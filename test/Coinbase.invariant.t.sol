// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Coinbase} from "../src/Coinbase.sol";

/// @dev Closed set of holders with an independent balance and allowance model.
contract CoinbaseHandler is Test {
    Coinbase public immutable token;
    address[4] public actors;
    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;

    constructor(Coinbase token_) {
        token = token_;
        for (uint256 i; i < actors.length; ++i) {
            actors[i] = makeAddr(string.concat("holder-", vm.toString(i)));
            expectedBalance[actors[i]] = token_.INITIAL_SUPPLY() / actors.length;
        }
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        amount = bound(amount, 0, expectedBalance[from]);
        vm.prank(from);
        require(token.transfer(to, amount), "transfer failed");
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount, bool unlimited) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        amount = unlimited ? type(uint256).max : bound(amount, 0, token.INITIAL_SUPPLY());
        vm.prank(owner);
        require(token.approve(spender, amount), "approve failed");
        expectedAllowance[owner][spender] = amount;
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 allowed = expectedAllowance[owner][spender];
        uint256 balance = expectedBalance[owner];
        amount = bound(amount, 0, allowed < balance ? allowed : balance);
        vm.prank(spender);
        require(token.transferFrom(owner, to, amount), "transferFrom failed");
        expectedBalance[owner] -= amount;
        expectedBalance[to] += amount;
        if (allowed != type(uint256).max) {
            expectedAllowance[owner][spender] -= amount;
        }
    }
}

contract CoinbaseInvariantTest is Test {
    Coinbase internal token;
    CoinbaseHandler internal handler;

    function setUp() public {
        token = new Coinbase();
        handler = new CoinbaseHandler(token);
        for (uint256 i; i < 4; ++i) {
            token.transfer(handler.actors(i), token.INITIAL_SUPPLY() / 4);
        }

        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = CoinbaseHandler.transfer.selector;
        selectors[1] = CoinbaseHandler.approve.selector;
        selectors[2] = CoinbaseHandler.transferFrom.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_supplyAndBalancesAreConserved() public view {
        uint256 sum;
        for (uint256 i; i < 4; ++i) {
            address actor = handler.actors(i);
            uint256 balance = token.balanceOf(actor);
            assertEq(balance, handler.expectedBalance(actor));
            sum += balance;
        }
        assertEq(sum, 1_000_000_000 * 10 ** 18);
        assertEq(token.totalSupply(), sum);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(handler)), 0);
    }

    function invariant_allowancesMatchApprovalsAndSpending() public view {
        for (uint256 i; i < 4; ++i) {
            address owner = handler.actors(i);
            for (uint256 j; j < 4; ++j) {
                address spender = handler.actors(j);
                assertEq(token.allowance(owner, spender), handler.expectedAllowance(owner, spender));
            }
        }
    }
}
