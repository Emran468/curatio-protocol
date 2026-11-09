// // SPDX-License-Identifier: MIT
// pragma solidity ^0.8.26;

// /*
//     CuratioHookEchidnaTest — ASSERTION mode.
//     Rules used throughout:
//       * every check is an assert (echidna_* properties are NOT evaluated in assertion mode)
//       * every test function is non-view (counters double as canaries)
//       * expected reverts are matched on the exact revert string, never just "!success"
//       * a valid swap must never revert (no silent `return` on failure)
//       * every path has a counter and a canary_* function that FAILS once the path was reached
//     Needs echidna.yaml with testMode: assertion (see the answer for suggested time settings).
// */

// import {CuratioHook} from "../../src/CuratioHook.sol";
// import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
// import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
// import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
// import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
// import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
// import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
// import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
// import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
// import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

// // ─── Minimal PoolManager mock ──────────────────────────────────────────────
// contract MockPoolManager {
//     using PoolIdLibrary for PoolKey;

//     struct Slot0 {
//         uint160 sqrtPriceX96;
//         int24 tick;
//         uint24 protocolFee;
//         uint24 lpFee;
//     }

//     mapping(bytes32 => Slot0) public slot0Of;
//     mapping(bytes32 => uint128) public liquidityOf;

//     function _getSlot0StorageSlot(PoolId poolId) internal pure returns (bytes32) {
//         return keccak256(abi.encode(PoolId.unwrap(poolId), uint256(6)));
//     }

//     function setSlot0(PoolId poolId, uint160 sqrtPriceX96, int24 tick) public {
//         slot0Of[PoolId.unwrap(poolId)] = Slot0(sqrtPriceX96, tick, 0, 0);

//         bytes32 packedSlot0 = bytes32(
//             uint256(sqrtPriceX96) | (uint256(uint24(tick)) << 160) | (uint256(0) << 184) | (uint256(0) << 208)
//         );

//         bytes32 slot0Loc = keccak256(abi.encode(PoolId.unwrap(poolId), uint256(0)));
//         bytes32 slot6Loc = keccak256(abi.encode(PoolId.unwrap(poolId), uint256(6)));

//         assembly {
//             sstore(slot0Loc, packedSlot0)
//             sstore(slot6Loc, packedSlot0)
//         }
//     }

//     function setLiquidity(PoolId poolId, uint128 liquidity) external {
//         liquidityOf[PoolId.unwrap(poolId)] = liquidity;
//     }

//     function getSlot0(PoolId poolId) external view returns (uint160, int24, uint24, uint24) {
//         Slot0 memory s = slot0Of[PoolId.unwrap(poolId)];
//         return (s.sqrtPriceX96, s.tick, s.protocolFee, s.lpFee);
//     }

//     function getLiquidity(PoolId poolId) external view returns (uint128) {
//         return liquidityOf[PoolId.unwrap(poolId)];
//     }

//     // ── Drivers ──

//     function driveAfterInitialize(address hook, PoolKey calldata key, uint160 sqrtPriceX96, int24 tick) external {
//         setSlot0(key.toId(), sqrtPriceX96, tick);
//         IHooks(hook).afterInitialize(address(this), key, sqrtPriceX96, tick);
//     }

//     function driveBeforeSwap(address hook, PoolKey calldata key, SwapParams calldata params)
//         external
//         returns (bytes4, BeforeSwapDelta, uint24)
//     {
//         return IHooks(hook).beforeSwap(address(this), key, params, "");
//     }

//     function driveAfterSwap(address hook, PoolKey calldata key, SwapParams calldata params)
//         external
//         returns (bytes4, int128)
//     {
//         return IHooks(hook).afterSwap(address(this), key, params, BalanceDelta.wrap(0), "");
//     }

//     function driveFullSwap(address hook, PoolKey calldata key, SwapParams calldata params, int24 postSwapTick)
//         external
//         returns (uint24 feeApplied)
//     {
//         (,, uint24 fee) = IHooks(hook).beforeSwap(address(this), key, params, "");
//         feeApplied = fee & ~LPFeeLibrary.OVERRIDE_FEE_FLAG;

//         PoolId poolId = key.toId();

//         uint160 currentPrice = slot0Of[PoolId.unwrap(poolId)].sqrtPriceX96;
//         if (currentPrice == 0) currentPrice = 79228162514264337593543950336;

//         setSlot0(poolId, currentPrice, postSwapTick);

//         IHooks(hook).afterSwap(address(this), key, params, BalanceDelta.wrap(0), "");
//     }

//     /// @dev beforeSwap twice in ONE transaction with no afterSwap in between.
//     ///      The hook must revert on the second call (transient-storage dirty guard).
//     function driveBeforeSwapTwice(address hook, PoolKey calldata key, SwapParams calldata params) external {
//         IHooks(hook).beforeSwap(address(this), key, params, "");
//         IHooks(hook).beforeSwap(address(this), key, params, "");
//     }

