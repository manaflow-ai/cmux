#!/usr/bin/env python3
"""CmuxMobileLinkFFI.xcframework is built once per set of inputs, not once per Mac job.

Every iOS review gate device leg built the same framework from scratch, about
3 minutes of a Mac each (run 43652999096: 3.4 min on iPhone, 2.9 on iPad),
while most app changes leave the Rust it is built from untouched. A job now
restores the framework built from the same inputs
(.github/scripts/ios_link_ffi_key.py) and builds only on a miss; a pull request
only reads the cache.

  python3 tests/test_ios_link_ffi_key.py
"""

from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / ".github/scripts"))
import ios_link_ffi_key  # noqa: E402

BUILD = "build-xcframework.sh"
KEY_PREFIX = "ios-link-ffi-xcframework-"
# cmux-next-ios-kit.yml checks the build script itself (that it runs and leaves
# the generated Swift unchanged), so it always builds.
ALWAYS_BUILDS = {"cmux-next-ios-kit.yml"}


def git(repo: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, text=True).stdout.strip()


def write(repo: Path, rel: str, text: str) -> None:
    path = repo / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def commit(repo: Path) -> str:
    git(repo, "add", "-A")
    git(repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "c", "--allow-empty")
    return git(repo, "rev-parse", "HEAD")


class KeyTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self.tmp.name)
        git(self.repo, "init", "-q")
        write(self.repo, "app/rust/Cargo.toml",
              '[workspace]\nmembers = ["ffi"]\n[patch.crates-io]\nnix = { path = "../../vendor/nix" }\n')
        write(self.repo, "app/rust/ffi/Cargo.toml",
              '[package]\nname = "ffi"\n[[bin]]\nname = "gen"\npath = "src/bin/gen.rs"\n'
              '[dependencies]\ncore = { path = "../../../core/crates/core" }\n')
        write(self.repo, "app/rust/ffi/src/lib.rs", "")
        write(self.repo, "core/Cargo.toml", '[workspace.package]\nedition = "2021"\n')
        write(self.repo, "core/crates/core/Cargo.toml",
              '[package]\nname = "core"\n[dependencies.wire]\npath = "../wire"\n')
        write(self.repo, "core/crates/core/src/lib.rs", "")
        write(self.repo, "core/crates/wire/Cargo.toml", '[package]\nname = "wire"\n')
        write(self.repo, "core/crates/wire/src/lib.rs", "")
        write(self.repo, "core/crates/unrelated/src/lib.rs", "")
        write(self.repo, "vendor/nix/Cargo.toml", '[package]\nname = "nix"\n')
        write(self.repo, "app/Sources/App.swift", "")
        self.base = commit(self.repo)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def key(self, rev: str, extra: list[str] | None = None) -> str:
        return ios_link_ffi_key.key(str(self.repo), rev, "app/rust", extra or [])[0]

    def changed(self, rel: str, text: str) -> str:
        write(self.repo, rel, text)
        return commit(self.repo)

    def test_the_same_inputs_give_the_same_key(self) -> None:
        self.assertEqual(self.key(self.base), self.key(commit(self.repo)))

    def test_a_crate_reached_through_another_crates_path_dependency_changes_the_key(self) -> None:
        self.assertNotEqual(self.key(self.base), self.key(self.changed("core/crates/wire/src/lib.rs", "fn f() {}")))

    def test_a_patched_crate_changes_the_key(self) -> None:
        self.assertNotEqual(self.key(self.base), self.key(self.changed("vendor/nix/src/lib.rs", "fn f() {}")))

    def test_the_workspace_manifest_above_a_path_crate_changes_the_key(self) -> None:
        self.assertNotEqual(self.key(self.base), self.key(self.changed("core/Cargo.toml", '[workspace.package]\nedition = "2024"\n')))

    def test_a_toolchain_file_above_a_crate_changes_the_key(self) -> None:
        self.assertNotEqual(self.key(self.base), self.key(self.changed("rust-toolchain.toml", '[toolchain]\nchannel = "1.0"\n')))

    def test_app_code_and_unreached_crates_keep_the_key(self) -> None:
        self.changed("app/Sources/App.swift", "let x = 1")
        rev = self.changed("core/crates/unrelated/src/lib.rs", "fn f() {}")
        self.assertEqual(self.key(self.base), self.key(rev))

    def test_the_xcode_build_is_part_of_the_key(self) -> None:
        self.assertNotEqual(self.key(self.base, ["xcode=17A"]), self.key(self.base, ["xcode=17B"]))

    def test_a_path_outside_the_repository_is_refused(self) -> None:
        rev = self.changed("app/rust/ffi/Cargo.toml", '[dependencies]\nx = { path = "../../../../outside" }\n')
        with self.assertRaises(SystemExit):
            self.key(rev)

    def test_the_real_workspace_reaches_the_cmux_tui_crates_it_links(self) -> None:
        rev = git(ROOT, "rev-parse", "HEAD")
        _, lines = ios_link_ffi_key.key(str(ROOT), rev, "cmux-next-ios/rust", [])
        trees = {line.split()[1] for line in lines if line.startswith("tree ")}
        self.assertIn("cmux-next-ios/rust", trees)
        self.assertIn("cmux-tui/crates/cmux-transport", trees)
        self.assertIn("cmux-tui/vendor/smoltcp", trees)
        self.assertIn("file cmux-tui/Cargo.toml", "\n".join(lines))


