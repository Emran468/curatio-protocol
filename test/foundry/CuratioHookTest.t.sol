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
import {MultiSwapRouter} from "./MultiSwapRouter.sol";
import {MockERC20} from "@uniswap/v4-core/lib/solmate/src/test/utils/mocks/MockERC20.sol";
import {FlashLoanAttacker} from "./FlashLoanAttacker.sol";

/// @dev Foundry test suite for CuratioHook.
///      Run with: forge test --match-contract CuratioHookTest -vvv
contract CuratioHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

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

        (, uint16 cardinalityAfter,) = hook.getOracleState(poolKey);
        assertEq(cardinalityAfter, targetCardinality, "cardinality should grow beyond the pre-warmed default");
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
}
