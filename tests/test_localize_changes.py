#!/usr/bin/env python3

import contextlib
import importlib.util
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("localize_changes", ROOT / "scripts/localize_changes.py")
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)
CATALOG = MODULE.CATALOG


def unit(value, state="translated"):
    return {"stringUnit": {"state": state, "value": value}}


def counted(parent, variants, specifier="d"):
    return {
        **unit(parent),
        "substitutions": {
            "count": {
                "argNum": 1,
                "formatSpecifier": specifier,
                "variations": {"plural": variants},
            }
        },
    }


def write_catalog(root: Path, strings: dict) -> Path:
    path = root / "Resources/Localizable.xcstrings"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({
        "sourceLanguage": "en",
        "strings": strings,
        "version": "1.0",
    }, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return path


class LocalizeChangesTests(unittest.TestCase):
    def test_discovers_locales_from_authoritative_sources(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            routing = root / "web/i18n/routing.ts"
            routing.parent.mkdir(parents=True)
            routing.write_text('export const locales = ["en", "ja", "fr", "pt-BR"] as const;\n', encoding="utf-8")
            self.assertEqual(MODULE.discover_web_locales(root), ("en", "ja", "fr", "pt-BR"))
            self.assertEqual(MODULE.macos_locales(), tuple(CATALOG.LOCALES))

    def test_new_key_is_prepared_once_and_extracts_every_missing_locale(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = write_catalog(root, {})
            message = MODULE.SwiftMessage("Sources/NewView.swift", "feature.new.title", "New Feature")
            first = MODULE.prepare_macos(root, [message], None, {})
            self.assertEqual(first.prepared, 1)
            self.assertEqual(first.attention, [])
            prepared_text = path.read_text(encoding="utf-8")
            rows = MODULE.extract_changed(root, first.changed_keys, {}, {}, {})
            self.assertEqual({row["locale"] for row in rows}, set(MODULE.macos_locales()) - {"en"})
            self.assertTrue(all(row["source"] == "New Feature" for row in rows))

            second = MODULE.prepare_macos(root, [message], None, {})
            self.assertEqual(second.prepared, 0)
            self.assertEqual(path.read_text(encoding="utf-8"), prepared_text)

    def test_catalog_insert_is_minimal_and_deterministic(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = write_catalog(root, {
                "existing": {"comment": "keep exact", "localizations": {"en": unit("Existing"), "de": unit("Vorhanden")}},
            })
            before = path.read_text(encoding="utf-8")
            before_entry = CATALOG.catalog_entries(before)[0]
            raw_existing = before[before_entry.start:before_entry.end]
            MODULE.insert_catalog_entry(path, "added", "Added", "New label")
            once = path.read_text(encoding="utf-8")
            existing = next(entry for entry in CATALOG.catalog_entries(once) if entry.key == "existing")
            self.assertEqual(once[existing.start:existing.end], raw_existing)
            MODULE.insert_catalog_entry(path, "added", "Added", "New label")
            self.assertEqual(path.read_text(encoding="utf-8"), once)

    def test_import_uses_existing_placeholder_validation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_catalog(root, {"open": {"localizations": {"en": unit("Open %@")}}})
            invalid = {"version": 1, "entries": [{
                "catalog": "Resources/Localizable.xcstrings",
                "key": "open",
                "source": "Open %@",
                "locale": "de",
                "value": "Öffnen",
            }]}
            with self.assertRaises(ValueError):
                MODULE.apply_completed(root, invalid, {})
            valid = json.loads(json.dumps(invalid, ensure_ascii=False))
            valid["entries"][0]["value"] = "Öffnen %@"
            self.assertEqual(MODULE.apply_completed(root, valid, {}), 1)

    def test_new_count_like_key_requires_explicit_plural_authoring(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = write_catalog(root, {})
            message = MODULE.SwiftMessage("Sources/CountView.swift", "feature.files.count", "%d files")
            result = MODULE.prepare_macos(root, [message], None, {})
            self.assertEqual(result.prepared, 0)
            self.assertEqual(result.changed_keys, [])
            self.assertTrue(any("explicit plural catalog entry" in item for item in result.attention))
            self.assertEqual(CATALOG.catalog_entries(path.read_text(encoding="utf-8")), [])

    def test_import_uses_existing_plural_validation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            english = counted("%#@count@", {"one": unit("%d file"), "other": unit("%d files")})
            path = write_catalog(root, {"files": {"localizations": {"en": english}}})
            source = CATALOG.source(CATALOG.catalog_entries(path.read_text(encoding="utf-8"))[0].value)
            arabic = counted("%#@count@ ملف", {"one": unit("%d"), "other": unit("%d")})
            work = {"version": 1, "entries": [{
                "catalog": "Resources/Localizable.xcstrings",
                "key": "files",
                "source": source,
                "locale": "ar",
                "localization": arabic,
            }]}
            with self.assertRaisesRegex(ValueError, "plural categories"):
                MODULE.apply_completed(root, work, {})

    def test_changed_source_marks_only_unchanged_translations_stale(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            old_strings = {"open": {"localizations": {
                "en": unit("Open"),
                "de": unit("Öffnen"),
                "ja": unit("開く"),
            }}}
            old_text = json.dumps({"sourceLanguage": "en", "strings": old_strings, "version": "1.0"}, ensure_ascii=False, indent=2) + "\n"
            path = write_catalog(root, {"open": {"localizations": {
                "en": unit("Open File"),
                "de": unit("Öffnen"),
                "ja": unit("ファイルを開く"),
            }}})
            with patch.object(MODULE, "base_text", return_value=old_text):
                result = MODULE.changed_catalog_keys(root, "base", ["Resources/Localizable.xcstrings"])
            self.assertEqual(result.changed_keys, [(path, "open")])
            self.assertEqual(result.stale, 1)
            entry = CATALOG.catalog_entries(path.read_text(encoding="utf-8"))[0]
            localizations = entry.value["localizations"]
            self.assertEqual(localizations["de"]["stringUnit"], {"state": "needs_review", "value": "Öffnen"})
            self.assertEqual(localizations["ja"], unit("ファイルを開く"))
            rows = MODULE.extract_changed(root, [(path, "open")], {}, {}, {})
            de = next(row for row in rows if row["locale"] == "de")
            self.assertTrue(any("state" in issue for issue in de["issues"]))

    def test_web_changed_english_reports_missing_and_stale_locale_work(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "web/messages").mkdir(parents=True)
            (root / "web/messages/en.json").write_text(json.dumps({"home": {"title": "New title"}}), encoding="utf-8")
            (root / "web/messages/ja.json").write_text(json.dumps({"home": {"title": "新しいタイトル"}}), encoding="utf-8")
            (root / "web/messages/fr.json").write_text(json.dumps({"home": {"title": "Ancien titre"}}), encoding="utf-8")
            old = {
                "web/messages/en.json": json.dumps({"home": {"title": "Old title"}}),
                "web/messages/ja.json": json.dumps({"home": {"title": "古いタイトル"}}),
                "web/messages/fr.json": json.dumps({"home": {"title": "Ancien titre"}}),
            }
            with patch.object(MODULE, "base_text", side_effect=lambda _root, _base, path: old.get(path, "")):
                rows, attention, changed = MODULE.web_work(
                    root, "base", ["web/messages/en.json"], ("en", "ja", "fr", "pt-BR")
                )
            self.assertEqual(changed, 1)
            self.assertIn("web/messages/pt-BR.json: missing catalog declared by web/i18n/routing.ts", attention)
            self.assertEqual([(row["locale"], row["key"]) for row in rows], [("fr", "home.title")])
            self.assertIn("unchanged", rows[0]["issues"][0])

    def test_end_to_end_reports_failure_and_success(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            work = root / "work.json"
            common = [
                patch.object(MODULE, "resolve_root", return_value=root),
                patch.object(MODULE, "resolve_base", return_value="abc123"),
                patch.object(MODULE, "changed_files", return_value=[]),
                patch.object(MODULE, "default_work_path", return_value=work),
                patch.object(MODULE, "load_work", return_value={}),
                patch.object(MODULE.CATALOG, "load_metadata", return_value={}),
                patch.object(MODULE, "apply_completed", return_value=0),
                patch.object(MODULE, "changed_swift_messages", return_value=([], [])),
                patch.object(MODULE, "prepare_macos", return_value=MODULE.PreparationResult([], 0, 0, [])),
                patch.object(MODULE, "changed_catalog_keys", return_value=MODULE.PreparationResult([], 0, 0, [])),
                patch.object(MODULE, "discover_web_locales", return_value=("en", "ja")),
                patch.object(MODULE, "write_work"),
            ]
            for manager in common:
                manager.start()
            try:
                with patch.object(MODULE, "extract_changed", return_value=[{"locale": "de"}]), \
                     patch.object(MODULE, "web_work", return_value=([], [], 0)), \
                     patch.object(MODULE, "run_validator", return_value=(1, "1 catalogs, 9 locales: 1 parity errors", "missing locale")), \
                     contextlib.redirect_stdout(io.StringIO()) as stdout, contextlib.redirect_stderr(io.StringIO()) as stderr:
                    self.assertEqual(MODULE.main([]), 1)
                    self.assertIn("Outstanding macOS translation rows: 1", stderr.getvalue())
                    self.assertIn("Strict catalog validator", stdout.getvalue() + stderr.getvalue())

                with patch.object(MODULE, "extract_changed", return_value=[]), \
                     patch.object(MODULE, "web_work", return_value=([], [], 0)), \
                     patch.object(MODULE, "run_validator", return_value=(0, "1 catalogs, 9 locales: 0 parity errors", "")), \
                     contextlib.redirect_stdout(io.StringIO()) as stdout, contextlib.redirect_stderr(io.StringIO()):
                    self.assertEqual(MODULE.main([]), 0)
                    self.assertIn("Localization ready", stdout.getvalue())
            finally:
                for manager in reversed(common):
                    manager.stop()


if __name__ == "__main__":
    unittest.main()
