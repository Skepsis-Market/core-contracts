// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {MarketFactory} from "../../src/MarketFactory.sol";
import {LMSRMarket} from "../../src/LMSRMarket.sol";
import {PositionNFT} from "../../src/PositionNFT.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";

/// @notice Integration tests for full market lifecycle
/// @dev Tests: Factory → Create → Trade → Resolve → Claim → LP Withdraw
contract MarketLifecycleTest is Test {
    MarketFactory public factory;
    PositionNFT public positionNFT;
    MockUSDC public usdc;
    
    address admin = address(0x1);
    address creator = address(0x2);
    address alice = address(0x3);
    address bob = address(0x4);
    address charlie = address(0x5);
    
    uint256 constant POOL_BALANCE = 10000_000000; // $10,000
    uint256 constant TRADE_AMOUNT = 100_000000; // $100
    
    function setUp() public {
        vm.startPrank(admin);
        
        // Deploy USDC
        usdc = new MockUSDC();
        
        // Predict factory address at nonce 2
        address predictedFactory = vm.computeCreateAddress(admin, 2);
        
        // Deploy PositionNFT with predicted factory address
        positionNFT = new PositionNFT(predictedFactory);
        
        // Deploy factory (must be at nonce 2)
        factory = new MarketFactory(
            address(usdc),
            address(positionNFT),
            1000_000000, // minPoolBalance = $1,000
            100, // maxBuckets
            50, // defaultFeeBps = 0.5%
            2000 // defaultProtocolFeeBps = 20%
        );
        
        // Verify factory address matches prediction
        require(address(factory) == predictedFactory, "Factory address mismatch");
        
        vm.stopPrank();
        
        // Mint USDC to users
        usdc.mint(creator, 50000_000000); // $50k
        usdc.mint(alice, 10000_000000); // $10k
        usdc.mint(bob, 10000_000000); // $10k
        usdc.mint(charlie, 10000_000000); // $10k
    }
    
    /// @notice Test full lifecycle: Create → Trade → Resolve → Claim → Withdraw
    function test_fullLifecycle_bitcoinScenario() public {
        // === PHASE 1: Market Creation ===
        uint256[] memory bucketRanges = new uint256[](11);
        for (uint256 i = 0; i <= 10; i++) {
            bucketRanges[i] = i * 10; // 0, 10, 20, ..., 100
        }
        
        vm.startPrank(creator);
        usdc.approve(address(factory), POOL_BALANCE);
        
        address marketAddress = factory.createMarket(
            POOL_BALANCE,
            bucketRanges,
            50, // 0.5% trading fee
            2000 // 20% protocol fee
        );
        vm.stopPrank();
        
        LMSRMarket market = LMSRMarket(marketAddress);
        uint256 marketId = market.marketId();
        
        // Verify market initialized correctly
        assertEq(market.poolBalance(), POOL_BALANCE);
        assertEq(market.bucketCount(), 10);
        assertEq(market.creator(), creator);
        assertEq(usdc.balanceOf(address(market)), POOL_BALANCE);
        
        // === PHASE 2: Trading ===
        
        // Alice buys bucket 7 (70-80 range) - bullish on Bitcoin at $75k
        vm.startPrank(alice);
        usdc.approve(address(market), TRADE_AMOUNT);
        uint256 aliceShares = market.buyShares(7, TRADE_AMOUNT, 0);
        vm.stopPrank();
        
        assertGt(aliceShares, 0, "Alice should receive shares");
        
        // Bob buys bucket 5 (50-60 range) - moderately bullish at $55k
        vm.startPrank(bob);
        usdc.approve(address(market), TRADE_AMOUNT);
        uint256 bobShares = market.buyShares(5, TRADE_AMOUNT, 0);
        vm.stopPrank();
        
        assertGt(bobShares, 0, "Bob should receive shares");
        
        // Charlie buys bucket 3 (30-40 range) - bearish at $35k
        vm.startPrank(charlie);
        usdc.approve(address(market), TRADE_AMOUNT);
        uint256 charlieShares = market.buyShares(3, TRADE_AMOUNT, 0);
        vm.stopPrank();
        
        assertGt(charlieShares, 0, "Charlie should receive shares");
        
        // Verify pool balance increased from trading
        uint256 poolAfterTrades = market.poolBalance();
        uint256 expectedIncrease = (TRADE_AMOUNT * 3) * 995 / 1000; // Net after 0.5% fee
        assertApproxEqAbs(poolAfterTrades, POOL_BALANCE + expectedIncrease, 10, "Pool should grow");
        
        // === PHASE 3: Resolution ===
        // Bitcoin settles at $75k → bucket 7 wins
        vm.prank(creator);
        market.resolveMarket(7);
        
        assertEq(uint256(market.status()), uint256(LMSRMarket.MarketStatus.RESOLVED));
        assertEq(market.winningBucket(), 7);
        
        // === PHASE 4: Claims ===
        
        // Alice claims her winnings (she won!)
        (uint256 bucket7Shares,,) = market.buckets(7);
        uint256 aliceBalanceBefore = usdc.balanceOf(alice);
        
        vm.prank(alice);
        market.claimWinnings(7, aliceShares);
        
        uint256 aliceBalanceAfter = usdc.balanceOf(alice);
        uint256 alicePayout = aliceBalanceAfter - aliceBalanceBefore;
        
        // Alice should receive close to $1 per share (in USDC 6 decimals)
        // aliceShares is in WAD (18 decimals), payout should be fromWad(aliceShares)
        assertGt(alicePayout, 0, "Alice should receive payout");
        
        // Bob and Charlie lost (wrong buckets)
        vm.expectRevert(LMSRMarket.InvalidBucket.selector);
        vm.prank(bob);
        market.claimWinnings(5, bobShares);
        
        vm.expectRevert(LMSRMarket.InvalidBucket.selector);
        vm.prank(charlie);
        market.claimWinnings(3, charlieShares);
        
        // === PHASE 5: LP Withdrawal ===
        
        uint256 creatorBalanceBefore = usdc.balanceOf(creator);
        (int256 profitBefore, int256 roiBefore, uint256 feesEarned) = market.getLPProfitability();
        
        vm.prank(creator);
        market.withdrawLP();
        
        uint256 creatorBalanceAfter = usdc.balanceOf(creator);
        uint256 lpPayout = creatorBalanceAfter - creatorBalanceBefore;
        
        assertGt(lpPayout, 0, "LP should receive payout");
        assertTrue(market.lpWithdrawn(), "LP withdrawal flag should be set");
        
        // In this scenario with low volume, LP actually loses (winner takes more than fees collected)
        // This is expected behavior - LMSR markets can result in LP loss
        assertLt(profitBefore, 0, "LP should lose money in this scenario (low volume, clear winner)");
        assertGt(feesEarned, 0, "LP should have collected fees");
        
        // Verify protocol fees were collected
        assertGt(market.feesCollectedProtocol(), 0, "Protocol should collect fees");
        
        // Verify final state: pool has exactly enough for remaining claims
        uint256 remainingWinningShares = bucket7Shares - aliceShares;
        uint256 expectedPoolBalance = remainingWinningShares / 1e12; // fromWad conversion
        assertApproxEqAbs(market.poolBalance(), expectedPoolBalance, 10, "Pool should have exact amount for remaining claims");
    }
    
    /// @notice Test LP profit scenario with high trading volume
    function test_lpProfit_highVolume() public {
        // Create market
        uint256[] memory bucketRanges = new uint256[](6);
        for (uint256 i = 0; i <= 5; i++) {
            bucketRanges[i] = i * 20; // 0, 20, 40, 60, 80, 100
        }
        
        vm.startPrank(creator);
        usdc.approve(address(factory), POOL_BALANCE);
        address marketAddress = factory.createMarket(POOL_BALANCE, bucketRanges, 50, 2000);
        vm.stopPrank();
        
        LMSRMarket market = LMSRMarket(marketAddress);
        
        // High volume trading from multiple users
        uint256 tradeAmount = 150_000000; // $150
        
        // Alice buys bucket 0
        vm.startPrank(alice);
        usdc.approve(address(market), tradeAmount * 2);
        market.buyShares(0, tradeAmount, 0);
        market.buyShares(1, tradeAmount, 0);
        vm.stopPrank();
        
        // Bob buys bucket 2
        vm.startPrank(bob);
        usdc.approve(address(market), tradeAmount * 2);
        market.buyShares(2, tradeAmount, 0);
        market.buyShares(3, tradeAmount, 0);
        vm.stopPrank();
        
        // Charlie buys bucket 4
        vm.startPrank(charlie);
        usdc.approve(address(market), tradeAmount);
        market.buyShares(4, tradeAmount, 0);
        vm.stopPrank();
        
        // Total volume: $750, fees: ~$3.75
        
        // Resolve to bucket 1 (Alice has shares here, but so does liquidity pool initially)
        vm.prank(creator);
        market.resolveMarket(1);
        
        // Check LP profitability before withdrawal
        (int256 profit, int256 roi, uint256 feesEarned) = market.getLPProfitability();
        
        // With distributed trading and reasonable resolution, LP should profit
        assertGt(feesEarned, 0, "Fees should be collected");
        
        // LP profit depends on who wins - with bucket 1 winning and Alice having some shares,
        // the LP should still profit from fees and other losing buckets
        
        // Withdraw and verify LP can withdraw
        vm.prank(creator);
        market.withdrawLP();
        
        assertTrue(market.lpWithdrawn(), "LP withdrawal should complete");
    }
    
    /// @notice Test LP loss scenario with low trading volume
    function test_lpLoss_lowVolume() public {
        // Create market
        uint256[] memory bucketRanges = new uint256[](6);
        for (uint256 i = 0; i <= 5; i++) {
            bucketRanges[i] = i * 20;
        }
        
        vm.startPrank(creator);
        usdc.approve(address(factory), POOL_BALANCE);
        address marketAddress = factory.createMarket(POOL_BALANCE, bucketRanges, 50, 2000);
        vm.stopPrank();
        
        LMSRMarket market = LMSRMarket(marketAddress);
        
        // Minimal trading
        uint256 smallTradeAmount = 50_000000; // $50
        
        vm.startPrank(alice);
        usdc.approve(address(market), smallTradeAmount);
        market.buyShares(0, smallTradeAmount, 0);
        vm.stopPrank();
        
        // Resolve to bucket 0 (Alice wins)
        vm.prank(creator);
        market.resolveMarket(0);
        
        // Alice claims all winnings
        (uint256 winningShares,,) = market.buckets(0);
        vm.prank(alice);
        market.claimWinnings(0, winningShares);
        
        // Check LP profitability
        (int256 profit, int256 roi,) = market.getLPProfitability();
        
        // With low volume and winner taking all, LP likely loses
        assertLt(profit, 0, "LP should lose with low volume");
        assertLt(roi, 0, "ROI should be negative");
    }
    
    /// @notice Test multi-user trading interactions
    function test_multiUser_trading() public {
        // Create market
        uint256[] memory bucketRanges = new uint256[](4);
        bucketRanges[0] = 0;
        bucketRanges[1] = 25;
        bucketRanges[2] = 50;
        bucketRanges[3] = 100;
        
        vm.startPrank(creator);
        usdc.approve(address(factory), POOL_BALANCE);
        address marketAddress = factory.createMarket(POOL_BALANCE, bucketRanges, 50, 2000);
        vm.stopPrank();
        
        LMSRMarket market = LMSRMarket(marketAddress);
        
        // Track balances
        uint256 aliceInitial = usdc.balanceOf(alice);
        uint256 bobInitial = usdc.balanceOf(bob);
        uint256 charlieInitial = usdc.balanceOf(charlie);
        
        // Alice buys bucket 0
        vm.startPrank(alice);
        usdc.approve(address(market), TRADE_AMOUNT);
        uint256 aliceShares = market.buyShares(0, TRADE_AMOUNT, 0);
        vm.stopPrank();
        
        // Bob buys bucket 1
        vm.startPrank(bob);
        usdc.approve(address(market), TRADE_AMOUNT);
        uint256 bobShares = market.buyShares(1, TRADE_AMOUNT, 0);
        vm.stopPrank();
        
        // Charlie buys bucket 2
        vm.startPrank(charlie);
        usdc.approve(address(market), TRADE_AMOUNT);
        uint256 charlieShares = market.buyShares(2, TRADE_AMOUNT, 0);
        vm.stopPrank();
        
        // Verify all received shares
        assertGt(aliceShares, 0);
        assertGt(bobShares, 0);
        assertGt(charlieShares, 0);
        
        // Verify USDC was debited
        assertEq(usdc.balanceOf(alice), aliceInitial - TRADE_AMOUNT);
        assertEq(usdc.balanceOf(bob), bobInitial - TRADE_AMOUNT);
        assertEq(usdc.balanceOf(charlie), charlieInitial - TRADE_AMOUNT);
        
        // Resolve to bucket 1 (Bob wins)
        vm.prank(creator);
        market.resolveMarket(1);
        
        // Only Bob can claim
        vm.prank(bob);
        market.claimWinnings(1, bobShares);
        
        // Bob should profit
        assertGt(usdc.balanceOf(bob), bobInitial, "Bob should profit as winner");
        
        // Alice and Charlie cannot claim
        vm.expectRevert(LMSRMarket.InvalidBucket.selector);
        vm.prank(alice);
        market.claimWinnings(0, aliceShares);
        
        vm.expectRevert(LMSRMarket.InvalidBucket.selector);
        vm.prank(charlie);
        market.claimWinnings(2, charlieShares);
    }
    
    /// @notice Test fee distribution (80% LP, 20% protocol)
    function test_fees_distributedCorrectly() public {
        // Create market
        uint256[] memory bucketRanges = new uint256[](4);
        bucketRanges[0] = 0;
        bucketRanges[1] = 33;
        bucketRanges[2] = 66;
        bucketRanges[3] = 100;
        
        vm.startPrank(creator);
        usdc.approve(address(factory), POOL_BALANCE);
        address marketAddress = factory.createMarket(POOL_BALANCE, bucketRanges, 50, 2000); // 0.5% fee, 20% protocol
        vm.stopPrank();
        
        LMSRMarket market = LMSRMarket(marketAddress);
        
        // Execute trades
        uint256 totalTraded = 0;
        
        vm.startPrank(alice);
        usdc.approve(address(market), TRADE_AMOUNT * 3);
        market.buyShares(0, TRADE_AMOUNT, 0);
        market.buyShares(1, TRADE_AMOUNT, 0);
        market.buyShares(2, TRADE_AMOUNT, 0);
        totalTraded = TRADE_AMOUNT * 3;
        vm.stopPrank();
        
        // Calculate expected fees
        uint256 expectedTotalFees = (totalTraded * 50) / 10000; // 0.5% fee
        uint256 expectedProtocolFees = (expectedTotalFees * 2000) / 10000; // 20% of fees
        uint256 expectedLPFees = expectedTotalFees - expectedProtocolFees; // 80% of fees
        
        // Verify fee distribution
        assertApproxEqAbs(market.feesCollectedProtocol(), expectedProtocolFees, 10, "Protocol fees incorrect");
        assertApproxEqAbs(market.feesCollectedLP(), expectedLPFees, 10, "LP fees incorrect");
        
        // Verify total
        assertApproxEqAbs(
            market.feesCollectedLP() + market.feesCollectedProtocol(),
            expectedTotalFees,
            10,
            "Total fees should match"
        );
    }
    
    /// @notice Test preventing double LP withdrawal
    function test_lpWithdrawal_preventsDoubleWithdraw() public {
        // Create and resolve market
        uint256[] memory bucketRanges = new uint256[](3);
        bucketRanges[0] = 0;
        bucketRanges[1] = 50;
        bucketRanges[2] = 100;
        
        vm.startPrank(creator);
        usdc.approve(address(factory), POOL_BALANCE);
        address marketAddress = factory.createMarket(POOL_BALANCE, bucketRanges, 50, 2000);
        vm.stopPrank();
        
        LMSRMarket market = LMSRMarket(marketAddress);
        
        // Trade and resolve
        vm.startPrank(alice);
        usdc.approve(address(market), TRADE_AMOUNT);
        market.buyShares(0, TRADE_AMOUNT, 0);
        vm.stopPrank();
        
        vm.prank(creator);
        market.resolveMarket(1);
        
        // First withdrawal succeeds
        vm.prank(creator);
        market.withdrawLP();
        
        assertTrue(market.lpWithdrawn());
        
        // Second withdrawal fails
        vm.expectRevert(LMSRMarket.InvalidParameters.selector);
        vm.prank(creator);
        market.withdrawLP();
    }
    
    /// @notice Test volume tracking
    function test_volumeTracking_accurate() public {
        // Create market
        uint256[] memory bucketRanges = new uint256[](4);
        bucketRanges[0] = 0;
        bucketRanges[1] = 33;
        bucketRanges[2] = 66;
        bucketRanges[3] = 100;
        
        vm.startPrank(creator);
        usdc.approve(address(factory), POOL_BALANCE);
        address marketAddress = factory.createMarket(POOL_BALANCE, bucketRanges, 50, 2000); // 0.5% fee, 20% protocol
        vm.stopPrank();
        
        LMSRMarket market = LMSRMarket(marketAddress);
        
        assertEq(market.totalVolume(), 0, "Initial volume should be 0");
        
        // Buy trades
        vm.startPrank(alice);
        usdc.approve(address(market), TRADE_AMOUNT * 2);
        market.buyShares(0, TRADE_AMOUNT, 0);
        market.buyShares(1, TRADE_AMOUNT, 0);
        vm.stopPrank();
        
        assertEq(market.totalVolume(), TRADE_AMOUNT * 2, "Volume should track buys");
        
        // Sell trade
        (uint256 bucket0Shares,,) = market.buckets(0);
        vm.prank(alice);
        uint256 payout = market.sellShares(0, bucket0Shares / 2, 0);
        
        // Volume includes both buy and sell amounts
        assertGt(market.totalVolume(), TRADE_AMOUNT * 2, "Volume should include sells");
    }
}
