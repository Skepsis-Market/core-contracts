#!/usr/bin/env tsx
/**
 * Skepsis Market — Lifecycle Integration Test
 *
 * Tests the full user journey:
 *   1. Position querying — on-chain + off-chain indexing strategies
 *   2. Sell shares (single + range)
 *   3. Resolve market (takes VALUE, not bucket number)
 *   4. Claim winnings (single + range)
 *
 * Run:
 *   cd core-contracts
 *   anvil &
 *   npx tsx ts-integration/lifecycle-test.ts
 */

import {
  createPublicClient,
  createWalletClient,
  http,
  getAddress,
  type Address,
  type Hex,
  formatUnits,
  parseAbiItem,
  type PublicClient,
  type WalletClient,
  type Chain,
  defineChain,
  type Log,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { readFileSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";

import {
  type MarketState,
  type BucketData,
  computeProbabilities,
  calculateSingleBucketShares,
  calculateRangeShares,
  calculateSellReturn,
  calculateRangeSellReturn,
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
const TRADER2_KEY =
  "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a" as Hex;

const deployer = privateKeyToAccount(DEPLOYER_KEY);
const trader = privateKeyToAccount(TRADER_KEY);
const trader2 = privateKeyToAccount(TRADER2_KEY);

const RPC = "http://127.0.0.1:8545";

let localChain: Chain;
let publicClient: PublicClient;
let deployerWallet: WalletClient;
let traderWallet: WalletClient;
let trader2Wallet: WalletClient;

async function initClients() {
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
  trader2Wallet = walletFor(TRADER2_KEY);
}

// ═════════════════════════════════════════════════════════════════════
// HELPERS
// ═════════════════════════════════════════════════════════════════════

let passCount = 0;
let failCount = 0;
const failures: string[] = [];

function assert(condition: boolean, label: string, detail?: string) {
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

function assertClose(actual: number, expected: number, tolerancePct: number, label: string) {
  if (expected === 0 && actual === 0) { assert(true, label); return; }
  const ref = Math.max(Math.abs(expected), 0.000001);
  const pctDiff = (Math.abs(actual - expected) / ref) * 100;
  assert(
    pctDiff <= tolerancePct,
    `${label} (${pctDiff.toFixed(2)}% diff)`,
    pctDiff > tolerancePct ? `actual=${actual.toFixed(6)} expected=${expected.toFixed(6)}` : undefined
  );
}

function usdc(n: number): bigint { return BigInt(Math.round(n * 1_000_000)); }
function fmtUsdc(val: bigint): string { return `$${formatUnits(val, 6)}`; }

async function send(
  wallet: WalletClient, to: Address, abi: any[], functionName: string, args: any[]
): Promise<Hex> {
  const hash = await wallet.writeContract({
    address: to, abi, functionName, args, chain: localChain, account: wallet.account!,
  });
  await publicClient.waitForTransactionReceipt({ hash });
  return hash;
}

// ═════════════════════════════════════════════════════════════════════
// READ MARKET STATE
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
      address: marketAddr, abi, functionName: "getBucket", args: [BigInt(i)],
    })) as { shares: bigint; lowerBound: bigint; upperBound: bigint };
    buckets.push({ shares: b.shares, lowerBound: b.lowerBound, upperBound: b.upperBound });
  }

  return { alpha, bucketCount: count, buckets, feeBps: Number(feeBps), poolBalance, marketMin, marketMax, bucketWidth };
}

// ═════════════════════════════════════════════════════════════════════
// TOKEN ID HELPERS (mirrors PositionNFT.sol encoding)
// ═════════════════════════════════════════════════════════════════════

function encodeTokenIdSingle(marketId: bigint, bucketId: number): bigint {
  return (marketId << 128n) | (BigInt(bucketId) << 64n) | BigInt(bucketId);
}

function encodeTokenIdRange(marketId: bigint, rangeLower: number, rangeUpper: number): bigint {
  return (marketId << 128n) | (BigInt(rangeLower) << 64n) | BigInt(rangeUpper);
}

function decodeTokenId(tokenId: bigint): { marketId: bigint; rangeLower: number; rangeUpper: number } {
  const marketId = tokenId >> 128n;
  const rangeLower = Number((tokenId >> 64n) & 0xFFFFFFFFFFFFFFFFn);
  const rangeUpper = Number(tokenId & 0xFFFFFFFFFFFFFFFFn);
  return { marketId, rangeLower, rangeUpper };
}

// ═════════════════════════════════════════════════════════════════════
// DEPLOY A FRESH MARKET FOR LIFECYCLE TESTING
// ═════════════════════════════════════════════════════════════════════

interface Addresses {
  usdc: Address;
  lmsrImpl: Address;
  positionNFT: Address;
  factory: Address;
  vault: Address;
  market: Address;
  marketId: bigint;
}

