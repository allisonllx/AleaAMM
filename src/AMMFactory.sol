// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ConstantProductAMM} from "./ConstantProductAMM.sol";

/**
 * @notice Central registry that deploys and tracks individual ConstantProductAMM pair pools.
 * @dev Tokens are stored in canonical order (token0 < token1) so each unordered pair maps to
 *      exactly one pool, regardless of the order a caller supplies the two token addresses.
 */
contract AMMFactory {
    // getPair[tokenA][tokenB] resolves to the pool address; populated in both directions.
    mapping(address => mapping(address => address)) public getPair;

    // Flat list of every pool ever created, for off-chain enumeration.
    address[] public allPairs;

    event PairCreated(address indexed token0, address indexed token1, address pair, uint256 pairIndex);

    /**
     * @notice Deploys a brand-new pool contract for the (tokenA, tokenB) trading pair.
     * @param tokenA One side of the pair (order does not matter).
     * @param tokenB The other side of the pair.
     * @return pair The address of the freshly deployed ConstantProductAMM pool.
     */
    function createPair(address tokenA, address tokenB) external returns (address pair) {
        require(tokenA != tokenB, "AMM: IDENTICAL_ADDRESSES");

        // Canonical ordering guarantees a single deterministic slot per unordered pair.
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), "AMM: ZERO_ADDRESS");
        require(getPair[token0][token1] == address(0), "AMM: PAIR_EXISTS");

        // Conjure a dedicated pool contract out of thin air for this pair.
        ConstantProductAMM newPair = new ConstantProductAMM(token0, token1);
        pair = address(newPair);

        // Register in both directions so lookups succeed regardless of argument order.
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair;
        allPairs.push(pair);

        emit PairCreated(token0, token1, pair, allPairs.length - 1);
    }

    /**
     * @notice Total number of pools deployed by this factory.
     */
    function allPairsLength() external view returns (uint256) {
        return allPairs.length;
    }
}
