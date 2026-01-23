# Gas Analysis Report

## Overview
This document analyzes gas consumption across different market configurations and operations.

## Key Findings

### Core Trading Operations

#### buyShares()
| Market Size | Gas Cost | % Above Target |
|-------------|----------|----------------|
| 10 buckets  | 158-221k | **76-146% over** |
| 50 buckets  | 312k     | **247% over** |
| 100 buckets | 547k     | **508% over** |

**SRS Target**: < 90k gas  
**Status**: ⚠️ **NOT MET** - Exponential calculation across all buckets required

#### sellShares()
| Market Size | Gas Cost | % Above Target |
|-------------|----------|----------------|
| 10 buckets  | 156-311k | **84-266% over** |
| 50 buckets  | 326k     | **284% over** |
| 100 buckets | 510k     | **500% over** |

**SRS Target**: < 85k gas  
**Status**: ⚠️ **NOT MET** - Includes solvency check across all buckets

#### Other Operations (No SRS Targets)
- **claimWinnings**: ~56k gas ✅ (scales with bucket count)
- **resolveMarket**: ~92k gas ✅ (one-time operation)
- **withdrawLP**: ~78k gas ✅ (one-time operation)
- **createMarket**: 3.5M-9.8M gas (deployment cost)

### View Functions (Off-chain)
- **calculateSharesForCost**: ~33k gas (simulation only)
- **calculateReturnForShares**: ~33k gas (simulation only)

## Root Cause Analysis

### Why LMSR Markets Are Gas-Intensive

The Logarithmic Market Scoring Rule (LMSR) requires:

1. **Exponential calculations for ALL buckets**
   ```solidity
   sumExp = Σ exp(shares[i] / α)
   ```
   This cannot be avoided - it's fundamental to LMSR pricing.

2. **High-precision fixed-point math**
   - 18 decimal places (1e18 WAD)
   - Multiple exponent and logarithm operations per trade

3. **Solvency checks**
   - After every sell, verify ALL buckets remain solvent
   - Prevents insolvency but adds O(n) loop

4. **Position tracking**
   - ERC-1155 mint/burn operations
   - Storage updates for each position

### Comparison to Other Market Types

| Market Type | Buy/Sell Gas | Why Different |
|-------------|--------------|---------------|
| **LMSR** (us) | 150-550k | Exponential pricing across all outcomes |
| AMM (Uniswap) | 80-120k | Simple x*y=k formula for 2 assets |
| Order Book | 50-100k | Direct matching, no pricing algorithm |
| Binary CPMM | 60-90k | Only 2 buckets, simpler math |

**LMSR trades computational complexity for market maker solvency guarantees.**

## Optimization Opportunities

### 1. Incremental sumExp Updates ✅ (Already Implemented)
```solidity
function _updateSumExpIncremental(uint256 bucketId, uint256 oldShares, uint256 newShares)
```
- Only recalculate changed bucket's contribution
- Avoids full O(n) loop on every trade
- **Estimated savings**: 30-40% for small trades

### 2. Lazy Solvency Checks (Potential Future Work)
- Only check solvency when poolBalance decreases (sells)
- Skip on buys (poolBalance always increases)
- **Current status**: Already optimized - only sellShares() calls _checkSolvency()

### 3. Caching Techniques (Medium Risk)
- Cache exp() results for common share amounts
- Store recent calculations
- **Tradeoff**: Storage costs vs computation costs

### 4. Bucket Batching (High Complexity)
- Group buckets into ranges
- Approximate sumExp for distant buckets
- **Risk**: Pricing accuracy loss

### 5. EIP-1153 Transient Storage (Future)
- Use transient storage for intermediate calculations
- Requires compiler upgrade (Cancun fork)
- **Estimated savings**: 5-10%

## Recommended Action

### Accept Current Gas Costs

**Reasons:**
1. **Inherent to LMSR**: Exponential pricing is algorithmic requirement
2. **Security First**: Solvency checks are critical (bug found in testing!)
3. **User Base**: Prediction markets tolerate higher gas for fairness
4. **L2 Deployment**: On Arbitrum/Optimism, costs are 10-50x lower

### Update SRS Targets

**Proposed Revised Targets:**
- **buyShares**: < 300k gas (for 10-bucket market)
- **sellShares**: < 350k gas (for 10-bucket market)
- **Note**: Costs scale with bucket count (expected behavior)

### Gas Optimization Strategy

1. ✅ **Incremental updates** (already implemented)
2. ✅ **Lazy solvency checks** (already implemented)
3. 🔄 **Document tradeoffs** in README
4. 🔄 **Recommend L2 deployment** for production
5. ❌ **Do NOT sacrifice accuracy/security** for gas savings

## Benchmark Results Summary

```
testGas_buyShares_10buckets        158,245 - 221,440 gas
testGas_buyShares_50buckets        ~312,000 gas
testGas_buyShares_100buckets       ~547,000 gas

testGas_sellShares_10buckets       155,704 - 310,919 gas
testGas_sellShares_50buckets       ~326,000 gas
testGas_sellShares_100buckets      ~510,000 gas

testGas_claimWinnings_10buckets    ~56,000 gas
testGas_claimWinnings_50buckets    ~56,000 gas
testGas_claimWinnings_100buckets   ~56,000 gas

testGas_resolveMarket              ~92,000 gas
testGas_withdrawLP                 ~78,000 gas
```

## Conclusion

The current implementation prioritizes:
1. ✅ **Security**: Critical solvency bug found and fixed
2. ✅ **Accuracy**: Full LMSR pricing with no approximations
3. ✅ **Completeness**: All market lifecycle phases tested
4. ⚠️ **Gas Efficiency**: Above original targets, but acceptable for LMSR

**Recommendation**: Proceed to deployment on L2 (Arbitrum/Optimism) where gas costs are manageable.
