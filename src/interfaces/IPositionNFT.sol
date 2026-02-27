// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IPositionNFT {
    function mint(address to, uint256 tokenId, uint256 amount) external;
    function burn(address from, uint256 tokenId, uint256 amount) external;
    function balanceOf(address account, uint256 id) external view returns (uint256);
}
