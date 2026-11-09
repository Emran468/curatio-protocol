// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";

import {CuratioForkRealTokensTest} from "./CuratioForkRealTokensTest.t.sol";

/**
 * @notice Regression tests for FIX-D: sandwich detection no longer depends on token decimals.
 *
 *         The old size gate compared the RAW `amountSpecified` of each swap with one hook-wide number
 *         (`mevVolumeThreshold`, 1e18). On the real USDC (6 decimals) / WETH (18 decimals) pool that meant a $20k
 *         USDC sandwich was invisible, a ~$12k WETH sandwich was caught, and a threshold tuned for USDC flagged a
 *         $60 WETH round trip. The gate is now the total price impact of the block in TICKS compared with
 *         `sandwichTickThreshold` (default 80), which has no unit and scales with each pool's depth.
 *
 *         Pool: ~$3000 per ETH, full-range liquidity 1e15 (~54,800 USDC + ~18.3 WETH), so
 *         ~$3 of either token moves the price by about 1 tick.
 *
 * Inherits the fixture (and the 7 tests) of CuratioForkRealTokensTest. Run only these with:
 *
 *   forge test --match-path test/fork/CuratioForkDecimalsTest.t.sol --match-test test_decimals -vv
 */
contract CuratioForkDecimalsTest is CuratioForkRealTokensTest {
    /// @dev Performs the swap and reports whether the hook emitted SandwichDetected during it.
    function _swapAndSawSandwich(bool zeroForOne, int256 amountSpecified) internal returns (bool saw) {
        vm.recordLogs();
        _swap(zeroForOne, amountSpecified);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 sig = keccak256("SandwichDetected(bytes32,int24,int24,uint256,uint24)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == sig) return true;
        }
        return false;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  1. A sandwich is detected whichever token its legs are denominated in
    // ═════════════════════════════════════════════════════════════════════════

    /// @dev Flipped: this $20k USDC sandwich used to slip through (raw volume 2e10 < 1e18).
    function test_decimals_usdcDenominatedSandwich_isDetected() public {
        _seedLp(1e15);
        _advance(130);

        _swap(true, -10_000e6); // front-run: 10,000 USDC in, price down
        bool saw = _swapAndSawSandwich(false, int256(10_000e6)); // back-run: 10,000 USDC out (exact output), price up

        // the raw volume is unchanged and still far below the deprecated 1e18 threshold...
        assertLt(hook.getCurrentBlockVolume(key), hook.mevVolumeThreshold());

        // ...but the price impact (thousands of ticks) is what counts now
        assertTrue(saw, "a $20k USDC sandwich is detected");
        assertEq(uint256(hook.getCurrentFee(key)), uint256(MEV_FEE), "the block is flagged");
    }

    function test_decimals_wethDenominatedSandwich_isStillDetected() public {
        _seedLp(1e15);
        _advance(130);

        _swap(false, -2e18); // front-run: 2 WETH in (~$6k), price up
        bool saw = _swapAndSawSandwich(true, -6_000e6); // back-run: 6,000 USDC in, price down

        assertTrue(saw, "a ~$12k sandwich with a WETH leg is detected");
        assertEq(uint256(hook.getCurrentFee(key)), uint256(MEV_FEE), "the block is flagged");
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  2. Dust round trips are not false positives, in either direction
    // ═════════════════════════════════════════════════════════════════════════

    /// @dev Flipped: a ~$60 round trip used to be flagged once the volume threshold was tuned for USDC. Its raw
    ///      amounts are irrelevant now: it moves the price by ~11 ticks per leg (~22 in total), below 80.
    function test_decimals_dustRoundTrips_areNotFlagged_inEitherDirection() public {
        _seedLp(1e15);
        _advance(130);

        // WETH first: 0.01 WETH in, then 30 USDC in
        _swap(false, -1e16);
        assertFalse(_swapAndSawSandwich(true, -30e6), "WETH-first dust round trip is not a sandwich");
        assertGt(hook.getBlockTickMove(key), 0);
        assertLt(hook.getBlockTickMove(key), hook.sandwichTickThreshold());
        assertLt(uint256(hook.getCurrentFee(key)), uint256(MEV_FEE));

        _advance(1); // new block, new tracker

        // USDC first: 30 USDC in, then 0.01 WETH in
        _swap(true, -30e6);
        assertFalse(_swapAndSawSandwich(false, -1e16), "USDC-first dust round trip is not a sandwich");
        assertLt(uint256(hook.getCurrentFee(key)), uint256(MEV_FEE));
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  3. The knob is in ticks and works the same for both tokens
    // ═════════════════════════════════════════════════════════════════════════

    /// @dev The owner can make detection more sensitive through the usual 2-day timelock, and the new value applies
    ///      to the USDC and the WETH leg alike. (`mevVolumeThreshold` is passed unchanged: it is deprecated.)
    function test_decimals_sandwichTickThreshold_isTunableInTicks() public {
        _seedLp(1e15);
        _advance(130);

        hook.proposeTickThresholds(500, 200, hook.mevVolumeThreshold(), 10);
        _advance(2 days);
        hook.executeTickThresholds();
        assertEq(hook.sandwichTickThreshold(), 10);

        // the same ~$60 round trip (~22 ticks in total) now exceeds the 10-tick threshold
        _swap(false, -1e16);
        assertTrue(_swapAndSawSandwich(true, -30e6), "a 22-tick round trip is flagged with a 10-tick threshold");
        assertEq(uint256(hook.getCurrentFee(key)), uint256(MEV_FEE));
    }
}
