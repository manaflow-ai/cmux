#!/usr/bin/env python3
"""The nightly-next canary's advisory felt-latency sampling (scripts/ci/nightly_next_canary_latency.py,
ported from feat-cmux-next's cmux#53287): the judge, and that the workflow steps can never fail or
hold the canary verdict."""
from __future__ import annotations

import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/ci"))
import nightly_next_canary_latency as latency  # noqa: E402

WORKFLOW = ROOT / ".github/workflows/nightly-next-canary.yml"
ADVISORY = ("Check out the latency harness", "Sample five warm terminal relaunches of the verified DMG",
            "Record the felt-latency reading", "Keep the measurements with this canary run")


class FeltLatencyTests(unittest.TestCase):
    def setUp(self):
        frames = [412.5, 398.0, 405.25, 420.0, 401.75]  # five warm first-frame marks, ms
        self.rounds = [{"kind": "warm", "front": "terminal", "input": "in_app", "failures": [], "first_frame_ms": frame,
                        "marks": {"terminal.probe_key_typed": frame + 2, "terminal_input_accepted": frame + 6,
                                  "terminal_echo": frame + 2 + echo}} for frame, echo in zip(frames, (18, 20, 21, 19, 22))]
        self.run_url = "https://github.com/manaflow-ai/cmux/actions/runs/555"
        self.previous = {"build": "100", "commit": "a" * 40, "canaryRun": self.run_url, "canaryAttempt": 1,
                         "latency": self.receipt(self.rounds, "100")}

    def receipt(self, rounds, build="101", outcome="success", verdict="pass", workspaces=3, smoke_failures=()):
        data = {"rounds": rounds, "verdict": verdict, "seed": {"workspaces": workspaces, "chats": 1}}
        readings, error = latency.samples(data, outcome, smoke_failures)
        return {"profile": latency.PROFILE, "build": build, "source_commit": "b" * 40, "machine": "fixture",
                "canaryRun": self.run_url, "canaryAttempt": 1, "samples": readings, "measurement_error": error}

    def test_same_build_and_independent_positive_controls(self):
        self.assertEqual(latency.judge(self.receipt(self.rounds), self.previous)["verdict"], "pass")
        for metric in latency.FLOORS_MS:
            with self.subTest(metric=metric):
                rounds = json.loads(json.dumps(self.rounds))
                for row in rounds:
                    if metric == "first_frame_ms":
                        row["first_frame_ms"] += 500
                        row["marks"] = {name: timestamp + 500 for name, timestamp in row["marks"].items()}
                    else:
                        row["marks"]["terminal_echo"] += 500
                result = latency.judge(self.receipt(rounds), self.previous)
                self.assertEqual(result["verdict"], "fail")
                self.assertEqual(result["metrics"][metric]["delta_ms"], 500)
                other = next(name for name in latency.FLOORS_MS if name != metric)
                self.assertEqual(result["metrics"][other]["verdict"], "pass")

    def test_echo_is_key_to_echo_and_a_missing_key_never_means_zero(self):
        self.assertEqual(self.receipt(self.rounds)["samples"]["typing_echo_ms"], [18, 20, 21, 19, 22])
        self.rounds[0]["marks"].pop("terminal.probe_key_typed")
        result = latency.judge(self.receipt(self.rounds), self.previous)
        self.assertEqual(result["verdict"], "unavailable")
        self.assertEqual(result["metrics"]["first_frame_ms"]["verdict"], "pass")

    def test_floor_relative_noise_and_strict_boundary(self):
        def compare(base, current):
            self.previous["latency"]["samples"]["first_frame_ms"] = base
            reading = self.receipt(self.rounds)
            reading["samples"]["first_frame_ms"] = current
            return latency.judge(reading, self.previous)["metrics"]["first_frame_ms"]

        self.assertEqual(compare([100] * 5, [250] * 5)["verdict"], "pass")
        self.assertEqual(compare([1000] * 5, [1251] * 5)["verdict"], "fail")
        row = compare([600, 800, 1000, 1200, 1400], [1300] * 5)
        self.assertEqual((row["threshold_ms"], row["verdict"]), (600, "pass"))
        self.assertEqual(compare([100] * 5, [100, 100, 100, 100, 3000])["verdict"], "pass")

    def test_first_good_without_samples_and_incomparable_machine(self):
        current = self.receipt(self.rounds)
        for base in (None, {"build": "100", "commit": "a" * 40}):
            self.assertEqual(latency.judge(current, base)["verdict"], "unavailable")
        self.previous["latency"]["machine"] = "other"
        self.assertEqual(latency.judge(current, self.previous)["verdict"], "unavailable")

    def test_round_failure_and_bad_input(self):
        def compare(**kwargs):
            report = self.receipt(self.rounds, **kwargs)
            return latency.judge(report, self.previous)

        self.assertEqual(compare(outcome="failure")["verdict"], "unavailable")
        self.assertEqual(compare(workspaces=1)["verdict"], "unavailable")
        self.rounds[0]["failures"] = ["the app typed no key: no window"]
        input_failure = ["round 1: the app typed no key: no window"]
        self.assertEqual(compare(outcome="failure", smoke_failures=input_failure + ["crash report"])["verdict"], "unavailable")
        mixed = compare(outcome="failure", verdict="fail", smoke_failures=input_failure)["metrics"]
        self.assertEqual(mixed["first_frame_ms"]["verdict"], "pass")
        self.assertEqual(mixed["typing_echo_ms"]["verdict"], "unavailable")
        self.rounds[0]["failures"] = ["the app exited (status 1)"]
        failed = compare()["metrics"]
        self.assertTrue(all(row["verdict"] == "unavailable" for row in failed.values()))
        self.rounds[0] = None
        self.assertEqual(compare()["verdict"], "unavailable")

    def test_only_matching_measurements_reach_the_durable_verdict(self):
        current = self.receipt(self.rounds)
        doc = {"verdict": "pass", "build": current["build"], "commit": "a" * 40,
               "canaryRun": self.run_url, "canaryAttempt": 1}
        with tempfile.TemporaryDirectory() as tmp:
            verdict, report = Path(tmp) / "verdict.json", Path(tmp) / "report.json"
            for change in ({}, {"source_commit": "bad-sha"}, {"build": "999"}, {"canaryRun": "another"}, {"canaryAttempt": 2}):
                with self.subTest(change=change):
                    verdict.write_text(json.dumps(doc))
                    report.write_text(json.dumps({**latency.judge(current, self.previous), **change}))
                    latency.attach(verdict, report)
                    saved = json.loads(verdict.read_text())
                    self.assertEqual(saved["verdict"], "pass")
                    self.assertEqual(saved["latency"]["verdict"], "unavailable" if change else "pass")

    def test_unreadable_harness_output_still_produces_an_advisory(self):
        with tempfile.TemporaryDirectory() as tmp:
            tti, output = Path(tmp) / "tti.json", Path(tmp) / "latency.json"
            tti.write_text("{")
            run = subprocess.run(
                [sys.executable, "-I", str(ROOT / "scripts/ci/nightly_next_canary_latency.py"), "report",
                 "--build", "101", "--source-commit", "b" * 40, "--run-url", self.run_url, "--attempt", "2",
                 "--machine", "fixture", "--harness-outcome", "failure", "--tti", str(tti), "--out", str(output)],
                capture_output=True, text=True, check=True)
            self.assertIn("::warning", run.stdout)
            self.assertEqual(json.loads(output.read_text())["verdict"], "unavailable")



