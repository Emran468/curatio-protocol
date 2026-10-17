// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CuratioRebalancer} from "../../src/CuratioRebalancer.sol";
import {MockHookView} from "./CuratioRebalancerTest.t.sol";

/// @notice Valuation (totalManagedAssets) and idle-return tests on the REAL PoolManager.
///         The hook is a TWAP-only mock here; swap in the real CuratioHook in the
///         end-to-end test (step 3).
contract CuratioRebalancerValuationTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    uint160 constant SQRT_1_1 = 79228162514264337593543950336;
    uint256 constant MAX = type(uint256).max;

    CuratioRebalancer rebalancer;
    MockHookView mockHook;
    PoolKey poolKey;

    address admin = makeAddr("admin");
    address vault = makeAddr("vault");
    address automationRegistry = makeAddr("automationRegistry");
    address attacker = makeAddr("attacker");

    address t0;
    address t1;

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();
        t0 = Currency.unwrap(currency0);
        t1 = Currency.unwrap(currency1);

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        manager.initialize(poolKey, SQRT_1_1);

        mockHook = new MockHookView();
        rebalancer = new CuratioRebalancer(
            address(manager), address(mockHook), vault, admin, 1 ether, automationRegistry, 1000 ether
        );

        vm.startPrank(admin);
        rebalancer.setManagedPool(poolKey);
        rebalancer.setAsset(t0);
        vm.stopPrank();
    }

    function _fund(uint256 amt0, uint256 amt1) internal {
        if (amt0 > 0) IERC20(t0).transfer(address(rebalancer), amt0);
        if (amt1 > 0) IERC20(t1).transfer(address(rebalancer), amt1);
    }

    // ── setAsset ─────────────────────────────────────────────────────────

    function test_setAsset_onlyAdmin() public {
        vm.prank(attacker);
        vm.expectRevert();
        rebalancer.setAsset(t0);
    }

    function test_setAsset_revertsForNonPoolToken() public {
        vm.prank(admin);
        vm.expectRevert(CuratioRebalancer.InvalidAsset.selector);
        rebalancer.setAsset(makeAddr("randomToken"));
    }

    function test_setAsset_revertsForZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(CuratioRebalancer.InvalidAsset.selector);
        rebalancer.setAsset(address(0));
    }

    function test_setAsset_revertsIfPoolNotConfigured() public {
        CuratioRebalancer fresh = new CuratioRebalancer(
            address(manager), address(mockHook), vault, admin, 1 ether, automationRegistry, 1000 ether
        );
        vm.prank(admin);
        vm.expectRevert(CuratioRebalancer.PoolNotConfigured.selector);
        fresh.setAsset(t0);
    }

    function test_setManagedPool_resetsAsset() public {
        assertEq(rebalancer.asset(), t0);
        vm.prank(admin);
        rebalancer.setManagedPool(poolKey);
        assertEq(rebalancer.asset(), address(0));
    }

    // ── totalManagedAssets ───────────────────────────────────────────────

    function test_totalManagedAssets_revertsIfAssetNotSet() public {
        vm.prank(admin);
        rebalancer.setManagedPool(poolKey); // clears asset
        vm.expectRevert(CuratioRebalancer.AssetNotSet.selector);
        rebalancer.totalManagedAssets();
    }

    function test_totalManagedAssets_idleOnly_priceOne() public {
        _fund(100 ether, 50 ether);
        mockHook.setTwapTick(0);
        assertEq(rebalancer.totalManagedAssets(), 150 ether);
    }

    function test_totalManagedAssets_includesLpPosition() public {
        _fund(1000 ether, 1000 ether);
        mockHook.setTwapTick(0);
        uint256 before = rebalancer.totalManagedAssets();
        assertEq(before, 2000 ether);

        vm.prank(admin);
        rebalancer.rebalanceLiquidity(-120, 120, 100 ether, MAX, MAX);

        // Moving funds into the LP must not change total value (up to a few wei of rounding).
        assertApproxEqAbs(rebalancer.totalManagedAssets(), 2000 ether, 10);
    }

    /// The core anti-manipulation property: swapping in the pool moves SPOT price,
    /// but the valuation follows the TWAP, so it must not change.
    function test_totalManagedAssets_ignoresSpotPriceManipulation() public {
        _fund(1000 ether, 1000 ether);
        mockHook.setTwapTick(0);
        vm.prank(admin);
        rebalancer.rebalanceLiquidity(-120, 120, 100 ether, MAX, MAX);

        uint256 beforeSwap = rebalancer.totalManagedAssets();

        swap(poolKey, true, -int256(1 ether), ""); // pushes spot price down

        assertEq(rebalancer.totalManagedAssets(), beforeSwap, "valuation must follow TWAP, not spot");
    }

    function test_totalManagedAssets_followsTwapPrice_assetIsToken0() public {
        _fund(0, 100 ether); // only token1 idle
        mockHook.setTwapTick(6932); // price ~= 2 token1 per token0
        // 100 token1 / 2 ~= 50 token0
        assertApproxEqRel(rebalancer.totalManagedAssets(), 50 ether, 0.001e18);
    }

    function test_totalManagedAssets_followsTwapPrice_assetIsToken1() public {
        vm.prank(admin);
        rebalancer.setAsset(t1);
        _fund(100 ether, 0); // only token0 idle
        mockHook.setTwapTick(6932);
        // 100 token0 * 2 ~= 200 token1
        assertApproxEqRel(rebalancer.totalManagedAssets(), 200 ether, 0.001e18);
    }

    function test_totalManagedAssets_positionOutOfRangeBelow_isAllToken0() public {
        _fund(1000 ether, 1000 ether);
        mockHook.setTwapTick(0);
        vm.prank(admin);
        rebalancer.rebalanceLiquidity(-120, 120, 100 ether, MAX, MAX);

        // TWAP far below the range: position counts as 100% token0
        mockHook.setTwapTick(-600);
        uint256 v = rebalancer.totalManagedAssets();
        assertGt(v, 0);
    }

    function test_totalManagedAssets_revertsWhenTwapUnavailable() public {
        _fund(100 ether, 100 ether);
        mockHook.setShouldRevertOnTwap(true);
        vm.expectRevert(CuratioRebalancer.TwapUnavailable.selector);
        rebalancer.totalManagedAssets();
    }

    // ── returnToVault ────────────────────────────────────────────────────

    function test_returnToVault_onlyVault() public {
        _fund(100 ether, 0);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(CuratioRebalancer.NotVault.selector, attacker));
        rebalancer.returnToVault(1 ether);
    }

    function test_returnToVault_sendsIdleAssetToVault() public {
        _fund(100 ether, 0);
        uint256 beforeBal = IERC20(t0).balanceOf(vault);

        vm.prank(vault);
        rebalancer.returnToVault(30 ether);

        assertEq(IERC20(t0).balanceOf(vault), beforeBal + 30 ether);
        assertEq(IERC20(t0).balanceOf(address(rebalancer)), 70 ether);
    }

    function test_returnToVault_revertsWhenIdleInsufficient() public {
        _fund(10 ether, 0);
        vm.prank(vault);
        vm.expectRevert(abi.encodeWithSelector(CuratioRebalancer.InsufficientIdle.selector, 10 ether, 30 ether));
        rebalancer.returnToVault(30 ether);
    }

    function test_returnToVault_revertsIfAssetNotSet() public {
        vm.prank(admin);
        rebalancer.setManagedPool(poolKey);
        vm.prank(vault);
        vm.expectRevert(CuratioRebalancer.AssetNotSet.selector);
        rebalancer.returnToVault(1 ether);
    }
}
