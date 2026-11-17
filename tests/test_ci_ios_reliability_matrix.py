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

    def test_a_binary_that_never_finished_fails_its_started_tests(self) -> None:
        code, rows = self.run_main("test wireguard_resumes_after_airplane_mode ... \n", IOS_LOG)
        self.assertEqual({row["id"]: row["status"] for row in rows}["airplane"], "fail")
        self.assertEqual(code, 1)

    def test_a_suite_without_a_log_does_not_gate(self) -> None:
        code, rows = self.run_main(RUST_LOG, None)
        self.assertEqual({row["id"]: row["status"] for row in rows}["offline"], "not run")
        self.assertEqual(code, 0)

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
