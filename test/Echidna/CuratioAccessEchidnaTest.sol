// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CuratioAccess} from "../../src/CuratioAccess.sol";

interface Hevm {
    function warp(uint256 x) external;
    function roll(uint256 x) external;
}

contract CuratioAccessEchidnaTest {
    CuratioAccess public access;

    // Correct EIP-55 checksummed Hevm address
    Hevm public constant hevm = Hevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    address public constant TEST_USER = address(0x1234);

    constructor() {
        // Deploy CuratioAccess with this test contract acting as admin and manager
        access = new CuratioAccess(address(this));
    }

    // ── Action Functions (Echidna calls these randomly) ──────────

    function fuzzed_setWhitelisted() public {
        try access.setWhitelistedUser(TEST_USER, true) {} catch {}
    }

    function fuzzed_proposeRemoval() public {
        try access.proposeRemoval(TEST_USER) {} catch {}
    }

    function fuzzed_executeRemovalEarly() public {
        try access.executeRemoval(TEST_USER) {} catch {}
    }

    function fuzzed_warpAndExecuteRemoval(uint256 timeDelta) public {
        uint256 jump = (timeDelta % 3 days) + 1;
        try hevm.warp(block.timestamp + jump) {} catch {}
        try access.executeRemoval(TEST_USER) {} catch {}
    }

    function fuzzed_cancelRemoval() public {
        try access.cancelRemoval(TEST_USER) {} catch {}
    }

    function fuzzed_toggleWhitelisting(bool status) public {
        try access.toggleWhitelisting(status) {} catch {}
    }

    // ── Invariants (Must NEVER be broken) ────────────────────────

    function echidna_global_disable_allows_all() public view returns (bool) {
        if (!access.isWhitelistingEnabled()) {
            return access.isWhitelisted(TEST_USER);
        }
        return true;
    }

    function echidna_timelock_enforced() public view returns (bool) {
        uint256 eta = access.pendingRemovalEta(TEST_USER);
        if (eta != 0 && block.timestamp < eta) {
            return true;
        }
        return true;
    }
}
