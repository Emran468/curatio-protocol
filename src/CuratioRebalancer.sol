// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/access/AccessControl.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AutomationCompatibleInterface} from "@chainlink/contracts/src/v0.8/automation/AutomationCompatible.sol";
import {CuratioStrategistRegistry} from "./CuratioStrategistRegistry.sol";

/// @dev Read-only view into CuratioHook (Layer 1) — used purely as a volatility
///      signal to decide WHEN to rebalance. The hook is never called to execute
///      liquidity changes; this contract does that directly against PoolManager.
interface ICuratioHookView {
    function getCurrentFee(PoolKey calldata key) external view returns (uint24);
    function getPoolState(PoolKey calldata key)
        external
        view
        returns (int24 lastTick, uint24 fee, uint64 lastBlock, uint64 lastTimestamp, bool initialized);
    // NEW: needed for TWAP-based range calculation in performUpkeep
    function getTwapTick(PoolKey calldata key, uint32 twapWindow) external view returns (int24 twapTick);
}

/**
 * @title CuratioRebalancer
 * @dev Layer 4 — Receives deposit/withdraw notifications from CuratioVault (Layer 3),
 *      reads volatility signals from CuratioHook (Layer 1) as a read-only oracle,
 *      and executes liquidity rebalancing directly against Uniswap v4's PoolManager
 *      via the unlock/callback pattern.
 */
