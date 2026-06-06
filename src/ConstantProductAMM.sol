// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AMMMath} from "./libraries/AMMMath.sol";

contract ConstantProductAMM is ERC20 {
    // State variables tracking the two ERC-20 tokens making up this trading pair
    IERC20 public immutable token0;
    IERC20 public immutable token1;

    // Internal tracking of pool reserves (scaled to 18 decimals by the respective tokens)
    uint256 public reserve0;
    uint256 public reserve1;

    // Emitted events for off-chain frontend listening (Viem/Wagmi hooks)
    event LiquidityAdded(address indexed provider, uint256 amount0, uint256 amount1, uint256 lpSharesMinted);
    event LiquidityRemoved(address indexed provider, uint256 amount0, uint256 amount1, uint256 lpSharesBurned);
    event Swap(address indexed trader, address tokenIn, uint256 amountIn, uint256 amountOut);

    /**
     * @dev Initialize the trading pair pool.
     * The contract name "Alea LP Token" represents the share receipts given to providers. (LP = Liquidity Provider)
     */
    constructor(address _token0, address _token1) ERC20("Alea Liquidity Provider Token", "ALEA-LP") {
        require(_token0 != address(0) && _token1 != address(0), "AMM: INVALID_ADDRESS");
        token0 = IERC20(_token0);
        token1 = IERC20(_token1);
    }

    /**
     * @notice Allows a user to deposit both assets to earn trading fees.
     * @dev In a production router, you ensure deposits match the exact current pool ratio.
     */
    function addLiquidity(uint256 amount0Desired, uint256 amount1Desired) external returns (uint256 shares) {
        // 1. Pull the assets into this contract storage vault
        token0.transferFrom(msg.sender, address(this), amount0Desired);
        token1.transferFrom(msg.sender, address(this), amount1Desired);

        // 2. Compute how many LP shares to mint.
        // For a simple implementation, if it's the first deposit, we mint shares equal to the geometric mean.
        uint256 totalPoolShares = totalSupply();
        if (totalPoolShares == 0) {
            // Primitive initialization calculation
            shares = amount0Desired + amount1Desired;
        } else {
            // Proportional share assignment based on the constant product ratio
            uint256 share0 = (amount0Desired * totalPoolShares) / reserve0;
            uint256 share1 = (amount1Desired * totalPoolShares) / reserve1;
            shares = share0 < share1 ? share0 : share1; // Give them the conservative minimum
        }

        require(shares > 0, "AMM: INSUFFICIENT_SHARES_MINTED");

        // 3. Mint the custom ERC-20 LP shares *of this contract* to the liquidity provider
        _mint(msg.sender, shares);

        // 4. Update the state machine reserves
        reserve0 = token0.balanceOf(address(this));
        reserve1 = token1.balanceOf(address(this));

        emit LiquidityAdded(msg.sender, amount0Desired, amount1Desired, shares);
    }

    /**
     * @notice Allows a liquidity provider to burn their LP shares to reclaim their underlying Token0 and Token1.
     * @param lpSharesBurned The quantity of Alea-LP tokens the user wants to trade back in.
     * @return amount0 The exact amount of Token0 returned to the user's wallet.
     * @return amount1 The exact amount of Token1 returned to the user's wallet.
     */
    function removeLiquidity(uint256 lpSharesBurned) external returns (uint256 amount0, uint256 amount1) {
        require(lpSharesBurned > 0, "AMM: INSUFFICIENT_SHARES_BURNED");
        require(balanceOf(msg.sender) >= lpSharesBurned, "AMM: EXCEEDS_LP_BALANCE");

        // 1. Fetch the total supply of LP shares currently in existence
        uint256 totalPoolShares = totalSupply();

        // 2. Proportional payout math using our active reserves
        // Remember: Multiply before dividing to prevent fractional truncation bugs!
        amount0 = (lpSharesBurned * reserve0) / totalPoolShares;
        amount1 = (lpSharesBurned * reserve1) / totalPoolShares;

        require(amount0 > 0 && amount1 > 0, "AMM: INSUFFICIENT_LIQUIDITY_BURNED");

        // 3. Destroy the user's LP shares so they can never use them again
        _burn(msg.sender, lpSharesBurned);

        // 4. Send the underlying assets directly back to the human wallet (msg.sender)
        token0.transfer(msg.sender, amount0);
        token1.transfer(msg.sender, amount1);

        // 5. Re-synchronize our local state machine records with the new realities of the contract balances
        reserve0 = token0.balanceOf(address(this));
        reserve1 = token1.balanceOf(address(this));

        emit LiquidityRemoved(msg.sender, amount0, amount1, lpSharesBurned);
    }

    /**
     * @notice Executes an atomic asset swap with built-in queue-cutting (slippage) protection.
     * @param tokenIn The address of the asset being deposited.
     * @param amountIn The exact quantity of tokens the trader is committing.
     * @param minAmountOut The minimum acceptable tokens the trader must receive (slippage guardrail).
     * @param deadline Unix timestamp after which the swap is rejected (staleness guardrail).
     * @return amountOut The exact quantity of opposing tokens sent to the trader's wallet.
     */
    function swap(address tokenIn, uint256 amountIn, uint256 minAmountOut, uint256 deadline)
        external
        returns (uint256 amountOut)
    {
        require(block.timestamp <= deadline, "AMM: EXPIRED");
        require(amountIn > 0, "AMM: INSUFFICIENT_INPUT_AMOUNT");
        require(tokenIn == address(token0) || tokenIn == address(token1), "AMM: INVALID_TOKEN");

        bool isToken0 = tokenIn == address(token0);
        (IERC20 tIn, IERC20 tOut, uint256 rIn, uint256 rOut) =
            isToken0 ? (token0, token1, reserve0, reserve1) : (token1, token0, reserve1, reserve0);

        // 1. Pull the trader's incoming tokens
        tIn.transferFrom(msg.sender, address(this), amountIn);

        // 2. Execute our safe fixed-point math calculation formula
        amountOut = AMMMath.getAmountOut(amountIn, rIn, rOut);

        // 3. Slippage guardrail: if the price degraded past the trader's tolerance, revert the whole trade
        require(amountOut >= minAmountOut, "AMM: INSUFFICIENT_OUTPUT_AMOUNT_SLIPPAGE");

        // 4. Disburse the output tokens back to the user
        tOut.transfer(msg.sender, amountOut);

        // 5. Re-sync internal records with the actual token balances remaining inside the vault
        reserve0 = token0.balanceOf(address(this));
        reserve1 = token1.balanceOf(address(this));

        emit Swap(msg.sender, tokenIn, amountIn, amountOut);
    }
}
