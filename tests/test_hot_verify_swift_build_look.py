"""A Swift-only change gets a look: the fleet builds the head's app, and the look records it for cmux/ui-proof.

2026-11-27: cmux#62345 and cmux#61438 (Swift into feat-cmux-next) could get no look. command_look returned
needs-build for every Swift plan, so no record was posted and cmux/ui-proof stayed pending on each Swift PR.

    python3 tests/test_hot_verify_swift_build_look.py
"""
from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("hot_verify_swift_look", ROOT / "scripts/cmux-next/hot-verify.py")
hv = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hv)

HEAD = "c" * 40


def plan(build: dict) -> dict:
    return {"needs_build": True, "build": build}


class CanBuild(unittest.TestCase):
    def test_swift_alone_builds(self):
        self.assertTrue(hv.can_build_swift_app(plan({"Swift": ["Sources/A.swift"]})))

    def test_a_strings_catalog_beside_swift_builds(self):
        self.assertTrue(hv.can_build_swift_app(plan({"Swift": ["Sources/A.swift"],
                                                     "strings": ["Resources/Localizable.xcstrings"]})))

    def test_bundled_resource_data_builds(self):
        # cmux#47278: only Resources/theme-files/*.json (Rust and web beside it) got no look and no proof record.
        themes = ["Resources/theme-files/sakura.json", "Resources/theme-files/sumi.json"]
        self.assertTrue(hv.can_build_swift_app(plan({"Swift, resources or manifests": themes})))
        self.assertTrue(hv.can_build_swift_app(plan({"Swift, resources or manifests": [
            "Packages/macOS/CmuxNext/Tests/T.swift", *themes, "Packages/X/Sources/X/Resources/icon.png"]})))
        for path in ("Resources/Info.plist", "Resources/cmux.entitlements", "Resources/bin/cmux",
                     "Resources/shell-integration.sh", "Resources/.DS_Store", "theme-files/sakura.json",
                     "Packages/App/Package.swift"):
            with self.subTest(path=path):
                self.assertFalse(hv.can_build_swift_app(plan({"Swift, resources or manifests": [path]})))

    def test_bundled_helper_rust_beside_swift_builds(self):
        # cmux#38466: Swift plus a new crate a bundled helper uses (Cargo.lock) got no look at all.
        self.assertTrue(hv.can_build_swift_app(plan({"Swift": ["Sources/A.swift"],
                                                     hv.HELPERS_REASON: ["cmux-tui/Cargo.lock"]})))
        self.assertFalse(hv.can_build_swift_app(plan({"Swift": ["Sources/A.swift"], hv.HELPERS_REASON: []})))

    def test_a_manifest_or_other_reason_does_not(self):
        self.assertFalse(hv.can_build_swift_app(plan({"Swift": ["Package.swift"]})))
        self.assertFalse(hv.can_build_swift_app(plan({"strings": ["Sources/A.swift"]})))
        self.assertFalse(hv.can_build_swift_app(plan({"Swift": ["A.swift"], "Rust FFI": ["x.h"]})))
        self.assertFalse(hv.can_build_swift_app({"needs_build": False, "build": {"Swift": ["A.swift"]}}))


class SwapCarries(unittest.TestCase):
    # 2026-11-28: a Swift PR's look on a fleet Mac (scripts/measure/ui-proof-look.sh) swaps the head's Swift into
    # NIGHTLY's copy (look --head-app): it carries Swift, manifests, resources and strings, and nothing a helper or the
    # FFI needs; the rust and web layers go in after it.
    def test_swift_manifests_and_strings_swap(self):
        self.assertTrue(hv.swap_carries(plan({"Swift": ["A.swift"], "Swift, resources or manifests": ["Package.swift"],
                                              "strings": ["L.xcstrings"]})))

    def test_helpers_ffi_or_no_build_do_not(self):
        self.assertFalse(hv.swap_carries(plan({"Swift": ["A.swift"], hv.HELPERS_REASON: ["cmux-tui/Cargo.lock"]})))
        self.assertFalse(hv.swap_carries(plan({"Swift": ["A.swift"], "Rust the app links (FFI)": ["x.rs"]})))
        self.assertFalse(hv.swap_carries({"needs_build": False, "build": {}}))


