// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice Guards the migration of the old "finding" tests into regression tests.
///
///         1. No Solidity file under `test/` may still contain a function whose name starts with the old
///            prefix (built at runtime below, so this file does not trip over itself).
///         2. Every regression test that the README names must exist as a function in some test file.
///
///         It needs read access to the test folder. Add this to `foundry.toml`, in the profile you run:
///             fs_permissions = [{ access = "read", path = "./test" }]
///
///         It cannot pass vacuously: it fails if it scans too few files, and it names the exact file or
///         test when something is wrong.
contract CuratioFindingsMigrationTest is Test {
    function test_noObsoleteFindingTestsRemain_andRegressionTestsExist() public view {
        string memory obsoletePrefix = string.concat("function test_", "finding_");

        string[] memory expected = new string[](13);
        expected[0] = "test_fix_unichainDefaultOracleDepth";
        expected[1] = "test_fix_busyPool_oracleStaysWarm_vaultKeepsWorking";
        expected[2] = "test_fix_growthAfterWrap_isDeferred_oracleStaysHealthy";
        expected[3] = "test_fix_penaltyEndsWithTheFlaggedBlock";
        expected[4] = "test_swapPath_withdrawNeedingSwap_revertsInSandwichBlock";
        expected[5] = "test_swapPath_withdrawNeedingSwap_succeedsAfterFeeDecay";
        expected[6] = "test_swapPath_withdrawWithinIdle_worksDuringPenalty";
        expected[7] = "test_swapPath_keeperTwoSidedRange_revertsInSandwichBlock";
        expected[8] = "test_swapPath_keeperTwoSidedRange_succeedsOneBlockAfterSandwich";
        expected[9] = "test_decimals_usdcDenominatedSandwich_isDetected";
        expected[10] = "test_decimals_wethDenominatedSandwich_isStillDetected";
        expected[11] = "test_decimals_dustRoundTrips_areNotFlagged_inEitherDirection";
        expected[12] = "test_decimals_sandwichTickThreshold_isTunableInTicks";

        bool[] memory found = new bool[](expected.length);

        Vm.DirEntry[] memory entries = vm.readDir("test", 6);
        uint256 scanned;

        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].isDir) continue;
            if (!_endsWith(entries[i].path, ".sol")) continue;

            string memory src = vm.readFile(entries[i].path);
            scanned++;

            assertFalse(
                _contains(src, obsoletePrefix),
                string.concat("obsolete old-prefix test still present in: ", entries[i].path)
            );

            for (uint256 j = 0; j < expected.length; j++) {
                if (!found[j] && _contains(src, string.concat("function ", expected[j], "("))) {
                    found[j] = true;
                }
            }
        }

        assertGt(scanned, 10, "scanned too few files: wrong path or missing fs_permissions");

        for (uint256 j = 0; j < expected.length; j++) {
            assertTrue(found[j], string.concat("missing regression test: ", expected[j]));
        }
    }

    // ─────────────────────────── helpers ───────────────────────────

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length == 0 || h.length < n.length) return false;

        for (uint256 i = 0; i <= h.length - n.length; i++) {
            if (h[i] != n[0]) continue;
            bool match_ = true;
            for (uint256 j = 1; j < n.length; j++) {
                if (h[i + j] != n[j]) {
                    match_ = false;
                    break;
                }
            }
            if (match_) return true;
        }
        return false;
    }

    function _endsWith(string memory s, string memory suffix) internal pure returns (bool) {
        bytes memory a = bytes(s);
        bytes memory b = bytes(suffix);
        if (a.length < b.length) return false;
        for (uint256 i = 0; i < b.length; i++) {
            if (a[a.length - b.length + i] != b[i]) return false;
        }
        return true;
    }
}
