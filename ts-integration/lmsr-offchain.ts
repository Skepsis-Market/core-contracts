/**
 * Off-chain LMSR math — mirrors the on-chain Solidity formulas exactly.
 *
 * This module is what the FE integration guide (Section 7) recommends:
 * all slider/input changes use these functions (zero RPC calls).
 *
 * Precision: JavaScript Number (float64, ~15 significant digits).
 * Good enough for UI display; on-chain tx uses targetShares as hint
 * and the contract does its own WAD-precision math.
 */

// ── Constants ────────────────────────────────────────────────────────
export const PHANTOM = 1;         // PHANTOM_SHARES in contract (1 = 0.000001 in 6-dec)
export const USDC_DECIMALS = 6;
export const USDC_SCALE = 1_000_000;

// ── Types ────────────────────────────────────────────────────────────

export interface BucketData {
  shares: bigint;       // 6 decimals
  lowerBound: bigint;
  upperBound: bigint;
}

export interface MarketState {
  alpha: bigint;        // 6 decimals
  bucketCount: number;
  buckets: BucketData[];
  feeBps: number;
  poolBalance: bigint;
  marketMin: bigint;
  marketMax: bigint;
  bucketWidth: bigint;
}

export interface TradePreview {
  impliedProbability: number;
  shares: number;              // float USDC-equivalent (6-dec scaled down)
  cost: number;                // float USDC-equivalent
  odds: number;                // shares / cost
  potentialPayout: number;     // shares (1 share = $1 on win)
  returnMultiplier: number;    // payout / amountUSDC
  probabilitiesBefore: number[];
  probabilitiesAfter: number[];
  rangeProbBefore: number;
  rangeProbAfter: number;
  probabilityShift: number;
  targetSharesBigInt: bigint;  // For fast-path on-chain submission
}

// ── Helpers ──────────────────────────────────────────────────────────

export function toFloat(val: bigint): number {
  return Number(val) / USDC_SCALE;
}

export function toBigInt6(val: number): bigint {
  return BigInt(Math.round(val * USDC_SCALE));
}

// ── Core LMSR ────────────────────────────────────────────────────────

/** Range → bucket indices (matching _rangeToBuckets in Solidity) */
export function rangeToBuckets(
  state: MarketState,
  lower: bigint,
  upper: bigint
): [number, number] {
  const start = Number((lower - state.marketMin) / state.bucketWidth);
  const end = Number((upper - state.marketMin) / state.bucketWidth) - 1;
  return [start, end];
}

/**
 * Compute probability for each bucket.
 * P[i] = exp(q_i / α) / Σ exp(q_j / α)
 */
export function computeProbabilities(state: MarketState): number[] {
  const alpha = toFloat(state.alpha);
  const exps = state.buckets.map(b => {
    const q = toFloat(b.shares) + toFloat(BigInt(PHANTOM));
    return Math.exp(q / alpha);
  });
  const sum = exps.reduce((a, b) => a + b, 0);
  return exps.map(e => e / sum);
}

/** Probability that the outcome falls within [lower, upper) */
export function computeRangeProbability(
  state: MarketState,
  lower: bigint,
  upper: bigint
): number {
  const [start, end] = rangeToBuckets(state, lower, upper);
  const probs = computeProbabilities(state);
  let p = 0;
  for (let i = start; i <= end; i++) p += probs[i];
  return p;
}

/**
 * LMSR cost function: C(q) = α × ln(Σ exp((q_i + phantom) / α))
 * Optionally override specific bucket shares.
 */
export function costFunction(
  state: MarketState,
  overrides?: Map<number, bigint>
): number {
  const alpha = toFloat(state.alpha);
  let sumExp = 0;
  for (let i = 0; i < state.bucketCount; i++) {
    const shares = overrides?.get(i) ?? state.buckets[i].shares;
    const q = toFloat(shares) + toFloat(BigInt(PHANTOM));
    sumExp += Math.exp(q / alpha);
  }
  return alpha * Math.log(sumExp);
}

// ── Single Bucket Buy (closed-form inverse) ─────────────────────────

export function calculateSingleBucketShares(
  state: MarketState,
  bucketId: number,
  amountUSDC: bigint
): { shares: number; cost: number; odds: number } {
  const fees = toFloat(amountUSDC) * state.feeBps / 10000;
  const net = toFloat(amountUSDC) - fees;
  const alpha = toFloat(state.alpha);

  // C_before
  const cBefore = costFunction(state);

  // sumOther = Σ exp(q_j/α) for j ≠ bucketId
  const allExps = state.buckets.map(b => {
    const q = toFloat(b.shares) + toFloat(BigInt(PHANTOM));
    return Math.exp(q / alpha);
  });
  const sumOther = allExps.reduce((a, b) => a + b, 0) - allExps[bucketId];

  // Inverse: new_q = α × ln(exp(C_new/α) - sumOther)
  const cNew = cBefore + net;
  const expCNew = Math.exp(cNew / alpha);
  const inner = expCNew - sumOther;
  if (inner <= 0) return { shares: 0, cost: 0, odds: 0 };

  const newQ = alpha * Math.log(inner);
  const oldQ = toFloat(state.buckets[bucketId].shares) + toFloat(BigInt(PHANTOM));
  const sharesAdded = newQ - oldQ;

  return {
    shares: Math.max(0, sharesAdded),
    cost: net,
    odds: sharesAdded > 0 ? sharesAdded / net : 0,
  };
}

