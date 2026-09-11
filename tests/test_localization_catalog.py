#!/usr/bin/env python3

import importlib.util
import contextlib
import io
import json
import sys
import tempfile
import unittest
from unittest.mock import patch
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("localization_catalog", ROOT / "scripts/localization_catalog.py")
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


def unit(value):
    return {"stringUnit": {"state": "translated", "value": value}}


def counted(parent, one, other, specifier="d"):
    return {
        **unit(parent),
        "substitutions": {
            "count": {
                "argNum": 1,
                "formatSpecifier": specifier,
                "variations": {"plural": {"one": one, "other": other}},
            }
        },
    }


class LocalizationCatalogTests(unittest.TestCase):
    def test_rejects_duplicate_locale_members_before_validation(self):
        text = '{"sourceLanguage":"en","strings":{"example":{"localizations":{"en":' + json.dumps(unit("Open")) + ',"de":' + json.dumps(unit("")) + ',"de":' + json.dumps(unit("Öffnen")) + '}}},"version":"1.0"}'
        with self.assertRaisesRegex(ValueError, "duplicate.*de"):
            MODULE.catalog_entries(text)

    def test_rejects_duplicate_substitution_members(self):
        english = unit("%d matches")
        localized = counted("%#@count@ Treffer", unit("%d"), unit("%d"))
        text = json.dumps({"sourceLanguage": "en", "strings": {"example": {"localizations": {"en": english, "de": localized}}}, "version": "1.0"})
        text = text.replace('"substitutions": {"count":', '"substitutions": {"count": {}, "count":', 1)
        with self.assertRaisesRegex(ValueError, "duplicate.*count"):
            MODULE.catalog_entries(text)

    def test_rejects_duplicate_catalog_containers(self):
        text = '{"sourceLanguage":"en","strings":{},"strings":{},"version":"1.0"}'
        with self.assertRaisesRegex(ValueError, "duplicate.*strings"):
            MODULE.catalog_entries(text)

    def test_shared_plural_words_do_not_allow_an_english_parent(self):
        english = counted("Your plan includes %#@count@.", unit("%d machine"), unit("%d machines"))
        french = counted("Votre forfait comprend %#@count@.", unit("%d machine"), unit("%d machines"))
        french["substitutions"]["count"]["variations"]["plural"]["many"] = unit("%d machines")
        entry = MODULE.Member("machines", {"localizations": {"en": english, "fr": french}}, 0, 0)
        metadata = {"machines": {"source": MODULE.source(entry.value), "identityLocales": {"fr": {
            "reason": "Machine and machines have the same spelling in French.", "values": ["%d machine", "%d machines"]}}}}
        self.assertEqual(MODULE.check_entry(entry, "fr", metadata, {}), [])
        french["stringUnit"]["value"] = "Your plan includes %#@count@."
        self.assertTrue(MODULE.check_entry(entry, "fr", metadata, {}))

    def test_check_does_not_hide_an_incomplete_duplicate_record(self):
        first = {"localizations": {"en": unit("Open")}}
        last = {"localizations": {"en": unit("Open"), "de": unit("Öffnen")}}
        text = '{"sourceLanguage":"en","strings":{"duplicate":' + json.dumps(first) + ',"duplicate":' + json.dumps(last) + '},"version":"1.0"}'
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Resources/Localizable.xcstrings"
            path.parent.mkdir()
            path.write_text(text)
            with patch.object(MODULE, "load_metadata", return_value={}), \
                 patch.object(sys, "argv", ["catalog", "check", "--root", directory, "--locale", "de"]), \
                 contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(MODULE.main(), 1)

    def test_package_catalog_uses_the_same_invariant_policy(self):
        catalog = {"sourceLanguage": "en", "strings": {"email": {"localizations": {
            "en": unit("you@example.com"), "ar": unit("you@example.com")}}}, "version": "1.0"}
        metadata = {"email": {"source": "you@example.com", "class": "syntax"}}
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Packages/macOS/Feedback/Sources/Feedback/Resources/Localizable.xcstrings"
            path.parent.mkdir(parents=True)
            path.write_text(json.dumps(catalog))
            with patch.object(MODULE, "load_metadata", side_effect=lambda name: metadata if "omissions" in name else {}), \
                 patch.object(sys, "argv", ["catalog", "check", "--root", directory, "--locale", "ar"]), \
                 contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(MODULE.main(), 0)

    def test_todo_commands_and_translated_words_are_not_markers(self):
        for source in ("Usage: cmux todo list", "Open Todo Pane", "Workspace todo controls"):
            self.assertEqual(MODULE.validate_localization(source, unit(source), "en"), [])
        self.assertEqual(MODULE.validate_localization("All", unit("Todo"), "es"), [])

    def test_unfinished_translation_markers_are_rejected(self):
        for marker in ("TODO", "TODO: translate this", "TRANSLATE_ME", "machine_translation", "<translated>", "__CMUX_TOKEN_1__"):
            with self.subTest(marker=marker):
                self.assertTrue(MODULE.validate_localization("Open", unit(marker), "de"))

    def test_rejects_lost_line_breaks(self):
        self.assertTrue(MODULE.validate_localization("Name: %@\nStatus: %@", unit("Name: %@ Status: %@"), "de"))

    def test_rejects_strings_outside_the_catalog_strings_object(self):
        catalog = {"sourceLanguage": "en", "strings": {}, "version": "1.0",
                   "orphan": {"localizations": {"en": unit("Ignored by Xcode")}}}
        with self.assertRaisesRegex(ValueError, "outside.*strings"):
            MODULE.catalog_entries(json.dumps(catalog))

    def test_shared_spelling_exception_is_locale_specific_and_never_allows_omission(self):
        entry = MODULE.Member("terminal", {"localizations": {"en": unit("Terminal"), "de": unit("Terminal"), "ja": unit("Terminal")}}, 0, 0)
        metadata = {"terminal": {"source": "Terminal", "identityLocales": {"de": "Established German technical term."}}}
        self.assertEqual(MODULE.check_entry(entry, "de", metadata, {}), [])
        self.assertTrue(MODULE.check_entry(entry, "ja", metadata, {}))
        del entry.value["localizations"]["de"]
        self.assertIn("missing locale entry", MODULE.check_entry(entry, "de", metadata, {}))

    def test_japanese_invariant_requires_entry_but_allows_literal(self):
        entry = MODULE.Member("brand", {"localizations": {"en": unit("cmux"), "ja": unit("cmux")}}, 0, 0)
        omissions = {"brand": {"source": "cmux", "class": "brand"}}
        self.assertEqual(MODULE.check_entry(entry, "ja", omissions, {}), [])
        del entry.value["localizations"]["ja"]
        self.assertIn("missing locale entry", MODULE.check_entry(entry, "ja", omissions, {}))

    def test_english_substitutions_and_plural_metadata_validate(self):
        english = counted("%#@count@", unit("%d match"), unit("%d matches"))
        german = counted("%#@count@", unit("%d Treffer"), unit("%d Treffer"))
        entry = MODULE.Member("matches", {"localizations": {"en": english, "de": german}}, 0, 0)
        counts = {"matches": {"source": "%d matches", "arguments": [1]}}
        for locale in ("en", "de"):
            with self.subTest(locale=locale):
                self.assertEqual(MODULE.check_entry(entry, locale, {}, counts), [])

    def test_each_required_plural_leaf_needs_text(self):
        for bad_leaf in ({}, {"stringUnit": {"state": "translated", "value": ""}}):
            for position in ("one", "other"):
                with self.subTest(leaf=bad_leaf, position=position):
                    german = counted("%#@count@ Treffer", unit("%d"), unit("%d"))
                    german["substitutions"]["count"]["variations"]["plural"][position] = bad_leaf
                    self.assertTrue(MODULE.validate_localization("%d matches", german, "de"))

    def test_substitution_cannot_hide_copied_english(self):
        german = counted("Treffer: %#@count@", unit("%d matches"), unit("%d matches"))
        self.assertTrue(MODULE.validate_localization("%d matches", german, "de"))

    def test_plural_only_numeric_leaves_are_valid_when_parent_is_translated(self):
        german = counted("%#@count@ Treffer", unit("%d"), unit("%d"))
        self.assertEqual(MODULE.validate_localization("%d matches", german, "de"), [])

    def test_unused_substitutions_cannot_satisfy_count_metadata(self):
        german = counted("%d Treffer", unit("%d"), unit("%d"))
        entry = MODULE.Member("matches", {"localizations": {"en": unit("%d matches"), "de": german}}, 0, 0)
        counts = {"matches": {"source": "%d matches", "arguments": [1]}}
        self.assertTrue(MODULE.check_entry(entry, "de", {}, counts))

    def test_arabic_requires_all_six_nonempty_categories(self):
        variants = {category: unit("%d نتائج") for category in ("zero", "one", "two", "few", "many", "other")}
        arabic = {"variations": {"plural": variants}}
        self.assertEqual(MODULE.validate_localization("%d matches", arabic, "ar"), [])
        variants["few"] = {}
        self.assertTrue(MODULE.validate_localization("%d matches", arabic, "ar"))

    def test_merge_updates_duplicate_records_without_losing_other_data(self):
        originals = [
            {"comment": "First record", "localizations": {"en": unit("Open"), "ja": unit("開く")}},
            {"comment": "Second record", "localizations": {"en": unit("Open"), "ja": unit("開く")}},
        ]
        text = '{"sourceLanguage":"en","strings":{' + ",".join(
            '"example":' + json.dumps(entry, ensure_ascii=False) for entry in originals
        ) + '},"version":"1.0"}'
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Localizable.xcstrings"
            path.write_text(text, encoding="utf-8")
            self.assertEqual(MODULE.merge(path, "de", [{"key": "example", "source": "Open", "value": "Öffnen"}], {}), 2)
            updated = MODULE.catalog_entries(path.read_text(encoding="utf-8"))
            self.assertEqual(len(updated), 2)
            for original, actual in zip(originals, updated):
                self.assertEqual(actual.value["comment"], original["comment"])
                self.assertEqual(actual.value["localizations"], {**original["localizations"], "de": unit("Öffnen")})

    def test_merge_rejects_stale_source_and_wrong_placeholder(self):
        original = {
            "sourceLanguage": "en",
            "strings": {
                "example": {
                    "extractionState": "manual",
                    "localizations": {"en": {"stringUnit": {"state": "translated", "value": "Open %@"}}},
                }
            },
        }
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Localizable.xcstrings"
            path.write_text(json.dumps(original, indent=2) + "\n", encoding="utf-8")
            with self.assertRaises(ValueError):
                MODULE.merge(path, "de", [{"key": "example", "source": "Stale %@", "value": "Öffnen %@"}], {})
            with self.assertRaises(ValueError):
                MODULE.merge(path, "de", [{"key": "example", "source": "Open %@", "value": "Öffnen"}], {})
            self.assertEqual(json.loads(path.read_text(encoding="utf-8")), original)

    def test_merge_preserves_other_locales_and_updates_only_target(self):
        original = {
            "sourceLanguage": "en",
            "strings": {
                "example": {
                    "extractionState": "manual",
                    "localizations": {
                        "en": {"stringUnit": {"state": "translated", "value": "Open"}},
                        "ja": {"stringUnit": {"state": "translated", "value": "開く"}},
                    },
                }
            },
        }
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Localizable.xcstrings"
            path.write_text(json.dumps(original, indent=2) + "\n", encoding="utf-8")
            MODULE.merge(path, "de", [{"key": "example", "source": "Open", "value": "Öffnen"}], {})
            updated = json.loads(path.read_text(encoding="utf-8"))
            localizations = updated["strings"]["example"]["localizations"]
            self.assertEqual(localizations["ja"]["stringUnit"]["value"], "開く")
            self.assertEqual(localizations["de"]["stringUnit"]["value"], "Öffnen")


if __name__ == "__main__":
    unittest.main()
