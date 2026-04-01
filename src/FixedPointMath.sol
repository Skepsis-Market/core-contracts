// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {UD60x18, ud, unwrap, convert} from "@prb/math/UD60x18.sol";

/// @notice Fixed-point math library for LMSR with USDC decimal conversions
library FixedPointMath {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant USDC_DECIMALS = 1e6;
    uint256 internal constant PRECISION = 1e6;

    error OverflowError();
    error DivisionByZero();
    error InvalidInput();

    /// @notice Convert USDC (6 decimals) to WAD (18 decimals)
    /// @param usdcAmount Amount in USDC decimals (1e6)
    /// @return Amount in WAD (1e18)
    function toWad(uint256 usdcAmount) internal pure returns (uint256) {
        return usdcAmount * 1e12;
    }

    /// @notice Convert WAD (18 decimals) to USDC (6 decimals), round down
    /// @param wadAmount Amount in WAD (1e18)
    /// @return Amount in USDC decimals (1e6)
    function fromWad(uint256 wadAmount) internal pure returns (uint256) {
        return wadAmount / 1e12;
    }

    /// @notice Convert WAD to USDC, round up
    /// @param wadAmount Amount in WAD (1e18)
    /// @return Amount in USDC decimals (1e6)
    function fromWadRoundUp(uint256 wadAmount) internal pure returns (uint256) {
        uint256 remainder = wadAmount % 1e12;
        uint256 base = wadAmount / 1e12;
        return remainder > 0 ? base + 1 : base;
    }

    /// @notice Calculate e^x using PRB-Math
    /// @param x Exponent in WAD
    /// @return e^x in WAD
    function exp(uint256 x) public pure returns (uint256) {
        UD60x18 xUD = ud(x);
        UD60x18 result = xUD.exp();
        return unwrap(result);
    }

    /// @notice Calculate ln(x) using PRB-Math
    /// @param x Value in WAD (must be > 0)
    /// @return ln(x) in WAD
    function ln(uint256 x) public pure returns (uint256) {
        require(x > 0, "InvalidInput");
        UD60x18 xUD = ud(x);
        UD60x18 result = xUD.ln();
        return unwrap(result);
    }

    /// @notice Safe multiply: (a * b) / WAD
    /// @param a First operand in WAD
    /// @param b Second operand in WAD
    /// @return Product in WAD
    function mulWad(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a * b) / WAD;
    }

    /// @notice Safe divide: (a * WAD) / b
    /// @param a Numerator in WAD
    /// @param b Denominator in WAD
    /// @return Quotient in WAD
    function divWad(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b > 0, "DivisionByZero");
        return (a * WAD) / b;
    }

    /// @notice Convert uint256 to WAD
    /// @param x Value
    /// @return x * WAD
    function fromU256(uint256 x) internal pure returns (uint256) {
        return x * WAD;
    }

    /// @notice Convert WAD to uint256 (truncate decimals)
    /// @param x Value in WAD
    /// @return x / WAD
    function toU256(uint256 x) internal pure returns (uint256) {
        return x / WAD;
    }

    /// @notice Get precision constant
    /// @return PRECISION (1e6)
    function getPrecision() internal pure returns (uint256) {
        return PRECISION;
    }
}