//     /// @dev Two complete swaps (pre -> a, then a -> b) and a THIRD beforeSwap, all in one transaction.
//     ///      Returns the fee the third swap is charged. Also proves the transient flag is cleared by afterSwap
//     ///      (otherwise the second beforeSwap would revert).
//     function driveSandwich(
//         address hook,
//         PoolKey calldata key,
//         SwapParams calldata params,
//         int24 preTick,
//         int24 tickA,
//         int24 tickB
//     ) external returns (uint24 fee3) {
//         PoolId poolId = key.toId();
//         uint160 price = 79228162514264337593543950336;

//         setSlot0(poolId, price, preTick);
//         IHooks(hook).beforeSwap(address(this), key, params, "");
//         setSlot0(poolId, price, tickA);
//         IHooks(hook).afterSwap(address(this), key, params, BalanceDelta.wrap(0), "");

//         IHooks(hook).beforeSwap(address(this), key, params, "");
//         setSlot0(poolId, price, tickB);
//         IHooks(hook).afterSwap(address(this), key, params, BalanceDelta.wrap(0), "");

//         (,, uint24 fee) = IHooks(hook).beforeSwap(address(this), key, params, "");
//         fee3 = fee & ~LPFeeLibrary.OVERRIDE_FEE_FLAG;
//         IHooks(hook).afterSwap(address(this), key, params, BalanceDelta.wrap(0), "");
//     }

//     function driveAfterAddLiquidity(address hook, PoolKey calldata key, ModifyLiquidityParams calldata params)
//         external
//     {
//         IHooks(hook).afterAddLiquidity(address(this), key, params, BalanceDelta.wrap(0), BalanceDelta.wrap(0), "");
//     }

//     function driveAfterRemoveLiquidity(address hook, PoolKey calldata key, ModifyLiquidityParams calldata params)
//         external
//     {
//         IHooks(hook).afterRemoveLiquidity(address(this), key, params, BalanceDelta.wrap(0), BalanceDelta.wrap(0), "");
//     }

//     // ── Extsload ──

//     function extsload(bytes32 slot) external view returns (bytes32 value) {
//         assembly {
//             value := sload(slot)
//         }
//     }

//     function extsload(bytes32[] calldata slots) external view returns (bytes32[] memory values) {
//         values = new bytes32[](slots.length);
//         for (uint256 i = 0; i < slots.length; i++) {
//             bytes32 slot = slots[i];
//             bytes32 value;
//             assembly {
//                 value := sload(slot)
//             }
//             values[i] = value;
//         }
//     }
// }

// // ─── Harness ───────────────────────────────────────────────────────────────
// contract CuratioHookHarness is CuratioHook {
//     constructor(IPoolManager pm, address owner_) CuratioHook(pm, owner_) {}

//     function exposed_packTracker(SandwichTracker memory t) external pure returns (uint256) {
//         return _packTracker(t);
//     }

//     function exposed_unpackTracker(uint256 packed) external pure returns (SandwichTracker memory) {
//         return _unpackTracker(packed);
//     }

//     function exposed_computeFee(uint24 tickDelta, uint256 blockDelta, uint24 currentFee)
//         external
//         view
//         returns (uint24)
//     {
//         return _computeFee(tickDelta, blockDelta, currentFee);
//     }

//     function exposed_abs(int24 n) external pure returns (uint24) {
//         return abs(n);
//     }

//     function _skipChainCheck() internal pure override returns (bool) {
//         return true;
//     }
// }

// // ─── Caller with no rights: every privileged call must revert ──────────────
// contract HookAttacker {
//     CuratioHookHarness public immutable hook;

//     constructor(CuratioHookHarness h) {
//         hook = h;
//     }

//     /// @return succeeded true if ANY privileged call went through (that would be a bug)
//     function probe(PoolKey calldata key, SwapParams calldata sp, ModifyLiquidityParams calldata mp)
//         external
//         returns (bool succeeded)
//     {
//         try hook.setInitialCardinality(10) { return true; } catch {}
//         try hook.setMaxCardinalityPerCall(10) { return true; } catch {}
//         try hook.proposeTickThresholds(2, 1, 1, 1) { return true; } catch {}
//         try hook.executeTickThresholds() { return true; } catch {}
//         try hook.cancelTickThresholdsProposal() { return true; } catch {}
//         try hook.transferOwnership(address(this)) { return true; } catch {}
//         try hook.afterInitialize(address(this), key, 0, 0) { return true; } catch {}
//         try hook.beforeSwap(address(this), key, sp, "") { return true; } catch {}
//         try hook.afterSwap(address(this), key, sp, BalanceDelta.wrap(0), "") { return true; } catch {}
//         try hook.afterAddLiquidity(address(this), key, mp, BalanceDelta.wrap(0), BalanceDelta.wrap(0), "") {
//             return true;
//         } catch {}
//         try hook.afterRemoveLiquidity(address(this), key, mp, BalanceDelta.wrap(0), BalanceDelta.wrap(0), "") {
//             return true;
//         } catch {}
//         return false;
//     }
// }

