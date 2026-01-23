// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {PositionNFT} from "../src/PositionNFT.sol";

contract PositionNFTTest is Test {
    PositionNFT nft;
    
    address factory = address(0xFACE);
    address market1 = address(0x1);
    address market2 = address(0x2);
    address user1 = address(0x123);
    address user2 = address(0x456);
    
    uint256 marketId1 = 1;
    uint256 marketId2 = 2;
    bytes32 cid1 = bytes32(uint256(0x1234567890abcdef));
    
    function setUp() public {
        vm.prank(factory);
        nft = new PositionNFT(factory);
    }
    
    function test_encodeTokenId_handlesLargeIds() public {
        uint256 marketId = type(uint128).max;
        uint256 bucketId = type(uint128).max;
        
        uint256 tokenId = nft.encodeTokenId(marketId, bucketId);
        
        // Should not revert and encode correctly
        assertEq(tokenId, type(uint256).max, "Should encode max values correctly");
    }
    
    function test_decodeTokenId_recoversOriginal() public {
        uint256 originalMarketId = 42;
        uint256 originalBucketId = 7;
        
        uint256 tokenId = nft.encodeTokenId(originalMarketId, originalBucketId);
        (uint256 recoveredMarketId, uint256 recoveredBucketId) = nft.decodeTokenId(tokenId);
        
        assertEq(recoveredMarketId, originalMarketId, "Market ID should match");
        assertEq(recoveredBucketId, originalBucketId, "Bucket ID should match");
    }
    
    function test_decodeTokenId_handlesEdgeCases() public {
        // Test with max values
        uint256 tokenId = type(uint256).max;
        (uint256 marketId, uint256 bucketId) = nft.decodeTokenId(tokenId);
        
        assertEq(marketId, type(uint128).max, "Should decode max market ID");
        assertEq(bucketId, type(uint128).max, "Should decode max bucket ID");
    }
    
    function test_mint_onlyMarket() public {
        // Authorize market1
        vm.prank(factory);
        nft.authorizeMarket(market1, marketId1);
        
        uint256 tokenId = nft.encodeTokenId(marketId1, 0);
        uint256 amount = 100e18;
        
        vm.prank(market1);
        nft.mint(user1, tokenId, amount);
        
        assertEq(nft.balanceOf(user1, tokenId), amount, "User should have minted tokens");
    }
    
    function test_mint_revertsIfNotMarket() public {
        uint256 tokenId = nft.encodeTokenId(marketId1, 0);
        uint256 amount = 100e18;
        
        // Try to mint without authorization
        vm.prank(user1);
        vm.expectRevert(PositionNFT.Unauthorized.selector);
        nft.mint(user1, tokenId, amount);
    }
    
    function test_burn_onlyMarket() public {
        // Authorize market1 and mint tokens
        vm.prank(factory);
        nft.authorizeMarket(market1, marketId1);
        
        uint256 tokenId = nft.encodeTokenId(marketId1, 0);
        uint256 amount = 100e18;
        
        vm.prank(market1);
        nft.mint(user1, tokenId, amount);
        
        // Burn tokens
        vm.prank(market1);
        nft.burn(user1, tokenId, 50e18);
        
        assertEq(nft.balanceOf(user1, tokenId), 50e18, "Should have burned 50 tokens");
    }
    
    function test_burn_revertsIfNotMarket() public {
        // Authorize market1 and mint tokens
        vm.prank(factory);
        nft.authorizeMarket(market1, marketId1);
        
        uint256 tokenId = nft.encodeTokenId(marketId1, 0);
        uint256 amount = 100e18;
        
        vm.prank(market1);
        nft.mint(user1, tokenId, amount);
        
        // Try to burn without authorization
        vm.prank(user1);
        vm.expectRevert(PositionNFT.Unauthorized.selector);
        nft.burn(user1, tokenId, 10e18);
    }
    
    function test_transfer_works() public {
        // Authorize market1 and mint tokens to user1
        vm.prank(factory);
        nft.authorizeMarket(market1, marketId1);
        
        uint256 tokenId = nft.encodeTokenId(marketId1, 0);
        uint256 amount = 100e18;
        
        vm.prank(market1);
        nft.mint(user1, tokenId, amount);
        
        // Transfer from user1 to user2
        vm.prank(user1);
        nft.safeTransferFrom(user1, user2, tokenId, 30e18, "");
        
        assertEq(nft.balanceOf(user1, tokenId), 70e18, "User1 should have 70 tokens");
        assertEq(nft.balanceOf(user2, tokenId), 30e18, "User2 should have 30 tokens");
    }
    
    function test_uri_returnsCorrectIPFS() public {
        // Set CID for market1
        vm.prank(factory);
        nft.setCID(marketId1, cid1);
        
        uint256 tokenId = nft.encodeTokenId(marketId1, 3); // Bucket 3
        string memory tokenURI = nft.uri(tokenId);
        
        // Should start with ipfs://
        assertTrue(
            bytes(tokenURI).length > 7 && 
            bytes(tokenURI)[0] == 'i' &&
            bytes(tokenURI)[1] == 'p' &&
            bytes(tokenURI)[2] == 'f' &&
            bytes(tokenURI)[3] == 's',
            "URI should start with ipfs"
        );
        
        // Should end with /3.json
        bytes memory uriBytes = bytes(tokenURI);
        assertTrue(
            uriBytes[uriBytes.length - 6] == '3' &&
            uriBytes[uriBytes.length - 5] == '.',
            "URI should contain bucket ID"
        );
    }
    
    function test_balanceOf_updatesCorrectly() public {
        // Authorize market1
        vm.prank(factory);
        nft.authorizeMarket(market1, marketId1);
        
        uint256 tokenId = nft.encodeTokenId(marketId1, 0);
        
        // Initial balance should be 0
        assertEq(nft.balanceOf(user1, tokenId), 0, "Initial balance should be 0");
        
        // Mint tokens
        vm.prank(market1);
        nft.mint(user1, tokenId, 100e18);
        assertEq(nft.balanceOf(user1, tokenId), 100e18, "Balance should be 100");
        
        // Mint more
        vm.prank(market1);
        nft.mint(user1, tokenId, 50e18);
        assertEq(nft.balanceOf(user1, tokenId), 150e18, "Balance should be 150");
        
        // Burn some
        vm.prank(market1);
        nft.burn(user1, tokenId, 30e18);
        assertEq(nft.balanceOf(user1, tokenId), 120e18, "Balance should be 120");
    }
    
    function test_authorizeMarket_onlyFactory() public {
        // Should work when called by factory
        vm.prank(factory);
        nft.authorizeMarket(market1, marketId1);
        assertTrue(nft.isAuthorizedMarket(market1), "Market1 should be authorized");
        
        // Should revert when called by non-factory
        vm.prank(user1);
        vm.expectRevert(PositionNFT.Unauthorized.selector);
        nft.authorizeMarket(market2, marketId2);
    }
    
    function test_setCID_onlyFactory() public {
        // Should work when called by factory
        vm.prank(factory);
        nft.setCID(marketId1, cid1);
        
        // Verify CID was set by checking URI
        uint256 tokenId = nft.encodeTokenId(marketId1, 0);
        string memory uri = nft.uri(tokenId);
        assertTrue(bytes(uri).length > 0, "URI should be set");
        
        // Should revert when called by non-factory
        vm.prank(user1);
        vm.expectRevert(PositionNFT.Unauthorized.selector);
        nft.setCID(marketId2, cid1);
    }
    
    function test_batchOperations_work() public {
        // Authorize market1
        vm.prank(factory);
        nft.authorizeMarket(market1, marketId1);
        
        // Create multiple token IDs
        uint256[] memory tokenIds = new uint256[](3);
        uint256[] memory amounts = new uint256[](3);
        
        for (uint256 i = 0; i < 3; i++) {
            tokenIds[i] = nft.encodeTokenId(marketId1, i);
            amounts[i] = 100e18 * (i + 1);
            
            vm.prank(market1);
            nft.mint(user1, tokenIds[i], amounts[i]);
        }
        
        // Batch transfer
        vm.prank(user1);
        nft.safeBatchTransferFrom(user1, user2, tokenIds, amounts, "");
        
        // Verify balances
        for (uint256 i = 0; i < 3; i++) {
            assertEq(nft.balanceOf(user1, tokenIds[i]), 0, "User1 should have 0");
            assertEq(nft.balanceOf(user2, tokenIds[i]), amounts[i], "User2 should have transferred amount");
        }
    }
}
