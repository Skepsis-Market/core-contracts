// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {LMSRMarket} from "../src/LMSRMarket.sol";
import {PositionNFT} from "../src/PositionNFT.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";

/// @notice Test expansion at scale — 300 active buckets, 100-bucket range buys
contract ExpansionScaleTest is Test {
    MockUSDC usdc;
    PositionNFT posNFT;
    LMSRMarket market;

    address factory;
    address creator = address(0x1);
    address trader = address(0x2);

    uint256 constant POOL = 100_000_000000; // $100K
    uint256 constant ALPHA = 14_285_000000; // ~POOL/sqrt(50)

    function setUp() public {
        usdc = new MockUSDC();
        factory = address(this);
        posNFT = new PositionNFT(factory);

        // Create market with 20 initial buckets: $80K-$100K in $1K steps
        uint256[] memory ranges = new uint256[](21);
        for (uint256 i = 0; i <= 20; i++) {
            ranges[i] = 80000 + (i * 1000);
        }

        market = new LMSRMarket(
            1, creator, factory, address(usdc), address(posNFT),
            ALPHA, POOL, ranges, new uint256[](0), 50, 0,
            LMSRMarket.MarketMetadata("BTC", "", "", "USD", creator, 0, 0, 0),
            address(0)
        );

        posNFT.authorizeMarket(address(market), 1);
        usdc.mint(address(market), POOL);

        // Expand: +-100 buckets = $80K-$100K initial, expand to $-20K to $200K
        // That's 100 below + 20 original + 100 above = 220 total
        market.configureExpansion(0, 220000); // $0 to $220K

        usdc.mint(trader, 10_000_000_000000); // $10M
        vm.startPrank(trader);
        usdc.approve(address(market), type(uint256).max);
        posNFT.setApprovalForAll(address(market), true);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                    SINGLE BUCKET ACTIVATION
    // ═══════════════════════════════════════════════════════════════════════

    function test_activateSingleBucket_gas() public {
        // Buy into bucket 0 (far left expansion — $0-$1K)
        uint256 g0 = gasleft();
        vm.prank(trader);
        market.buySharesRange(0, 1000, 100_000000, 0, 0, trader); // $100
        uint256 g1 = gasleft();

        console.log("=== SINGLE BUCKET ACTIVATION ===");
        console.log("Gas (activate + buy):  ", g0 - g1);
        console.log("Active bucket count:   ", market.activeBucketCount());
        console.log("Total bucket count:    ", market.bucketCount());
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                    ACTIVATE 300 BUCKETS ONE BY ONE
    // ═══════════════════════════════════════════════════════════════════════

    function test_activate300Buckets_gas() public {
        uint256 totalBuckets = market.bucketCount();
        uint256 bw = market.bucketWidth();
        uint256 mMin = market.marketMin();

        console.log("=== ACTIVATING ALL BUCKETS ===");
        console.log("Total buckets:         ", totalBuckets);
        console.log("Bucket width:          ", bw);

        uint256 totalGas = 0;
        uint256 activated = 0;

        // Activate all buckets one by one
        for (uint256 i = 0; i < totalBuckets && i < 220; i++) {
            uint256 lower = mMin + (i * bw);
            uint256 upper = lower + bw;

            // Skip already-active original buckets
            (uint256 shares,,,) = market.buckets(i);
            if (shares > 0) continue;

            uint256 g0 = gasleft();
            vm.prank(trader);
            market.buySharesRange(lower, upper, 10_000000, 0, 0, trader); // $10 each
            uint256 g1 = gasleft();

            totalGas += (g0 - g1);
            activated++;

            if (activated % 50 == 0) {
                console.log("  Activated:", activated, "| Last gas:", g0 - g1);
            }
        }

        console.log("Total activated:       ", activated);
        console.log("Active bucket count:   ", market.activeBucketCount());
        console.log("Total gas:             ", totalGas);
        console.log("Avg gas per activation:", totalGas / activated);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                    BUY ACROSS 10 BUCKETS (RANGE)
    // ═══════════════════════════════════════════════════════════════════════

    function test_rangeBuy10Buckets_afterExpansion() public {
        // First activate some buckets
        _activateAll();

        // Range buy across 10 active buckets: $85K-$95K
        uint256 g0 = gasleft();
        vm.prank(trader);
        market.buySharesRange(85000, 95000, 1000_000000, 0, 0, trader); // $1K
        uint256 g1 = gasleft();

        console.log("=== RANGE BUY 10 BUCKETS (all active) ===");
        console.log("Gas:                   ", g0 - g1);
        console.log("Active buckets:        ", market.activeBucketCount());
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                    BUY ACROSS 50 BUCKETS
    // ═══════════════════════════════════════════════════════════════════════

    function test_rangeBuy50Buckets_afterExpansion() public {
        _activateAll();

        // Range buy across 50 buckets: $75K-$125K
        uint256 g0 = gasleft();
        vm.prank(trader);
        market.buySharesRange(75000, 125000, 5000_000000, 0, 0, trader); // $5K
        uint256 g1 = gasleft();

        console.log("=== RANGE BUY 50 BUCKETS ===");
        console.log("Gas:                   ", g0 - g1);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                    BUY ACROSS 100 BUCKETS
    // ═══════════════════════════════════════════════════════════════════════

    function test_rangeBuy100Buckets_afterExpansion() public {
        _activateAll();

        // Range buy across 100 buckets: $50K-$150K
        uint256 g0 = gasleft();
        vm.prank(trader);
        market.buySharesRange(50000, 150000, 10000_000000, 0, 0, trader); // $10K
        uint256 g1 = gasleft();

        console.log("=== RANGE BUY 100 BUCKETS ===");
        console.log("Gas:                   ", g0 - g1);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                    BUY 100 INACTIVE BUCKETS (WORST CASE)
    // ═══════════════════════════════════════════════════════════════════════

    function test_rangeBuy100Inactive_worstCase() public {
        // DON'T activate first — buy across 100 inactive buckets
        // This is the dust attack scenario
        uint256 g0 = gasleft();
        vm.prank(trader);
        market.buySharesRange(0, 100000, 10000_000000, 0, 0, trader); // $10K across 100 inactive
        uint256 g1 = gasleft();

        console.log("=== WORST CASE: 100 INACTIVE BUCKETS ===");
        console.log("Gas:                   ", g0 - g1);
        console.log("Active after:          ", market.activeBucketCount());
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                    SINGLE BUY WITH 300 ACTIVE BUCKETS
    // ═══════════════════════════════════════════════════════════════════════

    function test_singleBuy_with300ActiveBuckets() public {
        _activateAll();

        uint256 activeBefore = market.activeBucketCount();
        console.log("Active buckets:        ", activeBefore);

        // Single bucket buy in a market with 220 active buckets
        uint256 g0 = gasleft();
        vm.prank(trader);
        market.buySharesRange(90000, 91000, 500_000000, 0, 0, trader); // $500 on one bucket
        uint256 g1 = gasleft();

        console.log("=== SINGLE BUY (many active buckets) ===");
        console.log("Gas:                   ", g0 - g1);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                    HELPER
    // ═══════════════════════════════════════════════════════════════════════

    function _activateAll() internal {
        uint256 totalBuckets = market.bucketCount();
        uint256 bw = market.bucketWidth();
        uint256 mMin = market.marketMin();

        for (uint256 i = 0; i < totalBuckets; i++) {
            (uint256 shares,,,) = market.buckets(i);
            if (shares > 0) continue;

            uint256 lower = mMin + (i * bw);
            vm.prank(trader);
            market.buySharesRange(lower, lower + bw, 10_000000, 0, 0, trader);
        }
    }
}
