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

**TWAP oracle.** A Uniswap-v3-style `tickCumulative` ring buffer (`TwapOracle` library), written in `afterSwap`. Cardinality is pre-warmed at pool initialisation (`initialCardinality`, default 100) and can be grown by anyone via `increaseObservationCardinality`, clamped per call by `maxCardinalityPerCall` (hard ceiling 1000). `isOracleWarm` / `getTwapTick` expose the oracle; the default window is 120 s. While the oracle is cold the hook charges the conservative mid fee instead of assuming safety.

**Sandwich detection (heuristic).** Within a block the hook tracks the first and last tick move and cumulative volume. A direction reversal with volume above `mevVolumeThreshold` flags the block, and all further swaps in that block pay `MEV_PENALTY_FEE`. This is a heuristic, not a classifier — legitimate opposing flow or arbitrage can trigger it.

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

- Withdrawals that need the LP can revert while the hook charges MEV-penalty fees; `maxWithdraw` / `maxRedeem` do not reflect available liquidity.
- Keeper range selection uses a fixed width.
- Sandwich detection is heuristic and may produce false positives.
- The `sandwichTickThreshold` parameter is stored and timelocked but is not currently used in the detection logic.
- `followStrategist` stores a preference only; it has no on-chain effect on funds yet.
- Switching the vault's rebalancer stops counting what the old one holds — move funds first.
- Unaudited.

---

## Getting started

Requirements: [Foundry](https://book.getfoundry.sh/), Solidity `^0.8.26`, and the OpenZeppelin, Uniswap v4-core and Chainlink contract dependencies.

```bash
git clone https://github.com/Emran468/curatio-protocol
cd curatio-protocol
forge install
forge build
forge test

### Suggested deployment order

1. `CuratioAccess(admin)`
2. `CuratioStrategistRegistry(admin)`
3. `CuratioHook(poolManager, owner)`, deployed to an address whose low bits match the hook permissions (CREATE2 / address mining, as required by Uniswap v4)
4. `CuratioRebalancer(...)` and `CuratioVault(asset, access, rebalancer, admin, depositCap)`. Each takes the other's address, so deploy the rebalancer first with a placeholder vault and call `setVault()` afterwards
5. `CuratioDynamicFee(admin, vault, feeRecipient)`, then `vault.initializeFeeModule(feeModule)`
6. Configure:
   - `rebalancer.setManagedPool(key)` then `rebalancer.setAsset(asset)`
   - `rebalancer.setKeeperMaxPay(max0, max1)` and `setAutomationRegistry(...)`
   - `registry.authorizeRebalancer(rebalancer)` and `rebalancer.setStrategistRegistry(registry)`
   - Initialise the pool with the hook and allow the TWAP to warm up before accepting deposits
   - Whitelist users via `CuratioAccess.setWhitelistedUser`

---

## Testing

The Foundry suite currently reports **490 passing tests across 18 suites, 0 failures**.

### Coverage

| Contract | Coverage |
|----------|---------:|
| `CuratioAccess` | 100% |
| `CuratioDynamicFee` | 100% |
| `CuratioStrategistRegistry` | 100% |
| `CuratioHook` | 96% |
| `CuratioVault` | 89% |
| `CuratioRebalancer` | 80% |

Regenerate with `forge coverage`.

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

---

## Roadmap

**Phase 1: Hardening (current)**
- [x] Foundry unit, fuzz and end-to-end suite (490 tests, 18 suites)
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
