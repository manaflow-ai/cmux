#!/usr/bin/env python3
"""cef-resize-sync-bench.py's host modes (p01-process-052): a bench counts as a host mode run only when the app
reported `debug.cef` host_resize at its end (null: Chromium ran in process), `hostfence` only with a fenced resize,
and a host mode starts with the layer hosting and deadline tunables an in-process mode left removed.

Runs on any host (Linux included): the benches are faked; no app, no fleet.

    python3 -m unittest scripts/cmux-next/tests/test_cef_resize_sync_bench_host.py
"""

from __future__ import annotations

import importlib.util
import io
import json
import os
import shutil
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERE))


def load_bench():
    spec = importlib.util.spec_from_file_location("cef_resize_sync_bench", HERE / "cef-resize-sync-bench.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def run(layout="1x2", action="split", fenced=None):
    return {"layout": layout, "action": action, "round": 0, "commit_p95_ms": 4.0, "commit_max_ms": 6.0, "missed": 0,
            "frames_p95_ms": 8.3, "frames_p99_ms": 9.0, "frames_max_ms": 10.0, "layout_p95_ms": 1.0,
            "refresh_ms": 8.3, "fence_resizes": fenced, "frame_intervals_ms": [8.3, 8.4]}


class HostModes(unittest.TestCase):
    def setUp(self):
        self.bench = load_bench()
        self.out = tempfile.mkdtemp(prefix="cef-resize-host-")
        self.addCleanup(shutil.rmtree, self.out, True)
        self.reports = {}  # mode -> host_resize the faked app reports
        self.commands = []
        self.recorded = []
        bench = self.bench

        def call(command, stdout=None, stderr=None):
            self.commands.append(command)
            out = command[command.index("--out") + 1]
            mode = Path(out).parent.name
            fenced = (self.reports.get(mode) or {}).get("fenced")
            report = {"runs": [run(fenced=fenced)], "summary": [run(fenced=fenced)],
                      "host_resize": self.reports.get(mode)}
            with open(command[command.index("--json") + 1], "w") as f:
                json.dump(report, f)
            return 0

        def record(series):
            self.recorded.extend(series)
            return True

        bench.subprocess.call = call
        bench.record_results = record

    def main(self, modes):
        with redirect_stdout(io.StringIO()):
            code = self.bench.main(["--app", "/x/cmux DEV.app", "--tag", "t", "--out", self.out, "--modes", modes,
                                    "--benches", "light,stress"])
        with open(os.path.join(self.out, "summary.json")) as f:
            return code, json.load(f)

    def failed(self, mode):
        return [list(s.samples) for s in self.recorded if s.metric == f"cef_resize_sync.{mode}.failed"]

    def test_in_process_chromium_is_not_a_host_run(self):
        self.reports = {"host": None, "hostfence": None}
        code, summary = self.main("host,hostfence")
        self.assertEqual(code, 1)
        for mode in ("host", "hostfence"):
            self.assertFalse(summary["validity"][mode]["ok"])
            self.assertIn("in process", summary["validity"][mode]["benches"]["light"]["error"])
            self.assertEqual(self.failed(mode), [[1], [1]])

    def test_hostfence_needs_a_fenced_resize(self):
        counters = {"resizes": 12, "fenced": 0, "joined": 0, "late": 0, "cut": 0}
        self.reports = {"host": dict(counters), "hostfence": dict(counters)}
        code, summary = self.main("host,hostfence")
        self.assertEqual(code, 1)
        self.assertTrue(summary["validity"]["host"]["ok"])
        self.assertEqual(self.failed("host"), [[0], [0]])
        self.assertFalse(summary["validity"]["hostfence"]["ok"])
        self.assertIn("no fenced resize", summary["validity"]["hostfence"]["benches"]["stress"]["error"])

    def test_a_fenced_host_run_is_valid_and_its_rows_carry_fenced_resizes(self):
        self.reports = {"hostfence": {"resizes": 12, "fenced": 9, "joined": 9, "late": 0, "cut": 1}}
        code, summary = self.main("hostfence")
        self.assertEqual(code, 0)
        self.assertTrue(summary["validity"]["hostfence"]["ok"])
        self.assertEqual(summary["modes"]["hostfence"]["light"]["rows"][0]["fence_resizes"], 9)
        self.assertEqual(self.failed("hostfence"), [[0], [0]])
        # chromiumHostTabs: the bench's Chromium tabs run in the host.
        self.assertTrue(all("cefHelperHost,chromiumHostResizeFence,chromiumHostTabs" in c for c in self.commands))

    def test_a_host_mode_starts_without_the_tunables_an_in_process_mode_left(self):
        tunables = os.path.join(self.out, "debug-tunables.json")
        with open(tunables, "w") as f:
            json.dump({"version": 1, "values": {"other": 1}}, f)
        seen = {}

        def check_mode(mode, hosting):
            return True, {"tunables_file": tunables}

        original = self.bench.subprocess.call

        def call(command, stdout=None, stderr=None):
            mode = Path(command[command.index("--out") + 1]).parent.name
            with open(tunables) as f:
                seen.setdefault(mode, json.load(f)["values"])
            return original(command, stdout, stderr)

        self.bench.check_mode = check_mode
        self.bench.subprocess.call = call
        self.reports = {"host": {"resizes": 3, "fenced": 0}}
        code, summary = self.main("on0,host")
        self.assertEqual(code, 0)
        self.assertEqual(seen["on0"], {"other": 1, "browserResize.syncDeadline": 0.0})
        self.assertEqual(seen["host"], {"other": 1})
        self.assertEqual(summary["validity"]["host"]["tunables_reset"], tunables)


if __name__ == "__main__":
    unittest.main()
