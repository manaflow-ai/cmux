#!/usr/bin/env python3
"""scripts/ci/ios_reliability_matrix.py: test logs in, one table out, gating cells decide the exit."""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts" / "ci"))
import ios_reliability_matrix as matrix  # noqa: E402

RUST_LOG = """\
running 2 tests
test host_recovery_tests::wake_recovers_signaling_and_phone_dial ... ok
test wireguard_resumes_after_airplane_mode ... ok
test result: ok. 2 passed; 0 failed
running 2 tests
test cell_scale_session_list ... MATRIX {"cell":"scale","variant":"1","list_ms":2.5}
MATRIX {"cell":"scale","variant":"god-5000","list_ms":40.0}
thread 'cell_scale_session_list' panicked at x.rs:1:1:
FAILED
test cell_host_daemon_restart ... MATRIX {"cell":"restart","variant":"small-1"}
ok

failures:

---- cell_scale_session_list stdout ----

failures:
    cell_scale_session_list

test result: FAILED. 1 passed; 1 failed
"""
IOS_LOG = """\
MATRIX {"cell":"offline","reconnect_ms":550.0,"variant":"small-10s"}
✔ Test cellNetworkOfflineThenBack() passed after 0.001 seconds.
✘ Test cellPairingRevokedToken() failed after 0.010 seconds with 1 issue.
Test case 'LinkRecoveryTests/resumeReplacesStaleLinkWithoutWaitingForAProbe()' passed on 'iPhone' (0.2 seconds)
** TEST FAILED **
"""

# cargo test --workspace --no-fail-fast, then the release --ignored --nocapture --test-threads=1
# matrix run (the workflow's two commands), where the matrix binary overflows its stack mid-run.
RUST_ABORT_LOG = """\
     Running tests/reliability_matrix.rs (target/debug/deps/reliability_matrix-3f2a1b0c9d8e7f60)

running 3 tests
test cell_host_daemon_restart ... ignored
test cell_network_offline_then_back_with_backlog ... ignored
test cell_scale_session_list ... ignored

test result: ok. 0 passed; 0 failed; 3 ignored; 0 measured; 0 filtered out; finished in 0.00s

     Running tests/wireguard.rs (target/debug/deps/wireguard-0b1c2d3e4f5a6b7c)

running 1 test
test wireguard_resumes_after_airplane_mode ... ok

test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 1.92s

    Finished `release` profile [optimized] target(s) in 1m 02s
     Running tests/reliability_matrix.rs (target/release/deps/reliability_matrix-9a8b7c6d5e4f3a2b)

running 3 tests
test cell_host_daemon_restart ... MATRIX {"cell":"restart","variant":"small-1","reconnect_ms":310.0}
ok
test cell_network_offline_then_back_with_backlog ... MATRIX {"cell":"backlog","variant":"small-10"}

thread 'cell_network_offline_then_back_with_backlog' has overflowed its stack
fatal runtime error: stack overflow
error: test failed, to rerun pass `-p cmux-mobile-host --test reliability_matrix`

Caused by:
  process didn't exit successfully: `/home/runner/work/cmux/cmux/cmux-next-ios/rust/target/release/deps/reliability_matrix-9a8b7c6d5e4f3a2b --ignored --nocapture --test-threads=1` (signal: 6, SIGABRT: process abort signal)
error: 1 target failed:
    `-p cmux-mobile-host --test reliability_matrix`
"""

