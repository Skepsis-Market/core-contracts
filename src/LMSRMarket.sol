// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IUSDC} from "./interfaces/IUSDC.sol";
import {IPositionNFT} from "./interfaces/IPositionNFT.sol";
import {IERC20Permit} from "@openzeppelin/token/ERC20/extensions/IERC20Permit.sol";
import {FixedPointMath} from "./FixedPointMath.sol";
import {ReentrancyGuard} from "@openzeppelin/utils/ReentrancyGuard.sol";

/// @notice Core LMSR market contract for prediction markets
contract LMSRMarket is ReentrancyGuard {
    using FixedPointMath for uint256;

    struct Bucket {
        uint256 shares; // 6 decimals (matches USDC)
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
    uint256 public constant CACHE_RESET_INTERVAL = 100;
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
    uint256 public marketMin;     // Minimum value (e.g., 110000 for $110K)
    uint256 public marketMax;     // Maximum value (e.g., 120000 for $120K)  
    uint256 public bucketWidth;   // Value units per bucket

    uint256 private cachedLnBucketCount;

    mapping(uint256 => Bucket) public buckets;

    MarketStatus public status;
    uint256 public winningBucket;
    uint256 public resolutionValue;  // Original value that resolved the market (e.g., $115,000)
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

    // Sui-style sparse cache: O(k) instead of O(n)
    uint256 private cachedSumExp;           // Σ exp(q_i/α) for all buckets
    mapping(uint256 => uint256) private cachedBucketExp;  // exp(q_i/α) per bucket
    bool private sumExpDirty;
    uint256 private tradeCount;

    // ═══════════════════════════════════════════════════════════════════════════
    // NEW STORAGE — appended for EIP-1167 clone safety
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Configurable protocol fee recipient (replaces hardcoded constant)
    address public protocolFeeCollector;                          // Slot 46

    // Slots 47-53 reserved for future dispute resolution & cancellation
    uint256[7] private __reservedForFutureUse;

    /// @notice Cumulative LP fees that stayed in the contract (accounting transparency)
    uint256 public lpFeesAccrued;                                 // Slot 54

    /// @notice Maximum buckets allowed in a single range trade (0 = no limit)
    uint256 public maxRangeWidth;                                 // Slot 55

    /// @notice Index of the bucket currently holding the most shares
    uint256 public currentMaxBucketId;                            // Slot 56

    event MarketCreated(
        uint256 indexed marketId,
        address indexed creator,
        uint256 poolBalance,
        uint256 alpha,
        uint256 bucketCount
    );

    event SharesPurchased(
        uint256 indexed marketId,
        address indexed buyer,
        uint256 indexed bucketId,
        uint256 amountUSDC,
        uint256 sharesMinted,
        uint256 newPrice
    );

    event SharesSold(
        uint256 indexed marketId,
        address indexed seller,
        uint256 indexed bucketId,
        uint256 sharesBurned,
        uint256 amountUSDC,
        uint256 newPrice
    );

    event MarketResolved(
        uint256 indexed marketId,
        uint256 resolutionValue,
        uint256 winningBucket,
        uint256 resolutionTime
    );

    event WinningsClaimed(
        uint256 indexed marketId,
        address indexed claimer,
        uint256 amount
    );

    event LPWithdrawal(
        uint256 indexed marketId,
        address indexed creator,
        uint256 amount,
        int256 profit
    );

    /// @notice Emitted when shares are purchased across a range (correlated LMSR)
    event RangeSharesPurchased(
        uint256 indexed marketId,
        address indexed buyer,
        uint256 startBucket,
        uint256 endBucket,
        uint256 shares,
        uint256 costUSDC
    );

    /// @notice Emitted when shares are sold from a range position
    event RangeSharesSold(
        uint256 indexed marketId,
        address indexed seller,
        uint256 startBucket,
        uint256 endBucket,
        uint256 shares,
        uint256 payoutUSDC
    );

    /// @notice Emitted when range winnings are claimed
    event RangeWinningsClaimed(
        uint256 indexed marketId,
        address indexed claimer,
        uint256 startBucket,
        uint256 endBucket,
        uint256 shares,
        uint256 payoutUSDC
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

    constructor(
        uint256 _marketId,
        address _creator,
        address _factory,
        address _usdcToken,
        address _positionNFT,
        uint256 _alpha,
        uint256 _poolBalance,
        uint256[] memory _bucketRanges,
        uint256 _feeBps,
        uint256 _protocolFeeBps,
        MarketMetadata memory _metadata,
        address _protocolFeeCollector
    ) {
        // Forward to initialize(). Supports both direct deployment and EIP-1167 clone pattern.
        initialize(
            _marketId, _creator, _factory, _usdcToken, _positionNFT,
            _alpha, _poolBalance, _bucketRanges, _feeBps, _protocolFeeBps, _metadata,
            _protocolFeeCollector
        );
    }

    /// @notice Initialize market state. Called by the constructor on direct deployment,
    ///         and by MarketFactory after Clones.clone() on the EIP-1167 proxy path.
    ///         Can only be invoked once per contract instance (_initialized guard).
    function initialize(
        uint256 _marketId,
        address _creator,
        address _factory,
        address _usdcToken,
        address _positionNFT,
        uint256 _alpha,
        uint256 _poolBalance,
        uint256[] memory _bucketRanges,
        uint256 _feeBps,
        uint256 _protocolFeeBps,
        MarketMetadata memory _metadata,
        address _protocolFeeCollector
    ) public {
        if (_initialized) revert AlreadyInitialized();
        _initialized = true;

        if (_alpha == 0) revert InvalidParameters();
        if (_poolBalance == 0) revert InvalidParameters();
        if (_bucketRanges.length < 2) revert InvalidParameters();
        if (_feeBps > MAX_FEE_BPS) revert InvalidParameters();

        marketId = _marketId;
        creator = _creator;
        factory = _factory;
        usdcToken = IUSDC(_usdcToken);
        positionNFT = _positionNFT;
        alpha = _alpha;
        poolBalance = _poolBalance;
        initialDeposit = _poolBalance;
        feeBps = _feeBps;
        protocolFeeBps = _protocolFeeBps;
        status = MarketStatus.ACTIVE;

        // Store metadata (Sui parity)
        name = _metadata.name;
        description = _metadata.description;
        resolutionCriteria = _metadata.resolutionCriteria;
        valueUnit = _metadata.valueUnit;
        resolver = _metadata.resolver == address(0) ? _creator : _metadata.resolver;
        biddingDeadline = _metadata.biddingDeadline;
        scheduledResolutionTime = _metadata.scheduledResolutionTime;
        minBetSize = _metadata.minBetSize;
        creationTime = block.timestamp;
        protocolFeeCollector = _protocolFeeCollector;

        bucketCount = _bucketRanges.length - 1;

        // Store market bounds for range-to-bucket conversion
        marketMin = _bucketRanges[0];
        marketMax = _bucketRanges[_bucketRanges.length - 1];
        bucketWidth = (marketMax - marketMin) / bucketCount;

        // Alpha is a creator-specified market design parameter (6 decimals).
        // Recommended heuristic: poolBalance / sqrt(bucketCount).
        alphaInitial = alpha;
        alphaFinal = alpha;
        lastAlphaSyncTime = block.timestamp;
        totalDeposited = _poolBalance;

        // Cache ln(n) for cost function calculations (not for alpha anymore)
        cachedLnBucketCount = bucketCount.fromU256().ln(); // Returns WAD (18 decimals)

        // Initialize with uniform distribution: poolBalance / bucketCount per bucket
        uint256 initialShares = poolBalance / bucketCount; // 6 decimals
        uint256 sumExp = 0;

        for (uint256 i = 0; i < bucketCount; i++) {
            buckets[i] = Bucket({
                shares: initialShares,
                lowerBound: _bucketRanges[i],
                upperBound: _bucketRanges[i + 1]
            });

            // Phantom shares: exp((shares + PHANTOM) / alpha)
            // shares and alpha both in 6 decimals; scale ratio to WAD for exp()
            uint256 q = initialShares + PHANTOM_SHARES; // 6 decimals
            uint256 ratio = (q * WAD) / alpha; // Scale to WAD: (6 dec * 18 dec) / 6 dec = 18 dec
            uint256 bucketExp = ratio.exp();
            cachedBucketExp[i] = bucketExp;  // Cache per-bucket exp
            sumExp += bucketExp;
        }

        cachedSumExp = sumExp;
        sumExpDirty = false;

        // Solvency check: max shares per bucket <= poolBalance
        if (initialShares > poolBalance + SOLVENCY_DUST) {
            revert SolvencyViolation();
        }

        maxLiability = initialShares;

        emit MarketCreated(_marketId, _creator, _poolBalance, alpha, bucketCount);
    }

    function getBucket(uint256 bucketId) external view returns (Bucket memory) {
        if (bucketId >= bucketCount) revert InvalidBucket();
        return buckets[bucketId];
    }

    function getCachedSumExp() external view returns (uint256) {
        return cachedSumExp;
    }

    function isSumExpDirty() external view returns (bool) {
        return sumExpDirty;
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
        uint256 currentBalance = usdcToken.balanceOf(address(this));
        uint256 requiredReserves = getRequiredReserves();
        if (currentBalance <= requiredReserves) return 0;
        return currentBalance - requiredReserves;
    }

    function isAlphaDecayConfigured() public view returns (bool) {
        return decayDuration > 0 && alphaFinal < alphaInitial;
    }

    function needsAlphaSync() public view returns (bool) {
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

    /// @notice Set max range width (factory-only, called post-initialize)
    /// @param _maxRangeWidth Max buckets per range trade (0 = no limit)
    function setMaxRangeWidth(uint256 _maxRangeWidth) external {
        if (msg.sender != factory) revert Unauthorized();
        maxRangeWidth = _maxRangeWidth;
    }

    function addLiquidity(uint256 amountUSDC) external nonReentrant onlyActive {
        if (amountUSDC == 0) revert InvalidParameters();
        if (msg.sender != creator && msg.sender != lpVault) revert Unauthorized();

        usdcToken.transferFrom(msg.sender, address(this), amountUSDC);
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
        _refreshMaxLiabilityInternal();

        uint256 withdrawable = getWithdrawableSurplus();
        if (withdrawable == 0) revert NoSurplusAvailable();

        withdrawnUSDC = amountUSDC;
        if (withdrawnUSDC == type(uint256).max) {
            withdrawnUSDC = withdrawable;
        }

        if (withdrawnUSDC == 0 || withdrawnUSDC > withdrawable) revert InvalidParameters();

        poolBalance -= withdrawnUSDC;
        totalSurplusWithdrawn += withdrawnUSDC; // reduce net cost basis — this capital already returned
        usdcToken.transfer(recipient, withdrawnUSDC);

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

    function _calculateCostFunction() internal returns (uint256) {
        uint256 sumExp = cachedSumExp;
        if (sumExpDirty) {
            sumExp = _recalculateSumExp();
            cachedSumExp = sumExp;
            sumExpDirty = false;
        }
        uint256 lnSum = sumExp.ln(); // Returns WAD (18 decimals)
        // alpha: 6 decimals, lnSum: WAD (18 decimals) → result: 6 decimals
        return (alpha * lnSum) / WAD;
    }

    function _positionTokenEnabled() internal view returns (bool) {
        return positionNFT != address(0) && positionNFT.code.length > 0;
    }

    function _routeProtocolFee(uint256 protocolFee) internal {
        if (protocolFee > 0 && protocolFeeCollector != address(0)) {
            usdcToken.transfer(protocolFeeCollector, protocolFee);
        }
    }

    /// @notice Encode token ID for a single bucket (rangeLower = rangeUpper = bucketId)
    /// @dev Matches PositionNFT.encodeTokenIdSingle format: (marketId << 128) | (bucketId << 64) | bucketId
    function _tokenIdForBucket(uint256 bucketId) internal view returns (uint256) {
        return (uint256(uint128(marketId)) << 128) | (uint256(uint64(bucketId)) << 64) | uint256(uint64(bucketId));
    }

    /// @notice Encode token ID for a range of buckets
    /// @dev Matches PositionNFT.encodeTokenId format: (marketId << 128) | (rangeLower << 64) | rangeUpper
    function _tokenIdForRange(uint256 rangeLower, uint256 rangeUpper) internal view returns (uint256) {
        return (uint256(uint128(marketId)) << 128) | (uint256(uint64(rangeLower)) << 64) | uint256(uint64(rangeUpper));
    }

    /// @notice Get sumOther using sparse cache: O(1) instead of O(n)
    /// @dev sumOther = cachedSumExp - cachedBucketExp[bucketId]
    function _getSumOther(uint256 bucketId) internal view returns (uint256) {
        return cachedSumExp - cachedBucketExp[bucketId];
    }

    function _recalculateSumExp() internal returns (uint256) {
        uint256 sumExp = 0;
        for (uint256 i = 0; i < bucketCount; i++) {
            // PHANTOM SHARES: exp((q + 1) / α)
            // shares: 6 dec, alpha: 6 dec, ratio is unitless → scale to WAD for exp()
            uint256 q = buckets[i].shares + PHANTOM_SHARES; // 6 decimals
            uint256 ratio = (q * WAD) / alpha; // Scale to WAD (18 decimals)
            uint256 bucketExp = ratio.exp();
            cachedBucketExp[i] = bucketExp;  // Refresh per-bucket cache
            sumExp += bucketExp;
        }
        return sumExp;
    }

    function _updateSumExpIncremental(uint256 bucketId, uint256 newShares) internal {
        // PHANTOM SHARES: exp((q + 1) / α)
        // shares: 6 dec, alpha: 6 dec, ratio is unitless → scale to WAD for exp()
        uint256 newRatio = ((newShares + PHANTOM_SHARES) * WAD) / alpha;
        uint256 newExp = newRatio.exp();
        
        // Sui-style delta update: use cached old exp instead of recalculating
        uint256 oldExp = cachedBucketExp[bucketId];
        
        cachedSumExp = cachedSumExp - oldExp + newExp;
        cachedBucketExp[bucketId] = newExp;  // Update per-bucket cache
        
        tradeCount++;
        if (tradeCount >= CACHE_RESET_INTERVAL) {
            sumExpDirty = true;
            tradeCount = 0;
        }
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

    /// @notice View-only cost function (doesn't update cache)
    function _calculateCostFunctionView() internal view returns (uint256) {
        uint256 sumExp = cachedSumExp;
        // For view functions, use cached value even if dirty (minor inaccuracy acceptable)
        uint256 lnSum = sumExp.ln();
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

        // Alpha change invalidates cached exp terms; perform full cache refresh once per epoch
        cachedSumExp = _recalculateSumExp();
        sumExpDirty = false;
        tradeCount = 0;

        emit AlphaSynced(marketId, oldAlpha, newAlpha, block.timestamp);
    }

    function buyShares(uint256 bucketId, uint256 amountUSDC, uint256 minSharesOut)
        external
        nonReentrant
        onlyActive
        returns (uint256 sharesMinted)
    {
        return _executeBuy(bucketId, amountUSDC, minSharesOut);
    }

    /// @notice Buy shares with EIP-2612 permit signature (gasless approval)
    function buySharesWithPermit(
        uint256 bucketId,
        uint256 amountUSDC,
        uint256 minSharesOut,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant onlyActive returns (uint256 sharesMinted) {
        IERC20Permit(address(usdcToken)).permit(
            msg.sender, address(this), amountUSDC, deadline, v, r, s
        );
        return _executeBuy(bucketId, amountUSDC, minSharesOut);
    }

    /// @dev Shared buy logic for buyShares and buySharesWithPermit
    function _executeBuy(uint256 bucketId, uint256 amountUSDC, uint256 minSharesOut)
        internal
        returns (uint256 sharesMinted)
    {
        _syncAlpha();

        if (bucketId >= bucketCount) revert InvalidBucket();
        if (amountUSDC == 0) revert InvalidParameters();
        if (biddingDeadline != 0 && block.timestamp > biddingDeadline) revert BiddingClosed();
        if (minBetSize != 0 && amountUSDC < minBetSize) revert BetTooSmall();

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

        // Solvency check: newShares cannot exceed poolBalance AFTER adding net cost
        uint256 newPoolBalance = poolBalance + netCostUSDC;
        if (newShares > newPoolBalance + SOLVENCY_DUST) {
            revert SolvencyViolation();
        }

        buckets[bucketId].shares = newShares;
        if (newShares > maxLiability) {
            maxLiability = newShares;
            currentMaxBucketId = bucketId;
        }

        _updateSumExpIncremental(bucketId, newShares);

        uint256 protocolFee = (feesUSDC * protocolFeeBps) / 10000;
        uint256 lpFee = feesUSDC - protocolFee;

        poolBalance += netCostUSDC;
        feesCollectedLP += lpFee;
        lpFeesAccrued += lpFee;
        feesCollectedProtocol += protocolFee;
        totalVolume += amountUSDC;

        usdcToken.transferFrom(msg.sender, address(this), amountUSDC);
        _routeProtocolFee(protocolFee);

        uint256 newPrice = _calculatePrice(bucketId);

        if (_positionTokenEnabled()) {
            IPositionNFT(positionNFT).mint(msg.sender, _tokenIdForBucket(bucketId), sharesMinted);
        }

        emit SharesPurchased(marketId, msg.sender, bucketId, amountUSDC, sharesMinted, newPrice);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CORRELATED RANGE LMSR - Clean design matching Sui semantics
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Buy shares across a contiguous range of outcomes (Correlated LMSR)
    /// @dev User pays once, receives shares that cover ALL buckets in range.
    ///      If ANY bucket in range wins, user gets full payout.
    /// @param rangeLower Lower bound in value space (inclusive)
    /// @param rangeUpper Upper bound in value space (exclusive)
    /// @param amountUSDC Maximum USDC to spend (6 decimals)
    /// @param minSharesOut Minimum shares to receive (slippage protection)
    /// @return shares Number of shares received (covers ALL buckets in range)
    /// @param targetShares FE-provided quote hint (0 = binary search, >0 = try fast path first)
    function buySharesRange(
        uint256 rangeLower,
        uint256 rangeUpper,
        uint256 amountUSDC,
        uint256 minSharesOut,
        uint256 targetShares
    ) external nonReentrant onlyActive returns (uint256 shares) {
        _syncAlpha();
        if (biddingDeadline != 0 && block.timestamp > biddingDeadline) revert BiddingClosed();
        if (minBetSize != 0 && amountUSDC < minBetSize) revert BetTooSmall();

        // ─────────────────────────────────────────────────────────────────────
        // STEP 1: Validate and convert range to buckets (ONCE)
        // ─────────────────────────────────────────────────────────────────────
        (uint256 startBucket, uint256 endBucket) = _rangeToBuckets(rangeLower, rangeUpper);

        // ─────────────────────────────────────────────────────────────────────
        // STEP 2: Calculate fees and net amount
        // ─────────────────────────────────────────────────────────────────────
        uint256 feesUSDC = (amountUSDC * feeBps) / 10000;
        uint256 netAmount = amountUSDC - feesUSDC;

        // ─────────────────────────────────────────────────────────────────────
        // STEP 3: Fast path — skip binary search when FE provides pre-calculated quote
        // ─────────────────────────────────────────────────────────────────────
        uint256 actualCost;
        uint256 newSumExp;

        if (targetShares > 0) {
            (uint256 cost, uint256 newSum) = _calculateRangeBuyCost(startBucket, endBucket, targetShares);
            if (cost <= netAmount) {
                // Quote is affordable — skip binary search (Sui parity).
                // User's slippage protection is via minSharesOut, not budget utilization.
                shares = targetShares;
                actualCost = cost;
                newSumExp = newSum;
            }
            // If cost > netAmount, quote is stale/too expensive → fall through to binary search
        }

        // Fall through to binary search only if fast path didn't succeed
        if (shares == 0) {
            (shares, actualCost, newSumExp) = _findMaxSharesForRange(
                startBucket, endBucket, netAmount
            );
        }
        
        if (shares < minSharesOut) revert InvalidParameters();
        
        // ─────────────────────────────────────────────────────────────────────
        // STEP 4: Validate solvency for all buckets in range
        // ─────────────────────────────────────────────────────────────────────
        _validateRangeSolvency(startBucket, endBucket, shares, actualCost);
        
        // ─────────────────────────────────────────────────────────────────────
        // STEP 5: Atomic state update
        // ─────────────────────────────────────────────────────────────────────
        _applyRangeBuy(startBucket, endBucket, shares, actualCost, newSumExp);
        
        // Update fees and volume
        uint256 protocolFee = (feesUSDC * protocolFeeBps) / 10000;
        uint256 lpFee = feesUSDC - protocolFee;
        feesCollectedLP += lpFee;
        lpFeesAccrued += lpFee;
        feesCollectedProtocol += protocolFee;
        totalVolume += amountUSDC;

        // ─────────────────────────────────────────────────────────────────────
        // STEP 6: External interaction LAST (checks-effects-interactions)
        // ─────────────────────────────────────────────────────────────────────
        usdcToken.transferFrom(msg.sender, address(this), amountUSDC);
        _routeProtocolFee(protocolFee);

        if (_positionTokenEnabled()) {
            // Mint ONE unified range token (not per-bucket)
            IPositionNFT(positionNFT).mint(msg.sender, _tokenIdForRange(startBucket, endBucket), shares);
        }
        
        emit RangeSharesPurchased(marketId, msg.sender, startBucket, endBucket, shares, actualCost);
    }

    /// @notice Sell shares from a range position (Correlated LMSR)
    /// @param rangeLower Lower bound in value space (inclusive)
    /// @param rangeUpper Upper bound in value space (exclusive)
    /// @param sharesToSell Number of shares to sell (must have this many in ALL buckets)
    /// @param minUsdcOut Minimum USDC to receive (slippage protection)
    /// @return payoutUSDC Amount of USDC received
    function sellSharesRange(
        uint256 rangeLower,
        uint256 rangeUpper,
        uint256 sharesToSell,
        uint256 minUsdcOut
    ) external nonReentrant onlyActive returns (uint256 payoutUSDC) {
        _syncAlpha();
        if (biddingDeadline != 0 && block.timestamp > biddingDeadline) revert BiddingClosed();

        if (sharesToSell == 0) revert InvalidParameters();
        
        // ─────────────────────────────────────────────────────────────────────
        // STEP 1: Convert range to buckets
        // ─────────────────────────────────────────────────────────────────────
        (uint256 startBucket, uint256 endBucket) = _rangeToBuckets(rangeLower, rangeUpper);
        
        // ─────────────────────────────────────────────────────────────────────
        // STEP 2: Validate user has range position token
        // ─────────────────────────────────────────────────────────────────────
        for (uint256 b = startBucket; b <= endBucket; b++) {
            if (buckets[b].shares < sharesToSell) revert InsufficientBalance();
        }

        if (_positionTokenEnabled()) {
            uint256 rangeTokenId = _tokenIdForRange(startBucket, endBucket);
            if (IPositionNFT(positionNFT).balanceOf(msg.sender, rangeTokenId) < sharesToSell) {
                revert InsufficientBalance();
            }
        }
        
        // ─────────────────────────────────────────────────────────────────────
        // STEP 3: Calculate sell return using correlated LMSR
        // ─────────────────────────────────────────────────────────────────────
        (uint256 grossPayout, uint256 newSumExp) = _calculateRangeSellReturn(
            startBucket, endBucket, sharesToSell
        );
        
        uint256 feesUSDC = (grossPayout * feeBps) / 10000;
        payoutUSDC = grossPayout - feesUSDC;
        
        if (payoutUSDC < minUsdcOut) revert InvalidParameters();
        
        // ─────────────────────────────────────────────────────────────────────
        // STEP 4: Atomic state update
        // ─────────────────────────────────────────────────────────────────────
        _applyRangeSell(startBucket, endBucket, sharesToSell, payoutUSDC, newSumExp);
        
        // Update fees and volume
        uint256 protocolFee = (feesUSDC * protocolFeeBps) / 10000;
        uint256 lpFee = feesUSDC - protocolFee;
        feesCollectedLP += lpFee;
        lpFeesAccrued += lpFee;
        feesCollectedProtocol += protocolFee;
        totalVolume += grossPayout;

        // Solvency check: O(1) fast path unless we sold from the max bucket
        bool affectsMax = false;
        for (uint256 b = startBucket; b <= endBucket; b++) {
            if (b == currentMaxBucketId) { affectsMax = true; break; }
        }
        if (affectsMax) {
            _rescanMaxLiability();
        } else {
            _checkSolvency();
        }

        // ─────────────────────────────────────────────────────────────────────
        // STEP 5: External interaction LAST
        // ─────────────────────────────────────────────────────────────────────
        if (_positionTokenEnabled()) {
            IPositionNFT(positionNFT).burn(msg.sender, _tokenIdForRange(startBucket, endBucket), sharesToSell);
        }

        _routeProtocolFee(protocolFee);

        usdcToken.transfer(msg.sender, payoutUSDC);

        emit RangeSharesSold(marketId, msg.sender, startBucket, endBucket, sharesToSell, payoutUSDC);
    }

    /// @notice Claim winnings if your range contains the winning bucket
    /// @param rangeLower Lower bound of your position (inclusive)
    /// @param rangeUpper Upper bound of your position (exclusive)
    /// @param sharesToClaim Number of shares to claim
    /// @return payoutUSDC Amount of USDC received ($1 per share)
    function claimRange(
        uint256 rangeLower,
        uint256 rangeUpper,
        uint256 sharesToClaim
    ) external nonReentrant returns (uint256 payoutUSDC) {
        if (status != MarketStatus.RESOLVED) revert MarketNotActive();
        if (sharesToClaim == 0) revert InvalidParameters();
        
        // Convert range to buckets
        (uint256 startBucket, uint256 endBucket) = _rangeToBuckets(rangeLower, rangeUpper);
        
        // Check if winning bucket is within user's range
        if (winningBucket < startBucket || winningBucket > endBucket) {
            revert RangeNotWinner();
        }
        
        if (sharesToClaim > buckets[winningBucket].shares) revert InsufficientBalance();
        if (_positionTokenEnabled()) {
            uint256 rangeTokenId = _tokenIdForRange(startBucket, endBucket);
            if (IPositionNFT(positionNFT).balanceOf(msg.sender, rangeTokenId) < sharesToClaim) {
                revert InsufficientBalance();
            }
        }
        
        // Payout = shares × $1 (both in 6 decimals)
        payoutUSDC = sharesToClaim;
        
        // Update only the winning bucket's shares (that's what backs the payout)
        buckets[winningBucket].shares -= sharesToClaim;
        poolBalance -= payoutUSDC;

        if (_positionTokenEnabled()) {
            // Burn the unified range token
            IPositionNFT(positionNFT).burn(msg.sender, _tokenIdForRange(startBucket, endBucket), sharesToClaim);
        }
        
        usdcToken.transfer(msg.sender, payoutUSDC);
        
        emit RangeWinningsClaimed(marketId, msg.sender, startBucket, endBucket, sharesToClaim, payoutUSDC);
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
        
        (shares, cost, ) = _findMaxSharesForRange(startBucket, endBucket, netAmount);
        
        // Odds = potential payout / cost = shares / cost (since payout = shares × $1)
        if (cost > 0) {
            odds = (shares * 1e6) / cost; // 6 decimal precision
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL HELPERS - Clean separation of concerns
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Convert value range to bucket indices (called ONCE per transaction)
    /// @param lower Lower bound in value space (inclusive)
    /// @param upper Upper bound in value space (exclusive)
    /// @return startBucket First bucket index
    /// @return endBucket Last bucket index (inclusive)
    function _rangeToBuckets(uint256 lower, uint256 upper) 
        internal view returns (uint256 startBucket, uint256 endBucket) 
    {
        if (lower >= upper) revert InvalidRange();
        if (bucketWidth == 0) revert InvalidParameters();
        if (lower < marketMin) revert InvalidRange();
        if (upper > marketMax) revert InvalidRange();
        
        // Market-relative indexing
        startBucket = (lower - marketMin) / bucketWidth;
        endBucket = ((upper - 1) - marketMin) / bucketWidth; // -1 makes upper exclusive

        // Enforce max range width if configured
        if (maxRangeWidth > 0 && (endBucket - startBucket + 1) > maxRangeWidth) {
            revert RangeTooWide();
        }
    }

    /// @dev Binary search to find max affordable shares for a range
    /// @return shares Maximum shares affordable
    /// @return actualCost Cost of those shares
    /// @return newSumExp New cached sum after purchase (for atomic update)
    function _findMaxSharesForRange(
        uint256 startBucket,
        uint256 endBucket,
        uint256 maxCost
    ) internal view returns (uint256 shares, uint256 actualCost, uint256 newSumExp) {
        if (maxCost == 0) return (0, 0, cachedSumExp);

        // Binary search bounds
        uint256 low = 0;
        uint256 high = poolBalance; // Solvency cap

        uint256 bestShares = 0;
        uint256 bestCost = 0;
        uint256 bestSumExp = cachedSumExp;

        // 20 iterations gives precision to 1 part in 10^6 (sub-cent for 6-decimal USDC)
        for (uint256 i = 0; i < 20; i++) {
            if (low > high) break;

            uint256 mid = (low + high) / 2;
            if (mid == 0) {
                low = 1;
                continue;
            }

            // Solvency pre-check: cheaper storage reads before expensive exp() calls.
            // If adding `mid` shares would exceed poolBalance + maxCost (max possible pool)
            // for any bucket, skip this iteration entirely.
            bool solvencyOk = true;
            uint256 maxPool = poolBalance + maxCost + SOLVENCY_DUST;
            for (uint256 b = startBucket; b <= endBucket; b++) {
                if (buckets[b].shares + mid > maxPool) {
                    solvencyOk = false;
                    break;
                }
            }
            if (!solvencyOk) {
                high = mid - 1;
                continue;
            }

            (uint256 cost, uint256 newSum) = _calculateRangeBuyCost(startBucket, endBucket, mid);

            if (cost <= maxCost) {
                // Affordable - track as best and try higher
                if (mid > bestShares) {
                    bestShares = mid;
                    bestCost = cost;
                    bestSumExp = newSum;
                }

                // Early exit if we're using 99.5%+ of budget
                if (cost >= (maxCost * 995) / 1000) break;

                low = mid + 1;
            } else {
                // Too expensive - try lower
                high = mid - 1;
            }

            // Convergence exit: sub-cent precision ($0.001 with 6 decimals)
            if (high - low < 1000) break;
        }

        return (bestShares, bestCost, bestSumExp);
    }

    /// @dev Calculate cost to buy shares across range using O(k) delta method
    /// Formula: Cost = α × (ln(sumExp_after) - ln(sumExp_before))
    function _calculateRangeBuyCost(
        uint256 startBucket,
        uint256 endBucket,
        uint256 sharesToAdd
    ) internal view returns (uint256 cost, uint256 newSumExp) {
        newSumExp = cachedSumExp;
        
        // For each bucket in range: subtract old exp, add new exp
        for (uint256 b = startBucket; b <= endBucket; b++) {
            uint256 oldShares = buckets[b].shares;
            uint256 newShares = oldShares + sharesToAdd;
            
            // Remove old contribution: exp((oldShares + phantom) / α)
            uint256 oldExp = cachedBucketExp[b];
            
            // Add new contribution: exp((newShares + phantom) / α)
            uint256 newRatio = ((newShares + PHANTOM_SHARES) * WAD) / alpha;
            uint256 newExp = newRatio.exp();
            
            newSumExp = newSumExp - oldExp + newExp;
        }
        
        // Cost = α × (ln(newSumExp) - ln(cachedSumExp))
        uint256 lnBefore = cachedSumExp.ln();
        uint256 lnAfter = newSumExp.ln();
        
        // Both ln values are in WAD, alpha is 6 decimals
        // cost = alpha * (lnAfter - lnBefore) / WAD → 6 decimals
        cost = (alpha * (lnAfter - lnBefore)) / WAD;
    }

    /// @dev Calculate return for selling shares from a range
    /// Formula: Return = α × (ln(sumExp_before) - ln(sumExp_after))
    function _calculateRangeSellReturn(
        uint256 startBucket,
        uint256 endBucket,
        uint256 sharesToSell
    ) internal view returns (uint256 returnUSDC, uint256 newSumExp) {
        newSumExp = cachedSumExp;
        
        // For each bucket in range: subtract old exp, add new (reduced) exp
        for (uint256 b = startBucket; b <= endBucket; b++) {
            uint256 oldShares = buckets[b].shares;
            uint256 newShares = oldShares - sharesToSell;
            
            // Remove old contribution
            uint256 oldExp = cachedBucketExp[b];
            
            // Add new (reduced) contribution
            uint256 newRatio = ((newShares + PHANTOM_SHARES) * WAD) / alpha;
            uint256 newExp = newRatio.exp();
            
            newSumExp = newSumExp - oldExp + newExp;
        }
        
        // Return = α × (ln(cachedSumExp) - ln(newSumExp))
        uint256 lnBefore = cachedSumExp.ln();
        uint256 lnAfter = newSumExp.ln();
        
        returnUSDC = (alpha * (lnBefore - lnAfter)) / WAD;
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

    /// @dev Atomic state update for range buy
    function _applyRangeBuy(
        uint256 startBucket,
        uint256 endBucket,
        uint256 shares,
        uint256 cost,
        uint256 newSumExp
    ) internal {
        // Update each bucket's shares and exp cache
        for (uint256 b = startBucket; b <= endBucket; b++) {
            uint256 newShares = buckets[b].shares + shares;
            buckets[b].shares = newShares;

            if (newShares > maxLiability) {
                maxLiability = newShares;
                currentMaxBucketId = b;
            }
            
            // Update per-bucket exp cache
            uint256 newRatio = ((newShares + PHANTOM_SHARES) * WAD) / alpha;
            cachedBucketExp[b] = newRatio.exp();
        }
        
        // Update global state
        cachedSumExp = newSumExp;
        poolBalance += cost;
        
        // Track trades for periodic cache refresh
        tradeCount++;
        if (tradeCount >= CACHE_RESET_INTERVAL) {
            sumExpDirty = true;
            tradeCount = 0;
        }
    }

    /// @dev Atomic state update for range sell
    function _applyRangeSell(
        uint256 startBucket,
        uint256 endBucket,
        uint256 shares,
        uint256 payout,
        uint256 newSumExp
    ) internal {
        // Update each bucket's shares and exp cache
        for (uint256 b = startBucket; b <= endBucket; b++) {
            uint256 newShares = buckets[b].shares - shares;
            buckets[b].shares = newShares;
            
            // Update per-bucket exp cache
            uint256 newRatio = ((newShares + PHANTOM_SHARES) * WAD) / alpha;
            cachedBucketExp[b] = newRatio.exp();
        }
        
        // Update global state
        cachedSumExp = newSumExp;
        poolBalance -= payout;
        
        // Track trades for periodic cache refresh
        tradeCount++;
        if (tradeCount >= CACHE_RESET_INTERVAL) {
            sumExpDirty = true;
            tradeCount = 0;
        }
    }

    /// @notice O(1) solvency check — only validates the current max bucket
    function _checkSolvency() internal view {
        if (buckets[currentMaxBucketId].shares > poolBalance + SOLVENCY_DUST) {
            revert SolvencyViolation();
        }
    }

    /// @notice Full rescan — finds the new max bucket and checks solvency for all
    /// @dev Called when selling from the current max bucket (rare) or on explicit refresh
    function _rescanMaxLiability() internal {
        uint256 currentMax = 0;
        uint256 maxBucket = 0;
        for (uint256 i = 0; i < bucketCount; i++) {
            if (buckets[i].shares > poolBalance + SOLVENCY_DUST) {
                revert SolvencyViolation();
            }
            if (buckets[i].shares > currentMax) {
                currentMax = buckets[i].shares;
                maxBucket = i;
            }
        }
        maxLiability = currentMax;
        currentMaxBucketId = maxBucket;
    }

    /// @dev Internal refresh — only decreases maxLiability
    function _refreshMaxLiabilityInternal() internal {
        uint256 currentMax = 0;
        uint256 maxBucket = 0;
        for (uint256 i = 0; i < bucketCount; i++) {
            if (buckets[i].shares > currentMax) {
                currentMax = buckets[i].shares;
                maxBucket = i;
            }
        }
        if (currentMax < maxLiability) {
            maxLiability = currentMax;
            currentMaxBucketId = maxBucket;
        }
    }

    /// @notice Permissionless refresh of maxLiability to current actual maximum
    /// @dev Useful before harvesting surplus — ensures reserves aren't over-locked
    function refreshMaxLiability() external {
        uint256 currentMax = 0;
        uint256 maxBucket = 0;
        for (uint256 i = 0; i < bucketCount; i++) {
            if (buckets[i].shares > currentMax) {
                currentMax = buckets[i].shares;
                maxBucket = i;
            }
        }
        if (currentMax < maxLiability) {
            maxLiability = currentMax;
            currentMaxBucketId = maxBucket;
        }
    }

    /// @notice Integer square root using binary search (matches Sui's simple_integer_sqrt)
    /// @dev Returns floor(sqrt(x))
    function _sqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;
        if (x <= 3) return 1;
        
        uint256 low = 1;
        uint256 high = x / 2 + 1;
        uint256 result = 0;
        
        while (low <= high) {
            uint256 mid = (low + high) / 2;
            uint256 square = mid * mid;
            
            if (square == x) {
                return mid;
            } else if (square < x) {
                result = mid;
                low = mid + 1;
            } else {
                high = mid - 1;
            }
        }
        
        return result;
    }
    
    function _calculatePrice(uint256 bucketId) internal view returns (uint256) {
        uint256 sumExp = cachedSumExp;
        // Use cached values for view (minor inaccuracy acceptable if dirty)
        
        // Sui-style: use cached bucket exp instead of recalculating
        uint256 bucketExp = cachedBucketExp[bucketId];
        
        // Return probability in WAD (for consistency with exp/ln)
        return (bucketExp * WAD) / sumExp;
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

    /// @notice Preview gross return for selling range shares (view — no state change)
    /// @param rangeLower Lower bound in value space (inclusive)
    /// @param rangeUpper Upper bound in value space (exclusive)
    /// @param sharesToSell Number of shares to sell from each bucket in range
    /// @return grossReturn Gross USDC return before fees
    /// @return netReturn Net USDC return after fees
    /// @return feesUSDC Total fees deducted
    function calculateReturnForRangeShares(
        uint256 rangeLower,
        uint256 rangeUpper,
        uint256 sharesToSell
    ) external view returns (uint256 grossReturn, uint256 netReturn, uint256 feesUSDC) {
        (uint256 startBucket, uint256 endBucket) = _rangeToBuckets(rangeLower, rangeUpper);

        if (sharesToSell == 0) return (0, 0, 0);

        // Validate all buckets have enough shares
        for (uint256 b = startBucket; b <= endBucket; b++) {
            if (sharesToSell > buckets[b].shares) revert InsufficientBalance();
        }

        (grossReturn, ) = _calculateRangeSellReturn(startBucket, endBucket, sharesToSell);
        feesUSDC = (grossReturn * feeBps) / 10000;
        netReturn = grossReturn - feesUSDC;
    }

    function sellShares(uint256 bucketId, uint256 sharesToSell, uint256 minPayoutOut)
        external
        nonReentrant
        onlyActive
        returns (uint256 payoutUSDC)
    {
        _syncAlpha();

        if (bucketId >= bucketCount) revert InvalidBucket();
        if (sharesToSell == 0) revert InvalidParameters();
        if (sharesToSell > buckets[bucketId].shares) revert InsufficientBalance();
        if (biddingDeadline != 0 && block.timestamp > biddingDeadline) revert BiddingClosed();

        if (_positionTokenEnabled()) {
            uint256 tokenId = _tokenIdForBucket(bucketId);
            if (IPositionNFT(positionNFT).balanceOf(msg.sender, tokenId) < sharesToSell) {
                revert InsufficientBalance();
            }
        }
        
        uint256 C_before = _calculateCostFunction(); // 6 decimals
        
        // Sui-style sparse cache: O(1) instead of O(n) loop
        uint256 sumOther = _getSumOther(bucketId);
        
        uint256 newShares = buckets[bucketId].shares - sharesToSell; // 6 decimals
        uint256 q = newShares + PHANTOM_SHARES; // 6 decimals
        uint256 ratio = (q * WAD) / alpha; // Scale to WAD
        uint256 newBucketExp = ratio.exp();
        
        uint256 newSumExp = sumOther + newBucketExp;
        uint256 lnNewSum = newSumExp.ln(); // Returns WAD (18 decimals)
        uint256 C_after = (alpha * lnNewSum) / WAD; // 6 decimals
        
        uint256 grossPayoutUSDC = C_before - C_after; // Already 6 decimals
        
        uint256 feesUSDC = (grossPayoutUSDC * feeBps) / 10000;
        payoutUSDC = grossPayoutUSDC - feesUSDC;
        
        if (payoutUSDC < minPayoutOut) revert InvalidParameters();
        
        buckets[bucketId].shares = newShares;
        
        // FIXED ALPHA: No update after trade (matches Sui, prevents arbitrage)
        
        _updateSumExpIncremental(bucketId, newShares);
        
        uint256 protocolFee = (feesUSDC * protocolFeeBps) / 10000;
        uint256 lpFee = feesUSDC - protocolFee;
        
        poolBalance -= payoutUSDC;
        feesCollectedLP += lpFee;
        lpFeesAccrued += lpFee;
        feesCollectedProtocol += protocolFee;
        totalVolume += grossPayoutUSDC;
        
        // Solvency check: O(1) for common case, O(n) rescan when selling from max bucket
        if (bucketId == currentMaxBucketId) {
            _rescanMaxLiability();
        } else {
            _checkSolvency();
        }

        if (_positionTokenEnabled()) {
            IPositionNFT(positionNFT).burn(msg.sender, _tokenIdForBucket(bucketId), sharesToSell);
        }

        _routeProtocolFee(protocolFee);
        
        usdcToken.transfer(msg.sender, payoutUSDC);
        
        uint256 newPrice = _calculatePrice(bucketId);
        emit SharesSold(marketId, msg.sender, bucketId, sharesToSell, payoutUSDC, newPrice);
    }

    /// @notice Resolve market with winning outcome value (Sui parity)
    /// @dev Takes a resolution value in the market's value space (e.g., $115,000) and
    ///      calculates which bucket contains that value. Matches Sui's resolve_market_with_outcome.
    /// @param _resolutionValue The actual outcome value (e.g., 115000 for $115K)
    function resolveMarket(uint256 _resolutionValue) external {
        if (msg.sender != resolver) revert Unauthorized();
        if (status != MarketStatus.ACTIVE) revert MarketAlreadyResolved();
        
        // Validate resolution value is within market bounds
        if (_resolutionValue < marketMin || _resolutionValue > marketMax) {
            revert InvalidResolutionValue();
        }
        
        // Calculate winning bucket from resolution value (same as Sui)
        // bucket_index = (value - marketMin) / bucketWidth
        uint256 calculatedBucket = (_resolutionValue - marketMin) / bucketWidth;
        
        // Handle edge case: if value equals marketMax, it belongs to the last bucket
        if (calculatedBucket >= bucketCount) {
            calculatedBucket = bucketCount - 1;
        }

        status = MarketStatus.RESOLVED;
        resolutionValue = _resolutionValue;
        winningBucket = calculatedBucket;
        resolutionTime = block.timestamp;

        emit MarketResolved(marketId, _resolutionValue, calculatedBucket, block.timestamp);
    }

    /// @notice Claim winnings for a resolved market (winning shares pay $1 each)
    /// @param bucketId The bucket to claim from
    /// @param sharesToClaim Number of shares to claim (in WAD 18 decimals)
    function claimWinnings(uint256 bucketId, uint256 sharesToClaim) external nonReentrant {
        if (status != MarketStatus.RESOLVED) revert MarketNotActive();
        if (bucketId != winningBucket) revert InvalidBucket();
        if (sharesToClaim == 0) revert InvalidParameters();

        if (sharesToClaim > buckets[bucketId].shares) revert InsufficientBalance();
        if (_positionTokenEnabled()) {
            uint256 tokenId = _tokenIdForBucket(bucketId);
            if (IPositionNFT(positionNFT).balanceOf(msg.sender, tokenId) < sharesToClaim) {
                revert InsufficientBalance();
            }
            IPositionNFT(positionNFT).burn(msg.sender, tokenId, sharesToClaim);
        }

        // Winning shares pay $1 per share: shares and USDC both in 6 decimals
        // So 1 share = 1 USDC (both in 6 decimals)
        uint256 payoutUSDC = sharesToClaim; // 6 decimals = 6 decimals

        // Update bucket shares
        buckets[bucketId].shares -= sharesToClaim;
        poolBalance -= payoutUSDC;

        // Transfer winnings
        usdcToken.transfer(msg.sender, payoutUSDC);

        emit WinningsClaimed(marketId, msg.sender, payoutUSDC);
    }

    /// @notice Withdraw LP funds after market resolution
    /// @dev Callable by the market creator OR the registered lpVault.
    ///      When called by lpVault the funds flow back to the vault (not to creator) so
    ///      the multi-vault can recycle capital across markets.
    function withdrawLP() external nonReentrant {
        if (msg.sender != creator && msg.sender != lpVault) revert Unauthorized();
        if (status != MarketStatus.RESOLVED) revert MarketNotActive();
        if (lpWithdrawn) revert InvalidParameters();

        // Calculate total outstanding winning shares
        uint256 totalWinningShares = buckets[winningBucket].shares; // 6 decimals
        uint256 totalPayoutsRequired = totalWinningShares; // 6 decimals = 6 decimals

        // Available for LP = current pool - unclaimed winnings
        uint256 availableForLP = poolBalance - totalPayoutsRequired;

        // Net cost basis: what was deposited minus what was already returned via surplus withdrawals
        uint256 netDeposit = totalDeposited > totalSurplusWithdrawn
            ? totalDeposited - totalSurplusWithdrawn
            : 0;

        // Calculate profit (can be negative)
        int256 profit = int256(availableForLP) - int256(netDeposit);

        // Reset pool balance to prevent re-withdrawal
        uint256 withdrawAmount = availableForLP;
        poolBalance = totalPayoutsRequired; // Leave exactly enough for remaining claims
        lpWithdrawn = true;

        // Transfer to caller: creator or lpVault (vault recycles capital into next markets)
        usdcToken.transfer(msg.sender, withdrawAmount);

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
            // Post-resolution: subtract winning share payouts still outstanding
            uint256 totalWinningShares = buckets[winningBucket].shares;
            uint256 availableForLP = poolBalance > totalWinningShares
                ? poolBalance - totalWinningShares
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
}