// // ─── CREATE2 salt miner (unchanged) ────────────────────────────────────────
// library HookMiner {
//     uint160 internal constant REQUIRED_FLAGS =
//         uint160(1 << 12) // AFTER_INITIALIZE_FLAG
//         | uint160(1 << 10) // AFTER_ADD_LIQUIDITY_FLAG
//         | uint160(1 << 8) // AFTER_REMOVE_LIQUIDITY_FLAG
//         | uint160(1 << 7) // BEFORE_SWAP_FLAG
//         | uint160(1 << 6); // AFTER_SWAP_FLAG

//     uint160 internal constant ALL_HOOK_MASK = uint160((1 << 14) - 1);

//     function find(address deployer, bytes memory creationCode, bytes memory constructorArgs)
//         internal
//         pure
//         returns (bytes32 salt, address hookAddress)
//     {
//         bytes memory initCode = abi.encodePacked(creationCode, constructorArgs);
//         bytes32 initCodeHash = keccak256(initCode);

//         for (uint256 i = 0; i < 200_00; i++) {
//             salt = bytes32(i);
//             hookAddress = computeAddress(deployer, salt, initCodeHash);
//             if (uint160(hookAddress) & ALL_HOOK_MASK == REQUIRED_FLAGS) {
//                 return (salt, hookAddress);
//             }
//         }
//         revert("HookMiner: no salt found in range");
//     }

//     function computeAddress(address deployer, bytes32 salt, bytes32 initCodeHash) internal pure returns (address) {
//         return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
//     }
// }

// // ─── Echidna test ──────────────────────────────────────────────────────────
// contract CuratioHookEchidnaTest {
//     using PoolIdLibrary for PoolKey;

//     uint160 internal constant PRICE_1_1 = 79228162514264337593543950336;
//     int256 internal constant MAX_TICK = 887272;
//     /// @dev Tiny ring so it WRAPS after 3 swaps (the default 100 slots would need 100 swaps).
//     uint16 internal constant TEST_CARDINALITY = 3;

//     MockPoolManager public poolManager;
//     CuratioHookHarness public hook;
//     HookAttacker public attacker;
//     PoolKey internal poolKey;
//     PoolId internal poolId;

//     // ── ghost state ──
//     int256 internal minTickSeen; // every tick ever handed to the pool manager mock
//     int256 internal maxTickSeen;
//     int24 internal lastTickGhost;
//     uint16 internal lastCardinalityNext;
//     bool internal grewAfterWrap;
//     uint128[4] internal ghostLiq;

//     // ── reachability counters (each has a canary at the bottom) ──
//     uint256 public swapsOk;
//     uint256 public swapsWarm;
//     uint256 public swapsCold;
//     uint256 public tierBase;
//     uint256 public tierMid;
//     uint256 public tierHigh;
//     uint256 public tierMev;
//     uint256 public oracleWrites;
//     uint256 public sandwichScenarios;
//     uint256 public sandwichPenalized;
//     uint256 public guardBeforeTwice;
//     uint256 public guardAfterAlone;
//     uint256 public thresholdProposals;
//     uint256 public badProposalRejected;
//     uint256 public thresholdExecutions;
//     uint256 public earlyExecRejected;
//     uint256 public thresholdCancels;
//     uint256 public growthOk;
//     uint256 public growthAfterWrap;
//     uint256 public swapsAfterWrapGrowth;
//     uint256 public warmTwapChecks;
//     uint256 public notWarmChecks;
//     uint256 public twapBoundsChecks;
//     uint256 public liqAdds;
//     uint256 public liqRemoves;
//     uint256 public liqOverRemoveRejected;
//     uint256 public liqWrongSignRejected;
//     uint256 public hugeDeltaRejected;
//     uint256 public attackerProbes;
//     uint256 public trackerRoundTrips;
//     uint256 public computeFeeChecks;
//     uint256 public absChecks;
//     uint256 public invariantChecks;
//     uint256 public initialCardinalityChecks;

//     constructor() {
//         poolManager = new MockPoolManager();

//         bytes memory creationCode = type(CuratioHookHarness).creationCode;
//         bytes memory args = abi.encode(address(poolManager), address(this));
//         (bytes32 salt,) = HookMiner.find(address(this), creationCode, args);
//         hook = new CuratioHookHarness{salt: salt}(IPoolManager(address(poolManager)), address(this));

//         // must be set BEFORE the pool is initialised: it sizes the ring created in afterInitialize
//         hook.setInitialCardinality(TEST_CARDINALITY);

//         poolKey = PoolKey({
//             currency0: Currency.wrap(address(0x1111)),
//             currency1: Currency.wrap(address(0x2222)),
//             fee: 3000,
//             tickSpacing: 60,
//             hooks: IHooks(address(hook))
//         });
//         poolId = poolKey.toId();

//         poolManager.driveAfterInitialize(address(hook), poolKey, PRICE_1_1, 0);
//         attacker = new HookAttacker(hook);

//         (,, lastCardinalityNext) = hook.getOracleState(poolKey);
//     }

//     // ═════════════════════════════════════════════════════════════════════
//     // Helpers
//     // ═════════════════════════════════════════════════════════════════════

