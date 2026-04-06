// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LMSRMarket} from "./LMSRMarket.sol";
import {PositionNFT} from "./PositionNFT.sol";
import {IUSDC} from "./interfaces/IUSDC.sol";
import {Ownable} from "@openzeppelin/access/Ownable.sol";
import {Vault} from "./Vault.sol";
import {Clones} from "@openzeppelin/proxy/Clones.sol";

/// @notice Factory contract for creating LMSR prediction markets
/// @dev Only whitelisted creators can deploy markets.
///      Capital allocation is managed by a separate Vault contract.
contract MarketFactory is Ownable {

    // ─────────────────── Structs ─────────────────────────────────────────────

    /// @notice All parameters required to create a market in one tx
    struct MarketParams {
        // Core LMSR parameters
        uint256 alpha;             // Creator-specified alpha (6 decimals)
        uint256 seedAmount;        // Initial liquidity from vault (USDC 6 decimals)
        uint256 bucketWidth;       // Value units per bucket (e.g., 1000 for $1K buckets)
        uint256 maxBucketId;       // Maximum valid bucket ID (tree capacity - 1)
        uint256[] seededBucketIds; // Absolute bucket IDs to seed with initial shares
        uint256[] seededShares;    // Shares for each seeded bucket (parallel array, sum = seedAmount)
        // Alpha decay — all zero means no decay (fixed alpha)
        uint256 alphaFinal;        // Decay floor (6 decimals). 0 = no decay
        uint256 decayStart;        // Unix timestamp when decay begins. 0 = block.timestamp
        uint256 decayDuration;     // Decay duration in seconds. 0 = no decay
        // Market metadata (Sui parity)
        string name;               // Market question/title
        string description;        // Detailed description
        string resolutionCriteria; // How the market will be resolved
        string valueUnit;          // Unit label (e.g., "USD", "°C", "ETH")
        address resolver;          // Who can resolve (0 = creator)
        uint256 biddingDeadline;   // Betting close time (0 = no deadline)
        uint256 scheduledResolutionTime; // When resolution is expected (0 = unspecified)
        uint256 minBetSize;        // Minimum trade size in USDC (0 = no minimum)
        uint256 maxBucketsPerRange; // Max buckets in a range trade (0 = factory default)
    }

    // ─────────────────── State ───────────────────────────────────────────────

    /// @notice Shared PositionNFT — one ERC-1155 collection for all markets
    PositionNFT public immutable positionNFT;

    /// @notice USDC token contract
    IUSDC public immutable usdcToken;

    /// @notice Platform vault that funds all markets
    Vault public vault;

    /// @notice Total number of markets created
    uint256 public marketCount;

    /// @notice Market address → is a factory-deployed market
    mapping(address => bool) public isValidMarket;

    /// @notice Market ID → market address
    mapping(uint256 => address) public marketById;

    /// @notice LMSRMarket implementation contract cloned for every new market (EIP-1167).
    ///         Removes 43k of LMSRMarket initcode from MarketFactory's own bytecode.
    address public immutable implementation;

    /// @notice Creator address → remaining market-creation slots (0 = not allowed)
    mapping(address => uint256) public creatorAllowance;

    /// @notice Minimum pool balance to create a market (USDC 6 decimals)
    uint256 public minPoolBalance;

    /// @notice Maximum number of buckets per market
    uint256 public maxBuckets;

    /// @notice Default trading fee in basis points (e.g. 50 = 0.5%)
    uint256 public defaultFeeBps;

    /// @notice Default protocol fee share in basis points (e.g. 2000 = 20%)
    uint256 public defaultProtocolFeeBps;

    /// @notice Address that receives protocol fees from all markets
    address public protocolFeeCollector;

    /// @notice Default max buckets allowed per range trade (0 = no limit)
    uint256 public defaultMaxBucketsPerRange;

    /// @notice Authorized trade router for all markets
    address public router;

    // ─────────────────── Events ──────────────────────────────────────────────

    event MarketCreated(
        uint256 indexed marketId,
        address indexed marketAddress,
        address indexed creator,
        uint256 poolBalance,
        uint256 bucketCount
    );
    event CreatorAllowanceSet(address indexed creator, uint256 allowance);
    event CreatorAllowanceAdded(address indexed creator, uint256 added, uint256 total);
    event MinPoolBalanceUpdated(uint256 oldValue, uint256 newValue);
    event MaxBucketsUpdated(uint256 oldValue, uint256 newValue);
    event DefaultFeeBpsUpdated(uint256 oldValue, uint256 newValue);
    event DefaultProtocolFeeBpsUpdated(uint256 oldValue, uint256 newValue);
    event ProtocolFeeCollectorUpdated(address indexed oldCollector, address indexed newCollector);
    event DefaultMaxBucketsPerRangeUpdated(uint256 oldValue, uint256 newValue);
    event MarketPaused(uint256 indexed marketId, address indexed marketAddress);
    event MarketUnpaused(uint256 indexed marketId, address indexed marketAddress);
    event RouterUpdated(address indexed oldRouter, address indexed newRouter);
    event VaultUpdated(address indexed oldVault, address indexed newVault);

    // ─────────────────── Errors ──────────────────────────────────────────────

    error InvalidParameters();
    error PoolBalanceTooLow();
    error TooManyBuckets();
    error InvalidBucketRanges();
    error NotWhitelisted();
    error VaultNotSet();

    // ─────────────────── Constructor ─────────────────────────────────────────

    constructor(
        address _implementation,
        address _usdcToken,
        address _positionNFT,
        uint256 _minPoolBalance,
        uint256 _maxBuckets,
        uint256 _defaultFeeBps,
        uint256 _defaultProtocolFeeBps,
        address _protocolFeeCollector
    ) Ownable(msg.sender) {
        if (_implementation == address(0)) revert InvalidParameters();
        if (_usdcToken == address(0)) revert InvalidParameters();
        if (_positionNFT == address(0)) revert InvalidParameters();
        if (_minPoolBalance == 0) revert InvalidParameters();
        if (_maxBuckets < 2) revert InvalidParameters();
        if (_defaultFeeBps > 500) revert InvalidParameters();
        if (_defaultProtocolFeeBps > 10000) revert InvalidParameters();
        if (_protocolFeeCollector == address(0)) revert InvalidParameters();

        implementation = _implementation;
        usdcToken = IUSDC(_usdcToken);
        positionNFT = PositionNFT(_positionNFT);
        minPoolBalance = _minPoolBalance;
        maxBuckets = _maxBuckets;
        defaultFeeBps = _defaultFeeBps;
        defaultProtocolFeeBps = _defaultProtocolFeeBps;
        protocolFeeCollector = _protocolFeeCollector;
    }

    // ─────────────────── Creator Whitelist ───────────────────────────────────

    /// @notice Set a creator's market-creation allowance (overwrites existing value)
    /// @param creator Address to configure. Set to 0 to revoke.
    /// @param slots   Number of markets they may create
    function setCreatorAllowance(address creator, uint256 slots) external onlyOwner {
        if (creator == address(0)) revert InvalidParameters();
        creatorAllowance[creator] = slots;
        emit CreatorAllowanceSet(creator, slots);
    }

    /// @notice Add market-creation slots on top of a creator's existing allowance
    /// @param creator Address to top-up
    /// @param slots   Number of additional slots to grant
    function addCreatorAllowance(address creator, uint256 slots) external onlyOwner {
        if (creator == address(0)) revert InvalidParameters();
        if (slots == 0) revert InvalidParameters();
        creatorAllowance[creator] += slots;
        emit CreatorAllowanceAdded(creator, slots, creatorAllowance[creator]);
    }

    /// @notice Set the platform vault that funds all markets
    function setVault(address _vault) external onlyOwner {
        if (_vault == address(0)) revert InvalidParameters();
        address oldVault = address(vault);
        vault = Vault(_vault);
        emit VaultUpdated(oldVault, _vault);
    }

    function setRouter(address _router) external onlyOwner {
        address oldRouter = router;
        router = _router;
        emit RouterUpdated(oldRouter, _router);
    }

    /// @notice Update router on an existing market (for upgrades)
    function updateMarketRouter(address market, address _router) external onlyOwner {
        if (!isValidMarket[market]) revert InvalidParameters();
        LMSRMarket(market).setRouter(_router);
    }

    // ─────────────────── Market Creation ─────────────────────────────────────

    /// @notice Create a prediction market in one transaction.
    /// @dev Caller must be whitelisted. Capital comes from the platform Vault.
    ///      Alpha decay is configured atomically when decayDuration > 0 and alphaFinal > 0.
    ///      Creator provides market design (alpha, buckets, seed amount); all USDC flows
    ///      through the Vault — creator never needs to transfer tokens.
    /// @param p  See {MarketParams}
    /// @return marketAddress Address of the deployed LMSRMarket
    function createMarket(MarketParams calldata p)
        external
        returns (address marketAddress)
    {
        if (address(vault) == address(0)) revert VaultNotSet();

        // ── Whitelist check (CEI: decrement before any external call) ─────────
        uint256 allowance = creatorAllowance[msg.sender];
        if (allowance == 0) revert NotWhitelisted();
        creatorAllowance[msg.sender] = allowance - 1;

        // ── Validate core params ──────────────────────────────────────────────
        if (p.alpha == 0) revert InvalidParameters();
        if (p.seedAmount < minPoolBalance) revert PoolBalanceTooLow();
        if (p.bucketWidth == 0) revert InvalidParameters();
        if (p.seededBucketIds.length < 2) revert InvalidParameters();
        if (p.seededBucketIds.length != p.seededShares.length) revert InvalidBucketRanges();
        if (p.maxBucketId + 1 > maxBuckets) revert TooManyBuckets();

        // Fees come from factory defaults — no per-market override
        uint256 actualFeeBps = defaultFeeBps;
        uint256 actualProtocolFeeBps = defaultProtocolFeeBps;

        uint256 marketId = marketCount++;

        // ── 1. Deploy market (alpha + seed are creator design params) ─────────
        LMSRMarket.MarketMetadata memory metadata = LMSRMarket.MarketMetadata({
            name: p.name,
            description: p.description,
            resolutionCriteria: p.resolutionCriteria,
            valueUnit: p.valueUnit,
            resolver: p.resolver,
            biddingDeadline: p.biddingDeadline,
            scheduledResolutionTime: p.scheduledResolutionTime,
            minBetSize: p.minBetSize
        });

        marketAddress = Clones.clone(implementation);
        LMSRMarket market = LMSRMarket(marketAddress);
        market.initialize(LMSRMarket.InitParams({
            marketId: marketId,
            creator: msg.sender,
            factory: address(this),
            usdcToken: address(usdcToken),
            positionNFT: address(positionNFT),
            alpha: p.alpha,
            poolBalance: p.seedAmount,
            bucketWidth: p.bucketWidth,
            maxBucketId: p.maxBucketId,
            seededBucketIds: p.seededBucketIds,
            seededShares: p.seededShares,
            feeBps: actualFeeBps,
            protocolFeeBps: actualProtocolFeeBps,
            metadata: metadata,
            protocolFeeCollector: protocolFeeCollector
        }));

        // ── 2. Register + authorize ───────────────────────────────────────────
        isValidMarket[marketAddress] = true;
        marketById[marketId] = marketAddress;
        positionNFT.authorizeMarket(marketAddress, marketId);

        // ── 3. Wire vault, router, and fund atomically ──────────────────────
        market.setLPVault(address(vault));
        if (router != address(0)) {
            market.setRouter(router);
        }
        vault.fundNewMarket(marketAddress, p.seedAmount);

        // ── 4. Configure alpha decay atomically if requested ──────────────────
        if (p.decayDuration > 0 && p.alphaFinal > 0) {
            uint256 startTime = p.decayStart == 0 ? block.timestamp : p.decayStart;
            market.configureAlphaDecay(p.alphaFinal, startTime, p.decayDuration);
        }

        // ── 5. Configure max range width ────────────────────────────────────
        uint256 rangeWidth = p.maxBucketsPerRange == 0 ? defaultMaxBucketsPerRange : p.maxBucketsPerRange;
        if (rangeWidth > 0) {
            market.setMaxRangeWidth(rangeWidth);
        }

        emit MarketCreated(marketId, marketAddress, msg.sender, p.seedAmount, p.seededBucketIds.length);
    }

    // ─────────────────── Admin ────────────────────────────────────────────────

    /// @notice Update minimum pool balance requirement
    function setMinPoolBalance(uint256 newMinPoolBalance) external onlyOwner {
        if (newMinPoolBalance == 0) revert InvalidParameters();
        uint256 oldValue = minPoolBalance;
        minPoolBalance = newMinPoolBalance;
        emit MinPoolBalanceUpdated(oldValue, newMinPoolBalance);
    }

    /// @notice Update maximum buckets per market
    function setMaxBuckets(uint256 newMaxBuckets) external onlyOwner {
        if (newMaxBuckets < 2) revert InvalidParameters();
        uint256 oldValue = maxBuckets;
        maxBuckets = newMaxBuckets;
        emit MaxBucketsUpdated(oldValue, newMaxBuckets);
    }

    /// @notice Update default trading fee
    function setDefaultFeeBps(uint256 newDefaultFeeBps) external onlyOwner {
        if (newDefaultFeeBps > 500) revert InvalidParameters();
        uint256 oldValue = defaultFeeBps;
        defaultFeeBps = newDefaultFeeBps;
        emit DefaultFeeBpsUpdated(oldValue, newDefaultFeeBps);
    }

    /// @notice Update protocol fee collector address
    function setProtocolFeeCollector(address _collector) external onlyOwner {
        if (_collector == address(0)) revert InvalidParameters();
        address old = protocolFeeCollector;
        protocolFeeCollector = _collector;
        emit ProtocolFeeCollectorUpdated(old, _collector);
    }

    /// @notice Update default protocol fee share
    function setDefaultProtocolFeeBps(uint256 newDefaultProtocolFeeBps) external onlyOwner {
        if (newDefaultProtocolFeeBps > 10000) revert InvalidParameters();
        uint256 oldValue = defaultProtocolFeeBps;
        defaultProtocolFeeBps = newDefaultProtocolFeeBps;
        emit DefaultProtocolFeeBpsUpdated(oldValue, newDefaultProtocolFeeBps);
    }

    /// @notice Update default max buckets per range trade
    function setDefaultMaxBucketsPerRange(uint256 newMaxBucketsPerRange) external onlyOwner {
        uint256 oldValue = defaultMaxBucketsPerRange;
        defaultMaxBucketsPerRange = newMaxBucketsPerRange;
        emit DefaultMaxBucketsPerRangeUpdated(oldValue, newMaxBucketsPerRange);
    }

    /// @notice Push current default fees to a specific market
    function updateMarketFees(address market) external onlyOwner {
        if (!isValidMarket[market]) revert InvalidParameters();
        LMSRMarket(market).setFees(defaultFeeBps, defaultProtocolFeeBps);
    }

    /// @notice Push current default fees to multiple markets at once
    function updateMarketFeesBatch(address[] calldata markets) external onlyOwner {
        for (uint256 i = 0; i < markets.length; i++) {
            if (!isValidMarket[markets[i]]) revert InvalidParameters();
            LMSRMarket(markets[i]).setFees(defaultFeeBps, defaultProtocolFeeBps);
        }
    }

    /// @notice Emergency pause a market — blocks all trading and claims
    function pauseMarket(uint256 _marketId) external onlyOwner {
        address marketAddress = marketById[_marketId];
        if (marketAddress == address(0)) revert InvalidParameters();
        if (!isValidMarket[marketAddress]) revert InvalidParameters();
        LMSRMarket(marketAddress).emergencyPause();
        emit MarketPaused(_marketId, marketAddress);
    }

    /// @notice Unpause an emergency-paused market
    function unpauseMarket(uint256 _marketId) external onlyOwner {
        address marketAddress = marketById[_marketId];
        if (marketAddress == address(0)) revert InvalidParameters();
        if (!isValidMarket[marketAddress]) revert InvalidParameters();
        LMSRMarket(marketAddress).emergencyUnpause();
        emit MarketUnpaused(_marketId, marketAddress);
    }
}
