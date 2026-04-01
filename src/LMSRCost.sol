// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {FixedPointMath} from "./FixedPointMath.sol";
import {Math} from "@openzeppelin/utils/math/Math.sol";

/// @title LMSRCost — Pure math library for LMSR cost computations via segment tree
/// @notice Replaces the O(k) per-bucket loop + binary search with algebraic O(1) math.
///         Works with BucketTree to provide O(log n) range trades.
/// @dev All functions are pure/view — no state mutations.
///
///      LMSR cost formula: C(q) = α × ln(Σ exp(q_i / α))
///      Cost of trade: ΔC = α × ln(sumAfter / sumBefore)
///
///      For uniform range trades (same Δq to each bucket in [lo, hi]):
///        factor = exp(Δq / α)
///        sumAfter = sumBefore - rangeSum + rangeSum × factor
///        cost = α × ln(sumAfter / sumBefore)
///
///      Correlated with:
///        - Signals Protocol: ClmsrMath (same algebraic solve pattern)
///        - Current LMSRMarket: _calculateRangeBuyCost, _findMaxSharesForRange
library LMSRCost {
    using FixedPointMath for uint256;

    uint256 internal constant WAD = 1e18;

    error ZeroAlpha();
    error ZeroSum();
    error InvalidCost();

    /// @notice Cost of a buy: α × ln(sumAfter / sumBefore)
    /// @param alpha Liquidity parameter (6 decimals, USDC precision)
    /// @param sumBefore Total exp-weight sum before trade (WAD)
    /// @param sumAfter Total exp-weight sum after trade (WAD)
    /// @return cost Cost in 6 decimals (USDC)
    function costFromDelta(
        uint256 alpha,
        uint256 sumBefore,
        uint256 sumAfter
    ) internal pure returns (uint256 cost) {
        if (sumAfter <= sumBefore) return 0;
        // ln(sumAfter) - ln(sumBefore), both in WAD
        uint256 lnAfter = sumAfter.ln();
        uint256 lnBefore = sumBefore.ln();
        // alpha (6 dec) × delta_ln (WAD) / WAD → 6 dec
        cost = (alpha * (lnAfter - lnBefore)) / WAD;
    }

    /// @notice Proceeds from a sell: α × ln(sumBefore / sumAfter)
    /// @param alpha Liquidity parameter (6 decimals)
    /// @param sumBefore Total exp-weight sum before trade (WAD)
    /// @param sumAfter Total exp-weight sum after trade (WAD)
    /// @return proceeds Proceeds in 6 decimals (USDC)
    function proceedsFromDelta(
        uint256 alpha,
        uint256 sumBefore,
        uint256 sumAfter
    ) internal pure returns (uint256 proceeds) {
        if (sumAfter >= sumBefore) return 0;
        uint256 lnBefore = sumBefore.ln();
        uint256 lnAfter = sumAfter.ln();
        proceeds = (alpha * (lnBefore - lnAfter)) / WAD;
    }

    /// @notice Convert share delta to multiplicative factor for tree
    /// @dev factor = exp(deltaShares / alpha)
    ///      For a uniform range buy of Δq shares per bucket:
    ///        Each bucket's exp weight gets multiplied by this factor.
    /// @param deltaShares Shares to add per bucket (6 decimals)
    /// @param alpha Liquidity parameter (6 decimals)
    /// @return factor Multiplicative factor (WAD)
    function sharesToFactor(
        uint256 deltaShares,
        uint256 alpha
    ) internal pure returns (uint256 factor) {
        if (alpha == 0) revert ZeroAlpha();
        // (deltaShares * WAD) / alpha → WAD-scaled ratio
        uint256 ratio = (deltaShares * WAD) / alpha;
        factor = ratio.exp();
    }

    /// @notice Inverse factor for sells: exp(-deltaShares / alpha) = 1 / exp(deltaShares / alpha)
    /// @param deltaShares Shares to remove per bucket (6 decimals)
    /// @param alpha Liquidity parameter (6 decimals)
    /// @return inverseFactor Multiplicative factor < 1.0 (WAD)
    function sharesToInverseFactor(
        uint256 deltaShares,
        uint256 alpha
    ) internal pure returns (uint256 inverseFactor) {
        uint256 factor = sharesToFactor(deltaShares, alpha);
        // 1/factor = WAD * WAD / factor (round up for conservative sell)
        inverseFactor = Math.mulDiv(WAD, WAD, factor);
    }

    /// @notice Algebraically solve for shares given a USDC budget — replaces binary search
    /// @dev Derivation:
    ///        cost = α × ln(sumAfter / sumBefore)
    ///        sumAfter = sumBefore × exp(cost / α)
    ///        sumAfter = (sumBefore - rangeSum) + rangeSum × factor
    ///        factor = (sumAfter - sumBefore + rangeSum) / rangeSum
    ///        shares = α × ln(factor)
    ///
    ///      This is O(1) math vs the 20-iteration binary search.
    ///      Correlated with: Signals' ClmsrMath.calculateQuantityFromCost
    ///
    /// @param alpha Liquidity parameter (6 decimals)
    /// @param _totalSum Tree total sum (WAD)
    /// @param _rangeSum Sum of exp weights in target range [lo, hi] (WAD)
    /// @param budget Maximum cost in 6 decimals (USDC)
    /// @return shares Maximum shares per bucket (6 decimals)
    function sharesFromCost(
        uint256 alpha,
        uint256 _totalSum,
        uint256 _rangeSum,
        uint256 budget
    ) internal pure returns (uint256 shares) {
        if (alpha == 0) revert ZeroAlpha();
        if (_totalSum == 0 || _rangeSum == 0) revert ZeroSum();
        if (budget == 0) return 0;

        // sumAfter = sumBefore × exp(budget / alpha)
        uint256 ratio = (budget * WAD) / alpha; // WAD
        uint256 expValue = ratio.exp(); // WAD
        uint256 targetSumAfter = Math.mulDiv(_totalSum, expValue, WAD); // WAD

        // requiredRangeSum = targetSumAfter - (sumBefore - rangeSum)
        //                  = targetSumAfter - sumBefore + rangeSum
        uint256 nonRangeSum = _totalSum - _rangeSum;
        if (targetSumAfter <= nonRangeSum) return 0; // Budget too small
        uint256 requiredRangeSum = targetSumAfter - nonRangeSum;

        // factor = requiredRangeSum / rangeSum (WAD division)
        uint256 factor = Math.mulDiv(requiredRangeSum, WAD, _rangeSum); // WAD

        if (factor <= WAD) return 0; // Factor ≤ 1.0 means no shares

        // shares = α × ln(factor)
        uint256 lnFactor = factor.ln(); // WAD
        shares = (alpha * lnFactor) / WAD; // 6 dec
    }
}
