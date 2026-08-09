// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

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

    /// @dev [FIX-2 helper] Returns true iff the oracle has at least `window`
    ///      seconds of continuous history behind its oldest observation.
    ///      Callers should treat `false` as "cannot verify price integrity"
    ///      and apply a conservative fee, not a permissive one.
    function isWarm(mapping(uint16 => Observation) storage self, State storage state, uint32 window)
        internal
        view
        returns (bool)
    {
        if (state.cardinality == 0) return false;

        uint16 oldestIndex = uint16((uint256(state.index) + 1) % state.cardinality);
        Observation memory oldest = self[oldestIndex];
        if (!oldest.initialized) {
            oldest = self[0];
        }
        if (!oldest.initialized) return false;
        if (block.timestamp < oldest.blockTimestamp) return false;

        return (uint32(block.timestamp) - oldest.blockTimestamp) >= window;
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

    struct PendingThresholds {
        uint256 high;
        uint256 mid;
        uint256 volumeThreshold;
        uint256 sandwichThreshold;
        uint256 eta; // earliest execution timestamp
        bool exists;
    }

    // ── Chain Info ────────────────────────────────────────────────────────────
    uint256 public immutable deployedChainId;
    uint64 public immutable blockDecayWindow;
    string public chainName;

    // ── TWAP warm-up config [FIX-1] ───────────────────────────────────────────
    // Cardinality pre-warmed at pool init so TWAP protection is live from the
    // pool's first swaps instead of requiring a manual bootstrap call.
    // 100 slots is a starting default — tune per deployment (gas cost at init
    // scales linearly with this number, paid once by whoever initializes the pool).
    uint16 public initialCardinality = 100;
    uint32 public constant DEFAULT_TWAP_WINDOW = 120;

    // ── Timelock config [FIX-3] ───────────────────────────────────────────────
    uint256 public constant THRESHOLD_TIMELOCK_DELAY = 2 days;
    PendingThresholds public pendingThresholds;

    // ── Storage ───────────────────────────────────────────────────────────────
    mapping(PoolId => PackedPoolState) public poolStates;
    mapping(bytes32 => PositionInfo) public storedPositions;

    mapping(PoolId => bytes32) private _tickSlotMap;
    mapping(PoolId => bytes32) private _flagSlotMap;
    mapping(PoolId => bytes32) private _trackerSlotMap;
    mapping(PoolId => bytes32) private _sandwichFlagSlotMap;

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
    event ThresholdsProposed(
        uint256 high, uint256 mid, uint256 volumeThreshold, uint256 sandwichThreshold, uint256 eta
    );
    event ThresholdsProposalCancelled();
    event SandwichDetected(
        PoolId indexed poolId, int24 firstMove, int24 lastMove, uint256 blockVolume, uint24 feeApplied
    );
    event DeployedOnChain(uint256 indexed chainId, string chainName, uint64 blockDecayWindow);
    event OracleCardinalityIncreased(PoolId indexed poolId, uint16 oldCardinality, uint16 newCardinality);
    event InitialCardinalityUpdated(uint16 oldValue, uint16 newValue);

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

        _tickSlotMap[poolId] = keccak256(abi.encodePacked(PRE_SWAP_TICK_PREFIX, poolId));
        _flagSlotMap[poolId] = keccak256(abi.encodePacked(PRE_SWAP_TICK_FLAG, poolId));
        _trackerSlotMap[poolId] = keccak256(abi.encodePacked(TRACKER_PREFIX, poolId));
        _sandwichFlagSlotMap[poolId] = keccak256(abi.encodePacked(SANDWICH_FLAG_PREFIX, poolId));

        // [FIX-1] Seed the oracle AND immediately pre-warm cardinality in the
        // same transaction, so write() no longer overwrites a single slot
        // forever. Gas cost of the pre-warm SSTOREs is paid once, here, by
        // whoever initializes the pool — not amortized silently later.
        TwapOracle.State storage state = _observationStates[poolId];
        TwapOracle.initialize(_observations[poolId], state, uint32(block.timestamp));

        uint16 oldCardinality = state.cardinality;
        if (initialCardinality > oldCardinality) {
            TwapOracle.grow(_observations[poolId], state, initialCardinality);
            state.cardinality = initialCardinality;
            emit OracleCardinalityIncreased(poolId, oldCardinality, state.cardinality);
        }

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

        // ── Transient storage setup & verification ──────────────────────────
        // NOTE: this flag assumes PoolManager always pairs beforeSwap with a
        // matching afterSwap for the same pool before any other beforeSwap on
        // that pool can run within the same unlock — this holds under v4's
        // lock/settle model, including multicall-batched swaps, since the
        // pool manager processes swap operations sequentially. If this
        // invariant is ever violated (e.g. a future PoolManager change),
        // this flag would need re-auditing.
        bytes32 flagSlot = keccak256(abi.encodePacked(poolId, "flag"));
        bytes32 tickSlot = keccak256(abi.encodePacked(poolId, "tick"));

        uint256 isDirty;
        assembly { isDirty := tload(flagSlot) }
        if (isDirty != 0) revert("Transient storage dirty: composability violation");

        assembly {
            tstore(flagSlot, 1)
            tstore(tickSlot, currentTick)
        }

        // ── Zero-amount swap guard ───────────────────────────────────────────
        if (params.amountSpecified == 0) {
            return
                (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, BASE_FEE | LPFeeLibrary.OVERRIDE_FEE_FLAG);
        }

        // ── MEV / Sandwich Block Level Check ─────────────────────────────────
        uint256 sandwichBlock = _sandwichFlags[poolId];
        if (sandwichBlock == currentBlock) {
            return (
                this.beforeSwap.selector,
                BeforeSwapDeltaLibrary.ZERO_DELTA,
                MEV_PENALTY_FEE | LPFeeLibrary.OVERRIDE_FEE_FLAG
            );
        }

        // ── [FIX-2] TWAP Protection & Dynamic Fee Calculation ────────────────
        // Explicit warm check replaces try/catch-on-revert: cheaper (no
        // external call + catch overhead) and cold start now defaults to a
        // conservative fee rather than silently falling back to BASE_FEE.
        uint24 feeToApply;

        if (TwapOracle.isWarm(_observations[poolId], _observationStates[poolId], DEFAULT_TWAP_WINDOW)) {
            int24 twapTick = _getTwapTick(poolId, currentTick, DEFAULT_TWAP_WINDOW);
            int24 tickDivergenceRaw = currentTick - twapTick;
            uint24 tickDivergence = abs(tickDivergenceRaw);

            if (uint256(tickDivergence) >= tickThresholdHigh) {
                feeToApply = MEV_PENALTY_FEE;
            } else if (uint256(tickDivergence) >= tickThresholdMid) {
                feeToApply = HIGH_VOLATILE_FEE;
            } else {
                PackedPoolState storage state = poolStates[poolId];
                uint256 blockDelta = currentBlock > state.lastBlock ? currentBlock - state.lastBlock : 0;
                feeToApply = (blockDelta >= blockDecayWindow || state.fee == 0) ? BASE_FEE : state.fee;
            }
        } else {
            // Cold start: we cannot verify spot price against a TWAP yet, so
            // we assume elevated risk rather than assuming safety.
            feeToApply = MID_VOLATILE_FEE;
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

        bytes32 flagSlot = keccak256(abi.encodePacked(poolId, "flag"));
        bytes32 tickSlot = keccak256(abi.encodePacked(poolId, "tick"));

        uint256 flag;
        bytes32 rawPreSwapTick;

        assembly {
            flag := tload(flagSlot)
            rawPreSwapTick := tload(tickSlot)
        }

        if (flag == 0) revert("Composability violation: unexpected state");

        assembly { tstore(flagSlot, 0) }

        int24 preSwapTick = int24(int256(uint256(rawPreSwapTick)));

        TwapOracle.write(_observations[poolId], _observationStates[poolId], uint32(block.timestamp), preSwapTick);

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

        int24 tickDeltaRaw = postSwapTick - preSwapTick;
        uint24 tickDelta = uint24(tickDeltaRaw >= 0 ? tickDeltaRaw : -tickDeltaRaw);

        uint256 swapAmount =
            params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);

        if (lastVolumeBlockMap[poolId] != currentBlock) {
            blockVolumeMap[poolId] = swapAmount;
            lastVolumeBlockMap[poolId] = currentBlock;
        } else {
            blockVolumeMap[poolId] += swapAmount;
        }

        PackedPoolState storage state = poolStates[poolId];
        uint256 blockDelta = currentBlock > state.lastBlock ? currentBlock - state.lastBlock : 0;

        uint24 feeToSave = _computeFee(tickDelta, blockDelta, state.fee);

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

        // NOTE: sandwich detection below is a heuristic (direction-reversal +
        // per-block volume threshold), not a guaranteed classifier. It can
        // produce false positives on legitimate opposing-direction trades or
        // arbitrage correction in the same block. Tune thresholds carefully
        // and treat MEV_PENALTY_FEE application here as "elevated suspicion",
        // not "proven attack".
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

        if (isSandwich) {
            feeToSave = MEV_PENALTY_FEE;
            _sandwichFlags[poolId] = currentBlock;

            emit SandwichDetected(poolId, tracker.firstMove, currentMove, blockVolumeMap[poolId], feeToSave);

            tracker.firstMove = currentMove;
            tracker.swapCount = 1;
            tracker.lastMove = currentMove;
        }

        _packedTrackers[poolId] = _packTracker(tracker);

        poolStates[poolId] = PackedPoolState({
            lastTick: postSwapTick,
            fee: feeToSave,
            lastBlock: uint64(currentBlock),
            lastTimestamp: uint64(block.timestamp),
            initialized: true
        });

        emit FeeUpdated(poolId, feeToSave);
        emit HistoryUpdated(poolId, postSwapTick, currentBlock, block.timestamp);

        return (this.afterSwap.selector, 0);
    }

    // ─── Internal helpers ─────────────────────────────────────────────────────

    function abs(int24 n) internal pure returns (uint24) {
        return uint24(n >= 0 ? n : -n);
    }

    function _computeFee(uint24 tickDelta, uint256 blockDelta, uint24 currentFee) internal view returns (uint24) {
        if (uint256(tickDelta) >= tickThresholdHigh) return HIGH_VOLATILE_FEE;
        if (uint256(tickDelta) >= tickThresholdMid) return MID_VOLATILE_FEE;

        if (blockDelta >= blockDecayWindow || currentFee == 0) return BASE_FEE;

        return currentFee;
    }

    /// @dev Internal TWAP computation, used only after isWarm() has already
    ///      confirmed sufficient history — avoids the external call + revert
    ///      path that the old try/catch pattern relied on.
    function _getTwapTick(PoolId poolId, int24 currentTick, uint32 twapWindow) internal view returns (int24) {
        uint32 nowTime = uint32(block.timestamp);
        uint32 targetTime = nowTime - twapWindow;

        int56 currentCumulative =
            TwapOracle.observeAt(_observations[poolId], _observationStates[poolId], nowTime, currentTick);
        int56 targetCumulative =
            TwapOracle.observeAt(_observations[poolId], _observationStates[poolId], targetTime, currentTick);

        int56 timeDelta = int56(uint56(twapWindow));
        return int24((currentCumulative - targetCumulative) / timeDelta);
    }

    // ── Pack/Unpack tracker ────────────────────────────────────────────────
    function _packTracker(SandwichTracker memory t) internal pure returns (uint256) {
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
    /// @dev Reverts if the oracle doesn't yet have `twapWindow` seconds of history.
    ///      Kept as public API for off-chain callers / integrators; the hook's
    ///      own beforeSwap no longer depends on this reverting path (see FIX-2).

    function getTwapTick(PoolKey calldata key, uint32 twapWindow) external view returns (int24 twapTick) {
        require(twapWindow > 0, "TwapWindow must be > 0");

        PoolId poolId = key.toId();
        (, int24 currentTick,,) = poolManager.getSlot0(poolId);

        // ভুল check-টা সরিয়ে দিন। history পর্যাপ্ত কিনা সেটা যাচাই করার
        // দায়িত্ব এমনিতেই TwapOracle.binarySearch-এর require-এর উপর ছেড়ে দিন,
        // অথবা explicit ভাবে isWarm() ব্যবহার করুন:
        require(
            TwapOracle.isWarm(_observations[poolId], _observationStates[poolId], twapWindow),
            "TwapOracle: insufficient history for requested window"
        );

        return _getTwapTick(poolId, currentTick, twapWindow);
    }

    /// @notice Whether the oracle has at least `twapWindow` seconds of history.
    ///         Integrators/UIs should check this before calling getTwapTick
    ///         to avoid an unnecessary revert.
    function isOracleWarm(PoolKey calldata key, uint32 twapWindow) external view returns (bool) {
        PoolId poolId = key.toId();
        return TwapOracle.isWarm(_observations[poolId], _observationStates[poolId], twapWindow);
    }

    function getOracleState(PoolKey calldata key)
        external
        view
        returns (uint16 index, uint16 cardinality, uint16 cardinalityNext)
    {
        TwapOracle.State memory s = _observationStates[key.toId()];
        return (s.index, s.cardinality, s.cardinalityNext);
    }

    /// @notice Increases the oracle observation cardinality for a pool
    /// @dev Only emits event if actual growth occurs (prevents no-op event emissions)

    function increaseObservationCardinality(PoolKey calldata key, uint16 targetCardinality)
        external
        returns (uint16 cardinalityNextOld, uint16 cardinalityNextNew)
    {
        PoolId poolId = key.toId();

        // 1. পুল ইনিশিয়ালাইজড কি না চেক করুন (ফেইল-২ ফিক্স)
        require(poolStates[poolId].initialized, "Pool not initialized");

        TwapOracle.State storage state = _observationStates[poolId];
        cardinalityNextOld = state.cardinalityNext;

        // 2. No-op চেক
        if (targetCardinality <= cardinalityNextOld) {
            return (cardinalityNextOld, cardinalityNextOld);
        }

        // 3. অরাকেল বাফার গ্রো করা
        _observations[poolId].grow(state, targetCardinality);

        // 4. cardinality ও cardinalityNext দুটোকেই আপডেট রাখা (ফেইল-১ ফিক্স)
        state.cardinality = state.cardinalityNext;
        cardinalityNextNew = state.cardinalityNext;

        // 5. ইভেন্ট ফায়ার
        if (cardinalityNextNew > cardinalityNextOld) {
            emit OracleCardinalityIncreased(poolId, cardinalityNextOld, cardinalityNextNew);
        }

        return (cardinalityNextOld, cardinalityNextNew);
    }

    // ─── Admin ────────────────────────────────────────────────────────────────

    /// @notice Sets the default oracle cardinality pre-warmed at pool init.
    ///         Only affects pools initialized after this call.
    function setInitialCardinality(uint16 newCardinality) external onlyOwner {
        require(newCardinality > 0, "Must be > 0");
        emit InitialCardinalityUpdated(initialCardinality, newCardinality);
        initialCardinality = newCardinality;
    }

    /// @notice [FIX-3] Step 1 of 2: propose new fee thresholds. Takes effect
    ///         no earlier than THRESHOLD_TIMELOCK_DELAY from now, giving LPs
    ///         and integrators visibility/reaction time before parameters change.
    function proposeTickThresholds(uint256 high, uint256 mid, uint256 volumeThreshold, uint256 sandwichThreshold)
        external
        onlyOwner
    {
        require(high > mid, "High threshold must be greater than mid");
        uint256 eta = block.timestamp + THRESHOLD_TIMELOCK_DELAY;

        pendingThresholds = PendingThresholds({
            high: high,
            mid: mid,
            volumeThreshold: volumeThreshold,
            sandwichThreshold: sandwichThreshold,
            eta: eta,
            exists: true
        });

        emit ThresholdsProposed(high, mid, volumeThreshold, sandwichThreshold, eta);
    }

    /// @notice [FIX-3] Step 2 of 2: execute a previously proposed threshold
    ///         change once its timelock has elapsed.
    function executeTickThresholds() external onlyOwner {
        PendingThresholds memory p = pendingThresholds;
        require(p.exists, "No pending proposal");
        require(block.timestamp >= p.eta, "Timelock not elapsed");

        tickThresholdHigh = p.high;
        tickThresholdMid = p.mid;
        mevVolumeThreshold = p.volumeThreshold;
        sandwichTickThreshold = p.sandwichThreshold;

        delete pendingThresholds;

        emit ThresholdsUpdated(p.high, p.mid, p.sandwichThreshold);
    }

    /// @notice Cancels a pending threshold proposal without applying it.
    function cancelTickThresholdsProposal() external onlyOwner {
        require(pendingThresholds.exists, "No pending proposal");
        delete pendingThresholds;
        emit ThresholdsProposalCancelled();
    }
}
