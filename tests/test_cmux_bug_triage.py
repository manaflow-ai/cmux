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


MANAGED = ROOT / "tests" / "fixtures" / "bug-triage" / "managed-mac-report"


def git(repo: Path, *args: str) -> str:
    env = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t", GIT_COMMITTER_NAME="t",
               GIT_COMMITTER_EMAIL="t@t", GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_SYSTEM="/dev/null")
    return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True,
                          text=True, env=env).stdout.strip()


def commit(repo: Path, message: str) -> str:
    git(repo, "commit", "-q", "--allow-empty", "-m", message)
    return git(repo, "rev-parse", "HEAD")


class LandedFixTests(unittest.TestCase):
    """Dedup against feat-cmux-next reads commit bodies, prefers the fix over its test,
    and says whether the fix is in the published nightly yet."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.inbox = Path(self.tmp.name) / "inbox"
        self.repo = Path(self.tmp.name) / "repo"
        self.repo.mkdir()
        git(self.repo, "init", "-q")
        self.decoy = commit(self.repo, "cmux-next: the Desktop Wallpaper tile shows the desktop, never a broken image")
        git(self.repo, "tag", "nightly-next")
        self.test_sha = commit(self.repo, "test(next): macOS 15 tester repros fail first: Cmd-D/Cmd-W from Settings, Cmd-1/2/3")
        self.crash_fix = commit(self.repo, "fix(next): Home binds no task local on the main thread outside a task (macOS 15 Cmd-1/2/3 crash)\n\n"
                                "macOS 15 tester: crashes after cmd 123. Cmd-1..9 switching workspaces crashed the app.")
        self.close_fix = commit(self.repo, "fix(next): Cmd-W right after Cmd-D runs at once; a split's key hold always ends\n\n"
                                "macOS 15 tester: Cmd-D then Cmd-W from Settings did nothing 2-3 times, then closed the new tab, Settings and the window.")
        self.chip_fix = commit(self.repo, "fix(next): the access chip says what it is and survives a refused mode\n\n"
                               "macOS 15 tester (company-managed Mac): what is the third dropdown? it does not work. It is the "
                               "permission mode. A mode the organization's managed settings refuse failed in silence.")
        self.tile_fix = commit(self.repo, "fix(next): wallpaper tiles show one title line; the full credit is the tooltip\n\n"
                               "macOS 15 tester: the caption text under each wallpaper tile overflowed and overlapped.")
        git(self.repo, "update-ref", "refs/remotes/origin/feat-cmux-next", "HEAD")

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def run_triage(self, *extra: str) -> dict:
        proc = run("triage", str(MANAGED / "report.md"), "--json", "--repo", str(self.repo), *extra, inbox=self.inbox)
        if proc.returncode != 0:
            raise AssertionError(proc.stderr)
        return json.loads(proc.stdout)

    def test_each_bug_maps_to_its_fix_commit(self) -> None:
        bugs = {b["text"]: b for b in self.run_triage()["bugs"]}
        want = {"Cmd+1": self.crash_fix, "Cmd+W": self.close_fix, "dropdown": self.chip_fix, "wallpaper": self.tile_fix}
        for needle, sha in want.items():
            bug = next(b for t, b in bugs.items() if needle.lower() in t.lower())
            self.assertEqual(bug["decision"], "skip", bug)
            self.assertEqual(bug["fixed_by"], sha[:11], bug)
            self.assertNotEqual(bug["fixed_by"], self.test_sha[:11])

    def test_fix_after_the_nightly_says_retest_after_next_nightly(self) -> None:
        for bug in self.run_triage()["bugs"]:
            self.assertFalse(bug["in_nightly"], bug)
            self.assertIn("not in nightly-next", bug["reason"])
        git(self.repo, "tag", "-f", "nightly-next", "HEAD")
        for bug in self.run_triage()["bugs"]:
            self.assertTrue(bug["in_nightly"], bug)
            self.assertIn("in nightly-next", bug["reason"])

    def test_open_github_issue_is_linked_without_changing_the_decision(self) -> None:
        issues = Path(self.tmp.name) / "issues.json"
        issues.write_text(json.dumps([{"number": 743, "title": "cmux crashes on workspace switch with Cmd+1",
                                       "url": "https://github.com/manaflow-ai/cmux/issues/743"}]))
        proc = run("triage", str(MANAGED / "report.md"), "--json", "--no-git", "--github", str(issues), inbox=self.inbox)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        result = json.loads(proc.stdout)
        crash = next(b for b in result["bugs"] if "Cmd+1" in b["text"])
        self.assertEqual(crash["decision"], "fix now")
        self.assertEqual(crash["issue"], "https://github.com/manaflow-ai/cmux/issues/743")
        task = next(t for t in result["tasks"] if "Cmd+1" in t["prompt"])
        self.assertIn("issues/743", task["prompt"])


if __name__ == "__main__":
    unittest.main()
