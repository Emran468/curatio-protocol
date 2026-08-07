// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "./CuratioAccess.sol";

/// @dev Minimal interface until CuratioRebalancer.sol (Layer 4) is implemented.
interface ICuratioRebalancer {
    function notifyDeposit(uint256 assets) external;
    function notifyWithdraw(uint256 assets) external;
}

/**
 * @title CuratioVault
 * @dev Layer 3 — ERC-4626 Tokenized Vault. Gates deposits/withdrawals through
 *      CuratioAccess (Layer 2) and triggers strategy execution via CuratioRebalancer (Layer 4).
 */
contract CuratioVault is ERC4626, AccessControl {
    bytes32 public constant VAULT_MANAGER_ROLE = keccak256("VAULT_MANAGER_ROLE");

    CuratioAccess public accessControl;
    ICuratioRebalancer public rebalancer;

    uint256 public depositCap;
    bool public depositsPaused;

    event AccessControlUpdated(address indexed oldAccess, address indexed newAccess);
    event RebalancerUpdated(address indexed oldRebalancer, address indexed newRebalancer);
    event DepositCapUpdated(uint256 newCap);
    event DepositsPausedToggled(bool paused);

    error NotWhitelisted(address user);
    error DepositCapExceeded(uint256 attempted, uint256 cap);
    error DepositsArePaused();
    error ZeroAddress();

    constructor(IERC20 asset_, address _accessControl, address _rebalancer, address _admin, uint256 _depositCap)
        ERC4626(asset_)
        ERC20("Curatio Vault Share", "cVAULT")
    {
        if (_accessControl == address(0) || _rebalancer == address(0) || _admin == address(0)) {
            revert ZeroAddress();
        }

        accessControl = CuratioAccess(_accessControl);
        rebalancer = ICuratioRebalancer(_rebalancer);
        depositCap = _depositCap;

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(VAULT_MANAGER_ROLE, _admin);
    }

    // ─── Deposit / Mint overrides ────────────────────────────────────────────

    function deposit(uint256 assets, address receiver) public override returns (uint256) {
        _checkWhitelist(msg.sender);
        _checkNotPaused();
        _checkCap(assets);

        uint256 shares = super.deposit(assets, receiver);
        _notifyRebalancerDeposit(assets);
        return shares;
    }

    function mint(uint256 shares, address receiver) public override returns (uint256) {
        _checkWhitelist(msg.sender);
        _checkNotPaused();

        uint256 assets = super.mint(shares, receiver);
        _checkCap(0); // re-check total assets after mint
        _notifyRebalancerDeposit(assets);
        return assets;
    }

    // ─── Withdraw / Redeem overrides ─────────────────────────────────────────

    function withdraw(uint256 assets, address receiver, address owner_) public override returns (uint256) {
        _checkWhitelist(msg.sender);

        uint256 shares = super.withdraw(assets, receiver, owner_);
        _notifyRebalancerWithdraw(assets);
        return shares;
    }

    function redeem(uint256 shares, address receiver, address owner_) public override returns (uint256) {
        _checkWhitelist(msg.sender);

        uint256 assets = super.redeem(shares, receiver, owner_);
        _notifyRebalancerWithdraw(assets);
        return assets;
    }

    // ─── Internal checks ──────────────────────────────────────────────────────

    function _checkWhitelist(address user) internal view {
        if (!accessControl.isWhitelisted(user)) revert NotWhitelisted(user);
    }

    function _checkNotPaused() internal view {
        if (depositsPaused) revert DepositsArePaused();
    }

    function _checkCap(uint256 incomingAssets) internal view {
        if (depositCap == 0) return; // 0 = uncapped
        uint256 projected = totalAssets() + incomingAssets;
        if (projected > depositCap) revert DepositCapExceeded(projected, depositCap);
    }

    function _notifyRebalancerDeposit(uint256 assets) internal {
        // Non-blocking: if rebalancer call fails, deposit still succeeds.
        try rebalancer.notifyDeposit(assets) {} catch {}
    }

    function _notifyRebalancerWithdraw(uint256 assets) internal {
        try rebalancer.notifyWithdraw(assets) {} catch {}
    }

    // ─── Admin ────────────────────────────────────────────────────────────────

    function setAccessControl(address _accessControl) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_accessControl == address(0)) revert ZeroAddress();
        emit AccessControlUpdated(address(accessControl), _accessControl);
        accessControl = CuratioAccess(_accessControl);
    }

    function setRebalancer(address _rebalancer) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_rebalancer == address(0)) revert ZeroAddress();
        emit RebalancerUpdated(address(rebalancer), _rebalancer);
        rebalancer = ICuratioRebalancer(_rebalancer);
    }

    function setDepositCap(uint256 _cap) external onlyRole(VAULT_MANAGER_ROLE) {
        depositCap = _cap;
        emit DepositCapUpdated(_cap);
    }

    function setDepositsPaused(bool _paused) external onlyRole(VAULT_MANAGER_ROLE) {
        depositsPaused = _paused;
        emit DepositsPausedToggled(_paused);
    }

    // ─── ERC4626 / AccessControl conflict resolution ────────────────────────
    // ERC4626 inherits ERC20 (which has no supportsInterface), AccessControl declares it.
    // No override needed here since ERC4626 doesn't implement IERC165, but kept explicit
    // in case OZ version changes this — remove if compiler doesn't require it.
}
