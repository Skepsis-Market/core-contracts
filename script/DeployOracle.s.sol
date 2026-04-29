// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ChainlinkPriceOracleResolver} from "../src/ChainlinkPriceOracleResolver.sol";

/// @notice Deploys the trustless Chainlink price-oracle resolver.
///
/// HOW TO USE
/// ═══════════════════════════════════════════════════════════════════
///  1. Deploy this contract once per network.
///  2. Create markets with metadata.resolver = <deployed oracle address>.
///  3. From the oracle owner, call registerMarket(market, feed, divisor, staleness).
///  4. Once scheduledResolutionTime passes, anyone may call resolve(market).
///
/// RUN (Arbitrum Sepolia)
/// ═══════════════════════════════════════════════════════════════════
//   forge script script/DeployOracle.s.sol:DeployOracleScript \
//     --rpc-url $ARB_SEPOLIA_RPC_URL \
//     --broadcast --verify \
//     --chain-id 421614
contract DeployOracleScript is Script {
    /// @dev Initial registrar allowance granted to the deployer. The deployer
    ///      can grant additional allowance to teammates with setRegistrarAllowance.
    uint256 constant INITIAL_DEPLOYER_SLOTS = 1000;

    function run() external returns (address oracle) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);

        ChainlinkPriceOracleResolver resolver =
            new ChainlinkPriceOracleResolver(deployer);
        // Seed deployer with registerMarket allowance so the keeper / scheduler
        // (signing as the deployer) can register markets without an extra setup tx.
        resolver.setRegistrarAllowance(deployer, INITIAL_DEPLOYER_SLOTS);

        vm.stopBroadcast();

        oracle = address(resolver);

        console.log("=============================================");
        console.log(" ChainlinkPriceOracleResolver deployed");
        console.log("=============================================");
        console.log(" Address:        ", oracle);
        console.log(" Owner:          ", deployer);
        console.log(" Deployer slots: ", INITIAL_DEPLOYER_SLOTS);
        console.log("---------------------------------------------");
        console.log(" Save to .env:");
        console.log(" CHAINLINK_ORACLE_RESOLVER_ADDRESS=", oracle);
        console.log("---------------------------------------------");
        console.log(" To grant a teammate (e.g. backend / co-dev):");
        console.log("  cast send <oracle> 'setRegistrarAllowance(address,uint256)' \\");
        console.log("    <teammate-address> 1000 --rpc-url <RPC> --private-key <owner-key>");
        console.log("=============================================");
    }
}
