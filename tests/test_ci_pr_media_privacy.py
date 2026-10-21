#!/usr/bin/env python3
"""PR media privacy gate: what counts as a private name, and what gets removed."""
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

import yaml

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("pr_media_privacy", ROOT / "scripts/ci/pr_media_privacy.py")
assert spec and spec.loader
privacy = importlib.util.module_from_spec(spec)
sys.modules["pr_media_privacy"] = privacy
spec.loader.exec_module(privacy)

GIT_ENV = {
    "GIT_AUTHOR_NAME": "test", "GIT_AUTHOR_EMAIL": "test@example.com",
    "GIT_COMMITTER_NAME": "test", "GIT_COMMITTER_EMAIL": "test@example.com",
    "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1",
}


def git(*args: str, cwd: Path) -> str:
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True,
                          env={**os.environ, **GIT_ENV}).stdout


def kinds(text: str, patterns=privacy.GENERIC_PATTERNS) -> list[str]:
    return [hit["kind"] for hit in privacy.findings([text], list(patterns))]


class FindingsTests(unittest.TestCase):
    def test_fleet_names_read_by_ocr_are_flagged(self) -> None:
        for text in (
            "- сmux7's Maс mini",
            "• сmux7's Mас mini",
            "стиx7's Mac mini",
            "cmux@cmux7s-Mac-mini cmux %",
            "сmux@cmuxs-Maс-mini-4 cmux %",
            "• /Users/cmux",
            "ssh leo@manaflow.ai",
        ):
            with self.subTest(text=text):
                self.assertTrue(kinds(text))

    def test_ordinary_text_is_not_flagged(self) -> None:
        for text in (
            "cmux-next",
            "manaflow-ai/cmux#22345",
            "cmux ~/code",
            "user@example.com",
            "Add retries with backoff",
            "cmux NEXT",
            "/Users/cmuxbot",
            "notify@docs.example.org",
        ):
            with self.subTest(text=text):
                self.assertEqual(kinds(text), [])

    def test_each_hit_names_its_kind_and_line(self) -> None:
        hits = privacy.findings(["clean", "• /Users/cmux"], list(privacy.GENERIC_PATTERNS))
        self.assertEqual([(hit["kind"], hit["line"]) for hit in hits], [("capture-account", 2)])

    def test_private_terms_match_whole_words_through_look_alikes(self) -> None:
        patterns = [*privacy.GENERIC_PATTERNS, *privacy.private_patterns(json.dumps(["Glowworm-Box"]))]
        self.assertEqual(kinds("ssh glоwwоrm-bох", patterns), ["private-term"])  # Cyrillic о, х
        self.assertEqual(kinds("GLOWWORM-BOX ready", patterns), ["private-term"])
        self.assertEqual(kinds("glowworm-boxes", patterns), [])
        self.assertEqual(privacy.private_patterns(""), [])
        with self.assertRaises(privacy.BadInput):
            privacy.private_patterns('{"not": "a list"}')


