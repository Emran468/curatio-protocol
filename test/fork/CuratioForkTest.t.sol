// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {HookMiner} from "../../lib/uniswap-hooks/lib/v4-periphery/src/utils/HookMiner.sol";

import {CuratioHook} from "../../src/CuratioHook.sol";
import {CuratioAccess} from "../../src/CuratioAccess.sol";
import {CuratioVault} from "../../src/CuratioVault.sol";
import {CuratioRebalancer} from "../../src/CuratioRebalancer.sol";
import {CuratioStrategistRegistry} from "../../src/CuratioStrategistRegistry.sol";
import {CuratioDynamicFee} from "../../src/CuratioDynamicFee.sol";

contract ForkToken is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {
        _mint(msg.sender, 1e30);
    }
}

/**
 * @notice Unichain MAINNET fork test (chain id 130).
 *
 * What is real:  the Uniswap v4 PoolManager at 0x1F98...0004, its transient storage / unlock
 *                semantics, the Swap event, and the hook's chain guard (ChainRegistry).
 * What is local: CuratioHook + the whole Curatio stack (deployed fresh on the fork) and two
 *                mock ERC20s (so no whale accounts are needed).
 *
 * Run (PowerShell), needs [profile.fork] test = "test/fork" in foundry.toml:
 *   $env:UNICHAIN_RPC = "https://mainnet.unichain.org"
 *   $env:FOUNDRY_PROFILE = "fork"
 *   forge test --match-path test/fork/CuratioForkTest.t.sol -vv
 * Optional: $env:UNICHAIN_FORK_BLOCK = "<block>" to pin the fork.
 * Without UNICHAIN_RPC every test is skipped.
 *
 * Unichain makes 1-second blocks, so _advance(n) moves n blocks AND n seconds.
 */
