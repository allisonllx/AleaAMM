// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {AMMFactory} from "../src/AMMFactory.sol";
import {AMMRouter} from "../src/AMMRouter.sol";
import {ConstantProductAMM} from "../src/ConstantProductAMM.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

/**
 * @notice Deploys the full Factory-Router stack with three demo tokens and two pools.
 * @dev The two pools (GLD/SLV and SLV/USDC) share SLV as a bridge token, so the router can
 *      immediately route GLD -> SLV -> USDC even though no direct GLD/USDC pool exists.
 */
contract DeployFactory is Script {
    uint256 constant SEED_LIQUIDITY = 100_000 * 10 ** 18;

    function run()
        external
        returns (AMMFactory factory, AMMRouter router, MockERC20 gold, MockERC20 silver, MockERC20 usdc)
    {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Core infrastructure
        factory = new AMMFactory();
        router = new AMMRouter(address(factory));

        // 2. Demo tokens
        gold = new MockERC20("Gold Coin", "GLD");
        silver = new MockERC20("Silver Coin", "SLV");
        usdc = new MockERC20("USD Coin", "USDC");

        // 3. Create the two bridged pools
        address goldSilver = factory.createPair(address(gold), address(silver));
        address silverUsdc = factory.createPair(address(silver), address(usdc));

        // 4. Seed both pools with balanced liquidity so swaps work out of the box
        gold.mint(deployer, SEED_LIQUIDITY);
        silver.mint(deployer, SEED_LIQUIDITY * 2); // silver sits in both pools
        usdc.mint(deployer, SEED_LIQUIDITY);

        _seed(goldSilver, gold, silver);
        _seed(silverUsdc, silver, usdc);

        vm.stopBroadcast();
    }

    /// @dev Approves and deposits an equal amount of both tokens into the given pool.
    function _seed(address pair, MockERC20 x, MockERC20 y) internal {
        x.approve(pair, SEED_LIQUIDITY);
        y.approve(pair, SEED_LIQUIDITY);
        ConstantProductAMM(pair).addLiquidity(SEED_LIQUIDITY, SEED_LIQUIDITY);
    }
}