//     function _bound(int256 x, int256 lo, int256 hi) internal pure returns (int256) {
//         if (lo >= hi) return lo;
//         int256 range = hi - lo + 1;
//         int256 w = x % range;
//         if (w < 0) w += range;
//         return lo + w;
//     }

//     /// @dev mode even: anywhere in range; mode odd: close to the last tick (reaches the MID/HIGH fee tiers).
//     function _pickTick(int256 raw, uint8 mode) internal view returns (int24) {
//         if (mode % 2 == 0) return int24(_bound(raw, -MAX_TICK, MAX_TICK));
//         return int24(_bound(int256(lastTickGhost) + (raw % 1000), -MAX_TICK, MAX_TICK));
//     }

//     function _trackTick(int24 t) internal {
//         int256 v = int256(t);
//         if (v < minTickSeen) minTickSeen = v;
//         if (v > maxTickSeen) maxTickSeen = v;
//     }

//     function _setTick(int24 t) internal {
//         poolManager.setSlot0(poolId, PRICE_1_1, t);
//         lastTickGhost = t;
//         _trackTick(t);
//     }

//     function _params(bool zeroForOne, int256 amt) internal pure returns (SwapParams memory) {
//         return SwapParams({
//             zeroForOne: zeroForOne,
//             amountSpecified: amt,
//             sqrtPriceLimitX96: zeroForOne ? 4295128740 : 1461446703485210103287273052203988822378723970341
//         });
//     }

//     function _absDiff(int24 a, int24 b) internal pure returns (uint256) {
//         int256 d = int256(a) - int256(b);
//         return uint256(d >= 0 ? d : -d);
//     }

//     /// @dev True iff `ret` is exactly Error(expected). A revert for the WRONG reason does not match.
//     function _isError(bytes memory ret, string memory expected) internal pure returns (bool) {
//         return keccak256(ret) == keccak256(abi.encodeWithSignature("Error(string)", expected));
//     }

//     function _assertTier(uint24 fee) internal view {
//         assert(
//             fee == hook.BASE_FEE() || fee == hook.MID_VOLATILE_FEE() || fee == hook.HIGH_VOLATILE_FEE()
//                 || fee == hook.MEV_PENALTY_FEE()
//         );
//     }

//     function _countTier(uint24 fee) internal {
//         if (fee == hook.BASE_FEE()) tierBase++;
//         else if (fee == hook.MID_VOLATILE_FEE()) tierMid++;
//         else if (fee == hook.HIGH_VOLATILE_FEE()) tierHigh++;
//         else if (fee == hook.MEV_PENALTY_FEE()) tierMev++;
//     }

//     /// @dev A TWAP is an average of ticks the pool actually had, so it must lie between the extremes ever used
//     ///      (+-2 for integer rounding in the interpolation). Garbage from a broken ring would break this.
//     function _checkTwapBounds(int24 t) internal {
//         assert(int256(t) >= minTickSeen - 2 && int256(t) <= maxTickSeen + 2);
//         twapBoundsChecks++;
//     }

//     // ═════════════════════════════════════════════════════════════════════
//     // Swaps: a valid swap must NEVER be blocked, and its fee must follow the spec
//     // ═════════════════════════════════════════════════════════════════════

//     function act_swap(int256 amtRaw, bool zeroForOne, int256 preRaw, int256 postRaw, uint8 mode) public {
//         int256 amt = amtRaw % 1e30; // realistic magnitude; huge values only test arithmetic limits
//         if (amt == 0) return; // zero-amount swaps are rejected by the pool manager itself
//         _runSwap(_pickTick(preRaw, mode), _pickTick(postRaw, mode >> 1), amt, zeroForOne);
//     }

//     function _runSwap(int24 preTick, int24 postTick, int256 amt, bool zeroForOne) internal {
//         _setTick(preTick);
//         _trackTick(postTick);

//         (bool warm, uint256 divergence) = _preSwapInfo(preTick);
//         (uint16 idxBefore,,) = hook.getOracleState(poolKey);

//         (bool ok, bytes memory ret) = address(poolManager).call(
//             abi.encodeWithSelector(
//                 poolManager.driveFullSwap.selector, address(hook), poolKey, _params(zeroForOne, amt), postTick
//             )
//         );
//         assert(ok); // a valid swap must never be blocked by the hook (no silent return)

//         _afterSwap(ret, warm, divergence, idxBefore);
//     }

//     /// @dev Reads what the hook will see: is the oracle warm, and how far is spot from the TWAP.
//     ///      A warm oracle whose TWAP cannot be read would make beforeSwap revert.
//     function _preSwapInfo(int24 preTick) internal returns (bool warm, uint256 divergence) {
//         uint32 window = hook.DEFAULT_TWAP_WINDOW();
//         warm = hook.isOracleWarm(poolKey, window);
//         if (warm) {
//             try hook.getTwapTick(poolKey, window) returns (int24 t) {
//                 _checkTwapBounds(t);
//                 divergence = _absDiff(preTick, t);
//             } catch {
//                 assert(false); // warm but unreadable: swaps and the vault's valuation would revert
//             }
//         }
//     }

//     function _afterSwap(bytes memory ret, bool warm, uint256 divergence, uint16 idxBefore) internal {
//         uint24 fee = abi.decode(ret, (uint24));
//         swapsOk++;

