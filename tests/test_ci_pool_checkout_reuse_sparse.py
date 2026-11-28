#!/usr/bin/env python3
"""A pool mirror checkout that reuses the last job's .git leaves that job's sparse state behind correctly.

#61461 made "Pool mirror: Checkout" steps reuse the previous job's .git and run `git sparse-checkout reapply` on
every reuse. A step whose SPARSE is empty never turns sparse mode on, so on a reused .git that was not sparse the
reapply is fatal ("must be in a sparse-checkout to reapply sparsity patterns": rust workspaces runs 46017040692,
46016977697, 46016950216 on 2026-11-27). On a .git another workflow left sparse it would keep that workflow's
patterns and hand this job a partial tree. Each such step now reapplies only its own patterns and leaves sparse
mode when it has none.

This runs the tail of each step (from writing the patterns to the final echo) in a real reused repository: the
head needs the pool VM's mirror, which a test cannot have.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

import importlib.util as _git_fixture_importlib
import yaml

ROOT = Path(__file__).resolve().parents[1]
_spec = _git_fixture_importlib.spec_from_file_location("git_fixture_env", ROOT / "tests" / "git_fixture_env.py")
git_fixture_env = _git_fixture_importlib.module_from_spec(_spec)
_spec.loader.exec_module(git_fixture_env)

GUARD = 'if [[ -n "${SPARSE//[[:space:]]/}" ]]; then'
TAIL_END = "workspace=$reuse"


def steps() -> list[tuple[str, str, str]]:
    """(label, SPARSE, tail script) for every reusing pool checkout step that may run without patterns."""
    found = []
    for path in sorted((ROOT / ".github/workflows").glob("*.yml")):
        text = path.read_text(encoding="utf-8")
        if TAIL_END not in text:
            continue
        for job_name, job in (yaml.load(text, Loader=yaml.BaseLoader).get("jobs") or {}).items():
            for step in job.get("steps") or []:
                run = step.get("run") or ""
                if TAIL_END not in run or GUARD not in run:
                    continue
                start = run.index(GUARD)
                end = run.index("\n", run.index(TAIL_END))
                sparse = (step.get("env") or {}).get("SPARSE", "")
                found.append((f"{path.name}:{job_name}:{step.get('name')}", sparse, run[start:end]))
    return found


def git(cwd: Path, *args: str) -> str:
    env = git_fixture_env.fixture_env({**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
                                       "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"})
    return subprocess.run(["git", *args], cwd=cwd, env=env, check=True, capture_output=True, text=True).stdout


class Reused:
    """A workspace a previous job checked out, now at commit B with a/x, b/y and c/z."""

    def __init__(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="pool-reuse-sparse-"))
        self.ws = self.tmp / "ws"
        self.ws.mkdir()
        git_fixture_env.init_repo(self.ws, "-b", "main", env=git_fixture_env.fixture_env())
        for rel in ("a/x", "b/y"):
            (self.ws / rel).parent.mkdir(parents=True, exist_ok=True)
            (self.ws / rel).write_text(rel + "\n")
        git(self.ws, "add", "-A")
        git(self.ws, "commit", "-qm", "A")
        (self.ws / "c").mkdir()
        (self.ws / "c/z").write_text("c/z\n")
        git(self.ws, "add", "-A")
        git(self.ws, "commit", "-qm", "B")
        self.sha = git(self.ws, "rev-parse", "HEAD").strip()
        git(self.ws, "checkout", "-q", "--detach", "HEAD~1")

    def run(self, tail: str, sparse: str) -> subprocess.CompletedProcess:
        script = f"set -euo pipefail\nreuse=reused\n{tail}\n"
        env = git_fixture_env.fixture_env({**os.environ, "HOME": str(self.tmp), "SHA": self.sha, "SPARSE": sparse})
        return subprocess.run(["bash", "-c", script], cwd=self.ws, env=env, capture_output=True, text=True)

    def files(self) -> set[str]:
        return {str(p.relative_to(self.ws)) for p in self.ws.rglob("*") if p.is_file() and ".git" not in p.parts}

    def close(self) -> None:
        shutil.rmtree(self.tmp, ignore_errors=True)


class PoolCheckoutReuse(unittest.TestCase):
    def setUp(self) -> None:
        self.cases = steps()
        self.assertTrue(any(s == "" for _, s, _ in self.cases), "rust-workspaces' pool checkout has SPARSE ''")

    def each(self, prepare, sparse_override=None):
        for label, sparse, tail in self.cases:
            with self.subTest(step=label):
                fx = Reused()
                self.addCleanup(fx.close)
                prepare(fx)
                sparse_value = sparse if sparse_override is None else sparse_override
                result = fx.run(tail, sparse_value)
                yield label, fx, result, sparse_value

    def test_no_patterns_on_a_plain_reused_git_checks_out_the_whole_tree(self) -> None:
        for _label, fx, result, _ in self.each(lambda fx: None, sparse_override=""):
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(fx.files(), {"a/x", "b/y", "c/z"})

    def test_no_patterns_on_a_git_another_job_left_sparse_checks_out_the_whole_tree(self) -> None:
        for _label, fx, result, _ in self.each(lambda fx: git(fx.ws, "sparse-checkout", "set", "--no-cone", "/a/"),
                                               sparse_override=""):
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(fx.files(), {"a/x", "b/y", "c/z"})
            self.assertNotEqual(git(fx.ws, "config", "--bool", "--default", "false", "core.sparseCheckout").strip(),
                                "true")

    def test_own_patterns_on_a_reused_git_apply_them(self) -> None:
        for _label, fx, result, _ in self.each(lambda fx: None, sparse_override="/*\n!/b/"):
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(fx.files(), {"a/x", "c/z"})


if __name__ == "__main__":
    unittest.main()
