#!/usr/bin/env python3
"""hot-apply.py: a merged commit's Rust part swapped into an app's bin/cmux and rolled back.

Runs on any host (Linux included): no app, no fleet, no network. This checkout's history stands in
for feat-cmux-next (cmux#37155, a cmux-wg fix, after its parent); a file:// tree stands in for
files.cmux.com/cmux-tui/tree; the app is a folder with an Info.plist and a bin/cmux, and no daemon
runs from it, so the swap is the file alone.

    python3 -m unittest scripts/cmux-next/tests/test_hot_apply.py
"""
import hashlib
import json
import os
import plistlib
import platform
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "hot-apply.py"
ROOT = SCRIPT.parents[2]
FIX = "a186694568df6a1ad8b5a32d0f4466cb33c03d7f"  # cmux#37155: cmux-tui/crates/cmux-wg only


def run_git(*args):
    return subprocess.run(["git", "-C", str(ROOT), *args], capture_output=True, text=True)


def key_of(sha):
    return subprocess.run([sys.executable, str(ROOT / "scripts/ci/cmux_tui_tree_key.py"), "--version", "v2", sha],
                          cwd=ROOT, capture_output=True, text=True, check=True).stdout.strip()


@unittest.skipUnless(run_git("cat-file", "-e", f"{FIX}^{{commit}}").returncode == 0, "needs cmux#37155 in history")
class HotApplyRust(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="hot-apply-test-"))
        self.base = run_git("rev-parse", f"{FIX}^").stdout.strip()
        self.app = self.tmp / "cmux NIGHTLY.app"
        (self.app / "Contents/Resources/bin").mkdir(parents=True)
        with open(self.app / "Contents/Info.plist", "wb") as handle:
            plistlib.dump({"CMUXCommit": self.base}, handle)
        self.cmux = self.app / "Contents/Resources/bin/cmux"
        self.cmux.write_bytes(b"#!/bin/sh\necho old\n")
        self.cmux.chmod(0o755)
        (self.app / "Contents/Resources/bin/cmux-tui").symlink_to("cmux")
        self.old = hashlib.sha256(self.cmux.read_bytes()).hexdigest()
        self.key = key_of(FIX)
        arch = "aarch64" if platform.machine() in ("arm64", "aarch64") else "x86_64"
        self.name = f"cmux-tui-{arch}-apple-darwin" if sys.platform == "darwin" else f"cmux-tui-{arch}-unknown-linux-musl"
        self.new_body = b"#!/bin/sh\necho new\n"
        self.new = hashlib.sha256(self.new_body).hexdigest()
        self.publish(self.new_body, self.new)
        self.env = dict(os.environ, CMUX_HOT_APPLY_TUI_BASE=(self.tmp / "tree").as_uri(),
                        CMUX_HOT_APPLY_STATE_DIR=str(self.tmp / "state"))

    def tearDown(self):
        subprocess.run(["rm", "-rf", str(self.tmp)])

    def publish(self, body, digest, listed=None):
        tree = self.tmp / "tree" / self.key
        tree.mkdir(parents=True, exist_ok=True)
        (tree / self.name).write_bytes(body)
        (tree / f"{self.name}.sha256").write_text(f"{digest}  {self.name}\n")
        (tree / "completion.json").write_text(json.dumps({"key": self.key, "binaries": {self.name: listed or digest}}))

    def hot(self, *args):
        done = subprocess.run([sys.executable, str(SCRIPT), *args], capture_output=True, text=True, env=self.env)
        lines = done.stdout.strip().splitlines()
        return done.returncode, (json.loads(lines[-1]) if lines and lines[-1].startswith("{") else None), done.stderr

    def sha(self):
        return hashlib.sha256(self.cmux.read_bytes()).hexdigest()

    def test_plan_takes_the_daemon_part(self):
        done = subprocess.run([sys.executable, str(SCRIPT), "plan", FIX, "--app", str(self.app)],
                              capture_output=True, text=True, env=self.env)
        self.assertEqual(done.returncode, 0, done.stderr)
        plan = json.loads(done.stdout)
        self.assertEqual(plan["parts"], ["rust"])
        # cmux-mobile-host builds from cmux-wg too: it keeps the nightly's build, and says so.
        self.assertEqual(list(plan["left"]), ["bundled helpers (cmux-mobile-host, ...)"])
        self.assertEqual(plan["tree_key"], self.key)

    def test_apply_then_rollback_restores_the_prior_sha(self):
        code, receipt, err = self.hot("apply", FIX, "--app", str(self.app))
        self.assertEqual(code, 0, err)
        self.assertEqual(receipt["applied"], ["rust"])
        self.assertEqual(receipt["steps"]["rust"]["from"], self.old)
        self.assertEqual(receipt["steps"]["rust"]["running_sha256"], self.new)
        self.assertEqual(self.sha(), self.new)
        self.assertTrue((self.app / "Contents/Resources/bin/cmux-tui").is_symlink())
        code, receipt, err = self.hot("rollback")
        self.assertEqual(code, 0, err)
        self.assertTrue(receipt["ok"])
        self.assertEqual(receipt["steps"]["rust"]["running_sha256"], self.old)
        self.assertEqual(self.sha(), self.old)

    def test_a_rollback_that_fails_can_be_tried_again(self):
        code, receipt, err = self.hot("apply", FIX, "--app", str(self.app))
        self.assertEqual(code, 0, err)
        kept = self.tmp / "state/builds" / self.old / "cmux"
        good = kept.read_bytes()
        kept.write_bytes(b"#!/bin/sh\necho damaged\n")
        code, receipt, _ = self.hot("rollback")
        self.assertEqual(code, 1)
        self.assertFalse(receipt["ok"])
        self.assertIn("rust", receipt["undo"])
        kept.write_bytes(good)
        code, receipt, err = self.hot("rollback")
        self.assertEqual(code, 0, err)
        self.assertTrue(receipt["ok"])
        self.assertEqual(self.sha(), self.old)

    def test_a_binary_that_does_not_hash_to_its_published_sha_changes_nothing(self):
        self.publish(b"#!/bin/sh\necho tampered\n", self.new)
        code, receipt, _ = self.hot("apply", FIX, "--app", str(self.app))
        self.assertEqual(code, 1)
        self.assertTrue(receipt["rolled_back"])
        self.assertIn("does not hash", receipt["error"])
        self.assertEqual(self.sha(), self.old)

    def test_checksum_files_that_disagree_change_nothing(self):
        self.publish(self.new_body, self.new, listed="0" * 64)
        code, receipt, _ = self.hot("apply", FIX, "--app", str(self.app))
        self.assertEqual(code, 1)
        self.assertEqual(self.sha(), self.old)

    def test_a_commit_the_app_already_has_is_a_no_op(self):
        with open(self.app / "Contents/Info.plist", "wb") as handle:
            plistlib.dump({"CMUXCommit": FIX}, handle)
        code, receipt, err = self.hot("apply", self.base, "--app", str(self.app))
        self.assertEqual(code, 0, err)
        self.assertEqual(receipt["applied"], [])
        self.assertIn("the app already contains SHA", receipt["notes"])
        self.assertEqual(self.sha(), self.old)


if __name__ == "__main__":
    unittest.main()
