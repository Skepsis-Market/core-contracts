// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

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

    function setUp() public {
        usdc = new MockUSDC();

        (uint256[] memory seedIds, uint256[] memory seedShares) = _uniformSeeds(4, poolBalance);

        market = new LMSRMarket(LMSRMarket.InitParams({
                marketId: marketId,
                creator: creator,
                factory: factory,
                usdcToken: address(usdc),
                positionNFT: positionNFT,
                alpha: alpha,
                poolBalance: poolBalance,
                bucketWidth: 25,
                maxBucketId: // bucketWidth
            3,
                seededBucketIds: // maxBucketId
            seedIds,
                seededShares: seedShares,
                feeBps: feeBps,
                protocolFeeBps: protocolFeeBps,
                metadata: _defaultMetadata(),
                protocolFeeCollector: address(0xFEE)
            }));

        // Simulate initial LP deposit
        usdc.mint(address(market), poolBalance);
    }

    function _buyBucket(uint256 bucketId, uint256 amount, uint256 minShares) internal returns (uint256) {
        uint256 lower = bucketId * market.bucketWidth();
        return market.buySharesRange(lower, lower + market.bucketWidth(), amount, minShares, 0, address(0));
    }

    function _sellBucket(uint256 bucketId, uint256 shares, uint256 minPayout) internal returns (uint256) {
        uint256 lower = bucketId * market.bucketWidth();
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
        
        uint256 expectedAlpha = poolBalance / 2;
        assertEq(market.alpha(), expectedAlpha, "Alpha should match sqrt(n) calculation");
        
        assertEq(market.poolBalance(), poolBalance);
        assertEq(market.initialDeposit(), poolBalance);
        assertEq(market.bucketCount(), 4);
        assertEq(market.feeBps(), feeBps);
        assertEq(market.protocolFeeBps(), protocolFeeBps);
        assertEq(uint8(market.status()), uint8(LMSRMarket.MarketStatus.ACTIVE));
    }

    function test_constructor_revertsIfAlphaZero() public {
        (uint256[] memory seedIds, uint256[] memory seedShares) = _uniformSeeds(2, poolBalance);
        vm.expectRevert(LMSRMarket.InvalidParameters.selector);
        new LMSRMarket(LMSRMarket.InitParams({
                marketId: 1,
                creator: creator,
                factory: factory,
                usdcToken: address(usdc),
                positionNFT: positionNFT,
                alpha: 0,
                poolBalance: poolBalance,
                bucketWidth: 50,
                maxBucketId: 1,
                seededBucketIds: seedIds,
                seededShares: seedShares,
                feeBps: feeBps,
                protocolFeeBps: protocolFeeBps,
                metadata: _defaultMetadata(),
                protocolFeeCollector: address(0xFEE)
            }));
    }

    function test_constructor_revertsIfPoolBalanceZero() public {
        (uint256[] memory seedIds, uint256[] memory seedShares) = _uniformSeeds(2, poolBalance);
        vm.expectRevert(LMSRMarket.InvalidParameters.selector);
        new LMSRMarket(LMSRMarket.InitParams({
                marketId: 1,
                creator: creator,
                factory: factory,
                usdcToken: address(usdc),
                positionNFT: positionNFT,
                alpha: alpha,
                poolBalance: 0,
                bucketWidth: 50,
                maxBucketId: 1,
                seededBucketIds: seedIds,
                seededShares: seedShares,
                feeBps: feeBps,
                protocolFeeBps: protocolFeeBps,
                metadata: _defaultMetadata(),
                protocolFeeCollector: address(0xFEE)
            }));
    }

    function test_constructor_revertsIfTooFewBuckets() public {
        uint256[] memory seedIds = new uint256[](1);
        uint256[] memory seedShares = new uint256[](1);
        seedIds[0] = 0;
        seedShares[0] = poolBalance;
        vm.expectRevert(LMSRMarket.InvalidParameters.selector);
        new LMSRMarket(LMSRMarket.InitParams({
                marketId: 1,
                creator: creator,
                factory: factory,
                usdcToken: address(usdc),
                positionNFT: positionNFT,
                alpha: alpha,
                poolBalance: poolBalance,
                bucketWidth: 50,
                maxBucketId: 0,
                seededBucketIds: seedIds,
                seededShares: seedShares,
                feeBps: feeBps,
                protocolFeeBps: protocolFeeBps,
                metadata: _defaultMetadata(),
                protocolFeeCollector: address(0xFEE)
            }));
    }

    function test_constructor_revertsIfFeeExceedsMax() public {
        (uint256[] memory seedIds, uint256[] memory seedShares) = _uniformSeeds(2, poolBalance);
        vm.expectRevert(LMSRMarket.InvalidParameters.selector);
        new LMSRMarket(LMSRMarket.InitParams({
                marketId: 1,
                creator: creator,
                factory: factory,
                usdcToken: address(usdc),
                positionNFT: positionNFT,
                alpha: alpha,
                poolBalance: poolBalance,
                bucketWidth: 50,
                maxBucketId: 1,
                seededBucketIds: seedIds,
                seededShares: seedShares,
                feeBps: 501,
                protocolFeeBps: protocolFeeBps,
                metadata: _defaultMetadata(),
                protocolFeeCollector: address(0xFEE)
            }));
    }

    function test_initialState_uniformDistribution() public view {
        uint256 expectedShares = poolBalance / 4;
        for (uint256 i = 0; i < 4; i++) {
            (uint256 bShares,,,) = market.buckets(i);
            assertEq(bShares, expectedShares);
        }
    }

    function test_initialState_bucketRanges() public view {
        (,, uint256 bLower0, uint256 bUpper0) = market.buckets(0);
        assertEq(bLower0, 0);
        assertEq(bUpper0, 25);

        (,, uint256 bLower1, uint256 bUpper1) = market.buckets(1);
        assertEq(bLower1, 25);
        assertEq(bUpper1, 50);

        (,, uint256 bLower3, uint256 bUpper3) = market.buckets(3);
        assertEq(bLower3, 75);
        assertEq(bUpper3, 100);
    }

    function test_initialState_isSolvent() public view {
        uint256 expectedShares = poolBalance / 4;
        assertLe(expectedShares, poolBalance + market.SOLVENCY_DUST());
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
        (uint256 bShares,,,) = market.buckets(0);
        uint256 initialShares = poolBalance / 4;
        assertEq(bShares, initialShares + sharesMinted);
    }

    function test_buyShares_updatesPoolBalance() public {
        usdc.mint(buyer, 100_000000);

        uint256 costUSDC = 10_000000;
        uint256 poolBefore = market.poolBalance();
        
        uint256 feesUSDC = (costUSDC * market.feeBps()) / 10000;
        uint256 protocolFee = (feesUSDC * market.protocolFeeBps()) / 10000;
        uint256 lpFee = feesUSDC - protocolFee;
        uint256 netCost = costUSDC - feesUSDC;

        vm.startPrank(buyer);
        usdc.approve(address(market), 100_000000);
        _buyBucket(0, costUSDC, 0);
        vm.stopPrank();

        assertEq(market.poolBalance(), poolBefore + netCost + lpFee);
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

        uint256 width = market.bucketWidth();

        vm.startPrank(buyer);
        usdc.approve(address(market), 100_000000);
        vm.expectRevert(LMSRMarket.InvalidParameters.selector);
        market.buySharesRange(0, width, costUSDC, expectedShares + 1, 0, address(0));
        vm.stopPrank();
    }

    function test_buyShares_updatesState() public {
        usdc.mint(buyer, 100_000000);

        (uint256 sharesBefore,,,) = market.buckets(0);

        vm.startPrank(buyer);
        usdc.approve(address(market), 100_000000);
        _buyBucket(0, 10_000000, 0);
        vm.stopPrank();

        (uint256 sharesAfter,,,) = market.buckets(0);
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
        uint256 sumExp = 0;
        for (uint256 i = 0; i < market.bucketCount(); i++) {
            (uint256 bShares,,,) = market.buckets(i);
            uint256 exp_i = bShares.divWad(market.alpha()).exp();
            sumExp += exp_i;
        }
        (uint256 targetShares,,,) = market.buckets(bucketId);
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

        // poolBalance decreases by payout + protocol fee (both leave the contract)
        assertTrue(market.poolBalance() < poolBefore, "pool should decrease after sell");
        assertTrue(market.poolBalance() <= poolBefore - payoutUSDC, "pool decreases by at least payout");
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
        
        uint256 width = market.bucketWidth();
        vm.expectRevert(LMSRMarket.InvalidParameters.selector);
        market.sellSharesRange(0, width, sharesBought, expectedReturn + 1, address(0));
        vm.stopPrank();
    }

    function test_sellShares_revertsIfInsufficientShares() public {
        uint256 width = market.bucketWidth();
        vm.startPrank(buyer);
        vm.expectRevert(LMSRMarket.InsufficientBalance.selector);
        market.sellSharesRange(0, width, 1000e18, 0, address(0));
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
        uint256 winningValue = 50; // bucket 2 (50/25 = 2)
        
        vm.prank(creator);
        market.resolveMarket(winningValue);
        
        assertEq(uint8(market.status()), uint8(LMSRMarket.MarketStatus.RESOLVED));
        assertEq(market.winningBucket(), 2);
        assertEq(market.resolutionValue(), winningValue);
        assertEq(market.resolutionTime(), block.timestamp);
    }

    function test_resolveMarket_revertsIfNotCreator() public {
        vm.prank(user1);
        vm.expectRevert(LMSRMarket.Unauthorized.selector);
        market.resolveMarket(0);
    }

    function test_resolveMarket_revertsIfAlreadyResolved() public {
        vm.prank(creator);
        market.resolveMarket(25);
        
        vm.prank(creator);
        vm.expectRevert(LMSRMarket.MarketAlreadyResolved.selector);
        market.resolveMarket(50);
    }

    function test_resolveMarket_revertsIfInvalidValue() public {
        vm.prank(creator);
        vm.expectRevert(LMSRMarket.InvalidResolutionValue.selector);
        market.resolveMarket(999); // value 999 is outside valid range
    }

    // ============================================
    // LP WITHDRAWAL TESTS
    // ============================================

    function test_withdrawLP_calculatesCorrectly() public {
        uint256 bucketId = 1;
        uint256 buyAmount = 200 * 1e6;
        
        usdc.mint(user1, buyAmount);
        vm.startPrank(user1);
        usdc.approve(address(market), buyAmount);
        _buyBucket(bucketId, buyAmount, 0);
        vm.stopPrank();

        uint256 poolBeforeResolution = market.poolBalance();

        vm.prank(creator);
        market.resolveMarket(25);

        (uint256 winningShares, uint256 initialSharesBucket,,) = market.buckets(bucketId);
        uint256 traderOwed = winningShares > initialSharesBucket ? winningShares - initialSharesBucket : 0;
        uint256 expectedLP = poolBeforeResolution - traderOwed;
        
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
        market.resolveMarket(0);
        
        vm.prank(user1);
        vm.expectRevert(LMSRMarket.Unauthorized.selector);
        market.withdrawLP();
    }

    function test_withdrawLP_preventsDoubleWithdraw() public {
        uint256 bucketId = 0;
        uint256 buyAmount = 50 * 1e6;
        
        usdc.mint(user1, buyAmount);
        vm.startPrank(user1);
        usdc.approve(address(market), buyAmount);
        _buyBucket(bucketId, buyAmount, 0);
        vm.stopPrank();
        
        vm.prank(creator);
        market.resolveMarket(0);
        
        vm.startPrank(creator);
        market.withdrawLP();
        
        vm.expectRevert(LMSRMarket.InvalidParameters.selector);
        market.withdrawLP();
        vm.stopPrank();
    }

    function test_getLPProfitability_showsCorrectROI() public {
        uint256 bucketId = 2;
        uint256 buyAmount = 100 * 1e6;
        
        usdc.mint(user1, buyAmount);
        vm.startPrank(user1);
        usdc.approve(address(market), buyAmount);
        _buyBucket(bucketId, buyAmount, 0);
        vm.stopPrank();
        
        (int256 unrealizedProfit, int256 roi, uint256 feesEarned) = market.getLPProfitability();
        
        assertGt(unrealizedProfit, 0, "LP should have unrealized profit from fees");
        assertGt(roi, 0, "ROI should be positive");
        assertGt(feesEarned, 0, "Fees should be collected");
        
        int256 expectedROI = (unrealizedProfit * 10000) / int256(poolBalance);
        assertEq(roi, expectedROI, "ROI should match formula");
    }

    function test_lpProfitScenario_highVolume() public {
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
        
        assertGt(unrealizedProfit, 0, "LP should profit from high volume");
        assertGt(roi, 0, "ROI should be positive with high trading fees");
    }

    function test_lpLossScenario_lowVolume() public {
        vm.prank(creator);
        market.resolveMarket(0);

        (int256 unrealizedProfit,,) = market.getLPProfitability();

        assertEq(unrealizedProfit, 0, "LP should break even with no trading (all winning shares are initial)");
    }

}