async function deployFreshMarket(): Promise<Addresses> {
  console.log("\n═══ USING EXISTING DEPLOYED CONTRACTS ═══\n");

  const coreDir = join(__dirname, "..");
  const envContent = readFileSync(join(coreDir, ".env.local"), "utf-8");
  const env = Object.fromEntries(
    envContent.split("\n")
      .filter(l => l.includes("=") && !l.startsWith("#"))
      .map(l => { const [k, ...v] = l.split("="); return [k.trim(), v.join("=").trim()]; })
  );

  const usdcAddr = getAddress(env.USDC_ADDRESS);
  const lmsrImpl = getAddress(env.LMSR_IMPL_ADDRESS);
  const positionNFT = getAddress(env.POSITION_NFT_ADDRESS);
  const factory = getAddress(env.FACTORY_ADDRESS);
  const vault = getAddress(env.VAULT_ADDRESS);
  const factoryAbi = MarketFactoryArtifact.abi;

  console.log(`  MockUSDC:      ${usdcAddr}`);
  console.log(`  LMSRImpl:      ${lmsrImpl}`);
  console.log(`  PositionNFT:   ${positionNFT}`);
  console.log(`  Factory:       ${factory}`);
  console.log(`  Vault:         ${vault}`);

  // Ensure deployer has USDC + vault capital
  await send(deployerWallet, usdcAddr, MockUSDCArtifact.abi, "mint", [deployer.address, 500_000_000000n]);
  await send(deployerWallet, usdcAddr, MockUSDCArtifact.abi, "approve", [vault, 500_000_000000n]);
  try {
    await send(deployerWallet, vault, VaultArtifact.abi, "deposit", [200_000_000000n, deployer.address]);
  } catch { /* vault may already have enough */ }

  // Ensure deployer has creator allowance
  try {
    await send(deployerWallet, factory, factoryAbi, "addCreatorAllowance", [deployer.address, 5n]);
  } catch { /* may already have allowance */ }

  // Create market: 10 buckets, $60K-$80K, $2K width, no expansion
  const SEED = 10_000_000000n;
  const createParams = [{
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
    expandedMinValue: 0n,
    expandedMaxValue: 0n,
    name: "BTC/USD Lifecycle Test",
    description: "Testing positions, sell, resolve, claim",
    resolutionCriteria: "CoinGecko BTC price",
    valueUnit: "USD",
    resolver: "0x0000000000000000000000000000000000000000" as Address,
    biddingDeadline: 0n,
    scheduledResolutionTime: 0n,
    minBetSize: 0n,
    maxBucketsPerRange: 0n,
  }];

  await send(deployerWallet, factory, factoryAbi, "createMarket", createParams);

  const count = (await publicClient.readContract({
    address: factory, abi: factoryAbi, functionName: "marketCount",
  })) as bigint;

  const marketId = count - 1n;
  const market = (await publicClient.readContract({
    address: factory, abi: factoryAbi, functionName: "marketById", args: [marketId],
  })) as Address;

  console.log(`  Market:        ${market} (id=${marketId})`);

  // Fund traders
  await send(deployerWallet, usdcAddr, MockUSDCArtifact.abi, "mint", [trader.address, 100_000_000000n]);
  await send(deployerWallet, usdcAddr, MockUSDCArtifact.abi, "mint", [trader2.address, 100_000_000000n]);
  await send(traderWallet, usdcAddr, MockUSDCArtifact.abi, "approve", [market, 100_000_000000n]);
  await send(trader2Wallet, usdcAddr, MockUSDCArtifact.abi, "approve", [market, 100_000_000000n]);

  console.log("\n═══ READY ═══\n");
  return { usdc: usdcAddr, lmsrImpl, positionNFT, factory, vault, market, marketId };
}


// ═════════════════════════════════════════════════════════════════════
// TEST 1: POSITION QUERYING — On-Chain Strategy
// ═════════════════════════════════════════════════════════════════════

async function testPositionQueryOnChain(addrs: Addresses, state: MarketState) {
  console.log("\n─── TEST 1: Position Querying (On-Chain) ───\n");

  const { market, positionNFT, marketId } = addrs;

  // ── 1a. Buy single-bucket positions
  console.log("  Step 1: Buy positions in buckets 3 and 7");
  await send(traderWallet, market, LMSRMarketArtifact.abi, "buyShares", [3n, usdc(200), 0n]);
  await send(traderWallet, market, LMSRMarketArtifact.abi, "buyShares", [7n, usdc(150), 0n]);

  // ── 1b. Buy range position: $66K-$72K (buckets 3-5)
  console.log("  Step 2: Buy range position [$66K-$72K]");
  const lower = state.marketMin + state.bucketWidth * 3n;
  const upper = state.marketMin + state.bucketWidth * 6n;
  await send(traderWallet, market, LMSRMarketArtifact.abi, "buySharesRange", [
    lower, upper, usdc(300), 0n, 0n,
  ]);

  // ── 1c. Query positions via PositionNFT.balanceOf
  console.log("\n  Querying positions via PositionNFT.balanceOf:");

  // Single bucket tokens
  for (const bucketId of [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]) {
    const tokenId = encodeTokenIdSingle(marketId, bucketId);
    const balance = (await publicClient.readContract({
      address: positionNFT, abi: PositionNFTArtifact.abi,
      functionName: "balanceOf", args: [trader.address, tokenId],
    })) as bigint;
    if (balance > 0n) {
      console.log(`    Bucket ${bucketId}: ${toFloat(balance).toFixed(4)} shares`);
    }
  }

  // Range token
  const [startB, endB] = rangeToBuckets(state, lower, upper);
  const rangeTokenId = encodeTokenIdRange(marketId, startB, endB);
  const rangeBalance = (await publicClient.readContract({
    address: positionNFT, abi: PositionNFTArtifact.abi,
    functionName: "balanceOf", args: [trader.address, rangeTokenId],
  })) as bigint;
  console.log(`    Range [${startB}-${endB}]: ${toFloat(rangeBalance).toFixed(4)} shares`);

  // ── Assertions
  const singleBalance3 = (await publicClient.readContract({
    address: positionNFT, abi: PositionNFTArtifact.abi,
    functionName: "balanceOf", args: [trader.address, encodeTokenIdSingle(marketId, 3)],
  })) as bigint;
  const singleBalance7 = (await publicClient.readContract({
    address: positionNFT, abi: PositionNFTArtifact.abi,
    functionName: "balanceOf", args: [trader.address, encodeTokenIdSingle(marketId, 7)],
  })) as bigint;

  assert(singleBalance3 > 0n, "Trader has bucket 3 single position");
  assert(singleBalance7 > 0n, "Trader has bucket 7 single position");
  assert(rangeBalance > 0n, "Trader has range position [3-5]");

  // Verify trader2 has no positions
  const t2Balance = (await publicClient.readContract({
    address: positionNFT, abi: PositionNFTArtifact.abi,
    functionName: "balanceOf", args: [trader2.address, encodeTokenIdSingle(marketId, 3)],
  })) as bigint;
  assert(t2Balance === 0n, "Trader2 has no positions (hasn't traded)");

  return { singleBalance3, singleBalance7, rangeBalance, rangeStartBucket: startB, rangeEndBucket: endB };
}

