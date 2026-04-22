// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {LMSRMarket} from "../src/LMSRMarket.sol";
import {ChainlinkPriceOracleResolver, AggregatorV3Interface} from "../src/ChainlinkPriceOracleResolver.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";

/// @dev Chainlink AggregatorV3 mock with per-round storage.
contract MockAggregatorV3 is AggregatorV3Interface {
    struct Round {
        int256 answer;
        uint256 updatedAt;
    }
    mapping(uint80 => Round) private _rounds;
    uint80 private _latest;
    uint8 private constant DECIMALS = 8;

    /// @notice Store a specific round. Advances `latest` if rid > latest.
    function setRound(uint80 rid, int256 answer_, uint256 updatedAt_) external {
        _rounds[rid] = Round(answer_, updatedAt_);
        if (rid > _latest) _latest = rid;
    }

    /// @notice Force `latestRoundData` to point at a specific round
    ///         (used when a test needs `latest` to lag behind written rounds).
    function setLatest(uint80 rid) external {
        _latest = rid;
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80, int256, uint256, uint256, uint80)
    {
        Round memory r = _rounds[_latest];
        return (_latest, r.answer, r.updatedAt, r.updatedAt, _latest);
    }

    function getRoundData(uint80 rid)
        external
        view
        override
        returns (uint80, int256, uint256, uint256, uint80)
    {
        Round memory r = _rounds[rid];
        return (rid, r.answer, r.updatedAt, r.updatedAt, rid);
    }

    function decimals() external pure override returns (uint8) {
        return DECIMALS;
    }
}

