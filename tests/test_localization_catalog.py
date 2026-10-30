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
            path = Path(directory) / "Resources/InfoPlist.xcstrings"
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

    def test_numbered_placeholders_may_change_order(self):
        self.assertEqual(MODULE.validate_localization("Move %@ to %@", unit("%2$@ に %1$@ を移動"), "ja"), [])
        self.assertEqual(MODULE.validate_localization("Count %d; name %@", unit("名前 %2$@、件数 %1$d"), "ja"), [])
        self.assertEqual(MODULE.validate_localization("%d%% of %@", unit("%2$@ の %1$d%%"), "ja"), [])

    def test_dynamic_width_and_precision_consume_their_own_arguments(self):
        self.assertEqual(MODULE.signature("Width %*d then %d"), [(1, "*"), (2, "*1$d"), (3, "d")])
        self.assertEqual(MODULE.signature("%3$*1$.*2$f"), [(1, "*"), (2, "*"), (3, "*1$.*2$f")])
        self.assertEqual(MODULE.signature("%*.*f"), MODULE.signature("%3$*1$.*2$f"))
        self.assertEqual(MODULE.canonical_text("Width %-*.*f"), "Width %3$-*1$.*2$f")
        self.assertEqual(MODULE.canonical_text("Width %3$-*1$.*2$f"), "Width %3$-*1$.*2$f")
        for english, translated in (
            ("Width %*d then %d", "幅 %2$*1$d、%3$d"),
            ("Width %*d then %d", "幅 %*d、%d"),
            ("Precision %.*f", "精度 %2$.*1$f"),
            ("Positional %3$*1$.*2$f", "精度 %3$*1$.*2$f"),
        ):
            with self.subTest(translated=translated):
                self.assertEqual(MODULE.validate_localization(english, unit(translated), "ja"), [])

    def test_dynamic_width_and_precision_arguments_cannot_be_dropped_or_retyped(self):
        for english, translated in (
            ("Width %*d", "幅 %d"),
            ("Precision %.*f", "精度 %f"),
            ("Positional %3$*1$.*2$f", "精度 %3$f"),
            ("Width %*d", "幅 %1$d 値 %2$d"),
            ("Width %*d", "幅 %2$*1$@"),
            ("Positional %3$*1$.*2$f", "精度 %3$*2$.*1$f"),
            ("Width %*d then %*d", "幅 %2$*3$d、%4$*1$d"),
        ):
            with self.subTest(translated=translated):
                self.assertTrue(MODULE.validate_localization(english, unit(translated), "ja"))

    def test_unnumbered_placeholders_count_separately_from_numbered_ones(self):
        # String(format: "%1$@ %@", "one", "two") renders "one one" and
        # String(format: "%@ %2$@", "one", "two") renders "one two".
        self.assertEqual(MODULE.signature("%1$@ %@"), [(1, "@"), (1, "@")])
        self.assertEqual(MODULE.canonical_text("%1$@ %@"), "%1$@ %1$@")
        self.assertEqual(MODULE.validate_localization("Move %@ to %@", unit("%@ を %2$@ へ"), "ja"), [])
        self.assertEqual(MODULE.validate_localization("Move %@ to %@", unit("%2$@ に %@ を移動"), "ja"), [])
        for english, translated in (
            ("Move %@ to %@", "%1$@ %@"),
            ("Width %*d then %d", "幅 %2$*1$d、%d"),
            ("Width %*d", "幅 %*1$d"),
        ):
            with self.subTest(translated=translated):
                self.assertTrue(MODULE.validate_localization(english, unit(translated), "ja"))

    def test_reordered_placeholders_still_need_every_argument_and_type(self):
        self.assertTrue(MODULE.validate_localization("Move %@ to %@", unit("%2$@ を移動"), "ja"))
        self.assertTrue(MODULE.validate_localization("Move %@ to %@", unit("%2$@ に %1$@ を %3$@ へ移動"), "ja"))
        self.assertTrue(MODULE.validate_localization("Count %d; name %@", unit("名前 %2$d、件数 %1$@"), "ja"))
        self.assertTrue(MODULE.validate_localization("%d%% of %@", unit("%2$@ の %1$d"), "ja"))

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

    def test_merge_accepts_reordered_numbered_placeholders(self):
        original = {
            "sourceLanguage": "en",
            "strings": {
                "example": {
                    "extractionState": "manual",
                    "localizations": {"en": {"stringUnit": {"state": "translated", "value": "Move %@ to %@"}}},
                }
            },
        }
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Localizable.xcstrings"
            path.write_text(json.dumps(original, indent=2) + "\n", encoding="utf-8")
            MODULE.merge(path, "ja", [{"key": "example", "source": "Move %@ to %@", "value": "%2$@ に %1$@ を移動"}], {})
            updated = json.loads(path.read_text(encoding="utf-8"))
            self.assertEqual(updated["strings"]["example"]["localizations"]["ja"]["stringUnit"]["value"], "%2$@ に %1$@ を移動")

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

    def test_load_metadata_rejects_duplicate_keys(self):
        document = (
            '{"one": {"source": "A"}, "two": {"source": "B"}, "one": {"source": "C"}}'
        )
        with tempfile.TemporaryDirectory() as directory:
            scripts = Path(directory) / "scripts"
            scripts.mkdir()
            (scripts / "metadata.json").write_text(document, encoding="utf-8")
            with patch.object(MODULE, "ROOT", Path(directory)):
                with self.assertRaisesRegex(ValueError, "scripts/metadata.json.*duplicate.*one"):
                    MODULE.load_metadata("metadata.json")

    def test_checked_in_metadata_has_no_duplicate_keys(self):
        for name in ("localization-allowed-omissions.json", "localization-plurals.json"):
            with self.subTest(name=name):
                self.assertIsInstance(MODULE.load_metadata(name), dict)


