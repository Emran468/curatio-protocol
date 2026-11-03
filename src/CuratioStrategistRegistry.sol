// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/access/AccessControl.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/**
 * @title CuratioStrategistRegistry
 * @dev Layer 6 — Tracks professional strategists, their pool assignments, and
 *      performance metrics. Used by CuratioRebalancer to attribute rebalances.
 *
 * Trust assumptions (prototype, unaudited):
 * - REGISTRAR_ROLE assigns pools to strategists and can deactivate/reactivate them.
 * - REBALANCER_ROLE (granted to CuratioRebalancer) records performance.
 * - A deactivated strategist keeps its pool assignments but cannot record new
 *   performance. Pool assignment to an INACTIVE strategist is rejected.
 * - `strategistList` includes deactivated strategists; use `getActiveStrategists()`
 *   for the current active set.
 */
contract CuratioStrategistRegistry is AccessControl {
    bytes32 public constant REGISTRAR_ROLE = keccak256("REGISTRAR_ROLE");
    bytes32 public constant REBALANCER_ROLE = keccak256("REBALANCER_ROLE");

    struct StrategistProfile {
        string name;
        address strategistAddress;
        uint256 registeredAt;
        bool active;
        uint256 totalRebalancesExecuted;
        uint256 totalFeesGeneratedForVault;
        uint256 lastActiveBlock;
    }

    mapping(address => StrategistProfile) public strategists;
    mapping(address => bool) public isRegisteredStrategist;
    address[] public strategistList;
    mapping(address => PoolId[]) private _strategistPools;
    mapping(PoolId => address) public poolStrategist;

    event StrategistRegistered(address indexed strategist, string name);
    event StrategistDeactivated(address indexed strategist);
    event StrategistReactivated(address indexed strategist);
    event PoolAssignedToStrategist(address indexed strategist, PoolId indexed poolId);
    event PoolUnassignedFromStrategist(address indexed strategist, PoolId indexed poolId);
    event PerformanceRecorded(address indexed strategist, uint256 rebalanceCount, uint256 feesGenerated);
    event BulkMigrationCompleted(address indexed oldStrategist, address indexed newStrategist, uint256 poolCount);

    error ZeroAddress();
    error AlreadyRegistered(address strategist);
    error NotRegistered(address strategist);
    error PoolAlreadyAssigned(PoolId poolId);
    error StrategistInactive(address strategist);
    error SameStrategist();
    error PoolNotAssigned(PoolId poolId);

    constructor(address admin) {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(REGISTRAR_ROLE, admin);
    }

    // ─── Registration ─────────────────────────────────────────────────────

    function registerStrategist(address strategist, string calldata name) external onlyRole(REGISTRAR_ROLE) {
        if (strategist == address(0)) revert ZeroAddress();
        if (isRegisteredStrategist[strategist]) revert AlreadyRegistered(strategist);

        strategists[strategist] = StrategistProfile({
            name: name,
            strategistAddress: strategist,
            registeredAt: block.timestamp,
            active: true,
            totalRebalancesExecuted: 0,
            totalFeesGeneratedForVault: 0,
            lastActiveBlock: block.number
        });
        isRegisteredStrategist[strategist] = true;
        strategistList.push(strategist);

        emit StrategistRegistered(strategist, name);
    }

    function deactivateStrategist(address strategist) external onlyRole(REGISTRAR_ROLE) {
        if (!isRegisteredStrategist[strategist]) revert NotRegistered(strategist);
        strategists[strategist].active = false;
        emit StrategistDeactivated(strategist);
    }

    function reactivateStrategist(address strategist) external onlyRole(REGISTRAR_ROLE) {
        if (!isRegisteredStrategist[strategist]) revert NotRegistered(strategist);
        strategists[strategist].active = true;
        emit StrategistReactivated(strategist);
    }

    // ─── Pool assignment ────────────────────────────────────────────────────

    function assignPoolToStrategist(address strategist, PoolId poolId) external onlyRole(REGISTRAR_ROLE) {
        if (!isRegisteredStrategist[strategist]) revert NotRegistered(strategist);
        if (!strategists[strategist].active) revert StrategistInactive(strategist); // ✅ FIXED
        if (poolStrategist[poolId] != address(0)) revert PoolAlreadyAssigned(poolId);

        _strategistPools[strategist].push(poolId);
        poolStrategist[poolId] = strategist;

        emit PoolAssignedToStrategist(strategist, poolId);
    }

    function reassignPool(PoolId poolId, address newStrategist) external onlyRole(REGISTRAR_ROLE) {
        if (!isRegisteredStrategist[newStrategist]) revert NotRegistered(newStrategist);
        if (!strategists[newStrategist].active) revert StrategistInactive(newStrategist); // ✅ FIXED

        address oldStrategist = poolStrategist[poolId];
        if (oldStrategist != address(0)) {
            _removePoolFromStrategist(oldStrategist, poolId);
            emit PoolUnassignedFromStrategist(oldStrategist, poolId);
        }

        poolStrategist[poolId] = newStrategist;
        _strategistPools[newStrategist].push(poolId);

        emit PoolAssignedToStrategist(newStrategist, poolId);
    }

    /// @notice Remove a pool from its current strategist without assigning a new one.
    function unassignPool(PoolId poolId) external onlyRole(REGISTRAR_ROLE) {
        // ✅ NEW
        address oldStrategist = poolStrategist[poolId];
        if (oldStrategist == address(0)) revert PoolNotAssigned(poolId);

        _removePoolFromStrategist(oldStrategist, poolId);
        delete poolStrategist[poolId];

        emit PoolUnassignedFromStrategist(oldStrategist, poolId);
    }

    function bulkReassignPools(address oldStrategist, address newStrategist, uint256 maxCount)
        external
        onlyRole(REGISTRAR_ROLE)
    {
        if (!isRegisteredStrategist[oldStrategist]) revert NotRegistered(oldStrategist);
        if (!isRegisteredStrategist[newStrategist]) revert NotRegistered(newStrategist);
        if (oldStrategist == newStrategist) revert SameStrategist();
        if (!strategists[newStrategist].active) revert StrategistInactive(newStrategist); // ✅ FIXED

        PoolId[] memory poolsToMigrate = _strategistPools[oldStrategist];
        uint256 count = poolsToMigrate.length < maxCount ? poolsToMigrate.length : maxCount;

        for (uint256 i = 0; i < count; i++) {
            PoolId poolId = poolsToMigrate[i];

            _removePoolFromStrategist(oldStrategist, poolId);
            emit PoolUnassignedFromStrategist(oldStrategist, poolId);

            poolStrategist[poolId] = newStrategist;
            _strategistPools[newStrategist].push(poolId);
            emit PoolAssignedToStrategist(newStrategist, poolId);
        }

        emit BulkMigrationCompleted(oldStrategist, newStrategist, count);
    }

    // ─── Performance recording ──────────────────────────────────────────────

    function recordRebalanceExecuted(address strategist) external onlyRole(REBALANCER_ROLE) {
        if (!isRegisteredStrategist[strategist]) revert NotRegistered(strategist);
        if (!strategists[strategist].active) revert StrategistInactive(strategist);
        StrategistProfile storage profile = strategists[strategist];
        profile.totalRebalancesExecuted += 1;
        profile.lastActiveBlock = block.number;

        emit PerformanceRecorded(strategist, profile.totalRebalancesExecuted, profile.totalFeesGeneratedForVault);
    }

    function recordFeesGenerated(address strategist, uint256 feeAmount) external onlyRole(REBALANCER_ROLE) {
        if (!isRegisteredStrategist[strategist]) revert NotRegistered(strategist);
        if (!strategists[strategist].active) revert StrategistInactive(strategist);
        StrategistProfile storage profile = strategists[strategist];
        profile.totalFeesGeneratedForVault += feeAmount;
        profile.lastActiveBlock = block.number; // ✅ FIXED

        emit PerformanceRecorded(strategist, profile.totalRebalancesExecuted, profile.totalFeesGeneratedForVault);
    }

    // ─── Admin ─────────────────────────────────────────────────────────────

    function authorizeRebalancer(address rebalancerContract) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(REBALANCER_ROLE, rebalancerContract);
    }

    function revokeRebalancer(address rebalancerContract) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _revokeRole(REBALANCER_ROLE, rebalancerContract);
    }

    // ─── Views ──────────────────────────────────────────────────────────────

    function getStrategistPools(address strategist) external view returns (PoolId[] memory) {
        return _strategistPools[strategist];
    }

    function getAllStrategists() external view returns (address[] memory) {
        return strategistList;
    }

    /// @notice Return only currently active strategists.  // ✅ NEW
    function getActiveStrategists() external view returns (address[] memory) {
        uint256 count = 0;
        uint256 len = strategistList.length;
        for (uint256 i = 0; i < len; i++) {
            if (strategists[strategistList[i]].active) count++;
        }
        address[] memory active = new address[](count);
        uint256 j = 0;
        for (uint256 i = 0; i < len; i++) {
            if (strategists[strategistList[i]].active) {
                active[j++] = strategistList[i];
            }
        }
        return active;
    }

    function getStrategistProfile(address strategist) external view returns (StrategistProfile memory) {
        if (!isRegisteredStrategist[strategist]) revert NotRegistered(strategist);
        return strategists[strategist];
    }

    // ─── Internal ─────────────────────────────────────────────────────────────

    function _removePoolFromStrategist(address strategist, PoolId poolId) internal {
        PoolId[] storage pools = _strategistPools[strategist];
        for (uint256 i = 0; i < pools.length; i++) {
            if (PoolId.unwrap(pools[i]) == PoolId.unwrap(poolId)) {
                pools[i] = pools[pools.length - 1];
                pools.pop();
                return;
            }
        }
    }
}
