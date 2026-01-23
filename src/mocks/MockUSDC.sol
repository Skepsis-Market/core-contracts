// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/token/ERC20/extensions/ERC20Permit.sol";

/// @notice Mock USDC for testing (6 decimals)
contract MockUSDC is ERC20, ERC20Permit {
    constructor() ERC20("USD Coin", "USDC") ERC20Permit("USD Coin") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }

    /// @notice Helper for testing - returns the permit typehash
    function PERMIT_TYPEHASH() external pure returns (bytes32) {
        return keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    }
}
