// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CuratioVault} from "../../src/CuratioVault.sol";
import {CuratioAccess} from "../../src/CuratioAccess.sol";

contract InflToken is ERC20 {
    constructor() ERC20("Mock", "MCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Holds idle asset only: totalManagedAssets = its asset balance.
contract InflRebalancer {
    IERC20 public immutable asset;

    constructor(IERC20 a) {
        asset = a;
    }

    function notifyDeposit(uint256) external {}
    function notifyWithdraw(uint256) external {}

    function totalManagedAssets() external view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    function returnToVault(uint256 amount) external {
        asset.transfer(msg.sender, amount);
    }
}

/// @notice Inflation / donation-attack protection: _decimalsOffset = 6 plus zero-amount guards.
contract CuratioVaultInflationTest is Test {
    uint256 constant SCALE = 1e6; // 10 ** _decimalsOffset()

    InflToken asset;
    InflRebalancer reb;
    CuratioAccess access;
    CuratioVault vault;

    address admin = makeAddr("admin");
    address alice = makeAddr("alice");
    address attacker = makeAddr("attacker");
    address victim = makeAddr("victim");

    function setUp() public {
        asset = new InflToken();
        reb = new InflRebalancer(IERC20(address(asset)));
        access = new CuratioAccess(admin);
        vault = new CuratioVault(IERC20(address(asset)), address(access), address(reb), admin, 0); // uncapped

        vm.startPrank(admin);
        access.setWhitelistedUser(alice, true);
        access.setWhitelistedUser(attacker, true);
        access.setWhitelistedUser(victim, true);
        vm.stopPrank();

        address[3] memory users = [alice, attacker, victim];
        for (uint256 i = 0; i < users.length; i++) {
            asset.mint(users[i], 1e30);
            vm.prank(users[i]);
            asset.approve(address(vault), type(uint256).max);
        }
    }

    // ── scaling ──────────────────────────────────────────────────────────

    function test_decimals_isAssetDecimalsPlusSix() public view {
        assertEq(uint256(vault.decimals()), 24);
    }

    function test_firstDeposit_mintsScaledShares() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(100 ether, alice);
        assertEq(shares, 100 ether * SCALE, "shares must be scaled by 1e6");
        assertEq(vault.totalAssets(), 100 ether);
    }

    function test_soleDepositor_redeemAll_returnsExactly() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(100 ether, alice);
        uint256 balBefore = asset.balanceOf(alice);

        vm.prank(alice);
        uint256 out = vault.redeem(shares, alice, alice);

        assertEq(out, 100 ether, "sole depositor must get back exactly what was deposited");
        assertEq(asset.balanceOf(alice), balBefore + 100 ether);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.totalAssets(), 0);
    }

    // ── zero-amount guards ───────────────────────────────────────────────

    /// A donation makes a tiny deposit round to 0 shares. It must revert and take nothing.
    function test_zeroShareDeposit_reverts_andTakesNoFunds() public {
        asset.mint(address(vault), 1 ether); // direct donation

        uint256 victimBefore = asset.balanceOf(victim);
        vm.prank(victim);
        vm.expectRevert(CuratioVault.ZeroShares.selector);
        vault.deposit(1e11, victim); // 1e11 * 1e6 / (1e18 + 1) = 0 shares

        assertEq(asset.balanceOf(victim), victimBefore, "victim must keep their tokens");
        assertEq(asset.balanceOf(address(vault)), 1 ether, "vault balance must be unchanged");
        assertEq(vault.totalSupply(), 0, "no shares may exist");
    }

    function test_mintZeroShares_reverts() public {
        vm.prank(alice);
        vm.expectRevert(CuratioVault.ZeroShares.selector);
        vault.mint(0, alice);
    }

    /// Redeeming dust shares that are worth 0 assets must revert and burn nothing.
    function test_redeemZeroAssets_reverts_andBurnsNothing() public {
        vm.prank(alice);
        vault.deposit(100 ether, alice);
        uint256 sharesBefore = vault.balanceOf(alice);

        vm.prank(alice);
        vm.expectRevert(CuratioVault.ZeroAssets.selector);
        vault.redeem(1, alice, alice); // 1 * (1e20 + 1) / (1e26 + 1e6) = 0 assets

        assertEq(vault.balanceOf(alice), sharesBefore, "shares must not be burned");
    }

    // ── the actual attack ────────────────────────────────────────────────

    /// Classic attack: deposit 1 wei, donate a lot, let the victim deposit.
    /// With the offset the victim loses a negligible amount and the attacker loses money.
    function test_inflationAttack_isUnprofitable_andVictimLossIsTiny() public {
        vm.prank(attacker);
        uint256 attackerShares = vault.deposit(1, attacker); // 1 wei
        assertEq(attackerShares, SCALE);

        vm.prank(attacker);
        asset.transfer(address(vault), 10 ether); // donation to inflate the share price

        vm.prank(victim);
        uint256 victimShares = vault.deposit(10 ether, victim);
        assertGt(victimShares, 0, "victim must receive shares");

        vm.prank(victim);
        uint256 victimOut = vault.redeem(victimShares, victim, victim);
        assertGe(victimOut + 10 ether / 100_000, 10 ether, "victim loss must stay below 0.001%");

        vm.prank(attacker);
        uint256 attackerOut = vault.redeem(attackerShares, attacker, attacker);
        assertLt(attackerOut, 10 ether + 1, "attacker must lose money overall");
    }

    // ── fuzz ─────────────────────────────────────────────────────────────

    /// A sole depositor can always get back exactly what they put in.
    function testFuzz_soleDepositor_roundTripIsExact(uint256 amt) public {
        amt = bound(amt, 1, 1e27);

        vm.prank(alice);
        uint256 shares = vault.deposit(amt, alice);
        vm.prank(alice);
        uint256 out = vault.redeem(shares, alice, alice);

        assertEq(out, amt);
    }

    /// With ANY donation, a deposit either mints at least 1 share or reverts with ZeroShares.
    /// It can never succeed with 0 shares.
    function testFuzz_deposit_neverSucceedsWithZeroShares(uint256 donation, uint256 amt) public {
        donation = bound(donation, 0, 1e30);
        amt = bound(amt, 1, 1e27);
        asset.mint(address(vault), donation);

        vm.prank(alice);
        try vault.deposit(amt, alice) returns (uint256 shares) {
            assertGt(shares, 0, "a successful deposit must mint shares");
        } catch (bytes memory err) {
            assertEq(bytes4(err), CuratioVault.ZeroShares.selector, "only ZeroShares may reject a valid deposit");
        }
    }
}
