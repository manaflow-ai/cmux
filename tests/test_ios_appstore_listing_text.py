#!/usr/bin/env python3
"""The App Store listing of cmux-next-ios names only screens the app has, in every locale.

cmux-next-ios replaces the classic iOS app under the production App Store record
(Leo, 2026-11-10: "Yeah we're letting go of the classic iOS app", "Replace
classic"). Its listing lives in cmux-next-ios/AppStoreReview/metadata in the layout
`asc metadata apply --dir` pushes: app-info/<locale>.json (name, subtitle) and
version/<version>/<locale>.json (description, keywords, promotional text).

On 2026-11-10 the classic listing still told reviewers to "select Tailscale Only
under Connection Method, use Add Computer, open the App Review workspace", screens
the replacing app does not have. This test fails a locale when:
  - a field is over its App Store limit;
  - the locale set is not the production record's, or the two trees (app-info and
    version) hold different locales, or the version tree is not project.yml's
    MARKETING_VERSION;
  - it names a classic-only screen (CLASSIC_ONLY_TERMS);
  - the public text carries App Review instructions (they belong in the notes);
  - a quoted screen name (any locale) is not a string the app shows;
  - an English capitalized phrase that is not a product or platform name is not a
    string the app shows.

"Strings the app shows" are the string literals of the release app's Swift
sources (APP_SOURCE_DIRS) and every key and value of their string catalogs,
leaving out `#if DEBUG` code and debug-only files (mock data, demos, the gallery,
stress rigs). When a screen ships, its strings join this set and a listing may
name it.
"""

from __future__ import annotations

import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "cmux-next-ios"
METADATA = APP / "AppStoreReview/metadata"
PROJECT_YML = APP / "project.yml"
APP_SOURCE_DIRS = (
    APP / "App",
    APP / "CmuxMobileKit/Sources",
    APP / "NotificationContent",
    APP / "NotificationService",
    # The conversation screen and composer come from this package.
    ROOT / "Packages/iOS/CmuxConversation/Sources",
)

# Paths under APP_SOURCE_DIRS whose strings a release build never shows.
NOT_SHIPPED = re.compile(
    r"/(Tests|UITests|Debug|Demo|Gallery|Mock)/"
    r"|/CmuxConversation(MacUI|LabMac)/"
    r"|/[^/]*(Mock|Demo|Gallery|Stress|Fixture|FloodBench|DevMenu)[^/]*\.swift$"
)

# The locales of the production App Store record (the classic app's listing had
# these 14). A locale missing here is deleted by `asc metadata apply --allow-deletes`.
PRODUCTION_LOCALES = (
    "de-DE", "en-US", "es-ES", "fr-FR", "it", "ja", "ko", "nl-NL", "pl", "pt-BR", "ru", "tr", "zh-Hans", "zh-Hant",
)

# Screens and settings of the classic iOS app (and of the earlier rewrite in ios/)
# that cmux-next-ios does not have.
CLASSIC_ONLY_TERMS = (
    "Connection Method",
    "Add Computer",
    "Tailscale Only",
    "App Review workspace",
    "Chat Server",
    "Self-Hosted",
)

# App Review instructions: the review notes carry these, never the public listing.
REVIEW_INSTRUCTION_TERMS = (
    "App Review",
    "Review Information",
    "demo account",
    "app-review-ok",
    "reviewer",
)

LIMITS = {"name": 30, "subtitle": 30, "keywords": 100, "promotional_text": 170, "description": 4000}