// ── Range Buy (binary search, matching on-chain _findMaxSharesForRange) ──

export function calculateRangeShares(
  state: MarketState,
  rangeLower: bigint,
  rangeUpper: bigint,
  amountUSDC: bigint
): { shares: number; cost: number; odds: number } {
  const [startBucket, endBucket] = rangeToBuckets(state, rangeLower, rangeUpper);

  const fees = toFloat(amountUSDC) * state.feeBps / 10000;
  const netAmount = toFloat(amountUSDC) - fees;

  const cBefore = costFunction(state);

  let low = 0;
  let high = toFloat(state.poolBalance);
  let bestShares = 0;
  let bestCost = 0;

  // 50 iterations for float precision (contract does 20 with bigint)
  for (let iter = 0; iter < 50; iter++) {
    const mid = (low + high) / 2;
    if (mid < 0.000001) { low = 0.000001; continue; }

    const overrides = new Map<number, bigint>();
    for (let b = startBucket; b <= endBucket; b++) {
      overrides.set(b, state.buckets[b].shares + toBigInt6(mid));
    }
    const cAfter = costFunction(state, overrides);
    const cost = cAfter - cBefore;

    if (cost <= netAmount) {
      bestShares = mid;
      bestCost = cost;
      if (cost >= netAmount * 0.9995) break;
      low = mid;
    } else {
      high = mid;
    }
    if (high - low < 0.0001) break;
  }

  return {
    shares: bestShares,
    cost: bestCost,
    odds: bestCost > 0 ? bestShares / bestCost : 0,
  };
}

// ── Sell Return ──────────────────────────────────────────────────────

export function calculateSellReturn(
  state: MarketState,
  bucketId: number,
  sharesToSell: bigint
): { grossReturn: number; netReturn: number } {
  const cBefore = costFunction(state);
  const overrides = new Map<number, bigint>();
  overrides.set(bucketId, state.buckets[bucketId].shares - sharesToSell);
  const cAfter = costFunction(state, overrides);
  const gross = cBefore - cAfter;
  const fees = gross * state.feeBps / 10000;
  return { grossReturn: gross, netReturn: gross - fees };
}

export function calculateRangeSellReturn(
  state: MarketState,
  rangeLower: bigint,
  rangeUpper: bigint,
  sharesToSell: bigint
): { grossReturn: number; netReturn: number } {
  const [start, end] = rangeToBuckets(state, rangeLower, rangeUpper);
  const cBefore = costFunction(state);
  const overrides = new Map<number, bigint>();
  for (let b = start; b <= end; b++) {
    overrides.set(b, state.buckets[b].shares - sharesToSell);
  }
  const cAfter = costFunction(state, overrides);
  const gross = cBefore - cAfter;
  const fees = gross * state.feeBps / 10000;
  return { grossReturn: gross, netReturn: gross - fees };
}

// ── Full Trade Preview (the slider handler) ──────────────────────────

export function computeTradePreview(
  state: MarketState,
  rangeLower: bigint,
  rangeUpper: bigint,
  amountUSDC: bigint
): TradePreview {
  const impliedProbability = computeRangeProbability(state, rangeLower, rangeUpper);
  const [startBucket, endBucket] = rangeToBuckets(state, rangeLower, rangeUpper);
  const isSingle = startBucket === endBucket;

  let shares: number, cost: number, odds: number;
  if (isSingle) {
    ({ shares, cost, odds } = calculateSingleBucketShares(state, startBucket, amountUSDC));
  } else {
    ({ shares, cost, odds } = calculateRangeShares(state, rangeLower, rangeUpper, amountUSDC));
  }

  const potentialPayout = shares;
  const returnMultiplier = toFloat(amountUSDC) > 0 ? potentialPayout / toFloat(amountUSDC) : 0;

  // Probabilities BEFORE trade
  const probsBefore = computeProbabilities(state);

  // Probabilities AFTER trade
  const postOverrides = new Map<number, bigint>();
  const sharesBig = toBigInt6(shares);
  for (let b = startBucket; b <= endBucket; b++) {
    postOverrides.set(b, state.buckets[b].shares + sharesBig);
  }
  const alpha = toFloat(state.alpha);
  const postExps = state.buckets.map((b, i) => {
    const s = postOverrides.get(i) ?? b.shares;
    const q = toFloat(s) + toFloat(BigInt(PHANTOM));
    return Math.exp(q / alpha);
  });
  const postSum = postExps.reduce((a, b) => a + b, 0);
  const probsAfter = postExps.map(e => e / postSum);

  let rangeProbBefore = 0, rangeProbAfter = 0;
  for (let b = startBucket; b <= endBucket; b++) {
    rangeProbBefore += probsBefore[b];
    rangeProbAfter += probsAfter[b];
  }

  return {
    impliedProbability,
    shares,
    cost,
    odds,
    potentialPayout,
    returnMultiplier,
    probabilitiesBefore: probsBefore,
    probabilitiesAfter: probsAfter,
    rangeProbBefore,
    rangeProbAfter,
    probabilityShift: rangeProbAfter - rangeProbBefore,
    targetSharesBigInt: sharesBig,
  };
}
