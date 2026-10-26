#!/usr/bin/env python3
"""The publish jobs mint the release App token and put scripts/ci/gh_app_token.sh on PATH.

The wrapper and the uploaders' fallback are tested in tests/test_gh_app_token.py. Here: every
publish job whose environment holds CMUX_RELEASE_APP_ID/_KEY mints a contents-only token
(continue-on-error, so a failed mint keeps github.token) and installs the wrapper before any step
that sends github.token, and the uploaders get GH_APP_TOKEN with GH_TOKEN as the fallback.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
NIGHTLY = ROOT / ".github" / "workflows" / "nightly.yml"


# Publish jobs whose environment (release or release-next) holds CMUX_RELEASE_APP_ID/_KEY.
APP_JOBS = {
    "recover-nightly-next-notarization": "read", "publish-nightly": "write", "keep-published-dsyms": "read",
    "legacy-identity-target": "read", "sign-nightly-identity-legacy": "read",
    "publish-nightly-identity-legacy": "write", "generate-nightly-deltas": "read",
    "republish-nightly-deltas": "write", "publish-release-notes": "read",
}
APP_INSTALL = re.compile(r"bash (\.publish-tooling/|\.gh-tooling/)?scripts/ci/gh_app_token\.sh --install")
BUDGET_INSTALL = re.compile(r"bash (\.publish-tooling/)?scripts/ci/gh_budget_wait\.sh --install")


class WorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        import yaml
        cls.jobs = yaml.safe_load(NIGHTLY.read_text(encoding="utf-8"))["jobs"]

    def test_publish_jobs_mint_the_app_token_and_install_before_the_budget_wait(self) -> None:
        for name, contents in APP_JOBS.items():
            job, steps = self.jobs[name], self.jobs[name]["steps"]
            self.assertIn(job.get("environment"), ("release-next", "${{ needs.decide.outputs.environment }}"), name)
            mint = [i for i, s in enumerate(steps) if s.get("id") == "gh-app-token"]
            app = [i for i, s in enumerate(steps) if APP_INSTALL.search(str(s.get("run", "")))]
            budget = [i for i, s in enumerate(steps) if BUDGET_INSTALL.search(str(s.get("run", "")))]
            self.assertEqual((len(mint), len(app), len(budget)), (1, 1, 1), name)
            # Mint, then this wrapper, then gh_budget_wait.sh, which wraps it and keeps its wait.
            self.assertEqual((app[0], budget[0]), (mint[0] + 1, mint[0] + 2), name)
            step = steps[mint[0]]
            self.assertIn("actions/create-github-app-token@", step["uses"])
            self.assertTrue(step.get("continue-on-error"), name)  # a failed mint keeps github.token
            self.assertEqual(step["with"]["app-id"], "${{ secrets.CMUX_RELEASE_APP_ID }}")
            self.assertEqual(step["with"]["private-key"], "${{ secrets.CMUX_RELEASE_APP_KEY }}")
            self.assertEqual(step["with"]["permission-contents"], contents, name)
            self.assertEqual({k for k in step["with"] if k.startswith("permission-")}, {"permission-contents"}, name)
            self.assertEqual(steps[app[0]]["env"], {"GH_APP_TOKEN": "${{ steps.gh-app-token.outputs.token }}",
                                                    "GH_FALLBACK_TOKEN": "${{ github.token }}"}, name)
            # Every step that sends github.token runs after the wrapper is on PATH.
            for i, s in enumerate(steps):
                if i != app[0] and "github.token" in str(s.get("env", {})):
                    self.assertGreater(i, budget[0], (name, s.get("name")))

    def test_release_asset_uploads_take_the_app_token_first(self) -> None:
        for name in ("publish-nightly", "republish-nightly-deltas"):
            for step in self.jobs[name]["steps"]:
                if "publish-release-assets.py" in str(step.get("run", "")):
                    self.assertEqual(step["env"]["GH_APP_TOKEN"], "${{ steps.gh-app-token.outputs.token }}", step["name"])
                    self.assertEqual(step["env"]["GH_TOKEN"], "${{ github.token }}", step["name"])

    def test_prune_and_finalize_take_the_app_token(self) -> None:
        steps = {s.get("name"): s for s in self.jobs["publish-nightly"]["steps"]}
        self.assertEqual(steps["Prune old nightly release assets"]["env"]["GH_APP_TOKEN"],
                         "${{ steps.gh-app-token.outputs.token }}")
        for name in ("Publish verified nightly release metadata", "Record verified nightly publication"):
            # nightly-next's GH_TOKEN is already the release App's, with Workflows write.
            self.assertEqual(steps[name]["env"]["GH_APP_TOKEN"],
                             "${{ needs.decide.outputs.track != 'nightly-next' && steps.gh-app-token.outputs.token || '' }}")

    def test_the_wrapper_comes_from_the_workflow_commit(self) -> None:
        for name in APP_JOBS:
            steps = self.jobs[name]["steps"]
            run = next(s["run"] for s in steps if APP_INSTALL.search(str(s.get("run", ""))))
            if ".gh-tooling/" in run:
                checkout = next(s for s in steps if s.get("name") == "Checkout the gh token wrapper at the workflow commit")
                self.assertEqual(checkout["with"]["ref"], "${{ github.sha }}", name)
                self.assertFalse(checkout["with"]["persist-credentials"], name)
            elif ".publish-tooling/" in run:
                tooling = next(s for s in steps if (s.get("with") or {}).get("path") == ".publish-tooling")
                self.assertEqual(tooling["with"]["ref"], "${{ github.sha }}", name)
            else:  # the job's own checkout is the workflow commit
                checkout = next(s for s in steps if "actions/checkout" in str(s.get("uses", "")))
                self.assertIn(checkout.get("with", {}).get("ref", "${{ github.sha }}"), ("${{ github.sha }}",), name)

    def test_legacy_target_runs_only_where_its_environment_admits(self) -> None:
        job = self.jobs["legacy-identity-target"]
        self.assertEqual(job["environment"], "release-next")
        self.assertIn("github.ref == 'refs/heads/nightly-next'", job["if"])
        self.assertIn("needs.decide.outputs.environment == 'release-next'", job["if"])

    def test_uploaders_run_from_the_workflow_commit(self) -> None:
        # A build checkout may predate GH_APP_TOKEN support; these jobs run the uploaders from
        # .gh-tooling (github.sha) so the App token is read.
        for name in ("republish-nightly-deltas",):
            steps = self.jobs[name]["steps"]
            checkout = next(s for s in steps if s.get("name") == "Checkout the gh token wrapper at the workflow commit")
            for script in ("scripts/ci/publish-release-assets.py",):
                self.assertIn(script, checkout["with"]["sparse-checkout"], name)
            for step in steps:
                run = str(step.get("run", ""))
                for script in ("publish-release-assets.py", "finalize-release.py", "prune_nightly_release_assets.py"):
                    if f"{script} " in run or f"{script} \\" in run:
                        self.assertIn(f".gh-tooling/scripts/", run, (name, step.get("name"), script))
                        self.assertNotIn(f"python3 scripts/ci/{script}", run, (name, step.get("name")))

if __name__ == "__main__":
    unittest.main()
