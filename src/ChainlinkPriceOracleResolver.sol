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

    function getRoundData(uint80 _roundId)
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
///  Allowed registrar → registerMarket(market, feed, divisor, staleness)  gates the config
///                      (allowance configured by owner; mirrors MarketFactory.creatorAllowance)
///  Owner             → setRegistrarAllowance / unregisterMarket          admin surface
///  Anyone            → resolve(market, roundId)                          permissionless trigger
///  LMSRMarket        → resolveMarket(value)                              enforces scheduled time
///  Chainlink         → getRoundData(roundId) / latestRoundData()         source of truth for price
///
/// ROUND PINNING
/// ═══════════════════════════════════════════════════════════════════
/// Instead of reading `latestRoundData()` at resolve time (which drifts with
/// block landing), callers supply the Chainlink `roundId` that was live at
/// `scheduledResolutionTime`. The contract verifies the pinned round brackets
/// scheduledTime — its own `updatedAt` is ≤ scheduledTime, and the next round's
/// `updatedAt` is > scheduledTime. This guarantees the pinned answer is
/// exactly the price Chainlink reported at scheduledResolutionTime, regardless
/// of when resolve() actually lands on chain. Off-chain tooling (keeper,
/// admin UI) discovers the right roundId by binary-searching feed history.
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

    /// @notice Per-address quota of remaining registerMarket calls.
    ///         Owner sets via setRegistrarAllowance / addRegistrarAllowance.
    ///         Decrements by 1 on every successful registerMarket call.
    ///         Mirrors MarketFactory.creatorAllowance — same shape, same admin pattern.
    mapping(address => uint256) public registrarAllowance;

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
        uint80 roundId,
        uint256 resolvedValue,
        uint256 winningBucket
    );
    event RegistrarAllowanceSet(address indexed registrar, uint256 slots);
    event RegistrarAllowanceAdded(address indexed registrar, uint256 added, uint256 newTotal);

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
    error InvalidRound();
    error RoundTooNew();
    error RoundTooOld();
    error NoScheduledTime();
    error NotAllowedRegistrar();
    error InvalidSlots();

    // ─── Constructor ─────────────────────────────────────────────────────────

    constructor(address _owner) Ownable(_owner) {}

    // ─── Admin ───────────────────────────────────────────────────────────────

    /// @notice Set a registrar's remaining registerMarket quota (overwrites existing value).
    /// @dev    Mirrors MarketFactory.setCreatorAllowance — same semantics.
    /// @param  registrar   Address whose allowance is being updated. Set slots=0 to revoke.
    /// @param  slots       Total number of markets they may register.
    function setRegistrarAllowance(address registrar, uint256 slots) external onlyOwner {
        if (registrar == address(0)) revert ZeroAddress();
        registrarAllowance[registrar] = slots;
        emit RegistrarAllowanceSet(registrar, slots);
    }

    /// @notice Add slots on top of a registrar's existing allowance.
    /// @dev    Mirrors MarketFactory.addCreatorAllowance — same semantics.
    function addRegistrarAllowance(address registrar, uint256 slots) external onlyOwner {
        if (registrar == address(0)) revert ZeroAddress();
        if (slots == 0) revert InvalidSlots();
        registrarAllowance[registrar] += slots;
        emit RegistrarAllowanceAdded(registrar, slots, registrarAllowance[registrar]);
    }

    /// @notice Register a market so this contract can resolve it via Chainlink.
    /// @dev    Caller must hold a non-zero registrarAllowance balance. Requires
    ///         the market's `resolver` to already be set to address(this).
    /// @param market               LMSRMarket address
    /// @param priceFeed            Chainlink AggregatorV3 feed address
    /// @param priceDivisor         raw / priceDivisor = value in market's unit space
    /// @param stalenessThreshold   max gap between pinned round and next round, in seconds
    ///                             (0 → default 3600). Also doubles as a liveness bound
    ///                             on the feed around scheduledResolutionTime.
    function registerMarket(
        address market,
        address priceFeed,
        uint256 priceDivisor,
        uint256 stalenessThreshold
    ) external {
        // Allowance gate first (mirrors MarketFactory.createMarket).
        // Reverts roll back state, so on a later failed validation the slot
        // is refunded automatically — same behavior as the factory.
        uint256 allowance = registrarAllowance[msg.sender];
        if (allowance == 0) revert NotAllowedRegistrar();
        registrarAllowance[msg.sender] = allowance - 1;

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

    /// @notice Resolve a registered market using the Chainlink round that was
    ///         live at scheduledResolutionTime. Permissionless.
    /// @param  market   LMSRMarket to resolve
    /// @param  roundId  Chainlink round that brackets scheduledResolutionTime.
    ///                  Off-chain tooling finds this by binary-searching history.
    /// @dev    Reverts TooEarlyToResolve / InvalidResolutionValue propagate from LMSRMarket.
    function resolve(address market, uint80 roundId) external {
        MarketConfig memory cfg = configs[market];
        if (!cfg.registered) revert NotRegistered();

        LMSRMarket m = LMSRMarket(market);
        if (m.status() != LMSRMarket.MarketStatus.ACTIVE) revert MarketNotActive();

        uint256 schedTime = m.scheduledResolutionTime();
        if (schedTime == 0) revert NoScheduledTime();

        uint256 resolvedValue = _pinnedPrice(cfg, schedTime, roundId);

        // Time and range enforcement live inside LMSRMarket.resolveMarket.
        m.resolveMarket(resolvedValue);

        uint256 winningBucket = resolvedValue / m.bucketWidth();
        emit MarketResolvedByOracle(market, msg.sender, roundId, resolvedValue, winningBucket);
    }

    // ─── Views (for keeper bots / frontends) ─────────────────────────────────

    /// @notice Lightweight check — is the market *resolvable-in-principle* right now?
    /// @dev    Does NOT verify a roundId. Off-chain callers use this to decide
    ///         whether to run the roundId binary search, then call resolve().
    /// @return canResolve  true iff registered, active, past scheduledTime, and
    ///                     the feed has already emitted a round after scheduledTime.
    /// @return reason      short human-readable explanation when canResolve is false.
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
        if (schedTime == 0) return (false, "no scheduled time");
        if (block.timestamp < schedTime) return (false, "too early");

        (, , , uint256 latestUpdatedAt, ) =
            AggregatorV3Interface(cfg.priceFeed).latestRoundData();
        // Need at least one round strictly after scheduledTime to prove a bracket.
        if (latestUpdatedAt <= schedTime) return (false, "waiting for post-scheduled round");

        return (true, "ready");
    }

    /// @notice Preview the exact value `resolve(market, roundId)` would set,
    ///         with full round-pinning verification. Useful for keepers to
    ///         sanity-check before submitting a tx.
    /// @param  market   LMSRMarket to preview
    /// @param  roundId  Candidate Chainlink round
    function previewResolutionValue(address market, uint80 roundId) external view returns (uint256) {
        MarketConfig memory cfg = configs[market];
        if (!cfg.registered) revert NotRegistered();

        uint256 schedTime = LMSRMarket(market).scheduledResolutionTime();
        if (schedTime == 0) revert NoScheduledTime();

        uint256 resolvedValue = _pinnedPrice(cfg, schedTime, roundId);

        LMSRMarket m = LMSRMarket(market);
        if (resolvedValue / m.bucketWidth() > m.maxBucketId()) revert PriceOutOfRange();

        return resolvedValue;
    }

    // ─── Internal ────────────────────────────────────────────────────────────

    /// @dev Verify `roundId` brackets `schedTime` and return its price in market units.
    ///
    /// Bracket proof:
    ///   1. round(roundId).updatedAt ≤ schedTime       — round existed at schedTime
    ///   2. round(roundId+1).updatedAt > schedTime     — next round came after schedTime
    ///   3. round(roundId+1).updatedAt - round.updatedAt ≤ stalenessThreshold
    ///                                                 — feed was healthy around schedTime
    ///
    /// Together (1) and (2) prove `roundId` is exactly the round Chainlink reported
    /// at schedTime — the caller cannot cherry-pick an older or newer round.
    function _pinnedPrice(
        MarketConfig memory cfg,
        uint256 schedTime,
        uint80 roundId
    ) internal view returns (uint256) {
        AggregatorV3Interface feed = AggregatorV3Interface(cfg.priceFeed);

        (, int256 answer, , uint256 updatedAt, ) = feed.getRoundData(roundId);
        if (updatedAt == 0) revert InvalidRound();
        if (updatedAt > schedTime) revert RoundTooNew();

        (, , , uint256 nextUpdatedAt, ) = feed.getRoundData(roundId + 1);
        if (nextUpdatedAt == 0 || nextUpdatedAt <= schedTime) revert RoundTooOld();
        if (nextUpdatedAt - updatedAt > cfg.stalenessThreshold) revert StalePriceFeed();

        if (answer <= 0) revert InvalidPrice();

        return uint256(answer) / cfg.priceDivisor;
    }
}
