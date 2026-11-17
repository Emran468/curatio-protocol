// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {CuratioHook} from "../../src/CuratioHook.sol";
import {CuratioForkTest} from "./CuratioForkTest.t.sol";

/**
 * @notice Mentor review (UHI11), two findings:
 *
 *   1. The hook depends on the fee override, which PoolManager only honours for dynamic-fee pools, so beforeInitialize
 *      must refuse any other pool (`PoolMustUseDynamicFee`).
 *   2. The sandwich penalty hit the inverse of what was intended: the sandwicher paid a normal fee and the ordinary
 *      swappers that came AFTER the sandwich paid the 10% penalty. Now the BACK-RUN (the swap that reverses the block's
 *      first move) pays it, decided in beforeSwap; the front-run and a victim in the same direction pay a normal fee.
 *
 * Inherits the CuratioForkTest fixture (real Unichain PoolManager). The oracle is left cold (< 120 s old) in the
 * sandwich tests, so the TWAP-deviation guard cannot add a penalty of its own and only the sandwich rule is measured.
 * Run only these with:
 *
 *   forge test --match-path test/fork/CuratioForkMentorFixTest.t.sol --match-test test_mentor -vv
 */
contract CuratioForkMentorFixTest is CuratioForkTest {
    // ═════════════════════════════════════════════════════════════════════════
    //  1. Dynamic-fee requirement
    // ═════════════════════════════════════════════════════════════════════════

    function test_mentor_staticFeePool_isRejected() public {
        PoolKey memory staticKey = PoolKey({
            currency0: key.currency0,
            currency1: key.currency1,
            fee: 3000, // a normal static 0.30% pool
            tickSpacing: 120,
            hooks: key.hooks
        });

        // the check itself, called directly (beforeInitialize is pure): exact error
        vm.expectRevert(CuratioHook.PoolMustUseDynamicFee.selector);
        hook.beforeInitialize(address(this), staticKey, SQRT_PRICE_1_1);

        // and through the real PoolManager, which wraps hook reverts in WrappedError
        vm.expectRevert();
        POOL_MANAGER.initialize(staticKey, SQRT_PRICE_1_1);
    }

    function test_mentor_dynamicFeePool_isAccepted() public {
        PoolKey memory dynamicKey = PoolKey({
            currency0: key.currency0,
            currency1: key.currency1,
            fee: key.fee, // DYNAMIC_FEE_FLAG
            tickSpacing: 120,
            hooks: key.hooks
        });

        POOL_MANAGER.initialize(dynamicKey, SQRT_PRICE_1_1);
        assertTrue(hook.isInitialized(dynamicKey));
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  2. Who pays the sandwich penalty
    // ═════════════════════════════════════════════════════════════════════════

    function test_mentor_attackerBackRunPaysPenalty_victimAndFrontRunDoNot() public {
        _seedLp(1e20);

        uint24 frontRunFee = _swapAndGetFee(true, -10e18); // attacker front-run: price down
        uint24 victimFee = _swapAndGetFee(true, -1e18); // victim, same direction
        uint24 backRunFee = _swapAndGetFee(false, -10e18); // attacker back-run: reverses the move

        assertLt(uint256(frontRunFee), uint256(MEV_FEE), "front-run pays a normal fee");
        assertLt(uint256(victimFee), uint256(MEV_FEE), "the victim must NOT pay the penalty");
        assertEq(uint256(backRunFee), uint256(MEV_FEE), "the back-run must pay the penalty");
    }

    /// @dev A reversal after only a small move (below sandwichTickThreshold = 80 ticks) is ordinary flow.
    function test_mentor_smallReversal_isNotPenalised() public {
        _seedLp(1e20);

        _swap(true, -1e17); // ~ -20 ticks
        uint24 reversalFee = _swapAndGetFee(false, -1e17);

        assertLt(uint256(reversalFee), uint256(MEV_FEE), "a small reversal is not a sandwich");
        assertLt(uint256(hook.getCurrentFee(key)), uint256(MEV_FEE));
    }

    /// @dev The tracker is per block: a swap in the next block starts from scratch and pays a normal fee.
    function test_mentor_penaltyDoesNotCarryIntoTheNextBlock() public {
        _seedLp(1e20);

        _swap(true, -10e18);
        assertEq(uint256(_swapAndGetFee(false, -10e18)), uint256(MEV_FEE), "back-run penalised in its block");

        _advance(1);
        assertLt(uint256(_swapAndGetFee(false, -1e15)), uint256(MEV_FEE), "next block: normal fee");
        assertLt(uint256(_swapAndGetFee(true, -1e15)), uint256(MEV_FEE), "next block: normal fee, either direction");
    }
}
