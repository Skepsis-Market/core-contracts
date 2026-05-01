// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {LMSRMarket} from "../src/LMSRMarket.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";

/// @title Range Economics Walkthrough
/// @notice Step-by-step demonstration of range position economics:
///
///   Scenario:
///   1. User buys range position for $100, gets X shares → sells HALF → what happens to $?
///   2. User buys ANOTHER $100 on the same range → what's the current value of position #1 vs #2?
///
///   This test prints a full accounting table at every step so you can follow the money.
contract RangeEconomicsWalkthroughTest is Test {
    LMSRMarket internal market;
    MockUSDC internal usdc;

    address internal constant CREATOR  = address(0xC1);
    address internal constant TRADER   = address(0xA1);
    address internal constant FEE_RECV = address(0xFEE);

    // ── Market parameters ──────────────────────────────────────────────
    uint256 internal constant POOL         = 10_000_000000;  // $10,000 initial liquidity
    uint256 internal constant BUCKET_COUNT = 100;            // 100 buckets
    uint256 internal constant FEE_BPS      = 50;             // 0.5% fee
    uint256 internal constant PROTO_BPS    = 2000;           // 20% of fee → protocol

    // ── Trade parameters ───────────────────────────────────────────────
    // Range: $114,500 → $114,800 (3 buckets: 45, 46, 47)
    uint256 internal constant RANGE_LO     = 114500;
    uint256 internal constant RANGE_HI     = 114800;
    uint256 internal constant BUY_AMOUNT   = 100_000000;     // $100

    function _meta() internal pure returns (LMSRMarket.MarketMetadata memory) {
        return LMSRMarket.MarketMetadata({
            name: "BTC Price EOY",
            description: "Where will BTC close?",
            resolutionCriteria: "CoinGecko 31 Dec UTC",
            valueUnit: "USD",
            resolver: address(0),
            biddingDeadline: 0,
            scheduledResolutionTime: 0,
            minBetSize: 0
        });
    }

    // ── Snapshot struct ────────────────────────────────────────────────
    struct Snap {
        uint256 traderUsdc;
        uint256 pool;
        uint256 feesLP;
        uint256 feesProt;
        uint256 alpha;
        uint256 totalVol;
        uint256 sharesBkt1145;
        uint256 sharesBkt1146;
        uint256 sharesBkt1147;
    }

    function _snap() internal view returns (Snap memory s) {
        (uint256 s1145,,,) = market.buckets(1145);
        (uint256 s1146,,,) = market.buckets(1146);
        (uint256 s1147,,,) = market.buckets(1147);
        s = Snap({
            traderUsdc: usdc.balanceOf(TRADER),
            pool:       market.poolBalance(),
            feesLP:     market.feesCollectedLP(),
            feesProt:   market.feesCollectedProtocol(),
            alpha:      market.alpha(),
            totalVol:   market.totalVolume(),
            sharesBkt1145: s1145,
            sharesBkt1146: s1146,
            sharesBkt1147: s1147
        });
    }

    // ── Setup ──────────────────────────────────────────────────────────
    function setUp() public {
        usdc = new MockUSDC();

        // 100 buckets at absolute IDs 1100-1199, width=100
        uint256 bw = 100;
        uint256 maxBid = 1199;
        uint256[] memory seedIds = new uint256[](BUCKET_COUNT);
        uint256[] memory seedShares = new uint256[](BUCKET_COUNT);
        uint256 perBucket = POOL / BUCKET_COUNT;
        for (uint256 i = 0; i < BUCKET_COUNT; i++) {
            seedIds[i] = 1100 + i;
            seedShares[i] = perBucket;
        }
        seedShares[BUCKET_COUNT - 1] += POOL - (perBucket * BUCKET_COUNT);

        usdc.mint(CREATOR, POOL);
        vm.startPrank(CREATOR);
        usdc.approve(address(this), POOL);
        market = new LMSRMarket(LMSRMarket.InitParams({
            marketId: 1,
            creator: CREATOR,
            factory: address(0xFACE),
            usdcToken: address(usdc),
            positionNFT: address(0),
            alpha: 1_000_000000,
            poolBalance: POOL,
            bucketWidth: bw,
            maxBucketId: maxBid,
            seededBucketIds: seedIds,
            seededShares: seedShares,
            feeBps: FEE_BPS,
            protocolFeeBps: PROTO_BPS,
            metadata: _meta(),
            protocolFeeCollector: FEE_RECV
        }));
        usdc.transfer(address(market), POOL);
        vm.stopPrank();

        // Fund trader with $10,000
        usdc.mint(TRADER, 10_000_000000);
    }

    // ════════════════════════════════════════════════════════════════════
    //  THE MAIN TEST -Full walkthrough with commentary
    // ════════════════════════════════════════════════════════════════════
    function test_rangeEconomics_fullWalkthrough() public {
        vm.startPrank(TRADER);
        usdc.approve(address(market), type(uint256).max);

        // ────────────────────────────────────────────────────────────────
        // STEP 0: Initial state
        // ────────────────────────────────────────────────────────────────
        Snap memory s0 = _snap();
        _header("STEP 0: INITIAL STATE");
        _printSnap(s0);
        _printQuote("Initial quote for $100 on range");

        // ────────────────────────────────────────────────────────────────
        // STEP 1: Buy $100 on range [114500, 114800) → get X shares
        // ────────────────────────────────────────────────────────────────
        _header("STEP 1: BUY $100 on range [114500, 114800)");

        (uint256 sharesStep1,,,,,) = market.buySharesRange(
            RANGE_LO, RANGE_HI, BUY_AMOUNT, 0, 0, address(0)
        );

        Snap memory s1 = _snap();
        _printSnap(s1);

        // Accounting
        uint256 feePaid1 = (BUY_AMOUNT * FEE_BPS) / 10000;
        uint256 netCost1 = BUY_AMOUNT - feePaid1;
        console2.log("");
        console2.log("  --- Step 1 Accounting ---");
        console2.log("  Gross spent (USDC)      :", BUY_AMOUNT);
        console2.log("  Fee (0.5%)              :", feePaid1);
        console2.log("  Net into pool           :", netCost1);
        console2.log("  Shares received         :", sharesStep1);
        console2.log("  Potential payout if win :", sharesStep1, "(= $1 per share)");
        console2.log("  Implied odds            :", sharesStep1 * 1e6 / BUY_AMOUNT, "x (6 dec)");
        console2.log("  Pool delta              :", s1.pool - s0.pool);
        console2.log("");

        // ────────────────────────────────────────────────────────────────
        // STEP 2: Sell HALF of those shares
        // ────────────────────────────────────────────────────────────────
        uint256 halfShares = sharesStep1 / 2;
        _header("STEP 2: SELL HALF shares from Step 1");
        console2.log("  Selling shares          :", halfShares);

        (uint256 sellReturn,,,) = market.sellSharesRange(
            RANGE_LO, RANGE_HI, halfShares, 0, address(0)
        );

        Snap memory s2 = _snap();
        _printSnap(s2);

        uint256 grossSellReturn = _estimateGrossSellReturn(sellReturn);
        uint256 sellFee = grossSellReturn - sellReturn;
        console2.log("");
        console2.log("  --- Step 2 Accounting ---");
        console2.log("  Shares sold             :", halfShares);
        console2.log("  Gross return (pre-fee)  :", grossSellReturn);
        console2.log("  Sell fee (0.5%)         :", sellFee);
        console2.log("  Net received (USDC)     :", sellReturn);
        console2.log("  Pool delta              :", _signedStr(int256(s2.pool) - int256(s1.pool)));
        console2.log("");

        // ── Combined P&L after Steps 1+2 ──
        uint256 remainingShares = sharesStep1 - halfShares;
        int256 cashFlow = int256(sellReturn) - int256(BUY_AMOUNT);
        console2.log("  === Position 1 Status After Step 2 ===");
        console2.log("  Cash spent so far       :", BUY_AMOUNT);
        console2.log("  Cash received back      :", sellReturn);
        console2.log("  Net cash flow           :", _signedStr(cashFlow));
        console2.log("  Remaining shares (pos1) :", remainingShares);
        console2.log("  If win, payout          :", remainingShares, "(= $1/share)");

        // What's the current sell value of remaining shares?
        uint256 pos1CurrentValue = _simulateSellReturn(remainingShares);
        console2.log("  Current sell value      :", pos1CurrentValue);
        console2.log("  Unrealized P&L (sell)   :", _signedStr(int256(pos1CurrentValue) + cashFlow));
        console2.log("");

        // ────────────────────────────────────────────────────────────────
        // STEP 3: Buy ANOTHER $100 on the SAME range
        // ────────────────────────────────────────────────────────────────
        _header("STEP 3: BUY another $100 on SAME range [114500, 114800)");

        _printQuote("Quote BEFORE 2nd buy");

        (uint256 sharesStep3,,,,,) = market.buySharesRange(
            RANGE_LO, RANGE_HI, BUY_AMOUNT, 0, 0, address(0)
        );

        Snap memory s3 = _snap();
        _printSnap(s3);

        uint256 feePaid3 = (BUY_AMOUNT * FEE_BPS) / 10000;
        uint256 netCost3 = BUY_AMOUNT - feePaid3;
        console2.log("");
        console2.log("  --- Step 3 Accounting ---");
        console2.log("  Gross spent (USDC)      :", BUY_AMOUNT);
        console2.log("  Fee (0.5%)              :", feePaid3);
        console2.log("  Net into pool           :", netCost3);
        console2.log("  Shares received         :", sharesStep3);
        console2.log("  Potential payout if win :", sharesStep3, "(= $1 per share)");
        console2.log("  Pool delta              :", s3.pool - s2.pool);
        console2.log("");

        // ────────────────────────────────────────────────────────────────
        // STEP 4: Compare both positions SIDE BY SIDE
        // ────────────────────────────────────────────────────────────────
        _header("STEP 4: POSITION COMPARISON");

        uint256 pos1SellNow = _simulateSellReturn(remainingShares);
        uint256 pos2SellNow = _simulateSellReturn(sharesStep3);

        // Position 1 total cost basis = $100 - sellReturn (got some back)
        int256 pos1NetCostBasis = int256(BUY_AMOUNT) - int256(sellReturn);

        console2.log("  +--------------------------------------------------------------+");
        console2.log("  |                    POSITION COMPARISON                       |");
        console2.log("  +--------------------------------------------------------------+");
        console2.log("  |                     Position 1        Position 2             |");
        console2.log("  +--------------------------------------------------------------+");
        console2.log("  Total $ spent           :", BUY_AMOUNT, BUY_AMOUNT);
        console2.log("  Cash returned (sell half):", sellReturn, uint256(0));
        console2.log("  Net cost basis (pos1)   :", _signedStr(pos1NetCostBasis));
        console2.log("  Net cost basis (pos2)   :", _signedStr(int256(BUY_AMOUNT)));
        console2.log("  Shares held             :", remainingShares, sharesStep3);
        console2.log("  Current sell value      :", pos1SellNow, pos2SellNow);
        console2.log("  Mark-to-market P&L pos1 :", _signedStr(int256(pos1SellNow) - pos1NetCostBasis));
        console2.log("  Mark-to-market P&L pos2 :", _signedStr(int256(pos2SellNow) - int256(BUY_AMOUNT)));
        console2.log("  If-win payout ($1/share):", remainingShares, sharesStep3);
        console2.log("  If-win profit pos1      :", _signedStr(int256(remainingShares) - pos1NetCostBasis));
        console2.log("  If-win profit pos2      :", _signedStr(int256(sharesStep3) - int256(BUY_AMOUNT)));
        console2.log("  +--------------------------------------------------------------+");
        console2.log("");

        // ── Key insight: price impact ──
        console2.log("  === KEY ECONOMICS INSIGHT ===");
        console2.log("  Step 1: $100 bought", sharesStep1, "shares (fresh market)");
        console2.log("  Step 3: $100 bought", sharesStep3, "shares (after activity)");
        if (sharesStep3 < sharesStep1) {
            console2.log("  >> 2nd buy got FEWER shares: price moved UP from prior demand");
            console2.log("  >> Difference:", sharesStep1 - sharesStep3, "fewer shares");
        } else if (sharesStep3 > sharesStep1) {
            console2.log("  >> 2nd buy got MORE shares: selling pushed price DOWN");
            console2.log("  >> Difference:", sharesStep3 - sharesStep1, "more shares");
        } else {
            console2.log("  >> Same shares - market returned to equilibrium");
        }
        console2.log("");

        // ── Global accounting sanity ──
        _header("GLOBAL ACCOUNTING");
        uint256 totalTraderSpent = s0.traderUsdc - s3.traderUsdc;
        console2.log("  Trader total spent      :", totalTraderSpent);
        console2.log("  Trader got back (sell)   :", sellReturn);
        console2.log("  Net trader outflow      :", totalTraderSpent - sellReturn);
        console2.log("  Pool balance now        :", s3.pool);
        console2.log("  Pool balance initial    :", s0.pool);
        console2.log("  Pool growth             :", s3.pool - s0.pool);
        console2.log("  Total fees (LP)         :", s3.feesLP);
        console2.log("  Total fees (Protocol)   :", s3.feesProt);
        console2.log("  Total volume            :", s3.totalVol);

        // ── Remaining shares in buckets ──
        console2.log("");
        console2.log("  Bucket 45 shares        :", s3.sharesBkt1145);
        console2.log("  Bucket 46 shares        :", s3.sharesBkt1146);
        console2.log("  Bucket 47 shares        :", s3.sharesBkt1147);
        console2.log("  (All 3 should be equal -correlated LMSR)");

        vm.stopPrank();

        // ── Basic assertions ──
        assertGt(sharesStep1, 0, "Step 1 should get shares");
        assertGt(sellReturn, 0, "Step 2 should get USDC back");
        assertGt(sharesStep3, 0, "Step 3 should get shares");
        assertEq(s3.sharesBkt1145, s3.sharesBkt1146, "Correlated: buckets should match");
        assertEq(s3.sharesBkt1146, s3.sharesBkt1147, "Correlated: buckets should match");
    }

    // ════════════════════════════════════════════════════════════════════
    //  HELPERS
    // ════════════════════════════════════════════════════════════════════

    /// @dev Simulate selling `shares` at current market state using snapshot/revert
    function _simulateSellReturn(uint256 shares) internal returns (uint256) {
        uint256 snap = vm.snapshotState();
        (uint256 payout,,,) = market.sellSharesRange(RANGE_LO, RANGE_HI, shares, 0, address(0));
        vm.revertToState(snap);
        return payout;
    }

    function _estimateGrossSellReturn(uint256 netReturn) internal pure returns (uint256) {
        // netReturn = gross - (gross * feeBps / 10000)
        // netReturn = gross * (10000 - feeBps) / 10000
        // gross = netReturn * 10000 / (10000 - feeBps)
        return (netReturn * 10000) / (10000 - FEE_BPS);
    }

    function _header(string memory title) internal pure {
        console2.log("");
        console2.log("================================================================");
        console2.log(title);
        console2.log("================================================================");
    }

    function _printSnap(Snap memory s) internal pure {
        console2.log("  Trader USDC             :", s.traderUsdc);
        console2.log("  Pool balance            :", s.pool);
        console2.log("  Alpha                   :", s.alpha);
        console2.log("  Fees LP / Protocol      :", s.feesLP, s.feesProt);
        console2.log("  Bucket shares [45,46,47]:", s.sharesBkt1145, s.sharesBkt1146);
        console2.log("  Bucket 47 shares        :", s.sharesBkt1147);
    }

    function _printQuote(string memory label) internal view {
        (uint256 qShares, uint256 qCost, uint256 qOdds) = market.getQuoteForRange(
            RANGE_LO, RANGE_HI, BUY_AMOUNT
        );
        console2.log("  [", label, "]");
        console2.log("    Quote shares           :", qShares);
        console2.log("    Quote cost             :", qCost);
        console2.log("    Quote odds             :", qOdds);
    }

    function _signedStr(int256 v) internal pure returns (string memory) {
        if (v >= 0) return string.concat("+", vm.toString(uint256(v)));
        return string.concat("-", vm.toString(uint256(-v)));
    }

}
