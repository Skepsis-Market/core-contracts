// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {FixedPointMath} from "../src/FixedPointMath.sol";

/// @notice Debug test to trace LMSR calculations step by step
contract DebugLMSRTest is Test {
    using FixedPointMath for uint256;
    
    uint256 constant WAD = 1e18;
    uint256 constant PHANTOM_SHARES = 1;
    
    /// @notice Integer square root (matches Sui's simple_integer_sqrt)
    function _sqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;
        if (x <= 3) return 1;
        
        uint256 low = 1;
        uint256 high = x / 2 + 1;
        uint256 result = 0;
        
        while (low <= high) {
            uint256 mid = (low + high) / 2;
            uint256 square = mid * mid;
            
            if (square == x) {
                return mid;
            } else if (square < x) {
                result = mid;
                low = mid + 1;
            } else {
                high = mid - 1;
            }
        }
        
        return result;
    }
    
    function test_trace_full_calculation() public view {
        console.log("=== STEP-BY-STEP LMSR CALCULATION DEBUG ===\n");
        
        // Market parameters (matching Sui test)
        uint256 poolBalance = 10_000_000_000; // $10K in 6 decimals
        uint256 bucketCount = 100;
        
        console.log("INPUTS:");
        console.log("  poolBalance (6 dec):", poolBalance);
        console.log("  bucketCount:", bucketCount);
        console.log("");
        
        // ===== STEP 1: ALPHA CALCULATION =====
        console.log("STEP 1: ALPHA CALCULATION (matching Sui's sqrt formula)");
        
        // Sui formula: alpha = pool / sqrt(n)
        uint256 sqrtN = _sqrt(bucketCount);
        console.log("  sqrt(100):", sqrtN);
        
        uint256 alpha = poolBalance / sqrtN;
        console.log("  alpha = pool / sqrt(n):", alpha);
        console.log("  alpha as USDC: $", alpha / 1_000_000);
        console.log("");
        
        // ===== STEP 2: INITIAL SHARES & EXP_SUM =====
        console.log("STEP 2: INITIAL STATE");
        
        uint256 initialShares = poolBalance / bucketCount;
        console.log("  initialShares per bucket (6 dec):", initialShares);
        console.log("  initialShares as USDC: $", initialShares / 1_000_000);
        
        // Calculate one bucket's exp contribution
        uint256 q = initialShares + PHANTOM_SHARES;
        console.log("  q (shares + phantom):", q);
        
        uint256 ratio = (q * WAD) / alpha;
        console.log("  ratio = (q * WAD) / alpha:", ratio);
        console.log("  ratio as decimal:", ratio * 10000 / WAD, "/ 10000");
        
        uint256 oneExp = ratio.exp();
        console.log("  exp(ratio) [one bucket]:", oneExp);
        console.log("  exp(ratio) as decimal:", oneExp * 10000 / WAD, "/ 10000");
        
        uint256 sumExp = bucketCount * oneExp;
        console.log("  sumExp (100 buckets):", sumExp);
        console.log("");
        
        // ===== STEP 3: COST FUNCTION =====
        console.log("STEP 3: COST FUNCTION C(q)");
        
        uint256 lnSum = sumExp.ln();
        console.log("  ln(sumExp) in WAD:", lnSum);
        console.log("  ln(sumExp) as decimal:", lnSum * 1000 / WAD, "/ 1000");
        
        uint256 C_before = (alpha * lnSum) / WAD;
        console.log("  C_before = (alpha * lnSum) / WAD:", C_before);
        console.log("  C_before as USDC: $", C_before / 1_000_000);
        console.log("");
        
        // ===== STEP 4: BUY $10 IN BUCKET 45 =====
        console.log("STEP 4: BUY $10 (after 0.5% fee = $9.95 net)");
        
        uint256 netCostUSDC = 9_950_000; // $9.95 in 6 decimals
        uint256 C_new = C_before + netCostUSDC;
        console.log("  netCostUSDC (6 dec):", netCostUSDC);
        console.log("  C_new = C_before + netCost:", C_new);
        console.log("");
        
        // ===== STEP 5: INVERSE LMSR - FIND NEW SHARES =====
        console.log("STEP 5: INVERSE LMSR CALCULATION");
        
        // sumOther = sum of exp for 99 other buckets
        uint256 sumOther = 99 * oneExp;
        console.log("  sumOther (99 buckets):", sumOther);
        
        // exp(C_new / alpha)
        uint256 ratioC = (C_new * WAD) / alpha;
        console.log("  C_new / alpha in WAD:", ratioC);
        console.log("  C_new / alpha as decimal:", ratioC * 1000 / WAD, "/ 1000");
        
        uint256 expCNewOverAlpha = ratioC.exp();
        console.log("  exp(C_new / alpha):", expCNewOverAlpha);
        console.log("");
        
        // innerTerm = exp(C_new/alpha) - sumOther
        console.log("CRITICAL CALCULATION:");
        console.log("  expCNewOverAlpha:", expCNewOverAlpha);
        console.log("  sumOther:", sumOther);
        
        uint256 innerTerm = expCNewOverAlpha - sumOther;
        console.log("  innerTerm = expCNew - sumOther:", innerTerm);
        console.log("  innerTerm as decimal:", innerTerm * 10000 / WAD, "/ 10000");
        
        // ln(innerTerm) 
        uint256 lnInner = innerTerm.ln();
        console.log("  ln(innerTerm) in WAD:", lnInner);
        console.log("  ln(innerTerm) as decimal:", lnInner * 10000 / WAD, "/ 10000");
        
        // newSharesWithPhantom = alpha * ln(innerTerm)
        uint256 newSharesWithPhantom = (alpha * lnInner) / WAD;
        console.log("  newSharesWithPhantom = (alpha * lnInner) / WAD:", newSharesWithPhantom);
        
        uint256 newShares = newSharesWithPhantom - PHANTOM_SHARES;
        console.log("  newShares (- phantom):", newShares);
        
        uint256 sharesMinted = newShares - initialShares;
        console.log("  sharesMinted = newShares - oldShares:", sharesMinted);
        console.log("  sharesMinted as USDC value: $", sharesMinted / 1_000_000);
        console.log("");
        
        console.log("=== COMPARISON ===");
        console.log("  Solidity sharesMinted:", sharesMinted);
        console.log("  Sui expected:         289306640");
        console.log("  Difference:", sharesMinted > 289306640 ? sharesMinted - 289306640 : 289306640 - sharesMinted);
        console.log("  Ratio (Sol/Sui):", (sharesMinted * 100) / 289306640, "/ 100");
    }
    
    function test_forward_cost_for_sui_shares() public view {
        console.log("=== FORWARD COST: 289M SHARES **PER BUCKET** (3 BUCKETS) ===\n");
        
        // Market parameters
        uint256 poolBalance = 10_000_000_000;
        uint256 bucketCount = 100;
        uint256 alpha = poolBalance / _sqrt(bucketCount); // $1000
        
        uint256 initialShares = poolBalance / bucketCount; // $100 per bucket
        
        // Calculate C_before (uniform distribution)
        uint256 q = initialShares + PHANTOM_SHARES;
        uint256 ratio = (q * WAD) / alpha;
        uint256 oneExp = ratio.exp();
        uint256 sumExp = bucketCount * oneExp;
        uint256 lnSum = sumExp.ln();
        uint256 C_before = (alpha * lnSum) / WAD;
        
        console.log("C_before (uniform):", C_before);
        console.log("  C_before as USDC:", C_before / 1_000_000);
        
        // Sui adds 289M shares to EACH of 3 buckets (not divided!)
        uint256 numBuckets = 3;
        uint256 suiSharesPerBucket = 289_306_640; // Added to EACH bucket
        
        console.log("\nBuying 289M shares into EACH of 3 buckets");
        console.log("  Total shares added:", suiSharesPerBucket * numBuckets);
        
        uint256 newBucketShares = initialShares + suiSharesPerBucket;
        
        // New exp for each of the 3 buckets
        uint256 newQ = newBucketShares + PHANTOM_SHARES;
        uint256 newRatio = (newQ * WAD) / alpha;
        uint256 newExp = newRatio.exp();
        
        console.log("Each modified bucket:");
        console.log("  new shares:", newBucketShares);
        console.log("  newRatio:", newRatio);
        console.log("  newExp:", newExp);
        
        // New sumExp = 97 unchanged buckets + 3 modified buckets
        uint256 newSumExp = (bucketCount - numBuckets) * oneExp + numBuckets * newExp;
        uint256 newLnSum = newSumExp.ln();
        uint256 C_after = (alpha * newLnSum) / WAD;
        
        console.log("C_after:", C_after);
        console.log("  C_after as USDC:", C_after / 1_000_000);
        
        uint256 cost = C_after - C_before;
        console.log("\n=== COST FOR 289M SHARES x 3 BUCKETS ===");
        console.log("  Cost (6 dec):", cost);
        console.log("  Cost in USDC: $", cost / 1_000_000);
        console.log("  Expected (Sui): ~$9.95 (after 0.5% fee from $10)");
    }
    
    function test_compare_6dec_vs_18dec_exp() public view {
        console.log("=== COMPARING 6-DEC vs 18-DEC EXP/LN ===\n");
        
        uint256 PRECISION_6 = 1_000_000;
        uint256 alpha = 1_000_000_000; // $1000 in 6 dec
        uint256 shares = 100_000_000;  // $100 in 6 dec
        
        // 18-dec calculation (PRB-Math)
        uint256 ratio18 = (shares * WAD) / alpha; // 0.1 in WAD
        uint256 exp18 = ratio18.exp();
        console.log("18-dec ratio:", ratio18);
        console.log("18-dec exp(0.1):", exp18);
        console.log("  as decimal:", exp18 * 1000000 / WAD, "/ 1000000");
        
        // 6-dec calculation (simulating Sui's Taylor series)
        uint256 ratio6 = (shares * PRECISION_6) / alpha; // 100000 (0.1 in 6 dec)
        uint256 exp6 = _exp6(ratio6);
        console.log("6-dec ratio:", ratio6);
        console.log("6-dec exp(0.1):", exp6);
        console.log("  as decimal:", exp6 * 1000000 / PRECISION_6, "/ 1000000");
        
        // For 389M shares (after buying 289M)
        uint256 newShares = 389_306_640;
        uint256 newRatio18 = (newShares * WAD) / alpha;
        uint256 newExp18 = newRatio18.exp();
        console.log("\n389M shares:");
        console.log("18-dec exp(0.389):", newExp18);
        
        uint256 newRatio6 = (newShares * PRECISION_6) / alpha;
        uint256 newExp6 = _exp6(newRatio6);
        console.log("6-dec exp(0.389):", newExp6);
        
        // Calculate costs
        uint256 oldSumExp18 = 100 * exp18;
        uint256 newSumExp18 = 99 * exp18 + newExp18;
        uint256 lnOld18 = oldSumExp18.ln();
        uint256 lnNew18 = newSumExp18.ln();
        uint256 C_before18 = (alpha * lnOld18) / WAD;
        uint256 C_after18 = (alpha * lnNew18) / WAD;
        console.log("\n18-dec cost:", C_after18 - C_before18);
        
        uint256 oldSumExp6 = 100 * exp6;
        uint256 newSumExp6 = 99 * exp6 + newExp6;
        uint256 lnOld6 = _ln6(oldSumExp6);
        uint256 lnNew6 = _ln6(newSumExp6);
        uint256 C_before6 = (alpha * lnOld6) / PRECISION_6;
        uint256 C_after6 = (alpha * lnNew6) / PRECISION_6;
        console.log("6-dec cost:", C_after6 - C_before6);
    }
    
    /// @notice 6-decimal exp using Taylor series (matching Sui)
    function _exp6(uint256 x) internal pure returns (uint256) {
        uint256 PRECISION_6 = 1_000_000;
        if (x == 0) return PRECISION_6;
        
        uint256 result = PRECISION_6;
        uint256 term = PRECISION_6;
        
        for (uint256 i = 1; i <= 8; i++) {
            term = (term * x) / (i * PRECISION_6);
            result += term;
            if (term < 10) break;
        }
        return result;
    }
    
    /// @notice 6-decimal ln (simplified)
    function _ln6(uint256 x) internal pure returns (uint256) {
        // For simplicity, use PRB-Math ln and scale
        uint256 PRECISION_6 = 1_000_000;
        uint256 scaledX = x * (WAD / PRECISION_6); // Scale to WAD
        uint256 lnWad = scaledX.ln();
        return (lnWad * PRECISION_6) / WAD;
    }
}
