#!/usr/bin/env python3
"""A checkout seeded from main's objects must end exactly where a cold one does."""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "ci" / "git-seed.sh"
WORKFLOWS = ROOT / ".github" / "workflows"


def git(*args: str, cwd: Path | None = None, env: dict | None = None) -> str:
    return subprocess.run(
        ["git", "-c", "protocol.file.allow=always", *args], cwd=cwd, env=env,
        check=True, capture_output=True, text=True,
    ).stdout.strip()


def commit(repo: Path, name: str, text: str) -> str:
    (repo / name).write_text(text)
    git("add", "-A", cwd=repo)
    git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", name, cwd=repo)
    return git("rev-parse", "HEAD", cwd=repo)


class GitSeedTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.base = Path(os.path.realpath(self._tmp.name))
        # Upstream repositories at <server>/<owner>/<name>, as GitHub lays them out.
        self.server = self.base / "server"
        self.module = self.server / "acme" / "module"
        self.super = self.server / "acme" / "super"
        for repo in (self.module, self.super):
            repo.mkdir(parents=True)
            git("init", "-q", "-b", "main", cwd=repo)
            git("config", "uploadpack.allowAnySHA1InWant", "true", cwd=repo)
        self.module_v1 = commit(self.module, "m.txt", "module v1")
        git("submodule", "add", "-q", f"file://{self.module}", "vendor/module", cwd=self.super)
        self.main = commit(self.super, "app.txt", "main")
        self.env = dict(
            os.environ,
            GITHUB_SERVER_URL=f"file://{self.server}",
            GITHUB_REPOSITORY="acme/super",
            GIT_CONFIG_COUNT="1", GIT_CONFIG_KEY_0="protocol.file.allow", GIT_CONFIG_VALUE_0="always",
        )

    def seed_from_main(self) -> Path:
        """What the main-branch seeder checks out and stages."""
        seeder = self.base / "seeder"
        git("clone", "-q", "--depth=1", "--recurse-submodules", "--shallow-submodules",
            f"file://{self.super}", str(seeder), env=self.env)
        stage = self.base / "stage" / "seed"
        self.run_seed("stage", seeder, stage)
        return stage

    def run_seed(self, mode: str, workspace: Path, *extra: Path, check: bool = True):
        result = subprocess.run(
            ["bash", str(SCRIPT), mode, str(workspace), *map(str, extra)],
            env=self.env, capture_output=True, text=True,
        )
        if check:
            self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def checkout(self, workspace: Path, sha: str) -> None:
        """The git commands actions/checkout runs against an existing repository."""
        self.assertEqual(git("rev-parse", "--symbolic-full-name", "--verify", "--quiet", "HEAD", cwd=workspace), "HEAD")
        self.assertEqual(git("config", "remote.origin.url", cwd=workspace), f"file://{self.server}/acme/super")
        git("clean", "-ffdx", cwd=workspace)
        git("reset", "--hard", "HEAD", cwd=workspace)
        git("fetch", "--no-tags", "--prune", "--no-recurse-submodules", "--depth=1", "origin",
            f"+{sha}:refs/remotes/pull/1/merge", cwd=workspace, env=self.env)
        git("checkout", "--force", "refs/remotes/pull/1/merge", cwd=workspace)
        git("submodule", "sync", "--recursive", cwd=workspace)
        git("submodule", "update", "--init", "--force", "--depth=1", "--recursive", cwd=workspace, env=self.env)

    def test_the_seed_carries_objects_and_commit_ids_only(self):
        stage = self.seed_from_main()
        self.assertEqual((stage / "HEAD").read_text().strip(), self.main)
        self.assertEqual((stage / "modules" / "vendor/module" / "HEAD").read_text().strip(), self.module_v1)
        for path in stage.rglob("*"):
            relative = path.relative_to(stage).as_posix()
            self.assertTrue(
                re.fullmatch(r"(modules/vendor/module/)?(objects(/.*)?|shallow|HEAD)|modules(/vendor(/module)?)?", relative),
                relative,
            )

    def test_a_seeded_checkout_matches_the_tested_commit_and_its_submodule(self):
        stage = self.seed_from_main()
        # Main moves on after the seed: a new app file and a submodule bump.
        module_v2 = commit(self.module, "m.txt", "module v2")
        git("-C", "vendor/module", "fetch", "-q", "origin", cwd=self.super, env=self.env)
        git("-C", "vendor/module", "checkout", "-q", module_v2, cwd=self.super)
        tested = commit(self.super, "app.txt", "pull request")

        workspace = self.base / "ws"
        workspace.mkdir()
        self.run_seed("install", workspace, stage)
        self.checkout(workspace, tested)
        self.assertEqual(git("rev-parse", "HEAD", cwd=workspace), tested)
        self.assertEqual((workspace / "app.txt").read_text(), "pull request")
        self.assertEqual(git("rev-parse", "HEAD", cwd=workspace / "vendor/module"), module_v2)
        self.assertEqual((workspace / "vendor/module/m.txt").read_text(), "module v2")
        self.assertEqual(git("status", "--porcelain", cwd=workspace), "")

    def test_an_unchanged_submodule_checks_out_from_the_seed(self):
        stage = self.seed_from_main()
        tested = commit(self.super, "app.txt", "pull request")
        workspace = self.base / "ws"
        workspace.mkdir()
        self.run_seed("install", workspace, stage)
        # The module upstream disappears: only the seed can supply its commit.
        self.module.rename(self.base / "gone")
        self.checkout(workspace, tested)
        self.assertEqual((workspace / "vendor/module/m.txt").read_text(), "module v1")

    def test_restore_leaves_an_existing_repository_alone(self):
        workspace = self.base / "ws"
        workspace.mkdir()
        git("init", "-q", cwd=workspace)
        marker = workspace / ".git" / "marker"
        marker.write_text("keep")
        result = self.run_seed("restore", workspace)
        self.assertIn("already has a repository", result.stdout)
        self.assertEqual(marker.read_text(), "keep")

    def test_a_missing_seed_leaves_the_workspace_empty(self):
        workspace = self.base / "ws"
        workspace.mkdir()
        self.env["CI_CACHE_R2_PUBLIC_URL"] = f"file://{self.base}/no-bucket"
        result = self.run_seed("restore", workspace)
        self.assertIn("clones from scratch", result.stdout)
        self.assertEqual(list(workspace.iterdir()), [])

    @unittest.skipUnless(shutil.which("zstd"), "zstd is not installed")
    def test_a_seed_served_by_the_bucket_is_installed(self):
        stage = self.seed_from_main()
        bucket = self.base / "bucket" / "v1" / "macOS-ARM64"
        (bucket / "latest").mkdir(parents=True)
        (bucket / "objects").mkdir()
        key = f"git-seed-v1-{self.main}"
        (bucket / "latest" / "git-seed-v1-").write_text(key + "\n")
        subprocess.run(
            f"tar -cf - -C {stage} . | zstd -q -o {bucket / 'objects' / (key + '.tar.zst')}",
            shell=True, check=True,
        )
        self.env.update(CI_CACHE_R2_PUBLIC_URL=f"file://{self.base}/bucket", RUNNER_OS="macOS", RUNNER_ARCH="ARM64")
        workspace = self.base / "ws"
        workspace.mkdir()
        self.run_seed("restore", workspace)
        self.assertEqual(git("rev-parse", "HEAD", cwd=workspace), self.main)

    def test_a_corrupt_seed_installs_nothing(self):
        stage = self.seed_from_main()
        (stage / "HEAD").write_text("0" * 40 + "\n")
        workspace = self.base / "ws"
        workspace.mkdir()
        result = self.run_seed("install", workspace, stage, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list(workspace.iterdir()), [])


