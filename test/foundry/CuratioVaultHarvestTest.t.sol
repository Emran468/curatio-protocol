// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CuratioVault} from "../../src/CuratioVault.sol";
import {CuratioAccess} from "../../src/CuratioAccess.sol";
import {CuratioDynamicFee} from "../../src/CuratioDynamicFee.sol";

contract HarvToken is ERC20 {
    constructor() ERC20("Mock", "MCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

/// @dev Holds idle asset only: totalManagedAssets = its asset balance. `down` simulates a TWAP outage.
contract HarvRebalancer {
    IERC20 public immutable asset;
    bool public down;

    constructor(IERC20 a) {
        asset = a;
    }

    function setDown(bool d) external {
        down = d;
    }

    function notifyDeposit(uint256) external {}
    function notifyWithdraw(uint256) external {}

    function totalManagedAssets() external view returns (uint256) {
        require(!down, "twap down");
        return asset.balanceOf(address(this));
    }

    function returnToVault(uint256 amount) external {
        asset.transfer(msg.sender, amount);
    }
}

/// @dev Misbehaving module: always quotes a fee ABOVE the yield.
contract HarvEvilFeeModule {
    address public vault;
    address public feeRecipient;
    uint256 public performanceFeeBps = 1000;

    constructor(address v, address r) {
        vault = v;
        feeRecipient = r;
    }

    function calculatePerformanceFee(uint256 yieldAmount) external pure returns (uint256) {
        return yieldAmount + 1;
    }

    function reportPerformanceFeeCharged(uint256, uint256) external {}
}

/// @dev Quotes 31% of the yield, one point above the vault's own cap.
contract HarvGreedyFeeModule {
    address public vault;
    address public feeRecipient;
    uint256 public performanceFeeBps = 3100;

    constructor(address v, address r) {
        vault = v;
        feeRecipient = r;
    }

    function calculatePerformanceFee(uint256 yieldAmount) external pure returns (uint256) {
        return (yieldAmount * 3100) / 10_000;
    }

    function reportPerformanceFeeCharged(uint256, uint256) external {}
}

/// @notice Fee-module management (initialize / propose / execute / cancel) and the performance fee (harvest)
///         with a high-water mark: fee shares are minted to the recipient.
contract CuratioVaultHarvestTest is Test {
    HarvToken asset;
    HarvRebalancer reb;
    CuratioAccess access;
    CuratioVault vault;
    CuratioDynamicFee fee;

    address admin = makeAddr("admin");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address feeRecipient = makeAddr("feeRecipient");
    address outsider = makeAddr("outsider");
    address attacker = makeAddr("attacker");

    event Harvested(uint256 yieldAssets, uint256 feeAssets, uint256 feeShares, uint256 newHighWaterMark);
    event FeeModuleUpdated(address indexed oldModule, address indexed newModule);

    function setUp() public {
        asset = new HarvToken();
        reb = new HarvRebalancer(IERC20(address(asset)));
        access = new CuratioAccess(admin);
        vault = new CuratioVault(IERC20(address(asset)), address(access), address(reb), admin, 0); // uncapped
        fee = new CuratioDynamicFee(admin, address(vault), feeRecipient);

        vm.startPrank(admin);
        access.setWhitelistedUser(alice, true);
        access.setWhitelistedUser(bob, true);
        access.setWhitelistedUser(feeRecipient, true);
        vault.initializeFeeModule(address(fee));
        vm.stopPrank();

        address[2] memory users = [alice, bob];
        for (uint256 i = 0; i < users.length; i++) {
            asset.mint(users[i], 1e30);
            vm.prank(users[i]);
            asset.approve(address(vault), type(uint256).max);
        }
    }

    // ── helpers ──────────────────────────────────────────────────────────

    function _deposit(address who, uint256 amt) internal returns (uint256 shares) {
        vm.prank(who);
        shares = vault.deposit(amt, who);
    }

    function _harvest() internal returns (uint256 feeShares) {
        vm.prank(admin);
        feeShares = vault.harvest();
    }

    /// Free money arrives (yield stand-in): raises the share price.
    function _gain(uint256 amt) internal {
        asset.mint(address(vault), amt);
    }

    function _loss(uint256 amt) internal {
        asset.burn(address(vault), amt);
    }

    /// Replaces (or, with address(0), disables) the fee module through the full timelock.
    function _swapFeeModule(address module) internal {
        vm.startPrank(admin);
        vault.proposeFeeModule(module);
        vm.warp(block.timestamp + vault.ADMIN_TIMELOCK());
        vault.executeFeeModule();
        vm.stopPrank();
    }

    /// A vault that has not been given a fee module yet, plus a matching module.
    function _freshVault() internal returns (CuratioVault v, CuratioDynamicFee f) {
        v = new CuratioVault(IERC20(address(asset)), address(access), address(reb), admin, 0);
        f = new CuratioDynamicFee(admin, address(v), feeRecipient);
    }

    // ── initializeFeeModule (one-time, immediate) ────────────────────────

    function test_initializeFeeModule_onlyAdmin() public {
        (CuratioVault v, CuratioDynamicFee f) = _freshVault();

        vm.prank(attacker);
        vm.expectRevert();
        v.initializeFeeModule(address(f));
    }

    function test_initializeFeeModule_revertsOnZero() public {
        (CuratioVault v,) = _freshVault();

        vm.prank(admin);
        vm.expectRevert(CuratioVault.ZeroAddress.selector);
        v.initializeFeeModule(address(0));
    }

    function test_initializeFeeModule_revertsOnVaultMismatch() public {
        (CuratioVault v,) = _freshVault();
        CuratioDynamicFee other = new CuratioDynamicFee(admin, makeAddr("someOtherVault"), feeRecipient);

        vm.prank(admin);
        vm.expectRevert(CuratioVault.FeeModuleVaultMismatch.selector);
        v.initializeFeeModule(address(other));
    }

    function test_initializeFeeModule_revertsWhenAlreadyInitialized() public {
        // setUp already initialized `vault`
        CuratioDynamicFee newFee = new CuratioDynamicFee(admin, address(vault), feeRecipient);

        vm.prank(admin);
        vm.expectRevert(CuratioVault.FeeModuleAlreadyInitialized.selector);
        vault.initializeFeeModule(address(newFee));
    }

    function test_initializeFeeModule_setsModuleAndEmits() public {
        (CuratioVault v, CuratioDynamicFee f) = _freshVault();
        assertFalse(v.feeModuleInitialized());

        vm.expectEmit(true, true, false, false, address(v));
        emit FeeModuleUpdated(address(0), address(f));
        vm.prank(admin);
        v.initializeFeeModule(address(f));

        assertEq(address(v.feeModule()), address(f));
        assertTrue(v.feeModuleInitialized());
        assertEq(v.highWaterMark(), 0);
    }

    // ── proposeFeeModule ─────────────────────────────────────────────────

    function test_proposeFeeModule_onlyAdmin() public {
        vm.prank(attacker);
        vm.expectRevert();
        vault.proposeFeeModule(address(fee));
    }

    function test_proposeFeeModule_revertsOnVaultMismatch() public {
        CuratioDynamicFee other = new CuratioDynamicFee(admin, makeAddr("someOtherVault"), feeRecipient);

        vm.prank(admin);
        vm.expectRevert(CuratioVault.FeeModuleVaultMismatch.selector);
        vault.proposeFeeModule(address(other));
    }

    function test_proposeFeeModule_setsPendingAndEmits() public {
        CuratioDynamicFee newFee = new CuratioDynamicFee(admin, address(vault), feeRecipient);
        uint256 expectedEta = block.timestamp + vault.ADMIN_TIMELOCK();

        vm.expectEmit(true, false, false, true, address(vault));
        emit CuratioVault.FeeModuleProposed(address(newFee), expectedEta);

        vm.prank(admin);
        vault.proposeFeeModule(address(newFee));

        assertEq(vault.pendingFeeModule(), address(newFee));
        assertEq(vault.pendingFeeModuleEta(), expectedEta);
        assertEq(address(vault.feeModule()), address(fee), "must not change on propose");
    }

    function test_proposeFeeModule_allowsZeroToDisable() public {
        vm.prank(admin);
        vault.proposeFeeModule(address(0));

        assertEq(vault.pendingFeeModule(), address(0));
        assertGt(vault.pendingFeeModuleEta(), 0, "the eta marks that a proposal exists");
        assertEq(address(vault.feeModule()), address(fee), "must not change on propose");
    }

    // ── executeFeeModule ─────────────────────────────────────────────────

    function test_executeFeeModule_revertsWithNoProposal() public {
        vm.prank(admin);
        vm.expectRevert(CuratioVault.NoPendingProposal.selector);
        vault.executeFeeModule();
    }

    function test_executeFeeModule_revertsBeforeTimelock() public {
        CuratioDynamicFee newFee = new CuratioDynamicFee(admin, address(vault), feeRecipient);

        vm.prank(admin);
        vault.proposeFeeModule(address(newFee));
        uint256 eta = vault.pendingFeeModuleEta();

        vm.warp(eta - 1);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CuratioVault.TimelockNotElapsed.selector, eta));
        vault.executeFeeModule();

        assertEq(address(vault.feeModule()), address(fee), "must not change early");
        assertEq(vault.pendingFeeModule(), address(newFee), "proposal must survive a failed execute");
    }

    /// Boundary: the check is `block.timestamp < eta`, so executing exactly at eta must work.
    function test_executeFeeModule_succeedsExactlyAtEta() public {
        CuratioDynamicFee newFee = new CuratioDynamicFee(admin, address(vault), feeRecipient);

        vm.prank(admin);
        vault.proposeFeeModule(address(newFee));

        vm.warp(vault.pendingFeeModuleEta());
        vm.prank(admin);
        vault.executeFeeModule();

        assertEq(address(vault.feeModule()), address(newFee));
    }

    function test_executeFeeModule_updatesStateAndEmits() public {
        CuratioDynamicFee newFee = new CuratioDynamicFee(admin, address(vault), feeRecipient);

        vm.startPrank(admin);
        vault.proposeFeeModule(address(newFee));
        vm.warp(block.timestamp + vault.ADMIN_TIMELOCK() + 1);

        vm.expectEmit(true, true, false, false, address(vault));
        emit FeeModuleUpdated(address(fee), address(newFee));
        vault.executeFeeModule();
        vm.stopPrank();

        assertEq(address(vault.feeModule()), address(newFee));
        assertEq(vault.pendingFeeModule(), address(0), "pending must be cleared");
        assertEq(vault.pendingFeeModuleEta(), 0, "eta must be cleared");
    }

    function test_executeFeeModule_onlyAdmin() public {
        CuratioDynamicFee newFee = new CuratioDynamicFee(admin, address(vault), feeRecipient);

        vm.prank(admin);
        vault.proposeFeeModule(address(newFee));
        vm.warp(block.timestamp + vault.ADMIN_TIMELOCK());

        vm.prank(attacker);
        vm.expectRevert();
        vault.executeFeeModule();

        assertEq(address(vault.feeModule()), address(fee), "attacker must not apply the change");
    }

    function test_executeFeeModule_cannotBeReplayed() public {
        CuratioDynamicFee newFee = new CuratioDynamicFee(admin, address(vault), feeRecipient);

        vm.startPrank(admin);
        vault.proposeFeeModule(address(newFee));
        vm.warp(block.timestamp + vault.ADMIN_TIMELOCK());
        vault.executeFeeModule();

        vm.expectRevert(CuratioVault.NoPendingProposal.selector);
        vault.executeFeeModule();
        vm.stopPrank();
    }

    /// The module's own admin can repoint it at another vault after the proposal: execution must notice.
    function test_executeFeeModule_rechecksVaultAtExecution() public {
        CuratioDynamicFee newFee = new CuratioDynamicFee(admin, address(vault), feeRecipient);

        vm.prank(admin);
        vault.proposeFeeModule(address(newFee));

        vm.prank(admin); // admin is also the module's DEFAULT_ADMIN
        newFee.setVault(makeAddr("someOtherVault"));

        vm.warp(block.timestamp + vault.ADMIN_TIMELOCK());
        vm.prank(admin);
        vm.expectRevert(CuratioVault.FeeModuleVaultMismatch.selector);
        vault.executeFeeModule();

        assertEq(address(vault.feeModule()), address(fee), "a mismatched module must never be applied");
    }

    function test_executeFeeModule_resetsHighWaterMark() public {
        _deposit(alice, 100 ether);
        _harvest(); // baseline
        assertGt(vault.highWaterMark(), 0);

        _swapFeeModule(address(new CuratioDynamicFee(admin, address(vault), feeRecipient)));

        assertEq(vault.highWaterMark(), 0, "replacing the module must re-baseline");
    }

    function test_executeFeeModule_gainsBeforeRebaselineAreFree() public {
        _deposit(alice, 100 ether);
        _harvest(); // baseline
        _gain(10 ether);

        _swapFeeModule(address(fee)); // re-registering the same module also re-baselines

        assertEq(_harvest(), 0, "first harvest after a reset only records the baseline");
        assertEq(fee.totalFeesCharged(), 0);
    }

    // ── cancelFeeModule ──────────────────────────────────────────────────

    function test_cancelFeeModule_clearsPending() public {
        vm.startPrank(admin);
        vault.proposeFeeModule(address(new CuratioDynamicFee(admin, address(vault), feeRecipient)));
        vault.cancelFeeModule();
        vm.stopPrank();

        assertEq(vault.pendingFeeModule(), address(0));
        assertEq(vault.pendingFeeModuleEta(), 0);

        vm.warp(block.timestamp + vault.ADMIN_TIMELOCK() + 1);
        vm.prank(admin);
        vm.expectRevert(CuratioVault.NoPendingProposal.selector);
        vault.executeFeeModule();
    }

    function test_cancelFeeModule_revertsWithNoProposal() public {
        vm.prank(admin);
        vm.expectRevert(CuratioVault.NoPendingProposal.selector);
        vault.cancelFeeModule();
    }

    function test_cancelFeeModule_onlyAdmin() public {
        vm.prank(admin);
        vault.proposeFeeModule(address(0));

        vm.prank(attacker);
        vm.expectRevert();
        vault.cancelFeeModule();

        assertGt(vault.pendingFeeModuleEta(), 0, "attacker must not cancel");
    }

    /// Disabling the module must not reopen the immediate initialize path (a way around the delay).
    function test_disabledModule_cannotBeReinitializedWithoutTimelock() public {
        _swapFeeModule(address(0)); // disabled, through the delay
        assertEq(address(vault.feeModule()), address(0));

        CuratioDynamicFee newFee = new CuratioDynamicFee(admin, address(vault), feeRecipient);
        vm.prank(admin);
        vm.expectRevert(CuratioVault.FeeModuleAlreadyInitialized.selector);
        vault.initializeFeeModule(address(newFee));
    }

    // ── harvest: access and preconditions ────────────────────────────────

    function test_harvest_onlyManager() public {
        vm.prank(attacker);
        vm.expectRevert();
        vault.harvest();
    }

    function test_harvest_revertsWhenNoFeeModule() public {
        _swapFeeModule(address(0));

        vm.prank(admin);
        vm.expectRevert(CuratioVault.FeeModuleNotSet.selector);
        vault.harvest();
    }

    function test_harvest_revertsDuringTwapOutage_andChangesNothing() public {
        _deposit(alice, 100 ether);
        _harvest(); // baseline
        _gain(10 ether);
        uint256 hwmBefore = vault.highWaterMark();
        uint256 supplyBefore = vault.totalSupply();

        reb.setDown(true);
        vm.prank(admin);
        vm.expectRevert();
        vault.harvest();
        reb.setDown(false);

        assertEq(vault.highWaterMark(), hwmBefore, "HWM must not move on a failed harvest");
        assertEq(vault.totalSupply(), supplyBefore, "no shares may be minted on a failed harvest");
    }

    // ── harvest: baseline and no-gain ────────────────────────────────────

    function test_harvest_firstCallSetsBaseline_chargesNothing() public {
        _deposit(alice, 100 ether);
        uint256 supplyBefore = vault.totalSupply();

        uint256 feeShares = _harvest();

        assertEq(feeShares, 0);
        assertEq(vault.highWaterMark(), vault.sharePrice(), "baseline is the current price");
        assertEq(vault.totalSupply(), supplyBefore);
        assertEq(fee.totalFeesCharged(), 0);
        assertEq(fee.totalYieldProcessed(), 0);
    }

    function test_harvest_emitsHarvestedOnBaseline() public {
        _deposit(alice, 100 ether);

        vm.expectEmit(false, false, false, false, address(vault));
        emit Harvested(0, 0, 0, 0);
        _harvest();
    }

    function test_harvest_noGain_changesNothing() public {
        _deposit(alice, 100 ether);
        _harvest(); // baseline
        uint256 hwmBefore = vault.highWaterMark();
        uint256 supplyBefore = vault.totalSupply();

        assertEq(_harvest(), 0);

        assertEq(vault.highWaterMark(), hwmBefore);
        assertEq(vault.totalSupply(), supplyBefore);
        assertEq(fee.totalFeesCharged(), 0);
    }

    // ── harvest: the fee itself ──────────────────────────────────────────

    function test_harvest_chargesFeeOnGain_andMintsSharesToRecipient() public {
        uint256 aliceShares = _deposit(alice, 100 ether);
        _harvest(); // baseline
        _gain(10 ether);

        uint256 assetsBefore = vault.totalAssets();
        uint256 supplyBefore = vault.totalSupply();

        uint256 feeShares = _harvest();

        // shares were minted to the recipient and nowhere else
        assertGt(feeShares, 0, "a fee must be charged");
        assertEq(vault.totalSupply(), supplyBefore + feeShares);
        assertEq(vault.balanceOf(feeRecipient), feeShares);
        assertEq(vault.balanceOf(alice), aliceShares, "alice's shares must not change");

        // no asset moved
        assertEq(vault.totalAssets(), assetsBefore, "harvest must not move assets");

        // 10% of a 10 ether gain
        assertApproxEqAbs(fee.totalYieldProcessed(), 10 ether, 1e3);
        assertApproxEqAbs(fee.totalFeesCharged(), 1 ether, 1e3);

        // the recipient's shares are worth the fee (never more), holders keep the rest
        uint256 recipientValue = vault.convertToAssets(feeShares);
        assertLe(recipientValue, fee.totalFeesCharged(), "recipient must never be over-paid");
        assertApproxEqAbs(recipientValue, fee.totalFeesCharged(), 1e3);
        assertApproxEqAbs(vault.convertToAssets(aliceShares), 109 ether, 1e4);

        // the new price is the new high-water mark
        assertEq(vault.highWaterMark(), vault.sharePrice(), "HWM must equal the post-fee price");
    }

    function test_harvest_secondCallRightAfter_chargesNothing() public {
        _deposit(alice, 100 ether);
        _harvest(); // baseline
        _gain(10 ether);
        _harvest(); // charges the fee

        uint256 supplyBefore = vault.totalSupply();
        uint256 feesBefore = fee.totalFeesCharged();
        uint256 hwmBefore = vault.highWaterMark();

        assertEq(_harvest(), 0, "the same gain must never be charged twice");

        assertEq(vault.totalSupply(), supplyBefore);
        assertEq(fee.totalFeesCharged(), feesBefore);
        assertEq(vault.highWaterMark(), hwmBefore);
    }

    function test_harvest_lossThenRecovery_chargesOnlyAboveHighWaterMark() public {
        _deposit(alice, 100 ether);
        _harvest(); // baseline at 100
        _gain(10 ether); // 110
        _harvest(); // fee ~ 1 ether, HWM ~ 110
        uint256 feesAfterFirst = fee.totalFeesCharged();
        uint256 hwmAfterFirst = vault.highWaterMark();

        _loss(20 ether); // 90, below the HWM
        assertEq(_harvest(), 0, "no fee while below the HWM");
        assertEq(fee.totalFeesCharged(), feesAfterFirst);
        assertEq(vault.highWaterMark(), hwmAfterFirst, "a loss must not lower the HWM");

        _gain(15 ether); // 105, recovered but still below 110
        assertEq(_harvest(), 0, "recovery up to the old HWM is not yield");
        assertEq(fee.totalFeesCharged(), feesAfterFirst);

        _gain(10 ether); // 115, 5 above the old HWM
        assertGt(_harvest(), 0);
        assertApproxEqAbs(fee.totalFeesCharged() - feesAfterFirst, 0.5 ether, 1e3, "10% of the 5 ether above the HWM");
    }

    function test_harvest_zeroRate_forgivesGain_noRetroactiveCharge() public {
        vm.prank(admin);
        fee.setPerformanceFeeBps(0);

        _deposit(alice, 100 ether);
        _harvest(); // baseline
        _gain(10 ether);

        assertEq(_harvest(), 0, "no fee at a zero rate");
        assertEq(vault.highWaterMark(), vault.sharePrice(), "the gain is forgiven: HWM moves up");

        vm.prank(admin);
        fee.setPerformanceFeeBps(1000);

        assertEq(_harvest(), 0, "raising the rate must not charge the old gain");
        assertEq(fee.totalFeesCharged(), 0);
    }

    function test_harvest_userActionsNeverTouchHighWaterMark() public {
        _deposit(alice, 100 ether);
        _harvest(); // baseline
        uint256 hwm = vault.highWaterMark();

        _deposit(bob, 50 ether);
        vm.prank(alice);
        vault.withdraw(30 ether, alice, alice);

        assertEq(vault.highWaterMark(), hwm, "only harvest and a fee-module change may change the HWM");
    }

    // ── recipient, modules ───────────────────────────────────────────────

    function test_harvest_feeRecipientCanRedeemItsShares() public {
        _deposit(alice, 100 ether);
        _harvest(); // baseline
        _gain(10 ether);
        uint256 feeShares = _harvest();

        uint256 before_ = asset.balanceOf(feeRecipient);
        vm.prank(feeRecipient);
        uint256 out = vault.redeem(feeShares, feeRecipient, feeRecipient);

        assertEq(asset.balanceOf(feeRecipient), before_ + out);
        assertLe(out, fee.totalFeesCharged(), "the recipient cannot redeem more than the fee");
        assertApproxEqAbs(out, fee.totalFeesCharged(), 1e3);
    }

    /// Documents the whitelist interaction: shares are minted regardless, but redeeming needs whitelisting.
    function test_harvest_mintsToNonWhitelistedRecipient_whoCannotRedeem() public {
        CuratioDynamicFee outsiderFee = new CuratioDynamicFee(admin, address(vault), outsider);
        _swapFeeModule(address(outsiderFee));

        _deposit(alice, 100 ether);
        _harvest(); // baseline
        _gain(10 ether);
        uint256 feeShares = _harvest();

        assertGt(feeShares, 0);
        assertEq(vault.balanceOf(outsider), feeShares);

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(CuratioVault.NotWhitelisted.selector, outsider));
        vault.redeem(feeShares, outsider, outsider);
    }

    function test_harvest_revertsIfModuleChargesMoreThanYield() public {
        _swapFeeModule(address(new HarvEvilFeeModule(address(vault), feeRecipient)));

        _deposit(alice, 100 ether);
        _harvest(); // baseline
        _gain(10 ether);

        vm.prank(admin);
        try vault.harvest() {
            fail("a fee above the yield must revert");
        } catch (bytes memory err) {
            assertEq(bytes4(err), CuratioVault.InvalidFee.selector);
        }
    }

    function test_harvest_revertsIfModuleChargesAboveVaultCap() public {
        _swapFeeModule(address(new HarvGreedyFeeModule(address(vault), feeRecipient)));

        _deposit(alice, 100 ether);
        _harvest(); // baseline
        _gain(10 ether);

        vm.prank(admin);
        try vault.harvest() {
            fail("a fee above the vault cap must revert");
        } catch (bytes memory err) {
            assertEq(bytes4(err), CuratioVault.InvalidFee.selector);
        }
    }

    function test_harvest_acceptsFeeExactlyAtVaultCap() public {
        vm.prank(admin);
        fee.setPerformanceFeeBps(3000); // the module's own maximum, equal to the vault cap

        _deposit(alice, 100 ether);
        _harvest(); // baseline
        _gain(10 ether);

        assertGt(_harvest(), 0);
        assertApproxEqAbs(fee.totalFeesCharged(), 3 ether, 1e3);
    }

    // ── max* never revert (ERC-4626) ─────────────────────────────────────

    function test_max_returnZeroInsteadOfRevertingDuringTwapOutage() public {
        vm.prank(admin);
        vault.setDepositCap(1000 ether);
        reb.setDown(true);

        assertEq(vault.maxDeposit(alice), 0);
        assertEq(vault.maxMint(alice), 0);
    }

    function test_max_uncappedAlsoReturnsZeroDuringTwapOutage() public {
        reb.setDown(true); // this suite's vault is uncapped
        assertEq(vault.maxDeposit(alice), 0);
        assertEq(vault.maxMint(alice), 0);

        reb.setDown(false);
        assertEq(vault.maxDeposit(alice), type(uint256).max);
    }

    // ── fuzz ─────────────────────────────────────────────────────────────

    /// Whatever the deposit, gain and rate: the fee never exceeds rate x gain, and holders never lose.
    function testFuzz_harvest_feeNeverExceedsRateTimesGain(uint256 dep, uint256 gain, uint256 bps) public {
        dep = bound(dep, 1e6, 1e27);
        gain = bound(gain, 1, 1e27);
        bps = bound(bps, 0, 3000);

        vm.prank(admin);
        fee.setPerformanceFeeBps(bps);

        uint256 shares = _deposit(alice, dep);
        _harvest(); // baseline
        _gain(gain);
        _harvest();

        uint256 charged = fee.totalFeesCharged();
        assertLe(charged, ((gain + 2) * bps) / 10_000, "fee must not exceed rate x gain");
        assertLe(charged, fee.totalYieldProcessed(), "fee must not exceed the yield");
        assertGe(vault.convertToAssets(shares) + 1, dep, "existing holders must never lose value");
        assertEq(vault.totalAssets(), dep + gain, "harvest must not move assets");
    }
}
