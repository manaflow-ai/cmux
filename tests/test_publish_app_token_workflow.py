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

import workflow_jobs
from nightly_workflow_text import nightly_text
from job_lists_routing import release_environment_jobs, unresolved_environment_jobs

ROOT = Path(__file__).resolve().parents[1]
NIGHTLY = ROOT / ".github" / "workflows" / "nightly.yml"


# Publish jobs whose environment (release or release-next) holds CMUX_RELEASE_APP_ID/_KEY.
APP_JOBS = {
    "recover-nightly-next-notarization": "read", "publish-nightly": "write", "keep-published-dsyms": "read",
    "generate-nightly-deltas": "read",
    "republish-nightly-deltas": "write", "publish-release-notes": "read",
    "publish-nightly-next-github": "write", "nightly-next-one": "write",
    # Mints the read token before its download of the published variant (#54859).
    "nightly-next-pkg": "read",
}
# The permission each job mints is a choice, so APP_JOBS stays hand-kept, but every nightly.yml
# job that can run under a release environment or reads the release App's credentials must be
# classified: in APP_JOBS, or here with why it does not mint through the wrapper.
# test_every_release_app_job_is_classified fails on a new one.
APP_TOKEN_EXEMPT = {
    "build-sign-notarize-nightly": (
        "signs and notarizes; its only github.token use is download-run-artifact.py reading the prepared "
        "app artifact, which writes nothing to a release"
    ),
    "promote-nightly-next": (
        "mints its own release App token (step app-token) in nightly-next-promote and hands it to "
        "promote-nightly-next.mjs as APP_TOKEN; it sends no github.token for the wrapper to replace"
    ),
    "promote-nightly-next-acked": (
        "the acked twin of promote-nightly-next: same own App token, same APP_TOKEN hand-off"
    ),
    "sign-live-code-variant": (
        "signs and notarizes the live code variant and uploads it to R2 with the nightly-next R2 keys; "
        "it writes nothing to a release and sends no github.token"
    ),
}
RELEASE_APP_SECRETS = ("CMUX_RELEASE_APP_ID", "CMUX_RELEASE_APP_KEY")
# nightly-next-one builds before it publishes: its build steps' gh calls already wait through a rate limit
# (the budget wrapper goes on PATH before the build), and it mints the App token only for publication.
BUDGET_FIRST = {"nightly-next-one"}
# A gh command in a step's run: `gh`, then a space, at a word start.
GH_CALL = re.compile(r"(?:^|[\s;|&(`])gh\s", re.M)


def release_app_jobs(jobs: dict) -> set[str]:
    """Jobs that can hold the release App's credentials: a release environment (or one that cannot
    be resolved), or a read of the credentials in any form (secrets.X, secrets['X'], any case,
    toJSON(secrets), secrets: inherit)."""
    return (release_environment_jobs(jobs) | unresolved_environment_jobs(jobs)
            | {name for name, job in jobs.items() if workflow_jobs.reads_secret(job, *RELEASE_APP_SECRETS)})


def unclassified_app_jobs(jobs: dict) -> set[str]:
    return release_app_jobs(jobs) - set(APP_JOBS) - set(APP_TOKEN_EXEMPT)


APP_INSTALL = re.compile(r"bash (\.publish-tooling/)?scripts/ci/gh_app_token\.sh --install")
BUDGET_INSTALL = re.compile(r"bash (\.publish-tooling/)?scripts/ci/gh_budget_wait\.sh --install")


class WorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.jobs = workflow_jobs.jobs(NIGHTLY)

    def test_every_release_app_job_is_classified(self) -> None:
        self.assertLessEqual({"publish-nightly", "promote-nightly-next"}, release_app_jobs(self.jobs))
        self.assertEqual(set(APP_JOBS) & set(APP_TOKEN_EXEMPT), set())
        self.assertEqual(unclassified_app_jobs(self.jobs), set())
        # A classified name that no longer holds the credentials is stale.
        self.assertEqual((set(APP_JOBS) | set(APP_TOKEN_EXEMPT)) - release_app_jobs(self.jobs), set())

    def test_a_new_release_app_job_must_be_classified(self) -> None:
        tail = "${{ github.ref == 'refs/heads/nightly-next' && 'release-next' || 'release' }}"
        for name, job in (
            ("publish-env-fixture", {"environment": tail, "steps": [{"run": "gh release upload"}]}),
            ("publish-secret-fixture", {"environment": "pr-media",
                                        "steps": [{"with": {"app-id": "${{ secrets.CMUX_RELEASE_APP_ID }}"}}]}),
            ("publish-bracket-fixture", {"environment": "pr-media",
                                         "steps": [{"with": {"private-key": "${{ secrets['CMUX_RELEASE_APP_KEY'] }}"}}]}),
            ("publish-double-bracket-fixture", {"steps": [{"with": {"app-id": '${{ secrets["CMUX_RELEASE_APP_ID"] }}'}}]}),
            ("publish-lowercase-fixture", {"steps": [{"with": {"private-key": "${{ secrets.cmux_release_app_key }}"}}]}),
            ("publish-tojson-fixture", {"steps": [{"env": {"ALL": "${{ toJSON(secrets) }}"}}]}),
            ("publish-inherit-fixture", {"uses": "./.github/workflows/publish.yml", "secrets": "inherit"}),
            ("publish-matrix-fixture", {"environment": "${{ matrix.environment }}",
                                        "strategy": {"matrix": {"environment": ["release"]}}}),
            ("publish-unknown-env-fixture", {"environment": "${{ inputs.environment }}"}),
        ):
            with self.subTest(job=name):
                self.assertEqual(unclassified_app_jobs({**self.jobs, name: job}), {name})

    def test_a_release_app_job_whose_environment_differs_in_case_must_be_classified(self) -> None:
        """Codex: GitHub matches environment names without case, so `environment: Release` is the release
        environment; workflow_jobs casefolds every resolved name."""
        for name, environment in (("publish-case-fixture", "Release"), ("publish-upper-fixture", {"name": "RELEASE-NEXT"}),
                                  ("publish-branch-case-fixture", "${{ inputs.x && 'Release' || 'pr-media' }}")):
            with self.subTest(job=name):
                job = {"environment": environment, "steps": [{"run": "gh release upload"}]}
                self.assertEqual(unclassified_app_jobs({**self.jobs, name: job}), {name})

    def test_a_listed_release_app_job_in_another_case_stays_green(self) -> None:
        listed = workflow_jobs.copy_job(self.jobs["publish-release-notes"], {"environment": "Release"})
        self.assertEqual(unclassified_app_jobs({**self.jobs, "publish-release-notes": listed}), set())

    def test_a_listed_release_app_job_reading_the_key_by_bracket_stays_green(self) -> None:
        listed = workflow_jobs.copy_job(self.jobs["publish-release-notes"])
        listed["steps"] = [*listed["steps"], {"with": {"private-key": "${{ secrets['cmux_release_app_key'] }}"}}]
        fixture = {**self.jobs, "publish-release-notes": listed}
        self.assertEqual(unclassified_app_jobs(fixture), set())

    def test_publish_jobs_mint_the_app_token_and_install_before_the_budget_wait(self) -> None:
        for name, contents in APP_JOBS.items():
            job, steps = self.jobs[name], self.jobs[name]["steps"]
            # workflow_jobs.environment_spec's one shape: a string environment is {"name": it}.
            self.assertIn(workflow_jobs.resolve(job).environment, tuple({"name": environment} for environment in (
                "release-next", "${{ needs.decide.outputs.environment }}",
                # Tail jobs: decide is in another run on nightly-next.
                "${{ github.ref == 'refs/heads/nightly-next' && 'release-next' || 'release' }}")), name)
            mint = [i for i, s in enumerate(steps) if s.get("id") == "gh-app-token"]
            app = [i for i, s in enumerate(steps) if APP_INSTALL.search(str(s.get("run", "")))]
            budget = [i for i, s in enumerate(steps) if BUDGET_INSTALL.search(str(s.get("run", "")))]
            self.assertEqual((len(mint), len(app), len(budget)), (1, 1, 1), name)
            # Mint, then this wrapper, then gh_budget_wait.sh, which wraps it and keeps its wait.
            if name in BUDGET_FIRST:
                # Each wrapper calls the gh first on PATH when it was installed, so here the App wrapper
                # calls the budget wrapper, which still waits: app -> budget -> gh.
                self.assertEqual(app[0], mint[0] + 1, name)
                self.assertLess(budget[0], mint[0], name)
            else:
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
            # Every step that sends github.token to gh runs after the wrapper is on PATH. A step that
            # hands it only to git as FETCH_TOKEN (an http extraheader: the Mac git credential step,
            # anchor github-token-for-git, #58418, and the warm checkout, #58081) runs before the
            # checkout the wrapper comes from, and must call no gh.
            for i, s in enumerate(steps):
                env = s.get("env", {}) or {}
                if [k for k, v in env.items() if "github.token" in str(v)] == ["FETCH_TOKEN"]:
                    self.assertIsNone(GH_CALL.search(str(s.get("run", ""))), (name, s.get("name")))
                    continue
                if i != app[0] and "github.token" in str(env):
                    self.assertGreater(i, budget[0], (name, s.get("name")))

    def test_release_asset_uploads_take_the_app_token_first(self) -> None:
        for name in ("publish-nightly", "republish-nightly-deltas", "publish-nightly-next-github"):
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
            if ".publish-tooling/" in run:
                # One scripts-only checkout at the workflow commit (test_nightly_cmux_tui_resolve.py
                # exempts exactly that shape from the build-commit pin).
                tooling = [s for s in steps if (s.get("with") or {}).get("path") == ".publish-tooling"]
                self.assertEqual(len(tooling), 1, name)
                self.assertEqual(tooling[0]["with"]["ref"], "${{ github.sha }}", name)
                self.assertFalse(tooling[0]["with"]["persist-credentials"], name)
            else:  # the job's own checkout is the workflow commit
                checkout = next(s for s in steps if "actions/checkout" in str(s.get("uses", "")))
                self.assertIn(checkout.get("with", {}).get("ref", "${{ github.sha }}"), ("${{ github.sha }}",), name)

    def test_uploaders_run_from_the_workflow_commit(self) -> None:
        # A build checkout may predate GH_APP_TOKEN support; these jobs run the uploader from
        # .publish-tooling (github.sha) so the App token is read.
        # republish-nightly-deltas runs its uploader from scripts/ci/nightly-steps/; read that script inline.
        expanded = workflow_jobs.jobs(nightly_text())
        for name in ("republish-nightly-deltas",):
            steps = expanded[name]["steps"]
            tooling = next(s for s in steps if (s.get("with") or {}).get("path") == ".publish-tooling")
            self.assertEqual(tooling["with"]["ref"], "${{ github.sha }}", name)
            for script in ("scripts/ci/publish-release-assets.py", "scripts/ci/gh_app_token.sh"):
                self.assertIn(script, tooling["with"]["sparse-checkout"], name)
            # The republish run block lives in scripts/ci/nightly-steps/republish-deltas-and-appcasts.sh, run from
            # .publish-tooling (it is in the sparse list) so it is the workflow commit's copy too.
            def text(step):
                run = str(step.get("run", ""))
                if ".publish-tooling/scripts/ci/nightly-steps/republish-deltas-and-appcasts.sh" in run:
                    self.assertIn("scripts/ci/nightly-steps/republish-deltas-and-appcasts.sh", tooling["with"]["sparse-checkout"], name)
                    return (ROOT / "scripts/ci/nightly-steps/republish-deltas-and-appcasts.sh").read_text(encoding="utf-8")
                return run
            uploads = [s for s in steps if "publish-release-assets.py" in text(s)]
            self.assertTrue(uploads, name)
            for step in uploads:
                run = text(step)
                self.assertIn(".publish-tooling/scripts/ci/publish-release-assets.py", run, (name, step.get("name")))
                self.assertNotIn("python3 scripts/ci/publish-release-assets.py", run, (name, step.get("name")))

    def test_nightly_yml_stays_under_githubs_workflow_size_limit(self) -> None:
        # GitHub refuses a workflow file over 512,000 bytes before any job starts: run 40424952395
        # (518,322 bytes) failed with 0 jobs; a comment-padded copy of base at 512,100 bytes failed
        # the same way, and one at 511,900 bytes produced no startup failure. The App-token steps are YAML aliases to stay under.
        size = (ROOT / ".github/workflows/nightly.yml").stat().st_size
        self.assertLess(size, 512_000, f"nightly.yml is {size} bytes; GitHub will not start it")

if __name__ == "__main__":
    unittest.main()