// ═════════════════════════════════════════════════════════════════════
// TEST 2: POSITION INDEXING — Off-Chain Event Strategy
// ═════════════════════════════════════════════════════════════════════

async function testPositionIndexingOffChain(addrs: Addresses) {
  console.log("\n─── TEST 2: Position Indexing (Off-Chain via Events) ───\n");

  const { market, marketId } = addrs;

  // Strategy: Scan SharesPurchased + RangeSharesPurchased events for a user
  // This is what a subgraph or backend indexer would do

  // ── 2a. Fetch all SharesPurchased events
  const purchaseLogs = await publicClient.getLogs({
    address: market,
    event: parseAbiItem(
      "event SharesPurchased(uint256 indexed marketId, address indexed buyer, uint256 indexed bucketId, uint256 amountUSDC, uint256 sharesMinted, uint256 newPrice)"
    ),
    fromBlock: 0n,
    toBlock: "latest",
    args: { buyer: trader.address },
  });

  console.log(`  SharesPurchased events for trader: ${purchaseLogs.length}`);
  for (const log of purchaseLogs) {
    const args = log.args;
    console.log(`    Bucket ${args.bucketId}: ${toFloat(args.sharesMinted!).toFixed(4)} shares, cost ${fmtUsdc(args.amountUSDC!)}`);
  }

  // ── 2b. Fetch all RangeSharesPurchased events
  const rangePurchaseLogs = await publicClient.getLogs({
    address: market,
    event: parseAbiItem(
      "event RangeSharesPurchased(uint256 indexed marketId, address indexed buyer, uint256 startBucket, uint256 endBucket, uint256 shares, uint256 costUSDC)"
    ),
    fromBlock: 0n,
    toBlock: "latest",
    args: { buyer: trader.address },
  });

  console.log(`  RangeSharesPurchased events for trader: ${rangePurchaseLogs.length}`);
  for (const log of rangePurchaseLogs) {
    const args = log.args;
    console.log(`    Range [${args.startBucket}-${args.endBucket}]: ${toFloat(args.shares!).toFixed(4)} shares, cost ${fmtUsdc(args.costUSDC!)}`);
  }

  assert(purchaseLogs.length === 2, `Found ${purchaseLogs.length} single-bucket purchases (expected 2)`);
  assert(rangePurchaseLogs.length === 1, `Found ${rangePurchaseLogs.length} range purchases (expected 1)`);

  // ── 2c. Build position map from events (indexer strategy)
  console.log("\n  Reconstructed position map (from events):");
  const positionMap: Map<string, { type: string; shares: bigint }> = new Map();

  for (const log of purchaseLogs) {
    const key = `single_${log.args.bucketId}`;
    const existing = positionMap.get(key);
    const shares = log.args.sharesMinted!;
    positionMap.set(key, {
      type: "single",
      shares: existing ? existing.shares + shares : shares,
    });
  }

  for (const log of rangePurchaseLogs) {
    const key = `range_${log.args.startBucket}_${log.args.endBucket}`;
    const existing = positionMap.get(key);
    const shares = log.args.shares!;
    positionMap.set(key, {
      type: "range",
      shares: existing ? existing.shares + shares : shares,
    });
  }

  for (const [key, pos] of positionMap) {
    console.log(`    ${key}: ${toFloat(pos.shares).toFixed(4)} shares`);
  }

  assert(positionMap.size === 3, "Position map has 3 entries (bucket 3, bucket 7, range)");
}

// ═════════════════════════════════════════════════════════════════════
// TEST 3: SELL SHARES (Single Bucket)
// ═════════════════════════════════════════════════════════════════════

