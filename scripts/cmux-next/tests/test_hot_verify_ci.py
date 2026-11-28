#!/usr/bin/env python3
"""hot-verify-ci.py: the plan verdict, the fleet step's packing, out.tar, staging, the PR comment and its edit.

No network, no gh, no engine: the engine's outputs and the worker's out.tar are made here.

    python3 -I scripts/cmux-next/tests/test_hot_verify_ci.py
"""
from __future__ import annotations

import base64
import importlib.util
import io
import os
import re
import shutil
import json
import sys
import subprocess
import tarfile
import tempfile
import textwrap
import unittest
from contextlib import redirect_stderr, redirect_stdout
from unittest import mock
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "scripts" / "cmux-next" / "hot-verify-ci.py"
WORKFLOW = ROOT / ".github" / "workflows" / "cmux-next-hot-verify.yml"
READ_PR = "Read the pull request"
WEB_PUBLISH = ROOT / ".github" / "workflows" / "cmux-next-web-bundle-publish.yml"
# tests/git_fixture_env.py, loaded by path (`python3 -I` puts no script folder on sys.path): the fetch fixture's
# repositories get git's auto maintenance off, so no detached writer is left when the temp folder goes.
_git_fixture_spec = importlib.util.spec_from_file_location("git_fixture_env", ROOT / "tests" / "git_fixture_env.py")
git_fixture_env = importlib.util.module_from_spec(_git_fixture_spec)
_git_fixture_spec.loader.exec_module(git_fixture_env)
spec = importlib.util.spec_from_file_location("hot_verify_ci", SCRIPT)
hv = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = hv
spec.loader.exec_module(hv)
RECEIPT_SCRIPT = ROOT / "scripts" / "cmux-next" / "hot-verify-receipt.py"
_receipt_spec = importlib.util.spec_from_file_location("hot_verify_receipt", RECEIPT_SCRIPT)
hr = importlib.util.module_from_spec(_receipt_spec)
_receipt_spec.loader.exec_module(hr)

HEAD = "a" * 40
OTHER = "b" * 40
APP = "c" * 40
MARKER = f"<!-- cmux-hot-verify sha={HEAD} app={APP} layers=web,rust source=pr -->"
PNG = b"\x89PNG\r\n\x1a\n" + b"\0" * 32


def unpack_inputs(chunks: list[str]) -> dict:
    """runner_capture.step_inputs, the worker's side of the packing."""
    text = "".join(c[1:] for c in chunks)
    return json.loads(zlib.decompress(base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))))


class Verdict(unittest.TestCase):
    def test_json_web_and_rust_is_eligible(self) -> None:
        found = hv.verdict(json.dumps({"layers": ["web", "rust"], "needs_build": False}))
        self.assertEqual(found, {"eligible": True, "layers": ["rust", "web"], "needs_build": False,
                                 "reason": "looks without a build: rust, web"})

    def test_daemon_is_the_rust_layer(self) -> None:
        self.assertEqual(hv.verdict('{"layers": ["daemon"], "needs_build": false}')["layers"], ["rust"])

    def test_needs_build_is_not_eligible(self) -> None:
        found = hv.verdict(json.dumps({"layers": ["web"], "needs_build": True}))
        self.assertFalse(found["eligible"])
        self.assertIn("needs a build", found["reason"])

    def test_a_swift_change_is_an_app_look(self) -> None:
        # cmux#61533 (2026-11-27): rust beside two Swift files planned needs_build and got no request for 9 h.
        plan = {"layers": ["rust"], "needs_build": True,
                "build": {"Swift": ["Sources/WindowRules+UpdateIdle.swift"],
                          "Swift, resources or manifests": ["Sources/UpdateIdleGate.swift"]}}
        found = hv.verdict(json.dumps(plan))
        self.assertEqual(found["layers"], ["app", "rust"])
        self.assertTrue(found["eligible"])
        self.assertTrue(found["needs_build"])
        self.assertIn("fleet app build", found["reason"])
        only = hv.verdict(json.dumps({"layers": [], "needs_build": True,
                                      "build": {"Swift": ["A.swift"], "strings": ["Localizable.xcstrings"]}}))
        self.assertEqual((only["eligible"], only["layers"]), (True, ["app"]))

    def test_other_builds_stay_build_required(self) -> None:
        for build in ({"Swift": ["Package.swift"]}, {"Swift": ["A.swift"], "web ABI": ["x"]},
                      {"strings": ["A.swift"]}, {}, {"Swift": []}):
            with self.subTest(build=build):
                found = hv.verdict(json.dumps({"layers": ["web"], "needs_build": True, "build": build}))
                self.assertFalse(found["eligible"])
                self.assertNotIn("app", found["layers"])

    def test_no_layer_is_not_eligible(self) -> None:
        found = hv.verdict(json.dumps({"layers": [], "needs_build": False}))
        self.assertFalse(found["eligible"])
        self.assertIn("nothing to look at", found["reason"])

    def test_an_unknown_layer_is_not_eligible(self) -> None:
        self.assertFalse(hv.verdict(json.dumps({"layers": ["web", "swift"], "needs_build": False}))["eligible"])

    def test_text_form(self) -> None:
        found = hv.verdict("layers: web,customize\nneeds_build: false\nnote: something\n")
        self.assertTrue(found["eligible"])
        self.assertEqual(found["layers"], ["customize", "web"])
        self.assertFalse(hv.verdict("layers: none\nneeds_build: false\n")["eligible"])
        self.assertFalse(hv.verdict("layers: web\nneeds_build: true\n")["eligible"])

    def test_garbage_is_not_eligible(self) -> None:
        for text in ("", "Traceback (most recent call last):", "[1, 2]", '{"layers": ["web"]}'):
            with self.subTest(text=text):
                self.assertFalse(hv.verdict(text)["eligible"])

    def test_output_lines_are_one_line_each(self) -> None:
        lines = hv.output_lines({"eligible": True, "layers": ["web"], "needs_build": False,
                                 "reason": "two\nlines"}).splitlines()
        self.assertEqual(lines, ["eligible=true", "layers=web", "needs_build=false", "reason=two lines"])


class Step(unittest.TestCase):
    def test_hq_ref_reads_commit_first(self) -> None:
        self.assertEqual(hv.hq_ref(json.dumps({"version": "5033525e660f", "commit": HEAD, "hq_commit": OTHER})), HEAD)
        self.assertEqual(hv.hq_ref(json.dumps({"hq_commit": HEAD, "commit_full": OTHER})), HEAD)
        self.assertEqual(hv.hq_ref(json.dumps({"version": "5033525e660f", "commit_full": OTHER.upper()})), OTHER)
        self.assertEqual(hv.hq_ref(json.dumps({"commit": "5033525e660f", "hq_commit": OTHER})), OTHER)

    def test_hq_ref_is_empty_without_a_full_commit(self) -> None:
        for text in ('{"version":"5033525e660f"}', '{"hq_commit":"5033525e660f"}', "", "not json", "[]"):
            with self.subTest(text=text):
                self.assertEqual(hv.hq_ref(text), "")

    def test_pack_round_trips_as_the_worker_reads_it(self) -> None:
        inputs = hv.step_inputs(43000, HEAD, "hv-43000-aaaaaaaaaaaa-1-1", True)
        chunks = hv.pack(inputs)
        self.assertTrue(all(c.startswith("z") and len(c) <= 2001 for c in chunks))
        self.assertEqual(unpack_inputs(chunks), {"mode": "hot-verify", "schema": 1, "pr": 43000, "head": HEAD,
                                                 "look": True, "video": True, "state": None, "nightly": "latest",
                                                 "nonce": "hv-43000-aaaaaaaaaaaa-1-1"})
        self.assertFalse(any(key.endswith("url") for key in unpack_inputs(chunks)))

    def test_pack_refuses_more_than_sixteen_chunks(self) -> None:
        noise = base64.b64encode(os.urandom(60000)).decode()
        with self.assertRaises(hv.Refused):
            hv.pack({"mode": "hot-verify", "state": noise})

    def test_step_inputs_need_a_full_head_and_a_nonce(self) -> None:
        for args in ((0, HEAD, "hv-x"), (1, "abc", "hv-x"), (1, HEAD, "nonce"), (1, HEAD, "hv-a b")):
            with self.subTest(args=args), self.assertRaises(hv.Refused):
                hv.step_inputs(*args, video=False)


def write_tar(path: Path, files: dict[str, bytes], extra=None) -> None:
    with tarfile.open(path, "w") as archive:
        for name, data in files.items():
            info = tarfile.TarInfo(name)
            info.size = len(data)
            archive.addfile(info, io.BytesIO(data))
        if extra:
            extra(archive)


