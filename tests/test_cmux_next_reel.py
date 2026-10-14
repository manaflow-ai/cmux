#!/usr/bin/env python3
"""scripts/cmux-next/media/reel.py: pull requests come from the notes once each, clips are
picked from the pr-media listing, title cards keep odd titles literal, and a build joins
the clips into one reel with a page listing every pull request."""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("cmux_next_reel", ROOT / "scripts/cmux-next/media/reel.py")
reel = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = reel
SPEC.loader.exec_module(reel)

HAS_FFMPEG = bool(shutil.which("ffmpeg") and shutil.which("ffprobe"))
NOTES = {
    "version": 1, "build": "100", "items": [
        {"title": "Tabs keep their order", "author": "Ada", "pr": 11},
        {"title": "Unrelated commit", "author": "Bob"},
        {"title": "Tabs keep their order, part two", "author": "Ada", "pr": 11},
        {"title": "Sidebar: quieter", "author": "Cy", "pr": 22},
        {"title": "No media here", "author": "Di", "pr": 33},
    ],
}


def tree(*paths: str) -> dict:
    return {"truncated": False, "tree": [{"path": p, "type": "blob"} for p in paths]}


def quiet(function, *args):
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        return function(*args)


class NotesTests(unittest.TestCase):
    def test_each_pr_once_in_notes_order_with_its_first_title(self):
        self.assertEqual(reel.notes_prs(NOTES), [
            {"pr": 11, "title": "Tabs keep their order", "author": "Ada"},
            {"pr": 22, "title": "Sidebar: quieter", "author": "Cy"},
            {"pr": 33, "title": "No media here", "author": "Di"},
        ])

    def test_notes_without_items_read_the_pr_suffix_of_each_change(self):
        prs = reel.notes_prs({"changes": ["fix: a (#5)", "chore: b", "fix: c (#5)", "feat: d (#6)"]})
        self.assertEqual([p["pr"] for p in prs], [5, 6])

    def test_a_pr_that_is_not_a_positive_int_is_skipped(self):
        prs = reel.notes_prs({"items": [{"pr": "7"}, {"pr": True}, {"pr": 0}, {"pr": 8}, "x"]})
        self.assertEqual([p["pr"] for p in prs], [8])


class PickClipTests(unittest.TestCase):
    def test_the_capture_at_the_current_head_wins(self):
        paths = ["11/aaaaaaaa/next-core-after/tour.mp4", "11/bbbbbbbb/next-core-after/tour.mp4",
                 "11/aaaaaaaa/next-core-before/tour.mp4"]
        clip = reel.pick_clip(11, paths, "aaaaaaaa" + "0" * 32)
        self.assertEqual(clip["path"], "11/aaaaaaaa/next-core-after/tour.mp4")
        self.assertEqual(clip["note"], "")

    def test_without_a_head_the_pick_is_deterministic_and_says_so(self):
        paths = ["11/bbbbbbbb/next-core-after/tour.mp4", "11/aaaaaaaa/next-core-after/tour.mp4"]
        clip = reel.pick_clip(11, paths, None)
        self.assertEqual(clip["sha8"], "bbbbbbbb")
        self.assertIn("head unknown", clip["note"])

    def test_tours_follow_capture_paths_order(self):
        paths = ["11/aaaaaaaa/next-core-after/tour.mp4", "11/aaaaaaaa/next-new-tab-after/tour.mp4"]
        self.assertEqual(reel.pick_clip(11, paths, None)["tour"], "new-tab")

    def test_a_before_clip_is_never_the_reel_clip(self):
        clip = reel.pick_clip(11, ["11/aaaaaaaa/next-core-before/tour.mp4", "11/x-before-after.mp4"], None)
        self.assertEqual((clip["source"], clip["path"]), ("manual", "11/x-before-after.mp4"))

    def test_a_hand_posted_clip_is_only_a_fallback(self):
        paths = ["20365/20365-cold-before-after.mp4", "20365/aaaaaaaa/next-core-after/tour.mp4"]
        self.assertEqual(reel.pick_clip(20365, paths, None)["source"], "tour-after")
        self.assertEqual(reel.pick_clip(20365, paths[:1], None)["path"], "20365/20365-cold-before-after.mp4")

    def test_a_pr_without_media_has_no_clip(self):
        self.assertIsNone(reel.pick_clip(33, ["11/aaaaaaaa/next-core-after/tour.mp4", "33/notes.txt"], None))

    def test_discover_reads_one_listing_and_builds_raw_urls(self):
        with tempfile.TemporaryDirectory() as tmp:
            listing = Path(tmp) / "tree.json"
            listing.write_text(json.dumps(tree("11/aaaaaaaa/next-core-after/tour.mp4", "22/manual clip.mp4",
                                               "22/demo.mp4", "99/aaaaaaaa/next-core-after/tour.mp4")))
            args = reel.argparse.Namespace(tree=listing, heads=None, repo="manaflow-ai/cmux")
            clips, truncated = reel.discover(args, reel.notes_prs(NOTES))
        self.assertFalse(truncated)
        self.assertEqual(sorted(clips), [11, 22])
        self.assertEqual(clips[11]["url"], "https://raw.githubusercontent.com/manaflow-ai/cmux/pr-media/"
                                           "11/aaaaaaaa/next-core-after/tour.mp4")
        self.assertEqual(clips[22]["path"], "22/demo.mp4")