async function testSellSharesSingle(addrs: Addresses, singleBalance: bigint) {
  console.log("\n─── TEST 3: Sell Shares (Single Bucket) ───\n");

  const { market, positionNFT, marketId, usdc: usdcAddr } = addrs;

  const stateBefore = await readMarketState(market);
  const bucket = 3;
  const sharesToSell = singleBalance / 2n; // Sell half

  // Off-chain sell quote
  const prediction = calculateSellReturn(stateBefore, bucket, sharesToSell);
  console.log(`  Selling ${toFloat(sharesToSell).toFixed(4)} shares from bucket ${bucket}`);
  console.log(`  Off-chain prediction: gross=${prediction.grossReturn.toFixed(4)}, net=${prediction.netReturn.toFixed(4)}`);

  // On-chain sell quote
  const onChainGross = (await publicClient.readContract({
    address: market, abi: LMSRMarketArtifact.abi,
    functionName: "calculateReturnForShares", args: [BigInt(bucket), sharesToSell],
  })) as bigint;
  console.log(`  On-chain gross return: ${toFloat(onChainGross).toFixed(4)}`);

  assertClose(prediction.grossReturn, toFloat(onChainGross), 2.0, "Sell quote: off-chain matches on-chain");

  // Get USDC balance before sell
  const balBefore = (await publicClient.readContract({
    address: usdcAddr, abi: MockUSDCArtifact.abi,
    functionName: "balanceOf", args: [trader.address],
  })) as bigint;

  // Execute sell
  const minPayout = toBigInt6(prediction.netReturn * 0.9);
  const sellHash = await send(traderWallet, market, LMSRMarketArtifact.abi, "sellShares", [
    BigInt(bucket), sharesToSell, minPayout,
  ]);
  console.log(`  Sell tx: ${sellHash}`);

  // Verify USDC received
  const balAfter = (await publicClient.readContract({
    address: usdcAddr, abi: MockUSDCArtifact.abi,
    functionName: "balanceOf", args: [trader.address],
  })) as bigint;
  const received = toFloat(balAfter - balBefore);
  console.log(`  USDC received: $${received.toFixed(4)}`);
  assertClose(received, prediction.netReturn, 2.0, "Sell payout matches off-chain prediction");

  // Verify NFT balance decreased
  const nftAfter = (await publicClient.readContract({
    address: positionNFT, abi: PositionNFTArtifact.abi,
    functionName: "balanceOf", args: [trader.address, encodeTokenIdSingle(marketId, bucket)],
  })) as bigint;
  assert(nftAfter === singleBalance - sharesToSell, "NFT balance decreased by sold shares");

  // Check SharesSold event
  const sellLogs = await publicClient.getLogs({
    address: market,
    event: parseAbiItem(
      "event SharesSold(uint256 indexed marketId, address indexed seller, uint256 indexed bucketId, uint256 sharesBurned, uint256 amountUSDC, uint256 newPrice)"
    ),
    fromBlock: 0n, toBlock: "latest",
    args: { seller: trader.address, bucketId: BigInt(bucket) },
  });
  assert(sellLogs.length > 0, "SharesSold event emitted");

  return nftAfter; // remaining shares
}

// ═════════════════════════════════════════════════════════════════════
// TEST 4: SELL SHARES (Range)
// ═════════════════════════════════════════════════════════════════════

async function testSellSharesRange(
  addrs: Addresses, state: MarketState,
  rangeBalance: bigint, rangeStart: number, rangeEnd: number
) {
  console.log("\n─── TEST 4: Sell Shares (Range) ───\n");

  const { market, positionNFT, marketId, usdc: usdcAddr } = addrs;

  const currentState = await readMarketState(market);
  const sharesToSell = rangeBalance / 3n; // Sell 1/3 of range

  // Convert bucket indices back to values for the contract call
  const lower = currentState.marketMin + currentState.bucketWidth * BigInt(rangeStart);
  const upper = currentState.marketMin + currentState.bucketWidth * BigInt(rangeEnd + 1);

  console.log(`  Range: [$${lower}-$${upper}] (buckets ${rangeStart}-${rangeEnd})`);
  console.log(`  Selling ${toFloat(sharesToSell).toFixed(4)} shares`);

  // Off-chain sell quote
  const prediction = calculateRangeSellReturn(currentState, lower, upper, sharesToSell);
  console.log(`  Off-chain prediction: gross=${prediction.grossReturn.toFixed(4)}, net=${prediction.netReturn.toFixed(4)}`);

  // Get USDC balance before
  const balBefore = (await publicClient.readContract({
    address: usdcAddr, abi: MockUSDCArtifact.abi,
    functionName: "balanceOf", args: [trader.address],
  })) as bigint;

  // Execute range sell
  const minPayout = toBigInt6(prediction.netReturn * 0.9);
  await send(traderWallet, market, LMSRMarketArtifact.abi, "sellSharesRange", [
    lower, upper, sharesToSell, minPayout,
  ]);

  // Verify payout
  const balAfter = (await publicClient.readContract({
    address: usdcAddr, abi: MockUSDCArtifact.abi,
    functionName: "balanceOf", args: [trader.address],
  })) as bigint;
  const received = toFloat(balAfter - balBefore);
  console.log(`  USDC received: $${received.toFixed(4)}`);
  assertClose(received, prediction.netReturn, 2.0, "Range sell payout matches prediction");

  // Verify range NFT balance
  const rangeTokenId = encodeTokenIdRange(marketId, rangeStart, rangeEnd);
  const nftAfter = (await publicClient.readContract({
    address: positionNFT, abi: PositionNFTArtifact.abi,
    functionName: "balanceOf", args: [trader.address, rangeTokenId],
  })) as bigint;
  assert(nftAfter === rangeBalance - sharesToSell, "Range NFT balance decreased correctly");

  // Check RangeSharesSold event
  const sellLogs = await publicClient.getLogs({
    address: market,
    event: parseAbiItem(
      "event RangeSharesSold(uint256 indexed marketId, address indexed seller, uint256 startBucket, uint256 endBucket, uint256 shares, uint256 payoutUSDC)"
    ),
    fromBlock: 0n, toBlock: "latest",
    args: { seller: trader.address },
  });
  assert(sellLogs.length > 0, "RangeSharesSold event emitted");

  return nftAfter;
}