def look_files(marker: str = MARKER, texts: dict | None = None, step: dict | None = None) -> dict[str, bytes]:
    receipt = {"marker": marker, "phases": {"plan": 1.5, "app": 12.25, "apply": 3},
               "push_to_first_shot_s": 210.5, "edit_to_visible_s": 1.2,
               "steps": {"steps": [{"ok": True}, {"ok": False}]}, "errors": []}
    media = ["before/light.png", "before/dark.png", "after/light.png", "after/dark.png", "steps/01-click.png"]
    files = {f"out/{rel}": PNG for rel in media}
    files["out/video.mp4"] = b"\0\0\0\x18ftypmp42"
    files["out/receipt.json"] = json.dumps(receipt).encode()
    files["out/step.json"] = json.dumps(step if step is not None else {
        "head": HEAD, "nightly": {"build": "4512", "commit": APP, "short_version": "0.70.1"},
        "phases": {"engine": 4.5, "nightly": 30, "look": 120}, "needs_build": False, "exit": 0}).encode()
    if texts is None:
        texts = {rel: {"text": [f"line in {rel}"], "privacy": []} for rel in [*media, "video.mp4"]}
    files["out/text.json"] = json.dumps(texts).encode()
    return files


class Result(unittest.TestCase):
    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.tmp = Path(tmp.name)

    def unpacked(self, files: dict[str, bytes]) -> Path:
        write_tar(self.tmp / "out.tar", files)
        return hv.unpack(self.tmp / "out.tar", self.tmp / "unpacked")

    def test_unpack_finds_the_receipt_folder(self) -> None:
        out = self.unpacked(look_files())
        self.assertEqual(out, self.tmp / "unpacked" / "out")
        self.assertTrue((out / "after" / "dark.png").is_file())

    def test_unpack_refuses_links_and_escapes(self) -> None:
        def link(archive):
            info = tarfile.TarInfo("out/evil")
            info.type = tarfile.SYMTYPE
            info.linkname = "/etc/passwd"
            archive.addfile(info)
        for name, extra, files in (("link", link, {}), ("dotdot", None, {"../x": b"1"}),
                                   ("absolute", None, {"/tmp/x": b"1"})):
            with self.subTest(name=name):
                path = self.tmp / f"{name}.tar"
                write_tar(path, files, extra)
                with self.assertRaises(hv.Refused):
                    hv.unpack(path, self.tmp / f"into-{name}")

    def test_stage_names_media_by_head_and_writes_every_line_read(self) -> None:
        out = self.unpacked(look_files())
        plan = hv.stage(out, 43000, HEAD, self.tmp / "hv" / "media", self.tmp / "hv" / "text" / "t.txt")
        names = [item["name"] for item in plan["staged"]]
        self.assertEqual(names[:4], [f"hv-{HEAD[:12]}-before-light.png", f"hv-{HEAD[:12]}-before-dark.png",
                                     f"hv-{HEAD[:12]}-after-light.png", f"hv-{HEAD[:12]}-after-dark.png"])
        self.assertIn(f"hv-{HEAD[:12]}-video.mp4", names)
        self.assertEqual(sorted(p.name for p in (self.tmp / "hv" / "media").iterdir()), sorted(names))
        self.assertIn("line in after/dark.png", (self.tmp / "hv" / "text" / "t.txt").read_text())
        self.assertEqual(plan["withheld"], [])
        self.assertTrue((self.tmp / "hv" / "stage.json").is_file())

    def test_stage_withholds_unread_and_flagged_files(self) -> None:
        texts = {"before/light.png": {"text": ["ok"], "privacy": []},
                 "after/light.png": {"text": ["x"], "privacy": [{"kind": "host"}]},
                 "video.mp4": {"text": None, "why": "no frame reader"}}
        out = self.unpacked(look_files(texts=texts))
        plan = hv.stage(out, 43000, HEAD, self.tmp / "m", self.tmp / "t.txt")
        self.assertEqual([item["rel"] for item in plan["staged"]], ["before/light.png"])
        self.assertIn("after/light.png (private text)", plan["withheld"])
        self.assertIn("video.mp4 (its text was not read)", plan["withheld"])
        self.assertNotIn("x", (self.tmp / "t.txt").read_text().split())

    def test_stage_refuses_a_marker_for_another_head(self) -> None:
        out = self.unpacked(look_files(marker=MARKER.replace(HEAD, OTHER)))
        with self.assertRaises(hv.Refused):
            hv.stage(out, 43000, HEAD, self.tmp / "m", self.tmp / "t.txt")

    def test_stage_refuses_no_marker(self) -> None:
        out = self.unpacked(look_files(marker="<!-- something else -->"))
        with self.assertRaises(hv.Refused):
            hv.stage(out, 43000, HEAD, self.tmp / "m", self.tmp / "t.txt")

    def test_a_look_the_worker_stopped_says_why_not_just_no_marker(self) -> None:
        # Runs 43779426587 (#44015: plan ran past 300 s on cmux17) and 43758485104 (#43472: a fetch timed out) ended
        # as "the receipt has no hot-verify marker"; the reason was only in the out.tar's step.json.
        why = "plan: Command '[...hot-verify.py, plan, ...]' timed out after 300 seconds"
        out = self.unpacked({"out/step.json": json.dumps({"head": HEAD, "worker": "cmux17", "error": why,
                                                          "phases": {"plan": 300.26}}).encode(),
                             "out/log.txt": b"plan: ...\n"})
        with self.assertRaises(hv.Refused) as refused:
            hv.stage(out, 43000, HEAD, self.tmp / "m", self.tmp / "t.txt")
        self.assertIn("cmux17", str(refused.exception))
        self.assertIn("timed out after 300 seconds", str(refused.exception))
        self.assertIn("plan 300", str(refused.exception))
        self.assertIsInstance(refused.exception, hv.NoReceipt)

    def test_a_tar_with_no_receipt_exits_3_so_the_workflow_looks_again(self) -> None:
        # Run 44455465520 (#45972): the worker's GitHub read ran out of quota, its out.tar had a step.json and no
        # receipt, and `post the look` failed hard. Exit 3 is the retryable result; a bad marker stays exit 1.
        out = self.unpacked({"out/step.json": json.dumps({"head": HEAD, "worker": "mini", "error": "rate limit"}).encode()})
        argv = ["stage", str(out), "--pr", "43000", "--head", HEAD, "--stage", str(self.tmp / "m"),
                "--text", str(self.tmp / "t.txt")]
        with redirect_stderr(io.StringIO()):
            self.assertEqual(hv.main(argv), 3)
            bad = self.unpacked(look_files(marker="<!-- something else -->"))
            self.assertEqual(hv.main(["stage", str(bad)] + argv[2:]), 1)

    def test_needs_build_stages_nothing(self) -> None:
        out = self.unpacked({"out/step.json": json.dumps({"head": HEAD, "needs_build": True}).encode()})
        self.assertEqual(hv.stage(out, 43000, HEAD, self.tmp / "m", self.tmp / "t.txt"),
                         {"needs_build": True, "staged": [], "withheld": []})

    def test_an_app_look_is_staged(self) -> None:
        # The look built the head's app: its plan says needs_build, its marker names layer app, and it is published.
        files = look_files(marker=f"<!-- cmux-hot-verify sha={HEAD} app={APP} layers=app,rust source=pr -->")
        receipt = json.loads(files["out/receipt.json"])
        receipt["plan"] = {"needs_build": True, "build": {"Swift": ["A.swift"]}}
        files["out/receipt.json"] = json.dumps(receipt).encode()
        plan = hv.stage(self.unpacked(files), 43000, HEAD, self.tmp / "m", self.tmp / "t.txt")
        self.assertFalse(plan["needs_build"])
        self.assertTrue(plan["staged"])
        receipt["marker"] = MARKER
        files["out/receipt.json"] = json.dumps(receipt).encode()
        write_tar(self.tmp / "b.tar", files)
        plain = hv.unpack(self.tmp / "b.tar", self.tmp / "b")
        self.assertEqual(hv.stage(plain, 43000, HEAD, self.tmp / "m2", self.tmp / "t2.txt"),
                         {"needs_build": True, "staged": [], "withheld": []})

    def test_a_look_with_nothing_to_look_at_stages_nothing(self) -> None:
        # Runs 46054808380, 46008620288, 46007530167 (2026-11-27): a merge look whose nightly already contained the
        # merge; the worker's step.json said nothing, no receipt, and `post the look` failed on the missing marker.
        out = self.unpacked({"out/step.json": json.dumps({"head": HEAD, "needs_build": False, "nothing": True,
                                                          "error": None}).encode(),
                             "out/plan.json": json.dumps({"notes": ["the app already contains SHA"]}).encode()})
        self.assertEqual(hv.stage(out, 43000, HEAD, self.tmp / "m", self.tmp / "t.txt"),
                         {"needs_build": False, "nothing": True, "reason": "the app already contains SHA",
                          "staged": [], "withheld": []})
        argv = ["stage", str(out), "--pr", "43000", "--head", HEAD, "--stage", str(self.tmp / "m"),
                "--text", str(self.tmp / "t.txt")]
        with redirect_stdout(io.StringIO()):
            self.assertEqual(hv.main(argv), 0)

    def test_render(self) -> None:
        out = self.unpacked(look_files())
        plan = hv.stage(out, 43000, HEAD, self.tmp / "hv" / "media", self.tmp / "hv" / "t.txt")
        body = hv.render(out, 43000, HEAD, uploaded=hv.uploaded_names(plan), run_url="https://run",
                         gallery=True, event_at=1000.0, now=1400.0)
        lines = body.splitlines()
        self.assertEqual(lines[0], MARKER)
        self.assertIn("First look: app", lines[1])
        self.assertIn(f"PR head `{HEAD}`", body)
        self.assertIn(f"NEXT nightly 4512 (CMUXCommit `{APP[:12]}`)", body)
        raw = f"https://raw.githubusercontent.com/manaflow-ai/cmux/pr-media/43000/hv-{HEAD[:12]}"
        self.assertIn(f"| before | ![before light]({raw}-before-light.png) | ![before dark]({raw}-before-dark.png) |",
                      body)
        self.assertIn(f"| after | ![after light]({raw}-after-light.png) | ![after dark]({raw}-after-dark.png) |", body)
        self.assertIn(f"![video.mp4]({raw}-video.gif)", body)
        self.assertIn(f"Video: [video.mp4]({raw}-video.mp4)", body)
        self.assertIn("push to first shot 210.5 s", body)
        self.assertIn("push to this comment 400 s", body)
        self.assertIn("fleet step (engine 4.5, nightly 30, look 120)", body)
        self.assertIn("Click-through steps: 1 of 2 ok", body)
        self.assertIn("gallery advisory run still checks", body)
        self.assertIn("[run](https://run)", body)

    def test_render_without_uploads_names_no_url(self) -> None:
        out = self.unpacked(look_files())
        body = hv.render(out, 43000, HEAD, uploaded=[])
        self.assertNotIn("raw.githubusercontent.com", body)
        self.assertIn("No shots were published", body)
        self.assertNotIn("gallery", body)

    def test_render_refuses_a_marker_for_another_head(self) -> None:
        out = self.unpacked(look_files(marker=MARKER.replace(HEAD, OTHER)))
        with self.assertRaises(hv.Refused):
            hv.render(out, 43000, HEAD)

    def test_render_names_no_worker(self) -> None:
        step = {"head": HEAD, "worker": "secret-mini-7", "nightly": {"build": "1", "commit": APP}}
        out = self.unpacked(look_files(step=step))
        self.assertNotIn("secret-mini-7", hv.render(out, 1, HEAD))