# --no-fail-fast keeps going after a binary dies: the next binary's `test result: ok` must not
# finish the dead one's started test.
RUST_ABORT_THEN_NEXT_BINARY_LOG = """\
     Running tests/reliability_matrix.rs (target/release/deps/reliability_matrix-9a8b7c6d5e4f3a2b)

running 2 tests
test cell_host_daemon_restart ... MATRIX {"cell":"restart","variant":"small-1"}
ok
test cell_scale_session_list ... MATRIX {"cell":"scale","variant":"1","list_ms":2.5}
error: test failed, to rerun pass `-p cmux-mobile-host --test reliability_matrix`

Caused by:
  process didn't exit successfully: `target/release/deps/reliability_matrix-9a8b7c6d5e4f3a2b --nocapture --test-threads=1` (signal: 11, SIGSEGV: invalid memory reference)
     Running tests/wireguard.rs (target/release/deps/wireguard-0b1c2d3e4f5a6b7c)

running 1 test
test wireguard_resumes_after_airplane_mode ... ok

test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 1.80s

error: 1 target failed:
    `-p cmux-mobile-host --test reliability_matrix`
"""

# xcodebuild test with Swift Testing: the test host dies in the memory-warning cell, xcodebuild
# restarts it, and the cells after it never report.
IOS_CRASH_LOG = """\
Testing started
◇ Test run started.
◇ Suite ConnectivityMatrixTests started.
◇ Test cellNetworkOfflineThenBack() started.
MATRIX {"cell":"offline","reconnect_ms":550.0,"variant":"small-10s"}
✔ Test cellNetworkOfflineThenBack() passed after 0.412 seconds.
Test case 'ConnectivityMatrixTests/cellNetworkOfflineThenBack()' passed on 'iPhone 17 Pro - CmuxMobileKit-Package (4121)' (0.412 seconds)
◇ Test cellAppMemoryWarning() started.
CmuxMobileLive/LiveStore.swift:812: Fatal error: Unexpectedly found nil while unwrapping an Optional value
Restarting after unexpected exit, crash, or test timeout in ConnectivityMatrixTests/cellAppMemoryWarning(); summary will include totals from previous launches.

Test session results, code coverage, and logs:
\t/Users/runner/work/_temp/dd-ios-sim/Logs/Test/Test-CmuxMobileKit-Package-2026.11.10_08-40-12-+0000.xcresult

Failing tests:
\tConnectivityMatrixTests/cellAppMemoryWarning()

** TEST FAILED **
"""

# XCTest's own lines, and a log cut off mid-test (the runner hit its timeout): no summary at all.
IOS_XCTEST_CUT_OFF_LOG = """\
Test Suite 'LinkRecoveryTests' started at 2026-11-10 08:41:02.113.
Test Case '-[CmuxMobileLiveTests.LinkRecoveryTests resumeAfterSleep]' started.
Test Case '-[CmuxMobileLiveTests.LinkRecoveryTests resumeAfterSleep]' passed (0.204 seconds).
Test Case '-[CmuxMobileLiveTests.LinkRecoveryTests staleLinkIsReplaced]' started.
"""

# `swift test`: XCTest's empty summary first, then Swift Testing, cut off mid-test.
SWIFT_TEST_CUT_OFF_LOG = """\
Test Suite 'All tests' started at 2026-11-10 08:41:00.001.
Test Suite 'All tests' passed at 2026-11-10 08:41:00.002.
\t Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.001) seconds
◇ Test run started.
↳ Testing Library Version: 6.2
◇ Suite ConnectivityMatrixTests started.
◇ Test cellNetworkOfflineThenBack() started.
✔ Test cellNetworkOfflineThenBack() passed after 0.412 seconds.
◇ Test cellAppMemoryWarning() started.
"""

# The release matrix binary's header, then nothing: it hung at startup until the job's timeout.
RUST_DIED_AT_STARTUP_LOG = """\
     Running tests/reliability_matrix.rs (target/debug/deps/reliability_matrix-3f2a1b0c9d8e7f60)

running 1 test
test cell_host_daemon_restart ... ignored

test result: ok. 0 passed; 0 failed; 1 ignored; 0 measured; 0 filtered out; finished in 0.00s

    Finished `release` profile [optimized] target(s) in 1m 02s
     Running tests/reliability_matrix.rs (target/release/deps/reliability_matrix-9a8b7c6d5e4f3a2b)
"""


