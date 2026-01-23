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
}