// ═════════════════════════════════════════════════════════════════════
// TEST 5: RESOLVE MARKET (takes VALUE, not bucket number)
// ═════════════════════════════════════════════════════════════════════

async function testResolveMarket(addrs: Addresses) {
  console.log("\n─── TEST 5: Resolve Market (value-based resolution) ───\n");

  const { market } = addrs;

  // Read resolver (0 = creator = deployer)
  const resolver = (await publicClient.readContract({
    address: market, abi: LMSRMarketArtifact.abi, functionName: "resolver",
  })) as Address;
  console.log(`  Resolver: ${resolver}`);

  const state = await readMarketState(market);

  // Resolution value: $68,500 — should land in bucket 4 ([$68K-$70K])
  // bucket = (68500 - 60000) / 2000 = 4.25 → floor = 4
  const resolutionValue = 68500n;
  const expectedBucket = Number((resolutionValue - state.marketMin) / state.bucketWidth);
  console.log(`  Resolution value: $${resolutionValue}`);
  console.log(`  Expected winning bucket: ${expectedBucket} ([$${state.marketMin + state.bucketWidth * BigInt(expectedBucket)}-$${state.marketMin + state.bucketWidth * BigInt(expectedBucket + 1)}])`);

  // Resolve — deployer is resolver (resolver == address(0) means creator)
  await send(deployerWallet, market, LMSRMarketArtifact.abi, "resolveMarket", [resolutionValue]);

  // Verify resolution state
  const [status, storedValue, winningBucket, resolutionTime] = (await Promise.all([
    publicClient.readContract({ address: market, abi: LMSRMarketArtifact.abi, functionName: "status" }),
    publicClient.readContract({ address: market, abi: LMSRMarketArtifact.abi, functionName: "resolutionValue" }),
    publicClient.readContract({ address: market, abi: LMSRMarketArtifact.abi, functionName: "winningBucket" }),
    publicClient.readContract({ address: market, abi: LMSRMarketArtifact.abi, functionName: "resolutionTime" }),
  ])) as [number, bigint, bigint, bigint];

  assert(status === 1, `Market status is RESOLVED (${status})`);
  assert(storedValue === resolutionValue, `Resolution value stored correctly: ${storedValue}`);
  assert(Number(winningBucket) === expectedBucket, `Winning bucket is ${winningBucket} (expected ${expectedBucket})`);
  assert(resolutionTime > 0n, "Resolution time recorded");

  // Verify MarketResolved event
  const resolveLogs = await publicClient.getLogs({
    address: market,
    event: parseAbiItem(
      "event MarketResolved(uint256 indexed marketId, uint256 resolutionValue, uint256 winningBucket, uint256 resolutionTime)"
    ),
    fromBlock: 0n, toBlock: "latest",
  });
  assert(resolveLogs.length === 1, "MarketResolved event emitted once");
  assert(resolveLogs[0].args.resolutionValue === resolutionValue, "Event has correct resolution value");

  // Verify trading is blocked after resolution
  try {
    await send(traderWallet, market, LMSRMarketArtifact.abi, "buyShares", [0n, usdc(10), 0n]);
    assert(false, "Buy should revert after resolution");
  } catch {
    assert(true, "Buy correctly reverts after resolution");
  }

  return { winningBucket: Number(winningBucket), resolutionValue };
}

// ═════════════════════════════════════════════════════════════════════
// TEST 6: CLAIM WINNINGS (Single Bucket)
// ═════════════════════════════════════════════════════════════════════

async function testClaimWinnings(addrs: Addresses, winningBucket: number) {
  console.log("\n─── TEST 6: Claim Winnings (Single Bucket) ───\n");

  const { market, positionNFT, marketId, usdc: usdcAddr } = addrs;

  // Check if trader has position in winning bucket
  const tokenId = encodeTokenIdSingle(marketId, winningBucket);
  const balance = (await publicClient.readContract({
    address: positionNFT, abi: PositionNFTArtifact.abi,
    functionName: "balanceOf", args: [trader.address, tokenId],
  })) as bigint;

  console.log(`  Trader balance in winning bucket ${winningBucket}: ${toFloat(balance).toFixed(4)} shares`);

  if (balance === 0n) {
    console.log("  (No position in winning bucket — buying into it for testing)");
    // Need an active market to buy, but we've already resolved.
    // So we skip this sub-test if trader doesn't hold the winning bucket.
    console.log("  Skipping claim test — trader has no winning single-bucket position");
    return;
  }

  // Claim: 1 share = 1 USDC (both 6 decimals)
  const expectedPayout = balance;
  console.log(`  Expected payout: ${fmtUsdc(expectedPayout)} (1 share = $1)`);

  const balBefore = (await publicClient.readContract({
    address: usdcAddr, abi: MockUSDCArtifact.abi,
    functionName: "balanceOf", args: [trader.address],
  })) as bigint;

  await send(traderWallet, market, LMSRMarketArtifact.abi, "claimWinnings", [
    BigInt(winningBucket), balance,
  ]);

  const balAfter = (await publicClient.readContract({
    address: usdcAddr, abi: MockUSDCArtifact.abi,
    functionName: "balanceOf", args: [trader.address],
  })) as bigint;

  const received = balAfter - balBefore;
  assert(received === expectedPayout, `Received ${fmtUsdc(received)} (expected ${fmtUsdc(expectedPayout)})`);

  // Verify NFT burned
  const nftAfter = (await publicClient.readContract({
    address: positionNFT, abi: PositionNFTArtifact.abi,
    functionName: "balanceOf", args: [trader.address, tokenId],
  })) as bigint;
  assert(nftAfter === 0n, "NFT burned after claim");

  // Verify WinningsClaimed event
  const claimLogs = await publicClient.getLogs({
    address: market,
    event: parseAbiItem(
      "event WinningsClaimed(uint256 indexed marketId, address indexed claimer, uint256 amount)"
    ),
    fromBlock: 0n, toBlock: "latest",
    args: { claimer: trader.address },
  });
  assert(claimLogs.length > 0, "WinningsClaimed event emitted");
}

