// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CuratioRebalancer} from "../../src/CuratioRebalancer.sol";

/// @notice CuratioRebalancer against the REAL v4 PoolManager (no mocks).
contract CuratioRebalancerRealPMTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    uint160 constant SQRT_1_1 = 79228162514264337593543950336;
    uint256 constant MAX = type(uint256).max;

    CuratioRebalancer rebalancer;
    PoolKey poolKey;
    PoolId poolId;

    address admin = makeAddr("admin");
    address vault = makeAddr("vault");
    address hook = makeAddr("hook");
    address automationRegistry = makeAddr("automationRegistry");

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        poolId = poolKey.toId();
        manager.initialize(poolKey, SQRT_1_1);

        rebalancer = new CuratioRebalancer(
            address(manager), hook, vault, admin, 1 ether, automationRegistry, 1000 ether
        );
        vm.prank(admin);
        rebalancer.setManagedPool(poolKey);
    }

    // ── helpers ──────────────────────────────────────────────────────────

    /// Simulates "tokens arrived from the vault" (fund flow is not implemented yet).
    function _fundRebalancer(uint256 amt) internal {
        IERC20(Currency.unwrap(currency0)).transfer(address(rebalancer), amt);
        IERC20(Currency.unwrap(currency1)).transfer(address(rebalancer), amt);
    }

    function _liq(int24 lower, int24 upper) internal view returns (uint128) {
        bytes32 id = Position.calculatePositionKey(address(rebalancer), lower, upper, bytes32(0));
        return StateLibrary.getPositionLiquidity(manager, poolId, id);
    }

    function _rebalance(int24 lo, int24 hi, uint128 liq) internal {
        vm.prank(admin);
        rebalancer.rebalanceLiquidity(lo, hi, liq, MAX, MAX);
    }

    // ── fund flow ────────────────────────────────────────────────────────

    function test_realPM_revertsWhenRebalancerHasNoTokens() public {
        vm.prank(admin);
        vm.expectRevert();
        rebalancer.rebalanceLiquidity(-120, 120, 1000 ether, MAX, MAX);
    }

    function test_realPM_extraTokensDoNotBreakRebalance() public {
        _fundRebalancer(1000 ether);
        IERC20(Currency.unwrap(currency0)).transfer(address(rebalancer), 5 ether);

        _rebalance(-120, 120, 100 ether);
        assertEq(_liq(-120, 120), 100 ether);
    }

    // ── core behaviour ───────────────────────────────────────────────────

    function test_realPM_firstRebalance_addsRealLiquidity() public {
        _fundRebalancer(1000 ether);
        _rebalance(-120, 120, 100 ether);

        assertEq(_liq(-120, 120), 100 ether, "liquidity not added to pool");
        assertEq(rebalancer.currentTickLower(), -120);
        assertEq(rebalancer.currentTickUpper(), 120);
        assertEq(rebalancer.currentLiquidity(), 100 ether);
    }

    function test_realPM_fullMove_emptiesOldRange() public {
        _fundRebalancer(1000 ether);
        _rebalance(-120, 120, 100 ether);
        _rebalance(-240, 240, 100 ether);

        assertEq(_liq(-120, 120), 0, "old range should be empty");
        assertEq(_liq(-240, 240), 100 ether, "new range should hold liquidity");
    }

    /// FIXED: previously 60 ether stayed behind. Now ALL old liquidity is removed.
    function test_realPM_resizeMove_leavesNothingInOldRange() public {
        _fundRebalancer(1000 ether);
        _rebalance(-120, 120, 100 ether);
        _rebalance(-240, 240, 40 ether); // shrink while moving

        assertEq(_liq(-120, 120), 0, "no liquidity may remain in old range");
        assertEq(_liq(-240, 240), 40 ether);
        assertEq(rebalancer.currentLiquidity(), 40 ether);
    }

    function test_realPM_sameRangeResize_works() public {
        _fundRebalancer(1000 ether);
        _rebalance(-120, 120, 100 ether);
        _rebalance(-120, 120, 150 ether);

        assertEq(_liq(-120, 120), 150 ether);
        assertEq(rebalancer.currentLiquidity(), 150 ether);
    }

    // ── validation (now enforced by the contract itself) ─────────────────

    function test_realPM_zeroLiquidityReverts() public {
        _fundRebalancer(1000 ether);
        vm.prank(admin);
        vm.expectRevert(CuratioRebalancer.InvalidLiquidity.selector);
        rebalancer.rebalanceLiquidity(-120, 120, 0, MAX, MAX);
    }

    function test_realPM_unalignedTicksRevert() public {
        _fundRebalancer(1000 ether);
        vm.prank(admin);
        vm.expectRevert(CuratioRebalancer.TickNotAligned.selector);
        rebalancer.rebalanceLiquidity(-121, 120, 100 ether, MAX, MAX);
    }

    function test_realPM_outOfBoundsTicksRevert() public {
        _fundRebalancer(1000 ether);
        vm.prank(admin);
        vm.expectRevert(CuratioRebalancer.InvalidTickRange.selector);
        rebalancer.rebalanceLiquidity(-887280, 120, 100 ether, MAX, MAX); // below usable MIN for spacing 60
    }

    // ── slippage ─────────────────────────────────────────────────────────

    function test_realPM_slippageCapReverts() public {
        _fundRebalancer(1000 ether);
        vm.prank(admin);
        vm.expectRevert(CuratioRebalancer.SlippageExceeded.selector);
        rebalancer.rebalanceLiquidity(-120, 120, 100 ether, 1, 1); // needs ~0.6 ether each
    }

    function test_realPM_slippageCapAllowsReasonableAmount() public {
        _fundRebalancer(1000 ether);
        vm.prank(admin);
        rebalancer.rebalanceLiquidity(-120, 120, 100 ether, 1 ether, 1 ether);
        assertEq(_liq(-120, 120), 100 ether);
    }

    // ── setManagedPool guard ─────────────────────────────────────────────

    function test_realPM_setManagedPoolRevertsWhilePositionActive() public {
        _fundRebalancer(1000 ether);
        _rebalance(-120, 120, 100 ether);

        vm.prank(admin);
        vm.expectRevert(CuratioRebalancer.PositionStillActive.selector);
        rebalancer.setManagedPool(poolKey);
    }

    // ── keeper path ──────────────────────────────────────────────────────

    function test_realPM_performUpkeep_negativeTick() public {
        _fundRebalancer(1000 ether);
        vm.prank(admin);
        rebalancer.setKeeperMaxPay(MAX, MAX);
        vm.roll(block.number + rebalancer.minBlocksBetweenRebalances());

        vm.prank(automationRegistry);
        rebalancer.performUpkeep(abi.encode(int24(-70), false));

        // floor(-70/60)*60 = -120 ; range = -120 +- 120
        assertEq(rebalancer.currentTickLower(), -240);
        assertEq(rebalancer.currentTickUpper(), 0);
        assertEq(_liq(-240, 0), 1000 ether);
    }

    function test_realPM_performUpkeep_revertsWithDefaultZeroCaps() public {
        _fundRebalancer(1000 ether);
        vm.roll(block.number + rebalancer.minBlocksBetweenRebalances());

        vm.prank(automationRegistry);
        vm.expectRevert(CuratioRebalancer.SlippageExceeded.selector);
        rebalancer.performUpkeep(abi.encode(int24(0), false));
    }

    function test_realPM_performUpkeep_skipsWhenRangeUnchanged() public {
        _fundRebalancer(1000 ether);
        vm.prank(admin);
        rebalancer.setKeeperMaxPay(MAX, MAX);
        vm.roll(block.number + rebalancer.minBlocksBetweenRebalances());

        vm.prank(automationRegistry);
        rebalancer.performUpkeep(abi.encode(int24(0), false));
        uint256 firstBlock = rebalancer.lastRebalanceBlock();

        vm.roll(block.number + rebalancer.minBlocksBetweenRebalances());
        vm.prank(automationRegistry);
        rebalancer.performUpkeep(abi.encode(int24(0), false)); // same range again

        assertEq(rebalancer.lastRebalanceBlock(), firstBlock, "identical range must not re-execute");
    }

    function test_realPM_performUpkeep_keepsExistingLiquiditySize() public {
        _fundRebalancer(1000 ether);
        _rebalance(-120, 120, 100 ether);
        vm.prank(admin);
        rebalancer.setKeeperMaxPay(MAX, MAX);
        vm.roll(block.number + rebalancer.minBlocksBetweenRebalances());

        vm.prank(automationRegistry);
        rebalancer.performUpkeep(abi.encode(int24(600), false));

        // keeper must reuse 100 ether, NOT the 1000 ether default
        assertEq(rebalancer.currentLiquidity(), 100 ether);
        assertEq(_liq(-120, 120), 0);
    }
}
