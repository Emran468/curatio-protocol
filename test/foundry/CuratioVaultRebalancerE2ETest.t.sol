// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CuratioRebalancer} from "../../src/CuratioRebalancer.sol";
import {CuratioVault} from "../../src/CuratioVault.sol";
import {CuratioAccess} from "../../src/CuratioAccess.sol";
import {MockHookView} from "./CuratioRebalancerTest.t.sol";

/// @notice Real vault + real rebalancer + real v4 PoolManager (hook is a TWAP-only mock).
///         Where the missing swap step matters, the test says so explicitly.
contract CuratioVaultRebalancerE2ETest is Test, Deployers {
    uint160 constant SQRT_1_1 = 79228162514264337593543950336;
    uint256 constant MAX = type(uint256).max;

    CuratioVault vault;
    CuratioRebalancer rebalancer;
    CuratioAccess access;
    MockHookView mockHook;
    PoolKey poolKey;

    IERC20 asset; // currency0
    IERC20 other; // currency1

    address admin = makeAddr("admin");
    address alice = makeAddr("alice");
    address attacker = makeAddr("attacker");
    address automationRegistry = makeAddr("automationRegistry");

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();
        asset = IERC20(Currency.unwrap(currency0));
        other = IERC20(Currency.unwrap(currency1));

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        manager.initialize(poolKey, SQRT_1_1);

        mockHook = new MockHookView(); // TWAP tick defaults to 0 (price 1)
        access = new CuratioAccess(admin);

        // vault <-> rebalancer are mutually dependent: deploy rebalancer with a placeholder vault, then point it at the real one.
        rebalancer = new CuratioRebalancer(
            address(manager), address(mockHook), makeAddr("placeholderVault"), admin, 1 ether, automationRegistry, 1000 ether
        );
        vault = new CuratioVault(asset, address(access), address(rebalancer), admin, 1000 ether);

        vm.startPrank(admin);
        rebalancer.setVault(address(vault));
        rebalancer.setManagedPool(poolKey);
        rebalancer.setAsset(address(asset));
        access.setWhitelistedUser(alice, true);
        vm.stopPrank();

        asset.transfer(alice, 1000 ether);
        vm.prank(alice);
        asset.approve(address(vault), type(uint256).max);
    }

    function _depositAlice(uint256 amt) internal returns (uint256 shares) {
        vm.prank(alice);
        shares = vault.deposit(amt, alice);
    }

    // ── share price & fund flow ──────────────────────────────────────────

    function test_e2e_deposit_totalAssetsEqualsDeposit() public {
        uint256 shares = _depositAlice(100 ether);
        assertEq(vault.totalAssets(), 100 ether);
        assertEq(shares, 100 ether);
    }

    function test_e2e_deployToRebalancer_doesNotChangeSharePrice() public {
        _depositAlice(100 ether);
        uint256 priceBefore = vault.convertToAssets(1 ether);

        vm.prank(admin);
        vault.deployToRebalancer(100 ether);

        assertEq(asset.balanceOf(address(vault)), 0, "vault idle should be empty");
        assertEq(asset.balanceOf(address(rebalancer)), 100 ether);
        assertEq(vault.totalAssets(), 100 ether, "totalAssets must still count the rebalancer's holdings");
        assertEq(vault.convertToAssets(1 ether), priceBefore, "share price must not move");
    }

    function test_e2e_deployToRebalancer_onlyManager() public {
        _depositAlice(100 ether);
        vm.prank(attacker);
        vm.expectRevert();
        vault.deployToRebalancer(10 ether);
    }

    // ── withdraw pulls from the rebalancer ───────────────────────────────

    function test_e2e_withdraw_pullsShortfallFromRebalancer() public {
        _depositAlice(100 ether);
        vm.prank(admin);
        vault.deployToRebalancer(100 ether); // vault idle = 0

        uint256 aliceBefore = asset.balanceOf(alice);
        vm.prank(alice);
        vault.withdraw(40 ether, alice, alice);

        assertEq(asset.balanceOf(alice), aliceBefore + 40 ether);
        assertEq(asset.balanceOf(address(rebalancer)), 60 ether);
        assertEq(vault.totalAssets(), 60 ether);
    }

    function test_e2e_redeemAll_afterDeploy_returnsEverything() public {
        uint256 shares = _depositAlice(100 ether);
        vm.prank(admin);
        vault.deployToRebalancer(100 ether);

        vm.prank(alice);
        vault.redeem(shares, alice, alice);

        assertEq(asset.balanceOf(alice), 1000 ether);
        assertEq(vault.totalSupply(), 0);
    }

    // ── LP position is counted ───────────────────────────────────────────

    /// The "other" token is donated to the rebalancer to stand in for the swap output
    /// that is not implemented yet. This only checks that moving funds into the LP
    /// does not change what the vault reports.
    function test_e2e_lpPositionIsCountedInTotalAssets() public {
        _depositAlice(100 ether);
        vm.prank(admin);
        vault.deployToRebalancer(100 ether);
        other.transfer(address(rebalancer), 100 ether); // stand-in for swap output

        uint256 before = vault.totalAssets(); // 100 asset + 100 other @ price 1 = 200
        assertEq(before, 200 ether);

        vm.prank(admin);
        rebalancer.rebalanceLiquidity(-120, 120, 1000 ether, MAX, MAX);

        assertApproxEqAbs(vault.totalAssets(), before, 10, "moving into LP must not change reported assets");
    }

    /// Documents the missing swap step: when the LP holds part of the asset, a withdrawal
    /// larger than the idle asset reverts instead of unwinding the LP.
    function test_e2e_KNOWN_LIMITATION_withdrawCannotUnwindLp() public {
        _depositAlice(100 ether);
        vm.prank(admin);
        vault.deployToRebalancer(100 ether);
        other.transfer(address(rebalancer), 100 ether);

        vm.prank(admin);
        rebalancer.rebalanceLiquidity(-120, 120, 10_000 ether, MAX, MAX); // locks roughly 60 of each token

        uint256 idle = asset.balanceOf(address(rebalancer));
        assertLt(idle, 100 ether, "some asset must be locked in the LP");

        uint256 want = idle + 1 ether; // more than the idle asset
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CuratioRebalancer.InsufficientIdle.selector, idle, want));
        vault.withdraw(want, alice, alice);
    }

    // ── safety properties ────────────────────────────────────────────────

    function test_e2e_twapOutage_haltsDepositsInsteadOfMispricing() public {
        mockHook.setShouldRevertOnTwap(true);
        vm.prank(alice);
        vm.expectRevert(CuratioRebalancer.TwapUnavailable.selector);
        vault.deposit(10 ether, alice);
    }

    function test_e2e_depositCapCountsRebalancerHoldings() public {
        _depositAlice(900 ether);
        vm.prank(admin);
        vault.deployToRebalancer(900 ether);

        // 900 now sits in the rebalancer; cap is 1000, so 101 must be rejected
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CuratioVault.DepositCapExceeded.selector, 1001 ether, 1000 ether));
        vault.deposit(101 ether, alice);
    }

    function test_e2e_maxDepositReflectsCapAndPause() public {
        assertEq(vault.maxDeposit(alice), 1000 ether);
        _depositAlice(300 ether);
        assertEq(vault.maxDeposit(alice), 700 ether);

        vm.prank(admin);
        vault.setDepositsPaused(true);
        assertEq(vault.maxDeposit(alice), 0);
        assertEq(vault.maxMint(alice), 0);
    }

    function test_e2e_receiverMustBeWhitelisted() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CuratioVault.NotWhitelisted.selector, attacker));
        vault.deposit(10 ether, attacker);
    }
}
