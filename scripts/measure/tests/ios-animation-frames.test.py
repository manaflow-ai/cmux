#!/usr/bin/env python3
"""Exercise 120 Hz CPU budgets and heavy replay evidence without a simulator."""
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from ios_animation_frames import ANIMATIONS, measure, read_run, simulator_identity


def sample(label="composer-typing", cpu_ms=1.0, drops=0):
    return {"label": label, "frames": 20, "expectedMs": 1000 / 60, "displayMaximumHz": 60,
            "p50Ms": 16.67, "p95Ms": 16.67, "maxMs": 33.34, "droppedFrames": drops,
            "mainThreadCPUPerFrameMs": [cpu_ms] * 20}


def export(evidence, directory, windows):
    folder = evidence / directory
    folder.mkdir(exist_ok=True)
    attachments = []
    for index, (label, stats) in enumerate(windows):
        uuid = f"024544E3-A6E9-47B4-B07A-{index:012x}"
        attachments.append({
            "suggestedHumanReadableName": f"animation-frame-{label}_0_{uuid}.json",
            "exportedFileName": f"{uuid}.json",
        })
        (folder / f"{uuid}.json").write_text(json.dumps(stats))
    (folder / "manifest.json").write_text(json.dumps([{"attachments": attachments}]))


class FrameBudgetTests(unittest.TestCase):
    def test_cpu_and_drops_gate_independently_on_a_60_hz_simulator(self):
        self.assertFalse(measure(sample(cpu_ms=8.33, drops=2))["failures"])
        self.assertTrue(measure(sample(cpu_ms=8.34))["failures"])
        self.assertTrue(measure(sample(drops=3))["failures"])

    def test_heavy_evidence_requires_the_window_that_checks_replay(self):
        with tempfile.TemporaryDirectory() as folder:
            evidence = Path(folder)
            export(evidence, "ui-duress-heavy-attachments", [("composer-typing-heavy", sample())])
            self.assertTrue(read_run(evidence, "heavy")[1])
            export(evidence, "ui-duress-heavy-attachments", [("composer-typing-heavy", sample("composer-typing-heavy"))])
            rows, errors = read_run(evidence, "heavy")
            self.assertEqual(errors, [])
            self.assertEqual((rows[0]["animation"], rows[0]["profile"]), ("composer-typing", "heavy"))

    def test_manifest_enforces_frame_budget_with_both_runs(self):
        with tempfile.TemporaryDirectory() as folder:
            evidence = Path(folder)
            sha = "ab" * 20
            (evidence / "SUMMARY.md").write_text(
                f"- commit: {sha}\n- simulator: iPhone-17-Pro on iOS-26-1\n"
                "- device: iPhone 17 Pro (com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro), the default\n"
            )
            labels = [(name, sample(name)) for name in ANIMATIONS]
            export(evidence, "ui-attachments", labels)
            target = evidence / "report.json"
            reader = Path(__file__).resolve().parents[1] / "ios_animation_frames.py"
            cmd = [sys.executable, "-I", str(reader), "--evidence", str(evidence), "--out", str(target),
                   "--sha", sha, "--run", "off", "--run", "heavy"]
            self.assertEqual(subprocess.run(cmd, capture_output=True).returncode, 1)
            report = json.loads(target.read_text())
            self.assertEqual(len([r for r in report["animations"] if r["gate"] == "pass"]), len(ANIMATIONS))
            self.assertEqual(report["animations"][-1]["gate"], "fail")
            # The profiled export has precedence over the "ui-*" copy of the first run.
            export(evidence, "ui-duress-off-attachments", labels)
            heavy = "composer-typing-heavy"
            export(evidence, "ui-duress-heavy-attachments", [(heavy, sample(heavy))])
            self.assertEqual(subprocess.run(cmd, capture_output=True).returncode, 0)
            report = json.loads(target.read_text())
            self.assertEqual(report["measured_on"], {"simulator_model": "iPhone 17 Pro", "runtime": "iOS-26-1"})
            self.assertEqual(len(report["animations"]), len(ANIMATIONS) + 1)
            export(evidence, "ui-duress-heavy-attachments", [(heavy, sample(heavy, drops=3))])
            self.assertEqual(subprocess.run(cmd, capture_output=True).returncode, 1)
            self.assertIn("3 dropped frames", json.loads(target.read_text())["failures"][0])
            self.assertTrue(simulator_identity(evidence, "cd" * 20, None, None)[1])



if __name__ == "__main__":
    unittest.main()
