// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {HookMiner} from "../../lib/uniswap-hooks/lib/v4-periphery/src/utils/HookMiner.sol";
import {CuratioHandler} from "./CuratioHandler.sol";
import {CuratioHook} from "../../src/CuratioHook.sol";

contract CuratioHookInvariantTest is StdInvariant, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    CuratioHandler handler;
    CuratioHook hook;
    PoolKey poolKey;
    PoolId poolId;

    address constant OWNER = address(0xC0FFEE);
    uint32 constant TWAP_WINDOW = 120;

    uint24 constant BASE_FEE = 3000;
    uint24 constant MID_FEE = 6000;
    uint24 constant HIGH_FEE = 15000;
    uint24 constant MEV_PENALTY_FEE = 100000;

    uint16 initialCardinalitySnapshot;

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        // Flags must exactly match CuratioHook.getHookPermissions()
        // (note: beforeInitialize is NOT enabled in CuratioHook).
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );

        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), flags, type(CuratioHook).creationCode, abi.encode(manager, OWNER));

        hook = new CuratioHook{salt: salt}(manager, OWNER);
        require(address(hook) == hookAddress, "Mined address mismatch");

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: hook
        });
        poolId = poolKey.toId();

        manager.initialize(poolKey, SQRT_PRICE_1_1);
        initialCardinalitySnapshot = hook.initialCardinality();

        handler = new CuratioHandler(
            hook,
            manager,
            swapRouter,
            modifyLiquidityRouter,
            poolKey,
            OWNER,
            IERC20(Currency.unwrap(currency0)),
            IERC20(Currency.unwrap(currency1))
        );

        IERC20(Currency.unwrap(currency0)).transfer(address(handler), 1e30);
        IERC20(Currency.unwrap(currency1)).transfer(address(handler), 1e30);

        handler.seedLiquidity();

        // Selector list doubles as a weighting: performSwap appears 4x.
        bytes4[] memory selectors = new bytes4[](14);
        selectors[0] = CuratioHandler.performSwap.selector;
        selectors[1] = CuratioHandler.performSwap.selector;
        selectors[2] = CuratioHandler.performSwap.selector;
        selectors[3] = CuratioHandler.performSwap.selector;
        selectors[4] = CuratioHandler.advanceTime.selector;
        selectors[5] = CuratioHandler.addLiquidity.selector;
        selectors[6] = CuratioHandler.removeLiquidity.selector;
        selectors[7] = CuratioHandler.growOracle.selector;
        selectors[8] = CuratioHandler.proposeThresholds.selector;
        selectors[9] = CuratioHandler.executeThresholds.selector;
        selectors[10] = CuratioHandler.cancelThresholds.selector;
        selectors[11] = CuratioHandler.unauthorizedAdminCall.selector;
        selectors[12] = CuratioHandler.ownerSetMaxCardinality.selector;
        selectors[13] = CuratioHandler.ownerSetInitialCardinality.selector;

        // Without targetContract, Foundry also fuzzes every contract deployed in
        // setUp (PoolManager, routers, tokens, the hook itself) and hits
        // onlyPoolManager/onlyOwner reverts. Pin the fuzzer to the handler only.
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));

        excludeContract(address(manager));
        excludeContract(address(hook));
        excludeContract(address(swapRouter));
        excludeContract(address(modifyLiquidityRouter));
    }

    // ── helpers ───────────────────────────────────────────────────────────────

    function _isValidFee(uint24 fee) internal pure returns (bool) {
        return fee == BASE_FEE || fee == MID_FEE || fee == HIGH_FEE || fee == MEV_PENALTY_FEE;
    }

    function _positionKey(uint256 i) internal view returns (bytes32) {
        (int24 lo, int24 hi) = handler.rangeTicks(i);
        // hook keys positions by the address PoolManager sees as the caller (the router)
        return keccak256(abi.encodePacked(address(modifyLiquidityRouter), poolId, lo, hi));
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Pool / price sanity
    // ═════════════════════════════════════════════════════════════════════════

    function invariant_tickAndPriceValid() public view {
        (uint160 sqrtPriceX96, int24 tick,,) = manager.getSlot0(poolId);
        assertTrue(tick >= TickMath.MIN_TICK && tick <= TickMath.MAX_TICK, "Tick out of range");
        assertTrue(sqrtPriceX96 >= TickMath.MIN_SQRT_PRICE && sqrtPriceX96 < TickMath.MAX_SQRT_PRICE, "Bad sqrtPrice");
    }

    function invariant_poolStaysDynamicFee() public view {
        assertEq(poolKey.fee, LPFeeLibrary.DYNAMIC_FEE_FLAG, "Pool must be dynamic-fee");
    }

    /// Hook's last recorded tick must always equal the pool's real tick
    /// (liquidity changes never move price, swaps always update the hook).
    function invariant_hookTickMatchesPoolTick() public view {
        (int24 lastTick,,,,) = hook.getPoolState(poolKey);
        (, int24 poolTick,,) = manager.getSlot0(poolId);
        assertEq(int256(lastTick), int256(poolTick), "Hook lastTick out of sync with pool");
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Fee logic
    // ═════════════════════════════════════════════════════════════════════════

    function invariant_storedFeeIsValidTier() public view {
        (, uint24 fee,,,) = hook.getPoolState(poolKey);
        assertTrue(_isValidFee(fee), "Stored fee not in {3000, 6000, 15000, 100000}");
    }

    function invariant_currentFeeIsValidTier() public view {
        assertTrue(_isValidFee(hook.getCurrentFee(poolKey)), "getCurrentFee not a valid tier");
    }

    function invariant_feeDecaysToBaseAfterWindow() public view {
        (, uint24 fee, uint64 lastBlock,,) = hook.getPoolState(poolKey);
        if (block.number < lastBlock) return;

        uint256 blockDelta = block.number - lastBlock;
        uint24 current = hook.getCurrentFee(poolKey);

        if (blockDelta >= hook.blockDecayWindow()) {
            assertEq(current, BASE_FEE, "Fee must decay to BASE_FEE after decay window");
        } else {
            assertEq(current, fee, "Fee must equal stored fee inside decay window");
        }
    }

    function invariant_hookStateMatchesLastSwap() public view {
        if (handler.swapCount() == 0) return;
        (int24 lastTick,, uint64 lastBlock, uint64 lastTimestamp, bool initialized) = hook.getPoolState(poolKey);
        assertTrue(initialized, "Pool state must be initialized");
        assertEq(int256(lastTick), int256(handler.lastPostSwapTick()), "lastTick mismatch");
        assertEq(uint256(lastBlock), handler.lastSwapBlock(), "lastBlock mismatch");
        assertEq(uint256(lastTimestamp), handler.lastSwapTimestamp(), "lastTimestamp mismatch");
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Volume + sandwich tracker
    // ═════════════════════════════════════════════════════════════════════════

    function invariant_blockVolumeMatchesGhost() public view {
        uint256 expected = block.number == handler.ghostVolumeBlock() ? handler.ghostBlockVolume() : 0;
        assertEq(hook.getCurrentBlockVolume(poolKey), expected, "Block volume mismatch");
    }

    function invariant_sandwichTrackerConsistent() public view {
        if (handler.swapCount() == 0) return;

        (,, int24 peakTick, uint256 startBlock, uint256 swapCount, bool initialized) =
            hook.getSandwichTracker(poolKey);

        assertTrue(initialized, "Tracker must be initialized after a swap");
        assertEq(startBlock, handler.lastSwapBlock(), "Tracker startBlock != last swap block");
        assertLe(swapCount, handler.ghostSwapsInBlock(), "Tracker swapCount exceeds swaps in block");
        assertTrue(peakTick >= TickMath.MIN_TICK && peakTick <= TickMath.MAX_TICK, "peakTick out of range");
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Liquidity accounting
    // ═════════════════════════════════════════════════════════════════════════

    function invariant_storedPositionsMatchGhost() public view {
        uint256 sum;
        for (uint256 i = 0; i < handler.RANGE_COUNT(); i++) {
            (uint128 liq) = hook.storedPositions(_positionKey(i));
            assertEq(uint256(liq), uint256(handler.ghostLiquidity(i)), "Position liquidity mismatch");
            sum += liq;
        }
        assertEq(sum, handler.totalGhostLiquidity(), "Total position liquidity mismatch");
    }

    function invariant_activeLiquidityNeverExceedsTotal() public view {
        assertLe(
            uint256(manager.getLiquidity(poolId)), handler.totalGhostLiquidity(), "Active liquidity > total added"
        );
    }

    function invariant_seedLiquidityFloor() public view {
        assertGe(uint256(handler.ghostLiquidity(0)), uint256(handler.SEED_LIQUIDITY()), "Seed floor breached");
    }

    function invariant_noUnexpectedLiquidityReverts() public view {
        assertEq(handler.unexpectedLiquidityReverts(), 0, "Hook blocked a valid add/remove liquidity");
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Swap liveness + gas
    // ═════════════════════════════════════════════════════════════════════════

    /// Core DoS check: with ample liquidity, the hook must never be the
    /// reason a swap reverts. On failure, read handler.lastSwapRevertData().
    function invariant_swapsNeverRevert() public view {
        assertEq(handler.unexpectedSwapReverts(), 0, "A swap reverted (see handler.lastSwapRevertData)");
    }

    function invariant_hookGasBounded() public view {
        assertLe(handler.maxSwapGasUsed(), 1_500_000, "Gas explosion in swap path");
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  TWAP oracle
    // ═════════════════════════════════════════════════════════════════════════

    function invariant_oracleStructure() public view {
        (uint16 index, uint16 cardinality, uint16 cardinalityNext) = hook.getOracleState(poolKey);
        assertGe(uint256(cardinality), 1, "cardinality must be >= 1");
        assertLt(uint256(index), uint256(cardinality), "index must be < cardinality");
        assertLe(uint256(cardinality), uint256(cardinalityNext), "cardinality > cardinalityNext");
        assertGe(uint256(cardinality), uint256(initialCardinalitySnapshot), "cardinality fell below initial");
    }

    function invariant_oracleGrowthRules() public view {
        assertFalse(handler.cardinalityDecreased(), "Cardinality decreased");
        assertFalse(handler.growthCapViolated(), "Per-call growth cap violated");
    }

    /// If the oracle claims to be warm, reading the TWAP must not revert and
    /// must return a valid tick. A revert here would also DoS beforeSwap.
    function invariant_warmOracleAlwaysReadable() public view {
        if (!hook.isOracleWarm(poolKey, TWAP_WINDOW)) return;

        try hook.getTwapTick(poolKey, TWAP_WINDOW) returns (int24 twapTick) {
            assertTrue(twapTick >= TickMath.MIN_TICK && twapTick <= TickMath.MAX_TICK, "TWAP tick out of range");
        } catch {
            assertTrue(false, "getTwapTick reverted although oracle is warm");
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Admin / timelock / access control
    // ═════════════════════════════════════════════════════════════════════════

    function invariant_thresholdOrdering() public view {
        assertGt(hook.tickThresholdHigh(), hook.tickThresholdMid(), "high must be > mid");
        assertGt(hook.tickThresholdMid(), 0, "mid must be > 0");
    }

    function invariant_timelockRespected() public view {
        assertFalse(handler.timelockViolated(), "Thresholds applied before timelock / without proposal");
        assertFalse(handler.executeRevertedWhenReady(), "Execute reverted although timelock elapsed");

        (,,,, uint256 eta, bool exists) = hook.pendingThresholds();
        assertEq(exists, handler.ghostHasProposal(), "Pending proposal state mismatch");
        if (exists) {
            assertEq(eta, handler.ghostEta(), "Pending eta mismatch");
        }
    }

    function invariant_accessControl() public view {
        assertEq(hook.owner(), OWNER, "Owner changed unexpectedly");
        assertFalse(handler.accessControlBroken(), "Non-owner executed an owner-only function");
        assertFalse(handler.adminUnexpectedRevert(), "A valid admin/oracle call reverted");
    }

    function invariant_cardinalityCapsWithinHardCeiling() public view {
        assertGt(uint256(hook.maxCardinalityPerCall()), 0, "max cap is zero");
        assertLe(
            uint256(hook.maxCardinalityPerCall()), uint256(hook.HARD_MAX_CARDINALITY_PER_CALL()), "cap > hard ceiling"
        );
        assertGt(uint256(hook.initialCardinality()), 0, "initialCardinality is zero");
    }
}
