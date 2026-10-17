// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {CuratioVault} from "../../src/CuratioVault.sol";
import {CuratioAccess} from "../../src/CuratioAccess.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "@uniswap/v4-core/lib/solmate/src/test/utils/mocks/MockERC20.sol";

/// @dev Configurable mock rebalancer. Covers:
///      - notify success / failure (try/catch non-blocking path in the vault)
///      - valuation (`totalManagedAssets`) which is deliberately NOT affected by `shouldRevert`,
///        because Vault.totalAssets() depends on it; use `shouldRevertOnValuation` to test that
///      - `returnToVault`, which pays out of the mock's own token balance.
contract MockRebalancer {
    bool public shouldRevert;
    bool public shouldRevertOnValuation;
    uint256 public lastDepositNotified;
    uint256 public lastWithdrawNotified;
    uint256 public depositCallCount;
    uint256 public withdrawCallCount;

    uint256 public managedAssets;
    address public returnToken;
    uint256 public returnCallCount;
    uint256 public lastReturnRequested;

    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    function setShouldRevertOnValuation(bool v) external {
        shouldRevertOnValuation = v;
    }

    function setManagedAssets(uint256 v) external {
        managedAssets = v;
    }

    function setReturnToken(address t) external {
        returnToken = t;
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

    function totalManagedAssets() external view returns (uint256) {
        if (shouldRevertOnValuation) revert("MockRebalancer: valuation unavailable");
        return managedAssets;
    }

    function returnToVault(uint256 amount) external {
        returnCallCount++;
        lastReturnRequested = amount;
        IERC20(returnToken).transfer(msg.sender, amount);
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
    event FundsDeployed(uint256 amount);
    event RebalancerNotifyFailed(bool isDeposit, uint256 assets);

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

    function test_deposit_revertsIfReceiverNotWhitelisted() public {
        vm.prank(alice);
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

    function test_deposit_emitsEventWhenRebalancerNotifyFails() public {
        rebalancer.setShouldRevert(true);

        vm.expectEmit(true, true, true, true);
        emit RebalancerNotifyFailed(true, 100 ether);

        vm.prank(alice);
        vault.deposit(100 ether, alice);
    }

    function test_deposit_mintsSharesToReceiverNotCaller() public {
        vm.prank(alice);
        vault.deposit(100 ether, bob);

        assertEq(vault.balanceOf(bob), 100 ether);
        assertEq(vault.balanceOf(alice), 0);
    }

    // ── Mint ─────────────────────────────────────────────────────

    function test_mint_revertsIfNotWhitelisted() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(CuratioVault.NotWhitelisted.selector, attacker));
        vault.mint(100 ether, attacker);
    }

    function test_mint_revertsIfReceiverNotWhitelisted() public {
        vm.prank(alice);
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

    function test_withdraw_revertsIfReceiverNotWhitelisted() public {
        vm.prank(alice);
        vault.deposit(100 ether, alice);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CuratioVault.NotWhitelisted.selector, attacker));
        vault.withdraw(50 ether, attacker, alice);
    }

    function test_withdraw_revertsIfOwnerNotWhitelisted() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CuratioVault.NotWhitelisted.selector, attacker));
        vault.withdraw(1 ether, alice, attacker);
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

    function test_redeem_revertsIfReceiverNotWhitelisted() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(100 ether, alice);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CuratioVault.NotWhitelisted.selector, attacker));
        vault.redeem(shares, attacker, alice);
    }

    function test_redeem_succeedsAndNotifiesRebalancer() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(100 ether, alice);

        vm.prank(alice);
        uint256 assets = vault.redeem(shares, alice, alice);

        assertGt(assets, 0);
        assertEq(rebalancer.lastWithdrawNotified(), assets);
    }

    // ── totalAssets / valuation ──────────────────────────────────

    function test_totalAssets_includesRebalancerHoldings() public {
        vm.prank(alice);
        vault.deposit(100 ether, alice);
        assertEq(vault.totalAssets(), 100 ether);

        rebalancer.setManagedAssets(500 ether);
        assertEq(vault.totalAssets(), 600 ether);
    }

    function test_totalAssets_revertsWhenValuationUnavailable() public {
        rebalancer.setShouldRevertOnValuation(true);

        vm.expectRevert(bytes("MockRebalancer: valuation unavailable"));
        vault.totalAssets();
    }

    function test_deposit_haltsWhenValuationUnavailable() public {
        // Strict valuation: no price, no deposit (never mint shares at a wrong price).
        rebalancer.setShouldRevertOnValuation(true);

        vm.prank(alice);
        vm.expectRevert(bytes("MockRebalancer: valuation unavailable"));
        vault.deposit(100 ether, alice);
    }

    function test_deposit_capCountsRebalancerHoldings() public {
        rebalancer.setManagedAssets(900 ether);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CuratioVault.DepositCapExceeded.selector, 1_001 ether, DEPOSIT_CAP));
        vault.deposit(101 ether, alice);
    }

    // ── ERC-4626 limits ──────────────────────────────────────────

    function test_maxDeposit_reflectsCapAndExistingAssets() public {
        assertEq(vault.maxDeposit(alice), DEPOSIT_CAP);

        vm.prank(alice);
        vault.deposit(300 ether, alice);
        assertEq(vault.maxDeposit(alice), 700 ether);

        rebalancer.setManagedAssets(700 ether); // total now 1000 = cap
        assertEq(vault.maxDeposit(alice), 0);
    }

    function test_maxDeposit_isMaxWhenUncapped() public {
        vm.prank(admin);
        vault.setDepositCap(0);
        assertEq(vault.maxDeposit(alice), type(uint256).max);
        assertEq(vault.maxMint(alice), type(uint256).max);
    }

    function test_maxDepositAndMint_zeroWhenPaused() public {
        vm.prank(admin);
        vault.setDepositsPaused(true);
        assertEq(vault.maxDeposit(alice), 0);
        assertEq(vault.maxMint(alice), 0);
    }

    function test_maxMint_matchesRemainingCapacity() public {
        vm.prank(alice);
        vault.deposit(300 ether, alice);
        assertEq(vault.maxMint(alice), 700 ether); // 1:1 pricing
    }

    // ── deployToRebalancer / withdraw pulls from rebalancer ──────

    function test_deployToRebalancer_onlyVaultManagerRole() public {
        vm.prank(alice);
        vault.deposit(100 ether, alice);

        vm.prank(attacker);
        vm.expectRevert();
        vault.deployToRebalancer(10 ether);
    }

    function test_deployToRebalancer_revertsOnZeroAmount() public {
        vm.prank(admin);
        vm.expectRevert(CuratioVault.ZeroAmount.selector);
        vault.deployToRebalancer(0);
    }

    function test_deployToRebalancer_movesAssetsAndKeepsSharePrice() public {
        vm.prank(alice);
        vault.deposit(100 ether, alice);
        uint256 priceBefore = vault.convertToAssets(1 ether);

        vm.expectEmit(true, true, true, true);
        emit FundsDeployed(100 ether);
        vm.prank(admin);
        vault.deployToRebalancer(100 ether);

        // the rebalancer now reports what it holds, as the real one does
        rebalancer.setManagedAssets(100 ether);

        assertEq(asset.balanceOf(address(vault)), 0);
        assertEq(asset.balanceOf(address(rebalancer)), 100 ether);
        assertEq(vault.totalAssets(), 100 ether);
        assertEq(vault.convertToAssets(1 ether), priceBefore, "share price must not move");
    }

    function test_withdraw_pullsShortfallFromRebalancer() public {
        vm.prank(alice);
        vault.deposit(100 ether, alice);

        vm.prank(admin);
        vault.deployToRebalancer(100 ether);
        rebalancer.setManagedAssets(100 ether);
        rebalancer.setReturnToken(address(asset));

        uint256 aliceBefore = asset.balanceOf(alice);
        vm.prank(alice);
        vault.withdraw(40 ether, alice, alice);

        assertEq(rebalancer.returnCallCount(), 1);
        assertEq(rebalancer.lastReturnRequested(), 40 ether); // vault idle was 0
        assertEq(asset.balanceOf(alice), aliceBefore + 40 ether);
        assertEq(asset.balanceOf(address(rebalancer)), 60 ether);
    }

    function test_withdraw_doesNotPullWhenVaultHasEnoughIdle() public {
        vm.prank(alice);
        vault.deposit(100 ether, alice);
        rebalancer.setReturnToken(address(asset));

        vm.prank(alice);
        vault.withdraw(40 ether, alice, alice);

        assertEq(rebalancer.returnCallCount(), 0);
    }

    function test_withdraw_revertsWhenRebalancerCannotReturnFunds() public {
        vm.prank(alice);
        vault.deposit(100 ether, alice);

        vm.prank(admin);
        vault.deployToRebalancer(100 ether);
        rebalancer.setManagedAssets(100 ether);
        rebalancer.setReturnToken(address(asset));

        // 100 ether is held by the rebalancer, asking for more than it can pay must revert
        vm.prank(alice);
        vm.expectRevert();
        vault.withdraw(101 ether, alice, alice);
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
