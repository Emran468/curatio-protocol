// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {CuratioHook} from "../../src/CuratioHook.sol";

/// @notice Fuzz handler for CuratioHook invariants.
/// Every action is wrapped in try/catch and mirrored into "ghost" variables,
/// so the invariant contract can compare the hook's on-chain state against
/// what *should* have happened.
contract CuratioHandler is CommonBase, StdUtils {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // ── Config ────────────────────────────────────────────────────────────────
    uint128 public constant SEED_LIQUIDITY = 1e18;
    uint256 public constant RANGE_COUNT = 3;

    CuratioHook public immutable hook;
    IPoolManager public immutable manager;
    PoolSwapTest public immutable swapRouter;
    PoolModifyLiquidityTest public immutable liquidityRouter;
    address public immutable owner;

    PoolKey internal key;
    PoolId internal poolId;

    // ── Swap ghosts ───────────────────────────────────────────────────────────
    uint256 public swapCount;
    uint256 public skippedSwaps;
    /// @dev Swap reverts CAUSED BY THE HOOK: PoolManager wraps any hook revert in WrappedError(...).
    uint256 public unexpectedSwapReverts;
    bytes public lastSwapRevertData;
    /// @dev Reverts that did NOT come from the hook (PoolManager / router at extreme prices, overflow of the
    ///      swap maths, ...). Counted and kept for inspection, but not treated as a hook failure.
    uint256 public otherSwapReverts;
    bytes public lastOtherSwapRevertData;
    // what the last failing swap looked like
    int24 public lastFailedTickBefore;
    bool public lastFailedZeroForOne;
    int256 public lastFailedAmountSpecified;
    bytes4 internal constant WRAPPED_ERROR_SELECTOR = bytes4(keccak256("WrappedError(address,bytes4,bytes,bytes)"));

    int24 public lastTickDelta;
    int24 public lastPostSwapTick;
    uint256 public lastSwapBlock;
    uint256 public lastSwapTimestamp;
    uint256 public lastSwapGasUsed;
    uint256 public maxSwapGasUsed;

    // per-block volume ghost (mirrors hook.blockVolumeMap / lastVolumeBlockMap)
    uint256 public ghostVolumeBlock = type(uint256).max;
    uint256 public ghostBlockVolume;
    uint256 public ghostSwapsInBlock;

    // ── Liquidity ghosts ──────────────────────────────────────────────────────
    uint128[3] public ghostLiquidity;
    uint256 public unexpectedLiquidityReverts;
    uint256 public routerAssertSkips; // PoolModifyLiquidityTest assert on fee-netted deltas (not a hook issue)
    bool public seeded;

    /// @dev PoolModifyLiquidityTest asserts that an add/remove nets out as a
    ///      pure payment/receipt. When accrued fees exceed the principal the
    ///      net delta flips sign and the router panics with Panic(0x01).
    ///      That is a test-router quirk, so it must not count as a hook failure.
    function _isRouterAssert(bytes memory reason) internal pure returns (bool) {
        if (reason.length != 36) return false;
        bytes4 sel;
        uint256 code;
        assembly {
            sel := mload(add(reason, 32))
            code := mload(add(reason, 36))
        }
        return sel == bytes4(0x4e487b71) && code == 1;
    }

    // ── Oracle ghosts ─────────────────────────────────────────────────────────
    bool public cardinalityDecreased;
    bool public growthCapViolated;

    // ── Admin / timelock ghosts ───────────────────────────────────────────────
    bool public ghostHasProposal;
    uint256 public ghostEta;
    bool public timelockViolated; // executed before eta, or without a proposal
    bool public executeRevertedWhenReady; // execute failed although eta passed
    bool public accessControlBroken; // a non-owner call succeeded
    bool public adminUnexpectedRevert;

    constructor(
        CuratioHook _hook,
        IPoolManager _manager,
        PoolSwapTest _swapRouter,
        PoolModifyLiquidityTest _liquidityRouter,
        PoolKey memory _key,
        address _owner,
        IERC20 _token0,
        IERC20 _token1
    ) {
        hook = _hook;
        manager = _manager;
        swapRouter = _swapRouter;
        liquidityRouter = _liquidityRouter;
        key = _key;
        poolId = _key.toId();
        owner = _owner;

        _token0.approve(address(_swapRouter), type(uint256).max);
        _token1.approve(address(_swapRouter), type(uint256).max);
        _token0.approve(address(_liquidityRouter), type(uint256).max);
        _token1.approve(address(_liquidityRouter), type(uint256).max);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Views used by the invariant contract
    // ═════════════════════════════════════════════════════════════════════════

    function rangeTicks(uint256 i) public pure returns (int24 lo, int24 hi) {
        if (i == 0) return (TickMath.minUsableTick(60), TickMath.maxUsableTick(60));
        if (i == 1) return (-6000, 6000);
        return (-600, 600);
    }

    function totalGhostLiquidity() public view returns (uint256 total) {
        for (uint256 i = 0; i < RANGE_COUNT; i++) {
            total += ghostLiquidity[i];
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Setup helper (NOT a fuzz target)
    // ═════════════════════════════════════════════════════════════════════════

    /// @dev Full-range floor liquidity so swaps never run against an empty pool.
    function seedLiquidity() external {
        require(!seeded, "already seeded");
        seeded = true;

        (int24 lo, int24 hi) = rangeTicks(0);
        liquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: lo, tickUpper: hi, liquidityDelta: int256(uint256(SEED_LIQUIDITY)), salt: bytes32(0)
            }),
            ""
        );
        ghostLiquidity[0] += SEED_LIQUIDITY;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Time
    // ═════════════════════════════════════════════════════════════════════════

    function advanceTime(uint256 blocksAhead, uint256 secondsSeed) external {
        _advance(blocksAhead, secondsSeed);
    }

    function _advance(uint256 blocksAhead, uint256 secondsSeed) internal {
        uint256 b = bound(blocksAhead, 0, 30);
        if (b == 0) return; // same block -> exercises same-block sandwich logic
        uint256 s = bound(secondsSeed, b, b * 12);
        vm.roll(block.number + b);
        vm.warp(block.timestamp + s);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Swaps
    // ═════════════════════════════════════════════════════════════════════════

    function performSwap(bool zeroForOne, bool exactInput, uint256 amountSeed, uint256 blocksAhead, uint256 secondsSeed)
        external
    {
        _advance(blocksAhead, secondsSeed);

        (, int24 tickBefore,,) = manager.getSlot0(poolId);

        // Don't push an already-extreme pool further; that is a PoolManager
        // concern (PriceLimitAlreadyExceeded), not a hook bug.
        if (zeroForOne && tickBefore <= TickMath.MIN_TICK + 1000) {
            skippedSwaps++;
            return;
        }
        if (!zeroForOne && tickBefore >= TickMath.MAX_TICK - 1000) {
            skippedSwaps++;
            return;
        }

        uint256 amt = exactInput ? bound(amountSeed, 1e12, 1 ether) : bound(amountSeed, 1e12, 0.05 ether);

        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: exactInput ? -int256(amt) : int256(amt),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        uint256 gasStart = gasleft();
        try swapRouter.swap(key, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "") {
            _recordSwap(tickBefore, amt, gasStart - gasleft());
        } catch (bytes memory reason) {
            lastFailedTickBefore = tickBefore;
            lastFailedZeroForOne = zeroForOne;
            lastFailedAmountSpecified = params.amountSpecified;

            if (reason.length >= 4 && bytes4(reason) == WRAPPED_ERROR_SELECTOR) {
                unexpectedSwapReverts++;
                lastSwapRevertData = reason;
            } else {
                otherSwapReverts++;
                lastOtherSwapRevertData = reason;
            }
        }
    }

    function _recordSwap(int24 tickBefore, uint256 amt, uint256 gasUsed) internal {
        (, int24 postTick,,) = manager.getSlot0(poolId);

        swapCount++;
        lastTickDelta = postTick - tickBefore;
        lastPostSwapTick = postTick;
        lastSwapBlock = block.number;
        lastSwapTimestamp = block.timestamp;

        if (block.number != ghostVolumeBlock) {
            ghostVolumeBlock = block.number;
            ghostBlockVolume = amt;
            ghostSwapsInBlock = 1;
        } else {
            ghostBlockVolume += amt;
            ghostSwapsInBlock++;
        }

        lastSwapGasUsed = gasUsed;
        if (gasUsed > maxSwapGasUsed) maxSwapGasUsed = gasUsed;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Liquidity
    // ═════════════════════════════════════════════════════════════════════════

    function addLiquidity(uint256 rangeSeed, uint256 amountSeed) external {
        uint256 i = rangeSeed % RANGE_COUNT;
        uint128 delta = uint128(bound(amountSeed, 1e9, 1e18));
        (int24 lo, int24 hi) = rangeTicks(i);

        try liquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: lo, tickUpper: hi, liquidityDelta: int256(uint256(delta)), salt: bytes32(0)
            }),
            ""
        ) {
            ghostLiquidity[i] += delta;
        } catch (bytes memory reason) {
            if (_isRouterAssert(reason)) routerAssertSkips++;
            else unexpectedLiquidityReverts++;
        }
    }

    function removeLiquidity(uint256 rangeSeed, uint256 amountSeed) external {
        uint256 i = rangeSeed % RANGE_COUNT;
        uint128 have = ghostLiquidity[i];

        // keep the full-range seed as a floor so the pool never goes empty
        uint128 removable = i == 0 ? (have > SEED_LIQUIDITY ? have - SEED_LIQUIDITY : 0) : have;
        if (removable == 0) return;

        uint128 delta = uint128(bound(amountSeed, 1, removable));
        (int24 lo, int24 hi) = rangeTicks(i);

        try liquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: lo, tickUpper: hi, liquidityDelta: -int256(uint256(delta)), salt: bytes32(0)
            }),
            ""
        ) {
            ghostLiquidity[i] -= delta;
        } catch (bytes memory reason) {
            if (_isRouterAssert(reason)) routerAssertSkips++;
            else unexpectedLiquidityReverts++;
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Oracle
    // ═════════════════════════════════════════════════════════════════════════

    function growOracle(uint16 targetSeed) external {
        uint16 target = uint16(bound(uint256(targetSeed), 1, 2000));

        (, uint16 cardBefore, uint16 nextBefore) = hook.getOracleState(key);

        try hook.increaseObservationCardinality(key, target) {
            (, uint16 cardAfter, uint16 nextAfter) = hook.getOracleState(key);

            if (cardAfter < cardBefore || nextAfter < nextBefore) {
                cardinalityDecreased = true;
            } else if (uint256(nextAfter) - uint256(nextBefore) > uint256(hook.maxCardinalityPerCall())) {
                growthCapViolated = true;
            }
        } catch {
            // permissionless + initialized pool => should not revert
            adminUnexpectedRevert = true;
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Owner actions: timelocked thresholds
    // ═════════════════════════════════════════════════════════════════════════

    function proposeThresholds(uint256 highSeed, uint256 midSeed, uint256 volSeed, uint256 sandSeed) external {
        uint256 mid = bound(midSeed, 1, 1000);
        uint256 high = bound(highSeed, mid + 1, 5000);
        uint256 vol = bound(volSeed, 1e15, 10 ether);
        uint256 sandwich = bound(sandSeed, 1, 500);

        vm.prank(owner);
        try hook.proposeTickThresholds(high, mid, vol, sandwich) {
            ghostHasProposal = true;
            ghostEta = block.timestamp + hook.THRESHOLD_TIMELOCK_DELAY();
        } catch {
            adminUnexpectedRevert = true;
        }
    }

    function executeThresholds(uint256 timeSeed) external {
        if (timeSeed % 3 == 0) {
            vm.warp(block.timestamp + bound(timeSeed, 1, 3 days));
        }

        vm.prank(owner);
        try hook.executeTickThresholds() {
            if (!ghostHasProposal || block.timestamp < ghostEta) timelockViolated = true;
            ghostHasProposal = false;
        } catch {
            if (ghostHasProposal && block.timestamp >= ghostEta) executeRevertedWhenReady = true;
        }
    }

    function cancelThresholds() external {
        vm.prank(owner);
        try hook.cancelTickThresholdsProposal() {
            if (!ghostHasProposal) adminUnexpectedRevert = true; // succeeded with nothing pending
            ghostHasProposal = false;
        } catch {
            if (ghostHasProposal) adminUnexpectedRevert = true;
        }
    }

    function ownerSetMaxCardinality(uint256 seed) external {
        uint16 v = uint16(bound(seed, 1, hook.HARD_MAX_CARDINALITY_PER_CALL()));
        vm.prank(owner);
        try hook.setMaxCardinalityPerCall(v) {}
        catch {
            adminUnexpectedRevert = true;
        }
    }

    function ownerSetInitialCardinality(uint256 seed) external {
        uint16 v = uint16(bound(seed, 1, hook.maxCardinalityPerCall()));
        vm.prank(owner);
        try hook.setInitialCardinality(v) {}
        catch {
            adminUnexpectedRevert = true;
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Access control: every owner-only function must reject strangers
    // ═════════════════════════════════════════════════════════════════════════

    function unauthorizedAdminCall(address caller, uint256 which) external {
        if (caller == owner || caller == address(0)) return;

        uint256 w = which % 6;
        vm.startPrank(caller);

        if (w == 0) {
            try hook.proposeTickThresholds(2, 1, 1, 1) {
                accessControlBroken = true;
            } catch {}
        } else if (w == 1) {
            try hook.executeTickThresholds() {
                accessControlBroken = true;
            } catch {}
        } else if (w == 2) {
            try hook.cancelTickThresholdsProposal() {
                accessControlBroken = true;
            } catch {}
        } else if (w == 3) {
            try hook.setInitialCardinality(10) {
                accessControlBroken = true;
            } catch {}
        } else if (w == 4) {
            try hook.setMaxCardinalityPerCall(10) {
                accessControlBroken = true;
            } catch {}
        } else {
            try hook.transferOwnership(caller) {
                accessControlBroken = true;
            } catch {}
        }

        vm.stopPrank();
    }
}
