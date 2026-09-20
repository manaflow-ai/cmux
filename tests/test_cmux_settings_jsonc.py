#!/usr/bin/env python3
"""Regression coverage for lossless cmux-settings JSONC writes."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "skills" / "cmux-settings" / "scripts" / "cmux-settings"


class CmuxSettingsJSONCTests(unittest.TestCase):
    def run_helper(
        self,
        config: Path,
        *args: str,
        check: bool = True,
    ) -> subprocess.CompletedProcess[str]:
        result = subprocess.run(
            [sys.executable, str(HELPER), "--file", str(config), *args],
            text=True,
            capture_output=True,
            check=False,
        )
        if check and result.returncode != 0:
            self.fail(
                f"helper failed ({result.returncode}): {result.stderr}\n{result.stdout}"
            )
        return result

    def test_unset_removes_values_under_all_duplicate_ancestors(self) -> None:
        cases = [
            ('{"app":{"appearance":"hidden","keep":1},"app":{"appearance":"dark"}}', "app.appearance"),
            ('{"app":1,"app":{"appearance":"dark","keep":1}}', "app.appearance"),
            ('{"app":{"nested":{"appearance":"hidden","keep":1},"nested":{"appearance":"dark"}}}', "app.nested.appearance"),
        ]
        for source, key in cases:
            with self.subTest(source=source), tempfile.TemporaryDirectory() as tmp:
                config = Path(tmp) / "cmux.json"
                config.write_text(source, encoding="utf-8")
                self.run_helper(config, "unset", key)
                appearances = []
                kept = []

                def inspect_object(pairs):
                    appearances.extend(value for name, value in pairs if name == "appearance")
                    kept.extend(value for name, value in pairs if name == "keep")
                    return dict(pairs)

                json.loads(self.strip_jsonc_for_test(config.read_text(encoding="utf-8")), object_pairs_hook=inspect_object)
                self.assertEqual(appearances, [])
                self.assertEqual(kept, [1])

    def test_set_preserves_comments_whitespace_order_and_trailing_commas(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            config = Path(tmp) / "cmux.json"
            source = """{
  // root documentation
  "zeta": { "keep": true },
  "app": {
    // before appearance
    "before": 1,
    "appearance": "light", // inline appearance documentation
    // after appearance
    "after": 2,
  },
  "alpha": 1,
}
"""
            config.write_text(source, encoding="utf-8")

            self.run_helper(config, "set", "app.appearance", "dark")

            self.assertEqual(
                config.read_text(encoding="utf-8"),
                source.replace('"appearance": "light"', '"appearance": "dark"'),
            )

    def test_nested_creation_inherits_trailing_comma_style(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            config = Path(tmp) / "cmux.json"
            config.write_text(
                """{
  "app": {
    "appearance": "dark",
  },
  "other": 1,
}
""",
                encoding="utf-8",
            )

            self.run_helper(config, "set", "app.nested.leaf", "true")

            updated = config.read_text(encoding="utf-8")
            self.assertIn(
                '"nested": {\n      "leaf": true\n    },',
                updated,
            )
            parsed = json.loads(self.strip_jsonc_for_test(updated))
            self.assertIs(parsed["app"]["nested"]["leaf"], True)

    def test_unset_prunes_plain_empty_parents_and_keeps_unrelated_text(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            config = Path(tmp) / "cmux.json"
            config.write_text(
                """{
  "automation": {
    "nested": {
      "leaf": true,
    },
  },
  "keep": 1,
}
""",
                encoding="utf-8",
            )

            self.run_helper(config, "unset", "automation.nested.leaf")

            self.assertEqual(
                config.read_text(encoding="utf-8"),
                """{
  "keep": 1,
}
""",
            )

    def test_symlinked_config_writes_target_and_keeps_link(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            target = root / "target.json"
            config = root / "cmux.json"
            source = """{
  // target docs
  "app": {
    "appearance": "light",
  },
}
"""
            target.write_text(source, encoding="utf-8")
            config.symlink_to(target)

            self.run_helper(config, "set", "app.appearance", "dark")

            self.assertTrue(config.is_symlink())
            self.assertEqual(config.resolve(), target.resolve())
            self.assertEqual(
                target.read_text(encoding="utf-8"),
                source.replace('"appearance": "light"', '"appearance": "dark"'),
            )

    def test_malformed_input_is_refused_without_overwrite(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            config = Path(tmp) / "cmux.json"
            before = b'{\n  // truncated\n  "app": {\n'
            config.write_bytes(before)

            result = self.run_helper(
                config,
                "set",
                "app.appearance",
                "dark",
                check=False,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("not valid JSONC", result.stderr)
            self.assertEqual(config.read_bytes(), before)

    def test_semantic_noops_are_byte_stable_and_skip_replace(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            config = Path(tmp) / "cmux.json"
            source = """{
  // preserve every byte on no-op
  "app": {
    "appearance": "dark",
  },
}
"""
            config.write_text(source, encoding="utf-8")
            before = config.stat()

            self.run_helper(config, "set", "app.appearance", "dark")
            self.run_helper(config, "unset", "app.missing")

            after = config.stat()
            self.assertEqual(config.read_text(encoding="utf-8"), source)
            self.assertEqual(after.st_ino, before.st_ino)
            self.assertEqual(after.st_mtime_ns, before.st_mtime_ns)

    def test_set_targets_effective_last_duplicate_key(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            config = Path(tmp) / "cmux.json"
            source = """{
  "app": {
    "appearance": "shadowed",
    "appearance": "system",
  },
}
"""
            config.write_text(source, encoding="utf-8")

            self.run_helper(config, "set", "app.appearance", "dark")

            updated = config.read_text(encoding="utf-8")
            self.assertIn('"appearance": "shadowed"', updated)
            self.assertIn('"appearance": "dark"', updated)
            parsed = json.loads(self.strip_jsonc_for_test(updated))
            self.assertEqual(parsed["app"]["appearance"], "dark")

    def test_unset_duplicate_keys_does_not_expose_shadowed_value(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            config = Path(tmp) / "cmux.json"
            source = """{
  "app": {
    "appearance": "shadowed",
    "keep": "authored",
  },
  "app": {
    "appearance": "system",
    "appearance": "light",
  },
  "other": 1,
}
"""
            config.write_text(source, encoding="utf-8")

            self.run_helper(config, "unset", "app.appearance")

            updated = config.read_text(encoding="utf-8")
            self.assertIn('"keep": "authored"', updated)
            self.assertIn('"other": 1', updated)
            parsed = json.loads(self.strip_jsonc_for_test(updated))
            self.assertNotIn("appearance", parsed["app"])

    def test_scalar_intermediate_rejection_remains_byte_stable(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            config = Path(tmp) / "cmux.json"
            source = '{"app":"manual"}\n'
            config.write_text(source, encoding="utf-8")

            result = self.run_helper(
                config,
                "set",
                "app.appearance",
                "dark",
                check=False,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("intermediate key 'app' is not an object", result.stderr)
            self.assertEqual(config.read_text(encoding="utf-8"), source)

    @staticmethod
    def strip_jsonc_for_test(text: str) -> str:
        # This fixture only needs line-comment and trailing-comma handling.
        lines = []
        for line in text.splitlines():
            quoted = False
            escaped = False
            cut = len(line)
            for index, character in enumerate(line):
                if quoted:
                    if escaped:
                        escaped = False
                    elif character == "\\":
                        escaped = True
                    elif character == '"':
                        quoted = False
                elif character == '"':
                    quoted = True
                elif line[index : index + 2] == "//":
                    cut = index
                    break
            lines.append(line[:cut])
        import re

        return re.sub(r",(\s*[}\]])", r"\1", "\n".join(lines))


if __name__ == "__main__":
    unittest.main()