contract CuratioForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // ── Unichain mainnet ──────────────────────────────────────────────────────
    uint256 constant UNICHAIN_CHAIN_ID = 130;
    IPoolManager constant POOL_MANAGER = IPoolManager(0x1F98400000000000000000000000000000000004);
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    // Single-sided LP range ABOVE the 1:1 start price => only token0 (the vault asset) is needed,
    // so the first position needs no swap.
    int24 constant LP_LOWER = 60;
    int24 constant LP_UPPER = 600;

    uint24 constant BASE_FEE = 3000;
    uint24 constant MID_FEE = 6000;
    uint24 constant HIGH_FEE = 15000;
    uint24 constant MEV_FEE = 100000;

    // ── Contracts ─────────────────────────────────────────────────────────────
    CuratioHook hook;
    CuratioAccess access;
    CuratioVault vault;
    CuratioRebalancer rebalancer;
    CuratioStrategistRegistry registry;
    CuratioDynamicFee feeModule;

    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest lpRouter;

    ForkToken token0;
    ForkToken token1;
    PoolKey key;
    PoolId poolId;

    address alice;
    address strategist;
    address feeRecipient;
    address automation;

    // ═════════════════════════════════════════════════════════════════════════
    //  Setup
    // ═════════════════════════════════════════════════════════════════════════

    function setUp() public {
        string memory rpc = vm.envOr("UNICHAIN_RPC", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);

        uint256 forkBlock = vm.envOr("UNICHAIN_FORK_BLOCK", uint256(0));
        if (forkBlock == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, forkBlock);
        require(block.chainid == UNICHAIN_CHAIN_ID, "RPC is not Unichain mainnet (130)");

        alice = makeAddr("alice");
        strategist = makeAddr("strategist");
        feeRecipient = makeAddr("feeRecipient");
        automation = makeAddr("automation");

        _deployTokensAndRouters();
        _deployHookAndPool();
        _deployProtocol();
    }

    function _deployTokensAndRouters() internal {
        ForkToken a = new ForkToken("Token A", "TKA");
        ForkToken b = new ForkToken("Token B", "TKB");
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);

        swapRouter = new PoolSwapTest(POOL_MANAGER);
        lpRouter = new PoolModifyLiquidityTest(POOL_MANAGER);

        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        token0.approve(address(lpRouter), type(uint256).max);
        token1.approve(address(lpRouter), type(uint256).max);
    }

    function _hookFlags() internal pure returns (uint160) {
        return uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );
    }

    function _deployHookAndPool() internal {
        // Constructor runs at a flag-encoded address, so no salt mining is needed in setUp.
        address hookAddr = address(uint160(_hookFlags()) ^ (uint160(0x4444) << 144));
        deployCodeTo("CuratioHook.sol:CuratioHook", abi.encode(POOL_MANAGER, address(this)), hookAddr);
        hook = CuratioHook(hookAddr);

        key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        poolId = key.toId();

        POOL_MANAGER.initialize(key, SQRT_PRICE_1_1);

        // Swap-event fee assertions below assume no protocol fee on the fresh pool.
        (,, uint24 protocolFee,) = POOL_MANAGER.getSlot0(poolId);
        require(protocolFee == 0, "Pool has a protocol fee: Swap-event fee assertions need adjusting");
    }

    function _deployProtocol() internal {
        access = new CuratioAccess(address(this));
        registry = new CuratioStrategistRegistry(address(this));

        // Vault <-> Rebalancer are circular: the vault is deployed right after the rebalancer.
        address predictedVault = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        rebalancer = new CuratioRebalancer(
            address(POOL_MANAGER), address(hook), predictedVault, address(this), 1e18, automation, 1e18
        );
        vault = new CuratioVault(IERC20(address(token0)), address(access), address(rebalancer), address(this), 0);
        require(address(vault) == predictedVault, "vault address mismatch");

        feeModule = new CuratioDynamicFee(address(this), address(vault), feeRecipient);
        vault.initializeFeeModule(address(feeModule));

        rebalancer.setManagedPool(key);
        rebalancer.setAsset(address(token0));
        rebalancer.setStrategistRegistry(address(registry));
        rebalancer.grantRole(rebalancer.STRATEGIST_ROLE(), strategist);

        registry.authorizeRebalancer(address(rebalancer));
        registry.registerStrategist(strategist, "alpha");

        access.setWhitelistedUser(alice, true);
        access.setWhitelistedUser(feeRecipient, true);

        token0.transfer(alice, 1_000e18);
        vm.prank(alice);
        token0.approve(address(vault), type(uint256).max);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Helpers
    // ═════════════════════════════════════════════════════════════════════════

    /// @dev Unichain: ~1s blocks, so blocks and seconds move together.
    function _advance(uint256 n) internal {
        vm.roll(block.number + n);
        vm.warp(block.timestamp + n);
    }

    function _seedLp(uint128 liq) internal {
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: int256(uint256(liq)),
                salt: bytes32(0)
            }),
            ""
        );
    }

    function _swap(bool zeroForOne, int256 amountSpecified) internal {
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @dev Reads the fee the REAL PoolManager charged from its own Swap event.
    function _swapAndGetFee(bool zeroForOne, int256 amountSpecified) internal returns (uint24 fee) {
        vm.recordLogs();
        _swap(zeroForOne, amountSpecified);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 sig = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(POOL_MANAGER) && logs[i].topics[0] == sig) {
                (,,,,, fee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                found = true;
            }
        }
        require(found, "no Swap event from PoolManager");
    }

    /// @dev alice deposits 100, manager deploys it all to the rebalancer, strategist opens a single-sided LP
    ///      worth ~90 (quote leaves 1% headroom). Oracle is warmed first (vault is strict about the TWAP).
    function _depositAndDeployLp() internal returns (uint128 liq) {
        _advance(130);
        vm.prank(alice);
        vault.deposit(100e18, alice);
        vault.deployToRebalancer(100e18);

        liq = rebalancer.quoteLiquidityForValue(LP_LOWER, LP_UPPER, 90e18);
        vm.prank(strategist);
        rebalancer.rebalanceLiquidity(LP_LOWER, LP_UPPER, liq, type(uint256).max, type(uint256).max);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  1. Environment + hook on the real PoolManager
    // ═════════════════════════════════════════════════════════════════════════

    function test_fork_environment_isUnichainMainnet() public view {
        assertEq(block.chainid, UNICHAIN_CHAIN_ID);
        assertGt(address(POOL_MANAGER).code.length, 0, "PoolManager has no code on this fork");

        assertEq(hook.deployedChainId(), UNICHAIN_CHAIN_ID);
        assertEq(hook.chainName(), "Unichain Mainnet");
        assertEq(uint256(hook.blockDecayWindow()), 300);

        (,,, bool isUnichain) = hook.getChainInfo();
        assertTrue(isUnichain);
    }

    function test_fork_hookRevertsOnWrongPoolManager() public {
        IPoolManager wrong = IPoolManager(address(0xBEEF));
        bytes memory args = abi.encode(wrong, address(this));
        (, bytes32 salt) = HookMiner.find(address(this), _hookFlags(), type(CuratioHook).creationCode, args);

        vm.expectRevert("Wrong PoolManager for this chain");
        new CuratioHook{salt: salt}(wrong, address(this));
    }

    function test_fork_hookInitialisedOnRealPoolManager() public view {
        (int24 lastTick, uint24 fee,,, bool initialized) = hook.getPoolState(key);
        assertTrue(initialized);
        assertEq(int256(lastTick), 0);
        assertEq(uint256(fee), uint256(BASE_FEE));

        (, uint16 cardinality, uint16 cardinalityNext) = hook.getOracleState(key);
        assertEq(uint256(cardinality), 100);
        assertEq(uint256(cardinalityNext), 100);
        assertFalse(hook.isOracleWarm(key, 120), "oracle must start cold");
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  2. Dynamic fees as charged by the real PoolManager
    // ═════════════════════════════════════════════════════════════════════════

    function test_fork_coldStart_chargesMidFee() public {
        _seedLp(1e20);
        uint24 fee = _swapAndGetFee(true, -1e15);
        assertEq(uint256(fee), uint256(MID_FEE), "cold oracle must charge MID_VOLATILE_FEE");
    }

    function test_fork_warmCalmPool_chargesBaseFee() public {
        _seedLp(1e20);
        _advance(130);
        uint24 fee = _swapAndGetFee(true, -1e15);
        assertEq(uint256(fee), uint256(BASE_FEE));
    }

    function test_fork_largeSwap_escalatesStoredFee_thenDecaysAfterWindow() public {
        _seedLp(1e20);
        _advance(130);

        _swap(true, -10e18); // ~ -1900 ticks

        (int24 lastTick, uint24 storedFee,,,) = hook.getPoolState(key);
        (, int24 poolTick,,) = POOL_MANAGER.getSlot0(poolId);
        assertEq(int256(lastTick), int256(poolTick), "hook tick must equal real pool tick");
        assertEq(uint256(storedFee), uint256(HIGH_FEE));
        assertEq(uint256(hook.getCurrentFee(key)), uint256(HIGH_FEE));

        _advance(uint256(hook.blockDecayWindow()));
        assertEq(uint256(hook.getCurrentFee(key)), uint256(BASE_FEE), "fee must decay after the Unichain window");
    }

    function test_fork_spotDeviation_triggersTwapMevPenalty() public {
        _seedLp(1e20);
        _advance(130);

        _swap(true, -10e18); // spot jumps ~ -1900 ticks, TWAP barely moves
        _advance(12);

        uint24 fee = _swapAndGetFee(false, -1e15);
        assertEq(uint256(fee), uint256(MEV_FEE), "spot far from TWAP must pay the MEV penalty");
    }

    function test_fork_sandwich_triggersPenaltyForRestOfBlock() public {
        _seedLp(1e20);
        _advance(130);

        _swap(true, -10e18); // front-run

        vm.expectEmit(true, false, false, false, address(hook));
        emit CuratioHook.SandwichDetected(poolId, 0, 0, 0, 0);
        _swap(false, -10e18); // back-run, same block, opposite direction, volume > 1 ether

        assertEq(uint256(hook.getCurrentFee(key)), uint256(MEV_FEE));

        uint24 fee = _swapAndGetFee(true, -1e15); // any further swap in the same block
        assertEq(uint256(fee), uint256(MEV_FEE), "rest of the block must pay the penalty");
    }

    function test_fork_oracleRecordsObservations_andTwapFollowsPrice() public {
        _seedLp(1e20);
        _advance(130);

        _swap(true, -10e18);
        _advance(30);
        _swap(true, -1e15);

        (uint16 index,,) = hook.getOracleState(key);
        assertEq(uint256(index), 2, "one observation per distinct timestamp");

        assertTrue(hook.isOracleWarm(key, 120));
        int24 twap = hook.getTwapTick(key, 120);
        assertLt(int256(twap), 0, "TWAP must reflect the downward move");
        assertGt(int256(twap), int256(TickMath.MIN_TICK));
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  3. Vault (ERC-4626) on top of the real PoolManager
    // ═════════════════════════════════════════════════════════════════════════

    function test_fork_vault_depositsHaltedUntilOracleWarm() public {
        assertEq(vault.maxDeposit(alice), 0, "cold oracle => no deposits");

        vm.prank(alice);
        vm.expectRevert();
        vault.deposit(100e18, alice);

        _advance(130);
        assertEq(vault.maxDeposit(alice), type(uint256).max);

        vm.prank(alice);
        assertGt(vault.deposit(100e18, alice), 0);
    }

    function test_fork_vault_depositRedeemRoundTrip() public {
        _advance(130);

        vm.startPrank(alice);
        uint256 shares = vault.deposit(100e18, alice);
        assertApproxEqAbs(vault.totalAssets(), 100e18, 1);
        uint256 out = vault.redeem(shares, alice, alice);
        vm.stopPrank();

        assertApproxEqAbs(out, 100e18, 2);
    }

    function test_fork_rebalancer_deploysLiquidityIntoRealPoolManager() public {
        uint128 liq = _depositAndDeployLp();

        // the position exists inside the REAL PoolManager, owned by the rebalancer
        bytes32 positionId = Position.calculatePositionKey(address(rebalancer), LP_LOWER, LP_UPPER, bytes32(0));
        assertEq(uint256(POOL_MANAGER.getPositionLiquidity(poolId, positionId)), uint256(liq));
        assertEq(uint256(rebalancer.currentLiquidity()), uint256(liq));

        // the hook mirrored it (keyed by the rebalancer, which PoolManager reports as `sender`)
        bytes32 hookKey = keccak256(abi.encodePacked(address(rebalancer), poolId, LP_LOWER, LP_UPPER));
        uint128 stored = hook.storedPositions(hookKey);
        assertEq(uint256(stored), uint256(liq));

        // deploying + opening the LP must not change what the vault is worth
        assertApproxEqAbs(vault.totalAssets(), 100e18, 1e3);

        // strategist attribution reached the registry
        (,,,, uint256 rebalances,,) = registry.strategists(strategist);
        assertEq(rebalances, 1);
    }

    function test_fork_vault_partialWithdrawUnwindsLp() public {
        uint128 liqBefore = _depositAndDeployLp();
        uint256 balBefore = token0.balanceOf(alice);

        vm.prank(alice);
        vault.withdraw(50e18, alice, alice);

        assertEq(token0.balanceOf(alice) - balBefore, 50e18, "alice must receive exactly what she asked for");

        uint128 liqAfter = rebalancer.currentLiquidity();
        assertLt(uint256(liqAfter), uint256(liqBefore), "LP must have been partially unwound");
        assertGt(uint256(liqAfter), 0, "LP must not be fully removed");

        assertApproxEqAbs(vault.totalAssets(), 50e18, 1e6);
    }

    function test_fork_vault_fullRedeemAfterRebalance() public {
        _depositAndDeployLp();

        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        uint256 out = vault.redeem(shares, alice, alice);

        assertApproxEqAbs(out, 100e18, 1e3);
        assertEq(uint256(rebalancer.currentLiquidity()), 0, "LP fully unwound");
        assertEq(vault.balanceOf(alice), 0);
    }

    function test_fork_harvest_chargesFeeOnDonation() public {
        _advance(130);
        vm.prank(alice);
        vault.deposit(100e18, alice);

        vault.harvest(); // first call only records the high-water mark

        token0.transfer(address(vault), 10e18); // counts as yield
        uint256 feeShares = vault.harvest();

        assertGt(feeShares, 0);
        assertEq(vault.balanceOf(feeRecipient), feeShares);
        // 10% of ~10e18 yield, within 0.1%
        assertApproxEqRel(feeModule.totalFeesCharged(), 1e18, 1e15);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  4. Automation signal
    // ═════════════════════════════════════════════════════════════════════════

    function test_fork_checkUpkeep_signalsVolatility() public {
        _advance(130);
        (bool needed,) = rebalancer.checkUpkeep("");
        assertFalse(needed, "calm pool must not trigger a rebalance");

        _seedLp(1e20);
        _swap(true, -10e18);

        (needed,) = rebalancer.checkUpkeep("");
        assertTrue(needed, "volatile pool must trigger a rebalance");
    }
}
