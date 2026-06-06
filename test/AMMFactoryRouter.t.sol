// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {ConstantProductAMM} from "../src/ConstantProductAMM.sol";
import {AMMFactory} from "../src/AMMFactory.sol";
import {AMMRouter} from "../src/AMMRouter.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

contract AMMFactoryRouterTest is Test {
    AMMFactory public factory;
    AMMRouter public router;

    MockERC20 public tokenA;
    MockERC20 public tokenB;
    MockERC20 public tokenC;

    address public liquidityProvider = address(0x1);
    address public trader = address(0x2);

    function setUp() public {
        factory = new AMMFactory();
        router = new AMMRouter(address(factory));

        tokenA = new MockERC20("Token A", "AAA");
        tokenB = new MockERC20("Token B", "BBB");
        tokenC = new MockERC20("Token C", "CCC");

        // Two pools sharing tokenB form the bridge for A -> B -> C routing.
        factory.createPair(address(tokenA), address(tokenB));
        factory.createPair(address(tokenB), address(tokenC));

        // Seed both pools with deep, balanced liquidity (10,000 : 10,000 each).
        _seedLiquidity(tokenA, tokenB, 10000 * 10 ** 18);
        _seedLiquidity(tokenB, tokenC, 10000 * 10 ** 18);

        // Fund the trader with the input asset.
        tokenA.mint(trader, 5000 * 10 ** 18);
    }

    /// @dev Adds equal amounts of two tokens to their pool (order-agnostic since amounts match).
    function _seedLiquidity(MockERC20 x, MockERC20 y, uint256 amount) internal {
        address pair = factory.getPair(address(x), address(y));

        x.mint(liquidityProvider, amount);
        y.mint(liquidityProvider, amount);

        vm.startPrank(liquidityProvider);
        x.approve(pair, amount);
        y.approve(pair, amount);
        ConstantProductAMM(pair).addLiquidity(amount, amount);
        vm.stopPrank();
    }

    function test_FactoryCreatesAndRegistersPair() public view {
        address pairAB = factory.getPair(address(tokenA), address(tokenB));

        assertTrue(pairAB != address(0), "pair should exist");
        // Lookup must succeed in both directions.
        assertEq(factory.getPair(address(tokenB), address(tokenA)), pairAB);
        assertEq(factory.allPairsLength(), 2);
    }

    function test_FactoryRevertsOnDuplicatePair() public {
        vm.expectRevert("AMM: PAIR_EXISTS");
        factory.createPair(address(tokenB), address(tokenA));
    }

    function test_FactoryRevertsOnIdenticalTokens() public {
        vm.expectRevert("AMM: IDENTICAL_ADDRESSES");
        factory.createPair(address(tokenA), address(tokenA));
    }

    function test_RouterDirectSwap() public {
        address[] memory path = new address[](2);
        path[0] = address(tokenA);
        path[1] = address(tokenB);

        uint256 amountIn = 1000 * 10 ** 18;
        uint256[] memory quoted = router.getAmountsOut(amountIn, path);

        uint256 beforeB = tokenB.balanceOf(trader);

        vm.startPrank(trader);
        tokenA.approve(address(router), amountIn);
        uint256[] memory amounts = router.swapExactTokensForTokens(amountIn, quoted[1], path, trader, block.timestamp);
        vm.stopPrank();

        assertEq(amounts[1], quoted[1], "realized output should match quote");
        assertEq(tokenB.balanceOf(trader) - beforeB, quoted[1], "trader receives quoted tokenB");
    }

    function test_RouterMultiHopSwap() public {
        address[] memory path = new address[](3);
        path[0] = address(tokenA);
        path[1] = address(tokenB);
        path[2] = address(tokenC);

        uint256 amountIn = 1000 * 10 ** 18;
        uint256[] memory quoted = router.getAmountsOut(amountIn, path);

        uint256 beforeA = tokenA.balanceOf(trader);
        uint256 beforeC = tokenC.balanceOf(trader);

        vm.startPrank(trader);
        tokenA.approve(address(router), amountIn);
        uint256[] memory amounts = router.swapExactTokensForTokens(amountIn, quoted[2], path, trader, block.timestamp);
        vm.stopPrank();

        // Final hop output must match the quote and reach the trader.
        assertEq(amounts[2], quoted[2], "realized output should match quote");
        assertEq(beforeA - tokenA.balanceOf(trader), amountIn, "exact input spent");
        assertEq(tokenC.balanceOf(trader) - beforeC, quoted[2], "trader receives final tokenC");
        // Two 0.3% fee legs mean the trader nets less than the input.
        assertTrue(amounts[2] > 0 && amounts[2] < amountIn, "double-fee erosion");

        console2.log("A in:", amountIn / 10 ** 18);
        console2.log("C out:", amounts[2] / 10 ** 18);
    }

    function test_RouterRevertsOnSlippage() public {
        address[] memory path = new address[](3);
        path[0] = address(tokenA);
        path[1] = address(tokenB);
        path[2] = address(tokenC);

        uint256 amountIn = 1000 * 10 ** 18;
        uint256[] memory quoted = router.getAmountsOut(amountIn, path);

        vm.startPrank(trader);
        tokenA.approve(address(router), amountIn);
        // Demand 1 wei more than the route can deliver.
        vm.expectRevert("AMM: INSUFFICIENT_OUTPUT_AMOUNT");
        router.swapExactTokensForTokens(amountIn, quoted[2] + 1, path, trader, block.timestamp);
        vm.stopPrank();
    }

    function test_RouterRevertsOnExpiredDeadline() public {
        address[] memory path = new address[](3);
        path[0] = address(tokenA);
        path[1] = address(tokenB);
        path[2] = address(tokenC);

        uint256 amountIn = 1000 * 10 ** 18;

        vm.warp(1000);

        vm.startPrank(trader);
        tokenA.approve(address(router), amountIn);
        vm.expectRevert("AMM: EXPIRED");
        router.swapExactTokensForTokens(amountIn, 0, path, trader, block.timestamp - 1);
        vm.stopPrank();
    }

    function test_RouterRevertsOnMissingPair() public {
        // tokenA <-> tokenC pool was never created.
        address[] memory path = new address[](2);
        path[0] = address(tokenA);
        path[1] = address(tokenC);

        vm.startPrank(trader);
        tokenA.approve(address(router), 1000 * 10 ** 18);
        vm.expectRevert("AMM: PAIR_NOT_FOUND");
        router.swapExactTokensForTokens(1000 * 10 ** 18, 0, path, trader, block.timestamp);
        vm.stopPrank();
    }
}
