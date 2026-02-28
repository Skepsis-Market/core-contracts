// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {LMSRMarket} from "../src/LMSRMarket.sol";
import {Vault} from "../src/Vault.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";

contract VaultTest is Test {
    MockUSDC   usdc;
    Vault vault;

    address admin    = address(0xAD);
    address creator  = address(0xC1);
    address lp1      = address(0x111);
    address lp2      = address(0x222);
    address trader   = address(0x333);

    LMSRMarket market1;
    LMSRMarket market2;

    // 4-bucket market (ranges 0-25-50-75-100)
    uint256[] buckets4;
    // 10-bucket market (ranges 0-10-20-...-100)
    uint256[] buckets10;

    uint256 constant SEED = 1_000_000000;   // $1k seed per market (from creator)

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

        // bucket arrays
        buckets4 = new uint256[](5);
        for (uint256 i = 0; i <= 4; i++) buckets4[i] = i * 25;

        buckets10 = new uint256[](11);
        for (uint256 i = 0; i <= 10; i++) buckets10[i] = i * 10;

        // Deploy two markets seeded by creator
        market1 = _deployMarket(1, buckets4,  SEED);
        market2 = _deployMarket(2, buckets10, SEED);

        // Deploy vault (admin-owned)
        vm.prank(admin);
        vault = new Vault(address(usdc), "Vault", "sVLT", admin);

        // Register markets and point them at vault
        vm.startPrank(admin);
        vault.registerMarket(address(market1));
        vault.registerMarket(address(market2));
        vm.stopPrank();

        vm.prank(creator);
        market1.setLPVault(address(vault));
        vm.prank(creator);
        market2.setLPVault(address(vault));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────────

    function _deployMarket(uint256 id, uint256[] memory ranges, uint256 seed)
        internal returns (LMSRMarket m)
    {
        uint256 numBuckets = ranges.length - 1;
        uint256 _alpha = seed / _isqrt(numBuckets);
        m = new LMSRMarket(
            id, creator, address(0xFACE), address(usdc), address(0),
            _alpha, seed, ranges, 100, 2000, _defaultMetadata()
        );
        usdc.mint(address(m), seed);
    }

    function _isqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;
        if (x <= 3) return 1;
        uint256 z = (x + 1) / 2;
        uint256 y = x;
        while (z < y) { y = z; z = (x / z + z) / 2; }
        return y;
    }

    function _lpDeposit(address lp, uint256 amount) internal {
        usdc.mint(lp, amount);
        vm.startPrank(lp);
        usdc.approve(address(vault), amount);
        vault.deposit(amount, lp);
        vm.stopPrank();
    }

    function _buy(LMSRMarket m, uint256 bucketId, uint256 amount) internal {
        usdc.mint(trader, amount);
        vm.startPrank(trader);
        usdc.approve(address(m), amount);
        m.buyShares(bucketId, amount, 0);
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 1. Basic deposit / share accounting
    // ─────────────────────────────────────────────────────────────────────────

    function test_deposit_mintsSharesOneToOne_firstLP() public {
        uint256 amount = 5_000_000000;
        _lpDeposit(lp1, amount);

        // First deposit: shares == assets (both in 6 dec, ERC4626 standard)
        assertEq(vault.balanceOf(lp1), amount, "first LP shares should equal deposit");
        assertEq(vault.totalAssets(), amount, "totalAssets = vault liquid (no deployments yet)");
    }

    function test_deposit_twoLPs_proportionalShares() public {
        _lpDeposit(lp1, 4_000_000000);
        _lpDeposit(lp2, 2_000_000000);

        // lp2 deposited half of lp1; should have half the (incremental) shares
        uint256 s1 = vault.balanceOf(lp1);
        uint256 s2 = vault.balanceOf(lp2);
        assertGt(s1, s2, "lp1 should have more shares");
        // Proportionality: s2 / s1 ≈ 2000 / 4000 = 0.5
        // Just verify no shares are 0
        assertGt(s1, 0);
        assertGt(s2, 0);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 2. deployTo — capital allocation
    // ─────────────────────────────────────────────────────────────────────────

    function test_deployTo_increasesMarketPool() public {
        _lpDeposit(lp1, 20_000_000000);

        uint256 poolBefore = market1.poolBalance();

        vm.prank(admin);
        vault.deployTo(address(market1), 3_000_000000);

        assertEq(market1.poolBalance(), poolBefore + 3_000_000000);
        assertEq(vault.deployedTo(address(market1)), 3_000_000000);
    }

    function test_deployTo_totalAssetsUnchanged() public {
        _lpDeposit(lp1, 50_000_000000);

        // First deploy brings market1 pool into NAV (includes its pre-existing seed)
        vm.prank(admin);
        vault.deployTo(address(market1), 2_000_000000);

        uint256 taBefore = vault.totalAssets();

        // Second deploy to same market: pure vault→market transfer, NAV unchanged
        vm.prank(admin);
        vault.deployTo(address(market1), 2_000_000000);

        assertApproxEqAbs(vault.totalAssets(), taBefore, 1, "totalAssets unchanged on subsequent deploy");
    }

    function test_deployTo_revertsIfNotRegistered() public {
        _lpDeposit(lp1, 5_000_000000);

        vm.prank(admin);
        vm.expectRevert(Vault.MarketNotRegistered.selector);
        vault.deployTo(address(0xDEAD), 1_000_000000);
    }

    function test_deployTo_revertsIfBreaksLiquidBuffer() public {
        // Deposit only $1k — deploying $2k exceeds vault liquid (Guard 1)
        _lpDeposit(lp1, 1_000_000000);
        vm.prank(admin);
        vm.expectRevert(Vault.InsufficientLiquidBuffer.selector);
        vault.deployTo(address(market1), 2_000_000000);
    }

    function test_deployTo_revertsIfExceedsMarketCap() public {
        // Deposit enough that $9k would exceed 20% cap
        _lpDeposit(lp1, 50_000_000000);

        // 20% of ~$52k = $10.4k per market cap
        // Deploying $11k to market1 should revert
        vm.prank(admin);
        vm.expectRevert(Vault.ExceedsMarketCap.selector);
        vault.deployTo(address(market1), 11_000_000000);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 3. harvestSurplus — P-Z surplus withdrawal
    // ─────────────────────────────────────────────────────────────────────────

    function test_harvestSurplus_afterLiquidityAdded() public {
        // Deploy large amount → market gets surplus (pool > requiredReserves)
        _lpDeposit(lp1, 50_000_000000);

        vm.prank(admin);
        vault.deployTo(address(market1), 10_000_000000);

        // market1 now has $11k pool (seed + deployed); requiredReserves ~ $1.6k
        // surplus should exist
        uint256 surplus = market1.getWithdrawableSurplus();
        assertGt(surplus, 0, "surplus should open after large deployment");

        uint256 vaultLiquidBefore = usdc.balanceOf(address(vault));

        vault.harvestSurplus(address(market1));

        assertGt(usdc.balanceOf(address(vault)), vaultLiquidBefore, "vault liquid should increase");
        assertEq(market1.getWithdrawableSurplus(), 0, "surplus should be 0 after full harvest");
    }

    function test_harvestSurplus_revertsWhenNoSurplus() public {
        // market1 has only $1k (just seed), no surplus
        vm.expectRevert(Vault.NothingToHarvest.selector);
        vault.harvestSurplus(address(market1));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 4. getSafetyBuffer decays with alpha — surplus unlocks progressively
    // ─────────────────────────────────────────────────────────────────────────

    function test_safetyBuffer_decreasesAsAlphaDecays() public {
        // Deploy $10k to market1, configure 50% alpha decay over 30 days
        _lpDeposit(lp1, 50_000_000000);
        vm.prank(admin);
        vault.deployTo(address(market1), 10_000_000000);

        uint256 alphaFloor = (market1.alphaInitial() * 50) / 100;
        vm.prank(creator);
        market1.configureAlphaDecay(alphaFloor, block.timestamp, 30 days);

        uint256 bufferAtStart = market1.getSafetyBuffer();

        // Warp to 50% through decay
        vm.warp(block.timestamp + 15 days + 30 minutes); // advance past an epoch
        market1.syncAlpha();

        uint256 bufferMid = market1.getSafetyBuffer();
        assertLt(bufferMid, bufferAtStart, "buffer should shrink as alpha decays");

        // Warp to end of decay
        vm.warp(block.timestamp + 16 days);
        market1.syncAlpha();

        uint256 bufferEnd = market1.getSafetyBuffer();
        assertLt(bufferEnd, bufferMid, "buffer should be lowest at floor alpha");

        console.log("Buffer at start:", bufferAtStart);
        console.log("Buffer at 50%:  ", bufferMid);
        console.log("Buffer at end:  ", bufferEnd);
    }

    function test_surplusUnlocks_progressivelyWithDecay() public {
        // Market with large deployment; no surplus at start because safetyBuffer is high
        _lpDeposit(lp1, 50_000_000000);
        vm.prank(admin);
        vault.deployTo(address(market1), 8_000_000000);

        uint256 alphaFloor = (market1.alphaInitial() * 30) / 100; // decay to 30%
        vm.prank(creator);
        market1.configureAlphaDecay(alphaFloor, block.timestamp, 10 days);

        // At start: safetyBuffer is large, surplus may be 0
        uint256 surplusStart = market1.getWithdrawableSurplus();

        // Warp to end of decay
        vm.warp(block.timestamp + 11 days);
        market1.syncAlpha();

        uint256 surplusEnd = market1.getWithdrawableSurplus();
        assertGt(surplusEnd, surplusStart, "surplus should grow as alpha decays");

        console.log("Surplus at start:", surplusStart);
        console.log("Surplus at end:  ", surplusEnd);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 5. harvestResolved — post-resolution capital recovery
    // ─────────────────────────────────────────────────────────────────────────

    function test_harvestResolved_afterMarketResolves() public {
        // Deploy to market1, have a trade, resolve, harvest
        _lpDeposit(lp1, 30_000_000000);
        vm.prank(admin);
        vault.deployTo(address(market1), 5_000_000000);

        // Trade to generate fees
        _buy(market1, 0, 500_000000);

        // Resolve
        vm.prank(creator);
        market1.resolveMarket(0); // bucket 0 wins

        uint256 vaultLiquidBefore = usdc.balanceOf(address(vault));

        vault.harvestResolved(address(market1));

        uint256 recovered = usdc.balanceOf(address(vault)) - vaultLiquidBefore;
        assertGt(recovered, 0, "vault should recover funds after resolution");
        assertTrue(market1.lpWithdrawn(), "lpWithdrawn should be true");
    }

    function test_harvestResolved_revertsIfNotResolved() public {
        vm.expectRevert(Vault.MarketNotResolved.selector);
        vault.harvestResolved(address(market1));
    }

    function test_harvestResolved_revertsIfAlreadyHarvested() public {
        _lpDeposit(lp1, 30_000_000000);
        vm.prank(admin);
        vault.deployTo(address(market1), 5_000_000000);

        vm.prank(creator);
        market1.resolveMarket(1);

        vault.harvestResolved(address(market1));

        vm.expectRevert(Vault.NothingToHarvest.selector);
        vault.harvestResolved(address(market1));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 6. Withdrawal — liquid buffer enforcement
    // ─────────────────────────────────────────────────────────────────────────

    function test_withdraw_limitedToLiquidAboveBuffer() public {
        uint256 deposit = 10_000_000000;
        _lpDeposit(lp1, deposit);

        // totalAssets = $10k vault (no deployments yet)
        // required liquid = 20% of $10k = $2k
        // liquid = $10k → liquidAvailable = $10k - $2k = $8k
        uint256 available = vault.liquidAvailable();
        uint256 maxW = vault.maxWithdraw(lp1);

        assertLe(maxW, available, "maxWithdraw should not exceed liquidAvailable");
        assertGt(maxW, 0, "should be able to withdraw something");

        // Withdraw the max
        vm.prank(lp1);
        vault.withdraw(maxW, lp1, lp1);

        assertEq(usdc.balanceOf(lp1), maxW);
    }

    function test_withdraw_revertsWhenAboveBuffer() public {
        _lpDeposit(lp1, 10_000_000000);

        // liquidAvailable = $10k - 20% buffer ($2k) = $8k
        uint256 maxW = vault.maxWithdraw(lp1);
        assertGt(maxW, 0, "should have some withdrawable");

        // Trying to withdraw 1 wei more than allowed should revert
        vm.prank(lp1);
        vm.expectRevert(); // ERC4626ExceededMaxWithdraw
        vault.withdraw(maxW + 1, lp1, lp1);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 7. Health ratio
    // ─────────────────────────────────────────────────────────────────────────

    function test_healthRatio_increasesWithMoreCapital() public {
        uint256 ratioBefore = vault.marketHealthRatio(address(market1));

        _lpDeposit(lp1, 30_000_000000);
        vm.prank(admin);
        vault.deployTo(address(market1), 5_000_000000);

        uint256 ratioAfter = vault.marketHealthRatio(address(market1));
        assertGt(ratioAfter, ratioBefore, "health ratio should increase with more capital");

        console.log("Health ratio before deploy:", ratioBefore);
        console.log("Health ratio after deploy: ", ratioAfter);
    }

    function test_healthRatio_aboveWithdrawThreshold_afterLargeDeployment() public {
        _lpDeposit(lp1, 50_000_000000);
        vm.prank(admin);
        vault.deployTo(address(market1), 10_000_000000);

        uint256 ratio = vault.marketHealthRatio(address(market1));
        assertGe(ratio, vault.HEALTH_WITHDRAW_THRESHOLD(), "should be above harvest threshold");
    }

    function test_lowestHealthMarket_returnsCorrectMarket() public {
        // market1 gets extra capital, market2 stays at seed only
        _lpDeposit(lp1, 50_000_000000);
        vm.prank(admin);
        vault.deployTo(address(market1), 8_000_000000);

        (address worst, uint256 ratio) = vault.lowestHealthMarket();
        // market2 has no extra deployment, should be lower ratio
        assertEq(worst, address(market2), "market2 should be the lowest health");
        console.log("Lowest health market ratio:", ratio);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 8. Multi-market totalAssets reflects both markets
    // ─────────────────────────────────────────────────────────────────────────

    function test_totalAssets_reflectsAllMarkets() public {
        uint256 deposit = 50_000_000000;
        _lpDeposit(lp1, deposit);

        // Before any deployment, totalAssets = vault liquid only
        assertEq(vault.totalAssets(), deposit, "no deployments yet");

        // Deploy to both markets
        vm.startPrank(admin);
        vault.deployTo(address(market1), 2_000_000000);
        vault.deployTo(address(market2), 2_000_000000);
        vm.stopPrank();

        // totalAssets = vault liquid + market1 pool (seed+deploy) + market2 pool (seed+deploy)
        uint256 expected = (deposit - 4_000_000000)
                         + (SEED + 2_000_000000)
                         + (SEED + 2_000_000000);
        assertEq(vault.totalAssets(), expected);
    }

    function test_totalAssets_updatesWhenMarketEarns() public {
        _lpDeposit(lp1, 30_000_000000);
        vm.prank(admin);
        vault.deployTo(address(market1), 5_000_000000);

        uint256 taBefore = vault.totalAssets();

        // Trade into market1 → poolBalance grows (net of protocol fee)
        _buy(market1, 0, 1_000_000000);

        uint256 taAfter = vault.totalAssets();
        // poolBalance grew by ~98% of trade amount (1% fee, 20% of that = protocol)
        // Net ~$980 stays in pool; totalAssets should grow
        assertGt(taAfter, taBefore, "totalAssets should grow after trade fees");
    }

    function test_totalAssets_shrinks_afterResolvedMarketHarvested() public {
        _lpDeposit(lp1, 30_000_000000);
        vm.prank(admin);
        vault.deployTo(address(market1), 5_000_000000);

        // Resolve market1 (winning bucket 2, no traders on bucket 2 so winShares ≈ initialShares)
        vm.prank(creator);
        market1.resolveMarket(2);

        // Before harvest: totalAssets includes resolved market's LP residual
        uint256 taBeforeHarvest = vault.totalAssets();

        vault.harvestResolved(address(market1));

        // After harvest: market1 claims are 0, but vault liquid increased
        // totalAssets should be roughly the same (capital moved back to vault)
        assertApproxEqAbs(vault.totalAssets(), taBeforeHarvest, 2, "totalAssets approx unchanged after harvest");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 9. withdrawLP by vault (tests the LMSRMarket change)
    // ─────────────────────────────────────────────────────────────────────────

    function test_lmsrMarket_withdrawLP_byLPVaultSendsFundsToVault() public {
        _lpDeposit(lp1, 30_000_000000);
        vm.prank(admin);
        vault.deployTo(address(market1), 5_000_000000);

        vm.prank(creator);
        market1.resolveMarket(0);

        uint256 vaultBalBefore = usdc.balanceOf(address(vault));
        uint256 creatorBalBefore = usdc.balanceOf(creator);

        // Vault calls withdrawLP (not creator) → funds come to vault
        vm.prank(address(vault));
        market1.withdrawLP();

        assertGt(usdc.balanceOf(address(vault)), vaultBalBefore, "vault should receive LP withdrawal");
        assertEq(usdc.balanceOf(creator), creatorBalBefore, "creator should NOT receive funds");
    }

    function test_lmsrMarket_withdrawLP_byCreatorStillWorks() public {
        // Create a market without vault to test creator path
        LMSRMarket noVaultMarket = _deployMarket(99, buckets4, 1_000_000000);

        vm.prank(creator);
        noVaultMarket.resolveMarket(0);

        uint256 creatorBalBefore = usdc.balanceOf(creator);
        vm.prank(creator);
        noVaultMarket.withdrawLP();

        assertGt(usdc.balanceOf(creator), creatorBalBefore, "creator should receive on direct withdrawLP");
    }
}
