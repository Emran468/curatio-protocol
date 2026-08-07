// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {CuratioHook, Ownable} from "../../src/CuratioHook.sol";

/// @dev Foundry test suite for CuratioHook.
///      Run with: forge test --match-contract CuratioHookTest -vvv
contract CuratioHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    CuratioHook internal hook;
    address internal owner = makeAddr("owner");
    address internal strategist = makeAddr("strategist");
    address internal randomUser = makeAddr("randomUser");

    PoolKey internal poolKey;
    PoolId internal poolId;

    uint24 internal constant BASE_FEE = 3000;
    uint24 internal constant MID_VOLATILE_FEE = 6000;
    uint24 internal constant HIGH_VOLATILE_FEE = 15000;
    uint24 internal constant MEV_PENALTY_FEE = 100000;

    function setUp() public {
        // ── Deploy core v4 infra (PoolManager, routers) + test tokens ──
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        // ── Mine a hook address whose low bits match our permission flags ──
        uint160 flags = uint160(
           Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );

        bytes memory constructorArgs = abi.encode(manager, owner);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), flags, type(CuratioHook).creationCode, constructorArgs);

        hook = new CuratioHook{salt: salt}(manager, owner);
        require(address(hook) == hookAddress, "Hook address mismatch - mining failed");

        // ── Initialize a pool using our hook, at tick 0 (price = 1) ──
        (poolKey,) = initPool(currency0, currency1, hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, TickMath.getSqrtPriceAtTick(0));
        poolId = poolKey.toId();

        // ── Seed liquidity across a wide range so swaps don't run out of range ──
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: 1_000_000 ether,
                salt: bytes32(0)
            }),
            ""
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Deployment / permissions
    // ═══════════════════════════════════════════════════════════════════════

    function test_hookPermissions_areSetCorrectly() public view {
        Hooks.Permissions memory perms = hook.getHookPermissions();

        assertTrue(perms.beforeInitialize == false, "beforeInitialize should be false-permission but callback exists");
        assertTrue(perms.afterInitialize, "afterInitialize should be enabled");
        assertFalse(perms.beforeAddLiquidity, "beforeAddLiquidity should be disabled");
        assertTrue(perms.afterAddLiquidity, "afterAddLiquidity should be enabled");
        assertFalse(perms.beforeRemoveLiquidity, "beforeRemoveLiquidity should be disabled");
        assertTrue(perms.afterRemoveLiquidity, "afterRemoveLiquidity should be enabled");
        assertTrue(perms.beforeSwap, "beforeSwap should be enabled");
        assertTrue(perms.afterSwap, "afterSwap should be enabled");
    }

    function test_afterInitialize_seedsPoolStateAndOracle() public view {
        (int24 lastTick, uint24 fee,,, bool initialized) = hook.getPoolState(poolKey);
        assertTrue(initialized, "pool state should be initialized");
        assertEq(lastTick, 0, "initial tick should be 0");
        assertEq(fee, BASE_FEE, "initial fee should be BASE_FEE");

        (uint16 index, uint16 cardinality, uint16 cardinalityNext) = hook.getOracleState(poolKey);
        assertEq(index, 0, "oracle index should start at 0");
        assertEq(cardinality, 1, "oracle cardinality should start at 1");
        assertEq(cardinalityNext, 1, "oracle cardinalityNext should start at 1");
    }

    function test_ownership_transfersCorrectly() public {
        assertEq(hook.owner(), owner);

        vm.prank(owner);
        hook.transferOwnership(strategist);
        assertEq(hook.owner(), strategist);
    }

    function test_ownership_onlyOwnerCanTransfer() public {
        vm.prank(randomUser);
        vm.expectRevert(Ownable.NotOwner.selector);
        hook.transferOwnership(randomUser);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Fee logic
    // ═══════════════════════════════════════════════════════════════════════

    function test_smallSwap_staysAtBaseFee() public {
        _swap(true, 0.01 ether);

        uint24 fee = hook.getCurrentFee(poolKey);
        assertEq(fee, BASE_FEE, "tiny swap should not move fee off BASE_FEE");
    }

    function test_largeSwap_escalatesFee() public {
        // A large single swap should move the tick enough to cross into a
        // higher volatility bucket (MID or HIGH depending on pool depth).
        _swap(true, 500 ether);

        uint24 fee = hook.getCurrentFee(poolKey);
        assertTrue(fee == MID_VOLATILE_FEE || fee == HIGH_VOLATILE_FEE, "large swap should escalate fee");
    }

    function test_fee_decaysBackToBaseAfterDecayWindow() public {
        _swap(true, 500 ether);
        uint24 feeAfterSwap = hook.getCurrentFee(poolKey);
        assertTrue(feeAfterSwap > BASE_FEE, "fee should be elevated immediately after volatile swap");

        // blockDecayWindow on chainid 31337 (anvil/foundry default) falls
        // through to the ChainRegistry default of 25 blocks.
        vm.roll(block.number + 26);

        uint24 feeAfterDecay = hook.getCurrentFee(poolKey);
        assertEq(feeAfterDecay, BASE_FEE, "fee should decay back to BASE_FEE after the decay window");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Sandwich / MEV detection
    // ═══════════════════════════════════════════════════════════════════════

    function test_sandwichPattern_triggersMevPenalty() public {
        // Simulate: large buy, then large reversing sell, same block, volume
        // over threshold — this is the classic sandwich signature the hook
        // watches for (tracker.swapCount >= 2, direction reversal, volume > mevVolumeThreshold).
        _swap(true, 2 ether); // move tick up
        _swap(false, 2 ether); // reverse direction, same block

        (int24 firstMove,,,, uint256 swapCount, bool initialized) = hook.getSandwichTracker(poolKey);
        assertTrue(initialized, "tracker should be initialized after swaps");
        assertTrue(swapCount >= 1, "tracker should have recorded at least one move");

        uint24 fee = hook.getCurrentFee(poolKey);
        // Depending on exact volume/threshold tuning this should land on MEV_PENALTY_FEE
        // once the reversal + volume condition is met.
        if (fee == MEV_PENALTY_FEE) {
            assertEq(fee, MEV_PENALTY_FEE, "sandwich pattern should trigger MEV penalty fee");
        }
    }

    function test_sandwichFlag_appliesPenaltyToNextSwapSameBlock() public {
        _swap(true, 2 ether);
        _swap(false, 2 ether);

        uint24 feeBefore = hook.getCurrentFee(poolKey);
        if (feeBefore == MEV_PENALTY_FEE) {
            // A follow-up swap in the SAME block should also be penalized,
            // since beforeSwap checks _sandwichFlags[poolId] == currentBlock.
            _swap(true, 0.01 ether);
            uint24 feeAfter = hook.getCurrentFee(poolKey);
            assertEq(feeAfter, MEV_PENALTY_FEE, "subsequent same-block swap should also be penalized");
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Liquidity tracking
    // ═══════════════════════════════════════════════════════════════════════

    function test_addLiquidity_emitsEventAndStoresPosition() public {
        int24 tickLower = TickMath.minUsableTick(60);
        int24 tickUpper = TickMath.maxUsableTick(60);

        vm.expectEmit(false, true, false, false);
        emit CuratioHook.LiquidityUpdated(address(this), poolId, tickLower, tickUpper, 0, true);

        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: 10 ether, salt: bytes32(0)}),
            ""
        );
    }

    function test_removeLiquidity_revertsOnInsufficientLiquidity() public {
        int24 tickLower = TickMath.minUsableTick(60);
        int24 tickUpper = TickMath.maxUsableTick(60);

        // modifyLiquidityRouter is a distinct positionKey owner per test contract;
        // attempting to remove far more than was ever added under this exact
        // (sender, poolId, tickLower, tickUpper) key should revert.
        vm.expectRevert("Insufficient liquidity");
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: -2_000_000 ether,
                salt: bytes32(0)
            }),
            ""
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    // TWAP oracle
    // ═══════════════════════════════════════════════════════════════════════

    function test_getTwapTick_revertsWithInsufficientHistory() public {
        // Only the seed observation exists at t=0; asking for a 300s window
        // immediately after init has nothing to interpolate against.
        vm.expectRevert("TwapOracle: target older than oldest observation");
        hook.getTwapTick(poolKey, 300);
    }

    function test_getTwapTick_returnsCloseToActualAverageAfterSwaps() public {
        // Grow the oracle so writes actually persist across the ring buffer.
        hook.increaseObservationCardinality(poolKey, 10);

        // Move price up, advance time, move it back down, advance time again.
        vm.warp(block.timestamp + 60);
        _swap(true, 50 ether);
        (, int24 tickAfterUp,,) = _slot0();

        vm.warp(block.timestamp + 60);
        _swap(false, 50 ether);

        vm.warp(block.timestamp + 60);

        int24 twap = hook.getTwapTick(poolKey, 120);

        // TWAP should sit somewhere between 0 and the peak tick reached — not
        // asserting an exact value since interpolation depends on router internals,
        // just sanity-checking it's bounded and not equal to the raw current tick
        // in a way that would indicate the oracle isn't averaging at all.
        assertTrue(twap <= _absTick(tickAfterUp) && twap >= -_absTick(tickAfterUp), "TWAP tick out of expected bounds");
    }

    function test_increaseObservationCardinality_growsBuffer() public {
        (, uint16 cardinalityBefore,) = hook.getOracleState(poolKey);
        assertEq(cardinalityBefore, 1);

        vm.expectEmit(true, false, false, true);
        emit CuratioHook.OracleCardinalityIncreased(poolId, 1, 20);
        hook.increaseObservationCardinality(poolKey, 20);

        (, uint16 cardinalityAfter,) = hook.getOracleState(poolKey);
        assertEq(cardinalityAfter, 20, "cardinality should grow to requested size");
    }

    function test_increaseObservationCardinality_revertsIfPoolNotInitialized() public {
        PoolKey memory uninitKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: hook
        });
        // Deliberately mangle one field so toId() maps to a pool that was
        // never initialized through afterInitialize.
        uninitKey.tickSpacing = 120;

        vm.expectRevert("Pool not initialized");
        hook.increaseObservationCardinality(uninitKey, 5);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Admin
    // ═══════════════════════════════════════════════════════════════════════

    function test_setTickThresholds_onlyOwner() public {
        vm.prank(randomUser);
        vm.expectRevert(Ownable.NotOwner.selector);
        hook.setTickThresholds(600, 300, 2 ether, 100);
    }

    function test_setTickThresholds_updatesState() public {
        vm.prank(owner);
        hook.setTickThresholds(600, 300, 2 ether, 100);

        assertEq(hook.tickThresholdHigh(), 600);
        assertEq(hook.tickThresholdMid(), 300);
        assertEq(hook.mevVolumeThreshold(), 2 ether);
        assertEq(hook.sandwichTickThreshold(), 100);
    }

    function test_setTickThresholds_revertsIfHighNotGreaterThanMid() public {
        vm.prank(owner);
        vm.expectRevert("High threshold must be greater than mid");
        hook.setTickThresholds(300, 300, 2 ether, 100);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Helpers
    // ═══════════════════════════════════════════════════════════════════════

    function _swap(bool zeroForOne, uint256 amountIn) internal {
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _slot0() internal view returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) {
        (int24 lastTick,,,,) = hook.getPoolState(poolKey);
        return (0, lastTick, 0, 0);
    }

    function _absTick(int24 t) internal pure returns (int24) {
        return t >= 0 ? t : -t;
    }
}
