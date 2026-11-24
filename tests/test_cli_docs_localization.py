#!/usr/bin/env python3
"""`cmux docs` prints its topic list, summaries, resource labels, headings and
agent guidance in the user's language, not only the workflows catalog.

The CLI resolves its strings through the enclosing app bundle, so each case
copies the built executable into a throwaway `.app` layout, compiles the
repository catalog beside it with `xcstringstool`, and runs it under an
`AppleLanguages` override. Commands, paths and URLs must survive unchanged in
every locale; the prose must not.
"""

from __future__ import annotations

import plistlib
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from test_cli_workflow_catalog import load_json, resolve_cmux_cli, run_cli

ROOT = Path(__file__).resolve().parent.parent
CATALOG = ROOT / "Resources" / "Localizable.xcstrings"
LANGUAGES = ["de", "fr", "ar", "es", "zh-Hant", "zh-Hans", "ko", "ja"]

# Syntax that may appear inside translatable prose and must come through unchanged.
# Paths end on an ASCII path character so a sentence period or an attached
# particle (Korean) is not taken as part of the path.
INVARIANT = re.compile(
    r"`[^`]+`|"
    r"(?:~/\.config/cmux/|\.cmux/|~/Library/)[A-Za-z0-9_./-]*[A-Za-z0-9_/]|"
    r"(?<![A-Za-z0-9])(?:(?:cmux|dock|settings)\.json|cmux reload-config|"
    r"png|jpeg|mp4|gif|zsh|bash|fish|MDM|CLI|SwiftUI|curl)(?![A-Za-z0-9])"
)


def invariants(text: str) -> list[str]:
    """Order-insensitive: translations may legitimately move a path or command."""
    return sorted(INVARIANT.findall(text))

ENGLISH_HEADINGS = ["Topics:", "Raw resources:", "Useful commands:", "Fetch:", "Config files:"]
ENGLISH_GUIDANCE = [
    "Print the canonical docs URL, raw GitHub resources, and useful commands for a cmux topic.",
    "Use `cmux docs dock` before creating or editing .cmux/dock.json.",
    "Fetch raw resources with the printed curl commands when you need the latest schema.",
]


def build_localized_bundle(cli_path: str, root: Path) -> Path:
    """Place a copy of the CLI inside an app bundle that carries the compiled catalog."""
    contents = root / "DocsLocalizationTest.app" / "Contents"
    resources = contents / "Resources"
    executable = resources / "bin" / "cmux"
    executable.parent.mkdir(parents=True)
    shutil.copy2(cli_path, executable)
    (contents / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "com.cmux.docs-localization-test",
        "CFBundleDevelopmentRegion": "en",
        "CFBundlePackageType": "APPL",
    }))
    subprocess.run(
        ["xcrun", "xcstringstool", "compile", str(CATALOG), "--output-directory", str(resources)],
        check=True, capture_output=True, text=True,
    )
    return executable


class DocsLocalizationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.tempdir = tempfile.TemporaryDirectory(prefix="cmux-docs-localization-")
        cls.cli = str(build_localized_bundle(resolve_cmux_cli(), Path(cls.tempdir.name)))
        cls.english = load_json(run_cli(cls.cli, ["docs", "--json"]), "English docs index")["topics"]

    @classmethod
    def tearDownClass(cls) -> None:
        cls.tempdir.cleanup()

    def localized_topics(self, language: str) -> list[dict]:
        return load_json(run_cli(self.cli, ["docs", "--json"], language), f"{language} docs index")["topics"]

    def test_every_topic_summary_and_resource_label_is_translated(self) -> None:
        for language in LANGUAGES:
            with self.subTest(language=language):
                topics = self.localized_topics(language)
                self.assertEqual([t["topic"] for t in topics], [t["topic"] for t in self.english])
                for base, translated in zip(self.english, topics):
                    self.assertEqual(base.keys(), translated.keys(), base["topic"])
                    for field in ["aliases", "web_url", "commands"]:
                        self.assertEqual(base[field], translated[field], f"{base['topic']}.{field}")
                    self.assertNotEqual(base["summary"], translated["summary"],
                                        f"{language}: {base['topic']} summary is still English")
                    self.assertEqual(invariants(base["summary"]), invariants(translated["summary"]),
                                     f"{language}: {base['topic']} summary changed command or path syntax")
                    self.assertEqual(len(base["raw_resources"]), len(translated["raw_resources"]), base["topic"])
                    for resource, localized in zip(base["raw_resources"], translated["raw_resources"]):
                        self.assertEqual(resource["url"], localized["url"], base["topic"])
                        self.assertEqual(resource["fetch"], localized["fetch"], base["topic"])
                        self.assertNotEqual(resource["label"], localized["label"],
                                            f"{language}: {base['topic']} label {resource['label']!r} is still English")

    def test_index_lists_translated_summaries(self) -> None:
        for language in LANGUAGES:
            with self.subTest(language=language):
                result = run_cli(self.cli, ["docs"], language)
                self.assertEqual(result.returncode, 0, result.stderr)
                for base, translated in zip(self.english, self.localized_topics(language)):
                    self.assertIn(translated["summary"], result.stdout, base["topic"])
                    self.assertNotIn(base["summary"], result.stdout, f"{language}: {base['topic']} index row is English")
                self.assertNotIn("Topics:", result.stdout, f"{language}: index heading is English")
                self.assertIn("cmux docs <topic>", result.stdout, "the footer must keep the command syntax")

    def test_topic_page_translates_headings_and_keeps_commands(self) -> None:
        english = run_cli(self.cli, ["docs", "settings"]).stdout
        for language in LANGUAGES:
            with self.subTest(language=language):
                result = run_cli(self.cli, ["docs", "settings"], language)
                self.assertEqual(result.returncode, 0, result.stderr)
                for heading in ENGLISH_HEADINGS:
                    self.assertNotIn(heading, result.stdout, f"{language}: heading {heading!r} is English")
                for line in ["cmux settings path", "cmux reload-config", "https://cmux.com/docs/configuration#cmux-json",
                             "curl -fsSL https://raw.githubusercontent.com/manaflow-ai/cmux/main/web/data/cmux.schema.json",
                             "~/.config/cmux/cmux.json", "~/.config/ghostty/config"]:
                    self.assertIn(line, result.stdout, f"{language}: lost {line!r}")
                self.assertEqual(english.count("\n"), result.stdout.count("\n"), f"{language}: line structure changed")

    def test_help_translates_guidance_and_keeps_command_syntax(self) -> None:
        for language in LANGUAGES:
            with self.subTest(language=language):
                result = run_cli(self.cli, ["docs", "--help"], language)
                self.assertEqual(result.returncode, 0, result.stderr)
                for line in ENGLISH_GUIDANCE:
                    self.assertNotIn(line, result.stdout, f"{language}: guidance is English")
                self.assertNotIn("Usage: cmux docs", result.stdout, f"{language}: usage line is English")
                for syntax in ["cmux docs [settings|shortcuts|api|browser|capture|agents|workflows|dock|managed-policies|completion]",
                               "`cmux docs settings`", "~/.config/cmux/cmux.json", "`cmux docs workflows --json`",
                               "`cmux docs dock`", ".cmux/dock.json", "`cmux docs capture`"]:
                    self.assertIn(syntax, result.stdout, f"{language}: lost {syntax!r}")

    def test_japanese_output_uses_the_shipped_translations(self) -> None:
        index = run_cli(self.cli, ["docs"], "ja").stdout
        self.assertIn("トピック:", index)
        page = run_cli(self.cli, ["docs", "settings"], "ja").stdout
        self.assertIn("便利なコマンド:", page)
        self.assertIn("設定ファイル:", page)
        help_text = run_cli(self.cli, ["docs", "--help"], "ja").stdout
        self.assertIn("使用法: cmux docs [", help_text)
        self.assertIn("エージェント向け:", help_text)

    def test_unknown_topic_error_is_translated(self) -> None:
        for language in LANGUAGES:
            with self.subTest(language=language):
                result = run_cli(self.cli, ["docs", "nope"], language)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("'nope'", result.stderr)
                self.assertIn("cmux docs", result.stderr)
                self.assertNotIn("Unknown docs topic", result.stderr, f"{language}: error is English")

    def test_english_is_unchanged(self) -> None:
        result = run_cli(self.cli, ["docs", "settings"])
        self.assertEqual(result.returncode, 0, result.stderr)
        for line in ["settings: cmux-owned settings, cmux.json locations, schema, and reload flow.",
                     "Raw resources:", "  settings schema: ", "Useful commands:", "Config files:",
                     "  primary: ~/.config/cmux/cmux.json"]:
            self.assertIn(line, result.stdout)
        help_text = run_cli(self.cli, ["docs", "--help"]).stdout
        self.assertIn("Usage: cmux docs [settings|", help_text)
        self.assertIn("Agents:\n  Use `cmux docs settings` before editing ~/.config/cmux/cmux.json.", help_text)


if __name__ == "__main__":
    unittest.main()
