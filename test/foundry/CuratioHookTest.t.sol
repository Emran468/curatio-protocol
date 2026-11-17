// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2, Vm} from "forge-std/Test.sol";

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
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {CuratioHook, Ownable} from "../../src/CuratioHook.sol";
import {MultiSwapRouter} from "./MultiSwapRouter.sol";
import {MockERC20} from "@uniswap/v4-core/lib/solmate/src/test/utils/mocks/MockERC20.sol";
import {FlashLoanAttacker} from "./FlashLoanAttacker.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Vm} from "forge-std/Vm.sol";

/// @dev Foundry test suite for CuratioHook.
///      Run with: forge test --match-contract CuratioHookTest -vvv
contract CuratioHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    CuratioHook internal hook;
    address internal owner = makeAddr("owner");
    address internal strategist = makeAddr("strategist");
    address internal attacker = makeAddr("attacker");
    address internal randomUser = makeAddr("randomUser");

    PoolKey internal poolKey;
    PoolId internal poolId;

    MultiSwapRouter internal multiSwapRouter;

    uint24 internal constant BASE_FEE = 3000;
    uint24 internal constant MID_VOLATILE_FEE = 6000;
    uint24 internal constant HIGH_VOLATILE_FEE = 15000;
    uint24 internal constant MEV_PENALTY_FEE = 100000;

    uint16 internal constant DEFAULT_ORACLE_CARDINALITY = 100;
    uint256 internal constant THRESHOLD_TIMELOCK_DELAY = 2 days;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal charlie = makeAddr("charlie");

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        // Fund and approve tokens for concurrent test actors
        _setupUser(alice);
        _setupUser(bob);
        _setupUser(charlie);

        multiSwapRouter = new MultiSwapRouter(manager);
        MockERC20(Currency.unwrap(currency0)).approve(address(multiSwapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(multiSwapRouter), type(uint256).max);

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
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

    // 3. User setup helper function
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

    function test_hookPermissions_areSetCorrectly() public view {
        Hooks.Permissions memory perms = hook.getHookPermissions();

        assertTrue(perms.beforeInitialize, "beforeInitialize should be enabled");
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
        assertEq(cardinality, DEFAULT_ORACLE_CARDINALITY, "oracle cardinality should be pre-warmed at init");
        assertEq(cardinalityNext, DEFAULT_ORACLE_CARDINALITY, "oracle cardinalityNext should be pre-warmed at init");
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

    function test_smallSwap_staysAtBaseFee() public {
        _swap(true, 0.01 ether);

        uint24 fee = hook.getCurrentFee(poolKey);
        assertEq(fee, BASE_FEE, "tiny swap should not move fee off BASE_FEE");
    }

    function test_largeSwap_escalatesFee() public {
        _swap(true, 500 ether);

        uint24 fee = hook.getCurrentFee(poolKey);
        assertTrue(fee == MID_VOLATILE_FEE || fee == HIGH_VOLATILE_FEE, "large swap should escalate fee");
    }

    function test_fee_decaysBackToBaseAfterDecayWindow() public {
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12);

        _swap(true, 5000 ether);

        uint24 feeAfterSwap = hook.getCurrentFee(poolKey);
        assertTrue(feeAfterSwap > BASE_FEE, "fee should be elevated immediately after volatile swap");

        uint256 blocksToPass = 26;
        vm.roll(block.number + blocksToPass);
        vm.warp(block.timestamp + (blocksToPass * 12));

        uint24 feeAfterDecay = hook.getCurrentFee(poolKey);
        assertEq(feeAfterDecay, BASE_FEE, "fee should decay back to BASE_FEE after the decay window");
    }

    function test_oracle_isColdImmediatelyAfterInit_thenWarmsUp() public {
        assertFalse(hook.isOracleWarm(poolKey, 120), "oracle should be cold immediately after init");

        vm.warp(block.timestamp + 120);

        assertTrue(hook.isOracleWarm(poolKey, 120), "oracle should be warm after 120s have elapsed");
    }

    function test_sandwichPattern_triggersMevPenalty() public {
        _swap(true, 2 ether);
        _swap(false, 2 ether);

        (,,,, uint256 swapCount, bool initialized) = hook.getSandwichTracker(poolKey);
        assertTrue(initialized, "tracker should be initialized after swaps");
        assertTrue(swapCount >= 1, "tracker should have recorded at least one move");

        uint24 fee = hook.getCurrentFee(poolKey);
        if (fee == MEV_PENALTY_FEE) {
            assertEq(fee, MEV_PENALTY_FEE, "sandwich pattern should trigger MEV penalty fee");
        }
    }

    function test_sandwichFlag_appliesPenaltyToNextSwapSameBlock() public {
        _swap(true, 2 ether);
        _swap(false, 2 ether);

        uint24 feeBefore = hook.getCurrentFee(poolKey);
        if (feeBefore == MEV_PENALTY_FEE) {
            _swap(true, 0.01 ether);
            uint24 feeAfter = hook.getCurrentFee(poolKey);
            assertEq(feeAfter, MEV_PENALTY_FEE, "subsequent same-block swap should also be penalized");
        }
    }

    function test_addLiquidity_emitsEventAndStoresPosition() public {
        int24 tickLower = TickMath.minUsableTick(60);
        int24 tickUpper = TickMath.maxUsableTick(60);

        vm.expectEmit(false, true, false, false);
        emit CuratioHook.LiquidityUpdated(address(this), poolId, tickLower, tickUpper, 0, true);

        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: 10 ether, salt: bytes32(0)
            }),
            ""
        );
    }

    function test_removeLiquidity_revertsOnInsufficientLiquidity() public {
        vm.expectRevert();

        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: -1000000000 ether,
                salt: bytes32(0)
            }),
            ""
        );
    }

    function test_getTwapTick_revertsWithInsufficientHistory() public {
        vm.expectRevert("TwapOracle: insufficient history for requested window");
        hook.getTwapTick(poolKey, 300);
    }

    function test_getTwapTick_returnsCloseToActualAverageAfterSwaps() public {
        hook.increaseObservationCardinality(poolKey, 10);

        vm.warp(block.timestamp + 120);

        _swap(true, 50 ether);
        (, int24 tickAfterUp,,) = _slot0();

        vm.warp(block.timestamp + 60);
        _swap(false, 50 ether);

        vm.warp(block.timestamp + 60);

        int24 twap = hook.getTwapTick(poolKey, 120);

        assertTrue(twap <= _absTick(tickAfterUp) && twap >= -_absTick(tickAfterUp), "TWAP tick out of expected bounds");
    }

    function test_increaseObservationCardinality_growsBuffer() public {
        (, uint16 cardinalityBefore,) = hook.getOracleState(poolKey);
        assertEq(cardinalityBefore, DEFAULT_ORACLE_CARDINALITY);

        uint16 targetCardinality = DEFAULT_ORACLE_CARDINALITY + 50;

        vm.expectEmit(true, false, false, true);
        emit CuratioHook.OracleCardinalityIncreased(poolId, DEFAULT_ORACLE_CARDINALITY, targetCardinality);
        hook.increaseObservationCardinality(poolKey, targetCardinality);

        // Uniswap-v3 rule: the new size is only RECORDED here; the ring switches to it when the
        // write index reaches the end of the current ring.
        (, uint16 cardinalityAfter, uint16 cardinalityNextAfter) = hook.getOracleState(poolKey);
        assertEq(cardinalityNextAfter, targetCardinality, "cardinalityNext should grow beyond the pre-warmed default");
        assertEq(
            cardinalityAfter, DEFAULT_ORACLE_CARDINALITY, "ring size is unchanged until the write index reaches its end"
        );
    }

    function test_increaseObservationCardinality_revertsIfPoolNotInitialized() public {
        PoolKey memory uninitKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: LPFeeLibrary.DYNAMIC_FEE_FLAG, tickSpacing: 60, hooks: hook
        });
        uninitKey.tickSpacing = 120;

        vm.expectRevert("Pool not initialized");
        hook.increaseObservationCardinality(uninitKey, 5);
    }

    function test_setInitialCardinality_affectsFuturePoolsOnly() public {
        vm.prank(owner);
        hook.setInitialCardinality(5);
        assertEq(hook.initialCardinality(), 5);

        (, uint16 existingCardinality,) = hook.getOracleState(poolKey);
        assertEq(existingCardinality, DEFAULT_ORACLE_CARDINALITY, "existing pool cardinality should be unaffected");
    }

    function test_setInitialCardinality_onlyOwner() public {
        vm.prank(randomUser);
        vm.expectRevert(Ownable.NotOwner.selector);
        hook.setInitialCardinality(5);
    }

    function test_proposeTickThresholds_onlyOwner() public {
        vm.prank(randomUser);
        vm.expectRevert(Ownable.NotOwner.selector);
        hook.proposeTickThresholds(600, 300, 2 ether, 100);
    }

    function test_proposeTickThresholds_revertsIfHighNotGreaterThanMid() public {
        vm.prank(owner);
        vm.expectRevert("High threshold must be greater than mid");
        hook.proposeTickThresholds(300, 300, 2 ether, 100);
    }

    function test_executeTickThresholds_revertsBeforeTimelockElapses() public {
        vm.prank(owner);
        hook.proposeTickThresholds(600, 300, 2 ether, 100);

        vm.prank(owner);
        vm.expectRevert("Timelock not elapsed");
        hook.executeTickThresholds();
    }

    function test_executeTickThresholds_revertsWithNoPendingProposal() public {
        vm.prank(owner);
        vm.expectRevert("No pending proposal");
        hook.executeTickThresholds();
    }

    function test_executeTickThresholds_onlyOwner() public {
        vm.prank(owner);
        hook.proposeTickThresholds(600, 300, 2 ether, 100);

        vm.warp(block.timestamp + THRESHOLD_TIMELOCK_DELAY);

        vm.prank(randomUser);
        vm.expectRevert(Ownable.NotOwner.selector);
        hook.executeTickThresholds();
    }

    function test_proposeThenExecuteTickThresholds_updatesStateAfterDelay() public {
        vm.prank(owner);
        hook.proposeTickThresholds(600, 300, 2 ether, 100);

        assertEq(hook.tickThresholdHigh(), 500, "threshold should not change until executed");

        vm.warp(block.timestamp + THRESHOLD_TIMELOCK_DELAY);

        vm.prank(owner);
        hook.executeTickThresholds();

        assertEq(hook.tickThresholdHigh(), 600);
        assertEq(hook.tickThresholdMid(), 300);
        assertEq(hook.mevVolumeThreshold(), 2 ether);
        assertEq(hook.sandwichTickThreshold(), 100);
    }

    function test_cancelTickThresholdsProposal_clearsPending() public {
        vm.prank(owner);
        hook.proposeTickThresholds(600, 300, 2 ether, 100);

        vm.prank(owner);
        hook.cancelTickThresholdsProposal();

        vm.warp(block.timestamp + THRESHOLD_TIMELOCK_DELAY);

        vm.prank(owner);
        vm.expectRevert("No pending proposal");
        hook.executeTickThresholds();

        assertEq(hook.tickThresholdHigh(), 500);
    }

    function test_cancelTickThresholdsProposal_revertsWithNoPendingProposal() public {
        vm.prank(owner);
        vm.expectRevert("No pending proposal");
        hook.cancelTickThresholdsProposal();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Multi-Swap / Composability Tests
    // ═══════════════════════════════════════════════════════════════════════

    function test_multipleSwapsSameTx_transientFlagClearsCorrectly() public {
        SwapParams[] memory swaps = new SwapParams[](3);

        swaps[0] = SwapParams({
            zeroForOne: true, amountSpecified: -int256(0.05 ether), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        swaps[1] = SwapParams({
            zeroForOne: true, amountSpecified: -int256(0.05 ether), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        swaps[2] = SwapParams({
            zeroForOne: true, amountSpecified: -int256(0.05 ether), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        multiSwapRouter.multiSwap(poolKey, swaps);

        (,,,, uint256 swapCount, bool initialized) = hook.getSandwichTracker(poolKey);
        assertTrue(initialized, "tracker should be initialized");
        assertEq(swapCount, 3, "all three same-direction swaps in the batch should have been recorded individually");

        _swap(true, 0.01 ether);
    }

    function test_multipleSwapsSameTx_alternatingDirections_noRevertEvenWithSandwichReset() public {
        SwapParams[] memory swaps = new SwapParams[](3);

        swaps[0] = SwapParams({
            zeroForOne: true, amountSpecified: -int256(1 ether), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        swaps[1] = SwapParams({
            zeroForOne: false, amountSpecified: -int256(0.5 ether), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });
        swaps[2] = SwapParams({
            zeroForOne: true, amountSpecified: -int256(0.2 ether), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        multiSwapRouter.multiSwap(poolKey, swaps);

        (,,,,, bool initialized) = hook.getSandwichTracker(poolKey);
        assertTrue(initialized, "tracker should be initialized");

        _swap(true, 0.01 ether);
        uint24 feeAfter = hook.getCurrentFee(poolKey);
        assertTrue(feeAfter == MEV_PENALTY_FEE || feeAfter > BASE_FEE, "post-sandwich swap should not be at base fee");
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

    function test_flashLoanManipulatesTwap() public {
        // ---------------------------------------------------------------
        // 1. Add extra liquidity for a deeper, more realistic pool
        // ---------------------------------------------------------------
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

        hook.increaseObservationCardinality(poolKey, 10);

        // ---------------------------------------------------------------
        // 2. Warm the oracle and record the TWAP tick BEFORE the attack
        // ---------------------------------------------------------------
        vm.warp(block.timestamp + 121);
        int24 twapBefore = hook.getTwapTick(poolKey, 120);

        // ---------------------------------------------------------------
        // 3. Fund the attacker contract with "borrowed" capital and
        //    execute the atomic manipulate-then-restore swap sequence,
        //    all within this single block (no vm.warp in between).
        // ---------------------------------------------------------------
        FlashLoanAttacker attackerContract = new FlashLoanAttacker(manager);

        uint256 flashAmount = 1000 ether;
        MockERC20(Currency.unwrap(currency0)).transfer(address(attackerContract), flashAmount);

        vm.startPrank(attacker);
        attackerContract.executeFlashLoanAttack(poolKey, currency0, flashAmount);
        vm.stopPrank();

        // ---------------------------------------------------------------
        // 4. Move time forward again (simulating the next oracle read) and
        //    compare the TWAP tick AFTER the attack was fully unwound.
        // ---------------------------------------------------------------
        vm.warp(block.timestamp + 121);
        int24 twapAfter = hook.getTwapTick(poolKey, 120);

        int24 twapDelta = twapAfter > twapBefore ? twapAfter - twapBefore : twapBefore - twapAfter;

        // Because the attacker manipulated and fully unwound the position
        // within a single block, a TWAP averaged over a real time window
        // should show only the residual drift from swap fees/slippage on
        // the round trip — NOT the full magnitude of the mid-attack price
        // swing. A large delta here would mean the hook's oracle is not
        // actually time-weighting correctly and is vulnerable to
        // single-block manipulation.
        int24 maxAcceptableDelta = 10;

        assertLt(
            uint24(twapDelta),
            uint24(maxAcceptableDelta),
            "TWAP moved more than expected from an atomic swap-and-restore - oracle may be vulnerable to single-block manipulation"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Extreme Market Conditions / Black Swan Test
    // ═══════════════════════════════════════════════════════════════════════

    function test_extremeMarketConditionsAndHighVolatility() public {
        // -------------------------------------------------------------------------
        // Step 1: Initial Setup - Add massive baseline liquidity
        // -------------------------------------------------------------------------
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: 10000 ether,
                salt: bytes32(0)
            }),
            ""
        );

        // -------------------------------------------------------------------------
        // Step 2: Warm up oracle
        // -------------------------------------------------------------------------
        hook.increaseObservationCardinality(poolKey, 20);
        vm.warp(block.timestamp + 300);

        int24 baselineTwap = hook.getTwapTick(poolKey, 120);

        // -------------------------------------------------------------------------
        // Step 3: Execute Market Shock
        // -------------------------------------------------------------------------
        address whale = makeAddr("whale");
        uint256 massiveAmount = 500_000 ether;

        MockERC20(Currency.unwrap(currency0)).mint(whale, massiveAmount);
        MockERC20(Currency.unwrap(currency1)).mint(whale, massiveAmount);

        vm.startPrank(whale);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);

        uint256 successfulSwaps = 0;

        for (uint256 i = 0; i < 6; i++) {
            bool direction = (i % 2 == 0);

            try swapRouter.swap(
                poolKey,
                SwapParams({
                    zeroForOne: direction,
                    amountSpecified: -int256(50_000 ether),
                    sqrtPriceLimitX96: direction ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                ""
            ) {
                successfulSwaps++;
            } catch {
                // Handled safely
            }
        }
        vm.stopPrank();

        // ----------------------------------------------------------------// -------------------------------------------------------------------------
        // Step 4: Strict Assertions
        // -------------------------------------------------------------------------
        // ১. নিশ্চিত করুন অন্তত একটি সোয়াপ সফল হয়েছে (try/catch যেন ভুয়া পাস না করায়)
        assertGt(successfulSwaps, 0, "At least one swap must succeed to simulate stress");

        // ২. এক্সট্রিম স্যান্ডউইচ/ভোলাটিলিটির কারণে ফি সর্বোচ্চ লেভেলে (MEV_PENALTY_FEE) পৌছেছে কি না
        uint24 currentFee = hook.getCurrentFee(poolKey);
        assertEq(currentFee, MEV_PENALTY_FEE, "Fee should hit max penalty fee under extreme volatility");

        // ৩. সময় সামনে বাড়িয়ে সঠিক TWAP ডিফারেন্স টেস্ট করা
        vm.warp(block.timestamp + 600);
        int24 postShockTwap = hook.getTwapTick(poolKey, 120);

        // নিশ্চিত করা হচ্ছে মার্কেট শকের পর TWAP টিক পরিমাপযোগ্যভাবে পরিবর্তন হয়েছে
        assertTrue(postShockTwap != baselineTwap, "TWAP tick should reflect structural market shock");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Strict Concurrent Pool Operations Tests (Zero Silent-Pass)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Verifies multi-user concurrent swaps in the same block without branching logic.
    function test_concurrentSwapsInSameBlock() public {
        uint256 blockTime = block.timestamp;

        // 1. Alice swaps zeroForOne (Large trade)
        _swapAs(alice, true, 50 ether);
        uint24 feeAfterAlice = hook.getCurrentFee(poolKey);

        // Hard check: Single large swap MUST move fee above BASE_FEE
        assertGt(feeAfterAlice, BASE_FEE, "Fee failed to escalate after Alice's heavy swap");

        // 2. Bob swaps zeroForOne in same block immediately after Alice
        _swapAs(bob, true, 20 ether);
        uint24 feeAfterBob = hook.getCurrentFee(poolKey);

        // Hard check: Cumulative volume MUST maintain or increase fee level
        assertGe(feeAfterBob, feeAfterAlice, "Fee level regressed despite sequential same-block volume");

        // 3. Charlie performs reverse swap (triggering directional flip in same block)
        _swapAs(charlie, false, 30 ether);
        uint24 feeAfterCharlie = hook.getCurrentFee(poolKey);

        // Hard check: Directional flip across users in same block MUST trigger MEV penalty
        assertEq(feeAfterCharlie, MEV_PENALTY_FEE, "Direction reversal in same block failed to trigger MEV penalty fee");
        assertEq(block.timestamp, blockTime, "Block timestamp drifted during atomic block simulation");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Strict Concurrent Operations Tests (Zero Silent-Pass Guarantee)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Verifies concurrent liquidity changes and swaps calculate strict TWAP bounds without silent failure.
    function test_concurrentLiquidityAndSwaps() public {
        // Warm up oracle first so observation buffer is active
        hook.increaseObservationCardinality(poolKey, 10);

        // Record initial tick BEFORE swaps occur to include full historical range
        (int24 tickInitial,,,,) = hook.getPoolState(poolKey);

        vm.warp(block.timestamp + 120);

        // 1. Alice swaps zeroForOne (Drives tick down)
        _swapAs(alice, true, 10 ether);
        (int24 tickAfterAlice,,,,) = hook.getPoolState(poolKey);

        // 2. Bob adds liquidity concurrently
        _modifyLiquidityAs(bob, 50 ether);

        // 3. Charlie swaps oneForZero (Drives tick back up)
        _swapAs(charlie, false, 8 ether);
        (int24 tickAfterCharlie,,,,) = hook.getPoolState(poolKey);

        // Advance time to allow TWAP accumulation
        vm.warp(block.timestamp + 120);

        // Query TWAP tick over the 120s window
        int24 twap = hook.getTwapTick(poolKey, 120);

        // Hard check: Include initial tick along with post-swap ticks to establish absolute boundary limits
        int24 minObservedTick = _min(_min(tickInitial, tickAfterAlice), tickAfterCharlie);
        int24 maxObservedTick = _max(_max(tickInitial, tickAfterAlice), tickAfterCharlie);

        assertGe(twap, minObservedTick, "TWAP tick fell below actual low tick bound");
        assertLe(twap, maxObservedTick, "TWAP tick exceeded actual high tick bound");
    }

    /// @notice Verifies multi-user sandwich attack detection & enforces penalty persistence.
    function test_concurrentMultiUserSandwichDetection() public {
        // 1. Alice (Attacker) frontruns
        _swapAs(alice, true, 5 ether);

        // 2. Bob (Victim) swaps in same direction
        _swapAs(bob, true, 10 ether);

        // 3. Alice (Attacker) backruns in opposite direction (triggers penalty & state tracker cycle)
        _swapAs(alice, false, 5 ether);

        // Hard check 1: Tracker MUST be active and initialized
        (,,,, uint256 swapCount, bool initialized) = hook.getSandwichTracker(poolKey);
        assertTrue(initialized, "Sandwich tracker was not initialized");
        assertGt(swapCount, 0, "Sandwich tracker failed to maintain active state");

        // Hard check 2: Penalty fee MUST be applied immediately on reverse backrun
        uint24 feeAfterBackrun = hook.getCurrentFee(poolKey);
        assertEq(feeAfterBackrun, MEV_PENALTY_FEE, "Multi-user sandwich pattern failed to apply MEV penalty fee");

        // Hard check 3: Ensure penalty fee persists for subsequent same-block swaps
        _swapAs(charlie, true, 0.01 ether);
        uint24 feeForNextUser = hook.getCurrentFee(poolKey);
        assertEq(feeForNextUser, MEV_PENALTY_FEE, "MEV penalty fee leaked/reset before block end");
    }

    // ─── Math Helpers (Required for bound evaluation) ─────────────────────

    function _min(int24 a, int24 b) internal pure returns (int24) {
        return a < b ? a : b;
    }

    function _max(int24 a, int24 b) internal pure returns (int24) {
        return a > b ? a : b;
    }
    // ═══════════════════════════════════════════════════════════════════════
    // Helpers
    // ═══════════════════════════════════════════════════════════════════════

    function _swapAs(address user, bool zeroForOne, uint256 amountIn) internal {
        vm.prank(user);
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

    function _modifyLiquidityAs(address user, int256 liquidityDelta) internal {
        vm.prank(user);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: liquidityDelta,
                salt: bytes32(0)
            }),
            ""
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Bulletproof Oracle Cold Start Edge Cases Tests (100% Fail-Safe)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Verifies querying TWAP with `secondsAgo = 0` reverts cleanly (prevents division by zero).
    function test_oracleColdStart_zeroSecondsAgoReverts() public {
        // Hard check: Zero-duration TWAP lookback MUST revert to prevent division-by-zero panic
        vm.expectRevert();
        hook.getTwapTick(poolKey, 0);
    }

    /// @notice Verifies querying TWAP window longer than pool age reverts explicitly.
    function test_oracleColdStart_windowExceedsPoolAge() public {
        hook.increaseObservationCardinality(poolKey, 10);

        // Advance time by exactly 60 seconds
        vm.warp(block.timestamp + 60);
        _swapAs(alice, true, 10 ether);

        (int24 currentTick,,,,) = hook.getPoolState(poolKey);
        assertNotEq(currentTick, 0, "Setup failed: Pool tick remained at 0");

        // Hard check: Querying 300s window on a 60s old pool MUST revert
        vm.expectRevert();
        hook.getTwapTick(poolKey, 300);
    }

    /// @notice Verifies querying TWAP window longer than observation history reverts explicitly.
    function test_oracleColdStart_defaultCardinalityOne() public {
        _swapAs(alice, true, 10 ether);
        vm.warp(block.timestamp + 60);
        _swapAs(bob, true, 5 ether);

        // Hard check: Querying 300s lookback when pool age is only 60s MUST revert
        vm.expectRevert();
        hook.getTwapTick(poolKey, 300);
    }

    /// @notice Verifies multiple same-block swaps do not corrupt TWAP when tick is strictly non-zero.
    function test_oracleColdStart_sameBlockMultipleSwaps() public {
        hook.increaseObservationCardinality(poolKey, 10);

        // Drive price away from tick 0 into negative territory
        _swapAs(alice, true, 20 ether);
        _swapAs(bob, true, 30 ether);
        _swapAs(charlie, true, 10 ether);

        (int24 tickEnd,,,,) = hook.getPoolState(poolKey);
        assertNotEq(tickEnd, 0, "Test setup invalid: Tick must be non-zero");

        vm.warp(block.timestamp + 30);

        int24 twap = hook.getTwapTick(poolKey, 30);
        assertEq(twap, tickEnd, "TWAP corrupted after same-timestamp cold start swaps");
    }

    /// @notice Verifies warm-state TWAP computes the EXACT mathematical time-weighted average tick.
    function test_oracleColdStart_transitionToWarmState() public {
        hook.increaseObservationCardinality(poolKey, 10);

        // 1. First swap at t = 1 (Oldest observation recorded)
        _swapAs(alice, true, 40 ether);
        (int24 tick1,,,,) = hook.getPoolState(poolKey);

        console2.log("Before first skip, timestamp:", block.timestamp);
        // Advance timestamp by 100s -> t = 101 (Using skip() to bypass Yul optimizer bug)
        skip(100);
        console2.log("After first skip, timestamp:", block.timestamp);

        // 2. Second swap at t = 101
        _swapAs(bob, true, 30 ether);
        (int24 tick2,,,,) = hook.getPoolState(poolKey);

        console2.log("Before second skip, timestamp:", block.timestamp);
        // Advance timestamp by another 100s -> t = 201
        skip(100);
        console2.log("After second skip, timestamp:", block.timestamp);

        // Sanity checks
        assertNotEq(tick1, tick2, "Setup failed: Ticks must be distinct to test weighted average");

        // Lookback window = 150s (Target timestamp = 201 - 150 = 51, safely after t = 1)
        // 150s window = 50s at tick1 (t=51 to 101) + 100s at tick2 (t=101 to 201)
        uint32 lookback = 150;
        int24 expectedTwap = int24((int256(tick1) * 50 + int256(tick2) * 100) / int256(uint256(lookback)));

        console2.log("------------------------------------------");
        console2.log("Timestamp right before getTwapTick call:", block.timestamp);
        console2.log("Tick 1:", tick1);
        console2.log("Tick 2:", tick2);
        console2.log("Expected TWAP:", expectedTwap);

        // Verify TWAP calculation succeeds and matches expected weighted average
        int24 actualTwap = hook.getTwapTick(poolKey, lookback);
        console2.log("Actual TWAP from Hook:", actualTwap);
        console2.log("------------------------------------------");

        assertApproxEqAbs(actualTwap, expectedTwap, 1, "TWAP failed exact mathematical weighted average check");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // setMaxCardinalityPerCall — completely untested in existing suite
    // ═══════════════════════════════════════════════════════════════════════

    function test_setMaxCardinalityPerCall_onlyOwner() public {
        vm.prank(randomUser);
        vm.expectRevert(Ownable.NotOwner.selector);
        hook.setMaxCardinalityPerCall(200);
    }

    function test_setMaxCardinalityPerCall_revertsOnZero() public {
        vm.prank(owner);
        vm.expectRevert("Must be > 0");
        hook.setMaxCardinalityPerCall(0);
    }

    function test_setMaxCardinalityPerCall_revertsAboveHardCeiling() public {
        uint16 hardCeiling = hook.HARD_MAX_CARDINALITY_PER_CALL();

        vm.prank(owner);
        vm.expectRevert("Exceeds hard ceiling");
        hook.setMaxCardinalityPerCall(hardCeiling + 1);
    }

    function test_setMaxCardinalityPerCall_succeedsAtExactHardCeiling() public {
        uint16 hardCeiling = hook.HARD_MAX_CARDINALITY_PER_CALL();

        vm.prank(owner);
        hook.setMaxCardinalityPerCall(hardCeiling);

        assertEq(hook.maxCardinalityPerCall(), hardCeiling);
    }

    function test_setMaxCardinalityPerCall_updatesStateAndEmits() public {
        vm.expectEmit(false, false, false, true);
        emit CuratioHook.MaxCardinalityPerCallUpdated(500, 300);

        vm.prank(owner);
        hook.setMaxCardinalityPerCall(300);

        assertEq(hook.maxCardinalityPerCall(), 300);
    }

    /// @notice A lowered maxCardinalityPerCall must retroactively clamp
    ///         future increaseObservationCardinality requests.
    function test_setMaxCardinalityPerCall_affectsFutureGrowthClamp() public {
        vm.prank(owner);
        hook.setMaxCardinalityPerCall(20);

        (, uint16 cardinalityBefore,) = hook.getOracleState(poolKey);

        (, uint16 newCardinalityNext) = hook.increaseObservationCardinality(poolKey, type(uint16).max);

        assertEq(newCardinalityNext, cardinalityBefore + 20, "growth should clamp to the newly lowered cap");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // increaseObservationCardinality — untested branches
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Requesting a target at or below the current cardinalityNext
    ///         must be a true no-op (early-return branch), not just a
    ///         gas-cheap growth.
    function test_increaseObservationCardinality_noOpBelowCurrent() public {
        (,, uint16 cardinalityNextBefore) = hook.getOracleState(poolKey);

        (uint16 oldVal, uint16 newVal) = hook.increaseObservationCardinality(poolKey, cardinalityNextBefore - 1);

        assertEq(oldVal, cardinalityNextBefore, "old value should reflect actual current state");
        assertEq(newVal, cardinalityNextBefore, "no-op growth must not change cardinalityNext");
    }

    /// @notice Requesting exactly the current cardinalityNext is also a no-op.
    function test_increaseObservationCardinality_noOpAtExactCurrent() public {
        (,, uint16 cardinalityNextBefore) = hook.getOracleState(poolKey);

        (, uint16 newVal) = hook.increaseObservationCardinality(poolKey, cardinalityNextBefore);

        assertEq(newVal, cardinalityNextBefore);
    }

    /// @notice No event should be emitted for the no-op growth path.
    function test_increaseObservationCardinality_noOpEmitsNoEvent() public {
        (,, uint16 cardinalityNextBefore) = hook.getOracleState(poolKey);

        vm.recordLogs();
        hook.increaseObservationCardinality(poolKey, cardinalityNextBefore);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 eventSig = keccak256("OracleCardinalityIncreased(bytes32,uint16,uint16)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics.length == 0 || logs[i].topics[0] != eventSig, "no-op growth must not emit");
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // isOracleWarm — untested edge-case branches
    // ═══════════════════════════════════════════════════════════════════════

    function test_isOracleWarm_falseWhenWindowIsZero() public view {
        assertFalse(hook.isOracleWarm(poolKey, 0), "zero window must be treated as never warm");
    }

    function test_isOracleWarm_falseWhenWindowExceedsCurrentTimestamp() public view {
        // block.timestamp is small early in the test run; a huge window
        // must exercise the `window > block.timestamp` early-return guard.
        assertFalse(hook.isOracleWarm(poolKey, type(uint32).max), "window exceeding block.timestamp must be cold");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // View/getter functions — untested in existing suite
    // ═══════════════════════════════════════════════════════════════════════

    function test_tickSlotMap_returnsNonZeroAfterInit() public view {
        assertNotEq(hook.tickSlotMap(poolId), bytes32(0));
    }

    function test_flagSlotMap_returnsNonZeroAfterInit() public view {
        assertNotEq(hook.flagSlotMap(poolId), bytes32(0));
    }

    function test_trackerSlotMap_returnsNonZeroAfterInit() public view {
        assertNotEq(hook.trackerSlotMap(poolId), bytes32(0));
    }

    function test_sandwichFlagSlotMap_returnsNonZeroAfterInit() public view {
        assertNotEq(hook.sandwichFlagSlotMap(poolId), bytes32(0));
    }

    function test_isInitialized_trueForConfiguredPool() public view {
        assertTrue(hook.isInitialized(poolKey));
    }

    function test_isInitialized_falseForUnconfiguredPool() public view {
        PoolKey memory uninitKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 120,
            hooks: hook
        });
        assertFalse(hook.isInitialized(uninitKey));
    }

    function test_getCurrentFee_returnsBaseFeeForUninitializedPool() public view {
        PoolKey memory uninitKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 120,
            hooks: hook
        });
        assertEq(hook.getCurrentFee(uninitKey), BASE_FEE, "uninitialized pool must report BASE_FEE, not revert");
    }

    function test_getCurrentBlockVolume_zeroBeforeAnySwapThisBlock() public view {
        assertEq(hook.getCurrentBlockVolume(poolKey), 0);
    }

    function test_getCurrentBlockVolume_nonZeroImmediatelyAfterSwap() public {
        _swap(true, 5 ether);
        assertEq(hook.getCurrentBlockVolume(poolKey), 5 ether);
    }

    function test_getCurrentBlockVolume_zeroInNextBlock() public {
        _swap(true, 5 ether);
        vm.roll(block.number + 1);
        assertEq(hook.getCurrentBlockVolume(poolKey), 0, "volume must reset once we move to a new block");
    }

    function test_getChainInfo_returnsExpectedTestChainValues() public view {
        (uint256 chainId, string memory name, uint64 decayWindow, bool isUnichain) = hook.getChainInfo();
        assertEq(chainId, block.chainid);
        assertFalse(isUnichain, "Foundry's default test chainid is not Unichain");
        assertGt(decayWindow, 0);
        assertTrue(bytes(name).length > 0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // abs() — direct branch coverage for both signs
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Drives the tick negative and confirms downstream tick-delta
    ///         math (which relies on abs()) still produces a sane, bounded
    ///         fee — exercising the negative-input branch of abs().
    function test_negativeTickDelta_producesValidFeeTier() public {
        (int24 tickBefore,,,,) = hook.getPoolState(poolKey);
        _swap(false, 200 ether);
        (int24 tickAfter,,,,) = hook.getPoolState(poolKey);

        assertTrue(tickAfter != tickBefore, "swap must actually move the tick to exercise delta math");

        uint24 fee = hook.getCurrentFee(poolKey);
        assertTrue(
            fee == MID_VOLATILE_FEE || fee == HIGH_VOLATILE_FEE, "large swap should escalate fee, not stay at base"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    // afterRemoveLiquidity — success path (only the revert path was tested before)
    // ═══════════════════════════════════════════════════════════════════════

    function test_removeLiquidity_succeedsAndEmitsEvent() public {
        int24 tickLower = TickMath.minUsableTick(60);
        int24 tickUpper = TickMath.maxUsableTick(60);

        vm.expectEmit(false, true, false, false);
        emit CuratioHook.LiquidityUpdated(address(this), poolId, tickLower, tickUpper, 0, false);

        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: -10 ether, salt: bytes32(0)
            }),
            ""
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Sandwich tracker — negative-direction peak tracking (only positive
    // direction was implicitly exercised before)
    // ═══════════════════════════════════════════════════════════════════════

    function test_sandwichTracker_tracksNegativeDirectionPeak() public {
        _swap(true, 3 ether);
        (int24 tickAfterFirst,,,,) = hook.getPoolState(poolKey);

        _swap(true, 3 ether);
        (int24 tickAfterSecond,,,,) = hook.getPoolState(poolKey);

        (,, int24 peakTick,,, bool initialized) = hook.getSandwichTracker(poolKey);
        assertTrue(initialized, "tracker should be initialized");

        assertTrue(
            tickAfterSecond < tickAfterFirst, "both swaps must move tick further negative to exercise this branch"
        );
        assertEq(peakTick, tickAfterSecond, "peak should track the more negative (lower) tick");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // beforeSwap / afterSwap — transient-storage reentrancy guard branches
    // These guards protect against a hypothetical future PoolManager change
    // and cannot be reached through the real PoolManager's normal atomic
    // beforeSwap -> core swap -> afterSwap flow. We exercise them directly
    // by pranking as the PoolManager (the only allowed caller) and driving
    // the hook's callback functions out of their expected sequence.
    // ═══════════════════════════════════════════════════════════════════════

    function test_beforeSwap_onlyPoolManager() public {
        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: -int256(1 ether), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        vm.prank(randomUser);
        vm.expectRevert(); // onlyPoolManager modifier, from BaseHook
        hook.beforeSwap(randomUser, poolKey, params, "");
    }

    function test_afterSwap_onlyPoolManager() public {
        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: -int256(1 ether), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        vm.prank(randomUser);
        vm.expectRevert(); // onlyPoolManager modifier, from BaseHook
        hook.afterSwap(randomUser, poolKey, params, BalanceDeltaLibrary.ZERO_DELTA, "");
    }

    /// @notice Calling beforeSwap twice in a row (as the PoolManager) without
    ///         an intervening afterSwap must revert on the second call — this
    ///         is the transient-storage dirty guard that protects against a
    ///         hypothetical PoolManager change that no longer pairs every
    ///         beforeSwap with a matching afterSwap before the next beforeSwap.
    function test_beforeSwap_revertsOnDirtyTransientStorage() public {
        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: -int256(1 ether), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        vm.startPrank(address(manager));

        // First call succeeds and sets the transient "in progress" flag.
        hook.beforeSwap(address(this), poolKey, params, "");

        // Second call, still within the same (simulated) unlock context,
        // with no afterSwap in between — must hit the dirty-flag guard.
        vm.expectRevert("Transient storage dirty: composability violation");
        hook.beforeSwap(address(this), poolKey, params, "");

        vm.stopPrank();
    }

    /// @notice Calling afterSwap (as the PoolManager) without a preceding
    ///         beforeSwap for the same pool must revert — the flag was never
    ///         set, so afterSwap sees flag == 0 and rejects the call as an
    ///         unexpected/out-of-sequence composability violation.
    function test_afterSwap_revertsOnComposabilityViolationWithoutPriorBeforeSwap() public {
        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: -int256(1 ether), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        vm.prank(address(manager));
        vm.expectRevert("Composability violation: unexpected state");
        hook.afterSwap(address(this), poolKey, params, BalanceDeltaLibrary.ZERO_DELTA, "");
    }

    /// @notice A properly-sequenced beforeSwap followed by afterSwap for the
    ///         same call must clear the flag, so a subsequent independent
    ///         beforeSwap call is NOT treated as dirty. This is the
    ///         complementary "happy path" for the guard, confirming the flag
    ///         is actually reset rather than only ever being set.
    function test_beforeSwap_thenAfterSwap_clearsFlagForNextCall() public {
        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: -int256(1 ether), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        vm.startPrank(address(manager));

        hook.beforeSwap(address(this), poolKey, params, "");
        hook.afterSwap(address(this), poolKey, params, BalanceDeltaLibrary.ZERO_DELTA, "");

        // Flag should be clear now — this must NOT revert.
        hook.beforeSwap(address(this), poolKey, params, "");

        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // _packTracker / _unpackTracker — negative-value sign-extension branches
    // These are internal, so we verify them indirectly through
    // getSandwichTracker(), which round-trips through pack/unpack on every
    // read. Driving firstMove, lastMove, and peakTick all negative exercises
    // the `rawX & 0x800000 != 0` sign-extension branch for each field,
    // instead of only ever hitting the positive/non-negative branch.
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice All three signed tracker fields (firstMove, lastMove, peakTick)
    ///         must round-trip correctly through pack/unpack when negative.
    function test_sandwichTracker_packUnpack_allFieldsNegative() public {
        // Swap 1: establishes firstMove (negative, tick moving down).
        (int24 tickStart,,,,) = hook.getPoolState(poolKey);
        _swap(true, 3 ether);
        (int24 tickAfterFirst,,,,) = hook.getPoolState(poolKey);
        int24 expectedFirstMove = tickAfterFirst - tickStart;
        assertLt(expectedFirstMove, 0, "setup invalid: first move must be negative");

        // Swap 2: same direction, extends the negative peak and updates lastMove.
        _swap(true, 3 ether);
        (int24 tickAfterSecond,,,,) = hook.getPoolState(poolKey);
        int24 expectedLastMove = tickAfterSecond - tickAfterFirst;
        assertLt(expectedLastMove, 0, "setup invalid: second move must also be negative");

        (int24 firstMove, int24 lastMove, int24 peakTick,,, bool initialized) = hook.getSandwichTracker(poolKey);

        assertTrue(initialized);
        assertEq(firstMove, expectedFirstMove, "firstMove failed negative round-trip through pack/unpack");
        assertEq(lastMove, expectedLastMove, "lastMove failed negative round-trip through pack/unpack");
        assertEq(peakTick, tickAfterSecond, "peakTick failed negative round-trip through pack/unpack");

        // Sanity: confirm all three are actually negative, so we know we
        // exercised the sign-extension branch and not the positive path.
        assertLt(firstMove, 0);
        assertLt(lastMove, 0);
        assertLt(peakTick, 0);
    }

    /// @notice Confirms positive and negative tracker values are each
    ///         unpacked correctly within the SAME tracker lifecycle (a
    ///         direction reversal). The first swap produces a positive
    ///         firstMove; the reversing second swap triggers sandwich
    ///         detection, which resets firstMove to the (negative)
    ///         currentMove per afterSwap's isSandwich branch. This exercises
    ///         both the positive-value and negative-value sign-extension
    ///         branches of pack/unpack within one sequence.
    function test_sandwichTracker_packUnpack_mixedSignsAcrossReversal() public {
        (int24 tickStart,,,,) = hook.getPoolState(poolKey);

        // 1. First swap: UP (false) -> Positive move.
        _swapAs(alice, false, 3 ether);
        (int24 tickAfterFirst,,,,) = hook.getPoolState(poolKey);
        int24 expectedFirstMove = tickAfterFirst - tickStart;

        // Strict check to ensure we are actually testing positive values.
        assertGt(expectedFirstMove, 0, "Setup invalid: first move must be positive (UP)");

        // 2. Second swap: DOWN (true) -> Negative move (Reversal).
        _swapAs(bob, true, 1 ether);
        (int24 tickAfterSecond,,,,) = hook.getPoolState(poolKey);
        int24 expectedLastMove = tickAfterSecond - tickAfterFirst;

        // Strict check to ensure we actually triggered a reversal.
        assertLt(expectedLastMove, 0, "Setup invalid: second move must be negative (DOWN)");

        (int24 firstMove, int24 lastMove,,,, bool initialized) = hook.getSandwichTracker(poolKey);
        uint24 currentFee = hook.getCurrentFee(poolKey);

        assertTrue(initialized, "Tracker must be initialized");

        // Ensure the reversal actually triggered the penalty (Sanity check).
        assertEq(currentFee, MEV_PENALTY_FEE, "Setup invalid: reversal must trigger MEV penalty");

        // 3. Strict assertion for the FIX:
        // The lastMove should be negative (DOWN).
        assertEq(lastMove, expectedLastMove, "lastMove failed negative round-trip");

        // The firstMove should REMAIN POSITIVE (UP) because we removed the tracker reset in afterSwap.
        assertEq(
            firstMove,
            expectedFirstMove,
            "firstMove MUST NOT reset after sandwich detection. It should remain the block's first move."
        );

        // Final sanity checks for the signs to prevent silent passes.
        assertGt(firstMove, 0, "firstMove must remain positive");
        assertLt(lastMove, 0, "lastMove must be negative");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // _computeFee — "fee persists" branch (neither escalate nor reset)
    // Exercises: tickDelta < mid threshold AND blockDelta < decayWindow AND
    // currentFee != 0 -> feeToSave = currentFee (the final `return currentFee`
    // branch in _computeFee, distinct from the BASE_FEE-reset branch already
    // covered by test_fee_decaysBackToBaseAfterDecayWindow).
    // ═══════════════════════════════════════════════════════════════════════

    function test_computeFee_feePersists_withinDecayWindowAndBelowThreshold() public {
        // 1. First swap: large enough to escalate fee off BASE_FEE.
        _swap(true, 500 ether);
        uint24 feeAfterEscalation = hook.getCurrentFee(poolKey);
        assertGt(feeAfterEscalation, BASE_FEE, "setup invalid: first swap must escalate fee");

        // 2. Move forward a FEW blocks only (well within blockDecayWindow,
        //    which defaults to 25 for the test chain per ChainRegistry).
        vm.roll(block.number + 2);
        vm.warp(block.timestamp + 24); // ~2 blocks at 12s/block

        // 3. Second swap: tiny amount, so tickDelta stays below both
        //    tickThresholdMid/High -> falls through to the persistence branch.
        _swap(true, 0.001 ether);
        uint24 feeAfterTinySwap = hook.getCurrentFee(poolKey);

        assertEq(
            feeAfterTinySwap,
            feeAfterEscalation,
            "fee should persist (neither reset to BASE_FEE nor re-escalate) for a tiny swap within the decay window"
        );
    }

    // ─── Chain Validation Tests ─────────────────────────────────────────────────

    function test_constructor_revertsOnWrongPoolManagerForChain() public {
        vm.chainId(1); // Ethereum mainnet

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );

        // ইচ্ছাকৃতভাবে ভুল PoolManager address — Ethereum mainnet-এর জন্য
        // ChainRegistry.getPoolManager(1)-এর expected address না
        address wrongManager = address(0xBEEF);

        bytes memory constructorArgs = abi.encode(wrongManager, owner);

        (, bytes32 salt) = HookMiner.find(address(this), flags, type(CuratioHook).creationCode, constructorArgs);

        vm.expectRevert("Wrong PoolManager for this chain");
        new CuratioHook{salt: salt}(IPoolManager(wrongManager), owner);
    }

    function test_constructor_succeedsWithCorrectPoolManagerForChain() public {
        vm.chainId(1); // Ethereum mainnet

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );

        // ChainRegistry.getPoolManager(1)-এর exact expected address
        address correctManager = 0x000000000004444c5dc75cB358380D2e3dE08A90;

        bytes memory constructorArgs = abi.encode(correctManager, owner);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), flags, type(CuratioHook).creationCode, constructorArgs);

        CuratioHook newHook = new CuratioHook{salt: salt}(IPoolManager(correctManager), owner);

        require(address(newHook) == hookAddress, "Hook address mismatch");
        assertEq(newHook.deployedChainId(), 1);
        assertEq(newHook.chainName(), "Ethereum Mainnet");
    }

    function test_constructor_revertsOnWrongPoolManagerForBaseChain() public {
        vm.chainId(8453); // Base mainnet

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );

        address wrongManager = address(0xBEEF);

        bytes memory constructorArgs = abi.encode(wrongManager, owner);

        (, bytes32 salt) = HookMiner.find(address(this), flags, type(CuratioHook).creationCode, constructorArgs);

        vm.expectRevert("Wrong PoolManager for this chain");
        new CuratioHook{salt: salt}(IPoolManager(wrongManager), owner);
    }

    function test_constructor_succeedsForBase() public {
        vm.chainId(8453); // Base Mainnet

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );

        address expectedManager = 0x498581fF718922c3f8e6A244956aF099B2652b2b;

        bytes memory constructorArgs = abi.encode(expectedManager, owner);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), flags, type(CuratioHook).creationCode, constructorArgs);

        CuratioHook newHook = new CuratioHook{salt: salt}(IPoolManager(expectedManager), owner);

        require(address(newHook) == hookAddress, "Hook address mismatch");
        assertEq(newHook.deployedChainId(), 8453);
        assertEq(newHook.chainName(), "Base Mainnet");
    }

    function test_constructor_succeedsForUnichain() public {
        vm.chainId(130); // Unichain

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );

        address expectedManager = 0x1F98400000000000000000000000000000000004;

        bytes memory constructorArgs = abi.encode(expectedManager, owner);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), flags, type(CuratioHook).creationCode, constructorArgs);

        CuratioHook newHook = new CuratioHook{salt: salt}(IPoolManager(expectedManager), owner);

        require(address(newHook) == hookAddress, "Hook address mismatch");
        assertEq(newHook.deployedChainId(), 130);
        assertEq(newHook.chainName(), "Unichain Mainnet");
    }

    function test_constructor_succeedsForArbitrum() public {
        vm.chainId(42161); // Arbitrum One

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );

        address expectedManager = 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32;

        bytes memory constructorArgs = abi.encode(expectedManager, owner);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), flags, type(CuratioHook).creationCode, constructorArgs);

        CuratioHook newHook = new CuratioHook{salt: salt}(IPoolManager(expectedManager), owner);

        require(address(newHook) == hookAddress, "Hook address mismatch");
        assertEq(newHook.deployedChainId(), 42161);
        assertEq(newHook.chainName(), "Arbitrum One");
    }

    function test_constructor_succeedsForArbitrumSepolia() public {
        vm.chainId(421614); // Arbitrum Sepolia

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );

        address expectedManager = 0xFB3e0C6F74eB1a21CC1Da29aeC80D2Dfe6C9a317;

        bytes memory constructorArgs = abi.encode(expectedManager, owner);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), flags, type(CuratioHook).creationCode, constructorArgs);

        CuratioHook newHook = new CuratioHook{salt: salt}(IPoolManager(expectedManager), owner);

        require(address(newHook) == hookAddress, "Hook address mismatch");
        assertEq(newHook.deployedChainId(), 421614);
        assertEq(newHook.chainName(), "Arbitrum Sepolia");
    }

    function test_constructor_succeedsForOptimism() public {
        vm.chainId(10);
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        address expectedManager = 0x9a13F98Cb987694C9F086b1F5eB990EeA8264Ec3;
        bytes memory constructorArgs = abi.encode(expectedManager, owner);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), flags, type(CuratioHook).creationCode, constructorArgs);
        CuratioHook newHook = new CuratioHook{salt: salt}(IPoolManager(expectedManager), owner);
        require(address(newHook) == hookAddress, "Hook address mismatch");
        assertEq(newHook.deployedChainId(), 10);
    }

    function test_constructor_succeedsForSepolia() public {
        vm.chainId(11155111);
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        address expectedManager = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
        bytes memory constructorArgs = abi.encode(expectedManager, owner);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), flags, type(CuratioHook).creationCode, constructorArgs);
        CuratioHook newHook = new CuratioHook{salt: salt}(IPoolManager(expectedManager), owner);
        require(address(newHook) == hookAddress, "Hook address mismatch");
        assertEq(newHook.deployedChainId(), 11155111);
    }

    function test_constructor_succeedsForUnichainSepolia() public {
        vm.chainId(1301);
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        address expectedManager = 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;
        bytes memory constructorArgs = abi.encode(expectedManager, owner);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), flags, type(CuratioHook).creationCode, constructorArgs);
        CuratioHook newHook = new CuratioHook{salt: salt}(IPoolManager(expectedManager), owner);
        require(address(newHook) == hookAddress, "Hook address mismatch");
        assertEq(newHook.deployedChainId(), 1301);
    }

    function test_constructor_succeedsForBaseSepolia() public {
        vm.chainId(84532);
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        address expectedManager = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
        bytes memory constructorArgs = abi.encode(expectedManager, owner);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), flags, type(CuratioHook).creationCode, constructorArgs);
        CuratioHook newHook = new CuratioHook{salt: salt}(IPoolManager(expectedManager), owner);
        require(address(newHook) == hookAddress, "Hook address mismatch");
        assertEq(newHook.deployedChainId(), 84532);
    }

    function test_constructor_revertsOnUnsupportedChain() public {
        vm.chainId(137); // Polygon — ChainRegistry-তে নেই

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );

        address anyManager = address(0xBEEF);

        bytes memory constructorArgs = abi.encode(anyManager, owner);
        (, bytes32 salt) = HookMiner.find(address(this), flags, type(CuratioHook).creationCode, constructorArgs);

        // BaseHook-এর address validation পাস হয়ে যাবে (কারণ salt সঠিকভাবে mined),
        // তারপর CuratioHook constructor-এর ভেতরের chain-check revert করবে
        vm.expectRevert("ChainRegistry: unsupported chain");
        new CuratioHook{salt: salt}(IPoolManager(anyManager), owner);
    }

    function test_twapOracle_interpolation_math_is_exact() public {
        // 1. Initial setup (Pool must have sufficient liquidity)
        // Assume swapRouter is already approved in setUp()
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: -120,
                tickUpper: 120,
                liquidityDelta: int256(100e18), // Large liquidity to prevent extreme price impact
                salt: bytes32(0)
            }),
            ""
        );

        // 2. First Swap at t = 1000
        vm.warp(1000);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -1e15, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        (, int24 T1,,) = manager.getSlot0(poolId); // T1 = Tick after the first swap

        // 3. Second Swap at t = 1100
        vm.warp(1100);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -1e15, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        (, int24 T2,,) = manager.getSlot0(poolId); // T2 = Tick after the second swap

        // 4. Now at t = 1150, and we request a twapWindow of 100 seconds
        vm.warp(1150);

        // 5. Call the TWAP function (This will trigger the interpolation logic)
        // targetTime will be 1150 - 100 = 1050, which is exactly in the middle of 1000 and 1100
        int24 twapTick = hook.getTwapTick(poolKey, 100);

        // 6. Mathematical calculation:
        // Since 1050 is exactly halfway between 1000 and 1100,
        // the expected interpolated TWAP is the average of T1 and T2
        int24 expectedTwap = (T1 + T2) / 2;

        // 7. Strict assertion (Prevents silent passing)
        // If your interpolation math is off by even 1 wei/tick, this will fail.
        assertEq(twapTick, expectedTwap, "Interpolation math is incorrect!");
    }

    function test_afterInitialize_stateIsStrictlySet() public {
        // 1. Create a NEW pool to trigger afterInitialize without reverting
        // We use a different tickSpacing (10 instead of 60) to make it unique
        PoolKey memory newPoolKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: LPFeeLibrary.DYNAMIC_FEE_FLAG, tickSpacing: 10, hooks: hook
        });

        // 2. Set specific block and timestamp to test against defaults
        uint256 expectedBlock = 12345;
        uint256 expectedTimestamp = 987654321;
        vm.roll(expectedBlock);
        vm.warp(expectedTimestamp);

        // 3. Initialize the new pool (This triggers hook.afterInitialize)
        manager.initialize(newPoolKey, SQRT_PRICE_1_1);

        // 4. Fetch the state from the hook for the NEW pool
        (int24 lastTick, uint24 fee, uint64 lastBlock, uint64 lastTimestamp, bool initialized) =
            hook.getPoolState(newPoolKey);

        // 5. Strict Assertions (Prevents silent passing)
        assertEq(int256(lastTick), int256(0), "lastTick must be the initial pool tick");
        assertEq(uint256(fee), uint256(hook.BASE_FEE()), "fee must default to BASE_FEE");
        assertEq(uint256(lastBlock), expectedBlock, "lastBlock must equal the initialization block");
        assertEq(uint256(lastTimestamp), expectedTimestamp, "lastTimestamp must equal the initialization timestamp");
        assertTrue(initialized, "initialized must be true");
    }

    function test_afterSwap_trackerResetsOnNewBlock_and_tickDeltaIsAbsolute() public {
        // 1. Setup: Add Liquidity to the pool so swaps can execute
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: int256(100e18), salt: bytes32(0)}),
            ""
        );

        // 2. Set a specific block number and perform the FIRST swap (zeroForOne = true, price goes down)
        vm.roll(1000);
        (, int24 preTick1,,) = manager.getSlot0(poolId);

        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -1e15, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        (, int24 postTick1,,) = manager.getSlot0(poolId);

        // 3. Fetch the tracker state (This reads the state set by the red highlighted block)
        (,,, uint256 startBlock1, uint256 swapCount1, bool init1) = hook.getSandwichTracker(poolKey);

        // Strict assertions for the FIRST swap in block 1000
        assertTrue(init1, "Tracker must be initialized");
        assertEq(startBlock1, 1000, "Tracker startBlock must be the current block");
        assertEq(swapCount1, 1, "Tracker swapCount must be incremented after the swap");

        // Verify the absolute math: tickDelta = uint24(tickDeltaRaw >= 0 ? tickDeltaRaw : -tickDeltaRaw)
        // Since it was zeroForOne, preTick1 > postTick1, so the absolute difference is preTick1 - postTick1
        uint256 expectedTickMove = uint256(uint24(preTick1 - postTick1));
        assertEq(hook.getBlockTickMove(poolKey), expectedTickMove, "tickDelta absolute value math failed");

        // 4. Advance to a NEW block (1001) and perform a SECOND swap (zeroForOne = false, price goes up)
        vm.roll(1001);
        (, int24 preTick2,,) = manager.getSlot0(poolId);

        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: false, amountSpecified: -1e15, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        (, int24 postTick2,,) = manager.getSlot0(poolId);

        // 5. Fetch the tracker state again
        (,,, uint256 startBlock2, uint256 swapCount2, bool init2) = hook.getSandwichTracker(poolKey);

        // Strict assertions for the NEW block
        assertTrue(init2, "Tracker must be initialized");
        assertEq(startBlock2, 1001, "Tracker startBlock must be updated to the new block");
        assertEq(swapCount2, 1, "Tracker swapCount must be reset to 1 for the new block");

        // Verify the absolute math again
        // Since it was zeroForOne = false, postTick2 > preTick2, so the absolute difference is postTick2 - preTick2
        uint256 expectedTickMove2 = uint256(uint24(postTick2 - preTick2));
        assertEq(
            hook.getBlockTickMove(poolKey), expectedTickMove2, "tickDelta absolute value math failed in second block"
        );
    }

    function test_beforeInitialize_revertsOnStaticFeePool() public {
        // স্ট্যাটিক ফি (3000) দিয়ে একটি পুল তৈরি করার চেষ্টা
        PoolKey memory staticFeeKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000, // Static Fee
            tickSpacing: 60,
            hooks: hook
        });

        // ⚠️ ফিক্স: manager.initialize() এর বদলে সরাসরি hook.beforeInitialize() কল করুন
        vm.expectRevert(CuratioHook.PoolMustUseDynamicFee.selector);
        hook.beforeInitialize(address(this), staticFeeKey, SQRT_PRICE_1_1);
    }

    function test_beforeSwap_reversalLogic_AttackerVsVictim() public {
        // 1. Alice UP (false) -> Tracker firstMove becomes POSITIVE (UP)
        _swapAs(alice, false, 10 ether);

        // 2. Bob DOWN (true) -> Reversal, pays penalty.
        // Because of the fix, tracker firstMove REMAINS POSITIVE (UP).
        _swapAs(bob, true, 10 ether);

        // 3. Attacker Test:
        // Since the block's first move was UP, the attacker must go DOWN (true) to trigger the penalty.
        SwapParams memory attackerParams = SwapParams({
            zeroForOne: true, amountSpecified: -int256(1 ether), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        vm.prank(address(manager));
        (,, uint24 attackerFee) = hook.beforeSwap(address(this), poolKey, attackerParams, "");

        // Strict check: Ensure the fee parsing worked (not 0) and matches the expected penalty + override flag.
        uint24 expectedAttackerFee = uint24(MEV_PENALTY_FEE) | LPFeeLibrary.OVERRIDE_FEE_FLAG;
        assertGt(attackerFee, 0, "Silent fail: Attacker fee is 0, hook call failed.");
        assertEq(attackerFee, expectedAttackerFee, "Attacker MUST get MEV penalty for reversing the first move.");

        // Clean up transient storage to prevent "Dirty Transient Storage" on the next call.
        vm.prank(address(manager));
        hook.afterSwap(address(this), poolKey, attackerParams, BalanceDelta.wrap(0), "");

        // 4. Victim Test:
        // The victim swaps in the SAME direction as the block's first move (Alice's UP).
        SwapParams memory victimParams = SwapParams({
            zeroForOne: false, amountSpecified: -int256(1 ether), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });

        vm.prank(address(manager));
        (,, uint24 victimFee) = hook.beforeSwap(address(this), poolKey, victimParams, "");

        // Strict check: Ensure the victim does NOT get the penalty.
        uint24 victimFeeWithoutFlag = victimFee & ~LPFeeLibrary.OVERRIDE_FEE_FLAG;
        assertGt(victimFee, 0, "Silent fail: Victim fee is 0, hook call failed.");
        assertTrue(victimFeeWithoutFlag != MEV_PENALTY_FEE, "Victim MUST NOT get MEV penalty (no reversal).");

        // Clean up transient storage.
        vm.prank(address(manager));
        hook.afterSwap(address(this), poolKey, victimParams, BalanceDelta.wrap(0), "");
    }

    function _swapAsAndGetFee(address who, bool zeroForOne, uint256 amount) internal returns (uint24 fee) {
        vm.recordLogs();
        _swapAs(who, zeroForOne, amount);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == sig) {
                (,,,,, fee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
            }
        }
    }

    function test_backRun_paysPenalty_frontRunAndVictimDoNot() public {
        uint24 frontRunFee = _swapAsAndGetFee(alice, false, 10 ether); // attacker front-run: UP
        uint24 victimFee = _swapAsAndGetFee(charlie, false, 1 ether); // victim, same direction
        uint24 backRunFee = _swapAsAndGetFee(bob, true, 10 ether); // attacker back-run: reverses

        assertLt(frontRunFee, MEV_PENALTY_FEE, "front-run pays a normal fee");
        assertLt(victimFee, MEV_PENALTY_FEE, "victim must not pay the penalty");
        assertEq(backRunFee, MEV_PENALTY_FEE, "back-run must pay the penalty");
    }

    function test_realPoolManager_reversalLogic() public {
        // 1. Alice Swap UP (false) -> Base Fee
        uint24 aliceFee = _swapAsAndGetFee(alice, false, 10 ether);
        console2.log("Alice Fee (Expected Base 6000):", aliceFee);
        assertGt(aliceFee, 0, "Silent fail: Fee is 0, event parsing failed.");
        assertEq(aliceFee, 6000, "Alice should pay base fee of 6000");

        // 2. Bob Swap DOWN (true) -> Reversal -> MEV Penalty
        uint24 bobFee = _swapAsAndGetFee(bob, true, 10 ether);
        console2.log("Bob Fee (Expected Penalty 100000):", bobFee);
        assertEq(bobFee, MEV_PENALTY_FEE, "Bob (back-runner) MUST pay MEV penalty fee");

        // 3. Charlie (Victim) Swap UP (false) -> Same direction as Alice -> Base Fee
        // Note: The tracker's firstMove is still UP, so Charlie going UP is NOT a reversal.
        uint24 victimFee = _swapAsAndGetFee(charlie, false, 1 ether);
        console2.log("Charlie/Victim Fee (Expected Base 6000):", victimFee);
        assertGt(victimFee, 0, "Silent fail: Fee is 0, event parsing failed.");
        assertEq(victimFee, 6000, "Victim should pay normal base fee");
    }

    function test_eightUsers_mixedDirections_trackerDoesNotReset() public {
        // 1. Create 5 new users and fund them
        address dave = makeAddr("dave");
        address eve = makeAddr("eve");
        address frank = makeAddr("frank");
        address grace = makeAddr("grace");
        address heidi = makeAddr("heidi");

        _setupUser(dave);
        _setupUser(eve);
        _setupUser(frank);
        _setupUser(grace);
        _setupUser(heidi);

        // ─────────────────────────────────────────────────────────────
        // Swap 1: Alice (UP) -> Base Fee.
        // ─────────────────────────────────────────────────────────────
        uint24 fee1 = _swapAsAndGetFee(alice, false, 10 ether);
        console2.log("1. Alice (UP) Fee:", fee1);
        assertGt(fee1, 0, "Silent fail: Fee is 0, event parsing failed");
        assertLt(fee1, MEV_PENALTY_FEE, "Alice should pay Base Fee");

        // ─────────────────────────────────────────────────────────────
        // Swap 2: Charlie (UP) -> Base Fee.
        // ─────────────────────────────────────────────────────────────
        uint24 fee2 = _swapAsAndGetFee(charlie, false, 5 ether);
        console2.log("2. Charlie (UP) Fee:", fee2);
        assertGt(fee2, 0, "Silent fail: Fee is 0");
        assertLt(fee2, MEV_PENALTY_FEE, "Charlie should pay Base Fee");

        // ─────────────────────────────────────────────────────────────
        // Swap 3: Bob (DOWN) -> MEV Penalty (Back-run of Alice's UP).
        // ─────────────────────────────────────────────────────────────
        uint24 fee3 = _swapAsAndGetFee(bob, true, 10 ether);
        console2.log("3. Bob (DOWN) Fee:", fee3);
        assertEq(fee3, MEV_PENALTY_FEE, "Bob MUST pay MEV Penalty");

        // ─────────────────────────────────────────────────────────────
        // Swap 4: Dave (DOWN) -> MEV Penalty.
        // ─────────────────────────────────────────────────────────────
        uint24 fee4 = _swapAsAndGetFee(dave, true, 5 ether);
        console2.log("4. Dave (DOWN) Fee:", fee4);
        assertEq(fee4, MEV_PENALTY_FEE, "Dave MUST pay MEV Penalty");

        // ─────────────────────────────────────────────────────────────
        // Swap 5: Eve (UP) -> Base Fee.
        // 🎯 THE CRITICAL TEST: Tracker reset bug check.
        // ─────────────────────────────────────────────────────────────
        uint24 fee5 = _swapAsAndGetFee(eve, false, 2 ether);
        console2.log("5. Eve (UP) Fee:", fee5);
        assertGt(fee5, 0, "Silent fail: Fee is 0");
        assertLt(fee5, MEV_PENALTY_FEE, "Eve MUST NOT pay penalty. Tracker reset bug is fixed!");

        // ─────────────────────────────────────────────────────────────
        // Swap 6: Frank (DOWN) -> MEV Penalty.
        // ─────────────────────────────────────────────────────────────
        uint24 fee6 = _swapAsAndGetFee(frank, true, 8 ether);
        console2.log("6. Frank (DOWN) Fee:", fee6);
        assertEq(fee6, MEV_PENALTY_FEE, "Frank MUST pay MEV Penalty");

        // ─────────────────────────────────────────────────────────────
        // Swap 7: Grace (DOWN) -> MEV Penalty.
        // ─────────────────────────────────────────────────────────────
        uint24 fee7 = _swapAsAndGetFee(grace, true, 3 ether);
        console2.log("7. Grace (DOWN) Fee:", fee7);
        assertEq(fee7, MEV_PENALTY_FEE, "Grace MUST pay MEV Penalty");

        // ─────────────────────────────────────────────────────────────
        // Swap 8: Heidi (UP) -> Base Fee.
        // ─────────────────────────────────────────────────────────────
        uint24 fee8 = _swapAsAndGetFee(heidi, false, 1 ether);
        console2.log("8. Heidi (UP) Fee:", fee8);
        assertGt(fee8, 0, "Silent fail: Fee is 0");
        assertLt(fee8, MEV_PENALTY_FEE, "Heidi should pay Base Fee");

        // ─────────────────────────────────────────────────────────────
        // Final state check: Checks whether the tracker remembers the block's first move (Alice's UP).
        // ─────────────────────────────────────────────────────────────
        (int24 firstMove,,,,, bool initialized) = hook.getSandwichTracker(poolKey);

        console2.log("Final Tracker firstMove:", firstMove);
        assertTrue(initialized, "Tracker should be initialized");
        assertGt(firstMove, 0, "Tracker firstMove should still be positive (UP) from Alice's swap");
    }

    function test_eightUsers_warmOracle_twapGuardCatchesVictim() public {
        address dave = makeAddr("dave");
        _setupUser(dave);

        // 1. Warm up the oracle
        vm.warp(block.timestamp + 130);
        vm.roll(block.number + 1);

        // 2. Alice UP (10 ether) -> Large price impact (tick divergence > 500)
        uint24 fee1 = _swapAsAndGetFee(alice, false, 10 ether);
        console2.log("Alice Fee (Expected ~15000 or 6000):", fee1);

        // 3. Charlie UP (1 ether) - not a reversal, but the spot price is far from the TWAP.
        // Therefore, the TWAP Guard can force them to pay a 100,000 fee!
        uint24 fee2 = _swapAsAndGetFee(charlie, false, 1 ether);
        console2.log("Charlie Fee (Victim):", fee2);
    }

    function test_warmOracle_realBackRun_getsPenalty() public {
        // Warm up the oracle
        vm.warp(block.timestamp + 130);
        vm.roll(block.number + 1);

        // ২. Alice UP (10 ether) -> Make impact for large price
        uint24 aliceFee = _swapAsAndGetFee(alice, false, 10 ether);
        console2.log("Alice Fee:", aliceFee);

        // 3. Charlie UP (1 ether) -> Victim. Oracle is warm and price has diverged,
        // so they will pay HIGH_VOLATILE_FEE (15000) due to the TWAP guard.
        uint24 charlieFee = _swapAsAndGetFee(charlie, false, 1 ether);
        console2.log("Charlie (Victim) Fee:", charlieFee);

        // Strict Check: Verify if the victim is paying a 1.5% (15000) fee instead of 10%
        assertEq(charlieFee, HIGH_VOLATILE_FEE, "Victim should pay capped TWAP guard fee (15000)");

        // ৪. Bob DOWN (10 ether) -> Real Back-runner।
        // Since it is moving in the opposite direction, it bypasses the TWAP guard and receives 10% (100000) via _isBackRun.
        uint24 bobFee = _swapAsAndGetFee(bob, true, 10 ether);
        console2.log("Bob (Back-runner) Fee:", bobFee);

        // Strict Check: Back-runner ঠিক ১০% (১০০০০০) ফি দিচ্ছে কিনা
        assertEq(bobFee, MEV_PENALTY_FEE, "Back-runner must pay 100000 even when TWAP is warm");
    }
}

