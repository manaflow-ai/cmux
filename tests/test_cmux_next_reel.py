#!/usr/bin/env python3
"""scripts/cmux-next/media/reel.py, run as the CLI: pull requests come from the notes once
each, clips are picked from the pr-media listing, a build joins title cards and clips into
one reel with a page listing every pull request, and bad notes are refused."""

from __future__ import annotations

import html
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/cmux-next/media/reel.py"
HAS_FFMPEG = bool(shutil.which("ffmpeg") and shutil.which("ffprobe"))
RAW = "https://raw.githubusercontent.com/manaflow-ai/cmux/pr-media/"
ODD_TITLE = "it's 100%{pts} : a, b; [c] \\ d\nsecond line"
NOTES = {
    "version": 1, "build": "100", "items": [
        {"title": "Tabs keep their order", "author": "Ada", "pr": 11},
        {"title": "Unrelated commit", "author": "Bob"},
        {"title": "Tabs keep their order, part two", "author": "Ada", "pr": 11},
        {"title": "Sidebar: quieter", "author": "Cy", "pr": 22},
        {"title": "Cold start", "author": "Di", "pr": 44},
        {"title": "No media here", "author": "Ed", "pr": 33},
    ],
}
TREE = {"truncated": False, "tree": [{"path": p, "type": "blob"} for p in (
    # 11: two captures; the head fixture names the one that sorts first.
    "11/aaaaaaaa/next-core-after/tour.mp4",
    "11/bbbbbbbb/next-core-after/tour.mp4",
    "11/aaaaaaaa/next-core-before/tour.mp4",
    # 22: two captures and no head, so the pick is by name and says so.
    "22/cccccccc/next-core-after/tour.mp4",
    "22/dddddddd/next-new-tab-after/tour.mp4",
    # 44: only a before clip and a hand-posted clip.
    "44/eeeeeeee/next-core-before/tour.mp4",
    "44/44-cold-before-after.mp4",
    # 33 has nothing; 99 is not in the notes.
    "99/ffffffff/next-core-after/tour.mp4",
)]}


def reel(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, str(SCRIPT), *args], capture_output=True, text=True, timeout=240)


def write(path: Path, data) -> Path:
    path.write_text(data if isinstance(data, str) else json.dumps(data), encoding="utf-8")
    return path


def duration(path: Path) -> float:
    return float(subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0",
                                 str(path)], capture_output=True, text=True, check=True).stdout)


class DryRunTests(unittest.TestCase):
    def test_plan_from_notes_and_listing(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            done = reel("--build", "100", "--notes", str(write(tmp / "notes.json", NOTES)),
                        "--tree", str(write(tmp / "tree.json", TREE)),
                        "--heads", str(write(tmp / "heads.json", {"11": "aaaaaaaa" + "0" * 32})),
                        "--out", str(tmp / "out"), "--dry-run")
            self.assertEqual(done.returncode, 0, done.stderr)
            self.assertEqual(sorted(p.name for p in (tmp / "out").iterdir()), ["reel.json"])
            report = json.loads((tmp / "out/reel.json").read_text())
        prs = {p["pr"]: p for p in report["prs"]}
        self.assertEqual([p["pr"] for p in report["prs"]], [11, 22, 44, 33])
        self.assertEqual(prs[11]["title"], "Tabs keep their order")
        self.assertEqual(prs[11]["clip"], RAW + "11/aaaaaaaa/next-core-after/tour.mp4")
        self.assertNotIn("note", prs[11])
        self.assertEqual(prs[22]["clip"], RAW + "22/dddddddd/next-new-tab-after/tour.mp4")
        self.assertIn("head unknown", prs[22]["note"])
        self.assertEqual((prs[44]["source"], prs[44]["clip"]), ("manual", RAW + "44/44-cold-before-after.mp4"))
        self.assertEqual(prs[33]["clip"], "no clip")
        self.assertIsNone(report["reel"])

    def test_notes_without_items_use_the_pr_suffix_of_each_change(self):
        notes = {"build": "100", "changes": ["fix: a (#5)", "chore: b", "fix: c again (#5)", "feat: d (#6)"]}
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            done = reel("--build", "100", "--notes", str(write(tmp / "notes.json", notes)),
                        "--tree", str(write(tmp / "tree.json", {"tree": []})), "--out", str(tmp / "out"), "--dry-run")
            self.assertEqual(done.returncode, 0, done.stderr)
            report = json.loads((tmp / "out/reel.json").read_text())
        self.assertEqual([(p["pr"], p["title"], p["clip"]) for p in report["prs"]],
                         [(5, "fix: a", "no clip"), (6, "feat: d", "no clip")])


@unittest.skipUnless(HAS_FFMPEG, "needs ffmpeg")
class BuildTests(unittest.TestCase):
    def test_two_clips_an_odd_title_and_a_pr_without_a_clip(self):
        notes = {"build": "100", "items": [{"title": ODD_TITLE, "author": "Ada", "pr": 11},
                                           {"title": "Sidebar <b>quieter</b>", "author": "Cy", "pr": 22},
                                           {"title": "No media here", "author": "Ed", "pr": 33}]}
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            for name in ("a", "b"):
                subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
                                "testsrc=size=320x200:rate=10:duration=1", "-pix_fmt", "yuv420p",
                                str(tmp / f"{name}.mp4")], check=True)
            clips = write(tmp / "clips.json", {"11": str(tmp / "a.mp4"), "22": str(tmp / "b.mp4")})
            out = tmp / "out"
            done = reel("--build", "100", "--notes", str(write(tmp / "notes.json", notes)),
                        "--clips", str(clips), "--out", str(out))
            self.assertEqual(done.returncode, 0, done.stderr)
            self.assertNotIn("blank card", done.stderr)
            # Two 1.5 s cards and two 1 s clips.
            self.assertAlmostEqual(duration(out / "reel.mp4"), 5.0, delta=0.5)
            page = (out / "index.html").read_text()
            report = json.loads((out / "reel.json").read_text())
        for title in (ODD_TITLE, "Sidebar <b>quieter</b>", "No media here"):
            self.assertIn(html.escape(title), page)
        self.assertNotIn("<b>quieter", page)
        self.assertIn(">#33</a></td><td>No media here</td><td>Ed</td><td>no clip</td>", page)
        self.assertEqual(report["reel"], "reel.mp4")
        self.assertEqual([(p["pr"], p["clip"] == "no clip") for p in report["prs"]],
                         [(11, False), (22, False), (33, True)])


class RefusalTests(unittest.TestCase):
    def test_a_bad_signature_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            notes = write(tmp / "100.json", NOTES)
            write(tmp / "100.json.sig", "AAAA\n")
            done = reel("--build", "100", "--notes", str(notes), "--tree", str(write(tmp / "t.json", TREE)),
                        "--out", str(tmp / "out"), "--dry-run")
            self.assertEqual(done.returncode, 1)
            self.assertIn("bad signature", done.stderr)
            self.assertFalse((tmp / "out/reel.json").exists())

    def test_notes_for_another_build_are_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            done = reel("--build", "101", "--notes", str(write(tmp / "n.json", NOTES)),
                        "--tree", str(write(tmp / "t.json", TREE)), "--out", str(tmp / "out"), "--dry-run")
            self.assertEqual(done.returncode, 1)
            self.assertIn("is build 100, not 101", done.stderr)


if __name__ == "__main__":
    unittest.main()
