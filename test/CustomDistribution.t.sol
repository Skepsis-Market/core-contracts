// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {LMSRMarket} from "../src/LMSRMarket.sol";
import {PositionNFT} from "../src/PositionNFT.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";

contract CustomDistributionTest is Test {
    MockUSDC usdc;
    PositionNFT posNFT;
    address factory;
    address creator = address(0x1);
    address trader = address(0x456);

    uint256 constant POOL = 100_000_000000; // $100K
    uint256 constant BUCKETS = 50;

    function setUp() public {
        usdc = new MockUSDC();
        factory = address(this);
        posNFT = new PositionNFT(factory);
        usdc.mint(trader, 1_000_000_000000);
    }

    /// @dev Build a bell-curve-ish distribution centered at bucket 25
    function _bellCurveShares() internal pure returns (uint256[] memory shares) {
        shares = new uint256[](BUCKETS);
        // Gaussian-like: heavier in center, lighter at tails
        // We use a simple triangle that sums to POOL
        uint256 total = 0;
        uint256[] memory raw = new uint256[](BUCKETS);
        for (uint256 i = 0; i < BUCKETS; i++) {
            // Distance from center (bucket 25)
            uint256 dist = i > 25 ? i - 25 : 25 - i;
            raw[i] = 26 - dist; // 26 at center, 1 at edges
            total += raw[i];
        }
        // Scale to POOL
        uint256 assigned = 0;
        for (uint256 i = 0; i < BUCKETS - 1; i++) {
            shares[i] = (raw[i] * POOL) / total;
            assigned += shares[i];
        }
        shares[BUCKETS - 1] = POOL - assigned; // remainder to last bucket
    }

    function _uniformSeedsCD() internal pure returns (uint256[] memory ids, uint256[] memory shares) {
        ids = new uint256[](BUCKETS);
        shares = new uint256[](BUCKETS);
        uint256 per = POOL / BUCKETS;
        for (uint256 i = 0; i < BUCKETS; i++) {
            ids[i] = 80 + i;
            shares[i] = per;
        }
        shares[BUCKETS - 1] += POOL - (per * BUCKETS);
    }

    function _createSeedIds() internal pure returns (uint256[] memory ids) {
        ids = new uint256[](BUCKETS);
        for (uint256 i = 0; i < BUCKETS; i++) {
            ids[i] = 80 + i; // absolute bucket IDs 80-129 (value = id * 1000)
        }
    }

    function _meta() internal pure returns (LMSRMarket.MarketMetadata memory) {
        return LMSRMarket.MarketMetadata("BTC EOY", "", "", "USD", address(0x1), 0, 0, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                    CREATION & GAS
    // ═══════════════════════════════════════════════════════════════════════

    function test_customDist_50buckets_creates() public {
        uint256[] memory shares = _bellCurveShares();
        // ranges no longer needed with absolute bucket indexing
        uint256 alpha = POOL / 7; // ~sqrt(50) ≈ 7

        uint256 g0 = gasleft();
        LMSRMarket market = new LMSRMarket(LMSRMarket.InitParams({
                marketId: 1,
                creator: creator,
                factory: factory,
                usdcToken: address(usdc),
                positionNFT: address(posNFT),
                alpha: alpha,
                poolBalance: POOL,
                bucketWidth: 1000,
                maxBucketId: 129,
                seededBucketIds: _createSeedIds(),
                seededShares: shares,
                feeBps: 50,
                protocolFeeBps: 0,
                metadata: _meta(),
                protocolFeeCollector: address(0)
            }));
        uint256 g1 = gasleft();

        posNFT.authorizeMarket(address(market), 1);
        usdc.mint(address(market), POOL);

        console.log("=== 50-BUCKET CUSTOM DISTRIBUTION ===");
        console.log("Gas for creation:     ", g0 - g1);
        console.log("Pool balance:         ", market.poolBalance() / 1e6, "USDC");
        console.log("Bucket count:         ", market.bucketCount());
        console.log("Alpha:                ", market.alpha() / 1e6, "USDC");

        // Verify distribution
        (uint256 centerShares,,,) = market.buckets(105);
        (uint256 edgeShares,,,) = market.buckets(80);
        console.log("Center bucket shares: ", centerShares / 1e6, "USDC");
        console.log("Edge bucket shares:   ", edgeShares / 1e6, "USDC");
        console.log("Center/Edge ratio:    ", centerShares / edgeShares, "x");

        assertGt(centerShares, edgeShares, "Center should have more shares");
        assertEq(market.poolBalance(), POOL, "Pool should match");
    }

    function test_customDist_50buckets_uniformComparison() public {
        // ranges no longer needed with absolute bucket indexing
        uint256 alpha = POOL / 7;

        // Uniform
        uint256 g0 = gasleft();
        (uint256[] memory uIds, uint256[] memory uShares) = _uniformSeedsCD();
        LMSRMarket uniform = new LMSRMarket(LMSRMarket.InitParams({
                marketId: 1,
                creator: creator,
                factory: factory,
                usdcToken: address(usdc),
                positionNFT: address(posNFT),
                alpha: alpha,
                poolBalance: POOL,
                bucketWidth: 1000,
                maxBucketId: 129,
                seededBucketIds: uIds,
                seededShares: uShares,
                feeBps: 50,
                protocolFeeBps: 0,
                metadata: _meta(),
                protocolFeeCollector: address(0)
            }));
        uint256 g1 = gasleft();
        uint256 uniformGas = g0 - g1;

        // Custom
        uint256[] memory shares = _bellCurveShares();
        g0 = gasleft();
        LMSRMarket custom = new LMSRMarket(LMSRMarket.InitParams({
                marketId: 2,
                creator: creator,
                factory: factory,
                usdcToken: address(usdc),
                positionNFT: address(posNFT),
                alpha: alpha,
                poolBalance: POOL,
                bucketWidth: 1000,
                maxBucketId: 129,
                seededBucketIds: _createSeedIds(),
                seededShares: shares,
                feeBps: 50,
                protocolFeeBps: 0,
                metadata: _meta(),
                protocolFeeCollector: address(0)
            }));
        g1 = gasleft();
        uint256 customGas = g0 - g1;

        console.log("=== GAS COMPARISON (50 buckets) ===");
        console.log("Uniform creation gas: ", uniformGas);
        console.log("Custom creation gas:  ", customGas);
        console.log("Difference:           ", customGas > uniformGas ? customGas - uniformGas : uniformGas - customGas);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                    TRADING ON CUSTOM DIST
    // ═══════════════════════════════════════════════════════════════════════

    function test_customDist_buyCenter() public {
        uint256[] memory shares = _bellCurveShares();
        // ranges no longer needed with absolute bucket indexing
        uint256 alpha = POOL / 7;

        LMSRMarket market = new LMSRMarket(LMSRMarket.InitParams({
                marketId: 1,
                creator: creator,
                factory: factory,
                usdcToken: address(usdc),
                positionNFT: address(posNFT),
                alpha: alpha,
                poolBalance: POOL,
                bucketWidth: 1000,
                maxBucketId: 129,
                seededBucketIds: _createSeedIds(),
                seededShares: shares,
                feeBps: 50,
                protocolFeeBps: 0,
                metadata: _meta(),
                protocolFeeCollector: address(0)
            }));
        posNFT.authorizeMarket(address(market), 1);
        usdc.mint(address(market), POOL);

        // Buy center bucket (high initial prob — expensive)
        vm.startPrank(trader);
        usdc.approve(address(market), type(uint256).max);
        posNFT.setApprovalForAll(address(market), true);

        uint256 buyAmount = 1000_000000; // $1K
        uint256 lower = 25 * market.bucketWidth();
        uint256 upper = lower + market.bucketWidth();

        uint256 g0 = gasleft();
        (uint256 sharesBought,,,,,) = market.buySharesRange(lower, upper, buyAmount, 0, 0, trader);
        uint256 g1 = gasleft();
        vm.stopPrank();

        console.log("=== BUY CENTER BUCKET (high prob) ===");
        console.log("Gas:                  ", g0 - g1);
        console.log("Spent:                ", buyAmount / 1e6, "USDC");
        console.log("Shares received:      ", sharesBought / 1e6);
    }

    function test_customDist_buyTail() public {
        uint256[] memory shares = _bellCurveShares();
        // ranges no longer needed with absolute bucket indexing
        uint256 alpha = POOL / 7;

        LMSRMarket market = new LMSRMarket(LMSRMarket.InitParams({
                marketId: 1,
                creator: creator,
                factory: factory,
                usdcToken: address(usdc),
                positionNFT: address(posNFT),
                alpha: alpha,
                poolBalance: POOL,
                bucketWidth: 1000,
                maxBucketId: 129,
                seededBucketIds: _createSeedIds(),
                seededShares: shares,
                feeBps: 50,
                protocolFeeBps: 0,
                metadata: _meta(),
                protocolFeeCollector: address(0)
            }));
        posNFT.authorizeMarket(address(market), 1);
        usdc.mint(address(market), POOL);

        // Buy tail bucket (low initial prob — cheap)
        vm.startPrank(trader);
        usdc.approve(address(market), type(uint256).max);
        posNFT.setApprovalForAll(address(market), true);

        uint256 buyAmount = 1000_000000; // $1K
        uint256 lower = 0; // bucket 0 = $80K (far tail)
        uint256 upper = lower + market.bucketWidth();

        uint256 g0 = gasleft();
        (uint256 sharesBought,,,,,) = market.buySharesRange(lower, upper, buyAmount, 0, 0, trader);
        uint256 g1 = gasleft();
        vm.stopPrank();

        console.log("=== BUY TAIL BUCKET (low prob) ===");
        console.log("Gas:                  ", g0 - g1);
        console.log("Spent:                ", buyAmount / 1e6, "USDC");
        console.log("Shares received:      ", sharesBought / 1e6);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                    FULL LIFECYCLE
    // ═══════════════════════════════════════════════════════════════════════

    function test_customDist_fullLifecycle() public {
        uint256[] memory shares = _bellCurveShares();
        // ranges no longer needed with absolute bucket indexing
        uint256 alpha = POOL / 7;

        LMSRMarket market = new LMSRMarket(LMSRMarket.InitParams({
                marketId: 1,
                creator: creator,
                factory: factory,
                usdcToken: address(usdc),
                positionNFT: address(posNFT),
                alpha: alpha,
                poolBalance: POOL,
                bucketWidth: 1000,
                maxBucketId: 129,
                seededBucketIds: _createSeedIds(),
                seededShares: shares,
                feeBps: 50,
                protocolFeeBps: 0,
                metadata: _meta(),
                protocolFeeCollector: address(0)
            }));
        posNFT.authorizeMarket(address(market), 1);
        usdc.mint(address(market), POOL);

        // Buy tail bucket
        vm.startPrank(trader);
        usdc.approve(address(market), type(uint256).max);
        posNFT.setApprovalForAll(address(market), true);

        uint256 lower = 83 * market.bucketWidth(); // bucket 83 = $83K
        uint256 upper = lower + market.bucketWidth();
        (uint256 sharesBought,,,,,) = market.buySharesRange(lower, upper, 5000_000000, 0, 0, trader);
        vm.stopPrank();

        // Resolve at $83.5K = bucket 83
        vm.prank(creator);
        market.resolveMarket(83500);

        // LP withdraws
        uint256 creatorBefore = usdc.balanceOf(creator);
        vm.prank(creator);
        market.withdrawLP();
        uint256 lpGot = usdc.balanceOf(creator) - creatorBefore;

        // Trader claims
        uint256 tokenId = (uint256(uint128(1)) << 128) | (uint256(uint64(83)) << 64) | uint256(uint64(83));
        uint256 traderBefore = usdc.balanceOf(trader);
        vm.prank(trader);
        market.claim(tokenId, trader);
        uint256 traderGot = usdc.balanceOf(trader) - traderBefore;

        uint256 stuck = usdc.balanceOf(address(market));

        console.log("=== FULL LIFECYCLE (tail wins) ===");
        console.log("Trader bought shares: ", sharesBought / 1e6);
        console.log("Trader paid:          5000 USDC");
        console.log("Trader claimed:       ", traderGot / 1e6, "USDC");
        console.log("LP deposited:         ", POOL / 1e6, "USDC");
        console.log("LP recovered:         ", lpGot / 1e6, "USDC");
        console.log("LP P&L:               ", int256(lpGot) - int256(POOL));
        console.log("Stuck in contract:    ", stuck / 1e6, "USDC");

        assertEq(stuck, 0, "No funds should be stuck");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                    VALIDATION
    // ═══════════════════════════════════════════════════════════════════════

    function test_customDist_revertIfSumMismatch() public {
        // ranges no longer needed with absolute bucket indexing
        uint256[] memory badShares = new uint256[](BUCKETS);
        for (uint256 i = 0; i < BUCKETS; i++) badShares[i] = 1000_000000; // $1K each = $50K ≠ POOL
        uint256 alpha = POOL / 7;

        vm.expectRevert(LMSRMarket.InvalidParameters.selector);
        new LMSRMarket(LMSRMarket.InitParams({
                marketId: 1,
                creator: creator,
                factory: factory,
                usdcToken: address(usdc),
                positionNFT: address(posNFT),
                alpha: alpha,
                poolBalance: POOL,
                bucketWidth: 1000,
                maxBucketId: 129,
                seededBucketIds: _createSeedIds(),
                seededShares: badShares,
                feeBps: 50,
                protocolFeeBps: 0,
                metadata: _meta(),
                protocolFeeCollector: address(0)
            }));
    }

    function test_customDist_revertIfZeroBucket() public {
        uint256[] memory badShares = _bellCurveShares();
        badShares[0] = 0; // zero bucket

        vm.expectRevert(LMSRMarket.InvalidParameters.selector);
        new LMSRMarket(LMSRMarket.InitParams({
                marketId: 1,
                creator: creator,
                factory: factory,
                usdcToken: address(usdc),
                positionNFT: address(posNFT),
                alpha: POOL / 7,
                poolBalance: POOL,
                bucketWidth: 1000,
                maxBucketId: 129,
                seededBucketIds: _createSeedIds(),
                seededShares: badShares,
                feeBps: 50,
                protocolFeeBps: 0,
                metadata: _meta(),
                protocolFeeCollector: address(0)
            }));
    }

    function test_customDist_revertIfWrongLength() public {
        uint256[] memory badIds = new uint256[](10);
        uint256[] memory badShares = new uint256[](11); // wrong length vs ids

        vm.expectRevert(LMSRMarket.InvalidParameters.selector);
        new LMSRMarket(LMSRMarket.InitParams({
                marketId: 1,
                creator: creator,
                factory: factory,
                usdcToken: address(usdc),
                positionNFT: address(posNFT),
                alpha: POOL / 7,
                poolBalance: POOL,
                bucketWidth: 1000,
                maxBucketId: 129,
                seededBucketIds: badIds,
                seededShares: badShares,
                feeBps: 50,
                protocolFeeBps: 0,
                metadata: _meta(),
                protocolFeeCollector: address(0)
            }));
    }
}
