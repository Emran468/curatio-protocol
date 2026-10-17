// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "./CuratioAccess.sol";

/// @dev Interface to CuratioRebalancer (Layer 4).
interface ICuratioRebalancer {
    function notifyDeposit(uint256 assets) external;
    function notifyWithdraw(uint256 assets) external;
    /// @dev Everything the rebalancer controls, in vault-asset terms (TWAP-priced). Reverts if unavailable.
    function totalManagedAssets() external view returns (uint256);
    /// @dev Sends idle vault asset back to the vault. Reverts if the rebalancer lacks idle asset.
    function returnToVault(uint256 amount) external;
}

/**
 * @title CuratioVault
 * @notice Layer 3. Whitelisted ERC-4626 vault. Idle asset stays here; the manager can deploy
 *         it to CuratioRebalancer (Layer 4), which puts it into a Uniswap v4 LP position.
 *
 * @dev Share pricing: totalAssets() = idle asset + rebalancer.totalManagedAssets().
 *      The second term is TWAP-priced and STRICT: if the rebalancer cannot value itself
 *      (e.g. TWAP unavailable) totalAssets() reverts, which pauses deposits/withdrawals
 *      instead of minting or burning shares at a wrong price.
 *
 *      Known limitations (prototype):
 *      - Withdrawals can only be served from idle asset in the vault + idle asset in the
 *        rebalancer. Funds inside the LP position are not unwound on withdraw (needs the
 *        swap step). maxWithdraw/maxRedeem do not yet reflect available liquidity.
 *      - No `_decimalsOffset` inflation-attack protection (kept at 0 so share math stays 1:1).
 *        OZ's built-in virtual shares + the whitelist + the deposit cap limit exposure.
 */
contract CuratioVault is ERC4626, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant VAULT_MANAGER_ROLE = keccak256("VAULT_MANAGER_ROLE");

    CuratioAccess public accessControl;
    ICuratioRebalancer public rebalancer;

    uint256 public depositCap;
    bool public depositsPaused;

    event AccessControlUpdated(address indexed oldAccess, address indexed newAccess);
    event RebalancerUpdated(address indexed oldRebalancer, address indexed newRebalancer);
    event DepositCapUpdated(uint256 newCap);
    event DepositsPausedToggled(bool paused);
    event FundsDeployed(uint256 amount);
    event RebalancerNotifyFailed(bool isDeposit, uint256 assets);

    error NotWhitelisted(address user);
    error DepositCapExceeded(uint256 attempted, uint256 cap);
    error DepositsArePaused();
    error ZeroAddress();
    error ZeroAmount();

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

    // ─── Accounting ──────────────────────────────────────────────────────────

    /// @notice Idle asset in the vault plus everything the rebalancer controls (TWAP-priced, strict).
    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this)) + rebalancer.totalManagedAssets();
    }

    // ─── ERC-4626 limits (so integrators see the cap and the pause) ───────────

    function maxDeposit(address) public view override returns (uint256) {
        if (depositsPaused) return 0;
        if (depositCap == 0) return type(uint256).max;
        uint256 total = totalAssets();
        return total >= depositCap ? 0 : depositCap - total;
    }

    function maxMint(address receiver) public view override returns (uint256) {
        uint256 maxAssets = maxDeposit(receiver);
        if (maxAssets == type(uint256).max) return type(uint256).max;
        return convertToShares(maxAssets);
    }

    // ─── Deposit / Mint overrides ────────────────────────────────────────────

    function deposit(uint256 assets, address receiver) public override nonReentrant returns (uint256) {
        _checkWhitelist(msg.sender);
        _checkWhitelist(receiver);
        _checkNotPaused();
        _checkCap(assets);

        uint256 shares = super.deposit(assets, receiver);
        _notifyRebalancerDeposit(assets);
        return shares;
    }

    function mint(uint256 shares, address receiver) public override nonReentrant returns (uint256) {
        _checkWhitelist(msg.sender);
        _checkWhitelist(receiver);
        _checkNotPaused();
        _checkCap(previewMint(shares)); // check BEFORE pulling tokens

        uint256 assets = super.mint(shares, receiver);
        _notifyRebalancerDeposit(assets);
        return assets;
    }

    // ─── Withdraw / Redeem overrides ─────────────────────────────────────────

    function withdraw(uint256 assets, address receiver, address owner_)
        public
        override
        nonReentrant
        returns (uint256)
    {
        _checkWhitelist(msg.sender);
        _checkWhitelist(receiver);
        _checkWhitelist(owner_);

        uint256 shares = super.withdraw(assets, receiver, owner_);
        _notifyRebalancerWithdraw(assets);
        return shares;
    }

    function redeem(uint256 shares, address receiver, address owner_)
        public
        override
        nonReentrant
        returns (uint256)
    {
        _checkWhitelist(msg.sender);
        _checkWhitelist(receiver);
        _checkWhitelist(owner_);

        uint256 assets = super.redeem(shares, receiver, owner_);
        _notifyRebalancerWithdraw(assets);
        return assets;
    }

    /// @dev If the vault's idle balance is short, pull the shortfall from the rebalancer first.
    ///      Reverts (via the rebalancer) if it does not hold enough idle asset.
    function _withdraw(address caller, address receiver, address owner_, uint256 assets, uint256 shares)
        internal
        override
    {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (idle < assets) {
            rebalancer.returnToVault(assets - idle);
        }
        super._withdraw(caller, receiver, owner_, assets, shares);
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

    /// @dev Non-blocking: a failing rebalancer never blocks a deposit/withdrawal, but the
    ///      failure is now visible on-chain.
    function _notifyRebalancerDeposit(uint256 assets) internal {
        try rebalancer.notifyDeposit(assets) {} catch {
            emit RebalancerNotifyFailed(true, assets);
        }
    }

    function _notifyRebalancerWithdraw(uint256 assets) internal {
        try rebalancer.notifyWithdraw(assets) {} catch {
            emit RebalancerNotifyFailed(false, assets);
        }
    }

    // ─── Manager: fund flow ───────────────────────────────────────────────────

    /// @notice Move idle asset to the rebalancer. Share price is unchanged because the
    ///         rebalancer's holdings are counted in totalAssets().
    function deployToRebalancer(uint256 amount) external onlyRole(VAULT_MANAGER_ROLE) nonReentrant {
        if (amount == 0) revert ZeroAmount();
        IERC20(asset()).safeTransfer(address(rebalancer), amount);
        emit FundsDeployed(amount);
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
}
