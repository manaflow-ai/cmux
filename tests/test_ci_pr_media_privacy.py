#!/usr/bin/env python3
"""PR media privacy gate: what counts as a private name, and what gets removed."""
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
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

    def test_terms_shorter_than_the_minimum_are_ignored(self) -> None:
        patterns = privacy.private_patterns(json.dumps(["io", "lab", " ab ", "glow"]))
        self.assertEqual(len(patterns), 1)
        self.assertEqual(kinds("version 10 of the lab, io 1ab", patterns), [])
        self.assertEqual(kinds("ssh g1ow", patterns), ["private-term"])


class LookAlikeTests(unittest.TestCase):
    def test_a_private_term_matches_cyrillic_letters_and_digits_read_for_letters(self) -> None:
        patterns = privacy.private_patterns(json.dumps(["glow-box"]))
        for text in ("ssh glоw-bоx", "g1ow-box %", "GLOW-B0X", "/Users/x/glow-box/y"):  # Cyrillic о
            with self.subTest(text=text):
                self.assertEqual(kinds(text, patterns), ["private-term"])
        for text in ("glow-boxes", "aglow-box", "glow box"):
            with self.subTest(text=text):
                self.assertEqual(kinds(text, patterns), [])

    def test_digits_are_never_folded_into_each_other(self) -> None:
        self.assertEqual(kinds("ssh cmux7", privacy.private_patterns(json.dumps(["cmux1"]))), [])
        self.assertEqual(privacy.fold("cmux1 cmux7"), "cmux1 cmux7")
        self.assertEqual([hit["text"] for hit in privacy.findings(["cmux7"], list(privacy.GENERIC_PATTERNS))],
                         ["cmux7"])

    def test_an_address_with_look_alike_letters_is_still_an_address(self) -> None:
        self.assertEqual(kinds("mail lео@glow-box.dev"), ["email"])  # Cyrillic е, о
        self.assertEqual(kinds("mail usеr@example.com"), [])

    def test_both_terms_formats_are_read(self) -> None:
        for raw in (json.dumps(["glow-box"]), json.dumps({"terms": ["glow-box"]})):
            with self.subTest(raw=raw):
                self.assertEqual(kinds("glow-box", privacy.private_patterns(raw)), ["private-term"])
        for raw in ('{"terms": "glow-box"}', "[1]", "not json"):
            with self.subTest(raw=raw), self.assertRaises(privacy.BadInput):
                privacy.private_patterns(raw)


class TermSourceTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory(prefix="cmux-pr-media-terms-test-")
        self.addCleanup(temporary.cleanup)
        self.home = Path(temporary.name)

    def write(self, relative: str, value) -> Path:
        path = self.home / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value))
        return path

    def test_sources_are_tried_in_order_and_named_without_their_terms(self) -> None:
        ci = {"HOME": str(self.home), "GITHUB_ACTIONS": "true"}
        self.assertEqual(privacy.load_private_terms(ci)[0], [])
        self.assertIn("no private terms", privacy.load_private_terms(ci)[1])
        self.write("Projects/cmuxterm-hq/build-fleet/pr_capture/private-terms.json", {"terms": ["home-box"]})
        self.assertEqual(privacy.load_private_terms(ci)[0], ["home-box"])
        hq = self.write("hq/build-fleet/pr_capture/private-terms.json", {"terms": ["hq-box"]})
        with_hq = {**ci, "CMUX_HQ": str(hq.parents[2])}
        self.assertEqual(privacy.load_private_terms(with_hq)[0], ["hq-box"])
        named = self.write("terms.json", ["file-box"])
        with_file = {**with_hq, "PR_MEDIA_PRIVATE_TERMS_FILE": str(named)}
        self.assertEqual(privacy.load_private_terms(with_file), (["file-box"], "$PR_MEDIA_PRIVATE_TERMS_FILE"))
        terms, source = privacy.load_private_terms({**with_file, "PR_MEDIA_PRIVATE_TERMS": '["glow-box"]'})
        self.assertEqual((terms, source), (["glow-box"], "$PR_MEDIA_PRIVATE_TERMS"))
        with self.assertRaises(privacy.BadInput):
            privacy.load_private_terms({**ci, "PR_MEDIA_PRIVATE_TERMS_FILE": str(self.home / "absent.json")})

    def test_outside_ci_this_machines_own_names_are_added(self) -> None:
        local = {"HOME": str(self.home), "PR_MEDIA_PRIVATE_TERMS": '["glow-box"]'}
        with mock.patch.object(privacy, "local_names", return_value=["glow-host"]):
            self.assertEqual(privacy.load_private_terms(local)[0], ["glow-box", "glow-host"])
            self.assertEqual(privacy.load_private_terms({**local, "GITHUB_ACTIONS": "true"})[0], ["glow-box"])

    def test_local_names_drop_short_and_shared_names(self) -> None:
        with mock.patch.object(privacy.getpass, "getuser", return_value="cmux"), \
                mock.patch.object(privacy.socket, "gethostname", return_value="glow-box.local"), \
                mock.patch.object(privacy.sys, "platform", "linux"):
            self.assertEqual(privacy.local_names(Path("/h")), ["glow-box", "glow-box.local"])

    def test_agent_authors_come_from_the_variable_or_the_workspace_list(self) -> None:
        env = {"HOME": str(self.home)}
        self.assertEqual(privacy.load_agent_authors(env), frozenset())
        self.write("Projects/leo-workspace/machines/agent-authors.json", ["Bot-A"])
        self.assertEqual(privacy.load_agent_authors(env), frozenset({"bot-a"}))
        self.assertEqual(privacy.load_agent_authors({**env, "PR_MEDIA_AGENT_AUTHORS": "bot-b, bot-c"}),
                         frozenset({"bot-b", "bot-c"}))

    def test_the_workspace_list_is_read_in_its_own_format(self) -> None:
        # leo-workspace's file is {"_doc": ..., "authors": [...]}, as tools/agent_authors.py reads it.
        env = {"HOME": str(self.home)}
        self.write("Projects/leo-workspace/machines/agent-authors.json", {"_doc": "who", "authors": ["Bot-A"]})
        self.assertEqual(privacy.load_agent_authors(env), frozenset({"bot-a"}))
        self.write("Projects/leo-workspace/machines/agent-authors.json", {"authors": "bot-a"})
        with self.assertRaises(privacy.BadInput):
            privacy.load_agent_authors(env)

    def test_the_ocr_tool_can_be_named_or_turned_off_and_is_absent_off_macos(self) -> None:
        self.assertIsNone(privacy.ocr_binary({"PR_MEDIA_PRIVACY_OCR": "none"}))
        self.assertEqual(privacy.ocr_binary({"PR_MEDIA_PRIVACY_OCR": "/opt/ocr"}), "/opt/ocr")
        with mock.patch.object(privacy.sys, "platform", "linux"), \
                mock.patch.object(privacy.subprocess, "run", side_effect=AssertionError("must not compile")):
            self.assertIsNone(privacy.ocr_binary({"HOME": str(self.home)}))


def fake_ocr(local: Path) -> list[str]:
    """Reads a "leak" file as a fleet prompt and a "broken" one as an OCR failure."""
    if "broken" in local.name:
        raise RuntimeError("OCR exited 4")
    return ["cmux@cmux7s-Mac-mini ~ %"] if "leak" in local.name else ["ok"]


class CheckFilesTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory(prefix="cmux-pr-media-check-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.patterns = [*privacy.GENERIC_PATTERNS, *privacy.private_patterns('["glow-box"]')]

    def file(self, name: str, text: str = "x") -> Path:
        path = self.root / name
        path.write_text(text)
        return path

    def check(self, items, authors=None, agents="bot-a", ocr=fake_ocr):
        lookup = authors if callable(authors) else (lambda _numbers: authors or {})
        report = privacy.check_files(items, self.patterns, ocr, lookup, privacy.agent_authors(agents))
        return {item["path"]: item["action"] for item in report["files"]}, report

    def test_an_agents_hit_is_refused_and_a_teammates_is_only_reported(self) -> None:
        leak, clean = self.file("leak.png"), self.file("clean.png")
        notes = self.file("notes.md", "ssh g1ow-box")
        actions, report = self.check([("10/leak.png", leak), ("10/clean.png", clean), ("11/leak.png", leak),
                                      ("12/notes.md", notes), ("ui-lab/leak.png", leak)],
                                     authors={10: "Bot-A", 11: "teammate", 12: "bot-a"})
        self.assertEqual(actions, {"10/leak.png": "refuse", "11/leak.png": "report",
                                   "12/notes.md": "refuse", "ui-lab/leak.png": "report"})
        self.assertTrue(report["refused"])
        self.assertNotIn("cmux7s", json.dumps(report))
        self.assertNotIn("g1ow", json.dumps(report))

    def test_bot_folders_are_always_refused(self) -> None:
        leak = self.file("leak.png")
        for agents in ("bot-a", ""):
            actions, _ = self.check([("nightly-next/r/leak.png", leak), ("fuzz/d/1/leak.png", leak)], agents=agents)
            self.assertEqual(set(actions.values()), {"refuse"}, agents)

    def test_a_hit_whose_author_cannot_be_looked_up_is_refused(self) -> None:
        leak, clean = self.file("leak.png"), self.file("clean.png")

        def broken(_numbers):
            raise RuntimeError("GraphQL unavailable")

        for lookup in (broken, lambda _numbers: None):
            actions, _ = self.check([("10/leak.png", leak)], authors=lookup)
            self.assertEqual(actions, {"10/leak.png": "refuse"})
        lookup = mock.Mock(side_effect=broken)
        actions, report = self.check([("10/clean.png", clean)], authors=lookup)
        self.assertEqual((actions, report["refused"]), ({}, False))
        lookup.assert_not_called()  # no hit, no lookup, nothing to fail closed on

    def test_no_agent_list_refuses_pull_request_hits(self) -> None:
        lookup = mock.Mock(return_value={10: "teammate"})
        actions, report = self.check([("10/leak.png", self.file("leak.png"))], authors=lookup, agents="")
        self.assertEqual(actions, {"10/leak.png": "refuse"})
        self.assertEqual(report["files"][0]["reason"], "PR_MEDIA_AGENT_AUTHORS is empty")
        lookup.assert_not_called()

    def test_check_upload_off_ci_without_an_agent_list_refuses(self) -> None:
        env = {"HOME": str(self.root), "PR_MEDIA_PRIVATE_TERMS": '["glow-box"]'}
        with contextlib.redirect_stderr(io.StringIO()) as err, self.assertRaises(privacy.Refused):
            privacy.check_upload([("10/notes.html", self.file("notes.html", "ssh glow-box"))], env=env,
                                 ocr=None, lookup=lambda _numbers: {10: "teammate"})
        self.assertIn("no PR_MEDIA_AGENT_AUTHORS list", err.getvalue())
        self.assertNotIn("glow-box", err.getvalue())

    def test_an_unreadable_agent_file_is_refused(self) -> None:
        actions, report = self.check([("nightly-next/broken.png", self.file("broken.png"))])
        self.assertEqual(actions, {"nightly-next/broken.png": "refuse"})
        self.assertEqual(report["files"][0]["kinds"], ["unreadable"])

    def test_without_ocr_media_are_skipped_and_text_is_still_read(self) -> None:
        notes = self.file("notes.html", "<p>cmux@cmux3s-mac-mini %</p>")
        actions, report = self.check([("fuzz/d/leak.png", self.file("leak.png")), ("fuzz/d/notes.html", notes)],
                                     ocr=None)
        self.assertEqual(actions, {"fuzz/d/notes.html": "refuse"})
        self.assertEqual(report["skipped"], ["fuzz/d/leak.png"])

    def test_the_ocr_tool_can_be_a_compiled_binary(self) -> None:
        tool = self.root / "ocr.sh"
        tool.write_text('#!/bin/sh\nprintf "@@frame 0\\nglow-box\\n"\n')
        tool.chmod(0o755)
        actions, _ = self.check([("fuzz/d/shot.png", self.file("shot.png"))], ocr=str(tool))
        self.assertEqual(actions, {"fuzz/d/shot.png": "refuse"})


class CheckCommandTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory(prefix="cmux-pr-media-check-cli-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        tool = self.root / "ocr.sh"
        tool.write_text('#!/bin/sh\ncase "$1" in *leak*) echo "ssh glоw-bоx" ;; *) echo ok ;; esac\n')
        tool.chmod(0o755)
        self.env = {"HOME": str(self.root), "GITHUB_ACTIONS": "true", "PR_MEDIA_PRIVACY_OCR": str(tool),
                    "PR_MEDIA_PRIVATE_TERMS": '{"terms": ["glow-box"]}', "PR_MEDIA_AGENT_AUTHORS": "bot-a",
                    "PR_MEDIA_PRIVATE_TERMS_FILE": "", "CMUX_HQ": ""}

    def run_check(self, prefix: str, *names: str):
        paths = []
        for name in names:
            (self.root / name).write_bytes(b"x")
            paths.append(str(self.root / name))
        with contextlib.redirect_stdout(io.StringIO()) as out, contextlib.redirect_stderr(io.StringIO()) as err, \
                mock.patch.dict(os.environ, self.env):
            code = privacy.main(["check", "--path-prefix", prefix, *paths],
                                lookup=lambda _numbers: {10: "bot-a", 11: "teammate"})
        return code, out.getvalue() + err.getvalue()

    def test_exit_status_names_refused_reported_and_clean(self) -> None:
        code, out = self.run_check("10", "leak.png", "clean.png")
        self.assertEqual(code, 1)
        self.assertIn("10/leak.png shows private-term; refused", out)
        self.assertNotIn("glow", out.replace(str(self.root), ""))  # never the matched text
        code, out = self.run_check("11", "leak.png")
        self.assertEqual(code, 0)
        self.assertIn("reported, uploading anyway", out)
        self.assertEqual(self.run_check("fuzz/abc/1", "clean.png")[0], 0)
        self.assertEqual(self.run_check("fuzz/abc/1", "leak.png")[0], 1)

    def test_bad_input_exits_two(self) -> None:
        (self.root / "a.md").write_text("x")
        with contextlib.redirect_stderr(io.StringIO()), contextlib.redirect_stdout(io.StringIO()), \
                mock.patch.dict(os.environ, self.env):
            self.assertEqual(privacy.main(["check", "--path-prefix", "10", str(self.root / "absent.png")]), 2)
            with mock.patch.dict(os.environ, {"PR_MEDIA_PRIVATE_TERMS": "not json"}):
                self.assertEqual(privacy.main(["check", "--path-prefix", "10", str(self.root / "a.md")]), 2)


class FuzzUploadTests(unittest.TestCase):
    def test_a_refused_frame_stops_every_put(self) -> None:
        sys.path.insert(0, str(ROOT / "dogfood" / "fuzz"))
        self.addCleanup(sys.path.remove, str(ROOT / "dogfood" / "fuzz"))
        from cmuxfuzz import triage
        with tempfile.TemporaryDirectory(prefix="cmux-pr-media-fuzz-test-") as directory:
            frames = []
            for name in ("step-00000.png", "step-00001.png"):
                frames.append(Path(directory) / name)
                frames[-1].write_bytes(b"x")
            tool = Path(directory) / "ocr.sh"
            tool.write_text('#!/bin/sh\ncase "$1" in *00001*) echo "cmux@cmux7s-Mac-mini" ;; *) echo ok ;; esac\n')
            tool.chmod(0o755)
            env = {"HOME": directory, "GITHUB_ACTIONS": "true", "PR_MEDIA_PRIVACY_OCR": str(tool),
                   "PR_MEDIA_PRIVATE_TERMS": "", "PR_MEDIA_PRIVATE_TERMS_FILE": "", "CMUX_HQ": "",
                   "PR_MEDIA_AGENT_AUTHORS": ""}
            with mock.patch.dict(os.environ, env), mock.patch.object(triage, "_gh") as gh, \
                    contextlib.redirect_stderr(io.StringIO()) as err:
                with self.assertRaises(RuntimeError) as raised:
                    triage.upload(frames, "digest/7")
                gh.assert_not_called()
                self.assertIn("fuzz/digest/7/step-00001.png", str(raised.exception))
                self.assertNotIn("cmux7s", str(raised.exception) + err.getvalue())
                gh.return_value = ""
                urls = triage.upload(frames[:1], "digest/7")
                self.assertEqual(gh.call_count, 1)
                self.assertTrue(urls[0].endswith("/pr-media/fuzz/digest/7/step-00000.png"))


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
        quiet = {**GIT_ENV, "GITHUB_STEP_SUMMARY": "", "GITHUB_OUTPUT": "", "PR_MEDIA_PRIVATE_TERMS": "",
                 "PR_MEDIA_AGENT_AUTHORS": ""}
        with contextlib.redirect_stdout(io.StringIO()), mock.patch.dict(os.environ, quiet):
            self.assertEqual(privacy.main(argv, lookup=lambda _numbers: {}), 1)
            self.assertEqual(privacy.main(["--repo", str(self.work), "--from", "f" * 40, "--to", end]), 2)
            self.assertEqual(privacy.main(["--repo", str(self.work), "--from", "empty", "--to", end]), 0)
        self.assertEqual(json.loads(report_path.read_text())["files"][0]["action"], "removed")
        self.assertNotIn("nightly-next/leak.png", self.remote_paths())

    def test_the_marker_skips_the_gates_own_removal_commit(self) -> None:
        start = self.commit({"README.md": "hi"})
        end = self.commit({"nightly-next/leak.png": "x"})
        report, _ = self.scan(start, end, apply=True)
        self.assertEqual(report["marker"], git("rev-parse", privacy.BRANCH, cwd=self.remote).strip())
        self.assertNotEqual(report["marker"], end)

    def test_an_unreadable_file_fails_the_run(self) -> None:
        start = self.commit({"README.md": "hi"})
        end = self.commit({"3/broken.png": "x"})
        self.ocr.write_text("#!/bin/sh\nexit 4\n")
        argv = ["--repo", str(self.work), "--from", start, "--to", end, "--ocr", str(self.ocr)]
        quiet = {**GIT_ENV, "GITHUB_STEP_SUMMARY": "", "GITHUB_OUTPUT": "", "PR_MEDIA_PRIVATE_TERMS": ""}
        with contextlib.redirect_stdout(io.StringIO()), mock.patch.dict(os.environ, quiet):
            self.assertEqual(privacy.main(argv, lookup=lambda _numbers: {}), 1)

    def test_a_crash_exits_above_one_so_the_marker_holds(self) -> None:
        start = self.commit({"README.md": "hi"})
        end = self.commit({"nightly-next/leak.png": "x"})
        argv = ["--repo", str(self.work), "--from", start, "--to", end, "--ocr", str(self.ocr), "--apply"]
        quiet = {**GIT_ENV, "GITHUB_STEP_SUMMARY": "", "GITHUB_OUTPUT": "", "PR_MEDIA_PRIVATE_TERMS": ""}
        with contextlib.redirect_stdout(io.StringIO()) as out, mock.patch.dict(os.environ, quiet), \
                mock.patch.object(privacy, "apply_removal", side_effect=RuntimeError("pr-media kept moving")):
            self.assertEqual(privacy.main(argv, lookup=lambda _numbers: {}), 3)
        self.assertIn("RuntimeError", out.getvalue())
        self.assertIn("nightly-next/leak.png", self.remote_paths())


class AuthorLookupTests(unittest.TestCase):
    def test_a_partial_graphql_answer_counts_as_a_failed_lookup(self) -> None:
        partial = json.dumps({"data": {"repository": {"p10": {"author": {"login": "teamleaderleo"}}, "p12": None}},
                              "errors": [{"message": "Could not resolve to a PullRequest"}]})
        done = subprocess.CompletedProcess([], 1, stdout=partial, stderr="")
        with mock.patch.dict(os.environ, {"REPOSITORY": "o/r"}), \
                mock.patch.object(privacy.subprocess, "run", return_value=done):
            self.assertIsNone(privacy.github_authors([10, 12]))
        whole = json.dumps({"data": {"repository": {"p10": {"author": {"login": "teamleaderleo"}}}}})
        with mock.patch.dict(os.environ, {"REPOSITORY": "o/r"}), \
                mock.patch.object(privacy.subprocess, "run",
                                  return_value=subprocess.CompletedProcess([], 0, stdout=whole, stderr="")):
            self.assertEqual(privacy.github_authors([10]), {10: "teamleaderleo"})


class WriterInventoryTests(unittest.TestCase):
    """Every file that writes to the pr-media branch runs the shared check first.

    A file counts as a writer when it names the branch and writes (a contents API
    PUT, a git push, or pr-media.py's put_file or CLI). A new writer fails this
    test until it is listed, and a direct writer must load pr_media_privacy.py.
    """

    MEDIA = re.compile(r"pr-media|MEDIA_BRANCH")
    # A contents PUT in any spelling, a push (also across a line continuation),
    # a ref update or a GraphQL commit.
    DIRECT = re.compile(r"""\bPUT\b|(?i:-xput\b|\.put\(|--method[\s"',=]+put\b)|\bgit\b(?:[^\n]|\\\n){0,120}?\bpush\b|"push",|git/refs|createCommitOnBranch""")
    VIA_TOOL = re.compile(r"put_file\(|pr-media\.py")
    # Writes with its own PUT or push, after check_privacy()/check_upload().
    CHECKS_ITSELF = {"scripts/pr-media.py", "dogfood/fuzz/cmuxfuzz/triage.py"}
    # Writes only through scripts/pr-media.py, which checks.
    THROUGH_PR_MEDIA_PY = {"scripts/ci/pr_media.py", "scripts/showcase-publish.py",
                           ".github/workflows/pr-media.yml"}
    # Remove files or rewrite the retention index; they add no capture.
    REMOVES_ONLY = {"scripts/ci/pr_media_privacy.py", ".github/workflows/pr-media-privacy.yml",
                    "scripts/ci/prune_pr_media.py", ".github/workflows/pr-media-prune.yml"}
    # Names the files for CI routing; writes nothing.
    NOT_WRITERS = {"scripts/ci/workflow_guard_groups.py"}
    SKIP_SUFFIXES = (".md", ".json", ".xcstrings", ".txt", ".png", ".gif", ".mp4", ".webp", ".jpg", ".svg")

    @classmethod
    def setUpClass(cls) -> None:
        cls.found = cls.scan()

    @classmethod
    def scan(cls) -> dict[str, str]:
        tracked = subprocess.run(["git", "ls-files", "-z"], cwd=ROOT, capture_output=True, text=True,
                                 check=True).stdout.split("\0")
        found = {}
        for path in tracked:
            if not path or path.startswith(("tests/", "docs/")) or path.endswith(cls.SKIP_SUFFIXES):
                continue
            try:
                text = (ROOT / path).read_text(encoding="utf-8")
            except (OSError, UnicodeDecodeError):
                continue
            if cls.MEDIA.search(text) and (cls.DIRECT.search(text) or cls.VIA_TOOL.search(text)):
                found[path] = text
        return found

    def test_every_writer_is_listed(self) -> None:
        listed = self.CHECKS_ITSELF | self.THROUGH_PR_MEDIA_PY | self.REMOVES_ONLY | self.NOT_WRITERS
        found = set(self.found)
        self.assertEqual(found - listed, set(), "a new pr-media writer: run pr_media_privacy.check_upload "
                                                "before it pushes (or upload with scripts/pr-media.py), then list it here")
        self.assertEqual(listed - found, set(), "a listed writer no longer writes; drop it from the list")

    def test_a_writer_never_bypasses_the_check(self) -> None:
        found = self.found
        for path in sorted(self.CHECKS_ITSELF):
            with self.subTest(path=path):
                self.assertIn("pr_media_privacy", found[path])
                self.assertRegex(found[path], r"\bcheck_(privacy|upload)\(")
        for path in sorted(self.THROUGH_PR_MEDIA_PY):
            with self.subTest(path=path):
                self.assertIsNone(self.DIRECT.search(found[path]), f"{path} writes without scripts/pr-media.py")

    def test_the_writer_patterns_catch_common_upload_shapes(self) -> None:
        for line in ('gh api -X PUT "repos/o/r/contents/x"', "curl -XPUT https://api.github.com/x",
                     "requests.put(url, json=body)", "gh api --method put x", "git -C media \\\n  push origin HEAD",
                     '["git", "push", "origin"]', "gh api -X PATCH repos/o/r/git/refs/heads/x",
                     "mutation { createCommitOnBranch(input: $i) { commit { oid } } }"):
            with self.subTest(line=line):
                self.assertIsNotNone(self.DIRECT.search(line))


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
