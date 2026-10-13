// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Coinbase} from "../src/Coinbase.sol";

/// @notice Property tests over arbitrary accounts and amounts. Constraints are applied with `bound`
/// and address remapping rather than `vm.assume`, so every run exercises the token.
contract CoinbaseFuzzTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;
    Coinbase internal token;

    function setUp() public {
        token = new Coinbase();
    }

    /// @dev Maps any fuzzed address onto a usable holder: never the zero address, never the deployer.
    function _holder(address a) internal view returns (address) {
        if (a == address(0) || a == address(this)) return address(uint160(uint256(keccak256(abi.encode(a)))));
        return a;
    }

    /// @dev Makes `b` differ from `a` without discarding the run.
    function _distinct(address a, address b) internal pure returns (address) {
        if (a == b) return address(uint160(uint256(keccak256(abi.encode(b, "distinct")))));
        return b;
    }

    function _isKnownSelector(bytes4 selector) internal pure returns (bool) {
        return selector == IERC20.transfer.selector || selector == IERC20.transferFrom.selector
            || selector == IERC20.approve.selector || selector == IERC20.allowance.selector
            || selector == IERC20.balanceOf.selector || selector == IERC20.totalSupply.selector
            || selector == IERC20Metadata.name.selector || selector == IERC20Metadata.symbol.selector
            || selector == IERC20Metadata.decimals.selector || selector == bytes4(keccak256("INITIAL_SUPPLY()"));
    }

    // ---------------------------------------------------------------------------------------------
    // Transfers between arbitrary accounts
    // ---------------------------------------------------------------------------------------------

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_threePartyConservation(address a, address b, uint256 give, uint256 move) public {
        a = _holder(a);
        b = _distinct(a, _holder(b));
        give = bound(give, 0, SUPPLY);
        move = bound(move, 0, give);
        assertTrue(token.transfer(a, give));
        vm.prank(a);
        assertTrue(token.transfer(b, move));
        assertEq(token.balanceOf(a), give - move);
        assertEq(token.balanceOf(b), move);
        assertEq(token.balanceOf(address(this)), SUPPLY - give);
        assertEq(token.balanceOf(a) + token.balanceOf(b) + token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_roundTripRestoresBalances(address a, address b, uint256 give, uint256 move) public {
        a = _holder(a);
        b = _distinct(a, _holder(b));
        give = bound(give, 0, SUPPLY);
        move = bound(move, 0, give);
        token.transfer(a, give);
        uint256 aBefore = token.balanceOf(a);
        uint256 bBefore = token.balanceOf(b);
        vm.prank(a);
        token.transfer(b, move);
        vm.prank(b);
        token.transfer(a, move);
        assertEq(token.balanceOf(a), aBefore);
        assertEq(token.balanceOf(b), bBefore);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_transferEmitsExactlyOneTransferEvent(address to, uint256 amount) public {
        to = _holder(to);
        amount = bound(amount, 0, SUPPLY);
        vm.recordLogs();
        assertTrue(token.transfer(to, amount));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "a transfer emitted a hidden side effect");
        assertEq(logs[0].emitter, address(token));
        assertEq(logs[0].topics[0], IERC20.Transfer.selector);
        assertEq(address(uint160(uint256(logs[0].topics[1]))), address(this));
        assertEq(address(uint160(uint256(logs[0].topics[2]))), to);
        assertEq(abi.decode(logs[0].data, (uint256)), amount);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_splitAcrossManyRecipientsSumsExactly(uint256 seed, uint8 count) public {
        count = uint8(bound(count, 1, 32));
        uint256 remaining = SUPPLY;
        uint256 paid;
        for (uint256 i; i < count; ++i) {
            address to = address(uint160(uint256(keccak256(abi.encode(seed, i)))));
            if (to == address(0) || to == address(this)) to = address(uint160(0x1000 + i));
            uint256 part = bound(uint256(keccak256(abi.encode(seed, i, "amount"))), 0, remaining);
            uint256 before = token.balanceOf(to);
            assertTrue(token.transfer(to, part));
            assertEq(token.balanceOf(to), before + part);
            remaining -= part;
            paid += part;
        }
        assertEq(token.balanceOf(address(this)), SUPPLY - paid);
        assertEq(token.totalSupply(), SUPPLY);
    }

    // ---------------------------------------------------------------------------------------------
    // Failure paths with arbitrary inputs
    // ---------------------------------------------------------------------------------------------

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_transferToZeroAlwaysReverts(address from, uint256 funded, uint256 amount) public {
        from = _holder(from);
        funded = bound(funded, 0, SUPPLY);
        token.transfer(from, funded);
        vm.prank(from);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), amount);
        assertEq(token.balanceOf(from), funded);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_strangerCannotSpendAnyoneWithoutApproval(address stranger, address victim, uint256 amount)
        public
    {
        stranger = _holder(stranger);
        victim = _distinct(stranger, _holder(victim));
        amount = bound(amount, 1, SUPPLY);
        token.transfer(victim, amount);
        // Pull from the victim.
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, stranger, 0, amount));
        token.transferFrom(victim, stranger, amount);
        // Pull from the deployer, who holds the rest.
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, stranger, 0, 1));
        token.transferFrom(address(this), stranger, 1);
        // Spend their own empty balance.
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, stranger, 0, 1));
        token.transfer(victim, 1);
        assertEq(token.balanceOf(victim), amount);
        assertEq(token.balanceOf(stranger), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY - amount);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_approveAndSpendByArbitrarySpender(
        address owner,
        address spender,
        address to,
        uint256 funded,
        uint256 approved,
        uint256 spent
    ) public {
        owner = _holder(owner);
        spender = _distinct(owner, _holder(spender));
        to = _holder(to);
        funded = bound(funded, 0, SUPPLY);
        approved = bound(approved, 0, SUPPLY);
        spent = bound(spent, 0, approved < funded ? approved : funded);
        token.transfer(owner, funded);
        vm.prank(owner);
        assertTrue(token.approve(spender, approved));
        assertEq(token.allowance(owner, spender), approved);
        assertEq(token.allowance(spender, owner), 0, "approval is not symmetric");

        uint256 ownerBefore = token.balanceOf(owner);
        uint256 toBefore = token.balanceOf(to);
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, spent));
        assertEq(token.allowance(owner, spender), approved - spent);
        if (to == owner) {
            assertEq(token.balanceOf(owner), ownerBefore);
        } else {
            assertEq(token.balanceOf(owner), ownerBefore - spent);
            assertEq(token.balanceOf(to), toBefore + spent);
        }
        assertEq(token.totalSupply(), SUPPLY);

        // One wei past what remains of the allowance must fail, unless the allowance was unlimited.
        uint256 left = approved - spent;
        if (left < type(uint256).max) {
            vm.prank(spender);
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, left, left + 1)
            );
            token.transferFrom(owner, to, left + 1);
            assertEq(token.allowance(owner, spender), left);
        }
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_onlyExactMaxAllowanceIsUnlimited(uint256 below, uint256 spent) public {
        address spender = makeAddr("spender");
        // Anything strictly below type(uint256).max is finite and is decremented.
        below = bound(below, 1, type(uint256).max - 1);
        spent = bound(spent, 0, below < SUPPLY ? below : SUPPLY);
        token.approve(spender, below);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), spender, spent));
        assertEq(token.allowance(address(this), spender), below - spent);

        token.approve(spender, type(uint256).max);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), spender, SUPPLY - spent));
        assertEq(token.allowance(address(this), spender), type(uint256).max);
        assertEq(token.balanceOf(spender), SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_allowanceDoesNotCoverMoreThanTheBalance(uint256 funded, uint256 approved) public {
        address owner = makeAddr("owner");
        address spender = makeAddr("spender");
        funded = bound(funded, 0, SUPPLY - 1);
        approved = bound(approved, funded + 1, type(uint256).max);
        token.transfer(owner, funded);
        vm.prank(owner);
        token.approve(spender, approved);
        vm.prank(spender);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, funded, funded + 1)
        );
        token.transferFrom(owner, spender, funded + 1);
        assertEq(token.allowance(owner, spender), approved, "a failed pull consumed allowance");
        assertEq(token.balanceOf(owner), funded);
        assertEq(token.balanceOf(spender), 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_approveZeroSpenderAlwaysReverts(address owner, uint256 amount) public {
        owner = _holder(owner);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), amount);
        assertEq(token.allowance(owner, address(0)), 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_unknownSelectorsRevertAndChangeNothing(bytes4 selector, bytes memory payload, address caller)
        public
    {
        if (_isKnownSelector(selector)) selector = bytes4(uint32(selector) ^ 1);
        if (_isKnownSelector(selector)) selector = 0xdeadbeef;
        caller = _holder(caller);
        token.transfer(caller, 1 ether);
        bytes memory data = abi.encodePacked(selector, payload);
        vm.prank(caller);
        (bool ok,) = address(token).call(data);
        assertFalse(ok, "an undeclared function exists");
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(caller), 1 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY - 1 ether);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_etherIsAlwaysRejected(uint256 value, bytes memory payload) public {
        value = bound(value, 1, 1_000 ether);
        vm.deal(address(this), value);
        (bool ok,) = address(token).call{value: value}(payload);
        assertFalse(ok, "the token accepted ether");
        assertEq(address(token).balance, 0);
        assertEq(address(this).balance, value);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_anyDeployerReceivesTheWholeSupply(address deployer) public {
        deployer = _holder(deployer);
        vm.prank(deployer);
        Coinbase fresh = new Coinbase();
        assertEq(fresh.totalSupply(), SUPPLY);
        assertEq(fresh.balanceOf(deployer), SUPPLY);
        assertEq(fresh.balanceOf(address(this)), 0);
        assertEq(fresh.decimals(), 18);
    }
}
