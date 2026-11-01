#!/usr/bin/env python3
"""PR media privacy gate: what counts as a private name, what gets removed, and how CI publishes."""
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import shutil
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

    def check(self, items, ocr=fake_ocr):
        report = privacy.check_files(items, self.patterns, ocr)
        return {item["path"]: item["action"] for item in report["files"]}, report

    def test_every_hit_is_refused_whoever_owns_the_folder(self) -> None:
        # Leo, 2026-10-22: "1 ok": a teammate's PR is refused like an agent's or a bot's.
        leak, clean = self.file("leak.png"), self.file("clean.png")
        notes = self.file("notes.md", "ssh g1ow-box")
        actions, report = self.check([("10/leak.png", leak), ("10/clean.png", clean), ("11/leak.png", leak),
                                      ("12/notes.md", notes), ("ui-lab/leak.png", leak),
                                      ("nightly-next/r/leak.png", leak), ("fuzz/d/1/leak.png", leak)])
        self.assertEqual(actions, dict.fromkeys(["10/leak.png", "11/leak.png", "12/notes.md", "ui-lab/leak.png",
                                                 "nightly-next/r/leak.png", "fuzz/d/1/leak.png"], "refuse"))
        self.assertTrue(report["refused"])
        self.assertNotIn("cmux7s", json.dumps(report))
        self.assertNotIn("g1ow", json.dumps(report))

    def test_a_refusal_names_the_category_and_the_fix_never_the_term(self) -> None:
        env = {"HOME": str(self.root), "PR_MEDIA_PRIVATE_TERMS": '["glow-box"]', "PR_MEDIA_AGENT_AUTHORS": "bot-a"}
        lookup = mock.Mock(return_value={10: "teammate"})
        with contextlib.redirect_stderr(io.StringIO()) as err, self.assertRaises(privacy.Refused) as raised:
            privacy.check_upload([("10/notes.html", self.file("notes.html", "ssh glow-box")),
                                  ("10/prompt.md", self.file("prompt.md", "cmux@cmux7s-Mac-mini %"))],
                                 env=env, ocr=None, lookup=lookup)
        said = err.getvalue() + str(raised.exception)
        self.assertIn("10/notes.html shows a personal machine or account name; refused", said)
        self.assertIn("10/prompt.md (fleet Mac mini name, fleet shell prompt)", said)
        self.assertIn("Nothing was uploaded. Show fixture names in the scene instead", said)
        self.assertNotIn("glow", said.replace(str(self.root), ""))
        self.assertNotIn("cmux7s", said)
        lookup.assert_not_called()  # no PR author decides any more

    def test_every_kind_has_a_category(self) -> None:
        kinds = {kind for kind, _pattern in privacy.GENERIC_PATTERNS} | {"private-term", "email", "unreadable"}
        self.assertEqual(kinds - set(privacy.KIND_LABELS), set())

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
        self.assertIn("10/leak.png shows a personal machine or account name; refused", out)
        self.assertNotIn("glow", out.replace(str(self.root), ""))  # never the matched text
        code, out = self.run_check("11", "leak.png")  # a teammate's PR
        self.assertEqual(code, 1)
        self.assertIn("11/leak.png shows a personal machine or account name; refused", out)
        self.assertEqual(self.run_check("11", "clean.png")[0], 0)
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
                           ".github/workflows/pr-media.yml", ".github/actions/pr-media-publish/action.yml"}
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


def load_script(name: str, path: Path):
    script_spec = importlib.util.spec_from_file_location(name, path)
    assert script_spec and script_spec.loader
    module = importlib.util.module_from_spec(script_spec)
    sys.modules[script_spec.name] = module
    script_spec.loader.exec_module(module)
    return module


PNG = b"\x89PNG\r\n\x1a\n" + b"0" * 32
# A local file holding LEAK reads as a fleet prompt to the fake OCR below.
FAKE_OCR = '#!/bin/sh\nif grep -q LEAK "$1"; then echo "cmux@cmux7s-Mac-mini ~ %"; else echo ok; fi\n'


