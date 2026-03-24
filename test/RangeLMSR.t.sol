// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {LMSRMarket} from "../src/LMSRMarket.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";

/// @notice Tests for Correlated Range LMSR functionality
contract RangeLMSRTest is Test {
    LMSRMarket public market;
    MockUSDC public usdc;
    
    address public creator = address(0x1);
    address public trader = address(0x2);
    address public factory = address(0x3);
    
    uint256 constant POOL = 10_000_000000; // $10,000 (6 decimals)
    uint256 constant BUCKET_COUNT = 100;

    function _defaultMetadata() internal pure returns (LMSRMarket.MarketMetadata memory) {
        return LMSRMarket.MarketMetadata({
            name: "",
            description: "",
            resolutionCriteria: "",
            valueUnit: "",
            resolver: address(0),
            biddingDeadline: 0,
            scheduledResolutionTime: 0,
            minBetSize: 0
        });
    }
    
    function setUp() public {
        usdc = new MockUSDC();
        
        // Create bucket ranges: $110,000 to $120,000 in $100 increments
        uint256[] memory ranges = new uint256[](BUCKET_COUNT + 1);
        for (uint256 i = 0; i <= BUCKET_COUNT; i++) {
            ranges[i] = 110000 + (i * 100); // $110,000, $110,100, ... $120,000
        }
        
        // Fund creator and create market
        usdc.mint(creator, POOL);
        vm.startPrank(creator);
        usdc.approve(address(this), POOL);
        
        market = new LMSRMarket(
            1,              // marketId
            creator,        // creator
            factory,        // factory
            address(usdc),  // usdcToken
            address(0),     // positionNFT (not used yet)
            1_000_000000,   // alpha = POOL / sqrt(100)
            POOL,           // poolBalance
            ranges,         // bucket ranges
            50,             // feeBps (0.5%)
            2000,           // protocolFeeBps (20% of fees)
            _defaultMetadata(),
            address(0xFEE)
        );
        
        usdc.transfer(address(market), POOL);
        vm.stopPrank();
        
        // Fund trader
        usdc.mint(trader, 1_000_000000); // $1,000
    }

    function _buyBucket(uint256 bucketId, uint256 amount, uint256 minShares) internal returns (uint256) {
        uint256 lower = market.marketMin() + (bucketId * market.bucketWidth());
        return market.buySharesRange(lower, lower + market.bucketWidth(), amount, minShares, 0, address(0));
    }

    function _buyBucket(LMSRMarket m, uint256 bucketId, uint256 amount, uint256 minShares) internal returns (uint256) {
        uint256 lower = m.marketMin() + (bucketId * m.bucketWidth());
        return m.buySharesRange(lower, lower + m.bucketWidth(), amount, minShares, 0, address(0));
    }
    
    function test_marketBoundsSetCorrectly() public view {
        assertEq(market.marketMin(), 110000, "Market min should be 110000");
        assertEq(market.marketMax(), 120000, "Market max should be 120000");
        assertEq(market.bucketWidth(), 100, "Bucket width should be 100");
        assertEq(market.bucketCount(), 100, "Bucket count should be 100");
    }
    
    function test_getQuoteForRange() public view {
        // Get quote for 3-bucket range: $114,500 to $114,800
        (uint256 shares, uint256 cost, uint256 odds) = market.getQuoteForRange(
            114500, 114800, 10_000000 // $10
        );
        
        console.log("=== Quote for $10 on 3 buckets ===");
        console.log("Shares:", shares);
        console.log("Cost:", cost);
        console.log("Odds:", odds);
        
        // Should get meaningful shares
        assertTrue(shares > 0, "Should receive shares");
        assertTrue(cost > 0 && cost <= 10_000000, "Cost should be <= input");
        assertTrue(odds > 0, "Odds should be positive");
    }
    
    function test_buySharesRange_basic() public {
        uint256 traderBalBefore = usdc.balanceOf(trader);
        
        vm.startPrank(trader);
        usdc.approve(address(market), 10_000000);
        
        // Buy $10 across 3 buckets
        uint256 shares = market.buySharesRange(
            114500,    // rangeLower
            114800,    // rangeUpper
            10_000000, // $10
            0,         // minSharesOut (no slippage protection for test)
            0,         // targetShares (0 = binary search)
            address(0) // recipient (0 = msg.sender)
        );
        vm.stopPrank();
        
        uint256 traderBalAfter = usdc.balanceOf(trader);
        
        console.log("=== Buy Range Result ===");
        console.log("Shares received:", shares);
        console.log("USDC spent:", traderBalBefore - traderBalAfter);
        console.log("Potential payout if win: $", shares / 1e6);
        console.log("Odds:", (shares * 1e6) / 10_000000, "x");
        
        assertTrue(shares > 0, "Should receive shares");
        assertEq(traderBalBefore - traderBalAfter, 10_000000, "Should spend $10");
    }
    
    function test_buySharesRange_affectsAllBucketsInRange() public {
        // Get bucket shares before
        (uint256 sharesBucket45Before,,) = market.buckets(45);
        (uint256 sharesBucket46Before,,) = market.buckets(46);
        (uint256 sharesBucket47Before,,) = market.buckets(47);
        (uint256 sharesBucket44Before,,) = market.buckets(44); // Outside range
        
        vm.startPrank(trader);
        usdc.approve(address(market), 10_000000);
        uint256 shares = market.buySharesRange(114500, 114800, 10_000000, 0, 0, address(0));
        vm.stopPrank();
        
        // Get bucket shares after
        (uint256 sharesBucket45After,,) = market.buckets(45);
        (uint256 sharesBucket46After,,) = market.buckets(46);
        (uint256 sharesBucket47After,,) = market.buckets(47);
        (uint256 sharesBucket44After,,) = market.buckets(44);
        
        console.log("=== Bucket Share Changes ===");
        console.log("Bucket 44 (outside): before=", sharesBucket44Before, "after=", sharesBucket44After);
        console.log("Bucket 45 (in range): before=", sharesBucket45Before, "after=", sharesBucket45After);
        console.log("Bucket 46 (in range): before=", sharesBucket46Before, "after=", sharesBucket46After);
        console.log("Bucket 47 (in range): before=", sharesBucket47Before, "after=", sharesBucket47After);
        
        // All buckets in range should increase by same amount
        uint256 delta45 = sharesBucket45After - sharesBucket45Before;
        uint256 delta46 = sharesBucket46After - sharesBucket46Before;
        uint256 delta47 = sharesBucket47After - sharesBucket47Before;
        
        assertEq(delta45, delta46, "Bucket 45 and 46 should have same delta");
        assertEq(delta46, delta47, "Bucket 46 and 47 should have same delta");
        assertEq(delta45, shares, "Delta should equal shares returned");
        
        // Bucket outside range should NOT change
        assertEq(sharesBucket44After, sharesBucket44Before, "Bucket 44 should not change");
    }
    
    function test_buySharesRange_vs_singleBucketBuy() public {
        // Compare: buying 3 buckets atomically vs 3 single-bucket buys
        
        // Setup two identical markets
        uint256[] memory ranges = new uint256[](BUCKET_COUNT + 1);
        for (uint256 i = 0; i <= BUCKET_COUNT; i++) {
            ranges[i] = 110000 + (i * 100);
        }
        
        usdc.mint(creator, POOL * 2);
        vm.startPrank(creator);
        
        LMSRMarket marketRange = new LMSRMarket(
            2, creator, factory, address(usdc), address(0),
            1_000_000000, POOL, ranges, 50, 2000, _defaultMetadata(), address(0xFEE)
        );
        usdc.transfer(address(marketRange), POOL);
        
        LMSRMarket marketSingle = new LMSRMarket(
            3, creator, factory, address(usdc), address(0),
            1_000_000000, POOL, ranges, 50, 2000, _defaultMetadata(), address(0xFEE)
        );
        usdc.transfer(address(marketSingle), POOL);
        vm.stopPrank();
        
        // Fund trader more
        usdc.mint(trader, 20_000000);
        
        // RANGE BUY: $10 across 3 buckets atomically
        vm.startPrank(trader);
        usdc.approve(address(marketRange), 10_000000);
        uint256 sharesRange = marketRange.buySharesRange(114500, 114800, 10_000000, 0, 0, address(0));
        
        // SINGLE BUYS: $3.33 per bucket (same total $10)
        usdc.approve(address(marketSingle), 10_000000);
        uint256 amountPerBucket = uint256(10_000000) / 3;
        uint256 sharesSingle1 = _buyBucket(marketSingle, 45, amountPerBucket, 0);
        uint256 sharesSingle2 = _buyBucket(marketSingle, 46, amountPerBucket, 0);
        uint256 sharesSingle3 = _buyBucket(marketSingle, 47, amountPerBucket, 0);
        vm.stopPrank();
        
        console.log("=== Range Buy vs Single Buys ===");
        console.log("RANGE BUY: shares covering all 3 buckets =", sharesRange);
        console.log("  If bucket 46 wins, payout = $", sharesRange / 1e6);
        console.log("");
        console.log("SINGLE BUYS:");
        console.log("  Bucket 45 shares =", sharesSingle1);
        console.log("  Bucket 46 shares =", sharesSingle2);
        console.log("  Bucket 47 shares =", sharesSingle3);
        console.log("  If bucket 46 wins, payout = $", sharesSingle2 / 1e6);
        console.log("");
        
        // KEY INSIGHT: Range buy gives SAME shares across all buckets
        // Single buys give DIFFERENT shares per bucket (sequential price impact)
        // Range buy should give LOWER shares per bucket but they ALL pay out if ANY wins
        
        // The range buyer's odds are better because ANY of 3 buckets winning pays full amount
        // Single buyer only wins on the specific bucket they bought
        console.log("ECONOMIC COMPARISON:");
        console.log("  Range buyer: $10 cost, $", sharesRange / 1e6, "payout if ANY of 3 wins");
        console.log("  Single buyer: $10 cost, only wins on specific bucket");
    }
    
    function test_resolveRange_winningBucketInRange() public {
        // Buy range
        vm.startPrank(trader);
        usdc.approve(address(market), 10_000000);
        uint256 shares = market.buySharesRange(114500, 114800, 10_000000, 0, 0, address(0));
        vm.stopPrank();

        // Resolve with value 114600 (bucket 46, within range 45-47)
        vm.prank(creator);
        market.resolveMarket(114600);

        // Verify resolution
        assertEq(market.winningBucket(), 46);
        assertTrue(shares > 0, "Should have received shares");
        // NOTE: claim() requires PositionNFT; tested in LMSRMarketPositionAccounting.t.sol
    }

    function test_resolveRange_winningBucketOutsideRange() public {
        // Buy range
        vm.startPrank(trader);
        usdc.approve(address(market), 10_000000);
        market.buySharesRange(114500, 114800, 10_000000, 0, 0, address(0));
        vm.stopPrank();

        // Resolve with value 115000 (bucket 50, OUTSIDE range 45-47)
        vm.prank(creator);
        market.resolveMarket(115000);

        // Verify winning bucket is outside the range
        assertEq(market.winningBucket(), 50);
        assertTrue(market.winningBucket() < 45 || market.winningBucket() > 47, "Winning bucket outside range");
    }
    
    function test_sellSharesRange() public {
        // Buy range first
        vm.startPrank(trader);
        usdc.approve(address(market), 10_000000);
        uint256 shares = market.buySharesRange(114500, 114800, 10_000000, 0, 0, address(0));
        
        // Get balance before sell
        uint256 balBefore = usdc.balanceOf(trader);
        
        // Sell immediately
        uint256 payout = market.sellSharesRange(114500, 114800, shares, 0, address(0));
        vm.stopPrank();
        
        uint256 balAfter = usdc.balanceOf(trader);
        
        console.log("=== Sell Range ===");
        console.log("Bought shares:", shares);
        console.log("Sell payout:", payout);
        console.log("Cost: $10, Return: $", payout / 1e6);
        console.log("Spread loss: $", (10_000000 - payout) / 1e6);
        
        assertTrue(payout > 0, "Should receive payout");
        assertTrue(payout < 10_000000, "Should have some spread loss");
        assertEq(balAfter - balBefore, payout, "Balance should increase by payout");
    }
    
    function test_sellSharesRange_affectsAllBucketsInRange() public {
        // Buy range first
        vm.startPrank(trader);
        usdc.approve(address(market), 10_000000);
        uint256 shares = market.buySharesRange(114500, 114800, 10_000000, 0, 0, address(0));
        
        // Get bucket shares before sell
        (uint256 sharesBucket45Before,,) = market.buckets(45);
        (uint256 sharesBucket46Before,,) = market.buckets(46);
        (uint256 sharesBucket47Before,,) = market.buckets(47);
        
        // Sell
        market.sellSharesRange(114500, 114800, shares, 0, address(0));
        vm.stopPrank();
        
        // Get bucket shares after sell
        (uint256 sharesBucket45After,,) = market.buckets(45);
        (uint256 sharesBucket46After,,) = market.buckets(46);
        (uint256 sharesBucket47After,,) = market.buckets(47);
        
        // All buckets should decrease by same amount
        uint256 delta45 = sharesBucket45Before - sharesBucket45After;
        uint256 delta46 = sharesBucket46Before - sharesBucket46After;
        uint256 delta47 = sharesBucket47Before - sharesBucket47After;
        
        assertEq(delta45, delta46, "All buckets should decrease equally");
        assertEq(delta46, delta47, "All buckets should decrease equally");
        assertEq(delta45, shares, "Decrease should equal shares sold");
    }
    
    function test_oddsComparison_narrowVsWide() public {
        console.log("=== Odds: Narrow vs Wide Range ===");
        
        // Narrow bet: 1 bucket
        (uint256 sharesNarrow, , uint256 oddsNarrow) = market.getQuoteForRange(
            114500, 114600, 10_000000
        );
        
        // Medium bet: 3 buckets
        (uint256 sharesMedium, , uint256 oddsMedium) = market.getQuoteForRange(
            114500, 114800, 10_000000
        );
        
        // Wide bet: 10 buckets
        (uint256 sharesWide, , uint256 oddsWide) = market.getQuoteForRange(
            114500, 115500, 10_000000
        );
        
        console.log("1 bucket shares");
        console.log(sharesNarrow);
        console.log("1 bucket odds x1e4");
        console.log(oddsNarrow / 1e4);
        console.log("3 buckets shares");
        console.log(sharesMedium);
        console.log("3 buckets odds x1e4");
        console.log(oddsMedium / 1e4);
        console.log("10 buckets shares");
        console.log(sharesWide);
        console.log("10 buckets odds x1e4");
        console.log(oddsWide / 1e4);
        
        // Narrow = high odds, low probability
        // Wide = low odds, high probability
        assertTrue(oddsNarrow > oddsMedium, "Narrow should have higher odds than medium");
        assertTrue(oddsMedium > oddsWide, "Medium should have higher odds than wide");
    }
}
