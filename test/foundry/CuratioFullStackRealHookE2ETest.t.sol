// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CuratioHook} from "../../src/CuratioHook.sol";
import {CuratioRebalancer} from "../../src/CuratioRebalancer.sol";
import {CuratioVault} from "../../src/CuratioVault.sol";
import {CuratioAccess} from "../../src/CuratioAccess.sol";

/// @notice The whole stack with NO mocks: real CuratioHook (dynamic fee + TWAP + sandwich
///         detection) on a real PoolManager, real CuratioRebalancer, real CuratioVault.
///         The "other" token is donated to the rebalancer to stand in for the swap step
///         that is not implemented yet.
contract CuratioFullStackRealHookE2ETest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    uint256 constant SCALE = 1e6; // = 10 ** _decimalsOffset() in CuratioVault
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

        // Deploy the real hook at an address whose low bits equal its permission flags.
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        address hookAddr = address(flags ^ (uint160(0x4444) << 144));
        deployCodeTo("CuratioHook.sol:CuratioHook", abi.encode(manager, hookOwner), hookAddr);
        hook = CuratioHook(hookAddr);

        (poolKey,) = initPool(currency0, currency1, hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, TickMath.getSqrtPriceAtTick(0));
        poolId = poolKey.toId();

        // base liquidity so third-party swaps have something to trade against
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

    /// The hook's TWAP needs `DEFAULT_TWAP_WINDOW` seconds of history before it reports a price.
    function _warmUp() internal {
        vm.warp(block.timestamp + 1000);
    }

    function _depositAndDeploy(uint256 amt) internal {
        vm.prank(alice);
        vault.deposit(amt, alice);
        vm.prank(admin);
        vault.deployToRebalancer(amt);
    }

    function _storedLiquidity(int24 lo, int24 hi) internal view returns (uint128) {
        bytes32 key = keccak256(abi.encodePacked(address(rebalancer), poolId, lo, hi));
        (uint128 liq) = hook.storedPositions(key);
        return liq;
    }

    // ── cold start ───────────────────────────────────────────────────────

    /// FINDING: right after a pool is initialised the hook has no TWAP history, so the strict
    /// valuation makes the vault refuse deposits (instead of mispricing shares).
    function test_realHook_coldStart_vaultDepositsHaltUntilTwapWarm() public {
        assertFalse(hook.isOracleWarm(poolKey, 120));

        vm.prank(alice);
        vm.expectRevert(CuratioRebalancer.TwapUnavailable.selector);
        vault.deposit(10 ether, alice);

        _warmUp();
        assertTrue(hook.isOracleWarm(poolKey, 120));

        vm.prank(alice);
        uint256 shares = vault.deposit(10 ether, alice);
        assertEq(shares, 10 ether * SCALE);
    }

    function test_realHook_afterWarmup_totalAssetsMatchesDeposit() public {
        _warmUp();
        vm.prank(alice);
        vault.deposit(100 ether, alice);
        assertEq(vault.totalAssets(), 100 ether);
        assertEq(rebalancer.totalManagedAssets(), 0);
    }

    // ── rebalance through the hook's liquidity callbacks ─────────────────

    function test_realHook_rebalanceWorksAndHookTracksPosition() public {
        _warmUp();
        _depositAndDeploy(100 ether);
        other.transfer(address(rebalancer), 100 ether); // stand-in for swap output

        vm.startPrank(admin);
        rebalancer.rebalanceLiquidity(-120, 120, 1000 ether, MAX, MAX);
        assertEq(_storedLiquidity(-120, 120), 1000 ether, "hook must see the rebalancer's position");

        rebalancer.rebalanceLiquidity(-240, 240, 1000 ether, MAX, MAX);
        vm.stopPrank();

        assertEq(_storedLiquidity(-120, 120), 0, "old range must be empty in the hook's books");
        assertEq(_storedLiquidity(-240, 240), 1000 ether);
        assertApproxEqAbs(vault.totalAssets(), 200 ether, 20, "moving ranges must not change reported assets");
    }

    // ── manipulation resistance with the REAL oracle ─────────────────────

    /// A big same-block swap moves spot price a lot; the vault's reported assets must not move.
    function test_realHook_valuationIgnoresSameBlockSwap() public {
        _warmUp();
        _depositAndDeploy(100 ether);
        other.transfer(address(rebalancer), 100 ether);
        vm.prank(admin);
        rebalancer.rebalanceLiquidity(-120, 120, 1000 ether, MAX, MAX);

        uint256 before = vault.totalAssets();

        swap(poolKey, true, -int256(10 ether), ""); // ~20% price impact

        (,,,, bool init) = hook.getPoolState(poolKey);
        assertTrue(init);
        assertEq(vault.totalAssets(), before, "reported assets must follow the TWAP, not spot");
    }

    // ── keeper path driven by the real hook's signals ────────────────────

    function test_realHook_bigSwap_triggersUpkeep_andKeeperRebalances() public {
        _warmUp();
        other.transfer(address(rebalancer), 1000 ether);
        asset.transfer(address(rebalancer), 1000 ether);
        vm.prank(admin);
        rebalancer.setKeeperMaxPay(MAX, MAX);
        vm.roll(block.number + 20);

        (bool needed,) = rebalancer.checkUpkeep("");
        assertFalse(needed, "calm pool: no upkeep needed");

        swap(poolKey, true, -int256(10 ether), ""); // spot tick jumps far from the TWAP

        bytes memory performData;
        (needed, performData) = rebalancer.checkUpkeep("");
        assertTrue(needed, "hook signals (fee + TWAP divergence) must trigger upkeep");
        (int24 refTick, bool diverged) = abi.decode(performData, (int24, bool));
        assertTrue(diverged);
        assertEq(refTick, 0, "reference tick is the TWAP, not the manipulated spot");

        vm.prank(automationRegistry);
        rebalancer.performUpkeep(performData);

        // diverged => 3 spacings each side of the TWAP-based tick
        assertEq(rebalancer.currentTickLower(), -180);
        assertEq(rebalancer.currentTickUpper(), 180);
        assertEq(rebalancer.currentLiquidity(), 1000 ether);
    }

    // ── hook MEV penalty vs the rebalancer ───────────────────────────────

    /// A sandwich-looking pattern makes the hook charge MEV_PENALTY_FEE for swaps. Liquidity
    /// operations (the rebalancer's only pool interaction) must be unaffected.
    function test_realHook_sandwichPenaltyDoesNotBlockRebalance() public {
        _warmUp();
        other.transfer(address(rebalancer), 1000 ether);
        asset.transfer(address(rebalancer), 1000 ether);

        swap(poolKey, true, -int256(5 ether), "");
        swap(poolKey, false, -int256(5 ether), ""); // reversal with volume above the threshold

        // the penalty lives only in the flagged block and is no longer stored in the pool state
        assertEq(hook.getCurrentFee(poolKey), hook.MEV_PENALTY_FEE(), "hook must have flagged the sandwich");
        (, uint24 storedFee,,,) = hook.getPoolState(poolKey);
        assertLt(uint256(storedFee), uint256(hook.MEV_PENALTY_FEE()), "the penalty must not be stored");

        vm.prank(admin);
        rebalancer.rebalanceLiquidity(-120, 120, 100 ether, MAX, MAX);
        assertEq(rebalancer.currentLiquidity(), 100 ether);
        assertEq(_storedLiquidity(-120, 120), 100 ether);
    }
}
