#!/usr/bin/env python3
"""scripts/localization_fill.py: the bot that fills the non-source locales on main, and the relaxed
per-PR check (scripts/localization_catalog.py check defers those locales; --strict and extract do not)."""

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("localization_fill", ROOT / "scripts/localization_fill.py")
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)
CATALOG = MODULE.CATALOG


def unit(value, state="translated"):
    return {"stringUnit": {"state": state, "value": value}}


def write(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def git(repo: Path, *argv: str) -> str:
    return subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@example.com", *argv], cwd=repo,
                          check=True, capture_output=True, text=True).stdout


ALL_MACOS = {"en": "Open", "de": "Öffnen", "fr": "Ouvrir", "ar": "فتح", "es": "Abrir", "zh-Hant": "開啟",
             "zh-Hans": "打开", "ko": "열기", "ja": "開く"}


class LocalizationFillTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.repo = Path(self.temporary.name)
        git(self.repo, "init", "--quiet")
        (self.repo / "web/i18n").mkdir(parents=True)
        (self.repo / "web/i18n/routing.ts").write_text('export const locales = [\n  "en",\n  "ja",\n  "de",\n] as const;\n')
        write(self.repo / "web/messages/en.json", {"nav": {"home": "Home", "docs": "Docs"}, "pricing": {"title": "Pricing"}})
        write(self.repo / "web/messages/ja.json", {"nav": {"home": "ホーム", "docs": "ドキュメント"}, "pricing": {"title": "料金"}})
        write(self.repo / "web/messages/de.json", {"nav": {"home": "Startseite", "docs": "Dokumentation"}})
        self.catalog = self.repo / "Resources/Localizable.xcstrings"
        write(self.catalog, {"sourceLanguage": "en", "strings": {
            "open": {"localizations": {locale: unit(value) for locale, value in ALL_MACOS.items()}}}, "version": "1.0"})
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "--quiet", "-m", "base")
        self.base = git(self.repo, "rev-parse", "HEAD").strip()
        write(self.repo / MODULE.STATE, {"filledThrough": self.base, "englishOnly": {"*": ["pricing"]}})

    def tearDown(self):
        self.temporary.cleanup()

    def pr_adds_english_only(self):
        """What a pull request does now: English (and Japanese) only, and an English edit."""
        write(self.repo / "web/messages/en.json",
              {"nav": {"home": "Home", "blog": "Blog", "docs": "Documentation"}, "pricing": {"title": "Pricing", "vm": "VMs"}})
        strings = json.loads(self.catalog.read_text())
        strings["strings"]["close"] = {"localizations": {"en": unit("Close %@"), "ja": unit("%@を閉じる")}}
        write(self.catalog, strings)
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "--quiet", "-m", "pr")

    def test_check_defers_bot_locales_but_extract_and_strict_do_not(self):
        self.pr_adds_english_only()
        entry = next(e for e in CATALOG.catalog_entries(self.catalog.read_text()) if e.key == "close")
        self.assertEqual(CATALOG.check_entry(entry, "de", {}, {}, CATALOG.BOT_LOCALES), [])
        self.assertEqual(CATALOG.check_entry(entry, "de", {}, {}), ["missing locale entry"])
        # The source locales stay required in every pull request.
        missing_ja = json.loads(json.dumps(entry.value))
        del missing_ja["localizations"]["ja"]
        self.assertEqual(CATALOG.check_entry(CATALOG.Member("close", missing_ja, 0, 0), "ja", {}, {}, CATALOG.BOT_LOCALES),
                         ["missing locale entry"])
        # A present bot-locale value is still validated; only "not filled yet" is deferred.
        broken = json.loads(json.dumps(entry.value))
        broken["localizations"]["de"] = unit("Schließen")
        self.assertIn("placeholders", " ".join(CATALOG.check_entry(CATALOG.Member("close", broken, 0, 0), "de", {}, {},
                                                                   CATALOG.BOT_LOCALES)))
        pending = json.loads(json.dumps(entry.value))
        pending["localizations"]["de"] = unit("%@ schließen", "needs_review")
        self.assertEqual(CATALOG.check_entry(CATALOG.Member("close", pending, 0, 0), "de", {}, {}, CATALOG.BOT_LOCALES), [])

    def test_gaps_lists_new_and_stale_keys_and_skips_english_only(self):
        self.pr_adds_english_only()
        packet = MODULE.gaps(self.repo, self.repo / "packet.json", None, 100)
        web = {(row["locale"], row["key"]): row for row in packet["entries"] if row["kind"] == "web"}
        self.assertEqual(set(web), {("de", "nav.blog"), ("de", "nav.docs")})
        self.assertEqual(web[("de", "nav.docs")]["current"], "Dokumentation")
        macos = {(row["locale"], row["key"]) for row in packet["entries"] if row["kind"] == "macos"}
        self.assertEqual(macos, {(locale, "close") for locale in CATALOG.BOT_LOCALES})
        self.assertTrue(packet["complete"])

    def test_apply_writes_valid_translations_in_english_order_and_rejects_broken_ones(self):
        self.pr_adds_english_only()
        packet = MODULE.gaps(self.repo, self.repo / "packet.json", None, 100)
        ids = {(row["locale"], row["key"]): row["id"] for row in packet["entries"]}
        answer = {"translations": [
            {"id": str(ids[("de", "nav.blog")]), "value": "Blog"},  # ids match as integers or strings
            {"id": ids[("de", "nav.docs")], "value": "Doku"},
            {"id": ids[("de", "close")], "value": "%@ schließen"},
            {"id": ids[("fr", "close")], "value": "Fermer"},  # drops the placeholder: rejected
        ]}
        result = MODULE.apply(self.repo, packet, answer)
        self.assertEqual(result["applied"], 3)
        self.assertEqual(len(result["rejected"]), 1)
        text = (self.repo / "web/messages/de.json").read_text()
        self.assertEqual(list(json.loads(text)["nav"]), ["home", "blog", "docs"])
        self.assertEqual(json.loads(text)["nav"]["docs"], "Doku")
        self.assertTrue(text.endswith("}\n"))
        localizations = json.loads(self.catalog.read_text())["strings"]["close"]["localizations"]
        self.assertEqual(localizations["de"], unit("%@ schließen"))
        self.assertNotIn("fr", localizations)
        # Incomplete (a rejection): filledThrough stays so the stale rows come back next run.
        self.assertEqual(json.loads((self.repo / MODULE.STATE).read_text())["filledThrough"], self.base)

    def test_web_problems_guard_icu_arguments_and_tags(self):
        self.assertEqual(MODULE.web_problems("Hi {name}", "Hallo {name}"), [])
        self.assertIn("ICU arguments differ from English", MODULE.web_problems("Hi {name}", "Hallo {nom}"))
        self.assertIn("rich-text tags differ from English", MODULE.web_problems("<b>Hi</b>", "Hallo"))
        self.assertIn("array length differs from English", MODULE.web_problems(["a", "b"], ["a"]))


if __name__ == "__main__":
    unittest.main()
