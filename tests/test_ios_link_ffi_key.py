#!/usr/bin/env python3
"""scripts/ci/ios_link_ffi_key.py keys CmuxMobileLinkFFI.xcframework by what its build reads, and the kit job
reuses a cached xcframework only under that key: a change to a compiled crate, the lock, the toolchain, the build
script or the bindings rebuilds; a dev-dependency or another workspace member does not."""
from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/ios_link_ffi_key.py"
WORKFLOW = ROOT / ".github/workflows/cmux-next-ios-kit.yml"

FILES = {
    "cmux-tui/rust-toolchain.toml": '[toolchain]\nchannel = "1.90.0"\n',
    "cmux-tui/Cargo.toml": '[workspace]\nmembers = ["crates/*"]\n'
                           '[workspace.dependencies]\ncore = { path = "crates/core" }\n',
    "cmux-tui/crates/core/Cargo.toml": '[package]\nname = "core"\n[dependencies]\nleaf = { path = "../leaf" }\n'
                                       '[dev-dependencies]\ntesty = { path = "../testy" }\n',
    "cmux-tui/crates/core/src/lib.rs": "pub fn core() {}\n",
    "cmux-tui/crates/leaf/Cargo.toml": '[package]\nname = "leaf"\n',
    "cmux-tui/crates/leaf/src/lib.rs": "pub fn leaf() {}\n",
    "cmux-tui/crates/testy/Cargo.toml": '[package]\nname = "testy"\n',
    "cmux-tui/crates/testy/src/lib.rs": "pub fn testy() {}\n",
    "cmux-tui/crates/other/Cargo.toml": '[package]\nname = "other"\n',
    "cmux-tui/crates/other/src/lib.rs": "pub fn other() {}\n",
    "cmux-next-ios/rust/Cargo.toml": '[workspace]\nmembers = ["crates/*"]\n',
    "cmux-next-ios/rust/Cargo.lock": "# lock\n",
    "cmux-next-ios/rust/scripts/build-xcframework.sh": "#!/bin/sh\n",
    "cmux-next-ios/rust/crates/cmux-mobile-link-ffi/Cargo.toml":
        '[package]\nname = "cmux-mobile-link-ffi"\n'
        '[dependencies]\ncore = { path = "../../../../cmux-tui/crates/core" }\n',
    "cmux-next-ios/rust/crates/cmux-mobile-link-ffi/src/lib.rs": "pub fn ffi() {}\n",
    "cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileLinkFFI/CmuxMobileLinkFFI.swift": "// bindings\n",
}


def run_key(repo: Path, *extra: str) -> str:
    return subprocess.run([sys.executable, str(SCRIPT), *extra], cwd=repo, check=True, capture_output=True,
                          text=True).stdout


@unittest.skipIf(sys.version_info < (3, 11), "the key script reads Cargo.toml with tomllib (3.11+)")
class KeyTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self.tmp.name)
        env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t",
               "GIT_COMMITTER_EMAIL": "t@t"}
        self.env = env
        self.git("init", "-q")
        for path, text in FILES.items():
            target = self.repo / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(text)
        self.commit()

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def git(self, *args: str) -> None:
        subprocess.run(["git", *args], cwd=self.repo, env=self.env, check=True, capture_output=True)

    def commit(self) -> None:
        self.git("add", "-A")
        self.git("commit", "-qm", "x")

    def key_after(self, path: str) -> str:
        before = run_key(self.repo).strip()
        target = self.repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text((target.read_text() if target.exists() else "") + "// changed\n")
        self.commit()
        after = run_key(self.repo).strip()
        self.assertRegex(after, r"^[0-9a-f]{32}$")
        return "same" if before == after else "changed"

    def test_lists_the_closure_and_nothing_else(self) -> None:
        listed = {line.split(" ", 1)[1] for line in run_key(self.repo, "--list").splitlines()[:-1]}
        self.assertEqual(listed, {
            "cmux-next-ios/rust/crates/cmux-mobile-link-ffi", "cmux-tui/crates/core", "cmux-tui/crates/leaf",
            "cmux-next-ios/rust/Cargo.toml", "cmux-next-ios/rust/Cargo.lock", "cmux-tui/Cargo.toml",
            "cmux-tui/rust-toolchain.toml", "cmux-next-ios/rust/scripts/build-xcframework.sh",
            "cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileLinkFFI/CmuxMobileLinkFFI.swift",
        })

    def test_a_built_input_changes_the_key(self) -> None:
        for path in ("cmux-tui/crates/leaf/src/lib.rs", "cmux-next-ios/rust/crates/cmux-mobile-link-ffi/src/lib.rs",
                     "cmux-next-ios/rust/Cargo.lock", "cmux-next-ios/rust/.cargo/config.toml",
                     "cmux-tui/rust-toolchain.toml", "cmux-next-ios/rust/scripts/build-xcframework.sh",
                     "cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileLinkFFI/CmuxMobileLinkFFI.swift"):
            with self.subTest(path=path):
                self.assertEqual(self.key_after(path), "changed")

    def test_what_the_build_does_not_compile_keeps_the_key(self) -> None:
        for path in ("cmux-tui/crates/testy/src/lib.rs", "cmux-tui/crates/other/src/lib.rs", "README.md",
                     "cmux-next-ios/CmuxMobileKit/Sources/Other.swift"):
            with self.subTest(path=path):
                self.assertEqual(self.key_after(path), "same")

    def test_the_working_tree_does_not_move_the_key(self) -> None:
        before = run_key(self.repo)
        (self.repo / "cmux-tui/crates/leaf/src/lib.rs").write_text("// uncommitted\n")
        self.assertEqual(run_key(self.repo), before)


class WorkflowTests(unittest.TestCase):
    def test_a_hit_skips_the_build_and_only_a_checked_build_saves(self) -> None:
        steps = yaml.safe_load(WORKFLOW.read_text())["jobs"]["kit-tests"]["steps"]
        names = [step.get("name", "") for step in steps]
        order = [names.index(name) for name in (
            "CmuxMobileLinkFFI.xcframework key", "Restore CmuxMobileLinkFFI.xcframework",
            "Build CmuxMobileLinkFFI.xcframework", "Checked-in bindings match the generated ones",
            "Save CmuxMobileLinkFFI.xcframework")]
        self.assertEqual(order, sorted(order))
        by_name = dict(zip(names, steps))
        self.assertIn("python3 scripts/ci/ios_link_ffi_key.py", by_name["CmuxMobileLinkFFI.xcframework key"]["run"])
        self.assertIn("xcodebuild -version", by_name["CmuxMobileLinkFFI.xcframework key"]["run"])
        self.assertIn("steps.xcf-restore.outputs.cache-hit != 'true'",
                      by_name["Build CmuxMobileLinkFFI.xcframework"]["if"])
        self.assertIn("success()", by_name["Save CmuxMobileLinkFFI.xcframework"]["if"])
        for name in ("Restore CmuxMobileLinkFFI.xcframework", "Save CmuxMobileLinkFFI.xcframework"):
            self.assertEqual(by_name[name]["with"]["key"], "${{ steps.xcf-key.outputs.key }}")


if __name__ == "__main__":
    unittest.main()
