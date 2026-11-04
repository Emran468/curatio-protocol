// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "./CuratioAccess.sol";
import {CuratioStrategistRegistry} from "./CuratioStrategistRegistry.sol";

/// @dev Interface to CuratioRebalancer (Layer 4).
interface ICuratioRebalancer {
    function notifyDeposit(uint256 assets) external;
    function notifyWithdraw(uint256 assets) external;
    /// @dev Everything the rebalancer controls, in vault-asset terms (TWAP-priced). Reverts if unavailable.
    function totalManagedAssets() external view returns (uint256);
    /// @dev Sends idle vault asset back to the vault. Unwinds part of the LP and swaps if idle asset is short.
    function returnToVault(uint256 amount) external;
    function strategistRegistry() external view returns (address);
}

/// @dev Interface to CuratioDynamicFee (Layer 5).
interface ICuratioDynamicFee {
    function calculatePerformanceFee(uint256 yieldAmount) external view returns (uint256);
    function reportPerformanceFeeCharged(uint256 yieldAmount, uint256 feeAmount) external;
    function performanceFeeBps() external view returns (uint256);
    function feeRecipient() external view returns (address);
    function vault() external view returns (address);
}

/**
 * @title CuratioVault
 * @notice Layer 3. Whitelisted ERC-4626 vault. Idle asset stays here; the manager can deploy
 *         it to CuratioRebalancer (Layer 4), which puts it into a Uniswap v4 LP position.
 *
 * @dev Share pricing: totalAssets() = idle asset + rebalancer.totalManagedAssets().
 *      The second term is TWAP-priced and STRICT: if the rebalancer cannot value itself
 *      (e.g. TWAP unavailable) totalAssets() reverts, which pauses deposits/withdrawals
 *      instead of minting or burning shares at a wrong price. maxDeposit/maxMint return 0 then
 *      (ERC-4626 requires the max* functions not to revert).
 *
 *      Inflation-attack protection:
 *      - _decimalsOffset() = 6: shares have (asset decimals + 6) decimals. The first deposit mints
 *        1e6 share units per asset wei, so a donation attacker must give up roughly 1e6x more
 *        than a victim can lose.
 *      - deposit/mint revert with ZeroShares, and redeem reverts with ZeroAssets, so nobody can
 *        pay for nothing (a large donation can still round a tiny deposit down to zero shares).
 *
 *      Performance fee (harvest):
 *      - The manager calls harvest(). The vault compares the share price with a high-water mark
 *        (HWM). Only the part of the price rise ABOVE the HWM is yield, so a recovery after a loss
 *        is never charged twice.
 *      - The fee is paid by minting shares to the fee module's feeRecipient; no asset moves.
 *        The number of shares is chosen so they are worth exactly the fee after dilution.
 *      - The first harvest after a fee-module change only records the baseline (no fee).
 *      - ANY rise of the share price counts as yield: LP fees, TWAP moves of the non-asset token,
 *        and direct donations to the vault.
 *      - The recipient receives shares without a whitelist check but must be whitelisted to redeem.
 *
 *      Trust assumptions (prototype, unaudited):
 *      - DEFAULT_ADMIN controls the rebalancer (which prices every share), the access contract (which
 *        gates exits as well as entries) and the fee module. Every change goes through propose ->
 *        wait ADMIN_TIMELOCK -> execute, so users can exit during the delay. The only immediate admin
 *        action is the one-time initializeFeeModule() at deployment.
 *      - Switching the rebalancer stops counting what the OLD rebalancer still holds: move the funds first.
 *      - A fee module can take at most MAX_PERFORMANCE_FEE_BPS (30%) of the yield above the HWM.
 *      - VAULT_MANAGER can pause deposits, change the deposit cap and call harvest(); withdrawals work while paused.
 *      - Whitelist gating applies to withdraw/redeem, so removing a user from the whitelist blocks their exit.
 *      - The timelock only protects users if the admin is a multisig or contract whose actions they can watch.
 *
 *      Known limitations (prototype):
 *      - If the vault's idle balance is short, the shortfall is pulled through
 *        rebalancer.returnToVault(), which unwinds part of the LP and swaps into the asset
 *        (TWAP-checked). That call can revert (e.g. SwapPriceDeviation during an MEV-penalty
 *        window). maxWithdraw/maxRedeem do not reflect available liquidity.
 *      - Anyone can donate asset directly to the vault. This raises the share price for
 *        existing holders (and, with a fee module set, counts as yield) and cannot be blocked.
 */
