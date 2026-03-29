// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {LMSRMarket} from "../src/LMSRMarket.sol";
import {PositionNFT} from "../src/PositionNFT.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";

/// @notice Compare: 200-bucket sparse seed vs 20-bucket dense seed
contract LazySeedingTest is Test {
    MockUSDC usdc;
    PositionNFT posNFT;
    address factory;
    address creator = address(0x1);
    address trader = address(0x2);

    uint256 constant POOL = 100_000_000000; // $100K

    function setUp() public {
        usdc = new MockUSDC();
        factory = address(this);
        posNFT = new PositionNFT(factory);
        usdc.mint(trader, 10_000_000_000000);
    }

    /// @dev 200 buckets ($50K-$250K), only center 20 seeded ($90K-$110K)
    function _createSparse200() internal returns (LMSRMarket) {
        uint256[] memory ranges = new uint256[](201);
        for (uint256 i = 0; i <= 200; i++) {
            ranges[i] = 50000 + (i * 1000); // $50K to $250K, $1K steps
        }

        // Seed only buckets 40-59 ($90K-$110K)
        // Empty buckets get 1 micro-USDC each (minimum > 0)
        uint256[] memory shares = new uint256[](200);
        uint256 emptyShare = 1; // 1 micro-USDC
        uint256 emptyTotal = 180 * emptyShare;
        uint256 seededPool = POOL - emptyTotal;
        uint256 perSeeded = seededPool / 20;

        for (uint256 i = 0; i < 200; i++) {
            if (i >= 40 && i < 60) {
                shares[i] = perSeeded;
            } else {
                shares[i] = emptyShare;
            }
        }
        // Absorb rounding into last seeded bucket
        uint256 assigned = perSeeded * 20 + emptyTotal;
        shares[59] += (POOL - assigned);

        return _deployMarket(1, ranges, shares);
    }

    /// @dev 20 buckets ($90K-$110K), all seeded
    function _createDense20() internal returns (LMSRMarket) {
        uint256[] memory ranges = new uint256[](21);
        for (uint256 i = 0; i <= 20; i++) {
            ranges[i] = 90000 + (i * 1000); // $90K to $110K, $1K steps
        }
        return _deployMarket(2, ranges, new uint256[](0)); // uniform
    }

    function _deployMarket(uint256 id, uint256[] memory ranges, uint256[] memory shares)
        internal returns (LMSRMarket)
    {
        uint256 buckets = ranges.length - 1;
        uint256 sqrtN = _sqrt(20); // use sqrt(20) for both to match alpha
        uint256 alpha = POOL / sqrtN;

        LMSRMarket m = new LMSRMarket(
            id, creator, factory, address(usdc), address(posNFT),
            alpha, POOL, ranges, shares, 100, 0,
            LMSRMarket.MarketMetadata("", "", "", "", creator, 0, 0, 0),
            address(0)
        );
        posNFT.authorizeMarket(address(m), id);
        usdc.mint(address(m), POOL);

        vm.startPrank(trader);
        usdc.approve(address(m), type(uint256).max);
        posNFT.setApprovalForAll(address(m), true);
        vm.stopPrank();

        return m;
    }

    function _sqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 1;
        uint256 z = (x + 1) / 2;
        uint256 y = x;
        while (z < y) { y = z; z = (x / z + z) / 2; }
        return y;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                    CREATION GAS
    // ═══════════════════════════════════════════════════════════════════════

    function test_creationGas() public {
        uint256 g0 = gasleft();
        LMSRMarket sparse = _createSparse200();
        uint256 g1 = gasleft();
        uint256 sparseGas = g0 - g1;

        g0 = gasleft();
        LMSRMarket dense = _createDense20();
        g1 = gasleft();
        uint256 denseGas = g0 - g1;

        console.log("=== CREATION GAS ===");
        console.log("Sparse 200 (20 seeded):", sparseGas);
        console.log("Dense 20:              ", denseGas);
        console.log("Overhead:              ", sparseGas - denseGas);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                    PRICE COMPARISON
    // ═══════════════════════════════════════════════════════════════════════

    function test_priceComparison() public {
        LMSRMarket sparse = _createSparse200();
        LMSRMarket dense = _createDense20();

        // Both have same alpha and same shares in center buckets
        // Buy $1K in center bucket: $100K ($100K-$101K in both)
        // Sparse: bucket 50 ($100K-$101K)
        // Dense: bucket 10 ($100K-$101K)

        vm.startPrank(trader);

        uint256 sharesSparse = sparse.buySharesRange(100000, 101000, 1000_000000, 0, 0, trader);
        uint256 sharesDense = dense.buySharesRange(100000, 101000, 1000_000000, 0, 0, trader);

        vm.stopPrank();

        console.log("=== PRICE COMPARISON ($1K buy on center bucket) ===");
        console.log("Sparse shares received:", sharesSparse / 1e6);
        console.log("Dense shares received: ", sharesDense / 1e6);
        console.log("Difference:            ", _absDiff(sharesSparse, sharesDense) / 1e6);

        // Are they close? The phantom weight on 180 empty buckets affects pricing
        uint256 pctDiff = (_absDiff(sharesSparse, sharesDense) * 10000) / sharesDense;
        console.log("Pct difference (bps):  ", pctDiff);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                    TRADING GAS
    // ═══════════════════════════════════════════════════════════════════════

    function test_tradingGas() public {
        LMSRMarket sparse = _createSparse200();
        LMSRMarket dense = _createDense20();

        vm.startPrank(trader);

        // Buy in seeded region
        uint256 g0 = gasleft();
        sparse.buySharesRange(100000, 101000, 500_000000, 0, 0, trader);
        uint256 g1 = gasleft();
        uint256 sparseSeededGas = g0 - g1;

        g0 = gasleft();
        dense.buySharesRange(100000, 101000, 500_000000, 0, 0, trader);
        g1 = gasleft();
        uint256 denseGas = g0 - g1;

        // Buy in empty region (sparse only) - bucket 0 ($50K-$51K)
        g0 = gasleft();
        sparse.buySharesRange(50000, 51000, 500_000000, 0, 0, trader);
        g1 = gasleft();
        uint256 sparseEmptyGas = g0 - g1;

        vm.stopPrank();

        console.log("=== TRADING GAS ===");
        console.log("Sparse (seeded bucket):", sparseSeededGas);
        console.log("Dense (all seeded):    ", denseGas);
        console.log("Sparse (empty bucket): ", sparseEmptyGas);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                    LP ECONOMICS - SAME TRADES
    // ═══════════════════════════════════════════════════════════════════════

    function test_lpEconomics_centerWins() public {
        LMSRMarket sparse = _createSparse200();
        LMSRMarket dense = _createDense20();

        // Same trades: $1K on $100K bucket (smaller to avoid solvency)
        vm.startPrank(trader);
        sparse.buySharesRange(100000, 101000, 1_000_000000, 0, 0, trader);
        dense.buySharesRange(100000, 101000, 1_000_000000, 0, 0, trader);
        vm.stopPrank();

        // Resolve at $100.5K
        vm.prank(creator);
        sparse.resolveMarket(100500);
        vm.prank(creator);
        dense.resolveMarket(100500);

        (int256 profitSparse,,) = sparse.getLPProfitability();
        (int256 profitDense,,) = dense.getLPProfitability();

        console.log("=== LP ECONOMICS (center wins) ===");
        console.log("Sparse LP profit:      ", profitSparse);
        console.log("Dense LP profit:       ", profitDense);

        _printWin(sparse, "Sparse");
        _printWin(dense, "Dense");
    }

    function test_lpEconomics_tailWins() public {
        LMSRMarket sparse = _createSparse200();

        // Buy in tail region: $60K bucket
        vm.startPrank(trader);
        sparse.buySharesRange(60000, 61000, 1_000_000000, 0, 0, trader);
        vm.stopPrank();

        // Resolve at $60.5K (tail - minimal LP seeding)
        vm.prank(creator);
        sparse.resolveMarket(60500);

        (int256 profit,,) = sparse.getLPProfitability();

        console.log("=== LP ECONOMICS (tail wins - sparse only) ===");
        console.log("LP profit:             ", profit);
        _printWin(sparse, "Sparse");
    }

    // ═══════════════════════════════════════════════════════════════════════

    function _printWin(LMSRMarket m, string memory label) internal view {
        uint256 wb = m.winningBucket();
        (uint256 total, uint256 init,,) = m.buckets(wb);
        console.log(string.concat("  ", label, " winning bucket:"), wb);
        console.log(string.concat("  ", label, " total shares: "), total / 1e6);
        console.log(string.concat("  ", label, " init shares:  "), init / 1e6);
    }

    function _absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }
}
