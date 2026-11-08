#!/usr/bin/env python3
"""Checks how skills/cmux-release/references/changelog-lines.jq reads a PR's Changelog section.

    python3 tests/test_release_changelog_lines.py

Needs jq on PATH. Review bots and agents append a footer after the last section
(a `---` rule, then HTML, or a "Generated with" line) with no heading of its
own, so the footer must not be read as part of the Changelog section.
"""

from __future__ import annotations

from pathlib import Path
import json
import shutil
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
JQ = ROOT / "skills/cmux-release/references/changelog-lines.jq"
FOOTER = ('---\n<a href="https://app.blacksmith.sh/x"><picture><source media="(prefers-color-scheme: dark)">'
          '</picture></a>\n<sup>Need help on this PR?</sup>\n')
GENERATED = "🤖 Generated with [Claude Code](https://claude.com/claude-code)\n"


def classify(body: str, title: str = "fix: something") -> tuple[str, str]:
    sha = "a" * 40
    pr = {"number": 1, "title": title, "body": body, "url": "https://example.invalid/1",
          "author": {"__typename": "User", "login": "teamleaderleo"},
          "mergeCommit": {"oid": sha}, "closingIssuesReferences": {"nodes": []}}
    out = subprocess.run(
        ["jq", "-r", "-s", "--arg", "log", f"{sha}\n{title} (#1)\n@@end@@\n", "-f", str(JQ)],
        input=json.dumps(pr), capture_output=True, text=True, check=True).stdout
    fields = out.rstrip("\n").split("\t")
    return fields[0], fields[5]


@unittest.skipUnless(shutil.which("jq"), "jq is not installed")
class ChangelogLinesTest(unittest.TestCase):
    def test_entry(self) -> None:
        self.assertEqual(classify("## Changelog\nFixed: A thing works.\n"), ("entry", "Fixed: A thing works."))

    def test_none_before_bot_footer_is_skipped(self) -> None:
        self.assertEqual(classify("## Changelog\nnone\n" + FOOTER)[0], "skip-none")

    def test_none_before_generated_line_and_footer_is_skipped(self) -> None:
        self.assertEqual(classify("## Changelog\nnone\n\n" + GENERATED + FOOTER)[0], "skip-none")

    def test_entry_before_generated_line_is_an_entry(self) -> None:
        body = "## Changelog\nFixed: Claude's worktree is followed.\n\n" + GENERATED + FOOTER
        self.assertEqual(classify(body), ("entry", "Fixed: Claude's worktree is followed."))

    def test_inline_html_line_stays_in_the_section(self) -> None:
        body = "## Changelog\nAdded: Cmd-K clears the pane.\n<kbd>Cmd</kbd>-Shift-K clears scrollback too.\n"
        self.assertEqual(classify(body)[0], "check-line")
        self.assertIn("<kbd>Cmd</kbd>", classify(body)[1])

    def test_closing_keyword_line_is_not_a_changelog_line(self) -> None:
        body = "## Changelog\nFixed: The shortcut hides the sidebar.\nFixes #20286\n"
        self.assertEqual(classify(body), ("entry", "Fixed: The shortcut hides the sidebar."))

    def test_unprefixed_line_still_needs_a_human(self) -> None:
        self.assertEqual(classify("## Changelog\nKeep updates on the owning pane.\n" + FOOTER),
                         ("check-line", "Keep updates on the owning pane."))

    def test_missing_section_uses_the_title(self) -> None:
        self.assertEqual(classify("## Summary\nText.\n", title="fix: title"), ("check-title", "fix: title"))


if __name__ == "__main__":
    unittest.main()