class GatedWriterCase(unittest.TestCase):
    """The real scripts/pr-media.py and privacy module inside the publishing
    action's environment, with a fake OCR tool and a fake gh.

    A hit refuses in every folder; no PR author is looked up.
    """

    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory(prefix="cmux-pr-media-gated-writer-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        ocr = self.root / "ocr.sh"
        ocr.write_text(FAKE_OCR)
        ocr.chmod(0o755)
        environment = mock.patch.dict(os.environ, {
            "HOME": str(self.root), "GITHUB_ACTIONS": "true", "PR_MEDIA_PRIVACY_OCR": str(ocr),
            "PR_MEDIA_PRIVATE_TERMS": '["glow-box"]', "PR_MEDIA_PRIVATE_TERMS_FILE": "", "CMUX_HQ": "",
            "PR_MEDIA_AGENT_AUTHORS": "", "PR_MEDIA_PUBLISH_GATE": "1"})
        environment.start()
        self.addCleanup(environment.stop)
        self.pr_media = load_script("pr_media_gated_writer_test", ROOT / "scripts/pr-media.py")
        self.puts: list[str] = []
        real_run = subprocess.run

        def run(argv, *args, **kwargs):
            if argv[:2] != ["gh", "api"]:
                return real_run(argv, *args, **kwargs)
            if "PUT" in argv:
                self.puts.append(argv[4].split("/contents/", 1)[1].split("?", 1)[0])
                return subprocess.CompletedProcess(argv, 0, stdout="{}", stderr="")
            return subprocess.CompletedProcess(argv, 1, stdout="", stderr="gh: Not Found (HTTP 404)")

        patched = mock.patch.object(self.pr_media.subprocess, "run", side_effect=run)
        patched.start()
        self.addCleanup(patched.stop)

    def put(self, remote: str, local: Path) -> None:
        with contextlib.redirect_stderr(io.StringIO()):
            self.pr_media.put_file("o/r", "pr-media", remote, local, "msg")


class PublishGateTests(GatedWriterCase):
    """scripts/pr-media.py in GitHub Actions writes only inside .github/actions/pr-media-publish."""

    def test_a_ci_step_outside_the_action_writes_nothing(self) -> None:
        shot = self.root / "shot.png"
        shot.write_bytes(PNG)
        with mock.patch.dict(os.environ, {"PR_MEDIA_PUBLISH_GATE": ""}), \
                self.assertRaises(self.pr_media.PrivacyError) as raised:
            self.put("nightly-next/1/shot.png", shot)
        self.assertEqual(self.puts, [])
        self.assertIn(".github/actions/pr-media-publish", str(raised.exception))

    def test_without_the_terms_list_nothing_is_written(self) -> None:
        page = self.root / "index.html"
        page.write_text("<p>ok</p>")
        with mock.patch.dict(os.environ, {"PR_MEDIA_PRIVATE_TERMS": ""}), \
                self.assertRaises(self.pr_media.PrivacyError) as raised:
            self.put("nightly-next/1/index.html", page)
        self.assertEqual(self.puts, [])
        self.assertIn("environment: pr-media", str(raised.exception))

    def test_without_an_ocr_tool_no_image_is_written(self) -> None:
        shot = self.root / "shot.png"
        shot.write_bytes(PNG)
        with mock.patch.dict(os.environ, {"PR_MEDIA_PRIVACY_OCR": "none"}), \
                self.assertRaises(self.pr_media.PrivacyError) as raised:
            self.put("nightly-next/1/shot.png", shot)
        self.assertEqual(self.puts, [])
        self.assertIn("OCR", str(raised.exception))

    def test_a_tours_private_name_is_refused_before_the_write(self) -> None:
        shot = self.root / "shot.png"
        shot.write_bytes(PNG + b"LEAK")
        with self.assertRaises(self.pr_media.PrivacyError):
            self.put("nightly-next/1/shot.png", shot)
        self.assertEqual(self.puts, [])

    def test_a_clean_shot_is_written(self) -> None:
        shot = self.root / "shot.png"
        shot.write_bytes(PNG)
        self.put("nightly-next/1/shot.png", shot)
        self.assertEqual(self.puts, ["nightly-next/1/shot.png"])

    def test_off_ci_the_gate_is_not_needed(self) -> None:
        page = self.root / "index.html"
        page.write_text("<p>ok</p>")
        with mock.patch.dict(os.environ, {"GITHUB_ACTIONS": "", "PR_MEDIA_PUBLISH_GATE": ""}):
            self.put("nightly-next/1/index.html", page)
        self.assertEqual(self.puts, ["nightly-next/1/index.html"])


GATE = ROOT / "scripts/ci/pr_media_gate.py"
TESSERACT_TOOL = ROOT / "scripts/ci/pr_media_ocr_tesseract.py"
ACTION = ROOT / ".github/actions/pr-media-publish/action.yml"
CANARY = ROOT / ".github/actions/pr-media-publish/canary.png"
FIXTURES = ROOT / "tests/fixtures/pr_media_gate"


class GatePreflightTests(unittest.TestCase):
    """scripts/ci/pr_media_gate.py: terms present and the OCR catches the canary, or no publish."""

    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory(prefix="cmux-pr-media-gate-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.gate = load_script("pr_media_gate_test", GATE)

    def ocr(self, text: str) -> str:
        tool = self.root / f"ocr-{len(list(self.root.iterdir()))}.sh"
        tool.write_text(f"#!/bin/sh\necho '{text}'\n")
        tool.chmod(0o755)
        return str(tool)

    def preflight(self, **env: str) -> str:
        environment = {"HOME": str(self.root), "GITHUB_ACTIONS": "true", **env}
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            return self.gate.preflight(CANARY, env=environment, privacy=privacy)

    def test_an_ocr_that_reads_the_canary_passes(self) -> None:
        tool = self.ocr("cmux@cmux-mac-mini-7 ~ %")
        self.assertEqual(self.preflight(PR_MEDIA_PRIVATE_TERMS='["glow-box"]', PR_MEDIA_PRIVACY_OCR=tool), tool)

    def test_a_blind_ocr_stops_the_publish(self) -> None:
        with self.assertRaises(SystemExit) as raised:
            self.preflight(PR_MEDIA_PRIVATE_TERMS='["glow-box"]', PR_MEDIA_PRIVACY_OCR=self.ocr("nothing here"))
        self.assertIn("did not catch the canary", str(raised.exception))

    def test_an_ocr_that_crashes_stops_the_publish(self) -> None:
        # The check holds an unreadable file like a hit; the canary must be caught by a pattern.
        tool = self.root / "crash.sh"
        tool.write_text("#!/bin/sh\nexit 1\n")
        tool.chmod(0o755)
        with self.assertRaises(SystemExit) as raised:
            self.preflight(PR_MEDIA_PRIVATE_TERMS='["glow-box"]', PR_MEDIA_PRIVACY_OCR=str(tool))
        self.assertIn("could not read the canary", str(raised.exception))

    def test_no_terms_list_stops_the_publish(self) -> None:
        for terms in ("", "   ", "[]", '["io"]'):
            with self.subTest(terms=terms), self.assertRaises(SystemExit):
                self.preflight(PR_MEDIA_PRIVATE_TERMS=terms, PR_MEDIA_PRIVACY_OCR=self.ocr("cmux@cmux-mac-mini"))

    def test_no_ocr_tool_stops_the_publish(self) -> None:
        with self.assertRaises(SystemExit) as raised:
            self.preflight(PR_MEDIA_PRIVATE_TERMS='["glow-box"]', PR_MEDIA_PRIVACY_OCR="none")
        self.assertIn("no OCR tool", str(raised.exception))

    def test_the_terms_are_never_printed(self) -> None:
        tool = self.ocr("cmux@cmux-mac-mini-7 ~ %")
        out = io.StringIO()
        with contextlib.redirect_stderr(io.StringIO()):
            self.gate.preflight(CANARY, env={"HOME": str(self.root), "GITHUB_ACTIONS": "true",
                                             "PR_MEDIA_PRIVATE_TERMS": '["glow-box"]',
                                             "PR_MEDIA_PRIVACY_OCR": tool}, privacy=privacy, out=out)
        self.assertNotIn("glow-box", out.getvalue())
        self.assertIn("1 private term", out.getvalue())


FAKE_TESSERACT = """#!/bin/sh
# Reads the picture on stdin; mode 3 and mode 11 each see part of it.
picture="$(cat)"
case "$picture" in *BROKEN*) exit 1 ;; esac
case "$4" in
  3) printf 'Workspace\\nshared line\\n' ;;
  11) printf 'shared line\\nlabel %s\\n' "$picture" ;;
esac
"""
# Writes three frames (two identical) for fps=1, and the last frame for -update.
FAKE_FFMPEG = """#!/bin/sh
for last; do :; done
case "$last" in
  *%05d.png) dir="$(dirname "$last")"; printf A > "$dir/00001.png"; printf A > "$dir/00002.png"; printf B > "$dir/00003.png" ;;
  *) printf C > "$last" ;;
esac
"""


class TesseractToolTests(unittest.TestCase):
    """scripts/ci/pr_media_ocr_tesseract.py keeps pr_media_ocr.swift's output contract."""

    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory(prefix="cmux-pr-media-tesseract-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        for name, text in (("tesseract", FAKE_TESSERACT), ("ffmpeg", FAKE_FFMPEG)):
            (bin_dir / name).write_text(text)
            (bin_dir / name).chmod(0o755)
        self.env = {**os.environ, "PATH": f"{bin_dir}{os.pathsep}{os.environ.get('PATH', '')}"}

    def run_tool(self, path: Path, env: dict | None = None) -> subprocess.CompletedProcess:
        return subprocess.run([sys.executable, str(TESSERACT_TOOL), str(path)], capture_output=True, text=True,
                              env=env or self.env, timeout=60)

    def test_a_still_prints_both_modes_once_each(self) -> None:
        shot = self.root / "shot.png"
        shot.write_text("X")
        done = self.run_tool(shot)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(done.stdout.splitlines(), ["Workspace", "shared line", "label X"])

    def test_a_video_prints_each_distinct_frame_after_a_marker(self) -> None:
        clip = self.root / "tour.mp4"
        clip.write_bytes(b"mp4")
        done = self.run_tool(clip)
        self.assertEqual(done.returncode, 0, done.stderr)
        frames = [line for line in done.stdout.splitlines() if line.startswith("@@frame")]
        self.assertEqual(frames, ["@@frame 0", "@@frame 1", "@@frame 2"])  # A, B and the last, C
        self.assertEqual([line for line in done.stdout.splitlines() if line.startswith("label")],
                         ["label A", "label B", "label C"])
        # The privacy module drops the markers.
        self.assertTrue(all(privacy.FRAME_SEPARATOR.match(line) for line in frames))

    def test_an_unreadable_picture_exits_2_so_the_gate_holds_it(self) -> None:
        shot = self.root / "shot.png"
        shot.write_text("BROKEN")
        self.assertEqual(self.run_tool(shot).returncode, 2)
        self.assertEqual(self.run_tool(self.root / "missing.png").returncode, 2)
        with mock.patch.dict(os.environ, {"PATH": self.env["PATH"]}), self.assertRaises(RuntimeError):
            privacy.ocr_file(str(TESSERACT_TOOL), shot)

    def test_without_tesseract_the_tool_refuses(self) -> None:
        shot = self.root / "shot.png"
        shot.write_text("X")
        (self.root / "bin" / "tesseract").unlink()
        done = self.run_tool(shot, env={**self.env, "PATH": str(self.root / "bin")})
        self.assertEqual(done.returncode, 2)
        self.assertIn("tesseract is not installed", done.stderr)

    def test_the_tools_get_no_secret_or_token(self) -> None:
        # The media comes from a pull request's run; tesseract and ffmpeg parse it.
        bin_dir = self.root / "bin"
        (bin_dir / "tesseract").write_text("#!/bin/sh\ncat >/dev/null\nenv\n")
        shot = self.root / "shot.png"
        shot.write_text("X")
        done = self.run_tool(shot, env={**self.env, "GH_TOKEN": "t0ken", "PR_MEDIA_PRIVATE_TERMS": '["glow-box"]'})
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertNotIn("t0ken", done.stdout)
        self.assertNotIn("glow-box", done.stdout)
        self.assertIn("OMP_THREAD_LIMIT=1", done.stdout)


@unittest.skipUnless(shutil.which("tesseract"), "needs a real tesseract (the publishing action installs it)")
class SeededTermEndToEndTests(GatedWriterCase):
    """Real tesseract, the real check and pr-media.py's real put_file with a fake gh:
    a picture that shows a seeded private term is refused before anything is written."""

    def setUp(self) -> None:
        super().setUp()
        environment = mock.patch.dict(os.environ, {"PR_MEDIA_PRIVACY_OCR": str(TESSERACT_TOOL),
                                                   "PR_MEDIA_PRIVATE_TERMS": '["zephyrquill"]'})
        environment.start()
        self.addCleanup(environment.stop)

    def test_the_seeded_term_is_refused_and_nothing_is_written(self) -> None:
        with self.assertRaises(self.pr_media.PrivacyError) as raised:
            self.put("nightly-next/1/seeded.png", FIXTURES / "seeded-private-term.png")
        self.assertEqual(self.puts, [])
        self.assertNotIn("zephyrquill", str(raised.exception))

    def test_the_canary_is_refused(self) -> None:
        with self.assertRaises(self.pr_media.PrivacyError):
            self.put("nightly-next/1/canary.png", CANARY)
        self.assertEqual(self.puts, [])

    def test_a_teammates_seeded_term_is_refused_too(self) -> None:
        with mock.patch.dict(os.environ, {"PR_MEDIA_AGENT_AUTHORS": "bot-a"}), \
                self.assertRaises(self.pr_media.PrivacyError) as raised:
            self.put("24001/seeded.png", FIXTURES / "seeded-private-term.png")
        self.assertEqual(self.puts, [])
        self.assertIn("personal machine or account name", str(raised.exception))
        self.assertNotIn("zephyrquill", str(raised.exception))

    def test_a_clean_picture_is_written(self) -> None:
        self.put("nightly-next/1/clean.png", FIXTURES / "clean.png")
        self.assertEqual(self.puts, ["nightly-next/1/clean.png"])

    def test_the_preflight_passes_with_real_tesseract(self) -> None:
        gate = load_script("pr_media_gate_e2e_test", GATE)
        with contextlib.redirect_stderr(io.StringIO()), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(gate.preflight(CANARY, privacy=privacy), str(TESSERACT_TOOL))


class PublishWorkflowTests(unittest.TestCase):
    """Every workflow job that writes pr-media does it through .github/actions/pr-media-publish,
    inside the pr-media environment; nothing else reads the private-terms secret but the
    rescan, and no pull_request_target job comes near either."""

    # workflow -> job id -> the script its publishing step runs
    WRITER_JOBS = {".github/workflows/pr-media.yml": {"publish": "scripts/ci/pr_media.py"}}
    # Remove files or rewrite the retention index; they add no capture.
    REMOVES_ONLY = {".github/workflows/pr-media-prune.yml", ".github/workflows/pr-media-privacy.yml"}
    # The 10-minute Vision rescan reads the repository's copy of the terms secret.
    RESCAN = (".github/workflows/pr-media-privacy.yml", "scan")
    ACTION_USE = "./.github/actions/pr-media-publish"
    NEEDED = (".github/actions/pr-media-publish", "scripts/pr-media.py", "scripts/ci/pr_media_privacy.py",
              "scripts/ci/pr_media_gate.py", "scripts/ci/pr_media_ocr_tesseract.py", "scripts/ci/pr_media_ocr.swift")
    WRITERS = ("scripts/pr-media.py", "scripts/ci/pr_media.py", "scripts/showcase-publish.py")

    @staticmethod
    def runs_a_writer(run: str, script: str | None = None) -> bool:
        """The step runs the writer (`python3 <script>`, `./<script>`), not merely names it
        (`[ -f <script> ]`, a comment)."""
        scripts = [script] if script else list(PublishWorkflowTests.WRITERS)
        for name in scripts:
            for found in re.finditer(re.escape(name), run):
                before = run[run.rfind("\n", 0, found.start()) + 1:found.start()]
                if before.lstrip().startswith("#") or re.search(r"-[efsx]\s+[\"']?(?:\./)?$", before):
                    continue
                # pr_media.py plans and tours too; only `publish` writes.
                if name == "scripts/ci/pr_media.py" and not re.match(r"\s+publish\b", run[found.end():]):
                    continue
                return True
        return False

    @staticmethod
    def publish_command(given: dict) -> str:
        """The command the action's Publish step runs for these `with:` inputs."""
        args = [line for line in str(given.get("args", "")).splitlines() if line]
        return " ".join(["python3", str(given.get("script", "")), *args])

    def test_the_writer_shapes_are_recognized(self) -> None:
        for run in ("python3 scripts/pr-media.py --pr 1 a.png", "./scripts/pr-media.py --pr 1 a.png",
                    'python3 scripts/ci/pr_media.py publish --media "$RUNNER_TEMP/media"',
                    "python3 scripts/showcase-publish.py --pr 1"):
            with self.subTest(run=run):
                self.assertTrue(self.runs_a_writer(run))
        for run in ("[ -f scripts/pr-media.py ] && echo yes", "# scripts/pr-media.py uploads",
                    "python3 scripts/ci/pr_media.py plan", 'exec "$PY" scripts/ci/pr_media.py tour'):
            with self.subTest(run=run):
                self.assertFalse(self.runs_a_writer(run))

    @staticmethod
    def covers(sparse: str, path: str) -> bool:
        for line in (line.strip().rstrip("/") for line in sparse.splitlines()):
            if line and (path == line or path.startswith(line + "/")):
                return True
        return False

    _loaded: dict[str, dict] = {}

    @classmethod
    def load(cls, workflow: str) -> dict:
        if workflow not in cls._loaded:
            cls._loaded[workflow] = yaml.load((ROOT / workflow).read_text(encoding="utf-8"),
                                              Loader=getattr(yaml, "CSafeLoader", yaml.SafeLoader)) or {}
        return cls._loaded[workflow]

    @classmethod
    def workflows(cls):
        for path in sorted((ROOT / ".github/workflows").glob("*.y*ml")):
            workflow = path.relative_to(ROOT).as_posix()
            yield workflow, cls.load(workflow)

    @staticmethod
    def triggers(loaded: dict) -> set[str]:
        on = loaded.get(True, loaded.get("on")) or {}
        return {on} if isinstance(on, str) else set(on)

    @staticmethod
    def in_pr_media_environment(job: dict) -> bool:
        environment = job.get("environment")
        name = environment.get("name") if isinstance(environment, dict) else environment
        return "pr-media" in str(name or "")

    def writes_pr_media(self, job: dict) -> bool:
        """The job runs a writer, publishes through the action, or names the branch and writes to it."""
        text = yaml.dump(job)
        for step in job.get("steps") or []:
            if str(step.get("uses", "")).startswith(self.ACTION_USE) or self.runs_a_writer(str(step.get("run", ""))):
                return True
        return bool(WriterInventoryTests.MEDIA.search(text) and WriterInventoryTests.DIRECT.search(text))

    def test_only_the_action_sets_the_publish_gate(self) -> None:
        for workflow in sorted((ROOT / ".github/workflows").glob("*.y*ml")):
            with self.subTest(workflow=workflow.name):
                self.assertNotIn("PR_MEDIA_PUBLISH_GATE", workflow.read_text(encoding="utf-8"))
        self.assertIn("PR_MEDIA_PUBLISH_GATE", ACTION.read_text(encoding="utf-8"))

    def test_every_job_that_writes_pr_media_publishes_through_the_action(self) -> None:
        found = {}
        for workflow, loaded in self.workflows():
            if workflow in self.REMOVES_ONLY:
                continue
            for job_id, job in (loaded.get("jobs") or {}).items():
                if not self.writes_pr_media(job):
                    continue
                found.setdefault(workflow, set()).add(job_id)
                with self.subTest(workflow=workflow, job=job_id):
                    self.assertEqual(job.get("environment"), "pr-media",
                                     "a pr-media writer runs in the pr-media environment (the terms list lives there)")
                    for step in job.get("steps") or []:
                        self.assertFalse(self.runs_a_writer(str(step.get("run", ""))),
                                         f"step {step.get('name')!r} writes pr-media outside {self.ACTION_USE}")
                        run = str(step.get("run", ""))
                        if WriterInventoryTests.MEDIA.search(run):
                            self.assertIsNone(WriterInventoryTests.DIRECT.search(run),
                                              f"step {step.get('name')!r} pushes to pr-media itself")
                    uses = [step for step in job.get("steps") or [] if step.get("uses") == self.ACTION_USE]
                    self.assertTrue(uses, f"no step uses {self.ACTION_USE}")
                    for step in uses:
                        given = step.get("with") or {}
                        self.assertEqual(given.get("private-terms"), "${{ secrets.PR_MEDIA_PRIVATE_TERMS }}")
                        self.assertEqual(given.get("agent-authors"), "${{ vars.PR_MEDIA_AGENT_AUTHORS }}")
                        self.assertTrue(self.runs_a_writer(self.publish_command(given)))
                        self.assertNotIn("PR_MEDIA_PRIVATE_TERMS", step.get("env") or {})
        expected = {workflow: set(jobs) for workflow, jobs in self.WRITER_JOBS.items()}
        self.assertEqual(found, expected, "a new pr-media writer job: publish through the action, then list it")

    def test_each_writer_job_checks_out_what_the_action_runs(self) -> None:
        for workflow, jobs in self.WRITER_JOBS.items():
            loaded = self.load(workflow)
            for job_id, script in jobs.items():
                with self.subTest(workflow=workflow, job=job_id):
                    steps = loaded["jobs"][job_id]["steps"]
                    checkouts = [step for step in steps if str(step.get("uses", "")).startswith("actions/checkout@")]
                    self.assertEqual(len(checkouts), 1)
                    sparse = checkouts[0].get("with", {}).get("sparse-checkout", "")
                    for path in (*self.NEEDED, script):
                        self.assertTrue(self.covers(sparse, path), f"{workflow} {job_id} does not check out {path}")
                    commands = [self.publish_command(step.get("with") or {}) for step in steps
                                if step.get("uses") == self.ACTION_USE]
                    self.assertTrue(any(self.runs_a_writer(command, script) for command in commands),
                                    f"{workflow} {job_id} no longer publishes {script} through the action")

    def test_only_the_action_in_the_pr_media_environment_reads_the_terms_secret(self) -> None:
        readers = set()
        for workflow, loaded in self.workflows():
            with self.subTest(workflow=workflow):
                # A workflow-level env reaches every job, so the terms are only ever read inside a job.
                self.assertFalse(self.may_read_terms(self.text_of(loaded.get("env") or {})))
            for job_id, job in (loaded.get("jobs") or {}).items():
                if not self.may_read_terms(self.text_of(job)):
                    continue
                readers.add((workflow, job_id))
                if (workflow, job_id) == self.RESCAN:
                    continue
                with self.subTest(workflow=workflow, job=job_id):
                    self.assertEqual(job.get("environment"), "pr-media")
                    for step in job.get("steps") or []:
                        if self.may_read_terms(self.text_of(step)):
                            self.assertEqual(step.get("uses"), self.ACTION_USE)
        self.assertIn(self.RESCAN, readers, "the rescan no longer reads the terms; drop its exemption")

    # Events whose runs take the default or base branch's ref (which the environment admits) while someone
    # outside the repo chooses when they fire: a PR (pull_request_target), a fork's finished run (workflow_run),
    # any commenter (issue_comment, issues).
    UNTRUSTED_EVENTS = {"pull_request_target", "workflow_run", "issue_comment", "issues"}

    @staticmethod
    def environment(job: dict) -> str:
        env = job.get("environment")
        return str((env.get("name") if isinstance(env, dict) else env) or "")

    @staticmethod
    def split_top(text: str, op: str) -> list[str]:
        """text split on op outside quotes and parentheses."""
        parts, depth, quoted, last, i = [], 0, False, 0, 0
        while i < len(text):
            c = text[i]
            if c == "'":
                quoted = not quoted
            elif not quoted and c in "([":
                depth += 1
            elif not quoted and c in ")]" and depth:
                depth -= 1
            elif not quoted and depth == 0 and text.startswith(op, i):
                parts.append(text[last:i])
                last = i + len(op)
                i = last
                continue
            i += 1
        return parts + [text[last:]]

    def outcomes(self, expression: str) -> list[str] | None:
        """The strings an expression can yield, or None when one comes from outside it: `a || b` yields a or b,
        `a && b` yields b (or a falsy a, which names no environment)."""
        expression = expression.strip()
        if expression.startswith("(") and self.split_top(expression[1:], ")") == [expression[1:-1], ""]:
            return self.outcomes(expression[1:-1])
        branches = self.split_top(expression, "||")
        if len(branches) > 1:
            found = [self.outcomes(branch) for branch in branches]
            return None if None in found else [value for values in found for value in values]
        operands = self.split_top(expression, "&&")
        if len(operands) > 1:
            return self.outcomes(operands[-1])
        return [expression[1:-1]] if re.fullmatch(r"'[^']*'", expression) else None

    def may_name_pr_media(self, name: str) -> bool:
        """The environment can be pr-media: GitHub matches names without case, and an expression whose value
        comes from outside it could be anything."""
        names = [""]
        for i, piece in enumerate(re.split(r"\$\{\{(.*?)\}\}", name, flags=re.S)):
            values = self.outcomes(piece) if i % 2 else [piece]
            if values is None:
                return True
            names = [n + v for n in names for v in values]
        return any("pr-media" in n.lower() for n in names)

    TERMS = "PR_MEDIA_PRIVATE_TERMS"

    @classmethod
    def text_of(cls, node) -> str:
        """Every key and string in a loaded job or step, as written (yaml.dump would re-quote `'` as `''`)."""
        if isinstance(node, dict):
            return "\n".join(cls.text_of(k) + "\n" + cls.text_of(v) for k, v in node.items())
        if isinstance(node, list):
            return "\n".join(cls.text_of(v) for v in node)
        return node if isinstance(node, str) else ""

    @classmethod
    def may_read_terms(cls, text: str) -> bool:
        """text may read the terms secret: by name in any case, through toJSON(secrets), or through a secrets[...]
        index unless it is a literal (read by name above) or a format() whose fixed prefix rules the name out
        (nightly.yml's `format('APPLE_{0}_...', ...)`). GitHub matches contexts, functions and secret names
        without case."""
        if cls.TERMS.lower() in text.lower() or re.search(r"tojson\(\s*secrets\s*\)", text, re.I):
            return True
        # The whole secrets object in an expression (not secrets.NAME or secrets[...]) can carry every secret.
        for expression in re.findall(r"\$\{\{(.*?)\}\}", text, re.S):
            if re.search(r"(?<![\w.])secrets(?!\w)(?!\s*[.\[])", expression, re.I):
                return True
        for index in re.findall(r"secrets\s*\[([^\]]*)\]", text, re.I):
            if re.fullmatch(r"\s*'[^']*'\s*", index):
                continue
            prefix = re.match(r"\s*format\(\s*'([^'{]*)", index, re.I)
            if not prefix or cls.TERMS.startswith(prefix.group(1).upper()):
                return True
        return False

    def holds_pr_media(self, job: dict) -> bool:
        """The job may enter the pr-media environment, read its terms secret, hand every secret to a workflow
        outside this repository (whose jobs this scan cannot read) or publish through the action."""
        return (self.may_name_pr_media(self.environment(job))
                or self.may_read_terms(self.text_of(job))
                or (job.get("secrets") == "inherit" and not str(job.get("uses", "")).startswith("./"))
                or any(str(step.get("uses", "")).startswith(self.ACTION_USE) for step in job.get("steps") or []))

    def untrusted_event_jobs(self, workflows) -> list[tuple[str, str, dict]]:
        """(workflow, job, job) for every job an untrusted event runs, including the jobs of the local reusable
        workflows it calls: those run in the caller's event, on the caller's ref. A WRITER_JOBS job is left out
        when workflow_run is its workflow's only untrusted event: the publisher runs the default branch's copy of
        itself and checks what it reads (test_the_writer_runs_only_on_workflow_run_or_dispatch)."""
        loaded = dict(workflows)
        out, seen = [], set()
        # (workflow, called): a called workflow runs in its caller's event, whatever its own triggers say.
        todo = [(w, False) for w, doc in loaded.items() if self.UNTRUSTED_EVENTS & self.triggers(doc)]
        while todo:
            workflow, called = todo.pop()
            if (workflow, called) in seen:
                continue
            seen.add((workflow, called))
            doc = loaded.get(workflow, {})
            exempt = self.WRITER_JOBS.get(workflow, {}) if (
                not called and (self.UNTRUSTED_EVENTS & self.triggers(doc)) == {"workflow_run"}) else {}
            for job_id, job in (doc.get("jobs") or {}).items():
                uses = str(job.get("uses", ""))
                if uses.startswith("./.github/workflows/"):
                    todo.append((uses[2:].split("@")[0], True))
                if job_id not in exempt:
                    # Every job inherits the workflow's env.
                    if doc.get("env"):
                        job = {**job, "env": {**doc["env"], **(job.get("env") or {})}}
                    out.append((workflow, job_id, job))
        return out

    def test_the_untrusted_event_scan_finds_called_workflows_and_expression_environments(self) -> None:
        workflows = [
            (".github/workflows/a.yml", {True: {"pull_request_target": {"types": ["opened"]}},
                                         "jobs": {"call": {"uses": "./.github/workflows/b.yml"}}}),
            (".github/workflows/b.yml", {"on": "workflow_call",
                                         "jobs": {"post": {"environment": {"name": "pr-media"}, "steps": []}}}),
            (".github/workflows/c.yml", {True: ["push"], "jobs": {"post": {"environment": "pr-media"}}}),
            (".github/workflows/d.yml", {True: {"issue_comment": None}, "jobs": {
                "case": {"environment": "PR-Media"},
                "cond": {"environment": "${{ github.event_name == 'issue_comment' && 'pr-media' || '' }}"},
                "named": {"environment": {"name": "${{ 'pr-' }}media"}},
                "output": {"environment": "${{ needs.decide.outputs.environment }}"},
                "fallback": {"environment": "${{ inputs.x == 'y' && 'ci-bot' || vars.ENV }}"},
                "secret": {"steps": [{"run": "echo ${{ secrets['pr_media_private_terms'] }}"}]},
                "other": {"environment": "${{ (needs.plan.outputs.go == 'true' && ('ci-bot')) || '' }}"},
                "pairs": {"environment": "${{ (inputs.x) && ('ci-bot') }}"},
                "plain": {"environment": "ci-bot"},
                "dyn": {"steps": [{"run": "echo ${{ secrets[format('PR_MEDIA_{0}', 'PRIVATE_TERMS')] }}"}]},
                "open": {"steps": [{"env": {"X": "${{ secrets[format('{0}', vars.NAME)] }}"}}]},
                "mixed": {"steps": [{"run": "echo ${{ Secrets[FORMAT('pr_media_{0}', 'PRIVATE_TERMS')] }}"}]},
                "var": {"steps": [{"env": {"X": "${{ secrets[vars.NAME] }}"}}]},
                "all": {"steps": [{"env": {"X": "${{ toJSON(secrets) }}"}}]},
                "whole": {"steps": [{"with": {"x": "${{ fromJSON(format('{0}', Secrets)) }}"}}]},
                "apple": {"steps": [{"env": {"X": "${{ secrets[format('APPLE_{0}_KEY', inputs.channel)] }}"}}]},
                "lit": {"steps": [{"env": {"X": "${{ secrets['APPLE_KEY'] }}"}}]},
                "away": {"uses": "someone/else/.github/workflows/x.yml@main", "secrets": "inherit"},
                "home": {"uses": "./.github/workflows/b2.yml", "secrets": "inherit"},
            }}),
            (".github/workflows/b2.yml", {"on": "workflow_call", "jobs": {"quiet": {"steps": []}}}),
            (".github/workflows/f.yml", {True: {"issue_comment": None},
                                         "env": {"TERMS": "${{ secrets.PR_MEDIA_PRIVATE_TERMS }}"},
                                         "jobs": {"inherits": {"steps": [{"run": 'printf %s "$TERMS"'}]}}}),
            # The writer is exempt only when workflow_run fires it: not another job beside it, and not when an
            # untrusted event's workflow calls it.
            (".github/workflows/pr-media.yml", {True: {"workflow_run": None, "workflow_call": None}, "jobs": {
                "publish": {"environment": "pr-media"}, "extra": {"environment": "pr-media"}}}),
            (".github/workflows/e.yml", {True: {"issues": None}, "jobs": {
                "call": {"uses": "./.github/workflows/pr-media.yml"}}}),
        ]
        found = sorted((w, j) for w, j, job in self.untrusted_event_jobs(workflows) if self.holds_pr_media(job))
        self.assertEqual(found, [(".github/workflows/b.yml", "post")] + [
            (".github/workflows/d.yml", j) for j in ("all", "away", "case", "cond", "dyn", "fallback", "mixed", "named",
                                                     "open", "output", "secret", "var", "whole")] + [
            (".github/workflows/f.yml", "inherits"),
            (".github/workflows/pr-media.yml", "extra"), (".github/workflows/pr-media.yml", "extra"),
            (".github/workflows/pr-media.yml", "publish")])

    def test_no_untrusted_event_job_holds_the_pr_media_environment_or_its_secret(self) -> None:
        # A deployment branch policy matches GITHUB_REF, and these events run on the base or default branch's ref,
        # which the environment admits: the environment alone would hand the terms list to a run an outsider fired.
        for workflow, job_id, job in self.untrusted_event_jobs(self.workflows()):
            with self.subTest(workflow=workflow, job=job_id):
                self.assertFalse(self.holds_pr_media(job),
                                 "a job an untrusted event runs may be in the pr-media environment or read its terms")

    def test_the_writer_runs_only_on_workflow_run_or_dispatch(self) -> None:
        for workflow in self.WRITER_JOBS:
            with self.subTest(workflow=workflow):
                # The writer runs on the default branch's copy of itself only.
                self.assertLessEqual(self.triggers(self.load(workflow)), {"workflow_run", "workflow_dispatch"})

    def test_the_action_checks_the_canary_before_it_publishes(self) -> None:
        steps = yaml.safe_load(ACTION.read_text(encoding="utf-8"))["runs"]["steps"]
        names = [step["name"] for step in steps]
        gate, publish = names.index("Check the terms list and the OCR against the canary"), names.index("Publish")
        self.assertLess(gate, publish)
        self.assertIn("pr_media_gate.py --canary", steps[gate]["run"])
        env = steps[publish]["env"]
        self.assertEqual(env["PR_MEDIA_PUBLISH_GATE"], "1")
        self.assertEqual(env["PR_MEDIA_PRIVATE_TERMS"], "${{ inputs.private-terms }}")
        self.assertEqual(env["PR_MEDIA_PRIVACY_OCR"], "${{ steps.gate.outputs.ocr }}")
        self.assertTrue(CANARY.is_file())
        # The publisher and its arguments reach bash through the environment, never by expression expansion,
        # and are run as a listed script with plain arguments, never as a shell string.
        run = steps[publish]["run"]
        self.assertNotIn("${{", run)
        self.assertNotIn("-c ", run)
        self.assertNotIn("eval", run)
        self.assertIn('python3 "$PUBLISH_SCRIPT" "${args[@]}"', run)
        self.assertNotIn("command", yaml.safe_load(ACTION.read_text(encoding="utf-8"))["inputs"])
        listed = set(re.findall(r"^\s*([\w./-]+\.py)\) ;;$", run, re.M))
        self.assertEqual(listed, {script for jobs in self.WRITER_JOBS.values() for script in jobs.values()},
                         "the action lists exactly the publishers its callers run")
        # A runner image's own apt run holds the lock for a while after boot.
        install = steps[names.index("Install the OCR tools")]["run"]
        self.assertEqual(install.count("apt-get"), install.count("apt-get -o DPkg::Lock::Timeout="))


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
