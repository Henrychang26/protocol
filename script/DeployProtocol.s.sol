//SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import {Script} from "forge-std/Script.sol";
import {Protocol} from "../src/Protocol.sol";
import {HelperConfig} from "./HelperConfig.s.sol";

contract DeployProtocol is Script {
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function run() public returns (Protocol, HelperConfig) {
        HelperConfig helperConfig = new HelperConfig();

        (address wethUsdPriceFeed, address wbtcUsdPriceFeed, address weth, address wbtc, uint256 deployerKey) =
            helperConfig.activeNetworkConfig();
        tokenAddresses = [weth, wbtc];
        priceFeedAddresses = [wethUsdPriceFeed, wbtcUsdPriceFeed];

        vm.startBroadcast(deployerKey);

        Protocol protocol = new Protocol(tokenAddresses, priceFeedAddresses);

        vm.stopBroadcast();
        return (protocol, helperConfig);
    }
}
