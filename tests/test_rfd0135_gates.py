#!/usr/bin/env python3
"""scripts/cmux-next/rfd0135_gates.py: the kill matrix table is counted cell by cell, p95 is the
nearest-rank 95th percentile, and the phone gate is NO (not NOT-RUN) when its check fails."""

from __future__ import annotations

import argparse
import importlib.util
import os
import tempfile
import sys
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("rfd0135_gates", ROOT / "scripts/cmux-next/rfd0135_gates.py")
gates = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gates)

LOG = """| local->cloud | before-begin | kill-src | 1 | nothing lost | - | - | mac | moved |
noise
| direction | step | kill | seed | lost | frozen past the settle | wrong answer to the person | where the work is | what the person sees |
|---|---|---|---|---|---|---|---|---|
| local->cloud | before-begin | kill-src | 1 | nothing lost | - | - | mac | moved |
| local->cloud | after-begin | off-dst | 2 | queued prompt run twice | - | - | vm | moved |
| local->cloud | mid-copy | cut | 3 | nothing lost | frozen 300 s, then recovered | said moved, did not | mac | moved |
"""


class Rfd0135GatesTest(unittest.TestCase):
    def test_move_times_runs_the_move_times_test_and_reads_its_file(self) -> None:
        def fake_run(cmd, **kw):
            Path(kw["env"]["MOVE_TIMES_OUT"]).write_text('{"to_cloud_ms":[900,1200],"back_ms":[800,700]}')
            self.assertEqual((cmd[-1], kw["env"]["MOVE_TIMES_RUNS"]), ("move_times::", "3"))
            return mock.Mock(returncode=0, stdout="", stderr="")
        with mock.patch.dict(os.environ, {"MOVE_TIMES": ""}), mock.patch.object(gates.subprocess, "run", side_effect=fake_run):
            got = gates.move_times(argparse.Namespace(matrix_log=None, move_runs=3))
        self.assertEqual((gates.p95(got["to_cloud_ms"]), gates.p95(got["back_ms"])), (1200, 800))

    def test_gates_run_tests_in_the_one_it_binary(self) -> None:
        # cmux-tui's tests are modules of `--test it` (cmux#56677); a `--test lid_close_gate` target is gone.
        with mock.patch.object(gates.subprocess, "run", return_value=mock.Mock(returncode=0, stdout="", stderr="")) as run:
            gates.cargo_test("lid_close_gate::", {})
        cmd = run.call_args.args[0]
        self.assertEqual(cmd[cmd.index("--test") + 1], "it")
        self.assertEqual(cmd[-1], "lid_close_gate::")
        tests = ROOT / "cmux-tui/crates/cmux-tui/tests"
        if tests.is_dir():  # the unit job's sparse checkout has no cmux-tui
            for name in ("lid_close_gate", "move_kill_drill"):
                self.assertTrue((tests / f"{name}.rs").is_file(), name)

    def test_matrix_cells_reads_only_the_summary_table(self) -> None:
        cells = gates.matrix_cells(LOG)
        self.assertEqual([c["step"] for c in cells], ["before-begin", "after-begin", "mid-copy"])
        self.assertEqual([c["clean"] for c in cells], [True, False, False])

    def test_matrix_count_line_wins_over_the_table(self) -> None:
        log = Path(tempfile.mkdtemp(), "m.log")
        log.write_text('| direction | step | kill | seed |\nMOVE_KILL_MATRIX {"cells":56,"clean":56,"known":0,"new":0}\n')
        with mock.patch.object(gates.subprocess, "run", return_value=mock.Mock(returncode=1, stdout="")):
            got = gates.gate_move(argparse.Namespace(matrix_log=str(log)))
        self.assertEqual((got["cells"], got["clean"], got["ok"]), (56, 56, False))

    def test_gate_line_found_after_the_harness_prefix(self) -> None:
        out = 'running 1 test\ntest lid_close_gate ... GATE lid-close {"runs": 2, "passed": 2}\nok\n'
        self.assertEqual(gates.gate_line(out, "lid-close"), {"runs": 2, "passed": 2})
        self.assertIsNone(gates.gate_line("nothing", "lid-close"))

    def test_p95(self) -> None:
        self.assertIsNone(gates.p95([]))
        self.assertEqual(gates.p95(list(range(1, 21))), 19)
        self.assertEqual(gates.p95([5.0]), 5.0)

    def test_move_code_landed_reads_the_tree_not_a_pr(self) -> None:
        # cmux#51824 closed unmerged (its commits landed via cmux#52230); the gate must see the code.
        # (The unit job's sparse checkout has no Packages/, so the tree here is made up.)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.assertFalse(gates.move_code_landed(root))
            for path in gates.MOVE_CODE:
                (root / path).parent.mkdir(parents=True, exist_ok=True)
                (root / path).write_text("")
            self.assertTrue(gates.move_code_landed(root))
            (root / gates.MOVE_CODE[0]).unlink()
            self.assertFalse(gates.move_code_landed(root))

    def test_phone_is_no_when_its_check_fails(self) -> None:
        os.environ["PHONE_GATE_CMD"] = "false"
        try:
            result = gates.gate_phone(None)
            self.assertTrue(result["ran"])
            self.assertFalse(result["ok"])
            os.environ["PHONE_GATE_CMD"] = 'echo \'GATE phone {"ok":true,"first_reply_ms":12}\''
            result = gates.gate_phone(None)
            self.assertTrue(result["ok"])
            self.assertEqual(result["measured"]["first_reply_ms"], 12)
        finally:
            os.environ.pop("PHONE_GATE_CMD")

    def test_every_gate_calls_cargo_test_with_its_signature(self) -> None:
        # A base merge once left gate_phone calling an older cargo_test(binary, name, env); nothing
        # else runs that branch in unit tests, so call each gate's cargo path through the real signature.
        def fake(name: str, env: dict[str, str]):
            return mock.Mock(returncode=1, stdout="", stderr="")
        os.environ.pop("PHONE_GATE_CMD", None)
        with mock.patch.object(gates, "cargo_test", side_effect=fake) as run:
            self.assertFalse(gates.gate_phone(None)["ok"])
            gates.gate_lid_close(argparse.Namespace(runs=1, secs=1))
        self.assertEqual(run.call_args_list[0].args[0], "phone_direct_gate::")

    def test_summary_adds_parallel_lid_close_jobs(self) -> None:
        one = {"gate": "lid-close", "ran": True, "runs": 1, "passed": 1, "lid_s": 1800, "each": [{"pass": True}]}
        bad = {**one, "passed": 0, "each": [{"pass": False}]}
        phone = {"gate": "phone", "ran": True, "ok": False}
        merged = gates.merge([one] * 10 + [phone])
        self.assertEqual([r["gate"] for r in merged], ["lid-close", "phone"])
        self.assertTrue(merged[0]["ok"])
        self.assertEqual(merged[0]["number"], "10/10 at 1800 s")
        self.assertFalse(gates.merge([one] * 9 + [bad])[0]["ok"])
        self.assertFalse(gates.merge([one] * 9)[0]["ok"], "9 runs are not the gate's 10")


if __name__ == "__main__":
    sys.exit(unittest.main())
