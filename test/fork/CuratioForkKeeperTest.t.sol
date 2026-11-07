// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";

import {CuratioRebalancer} from "../../src/CuratioRebalancer.sol";
import {CuratioForkTest} from "./CuratioForkTest.t.sol";

/**
 * @notice Keeper path (Chainlink Automation -> performUpkeep) on the Unichain mainnet fork.
 *
 * Reuses the fixture of CuratioForkTest (real PoolManager + fresh Curatio stack + mock tokens).
 * Because it inherits that contract, the 16 original tests are inherited too. Run ONLY the keeper
 * tests with:
 *
 *   forge test --match-path test/fork/CuratioForkKeeperTest.t.sol --match-test test_keeper -vv
 */
contract CuratioForkKeeperTest is CuratioForkTest {
    using StateLibrary for IPoolManager;

    /// @dev Vault funded and deployed to the rebalancer, an external LP exists, then a big swap makes
    ///      the pool volatile (spot ~ -1900 ticks, TWAP still ~0). Returns checkUpkeep's performData.
    function _volatileSetup() internal returns (bytes memory performData) {
        _advance(130);
        vm.prank(alice);
        vault.deposit(100e18, alice);
        vault.deployToRebalancer(100e18);

        _seedLp(1e20);
        _swap(true, -10e18);

        bool needed;
        (needed, performData) = rebalancer.checkUpkeep("");
        assertTrue(needed, "volatile pool must request an upkeep");

        (int24 referenceTick, bool twapDiverged) = abi.decode(performData, (int24, bool));
        assertEq(int256(referenceTick), 0, "reference tick is the TWAP, not the manipulated spot");
        assertTrue(twapDiverged, "spot must have diverged from the TWAP");
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Access control
    // ═════════════════════════════════════════════════════════════════════════

    function test_keeper_onlyAutomationRegistry() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CuratioRebalancer.NotAutomationRegistry.selector, alice));
        rebalancer.performUpkeep(abi.encode(int24(0), false));
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Slippage caps are fail-safe (default 0)
    // ═════════════════════════════════════════════════════════════════════════

    function test_keeper_defaultCapsAreZero_soUpkeepReverts() public {
        bytes memory data = _volatileSetup();

        assertEq(rebalancer.keeperMaxPay0(), 0);
        assertEq(rebalancer.keeperMaxPay1(), 0);

        vm.prank(automation);
        vm.expectRevert(CuratioRebalancer.SlippageExceeded.selector);
        rebalancer.performUpkeep(data);

        assertEq(uint256(rebalancer.currentLiquidity()), 0, "nothing may have been deployed");
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Happy path: keeper opens a position around the TWAP
    // ═════════════════════════════════════════════════════════════════════════

    function test_keeper_withCaps_opensPositionAroundTwap() public {
        bytes memory data = _volatileSetup();
        rebalancer.setKeeperMaxPay(type(uint256).max, type(uint256).max);

        vm.prank(automation);
        rebalancer.performUpkeep(data);

        // twapDiverged => 3 tick spacings (60) on each side of the TWAP tick (0)
        assertEq(int256(rebalancer.currentTickLower()), -180);
        assertEq(int256(rebalancer.currentTickUpper()), 180);
        // first position falls back to defaultRebalanceAmount (liquidity units)
        assertEq(uint256(rebalancer.currentLiquidity()), 1e18);
        assertEq(rebalancer.lastRebalanceBlock(), block.number);

        // the position really exists in the real PoolManager
        bytes32 positionId = Position.calculatePositionKey(address(rebalancer), int24(-180), int24(180), bytes32(0));
        assertEq(uint256(POOL_MANAGER.getPositionLiquidity(poolId, positionId)), 1e18);

        // the LP is a tiny part of the vault, so the vault value must not move
        assertApproxEqRel(vault.totalAssets(), 100e18, 1e15);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Skips
    // ═════════════════════════════════════════════════════════════════════════

    function test_keeper_secondCallTooSoon_emitsSkipped() public {
        bytes memory data = _volatileSetup();
        rebalancer.setKeeperMaxPay(type(uint256).max, type(uint256).max);

        vm.prank(automation);
        rebalancer.performUpkeep(data);
        uint128 liq = rebalancer.currentLiquidity();

        vm.expectEmit(false, false, false, true, address(rebalancer));
        emit CuratioRebalancer.RebalanceSkipped("Too soon since last rebalance");
        vm.prank(automation);
        rebalancer.performUpkeep(data);

        assertEq(uint256(rebalancer.currentLiquidity()), uint256(liq));
    }

    function test_keeper_sameRangeAgain_emitsRangeUnchanged() public {
        bytes memory data = _volatileSetup();
        rebalancer.setKeeperMaxPay(type(uint256).max, type(uint256).max);

        vm.prank(automation);
        rebalancer.performUpkeep(data);
        uint256 blockOfFirst = rebalancer.lastRebalanceBlock();

        _advance(11); // past minBlocksBetweenRebalances (10)

        vm.expectEmit(false, false, false, true, address(rebalancer));
        emit CuratioRebalancer.RebalanceSkipped("Range unchanged");
        vm.prank(automation);
        rebalancer.performUpkeep(data);

        assertEq(rebalancer.lastRebalanceBlock(), blockOfFirst, "no rebalance must have run");
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Observation: keeper rebalances are not attributed to a strategist
    // ═════════════════════════════════════════════════════════════════════════

    /// @dev performUpkeep reports msg.sender (the automation registry) to the strategist registry.
    ///      That address is not a registered strategist, so the try/catch swallows the revert and no
    ///      strategist is credited. Documented here so a change in behaviour is noticed.
    function test_keeper_rebalanceIsNotAttributedToAnyStrategist() public {
        bytes memory data = _volatileSetup();
        rebalancer.setKeeperMaxPay(type(uint256).max, type(uint256).max);

        vm.prank(automation);
        rebalancer.performUpkeep(data);

        (,,,, uint256 rebalances,,) = registry.strategists(strategist);
        assertEq(rebalances, 0);
    }
}
