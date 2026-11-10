# Curatio Protocol

A permissioned, KYC-gated ERC-4626 vault that deploys liquidity into a **Uniswap v4** pool and actively manages the position. Swap fees adapt to volatility and MEV through a custom v4 hook, and the position is re-ranged by Chainlink Automation or by registered strategists.

> ⚠️ **Prototype. Unaudited.** Do not deploy with real funds. See [Trust assumptions](#trust-assumptions) and [Known limitations](#known-limitations).

---

## Architecture

```
                     ┌────────────────────────┐
   users ──────────► │  CuratioVault (L3)     │ ◄── CuratioAccess (L2)  whitelist / KYC
                     │  ERC-4626, cVAULT      │ ◄── CuratioDynamicFee (L5)  performance fee
                     └───────────┬────────────┘
                                 │ deployToRebalancer / returnToVault / totalManagedAssets
                     ┌───────────▼────────────┐        ┌──────────────────────────────┐
  Chainlink ───────► │  CuratioRebalancer (L4)│ ─────► │ CuratioStrategistRegistry (L6)│
  Automation /       │  one v4 LP position    │        └──────────────────────────────┘
  strategist         └───────────┬────────────┘
                                 │ unlock → modifyLiquidity / swap
                     ┌───────────▼────────────┐
                     │  Uniswap v4 PoolManager│
                     └───────────┬────────────┘
                                 │ beforeSwap / afterSwap / liquidity hooks
                     ┌───────────▼────────────┐
                     │  CuratioHook (L1)      │  dynamic fee · TWAP oracle · MEV detection
                     └────────────────────────┘
```

| Layer | Contract | Responsibility |
|------|----------|----------------|
| 1 | `CuratioHook` | v4 hook: dynamic LP fee, on-chain TWAP oracle, sandwich/MEV detection, position tracking |
| 2 | `CuratioAccess` | Role-based permissions and whitelist (token-gating) with a timelocked removal path |
| 3 | `CuratioVault` | Whitelisted ERC-4626 vault, TWAP-priced share accounting, high-water-mark performance fee |
| 4 | `CuratioRebalancer` | Moves a single LP position between tick ranges, unwinds for withdrawals, Chainlink Automation compatible |
| 5 | `CuratioDynamicFee` | Performance-fee engine used by the vault at `harvest()` |
| 6 | `CuratioStrategistRegistry` | Strategist registration, pool assignment, performance attribution |

---

## Contracts

### Layer 1 — `CuratioHook`

A Uniswap v4 hook with these permissions enabled: `afterInitialize`, `afterAddLiquidity`, `afterRemoveLiquidity`, `beforeSwap`, `afterSwap`.

**Dynamic fee** (returned from `beforeSwap` with the override flag):

| Fee | Value | Applied when |
|-----|-------|--------------|
| `BASE_FEE` | 0.30% (3000) | Calm market / fee decayed |
| `MID_VOLATILE_FEE` | 0.60% (6000) | Oracle cold (cannot verify price) or moderate tick move |
| `HIGH_VOLATILE_FEE` | 1.50% (15000) | Spot ≥ 200 ticks from TWAP, or large tick move |
| `MEV_PENALTY_FEE` | 10.00% (100000) | Spot ≥ 500 ticks from TWAP, or sandwich detected in the current block |

**TWAP oracle.** A Uniswap-v3-style `tickCumulative` ring buffer (`TwapOracle` library), written in `afterSwap`. Cardinality is pre-warmed at pool initialisation (`initialCardinality`, chosen per chain by `ChainRegistry`: **240 slots on chains with ~1 s timestamps** such as Unichain and Arbitrum, 100 elsewhere, because at most one observation is written per second and the window is 120 s). Anyone can grow it via `increaseObservationCardinality`, clamped per call by `maxCardinalityPerCall` (hard ceiling 1000); like Uniswap v3, the new size is only recorded and is applied when the write index reaches the end of the current ring. `isOracleWarm` / `getTwapTick` expose the oracle; the default window is 120 s. While the oracle is cold the hook charges the conservative mid fee instead of assuming safety.

**Sandwich detection (heuristic).** Within a block the hook tracks the first and last tick move and the cumulative absolute tick move. A direction reversal, once the swaps of the block have moved the price by at least `sandwichTickThreshold` ticks (default 80) in total, flags the block, and all further swaps in that block pay `MEV_PENALTY_FEE`. The size gate is price impact in ticks, not a raw token amount, so it is independent of token decimals and scales with each pool's depth (`mevVolumeThreshold` is deprecated and no longer used). The penalty lives only in the flagged block: it is not written into the stored pool fee, and `getCurrentFee` reports it only inside that block. This is a heuristic, not a classifier — legitimate opposing flow or arbitrage can trigger it.

**Transient storage (EIP-1153).** The hook uses `tstore` / `tload` to pass state from `beforeSwap` to `afterSwap` within the same swap, at no persistent-storage cost. Each value lives in a per-pool slot derived as `keccak256(abi.encodePacked(poolId, "flag"))` or `keccak256(abi.encodePacked(poolId, "tick"))`.

| Transient slot | Written in | Read in | Purpose |
|----------------|-----------|---------|---------|
| `flag` | `beforeSwap` (set to 1) | `afterSwap` (checked, then reset to 0) | Marks that a swap is in flight for this pool |
| `tick` | `beforeSwap` (current tick from `slot0`) | `afterSwap` | Pre-swap tick, used for the tick-delta fee, sandwich tracking and the oracle write |

The flag acts as a composability guard:

- If `beforeSwap` finds the flag already set, a second swap on the same pool started before the first one's `afterSwap`, and it reverts with `Transient storage dirty: composability violation`.
- If `afterSwap` finds the flag unset, it was called without a matching `beforeSwap` and reverts with `Composability violation: unexpected state`.
- The flag is set before the early-return paths in `beforeSwap` (zero-amount swap, sandwich-penalty block), so `afterSwap` always finds it and clears it.
- Because transient storage is wiped at the end of each transaction, a stale flag can never carry over into a later transaction.

The design assumes PoolManager always pairs `beforeSwap` with `afterSwap` for a pool before another swap on that pool begins. This holds under v4's unlock/settle model, but should be re-audited if PoolManager behaviour ever changes.

Transient opcodes need an EVM version with Cancun support (`evm_version = "cancun"` or later in `foundry.toml`) and Solidity 0.8.24+. The project targets `^0.8.26`, and the target chain must support EIP-1153.

**Chain safety.** `ChainRegistry` maps chain IDs to the canonical PoolManager and a per-chain `blockDecayWindow`. The constructor reverts if the supplied PoolManager does not match the chain (chain ID 31337 is exempt for local testing). Supported: Ethereum, Base, Optimism, Arbitrum, Unichain and their testnets.

**Admin.** Owner can tune cardinality settings and change fee thresholds through **propose → wait 2 days → execute** (`proposeTickThresholds`, `executeTickThresholds`, `cancelTickThresholdsProposal`).

### Layer 2 — `CuratioAccess`

- Roles: `DEFAULT_ADMIN_ROLE`, `VAULT_MANAGER_ROLE`, `STRATEGIST_ROLE`.
- **Adding** to the whitelist is immediate (`setWhitelistedUser`, `setWhitelistedUsersBatch`, max 200 per batch).
- **Removing** is a two-step flow with a `REMOVAL_TIMELOCK` of 2 days: `proposeRemoval` → `executeRemoval` (or `cancelRemoval`), so users have time to withdraw.
- Admin can toggle whitelisting off entirely (`toggleWhitelisting(false)` makes `isWhitelisted` return true for everyone).

### Layer 3 — `CuratioVault`

ERC-4626 share token `cVAULT`.

- **Gating.** `deposit`, `mint`, `withdraw` and `redeem` check the whitelist for caller, receiver and (on exit) owner.
- **Share pricing.** `totalAssets() = idle asset + rebalancer.totalManagedAssets()`. The second term is TWAP-priced and strict: if the TWAP is unavailable, `totalAssets()` reverts, which pauses deposits and withdrawals instead of mispricing shares. `maxDeposit` / `maxMint` return 0 in that case rather than reverting.
- **Inflation-attack protection.** `_decimalsOffset() = 6`, plus `ZeroShares` / `ZeroAssets` reverts so nobody pays for nothing.
- **Withdrawals.** If idle balance is short, the vault calls `rebalancer.returnToVault()`, which unwinds part of the LP and swaps into the asset (TWAP-checked).
- **Controls (manager).** `setDepositCap`, `setDepositsPaused` (withdrawals keep working while paused), `deployToRebalancer`, `harvest`.
- **Performance fee.** `harvest()` compares share price with a high-water mark and charges the fee module's rate on the gain above it, paid by minting shares to `feeRecipient`. First harvest after a fee-module change only records the baseline. Fee is capped at `MAX_PERFORMANCE_FEE_BPS` (30%) of yield regardless of the module.
- **Timelocked admin changes (2 days).** Access contract, rebalancer and fee module each follow `propose… → execute… / cancel…`. The one immediate action is the one-time `initializeFeeModule()` at deployment.
- **Copy-LP.** `followStrategist` / `unfollowStrategist` record a depositor's chosen strategist (currently an on-chain preference only).

### Layer 4 — `CuratioRebalancer`

Manages one LP position `(managedPool, tickLower, tickUpper, salt 0)`.

- **Rebalance.** Removes *all* existing liquidity and adds `newLiquidity` in the new range inside a single `unlock`. Any token shortfall is covered by a TWAP-checked exact-output swap. Caps on the *net* tokens paid (`maxPay0`, `maxPay1`) apply to the final payment, swap cost included.
- **Strategist path.** `rebalanceLiquidity(...)` (needs `STRATEGIST_ROLE`) with caller-chosen caps.
- **Keeper path.** `checkUpkeep` triggers when the hook's fee is ≥ `MID_VOLATILE_FEE` or spot diverges from the TWAP by more than 200 ticks; `performUpkeep` (registry only) recentres the range (±2 tick spacings, ±3 if TWAP diverged) using admin-set `keeperMaxPay0/1`. **These default to 0, so keeper rebalances that must pay tokens revert until the admin sets caps.**
- **Valuation.** `totalManagedAssets()` prices idle balances of both tokens and the LP position at the hook's TWAP, never at spot, and reverts if the TWAP is unavailable. Uncollected LP fees are not counted.
- **Withdrawals.** `returnToVault` unwinds the needed share of the LP (plus a 1% buffer) and swaps into the asset. Swaps revert with `SwapPriceDeviation` if the execution price strays from the TWAP by more than `maxSwapSlippageBps` (default 3%), e.g. during MEV-penalty windows.
- **Sizing helper.** `quoteLiquidityForValue` returns the liquidity that fits a given asset value for a range.
- **Hook change** is timelocked (`proposeHook` → `executeHook`, 2 days).

### Layer 5 — `CuratioDynamicFee`

Performance-fee module for the vault: default 10% (`performanceFeeBps = 1000`), hard cap 30%. `calculatePerformanceFee` is a pure quote; `reportPerformanceFeeCharged` is vault-only and rejects any fee above the current rate × yield. Swap fees are *not* handled here (see the hook).

### Layer 6 — `CuratioStrategistRegistry`

Registers strategists, assigns pools to them (inactive strategists cannot be assigned), reassigns or bulk-migrates pools, and records rebalance counts and fees attributed to each strategist (written by the rebalancer, which holds `REBALANCER_ROLE`). `getActiveStrategists()` filters out deactivated ones.

---

## Trust assumptions

- **Admin keys are powerful.** The admin controls the rebalancer (which prices every share), the access contract (which gates exits) and the fee module. Changes on the vault are timelocked so users can exit, but this only helps if the admin is a multisig or contract whose actions users can monitor.
- **Rebalancer admin actions are not all timelocked.** `setVault()` is immediate and `returnToVault()` pays the current vault address; only the hook (TWAP source) change is timelocked.
- **Whitelist gates exits.** Removing a user (after the 2-day delay) blocks their withdrawals until they are re-whitelisted. Disabling whitelisting lets anyone deposit.
- **Strategists pick their own slippage caps** on the strategist path.
- **Donations.** Anyone can donate the asset to the vault, which raises share price and, with a fee module set, counts as yield.

## Known limitations

- Withdrawals that need the LP can revert inside a block in which the hook charges the MEV-penalty fee (a flagged sandwich block, or spot ≥ 500 ticks from the TWAP) and retry succeeds in the next block; `maxWithdraw` / `maxRedeem` do not reflect available liquidity.
- Keeper range selection uses a fixed width.
- Sandwich detection is heuristic and may produce false positives.
- `mevVolumeThreshold` is kept for ABI and timelock compatibility but is **deprecated and no longer used**: sandwich detection now compares the cumulative tick move of the block with `sandwichTickThreshold`.
- `followStrategist` stores a preference only; it has no on-chain effect on funds yet.
- Switching the vault's rebalancer stops counting what the old one holds — move funds first.
- Keeper rebalances are reported to the strategist registry under the automation registry's address, which is not a registered strategist, so they are not attributed to any strategist (the registry call is wrapped in `try/catch`).
- The stored fee decays by inactivity, not by time: `lastBlock` is refreshed on every swap, so a stored `MID` or `HIGH` fee only steps back to `BASE` after a gap of `blockDecayWindow` blocks without swaps, or when a later swap moves the price by a tier-changing amount. (By reading the code; not covered by a test.)
- Unaudited.

### Weaknesses found by the Unichain fork tests (fixed)

Reading the oracle and fee code, then probing it on a Unichain fork, exposed four weaknesses. They are fixed in `CuratioHook`; the old `test_finding_*` tests were flipped into `test_fix_*` regression tests in `CuratioForkFindingsTest`, `CuratioForkSwapPathTest` and `CuratioForkDecimalsTest`.

1. **Default oracle depth too small for a 1-second chain (fixed).** With 100 observations and one write per second, a busy pool only covered about 99 s, shorter than the 120 s TWAP window. The oracle never warmed, the TWAP guard was off, and `getTwapTick` reverted, so the vault's `totalAssets()` reverted and deposits and withdrawals halted. *Fix:* `ChainRegistry.getInitialCardinality` gives 240 slots on Unichain, Unichain Sepolia, Arbitrum and Arbitrum Sepolia (cost: one cold SSTORE per slot at pool initialisation). *Tests:* `test_fix_unichainDefaultOracleDepth`, `test_fix_busyPool_oracleStaysWarm_vaultKeepsWorking`.

2. **Anyone could break the oracle by growing it after the ring wrapped (fixed).** `increaseObservationCardinality` is permissionless and applied the new size immediately. On a wrapped, warm ring this left an empty gap in the middle of the buffer, `TwapOracle.binarySearch` reverted, and both `beforeSwap` and the vault's valuation halted. *Fix:* Uniswap v3 rule in `TwapOracle.write`: the function only records `cardinalityNext`; the ring switches to it when the write index reaches the last slot of the current ring. *Test:* `test_fix_growthAfterWrap_isDeferred_oracleStaysHealthy`.

3. **A cheap sandwich blocked withdrawals for a whole decay window (fixed).** Any address could flag a block with two opposite swaps for the price of the swap fees. The 10% penalty was also stored as the pool's current fee and re-stored by every calm swap, so it kept applying for `blockDecayWindow` blocks (300 on Unichain) and made the rebalancer's TWAP price check reject LP-unwind withdrawals and keeper swaps. *Fix:* the penalty is enforced only for the rest of the flagged block through the per-block flag; it is no longer written into `poolStates.fee`. An attacker can still make a withdrawal that needs a swap fail inside the flagged block (the cost is the swap fees), but a retry in the next block succeeds. Withdrawals covered by the rebalancer's idle asset were never affected. *Tests:* `test_fix_penaltyEndsWithTheFlaggedBlock`, `test_swapPath_withdrawNeedingSwap_revertsInSandwichBlock`, `test_swapPath_withdrawNeedingSwap_succeedsOneBlockAfterSandwich`, `test_swapPath_withdrawWithinIdle_worksDuringPenalty`, `test_swapPath_keeperTwoSidedRange_revertsInSandwichBlock`.

4. **Sandwich detection ignored token decimals (fixed).** The size gate compared the raw `amountSpecified` of each swap with one hook-wide `mevVolumeThreshold` (1 ether). On the real USDC (6 decimals) / WETH (18) pool a \$20k USDC sandwich was not detected, a ~\$12k sandwich with a WETH leg was, and a threshold tuned for USDC flagged a \$60 WETH round trip. *Fix:* the gate is now the cumulative absolute tick move of the block (`SandwichTracker.totalMove`, packed into previously unused bits, readable through `getBlockTickMove`) compared with `sandwichTickThreshold` (default 80 ticks). Ticks need no decimals and scale with the pool's depth. `mevVolumeThreshold` stays in the ABI but is deprecated. *Tests:* `test_decimals_usdcDenominatedSandwich_isDetected`, `test_decimals_wethDenominatedSandwich_isStillDetected`, `test_decimals_dustRoundTrips_areNotFlagged_inEitherDirection`, `test_decimals_sandwichTickThreshold_isTunableInTicks`.

---

## Getting started

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
4. `CuratioRebalancer(...)` and `CuratioVault(asset, access, rebalancer, admin, depositCap)`. Each takes the other's address, so deploy the rebalancer first with a placeholder vault and call `setVault()` afterwards. (The fork tests instead predict the vault address from the deployer nonce and deploy the rebalancer and vault back to back.)
5. `CuratioDynamicFee(admin, vault, feeRecipient)`, then `vault.initializeFeeModule(feeModule)`
6. Configure:
   - `rebalancer.setManagedPool(key)` then `rebalancer.setAsset(asset)`
   - `rebalancer.setKeeperMaxPay(max0, max1)` and `setAutomationRegistry(...)`
   - `registry.authorizeRebalancer(rebalancer)` and `rebalancer.setStrategistRegistry(registry)`
   - Initialise the pool with the hook and allow the TWAP to warm up before accepting deposits
   - Whitelist users via `CuratioAccess.setWhitelistedUser`

---

## Testing

The Foundry suite currently reports **493 passing tests across 18 suites, 0 failures**. In addition, **45 mainnet-fork tests across 6 suites** pass against Unichain, and **25 stateful invariants** fuzz the hook (see below).

### Coverage

| Contract | Coverage |
|----------|---------:|
| `CuratioAccess` | 100% |
| `CuratioDynamicFee` | 100% |
| `CuratioStrategistRegistry` | 100% |
| `CuratioHook` | 96% |
| `CuratioVault` | 89% |
| `CuratioRebalancer` | 80% |

These figures come from the last coverage run, taken before the hook changes described under [Known limitations](#weaknesses-found-by-the-unichain-fork-tests-fixed). Regenerate with `forge coverage`.

### Test suites

| Area | Suite(s) |
|------|----------|
| Hook (fees, oracle, sandwich, chains, transient guard) | `CuratioHookTest`, `CardinalityGasDoSTest`, `GasGriefingTest` |
| Access / whitelist | `CuratioAccessTest` |
| Vault (gating, caps, pause, timelocks) | `CuratioVaultTest` |
| Inflation attack and share maths (incl. fuzz) | `CuratioVaultInflationTest` |
| Harvest / high-water mark (incl. fuzz) | `CuratioVaultHarvestTest` |
| Rebalancer (unit, upkeep, valuation, real PoolManager) | `CuratioRebalancerTest`, `CuratioRebalancerValuationTest`, `CuratioRebalancerRealPMTest` |
| Swap / unwind paths | `CuratioSwapE2ETest` |
| Performance-fee module | `CuratioDynamicFeeTest` |
| Registry | `CuratioStrategistRegistryTest` |
| End-to-end | `CuratioVaultRebalancerE2ETest`, `CuratioFullStackRealHookE2ETest`, `CuratioFullProtocolE2ETest` |

### Mainnet-fork tests (Unichain)

45 tests in 6 suites, all passing. They run against the **real Unichain PoolManager** (`0x1F98…0004`, chain id 130) with a freshly deployed Curatio stack and a new pool that uses the hook, so no existing Uniswap pool is touched. Fees are read from the PoolManager's own `Swap` event, so they show the fee actually charged. Block time on Unichain is 1 s, so the tests move blocks and seconds together.

| Suite (`test/fork/`) | Tests | What it covers |
|----------------------|------:|----------------|
| `CuratioForkTest` | 16 | Chain guard and wrong-PoolManager revert, hook initialisation, fee tiers (cold 6000, calm 3000, escalation to 15000 and decay after 300 blocks), TWAP-based MEV penalty, sandwich detection, oracle observations, vault deposit/redeem, LP creation in the real PoolManager, partial and full unwind, harvest, `checkUpkeep` |
| `CuratioForkKeeperTest` | 6 | `performUpkeep`: registry-only access, default caps of 0 revert with `SlippageExceeded`, position opened around the TWAP, "too soon" and "range unchanged" skips, no strategist attribution |
| `CuratioForkRealTokensTest` | 7 | Real Unichain USDC (6 decimals) and WETH (18) in a ~\$3000 pool: 12-decimal shares, fee tiers at tick ~196k, TWAP valuation of idle WETH, single-sided USDC LP, partial withdraw and full redeem |
| `CuratioForkSwapPathTest` | 6 | Paths that swap inside the unlock: withdrawals that unwind a two-sided LP and keeper rebalances into a range containing the price, including their failure inside a flagged sandwich block and recovery one block later |
| `CuratioForkFindingsTest` | 6 | Two pools sharing one hook stay isolated, timelocked thresholds change real fees, and regression tests for the three fixes listed under [Known limitations](#weaknesses-found-by-the-unichain-fork-tests-fixed) |
| `CuratioForkDecimalsTest` | 4 | Real USDC/WETH: sandwich detection is decimals-independent (a \$20k USDC sandwich and a ~\$12k WETH sandwich are both detected), \$60 dust round trips are not false positives in either direction, and `sandwichTickThreshold` is tunable through the timelock |

**Setup.** Add a profile to `foundry.toml` (the default profile points `test` at `test/foundry`):

```toml
[profile.fork]
test = "test/fork"
```

Put the RPC URL in a `.env` file (or export it). The public endpoint needs no account; if you hit rate limits, pin the block with `UNICHAIN_FORK_BLOCK` so Foundry caches the state.

```
UNICHAIN_RPC=https://mainnet.unichain.org
```

Without `UNICHAIN_RPC` every fork test is skipped.

**Run.** `CuratioForkKeeperTest`, `CuratioForkSwapPathTest` and `CuratioForkFindingsTest` inherit the fixture of `CuratioForkTest`, so filter by test name to run only their own tests:

```bash
# bash
export FOUNDRY_PROFILE=fork
forge test --match-path test/fork/CuratioForkTest.t.sol -vv
forge test --match-path test/fork/CuratioForkKeeperTest.t.sol   --match-test test_keeper -vv
forge test --match-path test/fork/CuratioForkRealTokensTest.t.sol -vv
forge test --match-path test/fork/CuratioForkSwapPathTest.t.sol --match-test test_swapPath -vv
forge test --match-path test/fork/CuratioForkFindingsTest.t.sol --match-test "test_more|test_fix" -vv
forge test --match-path test/fork/CuratioForkDecimalsTest.t.sol --match-test test_decimals -vv
```

```powershell
# PowerShell
$env:FOUNDRY_PROFILE = "fork"
forge test --match-path test/fork/CuratioForkTest.t.sol -vv
```

Clear the profile afterwards (`unset FOUNDRY_PROFILE` / `Remove-Item Env:FOUNDRY_PROFILE`) so a plain `forge test` goes back to `test/foundry`.

**Not yet covered by fork tests:** USDC blacklist behaviour.

### Invariant tests (stateful fuzzing)

25 Foundry invariants in `test/invariant/` (`CuratioHookInvariantTest` driven by `CuratioHandler`) fuzz the hook against a local PoolManager with real swap and liquidity routers. The handler performs random swaps (exact-in and exact-out, both directions, 0 to 30 blocks apart so that same-block sandwiches happen), liquidity adds and removes, oracle growth by an arbitrary caller, owner timelock actions and calls from non-owners. It mirrors every action in ghost variables, so the invariants compare the hook's state with what should have happened.

| Area | What is checked |
|------|-----------------|
| Pool and fees | tick and price stay valid; the hook's `lastTick`, `lastBlock` and `lastTimestamp` match the pool and the last swap; stored and current fees are always one of the defined tiers; the fee decays to `BASE_FEE` after the decay window |
| MEV penalty | the penalty is never stored in the pool state; `getCurrentFee` reports it only in a block that already had a swap; the tick move recorded for a block is 0 unless a swap happened in it |
| Volume and tracker | per-block volume and the sandwich tracker match the handler's ghost values |
| Liquidity | stored positions match the ghost accounting; active liquidity never exceeds what was added; the seed liquidity floor holds |
| Oracle | `index < cardinality <= cardinalityNext`; cardinality never decreases; per-call growth cap holds; a warm oracle is always readable by `getTwapTick` (this is the invariant that would catch an oracle broken by growing it after the ring wrapped) |
| Liveness and gas | no swap reverts inside the hook; swap gas stays bounded |
| Governance | threshold ordering, the 2-day timelock, owner-only functions reject strangers, cardinality caps stay within the hard ceiling |

Swap reverts are classified: PoolManager wraps every revert that comes from a hook in `WrappedError`, so those count as hook failures and fail `invariant_swapsNeverRevert` (with the failing swap and revert data logged). Reverts that come from the PoolManager or the router (for example the swap maths at extreme prices) are counted separately and reported by `afterInvariant` without failing the run.

**Setup.** Add a profile to `foundry.toml` (the default profile's `[profile.default.invariant]` section sets `runs = 256`, `depth = 400`, `fail_on_revert = true`):

```toml
[profile.invariant]
test = "test/invariant"
```

**Run.**

```bash
# bash
FOUNDRY_PROFILE=invariant forge test --match-path test/invariant/CuratioHookInvariantTest.t.sol -vv
```

```powershell
# PowerShell
$env:FOUNDRY_PROFILE = "invariant"
forge test --match-path test/invariant/CuratioHookInvariantTest.t.sol -vv
```

A full run is slow (25 invariants x 256 runs x 400 calls). For a quick pass set `FOUNDRY_INVARIANT_RUNS=32`. The output is long because `bound()` logs every call; redirect it to a file and search for `PASS` and `FAIL`.

The `test/Echidna/` contracts are harnesses for Echidna and are not run by Foundry.

---

## Roadmap

**Phase 1: Hardening (current)**
- [x] Foundry unit, fuzz and end-to-end suite (493 tests, 18 suites)
- [x] Unichain mainnet-fork suite (45 tests, 6 suites, including real USDC/WETH)
- [x] Stateful invariant suite for the hook (25 invariants, `depth = 400`)
- [x] Fix the three weaknesses found by the fork tests (oracle depth, cardinality growth after wrap, block-scoped MEV penalty) and flip the finding tests into regression tests
- [x] Make sandwich detection decimals-independent (cumulative tick move vs `sandwichTickThreshold`; regression tests in `CuratioForkDecimalsTest`)
- [ ] **Echidna property-based fuzzing** of the core invariants:
  - Vault: user actions never change the high-water mark; `harvest()` never charges more than the fee rate × gain; a sole depositor's deposit/redeem round trip is exact.
  - Vault: no deposit or mint ever succeeds with zero shares.
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
