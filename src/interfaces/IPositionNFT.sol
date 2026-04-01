// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IPositionNFT {
    function mint(address to, uint256 tokenId, uint256 amount) external;
    function burn(address from, uint256 tokenId, uint256 amount) external;
    function balanceOf(address account, uint256 id) external view returns (uint256);
    function decodeTokenId(uint256 tokenId) external pure returns (uint256 marketId, uint256 rangeLower, uint256 rangeUpper);
    function safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes calldata data) external;
    function setApprovalForAll(address operator, bool approved) external;
    function isApprovedForAll(address account, address operator) external view returns (bool);
}
