/**
 * Create a BTC price market on Arbitrum Sepolia
 *
 * Market: BTC price tonight at 23:59 UTC
 * Range: $65K - $80K, bucket width $100
 * Seeded: 41 buckets (700-740) gaussian centered at 720 ($72K)
 * Seed amount: 200 USDC
 *
 * Run: npx tsx ts-integration/create-btc-market.ts
 */

import { createWalletClient, createPublicClient, http, parseAbi, formatUnits } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { arbitrumSepolia } from "viem/chains";
import { readFileSync } from "fs";

// ─── Config ──────────────────────────────────────────────────────────────────

const PRIVATE_KEY = process.env.PRIVATE_KEY as `0x${string}`;
if (!PRIVATE_KEY) throw new Error("Set PRIVATE_KEY env var");

const FACTORY = "0x91178A3B4654847b957876feC50214ed9618C757" as const;
const RPC = "https://sepolia-rollup.arbitrum.io/rpc";

// ─── Market parameters ───────────────────────────────────────────────────────

const SEED_AMOUNT = 200_000000n; // 200 USDC (6 decimals)
const BUCKET_WIDTH = 100n; // $100 per bucket
const MAX_BUCKET_ID = 799n; // supports $0 - $79,999 (800 bucket capacity)

// Gaussian center at bucket 720 ($72,000), seeded range 710-730 ($71K-$73K)
const SEED_START = 710;
const SEED_END = 730;
const GAUSSIAN_MU = 720;
const GAUSSIAN_SIGMA = 3.5; // ±3σ covers 710-730

// Alpha: seedAmount / sqrt(seededBuckets)
const NUM_SEEDED = SEED_END - SEED_START + 1; // 41
const ALPHA = BigInt(Math.floor(200_000000 / Math.sqrt(NUM_SEEDED))); // ~31 USDC

// Resolution: tonight 23:59 UTC
const RESOLUTION_TIME = Math.floor(
  new Date("2026-04-10T23:59:00Z").getTime() / 1000
);

const DEPLOYER = "0xe828a83E29c46FFb798926b86566e7f14454C2cF" as const;

// ─── Gaussian distribution ───────────────────────────────────────────────────

function gaussian(x: number, mu: number, sigma: number): number {
  return Math.exp(-0.5 * ((x - mu) / sigma) ** 2);
}

function buildGaussianSeeds(): { ids: bigint[]; shares: bigint[] } {
  const ids: bigint[] = [];
  const rawWeights: number[] = [];
  let totalWeight = 0;

  for (let i = SEED_START; i <= SEED_END; i++) {
    ids.push(BigInt(i));
    const w = gaussian(i, GAUSSIAN_MU, GAUSSIAN_SIGMA);
    rawWeights.push(w);
    totalWeight += w;
  }

  // Scale to SEED_AMOUNT, ensure minimum 1 per bucket
  const shares: bigint[] = [];
  let assigned = 0n;
  for (let i = 0; i < rawWeights.length - 1; i++) {
    const s = BigInt(Math.max(1, Math.floor((rawWeights[i] / totalWeight) * Number(SEED_AMOUNT))));
    shares.push(s);
    assigned += s;
  }
  // Last bucket gets remainder
  shares.push(SEED_AMOUNT - assigned);

  return { ids, shares };
}

// ─── Main ────────────────────────────────────────────────────────────────────