//         (uint16 idxAfter,,) = hook.getOracleState(poolKey);
//         if (idxAfter != idxBefore) oracleWrites++;

//         if (warm) swapsWarm++;
//         else swapsCold++;
//         if (grewAfterWrap) swapsAfterWrapGrowth++;

//         _countTier(fee);
//         _assertTier(fee);

//         // Fee spec. MEV is always allowed because a sandwich flagged earlier in the same block overrides everything.
//         if (!warm) {
//             assert(fee == hook.MID_VOLATILE_FEE() || fee == hook.MEV_PENALTY_FEE());
//         } else if (divergence >= hook.tickThresholdHigh()) {
//             assert(fee == hook.MEV_PENALTY_FEE());
//         } else if (divergence >= hook.tickThresholdMid()) {
//             assert(fee == hook.HIGH_VOLATILE_FEE() || fee == hook.MEV_PENALTY_FEE());
//         }
//     }

//     /// @dev Deterministic sandwich: two swaps whose tick moves reverse, volume above the threshold, all in one
//     ///      transaction. The third swap in the same block MUST be charged MEV_PENALTY_FEE.
//     function act_sandwich(int256 preRaw, int256 aRaw, int256 bRaw) public {
//         uint256 thr = hook.mevVolumeThreshold();
//         if (thr > 1e30) return; // an executed proposal effectively switched detection off
//         _runSandwich(
//             int24(_bound(preRaw, -MAX_TICK, MAX_TICK)),
//             int24(_bound(aRaw, -MAX_TICK, MAX_TICK)),
//             int24(_bound(bRaw, -MAX_TICK, MAX_TICK)),
//             thr
//         );
//     }

//     function _runSandwich(int24 preTick, int24 tickA, int24 tickB, uint256 thr) internal {
//         _setTick(preTick);
//         _trackTick(tickA);
//         _trackTick(tickB);

//         (bool ok, bytes memory ret) = address(poolManager).call(
//             abi.encodeWithSelector(
//                 poolManager.driveSandwich.selector,
//                 address(hook),
//                 poolKey,
//                 _params(true, -int256(thr + 1)), // each swap alone is above the volume threshold
//                 preTick,
//                 tickA,
//                 tickB
//             )
//         );
//         assert(ok); // also proves the transient flag is cleared between swaps of one transaction
//         lastTickGhost = tickB;

//         uint24 fee3 = abi.decode(ret, (uint24));
//         sandwichScenarios++;

//         if (_isReversal(preTick, tickA, tickB)) {
//             assert(fee3 == hook.MEV_PENALTY_FEE());
//             sandwichPenalized++;
//         } else {
//             _assertTier(fee3);
//         }
//     }

//     function _isReversal(int24 preTick, int24 tickA, int24 tickB) internal pure returns (bool) {
//         int256 m1 = int256(tickA) - int256(preTick);
//         int256 m2 = int256(tickB) - int256(tickA);
//         return (m1 > 0 && m2 < 0) || (m1 < 0 && m2 > 0);
//     }

//     // ═════════════════════════════════════════════════════════════════════
//     // Guards must fire, with the exact reason
//     // ═════════════════════════════════════════════════════════════════════

//     function act_guardBeforeSwapTwice() public {
//         (bool ok, bytes memory ret) = address(poolManager).call(
//             abi.encodeWithSelector(
//                 poolManager.driveBeforeSwapTwice.selector, address(hook), poolKey, _params(true, -1 ether)
//             )
//         );
//         assert(!ok);
//         assert(_isError(ret, "Transient storage dirty: composability violation"));
//         guardBeforeTwice++;
//     }

//     function act_guardAfterSwapWithoutBefore() public {
//         (bool ok, bytes memory ret) = address(poolManager).call(
//             abi.encodeWithSelector(poolManager.driveAfterSwap.selector, address(hook), poolKey, _params(true, -1 ether))
//         );
//         assert(!ok);
//         assert(_isError(ret, "Composability violation: unexpected state"));
//         guardAfterAlone++;
//     }

//     // ═════════════════════════════════════════════════════════════════════
//     // Threshold governance (propose -> wait -> execute / cancel), including the EXECUTE path
//     // ═════════════════════════════════════════════════════════════════════

//     function act_proposeThresholds(uint256 highRaw, uint256 midRaw, uint256 volRaw, uint256 sandwRaw) public {
//         // bounded so the fee tiers stay reachable after an execution
//         uint256 high = highRaw % 2000;
//         uint256 mid = midRaw % 2000;
//         uint256 vol = volRaw % 10 ether;

//         if (high <= mid) {
//             (bool ok, bytes memory ret) = address(hook).call(
//                 abi.encodeWithSelector(hook.proposeTickThresholds.selector, high, mid, vol, sandwRaw)
//             );
//             assert(!ok);
//             assert(_isError(ret, "High threshold must be greater than mid"));
//             badProposalRejected++;
//             return;
//         }

//         hook.proposeTickThresholds(high, mid, vol, sandwRaw);

