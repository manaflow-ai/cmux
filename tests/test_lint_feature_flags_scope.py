#!/usr/bin/env python3
"""The flag linter must see every flag declaration, not one hardcoded file.

A FLAG( comment outside Sources/FeatureFlags.swift used to be invisible to
scripts/lint-feature-flags.py, which silently exempted that flag from every
rule -- including the zombie reviewBy check the flag was relying on.
"""

import importlib.util
from pathlib import Path
import unittest

REPO_ROOT = Path(__file__).resolve().parents[1]
LINTER = REPO_ROOT / "scripts" / "lint-feature-flags.py"


def load_linter():
    spec = importlib.util.spec_from_file_location("lint_feature_flags", LINTER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FlagLinterScopeTests(unittest.TestCase):
    def setUp(self):
        self.linter = load_linter()

    def test_discovers_every_file_declaring_a_flag(self):
        discovered = set(self.linter.swift_registry_files())
        declared = {
            str(path.relative_to(REPO_ROOT))
            for root in ("Sources", "Packages", "CLI", "ios")
            for path in (REPO_ROOT / root).rglob("*.swift")
            if (REPO_ROOT / root).exists() and "FLAG(key:" in path.read_text(errors="ignore")
        }
        self.assertEqual(
            sorted(declared - discovered),
            [],
            "a Swift file declares a flag the linter cannot see; it is exempt from every rule",
        )

    def test_every_discovered_flag_is_linted(self):
        flags = []
        for rel in self.linter.swift_registry_files():
            flags += self.linter.parse_swift_registry(
                (REPO_ROOT / rel).read_text(), rel
            )
        keys = {flag["key"] for flag in flags}
        self.assertIn(
            "cloud-machines-enabled-release",
            keys,
            "the Cloud flag is declared outside the main registry and must still be linted",
        )
        for flag in flags:
            self.assertTrue(flag["source"], "each flag must be attributed to its own file")


if __name__ == "__main__":
    unittest.main()
