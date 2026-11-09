// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {CuratioForkTest} from "./CuratioForkTest.t.sol";

/**
 * @notice Regression tests for the three weaknesses the earlier `test_finding_*` tests exposed, plus two
 *         general behaviour tests. The assertions of the old finding tests are FLIPPED: they now prove the fixes.
 *
 *  FIX-A  per-chain default oracle depth (240 slots on Unichain)  -> a busy 1-second pool keeps the oracle warm
 *  FIX-B  V3-style cardinality growth (applied at the ring's end) -> growing a wrapped ring no longer bricks it
 *  FIX-C  the sandwich penalty lives only in the flagged block    -> it can no longer block later withdrawals
 *
 *  test_more_*  behaviour that should hold (pool isolation, timelocked governance changes real fees)
 *  test_fix_*   the fixes
 *
 * Reuses the CuratioForkTest fixture (real Unichain PoolManager + fresh Curatio stack + mock tokens).
 * It inherits the original tests too, so run ONLY these with:
 *
 *   forge test --match-path test/fork/CuratioForkFindingsTest.t.sol --match-test "test_more|test_fix" -vv
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
    //  test_fix: FIX-A  default oracle depth for a 1-second chain
    // ═════════════════════════════════════════════════════════════════════════

    /// @dev Unichain gets 240 slots (2x the 120 s window) instead of 100.
    function test_fix_unichainDefaultOracleDepth() public view {
        assertEq(uint256(hook.initialCardinality()), 240);

        (, uint16 cardinality, uint16 cardinalityNext) = hook.getOracleState(key);
        assertEq(uint256(cardinality), 240);
        assertEq(uint256(cardinalityNext), 240);
    }

    /// @dev Flipped from test_finding_busyPool_oracleNeverWarms_vaultFrozen_thenRecovers.
    ///      One swap per second, 300 swaps (the 240-slot ring wraps): the oracle stays warm, the TWAP guard keeps
    ///      working and the vault can always be valued.
    function test_fix_busyPool_oracleStaysWarm_vaultKeepsWorking() public {
        _seedLp(1e20);
        _advance(130);
        vm.prank(alice);
        vault.deposit(100e18, alice);

        _tradeEvery(300, 1);

        (, uint16 cardinality,) = hook.getOracleState(key);
        assertEq(uint256(cardinality), 240);
        assertTrue(hook.isOracleWarm(key, 120), "240 observations 1s apart cover more than 120s");
        hook.getTwapTick(key, 120); // must not revert

        assertGt(vault.maxDeposit(alice), 0, "the vault can be valued");
        _advance(1);
        assertEq(
            uint256(_swapAndGetFee(true, -1e15)), uint256(BASE_FEE), "TWAP-checked calm fee, not the cold-start fee"
        );

        vm.prank(alice);
        vault.withdraw(1e18, alice, alice);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  test_fix: FIX-B  cardinality growth is applied at the ring's end
    // ═════════════════════════════════════════════════════════════════════════

    /// @dev Flipped from test_finding_growingOracleAfterWrap_bricksSwapsAndVault. Same sequence, with the ring
    ///      wrapped (index ~80) and warm when anyone grows it. Now the new size is only RECORDED; getTwapTick,
    ///      swaps and the vault keep working, and the ring switches to the new size when it reaches its last slot.
    function test_fix_growthAfterWrap_isDeferred_oracleStaysHealthy() public {
        _seedLp(1e20);
        _advance(130);
        vm.prank(alice);
        vault.deposit(100e18, alice);

        _tradeEvery(320, 2); // 240-slot ring wrapped, write index ~80, observations 2s apart => warm

        (uint16 index, uint16 cardinality, uint16 cardinalityNext) = hook.getOracleState(key);
        assertEq(uint256(cardinality), 240);
        assertGt(uint256(index), 60, "now-120s lies in the newest part of the ring");
        assertTrue(hook.isOracleWarm(key, 120));

        vm.prank(makeAddr("attacker"));
        hook.increaseObservationCardinality(key, 400);

        // recorded, not applied
        (, cardinality, cardinalityNext) = hook.getOracleState(key);
        assertEq(uint256(cardinality), 240, "ring layout must be untouched");
        assertEq(uint256(cardinalityNext), 400);

        // exactly the calls that used to revert
        _advance(2);
        hook.getTwapTick(key, 120);
        _swap(true, -1e15);
        assertGt(vault.maxDeposit(alice), 0);
        vault.totalAssets();

        // keep trading until the write index reaches the end of the old ring: the new size takes effect there
        _tradeEvery(160, 2);
        (index, cardinality, cardinalityNext) = hook.getOracleState(key);
        assertEq(uint256(cardinality), 400, "the new size is applied at the end of the old ring");
        assertTrue(hook.isOracleWarm(key, 120));
        hook.getTwapTick(key, 120);

        vm.prank(alice);
        vault.withdraw(1e18, alice, alice);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  test_fix: FIX-C  the sandwich penalty ends with the flagged block
    // ═════════════════════════════════════════════════════════════════════════

    /// @dev Flipped from test_finding_cheapSandwichFlagsPenaltyForAnyone. Anyone can still flag a block for the
    ///      price of the swap fees, but the 10% penalty now ends with that block and is not stored.
    function test_fix_penaltyEndsWithTheFlaggedBlock() public {
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

        uint256 balAfter = token0.balanceOf(attacker) + token1.balanceOf(attacker);
        assertLt(balBefore - balAfter, 1e17, "the attack still costs only swap fees (< 2.5% of the volume)");

        // enforced for the rest of the flagged block...
        assertEq(uint256(hook.getCurrentFee(key)), uint256(MEV_FEE));
        assertEq(uint256(_swapAndGetFee(true, -1e15)), uint256(MEV_FEE), "rest of the flagged block pays the penalty");

        // ...but never stored
        (, uint24 storedFee,,,) = hook.getPoolState(key);
        assertLt(uint256(storedFee), uint256(MEV_FEE), "the penalty must not be stored in the pool state");

        // the very next block is back to a normal, non-penalty fee, and stays there while the pool keeps trading
        _advance(1);
        assertLt(uint256(hook.getCurrentFee(key)), uint256(MEV_FEE));
        for (uint256 i = 0; i < 5; i++) {
            uint24 fee = _swapAndGetFee(i % 2 == 0, -1e15);
            assertLt(uint256(fee), uint256(MEV_FEE), "no sticky penalty after the flagged block");
            _advance(1);
        }
    }
}