# Capitalized English words that are names of platforms or products, not app screens.
NON_SCREEN_NAMES = {
    "Apple", "Google", "GitHub", "Siri", "Shortcuts", "Action Button", "iPhone", "Mac", "Claude", "Codex",
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
DIRECTIVE = re.compile(r"^\s*#(if|elseif|else|endif)\b(.*)$")


def release_source(text: str) -> str:
    """Swift source with the branches a release build compiles out removed.

    `#if DEBUG` keeps its #else branch; `#if !DEBUG` keeps its first branch. Other
    conditions keep every branch (a platform check is still shipped code).
    """
    out: list[str] = []
    # Per open #if: (this branch dropped, condition is DEBUG-only, in its else branch)
    stack: list[tuple[bool, str]] = []

    def dropped() -> bool:
        return any(drop for drop, _ in stack)

    for line in text.splitlines():
        match = DIRECTIVE.match(line)
        if not match:
            if not dropped():
                out.append(line)
            continue
        kind, cond = match.group(1), match.group(2).strip()
        if kind == "if":
            mode = "debug" if cond == "DEBUG" else "release" if cond == "!DEBUG" else "other"
            stack.append((mode == "debug", mode))
        elif kind in ("else", "elseif") and stack:
            _, mode = stack.pop()
            stack.append((mode == "release", mode))
        elif kind == "endif" and stack:
            stack.pop()
    return "\n".join(out)


def app_strings() -> set[str]:
    strings: set[str] = set()
    for base in APP_SOURCE_DIRS:
        if not base.is_dir():
            continue
        for path in base.rglob("*"):
            if not path.is_file() or NOT_SHIPPED.search(path.as_posix()):
                continue
            if path.suffix == ".swift":
                for match in SWIFT_STRING.finditer(release_source(path.read_text(encoding="utf-8"))):
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


def marketing_version() -> str:
    match = re.search(r"^\s*MARKETING_VERSION:\s*\"?([0-9][0-9.]*)\"?\s*$", PROJECT_YML.read_text(encoding="utf-8"), re.MULTILINE)
    assert match, f"{PROJECT_YML} has no MARKETING_VERSION"
    return match.group(1)


def read_listings() -> dict[str, dict[str, dict[str, str]]]:
    """{tree: {locale: {field: text}}} for the app-info tree and each version tree."""
    trees: dict[str, dict[str, dict[str, str]]] = {"app-info": {}}
    for path in sorted((METADATA / "app-info").glob("*.json")):
        info = json.loads(path.read_text(encoding="utf-8"))
        trees["app-info"][path.stem] = {"name": info.get("name", ""), "subtitle": info.get("subtitle", "")}
    for version_dir in sorted(p for p in (METADATA / "version").iterdir() if p.is_dir()):
        tree = trees.setdefault(f"version/{version_dir.name}", {})
        for path in sorted(version_dir.glob("*.json")):
            data = json.loads(path.read_text(encoding="utf-8"))
            tree[path.stem] = {
                "description": data.get("description", ""),
                "keywords": data.get("keywords", ""),
                "promotional_text": data.get("promotionalText", ""),
            }
    return trees


def english_screen_candidates(text: str) -> set[tuple[str, ...]]:
    """Capitalized phrases in English prose, each with the readings that may name a screen.

    A phrase that opens a sentence may be a capitalized ordinary word followed by a
    screen name ("Open Settings"), so it also reads without its first word; a lone
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
        for tree, locales in self.listings.items():
            for locale, fields in locales.items():
                for field, text in fields.items():
                    yield tree, locale, field, text

    def test_sources_exist(self) -> None:
        self.assertIn("en-US", self.listings["app-info"])
        for label in ("New Chief", "Delete Account", "Continue with email"):
            self.assertIn(label, self.strings, f"the app string scan found no {label!r}")

    def test_debug_code_is_not_an_app_string(self) -> None:
        # Settings > Developer is #if DEBUG; its rows are not in a release build.
        self.assertNotIn("Mock (layout only)", self.strings)
        source = "#if DEBUG\nlet a = \"debug only\"\n#else\nlet a = \"release\"\n#endif\n#if !DEBUG\nlet b = \"shipped\"\n#endif"
        kept = release_source(source)
        self.assertIn("release", kept)
        self.assertIn("shipped", kept)
        self.assertNotIn("debug only", kept)

    def test_locales_are_the_production_record_set_in_both_trees(self) -> None:
        version = marketing_version()
        versions = [tree for tree in self.listings if tree.startswith("version/")]
        self.assertEqual(versions, [f"version/{version}"],
                         f"move metadata/version/<dir> to project.yml's MARKETING_VERSION {version}")
        for tree, locales in self.listings.items():
            with self.subTest(tree=tree):
                self.assertEqual(sorted(locales), sorted(PRODUCTION_LOCALES))

    def test_every_field_is_filled(self) -> None:
        for tree, locale, field, text in self.each_field():
            with self.subTest(tree=tree, locale=locale, field=field):
                self.assertTrue(text.strip(), f"{locale} has no {field}")

    def test_limits(self) -> None:
        for tree, locale, field, text in self.each_field():
            with self.subTest(tree=tree, locale=locale, field=field):
                self.assertLessEqual(len(text), LIMITS[field])

    def test_no_classic_only_screens(self) -> None:
        for tree, locale, field, text in self.each_field():
            for term in CLASSIC_ONLY_TERMS:
                with self.subTest(tree=tree, locale=locale, field=field, term=term):
                    self.assertNotIn(term.lower(), text.lower())

    def test_no_review_instructions_in_public_text(self) -> None:
        for tree, locale, field, text in self.each_field():
            for term in REVIEW_INSTRUCTION_TERMS:
                with self.subTest(tree=tree, locale=locale, field=field, term=term):
                    self.assertNotIn(term.lower(), text.lower())

    def test_quoted_screen_names_are_app_strings(self) -> None:
        for tree, locale, field, text in self.each_field():
            for match in QUOTED.finditer(text):
                name = next(g for g in match.groups() if g is not None).strip()
                with self.subTest(tree=tree, locale=locale, field=field, name=name):
                    self.assertIn(name, self.strings, f"{locale} {field} quotes a screen the app does not have")

    def test_english_screen_names_are_app_strings(self) -> None:
        for tree, locale, field, text in self.each_field():
            # Keywords are search terms, not prose that names screens.
            if not locale.startswith("en") or field == "keywords":
                continue
            for readings in sorted(english_screen_candidates(text)):
                with self.subTest(tree=tree, locale=locale, field=field, phrase=readings[0]):
                    self.assertTrue(named_in_app(readings, self.strings), f"{readings[0]!r} is not a string the app shows")

    def test_detectors_catch_the_classic_text(self) -> None:
        classic = (
            "For manual pairing, select Tailscale Only under Connection Method, use Add Computer, "
            "open the App Review workspace."
        )
        self.assertTrue(any(t.lower() in classic.lower() for t in CLASSIC_ONLY_TERMS))
        self.assertTrue(any(t.lower() in classic.lower() for t in REVIEW_INSTRUCTION_TERMS))
        prose = "Open the Terminal Grid, then tap Pair Computer. In Connection Settings, pick a host."
        missing = {r[0] for r in english_screen_candidates(prose) if not named_in_app(r, self.strings)}
        self.assertEqual(missing, {"Terminal Grid", "Pair Computer", "In Connection Settings"})
        self.assertTrue(named_in_app(("Open Settings", "Settings"), self.strings))
        quoted = [next(g for g in m.groups() if g) for m in QUOTED.finditer("Tippe auf „Computer hinzufügen“.")]
        self.assertEqual(quoted, ["Computer hinzufügen"])
        self.assertNotIn("Computer hinzufügen", self.strings)


if __name__ == "__main__":
    unittest.main()
