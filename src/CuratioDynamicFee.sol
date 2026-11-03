// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title CuratioDynamicFee
 * @dev Layer 5 — Performance fee engine for CuratioVault (Layer 3) yield.
 *      Swap-fee calculation intentionally lives in CuratioHook.sol (inline,
 *      gas-critical path) rather than here. This contract handles ONLY the
 *      vault's performance fee on harvested yield — a separate, non-gas-critical
 *      concern, called from CuratioVault during harvest, not from the hook.
 */
contract CuratioDynamicFee is AccessControl {
    bytes32 public constant FEE_ADMIN_ROLE = keccak256("FEE_ADMIN_ROLE");
    bytes32 public constant VAULT_ROLE = keccak256("VAULT_ROLE");

    uint256 public performanceFeeBps = 1000; // 10% of yield, in basis points
    uint256 public constant MAX_PERFORMANCE_FEE_BPS = 3000; // hard cap: 30%
    address public feeRecipient;
    address public vault;

    uint256 public totalFeesCharged;

    uint256 public totalYieldProcessed;

    event PerformanceFeeCharged(address indexed vault, uint256 yieldAmount, uint256 feeAmount);
    event PerformanceFeeUpdated(uint256 newBps);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event VaultUpdated(address indexed oldVault, address indexed newVault);

    error ZeroAddress();
    error FeeTooHigh(uint256 requested, uint256 max);
    error NotVault(address caller);
    error FeeExceedsCalculated(uint256 reported, uint256 maxAllowed);

    modifier onlyVault() {
        if (msg.sender != vault) revert NotVault(msg.sender);
        _;
    }

    constructor(address _admin, address _vault, address _feeRecipient) {
        if (_admin == address(0) || _vault == address(0) || _feeRecipient == address(0)) {
            revert ZeroAddress();
        }

        vault = _vault;
        feeRecipient = _feeRecipient;

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(FEE_ADMIN_ROLE, _admin);
        _grantRole(VAULT_ROLE, _vault);
    }

    /// @notice Pure calculation — vault calls this before harvest to know the fee amount.
    function calculatePerformanceFee(uint256 yieldAmount) external view returns (uint256) {
        return (yieldAmount * performanceFeeBps) / 10_000;
    }

    /// @notice Vault calls this after actually transferring the fee, for accounting/events.
    ///         Restricted to the registered vault only.

    function reportPerformanceFeeCharged(uint256 yieldAmount, uint256 feeAmount) external onlyVault {
        uint256 maxFee = (yieldAmount * performanceFeeBps) / 10_000;
        if (feeAmount > maxFee) revert FeeExceedsCalculated(feeAmount, maxFee);

        totalFeesCharged += feeAmount;
        totalYieldProcessed += yieldAmount;
        emit PerformanceFeeCharged(msg.sender, yieldAmount, feeAmount);
    }

    // ─── Admin ────────────────────────────────────────────────────────────────

    function setPerformanceFeeBps(uint256 newBps) external onlyRole(FEE_ADMIN_ROLE) {
        if (newBps > MAX_PERFORMANCE_FEE_BPS) revert FeeTooHigh(newBps, MAX_PERFORMANCE_FEE_BPS);
        performanceFeeBps = newBps;
        emit PerformanceFeeUpdated(newBps);
    }

    function setFeeRecipient(address newRecipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newRecipient == address(0)) revert ZeroAddress();
        emit FeeRecipientUpdated(feeRecipient, newRecipient);
        feeRecipient = newRecipient;
    }

    function setVault(address newVault) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newVault == address(0)) revert ZeroAddress();
        _revokeRole(VAULT_ROLE, vault);
        emit VaultUpdated(vault, newVault);
        vault = newVault;
        _grantRole(VAULT_ROLE, newVault);
    }
}