//         (uint256 h, uint256 m, uint256 v, uint256 s, uint256 eta, bool exists) = hook.pendingThresholds();
//         assert(exists);
//         assert(eta == block.timestamp + hook.THRESHOLD_TIMELOCK_DELAY());
//         assert(h == high && m == mid && v == vol && s == sandwRaw);
//         thresholdProposals++;
//     }

//     function act_executeThresholds() public {
//         (uint256 h, uint256 m, uint256 v, uint256 s, uint256 eta, bool exists) = hook.pendingThresholds();

//         (bool ok, bytes memory ret) =
//             address(hook).call(abi.encodeWithSelector(hook.executeTickThresholds.selector));

//         if (!exists) {
//             assert(!ok);
//             assert(_isError(ret, "No pending proposal"));
//             return;
//         }
//         if (block.timestamp < eta) {
//             assert(!ok);
//             assert(_isError(ret, "Timelock not elapsed"));
//             earlyExecRejected++;
//             return;
//         }

//         assert(ok);
//         assert(hook.tickThresholdHigh() == h);
//         assert(hook.tickThresholdMid() == m);
//         assert(hook.mevVolumeThreshold() == v);
//         assert(hook.sandwichTickThreshold() == s);
//         (,,,,, bool stillExists) = hook.pendingThresholds();
//         assert(!stillExists);
//         assert(hook.tickThresholdHigh() > hook.tickThresholdMid());
//         thresholdExecutions++;
//     }

//     function act_cancelThresholds() public {
//         (,,,,, bool exists) = hook.pendingThresholds();
//         (bool ok, bytes memory ret) =
//             address(hook).call(abi.encodeWithSelector(hook.cancelTickThresholdsProposal.selector));

//         if (!exists) {
//             assert(!ok);
//             assert(_isError(ret, "No pending proposal"));
//             return;
//         }
//         assert(ok);
//         (,,,,, bool after_) = hook.pendingThresholds();
//         assert(!after_);
//         thresholdCancels++;
//     }

//     // ═════════════════════════════════════════════════════════════════════
//     // Oracle ring: growth, warm/TWAP consistency
//     // ═════════════════════════════════════════════════════════════════════

//     function act_growCardinality(uint16 target) public {
//         (,, uint16 next0) = hook.getOracleState(poolKey);
//         (uint16 oldNext, uint16 newNext) = hook.increaseObservationCardinality(poolKey, target);

//         assert(oldNext == next0);
//         assert(newNext >= oldNext);
//         assert(newNext >= lastCardinalityNext);
//         assert(uint256(newNext) - uint256(oldNext) <= hook.maxCardinalityPerCall()); // per-call DoS cap
//         if (target <= oldNext) assert(newNext == oldNext); // nothing to grow
//         lastCardinalityNext = newNext;

//         if (newNext > oldNext) {
//             growthOk++;
//             // growth AFTER the ring wrapped is the dangerous case (see the contract notes)
//             if (oracleWrites >= TEST_CARDINALITY) {
//                 grewAfterWrap = true;
//                 growthAfterWrap++;
//             }
//         }
//     }

//     function act_checkWarmTwap(uint256 windowRaw) public {
//         uint32 window = uint32(1 + (windowRaw % 3600));

//         if (hook.isOracleWarm(poolKey, window)) {
//             warmTwapChecks++;
//             try hook.getTwapTick(poolKey, window) returns (int24 t) {
//                 _checkTwapBounds(t);
//             } catch {
//                 assert(false); // warm must imply readable
//             }
//             // warm for a window implies warm for every shorter window
//             assert(hook.isOracleWarm(poolKey, (window / 2) + 1));
//         } else {
//             notWarmChecks++;
//             // not warm for a window implies not warm for any longer window
//             assert(!hook.isOracleWarm(poolKey, window + 1000));
//         }
//         assert(!hook.isOracleWarm(poolKey, 0));
//     }

//     function act_setInitialCardinality(uint16 v) public {
//         (bool ok, bytes memory ret) =
//             address(hook).call(abi.encodeWithSelector(hook.setInitialCardinality.selector, v));

//         if (v == 0) {
//             assert(!ok);
//             assert(_isError(ret, "Must be > 0"));
//         } else if (v > hook.maxCardinalityPerCall()) {
//             assert(!ok);
//             assert(_isError(ret, "Exceeds max cardinality per call"));
//         } else {
//             assert(ok);
//             assert(hook.initialCardinality() == v);
//         }
//         initialCardinalityChecks++;
//     }

//     // ═════════════════════════════════════════════════════════════════════
//     // Liquidity bookkeeping against a ghost model
//     // ═════════════════════════════════════════════════════════════════════

//     function _lower(uint8 i) internal pure returns (int24) {
//         if (i == 0) return -120;
//         if (i == 1) return -60;
//         if (i == 2) return 0;
//         return 60;
//     }

//     function _upper(uint8 i) internal pure returns (int24) {
//         if (i == 0) return 120;
//         if (i == 1) return 60;
//         if (i == 2) return 60;
//         return 180;
//     }

