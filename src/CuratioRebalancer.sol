// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {AutomationCompatibleInterface} from "@chainlink/contracts/src/v0.8/automation/AutomationCompatible.sol";
import {CuratioStrategistRegistry} from "./CuratioStrategistRegistry.sol";

/// @dev Read-only view into CuratioHook (Layer 1). Used as a volatility signal
///      (keeper trigger) and as the TWAP price source for valuation.
interface ICuratioHookView {
    function getCurrentFee(PoolKey calldata key) external view returns (uint24);
    function getPoolState(PoolKey calldata key)
        external
        view
        returns (int24 lastTick, uint24 fee, uint64 lastBlock, uint64 lastTimestamp, bool initialized);
    function getTwapTick(PoolKey calldata key, uint32 twapWindow) external view returns (int24 twapTick);
}

/**
 * @title CuratioRebalancer
 * @notice Layer 4. Moves a single Uniswap v4 LP position between tick ranges, driven by
 *         volatility signals from CuratioHook (dynamic fee + TWAP) via Chainlink Automation
 *         or a strategist, and reports its holdings to CuratioVault in vault-asset terms.
 *
 * @dev Accounting model
 *      - One position: (managedPool, currentTickLower, currentTickUpper, salt 0), size in
 *        `currentLiquidity`. Every rebalance removes ALL of it and re-adds `newLiquidity`
 *        in the new range, so liquidity can never be orphaned in an old range.
 *      - Slippage: every rebalance carries caps on the NET tokens it may pay the pool.
 *        The keeper path uses admin-set caps that default to 0 (fail-safe).
 *      - Valuation: `totalManagedAssets()` prices everything at the hook's TWAP, never at
 *        pool spot, and reverts if the TWAP is unavailable.
 *
 *      Known limitations (prototype): tokens must already be held by this contract (vault
 *      fund flow not wired yet), `returnToVault` serves idle asset only (no swap-on-withdraw
 *      yet), uncollected LP fees are not counted in valuation, and the contract is unaudited.
 */
