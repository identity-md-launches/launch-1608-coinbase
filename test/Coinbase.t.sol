// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Coinbase} from "../src/Coinbase.sol";

/// @dev Test-only factory; it models immediate-deployer custody and exact transfers.
contract CoinbaseFactoryProbe {
    function deploy(bytes32 salt) external returns (Coinbase) {
        return new Coinbase{salt: salt}();
    }

    function send(Coinbase token, address to, uint256 amount) external {
        require(token.transfer(to, amount), "transfer failed");
    }
}

contract CoinbaseTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;
    Coinbase internal token;
    address internal alice;
    address internal bob;
    address internal spender;

    function setUp() public {
        token = new Coinbase();
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        spender = makeAddr("spender");
    }

    function test_metadataAndInitialSupply() public view {
        assertEq(token.name(), "Coinbase");
        assertEq(token.symbol(), "COINBASE");
        assertEq(token.decimals(), 18);
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
        assertEq(token.totalSupply(), 1_000_000_000_000_000_000_000_000_000);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.allowance(address(this), spender), 0);
    }

    function test_constructorEmitsMintTransfer() public {
        vm.expectEmit(true, true, false, true);
        emit IERC20.Transfer(address(0), address(this), SUPPLY);
        Coinbase fresh = new Coinbase();
        assertEq(fresh.balanceOf(address(this)), SUPPLY);
    }

    function test_constructorMintsToImmediateDeployer() public {
        vm.prank(alice, bob);
        Coinbase fresh = new Coinbase();
        assertEq(fresh.balanceOf(alice), SUPPLY);
        assertEq(fresh.balanceOf(bob), 0);
        assertEq(fresh.balanceOf(address(this)), 0);
    }

    function test_factoryDeploymentAndLaunchTransfersArriveWhole() public {
        CoinbaseFactoryProbe factory = new CoinbaseFactoryProbe();
        address distributor = makeAddr("distributor");
        address poolManager = makeAddr("pool manager");
        vm.prank(alice, bob);
        Coinbase launched = factory.deploy(keccak256("launch"));
        assertEq(launched.balanceOf(address(factory)), SUPPLY);
        assertEq(launched.balanceOf(alice), 0);
        assertEq(launched.balanceOf(bob), 0);

        uint256 swarm = SUPPLY * 10 / 100;
        uint256 liquidity = SUPPLY * 88 / 100;
        uint256 remainder = SUPPLY * 2 / 100;
        factory.send(launched, distributor, swarm);
        factory.send(launched, poolManager, liquidity);
        factory.send(launched, alice, remainder);
        assertEq(launched.balanceOf(address(factory)), 0);
        assertEq(launched.balanceOf(distributor), swarm);
        assertEq(launched.balanceOf(poolManager), liquidity);
        assertEq(launched.balanceOf(alice), remainder);

        vm.prank(distributor);
        assertTrue(launched.transfer(bob, swarm));
        assertEq(launched.balanceOf(bob), swarm);
        assertEq(launched.balanceOf(distributor), 0);

        // Exercise both directions of token movement without modeling DEX pricing.
        vm.prank(poolManager);
        assertTrue(launched.transfer(spender, 1 ether));
        assertEq(launched.balanceOf(spender), 1 ether);
        vm.prank(spender);
        assertTrue(launched.transfer(poolManager, 1 ether));
        assertEq(launched.balanceOf(spender), 0);
        assertEq(launched.balanceOf(poolManager), liquidity);
        assertEq(launched.totalSupply(), SUPPLY);
    }

    function test_transferEmitsEventAndMovesExactAmount() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(address(this), alice, 42 ether);
        assertTrue(token.transfer(alice, 42 ether));
        assertEq(token.balanceOf(alice), 42 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY - 42 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferEntireSupply() public {
        assertTrue(token.transfer(alice, SUPPLY));
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(alice), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_selfTransferDoesNotChangeBalance() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(address(this), address(this), SUPPLY);
        assertTrue(token.transfer(address(this), SUPPLY));
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_zeroTransferFromEmptyAccountEmitsEvent() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(alice, bob, 0);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transferToZeroRevertsEvenForZeroAmount() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferWithoutBalanceReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        token.transfer(bob, 1);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transferMaximumUintRevertsWithoutChangingState() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, type(uint256).max
            )
        );
        token.transfer(alice, type(uint256).max);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_approveEmitsEventAndCanBeReplacedAndRevoked() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Approval(address(this), spender, 10 ether);
        assertTrue(token.approve(spender, 10 ether));
        assertEq(token.allowance(address(this), spender), 10 ether);
        assertTrue(token.approve(spender, 5 ether));
        assertEq(token.allowance(address(this), spender), 5 ether);
        assertTrue(token.approve(spender, 0));
        assertEq(token.allowance(address(this), spender), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_approveDoesNotRequireBalance() public {
        vm.prank(alice);
        assertTrue(token.approve(spender, type(uint256).max));
        assertEq(token.allowance(alice, spender), type(uint256).max);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_approveZeroSpenderReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 0);
        assertEq(token.allowance(address(this), address(0)), 0);
    }

    function test_transferFromSpendsFiniteAllowanceAndEmitsTransfer() public {
        token.approve(spender, 10 ether);
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(address(this), alice, 4 ether);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, 4 ether));
        assertEq(token.allowance(address(this), spender), 6 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY - 4 ether);
        assertEq(token.balanceOf(alice), 4 ether);
        assertEq(token.balanceOf(spender), 0);
    }

    function test_transferFromExhaustsAllowanceAndCannotSpendAgain() public {
        token.approve(spender, 10 ether);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, 10 ether));
        assertEq(token.allowance(address(this), spender), 0);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        token.transferFrom(address(this), alice, 1);
        assertEq(token.balanceOf(alice), 10 ether);
    }

    function test_transferFromUnlimitedAllowanceIsNotDecremented() public {
        token.approve(spender, type(uint256).max);
        vm.startPrank(spender);
        assertTrue(token.transferFrom(address(this), alice, 10 ether));
        assertTrue(token.transferFrom(address(this), alice, 20 ether));
        vm.stopPrank();
        assertEq(token.allowance(address(this), spender), type(uint256).max);
        assertEq(token.balanceOf(alice), 30 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY - 30 ether);
    }

    function test_transferFromAfterRevocationReverts() public {
        token.approve(spender, 10 ether);
        token.approve(spender, 0);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        token.transferFrom(address(this), alice, 1);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_transferFromInsufficientBalanceRollsBackAllowance() public {
        vm.prank(alice);
        token.approve(spender, 10 ether);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1 ether));
        token.transferFrom(alice, bob, 1 ether);
        assertEq(token.allowance(alice, spender), 10 ether);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transferFromToZeroRollsBackAllowance() public {
        token.approve(spender, 10 ether);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(address(this), address(0), 1 ether);
        assertEq(token.allowance(address(this), spender), 10 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferFromZeroSenderReverts() public {
        // Allowance processing rejects the zero owner before transfer validation.
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        token.transferFrom(address(0), alice, 0);
    }

    function test_transferFromZeroAmountNeedsNoAllowance() public {
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, 0));
        assertEq(token.allowance(alice, spender), 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transferFromSelfConsumesAllowanceWithoutMovingBalance() public {
        token.approve(spender, 10 ether);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), address(this), 4 ether));
        assertEq(token.allowance(address(this), spender), 6 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_deployerCannotSpendHolderBalanceWithoutApproval() public {
        token.transfer(alice, 10 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(this), 0, 1 ether)
        );
        token.transferFrom(alice, address(this), 1 ether);
        assertEq(token.balanceOf(alice), 10 ether);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 10 ether));
        assertEq(token.balanceOf(bob), 10 ether);
    }

    function test_anotherSpenderCannotUseApproval() public {
        token.approve(spender, 10 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1 ether));
        token.transferFrom(address(this), alice, 1 ether);
        assertEq(token.allowance(address(this), spender), 10 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_noMintBurnOrAdministrativeEntrypoints() public {
        bytes[] memory calls = new bytes[](13);
        calls[0] = abi.encodeWithSignature("mint(address,uint256)", alice, SUPPLY);
        calls[1] = abi.encodeWithSignature("mint(uint256)", SUPPLY);
        calls[2] = abi.encodeWithSignature("mint()");
        calls[3] = abi.encodeWithSignature("burn(uint256)", 1 ether);
        calls[4] = abi.encodeWithSignature("burnFrom(address,uint256)", alice, 1 ether);
        calls[5] = abi.encodeWithSignature("pause()");
        calls[6] = abi.encodeWithSignature("blacklist(address)", alice);
        calls[7] = abi.encodeWithSignature("freeze(address)", alice);
        calls[8] = abi.encodeWithSignature("seize(address)", alice);
        calls[9] = abi.encodeWithSignature("initialize(address)", alice);
        calls[10] = abi.encodeWithSignature("transferOwnership(address)", alice);
        calls[11] = abi.encodeWithSignature("upgradeTo(address)", alice);
        calls[12] = abi.encodeWithSignature("setMinter(address)", alice);
        token.transfer(alice, 10 ether);
        // Even an approved spender cannot use a privileged burn entrypoint.
        vm.prank(alice);
        token.approve(address(this), 10 ether);
        for (uint256 i; i < calls.length; ++i) {
            (bool deployerSucceeded,) = address(token).call(calls[i]);
            assertFalse(deployerSucceeded);
            vm.prank(bob);
            (bool strangerSucceeded,) = address(token).call(calls[i]);
            assertFalse(strangerSucceeded);
            assertEq(token.totalSupply(), SUPPLY);
            assertEq(token.balanceOf(alice), 10 ether);
        }
        vm.prank(alice);
        assertTrue(token.transfer(bob, 10 ether));
        assertEq(token.balanceOf(bob), 10 ether);
    }

    function test_runtimeHasNoPrivilegedOpcodes() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576);
        for (uint256 i; i < runtime.length; ++i) {
            uint8 opcode = uint8(runtime[i]);
            if (opcode >= 0x60 && opcode <= 0x7f) {
                i += opcode - 0x5f;
                continue;
            }
            assertTrue(opcode != 0xf4, "DELEGATECALL");
            assertTrue(opcode != 0xf2, "CALLCODE");
            assertTrue(opcode != 0xff, "SELFDESTRUCT");
        }
    }

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != address(this));
        amount = bound(amount, 0, SUPPLY);
        assertTrue(token.transfer(to, amount));
        assertEq(token.balanceOf(to), amount);
        assertEq(token.balanceOf(address(this)), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferOverBalanceIsAtomic(uint256 balance, uint256 excess) public {
        balance = bound(balance, 0, SUPPLY);
        excess = bound(excess, 1, type(uint256).max - balance);
        token.transfer(alice, balance);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, balance, balance + excess)
        );
        token.transfer(bob, balance + excess);
        assertEq(token.balanceOf(alice), balance);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferFromAccounting(uint256 approved, uint256 spent) public {
        approved = bound(approved, 0, SUPPLY);
        spent = bound(spent, 0, approved);
        token.approve(spender, approved);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, spent));
        assertEq(token.allowance(address(this), spender), approved - spent);
        assertEq(token.balanceOf(address(this)), SUPPLY - spent);
        assertEq(token.balanceOf(alice), spent);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferFromOverAllowanceIsAtomic(uint256 approved) public {
        approved = bound(approved, 0, SUPPLY - 1);
        token.approve(spender, approved);
        vm.prank(spender);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, approved, approved + 1)
        );
        token.transferFrom(address(this), alice, approved + 1);
        assertEq(token.allowance(address(this), spender), approved);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }
}
