#!/usr/bin/env tsx
/**
 * Skepsis Market — Full Integration Test
 *
 * Steered by FE_INTEGRATION_GUIDE.md:
 *  1. Deploy all contracts on anvil (forge script)
 *  2. Read on-chain state via multicall
 *  3. Compare off-chain LMSR math vs on-chain quotes
 *  4. Execute trades and verify accounting
 *  5. Test LP vault lifecycle
 *  6. Test position display math
 *
 * Run:
 *   cd core-contracts
 *   anvil &                           # start local chain
 *   npx tsx ts-integration/integration-test.ts
 */

import {
  createPublicClient,
  createWalletClient,
  http,
  getAddress,
  type Address,
  type Hex,
  formatUnits,
  type PublicClient,
  type WalletClient,
  type Chain,
  defineChain,
  keccak256,
  toRlp,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { readFileSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";

import {
  type MarketState,
  type BucketData,
  computeProbabilities,
  computeRangeProbability,
  calculateSingleBucketShares,
  calculateRangeShares,
  calculateSellReturn,
  calculateRangeSellReturn,
  computeTradePreview,
  costFunction,
  toFloat,
  toBigInt6,
  rangeToBuckets,
} from "./lmsr-offchain.js";

// ═════════════════════════════════════════════════════════════════════
// CONFIG
// ═════════════════════════════════════════════════════════════════════

const __dirname = dirname(fileURLToPath(import.meta.url));
const ABIS_DIR = join(__dirname, "abis");

function loadArtifact(name: string) {
  const raw = JSON.parse(readFileSync(join(ABIS_DIR, `${name}.json`), "utf-8"));
  return { abi: raw.abi, bytecode: raw.bytecode.object as Hex };
}

const MockUSDCArtifact = loadArtifact("MockUSDC");
const LMSRMarketArtifact = loadArtifact("LMSRMarket");
const MarketFactoryArtifact = loadArtifact("MarketFactory");
const VaultArtifact = loadArtifact("Vault");
const PositionNFTArtifact = loadArtifact("PositionNFT");

// Anvil default accounts
const DEPLOYER_KEY =
  "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80" as Hex;
const TRADER_KEY =
  "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d" as Hex;
const LP_KEY =
  "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a" as Hex;

const deployer = privateKeyToAccount(DEPLOYER_KEY);
const trader = privateKeyToAccount(TRADER_KEY);
const lp = privateKeyToAccount(LP_KEY);

const RPC = "http://127.0.0.1:8545";

// Auto-detect chain ID from running anvil instance
let localChain: Chain;
let publicClient: PublicClient;
let deployerWallet: WalletClient;
let traderWallet: WalletClient;
let lpWallet: WalletClient;

async function initClients() {
  // Fetch chain ID from the node
  const rawClient = createPublicClient({ transport: http(RPC) });
  const chainId = await rawClient.getChainId();
  console.log(`  Detected chain ID: ${chainId}`);

  localChain = defineChain({
    id: chainId,
    name: "anvil-local",
    nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: { default: { http: [RPC] } },
  });

  publicClient = createPublicClient({ chain: localChain, transport: http(RPC) });

  function walletFor(key: Hex) {
    return createWalletClient({
      account: privateKeyToAccount(key),
      chain: localChain,
      transport: http(RPC),
    });
  }

  deployerWallet = walletFor(DEPLOYER_KEY);
  traderWallet = walletFor(TRADER_KEY);
  lpWallet = walletFor(LP_KEY);
}

// ═════════════════════════════════════════════════════════════════════
// HELPERS
// ═════════════════════════════════════════════════════════════════════

let passCount = 0;
let failCount = 0;
const failures: string[] = [];

function assert(
  condition: boolean,
  label: string,
  detail?: string
) {
  if (condition) {
    passCount++;
    console.log(`  ✅ ${label}`);
  } else {
    failCount++;
    const msg = detail ? `${label}: ${detail}` : label;
    failures.push(msg);
    console.log(`  ❌ ${label}${detail ? " — " + detail : ""}`);
  }
}

function assertClose(
  actual: number,
  expected: number,
  tolerancePct: number,
  label: string
) {
  if (expected === 0 && actual === 0) {
    assert(true, label);
    return;
  }
  const ref = Math.max(Math.abs(expected), 0.000001);
  const pctDiff = Math.abs(actual - expected) / ref * 100;
  const ok = pctDiff <= tolerancePct;
  assert(
    ok,
    `${label} (${pctDiff.toFixed(2)}% diff)`,
    ok ? undefined : `actual=${actual.toFixed(6)} expected=${expected.toFixed(6)} diff=${pctDiff.toFixed(2)}%`
  );
}

function usdc(n: number): bigint {
  return BigInt(Math.round(n * 1_000_000));
}

function fmtUsdc(val: bigint): string {
  return `$${formatUnits(val, 6)}`;
}

// ═════════════════════════════════════════════════════════════════════
// DEPLOY
// ═════════════════════════════════════════════════════════════════════

interface Addresses {
  usdc: Address;
  lmsrImpl: Address;
  positionNFT: Address;
  factory: Address;
  vault: Address;
  market: Address;
}

async function deployAll(): Promise<Addresses> {
  console.log("\n═══ LOADING DEPLOYED CONTRACTS ═══\n");

  const coreDir = join(__dirname, "..");
  let usdcAddr: Address, lmsrImpl: Address, positionNFT: Address,
      factory: Address, vault: Address, market: Address;

  // Read .env.local for deployed addresses
  const envContent = readFileSync(join(coreDir, ".env.local"), "utf-8");
  const env = Object.fromEntries(
    envContent.split("\n")
      .filter(l => l.includes("=") && !l.startsWith("#"))
      .map(l => { const [k, ...v] = l.split("="); return [k.trim(), v.join("=").trim()]; })
  );

  factory = getAddress(env.FACTORY_ADDRESS);
  usdcAddr = getAddress(env.USDC_ADDRESS);
  lmsrImpl = getAddress(env.LMSR_IMPL_ADDRESS);
  positionNFT = getAddress(env.POSITION_NFT_ADDRESS);
  vault = getAddress(env.VAULT_ADDRESS);
  market = getAddress(env.SAMPLE_MARKET_ADDRESS || env.MARKET_ADDRESS);

  // Verify factory is deployed with correct ABI
  const mc = (await publicClient.readContract({
    address: factory, abi: MarketFactoryArtifact.abi, functionName: "marketCount",
  })) as bigint;
  console.log(`  Factory has ${mc} markets`);

  console.log(`  MockUSDC:      ${usdcAddr}`);
  console.log(`  LMSRImpl:      ${lmsrImpl}`);
  console.log(`  PositionNFT:   ${positionNFT}`);
  console.log(`  MarketFactory: ${factory}`);
  console.log(`  Vault:         ${vault}`);
  console.log(`  Market:        ${market}`);

  // Check if existing market is still ACTIVE
  const marketStatus = (await publicClient.readContract({
    address: market, abi: LMSRMarketArtifact.abi, functionName: "status",
  })) as number;

  if (marketStatus !== 0) {
    console.log(`  Existing market status=${marketStatus} (not ACTIVE) — creating fresh market`);

    // Ensure deployer has USDC and vault has capital
    await send(deployerWallet, usdcAddr, MockUSDCArtifact.abi, "mint", [deployer.address, 500_000_000000n]);
    await send(deployerWallet, usdcAddr, MockUSDCArtifact.abi, "approve", [vault, 500_000_000000n]);

    // Deposit to vault (need capital for new market)
    try {
      await send(deployerWallet, vault, VaultArtifact.abi, "deposit", [100_000_000000n, deployer.address]);
      console.log("  Deposited 100K to vault");
    } catch { /* vault may already have enough */ }

    // Create new market: 10 buckets, $60K-$80K, $2K width
    const SEED = 10_000_000000n;
    const newMarketParams = [
      {
        alpha: SEED / 3n,
        seedAmount: SEED,
        minValue: 60000n,
        maxValue: 80000n,
        bucketCount: 10n,
        feeBps: 200n,
        protocolFeeBps: 2000n,
        alphaFinal: 0n,
        decayStart: 0n,
        decayDuration: 0n,
        name: "BTC/USD Integration Test",
        description: "Fresh market for integration testing",
        resolutionCriteria: "Test oracle",
        valueUnit: "USD",
        resolver: "0x0000000000000000000000000000000000000000" as Address,
        biddingDeadline: 0n,
        scheduledResolutionTime: 0n,
        minBetSize: 0n,
        maxBucketsPerRange: 0n,
      },
    ];

    await send(deployerWallet, factory, MarketFactoryArtifact.abi, "createMarket", newMarketParams);

    // Get the latest market
    const count = (await publicClient.readContract({
      address: factory, abi: MarketFactoryArtifact.abi, functionName: "marketCount",
    })) as bigint;
    market = (await publicClient.readContract({
      address: factory, abi: MarketFactoryArtifact.abi, functionName: "marketById", args: [count],
    })) as Address;

    console.log(`  New market created: ${market}`);
  }

  // Ensure trader + LP have USDC and approvals
  await send(deployerWallet, usdcAddr, MockUSDCArtifact.abi, "mint", [trader.address, 100_000_000000n]);
  await send(deployerWallet, usdcAddr, MockUSDCArtifact.abi, "mint", [lp.address, 500_000_000000n]);

  // Approve trader for market
  await send(traderWallet, usdcAddr, MockUSDCArtifact.abi, "approve", [market, 100_000_000000n]);

  console.log("\n═══ READY ═══\n");

  return { usdc: usdcAddr, lmsrImpl, positionNFT, factory, vault, market };
}

// ═════════════════════════════════════════════════════════════════════
// READ MARKET STATE (as FE guide Section 6a recommends)
// ═════════════════════════════════════════════════════════════════════

async function readMarketState(marketAddr: Address): Promise<MarketState> {
  const abi = LMSRMarketArtifact.abi;

  const [alpha, poolBalance, bucketCount, feeBps, marketMin, marketMax, bucketWidth] =
    (await Promise.all([
      publicClient.readContract({ address: marketAddr, abi, functionName: "alpha" }),
      publicClient.readContract({ address: marketAddr, abi, functionName: "poolBalance" }),
      publicClient.readContract({ address: marketAddr, abi, functionName: "bucketCount" }),
      publicClient.readContract({ address: marketAddr, abi, functionName: "feeBps" }),
      publicClient.readContract({ address: marketAddr, abi, functionName: "marketMin" }),
      publicClient.readContract({ address: marketAddr, abi, functionName: "marketMax" }),
      publicClient.readContract({ address: marketAddr, abi, functionName: "bucketWidth" }),
    ])) as [bigint, bigint, bigint, bigint, bigint, bigint, bigint];

  const count = Number(bucketCount);
  const buckets: BucketData[] = [];
  for (let i = 0; i < count; i++) {
    const b = (await publicClient.readContract({
      address: marketAddr,
      abi,
      functionName: "getBucket",
      args: [BigInt(i)],
    })) as { shares: bigint; lowerBound: bigint; upperBound: bigint };
    buckets.push({
      shares: b.shares,
      lowerBound: b.lowerBound,
      upperBound: b.upperBound,
    });
  }

  return {
    alpha,
    bucketCount: count,
    buckets,
    feeBps: Number(feeBps),
    poolBalance,
    marketMin,
    marketMax,
    bucketWidth,
  };
}

// ═════════════════════════════════════════════════════════════════════
// TEST SUITES
// ═════════════════════════════════════════════════════════════════════

async function testProbabilities(marketAddr: Address, state: MarketState) {
  console.log("\n─── TEST 1: Probability Distribution ───\n");

  // Initial state: all buckets have 0 shares + phantom → uniform distribution
  const probs = computeProbabilities(state);

  console.log("  Off-chain probabilities:");
  for (let i = 0; i < state.bucketCount; i++) {
    const lb = state.buckets[i].lowerBound;
    const ub = state.buckets[i].upperBound;
    console.log(`    Bucket ${i} ($${lb}K-$${ub}K): ${(probs[i] * 100).toFixed(2)}%`);
  }

  const sum = probs.reduce((a, b) => a + b, 0);
  assertClose(sum, 1.0, 0.01, "Probabilities sum to 1.0");

  // Check if market is fresh (all shares equal) — if so, verify uniform distribution
  const allSharesEqual = state.buckets.every(b => b.shares === state.buckets[0].shares);
  if (allSharesEqual) {
    const expected = 1 / state.bucketCount;
    for (let i = 0; i < state.bucketCount; i++) {
      assertClose(probs[i], expected, 0.1, `Bucket ${i} uniform probability`);
    }
  } else {
    console.log("  (Market has prior trades — skipping uniformity check)");
    // Verify each probability is in valid range
    for (let i = 0; i < state.bucketCount; i++) {
      assert(probs[i] > 0 && probs[i] < 1, `Bucket ${i} probability in (0,1): ${(probs[i]*100).toFixed(2)}%`);
    }
  }

  // Range probability: 3 buckets out of N
  const rangeProb = computeRangeProbability(
    state,
    state.marketMin + state.bucketWidth * 2n,
    state.marketMin + state.bucketWidth * 5n
  );
  assert(rangeProb > 0 && rangeProb < 1, `3-bucket range probability is valid: ${(rangeProb*100).toFixed(2)}%`);
}

async function testSingleBucketQuotes(marketAddr: Address, state: MarketState) {
  console.log("\n─── TEST 2: Single Bucket — On-Chain vs Off-Chain Quotes ───\n");

  const amounts = [10_000000n, 100_000000n, 1000_000000n]; // $10, $100, $1000
  const bucket = Math.floor(state.bucketCount / 2); // Middle bucket

  for (const amount of amounts) {
    // On-chain: calculateSharesForCost takes NET cost (after fees already deducted)
    const feesUsdc = (amount * BigInt(state.feeBps)) / 10000n;
    const netAmount = amount - feesUsdc;
    const onChainShares = (await publicClient.readContract({
      address: marketAddr,
      abi: LMSRMarketArtifact.abi,
      functionName: "calculateSharesForCost",
      args: [BigInt(bucket), netAmount],
    })) as bigint;

    // Off-chain: calculateSingleBucketShares takes GROSS amount (deducts fees internally)
    const offChain = calculateSingleBucketShares(state, bucket, amount);

    const onChainFloat = toFloat(onChainShares);
    const offChainFloat = offChain.shares;

    console.log(
      `  ${fmtUsdc(amount)} bet on bucket ${bucket}: on-chain=${onChainFloat.toFixed(4)} shares, off-chain=${offChainFloat.toFixed(4)} shares`
    );

    assertClose(
      offChainFloat,
      onChainFloat,
      2.0, // 2% tolerance (float vs WAD precision)
      `Single bucket quote match @ ${fmtUsdc(amount)}`
    );
  }
}

async function testRangeQuotes(marketAddr: Address, state: MarketState) {
  console.log("\n─── TEST 3: Range — On-Chain vs Off-Chain Quotes ───\n");

  const w = state.bucketWidth;
  const mn = state.marketMin;
  const mx = state.marketMax;
  const testCases = [
    { lower: mn + w * 2n, upper: mn + w * 5n, amount: 100_000000n, label: `3 buckets, $100` },
    { lower: mn, upper: mn + w * 3n, amount: 500_000000n, label: `3 buckets from start, $500` },
    { lower: mn, upper: mx, amount: 100_000000n, label: `ALL buckets, $100` },
    { lower: mn + w * 7n, upper: mn + w * 9n, amount: 200_000000n, label: `2 buckets, $200` },
  ];

  for (const tc of testCases) {
    // On-chain quote
    const onChain = (await publicClient.readContract({
      address: marketAddr,
      abi: LMSRMarketArtifact.abi,
      functionName: "getQuoteForRange",
      args: [tc.lower, tc.upper, tc.amount],
    })) as [bigint, bigint, bigint];
    const [onShares, onCost, onOdds] = onChain;

    // Off-chain quote
    const offChain = calculateRangeShares(state, tc.lower, tc.upper, tc.amount);

    console.log(`  ${tc.label}:`);
    console.log(
      `    On-chain:  shares=${toFloat(onShares).toFixed(4)}, cost=${toFloat(onCost).toFixed(4)}, odds=${toFloat(onOdds).toFixed(4)}`
    );
    console.log(
      `    Off-chain: shares=${offChain.shares.toFixed(4)}, cost=${offChain.cost.toFixed(4)}, odds=${offChain.odds.toFixed(4)}`
    );

    assertClose(
      offChain.shares,
      toFloat(onShares),
      5.0, // 5% tolerance for binary search convergence + float vs WAD
      `Range shares match: ${tc.label}`
    );

    assertClose(
      offChain.cost,
      toFloat(onCost),
      5.0,
      `Range cost match: ${tc.label}`
    );

    if (toFloat(onOdds) > 0) {
      assertClose(
        offChain.odds,
        toFloat(onOdds),
        5.0,
        `Range odds match: ${tc.label}`
      );
    }
  }
}

async function testTradeExecution(
  addrs: Addresses,
  state: MarketState
) {
  console.log("\n─── TEST 4: Execute Trade & Verify Accounting ───\n");

  const marketAddr = addrs.market;
  const amount = 500_000000n; // $500
  const bucket = Math.floor(state.bucketCount / 2);

  // Off-chain prediction
  const prediction = calculateSingleBucketShares(state, bucket, amount);
  console.log(`  Pre-trade prediction: ${prediction.shares.toFixed(4)} shares for ${fmtUsdc(amount)}`);

  // Execute buy
  const minShares = toBigInt6(prediction.shares * 0.95); // 5% slippage
  const buyHash = await send(traderWallet, marketAddr, LMSRMarketArtifact.abi, "buyShares", [
    BigInt(bucket),
    amount,
    minShares,
  ]);
  const buyReceipt = await publicClient.waitForTransactionReceipt({ hash: buyHash });
  console.log(`  Buy tx: ${buyReceipt.transactionHash} (gas: ${buyReceipt.gasUsed})`);

  // Read post-trade state
  const postState = await readMarketState(marketAddr);
  const actualShares = postState.buckets[bucket].shares - state.buckets[bucket].shares;

  console.log(`  Actual shares minted: ${toFloat(actualShares).toFixed(4)}`);
  assertClose(
    toFloat(actualShares),
    prediction.shares,
    1.0,
    "Actual minted shares match off-chain prediction"
  );

  // Verify pool balance increased by net amount (amount - fees)
  const fees = Number(amount) * state.feeBps / 10000;
  const expectedPoolIncrease = Number(amount) - fees;
  const actualPoolIncrease = Number(postState.poolBalance - state.poolBalance);
  // Pool gets netAmount + lpFee
  // netAmount = amount - totalFees
  // lpFee = totalFees - protocolFee
  // So pool gets: amount - totalFees + (totalFees - protocolFee) = amount - protocolFee
  // Wait, let me re-check the fee flow:
  // poolBalance += netCostUSDC (which is amountUSDC - feesUSDC) — only the net goes to pool
  // lpFee stays outside poolBalance but in the contract balance
  assertClose(
    actualPoolIncrease / 1_000_000,
    expectedPoolIncrease / 1_000_000,
    1.0,
    "Pool balance increase matches expected net amount"
  );

  // Verify position NFT balance increased by correct amount
  const posNFT = addrs.positionNFT;
  // Single bucket: rangeLower == rangeUpper == bucketId
  const marketId = (await publicClient.readContract({
    address: marketAddr,
    abi: LMSRMarketArtifact.abi,
    functionName: "marketId",
  })) as bigint;

  const tokenId =
    (marketId << 128n) | (BigInt(bucket) << 64n) | BigInt(bucket);

  const nftBalance = (await publicClient.readContract({
    address: posNFT,
    abi: PositionNFTArtifact.abi,
    functionName: "balanceOf",
    args: [trader.address, tokenId],
  })) as bigint;

  // NFT balance accumulates across trades, so just verify it's >= the shares from this trade
  assert(nftBalance >= actualShares, `NFT balance (${toFloat(nftBalance).toFixed(4)}) >= shares minted (${toFloat(actualShares).toFixed(4)})`);

  // Now test probability shift
  const probsBefore = computeProbabilities(state);
  const probsAfter = computeProbabilities(postState);
  console.log(
    `  Bucket ${bucket} probability: ${(probsBefore[bucket] * 100).toFixed(2)}% → ${(probsAfter[bucket] * 100).toFixed(2)}%`
  );
  assert(probsAfter[bucket] > probsBefore[bucket], "Bought bucket probability increased");

  return { postState, sharesOwned: actualShares, nftBalance, tokenId };
}

async function testSellAndPnL(
  addrs: Addresses,
  state: MarketState,
  sharesOwned: bigint,
  bucket: number
) {
  console.log("\n─── TEST 5: Sell Shares & PnL ───\n");

  const marketAddr = addrs.market;

  // Off-chain sell quote
  const sellPrediction = calculateSellReturn(state, bucket, sharesOwned);
  console.log(`  Off-chain sell prediction: gross=${sellPrediction.grossReturn.toFixed(4)}, net=${sellPrediction.netReturn.toFixed(4)}`);

  // On-chain sell quote
  const onChainReturn = (await publicClient.readContract({
    address: marketAddr,
    abi: LMSRMarketArtifact.abi,
    functionName: "calculateReturnForShares",
    args: [BigInt(bucket), sharesOwned],
  })) as bigint;

  console.log(`  On-chain sell quote (gross): ${toFloat(onChainReturn).toFixed(4)}`);

  assertClose(
    sellPrediction.grossReturn,
    toFloat(onChainReturn),
    1.0,
    "Sell return: off-chain matches on-chain"
  );

  // Execute sell (sell half)
  const halfShares = sharesOwned / 2n;
  const halfPrediction = calculateSellReturn(state, bucket, halfShares);
  const minPayout = toBigInt6(halfPrediction.netReturn * 0.95);

  const sellHash = await send(traderWallet, marketAddr, LMSRMarketArtifact.abi, "sellShares", [
    BigInt(bucket),
    halfShares,
    minPayout,
  ]);
  const sellReceipt = await publicClient.waitForTransactionReceipt({ hash: sellHash });
  console.log(`  Sell tx: ${sellReceipt.transactionHash} (gas: ${sellReceipt.gasUsed})`);

  const postState = await readMarketState(marketAddr);
  const sharesRemaining = postState.buckets[bucket].shares - (state.buckets[bucket].shares - sharesOwned);

  console.log(`  Shares remaining in bucket after partial sell`);
  assert(sellReceipt.status === "success", "Sell transaction succeeded");

  return postState;
}

async function testRangeTradeWithFastPath(
  addrs: Addresses,
  state: MarketState
) {
  console.log("\n─── TEST 6: Range Trade with Fast Path ───\n");

  const marketAddr = addrs.market;
  const amount = 300_000000n; // $300
  const lower = state.marketMin + state.bucketWidth * 3n;
  const upper = state.marketMin + state.bucketWidth * 6n; // 3 buckets

  // Off-chain preview (this is what the FE slider handler computes)
  const preview = computeTradePreview(state, lower, upper, amount);

  console.log(`  Range: $${lower}-$${upper}`);
  console.log(`  Amount: ${fmtUsdc(amount)}`);
  console.log(`  Implied probability: ${(preview.impliedProbability * 100).toFixed(2)}%`);
  console.log(`  Expected shares: ${preview.shares.toFixed(4)}`);
  console.log(`  Expected cost: $${preview.cost.toFixed(4)}`);
  console.log(`  Odds: ${preview.odds.toFixed(4)}x`);
  console.log(`  Potential payout: $${preview.potentialPayout.toFixed(2)}`);
  console.log(`  Return multiplier: ${preview.returnMultiplier.toFixed(2)}x`);
  console.log(`  Probability shift: ${(preview.probabilityShift * 100).toFixed(2)}%`);

  // On-chain quote for comparison
  const onChain = (await publicClient.readContract({
    address: marketAddr,
    abi: LMSRMarketArtifact.abi,
    functionName: "getQuoteForRange",
    args: [lower, upper, amount],
  })) as [bigint, bigint, bigint];

  assertClose(preview.shares, toFloat(onChain[0]), 2.0, "Range preview shares match on-chain");
  assertClose(preview.cost, toFloat(onChain[1]), 2.0, "Range preview cost match on-chain");

  // Execute with fast path (targetShares from off-chain preview)
  const minShares = toBigInt6(preview.shares * 0.95);
  const targetShares = preview.targetSharesBigInt;

  console.log(`\n  Executing buySharesRange with targetShares=${toFloat(targetShares).toFixed(4)} (fast path)`);

  const buyHash = await send(traderWallet, marketAddr, LMSRMarketArtifact.abi, "buySharesRange", [
    lower,
    upper,
    amount,
    minShares,
    targetShares,
  ]);
  const buyReceipt = await publicClient.waitForTransactionReceipt({ hash: buyHash });
  console.log(`  Range buy tx: ${buyReceipt.transactionHash} (gas: ${buyReceipt.gasUsed})`);
  assert(buyReceipt.status === "success", "Range buy with fast path succeeded");

  // Compare gas: fast path vs no fast path
  // We can't easily compare in same test, but we log the gas
  console.log(`  Gas used (with fast path): ${buyReceipt.gasUsed}`);

  // Verify post-trade state
  const postState = await readMarketState(marketAddr);
  const [startB, endB] = rangeToBuckets(state, lower, upper);

  // All buckets in range should have increased by same amount
  const increments: bigint[] = [];
  for (let b = startB; b <= endB; b++) {
    increments.push(postState.buckets[b].shares - state.buckets[b].shares);
  }

  // Check all increments are equal (correlated range trade)
  for (let i = 1; i < increments.length; i++) {
    assert(
      increments[i] === increments[0],
      `Range trade: bucket ${startB + i} increment equals bucket ${startB} increment`
    );
  }

  // Verify probability shifted
  const probsAfter = computeProbabilities(postState);
  let rangeProbAfter = 0;
  for (let b = startB; b <= endB; b++) rangeProbAfter += probsAfter[b];
  assert(
    rangeProbAfter > preview.impliedProbability,
    `Range probability increased: ${(preview.impliedProbability * 100).toFixed(2)}% → ${(rangeProbAfter * 100).toFixed(2)}%`
  );

  return postState;
}

async function testRangeSellQuote(
  addrs: Addresses,
  state: MarketState
) {
  console.log("\n─── TEST 6b: Range Sell — Off-Chain vs Actual Execution ───\n");

  const marketAddr = addrs.market;
  const w = state.bucketWidth;
  const mn = state.marketMin;

  // First buy a range position so the trader has range NFTs to sell
  const lower = mn + w * 1n;
  const upper = mn + w * 4n; // 3 buckets
  const buyAmount = 200_000000n;

  // Ensure trader has USDC + approval
  await send(deployerWallet, addrs.usdc, MockUSDCArtifact.abi, "mint", [trader.address, buyAmount]);
  await send(traderWallet, addrs.usdc, MockUSDCArtifact.abi, "approve", [marketAddr, buyAmount]);

  // Compute expected shares from off-chain
  const buyPreview = calculateRangeShares(state, lower, upper, buyAmount);
  const targetShares = toBigInt6(buyPreview.shares);
  const minBuyShares = toBigInt6(buyPreview.shares * 0.9);

  // Buy the range position
  await send(traderWallet, marketAddr, LMSRMarketArtifact.abi, "buySharesRange", [
    lower, upper, buyAmount, minBuyShares, targetShares,
  ]);
  console.log(`  Bought range $${lower}-$${upper}: ~${buyPreview.shares.toFixed(2)} shares`);

  // Read post-buy state
  const postBuyState = await readMarketState(marketAddr);

  // Now sell HALF the range position
  const sharesToSell = targetShares / 2n;

  // Off-chain sell quote
  const offChainSell = calculateRangeSellReturn(postBuyState, lower, upper, sharesToSell);
  console.log(`  Off-chain range sell: gross=${offChainSell.grossReturn.toFixed(4)}, net=${offChainSell.netReturn.toFixed(4)}`);

  // On-chain sell quote (new view function)
  const onChainSellQuote = (await publicClient.readContract({
    address: marketAddr,
    abi: LMSRMarketArtifact.abi,
    functionName: "calculateReturnForRangeShares",
    args: [lower, upper, sharesToSell],
  })) as [bigint, bigint, bigint];
  const [onGross, onNet, onFees] = onChainSellQuote;
  console.log(`  On-chain range sell:  gross=${toFloat(onGross).toFixed(4)}, net=${toFloat(onNet).toFixed(4)}, fees=${toFloat(onFees).toFixed(4)}`);

  assertClose(
    offChainSell.grossReturn,
    toFloat(onGross),
    1.0,
    "Range sell gross: off-chain matches on-chain view"
  );
  assertClose(
    offChainSell.netReturn,
    toFloat(onNet),
    1.0,
    "Range sell net: off-chain matches on-chain view"
  );

  // Get trader USDC balance before sell
  const preBalance = (await publicClient.readContract({
    address: addrs.usdc,
    abi: MockUSDCArtifact.abi,
    functionName: "balanceOf",
    args: [trader.address],
  })) as bigint;

  // Execute range sell
  const minPayout = toBigInt6(offChainSell.netReturn * 0.9);
  const sellHash = await send(traderWallet, marketAddr, LMSRMarketArtifact.abi, "sellSharesRange", [
    lower, upper, sharesToSell, minPayout,
  ]);
  const sellReceipt = await publicClient.waitForTransactionReceipt({ hash: sellHash });
  console.log(`  Range sell tx: ${sellReceipt.transactionHash} (gas: ${sellReceipt.gasUsed})`);

  // Get trader USDC balance after sell
  const postBalance = (await publicClient.readContract({
    address: addrs.usdc,
    abi: MockUSDCArtifact.abi,
    functionName: "balanceOf",
    args: [trader.address],
  })) as bigint;

  const actualPayout = toFloat(postBalance - preBalance);
  console.log(`  Actual payout: $${actualPayout.toFixed(4)}`);

  assertClose(
    offChainSell.netReturn,
    actualPayout,
    1.0,
    "Range sell: off-chain net return matches actual USDC received"
  );

  assert(sellReceipt.status === "success", "Range sell transaction succeeded");
}

async function testVaultLP(addrs: Addresses) {
  console.log("\n─── TEST 7: Vault / LP Page ───\n");

  const { vault, usdc: usdcAddr } = addrs;
  const abi = VaultArtifact.abi;

  // LP deposits
  await send(lpWallet, usdcAddr, MockUSDCArtifact.abi, "approve", [vault, 100_000_000000n]);
  await send(lpWallet, vault, abi, "deposit", [100_000_000000n, lp.address]);
  console.log("  LP deposited $100K");

  // Check vault state
  const totalAssets = (await publicClient.readContract({
    address: vault,
    abi,
    functionName: "totalAssets",
  })) as bigint;

  const lpShares = (await publicClient.readContract({
    address: vault,
    abi,
    functionName: "balanceOf",
    args: [lp.address],
  })) as bigint;

  const sharePrice = (await publicClient.readContract({
    address: vault,
    abi,
    functionName: "convertToAssets",
    args: [1_000000n],
  })) as bigint;

  const liquidAvail = (await publicClient.readContract({
    address: vault,
    abi,
    functionName: "liquidAvailable",
  })) as bigint;

  const maxWithdraw = (await publicClient.readContract({
    address: vault,
    abi,
    functionName: "maxWithdraw",
    args: [lp.address],
  })) as bigint;

  const deployable = (await publicClient.readContract({
    address: vault,
    abi,
    functionName: "deployableCapital",
  })) as bigint;

  const pendingCount = (await publicClient.readContract({
    address: vault,
    abi,
    functionName: "pendingWithdrawalsCount",
  })) as bigint;

  const marketCnt = (await publicClient.readContract({
    address: vault,
    abi,
    functionName: "marketCount",
  })) as bigint;

  console.log(`  Total assets:     ${fmtUsdc(totalAssets)}`);
  console.log(`  LP shares:        ${formatUnits(lpShares, 6)}`);
  console.log(`  Share price:      ${fmtUsdc(sharePrice)} per share`);
  console.log(`  Liquid available: ${fmtUsdc(liquidAvail)}`);
  console.log(`  Max withdraw:     ${fmtUsdc(maxWithdraw)}`);
  console.log(`  Deployable:       ${fmtUsdc(deployable)}`);
  console.log(`  Pending w/d:      ${pendingCount}`);
  console.log(`  Markets:          ${marketCnt}`);

  assert(totalAssets > 0n, "Vault has assets");
  assert(lpShares > 0n, "LP has shares");
  assert(sharePrice > 0n, "Share price > 0");
  assert(pendingCount === 0n, "No pending withdrawals");
  assert(marketCnt >= 1n, "At least 1 market registered");

  // Test instant withdrawal
  const withdrawAmount = 10_000_000000n; // $10K
  if (maxWithdraw >= withdrawAmount) {
    const preBalance = (await publicClient.readContract({
      address: addrs.usdc,
      abi: MockUSDCArtifact.abi,
      functionName: "balanceOf",
      args: [lp.address],
    })) as bigint;

    await send(lpWallet, vault, abi, "withdraw", [withdrawAmount, lp.address, lp.address]);

    const postBalance = (await publicClient.readContract({
      address: addrs.usdc,
      abi: MockUSDCArtifact.abi,
      functionName: "balanceOf",
      args: [lp.address],
    })) as bigint;

    const received = postBalance - preBalance;
    assertClose(
      Number(received),
      Number(withdrawAmount),
      0.1,
      `LP instant withdrawal: received ${fmtUsdc(received)}`
    );
  } else {
    console.log("  (Skipping instant withdrawal — insufficient liquid)");
  }
}

async function test100PctProbabilityOdds(marketAddr: Address, state: MarketState) {
  console.log("\n─── TEST 8: 100% Probability Odds (Sui Parity) ───\n");

  // Betting on ALL buckets = 100% probability → odds should be ~1.0x
  const amount = 100_000000n; // $100
  const lower = state.marketMin;
  const upper = state.marketMax;

  const onChain = (await publicClient.readContract({
    address: marketAddr,
    abi: LMSRMarketArtifact.abi,
    functionName: "getQuoteForRange",
    args: [lower, upper, amount],
  })) as [bigint, bigint, bigint];

  const offChain = calculateRangeShares(state, lower, upper, amount);

  const onOdds = toFloat(onChain[2]);
  console.log(`  100% range bet $100:`);
  console.log(`    On-chain odds:  ${onOdds.toFixed(4)}x`);
  console.log(`    Off-chain odds: ${offChain.odds.toFixed(4)}x`);

  // Odds for 100% probability should be close to 1.0x (with small spread for LMSR)
  assertClose(onOdds, 1.0, 15, "100% probability odds ≈ 1.0x (within 15%)");
  assertClose(offChain.odds, onOdds, 2.0, "Off-chain matches on-chain for 100% range");
}

async function testMultipleProbabilityLevels(marketAddr: Address, state: MarketState) {
  console.log("\n─── TEST 9: Odds at Different Probability Levels ───\n");

  const amount = 100_000000n;
  const width = state.bucketWidth;
  const min = state.marketMin;
  const n = state.bucketCount;

  const scenarios = [
    { buckets: 1, label: `${(100/n).toFixed(0)}% (1/${n})` },
    { buckets: 3, label: `${(300/n).toFixed(0)}% (3/${n})` },
    { buckets: Math.floor(n/2), label: `${(100*Math.floor(n/2)/n).toFixed(0)}% (${Math.floor(n/2)}/${n})` },
    { buckets: n - 1, label: `${(100*(n-1)/n).toFixed(0)}% (${n-1}/${n})` },
    { buckets: n, label: `100% (${n}/${n})` },
  ];

  for (const s of scenarios) {
    const lower = min;
    const upper = min + width * BigInt(s.buckets);

    const onChain = (await publicClient.readContract({
      address: marketAddr,
      abi: LMSRMarketArtifact.abi,
      functionName: "getQuoteForRange",
      args: [lower, upper, amount],
    })) as [bigint, bigint, bigint];

    const offChain = calculateRangeShares(state, lower, upper, amount);

    const expectedOdds = state.bucketCount / s.buckets; // theoretical: 1/probability

    console.log(
      `  ${s.label}: on-chain=${toFloat(onChain[2]).toFixed(3)}x, off-chain=${offChain.odds.toFixed(3)}x, theoretical=${expectedOdds.toFixed(3)}x`
    );

    assertClose(
      offChain.odds,
      toFloat(onChain[2]),
      3.0,
      `${s.label} — off-chain ≈ on-chain`
    );
  }
}

async function testTradePreviewFullCycle(addrs: Addresses, state: MarketState) {
  console.log("\n─── TEST 10: Full Trade Preview Cycle (FE Guide Section 7c) ───\n");

  // Simulate what happens when user drags sliders
  const w = state.bucketWidth;
  const mn = state.marketMin;
  const scenarios = [
    { lower: mn + w * 3n, upper: mn + w * 5n, amount: 10_000000n, label: "2 buckets, $10" },
    { lower: mn + w * 2n, upper: mn + w * 6n, amount: 50_000000n, label: "4 buckets, $50" },
    { lower: mn + w * 7n, upper: mn + w * 8n, amount: 100_000000n, label: "1 bucket, $100" },
  ];

  for (const s of scenarios) {
    const preview = computeTradePreview(state, s.lower, s.upper, s.amount);

    // Verify on-chain
    const onChain = (await publicClient.readContract({
      address: addrs.market,
      abi: LMSRMarketArtifact.abi,
      functionName: "getQuoteForRange",
      args: [s.lower, s.upper, s.amount],
    })) as [bigint, bigint, bigint];

    console.log(`\n  ${s.label}:`);
    console.log(`    Implied probability: ${(preview.impliedProbability * 100).toFixed(2)}%`);
    console.log(`    Shares:  off=${preview.shares.toFixed(4)} on=${toFloat(onChain[0]).toFixed(4)}`);
    console.log(`    Cost:    off=$${preview.cost.toFixed(4)} on=$${toFloat(onChain[1]).toFixed(4)}`);
    console.log(`    Payout:  $${preview.potentialPayout.toFixed(2)}`);
    console.log(`    Return:  ${preview.returnMultiplier.toFixed(2)}x`);
    console.log(`    Prob shift: ${(preview.probabilityShift * 100).toFixed(2)}%`);

    assertClose(preview.shares, toFloat(onChain[0]), 2.0, `${s.label} shares match`);
    assertClose(preview.cost, toFloat(onChain[1]), 2.0, `${s.label} cost match`);

    // Verify payout = shares (since 1 share = $1 on win)
    assertClose(preview.potentialPayout, preview.shares, 0.01, `${s.label} payout = shares`);

    // Verify return multiplier = payout / amountUSDC
    assertClose(
      preview.returnMultiplier,
      preview.potentialPayout / toFloat(s.amount),
      0.1,
      `${s.label} return multiplier`
    );
  }
}

// ═════════════════════════════════════════════════════════════════════
// UTILS
// ═════════════════════════════════════════════════════════════════════

async function send(
  wallet: WalletClient,
  to: Address,
  abi: any[],
  functionName: string,
  args: any[]
): Promise<Hex> {
  const hash = await wallet.writeContract({
    address: to,
    abi,
    functionName,
    args,
    chain: localChain,
    account: wallet.account!,
  });
  await publicClient.waitForTransactionReceipt({ hash });
  return hash;
}

function predictContractAddress(from: Address, nonce: number): Address {
  let nonceHex: Hex;
  if (nonce === 0) {
    nonceHex = "0x" as Hex;
  } else {
    let hex = nonce.toString(16);
    if (hex.length % 2 !== 0) hex = "0" + hex;
    nonceHex = `0x${hex}` as Hex;
  }
  const encoded = toRlp([from as Hex, nonceHex]);
  const hash = keccak256(encoded);
  return getAddress(`0x${hash.slice(26)}`) as Address;
}

// ═════════════════════════════════════════════════════════════════════
// MAIN
// ═════════════════════════════════════════════════════════════════════

async function main() {
  console.log("╔══════════════════════════════════════════════════╗");
  console.log("║  SKEPSIS MARKET — INTEGRATION TEST              ║");
  console.log("║  On-Chain vs Off-Chain Quote Validation          ║");
  console.log("╚══════════════════════════════════════════════════╝");

  // Initialize clients with auto-detected chain ID
  await initClients();

  // Step 1: Deploy
  const addrs = await deployAll();

  // Step 2: Read initial state
  console.log("═══ READING INITIAL MARKET STATE ═══");
  const initialState = await readMarketState(addrs.market);
  console.log(`  Alpha: ${toFloat(initialState.alpha).toFixed(2)}`);
  console.log(`  Pool: ${fmtUsdc(initialState.poolBalance)}`);
  console.log(`  Buckets: ${initialState.bucketCount}`);
  console.log(`  Range: $${initialState.marketMin}K - $${initialState.marketMax}K`);
  console.log(`  Width: $${initialState.bucketWidth}K`);
  console.log(`  Fees: ${initialState.feeBps / 100}%`);

  // Step 3: Run test suites
  await testProbabilities(addrs.market, initialState);
  await testSingleBucketQuotes(addrs.market, initialState);
  await testRangeQuotes(addrs.market, initialState);

  const { postState: stateAfterBuy, sharesOwned } = await testTradeExecution(addrs, initialState);

  const tradeBucket = Math.floor(initialState.bucketCount / 2);
  await testSellAndPnL(addrs, stateAfterBuy, sharesOwned, tradeBucket);

  // Re-read state after sell
  const stateAfterSell = await readMarketState(addrs.market);

  await testRangeTradeWithFastPath(addrs, stateAfterSell);

  // Re-read state for range sell test
  const stateAfterRangeBuy = await readMarketState(addrs.market);
  await testRangeSellQuote(addrs, stateAfterRangeBuy);

  // Re-read state for fresh quotes
  const freshState = await readMarketState(addrs.market);
  await test100PctProbabilityOdds(addrs.market, freshState);
  await testMultipleProbabilityLevels(addrs.market, freshState);
  await testTradePreviewFullCycle(addrs, freshState);

  await testVaultLP(addrs);

  // ═══ REPORT ═══
  console.log("\n╔══════════════════════════════════════════════════╗");
  console.log("║  RESULTS                                         ║");
  console.log("╚══════════════════════════════════════════════════╝");
  console.log(`  ✅ Passed: ${passCount}`);
  console.log(`  ❌ Failed: ${failCount}`);
  if (failures.length > 0) {
    console.log("\n  Failures:");
    failures.forEach((f) => console.log(`    - ${f}`));
  }
  console.log();

  process.exit(failCount > 0 ? 1 : 0);
}

main().catch((err) => {
  console.error("\n💥 FATAL ERROR:", err);
  process.exit(2);
});
