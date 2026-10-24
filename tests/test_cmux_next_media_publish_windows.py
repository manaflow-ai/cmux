#!/usr/bin/env python3
"""scripts/cmux-next/media/publish.py shows a step's other windows (floating panels, popovers,
sheets: tour.py's `windows`) beside its main-window shot, uploads them, and drops a window entry
whose path tour.py could not have written."""

from __future__ import annotations

import argparse
import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("media_publish", ROOT / "scripts/cmux-next/media/publish.py")
publish = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(publish)
PNG = b"\x89PNG\r\n\x1a\n" + b"0" * 32


class FakePrMedia:
    BRANCH = "pr-media"
    INLINE_MAX_BYTES = 10_000_000

    def __init__(self, fail=()):
        self.puts = []
        self.fail = fail
        self.checked = []

    def check_privacy(self, items, repo, **options):
        self.checked.extend(remote for remote, _local in items)

    def family_of_content(self, path):
        return "png" if path.read_bytes().startswith(b"\x89PNG") else "other"

    def put_file(self, repo, branch, remote, local, message, checked=False):
        if any(remote.endswith(name) for name in self.fail):
            raise RuntimeError("secondary rate limit")
        self.puts.append(remote)

    def raw_url(self, repo, branch, remote):
        return f"https://raw.githubusercontent.com/{repo}/{branch}/{remote}"

    def tool_env(self):
        return {"PATH": "/usr/bin"}

    def gif_argv(self, source, destination, fps, width):
        return ["ffmpeg", str(source), str(destination)]


STEP = {
    "index": 1, "title": "Open the pet", "status": "ok", "shot": "shots/01-open-the-pet.png",
    "windows": [
        {"id": 7, "kind": "chiefPet", "shot": "shots/01-open-the-pet--w7.png"},
        {"id": 8, "kind": "x<script>", "shot": "../../etc/passwd"},
        {"id": 9, "kind": "quickReply", "shot": "shots/01-open-the-pet--w9.png"},
    ],
}


class PublishWindowsTests(unittest.TestCase):
    def test_clean_step_keeps_only_window_shots_tour_py_writes(self):
        step = publish.clean_step(STEP)
        self.assertEqual([w["shot"] for w in step["windows"]],
                         ["shots/01-open-the-pet--w7.png", "shots/01-open-the-pet--w9.png"])
        self.assertEqual(step["windows"][0]["kind"], "chiefPet")

    def test_window_shots_are_uploaded_and_shown_beside_the_step(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp) / "agent-pane"
            (directory / "shots").mkdir(parents=True)
            for name in ("01-open-the-pet.png", "01-open-the-pet--w7.png", "01-open-the-pet--w9.png"):
                (directory / "shots" / name).write_bytes(PNG)
            scratch = Path(tmp) / "scratch"
            scratch.mkdir()
            manifest = {"title": "Agent pane", "steps": [publish.clean_step(STEP)], "frames": []}
            fake = FakePrMedia()
            args = argparse.Namespace(pr=21672, sha="a" * 40, repo="manaflow-ai/cmux", dry_run=False)
            text = publish.publish_tour(directory, manifest, args, fake, scratch)
        self.assertEqual(sorted(fake.puts), [
            "21672/aaaaaaaa/next-agent-pane/shots/01-open-the-pet--w7.png",
            "21672/aaaaaaaa/next-agent-pane/shots/01-open-the-pet--w9.png",
            "21672/aaaaaaaa/next-agent-pane/shots/01-open-the-pet.png",
        ])
        main = text.index("shots/01-open-the-pet.png")
        self.assertLess(main, text.index("shots/01-open-the-pet--w7.png"))
        self.assertIn('alt="Open the pet (chiefPet)"', text)
        self.assertIn("shots/01-open-the-pet--w9.png", text)

    def test_a_failed_window_upload_drops_only_that_window(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp) / "agent-pane"
            (directory / "shots").mkdir(parents=True)
            for name in ("01-open-the-pet.png", "01-open-the-pet--w7.png", "01-open-the-pet--w9.png"):
                (directory / "shots" / name).write_bytes(PNG)
            scratch = Path(tmp) / "scratch"
            scratch.mkdir()
            manifest = {"title": "Agent pane", "steps": [publish.clean_step(STEP)], "frames": []}
            fake = FakePrMedia(fail=("--w7.png",))
            args = argparse.Namespace(pr=21672, sha="a" * 40, repo="manaflow-ai/cmux", dry_run=False)
            text = publish.publish_tour(directory, manifest, args, fake, scratch)
        self.assertIn("shots/01-open-the-pet.png", text)
        self.assertIn("shots/01-open-the-pet--w9.png", text)
        self.assertNotIn("--w7.png", text)

class MakeVideoTests(unittest.TestCase):
    def test_ffmpeg_gets_only_the_tool_environment(self):
        envs = []

        def run(argv, **kwargs):
            envs.append(kwargs.get("env"))
            Path(argv[-1]).write_bytes(b"x")
            return SimpleNamespace(returncode=0, stdout="", stderr="")

        with tempfile.TemporaryDirectory() as scratch, \
                mock.patch.object(publish.shutil, "which", return_value="/usr/bin/ffmpeg"):
            mp4, gif = publish.make_video(Path(scratch), {"frames": [1, 2]}, Path(scratch), FakePrMedia(), run=run)
        self.assertIsNotNone(mp4)
        self.assertIsNotNone(gif)
        self.assertEqual(envs, [{"PATH": "/usr/bin"}] * 2)


if __name__ == "__main__":
    unittest.main()
