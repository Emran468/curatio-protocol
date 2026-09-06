// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {CuratioVault} from "../../src/CuratioVault.sol";
import {CuratioAccess} from "../../src/CuratioAccess.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "@uniswap/v4-core/lib/solmate/src/test/utils/mocks/MockERC20.sol";

/// @dev Configurable mock so we can exercise both the success path and the
///      try/catch non-blocking-failure path in CuratioVault's
///      _notifyRebalancerDeposit / _notifyRebalancerWithdraw.
contract MockRebalancer {
    bool public shouldRevert;
    uint256 public lastDepositNotified;
    uint256 public lastWithdrawNotified;
    uint256 public depositCallCount;
    uint256 public withdrawCallCount;

    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    function notifyDeposit(uint256 assets) external {
        if (shouldRevert) revert("MockRebalancer: forced revert");
        lastDepositNotified = assets;
        depositCallCount++;
    }

    function notifyWithdraw(uint256 assets) external {
        if (shouldRevert) revert("MockRebalancer: forced revert");
        lastWithdrawNotified = assets;
        withdrawCallCount++;
    }
}

contract CuratioVaultTest is Test {
    CuratioVault public vault;
    CuratioAccess public access;
    MockRebalancer public rebalancer;
    MockERC20 public asset;

    address public admin = makeAddr("admin");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public attacker = makeAddr("attacker");

    uint256 public constant DEPOSIT_CAP = 1_000 ether;

    event AccessControlUpdated(address indexed oldAccess, address indexed newAccess);
    event RebalancerUpdated(address indexed oldRebalancer, address indexed newRebalancer);
    event DepositCapUpdated(uint256 newCap);
    event DepositsPausedToggled(bool paused);

    function setUp() public {
        asset = new MockERC20("Test Asset", "TAST", 18);
        access = new CuratioAccess(admin);
        rebalancer = new MockRebalancer();

        vault = new CuratioVault(IERC20(address(asset)), address(access), address(rebalancer), admin, DEPOSIT_CAP);

        // Whitelist alice and bob for normal-path tests; attacker stays unwhitelisted.
        vm.startPrank(admin);
        access.setWhitelistedUser(alice, true);
        access.setWhitelistedUser(bob, true);
        vm.stopPrank();

        asset.mint(alice, 10_000 ether);
        asset.mint(bob, 10_000 ether);
        asset.mint(attacker, 10_000 ether);

        vm.prank(alice);
        asset.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        asset.approve(address(vault), type(uint256).max);
        vm.prank(attacker);
        asset.approve(address(vault), type(uint256).max);
    }

    // ── Constructor ──────────────────────────────────────────────

    function test_constructor_revertsOnZeroAccessControl() public {
        vm.expectRevert(CuratioVault.ZeroAddress.selector);
        new CuratioVault(IERC20(address(asset)), address(0), address(rebalancer), admin, DEPOSIT_CAP);
    }

    function test_constructor_revertsOnZeroRebalancer() public {
        vm.expectRevert(CuratioVault.ZeroAddress.selector);
        new CuratioVault(IERC20(address(asset)), address(access), address(0), admin, DEPOSIT_CAP);
    }

    function test_constructor_revertsOnZeroAdmin() public {
        vm.expectRevert(CuratioVault.ZeroAddress.selector);
        new CuratioVault(IERC20(address(asset)), address(access), address(rebalancer), address(0), DEPOSIT_CAP);
    }

    function test_constructor_setsInitialState() public view {
        assertEq(address(vault.accessControl()), address(access));
        assertEq(address(vault.rebalancer()), address(rebalancer));
        assertEq(vault.depositCap(), DEPOSIT_CAP);
        assertFalse(vault.depositsPaused());
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(vault.hasRole(vault.VAULT_MANAGER_ROLE(), admin));
        assertEq(vault.name(), "Curatio Vault Share");
        assertEq(vault.symbol(), "cVAULT");
    }

    // ── Deposit ──────────────────────────────────────────────────

    function test_deposit_revertsIfNotWhitelisted() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(CuratioVault.NotWhitelisted.selector, attacker));
        vault.deposit(100 ether, attacker);
    }

    function test_deposit_revertsIfPaused() public {
        vm.prank(admin);
        vault.setDepositsPaused(true);

        vm.prank(alice);
        vm.expectRevert(CuratioVault.DepositsArePaused.selector);
        vault.deposit(100 ether, alice);
    }

    function test_deposit_revertsIfCapExceeded() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(CuratioVault.DepositCapExceeded.selector, DEPOSIT_CAP + 1 ether, DEPOSIT_CAP)
        );
        vault.deposit(DEPOSIT_CAP + 1 ether, alice);
    }

    function test_deposit_succeedsAtExactCapBoundary() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(DEPOSIT_CAP, alice);

        assertGt(shares, 0);
        assertEq(vault.totalAssets(), DEPOSIT_CAP);
    }

    function test_deposit_succeedsWhenUncapped() public {
        vm.prank(admin);
        vault.setDepositCap(0); // 0 = uncapped

        vm.prank(alice);
        vault.deposit(DEPOSIT_CAP * 10, alice);

        assertEq(vault.totalAssets(), DEPOSIT_CAP * 10);
    }

    function test_deposit_notifiesRebalancer() public {
        vm.prank(alice);
        vault.deposit(100 ether, alice);

        assertEq(rebalancer.lastDepositNotified(), 100 ether);
        assertEq(rebalancer.depositCallCount(), 1);
    }

    function test_deposit_succeedsEvenIfRebalancerReverts() public {
        rebalancer.setShouldRevert(true);

        vm.prank(alice);
        uint256 shares = vault.deposit(100 ether, alice);

        // Deposit itself must not be blocked by the rebalancer's failure.
        assertGt(shares, 0);
        assertEq(vault.balanceOf(alice), shares);
        assertEq(rebalancer.depositCallCount(), 0); // reverted before incrementing
    }

    function test_deposit_mintsSharesToReceiverNotCaller() public {
        vm.prank(alice);
        vault.deposit(100 ether, bob);

        assertEq(vault.balanceOf(bob), vault.balanceOf(bob)); // sanity: bob has shares
        assertGt(vault.balanceOf(bob), 0);
        assertEq(vault.balanceOf(alice), 0);
    }

    // ── Mint ─────────────────────────────────────────────────────

    function test_mint_revertsIfNotWhitelisted() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(CuratioVault.NotWhitelisted.selector, attacker));
        vault.mint(100 ether, attacker);
    }

    function test_mint_revertsIfPaused() public {
        vm.prank(admin);
        vault.setDepositsPaused(true);

        vm.prank(alice);
        vm.expectRevert(CuratioVault.DepositsArePaused.selector);
        vault.mint(100 ether, alice);
    }

    function test_mint_revertsIfCapExceeded() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(CuratioVault.DepositCapExceeded.selector, DEPOSIT_CAP + 1 ether, DEPOSIT_CAP)
        );
        vault.mint(DEPOSIT_CAP + 1 ether, alice);
    }

    function test_mint_succeedsAndNotifiesRebalancer() public {
        vm.prank(alice);
        uint256 assets = vault.mint(100 ether, alice);

        assertGt(assets, 0);
        assertEq(rebalancer.lastDepositNotified(), assets);
    }

    function test_mint_succeedsEvenIfRebalancerReverts() public {
        rebalancer.setShouldRevert(true);

        vm.prank(alice);
        uint256 assets = vault.mint(100 ether, alice);

        assertGt(assets, 0);
        assertEq(vault.balanceOf(alice), 100 ether);
    }

    // ── Withdraw ─────────────────────────────────────────────────

    function test_withdraw_revertsIfNotWhitelisted() public {
        vm.prank(alice);
        vault.deposit(100 ether, alice);

        // Revoke alice's whitelist status after she has already deposited,
        // to isolate the withdraw-path whitelist check.
        vm.prank(admin);
        access.setWhitelistedUser(alice, false);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CuratioVault.NotWhitelisted.selector, alice));
        vault.withdraw(50 ether, alice, alice);
    }

    function test_withdraw_succeedsAndNotifiesRebalancer() public {
        vm.prank(alice);
        vault.deposit(100 ether, alice);

        vm.prank(alice);
        uint256 shares = vault.withdraw(40 ether, alice, alice);

        assertGt(shares, 0);
        assertEq(rebalancer.lastWithdrawNotified(), 40 ether);
    }

    function test_withdraw_succeedsEvenIfRebalancerReverts() public {
        vm.prank(alice);
        vault.deposit(100 ether, alice);

        rebalancer.setShouldRevert(true);

        vm.prank(alice);
        uint256 shares = vault.withdraw(40 ether, alice, alice);

        assertGt(shares, 0);
        assertEq(asset.balanceOf(alice), 10_000 ether - 100 ether + 40 ether);
    }

    function test_withdraw_worksEvenWhenPaused() public {
        // NOTE: withdraw() intentionally does not call _checkNotPaused() —
        // pausing only blocks new deposits, not exits. This test documents
        // and locks in that behavior.
        vm.prank(alice);
        vault.deposit(100 ether, alice);

        vm.prank(admin);
        vault.setDepositsPaused(true);

        vm.prank(alice);
        uint256 shares = vault.withdraw(40 ether, alice, alice);
        assertGt(shares, 0);
    }

    // ── Redeem ───────────────────────────────────────────────────

    function test_redeem_revertsIfNotWhitelisted() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(100 ether, alice);

        vm.prank(admin);
        access.setWhitelistedUser(alice, false);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CuratioVault.NotWhitelisted.selector, alice));
        vault.redeem(shares, alice, alice);
    }

    function test_redeem_succeedsAndNotifiesRebalancer() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(100 ether, alice);

        vm.prank(alice);
        uint256 assets = vault.redeem(shares, alice, alice);

        assertGt(assets, 0);
        assertEq(rebalancer.lastWithdrawNotified(), assets);
    }

    // ── Admin: setAccessControl ────────────────────────────────────

    function test_setAccessControl_onlyDefaultAdmin() public {
        vm.prank(attacker);
        vm.expectRevert();
        vault.setAccessControl(makeAddr("newAccess"));
    }

    function test_setAccessControl_revertsOnZero() public {
        vm.prank(admin);
        vm.expectRevert(CuratioVault.ZeroAddress.selector);
        vault.setAccessControl(address(0));
    }

    function test_setAccessControl_updatesStateAndEmits() public {
        CuratioAccess newAccess = new CuratioAccess(admin);

        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit AccessControlUpdated(address(access), address(newAccess));
        vault.setAccessControl(address(newAccess));

        assertEq(address(vault.accessControl()), address(newAccess));
    }

    // ── Admin: setRebalancer ────────────────────────────────────────

    function test_setRebalancer_onlyDefaultAdmin() public {
        vm.prank(attacker);
        vm.expectRevert();
        vault.setRebalancer(makeAddr("newRebalancer"));
    }

    function test_setRebalancer_revertsOnZero() public {
        vm.prank(admin);
        vm.expectRevert(CuratioVault.ZeroAddress.selector);
        vault.setRebalancer(address(0));
    }

    function test_setRebalancer_updatesStateAndEmits() public {
        MockRebalancer newRebalancer = new MockRebalancer();

        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit RebalancerUpdated(address(rebalancer), address(newRebalancer));
        vault.setRebalancer(address(newRebalancer));

        assertEq(address(vault.rebalancer()), address(newRebalancer));
    }

    // ── Admin: setDepositCap ────────────────────────────────────────

    function test_setDepositCap_onlyVaultManagerRole() public {
        vm.prank(attacker);
        vm.expectRevert();
        vault.setDepositCap(500 ether);
    }

    function test_setDepositCap_updatesStateAndEmits() public {
        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit DepositCapUpdated(500 ether);
        vault.setDepositCap(500 ether);

        assertEq(vault.depositCap(), 500 ether);
    }

    // ── Admin: setDepositsPaused ──────────────────────────────────

    function test_setDepositsPaused_onlyVaultManagerRole() public {
        vm.prank(attacker);
        vm.expectRevert();
        vault.setDepositsPaused(true);
    }

    function test_setDepositsPaused_updatesStateAndEmits() public {
        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit DepositsPausedToggled(true);
        vault.setDepositsPaused(true);

        assertTrue(vault.depositsPaused());
    }

    function test_setDepositsPaused_canBeUnpaused() public {
        vm.startPrank(admin);
        vault.setDepositsPaused(true);
        vault.setDepositsPaused(false);
        vm.stopPrank();

        assertFalse(vault.depositsPaused());

        vm.prank(alice);
        uint256 shares = vault.deposit(100 ether, alice);
        assertGt(shares, 0);
    }
}
