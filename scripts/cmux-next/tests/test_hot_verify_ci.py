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
import json
import sys
import subprocess
import tarfile
import tempfile
import textwrap
import unittest
from contextlib import redirect_stderr
from unittest import mock
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "scripts" / "cmux-next" / "hot-verify-ci.py"
WORKFLOW = ROOT / ".github" / "workflows" / "cmux-next-hot-verify.yml"
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

    def test_needs_build_stages_nothing(self) -> None:
        out = self.unpacked({"out/step.json": json.dumps({"head": HEAD, "needs_build": True}).encode()})
        self.assertEqual(hv.stage(out, 43000, HEAD, self.tmp / "m", self.tmp / "t.txt"),
                         {"needs_build": True, "staged": [], "withheld": []})

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


class Workflow(unittest.TestCase):
    """The workflow's wiring that the script relies on (text checks; the house guards check the rest)."""

    def test_the_workflow_runs_this_script_from_the_protected_branch(self) -> None:
        text = WORKFLOW.read_text()
        self.assertIn("tool=scripts/cmux-next/hot-verify-ci.py", text)
        for command in ("verdict", "hq-ref", "pack", "unpack", "stage", "render", "post"):
            with self.subTest(command=command):
                self.assertTrue(f"hot-verify-ci.py {command} " in text or f'"$tool" {command} ' in text)
        self.assertIn("environment: pr-media", text)
        self.assertIn("uses: ./.github/actions/pr-media-publish", text)
        self.assertIn("gh workflow run cmux-next-web-bundle-publish.yml", text)
        self.assertNotIn("secrets: inherit", text)
        self.assertIn("--script build-fleet/pr_capture/fleet-step-hot-verify.sh --display --artifact out.tar", text)

    def test_the_look_step_packs_its_inputs_without_bash_4_builtins(self) -> None:
        # #43916's look on glaeda-5 died with "mapfile: command not found": a fleet Mac's /bin/bash is 3.2. Run the
        # step's packing lines with bash 4's array builtins switched off, as 3.2 has none of them.
        scratch = Path(self.enterContext(tempfile.TemporaryDirectory(prefix="hot-verify-bash32-")))
        env, calls = self.look_env(scratch, "[[ $1 == run ]] && exit 75\nexit 1\n", "1", "")
        script = "enable -n mapfile readarray\n" + self.look_steps()[0]
        done = subprocess.run(["bash", "-c", script], cwd=ROOT, env=env, capture_output=True, text=True)
        self.assertNotIn("command not found", done.stderr)
        run = next(c for c in calls.read_text().splitlines() if c.startswith("run "))
        args = [a[len("--arg="):] for a in run.split() if a.startswith("--arg=")]
        self.assertEqual(args, hv.pack(hv.step_inputs(7, HEAD, f"hv-7-{HEAD[:12]}", True)))

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

    def run_block(self, job: str, gh_out: str, env: dict) -> tuple[subprocess.CompletedProcess, Path, list[str]]:
        """Run JOB's one `run: |` script with a gh on PATH that prints GH_OUT and logs its argv; returns the
        process, the GITHUB_OUTPUT file and the gh calls."""
        block = self.job_block(job)
        start = next(i for i, line in enumerate(block) if line.strip() == "run: |") + 1
        script = textwrap.dedent("\n".join(block[start:]))
        scratch = Path(self.enterContext(tempfile.TemporaryDirectory(prefix="hot-verify-job-")))
        (scratch / "bin").mkdir()
        fake = scratch / "bin" / "gh"
        fake.write_text('#!/bin/bash\nprintf "%s\\0" "$@" >> "$GH_CALLS"; printf "%s\\n" "$GH_OUT"\n')
        fake.chmod(0o755)
        out, summary, calls = scratch / "out", scratch / "summary", scratch / "calls"
        done = subprocess.run(["bash", "-c", script], capture_output=True, text=True,
                              env={**os.environ, "PATH": f"{scratch / 'bin'}:{os.environ['PATH']}", "GH_OUT": gh_out,
                                   "GH_CALLS": str(calls), "GITHUB_OUTPUT": str(out), "GITHUB_STEP_SUMMARY": str(summary),
                                   "GITHUB_REPOSITORY": "manaflow-ai/cmux", **env})
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
                done, out, _ = self.run_block("target", row, env)
                self.assertEqual(done.returncode, 0, done.stderr)
                self.assertIn(f"ok={ok}\n", out.read_text())

    def test_a_look_lost_on_the_fleet_is_started_once_more_and_only_once(self) -> None:
        # 2026-11-16: run 43788086518's step failed on three lent Macs' disk declines, run 43788591989's worker
        # stopped renewing its lease, and a reserved fleet Mac's gateway runner refused 8 looks (runs
        # 43833883489, 43834069668, ...). Each lost its look for good: nothing started one again.
        block = "\n".join(self.job_block("again"))
        self.assertIn("needs: [target, look]", block)
        self.assertIn("needs.look.result == 'failure'", block)
        self.assertIn("inputs.attempt != '1'", block)
        self.assertIn("!cancelled()", block)
        self.assertIn("attempt:", WORKFLOW.read_text().split("jobs:", 1)[0])
        done, _, argv = self.run_block("again", "", {"PR": "7", "HEAD_SHA": HEAD, "LAYERS": "web,rust",
                                                      "EVENT_AT": "1794800000"})
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(argv[:2], ["workflow", "run"])
        self.assertIn("cmux-next-hot-verify.yml", argv)
        for field in ("pr=7", f"head={HEAD}", "layers=web,rust", "event_at=1794800000", "attempt=1"):
            self.assertIn(field, argv)
        done, _, argv = self.run_block("again", "", {"PR": "7", "HEAD_SHA": HEAD, "LAYERS": "rust", "EVENT_AT": "",
                                                      "KIND": "merge"})
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("kind=merge", argv)

    def test_a_merged_pr_with_no_receipt_is_looked_at_at_its_merge_commit(self) -> None:
        # A look at the PR head that needs the change's own Rust (8 of 90 looks, 2026-11-15/16) cannot run on the
        # nightly copy; at the merge commit the tree is published and the engine plans from its first parent. The
        # closed event plans and dispatches that look once, and only when the PR has no receipt yet.
        text = WORKFLOW.read_text()
        self.assertIn("types: [opened, synchronize, reopened, ready_for_review, closed]", text)
        self.assertIn("(github.event.action != 'closed' || github.event.pull_request.merged)", "\n".join(self.job_block("plan")))
        self.assertIn("hot-verify-receipt.py --pr", "\n".join(self.job_block("plan")))
        hand_off = "\n".join(self.job_block("hand-off"))
        self.assertIn("github.event.action == 'closed' && github.event.pull_request.merge_commit_sha", hand_off)
        self.assertIn('-f kind="$KIND"', hand_off)
        # its own concurrency group: it never cancels a head look still queued when the PR merged
        self.assertIn("inputs.kind == 'merge') && '-merge'", text)
        merge = "c" * 40
        row = f"manaflow-ai/cmux\t{OTHER}\tfeat-cmux-next\tclosed\tfalse\t2026-11-16T10:00:00Z\t{merge}"
        done, out, _ = self.run_block("target", row, {"PR": "7", "HEAD_SHA": merge, "LAYERS": "web,rust"})
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("ok=true\n", out.read_text())
        self.assertIn(f"pr_head={OTHER}\n", out.read_text())  # the web layer waits for the PR's own head
        unmerged = f"manaflow-ai/cmux\t{OTHER}\tfeat-cmux-next\topen\tfalse\t-\t{merge}"
        done, out, _ = self.run_block("target", unmerged, {"PR": "7", "HEAD_SHA": merge, "LAYERS": "rust"})
        self.assertIn("ok=false\n", out.read_text())

    def test_a_receipt_check_that_cannot_read_github_still_looks(self) -> None:
        # Run 44033383427 (cmux#45098, 2026-11-17): the receipt read hit "API rate limit exceeded for installation",
        # receipt=unknown counted as a receipt, and the merged daemon PR got no look. Only receipt=true skips.
        block = self.job_block("plan")
        start = next(i for i, line in enumerate(block) if line.strip() == "run: |") + 1
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
                                           "GITHUB_REPOSITORY": "manaflow-ai/cmux", "PR": "7", "BASE_REF": "feat-cmux-next",
                                           "HEAD_SHA": "c" * 40, "MERGED": "true"})
                said = summary.read_text() if summary.exists() else ""
                if skips:
                    self.assertEqual(done.returncode, 0, done.stderr)
                    self.assertIn("eligible=false", out.read_text())
                    self.assertNotIn("reached-git", said)
                else:
                    self.assertIn("reached-git", said, (done.stderr, said))
                    self.assertFalse(out.exists() and "eligible=false" in out.read_text())

    def look_steps(self) -> list[str]:
        """The look job's `run: |` scripts, each through the line before its next step."""
        block, scripts = self.job_block("look"), []
        for i, line in enumerate(block):
            if line.strip() == "run: |":
                indent = len(line) - len(line.lstrip()) + 2
                end = next((j for j in range(i + 1, len(block)) if block[j].strip()
                            and len(block[j]) - len(block[j].lstrip()) < indent), len(block))
                scripts.append(textwrap.dedent("\n".join(block[i + 1:end])))
        return scripts

    def test_a_look_that_stops_waiting_cancels_its_queued_fleet_step(self) -> None:
        # 2026-11-17 13:49Z: 49 hot-verify steps queued on the fleet, at least 23 of them from runs whose look had
        # already given up (exit 75 after --queue-timeout leaves the step queued "keeping its place") and whose
        # `look again` had queued a second one. Those orphans run later and are never posted.
        step = "0123456789abcdef01234567"
        scratch = Path(self.enterContext(tempfile.TemporaryDirectory(prefix="hot-verify-look-")))
        (scratch / "bin").mkdir()
        calls = scratch / "client-calls"
        client = scratch / "bin" / "cmux-ci"
        client.write_text("#!/bin/bash\necho \"$*\" >> \"$CALLS\"\n"
                          f"if [[ $1 == run ]]; then echo 'submitted step {step}'; exit 75; fi\n"
                          "[[ $1 == cancel ]] && exit 0\nexit 1\n")
        client.chmod(0o755)
        curl = scratch / "bin" / "curl"
        curl.write_text("#!/bin/bash\nwhile [[ $# -gt 0 ]]; do [[ $1 == -o ]] && { shift; printf '{\"commit\": \"%s\"}' "
                        f"{HEAD} > \"$1\"; }}; shift; done\n")
        curl.chmod(0o755)
        temp, out, summary = scratch / "temp", scratch / "out", scratch / "summary"
        temp.mkdir()
        env = {**os.environ, "PATH": f"{scratch / 'bin'}:{os.environ['PATH']}", "CALLS": str(calls),
               "CMUX_CI_CLIENT": str(client), "RUNNER_TEMP": str(temp), "GITHUB_OUTPUT": str(out),
               "GITHUB_STEP_SUMMARY": str(summary), "CONTROLLER": "http://controller", "PR": "7",
               "HEAD_SHA": HEAD, "GITHUB_RUN_ID": "99", "GITHUB_RUN_ATTEMPT": "1", "RUNNER_NAME": "test",
               "ATTEMPT": "1"}  # the last look: no `look again` follows to rejoin its step
        scripts = self.look_steps()
        done = subprocess.run(["bash", "-c", scripts[0]], cwd=ROOT, env=env, capture_output=True, text=True)
        self.assertNotEqual(done.returncode, 0)  # no look result is never green
        self.assertIn(f"cancel {step}", calls.read_text(), (done.stdout, done.stderr))
        # A job cancelled while it waits (a newer push's run, the job's time limit) cancels its step too.
        self.assertTrue(any("cancelled()" in line for line in self.job_block("look")), "no step runs on cancel")
        calls.unlink()
        (temp / "look.log").write_text(f"submitted step {step}\n")
        done = subprocess.run(["bash", "-c", scripts[-1]], cwd=ROOT, env=env, capture_output=True, text=True)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn(f"cancel {step}", calls.read_text())

    def look_env(self, scratch: Path, client_body: str, run_id: str, attempt: str) -> tuple[dict, Path]:
        """The look step's environment, with a fake cmux-ci of client_body and a fake curl."""
        (scratch / "bin").mkdir(exist_ok=True)
        client = scratch / "bin" / "cmux-ci"
        client.write_text("#!/bin/bash\necho \"$*\" >> \"$CALLS\"\n" + client_body)
        client.chmod(0o755)
        curl = scratch / "bin" / "curl"
        curl.write_text("#!/bin/bash\nwhile [[ $# -gt 0 ]]; do [[ $1 == -o ]] && { shift; printf '{\"commit\": \"%s\"}' "
                        f"{HEAD} > \"$1\"; }}; shift; done\n")
        curl.chmod(0o755)
        temp = scratch / f"temp-{run_id}"
        temp.mkdir()
        calls = scratch / "client-calls"
        return {**os.environ, "PATH": f"{scratch / 'bin'}:{os.environ['PATH']}", "CALLS": str(calls),
                "CMUX_CI_CLIENT": str(client), "RUNNER_TEMP": str(temp), "GITHUB_OUTPUT": str(scratch / "out"),
                "GITHUB_STEP_SUMMARY": str(scratch / "summary"), "CONTROLLER": "http://controller", "PR": "7",
                "HEAD_SHA": HEAD, "GITHUB_RUN_ID": run_id, "GITHUB_RUN_ATTEMPT": "1", "RUNNER_NAME": "test",
                "ATTEMPT": attempt}, calls

    def test_a_look_again_rejoins_the_queued_fleet_step_of_its_head(self) -> None:
        # 2026-11-17: a look step runs about 2.5 min (p50 of 297) but waits 18 min p50 and 2 h p90 for a Mac. The client
        # stops waiting at 30 min and `look again` used to submit a new step under a new key, at the back of the queue;
        # #45314's step ran at 10:24 after waiting 2 h, with nobody left to post it. One key per PR head lets the retry
        # rejoin the step where it stands, or take its out.tar when it has run since.
        step = "0123456789abcdef01234567"
        scratch = Path(self.enterContext(tempfile.TemporaryDirectory(prefix="hot-verify-rejoin-")))
        body = (f"if [[ $1 == run ]]; then echo 'cmux-ci: step {step} (light, key x)'; exit 75; fi\n"
                "[[ $1 == cancel ]] && exit 0\nexit 1\n")
        script = self.look_steps()[0]
        keys = []
        for run_id, attempt in (("99", ""), ("100", "1")):
            env, calls = self.look_env(scratch, body, run_id, attempt)
            if calls.exists():
                calls.unlink()
            done = subprocess.run(["bash", "-c", script], cwd=ROOT, env=env, capture_output=True, text=True)
            self.assertNotEqual(done.returncode, 0)
            made = calls.read_text().splitlines()
            keys.append(next(c.split("--key ", 1)[1].split()[0] for c in made if c.startswith("run ")))
            # The first look leaves its step queued for `look again`; the last one has no retry after it.
            self.assertEqual(any(c.startswith(f"cancel {step}") for c in made), attempt == "1", made)
        self.assertEqual(keys[0], keys[1])
        self.assertEqual(keys[0], f"hv-7-{HEAD[:12]}")

    def test_a_look_whose_head_step_already_failed_runs_a_fresh_one(self) -> None:
        # The same key returns the step it made in any state: one that failed before must not be the only answer.
        old, new = "aaaaaaaaaaaaaaaaaaaaaaaa", "bbbbbbbbbbbbbbbbbbbbbbbb"
        scratch = Path(self.enterContext(tempfile.TemporaryDirectory(prefix="hot-verify-fresh-")))
        body = ("if [[ $1 == run ]]; then\n"
                "  for a in \"$@\"; do [[ $prev == --key ]] && key=$a; prev=$a; done\n"
                f"  if [[ $key == hv-7-{HEAD[:12]} ]]; then echo 'cmux-ci: step {old} (light, key x)'; exit 1; fi\n"
                f"  echo 'cmux-ci: step {new} (light, key y)'; exit 0\n"
                "fi\n"
                f"if [[ $1 == artifact && $2 == {new} ]]; then echo tar > \"$3\"; exit 0; fi\n"
                "[[ $1 == cancel ]] && exit 0\nexit 1\n")
        env, calls = self.look_env(scratch, body, "99", "")
        done = subprocess.run(["bash", "-c", self.look_steps()[0]], cwd=ROOT, env=env, capture_output=True, text=True)
        self.assertEqual(done.returncode, 0, (done.stdout, done.stderr))
        made = calls.read_text().splitlines()
        runs = [c for c in made if c.startswith("run ")]
        self.assertEqual(len(runs), 2, runs)
        self.assertIn(f"--key hv-7-{HEAD[:12]}-99-1 ", runs[1])
        self.assertIn("result=ok", (scratch / "out").read_text())
        # The first step is cancelled before the fresh one: a client that stopped early may have left it queued.
        cancels = [i for i, c in enumerate(made) if c.startswith(f"cancel {old}")]
        self.assertTrue(cancels and cancels[0] < made.index(runs[1]), made)

    def test_a_looks_queue_bound_follows_the_fleets_p90_wait(self) -> None:
        # 2026-11-18: 77 look steps since 00Z waited 13 s p50 but 6087 s p90 for a Mac, past the fixed --queue-timeout 1800
        # (hq docs/handbook/deadline-counts-queue-wait.md lists this caller as missing). The bound is the controller's
        # reported p90 for class light, at least 1800 s and at most 3 h; unreadable, it stays 1800 s.
        body = "[[ $1 == run ]] && { echo 'cmux-ci: step aaaaaaaaaaaaaaaaaaaaaaaa (light, key x)'; exit 75; }\n" \
               "[[ $1 == cancel ]] && exit 0\nexit 1\n"
        for p90, bound in ((6087.4, 6088), (600, 1800), (50000, 10800), (None, 1800)):
            with self.subTest(p90=p90):
                scratch = Path(self.enterContext(tempfile.TemporaryDirectory(prefix="hot-verify-bound-")))
                env, calls = self.look_env(scratch, body, "99", "1")
                status = "" if p90 is None else json.dumps({"step_queue_wait_p90_seconds": {"light": p90, "simulator": 1}})
                (scratch / "status.json").write_text(status)
                (scratch / "bin" / "curl").write_text(
                    "#!/bin/bash\nurl=; out=\nwhile [[ $# -gt 0 ]]; do case $1 in -o) shift; out=$1;; http*) url=$1;; esac; shift; done\n"
                    f"if [[ $url == */v1/status ]]; then [[ -s '{scratch / 'status.json'}' ]] || exit 22; "
                    f"cp '{scratch / 'status.json'}' \"$out\"; else printf '{{\"commit\": \"%s\"}}' {HEAD} > \"$out\"; fi\n")
                subprocess.run(["bash", "-c", self.look_steps()[0]], cwd=ROOT, env=env, capture_output=True, text=True)
                run = next(c for c in calls.read_text().splitlines() if c.startswith("run "))
                self.assertIn(f"--queue-timeout {bound} ", run)
        # The job outlives a fast first try (120 s), the longest bound, the step's own run limit (2400 s) and the reads.
        limit = next(int(line.split(":")[1]) for line in self.job_block("look") if line.strip().startswith("timeout-minutes:"))
        self.assertGreaterEqual(limit * 60, 120 + 10800 + 2400 + 600)
        # Whatever the controller sends, the bound is a number in range.
        for text in ("[]", '"x"', "null", '{"step_queue_wait_p90_seconds": null}', '{"step_queue_wait_p90_seconds": {"light": -Infinity}}',
                     '{"step_queue_wait_p90_seconds": {"light": NaN}}', '{"step_queue_wait_p90_seconds": {"light": ' + "9" * 400 + "}}"):
            self.assertIn(hv.queue_bound(text), (1800, 10800), text)

    def test_a_look_rejoins_its_head_step_at_that_steps_hq_commit(self) -> None:
        # #45082, 2026-11-17: its head step hv-45082-70e741a61349 was queued at 23:06 at HQ 1848f209. A run at 23:38 sent
        # the same key at the controller's newer HQ commit, got "HTTP 409: step_key already names a different step"
        # (the ref is part of the request), ran a fresh step instead, and the head step ran at 00:32 for nobody.
        old_ref, now_ref = "1" * 40, HEAD
        scratch = Path(self.enterContext(tempfile.TemporaryDirectory(prefix="hot-verify-ref-")))
        jobs = [{"id": "aaaaaaaaaaaaaaaaaaaaaaaa", "step_key": f"hv-7-{HEAD[:12]}", "ref": old_ref, "state": "queued",
                 "created_at": "2026-11-17T23:06:52Z"},
                {"id": "bbbbbbbbbbbbbbbbbbbbbbbb", "step_key": "hv-8-0123456789ab", "ref": "2" * 40, "state": "queued",
                 "created_at": "2026-11-17T23:10:00Z"}]
        (scratch / "all.json").write_text(json.dumps(jobs))
        body = (f"if [[ $1 == status && $2 == --all ]]; then cat '{scratch / 'all.json'}'; exit 0; fi\n"
                "if [[ $1 == run ]]; then echo 'cmux-ci: step aaaaaaaaaaaaaaaaaaaaaaaa (light, key x)'; exit 75; fi\n"
                "[[ $1 == cancel ]] && exit 0\nexit 1\n")
        env, calls = self.look_env(scratch, body, "99", "")
        subprocess.run(["bash", "-c", self.look_steps()[0]], cwd=ROOT, env=env, capture_output=True, text=True)
        runs = [c for c in calls.read_text().splitlines() if c.startswith("run ")]
        self.assertEqual(len(runs), 1, runs)
        self.assertIn(f"--ref {old_ref} ", runs[0])
        # With no step under the head key yet, the look runs at the controller's own HQ commit.
        (scratch / "all.json").write_text(json.dumps(jobs[1:]))
        calls.unlink()
        env, calls = self.look_env(scratch, body, "100", "")
        subprocess.run(["bash", "-c", self.look_steps()[0]], cwd=ROOT, env=env, capture_output=True, text=True)
        runs = [c for c in calls.read_text().splitlines() if c.startswith("run ")]
        self.assertIn(f"--ref {now_ref} ", runs[0])

    def test_a_look_at_a_new_head_cancels_the_prs_steps_at_other_heads(self) -> None:
        # A look that stopped waiting leaves its head's step queued for `look again`; when the author pushes meanwhile,
        # that retry never looks (the PR moved), so the new head's look retires the old step. Other PRs' are not touched.
        mine = f"hv-7-{HEAD[:12]}"
        queued = [("cccccccccccccccccccccccc", "hv-7-0123456789ab"), ("dddddddddddddddddddddddd", "hv-70-0123456789ab"),
                  ("eeeeeeeeeeeeeeeeeeeeeeee", mine), ("ffffffffffffffffffffffff", "build-thing")]
        status = json.dumps({"queued": [{"id": i, "step_key": k} for i, k in queued], "running": []})
        scratch = Path(self.enterContext(tempfile.TemporaryDirectory(prefix="hot-verify-moved-")))
        (scratch / "status.json").write_text(status)
        body = (f"if [[ $1 == status ]]; then cat '{scratch / 'status.json'}'; exit 0; fi\n"
                "if [[ $1 == run ]]; then echo 'cmux-ci: step eeeeeeeeeeeeeeeeeeeeeeee (light, key x)'; exit 75; fi\n"
                "[[ $1 == cancel ]] && exit 0\nexit 1\n")
        env, calls = self.look_env(scratch, body, "99", "")
        subprocess.run(["bash", "-c", self.look_steps()[0]], cwd=ROOT, env=env, capture_output=True, text=True)
        cancelled = {c.split()[1] for c in calls.read_text().splitlines() if c.startswith("cancel ")}
        self.assertEqual(cancelled, {"cccccccccccccccccccccccc"})

    def test_the_web_publisher_takes_a_pr_dispatch(self) -> None:
        text = WEB_PUBLISH.read_text()
        self.assertIn("workflow_dispatch:", text)


if __name__ == "__main__":
    unittest.main()
