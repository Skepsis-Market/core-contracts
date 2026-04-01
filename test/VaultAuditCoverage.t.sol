// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {LMSRMarket} from "../src/LMSRMarket.sol";
import {Vault} from "../src/Vault.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";

/// @notice Audit coverage tests for Vault — deposit gate, pausable, NAV accounting
contract VaultAuditCoverageTest is Test {
    MockUSDC usdc;
    Vault vault;
    LMSRMarket market;

    address admin = address(0xAD);
    address creator = address(0xC0);
    address lp1 = address(0x111);
    address lp2 = address(0x222);
    address randomUser = address(0x999);

    uint256 constant SEED = 5_000_000000; // 5K USDC

    function setUp() public {
        usdc = new MockUSDC();

        market = _deployMarket(1, 4, 25, SEED);

        vm.startPrank(admin);
        vault = new Vault(address(usdc), "Vault", "sVLT", admin);
        vault.setDepositsEnabled(true);
        vault.registerMarket(address(market));
        vm.stopPrank();

        vm.prank(creator);
        market.setLPVault(address(vault));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 1. Deposit Gate Tests
    // ─────────────────────────────────────────────────────────────────────────

    function test_depositGate_blocksWhenDisabled() public {
        vm.prank(admin);
        vault.setDepositsEnabled(false);

        usdc.mint(randomUser, 1000_000000);
        vm.startPrank(randomUser);
        usdc.approve(address(vault), 1000_000000);
        // maxDeposit returns 0, so OZ ERC4626 reverts with ERC4626ExceededMaxDeposit
        vm.expectRevert();
        vault.deposit(1000_000000, randomUser);
        vm.stopPrank();
    }

    function test_depositGate_ownerCanDepositWhenDisabled() public {
        vm.prank(admin);
        vault.setDepositsEnabled(false);

        usdc.mint(admin, 1000_000000);
        vm.startPrank(admin);
        usdc.approve(address(vault), 1000_000000);
        vault.deposit(1000_000000, admin);
        vm.stopPrank();

        assertEq(vault.balanceOf(admin), 1000_000000);
    }

    function test_depositGate_allowsWhenEnabled() public {
        usdc.mint(randomUser, 1000_000000);
        vm.startPrank(randomUser);
        usdc.approve(address(vault), 1000_000000);
        vault.deposit(1000_000000, randomUser);
        vm.stopPrank();

        assertEq(vault.balanceOf(randomUser), 1000_000000);
    }

    function test_maxDeposit_returnsZeroWhenDisabled() public {
        vm.prank(admin);
        vault.setDepositsEnabled(false);

        assertEq(vault.maxDeposit(randomUser), 0);
        assertEq(vault.maxMint(randomUser), 0);
        // Owner is exempted
        assertEq(vault.maxDeposit(admin), type(uint256).max);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 2. Pausable Tests
    // ─────────────────────────────────────────────────────────────────────────

    function test_pause_blocksDeposits() public {
        vm.prank(admin);
        vault.pause();

        usdc.mint(admin, 1000_000000);
        vm.startPrank(admin);
        usdc.approve(address(vault), 1000_000000);
        vm.expectRevert(); // EnforcedPause
        vault.deposit(1000_000000, admin);
        vm.stopPrank();
    }

    function test_pause_blocksWithdrawals() public {
        // First deposit while unpaused
        usdc.mint(lp1, 1000_000000);
        vm.startPrank(lp1);
        usdc.approve(address(vault), 1000_000000);
        vault.deposit(1000_000000, lp1);
        vm.stopPrank();

        // Pause
        vm.prank(admin);
        vault.pause();

        // Try to withdraw
        vm.startPrank(lp1);
        vm.expectRevert(); // EnforcedPause
        vault.withdraw(500_000000, lp1, lp1);
        vm.stopPrank();
    }

    function test_pause_maxDepositReturnsZero() public {
        vm.prank(admin);
        vault.pause();

        assertEq(vault.maxDeposit(admin), 0);
        assertEq(vault.maxMint(admin), 0);
    }

    function test_unpause_restoresOperations() public {
        vm.prank(admin);
        vault.pause();

        vm.prank(admin);
        vault.unpause();

        usdc.mint(lp1, 1000_000000);
        vm.startPrank(lp1);
        usdc.approve(address(vault), 1000_000000);
        vault.deposit(1000_000000, lp1);
        vm.stopPrank();

        assertEq(vault.balanceOf(lp1), 1000_000000);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 3. _claimableFromMarket with initialShares
    // ─────────────────────────────────────────────────────────────────────────

    function test_claimable_resolvedMarket_accountsForInitialShares() public {
        // Deposit and deploy
        _lpDeposit(lp1, 30_000_000000);
        vm.prank(admin);
        vault.deployTo(address(market), 5_000_000000);

        // Resolve
        vm.prank(creator);
        market.resolveMarket(50); // bucket 2 wins

        // Sync cached value
        vault.syncMarketValue(address(market));

        // The cached value should account for initial shares
        // (pool - traderShares, not pool - totalWinShares)
        uint256 cachedVal = vault.cachedMarketValue(address(market));
        uint256 pool = market.poolBalance();
        (uint256 winShares, uint256 initShares,,) = market.buckets(market.winningBucket());
        uint256 traderShares = winShares > initShares ? winShares - initShares : 0;
        uint256 expected = pool > traderShares ? pool - traderShares : 0;

        assertEq(cachedVal, expected, "cached value should use initialShares");
    }

    function test_harvestResolved_NAVstable() public {
        _lpDeposit(lp1, 30_000_000000);
        vm.prank(admin);
        vault.deployTo(address(market), 5_000_000000);

        vm.prank(creator);
        market.resolveMarket(50);

        vault.syncMarketValue(address(market));
        uint256 taBefore = vault.totalAssets();

        vault.harvestResolved(address(market));

        // NAV should be stable — cache already included initial shares
        assertApproxEqAbs(vault.totalAssets(), taBefore, 2, "NAV stable after harvest");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 4. Withdrawal Queue + Harvest Interaction
    // ─────────────────────────────────────────────────────────────────────────

    function test_withdrawalQueue_fulfilledAfterHarvest() public {
        _lpDeposit(lp1, 30_000_000000);
        vm.prank(admin);
        vault.deployTo(address(market), 5_000_000000);

        // LP1 requests withdrawal — may not have enough liquid
        vm.prank(lp1);
        uint256 queueIdx = vault.requestWithdrawal(1_000_000000);

        // Resolve market and harvest — capital returns
        vm.prank(creator);
        market.resolveMarket(50);
        vault.harvestResolved(address(market));

        // Check if request was fulfilled
        (,,bool fulfilled,,) = vault.withdrawalQueue(queueIdx);
        assertTrue(fulfilled, "request should be fulfilled after harvest");

        // Claim
        vm.prank(lp1);
        vault.claimWithdrawal(queueIdx);
    }

    /// @notice KNOWN ISSUE: Old vault doesn't subtract totalAssetsOwed from deployableCapital.
    ///         Queue burns shares but NAV doesn't adjust — deployable stays inflated.
    ///         This test documents the current (incorrect) behavior. Vault V2 will fix this
    ///         by subtracting totalAssetsOwed from both totalAssets() and deployableCapital().
    function test_withdrawalQueue_deployableDoesNotAccountForOwed_KNOWN_ISSUE() public {
        _lpDeposit(lp1, 10_000_000000);

        uint256 deployableBefore = vault.deployableCapital();

        vm.prank(lp1);
        vault.requestWithdrawal(5_000_000000);

        uint256 deployableAfter = vault.deployableCapital();
        // BUG: deployable is unchanged because totalAssetsOwed is not subtracted
        // This will be fixed in Vault V2
        assertEq(deployableAfter, deployableBefore, "KNOWN ISSUE: deployable unchanged after queue request");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 5. Events on Admin Setters
    // ─────────────────────────────────────────────────────────────────────────

    function test_event_depositsEnabled() public {
        vm.prank(admin);
        vm.expectEmit();
        emit Vault.DepositsEnabledUpdated(false);
        vault.setDepositsEnabled(false);
    }

    function test_event_factoryUpdated() public {
        vm.prank(admin);
        vm.expectEmit();
        emit Vault.FactoryUpdated(address(0), address(0xBEEF));
        vault.setFactory(address(0xBEEF));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────────

    function _lpDeposit(address lp, uint256 amount) internal {
        usdc.mint(lp, amount);
        vm.startPrank(lp);
        usdc.approve(address(vault), amount);
        vault.deposit(amount, lp);
        vm.stopPrank();
    }

    function _uniformSeeds(uint256 n, uint256 pool) internal pure returns (uint256[] memory ids, uint256[] memory shares) {
        ids = new uint256[](n);
        shares = new uint256[](n);
        uint256 per = pool / n;
        for (uint256 i = 0; i < n; i++) { ids[i] = i; shares[i] = per; }
        shares[n - 1] += pool - (per * n);
    }

    function _defaultMetadata() internal pure returns (LMSRMarket.MarketMetadata memory) {
        return LMSRMarket.MarketMetadata("Test", "", "", "USD", address(0), 0, 0, 0);
    }

    function _deployMarket(uint256 id, uint256 numBuckets, uint256 bw, uint256 seed) internal returns (LMSRMarket m) {
        uint256 _alpha = seed / _isqrt(numBuckets);
        (uint256[] memory seedIds, uint256[] memory seedShares) = _uniformSeeds(numBuckets, seed);
        m = new LMSRMarket(LMSRMarket.InitParams({
            marketId: id,
            creator: creator,
            factory: address(0xFACE),
            usdcToken: address(usdc),
            positionNFT: address(0),
            alpha: _alpha,
            poolBalance: seed,
            bucketWidth: bw,
            maxBucketId: numBuckets - 1,
            seededBucketIds: seedIds,
            seededShares: seedShares,
            feeBps: 100,
            protocolFeeBps: 2000,
            metadata: _defaultMetadata(),
            protocolFeeCollector: address(0xFEE)
        }));
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
}
