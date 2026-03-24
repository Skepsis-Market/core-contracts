// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {LMSRMarket} from "../../src/LMSRMarket.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";

/// @notice Handler for fuzzing LP downside under alpha decay.
contract AlphaDecayLossHandler is Test {
    LMSRMarket public market;
    MockUSDC public usdc;
    address[] public traders;

    uint256 public maxWorstCaseLossSeen;
    uint256 public minAvailableForLPSeen = type(uint256).max;

    constructor(LMSRMarket _market, MockUSDC _usdc, address[] memory _traders) {
        market = _market;
        usdc = _usdc;
        traders = _traders;
    }

    function buy(uint256 traderIndex, uint256 bucketId, uint256 amountUSDC) public {
        if (market.status() != LMSRMarket.MarketStatus.ACTIVE) return;

        traderIndex = bound(traderIndex, 0, traders.length - 1);
        bucketId = bound(bucketId, 0, market.bucketCount() - 1);
        amountUSDC = bound(amountUSDC, 10_000000, 2_000_000000); // $10 to $2,000

        address trader = traders[traderIndex];
        if (usdc.balanceOf(trader) < amountUSDC) {
            usdc.mint(trader, amountUSDC * 3);
        }

        uint256 lower = market.marketMin() + (bucketId * market.bucketWidth());
        uint256 upper = lower + market.bucketWidth();

        vm.startPrank(trader);
        usdc.approve(address(market), amountUSDC);
        try market.buySharesRange(lower, upper, amountUSDC, 0, 0, address(0)) {} catch {}
        vm.stopPrank();

        _updateLossObservations();
    }

    function buyRange(uint256 traderIndex, uint256 startBucket, uint256 width, uint256 amountUSDC) public {
        if (market.status() != LMSRMarket.MarketStatus.ACTIVE) return;

        traderIndex = bound(traderIndex, 0, traders.length - 1);
        startBucket = bound(startBucket, 0, market.bucketCount() - 1);
        width = bound(width, 1, market.bucketCount() - startBucket);
        amountUSDC = bound(amountUSDC, 10_000000, 1_500_000000); // $10 to $1,500

        uint256 rangeLower = startBucket;
        uint256 rangeUpper = startBucket + width;

        address trader = traders[traderIndex];
        if (usdc.balanceOf(trader) < amountUSDC) {
            usdc.mint(trader, amountUSDC * 3);
        }

        vm.startPrank(trader);
        usdc.approve(address(market), amountUSDC);
        try market.buySharesRange(rangeLower, rangeUpper, amountUSDC, 0, 0, address(0)) {} catch {}
        vm.stopPrank();

        _updateLossObservations();
    }

    function warpAndSync(uint256 secondsForward) public {
        if (market.status() != LMSRMarket.MarketStatus.ACTIVE) return;

        secondsForward = bound(secondsForward, 30 minutes, 3 days);
        vm.warp(block.timestamp + secondsForward + market.ALPHA_EPOCH_LENGTH() + 1);

        try market.syncAlpha() {} catch {}

        _updateLossObservations();
    }

    function resolveAtMaxLiability() public {
        if (market.status() != LMSRMarket.MarketStatus.ACTIVE) return;

        uint256 winner = _maxLiabilityBucket();
        vm.prank(address(0xC1));
        try market.resolveMarket(winner) {} catch {}

        _updateLossObservations();
    }

    function _maxLiabilityBucket() internal view returns (uint256 winner) {
        uint256 maxShares = 0;
        for (uint256 i = 0; i < market.bucketCount(); i++) {
            (uint256 shares,,) = market.buckets(i);
            if (shares > maxShares) {
                maxShares = shares;
                winner = i;
            }
        }
    }

    function _updateLossObservations() internal {
        uint256 pool = market.poolBalance();
        uint256 liability = _maxLiability();

        if (pool >= liability) {
            uint256 availableForLP = pool - liability;
            if (availableForLP < minAvailableForLPSeen) {
                minAvailableForLPSeen = availableForLP;
            }

            uint256 initialDeposit = market.initialDeposit();
            uint256 worstCaseLoss = initialDeposit > availableForLP ? initialDeposit - availableForLP : 0;
            if (worstCaseLoss > maxWorstCaseLossSeen) {
                maxWorstCaseLossSeen = worstCaseLoss;
            }
        }
    }

    function _maxLiability() internal view returns (uint256 maxShares) {
        for (uint256 i = 0; i < market.bucketCount(); i++) {
            (uint256 shares,,) = market.buckets(i);
            if (shares > maxShares) {
                maxShares = shares;
            }
        }
    }
}

