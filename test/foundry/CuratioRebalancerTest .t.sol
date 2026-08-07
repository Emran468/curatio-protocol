// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console, Vm} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {CuratioRebalancer} from "../../src/CuratioRebalancer.sol";

// Uniswap v4 official Test ERC20 token import
import {TestERC20} from "@uniswap/v4-core/src/test/TestERC20.sol";

/// @dev Minimal mock so we can test onlyPoolManager gating and unlock-triggered
///      calls without deploying the full real PoolManager. NOT a substitute for
///      integration testing against the real PoolManager before mainnet.
contract MockPoolManager {
    function unlock(bytes calldata data) external returns (bytes memory) {
        return CuratioRebalancer(msg.sender == address(this) ? address(0) : payable(msg.sender)).unlockCallback(data);
    }
}

contract CuratioRebalancerTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    CuratioRebalancer public rebalancer;

    address public admin = makeAddr("admin");
    address public strategist = makeAddr("strategist"); // will be granted role in setUp
    address public vault = makeAddr("vault");
    address public hook = makeAddr("hook");
    address public poolManager = makeAddr("poolManager"); // mocked as EOA-like for access tests
    address public attacker = makeAddr("attacker");

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
            1 ether // rebalanceThreshold
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
        assertTrue(rebalancer.hasRole(rebalancer.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(rebalancer.hasRole(rebalancer.STRATEGIST_ROLE(), admin));
        assertTrue(rebalancer.hasRole(rebalancer.VAULT_ROLE(), vault));
    }

    function test_constructor_revertsOnZeroPoolManager() public {
        vm.expectRevert(CuratioRebalancer.ZeroAddress.selector);
        new CuratioRebalancer(address(0), hook, vault, admin, 1 ether);
    }

    function test_constructor_revertsOnZeroHook() public {
        vm.expectRevert(CuratioRebalancer.ZeroAddress.selector);
        new CuratioRebalancer(poolManager, address(0), vault, admin, 1 ether);
    }

    function test_constructor_revertsOnZeroVault() public {
        vm.expectRevert(CuratioRebalancer.ZeroAddress.selector);
        new CuratioRebalancer(poolManager, hook, address(0), admin, 1 ether);
    }

    function test_constructor_revertsOnZeroAdmin() public {
        vm.expectRevert(CuratioRebalancer.ZeroAddress.selector);
        new CuratioRebalancer(poolManager, hook, vault, address(0), 1 ether);
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

        (Currency c0,,,, ) = rebalancer.managedPool();
        assertEq(Currency.unwrap(c0), Currency.unwrap(testKey.currency0));
    }

    function _unpackKey(PoolKey memory key)
        internal
        pure
        returns (Currency, Currency, uint24, int24, IHooks)
    {
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

    // ── Integration Placeholders ──────────────────────────────────

    function test_rebalanceLiquidity_fullExecution_requiresIntegrationSetup() public {
        vm.skip(true);
    }
}