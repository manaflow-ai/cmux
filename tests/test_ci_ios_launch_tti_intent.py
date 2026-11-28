"""ios-launch-tti-hosted.yml runs its hosted macOS legs on a pull request only when the pull request
says it is a measurement (the `launch-tti` label, or `[measure`, `launch tti` or `hosted tti` in the
title). Any other pull request that edits the file (a comment, a runner label, a sweep over every
workflow) skips the legs with no runner, and a label other than launch-tti never cancels a measurement.
"""

from __future__ import annotations

import pathlib
import unittest

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "ios-launch-tti-hosted.yml"


def load() -> dict:
    return yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))


class LaunchTTIIntentTest(unittest.TestCase):
    def test_pull_request_trigger_takes_the_label_event(self) -> None:
        on = load()[True]
        self.assertEqual(on["pull_request"]["types"], ["opened", "synchronize", "reopened", "labeled"])
        self.assertEqual(on["pull_request"]["paths"], [".github/workflows/ios-launch-tti-hosted.yml"])
        self.assertIn("workflow_dispatch", on)

    def test_every_job_is_gated_on_measurement_intent(self) -> None:
        jobs = load()["jobs"]
        self.assertTrue(jobs)
        for name, job in jobs.items():
            cond = job.get("if", "")
            with self.subTest(job=name):
                self.assertIn("github.event_name != 'pull_request'", cond)
                self.assertIn("github.event.label.name == 'launch-tti'", cond)
                self.assertIn("contains(github.event.pull_request.labels.*.name, 'launch-tti')", cond)
                for marker in ("[measure", "launch tti", "hosted tti"):
                    self.assertIn(f"contains(github.event.pull_request.title, '{marker}')", cond)
                # A bare `tti` would match `settings` (contains() ignores case).
                self.assertNotIn("contains(github.event.pull_request.title, 'tti')", cond)

    def test_other_labels_never_cancel_a_measurement(self) -> None:
        group = load()["concurrency"]["group"]
        self.assertIn("github.event.label.name != 'launch-tti'", group)
        self.assertIn("format('-label-{0}', github.run_id)", group)


if __name__ == "__main__":
    unittest.main()