class WorkflowWiringTests(unittest.TestCase):
    def steps_before_checkout(self, text: str, job: str) -> list[str]:
        body = re.search(rf"^  {re.escape(job)}:\n(.*?)(?=^  [A-Za-z0-9_-]+:\n|\Z)", text, re.S | re.M)
        self.assertIsNotNone(body, job)
        before = body.group(1).split("uses: actions/checkout@", 1)[0]
        return re.findall(r"- name: (.+)", before)

    def test_macos_jobs_restore_the_seed_before_checkout(self):
        text = (WORKFLOWS / "ci-macos.yml").read_text()
        for job in ("macos-compile-admission", "app-host-unit-tests", "swift-package-tests", "tests-build-and-lag"):
            with self.subTest(job=job):
                self.assertIn("Restore git object seed", self.steps_before_checkout(text, job))
        text = (WORKFLOWS / "cli-pipe-regressions.yml").read_text()
        self.assertIn("Restore git object seed", self.steps_before_checkout(text, "cli-pipe-regressions"))

    def test_only_main_saves_the_seed(self):
        text = (WORKFLOWS / "seed-derived-data.yml").read_text()
        step = re.search(r"- name: Save git object seed\n(.*?)(?=\n      - name:|\Z)", text, re.S)
        self.assertIsNotNone(step)
        self.assertIn("if: github.ref == 'refs/heads/main'", step.group(1))
        self.assertIn("continue-on-error: true", step.group(1))
        self.assertIn('git-seed.sh save "$GITHUB_WORKSPACE"', step.group(1))


if __name__ == "__main__":
    unittest.main(verbosity=2)
