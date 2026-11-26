#!/usr/bin/env python3
"""The iPhone INTERNAL archive reads its commit from the host's git mirror and keeps its Swift packages.

From 2026-11-25 21:47Z no INTERNAL build published. Five runs (45717448413, 45733165601, 45746081559,
45752138226, 45760129544) failed in "Archive": a fleet Mac's SwiftPM clones of github.com/apple/swift-asn1
and swift-crypto got 403 ("Could not resolve package dependencies"), because the archive kept its package
clones under the job's temp and cloned them again on every build. Two runs (45773843030, 45808800614)
failed in "Checkout the commit": actions/checkout's github.com fetch stalled (curl 92, early EOF) until its
20 min bound.

.github/workflows/ios-internal-nightly.yml now
- checks the commit out of the host's verified git mirror (the same borrow as nightly.yml's warm checkout:
  alternates plus glaeda-mirror-borrow.json) and runs actions/checkout only when the mirror has no copy,
  with git's low-speed abort so a stalled transfer is retried instead of holding the step;
- points a fleet Mac's package clones at a directory under its home (CMUX_MOBILE_SPM_CACHE), and
  cmux-next-ios/scripts/testflight-build.sh resolves from kept clones (-skipPackageUpdates) before any
  network resolve, with the same low-speed abort.

This runs the mirror step's own `run:` text against a temp mirror and an empty workspace whose origin is
unreachable, so a passing run proves the commit came from the mirror. git only, no network, no Mac:
python3 tests/test_ios_internal_archive_mirror_fetch.py
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml
# tests/git_fixture_env.py, loaded by path: `python3 -I` puts no script folder on sys.path.
import importlib.util as _git_fixture_importlib  # noqa: E402
from os import path as _git_fixture_path  # noqa: E402
_git_fixture_spec = _git_fixture_importlib.spec_from_file_location(
    "git_fixture_env", _git_fixture_path.join(_git_fixture_path.dirname(_git_fixture_path.abspath(__file__)), "git_fixture_env.py"))
git_fixture_env = _git_fixture_importlib.module_from_spec(_git_fixture_spec)
_git_fixture_spec.loader.exec_module(git_fixture_env)

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/ios-internal-nightly.yml"
BUILD_SCRIPT = ROOT / "cmux-next-ios/scripts/testflight-build.sh"
ARCHIVE = yaml.safe_load(WORKFLOW.read_text())["jobs"]["archive"]
MIRROR_STEP = "Checkout the commit from the host's git mirror"
GITHUB_STEP = "Checkout the commit"


def step(name: str) -> dict:
    return next(s for s in ARCHIVE["steps"] if s.get("name") == name)


class ArchiveCheckoutFromMirrorTest(unittest.TestCase):
    def setUp(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.temp = Path(temp.name)
        for folder in ("home", "runner-temp"):
            (self.temp / folder).mkdir()
        self.env = git_fixture_env.fixture_env({
            "PATH": os.environ["PATH"], "HOME": str(self.temp / "home"),
            "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0",
            "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t",
        })
        self.origin = self.temp / "origin"
        git_fixture_env.init_repo(self.origin, "-b", "main", env=self.env)
        self.commit({"README": "one\n"}, "first")
        self.sha = self.commit({"README": "two\n", "cmux-next-ios/project.yml": "name: x\n"}, "the build")
        self.fleet_git = self.temp / "fleet/git"
        self.fleet_git.mkdir(parents=True)
        self.mirror = self.fleet_git / "cmux.git"
        git_fixture_env.clone_repo(self.origin, self.mirror, "--mirror", env=self.env)
        (self.mirror / "glaeda-verified").write_text("ok\n")
        # A reused workspace with a stray file from an earlier job.
        self.ws = self.temp / "actions-runner-1/_work/cmux/cmux"
        self.ws.mkdir(parents=True)
        (self.ws / "stale.txt").write_text("old\n")

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
            "SHA": sha or self.sha, "GITHUB_WORKSPACE": str(self.ws), "RUNNER_TEMP": str(self.temp / "runner-temp"),
            "GITHUB_OUTPUT": str(output), "GLAEDA_GIT_MIRROR_DIR": str(self.fleet_git),
            "GLAEDA_GIT_MIRROR_TOOL": str(self.temp / "no-mirror-tool"),
            # Unreachable: a checkout that went to GitHub fails instead of passing.
            "REPO_URL": "https://127.0.0.1:9/manaflow-ai/cmux",
        })
        result = subprocess.run(["bash", str(script)], cwd=self.temp, env=env, capture_output=True, text=True,
                                timeout=120)
        outputs: dict[str, str] = {}
        for line in output.read_text().splitlines():
            key, _, value = line.partition("=")
            outputs[key] = value
        return result, outputs

    def test_commit_checks_out_from_the_mirror_with_no_github_fetch(self) -> None:
        result, outputs = self.run_step()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(outputs.get("source"), "mirror", result.stdout + result.stderr)
        self.assertEqual(self.git(self.ws, "rev-parse", "HEAD"), self.sha)
        self.assertEqual((self.ws / "README").read_text(), "two\n")
        self.assertFalse((self.ws / "stale.txt").exists(), "a reused workspace keeps no stray file")
        alternates = (self.ws / ".git/objects/info/alternates").read_text().splitlines()
        self.assertIn(str(self.mirror / "objects"), alternates)
        record = json.loads((self.ws / ".git/glaeda-mirror-borrow.json").read_text())
        self.assertEqual(record["objects"], str(self.mirror / "objects"))
        self.assertEqual(record["ino"], os.stat(self.mirror / "objects").st_ino)
        # A second build on the same workspace borrows once.
        newer = self.commit({"README": "three\n"}, "next build")
        self.git(self.mirror, "fetch", "-q", str(self.origin), "+refs/heads/*:refs/heads/*")
        result, outputs = self.run_step(newer)
        self.assertEqual(outputs.get("source"), "mirror", result.stdout + result.stderr)
        self.assertEqual(self.git(self.ws, "rev-parse", "HEAD"), newer)
        alternates = (self.ws / ".git/objects/info/alternates").read_text().splitlines()
        self.assertEqual(alternates.count(str(self.mirror / "objects")), 1)

    def test_unverified_or_repairing_mirror_leaves_it_to_github(self) -> None:
        (self.mirror / "glaeda-verified").unlink()
        result, outputs = self.run_step()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(outputs.get("source"), "github")
        (self.mirror / "glaeda-verified").write_text("ok\n")
        (self.mirror / "glaeda-repair-pending").write_text("")
        result, outputs = self.run_step()
        self.assertEqual(outputs.get("source"), "github")
        self.assertFalse((self.ws / ".git").exists(), "no mirror: the workspace is left to actions/checkout")

    def test_commit_the_mirror_lacks_goes_to_github(self) -> None:
        result, outputs = self.run_step("0" * 40)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(outputs.get("source"), "github")

    def test_github_checkout_runs_only_without_the_mirror_and_aborts_a_stall(self) -> None:
        mirror = step(MIRROR_STEP)
        self.assertTrue(mirror.get("continue-on-error"))
        self.assertLessEqual(mirror["timeout-minutes"], 10)
        names = [s.get("name") for s in ARCHIVE["steps"]]
        self.assertLess(names.index(MIRROR_STEP), names.index(GITHUB_STEP))
        github = step(GITHUB_STEP)
        self.assertEqual(github["if"], "steps.mirror-checkout.outputs.source != 'mirror'")
        self.assertEqual(github["with"]["fetch-depth"], 1)
        env = github["env"]
        pairs = {env[f"GIT_CONFIG_KEY_{i}"]: env[f"GIT_CONFIG_VALUE_{i}"] for i in range(int(env["GIT_CONFIG_COUNT"]))}
        self.assertEqual(pairs, {"http.lowSpeedLimit": "1024", "http.lowSpeedTime": "60"})


class ArchiveKeepsSwiftPackagesTest(unittest.TestCase):
    def test_fleet_mac_keeps_package_clones_outside_the_job_temp(self) -> None:
        run = step("Archive")["run"]
        match = re.search(r'export CMUX_MOBILE_SPM_CACHE="([^"]+)"', run)
        self.assertIsNotNone(match, "the archive names a kept Swift package directory")
        self.assertNotIn("RUNNER_TEMP", match.group(1))
        self.assertTrue(match.group(1).startswith("$HOME/"))

    def test_build_script_resolves_from_kept_clones_before_the_network(self) -> None:
        text = BUILD_SCRIPT.read_text()
        self.assertIn('spm_cache=${CMUX_MOBILE_SPM_CACHE:-$cache/spm}', text)
        self.assertNotIn('-clonedSourcePackagesDirPath "$cache/spm"', text)
        self.assertEqual(text.count('-clonedSourcePackagesDirPath "$spm_cache"'), 4)
        kept = text.index('-skipPackageUpdates > "$out/logs/resolve.log"')
        network = text.index('for i in "${!resolve_waits[@]}"')
        self.assertLess(kept, network, "kept clones are read before any network resolve")
        self.assertLess(text.index("GIT_CONFIG_KEY_0=http.lowSpeedLimit"), kept)
        self.assertIn("early EOF", text[network:text.index("-disableAutomaticPackageResolution")])


if __name__ == "__main__":
    unittest.main()