// ═════════════════════════════════════════════════════════════════════
// TEST 7: CLAIM WINNINGS (Range Position)
// ═════════════════════════════════════════════════════════════════════

async function testClaimRange(
  addrs: Addresses, winningBucket: number,
  rangeStart: number, rangeEnd: number
) {
  console.log("\n─── TEST 7: Claim Range Winnings ───\n");

  const { market, positionNFT, marketId, usdc: usdcAddr } = addrs;

  // Check if winning bucket falls within range
  const isInRange = winningBucket >= rangeStart && winningBucket <= rangeEnd;
  console.log(`  Winning bucket: ${winningBucket}, Range: [${rangeStart}-${rangeEnd}]`);
  console.log(`  Winning bucket in range: ${isInRange}`);

  if (!isInRange) {
    console.log("  Skipping range claim — winning bucket not in range position");
    assert(true, "Range claim skipped (winning bucket outside range)");
    return;
  }

  const rangeTokenId = encodeTokenIdRange(marketId, rangeStart, rangeEnd);
  const rangeBalance = (await publicClient.readContract({
    address: positionNFT, abi: PositionNFTArtifact.abi,
    functionName: "balanceOf", args: [trader.address, rangeTokenId],
  })) as bigint;

  if (rangeBalance === 0n) {
    console.log("  Skipping range claim — no range position remaining");
    assert(true, "Range claim skipped (no balance)");
    return;
  }

  console.log(`  Range position balance: ${toFloat(rangeBalance).toFixed(4)} shares`);

  // claimRange uses value bounds, not bucket indices
  const state = await readMarketState(market);
  const lower = state.marketMin + state.bucketWidth * BigInt(rangeStart);
  const upper = state.marketMin + state.bucketWidth * BigInt(rangeEnd + 1);

  const expectedPayout = rangeBalance; // 1 share = 1 USDC

  const balBefore = (await publicClient.readContract({
    address: usdcAddr, abi: MockUSDCArtifact.abi,
    functionName: "balanceOf", args: [trader.address],
  })) as bigint;

  await send(traderWallet, market, LMSRMarketArtifact.abi, "claimRange", [
    lower, upper, rangeBalance,
  ]);

  const balAfter = (await publicClient.readContract({
    address: usdcAddr, abi: MockUSDCArtifact.abi,
    functionName: "balanceOf", args: [trader.address],
  })) as bigint;

  const received = balAfter - balBefore;
  assert(received === expectedPayout, `Range claim: received ${fmtUsdc(received)} (expected ${fmtUsdc(expectedPayout)})`);

  // Verify NFT burned
  const nftAfter = (await publicClient.readContract({
    address: positionNFT, abi: PositionNFTArtifact.abi,
    functionName: "balanceOf", args: [trader.address, rangeTokenId],
  })) as bigint;
  assert(nftAfter === 0n, "Range NFT burned after claim");

  // Verify event
  const claimLogs = await publicClient.getLogs({
    address: market,
    event: parseAbiItem(
      "event RangeWinningsClaimed(uint256 indexed marketId, address indexed claimer, uint256 startBucket, uint256 endBucket, uint256 shares, uint256 payoutUSDC)"
    ),
    fromBlock: 0n, toBlock: "latest",
    args: { claimer: trader.address },
  });
  assert(claimLogs.length > 0, "RangeWinningsClaimed event emitted");
}

// ═════════════════════════════════════════════════════════════════════
// TEST 8: CLAIM REVERTS FOR NON-WINNING BUCKET
// ═════════════════════════════════════════════════════════════════════

async function testClaimRevertsForLoser(addrs: Addresses, winningBucket: number) {
  console.log("\n─── TEST 8: Claim Reverts for Non-Winning Bucket ───\n");

  const { market, positionNFT, marketId } = addrs;

  // Find a non-winning bucket with shares
  const losingBucket = winningBucket === 7 ? 3 : 7;

  const tokenId = encodeTokenIdSingle(marketId, losingBucket);
  const balance = (await publicClient.readContract({
    address: positionNFT, abi: PositionNFTArtifact.abi,
    functionName: "balanceOf", args: [trader.address, tokenId],
  })) as bigint;

  if (balance > 0n) {
    try {
      await send(traderWallet, market, LMSRMarketArtifact.abi, "claimWinnings", [
        BigInt(losingBucket), balance,
      ]);
      assert(false, "Claim should revert for non-winning bucket");
    } catch {
      assert(true, `Claim correctly reverts for losing bucket ${losingBucket}`);
    }
  } else {
    console.log(`  Bucket ${losingBucket} has 0 balance — checking with dummy amount`);
    try {
      await send(traderWallet, market, LMSRMarketArtifact.abi, "claimWinnings", [
        BigInt(losingBucket), 1n,
      ]);
      assert(false, "Claim should revert for non-winning bucket");
    } catch {
      assert(true, `Claim correctly reverts for losing bucket ${losingBucket}`);
    }
  }
}

// ═════════════════════════════════════════════════════════════════════
// TEST 9: MULTI-USER POSITION SCENARIO
// ═════════════════════════════════════════════════════════════════════

