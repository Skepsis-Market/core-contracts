#!/usr/bin/env tsx
/**
 * Skepsis Market — Position Tools
 *
 * Standalone utility for querying user positions, selling shares,
 * resolving markets, and claiming winnings.
 *
 * Usage:
 *   npx tsx ts-integration/position-tools.ts positions <market> <user>
 *   npx tsx ts-integration/position-tools.ts sell-single <market> <bucket> <shares>
 *   npx tsx ts-integration/position-tools.ts sell-range <market> <lower> <upper> <shares>
 *   npx tsx ts-integration/position-tools.ts resolve <market> <value>
 *   npx tsx ts-integration/position-tools.ts claim <market> <bucket> <shares>
 *   npx tsx ts-integration/position-tools.ts claim-range <market> <lower> <upper> <shares>
 *   npx tsx ts-integration/position-tools.ts demo   (full lifecycle demo against deployed contracts)
 */

import {
  createPublicClient,
  createWalletClient,
  http,
  getAddress,
  formatUnits,
  parseAbiItem,
  defineChain,
  type Address,
  type Hex,
  type PublicClient,
  type WalletClient,
  type Chain,
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
// SETUP
// ═════════════════════════════════════════════════════════════════════

const __dirname = dirname(fileURLToPath(import.meta.url));
const ABIS_DIR = join(__dirname, "abis");

function loadAbi(name: string) {
  return JSON.parse(readFileSync(join(ABIS_DIR, `${name}.json`), "utf-8")).abi;
}

const MarketAbi = loadAbi("LMSRMarket");
const PositionNFTAbi = loadAbi("PositionNFT");
const MockUSDCAbi = loadAbi("MockUSDC");
const FactoryAbi = loadAbi("MarketFactory");
const VaultAbi = loadAbi("Vault");

const RPC = process.env.RPC_URL || "http://127.0.0.1:8545";

let localChain: Chain;
let pub: PublicClient;

async function init() {
  const raw = createPublicClient({ transport: http(RPC) });
  const chainId = await raw.getChainId();
  localChain = defineChain({
    id: chainId,
    name: "local",
    nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: { default: { http: [RPC] } },
  });
  pub = createPublicClient({ chain: localChain, transport: http(RPC) });
}

function wallet(key: Hex): WalletClient {
  return createWalletClient({
    account: privateKeyToAccount(key),
    chain: localChain,
    transport: http(RPC),
  });
}

function fmtUsdc(val: bigint): string {
  return `$${formatUnits(val, 6)}`;
}

async function send(w: WalletClient, to: Address, abi: any[], fn: string, args: any[]) {
  const hash = await w.writeContract({
    address: to, abi, functionName: fn, args,
    chain: localChain, account: w.account!,
  });
  await pub.waitForTransactionReceipt({ hash });
  return hash;
}

// ═════════════════════════════════════════════════════════════════════
// TOKEN ID ENCODING (mirrors PositionNFT.sol)
// ═════════════════════════════════════════════════════════════════════

export function encodeTokenId(marketId: bigint, rangeLower: number, rangeUpper: number): bigint {
  return (marketId << 128n) | (BigInt(rangeLower) << 64n) | BigInt(rangeUpper);
}

export function decodeTokenId(tokenId: bigint) {
  return {
    marketId: tokenId >> 128n,
    rangeLower: Number((tokenId >> 64n) & 0xFFFFFFFFFFFFFFFFn),
    rangeUpper: Number(tokenId & 0xFFFFFFFFFFFFFFFFn),
  };
}

// ═════════════════════════════════════════════════════════════════════
// READ MARKET STATE
// ═════════════════════════════════════════════════════════════════════

async function readMarketState(market: Address): Promise<MarketState> {
  const [alpha, poolBalance, bucketCount, feeBps, marketMin, marketMax, bucketWidth] =
    (await Promise.all([
      pub.readContract({ address: market, abi: MarketAbi, functionName: "alpha" }),
      pub.readContract({ address: market, abi: MarketAbi, functionName: "poolBalance" }),
      pub.readContract({ address: market, abi: MarketAbi, functionName: "bucketCount" }),
      pub.readContract({ address: market, abi: MarketAbi, functionName: "feeBps" }),
      pub.readContract({ address: market, abi: MarketAbi, functionName: "marketMin" }),
      pub.readContract({ address: market, abi: MarketAbi, functionName: "marketMax" }),
      pub.readContract({ address: market, abi: MarketAbi, functionName: "bucketWidth" }),
    ])) as [bigint, bigint, bigint, bigint, bigint, bigint, bigint];

  const count = Number(bucketCount);
  const buckets: BucketData[] = [];
  for (let i = 0; i < count; i++) {
    const b = (await pub.readContract({
      address: market, abi: MarketAbi, functionName: "getBucket", args: [BigInt(i)],
    })) as { shares: bigint; lowerBound: bigint; upperBound: bigint };
    buckets.push({ shares: b.shares, lowerBound: b.lowerBound, upperBound: b.upperBound });
  }

  return { alpha, bucketCount: count, buckets, feeBps: Number(feeBps), poolBalance, marketMin, marketMax, bucketWidth };
}

// ═════════════════════════════════════════════════════════════════════
// POSITION QUERYING
// ═════════════════════════════════════════════════════════════════════

interface Position {
  type: "single" | "range";
  bucketId?: number;
  rangeLower?: number;
  rangeUpper?: number;
  shares: bigint;
  tokenId: bigint;
}

/** Query all positions for a user in a market (on-chain scan) */
async function queryPositionsOnChain(
  market: Address, positionNFT: Address, user: Address, marketId: bigint, bucketCount: number
): Promise<Position[]> {
  const positions: Position[] = [];

  // Scan single-bucket positions
  for (let i = 0; i < bucketCount; i++) {
    const tokenId = encodeTokenId(marketId, i, i);
    const bal = (await pub.readContract({
      address: positionNFT, abi: PositionNFTAbi,
      functionName: "balanceOf", args: [user, tokenId],
    })) as bigint;
    if (bal > 0n) {
      positions.push({ type: "single", bucketId: i, shares: bal, tokenId });
    }
  }

  // Scan range positions (all possible ranges up to 10 wide)
  const maxRangeWidth = Math.min(bucketCount, 10);
  for (let start = 0; start < bucketCount; start++) {
    for (let end = start + 1; end < Math.min(start + maxRangeWidth, bucketCount); end++) {
      const tokenId = encodeTokenId(marketId, start, end);
      const bal = (await pub.readContract({
        address: positionNFT, abi: PositionNFTAbi,
        functionName: "balanceOf", args: [user, tokenId],
      })) as bigint;
      if (bal > 0n) {
        positions.push({ type: "range", rangeLower: start, rangeUpper: end, shares: bal, tokenId });
      }
    }
  }

  return positions;
}

/** Query positions via event indexing (off-chain strategy) */
async function queryPositionsFromEvents(
  market: Address, user: Address
): Promise<{ buys: any[]; rangeBuys: any[]; sells: any[]; rangeSells: any[] }> {
  const buys = await pub.getLogs({
    address: market,
    event: parseAbiItem(
      "event SharesPurchased(uint256 indexed marketId, address indexed buyer, uint256 indexed bucketId, uint256 amountUSDC, uint256 sharesMinted, uint256 newPrice)"
    ),
    fromBlock: 0n, toBlock: "latest",
    args: { buyer: user },
  });

  const rangeBuys = await pub.getLogs({
    address: market,
    event: parseAbiItem(
      "event RangeSharesPurchased(uint256 indexed marketId, address indexed buyer, uint256 startBucket, uint256 endBucket, uint256 shares, uint256 costUSDC)"
    ),
    fromBlock: 0n, toBlock: "latest",
    args: { buyer: user },
  });

  const sells = await pub.getLogs({
    address: market,
    event: parseAbiItem(
      "event SharesSold(uint256 indexed marketId, address indexed seller, uint256 indexed bucketId, uint256 sharesBurned, uint256 amountUSDC, uint256 newPrice)"
    ),
    fromBlock: 0n, toBlock: "latest",
    args: { seller: user },
  });

  const rangeSells = await pub.getLogs({
    address: market,
    event: parseAbiItem(
      "event RangeSharesSold(uint256 indexed marketId, address indexed seller, uint256 startBucket, uint256 endBucket, uint256 shares, uint256 payoutUSDC)"
    ),
    fromBlock: 0n, toBlock: "latest",
    args: { seller: user },
  });

  return { buys, rangeBuys, sells, rangeSells };
}

// ═════════════════════════════════════════════════════════════════════
// SELL OPERATIONS
// ═════════════════════════════════════════════════════════════════════

/** Preview and execute a single-bucket sell */
async function sellSingle(
  w: WalletClient, market: Address, state: MarketState,
  bucketId: number, sharesToSell: bigint, slippagePct = 10
) {
  const preview = calculateSellReturn(state, bucketId, sharesToSell);
  const minPayout = toBigInt6(preview.netReturn * (100 - slippagePct) / 100);

  console.log(`  Preview: gross=${fmtUsdc(toBigInt6(preview.grossReturn))}, net=${fmtUsdc(toBigInt6(preview.netReturn))}`);

  const hash = await send(w, market, MarketAbi, "sellShares", [
    BigInt(bucketId), sharesToSell, minPayout,
  ]);
  console.log(`  Tx: ${hash}`);
  return preview;
}

/** Preview and execute a range sell */
async function sellRange(
  w: WalletClient, market: Address, state: MarketState,
  lower: bigint, upper: bigint, sharesToSell: bigint, slippagePct = 10
) {
  const preview = calculateRangeSellReturn(state, lower, upper, sharesToSell);
  const minPayout = toBigInt6(preview.netReturn * (100 - slippagePct) / 100);

  console.log(`  Preview: gross=${fmtUsdc(toBigInt6(preview.grossReturn))}, net=${fmtUsdc(toBigInt6(preview.netReturn))}`);

  const hash = await send(w, market, MarketAbi, "sellSharesRange", [
    lower, upper, sharesToSell, minPayout,
  ]);
  console.log(`  Tx: ${hash}`);
  return preview;
}

// ═════════════════════════════════════════════════════════════════════
// RESOLUTION
// ═════════════════════════════════════════════════════════════════════

/** Resolve a market with a value (not bucket number) */
async function resolveMarket(w: WalletClient, market: Address, resolutionValue: bigint) {
  const hash = await send(w, market, MarketAbi, "resolveMarket", [resolutionValue]);
  const winningBucket = (await pub.readContract({
    address: market, abi: MarketAbi, functionName: "winningBucket",
  })) as bigint;
  console.log(`  Resolved at value ${resolutionValue} -> winning bucket ${winningBucket}`);
  console.log(`  Tx: ${hash}`);
  return Number(winningBucket);
}

// ═════════════════════════════════════════════════════════════════════
// CLAIM OPERATIONS
// ═════════════════════════════════════════════════════════════════════

/** Claim winnings from a single-bucket position */
async function claimSingle(w: WalletClient, market: Address, bucketId: number, shares: bigint) {
  const hash = await send(w, market, MarketAbi, "claimWinnings", [BigInt(bucketId), shares]);
  console.log(`  Claimed ${fmtUsdc(shares)} from bucket ${bucketId} (1 share = $1)`);
  console.log(`  Tx: ${hash}`);
}

/** Claim winnings from a range position */
async function claimRange(
  w: WalletClient, market: Address, lower: bigint, upper: bigint, shares: bigint
) {
  const hash = await send(w, market, MarketAbi, "claimRange", [lower, upper, shares]);
  console.log(`  Claimed ${fmtUsdc(shares)} from range [$${lower}-$${upper}]`);
  console.log(`  Tx: ${hash}`);
}

// ═════════════════════════════════════════════════════════════════════
// DEMO: Full Lifecycle
// ═════════════════════════════════════════════════════════════════════

async function demo() {
  console.log("\n=== SKEPSIS LIFECYCLE DEMO ===\n");

  // Load .env.local
  const envContent = readFileSync(join(__dirname, "..", ".env.local"), "utf-8");
  const env = Object.fromEntries(
    envContent.split("\n")
      .filter(l => l.includes("=") && !l.startsWith("#"))
      .map(l => { const [k, ...v] = l.split("="); return [k.trim(), v.join("=").trim()]; })
  );

  const DEPLOYER_KEY = env.PRIVATE_KEY as Hex;
  const TRADER_KEY = "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d" as Hex;

  const deployer = privateKeyToAccount(DEPLOYER_KEY);
  const trader = privateKeyToAccount(TRADER_KEY);
  const deployerW = wallet(DEPLOYER_KEY);
  const traderW = wallet(TRADER_KEY);

  const factory = getAddress(env.FACTORY_ADDRESS);
  const usdcAddr = getAddress(env.USDC_ADDRESS);
  const vault = getAddress(env.VAULT_ADDRESS);
  const positionNFT = getAddress(env.POSITION_NFT_ADDRESS);

  // ── 1. Create market ──────────────────────────────────────────────
  console.log("1. Creating market: BTC/USD $60K-$80K, 10 buckets\n");

  // Ensure funds + allowance
  await send(deployerW, usdcAddr, MockUSDCAbi, "mint", [deployer.address, 500_000_000000n]);
  await send(deployerW, usdcAddr, MockUSDCAbi, "approve", [vault, 500_000_000000n]);
  try { await send(deployerW, vault, VaultAbi, "deposit", [200_000_000000n, deployer.address]); } catch {}
  try { await send(deployerW, factory, FactoryAbi, "addCreatorAllowance", [deployer.address, 5n]); } catch {}

  const SEED = 10_000_000000n;
  await send(deployerW, factory, FactoryAbi, "createMarket", [{
    alpha: SEED / 3n, seedAmount: SEED,
    minValue: 60000n, maxValue: 80000n, bucketCount: 10n,
    feeBps: 200n, protocolFeeBps: 2000n,
    alphaFinal: 0n, decayStart: 0n, decayDuration: 0n,
    expandedMinValue: 0n, expandedMaxValue: 0n,
    name: "BTC/USD Demo", description: "Lifecycle demo",
    resolutionCriteria: "CoinGecko", valueUnit: "USD",
    resolver: "0x0000000000000000000000000000000000000000" as Address,
    biddingDeadline: 0n, scheduledResolutionTime: 0n,
    minBetSize: 0n, maxBucketsPerRange: 0n,
  }]);

  const marketCount = (await pub.readContract({ address: factory, abi: FactoryAbi, functionName: "marketCount" })) as bigint;
  const marketId = marketCount - 1n;
  const market = (await pub.readContract({ address: factory, abi: FactoryAbi, functionName: "marketById", args: [marketId] })) as Address;
  console.log(`  Market: ${market} (id=${marketId})\n`);

  // ── 2. Buy positions ──────────────────────────────────────────────
  console.log("2. Buying positions\n");

  await send(deployerW, usdcAddr, MockUSDCAbi, "mint", [trader.address, 100_000_000000n]);
  await send(traderW, usdcAddr, MockUSDCAbi, "approve", [market, 100_000_000000n]);

  // Single bucket: $68K-$70K (bucket 4)
  await send(traderW, market, MarketAbi, "buyShares", [4n, 500_000000n, 0n]);
  console.log("  Bought $500 in bucket 4 ($68K-$70K)");

  // Range: $64K-$70K (buckets 2-4)
  await send(traderW, market, MarketAbi, "buySharesRange", [64000n, 70000n, 300_000000n, 0n, 0n]);
  console.log("  Bought $300 range [$64K-$70K]\n");

  // ── 3. Query positions ────────────────────────────────────────────
  console.log("3. Querying positions\n");

  const state = await readMarketState(market);
  const positions = await queryPositionsOnChain(market, positionNFT, trader.address, marketId, state.bucketCount);

  console.log("  On-chain positions:");
  for (const p of positions) {
    if (p.type === "single") {
      const lower = state.marketMin + state.bucketWidth * BigInt(p.bucketId!);
      const upper = lower + state.bucketWidth;
      console.log(`    Bucket ${p.bucketId} [$${lower}-$${upper}]: ${toFloat(p.shares).toFixed(4)} shares`);
    } else {
      console.log(`    Range [${p.rangeLower}-${p.rangeUpper}]: ${toFloat(p.shares).toFixed(4)} shares`);
    }
  }

  const events = await queryPositionsFromEvents(market, trader.address);
  console.log(`\n  Event history: ${events.buys.length} buys, ${events.rangeBuys.length} range buys\n`);

  // ── 4. Sell partial position ──────────────────────────────────────
  console.log("4. Selling half of bucket 4 position\n");

  const bucket4Pos = positions.find(p => p.type === "single" && p.bucketId === 4);
  if (bucket4Pos) {
    const halfShares = bucket4Pos.shares / 2n;
    const freshState = await readMarketState(market);
    await sellSingle(traderW, market, freshState, 4, halfShares);
    console.log();
  }

  // ── 5. Resolve market ─────────────────────────────────────────────
  console.log("5. Resolving market at $68,500\n");

  const winningBucket = await resolveMarket(deployerW, market, 68500n);
  console.log();

  // ── 6. Claim winnings ─────────────────────────────────────────────
  console.log("6. Claiming winnings\n");

  // Re-query after sell
  const postPositions = await queryPositionsOnChain(market, positionNFT, trader.address, marketId, state.bucketCount);

  for (const p of postPositions) {
    if (p.type === "single" && p.bucketId === winningBucket) {
      console.log(`  Claiming ${toFloat(p.shares).toFixed(4)} shares from winning bucket ${winningBucket}`);
      await claimSingle(traderW, market, winningBucket, p.shares);
    }
    if (p.type === "range" && p.rangeLower! <= winningBucket && p.rangeUpper! >= winningBucket) {
      const lower = state.marketMin + state.bucketWidth * BigInt(p.rangeLower!);
      const upper = state.marketMin + state.bucketWidth * BigInt(p.rangeUpper! + 1);
      console.log(`  Claiming ${toFloat(p.shares).toFixed(4)} range shares from [${p.rangeLower}-${p.rangeUpper}]`);
      await claimRange(traderW, market, lower, upper, p.shares);
    }
  }

  // Non-winning claim should fail
  const losingBucket = winningBucket === 0 ? 1 : 0;
  try {
    await send(traderW, market, MarketAbi, "claimWinnings", [BigInt(losingBucket), 1n]);
    console.log("\n  ERROR: claim from losing bucket should have reverted!");
  } catch {
    console.log(`\n  Correctly rejected claim from losing bucket ${losingBucket}`);
  }

  console.log("\n=== DEMO COMPLETE ===\n");
}

// ═════════════════════════════════════════════════════════════════════
// CLI
// ═════════════════════════════════════════════════════════════════════

async function main() {
  await init();

  const [, , cmd, ...args] = process.argv;

  switch (cmd) {
    case "positions": {
      const [marketAddr, userAddr] = args;
      if (!marketAddr || !userAddr) { console.log("Usage: positions <market> <user>"); break; }
      const market = getAddress(marketAddr);
      const user = getAddress(userAddr);
      const state = await readMarketState(market);
      const marketId = (await pub.readContract({ address: market, abi: MarketAbi, functionName: "marketId" })) as bigint;
      const nft = (await pub.readContract({ address: market, abi: MarketAbi, functionName: "positionNFT" })) as Address;

      console.log(`\nMarket ${market} (id=${marketId})`);
      console.log(`Range: $${state.marketMin}-$${state.marketMax}, ${state.bucketCount} buckets, width=$${state.bucketWidth}\n`);

      const positions = await queryPositionsOnChain(market, nft, user, marketId, state.bucketCount);
      if (positions.length === 0) {
        console.log("No positions found.");
      } else {
        const probs = computeProbabilities(state);
        for (const p of positions) {
          if (p.type === "single") {
            const lower = state.marketMin + state.bucketWidth * BigInt(p.bucketId!);
            const upper = lower + state.bucketWidth;
            console.log(`  Bucket ${p.bucketId} [$${lower}-$${upper}]: ${toFloat(p.shares).toFixed(4)} shares (${(probs[p.bucketId!] * 100).toFixed(1)}% prob)`);
          } else {
            console.log(`  Range [${p.rangeLower}-${p.rangeUpper}]: ${toFloat(p.shares).toFixed(4)} shares`);
          }
        }
      }
      break;
    }

    case "demo":
      await demo();
      break;

    default:
      console.log("Skepsis Position Tools\n");
      console.log("Commands:");
      console.log("  positions <market> <user>  — Query all positions for a user");
      console.log("  demo                       — Run full lifecycle demo");
      console.log("\nExamples:");
      console.log("  npx tsx ts-integration/position-tools.ts positions 0x1234... 0x5678...");
      console.log("  npx tsx ts-integration/position-tools.ts demo");
  }
}

main().catch((err) => { console.error("Error:", err.message || err); process.exit(1); });
