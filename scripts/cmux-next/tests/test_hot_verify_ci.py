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
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "scripts" / "cmux-next" / "hot-verify-ci.py"
WORKFLOW = ROOT / ".github" / "workflows" / "cmux-next-hot-verify.yml"
WEB_PUBLISH = ROOT / ".github" / "workflows" / "cmux-next-web-bundle-publish.yml"
spec = importlib.util.spec_from_file_location("hot_verify_ci", SCRIPT)
hv = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = hv
spec.loader.exec_module(hv)

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
        lines = WORKFLOW.read_text().splitlines()
        start = next(i for i, line in enumerate(lines) if line.strip().startswith('nonce="hv-'))
        end = next(i for i in range(start, len(lines)) if lines[i].strip().startswith('log="$RUNNER_TEMP/look.log"'))
        packing = textwrap.dedent("\n".join(lines[start:end]))
        script = "enable -n mapfile readarray\nset -uo pipefail\n" + packing + '\nprintf "%s\\n" "${args[@]}"\n'
        done = subprocess.run(["bash", "-c", script], cwd=ROOT, capture_output=True, text=True,
                              env={**os.environ, "PR": "7", "HEAD_SHA": "a" * 40, "GITHUB_RUN_ID": "1",
                                   "GITHUB_RUN_ATTEMPT": "1"})
        self.assertEqual(done.returncode, 0, done.stderr)
        args = done.stdout.splitlines()
        self.assertTrue(args and all(a.startswith("--arg=") and len(a) > len("--arg=") for a in args), done.stdout)
        expected = hv.pack(hv.step_inputs(7, "a" * 40, "hv-7-aaaaaaaaaaaa-1-1", True))
        self.assertEqual([a[len("--arg="):] for a in args], expected)

    def test_the_plan_fetch_finds_the_merge_base_after_a_depth_one_checkout(self) -> None:
        # The fleet's looks on #43862, #43807, #43816 and #43779 failed at `git merge-base` (2026-11-15): the
        # checkout's depth-1 fetch left the base tip shallow and the step's --shallow-since fetch did not deepen it.
        lines = WORKFLOW.read_text().splitlines()
        start = next(i for i, line in enumerate(lines) if line.strip().startswith('since="$(date'))
        end = next(i for i in range(start, len(lines)) if 'git rev-parse refs/remotes/pr/head' in lines[i])
        fetch = textwrap.dedent("\n".join(lines[start:end]))
        with tempfile.TemporaryDirectory(prefix="hot-verify-fetch-") as scratch:
            root = Path(scratch)
            env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t",
                   "GIT_COMMITTER_EMAIL": "t@t", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"}

            def git(cwd: Path, *args: str) -> str:
                return subprocess.run(["git", "-C", str(cwd), *args], check=True, capture_output=True, text=True,
                                      env=env).stdout.strip()

            src = root / "src"
            src.mkdir()
            git(src, "init", "-q", "-b", "feat-cmux-next")
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
            git(clone, "init", "-q")
            git(clone, "remote", "add", "origin", src.as_uri())
            # As actions/checkout: the base branch alone, at depth 1.
            git(clone, "fetch", "-q", "--no-tags", "--depth=1", "origin",
                "+refs/heads/feat-cmux-next:refs/remotes/origin/feat-cmux-next")
            subprocess.run(["bash", "-euo", "pipefail", "-c", fetch], cwd=clone, check=True, capture_output=True,
                           env={**env, "BASE_REF": "feat-cmux-next", "PR": "7"})
            self.assertEqual(git(clone, "merge-base", "refs/remotes/pr/head", "refs/remotes/origin/feat-cmux-next"),
                             fork)

    def test_the_web_publisher_takes_a_pr_dispatch(self) -> None:
        text = WEB_PUBLISH.read_text()
        self.assertIn("workflow_dispatch:", text)


if __name__ == "__main__":
    unittest.main()
