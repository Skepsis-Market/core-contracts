// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {PositionNFT} from "../src/PositionNFT.sol";
import {MarketFactory} from "../src/MarketFactory.sol";
import {Vault} from "../src/Vault.sol";
import {LMSRMarket} from "../src/LMSRMarket.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";

/// @notice Minimal deploy for lifecycle integration tests.
///         Writes addresses to stdout as JSON for the TS test to parse.
contract DeployLifecycleScript is Script {
    function run() public {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        vm.startBroadcast(pk);

        // 1. MockUSDC
        MockUSDC usdc = new MockUSDC();

        // 2. LMSRMarket impl
        uint256[] memory implRanges = new uint256[](2);
        implRanges[0] = 0;
        implRanges[1] = 1;
        LMSRMarket.MarketMetadata memory implMeta;
        address lmsrImpl = address(new LMSRMarket(
            0, address(0), address(0), address(usdc), address(0),
            1, 1, implRanges, 0, 0, implMeta, address(0xFEE)
        ));

        // 3. PositionNFT (needs predicted factory address)
        address predictedFactory = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 1);
        PositionNFT positionNFT = new PositionNFT(predictedFactory);

        // 4. MarketFactory
        MarketFactory factory = new MarketFactory(
            lmsrImpl, address(usdc), address(positionNFT),
            100_000000, 100, 200, 2000, address(0xFEE)
        );
        require(address(factory) == predictedFactory, "Factory address mismatch");

        // 5. Vault
        Vault vault = new Vault(address(usdc), "Skepsis Vault", "sVLT", deployer);
        vault.setFactory(address(factory));
        factory.setVault(address(vault));

        // 6. Seed vault
        usdc.mint(deployer, 500_000_000000);
        usdc.approve(address(vault), 500_000_000000);
        vault.deposit(200_000_000000, deployer);

        // 7. Creator allowance
        factory.setCreatorAllowance(deployer, 10);

        vm.stopBroadcast();

        // Output JSON for TS to parse
        console.log(string.concat(
            '{"usdc":"', vm.toString(address(usdc)),
            '","lmsrImpl":"', vm.toString(lmsrImpl),
            '","positionNFT":"', vm.toString(address(positionNFT)),
            '","factory":"', vm.toString(address(factory)),
            '","vault":"', vm.toString(address(vault)), '"}'
        ));
    }
}