def catalog(strings):
    return {"sourceLanguage": "en", "strings": strings, "version": "1.0"}


def string(english, **locales):
    localizations = {"en": unit(english)}
    for locale in MODULE.LOCALES[1:]:
        value, state = locales.get(locale.replace("-", "_"), (f"{english} ({locale})", "translated"))
        localizations[locale] = {"stringUnit": {"state": state, "value": value}}
    return {"localizations": localizations}


class LocalizationDebtRatchetTests(unittest.TestCase):
    """cmux NEXT's catalogs carry old debt; with a baseline, `check` lets it shrink but never grow."""

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.catalog = self.root / "Packages/macOS/CmuxNext/Sources/Area/Localizable.xcstrings"
        self.catalog.parent.mkdir(parents=True)
        self.baseline = self.root / "scripts" / MODULE.DEBT_BASELINE
        self.baseline.parent.mkdir()

    def tearDown(self):
        self.directory.cleanup()

    def write(self, strings):
        self.catalog.write_text(json.dumps(catalog(strings), indent=2) + "\n", encoding="utf-8")

    def check(self, *arguments):
        output, errors = io.StringIO(), io.StringIO()
        argv = ["localization_catalog.py", "check", "--root", str(self.root), *arguments]
        with patch.object(sys, "argv", argv), contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
            status = MODULE.main()
        return status, output.getvalue() + errors.getvalue()

    def review(self, english):
        return string(english, de=(f"{english} (de)", "needs_review"))

    def copied(self, english):
        return string(english, fr=(english, "translated"))

    def test_without_a_baseline_every_parity_error_fails(self):
        self.write({"open": self.review("Open")})
        status, output = self.check()
        self.assertEqual(status, 1)
        self.assertIn("1 parity errors", output)

    def test_debt_within_the_baseline_passes(self):
        self.write({"open": self.review("Open"), "close": string("Close")})
        self.assertEqual(self.check("--write-baseline")[0], 0)
        status, output = self.check()
        self.assertEqual(status, 0, output)
        self.assertIn("within the debt baseline", output)

    def test_new_copied_english_in_a_listed_catalog_fails(self):
        self.write({"open": self.copied("Open")})
        self.check("--write-baseline")
        self.write({"open": self.copied("Open"), "close": self.copied("Close")})
        status, output = self.check()
        self.assertEqual(status, 1)
        self.assertIn("identical 1 -> 2", output)
        self.assertIn("close:fr", output)

    def test_new_strings_awaiting_review_are_reported_not_failed(self):
        # cmux NEXT adds machine translations as needs_review (check-l10n.sh counts them present).
        self.write({"open": self.review("Open")})
        self.check("--write-baseline")
        self.write({"open": self.review("Open"), "close": self.review("Close")})
        status, output = self.check()
        self.assertEqual(status, 0, output)
        self.assertIn("note: more strings await review than the baseline records", output)
        self.assertIn("needs_review 1 -> 2", output)

    def test_a_new_kind_of_debt_fails_even_when_the_total_drops(self):
        self.write({"open": self.review("Open"), "close": self.review("Close")})
        self.check("--write-baseline")
        self.write({"open": self.copied("Open"), "close": string("Close")})
        status, output = self.check()
        self.assertEqual(status, 1)
        self.assertIn("identical 0 -> 1", output)

    def test_debt_in_a_catalog_the_baseline_does_not_list_fails(self):
        self.write({"open": string("Open")})
        self.check("--write-baseline")
        other = self.root / "Resources/Other.xcstrings"
        other.parent.mkdir()
        other.write_text(json.dumps(catalog({"save": self.copied("Save")})), encoding="utf-8")
        status, output = self.check()
        self.assertEqual(status, 1)
        self.assertIn("Resources/Other.xcstrings: identical 0 -> 1", output)

    def test_write_baseline_lowers_counts_and_refuses_to_raise_them(self):
        area = "Packages/macOS/CmuxNext/Sources/Area/Localizable.xcstrings"
        self.write({"open": self.copied("Open"), "close": self.copied("Close")})
        self.check("--write-baseline")
        self.write({"open": self.copied("Open")})
        status, output = self.check()
        self.assertEqual(status, 0, output)
        self.assertIn("below the baseline", output)
        self.assertEqual(self.check("--write-baseline")[0], 0)
        counts = json.loads(self.baseline.read_text(encoding="utf-8"))["catalogs"]
        self.assertEqual(counts, {area: {"identical": 1}})
        self.write({"open": self.copied("Open"), "close": self.copied("Close")})
        status, output = self.check("--write-baseline")
        self.assertEqual(status, 1)
        self.assertIn("refusing to raise", output)
        self.assertEqual(json.loads(self.baseline.read_text(encoding="utf-8"))["catalogs"], counts)

    def test_write_baseline_never_raises_the_review_count_either(self):
        area = "Packages/macOS/CmuxNext/Sources/Area/Localizable.xcstrings"
        self.write({"open": self.review("Open"), "close": self.copied("Close")})
        self.check("--write-baseline")
        # A cleanup of the copied English lands while new strings arrive for review.
        self.write({"open": self.review("Open"), "save": self.review("Save"), "close": string("Close")})
        self.assertEqual(self.check("--write-baseline")[0], 0)
        self.assertEqual(json.loads(self.baseline.read_text(encoding="utf-8"))["catalogs"],
                         {area: {"needs_review": 1}})

    def test_a_baseline_raised_above_the_bases_fails(self):
        self.write({"open": self.copied("Open")})
        self.check("--write-baseline")
        base = self.root / "base-baseline.json"
        base.write_text(self.baseline.read_text(encoding="utf-8"), encoding="utf-8")
        self.write({"open": self.copied("Open"), "close": self.copied("Close")})
        # A hand edit that raises the baseline to fit new debt.
        self.baseline.write_text(MODULE.debt_json(MODULE.debt_counts(
            [("Packages/macOS/CmuxNext/Sources/Area/Localizable.xcstrings", "identical to English")] * 2)),
            encoding="utf-8")
        self.assertEqual(self.check()[0], 0)
        status, output = self.check("--base-baseline", str(base))
        self.assertEqual(status, 1)
        self.assertIn("may only go down", output)

    def test_a_moved_catalog_keeps_its_debt_and_the_bases_baseline(self):
        # B1 (ba5e6df99f9) moved catalogs between packages: the ratchet read each as new debt
        # at the new path and as a baseline raised above the base's.
        self.write({"open": self.copied("Open"), "close": self.review("Close")})
        self.check("--write-baseline")
        base = self.root / "base-baseline.json"
        base.write_text(self.baseline.read_text(encoding="utf-8"), encoding="utf-8")
        moved = self.root / "Packages/macOS/CmuxNext/Sources/Other/Localizable.xcstrings"
        moved.parent.mkdir(parents=True)
        self.catalog.rename(moved)
        self.assertEqual(self.check("--write-baseline")[0], 0)
        self.assertEqual(json.loads(self.baseline.read_text(encoding="utf-8"))["catalogs"],
                         {"Packages/macOS/CmuxNext/Sources/Other/Localizable.xcstrings":
                          {"identical": 1, "needs_review": 1}})
        status, output = self.check("--base-baseline", str(base))
        self.assertEqual(status, 0, output)
        self.assertIn("keeps the base's baseline", output)
        # A moved catalog still may not grow, and a key whose file stays is not a move.
        moved.write_text(json.dumps(catalog({"open": self.copied("Open"), "save": self.copied("Save")})),
                         encoding="utf-8")
        self.assertEqual(self.check("--base-baseline", str(base))[0], 1)

    def test_a_baseline_key_whose_file_is_still_there_is_not_a_move(self):
        self.write({"open": self.copied("Open")})
        self.check("--write-baseline")
        base = self.root / "base-baseline.json"
        base.write_text(self.baseline.read_text(encoding="utf-8"), encoding="utf-8")
        copy = self.root / "Packages/macOS/CmuxNext/Sources/Other/Localizable.xcstrings"
        copy.parent.mkdir(parents=True)
        copy.write_text(self.catalog.read_text(encoding="utf-8"), encoding="utf-8")
        # A hand edit that moves the key to the copy while the old file stays in the tree.
        self.baseline.write_text(MODULE.debt_json({str(copy.relative_to(self.root)): {"identical": 1}}),
                                 encoding="utf-8")
        status, output = self.check("--base-baseline", str(base))
        self.assertEqual(status, 1)
        self.assertNotIn("keeps the base's baseline", output)

    def moved_base(self, strings):
        """A base tree holding the catalog with STRINGS, its baseline, and the same baseline here."""
        self.write(strings)
        self.check("--write-baseline")
        arguments = self.write_base(strings)
        return arguments

    def test_an_unrelated_same_named_catalog_does_not_inherit_a_deleted_catalogs_debt(self):
        # Most catalogs are Localizable.xcstrings: deleting one package's catalog and adding an
        # unrelated one with new untranslated strings must not move the old allowance to it.
        arguments = self.moved_base({"open": self.copied("Open"), "close": self.copied("Close")})
        self.catalog.unlink()
        other = self.root / "Packages/macOS/CmuxNext/Sources/Other/Localizable.xcstrings"
        other.parent.mkdir(parents=True)
        other.write_text(json.dumps(catalog({"rename": self.copied("Rename"), "share": self.copied("Share")})),
                         encoding="utf-8")
        # The hand-moved baseline the loophole needs: the old counts under the new path.
        self.baseline.write_text(MODULE.debt_json({str(other.relative_to(self.root)): {"identical": 2}}),
                                 encoding="utf-8")
        status, output = self.check(*arguments)
        self.assertEqual(status, 1, output)
        self.assertNotIn("keeps the base's baseline", output)
        self.assertIn("may only go down", output)

    def test_a_moved_catalog_proven_by_the_base_tree_keeps_its_baseline(self):
        arguments = self.moved_base({"open": self.copied("Open"), "close": self.copied("Close")})
        moved = self.root / "Packages/macOS/CmuxNext/Sources/Other/Localizable.xcstrings"
        moved.parent.mkdir(parents=True)
        self.catalog.rename(moved)
        # Edited on the way (one string translated): still the same catalog.
        moved.write_text(json.dumps(catalog({"open": self.copied("Open"),
                                             "close": string("Close", fr=("Fermer", "translated"))})),
                         encoding="utf-8")
        self.assertEqual(self.check("--write-baseline")[0], 0)
        status, output = self.check(*arguments)
        self.assertEqual(status, 0, output)
        self.assertIn("keeps the base's baseline", output)

    def write_base(self, strings):
        """The base tree's catalog and, as the base's baseline, a copy of the current baseline."""
        base = self.root / "base"
        path = base / self.catalog.relative_to(self.root)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(catalog(strings), indent=2) + "\n", encoding="utf-8")
        # The base's ratchet and metadata, unchanged by the pull request.
        (base / "scripts").mkdir(exist_ok=True)
        for name in MODULE.RULE_FILES:
            (base / "scripts" / name).write_bytes((ROOT / "scripts" / name).read_bytes())
        base_baseline = self.root / "base-baseline.json"
        base_baseline.write_text(self.baseline.read_text(encoding="utf-8"), encoding="utf-8")
        return ["--base-root", str(base), "--base-baseline", str(base_baseline)]

    def test_debt_the_base_already_has_is_a_warning_not_the_pull_requests_failure(self):
        # #23770 copied English into feat-cmux-next (identical 38 -> 39) and every pull
        # request merged with that base went red for it (#23877).
        self.write({"open": self.copied("Open")})
        self.check("--write-baseline")
        self.write({"open": self.copied("Open"), "close": self.copied("Close")})
        base_arguments = self.write_base({"open": self.copied("Open"), "close": self.copied("Close")})
        status, output = self.check(*base_arguments)
        self.assertEqual(status, 0, output)
        self.assertIn("warning: the base is already over its baseline", output)
        self.assertIn("identical 1 -> 2", output)

    def test_debt_a_pull_request_adds_on_top_of_a_red_base_still_fails(self):
        self.write({"open": self.copied("Open")})
        self.check("--write-baseline")
        self.write({"open": self.copied("Open"), "close": self.copied("Close"), "save": self.copied("Save")})
        base_arguments = self.write_base({"open": self.copied("Open"), "close": self.copied("Close")})
        status, output = self.check(*base_arguments)
        self.assertEqual(status, 1, output)
        self.assertIn("identical 2 -> 3", output)
        self.assertIn("save:fr", output)

    def test_a_base_within_the_baseline_does_not_excuse_new_debt(self):
        self.write({"open": self.copied("Open")})
        self.check("--write-baseline")
        self.write({"open": self.copied("Open"), "close": self.copied("Close")})
        base_arguments = self.write_base({"open": self.copied("Open")})
        status, output = self.check(*base_arguments)
        self.assertEqual(status, 1, output)
        self.assertIn("identical 1 -> 2", output)
        self.assertNotIn("warning", output)

    def test_a_baseline_lowered_below_the_merged_count_still_fails(self):
        # The base is within its own baseline; the pull request lowers the baseline under
        # the debt it still has, so this is the pull request's red, not the base's.
        self.write({"open": self.copied("Open"), "close": self.copied("Close")})
        self.check("--write-baseline")
        base_arguments = self.write_base({"open": self.copied("Open"), "close": self.copied("Close")})
        self.baseline.write_text(MODULE.debt_json(MODULE.debt_counts(
            [("Packages/macOS/CmuxNext/Sources/Area/Localizable.xcstrings", "identical to English")])),
            encoding="utf-8")
        status, output = self.check(*base_arguments)
        self.assertEqual(status, 1, output)
        self.assertIn("identical 1 -> 2", output)
        self.assertNotIn("warning", output)

    def test_a_change_to_the_rules_gets_no_allowance_for_base_debt(self):
        # Base debt is counted with the pull request's rules; if they differ from the base's
        # (an omission record removed, a check tightened), newly flagged strings would look
        # like the base's debt and the next push would go red.
        self.write({"open": self.copied("Open")})
        self.check("--write-baseline")
        self.write({"open": self.copied("Open"), "close": self.copied("Close")})
        base_arguments = self.write_base({"open": self.copied("Open"), "close": self.copied("Close")})
        omissions = self.root / "base" / "scripts" / "localization-allowed-omissions.json"
        omissions.write_bytes(omissions.read_bytes() + b"\n")
        status, output = self.check(*base_arguments)
        self.assertEqual(status, 1, output)
        self.assertIn("identical 1 -> 2", output)
        self.assertIn("changes localization-allowed-omissions.json", output)
        self.assertNotIn("warning", output)

    def test_the_base_tree_needs_the_bases_baseline(self):
        self.write({"open": string("Open")})
        self.check("--write-baseline")
        with self.assertRaises(SystemExit):
            self.check("--base-root", str(self.root))

    def test_the_checked_in_baseline_loads(self):
        path = ROOT / "scripts" / MODULE.DEBT_BASELINE
        if path.exists():
            self.assertIsInstance(MODULE.load_debt_baseline(path), dict)


if __name__ == "__main__":
    unittest.main()