class Comment(unittest.TestCase):
    def test_our_comment_is_the_newest_bot_marker_comment(self) -> None:
        listing = "\n".join(json.dumps(item) for item in (
            {"id": 1, "login": "github-actions[bot]", "head": "<!-- cmux-hot-verify sha=x"},
            {"id": 2, "login": "someone", "head": "<!-- cmux-hot-verify sha=y"},
            {"id": 3, "login": "github-actions[bot]", "head": "<!-- cmux-pr-status -->"},
            {"id": 4, "login": "github-actions[bot]", "head": "<!-- cmux-hot-verify sha=z"},
        ))
        self.assertEqual(hv.our_comment(listing + "\nnot json"), 4)
        self.assertIsNone(hv.our_comment(json.dumps({"id": 2, "login": "someone", "head": "<!-- cmux-hot-verify "})))

    def test_post_edits_in_place_and_skips_a_moved_head(self) -> None:
        calls = []

        def fake(*args, body=None):
            calls.append((args, body))
            if args[1].endswith("/pulls/7"):
                return HEAD + "\n"
            if "/comments?per_page=100&page=1" in args[1]:
                return json.dumps({"id": 99, "login": "github-actions[bot]", "head": MARKER[:40]}) + "\n"
            return "{}"

        original = hv.gh
        hv.gh = fake
        try:
            self.assertEqual(hv.post("body", 7, HEAD), "edited comment 99")
            self.assertEqual(calls[-1][0][:4], ("api", "-X", "PATCH", "repos/manaflow-ai/cmux/issues/comments/99"))
            self.assertEqual(json.loads(calls[-1][1]), {"body": "body"})
            calls.clear()
            self.assertIn("moved", hv.post("body", 7, OTHER))
            self.assertEqual(len(calls), 1)
        finally:
            hv.gh = original


    def test_a_look_at_a_merged_prs_merge_commit_posts_and_a_receipt_is_found(self) -> None:
        merge = "c" * 40

        def fake(*args, body=None):
            if args[1].endswith("/pulls/7") and args[3].startswith(".head.sha"):
                return f"{OTHER} {merge}\n"
            if args[1].endswith("/pulls/8") and args[3].startswith(".head.sha"):
                return f"{OTHER} \n"  # open: no merge commit to take
            if args[1].endswith("/pulls/7"):
                return "no marker here\n"
            if args[1].endswith("/pulls/8"):
                return f"text\n{MARKER}\n"
            if "/issues/7/comments?per_page=100&page=1" in args[1]:
                return json.dumps({"id": 5, "login": "someone", "head": "lgtm"}) + "\n"
            if "/comments?per_page=100&page=1" in args[1]:
                return ""
            return "{}"

        with mock.patch.object(hv, "gh", side_effect=fake):
            self.assertEqual(hv.post("body", 7, merge), "posted a comment")
            self.assertIn("moved", hv.post("body", 8, merge))

    def test_the_receipt_check_reads_once_and_never_waits(self) -> None:
        # hot-verify-receipt.py runs in `plan` with the workflow's token: one read per question, no sleep loop
        # (tests/test_ci_no_github_token_polling.py), and an unreadable answer is an error, never "no receipt".
        self.assertEqual(hr.MARKER_PREFIX, hv.MARKER_PREFIX)
        self.assertNotIn("while True", RECEIPT_SCRIPT.read_text())

        def answer(body, comments):
            def run(argv, **kw):
                text = comments if "comments" in argv[2] else body
                return subprocess.CompletedProcess(argv, 0, text, "")
            return run

        for body, comments, want in (("no marker\n", "false\nfalse\n", False), (f"text\n{MARKER}\n", "", True),
                                     ("", "false\ntrue\n", True), ("", "", False)):
            with self.subTest(body=body, comments=comments), \
                    mock.patch.object(hr.subprocess, "run", side_effect=answer(body, comments)) as run:
                self.assertEqual(hr.has_receipt(7), want)
            self.assertLessEqual(run.call_count, 2)
        # A full page asks for the next one, one bounded call each, never gh's paginate flag (tests/test_gh_pages.py).
        def paged(argv, **kw):
            if "comments" not in argv[2]:
                return subprocess.CompletedProcess(argv, 0, "", "")
            text = "false\n" * hr.PER_PAGE if argv[2].endswith("&page=1") else "true\n"
            return subprocess.CompletedProcess(argv, 0, text, "")
        with mock.patch.object(hr.subprocess, "run", side_effect=paged) as run:
            self.assertTrue(hr.has_receipt(7))
        self.assertEqual(run.call_count, 3)
        self.assertNotIn("--" + "paginate", [arg for call in run.call_args_list for arg in call.args[0]])
        denied = subprocess.CompletedProcess([], 1, "", "HTTP 403: API rate limit exceeded")
        with mock.patch.object(hr.subprocess, "run", return_value=denied) as run, redirect_stderr(io.StringIO()):
            self.assertEqual(hr.main(["--pr", "7"]), 1)
        self.assertEqual(run.call_count, 1)

    def test_a_call_out_of_quota_waits_for_the_reset_then_retries(self) -> None:
        # Run 43790108433 (cmux#44086, 2026-11-16): the look passed, then "post the look" died on
        # "API rate limit exceeded for installation" and the finished look was never posted.
        limited = subprocess.CompletedProcess([], 1, "", "gh: API rate limit exceeded for installation. If you ...")
        answers, calls, slept = [], [], []

        def run(argv, **kw):
            calls.append(argv)
            if argv[1:3] == ["api", "rate_limit"]:
                return subprocess.CompletedProcess(argv, 0, "0 1000300\n", "")
            return answers.pop(0)

        with mock.patch.object(hv.subprocess, "run", side_effect=run), \
                mock.patch.object(hv.time, "time", return_value=1000000.0), \
                mock.patch.object(hv.time, "sleep", side_effect=slept.append), redirect_stderr(io.StringIO()):
            answers[:] = [limited, subprocess.CompletedProcess([], 0, "ok\n", "")]
            self.assertEqual(hv.gh("api", "repos/manaflow-ai/cmux/pulls/7"), "ok\n")
            self.assertEqual(slept, [305.0])  # the core reset, 300 s on, plus 5
            self.assertEqual([c[1:3] for c in calls], [["api", "repos/manaflow-ai/cmux/pulls/7"],
                                                       ["api", "rate_limit"],
                                                       ["api", "repos/manaflow-ai/cmux/pulls/7"]])
            # Past QUOTA_WAIT_SECONDS in all, it stops waiting and says why.
            slept.clear()
            answers[:] = [limited] * 20
            with self.assertRaises(hv.Refused) as refused:
                hv.gh("api", "repos/manaflow-ai/cmux/pulls/7")
            self.assertLessEqual(sum(slept), hv.QUOTA_WAIT_SECONDS)
            self.assertIn("rate limit", str(refused.exception))
            # Any other failure is not retried.
            slept.clear()
            answers[:] = [subprocess.CompletedProcess([], 1, "", "HTTP 404: Not Found")]
            with self.assertRaises(hv.Refused):
                hv.gh("api", "repos/manaflow-ai/cmux/pulls/7")
            self.assertEqual(slept, [])

    def test_a_read_timeout_retries_with_an_alternate_token(self) -> None:
        calls = []
        timed_out = subprocess.TimeoutExpired(["gh", "api"], hv.GH_TIMEOUT_SECONDS)

        def run(argv, **kw):
            calls.append((argv, kw))
            if len(calls) == 1:
                raise timed_out
            return subprocess.CompletedProcess(argv, 0, "ok\n", "")

        with mock.patch.dict(hv.os.environ, {"GH_TOKEN": "primary", "GH_TOKEN_SPARE": "spare",
                                              "GH_TOKEN_SPARES": "spare third"}, clear=True), \
                mock.patch.object(hv.subprocess, "run", side_effect=run), redirect_stderr(io.StringIO()):
            self.assertEqual(hv.gh("api", "repos/manaflow-ai/cmux/pulls/7"), "ok\n")
        self.assertEqual(len(calls), 2)
        self.assertEqual(calls[0][1]["env"], None)
        self.assertEqual(calls[1][1]["env"]["GH_TOKEN"], "spare")

    def test_a_write_timeout_is_refused_without_a_retry(self) -> None:
        timed_out = subprocess.TimeoutExpired(["gh", "api"], hv.GH_TIMEOUT_SECONDS)
        with mock.patch.object(hv.subprocess, "run", side_effect=timed_out) as run:
            with self.assertRaisesRegex(hv.Refused, "timed out"):
                hv.gh("api", "-X", "POST", "repos/manaflow-ai/cmux/issues/7/comments", body="{}")
        self.assertEqual(run.call_count, 1)


