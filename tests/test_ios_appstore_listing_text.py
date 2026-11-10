#!/usr/bin/env python3
"""The App Store listing of the iOS app names only screens the app has.

The production lane (.github/workflows/ios-app-store.yml) pushes
ios/AppStoreReview/metadata with `asc metadata apply`; ios/fastlane/metadata holds
the same text per locale. On 2026-11-10 the en-US description still told
reviewers to "select Tailscale Only under Connection Method, use Add Computer,
open the App Review workspace": screens of the classic app, none of which the
NEXT app on feat-cmux-next has.

This test reads every locale's listing from both places and fails when:
  - a field is over its App Store limit, or the two copies of a locale differ;
  - any locale names a classic-only screen (CLASSIC_ONLY_TERMS);
  - the public description carries App Review instructions (they belong in the
    review notes);
  - a quoted screen name (any locale) is not a string the app shows;
  - an English capitalized phrase that is not a known product or platform name
    is not a string the app shows.

"Strings the app shows" are the string literals in the shipped app's Swift
sources (ios/CmuxiOS/Sources and ios/cmux) plus every value of their string
catalogs, leaving out debug-only code (Debug/, DevMenu, the gallery) and the
terminal module, which only the debug menu opens today. When a screen ships,
its strings join this set and a listing may name it.
"""

from __future__ import annotations

import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
IOS = ROOT / "ios"
ASC_METADATA = IOS / "AppStoreReview/metadata"
FASTLANE_METADATA = IOS / "fastlane/metadata"
APP_SOURCE_DIRS = (IOS / "CmuxiOS/Sources", IOS / "cmux")

# Paths under APP_SOURCE_DIRS whose strings a release build never shows.
NOT_SHIPPED = re.compile(
    r"/(Debug|Gallery|Mock|Tests)/|/CmuxiOSTerminal/|/(DevMenu|DevOptions|GalleryRunner|DebugLaunchTasks)\.swift$"
)

# Screens and settings of the classic iOS app that the NEXT app does not have.
CLASSIC_ONLY_TERMS = (
    "Connection Method",
    "Add Computer",
    "Tailscale Only",
    "App Review workspace",
)

# App Review instructions: the review notes carry these, never the public listing.
REVIEW_INSTRUCTION_TERMS = (
    "App Review",
    "Review Information",
    "demo account",
    "app-review-ok",
)

LIMITS = {"name": 30, "subtitle": 30, "keywords": 100, "promotional_text": 170, "description": 4000}

# Capitalized English words that are names of platforms, companies or examples, not app screens.
NON_SCREEN_NAMES = {
    "Apple", "Google", "GitHub", "Siri", "Shortcuts", "Action Button", "iPhone", "iPad", "Mac",
}

# Opening and closing quote pairs the listings use around a screen name.
QUOTED = re.compile(
    r'"([^"\n]{1,40})"'
    r"|“([^“”\n]{1,40})”"
    r"|„([^“”\n]{1,40})[“”]"
    r"|«\s?([^«»\n]{1,40}?)\s?»"
    r"|「([^「」\n]{1,40})」"
    r"|‘([^‘’\n]{1,40})’"
)
SWIFT_STRING = re.compile(r'"((?:[^"\\\n]|\\.)*)"')
CAPITALIZED_RUN = re.compile(r"(?<![\w-])[A-Z][\w-]*(?:\s+[A-Z][\w-]*)*")


def read_listings() -> dict[str, dict[str, dict[str, str]]]:
    """{source: {locale: {field: text}}} for the asc metadata and the fastlane copies."""
    asc: dict[str, dict[str, str]] = {}
    for path in sorted((ASC_METADATA / "app-info").glob("*.json")):
        info = json.loads(path.read_text(encoding="utf-8"))
        asc.setdefault(path.stem, {}).update(
            {"name": info.get("name", ""), "subtitle": info.get("subtitle", "")}
        )
    for path in sorted((ASC_METADATA / "version").glob("*/*.json")):
        data = json.loads(path.read_text(encoding="utf-8"))
        asc.setdefault(path.stem, {}).update(
            {
                "description": data.get("description", ""),
                "keywords": data.get("keywords", ""),
                "promotional_text": data.get("promotionalText", ""),
            }
        )
    fastlane: dict[str, dict[str, str]] = {}
    for locale_dir in sorted(p for p in FASTLANE_METADATA.iterdir() if p.is_dir()):
        fields = {}
        for field in LIMITS:
            path = locale_dir / f"{field}.txt"
            if path.exists():
                fields[field] = path.read_text(encoding="utf-8").strip()
        fastlane[locale_dir.name] = fields
    return {"asc": asc, "fastlane": fastlane}


def app_strings() -> set[str]:
    strings: set[str] = set()
    for base in APP_SOURCE_DIRS:
        for path in base.rglob("*"):
            if not path.is_file() or NOT_SHIPPED.search(path.as_posix()):
                continue
            if path.suffix == ".swift":
                for match in SWIFT_STRING.finditer(path.read_text(encoding="utf-8")):
                    strings.add(match.group(1))
            elif path.suffix == ".xcstrings":
                catalog = json.loads(path.read_text(encoding="utf-8"))
                for key, entry in catalog.get("strings", {}).items():
                    strings.add(key)
                    for loc in entry.get("localizations", {}).values():
                        value = loc.get("stringUnit", {}).get("value")
                        if value:
                            strings.add(value)
    return {s.strip() for s in strings if s.strip()}