def run_text(step: dict) -> str:
    return str(step.get("run", ""))


class WorkflowTests(unittest.TestCase):
    """Every job that builds the framework restores it first, builds only on a
    miss, and saves only outside pull requests."""

    def builders(self) -> list[tuple[str, str, list[dict]]]:
        found = []
        for path in sorted((ROOT / ".github/workflows").glob("*.yml")):
            doc = yaml.safe_load(path.read_text(encoding="utf-8"))
            for name, job in (doc.get("jobs") or {}).items():
                steps = job.get("steps") or []
                if any(BUILD in run_text(s) for s in steps):
                    found.append((path.name, name, steps))
        return found

    def test_the_review_gate_legs_reuse_the_framework(self) -> None:
        jobs = {(w, j): steps for w, j, steps in self.builders()}
        self.assertIn(("ios-review-gate.yml", "reviewer-path"), jobs)
        saves = [s for s in jobs[("ios-review-gate.yml", "reviewer-path")]
                 if str(s.get("uses", "")).startswith("actions/cache/save@")
                 and str(s.get("with", {}).get("key", "")).startswith(KEY_PREFIX)]
        self.assertTrue(saves, "a feat-cmux-next push saves the framework its legs built")

    def test_every_builder_restores_by_the_input_key_and_builds_only_on_a_miss(self) -> None:
        for workflow, job, steps in self.builders():
            if workflow in ALWAYS_BUILDS:
                continue
            with self.subTest(workflow=workflow, job=job):
                build_at = next(i for i, s in enumerate(steps) if BUILD in run_text(s))
                key_steps = [i for i, s in enumerate(steps) if "ios_link_ffi_key.py" in run_text(s)]
                restores = [i for i, s in enumerate(steps)
                            if str(s.get("uses", "")).startswith("actions/cache/restore@")
                            and str(s.get("with", {}).get("key", "")).startswith(KEY_PREFIX)]
                self.assertTrue(key_steps and key_steps[0] < build_at, "the key is computed before the build")
                self.assertTrue(restores and restores[0] < build_at, "the framework is restored before the build")
                restore_id = steps[restores[0]].get("id")
                self.assertTrue(restore_id, "the restore step has an id the build reads")
                miss = f"steps.{restore_id}.outputs.cache-hit != 'true'"
                for step in steps[restores[0]:build_at + 1]:
                    if step.get("name") in ("Set up pinned Rust", "Cache cargo") or BUILD in run_text(step):
                        self.assertIn(miss, str(step.get("if", "")), f"'{step.get('name')}' runs only on a miss")

    def test_a_pull_request_never_saves_the_framework(self) -> None:
        for workflow, job, steps in self.builders():
            for step in steps:
                uses = str(step.get("uses", ""))
                if not (uses.startswith("actions/cache/save@") or uses.startswith("./.github/actions/cache-save")):
                    continue
                if not str(step.get("with", {}).get("key", "")).startswith(KEY_PREFIX):
                    continue
                with self.subTest(workflow=workflow, job=job):
                    self.assertIn("github.event_name != 'pull_request'", str(step.get("if", "")))
                    self.assertIs(step.get("continue-on-error"), True, "a lost save race never fails the job")


if __name__ == "__main__":
    unittest.main(verbosity=2)
