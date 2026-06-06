# Concepts: How This AMM Works

This document explains the ideas behind the Constant Product AMM in plain language, anchored to the actual code. It is meant as a learning companion to the [README](../README.md) (which focuses on how to build, test, and deploy the project).

---

## 1. What is an AMM?

An **Automated Market Maker (AMM)** is a smart contract that lets people trade two tokens against a shared pool of reserves, with no order book and no counterparty needed. Instead of matching buyers and sellers, the price is set by a mathematical formula based on how much of each token the pool currently holds.

This project implements the **constant product** model popularized by Uniswap V2:

$$x \cdot y = k$$

- `x` = reserve of `token0`
- `y` = reserve of `token1`
- `k` = the invariant, which must never *decrease* during a swap

When a trader adds some `token0`, they remove some `token1` such that the product `x * y` stays at least as large as before. This is what defines the price curve: the more you buy of one token, the more expensive each additional unit becomes (slippage).

The pool tracks the two tokens and their reserves:

```8:15:src/ConstantProductAMM.sol
contract ConstantProductAMM is ERC20 {
    // State variables tracking the two ERC-20 tokens making up this trading pair
    IERC20 public immutable token0;
    IERC20 public immutable token1;

    // Internal tracking of pool reserves (scaled to 18 decimals by the respective tokens)
    uint256 public reserve0;
    uint256 public reserve1;
```

Positionally, `reserve0` always tracks `token0`, and `reserve1` always tracks `token1`.

---

## 2. The two meanings of "LP"

"LP" is overloaded and is the single most common source of confusion. It means two different things:

1. **LP = Liquidity Provider** — a *person/wallet* who deposits tokens into the pool. In the tests this is the `liquidityProvider` address.
2. **LP token / LP shares** — a *receipt token* the pool issues to that person to record their stake. In this project these are the `ALEA-LP` tokens.

### Key insight: the AMM contract *is* the LP token

There are not two separate contracts. `ConstantProductAMM` **inherits from `ERC20`**, so the pool contract is itself a token:

```26:30:src/ConstantProductAMM.sol
    constructor(address _token0, address _token1) ERC20("Alea Liquidity Provider Token", "ALEA-LP") {
        require(_token0 != address(0) && _token1 != address(0), "AMM: INVALID_ADDRESS");
        token0 = IERC20(_token0);
        token1 = IERC20(_token1);
    }
```

So one single contract wears two hats at the same time:

- **Hat 1 — the pool/vault:** it holds `token0` and `token1` and lets people swap between them.
- **Hat 2 — the LP token:** it is its own ERC-20 named "Alea Liquidity Provider Token" (`ALEA-LP`). When it calls `_mint(msg.sender, shares)`, it is minting *itself* to the provider.

That is why a test can ask `amm.balanceOf(liquidityProvider)` — it is querying the AMM, acting as an ERC-20, for how many `ALEA-LP` tokens that wallet holds.

In total there are **three tokens** in play: `token0` (e.g. USDC), `token1` (e.g. WETH), and the AMM itself (`ALEA-LP`).

---

## 3. `addLiquidity` — deposit real tokens, receive LP shares

Think of a coat check: you hand over your coats (`token0` + `token1`) and get a claim ticket (LP shares).

```36:63:src/ConstantProductAMM.sol
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
```

**First deposit vs. later deposits:**