//     function _stored(uint8 i) internal view returns (uint128) {
//         bytes32 key = keccak256(abi.encodePacked(address(poolManager), poolId, _lower(i), _upper(i)));
//         return hook.storedPositions(key);
//     }

//     function _liqParams(uint8 i, int256 delta) internal pure returns (ModifyLiquidityParams memory) {
//         return ModifyLiquidityParams({
//             tickLower: _lower(i), tickUpper: _upper(i), liquidityDelta: delta, salt: bytes32(0)
//         });
//     }

//     function _callAdd(uint8 i, int256 delta) internal returns (bool, bytes memory) {
//         return address(poolManager).call(
//             abi.encodeWithSelector(
//                 poolManager.driveAfterAddLiquidity.selector, address(hook), poolKey, _liqParams(i, delta)
//             )
//         );
//     }

//     function _callRemove(uint8 i, int256 delta) internal returns (bool, bytes memory) {
//         return address(poolManager).call(
//             abi.encodeWithSelector(
//                 poolManager.driveAfterRemoveLiquidity.selector, address(hook), poolKey, _liqParams(i, delta)
//             )
//         );
//     }

//     function act_addLiquidity(uint8 idx, uint256 amtRaw) public {
//         uint8 i = idx % 4;
//         uint128 amt = uint128(1 + (amtRaw % 1e30));
//         (bool ok,) = _callAdd(i, int256(uint256(amt)));
//         assert(ok);
//         ghostLiq[i] += amt;
//         assert(_stored(i) == ghostLiq[i]);
//         liqAdds++;
//     }

//     function act_removeLiquidity(uint8 idx, uint256 amtRaw) public {
//         uint8 i = idx % 4;
//         uint128 amt = uint128(1 + (amtRaw % 1e30));
//         (bool ok, bytes memory ret) = _callRemove(i, -int256(uint256(amt)));

//         if (amt > ghostLiq[i]) {
//             assert(!ok);
//             assert(_isError(ret, "Insufficient liquidity"));
//             liqOverRemoveRejected++;
//         } else {
//             assert(ok);
//             ghostLiq[i] -= amt;
//             liqRemoves++;
//         }
//         assert(_stored(i) == ghostLiq[i]);
//     }

//     function act_wrongSignLiquidity(uint8 idx, bool addPath, uint256 amtRaw) public {
//         uint8 i = idx % 4;
//         int256 amt = int256(1 + (amtRaw % 1e30));
//         bool ok;
//         bytes memory ret;

//         if (addPath) {
//             (ok, ret) = _callAdd(i, -amt);
//             assert(!ok);
//             assert(_isError(ret, "Delta must be positive when adding"));
//         } else {
//             (ok, ret) = _callRemove(i, amt);
//             assert(!ok);
//             assert(_isError(ret, "Delta must be negative when removing"));
//         }
//         assert(_stored(i) == ghostLiq[i]);
//         liqWrongSignRejected++;
//     }

//     function act_hugeDelta(bool addPath) public {
//         int256 huge = int256(uint256(type(uint128).max)) + 1;
//         bool ok;
//         bytes memory ret;

//         if (addPath) (ok, ret) = _callAdd(0, huge);
//         else (ok, ret) = _callRemove(0, -huge);

//         assert(!ok);
//         assert(_isError(ret, "Delta too large"));
//         assert(_stored(0) == ghostLiq[0]);
//         hugeDeltaRejected++;
//     }

//     // ═════════════════════════════════════════════════════════════════════
//     // Access control, tracker packing, fee spec, abs
//     // ═════════════════════════════════════════════════════════════════════

//     function act_attackerProbe() public {
//         ModifyLiquidityParams memory mp = _liqParams(0, 1);
//         assert(!attacker.probe(poolKey, _params(true, -1 ether), mp));
//         attackerProbes++;
//     }

//     function act_trackerRoundTrip(
//         int24 firstMove,
//         int24 lastMove,
//         int24 peakTick,
//         uint32 swapCount,
//         uint256 startBlock,
//         bool initialized
//     ) public {
//         CuratioHook.SandwichTracker memory t = CuratioHook.SandwichTracker({
//             firstMove: firstMove,
//             lastMove: lastMove,
//             peakTick: peakTick,
//             swapCount: swapCount,
//             startBlock: startBlock % (1 << 96), // startBlock is packed into 96 bits
//             initialized: initialized
//         });

//         CuratioHook.SandwichTracker memory t2 = hook.exposed_unpackTracker(hook.exposed_packTracker(t));

//         assert(t2.firstMove == firstMove);
//         assert(t2.lastMove == lastMove);
//         assert(t2.peakTick == peakTick);
//         assert(t2.swapCount == swapCount);
//         assert(t2.startBlock == t.startBlock);
//         assert(t2.initialized == initialized);
//         trackerRoundTrips++;
//     }

//     /// @dev Regression guard: an explicit copy of the fee spec. It fails if a branch of _computeFee is changed.
//     function act_computeFeeSpec(uint24 tickDelta, uint256 blockDelta, uint24 currentFee) public {
//         uint24 fee = hook.exposed_computeFee(tickDelta, blockDelta, currentFee);
//         uint24 expected;

