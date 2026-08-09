// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {CuratioHook} from "../../src/CuratioHook.sol";
import {MultiSwapRouter} from "./MultiSwapRouter.sol";
import {MockERC20} from "@uniswap/v4-core/lib/solmate/src/test/utils/mocks/MockERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

contract GasGriefingTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    CuratioHook public hook;
    PoolKey public poolKey;
    PoolId public poolId;

    address public owner = makeAddr("owner");
    address public attacker = makeAddr("attacker");
    address public lp = makeAddr("lp");
    address public swapper = makeAddr("swapper");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");

    uint24 constant BASE_FEE = 3000;
    uint24 constant MID_VOLATILE_FEE = 6000;
    uint24 constant HIGH_VOLATILE_FEE = 15000;
    uint24 constant MEV_PENALTY_FEE = 100000;
    uint16 constant DEFAULT_CARDINALITY = 100;

    // Events to verify
    event OracleCardinalityIncreased(PoolId indexed poolId, uint16 oldCardinality, uint16 newCardinality);

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        // Fund and approve tokens for test actors
        _setupUser(alice);
        _setupUser(bob);
        _setupUser(charlie);
        _setupUser(attacker);
        _setupUser(swapper);

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

        // Add initial liquidity
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: 1000 ether,
                salt: bytes32(0)
            }),
            ""
        );
    }

    function _setupUser(address user) internal {
        MockERC20(Currency.unwrap(currency0)).mint(user, 100_000 ether);
        MockERC20(Currency.unwrap(currency1)).mint(user, 100_000 ether);

        vm.startPrank(user);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency0)).approve(address(modifyLiquidityRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(modifyLiquidityRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _executeSwap(address user, uint256 amount, bool zeroForOne) internal {
        vm.startPrank(user);
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
    }

    // ============================================================
    // TEST 1: Attacker tries to grow oracle to max cardinality
    // ============================================================
    function test_gasGriefing_maxCardinalityAttempt() public {
        (,, uint16 initialCardinalityNext) = hook.getOracleState(poolKey);

        console2.log("Initial cardinalityNext:", initialCardinalityNext);

        vm.startPrank(attacker);
        uint16 maxCardinality = 65535;

        vm.expectRevert();
        hook.increaseObservationCardinality(poolKey, maxCardinality);

        vm.stopPrank();

        (,, uint16 finalCardinalityNext) = hook.getOracleState(poolKey);
        assertEq(finalCardinalityNext, initialCardinalityNext, "Cardinality should not change on failed attempt");
    }

    // ============================================================
    // TEST 2: Repeated small growth attempts (griefing)
    // ============================================================
    function test_gasGriefing_repeatedSmallGrowths() public {
        (,, uint16 initialCardinalityNext) = hook.getOracleState(poolKey);

        uint256 startGas = gasleft();

        vm.startPrank(attacker);

        uint16 currentGrowth = initialCardinalityNext;
        for (uint256 i = 0; i < 20; i++) {
            uint16 newSize = uint16(currentGrowth + 10);

            uint256 gasBefore = gasleft();
            hook.increaseObservationCardinality(poolKey, newSize);
            uint256 gasUsed = gasBefore - gasleft();

            console2.log("Growth %d gas used:", i, gasUsed);

            // 10 new SSTORE slots cost ~200k+ gas, 300k limit is realistic
            assertLe(gasUsed, 300000, "Each growth should cost reasonable gas");

            currentGrowth = newSize;
        }

        vm.stopPrank();

        uint256 endGas = gasleft();
        uint256 totalGasUsed = startGas - endGas;
        console2.log("Total gas used for 20 growths:", totalGasUsed);

        (,, uint16 finalCardinalityNext) = hook.getOracleState(poolKey);
        uint16 expectedSize = uint16(initialCardinalityNext + 200);
        assertEq(finalCardinalityNext, expectedSize, "Cardinality should grow by 200");
    }

    // ============================================================
    // TEST 3: Multiple attackers simultaneously griefing
    // ============================================================
    function test_gasGriefing_multipleAttackers() public {
        (,, uint16 initialCardinalityNext) = hook.getOracleState(poolKey);

        address[] memory attackers = new address[](5);
        for (uint256 i = 0; i < 5; i++) {
            attackers[i] = makeAddr(string(abi.encodePacked("attacker", i)));
            _setupUser(attackers[i]);
        }

        uint16 targetSize = uint16(initialCardinalityNext + 50);
        uint256 startGas = gasleft();

        for (uint256 i = 0; i < attackers.length; i++) {
            vm.startPrank(attackers[i]);

            uint256 gasBefore = gasleft();
            hook.increaseObservationCardinality(poolKey, targetSize);
            uint256 gasUsed = gasBefore - gasleft();

            console2.log("Attacker %d gas used:", i, gasUsed);

            // 50 SSTORE slots physically require ~1.1M gas on EVM
            assertLe(gasUsed, 1500000, "Gas cost should be reasonable");

            vm.stopPrank();

            targetSize = uint16(targetSize + 10);
        }

        uint256 endGas = gasleft();
        uint256 totalGasUsed = startGas - endGas;
        console2.log("Total gas used by all attackers:", totalGasUsed);

        (,, uint16 finalCardinalityNext) = hook.getOracleState(poolKey);
        uint16 expectedSize = uint16(initialCardinalityNext + 50 + (4 * 10));
        assertGe(finalCardinalityNext, expectedSize, "Cardinality should grow by expected amount");
    }

    // ============================================================
    // TEST 4: Gas griefing affects normal users
    // ============================================================
    function test_gasGriefing_impactOnNormalUsers() public {
        vm.startPrank(owner);
        hook.increaseObservationCardinality(poolKey, 500);
        vm.stopPrank();

        vm.startPrank(attacker);
        hook.increaseObservationCardinality(poolKey, 1000);
        vm.stopPrank();

        uint256 swapAmount = 1 ether;

        // Fixed: _executeSwap manages prank internally
        uint256 gasBefore = gasleft();
        _executeSwap(swapper, swapAmount, true);
        uint256 gasUsed = gasBefore - gasleft();

        console2.log("Normal user swap gas cost after griefing:", gasUsed);

        assertLe(gasUsed, 300000, "Gas cost should not exceed reasonable limit");
    }

    // ============================================================
    // TEST 5: Owner can still function despite griefing
    // ============================================================
    function test_gasGriefing_ownerFunctionsStillWork() public {
        vm.startPrank(attacker);
        for (uint256 i = 0; i < 10; i++) {
            hook.increaseObservationCardinality(poolKey, uint16(100 + i * 50));
        }
        vm.stopPrank();

        vm.startPrank(owner);

        uint256 gasBefore = gasleft();
        hook.proposeTickThresholds(1000, 500, 5 ether, 200);
        uint256 gasUsed = gasBefore - gasleft();
        assertLe(gasUsed, 200000, "Admin functions should still work");

        vm.warp(block.timestamp + 3 days);
        gasBefore = gasleft();
        hook.executeTickThresholds();
        gasUsed = gasBefore - gasleft();
        assertLe(gasUsed, 200000, "Admin execution should still work");

        gasBefore = gasleft();
        hook.setInitialCardinality(200);
        gasUsed = gasBefore - gasleft();
        assertLe(gasUsed, 100000, "Set cardinality should still work");

        vm.stopPrank();

        assertEq(hook.tickThresholdHigh(), 1000, "Thresholds should update");
        assertEq(hook.initialCardinality(), 200, "Initial cardinality should update");
    }

    // ============================================================
    // TEST 6: Handling invalid or no-op cardinality calls
    // ============================================================
    function test_gasGriefing_invalidCardinalityReverts() public {
        (,, uint16 initialCardinalityNext) = hook.getOracleState(poolKey);

        // Setting to 0 is a no-op in TwapOracle.grow
        vm.startPrank(attacker);
        hook.increaseObservationCardinality(poolKey, 0);
        vm.stopPrank();

        (,, uint16 currentCardinalityNext) = hook.getOracleState(poolKey);
        assertEq(currentCardinalityNext, initialCardinalityNext, "Setting 0 should be no-op");

        // Try same cardinality (no-op)
        vm.startPrank(attacker);
        uint256 gasBefore = gasleft();
        hook.increaseObservationCardinality(poolKey, currentCardinalityNext);
        uint256 gasUsed = gasBefore - gasleft();
        console2.log("Gas used for no-op growth:", gasUsed);

        assertLe(gasUsed, 50000, "No-op should be gas efficient");
        vm.stopPrank();

        // Try lower cardinality (no-op)
        uint16 lowerSize = uint16(currentCardinalityNext - 10);
        vm.startPrank(attacker);
        gasBefore = gasleft();
        hook.increaseObservationCardinality(poolKey, lowerSize);
        gasUsed = gasBefore - gasleft();
        console2.log("Gas used for lower cardinality:", gasUsed);

        assertLe(gasUsed, 50000, "Setting lower cardinality should be no-op");
        vm.stopPrank();
    }

    // ============================================================
    // TEST 7: Storage slot initialization cost
    // ============================================================
    function test_gasGriefing_storageInitializationCost() public {
        (,, uint16 initialCardinalityNext) = hook.getOracleState(poolKey);

        uint16 currentSize = initialCardinalityNext;
        uint256[] memory costs = new uint256[](10);

        for (uint256 i = 0; i < 10; i++) {
            uint16 newSize = uint16(currentSize + 1);

            vm.startPrank(attacker);
            uint256 gasBefore = gasleft();
            hook.increaseObservationCardinality(poolKey, newSize);
            uint256 gasUsed = gasBefore - gasleft();
            vm.stopPrank();

            costs[i] = gasUsed;
            console2.log("Slot %d initialization cost:", i, gasUsed);

            // 1 SSTORE slot costs ~30,000 gas
            if (i == 0) {
                assertGt(gasUsed, 20000, "New slot should cost significant gas");
            }

            currentSize = newSize;
        }

        for (uint256 i = 1; i < costs.length; i++) {
            if (i > 1) {
                assertLe(costs[i], costs[i - 1] * 2, "Costs should stabilize");
            }
        }
    }

    // ============================================================
    // TEST 8: Impact on swap gas costs
    // ============================================================
    function test_gasGriefing_swapGasImpact() public {
        // Fixed: _executeSwap manages prank internally
        uint256 baselineGas = gasleft();
        _executeSwap(swapper, 1 ether, true);
        uint256 baselineCost = baselineGas - gasleft();
        console2.log("Baseline swap cost:", baselineCost);

        vm.startPrank(attacker);
        hook.increaseObservationCardinality(poolKey, 1000);
        vm.stopPrank();

        uint256 afterGrowthGas = gasleft();
        _executeSwap(swapper, 1 ether, true);
        uint256 afterGrowthCost = afterGrowthGas - gasleft();
        console2.log("Swap cost after growth:", afterGrowthCost);

        uint256 gasIncrease = afterGrowthCost > baselineCost ? afterGrowthCost - baselineCost : 0;
        console2.log("Gas increase due to growth:", gasIncrease);

        assertLe(gasIncrease, baselineCost * 2, "Gas increase should be bounded");
    }

    // ============================================================
    // TEST 9: Growth vs no-growth gas comparison
    // ============================================================
    function test_gasGriefing_growthVsNoGrowth() public {
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );

        bytes memory constructorArgs = abi.encode(manager, owner);
        (address hookAddress2, bytes32 salt2) =
            HookMiner.find(address(this), flags, type(CuratioHook).creationCode, constructorArgs);

        CuratioHook hook2 = new CuratioHook{salt: salt2}(manager, owner);
        require(address(hook2) == hookAddress2, "Hook2 address mismatch");

        (PoolKey memory key2,) =
            initPool(currency0, currency1, hook2, LPFeeLibrary.DYNAMIC_FEE_FLAG, TickMath.getSqrtPriceAtTick(0));

        modifyLiquidityRouter.modifyLiquidity(
            key2,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: 1000 ether,
                salt: bytes32(0)
            }),
            ""
        );

        vm.startPrank(owner);
        hook.increaseObservationCardinality(poolKey, 500);
        vm.stopPrank();

        uint256 gasPool1 = _measureSwapGas(poolKey);
        uint256 gasPool2 = _measureSwapGas(key2);

        console2.log("Pool 1 (grown) swap cost:", gasPool1);
        console2.log("Pool 2 (default) swap cost:", gasPool2);

        assertGe(gasPool1, gasPool2, "Grown pool should have higher gas cost");

        uint256 difference = gasPool1 - gasPool2;
        assertLe(difference, 100000, "Gas difference should be reasonable");
    }

    function _measureSwapGas(PoolKey memory key) internal returns (uint256) {
        vm.startPrank(swapper);
        uint256 gasBefore = gasleft();

        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(1 ether), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 gasUsed = gasBefore - gasleft();
        vm.stopPrank();
        return gasUsed;
    }

    // ============================================================
    // TEST 10: Event emissions on growth
    // ============================================================
    function test_gasGriefing_eventEmissions() public {
        vm.recordLogs();

        vm.startPrank(owner);
        hook.increaseObservationCardinality(poolKey, 200);
        vm.stopPrank();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool eventFound = false;

        // Fixed UDVT type in topic keccak256
        bytes32 eventSig = keccak256("OracleCardinalityIncreased(bytes32,uint16,uint16)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == eventSig) {
                eventFound = true;
                break;
            }
        }

        assertTrue(eventFound, "OracleCardinalityIncreased event should be emitted");

        vm.recordLogs();

        vm.startPrank(attacker);
        hook.increaseObservationCardinality(poolKey, 100);
        vm.stopPrank();

        logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == eventSig) {
                fail("No event should be emitted for no-op growth");
            }
        }
    }

    // ============================================================
    // TEST 11: Growth with insufficient gas
    // ============================================================
    function test_gasGriefing_insufficientGas() public {
        uint256 gasLimit = 100000;

        vm.startPrank(attacker);

        uint256 gasBefore = gasleft();
        bool success;

        (success,) = address(hook).call{gas: gasLimit}(
            abi.encodeWithSelector(hook.increaseObservationCardinality.selector, poolKey, uint16(1000))
        );

        console2.log("Gas used before revert:", gasBefore - gasleft());
        console2.log("Success:", success);

        assertFalse(success, "Should fail with insufficient gas");
        vm.stopPrank();
    }

    // ============================================================
    // TEST 12: Multiple pools gas griefing impact
    // ============================================================
    function test_gasGriefing_multiplePools() public {
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );

        bytes memory constructorArgs = abi.encode(manager, owner);
        (address hookAddress2, bytes32 salt2) =
            HookMiner.find(address(this), flags, type(CuratioHook).creationCode, constructorArgs);

        CuratioHook hook2 = new CuratioHook{salt: salt2}(manager, owner);
        require(address(hook2) == hookAddress2, "Hook2 address mismatch");

        (PoolKey memory key2,) =
            initPool(currency0, currency1, hook2, LPFeeLibrary.DYNAMIC_FEE_FLAG, TickMath.getSqrtPriceAtTick(0));

        modifyLiquidityRouter.modifyLiquidity(
            key2,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: 1000 ether,
                salt: bytes32(0)
            }),
            ""
        );

        vm.startPrank(attacker);

        uint256 gasPool1 = gasleft();
        hook.increaseObservationCardinality(poolKey, 500);
        uint256 gasUsed1 = gasPool1 - gasleft();

        uint256 gasPool2 = gasleft();
        hook2.increaseObservationCardinality(key2, 500);
        uint256 gasUsed2 = gasPool2 - gasleft();

        vm.stopPrank();

        console2.log("Pool 1 growth gas cost:", gasUsed1);
        console2.log("Pool 2 growth gas cost:", gasUsed2);

        assertTrue(gasUsed1 > 0 && gasUsed2 > 0, "Both pools should be griefable");
        assertLe(gasUsed1, gasUsed2 * 2, "Gas costs should be similar across pools");
    }
}
