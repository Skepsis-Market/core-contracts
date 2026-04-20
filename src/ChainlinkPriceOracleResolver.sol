// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/access/Ownable.sol";
import {LMSRMarket} from "./LMSRMarket.sol";

/// @notice Minimal Chainlink AggregatorV3 interface — only the methods we use.
interface AggregatorV3Interface {
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );

    function decimals() external view returns (uint8);
}

/// @title ChainlinkPriceOracleResolver
/// @notice Trustless, permissionless resolver for LMSR price markets backed by Chainlink feeds.
///
/// ARCHITECTURE
/// ═══════════════════════════════════════════════════════════════════
///  Owner         → registerMarket(market, feed, divisor, staleness)  gates the config
///  Anyone        → resolve(market)                                   permissionless trigger
///  LMSRMarket    → resolveMarket(value)                              enforces scheduled time
///  Chainlink     → latestRoundData()                                 source of truth for price
///
/// Time enforcement lives in LMSRMarket.resolveMarket (single source of truth).
/// priceDivisor scales the raw feed answer into the market's unit space, e.g.
/// a BTC/USD feed (1e8 decimals) into a $1-bucket market: divisor = 1e8 → 94500.
contract ChainlinkPriceOracleResolver is Ownable {
    // ─── Config ──────────────────────────────────────────────────────────────

    struct MarketConfig {
        address priceFeed;
        uint256 priceDivisor;
        uint256 stalenessThreshold;
        bool registered;
    }

    /// @notice market address → its oracle config
    mapping(address => MarketConfig) public configs;

    // ─── Events ──────────────────────────────────────────────────────────────

    event MarketRegistered(
        address indexed market,
        address indexed priceFeed,
        uint256 priceDivisor,
        uint256 stalenessThreshold
    );
    event MarketUnregistered(address indexed market);
    event MarketResolvedByOracle(
        address indexed market,
        address indexed caller,
        uint256 resolvedValue,
        uint256 winningBucket
    );

    // ─── Errors ──────────────────────────────────────────────────────────────

    error AlreadyRegistered();
    error NotRegistered();
    error ZeroAddress();
    error ZeroDivisor();
    error ResolverMismatch();
    error MarketNotActive();
    error StalePriceFeed();
    error InvalidPrice();
    error PriceOutOfRange();

    // ─── Constructor ─────────────────────────────────────────────────────────

    constructor(address _owner) Ownable(_owner) {}

    // ─── Admin ───────────────────────────────────────────────────────────────

    /// @notice Register a market so this contract can resolve it via Chainlink.
    /// @dev    Requires the market's `resolver` to already be set to address(this).
    /// @param market               LMSRMarket address
    /// @param priceFeed            Chainlink AggregatorV3 feed address
    /// @param priceDivisor         raw / priceDivisor = value in market's unit space
    /// @param stalenessThreshold   max Chainlink update age in seconds (0 → default 3600)
    function registerMarket(
        address market,
        address priceFeed,
        uint256 priceDivisor,
        uint256 stalenessThreshold
    ) external onlyOwner {
        if (market == address(0) || priceFeed == address(0)) revert ZeroAddress();
        if (priceDivisor == 0) revert ZeroDivisor();
        if (configs[market].registered) revert AlreadyRegistered();

        // Misconfiguration guard: market must already have us wired as its resolver.
        if (LMSRMarket(market).resolver() != address(this)) revert ResolverMismatch();

        configs[market] = MarketConfig({
            priceFeed: priceFeed,
            priceDivisor: priceDivisor,
            stalenessThreshold: stalenessThreshold == 0 ? 3600 : stalenessThreshold,
            registered: true
        });

        emit MarketRegistered(market, priceFeed, priceDivisor, stalenessThreshold);
    }

    /// @notice Remove a market's config (post-resolution cleanup or reconfiguration).
    function unregisterMarket(address market) external onlyOwner {
        if (!configs[market].registered) revert NotRegistered();
        delete configs[market];
        emit MarketUnregistered(market);
    }

    // ─── Core ────────────────────────────────────────────────────────────────

    /// @notice Resolve a registered market using its Chainlink price feed.
    ///         Permissionless — anyone may call once all conditions are met.
    /// @dev    TooEarlyToResolve / InvalidResolutionValue propagate from LMSRMarket.
    function resolve(address market) external {
        MarketConfig memory cfg = configs[market];
        if (!cfg.registered) revert NotRegistered();

        // Cheap upfront check; market.resolveMarket also enforces this, but
        // failing here gives callers a clearer error surface.
        LMSRMarket m = LMSRMarket(market);
        if (m.status() != LMSRMarket.MarketStatus.ACTIVE) revert MarketNotActive();

        uint256 resolvedValue = _fetchPrice(cfg);

        // Time and range enforcement live inside LMSRMarket.resolveMarket.
        m.resolveMarket(resolvedValue);

        uint256 winningBucket = resolvedValue / m.bucketWidth();
        emit MarketResolvedByOracle(market, msg.sender, resolvedValue, winningBucket);
    }

    // ─── Views (for keeper bots / frontends) ─────────────────────────────────

    /// @notice Check whether a market can be resolved right now.
    /// @return canResolve  true if resolve(market) will succeed
    /// @return reason      short human-readable explanation when canResolve is false
    function checkResolvable(address market)
        external
        view
        returns (bool canResolve, string memory reason)
    {
        MarketConfig memory cfg = configs[market];
        if (!cfg.registered) return (false, "not registered");

        LMSRMarket m = LMSRMarket(market);
        if (m.status() != LMSRMarket.MarketStatus.ACTIVE) return (false, "market not active");

        uint256 schedTime = m.scheduledResolutionTime();
        if (schedTime != 0 && block.timestamp < schedTime) return (false, "too early");

        (, int256 answer, , uint256 updatedAt, ) =
            AggregatorV3Interface(cfg.priceFeed).latestRoundData();

        if (block.timestamp > updatedAt + cfg.stalenessThreshold) return (false, "price stale");
        if (answer <= 0) return (false, "invalid price");

        uint256 resolvedValue = uint256(answer) / cfg.priceDivisor;
        if (resolvedValue / m.bucketWidth() > m.maxBucketId()) return (false, "price out of range");

        return (true, "ready");
    }

    /// @notice Preview what value `resolve()` would set if called right now.
    /// @dev    Mirrors every guard `resolve` applies except the time and staleness
    ///         checks — so a stale feed still returns a value, but an out-of-range
    ///         price reverts exactly as the on-chain resolution path would.
    function previewResolutionValue(address market) external view returns (uint256) {
        MarketConfig memory cfg = configs[market];
        if (!cfg.registered) revert NotRegistered();

        (, int256 answer, , , ) = AggregatorV3Interface(cfg.priceFeed).latestRoundData();
        if (answer <= 0) revert InvalidPrice();

        uint256 resolvedValue = uint256(answer) / cfg.priceDivisor;

        LMSRMarket m = LMSRMarket(market);
        if (resolvedValue / m.bucketWidth() > m.maxBucketId()) revert PriceOutOfRange();

        return resolvedValue;
    }

    // ─── Internal ────────────────────────────────────────────────────────────

    /// @dev Fetch Chainlink price with staleness + sign checks, scale to market units.
    function _fetchPrice(MarketConfig memory cfg) internal view returns (uint256) {
        (, int256 answer, , uint256 updatedAt, ) =
            AggregatorV3Interface(cfg.priceFeed).latestRoundData();

        // Stale answers are as dangerous as missing answers — refuse to resolve.
        if (block.timestamp > updatedAt + cfg.stalenessThreshold) revert StalePriceFeed();
        // Chainlink returns int256; negative / zero indicates a degraded feed.
        if (answer <= 0) revert InvalidPrice();

        return uint256(answer) / cfg.priceDivisor;
    }
}