//         if (uint256(tickDelta) >= hook.tickThresholdHigh()) expected = hook.HIGH_VOLATILE_FEE();
//         else if (uint256(tickDelta) >= hook.tickThresholdMid()) expected = hook.MID_VOLATILE_FEE();
//         else if (blockDelta >= uint256(hook.blockDecayWindow()) || currentFee == 0) expected = hook.BASE_FEE();
//         else expected = currentFee;

//         assert(fee == expected);
//         computeFeeChecks++;
//     }

//     function act_abs(int24 n) public {
//         if (n == type(int24).min) return; // no representable absolute value
//         uint24 r = hook.exposed_abs(n);
//         assert(int256(uint256(r)) == (n >= 0 ? int256(n) : -int256(n)));
//         absChecks++;
//     }

//     // ═════════════════════════════════════════════════════════════════════
//     // Invariants (assertions, called like any other function)
//     // ═════════════════════════════════════════════════════════════════════

//     function invariant_thresholds() public {
//         assert(hook.tickThresholdHigh() > hook.tickThresholdMid());
//         invariantChecks++;
//     }

//     function invariant_oracle_state() public {
//         (uint16 index, uint16 cardinality, uint16 next) = hook.getOracleState(poolKey);
//         assert(cardinality >= 1);
//         assert(index < cardinality);
//         assert(next >= cardinality);
//         assert(next >= lastCardinalityNext); // never shrinks
//         invariantChecks++;
//     }

//     function invariant_pool_state() public {
//         (int24 lastTick, uint24 fee, uint64 lastBlock, uint64 lastTs, bool init) = hook.getPoolState(poolKey);
//         assert(init);
//         assert(lastBlock <= block.number);
//         assert(lastTs <= block.timestamp);
//         assert(int256(lastTick) >= -MAX_TICK && int256(lastTick) <= MAX_TICK);
//         _assertTier(fee);
//         _assertTier(hook.getCurrentFee(poolKey));
//         invariantChecks++;
//     }

//     // ═════════════════════════════════════════════════════════════════════
//     // CANARIES: each FAILS once its path was reached. A canary that is still
//     // "passing" at the end means that path never ran, so the checks above
//     // proved nothing about it.
//     // ═════════════════════════════════════════════════════════════════════

//     function canary_swap_ok() public { assert(swapsOk == 0); }
//     function canary_swap_warm_oracle() public { assert(swapsWarm == 0); }
//     function canary_swap_cold_oracle() public { assert(swapsCold == 0); }
//     function canary_oracle_wrapped() public { assert(oracleWrites < TEST_CARDINALITY); }
//     function canary_tier_base() public { assert(tierBase == 0); }
//     function canary_tier_mid() public { assert(tierMid == 0); }
//     function canary_tier_high() public { assert(tierHigh == 0); }
//     function canary_tier_mev() public { assert(tierMev == 0); }
//     function canary_sandwich_scenario() public { assert(sandwichScenarios == 0); }
//     function canary_sandwich_penalized() public { assert(sandwichPenalized == 0); }
//     function canary_guard_before_twice() public { assert(guardBeforeTwice == 0); }
//     function canary_guard_after_alone() public { assert(guardAfterAlone == 0); }
//     function canary_threshold_proposed() public { assert(thresholdProposals == 0); }
//     function canary_bad_proposal_rejected() public { assert(badProposalRejected == 0); }
//     function canary_threshold_executed() public { assert(thresholdExecutions == 0); }
//     function canary_early_execution_rejected() public { assert(earlyExecRejected == 0); }
//     function canary_threshold_cancelled() public { assert(thresholdCancels == 0); }
//     function canary_growth() public { assert(growthOk == 0); }
//     function canary_growth_after_wrap() public { assert(growthAfterWrap == 0); }
//     function canary_swap_after_growth_after_wrap() public { assert(swapsAfterWrapGrowth == 0); }
//     function canary_warm_twap_checked() public { assert(warmTwapChecks == 0); }
//     function canary_not_warm_checked() public { assert(notWarmChecks == 0); }
//     function canary_twap_bounds_checked() public { assert(twapBoundsChecks == 0); }
//     function canary_liquidity_added() public { assert(liqAdds == 0); }
//     function canary_liquidity_removed() public { assert(liqRemoves == 0); }
//     function canary_liquidity_over_remove_rejected() public { assert(liqOverRemoveRejected == 0); }
//     function canary_liquidity_wrong_sign_rejected() public { assert(liqWrongSignRejected == 0); }
//     function canary_huge_delta_rejected() public { assert(hugeDeltaRejected == 0); }
//     function canary_attacker_probed() public { assert(attackerProbes == 0); }
//     function canary_tracker_round_trip() public { assert(trackerRoundTrips == 0); }
//     function canary_compute_fee_checked() public { assert(computeFeeChecks == 0); }
//     function canary_abs_checked() public { assert(absChecks == 0); }
//     function canary_invariants_called() public { assert(invariantChecks == 0); }
//     function canary_initial_cardinality_checked() public { assert(initialCardinalityChecks == 0); }
// }
