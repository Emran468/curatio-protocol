// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title CuratioAccess
 * @dev Layer 2 — Manages token-gating and role-based permissions for the Curatio Vault ecosystem.
 */
contract CuratioAccess is AccessControl {
    bytes32 public constant STRATEGIST_ROLE = keccak256("STRATEGIST_ROLE");
    bytes32 public constant VAULT_MANAGER_ROLE = keccak256("VAULT_MANAGER_ROLE");

    mapping(address => bool) private _whitelistedUsers;
    bool public isWhitelistingEnabled = true;

    event UserWhitelisted(address indexed user, bool status);
    event WhitelistingToggled(bool status);

    constructor(address admin) {
        require(admin != address(0), "CuratioAccess: zero admin");
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(STRATEGIST_ROLE, admin);
        _grantRole(VAULT_MANAGER_ROLE, admin);
    }

    function setWhitelistedUser(address user, bool status) external onlyRole(VAULT_MANAGER_ROLE) {
        require(user != address(0), "CuratioAccess: zero user");
        _whitelistedUsers[user] = status;
        emit UserWhitelisted(user, status);
    }

    function setWhitelistedUsersBatch(address[] calldata users, bool status) external onlyRole(VAULT_MANAGER_ROLE) {
        for (uint256 i = 0; i < users.length; i++) {
            require(users[i] != address(0), "CuratioAccess: zero user");
            _whitelistedUsers[users[i]] = status;
            emit UserWhitelisted(users[i], status);
        }
    }

    function toggleWhitelisting(bool status) external onlyRole(DEFAULT_ADMIN_ROLE) {
        isWhitelistingEnabled = status;
        emit WhitelistingToggled(status);
    }

    function isWhitelisted(address user) external view returns (bool) {
        return !isWhitelistingEnabled || _whitelistedUsers[user];
    }
}
