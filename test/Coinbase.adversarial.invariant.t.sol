// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Coinbase} from "../src/Coinbase.sol";

/// @dev Drives the token with an open cast: funded holders, strangers who start with nothing, the
/// deployer, the token contract itself as a sink, and callers who try what the token must refuse.
/// Every function is total: the operations that must fail are issued with low-level calls and the
/// failure itself is asserted, so `fail_on_revert` stays meaningful for the operations that must not.
contract CoinbaseAdversarialHandler is Test {
    Coinbase public immutable token;
    address public immutable deployer;

    /// @dev Everyone whose balance can be non-zero. Index 0 is the deployer, index 1 the token.
    address[] public cast;
    mapping(address => bool) public inCast;
    mapping(address => uint256) public ghostBalance;
    mapping(address => mapping(address => uint256)) public ghostAllowance;

    uint256 public ghostVolume;
    uint256 public ghostRefusals;
    uint256 public ghostTransfers;

    bytes4[22] internal privileged = [
        bytes4(keccak256("mint(address,uint256)")),
        bytes4(keccak256("mint(uint256)")),
        bytes4(keccak256("mint()")),
        bytes4(keccak256("issue(uint256)")),
        bytes4(keccak256("setOwner(address)")),
        bytes4(keccak256("transferOwnership(address)")),
        bytes4(keccak256("upgradeTo(address)")),
        bytes4(keccak256("initialize(address)")),
        bytes4(keccak256("unpause()")),
        bytes4(keccak256("setMinter(address)")),
        bytes4(keccak256("pause()")),
        bytes4(keccak256("blacklist(address)")),
        bytes4(keccak256("blocklist(address)")),
        bytes4(keccak256("freeze(address)")),
        bytes4(keccak256("freezeAccount(address)")),
        bytes4(keccak256("setBlacklist(address,bool)")),
        bytes4(keccak256("setBlocked(address,bool)")),
        bytes4(keccak256("lock(address)")),
        bytes4(keccak256("disableTransfers()")),
        bytes4(keccak256("setTransfersEnabled(bool)")),
        bytes4(keccak256("burnFrom(address,uint256)")),
        bytes4(keccak256("seize(address)"))
    ];

    constructor(Coinbase token_, address deployer_, uint256 holders, uint256 strangers) {
        token = token_;
        deployer = deployer_;
        _enroll(deployer_);
        _enroll(address(token_));
        for (uint256 i; i < holders; ++i) {
            _enroll(makeAddr(string.concat("holder-", vm.toString(i))));
        }
        for (uint256 i; i < strangers; ++i) {
            _enroll(makeAddr(string.concat("stranger-", vm.toString(i))));
        }
    }

    function castLength() external view returns (uint256) {
        return cast.length;
    }

    /// @dev Called by the test once the deployer has funded the holders, to seed the ghost model.
    function syncBalances() external {
        for (uint256 i; i < cast.length; ++i) {
            ghostBalance[cast[i]] = token.balanceOf(cast[i]);
        }
    }

    function _enroll(address a) internal {
        if (!inCast[a]) {
            inCast[a] = true;
            cast.push(a);
        }
    }

    function _pick(uint256 seed) internal view returns (address) {
        return cast[seed % cast.length];
    }

    /// @dev An address outside the cast holds nothing and has approved nobody; use it as a stranger.
    function _outsider(uint256 seed) internal view returns (address a) {
        a = address(uint160(uint256(keccak256(abi.encode("outsider", seed)))));
        if (inCast[a] || a == address(0)) a = address(uint160(uint256(keccak256(abi.encode(a)))));
    }

    /// @dev One of four slots a sequence can bring into the cast, so the cast stays small enough to
    /// check every allowance pair after every call.
    function _newcomer(uint256 seed) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encode("newcomer", seed % 4)))));
    }

    function _expectFailure(address caller, bytes memory data, bytes memory expectedError) internal {
        vm.prank(caller);
        (bool ok, bytes memory ret) = address(token).call(data);
        assertFalse(ok, "an operation that must fail succeeded");
        if (expectedError.length != 0) {
            assertEq(keccak256(ret), keccak256(expectedError), "unexpected revert reason");
        }
        ++ghostRefusals;
    }

    // ---------------------------------------------------------------------------------------------
    // Operations that must succeed
    // ---------------------------------------------------------------------------------------------

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _pick(fromSeed);
        address to = _pick(toSeed);
        if (from == address(token)) return; // the token contract never acts
        amount = bound(amount, 0, ghostBalance[from]);
        vm.prank(from);
        bool ok = token.transfer(to, amount);
        assertTrue(ok, "transfer returned false");
        ghostBalance[from] -= amount;
        ghostBalance[to] += amount;
        ghostVolume += amount;
        ++ghostTransfers;
    }

    function transferToNewcomer(uint256 fromSeed, uint256 newcomerSeed, uint256 amount) external {
        address from = _pick(fromSeed);
        if (from == address(token)) return;
        address to = _newcomer(newcomerSeed);
        amount = bound(amount, 0, ghostBalance[from]);
        vm.prank(from);
        assertTrue(token.transfer(to, amount), "transfer returned false");
        _enroll(to);
        ghostBalance[from] -= amount;
        ghostBalance[to] += amount;
        ghostVolume += amount;
        ++ghostTransfers;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount, bool unlimited) external {
        address owner = _pick(ownerSeed);
        address spender = _pick(spenderSeed);
        if (owner == address(token)) return;
        amount = unlimited ? type(uint256).max : bound(amount, 0, 2 * token.INITIAL_SUPPLY());
        vm.prank(owner);
        assertTrue(token.approve(spender, amount), "approve returned false");
        ghostAllowance[owner][spender] = amount;
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount) external {
        address owner = _pick(ownerSeed);
        address spender = _pick(spenderSeed);
        address to = _pick(toSeed);
        if (owner == address(token) || spender == address(token)) return;
        uint256 allowed = ghostAllowance[owner][spender];
        uint256 balance = ghostBalance[owner];
        amount = bound(amount, 0, allowed < balance ? allowed : balance);
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount), "transferFrom returned false");
        ghostBalance[owner] -= amount;
        ghostBalance[to] += amount;
        ghostVolume += amount;
        ++ghostTransfers;
        if (allowed != type(uint256).max) ghostAllowance[owner][spender] -= amount;
    }

    // ---------------------------------------------------------------------------------------------
    // Operations that must fail, and must leave nothing behind
    // ---------------------------------------------------------------------------------------------

    function transferOverBalance(uint256 fromSeed, uint256 toSeed, uint256 excess) external {
        address from = _pick(fromSeed);
        address to = _pick(toSeed);
        if (from == address(token)) from = deployer;
        uint256 balance = ghostBalance[from];
        excess = bound(excess, 1, type(uint256).max - balance);
        _expectFailure(
            from,
            abi.encodeCall(IERC20.transfer, (to, balance + excess)),
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, balance, balance + excess)
        );
    }

    function transferToZero(uint256 fromSeed, uint256 amount) external {
        address from = _pick(fromSeed);
        if (from == address(token)) from = deployer;
        _expectFailure(
            from,
            abi.encodeCall(IERC20.transfer, (address(0), amount)),
            abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0))
        );
    }

    function approveZeroSpender(uint256 ownerSeed, uint256 amount) external {
        address owner = _pick(ownerSeed);
        if (owner == address(token)) owner = deployer;
        _expectFailure(
            owner,
            abi.encodeCall(IERC20.approve, (address(0), amount)),
            abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0))
        );
    }

    function transferFromOverAllowance(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 excess)
        external
    {
        address owner = _pick(ownerSeed);
        address spender = _pick(spenderSeed);
        address to = _pick(toSeed);
        if (owner == address(token)) owner = deployer;
        if (spender == address(token)) spender = deployer;
        uint256 allowed = ghostAllowance[owner][spender];
        if (allowed == type(uint256).max) return; // nothing is over an unlimited allowance
        excess = bound(excess, 1, type(uint256).max - allowed);
        _expectFailure(
            spender,
            abi.encodeCall(IERC20.transferFrom, (owner, to, allowed + excess)),
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, allowed + excess)
        );
    }

    function transferFromOverBalance(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 excess) external {
        address owner = _pick(ownerSeed);
        address spender = _pick(spenderSeed);
        address to = _pick(toSeed);
        if (owner == address(token)) owner = deployer;
        if (spender == address(token)) spender = deployer;
        uint256 balance = ghostBalance[owner];
        // Grant enough allowance that only the balance stands in the way.
        vm.prank(owner);
        token.approve(spender, type(uint256).max);
        ghostAllowance[owner][spender] = type(uint256).max;
        excess = bound(excess, 1, type(uint256).max - balance);
        _expectFailure(
            spender,
            abi.encodeCall(IERC20.transferFrom, (owner, to, balance + excess)),
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, balance, balance + excess)
        );
    }

    function strangerPullsWithoutApproval(uint256 strangerSeed, uint256 victimSeed, uint256 amount) external {
        address stranger = _outsider(strangerSeed);
        address victim = _pick(victimSeed);
        amount = bound(amount, 1, type(uint256).max);
        _expectFailure(
            stranger,
            abi.encodeCall(IERC20.transferFrom, (victim, stranger, amount)),
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, stranger, 0, amount)
        );
    }

    function strangerSpendsNothing(uint256 strangerSeed, uint256 toSeed, uint256 amount) external {
        address stranger = _outsider(strangerSeed);
        amount = bound(amount, 1, type(uint256).max);
        _expectFailure(
            stranger,
            abi.encodeCall(IERC20.transfer, (_pick(toSeed), amount)),
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, stranger, 0, amount)
        );
    }

    function deployerPullsWithoutApproval(uint256 victimSeed, uint256 amount) external {
        address victim = _pick(victimSeed);
        if (victim == deployer) victim = address(token);
        uint256 allowed = ghostAllowance[victim][deployer];
        if (allowed == type(uint256).max) return;
        amount = bound(amount, allowed + 1, type(uint256).max);
        _expectFailure(
            deployer,
            abi.encodeCall(IERC20.transferFrom, (victim, deployer, amount)),
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, deployer, allowed, amount)
        );
    }

    function privilegedCall(uint256 callerSeed, uint256 selectorSeed, uint256 targetSeed, uint256 amount) external {
        address caller = callerSeed % 2 == 0 ? deployer : _pick(callerSeed);
        bytes4 selector = privileged[selectorSeed % privileged.length];
        _expectFailure(caller, abi.encodeWithSelector(selector, _pick(targetSeed), amount), "");
    }

    function sendEther(uint256 fromSeed, uint256 value, bytes calldata payload) external {
        address from = _pick(fromSeed);
        if (from == address(token)) from = deployer; // dealing ether to the token would fund it
        value = bound(value, 1, 100 ether);
        vm.deal(from, value);
        vm.prank(from);
        (bool ok,) = address(token).call{value: value}(payload);
        assertFalse(ok, "the token accepted ether");
        ++ghostRefusals;
    }
}

