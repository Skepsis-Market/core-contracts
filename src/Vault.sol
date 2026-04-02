// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/token/ERC20/extensions/ERC4626.sol";
import {Ownable} from "@openzeppelin/access/Ownable.sol";
import {Pausable} from "@openzeppelin/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {LMSRMarket} from "./LMSRMarket.sol";

/// @notice Single ERC-4626 vault backing all LMSR prediction markets on the platform.
///
/// ARCHITECTURE
/// ═══════════════════════════════════════════════════════════════════
///  LPs            → deposit()/redeem()         interact with the vault (instant if liquid)
///  LPs            → requestWithdrawal()        queue exit when capital is deployed
///  LPs            → claimWithdrawal()          claim after capital returns from markets
///  Admin/Keeper   → deployTo(market, amount)   push capital into a market
///  Admin/Keeper   → harvestSurplus(market)     pull alpha-decay-released surplus back
///  Admin/Keeper   → harvestResolved(market)    pull post-resolution residual back
///
/// ACCOUNTING (conservative NAV)
/// ═══════════════════════════════════════════════════════════════════
///  totalAssets() = vault liquid USDC (excl. reserved for queue)
///               + Σ market.poolBalance()                 (active markets — LPs bear risk)
///               + Σ (poolBalance - winShares)            (resolved, unclaimed LP residual)
///
/// WITHDRAWAL QUEUE
/// ═══════════════════════════════════════════════════════════════════
///  When capital is deployed, LPs may not be able to withdraw instantly.
///  They can requestWithdrawal() to join a FIFO queue.
///  When capital returns (harvest/resolution), it's reserved for queued LPs first.
///  Reserved capital cannot be deployed to new markets.
///
/// SOLVENCY LAYERS
/// ═══════════════════════════════════════════════════════════════════
///  Layer 1 – market-level  : each market enforces its own P-Z invariant (LMSRMarket.sol)
///  Layer 2 – vault-level   : 20% buffer on DEPLOYED capital (not idle)
///  Layer 3 – per-market cap: no single new deployment > 20% of totalAssets at time of call
contract Vault is ERC4626, Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─── Constants ────────────────────────────────────────────────────────────
    uint256 public constant LIQUID_BUFFER_BPS  = 2000; // 20 % always liquid
    uint256 public constant MAX_MARKET_BPS     = 2000; // no new deployment > 20 % of NAV
    uint256 public constant BPS_DENOMINATOR    = 10000;

    uint256 public constant MIN_WITHDRAWAL_REQUEST = 1_000000; // 1 USDC minimum queue request

    // Health thresholds (integer ×100, e.g. 120 = 1.20×)
    uint256 public constant HEALTH_INJECT_THRESHOLD   = 120; // inject when below 1.20×
    uint256 public constant HEALTH_WITHDRAW_THRESHOLD = 150; // harvest when above 1.50×

    // ─── Withdrawal Queue ────────────────────────────────────────────────────
    /// @dev Option A (Lido-style): Shares burned at request time, USDC amount fixed.
    ///      No cancellation allowed. LP stops earning fees immediately.
    struct WithdrawalRequest {
        address owner;           // LP who requested
        uint256 assetsOwed;      // USDC owed (fixed at request time, shares already burned)
        bool fulfilled;          // true when capital is reserved for this request
        bool claimed;            // true when LP has claimed the USDC
        uint256 requestTime;     // timestamp of request
    }
    WithdrawalRequest[] public withdrawalQueue;
    uint256 public totalAssetsOwed;         // total USDC owed to queue (unfulfilled)
    uint256 public reservedForWithdrawals;  // USDC earmarked for queue, cannot be deployed
    uint256 public queueHead;               // first unfulfilled request index

    // ─── State ────────────────────────────────────────────────────────────────
    address public factory;
    address[] public markets;
    mapping(address => bool)    public isRegistered;
    mapping(address => uint256) public deployedTo;  // cumulative principal sent to each market
    uint256 public totalDeployed;

    // ─── Cached Market Value (O(1) totalAssets) ────────────────────────────
    uint256 public cachedTotalMarketValue;              // Σ cached per-market values
    mapping(address => uint256) public cachedMarketValue; // per-market cached value

    // ─── Withdrawal Queue Counter (O(1) pendingWithdrawalsCount) ───────────
    uint256 public pendingCount;                        // unfulfilled queue entries

    // ─── Deposit Gate ─────────────────────────────────────────────────────────
    bool public depositsEnabled;            // false = only owner can deposit (capped launch)

    // ─── Events ───────────────────────────────────────────────────────────────
    event MarketRegistered(address indexed market);
    event CapitalDeployed(address indexed market, uint256 amount);
    event SurplusHarvested(address indexed market, uint256 amount);
    event ResolvedHarvested(address indexed market, uint256 amount);
    event MarketValueSynced(address indexed market, uint256 oldValue, uint256 newValue);
    event WithdrawalRequested(address indexed owner, uint256 indexed queueIndex, uint256 sharesBurned, uint256 assetsOwed);
    event WithdrawalFulfilled(uint256 indexed queueIndex, uint256 assetsOwed);
    event WithdrawalClaimed(address indexed owner, uint256 indexed queueIndex, uint256 assets);
    event DepositsEnabledUpdated(bool enabled);
    event FactoryUpdated(address indexed oldFactory, address indexed newFactory);

    // ─── Errors ───────────────────────────────────────────────────────────────
    error MarketAlreadyRegistered();
    error MarketNotRegistered();
    error InsufficientLiquidBuffer();
    error ExceedsMarketCap();
    error NothingToHarvest();
    error MarketNotResolved();
    error NotFactory();
    error InvalidQueueIndex();
    error NotRequestOwner();
    error WithdrawalNotFulfilled();
    error WithdrawalAlreadyClaimed();
    error InsufficientShares();
    error DepositsDisabled();

    // ─── Constructor ──────────────────────────────────────────────────────────
    constructor(
        address _asset,
        string memory _name,
        string memory _symbol,
        address _owner
    ) ERC20(_name, _symbol) ERC4626(IERC20(_asset)) Ownable(_owner) {}

    /// @dev Virtual offset of 6 decimals (1e6 virtual shares) prevents first-depositor
    ///      inflation attack. An attacker would need to donate >1e6 USDC to steal 1 wei.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ERC-4626 OVERRIDES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice NAV = (liquid USDC - reserved - owed) + cached Σ market values.
    ///         Subtracting reservedForWithdrawals (fulfilled, unclaimed) AND totalAssetsOwed
    ///         (unfulfilled, shares already burned) prevents share price inflation.
    function totalAssets() public view override returns (uint256) {
        uint256 liquid = IERC20(asset()).balanceOf(address(this));
        uint256 unavailable = reservedForWithdrawals + totalAssetsOwed;
        uint256 available = liquid > unavailable ? liquid - unavailable : 0;
        return available + cachedTotalMarketValue;
    }

    /// @notice Total value currently deployed in active/resolved markets (cached).
    function _totalMarketValue() internal view returns (uint256) {
        return cachedTotalMarketValue;
    }

    /// @notice Liquid USDC available for INSTANT withdrawal (excludes reserved for queue).
    ///         Buffer only applies to DEPLOYED capital, not idle USDC.
    ///         If nothing deployed, 100% of liquid is available.
    function liquidAvailable() public view returns (uint256) {
        uint256 liquid = IERC20(asset()).balanceOf(address(this));
        uint256 deployed = _totalMarketValue();
        
        // Reserved for queued withdrawals is not available
        uint256 unavailable = reservedForWithdrawals;
        
        // Buffer only applies when capital is deployed
        if (deployed > 0) {
            uint256 buffer = (deployed * LIQUID_BUFFER_BPS) / BPS_DENOMINATOR;
            unavailable += buffer;
        }
        
        return liquid > unavailable ? liquid - unavailable : 0;
    }

    /// @notice Capped at the requesting owner's proportional share of instant-liquid USDC.
    ///         For larger withdrawals, use requestWithdrawal() to join the queue.
    function maxWithdraw(address owner) public view override returns (uint256) {
        uint256 ownerAssets = convertToAssets(balanceOf(owner));
        uint256 available   = liquidAvailable();
        return ownerAssets < available ? ownerAssets : available;
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        return previewWithdraw(maxWithdraw(owner));
    }

    /// @notice Returns 0 when paused or deposits disabled (unless caller is owner).
    function maxDeposit(address receiver) public view override returns (uint256) {
        if (paused()) return 0;
        if (!depositsEnabled && receiver != owner()) return 0;
        return type(uint256).max;
    }

    /// @notice Returns 0 when paused or deposits disabled (unless caller is owner).
    function maxMint(address receiver) public view override returns (uint256) {
        if (paused()) return 0;
        if (!depositsEnabled && receiver != owner()) return 0;
        return type(uint256).max;
    }

    /// @notice Deposit gate — blocked when paused or deposits disabled (unless owner).
    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal override whenNotPaused {
        if (!depositsEnabled && caller != owner()) revert DepositsDisabled();
        super._deposit(caller, receiver, assets, shares);
    }

    /// @notice Withdrawals only from liquid USDC above the 20% buffer. Blocked when paused.
    function _withdraw(
        address caller,
        address receiver,
        address owner_,
        uint256 assets,
        uint256 shares
    ) internal override whenNotPaused {
        if (assets > liquidAvailable()) revert InsufficientLiquidBuffer();
        super._withdraw(caller, receiver, owner_, assets, shares);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ADMIN: PAUSE + DEPOSIT GATE
    // ═══════════════════════════════════════════════════════════════════════════

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    /// @notice Enable/disable public deposits. When disabled, only owner can deposit.
    function setDepositsEnabled(bool _enabled) external onlyOwner {
        depositsEnabled = _enabled;
        emit DepositsEnabledUpdated(_enabled);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ADMIN: MARKET REGISTRY
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Register a market so the vault can interact with it.
    /// @dev The market creator must also call market.setLPVault(address(this)) to authorise
    ///      this vault on the market side (or it can be done atomically by the factory).
    function registerMarket(address market) external onlyOwner {
        if (isRegistered[market]) revert MarketAlreadyRegistered();
        isRegistered[market] = true;
        markets.push(market);
        emit MarketRegistered(market);
    }

    /// @notice Set the factory that can call fundNewMarket
    function setFactory(address _factory) external onlyOwner {
        address oldFactory = factory;
        factory = _factory;
        emit FactoryUpdated(oldFactory, _factory);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // LP: WITHDRAWAL QUEUE (Lido-style: burn at request, no cancellation)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Request a withdrawal when instant liquidity is insufficient.
    ///         IMPORTANT: Shares are BURNED immediately. USDC owed is fixed at request time.
    ///         LP stops earning fees/returns from this point. No cancellation allowed.
    ///         When capital returns (via harvest), queued requests are fulfilled FIFO.
    /// @param shares Amount of vault shares to burn for withdrawal
    /// @return queueIndex Index in the withdrawal queue for tracking
    function requestWithdrawal(uint256 shares) external returns (uint256 queueIndex) {
        if (shares == 0) revert InsufficientShares();
        if (balanceOf(msg.sender) < shares) revert InsufficientShares();

        // Calculate USDC owed at CURRENT exchange rate (crystallize exit value)
        uint256 assetsOwed = convertToAssets(shares);
        if (assetsOwed < MIN_WITHDRAWAL_REQUEST) revert InsufficientShares();
        
        // Burn shares immediately - LP stops earning from this point
        _burn(msg.sender, shares);
        
        queueIndex = withdrawalQueue.length;
        withdrawalQueue.push(WithdrawalRequest({
            owner: msg.sender,
            assetsOwed: assetsOwed,
            fulfilled: false,
            claimed: false,
            requestTime: block.timestamp
        }));
        totalAssetsOwed += assetsOwed;
        pendingCount++;

        emit WithdrawalRequested(msg.sender, queueIndex, shares, assetsOwed);
    }

    /// @notice Claim a fulfilled withdrawal request.
    ///         Only callable after capital has returned and been reserved for this request.
    /// @param queueIndex Index of your withdrawal request
    function claimWithdrawal(uint256 queueIndex) external {
        if (queueIndex >= withdrawalQueue.length) revert InvalidQueueIndex();
        
        WithdrawalRequest storage req = withdrawalQueue[queueIndex];
        if (req.owner != msg.sender) revert NotRequestOwner();
        if (!req.fulfilled) revert WithdrawalNotFulfilled();
        if (req.claimed) revert WithdrawalAlreadyClaimed();
        
        uint256 payout = req.assetsOwed;
        
        // Update state
        reservedForWithdrawals -= payout;
        req.claimed = true;
        
        // Transfer USDC to owner
        IERC20(asset()).safeTransfer(msg.sender, payout);
        
        emit WithdrawalClaimed(msg.sender, queueIndex, payout);
    }

    /// @notice Get withdrawal request details
    function getWithdrawalRequest(uint256 queueIndex) external view returns (WithdrawalRequest memory) {
        if (queueIndex >= withdrawalQueue.length) revert InvalidQueueIndex();
        return withdrawalQueue[queueIndex];
    }

    /// @notice Get total pending (unfulfilled) withdrawal requests count — O(1)
    function pendingWithdrawalsCount() external view returns (uint256) {
        return pendingCount;
    }

    /// @notice USDC available for new market deployments (excludes reserved + buffer)
    function deployableCapital() public view returns (uint256) {
        uint256 liquid = IERC20(asset()).balanceOf(address(this));
        uint256 deployed = _totalMarketValue();
        
        // Cannot deploy reserved capital
        uint256 unavailable = reservedForWithdrawals;
        
        // Buffer on deployed capital
        if (deployed > 0) {
            unavailable += (deployed * LIQUID_BUFFER_BPS) / BPS_DENOMINATOR;
        }
        
        return liquid > unavailable ? liquid - unavailable : 0;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // FACTORY: NEW MARKET FUNDING
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Fund a newly created market with vault capital. Called atomically by the
    ///         factory during createMarket(). Registers the market and transfers seed USDC.
    /// @dev Only callable by the factory. The market's constructor already set poolBalance
    ///      as an accounting entry; this provides the actual USDC to match.
    ///      Enforces the same guards as deployTo: deployable capital + per-market cap.
    function fundNewMarket(address market, uint256 amount) external {
        if (msg.sender != factory) revert NotFactory();
        if (isRegistered[market]) revert MarketAlreadyRegistered();

        uint256 ta = totalAssets();

        // Guard 1: must not exceed deployable capital (respects reserved + buffer)
        if (amount > deployableCapital()) revert InsufficientLiquidBuffer();

        // Guard 2: per-market cap (skip when vault is empty)
        if (ta > 0) {
            if ((amount * BPS_DENOMINATOR) / ta > MAX_MARKET_BPS) {
                revert ExceedsMarketCap();
            }
        }

        // Register + track
        isRegistered[market] = true;
        markets.push(market);
        deployedTo[market] = amount;
        totalDeployed      += amount;

        // Update cached market value (conservative: deployed amount)
        cachedMarketValue[market] = amount;
        cachedTotalMarketValue += amount;

        // Raw USDC transfer (market constructor already set poolBalance accounting)
        IERC20(asset()).safeTransfer(market, amount);

        emit MarketRegistered(market);
        emit CapitalDeployed(market, amount);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ADMIN: CAPITAL ALLOCATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Deploy vault USDC into a registered market (increases its alpha depth).
    ///         Enforces:
    ///           1. Per-market cap: this deployment must not push market share above 20% of NAV.
    ///           2. Deployable capital check: respects reserved-for-withdrawals and buffer.
    /// @param market  Target LMSRMarket (must be registered and have vault set as lpVault)
    /// @param amount  USDC amount to deploy (6 decimals)
    function deployTo(address market, uint256 amount) external onlyOwner {
        if (!isRegistered[market]) revert MarketNotRegistered();

        // Guard 1: must not exceed deployable capital (respects reserved + buffer)
        if (amount > deployableCapital()) revert InsufficientLiquidBuffer();

        // Guard 2: per-market cap (skip on first ever deployment when ta == 0)
        uint256 ta = totalAssets();
        if (ta > 0) {
            uint256 newMarketDeployed = deployedTo[market] + amount;
            if ((newMarketDeployed * BPS_DENOMINATOR) / ta > MAX_MARKET_BPS) {
                revert ExceedsMarketCap();
            }
        }

        deployedTo[market] += amount;
        totalDeployed      += amount;

        // Update cached value: deployed increased, so cached value increases by amount
        // (conservative NAV caps at deployed, so new cache = deployedTo[market])
        uint256 oldCached = cachedMarketValue[market];
        cachedMarketValue[market] = deployedTo[market];
        cachedTotalMarketValue = cachedTotalMarketValue - oldCached + deployedTo[market];

        IERC20(asset()).forceApprove(market, amount);
        LMSRMarket(market).addLiquidity(amount);

        emit CapitalDeployed(market, amount);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PERMISSIONLESS: REBALANCING / HARVESTING
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Pull all available surplus from an active market back to the vault.
    ///         Permissionless: no loss possible — only claims what the market reports as
    ///         withdrawable (above requiredReserves = maxLiability + 2·alpha_current·ln(N)).
    ///         As alpha decays, requiredReserves shrink and this call can return more capital.
    ///         Returned capital is first allocated to queued withdrawal requests (FIFO).
    function harvestSurplus(address market) external nonReentrant {
        if (!isRegistered[market]) revert MarketNotRegistered();

        LMSRMarket m = LMSRMarket(market);
        uint256 surplus = m.getWithdrawableSurplus();
        if (surplus == 0) revert NothingToHarvest();

        uint256 before = IERC20(asset()).balanceOf(address(this));
        m.withdrawSurplus(address(this), surplus);
        uint256 harvested = IERC20(asset()).balanceOf(address(this)) - before;

        // Refresh cached market value after surplus extraction
        _syncCachedMarketValue(market);

        // Process withdrawal queue with returned capital
        _processWithdrawalQueue(harvested);

        emit SurplusHarvested(market, harvested);
    }

    /// @notice Pull LP residual from a resolved market back to the vault.
    ///         Permissionless. Market must be RESOLVED and not yet claimed.
    ///         Returned capital is first allocated to queued withdrawal requests (FIFO).
    function harvestResolved(address market) external nonReentrant {
        if (!isRegistered[market]) revert MarketNotRegistered();

        LMSRMarket m = LMSRMarket(market);
        if (m.status() != LMSRMarket.MarketStatus.RESOLVED) revert MarketNotResolved();
        if (m.lpWithdrawn()) revert NothingToHarvest();

        uint256 before = IERC20(asset()).balanceOf(address(this));
        m.withdrawLP();
        uint256 harvested = IERC20(asset()).balanceOf(address(this)) - before;

        // Zero out cached market value — LP has been fully withdrawn
        uint256 oldCached = cachedMarketValue[market];
        cachedMarketValue[market] = 0;
        cachedTotalMarketValue = cachedTotalMarketValue > oldCached
            ? cachedTotalMarketValue - oldCached : 0;

        // Process withdrawal queue with returned capital
        _processWithdrawalQueue(harvested);

        emit ResolvedHarvested(market, harvested);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VIEW: HEALTH MONITORING
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Health ratio of a market (integer ×100).
    ///         100 = exactly at requiredReserves (critical)
    ///         120 = 20 % headroom (inject threshold)
    ///         150 = 50 % headroom (harvest threshold)
    function marketHealthRatio(address market) public view returns (uint256) {
        LMSRMarket m = LMSRMarket(market);
        uint256 req = m.getRequiredReserves();
        if (req == 0) return type(uint256).max;
        return (m.poolBalance() * 100) / req;
    }

    /// @notice Returns the active registered market with the lowest health ratio.
    function lowestHealthMarket() external view returns (address worst, uint256 ratio) {
        ratio = type(uint256).max;
        for (uint256 i = 0; i < markets.length; i++) {
            LMSRMarket m = LMSRMarket(markets[i]);
            if (m.status() != LMSRMarket.MarketStatus.ACTIVE) continue;
            uint256 r = marketHealthRatio(markets[i]);
            if (r < ratio) {
                ratio = r;
                worst = markets[i];
            }
        }
    }

    /// @notice Total harvestable surplus across ALL active registered markets right now.
    function totalHarvestableSurplus() external view returns (uint256 total) {
        for (uint256 i = 0; i < markets.length; i++) {
            LMSRMarket m = LMSRMarket(markets[i]);
            if (m.status() == LMSRMarket.MarketStatus.ACTIVE) {
                total += m.getWithdrawableSurplus();
            }
        }
    }

    function marketCount() external view returns (uint256) {
        return markets.length;
    }

    /// @notice Permissionless refresh of a single market's cached value.
    ///         Useful for keepers or FE to keep totalAssets() accurate between harvests.
    function syncMarketValue(address market) external {
        if (!isRegistered[market]) revert MarketNotRegistered();
        _syncCachedMarketValue(market);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Process queued withdrawal requests with returned capital (FIFO).
    ///         Called automatically when capital returns via harvest functions.
    ///         Since shares are burned at request time, assetsOwed is already fixed.
    /// @param returnedCapital Amount of USDC that just returned to the vault
    function _processWithdrawalQueue(uint256 returnedCapital) internal {
        if (returnedCapital == 0) return;
        
        uint256 remaining = returnedCapital;
        
        // Start from queueHead to skip already-processed requests
        for (uint256 i = queueHead; i < withdrawalQueue.length && remaining > 0; i++) {
            WithdrawalRequest storage req = withdrawalQueue[i];
            
            // Skip already fulfilled or claimed requests
            if (req.fulfilled || req.claimed || req.assetsOwed == 0) {
                // Advance queueHead past processed entries
                if (i == queueHead) queueHead++;
                continue;
            }
            
            // Check if we have enough to fulfill this request
            if (remaining >= req.assetsOwed) {
                // Fully fulfill
                req.fulfilled = true;
                reservedForWithdrawals += req.assetsOwed;
                totalAssetsOwed -= req.assetsOwed;
                remaining -= req.assetsOwed;
                if (pendingCount > 0) pendingCount--;

                emit WithdrawalFulfilled(i, req.assetsOwed);
            } else {
                // Not enough capital for this request - stop here
                // (No partial fulfillment - either fully funded or wait)
                break;
            }
        }
    }

    /// @notice Value the vault attributes to each market in totalAssets().
    ///         Active:   min(poolBalance, deployed) — conservative: caps upside at principal,
    ///                   marks-to-market on downside. Prevents phantom NAV inflation.
    ///         Resolved: pool minus unclaimed winning shares (net LP residual)
    ///         Other:    0
    function _claimableFromMarket(address market) internal view returns (uint256) {
        if (deployedTo[market] == 0) return 0; // vault has no claim on markets it never funded
        LMSRMarket m = LMSRMarket(market);
        LMSRMarket.MarketStatus s = m.status();

        if (s == LMSRMarket.MarketStatus.ACTIVE) {
            uint256 pool = m.poolBalance();
            uint256 deployed = deployedTo[market];
            return pool < deployed ? pool : deployed; // min(pool, deployed)
        }

        if (s == LMSRMarket.MarketStatus.RESOLVED && !m.lpWithdrawn()) {
            (uint256 winShares, uint256 initShares, , ) = m.buckets(m.winningBucket());
            uint256 traderShares = winShares > initShares ? winShares - initShares : 0;
            uint256 pool = m.poolBalance();
            return pool > traderShares ? pool - traderShares : 0;
        }

        return 0;
    }

    /// @dev Refresh cached value for a single market from on-chain state.
    function _syncCachedMarketValue(address market) internal {
        uint256 oldCached = cachedMarketValue[market];
        uint256 newValue = _claimableFromMarket(market);
        cachedMarketValue[market] = newValue;
        cachedTotalMarketValue = cachedTotalMarketValue - oldCached + newValue;
        emit MarketValueSynced(market, oldCached, newValue);
    }
}