contract ChainlinkPriceOracleResolverTest is Test {
    LMSRMarket market;
    MockUSDC usdc;
    ChainlinkPriceOracleResolver oracle;
    MockAggregatorV3 feed;

    address owner      = address(0xA11CE);
    address creator    = address(0xC0DE);
    address factory    = address(0xFACE);
    address positionNFT = address(0xDEAD);
    address randomUser = address(0xBEEF);

    uint256 constant POOL          = 1000_000000;      // $1000 USDC seed
    uint256 constant ALPHA         = 500_000000;       // α = 500
    uint256 constant BUCKET_WIDTH  = 1000;             // $1K buckets
    uint256 constant MAX_BUCKET_ID = 200;              // 0–$200,999 range

    uint256 scheduledTime;

    function setUp() public {
        usdc  = new MockUSDC();
        feed  = new MockAggregatorV3();
        oracle = new ChainlinkPriceOracleResolver(owner);

        scheduledTime = block.timestamp + 1 days;

        market = _deployMarket(scheduledTime, address(oracle));
        usdc.mint(address(market), POOL);
    }

    // ─── Helpers ─────────────────────────────────────────────────────────────

    function _defaultSeeds() internal pure returns (uint256[] memory ids, uint256[] memory shares) {
        ids = new uint256[](2);
        shares = new uint256[](2);
        ids[0] = 90;
        ids[1] = 100;
        shares[0] = POOL / 2;
        shares[1] = POOL - shares[0];
    }

    function _deployMarket(uint256 schedTime, address resolver_) internal returns (LMSRMarket m) {
        (uint256[] memory seedIds, uint256[] memory seedShares) = _defaultSeeds();
        m = new LMSRMarket(LMSRMarket.InitParams({
            marketId: 1,
            creator: creator,
            factory: factory,
            usdcToken: address(usdc),
            positionNFT: positionNFT,
            alpha: ALPHA,
            poolBalance: POOL,
            bucketWidth: BUCKET_WIDTH,
            maxBucketId: MAX_BUCKET_ID,
            seededBucketIds: seedIds,
            seededShares: seedShares,
            feeBps: 50,
            protocolFeeBps: 2000,
            metadata: LMSRMarket.MarketMetadata({
                name: "BTC",
                description: "",
                resolutionCriteria: "",
                valueUnit: "USD",
                resolver: resolver_,
                biddingDeadline: 0,
                scheduledResolutionTime: schedTime,
                minBetSize: 0
            }),
            protocolFeeCollector: address(0xFEE)
        }));
    }

    function _register() internal {
        vm.prank(owner);
        oracle.registerMarket(address(market), address(feed), 1e8, 3600);
    }

    /// @dev Writes a valid two-round bracket around `scheduledTime` with `priceAnswer`
    ///      as the pinned round's raw answer. roundId 1 brackets scheduledTime.
    function _bracket(int256 priceAnswer) internal {
        feed.setRound(1, priceAnswer,             scheduledTime - 30);
        feed.setRound(2, priceAnswer,             scheduledTime + 30);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // LMSRMarket — scheduledResolutionTime enforcement
    // ═══════════════════════════════════════════════════════════════════════

    function test_resolveMarket_revertsBeforeScheduledTime() public {
        vm.prank(address(oracle));
        vm.expectRevert(LMSRMarket.TooEarlyToResolve.selector);
        market.resolveMarket(94_500);
    }

    function test_resolveMarket_succeedsAtScheduledTime() public {
        vm.warp(scheduledTime);
        vm.prank(address(oracle));
        market.resolveMarket(94_500);
        assertEq(uint8(market.status()), uint8(LMSRMarket.MarketStatus.RESOLVED));
        assertEq(market.winningBucket(), 94);
    }

    function test_resolveMarket_succeedsAfterScheduledTime() public {
        vm.warp(scheduledTime + 1 hours);
        vm.prank(address(oracle));
        market.resolveMarket(94_500);
        assertEq(uint8(market.status()), uint8(LMSRMarket.MarketStatus.RESOLVED));
    }

    function test_resolveMarket_noScheduleAllowsAnytime() public {
        LMSRMarket m = _deployMarket(0, address(oracle));
        usdc.mint(address(m), POOL);

        vm.prank(address(oracle));
        m.resolveMarket(94_500);
        assertEq(uint8(m.status()), uint8(LMSRMarket.MarketStatus.RESOLVED));
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Oracle — registration
    // ═══════════════════════════════════════════════════════════════════════

    function test_registerMarket_onlyOwner() public {
        vm.prank(randomUser);
        vm.expectRevert();
        oracle.registerMarket(address(market), address(feed), 1e8, 3600);
    }

    function test_registerMarket_revertsOnZeroAddresses() public {
        vm.startPrank(owner);

        vm.expectRevert(ChainlinkPriceOracleResolver.ZeroAddress.selector);
        oracle.registerMarket(address(0), address(feed), 1e8, 3600);

        vm.expectRevert(ChainlinkPriceOracleResolver.ZeroAddress.selector);
        oracle.registerMarket(address(market), address(0), 1e8, 3600);

        vm.stopPrank();
    }

    function test_registerMarket_revertsOnZeroDivisor() public {
        vm.prank(owner);
        vm.expectRevert(ChainlinkPriceOracleResolver.ZeroDivisor.selector);
        oracle.registerMarket(address(market), address(feed), 0, 3600);
    }

    function test_registerMarket_revertsOnResolverMismatch() public {
        LMSRMarket otherMarket = _deployMarket(scheduledTime, address(0xDEAD));
        vm.prank(owner);
        vm.expectRevert(ChainlinkPriceOracleResolver.ResolverMismatch.selector);
        oracle.registerMarket(address(otherMarket), address(feed), 1e8, 3600);
    }

    function test_registerMarket_revertsOnDoubleRegister() public {
        vm.startPrank(owner);
        oracle.registerMarket(address(market), address(feed), 1e8, 3600);
        vm.expectRevert(ChainlinkPriceOracleResolver.AlreadyRegistered.selector);
        oracle.registerMarket(address(market), address(feed), 1e8, 3600);
        vm.stopPrank();
    }

    function test_unregisterMarket_onlyOwner() public {
        vm.prank(owner);
        oracle.registerMarket(address(market), address(feed), 1e8, 3600);

        vm.prank(randomUser);
        vm.expectRevert();
        oracle.unregisterMarket(address(market));
    }

    function test_unregisterMarket_clearsConfig() public {
        vm.startPrank(owner);
        oracle.registerMarket(address(market), address(feed), 1e8, 3600);
        oracle.unregisterMarket(address(market));
        vm.stopPrank();

        (, , , bool registered) = oracle.configs(address(market));
        assertFalse(registered);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Oracle — resolve() with round pinning
    // ═══════════════════════════════════════════════════════════════════════

    function test_resolve_revertsIfNotRegistered() public {
        vm.expectRevert(ChainlinkPriceOracleResolver.NotRegistered.selector);
        oracle.resolve(address(market), 1);
    }

    function test_resolve_revertsIfMarketHasNoScheduledTime() public {
        // Market with scheduledTime == 0 is incompatible with round pinning.
        LMSRMarket m = _deployMarket(0, address(oracle));
        usdc.mint(address(m), POOL);
        vm.prank(owner);
        oracle.registerMarket(address(m), address(feed), 1e8, 3600);

        vm.expectRevert(ChainlinkPriceOracleResolver.NoScheduledTime.selector);
        oracle.resolve(address(m), 1);
    }

    function test_resolve_revertsOnInvalidRound() public {
        _register();
        // No rounds written; roundId=5 returns zeros.
        vm.warp(scheduledTime + 1 hours);
        vm.expectRevert(ChainlinkPriceOracleResolver.InvalidRound.selector);
        oracle.resolve(address(market), 5);
    }

    function test_resolve_revertsOnRoundTooNew() public {
        _register();
        // roundId=1 exists but its updatedAt is AFTER scheduledTime — caller
        // picked a round that came after the deadline.
        feed.setRound(1, int256(94_500 * 1e8), scheduledTime + 60);
        feed.setRound(2, int256(95_000 * 1e8), scheduledTime + 120);
        vm.warp(scheduledTime + 1 hours);

        vm.expectRevert(ChainlinkPriceOracleResolver.RoundTooNew.selector);
        oracle.resolve(address(market), 1);
    }

    function test_resolve_revertsOnRoundTooOld_nextRoundBeforeSched() public {
        _register();
        // Both rounds are before scheduledTime — the submitted round isn't the
        // last one before schedTime (the next one was also pre-schedTime).
        feed.setRound(1, int256(94_500 * 1e8), scheduledTime - 300);
        feed.setRound(2, int256(94_500 * 1e8), scheduledTime - 200);
        vm.warp(scheduledTime + 1 hours);

        vm.expectRevert(ChainlinkPriceOracleResolver.RoundTooOld.selector);
        oracle.resolve(address(market), 1);
    }

    function test_resolve_revertsOnRoundTooOld_nextRoundMissing() public {
        _register();
        // Only round 1 exists; round 2 isn't written → getRoundData returns zeros.
        feed.setRound(1, int256(94_500 * 1e8), scheduledTime - 30);
        vm.warp(scheduledTime + 1 hours);

        vm.expectRevert(ChainlinkPriceOracleResolver.RoundTooOld.selector);
        oracle.resolve(address(market), 1);
    }

    function test_resolve_revertsOnStalePrice_gapExceedsThreshold() public {
        _register();
        // Pinned round at schedTime-30, next round 10 hours later. Gap >> 1h threshold.
        feed.setRound(1, int256(94_500 * 1e8), scheduledTime - 30);
        feed.setRound(2, int256(94_500 * 1e8), scheduledTime + 10 hours);
        vm.warp(scheduledTime + 11 hours);

        vm.expectRevert(ChainlinkPriceOracleResolver.StalePriceFeed.selector);
        oracle.resolve(address(market), 1);
    }

    function test_resolve_revertsOnNegativePrice() public {
        _register();
        _bracket(-1);
        vm.warp(scheduledTime + 1);

        vm.expectRevert(ChainlinkPriceOracleResolver.InvalidPrice.selector);
        oracle.resolve(address(market), 1);
    }

    function test_resolve_revertsOnZeroPrice() public {
        _register();
        _bracket(0);
        vm.warp(scheduledTime + 1);

        vm.expectRevert(ChainlinkPriceOracleResolver.InvalidPrice.selector);
        oracle.resolve(address(market), 1);
    }

    function test_resolve_revertsIfMarketNotActive() public {
        _register();
        _bracket(int256(94_500 * 1e8));
        vm.warp(scheduledTime + 1);
        oracle.resolve(address(market), 1);

        vm.expectRevert(ChainlinkPriceOracleResolver.MarketNotActive.selector);
        oracle.resolve(address(market), 1);
    }

    function test_resolve_successful_resolvesBucket94() public {
        _register();
        _bracket(int256(94_500 * 1e8)); // BTC = $94,500
        vm.warp(scheduledTime + 1);

        oracle.resolve(address(market), 1);

        assertEq(uint8(market.status()), uint8(LMSRMarket.MarketStatus.RESOLVED));
        assertEq(market.resolutionValue(), 94_500);
        assertEq(market.winningBucket(), 94);
    }

    function test_resolve_permissionless_anyoneCanCall() public {
        _register();
        _bracket(int256(94_500 * 1e8));
        vm.warp(scheduledTime + 1);

        vm.prank(randomUser);
        oracle.resolve(address(market), 1);

        assertEq(uint8(market.status()), uint8(LMSRMarket.MarketStatus.RESOLVED));
    }

    function test_resolve_outOfRangePrice_revertsFromMarket() public {
        _register();
        // BTC price = $300,000 → bucket 300 > maxBucketId (200)
        _bracket(int256(300_000 * 1e8));
        vm.warp(scheduledTime + 1);

        vm.expectRevert(LMSRMarket.InvalidResolutionValue.selector);
        oracle.resolve(address(market), 1);
    }

    /// @dev The headline test — proves we use the *pinned* round's price, not the latest.
    function test_resolve_pinsToScheduledRound_ignoringLaterRounds() public {
        _register();
        // Scenario: round 1 is the one live at scheduledTime ($94,500).
        // Rounds 2 and 3 came AFTER and have different prices. If the caller
        // submits roundId=1, we must resolve to $94,500 regardless of how
        // much time passes or how far the price has moved since.
        feed.setRound(1, int256(94_500  * 1e8), scheduledTime - 30);
        feed.setRound(2, int256(98_000  * 1e8), scheduledTime + 30);
        feed.setRound(3, int256(105_000 * 1e8), scheduledTime + 1 hours);
        vm.warp(scheduledTime + 2 hours);

        oracle.resolve(address(market), 1);

        assertEq(market.resolutionValue(), 94_500, "must use pinned round's price, not latest");
        assertEq(market.winningBucket(), 94);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Oracle — view helpers
    // ═══════════════════════════════════════════════════════════════════════

    function test_checkResolvable_notRegistered() public view {
        (bool ok, string memory reason) = oracle.checkResolvable(address(market));
        assertFalse(ok);
        assertEq(reason, "not registered");
    }

    function test_checkResolvable_tooEarly() public {
        _register();
        (bool ok, string memory reason) = oracle.checkResolvable(address(market));
        assertFalse(ok);
        assertEq(reason, "too early");
    }

    function test_checkResolvable_noScheduledTime() public {
        LMSRMarket m = _deployMarket(0, address(oracle));
        usdc.mint(address(m), POOL);
        vm.prank(owner);
        oracle.registerMarket(address(m), address(feed), 1e8, 3600);

        (bool ok, string memory reason) = oracle.checkResolvable(address(m));
        assertFalse(ok);
        assertEq(reason, "no scheduled time");
    }

    function test_checkResolvable_waitingForPostScheduledRound() public {
        _register();
        // Latest round is at scheduledTime exactly — no round yet proves
        // the feed advanced past it, so we can't bracket.
        feed.setRound(1, int256(94_500 * 1e8), scheduledTime);
        vm.warp(scheduledTime + 1);

        (bool ok, string memory reason) = oracle.checkResolvable(address(market));
        assertFalse(ok);
        assertEq(reason, "waiting for post-scheduled round");
    }

    function test_checkResolvable_ready() public {
        _register();
        _bracket(int256(94_500 * 1e8));
        vm.warp(scheduledTime + 1);

        (bool ok, string memory reason) = oracle.checkResolvable(address(market));
        assertTrue(ok);
        assertEq(reason, "ready");
    }

    function test_previewResolutionValue_returnsPinnedPrice() public {
        _register();
        _bracket(int256(94_500 * 1e8));
        vm.warp(scheduledTime + 1);

        assertEq(oracle.previewResolutionValue(address(market), 1), 94_500);
    }

    function test_previewResolutionValue_revertsIfNotRegistered() public {
        vm.expectRevert(ChainlinkPriceOracleResolver.NotRegistered.selector);
        oracle.previewResolutionValue(address(market), 1);
    }

    function test_previewResolutionValue_revertsOnOutOfRange() public {
        _register();
        _bracket(int256(300_000 * 1e8)); // $300K > maxBucketId×bucketWidth
        vm.warp(scheduledTime + 1);

        vm.expectRevert(ChainlinkPriceOracleResolver.PriceOutOfRange.selector);
        oracle.previewResolutionValue(address(market), 1);
    }

    function test_previewResolutionValue_revertsOnRoundTooNew() public {
        _register();
        feed.setRound(1, int256(94_500 * 1e8), scheduledTime + 60);
        feed.setRound(2, int256(94_500 * 1e8), scheduledTime + 120);
        vm.warp(scheduledTime + 1 hours);

        vm.expectRevert(ChainlinkPriceOracleResolver.RoundTooNew.selector);
        oracle.previewResolutionValue(address(market), 1);
    }

    function test_previewResolutionValue_revertsOnInvalidRound() public {
        _register();
        vm.expectRevert(ChainlinkPriceOracleResolver.InvalidRound.selector);
        oracle.previewResolutionValue(address(market), 99);
    }
}
