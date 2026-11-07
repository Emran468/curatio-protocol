// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {CuratioRebalancer} from "../../src/CuratioRebalancer.sol";
import {CuratioForkTest} from "./CuratioForkTest.t.sol";

/**
 * @notice More fork tests, in two groups.
 *
 *  test_more_*     Behaviour that SHOULD hold (pool isolation, timelocked governance really changes fees).
 *
 *  test_finding_*  Probes for weaknesses found by reading CuratioHook / TwapOracle. They assert what the
 *                  code does TODAY, so they PASS while the weakness exists. After a fix, flip the asserts.
 *                  If one of them FAILS, either the weakness is not real or the test model is wrong:
 *                  send the output.
 *
 * Reuses the CuratioForkTest fixture (real Unichain PoolManager + fresh Curatio stack + mock tokens).
 * It inherits the original tests too, so run ONLY these with:
 *
 *   forge test --match-path test/fork/CuratioForkFindingsTest.t.sol --match-test "test_more|test_finding" -vv
 */
contract CuratioForkFindingsTest is CuratioForkTest {
    using PoolIdLibrary for PoolKey;

    // ═════════════════════════════════════════════════════════════════════════
    //  Helpers
    // ═════════════════════════════════════════════════════════════════════════

    /// @dev n tiny alternating swaps, each `secondsApart` blocks/seconds after the previous one, so each swap
    ///      lands in a new timestamp and writes one oracle observation.
    function _tradeEvery(uint256 n, uint256 secondsApart) internal {
        for (uint256 i = 0; i < n; i++) {
            _advance(secondsApart);
            _swap(i % 2 == 0, -1e15);
        }
    }

    function _swapOn(PoolKey memory k, bool zeroForOne, int256 amountSpecified) internal {
        swapRouter.swap(
            k,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _seedLpOn(PoolKey memory k, uint128 liq, int24 spacing) internal {
        lpRouter.modifyLiquidity(
            k,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(spacing),
                tickUpper: TickMath.maxUsableTick(spacing),
                liquidityDelta: int256(uint256(liq)),
                salt: bytes32(0)
            }),
            ""
        );
    }

    function _feeOfSwapOn(PoolKey memory k, bool zeroForOne, int256 amountSpecified) internal returns (uint24 fee) {
        vm.recordLogs();
        _swapOn(k, zeroForOne, amountSpecified);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 sig = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
        bytes32 id = PoolId.unwrap(k.toId());
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(POOL_MANAGER) && logs[i].topics[0] == sig && logs[i].topics[1] == id) {
                (,,,,, fee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                found = true;
            }
        }
        require(found, "no Swap event for this pool");
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  test_more: things that should hold
    // ═════════════════════════════════════════════════════════════════════════

    /// @dev One hook serves two pools. A sandwich in pool 1 must not leak into pool 2.
    function test_more_twoPoolsShareHook_stateIsIsolated() public {
        PoolKey memory key2 = PoolKey({
            currency0: key.currency0, currency1: key.currency1, fee: key.fee, tickSpacing: 120, hooks: key.hooks
        });
        POOL_MANAGER.initialize(key2, SQRT_PRICE_1_1);

        _seedLp(1e20);
        _seedLpOn(key2, 1e20, 120);
        _advance(130);

        // sandwich in pool 1
        _swap(true, -2e18);
        _swap(false, -2e18);
        assertEq(uint256(hook.getCurrentFee(key)), uint256(MEV_FEE), "pool 1 must be flagged");

        // pool 2 never traded: untouched hook state
        (int24 lastTick2, uint24 fee2,,, bool init2) = hook.getPoolState(key2);
        assertTrue(init2);
        assertEq(int256(lastTick2), 0);
        assertEq(uint256(fee2), uint256(BASE_FEE));
        assertEq(uint256(hook.getCurrentFee(key2)), uint256(BASE_FEE));
        (,,,, uint256 swapCount2, bool trackerInit2) = hook.getSandwichTracker(key2);
        assertFalse(trackerInit2);
        assertEq(swapCount2, 0);

        // a swap in pool 2 in the SAME block as the pool-1 sandwich pays the normal fee
        uint24 fee = _feeOfSwapOn(key2, true, -1e15);
        assertEq(uint256(fee), uint256(BASE_FEE), "pool 2 must not pay pool 1's penalty");
    }

    /// @dev The 2-day timelock is real: execute reverts early, and after it the new thresholds change the
    ///      fee the real PoolManager charges for the very same swaps.
    function test_more_timelockedThresholds_changeRealFeeBehaviour() public {
        _seedLp(1e20);
        _advance(130);

        hook.proposeTickThresholds(5000, 4000, 100e18, 80);
        vm.expectRevert("Timelock not elapsed");
        hook.executeTickThresholds();

        _advance(2 days);
        hook.executeTickThresholds();
        assertEq(hook.tickThresholdHigh(), 5000);
        assertEq(hook.tickThresholdMid(), 4000);
        assertEq(hook.mevVolumeThreshold(), 100e18);

        // with the default thresholds this swap (~ -1900 ticks) stores HIGH_FEE (see the earlier test)
        _swap(true, -10e18);
        (, uint24 storedFee,,,) = hook.getPoolState(key);
        assertEq(uint256(storedFee), uint256(BASE_FEE), "1900 ticks is below the new mid threshold");

        // and the TWAP guard no longer reacts to a 1700-tick deviation either
        _advance(12);
        uint24 fee = _swapAndGetFee(false, -1e15);
        assertEq(uint256(fee), uint256(BASE_FEE));
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  test_finding: oracle depth (100 slots) vs a 120s window on a 1-second chain
    // ═════════════════════════════════════════════════════════════════════════

    /// @dev 100 observations written once per second only cover ~99s, which is shorter than the 120s TWAP
    ///      window. isWarm() turns false, so on a pool that trades every second:
    ///        - the hook falls back to the cold-start fee and the TWAP guard is off,
    ///        - getTwapTick reverts, so the vault's totalAssets() reverts and deposits AND withdrawals halt,
    ///        until the pool is quiet for ~20s (the oldest observation ages past 120s).
    function test_finding_busyPool_oracleNeverWarms_vaultFrozen_thenRecovers() public {
        _seedLp(1e20);
        _advance(130);
        vm.prank(alice);
        vault.deposit(100e18, alice);
        assertTrue(hook.isOracleWarm(key, 120), "warm before the ring wraps");

        _tradeEvery(150, 1); // one swap per second, like a busy pool on Unichain

        (, uint16 cardinality,) = hook.getOracleState(key);
        assertEq(uint256(cardinality), 100);
        assertFalse(hook.isOracleWarm(key, 120), "100 observations 1s apart cover less than 120s");

        vm.expectRevert("TwapOracle: insufficient history for requested window");
        hook.getTwapTick(key, 120);

        // the vault is frozen: it cannot be valued
        assertEq(vault.maxDeposit(alice), 0);
        vm.prank(alice);
        vm.expectRevert(CuratioRebalancer.TwapUnavailable.selector);
        vault.withdraw(1e18, alice, alice);

        // and the next swap runs on the cold-start fee instead of a TWAP-checked fee
        _advance(1);
        assertEq(uint256(_swapAndGetFee(true, -1e15)), uint256(MID_FEE), "cold-start fee while the oracle is not warm");

        // a quiet period lets the history age: warm again, vault usable again
        _advance(30);
        assertTrue(hook.isOracleWarm(key, 120));
        vm.prank(alice);
        vault.withdraw(1e18, alice, alice);
    }

    /// @dev The same load with a bigger ring (grown BEFORE it wraps) stays warm, so the weakness is the
    ///      initialCardinality default (100), not the TWAP design.
    function test_finding_largerCardinalityBeforeWrap_keepsOracleWarm() public {
        _seedLp(1e20);
        _advance(130);
        vm.prank(alice);
        vault.deposit(100e18, alice);

        _tradeEvery(30, 1);
        vm.prank(makeAddr("anyone"));
        hook.increaseObservationCardinality(key, 400); // permissionless
        _tradeEvery(150, 1);

        (, uint16 cardinality,) = hook.getOracleState(key);
        assertEq(uint256(cardinality), 400);
        assertTrue(hook.isOracleWarm(key, 120));
        hook.getTwapTick(key, 120); // must not revert

        _advance(1);
        assertEq(uint256(_swapAndGetFee(true, -1e15)), uint256(BASE_FEE), "TWAP-checked calm fee");

        vm.prank(alice);
        vault.withdraw(1e18, alice, alice); // the vault keeps working
    }

    /// @dev increaseObservationCardinality is permissionless and sets `cardinality = cardinalityNext` at once.
    ///      If the ring has ALREADY wrapped and the oracle is warm (swaps ~2s apart), the buffer becomes
    ///      [old part][empty gap][new part]. TwapOracle.binarySearch treats the gap as "too new", cannot bracket
    ///      now-120s, and reverts. beforeSwap and the vault's valuation both call it => swaps and the vault halt.
    ///      (A swap after 120+ quiet seconds takes the extrapolation path and works once, then it breaks again.)
    function test_finding_growingOracleAfterWrap_bricksSwapsAndVault() public {
        _seedLp(1e20);
        _advance(130);
        vm.prank(alice);
        vault.deposit(100e18, alice);

        _tradeEvery(180, 2); // observations 2s apart: the ring spans ~198s (warm) and has wrapped

        (uint16 index, uint16 cardinality,) = hook.getOracleState(key);
        assertEq(uint256(cardinality), 100);
        assertGt(uint256(index), 60, "ring wrapped far enough that now-120s is in the newest part");
        assertTrue(hook.isOracleWarm(key, 120));
        hook.getTwapTick(key, 120); // works today

        // anyone grows the buffer
        vm.prank(makeAddr("attacker"));
        hook.increaseObservationCardinality(key, 300);
        _advance(2);

        vm.expectRevert("TwapOracle: insufficient observation history");
        hook.getTwapTick(key, 120);

        // PoolManager wraps hook reverts, so only check that the swap reverts
        vm.expectRevert();
        _swap(true, -1e15);

        // the vault cannot be valued either
        vm.expectRevert(CuratioRebalancer.TwapUnavailable.selector);
        vault.totalAssets();
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  test_finding: the MEV penalty is cheap to trigger and lasts a whole decay window
    // ═════════════════════════════════════════════════════════════════════════

    /// @dev Anyone with a few tokens can flag a "sandwich" with two opposite swaps in one block. It costs only
    ///      the swap fees, and the 10% penalty then stays for blockDecayWindow blocks (300 on Unichain, ~5 min),
    ///      which (see CuratioForkSwapPathTest) blocks withdrawals that must unwind the LP and keeper rebalances.
    function test_finding_cheapSandwichFlagsPenaltyForAnyone() public {
        _seedLp(1e20);
        _advance(130);

        address attacker = makeAddr("attacker");
        token0.transfer(attacker, 10e18);
        token1.transfer(attacker, 10e18);
        uint256 balBefore = token0.balanceOf(attacker) + token1.balanceOf(attacker);

        vm.startPrank(attacker);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        _swap(true, -2e18);
        _swap(false, -2e18);
        vm.stopPrank();

        assertEq(uint256(hook.getCurrentFee(key)), uint256(MEV_FEE), "flagged by an arbitrary address");

        uint256 balAfter = token0.balanceOf(attacker) + token1.balanceOf(attacker);
        assertLt(balBefore - balAfter, 1e17, "attack cost must be only swap fees (< 2.5% of the 4e18 volume)");

        // the penalty lasts the whole decay window
        _advance(uint256(hook.blockDecayWindow()) - 1);
        assertEq(uint256(hook.getCurrentFee(key)), uint256(MEV_FEE));
        _advance(1);
        assertEq(uint256(hook.getCurrentFee(key)), uint256(BASE_FEE));
    }
}
