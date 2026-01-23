// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {LMSRMarket} from "./LMSRMarket.sol";
import {PositionNFT} from "./PositionNFT.sol";
import {IUSDC} from "./interfaces/IUSDC.sol";
import {Ownable} from "@openzeppelin/access/Ownable.sol";

/// @notice Factory contract for creating LMSR prediction markets
/// @dev Deploys LMSRMarket contracts and manages global parameters
contract MarketFactory is Ownable {
    
    /// @notice Address of the shared PositionNFT contract
    PositionNFT public immutable positionNFT;
    
    /// @notice USDC token contract
    IUSDC public immutable usdcToken;
    
    /// @notice Total number of markets created
    uint256 public marketCount;
    
    /// @notice Mapping of market addresses to validity
    mapping(address => bool) public isValidMarket;
    
    /// @notice Mapping of market ID to market address
    mapping(uint256 => address) public marketById;
    
    /// @notice Minimum pool balance required to create a market (in USDC 6 decimals)
    uint256 public minPoolBalance;
    
    /// @notice Maximum number of buckets allowed per market
    uint256 public maxBuckets;
    
    /// @notice Default fee in basis points (0.5% = 50 bps)
    uint256 public defaultFeeBps;
    
    /// @notice Default protocol fee percentage of total fees (20% = 2000 bps)
    uint256 public defaultProtocolFeeBps;
    
    event MarketCreated(
        uint256 indexed marketId,
        address indexed marketAddress,
        address indexed creator,
        uint256 poolBalance,
        uint256 bucketCount
    );
    
    event MinPoolBalanceUpdated(uint256 oldValue, uint256 newValue);
    event MaxBucketsUpdated(uint256 oldValue, uint256 newValue);
    event DefaultFeeBpsUpdated(uint256 oldValue, uint256 newValue);
    event DefaultProtocolFeeBpsUpdated(uint256 oldValue, uint256 newValue);
    event MarketPaused(uint256 indexed marketId, address indexed marketAddress);
    
    error InvalidParameters();
    error PoolBalanceTooLow();
    error TooManyBuckets();
    error InvalidBucketRanges();
    
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
        if (_defaultFeeBps > 500) revert InvalidParameters(); // Max 5%
        if (_defaultProtocolFeeBps > 10000) revert InvalidParameters(); // Max 100%
        
        usdcToken = IUSDC(_usdcToken);
        positionNFT = PositionNFT(_positionNFT);
        minPoolBalance = _minPoolBalance;
        maxBuckets = _maxBuckets;
        defaultFeeBps = _defaultFeeBps;
        defaultProtocolFeeBps = _defaultProtocolFeeBps;
    }
    
    /// @notice Create a new prediction market
    /// @param poolBalance Initial liquidity in USDC (6 decimals)
    /// @param bucketRanges Array of bucket boundaries (length = buckets + 1)
    /// @param feeBps Trading fee in basis points (optional, 0 = use default)
    /// @param protocolFeeBps Protocol fee share in basis points (optional, 0 = use default)
    /// @return marketAddress Address of the newly created market
    function createMarket(
        uint256 poolBalance,
        uint256[] memory bucketRanges,
        uint256 feeBps,
        uint256 protocolFeeBps
    ) external returns (address marketAddress) {
        // Validate parameters
        if (poolBalance < minPoolBalance) revert PoolBalanceTooLow();
        if (bucketRanges.length < 2) revert InvalidParameters();
        if (bucketRanges.length - 1 > maxBuckets) revert TooManyBuckets();
        
        // Validate bucket ranges are strictly increasing
        for (uint256 i = 1; i < bucketRanges.length; i++) {
            if (bucketRanges[i] <= bucketRanges[i - 1]) {
                revert InvalidBucketRanges();
            }
        }
        
        // Use default fees if not specified
        uint256 actualFeeBps = feeBps == 0 ? defaultFeeBps : feeBps;
        uint256 actualProtocolFeeBps = protocolFeeBps == 0 ? defaultProtocolFeeBps : protocolFeeBps;
        
        // Validate fee parameters
        if (actualFeeBps > 500) revert InvalidParameters(); // Max 5%
        if (actualProtocolFeeBps > 10000) revert InvalidParameters(); // Max 100%
        
        // Increment market count
        uint256 marketId = marketCount++;
        
        // Calculate alpha (will be overridden by dynamic alpha in constructor)
        uint256 bucketCount = bucketRanges.length - 1;
        uint256 alpha = 100e18; // Placeholder, market will calculate dynamic alpha
        
        // Deploy new market
        LMSRMarket market = new LMSRMarket(
            marketId,
            msg.sender, // creator
            address(this), // factory
            address(usdcToken),
            address(positionNFT),
            alpha,
            poolBalance,
            bucketRanges,
            actualFeeBps,
            actualProtocolFeeBps
        );
        
        marketAddress = address(market);
        
        // Register market
        isValidMarket[marketAddress] = true;
        marketById[marketId] = marketAddress;
        
        // Authorize market to mint position NFTs
        positionNFT.authorizeMarket(marketAddress, marketId);
        
        // Transfer initial pool balance from creator to market
        usdcToken.transferFrom(msg.sender, marketAddress, poolBalance);
        
        emit MarketCreated(marketId, marketAddress, msg.sender, poolBalance, bucketCount);
    }
    
    /// @notice Set minimum pool balance requirement
    /// @param newMinPoolBalance New minimum in USDC (6 decimals)
    function setMinPoolBalance(uint256 newMinPoolBalance) external onlyOwner {
        if (newMinPoolBalance == 0) revert InvalidParameters();
        uint256 oldValue = minPoolBalance;
        minPoolBalance = newMinPoolBalance;
        emit MinPoolBalanceUpdated(oldValue, newMinPoolBalance);
    }
    
    /// @notice Set maximum buckets per market
    /// @param newMaxBuckets New maximum bucket count
    function setMaxBuckets(uint256 newMaxBuckets) external onlyOwner {
        if (newMaxBuckets < 2) revert InvalidParameters();
        uint256 oldValue = maxBuckets;
        maxBuckets = newMaxBuckets;
        emit MaxBucketsUpdated(oldValue, newMaxBuckets);
    }
    
    /// @notice Set default trading fee
    /// @param newDefaultFeeBps New fee in basis points
    function setDefaultFeeBps(uint256 newDefaultFeeBps) external onlyOwner {
        if (newDefaultFeeBps > 500) revert InvalidParameters(); // Max 5%
        uint256 oldValue = defaultFeeBps;
        defaultFeeBps = newDefaultFeeBps;
        emit DefaultFeeBpsUpdated(oldValue, newDefaultFeeBps);
    }
    
    /// @notice Set default protocol fee percentage
    /// @param newDefaultProtocolFeeBps New protocol fee share in basis points
    function setDefaultProtocolFeeBps(uint256 newDefaultProtocolFeeBps) external onlyOwner {
        if (newDefaultProtocolFeeBps > 10000) revert InvalidParameters(); // Max 100%
        uint256 oldValue = defaultProtocolFeeBps;
        defaultProtocolFeeBps = newDefaultProtocolFeeBps;
        emit DefaultProtocolFeeBpsUpdated(oldValue, newDefaultProtocolFeeBps);
    }
    
    /// @notice Emergency pause a market (sets status to EMERGENCY_PAUSED)
    /// @param marketId The market ID to pause
    /// @dev This is a placeholder - actual implementation requires adding pause functionality to LMSRMarket
    function pauseMarket(uint256 marketId) external onlyOwner {
        address marketAddress = marketById[marketId];
        if (marketAddress == address(0)) revert InvalidParameters();
        if (!isValidMarket[marketAddress]) revert InvalidParameters();
        
        // TODO: Add pauseMarket() function to LMSRMarket contract
        // For now, just emit event
        emit MarketPaused(marketId, marketAddress);
    }
}