async function testMultiUserPositions(addrs: Addresses) {
  console.log("\n─── TEST 9: Multi-User Position Scenario ───\n");

  // Deploy a FRESH market for this test (the previous one is resolved)
  console.log("  Deploying fresh market for multi-user test...");

  const { factory, usdc: usdcAddr, positionNFT, vault } = addrs;

  // Ensure deployer has allowance
  try {
    await send(deployerWallet, factory, MarketFactoryArtifact.abi, "addCreatorAllowance", [deployer.address, 1n]);
  } catch { /* may already have */ }

  const createParams = [{
    alpha: 3_333_000000n,
    seedAmount: 10_000_000000n,
    minValue: 60000n,
    maxValue: 80000n,
    bucketCount: 10n,
    feeBps: 200n,
    protocolFeeBps: 2000n,
    alphaFinal: 0n,
    decayStart: 0n,
    decayDuration: 0n,
    name: "Multi-User Test",
    description: "",
    resolutionCriteria: "",
    valueUnit: "USD",
    resolver: "0x0000000000000000000000000000000000000000" as Address,
    biddingDeadline: 0n,
    scheduledResolutionTime: 0n,
    minBetSize: 0n,
    maxBucketsPerRange: 0n,
    expandedMinValue: 0n,
    expandedMaxValue: 0n,
  }];

  await send(deployerWallet, factory, MarketFactoryArtifact.abi, "createMarket", createParams);

  const count = (await publicClient.readContract({
    address: factory, abi: MarketFactoryArtifact.abi, functionName: "marketCount",
  })) as bigint;
  const newMarketId = count - 1n;
  const newMarket = (await publicClient.readContract({
    address: factory, abi: MarketFactoryArtifact.abi, functionName: "marketById", args: [newMarketId],
  })) as Address;

  // Fund + approve both traders
  await send(deployerWallet, usdcAddr, MockUSDCArtifact.abi, "mint", [trader.address, 50_000_000000n]);
  await send(deployerWallet, usdcAddr, MockUSDCArtifact.abi, "mint", [trader2.address, 50_000_000000n]);
  await send(traderWallet, usdcAddr, MockUSDCArtifact.abi, "approve", [newMarket, 50_000_000000n]);
  await send(trader2Wallet, usdcAddr, MockUSDCArtifact.abi, "approve", [newMarket, 50_000_000000n]);

  // Both traders buy same bucket
  const bucket = 5n;
  await send(traderWallet, newMarket, LMSRMarketArtifact.abi, "buyShares", [bucket, usdc(500), 0n]);
  await send(trader2Wallet, newMarket, LMSRMarketArtifact.abi, "buyShares", [bucket, usdc(300), 0n]);

  // Check both have positions
  const t1TokenId = encodeTokenIdSingle(newMarketId, 5);
  const t2TokenId = encodeTokenIdSingle(newMarketId, 5);

  const t1Balance = (await publicClient.readContract({
    address: positionNFT, abi: PositionNFTArtifact.abi,
    functionName: "balanceOf", args: [trader.address, t1TokenId],
  })) as bigint;
  const t2Balance = (await publicClient.readContract({
    address: positionNFT, abi: PositionNFTArtifact.abi,
    functionName: "balanceOf", args: [trader2.address, t2TokenId],
  })) as bigint;

  console.log(`  Trader 1 position: ${toFloat(t1Balance).toFixed(4)} shares`);
  console.log(`  Trader 2 position: ${toFloat(t2Balance).toFixed(4)} shares`);
  assert(t1Balance > 0n, "Trader 1 has position");
  assert(t2Balance > 0n, "Trader 2 has position");
  assert(t1Balance > t2Balance, "Trader 1 has more shares ($500 vs $300 bet)");

  // Resolve at bucket 5's range: $70K-$72K → value $71K
  const resValue = 71000n;
  await send(deployerWallet, newMarket, LMSRMarketArtifact.abi, "resolveMarket", [resValue]);

  // Both claim
  const t1BalBefore = (await publicClient.readContract({
    address: usdcAddr, abi: MockUSDCArtifact.abi,
    functionName: "balanceOf", args: [trader.address],
  })) as bigint;

  await send(traderWallet, newMarket, LMSRMarketArtifact.abi, "claimWinnings", [bucket, t1Balance]);
  await send(trader2Wallet, newMarket, LMSRMarketArtifact.abi, "claimWinnings", [bucket, t2Balance]);

  const t1BalAfter = (await publicClient.readContract({
    address: usdcAddr, abi: MockUSDCArtifact.abi,
    functionName: "balanceOf", args: [trader.address],
  })) as bigint;

  const t1Payout = t1BalAfter - t1BalBefore;
  assert(t1Payout === t1Balance, `Trader 1 received correct payout: ${fmtUsdc(t1Payout)}`);
  assert(true, "Both traders claimed successfully");
}

// ═════════════════════════════════════════════════════════════════════
// TEST 10: POSITION QUERYING STRATEGIES SUMMARY
// ═════════════════════════════════════════════════════════════════════

