// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/access/AccessControl.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/**
 * @title CuratioStrategistRegistry
 * @dev Layer 3.5 — Registers strategists, tracks their managed pools and
 *      performance history, and gates who may act as a strategist on any
 *      CuratioRebalancer instance. This is what turns a single-manager
 *      rebalancer into a curated network of professional managers that
 *      depositors can discover and follow.
 */
contract CuratioStrategistRegistry is AccessControl {
    bytes32 public constant REGISTRAR_ROLE = keccak256("REGISTRAR_ROLE");
    bytes32 public constant REBALANCER_ROLE = keccak256("REBALANCER_ROLE"); // granted to CuratioRebalancer instances

    struct StrategistProfile {
        string name;
        address strategistAddress;
        uint256 registeredAt;
        bool active;
        // Cumulative performance stats, updated by authorized CuratioRebalancer
        // instances after each rebalance/performance-fee event.
        uint256 totalRebalancesExecuted;
        uint256 totalFeesGeneratedForVault; // in the vault's asset terms, reported by CuratioDynamicFee
        uint256 lastActiveBlock;
    }

    mapping(address => StrategistProfile) public strategists;
    mapping(address => bool) public isRegisteredStrategist;
    address[] public strategistList;

    // Which pools (by PoolId) each strategist currently manages.
    mapping(address => PoolId[]) private _strategistPools;
    mapping(PoolId => address) public poolStrategist; // reverse lookup: pool -> its strategist

    event StrategistRegistered(address indexed strategist, string name);
    event StrategistDeactivated(address indexed strategist);
    event StrategistReactivated(address indexed strategist);
    event PoolAssignedToStrategist(address indexed strategist, PoolId indexed poolId);
    event PoolUnassignedFromStrategist(address indexed strategist, PoolId indexed poolId);
    event PerformanceRecorded(address indexed strategist, uint256 rebalanceCount, uint256 feesGenerated);

    error ZeroAddress();
    error AlreadyRegistered(address strategist);
    error NotRegistered(address strategist);
    error PoolAlreadyAssigned(PoolId poolId);

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
        if (poolStrategist[poolId] != address(0)) revert PoolAlreadyAssigned(poolId);

        _strategistPools[strategist].push(poolId);
        poolStrategist[poolId] = strategist;

        emit PoolAssignedToStrategist(strategist, poolId);
    }

    /// @notice Enables "strategy migration between pools" — reassigns a pool
    ///         away from its current strategist without deleting history.
    function reassignPool(PoolId poolId, address newStrategist) external onlyRole(REGISTRAR_ROLE) {
        if (!isRegisteredStrategist[newStrategist]) revert NotRegistered(newStrategist);

        address oldStrategist = poolStrategist[poolId];
        if (oldStrategist != address(0)) {
            emit PoolUnassignedFromStrategist(oldStrategist, poolId);
        }

        poolStrategist[poolId] = newStrategist;
        _strategistPools[newStrategist].push(poolId);

        emit PoolAssignedToStrategist(newStrategist, poolId);
    }

    // ─── Performance recording (called by authorized CuratioRebalancer) ────

    /// @notice Called by a CuratioRebalancer instance after executing a
    ///         rebalance, so the registry accumulates a public track record
    ///         per strategist — this is what LPs would inspect before
    ///         choosing which manager to follow.
    function recordRebalanceExecuted(address strategist) external onlyRole(REBALANCER_ROLE) {
        if (!isRegisteredStrategist[strategist]) revert NotRegistered(strategist);
        StrategistProfile storage profile = strategists[strategist];
        profile.totalRebalancesExecuted += 1;
        profile.lastActiveBlock = block.number;

        emit PerformanceRecorded(strategist, profile.totalRebalancesExecuted, profile.totalFeesGeneratedForVault);
    }

    function recordFeesGenerated(address strategist, uint256 feeAmount) external onlyRole(REBALANCER_ROLE) {
        if (!isRegisteredStrategist[strategist]) revert NotRegistered(strategist);
        StrategistProfile storage profile = strategists[strategist];
        profile.totalFeesGeneratedForVault += feeAmount;

        emit PerformanceRecorded(strategist, profile.totalRebalancesExecuted, profile.totalFeesGeneratedForVault);
    }

    // ─── Admin: authorize a CuratioRebalancer instance to report performance ─

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

    function getStrategistProfile(address strategist) external view returns (StrategistProfile memory) {
        return strategists[strategist];
    }
}
