// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IUSDC} from "./interfaces/IUSDC.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {IPositionNFT} from "./interfaces/IPositionNFT.sol";
import {LMSRMarket} from "./LMSRMarket.sol";
import {Ownable} from "@openzeppelin/access/Ownable.sol";
import {Pausable} from "@openzeppelin/utils/Pausable.sol";

interface IMarketFactory {
    function isValidMarket(address) external view returns (bool);
}

/// @notice Unified stateless router for all LMSR market operations.
/// @dev Two one-time approvals per user:
///      1. USDC.approve(router, type(uint256).max) — for buys
///      2. positionNFT.setApprovalForAll(router, true) — for sells/claims
///      Router never retains funds or positions between transactions.
contract TradeRouter is Ownable, Pausable {
    using SafeERC20 for IERC20;

    IUSDC public immutable usdc;
    IPositionNFT public immutable positionNFT;
    IMarketFactory public immutable factory;

    /// @notice Max USDC per buy (6 decimals). 0 = no limit.
    uint256 public maxBuyAmount;

    event SharesBought(
        address indexed market,
        address indexed buyer,
        uint256 rangeLower,
        uint256 rangeUpper,
        uint256 shares,
        uint256 amountUSDC
    );

    event SharesSold(
        address indexed market,
        address indexed seller,
        uint256 rangeLower,
        uint256 rangeUpper,
        uint256 shares,
        uint256 payoutUSDC
    );

    event WinningsClaimed(
        address indexed market,
        address indexed claimer,
        uint256 tokenId,
        uint256 payoutUSDC
    );

    error ZeroAmount();
    error BuyExceedsLimit();
    error InvalidMarket();

    modifier onlyValidMarket(LMSRMarket market) {
        if (!factory.isValidMarket(address(market))) revert InvalidMarket();
        _;
    }

    constructor(address _usdc, address _positionNFT, address _factory) Ownable(msg.sender) {
        usdc = IUSDC(_usdc);
        positionNFT = IPositionNFT(_positionNFT);
        factory = IMarketFactory(_factory);
    }

    function setMaxBuyAmount(uint256 _maxBuyAmount) external onlyOwner {
        maxBuyAmount = _maxBuyAmount;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // ═══════════════════════════════════════════════════════════════════════
    //                              BUY
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Buy shares — USDC pulled from user, NFT minted to user
    function buy(
        LMSRMarket market,
        uint256 rangeLower,
        uint256 rangeUpper,
        uint256 amountUSDC,
        uint256 minSharesOut,
        uint256 targetShares
    ) external whenNotPaused onlyValidMarket(market) returns (uint256 shares) {
        if (amountUSDC == 0) revert ZeroAmount();
        if (maxBuyAmount > 0 && amountUSDC > maxBuyAmount) revert BuyExceedsLimit();
        IERC20(address(usdc)).safeTransferFrom(msg.sender, address(this), amountUSDC);
        IERC20(address(usdc)).forceApprove(address(market), amountUSDC);
        shares = market.buySharesRange(
            rangeLower, rangeUpper, amountUSDC, minSharesOut, targetShares, msg.sender
        );
        emit SharesBought(address(market), msg.sender, rangeLower, rangeUpper, shares, amountUSDC);
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
    ) external whenNotPaused onlyValidMarket(market) returns (uint256 shares) {
        if (amountUSDC == 0) revert ZeroAmount();
        if (maxBuyAmount > 0 && amountUSDC > maxBuyAmount) revert BuyExceedsLimit();
        usdc.permit(msg.sender, address(this), amountUSDC, deadline, v, r, s);
        IERC20(address(usdc)).safeTransferFrom(msg.sender, address(this), amountUSDC);
        IERC20(address(usdc)).forceApprove(address(market), amountUSDC);
        shares = market.buySharesRange(
            rangeLower, rangeUpper, amountUSDC, minSharesOut, targetShares, msg.sender
        );
        emit SharesBought(address(market), msg.sender, rangeLower, rangeUpper, shares, amountUSDC);
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
        uint256 minUsdcOut
    ) external whenNotPaused onlyValidMarket(market) returns (uint256 payoutUSDC) {
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
        payoutUSDC = market.sellSharesRange(
            rangeLower, rangeUpper, sharesToSell, minUsdcOut, msg.sender
        );
        emit SharesSold(address(market), msg.sender, rangeLower, rangeUpper, sharesToSell, payoutUSDC);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                              CLAIM
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Claim winnings — NFTs pulled from user, USDC sent to user
    /// @dev Claims full NFT balance (no partial claims)
    function claim(
        LMSRMarket market,
        uint256 tokenId
    ) external whenNotPaused onlyValidMarket(market) returns (uint256 payoutUSDC) {
        // Pull all NFTs from user
        uint256 balance = positionNFT.balanceOf(msg.sender, tokenId);
        if (balance == 0) revert ZeroAmount();
        positionNFT.safeTransferFrom(msg.sender, address(this), tokenId, balance, "");

        // Claim — market burns from router, sends USDC to user
        payoutUSDC = market.claim(tokenId, msg.sender);
        emit WinningsClaimed(address(market), msg.sender, tokenId, payoutUSDC);
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
