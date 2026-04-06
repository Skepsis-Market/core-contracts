// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {LMSRMarket} from "../src/LMSRMarket.sol";
import {PositionNFT} from "../src/PositionNFT.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {FixedPointMath} from "../src/FixedPointMath.sol";

/// @notice Compare LP economics: 20 buckets vs 100 buckets, same pool, same trades
contract LPEconomicsTest is Test {
    using FixedPointMath for uint256;

    MockUSDC usdc;
    PositionNFT posNFT;
    address factory;
    address creator = address(0x1);
    address trader1 = address(0x10);
    address trader2 = address(0x20);
    address trader3 = address(0x30);

    uint256 constant POOL = 100_000_000000; // $100K same for both

    function setUp() public {
        usdc = new MockUSDC();
        factory = address(this);
        posNFT = new PositionNFT(factory);

        for (uint256 i = 0; i < 5; i++) {
            address t = address(uint160(0x10 + i * 0x10));
            usdc.mint(t, 1_000_000_000000);
        }
    }

    function _uniformSeeds(uint256 numBuckets, uint256 pool)
        internal pure returns (uint256[] memory ids, uint256[] memory shares)
    {
        ids = new uint256[](numBuckets);
        shares = new uint256[](numBuckets);
        uint256 per = pool / numBuckets;
        for (uint256 i = 0; i < numBuckets; i++) {
            ids[i] = i;
            shares[i] = per;
        }
        shares[numBuckets - 1] += pool - (per * numBuckets);
    }

    function _createMarket(uint256 id, uint256 buckets, uint256 minVal, uint256 maxVal)
        internal returns (LMSRMarket)
    {
        uint256 width = (maxVal - minVal) / buckets;

        // Seed bucket IDs: minVal/width .. (maxVal/width - 1)
        uint256 startBucket = minVal / width;
        uint256 maxBid = (maxVal / width) - 1;
        uint256[] memory seedIds = new uint256[](buckets);
        uint256[] memory seedShares = new uint256[](buckets);
        uint256 per = POOL / buckets;
        for (uint256 i = 0; i < buckets; i++) {
            seedIds[i] = startBucket + i;
            seedShares[i] = per;
        }
        seedShares[buckets - 1] += POOL - (per * buckets);

        uint256 sqrtN = _sqrt(buckets);
        uint256 alpha = POOL / sqrtN;

        LMSRMarket m = new LMSRMarket(LMSRMarket.InitParams({
                marketId: id,
                creator: creator,
                factory: factory,
                usdcToken: address(usdc),
                positionNFT: address(posNFT),
                alpha: alpha,
                poolBalance: POOL,
                bucketWidth: width,
                maxBucketId: maxBid,
                seededBucketIds: seedIds,
                seededShares: seedShares,
                feeBps: 100,
                protocolFeeBps: 0,
                metadata: LMSRMarket.MarketMetadata("", "", "", "", creator, 0, 0, 0),
                protocolFeeCollector: address(0)
            }));

        posNFT.authorizeMarket(address(m), id);
        usdc.mint(address(m), POOL);
        return m;
    }

    function _sqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 1;
        uint256 z = (x + 1) / 2;
        uint256 y = x;
        while (z < y) { y = z; z = (x / z + z) / 2; }
        return y;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //              SCENARIO 1: NO TRADING - LP RISK FROM SEEDING
    // ═══════════════════════════════════════════════════════════════════════

    function test_lpRisk_noTrading() public {
        LMSRMarket m20 = _createMarket(1, 20, 80000, 100000);
        LMSRMarket m100 = _createMarket(2, 100, 80000, 100000);

        console.log("=== NO TRADING - LP SEEDING RISK ===");
        console.log("");

        // 20 buckets
        uint256 sharesPerBucket20 = POOL / 20;
        console.log("20 BUCKETS:");
        console.log("  Alpha:               ", m20.alpha() / 1e6, "USDC");
        console.log("  Shares per bucket:   ", sharesPerBucket20 / 1e6, "USDC");
        console.log("  Max LP liability:    ", sharesPerBucket20 / 1e6, "USDC (one bucket wins)");
        console.log("  LP recovery (best):  ", (POOL - sharesPerBucket20) / 1e6, "USDC");
        console.log("  LP loss (no trades): ", sharesPerBucket20 / 1e6, "USDC");
        console.log("  LP loss % of pool:   ", (sharesPerBucket20 * 100) / POOL, "%");

        // With our fix: LP recovers initial shares, so no loss without trading
        vm.prank(creator);
        m20.resolveMarket(85000); // resolve to some bucket
        (int256 profit20,,) = m20.getLPProfitability();
        console.log("  LP profit (actual):  ", profit20);

        console.log("");

        // 100 buckets
        uint256 sharesPerBucket100 = POOL / 100;
        console.log("100 BUCKETS:");
        console.log("  Alpha:               ", m100.alpha() / 1e6, "USDC");
        console.log("  Shares per bucket:   ", sharesPerBucket100 / 1e6, "USDC");
        console.log("  Max LP liability:    ", sharesPerBucket100 / 1e6, "USDC (one bucket wins)");
        console.log("  LP recovery (best):  ", (POOL - sharesPerBucket100) / 1e6, "USDC");
        console.log("  LP loss (no trades): ", sharesPerBucket100 / 1e6, "USDC");
        console.log("  LP loss % of pool:   ", (sharesPerBucket100 * 100) / POOL, "%");

        vm.prank(creator);
        m100.resolveMarket(85000);
        (int256 profit100,,) = m100.getLPProfitability();
        console.log("  LP profit (actual):  ", profit100);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //              SCENARIO 2: MODERATE TRADING - SAME DOLLAR VOLUME
    // ═══════════════════════════════════════════════════════════════════════

    function test_lpEconomics_moderateTrading() public {
        LMSRMarket m20 = _createMarket(1, 20, 80000, 100000);
        LMSRMarket m100 = _createMarket(2, 100, 80000, 100000);

        // Same trades on both markets: $50K total volume across 5 traders
        // Each trader buys $10K in their predicted bucket
        // BTC at $90K → bucket varies by market width

        _executeTrades(m20, 20, 80000);
        _executeTrades(m100, 100, 80000);

        // Resolve at $90K
        uint256 resolutionValue = 90000;

        vm.prank(creator);
        m20.resolveMarket(resolutionValue);
        vm.prank(creator);
        m100.resolveMarket(resolutionValue);

        (int256 profit20, int256 roi20, uint256 fees20) = m20.getLPProfitability();
        (int256 profit100, int256 roi100, uint256 fees100) = m100.getLPProfitability();

        console.log("=== MODERATE TRADING ($50K volume) - RESOLVE AT $90K ===");
        console.log("");
        console.log("20 BUCKETS ($1K width):");
        console.log("  Pool balance:        ", m20.poolBalance() / 1e6, "USDC");
        console.log("  Total volume:        ", m20.totalVolume() / 1e6, "USDC");
        console.log("  LP fees earned:      ", fees20 / 1e6, "USDC");
        console.log("  LP profit:           ", profit20);
        console.log("  LP ROI bps:          ", roi20);
        _printWinningBucket(m20, "  ");

        console.log("");
        console.log("100 BUCKETS ($200 width):");
        console.log("  Pool balance:        ", m100.poolBalance() / 1e6, "USDC");
        console.log("  Total volume:        ", m100.totalVolume() / 1e6, "USDC");
        console.log("  LP fees earned:      ", fees100 / 1e6, "USDC");
        console.log("  LP profit:           ", profit100);
        console.log("  LP ROI bps:          ", roi100);
        _printWinningBucket(m100, "  ");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //              SCENARIO 3: HEAVY TRADING - WINNER CONCENTRATES
    // ═══════════════════════════════════════════════════════════════════════

    function test_lpEconomics_heavyTrading() public {
        LMSRMarket m20 = _createMarket(1, 20, 80000, 100000);
        LMSRMarket m100 = _createMarket(2, 100, 80000, 100000);

        // Heavy concentrated buying: $200K into winning bucket region
        _executeHeavyTrades(m20, 20, 80000);
        _executeHeavyTrades(m100, 100, 80000);

        uint256 resolutionValue = 90000;
        vm.prank(creator);
        m20.resolveMarket(resolutionValue);
        vm.prank(creator);
        m100.resolveMarket(resolutionValue);

        (int256 profit20, int256 roi20, uint256 fees20) = m20.getLPProfitability();
        (int256 profit100, int256 roi100, uint256 fees100) = m100.getLPProfitability();

        console.log("=== HEAVY TRADING ($200K+ volume) - RESOLVE AT $90K ===");
        console.log("");
        console.log("20 BUCKETS:");
        console.log("  Pool balance:        ", m20.poolBalance() / 1e6, "USDC");
        console.log("  Total volume:        ", m20.totalVolume() / 1e6, "USDC");
        console.log("  LP fees earned:      ", fees20 / 1e6, "USDC");
        console.log("  LP profit:           ", profit20);
        console.log("  LP ROI bps:          ", roi20);
        _printWinningBucket(m20, "  ");

        console.log("");
        console.log("100 BUCKETS:");
        console.log("  Pool balance:        ", m100.poolBalance() / 1e6, "USDC");
        console.log("  Total volume:        ", m100.totalVolume() / 1e6, "USDC");
        console.log("  LP fees earned:      ", fees100 / 1e6, "USDC");
        console.log("  LP profit:           ", profit100);
        console.log("  LP ROI bps:          ", roi100);
        _printWinningBucket(m100, "  ");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //              SCENARIO 4: TAIL EVENT - EXTREME OUTCOME
    // ═══════════════════════════════════════════════════════════════════════

    function test_lpEconomics_tailEvent() public {
        LMSRMarket m20 = _createMarket(1, 20, 80000, 100000);
        LMSRMarket m100 = _createMarket(2, 100, 80000, 100000);

        // Moderate trading spread across multiple buckets
        _executeTrades(m20, 20, 80000);
        _executeTrades(m100, 100, 80000);

        // Resolve at edge: $80.5K (bucket 0 in 20-bucket, bucket 2 in 100-bucket)
        uint256 resolutionValue = 80500;
        vm.prank(creator);
        m20.resolveMarket(resolutionValue);
        vm.prank(creator);
        m100.resolveMarket(resolutionValue);

        (int256 profit20,, uint256 fees20) = m20.getLPProfitability();
        (int256 profit100,, uint256 fees100) = m100.getLPProfitability();

        console.log("=== TAIL EVENT - RESOLVE AT $80.5K (edge) ===");
        console.log("");
        console.log("20 BUCKETS:");
        console.log("  LP fees:             ", fees20 / 1e6, "USDC");
        console.log("  LP profit:           ", profit20);
        _printWinningBucket(m20, "  ");

        console.log("");
        console.log("100 BUCKETS:");
        console.log("  LP fees:             ", fees100 / 1e6, "USDC");
        console.log("  LP profit:           ", profit100);
        _printWinningBucket(m100, "  ");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //              HELPERS
    // ═══════════════════════════════════════════════════════════════════════

    function _executeTrades(LMSRMarket m, uint256 buckets, uint256 minVal) internal {
        uint256 width = (100000 - minVal) / buckets;
        _buyAt(m, trader1, 88000, minVal, width, buckets, 10_000_000000);
        _buyAt(m, trader2, 89000, minVal, width, buckets, 10_000_000000);
        _buyAt(m, trader3, 90000, minVal, width, buckets, 10_000_000000);
        _buyAt(m, address(0x40), 91000, minVal, width, buckets, 10_000_000000);
        _buyAt(m, address(0x50), 92000, minVal, width, buckets, 10_000_000000);
    }

    function _executeHeavyTrades(LMSRMarket m, uint256 buckets, uint256 minVal) internal {
        uint256 width = (100000 - minVal) / buckets;
        _buyAt(m, trader1, 90000, minVal, width, buckets, 40_000_000000);
        _buyAt(m, trader2, 90000, minVal, width, buckets, 40_000_000000);
        _buyAt(m, trader3, 90000, minVal, width, buckets, 40_000_000000);
        _buyAt(m, address(0x40), 90000, minVal, width, buckets, 40_000_000000);
        _buyAt(m, address(0x50), 90000, minVal, width, buckets, 40_000_000000);
    }

    function _buyAt(LMSRMarket m, address t, uint256 target, uint256 minVal, uint256 width, uint256 buckets, uint256 amount) internal {
        uint256 bid = target / width;
        uint256 startBucket = minVal / width;
        if (bid < startBucket) bid = startBucket;
        if (bid >= startBucket + buckets) bid = startBucket + buckets - 1;
        uint256 lo = bid * width;
        vm.startPrank(t);
        usdc.approve(address(m), type(uint256).max);
        m.buySharesRange(lo, lo + width, amount, 0, 0, t);
        vm.stopPrank();
    }

    function _printWinningBucket(LMSRMarket m, string memory prefix) internal view {
        uint256 wb = m.winningBucket();
        (uint256 totalShares, uint256 initShares,,) = m.buckets(wb);
        uint256 traderShares = totalShares > initShares ? totalShares - initShares : 0;
        console.log(string.concat(prefix, "Winning bucket:        "), wb);
        console.log(string.concat(prefix, "Total winning shares:  "), totalShares / 1e6);
        console.log(string.concat(prefix, "  LP initial shares:   "), initShares / 1e6);
        console.log(string.concat(prefix, "  Trader shares:       "), traderShares / 1e6);
    }
}
