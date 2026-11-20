# Curatio

A permissioned, KYC-gated ERC-4626 vault that deploys liquidity into a **Uniswap v4** pool and actively manages a single LP position. Swap fees adapt to volatility and MEV through a custom v4 hook, and the position is re-ranged by Chainlink Automation or by registered strategists. The vault prices its shares from the hook's TWAP, never from pool spot.

> **Status:** prototype, **unaudited**. Do not deploy with real funds. Solidity `^0.8.26`. See [Roles & trust assumptions](#5-roles--trust-assumptions) and [Known limitations](#6-known-limitations).

---

## Partner Integrations

- **Chainlink Automation**: `CuratioRebalancer` implements `AutomationCompatibleInterface` (`checkUpkeep` / `performUpkeep`). A Chainlink keeper triggers rebalances when the hook's dynamic fee rises to the mid-volatility tier or the pool tick diverges from the TWAP. Only the registered `automationRegistry` can call `performUpkeep`. The integration is covered by unit and end-to-end tests that simulate the Automation registry (see Testing).

No other partner integrations.

(Built on Uniswap v4 core and OpenZeppelin libraries as dependencies; these are the base platform, not partner integrations.)

---

## 1. Architecture

| Layer | Contract | Role |
|------:|----------|------|
| 1 | `CuratioHook` | Uniswap v4 hook: dynamic swap fee, TWAP oracle, sandwich (MEV) detection |
| 2 | `CuratioAccess` | Whitelist / KYC gating with a 2-day removal timelock |
| 3 | `CuratioVault` | ERC-4626 vault (`cVAULT`), high-water-mark performance fee, delegated strategist following |
| 4 | `CuratioRebalancer` | Holds the LP position, rebalances ranges, swaps to cover shortfalls, reports TWAP-priced assets |
| 5 | `CuratioDynamicFee` | Performance-fee rate engine (swap fees live in the hook, not here) |
| 6 | `CuratioStrategistRegistry` | Strategist registry, pool assignment, performance counters |

```
                    ┌──────────────────┐
   User ──────────► │  CuratioVault    │ ◄── CuratioAccess (whitelist)
                    │  (ERC-4626)      │ ◄── CuratioDynamicFee (perf. fee)
                    └───────┬──────────┘
        totalManagedAssets()│  ▲ deployToRebalancer / returnToVault
                            ▼  │
                    ┌──────────────────┐        ┌──────────────────────────┐
                    │CuratioRebalancer │ ─────► │ StrategistRegistry (L6)  │
                    └───────┬──────────┘        └──────────────────────────┘
          unlock / modifyLiquidity / swap
                            ▼
                    ┌──────────────────┐
                    │ Uniswap v4       │ ◄──► CuratioHook (L1)
                    │ PoolManager      │      (fees + TWAP + MEV guard)
                    └──────────────────┘
```

---

## 2. Flows

### 2.1 Swap flow (Hook, Layer 1)

```
User → PoolManager.swap()
   │
   ├─ beforeSwap()
   │    1. transient-storage guard (flag set; reverts if already dirty)
   │    2. zero-amount swap → BASE_FEE
   │    3. back-run check → MEV_PENALTY_FEE?
   │    4. TWAP warm? → divergence check → fee
   │       (cold oracle → MID_VOLATILE_FEE)
   │    5. return fee | OVERRIDE_FEE_FLAG
   │
   ├─ [Swap executes]
   │
   └─ afterSwap()
        1. flag verify + reset
        2. TwapOracle.write(preSwapTick)
        3. tracker update (swapCount, tickDelta, totalMove, firstMove)
        4. back-run? → flag THIS block only (monitoring)
        5. _computeFee → save to poolStates.fee
        6. emit FeeUpdated / HistoryUpdated (/ SandwichDetected)
```

### 2.2 Deposit → rebalance flow (Vault → Rebalancer → PoolManager)

```
User.deposit()  ──ERC20──►  Vault  ──deployToRebalancer──ERC20──►  Rebalancer
                                                                        │
                                                    rebalanceLiquidity() / performUpkeep()
                                                                        │
                                                        poolManager.unlock(REBALANCE)
                                                                        │
                                                        unlockCallback → _executeRebalance
                                                                        │
                       ┌────────────────────────────────────────────────┤
                       │ 1. modifyLiquidity (remove ALL old liquidity)  │
                       │ 2. modifyLiquidity (add new range)             │
                       │ 3. _coverDeficits:                             │
                       │      MEV-penalty check → TWAP price check      │
                       │      → poolManager.swap() (exact-out)          │
                       │         ├─ Hook.beforeSwap (fee)               │
                       │         ├─ [AMM swap in pool]                  │
                       │         └─ Hook.afterSwap  (writes TWAP)       │
                       │ 4. slippage caps (maxPay0 / maxPay1)           │
                       └────────────────────────────────────────────────┤
                                                                        │
                                                        _settleCurrency × 2
                                                                        │
                                                Rebalancer → PoolManager → Pool
```

The swap in step 3 happens **only if one currency is short** after the net remove/add deltas.

### 2.3 Withdraw flow

```
User.withdraw()/redeem()
   → whitelist check (caller, receiver, owner)
   → Vault._withdraw: idle < assets ?
        └─ Rebalancer.returnToVault(shortfall)
              └─ idle short → _unwindForVault:
                    remove needed share of LP (+1% buffer)
                    → swap other token into asset (TWAP-checked)
   → transfer assets to receiver
   → notifyWithdraw (non-blocking)
```

### 2.4 Performance-fee flow (`harvest`)

```
VAULT_MANAGER.harvest()
   price = (totalAssets + 1) * 1e36 / (supply + 1e6)
   price <= HWM        → nothing
   hwm == 0            → record baseline, no fee
   yield = (price - HWM) * (supply + 1e6) / 1e36
   fee   = DynamicFee.calculatePerformanceFee(yield)   (vault caps at 30%)
   mint fee shares to feeRecipient (no asset moves)
   HWM = post-dilution price
```

### 2.5 LP positions and imbalance

**LP position.** A liquidity position is a deposit of both pool tokens that earns swap fees only while the pool price is inside its tick range. `CuratioRebalancer` tracks exactly one position as `currentTickLower`, `currentTickUpper` and `currentLiquidity`. A rebalance removes all of it and re-adds it in a new range, so the liquidity keeps earning fees as the price moves. Outside its range a position holds only one of the two tokens and earns nothing.

**Imbalance.** A position in a given range at a given price needs a specific mix of token0 and token1. When the tokens the rebalancer holds do not match that mix, one token is short and the other is in surplus. That mismatch is the imbalance. It comes from three places:

| Source | Example |
|--------|---------|
| Removing the old position | The price left the old range, so the old position returns only one token, but the new range needs both |
| Single-token vault asset | Users deposit only the vault asset (say USDC), but any in-range position needs both tokens |
| Withdrawals | The user wants the vault asset, but removing LP also returns the other token |

**How the rebalancer resolves it** (`_coverDeficits`, called inside the PoolManager unlock):

1. Net the removed and added amounts into `delta0` / `delta1` (negative = we owe the pool, positive = the pool owes us).
2. For each token, compute the shortfall: what must be paid, minus the idle balance plus the delta.
3. No shortfall: no swap.
4. Shortfall in **both** tokens: revert (`InsufficientFunds`), because a swap cannot cover both.
5. Shortfall in **one** token: buy it with the other token through an exact-output swap on the pool.
6. Before swapping, refuse if the hook is charging the MEV penalty (`MevPenaltyActive`). After swapping, compare the execution price with the TWAP and revert above `maxSwapSlippageBps` (`SwapPriceDeviation`).
7. Check the final net payment against the `maxPay0` / `maxPay1` caps, then settle.

Illustrative example (the numbers are only for explanation): the vault asset is USDC, the rebalancer holds 800 USDC and no WETH, and the new range needs about 0.19 WETH and 400 USDC. WETH is short, so the rebalancer buys 0.19 WETH with USDC (the swap goes through the hook's `beforeSwap` / `afterSwap`), checks the price against the TWAP, and then adds the position. The leftover USDC stays idle.

### 2.6 Where the funds actually are

User funds never go into the hook, and the swap does not happen in the hook. The swap executes in the Uniswap v4 `PoolManager`, and the hook is only a callback.

```
User ──deposit──► Vault ──deployToRebalancer──► Rebalancer ──unlock/settle──► PoolManager ──► Pool (LP)
                                                                                  │
                                                       Hook.beforeSwap (sets fee) ┤
                                                       Hook.afterSwap  (writes TWAP)
```

| Component | Holds user funds? | Role |
|-----------|:-----------------:|------|
| Vault | Idle asset only | Accounting, whitelist, share pricing |
| Rebalancer | Idle balances of both tokens | Moves funds in and out of the pool |
| PoolManager / Pool | Yes (LP reserves) | Executes the swap and holds liquidity |
| CuratioHook | **No** | Sets the fee and records the TWAP and sandwich data. It never calls `transfer` or `transferFrom` |

State at each step:

1. `deposit`: the vault holds the idle asset. Nothing is swapped and the share price does not change.
2. `deployToRebalancer`: a plain ERC-20 transfer from the vault to the rebalancer. This changes custody only, and the share price stays the same because `totalAssets()` counts the rebalancer's holdings.
3. Rebalance (strategist call or Chainlink `performUpkeep`): the rebalancer calls `poolManager.unlock(...)`. Inside the callback it removes the old liquidity, adds the new, covers any shortfall with a swap, and settles the net amounts.
4. A swap happens only when a token is short (see 2.5). Often the removed tokens plus the idle balance are enough and no swap is needed.

---

## 3. Contract notes

### CuratioHook (L1)

- **Permissions:** `beforeInitialize`, `afterInitialize`, `afterAddLiquidity`, `afterRemoveLiquidity`, `beforeSwap`, `afterSwap`.
- **Pools must use dynamic fees** (`PoolMustUseDynamicFee`).
- **Fees**

  | Constant | Value | Meaning |
  |----------|------:|---------|
  | `BASE_FEE` | 3000 | 0.30% |
  | `MID_VOLATILE_FEE` | 6000 | 0.60% (also cold-start fee) |
  | `HIGH_VOLATILE_FEE` | 15000 | 1.50% |
  | `MEV_PENALTY_FEE` | 100000 | 10% (charged to the swap that reverses the block's first move) |

- **Fee logic:** if the oracle is warm, |spot − TWAP| ≥ `tickThresholdHigh` (500) → HIGH, ≥ `tickThresholdMid` (200) → MID, otherwise the last stored fee decays to BASE after `blockDecayWindow` blocks.
- **TWAP oracle:** v3-style `tickCumulative` ring buffer, 120 s window, one observation per distinct timestamp. Pre-warmed at init (`getInitialCardinality`: 240 on ~1 s chains, 100 elsewhere). Cardinality growth is applied only when the write index reaches the last slot (v3 rule).
- **Sandwich detection:** tracks per-block `firstMove`, `lastMove`, `totalMove` (sum of |tick move|). A swap in the opposite direction of the block's first move, after `totalMove ≥ sandwichTickThreshold` (80 ticks), is a back-run.
- **Chain safety:** constructor checks the PoolManager address against `ChainRegistry` (skipped on chain 31337).
- **Admin:** owner can propose/execute/cancel threshold changes with a **2-day timelock**; `setInitialCardinality`, `setMaxCardinalityPerCall`.
- **Deprecated:** `mevVolumeThreshold` is kept for ABI compatibility only.

### Hook details: transient storage (EIP-1153)

The hook uses `tstore` / `tload` to pass state from `beforeSwap` to `afterSwap` within one swap, at no persistent-storage cost. Each value lives in a per-pool slot derived as `keccak256(abi.encodePacked(poolId, "flag"))` or `keccak256(abi.encodePacked(poolId, "tick"))`.

| Transient slot | Written in | Read in | Purpose |
|----------------|-----------|---------|---------|
| `flag` | `beforeSwap` (set to 1) | `afterSwap` (checked, then reset to 0) | Marks that a swap is in flight for this pool |
| `tick` | `beforeSwap` (current tick from `slot0`) | `afterSwap` | Pre-swap tick, used for the tick-delta fee, sandwich tracking and the oracle write |

The flag is a composability guard:

- If `beforeSwap` finds the flag already set, a second swap on the same pool started before the first one's `afterSwap`. It reverts with `Transient storage dirty: composability violation`.
- If `afterSwap` finds the flag unset, it was called without a matching `beforeSwap`. It reverts with `Composability violation: unexpected state`.
- The flag is set before the early-return paths in `beforeSwap` (zero-amount swap, sandwich-penalty block), so `afterSwap` always finds it and clears it.
- Transient storage is wiped at the end of each transaction, so a stale flag can never carry over into a later transaction.

The design assumes PoolManager always pairs `beforeSwap` with `afterSwap` for a pool before another swap on that pool begins. This holds under v4's unlock/settle model, but should be re-audited if PoolManager behaviour ever changes. Transient opcodes need an EVM version with Cancun support (`evm_version = "cancun"` or later in `foundry.toml`), Solidity 0.8.24+, and a target chain that supports EIP-1153.

### CuratioAccess (L2)

- Adding to the whitelist is **immediate**; removal is `proposeRemoval` → 2 days → `executeRemoval` (or `cancelRemoval`).
- `isWhitelisted()` returns `true` for everyone when `isWhitelistingEnabled == false` (admin toggle).
- Batch add is limited to 200 users per call.

### CuratioVault (L3)

- ERC-4626 with `_decimalsOffset() = 6` (inflation-attack protection); `ZeroShares` / `ZeroAssets` guards.
- `totalAssets() = idle + rebalancer.totalManagedAssets()`. This is **strict**: if the TWAP is unavailable it reverts, pausing deposits/withdrawals instead of mispricing. `maxDeposit`/`maxMint` return 0 in that case.
- Whitelist gates deposit, mint, withdraw and redeem. The deposit cap and the deposit pause are managed by `VAULT_MANAGER`; withdrawals still work while deposits are paused.
- Admin changes (access contract, rebalancer, fee module) use **propose → 2 days → execute**. The only immediate action is the one-time `initializeFeeModule()`.
- Performance fee is capped at 30% of the yield above the HWM (`MAX_PERFORMANCE_FEE_BPS`).
- `followStrategist` / `unfollowStrategist` record a depositor's chosen strategist (registry-validated).

### CuratioRebalancer (L4)

- One position: `(managedPool, currentTickLower, currentTickUpper, salt 0)`. Every rebalance removes **all** liquidity and re-adds `newLiquidity`.
- **Entry points:** `rebalanceLiquidity()` (`STRATEGIST_ROLE`) and Chainlink `performUpkeep()` (keeper).
- **Keeper trigger** (`checkUpkeep`): hook fee ≥ 6000, or |lastTick − TWAP| > 200. The new range is ±2 tick spacings around the reference tick (±3 when the TWAP diverged).
- **Keeper sanity:** reference tick must be within `maxReferenceDeviationTicks` (500) of the current TWAP. Keeper slippage caps `keeperMaxPay0/1` default to **0** (fail-safe).
- **Swap protection:** reverts on `MevPenaltyActive` and when the execution price deviates more than `maxSwapSlippageBps` (3%) from TWAP (`SwapPriceDeviation`).
- **Valuation:** `totalManagedAssets()` prices idle balances and the LP position at the TWAP; uncollected fees are not counted.
- **Timelock:** only the hook address (`proposeHook` → 2 days → `executeHook`).
- **Rescue:** `rescueToken` (non-managed tokens only), `rescueNativeEth` (only when no pool currency is native).

### CuratioDynamicFee (L5)

Performance-fee engine for the vault's harvested yield. It holds no funds: it calculates the fee, records what was charged, and names who receives it. Swap fees are not handled here; they live in the hook because the swap path is gas-critical.

- **Fee rate:** `performanceFeeBps` defaults to 1000 (10%) with a hard cap of 3000 (30%, a constant). Setting it to 0 is allowed.
- **Calculation:** `calculatePerformanceFee(yield)` is a view: `yield * performanceFeeBps / 10_000` (flat rate, no tiers).
- **Accounting:** `reportPerformanceFeeCharged(yield, fee)` is vault-only. It rejects a fee above `yield * performanceFeeBps / 10_000` (`FeeExceedsCalculated`), then adds to the cumulative counters `totalFeesCharged` and `totalYieldProcessed` and emits `PerformanceFeeCharged`. It moves no funds, because the vault has already minted the fee shares.
- **Recipient:** the vault reads `feeRecipient()` and mints the fee shares to it, so the fee is paid in shares (dilution), not in assets.
- **One vault per module:** the vault's `_checkFeeModule` requires `module.vault() == address(vault)`.

| Role | Powers |
|------|--------|
| `DEFAULT_ADMIN_ROLE` | `setFeeRecipient`, `setVault`, role management |
| `FEE_ADMIN_ROLE` | `setPerformanceFeeBps` |
| `VAULT_ROLE` | `reportPerformanceFeeCharged` |

**Double cap.** The module caps the rate at 30%, and the vault independently reverts if a module quotes more than 30% of the yield, or more than total assets. A compromised or buggy module cannot make the vault charge more than 30% of the yield.

**Trust assumptions specific to this module:**

- `setPerformanceFeeBps`, `setFeeRecipient` and `setVault` are immediate (no timelock). Use a multisig as admin.
- A new rate applies to all gain since the last `harvest()`, because the high-water mark only moves when `harvest()` runs. Harvest before raising the rate if the old rate should apply to gain already earned.
- A new `feeRecipient` receives future fee shares only. Shares already minted stay with the old recipient.
- If `setVault` points the module at a different vault, the real vault's `harvest()` reverts, because `reportPerformanceFeeCharged` is vault-only. Keep the module's vault and the vault's fee module consistent.
- There is no pause. To stop fees, propose `address(0)` as the fee module on the vault (`proposeFeeModule(0)`, effective after the 2-day timelock), or set the rate to 0.
- The counters are cumulative totals with no snapshots. Rebuild history from the `PerformanceFeeCharged` and `Harvested` events.

### CuratioStrategistRegistry (L6)

- Register, deactivate, reactivate; assign, reassign, unassign and bulk-reassign pools.
- `REBALANCER_ROLE` (granted to the rebalancer) records rebalance counts and fees.
- Inactive strategists keep their assignments but cannot record performance or receive new pools.
- `backtestStrategy()` is a placeholder estimate (10% of recorded fees), not a real backtest.

---

## 4. Testing

The protocol ships with two Foundry test layers, both fully passing (Solc 0.8.26):

- **Local suite:** 501 tests across 18 suites, 0 failed, 0 skipped (`forge test`).
- **Fork suite:** 131 passing test runs across 7 suites (55 distinct tests), 0 failed, 0 skipped, run against a fork of Unichain mainnet (chain id 130) through `UNICHAIN_RPC`.
- **Invariant suite:** 25 stateful invariants for the hook (see below).

```bash
forge test
```

Tests live in `test/foundry/`. Several suites run against the real Uniswap v4 `PoolManager` and the real `CuratioHook` (not mocks).

| Area | Suite | Tests |
|------|-------|------:|
| Hook (L1) | `CuratioHookTest` | 93 |
| Hook oracle growth / gas | `CardinalityGasDoSTest` | 6 |
| Hook oracle growth / gas | `GasGriefingTest` | 13 |
| Access (L2) | `CuratioAccessTest` | 34 |
| Vault (L3) | `CuratioVaultTest` | 79 |
| Vault harvest / fees | `CuratioVaultHarvestTest` | 41 |
| Vault inflation attack | `CuratioVaultInflationTest` (incl. fuzz, 256 runs) | 9 |
| Rebalancer (L4) | `CuratioRebalancerTest` | 43 |
| Rebalancer integration | `CuratioRebalancerIntegrationTest` | 19 |
| Rebalancer with real PoolManager | `CuratioRebalancerRealPMTest` | 17 |
| Rebalancer valuation (TWAP) | `CuratioRebalancerValuationTest` | 18 |
| Chainlink Automation (`checkUpkeep`) | `CuratioRebalancerCheckUpkeepTest` | 5 |
| Swap / unwind / slippage | `CuratioSwapE2ETest` | 9 |
| Dynamic fee (L5) | `CuratioDynamicFeeTest` | 37 |
| Strategist registry (L6) | `CuratioStrategistRegistryTest` | 53 |
| End-to-end, vault + rebalancer | `CuratioVaultRebalancerE2ETest` | 12 |
| End-to-end, real hook | `CuratioFullStackRealHookE2ETest` | 6 |
| End-to-end, full protocol | `CuratioFullProtocolE2ETest` | 7 |
| **Total** | **18 suites** | **501** |

What the tests cover:

- **Hook:** dynamic fee tiers, TWAP warm-up and interpolation, sandwich/back-run penalty, transient-storage guard, chain and PoolManager checks (including Unichain Sepolia), timelocked thresholds.
- **Vault:** whitelist gating, deposit cap and pause, TWAP-outage halt (no mispricing), withdrawal unwinding the LP, high-water-mark performance fee, inflation-attack resistance (fuzzed).
- **Rebalancer:** range validation, slippage caps, MEV-penalty refusal, TWAP price check on swaps, same-block spot manipulation ignored in valuation.
- **Chainlink Automation:** `checkUpkeep` (fee high, TWAP diverged, hook failure fallback) and `performUpkeep` (registry-only, range selection, skip rules) are tested by simulating the Automation registry. The fork suite also checks the keeper path against the real PoolManager (default keeper caps are zero so upkeep reverts, only the Automation registry can call it, a repeat call in the same range emits `Range unchanged`, a call that is too soon is skipped, and with caps set it opens a position around the TWAP).
- **Access control and timelocks:** every admin action, role restriction and timelock boundary, including exact-ETA execution and replay protection.

### Fork tests (real PoolManager and real tokens)

The fork tests deploy a fresh Curatio stack and a new pool that uses the hook on top of the **real Unichain PoolManager** (`0x1F98...0004`, chain id 130), so no existing Uniswap pool is touched. Fees are read from the PoolManager's own `Swap` event, so they show the fee actually charged. Unichain blocks are 1 s, so the tests move blocks and seconds together.

**Setup.** Add a profile to `foundry.toml` (the default profile points `test` at `test/foundry`):

```toml
[profile.fork]
test = "test/fork"
```

Put the RPC URL in a `.env` file or export it. The public endpoint needs no account; if you hit rate limits, pin the block with `UNICHAIN_FORK_BLOCK` so Foundry caches the state. Without `UNICHAIN_RPC`, every fork test is skipped.

```
UNICHAIN_RPC=https://mainnet.unichain.org
```

**Run.** The keeper, swap-path, findings and mentor-fix suites inherit the fixture of `CuratioForkTest`, so filter by test name to run only their own tests:

```bash
export FOUNDRY_PROFILE=fork
forge test --match-path test/fork/CuratioForkTest.t.sol -vv
forge test --match-path test/fork/CuratioForkKeeperTest.t.sol --match-test test_keeper -vv
forge test --match-path test/fork/CuratioForkRealTokensTest.t.sol -vv
forge test --match-path test/fork/CuratioForkSwapPathTest.t.sol --match-test test_swapPath -vv
forge test --match-path test/fork/CuratioForkFindingsTest.t.sol --match-test "test_more|test_fix" -vv
forge test --match-path test/fork/CuratioForkDecimalsTest.t.sol --match-test test_decimals -vv
```

On PowerShell use `$env:FOUNDRY_PROFILE = "fork"`, and clear it afterwards (`unset FOUNDRY_PROFILE` / `Remove-Item Env:FOUNDRY_PROFILE`) so a plain `forge test` goes back to `test/foundry`. Not yet covered by fork tests: USDC blacklist behaviour.

| Suite | Tests | Focus |
|-------|------:|-------|
| `CuratioForkTest` | 17 | Base scenarios: hook initialised on the real PoolManager, cold-start and warm fees, TWAP deviation, same-block reversal penalty, sandwich penalty, vault deposit/redeem, rebalancer deploying liquidity |
| `CuratioForkFindingsTest` | 23 | Base + 6: busy pool keeps the oracle warm, deferred cardinality growth after wrap, penalty ends with the flagged block, Unichain default oracle depth, timelocked thresholds, two pools sharing one hook stay isolated |
| `CuratioForkKeeperTest` | 23 | Base + 6 keeper tests (Chainlink Automation path, see above) |
| `CuratioForkSwapPathTest` | 26 | Base + 9: keeper two-sided range covers deficits with a swap, reverts inside a sandwich block, succeeds one block later, slippage caps, withdrawals that need a swap, fee decay after a sandwich |
| `CuratioForkMentorFixTest` | 22 | Base + 5: attacker back-run pays the penalty while victim and front-run do not, penalty does not carry into the next block, small reversals are not penalised, dynamic-fee pool accepted and static-fee pool rejected |
| `CuratioForkRealTokensTest` | 8 | Real USDC and WETH tokens: pool setup, fee tiers, single-sided USDC position, vault values WETH at the TWAP, deposit/redeem round trips |
| `CuratioForkDecimalsTest` | 12 | Real-token tests + 4 decimals tests: USDC- and WETH-denominated sandwiches are detected, dust round trips are not flagged, sandwich tick threshold is tunable in ticks |
| **Total** | **131** | 7 suites |

The extended suites re-run the base suite's scenarios, so the number of distinct tests is lower than 131.

### Invariant tests (stateful fuzzing)

25 Foundry invariants in `test/invariant/` (`CuratioHookInvariantTest`, driven by `CuratioHandler`) fuzz the hook against a local PoolManager with real swap and liquidity routers. The handler performs random swaps (exact-in and exact-out, both directions, 0 to 30 blocks apart so same-block sandwiches happen), liquidity adds and removes, oracle growth by an arbitrary caller, owner timelock actions and calls from non-owners. It mirrors every action in ghost variables, so each invariant compares the hook's state with what should have happened.

| Area | What is checked |
|------|-----------------|
| Pool and fees | tick and price stay valid; `lastTick`, `lastBlock` and `lastTimestamp` match the pool and the last swap; stored and current fees are always a defined tier; the fee decays to `BASE_FEE` after the decay window |
| MEV penalty | the penalty is never stored in the pool state; `getCurrentFee` reports it only in a block that already had a swap; the tick move recorded for a block is 0 unless a swap happened in it |
| Volume and tracker | per-block volume and the sandwich tracker match the ghost values |
| Liquidity | stored positions match the ghost accounting; active liquidity never exceeds what was added; the seed liquidity floor holds |
| Oracle | `index < cardinality <= cardinalityNext`; cardinality never decreases; the per-call growth cap holds; a warm oracle is always readable by `getTwapTick` |
| Liveness and gas | no swap reverts inside the hook; swap gas stays bounded |
| Governance | threshold ordering, the 2-day timelock, owner-only functions reject strangers, cardinality caps stay within the hard ceiling |

PoolManager wraps every revert that comes from a hook in `WrappedError`, so those count as hook failures and fail `invariant_swapsNeverRevert` (with the failing swap and revert data logged). Reverts that come from the PoolManager or router (for example swap maths at extreme prices) are counted separately and reported by `afterInvariant` without failing the run.

The invariant settings come from the `[profile.default.invariant]` section of `foundry.toml` (`runs = 256`, `depth = 400`, `fail_on_revert = true`), so no extra profile is needed:

```bash
forge test --via-ir --match-path "test/invariant/*.sol"
```

`--via-ir` is only needed if `foundry.toml` does not already set `via_ir = true`. Add `-vv` only when debugging a failure: forge-std's `bound()` logs every call, so the output becomes very long.

**Last full run:** 25 passed, 0 failed, 0 skipped. Each invariant ran 256 runs of depth 400 (102,400 calls) with 0 reverts, in about 222 seconds.

A full run is slow (25 invariants x 256 runs x 400 calls). For a quick pass set `FOUNDRY_INVARIANT_RUNS=32`. The `test/Echidna/` contracts are harnesses for Echidna and are not run by Foundry.

### Test coverage

Per-file coverage of the contracts in `src/`, as reported by the coverage display in VS Code after running the test suite:

| Contract | Coverage |
|----------|---------:|
| `CuratioAccess.sol` | 100% |
| `CuratioDynamicFee.sol` | 100% |
| `CuratioStrategistRegistry.sol` | 100% |
| `CuratioHook.sol` | 96% |
| `CuratioVault.sol` | 89% |
| `CuratioRebalancer.sol` | 80% |

To regenerate the numbers:

```bash
forge coverage --report summary
```

`CuratioRebalancer.sol` has the lowest coverage of the six contracts.

---

## 5. Roles & trust assumptions

| Role | Contract(s) | Powers |
|------|-------------|--------|
| `DEFAULT_ADMIN` | all | Wires the system. Vault changes are timelocked. Rebalancer `setVault()` is **immediate**. |
| `VAULT_MANAGER` | Access, Vault | Whitelist add (immediate) / remove (timelocked), `harvest`, deposit cap and pause, `deployToRebalancer` |
| `STRATEGIST` | Rebalancer | `rebalanceLiquidity` with self-chosen slippage caps |
| `REGISTRAR` | Registry | Strategist and pool management |
| `FEE_ADMIN` | DynamicFee | Set `performanceFeeBps` (≤ 30%) |
| Hook `owner` | Hook | Threshold proposals (2-day timelock), cardinality settings |

The timelocks only protect users if the admin is a multisig or contract whose actions they can watch.

---

## 6. Known limitations

- Disabling whitelisting lets anyone deposit and bypasses KYC; removed users cannot exit until re-whitelisted.
- Withdrawals that need the LP can revert while the hook charges MEV penalty fees.
- Keeper range selection uses a fixed width.
- Uncollected LP fees are not in valuation; they appear once the position is modified.
- Direct donations to the vault raise the share price and count as yield for the fee.
- Switching the vault's rebalancer stops counting funds still held by the old one, so move the funds first.
- `maxWithdraw` / `maxRedeem` do not reflect actual liquidity.
- The Rebalancer's `setVault()` and `setAutomationRegistry()` are not timelocked.
- `CuratioDynamicFee` rate, recipient and vault changes are immediate, and a rate change applies to gain not yet harvested (see the DynamicFee notes).
- Strategists choose their own slippage caps on the strategist path; only the keeper path has admin-set caps (`keeperMaxPay0/1`, default 0).
- Sandwich detection is a heuristic and can produce false positives (legitimate opposing flow or arbitrage).
- `followStrategist` stores a preference only; it has no on-chain effect on funds yet.
- Keeper rebalances are reported to the strategist registry under the automation registry's address, which is not a registered strategist, so they are not attributed to any strategist. The registry call is wrapped in `try/catch`.
- The stored fee decays by inactivity, not by time: `lastBlock` is refreshed on every swap, so a stored MID or HIGH fee steps back to BASE only after `blockDecayWindow` blocks without swaps, or when a later swap moves the price by a tier-changing amount.
- **The code is unaudited. Do not use it with real funds.**

### Weaknesses found by the Unichain fork tests (fixed)

Reading the oracle and fee code, then probing it on a Unichain fork, exposed four weaknesses. They are fixed in `CuratioHook`, and the old `test_finding_*` tests were flipped into `test_fix_*` regression tests.

1. **Default oracle depth too small for a 1-second chain.** With 100 observations and one write per second, a busy pool covered about 99 s, shorter than the 120 s TWAP window. The oracle never warmed, the TWAP guard was off, `getTwapTick` reverted, and the vault's `totalAssets()` reverted, halting deposits and withdrawals. *Fix:* `ChainRegistry.getInitialCardinality` gives 240 slots on Unichain, Unichain Sepolia, Arbitrum and Arbitrum Sepolia (cost: one cold SSTORE per slot at pool initialisation). *Tests:* `test_fix_unichainDefaultOracleDepth`, `test_fix_busyPool_oracleStaysWarm_vaultKeepsWorking`.
2. **Anyone could break the oracle by growing it after the ring wrapped.** `increaseObservationCardinality` is permissionless and applied the new size immediately. On a wrapped, warm ring this left an empty gap, `TwapOracle.binarySearch` reverted, and both `beforeSwap` and the vault's valuation halted. *Fix:* the Uniswap v3 rule in `TwapOracle.write`: the function only records `cardinalityNext`, and the ring switches to it when the write index reaches the last slot. *Test:* `test_fix_growthAfterWrap_isDeferred_oracleStaysHealthy`.
3. **A cheap sandwich blocked withdrawals for a whole decay window.** Any address could flag a block with two opposite swaps. The 10% penalty was also stored as the pool's current fee, so it kept applying for `blockDecayWindow` blocks (300 on Unichain) and made the rebalancer's TWAP price check reject LP-unwind withdrawals and keeper swaps. *Fix:* the penalty is enforced only for the rest of the flagged block through the per-block flag and is no longer written into `poolStates.fee`. An attacker can still make a withdrawal that needs a swap fail inside the flagged block (the cost is the swap fees), but a retry in the next block succeeds. Withdrawals covered by the rebalancer's idle asset were never affected. *Tests:* `test_fix_penaltyEndsWithTheFlaggedBlock`, `test_swapPath_withdrawNeedingSwap_revertsInSandwichBlock`, `test_swapPath_withdrawNeedingSwap_succeedsOneBlockAfterSandwich`, `test_swapPath_withdrawWithinIdle_worksDuringPenalty`, `test_swapPath_keeperTwoSidedRange_revertsInSandwichBlock`.
4. **Sandwich detection ignored token decimals.** The size gate compared the raw `amountSpecified` of each swap with one hook-wide `mevVolumeThreshold` (1 ether). On the real USDC (6 decimals) / WETH (18) pool a 20k USD USDC sandwich was not detected, a roughly 12k USD sandwich with a WETH leg was, and a threshold tuned for USDC flagged a 60 USD WETH round trip. *Fix:* the gate is now the cumulative absolute tick move of the block (`SandwichTracker.totalMove`, readable through `getBlockTickMove`) compared with `sandwichTickThreshold` (default 80 ticks). Ticks need no decimals and scale with the pool's depth. `mevVolumeThreshold` stays in the ABI but is deprecated. *Tests:* `test_decimals_usdcDenominatedSandwich_isDetected`, `test_decimals_wethDenominatedSandwich_isStillDetected`, `test_decimals_dustRoundTrips_areNotFlagged_inEitherDirection`, `test_decimals_sandwichTickThreshold_isTunableInTicks`.

---

## 7. Supported chains

Ethereum, Base, Optimism, Arbitrum, Unichain and their testnets (Sepolia, Base Sepolia, Arbitrum Sepolia, Unichain Sepolia). The hook deploys only against the canonical PoolManager for each chain (or on chain 31337 for local testing).

---

## 8. Getting started

Requirements: [Foundry](https://book.getfoundry.sh/), Solidity `^0.8.26`, and the OpenZeppelin, Uniswap v4-core and Chainlink contract dependencies.

```bash
git clone https://github.com/Emran468/curatio-protocol
cd curatio-protocol
forge install
forge build
forge test
```

### Suggested deployment order

1. `CuratioAccess(admin)`
2. `CuratioStrategistRegistry(admin)`
3. `CuratioHook(poolManager, owner)`, deployed to an address whose low bits match the hook permissions (CREATE2 / address mining, as required by Uniswap v4)
4. `CuratioRebalancer(...)` and `CuratioVault(asset, access, rebalancer, admin, depositCap)`. Each needs the other's address, so deploy the rebalancer first with a placeholder vault and call `setVault()` afterwards. (The fork tests instead predict the vault address from the deployer nonce and deploy the rebalancer and vault back to back.)
5. `CuratioDynamicFee(admin, vault, feeRecipient)`, then `vault.initializeFeeModule(feeModule)`
6. Configure:
   - `rebalancer.setManagedPool(key)` then `rebalancer.setAsset(asset)`
   - `rebalancer.setKeeperMaxPay(max0, max1)` and `setAutomationRegistry(...)`
   - `registry.authorizeRebalancer(rebalancer)` and `rebalancer.setStrategistRegistry(registry)`
   - Initialise the pool with the hook and wait at least 120 seconds for the TWAP to warm up before accepting deposits (until then `totalAssets()` reverts)
   - Whitelist users via `CuratioAccess.setWhitelistedUser`

---

## 9. Roadmap

**Phase 1: Hardening (current)**
- [x] Foundry unit, fuzz and end-to-end suite (501 tests, 18 suites)
- [x] Unichain mainnet-fork suite (55 distinct tests, 131 runs across 7 suites, including real USDC/WETH)
- [x] Stateful invariant suite for the hook (25 invariants, `depth = 400`)
- [x] Fix the weaknesses found by the fork tests (oracle depth, cardinality growth after wrap, block-scoped MEV penalty) and flip the finding tests into regression tests
- [x] Make sandwich detection decimals-independent (cumulative tick move vs `sandwichTickThreshold`)
- [ ] **Echidna property-based fuzzing** of the core invariants:
  - Vault: user actions never change the high-water mark; `harvest()` never charges more than the fee rate x gain; a sole depositor's deposit/redeem round trip is exact; no deposit or mint ever succeeds with zero shares.
  - Rebalancer: `totalManagedAssets()` is unaffected by same-block spot-price manipulation; `currentLiquidity` always matches the position held in the PoolManager.
  - Hook: the transient flag is always cleared after a completed swap; the fee is always one of the defined tiers; the oracle index never leaves `[0, cardinality)`.
  - Access: a pending removal never takes effect before its ETA.
- [ ] Independent security audit

**Phase 2: Launch**
- [ ] Testnet deployment and soak test (Unichain Sepolia)
- [ ] **Mainnet deployment on Unichain first**
- [ ] Full-match Sourcify verification of every mainnet contract
- [ ] Mainnet deployment on Base and Optimism

**Phase 3: Ecosystem**
- [ ] Developer integration guide with consumer-hook examples
- [ ] Governance mechanism for threshold updates (replacing the single-owner propose/execute flow in `CuratioHook`)

---

## License

MIT
