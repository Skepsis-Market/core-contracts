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
    function run() external returns (address oracle) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);

        ChainlinkPriceOracleResolver resolver =
            new ChainlinkPriceOracleResolver(deployer);

        vm.stopBroadcast();

        oracle = address(resolver);

        console.log("=============================================");
        console.log(" ChainlinkPriceOracleResolver deployed");
        console.log("=============================================");
        console.log(" Address:", oracle);
        console.log(" Owner:  ", deployer);
        console.log("---------------------------------------------");
        console.log(" Save to .env:");
        console.log(" CHAINLINK_ORACLE_RESOLVER_ADDRESS=", oracle);
        console.log("=============================================");
    }
}
