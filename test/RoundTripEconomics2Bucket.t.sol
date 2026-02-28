// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {LMSRMarket} from "../src/LMSRMarket.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";

contract RoundTripEconomics2BucketTest is Test {
    LMSRMarket internal market;
    MockUSDC internal usdc;

    address internal constant CREATOR = address(0xC1);
    address internal constant TRADER = address(0xA1);
    address internal constant PROTOCOL_COLLECTOR = 0x1234567890123456789012345678901234567890;

    uint256 internal constant INITIAL_LIQUIDITY = 10_000_000000; // 10,000 USDC
    uint256 internal constant STARTING_TRADER_USDC = 50_000_000000; // 50,000 USDC
    uint256 internal constant TARGET_SHARES = 10_000000; // 10 shares (6 decimals)

    uint256 internal constant FEE_BPS = 100; // 1%
    uint256 internal constant PROTOCOL_FEE_BPS = 2000; // 20% of fee (0.2% of gross)

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

    struct Snapshot {
        uint256 userUsdc;
        uint256 pool;
        uint256 feesLP;
        uint256 feesProtocol;
        uint256 protocolCollectorUsdc;
        uint256 bucketShares;
    }

    function setUp() public {
        usdc = new MockUSDC();

        uint256[] memory ranges = new uint256[](3);
        ranges[0] = 0;
        ranges[1] = 1;
        ranges[2] = 2;

        market = new LMSRMarket(
            7001,
            CREATOR,
            address(0xFACA),
            address(usdc),
            address(0),
            10_000_000000,
            INITIAL_LIQUIDITY,
            ranges,
            FEE_BPS,
            PROTOCOL_FEE_BPS,
            _defaultMetadata()
        );

        usdc.mint(address(market), INITIAL_LIQUIDITY);
        usdc.mint(TRADER, STARTING_TRADER_USDC);
    }

    function test_report_buy10_and_sell_immediately_table() public {
        uint256 bucketId = 1;

        uint256 grossCostToBuyAtLeast10 = _findGrossCostForTargetShares(bucketId, TARGET_SHARES);

        vm.startPrank(TRADER);
        usdc.approve(address(market), type(uint256).max);

        Snapshot memory s0 = _snapshot(bucketId);
        _logHeader();
        _logRow("0:init", "none", 0, 0, s0, s0);

        uint256 sharesBought = market.buyShares(bucketId, grossCostToBuyAtLeast10, 0);
        Snapshot memory s1 = _snapshot(bucketId);
        _logRow("1:buy", "buyShares", grossCostToBuyAtLeast10, sharesBought, s0, s1);

        assertGe(sharesBought, TARGET_SHARES, "Buy should mint at least 10 shares");

        uint256 payout = market.sellShares(bucketId, TARGET_SHARES, 0);
        Snapshot memory s2 = _snapshot(bucketId);
        _logRow("2:sell", "sellShares", payout, TARGET_SHARES, s1, s2);

        vm.stopPrank();

        int256 netPnL = int256(s2.userUsdc) - int256(s0.userUsdc);
        console2.log(string.concat("summary|netPnLUserUSDC6=", vm.toString(netPnL)));

        assertLe(s2.userUsdc, s0.userUsdc, "Immediate round-trip should not profit user under fees");
        assertGe(s2.feesLP, s0.feesLP, "LP fees should not decrease");
        assertGe(s2.feesProtocol, s0.feesProtocol, "Protocol fees should not decrease");
    }

    function _snapshot(uint256 bucketId) internal view returns (Snapshot memory snap) {
        (uint256 bucketShares,,) = market.buckets(bucketId);

        snap = Snapshot({
            userUsdc: usdc.balanceOf(TRADER),
            pool: market.poolBalance(),
            feesLP: market.feesCollectedLP(),
            feesProtocol: market.feesCollectedProtocol(),
            protocolCollectorUsdc: usdc.balanceOf(PROTOCOL_COLLECTOR),
            bucketShares: bucketShares
        });
    }

    function _logHeader() internal pure {
        console2.log(
            "step|action|amountUSDC6|sharesDeltaUSDC6|userUsdcBefore|userUsdcAfter|userUsdcDelta|poolBefore|poolAfter|poolDelta|feesLPBefore|feesLPAfter|feesLPDelta|feesProtBefore|feesProtAfter|feesProtDelta|collectorBefore|collectorAfter|collectorDelta|bucketSharesBefore|bucketSharesAfter|bucketSharesDelta"
        );
    }

    function _logRow(
        string memory step,
        string memory action,
        uint256 amountUSDC,
        uint256 sharesDelta,
        Snapshot memory beforeSnap,
        Snapshot memory afterSnap
    ) internal view {
        int256 userDelta = int256(afterSnap.userUsdc) - int256(beforeSnap.userUsdc);
        int256 poolDelta = int256(afterSnap.pool) - int256(beforeSnap.pool);
        int256 feeLPDelta = int256(afterSnap.feesLP) - int256(beforeSnap.feesLP);
        int256 feeProtDelta = int256(afterSnap.feesProtocol) - int256(beforeSnap.feesProtocol);
        int256 collectorDelta = int256(afterSnap.protocolCollectorUsdc) - int256(beforeSnap.protocolCollectorUsdc);
        int256 bucketSharesDelta = int256(afterSnap.bucketShares) - int256(beforeSnap.bucketShares);

        string memory line = string.concat(
            step,
            "|",
            action,
            "|",
            vm.toString(amountUSDC),
            "|",
            vm.toString(sharesDelta),
            "|",
            vm.toString(beforeSnap.userUsdc),
            "|",
            vm.toString(afterSnap.userUsdc),
            "|",
            vm.toString(userDelta),
            "|",
            vm.toString(beforeSnap.pool),
            "|",
            vm.toString(afterSnap.pool),
            "|",
            vm.toString(poolDelta),
            "|",
            vm.toString(beforeSnap.feesLP),
            "|",
            vm.toString(afterSnap.feesLP),
            "|",
            vm.toString(feeLPDelta),
            "|",
            vm.toString(beforeSnap.feesProtocol),
            "|",
            vm.toString(afterSnap.feesProtocol),
            "|",
            vm.toString(feeProtDelta),
            "|",
            vm.toString(beforeSnap.protocolCollectorUsdc),
            "|",
            vm.toString(afterSnap.protocolCollectorUsdc),
            "|",
            vm.toString(collectorDelta),
            "|",
            vm.toString(beforeSnap.bucketShares),
            "|",
            vm.toString(afterSnap.bucketShares),
            "|",
            vm.toString(bucketSharesDelta)
        );

        console2.log(line);
    }

    function _findGrossCostForTargetShares(uint256 bucketId, uint256 targetShares) internal view returns (uint256) {
        uint256 low = 1;
        uint256 high = 10_000_000000; // $10k upper search bound

        while (_sharesFromGrossSpend(bucketId, high) < targetShares) {
            high *= 2;
            if (high > 100_000_000000) break;
        }

        for (uint256 i = 0; i < 50; i++) {
            uint256 mid = (low + high) / 2;
            uint256 shares = _sharesFromGrossSpend(bucketId, mid);
            if (shares >= targetShares) {
                high = mid;
            } else {
                low = mid + 1;
            }
        }

        return high;
    }

    function _sharesFromGrossSpend(uint256 bucketId, uint256 grossSpend) internal view returns (uint256) {
        uint256 fees = (grossSpend * market.feeBps()) / 10000;
        uint256 netSpend = grossSpend - fees;
        return market.calculateSharesForCost(bucketId, netSpend);
    }
}
