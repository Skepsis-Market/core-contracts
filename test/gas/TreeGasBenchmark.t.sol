// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {LMSRMarket} from "../../src/LMSRMarket.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";

/// @notice Gas benchmarks for BucketTree-powered LMSRMarket operations
/// @dev Run with: forge test --match-contract TreeGasBenchmarkTest -vvv
contract TreeGasBenchmarkTest is Test {
    MockUSDC public usdc;
    address creator = address(0x1);
    address trader = address(0x2);

    uint256 constant POOL = 10_000_000000; // $10,000
    uint256 constant ALPHA = 1_000_000000; // $1,000

    function _uniformSeeds(uint256 numBuckets, uint256 pool)
        internal pure returns (uint256[] memory ids, uint256[] memory shares)
    {
        ids = new uint256[](numBuckets);
        shares = new uint256[](numBuckets);
        uint256 per = pool / numBuckets;
        for (uint256 i = 0; i < numBuckets; i++) {
            ids[i] = 100 + i; // absolute IDs: 100, 101, 102... (value = id * 1000)
            shares[i] = per;
        }
        shares[numBuckets - 1] += pool - (per * numBuckets);
    }

    function _createMarket(uint256 buckets) internal returns (LMSRMarket) {
        (uint256[] memory seedIds, uint256[] memory seedShares) = _uniformSeeds(buckets, POOL);
        uint256 maxBid = 100 + buckets - 1;

        LMSRMarket.MarketMetadata memory meta = LMSRMarket.MarketMetadata({
            name: "Gas Benchmark",
            description: "",
            resolutionCriteria: "",
            valueUnit: "USD",
            resolver: creator,
            biddingDeadline: 0,
            scheduledResolutionTime: 0,
            minBetSize: 0
        });

        vm.prank(creator);
        LMSRMarket market = new LMSRMarket(LMSRMarket.InitParams({
                marketId: 1,
                creator: creator,
                factory: address(this),
                usdcToken: address(usdc),
                positionNFT: address(0),
                alpha: ALPHA,
                poolBalance: POOL,
                bucketWidth: 1_000,
                maxBucketId: maxBid,
                seededBucketIds: seedIds,
                seededShares: seedShares,
                feeBps: 50,
                protocolFeeBps: 2000,
                metadata: meta,
                protocolFeeCollector: address(0xFEE)
            }));

        // Fund trader
        usdc.mint(trader, 100_000_000000);
        vm.prank(trader);
        usdc.approve(address(market), type(uint256).max);

        return market;
    }

    function setUp() public {
        usdc = new MockUSDC();
        usdc.mint(creator, 100_000_000000);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                    SINGLE BUCKET OPERATIONS
    // ═══════════════════════════════════════════════════════════════════

    function _buyBucket(LMSRMarket market, uint256 bucketId, uint256 amount, uint256 minShares) internal returns (uint256) {
        uint256 lower = bucketId * market.bucketWidth();
        (uint256 shares,,,,,) = market.buySharesRange(lower, lower + market.bucketWidth(), amount, minShares, 0, address(0));
        return shares;
    }
    function _sellBucket(LMSRMarket market, uint256 bucketId, uint256 shares, uint256 minPayout) internal returns (uint256) {
        uint256 lower = bucketId * market.bucketWidth();
        (uint256 payoutUSDC,,,) = market.sellSharesRange(lower, lower + market.bucketWidth(), shares, minPayout, address(0));
        return payoutUSDC;
    }

    function test_gas_buyShares_single_19buckets() public {
        LMSRMarket market = _createMarket(19);
        uint256 lower = 5 * market.bucketWidth();
        uint256 upper = lower + market.bucketWidth();
        vm.prank(trader);
        uint256 g0 = gasleft();
        market.buySharesRange(lower, upper, 100_000000, 0, 0, address(0)); // $100 buy on bucket 5
        uint256 g1 = gasleft();
        console.log("buyShares (single, 19 buckets):", g0 - g1);
    }

    function test_gas_sellShares_single_19buckets() public {
        LMSRMarket market = _createMarket(19);
        // Buy first
        vm.startPrank(trader);
        _buyBucket(market, 5, 500_000000, 0);
        vm.stopPrank();
        // Sell
        (uint256 bShares,,,) = market.buckets(5);
        uint256 shares = bShares > POOL / 19 ? (bShares - POOL / 19) / 2 : 1;
        uint256 lower = 5 * market.bucketWidth();
        uint256 upper = lower + market.bucketWidth();
        vm.prank(trader);
        uint256 g0 = gasleft();
        market.sellSharesRange(lower, upper, shares / 2, 0, address(0));
        uint256 g1 = gasleft();
        console.log("sellShares (single, 19 buckets):", g0 - g1);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                     RANGE OPERATIONS
    // ═══════════════════════════════════════════════════════════════════

    function test_gas_buySharesRange_3buckets_withTarget() public {
        LMSRMarket market = _createMarket(19);
        // Get a quote first
        (uint256 quotedShares,,) = market.getQuoteForRange(103_000, 106_000, 200_000000);
        vm.prank(trader);
        uint256 g0 = gasleft();
        market.buySharesRange(103_000, 106_000, 200_000000, 0, quotedShares, address(0));
        uint256 g1 = gasleft();
        console.log("buySharesRange (3 buckets, fast path):", g0 - g1);
    }

    function test_gas_buySharesRange_3buckets_noTarget() public {
        LMSRMarket market = _createMarket(19);
        vm.prank(trader);
        uint256 g0 = gasleft();
        market.buySharesRange(103_000, 106_000, 200_000000, 0, 0, address(0));
        uint256 g1 = gasleft();
        console.log("buySharesRange (3 buckets, algebraic):", g0 - g1);
    }

    function test_gas_buySharesRange_10buckets_withTarget() public {
        LMSRMarket market = _createMarket(19);
        (uint256 quotedShares,,) = market.getQuoteForRange(100_000, 110_000, 500_000000);
        vm.prank(trader);
        uint256 g0 = gasleft();
        market.buySharesRange(100_000, 110_000, 500_000000, 0, quotedShares, address(0));
        uint256 g1 = gasleft();
        console.log("buySharesRange (10 buckets, fast path):", g0 - g1);
    }

    function test_gas_buySharesRange_10buckets_noTarget() public {
        LMSRMarket market = _createMarket(19);
        vm.prank(trader);
        uint256 g0 = gasleft();
        market.buySharesRange(100_000, 110_000, 500_000000, 0, 0, address(0));
        uint256 g1 = gasleft();
        console.log("buySharesRange (10 buckets, algebraic):", g0 - g1);
    }

    function test_gas_buySharesRange_all19_noTarget() public {
        LMSRMarket market = _createMarket(19);
        vm.prank(trader);
        uint256 g0 = gasleft();
        market.buySharesRange(100_000, 119_000, 500_000000, 0, 0, address(0));
        uint256 g1 = gasleft();
        console.log("buySharesRange (19 buckets, algebraic):", g0 - g1);
    }

    function test_gas_sellSharesRange_10buckets() public {
        LMSRMarket market = _createMarket(19);
        // Buy first
        vm.prank(trader);
        market.buySharesRange(100_000, 110_000, 500_000000, 0, 0, address(0));
        // Sell half
        (uint256 shares,,) = market.getQuoteForRange(100_000, 110_000, 500_000000);
        vm.prank(trader);
        uint256 g0 = gasleft();
        market.sellSharesRange(100_000, 110_000, shares / 4, 0, address(0));
        uint256 g1 = gasleft();
        console.log("sellSharesRange (10 buckets):", g0 - g1);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                      VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════

    function test_gas_getQuoteForRange_10buckets() public {
        LMSRMarket market = _createMarket(19);
        uint256 g0 = gasleft();
        market.getQuoteForRange(100_000, 110_000, 500_000000);
        uint256 g1 = gasleft();
        console.log("getQuoteForRange (10 buckets):", g0 - g1);
    }

    function test_gas_getQuoteForRange_all19() public {
        LMSRMarket market = _createMarket(19);
        uint256 g0 = gasleft();
        market.getQuoteForRange(100_000, 119_000, 500_000000);
        uint256 g1 = gasleft();
        console.log("getQuoteForRange (19 buckets):", g0 - g1);
    }

    function test_gas_calculateSharesForCost() public {
        LMSRMarket market = _createMarket(19);
        uint256 g0 = gasleft();
        market.calculateSharesForCost(5, 100_000000);
        uint256 g1 = gasleft();
        console.log("calculateSharesForCost:", g0 - g1);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                    INITIALIZATION
    // ═══════════════════════════════════════════════════════════════════

    function test_gas_initialize_19buckets() public {
        uint256 g0 = gasleft();
        _createMarket(19);
        uint256 g1 = gasleft();
        console.log("initialize (19 buckets):", g0 - g1);
    }

    function test_gas_initialize_50buckets() public {
        uint256 g0 = gasleft();
        _createMarket(50);
        uint256 g1 = gasleft();
        console.log("initialize (50 buckets):", g0 - g1);
    }

    // Gas numbers from individual tests above (19-bucket market):
    //
    // | Operation                             | Gas       |
    // |---------------------------------------|-----------|
    // | buyShares (single)                    | ~445K     |
    // | buySharesRange (3, fast path)         | ~535K     |
    // | buySharesRange (3, algebraic)         | ~548K     |
    // | buySharesRange (10, fast path)        | ~239K     |
    // | buySharesRange (10, algebraic)        | ~252K     |
    // | buySharesRange (19, algebraic)        | ~214K     |
    // | sellShares (single)                   | ~79K      |
    // | sellSharesRange (10)                  | ~64K      |
    // | getQuoteForRange (10)                 | ~41K      |
    // | getQuoteForRange (19)                 | ~44K      |
    // | calculateSharesForCost               | ~23K      |
    // | initialize (19 buckets)              | ~6.7M     |
    // | initialize (50 buckets)              | ~8.7M     |
}
