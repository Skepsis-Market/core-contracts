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

    function _buyBucket(LMSRMarket m, uint256 bucketId, uint256 amount, uint256 minShares) internal returns (uint256) {
        uint256 lower = m.marketMin() + (bucketId * m.bucketWidth());
        return m.buySharesRange(lower, lower + m.bucketWidth(), amount, minShares, 0, address(0));
    }

    function _sellBucket(LMSRMarket m, uint256 bucketId, uint256 shares, uint256 minPayout) internal returns (uint256) {
        uint256 lower = m.marketMin() + (bucketId * m.bucketWidth());
        return m.sellSharesRange(lower, lower + m.bucketWidth(), shares, minPayout, address(0));
    }

    function _claimBucket(LMSRMarket m, uint256 bucketId) internal returns (uint256) {
        uint256 tokenId = (uint256(uint128(m.marketId())) << 128) | (uint256(uint64(bucketId)) << 64) | uint256(uint64(bucketId));
        return m.claim(tokenId, address(0));
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
        (uint256 origShares0, uint256 origLower0, uint256 origUpper0) = market.buckets(0);
        assertEq(origLower0, 100_000);
        assertEq(origUpper0, 101_000);

        // Expand: 5 buckets below
        market.configureExpansion(95_000, 115_000);

        // Original bucket 0 is now at index 5
        (uint256 remappedShares, uint256 remappedLower, uint256 remappedUpper) = market.buckets(5);
        assertEq(remappedLower, 100_000);
        assertEq(remappedUpper, 101_000);
        assertEq(remappedShares, origShares0);

        // New bucket 0 is inactive (below original range)
        (uint256 inactiveShares, uint256 inactiveLower, uint256 inactiveUpper) = market.buckets(0);
        assertEq(inactiveLower, 0);
        assertEq(inactiveUpper, 0);
        assertEq(inactiveShares, 0);
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
        vm.startPrank(trader);
        _buyBucket(market, 0, 100_000000, 0);
        vm.stopPrank();
        // Now expansion should fail
        vm.expectRevert(LMSRMarket.InvalidParameters.selector);
        market.configureExpansion(95_000, 115_000);
    }

    function test_configureExpansion_treeConsistency() public {
        market = _createMarket();
        // Verify prices are approximately the same before/after expansion
        (uint256 sharesBefore,,) = market.getQuoteForRange(100_000, 101_000, 100_000000);
        market.configureExpansion(95_000, 115_000);
        (uint256 sharesAfter,,) = market.getQuoteForRange(100_000, 101_000, 100_000000);

        // Quotes should be approximately the same — only active leaves have weight
        assertApproxEqRel(sharesAfter, sharesBefore, 1e14);
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
        (,, uint256 bUpper0) = market.buckets(0);
        assertEq(bUpper0, 0); // inactive

        // Bucket 5: active (first original bucket, remapped)
        (, uint256 bLower5, uint256 bUpper5) = market.buckets(5);
        assertTrue(bUpper5 > bLower5); // active

        // Buckets 15-19: inactive (above original range)
        (,, uint256 bUpper15) = market.buckets(15);
        assertEq(bUpper15, 0); // inactive
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
        vm.startPrank(trader);
        _buyBucket(market, 0, 100_000000, 0);
        vm.stopPrank();

        // Bucket 0 should now be active
        (uint256 bShares0, uint256 bLower0, uint256 bUpper0) = market.buckets(0);
        assertTrue(bUpper0 > bLower0);
        assertEq(bLower0, 95_000);
        assertEq(bUpper0, 96_000);
        assertTrue(bShares0 > 0);
        assertEq(market.activeBucketCount(), activeBefore + 1);
    }

    function test_buyRangeSpanningActiveAndInactive() public {
        market = _createMarket();
        market.configureExpansion(95_000, 115_000);

        // Range buy: [98K, 102K] — buckets 3,4 inactive; 5,6 active
        vm.prank(trader);
        market.buySharesRange(98_000, 102_000, 200_000000, 0, 0, address(0));

        // All 4 buckets should be active
        for (uint256 i = 3; i <= 6; i++) {
            (, uint256 bLower, uint256 bUpper) = market.buckets(i);
            assertTrue(bUpper > bLower);
        }
        assertEq(market.activeBucketCount(), 12); // 10 + 2 newly activated
    }

    function test_activationUpdatesTree() public {
        market = _createMarket();
        market.configureExpansion(95_000, 115_000);

        // Get bucket 0 shares before activation
        (uint256 sharesBucket0Before,,) = market.buckets(0);
        assertEq(sharesBucket0Before, 0); // inactive

        // Activate bucket 0
        vm.startPrank(trader);
        _buyBucket(market, 0, 100_000000, 0);
        vm.stopPrank();

        // After activation, bucket 0 should have shares
        (uint256 sharesBucket0After,,) = market.buckets(0);
        assertTrue(sharesBucket0After > 0, "Activated bucket should have shares");
    }

    function test_sellFromInactiveBucketReverts() public {
        market = _createMarket();
        market.configureExpansion(95_000, 115_000);

        // Try to sell from inactive bucket — should fail (0 shares)
        uint256 lower = market.marketMin();
        uint256 width = market.bucketWidth();
        vm.prank(trader);
        vm.expectRevert(LMSRMarket.InsufficientBalance.selector);
        market.sellSharesRange(lower, lower + width, 1, 0, address(0));
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
        vm.startPrank(trader);
        _buyBucket(market, 0, 100_000000, 0);
        vm.stopPrank();

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
        vm.startPrank(trader);
        _buyBucket(market, 7, 100_000000, 0);

        // 2. Buy in expanded range below (bucket 2 = value range [97K, 98K])
        _buyBucket(market, 2, 100_000000, 0);

        // 3. Buy range spanning both (value range [99K, 103K] = buckets 4-7)
        market.buySharesRange(99_000, 103_000, 100_000000, 0, 0, address(0));

        // 4. Sell some shares from an activated bucket
        (uint256 b2Shares,,) = market.buckets(2);
        _sellBucket(market, 2, b2Shares / 4, 0);
        vm.stopPrank();

        // 5. Resolve in the expanded range
        vm.prank(creator);
        market.resolveMarket(97_500); // Bucket 2 wins

        // 6. Verify resolution succeeded (claim requires PositionNFT, tested elsewhere)
        assertEq(market.winningBucket(), 2);
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
        vm.startPrank(trader);
        _buyBucket(market, 0, 100_000000, 0);
        vm.stopPrank();

        // Trader 2 buys into already-active bucket 0
        vm.startPrank(trader2);
        _buyBucket(market, 0, 200_000000, 0);
        vm.stopPrank();

        // Both traders contributed — bucket should have shares from both
        (uint256 bShares0,,) = market.buckets(0);
        assertTrue(bShares0 > 0);
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
        vm.startPrank(trader);
        _buyBucket(market, 5, 100_000000, 0);

        // Normal range buy should work
        market.buySharesRange(103_000, 106_000, 200_000000, 0, 0, address(0));
        vm.stopPrank();

        // Out of range should still fail
        vm.prank(trader);
        vm.expectRevert(LMSRMarket.InvalidRange.selector);
        market.buySharesRange(90_000, 95_000, 100_000000, 0, 0, address(0));
    }

    // ═══════════════════════════════════════════════════════════════════
    //                GAS BENCHMARKS
    // ═══════════════════════════════════════════════════════════════════

    function test_gas_activateBucket() public {
        market = _createMarket();
        market.configureExpansion(95_000, 115_000);

        vm.startPrank(trader);
        uint256 g0 = gasleft();
        _buyBucket(market, 0, 100_000000, 0);
        uint256 g1 = gasleft();
        vm.stopPrank();
        console.log("buyShares with activation (single bucket):", g0 - g1);
    }

    function test_gas_buyIntoAlreadyActive() public {
        market = _createMarket();
        market.configureExpansion(95_000, 115_000);

        // Buy into active bucket (no activation overhead)
        vm.startPrank(trader);
        uint256 g0 = gasleft();
        _buyBucket(market, 5, 100_000000, 0);
        uint256 g1 = gasleft();
        vm.stopPrank();
        console.log("buyShares without activation (active bucket):", g0 - g1);
    }

    function test_gas_buyRangeWithActivation() public {
        market = _createMarket();
        market.configureExpansion(95_000, 115_000);

        // Range buy activating 3 buckets: [97K, 100K] = buckets 2,3,4
        vm.prank(trader);
        uint256 g0 = gasleft();
        market.buySharesRange(97_000, 100_000, 300_000000, 0, 0, address(0));
        uint256 g1 = gasleft();
        console.log("buySharesRange with 3 activations:", g0 - g1);
    }
}
