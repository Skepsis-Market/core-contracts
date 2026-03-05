// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {LMSRMarket} from "../src/LMSRMarket.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {FixedPointMath} from "../src/FixedPointMath.sol";

/// @notice Diversified buy benchmark for 2/5/10 bucket markets.
/// @dev Produces an execution report through logs for pricing shifts, liability, and solvency margin.
contract BenchmarkDiversifiedBucketsTest is Test {
    using FixedPointMath for uint256;

    struct ScenarioSummary {
        uint256 pool;
        uint256 liability;
        uint256 margin;
        uint256 maxProb;
        uint256 minProb;
        uint256 alpha;
    }

    address internal constant CREATOR = address(0xC1);
    address internal constant TRADER = address(0xA1);

    uint256 internal constant INITIAL_LIQUIDITY = 10_000_000000; // $10,000
    uint256 internal constant TRADER_BANKROLL = 250_000_000000; // $250,000

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

    function test_report_diversified_buys_2_5_10() public {
        _runScenario2Buckets();
        _runScenario5Buckets();
        _runScenario10Buckets();
    }

    function test_report_fixed_vs_decay_5b() public {
        (LMSRMarket fixedMarket, MockUSDC fixedUsdc) = _deployMarket(5, 5501);
        (LMSRMarket decayMarket, MockUSDC decayUsdc) = _deployMarket(5, 5502);

        uint256 alphaFloor = (decayMarket.alphaInitial() * 30) / 100;
        vm.prank(CREATOR);
        decayMarket.configureAlphaDecay(alphaFloor, block.timestamp, 10 days);

        console2.log("compare=5b_fixed_vs_decay,header=mode|poolUSDC6|liabilityUSDC6|marginUSDC6|maxProbWad|minProbWad|alphaUSDC6");

        ScenarioSummary memory fixedSummary = _runFiveBucketDiversifiedScript(
            "5b-fixed",
            fixedMarket,
            fixedUsdc,
            false
        );

        ScenarioSummary memory decaySummary = _runFiveBucketDiversifiedScript(
            "5b-decay",
            decayMarket,
            decayUsdc,
            true
        );

        _logSummary("fixed", fixedSummary);
        _logSummary("decay", decaySummary);

        assertLt(decaySummary.alpha, fixedSummary.alpha, "Decay alpha should be lower than fixed alpha");
        assertGe(decaySummary.maxProb, fixedSummary.maxProb, "Decay should sharpen the top probability");
        assertLe(decaySummary.minProb, fixedSummary.minProb, "Decay should push tail probabilities lower");
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Scenario: 2 buckets
    // ─────────────────────────────────────────────────────────────────────────────

    function _runScenario2Buckets() internal {
        (LMSRMarket market, MockUSDC usdc) = _deployMarket(2, 2001);

        vm.startPrank(TRADER);
        usdc.approve(address(market), type(uint256).max);

        console2.log("scenario=2b,header=step|tx|amountUSDC6|sharesOutUSDC6|maxProbWad|minProbWad|poolUSDC6|liabilityUSDC6|marginUSDC6");
        _logScenarioState("2b", market, 0, "init", 0, 0);

        uint256 out;
        out = market.buyShares(0, 250_000000, 0);
        _logScenarioState("2b", market, 1, "single:b0", 250_000000, out);

        out = market.buyShares(1, 300_000000, 0);
        _logScenarioState("2b", market, 2, "single:b1", 300_000000, out);

        out = market.buySharesRange(0, 2, 400_000000, 0, 0); // 2-bucket range
        _logScenarioState("2b", market, 3, "range:0-2(len2)", 400_000000, out);

        out = market.buyShares(1, 500_000000, 0);
        _logScenarioState("2b", market, 4, "single:b1", 500_000000, out);

        out = market.buySharesRange(0, 2, 350_000000, 0, 0);
        _logScenarioState("2b", market, 5, "range:0-2(len2)", 350_000000, out);

        vm.stopPrank();

        _logFinalDistribution("2b", market);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Scenario: 5 buckets
    // ─────────────────────────────────────────────────────────────────────────────

    function _runScenario5Buckets() internal {
        (LMSRMarket market, MockUSDC usdc) = _deployMarket(5, 5001);

        vm.startPrank(TRADER);
        usdc.approve(address(market), type(uint256).max);

        console2.log("scenario=5b,header=step|tx|amountUSDC6|sharesOutUSDC6|maxProbWad|minProbWad|poolUSDC6|liabilityUSDC6|marginUSDC6");
        _logScenarioState("5b", market, 0, "init", 0, 0);

        uint256 out;
        out = market.buyShares(1, 200_000000, 0);
        _logScenarioState("5b", market, 1, "single:b1", 200_000000, out);

        out = market.buySharesRange(1, 3, 250_000000, 0, 0); // len 2
        _logScenarioState("5b", market, 2, "range:1-3(len2)", 250_000000, out);

        out = market.buySharesRange(0, 3, 300_000000, 0, 0); // len 3
        _logScenarioState("5b", market, 3, "range:0-3(len3)", 300_000000, out);

        out = market.buyShares(4, 350_000000, 0);
        _logScenarioState("5b", market, 4, "single:b4", 350_000000, out);

        out = market.buySharesRange(1, 5, 400_000000, 0, 0); // len 4
        _logScenarioState("5b", market, 5, "range:1-5(len4)", 400_000000, out);

        out = market.buySharesRange(0, 5, 500_000000, 0, 0); // len 5
        _logScenarioState("5b", market, 6, "range:0-5(len5)", 500_000000, out);

        vm.stopPrank();

        _logFinalDistribution("5b", market);
    }

    function _runFiveBucketDiversifiedScript(
        string memory scenario,
        LMSRMarket market,
        MockUSDC usdc,
        bool withDecay
    ) internal returns (ScenarioSummary memory summary) {
        vm.startPrank(TRADER);
        usdc.approve(address(market), type(uint256).max);

        console2.log(string.concat("scenario=", scenario, ",header=step|tx|amountUSDC6|sharesOutUSDC6|maxProbWad|minProbWad|poolUSDC6|liabilityUSDC6|marginUSDC6|alphaUSDC6"));
        _logScenarioStateWithAlpha(scenario, market, 0, "init", 0, 0);

        uint256 out;
        out = market.buyShares(1, 200_000000, 0);
        _logScenarioStateWithAlpha(scenario, market, 1, "single:b1", 200_000000, out);
        if (withDecay) _advanceDecayOneDay(market);

        out = market.buySharesRange(1, 3, 250_000000, 0, 0); // len 2
        _logScenarioStateWithAlpha(scenario, market, 2, "range:1-3(len2)", 250_000000, out);
        if (withDecay) _advanceDecayOneDay(market);

        out = market.buySharesRange(0, 3, 300_000000, 0, 0); // len 3
        _logScenarioStateWithAlpha(scenario, market, 3, "range:0-3(len3)", 300_000000, out);
        if (withDecay) _advanceDecayOneDay(market);

        out = market.buyShares(4, 350_000000, 0);
        _logScenarioStateWithAlpha(scenario, market, 4, "single:b4", 350_000000, out);
        if (withDecay) _advanceDecayOneDay(market);

        out = market.buySharesRange(1, 5, 400_000000, 0, 0); // len 4
        _logScenarioStateWithAlpha(scenario, market, 5, "range:1-5(len4)", 400_000000, out);
        if (withDecay) _advanceDecayOneDay(market);

        out = market.buySharesRange(0, 5, 500_000000, 0, 0); // len 5
        _logScenarioStateWithAlpha(scenario, market, 6, "range:0-5(len5)", 500_000000, out);

        vm.stopPrank();

        _logFinalDistribution(scenario, market);
        summary = _buildSummary(market);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Scenario: 10 buckets
    // ─────────────────────────────────────────────────────────────────────────────

    function _runScenario10Buckets() internal {
        (LMSRMarket market, MockUSDC usdc) = _deployMarket(10, 10001);

        vm.startPrank(TRADER);
        usdc.approve(address(market), type(uint256).max);

        console2.log("scenario=10b,header=step|tx|amountUSDC6|sharesOutUSDC6|maxProbWad|minProbWad|poolUSDC6|liabilityUSDC6|marginUSDC6");
        _logScenarioState("10b", market, 0, "init", 0, 0);

        uint256 out;
        out = market.buyShares(2, 150_000000, 0);
        _logScenarioState("10b", market, 1, "single:b2", 150_000000, out);

        out = market.buySharesRange(2, 4, 180_000000, 0, 0); // len 2
        _logScenarioState("10b", market, 2, "range:2-4(len2)", 180_000000, out);

        out = market.buySharesRange(4, 7, 220_000000, 0, 0); // len 3
        _logScenarioState("10b", market, 3, "range:4-7(len3)", 220_000000, out);

        out = market.buySharesRange(1, 5, 260_000000, 0, 0); // len 4
        _logScenarioState("10b", market, 4, "range:1-5(len4)", 260_000000, out);

        out = market.buySharesRange(3, 8, 300_000000, 0, 0); // len 5
        _logScenarioState("10b", market, 5, "range:3-8(len5)", 300_000000, out);

        out = market.buyShares(9, 350_000000, 0);
        _logScenarioState("10b", market, 6, "single:b9", 350_000000, out);

        out = market.buySharesRange(0, 5, 280_000000, 0, 0); // len 5
        _logScenarioState("10b", market, 7, "range:0-5(len5)", 280_000000, out);

        vm.stopPrank();

        _logFinalDistribution("10b", market);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────────────

    function _deployMarket(uint256 bucketCount, uint256 marketId)
        internal
        returns (LMSRMarket market, MockUSDC usdc)
    {
        usdc = new MockUSDC();

        uint256[] memory ranges = new uint256[](bucketCount + 1);
        for (uint256 i = 0; i <= bucketCount; i++) {
            ranges[i] = i;
        }

        market = new LMSRMarket(
            marketId,
            CREATOR,
            address(0xFACA),
            address(usdc),
            address(0),
            INITIAL_LIQUIDITY / _isqrt(bucketCount),
            INITIAL_LIQUIDITY,
            ranges,
            0,
            0,
            _defaultMetadata(),
            address(0xFEE)
        );

        usdc.mint(address(market), INITIAL_LIQUIDITY);
        usdc.mint(TRADER, TRADER_BANKROLL);
    }

    function _isqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;
        if (x <= 3) return 1;
        uint256 z = (x + 1) / 2;
        uint256 y = x;
        while (z < y) { y = z; z = (x / z + z) / 2; }
        return y;
    }

    function _logScenarioState(
        string memory scenario,
        LMSRMarket market,
        uint256 step,
        string memory txLabel,
        uint256 amountUSDC,
        uint256 sharesOut
    ) internal view {
        (uint256 maxProb, uint256 minProb) = _probabilityBounds(market);
        uint256 liability = _liability(market);
        uint256 pool = market.poolBalance();
        uint256 margin = pool > liability ? pool - liability : 0;

        _assertSolvent(market);

        string memory line = string.concat(
            "scenario=", scenario,
            "|step=", vm.toString(step),
            "|tx=", txLabel,
            "|amountUSDC6=", vm.toString(amountUSDC),
            "|sharesOutUSDC6=", vm.toString(sharesOut),
            "|maxProbWad=", vm.toString(maxProb),
            "|minProbWad=", vm.toString(minProb),
            "|poolUSDC6=", vm.toString(pool),
            "|liabilityUSDC6=", vm.toString(liability),
            "|marginUSDC6=", vm.toString(margin)
        );

        console2.log(line);
    }

    function _logFinalDistribution(string memory scenario, LMSRMarket market) internal view {
        uint256 buckets = market.bucketCount();
        for (uint256 i = 0; i < buckets; i++) {
            uint256 p = _spotProbability(market, i);
            (uint256 shares,,) = market.buckets(i);
            string memory line = string.concat(
                "final=", scenario,
                "|bucket=", vm.toString(i),
                "|probWad=", vm.toString(p),
                "|sharesUSDC6=", vm.toString(shares)
            );
            console2.log(line);
        }
    }

    function _probabilityBounds(LMSRMarket market) internal view returns (uint256 maxProb, uint256 minProb) {
        uint256 buckets = market.bucketCount();
        maxProb = 0;
        minProb = type(uint256).max;

        for (uint256 i = 0; i < buckets; i++) {
            uint256 p = _spotProbability(market, i);
            if (p > maxProb) maxProb = p;
            if (p < minProb) minProb = p;
        }
    }

    function _spotProbability(LMSRMarket market, uint256 bucketId) internal view returns (uint256) {
        (uint256 shares,,) = market.buckets(bucketId);
        uint256 ratio = ((shares + market.PHANTOM_SHARES()) * market.WAD()) / market.alpha();
        uint256 bucketExp = ratio.exp();
        uint256 sumExp = market.getCachedSumExp();
        return (bucketExp * 1e18) / sumExp;
    }

    function _liability(LMSRMarket market) internal view returns (uint256 maxShares) {
        uint256 buckets = market.bucketCount();
        for (uint256 i = 0; i < buckets; i++) {
            (uint256 shares,,) = market.buckets(i);
            if (shares > maxShares) {
                maxShares = shares;
            }
        }
    }

    function _assertSolvent(LMSRMarket market) internal view {
        uint256 liability = _liability(market);
        assertLe(liability, market.poolBalance() + market.SOLVENCY_DUST(), "Solvency invariant must hold");
    }

    function _logScenarioStateWithAlpha(
        string memory scenario,
        LMSRMarket market,
        uint256 step,
        string memory txLabel,
        uint256 amountUSDC,
        uint256 sharesOut
    ) internal view {
        (uint256 maxProb, uint256 minProb) = _probabilityBounds(market);
        uint256 liability = _liability(market);
        uint256 pool = market.poolBalance();
        uint256 margin = pool > liability ? pool - liability : 0;

        _assertSolvent(market);

        string memory line = string.concat(
            "scenario=", scenario,
            "|step=", vm.toString(step),
            "|tx=", txLabel,
            "|amountUSDC6=", vm.toString(amountUSDC),
            "|sharesOutUSDC6=", vm.toString(sharesOut),
            "|maxProbWad=", vm.toString(maxProb),
            "|minProbWad=", vm.toString(minProb),
            "|poolUSDC6=", vm.toString(pool),
            "|liabilityUSDC6=", vm.toString(liability),
            "|marginUSDC6=", vm.toString(margin),
            "|alphaUSDC6=", vm.toString(market.alpha())
        );

        console2.log(line);
    }

    function _advanceDecayOneDay(LMSRMarket market) internal {
        vm.warp(block.timestamp + 1 days + market.ALPHA_EPOCH_LENGTH() + 1);
        market.syncAlpha();
    }

    function _buildSummary(LMSRMarket market) internal view returns (ScenarioSummary memory summary) {
        (uint256 maxProb, uint256 minProb) = _probabilityBounds(market);
        uint256 liability = _liability(market);
        uint256 pool = market.poolBalance();
        uint256 margin = pool > liability ? pool - liability : 0;

        summary = ScenarioSummary({
            pool: pool,
            liability: liability,
            margin: margin,
            maxProb: maxProb,
            minProb: minProb,
            alpha: market.alpha()
        });
    }

    function _logSummary(string memory mode, ScenarioSummary memory summary) internal view {
        string memory line = string.concat(
            "compare=5b_fixed_vs_decay|mode=", mode,
            "|poolUSDC6=", vm.toString(summary.pool),
            "|liabilityUSDC6=", vm.toString(summary.liability),
            "|marginUSDC6=", vm.toString(summary.margin),
            "|maxProbWad=", vm.toString(summary.maxProb),
            "|minProbWad=", vm.toString(summary.minProb),
            "|alphaUSDC6=", vm.toString(summary.alpha)
        );
        console2.log(line);
    }
}