class RepoCase(unittest.TestCase):
    """A bare remote with a pr-media branch and a blob:none-style checkout of it."""

    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory(prefix="cmux-pr-media-privacy-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.remote = self.root / "remote.git"
        self.work = self.root / "work"
        git("init", "-q", "--bare", str(self.remote), cwd=self.root)
        git("init", "-q", "-b", privacy.BRANCH, str(self.work), cwd=self.root)
        git("remote", "add", "origin", str(self.remote), cwd=self.work)
        self.ocr = self.root / "ocr.sh"
        self.ocr.write_text('#!/bin/sh\ncase "$1" in *leak*) echo "cmux@cmux7s-Mac-mini ~ %" ;; *) echo ok ;; esac\n')
        self.ocr.chmod(0o755)

    def commit(self, files: dict[str, str]) -> str:
        for path, text in files.items():
            target = self.work / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(text)
            git("add", path, cwd=self.work)
        git("commit", "-qm", "media", cwd=self.work)
        git("push", "-q", "origin", privacy.BRANCH, cwd=self.work)
        git("fetch", "-q", "origin", cwd=self.work)
        return git("rev-parse", "HEAD", cwd=self.work).strip()

    def scan(self, start: str, end: str, apply: bool, authors=None, agents="teamleaderleo"):
        lookup = (lambda numbers: authors) if not callable(authors) else authors
        with contextlib.redirect_stdout(io.StringIO()) as out, mock.patch.dict(os.environ, GIT_ENV):
            report = privacy.scan(self.work, start, end, str(self.ocr), list(privacy.GENERIC_PATTERNS),
                                  apply, privacy.agent_authors(agents), lookup)
        return report, out.getvalue()

    def remote_paths(self) -> list[str]:
        return git("ls-tree", "-r", "--name-only", privacy.BRANCH, cwd=self.remote).splitlines()


class ScanTests(RepoCase):
    def test_only_added_and_modified_files_are_listed_even_after_a_squash(self) -> None:
        first = self.commit({"1/a.png": "a", "1/b.png": "b", "1/notes.bin": "x"})
        # prune_pr_media.py squashes the branch, so the marker need not be an ancestor.
        squashed = git("commit-tree", f"{first}^{{tree}}", "-m", "PR media, pruned", cwd=self.work).strip()
        (self.work / "1/a.png").unlink()
        git("rm", "-q", "1/a.png", cwd=self.work)
        end = self.commit({"1/b.png": "b2", "2/c.gif": "c", "2/d.mov": "d", "2/readme.md": "m"})
        self.assertEqual(sorted(privacy.changed_files(self.work, squashed, end)),
                         ["1/b.png", "2/c.gif", "2/d.mov", "2/readme.md"])

    def test_text_files_are_read_without_ocr(self) -> None:
        start = self.commit({"README.md": "hi"})
        end = self.commit({"7/index.html": "<p>cmux@cmux3s-mac-mini %</p>"})
        report, out = self.scan(start, end, apply=False)
        self.assertEqual([item["path"] for item in report["files"]], ["7/index.html"])
        self.assertNotIn("cmux3s", out)  # matched text is never printed

    def test_no_marker_scans_nothing(self) -> None:
        end = self.commit({"5/leak.png": "x"})
        report, _ = self.scan(None, end, apply=True)
        self.assertEqual(report["files"], [])
        self.assertIn("5/leak.png", self.remote_paths())


class ApplyTests(RepoCase):
    def test_agent_hits_go_in_one_commit_and_teammate_hits_stay(self) -> None:
        start = self.commit({"README.md": "hi"})
        end = self.commit({
            "10/aaaaaaaa/tour/leak.png": "x",
            "10/aaaaaaaa/tour/clean.png": "x",
            "11/leak.gif": "x",
            "nightly-next/reel/leak.mp4": "x",
            "ui-lab/leak.png": "x",
        })
        history = git("rev-list", privacy.BRANCH, cwd=self.remote).split()
        report, out = self.scan(start, end, apply=True, authors={10: "TeamLeaderLeo", 11: "austinywang"})
        paths = self.remote_paths()
        self.assertNotIn("10/aaaaaaaa/tour/leak.png", paths)
        self.assertNotIn("nightly-next/reel/leak.mp4", paths)
        self.assertIn("10/aaaaaaaa/tour/clean.png", paths)
        self.assertIn("11/leak.gif", paths)
        self.assertIn("ui-lab/leak.png", paths)
        # One ordinary commit on top; earlier history is untouched.
        self.assertEqual(git("rev-list", privacy.BRANCH, cwd=self.remote).split()[1:], history)
        self.assertEqual(git("rev-parse", f"{privacy.BRANCH}^", cwd=self.remote).strip(), end)
        message = git("log", "-1", "--format=%B", privacy.BRANCH, cwd=self.remote)
        self.assertIn("10/aaaaaaaa/tour/leak.png (mini-name, shell-prompt)", message)
        self.assertNotIn("cmux7s", message)
        actions = {item["path"]: item["action"] for item in report["files"]}
        self.assertEqual(actions["10/aaaaaaaa/tour/leak.png"], "removed")
        self.assertEqual(actions["nightly-next/reel/leak.mp4"], "removed")
        self.assertTrue(actions["11/leak.gif"].startswith("reported, not removed"))
        self.assertTrue(actions["ui-lab/leak.png"].startswith("reported, not removed"))
        self.assertIn("11/leak.gif (PR #11) shows", out)

    def test_a_failed_author_lookup_keeps_every_pull_request_file(self) -> None:
        start = self.commit({"README.md": "hi"})
        end = self.commit({"10/leak.png": "x", "12/leak.png": "x"})

        def broken(_numbers):
            raise RuntimeError("GraphQL unavailable")

        for lookup in (broken, None):
            report, _ = self.scan(start, end, apply=True, authors=lookup)
            self.assertEqual({"10/leak.png", "12/leak.png"} - set(self.remote_paths()), set())
            self.assertTrue(all(item["action"].startswith("reported") for item in report["files"]))

    def test_no_agent_list_removes_no_pull_request_file(self) -> None:
        start = self.commit({"README.md": "hi"})
        end = self.commit({"10/leak.png": "x"})
        lookup = mock.Mock(return_value={10: "teamleaderleo"})
        report, _ = self.scan(start, end, apply=True, authors=lookup, agents="")
        lookup.assert_not_called()
        self.assertIn("10/leak.png", self.remote_paths())
        self.assertIn("PR_MEDIA_AGENT_AUTHORS is empty", report["files"][0]["action"])

    def test_cli_exits_one_on_a_hit_and_writes_a_report(self) -> None:
        start = self.commit({"README.md": "hi"})
        end = self.commit({"nightly-next/leak.png": "x"})
        report_path = self.root / "report.json"
        argv = ["--repo", str(self.work), "--from", start, "--to", end, "--ocr", str(self.ocr),
                "--apply", "--report", str(report_path)]
        quiet = {**GIT_ENV, "GITHUB_STEP_SUMMARY": "", "PR_MEDIA_PRIVATE_TERMS": "", "PR_MEDIA_AGENT_AUTHORS": ""}
        with contextlib.redirect_stdout(io.StringIO()), mock.patch.dict(os.environ, quiet):
            self.assertEqual(privacy.main(argv, lookup=lambda _numbers: {}), 1)
            self.assertEqual(privacy.main(["--repo", str(self.work), "--from", "f" * 40, "--to", end]), 2)
            self.assertEqual(privacy.main(["--repo", str(self.work), "--from", "empty", "--to", end]), 0)
        self.assertEqual(json.loads(report_path.read_text())["files"][0]["action"], "removed")
        self.assertNotIn("nightly-next/leak.png", self.remote_paths())


class WorkflowTests(unittest.TestCase):
    def test_the_tick_is_one_ls_remote_and_the_scan_writes_only_contents(self) -> None:
        workflow = yaml.safe_load((ROOT / ".github/workflows/pr-media-privacy.yml").read_text())
        self.assertEqual(workflow["permissions"], {})
        self.assertEqual(workflow["concurrency"], {"group": "pr-media-privacy", "cancel-in-progress": False})
        self.assertEqual(workflow[True]["schedule"], [{"cron": "*/10 * * * *"}])
        check, scan = workflow["jobs"]["check"], workflow["jobs"]["scan"]
        self.assertIn("refs/heads/main", check["if"])
        self.assertEqual(check["permissions"], {"contents": "read"})
        self.assertEqual([step["run"].count("git ls-remote") for step in check["steps"]], [1])
        self.assertNotIn("uses", str(check["steps"]))
        self.assertEqual(scan["needs"], "check")
        self.assertEqual(scan["permissions"], {"contents": "write", "pull-requests": "read"})
        text = yaml.safe_dump(scan)
        self.assertIn("refs/pr-media-privacy/scanned", text)
        self.assertIn("secrets.PR_MEDIA_PRIVATE_TERMS", text)
        self.assertIn("vars.PR_MEDIA_AGENT_AUTHORS", text)
        for forbidden in ("gh pr comment", "gh issue", "statuses", "check-runs"):
            self.assertNotIn(forbidden, text)


if __name__ == "__main__":
    unittest.main(buffer=True)
