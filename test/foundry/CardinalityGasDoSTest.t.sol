// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/*//////////////////////////////////////////////////////////////////////////
    CardinalityGasDoS.t.sol

    Foundry gas-bound & security assertion checks for oracle cardinality
    management, verifying protection against gas DoS and pool-bricking.
//////////////////////////////////////////////////////////////////////////*/

import {Test} from "forge-std/Test.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {CuratioHook} from "../../src/CuratioHook.sol";

contract CardinalityGasDoSTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    CuratioHook internal hook;
    address internal owner = makeAddr("owner");

    PoolKey internal poolKey;
    PoolId internal poolId;

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );

        bytes memory constructorArgs = abi.encode(manager, owner);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), flags, type(CuratioHook).creationCode, constructorArgs);

        hook = new CuratioHook{salt: salt}(manager, owner);
        require(address(hook) == hookAddress, "Hook address mismatch - mining failed");

        (poolKey,) = initPool(currency0, currency1, hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, TickMath.getSqrtPriceAtTick(0));
        poolId = poolKey.toId();

        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: 100 ether,
                salt: bytes32(0)
            }),
            ""
        );
    }

    /*==========================================================================
        BOUNDED GAS & CLAMP TESTS
    ==========================================================================*/

    /// @notice Requesting a massive target clamps growth to `maxCardinalityPerCall`
    ///         instead of reverting or running out of gas.
    function test_IncreaseObservationCardinality_ExceedsCap_ClampsInsteadOfRevert() public {
        // 1. Get initial state (which is 100 from setUp)
        (, uint16 cardinalityBefore,) = hook.getOracleState(poolKey);

        uint256 gasBefore = gasleft();
        // Requesting max uint16 silently clamps instead of reverting
        (, uint16 cardinalityNextNew) = hook.increaseObservationCardinality(poolKey, type(uint16).max);
        uint256 gasUsed = gasBefore - gasleft();

        // 2. Expect growth to be bounded by: starting amount + soft cap (100 + 500 = 600)
        uint16 expectedCardinality = cardinalityBefore + hook.maxCardinalityPerCall();

        assertEq(cardinalityNextNew, expectedCardinality, "single call should silently clamp growth to active cap");

        assertLt(gasUsed, 25_000_000, "cardinality increase used unexpectedly high gas");
    }

    /// @notice Integrators can reach targets above `maxCardinalityPerCall`
    ///         via multiple bounded calls.
    function test_IncreaseObservationCardinality_RepeatedCalls_ReachLargeTarget() public {
        uint16 target = 1500; // Greater than the default soft cap (500)

        while (true) {
            (, uint16 cardinalityNextNew) = hook.increaseObservationCardinality(poolKey, target);
            if (cardinalityNextNew >= target) break;
        }

        (, uint16 finalCardinality, uint16 finalCardinalityNext) = hook.getOracleState(poolKey);
        assertEq(finalCardinalityNext, target, "oracle failed to reach incremental target");
        assertLe(finalCardinality, finalCardinalityNext, "the active ring never exceeds the recorded size");
    }

    /// @notice Setting `initialCardinality` to the allowed cap pre-warms safely
    ///         without bricking `afterInitialize`.
    function test_SetInitialCardinality_AtCap_DoesNotBrickInitialize() public {
        uint16 activeCap = hook.maxCardinalityPerCall();

        vm.prank(owner);
        hook.setInitialCardinality(activeCap);

        PoolKey memory freshKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 120, // Distinct pool
            hooks: hook
        });

        uint256 gasBefore = gasleft();
        manager.initialize(freshKey, TickMath.getSqrtPriceAtTick(0));
        uint256 gasUsed = gasBefore - gasleft();

        assertLt(gasUsed, 25_000_000, "pool initialize with max initialCardinality used unexpectedly high gas");

        (, uint16 cardinality,) = hook.getOracleState(freshKey);
        assertEq(cardinality, activeCap, "oracle should be pre-warmed to configured initialCardinality");
    }

    /*==========================================================================
        GOVERNANCE & PARAMETER SAFETY TESTS
    ==========================================================================*/

    /// @notice Owner cannot set `maxCardinalityPerCall` above `HARD_MAX_CARDINALITY_PER_CALL`.
    function test_MaxCardinalityPerCall_CannotExceedHardCeiling() public {
        uint16 hardCeiling = hook.HARD_MAX_CARDINALITY_PER_CALL();

        vm.prank(owner);
        vm.expectRevert("Exceeds hard ceiling");
        hook.setMaxCardinalityPerCall(hardCeiling + 1);
    }

    /// @notice Setting `initialCardinality` above `maxCardinalityPerCall` must revert.
    function test_SetInitialCardinality_AboveActiveCap_Reverts() public {
        uint16 activeCap = hook.maxCardinalityPerCall();

        vm.prank(owner);
        vm.expectRevert("Exceeds max cardinality per call");
        hook.setInitialCardinality(activeCap + 1);
    }

    /// @notice Setting `initialCardinality` at or below the active cap succeeds.
    function test_SetInitialCardinality_AtCap_Succeeds() public {
        uint16 activeCap = hook.maxCardinalityPerCall();

        vm.prank(owner);
        hook.setInitialCardinality(activeCap);

        assertEq(hook.initialCardinality(), activeCap);
    }
}