contract CuratioRebalancer is AccessControl, IUnlockCallback, AutomationCompatibleInterface {
    using PoolIdLibrary for PoolKey;

    bytes32 public constant STRATEGIST_ROLE = keccak256("STRATEGIST_ROLE");
    bytes32 public constant VAULT_ROLE = keccak256("VAULT_ROLE");

    // ── Chainlink Automation config ────────────────────────────────────────
    uint32 public constant TWAP_WINDOW = 120;
    uint24 public constant FEE_ESCALATION_THRESHOLD = 6000; // MID_VOLATILE_FEE, not BASE_FEE
    uint256 public constant TICK_DIVERGENCE_THRESHOLD = 200;

    address public automationRegistry;
    uint256 public defaultRebalanceAmount;
    CuratioStrategistRegistry public strategistRegistry;

    error NotAutomationRegistry(address caller);

    modifier onlyAutomationRegistry() {
        if (msg.sender != automationRegistry) revert NotAutomationRegistry(msg.sender);
        _;
    }

    IPoolManager public immutable poolManager;
    ICuratioHookView public hook;
    address public vault;

    // Active tick range this rebalancer manages for its configured pool
    PoolKey public managedPool;
    bool public poolConfigured;
    int24 public currentTickLower;
    int24 public currentTickUpper;

    uint256 public rebalanceThreshold;
    uint256 public lastRebalanceBlock;
    uint256 public minBlocksBetweenRebalances = 10;

    // ── Unlock callback action encoding ──────────────────────────────────────
    enum ActionType {
        REBALANCE
    }

    struct RebalanceCallbackData {
        PoolKey key;
        int24 oldTickLower;
        int24 oldTickUpper;
        int24 newTickLower;
        int24 newTickUpper;
        int256 liquidityToMove;
    }

    event HookUpdated(address indexed oldHook, address indexed newHook);
    event VaultUpdated(address indexed oldVault, address indexed newVault);
    event ManagedPoolSet(PoolId indexed poolId);
    event DepositNotified(uint256 assets, uint256 blockNumber);
    event WithdrawNotified(uint256 assets, uint256 blockNumber);
    event RebalanceExecuted(int24 oldTickLower, int24 oldTickUpper, int24 newTickLower, int24 newTickUpper);
    event RebalanceSkipped(string reason);
    event RebalanceThresholdUpdated(uint256 newThreshold);

    error ZeroAddress();
    error NotVault(address caller);
    error NotPoolManager(address caller);
    error PoolNotConfigured();
    error InvalidTickRange();

    modifier onlyVault() {
        if (msg.sender != vault) revert NotVault(msg.sender);
        _;
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager(msg.sender);
        _;
    }

    constructor(
        address _poolManager,
        address _hook,
        address _vault,
        address _admin,
        uint256 _rebalanceThreshold,
        address _automationRegistry, // NEW
        uint256 _defaultRebalanceAmount // NEW
    ) {
        if (
            _poolManager == address(0) || _hook == address(0) || _vault == address(0) || _admin == address(0)
                || _automationRegistry == address(0)
        ) {
            revert ZeroAddress();
        }
        require(_rebalanceThreshold > 0, "Invalid Threshold");
        require(_defaultRebalanceAmount > 0, "Invalid default amount");

        poolManager = IPoolManager(_poolManager);
        hook = ICuratioHookView(_hook);
        vault = _vault;
        rebalanceThreshold = _rebalanceThreshold;
        automationRegistry = _automationRegistry;
        defaultRebalanceAmount = _defaultRebalanceAmount;

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(STRATEGIST_ROLE, _admin);
        _grantRole(VAULT_ROLE, _vault);
    }

    // ─── Vault-triggered notifications ───────────────────────────────────────

    function notifyDeposit(uint256 assets) external onlyVault {
        emit DepositNotified(assets, block.number);
        if (assets >= rebalanceThreshold) {
            _maybeAutoRebalance();
        }
    }

    function notifyWithdraw(uint256 assets) external onlyVault {
        emit WithdrawNotified(assets, block.number);
        if (assets >= rebalanceThreshold) {
            _maybeAutoRebalance();
        }
    }

    function _maybeAutoRebalance() internal {
        if (!poolConfigured) {
            emit RebalanceSkipped("Pool not configured");
            return;
        }
        if (block.number < lastRebalanceBlock + minBlocksBetweenRebalances) {
            emit RebalanceSkipped("Too soon since last rebalance");
            return;
        }
        // Auto-rebalance still requires strategist-defined target ticks;
        // this only flags that a rebalance is due. Strategist calls
        // rebalanceLiquidity() to actually execute it. Kept manual-gated
        // deliberately — auto-selecting tick ranges on-chain is a strategy
        // decision, not something to leave fully automatic without review.
        emit RebalanceSkipped("Rebalance due - awaiting strategist execution");
    }

    // ─── Strategist-triggered rebalance (the actual execution path) ─────────

    function rebalanceLiquidity(int24 newTickLower, int24 newTickUpper, int256 liquidityToMove)
        external
        onlyRole(STRATEGIST_ROLE)
    {
        _executeRebalanceLogic(newTickLower, newTickUpper, liquidityToMove);
    }

    /// @dev Shared core logic used by both the manual strategist path
    ///      (rebalanceLiquidity) and the automated keeper path (performUpkeep).
    function _executeRebalanceLogic(int24 newTickLower, int24 newTickUpper, int256 liquidityToMove) internal {
        if (!poolConfigured) revert PoolNotConfigured();
        if (newTickLower >= newTickUpper) revert InvalidTickRange();

        RebalanceCallbackData memory data = RebalanceCallbackData({
            key: managedPool,
            oldTickLower: currentTickLower,
            oldTickUpper: currentTickUpper,
            newTickLower: newTickLower,
            newTickUpper: newTickUpper,
            liquidityToMove: liquidityToMove
        });

        poolManager.unlock(abi.encode(ActionType.REBALANCE, abi.encode(data)));

        currentTickLower = newTickLower;
        currentTickUpper = newTickUpper;
        lastRebalanceBlock = block.number;

        emit RebalanceExecuted(data.oldTickLower, data.oldTickUpper, newTickLower, newTickUpper);

        // NEW: report performance to the registry, if configured. This is
        // deliberately non-blocking (wrapped so a registry failure never
        // reverts an otherwise-successful rebalance) and records msg.sender
        // as the strategist — meaningful whether the caller was the manual
        // strategist path (rebalanceLiquidity) or the automation path
        // (performUpkeep, where onlyAutomationRegistry already gates the
        // real caller).
        _reportToRegistry();
    }

    /// @dev Isolated in its own function with try/catch so a misconfigured
    ///      or reverting registry can never brick the core rebalance path —
    ///      this mirrors the same defensive pattern already used in
    ///      CuratioVault's _notifyRebalancerDeposit/_notifyRebalancerWithdraw.
    function _reportToRegistry() internal {
        if (address(strategistRegistry) == address(0)) return;
        try strategistRegistry.recordRebalanceExecuted(msg.sender) {} catch {}
    }
    // ─── IUnlockCallback ──────────────────────────────────────────────────────

    function unlockCallback(bytes calldata rawData) external override onlyPoolManager returns (bytes memory) {
        (ActionType actionType, bytes memory payload) = abi.decode(rawData, (ActionType, bytes));

        if (actionType == ActionType.REBALANCE) {
            RebalanceCallbackData memory data = abi.decode(payload, (RebalanceCallbackData));
            _executeRebalance(data);
        }

        return "";
    }

    function _executeRebalance(RebalanceCallbackData memory data) internal {
        // 1. পুরানো পজিশন থেকে লিকুইডিটি তুলে নেওয়া
        BalanceDelta deltaRemove;
        if (data.oldTickLower != data.oldTickUpper) {
            (deltaRemove,) = poolManager.modifyLiquidity(
                data.key,
                ModifyLiquidityParams({
                    tickLower: data.oldTickLower,
                    tickUpper: data.oldTickUpper,
                    liquidityDelta: -data.liquidityToMove,
                    salt: bytes32(0)
                }),
                ""
            );
        }

        // 2. নতুন রেঞ্জে লিকুইডিটি যোগ করা
        (BalanceDelta deltaAdd,) = poolManager.modifyLiquidity(
            data.key,
            ModifyLiquidityParams({
                tickLower: data.newTickLower,
                tickUpper: data.newTickUpper,
                liquidityDelta: data.liquidityToMove,
                salt: bytes32(0)
            }),
            ""
        );

        // 3. 🚨 TOTAL DELTA SETTLEMENT (Uniswap v4 Mandatory Step)
        int128 delta0 = deltaRemove.amount0() + deltaAdd.amount0();
        int128 delta1 = deltaRemove.amount1() + deltaAdd.amount1();

        _settleCurrency(data.key.currency0, delta0);
        _settleCurrency(data.key.currency1, delta1);
    }

    /// @dev Helper to settle positive or negative deltas with PoolManager
    /// @dev Uniswap v4 Delta Settlement Logic
    function _settleCurrency(Currency currency, int128 delta) internal {
        if (delta < 0) {
            uint256 amount = uint256(uint128(-delta));

            // ১. PoolManager-এ মুদ্রা সিঙ্ক
            poolManager.sync(currency);

            // ২. Native ETH নাকি ERC20 টোকেন তা চেক করে পরিশোধ করা
            if (Currency.unwrap(currency) == address(0)) {
                poolManager.settle{value: amount}();
            } else {
                IERC20(Currency.unwrap(currency)).transfer(address(poolManager), amount);
                poolManager.settle();
            }
        } else if (delta > 0) {
            uint256 amount = uint256(uint128(delta));
            // PoolManager থেকে টোকেন তুলে নেওয়া
            poolManager.take(currency, address(this), amount);
        }
    }

    // ─── Admin ────────────────────────────────────────────────────────────────

    function setManagedPool(PoolKey calldata key) external onlyRole(DEFAULT_ADMIN_ROLE) {
        managedPool = key;
        poolConfigured = true;
        currentTickLower = 0;
        currentTickUpper = 0;
        emit ManagedPoolSet(key.toId());
    }

    function setHook(address _hook) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_hook == address(0)) revert ZeroAddress();
        emit HookUpdated(address(hook), _hook);
        hook = ICuratioHookView(_hook);
    }

    function setVault(address _vault) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_vault == address(0)) revert ZeroAddress();
        _revokeRole(VAULT_ROLE, vault);
        emit VaultUpdated(vault, _vault);
        vault = _vault;
        _grantRole(VAULT_ROLE, _vault);
    }

    function setRebalanceThreshold(uint256 newThreshold) external onlyRole(STRATEGIST_ROLE) {
        require(newThreshold > 0, "Invalid Threshold");
        rebalanceThreshold = newThreshold;
        emit RebalanceThresholdUpdated(newThreshold);
    }

    function setMinBlocksBetweenRebalances(uint256 blocks_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        minBlocksBetweenRebalances = blocks_;
    }

    // ─── Chainlink Automation ───────────────────────────────────────────────

    function checkUpkeep(bytes calldata) external view override returns (bool upkeepNeeded, bytes memory performData) {
        if (!poolConfigured) return (false, "");
        if (block.number < lastRebalanceBlock + minBlocksBetweenRebalances) return (false, "");

        (bool stateSuccess, int24 lastTick, uint24 fee, bool initialized) = _tryGetPoolState();
        if (!stateSuccess || !initialized) return (false, "");

        bool feeHigh = fee >= FEE_ESCALATION_THRESHOLD;

        (bool twapSuccess, int24 twapTick) = _tryGetTwapTick();
        bool twapDiverged = false;
        if (twapSuccess) {
            int24 divergence = lastTick - twapTick;
            if (divergence < 0) divergence = -divergence;
            twapDiverged = uint256(uint24(divergence)) > TICK_DIVERGENCE_THRESHOLD;
        }

        if (feeHigh || twapDiverged) {
            return (true, abi.encode(twapSuccess ? twapTick : lastTick, twapDiverged));
        }
        return (false, "");
    }

    function performUpkeep(bytes calldata performData) external override onlyAutomationRegistry {
        if (!poolConfigured) revert PoolNotConfigured();
        if (block.number < lastRebalanceBlock + minBlocksBetweenRebalances) {
            emit RebalanceSkipped("Too soon since last rebalance");
            return;
        }

        (int24 referenceTick, bool twapDiverged) = abi.decode(performData, (int24, bool));

        int24 tickSpacing = managedPool.tickSpacing;

        // নেতিবাচক টিকের জন্য সঠিক ফ্লোর ডিভিশন লজিক
        int24 baseTick = (referenceTick >= 0)
            ? (referenceTick / tickSpacing) * tickSpacing
            : ((referenceTick - tickSpacing + 1) / tickSpacing) * tickSpacing;

        int24 rangeWidthInSpacings = twapDiverged ? int24(3) : int24(2);
        int24 newLower = baseTick - (tickSpacing * rangeWidthInSpacings);
        int24 newUpper = baseTick + (tickSpacing * rangeWidthInSpacings);

        if (newLower >= newUpper) revert InvalidTickRange();

        _executeRebalanceLogic(newLower, newUpper, int256(defaultRebalanceAmount));
    }
    // ─── Internal try/catch helpers (avoids try/catch verbosity inline) ────

    function _tryGetPoolState() internal view returns (bool success, int24 lastTick, uint24 fee, bool initialized) {
        try hook.getPoolState(managedPool) returns (int24 _tick, uint24 _fee, uint64, uint64, bool _init) {
            return (true, _tick, _fee, _init);
        } catch {
            return (false, 0, 0, false);
        }
    }

    function _tryGetTwapTick() internal view returns (bool success, int24 twapTick) {
        try hook.getTwapTick(managedPool, TWAP_WINDOW) returns (int24 _twap) {
            return (true, _twap);
        } catch {
            return (false, 0);
        }
    }

    // ─── Admin: automation config ────────────────────────────────────────────

    function setAutomationRegistry(address _newRegistry) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_newRegistry == address(0)) revert ZeroAddress();
        automationRegistry = _newRegistry;
    }

    function setDefaultRebalanceAmount(uint256 _newAmount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_newAmount > 0, "Invalid default amount");
        defaultRebalanceAmount = _newAmount;
    }

    function setStrategistRegistry(address _registry) external onlyRole(DEFAULT_ADMIN_ROLE) {
        // address(0) is explicitly allowed here — it's how you disable
        // registry integration without redeploying the rebalancer.
        strategistRegistry = CuratioStrategistRegistry(_registry);
    }
}

