// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Coinbase (COINBASE)
/// @notice A fixed-supply ERC-20 with 18 decimals and no administrative powers.
contract Coinbase is ERC20 {
    /// @notice One billion tokens, expressed in the smallest token units.
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    /// @notice Mint the entire supply once to the immediate deployer.
    /// @dev During the launch, msg.sender is the factory that distributes the supply.
    constructor() ERC20("Coinbase", "COINBASE") {
        _mint(msg.sender, INITIAL_SUPPLY);
    }
}
