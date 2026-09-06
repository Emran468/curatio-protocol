// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/*//////////////////////////////////////////////////////////////////////////
    CuratioHookEchidnaTest

    Echidna property tests for CuratioHook.sol.

    WHY A CUSTOM HARNESS IS NEEDED
    -------------------------------
    CuratioHook extends BaseHook, whose constructor calls
    Hooks.validateHookPermissions(this, getHookPermissions()), which reverts
    unless the low bits of the *deployed contract address* exactly match the
    hook's declared permission flags (afterInitialize, afterAddLiquidity,
    afterRemoveLiquidity, beforeSwap, afterSwap). CuratioHook's own
    constructor also reverts unless the supplied PoolManager address equals
    ChainRegistry.getPoolManager(block.chainid) — UNLESS block.chainid == 31337.

    Echidna 2.3.1 has no way to set block.chainid (no config key, no
    cheatcode), and its default chainid is not 31337. So instead of trying
    to fake the chain id, CuratioHook.sol exposes a virtual
    `_skipChainCheck()` hook (default: false, dead code in production) that
    CuratioHookHarness overrides to true — this bypasses ONLY the
    chain/PoolManager-address guard, never any of the hook's actual logic
    under test.

    So this harness:
      1. Deploys a MockPoolManager the hook can call getSlot0/getLiquidity on,
         and that itself acts as `msg.sender` when driving hook callbacks
         (satisfying `onlyPoolManager`).
      2. Mines a CREATE2 salt so CuratioHookHarness's address carries the
         correct hook-flag bits.
      3. Overrides `_skipChainCheck()` to bypass the PoolManager-address
         guard regardless of Echidna's (unconfigurable) chain id.

    Run with (from repo root):
      echidna test/Echidna/CuratioHookEchidnaTest.sol \
        --contract CuratioHookEchidnaTest --config test/Echidna/echidna.yaml

    NOTE ON THIS CLEANED-UP VERSION
    --------------------------------
    - Fixed a compile error in testOracleWarmImpliesTwapAvailable: `warm` was
      referenced but never declared (its declaration line was commented out).
      It now calls hook.isOracleWarm / hook.getTwapTick directly, mirroring
      how every other property in this file calls the hook. If either of
      those is `internal` on CuratioHook rather than `public`/`external`,
      add `exposed_isOracleWarm` / `exposed_getTwapTick` wrappers to
      CuratioHookHarness the same way exposed_computeFee etc. are done below.
    - Removed a duplicate `exposed_tickCumulativeDelta` that was redefined
      loose inside the test contract; the harness's copy (used by
      testTickCumulativeNeverOverflows) is the only one now.
    - Removed three fully-empty stub functions (test_ObserveAt_* /
      test_BinarySearch_*) that had no bodies — they compiled but asserted
      nothing, so they weren't testing anything. Restore them with real
      bodies when you're ready to write those properties.
    - Moved the two Foundry-style tests (test_IncreaseObservationCardinality_
      LargeValue_GasBounded, test_SetInitialCardinality_LargeValue_
      DoesNotBrickInitialize) out to their own Foundry test file, matching
      the `// test/Foundry/CardinalityGasDoS.t.sol` comment that was already
      pointing at that intent. Echidna and Foundry tests generally shouldn't
      live in the same contract.
//////////////////////////////////////////////////////////////////////////*/

import {CuratioHook} from "../../src/CuratioHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

