#!/usr/bin/env python3
"""scripts/measure/live-code-cost.py: the report from two fake builds and fake instant-create runs."""
import json
import os
import random
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.realpath(os.path.join(os.path.dirname(__file__), ".."))
SCRIPT = os.path.join(ROOT, "scripts", "measure", "live-code-cost.py")
SHA = "0123456789abcdef0123456789abcdef01234567"


def read(path):
    with open(path) as f:
        return f.read()


def fake_app(root, name, binary_bytes):
    macos = os.path.join(root, name, "Contents", "MacOS")
    os.makedirs(macos)
    with open(os.path.join(macos, "cmux"), "wb") as f:
        f.write(b"\0" * binary_bytes)
    with open(os.path.join(macos, "libextra.dylib"), "wb") as f:
        f.write(b"\0" * 10)
    return os.path.join(root, name)


def fake_run(out, rnd, arm, visible, rng):
    runs = [{"command": "split_right", "phase": "idle", "visible_ms": visible + rng.random(), "key_ms": 1.0}
            for _ in range(40)]
    with open(os.path.join(out, f"bench-instant-r{rnd}-{arm}-{SHA[:8]}.json"), "w") as f:
        json.dump({"runs": runs}, f)


class LiveCodeCostReport(unittest.TestCase):
    def test_builds_sizes_and_a_slower_live_build(self):
        rng = random.Random(1)
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "out")
            os.makedirs(out)
            regular = fake_app(tmp, "regular.app", 1000)
            live = fake_app(tmp, "live.app", 3000)
            for rnd in range(1, 5):
                fake_run(out, rnd, "before", 10.0, rng)
                fake_run(out, rnd, "after", 20.0, rng)
            # An earlier commit's file in the folder never joins an arm.
            with open(os.path.join(out, "bench-instant-r9-after-ffffffff.json"), "w") as f:
                json.dump({"runs": [{"command": "split_right", "phase": "idle", "visible_ms": 1.0}]}, f)
            p = subprocess.run([sys.executable, SCRIPT, "--out", out, "--sha", SHA, "--regular-app", regular,
                                "--regular-build-s", "100", "--live-app", live, "--live-build-s", "250"],
                               capture_output=True, text=True)
            self.assertEqual(p.returncode, 0, p.stderr)
            result = json.loads(read(os.path.join(out, "result.json")))
            self.assertEqual(result["builds"]["regular"]["binary_bytes"], 1000)
            self.assertEqual(result["builds"]["live"]["binary_bytes"], 3000)
            self.assertEqual(result["builds"]["live"]["app_bytes"], 3010)
            self.assertEqual((result["bench"]["jobs_a"], result["bench"]["jobs_b"]), (4, 4))
            report = read(os.path.join(out, "REPORT.md"))
            self.assertIn("| build, s | 100 | 250 | 2.5 |", report)
            row = next(r for r in result["bench"]["rows"] if r["metric"] == "visible_ms")
            self.assertEqual(row["verdict"]["p50"], "REGRESSION")
            self.assertIn("| split_right/idle | visible_ms | p50 |", report)
            self.assertIn("LIVE-CODE-COST", p.stdout)

    def test_no_runs_still_reports_the_builds(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "out")
            os.makedirs(out)
            app = fake_app(tmp, "a.app", 5)
            p = subprocess.run([sys.executable, SCRIPT, "--out", out, "--sha", SHA, "--regular-app", app,
                                "--regular-build-s", "1", "--live-app", app, "--live-build-s", "2"],
                               capture_output=True, text=True)
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertIn("Verdicts: none", read(os.path.join(out, "REPORT.md")))


if __name__ == "__main__":
    unittest.main()
