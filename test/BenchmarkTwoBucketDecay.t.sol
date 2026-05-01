// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {LMSRMarket} from "../src/LMSRMarket.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {FixedPointMath} from "../src/FixedPointMath.sol";

/// @notice Benchmark test for 2-bucket LMSR behavior with decay and solvency checks.
/// @dev Target checks:
///      - Initial pricing near 50/50
///      - After trades, bucket 1 price near 70%
///      - 1-share cost tracks probability within 1%
///      - Decay increases slippage for same spend
///      - Solvency invariant holds throughout
contract BenchmarkTwoBucketDecayTest is Test {
    using FixedPointMath for uint256;

    LMSRMarket internal market;
    MockUSDC internal usdc;

    address internal creator = address(0xC1);
    address internal trader = address(0xA1);

    uint256 internal constant INITIAL_LIQUIDITY = 10_000_000000; // $10,000
    uint256 internal constant ONE_SHARE = 1_000000; // 1 share in 6 decimals
    uint256 internal constant ONE_PERCENT_WAD = 0.01e18;

    function _buyBucket(uint256 bucketId, uint256 amount, uint256 minShares) internal returns (uint256) {
        uint256 lower = bucketId * market.bucketWidth();
        (uint256 _bs,,,,,) = market.buySharesRange(lower, lower + market.bucketWidth(), amount, minShares, 0, address(0)); return _bs;
    }
    function _sellBucket(uint256 bucketId, uint256 shares, uint256 minPayout) internal returns (uint256) {
        uint256 lower = bucketId * market.bucketWidth();
        (uint256 _ss,,,) = market.sellSharesRange(lower, lower + market.bucketWidth(), shares, minPayout, address(0)); return _ss;
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

        (uint256[] memory seedIds, uint256[] memory seedShares) = _uniformSeeds(2, INITIAL_LIQUIDITY);

        market = new LMSRMarket(LMSRMarket.InitParams({
                marketId: 1,
                creator: creator,
                factory: address(0xFACA),
                usdcToken: address(usdc),
                positionNFT: address(0),
                alpha: 10_000_000000,
                poolBalance: INITIAL_LIQUIDITY,
                bucketWidth: 1,
                maxBucketId: // bucketWidth
            1,
                seededBucketIds: // maxBucketId
            seedIds,
                seededShares: seedShares,
                feeBps: 0,
                protocolFeeBps: // feeBps = 0 for pure math benchmark
            0,
                metadata: // protocolFeeBps = 0
            _defaultMetadata(),
                protocolFeeCollector: address(0xFEE)
            }));

        // Seed initial liquidity
        usdc.mint(address(market), INITIAL_LIQUIDITY);

        // Fund trader for directional moves
        usdc.mint(trader, 100_000_000000);

        // Configure 10-day decay
        uint256 alphaFloor = (market.alphaInitial() * 30) / 100;
        vm.prank(creator);
        market.configureAlphaDecay(alphaFloor, block.timestamp, 10 days);
    }

    function test_initial_50_50_pricing() public view {
        uint256 p0 = _spotProbability(0);
        uint256 p1 = _spotProbability(1);

        assertApproxEqAbs(p0, 0.5e18, ONE_PERCENT_WAD, "Bucket 0 should start near 50%");
        assertApproxEqAbs(p1, 0.5e18, ONE_PERCENT_WAD, "Bucket 1 should start near 50%");
        assertApproxEqAbs(p0 + p1, 1e18, ONE_PERCENT_WAD, "Probabilities should sum to ~1");

        uint256 oneShareCost = _costForOneShare(0); // in USDC 6 decimals
        uint256 impliedFromProb = (p0 * 1_000000) / 1e18;

        assertApproxEqAbs(
            oneShareCost,
            impliedFromProb,
            10_000, // 1% of $1 = $0.01 => 10_000 in 6 decimals
            "1-share cost should track ~50c at 50%"
        );
    }

    function test_shift_to_70_probability_and_price_alignment() public {
        _pushProbabilityToTarget(1, 0.70e18, 0.69e18, 0.71e18);

        uint256 p1 = _spotProbability(1);
        uint256 p0 = _spotProbability(0);

        assertGe(p1, 0.69e18, "Bucket 1 should be >= 69%");
        assertLe(p1, 0.71e18, "Bucket 1 should be <= 71%");
        assertApproxEqAbs(p0 + p1, 1e18, ONE_PERCENT_WAD, "Probabilities should sum to ~1");

        uint256 oneShareCost = _costForOneShare(1);
        uint256 impliedFromProb = (p1 * 1_000000) / 1e18;

        assertApproxEqAbs(
            oneShareCost,
            impliedFromProb,
            10_000, // ±$0.01 tolerance
            "1-share cost should track ~70c at 70%"
        );

        _assertSolvency();
    }

    function test_decay_increases_slippage_for_same_spend() public {
        _pushProbabilityToTarget(1, 0.70e18, 0.69e18, 0.71e18);

        uint256 spend = 100_000000; // $100
        uint256 sharesNow = market.calculateSharesForCost(1, spend);
        uint256 costOneNow = _costForOneShare(1);

        vm.warp(block.timestamp + 9 days + market.ALPHA_EPOCH_LENGTH() + 1);
        market.syncAlpha();

        uint256 sharesLate = market.calculateSharesForCost(1, spend);
        uint256 costOneLate = _costForOneShare(1);

        assertLt(sharesLate, sharesNow, "Same spend should buy fewer shares after decay");
        assertGt(costOneLate, costOneNow, "1-share cost should increase after decay");

        _assertSolvency();
    }

    function test_trace_probability_price_shift_table() public {
        uint256 bucketId = 1;
        uint256 stepSpend = 100_000000; // $100
        uint256 cumulativeSpend = 0;
        uint256 maxIterations = 200;

        vm.startPrank(trader);
        usdc.approve(address(market), type(uint256).max);

        console2.log("step,cumulativeSpendUSDC6,pBucket1Wad,costOneShareUSDC6,sharesMintedUSDC6,bucket1SharesUSDC6,poolBalanceUSDC6,alphaUSDC6,tx");

        _logTableRow(0, cumulativeSpend, 0, "init");

        for (uint256 step = 1; step <= maxIterations; step++) {
            uint256 pBefore = _spotProbability(bucketId);
            if (pBefore >= 0.69e18 && pBefore <= 0.71e18) {
                break;
            }

            uint256 sharesMinted = _buyBucket(bucketId, stepSpend, 0);
            cumulativeSpend += stepSpend;
            _logTableRow(step, cumulativeSpend, sharesMinted, "buyShares(1,100e6,0)");
        }

        vm.stopPrank();

        uint256 pFinal = _spotProbability(bucketId);
        assertGe(pFinal, 0.69e18, "Final bucket 1 probability should be >= 69%");
        assertLe(pFinal, 0.71e18, "Final bucket 1 probability should be <= 71%");
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────────────

    function _spotProbability(uint256 bucketId) internal view returns (uint256) {
        (uint256 shares,,,) = market.buckets(bucketId);
        uint256 ratio = ((shares + market.PHANTOM_SHARES()) * market.WAD()) / market.alpha();
        uint256 bucketExp = ratio.exp();
        uint256 sumExp = _computeSumExp();
        return (bucketExp * 1e18) / sumExp;
    }

    function _computeSumExp() internal view returns (uint256 sumExp) {
        uint256 n = market.bucketCount();
        for (uint256 i = 0; i < n; i++) {
            (uint256 s,,,) = market.buckets(i);
            uint256 r = ((s + market.PHANTOM_SHARES()) * market.WAD()) / market.alpha();
            sumExp += r.exp();
        }
    }

    function _costForOneShare(uint256 bucketId) internal view returns (uint256) {
        uint256 low = 1;
        uint256 high = 1_000000; // start at $1

        while (market.calculateSharesForCost(bucketId, high) < ONE_SHARE) {
            high *= 2;
            if (high > 100_000000) break; // safety cap ($100)
        }

        for (uint256 i = 0; i < 40; i++) {
            uint256 mid = (low + high) / 2;
            uint256 out = market.calculateSharesForCost(bucketId, mid);
            if (out >= ONE_SHARE) {
                high = mid;
            } else {
                low = mid + 1;
            }
        }

        return high;
    }

    function _pushProbabilityToTarget(
        uint256 bucketId,
        uint256 target,
        uint256 lower,
        uint256 upper
    ) internal {
        vm.startPrank(trader);
        usdc.approve(address(market), type(uint256).max);

        uint256 maxIterations = 200;
        uint256 i = 0;
        while (i < maxIterations) {
            uint256 p = _spotProbability(bucketId);
            if (p >= lower && p <= upper) break;

            if (p < target) {
                _buyBucket(bucketId, 100_000000, 0); // $100 step
            } else {
                break;
            }
            i++;
        }

        vm.stopPrank();
    }

    function _assertSolvency() internal view {
        uint256 maxShares = 0;
        uint256 buckets = market.bucketCount();
        for (uint256 i = 0; i < buckets; i++) {
            (uint256 shares,,,) = market.buckets(i);
            if (shares > maxShares) {
                maxShares = shares;
            }
        }

        assertLe(maxShares, market.poolBalance() + market.SOLVENCY_DUST(), "Solvency invariant must hold");
    }

    function _logTableRow(uint256 step, uint256 cumulativeSpend, uint256 sharesMinted, string memory txLabel) internal view {
        uint256 p1 = _spotProbability(1);
        uint256 costOne = _costForOneShare(1);
        (uint256 bucket1Shares,,,) = market.buckets(1);

        string memory line = string.concat(
            vm.toString(step), ",",
            vm.toString(cumulativeSpend), ",",
            vm.toString(p1), ",",
            vm.toString(costOne), ",",
            vm.toString(sharesMinted), ",",
            vm.toString(bucket1Shares), ",",
            vm.toString(market.poolBalance()), ",",
            vm.toString(market.alpha()), ",",
            txLabel
        );

        console2.log(line);
    }
}
