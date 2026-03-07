// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {LMSRMarket} from "../src/LMSRMarket.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";

/// @notice Tests for dynamic range expansion
contract ExpansionTest is Test {
    LMSRMarket public market;
    MockUSDC public usdc;

    address creator = address(0x1);
    address trader = address(0x2);
    address factory = address(this); // test contract acts as factory

    uint256 constant POOL = 10_000_000000; // $10,000
    uint256 constant ALPHA = 1_000_000000; // $1,000

    function _defaultMetadata() internal pure returns (LMSRMarket.MarketMetadata memory) {
        return LMSRMarket.MarketMetadata({
            name: "Expansion Test",
            description: "",
            resolutionCriteria: "",
            valueUnit: "USD",
            resolver: address(0),
            biddingDeadline: 0,
            scheduledResolutionTime: 0,
            minBetSize: 0
        });
    }

    /// @dev Create a 10-bucket market: [100K, 110K] with $1K width
    function _createMarket() internal returns (LMSRMarket) {
        uint256[] memory ranges = new uint256[](11);
        for (uint256 i = 0; i <= 10; i++) {
            ranges[i] = 100_000 + i * 1_000;
        }

        vm.prank(creator);
        LMSRMarket m = new LMSRMarket(
            1, creator, factory, address(usdc), address(0),
            ALPHA, POOL, ranges, 50, 2000, _defaultMetadata(), address(0xFEE)
        );

        // Fund market with initial pool (simulates vault.fundNewMarket)
        usdc.mint(address(m), POOL);

        // Fund trader
        usdc.mint(trader, 1_000_000_000000);
        vm.prank(trader);
        usdc.approve(address(m), type(uint256).max);

        return m;
    }

    function setUp() public {
        usdc = new MockUSDC();
        usdc.mint(creator, 1_000_000_000000);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                  configureExpansion
    // ═══════════════════════════════════════════════════════════════════

    function test_configureExpansion_basic() public {
        market = _createMarket();
        // Original: [100K, 110K], 10 buckets, width = 1K
        assertEq(market.bucketCount(), 10);
        assertEq(market.marketMin(), 100_000);
        assertEq(market.marketMax(), 110_000);

        // Expand to [95K, 115K] — 5 below, 5 above = 20 total
        market.configureExpansion(95_000, 115_000);

        assertEq(market.bucketCount(), 20);
        assertEq(market.maxBucketCount(), 20);
        assertEq(market.activeBucketCount(), 10);
        assertEq(market.initialBucketOffset(), 5);
        assertEq(market.marketMin(), 95_000);
        assertEq(market.marketMax(), 115_000);
    }

    function test_configureExpansion_bucketRemapping() public {
        market = _createMarket();
        // Original bucket 0: [100K, 101K]
        LMSRMarket.Bucket memory origBucket0 = market.getBucket(0);
        assertEq(origBucket0.lowerBound, 100_000);
        assertEq(origBucket0.upperBound, 101_000);

        // Expand: 5 buckets below
        market.configureExpansion(95_000, 115_000);

        // Original bucket 0 is now at index 5
        LMSRMarket.Bucket memory remapped = market.getBucket(5);
        assertEq(remapped.lowerBound, 100_000);
        assertEq(remapped.upperBound, 101_000);
        assertEq(remapped.shares, origBucket0.shares);

        // New bucket 0 is inactive (below original range)
        LMSRMarket.Bucket memory inactive = market.getBucket(0);
        assertEq(inactive.lowerBound, 0);
        assertEq(inactive.upperBound, 0);
        assertEq(inactive.shares, 0);
    }

    function test_configureExpansion_onlyFactory() public {
        market = _createMarket();
        vm.prank(trader);
        vm.expectRevert(LMSRMarket.Unauthorized.selector);
        market.configureExpansion(95_000, 115_000);
    }

    function test_configureExpansion_onlyOnce() public {
        market = _createMarket();
        market.configureExpansion(95_000, 115_000);
        vm.expectRevert(LMSRMarket.ExpansionAlreadyConfigured.selector);
        market.configureExpansion(90_000, 120_000);
    }

    function test_configureExpansion_revertAfterTrades() public {
        market = _createMarket();
        // Make a trade first
        vm.prank(trader);
        market.buyShares(0, 100_000000, 0);
        // Now expansion should fail
        vm.expectRevert(LMSRMarket.InvalidParameters.selector);
        market.configureExpansion(95_000, 115_000);
    }

    function test_configureExpansion_treeConsistency() public {
        market = _createMarket();
        uint256 sumBefore = market.getCachedSumExp();
        market.configureExpansion(95_000, 115_000);
        uint256 sumAfter = market.getCachedSumExp();

        // Tree sum should be approximately the same — only active leaves have weight
        assertApproxEqRel(sumAfter, sumBefore, 1e14);
    }

    function test_configureExpansion_expandOnlyBelow() public {
        market = _createMarket();
        // Only expand below: [95K, 110K]
        market.configureExpansion(95_000, 110_000);
        assertEq(market.bucketCount(), 15); // 10 + 5 below
        assertEq(market.initialBucketOffset(), 5);
    }

    function test_configureExpansion_expandOnlyAbove() public {
        market = _createMarket();
        // Only expand above: [100K, 120K]
        market.configureExpansion(100_000, 120_000);
        assertEq(market.bucketCount(), 20); // 10 + 10 above
        assertEq(market.initialBucketOffset(), 0);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                  _isBucketActive
    // ═══════════════════════════════════════════════════════════════════

    function test_isBucketActive_activeVsInactive() public {
        market = _createMarket();
        market.configureExpansion(95_000, 115_000);

        // Buckets 0-4: inactive (below original range)
        LMSRMarket.Bucket memory b0 = market.getBucket(0);
        assertEq(b0.upperBound, 0); // inactive

        // Bucket 5: active (first original bucket, remapped)
        LMSRMarket.Bucket memory b5 = market.getBucket(5);
        assertTrue(b5.upperBound > b5.lowerBound); // active

        // Buckets 15-19: inactive (above original range)
        LMSRMarket.Bucket memory b15 = market.getBucket(15);
        assertEq(b15.upperBound, 0); // inactive
    }

    // ═══════════════════════════════════════════════════════════════════
    //                BUCKET ACTIVATION
    // ═══════════════════════════════════════════════════════════════════

    function test_buyIntoInactiveBucket_activates() public {
        market = _createMarket();
        market.configureExpansion(95_000, 115_000);

        uint256 activeBefore = market.activeBucketCount();
        assertEq(activeBefore, 10);

        // Buy into bucket 0 (inactive — expanded region below)
        vm.prank(trader);
        market.buyShares(0, 100_000000, 0);

        // Bucket 0 should now be active
        LMSRMarket.Bucket memory b0 = market.getBucket(0);
        assertTrue(b0.upperBound > b0.lowerBound);
        assertEq(b0.lowerBound, 95_000);
        assertEq(b0.upperBound, 96_000);
        assertTrue(b0.shares > 0);
        assertEq(market.activeBucketCount(), activeBefore + 1);
    }

    function test_buyRangeSpanningActiveAndInactive() public {
        market = _createMarket();
        market.configureExpansion(95_000, 115_000);

        // Range buy: [98K, 102K] — buckets 3,4 inactive; 5,6 active
        vm.prank(trader);
        market.buySharesRange(98_000, 102_000, 200_000000, 0, 0);

        // All 4 buckets should be active
        for (uint256 i = 3; i <= 6; i++) {
            LMSRMarket.Bucket memory b = market.getBucket(i);
            assertTrue(b.upperBound > b.lowerBound);
        }
        assertEq(market.activeBucketCount(), 12); // 10 + 2 newly activated
    }

    function test_activationUpdatesTree() public {
        market = _createMarket();
        market.configureExpansion(95_000, 115_000);

        uint256 sumBefore = market.getCachedSumExp();

        // Activate bucket 0
        vm.prank(trader);
        market.buyShares(0, 100_000000, 0);

        uint256 sumAfter = market.getCachedSumExp();
        // Sum should increase — bucket went from 0 weight to phantom + buy weight
        assertTrue(sumAfter > sumBefore);
    }

    function test_sellFromInactiveBucketReverts() public {
        market = _createMarket();
        market.configureExpansion(95_000, 115_000);

        // Try to sell from inactive bucket — should fail (0 shares)
        vm.prank(trader);
        vm.expectRevert(LMSRMarket.InsufficientBalance.selector);
        market.sellShares(0, 1, 0);
    }

    function test_pricesUnchangedAfterExpansion() public {
        market = _createMarket();

        // Get price of bucket 0 before expansion
        // (bucket 0 will become bucket 5 after expansion)
        (uint256 sharesBefore,,) = market.getQuoteForRange(100_000, 101_000, 100_000000);

        // Expand
        market.configureExpansion(95_000, 115_000);

        // Same value range should give same quote
        (uint256 sharesAfter,,) = market.getQuoteForRange(100_000, 101_000, 100_000000);
        assertApproxEqRel(sharesAfter, sharesBefore, 1e14);
    }

    function test_safetyBufferGrowsOnActivation() public {
        market = _createMarket();
        market.configureExpansion(95_000, 115_000);

        uint256 bufferBefore = market.getSafetyBuffer();

        // Activate a bucket
        vm.prank(trader);
        market.buyShares(0, 100_000000, 0);

        uint256 bufferAfter = market.getSafetyBuffer();
        // Buffer should increase (11 active vs 10 active)
        assertTrue(bufferAfter > bufferBefore);
    }

    // ═══════════════════════════════════════════════════════════════════
    //               FULL LIFECYCLE
    // ═══════════════════════════════════════════════════════════════════

    function test_fullLifecycle_expandedMarket() public {
        market = _createMarket();
        market.configureExpansion(95_000, 115_000);

        // 1. Buy in original range (bucket 7 = value range [102K, 103K])
        vm.prank(trader);
        market.buyShares(7, 100_000000, 0);

        // 2. Buy in expanded range below (bucket 2 = value range [97K, 98K])
        vm.prank(trader);
        market.buyShares(2, 100_000000, 0);

        // 3. Buy range spanning both (value range [99K, 103K] = buckets 4-7)
        vm.prank(trader);
        market.buySharesRange(99_000, 103_000, 100_000000, 0, 0);

        // 4. Sell some shares from an activated bucket
        LMSRMarket.Bucket memory b2 = market.getBucket(2);
        vm.prank(trader);
        market.sellShares(2, b2.shares / 4, 0);

        // 5. Resolve in the expanded range
        vm.prank(creator);
        market.resolveMarket(97_500); // Bucket 2 wins

        // 6. Claim all winnings — solvency invariant guarantees this succeeds
        LMSRMarket.Bucket memory b2After = market.getBucket(2);
        if (b2After.shares > 0) {
            vm.prank(trader);
            market.claimWinnings(2, b2After.shares);
        }
    }

    function test_quoteForInactiveBuckets() public {
        market = _createMarket();
        market.configureExpansion(95_000, 115_000);

        // Get quote for entirely inactive range
        (uint256 shares, uint256 cost,) = market.getQuoteForRange(95_000, 97_000, 100_000000);
        // Should return meaningful quote (simulates activation)
        assertTrue(shares > 0);
        assertTrue(cost > 0);
    }

    function test_multiUserActivation() public {
        market = _createMarket();
        market.configureExpansion(95_000, 115_000);

        address trader2 = address(0x4);
        usdc.mint(trader2, 1_000_000_000000);
        vm.prank(trader2);
        usdc.approve(address(market), type(uint256).max);

        // Trader 1 activates bucket 0
        vm.prank(trader);
        market.buyShares(0, 100_000000, 0);

        // Trader 2 buys into already-active bucket 0
        vm.prank(trader2);
        market.buyShares(0, 200_000000, 0);

        // Both traders contributed — bucket should have shares from both
        LMSRMarket.Bucket memory b0 = market.getBucket(0);
        assertTrue(b0.shares > 0);
        assertEq(market.activeBucketCount(), 11);
    }

    // ═══════════════════════════════════════════════════════════════════
    //           NON-EXPANDED MARKET (no regression)
    // ═══════════════════════════════════════════════════════════════════

    function test_nonExpandedMarket_unchanged() public {
        market = _createMarket();
        // No configureExpansion call — maxBucketCount stays 0

        assertEq(market.maxBucketCount(), 0);
        assertEq(market.activeBucketCount(), 0); // Not set for non-expanded

        // Normal buy should work
        vm.prank(trader);
        market.buyShares(5, 100_000000, 0);

        // Normal range buy should work
        vm.prank(trader);
        market.buySharesRange(103_000, 106_000, 200_000000, 0, 0);

        // Out of range should still fail
        vm.prank(trader);
        vm.expectRevert(LMSRMarket.InvalidRange.selector);
        market.buySharesRange(90_000, 95_000, 100_000000, 0, 0);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                GAS BENCHMARKS
    // ═══════════════════════════════════════════════════════════════════

    function test_gas_activateBucket() public {
        market = _createMarket();
        market.configureExpansion(95_000, 115_000);

        vm.prank(trader);
        uint256 g0 = gasleft();
        market.buyShares(0, 100_000000, 0);
        uint256 g1 = gasleft();
        console.log("buyShares with activation (single bucket):", g0 - g1);
    }

    function test_gas_buyIntoAlreadyActive() public {
        market = _createMarket();
        market.configureExpansion(95_000, 115_000);

        // Buy into active bucket (no activation overhead)
        vm.prank(trader);
        uint256 g0 = gasleft();
        market.buyShares(5, 100_000000, 0);
        uint256 g1 = gasleft();
        console.log("buyShares without activation (active bucket):", g0 - g1);
    }

    function test_gas_buyRangeWithActivation() public {
        market = _createMarket();
        market.configureExpansion(95_000, 115_000);

        // Range buy activating 3 buckets: [97K, 100K] = buckets 2,3,4
        vm.prank(trader);
        uint256 g0 = gasleft();
        market.buySharesRange(97_000, 100_000, 300_000000, 0, 0);
        uint256 g1 = gasleft();
        console.log("buySharesRange with 3 activations:", g0 - g1);
    }
}
