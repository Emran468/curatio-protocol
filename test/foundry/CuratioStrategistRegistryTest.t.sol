// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../src/CuratioStrategistRegistry.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

contract CuratioStrategistRegistryTest is Test {
    CuratioStrategistRegistry public registry;
    
    address public admin = address(0x123);
    address public strategist1 = address(0x456);
    address public strategist2 = address(0x789);
    address public unauthorized = address(0xabc);
    
    PoolId public poolId1 = PoolId.wrap(bytes32(uint256(1)));
    PoolId public poolId2 = PoolId.wrap(bytes32(uint256(2)));
    PoolId public poolId3 = PoolId.wrap(bytes32(uint256(3)));

    // ─── Events ────────────────────────────────────────────────────────────────
    event StrategistRegistered(address indexed strategist, string name);
    event StrategistDeactivated(address indexed strategist);
    event StrategistReactivated(address indexed strategist);
    event PoolAssignedToStrategist(address indexed strategist, PoolId indexed poolId);
    event PoolUnassignedFromStrategist(address indexed strategist, PoolId indexed poolId);
    event PerformanceRecorded(address indexed strategist, uint256 rebalanceCount, uint256 feesGenerated);

    function setUp() public {
        registry = new CuratioStrategistRegistry(admin);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ১. REGISTRATION TESTS
    // ═══════════════════════════════════════════════════════════════════════

    function test_registerStrategist() public {
        vm.startPrank(admin);
        
        vm.expectEmit(true, true, false, true);
        emit StrategistRegistered(strategist1, "Strategist One");
        
        registry.registerStrategist(strategist1, "Strategist One");
        
        (string memory name, address addr, uint256 registeredAt, bool active, 
         uint256 rebalances, uint256 fees, uint256 lastBlock) = registry.strategists(strategist1);
        
        assertEq(addr, strategist1, "Wrong strategist address");
        assertEq(name, "Strategist One", "Wrong name");
        assertTrue(active, "Should be active");
        assertEq(registeredAt, block.timestamp, "Wrong registration time");
        assertEq(rebalances, 0, "Should have 0 rebalances");
        assertEq(fees, 0, "Should have 0 fees");
        assertEq(lastBlock, block.number, "Wrong last active block");
        
        assertTrue(registry.isRegisteredStrategist(strategist1), "Should be registered");
        
        address[] memory all = registry.getAllStrategists();
        assertEq(all.length, 1, "Should have 1 strategist");
        assertEq(all[0], strategist1, "Wrong strategist in list");
        
        vm.stopPrank();
    }

    function test_registerStrategist_revertsIfAlreadyRegistered() public {
        vm.startPrank(admin);
        registry.registerStrategist(strategist1, "Strategist One");
        
        vm.expectRevert(abi.encodeWithSelector(
            CuratioStrategistRegistry.AlreadyRegistered.selector,
            strategist1
        ));
        registry.registerStrategist(strategist1, "Strategist One");
        
        vm.stopPrank();
    }

    function test_registerStrategist_revertsOnZeroAddress() public {
        vm.startPrank(admin);
        
        vm.expectRevert(abi.encodeWithSelector(
            CuratioStrategistRegistry.ZeroAddress.selector
        ));
        registry.registerStrategist(address(0), "Zero Strategist");
        
        vm.stopPrank();
    }

    function test_registerStrategist_onlyRegistrarRole() public {
        vm.startPrank(unauthorized);
        vm.expectRevert();
        registry.registerStrategist(strategist1, "Strategist One");
        vm.stopPrank();
        
        assertFalse(registry.isRegisteredStrategist(strategist1), "Should not be registered");
    }

    function test_registerMultipleStrategists() public {
        vm.startPrank(admin);
        
        registry.registerStrategist(strategist1, "Strategist One");
        registry.registerStrategist(strategist2, "Strategist Two");
        
        address[] memory all = registry.getAllStrategists();
        assertEq(all.length, 2, "Should have 2 strategists");
        assertEq(all[0], strategist1, "First should be strategist1");
        assertEq(all[1], strategist2, "Second should be strategist2");
        
        (, , , bool active1, , , ) = registry.strategists(strategist1);
        (, , , bool active2, , , ) = registry.strategists(strategist2);
        assertTrue(active1, "Strategist1 should be active");
        assertTrue(active2, "Strategist2 should be active");
        
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ২. DEACTIVATION TESTS
    // ═══════════════════════════════════════════════════════════════════════

    function test_deactivateStrategist() public {
        vm.startPrank(admin);
        registry.registerStrategist(strategist1, "Strategist One");
        
        (, , , bool activeBefore, , , ) = registry.strategists(strategist1);
        assertTrue(activeBefore, "Should be active before deactivation");
        
        vm.expectEmit(true, true, false, true);
        emit StrategistDeactivated(strategist1);
        
        registry.deactivateStrategist(strategist1);
        
        (, , , bool activeAfter, , , ) = registry.strategists(strategist1);
        assertFalse(activeAfter, "Should be inactive after deactivation");
        
        vm.stopPrank();
    }

    function test_deactivateStrategist_revertsIfNotRegistered() public {
        vm.startPrank(admin);
        
        vm.expectRevert(abi.encodeWithSelector(
            CuratioStrategistRegistry.NotRegistered.selector,
            strategist1
        ));
        registry.deactivateStrategist(strategist1);
        
        vm.stopPrank();
    }

    function test_deactivateStrategist_onlyRegistrarRole() public {
        vm.startPrank(admin);
        registry.registerStrategist(strategist1, "Strategist One");
        vm.stopPrank();
        
        vm.startPrank(unauthorized);
        vm.expectRevert();
        registry.deactivateStrategist(strategist1);
        vm.stopPrank();
        
        (, , , bool active, , , ) = registry.strategists(strategist1);
        assertTrue(active, "Should still be active");
    }

    function test_reactivateStrategist() public {
        vm.startPrank(admin);
        registry.registerStrategist(strategist1, "Strategist One");
        registry.deactivateStrategist(strategist1);
        
        (, , , bool activeBefore, , , ) = registry.strategists(strategist1);
        assertFalse(activeBefore, "Should be inactive before reactivation");
        
        vm.expectEmit(true, true, false, true);
        emit StrategistReactivated(strategist1);
        
        registry.reactivateStrategist(strategist1);
        
        (, , , bool activeAfter, , , ) = registry.strategists(strategist1);
        assertTrue(activeAfter, "Should be active after reactivation");
        
        vm.stopPrank();
    }

    function test_reactivateStrategist_revertsIfNotRegistered() public {
        vm.startPrank(admin);
        
        vm.expectRevert(abi.encodeWithSelector(
            CuratioStrategistRegistry.NotRegistered.selector,
            strategist1
        ));
        registry.reactivateStrategist(strategist1);
        
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ৩. POOL ASSIGNMENT TESTS
    // ═══════════════════════════════════════════════════════════════════════

    function test_assignPoolToStrategist() public {
        vm.startPrank(admin);
        registry.registerStrategist(strategist1, "Strategist One");
        
        vm.expectEmit(true, true, false, true);
        emit PoolAssignedToStrategist(strategist1, poolId1);
        
        registry.assignPoolToStrategist(strategist1, poolId1);
        
        address assigned = registry.poolStrategist(poolId1);
        assertEq(assigned, strategist1, "Wrong strategist for pool");
        
        PoolId[] memory pools = registry.getStrategistPools(strategist1);
        assertEq(pools.length, 1, "Should have 1 pool");
        assertEq(PoolId.unwrap(pools[0]), PoolId.unwrap(poolId1), "Wrong pool ID");
        
        vm.stopPrank();
    }

    function test_assignPoolToStrategist_revertsIfStrategistNotRegistered() public {
        vm.startPrank(admin);
        
        vm.expectRevert(abi.encodeWithSelector(
            CuratioStrategistRegistry.NotRegistered.selector,
            strategist1
        ));
        registry.assignPoolToStrategist(strategist1, poolId1);
        
        vm.stopPrank();
    }

    function test_assignPoolToStrategist_revertsIfPoolAlreadyAssigned() public {
        vm.startPrank(admin);
        registry.registerStrategist(strategist1, "Strategist One");
        registry.registerStrategist(strategist2, "Strategist Two");
        registry.assignPoolToStrategist(strategist1, poolId1);
        
        vm.expectRevert(abi.encodeWithSelector(
            CuratioStrategistRegistry.PoolAlreadyAssigned.selector,
            poolId1
        ));
        registry.assignPoolToStrategist(strategist2, poolId1);
        
        vm.stopPrank();
    }

    function test_assignPoolToStrategist_onlyRegistrarRole() public {
        vm.startPrank(admin);
        registry.registerStrategist(strategist1, "Strategist One");
        vm.stopPrank();
        
        vm.startPrank(unauthorized);
        vm.expectRevert();
        registry.assignPoolToStrategist(strategist1, poolId1);
        vm.stopPrank();
        
        address assigned = registry.poolStrategist(poolId1);
        assertEq(assigned, address(0), "Pool should not be assigned");
    }

    function test_assignMultiplePoolsToStrategist() public {
        vm.startPrank(admin);
        registry.registerStrategist(strategist1, "Strategist One");
        
        registry.assignPoolToStrategist(strategist1, poolId1);
        registry.assignPoolToStrategist(strategist1, poolId2);
        
        PoolId[] memory pools = registry.getStrategistPools(strategist1);
        assertEq(pools.length, 2, "Should have 2 pools");
        assertEq(PoolId.unwrap(pools[0]), PoolId.unwrap(poolId1), "First pool wrong");
        assertEq(PoolId.unwrap(pools[1]), PoolId.unwrap(poolId2), "Second pool wrong");
        
        assertEq(registry.poolStrategist(poolId1), strategist1, "Pool1 wrong strategist");
        assertEq(registry.poolStrategist(poolId2), strategist1, "Pool2 wrong strategist");
        
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ৪. REASSIGN POOL TESTS
    // ═══════════════════════════════════════════════════════════════════════

    function test_reassignPool() public {
        vm.startPrank(admin);
        registry.registerStrategist(strategist1, "Strategist One");
        registry.registerStrategist(strategist2, "Strategist Two");
        registry.assignPoolToStrategist(strategist1, poolId1);
        
        assertEq(registry.poolStrategist(poolId1), strategist1, "Pool should be with strategist1");
        PoolId[] memory pools1 = registry.getStrategistPools(strategist1);
        assertEq(pools1.length, 1, "Strategist1 should have 1 pool");
        
        vm.expectEmit(true, true, false, true);
        emit PoolUnassignedFromStrategist(strategist1, poolId1);
        vm.expectEmit(true, true, false, true);
        emit PoolAssignedToStrategist(strategist2, poolId1);
        
        registry.reassignPool(poolId1, strategist2);
        
        assertEq(registry.poolStrategist(poolId1), strategist2, "Pool should be with strategist2");
        
        PoolId[] memory pools2 = registry.getStrategistPools(strategist2);
        assertEq(pools2.length, 1, "Strategist2 should have 1 pool");
        assertEq(PoolId.unwrap(pools2[0]), PoolId.unwrap(poolId1), "Wrong pool in strategist2 list");
        
        vm.stopPrank();
    }

    function test_reassignPool_revertsIfNewStrategistNotRegistered() public {
        vm.startPrank(admin);
        registry.registerStrategist(strategist1, "Strategist One");
        registry.assignPoolToStrategist(strategist1, poolId1);
        
        vm.expectRevert(abi.encodeWithSelector(
            CuratioStrategistRegistry.NotRegistered.selector,
            strategist2
        ));
        registry.reassignPool(poolId1, strategist2);
        
        vm.stopPrank();
    }

    function test_reassignPool_onlyRegistrarRole() public {
        vm.startPrank(admin);
        registry.registerStrategist(strategist1, "Strategist One");
        registry.registerStrategist(strategist2, "Strategist Two");
        registry.assignPoolToStrategist(strategist1, poolId1);
        vm.stopPrank();
        
        vm.startPrank(unauthorized);
        vm.expectRevert();
        registry.reassignPool(poolId1, strategist2);
        vm.stopPrank();
        
        assertEq(registry.poolStrategist(poolId1), strategist1, "Pool should still be with strategist1");
    }

    // ✅ ফিক্সড টেস্ট
    function test_reassignPool_removesFromOldList() public {
        vm.startPrank(admin);
        registry.registerStrategist(strategist1, "Strategist One");
        registry.registerStrategist(strategist2, "Strategist Two");
        
        registry.assignPoolToStrategist(strategist1, poolId1);
        registry.assignPoolToStrategist(strategist1, poolId2);
        
        PoolId[] memory poolsBefore = registry.getStrategistPools(strategist1);
        assertEq(poolsBefore.length, 2, "Strategist1 should have 2 pools");
        
        registry.reassignPool(poolId1, strategist2);
        
        PoolId[] memory poolsAfter = registry.getStrategistPools(strategist1);
        assertEq(poolsAfter.length, 1, "Strategist1 should have 1 pool after");
        assertEq(PoolId.unwrap(poolsAfter[0]), PoolId.unwrap(poolId2), "Remaining pool should be poolId2");
        
        PoolId[] memory poolsNew = registry.getStrategistPools(strategist2);
        assertEq(poolsNew.length, 1, "Strategist2 should have 1 pool");
        assertEq(PoolId.unwrap(poolsNew[0]), PoolId.unwrap(poolId1), "Pool should be poolId1");
        
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ৫. PERFORMANCE RECORDING TESTS
    // ═══════════════════════════════════════════════════════════════════════

    function test_recordRebalanceExecuted() public {
        vm.startPrank(admin);
        registry.registerStrategist(strategist1, "Strategist One");
        registry.authorizeRebalancer(address(this));
        vm.stopPrank();
        
        (, , , , uint256 rebalancesBefore, , ) = registry.strategists(strategist1);
        assertEq(rebalancesBefore, 0, "Should have 0 rebalances before");
        
        vm.expectEmit(true, true, false, true);
        emit PerformanceRecorded(strategist1, 1, 0);
        
        registry.recordRebalanceExecuted(strategist1);
        
        (, , , , uint256 rebalancesAfter, , uint256 lastBlock) = registry.strategists(strategist1);
        assertEq(rebalancesAfter, 1, "Should have 1 rebalance after");
        assertEq(lastBlock, block.number, "Last active block should be current");
    }

    function test_recordRebalanceExecuted_accumulates() public {
        vm.startPrank(admin);
        registry.registerStrategist(strategist1, "Strategist One");
        registry.authorizeRebalancer(address(this));
        vm.stopPrank();
        
        for (uint256 i = 1; i <= 3; i++) {
            registry.recordRebalanceExecuted(strategist1);
            (, , , , uint256 rebalances, , ) = registry.strategists(strategist1);
            assertEq(rebalances, i, string(abi.encodePacked("Should have ", vm.toString(i), " rebalances")));
        }
    }

    function test_recordRebalanceExecuted_revertsIfStrategistNotRegistered() public {
        vm.startPrank(admin);
        registry.authorizeRebalancer(address(this));
        vm.stopPrank();
        
        vm.expectRevert(abi.encodeWithSelector(
            CuratioStrategistRegistry.NotRegistered.selector,
            strategist1
        ));
        registry.recordRebalanceExecuted(strategist1);
    }

    // ✅ ফিক্সড টেস্ট
    function test_recordRebalanceExecuted_revertsIfStrategistInactive() public {
        vm.startPrank(admin);
        registry.registerStrategist(strategist1, "Strategist One");
        registry.deactivateStrategist(strategist1);
        registry.authorizeRebalancer(address(this));
        vm.stopPrank();
        
        vm.expectRevert(abi.encodeWithSelector(
            CuratioStrategistRegistry.StrategistInactive.selector,  // ✅ সঠিক error
            strategist1
        ));
        registry.recordRebalanceExecuted(strategist1);
    }

    function test_recordRebalanceExecuted_onlyRebalancerRole() public {
        vm.startPrank(admin);
        registry.registerStrategist(strategist1, "Strategist One");
        vm.stopPrank();
        
        vm.startPrank(unauthorized);
        vm.expectRevert();
        registry.recordRebalanceExecuted(strategist1);
        vm.stopPrank();
        
        (, , , , uint256 rebalances, , ) = registry.strategists(strategist1);
        assertEq(rebalances, 0, "Should have 0 rebalances");
    }

    function test_recordFeesGenerated() public {
        vm.startPrank(admin);
        registry.registerStrategist(strategist1, "Strategist One");
        registry.authorizeRebalancer(address(this));
        vm.stopPrank();
        
        (, , , , , uint256 feesBefore, ) = registry.strategists(strategist1);
        assertEq(feesBefore, 0, "Should have 0 fees before");
        
        vm.expectEmit(true, true, false, true);
        emit PerformanceRecorded(strategist1, 0, 1000);
        
        registry.recordFeesGenerated(strategist1, 1000);
        
        (, , , , , uint256 feesAfter, ) = registry.strategists(strategist1);
        assertEq(feesAfter, 1000, "Should have 1000 fees after");
    }

    function test_recordFeesGenerated_accumulates() public {
        vm.startPrank(admin);
        registry.registerStrategist(strategist1, "Strategist One");
        registry.authorizeRebalancer(address(this));
        vm.stopPrank();
        
        registry.recordFeesGenerated(strategist1, 1000);
        registry.recordFeesGenerated(strategist1, 500);
        registry.recordFeesGenerated(strategist1, 250);
        
        (, , , , , uint256 fees, ) = registry.strategists(strategist1);
        assertEq(fees, 1750, "Should have 1750 total fees");
    }

    function test_recordFeesGenerated_revertsIfStrategistNotRegistered() public {
        vm.startPrank(admin);
        registry.authorizeRebalancer(address(this));
        vm.stopPrank();
        
        vm.expectRevert(abi.encodeWithSelector(
            CuratioStrategistRegistry.NotRegistered.selector,
            strategist1
        ));
        registry.recordFeesGenerated(strategist1, 1000);
    }

    function test_recordFeesGenerated_onlyRebalancerRole() public {
        vm.startPrank(admin);
        registry.registerStrategist(strategist1, "Strategist One");
        vm.stopPrank();
        
        vm.startPrank(unauthorized);
        vm.expectRevert();
        registry.recordFeesGenerated(strategist1, 1000);
        vm.stopPrank();
        
        (, , , , , uint256 fees, ) = registry.strategists(strategist1);
        assertEq(fees, 0, "Should have 0 fees");
    }

    // ✅ ফিক্সড টেস্ট
    function test_performanceRecordingAfterDeactivation() public {
        vm.startPrank(admin);
        registry.registerStrategist(strategist1, "Strategist One");
        registry.deactivateStrategist(strategist1);
        registry.authorizeRebalancer(address(this));
        vm.stopPrank();
        
        vm.expectRevert(abi.encodeWithSelector(
            CuratioStrategistRegistry.StrategistInactive.selector,  // ✅ সঠিক error
            strategist1
        ));
        registry.recordRebalanceExecuted(strategist1);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ৬. AUTHORIZE REBALANCER TESTS
    // ═══════════════════════════════════════════════════════════════════════

    function test_authorizeRebalancer() public {
        vm.startPrank(admin);
        
        bool hasRoleBefore = registry.hasRole(registry.REBALANCER_ROLE(), address(this));
        assertFalse(hasRoleBefore, "Should not have role before");
        
        registry.authorizeRebalancer(address(this));
        
        bool hasRoleAfter = registry.hasRole(registry.REBALANCER_ROLE(), address(this));
        assertTrue(hasRoleAfter, "Should have role after");
        
        vm.stopPrank();
    }

    function test_authorizeRebalancer_onlyAdminRole() public {
        vm.startPrank(unauthorized);
        vm.expectRevert();
        registry.authorizeRebalancer(address(this));
        vm.stopPrank();
        
        bool hasRole = registry.hasRole(registry.REBALANCER_ROLE(), address(this));
        assertFalse(hasRole, "Should not have role");
    }

    function test_authorizeMultipleRebalancers() public {
        vm.startPrank(admin);
        
        address rebalancer1 = address(0x111);
        address rebalancer2 = address(0x222);
        
        registry.authorizeRebalancer(rebalancer1);
        registry.authorizeRebalancer(rebalancer2);
        
        assertTrue(registry.hasRole(registry.REBALANCER_ROLE(), rebalancer1), "Rebalancer1 should have role");
        assertTrue(registry.hasRole(registry.REBALANCER_ROLE(), rebalancer2), "Rebalancer2 should have role");
        
        vm.stopPrank();
    }

    function test_revokeRebalancer() public {
        vm.startPrank(admin);
        registry.authorizeRebalancer(address(this));
        
        bool hasRoleBefore = registry.hasRole(registry.REBALANCER_ROLE(), address(this));
        assertTrue(hasRoleBefore, "Should have role before");
        
        registry.revokeRebalancer(address(this));
        
        bool hasRoleAfter = registry.hasRole(registry.REBALANCER_ROLE(), address(this));
        assertFalse(hasRoleAfter, "Should not have role after");
        
        vm.stopPrank();
    }

    function test_revokeRebalancer_onlyAdminRole() public {
        vm.startPrank(admin);
        registry.authorizeRebalancer(address(this));
        vm.stopPrank();
        
        vm.startPrank(unauthorized);
        vm.expectRevert();
        registry.revokeRebalancer(address(this));
        vm.stopPrank();
        
        bool hasRole = registry.hasRole(registry.REBALANCER_ROLE(), address(this));
        assertTrue(hasRole, "Should still have role");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ৭. VIEW FUNCTIONS TESTS
    // ═══════════════════════════════════════════════════════════════════════

    function test_getAllStrategists() public {
        vm.startPrank(admin);
        
        address[] memory strategists = new address[](3);
        strategists[0] = strategist1;
        strategists[1] = strategist2;
        strategists[2] = address(0x999);
        
        for (uint256 i = 0; i < strategists.length; i++) {
            registry.registerStrategist(strategists[i], string(abi.encodePacked("Strategist ", vm.toString(i))));
        }
        
        address[] memory all = registry.getAllStrategists();
        assertEq(all.length, strategists.length, "Wrong number of strategists");
        
        for (uint256 i = 0; i < all.length; i++) {
            assertEq(all[i], strategists[i], string(abi.encodePacked("Wrong strategist at index ", vm.toString(i))));
        }
        
        vm.stopPrank();
    }

    function test_getStrategistPools() public {
        vm.startPrank(admin);
        registry.registerStrategist(strategist1, "Strategist One");
        
        PoolId[] memory expectedPools = new PoolId[](3);
        expectedPools[0] = poolId1;
        expectedPools[1] = poolId2;
        expectedPools[2] = poolId3;
        
        for (uint256 i = 0; i < expectedPools.length; i++) {
            registry.assignPoolToStrategist(strategist1, expectedPools[i]);
        }
        
        PoolId[] memory pools = registry.getStrategistPools(strategist1);
        assertEq(pools.length, expectedPools.length, "Wrong number of pools");
        
        for (uint256 i = 0; i < pools.length; i++) {
            assertEq(PoolId.unwrap(pools[i]), PoolId.unwrap(expectedPools[i]), 
                string(abi.encodePacked("Wrong pool at index ", vm.toString(i))));
        }
        
        vm.stopPrank();
    }

    function test_getStrategistProfile() public {
        vm.startPrank(admin);
        registry.registerStrategist(strategist1, "Strategist One");
        registry.authorizeRebalancer(address(this));
        vm.stopPrank();
        
        registry.recordRebalanceExecuted(strategist1);
        registry.recordFeesGenerated(strategist1, 1000);
        
        CuratioStrategistRegistry.StrategistProfile memory profile = registry.getStrategistProfile(strategist1);
        
        assertEq(profile.strategistAddress, strategist1, "Wrong address");
        assertEq(profile.name, "Strategist One", "Wrong name");
        assertEq(profile.registeredAt, block.timestamp, "Wrong registration time");
        assertTrue(profile.active, "Should be active");
        assertEq(profile.totalRebalancesExecuted, 1, "Wrong rebalance count");
        assertEq(profile.totalFeesGeneratedForVault, 1000, "Wrong fees");
        assertEq(profile.lastActiveBlock, block.number, "Wrong last active block");
    }

    function test_getStrategistProfile_revertsIfNotRegistered() public {
        vm.startPrank(admin);
        
        vm.expectRevert(abi.encodeWithSelector(
            CuratioStrategistRegistry.NotRegistered.selector,
            strategist1
        ));
        registry.getStrategistProfile(strategist1);
        
        vm.stopPrank();
    }

    function test_poolStrategist() public {
        vm.startPrank(admin);
        registry.registerStrategist(strategist1, "Strategist One");
        registry.assignPoolToStrategist(strategist1, poolId1);
        vm.stopPrank();
        
        address assigned = registry.poolStrategist(poolId1);
        assertEq(assigned, strategist1, "Wrong strategist for pool");
        
        address notAssigned = registry.poolStrategist(poolId2);
        assertEq(notAssigned, address(0), "Should be address(0) for unassigned pool");
    }

    function test_isRegisteredStrategist() public {
        vm.startPrank(admin);
        registry.registerStrategist(strategist1, "Strategist One");
        vm.stopPrank();
        
        assertTrue(registry.isRegisteredStrategist(strategist1), "Should be registered");
        assertFalse(registry.isRegisteredStrategist(strategist2), "Should not be registered");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ৮. EDGE CASE TESTS
    // ═══════════════════════════════════════════════════════════════════════

    function test_deactivateAndReactivateWithPools() public {
        vm.startPrank(admin);
        registry.registerStrategist(strategist1, "Strategist One");
        registry.assignPoolToStrategist(strategist1, poolId1);
        
        registry.deactivateStrategist(strategist1);
        
        PoolId[] memory pools = registry.getStrategistPools(strategist1);
        assertEq(pools.length, 1, "Should still have pool assignment");
        assertEq(registry.poolStrategist(poolId1), strategist1, "Pool still assigned");
        
        registry.reactivateStrategist(strategist1);
        
        (, , , bool active, , , ) = registry.strategists(strategist1);
        assertTrue(active, "Should be active again");
        
        vm.stopPrank();
    }

    function test_samePoolMultipleAssignments() public {
        vm.startPrank(admin);
        registry.registerStrategist(strategist1, "Strategist One");
        
        registry.assignPoolToStrategist(strategist1, poolId1);
        
        vm.expectRevert(abi.encodeWithSelector(
            CuratioStrategistRegistry.PoolAlreadyAssigned.selector,
            poolId1
        ));
        registry.assignPoolToStrategist(strategist1, poolId1);
        
        vm.stopPrank();
    }

function test_constructor_revertsOnZeroAdmin() public {
    vm.expectRevert(CuratioStrategistRegistry.ZeroAddress.selector);
    new CuratioStrategistRegistry(address(0));
}

function test_recordFeesGenerated_revertsIfStrategistInactive() public {
    vm.startPrank(admin);
    registry.registerStrategist(strategist1, "Strategist One");
    registry.deactivateStrategist(strategist1);
    registry.authorizeRebalancer(address(this));
    vm.stopPrank();

    vm.expectRevert(abi.encodeWithSelector(
        CuratioStrategistRegistry.StrategistInactive.selector,
        strategist1
    ));
    registry.recordFeesGenerated(strategist1, 100);
}

    function test_bulkReassignPools_movesAllPoolsToNewStrategist() public {
        vm.startPrank(admin);
        registry.registerStrategist(strategist1, "Strategist One");
        registry.registerStrategist(strategist2, "Strategist Two");
        registry.assignPoolToStrategist(strategist1, poolId1);
        registry.assignPoolToStrategist(strategist1, poolId2);
        registry.assignPoolToStrategist(strategist1, poolId3);

        registry.bulkReassignPools(strategist1, strategist2, type(uint256).max);
        vm.stopPrank();

        assertEq(registry.poolStrategist(poolId1), strategist2);
        assertEq(registry.poolStrategist(poolId2), strategist2);
        assertEq(registry.poolStrategist(poolId3), strategist2);

        PoolId[] memory oldPools = registry.getStrategistPools(strategist1);
        assertEq(oldPools.length, 0);

        PoolId[] memory newPools = registry.getStrategistPools(strategist2);
        assertEq(newPools.length, 3);
    }

    function test_bulkReassignPools_respectsMaxCount() public {
        vm.startPrank(admin);
        registry.registerStrategist(strategist1, "Strategist One");
        registry.registerStrategist(strategist2, "Strategist Two");
        registry.assignPoolToStrategist(strategist1, poolId1);
        registry.assignPoolToStrategist(strategist1, poolId2);
        registry.assignPoolToStrategist(strategist1, poolId3);

        registry.bulkReassignPools(strategist1, strategist2, 2);
        vm.stopPrank();

        PoolId[] memory oldPools = registry.getStrategistPools(strategist1);
        assertEq(oldPools.length, 1);

        PoolId[] memory newPools = registry.getStrategistPools(strategist2);
        assertEq(newPools.length, 2);
    }

    function test_bulkReassignPools_emptyListSucceedsNoOp() public {
        vm.startPrank(admin);
        registry.registerStrategist(strategist1, "Strategist One");
        registry.registerStrategist(strategist2, "Strategist Two");

        registry.bulkReassignPools(strategist1, strategist2, type(uint256).max);
        vm.stopPrank();

        assertEq(registry.getStrategistPools(strategist2).length, 0);
    }

    function test_bulkReassignPools_revertsIfOldStrategistNotRegistered() public {
        vm.startPrank(admin);
        registry.registerStrategist(strategist2, "Strategist Two");

        vm.expectRevert(abi.encodeWithSelector(
            CuratioStrategistRegistry.NotRegistered.selector,
            strategist1
        ));
        registry.bulkReassignPools(strategist1, strategist2, type(uint256).max);
        vm.stopPrank();
    }

    function test_bulkReassignPools_revertsIfNewStrategistNotRegistered() public {
        vm.startPrank(admin);
        registry.registerStrategist(strategist1, "Strategist One");

        vm.expectRevert(abi.encodeWithSelector(
            CuratioStrategistRegistry.NotRegistered.selector,
            strategist2
        ));
        registry.bulkReassignPools(strategist1, strategist2, type(uint256).max);
        vm.stopPrank();
    }

    function test_bulkReassignPools_revertsIfSameStrategist() public {
        vm.startPrank(admin);
        registry.registerStrategist(strategist1, "Strategist One");

        vm.expectRevert(CuratioStrategistRegistry.SameStrategist.selector);
        registry.bulkReassignPools(strategist1, strategist1, type(uint256).max);
        vm.stopPrank();
    }

function test_bulkReassignPools_onlyRegistrarRole() public {
    vm.prank(admin);
    registry.registerStrategist(strategist1, "Strategist One");
    vm.prank(admin);
    registry.registerStrategist(strategist2, "Strategist Two");

    bytes32 registrarRole = registry.REGISTRAR_ROLE();  // ✅ আগে cache করুন

    vm.prank(unauthorized);
    vm.expectRevert(
        abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector,
            unauthorized,
            registrarRole   // ✅ cached ভ্যারিয়েবল ব্যবহার করুন
        )
    );
    registry.bulkReassignPools(strategist1, strategist2, type(uint256).max);
}

}