/// @notice Invariants around LP downside under alpha decay.
/// @dev Worst-case LP loss is measured as: initialDeposit - (poolBalance - maxLiability).
contract AlphaDecayLPLossInvariantTest is StdInvariant, Test {
    LMSRMarket public market;
    MockUSDC public usdc;
    AlphaDecayLossHandler public handler;

    address internal constant CREATOR = address(0xC1);
    uint256 internal constant INITIAL_LIQUIDITY = 10_000_000000;

    address[] internal traders;

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

        uint256[] memory bucketRanges = new uint256[](11);
        for (uint256 i = 0; i <= 10; i++) {
            bucketRanges[i] = i;
        }

        market = new LMSRMarket(
            91001,
            CREATOR,
            address(0xFACA),
            address(usdc),
            address(0),
            3_333_333333,
            INITIAL_LIQUIDITY,
            bucketRanges,
            0,
            0,
            _defaultMetadata(),
            address(0xFEE)
        );

        usdc.mint(address(market), INITIAL_LIQUIDITY);

        uint256 alphaFloor = (market.alphaInitial() * 30) / 100;
        vm.prank(CREATOR);
        market.configureAlphaDecay(alphaFloor, block.timestamp, 10 days);

        for (uint256 i = 0; i < 6; i++) {
            traders.push(address(uint160(0x3000 + i)));
        }

        handler = new AlphaDecayLossHandler(market, usdc, traders);

        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = handler.buy.selector;
        selectors[1] = handler.buyRange.selector;
        selectors[2] = handler.warpAndSync.selector;
        selectors[3] = handler.resolveAtMaxLiability.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @notice Invariant: market remains solvent under alpha decay.
    function invariant_decayScenarioRemainsSolvent() public view {
        uint256 pool = market.poolBalance();
        uint256 liability = _maxLiability();

        assertLe(liability, pool + market.SOLVENCY_DUST(), "Solvency invariant violated under decay");
    }

    /// @notice Invariant: maximum LP loss cannot exceed initial deposit.
    /// @dev Equivalent to available-for-LP being non-negative in all reachable states.
    function invariant_maxLpLossBoundedByInitialDeposit() public view {
        uint256 pool = market.poolBalance();
        uint256 liability = _maxLiability();

        assertGe(pool + market.SOLVENCY_DUST(), liability, "State insolvent; LP loss bound undefined");

        uint256 availableForLP = pool > liability ? pool - liability : 0;
        uint256 initialDeposit = market.initialDeposit();
        uint256 worstCaseLoss = initialDeposit > availableForLP ? initialDeposit - availableForLP : 0;

        assertLe(worstCaseLoss, initialDeposit, "LP worst-case loss exceeds initial deposit");
    }

    /// @notice Invariant: if resolved, reported LP profitability cannot be less than -100%.
    function invariant_resolvedProfitabilityFloor() public view {
        if (market.status() != LMSRMarket.MarketStatus.RESOLVED) return;

        (int256 unrealizedProfit,,) = market.getLPProfitability();
        int256 floor = -int256(market.initialDeposit());

        assertGe(unrealizedProfit, floor, "Resolved LP profitability breached -100% floor");
    }

    function invariant_logDecayLossStats() public view {
        console.log("=== Alpha Decay LP Loss Stats ===");
        console.log("alpha current:", market.alpha());
        console.log("pool balance:", market.poolBalance());
        console.log("max liability:", _maxLiability());
        console.log("handler max worst-case loss seen:", handler.maxWorstCaseLossSeen());
        console.log("handler min availableForLP seen:", handler.minAvailableForLPSeen());
        console.log("================================");
    }

    function _maxLiability() internal view returns (uint256 maxShares) {
        for (uint256 i = 0; i < market.bucketCount(); i++) {
            (uint256 shares,,) = market.buckets(i);
            if (shares > maxShares) {
                maxShares = shares;
            }
        }
    }
}
