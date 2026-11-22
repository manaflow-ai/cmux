#!/usr/bin/env python3
"""The vendored CmuxAgentCursor must equal the cmux-cua tree named in its SOURCE
file, and SOURCE must name CMUX_CUA_PINNED_SHA (plans/cmux-next/agent-cursor.md)."""
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "cmux_agent_cursor_vendor.py"
sys.path.insert(0, str(SCRIPT.parent))


class VendoredAgentCursorTest(unittest.TestCase):
    def test_the_vendored_copy_matches_its_pinned_source(self):
        done = subprocess.run([sys.executable, str(SCRIPT), "check"], capture_output=True, text=True)
        self.assertEqual(done.returncode, 0, done.stderr)

    def test_a_hand_edit_changes_the_tree_hash(self):
        import cmux_agent_cursor_vendor as vendor
        source = vendor.read_source()
        with tempfile.TemporaryDirectory() as tmp:
            copy = Path(tmp) / "CmuxAgentCursor"
            shutil.copytree(vendor.DEST, copy, symlinks=True)
            skip = frozenset({vendor.SOURCE_NAME})
            self.assertEqual(vendor.git_tree_hash(copy, skip), source["tree"])
            manifest = copy / "Package.swift"
            manifest.write_text(manifest.read_text() + "// local edit\n")
            self.assertNotEqual(vendor.git_tree_hash(copy, skip), source["tree"])

    def test_the_tree_hash_is_gits(self):
        import cmux_agent_cursor_vendor as vendor
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "b").mkdir()
            (root / "b" / "x.txt").write_text("x\n")
            (root / "a.txt").write_text("a\n")
            (root / "run.sh").write_text("#!/bin/sh\n")
            (root / "run.sh").chmod(0o755)
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            subprocess.run(["git", "-C", str(root), "add", "-A"], check=True)
            expected = subprocess.run(["git", "-C", str(root), "write-tree"], check=True,
                                      capture_output=True, text=True).stdout.strip()
            shutil.rmtree(root / ".git")
            self.assertEqual(vendor.git_tree_hash(root), expected)


if __name__ == "__main__":
    unittest.main()
