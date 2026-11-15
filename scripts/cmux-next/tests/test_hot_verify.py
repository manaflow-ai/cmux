#!/usr/bin/env python3
"""hot-verify.py: the plan, the receipt's marker, the sources and the pixel check, on any host (Linux included).

No app, no fleet, no network: a scratch git repo stands in for the checkout, hot-apply's and live_apply's rules
are stand-ins where the plan's own logic is what is checked, and PNGs are written here.

    python3 -m unittest scripts/cmux-next/tests/test_hot_verify.py
"""
import importlib.util
import json
import os
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
_git_fixture_env = importlib.util.spec_from_file_location("git_fixture_env", HERE.parents[2] / "tests/git_fixture_env.py")
git_fixture_env = importlib.util.module_from_spec(_git_fixture_env)
_git_fixture_env.loader.exec_module(git_fixture_env)


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


hv = load("hot_verify", HERE.parent / "hot-verify.py")
png_diff = load("png_diff", HERE.parent / "png_diff.py")


def git(repo, *args):
    return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, text=True,
                          env={**os.environ, **getattr(git_fixture_env, "ENV", {}),
                               "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@x", "GIT_COMMITTER_NAME": "t",
                               "GIT_COMMITTER_EMAIL": "t@x"}).stdout.strip()


def write_png(path, width, height, pixel, filter_kind=0):
    """An RGB PNG of one color, with every row under FILTER_KIND (0 none, 1 sub, 2 up)."""
    rows = b""
    for y in range(height):
        raw = bytes(pixel) * width
        if filter_kind == 1:
            line = bytearray(raw)
            for i in range(len(raw) - 1, 2, -1):
                line[i] = (raw[i] - raw[i - 3]) & 0xFF
            raw = bytes(line)
        elif filter_kind == 2 and y > 0:
            raw = bytes(len(raw))
        rows += bytes([filter_kind if (filter_kind != 2 or y > 0) else 0]) + raw

    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)

    Path(path).write_bytes(png_diff.SIGNATURE + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
                           + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


class Sources(unittest.TestCase):
    def test_parse(self):
        self.assertEqual(hv.parse_source("dir:."), ("dir", "."))
        self.assertEqual(hv.parse_source("pr:43591"), ("pr", "43591"))
        self.assertEqual(hv.parse_source("sha:20a18ceaac"), ("sha", "20a18ceaac"))
        self.assertEqual(hv.parse_source("profile:x.json"), ("profile", "x.json"))
        for bad in ("43591", "pr:abc", "sha:xyz", "tag:1", "dir:"):
            with self.assertRaises(ValueError, msg=bad):
                hv.parse_source(bad)

    def test_snapshot_commit_takes_edits_and_untracked_files_and_leaves_the_index(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            git(repo, "init", "-q")
            (repo / "a.txt").write_text("one\n")
            (repo / ".gitignore").write_text("ignored/\n")
            git(repo, "add", ".")
            git(repo, "commit", "-q", "-m", "base")
            head = git(repo, "rev-parse", "HEAD")
            self.assertEqual(hv.snapshot_commit(repo), head, "a clean tree is its HEAD")
            (repo / "a.txt").write_text("two\n")
            (repo / "new.txt").write_text("new\n")
            (repo / "ignored").mkdir()
            (repo / "ignored/x").write_text("x\n")
            snap = hv.snapshot_commit(repo)
            self.assertNotEqual(snap, head)
            self.assertEqual(git(repo, "rev-parse", f"{snap}^"), head)
            self.assertEqual(git(repo, "show", f"{snap}:a.txt"), "two")
            self.assertEqual(git(repo, "show", f"{snap}:new.txt"), "new")
            self.assertNotIn("ignored/x", git(repo, "ls-tree", "-r", "--name-only", snap))
            self.assertEqual(git(repo, "status", "--porcelain").splitlines(), ["M a.txt", "?? new.txt"])
            self.assertEqual(git(repo, "diff", "--cached", "--name-only"), "", "the real index is untouched")

    def test_dir_source_names_its_head_and_dirty(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            git(repo, "init", "-q")
            (repo / "a").write_text("1\n")
            git(repo, "add", ".")
            git(repo, "commit", "-q", "-m", "base")
            head = git(repo, "rev-parse", "HEAD")
            (repo / "a").write_text("2\n")
            source = hv.resolve_source("dir", str(repo), repo)
            self.assertEqual(source["marker_sha"], head)
            self.assertTrue(source["dirty"])
            self.assertEqual(source["receipt_source"], "worktree")


class StubHot:
    """hot-apply.py's rules the plan calls, decided by the test."""
    NATIVE_IN_TUI = hv.re.compile(r"^cmux-tui/.+\.(c|h|m|mm|zig)$")

    def __init__(self, files, linked=(), keys=None, abi=None, ancestor=True):
        self.files, self.linked, self.keys, self.abi, self.ancestor = files, list(linked), keys or {}, abi, ancestor
        hot = self

        class Live:
            @staticmethod
            def classify_range(repo, since, head):
                order = ["rebuild", "swift-live", "daemon", "web-live", "ios-only", "no-app"]
                kinds = {k: list(v) for k, v in hot.files.items()}
                return {"verdict": next((k for k in order if kinds.get(k)), "no-app"), "files": kinds, "reasons": {}}
        self.live_apply = Live

    def is_ancestor(self, repo, older, newer):
        return self.ancestor if older == "APP" else False

    def app_commit(self, app, repo):
        return "APP"

    def linked_rust(self, repo, paths):
        return [p for p in paths if p in self.linked]

    def helper_rust(self, repo, paths):
        return []

    def tree_key(self, repo, sha):
        return self.keys.get(sha, "same")

    def app_abi(self, app):
        return self.abi


class Plan(unittest.TestCase):
    def plan(self, files, **kw):
        source = {"kind": "sha", "repo": Path("."), "head": "HEAD1", "marker_sha": "a" * 40, "receipt_source": "pr"}
        hot = StubHot(files, **kw)
        original = hv.git
        hv.git = lambda repo, *args, **k: "APP" if args[:1] in (("rev-parse",), ("merge-base",)) else ""
        original_abi = hv.web_abi
        hv.web_abi = lambda repo, commit: 7
        try:
            return hv.make_plan(source, None, "APP", hot=hot, live=hot.live_apply)
        finally:
            hv.git, hv.web_abi = original, original_abi

    def test_web_only_is_live(self):
        out = self.plan({"web-live": ["webviews/src/x.tsx"], "no-app": ["webviews/src/x.test.ts"]})
        self.assertEqual(out["layers"], ["web"])
        self.assertFalse(out["needs_build"])

    def test_daemon_rust_is_live(self):
        out = self.plan({"daemon": ["cmux-tui/crates/acpmux/src/a.rs"]})
        self.assertEqual(out["layers"], ["rust"])
        self.assertFalse(out["needs_build"])

    def test_ffi_rust_needs_a_build(self):
        out = self.plan({"daemon": ["cmux-tui/crates/cmux-app-ffi/src/a.rs"]},
                        linked=["cmux-tui/crates/cmux-app-ffi/src/a.rs"])
        self.assertEqual(out["layers"], [])
        self.assertTrue(out["needs_build"])
        self.assertIn("Rust the app links (FFI)", out["build"])
        self.assertIn("build_command", out)

    def test_swift_needs_a_build_and_web_still_listed(self):
        out = self.plan({"rebuild": ["Packages/macOS/CmuxNext/Sources/X/a.swift"], "web-live": ["webviews/src/a.ts"]})
        self.assertTrue(out["needs_build"])
        self.assertEqual(out["layers"], ["web"])

    def test_native_sources_in_cmux_tui_count_as_its_rust(self):
        out = self.plan({"rebuild": ["cmux-tui/crates/x/src/shim.c"]})
        self.assertEqual(out["layers"], ["rust"])
        self.assertFalse(out["needs_build"])

    def test_nothing_in_the_app(self):
        out = self.plan({"no-app": ["docs/a.md"]})
        self.assertEqual(out["layers"], [])
        self.assertFalse(out["needs_build"])
        self.assertTrue(any("nothing in the app" in n for n in out["notes"]))

    def test_profile_is_customize(self):
        out = hv.make_plan({"kind": "profile", "head": None, "marker_sha": None}, None, "APP")
        self.assertEqual(out["layers"], ["customize"])


class Receipt(unittest.TestCase):
    def test_marker_shape(self):
        line = hv.marker("a" * 40, "b1f76a2", ["web", "rust"], "worktree")
        self.assertEqual(line, f"<!-- cmux-hot-verify sha={'a' * 40} app=b1f76a2 layers=web,rust source=worktree -->")
        self.assertIn("layers=none", hv.marker(None, None, [], "pr"))

    def test_default_steps_follow_what_changed(self):
        chat = hv.default_steps({"web-live": ["webviews/src/agent-pane/Row.tsx"]})
        self.assertEqual(chat[0], {"recording": "start", "clip": "look"})
        self.assertEqual(chat[-1], {"recording": "stop"})
        self.assertIn({"action": "palette.newAgentChat", "name": "open-agent-chat"}, chat)
        other = hv.default_steps({"daemon": ["cmux-tui/crates/acpmux/src/a.rs"]})
        self.assertIn({"action": "newTab", "name": "new-tab"}, other)

    def test_phases_add_up(self):
        ticks = iter([0.0, 1.0, 3.0, 3.5, 4.0, 10.0])
        phases = hv.Phases(clock=lambda: next(ticks))
        with phases("app"):
            pass
        with phases("after"):
            pass
        self.assertEqual(phases.seconds, {"app": 2.0, "after": 0.5})
        self.assertEqual(phases.total(), 10.0)

    def test_cli_usage_errors_exit_2(self):
        done = subprocess.run([sys.executable, str(HERE.parent / "hot-verify.py"), "plan", "--source", "nope"],
                              capture_output=True, text=True)
        self.assertEqual(done.returncode, 2)
        self.assertIn("--source takes", done.stderr)


class PixelDiff(unittest.TestCase):
    def test_same_and_changed(self):
        with tempfile.TemporaryDirectory() as tmp:
            a, b, c, d = (Path(tmp) / n for n in ("a.png", "b.png", "c.png", "d.png"))
            write_png(a, 40, 30, (10, 20, 30))
            write_png(b, 40, 30, (10, 20, 30), filter_kind=1)
            write_png(c, 40, 30, (200, 20, 30), filter_kind=2)
            write_png(d, 41, 30, (10, 20, 30))
            self.assertEqual(png_diff.decode(a)[3], png_diff.decode(b)[3], "the Sub filter decodes")
            self.assertEqual(png_diff.changed(a, b), 0.0)
            self.assertEqual(png_diff.changed(a, c), 1.0)
            self.assertEqual(png_diff.changed(a, d), 1.0, "another size is a change")

    def test_not_a_png(self):
        with tempfile.TemporaryDirectory() as tmp:
            bad = Path(tmp) / "x.png"
            bad.write_bytes(b"nope")
            with self.assertRaises(ValueError):
                png_diff.decode(bad)


if __name__ == "__main__":
    unittest.main()
