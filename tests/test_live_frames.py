#!/usr/bin/env python3
"""scripts/cmux-next/live_frames.py and its callers: a `cmux live` loop's build in place asks the chat
for a frame (cmuxterm-hq RFD 0152), never blocking or failing the loop.

Run it yourself (under 1 s, no build, no app): python3 tests/test_live_frames.py
"""

from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts/cmux-next"))
import live_frames  # noqa: E402


def load(name: str, rel: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / rel)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


class Command(unittest.TestCase):
    def test_names_the_chat_and_the_source(self):
        env = {"ACPMUX_SESSION_ID": "chat-1", "ACPMUX_BIN": "/opt/acpmux"}
        self.assertEqual(live_frames.command("rust", env), ["/opt/acpmux", "frame", "chat-1", "--built", "rust"])

    def test_nothing_outside_a_chat_or_for_an_unknown_source(self):
        self.assertIsNone(live_frames.command("rust", {"ACPMUX_BIN": "/opt/acpmux"}))

    def test_the_tree_reaches_the_chats_working_in_it_with_or_without_a_chat(self):
        env = {"ACPMUX_SESSION_ID": "chat-1", "ACPMUX_BIN": "/opt/acpmux"}
        self.assertEqual(live_frames.command("rust", env, "/w/cmux"),
                         ["/opt/acpmux", "frame", "chat-1", "--built", "rust", "--tree", "/w/cmux"])
        # A loop from a plain terminal: no chat, only the tree.
        self.assertEqual(live_frames.command("swift", {"ACPMUX_BIN": "/opt/acpmux"}, Path("/w/cmux")),
                         ["/opt/acpmux", "frame", "@", "--built", "swift", "--tree", "/w/cmux"])
        self.assertIsNone(live_frames.command("gradle", {"ACPMUX_SESSION_ID": "c", "ACPMUX_BIN": "/opt/acpmux"}))
        self.assertIsNone(live_frames.command("rust", {"ACPMUX_SESSION_ID": "c", "PATH": "/nonexistent"}))

    def test_runs_acpmux_off_the_loop(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "argv.json"
            fake = Path(tmp) / "acpmux"
            fake.write_text(f"#!{sys.executable}\nimport json, sys\nopen({str(out)!r}, 'w').write(json.dumps(sys.argv[1:]))\n")
            fake.chmod(fake.stat().st_mode | stat.S_IXUSR)
            thread = live_frames.built("swift", {"ACPMUX_SESSION_ID": "chat-2", "PATH": tmp})
            self.assertIsNotNone(thread)
            thread.join(10)
            self.assertEqual(json.loads(out.read_text()), ["frame", "chat-2", "--built", "swift"])

    def test_a_failing_or_missing_acpmux_never_raises(self):
        self.assertIsNone(live_frames.ask(["/nonexistent/acpmux", "frame"]))


class RustLive(unittest.TestCase):
    def setUp(self):
        self.rl = load("rust_live_frames", "scripts/cmux-next/rust-live.py")

    def loop(self, state: Path, on_swap=None):
        loop = object.__new__(self.rl.Loop)
        loop.state, loop.on_swap, loop.tree = state, on_swap, Path("/w/cmux")
        return loop

    def test_a_swap_asks_and_a_failed_build_does_not(self):
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(self.rl.live_frames, "built") as built:
            loop = self.loop(Path(tmp))
            loop.record({"outcome": "build_failed"})
            built.assert_not_called()
            loop.record({"outcome": "swapped"})
            built.assert_called_once_with("rust", tree=Path("/w/cmux"))

    def test_the_measurement_loop_never_asks(self):
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(self.rl.live_frames, "built") as built:
            self.loop(Path(tmp), on_swap=lambda entry: None).record({"outcome": "swapped"})
            built.assert_not_called()


class LiveMode(unittest.TestCase):
    def test_an_applied_patch_asks(self):
        lm = load("live_mode_frames", "scripts/live-code/live-mode.py")
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(lm.live_frames, "built") as built:
            log = Path(tmp) / "live-code.log"
            log.write_text("")
            phases = lm.Phases(Path(tmp) / "phases.jsonl", log=log, tree=Path("/w/cmux"))
            phases.waiting["patch1"] = (0.0, {"placed_at": 1.0, "heard_at": 0.5})
            with log.open("a") as f:
                f.write("applied patch1.dylib load_ms=3 at=2.0\n")
            phases.settle()
            built.assert_called_once_with("swift", tree=Path("/w/cmux"))


if __name__ == "__main__":
    unittest.main()
