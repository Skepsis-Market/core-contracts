// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IUSDC} from "./interfaces/IUSDC.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {IPositionNFT} from "./interfaces/IPositionNFT.sol";
import {LMSRMarket} from "./LMSRMarket.sol";
import {Ownable} from "@openzeppelin/access/Ownable.sol";
import {Pausable} from "@openzeppelin/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/utils/ReentrancyGuard.sol";

interface IMarketFactory {
    function isValidMarket(address) external view returns (bool);
}

/// @notice Unified stateless router for all LMSR market operations.
/// @dev Two one-time approvals per user:
///      1. USDC.approve(router, type(uint256).max) — for buys
///      2. positionNFT.setApprovalForAll(router, true) — for sells/claims
///      Router never retains funds or positions between transactions.
contract TradeRouter is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IUSDC public immutable usdc;
    IPositionNFT public immutable positionNFT;
    IMarketFactory public immutable factory;

    /// @notice Max USDC per buy (6 decimals). 0 = no limit.
    uint256 public maxBuyAmount;

    /// @dev Enriched with post-trade state so the indexer can maintain
    ///      `poolBalance` / `maxLiability` from event deltas alone (no
    ///      recurring re-reads of the market contract). `actualCost` is the
    ///      LMSR-priced cost actually charged (may be < `amountUSDC` because
    ///      the contract refunds unused budget for range buys).
    event SharesBought(
        address indexed market,
        address indexed buyer,
        uint256 rangeLower,
        uint256 rangeUpper,
        uint256 shares,
        uint256 amountUSDC,
        uint256 actualCost,
        uint256 lpFeeUSDC,
        uint256 protocolFeeUSDC,
        uint256 newPoolBalance,
        uint256 newMaxLiability
    );

    /// @dev Enriched with fee split + post-trade `newPoolBalance` for the
    ///      same drift-elimination reason as `SharesBought`.
    event SharesSold(
        address indexed market,
        address indexed seller,
        uint256 rangeLower,
        uint256 rangeUpper,
        uint256 shares,
        uint256 payoutUSDC,
        uint256 lpFeeUSDC,
        uint256 protocolFeeUSDC,
        uint256 newPoolBalance
    );

    /// @dev `newWinningBucketShares` lets the indexer write the post-claim
    ///      bucket shares value directly instead of computing a delta —
    ///      self-healing if any prior trade event was missed.
    event WinningsClaimed(
        address indexed market,
        address indexed claimer,
        uint256 tokenId,
        uint256 payoutUSDC,
        uint256 newPoolBalance,
        uint256 newWinningBucketShares
    );

    event MaxBuyAmountUpdated(uint256 oldValue, uint256 newValue);

    error ZeroAmount();
    error BuyExceedsLimit();
    error InvalidMarket();
    error Expired();

    modifier onlyValidMarket(LMSRMarket market) {
        if (!factory.isValidMarket(address(market))) revert InvalidMarket();
        _;
    }

    modifier ensure(uint256 deadline) {
        if (block.timestamp > deadline) revert Expired();
        _;
    }

    constructor(address _usdc, address _positionNFT, address _factory) Ownable(msg.sender) {
        usdc = IUSDC(_usdc);
        positionNFT = IPositionNFT(_positionNFT);
        factory = IMarketFactory(_factory);
    }

    function setMaxBuyAmount(uint256 _maxBuyAmount) external onlyOwner {
        uint256 oldValue = maxBuyAmount;
        maxBuyAmount = _maxBuyAmount;
        emit MaxBuyAmountUpdated(oldValue, _maxBuyAmount);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // ═══════════════════════════════════════════════════════════════════════
    //                              BUY
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Buy shares — USDC pulled from user, NFT minted to user
    /// @param deadline Unix timestamp after which the trade is invalid (slippage + staleness protection)
    function buy(
        LMSRMarket market,
        uint256 rangeLower,
        uint256 rangeUpper,
        uint256 amountUSDC,
        uint256 minSharesOut,
        uint256 targetShares,
        uint256 deadline
    ) external nonReentrant whenNotPaused ensure(deadline) onlyValidMarket(market) returns (uint256 shares) {
        if (amountUSDC == 0) revert ZeroAmount();
        if (maxBuyAmount > 0 && amountUSDC > maxBuyAmount) revert BuyExceedsLimit();
        IERC20(address(usdc)).safeTransferFrom(msg.sender, address(this), amountUSDC);
        IERC20(address(usdc)).forceApprove(address(market), amountUSDC);
        (
            uint256 _shares,
            uint256 actualCost,
            uint256 lpFeeUSDC,
            uint256 protocolFeeUSDC,
            uint256 newPoolBalance,
            uint256 newMaxLiability
        ) = market.buySharesRange(
            rangeLower, rangeUpper, amountUSDC, minSharesOut, targetShares, msg.sender
        );
        shares = _shares;
        emit SharesBought(
            address(market),
            msg.sender,
            rangeLower,
            rangeUpper,
            shares,
            amountUSDC,
            actualCost,
            lpFeeUSDC,
            protocolFeeUSDC,
            newPoolBalance,
            newMaxLiability
        );
    }

    /// @notice Buy with EIP-2612 permit — zero prior USDC approval needed
    function buyWithPermit(
        LMSRMarket market,
        uint256 rangeLower,
        uint256 rangeUpper,
        uint256 amountUSDC,
        uint256 minSharesOut,
        uint256 targetShares,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant whenNotPaused ensure(deadline) onlyValidMarket(market) returns (uint256 shares) {
        if (amountUSDC == 0) revert ZeroAmount();
        if (maxBuyAmount > 0 && amountUSDC > maxBuyAmount) revert BuyExceedsLimit();
        usdc.permit(msg.sender, address(this), amountUSDC, deadline, v, r, s);
        IERC20(address(usdc)).safeTransferFrom(msg.sender, address(this), amountUSDC);
        IERC20(address(usdc)).forceApprove(address(market), amountUSDC);
        (
            uint256 _shares,
            uint256 actualCost,
            uint256 lpFeeUSDC,
            uint256 protocolFeeUSDC,
            uint256 newPoolBalance,
            uint256 newMaxLiability
        ) = market.buySharesRange(
            rangeLower, rangeUpper, amountUSDC, minSharesOut, targetShares, msg.sender
        );
        shares = _shares;
        emit SharesBought(
            address(market),
            msg.sender,
            rangeLower,
            rangeUpper,
            shares,
            amountUSDC,
            actualCost,
            lpFeeUSDC,
            protocolFeeUSDC,
            newPoolBalance,
            newMaxLiability
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                              SELL
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Sell shares — NFTs pulled from user, USDC sent to user
    /// @dev Requires positionNFT.setApprovalForAll(router, true) from user
    function sell(
        LMSRMarket market,
        uint256 rangeLower,
        uint256 rangeUpper,
        uint256 sharesToSell,
        uint256 minUsdcOut,
        uint256 deadline
    ) external nonReentrant whenNotPaused ensure(deadline) onlyValidMarket(market) returns (uint256 payoutUSDC) {
        if (sharesToSell == 0) revert ZeroAmount();

        // Compute tokenId for this range (absolute bucket indexing)
        uint256 startBucket = rangeLower / market.bucketWidth();
        uint256 endBucket = (rangeUpper - 1) / market.bucketWidth();
        uint256 tokenId = (uint256(uint128(market.marketId())) << 128)
            | (uint256(uint64(startBucket)) << 64)
            | uint256(uint64(endBucket));

        // Pull NFTs from user to router (partial — only sharesToSell)
        positionNFT.safeTransferFrom(msg.sender, address(this), tokenId, sharesToSell, "");

        // Sell — market burns from router, sends USDC to user
        (
            uint256 _payoutUSDC,
            uint256 lpFeeUSDC,
            uint256 protocolFeeUSDC,
            uint256 newPoolBalance
        ) = market.sellSharesRange(
            rangeLower, rangeUpper, sharesToSell, minUsdcOut, msg.sender
        );
        payoutUSDC = _payoutUSDC;
        emit SharesSold(
            address(market),
            msg.sender,
            rangeLower,
            rangeUpper,
            sharesToSell,
            payoutUSDC,
            lpFeeUSDC,
            protocolFeeUSDC,
            newPoolBalance
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                              CLAIM
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Claim winnings — NFTs pulled from user, USDC sent to user
    /// @dev Claims full NFT balance (no partial claims)
    function claim(
        LMSRMarket market,
        uint256 tokenId,
        uint256 deadline
    ) external nonReentrant whenNotPaused ensure(deadline) onlyValidMarket(market) returns (uint256 payoutUSDC) {
        // Pull all NFTs from user
        uint256 balance = positionNFT.balanceOf(msg.sender, tokenId);
        if (balance == 0) revert ZeroAmount();
        positionNFT.safeTransferFrom(msg.sender, address(this), tokenId, balance, "");

        // Claim — market burns from router, sends USDC to user
        (
            uint256 _payoutUSDC,
            uint256 newPoolBalance,
            uint256 newWinningBucketShares
        ) = market.claim(tokenId, msg.sender);
        payoutUSDC = _payoutUSDC;
        emit WinningsClaimed(
            address(market),
            msg.sender,
            tokenId,
            payoutUSDC,
            newPoolBalance,
            newWinningBucketShares
        );
    }

    /// @notice ERC-1155 receiver — required for safeTransferFrom
    function onERC1155Received(address, address, uint256, uint256, bytes calldata)
        external pure returns (bytes4)
    {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external pure returns (bytes4)
    {
        return this.onERC1155BatchReceived.selector;
    }
}
