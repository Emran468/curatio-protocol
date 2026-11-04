// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CuratioDynamicFee} from "../../src/CuratioDynamicFee.sol";

contract CuratioDynamicFeeEchidnaTest {
    CuratioDynamicFee public feeModule;

    address public admin = address(this);
    address public vault = address(this); 
    address public feeRecipient = address(0x3);

    constructor() {
        feeModule = new CuratioDynamicFee(admin, vault, feeRecipient);
    }

    // ── Action Functions (Echidna will call these randomly) ──────────

    function set_fee(uint256 newBps) public {
        try feeModule.setPerformanceFeeBps(newBps) {} catch {}
    }

    function report_fee(uint256 yieldAmount, uint256 feeAmount) public {
        try feeModule.reportPerformanceFeeCharged(yieldAmount, feeAmount) {} catch {}
    }

    // ── Invariants (Must NEVER be broken) ────────────────────────

    function echidna_fee_never_exceeds_max_cap() public view returns (bool) {
        uint256 hardCap = 3000; 
        return feeModule.performanceFeeBps() <= hardCap;
    }

    /// @dev FIX: Removed the argument and used a hardcoded/fuzzed value inside
    function echidna_calculate_fee_is_safe() public view returns (bool) {
        // Use a fixed value to test the invariant, or use the action function to set a state variable
        uint256 yieldAmount = 1e18; // 1 token
        
        uint256 fee = feeModule.calculatePerformanceFee(yieldAmount);
        
        // The fee should never be greater than 30% of the yield amount
        return fee <= (yieldAmount * feeModule.MAX_PERFORMANCE_FEE_BPS()) / 10000;
    }
}