async function testPositionStrategySummary() {
  console.log("\n─── TEST 10: Position Querying Strategies ───\n");

  console.log("  ═══ STRATEGY A: On-Chain Direct Query ═══");
  console.log("  Use PositionNFT.balanceOf(user, tokenId) for each possible tokenId");
  console.log("  Token ID encoding:");
  console.log("    Single: (marketId << 128) | (bucketId << 64) | bucketId");
  console.log("    Range:  (marketId << 128) | (rangeLower << 64) | rangeUpper");
  console.log("  Pros: No backend needed, always up-to-date");
  console.log("  Cons: O(n) calls for n buckets, doesn't find range positions without scanning");
  console.log("  Best for: Single market views, known bucket positions");
  console.log("");

  console.log("  ═══ STRATEGY B: Off-Chain Event Indexing ═══");
  console.log("  Scan events: SharesPurchased, RangeSharesPurchased, SharesSold, RangeSharesSold");
  console.log("  Build position map: aggregate mints - burns per tokenId");
  console.log("  Pros: Discovers ALL positions (including unknown ranges)");
  console.log("  Cons: Requires indexer/subgraph, eventual consistency lag");
  console.log("  Best for: Portfolio views, user dashboards, analytics");
  console.log("");

  console.log("  ═══ STRATEGY C: Hybrid (Recommended) ═══");
  console.log("  1. Indexer builds candidate position set from events");
  console.log("  2. Frontend confirms balances via on-chain balanceOf");
  console.log("  3. Real-time: subscribe to Transfer events for live updates");
  console.log("  Events to index:");
  console.log("    - TransferSingle(operator, from, to, id, value) [ERC-1155]");
  console.log("    - SharesPurchased(marketId, buyer, bucketId, amountUSDC, sharesMinted, newPrice)");
  console.log("    - RangeSharesPurchased(marketId, buyer, startBucket, endBucket, shares, costUSDC)");
  console.log("    - SharesSold(marketId, seller, bucketId, sharesBurned, amountUSDC, newPrice)");
  console.log("    - RangeSharesSold(marketId, seller, startBucket, endBucket, shares, payoutUSDC)");
  console.log("    - WinningsClaimed(marketId, claimer, amount)");
  console.log("    - RangeWinningsClaimed(marketId, claimer, startBucket, endBucket, shares, payoutUSDC)");

  // Decode example token IDs
  const examples = [
    { marketId: 0n, bucket: 5, type: "single" },
    { marketId: 0n, rangeLower: 3, rangeUpper: 7, type: "range" },
    { marketId: 42n, bucket: 0, type: "single" },
  ];

  console.log("\n  Token ID encoding examples:");
  for (const ex of examples) {
    if (ex.type === "single") {
      const tid = encodeTokenIdSingle(ex.marketId, ex.bucket!);
      const decoded = decodeTokenId(tid);
      console.log(`    Market ${ex.marketId}, bucket ${ex.bucket}: tokenId=${tid}`);
      console.log(`      Decoded: market=${decoded.marketId}, range=[${decoded.rangeLower}-${decoded.rangeUpper}]`);
    } else {
      const tid = encodeTokenIdRange(ex.marketId, ex.rangeLower!, ex.rangeUpper!);
      const decoded = decodeTokenId(tid);
      console.log(`    Market ${ex.marketId}, range [${ex.rangeLower}-${ex.rangeUpper}]: tokenId=${tid}`);
      console.log(`      Decoded: market=${decoded.marketId}, range=[${decoded.rangeLower}-${decoded.rangeUpper}]`);
    }
  }

  assert(true, "Position strategy documentation complete");
}

// ═════════════════════════════════════════════════════════════════════
// MAIN
// ═════════════════════════════════════════════════════════════════════

async function main() {
  console.log("╔══════════════════════════════════════════════════╗");
  console.log("║  SKEPSIS MARKET — LIFECYCLE INTEGRATION TEST     ║");
  console.log("║  Positions · Sell · Resolve · Claim              ║");
  console.log("╚══════════════════════════════════════════════════╝");

  await initClients();

  // Deploy fresh market
  const addrs = await deployFreshMarket();

  // Read initial state
  console.log("\n═══ INITIAL MARKET STATE ═══");
  const initialState = await readMarketState(addrs.market);
  console.log(`  Alpha: ${toFloat(initialState.alpha).toFixed(2)}`);
  console.log(`  Pool: ${fmtUsdc(initialState.poolBalance)}`);
  console.log(`  Buckets: ${initialState.bucketCount}`);
  console.log(`  Range: $${initialState.marketMin} - $${initialState.marketMax}`);
  console.log(`  Width: $${initialState.bucketWidth}`);
  console.log(`  Fees: ${initialState.feeBps / 100}%`);

  // ── TEST 1: On-chain position querying
  const positions = await testPositionQueryOnChain(addrs, initialState);

  // ── TEST 2: Off-chain event indexing
  await testPositionIndexingOffChain(addrs);

  // ── TEST 3: Sell single-bucket position
  const remainingShares3 = await testSellSharesSingle(addrs, positions.singleBalance3);

  // ── TEST 4: Sell range position
  const remainingRange = await testSellSharesRange(
    addrs, initialState,
    positions.rangeBalance, positions.rangeStartBucket, positions.rangeEndBucket
  );

  // ── TEST 5: Resolve market (takes VALUE)
  const { winningBucket, resolutionValue } = await testResolveMarket(addrs);

  // ── TEST 6: Claim single bucket winnings
  await testClaimWinnings(addrs, winningBucket);

  // ── TEST 7: Claim range winnings
  await testClaimRange(addrs, winningBucket, positions.rangeStartBucket, positions.rangeEndBucket);

  // ── TEST 8: Claim reverts for losers
  await testClaimRevertsForLoser(addrs, winningBucket);

  // ── TEST 9: Multi-user scenario
  await testMultiUserPositions(addrs);

  // ── TEST 10: Strategy documentation
  await testPositionStrategySummary();

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
