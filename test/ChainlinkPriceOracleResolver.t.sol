// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {LMSRMarket} from "../src/LMSRMarket.sol";
import {ChainlinkPriceOracleResolver, AggregatorV3Interface} from "../src/ChainlinkPriceOracleResolver.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";

/// @dev Minimal Chainlink AggregatorV3 mock. Owner sets answer + updatedAt.
contract MockAggregatorV3 is AggregatorV3Interface {
    int256 private _answer;
    uint256 private _updatedAt;
    uint8 private constant DECIMALS = 8;

    function setAnswer(int256 answer_, uint256 updatedAt_) external {
        _answer = answer_;
        _updatedAt = updatedAt_;
    }

    function latestRoundData()
        external
        view
        override
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        return (1, _answer, _updatedAt, _updatedAt, 1);
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
        // Seed 2 buckets with equal shares summing to POOL
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
        // Redeploy with scheduledResolutionTime = 0 → unbounded (geopolitical-style)
        LMSRMarket m = _deployMarket(0, address(oracle));
        usdc.mint(address(m), POOL);

        // Resolving immediately must succeed
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
        // Deploy a market with a different resolver
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
    // Oracle — resolve()
    // ═══════════════════════════════════════════════════════════════════════

    function _register() internal {
        vm.prank(owner);
        oracle.registerMarket(address(market), address(feed), 1e8, 3600);
    }

    function test_resolve_revertsIfNotRegistered() public {
        vm.expectRevert(ChainlinkPriceOracleResolver.NotRegistered.selector);
        oracle.resolve(address(market));
    }

    function test_resolve_revertsBeforeScheduledTime() public {
        _register();
        feed.setAnswer(int256(94_500 * 1e8), block.timestamp);

        // Propagates TooEarlyToResolve from the market
        vm.expectRevert(LMSRMarket.TooEarlyToResolve.selector);
        oracle.resolve(address(market));
    }

    function test_resolve_revertsOnStalePrice() public {
        _register();
        // Price set "a long time ago"
        feed.setAnswer(int256(94_500 * 1e8), block.timestamp);
        vm.warp(scheduledTime + 10 hours); // staleness threshold = 1 hour

        vm.expectRevert(ChainlinkPriceOracleResolver.StalePriceFeed.selector);
        oracle.resolve(address(market));
    }

    function test_resolve_revertsOnNegativePrice() public {
        _register();
        feed.setAnswer(-1, scheduledTime);
        vm.warp(scheduledTime);

        vm.expectRevert(ChainlinkPriceOracleResolver.InvalidPrice.selector);
        oracle.resolve(address(market));
    }

    function test_resolve_revertsOnZeroPrice() public {
        _register();
        feed.setAnswer(0, scheduledTime);
        vm.warp(scheduledTime);

        vm.expectRevert(ChainlinkPriceOracleResolver.InvalidPrice.selector);
        oracle.resolve(address(market));
    }

    function test_resolve_revertsIfMarketNotActive() public {
        _register();
        // Resolve the market first via a valid path
        feed.setAnswer(int256(94_500 * 1e8), scheduledTime);
        vm.warp(scheduledTime);
        oracle.resolve(address(market));

        // Second call must revert — market is now RESOLVED
        vm.expectRevert(ChainlinkPriceOracleResolver.MarketNotActive.selector);
        oracle.resolve(address(market));
    }

    function test_resolve_successful_resolvesBucket94() public {
        _register();
        feed.setAnswer(int256(94_500 * 1e8), scheduledTime); // BTC = $94,500
        vm.warp(scheduledTime);

        oracle.resolve(address(market));

        assertEq(uint8(market.status()), uint8(LMSRMarket.MarketStatus.RESOLVED));
        assertEq(market.resolutionValue(), 94_500);
        assertEq(market.winningBucket(), 94); // 94500 / 1000 = 94
    }

    function test_resolve_permissionless_anyoneCanCall() public {
        _register();
        feed.setAnswer(int256(94_500 * 1e8), scheduledTime);
        vm.warp(scheduledTime);

        // Random address (not owner, not creator, not keeper) calls resolve
        vm.prank(randomUser);
        oracle.resolve(address(market));

        assertEq(uint8(market.status()), uint8(LMSRMarket.MarketStatus.RESOLVED));
    }

    function test_resolve_outOfRangePrice_revertsFromMarket() public {
        _register();
        // BTC price = $300,000 → bucket 300 > maxBucketId (200)
        feed.setAnswer(int256(300_000 * 1e8), scheduledTime);
        vm.warp(scheduledTime);

        vm.expectRevert(LMSRMarket.InvalidResolutionValue.selector);
        oracle.resolve(address(market));
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Oracle — view helpers
    // ═══════════════════════════════════════════════════════════════════════

    function test_checkResolvable_ready() public {
        _register();
        feed.setAnswer(int256(94_500 * 1e8), scheduledTime);
        vm.warp(scheduledTime);

        (bool ok, string memory reason) = oracle.checkResolvable(address(market));
        assertTrue(ok);
        assertEq(reason, "ready");
    }

    function test_checkResolvable_notRegistered() public view {
        (bool ok, string memory reason) = oracle.checkResolvable(address(market));
        assertFalse(ok);
        assertEq(reason, "not registered");
    }

    function test_checkResolvable_tooEarly() public {
        _register();
        feed.setAnswer(int256(94_500 * 1e8), block.timestamp);

        (bool ok, string memory reason) = oracle.checkResolvable(address(market));
        assertFalse(ok);
        assertEq(reason, "too early");
    }

    function test_checkResolvable_priceStale() public {
        _register();
        feed.setAnswer(int256(94_500 * 1e8), block.timestamp);
        vm.warp(scheduledTime + 10 hours); // 1-hour threshold → stale

        (bool ok, string memory reason) = oracle.checkResolvable(address(market));
        assertFalse(ok);
        assertEq(reason, "price stale");
    }

    function test_checkResolvable_invalidPrice() public {
        _register();
        feed.setAnswer(0, scheduledTime);
        vm.warp(scheduledTime);

        (bool ok, string memory reason) = oracle.checkResolvable(address(market));
        assertFalse(ok);
        assertEq(reason, "invalid price");
    }

    function test_checkResolvable_outOfRange() public {
        _register();
        feed.setAnswer(int256(300_000 * 1e8), scheduledTime);
        vm.warp(scheduledTime);

        (bool ok, string memory reason) = oracle.checkResolvable(address(market));
        assertFalse(ok);
        assertEq(reason, "price out of range");
    }

    function test_previewResolutionValue() public {
        _register();
        feed.setAnswer(int256(94_500 * 1e8), block.timestamp);

        assertEq(oracle.previewResolutionValue(address(market)), 94_500);
    }

    function test_previewResolutionValue_revertsIfNotRegistered() public {
        vm.expectRevert(ChainlinkPriceOracleResolver.NotRegistered.selector);
        oracle.previewResolutionValue(address(market));
    }

    function test_previewResolutionValue_revertsOnOutOfRange() public {
        _register();
        // BTC = $300,000 → bucket 300 > maxBucketId (200). Staleness is ignored by
        // previewResolutionValue, but the range guard must still fire.
        feed.setAnswer(int256(300_000 * 1e8), block.timestamp);

        vm.expectRevert(ChainlinkPriceOracleResolver.PriceOutOfRange.selector);
        oracle.previewResolutionValue(address(market));
    }
}
