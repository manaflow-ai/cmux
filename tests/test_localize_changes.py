#!/usr/bin/env python3

import contextlib
import importlib.util
import io
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import git_fixture_env  # noqa: F401  (disables git auto maintenance)

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
    def test_key_only_call_cannot_steal_next_default(self):
        messages, attention = MODULE.parse_swift_messages(
            "Sources/View.swift",
            'String(localized: "bare")\nString(localized: "other", defaultValue: "Other")',
        )
        self.assertEqual({key: value.source for key, value in messages.items()}, {"other": "Other"})
        self.assertTrue(any("cannot safely prepare" in item for item in attention))

    def test_import_validates_all_catalog_locale_groups_before_writing(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = write_catalog(root, {"open": {"localizations": {"en": unit("Open %@")}}})
            original = path.read_bytes()
            packet = {"entries": [{
                "catalog": "Resources/Localizable.xcstrings", "key": "open", "source": "Open %@",
                "locale": locale, "value": value,
            } for locale, value in [("de", "Öffnen %@"), ("fr", "Ouvrir")]]}
            with self.assertRaises(ValueError):
                MODULE.apply_completed(root, packet, {})
            self.assertEqual(path.read_bytes(), original)

    def test_partial_array_translation_keeps_stale_element_visible(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "web/messages").mkdir(parents=True)
            (root / "web/messages/en.json").write_text(json.dumps({"items": ["New first", "New second"]}))
            (root / "web/messages/ja.json").write_text(json.dumps({"items": ["新しい一", "古い二"]}))
            previous = {"web/messages/en.json": {"items": ["Old first", "Old second"]},
                        "web/messages/ja.json": {"items": ["古い一", "古い二"]}}
            with patch.object(MODULE, "base_json", side_effect=lambda root, base, path: previous[path]):
                rows, attention, _ = MODULE.web_work(root, "base", ["web/messages/en.json"], ("en", "ja"))
            self.assertEqual(len(rows), 1)
            self.assertIn("unchanged", rows[0]["issues"][0])
            self.assertEqual(attention, [])

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

    def test_swift_source_change_preserves_completed_translations(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = write_catalog(root, {"open": {"localizations": {
                "en": unit("Open"), "de": unit("Öffnen"), "ja": unit("開く"),
            }}})
            old = path.read_text()
            strings = json.loads(old)["strings"]
            strings["open"]["localizations"]["ja"] = unit("ファイルを開く")
            write_catalog(root, strings)
            message = MODULE.SwiftMessage("Sources/View.swift", "open", "Open File")
            prepared = MODULE.prepare_macos(root, [message], None, {})
            with patch.object(MODULE, "base_text", return_value=old):
                MODULE.changed_catalog_keys(root, "base", [str(path.relative_to(root))])
            values = json.loads(path.read_text())["strings"]["open"]["localizations"]
            self.assertEqual(values["ja"], unit("ファイルを開く"))
            self.assertEqual(values["de"], unit("Öffnen", "needs_review"))
            self.assertEqual(values["en"], unit("Open File"))

    def test_cross_file_conflicting_defaults_do_not_mutate_catalog(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = write_catalog(root, {})
            before = path.read_bytes()
            messages = [MODULE.SwiftMessage("Sources/A.swift", "shared", "First"),
                        MODULE.SwiftMessage("Sources/B.swift", "shared", "Second")]
            result = MODULE.prepare_macos(root, messages, None, {})
            self.assertTrue(any("multiple default values" in item for item in result.attention))
            self.assertEqual(path.read_bytes(), before)
            self.assertEqual(result.changed_keys, [])

    def test_web_parity_for_locale_routing_and_english_deletions(self):
        cases = [
            (["web/messages/ja.json"], {"title": "Title"}, {}, "title"),
            (["web/messages/ja.json"], {"title": "Title"}, {"renamed": "題名"}, "renamed"),
            (["web/i18n/routing.ts"], {"title": "Title"}, {}, "title"),
            (["web/messages/en.json"], {}, {"title": "題名"}, "title"),
        ]
        for paths, english, japanese, key in cases:
            with self.subTest(paths=paths, english=english, japanese=japanese), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                (root / "web/messages").mkdir(parents=True)
                for locale, data in [("en", english), ("ja", japanese)]:
                    (root / f"web/messages/{locale}.json").write_text(json.dumps(data))
                with patch.object(MODULE, "base_json", return_value={"title": "Title"}):
                    rows, attention, changed = MODULE.web_work(root, "base", paths, ("en", "ja"))
                self.assertTrue(any(row["key"] == key for row in rows) or any(key in item for item in attention))
                if not english:
                    self.assertEqual(changed, 1)

    def test_translator_comments_follow_default_value(self):
        for constructor in ['String(localized: ', 'LocalizedStringResource(']:
            with self.subTest(constructor=constructor), tempfile.TemporaryDirectory() as directory:
                text = constructor + '\"hello\", defaultValue: \"Hello\", bundle: .atURL(URL(string: \"file:///tmp\")!), comment: \"Greeting (shown at launch)\")'
                text += '\nString(localized: \"other\", defaultValue: \"Other\", comment: \"Other context\")'
                messages, attention = MODULE.parse_swift_messages("Sources/View.swift", text)
                self.assertEqual(attention, [])
                root = Path(directory)
                path = write_catalog(root, {})
                MODULE.prepare_macos(root, list(messages.values()), None, {})
                entries = json.loads(path.read_text())["strings"]
                self.assertEqual(entries["hello"]["comment"], "Greeting (shown at launch)")
                self.assertEqual(entries["other"]["comment"], "Other context")

    def test_packet_targets_validated_before_any_writes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = write_catalog(root, {"open": {"localizations": {"en": unit("Open")}}})
            outside = root / "outside.xcstrings"
            outside.write_bytes(path.read_bytes())
            link = root / "Resources/Linked.xcstrings"
            link.symlink_to(outside)
            valid = {"catalog": "Resources/Localizable.xcstrings", "key": "open",
                     "source": "Open", "locale": "de", "value": "Öffnen"}
            invalid = [{"locale": "xx"}, {"catalog": str(outside)},
                       {"catalog": "../outside.xcstrings"}, {"catalog": "outside.xcstrings"},
                       {"catalog": "Resources/Linked.xcstrings"}, {"key": None}, {"source": []}]
            before = path.read_bytes()
            for overrides in invalid:
                with self.subTest(overrides=overrides):
                    with self.assertRaises(ValueError):
                        MODULE.apply_completed(root, {"entries": [valid, {**valid, **overrides}]}, {})
                    self.assertEqual(path.read_bytes(), before)
                    self.assertEqual(outside.read_bytes(), before)

    def test_catalog_diff_parses_current_once_and_batches_edits(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            strings = {str(i): {"localizations": {"en": unit("Old"), "de": unit("Alt")}} for i in range(12)}
            path = write_catalog(root, strings)
            old = path.read_text()
            for record in strings.values():
                record["localizations"]["en"] = unit("New")
            write_catalog(root, strings)
            current = path.read_text()
            with patch.object(MODULE, "base_text", return_value=old), patch.object(CATALOG, "catalog_entries", wraps=CATALOG.catalog_entries) as parse:
                result = MODULE.changed_catalog_keys(root, "base", [str(path.relative_to(root))])
            self.assertEqual(sum(call.args[0] == current for call in parse.call_args_list), 1)
            self.assertLessEqual(parse.call_count, 3)  # base, current, optional final validation
            self.assertEqual(result.stale, 12)
            for record in json.loads(path.read_text())["strings"].values():
                self.assertEqual(record["localizations"]["de"], unit("Alt", "needs_review"))

    def test_conflicting_default_at_unchanged_call_site_is_reported_not_picked(self):
        changed = 'let a = String(localized: "shared", defaultValue: "First")\n'
        untouched = 'let b = String(localized: "shared", defaultValue: "Second")\n'
        for paths in (["Sources/A.swift"], ["Sources/A.swift", "Sources/B.swift"]):
            with self.subTest(paths=paths), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                subprocess.run(["git", "init", "-q", str(root)], check=True)
                (root / "Sources").mkdir()
                (root / "Sources/A.swift").write_text(changed, encoding="utf-8")
                (root / "Sources/B.swift").write_text(untouched, encoding="utf-8")
                base = {"Sources/B.swift": untouched}
                with patch.object(MODULE, "base_text", side_effect=lambda _root, _base, path: base.get(path, "")):
                    messages, attention = MODULE.changed_swift_messages(root, "base", paths)
                self.assertEqual([message for message in messages if message.key == "shared"], [])
                conflicts = [item for item in attention if "multiple default values" in item]
                self.assertEqual(len(conflicts), 1)
                self.assertIn("Sources/A.swift", conflicts[0])
                self.assertIn("Sources/B.swift", conflicts[0])

    def test_same_file_conflicting_defaults_are_not_prepared(self):
        text = ('String(localized: "shared", defaultValue: "First")\n'
                'String(localized: "shared", defaultValue: "Second")\n'
                'String(localized: "shared", defaultValue: "First")\n'
                'String(localized: "other", defaultValue: "Other")\n')
        messages, attention = MODULE.parse_swift_messages("Sources/View.swift", text)
        self.assertEqual(sorted(messages), ["other"])
        self.assertEqual(attention, ["Sources/View.swift: localization key 'shared' has multiple default values"])

    def test_repeated_key_with_same_default_needs_no_attention(self):
        text = ('String(localized: "shared", defaultValue: "Same")\n'
                'LocalizedStringResource("shared", defaultValue: "Same")\n')
        messages, attention = MODULE.parse_swift_messages("Sources/View.swift", text)
        self.assertEqual(sorted(messages), ["shared"])
        self.assertEqual(attention, [])
        _, attention = MODULE.parse_swift_messages("Sources/View.swift", text + 'String(localized: "bare")\n')
        self.assertEqual(len(attention), 1)
        self.assertIn("1 localized call(s)", attention[0])

    def test_web_parity_covers_non_string_messages(self):
        english = {"title": "Title", "jobs": {"items": ["One", {"label": "Two"}]}}
        cases = [
            ({"title": "題名"}, english, "missing message key"),
            ({"title": "題名", "jobs": {"items": ["古い"]}}, {"title": "Title", "jobs": {"items": ["Old"]}}, "unchanged"),
        ]
        for japanese, previous_english, issue in cases:
            with self.subTest(issue=issue), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                (root / "web/messages").mkdir(parents=True)
                (root / "web/messages/en.json").write_text(json.dumps(english), encoding="utf-8")
                (root / "web/messages/ja.json").write_text(json.dumps(japanese, ensure_ascii=False), encoding="utf-8")
                old = {
                    "web/messages/en.json": json.dumps(previous_english),
                    "web/messages/ja.json": json.dumps({"title": "題名", "jobs": {"items": ["古い"]}}, ensure_ascii=False),
                }
                with patch.object(MODULE, "base_text", side_effect=lambda _root, _base, path: old.get(path, "")):
                    rows, attention, _ = MODULE.web_work(root, "base", ["web/messages/ja.json"], ("en", "ja"))
                self.assertEqual(attention, [])
                self.assertEqual([(row["key"], row["source"]) for row in rows], [("jobs.items", english["jobs"]["items"])])
                self.assertIn(issue, rows[0]["issues"][0])

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "web/messages").mkdir(parents=True)
            (root / "web/messages/en.json").write_text(json.dumps({"title": "Title"}), encoding="utf-8")
            (root / "web/messages/ja.json").write_text(json.dumps({"title": "題名", "items": ["余分"]}, ensure_ascii=False), encoding="utf-8")
            with patch.object(MODULE, "base_text", return_value=""):
                _, attention, _ = MODULE.web_work(root, "base", ["web/messages/ja.json"], ("en", "ja"))
            self.assertTrue(any("extra message key 'items'" in item for item in attention))

    def test_confirmed_unchanged_translation_is_not_marked_stale_again(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            relative = "Resources/Localizable.xcstrings"
            localizations = {locale: unit("Opne" if locale == "en" else f"Öffnen {locale}") for locale in CATALOG.LOCALES}
            path = write_catalog(root, {"open": {"localizations": localizations}})
            old = path.read_text(encoding="utf-8")
            write_catalog(root, {"open": {"localizations": {**localizations, "en": unit("Open")}}})
            (root / "web/messages").mkdir(parents=True)
            (root / "web/messages/en.json").write_text("{}", encoding="utf-8")
            work = root / "work.json"
            patches = [
                patch.object(MODULE, "resolve_root", return_value=root),
                patch.object(MODULE, "resolve_base", return_value="abc123"),
                patch.object(MODULE, "changed_files", return_value=[relative]),
                patch.object(MODULE, "base_text", side_effect=lambda _root, _base, name: old if name == relative else ""),
                patch.object(MODULE.CATALOG, "load_metadata", return_value={}),
                patch.object(MODULE, "discover_web_locales", return_value=("en",)),
                patch.object(MODULE, "run_validator", return_value=(0, "", "")),
            ]

            def run():
                with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                    return MODULE.main(["--work-file", str(work)])

            def states():
                record = json.loads(path.read_text(encoding="utf-8"))["strings"]["open"]["localizations"]
                return {locale: value["stringUnit"]["state"] for locale, value in record.items()}

            for manager in patches:
                manager.start()
            try:
                self.assertEqual(run(), 1)
                self.assertEqual(states()["de"], "needs_review")
                packet = json.loads(work.read_text(encoding="utf-8"))
                self.assertEqual(len(packet["entries"]), len(CATALOG.LOCALES) - 1)
                for row in packet["entries"]:
                    current = row["currentLocalization"]["stringUnit"]["value"]
                    # German stays correct after the English typo fix; the others are retranslated.
                    row["value"] = current if row["locale"] == "de" else current + " neu"
                work.write_text(json.dumps(packet, ensure_ascii=False), encoding="utf-8")
                self.assertEqual(run(), 0)
                self.assertEqual(set(states().values()), {"translated"})
                self.assertEqual(run(), 0)
                self.assertEqual(set(states().values()), {"translated"})

                # A confirmation covers only the confirmed value: restoring the base text stales it again.
                write_catalog(root, {"open": {"localizations": {**localizations, "en": unit("Open")}}})
                self.assertEqual(run(), 1)
                self.assertEqual({locale for locale, state in states().items() if state == "translated"}, {"en", "de"})
            finally:
                for manager in reversed(patches):
                    manager.stop()

    def test_prepare_and_extract_parse_each_catalog_once(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = write_catalog(root, {f"old.{i}": {"localizations": {"en": unit("Old"), "de": unit("Alt")}} for i in range(12)})
            messages = [MODULE.SwiftMessage("Sources/View.swift", f"old.{i}", "Changed") for i in range(12)]
            messages += [MODULE.SwiftMessage("Sources/View.swift", f"new.{i}", f"New {i}", f"Comment {i}") for i in range(12)]
            with patch.object(CATALOG, "catalog_entries", wraps=CATALOG.catalog_entries) as parse:
                prepared = MODULE.prepare_macos(root, messages, None, {})
            self.assertLessEqual(parse.call_count, 2)  # one index parse, one validation of the batched write
            self.assertEqual(prepared.attention, [])
            self.assertEqual(prepared.prepared, 12)
            self.assertEqual(sorted(prepared.changed_keys), sorted((path, message.key) for message in messages))
            strings = json.loads(path.read_text(encoding="utf-8"))["strings"]
            self.assertEqual(list(strings), [f"old.{i}" for i in range(12)] + [f"new.{i}" for i in range(12)])
            for i in range(12):
                self.assertEqual(strings[f"old.{i}"]["localizations"], {"en": unit("Changed"), "de": unit("Alt")})
                self.assertEqual(strings[f"new.{i}"], {
                    "comment": f"Comment {i}", "extractionState": "manual", "localizations": {"en": unit(f"New {i}")},
                })
            with patch.object(CATALOG, "catalog_entries", wraps=CATALOG.catalog_entries) as parse:
                rows = MODULE.extract_changed(root, prepared.changed_keys, {}, {}, {})
            self.assertEqual(parse.call_count, 1)
            self.assertEqual({row["key"] for row in rows}, {message.key for message in messages})

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