/// @notice Random call sequences from an open set of actors, including the deployer, the token's own
/// address as a sink, newcomers who join mid-sequence, and callers issuing what must be refused.
contract CoinbaseAdversarialInvariantTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;
    uint256 internal constant HOLDERS = 5;
    uint256 internal constant STRANGERS = 2;

    Coinbase internal token;
    CoinbaseAdversarialHandler internal handler;

    function setUp() public {
        token = new Coinbase();
        handler = new CoinbaseAdversarialHandler(token, address(this), HOLDERS, STRANGERS);
        // Fund the holders unevenly; the deployer keeps the rest. Strangers and the token start empty.
        uint256 share = SUPPLY / 10;
        for (uint256 i; i < HOLDERS; ++i) {
            token.transfer(handler.cast(2 + i), share * (i + 1) / HOLDERS);
        }
        handler.syncBalances();

        bytes4[] memory selectors = new bytes4[](14);
        selectors[0] = CoinbaseAdversarialHandler.transfer.selector;
        selectors[1] = CoinbaseAdversarialHandler.transferToNewcomer.selector;
        selectors[2] = CoinbaseAdversarialHandler.approve.selector;
        selectors[3] = CoinbaseAdversarialHandler.transferFrom.selector;
        selectors[4] = CoinbaseAdversarialHandler.transferOverBalance.selector;
        selectors[5] = CoinbaseAdversarialHandler.transferToZero.selector;
        selectors[6] = CoinbaseAdversarialHandler.approveZeroSpender.selector;
        selectors[7] = CoinbaseAdversarialHandler.transferFromOverAllowance.selector;
        selectors[8] = CoinbaseAdversarialHandler.transferFromOverBalance.selector;
        selectors[9] = CoinbaseAdversarialHandler.strangerPullsWithoutApproval.selector;
        selectors[10] = CoinbaseAdversarialHandler.strangerSpendsNothing.selector;
        selectors[11] = CoinbaseAdversarialHandler.deployerPullsWithoutApproval.selector;
        selectors[12] = CoinbaseAdversarialHandler.privilegedCall.selector;
        selectors[13] = CoinbaseAdversarialHandler.sendEther.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_supplyIsFixed() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
        assertEq(uint256(token.decimals()), 18);
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_balancesMatchTheModelAndSumToSupply() public view {
        uint256 n = handler.castLength();
        uint256 sum;
        for (uint256 i; i < n; ++i) {
            address a = handler.cast(i);
            uint256 balance = token.balanceOf(a);
            assertEq(balance, handler.ghostBalance(a), "a balance drifted from the model");
            assertLe(balance, SUPPLY);
            sum += balance;
        }
        assertEq(sum, SUPPLY, "the cast does not hold the whole supply");
        assertEq(token.balanceOf(address(0)), 0, "the zero address holds tokens");
        assertEq(token.balanceOf(address(handler)), 0, "the handler holds tokens");
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_allowancesMatchTheModel() public view {
        uint256 n = handler.castLength();
        for (uint256 i; i < n; ++i) {
            address owner = handler.cast(i);
            for (uint256 j; j < n; ++j) {
                address spender = handler.cast(j);
                assertEq(token.allowance(owner, spender), handler.ghostAllowance(owner, spender));
            }
            assertEq(token.allowance(owner, address(0)), 0);
        }
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_tokenHoldsNoEtherAndNothingLeavesItsOwnBalanceUnasked() public view {
        assertEq(address(token).balance, 0);
        // Tokens sent to the token's own address are a sink: only transfer/transferFrom with an
        // allowance could move them, and the token never grants one.
        assertEq(token.balanceOf(address(token)), handler.ghostBalance(address(token)));
    }
}
