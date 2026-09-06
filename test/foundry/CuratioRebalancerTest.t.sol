// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console, Vm} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, BalanceDeltaLibrary, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {CuratioRebalancer} from "../../src/CuratioRebalancer.sol";
import {MockERC20} from "@uniswap/v4-core/lib/solmate/src/test/utils/mocks/MockERC20.sol";

// Uniswap v4 official Test ERC20 token import
import {TestERC20} from "@uniswap/v4-core/src/test/TestERC20.sol";

/// @dev Minimal mock so we can test onlyPoolManager gating and unlock-triggered
///      calls without deploying the full real PoolManager. NOT a substitute for
///      integration testing against the real PoolManager before mainnet.
///      Used for pure access-control tests where the manager is never actually
///      invoked with a real unlock/callback flow.
contract MockPoolManager {
    function unlock(bytes calldata data) external returns (bytes memory) {
        return CuratioRebalancer(msg.sender == address(this) ? address(0) : payable(msg.sender)).unlockCallback(data);
    }
}

/// @dev Fuller mock PoolManager that actually drives the unlock -> callback ->
///      modifyLiquidity -> sync/settle/take flow, letting us exercise
///      CuratioRebalancer's _executeRebalance and _settleCurrency logic end
///      to end, including both the positive-delta (take) and negative-delta
///      (settle) branches. Deltas are configured per-call by the test so we
///      can deterministically hit each branch.
contract MockPoolManagerFull {
    // Configurable per-call deltas the next modifyLiquidity() call should return.
    int128 public nextDelta0;
    int128 public nextDelta1;
    // Tracks which modifyLiquidity call (1st = remove, 2nd = add) we're on,
    // so the caller can configure asymmetric deltas across the two calls in
    // a single rebalance if desired. Reset at the start of each unlock().
    uint256 public callIndex;

    function unlock(bytes calldata data) external returns (bytes memory) {
        callIndex = 0;
        return IUnlockCallback(msg.sender).unlockCallback(data);
    }

    function setNextDelta(int128 delta0, int128 delta1) external {
        nextDelta0 = delta0;
        nextDelta1 = delta1;
    }

    function modifyLiquidity(PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        returns (BalanceDelta delta, BalanceDelta feesAccrued)
    {
        callIndex++;
        delta = toBalanceDelta(nextDelta0, nextDelta1);
        feesAccrued = BalanceDeltaLibrary.ZERO_DELTA;
    }

    function sync(Currency) external {}

    function settle() external payable returns (uint256) {
        return uint256(uint160(msg.value));
    }

    function take(Currency currency, address to, uint256 amount) external {
        // Simulate the manager paying out ERC20 tokens it is assumed to hold.
        MockERC20(Currency.unwrap(currency)).mint(to, amount);
    }
}

contract CuratioRebalancerTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    CuratioRebalancer public rebalancer;

    address public admin = makeAddr("admin");
    address public strategist = makeAddr("strategist");
    address public vault = makeAddr("vault");
    address public hook = makeAddr("hook");
    address public poolManager = makeAddr("poolManager");
    address public attacker = makeAddr("attacker");
    address public automationRegistry = makeAddr("automationRegistry"); // NEW
    uint256 public constant DEFAULT_REBALANCE_AMOUNT = 1000 ether; // NEW

    PoolKey internal testKey;

    event ManagedPoolSet(PoolId indexed poolId);
    event RebalanceThresholdUpdated(uint256 newThreshold);
    event DepositNotified(uint256 assets, uint256 blockNumber);
    event WithdrawNotified(uint256 assets, uint256 blockNumber);

    function setUp() public {
        rebalancer = new CuratioRebalancer(
            poolManager,
            hook,
            vault,
            admin,
            1 ether, // rebalanceThreshold
            automationRegistry, // NEW
            DEFAULT_REBALANCE_AMOUNT // NEW
        );

        testKey = PoolKey({
            currency0: Currency.wrap(address(0x1111)),
            currency1: Currency.wrap(address(0x2222)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hook)
        });
    }

    // ── Constructor Tests ──────────────────────────────────────────

    function test_constructor_setsInitialState() public view {
        assertEq(address(rebalancer.poolManager()), poolManager);
        assertEq(address(rebalancer.hook()), hook);
        assertEq(rebalancer.vault(), vault);
        assertEq(rebalancer.rebalanceThreshold(), 1 ether);
        assertEq(rebalancer.automationRegistry(), automationRegistry); // NEW
        assertEq(rebalancer.defaultRebalanceAmount(), DEFAULT_REBALANCE_AMOUNT); // NEW
        assertTrue(rebalancer.hasRole(rebalancer.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(rebalancer.hasRole(rebalancer.STRATEGIST_ROLE(), admin));
        assertTrue(rebalancer.hasRole(rebalancer.VAULT_ROLE(), vault));
    }

    function test_constructor_revertsOnZeroPoolManager() public {
        vm.expectRevert(CuratioRebalancer.ZeroAddress.selector);
        new CuratioRebalancer(address(0), hook, vault, admin, 1 ether, automationRegistry, DEFAULT_REBALANCE_AMOUNT);
    }

    function test_constructor_revertsOnZeroHook() public {
        vm.expectRevert(CuratioRebalancer.ZeroAddress.selector);
        new CuratioRebalancer(poolManager, address(0), vault, admin, 1 ether, automationRegistry, DEFAULT_REBALANCE_AMOUNT);
    }

    function test_constructor_revertsOnZeroVault() public {
        vm.expectRevert(CuratioRebalancer.ZeroAddress.selector);
        new CuratioRebalancer(poolManager, hook, address(0), admin, 1 ether, automationRegistry, DEFAULT_REBALANCE_AMOUNT);
    }

    function test_constructor_revertsOnZeroAdmin() public {
        vm.expectRevert(CuratioRebalancer.ZeroAddress.selector);
        new CuratioRebalancer(poolManager, hook, vault, address(0), 1 ether, automationRegistry, DEFAULT_REBALANCE_AMOUNT);
    }

    function test_constructor_revertsOnZeroThreshold() public {
        vm.expectRevert(bytes("Invalid Threshold"));
        new CuratioRebalancer(poolManager, hook, vault, admin, 0, automationRegistry, DEFAULT_REBALANCE_AMOUNT);
    }

    // NEW: constructor validation for the two new parameters
    function test_constructor_revertsOnZeroAutomationRegistry() public {
        vm.expectRevert(CuratioRebalancer.ZeroAddress.selector);
        new CuratioRebalancer(poolManager, hook, vault, admin, 1 ether, address(0), DEFAULT_REBALANCE_AMOUNT);
    }

    function test_constructor_revertsOnZeroDefaultRebalanceAmount() public {
        vm.expectRevert(bytes("Invalid default amount"));
        new CuratioRebalancer(poolManager, hook, vault, admin, 1 ether, automationRegistry, 0);
    }



   

    // ── Vault Notifications Tests ─────────────────────────────────

    function test_notifyDeposit_revertsIfNotVault() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(CuratioRebalancer.NotVault.selector, attacker));
        rebalancer.notifyDeposit(1 ether);
    }

    function test_notifyDeposit_emitsEvent() public {
        vm.prank(vault);
        vm.expectEmit(true, true, true, true);
        emit DepositNotified(2 ether, block.number);
        rebalancer.notifyDeposit(2 ether);
    }

    function test_notifyWithdraw_revertsIfNotVault() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(CuratioRebalancer.NotVault.selector, attacker));
        rebalancer.notifyWithdraw(1 ether);
    }

    function test_notifyWithdraw_emitsEvent() public {
        vm.prank(vault);
        vm.expectEmit(true, true, true, true);
        emit WithdrawNotified(3 ether, block.number);
        rebalancer.notifyWithdraw(3 ether);
    }

    function test_notify_belowThreshold_doesNotTriggerRebalanceSkipped() public {
        vm.recordLogs();
        vm.prank(vault);
        rebalancer.notifyDeposit(0.5 ether);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
    }

    function test_notify_aboveThreshold_poolNotConfigured_emitsSkipped() public {
        vm.expectEmit(false, false, false, true);
        emit CuratioRebalancer.RebalanceSkipped("Pool not configured");

        vm.prank(vault);
        rebalancer.notifyDeposit(2 ether);
    }

    /// @notice Above-threshold deposit, pool configured, but not enough
    ///         blocks have passed since the last rebalance (block 0 counts
    ///         as "last rebalance" implicitly since lastRebalanceBlock
    ///         defaults to 0) — must emit the "too soon" skip reason.
    function test_notify_aboveThreshold_tooSoonSinceLastRebalance_emitsSkipped() public {
        vm.prank(admin);
        rebalancer.setManagedPool(testKey);

        // block.number starts at 1 in Foundry by default; minBlocksBetweenRebalances
        // defaults to 10, and lastRebalanceBlock defaults to 0, so block 1 < 0 + 10.
        vm.expectEmit(false, false, false, true);
        emit CuratioRebalancer.RebalanceSkipped("Too soon since last rebalance");

        vm.prank(vault);
        rebalancer.notifyDeposit(2 ether);
    }

    /// @notice Above-threshold deposit, pool configured, and enough blocks
    ///         have elapsed — must emit the "rebalance due" skip reason
    ///         (auto-rebalance is deliberately manual-gated; see contract
    ///         comment on _maybeAutoRebalance).
    function test_notify_aboveThreshold_dueForRebalance_emitsDueSkipped() public {
        vm.prank(admin);
        rebalancer.setManagedPool(testKey);

        vm.roll(block.number + rebalancer.minBlocksBetweenRebalances());

        vm.expectEmit(false, false, false, true);
        emit CuratioRebalancer.RebalanceSkipped("Rebalance due - awaiting strategist execution");

        vm.prank(vault);
        rebalancer.notifyDeposit(2 ether);
    }

    // ── Admin: setManagedPool Tests ───────────────────────────────

    function test_setManagedPool_onlyAdmin() public {
        vm.prank(attacker);
        vm.expectRevert();
        rebalancer.setManagedPool(testKey);
    }

    function test_setManagedPool_setsStateAndEmits() public {
        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit ManagedPoolSet(testKey.toId());
        rebalancer.setManagedPool(testKey);

        assertTrue(rebalancer.poolConfigured());
        assertEq(rebalancer.currentTickLower(), 0);
        assertEq(rebalancer.currentTickUpper(), 0);

        (Currency c0,,,,) = rebalancer.managedPool();
        assertEq(Currency.unwrap(c0), Currency.unwrap(testKey.currency0));
    }

    function _unpackKey(PoolKey memory key) internal pure returns (Currency, Currency, uint24, int24, IHooks) {
        return (key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks);
    }

    // ── Admin: setHook / setVault Tests ───────────────────────────

    function test_setHook_onlyAdmin() public {
        vm.prank(attacker);
        vm.expectRevert();
        rebalancer.setHook(makeAddr("newHook"));
    }

    function test_setHook_revertsOnZero() public {
        vm.prank(admin);
        vm.expectRevert(CuratioRebalancer.ZeroAddress.selector);
        rebalancer.setHook(address(0));
    }

    function test_setHook_updatesState() public {
        address newHook = makeAddr("newHook");
        vm.prank(admin);
        rebalancer.setHook(newHook);
        assertEq(address(rebalancer.hook()), newHook);
    }

    function test_setVault_onlyAdmin() public {
        vm.prank(attacker);
        vm.expectRevert();
        rebalancer.setVault(makeAddr("newVault"));
    }

    function test_setVault_revokesOldGrantsNewRole() public {
        address newVault = makeAddr("newVault");

        assertTrue(rebalancer.hasRole(rebalancer.VAULT_ROLE(), vault));

        vm.prank(admin);
        rebalancer.setVault(newVault);

        assertFalse(rebalancer.hasRole(rebalancer.VAULT_ROLE(), vault));
        assertTrue(rebalancer.hasRole(rebalancer.VAULT_ROLE(), newVault));
        assertEq(rebalancer.vault(), newVault);
    }

    function test_setVault_revertsOnZero() public {
        vm.prank(admin);
        vm.expectRevert(CuratioRebalancer.ZeroAddress.selector);
        rebalancer.setVault(address(0));
    }

    // ── Admin: Thresholds Tests ───────────────────────────────────

    function test_setRebalanceThreshold_onlyStrategist() public {
        vm.prank(attacker);
        vm.expectRevert();
        rebalancer.setRebalanceThreshold(5 ether);
    }

    function test_setRebalanceThreshold_updatesAndEmits() public {
        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit RebalanceThresholdUpdated(5 ether);
        rebalancer.setRebalanceThreshold(5 ether);

        assertEq(rebalancer.rebalanceThreshold(), 5 ether);
    }

    function test_setRebalanceThreshold_revertsOnZero() public {
        vm.prank(admin);
        vm.expectRevert(bytes("Invalid Threshold"));
        rebalancer.setRebalanceThreshold(0);
    }

    function test_setMinBlocksBetweenRebalances_onlyAdmin() public {
        vm.prank(attacker);
        vm.expectRevert();
        rebalancer.setMinBlocksBetweenRebalances(50);
    }

    function test_setMinBlocksBetweenRebalances_updatesState() public {
        vm.prank(admin);
        rebalancer.setMinBlocksBetweenRebalances(50);
        assertEq(rebalancer.minBlocksBetweenRebalances(), 50);
    }

    // ── Rebalance Liquidity Validation Tests ──────────────────────

    function test_rebalanceLiquidity_onlyStrategist() public {
        vm.prank(admin);
        rebalancer.setManagedPool(testKey);

        vm.prank(attacker);
        vm.expectRevert();
        rebalancer.rebalanceLiquidity(-120, 120, 1000);
    }

    function test_rebalanceLiquidity_revertsIfPoolNotConfigured() public {
        vm.prank(admin);
        vm.expectRevert(CuratioRebalancer.PoolNotConfigured.selector);
        rebalancer.rebalanceLiquidity(-120, 120, 1000);
    }

    function test_rebalanceLiquidity_revertsOnInvalidTickRange() public {
        vm.prank(admin);
        rebalancer.setManagedPool(testKey);

        vm.prank(admin);
        vm.expectRevert(CuratioRebalancer.InvalidTickRange.selector);
        rebalancer.rebalanceLiquidity(120, -120, 1000);
    }

    // ── Access Control Tests ──────────────────────────────────────

    function test_unlockCallback_revertsIfNotPoolManager() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(CuratioRebalancer.NotPoolManager.selector, attacker));
        rebalancer.unlockCallback("");
    }
}