def english_screen_candidates(text: str) -> set[tuple[str, ...]]:
    """Capitalized phrases in English prose, each with the readings that may name a screen.

    A phrase that opens a sentence may be a capitalized ordinary word followed by a
    screen name ("In Chat Server"), so it also reads without its first word; a lone
    capitalized first word is ordinary English and is skipped.
    """
    found = set()
    for line in text.splitlines():
        body = line.lstrip("-•· ").strip()
        for match in CAPITALIZED_RUN.finditer(body):
            phrase = match.group(0)
            before = body[: match.start()].rstrip()
            if not before or before[-1] in ".:!?":
                words = phrase.split()
                if len(words) == 1:
                    continue
                found.add((phrase, " ".join(words[1:])))
            else:
                found.add((phrase,))
    return found


def in_app(phrase: str, strings: set[str]) -> bool:
    pattern = re.compile(rf"(?<![\w-]){re.escape(phrase)}(?![\w-])")
    return any(pattern.search(s) for s in strings)


def named_in_app(readings: tuple[str, ...], strings: set[str]) -> bool:
    return any(r in NON_SCREEN_NAMES or in_app(r, strings) for r in readings)


class ListingTextTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.listings = read_listings()
        cls.strings = app_strings()

    def each_field(self):
        for source, locales in self.listings.items():
            for locale, fields in locales.items():
                for field, text in fields.items():
                    yield source, locale, field, text

    def test_sources_exist(self) -> None:
        self.assertIn("en-US", self.listings["asc"])
        self.assertIn("New Chief", self.strings, "the app string scan found no Home strings")

    def test_every_fastlane_locale_is_pushed_with_the_same_text(self) -> None:
        asc, fastlane = self.listings["asc"], self.listings["fastlane"]
        self.assertEqual(sorted(fastlane), sorted(asc), "a locale exists in only one of the two metadata trees")
        for locale, fields in fastlane.items():
            for field in ("description", "keywords", "promotional_text", "subtitle"):
                with self.subTest(locale=locale, field=field):
                    self.assertTrue(fields.get(field), f"{locale} has no fastlane {field}")
                    self.assertEqual(fields[field], asc[locale].get(field, "").strip())

    def test_limits(self) -> None:
        for source, locale, field, text in self.each_field():
            with self.subTest(source=source, locale=locale, field=field):
                self.assertLessEqual(len(text), LIMITS[field])

    def test_no_classic_only_screens(self) -> None:
        for source, locale, field, text in self.each_field():
            for term in CLASSIC_ONLY_TERMS:
                with self.subTest(source=source, locale=locale, field=field, term=term):
                    self.assertNotIn(term.lower(), text.lower())

    def test_no_review_instructions_in_public_text(self) -> None:
        for source, locale, field, text in self.each_field():
            for term in REVIEW_INSTRUCTION_TERMS:
                with self.subTest(source=source, locale=locale, field=field, term=term):
                    self.assertNotIn(term.lower(), text.lower())

    def test_quoted_screen_names_are_app_strings(self) -> None:
        for source, locale, field, text in self.each_field():
            for match in QUOTED.finditer(text):
                name = next(g for g in match.groups() if g is not None).strip()
                with self.subTest(source=source, locale=locale, field=field, name=name):
                    self.assertIn(name, self.strings, f"{locale} {field} quotes a screen the app does not have")

    def test_english_screen_names_are_app_strings(self) -> None:
        for source, locale, field, text in self.each_field():
            # Keywords are search terms, not prose that names screens.
            if not locale.startswith("en") or field == "keywords":
                continue
            for readings in sorted(english_screen_candidates(text)):
                with self.subTest(source=source, locale=locale, field=field, phrase=readings[0]):
                    self.assertTrue(named_in_app(readings, self.strings), f"{readings[0]!r} is not a string the app shows")

    def test_detectors_catch_the_classic_text(self) -> None:
        classic = (
            "For manual pairing, select Tailscale Only under Connection Method, use Add Computer, "
            "open the App Review workspace."
        )
        self.assertTrue(any(t.lower() in classic.lower() for t in CLASSIC_ONLY_TERMS))
        prose = "Open the Workspaces tab, then tap Pair Computer. In Connection Settings, pick a host."
        missing = {r[0] for r in english_screen_candidates(prose) if not named_in_app(r, self.strings)}
        self.assertEqual(missing, {"Workspaces", "Pair Computer", "In Connection Settings"})
        self.assertTrue(named_in_app(("In Chat Server", "Chat Server"), self.strings))
        quoted = [next(g for g in m.groups() if g) for m in QUOTED.finditer("Tippe auf „Computer hinzufügen“.")]
        self.assertEqual(quoted, ["Computer hinzufügen"])
        self.assertNotIn("Computer hinzufügen", self.strings)


if __name__ == "__main__":
    unittest.main()
