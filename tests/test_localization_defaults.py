#!/usr/bin/env python3

import contextlib
import importlib.util
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("localization_defaults", ROOT / "scripts/localization_defaults.py")
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


def unit(value):
    return {"stringUnit": {"state": "translated", "value": value}}


def swift_call(key, default):
    return f'let _ = String(localized: "{key}", defaultValue: "{default}")\n'


class Fixture:
    """A throwaway checkout: one catalog under Resources, Swift wherever the test puts it."""

    def __init__(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)

    def catalog(self, entries, path="Resources/Localizable.xcstrings"):
        strings = {key: {"localizations": {"en": unit(english), "ja": unit(japanese)}}
                   for key, (english, japanese) in entries.items()}
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(json.dumps({"sourceLanguage": "en", "strings": strings, "version": "1.0"},
                                     ensure_ascii=False), encoding="utf-8")

    def swift(self, text, path="Sources/App.swift"):
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding="utf-8")

    def allowlist(self, entries):
        target = self.root / MODULE.ALLOWLIST
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(json.dumps(entries), encoding="utf-8")

    def check(self):
        return MODULE.check(self.root, MODULE.load_allowlist(self.root / MODULE.ALLOWLIST))


class LocalizationDefaultsTests(unittest.TestCase):
    def setUp(self):
        self.fixture = Fixture()
        self.addCleanup(self.fixture.directory.cleanup)

    def test_catalog_that_drops_a_default_argument_is_reported(self):
        self.fixture.catalog({"rename.unavailable": ("The state could not be refreshed.", "状態を更新できませんでした。")})
        self.fixture.swift(swift_call("rename.unavailable", "The state for %@ is unavailable."))
        errors, compared = self.fixture.check()
        self.assertEqual(compared, 1)
        self.assertEqual(errors, [
            "Resources/Localizable.xcstrings:rename.unavailable: catalog en placeholders [] != "
            "Swift defaultValue [(1, '@')] (Sources/App.swift)"
        ])

    def test_catalog_that_adds_an_argument_is_reported(self):
        self.fixture.catalog({"install.failed": ("failed to install: %@", "インストールできませんでした：%@")})
        self.fixture.swift(swift_call("install.failed", "failed to install"))
        errors, _ = self.fixture.check()
        self.assertEqual(len(errors), 1)
        self.assertIn("catalog en placeholders [(1, '@')] != Swift defaultValue []", errors[0])

    def test_same_arguments_in_another_order_or_spelling_match(self):
        self.fixture.catalog({
            "move": ("Move %2$@ to %1$@", "%1$@ に %2$@ を移動"),
            "count": ("%lld items in %@", "%@ 内の %lld 項目"),
        })
        self.fixture.swift(swift_call("move", "Move %2$@ to %1$@") + swift_call("count", "%lld items in %@"))
        self.assertEqual(self.fixture.check(), ([], 2))

    def test_calls_without_one_readable_default_are_skipped(self):
        self.fixture.catalog({
            "interpolated": ("Hello %@", "こんにちは %@"),
            "conflicting": ("Open %@", "%@ を開く"),
            "key.only": ("Close %@", "%@ を閉じる"),
        })
        self.fixture.swift(
            'let _ = String(localized: "interpolated", defaultValue: "Hello \\(name)")\n'
            + swift_call("conflicting", "Open")
            + 'let _ = String(localized: "key.only")\n',
            "Sources/A.swift",
        )
        self.fixture.swift(swift_call("conflicting", "Open %@"), "Sources/B.swift")
        self.assertEqual(self.fixture.check(), ([], 0))

    def test_a_conflict_inside_one_file_is_not_settled_by_another_file(self):
        self.fixture.catalog({"conflicting": ("Open %@", "%@ を開く")})
        self.fixture.swift(swift_call("conflicting", "Open") + swift_call("conflicting", "Open %@"), "Sources/A.swift")
        self.fixture.swift(swift_call("conflicting", "Open"), "Sources/B.swift")
        self.assertEqual(self.fixture.check(), ([], 0))

    def test_mismatch_names_the_other_catalogs_carrying_the_key(self):
        self.fixture.catalog({"shared": ("Open %@", "%@ を開く")})
        self.fixture.catalog({"shared": ("Open", "開く")}, "Packages/macOS/Pkg/Sources/Pkg/Localizable.xcstrings")
        self.fixture.swift(swift_call("shared", "Open %@"), "Packages/macOS/Pkg/Sources/Pkg/View.swift")
        errors, compared = self.fixture.check()
        self.assertEqual(compared, 2)
        self.assertEqual(errors, [
            "Packages/macOS/Pkg/Sources/Pkg/Localizable.xcstrings:shared: catalog en placeholders [] != "
            "Swift defaultValue [(1, '@')] (Packages/macOS/Pkg/Sources/Pkg/View.swift)"
            "; Resources/Localizable.xcstrings carries [(1, '@')]"
        ])

    def test_a_default_the_signature_parser_rejects_is_skipped_not_fatal(self):
        self.fixture.catalog({"items": ("%lld items", "%lld 項目"), "ok": ("Open %@", "%@ を開く")})
        self.fixture.swift(swift_call("items", "%#@count@ items") + swift_call("ok", "Open %@"))
        self.assertEqual(self.fixture.check(), ([], 1))

    def test_test_targets_and_vendored_trees_are_not_scanned(self):
        self.fixture.catalog({"age": ("%lld minutes", "%lld 分")})
        for path in ("cmuxTests/AgeTests.swift", "Packages/macOS/Pkg/Tests/PkgTests/T.swift", "vendor/Dep/Sources/D.swift"):
            self.fixture.swift(swift_call("age", "a few minutes"), path)
        self.assertEqual(self.fixture.check(), ([], 0))

    def test_allowlisted_mismatch_passes_and_a_stale_entry_fails(self):
        self.fixture.catalog({
            "known": ("The state could not be refreshed.", "状態を更新できませんでした。"),
            "fixed": ("Open %@", "%@ を開く"),
        })
        self.fixture.swift(swift_call("known", "The state for %@ is unavailable.") + swift_call("fixed", "Open %@"))
        self.fixture.allowlist({"known": "waiting on a copy decision", "fixed": "already fixed"})
        errors, _ = self.fixture.check()
        self.assertEqual(errors, [
            f"{MODULE.ALLOWLIST}: fixed no longer mismatches its Swift defaultValue; remove the entry"
        ])

    def test_allowlist_entries_need_a_reason(self):
        self.fixture.allowlist({"known": ""})
        with self.assertRaises(ValueError):
            MODULE.load_allowlist(self.fixture.root / MODULE.ALLOWLIST)

    def test_main_reports_the_count_and_exit_status(self):
        self.fixture.catalog({"ok": ("Open %@", "%@ を開く"), "bad": ("Close", "閉じる")})
        self.fixture.swift(swift_call("ok", "Open %@") + swift_call("bad", "Close %@"))
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            status = MODULE.main(["--root", str(self.fixture.root)])
        self.assertEqual(status, 1)
        self.assertIn("Resources/Localizable.xcstrings:bad:", stderr.getvalue())
        self.assertEqual(stdout.getvalue(), "2 Swift defaultValue/catalog en comparisons: 1 mismatch\n")
        (self.fixture.root / "Sources/App.swift").write_text(swift_call("ok", "Open %@") + swift_call("bad", "Close"))
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(MODULE.main(["--root", str(self.fixture.root)]), 0)


if __name__ == "__main__":
    unittest.main()
