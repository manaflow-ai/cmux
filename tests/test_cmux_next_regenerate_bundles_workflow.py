#!/usr/bin/env python3
"""cmux-next-regenerate-bundles.yml: lanes regenerate the committed web bundles without bun.

A lane runs scripts/cmux-next/regenerate-bundles-remote.sh, which dispatches the workflow for its
branch. The build job runs the branch's bundle scripts with the pinned bun and Node and no secrets,
and uploads a patch of the bundle paths only; the helper applies it for the lane to commit and push.
"""

from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/cmux-next-regenerate-bundles.yml"
HELPER = ROOT / "scripts/cmux-next/regenerate-bundles-remote.sh"


def load() -> dict:
    return yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))


def step(job: dict, name: str) -> dict:
    return next(item for item in job["steps"] if item.get("name") == name)


class RegenerateBundles(unittest.TestCase):
    def test_a_dispatch_names_the_branch(self):
        on = load()[True]  # PyYAML reads the `on` key as True
        inputs = on["workflow_dispatch"]["inputs"]
        self.assertTrue(inputs["branch"]["required"])
        self.assertFalse(inputs["sha"]["required"])
        self.assertEqual(set(on), {"workflow_dispatch"})

    def test_the_build_runs_both_scripts_with_the_pinned_toolchain_and_no_secrets(self):
        workflow = load()
        build = workflow["jobs"]["build"]
        self.assertEqual(build["permissions"], {"contents": "read"})
        text = yaml.safe_dump(build)
        self.assertNotIn("secrets.", text)
        runs = " ".join(item.get("run", "") for item in build["steps"])
        self.assertIn("scripts/cmux-next/build-agent-pane-web.sh", runs)
        self.assertIn("scripts/cmux-next/build-pages-web.sh", runs)
        pinned = (ROOT / "webviews/package.json").read_text(encoding="utf-8")
        bun = step(build, "Setup Bun")["with"]["bun-version"]
        self.assertIn(f'"version": "{bun}"', pinned)
        checkout = next(item for item in build["steps"] if item.get("uses", "").startswith("actions/checkout@"))
        self.assertFalse(checkout["with"]["persist-credentials"])

    def test_main_and_the_base_branch_are_refused(self):
        guard = step(load()["jobs"]["build"], "Resolve the branch")["run"]
        for branch in ("main", "feat-cmux-next"):
            self.assertIn(branch, guard)
        result = self.resolve("main")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("refusing", result.stdout + result.stderr)

    def resolve(self, branch: str) -> subprocess.CompletedProcess:
        script = step(load()["jobs"]["build"], "Resolve the branch")["run"]
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "out"
            output.touch()
            return subprocess.run(["bash", "-c", script], capture_output=True, text=True, timeout=30,
                                  env={"PATH": "/usr/bin:/bin", "BRANCH": branch, "SHA": "",
                                       "GITHUB_OUTPUT": str(output), "GITHUB_REPOSITORY": "manaflow-ai/cmux"})

    def test_no_job_holds_a_write_token(self):
        # The routing App has no contents permission; the lane commits and pushes the patch itself,
        # and that push runs CI as usual.
        workflow = load()
        self.assertEqual(set(workflow["jobs"]), {"build"})
        self.assertNotIn("secrets.", WORKFLOW.read_text(encoding="utf-8"))
        self.assertEqual(workflow["permissions"], {"contents": "read"})

    def test_the_run_names_its_branch_and_commit_for_the_helper(self):
        self.assertEqual(load()["run-name"], "regenerate bundles for ${{ inputs.branch }} @ ${{ inputs.sha }}")
        helper = HELPER.read_text(encoding="utf-8")
        self.assertIn('title="regenerate bundles for $branch @ $sha"', helper)
        self.assertIn('workflow_ref="${CMUX_REGENERATE_BUNDLES_REF:-feat-cmux-next}"', helper)
        self.assertIn('--ref "$workflow_ref"', helper)
        self.assertIn("cmux-next-bundles-patch", helper)
        upload = step(load()["jobs"]["build"], "Upload the bundle patch")
        self.assertEqual(upload["with"]["name"], "cmux-next-bundles-patch")

    def helper_in(self, branch: str, dirty: bool) -> subprocess.CompletedProcess:
        with tempfile.TemporaryDirectory() as directory:
            git = ["git", "-C", directory, "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"]
            subprocess.run([*git, "init", "-q", "-b", branch], check=True)
            (Path(directory) / "a.txt").write_text("a\n")
            subprocess.run([*git, "add", "a.txt"], check=True)
            subprocess.run([*git, "commit", "-qm", "a"], check=True)
            if dirty:
                (Path(directory) / "a.txt").write_text("b\n")
            env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
            env["PATH"] = "/usr/bin:/bin"  # no gh: a refusal must come first
            return subprocess.run(["bash", str(HELPER)], cwd=directory, capture_output=True, text=True,
                                  env=env, timeout=30)

    def test_the_helper_refuses_the_base_branches_and_a_dirty_tree(self):
        for branch in ("main", "feat-cmux-next"):
            result = self.helper_in(branch, dirty=False)
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertIn("lane branch", result.stderr)
        result = self.helper_in("lane", dirty=True)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("commit or stash", result.stderr)

    def test_the_helper_applies_only_bundle_paths(self):
        helper = HELPER.read_text(encoding="utf-8")
        collect = step(load()["jobs"]["build"], "Collect the bundle patch")["run"]
        for allowed in ("Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Resources/agent-pane",
                        "Packages/macOS/CmuxNext/Sources/CmuxNextPages/Resources/pages"):
            self.assertIn(allowed, collect)
            self.assertIn(allowed + "/*) continue", helper)
        self.assertIn("webviews/src/*/generated/strings.json) continue", helper)
        self.assertIn("git apply --numstat", helper)


if __name__ == "__main__":
    unittest.main()
