// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IUSDC} from "./interfaces/IUSDC.sol";
import {FixedPointMath} from "./FixedPointMath.sol";
import {ReentrancyGuard} from "@openzeppelin/utils/ReentrancyGuard.sol";

/// @notice Core LMSR market contract for prediction markets
contract LMSRMarket is ReentrancyGuard {
    using FixedPointMath for uint256;

    struct Bucket {
        uint256 shares;
        uint256 lowerBound;
        uint256 upperBound;
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
    uint256 public constant SPREAD_FACTOR = 2_160000;

    uint256 public immutable marketId;
    address public immutable creator;
    address public immutable factory;
    address public immutable positionNFT;
    IUSDC public immutable usdcToken;

    uint256 public alpha;
    uint256 public poolBalance;
    uint256 public initialDeposit;
    uint256 public bucketCount;

    uint256 private cachedLnBucketCount;

    mapping(uint256 => Bucket) public buckets;

    MarketStatus public status;
    uint256 public winningBucket;
    uint256 public totalVolume;
    uint256 public resolutionTime;
    bool public lpWithdrawn;

    uint256 public feeBps;
    uint256 public protocolFeeBps;
    uint256 public feesCollectedLP;
    uint256 public feesCollectedProtocol;

    uint256 private cachedSumExp;
    bool private sumExpDirty;
    uint256 private tradeCount;

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

    error InvalidParameters();
    error MarketNotActive();
    error MarketAlreadyResolved();
    error InvalidBucket();
    error InsufficientBalance();
    error Unauthorized();
    error SolvencyViolation();

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
        uint256 _protocolFeeBps
    ) {
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

        bucketCount = _bucketRanges.length - 1;

        cachedLnBucketCount = bucketCount.fromU256().ln();
        
        _updateDynamicAlpha();

        uint256 uniformShares = _poolBalance.toWad() / bucketCount;
        uint256 sumExp = 0;

        for (uint256 i = 0; i < bucketCount; i++) {
            buckets[i] = Bucket({
                shares: uniformShares,
                lowerBound: _bucketRanges[i],
                upperBound: _bucketRanges[i + 1]
            });

            uint256 q = uniformShares;
            uint256 exponent = q.divWad(alpha);
            sumExp += exponent.exp();
        }

        cachedSumExp = sumExp;
        sumExpDirty = false;

        uint256 maxSharesWad = uniformShares;
        uint256 maxSharesUSDC = maxSharesWad.fromWad();
        if (maxSharesUSDC > poolBalance + SOLVENCY_DUST) {
            revert SolvencyViolation();
        }

        emit MarketCreated(_marketId, _creator, _poolBalance, alpha, bucketCount);
    }

    function getBucket(uint256 bucketId) external view returns (Bucket memory) {
        if (bucketId >= bucketCount) revert InvalidBucket();
        return buckets[bucketId];
    }

    function getCachedSumExp() external view returns (uint256) {
        return cachedSumExp;
    }

    function _updateDynamicAlpha() internal {
        if (bucketCount == 0) return;
        
        uint256 poolBalanceWad = poolBalance.toWad();
        uint256 lnN = cachedLnBucketCount;
        
        uint256 divisor = SPREAD_FACTOR.mulWad(lnN);
        alpha = poolBalanceWad.divWad(divisor);
    }

    function isSumExpDirty() external view returns (bool) {
        return sumExpDirty;
    }

    modifier onlyActive() {
        if (status != MarketStatus.ACTIVE) revert MarketNotActive();
        _;
    }

    modifier onlyCreator() {
        if (msg.sender != creator) revert Unauthorized();
        _;
    }

    function _calculateCostFunction() internal view returns (uint256) {
        uint256 sumExp = cachedSumExp;
        if (sumExpDirty) {
            sumExp = _recalculateSumExp();
        }
        uint256 lnSum = sumExp.ln();
        return alpha.mulWad(lnSum);
    }

    function _recalculateSumExp() internal view returns (uint256) {
        uint256 sumExp = 0;
        for (uint256 i = 0; i < bucketCount; i++) {
            uint256 q = buckets[i].shares;
            uint256 exponent = q.divWad(alpha);
            sumExp += exponent.exp();
        }
        return sumExp;
    }

    function _updateSumExpIncremental(uint256 bucketId, uint256 oldShares, uint256 newShares) internal {
        uint256 oldExponent = oldShares.divWad(alpha);
        uint256 newExponent = newShares.divWad(alpha);
        
        uint256 oldExp = oldExponent.exp();
        uint256 newExp = newExponent.exp();
        
        cachedSumExp = cachedSumExp - oldExp + newExp;
        
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
        
        uint256 costWad = costUSDC.toWad();
        uint256 C_before = _calculateCostFunction();
        
        uint256 sumOther = 0;
        for (uint256 i = 0; i < bucketCount; i++) {
            if (i != bucketId) {
                uint256 exponent = buckets[i].shares.divWad(alpha);
                sumOther += exponent.exp();
            }
        }
        
        uint256 C_new = C_before + costWad;
        uint256 expCNewOverAlpha = C_new.divWad(alpha).exp();
        
        uint256 innerTerm = expCNewOverAlpha - sumOther;
        uint256 lnInnerTerm = innerTerm.ln();
        uint256 newShares = alpha.mulWad(lnInnerTerm);
        
        shares = newShares - buckets[bucketId].shares;
    }

    function buyShares(uint256 bucketId, uint256 amountUSDC, uint256 minSharesOut)
        external
        nonReentrant
        onlyActive
        returns (uint256 sharesMinted)
    {
        if (bucketId >= bucketCount) revert InvalidBucket();
        if (amountUSDC == 0) revert InvalidParameters();
        
        uint256 costWad = amountUSDC.toWad();
        uint256 C_before = _calculateCostFunction();
        
        uint256 sumOther = 0;
        for (uint256 i = 0; i < bucketCount; i++) {
            if (i != bucketId) {
                uint256 exponent = buckets[i].shares.divWad(alpha);
                sumOther += exponent.exp();
            }
        }
        
        uint256 feesUSDC = (amountUSDC * feeBps) / 10000;
        uint256 netCostUSDC = amountUSDC - feesUSDC;
        uint256 netCostWad = netCostUSDC.toWad();
        
        uint256 C_new = C_before + netCostWad;
        uint256 expCNewOverAlpha = C_new.divWad(alpha).exp();
        
        uint256 innerTerm = expCNewOverAlpha - sumOther;
        uint256 lnInnerTerm = innerTerm.ln();
        uint256 newShares = alpha.mulWad(lnInnerTerm);
        
        sharesMinted = newShares - buckets[bucketId].shares;
        
        if (sharesMinted < minSharesOut) revert InvalidParameters();
        
        // Solvency check: newShares cannot exceed poolBalance AFTER adding net cost
        uint256 maxSharesUSDC = newShares.fromWad();
        uint256 newPoolBalance = poolBalance + netCostUSDC;
        if (maxSharesUSDC > newPoolBalance + SOLVENCY_DUST) {
            revert SolvencyViolation();
        }
        
        uint256 oldShares = buckets[bucketId].shares;
        buckets[bucketId].shares = newShares;
        
        _updateSumExpIncremental(bucketId, oldShares, newShares);
        
        _updateDynamicAlpha();
        
        uint256 protocolFee = (feesUSDC * protocolFeeBps) / 10000;
        uint256 lpFee = feesUSDC - protocolFee;
        
        poolBalance += netCostUSDC;
        feesCollectedLP += lpFee;
        feesCollectedProtocol += protocolFee;
        totalVolume += amountUSDC;
        
        usdcToken.transferFrom(msg.sender, address(this), amountUSDC);
        
        uint256 newPrice = _calculatePrice(bucketId);
        emit SharesPurchased(marketId, msg.sender, bucketId, amountUSDC, sharesMinted, newPrice);
    }

    function _calculatePrice(uint256 bucketId) internal view returns (uint256) {
        uint256 sumExp = cachedSumExp;
        if (sumExpDirty) {
            sumExp = _recalculateSumExp();
        }
        
        uint256 exponent = buckets[bucketId].shares.divWad(alpha);
        uint256 bucketExp = exponent.exp();
        
        return bucketExp.divWad(sumExp);
    }

    function calculateReturnForShares(uint256 bucketId, uint256 sharesToSell)
        external
        view
        returns (uint256 returnUSDC)
    {
        if (bucketId >= bucketCount) revert InvalidBucket();
        if (sharesToSell == 0) return 0;
        if (sharesToSell > buckets[bucketId].shares) revert InsufficientBalance();
        
        uint256 C_before = _calculateCostFunction();
        
        uint256 sumOther = 0;
        for (uint256 i = 0; i < bucketCount; i++) {
            if (i != bucketId) {
                uint256 exponent = buckets[i].shares.divWad(alpha);
                sumOther += exponent.exp();
            }
        }
        
        uint256 newShares = buckets[bucketId].shares - sharesToSell;
        uint256 exponent = newShares.divWad(alpha);
        uint256 newBucketExp = exponent.exp();
        
        uint256 newSumExp = sumOther + newBucketExp;
        uint256 lnNewSum = newSumExp.ln();
        uint256 C_after = alpha.mulWad(lnNewSum);
        
        uint256 returnWad = C_before - C_after;
        returnUSDC = returnWad.fromWad();
    }

    function sellShares(uint256 bucketId, uint256 sharesToSell, uint256 minPayoutOut)
        external
        nonReentrant
        onlyActive
        returns (uint256 payoutUSDC)
    {
        if (bucketId >= bucketCount) revert InvalidBucket();
        if (sharesToSell == 0) revert InvalidParameters();
        if (sharesToSell > buckets[bucketId].shares) revert InsufficientBalance();
        
        uint256 C_before = _calculateCostFunction();
        
        uint256 sumOther = 0;
        for (uint256 i = 0; i < bucketCount; i++) {
            if (i != bucketId) {
                uint256 exponent = buckets[i].shares.divWad(alpha);
                sumOther += exponent.exp();
            }
        }
        
        uint256 newShares = buckets[bucketId].shares - sharesToSell;
        uint256 exponent = newShares.divWad(alpha);
        uint256 newBucketExp = exponent.exp();
        
        uint256 newSumExp = sumOther + newBucketExp;
        uint256 lnNewSum = newSumExp.ln();
        uint256 C_after = alpha.mulWad(lnNewSum);
        
        uint256 returnWad = C_before - C_after;
        uint256 grossPayoutUSDC = returnWad.fromWad();
        
        uint256 feesUSDC = (grossPayoutUSDC * feeBps) / 10000;
        payoutUSDC = grossPayoutUSDC - feesUSDC;
        
        if (payoutUSDC < minPayoutOut) revert InvalidParameters();
        
        uint256 oldShares = buckets[bucketId].shares;
        buckets[bucketId].shares = newShares;
        
        _updateDynamicAlpha();
        
        _updateSumExpIncremental(bucketId, oldShares, newShares);
        
        uint256 protocolFee = (feesUSDC * protocolFeeBps) / 10000;
        uint256 lpFee = feesUSDC - protocolFee;
        
        poolBalance -= payoutUSDC;
        feesCollectedLP += lpFee;
        feesCollectedProtocol += protocolFee;
        totalVolume += grossPayoutUSDC;
        
        usdcToken.transfer(msg.sender, payoutUSDC);
        
        uint256 newPrice = _calculatePrice(bucketId);
        emit SharesSold(marketId, msg.sender, bucketId, sharesToSell, payoutUSDC, newPrice);
    }

    /// @notice Resolve market with winning outcome (admin only)
    /// @param _winningBucket The bucket ID that won
    function resolveMarket(uint256 _winningBucket) external {
        if (msg.sender != creator) revert Unauthorized();
        if (status != MarketStatus.ACTIVE) revert MarketAlreadyResolved();
        if (_winningBucket >= bucketCount) revert InvalidBucket();

        status = MarketStatus.RESOLVED;
        winningBucket = _winningBucket;
        resolutionTime = block.timestamp;

        emit MarketResolved(marketId, _winningBucket, block.timestamp);
    }

    /// @notice Claim winnings for a resolved market (winning shares pay $1 each)
    /// @param bucketId The bucket to claim from
    /// @param sharesToClaim Number of shares to claim (in WAD 18 decimals)
    function claimWinnings(uint256 bucketId, uint256 sharesToClaim) external nonReentrant {
        if (status != MarketStatus.RESOLVED) revert MarketNotActive();
        if (bucketId != winningBucket) revert InvalidBucket();
        if (sharesToClaim == 0) revert InvalidParameters();

        // TODO: Check user's position balance from PositionNFT
        // For now, we'll just check against bucket shares (will be replaced with NFT integration)
        if (sharesToClaim > buckets[bucketId].shares) revert InsufficientBalance();

        // Winning shares pay $1 per share: shares are in WAD, USDC is in 6 decimals
        // So sharesWAD = USDC × 1e12 (toWad conversion)
        // Therefore: payoutUSDC = shares / 1e12 (reverse the toWad)
        // This means payoutUSDC = fromWad(shares)
        uint256 payoutUSDC = sharesToClaim.fromWad();

        // Update bucket shares
        buckets[bucketId].shares -= sharesToClaim;
        poolBalance -= payoutUSDC;

        // Transfer winnings
        usdcToken.transfer(msg.sender, payoutUSDC);

        emit WinningsClaimed(marketId, msg.sender, payoutUSDC);
    }

    /// @notice Withdraw LP funds after market resolution (creator only)
    /// @dev Can only withdraw after resolution, pays out remaining funds after all claims
    function withdrawLP() external nonReentrant {
        if (msg.sender != creator) revert Unauthorized();
        if (status != MarketStatus.RESOLVED) revert MarketNotActive();
        if (lpWithdrawn) revert InvalidParameters();

        // Calculate total outstanding winning shares
        uint256 totalWinningShares = buckets[winningBucket].shares;
        uint256 totalPayoutsRequired = totalWinningShares.fromWad();

        // Available for LP = current pool - unclaimed winnings
        uint256 availableForLP = poolBalance - totalPayoutsRequired;

        // Calculate profit (can be negative)
        int256 profit = int256(availableForLP) - int256(initialDeposit);

        // Reset pool balance to prevent re-withdrawal
        uint256 withdrawAmount = availableForLP;
        poolBalance = totalPayoutsRequired; // Leave exactly enough for remaining claims
        lpWithdrawn = true;

        // Transfer to creator
        usdcToken.transfer(creator, withdrawAmount);

        emit LPWithdrawal(marketId, creator, withdrawAmount, profit);
    }

    /// @notice Get LP profitability metrics
    /// @return unrealizedProfit Current profit/loss (before withdrawal)
    /// @return roi Return on investment in basis points
    /// @return feesEarned Total fees collected for LP
    function getLPProfitability() external view returns (int256 unrealizedProfit, int256 roi, uint256 feesEarned) {
        if (status != MarketStatus.RESOLVED) {
            // Pre-resolution: show current unrealized profit
            unrealizedProfit = int256(poolBalance) - int256(initialDeposit);
        } else {
            // Post-resolution: calculate actual profit after winnings reserved
            uint256 totalWinningShares = buckets[winningBucket].shares;
            uint256 totalPayoutsRequired = totalWinningShares.fromWad();
            uint256 availableForLP = poolBalance - totalPayoutsRequired;
            unrealizedProfit = int256(availableForLP) - int256(initialDeposit);
        }

        // Calculate ROI in basis points (1 bp = 0.01%)
        if (initialDeposit > 0) {
            roi = (unrealizedProfit * 10000) / int256(initialDeposit);
        } else {
            roi = 0;
        }

        feesEarned = feesCollectedLP;
    }
}
