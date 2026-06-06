// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {ConstantProductAMM} from "../src/ConstantProductAMM.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {AMMMath} from "../src/libraries/AMMMath.sol";

contract ConstantProductAMMTest is Test {
    ConstantProductAMM public amm;
    MockERC20 public token0;
    MockERC20 public token1;

    // Set up dummy tester addresses
    address public liquidityProvider = address(0x1);
    address public trader = address(0x2);

    function setUp() public {
        // 1. Deploy our mock assets
        token0 = new MockERC20("USD Coin", "USDC");
        token1 = new MockERC20("Wrapped Ether", "WETH");

        // 2. Deploy our AMM trading pair pool
        amm = new ConstantProductAMM(address(token0), address(token1));

        // 3. Seed our test accounts with mock balances (10,000 tokens each)
        token0.mint(liquidityProvider, 100000 * 10 ** 18);
        token1.mint(liquidityProvider, 100000 * 10 ** 18);

        token0.mint(trader, 5000 * 10 ** 18);
        token1.mint(trader, 5000 * 10 ** 18);
    }

    function test_AddLiquidity() public {
        // Act as the Liquidity Provider
        vm.startPrank(liquidityProvider);

        // Approve the AMM to spend our tokens
        token0.approve(address(amm), 1000 * 10 ** 18);
        token1.approve(address(amm), 1000 * 10 ** 18);

        // Deposit a 1:1 ratio into the empty pool
        uint256 lpShares = amm.addLiquidity(1000 * 10 ** 18, 1000 * 10 ** 18);

        vm.stopPrank();

        // Verify the AMM vault storage metrics updated correctly
        assertEq(amm.reserve0(), 1000 * 10 ** 18);
        assertEq(amm.reserve1(), 1000 * 10 ** 18);
        assertEq(amm.balanceOf(liquidityProvider), lpShares);

        console2.log("LP Shares Minted:", lpShares);
    }

    function test_SwapExecutionAndFees() public {
        // Step A: Establish baseline liquidity first (10 ETH : 20,000 USDC scenario)
        vm.startPrank(liquidityProvider);
        token0.approve(address(amm), 20000 * 10 ** 18);
        token1.approve(address(amm), 10 * 10 ** 18);
        amm.addLiquidity(20000 * 10 ** 18, 10 * 10 ** 18);
        vm.stopPrank();

        // Step B: Act as a trader swapping 1,000 USDC into the pool to get WETH
        vm.startPrank(trader);
        token0.approve(address(amm), 1000 * 10 ** 18);

        uint256 expectedOut = AMMMath.getAmountOut(1000 * 10 ** 18, 20000 * 10 ** 18, 10 * 10 ** 18);
        uint256 actualOut = amm.swap(address(token0), 1000 * 10 ** 18, expectedOut, block.timestamp);
        vm.stopPrank();

        // Assert the pricing calculation was perfectly executed
        assertEq(actualOut, expectedOut);
        assertTrue(actualOut > 0, "Trader should receive tokens");

        console2.log("WETH Received by Trader:", actualOut / 10 ** 15, "x 10^-3");
    }

    function test_SwapRevertsOnSlippage() public {
        // Step A: Establish the same baseline liquidity (20,000 USDC : 10 WETH)
        vm.startPrank(liquidityProvider);
        token0.approve(address(amm), 20000 * 10 ** 18);
        token1.approve(address(amm), 10 * 10 ** 18);
        amm.addLiquidity(20000 * 10 ** 18, 10 * 10 ** 18);
        vm.stopPrank();

        // Step B: Trader demands MORE output than the curve can possibly deliver
        vm.startPrank(trader);
        token0.approve(address(amm), 1000 * 10 ** 18);

        uint256 fairOut = AMMMath.getAmountOut(1000 * 10 ** 18, 20000 * 10 ** 18, 10 * 10 ** 18);

        // Asking for 1 wei more than the fair quote must trip the slippage guardrail
        vm.expectRevert("AMM: INSUFFICIENT_OUTPUT_AMOUNT_SLIPPAGE");
        amm.swap(address(token0), 1000 * 10 ** 18, fairOut + 1, block.timestamp);
        vm.stopPrank();
    }

    function test_SwapRevertsOnExpiredDeadline() public {
        // Step A: Establish baseline liquidity
        vm.startPrank(liquidityProvider);
        token0.approve(address(amm), 20000 * 10 ** 18);
        token1.approve(address(amm), 10 * 10 ** 18);
        amm.addLiquidity(20000 * 10 ** 18, 10 * 10 ** 18);
        vm.stopPrank();

        // Move the clock forward so any past deadline is now stale
        vm.warp(1000);

        vm.startPrank(trader);
        token0.approve(address(amm), 1000 * 10 ** 18);

        // A deadline one second in the past must be rejected before execution
        vm.expectRevert("AMM: EXPIRED");
        amm.swap(address(token0), 1000 * 10 ** 18, 0, block.timestamp - 1);
        vm.stopPrank();
    }

    function test_RemoveLiquidity() public {
        // Step A: Deposit liquidity
        vm.startPrank(liquidityProvider);
        token0.approve(address(amm), 500 * 10 ** 18);
        token1.approve(address(amm), 500 * 10 ** 18);
        uint256 sharesMinted = amm.addLiquidity(500 * 10 ** 18, 500 * 10 ** 18);

        // Step B: Immediately turn around and redeem all shares
        (uint256 redeemed0, uint256 redeemed1) = amm.removeLiquidity(sharesMinted);
        vm.stopPrank();

        // Since no trades occurred, they should get their exact assets back
        assertEq(redeemed0, 500 * 10 ** 18);
        assertEq(redeemed1, 500 * 10 ** 18);
        assertEq(amm.balanceOf(liquidityProvider), 0);
    }

    /**
     * @notice PROPERTY-BASED FUZZ TEST
     * Foundry will run this 256 times with entirely random input amounts.
     * It proves mathematically that our invariant 'k' NEVER shrinks during a swap.
     */
    function testFuzz_SwapMathInvariance(uint256 swapAmount) public {
        // Bound our fuzz inputs to reasonable token amounts (between 1 wei and 1,000 tokens)
        // to prevent extreme overflow limits that break mock setups.
        swapAmount = bound(swapAmount, 1, 1000 * 10 ** 18);

        // Establish initial pool reserves
        vm.startPrank(liquidityProvider);
        token0.approve(address(amm), 2000 * 10 ** 18);
        token1.approve(address(amm), 2000 * 10 ** 18);
        amm.addLiquidity(2000 * 10 ** 18, 2000 * 10 ** 18);
        vm.stopPrank();

        uint256 kBefore = amm.reserve0() * amm.reserve1();

        // Execute fuzz swap
        vm.startPrank(trader);
        token0.mint(trader, swapAmount); // Ensure trader has enough funds
        token0.approve(address(amm), swapAmount);
        amm.swap(address(token0), swapAmount, 0, block.timestamp); // No slippage floor: accept any output
        vm.stopPrank();

        uint256 kAfter = amm.reserve0() * amm.reserve1();

        // The Golden Core AMM Invariant Rule: kAfter must ALWAYS be greater than or equal to kBefore
        assertTrue(kAfter >= kBefore, "Constant product invariant violation!");
    }
}