class PreviousVerdictTests(unittest.TestCase):
    def test_newest_passing_verdict_with_a_full_commit(self):
        docs = {"103": None, "102": b"{", "101": json.dumps({"build": "101", "verdict": "fail", "commit": "a" * 40}),
                "100": json.dumps({"build": "100", "verdict": "pass", "commit": "a" * 40})}
        fetch = lambda url: docs[url.rsplit("/", 1)[1].removesuffix(".json")]
        self.assertEqual(latency.passing_verdict(["103", "102", "101", "100"], fetch)["build"], "100")
        self.assertIsNone(latency.passing_verdict(["103"], fetch))


class WiringTests(unittest.TestCase):
    doc = yaml.safe_load(WORKFLOW.read_text())
    steps = doc["jobs"]["canary"]["steps"]

    def by_name(self, name):
        return next(s for s in self.steps if s.get("name") == name)

    def test_every_sampling_step_is_advisory(self):
        for name in ADVISORY:
            with self.subTest(step=name):
                self.assertIs(self.by_name(name).get("continue-on-error"), True)

    def test_sampling_never_feeds_the_verdict(self):
        verdict = self.doc["jobs"]["canary"]["outputs"]["verdict"]
        self.assertEqual(verdict, "${{ steps.run.outputs.verdict || steps.broken.outputs.verdict }}")
        ids = {self.by_name(name).get("id") for name in ADVISORY} - {None}
        text = WORKFLOW.read_text()
        for step_id in ids:
            mentions = re.findall(rf"steps\.{step_id}\.", text)
            self.assertTrue(mentions)
        for job, spec in self.doc["jobs"].items():
            if job == "canary":
                continue
            self.assertNotIn("canary-latency", json.dumps(spec))

    def test_sampling_runs_after_the_verdict_and_before_the_harness_is_removed(self):
        names = [s.get("name") for s in self.steps]
        start = names.index(ADVISORY[0])
        self.assertGreater(start, names.index("Run the canary"))
        self.assertGreater(start, names.index("Detach the DMG"))
        self.assertLess(names.index(ADVISORY[-1]), names.index("Remove the harness worktree"))
        self.assertEqual(names[start:start + len(ADVISORY)], list(ADVISORY))

    def test_report_step_runs_the_script_this_test_covers(self):
        run = self.by_name("Record the felt-latency reading")["run"]
        self.assertIn("scripts/ci/nightly_next_canary_latency.py report", run)
        self.assertTrue((ROOT / "scripts/ci/nightly_next_canary_latency.py").is_file())


if __name__ == "__main__":
    unittest.main()
