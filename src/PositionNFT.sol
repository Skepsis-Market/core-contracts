// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC1155} from "@openzeppelin/token/ERC1155/ERC1155.sol";

/// @notice ERC-1155 position NFTs for prediction market shares
/// @dev Token ID encoding: (marketId << 128) | (rangeLower << 64) | rangeUpper
/// @dev For single-bucket positions, rangeLower == rangeUpper
contract PositionNFT is ERC1155 {
    
    /// @notice Factory contract that deploys markets
    address public immutable factory;
    
    /// @notice IPFS CID storage per market for metadata
    /// @dev Maps marketId => CID (bytes32 for gas efficiency)
    mapping(uint256 => bytes32) private cidByMarket;
    
    /// @notice Markets authorized to mint/burn tokens
    /// @dev Set by factory when deploying new market
    mapping(address => bool) public isAuthorizedMarket;
    
    event MarketAuthorized(address indexed market, uint256 indexed marketId);
    event CIDSet(uint256 indexed marketId, bytes32 cid);
    
    error Unauthorized();
    error InvalidTokenId();
    
    modifier onlyMarket() {
        if (!isAuthorizedMarket[msg.sender]) revert Unauthorized();
        _;
    }
    
    modifier onlyFactory() {
        if (msg.sender != factory) revert Unauthorized();
        _;
    }
    
    constructor(address _factory) ERC1155("") {
        factory = _factory;
    }
    
    /// @notice Encode market ID and range bounds into a single token ID
    /// @param marketId The market identifier (must fit in uint128)
    /// @param rangeLower The lower bucket index (must fit in uint64)
    /// @param rangeUpper The upper bucket index (must fit in uint64)
    /// @return tokenId The encoded token ID
    /// @dev For single-bucket positions, set rangeLower == rangeUpper
    function encodeTokenId(uint256 marketId, uint256 rangeLower, uint256 rangeUpper) 
        public 
        pure 
        returns (uint256 tokenId) 
    {
        require(rangeUpper >= rangeLower, "Invalid range");
        tokenId = (uint256(uint128(marketId)) << 128) | (uint256(uint64(rangeLower)) << 64) | uint256(uint64(rangeUpper));
    }
    
    /// @notice Legacy encoder for single-bucket positions (backwards compatibility)
    /// @param marketId The market identifier
    /// @param bucketId The bucket identifier
    /// @return tokenId The encoded token ID with rangeLower == rangeUpper == bucketId
    function encodeTokenIdSingle(uint256 marketId, uint256 bucketId) 
        public 
        pure 
        returns (uint256 tokenId) 
    {
        return encodeTokenId(marketId, bucketId, bucketId);
    }
    
    /// @notice Decode a token ID back into market ID and range bounds
    /// @param tokenId The encoded token ID
    /// @return marketId The market identifier
    /// @return rangeLower The lower bucket index
    /// @return rangeUpper The upper bucket index
    function decodeTokenId(uint256 tokenId) 
        public 
        pure 
        returns (uint256 marketId, uint256 rangeLower, uint256 rangeUpper) 
    {
        marketId = tokenId >> 128;
        rangeLower = uint256(uint64(tokenId >> 64));
        rangeUpper = uint256(uint64(tokenId));
    }
    
    /// @notice Check if a token represents a range (multiple buckets)
    /// @param tokenId The encoded token ID
    /// @return isRange True if rangeLower != rangeUpper
    function isRangeToken(uint256 tokenId) public pure returns (bool) {
        (, uint256 lower, uint256 upper) = decodeTokenId(tokenId);
        return lower != upper;
    }
    
    /// @notice Get the number of buckets covered by a token
    /// @param tokenId The encoded token ID
    /// @return count Number of buckets (rangeUpper - rangeLower + 1)
    function bucketCount(uint256 tokenId) public pure returns (uint256) {
        (, uint256 lower, uint256 upper) = decodeTokenId(tokenId);
        return upper - lower + 1;
    }
    
    /// @notice Authorize a market contract to mint/burn tokens
    /// @dev Only factory can authorize markets
    /// @param market The market contract address
    /// @param marketId The market's unique identifier
    function authorizeMarket(address market, uint256 marketId) 
        external 
        onlyFactory 
    {
        isAuthorizedMarket[market] = true;
        emit MarketAuthorized(market, marketId);
    }
    
    /// @notice Set IPFS CID for a market's metadata
    /// @dev Only factory can set CID during market creation
    /// @param marketId The market identifier
    /// @param cid The IPFS CID as bytes32
    function setCID(uint256 marketId, bytes32 cid) 
        external 
        onlyFactory 
    {
        cidByMarket[marketId] = cid;
        emit CIDSet(marketId, cid);
    }
    
    /// @notice Mint position tokens to a user
    /// @dev Only authorized markets can mint
    /// @param to Recipient address
    /// @param tokenId Encoded token ID (marketId << 128 | rangeLower << 64 | rangeUpper)
    /// @param amount Number of tokens to mint
    function mint(address to, uint256 tokenId, uint256 amount) 
        external 
        onlyMarket 
    {
        _mint(to, tokenId, amount, "");
    }
    
    /// @notice Burn position tokens from a user
    /// @dev Only authorized markets can burn
    /// @param from Token holder address
    /// @param tokenId Encoded token ID
    /// @param amount Number of tokens to burn
    function burn(address from, uint256 tokenId, uint256 amount) 
        external 
        onlyMarket 
    {
        _burn(from, tokenId, amount);
    }
    
    /// @notice Get token URI with IPFS CID
    /// @param tokenId Encoded token ID
    /// @return URI string in format ipfs://{CID}/{rangeLower}-{rangeUpper}.json
    function uri(uint256 tokenId) 
        public 
        view 
        override 
        returns (string memory) 
    {
        (uint256 marketId, uint256 rangeLower, uint256 rangeUpper) = decodeTokenId(tokenId);
        bytes32 cid = cidByMarket[marketId];
        
        // Convert CID from bytes32 to hex string (simplified - real impl would use proper base58)
        return string(
            abi.encodePacked(
                "ipfs://",
                _toHexString(cid),
                "/",
                _toString(rangeLower),
                "-",
                _toString(rangeUpper),
                ".json"
            )
        );
    }
    
    /// @dev Helper to convert bytes32 to hex string
    function _toHexString(bytes32 data) private pure returns (string memory) {
        bytes memory alphabet = "0123456789abcdef";
        bytes memory str = new bytes(64);
        for (uint256 i = 0; i < 32; i++) {
            str[i * 2] = alphabet[uint8(data[i] >> 4)];
            str[1 + i * 2] = alphabet[uint8(data[i] & 0x0f)];
        }
        return string(str);
    }
    
    /// @dev Helper to convert uint to string
    function _toString(uint256 value) private pure returns (string memory) {
        if (value == 0) {
            return "0";
        }
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}
