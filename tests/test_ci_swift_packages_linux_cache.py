#!/usr/bin/env python3
"""Keep the Linux SwiftPM build cache rolling instead of per-commit."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/swift-packages-linux.yml"


class SwiftPackagesLinuxCacheTests(unittest.TestCase):
    def test_restore_and_save_use_one_rolling_key(self):
        text = WORKFLOW.read_text(encoding="utf-8")
        key_lines = [line.strip() for line in text.splitlines() if "key: swiftpm-linux-" in line]
        self.assertEqual(len(key_lines), 2)
        self.assertEqual(key_lines[0], key_lines[1])
        self.assertNotIn("${{ github.sha }}", key_lines[0])

    def test_week_and_manifest_prefixes_remain_in_the_key(self):
        text = WORKFLOW.read_text(encoding="utf-8")
        key = next(line for line in text.splitlines() if "key: swiftpm-linux-" in line)
        self.assertIn("${{ steps.key.outputs.week }}", key)
        self.assertIn("${{ steps.key.outputs.toolchain }}", key)
        self.assertIn("${{ matrix.group }}", key)
        self.assertIn("${{ hashFiles('Packages/**/Package.swift', 'Packages/**/Package.resolved') }}", key)


if __name__ == "__main__":
    unittest.main()
