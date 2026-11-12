#!/usr/bin/env python3
"""CMUX_NOW_EPOCH (scripts/ci/cmux_now_epoch.py): a malformed clock override stops with one line.

cmux#41805 gave asc_developer_id_app.py and lint-feature-flags.py a CMUX_NOW_EPOCH clock, but
each parsed it with int() and datetime.fromtimestamp(): a non-number or an out-of-range value
died with a ValueError or OverflowError traceback, and an empty value quietly meant the real
clock. continue-nightly-next.sh, which read the variable first, took an empty value as unset and
let any other text reach its inline Python. Now one rule holds for all three: digits only,
0..253402300799, unset means the real clock, anything else exits 2 with
"CMUX_NOW_EPOCH='<v>' is not an epoch".

    python3 -I tests/test_cmux_now_epoch.py
"""
from __future__ import annotations

import datetime as dt
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
MODULE = ROOT / "scripts/ci/cmux_now_epoch.py"
ASC = ROOT / "scripts/ci/asc_developer_id_app.py"
LINT = ROOT / "scripts/lint-feature-flags.py"
CONTINUE = ROOT / "scripts/cmux-next/continue-nightly-next.sh"

# The rows named in the review (cmux#41805 F1): a non-number, an empty string, out of range.
REFUSED_ROWS = ("abc", "", "99999999999999999999")
REFUSED = REFUSED_ROWS + ("1e9", "-1", " 4133980800", "4133980800 ", "4133980800.5", "+5", "0x10",
                          "253402300800", "١٢٣")
ACCEPTED = ("0", "4133980800", "253402300799", "000000000042")


def load_module():
    spec = importlib.util.spec_from_file_location("cmux_now_epoch", MODULE)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def environment(value: str) -> dict[str, str]:
    env = {k: v for k, v in os.environ.items() if not k.startswith("ASC_API_")}
    env["CMUX_NOW_EPOCH"] = value
    return env


def message(value: str) -> str:
    return f"CMUX_NOW_EPOCH={value!r} is not an epoch"


class ScriptsRefuseAMalformedClock(unittest.TestCase):
    """Each caller, run as CI runs it, exits 2 with the one line and no traceback."""

    def assert_refused(self, run: subprocess.CompletedProcess, value: str, where: str) -> None:
        said = run.stdout + run.stderr
        self.assertNotIn("Traceback", said, f"{where} with CMUX_NOW_EPOCH={value!r}: {said}")
        self.assertEqual(run.returncode, 2, f"{where} with CMUX_NOW_EPOCH={value!r}: {said}")
        self.assertIn(message(value), run.stderr, f"{where} with CMUX_NOW_EPOCH={value!r}: {said}")

    def test_asc_developer_id_app(self):
        for value in REFUSED_ROWS:
            with self.subTest(value=value):
                run = subprocess.run(
                    [sys.executable, "-I", str(ASC), "check", "--bundle-id", "com.example.app",
                     "--name", "Example", "--profile-name", "Example Developer ID"],
                    env=environment(value), capture_output=True, text=True, timeout=60)
                self.assert_refused(run, value, "asc_developer_id_app.py check")

    def test_lint_feature_flags(self):
        for value in REFUSED_ROWS:
            with self.subTest(value=value):
                run = subprocess.run([sys.executable, "-I", str(LINT)], cwd=ROOT,
                                     env=environment(value), capture_output=True, text=True, timeout=300)
                self.assert_refused(run, value, "lint-feature-flags.py")

    def test_continue_nightly_next(self):
        for value in REFUSED_ROWS:
            with self.subTest(value=value):
                run, calls = run_continue(value)
                self.assert_refused(run, value, "continue-nightly-next.sh")
                self.assertEqual(calls, "", "a refused clock must stop before any GitHub call")


def run_continue(value: str) -> tuple[subprocess.CompletedProcess, str]:
    """continue-nightly-next.sh with a gh that records its calls and fails, so an accepted clock
    ends at "could not list nightly-next runs" (exit 0) and never reaches GitHub."""
    with tempfile.TemporaryDirectory() as temp:
        stub = Path(temp) / "gh"
        log = Path(temp) / "gh.log"
        stub.write_text(f'#!/usr/bin/env bash\nprintf "%s\\n" "$*" >> "{log}"\nexit 1\n')
        stub.chmod(0o755)
        env = environment(value)
        env["PATH"] = f"{temp}{os.pathsep}{env.get('PATH', '')}"
        run = subprocess.run(["bash", str(CONTINUE), "--repo", "example/repo"], env=env,
                             capture_output=True, text=True, timeout=60)
        return run, log.read_text() if log.exists() else ""


class OneRule(unittest.TestCase):
    def setUp(self):
        self.clock = load_module()

    def test_accepted_values_name_their_second(self):
        for value in ACCEPTED:
            with self.subTest(value=value):
                self.assertEqual(int(self.clock.parse(value).timestamp()), int(value))
        self.assertEqual(self.clock.parse("4133980800"), dt.datetime(2101, 1, 1, tzinfo=dt.timezone.utc))

    def test_refused_values_raise_the_one_line(self):
        for value in REFUSED:
            with self.subTest(value=value), self.assertRaises(self.clock.NotAnEpoch) as caught:
                self.clock.parse(value)
            self.assertIn(message(value), str(caught.exception))

    def test_unset_is_the_real_clock(self):
        before = dt.datetime.now(dt.timezone.utc)
        now = self.clock.utc_now({})
        self.assertLessEqual(before, now)
        self.assertLess(now - before, dt.timedelta(seconds=60))

    def test_utc_now_exits_2_on_a_refused_value(self):
        with self.assertRaises(SystemExit) as caught:
            self.clock.utc_now({"CMUX_NOW_EPOCH": "abc"})
        self.assertEqual(caught.exception.code, 2)

    def test_continue_nightly_next_keeps_the_same_rule(self):
        """The bash copy accepts and refuses exactly what the Python parser does."""
        for value in ACCEPTED + REFUSED:
            with self.subTest(value=value):
                try:
                    self.clock.parse(value)
                    python_accepts = True
                except self.clock.NotAnEpoch:
                    python_accepts = False
                run, _ = run_continue(value)
                self.assertNotIn("Traceback", run.stderr)
                self.assertEqual(run.returncode, 0 if python_accepts else 2, run.stdout + run.stderr)
                if not python_accepts:
                    self.assertIn(message(value), run.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