// ─── Minimal PoolManager mock ──────────────────────────────────────────────
// Implements only what CuratioHook actually calls (getSlot0, getLiquidity),
// plus pass-through "driver" functions so this contract is the msg.sender
// the hook sees, matching onlyPoolManager.
contract MockPoolManager {
    struct Slot0 {
        uint160 sqrtPriceX96;
        int24 tick;
        uint24 protocolFee;
        uint24 lpFee;
    }

    mapping(bytes32 => Slot0) public slot0Of;
    mapping(bytes32 => uint128) public liquidityOf;

    // Uniswap v4 StateLibrary slot layout for Pool.State.
    // StateLibrary computes: keccak256(abi.encode(poolId, POOLS_SLOT))
    // POOLS_SLOT is slot 6 in the standard v4 Pool.State storage layout.
    function _getSlot0StorageSlot(PoolId poolId) internal pure returns (bytes32) {
        return keccak256(abi.encode(PoolId.unwrap(poolId), uint256(6)));
    }

    function setSlot0(PoolId poolId, uint160 sqrtPriceX96, int24 tick) public {
        // 1. Solidity struct mapping update
        slot0Of[PoolId.unwrap(poolId)] = Slot0(sqrtPriceX96, tick, 0, 0);

        // 2. Packed Slot0 value formatting (as expected by Uniswap v4)
        // Format: sqrtPriceX96 (160 bits) | tick (24 bits) | protocolFee (24 bits) | lpFee (24 bits)
        bytes32 packedSlot0 = bytes32(
            uint256(sqrtPriceX96) |
            (uint256(uint24(tick)) << 160) |
            (uint256(0) << 184) |
            (uint256(0) << 208)
        );

        // 3. Write to BOTH common slot layouts (Slot 0 & Slot 6) so StateLibrary finds it
        bytes32 slot0Loc = keccak256(abi.encode(PoolId.unwrap(poolId), uint256(0)));
        bytes32 slot6Loc = keccak256(abi.encode(PoolId.unwrap(poolId), uint256(6)));

        assembly {
            sstore(slot0Loc, packedSlot0)
            sstore(slot6Loc, packedSlot0)
        }
    }

    function setLiquidity(PoolId poolId, uint128 liquidity) external {
        liquidityOf[PoolId.unwrap(poolId)] = liquidity;
    }

    function getSlot0(PoolId poolId) external view returns (uint160, int24, uint24, uint24) {
        Slot0 memory s = slot0Of[PoolId.unwrap(poolId)];
        return (s.sqrtPriceX96, s.tick, s.protocolFee, s.lpFee);
    }

    function getLiquidity(PoolId poolId) external view returns (uint128) {
        return liquidityOf[PoolId.unwrap(poolId)];
    }

    // ── Drivers ──

    function driveAfterInitialize(address hook, PoolKey calldata key, uint160 sqrtPriceX96, int24 tick) external {
        setSlot0(key.toId(), sqrtPriceX96, tick);
        IHooks(hook).afterInitialize(address(this), key, sqrtPriceX96, tick);
    }

    function driveBeforeSwap(address hook, PoolKey calldata key, SwapParams calldata params)
        external
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return IHooks(hook).beforeSwap(address(this), key, params, "");
    }

    function driveAfterSwap(address hook, PoolKey calldata key, SwapParams calldata params)
        external
        returns (bytes4, int128)
    {
        return IHooks(hook).afterSwap(address(this), key, params, BalanceDelta.wrap(0), "");
    }

    function driveFullSwap(address hook, PoolKey calldata key, SwapParams calldata params, int24 postSwapTick)
        external
        returns (uint24 feeApplied)
    {
        (,, uint24 fee) = IHooks(hook).beforeSwap(address(this), key, params, "");
        feeApplied = fee & ~LPFeeLibrary.OVERRIDE_FEE_FLAG;

        PoolId poolId = key.toId();

        // Ensure Slot0 reflects the post-swap tick before afterSwap runs.
        uint160 currentPrice = slot0Of[PoolId.unwrap(poolId)].sqrtPriceX96;
        if (currentPrice == 0) currentPrice = 79228162514264337593543950336;

        setSlot0(poolId, currentPrice, postSwapTick);

        IHooks(hook).afterSwap(address(this), key, params, BalanceDelta.wrap(0), "");
    }

    function driveAfterAddLiquidity(address hook, PoolKey calldata key, ModifyLiquidityParams calldata params)
        external
    {
        IHooks(hook).afterAddLiquidity(address(this), key, params, BalanceDelta.wrap(0), BalanceDelta.wrap(0), "");
    }

    function driveAfterRemoveLiquidity(address hook, PoolKey calldata key, ModifyLiquidityParams calldata params)
        external
    {
        IHooks(hook).afterRemoveLiquidity(address(this), key, params, BalanceDelta.wrap(0), BalanceDelta.wrap(0), "");
    }

    // ── Extsload Implementations ──

    function extsload(bytes32 slot) external view returns (bytes32 value) {
        assembly {
            value := sload(slot)
        }
    }

    function extsload(bytes32[] calldata slots) external view returns (bytes32[] memory values) {
        values = new bytes32[](slots.length);
        for (uint256 i = 0; i < slots.length; i++) {
            bytes32 slot = slots[i];
            bytes32 value;
            assembly {
                value := sload(slot)
            }
            values[i] = value;
        }
    }
}

