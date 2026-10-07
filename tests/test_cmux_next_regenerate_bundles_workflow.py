#!/usr/bin/env python3
"""cmux-next-regenerate-bundles.yml: lanes regenerate the committed web bundles without bun.

A lane dispatches the workflow for its branch. The build job runs the branch's bundle scripts
with the pinned bun and Node and no secrets, and uploads a patch of the bundle paths only. The
push job holds the App token and runs no branch code: it applies only bundle paths and pushes only
while the branch is still at the commit that was built.
"""

from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/cmux-next-regenerate-bundles.yml"


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

    def test_the_push_job_applies_only_bundle_paths(self):
        push = load()["jobs"]["push"]
        self.assertIn("needs.build.outputs.patch == 'true'", push["if"])
        script = step(push, "Apply and push the regenerated bundles")["run"]
        for allowed in ("Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Resources/agent-pane/",
                        "Packages/macOS/CmuxNext/Sources/CmuxNextPages/Resources/pages/",
                        "webviews/src/*/generated/strings.json"):
            self.assertIn(allowed, script)
        # The same allowlist, run on a patch that reaches outside it, refuses before applying.
        check = step(push, "Check the patch paths")["run"]
        with tempfile.TemporaryDirectory() as directory:
            patch = Path(directory) / "bundles.patch"
            patch.write_text("diff --git a/scripts/evil.sh b/scripts/evil.sh\nnew file mode 100755\n"
                             "--- /dev/null\n+++ b/scripts/evil.sh\n@@ -0,0 +1 @@\n+echo hi\n", encoding="utf-8")
            result = subprocess.run(["bash", "-c", check], cwd=directory, capture_output=True, text=True, timeout=30,
                                    env={"PATH": "/usr/bin:/bin", "PATCH_FILE": str(patch)})
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("scripts/evil.sh", result.stdout + result.stderr)
            patch.write_text("diff --git a/webviews/src/pages/settings/generated/strings.json "
                             "b/webviews/src/pages/settings/generated/strings.json\n"
                             "--- a/webviews/src/pages/settings/generated/strings.json\n"
                             "+++ b/webviews/src/pages/settings/generated/strings.json\n"
                             "@@ -1 +1 @@\n-{}\n+{\"a\": 1}\n", encoding="utf-8")
            result = subprocess.run(["bash", "-c", check], cwd=directory, capture_output=True, text=True, timeout=30,
                                    env={"PATH": "/usr/bin:/bin", "PATCH_FILE": str(patch)})
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_the_push_job_runs_no_branch_code_and_pushes_only_an_unmoved_branch(self):
        push = load()["jobs"]["push"]
        self.assertEqual(push["permissions"], {"contents": "read"})
        script = step(push, "Apply and push the regenerated bundles")["run"]
        self.assertIn('"$current" != "$HEAD_SHA"', script)
        self.assertNotIn("--force", script)
        runs = " ".join(item.get("run", "") for item in push["steps"])
        self.assertNotIn("scripts/", runs.replace("scripts/evil", ""))
        self.assertIn("# github-hosted-required:", WORKFLOW.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
