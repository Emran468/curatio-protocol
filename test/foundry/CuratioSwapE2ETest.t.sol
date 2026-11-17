// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol"; // <-- যোগ করা হয়েছে
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "@uniswap/v4-core/lib/solmate/src/test/utils/mocks/MockERC20.sol";
import {CuratioHook} from "../../src/CuratioHook.sol";
import {CuratioRebalancer} from "../../src/CuratioRebalancer.sol";
import {CuratioVault} from "../../src/CuratioVault.sol";
import {CuratioAccess} from "../../src/CuratioAccess.sol";

/// @notice Option 2: the vault only ever holds ONE token (the asset). The rebalancer swaps the
///         missing token itself when it builds a position, and swaps back when the vault withdraws.
///         Real CuratioHook + real PoolManager + real Rebalancer + real Vault, nothing donated.
contract CuratioSwapE2ETest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    uint256 constant MAX = type(uint256).max;

    CuratioHook hook;
    CuratioRebalancer rebalancer;
    CuratioVault vault;
    CuratioAccess access;
    PoolKey poolKey;
    PoolId poolId;

    IERC20 asset; // currency0
    IERC20 other; // currency1

    address admin = makeAddr("admin");
    address hookOwner = makeAddr("hookOwner");
    address alice = makeAddr("alice");
    address automationRegistry = makeAddr("automationRegistry");

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();
        asset = IERC20(Currency.unwrap(currency0));
        other = IERC20(Currency.unwrap(currency1));

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        address hookAddr = address(flags ^ (uint160(0x4444) << 144));
        deployCodeTo("CuratioHook.sol:CuratioHook", abi.encode(manager, hookOwner), hookAddr);
        hook = CuratioHook(hookAddr);

        (poolKey,) = initPool(currency0, currency1, hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, TickMath.getSqrtPriceAtTick(0));
        poolId = poolKey.toId();

        // external liquidity (deeper than the rebalancer's own position, like a real pool)
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: 100 ether,
                salt: bytes32(0)
            }),
            ""
        );

        access = new CuratioAccess(admin);
        rebalancer = new CuratioRebalancer(
            address(manager),
            address(hook),
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

    // ── helpers ──────────────────────────────────────────────────────────

    function _warmUp() internal {
        vm.warp(block.timestamp + 1000);
    }

    /// alice deposits `amt` and the manager sends all of it to the rebalancer (asset only!)
    function _depositAndDeploy(uint256 amt) internal {
        vm.prank(alice);
        vault.deposit(amt, alice);
        vm.prank(admin);
        vault.deployToRebalancer(amt);
    }

    /// build a ~1 ether position out of asset only: the rebalancer must swap for the other token
    function _openSmallPosition() internal returns (uint128 liq) {
        liq = rebalancer.quoteLiquidityForValue(-120, 120, 1 ether);
        vm.prank(admin);
        rebalancer.rebalanceLiquidity(-120, 120, liq, MAX, MAX);
    }

    // ── sizing helper ────────────────────────────────────────────────────

    function test_swap_quote_widerRangeNeedsLessLiquidityForSameValue() public {
        _warmUp();
        uint128 narrow = rebalancer.quoteLiquidityForValue(-120, 120, 10 ether);
        uint128 wide = rebalancer.quoteLiquidityForValue(-600, 600, 10 ether);
        assertGt(narrow, 0);
        assertGt(wide, 0);
        assertLt(wide, narrow);
    }

    function test_swap_quote_revertsWhenTwapUnavailable() public {
        // no warm-up: the hook has no TWAP history yet
        vm.expectRevert(CuratioRebalancer.TwapUnavailable.selector);
        rebalancer.quoteLiquidityForValue(-120, 120, 1 ether);
    }

    // ── deploy: asset only -> two-sided position ─────────────────────────

    function test_swap_deployFromAssetOnly_buildsPositionWithoutDonation() public {
        _warmUp();
        _depositAndDeploy(100 ether);
        assertEq(other.balanceOf(address(rebalancer)), 0, "rebalancer starts with the asset only");

        uint128 liq = _openSmallPosition();

        assertEq(rebalancer.currentLiquidity(), liq);
        assertEq(other.balanceOf(address(rebalancer)), 0, "swap bought exactly what the position needed");

        uint256 total = vault.totalAssets();
        assertLe(total, 100 ether, "no free money: swap fees can only cost value");
        assertApproxEqRel(total, 100 ether, 0.01e18, "value is preserved up to fees/impact");
    }

    // ── withdraw: unwind LP and swap back ────────────────────────────────

    function test_swap_withdrawUnwindsLpAndPaysInAsset() public {
        _warmUp();
        _depositAndDeploy(100 ether);
        uint128 liqBefore = _openSmallPosition();

        uint256 idle = asset.balanceOf(address(rebalancer));
        uint256 want = idle + 0.3 ether; // more than the idle asset -> part of the LP must be unwound
        uint256 aliceBefore = asset.balanceOf(alice);

        vm.prank(alice);
        vault.withdraw(want, alice, alice);

        assertEq(asset.balanceOf(alice), aliceBefore + want, "alice is paid in the vault asset");
        uint128 liqAfter = rebalancer.currentLiquidity();
        assertLt(liqAfter, liqBefore, "part of the position was removed");
        assertGt(liqAfter, 0, "but not all of it");
    }

    function test_swap_withdrawBeyondRealizableValueRevertsSafely() public {
        _warmUp();
        _depositAndDeploy(100 ether);
        _openSmallPosition();

        // far more than idle + whole position can ever pay
        vm.prank(alice);
        vm.expectRevert();
        vault.withdraw(100 ether, alice, alice);
    }

    // ── protections ──────────────────────────────────────────────────────

    function test_swap_refusesWhenSlippageToleranceTooTight() public {
        _warmUp();
        _depositAndDeploy(100 ether);
        uint128 liq = rebalancer.quoteLiquidityForValue(-120, 120, 1 ether);

        vm.prank(admin);
        rebalancer.setMaxSwapSlippageBps(1); // 0.01%: even the 0.3% pool fee is too much

        vm.prank(admin);
        vm.expectRevert(CuratioRebalancer.SwapPriceDeviation.selector);
        rebalancer.rebalanceLiquidity(-120, 120, liq, MAX, MAX);
    }

    /// While the hook charges its MEV penalty (10% fee) the rebalancer must not swap.

    // function test_swap_refusesDuringMevPenalty() public {
    //     _warmUp();
    //     _depositAndDeploy(100 ether);

    //     // ── Alice-কে উভয় টোকেন মিন্ট করুন (balance ঠিক করে) ──
    //     MockERC20(Currency.unwrap(poolKey.currency0)).mint(alice, 100 ether);
    //     MockERC20(Currency.unwrap(poolKey.currency1)).mint(alice, 100 ether);

    //     // ── Alice-কে PoolSwapTest-এ approve করান (allowance ঠিক করে) ──
    //     vm.startPrank(alice);
    //     MockERC20(Currency.unwrap(poolKey.currency0)).approve(address(swapRouter), type(uint256).max);
    //     MockERC20(Currency.unwrap(poolKey.currency1)).approve(address(swapRouter), type(uint256).max);
    //     vm.stopPrank();

    //     uint128 liq = rebalancer.quoteLiquidityForValue(-120, 120, 1 ether);

    //     vm.prank(admin);
    //     rebalancer.rebalanceLiquidity(-120, 120, liq, MAX, MAX);

    //     assertLt(hook.getCurrentFee(poolKey), 100000, "Setup invalid: Fee should be normal before MEV trigger");

    //     vm.startPrank(alice);
    //     // Alice UP (false): pays currency1, gets currency0
    //     swapRouter.swap(
    //         poolKey,
    //         SwapParams({
    //             zeroForOne: false,
    //             amountSpecified: -int256(10 ether),
    //             sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
    //         }),
    //         PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
    //         ""
    //     );

    //     // Alice DOWN (true) -> Reversal! This sets the MEV penalty flag.
    //     swapRouter.swap(
    //         poolKey,
    //         SwapParams({
    //             zeroForOne: true,
    //             amountSpecified: -int256(10 ether),
    //             sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
    //         }),
    //         PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
    //         ""
    //     );
    //     vm.stopPrank();

    //     uint24 currentFee = hook.getCurrentFee(poolKey);
    //     console2.log("Current Hook Fee:", currentFee);
    //     assertEq(currentFee, 100000, "Setup invalid: Hook did not enter MEV penalty mode");

    //     vm.prank(admin);
    //     vm.expectRevert(CuratioRebalancer.SwapPriceDeviation.selector);

    //     rebalancer.rebalanceLiquidity(-120, 120, liq, MAX, MAX);
    // }

    function test_swap_refusesDuringMevPenalty() public {
        // 1. Setup & Warmup
        _warmUp();
        _depositAndDeploy(100 ether);
        console2.log("--- Warmup and Deposit Completed ---");

        // 2. Mint tokens to Alice
        MockERC20(Currency.unwrap(poolKey.currency0)).mint(alice, 100 ether);
        MockERC20(Currency.unwrap(poolKey.currency1)).mint(alice, 100 ether);
        console2.log("Minted 100 ether tokens to Alice");

        // 3. Approve swap router
        vm.startPrank(alice);
        MockERC20(Currency.unwrap(poolKey.currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(poolKey.currency1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
        console2.log("Swap router approved by Alice");

        // 4. Initial Rebalance
        uint128 liq = rebalancer.quoteLiquidityForValue(-120, 120, 1 ether);
        vm.prank(admin);
        rebalancer.rebalanceLiquidity(-120, 120, liq, MAX, MAX);
        console2.log("Initial liquidity rebalanced with amount:", liq);

        // Verify we start from base fee
        uint24 initialFee = hook.getCurrentFee(poolKey);
        console2.log("Initial Hook Fee:", initialFee);
        assertEq(initialFee, 3000, "Initial fee should be BASE_FEE");

        // 5. Execute two opposing swaps in the SAME block → trigger sandwich / MEV penalty
        vm.startPrank(alice);
        console2.log("Executing Swap 1 (zeroForOne: false)...");

        // Swap 1
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: false, amountSpecified: -int256(1 ether), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        console2.log("Executing Swap 2 (direction reversal, zeroForOne: true)...");
        // Swap 2 (direction reversal)
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(1 ether), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        vm.stopPrank();

        // 6. Confirm we are in MEV penalty mode
        uint24 currentFee = hook.getCurrentFee(poolKey);
        console2.log("Current Hook Fee after MEV trigger:", currentFee);
        assertEq(currentFee, 100_000, "Hook should be in MEV penalty mode");

        // Diagnostic information before expected revert
        console2.log("--- Diagnostic Check Before Rebalance ---");
        console2.log("Block number:", block.number);
        console2.log("Block timestamp:", block.timestamp);

        // 7. Force a range change so rebalancer must swap → should revert during MEV penalty
        console2.log("Attempting rebalance liquidity during MEV penalty (expecting revert)...");
        vm.expectRevert(abi.encodeWithSelector(CuratioRebalancer.MevPenaltyActive.selector, uint24(100_000)));
        vm.prank(admin);
        rebalancer.rebalanceLiquidity(-180, 60, liq, MAX, MAX);
    }

    function test_swap_slippageCapOnNetPaymentStillApplies() public {
        _warmUp();
        _depositAndDeploy(100 ether);
        uint128 liq = rebalancer.quoteLiquidityForValue(-120, 120, 1 ether);

        // the position + the swap cost about 1 ether of asset; a cap far below that must revert
        vm.prank(admin);
        vm.expectRevert(CuratioRebalancer.SlippageExceeded.selector);
        rebalancer.rebalanceLiquidity(-120, 120, liq, 0.1 ether, 0.1 ether);
    }

    function test_swap_setMaxSwapSlippage_onlyAdminAndBounded() public {
        vm.prank(alice);
        vm.expectRevert();
        rebalancer.setMaxSwapSlippageBps(500);

        vm.prank(admin);
        vm.expectRevert(CuratioRebalancer.InvalidBps.selector);
        rebalancer.setMaxSwapSlippageBps(10_001);

        vm.prank(admin);
        rebalancer.setMaxSwapSlippageBps(500);
        assertEq(rebalancer.maxSwapSlippageBps(), 500);
    }
}
