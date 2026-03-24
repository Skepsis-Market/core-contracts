// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {LMSRMarket} from "../src/LMSRMarket.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {FixedPointMath} from "../src/FixedPointMath.sol";

contract LMSRMarketTest is Test {
    using FixedPointMath for uint256;

    LMSRMarket market;
    MockUSDC usdc;
    
    address factory = address(0xFACE);
    address creator = address(0x1);
    address positionNFT = address(0x2);
    address buyer = address(0x123);
    address user1 = address(0x456);
    
    uint256 marketId = 1;
    uint256 alpha = 500_000000;
    uint256 poolBalance = 1000_000000;
    uint256 feeBps = 50;
    uint256 protocolFeeBps = 2000;

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

        uint256[] memory bucketRanges = new uint256[](5);
        bucketRanges[0] = 0;
        bucketRanges[1] = 25;
        bucketRanges[2] = 50;
        bucketRanges[3] = 75;
        bucketRanges[4] = 100;

        market = new LMSRMarket(
            marketId,
            creator,
            factory,
            address(usdc),
            positionNFT,
            alpha,
            poolBalance,
            bucketRanges,
            feeBps,
            protocolFeeBps,
            _defaultMetadata(),
            address(0xFEE)
        );

        // Simulate initial LP deposit
        usdc.mint(address(market), poolBalance);
    }

    function _buyBucket(uint256 bucketId, uint256 amount, uint256 minShares) internal returns (uint256) {
        uint256 lower = market.marketMin() + (bucketId * market.bucketWidth());
        return market.buySharesRange(lower, lower + market.bucketWidth(), amount, minShares, 0, address(0));
    }

    function _sellBucket(uint256 bucketId, uint256 shares, uint256 minPayout) internal returns (uint256) {
        uint256 lower = market.marketMin() + (bucketId * market.bucketWidth());
        return market.sellSharesRange(lower, lower + market.bucketWidth(), shares, minPayout, address(0));
    }

    function _claimBucket(uint256 bucketId) internal returns (uint256) {
        uint256 tokenId = (uint256(uint128(market.marketId())) << 128) | (uint256(uint64(bucketId)) << 64) | uint256(uint64(bucketId));
        return market.claim(tokenId, address(0));
    }

    function test_constructor_initializesCorrectly() public view {
        assertEq(market.marketId(), marketId);
        assertEq(market.creator(), creator);
        assertEq(market.factory(), factory);
        assertEq(address(market.usdcToken()), address(usdc));
        assertEq(market.positionNFT(), positionNFT);
        
        // Alpha formula matches Sui: alpha = pool / sqrt(n)
        // For 4 buckets: sqrt(4) = 2, so alpha = poolBalance / 2
        uint256 expectedAlpha = poolBalance / 2; // sqrt(4) = 2
        assertEq(market.alpha(), expectedAlpha, "Alpha should match sqrt(n) calculation");
        
        assertEq(market.poolBalance(), poolBalance);
        assertEq(market.initialDeposit(), poolBalance);
        assertEq(market.bucketCount(), 4);
        assertEq(market.feeBps(), feeBps);
        assertEq(market.protocolFeeBps(), protocolFeeBps);
        assertEq(uint8(market.status()), uint8(LMSRMarket.MarketStatus.ACTIVE));
    }

    function test_constructor_revertsIfAlphaZero() public {
        uint256[] memory bucketRanges = new uint256[](3);
        bucketRanges[0] = 0;
        bucketRanges[1] = 50;
        bucketRanges[2] = 100;

        vm.expectRevert(LMSRMarket.InvalidParameters.selector);
        new LMSRMarket(1, creator, factory, address(usdc), positionNFT, 0, poolBalance, bucketRanges, feeBps, protocolFeeBps, _defaultMetadata(), address(0xFEE));
    }

    function test_constructor_revertsIfPoolBalanceZero() public {
        uint256[] memory bucketRanges = new uint256[](3);
        bucketRanges[0] = 0;
        bucketRanges[1] = 50;
        bucketRanges[2] = 100;

        vm.expectRevert(LMSRMarket.InvalidParameters.selector);
        new LMSRMarket(1, creator, factory, address(usdc), positionNFT, alpha, 0, bucketRanges, feeBps, protocolFeeBps, _defaultMetadata(), address(0xFEE));
    }

    function test_constructor_revertsIfTooFewBuckets() public {
        uint256[] memory bucketRanges = new uint256[](1);
        bucketRanges[0] = 0;

        vm.expectRevert(LMSRMarket.InvalidParameters.selector);
        new LMSRMarket(1, creator, factory, address(usdc), positionNFT, alpha, poolBalance, bucketRanges, feeBps, protocolFeeBps, _defaultMetadata(), address(0xFEE));
    }

    function test_constructor_revertsIfFeeExceedsMax() public {
        uint256[] memory bucketRanges = new uint256[](3);
        bucketRanges[0] = 0;
        bucketRanges[1] = 50;
        bucketRanges[2] = 100;

        vm.expectRevert(LMSRMarket.InvalidParameters.selector);
        new LMSRMarket(1, creator, factory, address(usdc), positionNFT, alpha, poolBalance, bucketRanges, 501, protocolFeeBps, _defaultMetadata(), address(0xFEE));
    }

    function test_initialState_uniformDistribution() public view {
        // Shares are now in 6 decimals, not WAD
        uint256 expectedShares = poolBalance / 4; // 6 decimals
        for (uint256 i = 0; i < 4; i++) {
            (uint256 bShares,,) = market.buckets(i);
            assertEq(bShares, expectedShares);
        }
    }

    function test_initialState_bucketRanges() public view {
        (, uint256 bLower0, uint256 bUpper0) = market.buckets(0);
        assertEq(bLower0, 0);
        assertEq(bUpper0, 25);

        (, uint256 bLower1, uint256 bUpper1) = market.buckets(1);
        assertEq(bLower1, 25);
        assertEq(bUpper1, 50);

        (, uint256 bLower3, uint256 bUpper3) = market.buckets(3);
        assertEq(bLower3, 75);
        assertEq(bUpper3, 100);
    }

    function test_initialState_isSolvent() public view {
        uint256 expectedShares = poolBalance.toWad() / 4;
        uint256 maxSharesUSDC = expectedShares.fromWad();
        assertLe(maxSharesUSDC, poolBalance + market.SOLVENCY_DUST());
    }

    function test_calculateSharesForCost_basic() public view {
        uint256 costUSDC = 10_000000;
        uint256 shares = market.calculateSharesForCost(0, costUSDC);
        assertGt(shares, 0);
    }

    function test_buyShares_mintsCorrectShares() public {
        usdc.mint(buyer, 100_000000);
        
        vm.startPrank(buyer);
        usdc.approve(address(market), 100_000000);

        uint256 costUSDC = 10_000000;
        uint256 feesUSDC = (costUSDC * market.feeBps()) / 10000;
        uint256 netCostUSDC = costUSDC - feesUSDC;
        uint256 expectedShares = market.calculateSharesForCost(0, netCostUSDC);
        
        uint256 sharesMinted = _buyBucket(0, costUSDC, expectedShares);
        vm.stopPrank();

        assertEq(sharesMinted, expectedShares);
        (uint256 bShares,,) = market.buckets(0);
        // Shares are now in 6 decimals, not WAD
        uint256 initialShares = poolBalance / 4; // 6 decimals
        assertEq(bShares, initialShares + sharesMinted);
    }

    function test_buyShares_updatesPoolBalance() public {
        usdc.mint(buyer, 100_000000);

        uint256 costUSDC = 10_000000;
        uint256 poolBefore = market.poolBalance();
        
        uint256 feesUSDC = (costUSDC * market.feeBps()) / 10000;
        uint256 netCost = costUSDC - feesUSDC;

        vm.startPrank(buyer);
        usdc.approve(address(market), 100_000000);
        _buyBucket(0, costUSDC, 0);
        vm.stopPrank();
        
        assertEq(market.poolBalance(), poolBefore + netCost);
    }

    function test_buyShares_collectsFees() public {
        usdc.mint(buyer, 100_000000);

        uint256 costUSDC = 10_000000;
        uint256 feesUSDC = (costUSDC * market.feeBps()) / 10000;
        uint256 protocolFee = (feesUSDC * market.protocolFeeBps()) / 10000;
        uint256 lpFee = feesUSDC - protocolFee;

        vm.startPrank(buyer);
        usdc.approve(address(market), 100_000000);
        _buyBucket(0, costUSDC, 0);
        vm.stopPrank();
        
        assertEq(market.feesCollectedLP(), lpFee);
        assertEq(market.feesCollectedProtocol(), protocolFee);
    }

    function test_buyShares_revertsOnSlippage() public {
        usdc.mint(buyer, 100_000000);

        uint256 costUSDC = 10_000000;
        uint256 feesUSDC = (costUSDC * market.feeBps()) / 10000;
        uint256 netCostUSDC = costUSDC - feesUSDC;
        uint256 expectedShares = market.calculateSharesForCost(0, netCostUSDC);

        uint256 lower = market.marketMin();
        uint256 width = market.bucketWidth();

        vm.startPrank(buyer);
        usdc.approve(address(market), 100_000000);
        vm.expectRevert(LMSRMarket.InvalidParameters.selector);
        market.buySharesRange(lower, lower + width, costUSDC, expectedShares + 1, 0, address(0));
        vm.stopPrank();
    }

    function test_buyShares_updatesState() public {
        usdc.mint(buyer, 100_000000);

        (uint256 sharesBefore,,) = market.buckets(0);

        vm.startPrank(buyer);
        usdc.approve(address(market), 100_000000);
        _buyBucket(0, 10_000000, 0);
        vm.stopPrank();

        (uint256 sharesAfter,,) = market.buckets(0);
        assertGt(sharesAfter, sharesBefore);
    }

    function test_calculatePrice_returnsValidProbability() public view {
        uint256 totalProb = 0;
        for (uint256 i = 0; i < 4; i++) {
            uint256 price = this.getPrice(i);
            assertGt(price, 0);
            assertLe(price, 1e18);
            totalProb += price;
        }
        assertApproxEqRel(totalProb, 1e18, 0.01e18);
    }

    function getPrice(uint256 bucketId) external view returns (uint256) {
        // Compute sumExp manually from all buckets
        uint256 sumExp = 0;
        for (uint256 i = 0; i < market.bucketCount(); i++) {
            (uint256 bShares,,) = market.buckets(i);
            uint256 exp_i = bShares.divWad(market.alpha()).exp();
            sumExp += exp_i;
        }
        (uint256 targetShares,,) = market.buckets(bucketId);
        uint256 exponent = targetShares.divWad(market.alpha());
        uint256 bucketExp = exponent.exp();
        return bucketExp.divWad(sumExp);
    }

    function test_calculateReturnForShares_basic() public {
        usdc.mint(buyer, 100_000000);
        
        vm.startPrank(buyer);
        usdc.approve(address(market), 100_000000);
        
        uint256 costUSDC = 10_000000;
        uint256 feesUSDC = (costUSDC * market.feeBps()) / 10000;
        uint256 netCostUSDC = costUSDC - feesUSDC;
        uint256 sharesBought = market.calculateSharesForCost(0, netCostUSDC);
        
        _buyBucket(0, costUSDC, sharesBought);
        vm.stopPrank();
        
        uint256 returnUSDC = market.calculateReturnForShares(0, sharesBought);
        assertGt(returnUSDC, 0);
        assertLt(returnUSDC, netCostUSDC);
    }

    function test_sellShares_returnsUSDC() public {
        usdc.mint(buyer, 100_000000);
        
        vm.startPrank(buyer);
        usdc.approve(address(market), 100_000000);
        
        uint256 costUSDC = 10_000000;
        uint256 feesUSDC = (costUSDC * market.feeBps()) / 10000;
        uint256 netCostUSDC = costUSDC - feesUSDC;
        uint256 sharesBought = market.calculateSharesForCost(0, netCostUSDC);
        
        _buyBucket(0, costUSDC, sharesBought);
        
        uint256 balanceBefore = usdc.balanceOf(buyer);
        uint256 payoutUSDC = _sellBucket(0, sharesBought, 0);
        uint256 balanceAfter = usdc.balanceOf(buyer);
        vm.stopPrank();
        
        assertEq(balanceAfter - balanceBefore, payoutUSDC);
        assertGt(payoutUSDC, 0);
    }

    function test_sellShares_updatesPoolBalance() public {
        usdc.mint(buyer, 100_000000);
        
        vm.startPrank(buyer);
        usdc.approve(address(market), 100_000000);
        
        uint256 costUSDC = 10_000000;
        uint256 feesUSDC = (costUSDC * market.feeBps()) / 10000;
        uint256 netCostUSDC = costUSDC - feesUSDC;
        uint256 sharesBought = market.calculateSharesForCost(0, netCostUSDC);
        
        _buyBucket(0, costUSDC, sharesBought);
        
        uint256 poolBefore = market.poolBalance();
        uint256 payoutUSDC = _sellBucket(0, sharesBought, 0);
        vm.stopPrank();
        
        assertEq(market.poolBalance(), poolBefore - payoutUSDC);
    }

    function test_sellShares_collectsFees() public {
        usdc.mint(buyer, 100_000000);
        
        vm.startPrank(buyer);
        usdc.approve(address(market), 100_000000);
        
        uint256 costUSDC = 10_000000;
        uint256 feesUSDC = (costUSDC * market.feeBps()) / 10000;
        uint256 netCostUSDC = costUSDC - feesUSDC;
        uint256 sharesBought = market.calculateSharesForCost(0, netCostUSDC);
        
        _buyBucket(0, costUSDC, sharesBought);
        
        uint256 lpFeesBefore = market.feesCollectedLP();
        uint256 protocolFeesBefore = market.feesCollectedProtocol();
        
        _sellBucket(0, sharesBought, 0);
        vm.stopPrank();
        
        assertGt(market.feesCollectedLP(), lpFeesBefore);
        assertGt(market.feesCollectedProtocol(), protocolFeesBefore);
    }

    function test_sellShares_revertsOnSlippage() public {
        usdc.mint(buyer, 100_000000);
        
        vm.startPrank(buyer);
        usdc.approve(address(market), 100_000000);
        
        uint256 costUSDC = 10_000000;
        uint256 feesUSDC = (costUSDC * market.feeBps()) / 10000;
        uint256 netCostUSDC = costUSDC - feesUSDC;
        uint256 sharesBought = market.calculateSharesForCost(0, netCostUSDC);
        
        _buyBucket(0, costUSDC, sharesBought);
        
        uint256 expectedReturn = market.calculateReturnForShares(0, sharesBought);
        
        uint256 lower = market.marketMin();
        uint256 width = market.bucketWidth();
        vm.expectRevert(LMSRMarket.InvalidParameters.selector);
        market.sellSharesRange(lower, lower + width, sharesBought, expectedReturn + 1, address(0));
        vm.stopPrank();
    }

    function test_sellShares_revertsIfInsufficientShares() public {
        uint256 lower = market.marketMin();
        uint256 width = market.bucketWidth();
        vm.startPrank(buyer);
        vm.expectRevert(LMSRMarket.InsufficientBalance.selector);
        market.sellSharesRange(lower, lower + width, 1000e18, 0, address(0));
        vm.stopPrank();
    }

    function test_buyThenSell_roundTrip() public {
        usdc.mint(buyer, 100_000000);
        
        vm.startPrank(buyer);
        usdc.approve(address(market), 100_000000);
        
        uint256 costUSDC = 10_000000;
        uint256 feesUSDC = (costUSDC * market.feeBps()) / 10000;
        uint256 netCostUSDC = costUSDC - feesUSDC;
        uint256 sharesBought = market.calculateSharesForCost(0, netCostUSDC);
        
        uint256 balanceStart = usdc.balanceOf(buyer);
        
        _buyBucket(0, costUSDC, sharesBought);
        uint256 payoutUSDC = _sellBucket(0, sharesBought, 0);
        
        uint256 balanceEnd = usdc.balanceOf(buyer);
        vm.stopPrank();
        
        uint256 totalFees = costUSDC - payoutUSDC;
        assertEq(balanceStart - balanceEnd, totalFees);
        assertGt(totalFees, 0);
    }

    // ============================================
    // RESOLUTION & CLAIMS TESTS
    // ============================================

    function test_resolveMarket_setsWinningBucket() public {
        uint256 winningValue = 50; // bucket 2 in 0-100 with 4 buckets
        
        vm.prank(creator);
        market.resolveMarket(winningValue);
        
        assertEq(uint8(market.status()), uint8(LMSRMarket.MarketStatus.RESOLVED));
        assertEq(market.winningBucket(), 2); // value 50 → bucket 2
        assertEq(market.resolutionValue(), winningValue);
        assertEq(market.resolutionTime(), block.timestamp);
    }

    function test_resolveMarket_revertsIfNotCreator() public {
        vm.prank(user1);
        vm.expectRevert(LMSRMarket.Unauthorized.selector);
        market.resolveMarket(0); // value 0 = bucket 0
    }

    function test_resolveMarket_revertsIfAlreadyResolved() public {
        vm.prank(creator);
        market.resolveMarket(25); // value 25 = bucket 1
        
        vm.prank(creator);
        vm.expectRevert(LMSRMarket.MarketAlreadyResolved.selector);
        market.resolveMarket(50); // value 50 = bucket 2
    }

    function test_resolveMarket_revertsIfInvalidValue() public {
        vm.prank(creator);
        vm.expectRevert(LMSRMarket.InvalidResolutionValue.selector);
        market.resolveMarket(999); // value 999 is outside [0, 100]
    }

    // NOTE: claim tests moved to LMSRMarketPositionAccounting.t.sol (requires real PositionNFT)

    // ============================================
    // LP WITHDRAWAL TESTS
    // ============================================

    function test_withdrawLP_calculatesCorrectly() public {
        // User buys shares
        uint256 bucketId = 1;
        uint256 buyAmount = 200 * 1e6;
        
        usdc.mint(user1, buyAmount);
        vm.startPrank(user1);
        usdc.approve(address(market), buyAmount);
        _buyBucket(bucketId, buyAmount, 0);
        vm.stopPrank();

        uint256 poolBeforeResolution = market.poolBalance();

        // Resolve market with value 25 (bucket 1)
        vm.prank(creator);
        market.resolveMarket(25);

        // Get winning shares - now in 6 decimals
        (uint256 winningShares,,) = market.buckets(bucketId);
        // Shares are 6 decimals, payout = shares (both 6 decimals)
        uint256 expectedPayouts = winningShares;
        uint256 expectedLP = poolBeforeResolution - expectedPayouts;
        
        // LP withdraws
        uint256 creatorBalanceBefore = usdc.balanceOf(creator);
        vm.prank(creator);
        market.withdrawLP();
        uint256 creatorBalanceAfter = usdc.balanceOf(creator);
        
        uint256 withdrawn = creatorBalanceAfter - creatorBalanceBefore;
        assertEq(withdrawn, expectedLP, "LP should receive pool minus unclaimed winnings");
    }

    function test_withdrawLP_revertsIfNotResolved() public {
        vm.prank(creator);
        vm.expectRevert(LMSRMarket.MarketNotActive.selector);
        market.withdrawLP();
    }

    function test_withdrawLP_revertsIfNotCreator() public {
        vm.prank(creator);
        market.resolveMarket(0); // value 0 = bucket 0
        
        vm.prank(user1);
        vm.expectRevert(LMSRMarket.Unauthorized.selector);
        market.withdrawLP();
    }

    function test_withdrawLP_preventsDoubleWithdraw() public {
        // Add some trading first so there's something to withdraw
        uint256 bucketId = 0;
        uint256 buyAmount = 50 * 1e6;
        
        usdc.mint(user1, buyAmount);
        vm.startPrank(user1);
        usdc.approve(address(market), buyAmount);
        _buyBucket(bucketId, buyAmount, 0);
        vm.stopPrank();
        
        vm.prank(creator);
        market.resolveMarket(0); // value 0 = bucket 0
        
        vm.startPrank(creator);
        market.withdrawLP();
        
        // Second withdrawal should fail because LP already withdrew
        vm.expectRevert(LMSRMarket.InvalidParameters.selector);
        market.withdrawLP();
        vm.stopPrank();
    }

    function test_getLPProfitability_showsCorrectROI() public {
        // Scenario: LP profits from trading fees
        uint256 bucketId = 2;
        uint256 buyAmount = 100 * 1e6;
        
        usdc.mint(user1, buyAmount);
        vm.startPrank(user1);
        usdc.approve(address(market), buyAmount);
        _buyBucket(bucketId, buyAmount, 0);
        vm.stopPrank();
        
        (int256 unrealizedProfit, int256 roi, uint256 feesEarned) = market.getLPProfitability();
        
        // LP should have profit from fees
        assertGt(unrealizedProfit, 0, "LP should have unrealized profit from fees");
        assertGt(roi, 0, "ROI should be positive");
        assertGt(feesEarned, 0, "Fees should be collected");
        
        // Check ROI calculation: roi = (profit * 10000) / initialDeposit
        int256 expectedROI = (unrealizedProfit * 10000) / int256(poolBalance);
        assertEq(roi, expectedROI, "ROI should match formula");
    }

    function test_lpProfitScenario_highVolume() public {
        // High trading volume = more fees for LP
        uint256 totalVolume = 0;
        
        for (uint256 i = 0; i < 3; i++) {
            uint256 buyAmount = 50 * 1e6;
            totalVolume += buyAmount;
            
            address trader = address(uint160(1000 + i));
            usdc.mint(trader, buyAmount);
            
            vm.startPrank(trader);
            usdc.approve(address(market), buyAmount);
            _buyBucket(i % 4, buyAmount, 0);
            vm.stopPrank();
        }
        
        (int256 unrealizedProfit, int256 roi,) = market.getLPProfitability();
        
        // LP should profit significantly from high volume fees
        assertGt(unrealizedProfit, 0, "LP should profit from high volume");
        assertGt(roi, 0, "ROI should be positive with high trading fees");
    }

    function test_lpLossScenario_lowVolume() public {
        // Resolve immediately with no trading
        // LP should get back (poolBalance - winningShares)
        // Initial uniform distribution: each bucket has poolBalance/4 WAD shares
        vm.prank(creator);
        market.resolveMarket(0); // value 0 = bucket 0
        
        (int256 unrealizedProfit,,) = market.getLPProfitability();
        
        // With uniform initial distribution, winning bucket has poolBalance/bucketCount shares
        // Those shares cost exactly poolBalance/bucketCount in USDC to pay out
        // So LP gets back: poolBalance - (poolBalance/4) = 3*poolBalance/4
        // Profit = (3/4)*initialDeposit - initialDeposit = -1/4 * initialDeposit
        int256 expectedLoss = -int256(poolBalance / 4);
        assertEq(unrealizedProfit, expectedLoss, "LP should have predictable loss from uniform distribution");
        assertLt(unrealizedProfit, 0, "LP should have loss with no trading volume");
    }

}

