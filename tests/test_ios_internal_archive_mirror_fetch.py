#!/usr/bin/env python3
"""Check the iOS INTERNAL archive's verified mirror and persistent Swift package cache."""
from __future__ import annotations

import importlib.util
import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

_git_fixture_spec = importlib.util.spec_from_file_location(
    "git_fixture_env", Path(__file__).with_name("git_fixture_env.py")
)
git_fixture_env = importlib.util.module_from_spec(_git_fixture_spec)
_git_fixture_spec.loader.exec_module(git_fixture_env)

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/ios-internal-nightly.yml"
BUILD_SCRIPT = ROOT / "cmux-next-ios/scripts/testflight-build.sh"
ARCHIVE = yaml.safe_load(WORKFLOW.read_text())["jobs"]["archive"]
MIRROR_STEP = "Checkout from the verified fleet mirror"
GITHUB_STEP = "Checkout the commit"


def step(name: str) -> dict:
    return next(s for s in ARCHIVE["steps"] if s.get("name") == name)


class ArchiveCheckoutFromMirrorTest(unittest.TestCase):
    def setUp(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.temp = Path(temp.name)
        (self.temp / "home").mkdir()
        (self.temp / "runner-temp").mkdir()
        self.env = git_fixture_env.fixture_env({
            "PATH": os.environ["PATH"], "HOME": str(self.temp / "home"),
            "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0",
            "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
            "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t",
        })
        self.origin = self.temp / "origin"
        git_fixture_env.init_repo(self.origin, "-b", "main", env=self.env)
        self.commit({"README": "one\n", "cmux-next-ios/project.yml": "name: x\n"}, "first")
        self.sha = self.commit({"README": "two\n"}, "the build")
        self.fleet_git = self.temp / "fleet/git"
        self.fleet_git.mkdir(parents=True)
        self.mirror = self.fleet_git / "cmux.git"
        git_fixture_env.clone_repo(self.origin, self.mirror, "--mirror", env=self.env)
        (self.mirror / "glaeda-verified").write_text("ok\n")

    def git(self, cwd: Path, *args: str) -> str:
        result = subprocess.run(["git", *args], cwd=cwd, env=self.env, capture_output=True, text=True)
        if result.returncode != 0:
            self.fail(f"git {' '.join(args)}: exit {result.returncode}\n{result.stderr}")
        return result.stdout.strip()

    def commit(self, tree: dict[str, str], message: str) -> str:
        for name, text in tree.items():
            path = self.origin / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        self.git(self.origin, "add", "-A")
        self.git(self.origin, "commit", "-qm", message)
        return self.git(self.origin, "rev-parse", "HEAD")

    def run_step(self, sha: str | None = None) -> tuple[subprocess.CompletedProcess, dict[str, str]]:
        script = self.temp / "runner-temp/mirror-checkout.sh"
        script.write_text(step(MIRROR_STEP)["run"])
        output = self.temp / "runner-temp/output"
        output.write_text("")
        env = dict(self.env)
        env.update({
            "SHA": sha or self.sha, "GITHUB_WORKSPACE": str(self.temp / "workspace"),
            "RUNNER_TEMP": str(self.temp / "runner-temp"), "GITHUB_OUTPUT": str(output),
            "GLAEDA_GIT_MIRROR_DIR": str(self.fleet_git), "ARCHIVE_PATHS": "/*\n",
            "REPO_URL": "https://127.0.0.1:9/manaflow-ai/cmux",
        })
        result = subprocess.run(["bash", str(script)], cwd=self.temp, env=env, capture_output=True, text=True, timeout=120)
        outputs: dict[str, str] = {}
        for line in output.read_text().splitlines():
            key, _, value = line.partition("=")
            outputs[key] = value
        return result, outputs

    def test_commit_checks_out_from_verified_mirror(self) -> None:
        result, outputs = self.run_step()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        directory = Path(outputs["directory"])
        self.assertEqual(self.git(directory, "rev-parse", "HEAD"), self.sha)
        self.assertEqual((directory / "README").read_text(), "two\n")
        self.assertEqual(self.git(directory, "remote", "get-url", "origin"), "https://127.0.0.1:9/manaflow-ai/cmux")

        newer = self.commit({"README": "three\n"}, "next build")
        self.git(self.mirror, "fetch", "-q", str(self.origin), "+refs/heads/*:refs/heads/*")
        result, outputs = self.run_step(newer)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.git(Path(outputs["directory"]), "rev-parse", "HEAD"), newer)

    def test_unverified_or_missing_mirror_falls_back(self) -> None:
        (self.mirror / "glaeda-verified").unlink()
        result, outputs = self.run_step()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("directory", outputs)
        (self.mirror / "glaeda-verified").write_text("ok\n")
        (self.mirror / "glaeda-repair-pending").write_text("")
        result, outputs = self.run_step()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("directory", outputs)

    def test_checkout_fallback_is_bounded(self) -> None:
        mirror = step(MIRROR_STEP)
        self.assertTrue(mirror.get("continue-on-error"))
        self.assertLessEqual(mirror["timeout-minutes"], 10)
        names = [s.get("name") for s in ARCHIVE["steps"]]
        self.assertLess(names.index(MIRROR_STEP), names.index(GITHUB_STEP))
        github = step(GITHUB_STEP)
        self.assertEqual(github["if"], "steps.kept.outputs.directory == ''")
        self.assertIn("--depth=1 --filter=blob:none", github["run"])
        self.assertIn("http.lowSpeedLimit=1024", github["run"])
        self.assertIn("http.lowSpeedTime=45", github["run"])


class ArchiveKeepsSwiftPackagesTest(unittest.TestCase):
    def test_fallback_keeps_package_clones_under_home(self) -> None:
        run = step("Archive")["run"]
        match = re.search(r'export CMUX_MOBILE_SPM_CACHE="([^"]+)"', run)
        self.assertIsNotNone(match, "the archive names a kept Swift package directory")
        self.assertNotIn("RUNNER_TEMP", match.group(1))
        self.assertTrue(match.group(1).startswith("$HOME/"))

    def test_build_script_resolves_from_kept_clones_before_network(self) -> None:
        text = BUILD_SCRIPT.read_text()
        self.assertIn("spm_cache=${CMUX_MOBILE_SPM_CACHE:-$cache/spm}", text)
        self.assertNotIn('-clonedSourcePackagesDirPath "$cache/spm"', text)
        self.assertEqual(text.count('-clonedSourcePackagesDirPath "$spm_cache"'), 4)
        kept = text.index('-skipPackageUpdates > "$out/logs/resolve.log"')
        network = text.index('for i in "${!resolve_waits[@]}"')
        self.assertLess(kept, network)
        self.assertLess(text.index("GIT_CONFIG_KEY_0=http.lowSpeedLimit"), kept)
        self.assertIn("early EOF", text[network:text.index("-disableAutomaticPackageResolution")])


if __name__ == "__main__":
    unittest.main()
