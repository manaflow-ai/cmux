from __future__ import annotations

import json
import shlex
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
HARNESS = ROOT / "scripts" / "measure" / "cloud-first-byte.sh"


def py_command(source: str) -> str:
    return shlex.join([sys.executable, "-c", source])


class CloudFirstByteHarnessTest(unittest.TestCase):
    def run_harness(self, chat: str, git: str, *extra: str) -> tuple[int, dict]:
        proc = subprocess.run(
            ["bash", str(HARNESS), "--samples", "3", "--timeout", "2",
             "--chat-command", chat, "--git-command", git, "--completion-marker", "ok", *extra],
            cwd=ROOT, capture_output=True, text=True, check=False,
        )
        line = next(line for line in proc.stdout.splitlines() if line.startswith("CLOUD-FIRST-BYTE "))
        return proc.returncode, json.loads(line.split(" ", 1)[1])

    def test_records_first_byte_and_concurrent_git(self) -> None:
        chat = py_command("import sys,time; time.sleep(.02); sys.stdout.write('ok'); sys.stdout.flush()")
        git = py_command("import time; time.sleep(.3)")
        code, result = self.run_harness(chat, git, "--completion-marker", "ok")
        self.assertEqual(code, 0)
        self.assertEqual(result["samples"], 3)
        self.assertEqual(result["completed"], 3)
        self.assertEqual(result["errors"], 0)
        self.assertEqual(result["timeouts"], 0)
        self.assertTrue(result["flow_completed"])
        self.assertIsInstance(result["median_ms"], (int, float))
        self.assertIsInstance(result["p95_ms"], (int, float))
        self.assertTrue(all(row["git_concurrent"] for row in result["rows"]))

    def test_does_not_fabricate_a_timing_on_timeout(self) -> None:
        chat = py_command("import time; time.sleep(1); print('late')")
        git = py_command("pass")
        code, result = self.run_harness(chat, git, "--timeout", "0.05")
        self.assertNotEqual(code, 0)
        self.assertEqual(result["completed"], 0)
        self.assertEqual(result["median_ms"], None)
        self.assertEqual(result["p95_ms"], None)
        self.assertEqual(result["timeouts"], 3)
        self.assertFalse(result["flow_completed"])

    def test_git_failure_keeps_chat_timing_but_fails_flow(self) -> None:
        chat = py_command("print('ok')")
        git = py_command("import sys; sys.exit(7)")
        code, result = self.run_harness(chat, git, "--completion-marker", "ok")
        self.assertNotEqual(code, 0)
        self.assertEqual(result["completed"], 0)
        self.assertIsNone(result["median_ms"])
        self.assertTrue(all(row["first_byte_ms"] is not None for row in result["rows"]))
        self.assertEqual(result["errors"], 3)
        self.assertFalse(result["flow_completed"])

    def test_git_finished_before_response_is_not_overlap(self) -> None:
        code, result = self.run_harness(py_command("import time; time.sleep(.1); print('ok')"), py_command("pass"))
        self.assertNotEqual(code, 0)
        self.assertFalse(result["flow_completed"])
        self.assertFalse(any(row["git_concurrent"] for row in result["rows"]))
        self.assertIsNone(result["p95_ms"])

    def test_stderr_is_not_a_response_byte(self) -> None:
        code, result = self.run_harness(py_command("import sys; print('ok', file=sys.stderr)"),
                                        py_command("import time; time.sleep(.1)"))
        self.assertNotEqual(code, 0)
        self.assertTrue(all(row["first_byte_ms"] is None for row in result["rows"]))

    def test_launch_failure_still_emits_every_sample(self) -> None:
        code, result = self.run_harness("/nonexistent-cloud-first-byte-command", py_command("pass"))
        self.assertNotEqual(code, 0)
        self.assertEqual(len(result["rows"]), 3)
        self.assertEqual(result["errors"], 3)

    def test_closed_stdout_with_live_process_is_a_timeout_receipt(self) -> None:
        code, result = self.run_harness(py_command("import os,time; os.close(1); time.sleep(5)"),
                                        py_command("pass"), "--timeout", ".2")
        self.assertNotEqual(code, 0)
        self.assertEqual(result["timeouts"], 3)

    def test_timeout_after_first_byte_keeps_diagnostic_but_not_success(self) -> None:
        code, result = self.run_harness(py_command("import time; print('partial', flush=True); time.sleep(5)"),
                                        py_command("import time; time.sleep(5)"), "--timeout", ".2")
        self.assertNotEqual(code, 0)
        self.assertEqual(result["timeouts"], 3)
        self.assertEqual(result["completed"], 0)
        self.assertTrue(all(row["first_byte_ms"] is not None for row in result["rows"]))
        self.assertIsNone(result["median_ms"])

    def test_marker_split_across_reads_is_recognized(self) -> None:
        code, result = self.run_harness(py_command("import time; print('o', end='', flush=True); time.sleep(.02); print('k')"),
                                        py_command("import time; time.sleep(.3)"))
        self.assertEqual(code, 0)
        self.assertEqual(result["completed"], 3)

    def test_offline_duress_streams_under_parallel_git_work(self) -> None:
        code, result = self.run_harness(
            py_command("import sys; sys.stdout.write('x' * 2000000 + 'ok'); sys.stdout.flush()"),
            py_command("import time; time.sleep(.5)"), "--samples", "64", "--parallel", "8", "--timeout", "5")
        self.assertEqual(code, 0)
        self.assertEqual(result["completed"], 64)
        self.assertEqual(result["errors"], 0)
        self.assertTrue(all(row["chat_bytes"] == 2000002 for row in result["rows"]))
        print("OFFLINE-DURESS " + json.dumps({key: result[key] for key in
              ("samples", "parallel", "completed", "errors", "timeouts", "median_ms", "p95_ms")}))


class CloudFirstByteBenchTest(unittest.TestCase):
    def test_timestamped_log_and_failed_rows_do_not_become_valid_metrics(self) -> None:
        sys.path.insert(0, str(ROOT / "scripts" / "bench"))
        from benches.cloud_first_byte import BENCH, report
        from benchlib.bench import BenchError, Context
        result = {"schema": "cloud-first-byte/v2", "measurement": "command_stdout_first_byte",
                  "samples": 2, "completed": 1, "flow_completed": False, "errors": 1, "timeouts": 0,
                  "rows": [{"first_byte_ms": 10, "flow_completed": True},
                           {"first_byte_ms": 9000, "flow_completed": False}]}
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "receipt.log"
            path.write_text("2026-11-27T00:00:00Z CLOUD-FIRST-BYTE " + json.dumps(result))
            self.assertEqual(report(path), result)
            ctx = Context(bench=BENCH, build={"channel": "sha", "sha": "a" * 40}, host_role="fleet")
            with self.assertRaises(BenchError):
                BENCH.ingest(ctx, path)
            self.assertEqual(ctx.rows[0]["value"], 10)

    def test_fleet_requires_ref_instead_of_selecting_base_tip(self) -> None:
        sys.path.insert(0, str(ROOT / "scripts" / "bench"))
        from benches.cloud_first_byte import BENCH
        from benchlib.bench import BenchError
        ctx = mock.Mock()
        ctx.arg.return_value = None
        with self.assertRaisesRegex(BenchError, "ref"):
            BENCH.run(ctx)
        ctx.fleet_step.assert_not_called()


if __name__ == "__main__":
    unittest.main()
