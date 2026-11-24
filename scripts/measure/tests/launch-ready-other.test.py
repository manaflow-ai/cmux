#!/usr/bin/env python3
"""launch-ready.sh other=: launch-ready-applog.py reads an app's own `NAME=N ms` launch lines from its log stream, the
summary gives a plain side its medians (log.* and log_at.*) without judging a restore it cannot read, and
other_args_ok accepts a DMG or zip URL or an .app path and refuses the arguments that drive cmux's socket.

    python3 scripts/measure/tests/launch-ready-other.test.py
"""

import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, HERE.parent / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


applog = load("launch_ready_applog", "launch-ready-applog.py")
summary = load("launch_ready_summary", "launch-ready-summary.py")

START = applog.epoch_ms("2026-11-21 08:00:00.000000+0000")
STREAM = [
    "Filtering the log data using \"process == \\\"App\\\"\"",
    json.dumps({"timestamp": "2026-11-21 08:00:00.300000+0000",
                "eventMessage": "First workspace window frame appeared count=1 launch_to_first_frame=280 ms"}),
    json.dumps({"timestamp": "2026-11-21 08:00:00.450000+0000",
                "eventMessage": "First terminal surface appeared count=1 duration=12 ms launch_to_surface=431 ms"}),
    json.dumps({"timestamp": "2026-11-21 08:00:00.900000+0000",
                "eventMessage": "First workspace window frame appeared count=2 launch_to_first_frame=870 ms"}),
    json.dumps({"timestamp": "2026-11-21 08:00:00.950000+0000", "eventMessage": "no durations here, size=12 MB"}),
]


class AppLogTests(unittest.TestCase):
    def test_pairs_first_of_each_name_and_when(self):
        values, at = applog.read(STREAM, START)
        self.assertEqual(values, {"launch_to_first_frame": 280, "duration": 12, "launch_to_surface": 431})
        self.assertEqual(at, {"launch_to_first_frame": 300.0, "duration": 450.0, "launch_to_surface": 450.0})

    def test_cli_adds_fields_and_reports_unreadable_stream(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "s.ndjson")
            Path(path).write_text("\n".join(STREAM) + "\n")
            row = {"label": "run1", "start_epoch_ms": START, "plain": True}
            out = subprocess.run(["python3", "-I", str(HERE.parent / "launch-ready-applog.py"), path, json.dumps(row)],
                                 check=True, capture_output=True, text=True).stdout
            self.assertEqual(json.loads(out)["app_log"]["launch_to_surface"], 431)
            missing = subprocess.run(["python3", "-I", str(HERE.parent / "launch-ready-applog.py"),
                                      os.path.join(tmp, "none"), json.dumps(row)],
                                     check=True, capture_output=True, text=True).stdout
            self.assertIn("app_log_error", json.loads(missing))


def row(side, label, **extra):
    r = {"side": side, "label": label, "window_on_screen": 100.0, "finished_launching": 90.0, "marks": {},
         "first_reveal": None}
    r.update(extra)
    return r


class PlainSummaryTests(unittest.TestCase):
    def test_plain_side_medians_and_no_restore_judgment(self):
        home = {"workspace": "wk-1", "tab": "tab_h", "page": "home-dock", "home": True, "windows": 1}
        rows = [row("head", "prime", front=home), row("head", "run1", front=home), row("head", "run2", front=home)]
        for i, (frame, at) in enumerate([(200, 210.0), (300, 320.0), (400, 410.0)]):
            rows.append(row("other", "prime" if i == 0 else f"run{i}", plain=True,
                            app_log={"launch_to_first_frame": frame}, app_log_at={"launch_to_first_frame": at}))
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            result = summary.summarize(rows, "kept", "", False)
        lines = out.getvalue().splitlines()
        other = json.loads(next(l for l in lines if l.startswith("LR-MEDIAN other ")).split(" ", 2)[2])
        self.assertEqual(other["log.launch_to_first_frame"], 350.0)
        self.assertEqual(other["log_at.launch_to_first_frame"], 365.0)
        self.assertEqual(other["reopened"], "n/a (plain app)")
        self.assertEqual(result["other"]["failed"], [])
        self.assertFalse(any(l.startswith("LR-FAIL other") for l in lines))
        self.assertFalse(any(l.startswith("LR-SURFACE-DIFF") for l in lines))
        self.assertTrue(any(l.startswith("LR-SAME-FRONT ok") for l in lines))


class OtherArgsTests(unittest.TestCase):
    def ok(self, other, dmg="nightly", session="small", engines="", late="0", front="", keys="0"):
        script = HERE.parent / "launch-ready.sh"
        code = (f'source "{script}"; LR_FRONT="{front}" LR_CASE="" LR_SNAPSHOT=own LR_KEYS={keys} '
                f'other_args_ok "$1" "{dmg}" "{session}" "{engines}" "{late}"')
        return subprocess.run(["bash", "-c", code, "bash", other], capture_output=True).returncode == 0

    def test_forms(self):
        self.assertTrue(self.ok(""))
        self.assertTrue(self.ok("https://example.com/App-1.0.dmg"))
        self.assertTrue(self.ok("https://example.com/App-1.0.zip"))
        with tempfile.TemporaryDirectory() as tmp:
            app = os.path.join(tmp, "Some App.app")
            os.mkdir(app)
            self.assertTrue(self.ok(app))
            self.assertFalse(self.ok(os.path.join(tmp, "Missing.app")))
        self.assertFalse(self.ok("http://example.com/App.dmg"))
        self.assertFalse(self.ok("https://example.com/App.pkg"))

    def test_refuses_cmux_only_arguments(self):
        url = "https://example.com/App.dmg"
        self.assertFalse(self.ok(url, dmg="build"))
        self.assertFalse(self.ok(url, session="stress3"))
        self.assertFalse(self.ok(url, engines="webkit"))
        self.assertFalse(self.ok(url, late="500"))
        self.assertFalse(self.ok(url, front="tab"))
        self.assertFalse(self.ok(url, keys="1"))


if __name__ == "__main__":
    unittest.main()
