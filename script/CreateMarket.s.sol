// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {MarketFactory} from "../src/MarketFactory.sol";
import {LMSRMarket} from "../src/LMSRMarket.sol";
import {Vault} from "../src/Vault.sol";

/// @notice Creates a new prediction market through the deployed MarketFactory.
///
/// CONFIGURE
/// ─────────
///   Edit the constants in the "Market Configuration" section below.
///   Then run:
///
///   forge script script/CreateMarket.s.sol:CreateMarketScript \
///     --rpc-url $FUJI_RPC_URL --broadcast --chain-id 43113
///
/// PREREQUISITES
/// ─────────────
///   .env must have: FACTORY_ADDRESS, PRIVATE_KEY, DEPLOYER_ADDRESS
///   Deployer must have creatorAllowance > 0 on the factory
///   Vault must have deployableCapital >= SEED_AMOUNT
///
/// AFTER DEPLOY
/// ────────────
///   Copy the printed MARKET_ADDRESS into .env as MARKET_ADDRESS.
///   Then use Trade / Resolve / Claim scripts against that address.
contract CreateMarketScript is Script {

    // ─── Market Configuration ─────────────────────────────────────────────────
    // Edit these values before each deployment.

    // Question metadata
    string constant NAME               = "AVAX/USD Jun 1 2026";
    string constant DESCRIPTION        = "What will the AVAX/USD price be on June 1, 2026 00:00 UTC?";
    string constant RESOLUTION_CRITERIA =
        "Resolved using Chainlink AVAX/USD feed at 00:00 UTC June 1 2026. "
        "Bucket is selected as floor((value - marketMin) / bucketWidth). Closest bucket wins.";
    string constant VALUE_UNIT         = "USD";

    // Price range and bucket structure
    // Bucket width = (MARKET_MAX - MARKET_MIN) / BUCKET_COUNT
    // e.g. (200 - 10) / 19 = 10 USD per bucket → buckets: [$10,$20), [$20,$30) … [$190,$200)
    uint256 constant MARKET_MIN        = 10;            // lower bound (inclusive)
    uint256 constant MARKET_MAX        = 200;           // upper bound (inclusive)
    uint256 constant BUCKET_COUNT      = 19;            // number of buckets

    // Liquidity
    uint256 constant SEED_AMOUNT       = 10_000_000000; // $10k pulled from vault (6 dec USDC)

    // Alpha: controls price sensitivity.
    // Rule of thumb: SEED_AMOUNT / bucketCount gives moderate impact.
    // Higher alpha → flatter odds (more resistant to manipulation).
    // Lower alpha  → sharper moves per trade (better for liquid markets).
    uint256 constant ALPHA_INITIAL     = SEED_AMOUNT / 3; // ~$3.3k

    // Alpha decay: linearly drops from ALPHA_INITIAL to (ALPHA_INITIAL * DECAY_FINAL_BPS/10000)
    // over DECAY_DURATION seconds. Protects against late-entry sniping near resolution.
    uint256 constant DECAY_FINAL_BPS   = 3000;           // floor = 30% of alpha_initial
    uint256 constant DECAY_DURATION    = 30 days;        // duration to reach floor

    // Fees (set to 0 to use factory defaults)
    uint256 constant FEE_BPS           = 200;   // 2% total fee per trade
    uint256 constant PROTOCOL_FEE_BPS  = 2000;  // 20% of fees → protocol treasury

    // Optional constraints (0 = disabled)
    uint256 constant BIDDING_DEADLINE  = 0;       // 0 = no betting deadline
    uint256 constant SCHEDULED_RESOLVE = 0;       // 0 = unspecified resolution time
    uint256 constant MIN_BET_SIZE      = 1_000000; // $1 minimum bet; 0 = no minimum

    // ─────────────────────────────────────────────────────────────────────────

    function run() public {
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        uint256 pk       = vm.envUint("PRIVATE_KEY");

        MarketFactory factory = MarketFactory(vm.envAddress("FACTORY_ADDRESS"));
        Vault vault = factory.vault();

        console.log("=================================================");
        console.log("  Create Market");
        console.log("=================================================");
        console.log("Factory:         ", address(factory));
        console.log("Creator:         ", deployer);
        console.log("Creator slots:   ", factory.creatorAllowance(deployer));
        console.log("Vault deployable:", vault.deployableCapital() / 1e6, "USDC");
        console.log("Seed requested:  ", SEED_AMOUNT / 1e6, "USDC");

        require(factory.creatorAllowance(deployer) > 0, "Deployer has no creator allowance");
        require(vault.deployableCapital() >= SEED_AMOUNT, "Vault: insufficient deployable capital");

        MarketFactory.MarketParams memory p;
        p.alpha                   = ALPHA_INITIAL;
        p.seedAmount              = SEED_AMOUNT;
        p.minValue                = MARKET_MIN;
        p.maxValue                = MARKET_MAX;
        p.bucketCount             = BUCKET_COUNT;
        p.feeBps                  = FEE_BPS;
        p.protocolFeeBps          = PROTOCOL_FEE_BPS;
        p.alphaFinal              = (ALPHA_INITIAL * DECAY_FINAL_BPS) / 10000;
        p.decayDuration           = DECAY_DURATION;
        p.name                    = NAME;
        p.description             = DESCRIPTION;
        p.resolutionCriteria      = RESOLUTION_CRITERIA;
        p.valueUnit               = VALUE_UNIT;
        p.resolver                = deployer;   // deployer resolves; 0 also defaults to creator
        p.biddingDeadline         = BIDDING_DEADLINE;
        p.scheduledResolutionTime = SCHEDULED_RESOLVE;
        p.minBetSize              = MIN_BET_SIZE;

        vm.startBroadcast(pk);
        address marketAddr = factory.createMarket(p);
        vm.stopBroadcast();

        LMSRMarket market = LMSRMarket(marketAddr);

        console.log("\n  Market created!");
        console.log("  Address:        ", marketAddr);
        console.log("  Market ID:      ", market.marketId());
        console.log("  Pool balance:   ", market.poolBalance() / 1e6, "USDC");
        console.log("  Alpha (initial):", market.alpha());
        console.log("  Alpha (final):  ", market.alphaFinal());
        console.log("  Bucket count:   ", market.bucketCount());
        console.log("  Bucket width:   ", market.bucketWidth());
        console.log("  Value unit:     ", market.valueUnit());
        console.log("  Resolver:       ", market.resolver());
        console.log("  Vault remaining:", vault.deployableCapital() / 1e6, "USDC");

        console.log("\n  Copy to .env:");
        console.log(string.concat("  MARKET_ADDRESS=", vm.toString(marketAddr)));
    }
}
