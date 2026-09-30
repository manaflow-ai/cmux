#!/usr/bin/env python3
"""The flag linter must see every flag declaration, not one hardcoded file.

A FLAG( comment outside Sources/FeatureFlags.swift used to be invisible to
scripts/lint-feature-flags.py, which silently exempted that flag from every
rule -- including the zombie reviewBy check the flag was relying on.
"""

import importlib.util
import contextlib
import io
from pathlib import Path
import tempfile
from unittest import mock
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
        flags = self.linter.collect_flags()
        keys = {flag["key"] for flag in flags}
        self.assertIn(
            "cloud-machines-enabled-release",
            keys,
            "the Cloud flag is declared outside the main registry and must still be linted",
        )
        for flag in flags:
            self.assertTrue(flag["source"], "each flag must be attributed to its own file")

    def test_collect_flags_includes_web_and_swift_registries(self):
        flags = self.linter.collect_flags()
        sources = {flag["source"] for flag in flags}
        self.assertIn(self.linter.WEB_REGISTRY_REL, sources)
        self.assertTrue(
            sources - {self.linter.WEB_REGISTRY_REL},
            "the collector must include at least one Swift registry",
        )

    def test_collect_flags_preserves_declarations_with_non_utf8_bytes(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            web = root / "flags.ts"
            web.write_bytes(b'// \xff\n{ key: "web-release", reviewBy: "2030-01-01" }')
            (root / "Example.swift").write_bytes(
                b'// \xff\n// FLAG(key: swift-release, reviewBy: 2030-01-01)\n')
            with mock.patch.object(self.linter, "REPO", root), \
                 mock.patch.object(self.linter, "WEB_REGISTRY", web), \
                 mock.patch.object(self.linter, "swift_registry_files", return_value=["Example.swift"]):
                flags, registries = self.linter.collect_flags()
            self.assertEqual({flag["key"] for flag in flags}, {"web-release", "swift-release"})
            self.assertIn("Example.swift", registries)

    def test_main_discovers_registries_only_once(self):
        with mock.patch.object(self.linter, "swift_registry_files", return_value=[]) as discover, \
             mock.patch.object(self.linter, "parse_web_registry", return_value=[]), \
             contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(self.linter.main(), 0)
        discover.assert_called_once_with()

    def test_prose_flag_references_are_not_declarations(self):
        """Discovery and parsing must agree on what a declaration is.

        Discovery greps the literal `FLAG(key:`; parsing must require the same
        thing. Sources/ContentView.swift:1771 has long carried
        `// FLAG(sidebar-appkit-list-experiment): parent-driven`, a prose
        reference with no `key:`. Once any flag is declared in that file -- the
        pattern this linter's file discovery exists to support -- a looser parse
        reports "flag entry without a key" against the untouched comment rather
        than against the flag just added.
        """
        source = (
            "// FLAG(sidebar-appkit-list-experiment): parent-driven\n"
            "// FLAG(key: example-thing-release, owner: someone,\n"
            "//      reviewBy: 2030-01-01, defaultWhenUnavailable: false)\n"
        )
        flags = self.linter.parse_swift_registry(source, "Example.swift")
        self.assertEqual([flag["key"] for flag in flags], ["example-thing-release"])

    def test_no_discovered_flag_is_missing_a_key(self):
        """The whole-repo version of the above: a keyless parse is a parse bug.

        Every rule keys off `flag["key"]`, so a `None` key is reported as a
        malformed declaration in a real file -- a failure nobody can act on,
        because the file is fine and the parser is wrong.
        """
        for rel in self.linter.swift_registry_files():
            for flag in self.linter.parse_swift_registry(
                (REPO_ROOT / rel).read_text(), rel
            ):
                self.assertIsNotNone(
                    flag["key"],
                    f"{rel}: parsed a flag declaration with no key",
                )

    def test_invalid_calendar_date_is_reported_as_a_violation(self):
        """A DATE_RE match that is not a calendar date must be lint output."""
        source = (
            "// FLAG(key: malformed-date-release, owner: someone,\n"
            "//      reviewBy: 2026-13-01, defaultWhenUnavailable: false)\n"
        )
        parsed = self.linter.parse_swift_registry(source, "Example.swift")
        self.linter.errors.clear()
        grep_keys = lambda key: {"Example.swift"} if key == "malformed-date-release" else set()
        with mock.patch.object(self.linter, "parse_web_registry", return_value=parsed), \
             mock.patch.object(self.linter, "swift_registry_files", return_value=[]), \
             mock.patch.object(self.linter, "grep_key_files", side_effect=grep_keys), \
             contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(self.linter.main(), 1)
        self.assertTrue(
            any("malformed-date-release" in error and "Example.swift" in error
                for error in self.linter.errors),
            self.linter.errors,
        )


if __name__ == "__main__":
    unittest.main()
