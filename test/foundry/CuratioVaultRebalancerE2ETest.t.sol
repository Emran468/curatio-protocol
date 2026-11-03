// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {CuratioRebalancer} from "../../src/CuratioRebalancer.sol";
import {CuratioVault} from "../../src/CuratioVault.sol";
import {CuratioAccess} from "../../src/CuratioAccess.sol";
import {MockHookView} from "./CuratioRebalancerTest.t.sol";

/// @notice Real vault + real rebalancer + real v4 PoolManager (hook is a TWAP-only mock).
contract CuratioVaultRebalancerE2ETest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // Mirror of the rebalancer's event, needed for vm.expectEmit.
    event LiquidityUnwound(uint128 liquidityRemoved, uint128 liquidityLeft);

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
            currency0: currency0, currency1: currency1, fee: 3000, tickSpacing: 60, hooks: IHooks(address(0))
        });
        manager.initialize(poolKey, SQRT_1_1);

        mockHook = new MockHookView(); // TWAP tick defaults to 0 (price 1)
        access = new CuratioAccess(admin);

        // vault <-> rebalancer are mutually dependent: deploy rebalancer with a placeholder vault, then point it at the real one.
        rebalancer = new CuratioRebalancer(
            address(manager),
            address(mockHook),
            makeAddr("placeholderVault"),
            admin,
            1 ether,
            automationRegistry,
            1000 ether
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

    /// @dev Liquidity the PoolManager itself holds for the rebalancer's position
    ///      (ground truth, not the rebalancer's tracked variable).
    function _poolPositionLiquidity(int24 lo, int24 hi) internal view returns (uint128) {
        bytes32 key = Position.calculatePositionKey(address(rebalancer), lo, hi, bytes32(0));
        return manager.getPositionLiquidity(poolKey.toId(), key);
    }

    // ── share price & fund flow ──────────────────────────────────────────

    function test_e2e_deposit_totalAssetsEqualsDeposit() public {
        uint256 shares = _depositAlice(100 ether);
        assertEq(vault.totalAssets(), 100 ether);
        assertEq(shares, 100 ether * 1e6);
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

    /// The "other" token is donated to the rebalancer so it holds both tokens.
    /// This only checks that moving funds into the LP does not change what the vault reports.
    function test_e2e_lpPositionIsCountedInTotalAssets() public {
        _depositAlice(100 ether);
        vm.prank(admin);
        vault.deployToRebalancer(100 ether);
        other.transfer(address(rebalancer), 100 ether);

        uint256 before = vault.totalAssets(); // 100 asset + 100 other @ price 1 = 200
        assertEq(before, 200 ether);

        vm.prank(admin);
        rebalancer.rebalanceLiquidity(-120, 120, 1000 ether, MAX, MAX);

        assertApproxEqAbs(vault.totalAssets(), before, 10, "moving into LP must not change reported assets");
    }

    // ── withdraw unwinds the LP ──────────────────────────────────────────

    /// A withdrawal larger than the idle asset must unwind part of the LP, swap the other
    /// token into the asset (priced against the TWAP) and pay the full amount.
    /// Every step is asserted so the test cannot pass unless the unwind really happened.
    function test_e2e_withdrawUnwindsLp_andPaysFullAmount() public {
        _depositAlice(100 ether);
        vm.prank(admin);
        vault.deployToRebalancer(100 ether);
        other.transfer(address(rebalancer), 100 ether);

        vm.prank(admin);
        rebalancer.rebalanceLiquidity(-120, 120, 10_000 ether, MAX, MAX); // locks roughly 60 of each token

        // preconditions: prove we are really in the "LP must be unwound" scenario
        uint128 trackedLiqBefore = rebalancer.currentLiquidity();
        assertEq(trackedLiqBefore, 10_000 ether, "position must exist");
        assertEq(_poolPositionLiquidity(-120, 120), trackedLiqBefore, "pool and rebalancer must agree before");

        uint256 idleAssetBefore = asset.balanceOf(address(rebalancer));
        assertLt(idleAssetBefore, 100 ether, "some asset must be locked in the LP");
        assertEq(asset.balanceOf(address(vault)), 0, "vault must hold no idle asset");

        uint256 want = idleAssetBefore + 1 ether; // strictly more than the idle asset
        assertGt(want, idleAssetBefore, "withdrawal must exceed idle asset");

        uint256 aliceAssetBefore = asset.balanceOf(alice);
        uint256 aliceSharesBefore = vault.balanceOf(alice);
        uint256 totalAssetsBefore = vault.totalAssets();

        // action: only checks that the event is emitted by the rebalancer
        vm.expectEmit(false, false, false, false, address(rebalancer));
        emit LiquidityUnwound(0, 0);

        vm.prank(alice);
        uint256 sharesBurned = vault.withdraw(want, alice, alice);

        // 1. alice received exactly what she asked for
        assertEq(asset.balanceOf(alice), aliceAssetBefore + want, "alice must receive the full amount");

        // 2. shares were really burned
        assertGt(sharesBurned, 0, "shares must be burned");
        assertEq(vault.balanceOf(alice), aliceSharesBefore - sharesBurned, "share balance must drop by burned amount");

        // 3. the LP really shrank, both in the tracked state and in the PoolManager
        uint128 trackedLiqAfter = rebalancer.currentLiquidity();
        assertLt(trackedLiqAfter, trackedLiqBefore, "tracked liquidity must decrease");
        assertGt(trackedLiqAfter, 0, "only a partial unwind is needed for this amount");
        assertEq(_poolPositionLiquidity(-120, 120), trackedLiqAfter, "pool and rebalancer must agree after");

        // 4. the vault keeps nothing; the shortfall went straight to alice
        assertEq(asset.balanceOf(address(vault)), 0, "vault must not keep leftover asset");

        // 5. accounting: totalAssets fell by `want`, minus only a small swap-fee loss
        uint256 totalAssetsAfter = vault.totalAssets();
        assertLe(totalAssetsAfter, totalAssetsBefore - want + 10, "no value may be created");
        assertGe(totalAssetsAfter + 0.01 ether, totalAssetsBefore - want, "swap cost must stay tiny");
    }

    /// Negative control: with the TWAP down the unwind must refuse (no unpriced swap) and nothing moves.
    function test_e2e_withdrawUnwind_revertsWhenTwapUnavailable_andChangesNothing() public {
        _depositAlice(100 ether);
        vm.prank(admin);
        vault.deployToRebalancer(100 ether);
        other.transfer(address(rebalancer), 100 ether);
        vm.prank(admin);
        rebalancer.rebalanceLiquidity(-120, 120, 10_000 ether, MAX, MAX);

        uint256 want = asset.balanceOf(address(rebalancer)) + 1 ether;
        uint128 liqBefore = rebalancer.currentLiquidity();
        uint256 aliceBefore = asset.balanceOf(alice);

        mockHook.setShouldRevertOnTwap(true);

        vm.prank(alice);
        vm.expectRevert(CuratioRebalancer.TwapUnavailable.selector);
        vault.withdraw(want, alice, alice);

        assertEq(rebalancer.currentLiquidity(), liqBefore, "LP must be untouched after revert");
        assertEq(asset.balanceOf(alice), aliceBefore, "alice must not receive anything");
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