- **First deposit** (`totalSupply() == 0`): the pool is empty, so there is no existing ratio to match. Shares are seeded simply as `amount0Desired + amount1Desired`. (This is a simplified choice — see [Limitations](#7-limitations).)
- **Later deposits:** shares are proportional to what you add relative to existing reserves, and the provider is given the *conservative minimum* of the two ratios. This discourages depositing in a lopsided ratio that does not match the current pool.

**Direction of flow:**

| Asset | From | To |
|---|---|---|
| `token0`, `token1` | provider's wallet | AMM (via `transferFrom`) |
| LP shares (`ALEA-LP`) | minted | provider's wallet |

Note that the provider must `approve` the AMM to spend their tokens first, because the AMM pulls them with `transferFrom`.

---

## 4. `removeLiquidity` — burn LP shares, get real tokens back

The exact reverse of depositing: return the claim ticket, get your coats back (plus any fees that accumulated while you were providing liquidity).

```72:98:src/ConstantProductAMM.sol
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
```

**Direction of flow:**

| Asset | From | To |
|---|---|---|
| LP shares (`ALEA-LP`) | burned from provider | destroyed |
| `token0`, `token1` | AMM | provider's wallet |

### Why LP shares exist at all

You might wonder why the pool can't just remember "Alice deposited 500 USDC." The receipt-token design solves a real problem: **multiple providers share one pool, and the pool's value changes as fees accumulate.**

LP shares represent a *proportional claim*, not a fixed amount. If you hold 10% of all `ALEA-LP` tokens, you own 10% of *whatever is currently in the pool*. The redemption math is purely proportional:

```81:82:src/ConstantProductAMM.sol
        amount0 = (lpSharesBurned * reserve0) / totalPoolShares;
        amount1 = (lpSharesBurned * reserve1) / totalPoolShares;
```

As traders pay the 0.3% fee, reserves grow, so each LP share becomes redeemable for slightly *more* `token0`/`token1` than was originally deposited. That is how liquidity providers earn yield.

### Quick summary table

| | Who calls it | `token0`/`token1` | LP shares (`ALEA-LP`) |
|---|---|---|---|
| `addLiquidity` | the provider (a wallet) | wallet → AMM | minted to wallet |
| `removeLiquidity` | the provider (a wallet) | AMM → wallet | burned from wallet |

---

## 5. `swap` — trading one token for the other

A trader sends in one token and receives the other, priced by the constant-product formula.

```108:137:src/ConstantProductAMM.sol
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
```

The function figures out which direction the trade goes (`isToken0`), pulls the input token in, computes the output, and sends the output token out. The `(tIn, tOut, rIn, rOut)` tuple keeps "in" and "out" correctly paired regardless of direction.

### Slippage protection (`minAmountOut`)

The trader passes a `minAmountOut` — the smallest output they are willing to accept. If another transaction lands first and moves the price (a front-run / sandwich attack), the computed `amountOut` may drop below that floor, and the `require` reverts the entire swap atomically so the trader never gets a worse deal than they signed up for. Passing `minAmountOut = 0` opts out of protection (accept any output), which is convenient in tests but unsafe in production.

Note that `minAmountOut` must be an **absolute** amount, not a percentage. A percentage tolerance only means something relative to a reference price, and the only reference a contract has at execution time is its current reserves — which is exactly what an attacker manipulates. So the percentage is applied **off-chain** at signing time (when the user sees a quote), and the resulting absolute floor is what the contract enforces. This is why Uniswap and friends take an absolute `amountOutMin` on-chain.

### Deadline protection (`deadline`)

The trader also passes a `deadline` (a Unix timestamp). If the transaction is still sitting in the mempool when `block.timestamp` passes it, the swap reverts with `AMM: EXPIRED` instead of executing at a stale price. Without this, a transaction could be held back by validators and executed much later under very different market conditions. Slippage and deadline are complementary: `minAmountOut` bounds *how bad a price* you accept, while `deadline` bounds *how long* the order stays valid.

### The 0.3% fee and the pricing formula

The actual pricing lives in a separate pure library, `AMMMath`:

```11:31:src/libraries/AMMMath.sol
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
```

Key points:

- **No floats in Solidity.** A 0.3% fee means the trader effectively only gets credited for 99.7% of their input. Rather than multiply by `0.997` (impossible with integers), the code multiplies by `997` and divides by `1000`.
- **Multiply before dividing.** Integer division truncates, so doing all multiplications first preserves precision.
- The formula is the algebraic solution to keeping `x * y = k` after the fee-adjusted input is added: `amountOut = (amountInWithFee * reserveOut) / (reserveIn * 1000 + amountInWithFee)`.
- The fee is **never sent anywhere** — it simply stays in the reserves, which is what grows `k` and rewards liquidity providers.

---

## 6. Why reserves are tracked explicitly

Notice that after every state-changing function, the code re-reads balances into `reserve0` / `reserve1`:

```120:122:src/ConstantProductAMM.sol
        // 4. Re-sync internal records with the actual token balances remaining inside the vault
        reserve0 = token0.balanceOf(address(this));
        reserve1 = token1.balanceOf(address(this));
```

There are two distinct quantities:

1. **Actual balance** — `token0.balanceOf(address(this))`. Anyone can transfer tokens directly to the contract without going through `addLiquidity` or `swap`. Such "donations" are real but unaccounted for.
2. **Tracked reserves** — `reserve0` / `reserve1`. These are what the pricing formula uses.

By storing reserves explicitly and only updating them at the end of each call, the pool prevents stray transfers from skewing the price curve mid-transaction, and keeps the invariant `k = reserve0 * reserve1` well-defined. (Uniswap V2 does the same, and exposes a `skim()` function to recover the difference; this project does not implement `skim`.)

---

## 7. How the invariant is tested

The fuzz test asserts the core property — that `k` never shrinks across a swap — over **256 randomized inputs**:

```140:165:test/ConstantProductAMM.t.sol
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
```

Because the test function takes a parameter (`uint256 swapAmount`), Foundry runs it as a **fuzz test**: by default 256 times, each with a different pseudo-random value (biased toward edge cases). `bound(...)` maps the raw random number into a sensible range so the run exercises the real logic instead of trivially reverting. If *any* input ever made `k` shrink, the test would fail and report the exact counterexample.

This is **property-based testing**: rather than checking one hand-picked example, it asserts a rule that must hold across a whole space of inputs.

---

## 8. The Factory-Router architecture

A single pool only knows how to trade its own two tokens. Real AMMs scale to many tokens by splitting responsibilities across two extra contracts: a **Factory** that mass-produces pools, and a **Router** that chains trades across them.

### The Factory: a pool registry

`AMMFactory` deploys a fresh `ConstantProductAMM` for any token pair and remembers it, so the same pair can never be created twice:

```26:43:src/AMMFactory.sol
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
```

**Canonical ordering** means sorting the two tokens by the numeric value of their *addresses* (not their names), so `token0` is always the smaller address. This collapses `createPair(A, B)` and `createPair(B, A)` to the same registry slot, guaranteeing one pool per unordered pair. The factory stores the lookup in both directions so callers never have to sort themselves.

### The Router: multi-hop swaps

If you want to trade A for C but only A/B and B/C pools exist, the `AMMRouter` bridges through B in a single transaction. It first quotes every leg, checks the final slippage floor, then executes each hop, carrying the output of one into the next:

```55:74:src/AMMRouter.sol
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
```

### Worked example: routing 1,000 A → C through B

Suppose both pools start balanced at 10,000 : 10,000, and there is no direct A/C pool.

1. **Quote** (`getAmountsOut`, a read-only view): leg A→B gives `getAmountOut(1000, 10000, 10000) ≈ 906.6 B`; leg B→C gives `getAmountOut(906.6, 10000, 10000) ≈ 828.2 C`. Note the erosion `1000 → 906.6 → 828.2` — each hop pays the 0.3% fee *and* incurs curve slippage.
2. **Slippage check**: revert immediately if `828.2 < amountOutMin`, before any tokens move.
3. **Pull input**: 1,000 A moves from trader → router.
4. **Leg A→B**: router approves pool A/B, calls `swap`; pool pulls the 1,000 A and sends ~906.6 B back to the router.
5. **Leg B→C**: router approves pool B/C, calls `swap`; pool pulls the 906.6 B and sends ~828.2 C back to the router.
6. **Forward**: router transfers the ~828.2 C to the recipient.

### Why "atomic" matters

All of those steps happen inside one transaction, and the EVM guarantees a transaction is **all-or-nothing**. If any leg reverts — say pool B/C was drained by a front-runner and its per-leg `swap` check fails — then the leg that already executed is rolled back too. The trader can never end up stranded holding intermediate B tokens; they either get their final C or keep their original A. The router safely custodying tokens mid-route works precisely because those intermediate balances only exist *within* the transaction.

---

## 9. Limitations

This is an educational implementation and is **not production-ready**:

- ERC-20 `transfer` / `transferFrom` return values are not checked (no `SafeERC20`).
- `swap` now enforces both a `minAmountOut` slippage floor and a `deadline` staleness guardrail, but liquidity provision (`addLiquidity` / `removeLiquidity`) still has neither.
- The first-deposit share calculation is simplified (sum of amounts) rather than a geometric mean (`sqrt(amount0 * amount1)`) with a minimum-liquidity lock, which real AMMs use to resist share-price manipulation.
- The router custodies tokens between hops rather than using the send-directly-to-next-pool optimization, and does not deduplicate repeated pools within a path.

See [`PLAN.md`](../PLAN.md) for planned extensions that address several of these.
