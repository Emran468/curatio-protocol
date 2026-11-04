// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {CuratioVault} from "../../src/CuratioVault.sol";
import {CuratioAccess} from "../../src/CuratioAccess.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "@uniswap/v4-core/lib/solmate/src/test/utils/mocks/MockERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @dev Configurable mock rebalancer. Covers:
///      - notify success / failure (try/catch non-blocking path in the vault)
///      - valuation (`totalManagedAssets`) which is deliberately NOT affected by `shouldRevert`,
///        because Vault.totalAssets() depends on it; use `shouldRevertOnValuation` to test that
///      - `returnToVault`, which pays out of the mock's own token balance.
// contract MockRebalancer {
//     bool public shouldRevert;
//     bool public shouldRevertOnValuation;
//     uint256 public lastDepositNotified;
//     uint256 public lastWithdrawNotified;
//     uint256 public depositCallCount;
//     uint256 public withdrawCallCount;

//     uint256 public managedAssets;
//     address public returnToken;
//     uint256 public returnCallCount;
//     uint256 public lastReturnRequested;

//     function setShouldRevert(bool _shouldRevert) external {
//         shouldRevert = _shouldRevert;
//     }

//     function setShouldRevertOnValuation(bool v) external {
//         shouldRevertOnValuation = v;
//     }

//     function setManagedAssets(uint256 v) external {
//         managedAssets = v;
//     }

//     function setReturnToken(address t) external {
//         returnToken = t;
//     }

//     function notifyDeposit(uint256 assets) external {
//         if (shouldRevert) revert("MockRebalancer: forced revert");
//         lastDepositNotified = assets;
//         depositCallCount++;
//     }

//     function notifyWithdraw(uint256 assets) external {
//         if (shouldRevert) revert("MockRebalancer: forced revert");
//         lastWithdrawNotified = assets;
//         withdrawCallCount++;
//     }

//     function totalManagedAssets() external view returns (uint256) {
//         if (shouldRevertOnValuation) revert("MockRebalancer: valuation unavailable");
//         return managedAssets;
//     }