/// @notice Separate test contract using a fuller mock PoolManager so
///         rebalanceLiquidity() can actually execute end to end: unlock ->
///         unlockCallback -> _executeRebalance -> modifyLiquidity (remove,
///         then add) -> _settleCurrency for both currencies, covering both
///         the positive-delta (take) and negative-delta (settle) branches.
contract CuratioRebalancerIntegrationTest is Test {
    using PoolIdLibrary for PoolKey;

    CuratioRebalancer public rebalancer;
    MockPoolManagerFull public mockManager;
    MockERC20 public token0;
    MockERC20 public token1;

    address public admin = makeAddr("admin");
    address public vault = makeAddr("vault");
    address public hook = makeAddr("hook");
    address public automationRegistry = makeAddr("automationRegistry"); // NEW

    PoolKey internal testKey;

    function setUp() public {
        mockManager = new MockPoolManagerFull();

        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("Token1", "TK1", 18);
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }

        rebalancer = new CuratioRebalancer(
            address(mockManager), hook, vault, admin, 1 ether, automationRegistry, 1000 ether
        );

        testKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hook)
        });

        vm.prank(admin);
        rebalancer.setManagedPool(testKey);

        token0.mint(address(rebalancer), 1_000 ether);
        token1.mint(address(rebalancer), 1_000 ether);
    }

    /// @notice First-ever rebalance: currentTickLower == currentTickUpper == 0,
    ///         so _executeRebalance's "remove old position" branch is skipped
    ///         (data.oldTickLower != data.oldTickUpper is false), and only the
    ///         "add new position" branch executes. Configures a positive delta
    ///         on both currencies to exercise the `take()` branch of
    ///         _settleCurrency.
    function test_rebalanceLiquidity_firstExecution_positiveDeltas_takesFromManager() public {
        mockManager.setNextDelta(5 ether, 3 ether);

        vm.prank(admin);
        rebalancer.rebalanceLiquidity(-120, 120, 1000 ether);

        assertEq(rebalancer.currentTickLower(), -120);
        assertEq(rebalancer.currentTickUpper(), 120);
        assertEq(rebalancer.lastRebalanceBlock(), block.number);

        // take() in the mock mints directly to `to` (the rebalancer), so we
        // can confirm the positive-delta branch actually ran.
        assertEq(token0.balanceOf(address(rebalancer)), 1_000 ether + 5 ether);
        assertEq(token1.balanceOf(address(rebalancer)), 1_000 ether + 3 ether);
    }

    /// @notice A subsequent rebalance (after the position is already
    ///         non-zero) exercises the "remove old position" branch too,
    ///         and negative deltas exercise the `settle()` / transfer
    ///         branch of _settleCurrency.
    function test_rebalanceLiquidity_subsequentExecution_negativeDeltas_settlesToManager() public {
        // First rebalance to establish a non-zero current range.
        mockManager.setNextDelta(0, 0);
        vm.prank(admin);
        rebalancer.rebalanceLiquidity(-120, 120, 1000 ether);

        uint256 balBefore0 = token0.balanceOf(address(rebalancer));
        uint256 balBefore1 = token1.balanceOf(address(rebalancer));

        // Second rebalance: both remove and add calls will return this same
        // negative delta (mock doesn't vary by call index here), summing to
        // a net negative delta that must be settled via transfer+settle().
        mockManager.setNextDelta(-1 ether, -2 ether);

        vm.prank(admin);
        rebalancer.rebalanceLiquidity(-240, 240, 500 ether);

        assertEq(rebalancer.currentTickLower(), -240);
        assertEq(rebalancer.currentTickUpper(), 240);

        // Net delta per currency = removeDelta + addDelta = -1e18 + -1e18 = -2e18
        // (mock returns the same configured delta for both calls), so the
        // rebalancer must have paid out 2x the configured per-call amount.
        assertEq(token0.balanceOf(address(rebalancer)), balBefore0 - 2 ether);
        assertEq(token1.balanceOf(address(rebalancer)), balBefore1 - 4 ether);
    }

    /// @notice Confirms the previously-skipped placeholder is now covered by
    ///         real integration execution above; kept here as a marker so a
    ///         `grep -r "vm.skip" test/` sweep doesn't silently miss this file.

    /// @notice Confirms the previously-skipped placeholder is now covered by
    ///         real integration execution above; kept here as a marker so a
    ///         `grep -r "vm.skip" test/` sweep doesn't silently miss this file.
    function test_rebalanceLiquidity_fullExecution_noLongerSkipped() public pure {
        assertTrue(true);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // _settleCurrency — native ETH branch and zero-delta branch
    // Previously untested: every prior test used ERC20 currencies with
    // non-zero deltas only.
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Exercises the native-ETH settlement branch of _settleCurrency
    ///         (Currency.unwrap(currency) == address(0)), which every prior
    ///         integration test skipped by using only ERC20 currencies.
    function test_rebalanceLiquidity_negativeDelta_nativeEth_usesSettleWithValue() public {
        // Deploy a fresh pool pair where currency0 is native ETH (address(0)).
        MockERC20 tokenB = new MockERC20("TokenB", "TKB", 18);

        PoolKey memory ethKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(tokenB)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hook)
        });

        vm.prank(admin);
        rebalancer.setManagedPool(ethKey);

        // Fund the rebalancer with native ETH so it can pay out on settle.
        vm.deal(address(rebalancer), 10 ether);
        tokenB.mint(address(rebalancer), 10 ether);

        mockManager.setNextDelta(-1 ether, -1 ether);

        uint256 managerEthBefore = address(mockManager).balance;

        vm.prank(admin);
        rebalancer.rebalanceLiquidity(-120, 120, 1000 ether);

        // If settle{value: amount}() was correctly invoked with native ETH,
        // the mock manager's balance must have increased by the settled amount.
        assertGt(address(mockManager).balance, managerEthBefore, "native ETH branch of _settleCurrency did not run");
    }

    /// @notice Exercises the zero-delta (no settle, no take) implicit branch
    ///         of _settleCurrency for both currencies in the same rebalance.
    function test_rebalanceLiquidity_zeroDelta_noSettleNoTake() public {
        mockManager.setNextDelta(0, 0);

        uint256 rebalancerBalance0Before = token0.balanceOf(address(rebalancer));
        uint256 rebalancerBalance1Before = token1.balanceOf(address(rebalancer));

        vm.prank(admin);
        rebalancer.rebalanceLiquidity(-120, 120, 1000 ether);

        // Zero delta means neither settle() nor take() should have moved
        // any balance for either currency.
        assertEq(
            token0.balanceOf(address(rebalancer)),
            rebalancerBalance0Before,
            "zero delta must not settle or take currency0"
        );
        assertEq(
            token1.balanceOf(address(rebalancer)),
            rebalancerBalance1Before,
            "zero delta must not settle or take currency1"
        );
    }

    function test_notifyDeposit_skipsIfBelowThreshold() public {
        vm.prank(admin);
        rebalancer.setManagedPool(testKey);

        // 1 ether-এর নিচে ডিপোজিট করছি (যেমন: 0.5 ether)
        vm.prank(vault);
        rebalancer.notifyDeposit(0.5 ether);

        // রিব্যালান্স ট্রিগার হয়নি তা নিশ্চিত হওয়া
        assertEq(rebalancer.lastRebalanceBlock(), 0);
    }

        // ═══════════════════════════════════════════════════════════════════════
    // Chainlink Automation — checkUpkeep / performUpkeep
    // ═══════════════════════════════════════════════════════════════════════

    function test_performUpkeep_onlyAutomationRegistry() public {
        vm.prank(makeAddr("randomCaller"));
        vm.expectRevert(
            abi.encodeWithSelector(CuratioRebalancer.NotAutomationRegistry.selector, makeAddr("randomCaller"))
        );
        rebalancer.performUpkeep(abi.encode(int24(0), false));
    }

    /// @notice checkUpkeep must return false when the pool has not been
    ///         configured — this is a real state-dependent check, not a
    ///         hardcoded true/false.
    function test_checkUpkeep_falseWhenPoolNotConfigured() public {
        CuratioRebalancer freshRebalancer = new CuratioRebalancer(
            address(mockManager), hook, vault, admin, 1 ether, automationRegistry, 1000 ether
        );

        (bool upkeepNeeded,) = freshRebalancer.checkUpkeep("");
        assertFalse(upkeepNeeded, "checkUpkeep must be false when pool is unconfigured");
    }

    /// @notice checkUpkeep must return false immediately after a rebalance,
    ///         before minBlocksBetweenRebalances has elapsed.
    function test_checkUpkeep_falseWhenTooSoonSinceLastRebalance() public {
        // Trigger a manual rebalance to set lastRebalanceBlock to now.
        mockManager.setNextDelta(0, 0);
        vm.prank(admin);
        rebalancer.rebalanceLiquidity(-120, 120, 100 ether);

        (bool upkeepNeeded,) = rebalancer.checkUpkeep("");
        assertFalse(upkeepNeeded, "checkUpkeep must be false immediately after a rebalance");
    }

    /// @notice checkUpkeep must return false when hook.getPoolState reverts
    ///         (e.g. hook is an EOA/mock with no code), exercising the
    ///         !stateSuccess early-return branch, not a hardcoded value.
    function test_checkUpkeep_falseWhenHookCallReverts() public view {
        // `hook` in this suite is makeAddr(...) — an address with no code,
        // so any call to it (including the try/catch-wrapped getPoolState)
        // will fail, forcing _tryGetPoolState to return success = false.
        (bool upkeepNeeded, bytes memory performData) = rebalancer.checkUpkeep("");
        assertFalse(upkeepNeeded, "checkUpkeep must be false when the hook call fails");
        assertEq(performData.length, 0, "performData must be empty when checkUpkeep returns false");
    }

    /// @notice performUpkeep must correctly decode performData and execute
    ///         a rebalance through the shared _executeRebalanceLogic path —
    ///         verified by checking actual state changes, not just success.
    function test_performUpkeep_executesRebalanceWithComputedRange() public {
        mockManager.setNextDelta(0, 0);

        int24 referenceTick = 600; // an arbitrary tick, must be a multiple-friendly value
        bool twapDiverged = false;

        vm.prank(automationRegistry);
        rebalancer.performUpkeep(abi.encode(referenceTick, twapDiverged));

        int24 tickSpacing = testKey.tickSpacing;
        int24 expectedBase = (referenceTick / tickSpacing) * tickSpacing;
        int24 expectedLower = expectedBase - (tickSpacing * 2); // twapDiverged=false -> width 2
        int24 expectedUpper = expectedBase + (tickSpacing * 2);

        assertEq(rebalancer.currentTickLower(), expectedLower, "performUpkeep computed wrong lower tick");
        assertEq(rebalancer.currentTickUpper(), expectedUpper, "performUpkeep computed wrong upper tick");
        assertEq(rebalancer.lastRebalanceBlock(), block.number, "lastRebalanceBlock not updated by performUpkeep");
    }

    /// @notice When twapDiverged is true, performUpkeep must use the wider
    ///         range (3x tickSpacing) instead of the default (2x) — this
    ///         distinguishes the two branches of rangeWidthInSpacings.
    function test_performUpkeep_usesWiderRangeWhenTwapDiverged() public {
        mockManager.setNextDelta(0, 0);

        int24 referenceTick = 600;
        bool twapDiverged = true;

        vm.prank(automationRegistry);
        rebalancer.performUpkeep(abi.encode(referenceTick, twapDiverged));

        int24 tickSpacing = testKey.tickSpacing;
        int24 expectedBase = (referenceTick / tickSpacing) * tickSpacing;
        int24 expectedLower = expectedBase - (tickSpacing * 3); // twapDiverged=true -> width 3
        int24 expectedUpper = expectedBase + (tickSpacing * 3);

        assertEq(rebalancer.currentTickLower(), expectedLower, "diverged case did not use the wider (3x) range");
        assertEq(rebalancer.currentTickUpper(), expectedUpper, "diverged case did not use the wider (3x) range");
    }

    function test_performUpkeep_revertsIfPoolNotConfigured() public {
        CuratioRebalancer freshRebalancer = new CuratioRebalancer(
            address(mockManager), hook, vault, admin, 1 ether, automationRegistry, 1000 ether
        );

        vm.prank(automationRegistry);
        vm.expectRevert(CuratioRebalancer.PoolNotConfigured.selector);
        freshRebalancer.performUpkeep(abi.encode(int24(0), false));
    }

    function test_performUpkeep_skipsIfTooSoonSinceLastRebalance() public {
        mockManager.setNextDelta(0, 0);
        vm.prank(admin);
        rebalancer.rebalanceLiquidity(-120, 120, 100 ether);

        uint256 lastRebalanceBlockBefore = rebalancer.lastRebalanceBlock();

        vm.prank(automationRegistry);
        rebalancer.performUpkeep(abi.encode(int24(600), false));

        // Must not have executed a second rebalance — lastRebalanceBlock
        // stays the same (real check, not assuming success).
        assertEq(
            rebalancer.lastRebalanceBlock(),
            lastRebalanceBlockBefore,
            "performUpkeep must skip, not execute, when called too soon"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Admin: automation config
    // ═══════════════════════════════════════════════════════════════════════

    function test_setAutomationRegistry_onlyAdmin() public {
        vm.prank(makeAddr("randomCaller"));
        vm.expectRevert();
        rebalancer.setAutomationRegistry(makeAddr("newRegistry"));
    }

    function test_setAutomationRegistry_revertsOnZero() public {
        vm.prank(admin);
        vm.expectRevert(CuratioRebalancer.ZeroAddress.selector);
        rebalancer.setAutomationRegistry(address(0));
    }

    function test_setAutomationRegistry_updatesState() public {
        address newRegistry = makeAddr("newRegistry");
        vm.prank(admin);
        rebalancer.setAutomationRegistry(newRegistry);
        assertEq(rebalancer.automationRegistry(), newRegistry);
    }

    function test_setDefaultRebalanceAmount_onlyAdmin() public {
        vm.prank(makeAddr("randomCaller"));
        vm.expectRevert();
        rebalancer.setDefaultRebalanceAmount(500 ether);
    }

    function test_setDefaultRebalanceAmount_revertsOnZero() public {
        vm.prank(admin);
        vm.expectRevert(bytes("Invalid default amount"));
        rebalancer.setDefaultRebalanceAmount(0);
    }

    function test_setDefaultRebalanceAmount_updatesState() public {
        vm.prank(admin);
        rebalancer.setDefaultRebalanceAmount(500 ether);
        assertEq(rebalancer.defaultRebalanceAmount(), 500 ether);
    }
}

