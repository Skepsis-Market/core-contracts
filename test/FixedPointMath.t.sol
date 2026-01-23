// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {FixedPointMath} from "../src/FixedPointMath.sol";

contract FixedPointMathTest is Test {
    using FixedPointMath for uint256;

    function test_toWad_convertsCorrectly() public pure {
        assertEq(FixedPointMath.toWad(1_000000), 1e18);
        assertEq(FixedPointMath.toWad(10_000000), 10e18);
        assertEq(FixedPointMath.toWad(100_000000), 100e18);
    }

    function test_fromWad_convertsCorrectly() public pure {
        assertEq(FixedPointMath.fromWad(1e18), 1_000000);
        assertEq(FixedPointMath.fromWad(10e18), 10_000000);
        assertEq(FixedPointMath.fromWad(100e18), 100_000000);
    }

    function test_fromWad_roundsDown() public pure {
        assertEq(FixedPointMath.fromWad(1e18 + 5e11), 1_000000);
        assertEq(FixedPointMath.fromWad(10e18 + 9e11), 10_000000);
    }

    function test_fromWadRoundUp_roundsUp() public pure {
        assertEq(FixedPointMath.fromWadRoundUp(1e18 + 1), 1_000001);
        assertEq(FixedPointMath.fromWadRoundUp(10e18 + 5e11), 10_000001);
    }

    function test_fromWadRoundUp_noRoundIfExact() public pure {
        assertEq(FixedPointMath.fromWadRoundUp(1e18), 1_000000);
        assertEq(FixedPointMath.fromWadRoundUp(10e18), 10_000000);
    }

    function test_roundTrip_toWadFromWad() public pure {
        uint256 usdc = 1234_567890;
        uint256 wad = FixedPointMath.toWad(usdc);
        uint256 backToUsdc = FixedPointMath.fromWad(wad);
        assertEq(backToUsdc, usdc);
    }

    function test_exp_e0equals1() public pure {
        uint256 result = FixedPointMath.exp(0);
        assertApproxEqRel(result, 1e18, 0.001e18);
    }

    function test_exp_e1equalsE() public pure {
        uint256 result = FixedPointMath.exp(1e18);
        assertApproxEqRel(result, 2.718281828459045235e18, 0.001e18);
    }

    function test_ln_ln1equals0() public pure {
        uint256 result = FixedPointMath.ln(1e18);
        assertEq(result, 0);
    }

    function test_ln_lnEequals1() public pure {
        uint256 e = 2.718281828459045235e18;
        uint256 result = FixedPointMath.ln(e);
        assertApproxEqRel(result, 1e18, 0.001e18);
    }

    function test_mulWad_basic() public pure {
        uint256 a = 2e18;
        uint256 b = 3e18;
        assertEq(FixedPointMath.mulWad(a, b), 6e18);
    }

    function test_divWad_basic() public pure {
        uint256 a = 6e18;
        uint256 b = 2e18;
        assertEq(FixedPointMath.divWad(a, b), 3e18);
    }

    function test_fromU256_convertsCorrectly() public pure {
        assertEq(FixedPointMath.fromU256(1), 1e18);
        assertEq(FixedPointMath.fromU256(10), 10e18);
    }

    function test_toU256_convertsCorrectly() public pure {
        assertEq(FixedPointMath.toU256(1e18), 1);
        assertEq(FixedPointMath.toU256(10e18), 10);
    }

    function testFuzz_roundTrip(uint256 usdc) public pure {
        usdc = bound(usdc, 1, type(uint128).max / 1e12);
        uint256 wad = FixedPointMath.toWad(usdc);
        uint256 backToUsdc = FixedPointMath.fromWad(wad);
        assertEq(backToUsdc, usdc);
    }

    function testFuzz_toWadFromWad(uint256 wad) public pure {
        wad = bound(wad, 1e12, type(uint256).max);
        wad = (wad / 1e12) * 1e12;
        uint256 usdc = FixedPointMath.fromWad(wad);
        uint256 backToWad = FixedPointMath.toWad(usdc);
        assertEq(backToWad, wad);
    }

    // ========== EDGE CASES ==========

    function test_toWad_zero() public pure {
        assertEq(FixedPointMath.toWad(0), 0);
    }

    function test_fromWad_zero() public pure {
        assertEq(FixedPointMath.fromWad(0), 0);
    }

    function test_fromWadRoundUp_zero() public pure {
        assertEq(FixedPointMath.fromWadRoundUp(0), 0);
    }

    function test_toWad_maxSafeValue() public pure {
        // Max USDC value that won't overflow when converted to WAD
        uint256 maxUSDC = type(uint256).max / 1e12;
        uint256 wad = FixedPointMath.toWad(maxUSDC);
        assertGt(wad, 0);
    }

    function test_fromU256_zero() public pure {
        assertEq(FixedPointMath.fromU256(0), 0);
    }

    function test_toU256_zero() public pure {
        assertEq(FixedPointMath.toU256(0), 0);
    }

    function test_fromU256_maxUint8() public pure {
        assertEq(FixedPointMath.fromU256(type(uint8).max), uint256(type(uint8).max) * 1e18);
    }

    function test_toU256_roundsDown() public pure {
        assertEq(FixedPointMath.toU256(1e18 + 5e17), 1); // 1.5 → 1
        assertEq(FixedPointMath.toU256(10e18 + 9e17), 10); // 10.9 → 10
    }

    // ========== PRECISION LOSS SCENARIOS ==========

    function test_fromWad_precisionLoss_smallValues() public pure {
        // Values smaller than 1e12 get rounded to 0
        assertEq(FixedPointMath.fromWad(1e11), 0);
        assertEq(FixedPointMath.fromWad(5e11), 0);
        assertEq(FixedPointMath.fromWad(9.99e11), 0);
    }

    function test_fromWadRoundUp_precisionLoss_alwaysRoundsUp() public pure {
        // Even tiny dust rounds up
        assertEq(FixedPointMath.fromWadRoundUp(1), 1);
        assertEq(FixedPointMath.fromWadRoundUp(1e11), 1);
        assertEq(FixedPointMath.fromWadRoundUp(1e12 + 1), 2);
    }

    function test_toU256_precisionLoss() public pure {
        // Values smaller than 1e18 get rounded to 0
        assertEq(FixedPointMath.toU256(1e17), 0);
        assertEq(FixedPointMath.toU256(5e17), 0);
        assertEq(FixedPointMath.toU256(9.99e17), 0);
    }

    // ========== MATH OPERATIONS ==========

    function test_mulWad_zero() public pure {
        assertEq(FixedPointMath.mulWad(0, 5e18), 0);
        assertEq(FixedPointMath.mulWad(5e18, 0), 0);
        assertEq(FixedPointMath.mulWad(0, 0), 0);
    }

    function test_mulWad_identity() public pure {
        // Multiplying by 1e18 (1.0 in WAD) should return original
        assertEq(FixedPointMath.mulWad(123e18, 1e18), 123e18);
        assertEq(FixedPointMath.mulWad(1e18, 456e18), 456e18);
    }

    function test_mulWad_fractions() public pure {
        // 0.5 × 2 = 1
        assertEq(FixedPointMath.mulWad(0.5e18, 2e18), 1e18);
        // 0.25 × 4 = 1
        assertEq(FixedPointMath.mulWad(0.25e18, 4e18), 1e18);
    }

    function test_divWad_identity() public pure {
        // Dividing by 1e18 (1.0 in WAD) should return original
        assertEq(FixedPointMath.divWad(123e18, 1e18), 123e18);
    }

    function test_divWad_fractions() public pure {
        // 1 ÷ 2 = 0.5
        assertEq(FixedPointMath.divWad(1e18, 2e18), 0.5e18);
        // 3 ÷ 4 = 0.75
        assertEq(FixedPointMath.divWad(3e18, 4e18), 0.75e18);
    }

    function test_exp_smallPositive() public pure {
        // exp(0.5) ≈ 1.648721
        uint256 result = FixedPointMath.exp(0.5e18);
        assertApproxEqRel(result, 1.648721270700128147e18, 0.001e18);
    }

    function test_exp_largePositive() public pure {
        // exp(2) ≈ 7.389056
        uint256 result = FixedPointMath.exp(2e18);
        assertApproxEqRel(result, 7.389056098930650227e18, 0.001e18);
    }

    function test_ln_largeValue() public pure {
        // ln(10) ≈ 2.302585
        uint256 result = FixedPointMath.ln(10e18);
        assertApproxEqRel(result, 2.302585092994045684e18, 0.001e18);
    }

    // ========== ADVANCED FUZZ TESTS ==========

    /// @dev Fuzz test: mulWad and divWad are inverses
    function testFuzz_mulDivInverse(uint256 a, uint256 b) public pure {
        // Bound to prevent overflow
        a = bound(a, 1e18, type(uint128).max);
        b = bound(b, 1e18, type(uint128).max);

        uint256 product = FixedPointMath.mulWad(a, b);
        uint256 quotient = FixedPointMath.divWad(product, b);
        
        // Allow for small rounding error (0.1%)
        assertApproxEqRel(quotient, a, 0.001e18);
    }

    /// @dev Fuzz test: exp and ln are inverses
    function testFuzz_expLnInverse(uint256 x) public pure {
        // Bound to safe range for exp/ln
        x = bound(x, 0.01e18, 10e18); // 0.01 to 10

        uint256 expX = FixedPointMath.exp(x);
        uint256 lnExpX = FixedPointMath.ln(expX);
        
        // Allow for small rounding error (0.1%)
        assertApproxEqRel(lnExpX, x, 0.001e18);
    }

    /// @dev Fuzz test: fromWadRoundUp always >= fromWad
    function testFuzz_roundUpAlwaysGreaterOrEqual(uint256 wad) public pure {
        wad = bound(wad, 0, type(uint256).max);
        
        uint256 rounded = FixedPointMath.fromWad(wad);
        uint256 roundedUp = FixedPointMath.fromWadRoundUp(wad);
        
        assertGe(roundedUp, rounded);
    }

    /// @dev Fuzz test: mulWad commutativity (a × b = b × a)
    function testFuzz_mulWadCommutative(uint256 a, uint256 b) public pure {
        a = bound(a, 0, type(uint128).max);
        b = bound(b, 0, type(uint128).max);
        
        uint256 ab = FixedPointMath.mulWad(a, b);
        uint256 ba = FixedPointMath.mulWad(b, a);
        
        assertEq(ab, ba);
    }

    /// @dev Fuzz test: mulWad associativity (a × (b × c) = (a × b) × c)
    function testFuzz_mulWadAssociative(uint256 a, uint256 b, uint256 c) public pure {
        a = bound(a, 1e18, type(uint64).max);
        b = bound(b, 1e18, type(uint64).max);
        c = bound(c, 1e18, type(uint64).max);
        
        uint256 abc1 = FixedPointMath.mulWad(a, FixedPointMath.mulWad(b, c));
        uint256 abc2 = FixedPointMath.mulWad(FixedPointMath.mulWad(a, b), c);
        
        // Allow for small rounding error due to order of operations
        assertApproxEqRel(abc1, abc2, 0.001e18);
    }

    /// @dev Fuzz test: Conversion bounds
    function testFuzz_conversionBounds(uint256 usdc) public pure {
        usdc = bound(usdc, 0, type(uint128).max / 1e12);
        
        uint256 wad = FixedPointMath.toWad(usdc);
        
        // WAD should be usdc × 1e12
        assertEq(wad, usdc * 1e12);
        
        // Round trip should preserve value
        uint256 backToUsdc = FixedPointMath.fromWad(wad);
        assertEq(backToUsdc, usdc);
    }

    // ========== UTILITY FUNCTIONS ==========

    function test_getPrecision() public pure {
        assertEq(FixedPointMath.getPrecision(), 1e6);
    }
}
