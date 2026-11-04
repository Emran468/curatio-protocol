// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CuratioDynamicFee} from "../../src/CuratioDynamicFee.sol";

contract CuratioDynamicFeeEchidnaTest {
    CuratioDynamicFee public feeModule;

    address public admin = address(this);
    // ✅ FIX 1: vault-কে address(this) করে দিন, যাতে onlyVault চেক পাস হয়
    address public vault = address(this); 
    address public feeRecipient = address(0x3);

    constructor() {
        feeModule = new CuratioDynamicFee(admin, vault, feeRecipient);
    }

    // ── Action Functions (Echidna will call these randomly) ──────────

    /// @dev Echidna will randomly call this to try and set a new fee rate.
    function set_fee(uint256 newBps) public {
        // If Echidna passes a value above 3000, it should revert.
        // We use try/catch so the fuzzer keeps running instead of crashing on reverts.
        try feeModule.setPerformanceFeeBps(newBps) {} catch {}
    }

    /// @dev Echidna will randomly call this to try and report fees.
    function report_fee(uint256 yieldAmount, uint256 feeAmount) public {
        // ✅ FIX 2: vm.prank সরিয়ে ফেলা হয়েছে। যেহেতু address(this) হলো vault, তাই সরাসরি কল হবে।
        try feeModule.reportPerformanceFeeCharged(yieldAmount, feeAmount) {} catch {}
    }

    // ── Invariants (Must NEVER be broken) ────────────────────────

    /// @dev Invariant 1: The performance fee BPS must NEVER exceed the 30% (3000 bps) hard cap.
    function echidna_fee_never_exceeds_max_cap() public view returns (bool) {
        uint256 hardCap = 3000; // 30%
        return feeModule.performanceFeeBps() <= hardCap;
    }

    /// @dev Invariant 2: The fee calculation must NEVER exceed 30% of the yield.
    function echidna_calculate_fee_is_safe(uint256 yieldAmount) public view returns (bool) {
        // Truncate to avoid overflow in the test itself
        yieldAmount = yieldAmount % 1e30; 
        
        uint256 fee = feeModule.calculatePerformanceFee(yieldAmount);
        
        // The fee should never be greater than 30% of the yield amount
        return fee <= (yieldAmount * feeModule.MAX_PERFORMANCE_FEE_BPS()) / 10000;
    }
}