class RecordsABuiltLook(unittest.TestCase):
    def run_recorded(self, receipt: dict, code: int, no_post: bool = False):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d)
            (out / "receipt.json").write_text(json.dumps(receipt))
            args = SimpleNamespace(record=True, pr=1, out=d, repo_slug="manaflow-ai/cmux", repo=str(ROOT),
                                   no_post=no_post)
            ran = mock.Mock(return_value=SimpleNamespace(returncode=0, stdout="", stderr=""))
            fake_verdict = SimpleNamespace(build_record=lambda *a, **k: {"verdict": "pass"},
                                           summary=lambda r: "", rerun_gate=lambda *a: "gate rerun")
            with mock.patch.object(hv, "command_look", return_value=code), \
                    mock.patch.object(hv.subprocess, "run", ran), \
                    mock.patch.object(hv, "commit_time", return_value=None), \
                    mock.patch.dict("sys.modules", {"ui_proof_verdict": fake_verdict,
                                                    "proof_record": SimpleNamespace(render=lambda r, s: "x")}):
                self.assertEqual(hv.command_look_recorded(args), code)
            if no_post:
                self.assertEqual((out / "proof-record.md").read_text(), "x")
            return [c for c in ran.call_args_list if c.args and c.args[0][:3] == ["gh", "pr", "comment"]]

    def test_a_built_app_look_with_no_hot_layers_posts(self):
        posted = self.run_recorded({"plan": {"head": HEAD, "layers": []}, "errors": [],
                                    "applied": {"app": {"commit": HEAD}}}, hv.EXIT_LOOKED)
        self.assertEqual(len(posted), 1)

    def test_no_post_writes_the_record_and_posts_nothing(self):
        # A fleet step has no GitHub token: it writes proof-record.md and its caller posts it.
        posted = self.run_recorded({"plan": {"head": HEAD, "layers": ["rust"]}, "errors": [],
                                    "applied": {"app": {"commit": HEAD}}}, hv.EXIT_LOOKED, no_post=True)
        self.assertEqual(posted, [])

    def test_a_refused_build_posts_nothing(self):
        posted = self.run_recorded({"plan": {"head": HEAD, "layers": []}, "errors": ["needs a build"]},
                                   hv.EXIT_NEEDS_BUILD)
        self.assertEqual(posted, [])


class NightlyHistory(unittest.TestCase):
    """A fleet source has one commit and may have no origin; NIGHTLY names a short SHA."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)
        self.source = self.folder / "source"
        self.checkout = self.folder / "checkout"
        self.env = {**os.environ, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
                    "GIT_AUTHOR_NAME": "test", "GIT_COMMITTER_NAME": "test",
                    "GIT_AUTHOR_EMAIL": "test@example.invalid", "GIT_COMMITTER_EMAIL": "test@example.invalid"}
        self.git(self.folder, "init", "-q", "-b", "feat-cmux-next", str(self.source))
        self.common = self.commit("common")
        self.git(self.source, "checkout", "-qb", "lane/test")
        self.head = self.commit("head")
        self.git(self.source, "checkout", "-q", "feat-cmux-next")
        self.nightly = self.commit("nightly")
        self.commit("tip")
        self.git(self.folder, "clone", "-q", "--depth=1", "--branch", "feat-cmux-next",
                 self.source.as_uri(), str(self.checkout))

    def git(self, cwd, *args):
        return subprocess.run(["git", "-C", str(cwd), *args], env=self.env, check=True,
                              text=True, capture_output=True).stdout.strip()

    def commit(self, name):
        (self.source / name).write_text(name)
        self.git(self.source, "add", name)
        self.git(self.source, "-c", "core.hooksPath=/dev/null", "commit", "-qm", name)
        return self.git(self.source, "rev-parse", "HEAD")

    def prepare(self, commit, no_origin=False):
        if no_origin:
            self.git(self.checkout, "remote", "remove", "origin")
        # Redirect the production fallback URL to a real offline Git repository.
        env = {**self.env, "GIT_CONFIG_COUNT": "2",
               "GIT_CONFIG_KEY_0": "url." + self.source.as_uri() + ".insteadOf",
               "GIT_CONFIG_VALUE_0": "https://github.com/manaflow-ai/cmux.git",
               "GIT_CONFIG_KEY_1": "protocol.file.allow", "GIT_CONFIG_VALUE_1": "always"}
        script = (ROOT / "scripts/measure/ui-proof-look.sh").read_text()
        fragment = script.split("# The plan against NIGHTLY:", 1)[1].split('python3 "$hv" plan', 1)[0]
        fragment = fragment.split("\n", 1)[1]
        return subprocess.run(["bash", "-uc", fragment + '\ngit -C "$root" rev-parse "$commit^{commit}"',
                               "test"], env={**env, "root": str(self.checkout), "commit": commit,
                                             "head": self.head}, text=True, capture_output=True)

    def test_missing_short_nightly_with_origin(self):
        result = self.prepare(self.nightly[:7])
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual(result.stdout.strip(), self.nightly)
        self.assertEqual(self.git(self.checkout, "merge-base", self.nightly, self.head), self.common)

    def test_missing_short_nightly_without_origin(self):
        result = self.prepare(self.nightly[:7], no_origin=True)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual(result.stdout.strip(), self.nightly)
        self.assertEqual(self.git(self.checkout, "merge-base", self.nightly, self.head), self.common)

    def test_present_commits_still_need_ancestry_without_origin(self):
        self.git(self.checkout, "fetch", "-q", "--depth=1", "origin", self.nightly, self.head)
        result = self.prepare(self.nightly, no_origin=True)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual(self.git(self.checkout, "merge-base", self.nightly, self.head), self.common)

    def test_unknown_short_commit_fails_before_plan(self):
        result = self.prepare("0000000", no_origin=True)
        self.assertEqual(result.returncode, 3, result.stderr + result.stdout)


if __name__ == "__main__":
    unittest.main()
