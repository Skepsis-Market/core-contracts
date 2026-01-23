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
    
    uint256 marketId = 1;
    uint256 alpha = 100e18;
    uint256 poolBalance = 1000_000000;
    uint256 feeBps = 50;
    uint256 protocolFeeBps = 2000;

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
            protocolFeeBps
        );
    }

    function test_constructor_initializesCorrectly() public view {
        assertEq(market.marketId(), marketId);
        assertEq(market.creator(), creator);
        assertEq(market.factory(), factory);
        assertEq(address(market.usdcToken()), address(usdc));
        assertEq(market.positionNFT(), positionNFT);
        
        uint256 calculatedAlpha = poolBalance.toWad().divWad(
            market.SPREAD_FACTOR().mulWad((uint256(4)).fromU256().ln())
        );
        assertEq(market.alpha(), calculatedAlpha, "Alpha should match dynamic calculation");
        
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
        new LMSRMarket(1, creator, factory, address(usdc), positionNFT, 0, poolBalance, bucketRanges, feeBps, protocolFeeBps);
    }

    function test_constructor_revertsIfPoolBalanceZero() public {
        uint256[] memory bucketRanges = new uint256[](3);
        bucketRanges[0] = 0;
        bucketRanges[1] = 50;
        bucketRanges[2] = 100;

        vm.expectRevert(LMSRMarket.InvalidParameters.selector);
        new LMSRMarket(1, creator, factory, address(usdc), positionNFT, alpha, 0, bucketRanges, feeBps, protocolFeeBps);
    }

    function test_constructor_revertsIfTooFewBuckets() public {
        uint256[] memory bucketRanges = new uint256[](1);
        bucketRanges[0] = 0;

        vm.expectRevert(LMSRMarket.InvalidParameters.selector);
        new LMSRMarket(1, creator, factory, address(usdc), positionNFT, alpha, poolBalance, bucketRanges, feeBps, protocolFeeBps);
    }

    function test_constructor_revertsIfFeeExceedsMax() public {
        uint256[] memory bucketRanges = new uint256[](3);
        bucketRanges[0] = 0;
        bucketRanges[1] = 50;
        bucketRanges[2] = 100;

        vm.expectRevert(LMSRMarket.InvalidParameters.selector);
        new LMSRMarket(1, creator, factory, address(usdc), positionNFT, alpha, poolBalance, bucketRanges, 501, protocolFeeBps);
    }

    function test_initialState_uniformDistribution() public view {
        uint256 expectedShares = poolBalance.toWad() / 4;
        for (uint256 i = 0; i < 4; i++) {
            LMSRMarket.Bucket memory bucket = market.getBucket(i);
            assertEq(bucket.shares, expectedShares);
        }
    }

    function test_initialState_bucketRanges() public view {
        LMSRMarket.Bucket memory bucket0 = market.getBucket(0);
        assertEq(bucket0.lowerBound, 0);
        assertEq(bucket0.upperBound, 25);

        LMSRMarket.Bucket memory bucket1 = market.getBucket(1);
        assertEq(bucket1.lowerBound, 25);
        assertEq(bucket1.upperBound, 50);

        LMSRMarket.Bucket memory bucket3 = market.getBucket(3);
        assertEq(bucket3.lowerBound, 75);
        assertEq(bucket3.upperBound, 100);
    }

    function test_initialState_cachedSumExpSet() public view {
        uint256 cachedSum = market.getCachedSumExp();
        assertGt(cachedSum, 0);
        assertFalse(market.isSumExpDirty());
    }

    function test_getBucket_revertsOnInvalidId() public {
        vm.expectRevert(LMSRMarket.InvalidBucket.selector);
        market.getBucket(4);

        vm.expectRevert(LMSRMarket.InvalidBucket.selector);
        market.getBucket(100);
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
        
        uint256 sharesMinted = market.buyShares(0, costUSDC, expectedShares);
        vm.stopPrank();
        
        assertEq(sharesMinted, expectedShares);
        LMSRMarket.Bucket memory bucket = market.getBucket(0);
        assertEq(bucket.shares, poolBalance.toWad() / 4 + sharesMinted);
    }

    function test_buyShares_updatesPoolBalance() public {
        usdc.mint(buyer, 100_000000);

        uint256 costUSDC = 10_000000;
        uint256 poolBefore = market.poolBalance();
        
        uint256 feesUSDC = (costUSDC * market.feeBps()) / 10000;
        uint256 netCost = costUSDC - feesUSDC;

        vm.startPrank(buyer);
        usdc.approve(address(market), 100_000000);
        market.buyShares(0, costUSDC, 0);
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
        market.buyShares(0, costUSDC, 0);
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
        
        vm.startPrank(buyer);
        usdc.approve(address(market), 100_000000);
        vm.expectRevert(LMSRMarket.InvalidParameters.selector);
        market.buyShares(0, costUSDC, expectedShares + 1);
        vm.stopPrank();
    }

    function test_buyShares_updatesSumExpCache() public {
        usdc.mint(buyer, 100_000000);

        uint256 sumExpBefore = market.getCachedSumExp();
        
        vm.startPrank(buyer);
        usdc.approve(address(market), 100_000000);
        market.buyShares(0, 10_000000, 0);
        vm.stopPrank();
        
        uint256 sumExpAfter = market.getCachedSumExp();
        assertGt(sumExpAfter, sumExpBefore);
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
        uint256 sumExp = market.getCachedSumExp();
        LMSRMarket.Bucket memory bucket = market.getBucket(bucketId);
        uint256 exponent = bucket.shares.divWad(market.alpha());
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
        
        market.buyShares(0, costUSDC, sharesBought);
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
        
        market.buyShares(0, costUSDC, sharesBought);
        
        uint256 balanceBefore = usdc.balanceOf(buyer);
        uint256 payoutUSDC = market.sellShares(0, sharesBought, 0);
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
        
        market.buyShares(0, costUSDC, sharesBought);
        
        uint256 poolBefore = market.poolBalance();
        uint256 payoutUSDC = market.sellShares(0, sharesBought, 0);
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
        
        market.buyShares(0, costUSDC, sharesBought);
        
        uint256 lpFeesBefore = market.feesCollectedLP();
        uint256 protocolFeesBefore = market.feesCollectedProtocol();
        
        market.sellShares(0, sharesBought, 0);
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
        
        market.buyShares(0, costUSDC, sharesBought);
        
        uint256 expectedReturn = market.calculateReturnForShares(0, sharesBought);
        
        vm.expectRevert(LMSRMarket.InvalidParameters.selector);
        market.sellShares(0, sharesBought, expectedReturn + 1);
        vm.stopPrank();
    }

    function test_sellShares_revertsIfInsufficientShares() public {
        vm.startPrank(buyer);
        vm.expectRevert(LMSRMarket.InsufficientBalance.selector);
        market.sellShares(0, 1000e18, 0);
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
        
        market.buyShares(0, costUSDC, sharesBought);
        uint256 payoutUSDC = market.sellShares(0, sharesBought, 0);
        
        uint256 balanceEnd = usdc.balanceOf(buyer);
        vm.stopPrank();
        
        uint256 totalFees = costUSDC - payoutUSDC;
        assertEq(balanceStart - balanceEnd, totalFees);
        assertGt(totalFees, 0);
    }
}
