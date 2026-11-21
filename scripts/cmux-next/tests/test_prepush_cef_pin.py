#!/usr/bin/env python3
"""prepush-gate.py cef_pin_problems: a push that changes scripts/cmux-next/cef-manifest.json is refused when an
artifact's r2_key does not contain its sha256 (or ends in another asset), or its url names another asset.

2026-11-20: a dogfood pin moved sha256 to a staging dist (c8464a08...) but kept cmux.52's url and r2_key
(cef/ea0124be.../...). Only the fleet controller store held those bytes; the Linux pool's fetch-pinned failed with a
checksum mismatch (job a217815294ce09cd160f2169).

  python3 scripts/cmux-next/tests/test_prepush_cef_pin.py
"""
from __future__ import annotations

import copy
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

# tests/git_fixture_env.py turns off git's background maintenance in temp repos.
_git_fixture_env = importlib.util.spec_from_file_location(
    "git_fixture_env",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "tests", "git_fixture_env.py"),
)
git_fixture_env = importlib.util.module_from_spec(_git_fixture_env)
_git_fixture_env.loader.exec_module(git_fixture_env)

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("prepush_gate", HERE.parent / "prepush-gate.py")
assert SPEC and SPEC.loader
gate = importlib.util.module_from_spec(SPEC)
sys.modules["prepush_gate"] = gate
SPEC.loader.exec_module(gate)

MANIFEST = "scripts/cmux-next/cef-manifest.json"
CURRENT = json.loads((HERE.parent / "cef-manifest.json").read_text())
STAGING_SHA = "c8464a08" + "5" * 56
OLD_SHA = "ea0124be" + "7" * 56
OLD = "cef-157.0.0-cmux.52-macos-arm64.tar.xz"


def half_updated_pin() -> dict:
    """The 2026-11-20 shape: sha256 and asset name the staging dist; url and r2_key still name cmux.52."""
    bad = copy.deepcopy(CURRENT)
    bad["asset"] = "cef-157.0.0-cmux.53-staging-macos-arm64.tar.xz"
    bad["sha256"] = STAGING_SHA
    bad["url"] = f"https://github.com/manaflow-ai/cef/releases/download/cef-157.0.0-cmux.52/{OLD}"
    bad["r2_key"] = f"cef/{OLD_SHA}/{OLD}"
    return bad


def git(repo: Path, *args: str) -> str:
    return subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", *args],
                          cwd=repo, check=True, capture_output=True, text=True).stdout.strip()


class CefPinTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.repo = Path(self.tmp.name) / "r"
        (self.repo / "scripts" / "cmux-next").mkdir(parents=True)
        git(self.repo, "init", "-q")
        (self.repo / "README").write_text("base\n")
        self.base = self.commit(MANIFEST, dict(CURRENT, version="base"))

    def commit(self, path: str, content) -> str:
        text = content if isinstance(content, str) else json.dumps(content, indent=2) + "\n"
        (self.repo / path).write_text(text)
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-qm", f"change {path}")
        return git(self.repo, "rev-parse", "HEAD")

    def test_the_half_updated_staging_pin_is_refused(self):
        head = self.commit(MANIFEST, half_updated_pin())
        found = gate.cef_pin_problems(self.repo, self.base, head)
        text = "\n".join(found)
        self.assertIn(f"r2_key cef/{OLD_SHA}/{OLD} does not contain sha256 {STAGING_SHA}", text)
        self.assertIn(f"r2_key cef/{OLD_SHA}/{OLD} names another asset", text)
        self.assertIn(f"names {OLD}, not asset cef-157.0.0-cmux.53-staging", text)
        self.assertIn("publish-cef-r2.sh", found[-1])
        self.assertFalse(any("x86_64." in line for line in found), found)
        reserved = gate.gate(self.repo, self.base, head, {"cef-pin"}, False)
        self.assertEqual([check for check, _ in reserved], [gate.CEF_PIN_CHECK])

    def test_a_stale_x86_64_r2_key_is_refused(self):
        bad = copy.deepcopy(CURRENT)
        bad["x86_64"]["r2_key"] = f"cef/{OLD_SHA}/{bad['x86_64']['asset']}"
        found = gate.cef_pin_problems(self.repo, self.base, self.commit(MANIFEST, bad))
        self.assertTrue(any(line.startswith(f"{MANIFEST}: x86_64.r2_key") for line in found), found)

    def test_a_stale_debug_r2_key_is_refused(self):
        bad = copy.deepcopy(CURRENT)
        bad["debug_r2_key"] = f"cef/{OLD_SHA}/{bad['debug_asset']}"
        found = gate.cef_pin_problems(self.repo, self.base, self.commit(MANIFEST, bad))
        self.assertTrue(any("debug_r2_key" in line and "debug_sha256" in line for line in found), found)

    def test_the_current_feat_cmux_next_manifest_passes(self):
        bad_base = self.commit(MANIFEST, half_updated_pin())
        head = self.commit(MANIFEST, CURRENT)
        self.assertEqual(gate.cef_pin_problems(self.repo, bad_base, head), [])
        self.assertEqual(gate.gate(self.repo, bad_base, head, {"cef-pin"}, False), [])

    def test_a_push_that_does_not_change_the_manifest_is_not_judged(self):
        bad_base = self.commit(MANIFEST, half_updated_pin())
        head = self.commit("README", "other\n")
        self.assertEqual(gate.cef_pin_problems(self.repo, bad_base, head), [])


if __name__ == "__main__":
    unittest.main()
