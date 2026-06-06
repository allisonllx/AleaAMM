# Constant Product Automated Market Maker (AMM)

A minimal, fully-tested Uniswap V2-style constant product AMM built with [Foundry](https://book.getfoundry.sh/) and [OpenZeppelin](https://github.com/OpenZeppelin/openzeppelin-contracts). A single pool contract holds two ERC-20 tokens and prices swaps against the invariant `x * y = k`, while liquidity providers receive ERC-20 LP shares representing their stake in the pool.

## How It Works

The pool tracks two tokens (`token0`, `token1`) and their accounted `reserve0` / `reserve1`. Pricing follows the constant product formula with a 0.3% trading fee applied to the input amount. The pool contract is itself an ERC-20 (`Alea Liquidity Provider Token`, symbol `ALEA-LP`); LP shares are minted on deposit and burned on withdrawal.

Reserves are tracked explicitly (rather than read live from `balanceOf`) and re-synced at the end of each state-changing call, so direct token transfers into the contract cannot skew the price curve mid-transaction.

For a deeper, plain-language walkthrough of these concepts — what an AMM is, the two meanings of "LP", the deposit/withdraw/swap flows, the 0.3% fee, and how the invariant is tested — see [`docs/CONCEPTS.md`](./docs/CONCEPTS.md).

## Project Structure

```
src/
  ConstantProductAMM.sol     # Core pool: addLiquidity, removeLiquidity, swap
  libraries/AMMMath.sol      # Pure pricing math (getAmountOut) with 0.3% fee
  mocks/MockERC20.sol        # Freely-mintable ERC-20 for local testing
script/
  DeployAMM.s.sol            # Deploys two mock tokens + the AMM pool
test/
  ConstantProductAMM.t.sol   # Unit tests + property-based fuzz test
```

## Core Contract API

`ConstantProductAMM`:

- `addLiquidity(uint256 amount0Desired, uint256 amount1Desired) → uint256 shares` — deposits both assets and mints LP shares. The first deposit seeds the pool; later deposits mint the conservative minimum of the two proportional share amounts.
- `removeLiquidity(uint256 lpSharesBurned) → (uint256 amount0, uint256 amount1)` — burns LP shares and returns a proportional slice of both reserves.
- `swap(address tokenIn, uint256 amountIn) → uint256 amountOut` — swaps `tokenIn` for the other token, priced via `AMMMath.getAmountOut`.

`AMMMath` (library, inlined into callers):

- `getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) → uint256` — pure constant-product pricing with a 0.3% fee (`amountIn * 997 / 1000` accounting).

Events `LiquidityAdded`, `LiquidityRemoved`, and `Swap` are emitted for off-chain (e.g. Viem/Wagmi) consumption.

## Requirements

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (`forge`, `cast`, `anvil`)

## Usage

### Build

```shell
forge build
```

### Test

```shell
forge test
```

The suite currently passes 4/4 tests, including a 256-run fuzz test (`testFuzz_SwapMathInvariance`) that asserts the constant product invariant `k` never decreases across a swap.

For verbose traces:

```shell
forge test -vvvv
```

### Format

```shell
forge fmt
```

### Local Deployment

Start a local node:

```shell
anvil
```

Set a deployer key (the script reads `PRIVATE_KEY` from the environment) and run the deploy script, which deploys two mock tokens (`Gold Coin`/`GLD`, `Silver Coin`/`SLV`) and an AMM pool over them:

```shell
export PRIVATE_KEY=<your_private_key>
forge script script/DeployAMM.s.sol:DeployAMM --rpc-url http://localhost:8545 --broadcast
```

## Roadmap

See [`PLAN.md`](./PLAN.md) for planned extensions, including an interactive simulation script and production-grade features such as slippage protection (`minAmountOut` + deadlines), a factory/router architecture for multi-hop swaps, and flash loans.

## Notes & Limitations

This is an educational implementation and is **not production-ready**. Notably:

- ERC-20 `transfer` / `transferFrom` return values are not checked (no `SafeERC20`).
- `swap` has no slippage protection (`minAmountOut`) or deadline.
- The first-deposit share calculation is simplified (sum of amounts) rather than a geometric mean with a minimum-liquidity lock.

## License

MIT
