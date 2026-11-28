"""A Swift-only change gets a look: the fleet builds the head's app, and the look records it for cmux/ui-proof.

2026-11-27: cmux#62345 and cmux#61438 (Swift into feat-cmux-next) could get no look. command_look returned
needs-build for every Swift plan, so no record was posted and cmux/ui-proof stayed pending on each Swift PR.

    python3 tests/test_hot_verify_swift_build_look.py
"""
from __future__ import annotations

import importlib.util
import json
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


class RecordsABuiltLook(unittest.TestCase):
    def run_recorded(self, receipt: dict, code: int):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d)
            (out / "receipt.json").write_text(json.dumps(receipt))
            args = SimpleNamespace(record=True, pr=1, out=d, repo_slug="manaflow-ai/cmux", repo=str(ROOT))
            ran = mock.Mock(return_value=SimpleNamespace(returncode=0, stdout="", stderr=""))
            fake_verdict = SimpleNamespace(build_record=lambda *a, **k: {"verdict": "pass"},
                                           summary=lambda r: "", rerun_gate=lambda *a: "gate rerun")
            with mock.patch.object(hv, "command_look", return_value=code), \
                    mock.patch.object(hv.subprocess, "run", ran), \
                    mock.patch.object(hv, "commit_time", return_value=None), \
                    mock.patch.dict("sys.modules", {"ui_proof_verdict": fake_verdict,
                                                    "proof_record": SimpleNamespace(render=lambda r, s: "x")}):
                self.assertEqual(hv.command_look_recorded(args), code)
            return [c for c in ran.call_args_list if c.args and c.args[0][:3] == ["gh", "pr", "comment"]]

    def test_a_built_app_look_with_no_hot_layers_posts(self):
        posted = self.run_recorded({"plan": {"head": HEAD, "layers": []}, "errors": [],
                                    "applied": {"app": {"commit": HEAD}}}, hv.EXIT_LOOKED)
        self.assertEqual(len(posted), 1)

    def test_a_refused_build_posts_nothing(self):
        posted = self.run_recorded({"plan": {"head": HEAD, "layers": []}, "errors": ["needs a build"]},
                                   hv.EXIT_NEEDS_BUILD)
        self.assertEqual(posted, [])


if __name__ == "__main__":
    unittest.main()
