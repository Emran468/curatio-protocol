// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {CuratioDynamicFee} from "../../src/CuratioDynamicFee.sol";

contract CuratioDynamicFeeTest is Test {
    CuratioDynamicFee public fee;

    address public admin = makeAddr("admin");
    address public vault = makeAddr("vault");
    address public feeRecipient = makeAddr("feeRecipient");
    address public attacker = makeAddr("attacker");
    address public feeAdmin2 = makeAddr("feeAdmin2");

    event PerformanceFeeCharged(address indexed vault, uint256 yieldAmount, uint256 feeAmount);
    event PerformanceFeeUpdated(uint256 newBps);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event VaultUpdated(address indexed oldVault, address indexed newVault);

    function setUp() public {
        fee = new CuratioDynamicFee(admin, vault, feeRecipient);
    }

    // ── Constructor ──────────────────────────────────────────────

    function test_constructor_revertsOnZeroAdmin() public {
        vm.expectRevert(CuratioDynamicFee.ZeroAddress.selector);
        new CuratioDynamicFee(address(0), vault, feeRecipient);
    }

    function test_constructor_revertsOnZeroVault() public {
        vm.expectRevert(CuratioDynamicFee.ZeroAddress.selector);
        new CuratioDynamicFee(admin, address(0), feeRecipient);
    }

    function test_constructor_revertsOnZeroFeeRecipient() public {
        vm.expectRevert(CuratioDynamicFee.ZeroAddress.selector);
        new CuratioDynamicFee(admin, vault, address(0));
    }

    function test_constructor_setsInitialState() public view {
        assertEq(fee.vault(), vault);
        assertEq(fee.feeRecipient(), feeRecipient);
        assertEq(fee.performanceFeeBps(), 1000);
        assertEq(fee.totalFeesCharged(), 0);
        assertTrue(fee.hasRole(fee.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(fee.hasRole(fee.FEE_ADMIN_ROLE(), admin));
        assertTrue(fee.hasRole(fee.VAULT_ROLE(), vault));
    }

    // ── calculatePerformanceFee ───────────────────────────────────

    function test_calculatePerformanceFee_defaultTenPercent() public view {
        // 1000 bps == 10%
        assertEq(fee.calculatePerformanceFee(1000 ether), 100 ether);
    }

    function test_calculatePerformanceFee_zeroYieldReturnsZero() public view {
        assertEq(fee.calculatePerformanceFee(0), 0);
    }

    function test_calculatePerformanceFee_afterFeeChange() public {
        vm.prank(admin);
        fee.setPerformanceFeeBps(2000); // 20%

        assertEq(fee.calculatePerformanceFee(1000 ether), 200 ether);
    }

    function test_calculatePerformanceFee_atMaxCap() public {
        vm.prank(admin);
        fee.setPerformanceFeeBps(3000); // 30%, the hard max

        assertEq(fee.calculatePerformanceFee(1000 ether), 300 ether);
    }

    function test_calculatePerformanceFee_roundsDown() public view {
        // 999 wei * 1000 bps / 10000 = 99.9 -> rounds down to 99 in integer division
        assertEq(fee.calculatePerformanceFee(999), 99);
    }

    function test_calculatePerformanceFee_doesNotRequireVaultCaller() public view {
        // This is a view function with no access restriction — callable by anyone.
        assertEq(fee.calculatePerformanceFee(500 ether), 50 ether);
    }

    // ── reportPerformanceFeeCharged ───────────────────────────────

    function test_reportPerformanceFeeCharged_onlyVault() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(CuratioDynamicFee.NotVault.selector, attacker));
        fee.reportPerformanceFeeCharged(1000 ether, 100 ether);
    }

    function test_reportPerformanceFeeCharged_updatesTotalAndEmits() public {
        vm.prank(vault);
        vm.expectEmit(true, true, true, true);
        emit PerformanceFeeCharged(vault, 1000 ether, 100 ether);
        fee.reportPerformanceFeeCharged(1000 ether, 100 ether);

        assertEq(fee.totalFeesCharged(), 100 ether);
    }

    function test_reportPerformanceFeeCharged_accumulatesAcrossMultipleCalls() public {
        vm.startPrank(vault);
        fee.reportPerformanceFeeCharged(1000 ether, 100 ether);
        fee.reportPerformanceFeeCharged(500 ether, 50 ether);
        fee.reportPerformanceFeeCharged(2000 ether, 200 ether);
        vm.stopPrank();

        assertEq(fee.totalFeesCharged(), 350 ether);
    }

    function test_reportPerformanceFeeCharged_allowsZeroFeeAmount() public {
        vm.prank(vault);
        fee.reportPerformanceFeeCharged(0, 0);

        assertEq(fee.totalFeesCharged(), 0);
    }

    // ── Admin: setPerformanceFeeBps ───────────────────────────────

    function test_setPerformanceFeeBps_onlyFeeAdminRole() public {
        bytes32 feeAdminRole = fee.FEE_ADMIN_ROLE(); // pre-fetch, outside prank

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", attacker, feeAdminRole)
        );
        fee.setPerformanceFeeBps(1500);
    }

    function test_setPerformanceFeeBps_revertsAboveHardCap() public {
        uint256 maxBps = fee.MAX_PERFORMANCE_FEE_BPS(); // pre-fetch, outside prank

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CuratioDynamicFee.FeeTooHigh.selector, maxBps + 1, maxBps));
        fee.setPerformanceFeeBps(maxBps + 1);
    }

    function test_setPerformanceFeeBps_succeedsAtExactHardCap() public {
        uint256 maxBps = fee.MAX_PERFORMANCE_FEE_BPS();

        vm.prank(admin);
        fee.setPerformanceFeeBps(maxBps);

        assertEq(fee.performanceFeeBps(), maxBps);
    }

    function test_setPerformanceFeeBps_updatesStateAndEmits() public {
        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit PerformanceFeeUpdated(1500);
        fee.setPerformanceFeeBps(1500);

        assertEq(fee.performanceFeeBps(), 1500);
    }

    function test_setPerformanceFeeBps_canBeSetToZero() public {
        vm.prank(admin);
        fee.setPerformanceFeeBps(0);

        assertEq(fee.performanceFeeBps(), 0);
        assertEq(fee.calculatePerformanceFee(1000 ether), 0);
    }

    function test_setPerformanceFeeBps_grantedRoleCanAlsoCall() public {
        bytes32 feeAdminRole = fee.FEE_ADMIN_ROLE(); // pre-fetch, outside prank

        vm.prank(admin);
        fee.grantRole(feeAdminRole, feeAdmin2);

        vm.prank(feeAdmin2);
        fee.setPerformanceFeeBps(1200);

        assertEq(fee.performanceFeeBps(), 1200);
    }

    // ── Admin: setFeeRecipient ────────────────────────────────────
    function test_setFeeRecipient_onlyDefaultAdminRole() public {
        bytes32 defaultAdminRole = fee.DEFAULT_ADMIN_ROLE(); // pre-fetch, outside prank

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", attacker, defaultAdminRole)
        );
        fee.setFeeRecipient(makeAddr("newRecipient"));
    }

    function test_setFeeRecipient_feeAdminRoleCannotCall() public {
        bytes32 feeAdminRole = fee.FEE_ADMIN_ROLE();
        bytes32 defaultAdminRole = fee.DEFAULT_ADMIN_ROLE(); // pre-fetch, outside prank

        vm.prank(admin);
        fee.grantRole(feeAdminRole, feeAdmin2);

        // feeAdmin2 has FEE_ADMIN_ROLE but not DEFAULT_ADMIN_ROLE.
        vm.prank(feeAdmin2);
        vm.expectRevert(
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", feeAdmin2, defaultAdminRole)
        );
        fee.setFeeRecipient(makeAddr("newRecipient"));
    }

    function test_setFeeRecipient_revertsOnZero() public {
        vm.prank(admin);
        vm.expectRevert(CuratioDynamicFee.ZeroAddress.selector);
        fee.setFeeRecipient(address(0));
    }

    function test_setFeeRecipient_updatesStateAndEmits() public {
        address newRecipient = makeAddr("newRecipient");

        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit FeeRecipientUpdated(feeRecipient, newRecipient);
        fee.setFeeRecipient(newRecipient);

        assertEq(fee.feeRecipient(), newRecipient);
    }

    // ── Admin: setVault ────────────────────────────────────────────

    function test_setVault_onlyDefaultAdminRole() public {
        bytes32 defaultAdminRole = fee.DEFAULT_ADMIN_ROLE(); // pre-fetch, outside prank

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", attacker, defaultAdminRole)
        );
        fee.setVault(makeAddr("newVault"));
    }

    function test_setVault_revertsOnZero() public {
        vm.prank(admin);
        vm.expectRevert(CuratioDynamicFee.ZeroAddress.selector);
        fee.setVault(address(0));
    }

    function test_setVault_revokesOldGrantsNewRoleAndEmits() public {
        address newVault = makeAddr("newVault");
        bytes32 vaultRole = fee.VAULT_ROLE(); // pre-fetch, outside prank

        assertTrue(fee.hasRole(vaultRole, vault));

        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit VaultUpdated(vault, newVault);
        fee.setVault(newVault);

        assertFalse(fee.hasRole(vaultRole, vault));
        assertTrue(fee.hasRole(vaultRole, newVault));
        assertEq(fee.vault(), newVault);
    }

    function test_setVault_oldVaultCanNoLongerReportFees() public {
        address newVault = makeAddr("newVault");

        vm.prank(admin);
        fee.setVault(newVault);

        // The old vault address, no longer holding VAULT_ROLE, must now be
        // rejected by the onlyVault modifier (msg.sender != vault).
        vm.prank(vault);
        vm.expectRevert(abi.encodeWithSelector(CuratioDynamicFee.NotVault.selector, vault));
        fee.reportPerformanceFeeCharged(100 ether, 10 ether);
    }

    function test_setVault_newVaultCanReportFees() public {
        address newVault = makeAddr("newVault");

        vm.prank(admin);
        fee.setVault(newVault);

        vm.prank(newVault);
        fee.reportPerformanceFeeCharged(100 ether, 10 ether);

        assertEq(fee.totalFeesCharged(), 10 ether);
    }
}
