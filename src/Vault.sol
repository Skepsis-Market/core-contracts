// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/token/ERC20/extensions/ERC4626.sol";
import {Ownable} from "@openzeppelin/access/Ownable.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {LMSRMarket} from "./LMSRMarket.sol";

/// @notice Single ERC-4626 vault backing all LMSR prediction markets on the platform.
///
/// ARCHITECTURE
/// ═══════════════════════════════════════════════════════════════════
///  LPs            → deposit()/redeem()         interact with the vault
///  Admin/Keeper   → deployTo(market, amount)   push capital into a market
///  Admin/Keeper   → harvestSurplus(market)     pull alpha-decay-released surplus back
///  Admin/Keeper   → harvestResolved(market)    pull post-resolution residual back
///
/// ACCOUNTING (conservative NAV)
/// ═══════════════════════════════════════════════════════════════════
///  totalAssets() = vault liquid USDC
///               + Σ market.poolBalance()                 (active markets — LPs bear risk)
///               + Σ (poolBalance - winShares)            (resolved, unclaimed LP residual)
///
///  Pre-resolution redemptions are capped at vault liquid USDC above the 20% buffer.
///  Locked capital inside active markets is not force-liquidatable by redeemers.
///
/// SOLVENCY LAYERS
/// ═══════════════════════════════════════════════════════════════════
///  Layer 1 – market-level  : each market enforces its own P-Z invariant (LMSRMarket.sol)
///  Layer 2 – vault-level   : 20% of totalAssets always held as liquid USDC
///  Layer 3 – per-market cap: no single new deployment > 20% of totalAssets at time of call
contract Vault is ERC4626, Ownable {
    using SafeERC20 for IERC20;

    // ─── Constants ────────────────────────────────────────────────────────────
    uint256 public constant LIQUID_BUFFER_BPS  = 2000; // 20 % always liquid
    uint256 public constant MAX_MARKET_BPS     = 2000; // no new deployment > 20 % of NAV
    uint256 public constant BPS_DENOMINATOR    = 10000;

    // Health thresholds (integer ×100, e.g. 120 = 1.20×)
    uint256 public constant HEALTH_INJECT_THRESHOLD   = 120; // inject when below 1.20×
    uint256 public constant HEALTH_WITHDRAW_THRESHOLD = 150; // harvest when above 1.50×

    // ─── State ────────────────────────────────────────────────────────────────
    address public factory;
    address[] public markets;
    mapping(address => bool)    public isRegistered;
    mapping(address => uint256) public deployedTo;  // cumulative principal sent to each market
    uint256 public totalDeployed;

    // ─── Events ───────────────────────────────────────────────────────────────
    event MarketRegistered(address indexed market);
    event CapitalDeployed(address indexed market, uint256 amount);
    event SurplusHarvested(address indexed market, uint256 amount);
    event ResolvedHarvested(address indexed market, uint256 amount);

    // ─── Errors ───────────────────────────────────────────────────────────────
    error MarketAlreadyRegistered();
    error MarketNotRegistered();
    error InsufficientLiquidBuffer();
    error ExceedsMarketCap();
    error NothingToHarvest();
    error MarketNotResolved();
    error NotFactory();

    // ─── Constructor ──────────────────────────────────────────────────────────
    constructor(
        address _asset,
        string memory _name,
        string memory _symbol,
        address _owner
    ) ERC20(_name, _symbol) ERC4626(IERC20(_asset)) Ownable(_owner) {}

    // ═══════════════════════════════════════════════════════════════════════════
    // ERC-4626 OVERRIDES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice NAV = vault liquid + Σ market.poolBalance() (active) + Σ LP-residual (resolved).
    ///         Full poolBalance is counted for active markets: LPs accept market risk.
    ///         Pre-resolution redemptions are still limited to vault liquid above the 20% buffer.
    function totalAssets() public view override returns (uint256 total) {
        total = IERC20(asset()).balanceOf(address(this));
        for (uint256 i = 0; i < markets.length; i++) {
            total += _claimableFromMarket(markets[i]);
        }
    }

    /// @notice Liquid USDC available for withdrawal above the 20% buffer.
    function liquidAvailable() public view returns (uint256) {
        uint256 liquid = IERC20(asset()).balanceOf(address(this));
        uint256 ta = totalAssets();
        uint256 required = (ta * LIQUID_BUFFER_BPS) / BPS_DENOMINATOR;
        return liquid > required ? liquid - required : 0;
    }

    /// @notice Capped at the requesting owner's proportional share of liquid-available USDC.
    function maxWithdraw(address owner) public view override returns (uint256) {
        uint256 ownerAssets = convertToAssets(balanceOf(owner));
        uint256 available   = liquidAvailable();
        return ownerAssets < available ? ownerAssets : available;
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        return previewWithdraw(maxWithdraw(owner));
    }

    // Deposits stay liquid in the vault; admin deploys capital separately via deployTo().
    // No _deposit override needed — standard ERC-4626 behaviour is correct.

    /// @notice Withdrawals only from liquid USDC above the 20% buffer.
    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal override {
        if (assets > liquidAvailable()) revert InsufficientLiquidBuffer();
        super._withdraw(caller, receiver, owner, assets, shares);
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
        factory = _factory;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // FACTORY: NEW MARKET FUNDING
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Fund a newly created market with vault capital. Called atomically by the
    ///         factory during createMarket(). Registers the market and transfers seed USDC.
    /// @dev Only callable by the factory. The market's constructor already set poolBalance
    ///      as an accounting entry; this provides the actual USDC to match.
    ///      Enforces the same guards as deployTo: liquid buffer + per-market cap.
    function fundNewMarket(address market, uint256 amount) external {
        if (msg.sender != factory) revert NotFactory();
        if (isRegistered[market]) revert MarketAlreadyRegistered();

        uint256 ta = totalAssets();
        uint256 vaultLiquid = IERC20(asset()).balanceOf(address(this));

        // Guard 1: enough liquid USDC
        if (amount > vaultLiquid) revert InsufficientLiquidBuffer();

        // Guard 2: per-market cap (skip when vault is empty)
        if (ta > 0) {
            if ((amount * BPS_DENOMINATOR) / ta > MAX_MARKET_BPS) {
                revert ExceedsMarketCap();
            }
        }

        // Guard 3: 20% liquid buffer maintained after funding
        // NAV is unchanged by the transfer (vault liquid ↓, market pool ↑ by same amount)
        uint256 liquidAfter   = vaultLiquid - amount;
        uint256 requiredAfter = (ta * LIQUID_BUFFER_BPS) / BPS_DENOMINATOR;
        if (liquidAfter < requiredAfter) revert InsufficientLiquidBuffer();

        // Register + track
        isRegistered[market] = true;
        markets.push(market);
        deployedTo[market] = amount;
        totalDeployed      += amount;

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
    ///           2. Liquid buffer: 20% of post-deployment NAV must remain liquid in vault.
    /// @param market  Target LMSRMarket (must be registered and have vault set as lpVault)
    /// @param amount  USDC amount to deploy (6 decimals)
    function deployTo(address market, uint256 amount) external onlyOwner {
        if (!isRegistered[market]) revert MarketNotRegistered();

        uint256 ta = totalAssets();
        uint256 vaultLiquid = IERC20(asset()).balanceOf(address(this));

        // Guard 1: we actually have the liquid USDC
        if (amount > vaultLiquid) revert InsufficientLiquidBuffer();

        // Guard 2: per-market cap (skip on first ever deployment when ta == 0)
        if (ta > 0) {
            uint256 newMarketDeployed = deployedTo[market] + amount;
            if ((newMarketDeployed * BPS_DENOMINATOR) / ta > MAX_MARKET_BPS) {
                revert ExceedsMarketCap();
            }
        }

        // Guard 3: 20% buffer still satisfied after deployment.
        // NAV is unchanged (USDC moves vault→market, poolBalance increases by same amount).
        uint256 liquidAfter   = vaultLiquid - amount;
        uint256 requiredAfter = (ta * LIQUID_BUFFER_BPS) / BPS_DENOMINATOR;
        if (liquidAfter < requiredAfter) revert InsufficientLiquidBuffer();

        deployedTo[market] += amount;
        totalDeployed      += amount;

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
    function harvestSurplus(address market) external {
        if (!isRegistered[market]) revert MarketNotRegistered();

        LMSRMarket m = LMSRMarket(market);
        uint256 surplus = m.getWithdrawableSurplus();
        if (surplus == 0) revert NothingToHarvest();

        uint256 before = IERC20(asset()).balanceOf(address(this));
        m.withdrawSurplus(address(this), surplus);
        uint256 harvested = IERC20(asset()).balanceOf(address(this)) - before;

        emit SurplusHarvested(market, harvested);
    }

    /// @notice Pull LP residual from a resolved market back to the vault.
    ///         Permissionless. Market must be RESOLVED and not yet claimed.
    function harvestResolved(address market) external {
        if (!isRegistered[market]) revert MarketNotRegistered();

        LMSRMarket m = LMSRMarket(market);
        if (m.status() != LMSRMarket.MarketStatus.RESOLVED) revert MarketNotResolved();
        if (m.lpWithdrawn()) revert NothingToHarvest();

        uint256 before = IERC20(asset()).balanceOf(address(this));
        m.withdrawLP();
        uint256 harvested = IERC20(asset()).balanceOf(address(this)) - before;

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

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Value the vault attributes to each market in totalAssets().
    ///         Active:   full poolBalance (LPs bear risk; capital returns at resolution)
    ///         Resolved: pool minus unclaimed winning shares (net LP residual)
    ///         Other:    0
    function _claimableFromMarket(address market) internal view returns (uint256) {
        if (deployedTo[market] == 0) return 0; // vault has no claim on markets it never funded
        LMSRMarket m = LMSRMarket(market);
        LMSRMarket.MarketStatus s = m.status();

        if (s == LMSRMarket.MarketStatus.ACTIVE) {
            return m.poolBalance();
        }

        if (s == LMSRMarket.MarketStatus.RESOLVED && !m.lpWithdrawn()) {
            LMSRMarket.Bucket memory winBucket = m.getBucket(m.winningBucket());
            uint256 pool = m.poolBalance();
            return pool > winBucket.shares ? pool - winBucket.shares : 0;
        }

        return 0;
    }
}
