// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title CuratioAccess
 * @dev Layer 2 — Manages token-gating and role-based permissions for the Curatio Vault ecosystem.
 *
 * Trust assumptions (prototype, unaudited):
 * - DEFAULT_ADMIN can toggle whitelisting. Disabling it (false) lets anyone deposit,
 *   bypassing KYC. Re-enabling it (true) does NOT immediately block existing users
 *   from exiting — see the exit-gating note below.
 * - VAULT_MANAGER can add users to the whitelist immediately, but REMOVING a user
 *   goes through a 2-day timelock so they have time to withdraw before losing access.
 * - The vault gates withdraw/redeem on whitelist membership. A removed user cannot
 *   exit until re-whitelisted. This is a permissioned-vault design choice, not a bug.
 */
contract CuratioAccess is AccessControl {
    bytes32 public constant STRATEGIST_ROLE = keccak256("STRATEGIST_ROLE");
    bytes32 public constant VAULT_MANAGER_ROLE = keccak256("VAULT_MANAGER_ROLE");

    /// @notice Delay before a whitelist REMOVAL takes effect. Adding is immediate.
    uint256 public constant REMOVAL_TIMELOCK = 2 days;

    /// @notice Max users per batch call, to avoid an accidental out-of-gas on the
    ///         manager's own transaction. Not a security limit.
    uint256 public constant MAX_BATCH_SIZE = 200;

    mapping(address => bool) private _whitelistedUsers;
    /// @notice Timestamp at which a pending removal becomes executable. 0 = no pending removal.
    mapping(address => uint256) public pendingRemovalEta;

    bool public isWhitelistingEnabled = true;

    event UserWhitelisted(address indexed user, bool status);
    event WhitelistingToggled(bool status);
    event RemovalProposed(address indexed user, uint256 eta);
    event RemovalCancelled(address indexed user);
    event RemovalExecuted(address indexed user);

    error ZeroAddress();
    error BatchTooLarge(uint256 size, uint256 max);
    error NoPendingRemoval(address user);
    error RemovalTimelockActive(uint256 eta);

    constructor(address admin) {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(STRATEGIST_ROLE, admin);
        _grantRole(VAULT_MANAGER_ROLE, admin);
    }

    // ─── Adding to whitelist (immediate) ─────────────────────────────────────

    /// @notice Add (or re-add) a user to the whitelist immediately.
    ///         Removing is intentionally NOT immediate — see proposeRemoval.
    function setWhitelistedUser(address user, bool status) external onlyRole(VAULT_MANAGER_ROLE) {
        if (user == address(0)) revert ZeroAddress();
        if (status == false) {
            // Removal must go through the timelock, not this path.
            revert("Use proposeRemoval for removal");
        }
        _whitelistedUsers[user] = true;
        emit UserWhitelisted(user, true);
    }

    function setWhitelistedUsersBatch(address[] calldata users, bool status) external onlyRole(VAULT_MANAGER_ROLE) {
        if (users.length > MAX_BATCH_SIZE) revert BatchTooLarge(users.length, MAX_BATCH_SIZE);
        if (status == false) revert("Use proposeRemovalBatch for removal");

        for (uint256 i = 0; i < users.length; i++) {
            if (users[i] == address(0)) revert ZeroAddress();
            _whitelistedUsers[users[i]] = true;
            emit UserWhitelisted(users[i], true);
        }
    }

    // ─── Removing from whitelist (2-day timelock) ────────────────────────────

    /// @notice Step 1 of 2: propose removing a user. Takes effect after REMOVAL_TIMELOCK.
    function proposeRemoval(address user) external onlyRole(VAULT_MANAGER_ROLE) {
        if (user == address(0)) revert ZeroAddress();
        uint256 eta = block.timestamp + REMOVAL_TIMELOCK;
        pendingRemovalEta[user] = eta;
        emit RemovalProposed(user, eta);
    }

    /// @notice Step 2 of 2: execute a previously proposed removal.
    function executeRemoval(address user) external onlyRole(VAULT_MANAGER_ROLE) {
        uint256 eta = pendingRemovalEta[user];
        if (eta == 0) revert NoPendingRemoval(user);
        if (block.timestamp < eta) revert RemovalTimelockActive(eta);

        delete pendingRemovalEta[user];
        _whitelistedUsers[user] = false;
        emit RemovalExecuted(user);
        emit UserWhitelisted(user, false);
    }

    /// @notice Cancel a pending removal (e.g. false alarm).
    function cancelRemoval(address user) external onlyRole(VAULT_MANAGER_ROLE) {
        if (pendingRemovalEta[user] == 0) revert NoPendingRemoval(user);
        delete pendingRemovalEta[user];
        emit RemovalCancelled(user);
    }

    // ─── Admin ────────────────────────────────────────────────────────────────

    function toggleWhitelisting(bool status) external onlyRole(DEFAULT_ADMIN_ROLE) {
        isWhitelistingEnabled = status;
        emit WhitelistingToggled(status);
    }

    function isWhitelisted(address user) external view returns (bool) {
        return !isWhitelistingEnabled || _whitelistedUsers[user];
    }
}