//     function returnToVault(uint256 amount) external {
//         returnCallCount++;
//         lastReturnRequested = amount;
//         IERC20(returnToken).transfer(msg.sender, amount);
//     }
// }

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

    // ✅ নতুন ভেরিয়েবল (টেস্টের জন্য)
    address public strategistRegistry;

    // ✅ নতুন ফাংশন (টেস্টের জন্য)
    function setStrategistRegistry(address r) external {
        strategistRegistry = r;
    }

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
    uint256 constant SCALE = 1e6; // = 10 ** _decimalsOffset() in CuratioVault

    address public admin = makeAddr("admin");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public attacker = makeAddr("attacker");
    address public strategist = makeAddr("strategist");

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

        assertEq(vault.balanceOf(bob), 100 ether * SCALE);
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
        // mint() takes SHARES. Scale so the request is worth DEPOSIT_CAP + 1 ether of assets.
        uint256 shares = (DEPOSIT_CAP + 1 ether) * SCALE;

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(CuratioVault.DepositCapExceeded.selector, DEPOSIT_CAP + 1 ether, DEPOSIT_CAP)
        );
        vault.mint(shares, alice);
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
        // 1. Alice deposits while whitelisted
        vm.prank(alice);
        uint256 shares = vault.deposit(100 ether, alice);
        assertGt(shares, 0, "deposit must mint shares");

        // 2. Admin PROPOSES removal (not immediate)
        vm.prank(admin);
        access.proposeRemoval(alice);

        // 3. Withdraw is NOT yet blocked — removal is only pending.
        //    Guards against silently breaking the timelock.
        vm.prank(alice);
        uint256 out = vault.withdraw(10 ether, alice, alice);
        assertGt(out, 0, "withdraw must succeed while removal is pending");

        // 4. Warp past the timelock and execute removal
        vm.warp(block.timestamp + access.REMOVAL_TIMELOCK());
        vm.prank(admin);
        access.executeRemoval(alice);

        // 5. NOW withdraw must revert with NotWhitelisted
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CuratioVault.NotWhitelisted.selector, alice));
        vault.withdraw(10 ether, alice, alice);
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
        // 1. Alice deposits while whitelisted
        vm.prank(alice);
        uint256 shares = vault.deposit(100 ether, alice);
        assertGt(shares, 0, "deposit must mint shares");

        // 2. Admin PROPOSES removal (not immediate)
        vm.prank(admin);
        access.proposeRemoval(alice);

        // 3. Removal is NOT yet effective — redeem must still work
        //    (this guards against silently breaking the timelock)
        vm.prank(alice);
        uint256 out = vault.redeem(shares / 2, alice, alice);
        assertGt(out, 0, "redeem must succeed while removal is pending");

        // 4. Warp past the timelock and execute removal
        vm.warp(block.timestamp + access.REMOVAL_TIMELOCK());
        vm.prank(admin);
        access.executeRemoval(alice);

        // 5. NOW redeem must revert with NotWhitelisted
        uint256 remainingShares = vault.balanceOf(alice);
        assertGt(remainingShares, 0, "alice must still hold shares to redeem");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CuratioVault.NotWhitelisted.selector, alice));
        vault.redeem(remainingShares, alice, alice);
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

        // remaining capacity is 700 ether of assets; shares are scaled by 10 ** _decimalsOffset()
        assertEq(vault.maxMint(alice), 700 ether * SCALE);
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

    // ── Admin: access-contract timelock ──────────────────────────────

    function test_proposeAccessControl_onlyDefaultAdmin() public {
        vm.prank(attacker);
        vm.expectRevert();
        vault.proposeAccessControl(makeAddr("newAccess"));
    }

    function test_proposeAccessControl_revertsOnZero() public {
        vm.prank(admin);
        vm.expectRevert(CuratioVault.ZeroAddress.selector);
        vault.proposeAccessControl(address(0));
    }

    function test_proposeAccessControl_setsPendingAndEmits() public {
        address newAccess = makeAddr("newAccess");
        uint256 expectedEta = block.timestamp + vault.ADMIN_TIMELOCK();

        vm.expectEmit(true, false, false, true, address(vault));
        emit CuratioVault.AccessControlProposed(newAccess, expectedEta);

        vm.prank(admin);
        vault.proposeAccessControl(newAccess);

        assertEq(vault.pendingAccessControl(), newAccess);
        assertEq(vault.pendingAccessControlEta(), expectedEta);
        assertEq(address(vault.accessControl()), address(access), "must not change on propose");
    }

    function test_executeAccessControl_revertsWithNoProposal() public {
        vm.prank(admin);
        vm.expectRevert(CuratioVault.NoPendingProposal.selector);
        vault.executeAccessControl();
    }

    function test_executeAccessControl_revertsBeforeTimelock() public {
        address newAccess = address(new CuratioAccess(admin));

        vm.prank(admin);
        vault.proposeAccessControl(newAccess);
        uint256 eta = vault.pendingAccessControlEta();

        vm.warp(eta - 1);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CuratioVault.TimelockNotElapsed.selector, eta));
        vault.executeAccessControl();

        assertEq(address(vault.accessControl()), address(access), "must not change early");
        assertEq(vault.pendingAccessControl(), newAccess, "proposal must survive a failed execute");
    }

    /// Boundary: the check is `block.timestamp < eta`, so executing exactly at eta must work.
    function test_executeAccessControl_succeedsExactlyAtEta() public {
        address newAccess = address(new CuratioAccess(admin));

        vm.prank(admin);
        vault.proposeAccessControl(newAccess);

        vm.warp(vault.pendingAccessControlEta());
        vm.prank(admin);
        vault.executeAccessControl();

        assertEq(address(vault.accessControl()), newAccess);
    }

    function test_executeAccessControl_updatesStateAndEmits() public {
        address newAccess = address(new CuratioAccess(admin));

        vm.startPrank(admin);
        vault.proposeAccessControl(newAccess);
        vm.warp(block.timestamp + vault.ADMIN_TIMELOCK() + 1);

        vm.expectEmit(true, true, false, false, address(vault));
        emit AccessControlUpdated(address(access), newAccess);
        vault.executeAccessControl();
        vm.stopPrank();

        assertEq(address(vault.accessControl()), newAccess);
        assertEq(vault.pendingAccessControl(), address(0), "pending must be cleared");
        assertEq(vault.pendingAccessControlEta(), 0, "eta must be cleared");
    }

    function test_executeAccessControl_onlyDefaultAdmin() public {
        address newAccess = address(new CuratioAccess(admin));

        vm.prank(admin);
        vault.proposeAccessControl(newAccess);
        vm.warp(block.timestamp + vault.ADMIN_TIMELOCK());

        vm.prank(attacker);
        vm.expectRevert();
        vault.executeAccessControl();

        assertEq(address(vault.accessControl()), address(access), "attacker must not apply the change");
    }

    function test_executeAccessControl_cannotBeReplayed() public {
        address newAccess = address(new CuratioAccess(admin));

        vm.startPrank(admin);
        vault.proposeAccessControl(newAccess);
        vm.warp(block.timestamp + vault.ADMIN_TIMELOCK());
        vault.executeAccessControl();

        vm.expectRevert(CuratioVault.NoPendingProposal.selector);
        vault.executeAccessControl();
        vm.stopPrank();
    }

    function test_cancelAccessControl_clearsPending() public {
        vm.startPrank(admin);
        vault.proposeAccessControl(makeAddr("newAccess"));
        vault.cancelAccessControl();
        vm.stopPrank();

        assertEq(vault.pendingAccessControl(), address(0));
        assertEq(vault.pendingAccessControlEta(), 0);

        // a cancelled proposal can never be executed, even after the delay
        vm.warp(block.timestamp + vault.ADMIN_TIMELOCK() + 1);
        vm.prank(admin);
        vm.expectRevert(CuratioVault.NoPendingProposal.selector);
        vault.executeAccessControl();
    }

    function test_cancelAccessControl_revertsWithNoProposal() public {
        vm.prank(admin);
        vm.expectRevert(CuratioVault.NoPendingProposal.selector);
        vault.cancelAccessControl();
    }

    function test_cancelAccessControl_onlyDefaultAdmin() public {
        vm.prank(admin);
        vault.proposeAccessControl(makeAddr("newAccess"));

        vm.prank(attacker);
        vm.expectRevert();
        vault.cancelAccessControl();

        assertTrue(vault.pendingAccessControl() != address(0), "attacker must not cancel");
    }

    // ── Admin: rebalancer timelock ───────────────────────────────────

    function test_proposeRebalancer_onlyDefaultAdmin() public {
        vm.prank(attacker);
        vm.expectRevert();
        vault.proposeRebalancer(makeAddr("newRebalancer"));
    }

    function test_proposeRebalancer_revertsOnZero() public {
        vm.prank(admin);
        vm.expectRevert(CuratioVault.ZeroAddress.selector);
        vault.proposeRebalancer(address(0));
    }

    function test_proposeRebalancer_setsPendingAndEmits() public {
        address newReb = makeAddr("newRebalancer");
        uint256 expectedEta = block.timestamp + vault.ADMIN_TIMELOCK();

        vm.expectEmit(true, false, false, true, address(vault));
        emit CuratioVault.RebalancerProposed(newReb, expectedEta);

        vm.prank(admin);
        vault.proposeRebalancer(newReb);

        assertEq(vault.pendingRebalancer(), newReb);
        assertEq(vault.pendingRebalancerEta(), expectedEta);
        assertEq(address(vault.rebalancer()), address(rebalancer), "must not change on propose");
    }

    function test_proposeRebalancer_secondProposalOverwritesAndRestartsTimelock() public {
        address first = makeAddr("firstReb");
        address second = makeAddr("secondReb");

        vm.prank(admin);
        vault.proposeRebalancer(first);
        vm.warp(block.timestamp + 1 days);

        vm.prank(admin);
        vault.proposeRebalancer(second);

        assertEq(vault.pendingRebalancer(), second);
        assertEq(vault.pendingRebalancerEta(), block.timestamp + vault.ADMIN_TIMELOCK());
    }

    function test_executeRebalancer_revertsWithNoProposal() public {
        vm.prank(admin);
        vm.expectRevert(CuratioVault.NoPendingProposal.selector);
        vault.executeRebalancer();
    }

    function test_executeRebalancer_revertsBeforeTimelock() public {
        MockRebalancer newReb = new MockRebalancer();

        vm.prank(admin);
        vault.proposeRebalancer(address(newReb));
        uint256 eta = vault.pendingRebalancerEta();

        vm.warp(eta - 1);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CuratioVault.TimelockNotElapsed.selector, eta));
        vault.executeRebalancer();

        assertEq(address(vault.rebalancer()), address(rebalancer), "must not change early");
        assertEq(vault.pendingRebalancer(), address(newReb), "proposal must survive a failed execute");
    }

    function test_executeRebalancer_succeedsExactlyAtEta() public {
        MockRebalancer newReb = new MockRebalancer();

        vm.prank(admin);
        vault.proposeRebalancer(address(newReb));

        vm.warp(vault.pendingRebalancerEta());
        vm.prank(admin);
        vault.executeRebalancer();

        assertEq(address(vault.rebalancer()), address(newReb));
    }

    function test_executeRebalancer_updatesStateAndEmits() public {
        MockRebalancer newReb = new MockRebalancer();

        vm.startPrank(admin);
        vault.proposeRebalancer(address(newReb));
        vm.warp(block.timestamp + vault.ADMIN_TIMELOCK() + 1);

        vm.expectEmit(true, true, false, false, address(vault));
        emit RebalancerUpdated(address(rebalancer), address(newReb));
        vault.executeRebalancer();
        vm.stopPrank();

        assertEq(address(vault.rebalancer()), address(newReb));
        assertEq(vault.pendingRebalancer(), address(0), "pending must be cleared");
        assertEq(vault.pendingRebalancerEta(), 0, "eta must be cleared");
    }

    function test_executeRebalancer_onlyDefaultAdmin() public {
        MockRebalancer newReb = new MockRebalancer();

        vm.prank(admin);
        vault.proposeRebalancer(address(newReb));
        vm.warp(block.timestamp + vault.ADMIN_TIMELOCK());

        vm.prank(attacker);
        vm.expectRevert();
        vault.executeRebalancer();

        assertEq(address(vault.rebalancer()), address(rebalancer), "attacker must not apply the change");
    }

    function test_executeRebalancer_cannotBeReplayed() public {
        MockRebalancer newReb = new MockRebalancer();

        vm.startPrank(admin);
        vault.proposeRebalancer(address(newReb));
        vm.warp(block.timestamp + vault.ADMIN_TIMELOCK());
        vault.executeRebalancer();

        vm.expectRevert(CuratioVault.NoPendingProposal.selector);
        vault.executeRebalancer();
        vm.stopPrank();
    }

    function test_cancelRebalancer_clearsPending() public {
        vm.startPrank(admin);
        vault.proposeRebalancer(address(new MockRebalancer()));
        vault.cancelRebalancer();
        vm.stopPrank();

        assertEq(vault.pendingRebalancer(), address(0));
        assertEq(vault.pendingRebalancerEta(), 0);

        vm.warp(block.timestamp + vault.ADMIN_TIMELOCK() + 1);
        vm.prank(admin);
        vm.expectRevert(CuratioVault.NoPendingProposal.selector);
        vault.executeRebalancer();
    }

    function test_cancelRebalancer_revertsWithNoProposal() public {
        vm.prank(admin);
        vm.expectRevert(CuratioVault.NoPendingProposal.selector);
        vault.cancelRebalancer();
    }

    function test_cancelRebalancer_onlyDefaultAdmin() public {
        MockRebalancer newRebalancer = new MockRebalancer();
        vm.prank(admin);
        vault.proposeRebalancer(address(newRebalancer));

        assertEq(vault.pendingRebalancer(), address(newRebalancer));

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, bytes32(0))
        );
        vault.cancelRebalancer();

        assertEq(vault.pendingRebalancer(), address(newRebalancer), "attacker must not cancel");
    }

    // ── What the timelock protects ───────────────────────────────────

    /// Valuation (and therefore the share price) cannot be changed by a proposal alone. After
    /// execution the OLD rebalancer's holdings stop being counted: documents why funds must be moved first.
    function test_rebalancerChange_doesNotAffectValuationUntilExecuted() public {
        vm.prank(alice);
        vault.deposit(100 ether, alice);
        rebalancer.setManagedAssets(500 ether);
        uint256 totalBefore = vault.totalAssets(); // 100 idle + 500 managed
        assertEq(totalBefore, 600 ether);

        MockRebalancer empty = new MockRebalancer();
        vm.prank(admin);
        vault.proposeRebalancer(address(empty));

        assertEq(vault.totalAssets(), totalBefore, "a proposal must not move the share price");
        assertEq(address(vault.rebalancer()), address(rebalancer));

        vm.warp(block.timestamp + vault.ADMIN_TIMELOCK());
        vm.prank(admin);
        vault.executeRebalancer();

        assertEq(vault.totalAssets(), 100 ether, "after the switch the old rebalancer's 500 are no longer counted");
    }

    /// The reason for the delay: users can leave while a (possibly hostile) change is pending.
    function test_proposedRebalancer_usersCanStillWithdrawDuringDelay() public {
        vm.prank(alice);
        vault.deposit(100 ether, alice);

        MockRebalancer newRebalancer = new MockRebalancer();
        vm.prank(admin);
        vault.proposeRebalancer(address(newRebalancer));
        assertEq(vault.pendingRebalancer(), address(newRebalancer), "proposal not recorded");

        uint256 before_ = asset.balanceOf(alice);
        vm.prank(alice);
        vault.withdraw(40 ether, alice, alice);

        assertEq(asset.balanceOf(alice), before_ + 40 ether);
    }

    /// A new access contract that does not whitelist alice blocks her exit, but only after the delay.
    function test_accessControlChange_doesNotBlockExitsUntilExecuted() public {
        vm.prank(alice);
        vault.deposit(100 ether, alice);

        CuratioAccess strict = new CuratioAccess(admin); // alice is not whitelisted here
        vm.prank(admin);
        vault.proposeAccessControl(address(strict));

        vm.prank(alice);
        vault.withdraw(10 ether, alice, alice); // still fine during the delay

        vm.warp(block.timestamp + vault.ADMIN_TIMELOCK());
        vm.prank(admin);
        vault.executeAccessControl();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CuratioVault.NotWhitelisted.selector, alice));
        vault.withdraw(10 ether, alice, alice);
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

    // ==========================================
    // ✅ NEW: Copy-LP / Follow Strategist Tests
    // ==========================================

    function test_followStrategist_success() public {
        vm.prank(admin);
        access.setWhitelistedUser(alice, true);

        // ✅ Mock the rebalancer's registry call
        address mockRegistry = makeAddr("mockRegistry");
        vm.mockCall(address(rebalancer), abi.encodeWithSignature("strategistRegistry()"), abi.encode(mockRegistry));

        // ✅ Mock the registry's checks to return true
        vm.mockCall(
            mockRegistry, abi.encodeWithSignature("isRegisteredStrategist(address)", strategist), abi.encode(true)
        );
        vm.mockCall(mockRegistry, abi.encodeWithSignature("isActiveStrategist(address)", strategist), abi.encode(true));

        // ✅ Now Alice can follow
        vm.prank(alice);
        vault.followStrategist(strategist);

        assertEq(vault.depositorToStrategist(alice), strategist, "Alice should follow the strategist");
    }

    function test_followStrategist_revertsIfNotWhitelisted() public {
        // ✅ alice এর বদলে attacker ব্যবহার করা হলো
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(CuratioVault.NotWhitelisted.selector, attacker));
        vault.followStrategist(makeAddr("strategist"));
    }

    function test_unfollowStrategist_success() public {
        vm.prank(admin);
        access.setWhitelistedUser(alice, true);

        // Mock for following
        address mockRegistry = makeAddr("mockRegistry");
        vm.mockCall(address(rebalancer), abi.encodeWithSignature("strategistRegistry()"), abi.encode(mockRegistry));
        vm.mockCall(
            mockRegistry, abi.encodeWithSignature("isRegisteredStrategist(address)", strategist), abi.encode(true)
        );
        vm.mockCall(mockRegistry, abi.encodeWithSignature("isActiveStrategist(address)", strategist), abi.encode(true));

        // Follow
        vm.prank(alice);
        vault.followStrategist(strategist);
        assertEq(vault.depositorToStrategist(alice), strategist);

        // Unfollow
        vm.prank(alice);
        vault.unfollowStrategist();

        assertEq(vault.depositorToStrategist(alice), address(0), "Alice should unfollow successfully");
    }
}
