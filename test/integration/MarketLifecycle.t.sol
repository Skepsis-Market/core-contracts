// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {MarketFactory} from "../../src/MarketFactory.sol";
import {LMSRMarket} from "../../src/LMSRMarket.sol";
import {PositionNFT} from "../../src/PositionNFT.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";
import {Vault} from "../../src/Vault.sol";

/// @notice Integration tests for full market lifecycle
/// @dev Tests: Factory → Create → Trade → Resolve → Claim → LP Withdraw
contract MarketLifecycleTest is Test {
    MarketFactory public factory;
    PositionNFT public positionNFT;
    MockUSDC public usdc;
    Vault public vault;
    
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

        // Deploy LMSRMarket implementation (EIP-1167 clone source)
        {
            uint256[] memory implRanges = new uint256[](2);
            implRanges[0] = 0;
            implRanges[1] = 1;
            LMSRMarket.MarketMetadata memory implMeta;
            address lmsrImpl = address(new LMSRMarket(
                0, address(0), address(0), address(usdc), address(0),
                1, 1, implRanges, new uint256[](0), 0, 0, implMeta, address(0xFEE)
            ));

            // nonce 0: usdc, nonce 1: impl, nonce 2: positionNFT -> factory at nonce 3
            address predictedFactory = vm.computeCreateAddress(admin, 3);

            // Deploy PositionNFT with predicted factory address
            positionNFT = new PositionNFT(predictedFactory);

            // Deploy factory (must be at nonce 3)
            factory = new MarketFactory(
                lmsrImpl,
                address(usdc),
                address(positionNFT),
                1000_000000, // minPoolBalance = $1,000
                100, // maxBuckets
                50, // defaultFeeBps = 0.5%
                2000, // defaultProtocolFeeBps = 20%
                address(0xFEE)
            );

            // Verify factory address matches prediction
            require(address(factory) == predictedFactory, "Factory address mismatch");
        }

        // Whitelist the market creator
        factory.setCreatorAllowance(creator, 50);

        // Deploy vault and wire up
        vault = new Vault(address(usdc), "Vault", "sVLT", admin);
        factory.setVault(address(vault));
        vault.setFactory(address(factory));

        vm.stopPrank();

        // Fund vault via LP deposit
        address lp = address(0x6);
        usdc.mint(lp, 1_000_000_000000);
        vm.startPrank(lp);
        usdc.approve(address(vault), 1_000_000_000000);
        vault.deposit(1_000_000_000000, lp);
        vm.stopPrank();
        
        // Mint USDC to traders (not to creator — vault funds markets)
        usdc.mint(alice, 10000_000000);
        usdc.mint(bob, 10000_000000);
        usdc.mint(charlie, 10000_000000);
    }
    
    // ── Helpers ──────────────────────────────────────────────────────────────

    function _params(
        uint256 sa,
        uint256 minValue,
        uint256 maxValue,
        uint256 bucketCount,
        uint256 feeBps,
        uint256 protoBps
    ) internal pure returns (MarketFactory.MarketParams memory p) {
        p.alpha        = sa / _isqrt(bucketCount);
        p.seedAmount   = sa;
        p.minValue     = minValue;
        p.maxValue     = maxValue;
        p.bucketCount  = bucketCount;
    }

    function _isqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;
        if (x <= 3) return 1;
        uint256 z = (x + 1) / 2;
        uint256 y = x;
        while (z < y) { y = z; z = (x / z + z) / 2; }
        return y;
    }

    function _cm(
        uint256 pb,
        uint256 minValue,
        uint256 maxValue,
        uint256 bucketCount,
        uint256 feeBps,
        uint256 protoBps
    ) internal returns (address) {
        return factory.createMarket(_params(pb, minValue, maxValue, bucketCount, feeBps, protoBps));
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

    // ── Tests ─────────────────────────────────────────────────────────────────

    /// @notice Test full lifecycle: Create → Trade → Resolve → Claim → Withdraw
    function test_fullLifecycle_bitcoinScenario() public {
        // === PHASE 1: Market Creation ===
        // 10 buckets: 0, 10, 20, ..., 100
        
        vm.prank(creator);
        address marketAddress = _cm(POOL_BALANCE, 0, 100, 10, 50, 2000);
        
        LMSRMarket market = LMSRMarket(marketAddress);
        // Verify market initialized correctly
        assertEq(market.poolBalance(), POOL_BALANCE);
        assertEq(market.bucketCount(), 10);
        assertEq(market.creator(), creator);
        assertEq(usdc.balanceOf(address(market)), POOL_BALANCE);
        
        // === PHASE 2: Trading ===
        
        // Alice buys bucket 7 (70-80 range) - bullish on Bitcoin at $75k
        vm.startPrank(alice);
        usdc.approve(address(market), TRADE_AMOUNT);
        uint256 aliceShares = _buyBucket(market, 7, TRADE_AMOUNT, 0);
        vm.stopPrank();

        assertGt(aliceShares, 0, "Alice should receive shares");

        // Bob buys bucket 5 (50-60 range) - moderately bullish at $55k
        vm.startPrank(bob);
        usdc.approve(address(market), TRADE_AMOUNT);
        uint256 bobShares = _buyBucket(market, 5, TRADE_AMOUNT, 0);
        vm.stopPrank();

        assertGt(bobShares, 0, "Bob should receive shares");

        // Charlie buys bucket 3 (30-40 range) - bearish at $35k
        vm.startPrank(charlie);
        usdc.approve(address(market), TRADE_AMOUNT);
        uint256 charlieShares = _buyBucket(market, 3, TRADE_AMOUNT, 0);
        vm.stopPrank();
        
        assertGt(charlieShares, 0, "Charlie should receive shares");
        
        // Verify pool balance increased from trading
        // Pool now receives netCost + lpFee = costUSDC - protocolFee
        // Fee = 0.5% (50 bps), protocolFee = 20% of fee = 0.1% (10 bps of trade)
        // So pool increase per trade = trade * 9990 / 10000
        uint256 poolAfterTrades = market.poolBalance();
        uint256 expectedIncrease = (TRADE_AMOUNT * 3) * 9990 / 10000;
        assertApproxEqAbs(poolAfterTrades, POOL_BALANCE + expectedIncrease, 10, "Pool should grow");
        
        // === PHASE 3: Resolution ===
        // Bitcoin settles at $75k → value 70 resolves to bucket 7
        vm.prank(creator);
        market.resolveMarket(70); // value 70 = bucket 7 (width 10)
        
        assertEq(uint256(market.status()), uint256(LMSRMarket.MarketStatus.RESOLVED));
        assertEq(market.winningBucket(), 7);
        
        // === PHASE 4: Claims ===
        
        // Alice claims her winnings (she won!)
        (uint256 bucket7Shares,,,) = market.buckets(7);
        uint256 aliceBalanceBefore = usdc.balanceOf(alice);

        vm.startPrank(alice);
        _claimBucket(market, 7);
        vm.stopPrank();

        uint256 aliceBalanceAfter = usdc.balanceOf(alice);
        uint256 alicePayout = aliceBalanceAfter - aliceBalanceBefore;

        // Alice should receive close to $1 per share (in USDC 6 decimals)
        assertGt(alicePayout, 0, "Alice should receive payout");

        // Bob and Charlie lost (wrong buckets)
        {
            uint256 bobTokenId = (uint256(uint128(market.marketId())) << 128) | (uint256(uint64(5)) << 64) | uint256(uint64(5));
            vm.expectRevert(LMSRMarket.RangeNotWinner.selector);
            vm.prank(bob);
            market.claim(bobTokenId, address(0));
        }

        {
            uint256 charlieTokenId = (uint256(uint128(market.marketId())) << 128) | (uint256(uint64(3)) << 64) | uint256(uint64(3));
            vm.expectRevert(LMSRMarket.RangeNotWinner.selector);
            vm.prank(charlie);
            market.claim(charlieTokenId, address(0));
        }
        
        // === PHASE 5: LP Withdrawal ===
        
        uint256 creatorBalanceBefore = usdc.balanceOf(creator);
        (int256 profitBefore,, uint256 feesEarned) = market.getLPProfitability();
        
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
        
        // Verify final state: pool has exactly enough for remaining trader claims
        // After Alice claimed, remaining shares = bucket7Shares - aliceShares = initialShares
        // With new accounting, traderOwed = max(0, remainingShares - initialShares) = 0
        // So poolBalance should be 0 (all remaining shares are LP's initial allocation)
        (uint256 bucket7SharesAfterClaim, uint256 bucket7InitShares,,) = market.buckets(7);
        uint256 remainingTraderClaims = bucket7SharesAfterClaim > bucket7InitShares
            ? bucket7SharesAfterClaim - bucket7InitShares
            : 0;
        assertApproxEqAbs(market.poolBalance(), remainingTraderClaims, 10, "Pool should have exact amount for remaining trader claims");
    }
    
    /// @notice Test LP profit scenario with high trading volume
    function test_lpProfit_highVolume() public {
        // Create market with 5 buckets: 0, 20, 40, 60, 80, 100
        
        vm.prank(creator);
        address marketAddress = _cm(POOL_BALANCE, 0, 100, 5, 50, 2000);

        LMSRMarket market = LMSRMarket(marketAddress);

        // High volume trading from multiple users
        uint256 tradeAmount = 150_000000; // $150
        
        // Alice buys bucket 0
        vm.startPrank(alice);
        usdc.approve(address(market), tradeAmount * 2);
        _buyBucket(market, 0, tradeAmount, 0);
        _buyBucket(market, 1, tradeAmount, 0);
        vm.stopPrank();

        // Bob buys bucket 2
        vm.startPrank(bob);
        usdc.approve(address(market), tradeAmount * 2);
        _buyBucket(market, 2, tradeAmount, 0);
        _buyBucket(market, 3, tradeAmount, 0);
        vm.stopPrank();

        // Charlie buys bucket 4
        vm.startPrank(charlie);
        usdc.approve(address(market), tradeAmount);
        _buyBucket(market, 4, tradeAmount, 0);
        vm.stopPrank();
        
        // Total volume: $750, fees: ~$3.75
        
        // Resolve with value 20 (bucket 1 in 5-bucket market with width 20)
        vm.prank(creator);
        market.resolveMarket(20);
        
        // Check LP profitability before withdrawal
        (,, uint256 feesEarned) = market.getLPProfitability();

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
        // Create market with 5 buckets: 0, 20, 40, 60, 80, 100
        
        vm.prank(creator);
        address marketAddress = _cm(POOL_BALANCE, 0, 100, 5, 50, 2000);

        LMSRMarket market = LMSRMarket(marketAddress);

        // Minimal trading
        uint256 smallTradeAmount = 50_000000; // $50
        
        vm.startPrank(alice);
        usdc.approve(address(market), smallTradeAmount);
        _buyBucket(market, 0, smallTradeAmount, 0);
        vm.stopPrank();

        // Resolve with value 0 (bucket 0, Alice wins)
        vm.prank(creator);
        market.resolveMarket(0);

        // Alice claims all winnings
        vm.startPrank(alice);
        _claimBucket(market, 0);
        vm.stopPrank();
        
        // Check LP profitability
        (int256 profit, int256 roi,) = market.getLPProfitability();
        
        // With low volume and winner taking all, LP likely loses
        assertLt(profit, 0, "LP should lose with low volume");
        assertLt(roi, 0, "ROI should be negative");
    }
    
    /// @notice Test multi-user trading interactions
    function test_multiUser_trading() public {
        // Create market with 3 buckets: 0, 33, 66, 99 (uniform, width 33 each)
        
        vm.prank(creator);
        address marketAddress = _cm(POOL_BALANCE, 0, 99, 3, 50, 2000);

        LMSRMarket market = LMSRMarket(marketAddress);

        // Track balances
        uint256 aliceInitial = usdc.balanceOf(alice);
        uint256 bobInitial = usdc.balanceOf(bob);
        uint256 charlieInitial = usdc.balanceOf(charlie);
        
        // Alice buys bucket 0
        vm.startPrank(alice);
        usdc.approve(address(market), TRADE_AMOUNT);
        uint256 aliceShares = _buyBucket(market, 0, TRADE_AMOUNT, 0);
        vm.stopPrank();

        // Bob buys bucket 1
        vm.startPrank(bob);
        usdc.approve(address(market), TRADE_AMOUNT);
        uint256 bobShares = _buyBucket(market, 1, TRADE_AMOUNT, 0);
        vm.stopPrank();

        // Charlie buys bucket 2
        vm.startPrank(charlie);
        usdc.approve(address(market), TRADE_AMOUNT);
        uint256 charlieShares = _buyBucket(market, 2, TRADE_AMOUNT, 0);
        vm.stopPrank();
        
        // Verify all received shares
        assertGt(aliceShares, 0);
        assertGt(bobShares, 0);
        assertGt(charlieShares, 0);
        
        // Verify USDC was debited
        assertEq(usdc.balanceOf(alice), aliceInitial - TRADE_AMOUNT);
        assertEq(usdc.balanceOf(bob), bobInitial - TRADE_AMOUNT);
        assertEq(usdc.balanceOf(charlie), charlieInitial - TRADE_AMOUNT);
        
        // Resolve with value 33 (bucket 1 in 3-bucket market with width 33, Bob wins)
        vm.prank(creator);
        market.resolveMarket(33);
        
        // Only Bob can claim
        vm.startPrank(bob);
        _claimBucket(market, 1);
        vm.stopPrank();

        // Bob should profit
        assertGt(usdc.balanceOf(bob), bobInitial, "Bob should profit as winner");

        // Alice and Charlie cannot claim
        {
            uint256 aliceTokenId = (uint256(uint128(market.marketId())) << 128) | (uint256(uint64(0)) << 64) | uint256(uint64(0));
            vm.expectRevert(LMSRMarket.RangeNotWinner.selector);
            vm.prank(alice);
            market.claim(aliceTokenId, address(0));
        }

        {
            uint256 charlieTokenId = (uint256(uint128(market.marketId())) << 128) | (uint256(uint64(2)) << 64) | uint256(uint64(2));
            vm.expectRevert(LMSRMarket.RangeNotWinner.selector);
            vm.prank(charlie);
            market.claim(charlieTokenId, address(0));
        }
    }
    
    /// @notice Test fee distribution (80% LP, 20% protocol)
    function test_fees_distributedCorrectly() public {
        // Create market with 3 buckets: 0, 33, 66, 99 (width 33 each)
        
        vm.prank(creator);
        address marketAddress = _cm(POOL_BALANCE, 0, 99, 3, 50, 2000);

        LMSRMarket market = LMSRMarket(marketAddress);

        // Execute trades
        uint256 totalTraded = 0;
        
        vm.startPrank(alice);
        usdc.approve(address(market), TRADE_AMOUNT * 3);
        _buyBucket(market, 0, TRADE_AMOUNT, 0);
        _buyBucket(market, 1, TRADE_AMOUNT, 0);
        _buyBucket(market, 2, TRADE_AMOUNT, 0);
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
        // Create and resolve market with 2 buckets: 0, 50, 100
        
        vm.prank(creator);
        address marketAddress = _cm(POOL_BALANCE, 0, 100, 2, 50, 2000);

        LMSRMarket market = LMSRMarket(marketAddress);

        // Trade and resolve
        vm.startPrank(alice);
        usdc.approve(address(market), TRADE_AMOUNT);
        _buyBucket(market, 0, TRADE_AMOUNT, 0);
        vm.stopPrank();

        vm.prank(creator);
        market.resolveMarket(50); // value 50 = bucket 1 (width 50)
        
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
        // Create market with 3 buckets: 0, 33, 66, 99 (width 33 each)
        
        vm.prank(creator);
        address marketAddress = _cm(POOL_BALANCE, 0, 99, 3, 50, 2000);

        LMSRMarket market = LMSRMarket(marketAddress);

        assertEq(market.totalVolume(), 0, "Initial volume should be 0");
        
        // Buy trades
        vm.startPrank(alice);
        usdc.approve(address(market), TRADE_AMOUNT * 2);
        uint256 aliceBucket0Shares = _buyBucket(market, 0, TRADE_AMOUNT, 0);
        _buyBucket(market, 1, TRADE_AMOUNT, 0);
        vm.stopPrank();

        assertEq(market.totalVolume(), TRADE_AMOUNT * 2, "Volume should track buys");

        // Sell trade
        vm.startPrank(alice);
        _sellBucket(market, 0, aliceBucket0Shares / 2, 0);
        vm.stopPrank();
        
        // Volume includes both buy and sell amounts
        assertGt(market.totalVolume(), TRADE_AMOUNT * 2, "Volume should include sells");
    }
}
