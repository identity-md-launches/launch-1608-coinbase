// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Coinbase} from "../src/Coinbase.sol";

/// @dev Mirrors the launch factory: deploys the attested creation code through raw CREATE2 (so the
/// token's constructor sees the factory as msg.sender exactly as the real launch does), holds the
/// supply, and moves it on the test's instruction only.
contract RawCreate2Factory {
    address private immutable controller = msg.sender;

    modifier onlyController() {
        require(msg.sender == controller, "not the controller");
        _;
    }

    function deploy(bytes memory code, bytes32 salt) external onlyController returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
        }
        require(deployed != address(0) && deployed.code.length > 0, "constructor failed");
    }

    /// @dev Same as deploy, but reports failure instead of reverting, for collision checks.
    function tryDeploy(bytes memory code, bytes32 salt) external onlyController returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
        }
    }

    function move(IERC20 token, address to, uint256 amount) external onlyController returns (bool) {
        return token.transfer(to, amount);
    }

    function pull(IERC20 token, address from, address to, uint256 amount) external onlyController returns (bool) {
        return token.transferFrom(from, to, amount);
    }

    function call(address target, bytes calldata data) external onlyController returns (bool ok, bytes memory ret) {
        (ok, ret) = target.call(data);
    }
}

/// @dev A stand-in for the Uniswap v4 PoolManager's token movements: it is paid by plain
/// `transfer` into it (settle) and pays out by plain `transfer` from itself (take). No pricing.
contract PoolManagerProbe {
    function payOut(IERC20 token, address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }
}

