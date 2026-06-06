// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ConstantProductAMM} from "./ConstantProductAMM.sol";
import {AMMFactory} from "./AMMFactory.sol";
import {AMMMath} from "./libraries/AMMMath.sol";

/**
 * @notice User-facing entry point that routes trades across one or more factory pools.
 * @dev If a direct pool for the desired pair does not exist, callers can supply a multi-hop
 *      `path` (e.g. [SLV, GLD, USDC]) and the router executes each leg atomically in one tx.
 */
contract AMMRouter {
    AMMFactory public immutable factory;

    constructor(address _factory) {
        require(_factory != address(0), "AMM: ZERO_FACTORY");
        factory = AMMFactory(_factory);
    }

    /**
     * @notice Quotes the cascading output amounts for a swap along `path`, leg by leg.
     * @param amountIn The exact input amount of the first token in the path.
     * @param path Ordered list of token addresses; each adjacent pair must have a pool.
     * @return amounts Array where amounts[0] == amountIn and amounts[i] is the output of leg i-1.
     */
    function getAmountsOut(uint256 amountIn, address[] calldata path)
        public
        view
        returns (uint256[] memory amounts)
    {
        require(path.length >= 2, "AMM: INVALID_PATH");

        amounts = new uint256[](path.length);
        amounts[0] = amountIn;

        for (uint256 i; i < path.length - 1; i++) {
            ConstantProductAMM pair = _pairFor(path[i], path[i + 1]);
            (uint256 reserveIn, uint256 reserveOut) = _getReserves(pair, path[i]);
            amounts[i + 1] = AMMMath.getAmountOut(amounts[i], reserveIn, reserveOut);
        }
    }

    /**
     * @notice Swaps an exact amount of the first token in `path` for the last, hopping pools as needed.
     * @param amountIn The exact input amount of path[0] to spend.
     * @param amountOutMin The minimum acceptable amount of the final token (slippage guardrail).
     * @param path Ordered token route; adjacent entries must each have a registered pool.
     * @param to Recipient of the final output tokens.
     * @param deadline Unix timestamp after which the whole route is rejected (staleness guardrail).
     * @return amounts The realized amount at each hop (amounts[0] == amountIn).
     */
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts) {
        require(block.timestamp <= deadline, "AMM: EXPIRED");

        amounts = getAmountsOut(amountIn, path);
        require(amounts[amounts.length - 1] >= amountOutMin, "AMM: INSUFFICIENT_OUTPUT_AMOUNT");

        // Pull the trader's starting funds into the router.
        IERC20(path[0]).transferFrom(msg.sender, address(this), amountIn);

        // Walk each leg: approve the pool, swap, and carry the output into the next hop.
        for (uint256 i; i < path.length - 1; i++) {
            ConstantProductAMM pair = _pairFor(path[i], path[i + 1]);
            IERC20(path[i]).approve(address(pair), amounts[i]);
            // Each leg's pre-quoted output doubles as its own minimum; the loop is atomic.
            pair.swap(path[i], amounts[i], amounts[i + 1], deadline);
        }

        // Forward the final proceeds to the recipient.
        IERC20(path[path.length - 1]).transfer(to, amounts[amounts.length - 1]);
    }

    /**
     * @dev Resolves the pool for an adjacent token pair, reverting if none is registered.
     */
    function _pairFor(address tokenIn, address tokenOut) internal view returns (ConstantProductAMM pair) {
        address pairAddr = factory.getPair(tokenIn, tokenOut);
        require(pairAddr != address(0), "AMM: PAIR_NOT_FOUND");
        pair = ConstantProductAMM(pairAddr);
    }

    /**
     * @dev Orients a pool's reserves so they line up with the (in, out) direction of the swap.
     */
    function _getReserves(ConstantProductAMM pair, address tokenIn)
        internal
        view
        returns (uint256 reserveIn, uint256 reserveOut)
    {
        if (tokenIn == address(pair.token0())) {
            (reserveIn, reserveOut) = (pair.reserve0(), pair.reserve1());
        } else {
            (reserveIn, reserveOut) = (pair.reserve1(), pair.reserve0());
        }
    }
}
