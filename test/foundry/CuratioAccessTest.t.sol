// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {CuratioAccess} from "../../src/CuratioAccess.sol";

contract CuratioAccessTest is Test {
    CuratioAccess public access;

    address public admin = makeAddr("admin");
    address public manager2 = makeAddr("manager2");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public attacker = makeAddr("attacker");

    event UserWhitelisted(address indexed user, bool status);
    event WhitelistingToggled(bool status);
    event RemovalProposed(address indexed user, uint256 eta);
    event RemovalCancelled(address indexed user);
    event RemovalExecuted(address indexed user);

    function setUp() public {
        access = new CuratioAccess(admin);
    }

    // ── Constructor ──────────────────────────────────────────────

    function test_constructor_revertsOnZeroAdmin() public {
        vm.expectRevert(CuratioAccess.ZeroAddress.selector);
        new CuratioAccess(address(0));
    }

    function test_constructor_grantsAllRolesToAdmin() public view {
        assertTrue(access.hasRole(access.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(access.hasRole(access.STRATEGIST_ROLE(), admin));
        assertTrue(access.hasRole(access.VAULT_MANAGER_ROLE(), admin));
    }

    function test_constructor_whitelistingEnabledByDefault() public view {
        assertTrue(access.isWhitelistingEnabled());
    }

    // ── isWhitelisted ─────────────────────────────────────────────

    function test_isWhitelisted_falseByDefaultWhenEnabled() public view {
        assertFalse(access.isWhitelisted(alice));
    }

    function test_isWhitelisted_trueForEveryoneWhenDisabled() public {
        vm.prank(admin);
        access.toggleWhitelisting(false);

        assertTrue(access.isWhitelisted(alice));
        assertTrue(access.isWhitelisted(bob));
        assertTrue(access.isWhitelisted(attacker));
    }

    function test_isWhitelisted_trueAfterExplicitWhitelist() public {
        vm.prank(admin);
        access.setWhitelistedUser(alice, true);

        assertTrue(access.isWhitelisted(alice));
        assertFalse(access.isWhitelisted(bob));
    }

    /// @dev Updated: removal goes through propose → warp → execute.
    function test_isWhitelisted_falseAfterRevoke() public {
        vm.prank(admin);
        access.setWhitelistedUser(alice, true);
        assertTrue(access.isWhitelisted(alice), "alice should be whitelisted after add");

        vm.prank(admin);
        access.proposeRemoval(alice);

        // Still whitelisted during the timelock — this guards against silently
        // removing without the delay.
        assertTrue(access.isWhitelisted(alice), "still whitelisted during timelock");

        vm.warp(block.timestamp + access.REMOVAL_TIMELOCK());
        vm.prank(admin);
        access.executeRemoval(alice);

        assertFalse(access.isWhitelisted(alice), "alice must be revoked after execute");
    }

    // ── setWhitelistedUser ────────────────────────────────────────

    function test_setWhitelistedUser_onlyVaultManagerRole() public {
        vm.prank(attacker);
        vm.expectRevert();
        access.setWhitelistedUser(alice, true);
    }

    function test_setWhitelistedUser_revertsOnZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(CuratioAccess.ZeroAddress.selector);
        access.setWhitelistedUser(address(0), true);
    }

    function test_setWhitelistedUser_emitsEvent() public {
        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit UserWhitelisted(alice, true);
        access.setWhitelistedUser(alice, true);
    }

    function test_setWhitelistedUser_grantedRoleCanAlsoCall() public {
        bytes32 vaultManagerRole = access.VAULT_MANAGER_ROLE();

        vm.prank(admin);
        access.grantRole(vaultManagerRole, manager2);

        vm.prank(manager2);
        access.setWhitelistedUser(alice, true);

        assertTrue(access.isWhitelisted(alice));
    }

    /// @dev NEW: setWhitelistedUser(user, false) must NOT be a shortcut around
    ///      the timelock. It must revert so nobody can bypass proposeRemoval.
    function test_setWhitelistedUser_revertsOnRemovalPath() public {
        vm.prank(admin);
        access.setWhitelistedUser(alice, true);

        vm.prank(admin);
        vm.expectRevert(bytes("Use proposeRemoval for removal"));
        access.setWhitelistedUser(alice, false);

        // And alice must still be whitelisted (no silent change).
        assertTrue(access.isWhitelisted(alice), "no silent removal via setWhitelistedUser");
    }

    // ── setWhitelistedUsersBatch ──────────────────────────────────

    function test_setWhitelistedUsersBatch_onlyVaultManagerRole() public {
        address[] memory users = new address[](1);
        users[0] = alice;

        vm.prank(attacker);
        vm.expectRevert();
        access.setWhitelistedUsersBatch(users, true);
    }

    function test_setWhitelistedUsersBatch_revertsOnZeroAddressInArray() public {
        address[] memory users = new address[](2);
        users[0] = alice;
        users[1] = address(0);

        vm.prank(admin);
        vm.expectRevert(CuratioAccess.ZeroAddress.selector);
        access.setWhitelistedUsersBatch(users, true);
    }

    function test_setWhitelistedUsersBatch_setsAllUsers() public {
        address[] memory users = new address[](3);
        users[0] = alice;
        users[1] = bob;
        users[2] = attacker;

        vm.prank(admin);
        access.setWhitelistedUsersBatch(users, true);

        assertTrue(access.isWhitelisted(alice));
        assertTrue(access.isWhitelisted(bob));
        assertTrue(access.isWhitelisted(attacker));
    }

    function test_setWhitelistedUsersBatch_emitsEventPerUser() public {
        address[] memory users = new address[](2);
        users[0] = alice;
        users[1] = bob;

        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit UserWhitelisted(alice, true);
        vm.expectEmit(true, true, true, true);
        emit UserWhitelisted(bob, true);
        access.setWhitelistedUsersBatch(users, true);
    }

    function test_setWhitelistedUsersBatch_handlesEmptyArray() public {
        address[] memory users = new address[](0);

        vm.prank(admin);
        access.setWhitelistedUsersBatch(users, true); // should not revert
    }

    /// @dev Updated: batch revoke now goes through propose → warp → execute.
    function test_setWhitelistedUsersBatch_canRevokeAllAtOnce() public {
        address[] memory users = new address[](2);
        users[0] = alice;
        users[1] = bob;

        vm.prank(admin);
        access.setWhitelistedUsersBatch(users, true);
        assertTrue(access.isWhitelisted(alice));
        assertTrue(access.isWhitelisted(bob));

        // Propose removal for all
        vm.startPrank(admin);
        for (uint256 i = 0; i < users.length; i++) {
            access.proposeRemoval(users[i]);
        }
        vm.stopPrank();

        // Still whitelisted during timelock
        assertTrue(access.isWhitelisted(alice), "still whitelisted during timelock");
        assertTrue(access.isWhitelisted(bob), "still whitelisted during timelock");

        // Warp and execute
        vm.warp(block.timestamp + access.REMOVAL_TIMELOCK());
        vm.startPrank(admin);
        for (uint256 i = 0; i < users.length; i++) {
            access.executeRemoval(users[i]);
        }
        vm.stopPrank();

        assertFalse(access.isWhitelisted(alice), "alice revoked after execute");
        assertFalse(access.isWhitelisted(bob), "bob revoked after execute");
    }

    /// @dev NEW: batch removal path must be blocked on the immediate function.
    function test_setWhitelistedUsersBatch_revertsOnRemovalPath() public {
        address[] memory users = new address[](2);
        users[0] = alice;
        users[1] = bob;

        vm.prank(admin);
        access.setWhitelistedUsersBatch(users, true);
        assertTrue(access.isWhitelisted(alice));

        vm.prank(admin);
        vm.expectRevert(bytes("Use proposeRemovalBatch for removal"));
        access.setWhitelistedUsersBatch(users, false);

        // No silent change.
        assertTrue(access.isWhitelisted(alice), "no silent batch removal");
        assertTrue(access.isWhitelisted(bob), "no silent batch removal");
    }

    // ── toggleWhitelisting ────────────────────────────────────────

    function test_toggleWhitelisting_onlyDefaultAdminRole() public {
        vm.prank(attacker);
        vm.expectRevert();
        access.toggleWhitelisting(false);
    }

    function test_toggleWhitelisting_vaultManagerCannotCall() public {
        bytes32 vaultManagerRole = access.VAULT_MANAGER_ROLE();

        vm.prank(admin);
        access.grantRole(vaultManagerRole, manager2);

        vm.prank(manager2);
        vm.expectRevert();
        access.toggleWhitelisting(false);
    }

    function test_toggleWhitelisting_updatesStateAndEmits() public {
        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit WhitelistingToggled(false);
        access.toggleWhitelisting(false);

        assertFalse(access.isWhitelistingEnabled());
    }

    function test_toggleWhitelisting_canBeReEnabled() public {
        vm.startPrank(admin);
        access.toggleWhitelisting(false);
        access.toggleWhitelisting(true);
        vm.stopPrank();

        assertTrue(access.isWhitelistingEnabled());
    }

    // ── proposeRemoval / executeRemoval / cancelRemoval (NEW) ─────

    function test_proposeRemoval_setsEtaAndEmits() public {
        vm.prank(admin);
        access.setWhitelistedUser(alice, true);

        uint256 expectedEta = block.timestamp + access.REMOVAL_TIMELOCK();

        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit RemovalProposed(alice, expectedEta);
        access.proposeRemoval(alice);

        assertEq(access.pendingRemovalEta(alice), expectedEta);
    }

    function test_proposeRemoval_revertsOnZero() public {
        vm.prank(admin);
        vm.expectRevert(CuratioAccess.ZeroAddress.selector);
        access.proposeRemoval(address(0));
    }

    function test_proposeRemoval_onlyVaultManagerRole() public {
        vm.prank(attacker);
        vm.expectRevert();
        access.proposeRemoval(alice);
    }

    function test_executeRemoval_revertsBeforeTimelock() public {
        vm.prank(admin);
        access.setWhitelistedUser(alice, true);

        vm.prank(admin);
        access.proposeRemoval(alice);

        vm.prank(admin);
        vm.expectRevert(); // timelock still active
        access.executeRemoval(alice);

        // Alice must still be whitelisted (no partial state change).
        assertTrue(access.isWhitelisted(alice), "revert must not revoke");
    }

    function test_executeRemoval_succeedsExactlyAtEta() public {
        vm.prank(admin);
        access.setWhitelistedUser(alice, true);

        vm.prank(admin);
        access.proposeRemoval(alice);
        uint256 eta = access.pendingRemovalEta(alice);

        vm.warp(eta); // exactly at eta

        vm.prank(admin);
        access.executeRemoval(alice);

        assertFalse(access.isWhitelisted(alice));
        assertEq(access.pendingRemovalEta(alice), 0, "eta cleared after execute");
    }

    function test_executeRemoval_revertsWithNoProposal() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CuratioAccess.NoPendingRemoval.selector, alice));
        access.executeRemoval(alice);
    }

    function test_executeRemoval_cannotBeReplayed() public {
        vm.prank(admin);
        access.setWhitelistedUser(alice, true);
        vm.prank(admin);
        access.proposeRemoval(alice);
        vm.warp(block.timestamp + access.REMOVAL_TIMELOCK());

        vm.prank(admin);
        access.executeRemoval(alice);
        assertFalse(access.isWhitelisted(alice));

        // Second execute must revert with NoPendingRemoval.
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CuratioAccess.NoPendingRemoval.selector, alice));
        access.executeRemoval(alice);
    }

    function test_executeRemoval_onlyVaultManagerRole() public {
        vm.prank(admin);
        access.setWhitelistedUser(alice, true);
        vm.prank(admin);
        access.proposeRemoval(alice);
        vm.warp(block.timestamp + access.REMOVAL_TIMELOCK());

        vm.prank(attacker);
        vm.expectRevert();
        access.executeRemoval(alice);
    }

    function test_cancelRemoval_clearsEta() public {
        vm.prank(admin);
        access.setWhitelistedUser(alice, true);
        vm.prank(admin);
        access.proposeRemoval(alice);

        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit RemovalCancelled(alice);
        access.cancelRemoval(alice);

        assertEq(access.pendingRemovalEta(alice), 0);
        // Still whitelisted since we cancelled.
        assertTrue(access.isWhitelisted(alice));
    }

    function test_cancelRemoval_revertsWithNoProposal() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CuratioAccess.NoPendingRemoval.selector, alice));
        access.cancelRemoval(alice);
    }

    /// @dev The whole point of the timelock: a removed user keeps access until
    ///      the delay elapses, then loses it. Checks both sides explicitly.
    function test_removalTimelock_protectsUserDuringDelay() public {
        vm.prank(admin);
        access.setWhitelistedUser(alice, true);

        vm.prank(admin);
        access.proposeRemoval(alice);

        // Halfway through the delay alice is still whitelisted.
        vm.warp(block.timestamp + access.REMOVAL_TIMELOCK() / 2);
        assertTrue(access.isWhitelisted(alice), "still whitelisted mid-delay");

        // At eta, still whitelisted until execute is called.
        vm.warp(block.timestamp + access.REMOVAL_TIMELOCK()); // past eta
        assertTrue(access.isWhitelisted(alice), "whitelisted until execute");

        vm.prank(admin);
        access.executeRemoval(alice);
        assertFalse(access.isWhitelisted(alice), "revoked after execute");
    }
}