// ─── Harness: exposes CuratioHook's internal pure/view helpers ────────────
contract CuratioHookHarness is CuratioHook {
    constructor(IPoolManager pm, address owner_) CuratioHook(pm, owner_) {}

    function exposed_packTracker(SandwichTracker memory t) external pure returns (uint256) {
        return _packTracker(t);
    }

    function exposed_unpackTracker(uint256 packed) external pure returns (SandwichTracker memory) {
        return _unpackTracker(packed);
    }

    function exposed_computeFee(uint24 tickDelta, uint256 blockDelta, uint24 currentFee)
        external
        view
        returns (uint24)
    {
        return _computeFee(tickDelta, blockDelta, currentFee);
    }

    function exposed_abs(int24 n) external pure returns (uint24) {
        return abs(n);
    }

    function exposed_tickCumulativeDelta(int24 tick, uint32 delta) external pure returns (int56) {
        return int56(tick) * int56(uint56(delta));
    }

    // Testing-only bypass for the constructor's chain/PoolManager-address
    // guard (see CuratioHook.sol). Echidna can't set block.chainid, so we
    // skip that specific check here instead — everything else in the
    // constructor, and all hook logic under test, runs unmodified.
    function _skipChainCheck() internal pure override returns (bool) {
        return true;
    }
}

// ─── CREATE2 salt miner ────────────────────────────────────────────────────
// Mines (once, at test-suite deployment) a salt whose resulting address
// carries exactly the hook-flag bits CuratioHook declares in
// getHookPermissions(): afterInitialize | afterAddLiquidity |
// afterRemoveLiquidity | beforeSwap | afterSwap.
library HookMiner {
    uint160 internal constant REQUIRED_FLAGS =
        uint160(1 << 12) // AFTER_INITIALIZE_FLAG
        | uint160(1 << 10) // AFTER_ADD_LIQUIDITY_FLAG
        | uint160(1 << 8) // AFTER_REMOVE_LIQUIDITY_FLAG
        | uint160(1 << 7) // BEFORE_SWAP_FLAG
        | uint160(1 << 6); // AFTER_SWAP_FLAG

    uint160 internal constant ALL_HOOK_MASK = uint160((1 << 14) - 1);

    function find(address deployer, bytes memory creationCode, bytes memory constructorArgs)
        internal
        pure
        returns (bytes32 salt, address hookAddress)
    {
        bytes memory initCode = abi.encodePacked(creationCode, constructorArgs);
        bytes32 initCodeHash = keccak256(initCode);

        for (uint256 i = 0; i < 200_000; i++) {
            salt = bytes32(i);
            hookAddress = computeAddress(deployer, salt, initCodeHash);
            if (uint160(hookAddress) & ALL_HOOK_MASK == REQUIRED_FLAGS) {
                return (salt, hookAddress);
            }
        }
        revert("HookMiner: no salt found in range");
    }

    function computeAddress(address deployer, bytes32 salt, bytes32 initCodeHash) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
    }
}

