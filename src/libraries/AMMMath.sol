// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

library AMMMath {
    /**
     * @notice Calculates the output amount of tokens received given an input amount.
     * @param amountIn The amount of incoming tokens being swapped into the pool.
     * @param reserveIn The current pool reserve balance of the incoming token.
     * @param reserveOut The current pool reserve balance of the outgoing token.
     */
    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256 amountOut) {
        // Absolute requirement: The pool must have active liquidity
        require(reserveIn > 0 && reserveOut > 0, "AMM: INSUFFICIENT_LIQUIDITY");

        // 1. Apply the 0.3% trading fee to the incoming amount.
        // We multiply by 997 instead of multiplying by 0.997 (floats aren't allowed!).
        uint256 amountInWithFee = amountIn * 997;

        // 2. Multiply before dividing! (Numerator = y * delta_x_with_fee)
        uint256 numerator = amountInWithFee * reserveOut;

        // 3. Adjust the denominator to account for the scaled input. (Denominator = x * 1000 + delta_x_with_fee)
        uint256 denominator = (reserveIn * 1000) + amountInWithFee;

        // 4. Perform the integer division (Solidity automatically truncates any fraction left over)
        amountOut = numerator / denominator;
    }
}