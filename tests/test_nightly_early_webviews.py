#!/usr/bin/env python3
"""The one-job nightly runs its webview checks before the signer and skips the retry on a webview red.

cmuxterm-hq#19108 (brief): "Run the webview check first ... before the release build starts." /
"Skip Retry on deterministic reds." docs/ci/nightly-workflow-notes.md#note-51.
"""
from __future__ import annotations

import re
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/nightly.yml"
EARLY = "early-nightly-webviews"
RED_ON_BUILT = (f"needs.{EARLY}.outputs.red_sha == '' || needs.{EARLY}.outputs.red_sha != "
                "needs.resolve-nightly-cmux-tui-client.outputs.build_sha")

# The steps of nightly-next-one that compile this repo's code: a failure there is the tree, not the runner.
COMPILE_STEPS = ("chief-build", "mobile-host-build", "app-release-build", "chief-bundle")


def one_line(value) -> str:
    return re.sub(r"\s+", " ", str(value or "")).strip()


class EarlyNightlyWebviewsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]

    def needs(self, job: str) -> list[str]:
        value = self.jobs[job].get("needs") or []
        return [value] if isinstance(value, str) else list(value)

    def test_it_runs_beside_resolve_on_decides_head(self) -> None:
        job = self.jobs[EARLY]
        self.assertEqual(self.needs(EARLY), ["decide"], "only decide, so it runs alongside resolve")
        cond = one_line(job["if"])
        self.assertIn("needs.decide.outputs.one_job == 'true'", cond)
        self.assertIn("needs.decide.outputs.track == 'nightly-next'", cond)
        checkout = next(s for s in job["steps"] if str(s.get("uses", "")).startswith("actions/checkout@"))
        self.assertEqual(checkout["with"]["ref"], "${{ needs.decide.outputs.head_sha }}")
        self.assertFalse(checkout["with"]["persist-credentials"])
        run = next(s for s in job["steps"] if s.get("id") == "checks")["run"]
        self.assertIn("fast_gate_webviews_checks.py", run, "the same check the signer runs")

    def test_it_holds_no_secret_and_never_the_signing_mac(self) -> None:
        job = self.jobs[EARLY]
        self.assertEqual(job["permissions"], {"contents": "read"})
        self.assertNotIn("secrets.", WORKFLOW.read_text(encoding="utf-8").split(f"  {EARLY}:\n", 1)[1]
                         .split("\n  prepare-nightly-variant-primary:", 1)[0])
        self.assertEqual(one_line(job["runs-on"]), one_line(self.jobs["check-nightly-webviews"]["runs-on"]),
                         "check-nightly-webviews' Linux route")

    def test_the_signer_skips_only_the_red_commit(self) -> None:
        # Leo, 2026-11-25: publish blocks on four things; the early webview check no longer holds the signer.
        self.assertNotIn(EARLY, self.needs("nightly-next-one"))
        self.assertIn("steps.webview-checks.outcome == 'failure'",
                      self.jobs["nightly-next-one"]["outputs"]["webview_red"])

    def test_retry_skips_a_webview_red(self) -> None:
        self.assertIn(EARLY, self.needs("retry-nightly-next"))
        cond = one_line(self.jobs["retry-nightly-next"]["if"])
        self.assertIn("needs.nightly-next-one.outputs.webview_red != 'true'", cond)
        self.assertIn(RED_ON_BUILT, cond)

    def test_retry_skips_a_compile_red_on_the_same_commit(self) -> None:
        # Run 45556730650: the retry rebuilt an E0063 red on the same tree for 1 h of the signer slot.
        job = self.jobs["nightly-next-one"]
        red = one_line(job["outputs"].get("compile_red"))
        for step in COMPILE_STEPS:
            self.assertIn(step, [s.get("id") for s in job["steps"]], f"nightly-next-one has no {step} step")
            self.assertIn(f"steps.{step}.outcome == 'failure'", red, f"compile_red misses {step}")
        self.assertIn("needs.nightly-next-one.outputs.compile_red != 'true'",
                      one_line(self.jobs["retry-nightly-next"]["if"]))

    def test_a_skipped_signer_still_wakes_the_loop_and_reports(self) -> None:
        self.assertIn(EARLY, self.needs("wake-nightly-next-tick"))
        self.assertIn(f"needs.{EARLY}.outputs.red_sha != ''", one_line(self.jobs["wake-nightly-next-tick"]["if"]))
        self.assertIn(EARLY, self.needs("report-nightly-failure"))


if __name__ == "__main__":
    unittest.main()