contract CuratioVault is ERC4626, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant VAULT_MANAGER_ROLE = keccak256("VAULT_MANAGER_ROLE");

    /// @dev Virtual-share offset exponent (see contract NatSpec).
    uint8 private constant SHARE_DECIMALS_OFFSET = 6;
    /// @dev 10 ** SHARE_DECIMALS_OFFSET, the virtual shares OZ adds to totalSupply.
    uint256 private constant SHARE_SCALE = 10 ** uint256(SHARE_DECIMALS_OFFSET);
    /// @notice Fixed-point precision of sharePrice() and highWaterMark.
    uint256 public constant PRICE_PRECISION = 1e36;
    /// @notice Hard cap on the performance fee the vault will accept from ANY fee module.
    uint256 public constant MAX_PERFORMANCE_FEE_BPS = 3000; // 30% of the yield
    /// @notice Delay between proposing and executing a change of access contract, rebalancer or fee module.
    uint256 public constant ADMIN_TIMELOCK = 2 days;

    CuratioAccess public accessControl;
    ICuratioRebalancer public rebalancer;
    /// @notice Fee module (address(0) = performance fee disabled).
    ICuratioDynamicFee public feeModule;
    /// @notice True once a fee module has been set (initializeFeeModule or executeFeeModule). Never reset.
    bool public feeModuleInitialized;

    // Pending admin changes. An eta of 0 means "nothing pending" (a pending fee module may be address(0)).
    address public pendingAccessControl;
    uint256 public pendingAccessControlEta;
    address public pendingRebalancer;
    uint256 public pendingRebalancerEta;
    address public pendingFeeModule;
    uint256 public pendingFeeModuleEta;

    uint256 public depositCap;
    bool public depositsPaused;
    /// @notice Highest share price (PRICE_PRECISION scale) already accounted for. 0 = not yet baselined.
    uint256 public highWaterMark;

    mapping(address => address) public depositorToStrategist;

    event AccessControlUpdated(address indexed oldAccess, address indexed newAccess);
    event RebalancerUpdated(address indexed oldRebalancer, address indexed newRebalancer);
    event FeeModuleUpdated(address indexed oldModule, address indexed newModule);
    event AccessControlProposed(address indexed newAccess, uint256 eta);
    event RebalancerProposed(address indexed newRebalancer, uint256 eta);
    event FeeModuleProposed(address indexed newModule, uint256 eta);
    event AccessControlProposalCancelled(address indexed cancelled);
    event RebalancerProposalCancelled(address indexed cancelled);
    event FeeModuleProposalCancelled(address indexed cancelled);
    event DepositCapUpdated(uint256 newCap);
    event DepositsPausedToggled(bool paused);
    event FundsDeployed(uint256 amount);
    event RebalancerNotifyFailed(bool isDeposit, uint256 assets);
    event Harvested(uint256 yieldAssets, uint256 feeAssets, uint256 feeShares, uint256 newHighWaterMark);
    event StrategistFollowed(address indexed depositor, address indexed strategist);
    event StrategistUnfollowed(address indexed depositor, address indexed strategist);

    error NotWhitelisted(address user);
    error DepositCapExceeded(uint256 attempted, uint256 cap);
    error DepositsArePaused();
    error ZeroAddress();
    error ZeroAmount();
    /// @dev The call would mint zero shares (the caller would pay for nothing).
    error ZeroShares();
    /// @dev The call would burn shares and pay out zero assets.
    error ZeroAssets();
    error FeeModuleNotSet();
    error FeeModuleVaultMismatch();
    error FeeModuleAlreadyInitialized();
    /// @dev The fee module quoted a fee above the vault's cap (or above total assets).
    error InvalidFee(uint256 fee, uint256 yieldAmount);
    error NoPendingProposal();
    error TimelockNotElapsed(uint256 eta);

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

    /// @dev Virtual shares/assets offset used by OZ's ERC4626 math (inflation-attack protection).
    function _decimalsOffset() internal pure override returns (uint8) {
        return SHARE_DECIMALS_OFFSET;
    }

    /// @notice Asset value of one virtual share unit, scaled by PRICE_PRECISION. Strict like totalAssets().
    function sharePrice() external view returns (uint256) {
        return _sharePrice(totalAssets(), totalSupply());
    }

    function _sharePrice(uint256 assets, uint256 supply) internal pure returns (uint256) {
        return Math.mulDiv(assets + 1, PRICE_PRECISION, supply + SHARE_SCALE);
    }

    // ─── ERC-4626 limits (so integrators see the cap and the pause) ───────────

    /// @dev Never reverts: when the vault cannot be valued (TWAP outage) no deposit is possible, so 0.
    function maxDeposit(address) public view override returns (uint256) {
        if (depositsPaused) return 0;
        try this.totalAssets() returns (uint256 total) {
            if (depositCap == 0) return type(uint256).max;
            return total >= depositCap ? 0 : depositCap - total;
        } catch {
            return 0;
        }
    }

    function maxMint(address receiver) public view override returns (uint256) {
        uint256 maxAssets = maxDeposit(receiver);
        if (maxAssets == 0) return 0;
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
        if (shares == 0) revert ZeroShares(); // reverts the whole call, including the token pull
        _notifyRebalancerDeposit(assets);
        return shares;
    }

    function mint(uint256 shares, address receiver) public override nonReentrant returns (uint256) {
        _checkWhitelist(msg.sender);
        _checkWhitelist(receiver);
        _checkNotPaused();
        if (shares == 0) revert ZeroShares();
        _checkCap(previewMint(shares)); // check BEFORE pulling tokens

        uint256 assets = super.mint(shares, receiver);
        _notifyRebalancerDeposit(assets);
        return assets;
    }

    // ─── Withdraw / Redeem overrides ─────────────────────────────────────────

    function withdraw(uint256 assets, address receiver, address owner_) public override nonReentrant returns (uint256) {
        _checkWhitelist(msg.sender);
        _checkWhitelist(receiver);
        _checkWhitelist(owner_);

        uint256 shares = super.withdraw(assets, receiver, owner_);
        _notifyRebalancerWithdraw(assets);
        return shares;
    }

    function redeem(uint256 shares, address receiver, address owner_) public override nonReentrant returns (uint256) {
        _checkWhitelist(msg.sender);
        _checkWhitelist(receiver);
        _checkWhitelist(owner_);

        uint256 assets = super.redeem(shares, receiver, owner_);
        if (assets == 0) revert ZeroAssets(); // reverts the whole call, including the share burn
        _notifyRebalancerWithdraw(assets);
        return assets;
    }

    /// @dev If the vault's idle balance is short, pull the shortfall from the rebalancer first.
    ///      The rebalancer unwinds part of the LP and swaps if its own idle asset is short too.
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

    // ─── Performance fee ──────────────────────────────────────────────────────

    /// @notice Charge the performance fee on the share-price gain above the high-water mark.
    ///         Returns the fee shares minted (0 when there is nothing to charge).
    /// @dev Reverts while the TWAP is unavailable (totalAssets() is strict).
    function harvest() external onlyRole(VAULT_MANAGER_ROLE) nonReentrant returns (uint256 feeShares) {
        ICuratioDynamicFee module = feeModule;
        if (address(module) == address(0)) revert FeeModuleNotSet();

        uint256 supply = totalSupply();
        uint256 assets = totalAssets();
        uint256 price = _sharePrice(assets, supply);
        uint256 hwm = highWaterMark;

        // First harvest: record the baseline, charge nothing.
        if (hwm == 0) {
            highWaterMark = price;
            emit Harvested(0, 0, 0, price);
            return 0;
        }

        // No gain above the high-water mark.
        if (price <= hwm) return 0;

        // Gain in asset terms: (price - hwm) * (supply + virtual) / PRICE_PRECISION.
        uint256 yieldAssets = Math.mulDiv(price - hwm, supply + SHARE_SCALE, PRICE_PRECISION);
        uint256 feeAssets = module.calculatePerformanceFee(yieldAssets);
        if (feeAssets > Math.mulDiv(yieldAssets, MAX_PERFORMANCE_FEE_BPS, 10_000) || feeAssets > assets) {
            revert InvalidFee(feeAssets, yieldAssets);
        }

        if (feeAssets == 0) {
            // A zero rate forgives the gain, so a later rate increase cannot charge it retroactively.
            // A non-zero rate that rounds to zero keeps the HWM, so the gain accumulates.
            if (module.performanceFeeBps() == 0) {
                highWaterMark = price;
                emit Harvested(yieldAssets, 0, 0, price);
            }
            return 0;
        }

        // Shares worth exactly feeAssets after dilution: f * (A + 1) / (S + f + V) = fee  =>  f = fee * (S + V) / (A + 1 - fee)
        feeShares = Math.mulDiv(feeAssets, supply + SHARE_SCALE, assets + 1 - feeAssets);
        if (feeShares == 0) return 0; // dust: do not report a fee that was not paid

        _mint(module.feeRecipient(), feeShares);

        uint256 newPrice = _sharePrice(assets, supply + feeShares);
        if (newPrice < hwm) newPrice = hwm; // the HWM never decreases
        highWaterMark = newPrice;

        module.reportPerformanceFeeCharged(yieldAssets, feeAssets);
        emit Harvested(yieldAssets, feeAssets, feeShares, newPrice);
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

    function _checkFeeModule(address module) internal view {
        if (ICuratioDynamicFee(module).vault() != address(this)) revert FeeModuleVaultMismatch();
    }

    /// @dev Non-blocking: a failing rebalancer never blocks a deposit/withdrawal, but the
    ///      failure is visible on-chain.
    function _notifyRebalancerDeposit(uint256 assets) internal {
        try rebalancer.notifyDeposit(assets) {}
        catch {
            emit RebalancerNotifyFailed(true, assets);
        }
    }

    function _notifyRebalancerWithdraw(uint256 assets) internal {
        try rebalancer.notifyWithdraw(assets) {}
        catch {
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

    // ─── Admin: access contract (timelocked) ──────────────────────────────────

    function proposeAccessControl(address _accessControl) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_accessControl == address(0)) revert ZeroAddress();
        pendingAccessControl = _accessControl;
        pendingAccessControlEta = block.timestamp + ADMIN_TIMELOCK;
        emit AccessControlProposed(_accessControl, pendingAccessControlEta);
    }

    function executeAccessControl() external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 eta = pendingAccessControlEta;
        if (eta == 0) revert NoPendingProposal();
        if (block.timestamp < eta) revert TimelockNotElapsed(eta);

        address newAccess = pendingAccessControl;
        pendingAccessControl = address(0);
        pendingAccessControlEta = 0;

        emit AccessControlUpdated(address(accessControl), newAccess);
        accessControl = CuratioAccess(newAccess);
    }

    function cancelAccessControl() external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (pendingAccessControlEta == 0) revert NoPendingProposal();
        emit AccessControlProposalCancelled(pendingAccessControl);
        pendingAccessControl = address(0);
        pendingAccessControlEta = 0;
    }

    // ─── Admin: rebalancer (timelocked) ───────────────────────────────────────

    /// @dev The rebalancer prices every share. After execution the OLD rebalancer's holdings are no
    ///      longer counted, so move its funds back to the vault (or to the new rebalancer) first.
    function proposeRebalancer(address _rebalancer) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_rebalancer == address(0)) revert ZeroAddress();
        pendingRebalancer = _rebalancer;
        pendingRebalancerEta = block.timestamp + ADMIN_TIMELOCK;
        emit RebalancerProposed(_rebalancer, pendingRebalancerEta);
    }

    function executeRebalancer() external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 eta = pendingRebalancerEta;
        if (eta == 0) revert NoPendingProposal();
        if (block.timestamp < eta) revert TimelockNotElapsed(eta);

        address newRebalancer = pendingRebalancer;
        pendingRebalancer = address(0);
        pendingRebalancerEta = 0;

        emit RebalancerUpdated(address(rebalancer), newRebalancer);
        rebalancer = ICuratioRebalancer(newRebalancer);
    }

    function cancelRebalancer() external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (pendingRebalancerEta == 0) revert NoPendingProposal();
        emit RebalancerProposalCancelled(pendingRebalancer);
        pendingRebalancer = address(0);
        pendingRebalancerEta = 0;
    }

    // ─── Admin: fee module (initial set immediate, every later change timelocked) ──

    /// @notice One-time, immediate: sets the first fee module so deployment works (the module needs the
    ///         vault's address, so it cannot be a constructor argument). Reverts forever after any
    ///         module has been set, even if that module was later disabled.
    function initializeFeeModule(address module) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (feeModuleInitialized) revert FeeModuleAlreadyInitialized();
        if (module == address(0)) revert ZeroAddress();
        _checkFeeModule(module);

        feeModuleInitialized = true;
        pendingFeeModule = address(0);
        pendingFeeModuleEta = 0;

        emit FeeModuleUpdated(address(feeModule), module);
        feeModule = ICuratioDynamicFee(module);
        highWaterMark = 0;
    }

    /// @notice Propose a new fee module (address(0) disables fees). Applies after ADMIN_TIMELOCK.
    function proposeFeeModule(address module) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (module != address(0)) _checkFeeModule(module);
        pendingFeeModule = module;
        pendingFeeModuleEta = block.timestamp + ADMIN_TIMELOCK;
        emit FeeModuleProposed(module, pendingFeeModuleEta);
    }

    /// @notice Applies the pending fee module. The high-water mark is reset, so the next harvest only
    ///         records a new baseline and gains before it are free.
    function executeFeeModule() external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 eta = pendingFeeModuleEta;
        if (eta == 0) revert NoPendingProposal();
        if (block.timestamp < eta) revert TimelockNotElapsed(eta);

        address module = pendingFeeModule;
        if (module != address(0)) _checkFeeModule(module); // the module's vault may have changed since the proposal

        pendingFeeModule = address(0);
        pendingFeeModuleEta = 0;
        feeModuleInitialized = true;

        emit FeeModuleUpdated(address(feeModule), module);
        feeModule = ICuratioDynamicFee(module);
        highWaterMark = 0;
    }

    function cancelFeeModule() external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (pendingFeeModuleEta == 0) revert NoPendingProposal();
        emit FeeModuleProposalCancelled(pendingFeeModule);
        pendingFeeModule = address(0);
        pendingFeeModuleEta = 0;
    }

    // ─── Manager settings (immediate) ─────────────────────────────────────────

    function setDepositCap(uint256 _cap) external onlyRole(VAULT_MANAGER_ROLE) {
        depositCap = _cap;
        emit DepositCapUpdated(_cap);
    }

    function setDepositsPaused(bool _paused) external onlyRole(VAULT_MANAGER_ROLE) {
        depositsPaused = _paused;
        emit DepositsPausedToggled(_paused);
    }

    // ==========================================
    // ✅ NEW: Copy-LP / Delegated Liquidity Management
    // ==========================================
    function followStrategist(address strategist) external nonReentrant {
        _checkWhitelist(msg.sender); // ✅ এটি CuratioVault.NotWhitelisted এররটি নিক্ষেপ করবে

        address registryAddr = rebalancer.strategistRegistry();
        CuratioStrategistRegistry registry = CuratioStrategistRegistry(registryAddr);

        require(registry.isRegisteredStrategist(strategist), "Strategist not registered");
        require(registry.isActiveStrategist(strategist), "Strategist is inactive");

        depositorToStrategist[msg.sender] = strategist;
        emit StrategistFollowed(msg.sender, strategist);
    }

    /// @notice Allows a depositor to stop following a strategist.
    function unfollowStrategist() external nonReentrant {
        address currentStrategist = depositorToStrategist[msg.sender];
        require(currentStrategist != address(0), "Not following anyone");

        delete depositorToStrategist[msg.sender];
        emit StrategistUnfollowed(msg.sender, currentStrategist);
    }
}
