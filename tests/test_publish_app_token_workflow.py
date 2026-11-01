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


# Publish jobs whose environment (release) holds CMUX_RELEASE_APP_ID/_KEY, by workflow.
DEV = ROOT / ".github" / "workflows" / "cmux-next-dev-daily.yml"
APP_JOBS = {
    NIGHTLY: {"publish-nightly": "write", "generate-nightly-deltas": "read", "republish-nightly-deltas": "write"},
    DEV: {"publish": "write"},
}
APP_INSTALL = re.compile(r"bash (\.gh-tooling/)?scripts/ci/gh_app_token\.sh --install")


class WorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        import yaml
        cls.workflows = {path: yaml.safe_load(path.read_text(encoding="utf-8"))["jobs"] for path in APP_JOBS}

    def test_publish_jobs_mint_the_app_token_and_install_before_their_gh_calls(self) -> None:
        for path, jobs in APP_JOBS.items():
            for name, contents in jobs.items():
                job = self.workflows[path][name]
                steps = job["steps"]
                self.assertEqual(job.get("environment"), "release", name)
                mint = [i for i, s in enumerate(steps) if s.get("id") == "gh-app-token"]
                app = [i for i, s in enumerate(steps) if APP_INSTALL.search(str(s.get("run", "")))]
                self.assertEqual((len(mint), len(app)), (1, 1), name)
                self.assertEqual(app[0], mint[0] + 1, name)
                step = steps[mint[0]]
                self.assertIn("actions/create-github-app-token@", step["uses"])
                self.assertTrue(step.get("continue-on-error"), name)  # a failed mint keeps github.token
                self.assertEqual(step["with"]["app-id"], "${{ secrets.CMUX_RELEASE_APP_ID }}")
                self.assertEqual(step["with"]["private-key"], "${{ secrets.CMUX_RELEASE_APP_KEY }}")
                self.assertEqual(step["with"]["permission-contents"], contents, name)
                self.assertEqual(job["permissions"].get("contents"), contents, name)
                self.assertEqual({k for k in step["with"] if k.startswith("permission-")}, {"permission-contents"}, name)
                self.assertEqual(steps[app[0]]["env"], {"GH_APP_TOKEN": "${{ steps.gh-app-token.outputs.token }}",
                                                        "GH_FALLBACK_TOKEN": "${{ github.token }}"}, name)
                # The backoff fits the job's timeout.
                self.assertIn("GH_BUDGET_WAIT_MAX_SECONDS=600", steps[app[0]]["run"])
                self.assertGreaterEqual(int(job.get("timeout-minutes", 360)), 15 + 10, name)
                # Every step that sends github.token runs after the wrapper is on PATH.
                for i, s in enumerate(steps):
                    if i != app[0] and "github.token" in str(s.get("env", {})):
                        self.assertGreater(i, app[0], (name, s.get("name")))

    def test_release_asset_uploads_take_the_app_token_first(self) -> None:
        for name in ("publish-nightly", "republish-nightly-deltas"):
            uploads = [s for s in self.workflows[NIGHTLY][name]["steps"]
                       if "publish-release-assets.py" in str(s.get("run", ""))]
            self.assertTrue(uploads, name)
            for step in uploads:
                self.assertEqual(step["env"]["GH_APP_TOKEN"], "${{ steps.gh-app-token.outputs.token }}", step["name"])
                self.assertEqual(step["env"]["GH_TOKEN"], "${{ github.token }}", step["name"])

    def test_prune_and_finalize_take_the_app_token(self) -> None:
        steps = {s.get("name"): s for s in self.workflows[NIGHTLY]["publish-nightly"]["steps"]}
        for name in ("Prune old nightly release assets", "Publish verified nightly release metadata",
                     "Record verified nightly publication"):
            self.assertEqual(steps[name]["env"]["GH_APP_TOKEN"], "${{ steps.gh-app-token.outputs.token }}", name)

    def test_the_wrapper_comes_from_the_workflow_commit(self) -> None:
        for name in APP_JOBS[NIGHTLY]:
            steps = self.workflows[NIGHTLY][name]["steps"]
            checkout = next(s for s in steps if s.get("name") == "Checkout the gh token wrapper at the workflow commit")
            self.assertEqual(checkout["with"]["ref"], "${{ github.sha }}", name)
            self.assertFalse(checkout["with"]["persist-credentials"], name)
            self.assertIn(".gh-tooling/scripts/ci/gh_app_token.sh --install",
                          next(s["run"] for s in steps if APP_INSTALL.search(str(s.get("run", "")))), name)

    def test_the_dev_publisher_runs_main_s_wrapper(self) -> None:
        steps = self.workflows[DEV]["publish"]["steps"]
        checkout = next(s for s in steps if s.get("name") == "Checkout the gh token wrapper from main")
        self.assertEqual(checkout["with"]["ref"], "${{ github.event.repository.default_branch }}")
        self.assertFalse(checkout["with"]["persist-credentials"])
        self.assertEqual(checkout["with"]["sparse-checkout"], "scripts/ci/gh_app_token.sh")

    def test_uploaders_run_from_the_workflow_commit(self) -> None:
        # A build checkout may predate GH_APP_TOKEN support; these jobs run the uploaders from
        # .gh-tooling (github.sha) so the App token is read.
        for name in ("publish-nightly", "republish-nightly-deltas"):
            steps = self.workflows[NIGHTLY][name]["steps"]
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
