// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {FixedPointMath} from "../src/FixedPointMath.sol";

contract DebugAlphaTest is Test {
    using FixedPointMath for uint256;
    
    uint256 constant SPREAD_FACTOR = 2_160_000; // 2.16 in 6 decimals
    uint256 constant PRECISION = 1e12;
    
    function test_calculate_alpha() public view {
        uint256 poolBalance = 10_000_000_000; // $10K in 6 decimals
        uint256 bucketCount = 100;
        
        // Calculate ln(100)
        uint256 lnN = bucketCount.fromU256().ln();
        
        console.log("=== ALPHA CALCULATION DEBUG ===");
        console.log("poolBalance (6 dec):", poolBalance);
        console.log("bucketCount:", bucketCount);
        console.log("ln(100) in PRECISION:", lnN);
        console.log("SPREAD_FACTOR (6 dec):", SPREAD_FACTOR);
        console.log("PRECISION:", PRECISION);
        console.log("");
        
        // Step 1: Calculate divisor
        uint256 divisor = (SPREAD_FACTOR * lnN) / PRECISION;
        console.log("Step 1: divisor = (SPREAD_FACTOR * lnN) / PRECISION");
        console.log("       divisor =", divisor);
        console.log("");
        
        // Step 2: Calculate alpha
        uint256 alpha = (poolBalance * PRECISION) / divisor;
        console.log("Step 2: alpha = (poolBalance * PRECISION) / divisor");
        console.log("       alpha =", alpha);
        console.log("       alpha in USDC = $", alpha / 1_000_000);
        console.log("");
        
        console.log("Expected Sui alpha ~= 1_005_000_000 (6 decimals)");
        console.log("Difference:", alpha > 1_005_000_000 ? alpha - 1_005_000_000 : 1_005_000_000 - alpha);
    }
}
