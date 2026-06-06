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
  AMMFactory.sol             # Registry that deploys & tracks pool pairs
  AMMRouter.sol              # Multi-hop swaps + quoting across pools
  libraries/AMMMath.sol      # Pure pricing math (getAmountOut) with 0.3% fee
  mocks/MockERC20.sol        # Freely-mintable ERC-20 for local testing
script/
  DeployAMM.s.sol            # Deploys two mock tokens + a single AMM pool
  DeployFactory.s.sol        # Deploys factory + router + 3 tokens + 2 bridged pools
test/
  ConstantProductAMM.t.sol   # Pool unit tests + property-based fuzz test
  AMMFactoryRouter.t.sol     # Factory registration + multi-hop routing tests
```

## Core Contract API

`ConstantProductAMM`:

- `addLiquidity(uint256 amount0Desired, uint256 amount1Desired) → uint256 shares` — deposits both assets and mints LP shares. The first deposit seeds the pool; later deposits mint the conservative minimum of the two proportional share amounts.
- `removeLiquidity(uint256 lpSharesBurned) → (uint256 amount0, uint256 amount1)` — burns LP shares and returns a proportional slice of both reserves.
- `swap(address tokenIn, uint256 amountIn, uint256 minAmountOut, uint256 deadline) → uint256 amountOut` — swaps `tokenIn` for the other token, priced via `AMMMath.getAmountOut`, with slippage and deadline guardrails.

`AMMFactory`:

- `createPair(address tokenA, address tokenB) → address pair` — deploys and registers a pool for the (canonically ordered) pair; reverts if it already exists.
- `getPair(address, address) → address` / `allPairs(uint256)` / `allPairsLength()` — registry lookups.

`AMMRouter`:

- `getAmountsOut(uint256 amountIn, address[] path) → uint256[]` — view that quotes the cascading output across a multi-hop path.
- `swapExactTokensForTokens(uint256 amountIn, uint256 amountOutMin, address[] path, address to, uint256 deadline) → uint256[]` — executes a multi-hop swap atomically, bridging through intermediate pools.

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

The suite includes pool unit tests, a 256-run fuzz test (`testFuzz_SwapMathInvariance`) that asserts the constant product invariant `k` never decreases across a swap, and factory/router tests covering pair registration and multi-hop routing.

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

Set a deployer key (the scripts read `PRIVATE_KEY` from the environment). To deploy a single pool with two mock tokens (`Gold Coin`/`GLD`, `Silver Coin`/`SLV`):

```shell
export PRIVATE_KEY=<your_private_key>
forge script script/DeployAMM.s.sol:DeployAMM --rpc-url http://localhost:8545 --broadcast
```

To deploy the full factory/router stack with three tokens and two bridged, pre-seeded pools (`GLD/SLV` and `SLV/USDC`, enabling `GLD → SLV → USDC` routing):

```shell
export PRIVATE_KEY=<your_private_key>
forge script script/DeployFactory.s.sol:DeployFactory --rpc-url http://localhost:8545 --broadcast
```

## Roadmap

See [`PLAN.md`](./PLAN.md) for planned extensions, including an interactive simulation script and production-grade features such as slippage protection (`minAmountOut` + deadlines), a factory/router architecture for multi-hop swaps, and flash loans.

## Notes & Limitations

This is an educational implementation and is **not production-ready**. Notably:

- ERC-20 `transfer` / `transferFrom` return values are not checked (no `SafeERC20`).
- `swap` enforces both a `minAmountOut` slippage floor and a `deadline`, but `addLiquidity` / `removeLiquidity` have neither.
- The first-deposit share calculation is simplified (sum of amounts) rather than a geometric mean with a minimum-liquidity lock.

## License

MIT
