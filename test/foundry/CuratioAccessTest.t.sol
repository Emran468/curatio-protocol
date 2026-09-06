// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {CuratioAccess} from "../../src/CuratioAccess.sol";

contract CuratioAccessTest is Test {
    CuratioAccess public access;

    address public admin = makeAddr("admin");
    address public manager2 = makeAddr("manager2"); // will be granted VAULT_MANAGER_ROLE in some tests
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public attacker = makeAddr("attacker");

    event UserWhitelisted(address indexed user, bool status);
    event WhitelistingToggled(bool status);

    function setUp() public {
        access = new CuratioAccess(admin);
    }

    // ── Constructor ──────────────────────────────────────────────

    function test_constructor_revertsOnZeroAdmin() public {
        vm.expectRevert(bytes("CuratioAccess: zero admin"));
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

    function test_isWhitelisted_falseAfterRevoke() public {
        vm.startPrank(admin);
        access.setWhitelistedUser(alice, true);
        access.setWhitelistedUser(alice, false);
        vm.stopPrank();

        assertFalse(access.isWhitelisted(alice));
    }

    // ── setWhitelistedUser ────────────────────────────────────────

    function test_setWhitelistedUser_onlyVaultManagerRole() public {
        vm.prank(attacker);
        vm.expectRevert();
        access.setWhitelistedUser(alice, true);
    }

    function test_setWhitelistedUser_revertsOnZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(bytes("CuratioAccess: zero user"));
        access.setWhitelistedUser(address(0), true);
    }

    function test_setWhitelistedUser_emitsEvent() public {
        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit UserWhitelisted(alice, true);
        access.setWhitelistedUser(alice, true);
    }

    function test_setWhitelistedUser_grantedRoleCanAlsoCall() public {
        bytes32 vaultManagerRole = access.VAULT_MANAGER_ROLE(); // pre-fetch, outside prank

        vm.prank(admin);
        access.grantRole(vaultManagerRole, manager2);

        vm.prank(manager2);
        access.setWhitelistedUser(alice, true);

        assertTrue(access.isWhitelisted(alice));
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
        vm.expectRevert(bytes("CuratioAccess: zero user"));
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

    function test_setWhitelistedUsersBatch_canRevokeAllAtOnce() public {
        address[] memory users = new address[](2);
        users[0] = alice;
        users[1] = bob;

        vm.startPrank(admin);
        access.setWhitelistedUsersBatch(users, true);
        access.setWhitelistedUsersBatch(users, false);
        vm.stopPrank();

        assertFalse(access.isWhitelisted(alice));
        assertFalse(access.isWhitelisted(bob));
    }

    // ── toggleWhitelisting ────────────────────────────────────────

    function test_toggleWhitelisting_onlyDefaultAdminRole() public {
        // Note: STRATEGIST_ROLE/VAULT_MANAGER_ROLE holders should NOT be able
        // to call this — only DEFAULT_ADMIN_ROLE. manager2 has neither role
        // granted here, so this also implicitly covers the "no role" case.
        vm.prank(attacker);
        vm.expectRevert();
        access.toggleWhitelisting(false);
    }

    function test_toggleWhitelisting_vaultManagerCannotCall() public {
        bytes32 vaultManagerRole = access.VAULT_MANAGER_ROLE(); // pre-fetch, outside prank

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
}