class TitleCardTests(unittest.TestCase):
    def test_control_characters_go_and_long_titles_are_cut_at_a_word(self):
        self.assertEqual(reel.card_text(5, "a\nb\tc"), "#5  a b c")
        long = reel.card_text(5, "word " * 30)
        self.assertTrue(long.endswith("…"))
        self.assertLessEqual(len(long), len("#5  ") + reel.TITLE_MAX)
        self.assertEqual(reel.card_text(5, ""), "#5")

    @unittest.skipUnless(HAS_FFMPEG, "needs ffmpeg")
    def test_filter_syntax_in_a_title_stays_literal(self):
        title = "it's 100%{pts} : a, b; [c] \\ d"
        with tempfile.TemporaryDirectory() as tmp:
            card = quiet(reel.make_card, 7, title, Path(tmp))
            self.assertTrue(card.is_file())
            self.assertEqual((Path(tmp) / "card-7.txt").read_text(), f"#7  {title}")
            self.assertAlmostEqual(duration(card), reel.CARD_SECONDS, delta=0.3)


def duration(path: Path) -> float:
    return float(subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0",
                                 str(path)], capture_output=True, text=True, check=True).stdout)


@unittest.skipUnless(HAS_FFMPEG, "needs ffmpeg")
class BuildTests(unittest.TestCase):
    def test_two_clips_and_a_pr_without_one(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            for name in ("a", "b"):
                subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
                                "testsrc=size=320x200:rate=10:duration=1", "-pix_fmt", "yuv420p", str(tmp / f"{name}.mp4")],
                               check=True)
            (tmp / "notes.json").write_text(json.dumps(NOTES))
            (tmp / "clips.json").write_text(json.dumps({"11": str(tmp / "a.mp4"), "22": str(tmp / "b.mp4")}))
            out = tmp / "out"
            quiet(reel.main, ["--build", "100", "--notes", str(tmp / "notes.json"), "--clips",
                              str(tmp / "clips.json"), "--out", str(out)])
            self.assertAlmostEqual(duration(out / "reel.mp4"), 2 * (reel.CARD_SECONDS + 1), delta=0.5)
            page = (out / "index.html").read_text()
            for text in ("#11", "#22", "#33", "Sidebar: quieter", "no clip"):
                self.assertIn(text, page)
            report = json.loads((out / "reel.json").read_text())
            self.assertEqual([(p["pr"], p["clip"] == "no clip") for p in report["prs"]],
                             [(11, False), (22, False), (33, True)])
            self.assertEqual(report["reel"], "reel.mp4")

    def test_dry_run_writes_only_the_plan(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            (tmp / "notes.json").write_text(json.dumps(NOTES))
            (tmp / "tree.json").write_text(json.dumps(tree("22/aaaaaaaa/next-core-after/tour.mp4")))
            quiet(reel.main, ["--build", "100", "--notes", str(tmp / "notes.json"), "--tree", str(tmp / "tree.json"),
                              "--out", str(tmp / "out"), "--dry-run"])
            self.assertEqual(sorted(p.name for p in (tmp / "out").iterdir()), ["reel.json"])
            report = json.loads((tmp / "out/reel.json").read_text())
            self.assertEqual([p["clip"] == "no clip" for p in report["prs"]], [True, False, True])


class SignatureTests(unittest.TestCase):
    def test_a_local_notes_file_with_a_bad_signature_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            notes = Path(tmp) / "100.json"
            notes.write_text(json.dumps(NOTES))
            Path(f"{notes}.sig").write_text("AAAA\n")
            with self.assertRaises(SystemExit):
                quiet(reel.main, ["--build", "100", "--notes", str(notes), "--clips", str(notes),
                                  "--out", str(Path(tmp) / "out"), "--dry-run"])

    def test_notes_for_another_build_are_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            notes = Path(tmp) / "n.json"
            notes.write_text(json.dumps(NOTES))
            with self.assertRaises(SystemExit):
                quiet(reel.main, ["--build", "101", "--notes", str(notes), "--out", str(Path(tmp) / "o"), "--dry-run"])


if __name__ == "__main__":
    unittest.main()