def cell(id_: str, suite: str, test: str, gate: bool) -> dict:
    return {"id": id_, "axis": "a", "case": id_, "suite": suite, "test": test, "asserts": "x", "gate": gate}


CELLS = [
    cell("scale", "rust", "cell_scale_session_list", False),
    cell("restart", "rust", "cell_host_daemon_restart", True),
    cell("wake", "rust", "host_recovery_tests::wake_recovers_signaling_and_phone_dial", True),
    cell("airplane", "rust", "wireguard_resumes_after_airplane_mode", True),
    cell("offline", "ios", "cellNetworkOfflineThenBack", True),
    cell("revoked", "ios", "cellPairingRevokedToken", False),
    cell("resume", "ios", "resumeReplacesStaleLinkWithoutWaitingForAProbe", True),
    cell("cloud", "cloud", "cloud-journey", False),
]


class MatrixReportTest(unittest.TestCase):
    def run_main(self, rust: str | None, ios: str | None, cells: list[dict] = CELLS) -> tuple[int, list[dict]]:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "cells.json").write_text(json.dumps({"cells": cells}))
            argv = ["--cells", str(root / "cells.json"), "--json", str(root / "out.json")]
            if rust is not None:
                (root / "rust.log").write_text(rust)
                argv += ["--rust", str(root / "rust.log")]
            if ios is not None:
                (root / "ios.log").write_text(ios)
                argv += ["--ios", str(root / "ios.log")]
            code = matrix.main(argv)
            return code, json.loads((root / "out.json").read_text())

    def test_each_cell_gets_its_result_and_numbers(self) -> None:
        code, rows = self.run_main(RUST_LOG, IOS_LOG)
        status = {row["id"]: row["status"] for row in rows}
        self.assertEqual(status, {"scale": "fail", "restart": "pass", "wake": "pass", "airplane": "pass", "offline": "pass",
                                  "revoked": "fail", "resume": "pass", "cloud": "not run"})
        numbers = {row["id"]: row["numbers"] for row in rows}
        self.assertIn("god-5000: list_ms=40.0", numbers["scale"])
        self.assertIn("reconnect_ms=550.0", numbers["offline"])
        # Only non-gating cells failed.
        self.assertEqual(code, 0)

    def test_a_gating_cell_that_fails_fails_the_run(self) -> None:
        code, _ = self.run_main(RUST_LOG.replace("airplane_mode ... ok", "airplane_mode ... FAILED"), IOS_LOG)
        self.assertEqual(code, 1)

    def test_a_gating_cell_missing_from_its_log_fails_the_run(self) -> None:
        code, rows = self.run_main(RUST_LOG, "")
        self.assertEqual({row["id"]: row["status"] for row in rows}["offline"], "not run")
        self.assertEqual(code, 1)

    def test_a_binary_that_never_finished_crashes_its_started_tests(self) -> None:
        code, rows = self.run_main("test wireguard_resumes_after_airplane_mode ... \n", IOS_LOG)
        self.assertEqual({row["id"]: row["status"] for row in rows}["airplane"], "crashed")
        self.assertEqual(code, 1)

    def test_a_suite_without_a_log_does_not_gate(self) -> None:
        code, rows = self.run_main(RUST_LOG, None)
        self.assertEqual({row["id"]: row["status"] for row in rows}["offline"], "not run")
        self.assertEqual(code, 0)

    def test_a_rust_binary_that_aborts_mid_run_passes_only_what_it_printed_ok(self) -> None:
        cells = [
            cell("restart", "rust", "cell_host_daemon_restart", True),
            cell("backlog", "rust", "cell_network_offline_then_back_with_backlog", True),
            cell("scale", "rust", "cell_scale_session_list", False),
            cell("airplane", "rust", "wireguard_resumes_after_airplane_mode", True),
        ]
        code, rows = self.run_main(RUST_ABORT_LOG, None, cells)
        # The cell it died in, and the one it never reached (ignored in the debug run), crashed.
        self.assertEqual({row["id"]: row["status"] for row in rows},
                         {"restart": "pass", "backlog": "crashed", "scale": "crashed", "airplane": "pass"})
        self.assertEqual(code, 1)

    def test_a_dead_rust_binary_is_not_finished_by_the_next_binarys_result(self) -> None:
        cells = [
            cell("restart", "rust", "cell_host_daemon_restart", True),
            cell("scale", "rust", "cell_scale_session_list", False),
            cell("airplane", "rust", "wireguard_resumes_after_airplane_mode", True),
        ]
        code, rows = self.run_main(RUST_ABORT_THEN_NEXT_BINARY_LOG, None, cells)
        self.assertEqual({row["id"]: row["status"] for row in rows},
                         {"restart": "pass", "scale": "crashed", "airplane": "pass"})
        self.assertEqual(code, 0)  # the crashed cell does not gate; the gating ones passed explicitly

    def test_an_xctest_run_that_crashes_passes_no_unreported_cell(self) -> None:
        cells = [
            cell("offline", "ios", "cellNetworkOfflineThenBack", True),
            cell("memory", "ios", "cellAppMemoryWarning", True),
            cell("asleep", "ios", "cellHostMacAsleepThenWakes", True),
        ]
        code, rows = self.run_main(None, IOS_CRASH_LOG, cells)
        self.assertEqual({row["id"]: row["status"] for row in rows},
                         {"offline": "pass", "memory": "crashed", "asleep": "crashed"})
        self.assertEqual(code, 1)

    def test_an_ios_log_with_no_summary_reads_crashed(self) -> None:
        cells = [
            cell("sleep", "ios", "resumeAfterSleep", True),
            cell("stale", "ios", "staleLinkIsReplaced", True),
            cell("cached", "ios", "cachedLaunchShowsItsRowsAtOnce", True),
        ]
        code, rows = self.run_main(None, IOS_XCTEST_CUT_OFF_LOG, cells)
        self.assertEqual({row["id"]: row["status"] for row in rows},
                         {"sleep": "pass", "stale": "crashed", "cached": "crashed"})
        self.assertEqual(code, 1)

    def test_an_xctest_summary_before_a_cut_off_swift_testing_run_does_not_finish_it(self) -> None:
        cells = [
            cell("offline", "ios", "cellNetworkOfflineThenBack", True),
            cell("memory", "ios", "cellAppMemoryWarning", True),
            cell("asleep", "ios", "cellHostMacAsleepThenWakes", True),
        ]
        code, rows = self.run_main(None, SWIFT_TEST_CUT_OFF_LOG, cells)
        self.assertEqual({row["id"]: row["status"] for row in rows},
                         {"offline": "pass", "memory": "crashed", "asleep": "crashed"})
        self.assertEqual(code, 1)

    def test_a_rust_binary_that_dies_before_its_first_line_crashes_its_known_tests(self) -> None:
        code, rows = self.run_main(RUST_DIED_AT_STARTUP_LOG, None, [cell("restart", "rust", "cell_host_daemon_restart", True)])
        self.assertEqual(rows[0]["status"], "crashed")
        self.assertEqual(code, 1)

    def test_a_crashed_cell_reads_crashed_in_the_table(self) -> None:
        rows = matrix.build([cell("memory", "ios", "cellAppMemoryWarning", False)], {"ios": IOS_CRASH_LOG})
        self.assertIn("| **crashed** |", matrix.table(rows))

    def test_the_real_catalog_parses_and_names_known_suites(self) -> None:
        cells = json.loads(matrix.CELLS.read_text())["cells"]
        self.assertTrue(cells)
        ids = [c["id"] for c in cells]
        self.assertEqual(len(ids), len(set(ids)), "cell ids are unique")
        for c in cells:
            self.assertIn(c["suite"], {"rust", "ios", "cloud"}, c["id"])
            for key in ("axis", "case", "test", "asserts", "gate"):
                self.assertIn(key, c, c["id"])


if __name__ == "__main__":
    unittest.main()
