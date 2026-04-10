// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IUSDC} from "./interfaces/IUSDC.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {IPositionNFT} from "./interfaces/IPositionNFT.sol";
import {FixedPointMath} from "./FixedPointMath.sol";
import {ReentrancyGuard} from "@openzeppelin/utils/ReentrancyGuard.sol";
import {BucketTree} from "./BucketTree.sol";
import {LMSRCost} from "./LMSRCost.sol";
import {Math} from "@openzeppelin/utils/math/Math.sol";

/// @notice Core LMSR market contract for prediction markets
contract LMSRMarket is ReentrancyGuard {
    using FixedPointMath for uint256;
    using BucketTree for BucketTree.Tree;
    using SafeERC20 for IERC20;

    struct Bucket {
        uint256 shares;        // 6 decimals (matches USDC) — current total shares
        uint256 initialShares; // 6 decimals — LP's initial allocation (immutable after creation)
        uint256 lowerBound;
        uint256 upperBound;
    }

    /// @notice Range position for correlated LMSR bets
    struct RangePosition {
        uint256 startBucket;
        uint256 endBucket;
        uint256 shares; // 6 decimals - same shares cover ALL buckets in range
    }

    enum MarketStatus {
        ACTIVE,
        RESOLVED,
        CANCELLED,
        EMERGENCY_PAUSED
    }

    uint256 public constant SOLVENCY_DUST = 1000;
    uint256 public constant CACHE_RESET_INTERVAL = 100; // DEPRECATED — tree is always consistent
    uint256 public constant MAX_FEE_BPS = 500;
    uint256 public constant PHANTOM_SHARES = 1; // 1 phantom share (0.000001 USDC in 6 decimals)
    uint256 public constant WAD = 1e18; // PRB-Math's WAD (18 decimals) for exp/ln operations
    uint256 public constant ALPHA_EPOCH_LENGTH = 30 minutes;
    uint256 public constant MIN_ALPHA_FLOOR_BPS = 1000; // 10%

    uint256 public marketId;
    address public creator;
    address public factory;
    address public positionNFT;
    IUSDC public usdcToken;
    bool private _initialized; // clone guard: prevents re-initialization on EIP-1167 clones

    uint256 public alpha;
    uint256 public alphaInitial;
    uint256 public alphaFinal;
    uint256 public decayStartTime;
    uint256 public decayDuration;
    uint256 public lastAlphaSyncTime;
    uint256 public poolBalance;
    uint256 public initialDeposit;      // first deposit only (legacy, kept for compat)
    uint256 public totalDeposited;      // cumulative USDC deposited as liquidity
    uint256 public totalSurplusWithdrawn; // cumulative USDC withdrawn via withdrawSurplus
    uint256 public bucketCount;

    // Market bounds for range-to-bucket conversion
    uint256 public marketMin;     // DEPRECATED — kept for slot layout (was relative min)
    uint256 public maxBucketId;   // Maximum valid bucket ID (tree capacity - 1)
    uint256 public bucketWidth;   // Value units per bucket

    uint256 private cachedLnBucketCount;

    mapping(uint256 => Bucket) public buckets;

    MarketStatus public status;
    uint256 public winningBucket;
    uint256 public resolutionValue;  // Original value that resolved the market (e.g., $115,000) — absolute bucket index
    uint256 public totalVolume;
    uint256 public resolutionTime;
    bool public lpWithdrawn;
    address public lpVault;

    uint256 public feeBps;
    uint256 public protocolFeeBps;
    uint256 public feesCollectedLP;
    uint256 public feesCollectedProtocol;
    uint256 public maxLiability;

    // Market metadata (Sui parity)
    string public name;                    // Market question/title
    string public description;             // Detailed description  
    string public resolutionCriteria;      // How the market will be resolved
    string public valueUnit;               // Unit label (e.g., "USD", "°C")
    address public resolver;               // Who can resolve (if different from creator)
    uint256 public biddingDeadline;        // Betting close time (0 = no deadline)
    uint256 public scheduledResolutionTime; // When resolution is expected
    uint256 public minBetSize;             // Minimum trade size in USDC
    uint256 public creationTime;           // Block timestamp when created

    // DEPRECATED — replaced by BucketTree. Slots kept for EIP-1167 clone layout compatibility.
    uint256 private cachedSumExp;
    mapping(uint256 => uint256) private cachedBucketExp;
    bool private sumExpDirty;
    uint256 private tradeCount;

    // ═══════════════════════════════════════════════════════════════════════════
    // NEW STORAGE — appended for EIP-1167 clone safety
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Configurable protocol fee recipient (replaces hardcoded constant)
    address public protocolFeeCollector;                          // Slot 46

    /// @notice Number of buckets with active LMSR weight (≤ maxBucketId + 1)
    uint256 public activeBucketCount;                               // Slot 47

    /// @notice DEPRECATED — was expansion capacity. Kept for slot layout.
    uint256 public maxBucketCount;                                  // Slot 48

    /// @notice DEPRECATED — was index shift for expansion. Kept for slot layout.
    uint256 public initialBucketOffset;                             // Slot 49

    /// @notice Authorized trade router — only address allowed to call buy/sell/claim
    address public router;                                           // Slot 50

    // Slots 51-53 reserved for future use
    uint256[3] private __reservedForFutureUse;

    /// @notice Cumulative LP fees that stayed in the contract (accounting transparency)
    uint256 public lpFeesAccrued;                                 // Slot 54

    /// @notice Maximum buckets allowed in a single range trade (0 = no limit)
    uint256 public maxRangeWidth;                                 // Slot 55

    /// @notice Index of the bucket currently holding the most shares
    uint256 public currentMaxBucketId;                            // Slot 56

    /// @notice Sparse segment tree for O(log n) range operations on bucket exp weights
    BucketTree.Tree private _tree;                                // Slot 57+ (mapping-based)

    event MarketCreated(
        uint256 indexed marketId,
        address indexed creator,
        uint256 poolBalance,
        uint256 alpha,
        uint256 bucketCount
    );

    event MarketResolved(
        uint256 indexed marketId,
        uint256 resolutionValue,
        uint256 winningBucket,
        uint256 resolutionTime
    );

    event LPWithdrawal(
        uint256 indexed marketId,
        address indexed creator,
        uint256 amount,
        int256 profit
    );

    event AlphaDecayConfigured(
        uint256 indexed marketId,
        uint256 alphaInitial,
        uint256 alphaFinal,
        uint256 decayStartTime,
        uint256 decayDuration
    );

    event AlphaSynced(
        uint256 indexed marketId,
        uint256 oldAlpha,
        uint256 newAlpha,
        uint256 syncedAt
    );

    event LPVaultSet(uint256 indexed marketId, address indexed vault);
    event LiquidityAdded(uint256 indexed marketId, address indexed provider, uint256 amountUSDC);
    event SurplusWithdrawn(uint256 indexed marketId, address indexed caller, address indexed recipient, uint256 amountUSDC);
    event MarketEmergencyPaused(uint256 indexed marketId);
    event MarketEmergencyUnpaused(uint256 indexed marketId);
    event RouterUpdated(uint256 indexed marketId, address indexed router);
    event FeesUpdated(uint256 indexed marketId, uint256 feeBps, uint256 protocolFeeBps);
    event MaxRangeWidthUpdated(uint256 indexed marketId, uint256 maxRangeWidth);
    event BucketActivated(uint256 indexed marketId, uint256 indexed bucketId, uint256 lowerBound, uint256 upperBound);

    error InvalidParameters();
    error MarketNotActive();
    error MarketAlreadyResolved();
    error InvalidBucket();
    error InvalidResolutionValue();
    error InsufficientBalance();
    error Unauthorized();
    error SolvencyViolation();
    error InvalidRange();
    error RangeNotWinner();
    error NoSurplusAvailable();
    error BiddingClosed();      // Betting deadline has passed
    error BetTooSmall();        // Below minimum bet size
    error AlreadyInitialized(); // Clone guard: initialize() already called
    error MarketPaused();       // Market is emergency paused
    error RangeTooWide();       // Range exceeds maxRangeWidth

    /// @notice Market metadata for initialization (packed to avoid stack too deep)
    struct MarketMetadata {
        string name;
        string description;
        string resolutionCriteria;
        string valueUnit;
        address resolver;
        uint256 biddingDeadline;
        uint256 scheduledResolutionTime;
        uint256 minBetSize;
    }

    /// @notice Core initialization parameters (packed to avoid stack too deep)
    struct InitParams {
        uint256 marketId;
        address creator;
        address factory;
        address usdcToken;
        address positionNFT;
        uint256 alpha;
        uint256 poolBalance;
        uint256 bucketWidth;
        uint256 maxBucketId;
        uint256[] seededBucketIds;
        uint256[] seededShares;
        uint256 feeBps;
        uint256 protocolFeeBps;
        MarketMetadata metadata;
        address protocolFeeCollector;
    }

    constructor(InitParams memory p) {
        initialize(p);
    }

    /// @notice Initialize market state. Called by the constructor on direct deployment,
    ///         and by MarketFactory after Clones.clone() on the EIP-1167 proxy path.
    ///         Can only be invoked once per contract instance (_initialized guard).
    function initialize(InitParams memory p) public {
        if (_initialized) revert AlreadyInitialized();
        _initialized = true;

        if (p.alpha == 0) revert InvalidParameters();
        if (p.poolBalance == 0) revert InvalidParameters();
        if (p.bucketWidth == 0) revert InvalidParameters();
        if (p.seededBucketIds.length < 2) revert InvalidParameters();
        if (p.seededBucketIds.length != p.seededShares.length) revert InvalidParameters();
        if (p.feeBps > MAX_FEE_BPS) revert InvalidParameters();

        marketId = p.marketId;
        creator = p.creator;
        factory = p.factory;
        usdcToken = IUSDC(p.usdcToken);
        positionNFT = p.positionNFT;
        alpha = p.alpha;
        poolBalance = p.poolBalance;
        initialDeposit = p.poolBalance;
        feeBps = p.feeBps;
        protocolFeeBps = p.protocolFeeBps;
        status = MarketStatus.ACTIVE;

        // Store metadata (Sui parity)
        name = p.metadata.name;
        description = p.metadata.description;
        resolutionCriteria = p.metadata.resolutionCriteria;
        valueUnit = p.metadata.valueUnit;
        resolver = p.metadata.resolver == address(0) ? p.creator : p.metadata.resolver;
        biddingDeadline = p.metadata.biddingDeadline;
        scheduledResolutionTime = p.metadata.scheduledResolutionTime;
        minBetSize = p.metadata.minBetSize;
        creationTime = block.timestamp;
        protocolFeeCollector = p.protocolFeeCollector;

        // Absolute bucket indexing — bucketId = value / bucketWidth
        bucketWidth = p.bucketWidth;
        maxBucketId = p.maxBucketId;
        bucketCount = p.maxBucketId + 1;
        marketMin = 0; // DEPRECATED — set to 0

        // Alpha is a creator-specified market design parameter (6 decimals).
        alphaInitial = alpha;
        alphaFinal = alpha;
        lastAlphaSyncTime = block.timestamp;
        totalDeposited = p.poolBalance;

        // Seed buckets with initial shares
        uint256 seededCount = p.seededBucketIds.length;
        uint256 maxShares = 0;
        uint256 totalShares = 0;
        uint256[] memory seedValues = new uint256[](seededCount);

        for (uint256 i = 0; i < seededCount; i++) {
            uint256 bid = p.seededBucketIds[i];
            uint256 shares = p.seededShares[i];
            if (bid > p.maxBucketId) revert InvalidParameters();
            if (shares == 0) revert InvalidParameters();

            uint256 lower = bid * p.bucketWidth;
            uint256 upper = lower + p.bucketWidth;
            buckets[bid] = Bucket({
                shares: shares,
                initialShares: shares,
                lowerBound: lower,
                upperBound: upper
            });
            seedValues[i] = (((shares + PHANTOM_SHARES) * WAD) / alpha).exp();
            totalShares += shares;
            if (shares > maxShares) maxShares = shares;
        }

        if (totalShares != p.poolBalance) revert InvalidParameters();

        // Lazy tree init: builds only over seeded bucket range, grows on demand
        _tree.initFromSeeds(uint32(maxBucketId), p.seededBucketIds, seedValues);
        maxLiability = maxShares;

        activeBucketCount = seededCount;
        cachedLnBucketCount = seededCount.fromU256().ln();

        // Solvency check
        if (maxLiability > poolBalance + SOLVENCY_DUST) {
            revert SolvencyViolation();
        }

        emit MarketCreated(p.marketId, p.creator, p.poolBalance, alpha, bucketCount);
    }


    /// @notice Safety buffer based on CURRENT alpha (not initial).
    /// @dev As alpha decays, the worst-case future loss shrinks proportionally.
    ///      Capital reserved for a now-impossible high-alpha path is released as surplus.
    ///      For non-decay markets alpha == alphaInitial so behavior is identical.
    function getSafetyBuffer() public view returns (uint256) {
        return ((alpha * 2) * cachedLnBucketCount) / WAD;
    }

    function getRequiredReserves() public view returns (uint256) {
        return maxLiability + getSafetyBuffer();
    }

    function getWithdrawableSurplus() public view returns (uint256) {
        uint256 requiredReserves = getRequiredReserves();
        if (poolBalance <= requiredReserves) return 0;
        return poolBalance - requiredReserves;
    }

    function isAlphaDecayConfigured() internal view returns (bool) {
        return decayDuration > 0 && alphaFinal < alphaInitial;
    }

    function needsAlphaSync() internal view returns (bool) {
        if (!isAlphaDecayConfigured()) return false;
        if (block.timestamp < decayStartTime) return false;
        return block.timestamp >= lastAlphaSyncTime + ALPHA_EPOCH_LENGTH;
    }

    /// @notice Configure epoch-based alpha decay for sniper defense
    /// @dev Once configured, alpha decays linearly from alphaInitial to alphaFinal over decayDuration
    ///      with sync checkpoints every ALPHA_EPOCH_LENGTH.
    ///      Callable by the market creator OR the factory (atomically at creation time).
    /// @param _alphaFinal Alpha floor (6 decimals), must be < alphaInitial and >= 10% of alphaInitial
    /// @param _decayStartTime Timestamp when decay begins
    /// @param _decayDuration Duration of decay in seconds
    function configureAlphaDecay(
        uint256 _alphaFinal,
        uint256 _decayStartTime,
        uint256 _decayDuration
    ) external onlyActive {
        if (msg.sender != creator && msg.sender != factory) revert Unauthorized();
        if (_decayDuration == 0) revert InvalidParameters();
        if (_alphaFinal == 0 || _alphaFinal >= alphaInitial) revert InvalidParameters();

        uint256 minAllowedFinal = (alphaInitial * MIN_ALPHA_FLOOR_BPS) / 10000;
        if (_alphaFinal < minAllowedFinal) revert InvalidParameters();

        alphaFinal = _alphaFinal;
        decayStartTime = _decayStartTime;
        decayDuration = _decayDuration;
        lastAlphaSyncTime = block.timestamp;

        emit AlphaDecayConfigured(marketId, alphaInitial, alphaFinal, decayStartTime, decayDuration);
    }

    /// @notice Permissionless alpha sync endpoint for keepers
    /// @dev Recalculates cached exp terms when entering a new epoch
    function syncAlpha() external onlyActive {
        _syncAlpha();
    }

    function setLPVault(address _lpVault) external onlyActive {
        if (_lpVault == address(0)) revert InvalidParameters();
        if (msg.sender != creator && msg.sender != factory) revert Unauthorized();
        if (lpVault != address(0)) revert InvalidParameters();
        lpVault = _lpVault;
        emit LPVaultSet(marketId, _lpVault);
    }

    /// @notice Set the authorized trade router (factory-only, one-time)
    /// @notice Set or update the authorized trade router (factory-only)
    function setRouter(address _router) external {
        if (msg.sender != factory) revert Unauthorized();
        router = _router;
        emit RouterUpdated(marketId, _router);
    }

    /// @notice Emergency pause — blocks all trading, claims, and LP operations
    /// @dev Only callable by the factory contract (controlled by owner/multisig)
    function emergencyPause() external {
        if (msg.sender != factory) revert Unauthorized();
        if (status == MarketStatus.RESOLVED) revert MarketAlreadyResolved();
        if (status == MarketStatus.EMERGENCY_PAUSED) revert MarketPaused();
        status = MarketStatus.EMERGENCY_PAUSED;
        emit MarketEmergencyPaused(marketId);
    }

    /// @notice Unpause an emergency-paused market, returning it to ACTIVE
    /// @dev Only callable by the factory contract
    function emergencyUnpause() external {
        if (msg.sender != factory) revert Unauthorized();
        if (status != MarketStatus.EMERGENCY_PAUSED) revert InvalidParameters();
        status = MarketStatus.ACTIVE;
        emit MarketEmergencyUnpaused(marketId);
    }

    /// @notice Update fee configuration (factory-only)
    function setFees(uint256 _feeBps, uint256 _protocolFeeBps) external {
        if (msg.sender != factory) revert Unauthorized();
        if (_feeBps > MAX_FEE_BPS) revert InvalidParameters();
        if (_protocolFeeBps > 10000) revert InvalidParameters();
        feeBps = _feeBps;
        protocolFeeBps = _protocolFeeBps;
        emit FeesUpdated(marketId, _feeBps, _protocolFeeBps);
    }

    /// @notice Set max range width (factory-only, called post-initialize)
    /// @param _maxRangeWidth Max buckets per range trade (0 = no limit)
    function setMaxRangeWidth(uint256 _maxRangeWidth) external {
        if (msg.sender != factory) revert Unauthorized();
        maxRangeWidth = _maxRangeWidth;
        emit MaxRangeWidthUpdated(marketId, _maxRangeWidth);
    }

    function addLiquidity(uint256 amountUSDC) external nonReentrant onlyActive {
        if (amountUSDC == 0) revert InvalidParameters();
        if (msg.sender != creator && msg.sender != lpVault) revert Unauthorized();

        IERC20(address(usdcToken)).safeTransferFrom(msg.sender, address(this), amountUSDC);
        poolBalance += amountUSDC;
        totalDeposited += amountUSDC; // track cumulative deposits for accurate profit basis

        emit LiquidityAdded(marketId, msg.sender, amountUSDC);
    }

    function withdrawSurplus(address recipient, uint256 amountUSDC)
        external
        nonReentrant
        onlyActive
        returns (uint256 withdrawnUSDC)
    {
        if (recipient == address(0)) revert InvalidParameters();
        if (msg.sender != creator && msg.sender != lpVault) revert Unauthorized();

        // Lazy refresh maxLiability before calculating surplus to avoid over-locking
        _scanMaxLiability(false);

        uint256 withdrawable = getWithdrawableSurplus();
        if (withdrawable == 0) revert NoSurplusAvailable();

        withdrawnUSDC = amountUSDC;
        if (withdrawnUSDC == type(uint256).max) {
            withdrawnUSDC = withdrawable;
        }

        if (withdrawnUSDC == 0 || withdrawnUSDC > withdrawable) revert InvalidParameters();

        poolBalance -= withdrawnUSDC;
        totalSurplusWithdrawn += withdrawnUSDC; // reduce net cost basis — this capital already returned
        IERC20(address(usdcToken)).safeTransfer(recipient, withdrawnUSDC);

        emit SurplusWithdrawn(marketId, msg.sender, recipient, withdrawnUSDC);
    }

    modifier onlyActive() {
        if (status != MarketStatus.ACTIVE) revert MarketNotActive();
        _;
    }

    modifier onlyCreator() {
        if (msg.sender != creator) revert Unauthorized();
        _;
    }

    modifier onlyRouter() {
        if (router != address(0) && msg.sender != router) revert Unauthorized();
        _;
    }

    function _calculateCostFunction() internal view returns (uint256) {
        uint256 lnSum = _tree.totalSum().ln();
        return (alpha * lnSum) / WAD;
    }

    function _positionTokenEnabled() internal view returns (bool) {
        return positionNFT != address(0) && positionNFT.code.length > 0;
    }

    function _routeProtocolFee(uint256 protocolFee) internal {
        if (protocolFee > 0) {
            if (protocolFeeCollector != address(0)) {
                IERC20(address(usdcToken)).safeTransfer(protocolFeeCollector, protocolFee);
            } else {
                poolBalance += protocolFee; // return to pool if no collector configured
            }
        }
    }

    /// @notice Encode token ID for a range of buckets (single bucket: rangeLower == rangeUpper)
    /// @dev Matches PositionNFT.encodeTokenId format: (marketId << 128) | (rangeLower << 64) | rangeUpper
    function _tokenIdForRange(uint256 rangeLower, uint256 rangeUpper) internal view returns (uint256) {
        return (uint256(uint128(marketId)) << 128) | (uint256(uint64(rangeLower)) << 64) | uint256(uint64(rangeUpper));
    }

    /// @notice Get sum of all exp weights EXCEPT the given bucket — O(log n) via tree
    function _getSumOther(uint256 bucketId) internal view returns (uint256) {
        return _tree.totalSum() - _tree.leafValue(uint32(bucketId));
    }

    /// @notice Check if a bucket has been activated (has LMSR weight)
    /// @dev Inactive buckets have default Bucket{0, 0, 0} — upperBound == lowerBound == 0
    function _isBucketActive(uint256 bucketId) internal view returns (bool) {
        return buckets[bucketId].upperBound > buckets[bucketId].lowerBound;
    }

    function calculateSharesForCost(uint256 bucketId, uint256 costUSDC)
        external
        view
        returns (uint256 shares)
    {
        if (bucketId >= bucketCount) revert InvalidBucket();
        
        uint256 C_before = _calculateCostFunctionView(); // 6 decimals
        
        // Sui-style sparse cache: O(1) instead of O(n) loop
        uint256 sumOther = _getSumOther(bucketId);
        
        uint256 C_new = C_before + costUSDC; // 6 decimals
        uint256 ratio = (C_new * WAD) / alpha; // Scale to WAD
        uint256 expCNewOverAlpha = ratio.exp();
        
        uint256 innerTerm = expCNewOverAlpha - sumOther;
        uint256 lnInnerTerm = innerTerm.ln(); // Returns WAD (18 decimals)
        uint256 newSharesWithPhantom = (alpha * lnInnerTerm) / WAD; // 6 decimals
        
        // Subtract phantom shares to get actual shares
        uint256 newShares = newSharesWithPhantom - PHANTOM_SHARES;
        shares = newShares - buckets[bucketId].shares; // All 6 decimals
    }

    /// @notice View-only cost function — tree is always consistent, no dirty flag
    function _calculateCostFunctionView() internal view returns (uint256) {
        uint256 lnSum = _tree.totalSum().ln();
        return (alpha * lnSum) / WAD;
    }

    function _computeDecayedAlpha(uint256 timestamp) internal view returns (uint256) {
        if (!isAlphaDecayConfigured()) return alpha;
        if (timestamp <= decayStartTime) return alphaInitial;

        uint256 elapsed = timestamp - decayStartTime;
        if (elapsed >= decayDuration) return alphaFinal;

        uint256 totalDrop = alphaInitial - alphaFinal;
        uint256 decayed = (totalDrop * elapsed) / decayDuration;
        return alphaInitial - decayed;
    }

    function _syncAlpha() internal {
        if (!needsAlphaSync()) return;

        uint256 newAlpha = _computeDecayedAlpha(block.timestamp);
        uint256 oldAlpha = alpha;

        // Advance epoch marker even if alpha unchanged (e.g., already at floor)
        lastAlphaSyncTime = block.timestamp;

        if (newAlpha == oldAlpha) {
            return;
        }

        alpha = newAlpha;

        // Rebuild tree with new alpha — O(n log n) but runs at most once per epoch (30 min)
        // Use tree's actual offset and count (lazy tree may cover a subset of bucketCount)
        uint32 offset = _tree.leafOffset;
        uint32 count = _tree.leafCount;
        uint256[] memory values = new uint256[](count);
        for (uint32 i = 0; i < count; i++) {
            uint256 absoluteBucketId = uint256(offset + i);
            if (!_isBucketActive(absoluteBucketId)) {
                values[i] = 0;
                continue;
            }
            uint256 q = buckets[absoluteBucketId].shares + PHANTOM_SHARES;
            values[i] = ((q * WAD) / newAlpha).exp();
        }
        _tree.seedWithValues(values);

        emit AlphaSynced(marketId, oldAlpha, newAlpha, block.timestamp);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // UNIFIED BUY — single bucket + correlated range in one entry point
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Buy shares across a contiguous range of outcomes (Correlated LMSR)
    /// @dev For single-bucket buys, pass rangeLower/rangeUpper that map to one bucket.
    ///      User pays once, receives shares that cover ALL buckets in range.
    /// @param rangeLower Lower bound in value space (inclusive)
    /// @param rangeUpper Upper bound in value space (exclusive)
    /// @param amountUSDC Maximum USDC to spend (6 decimals)
    /// @param minSharesOut Minimum shares to receive (slippage protection)
    /// @param targetShares FE-provided quote hint (0 = binary search, >0 = try fast path first)
    function buySharesRange(
        uint256 rangeLower,
        uint256 rangeUpper,
        uint256 amountUSDC,
        uint256 minSharesOut,
        uint256 targetShares,
        address recipient
    ) external nonReentrant onlyActive onlyRouter returns (uint256 shares) {
        if (recipient == address(0)) recipient = msg.sender;
        _syncAlpha();
        if (amountUSDC == 0) revert InvalidParameters();
        if (biddingDeadline != 0 && block.timestamp > biddingDeadline) revert BiddingClosed();
        if (minBetSize != 0 && amountUSDC < minBetSize) revert BetTooSmall();

        (uint256 startBucket, uint256 endBucket) = _rangeToBuckets(rangeLower, rangeUpper);

        // Activate any inactive buckets in range (lazy activation)
        for (uint256 b = startBucket; b <= endBucket; b++) {
            if (!_isBucketActive(b)) {
                _activateBucket(b);
            }
        }

        // ── Single-bucket fast path: direct LMSR math (no binary search) ──
        if (startBucket == endBucket) {
            return _executeBuySingle(startBucket, amountUSDC, minSharesOut, recipient);
        }

        // ── Multi-bucket range path ──
        uint256 feesUSDC = (amountUSDC * feeBps) / 10000;
        uint256 netAmount = amountUSDC - feesUSDC;

        uint256 actualCost;
        {
            uint256 sumBefore = _tree.totalSum();
            uint256 rSum = _tree.rangeSum(uint32(startBucket), uint32(endBucket));

            if (targetShares > 0) {
                uint256 factor = LMSRCost.sharesToFactor(targetShares, alpha);
                uint256 sumAfter = sumBefore - rSum + Math.mulDiv(rSum, factor, WAD);
                uint256 cost = LMSRCost.costFromDelta(alpha, sumBefore, sumAfter);
                if (cost <= netAmount) {
                    shares = targetShares;
                    actualCost = cost;
                }
            }

            if (shares == 0) {
                shares = LMSRCost.sharesFromCost(alpha, sumBefore, rSum, netAmount);
                if (shares > 0) {
                    uint256 factor = LMSRCost.sharesToFactor(shares, alpha);
                    uint256 sumAfter = sumBefore - rSum + Math.mulDiv(rSum, factor, WAD);
                    actualCost = LMSRCost.costFromDelta(alpha, sumBefore, sumAfter);
                }
            }
        }

        if (shares < minSharesOut) revert InvalidParameters();

        uint256 protocolFee = (feesUSDC * protocolFeeBps) / 10000;
        uint256 lpFee = feesUSDC - protocolFee;

        _validateRangeSolvency(startBucket, endBucket, shares, actualCost + lpFee);
        _applyRangeBuy(startBucket, endBucket, shares, actualCost + lpFee);

        // Only pull what's needed: cost + fees (refund unused budget)
        uint256 totalPull = actualCost + feesUSDC;

        feesCollectedLP += lpFee;
        lpFeesAccrued += lpFee;
        feesCollectedProtocol += protocolFee;
        totalVolume += totalPull;
        IERC20(address(usdcToken)).safeTransferFrom(msg.sender, address(this), totalPull);
        _routeProtocolFee(protocolFee);

        if (_positionTokenEnabled()) {
            IPositionNFT(positionNFT).mint(recipient, _tokenIdForRange(startBucket, endBucket), shares);
        }

    }

    /// @dev Single-bucket buy: direct LMSR cost function (no binary search needed)
    function _executeBuySingle(uint256 bucketId, uint256 amountUSDC, uint256 minSharesOut, address recipient)
        internal
        returns (uint256 sharesMinted)
    {
        uint256 C_before = _calculateCostFunction();
        uint256 sumOther = _getSumOther(bucketId);

        uint256 feesUSDC = (amountUSDC * feeBps) / 10000;
        uint256 netCostUSDC = amountUSDC - feesUSDC;

        uint256 C_new = C_before + netCostUSDC;
        uint256 ratio = (C_new * WAD) / alpha;
        uint256 expCNewOverAlpha = ratio.exp();

        uint256 innerTerm = expCNewOverAlpha - sumOther;
        uint256 lnInnerTerm = innerTerm.ln();
        uint256 newSharesWithPhantom = (alpha * lnInnerTerm) / WAD;
        uint256 newShares = newSharesWithPhantom - PHANTOM_SHARES;

        sharesMinted = newShares - buckets[bucketId].shares;
        if (sharesMinted < minSharesOut) revert InvalidParameters();

        uint256 newPoolBalance = poolBalance + netCostUSDC;
        if (newShares > newPoolBalance + SOLVENCY_DUST) {
            revert SolvencyViolation();
        }

        buckets[bucketId].shares = newShares;
        if (newShares > maxLiability) {
            maxLiability = newShares;
            currentMaxBucketId = bucketId;
        }

        _applyTreeBuyFactor(uint32(bucketId), uint32(bucketId), sharesMinted);

        uint256 protocolFee = (feesUSDC * protocolFeeBps) / 10000;
        uint256 lpFee = feesUSDC - protocolFee;

        poolBalance += netCostUSDC + lpFee;
        feesCollectedLP += lpFee;
        lpFeesAccrued += lpFee;
        feesCollectedProtocol += protocolFee;
        totalVolume += amountUSDC;

        IERC20(address(usdcToken)).safeTransferFrom(msg.sender, address(this), amountUSDC);
        _routeProtocolFee(protocolFee);

        if (_positionTokenEnabled()) {
            IPositionNFT(positionNFT).mint(recipient, _tokenIdForRange(bucketId, bucketId), sharesMinted);
        }

    }

    // ═══════════════════════════════════════════════════════════════════════════
    // UNIFIED SELL — single bucket + correlated range in one entry point
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Sell shares from a position (single bucket or range)
    /// @param rangeLower Lower bound in value space (inclusive)
    /// @param rangeUpper Upper bound in value space (exclusive)
    /// @param sharesToSell Number of shares to sell
    /// @param minUsdcOut Minimum USDC to receive (slippage protection)
    function sellSharesRange(
        uint256 rangeLower,
        uint256 rangeUpper,
        uint256 sharesToSell,
        uint256 minUsdcOut,
        address recipient
    ) external nonReentrant onlyActive onlyRouter returns (uint256 payoutUSDC) {
        if (recipient == address(0)) recipient = msg.sender;
        _syncAlpha();
        if (sharesToSell == 0) revert InvalidParameters();
        if (biddingDeadline != 0 && block.timestamp > biddingDeadline) revert BiddingClosed();

        (uint256 startBucket, uint256 endBucket) = _rangeToBuckets(rangeLower, rangeUpper);

        // Validate user has enough shares in all buckets
        for (uint256 b = startBucket; b <= endBucket; b++) {
            if (buckets[b].shares < sharesToSell) revert InsufficientBalance();
        }

        if (_positionTokenEnabled()) {
            uint256 rangeTokenId = _tokenIdForRange(startBucket, endBucket);
            if (IPositionNFT(positionNFT).balanceOf(msg.sender, rangeTokenId) < sharesToSell) {
                revert InsufficientBalance();
            }
        }

        // ── Single-bucket fast path: direct LMSR math ──
        if (startBucket == endBucket) {
            return _executeSellSingle(startBucket, sharesToSell, minUsdcOut, recipient);
        }

        // ── Multi-bucket range path ──
        uint256 grossPayout = _calculateRangeSellReturn(startBucket, endBucket, sharesToSell);
        uint256 feesUSDC = (grossPayout * feeBps) / 10000;
        payoutUSDC = grossPayout - feesUSDC;
        if (payoutUSDC < minUsdcOut) revert InvalidParameters();

        uint256 protocolFee = (feesUSDC * protocolFeeBps) / 10000;
        uint256 lpFee = feesUSDC - protocolFee;

        _applyRangeSell(startBucket, endBucket, sharesToSell, payoutUSDC + protocolFee);

        feesCollectedLP += lpFee;
        lpFeesAccrued += lpFee;
        feesCollectedProtocol += protocolFee;
        totalVolume += grossPayout;

        // Solvency check
        bool affectsMax = false;
        for (uint256 b = startBucket; b <= endBucket; b++) {
            if (b == currentMaxBucketId) { affectsMax = true; break; }
        }
        if (affectsMax) {
            _scanMaxLiability(true);
        } else {
            _checkSolvency();
        }

        if (_positionTokenEnabled()) {
            IPositionNFT(positionNFT).burn(msg.sender, _tokenIdForRange(startBucket, endBucket), sharesToSell);
        }

        _routeProtocolFee(protocolFee);
        IERC20(address(usdcToken)).safeTransfer(recipient, payoutUSDC);

    }

    /// @dev Single-bucket sell: direct LMSR cost function
    function _executeSellSingle(uint256 bucketId, uint256 sharesToSell, uint256 minPayoutOut, address recipient)
        internal
        returns (uint256 payoutUSDC)
    {
        uint256 C_before = _calculateCostFunction();
        uint256 sumOther = _getSumOther(bucketId);

        uint256 newShares = buckets[bucketId].shares - sharesToSell;
        uint256 q = newShares + PHANTOM_SHARES;
        uint256 ratio = (q * WAD) / alpha;
        uint256 newBucketExp = ratio.exp();

        uint256 newSumExp = sumOther + newBucketExp;
        uint256 lnNewSum = newSumExp.ln();
        uint256 C_after = (alpha * lnNewSum) / WAD;

        uint256 grossPayoutUSDC = C_before - C_after;
        uint256 feesUSDC = (grossPayoutUSDC * feeBps) / 10000;
        payoutUSDC = grossPayoutUSDC - feesUSDC;
        if (payoutUSDC < minPayoutOut) revert InvalidParameters();

        buckets[bucketId].shares = newShares;
        _applyTreeSellFactor(uint32(bucketId), uint32(bucketId), sharesToSell);

        uint256 protocolFee = (feesUSDC * protocolFeeBps) / 10000;
        uint256 lpFee = feesUSDC - protocolFee;

        poolBalance -= (payoutUSDC + protocolFee);
        feesCollectedLP += lpFee;
        lpFeesAccrued += lpFee;
        feesCollectedProtocol += protocolFee;
        totalVolume += grossPayoutUSDC;

        if (bucketId == currentMaxBucketId) {
            _scanMaxLiability(true);
        } else {
            _checkSolvency();
        }

        if (_positionTokenEnabled()) {
            IPositionNFT(positionNFT).burn(msg.sender, _tokenIdForRange(bucketId, bucketId), sharesToSell);
        }

        _routeProtocolFee(protocolFee);
        IERC20(address(usdcToken)).safeTransfer(recipient, payoutUSDC);

    }

    // ═══════════════════════════════════════════════════════════════════════════
    // UNIFIED CLAIM — decode tokenId, check winner, pay full balance
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Claim winnings by presenting your position NFT token ID
    /// @dev Decodes tokenId to determine range, checks if winning bucket is in range,
    ///      claims full NFT balance (no partial claims). Works for single and range positions.
    /// @param tokenId The ERC-1155 position token ID (encodes marketId + bucket range)
    /// @return payoutUSDC Amount of USDC received ($1 per share)
    function claim(uint256 tokenId, address recipient) external nonReentrant onlyRouter returns (uint256 payoutUSDC) {
        if (recipient == address(0)) recipient = msg.sender;
        if (status != MarketStatus.RESOLVED) revert MarketNotActive();

        // Decode tokenId inline: (marketId << 128) | (rangeLower << 64) | rangeUpper
        uint256 tokenMarketId = tokenId >> 128;
        uint256 rangeLower = uint256(uint64(tokenId >> 64));
        uint256 rangeUpper = uint256(uint64(tokenId));

        if (tokenMarketId != marketId) revert InvalidParameters();
        if (winningBucket < rangeLower || winningBucket > rangeUpper) revert RangeNotWinner();

        if (!_positionTokenEnabled()) revert InvalidParameters();

        uint256 balance = IPositionNFT(positionNFT).balanceOf(msg.sender, tokenId);
        if (balance == 0) revert InsufficientBalance();

        payoutUSDC = balance;
        buckets[winningBucket].shares -= balance;
        poolBalance -= payoutUSDC;

        IPositionNFT(positionNFT).burn(msg.sender, tokenId, balance);
        IERC20(address(usdcToken)).safeTransfer(recipient, payoutUSDC);

    }

    /// @notice Get quote for buying shares across a range
    /// @return shares Estimated shares receivable
    /// @return cost Estimated cost in USDC
    /// @return odds Potential return multiplier (shares/cost)
    function getQuoteForRange(
        uint256 rangeLower,
        uint256 rangeUpper,
        uint256 amountUSDC
    ) external view returns (uint256 shares, uint256 cost, uint256 odds) {
        (uint256 startBucket, uint256 endBucket) = _rangeToBuckets(rangeLower, rangeUpper);

        uint256 feesUSDC = (amountUSDC * feeBps) / 10000;
        uint256 netAmount = amountUSDC - feesUSDC;

        uint256 sumBefore = _tree.totalSum();
        uint256 rSum = _tree.rangeSum(uint32(startBucket), uint32(endBucket));

        // Simulate activation of inactive buckets in range for accurate quote
        uint256 phantomExp = ((PHANTOM_SHARES * WAD) / alpha).exp();
        for (uint256 b = startBucket; b <= endBucket; b++) {
            if (!_isBucketActive(b)) {
                sumBefore += phantomExp;
                rSum += phantomExp;
            }
        }

        // Algebraic solve — O(1) replaces 20-iteration binary search
        if (rSum > 0) {
            shares = LMSRCost.sharesFromCost(alpha, sumBefore, rSum, netAmount);
        }

        // Solvency cap
        uint256 maxPool = poolBalance + netAmount + SOLVENCY_DUST;
        for (uint256 b = startBucket; b <= endBucket; b++) {
            uint256 currentShares = !_isBucketActive(b) ? 0 : buckets[b].shares;
            uint256 available = maxPool > currentShares ? maxPool - currentShares : 0;
            if (available < shares) shares = available;
        }

        if (shares > 0) {
            uint256 factor = LMSRCost.sharesToFactor(shares, alpha);
            uint256 sumAfter = sumBefore - rSum + Math.mulDiv(rSum, factor, WAD);
            cost = LMSRCost.costFromDelta(alpha, sumBefore, sumAfter);
        }

        if (cost > 0) {
            odds = (shares * 1e6) / cost;
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL HELPERS - Clean separation of concerns
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Convert value range to absolute bucket indices (called ONCE per transaction)
    /// @param lower Lower bound in value space (inclusive)
    /// @param upper Upper bound in value space (exclusive)
    /// @return startBucket First bucket index (absolute)
    /// @return endBucket Last bucket index (inclusive, absolute)
    function _rangeToBuckets(uint256 lower, uint256 upper)
        internal view returns (uint256 startBucket, uint256 endBucket)
    {
        if (lower >= upper) revert InvalidRange();
        if (bucketWidth == 0) revert InvalidParameters();

        // Absolute indexing: bucketId = value / bucketWidth
        startBucket = lower / bucketWidth;
        endBucket = (upper - 1) / bucketWidth;

        if (endBucket > maxBucketId) revert InvalidRange();

        // Enforce max range width if configured
        if (maxRangeWidth > 0 && (endBucket - startBucket + 1) > maxRangeWidth) {
            revert RangeTooWide();
        }
    }

    /// @dev Calculate return for selling shares from a range — O(log n) via tree
    function _calculateRangeSellReturn(
        uint256 startBucket,
        uint256 endBucket,
        uint256 sharesToSell
    ) internal view returns (uint256 returnUSDC) {
        uint256 sumBefore = _tree.totalSum();
        uint256 rSum = _tree.rangeSum(uint32(startBucket), uint32(endBucket));
        uint256 inverseFactor = LMSRCost.sharesToInverseFactor(sharesToSell, alpha);
        uint256 sumAfter = sumBefore - rSum + Math.mulDiv(rSum, inverseFactor, WAD);
        returnUSDC = LMSRCost.proceedsFromDelta(alpha, sumBefore, sumAfter);
    }

    /// @dev Validate solvency for range purchase
    function _validateRangeSolvency(
        uint256 startBucket,
        uint256 endBucket,
        uint256 sharesToAdd,
        uint256 costPaid
    ) internal view {
        uint256 newPoolBalance = poolBalance + costPaid;
        
        for (uint256 b = startBucket; b <= endBucket; b++) {
            uint256 newShares = buckets[b].shares + sharesToAdd;
            if (newShares > newPoolBalance + SOLVENCY_DUST) {
                revert SolvencyViolation();
            }
        }
    }

    /// @dev Atomic state update for range buy — O(log n) via tree
    function _applyRangeBuy(
        uint256 startBucket,
        uint256 endBucket,
        uint256 shares,
        uint256 cost
    ) internal {
        // Update flat bucket shares and maxLiability
        for (uint256 b = startBucket; b <= endBucket; b++) {
            uint256 newShares = buckets[b].shares + shares;
            buckets[b].shares = newShares;

            if (newShares > maxLiability) {
                maxLiability = newShares;
                currentMaxBucketId = b;
            }
        }

        // Update tree — O(log n) with chunked factor application
        _applyTreeBuyFactor(uint32(startBucket), uint32(endBucket), shares);

        poolBalance += cost;
    }

    /// @dev Atomic state update for range sell — O(log n) via tree
    function _applyRangeSell(
        uint256 startBucket,
        uint256 endBucket,
        uint256 shares,
        uint256 payout
    ) internal {
        // Update flat bucket shares
        for (uint256 b = startBucket; b <= endBucket; b++) {
            buckets[b].shares -= shares;
        }

        // Update tree — O(log n) with chunked factor application
        _applyTreeSellFactor(uint32(startBucket), uint32(endBucket), shares);

        poolBalance -= payout;
    }

    /// @notice O(1) solvency check — only validates the current max bucket
    function _checkSolvency() internal view {
        if (buckets[currentMaxBucketId].shares > poolBalance + SOLVENCY_DUST) {
            revert SolvencyViolation();
        }
    }

    /// @notice Unified max liability scanner
    /// @param checkSolvency If true, reverts on solvency violation and unconditionally updates.
    ///                      If false, only decreases maxLiability (refresh mode).
    function _scanMaxLiability(bool checkSolvency) internal {
        uint256 currentMax = 0;
        uint256 maxBucket = 0;
        for (uint256 i = 0; i <= maxBucketId; i++) {
            if (!_isBucketActive(i)) continue;
            if (checkSolvency && buckets[i].shares > poolBalance + SOLVENCY_DUST) {
                revert SolvencyViolation();
            }
            if (buckets[i].shares > currentMax) {
                currentMax = buckets[i].shares;
                maxBucket = i;
            }
        }
        if (checkSolvency || currentMax < maxLiability) {
            maxLiability = currentMax;
            currentMaxBucketId = maxBucket;
        }
    }


    function calculateReturnForShares(uint256 bucketId, uint256 sharesToSell)
        external
        view
        returns (uint256 returnUSDC)
    {
        if (bucketId >= bucketCount) revert InvalidBucket();
        if (sharesToSell == 0) return 0;
        if (sharesToSell > buckets[bucketId].shares) revert InsufficientBalance();
        
        uint256 C_before = _calculateCostFunctionView(); // 6 decimals
        
        // Sui-style sparse cache: O(1) instead of O(n) loop
        uint256 sumOther = _getSumOther(bucketId);
        
        uint256 newShares = buckets[bucketId].shares - sharesToSell; // 6 decimals
        uint256 q = newShares + PHANTOM_SHARES; // 6 decimals
        uint256 ratio = (q * WAD) / alpha; // Scale to WAD
        uint256 newBucketExp = ratio.exp();
        
        uint256 newSumExp = sumOther + newBucketExp;
        uint256 lnNewSum = newSumExp.ln(); // Returns WAD (18 decimals)
        uint256 C_after = (alpha * lnNewSum) / WAD; // 6 decimals
        
        returnUSDC = C_before - C_after; // Already 6 decimals
    }


    /// @notice Resolve market with winning outcome value (Sui parity)
    /// @dev Takes a resolution value in the market's value space (e.g., $115,000) and
    ///      calculates which bucket contains that value. Matches Sui's resolve_market_with_outcome.
    /// @param _resolutionValue The actual outcome value (e.g., 115000 for $115K)
    function resolveMarket(uint256 _resolutionValue) external {
        if (msg.sender != resolver) revert Unauthorized();
        if (status != MarketStatus.ACTIVE) revert MarketAlreadyResolved();

        // Absolute bucket indexing: bucketId = value / bucketWidth
        uint256 calculatedBucket = _resolutionValue / bucketWidth;
        if (calculatedBucket > maxBucketId) revert InvalidResolutionValue();

        status = MarketStatus.RESOLVED;
        resolutionValue = _resolutionValue;
        winningBucket = calculatedBucket;
        resolutionTime = block.timestamp;

        emit MarketResolved(marketId, _resolutionValue, calculatedBucket, block.timestamp);
    }

    /// @notice Withdraw LP funds after market resolution
    /// @dev Callable by the market creator OR the registered lpVault.
    ///      When called by lpVault the funds flow back to the vault (not to creator) so
    ///      the multi-vault can recycle capital across markets.
    function withdrawLP() external nonReentrant {
        if (msg.sender != creator && msg.sender != lpVault) revert Unauthorized();
        if (status != MarketStatus.RESOLVED) revert MarketNotActive();
        if (lpWithdrawn) revert InvalidParameters();

        // LP's initial shares in winning bucket — nobody holds NFTs for these
        uint256 lpInitialShares = buckets[winningBucket].initialShares;

        // Only trader-held shares need to be reserved for claims
        uint256 totalWinningShares = buckets[winningBucket].shares;
        uint256 traderPayoutsRequired = totalWinningShares > lpInitialShares
            ? totalWinningShares - lpInitialShares
            : 0;

        // Available for LP = pool - trader claims (LP recovers their initial shares)
        uint256 availableForLP = poolBalance - traderPayoutsRequired;

        // Net cost basis: what was deposited minus what was already returned via surplus withdrawals
        uint256 netDeposit = totalDeposited > totalSurplusWithdrawn
            ? totalDeposited - totalSurplusWithdrawn
            : 0;

        // Calculate profit (can be negative)
        int256 profit = int256(availableForLP) - int256(netDeposit);

        // Reset pool balance to prevent re-withdrawal
        uint256 withdrawAmount = availableForLP;
        poolBalance = traderPayoutsRequired; // Leave exactly enough for trader claims
        lpWithdrawn = true;

        // Transfer to caller: creator or lpVault (vault recycles capital into next markets)
        IERC20(address(usdcToken)).safeTransfer(msg.sender, withdrawAmount);

        emit LPWithdrawal(marketId, msg.sender, withdrawAmount, profit);
    }

    /// @notice Get LP profitability metrics
    /// @return unrealizedProfit Current profit/loss (before withdrawal)
    /// @return roi Return on investment in basis points
    /// @return feesEarned Total fees collected for LP
    function getLPProfitability() external view returns (int256 unrealizedProfit, int256 roi, uint256 feesEarned) {
        // Net cost basis: total deposited minus capital already returned via surplus withdrawals
        uint256 netDeposit = totalDeposited > totalSurplusWithdrawn
            ? totalDeposited - totalSurplusWithdrawn
            : 0;

        if (status != MarketStatus.RESOLVED) {
            // Pre-resolution: pool minus what's still owed as net deposit
            unrealizedProfit = int256(poolBalance) - int256(netDeposit);
        } else {
            // Post-resolution: only trader shares are owed, LP recovers initial shares
            uint256 lpInitShares = buckets[winningBucket].initialShares;
            uint256 totalWinShares = buckets[winningBucket].shares;
            uint256 traderOwed = totalWinShares > lpInitShares ? totalWinShares - lpInitShares : 0;
            uint256 availableForLP = poolBalance > traderOwed
                ? poolBalance - traderOwed
                : 0;
            unrealizedProfit = int256(availableForLP) - int256(netDeposit);
        }

        // ROI against net deposit (accounts for re-deployed surplus)
        if (netDeposit > 0) {
            roi = (unrealizedProfit * 10000) / int256(netDeposit);
        } else {
            roi = 0;
        }

        feesEarned = feesCollectedLP;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // BUCKET ACTIVATION — Dynamic range expansion
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Activate an inactive bucket on first trade — sets bounds, tree leaf, and increments counter
    function _activateBucket(uint256 bucketId) internal {
        uint256 lower = bucketId * bucketWidth;
        uint256 upper = lower + bucketWidth;

        buckets[bucketId] = Bucket({
            shares: 0,
            initialShares: 0,
            lowerBound: lower,
            upperBound: upper
        });

        // Grow tree if this bucket is outside current range
        uint32 bid32 = uint32(bucketId);
        if (bid32 < _tree.leafOffset || bid32 >= _tree.leafOffset + _tree.leafCount) {
            _tree.growToInclude(bid32);
        }

        // Set tree leaf to phantom weight: exp(PHANTOM_SHARES / alpha)
        uint256 phantomExp = ((PHANTOM_SHARES * WAD) / alpha).exp();
        _tree.setLeaf(uint32(bucketId), phantomExp);

        activeBucketCount++;
        cachedLnBucketCount = activeBucketCount.fromU256().ln();

        emit BucketActivated(marketId, bucketId, lower, upper);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TREE HELPERS — Chunked factor application for BucketTree
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Maximum shares per chunk to keep tree factor within bounds
    function _maxChunkShares() internal view returns (uint256) {
        // exp(4) ≈ 54.6 WAD, well within MAX_FACTOR (100 WAD)
        return alpha * 4;
    }

    /// @dev Apply buy factor to tree with chunking for large trades
    function _applyTreeBuyFactor(uint32 lo, uint32 hi, uint256 shares) internal {
        uint256 maxChunk = _maxChunkShares();
        while (shares > 0) {
            uint256 chunk = shares > maxChunk ? maxChunk : shares;
            uint256 factor = LMSRCost.sharesToFactor(chunk, alpha);
            _tree.applyFactor(lo, hi, factor);
            shares -= chunk;
        }
    }

    /// @dev Apply sell (inverse) factor to tree with chunking for large trades
    function _applyTreeSellFactor(uint32 lo, uint32 hi, uint256 shares) internal {
        uint256 maxChunk = _maxChunkShares();
        while (shares > 0) {
            uint256 chunk = shares > maxChunk ? maxChunk : shares;
            uint256 inverseFactor = LMSRCost.sharesToInverseFactor(chunk, alpha);
            _tree.applyFactor(lo, hi, inverseFactor);
            shares -= chunk;
        }
    }
}