async function main() {
  const account = privateKeyToAccount(PRIVATE_KEY);

  const walletClient = createWalletClient({
    account,
    chain: arbitrumSepolia,
    transport: http(RPC),
  });

  const publicClient = createPublicClient({
    chain: arbitrumSepolia,
    transport: http(RPC),
  });

  // Load ABI
  const factoryArtifact = JSON.parse(
    readFileSync("ts-integration/abis/MarketFactory.json", "utf-8")
  );
  const factoryAbi = factoryArtifact.abi;

  // Build gaussian seeds
  const { ids, shares } = buildGaussianSeeds();

  console.log("\n══════════════════════════════════════════════");
  console.log("  Creating BTC Market on Arbitrum Sepolia");
  console.log("══════════════════════════════════════════════\n");

  console.log("Market:           BTC Price Tonight 23:59 UTC");
  console.log("Range:            $65,000 - $80,000");
  console.log("Bucket width:     $100");
  console.log("Max bucket ID:    799 (150 total capacity)");
  console.log(`Seeded buckets:   ${NUM_SEEDED} (IDs ${SEED_START}-${SEED_END})`);
  console.log(`Seeded range:     $${SEED_START * 100} - $${(SEED_END + 1) * 100}`);
  console.log(`Seed amount:      ${formatUnits(SEED_AMOUNT, 6)} USDC`);
  console.log(`Alpha:            ${formatUnits(ALPHA, 6)} USDC`);
  console.log(`Resolution:       ${new Date(RESOLUTION_TIME * 1000).toISOString()}`);
  console.log(`Resolver:         ${DEPLOYER}`);

  // Print distribution preview
  console.log("\n  Distribution preview (shares per bucket):");
  const peak = shares.reduce((a, b) => (a > b ? a : b), 0n);
  for (let i = 0; i < ids.length; i += 4) {
    const id = Number(ids[i]);
    const s = shares[i];
    const bar = "█".repeat(Math.max(1, Math.floor((Number(s) / Number(peak)) * 30)));
    console.log(`  ${id} ($${id * 100}): ${bar} ${formatUnits(s, 6)}`);
  }

  // Build MarketParams
  const params = {
    alpha: ALPHA,
    seedAmount: SEED_AMOUNT,
    bucketWidth: BUCKET_WIDTH,
    maxBucketId: MAX_BUCKET_ID,
    seededBucketIds: ids,
    seededShares: shares,
    alphaFinal: 0n, // no decay
    decayStart: 0n,
    decayDuration: 0n,
    name: "BTC Price Tonight 23:59 UTC",
    description: "Where will BTC/USD close on April 10, 2026? Pick your range.",
    resolutionCriteria: "CoinGecko BTC/USD spot price at 2026-04-10 23:59:00 UTC",
    valueUnit: "USD",
    resolver: DEPLOYER,
    biddingDeadline: BigInt(RESOLUTION_TIME),
    scheduledResolutionTime: BigInt(RESOLUTION_TIME),
    minBetSize: 0n,
    maxBucketsPerRange: 10n,
  };

  console.log("\n  Sending createMarket tx...");

  const hash = await walletClient.writeContract({
    address: FACTORY,
    abi: factoryAbi,
    functionName: "createMarket",
    args: [params],
    gas: 100_000_000n, // large init: clone + tree + bucket SSTOREs
  });

  console.log(`  Tx hash: ${hash}`);
  console.log("  Waiting for confirmation...");

  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  console.log(`  Status: ${receipt.status}`);
  console.log(`  Gas used: ${receipt.gasUsed}`);

  // Parse MarketCreated event
  const marketCreatedTopic = "0x"; // we'll find it from logs
  for (const log of receipt.logs) {
    if (log.address.toLowerCase() === FACTORY.toLowerCase() && log.topics.length >= 4) {
      const marketId = BigInt(log.topics[1]!);
      const marketAddress = `0x${log.topics[2]!.slice(26)}`;
      console.log(`\n  ✓ Market created!`);
      console.log(`  Market ID:      ${marketId}`);
      console.log(`  Market address:  ${marketAddress}`);

      // Read market state
      const marketArtifact = JSON.parse(
        readFileSync("ts-integration/abis/LMSRMarket.json", "utf-8")
      );
      const marketAbi = marketArtifact.abi;

      const poolBalance = await publicClient.readContract({
        address: marketAddress as `0x${string}`,
        abi: marketAbi,
        functionName: "poolBalance",
      });

      const activeBuckets = await publicClient.readContract({
        address: marketAddress as `0x${string}`,
        abi: marketAbi,
        functionName: "activeBucketCount",
      });

      console.log(`  Pool balance:    ${formatUnits(poolBalance as bigint, 6)} USDC`);
      console.log(`  Active buckets:  ${activeBuckets}`);
      console.log(`\n  Add to .env:`);
      console.log(`  MARKET_ADDRESS=${marketAddress}`);
      break;
    }
  }

  console.log("\n══════════════════════════════════════════════");
  console.log("  Done. Market is live for trading.");
  console.log("══════════════════════════════════════════════\n");
}

main().catch(console.error);
