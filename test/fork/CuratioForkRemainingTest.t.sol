// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol"; // adjust to your remapping

import {CuratioHook} from "../../src/CuratioHook.sol";
import {CuratioAccess} from "../../src/CuratioAccess.sol";
import {CuratioRebalancer} from "../../src/CuratioRebalancer.sol";
import {CuratioVault} from "../../src/CuratioVault.sol";

contract ForkTestToken is ERC20 {
    constructor() ERC20("Fork Test Token", "FTT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Shared fixture: forks Unichain MAINNET (chain id 130) through UNICHAIN_RPC, deploys a fresh hook with
///      a mined address, two fresh tokens and the real v4 test routers. Nothing existing on chain is touched.
///      Without UNICHAIN_RPC every test is skipped (reported as skipped, never as passed).
abstract contract UnichainForkBase is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    address internal constant PM = 0x1F98400000000000000000000000000000000004;
    uint256 internal constant UNICHAIN_MAINNET = 130;
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336; // 2^96
    int24 internal constant SPACING = 60;

    IPoolManager internal manager = IPoolManager(PM);
    CuratioHook internal hook;
    PoolKey internal key;
    PoolId internal poolId;
    ForkTestToken internal token0;
    ForkTestToken internal token1;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal lpRouter;

    function setUp() public virtual {
        string memory rpc = vm.envOr("UNICHAIN_RPC", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);

        uint256 pinned = vm.envOr("UNICHAIN_FORK_BLOCK", uint256(0));
        if (pinned == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, pinned);

        // Fail loudly if the RPC is the wrong network instead of silently testing something else.
        require(block.chainid == UNICHAIN_MAINNET, "UNICHAIN_RPC must point to Unichain mainnet (chain id 130)");
        require(PM.code.length > 0, "no PoolManager code at the expected address");

        ForkTestToken a = new ForkTestToken();
        ForkTestToken b = new ForkTestToken();
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);

        swapRouter = new PoolSwapTest(manager);
        lpRouter = new PoolModifyLiquidityTest(manager);

        token0.mint(address(this), 1e30);
        token1.mint(address(this), 1e30);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        token0.approve(address(lpRouter), type(uint256).max);
        token1.approve(address(lpRouter), type(uint256).max);
    }

    // -------------------helpers -----------------------

    function _deployHook() internal returns (CuratioHook h) {
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        bytes memory args = abi.encode(manager, address(this));
        // inside a test the CREATE2 deployer is this contract
        (address mined, bytes32 salt) = HookMiner.find(address(this), flags, type(CuratioHook).creationCode, args);
        h = new CuratioHook{salt: salt}(manager, address(this));
        require(address(h) == mined, "mined hook address mismatch");
    }

    function _poolKey(int24 spacing, address h) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: spacing,
            hooks: IHooks(h)
        });
    }

    /// @dev Deploys the hook, optionally lowers the pre-warmed cardinality, initialises the pool and adds
    ///      1e18 liquidity over [-6000, 6000] around price 1.0.
    function _setUpPool(uint16 initialCardinality) internal {
        hook = _deployHook();
        if (initialCardinality != 0) hook.setInitialCardinality(initialCardinality);
        key = _poolKey(SPACING, address(hook));
        poolId = key.toId();
        manager.initialize(key, SQRT_PRICE_1_1);
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 1e18, salt: bytes32(0)}),
            ""
        );
    }

    /// @dev Exact-input swap through the real PoolManager. Returns the fee that was ACTUALLY charged, read from
    ///      the PoolManager's Swap event, and the pool tick after the swap.
    function _swap(bool zeroForOne, uint256 amountIn) internal returns (uint24 fee, int24 tickAfter) {
        vm.recordLogs();
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        fee = _feeFromLogs(logs);
        tickAfter = _tick();
    }

    function _feeFromLogs(Vm.Log[] memory logs) internal pure returns (uint24) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == PM && logs[i].topics[0] == IPoolManager.Swap.selector) {
                (,,,,, uint24 fee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                return fee;
            }
        }
        revert("no PoolManager Swap event found");
    }

    function _tick() internal view returns (int24 t) {
        (, t,,) = manager.getSlot0(poolId);
    }

    function _abs(int24 x) internal pure returns (uint256) {
        return x >= 0 ? uint256(int256(x)) : uint256(-int256(x));
    }

    /// @dev Unichain has 1 s blocks, so seconds and blocks move together.
    function _advance(uint256 secs) internal {
        vm.warp(block.timestamp + secs);
        vm.roll(block.number + secs);
    }
}