/// @notice The launch floor, reproduced without the Uniswap v4 stack: the supply is minted once to
/// the CREATE2 deployer, launch flows arrive whole, no privileged entry point exists, and the
/// protected harness's full lists of administrative signatures are tried from every plausible caller.
contract CoinbaseLaunchTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;
    uint256 internal constant SWARM_BPS = 1_000;
    uint64 internal constant LAUNCH_NUMBER = 7;

    RawCreate2Factory internal factory;
    Coinbase internal token;

    address internal constant DISTRIBUTOR = address(0xD157);
    address internal constant CLAIMANT = address(0xC1A1);
    address internal constant HOLDER = address(0x401D);
    address internal constant OTHER = address(0x07E5);
    address internal constant ATTACKER = address(0xBEEF);

    function setUp() public {
        factory = new RawCreate2Factory();
        token = Coinbase(factory.deploy(type(Coinbase).creationCode, bytes32(uint256(LAUNCH_NUMBER))));
    }

    // ---------------------------------------------------------------------------------------------
    // Deployment
    // ---------------------------------------------------------------------------------------------

    function test_create2AddressIsPredictableFromCreationCodeAlone() public view {
        bytes32 codeHash = keccak256(type(Coinbase).creationCode);
        address predicted = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(bytes1(0xff), address(factory), bytes32(uint256(LAUNCH_NUMBER)), codeHash)
                    )
                )
            )
        );
        // No constructor arguments: the manifest's creation code is the compiler's output, unchanged.
        assertEq(address(token), predicted);
    }

    function test_mintsTheWholeSupplyToTheFactoryOnly() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.totalSupply(), 10 ** 27);
        assertEq(token.balanceOf(address(factory)), SUPPLY);
        assertEq(token.balanceOf(address(this)), 0, "the controller of the factory received tokens");
        assertEq(token.balanceOf(tx.origin), 0, "the transaction origin received tokens");
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(address(0)), 0);
    }

    function test_decimalsAndMetadataAreFixed() public view {
        assertEq(uint256(token.decimals()), 18);
        assertEq(token.name(), "Coinbase");
        assertEq(token.symbol(), "COINBASE");
        assertEq(bytes(token.name()).length, 8);
        assertEq(bytes(token.symbol()).length, 8);
    }

    function test_constructorEmitsExactlyOneMintAndNothingElse() public {
        vm.recordLogs();
        address fresh = factory.deploy(type(Coinbase).creationCode, keccak256("another"));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "the constructor emitted more than the mint");
        assertEq(logs[0].emitter, fresh);
        assertEq(logs[0].topics.length, 3);
        assertEq(logs[0].topics[0], IERC20.Transfer.selector);
        assertEq(logs[0].topics[1], bytes32(0));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(address(factory)))));
        assertEq(abi.decode(logs[0].data, (uint256)), SUPPLY);
    }

    function test_sameSaltCannotBeDeployedTwice() public {
        address again = factory.tryDeploy(type(Coinbase).creationCode, bytes32(uint256(LAUNCH_NUMBER)));
        assertEq(again, address(0), "CREATE2 collision did not fail");
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(factory)), SUPPLY);
    }

    function test_separateDeploymentsHaveIndependentSupplies() public {
        Coinbase second = Coinbase(factory.deploy(type(Coinbase).creationCode, bytes32(uint256(LAUNCH_NUMBER) + 1)));
        assertTrue(address(second) != address(token));
        assertEq(second.totalSupply(), SUPPLY);
        assertEq(second.balanceOf(address(factory)), SUPPLY);
        assertTrue(factory.move(token, HOLDER, 5 ether));
        assertEq(second.balanceOf(HOLDER), 0);
        assertEq(second.balanceOf(address(factory)), SUPPLY);
        assertEq(token.balanceOf(address(factory)), SUPPLY - 5 ether);
    }

    function test_creationCodeWithAppendedArgumentsStillMintsToDeployer() public {
        // The deployer encodes no constructor arguments. If someone appends some anyway, the
        // constructor ignores them: nothing is read, nothing changes hands.
        bytes memory code = abi.encodePacked(type(Coinbase).creationCode, abi.encode(ATTACKER, uint256(1)));
        Coinbase odd = Coinbase(factory.deploy(code, keccak256("appended")));
        assertEq(odd.totalSupply(), SUPPLY);
        assertEq(odd.balanceOf(address(factory)), SUPPLY);
        assertEq(odd.balanceOf(ATTACKER), 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Launch flows
    // ---------------------------------------------------------------------------------------------

    function test_theSwarmShareArrivesWholeAndIsClaimableWhole() public {
        uint256 swarm = (SUPPLY * SWARM_BPS) / 10_000;
        assertEq(swarm, 100_000_000 * 10 ** 18);
        assertTrue(factory.move(token, DISTRIBUTOR, swarm), "the transfer to the distributor returned false");
        assertEq(token.balanceOf(DISTRIBUTOR), swarm, "the swarm's share arrived short");
        vm.prank(DISTRIBUTOR);
        assertTrue(token.transfer(CLAIMANT, swarm), "the claim transfer returned false");
        assertEq(token.balanceOf(CLAIMANT), swarm, "a claim arrived short");
        assertEq(token.balanceOf(DISTRIBUTOR), 0, "the distributor kept something back");
        assertEq(token.totalSupply(), SUPPLY, "the launch flows changed the supply");
    }

    function test_manyClaimsDrainTheDistributorExactly() public {
        uint256 swarm = (SUPPLY * SWARM_BPS) / 10_000;
        factory.move(token, DISTRIBUTOR, swarm);
        // Two percent split among 7 workers, eight percent among 13 seats: uneven shares with dust.
        uint256 workers = (swarm * 2_000) / 10_000;
        uint256 seats = swarm - workers;
        uint256 perWorker = workers / 7;
        uint256 perSeat = seats / 13;
        uint256 paid;
        for (uint256 i; i < 7; ++i) {
            address w = address(uint160(0xA000 + i));
            vm.prank(DISTRIBUTOR);
            assertTrue(token.transfer(w, perWorker));
            assertEq(token.balanceOf(w), perWorker);
            paid += perWorker;
        }
        for (uint256 i; i < 13; ++i) {
            address s = address(uint160(0xB000 + i));
            vm.prank(DISTRIBUTOR);
            assertTrue(token.transfer(s, perSeat));
            assertEq(token.balanceOf(s), perSeat);
            paid += perSeat;
        }
        assertEq(token.balanceOf(DISTRIBUTOR), swarm - paid, "the distributor's remainder is not the exact dust");
        // One wei more than what is left must fail, and the failure must leave the dust intact.
        uint256 dust = swarm - paid;
        vm.prank(DISTRIBUTOR);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, DISTRIBUTOR, dust, dust + 1)
        );
        token.transfer(CLAIMANT, dust + 1);
        assertEq(token.balanceOf(DISTRIBUTOR), dust);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_poolManagerSettleAndTakeMoveExactAmounts() public {
        PoolManagerProbe manager = new PoolManagerProbe();
        uint256 seed = (SUPPLY * 8_800) / 10_000;
        // Seed: the factory settles the pool by transferring the requester's share into the manager.
        assertTrue(factory.move(token, address(manager), seed), "the seed transfer returned false");
        assertEq(token.balanceOf(address(manager)), seed, "the seed arrived short");

        // Buy: the manager takes tokens out to a trader.
        address trader = makeAddr("trader");
        assertTrue(manager.payOut(token, trader, 123_456_789 ether));
        assertEq(token.balanceOf(trader), 123_456_789 ether, "a buyer received short");
        assertEq(token.balanceOf(address(manager)), seed - 123_456_789 ether);

        // Sell: the trader settles by transferring the whole purchase back into the manager.
        vm.prank(trader);
        assertTrue(token.transfer(address(manager), 123_456_789 ether));
        assertEq(token.balanceOf(trader), 0, "a trader could not sell everything back");
        assertEq(token.balanceOf(address(manager)), seed, "the manager did not get back what it paid out");

        // A router paying on the trader's behalf through an allowance moves exactly what it says.
        address router = makeAddr("router");
        assertTrue(manager.payOut(token, trader, 1 ether));
        vm.prank(trader);
        token.approve(router, 1 ether);
        vm.prank(router);
        assertTrue(token.transferFrom(trader, address(manager), 1 ether));
        assertEq(token.balanceOf(trader), 0);
        assertEq(token.allowance(trader, router), 0);
        assertEq(token.balanceOf(address(manager)), seed);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_remainderRecipientReceivesExactlyTheRest() public {
        uint256 swarm = (SUPPLY * SWARM_BPS) / 10_000;
        uint256 seed = (SUPPLY * 8_800) / 10_000;
        address pool = makeAddr("pool");
        address requester = makeAddr("requester");
        factory.move(token, DISTRIBUTOR, swarm);
        factory.move(token, pool, seed);
        uint256 rest = token.balanceOf(address(factory));
        assertEq(rest, SUPPLY - swarm - seed);
        assertEq(rest, 20_000_000 * 10 ** 18);
        assertTrue(factory.move(token, requester, rest));
        assertEq(token.balanceOf(address(factory)), 0, "the factory kept tokens after the launch");
        assertEq(token.balanceOf(requester), rest);
        assertEq(token.balanceOf(DISTRIBUTOR) + token.balanceOf(pool) + token.balanceOf(requester), SUPPLY);
        // Nothing left: even one wei more from the factory fails.
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(factory), 0, 1));
        factory.move(token, requester, 1);
    }

    // ---------------------------------------------------------------------------------------------
    // No supply growth, no privileged hand
    // ---------------------------------------------------------------------------------------------

    function test_noCommonAdminCallIncreasesSupply() public {
        string[10] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], ATTACKER, type(uint128).max);
            vm.prank(ATTACKER);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            assertEq(token.totalSupply(), SUPPLY, signatures[i]);
            assertEq(token.balanceOf(ATTACKER), 0, signatures[i]);
            (ok,) = factory.call(address(token), data);
            assertFalse(ok, signatures[i]);
            assertEq(token.totalSupply(), SUPPLY, signatures[i]);
            assertEq(token.balanceOf(address(factory)), SUPPLY, signatures[i]);
        }
    }

    function test_noPrivilegedHandMovesOrFreezesAHolder() public {
        factory.move(token, HOLDER, SUPPLY / 1_000);
        uint256 held = token.balanceOf(HOLDER);
        assertGt(held, 0);
        string[12] memory signatures = [
            "pause()",
            "blacklist(address)",
            "blocklist(address)",
            "freeze(address)",
            "freezeAccount(address)",
            "setBlacklist(address,bool)",
            "setBlocked(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "setTransfersEnabled(bool)",
            "burnFrom(address,uint256)",
            "seize(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], HOLDER, true);
            (bool ok,) = factory.call(address(token), data);
            assertFalse(ok, signatures[i]);
            vm.prank(ATTACKER);
            (ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            assertEq(token.balanceOf(HOLDER), held, signatures[i]);
        }
        // The deployer tries to pull the holder's tokens without an allowance.
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(factory), 0, 1)
        );
        factory.pull(token, HOLDER, address(factory), 1);
        assertEq(token.balanceOf(HOLDER), held, "a privileged call moved the holder's balance");
        vm.prank(HOLDER);
        assertTrue(token.transfer(OTHER, held / 2), "the holder can no longer transfer");
        assertEq(token.balanceOf(OTHER), held / 2, "the holder's transfer delivered short");
        assertEq(token.balanceOf(HOLDER), held - held / 2);
    }

    function test_rejectsEtherAndUnknownCalls() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(token).call{value: 1}("");
        assertFalse(ok, "the token accepted ether");
        (ok,) = address(token).call{value: 1}(abi.encodeWithSelector(IERC20.transfer.selector, HOLDER, 0));
        assertFalse(ok, "a non-payable function accepted ether");
        (ok,) = address(token).call("");
        assertFalse(ok, "the token has a receive or fallback path");
        (ok,) = address(token).call(hex"deadbeef");
        assertFalse(ok, "an unknown selector did not revert");
        assertEq(address(token).balance, 0);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(factory)), SUPPLY);
    }

    function test_tokensSentToTheTokenItselfCannotBeRescuedByAnyone() public {
        factory.move(token, address(token), 1 ether);
        assertEq(token.balanceOf(address(token)), 1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(factory), 0, 1 ether)
        );
        factory.pull(token, address(token), address(factory), 1 ether);
        vm.prank(ATTACKER);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, ATTACKER, 0, 1 ether));
        token.transferFrom(address(token), ATTACKER, 1 ether);
        (bool ok,) = address(token).call(abi.encodeWithSignature("rescue(address,uint256)", ATTACKER, 1 ether));
        assertFalse(ok);
        assertEq(token.balanceOf(address(token)), 1 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_runtimeFitsEip170AndHasNoPrivilegedOpcodes() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576);
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4, "DELEGATECALL");
            assertTrue(op != 0xf2, "CALLCODE");
            assertTrue(op != 0xff, "SELFDESTRUCT");
            assertTrue(op != 0xf0, "CREATE");
            assertTrue(op != 0xf5, "CREATE2");
        }
    }
}