class Workflow(unittest.TestCase):
    """The workflow's wiring that the script relies on (text checks; the house guards check the rest)."""

    def test_the_workflow_runs_this_script_from_the_protected_branch(self) -> None:
        text = WORKFLOW.read_text()
        self.assertIn("tool=scripts/cmux-next/hot-verify-ci.py", text)
        for command in ("verdict", "nightly-commit", "result", "unpack", "stage", "render", "post"):
            with self.subTest(command=command):
                self.assertTrue(f"hot-verify-ci.py {command} " in text or f'"$tool" {command} ' in text)
        self.assertIn("environment: pr-media", text)
        self.assertIn("uses: ./.github/actions/pr-media-publish", text)
        self.assertIn("gh workflow run cmux-next-web-bundle-publish.yml", text)
        self.assertNotIn("secrets: inherit", text)
        # No job waits for a fleet Mac: the gateway runner and the fleet client are gone from this workflow.
        self.assertNotIn("CI_EVAL_STEP_GATEWAY", text)
        self.assertNotIn("cmux-ci", text.replace("cmux-ci-", ""))

    def test_pr_reads_wait_through_github_api_rate_limits(self) -> None:
        for job in ("target", "publish"):
            with self.subTest(job=job):
                block = "\n".join(self.job_block(job))
                self.assertIn("scripts/ci/gh_budget_wait.sh", block)
                self.assertIn("bash scripts/ci/gh_budget_wait.sh --install", block)

    def test_the_plan_fetch_finds_the_merge_base_after_a_depth_one_checkout(self) -> None:
        # The fleet's looks on #43862, #43807, #43816 and #43779 failed at `git merge-base` (2026-11-15): the
        # checkout's depth-1 fetch left the base tip shallow and the step's --shallow-since fetch did not deepen it.
        lines = WORKFLOW.read_text().splitlines()
        start = next(i for i, line in enumerate(lines) if line.strip().startswith('since="$(date'))
        end = next(i for i in range(start, len(lines)) if 'git rev-parse refs/remotes/pr/head' in lines[i])
        fetch = textwrap.dedent("\n".join(lines[start:end]))
        with tempfile.TemporaryDirectory(prefix="hot-verify-fetch-") as scratch:
            root = Path(scratch)
            env = git_fixture_env.fixture_env({
                **os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t",
                "GIT_COMMITTER_EMAIL": "t@t", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"})

            def git(cwd: Path, *args: str) -> str:
                return subprocess.run(["git", "-C", str(cwd), *args], check=True, capture_output=True, text=True,
                                      env=env).stdout.strip()

            src = root / "src"
            src.mkdir()
            git_fixture_env.init_repo(src, "-b", "feat-cmux-next", env=env)
            git(src, "config", "uploadpack.allowFilter", "true")
            for n in range(5):
                (src / "f").write_text(f"{n}\n")
                git(src, "add", "f")
                git(src, "commit", "-q", "-m", f"base {n}")
            fork = git(src, "rev-parse", "HEAD~2")
            git(src, "checkout", "-q", "-b", "pr", fork)
            (src / "g").write_text("change\n")
            git(src, "add", "g")
            git(src, "commit", "-q", "-m", "change")
            head = git(src, "rev-parse", "HEAD")
            git(src, "update-ref", "refs/pull/7/head", head)
            git(src, "checkout", "-q", "feat-cmux-next")
            clone = root / "clone"
            clone.mkdir()
            git_fixture_env.init_repo(clone, env=env)
            git(clone, "remote", "add", "origin", src.as_uri())
            # As actions/checkout: the base branch alone, at depth 1.
            git(clone, "fetch", "-q", "--no-tags", "--depth=1", "origin",
                "+refs/heads/feat-cmux-next:refs/remotes/origin/feat-cmux-next")
            subprocess.run(["bash", "-euo", "pipefail", "-c", fetch], cwd=clone, check=True, capture_output=True,
                           env={**env, "BASE_REF": "feat-cmux-next", "PR": "7"})
            self.assertEqual(git(clone, "merge-base", "refs/remotes/pr/head", "refs/remotes/origin/feat-cmux-next"),
                             fork)

    def job_block(self, job: str) -> list[str]:
        """The workflow's lines of one top-level job, its key line through the line before the next job."""
        lines = WORKFLOW.read_text().splitlines()
        start = lines.index(f"  {job}:")
        end = next((i for i in range(start + 1, len(lines)) if lines[i].startswith("  ") and not
                    lines[i].startswith("   ") and lines[i].rstrip().endswith(":") and not lines[i].lstrip().startswith("#")),
                   len(lines))
        return lines[start:end]

    def run_block(self, job: str, gh_out: str, env: dict, step: str) -> tuple[subprocess.CompletedProcess, Path, list[str]]:
        """Run JOB's STEP `run: |` script, from the checkout's root, with a gh on PATH that prints GH_OUT and logs its
        argv; returns the process, the GITHUB_OUTPUT file and the gh calls.

        STEP is named, never "the job's first script": each job's first one is now "Drop a reused workspace's
        repository" (`rm -rf "$GITHUB_WORKSPACE/.git"`), and run with the job's environment it deleted the checks
        job's own .git mid-run (cmux-next.yml checks, runs 45871176600 and 45884200942: ~20 checks then failed with
        "not a git repository"). GITHUB_WORKSPACE points at the scratch directory too, so no step body reaches it."""
        block = self.job_block(job)
        first = next(i for i, line in enumerate(block) if line.strip() == f"- name: {step}")
        at = next(i for i in range(first, len(block)) if block[i].strip() == "run: |")
        indent = len(block[at]) - len(block[at].lstrip()) + 2
        end = next((j for j in range(at + 1, len(block)) if block[j].strip()
                    and len(block[j]) - len(block[j].lstrip()) < indent), len(block))
        script = textwrap.dedent("\n".join(block[at + 1:end]))
        scratch = Path(self.enterContext(tempfile.TemporaryDirectory(prefix="hot-verify-job-")))
        (scratch / "bin").mkdir()
        fake = scratch / "bin" / "gh"
        fake.write_text('#!/bin/bash\nprintf "%s\\0" "$@" >> "$GH_CALLS"; printf "%s\\n" "$GH_OUT"\n')
        fake.chmod(0o755)
        out, summary, calls = scratch / "out", scratch / "summary", scratch / "calls"
        done = subprocess.run(["bash", "-c", script], cwd=ROOT, capture_output=True, text=True,
                              env={**os.environ, "PATH": f"{scratch / 'bin'}:{os.environ['PATH']}", "GH_OUT": gh_out,
                                   "GH_CALLS": str(calls), "GITHUB_OUTPUT": str(out), "GITHUB_STEP_SUMMARY": str(summary),
                                   "GITHUB_REPOSITORY": "manaflow-ai/cmux", "GITHUB_WORKSPACE": str(scratch), **env})
        argv = calls.read_text().split("\0")[:-1] if calls.exists() else []
        return done, out, argv

    def test_a_merged_pull_request_is_looked_at_at_its_merged_head(self) -> None:
        # A look queued behind the busy gateway label (12 looks waited up to 30 min, 2026-11-16 09:10Z) starts after
        # its PR merged, and `look again` always runs after the look it repeats: a check that took only open PRs
        # dropped both.
        env = {"PR": "7", "HEAD_SHA": HEAD, "LAYERS": "rust"}
        cases = {
            "merged": (f"manaflow-ai/cmux\t{HEAD}\tfeat-cmux-next\tclosed\tfalse\t2026-11-16T09:00:00Z", "true"),
            "open": (f"manaflow-ai/cmux\t{HEAD}\tfeat-cmux-next\topen\tfalse\t-", "true"),
            "closed unmerged": (f"manaflow-ai/cmux\t{HEAD}\tfeat-cmux-next\tclosed\tfalse\t-", "false"),
            "draft": (f"manaflow-ai/cmux\t{HEAD}\tfeat-cmux-next\topen\ttrue\t-", "false"),
            "merged, moved": (f"manaflow-ai/cmux\t{OTHER}\tfeat-cmux-next\tclosed\tfalse\t2026-11-16T09:00:00Z", "false"),
            "fork": (f"someone/cmux\t{HEAD}\tfeat-cmux-next\tclosed\tfalse\t2026-11-16T09:00:00Z", "false"),
        }
        for name, (row, ok) in cases.items():
            with self.subTest(name):
                done, out, _ = self.run_block("target", row, env, READ_PR)
                self.assertEqual(done.returncode, 0, done.stderr)
                self.assertIn(f"ok={ok}\n", out.read_text())

    def test_a_look_result_waits_for_one_runner_not_two(self) -> None:
        # 2026-11-19: every result run (the controller's look_result dispatch) queued for a shared 4 vCPU Linux runner
        # at `target`, then queued again for `publish` or `again`; 15 of 16 PRs without a receipt lost their look to
        # runner queues (goals/hot-verify-share.md). The result run is one job with no needs.
        lines = WORKFLOW.read_text().split("\njobs:\n", 1)[1].splitlines()
        jobs = [line.strip().rstrip(":") for line in lines if line.startswith("  ") and not line.startswith("   ")
                and line.rstrip().endswith(":") and not line.lstrip().startswith("#")]
        runs = [job for job in jobs if "inputs.look_result != ''" in
                next(line for line in self.job_block(job) if line.strip().startswith("if:"))]
        self.assertEqual(runs, ["publish"])
        block = self.job_block("publish")
        self.assertFalse(any(line.strip().startswith("needs:") for line in block), "\n".join(block))
        target_if = next(line for line in self.job_block("target") if line.strip().startswith("if:"))
        self.assertIn("inputs.look_result == ''", target_if)

    def test_a_look_lost_on_the_fleet_is_started_once_more_and_only_once(self) -> None:
        # 2026-11-16: run 43788086518's step failed on three lent Macs' disk declines, run 43788591989's worker
        # stopped renewing its lease, and a reserved fleet Mac's gateway runner refused 8 looks (runs
        # 43833883489, 43834069668, ...). Each lost its look for good: nothing started one again.
        block = self.job_block("publish")
        self.assertIn("inputs.look_result != ''", "\n".join(block))
        step = block.index("      - name: Dispatch one more look")
        self.assertEqual(block[step + 1].strip(), "if: ${{ steps.check.outputs.ok == 'true' && "
                                                  "(steps.result.outputs.tar == 'false' || steps.stage.outputs.again == 'true') && "
                                                  "inputs.attempt != '1' }}")
        self.assertIn("attempt:", WORKFLOW.read_text().split("jobs:", 1)[0])
        again = "Dispatch one more look"
        done, _, argv = self.run_block("publish", "", {"PR": "7", "HEAD_SHA": HEAD, "LAYERS": "web,rust",
                                                        "EVENT_AT": "1794800000"}, again)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(argv[:2], ["workflow", "run"])
        self.assertIn("cmux-next-hot-verify.yml", argv)
        for field in ("pr=7", f"head={HEAD}", "layers=web,rust", "event_at=1794800000", "attempt=1"):
            self.assertIn(field, argv)
        done, _, argv = self.run_block("publish", "", {"PR": "7", "HEAD_SHA": HEAD, "LAYERS": "rust", "EVENT_AT": "",
                                                        "KIND": "merge"}, again)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("kind=merge", argv)

    def test_a_tar_with_no_receipt_marks_the_publish_job_to_look_again_once(self) -> None:
        # Run 44455465520 (#45972): stage exits 3 for an out.tar with no receipt; the stage step turns that into
        # again=true (the dispatch step above runs on it) on the first look, and fails on the retry (attempt 1).
        block = self.job_block("publish")
        stage = block.index("      - name: Unpack and stage")
        dispatch = block.index("      - name: Dispatch one more look")
        self.assertLess(stage, dispatch, "the dispatch step reads steps.stage.outputs.again, so it runs after stage")
        script = "\n".join(block[stage:dispatch])
        self.assertIn('if [[ "$rc" == 3 && "${ATTEMPT:-}" != 1 ]]; then', script)
        self.assertIn('echo "again=true" >> "$GITHUB_OUTPUT"', script)
        self.assertIn('[[ "$rc" == 0 ]] || exit "$rc"', script)
        self.assertIn("ATTEMPT: ${{ inputs.attempt }}", script)

    def test_a_merged_pr_with_no_receipt_is_looked_at_at_its_merge_commit(self) -> None:
        # A look at the PR head that needs the change's own Rust (8 of 90 looks, 2026-11-15/16) cannot run on the
        # nightly copy; at the merge commit the tree is published and the engine plans from its first parent. The
        # closed event plans and dispatches that look once, and only when the PR has no receipt yet.
        text = WORKFLOW.read_text()
        self.assertIn("types: [opened, synchronize, reopened, ready_for_review, closed", text)
        self.assertIn("(github.event.action != 'closed' || github.event.pull_request.merged)", "\n".join(self.job_block("plan")))
        self.assertIn("hot-verify-receipt.py --pr", "\n".join(self.job_block("plan")))
        # The plan job's last step dispatches the look (the hand-off was its own job until 2026-11-23).
        self.assertNotIn("  hand-off:", WORKFLOW.read_text().splitlines())
        plan = self.job_block("plan")
        dispatch = "\n".join(plan[next(i for i, line in enumerate(plan) if line.strip() == "- name: Dispatch the look"):])
        self.assertIn("if: ${{ steps.plan.outputs.eligible == 'true' }}", dispatch)
        self.assertIn("github.event.action == 'closed' && github.event.pull_request.merge_commit_sha", dispatch)
        self.assertIn('-f kind="$KIND"', dispatch)
        # its own concurrency group: it never cancels a head look still queued when the PR merged
        self.assertIn("inputs.kind == 'merge') && '-merge'", text)
        merge = "c" * 40
        row = f"manaflow-ai/cmux\t{OTHER}\tfeat-cmux-next\tclosed\tfalse\t2026-11-16T10:00:00Z\t{merge}"
        done, out, _ = self.run_block("target", row, {"PR": "7", "HEAD_SHA": merge, "LAYERS": "web,rust"}, READ_PR)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("ok=true\n", out.read_text())
        self.assertIn(f"pr_head={OTHER}\n", out.read_text())  # the web layer waits for the PR's own head
        unmerged = f"manaflow-ai/cmux\t{OTHER}\tfeat-cmux-next\topen\tfalse\t-\t{merge}"
        done, out, _ = self.run_block("target", unmerged, {"PR": "7", "HEAD_SHA": merge, "LAYERS": "rust"}, READ_PR)
        self.assertIn("ok=false\n", out.read_text())

    def test_a_receipt_check_that_cannot_read_github_still_looks(self) -> None:
        # Run 44033383427 (cmux#45098, 2026-11-17): the receipt read hit "API rate limit exceeded for installation",
        # receipt=unknown counted as a receipt, and the merged daemon PR got no look. Only receipt=true skips.
        # From the Plan step on, not the job's first script: that is the workspace drop (see run_block).
        block = self.job_block("plan")
        plan = block.index("      - name: Plan")
        start = next(i for i in range(plan, len(block)) if block[i].strip() == "run: |") + 1
        script = textwrap.dedent("\n".join(block[start:]))
        unreadable = "import sys\nprint('hot-verify-receipt: API rate limit exceeded', file=sys.stderr)\nsys.exit(1)\n"
        for answer, skips in ((unreadable, False), ("print('receipt=false')\n", False), ("print('receipt=true')\n", True)):
            with self.subTest(answer=answer):
                scratch = Path(self.enterContext(tempfile.TemporaryDirectory(prefix="hot-verify-plan-")))
                (scratch / "scripts/cmux-next").mkdir(parents=True)
                (scratch / "scripts/cmux-next/hot-verify-receipt.py").write_text(answer)
                (scratch / "bin").mkdir()
                # The git fetch after the receipt check stops the script: reaching it means the plan went on.
                (scratch / "bin/git").write_text("#!/bin/bash\necho reached-git >> \"$GITHUB_STEP_SUMMARY\"; exit 3\n")
                (scratch / "bin/git").chmod(0o755)
                out, summary = scratch / "out", scratch / "summary"
                done = subprocess.run(["bash", "-c", script], cwd=scratch, capture_output=True, text=True,
                                      env={**os.environ, "PATH": f"{scratch / 'bin'}:{os.environ['PATH']}",
                                           "GITHUB_OUTPUT": str(out), "GITHUB_STEP_SUMMARY": str(summary),
                                           "GITHUB_REPOSITORY": "manaflow-ai/cmux", "GITHUB_WORKSPACE": str(scratch),
                                           "PR": "7", "BASE_REF": "feat-cmux-next",
                                           "HEAD_SHA": "c" * 40, "MERGED": "true"})
                said = summary.read_text() if summary.exists() else ""
                if skips:
                    self.assertEqual(done.returncode, 0, done.stderr)
                    self.assertIn("eligible=false", out.read_text())
                    self.assertNotIn("reached-git", said)
                else:
                    self.assertIn("reached-git", said, (done.stderr, said))
                    self.assertFalse(out.exists() and "eligible=false" in out.read_text())

    def test_the_rust_layer_names_only_a_tree_something_will_publish(self) -> None:
        # tree= makes the controller wait up to 50 min for the tree's completion.json. A pull request head's push
        # builds no tree (ci-min-per-pr-30) and the dispatch below is off (#53824), so a named unpublished tree was a
        # 50 min wait for nothing before the fleet step built the head's daemon itself (builds_head_daemon).
        # Cases: curl exit, CMUX_TUI_BRANCH_ON_REQUEST, CMUX_TUI_LOOK_DISPATCH, the head's Cmux-Daemon-Tests value.
        real_git = shutil.which("git")
        cases = ((0, "1", "", "", True), (22, "1", "", "", False), (22, "0", "", "", True),
                 (22, "1", "", " Run\n", True), (22, "1", "", "skip\n", False), (22, "1", "1", "", True))
        for answer, on_request, dispatch, trailer, named in cases:
            with self.subTest(curl_exit=answer, on_request=on_request, dispatch=dispatch, trailer=trailer):
                fake = Path(self.enterContext(tempfile.TemporaryDirectory(prefix="hot-verify-tree-")))
                (fake / "curl").write_text(f"#!/bin/bash\nprintf '%s\\n' \"$*\" >> {fake}/asked\nexit {answer}\n")
                (fake / "curl").chmod(0o755)
                # git log answers the trailer; the tree key's own git reads go to the real git.
                (fake / "git").write_text(f'#!/bin/bash\nif [[ "$1" == log ]]; then printf "{trailer}"; exit 0; fi\n'
                                          f'exec {real_git} "$@"\n')
                (fake / "git").chmod(0o755)
                done, out, calls = self.run_block("rust", "", {"HEAD_SHA": HEAD, "GITHUB_RUN_ID": "1",
                                                               "BRANCH_ON_REQUEST": on_request, "LOOK_DISPATCH": dispatch,
                                                               "PATH": f"{fake}:{os.environ['PATH']}"},
                                                  step="The head's cmux-tui tree key")
                self.assertEqual(done.returncode, 0, done.stderr)
                self.assertEqual(calls, [])
                self.assertRegex((fake / "asked").read_text(),
                                 r"https://files\.cmux\.com/cmux-tui/tree/[0-9a-f]{40,64}/completion\.json")
                written = out.read_text()
                self.assertRegex(written, r"(?m)^key=[0-9a-f]{40,64}$")  # the dispatch step still reads it
                self.assertEqual(bool(re.search(r"(?m)^tree=[0-9a-f]{40,64}$", written)), named, written)
        block = "\n".join(self.job_block("rust"))
        self.assertIn("key: ${{ steps.key.outputs.tree }}", block)
        self.assertIn("BRANCH_ON_REQUEST: ${{ vars.CMUX_TUI_BRANCH_ON_REQUEST || '1' }}", block)

    def test_the_request_job_name_is_the_controllers_request(self) -> None:
        # The build fleet controller (cmuxterm-hq build-fleet/cmd/controller/hot_verify_look.go hotLookJobName) reads
        # the request from this job's name; nothing else carries it. Its fields come only from the target job, which
        # checks each one's shape.
        block = "\n".join(self.job_block("request"))
        name = next(line.split("name: ", 1)[1] for line in self.job_block("request") if line.strip().startswith("name: hot verify request"))
        self.assertEqual(name, "hot verify request pr=${{ needs.target.outputs.pr }} head=${{ needs.target.outputs.head }} "
                               "attempt=${{ needs.target.outputs.attempt }} kind=${{ needs.target.outputs.kind }} "
                               "event=${{ needs.target.outputs.event_at }} layers=${{ needs.target.outputs.layers }}"
                               "${{ needs.rust.outputs.key != '' && format(' tree={0}', needs.rust.outputs.key) || '' }}")
        self.assertIn("timeout-minutes: 2", block)
        self.assertIn("permissions: {}", block)
        # No runner waits for a build here: a retry's pause is short and bounded (at most 60 s), never a poll.
        for job in ("rust", "web"):
            pauses = re.findall(r"\bsleep\s+(\S+)", "\n".join(self.job_block(job)))
            self.assertTrue(all(p in ('"$pause"',) or (p.isdigit() and int(p) <= 60) for p in pauses), (job, pauses))
        self.assertNotIn("sleep", "\n".join(self.job_block("rust")))
        row = f"manaflow-ai/cmux\t{HEAD}\tfeat-cmux-next\topen\tfalse\t-\t-"
        for env, want in (({"KIND": "", "ATTEMPT": "", "EVENT_AT": "1794800000"}, ("kind=head", "attempt=0", "event_at=1794800000")),
                          ({"KIND": "merge", "ATTEMPT": "1", "EVENT_AT": "x y=z"}, ("kind=merge", "attempt=1", "event_at=\n"))):
            done, out, _ = self.run_block("target", row, {"PR": "7", "HEAD_SHA": HEAD, "LAYERS": "web,rust", **env}, READ_PR)
            self.assertEqual(done.returncode, 0, done.stderr)
            for line in want:
                self.assertIn(line, out.read_text())
        done, _, _ = self.run_block("target", row, {"PR": "7", "HEAD_SHA": HEAD, "LAYERS": "web", "KIND": "head layers=web"}, READ_PR)
        self.assertNotEqual(done.returncode, 0)

    def test_the_look_result_names_its_pr_and_head_and_its_out_tar(self) -> None:
        url = "https://store.example/artifacts/abc?X-Amz-Signature=1"
        done = hv.look_result(json.dumps({"pr": 7, "head": HEAD, "step_id": "0123456789abcdef01234567", "state": "done",
                                          "exit_code": 0, "queued_s": 4620, "artifact_url": url}), 7, HEAD)
        self.assertEqual(done["url"], url)
        self.assertIn("after 4620 s in the queue", done["reason"])
        lost = hv.look_result(json.dumps({"pr": 7, "head": HEAD, "state": "cancelled", "error": "no fleet Mac took the look within 3h0m0s"}), 7, HEAD)
        self.assertEqual(lost["url"], "")
        for bad in ({"pr": 8, "head": HEAD, "state": "done"}, {"pr": 7, "head": OTHER, "state": "done"},
                    {"pr": 7, "head": HEAD, "state": "maybe"}, {"pr": 7, "head": HEAD, "state": "done", "artifact_url": "http://x"}):
            with self.subTest(bad=bad), self.assertRaises(hv.Refused):
                hv.look_result(json.dumps(bad), 7, HEAD)

    def test_the_plan_plans_against_the_nightlys_commit(self) -> None:
        # 128 steps on 2026-11-17 queued for a Mac and ended "needs a build" at the worker, which plans against the
        # nightly; the PR half planned against the merge base. The feed item cmux's own pick() takes names it.
        def item(build: int, commit: str, channel: str = "") -> str:
            ch = f"<sparkle:channel>{channel}</sparkle:channel>" if channel else ""
            return (f"<item><sparkle:version>{build}</sparkle:version>{ch}<cmux:sourceCommit>{commit}</cmux:sourceCommit>"
                    f'<enclosure url="https://files-next.cmux.com/nightly-next/cmux-nightly-next-macos-arm64-{build}.dmg" '
                    'length="1" sparkle:edSignature="x"/></item>')
        feed = "<rss><channel>" + item(10, APP) + item(12, OTHER, "cmux-next-dev") + item(11, HEAD) + "</channel></rss>"
        self.assertEqual(hv.nightly_commit(feed), HEAD)
        self.assertEqual(hv.nightly_commit("<rss/>"), "")
        # The writer (publish-nightly-next-r2.py add_source) binds cmux: inline on the tag itself.
        inline = feed.replace("<cmux:sourceCommit>", '<cmux:sourceCommit xmlns:cmux="https://cmux.com/xml-namespaces/cmux">')
        self.assertEqual(hv.nightly_commit(inline), HEAD)
        plan = "\n".join(self.job_block("plan"))
        self.assertIn('"$tool" nightly-commit', plan)
        self.assertIn('${base[@]+"${base[@]}"}', plan)

    def test_every_checkout_clones_once_more_after_a_stalled_transport(self) -> None:
        # 2026-11-25: 10 of 13 sampled hot verify reds were GitHub's git transport stalling ("Operation too slow",
        # "could not fetch ... from promisor remote") in a checkout or the plan's fetch (runs 45701596650,
        # 45702976944, 45711119163), each green on a rerun.
        for job in ("plan", "target", "rust", "publish"):
            with self.subTest(job=job):
                block = "\n".join(self.job_block(job))
                first = block.index("uses: actions/checkout@")
                self.assertIn("id: checkout\n        continue-on-error: true", block[:first])
                self.assertEqual(block.count("uses: actions/checkout@"), 2)
                again = block.index("(again)\n        if: ${{ steps.checkout.outcome == 'failure' }}")
                drop = block.index("- name: Drop the stalled clone")
                self.assertLess(first, drop)
                self.assertLess(drop, again)
                # Both checkouts take the same inputs.
                withs = [w.split("\n      - ", 1)[0].split("\n      # ", 1)[0]
                         .replace("sparse-checkout: &publisher-sparse", "sparse-checkout:")
                         for w in block.split("uses: actions/checkout@")[1:]]
                self.assertEqual(withs[0], withs[1])

    def test_the_plan_fetch_tries_a_stalled_transport_again(self) -> None:
        lines = WORKFLOW.read_text().splitlines()
        start = next(i for i, line in enumerate(lines) if line.strip() == "fetch_retry() {")
        body = textwrap.dedent("\n".join(lines[start:start + 8]))
        scratch = Path(self.enterContext(tempfile.TemporaryDirectory(prefix="hot-verify-fetch-retry-")))
        (scratch / "git").write_text(f'#!/bin/bash\nn=$(cat {scratch}/n 2>/dev/null || echo 0); echo $((n+1)) > {scratch}/n\n'
                                     '[[ $n -ge 2 ]]\n')
        (scratch / "git").chmod(0o755)
        (scratch / "sleep").write_text("#!/bin/bash\n")
        (scratch / "sleep").chmod(0o755)
        env = {**os.environ, "PATH": f"{scratch}:{os.environ['PATH']}"}
        done = subprocess.run(["bash", "-c", body + "\nfetch_retry 5 origin x"], env=env, capture_output=True, text=True)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual((scratch / "n").read_text().strip(), "3")
        (scratch / "n").write_text("-9")
        done = subprocess.run(["bash", "-c", body + "\nfetch_retry 5 origin x"], env=env, capture_output=True, text=True)
        self.assertNotEqual(done.returncode, 0)
        self.assertEqual((scratch / "n").read_text().strip(), "-6")

    def fake_gh_run(self, job: str, step: str, gh_body: str, env: dict) -> tuple[subprocess.CompletedProcess, str, str]:
        block = self.job_block(job)
        first = next(i for i, line in enumerate(block) if line.strip() == f"- name: {step}")
        at = next(i for i in range(first, len(block)) if block[i].strip() == "run: |")
        indent = len(block[at]) - len(block[at].lstrip()) + 2
        end = next((j for j in range(at + 1, len(block)) if block[j].strip()
                    and len(block[j]) - len(block[j].lstrip()) < indent), len(block))
        script = textwrap.dedent("\n".join(block[at + 1:end]))
        scratch = Path(self.enterContext(tempfile.TemporaryDirectory(prefix="hot-verify-gh-")))
        (scratch / "gh").write_text(f"#!/bin/bash\necho \"$GH_TOKEN $*\" >> {scratch}/calls\n" + gh_body)
        (scratch / "gh").chmod(0o755)
        (scratch / "sleep").write_text("#!/bin/bash\n")
        (scratch / "sleep").chmod(0o755)
        done = subprocess.run(["bash", "-c", script], capture_output=True, text=True,
                              env={**os.environ, "PATH": f"{scratch}:{os.environ['PATH']}", "RUNNER_TEMP": str(scratch),
                                   "GITHUB_STEP_SUMMARY": str(scratch / "summary"), "GITHUB_REPOSITORY": "manaflow-ai/cmux",
                                   "GITHUB_WORKSPACE": str(scratch), **env})
        calls = (scratch / "calls").read_text() if (scratch / "calls").exists() else ""
        summary = (scratch / "summary").read_text() if (scratch / "summary").exists() else ""
        return done, calls, summary

    def test_the_web_layer_warns_on_a_spent_hour_and_stays_red_on_a_real_refusal(self) -> None:
        # 2026-11-25: 4 of 5 sampled web layer reds were github.token's spent hour (run 45711732758), one an HTTP 500
        # (run 45710344100). gh here is gh_budget_wait.sh (spare pools, bounded wait, 5xx dispatch retry); what
        # still comes back rate-limited is every pool's spent hour: a warning, not red, since nothing waits for
        # this bundle. A real refusal is still red.
        step = "Start the web layer"
        env = {"GH_TOKEN": "t0", "PR": "7"}
        done, calls, summary = self.fake_gh_run("web", step, "exit 0\n", env)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("publishing", summary)
        limit = 'echo "HTTP 403: API rate limit exceeded for installation." >&2; exit 1\n'
        done, calls, summary = self.fake_gh_run("web", step, limit, env)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(len(calls.splitlines()), 1)
        self.assertIn("::warning", done.stdout)
        self.assertIn("not published", summary)
        done, calls, _ = self.fake_gh_run("web", step, 'echo "HTTP 404: Not Found" >&2; exit 1\n', env)
        self.assertNotEqual(done.returncode, 0)
        self.assertIn("::error", done.stdout)

    def test_one_more_look_tries_a_5xx_again(self) -> None:
        # Runs 45709542537 and 45710724221: the dispatch API answered HTTP 500 once and the step ended red.
        flaky = ('n=$(wc -l < "$RUNNER_TEMP/calls"); [[ $n -ge 2 ]] && exit 0\n'
                 'echo "could not create workflow dispatch event: HTTP 500" >&2; exit 1\n')
        env = {"PR": "7", "HEAD_SHA": HEAD, "LAYERS": "rust", "EVENT_AT": "1", "KIND": "head"}
        done, calls, _ = self.fake_gh_run("publish", "Dispatch one more look", flaky, env)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(len(calls.splitlines()), 2)
        done, calls, _ = self.fake_gh_run("publish", "Dispatch one more look", 'echo "HTTP 422: no" >&2; exit 1\n', env)
        self.assertNotEqual(done.returncode, 0)
        self.assertEqual(len(calls.splitlines()), 3)

    def test_the_plan_dispatch_judges_ghs_answer_not_the_wrappers_notice(self) -> None:
        # Run 45707112427: the wrapper's ::notice ("refused for the API rate limit ... on GH_TOKEN_SPARE now") made
        # the step stop retrying a later 5xx on the spare, and hid the spare's answer.
        flaky = ('n=$(wc -l < "$RUNNER_TEMP/calls")\n'
                 'echo "::notice title=GitHub API budget::gh workflow run was refused for the API rate limit" >&2\n'
                 '[[ $n -ge 2 ]] && exit 0\necho "HTTP 500: Failed to run workflow dispatch" >&2; exit 1\n')
        env = {"PR": "7", "HEAD_SHA": HEAD, "LAYERS": "rust", "EVENT_AT": "2026-11-25T00:00:00Z", "KIND": "head"}
        done, calls, _ = self.fake_gh_run("plan", "Dispatch the look", flaky, env)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertEqual(len(calls.splitlines()), 2)
        # gh's own rate-limit answer still stops at once: the wrapper already waited (120 s at most) on every pool.
        # The look is advisory, so a spent hour skips it green instead of a red (2026-11-24 runs slept ~24 min here).
        done, calls, summary = self.fake_gh_run("plan", "Dispatch the look", 'echo "HTTP 403: API rate limit exceeded" >&2; exit 1\n', env)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertEqual(len(calls.splitlines()), 1)
        self.assertIn("no look", summary)
        # Any other refusal is still red after its retries.
        done, calls, _ = self.fake_gh_run("plan", "Dispatch the look", 'echo "HTTP 422: no" >&2; exit 1\n', env)
        self.assertNotEqual(done.returncode, 0)

    def test_the_rust_layer_reads_the_pr_only_to_send_a_dispatch(self) -> None:
        # 5 of 6 sampled rust layer reds on 2026-11-25 were this read out of quota with the dispatch switched off.
        step = "Ask for the head's tree when it is not published"
        block = "\n".join(self.job_block("rust"))
        body = block.split(f"- name: {step}", 1)[1]
        self.assertLess(body.index('if [[ "${LOOK_DISPATCH:-}" != 1 ]]; then'), body.index("gh api "))

    def test_the_web_publisher_takes_a_pr_dispatch(self) -> None:
        text = WEB_PUBLISH.read_text()
        self.assertIn("workflow_dispatch:", text)


PR_SH = ROOT / "scripts" / "cmux-next" / "hot-verify-pr.sh"
BUDGET_WAIT = ROOT / "scripts" / "ci" / "gh_budget_wait.sh"
HEAD = "a" * 40


class PullRequestRead(unittest.TestCase):
    """hot-verify-pr.sh reads the PR without sleeping: REST, then GraphQL's own hour, then a capped wait."""

    def run_read(self, fake_body: str) -> tuple[subprocess.CompletedProcess, dict[str, str], str]:
        with tempfile.TemporaryDirectory() as tmp:
            t = Path(tmp)
            real = t / "real"
            real.mkdir()
            calls = t / "calls.log"
            fake = real / "gh"
            fake.write_text("#!/usr/bin/env bash\n" f"echo \"$*\" >> {calls}\n" + textwrap.dedent(fake_body))
            fake.chmod(0o755)
            wrap = t / "wrap"
            wrap.mkdir()
            gh = wrap / "gh"
            # The wrapper as --install writes it, pointed at the fake gh.
            gh.write_text(BUDGET_WAIT.read_text().replace("REAL_GH=gh ", f"REAL_GH='{fake}' ", 1))
            gh.chmod(0o755)
            out = t / "out"
            out.write_text("")
            env = git_fixture_env.fixture_env({
                "PATH": f"{wrap}:/usr/bin:/bin", "PR": "42", "HEAD_SHA": HEAD, "LAYERS": "web",
                "GITHUB_REPOSITORY": "manaflow-ai/cmux", "GITHUB_OUTPUT": str(out),
                "GITHUB_STEP_SUMMARY": str(t / "summary"), "RUNNER_TEMP": str(t),
                "GH_TOKEN": "t0", "GH_BUDGET_WAIT_MAX_SECONDS": "0",
            })
            done = subprocess.run(["bash", str(PR_SH)], env=env, capture_output=True, text=True, timeout=60)
            lines = dict(l.split("=", 1) for l in out.read_text().splitlines() if "=" in l)
            return done, lines, calls.read_text() if calls.exists() else ""

    def test_rest_answers(self) -> None:
        done, out, calls = self.run_read(f"""
            [[ "$2" == graphql ]] && exit 9
            printf 'manaflow-ai/cmux\\t{HEAD}\\tfeat-cmux-next\\topen\\tfalse\\t-\\t-\\n'
            """)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(out["ok"], "true")
        self.assertEqual(out["publish_web"], "true")
        self.assertEqual(out["layers"], "web")
        self.assertNotIn("graphql", calls)

    def test_spent_rest_hour_reads_graphql_without_sleeping(self) -> None:
        done, out, calls = self.run_read(f"""
            if [[ "$2" == rate_limit ]]; then echo 0; exit 0; fi
            if [[ "$2" == graphql ]]; then
              printf 'manaflow-ai/cmux\\t{HEAD}\\tfeat-cmux-next\\topen\\tfalse\\t-\\t-\\n'; exit 0
            fi
            echo "gh: API rate limit exceeded for installation ID 1 (HTTP 403)" >&2; exit 1
            """)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(out["ok"], "true")
        self.assertEqual(out["pr_head"], HEAD)
        self.assertIn("graphql", calls)

    def test_graphql_merged_state_reads_as_closed_and_merged(self) -> None:
        done, out, _ = self.run_read("""
            if [[ "$2" == graphql ]]; then
              # what gh's --jq prints for a merged pull request whose merge commit is the head
              printf 'manaflow-ai/cmux\\tbbbb\\tfeat-cmux-next\\tclosed\\tfalse\\t2026-11-24T00:00:00Z\\t%s\\n' "$HEAD_SHA"; exit 0
            fi
            echo "API rate limit exceeded" >&2; exit 1
            """)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(out["ok"], "true")
        self.assertEqual(out["publish_web"], "false")
        self.assertEqual(out["layers"], "web")

    def test_graphql_jq_maps_the_states(self) -> None:
        text = PR_SH.read_text()
        self.assertIn('if .state == "OPEN" then "open" else "closed" end', text)
        self.assertIn("GH_BUDGET_WAIT_MAX_SECONDS=0 gh api graphql", text)

    def test_both_refused_ends_with_the_refusal(self) -> None:
        done, _, calls = self.run_read("""
            if [[ "$2" == rate_limit ]]; then echo 0; exit 0; fi
            echo "API rate limit exceeded" >&2; exit 1
            """)
        self.assertNotEqual(done.returncode, 0)
        self.assertEqual(calls.count("pulls/42"), 2)

    def test_workflow_reads_take_the_spare_and_target_caps_its_wait(self) -> None:
        text = WORKFLOW.read_text()
        self.assertEqual(text.count("- name: Mint the pull request read's spare token"), 2)
        # plan's dispatch, web layer's dispatch, the two pull request reads, and publish's gallery read and
        # one-more-look dispatch.
        self.assertEqual(text.count("GH_TOKEN_SPARE: ${{ steps.cmux-bot-token.outputs.token }}"), 7)
        target = text.split("  target:", 1)[1].split("\n  web:", 1)[0]
        self.assertIn("GH_BUDGET_WAIT_MAX_SECONDS: 120", target)
        self.assertIn("permission-pull-requests: read", target)

    # 2026-11-25: every web and rust layer went red on github.token's spent hour ("API rate limit exceeded for
    # installation", jobs 139099457954 and 139101072630).
    def test_web_layer_dispatch_moves_to_the_spare_when_rate_limited(self) -> None:
        web = WORKFLOW.read_text().split("\n  web:", 1)[1].split("\n  rust:", 1)[0]
        self.assertIn("- name: Mint the dispatch's spare token", web)
        self.assertIn("GH_TOKEN_SPARE: ${{ steps.cmux-bot-token.outputs.token }}", web)
        # The budget wrapper is gh for the dispatch, so a rate limit moves to the spare and each pool.
        self.assertLess(web.index("gh_budget_wait.sh --install"), web.index("- name: Start the web layer"))

    # 2026-11-26 15:00-19:00Z: post the look ran 584 s at the median and 2,290 s at p90 over 215 jobs, nearly all of
    # it in the one-more-look dispatch and the gallery read sleeping out github.token's spent hour.
    def test_publish_dispatch_and_gallery_read_go_out_on_the_pools_and_spare(self) -> None:
        publish = WORKFLOW.read_text().split("name: post the look", 1)[1]
        self.assertIn('CI_POOL_PERMISSIONS: \'{"contents":"read","actions":"write"}\'', publish)
        self.assertIn("permission-actions: write", publish.split("- name: Mint the pull request read's spare token", 1)[1].split("- name:", 1)[0])
        for step in ("- name: Dispatch one more look", "- name: Is the gallery advisory also on this head"):
            env = publish.split(step, 1)[1].split("run: |", 1)[0]
            self.assertIn("GH_TOKEN: ${{ env.CI_POOL_GH_TOKEN || github.token }}", env)
            self.assertIn("GH_TOKEN_SPARE: ${{ steps.cmux-bot-token.outputs.token }}", env)
            self.assertIn("GH_TOKEN_SPARES: ${{ env.CI_POOL_GH_TOKEN_SPARES }} ${{ github.token }}", env)

    def test_rust_layer_reads_the_pull_request_only_when_it_will_dispatch(self) -> None:
        rust = WORKFLOW.read_text().split("\n  rust:", 1)[1].split("\n  request:", 1)[0]
        ask = rust.split("- name: Ask for the head's tree when it is not published", 1)[1]
        self.assertLess(ask.index('if [[ "${LOOK_DISPATCH:-}" != 1 ]]'), ask.index("gh api"))


if __name__ == "__main__":
    unittest.main()