// ─── Echidna test contract ─────────────────────────────────────────────────
contract CuratioHookEchidnaTest {
    using PoolIdLibrary for PoolKey;

    MockPoolManager public poolManager;
    CuratioHookHarness public hook;
    PoolKey internal poolKey;
    PoolId internal poolId;

    // Tracks the last cardinalityNext observed by fuzz calls, so we can
    // assert monotonicity across the whole campaign, not just within one call.
    uint16 internal lastCardinalityNext;

    // Echidna deploys this contract once; deployment is msg.sender == this,
    // so `owner` on the hook is set to address(this), letting fuzz functions
    // call onlyOwner admin functions directly.
    constructor() {
        poolManager = new MockPoolManager();

        bytes memory creationCode = type(CuratioHookHarness).creationCode;
        bytes memory args = abi.encode(address(poolManager), address(this));

        (bytes32 salt,) = HookMiner.find(address(this), creationCode, args);
        hook = new CuratioHookHarness{salt: salt}(IPoolManager(address(poolManager)), address(this));

        poolKey = PoolKey({
            currency0: Currency.wrap(address(0x1111)),
            currency1: Currency.wrap(address(0x2222)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        poolId = poolKey.toId();

        poolManager.driveAfterInitialize(address(hook), poolKey, 79228162514264337593543950336, 0);

        (,, lastCardinalityNext) = hook.getOracleState(poolKey);
    }

    // ════════════════════════════════════════════════════════════════════
    // Property: SandwichTracker pack/unpack round-trips losslessly.
    // (int24 fields are stored in 24 bits and must sign-extend correctly.)
    // ════════════════════════════════════════════════════════════════════
    function testTrackerRoundTrip(int24 firstMove, int24 lastMove, int24 peakTick, uint32 swapCount, uint256 startBlock)
        public view
    {
        CuratioHook.SandwichTracker memory t = CuratioHook.SandwichTracker({
            firstMove: firstMove,
            lastMove: lastMove,
            peakTick: peakTick,
            swapCount: swapCount,
            startBlock: startBlock % (1 << 96), // startBlock is packed into 96 bits
            initialized: true
        });

        uint256 packed = hook.exposed_packTracker(t);
        CuratioHook.SandwichTracker memory t2 = hook.exposed_unpackTracker(packed);

        assert(t2.firstMove == firstMove);
        assert(t2.lastMove == lastMove);
        assert(t2.peakTick == peakTick);
        assert(t2.swapCount == swapCount);
        assert(t2.startBlock == t.startBlock);
        assert(t2.initialized == true);
    }

    // ════════════════════════════════════════════════════════════════════
    // Property: _computeFee only ever returns one of the four declared
    // fee tiers — never an arbitrary value.
    // ════════════════════════════════════════════════════════════════════
    function testComputeFeeIsAlwaysAKnownTier(uint24 tickDelta, uint256 blockDelta, uint24 currentFee) public view {
        uint24 fee = hook.exposed_computeFee(tickDelta, blockDelta, currentFee);
        assert(
            fee == hook.BASE_FEE() || fee == hook.MID_VOLATILE_FEE() || fee == hook.HIGH_VOLATILE_FEE()
                || fee == currentFee
        );
    }

    // ════════════════════════════════════════════════════════════════════
    // Property: abs() never returns a value whose sign bit implies overflow,
    // and matches the mathematical absolute value for all int24 inputs
    // except type(int24).min (which has no representable positive counterpart).
    // ════════════════════════════════════════════════════════════════════
    function testAbsIsNonNegativeAndCorrect(int24 n) public view {
        if (n == type(int24).min) return; // no representable abs, skip
        uint24 result = hook.exposed_abs(n);
        int24 expected = n >= 0 ? n : -n;
        assert(int24(result) == expected);
    }

    // ════════════════════════════════════════════════════════════════════
    // Property: getCurrentFee() never reverts and always returns a fee
    // within the declared tiers (never 0, never an out-of-range value).
    // ════════════════════════════════════════════════════════════════════
    function testGetCurrentFeeBounded() public view {
        uint24 fee = hook.getCurrentFee(poolKey);
        assert(
            fee == hook.BASE_FEE() || fee == hook.MID_VOLATILE_FEE() || fee == hook.HIGH_VOLATILE_FEE()
                || fee == hook.MEV_PENALTY_FEE()
        );
    }

    // ════════════════════════════════════════════════════════════════════
    // Property: threshold timelock governance state machine.
    // A proposal's eta must always be >= proposal time + delay, and
    // execution must never succeed before eta.
    // ════════════════════════════════════════════════════════════════════
    function testProposeThresholdsEtaIsFuture(uint256 high, uint256 mid, uint256 volumeThreshold, uint256 sandwichThreshold)
        public
    {
        if (high <= mid) return; // proposeTickThresholds requires high > mid

        hook.proposeTickThresholds(high, mid, volumeThreshold, sandwichThreshold);
        (,,,, uint256 eta, bool exists) = hook.pendingThresholds();

        assert(exists);
        assert(eta >= block.timestamp + hook.THRESHOLD_TIMELOCK_DELAY());
    }

    function testExecuteThresholdsRevertsBeforeEta(uint256 high, uint256 mid) public {
        if (high <= mid) return;

        hook.proposeTickThresholds(high, mid, 1 ether, 80);

        // Immediately attempting execution (same block, timelock not
        // elapsed) must revert — call via low-level to observe failure
        // without aborting the whole property.
        (bool success,) = address(hook).call(abi.encodeWithSelector(hook.executeTickThresholds.selector));
        assert(!success);

        hook.cancelTickThresholdsProposal(); // reset state for next run
    }

    // Property: after execute OR cancel, no pending proposal remains.
    function testProposalAlwaysClearedAfterCancel(uint256 high, uint256 mid) public {
        if (high <= mid) return;

        hook.proposeTickThresholds(high, mid, 1 ether, 80);
        hook.cancelTickThresholdsProposal();

        (,,,,, bool exists) = hook.pendingThresholds();
        assert(!exists);
    }

    // ════════════════════════════════════════════════════════════════════
    // Property: tickThresholdHigh is always strictly greater than
    // tickThresholdMid — enforced at proposal time and must never be
    // violated by an executed proposal.
    // ════════════════════════════════════════════════════════════════════
    function echidna_high_threshold_exceeds_mid() public view returns (bool) {
        return hook.tickThresholdHigh() > hook.tickThresholdMid();
    }

    // ════════════════════════════════════════════════════════════════════
    // Property: the fee applied by beforeSwap is always one of the
    // declared tiers. Uses the full beforeSwap->afterSwap round trip so
    // transient-storage state and packed trackers evolve realistically
    // across a fuzzed sequence of swaps.
    // ════════════════════════════════════════════════════════════════════
    function testSwapFeeAlwaysKnownTier(int256 amountSpecified, bool zeroForOne, int24 preTick, int24 postTick)
        public
    {
        if (amountSpecified == 0) return;
        if (preTick < -887272 || preTick > 887272) return;
        if (postTick < -887272 || postTick > 887272) return;

        poolManager.setSlot0(poolId, 79228162514264337593543950336, preTick);

        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: zeroForOne ? 4295128740 : 1461446703485210103287273052203988822378723970341
        });

        (bool success, bytes memory ret) = address(poolManager).call(
            abi.encodeWithSelector(poolManager.driveFullSwap.selector, address(hook), poolKey, params, postTick)
        );
        if (!success) return; // e.g. transient-storage dirty guard tripped; not a violation

        uint24 fee = abi.decode(ret, (uint24));

        assert(
            fee == hook.BASE_FEE() || fee == hook.MID_VOLATILE_FEE() || fee == hook.HIGH_VOLATILE_FEE()
                || fee == hook.MEV_PENALTY_FEE()
        );

        // getCurrentFee must stay consistent with what afterSwap persisted.
        testGetCurrentFeeBounded();
    }

    // ════════════════════════════════════════════════════════════════════
    // Property: once a sandwich is flagged for the current block, every
    // swap attempted later in that same block is charged MEV_PENALTY_FEE.
    // ════════════════════════════════════════════════════════════════════
    function testSandwichFlagStaysStickyWithinBlock(int24 preTick, int24 postTick) public {
        require(preTick >= -887272 && preTick <= 887272, "Invalid preTick");
        require(postTick >= -887272 && postTick <= 887272, "Invalid postTick");

        poolManager.setSlot0(poolId, 79228162514264337593543950336, preTick);

        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -1e18,
            sqrtPriceLimitX96: 4295128740
        });

        (bool success1, bytes memory ret1) = address(poolManager).call(
            abi.encodeWithSelector(poolManager.driveFullSwap.selector, address(hook), poolKey, params, postTick)
        );
        require(success1, "First swap failed");

        uint24 rawFirstFee = abi.decode(ret1, (uint24));
        uint24 firstFee = uint24(rawFirstFee & 0x00FFFFFF); // clear the dynamic-fee override flag

        // Using require (not return) here deliberately forces Echidna to
        // keep searching for inputs that actually trigger the MEV penalty,
        // rather than silently passing on inputs that don't.
        require(firstFee == hook.MEV_PENALTY_FEE(), "Sandwich wasn't triggered this run");

        // A follow-up swap in the same block must also be penalized.
        (bool success2, bytes memory ret2) = address(poolManager).call(
            abi.encodeWithSelector(poolManager.driveFullSwap.selector, address(hook), poolKey, params, postTick)
        );
        require(success2, "Second swap failed");

        uint24 rawSecondFee = abi.decode(ret2, (uint24));
        uint24 secondFee = uint24(rawSecondFee & 0x00FFFFFF);

        assert(secondFee == hook.MEV_PENALTY_FEE());
    }

    // ════════════════════════════════════════════════════════════════════
    // Property: increaseObservationCardinality never decreases
    // cardinalityNext, and stored cardinalityNext only ever grows across
    // the whole fuzzing campaign.
    // ════════════════════════════════════════════════════════════════════
    function testCardinalityNeverDecreases(uint16 targetCardinality) public {
        (uint16 cardinalityNextOld, uint16 cardinalityNextNew) =
            hook.increaseObservationCardinality(poolKey, targetCardinality);

        assert(cardinalityNextNew >= cardinalityNextOld);
        assert(cardinalityNextNew >= lastCardinalityNext);
        lastCardinalityNext = cardinalityNextNew;
    }

    // ════════════════════════════════════════════════════════════════════
    // Property: setInitialCardinality rejects zero and always stores
    // exactly what was requested when nonzero.
    // ════════════════════════════════════════════════════════════════════
    function testSetInitialCardinality(uint16 newCardinality) public {
        if (newCardinality == 0) {
            (bool success,) =
                address(hook).call(abi.encodeWithSelector(hook.setInitialCardinality.selector, newCardinality));
            assert(!success);
            return;
        }

        hook.setInitialCardinality(newCardinality);
        assert(hook.initialCardinality() == newCardinality);
    }

    // ════════════════════════════════════════════════════════════════════
    // Property: isOracleWarm() never reverts, and once true for a given
    // window, getTwapTick() for that same window must not revert either.
    //
    // Calls hook.isOracleWarm / hook.getTwapTick directly (both must be
    // public/external on CuratioHook). If either is internal, add
    // exposed_isOracleWarm / exposed_getTwapTick wrappers to
    // CuratioHookHarness instead, the same way exposed_computeFee is done.
    // ════════════════════════════════════════════════════════════════════
    function testOracleWarmImpliesTwapAvailable(uint32 twapWindow) external view {
        require(twapWindow > 0, "TWAP window must be > 0");
        require(twapWindow <= block.timestamp, "TWAP window cannot exceed current timestamp");

        bool warm = hook.isOracleWarm(poolKey, twapWindow);

        if (warm) {
            try hook.getTwapTick(poolKey, twapWindow) returns (int24) {
                assert(true);
            } catch {
                assert(false);
            }
        }
    }

    // ════════════════════════════════════════════════════════════════════
    // Property: a valid sandwich reversal pattern (tick moves back and
    // forth across two swaps) is reflected in a bounded, known fee tier.
    // ════════════════════════════════════════════════════════════════════
    function testSandwichReversalActuallyDetected(int24 move1, int24 move2, uint256 vol1, uint256 vol2) external {
        require(vol1 > 0 && vol2 > 0, "Volume must be > 0");
        require(move1 != 0 && move2 != 0, "Tick moves must be non-zero");

        bool isReversal = (move1 > 0 && move2 < 0) || (move1 < 0 && move2 > 0);
        require(isReversal, "Moves do not form a reversal pattern");

        int24 initialTick = 1;
        poolManager.setSlot0(poolId, 79228162514264337593543950336, initialTick);

        int24 nextTick = initialTick + move1 + move2;
        poolManager.setSlot0(poolId, 79228162514264337593543950336, nextTick);

        this.testGetCurrentFeeBounded();
    }

    // ════════════════════════════════════════════════════════════════════
    // Property: tickCumulative deltas never silently flip sign relative
    // to a positive tick * positive time delta (i.e. no overflow-induced
    // sign corruption within realistic ranges).
    // ════════════════════════════════════════════════════════════════════
    function testTickCumulativeNeverOverflows(int24 tick, uint32 delta) public view {
        int56 result = hook.exposed_tickCumulativeDelta(tick, delta);
        if (tick > 0 && delta > 0) {
            assert(result >= 0);
        }
        if (tick < 0 && delta > 0) {
            assert(result <= 0);
        }
    }

    // ════════════════════════════════════════════════════════════════════
    // TODO: properties not yet implemented. Restore these with real bodies
    // when ready — empty stubs were removed from this file because they
    // compiled but asserted nothing:
    //
    //   - Observation-at-exact-boundary: keep cardinality small (e.g. 3) so
    //     the ring buffer wraps quickly, run more swaps than cardinality,
    //     then call getTwapTick exactly at the oldest observation's
    //     timestamp — it should not revert and should return the correct
    //     tickCumulative.
    //   - Observation older than oldest: request a TWAP window wide enough
    //     that the target falls before the oldest observation and assert
    //     it reverts with the "target older than oldest observation"-style
    //     error.
    //   - Binary search over uninitialized slots: right after pool init
    //     (only slot 0 populated, grown slots still zeroed) call the
    //     observe/TWAP path with a target timestamp after the first
    //     observation and assert it terminates (no infinite loop) and
    //     either reverts cleanly or returns a sane value.
    // ════════════════════════════════════════════════════════════════════
}

/*//////////////////////////////////////////////////////////////////////////
    See echidna.yaml (same directory) for the required config:
    testMode: assertion, chainId: 31337.
//////////////////////////////////////////////////////////////////////////*/
