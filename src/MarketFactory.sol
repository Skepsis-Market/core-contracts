// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {LMSRMarket} from "./LMSRMarket.sol";
import {PositionNFT} from "./PositionNFT.sol";
import {IUSDC} from "./interfaces/IUSDC.sol";
import {Ownable} from "@openzeppelin/access/Ownable.sol";
import {Vault} from "./Vault.sol";

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
        uint256 minValue;          // Minimum value in market range (Sui parity)
        uint256 maxValue;          // Maximum value in market range (Sui parity)
        uint256 bucketCount;       // Number of buckets (Sui parity)
        uint256 feeBps;            // Trading fee bps (0 = factory default)
        uint256 protocolFeeBps;    // Protocol fee share bps (0 = factory default)
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
    event MarketPaused(uint256 indexed marketId, address indexed marketAddress);

    // ─────────────────── Errors ──────────────────────────────────────────────

    error InvalidParameters();
    error PoolBalanceTooLow();
    error TooManyBuckets();
    error InvalidBucketRanges();
    error NotWhitelisted();
    error VaultNotSet();

    // ─────────────────── Constructor ─────────────────────────────────────────

    constructor(
        address _usdcToken,
        address _positionNFT,
        uint256 _minPoolBalance,
        uint256 _maxBuckets,
        uint256 _defaultFeeBps,
        uint256 _defaultProtocolFeeBps
    ) Ownable(msg.sender) {
        if (_usdcToken == address(0)) revert InvalidParameters();
        if (_positionNFT == address(0)) revert InvalidParameters();
        if (_minPoolBalance == 0) revert InvalidParameters();
        if (_maxBuckets < 2) revert InvalidParameters();
        if (_defaultFeeBps > 500) revert InvalidParameters();
        if (_defaultProtocolFeeBps > 10000) revert InvalidParameters();

        usdcToken = IUSDC(_usdcToken);
        positionNFT = PositionNFT(_positionNFT);
        minPoolBalance = _minPoolBalance;
        maxBuckets = _maxBuckets;
        defaultFeeBps = _defaultFeeBps;
        defaultProtocolFeeBps = _defaultProtocolFeeBps;
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
        vault = Vault(_vault);
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
        if (p.bucketCount < 2) revert InvalidParameters();
        if (p.bucketCount > maxBuckets) revert TooManyBuckets();
        if (p.minValue >= p.maxValue) revert InvalidBucketRanges();
        // Ensure even bucket widths
        if ((p.maxValue - p.minValue) % p.bucketCount != 0) revert InvalidBucketRanges();

        uint256 actualFeeBps = p.feeBps == 0 ? defaultFeeBps : p.feeBps;
        uint256 actualProtocolFeeBps = p.protocolFeeBps == 0 ? defaultProtocolFeeBps : p.protocolFeeBps;
        if (actualFeeBps > 500) revert InvalidParameters();
        if (actualProtocolFeeBps > 10000) revert InvalidParameters();

        uint256 marketId = marketCount++;

        // ── Build bucket ranges from minValue, maxValue, bucketCount (Sui parity) ──
        uint256 bucketWidth = (p.maxValue - p.minValue) / p.bucketCount;
        uint256[] memory bucketRanges = new uint256[](p.bucketCount + 1);
        for (uint256 i = 0; i <= p.bucketCount; i++) {
            bucketRanges[i] = p.minValue + (i * bucketWidth);
        }

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

        LMSRMarket market = new LMSRMarket(
            marketId,
            msg.sender,        // creator
            address(this),     // factory
            address(usdcToken),
            address(positionNFT),
            p.alpha,           // creator-specified alpha (6 decimals)
            p.seedAmount,
            bucketRanges,      // computed from minValue, maxValue, bucketCount
            actualFeeBps,
            actualProtocolFeeBps,
            metadata
        );
        marketAddress = address(market);

        // ── 2. Register + authorize ───────────────────────────────────────────
        isValidMarket[marketAddress] = true;
        marketById[marketId] = marketAddress;
        positionNFT.authorizeMarket(marketAddress, marketId);

        // ── 3. Wire vault and fund atomically (all capital from vault) ────────
        market.setLPVault(address(vault));
        vault.fundNewMarket(marketAddress, p.seedAmount);

        // ── 4. Configure alpha decay atomically if requested ──────────────────
        if (p.decayDuration > 0 && p.alphaFinal > 0) {
            uint256 startTime = p.decayStart == 0 ? block.timestamp : p.decayStart;
            market.configureAlphaDecay(p.alphaFinal, startTime, p.decayDuration);
        }

        emit MarketCreated(marketId, marketAddress, msg.sender, p.seedAmount, p.bucketCount);
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

    /// @notice Update default protocol fee share
    function setDefaultProtocolFeeBps(uint256 newDefaultProtocolFeeBps) external onlyOwner {
        if (newDefaultProtocolFeeBps > 10000) revert InvalidParameters();
        uint256 oldValue = defaultProtocolFeeBps;
        defaultProtocolFeeBps = newDefaultProtocolFeeBps;
        emit DefaultProtocolFeeBpsUpdated(oldValue, newDefaultProtocolFeeBps);
    }

    /// @notice Emergency pause a market
    function pauseMarket(uint256 marketId) external onlyOwner {
        address marketAddress = marketById[marketId];
        if (marketAddress == address(0)) revert InvalidParameters();
        if (!isValidMarket[marketAddress]) revert InvalidParameters();
        emit MarketPaused(marketId, marketAddress);
    }
}
