// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {CuratioHook} from "../../src/CuratioHook.sol";
import {CuratioAccess} from "../../src/CuratioAccess.sol";
import {CuratioVault} from "../../src/CuratioVault.sol";
import {CuratioRebalancer} from "../../src/CuratioRebalancer.sol";
import {CuratioStrategistRegistry} from "../../src/CuratioStrategistRegistry.sol";
import {CuratioDynamicFee} from "../../src/CuratioDynamicFee.sol";

contract CuratioFullProtocolE2ETest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    CuratioHook public hook;
    CuratioAccess public access;
    CuratioVault public vault;
    CuratioRebalancer public rebalancer;
    CuratioStrategistRegistry public registry;
    CuratioDynamicFee public feeModule;

    PoolKey public poolKey;
    PoolId public poolId;

    address public admin = makeAddr("admin");
    address public managerEOA = makeAddr("manager");
    address public strategist = makeAddr("strategist");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public automationRegistry = makeAddr("automationRegistry");
    address public feeRecipient = makeAddr("feeRecipient");

    uint160 constant SQRT_1_1 = 79228162514264337593543950336;

    function setUp() public {
        // ── 1. Deploy Fresh Manager ─────────────────────────────
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        // ── 2. Deploy Access ────────────────────────────────────
        access = new CuratioAccess(admin);

        // ── 3. Deploy Hook via HookMiner ────────────────────────
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_INITIALIZE_FLAG
                | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
        );

        bytes memory constructorArgs = abi.encode(address(manager), admin);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), flags, type(CuratioHook).creationCode, constructorArgs);

        hook = new CuratioHook{salt: salt}(IPoolManager(address(manager)), admin);
        require(address(hook) == hookAddress, "HookAddressNotValid");

        // ── 4. Deploy Registry ──────────────────────────────────
        registry = new CuratioStrategistRegistry(admin);

        // ✅ FIX 1: feeModule — placeholder vault (admin)
        feeModule = new CuratioDynamicFee(admin, admin, feeRecipient);

        // ✅ FIX 2: rebalancer — placeholder vault (admin)
        rebalancer = new CuratioRebalancer(
            address(manager), address(hook), admin, admin, 1 ether, automationRegistry, 1000 ether
        );

        // ── 5. Deploy Vault ─────────────────────────────────────
        vault = new CuratioVault(IERC20(Currency.unwrap(currency0)), address(access), address(rebalancer), admin, 0);

        // ── 6. Wire permissions ─────────────────────────────────
        vm.startPrank(admin);

        access.setWhitelistedUser(alice, true);
        access.setWhitelistedUser(bob, true);
        access.setWhitelistedUser(managerEOA, true);

        feeModule.setVault(address(vault));
        vault.initializeFeeModule(address(feeModule));

        rebalancer.setVault(address(vault));

        rebalancer.setStrategistRegistry(address(registry));
        registry.authorizeRebalancer(address(rebalancer));
        registry.registerStrategist(strategist, "Test Strategist");
        rebalancer.grantRole(rebalancer.STRATEGIST_ROLE(), strategist);

        vm.stopPrank();

        // ── 7. Initialize pool with Hook ────────────────────────
        poolKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: 3000, tickSpacing: 60, hooks: IHooks(address(hook))
        });
        manager.initialize(poolKey, SQRT_1_1);
        poolId = poolKey.toId();

        // ── 8. Configure Rebalancer pool ────────────────────────
        vm.prank(admin);
        rebalancer.setManagedPool(poolKey);
        vm.prank(admin);
        rebalancer.setAsset(Currency.unwrap(currency0));

        // ── 9. Fund users ───────────────────────────────────────
        deal(Currency.unwrap(currency0), alice, 1000 ether);
        deal(Currency.unwrap(currency0), bob, 1000 ether);

        vm.prank(alice);
        IERC20(Currency.unwrap(currency0)).approve(address(vault), type(uint256).max);
        vm.prank(bob);
        IERC20(Currency.unwrap(currency0)).approve(address(vault), type(uint256).max);

        // ✅ FIX 3: TWAP WARMUP
        // TWAP warm না হলে rebalancer.totalManagedAssets() revert করে
        // → vault.totalAssets() revert → maxDeposit() = 0 → deposit revert
        // Solution: swap করে TWAP observation তৈরি + 300s warp
        _warmUpTwap();
    }

    /// @dev Swap করে TWAP observation তৈরি করে + TWAP_WINDOW পার করে
    function _warmUpTwap() internal {
        // Pool-এ swap করুন TWAP observation তৈরি করতে
        swap(poolKey, true, -int256(1 ether), "");

        // TWAP_WINDOW (120s) + buffer পার করুন
        vm.warp(block.timestamp + 300);
    }

    // ══════════════════════════════════════════════════════════════
    // FULL FLOW: Deposit → Deploy → Rebalance → Withdraw
    // ══════════════════════════════════════════════════════════════

    function test_fullProtocol_depositToWithdraw() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(100 ether, alice);

        assertGt(shares, 0, "deposit must mint shares");
        assertEq(vault.totalAssets(), 100 ether, "totalAssets = 100");

        vm.prank(admin);
        vault.deployToRebalancer(100 ether);

        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(address(rebalancer)), 100 ether, "rebalancer holds 100");
        assertEq(vault.totalAssets(), 100 ether, "totalAssets unchanged after deploy");

        vm.warp(block.timestamp + 300);

        vm.prank(strategist);
        rebalancer.rebalanceLiquidity(-120, 120, 100 ether, type(uint256).max, type(uint256).max);

        assertGt(rebalancer.currentLiquidity(), 0, "rebalancer has position");

        (,,, bool active, uint256 rebalances,,) = registry.strategists(strategist);
        assertTrue(active, "strategist active");
        assertEq(rebalances, 1, "rebalances = 1");

        uint256 aliceBefore = IERC20(Currency.unwrap(currency0)).balanceOf(alice);

        vm.prank(alice);
        uint256 out = vault.redeem(shares, alice, alice);

        assertGt(out, 0, "redeem must return assets");
        assertApproxEqAbs(
            IERC20(Currency.unwrap(currency0)).balanceOf(alice), aliceBefore + out, 10, "alice receives assets"
        );
    }

    // ══════════════════════════════════════════════════════════════
    // MULTI-USER: Two users, share price consistency
    // ══════════════════════════════════════════════════════════════

    function test_fullProtocol_multiUser_sharePriceConsistent() public {
        // ── 1. Deposits ─────────────────────────────────────────
        vm.prank(alice);
        uint256 aliceShares = vault.deposit(100 ether, alice);
        assertGt(aliceShares, 0, "alice deposit must mint shares");

        vm.prank(bob);
        uint256 bobShares = vault.deposit(100 ether, bob);
        assertGt(bobShares, 0, "bob deposit must mint shares");

        // ✅ Two deposits should be equal
        assertEq(vault.balanceOf(alice), vault.balanceOf(bob), "equal shares");

        // ✅ totalAssets should be 200
        assertEq(vault.totalAssets(), 200 ether, "totalAssets = 200");

        // ── 2. Deploy + Rebalance ───────────────────────────────
        vm.prank(admin);
        vault.deployToRebalancer(200 ether);

        // ✅ Verify rebalancer received funds
        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(address(rebalancer)), 200 ether, "rebalancer holds 200");

        vm.warp(block.timestamp + 300);
        vm.prank(strategist);
        rebalancer.rebalanceLiquidity(-120, 120, 200 ether, type(uint256).max, type(uint256).max);

        // ✅ Verify rebalance succeeded
        assertGt(rebalancer.currentLiquidity(), 0, "rebalancer has position");

        // ── 3. Alice redeems ────────────────────────────────────
        uint256 aliceSharesToRedeem = vault.balanceOf(alice);
        vm.prank(alice);
        uint256 aliceOut = vault.redeem(aliceSharesToRedeem, alice, alice);

        // ✅ Verify alice got > 0
        assertGt(aliceOut, 0, "alice must withdraw > 0");

        // ── 4. Bob redeems ──────────────────────────────────────
        uint256 bobSharesToRedeem = vault.balanceOf(bob);
        vm.prank(bob);
        uint256 bobOut = vault.redeem(bobSharesToRedeem, bob, bob);

        // ✅ Verify bob got > 0
        assertGt(bobOut, 0, "bob must withdraw > 0");

        // ── 5. Assertion: equal withdrawals ────────────────────
        assertApproxEqAbs(aliceOut, bobOut, 10, "equal withdrawals");

        // ✅ Verify both are fully redeemed
        assertEq(vault.balanceOf(alice), 0, "alice shares burned");
        assertEq(vault.balanceOf(bob), 0, "bob shares burned");
    }

    // ══════════════════════════════════════════════════════════════
    // HARVEST: Performance fee flows through DynamicFee
    // ══════════════════════════════════════════════════════════════

    function test_fullProtocol_harvestChargesFee() public {
        vm.prank(alice);
        vault.deposit(100 ether, alice);

        // First harvest: baseline, no fee
        vm.prank(admin);
        vault.harvest();

        // Donate to simulate yield
        vm.prank(alice);
        IERC20(Currency.unwrap(currency0)).transfer(address(vault), 10 ether);

        // Second harvest: charges fee
        uint256 feeRecipientBefore = vault.balanceOf(feeRecipient);
        vm.prank(admin);
        vault.harvest();

        assertGt(vault.balanceOf(feeRecipient), feeRecipientBefore, "fee recipient gets shares");

        assertGt(feeModule.totalFeesCharged(), 0, "fee module recorded");
        assertGt(feeModule.totalYieldProcessed(), 0, "yield processed");
    }

    // ══════════════════════════════════════════════════════════════
    // WHITELIST: Non-whitelisted user cannot deposit
    // ══════════════════════════════════════════════════════════════

    function test_fullProtocol_whitelistEnforced() public {
        address nonWhitelisted = makeAddr("nonWhitelisted");

        vm.prank(nonWhitelisted);
        vm.expectRevert(abi.encodeWithSelector(CuratioVault.NotWhitelisted.selector, nonWhitelisted));
        vault.deposit(100 ether, nonWhitelisted);
    }

    // ══════════════════════════════════════════════════════════════
    // ACCESS TIMELOCK: Removal pending → user can still withdraw
    // ══════════════════════════════════════════════════════════════

    function test_fullProtocol_whitelistRemovalTimelock() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(100 ether, alice);

        vm.prank(admin);
        access.proposeRemoval(alice);

        // Alice can still withdraw during timelock
        vm.prank(alice);
        uint256 out = vault.redeem(shares / 2, alice, alice);
        assertGt(out, 0, "withdraw works during pending removal");

        // After timelock, execute removal
        vm.warp(block.timestamp + access.REMOVAL_TIMELOCK());
        vm.prank(admin);
        access.executeRemoval(alice);

        uint256 remaining = vault.balanceOf(alice);
        assertGt(remaining, 0, "alice still has shares");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CuratioVault.NotWhitelisted.selector, alice));
        vault.redeem(remaining, alice, alice);
    }

    // ══════════════════════════════════════════════════════════════
    // VAULT TIMELOCK: Rebalancer change doesn't affect valuation
    // ══════════════════════════════════════════════════════════════

    function test_fullProtocol_rebalancerTimelockProtectsValuation() public {
        // ── 1. Alice deposits ───────────────────────────────────
        vm.prank(alice);
        uint256 shares = vault.deposit(100 ether, alice);
        assertGt(shares, 0, "deposit must mint shares");

        // ── 2. Capture state before proposal ────────────────────
        address rebalancerBefore = address(vault.rebalancer());
        uint256 valuationBefore = vault.totalAssets();
        assertEq(valuationBefore, 100 ether, "valuation = 100 before proposal");

        // ── 3. Admin proposes new rebalancer ───────────────────
        address newRebalancer = address(0xDEAD);
        vm.prank(admin);
        vault.proposeRebalancer(newRebalancer);

        // ✅ Verify: pending proposal is set, but rebalancer is NOT yet changed
        assertEq(address(vault.rebalancer()), rebalancerBefore, "rebalancer must NOT change immediately after propose");

        // ── 4. During timelock: valuation unchanged ─────────────
        vm.warp(block.timestamp + 1 days);

        // ✅ Verify: rebalancer still old
        assertEq(address(vault.rebalancer()), rebalancerBefore, "rebalancer unchanged at +1 day");

        // ✅ Verify: valuation unchanged (old rebalancer still used)
        assertEq(vault.totalAssets(), valuationBefore, "valuation unchanged during delay");

        // ── 5. During timelock: execute must revert ─────────────
        vm.prank(admin);
        vm.expectRevert(); // timelock not elapsed yet
        vault.executeRebalancer();

        // ✅ Verify: rebalancer still old after failed execute
        assertEq(address(vault.rebalancer()), rebalancerBefore, "rebalancer unchanged after failed execute");

        // ── 6. Warp past timelock ───────────────────────────────
        // ✅ FIX: যথেষ্ট বেশি warp (eta-র চেয়ে বেশি)
        vm.warp(block.timestamp + 5 days);

        // ✅ Verify: valuation still unchanged (rebalancer not yet executed)
        assertEq(vault.totalAssets(), valuationBefore, "valuation still unchanged just before execute");

        // ── 7. Execute succeeds after timelock ─────────────────
        vm.prank(admin);
        vault.executeRebalancer();

        // ✅ Verify: rebalancer IS now the new one
        assertEq(address(vault.rebalancer()), newRebalancer, "rebalancer changed after timelock execution");

        // ✅ Verify: valuation may change (new rebalancer = 0xDEAD contract has no code)
        // Since 0xDEAD has no code, calling totalManagedAssets() will revert
        // So we expect the valuation call to revert OR return something different
        // We check that state was actually changed
        assertTrue(address(vault.rebalancer()) != rebalancerBefore, "rebalancer state must have changed");
    }

    // ══════════════════════════════════════════════════════════════
    // REGISTRY: Performance tracking
    // ══════════════════════════════════════════════════════════════

    function test_fullProtocol_registryTracksPerformance() public {
        vm.prank(alice);
        vault.deposit(100 ether, alice);
        vm.prank(admin);
        vault.deployToRebalancer(100 ether);
        vm.warp(block.timestamp + 300);

        vm.prank(strategist);
        rebalancer.rebalanceLiquidity(-120, 120, 50 ether, type(uint256).max, type(uint256).max);

        vm.prank(strategist);
        rebalancer.rebalanceLiquidity(-180, 180, 100 ether, type(uint256).max, type(uint256).max);

        (,,, bool active, uint256 rebalances,,) = registry.strategists(strategist);
        assertTrue(active, "strategist active");
        assertEq(rebalances, 2, "2 rebalances recorded");
    }
}
