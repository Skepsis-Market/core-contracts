// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {LMSRMarket} from "../src/LMSRMarket.sol";

/// @notice Resolve a prediction market by providing the final outcome value.
///
/// CONFIGURE
/// ─────────
///   Set RESOLUTION_VALUE to the actual market outcome (in the market's VALUE_UNIT).
///   Example: for an AVAX/USD $10–$200 market, pass 150 if AVAX settled at $150.
///   The contract computes the winning bucket as:
///       bucket = (resolutionValue - marketMin) / bucketWidth
///
///   forge script script/Resolve.s.sol:ResolveScript \
///     --rpc-url $FUJI_RPC_URL --broadcast --chain-id 43113
///
/// PREREQUISITES
/// ─────────────
///   .env must have: MARKET_ADDRESS, PRIVATE_KEY, DEPLOYER_ADDRESS
///   Caller must be market.resolver() — defaults to the market creator (deployer)
///   Market must be ACTIVE
///
/// AFTER RESOLVING
/// ───────────────
///   1. Winners call:  forge script script/Claim.s.sol:ClaimScript    --broadcast
///   2. Vault harvest: forge script script/Claim.s.sol:HarvestLPScript --broadcast
contract ResolveScript is Script {

    function run() public {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address resolver = vm.envAddress("DEPLOYER_ADDRESS");

        // Read resolution value from env. 0 = dry run.
        uint256 RESOLUTION_VALUE = vm.envOr("RESOLUTION_VALUE", uint256(0));

        LMSRMarket market = LMSRMarket(vm.envAddress("MARKET_ADDRESS"));

        uint256 n         = market.bucketCount();
        uint256 minVal    = 0;
        uint256 maxVal    = (market.maxBucketId() + 1) * market.bucketWidth();
        uint256 bWidth    = market.bucketWidth();
        uint256 pool      = market.poolBalance();

        console.log("=================================================");
        console.log("  Resolve Market");
        console.log("=================================================");
        console.log("Market:          ", address(market));
        console.log("Market ID:       ", market.marketId());
        console.log("Name:            ", market.name());
        console.log("Status:          ", uint256(market.status()));
        console.log("Resolver:        ", market.resolver());
        console.log("Caller:          ", resolver);
        console.log("Pool balance:    ", pool / 1e6, "USDC");
        console.log("Range:           ", minVal, "-", maxVal);
        console.log("Bucket width:    ", bWidth, "  Count:", n);
        console.log("Value unit:      ", market.valueUnit());

        console.log("\n  Bucket distribution (all buckets):");
        console.log("  idx  lowerBound  upperBound    shares");
        for (uint256 i = 0; i < n; i++) {
            (uint256 bShares,, uint256 bLower, uint256 bUpper) = market.buckets(i);
            console.log("  bucket", i, bLower, bUpper);
            console.log("    shares:", bShares);
        }

        if (RESOLUTION_VALUE == 0) {
            console.log("\n  RESOLUTION_VALUE is 0 -- dry run only (no tx broadcast).");
            console.log("  Set RESOLUTION_VALUE to the real outcome and rerun with --broadcast.");
            return;
        }

        // ── Pre-flight checks ─────────────────────────────────────────────────
        require(
            market.status() == LMSRMarket.MarketStatus.ACTIVE,
            "Market is not ACTIVE"
        );
        require(
            RESOLUTION_VALUE >= minVal && RESOLUTION_VALUE <= maxVal,
            "RESOLUTION_VALUE out of market range"
        );
        require(
            msg.sender == market.resolver() || resolver == market.resolver(),
            "Caller is not the resolver"
        );

        // Compute the winning bucket (mirrors LMSRMarket.resolveMarket logic)
        uint256 winBucket = RESOLUTION_VALUE / bWidth;
        if (winBucket >= n) winBucket = n - 1;

        (uint256 wbShares,, uint256 wbLower, uint256 wbUpper) = market.buckets(winBucket);

        console.log("\n  Resolution value:", RESOLUTION_VALUE, market.valueUnit());
        console.log("  Winning bucket:  ", winBucket);
        console.log("  Winning range:   ", wbLower, "-", wbUpper);
        console.log("  Winning shares:  ", wbShares, "(payout USDC ~= shares / 1e6)");

        vm.startBroadcast(pk);
        market.resolveMarket(RESOLUTION_VALUE);
        vm.stopBroadcast();

        console.log("\n  Market resolved!");
        console.log("  Final winBucket:", market.winningBucket());
        console.log("  resolutionTime: ", market.resolutionTime());
        console.log("\n  Next steps:");
        console.log("  1. Winners claim:  forge script script/Claim.s.sol:ClaimScript --broadcast");
        console.log("  2. Harvest LP:     forge script script/Claim.s.sol:HarvestLPScript --broadcast");
    }
}
