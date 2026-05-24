// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {ConstantProductAMM} from "../src/ConstantProductAMM.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

contract DeployAMM is Script {
    function run() external returns (MockERC20 token0, MockERC20 token1, ConstantProductAMM amm) {
        // 1. Read your deployment private key from local terminal session
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        // 2. Everything inside the broadcast block is sent to the active network (Anvil)
        vm.startBroadcast(deployerPrivateKey);

        // Deploy the test tokens
        token0 = new MockERC20("Gold Coin", "GLD");
        token1 = new MockERC20("Silver Coin", "SLV");

        // Deploy the AMM pair pool managing them
        amm = new ConstantProductAMM(address(token0), address(token1));

        vm.stopBroadcast();
    }
}