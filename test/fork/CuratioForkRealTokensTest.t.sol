// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";

import {CuratioHook} from "../../src/CuratioHook.sol";
import {CuratioAccess} from "../../src/CuratioAccess.sol";
import {CuratioVault} from "../../src/CuratioVault.sol";
import {CuratioRebalancer} from "../../src/CuratioRebalancer.sol";

interface IWETH {
    function deposit() external payable;
}

/**
 * @notice Unichain MAINNET fork test with the REAL tokens: native USDC (6 decimals) and WETH (18).
 *
 * Why it matters: the mock-token tests use 18/18 decimals at a 1:1 price. Here the pool is
 * USDC (token0) / WETH (token1) at ~ $3000 per ETH, so ticks are ~196k, the raw price is ~3.3e8, the vault
 * has 6 + 6 = 12 share decimals, and real token contracts (USDC is a proxy) move the funds.
 *
 * The pool is NEW (our hook, dynamic fee), so no existing Uniswap pool or liquidity is touched.
 *
 * Run (PowerShell, [profile.fork] test = "test/fork"):
 *   $env:FOUNDRY_PROFILE = "fork"
 *   forge test --match-path test/fork/CuratioForkRealTokensTest.t.sol -vv
 */
contract CuratioForkRealTokensTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 constant UNICHAIN_CHAIN_ID = 130;
    IPoolManager constant POOL_MANAGER = IPoolManager(0x1F98400000000000000000000000000000000004);

    // WETH is the OP-stack predeploy (digits only, so no checksum issue).
    address constant WETH = 0x4200000000000000000000000000000000000006;

    /// @dev ~ $2999 per ETH: 1.0001^196260 ~ 3.33e8 raw WETH per raw USDC (multiple of tickSpacing 60).
    int24 constant START_TICK = 196260;
    /// @dev Range ABOVE the start tick => single-sided USDC (the vault asset), no swap needed.
    int24 constant LP_LOWER = 196320;
    int24 constant LP_UPPER = 197520;

    uint24 constant BASE_FEE = 3000;
    uint24 constant MID_FEE = 6000;
    uint24 constant HIGH_FEE = 15000;
    uint24 constant MEV_FEE = 100000;

    address usdc;
    address weth;

    CuratioHook hook;
    CuratioAccess access;
    CuratioVault vault;
    CuratioRebalancer rebalancer;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest lpRouter;

    PoolKey key;
    PoolId poolId;

    address alice;
    address strategist;

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

        _loadAndCheckTokens();
        _fund();
        _deployHookAndPool();
        _deployStack();
    }

    function _loadAndCheckTokens() internal {
        // parseAddress is case-insensitive, so a checksum typo cannot break compilation.
        usdc = vm.parseAddress("0x078D782b760474a361dDA0AF3839290b0EF57AD6");
        weth = WETH;

        require(usdc.code.length > 0 && weth.code.length > 0, "token has no code on this fork");
        // fail loudly if an address is wrong
        require(keccak256(bytes(IERC20Metadata(usdc).symbol())) == keccak256("USDC"), "usdc address is not USDC");
        require(IERC20Metadata(usdc).decimals() == 6, "USDC must have 6 decimals");
        require(keccak256(bytes(IERC20Metadata(weth).symbol())) == keccak256("WETH"), "weth address is not WETH");
        require(IERC20Metadata(weth).decimals() == 18, "WETH must have 18 decimals");
        require(usdc < weth, "expected USDC to sort as currency0");
    }

    function _fund() internal {
        // If forge-std cannot find USDC's balance slot, deal() reverts here with a clear message.
        deal(usdc, address(this), 2_000_000e6);
        deal(usdc, alice, 100_000e6);

        vm.deal(address(this), 200 ether);
        IWETH(weth).deposit{value: 100 ether}();
    }

    function _hookFlags() internal pure returns (uint160) {
        return uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );
    }

    function _deployHookAndPool() internal {
        swapRouter = new PoolSwapTest(POOL_MANAGER);
        lpRouter = new PoolModifyLiquidityTest(POOL_MANAGER);

        IERC20(usdc).approve(address(swapRouter), type(uint256).max);
        IERC20(weth).approve(address(swapRouter), type(uint256).max);
        IERC20(usdc).approve(address(lpRouter), type(uint256).max);
        IERC20(weth).approve(address(lpRouter), type(uint256).max);

        address hookAddr = address(uint160(_hookFlags()) ^ (uint160(0x4444) << 144));
        deployCodeTo("CuratioHook.sol:CuratioHook", abi.encode(POOL_MANAGER, address(this)), hookAddr);
        hook = CuratioHook(hookAddr);

        key = PoolKey({
            currency0: Currency.wrap(usdc),
            currency1: Currency.wrap(weth),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        poolId = key.toId();

        POOL_MANAGER.initialize(key, TickMath.getSqrtPriceAtTick(START_TICK));

        (,, uint24 protocolFee,) = POOL_MANAGER.getSlot0(poolId);
        require(protocolFee == 0, "Pool has a protocol fee: Swap-event fee assertions need adjusting");
    }

    function _deployStack() internal {
        access = new CuratioAccess(address(this));

        address predictedVault = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        rebalancer = new CuratioRebalancer(
            address(POOL_MANAGER), address(hook), predictedVault, address(this), 1e6, makeAddr("automation"), 1e12
        );
        vault = new CuratioVault(IERC20(usdc), address(access), address(rebalancer), address(this), 0);
        require(address(vault) == predictedVault, "vault address mismatch");

        rebalancer.setManagedPool(key);
        rebalancer.setAsset(usdc);
        rebalancer.grantRole(rebalancer.STRATEGIST_ROLE(), strategist);

        access.setWhitelistedUser(alice, true);
        vm.prank(alice);
        IERC20(usdc).approve(address(vault), type(uint256).max);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Helpers
    // ═════════════════════════════════════════════════════════════════════════

    function _advance(uint256 n) internal {
        vm.roll(block.number + n);
        vm.warp(block.timestamp + n);
    }

    /// @dev Full range. At this price L = 1e15 needs ~ 54,800 USDC and ~ 18.3 WETH.
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

    /// @dev alice deposits 10,000 USDC, the manager deploys it, the strategist opens a single-sided
    ///      USDC position worth ~9,000 (the quote leaves 1% headroom).
    function _depositAndDeployLp() internal returns (uint128 liq) {
        _advance(130);
        vm.prank(alice);
        vault.deposit(10_000e6, alice);
        vault.deployToRebalancer(10_000e6);

        liq = rebalancer.quoteLiquidityForValue(LP_LOWER, LP_UPPER, 9_000e6);
        vm.prank(strategist);
        rebalancer.rebalanceLiquidity(LP_LOWER, LP_UPPER, liq, type(uint256).max, type(uint256).max);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  1. Tokens, decimals, pool
    // ═════════════════════════════════════════════════════════════════════════

    function test_real_tokensAndPoolAreSetUpCorrectly() public view {
        assertEq(Currency.unwrap(key.currency0), usdc);
        assertEq(Currency.unwrap(key.currency1), weth);

        (, int24 poolTick,,) = POOL_MANAGER.getSlot0(poolId);
        assertEq(int256(poolTick), int256(START_TICK));

        (int24 lastTick,,,, bool initialized) = hook.getPoolState(key);
        assertTrue(initialized);
        assertEq(int256(lastTick), int256(START_TICK));

        // USDC has 6 decimals; the vault adds a 6-decimal share offset
        assertEq(uint256(vault.decimals()), 12);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  2. Dynamic fees on a USDC/WETH pool (ticks ~196k)
    // ═════════════════════════════════════════════════════════════════════════

    function test_real_fees_coldThenWarmThenEscalation() public {
        _seedLp(1e15);

        // cold oracle
        uint24 fee = _swapAndGetFee(false, -1e15); // 0.001 WETH in
        assertEq(uint256(fee), uint256(MID_FEE), "cold oracle must charge MID_VOLATILE_FEE");

        // warm + calm
        _advance(130);
        fee = _swapAndGetFee(false, -1e15);
        assertEq(uint256(fee), uint256(BASE_FEE), "warm calm pool must charge BASE_FEE");

        // 5 WETH into ~18 WETH of liquidity: thousands of ticks
        _swap(false, -5e18);
        (int24 lastTick, uint24 storedFee,,,) = hook.getPoolState(key);
        (, int24 poolTick,,) = POOL_MANAGER.getSlot0(poolId);
        assertEq(int256(lastTick), int256(poolTick));
        assertGt(int256(poolTick), int256(START_TICK) + 500, "price must have moved far");
        assertEq(uint256(storedFee), uint256(HIGH_FEE));
        assertEq(uint256(hook.getCurrentFee(key)), uint256(HIGH_FEE));
    }

    function test_real_spotDeviation_triggersTwapMevPenalty() public {
        _seedLp(1e15);
        _advance(130);

        _swap(false, -5e18);
        _advance(12);

        uint24 fee = _swapAndGetFee(true, -1e6); // 1 USDC in, the other direction
        assertEq(uint256(fee), uint256(MEV_FEE), "spot far from TWAP must pay the MEV penalty");
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  3. Vault with a 6-decimal asset
    // ═════════════════════════════════════════════════════════════════════════

    function test_real_vault_usdcDepositRedeemRoundTrip() public {
        _advance(130);

        vm.startPrank(alice);
        uint256 shares = vault.deposit(10_000e6, alice);
        // first deposit: 1e6 share units per asset unit (offset 6)
        assertEq(shares, 10_000e6 * 1e6);
        assertApproxEqAbs(vault.totalAssets(), 10_000e6, 1);

        uint256 out = vault.redeem(shares, alice, alice);
        vm.stopPrank();

        assertApproxEqAbs(out, 10_000e6, 2);
    }

    function test_real_vault_totalAssetsValuesWethAtTwap() public {
        _advance(130);
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        uint256 before = vault.totalAssets();
        IERC20(weth).transfer(address(rebalancer), 1e18); // 1 WETH sits idle in the rebalancer
        uint256 afterAssets = vault.totalAssets();

        // TWAP == START_TICK (no swaps), so 1 WETH is worth 1e18 / 1.0001^196260 raw USDC
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(START_TICK);
        uint256 expected = FullMath.mulDiv(FullMath.mulDiv(1e18, 1 << 96, sqrtP), 1 << 96, sqrtP);

        assertGt(expected, 2_500e6, "1 WETH should be worth > 2,500 USDC");
        assertLt(expected, 3_500e6, "1 WETH should be worth < 3,500 USDC");
        assertApproxEqAbs(afterAssets - before, expected, 2);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  4. Rebalancer / LP with real tokens
    // ═════════════════════════════════════════════════════════════════════════

    function test_real_rebalancer_opensSingleSidedUsdcPosition() public {
        uint128 liq = _depositAndDeployLp();

        bytes32 positionId = Position.calculatePositionKey(address(rebalancer), LP_LOWER, LP_UPPER, bytes32(0));
        assertEq(uint256(POOL_MANAGER.getPositionLiquidity(poolId, positionId)), uint256(liq));

        bytes32 hookKey = keccak256(abi.encodePacked(address(rebalancer), poolId, LP_LOWER, LP_UPPER));
        uint128 stored = hook.storedPositions(hookKey);
        assertEq(uint256(stored), uint256(liq));

        assertApproxEqAbs(vault.totalAssets(), 10_000e6, 10);
        // single-sided: the LP took USDC only, so the rebalancer holds no WETH
        assertEq(IERC20(weth).balanceOf(address(rebalancer)), 0);
    }

    function test_real_vault_partialWithdrawThenFullRedeem() public {
        uint128 liqBefore = _depositAndDeployLp();
        uint256 balBefore = IERC20(usdc).balanceOf(alice);

        vm.prank(alice);
        vault.withdraw(5_000e6, alice, alice);
        assertEq(IERC20(usdc).balanceOf(alice) - balBefore, 5_000e6, "exact USDC out");

        uint128 liqMid = rebalancer.currentLiquidity();
        assertLt(uint256(liqMid), uint256(liqBefore), "LP partially unwound");
        assertGt(uint256(liqMid), 0);

        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        uint256 out = vault.redeem(shares, alice, alice);

        assertApproxEqAbs(out, 5_000e6, 50);
        assertEq(uint256(rebalancer.currentLiquidity()), 0, "LP fully unwound");
    }
}
