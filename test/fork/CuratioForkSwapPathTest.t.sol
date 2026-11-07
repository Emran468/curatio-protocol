// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";

import {CuratioRebalancer} from "../../src/CuratioRebalancer.sol";
import {CuratioForkTest} from "./CuratioForkTest.t.sol";

/**
 * @notice Paths where the rebalancer must SWAP inside the PoolManager unlock:
 *           (A) a withdrawal that has to unwind a two-sided LP position,
 *           (B) a keeper (performUpkeep) rebalance into a range that contains the price.
 *         Both call _coverDeficits, which swaps against the TWAP-checked price
 *         (maxSwapSlippageBps = 300). That is exactly what the hook's MEV penalty fee (10%) breaks.
 *
 * Reuses the fixture of CuratioForkTest (real Unichain PoolManager + fresh Curatio stack + mock
 * tokens at a 1:1 price). It inherits the original tests too, so run ONLY these with:
 *
 *   forge test --match-path test/fork/CuratioForkSwapPathTest.t.sol --match-test test_swapPath -vv
 */
contract CuratioForkSwapPathTest is CuratioForkTest {
    using StateLibrary for IPoolManager;

    // ═════════════════════════════════════════════════════════════════════════
    //  Helpers
    // ═════════════════════════════════════════════════════════════════════════

    /// @dev Same-block front-run + back-run: opposite directions, total volume 4e18 > mevVolumeThreshold (1e18).
    ///      The external LP (1e20) keeps the price near 1:1 (a few ticks).
    function _sandwichSameBlock() internal {
        _swap(true, -2e18);
        _swap(false, -2e18);
        assertEq(uint256(hook.getCurrentFee(key)), uint256(MEV_FEE), "sandwich must be flagged");
    }

    /// @dev alice deposits 100 (asset = token0), plus 50 token1 sits idle in the rebalancer so the rebalance
    ///      itself needs no swap. The strategist then opens a TWO-SIDED position of value ~80 in [-600, 600].
    ///      Result: ~60 token0 idle, ~10 token1 idle, LP ~ (39.6 token0 + 39.6 token1) at 1:1.
    function _twoSidedLpSetup() internal returns (uint128 liq) {
        _advance(130);
        vm.prank(alice);
        vault.deposit(100e18, alice);
        vault.deployToRebalancer(100e18);
        token1.transfer(address(rebalancer), 50e18);

        _seedLp(1e20); // external depth so later swaps can execute

        liq = rebalancer.quoteLiquidityForValue(-600, 600, 80e18);
        vm.prank(strategist);
        rebalancer.rebalanceLiquidity(-600, 600, liq, type(uint256).max, type(uint256).max);
    }

    /// @dev Only the asset (token0) is held; external LP exists; keeper may pay any amount.
    function _keeperSetup() internal {
        _advance(130);
        vm.prank(alice);
        vault.deposit(100e18, alice);
        vault.deployToRebalancer(100e18);
        _seedLp(1e20);
        rebalancer.setKeeperMaxPay(type(uint256).max, type(uint256).max);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  A. Withdrawals that need a swap vs. the MEV penalty fee
    // ═════════════════════════════════════════════════════════════════════════

    function test_swapPath_withdrawNeedingSwap_revertsInSandwichBlock() public {
        uint128 liqBefore = _twoSidedLpSetup();
        _sandwichSameBlock();

        // 100 > ~60 idle token0 => LP must be unwound and ~20 token1 swapped into token0 at a 10% fee
        vm.prank(alice);
        vm.expectRevert(CuratioRebalancer.SwapPriceDeviation.selector);
        vault.withdraw(100e18, alice, alice);

        assertEq(uint256(rebalancer.currentLiquidity()), uint256(liqBefore), "a failed withdraw must change nothing");
    }

    /// @dev The same-block flag is gone one block later, but the MEV fee stays stored in the hook and is
    ///      re-applied to calm swaps until blockDecayWindow (300 blocks on Unichain) has passed.
    function test_swapPath_withdrawNeedingSwap_succeedsOnlyAfterDecayWindow() public {
        uint128 liqBefore = _twoSidedLpSetup();
        _sandwichSameBlock();

        _advance(1);
        vm.prank(alice);
        vm.expectRevert(CuratioRebalancer.SwapPriceDeviation.selector);
        vault.withdraw(100e18, alice, alice);

        _advance(uint256(hook.blockDecayWindow()));
        assertEq(uint256(hook.getCurrentFee(key)), uint256(BASE_FEE), "fee must have decayed");

        uint256 balBefore = token0.balanceOf(alice);
        vm.prank(alice);
        vault.withdraw(100e18, alice, alice);

        assertEq(token0.balanceOf(alice) - balBefore, 100e18, "alice must receive exactly what she asked for");
        assertLt(uint256(rebalancer.currentLiquidity()), uint256(liqBefore), "LP must have been partially unwound");
    }

    /// @dev Contrast: a withdrawal that the rebalancer's idle token0 can cover needs no unwind and no swap,
    ///      so the penalty window does not affect it.
    function test_swapPath_withdrawWithinIdle_worksDuringPenalty() public {
        uint128 liqBefore = _twoSidedLpSetup();
        _sandwichSameBlock();

        uint256 balBefore = token0.balanceOf(alice);
        vm.prank(alice);
        vault.withdraw(50e18, alice, alice); // ~60 idle token0 covers it

        assertEq(token0.balanceOf(alice) - balBefore, 50e18);
        assertEq(uint256(rebalancer.currentLiquidity()), uint256(liqBefore), "no unwind must have happened");
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  B. Keeper rebalance into a two-sided range (needs a swap)
    // ═════════════════════════════════════════════════════════════════════════

    function test_swapPath_keeperTwoSidedRange_coversDeficitWithSwap() public {
        _keeperSetup();
        assertEq(token1.balanceOf(address(rebalancer)), 0, "only the asset is held at the start");

        // referenceTick 0, no divergence => 2 tick spacings => [-120, 120], which contains the price
        vm.prank(automation);
        rebalancer.performUpkeep(abi.encode(int24(0), false));

        assertEq(int256(rebalancer.currentTickLower()), -120);
        assertEq(int256(rebalancer.currentTickUpper()), 120);
        assertEq(uint256(rebalancer.currentLiquidity()), 1e18);

        bytes32 positionId = Position.calculatePositionKey(address(rebalancer), int24(-120), int24(120), bytes32(0));
        assertEq(uint256(POOL_MANAGER.getPositionLiquidity(poolId, positionId)), 1e18);

        // a swap really ran inside the unlock: the hook recorded it in this block
        (,, uint64 lastBlock,,) = hook.getPoolState(key);
        assertEq(uint256(lastBlock), block.number, "the hook must have seen a swap in this block");

        // exact-output swap => the token1 bought is exactly what the LP needed, nothing left over
        assertEq(token1.balanceOf(address(rebalancer)), 0);

        // only swap fees were lost
        assertApproxEqRel(vault.totalAssets(), 100e18, 1e15);
    }

    function test_swapPath_keeperTwoSidedRange_capTooLowReverts() public {
        _keeperSetup();
        rebalancer.setKeeperMaxPay(1, type(uint256).max); // keeper may pay at most 1 wei of token0

        vm.prank(automation);
        vm.expectRevert(CuratioRebalancer.SlippageExceeded.selector);
        rebalancer.performUpkeep(abi.encode(int24(0), false));

        assertEq(uint256(rebalancer.currentLiquidity()), 0, "nothing may have been deployed");
    }

    function test_swapPath_keeperTwoSidedRange_revertsInSandwichBlock() public {
        _keeperSetup();
        _sandwichSameBlock();

        vm.prank(automation);
        vm.expectRevert(CuratioRebalancer.SwapPriceDeviation.selector);
        rebalancer.performUpkeep(abi.encode(int24(0), false));

        assertEq(uint256(rebalancer.currentLiquidity()), 0, "nothing may have been deployed");
    }
}
