// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";

contract MockUSDCTest is Test {
    MockUSDC usdc;
    address alice = address(0x1);
    address bob = address(0x2);

    function setUp() public {
        usdc = new MockUSDC();
    }

    function test_decimals() public view {
        assertEq(usdc.decimals(), 6);
    }

    function test_mint() public {
        usdc.mint(alice, 100_000000);
        assertEq(usdc.balanceOf(alice), 100_000000);
    }

    function test_burn() public {
        usdc.mint(alice, 100_000000);
        usdc.burn(alice, 50_000000);
        assertEq(usdc.balanceOf(alice), 50_000000);
    }

    function test_transfer() public {
        usdc.mint(alice, 100_000000);
        vm.prank(alice);
        usdc.transfer(bob, 30_000000);
        assertEq(usdc.balanceOf(alice), 70_000000);
        assertEq(usdc.balanceOf(bob), 30_000000);
    }

    function test_permit() public {
        uint256 privateKey = 0xA11CE;
        address owner = vm.addr(privateKey);
        
        usdc.mint(owner, 100_000000);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            privateKey,
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    usdc.DOMAIN_SEPARATOR(),
                    keccak256(
                        abi.encode(
                            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                            owner,
                            alice,
                            100_000000,
                            0,
                            block.timestamp
                        )
                    )
                )
            )
        );

        usdc.permit(owner, alice, 100_000000, block.timestamp, v, r, s);
        assertEq(usdc.allowance(owner, alice), 100_000000);
    }
}