/// @notice Remaining Unichain fork tests. Every assertion has a message, every revert expectation names the exact
///         error, and every loop is bounded and asserts that it reached its goal, so no test can pass vacuously.
contract CuratioForkRemainingTest is UnichainForkBase {
    /// Gas budget for initialising a pool with the default 240 pre-warmed slots.
    /// Expected: 239 new non-zero SSTOREs x 22,100 gas ~ 5.3M, plus ~0.4M for the PoolManager and hook writes.
    uint256 internal constant INIT_GAS_BUDGET_240 = 7_500_000;
    /// Budget for the largest allowed pre-warm (maxCardinalityPerCall = 500): 499 x 22,100 ~ 11.0M plus overhead.
    uint256 internal constant INIT_GAS_BUDGET_CAP = 15_000_000;
    /// A new non-zero SSTORE costs at least 20,000 gas, so this is a hard floor proving the writes happened.
    uint256 internal constant MIN_GAS_PER_SLOT = 20_000;


    // 0. Sanity: the fixture really forks Unichain mainnet
    // ------------------------------------------------------

    function test_fork_isRealUnichainMainnet() public {
        hook = _deployHook();
        assertEq(block.chainid, 130, "not Unichain mainnet");
        assertEq(hook.deployedChainId(), 130, "hook did not see chain id 130");
        assertEq(hook.chainName(), "Unichain Mainnet", "hook chain name");
        assertGt(PM.code.length, 0, "PoolManager has no code");
    }

  
    // 2. Pool initialisation: gas and state limits on the live fork
    //=================================================================
    function test_poolInit_defaultCardinality_gasAndState() public {
        hook = _deployHook();
        assertEq(hook.initialCardinality(), 240, "Unichain default must be 240 slots");

        key = _poolKey(SPACING, address(hook));
        poolId = key.toId();

        uint256 gasBefore = gasleft();
        manager.initialize(key, SQRT_PRICE_1_1);
        uint256 gasUsed = gasBefore - gasleft();
        console2.log("pool initialise gas, 240 slots:", gasUsed);

        assertTrue(hook.isInitialized(key), "hook did not register the pool");
        (uint16 index, uint16 cardinality, uint16 cardinalityNext) = hook.getOracleState(key);
        assertEq(index, 0, "oracle index after init");
        assertEq(cardinality, 240, "oracle cardinality after init");
        assertEq(cardinalityNext, 240, "oracle cardinalityNext after init");

        assertGt(gasUsed, 239 * MIN_GAS_PER_SLOT, "too cheap: the pre-warm SSTOREs did not happen");
        assertLt(gasUsed, INIT_GAS_BUDGET_240, "pool initialisation above the expected gas budget");
        assertLt(gasUsed, block.gaslimit, "pool initialisation does not fit in a block");
    }

    function test_poolInit_atMaxCardinalityCap_stillFitsTheBudget() public {
        hook = _deployHook();
        uint16 cap = hook.maxCardinalityPerCall();
        assertEq(cap, 500, "default per-call cap changed; update the budget");

        hook.setInitialCardinality(cap);

        key = _poolKey(SPACING, address(hook));
        poolId = key.toId();

        uint256 gasBefore = gasleft();
        manager.initialize(key, SQRT_PRICE_1_1);
        uint256 gasUsed = gasBefore - gasleft();
        console2.log("pool initialise gas, 500 slots:", gasUsed);

        (, uint16 cardinality, uint16 cardinalityNext) = hook.getOracleState(key);
        assertEq(cardinality, cap, "cardinality at cap");
        assertEq(cardinalityNext, cap, "cardinalityNext at cap");

        assertGt(gasUsed, uint256(cap - 1) * MIN_GAS_PER_SLOT, "too cheap: the pre-warm SSTOREs did not happen");
        assertLt(gasUsed, INIT_GAS_BUDGET_CAP, "max-cap initialisation above the expected gas budget");
        assertLt(gasUsed, block.gaslimit, "max-cap initialisation does not fit in a block");
    }

    function test_poolInit_cannotConfigureBeyondTheCap() public {
        hook = _deployHook();
        uint16 cap = hook.maxCardinalityPerCall();

        vm.expectRevert("Exceeds max cardinality per call");
        hook.setInitialCardinality(cap + 1);

        assertEq(hook.initialCardinality(), 240, "a rejected call must not change the setting");
    }


    // 3a. Sandwich tracker over many blocks: accumulate inside a block, reset on the next
    // ----------------------------------------------------------------------------

    function test_sandwichTracker_accumulatesInsideABlock_andResetsEveryNewBlock() public {
        _setUpPool(0);
        uint256 amount = 1e15; // about 20 ticks on this pool

        // ── block 1: two same-direction swaps accumulate ──
        int24 t0 = _tick();
        _swap(true, amount);
        int24 t1 = _tick();
        _swap(true, amount);
        int24 t2 = _tick();

        uint256 d1 = _abs(t1 - t0);
        uint256 d2 = _abs(t2 - t1);
        assertGt(d1, 0, "first swap did not move the price; raise the amount");
        assertGt(d2, 0, "second swap did not move the price; raise the amount");

        assertEq(hook.getBlockTickMove(key), d1 + d2, "totalMove must be the sum of both swaps");
        (int24 firstMove, int24 lastMove,, uint256 startBlock, uint256 swapCount, bool initialized) =
            hook.getSandwichTracker(key);
        assertTrue(initialized, "tracker not initialised");
        assertEq(startBlock, block.number, "tracker must belong to the current block");
        assertEq(swapCount, 2, "swap count in block 1");
        assertEq(int256(firstMove), int256(t1 - t0), "firstMove");
        assertEq(int256(lastMove), int256(t2 - t1), "lastMove");
        assertEq(hook.getCurrentBlockVolume(key), 2 * amount, "informational block volume must still be tracked");

        // ── following blocks, with different gaps: every block starts from zero ──
        uint256[5] memory gaps = [uint256(1), 2, 1, 7, 1];
        bool zeroForOne = false;
        for (uint256 b = 0; b < gaps.length; b++) {
            _advance(gaps[b]);

            // a view in a new block must report zero, and the stored tracker must still be the OLD block's
            assertEq(hook.getBlockTickMove(key), 0, "tick move must be 0 in a block without swaps");
            (,,, uint256 oldStart,,) = hook.getSandwichTracker(key);
            assertLt(oldStart, block.number, "stored tracker must be stale in a new block");

            int24 before = _tick();
            (uint24 fee, int24 afterTick) = _swap(zeroForOne, amount);
            uint256 delta = _abs(afterTick - before);
            assertGt(delta, 0, "swap did not move the price; raise the amount");

            assertEq(hook.getBlockTickMove(key), delta, "totalMove carried over from an earlier block");
            (,,, uint256 start, uint256 count,) = hook.getSandwichTracker(key);
            assertEq(start, block.number, "tracker block after reset");
            assertEq(count, 1, "swap count after reset");
            assertLt(fee, hook.MEV_PENALTY_FEE(), "MEV penalty carried into a new block");

            zeroForOne = !zeroForOne; // opposite direction to the previous BLOCK must never count as a back-run
        }
    }

    
    // 3b. mevVolumeThreshold is deprecated: old calls keep working, behaviour does not depend on it
    //---------------------------------------------------------------------------------------------------

    function test_mevVolumeThreshold_deprecated_oldCallsWork_andBehaviourIgnoresIt() public {
        _setUpPool(0);
        assertEq(hook.mevVolumeThreshold(), 1 ether, "default must stay for ABI compatibility");

        uint256[3] memory values = [uint256(0), 1, type(uint256).max];
        for (uint256 i = 0; i < values.length; i++) {
            // old-style proposal still accepted, and still timelocked
            vm.expectEmit(false, false, false, true, address(hook));
            emit CuratioHook.ThresholdsProposed(500, 200, values[i], 80, block.timestamp + 2 days);
            hook.proposeTickThresholds(500, 200, values[i], 80);

            vm.expectRevert("Timelock not elapsed");
            hook.executeTickThresholds();

            _advance(2 days + 1);
            vm.expectEmit(false, false, false, true, address(hook));
            emit CuratioHook.ThresholdsUpdated(500, 200, 80);
            hook.executeTickThresholds();

            assertEq(hook.mevVolumeThreshold(), values[i], "stored value must follow the old call");
            assertEq(hook.sandwichTickThreshold(), 80, "tick threshold");

            // A real sandwich in one block: big front-run, then the reversal. It must be penalised
            // whatever mevVolumeThreshold is (0, 1 wei or max uint).
            _advance(1);
            (uint24 frontFee,) = _swap(true, 2e16); // ~400 ticks
            (uint24 backFee,) = _swap(false, 1e15);
            assertLt(frontFee, hook.MEV_PENALTY_FEE(), "front-run must not pay the penalty");
            assertEq(backFee, hook.MEV_PENALTY_FEE(), "back-run must pay the penalty for every volume threshold");

            // The next block starts clean even with an extreme volume threshold.
            _advance(1);
            (uint24 calmFee,) = _swap(true, 1e15);
            assertLt(calmFee, hook.MEV_PENALTY_FEE(), "penalty must not carry into the next block");
        }
    }

  
    // 3c. cardinalityNext switch around the ring wrap: hook and vault stay consistent
    //==================================================================================

    function test_cardinalitySwitch_aroundRingWrap_keepsBeforeSwapAndTotalAssetsConsistent() public {
        // Small ring (8 slots) so the wrap and the switch happen within a few swaps.
        _setUpPool(8);

        // Full stack on top of the hook: the vault is valued through the hook's TWAP.
        CuratioAccess access = new CuratioAccess(address(this));
        CuratioRebalancer rebalancer =
            new CuratioRebalancer(PM, address(hook), address(this), address(this), 1, address(0xA11CE), 1e12);
        CuratioVault vault = new CuratioVault(IERC20(address(token0)), address(access), address(rebalancer), address(this), 0);
        rebalancer.setVault(address(vault));
        rebalancer.setManagedPool(key);
        rebalancer.setAsset(address(token0));
        access.setWhitelistedUser(address(this), true);
        token0.approve(address(vault), type(uint256).max);

        // 1) Cold oracle: the vault cannot be valued (must revert, not return a wrong number).
        vm.expectRevert(CuratioRebalancer.TwapUnavailable.selector);
        vault.totalAssets();

        // 2) Warm up: one small swap every 20 s, alternating direction, until the oracle is warm.
        uint256 steps;
        while (!hook.isOracleWarm(key, 120)) {
            steps++;
            assertLt(steps, 30, "oracle never warmed up");
            _advance(20);
            _swap(steps % 2 == 0, 1e15);
        }
        assertGe(steps, 5, "oracle warmed implausibly fast");

        // 3) Now the vault can be valued and accept a deposit.
        uint256 deposit = 1_000e18;
        vault.deposit(deposit, address(this));
        assertEq(vault.totalAssets(), deposit, "totalAssets right after the deposit");

        // 4) Request growth: it must be RECORDED only, not applied.
        (, uint16 card0, uint16 next0) = hook.getOracleState(key);
        assertEq(card0, 8, "ring size before growth");
        assertEq(next0, 8, "cardinalityNext before growth");
        hook.increaseObservationCardinality(key, 16);
        (, uint16 card1, uint16 next1) = hook.getOracleState(key);
        assertEq(card1, 8, "growth must not be applied immediately");
        assertEq(next1, 16, "cardinalityNext must record the request");

        // 5) Keep swapping across the switch and across later wraps, checking everything at every step.
        bool switched;
        uint256 wraps;
        for (uint256 s = 0; s < 40; s++) {
            (uint16 idxBefore, uint16 cardBefore,) = hook.getOracleState(key);
            _advance(20);
            (uint24 fee, int24 tick) = _swap(s % 2 == 0, 1e15);
            (uint16 idxAfter, uint16 cardAfter, uint16 nextAfter) = hook.getOracleState(key);

            assertGe(cardAfter, cardBefore, "cardinality must never decrease");
            assertEq(nextAfter, 16, "cardinalityNext must stay 16");
            if (idxAfter < idxBefore) wraps++;

            if (cardBefore == 8 && cardAfter == 16) {
                assertFalse(switched, "ring size switched twice");
                assertEq(idxBefore, 7, "the switch must happen when the write index was on the last slot");
                assertEq(idxAfter, 8, "the first write after the switch must land in the first new slot");
                switched = true;
            }

            // beforeSwap still used the warm-oracle path (a cold fallback would charge MID_VOLATILE_FEE)
            assertTrue(hook.isOracleWarm(key, 120), "oracle lost its warmth");
            assertEq(fee, hook.BASE_FEE(), "beforeSwap fell off the warm-oracle path");

            // the TWAP is readable and sane
            int24 twap = hook.getTwapTick(key, 120);
            assertLe(_abs(tick - twap), 100, "TWAP too far from spot on a calm pool");

            // the vault valuation never reverts and never changes
            assertEq(vault.totalAssets(), deposit, "totalAssets changed or reverted around the ring switch");
        }

        assertTrue(switched, "the ring never switched to the larger size");
        assertGe(wraps, 2, "the test never wrapped the ring twice");
        (, uint16 finalCard,) = hook.getOracleState(key);
        assertEq(finalCard, 16, "final ring size");
    }
}
