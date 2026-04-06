// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/token/ERC20/extensions/IERC20Permit.sol";

/// @notice USDC interface with EIP-2612 permit support
interface IUSDC is IERC20, IERC20Permit {
    function decimals() external view returns (uint8);
}
