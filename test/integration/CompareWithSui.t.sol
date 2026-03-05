// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {LMSRMarket} from "../../src/LMSRMarket.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";
import {FixedPointMath} from "../../src/FixedPointMath.sol";

/// @notice Test to validate economic equivalence with Sui implementation
/// @dev Replicates EXACT Sui test parameters: 100 buckets, $10K pool, $114.5K-$114.8K range
contract CompareWithSuiTest is Test {
    using FixedPointMath for uint256;
    
    MockUSDC usdc;
    LMSRMarket market;
    
    address factory = address(0x1);
    address creator = address(0x2);
    address positionNFT = address(0x3);
    address trader = address(0x4);
    
    uint256 constant POOL_BALANCE = 10000_000000; // $10,000 (matches Sui)
    uint256 constant TRADE_AMOUNT = 10_000000; // $10 (matches Sui)
    uint256 constant FEE_BPS = 50; // 0.5%

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
        
        // Create 100 buckets: $110K to $120K in $100 increments (EXACT Sui setup)
        uint256[] memory bucketRanges = new uint256[](101);
        for (uint256 i = 0; i <= 100; i++) {
            bucketRanges[i] = 110000 + (i * 100);
        }
        
        market = new LMSRMarket(
            1,
            creator,
            factory,
            address(usdc),
            positionNFT,
            1_000_000000,
            POOL_BALANCE,
            bucketRanges,
            FEE_BPS,
            2000,
            _defaultMetadata(),
            address(0xFEE)
        );
        
        usdc.mint(address(market), POOL_BALANCE);
        usdc.mint(trader, 100_000000);
    }
    
    function test_compare_economics() public {
        console.log("\n=== ECONOMICS COMPARISON: Solidity vs Sui (EXACT PARAMETERS) ===\n");
        
        // Sui test buys buckets $114,500-$114,800 (3 buckets: 45, 46, 47)
        uint256 startBucket = 45;
        uint256 endBucket = 47;
        
        console.log("Setup:");
        console.log("  Pool: $10,000");
        console.log("  Buckets: 100 ($110K-$120K, $100 width)");
        console.log("  Alpha (WAD):", market.alpha());
        console.log("  Trade: $10 in SINGLE bucket 45 ($114,500-$114,600)");
        console.log("  Fee: 0.5%");
        console.log("");
        
        // BUY single bucket 45 ($114,500-$114,600) - matching Sui's single bucket test
        vm.startPrank(trader);
        usdc.approve(address(market), TRADE_AMOUNT);
        
        uint256 bucketId = 45;
        uint256 totalShares = market.buyShares(bucketId, TRADE_AMOUNT, 0);
        
        vm.stopPrank();
        
        console.log("BUY RESULTS (SINGLE BUCKET):");
        console.log("  Shares (6 decimals):", totalShares);
        console.log("  Shares in USDC: $", totalShares / 1_000_000);
        console.log("");
        
        console.log("NOTE: Sui's 289M shares is for a 3-BUCKET RANGE bet, not single bucket!");
        console.log("  Sui adds 289M shares to EACH bucket in range (867M total)");
        console.log("  For single bucket: both should produce ~693M shares");
        console.log("");
        
        // For a single bucket buy, the expected is ~693M based on LMSR math
        uint256 solidityShares6 = totalShares;
        uint256 expectedSingleBucket = 693_000_000; // Approximate expected for single bucket
        uint256 diff = solidityShares6 > expectedSingleBucket ? solidityShares6 - expectedSingleBucket : expectedSingleBucket - solidityShares6;
        
        console.log("SINGLE BUCKET VALIDATION:");
        console.log("  Solidity shares:", solidityShares6);
        console.log("  Expected ~693M:", expectedSingleBucket);
        console.log("  Difference:", diff);
        console.log("  Within 1%:", diff < expectedSingleBucket / 100 ? "YES" : "NO");
    }
    
    function test_compare_fullLifecycle() public {
        console.log("\n=== FULL LIFECYCLE: BUY -> SELL -> RESOLVE -> CLAIM ===\n");
        
        uint256 startBucket = 45;
        uint256 endBucket = 47;
        
        // BUY across 3 buckets
        vm.startPrank(trader);
        usdc.approve(address(market), TRADE_AMOUNT * 2);
        
        uint256 totalShares = 0;
        uint256 amountPerBucket = TRADE_AMOUNT / 3;
        
        for (uint256 i = startBucket; i <= endBucket; i++) {
            uint256 shares = market.buyShares(i, amountPerBucket, 0);
            totalShares += shares;
        }
        // Shares are now in 6 decimals
        console.log("1. BUY: Total shares (6 dec):", totalShares);
        console.log("   Shares in USDC units:", totalShares / 1e6);
        
        // SELL IMMEDIATELY (test spread)
        uint256 balBefore = usdc.balanceOf(trader);
        
        for (uint256 i = startBucket; i <= endBucket; i++) {
            (uint256 bucketShares,,) = market.buckets(i);
            uint256 myShares = totalShares / 3;
            if (myShares > 0 && bucketShares >= myShares) {
                market.sellShares(i, myShares, 0);
            }
        }
        
        uint256 balAfter = usdc.balanceOf(trader);
        uint256 proceeds = balAfter - balBefore;
        
        console.log("2. SELL: Proceeds:", proceeds);
        console.log("   Loss:", TRADE_AMOUNT - proceeds);
        console.log("   Loss %:", ((TRADE_AMOUNT - proceeds) * 100) / TRADE_AMOUNT);
        
        // BUY BACK for resolution test
        totalShares = 0;
        for (uint256 i = startBucket; i <= endBucket; i++) {
            uint256 shares = market.buyShares(i, amountPerBucket, 0);
            totalShares += shares;
        }
        vm.stopPrank();
        
        // RESOLVE to middle bucket (46 = $114,600-$114,700)
        vm.prank(creator);
        market.resolveMarket(114600); // bucket 46
        
        console.log("3. RESOLVE: To bucket 46 ($114,600-$114,700)");
        
        // CLAIM (only bucket 46 wins)
        uint256 traderBalBefore = usdc.balanceOf(trader);
        vm.prank(trader);
        uint256 winningShares = totalShares / 3;
        market.claimWinnings(46, winningShares);
        uint256 traderBalAfter = usdc.balanceOf(trader);
        uint256 payout = traderBalAfter - traderBalBefore;
        
        console.log("4. CLAIM: Payout (6 dec):", payout);
        // Shares are now 6 decimals, payout = shares directly (both 6 decimals)
        console.log("   Winning shares (6 dec):", winningShares);
        console.log("");
        
        console.log("KEY VALIDATION:");
        console.log("  Sui: Winner receives shares * $1 (micro-units)");
        console.log("  Solidity: Winner receives shares USDC (both 6 decimals)");
        console.log("  Both: $1 per share payout");
        
        // Payout should match shares directly now (both 6 decimals)
        assertApproxEqAbs(payout, winningShares, 100, "Payout should match shares");
    }

    /// @notice Detailed comparison test with exact Sui parameters
    /// @dev Run this and compare output with: sui move test test_bitcoin_market_10_dollar_trade
    function test_detailed_sui_comparison() public {
        console.log("\n");
        console.log("================================================================================");
        console.log("       SOLIDITY vs SUI COMPARISON - EXACT SAME PARAMETERS");
        console.log("================================================================================");
        console.log("");
        
        // ========== MARKET SETUP ==========
        console.log("1. MARKET SETUP");
        console.log("   ---------------");
        console.log("   Pool Balance: $10,000");
        console.log("   Buckets: 100 ($110K - $120K, $100 width)");
        console.log("   Alpha (6 dec):", market.alpha());
        console.log("   Alpha in $:", market.alpha() / 1e6);
        console.log("   Bucket Count:", market.bucketCount());
        console.log("");
        
        // Get initial bucket state
        (uint256 initShares,,) = market.buckets(45);
        console.log("   Initial shares per bucket:", initShares);
        console.log("   Initial shares in $:", initShares / 1e6);
        console.log("");
        
        // ========== BUY $10 IN 3 BUCKETS (like Sui's range bet) ==========
        console.log("2. BUY: $10 across buckets 45-47 ($114.5K - $114.8K)");
        console.log("   ---------------");
        
        vm.startPrank(trader);
        usdc.approve(address(market), TRADE_AMOUNT * 10);
        
        uint256 amountPerBucket = TRADE_AMOUNT / 3; // ~$3.33 per bucket
        console.log("   Amount per bucket: $", amountPerBucket / 1e6);
        console.log("   Fee per bucket (0.5%): $", (amountPerBucket * 50) / 10000 / 1e6);
        console.log("");
        
        uint256 totalSharesBought = 0;
        uint256[] memory sharesByBucket = new uint256[](3);
        
        for (uint256 i = 0; i < 3; i++) {
            uint256 bucketId = 45 + i;
            uint256 sharesBefore = 0;
            {
                (uint256 s,,) = market.buckets(bucketId);
                sharesBefore = s;
            }
            
            uint256 sharesMinted = market.buyShares(bucketId, amountPerBucket, 0);
            sharesByBucket[i] = sharesMinted;
            totalSharesBought += sharesMinted;
            
            (uint256 sharesAfter,,) = market.buckets(bucketId);
            
            console.log("   Bucket", bucketId, ":");
            console.log("      Shares minted:", sharesMinted);
            console.log("      Bucket before:", sharesBefore);
            console.log("      Bucket after:", sharesAfter);
        }
        
        console.log("");
        console.log("   TOTAL shares bought:", totalSharesBought);
        console.log("   Total shares in $:", totalSharesBought / 1e6);
        console.log("");
        
        // ========== CHECK CURRENT STATE ==========
        console.log("3. CURRENT STATE (after buy)");
        console.log("   ---------------");
        console.log("   Pool balance:", market.poolBalance());
        console.log("   Pool in $:", market.poolBalance() / 1e6);
        console.log("   Total volume:", market.totalVolume());
        console.log("");
        
        // ========== SELL ALL SHARES ==========
        console.log("4. SELL: All shares immediately");
        console.log("   ---------------");
        
        uint256 balanceBefore = usdc.balanceOf(trader);
        uint256 totalProceeds = 0;
        
        for (uint256 i = 0; i < 3; i++) {
            uint256 bucketId = 45 + i;
            uint256 sharesToSell = sharesByBucket[i];
            
            uint256 expectedReturn = market.calculateReturnForShares(bucketId, sharesToSell);
            uint256 actualProceeds = market.sellShares(bucketId, sharesToSell, 0);
            totalProceeds += actualProceeds;
            
            console.log("   Bucket", bucketId, ":");
            console.log("      Sold shares:", sharesToSell);
            console.log("      Expected (view):", expectedReturn);
            console.log("      Actual proceeds:", actualProceeds);
        }
        
        console.log("");
        console.log("   TOTAL proceeds:", totalProceeds);
        console.log("   Proceeds in $:", totalProceeds / 1e6);
        
        uint256 netCostPaid = (TRADE_AMOUNT * 995) / 1000; // After 0.5% fee
        uint256 loss = netCostPaid > totalProceeds ? netCostPaid - totalProceeds : 0;
        uint256 lossPct = (loss * 100) / netCostPaid;
        
        console.log("");
        console.log("   Net cost paid (after fee): $", netCostPaid / 1e6);
        console.log("   Loss on immediate sell: $", loss / 1e6);
        console.log("   Loss %:", lossPct);
        console.log("");
        
        // ========== BUY BACK FOR RESOLUTION ==========
        console.log("5. BUY BACK: $10 for resolution test");
        console.log("   ---------------");
        
        totalSharesBought = 0;
        for (uint256 i = 0; i < 3; i++) {
            uint256 bucketId = 45 + i;
            uint256 sharesMinted = market.buyShares(bucketId, amountPerBucket, 0);
            sharesByBucket[i] = sharesMinted;
            totalSharesBought += sharesMinted;
        }
        
        console.log("   Total shares for claiming:", totalSharesBought);
        console.log("   Shares in $:", totalSharesBought / 1e6);
        console.log("");
        
        vm.stopPrank();
        
        // ========== RESOLVE ==========
        console.log("6. RESOLVE: Market at $114,600 (bucket 46)");
        console.log("   ---------------");
        
        vm.prank(creator);
        market.resolveMarket(114600); // bucket 46
        
        console.log("   Winning bucket: 46 ($114,600 - $114,700)");
        console.log("   Winning shares:", sharesByBucket[1]);
        console.log("   Winning shares in $:", sharesByBucket[1] / 1e6);
        console.log("");
        
        // ========== CLAIM ==========
        console.log("7. CLAIM: Winning payout");
        console.log("   ---------------");
        
        uint256 claimBalBefore = usdc.balanceOf(trader);
        vm.prank(trader);
        market.claimWinnings(46, sharesByBucket[1]);
        uint256 claimBalAfter = usdc.balanceOf(trader);
        uint256 payout = claimBalAfter - claimBalBefore;
        
        console.log("   Payout received:", payout);
        console.log("   Payout in $:", payout / 1e6);
        console.log("   Expected (shares = $1 each):", sharesByBucket[1]);
        console.log("");
        
        // ========== SUMMARY ==========
        console.log("================================================================================");
        console.log("       COMPARISON SUMMARY");
        console.log("================================================================================");
        console.log("");
        console.log("   PARAMETER                    SOLIDITY            SUI (expected)");
        console.log("   -----------                  --------            --------------");
        console.log("   Alpha                        $", market.alpha() / 1e6, "              $1000");
        console.log("   Initial shares/bucket        ", initShares, "        100000000");
        console.log("   Shares for $3.33/bucket      ~", sharesByBucket[0], "   ~289000000");
        console.log("   Loss on immediate sell       ", lossPct, "%                <5%");
        console.log("   Payout = Shares?             ", payout == sharesByBucket[1] ? "YES" : "NO", "               YES");
        console.log("");
        console.log("================================================================================");
        
        // Assertions
        assertEq(market.alpha() / 1e6, 1000, "Alpha should be $1000");
        assertTrue(lossPct <= 5, "Loss should be <5%");
        assertEq(payout, sharesByBucket[1], "Payout should equal winning shares");
    }
}