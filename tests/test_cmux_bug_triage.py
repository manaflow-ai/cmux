#!/usr/bin/env python3
"""Executable coverage for the cmux-bug-triage skill script.

Runs the real CLI against the tester report fixture (macOS Sequoia: Cmd+1/2/3
crash, Cmd+D/Cmd+W in Settings, composer third dropdown, wallpaper text
overflow) with temp inboxes and fake open-work files. No network, no git
repository state, no user files.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "skills" / "cmux-bug-triage" / "scripts" / "cmux-bug-triage"
FIXTURE = ROOT / "tests" / "fixtures" / "bug-triage" / "sequoia-report"


def run(*args: str, inbox: Path, stdin: str | None = None) -> subprocess.CompletedProcess:
    env = dict(os.environ, CMUX_BUG_INBOX=str(inbox), CMUX_PROMPT_COMMITS="")
    return subprocess.run(
        [sys.executable, "-I", str(SCRIPT), *args],
        input=stdin,
        capture_output=True,
        text=True,
        env=env,
        timeout=60,
    )


def triage(report: Path, inbox: Path, *extra: str) -> dict:
    proc = run("triage", str(report), "--json", "--no-git", *extra, inbox=inbox)
    if proc.returncode != 0:
        raise AssertionError(proc.stderr)
    return json.loads(proc.stdout)


def by_topic(result: dict) -> dict[str, dict]:
    keys = {"crash": "Cmd+1", "settings": "Cmd+W", "composer": "composer", "wallpaper": "Wallpaper"}
    out = {}
    for name, needle in keys.items():
        hits = [b for b in result["bugs"] if needle.lower() in b["text"].lower()]
        if len(hits) != 1:
            raise AssertionError(f"{name}: expected one bug containing {needle!r}, got {hits}")
        out[name] = hits[0]
    return out


class SequoiaReportTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.inbox = Path(self.tmp.name) / "inbox"

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_splits_into_four_bugs_with_environment(self) -> None:
        result = triage(FIXTURE / "report.md", self.inbox)
        self.assertEqual(len(result["bugs"]), 4)
        for bug in result["bugs"]:
            self.assertIn("Sequoia", bug["environment"])

    def test_decisions_without_open_work(self) -> None:
        bugs = by_topic(triage(FIXTURE / "report.md", self.inbox))
        self.assertEqual(bugs["crash"]["decision"], "fix now")
        self.assertEqual(bugs["settings"]["decision"], "fix now")
        self.assertEqual(bugs["composer"]["decision"], "batch")
        self.assertEqual(bugs["wallpaper"]["decision"], "batch")
        self.assertGreater(bugs["crash"]["score"], bugs["composer"]["score"])
        self.assertGreater(bugs["composer"]["score"], bugs["wallpaper"]["score"])
        for bug in bugs.values():
            self.assertTrue(bug["reason"].strip())

    def test_fix_now_tasks_have_title_line_group_and_rules(self) -> None:
        result = triage(FIXTURE / "report.md", self.inbox)
        tasks = result["tasks"]
        fix_now = [b for b in result["bugs"] if b["decision"] == "fix now"]
        self.assertEqual(len([t for t in tasks if t["kind"] == "fix now"]), len(fix_now))
        for task in tasks:
            title = task["prompt"].splitlines()[0]
            self.assertTrue(2 <= len(title.split()) <= 5, title)
            self.assertNotIn("User (u", title)
            self.assertTrue(task["group"])
            self.assertIn("origin/feat-cmux-next", task["prompt"])
            self.assertIn("no PR", task["prompt"])
            self.assertIn("macOS 15", task["prompt"])
        groups = {t["title"]: t["group"] for t in tasks if t["kind"] == "fix now"}
        self.assertIn("cmux-next app", groups.values())

    def test_open_agent_work_is_skipped_as_duplicate(self) -> None:
        open_work = Path(self.tmp.name) / "open.txt"
        open_work.write_text("a200: Composer model picker dropdown does not open\n")
        bugs = by_topic(triage(FIXTURE / "report.md", self.inbox, "--open-work", str(open_work)))
        self.assertEqual(bugs["composer"]["decision"], "skip")
        self.assertIn("a200", bugs["composer"]["reason"])
        self.assertEqual(bugs["crash"]["decision"], "fix now")

    def test_landed_prompt_commit_is_skipped_with_sha(self) -> None:
        log = Path(self.tmp.name) / "prompt-commits.md"
        log.write_text(
            "| msg | date | prompt | status | commits |\n|---|---|---|---|---|\n"
            "| 2119 | 2026-10-19 | Wallpaper settings text overflows and is clipped | landed | "
            "[`f3c64c03944`](https://github.com/manaflow-ai/cmux/commit/f3c64c03944) |\n"
            "| 1775 | 2026-10-19 | Cmd+N/T/D instant new tab and split | landed | "
            "[`1236922d165`](https://github.com/manaflow-ai/cmux/commit/1236922d165) |\n"
        )
        bugs = by_topic(triage(FIXTURE / "report.md", self.inbox, "--prompt-commits", str(log)))
        self.assertEqual(bugs["wallpaper"]["decision"], "skip")
        self.assertIn("f3c64c03944", bugs["wallpaper"]["reason"])
        # A shared shortcut alone (Cmd+D) with unrelated words is not a duplicate.
        self.assertEqual(bugs["settings"]["decision"], "fix now")

    def test_vague_item_is_skipped(self) -> None:
        report = Path(self.tmp.name) / "vague.md"
        report.write_text("- weird\n- Cmd+T crashes the app when the sidebar is hidden\n")
        result = triage(report, self.inbox)
        decisions = {b["text"]: b["decision"] for b in result["bugs"]}
        self.assertEqual(decisions["weird"], "skip")


class InboxTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.inbox = Path(self.tmp.name) / "inbox"

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_add_then_inbox_writes_triage_and_logs(self) -> None:
        image = Path(self.tmp.name) / "shot.png"
        image.write_bytes(b"\x89PNG\r\n\x1a\n")
        text = (FIXTURE / "report.md").read_text()
        added = run("add", "--text", "-", "--image", str(image), "--from", "tester", inbox=self.inbox, stdin=text)
        self.assertEqual(added.returncode, 0, added.stderr)
        folder = Path(added.stdout.strip().splitlines()[-1])
        self.assertTrue((folder / "report.md").exists())
        self.assertTrue((folder / "shot.png").exists())

        open_work = Path(self.tmp.name) / "open.txt"
        open_work.write_text("a201: Wallpaper settings text overflow clipped\n")
        proc = run("inbox", "--no-git", "--open-work", str(open_work), inbox=self.inbox)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        result = json.loads((folder / "triage.json").read_text())
        self.assertEqual(len(result["bugs"]), 4)
        self.assertTrue((folder / "triage.md").exists())
        skipped = (self.inbox / "SKIPPED.md").read_text()
        self.assertIn("a201", skipped)
        batch = (self.inbox / "BATCH.md").read_text()
        self.assertIn("composer", batch.lower())
        self.assertTrue(any(str(folder / "shot.png") in t["prompt"] for t in result["tasks"]))

        # A second run does not triage the same report again.
        again = run("inbox", "--no-git", "--open-work", str(open_work), inbox=self.inbox)
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertEqual((self.inbox / "SKIPPED.md").read_text(), skipped)


if __name__ == "__main__":
    unittest.main()
