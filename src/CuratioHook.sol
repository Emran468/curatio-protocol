// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// ═══════════════════════════════════════════════════════════════════════════════
// Hybrid Volatility Hook v3 — Multi-Chain Edition (Test Suite Compatible)
// + TWAP Oracle Module (v3-style tickCumulative ring buffer)
// ═══════════════════════════════════════════════════════════════════════════════

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

// ─── Ownable ──────────────────────────────────────────────────────────────────
abstract contract Ownable {
    address public owner;
    error NotOwner();
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    constructor() {
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Zero address");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
}

// ─── Chain Registry ───────────────────────────────────────────────────────────
library ChainRegistry {
    uint256 constant UNICHAIN = 130;
    uint256 constant ETHEREUM = 1;
    uint256 constant BASE = 8453;
    uint256 constant OPTIMISM = 10;
    uint256 constant ARBITRUM = 42161;
    uint256 constant SEPOLIA = 11155111;
    uint256 constant UNICHAIN_SEPOLIA = 1301;
    uint256 constant BASE_SEPOLIA = 84532;

    function getPoolManager(uint256 chainId) internal pure returns (address) {
        if (chainId == UNICHAIN) return 0x1F98400000000000000000000000000000000004;
        if (chainId == ETHEREUM) return 0x000000000004444c5dc75cB358380D2e3dE08A90;
        if (chainId == BASE) return 0x498581fF718922c3f8e6A244956aF099B2652b2b;
        if (chainId == OPTIMISM) return 0x9a13F98Cb987694C9F086b1F5eB990EeA8264Ec3;
        if (chainId == ARBITRUM) return 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32;
        if (chainId == SEPOLIA) return 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
        if (chainId == UNICHAIN_SEPOLIA) return 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;
        if (chainId == BASE_SEPOLIA) return 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;
        revert("ChainRegistry: unsupported chain");
    }

    function getChainName(uint256 chainId) internal pure returns (string memory) {
        if (chainId == UNICHAIN) return "Unichain Mainnet";
        if (chainId == ETHEREUM) return "Ethereum Mainnet";
        if (chainId == BASE) return "Base Mainnet";
        if (chainId == OPTIMISM) return "Optimism Mainnet";
        if (chainId == ARBITRUM) return "Arbitrum One";
        if (chainId == SEPOLIA) return "Sepolia Testnet";
        if (chainId == UNICHAIN_SEPOLIA) return "Unichain Sepolia";
        if (chainId == BASE_SEPOLIA) return "Base Sepolia";
        return "Unknown Chain";
    }

    function getBlockDecayWindow(uint256 chainId) internal pure returns (uint64) {
        if (chainId == UNICHAIN) return 300;
        if (chainId == UNICHAIN_SEPOLIA) return 300;
        if (chainId == BASE) return 150;
        if (chainId == BASE_SEPOLIA) return 150;
        if (chainId == OPTIMISM) return 150;
        if (chainId == ARBITRUM) return 1000;
        return 25;
    }
}

// ─── TWAP Oracle Library ──────────────────────────────────────────────────────
// v3-style tickCumulative ring buffer. Kept as an internal library so the main
// contract stays readable; all storage lives in CuratioHook itself (structs
// are value types passed by storage pointer).
library TwapOracle {
    struct Observation {
        uint32 blockTimestamp;
        int56 tickCumulative;
        bool initialized;
    }

    struct State {
        uint16 index;
        uint16 cardinality;
        uint16 cardinalityNext;
    }

    /// @dev Called once, at pool init. Seeds slot 0.
    function initialize(mapping(uint16 => Observation) storage self, State storage state, uint32 time) internal {
        self[0] = Observation({blockTimestamp: time, tickCumulative: 0, initialized: true});
        state.index = 0;
        state.cardinality = 1;
        state.cardinalityNext = 1;
    }

    /// @dev Called on every swap (via afterSwap). No-op if oracle not grown
    ///      past cardinality 0, and no-op if called twice in the same block.
    function write(mapping(uint16 => Observation) storage self, State storage state, uint32 time, int24 tick) internal {
        if (state.cardinality == 0) return;

        Observation memory last = self[state.index];
        if (last.blockTimestamp == time) return; // already recorded this block

        uint32 delta = time - last.blockTimestamp;
        int56 tickCumulative = last.tickCumulative + int56(tick) * int56(uint56(delta));

        uint16 indexUpdated = uint16((uint256(state.index) + 1) % state.cardinality);
        self[indexUpdated] = Observation({blockTimestamp: time, tickCumulative: tickCumulative, initialized: true});
        state.index = indexUpdated;
    }

    /// @dev Grows the ring buffer capacity. Anyone can call to pre-warm slots
    ///      (gas-expensive SSTOREs paid up front instead of during swaps).
    function grow(mapping(uint16 => Observation) storage self, State storage state, uint16 newCardinality) internal {
        uint16 current = state.cardinalityNext;
        if (newCardinality <= current) return;

        for (uint16 i = current; i < newCardinality; i++) {
            self[i].blockTimestamp = 1; // touch slot to make later SSTORE cheaper
        }
        state.cardinalityNext = newCardinality;
        // Note: state.cardinality (the ACTIVE size used by write()) only grows
        // once write() observes cardinalityNext > cardinality at the wraparound
        // point. For simplicity/predictability in this hook, we bump both
        // together — see bumpCardinality() below, called from admin function.
    }

    /// @dev Finds the two observations surrounding `target` and returns the
    ///      tickCumulative at exactly `target` via linear interpolation.
    function observeAt(
        mapping(uint16 => Observation) storage self,
        State storage state,
        uint32 target,
        int24 currentTick
    ) internal view returns (int56 tickCumulative) {
        Observation memory latest = self[state.index];

        if (latest.blockTimestamp == target) {
            return latest.tickCumulative;
        }

        if (latest.blockTimestamp < target) {
            // Extrapolate forward to `target` using the current (post-swap) tick.
            uint32 delta = target - latest.blockTimestamp;
            return latest.tickCumulative + int56(currentTick) * int56(uint56(delta));
        }

        // target is in the past relative to the latest observation — binary search.
        (Observation memory before, Observation memory afterObs) = binarySearch(self, state, target);

        if (before.blockTimestamp == target) {
            return before.tickCumulative;
        }
        if (afterObs.blockTimestamp == target) {
            return afterObs.tickCumulative;
        }

        uint32 timeDelta = afterObs.blockTimestamp - before.blockTimestamp;
        uint32 targetDelta = target - before.blockTimestamp;
        int56 cumDelta = afterObs.tickCumulative - before.tickCumulative;

        tickCumulative = before.tickCumulative + (cumDelta * int56(uint56(targetDelta))) / int56(uint56(timeDelta));
    }

    /// @dev Binary search over the ring buffer for the observations bracketing `target`.
    ///      Reverts if `target` is older than the oldest stored observation.
    function binarySearch(mapping(uint16 => Observation) storage self, State storage state, uint32 target)
        internal
        view
        returns (Observation memory before, Observation memory afterObs)
    {
        uint16 oldestIndex = uint16((uint256(state.index) + 1) % state.cardinality);
        Observation memory oldest = self[oldestIndex];
        if (!oldest.initialized) {
            oldest = self[0];
            oldestIndex = 0;
        }
        require(target >= oldest.blockTimestamp, "TwapOracle: target older than oldest observation");

        uint256 l = 0;
        uint256 r = state.cardinality - 1;
        while (l <= r) {
            uint256 mid = (l + r) / 2;
            uint16 idx = uint16((uint256(oldestIndex) + mid) % state.cardinality);
            Observation memory obs = self[idx];

            if (!obs.initialized) {
                // Uninitialized slot — treat as "too far forward", search left half.
                if (mid == 0) break;
                r = mid - 1;
                continue;
            }

            if (obs.blockTimestamp <= target) {
                before = obs;
                if (mid + 1 > r) break;
                l = mid + 1;
            } else {
                afterObs = obs;
                if (mid == 0) break;
                r = mid - 1;
            }
        }

        require(before.initialized && afterObs.initialized, "TwapOracle: insufficient observation history");
    }
}

// ─── Main Hook ────────────────────────────────────────────────────────────────
contract CuratioHook is BaseHook, Ownable {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TwapOracle for mapping(uint16 => TwapOracle.Observation);

    // ── Structs ───────────────────────────────────────────────────────────────

    struct PackedPoolState {
        int24 lastTick;
        uint24 fee;
        uint64 lastBlock;
        uint64 lastTimestamp;
        bool initialized;
    }

    struct SandwichTracker {
        int24 firstMove;
        int24 lastMove;
        int24 peakTick;
        uint32 swapCount;
        uint256 startBlock;
        bool initialized;
    }

    struct PositionInfo {
        uint128 liquidity;
    }

    // ── Chain Info ────────────────────────────────────────────────────────────
    uint256 public immutable deployedChainId;
    uint64 public immutable blockDecayWindow;
    string public chainName;

    // ── Storage ───────────────────────────────────────────────────────────────
    mapping(PoolId => PackedPoolState) public poolStates;
    mapping(bytes32 => PositionInfo) public storedPositions;

    // 🔒 Internal Slot Mappings for strict type resolution
    mapping(PoolId => bytes32) private _tickSlotMap;
    mapping(PoolId => bytes32) private _flagSlotMap;
    mapping(PoolId => bytes32) private _trackerSlotMap;
    mapping(PoolId => bytes32) private _sandwichFlagSlotMap;

    // Secure Internal Persistent Mappings
    mapping(PoolId => uint256) private _packedTrackers;
    mapping(PoolId => uint256) private _sandwichFlags;

    mapping(PoolId => uint256) public blockVolumeMap;
    mapping(PoolId => uint256) public lastVolumeBlockMap;

    // ── TWAP Oracle Storage ───────────────────────────────────────────────────
    mapping(PoolId => mapping(uint16 => TwapOracle.Observation)) private _observations;
    mapping(PoolId => TwapOracle.State) private _observationStates;

    // ── Transient/Storage Prefix Keys ─────────────────────────────────────────
    bytes32 private constant PRE_SWAP_TICK_PREFIX = keccak256("hybrid.vol.preSwapTick");
    bytes32 private constant PRE_SWAP_TICK_FLAG = keccak256("hybrid.vol.flag");
    bytes32 private constant TRACKER_PREFIX = keccak256("hybrid.vol.tracker");
    bytes32 private constant SANDWICH_FLAG_PREFIX = keccak256("hybrid.vol.sandwichFlag");
    bytes32 public constant PRE_SWAP_TICK_SLOT = keccak256("curatio.preSwapTick");

    // ── Fee Constants ─────────────────────────────────────────────────────────
    uint24 public constant BASE_FEE = 3000;
    uint24 public constant MID_VOLATILE_FEE = 6000;
    uint24 public constant HIGH_VOLATILE_FEE = 15000;
    uint24 public constant MEV_PENALTY_FEE = 100000;

    // ── Configurable thresholds ───────────────────────────────────────────────
    uint256 public tickThresholdHigh = 500;
    uint256 public tickThresholdMid = 200;
    uint256 public mevVolumeThreshold = 1 ether;
    uint256 public sandwichTickThreshold = 80;

    bool private _entered;

    // ── Events ────────────────────────────────────────────────────────────────
    event LiquidityUpdated(
        address indexed sender,
        PoolId indexed poolId,
        int24 tickLower,
        int24 tickUpper,
        uint128 newLiquidity,
        bool isAdding
    );
    event FeeUpdated(PoolId indexed poolId, uint24 newFee);
    event HistoryUpdated(PoolId indexed poolId, int24 newTick, uint256 blockNumber, uint256 timestamp);
    event ThresholdsUpdated(uint256 high, uint256 mid, uint256 sandwichThreshold);
    event SandwichDetected(
        PoolId indexed poolId, int24 firstMove, int24 lastMove, uint256 blockVolume, uint24 feeApplied
    );
    event DeployedOnChain(uint256 indexed chainId, string chainName, uint64 blockDecayWindow);
    event OracleCardinalityIncreased(PoolId indexed poolId, uint16 oldCardinality, uint16 newCardinality);

    // ── Reentrancy Guard ──────────────────────────────────────────────────────
    modifier nonReentrant() {
        require(!_entered, "ReentrancyGuard: reentrant call");
        _entered = true;
        _;
        _entered = false;
    }

    constructor(IPoolManager _poolManager, address _owner) BaseHook(_poolManager) Ownable() {
        deployedChainId = block.chainid;
        blockDecayWindow = ChainRegistry.getBlockDecayWindow(block.chainid);
        chainName = ChainRegistry.getChainName(block.chainid);

        if (block.chainid != 31337) {
            address expected = ChainRegistry.getPoolManager(block.chainid);
            require(address(_poolManager) == expected, "Wrong PoolManager for this chain");
        }

        owner = _owner;
        emit OwnershipTransferred(msg.sender, _owner);
        emit DeployedOnChain(deployedChainId, chainName, blockDecayWindow);
    }

    // ── Hook Permissions ──────────────────────────────────────────────────────
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: true,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ─── Initialize ───────────────────────────────────────────────────────────

    function beforeInitialize(address, PoolKey calldata, uint160) external pure override returns (bytes4) {
        return this.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata key, uint160, int24 tick)
        external
        override
        onlyPoolManager
        returns (bytes4)
    {
        PoolId poolId = key.toId();

        poolStates[poolId] = PackedPoolState({
            lastTick: tick,
            fee: BASE_FEE,
            lastBlock: uint64(block.number),
            lastTimestamp: uint64(block.timestamp),
            initialized: true
        });

        // Compute slots securely
        _tickSlotMap[poolId] = keccak256(abi.encodePacked(PRE_SWAP_TICK_PREFIX, poolId));
        _flagSlotMap[poolId] = keccak256(abi.encodePacked(PRE_SWAP_TICK_FLAG, poolId));
        _trackerSlotMap[poolId] = keccak256(abi.encodePacked(TRACKER_PREFIX, poolId));
        _sandwichFlagSlotMap[poolId] = keccak256(abi.encodePacked(SANDWICH_FLAG_PREFIX, poolId));

        // Seed TWAP oracle at slot 0
        TwapOracle.initialize(_observations[poolId], _observationStates[poolId], uint32(block.timestamp));

        return this.afterInitialize.selector;
    }

    // ─── Liquidity ────────────────────────────────────────────────────────────
    function beforeRemoveLiquidity(address, PoolKey calldata key, ModifyLiquidityParams calldata params, bytes calldata)
        external
        view
        override
        onlyPoolManager
        returns (bytes4)
    {
        PoolId poolId = key.toId();
        uint128 currentLiquidity = poolManager.getLiquidity(poolId);

        // Convert negative delta to uint256 safely to prevent SafeCast overflow
        uint256 requestedRemoval = params.liquidityDelta < 0 ? uint256(-int256(params.liquidityDelta)) : 0;

        if (requestedRemoval > uint256(currentLiquidity)) {
            revert("Insufficient liquidity");
        }

        return this.beforeRemoveLiquidity.selector;
    }

    function afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external override onlyPoolManager nonReentrant returns (bytes4, BalanceDelta) {
        _updatePositionLiquidity(sender, key, params, true);
        return (this.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    function afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external override onlyPoolManager nonReentrant returns (bytes4, BalanceDelta) {
        _updatePositionLiquidity(sender, key, params, false);
        return (this.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    function _updatePositionLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bool isAdding
    ) internal {
        PoolId poolId = key.toId();
        bytes32 positionKey = keccak256(abi.encodePacked(sender, poolId, params.tickLower, params.tickUpper));
        int256 delta = params.liquidityDelta;
        if (delta == 0) return;

        if (isAdding) {
            require(delta > 0, "Delta must be positive when adding");
            uint256 temp = uint256(delta);
            require(temp <= type(uint128).max, "Delta too large");
            storedPositions[positionKey].liquidity += uint128(temp);
        } else {
            require(delta < 0, "Delta must be negative when removing");
            uint256 temp = uint256(-delta);
            require(temp <= type(uint128).max, "Delta too large");
            uint128 toRemove = uint128(temp);
            require(storedPositions[positionKey].liquidity >= toRemove, "Insufficient liquidity");
            storedPositions[positionKey].liquidity -= toRemove;
        }

        emit LiquidityUpdated(
            sender, poolId, params.tickLower, params.tickUpper, storedPositions[positionKey].liquidity, isAdding
        );
    }

    // ─── Swap Hooks ───────────────────────────────────────────────────────────
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        uint256 currentBlock = block.number;
        (, int24 currentTick,,) = poolManager.getSlot0(poolId);

        // ১. Transient storage setup & verification
        bytes32 flagSlot = keccak256(abi.encodePacked(poolId, "flag"));
        bytes32 tickSlot = keccak256(abi.encodePacked(poolId, "tick"));

        uint256 isDirty;
        assembly { isDirty := tload(flagSlot) }
        if (isDirty != 0) revert("Transient storage dirty: composability violation");

        assembly {
            tstore(flagSlot, 1)
            tstore(tickSlot, currentTick)
        }

        // ২. Zero-amount swap guard
        if (params.amountSpecified == 0) {
            return
                (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, BASE_FEE | LPFeeLibrary.OVERRIDE_FEE_FLAG);
        }

        // ৩. MEV / Sandwich Block Level Check
        uint256 sandwichBlock = _sandwichFlags[poolId];
        if (sandwichBlock == currentBlock) {
            return (
                this.beforeSwap.selector,
                BeforeSwapDeltaLibrary.ZERO_DELTA,
                MEV_PENALTY_FEE | LPFeeLibrary.OVERRIDE_FEE_FLAG
            );
        }

        // 🌟 ৪. TWAP Protection & Dynamic Fee Calculation
        uint24 feeToApply = BASE_FEE;

        // ১২০ সেকেন্ডের TWAP উইন্ডো থেকে গড় টিকেট নেয়ার চেষ্টা
        try this.getTwapTick(key, 120) returns (int24 twapTick) {
            // Current Tick এবং TWAP Tick-এর মধ্যে পার্থক্য হিসেব
            int24 tickDivergenceRaw = currentTick - twapTick;
            uint24 tickDivergence = abs(tickDivergenceRaw);

            // যদি স্পট প্রাইস TWAP থেকে অতিরিক্ত দূরে সরে যায় (MEV / Flash Loan Manipulation)
            if (uint256(tickDivergence) >= tickThresholdHigh) {
                feeToApply = MEV_PENALTY_FEE; // চরম ব্যবধানে পেনাল্টি ফি
            } else if (uint256(tickDivergence) >= tickThresholdMid) {
                feeToApply = HIGH_VOLATILE_FEE; // মাঝারি ব্যবধানে হাই ভোলাটিলিটি ফি
            } else {
                // ৫. Block Decay অনুযায়ী সাধারণ বা ভোলাটাইল ফি
                PackedPoolState storage state = poolStates[poolId];
                uint256 blockDelta = currentBlock > state.lastBlock ? currentBlock - state.lastBlock : 0;

                feeToApply = (blockDelta >= blockDecayWindow || state.fee == 0) ? BASE_FEE : state.fee;
            }
        } catch {
            // Cold Start Fallback: পুল নতুন হলে বা TWAP ডাটা না থাকলে সাধারণ ফি লজিক ব্যবহার হবে
            PackedPoolState storage state = poolStates[poolId];
            uint256 blockDelta = currentBlock > state.lastBlock ? currentBlock - state.lastBlock : 0;

            feeToApply = (blockDelta >= blockDecayWindow || state.fee == 0) ? BASE_FEE : state.fee;
        }

        return
            (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, feeToApply | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, int128)
    {
        PoolId poolId = key.toId();
        uint256 currentBlock = block.number;
        (, int24 postSwapTick,,) = poolManager.getSlot0(poolId);

        // 👈 beforeSwap-এর সাথে মিলিয়ে একই ডাইনামিক স্লট ব্যবহার করা হচ্ছে
        bytes32 flagSlot = keccak256(abi.encodePacked(poolId, "flag"));
        bytes32 tickSlot = keccak256(abi.encodePacked(poolId, "tick"));

        uint256 flag;
        bytes32 rawPreSwapTick;

        // 1. Load pre-swap state from transient storage
        assembly {
            flag := tload(flagSlot)
            rawPreSwapTick := tload(tickSlot)
        }

        if (flag == 0) revert("Composability violation: unexpected state");

        // Clear transient flag slot for cleanup
        assembly { tstore(flagSlot, 0) }

        // Safely cast transient byte storage to signed int24
        int24 preSwapTick = int24(int256(uint256(rawPreSwapTick)));

        // 2. Write observation to TWAP oracle
        TwapOracle.write(_observations[poolId], _observationStates[poolId], uint32(block.timestamp), postSwapTick);

        // 3. Unpack MEV / Sandwich tracker state
        uint256 trackerPacked = _packedTrackers[poolId];
        SandwichTracker memory tracker = _unpackTracker(trackerPacked);

        if (!tracker.initialized || tracker.startBlock != currentBlock) {
            tracker = SandwichTracker({
                firstMove: 0,
                lastMove: 0,
                peakTick: postSwapTick,
                swapCount: 0,
                startBlock: currentBlock,
                initialized: true
            });
        }

        // 4. Calculate tick delta magnitude
        int24 tickDeltaRaw = postSwapTick - preSwapTick;
        uint24 tickDelta = uint24(tickDeltaRaw >= 0 ? tickDeltaRaw : -tickDeltaRaw);

        // 5. Track volume per block
        uint256 swapAmount =
            params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);

        if (lastVolumeBlockMap[poolId] != currentBlock) {
            blockVolumeMap[poolId] = swapAmount;
            lastVolumeBlockMap[poolId] = currentBlock;
        } else {
            blockVolumeMap[poolId] += swapAmount;
        }

        // 6. Compute dynamic escalated fee based on tick movement
        PackedPoolState storage state = poolStates[poolId];
        uint256 blockDelta = currentBlock > state.lastBlock ? currentBlock - state.lastBlock : 0;

        uint24 feeToSave = _computeFee(tickDelta, blockDelta, state.fee);

        // 7. Update tracker direction and peak tick
        int24 currentMove = postSwapTick - preSwapTick;

        if (currentMove != 0) {
            tracker.swapCount++;
            tracker.lastMove = currentMove;

            if (tracker.firstMove == 0) {
                tracker.firstMove = currentMove;
            }

            if (currentMove > 0 && postSwapTick > tracker.peakTick) {
                tracker.peakTick = postSwapTick;
            } else if (currentMove < 0 && postSwapTick < tracker.peakTick) {
                tracker.peakTick = postSwapTick;
            }
        }

        // 8. Detect sandwich attack patterns
        bool isSandwich = false;
        uint256 volume = blockVolumeMap[poolId];

        if (tracker.swapCount >= 2 && tracker.firstMove != 0 && currentMove != 0) {
            bool isReversal = (tracker.firstMove > 0 && currentMove < 0) || (tracker.firstMove < 0 && currentMove > 0);

            if (isReversal && volume > mevVolumeThreshold) {
                isSandwich = true;
            }
        }

        if (_sandwichFlags[poolId] == currentBlock) {
            isSandwich = true;
        }

        // Apply MEV penalty fee if a sandwich pattern was detected
        if (isSandwich) {
            feeToSave = MEV_PENALTY_FEE;
            _sandwichFlags[poolId] = currentBlock;

            emit SandwichDetected(poolId, tracker.firstMove, currentMove, blockVolumeMap[poolId], feeToSave);

            tracker.firstMove = currentMove;
            tracker.swapCount = 1;
            tracker.lastMove = currentMove;
        }

        // 9. Persist updated tracker and pool state
        _packedTrackers[poolId] = _packTracker(tracker);

        poolStates[poolId] = PackedPoolState({
            lastTick: postSwapTick,
            fee: feeToSave,
            lastBlock: uint64(currentBlock),
            lastTimestamp: uint64(block.timestamp),
            initialized: true
        });

        // 10. Emit update events
        emit FeeUpdated(poolId, feeToSave);
        emit HistoryUpdated(poolId, postSwapTick, currentBlock, block.timestamp);

        return (this.afterSwap.selector, 0);
    }

    // ─── Internal helpers ─────────────────────────────────────────────────────

    function abs(int24 n) internal pure returns (uint24) {
        return n >= 0 ? uint24(uint32(int32(n))) : uint24(uint32(-int32(n)));
    }

    function _computeFee(uint24 tickDelta, uint256 blockDelta, uint24 currentFee) internal view returns (uint24) {
        // '>' এর জায়গায় '>=' ব্যবহার করুন
        if (uint256(tickDelta) >= tickThresholdHigh) return HIGH_VOLATILE_FEE;
        if (uint256(tickDelta) >= tickThresholdMid) return MID_VOLATILE_FEE;

        if (blockDelta >= blockDecayWindow || currentFee == 0) return BASE_FEE;

        return currentFee;
    }

    // ── Pack/Unpack tracker ────────────────────────────────────────────────
    function _packTracker(SandwichTracker memory t) internal pure returns (uint256) {
        // Cast signed ticks (int24) through int32 -> uint32 -> uint24 to preserve
        // two's complement bit patterns and prevent Solidity 0.8+ cast underflow panics (0x11)
        uint24 rawFirst = uint24(uint32(int32(t.firstMove)));
        uint24 rawLast = uint24(uint32(int32(t.lastMove)));
        uint24 rawPeak = uint24(uint32(int32(t.peakTick)));

        return (uint256(rawFirst) << 232) | (uint256(rawLast) << 208) | (uint256(rawPeak) << 184)
            | (uint256(t.swapCount) << 152) | (uint256(t.startBlock) << 56) | (t.initialized ? 1 : 0);
    }

    function _unpackTracker(uint256 packed) internal pure returns (SandwichTracker memory t) {
        uint24 rawFirst = uint24((packed >> 232) & 0xFFFFFF);
        uint24 rawLast = uint24((packed >> 208) & 0xFFFFFF);
        uint24 rawPeak = uint24((packed >> 184) & 0xFFFFFF);

        t.firstMove = rawFirst & 0x800000 != 0 ? int24(int32(uint32(rawFirst) | 0xFF000000)) : int24(rawFirst);
        t.lastMove = rawLast & 0x800000 != 0 ? int24(int32(uint32(rawLast) | 0xFF000000)) : int24(rawLast);
        t.peakTick = rawPeak & 0x800000 != 0 ? int24(int32(uint32(rawPeak) | 0xFF000000)) : int24(rawPeak);

        t.swapCount = uint32((packed >> 152) & 0xFFFFFFFF);
        t.startBlock = (packed >> 56) & 0xFFFFFFFFFFFFFFFFFFFFFFFF;
        t.initialized = (packed & 0x1) == 1;
    }

    // ─── View/Getter functions ───────────────────────────────────────────────

    // ✅ Explicit Getters to bypass custom value type mapping quirks in tests
    function tickSlotMap(PoolId poolId) external view returns (bytes32) {
        return _tickSlotMap[poolId];
    }

    function flagSlotMap(PoolId poolId) external view returns (bytes32) {
        return _flagSlotMap[poolId];
    }

    function trackerSlotMap(PoolId poolId) external view returns (bytes32) {
        return _trackerSlotMap[poolId];
    }

    function sandwichFlagSlotMap(PoolId poolId) external view returns (bytes32) {
        return _sandwichFlagSlotMap[poolId];
    }

    function getCurrentFee(PoolKey calldata key) external view returns (uint24) {
        PoolId poolId = key.toId();
        PackedPoolState memory state = poolStates[poolId];
        if (!state.initialized) return BASE_FEE;

        uint256 blockDelta = block.number > state.lastBlock ? block.number - state.lastBlock : 0;

        if (blockDelta >= blockDecayWindow) return BASE_FEE;
        return state.fee == 0 ? BASE_FEE : state.fee;
    }

    function getPoolState(PoolKey calldata key)
        external
        view
        returns (int24 lastTick, uint24 fee, uint64 lastBlock, uint64 lastTimestamp, bool initialized)
    {
        PackedPoolState memory s = poolStates[key.toId()];
        return (s.lastTick, s.fee, s.lastBlock, s.lastTimestamp, s.initialized);
    }

    function getCurrentBlockVolume(PoolKey calldata key) external view returns (uint256) {
        PoolId poolId = key.toId();
        return lastVolumeBlockMap[poolId] != block.number ? 0 : blockVolumeMap[poolId];
    }

    function getSandwichTracker(PoolKey calldata key)
        external
        view
        returns (
            int24 firstMove,
            int24 lastMove,
            int24 peakTick,
            uint256 startBlock,
            uint256 swapCount,
            bool initialized
        )
    {
        PoolId poolId = key.toId();
        uint256 packed = _packedTrackers[poolId];
        SandwichTracker memory t = _unpackTracker(packed);
        return (t.firstMove, t.lastMove, t.peakTick, t.startBlock, uint256(t.swapCount), t.initialized);
    }

    function isInitialized(PoolKey calldata key) external view returns (bool) {
        return poolStates[key.toId()].initialized;
    }

    function getChainInfo()
        external
        view
        returns (uint256 chainId, string memory name, uint64 decayWindow, bool isUnichain)
    {
        return (
            deployedChainId,
            chainName,
            blockDecayWindow,
            deployedChainId == ChainRegistry.UNICHAIN || deployedChainId == ChainRegistry.UNICHAIN_SEPOLIA
        );
    }

    // ─── TWAP Oracle — public API ─────────────────────────────────────────────

    /// @notice Time-weighted average tick over the last `twapWindow` seconds.
    /// @dev Reverts if the oracle doesn't yet have `twapWindow` seconds of history
    ///      (e.g. right after pool init, or if cardinality is too small).
    // Example of problematic pattern causing early return:
    function getTwapTick(PoolKey calldata key, uint32 twapWindow) external view returns (int24 twapTick) {
        require(twapWindow > 0, "TwapWindow must be > 0");

        uint32 nowTime = uint32(block.timestamp);

        // 🔴 Underflow Panic (0x11) রোধ করতে এবং পর্যাপ্ত হিস্ট্রি না থাকলে Revert করতে এই চেকটি যুক্ত করা হয়েছে
        require(nowTime >= twapWindow, "TwapOracle: target older than oldest observation");

        uint32 targetTime = nowTime - twapWindow;
        PoolId poolId = key.toId();

        (, int24 currentTick,,) = poolManager.getSlot0(poolId);

        int56 currentCumulative =
            TwapOracle.observeAt(_observations[poolId], _observationStates[poolId], nowTime, currentTick);

        int56 targetCumulative =
            TwapOracle.observeAt(_observations[poolId], _observationStates[poolId], targetTime, currentTick);

        int56 timeDelta = int56(uint56(twapWindow));
        twapTick = int24((currentCumulative - targetCumulative) / timeDelta);
    }

    /// @notice Raw oracle state, useful for off-chain tooling / debugging.
    function getOracleState(PoolKey calldata key)
        external
        view
        returns (uint16 index, uint16 cardinality, uint16 cardinalityNext)
    {
        TwapOracle.State memory s = _observationStates[key.toId()];
        return (s.index, s.cardinality, s.cardinalityNext);
    }

    /// @notice Grows the oracle's ring-buffer capacity so a longer TWAP window
    ///         can eventually be supported. Anyone may call and pay the gas
    ///         to pre-warm slots (same pattern as Uniswap v3 pools).
    function increaseObservationCardinality(PoolKey calldata key, uint16 newCardinality) external {
        PoolId poolId = key.toId();
        TwapOracle.State storage state = _observationStates[poolId];
        require(state.cardinality > 0, "Pool not initialized");

        uint16 old = state.cardinality;
        TwapOracle.grow(_observations[poolId], state, newCardinality);

        // Bump the active cardinality immediately (simpler + more predictable
        // than v3's lazy wraparound bump — acceptable tradeoff for this hook).
        if (newCardinality > state.cardinality) {
            state.cardinality = newCardinality;
        }

        emit OracleCardinalityIncreased(poolId, old, state.cardinality);
    }

    // ─── Admin ────────────────────────────────────────────────────────────────

    function setTickThresholds(uint256 high, uint256 mid, uint256 volumeThreshold, uint256 sandwichThreshold)
        external
        onlyOwner
    {
        require(high > mid, "High threshold must be greater than mid");
        tickThresholdHigh = high;
        tickThresholdMid = mid;
        mevVolumeThreshold = volumeThreshold;
        sandwichTickThreshold = sandwichThreshold;
        emit ThresholdsUpdated(high, mid, sandwichThreshold);
    }
}
