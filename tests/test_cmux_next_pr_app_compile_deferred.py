"""The one-hop PR verdict: the build fleet's app compile runs at the land head, with full-ci and on base pushes,
not on every feat-cmux-next pull request head (docs/ci/cmux-next-workflow-notes/2026-11-26-one-hop-verdict.md)."""
from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/cmux-next.yml"
CLASSIFY = ROOT / "scripts/ci/cmux-next-steps/classify-pull-request-paths.sh"
GATE = "needs.path_route.outputs.app_compile_pr != 'false'"


def fast_tier_block() -> str:
    """The classifier's last two blocks (PR fast tier, cheap-tier cargo), which run on their own variables."""
    text = CLASSIFY.read_text(encoding="utf-8")
    start = text.index('if [[ "$EVENT_NAME" == pull_request && "${PR_BASE_REF:-}" == feat-cmux-next')
    return text[start:]


class AppCompileDeferredTest(unittest.TestCase):
    def setUp(self) -> None:
        self.jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]

    def test_both_app_compile_jobs_read_the_route(self) -> None:
        for name in ("app-compile-placement", "app-compile-fleet"):
            self.assertIn(GATE, self.jobs[name]["if"], name)

    def test_path_route_exports_it_and_passes_the_switch(self) -> None:
        route = self.jobs["path_route"]
        self.assertEqual(route["outputs"]["app_compile_pr"], "${{ steps.route.outputs.app_compile_pr }}")
        step = next(s for s in route["steps"] if s.get("id") == "route")
        self.assertIn("PR_APP_COMPILE", step["env"])

    def run_block(self, labels: str, route: str = "", head_tier: str = "", **env: str) -> dict:
        with tempfile.TemporaryDirectory() as tmp:
            out, summary = Path(tmp, "out"), Path(tmp, "summary")
            out.touch()
            script = "set -euo pipefail\nlabels=%s\nhead_tier=%s\n%s\n%s" % (repr(labels), head_tier, route, fast_tier_block())
            base = {"PATH": os.environ["PATH"], "EVENT_NAME": "pull_request", "PR_BASE_REF": "feat-cmux-next",
                    "PR_FAST_ONLY": "true", "GITHUB_OUTPUT": str(out), "GITHUB_STEP_SUMMARY": str(summary)}
            subprocess.run(["bash", "-c", script], check=True, env={**base, **env}, capture_output=True)
            pairs = (line.split("=", 1) for line in out.read_text().splitlines() if "=" in line)
            return dict(pairs)

    def test_a_head_that_is_not_landing_skips_it_and_the_mac_release(self) -> None:
        got = self.run_block("risk:normal")
        self.assertEqual(got.get("app_compile_pr"), "false")
        self.assertEqual(got.get("mac_release"), "false")

    def test_the_land_head_full_ci_and_the_switch_keep_it(self) -> None:
        self.assertNotIn("app_compile_pr", self.run_block("ready-to-land"))
        self.assertNotIn("app_compile_pr", self.run_block("full-ci"))
        self.assertNotIn("app_compile_pr", self.run_block("", PR_APP_COMPILE="1"))
        self.assertNotIn("app_compile_pr", self.run_block("", PR_FAST_ONLY="false"))

    ROUTED = "route_native=true\nroute_mac_release=true"

    def test_the_land_head_that_changes_the_app_runs_its_compile(self) -> None:
        """cmux#54956: a ready-to-land head on the cheap tier (CI_LAND_FULL_PER_PR=0) got native=false and
        mac_release=false, so app-compile-fleet skipped and a missing target dependency landed. Before: no
        app_compile_land; after: app_compile_land=true, and both app compile jobs run on it."""
        got = self.run_block("ready-to-land,risk:high", route=self.ROUTED, head_tier="cheap")
        self.assertEqual(got.get("mac_release"), "false")  # the Mac tiers stay deferred
        self.assertEqual(got.get("app_compile_land"), "true")
        context = {"github.event_name": "pull_request", "github.repository_owner": "manaflow-ai",
                   "github.repository": "manaflow-ai/cmux", "vars.CI_COMPILE_CHECK_GATEWAY": "gw",
                   "vars.CI_PR_POOL_OWNED": "1", "github.run_attempt": 1,
                   "github.event.pull_request.head.repo.full_name": "manaflow-ai/cmux",
                   "github.event.pull_request.base.ref": "feat-cmux-next", "github.event.action": "synchronize",
                   "needs.push-head-preflight.outputs.current": "true", "needs.path_route.result": "success",
                   "needs.path_route.outputs.labels": ",ready-to-land,risk:high,",
                   "needs.path_route.outputs.native": "false", "needs.path_route.outputs.macos": "false",
                   "needs.path_route.outputs.mac_release": "false"}
        sys.path.insert(0, str(ROOT / "tests"))
        from test_cmux_next_checks_workflow import evaluate
        for name in ("app-compile-placement", "app-compile-fleet"):
            self.assertFalse(evaluate(self.jobs[name]["if"], context), name)  # before
            self.assertTrue(evaluate(self.jobs[name]["if"], {**context, "needs.path_route.outputs.app_compile_land": "true"}), name)
            self.assertFalse(evaluate(self.jobs[name]["if"], {**context, "needs.path_route.outputs.app_compile_land": "true",
                                                              "github.event.pull_request.draft": True}), name)

    def test_no_land_compile_off_the_land_head_or_without_an_app_change(self) -> None:
        self.assertNotIn("app_compile_land", self.run_block("risk:normal", route=self.ROUTED, head_tier="cheap"))
        self.assertNotIn("app_compile_land", self.run_block("ready-to-land", route="route_native=false\nroute_mac_release=true"))
        self.assertNotIn("app_compile_land", self.run_block("ready-to-land", route="route_native=true\nroute_mac_release=false"))
        self.assertNotIn("app_compile_land", self.run_block("ready-to-land"))
        self.assertNotIn("app_compile_land", self.run_block("ready-to-land", route=self.ROUTED, PR_BASE_REF="main"))


if __name__ == "__main__":
    unittest.main()
