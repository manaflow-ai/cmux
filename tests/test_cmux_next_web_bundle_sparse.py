#!/usr/bin/env python3
"""Run the source-key expansion step after fresh and reused actions/checkout sparse setup.

Detector for job 140405412467: local core.sparseCheckout=true cannot override a previous
job's config.worktree=false. Exercise real git and the workflow's shell, including input
discovery across multiple passes; never replace the sparse checkout with a full tree.
"""
from __future__ import annotations

import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("git_fixture_env", ROOT / "tests/git_fixture_env.py")
git_fixture_env = importlib.util.module_from_spec(spec)
spec.loader.exec_module(git_fixture_env)
WORKFLOW = Path(os.environ.get("SPARSE_TEST_WORKFLOW", ROOT / ".github/workflows/cmux-next-web-bundle-publish.yml"))
STEPS = [step for job in yaml.safe_load(WORKFLOW.read_text())["jobs"].values() for step in job.get("steps", [])]
CHECKOUT = next(step for step in STEPS if step.get("name") == "Check out the source key's dirs")
EXPAND = next(step for step in STEPS if step.get("name") == "Add the rest of the source key's inputs")


class SourceKeySparseTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="source-key-sparse-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.env = git_fixture_env.fixture_env({
            **os.environ, "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "fixture", "GIT_AUTHOR_EMAIL": "fixture@example.test",
            "GIT_COMMITTER_NAME": "fixture", "GIT_COMMITTER_EMAIL": "fixture@example.test",
        })
        self.env.pop("BASH_ENV", None)
        git_fixture_env.init_repo(self.root, "-b", "main", env=self.env)
        files = {
            "webviews/main.ts": "export {};\n",
            "outside/first.ts": "imports the next input\n",
            "outside/second.ts": "a discovered dependency\n",
            "unrelated/large.bin": "must stay outside the checkout\n",
            "scripts/cmux-next/web-bundle-key.py": (
                "from pathlib import Path\n"
                "print('webviews/main.ts')\n"
                "print('outside/first')\n"
                "if Path('outside/first.ts').exists(): print('outside/second.ts')\n"
            ),
        }
        for name, content in files.items():
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
        self.git("add", ".")
        self.git("commit", "-qm", "fixture")

    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.root, env=self.env,
                              capture_output=True, text=True, check=True).stdout.strip()

    def checkout_and_expand(self, prior):
        if prior != "fresh":
            self.git("sparse-checkout", "set", "--cone", "webviews")
            if prior == "disabled":
                self.git("sparse-checkout", "disable")
        # The non-cone commands actions/checkout emitted in the failing job. Unlike `set`,
        # config without --worktree writes the local scope even with worktreeConfig enabled.
        self.git("config", "core.sparseCheckout", "true")
        patterns = self.root / self.git("rev-parse", "--git-path", "info/sparse-checkout")
        patterns.parent.mkdir(parents=True, exist_ok=True)
        patterns.write_text(CHECKOUT["with"]["sparse-checkout"])
        self.git("checkout", "--force", "HEAD")
        if prior == "disabled":
            self.assertEqual(self.git("config", "--bool", "core.sparseCheckout"), "false")
        result = subprocess.run(["bash", "-e", "-c", EXPAND["run"]], cwd=self.root,
                                env=self.env, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for name in ("webviews/main.ts", "scripts/cmux-next/web-bundle-key.py", "outside/first.ts", "outside/second.ts"):
            self.assertTrue((self.root / name).is_file(), name)
        self.assertFalse((self.root / "unrelated/large.bin").exists())
        self.assertEqual(self.git("config", "--bool", "core.sparseCheckoutCone"), "false")
        self.assertIn("still outside the checkout", result.stdout)

    def test_fresh_checkout_discovers_transitive_inputs(self):
        self.checkout_and_expand("fresh")

    def test_reused_disabled_worktree(self):
        self.checkout_and_expand("disabled")

    def test_reused_cone_worktree(self):
        self.checkout_and_expand("cone")


if __name__ == "__main__":
    unittest.main()