contract CuratioRebalancer is AccessControl, ReentrancyGuard, IUnlockCallback, AutomationCompatibleInterface {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    bytes32 public constant STRATEGIST_ROLE = keccak256("STRATEGIST_ROLE");
    bytes32 public constant VAULT_ROLE = keccak256("VAULT_ROLE");

    // ── Automation / signal config ───────────────────────────────────────────
    uint32 public constant TWAP_WINDOW = 120;
    uint24 public constant FEE_ESCALATION_THRESHOLD = 6000; // MID_VOLATILE_FEE, not BASE_FEE
    uint256 public constant TICK_DIVERGENCE_THRESHOLD = 200;
    uint256 private constant Q96 = 1 << 96;

    address public automationRegistry;
    /// @dev Liquidity UNITS (not token amounts) used only when no position exists yet.
    uint256 public defaultRebalanceAmount;
    CuratioStrategistRegistry public strategistRegistry;

    /// @dev Max NET tokens the keeper path may pay per rebalance (slippage cap).
    ///      Default 0 => keeper rebalances that must pay tokens revert until admin sets caps.
    uint256 public keeperMaxPay0;
    uint256 public keeperMaxPay1;

    // ── Core state ───────────────────────────────────────────────────────────
    IPoolManager public immutable poolManager;
    ICuratioHookView public hook;
    address public vault;

    PoolKey public managedPool;
    bool public poolConfigured;
    /// @dev Vault asset (one of the pool currencies, never native ETH).
    address public asset;
    int24 public currentTickLower;
    int24 public currentTickUpper;
    /// @dev Liquidity currently deployed in [currentTickLower, currentTickUpper].
    uint128 public currentLiquidity;

    uint256 public rebalanceThreshold;
    uint256 public lastRebalanceBlock;
    uint256 public minBlocksBetweenRebalances = 10;

    enum ActionType {
        REBALANCE
    }

    struct RebalanceCallbackData {
        PoolKey key;
        int24 oldTickLower;
        int24 oldTickUpper;
        uint128 oldLiquidity; // ALL of it is removed
        int24 newTickLower;
        int24 newTickUpper;
        uint128 newLiquidity;
        uint256 maxPay0; // cap on NET tokens paid to the pool
        uint256 maxPay1;
    }

    // ── Events ───────────────────────────────────────────────────────────────
    event HookUpdated(address indexed oldHook, address indexed newHook);
    event VaultUpdated(address indexed oldVault, address indexed newVault);
    event ManagedPoolSet(PoolId indexed poolId);
    event AssetUpdated(address indexed newAsset);
    event DepositNotified(uint256 assets, uint256 blockNumber);
    event WithdrawNotified(uint256 assets, uint256 blockNumber);
    event RebalanceExecuted(int24 oldTickLower, int24 oldTickUpper, int24 newTickLower, int24 newTickUpper);
    event RebalanceSkipped(string reason);
    event RebalanceThresholdUpdated(uint256 newThreshold);
    event KeeperMaxPayUpdated(uint256 maxPay0, uint256 maxPay1);
    event FundsReturned(uint256 amount);

    // ── Errors ───────────────────────────────────────────────────────────────
    error ZeroAddress();
    error NotVault(address caller);
    error NotPoolManager(address caller);
    error NotAutomationRegistry(address caller);
    error PoolNotConfigured();
    error InvalidTickRange();
    error TickNotAligned();
    error InvalidLiquidity();
    error SlippageExceeded();
    error PositionStillActive();
    error InvalidAsset();
    error AssetNotSet();
    error TwapUnavailable();
    error InsufficientIdle(uint256 available, uint256 requested);

    modifier onlyVault() {
        if (msg.sender != vault) revert NotVault(msg.sender);
        _;
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager(msg.sender);
        _;
    }

    modifier onlyAutomationRegistry() {
        if (msg.sender != automationRegistry) revert NotAutomationRegistry(msg.sender);
        _;
    }

    constructor(
        address _poolManager,
        address _hook,
        address _vault,
        address _admin,
        uint256 _rebalanceThreshold,
        address _automationRegistry,
        uint256 _defaultRebalanceAmount
    ) {
        if (
            _poolManager == address(0) || _hook == address(0) || _vault == address(0) || _admin == address(0)
                || _automationRegistry == address(0)
        ) {
            revert ZeroAddress();
        }
        require(_rebalanceThreshold > 0, "Invalid Threshold");
        require(_defaultRebalanceAmount > 0 && _defaultRebalanceAmount <= type(uint128).max, "Invalid default amount");

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

    /// @dev Needed only if a pool currency is native ETH (PoolManager.take sends ETH here).
    receive() external payable {}

    // ═════════════════════════════════════════════════════════════════════════
    // Vault interface
    // ═════════════════════════════════════════════════════════════════════════

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
        // Tick selection stays a strategist/keeper decision; this only flags that a rebalance is due.
        emit RebalanceSkipped("Rebalance due - awaiting strategist execution");
    }

    /// @notice Vault pulls back idle `asset` (e.g. to serve a withdrawal).
    /// @dev TODO(swap): when idle < amount, remove liquidity and swap into `asset` first.
    function returnToVault(uint256 amount) external onlyVault nonReentrant {
        if (asset == address(0)) revert AssetNotSet();

        uint256 idleBalance = IERC20(asset).balanceOf(address(this));
        if (idleBalance < amount) revert InsufficientIdle(idleBalance, amount);

        IERC20(asset).safeTransfer(vault, amount);
        emit FundsReturned(amount);
    }

    /// @notice Everything this contract controls (idle balances of both pool tokens plus the
    ///         LP position), expressed in `asset` and valued at the hook's TWAP price.
    /// @dev    Uses the TWAP, never pool spot, so a same-block swap cannot move it.
    ///         Reverts if the TWAP is unavailable rather than returning a wrong value.
    ///         Uncollected LP fees are not included (conservative).
    function totalManagedAssets() external view returns (uint256) {
        if (asset == address(0)) revert AssetNotSet();

        uint160 sqrtP = TickMath.getSqrtPriceAtTick(_getTwapTickOrFail());
        address t0 = Currency.unwrap(managedPool.currency0);
        address t1 = Currency.unwrap(managedPool.currency1);

        uint256 a0 = _idleBalance(t0);
        uint256 a1 = _idleBalance(t1);

        uint128 liq = currentLiquidity;
        if (liq > 0) {
            uint160 sL = TickMath.getSqrtPriceAtTick(currentTickLower);
            uint160 sU = TickMath.getSqrtPriceAtTick(currentTickUpper);
            if (sqrtP <= sL) {
                a0 += SqrtPriceMath.getAmount0Delta(sL, sU, liq, false);
            } else if (sqrtP < sU) {
                a0 += SqrtPriceMath.getAmount0Delta(sqrtP, sU, liq, false);
                a1 += SqrtPriceMath.getAmount1Delta(sL, sqrtP, liq, false);
            } else {
                a1 += SqrtPriceMath.getAmount1Delta(sL, sU, liq, false);
            }
        }

        if (asset == t0) {
            // token1 -> token0 : a1 * 2^192 / sqrtP^2
            return a0 + FullMath.mulDiv(FullMath.mulDiv(a1, Q96, sqrtP), Q96, sqrtP);
        }
        // token0 -> token1 : a0 * sqrtP^2 / 2^192
        return a1 + FullMath.mulDiv(FullMath.mulDiv(a0, sqrtP, Q96), sqrtP, Q96);
    }

    function _idleBalance(address token) internal view returns (uint256) {
        return token == address(0) ? address(this).balance : IERC20(token).balanceOf(address(this));
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Rebalancing
    // ═════════════════════════════════════════════════════════════════════════

    /// @param newLiquidity liquidity units to hold in the NEW range (all old liquidity is removed)
    /// @param maxPay0 max net currency0 this call may pay to the pool (slippage cap)
    /// @param maxPay1 max net currency1 this call may pay to the pool (slippage cap)
    function rebalanceLiquidity(
        int24 newTickLower,
        int24 newTickUpper,
        uint128 newLiquidity,
        uint256 maxPay0,
        uint256 maxPay1
    ) external onlyRole(STRATEGIST_ROLE) nonReentrant {
        _executeRebalanceLogic(newTickLower, newTickUpper, newLiquidity, maxPay0, maxPay1);
    }

    function _validateTicks(int24 lower, int24 upper) internal view {
        if (lower >= upper) revert InvalidTickRange();
        int24 spacing = managedPool.tickSpacing;
        if (lower % spacing != 0 || upper % spacing != 0) revert TickNotAligned();
        int24 minUsable = (TickMath.MIN_TICK / spacing) * spacing;
        int24 maxUsable = (TickMath.MAX_TICK / spacing) * spacing;
        if (lower < minUsable || upper > maxUsable) revert InvalidTickRange();
    }

    /// @dev Shared core used by the strategist path and the keeper path.
    function _executeRebalanceLogic(
        int24 newTickLower,
        int24 newTickUpper,
        uint128 newLiquidity,
        uint256 maxPay0,
        uint256 maxPay1
    ) internal {
        if (!poolConfigured) revert PoolNotConfigured();
        if (newLiquidity == 0) revert InvalidLiquidity();
        _validateTicks(newTickLower, newTickUpper);

        int24 oldLower = currentTickLower;
        int24 oldUpper = currentTickUpper;

        RebalanceCallbackData memory data = RebalanceCallbackData({
            key: managedPool,
            oldTickLower: oldLower,
            oldTickUpper: oldUpper,
            oldLiquidity: currentLiquidity,
            newTickLower: newTickLower,
            newTickUpper: newTickUpper,
            newLiquidity: newLiquidity,
            maxPay0: maxPay0,
            maxPay1: maxPay1
        });

        poolManager.unlock(abi.encode(ActionType.REBALANCE, abi.encode(data)));

        currentTickLower = newTickLower;
        currentTickUpper = newTickUpper;
        currentLiquidity = newLiquidity;
        lastRebalanceBlock = block.number;

        emit RebalanceExecuted(oldLower, oldUpper, newTickLower, newTickUpper);

        _reportToRegistry();
    }

    /// @dev try/catch so a broken registry can never brick the core rebalance path.
    function _reportToRegistry() internal {
        if (address(strategistRegistry) == address(0)) return;
        try strategistRegistry.recordRebalanceExecuted(msg.sender) {} catch {}
    }

    // ─── IUnlockCallback ─────────────────────────────────────────────────────

    function unlockCallback(bytes calldata rawData) external override onlyPoolManager returns (bytes memory) {
        (ActionType actionType, bytes memory payload) = abi.decode(rawData, (ActionType, bytes));

        if (actionType == ActionType.REBALANCE) {
            RebalanceCallbackData memory data = abi.decode(payload, (RebalanceCallbackData));
            _executeRebalance(data);
        }

        return "";
    }

    function _executeRebalance(RebalanceCallbackData memory data) internal {
        // 1. Remove ALL tracked liquidity from the old range
        BalanceDelta deltaRemove;
        if (data.oldLiquidity > 0) {
            (deltaRemove,) = poolManager.modifyLiquidity(
                data.key,
                ModifyLiquidityParams({
                    tickLower: data.oldTickLower,
                    tickUpper: data.oldTickUpper,
                    liquidityDelta: -int256(uint256(data.oldLiquidity)),
                    salt: bytes32(0)
                }),
                ""
            );
        }

        // 2. Add liquidity to the new range
        (BalanceDelta deltaAdd,) = poolManager.modifyLiquidity(
            data.key,
            ModifyLiquidityParams({
                tickLower: data.newTickLower,
                tickUpper: data.newTickUpper,
                liquidityDelta: int256(uint256(data.newLiquidity)),
                salt: bytes32(0)
            }),
            ""
        );

        // 3. Net delta, slippage caps, settlement
        int128 delta0 = deltaRemove.amount0() + deltaAdd.amount0();
        int128 delta1 = deltaRemove.amount1() + deltaAdd.amount1();

        if (delta0 < 0 && uint256(uint128(-delta0)) > data.maxPay0) revert SlippageExceeded();
        if (delta1 < 0 && uint256(uint128(-delta1)) > data.maxPay1) revert SlippageExceeded();

        _settleCurrency(data.key.currency0, delta0);
        _settleCurrency(data.key.currency1, delta1);
    }

    /// @dev Settle a net delta with the PoolManager (negative = we pay, positive = we take).
    function _settleCurrency(Currency currency, int128 delta) internal {
        if (delta < 0) {
            uint256 amount = uint256(uint128(-delta));

            poolManager.sync(currency);

            if (Currency.unwrap(currency) == address(0)) {
                poolManager.settle{value: amount}();
            } else {
                IERC20(Currency.unwrap(currency)).safeTransfer(address(poolManager), amount);
                poolManager.settle();
            }
        } else if (delta > 0) {
            poolManager.take(currency, address(this), uint256(uint128(delta)));
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Chainlink Automation
    // ═════════════════════════════════════════════════════════════════════════

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

    function performUpkeep(bytes calldata performData) external override onlyAutomationRegistry nonReentrant {
        if (!poolConfigured) revert PoolNotConfigured();
        if (block.number < lastRebalanceBlock + minBlocksBetweenRebalances) {
            emit RebalanceSkipped("Too soon since last rebalance");
            return;
        }

        (int24 referenceTick, bool twapDiverged) = abi.decode(performData, (int24, bool));

        int24 tickSpacing = managedPool.tickSpacing;

        // floor division that is correct for negative ticks
        int24 baseTick = (referenceTick >= 0)
            ? (referenceTick / tickSpacing) * tickSpacing
            : ((referenceTick - tickSpacing + 1) / tickSpacing) * tickSpacing;

        int24 rangeWidthInSpacings = twapDiverged ? int24(3) : int24(2);
        int24 newLower = baseTick - (tickSpacing * rangeWidthInSpacings);
        int24 newUpper = baseTick + (tickSpacing * rangeWidthInSpacings);

        // Do not burn gas/fees re-creating the identical position.
        if (currentLiquidity > 0 && newLower == currentTickLower && newUpper == currentTickUpper) {
            emit RebalanceSkipped("Range unchanged");
            return;
        }

        // Keep the existing position size; fall back to the default only for the first position.
        uint128 liq = currentLiquidity > 0 ? currentLiquidity : uint128(defaultRebalanceAmount);

        _executeRebalanceLogic(newLower, newUpper, liq, keeperMaxPay0, keeperMaxPay1);
    }

    // ─── Hook read helpers ───────────────────────────────────────────────────

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

    /// @dev Strict variant used for valuation: no TWAP, no value.
    function _getTwapTickOrFail() internal view returns (int24) {
        try hook.getTwapTick(managedPool, TWAP_WINDOW) returns (int24 _twap) {
            return _twap;
        } catch {
            revert TwapUnavailable();
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Admin
    // ═════════════════════════════════════════════════════════════════════════

    function setManagedPool(PoolKey calldata key) external onlyRole(DEFAULT_ADMIN_ROLE) {
        // Changing pool while a position exists would orphan it.
        if (currentLiquidity != 0) revert PositionStillActive();
        managedPool = key;
        poolConfigured = true;
        asset = address(0); // must be re-selected for the new pool
        currentTickLower = 0;
        currentTickUpper = 0;
        emit ManagedPoolSet(key.toId());
    }

    /// @notice Select which pool currency is the vault asset (valuation/return unit).
    function setAsset(address _asset) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!poolConfigured) revert PoolNotConfigured();
        if (
            _asset == address(0)
                || (_asset != Currency.unwrap(managedPool.currency0) && _asset != Currency.unwrap(managedPool.currency1))
        ) revert InvalidAsset();
        asset = _asset;
        emit AssetUpdated(_asset);
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

    function setKeeperMaxPay(uint256 maxPay0, uint256 maxPay1) external onlyRole(DEFAULT_ADMIN_ROLE) {
        keeperMaxPay0 = maxPay0;
        keeperMaxPay1 = maxPay1;
        emit KeeperMaxPayUpdated(maxPay0, maxPay1);
    }

    function setAutomationRegistry(address _newRegistry) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_newRegistry == address(0)) revert ZeroAddress();
        automationRegistry = _newRegistry;
    }

    function setDefaultRebalanceAmount(uint256 _newAmount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_newAmount > 0 && _newAmount <= type(uint128).max, "Invalid default amount");
        defaultRebalanceAmount = _newAmount;
    }

    function setStrategistRegistry(address _registry) external onlyRole(DEFAULT_ADMIN_ROLE) {
        // address(0) disables registry integration without redeploying.
        strategistRegistry = CuratioStrategistRegistry(_registry);
    }
}
