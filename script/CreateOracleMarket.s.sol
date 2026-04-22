// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {MarketFactory} from "../src/MarketFactory.sol";
import {LMSRMarket} from "../src/LMSRMarket.sol";
import {Vault} from "../src/Vault.sol";
import {ChainlinkPriceOracleResolver} from "../src/ChainlinkPriceOracleResolver.sol";

/// @notice Create a BTC price market wired to ChainlinkPriceOracleResolver.
///
/// Differs from CreateMarket.s.sol in three ways:
///   1. resolver            = CHAINLINK_ORACLE_RESOLVER_ADDRESS (not deployer)
///   2. scheduledResolution = now + RESOLVE_OFFSET_MIN minutes    (required; oracle enforces it)
///   3. bucket structure    = $1K-wide buckets over $0-$200,999   (comfortably covers BTC)
///
/// PREREQUISITES
///   .env: FACTORY_ADDRESS, CHAINLINK_ORACLE_RESOLVER_ADDRESS, PRIVATE_KEY, DEPLOYER_ADDRESS
///   Deployer must have factory.creatorAllowance(deployer) > 0
///   Vault must have deployableCapital >= SEED_AMOUNT
///
/// RUN
///   forge script script/CreateOracleMarket.s.sol:CreateOracleMarketScript \
///     --rpc-url $ARB_SEPOLIA_RPC_URL --broadcast --chain-id 421614
contract CreateOracleMarketScript is Script {

    // ─── Market Configuration ─────────────────────────────────────────────────

    string  constant NAME               = "BTC/USD Oracle Testnet4";
    string  constant DESCRIPTION        = "End-to-end test of ChainlinkPriceOracleResolver on Arbitrum Sepolia.";
    string  constant RESOLUTION_CRITERIA =
        "Chainlink BTC/USD feed (0x56a43EB56Da12C0dc1D972ACb089c06a5dEF8e69) at scheduledResolutionTime. "
        "winningBucket = floor(answer / 1e8 / bucketWidth).";
    string  constant VALUE_UNIT         = "USD";

    uint256 constant BUCKET_WIDTH       = 1_000;    // $1K per bucket
    uint256 constant MAX_BUCKET_ID      = 150;      // buckets 0-150 → $0-$150,999

    // Seed a gaussian across buckets 65-85 ($65K-$85K) centered at $75K.
    // Outside this range, buckets stay dormant until someone trades them.
    uint256 constant SEED_LOW_BUCKET    = 65;
    uint256 constant SEED_HIGH_BUCKET   = 85;
    uint256 constant SEED_CENTER_BUCKET = 75;

    uint256 constant SEED_AMOUNT        = 200_000000;   // $200 pulled from vault (min $100 factory floor)
    uint256 constant ALPHA              = 50_000000;    // $50 alpha (~SEED/4)
    uint256 constant MIN_BET_SIZE       = 1_000000;     // $1

    /// @notice Minutes from now until the market becomes resolvable.
    /// Keep small so you can exercise the full flow in one session.
    uint256 constant RESOLVE_OFFSET_MIN = 1;

    // ─── Oracle Registration ─────────────────────────────────────────────────

    address constant PRICE_FEED    = 0x56a43EB56Da12C0dc1D972ACb089c06a5dEF8e69; // BTC/USD, Arb Sepolia
    uint256 constant PRICE_DIVISOR = 1e8;   // Chainlink USD feeds: 8 decimals
    uint256 constant STALENESS_SEC = 3600;  // 1h — also the resolver default

    // ─────────────────────────────────────────────────────────────────────────

    function run() public {
        address deployer       = vm.envAddress("DEPLOYER_ADDRESS");
        address factoryAddr    = vm.envAddress("FACTORY_ADDRESS");
        address oracleResolver = vm.envAddress("CHAINLINK_ORACLE_RESOLVER_ADDRESS");
        uint256 pk             = vm.envUint("PRIVATE_KEY");

        MarketFactory factory = MarketFactory(factoryAddr);
        Vault vault = factory.vault();

        console.log("=================================================");
        console.log("  Create BTC Oracle Market");
        console.log("=================================================");
        console.log("Factory:         ", factoryAddr);
        console.log("Oracle resolver: ", oracleResolver);
        console.log("Creator:         ", deployer);
        console.log("Creator slots:   ", factory.creatorAllowance(deployer));
        console.log("Vault deployable:", vault.deployableCapital() / 1e6, "USDC");
        console.log("Seed requested:  ", SEED_AMOUNT / 1e6, "USDC");

        require(oracleResolver != address(0), "CHAINLINK_ORACLE_RESOLVER_ADDRESS not set");
        require(factory.creatorAllowance(deployer) > 0, "Deployer has no creator allowance");
        require(vault.deployableCapital() >= SEED_AMOUNT, "Vault: insufficient deployable capital");
        require(
            ChainlinkPriceOracleResolver(oracleResolver).owner() == deployer,
            "Deployer must own the oracle resolver to auto-register the market"
        );

        uint256 schedTime = block.timestamp + (RESOLVE_OFFSET_MIN * 60);

        // Gaussian seed distribution across [SEED_LOW_BUCKET, SEED_HIGH_BUCKET].
        uint256 numSeeded = SEED_HIGH_BUCKET - SEED_LOW_BUCKET + 1;
        uint256[] memory seedIds    = new uint256[](numSeeded);
        uint256[] memory seedShares = new uint256[](numSeeded);
        {
            uint256[] memory rawWeights = new uint256[](numSeeded);
            uint256 totalWeight = 0;
            for (uint256 i = 0; i < numSeeded; i++) {
                uint256 bucketId = SEED_LOW_BUCKET + i;
                uint256 dist = bucketId > SEED_CENTER_BUCKET
                    ? bucketId - SEED_CENTER_BUCKET
                    : SEED_CENTER_BUCKET - bucketId;
                uint256 w = dist * dist * 10;
                rawWeights[i] = w < 1000 ? 1000 - w : 1;
                totalWeight += rawWeights[i];
                seedIds[i] = bucketId;
            }
            uint256 assigned = 0;
            for (uint256 i = 0; i < numSeeded - 1; i++) {
                seedShares[i] = (rawWeights[i] * SEED_AMOUNT) / totalWeight;
                if (seedShares[i] == 0) seedShares[i] = 1;
                assigned += seedShares[i];
            }
            seedShares[numSeeded - 1] = SEED_AMOUNT - assigned;
        }

        MarketFactory.MarketParams memory p;
        p.alpha                   = ALPHA;
        p.seedAmount              = SEED_AMOUNT;
        p.bucketWidth             = BUCKET_WIDTH;
        p.maxBucketId             = MAX_BUCKET_ID;
        p.seededBucketIds         = seedIds;
        p.seededShares            = seedShares;
        p.name                    = NAME;
        p.description             = DESCRIPTION;
        p.resolutionCriteria      = RESOLUTION_CRITERIA;
        p.valueUnit               = VALUE_UNIT;
        p.resolver                = oracleResolver;
        p.biddingDeadline         = 0;
        p.scheduledResolutionTime = schedTime;
        p.minBetSize              = MIN_BET_SIZE;

        vm.startBroadcast(pk);
        address marketAddr = factory.createMarket(p);
        ChainlinkPriceOracleResolver(oracleResolver).registerMarket(
            marketAddr,
            PRICE_FEED,
            PRICE_DIVISOR,
            STALENESS_SEC
        );
        vm.stopBroadcast();

        LMSRMarket market = LMSRMarket(marketAddr);

        console.log("\n  Market created & registered!");
        console.log("  Address:                 ", marketAddr);
        console.log("  Market ID:               ", market.marketId());
        console.log("  Pool balance:            ", market.poolBalance() / 1e6, "USDC");
        console.log("  Resolver:                ", market.resolver());
        console.log("  scheduledResolutionTime: ", market.scheduledResolutionTime());
        console.log("  Resolvable in ~min:      ", RESOLVE_OFFSET_MIN);
        console.log("  bucketWidth:             ", market.bucketWidth());
        console.log("  maxBucketId:             ", market.maxBucketId());
        console.log("  Oracle priceFeed:        ", PRICE_FEED);
        console.log("  Oracle priceDivisor:     ", PRICE_DIVISOR);
        console.log("  Oracle stalenessSec:     ", STALENESS_SEC);

        require(market.resolver() == oracleResolver, "Resolver mismatch: resolve() will revert");

        console.log("\n  Copy to both core-contracts/.env and skepsis-be/.env:");
        console.log(string.concat("  MARKET_ADDRESS=", vm.toString(marketAddr)));

        console.log("\n  Next (DB sync only): POST /admin/oracle/register so the backend writes");
        console.log("  oraclePriceFeed / oraclePriceDivisor / oracleStalenessSec / oracleRegisteredAt.");
        console.log("  The market is ALREADY registered on-chain; this step just syncs the DB.");
        console.log(
            string.concat(
                "  curl -X POST $BACKEND_URL/admin/oracle/register ",
                "-H 'Authorization: Bearer $PRIVY_TOKEN' -H 'Content-Type: application/json' ",
                "-d '{\"marketAddress\":\"",
                vm.toString(marketAddr),
                "\",\"priceFeed\":\"0x56a43EB56Da12C0dc1D972ACb089c06a5dEF8e69\",",
                "\"priceDivisor\":\"100000000\",\"stalenessSec\":3600}'"
            )
        );
    }
}
