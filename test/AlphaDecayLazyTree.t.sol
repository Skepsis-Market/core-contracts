// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {LMSRMarket} from "../src/LMSRMarket.sol";
import {PositionNFT} from "../src/PositionNFT.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";

/// @notice Test alpha decay with lazy tree initialization (P5-C-01 regression test)
contract AlphaDecayLazyTreeTest is Test {
    MockUSDC usdc;
    PositionNFT posNFT;
    LMSRMarket market;
    address factory;
    address creator = address(0x1);
    address trader = address(0x2);

    uint256 constant POOL = 10_000_000000; // $10K
    uint256 constant ALPHA = 2_000_000000; // $2K

    function setUp() public {
        usdc = new MockUSDC();
        factory = address(this);
        posNFT = new PositionNFT(factory);

        // Seed 5 buckets at IDs 100-104 (sparse — maxBucketId=200)
        uint256[] memory seedIds = new uint256[](5);
        uint256[] memory seedShares = new uint256[](5);
        for (uint256 i = 0; i < 5; i++) {
            seedIds[i] = 100 + i;
            seedShares[i] = POOL / 5;
        }

        market = new LMSRMarket(LMSRMarket.InitParams({
            marketId: 1,
            creator: creator,
            factory: factory,
            usdcToken: address(usdc),
            positionNFT: address(posNFT),
            alpha: ALPHA,
            poolBalance: POOL,
            bucketWidth: 1000,
            maxBucketId: 200,
            seededBucketIds: seedIds,
            seededShares: seedShares,
            feeBps: 100,
            protocolFeeBps: 0,
            metadata: LMSRMarket.MarketMetadata("", "", "", "", creator, 0, 0, 0),
            protocolFeeCollector: address(0)
        }));

        posNFT.authorizeMarket(address(market), 1);
        usdc.mint(address(market), POOL);

        // Configure alpha decay: 50% over 1 hour
        vm.prank(creator);
        market.configureAlphaDecay(ALPHA / 2, block.timestamp, 1 hours);

        // Fund trader
        usdc.mint(trader, 100_000_000000);
        vm.startPrank(trader);
        usdc.approve(address(market), type(uint256).max);
        posNFT.setApprovalForAll(address(market), true);
        vm.stopPrank();
    }

    /// @notice Core regression test: alpha sync must work with offset-based tree
    function test_alphaSyncDoesNotRevert() public {
        // Warp past one epoch (30 min)
        vm.warp(block.timestamp + 31 minutes);

        // This buy triggers _syncAlpha() internally
        // Before P5-C-01 fix, this reverted with "BucketTree: length mismatch"
        vm.prank(trader);
        (uint256 shares,,,,,) = market.buySharesRange(100000, 101000, 100_000000, 0, 0, trader);
        assertGt(shares, 0, "Should receive shares after alpha sync");

        // Verify alpha actually decayed
        assertLt(market.alpha(), ALPHA, "Alpha should have decayed");
    }

    /// @notice Alpha sync after tree growth (bucket activated outside initial range)
    function test_alphaSyncAfterTreeGrowth() public {
        // Activate a bucket outside the initial range
        vm.prank(trader);
        market.buySharesRange(50000, 51000, 100_000000, 0, 0, trader); // bucket 50, below offset 100

        // Warp past one epoch
        vm.warp(block.timestamp + 31 minutes);

        // Alpha sync with expanded tree (now covers [50, 104] instead of [100, 104])
        vm.prank(trader);
        (uint256 shares,,,,,) = market.buySharesRange(101000, 102000, 100_000000, 0, 0, trader);
        assertGt(shares, 0, "Should receive shares after alpha sync with grown tree");
    }

    /// @notice Alpha sync after tree growth upward
    function test_alphaSyncAfterTreeGrowthUpward() public {
        // Activate bucket above initial range
        vm.prank(trader);
        market.buySharesRange(150000, 151000, 100_000000, 0, 0, trader); // bucket 150, above 104

        // Warp past epoch
        vm.warp(block.timestamp + 31 minutes);

        // Alpha sync with tree covering [100, 150]
        vm.prank(trader);
        (uint256 shares,,,,,) = market.buySharesRange(102000, 103000, 100_000000, 0, 0, trader);
        assertGt(shares, 0);
    }

    /// @notice Multiple alpha syncs over multiple epochs
    function test_multipleAlphaSyncs() public {
        uint256 prevAlpha = market.alpha();

        for (uint256 epoch = 0; epoch < 3; epoch++) {
            vm.warp(block.timestamp + 31 minutes);

            vm.prank(trader);
            market.buySharesRange(100000, 101000, 50_000000, 0, 0, trader);

            uint256 newAlpha = market.alpha();
            assertLe(newAlpha, prevAlpha, "Alpha should monotonically decrease");
            prevAlpha = newAlpha;
        }

        // After 93 min of 60 min decay, alpha should be near floor
        assertLt(market.alpha(), ALPHA, "Alpha should have decayed significantly");
    }

    /// @notice Sell after alpha sync should work
    function test_sellAfterAlphaSync() public {
        // Buy first
        vm.prank(trader);
        (uint256 shares,,,,,) = market.buySharesRange(100000, 101000, 500_000000, 0, 0, trader);

        // Warp and trigger sync
        vm.warp(block.timestamp + 31 minutes);

        // Sell should work after alpha sync
        vm.prank(trader);
        (uint256 payout,,,) = market.sellSharesRange(100000, 101000, shares / 2, 0, trader);
        assertGt(payout, 0, "Should receive payout after sell with alpha sync");
    }
}
