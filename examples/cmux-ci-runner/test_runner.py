import json
import os
from pathlib import Path
import signal
import select
import subprocess
import sys
import tempfile
import unittest

RUNNER = Path(__file__).with_name("cmux_ci.py")


class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def argv(self, name="receipt", extra=(), command=None):
        return [sys.executable, str(RUNNER), "--label", "checks", "--pool", str(self.root / "pool"),
                "--receipt", str(self.root / f"{name}.json"), *extra, "--",
                *(command or [sys.executable, "-c", "print('checked')"])]

    def ready(self, process):
        readable, _, _ = select.select([process.stdout], [], [], 5)
        self.assertTrue(readable, "command did not become ready")
        self.assertEqual(process.stdout.readline(), "ready\n")

    def stop(self, process):
        if process.poll() is None:
            process.send_signal(signal.SIGTERM)
            process.communicate(timeout=5)

    def receipt(self, name="receipt"):
        return json.loads((self.root / f"{name}.json").read_text())

    def run_job(self, **kwargs):
        return subprocess.run(self.argv(**kwargs), text=True, capture_output=True, timeout=10)

    def test_output_exit_code_and_private_receipt(self):
        result = self.run_job(command=[sys.executable, "-c", "print('checked'); raise SystemExit(7)"])
        self.assertEqual(result.returncode, 7)
        self.assertEqual(result.stdout, "checked\n")
        self.assertEqual(self.receipt()["status"], "failed")
        self.assertEqual((self.root / "receipt.json").stat().st_mode & 0o777, 0o600)

    def test_argv_is_never_evaluated_by_a_shell(self):
        literal = "$(touch should-not-exist); ${SECRET}"
        result = self.run_job(command=[sys.executable, "-c", "import sys; print(sys.argv[1])", literal])
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), literal)
        self.assertNotIn(literal, json.dumps(self.receipt()))

    def test_timeout_releases_capacity(self):
        result = self.run_job(extra=["--timeout", "0.05"],
                              command=[sys.executable, "-c", "import time; time.sleep(20)"])
        self.assertEqual(result.returncode, 124)
        self.assertEqual(self.receipt()["status"], "timed_out")
        self.assertEqual(self.run_job(name="next").returncode, 0)

    def test_capacity_limit_then_release(self):
        first = subprocess.Popen(self.argv(name="first", command=[sys.executable, "-u", "-c",
                                   "import sys; print('ready'); sys.stdin.read()"]),
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(self.stop, first)
        self.ready(first)
        self.assertEqual(self.run_job(name="full").returncode, 75)
        self.assertEqual(self.receipt("full")["status"], "capacity_unavailable")
        first.communicate("", timeout=10)
        self.assertEqual(self.run_job(name="released").returncode, 0)

    def test_two_slots_run_concurrently_and_a_third_is_refused(self):
        workers = []
        for name in ("one", "two"):
            process = subprocess.Popen(self.argv(name=name, extra=["--slots", "2"],
                                       command=[sys.executable, "-u", "-c",
                                                "import sys; print('ready'); sys.stdin.read()"]),
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                       stderr=subprocess.PIPE, text=True)
            self.addCleanup(self.stop, process)
            self.ready(process)
            workers.append(process)
        self.assertEqual(self.run_job(name="full", extra=["--slots", "2"]).returncode, 75)
        for worker in workers:
            worker.communicate("", timeout=10)
        self.assertEqual({self.receipt("one")["slot"], self.receipt("two")["slot"]}, {0, 1})

    def test_slot_count_cannot_change_in_a_live_pool(self):
        self.assertEqual(self.run_job().returncode, 0)
        self.assertEqual(self.run_job(name="mismatch", extra=["--slots", "2"]).returncode, 125)
        self.assertEqual(self.receipt("mismatch")["status"], "error")

    def test_cancellation_stops_command_and_releases_capacity(self):
        process = subprocess.Popen(self.argv(command=[sys.executable, "-u", "-c",
                                     "import sys; print('ready'); sys.stdin.read()"]),
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(self.stop, process)
        self.ready(process)
        process.send_signal(signal.SIGTERM)
        process.communicate(timeout=10)
        self.assertEqual(process.returncode, 143)
        self.assertEqual(self.receipt()["status"], "cancelled")
        self.assertEqual(self.run_job(name="next").returncode, 0)

    def test_timeout_stops_descendants_that_ignore_term(self):
        child = "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(20)"
        parent = "import subprocess,sys,time; subprocess.Popen([sys.executable,'-c',sys.argv[1]]); time.sleep(20)"
        result = self.run_job(extra=["--timeout", "0.1"],
                              command=[sys.executable, "-c", parent, child])
        self.assertEqual(result.returncode, 124)
        self.assertEqual(self.receipt()["status"], "timed_out")

    def test_receipt_contains_meter_estimate_but_no_environment_or_argv(self):
        result = self.run_job(extra=["--rate-usd", "1.25"])
        self.assertEqual(result.returncode, 0)
        receipt = self.receipt()
        self.assertEqual(receipt["status"], "passed")
        self.assertEqual(receipt["estimated_cost_usd"], round(receipt["run_ms"] * 1.25 / 3_600_000, 8))
        self.assertNotIn("command", receipt)
        self.assertNotIn("environment", receipt)

    def test_unavailable_command_still_has_a_receipt(self):
        self.assertEqual(self.run_job(command=["/nonexistent/cmux-ci-test"]).returncode, 125)
        self.assertEqual(self.receipt()["status"], "error")

    def test_rejects_insecure_capacity_directory(self):
        pool = self.root / "pool"
        pool.mkdir(mode=0o777)
        pool.chmod(0o777)
        self.assertEqual(self.run_job().returncode, 125)
        self.assertEqual(self.receipt()["slot"], None)

    def test_rejects_nonfinite_rate(self):
        self.assertEqual(self.run_job(extra=["--rate-usd", "nan"]).returncode, 2)
        self.assertFalse((self.root / "receipt.json").exists())


if __name__ == "__main__":
    unittest.main()
