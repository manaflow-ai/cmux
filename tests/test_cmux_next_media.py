#!/usr/bin/env python3
"""cmux-next tour media: the runner pick, the tour format and the PR comment."""

from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import cmux_next_media_runner as runner  # noqa: E402


def load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


MEDIA = ROOT / "scripts" / "cmux-next" / "media"
tour = load("cmux_next_tour", MEDIA / "tour.py")
publish = load("cmux_next_publish", MEDIA / "publish.py")

SLOTS = json.dumps({"glaeda-std-xcode-26.6": 42, "glaeda-root-std-xcode-26.6": 19,
                    "glaeda-gui-std-xcode-26.6": 10})
XCODE = "/Applications/Xcode_26.6.app"


class RunnerPick(unittest.TestCase):
    def test_a_same_repository_head_takes_the_gui_runner(self) -> None:
        label, reason = runner.pick(same_repo=True, owned="1", owned_slots=SLOTS, pr_xcode_app=XCODE)
        self.assertEqual(label, "glaeda-gui-std-xcode-26.6")
        self.assertIn("10 gui runner", reason)

    def test_never_blacksmith_and_never_a_fork(self) -> None:
        cases = {
            "fork": dict(same_repo=False, owned="1", owned_slots=SLOTS, pr_xcode_app=XCODE),
            "owned off": dict(same_repo=True, owned="0", owned_slots=SLOTS, pr_xcode_app=XCODE),
            "no gui slots": dict(same_repo=True, owned="1", pr_xcode_app=XCODE,
                                 owned_slots=json.dumps({"glaeda-std-xcode-26.6": 42})),
            "other xcode": dict(same_repo=True, owned="1", owned_slots=SLOTS,
                                pr_xcode_app="/Applications/Xcode_26.3.app"),
            "malformed slots": dict(same_repo=True, owned="1", owned_slots="{", pr_xcode_app=XCODE),
        }
        for name, kwargs in cases.items():
            with self.subTest(name):
                label, reason = runner.pick(**kwargs)
                self.assertEqual(label, "")
                self.assertTrue(reason)


class TourFormat(unittest.TestCase):
    def write(self, data) -> Path:
        directory = Path(tempfile.mkdtemp())
        path = directory / "sample.json"
        path.write_text(json.dumps(data), encoding="utf-8")
        return path

    def test_every_checked_in_tour_loads(self) -> None:
        tours = sorted((MEDIA / "tours").glob("*.json"))
        self.assertTrue(tours)
        for path in tours:
            with self.subTest(path.name):
                loaded = tour.load_tour(path)
                self.assertTrue(loaded["steps"])

    def test_bad_steps_are_refused_with_the_step_number(self) -> None:
        bad = {
            "unknown key": {"title": "x", "run": ["a"]},
            "no title": {"cmux": ["a"]},
            "string command": {"title": "x", "cmux": "pane split-right"},
            "daemon without command": {"title": "x", "daemon": True},
            "long wait": {"title": "x", "wait": 120},
            "empty optional": {"title": "x", "optional": ""},
        }
        for name, step in bad.items():
            with self.subTest(name):
                path = self.write({"title": "T", "steps": [{"title": "ok"}, step]})
                with self.assertRaisesRegex(tour.TourError, "step 2"):
                    tour.load_tour(path)

    def test_a_tour_needs_a_title_and_steps(self) -> None:
        for data in ({"steps": [{"title": "x"}]}, {"title": "T", "steps": []}, {"title": "T", "steps": [], "x": 1}):
            with self.subTest(data=data), self.assertRaises(tour.TourError):
                tour.load_tour(self.write(data))

    def test_check_mode_validates_without_an_app(self) -> None:
        self.assertEqual(tour.main(["--check", str(MEDIA / "tours")]), 0)
        self.assertEqual(tour.main(["--check", str(self.write({"title": "T", "steps": [{}]}))]), 2)

    def test_a_tour_fails_only_on_a_required_step(self) -> None:
        manifest = {"steps": [{"status": "ok"}, {"status": "unavailable"}]}
        self.assertTrue(tour.passed(manifest))
        self.assertFalse(tour.passed({"steps": [{"status": "failed"}]}))
        self.assertFalse(tour.passed({"steps": [], "error": "launch: no socket"}))


class CaptureRect(unittest.TestCase):
    def screen(self, width=1920.0, height=1080.0):
        screen = tour.Screen.__new__(tour.Screen)
        screen.rect, screen.primary_width, screen.primary_height = None, width, height
        return screen

    def test_a_window_frame_becomes_a_top_left_rect(self) -> None:
        screen = self.screen()
        screen.follow([100, 200, 800, 600])
        self.assertEqual(screen.rect, (100, 280, 800, 600))

    def test_a_window_partly_off_screen_is_clamped(self) -> None:
        screen = self.screen()
        screen.follow([-50, 900, 400, 300])
        self.assertEqual(screen.rect, (0, 0, 350, 180))
        screen.follow([1800, 0, 400, 300])
        self.assertEqual(screen.rect, (1800, 780, 120, 300))

    def test_a_window_that_leaves_the_display_stops_the_capture(self) -> None:
        screen = self.screen()
        screen.follow([100, 200, 800, 600])
        screen.follow([5000, 200, 800, 600])
        self.assertIsNone(screen.rect)

    def test_a_window_that_disappears_stops_the_capture(self) -> None:
        for gone in (None, [0, 0, 10, 10], [1, 2]):
            with self.subTest(gone=gone):
                screen = self.screen()
                screen.follow([100, 200, 800, 600])
                screen.follow(gone)
                self.assertIsNone(screen.rect)

    def test_no_window_means_no_rect_and_no_shot(self) -> None:
        screen = self.screen()
        screen.follow(None)
        screen.follow([0, 0, 10, 10])
        self.assertIsNone(screen.rect)
        self.assertEqual(screen.capture(Path("/tmp/never.png")), "no app window on screen to capture")


class Bounds(unittest.TestCase):
    def test_the_recorder_stops_at_the_frame_cap(self) -> None:
        with tempfile.TemporaryDirectory() as scratch:
            class Screen:
                def capture(self, path: Path, kind: str) -> None:
                    return None
            recorder = tour.Recorder(Screen(), Path(scratch))
            recorder.frames = [{"file": "x", "step": 0}] * tour.MAX_FRAMES
            recorder.run()
            self.assertEqual(len(recorder.frames), tour.MAX_FRAMES)
            self.assertIn("stops at", recorder.error)

    def test_the_publisher_shares_the_cap(self) -> None:
        self.assertEqual(publish.MAX_FRAMES, tour.MAX_FRAMES)


class FreshState(unittest.TestCase):
    def app(self, tag: str, *, fresh: bool) -> object:
        app = tour.App.__new__(tour.App)
        app.session = type("S", (), {"user": "cmux"})()
        app.bundle_tag = tour.clean_tag(tag)
        app.fresh_state = fresh
        return app

    def test_the_tag_state_directory_matches_the_daemon_launcher(self) -> None:
        directory = self.app("ci-media", fresh=True).state_directory()
        self.assertEqual(directory.parts[-4:], ("cmux", "tags", "ci-media", "tui"))
        self.assertEqual(tour.clean_tag("a/b c."), "a-b-c")

    def test_an_untagged_build_never_loses_its_state(self) -> None:
        app = self.app("", fresh=True)
        self.assertIsNone(app.state_directory())
        app.session.run = lambda argv: self.fail(f"ran {argv}")
        app.clear_state()

    def test_an_untagged_build_never_stops_the_users_daemon(self) -> None:
        app = self.app("", fresh=True)
        app.cli = lambda *a, **k: self.fail(f"ran {a}")
        app.stop_daemon()

    def test_the_tagged_daemon_stops_through_its_session(self) -> None:
        app = self.app("ci-media", fresh=False)
        app.identity = {}
        calls = []
        app.cli = lambda args, **options: calls.append((args, options.get("daemon")))
        app.stop_daemon()
        self.assertEqual(app.daemon_session(), "cmux-app-ci-media")
        self.assertEqual(calls, [(["server", "stop", "--end-terminals"], True)])

    def test_state_is_kept_unless_asked(self) -> None:
        app = self.app("ci-media", fresh=False)
        app.session.run = lambda argv: self.fail(f"ran {argv}")
        app.clear_state()


class Comment(unittest.TestCase):
    MANIFEST = {
        "name": "core", "title": "Core UI",
        "steps": [
            {"index": 1, "title": "Launch", "status": "ok", "shot": "shots/01-launch.png"},
            {"index": 2, "title": "Split | right", "status": "failed", "detail": "exited 2",
             "command": "cmux pane split-right", "shot": "shots/02-split-right-failed.png"},
            {"index": 3, "title": "Agent chat", "status": "unavailable",
             "detail": "exited 1 (agent chat views are not ported yet)"},
        ],
    }
    URLS = {"shots/01-launch.png": "https://raw/01.png", "shots/02-split-right-failed.png": "https://raw/02.png",
            "tour.gif": "https://raw/tour.gif", "tour.mp4": "https://raw/tour.mp4"}

    def test_failed_steps_show_inline_and_the_rest_fold(self) -> None:
        section = publish.tour_section(self.MANIFEST, self.URLS)
        self.assertIn("### Core UI: 1 ok, 1 failed, 1 unavailable", section)
        failed, _, folded = section.partition("<details>")
        self.assertIn("https://raw/02.png", failed)
        self.assertNotIn("https://raw/01.png", failed)
        self.assertIn("https://raw/01.png", folded)
        self.assertIn("Split \\| right", section)
        self.assertIn("[Video (mp4)](https://raw/tour.mp4)", section)

    def test_the_comment_carries_the_marker_and_a_note(self) -> None:
        body = publish.render("a" * 40, [], "https://run", "The tour did not run: owned Macs are off.")
        self.assertTrue(body.startswith(publish.COMMENT_MARKER))
        self.assertIn("The tour did not run", body)
        self.assertIn(publish.TOURS_DIR, body)

    def test_dry_run_renders_from_tour_output(self) -> None:
        media = Path(tempfile.mkdtemp())
        (media / "core" / "shots").mkdir(parents=True)
        (media / "core" / "shots" / "01-launch.png").write_bytes(b"\x89PNG\r\n\x1a\n")
        (media / "core" / "manifest.json").write_text(json.dumps(self.MANIFEST), encoding="utf-8")
        self.assertEqual(publish.main(["--media", str(media), "--pr", "1", "--sha", "b" * 40, "--dry-run"]), 0)


class ArtifactIsData(unittest.TestCase):
    """The tour artifact comes from a job that ran the pull request's code."""

    def tour(self, manifest, name="core") -> Path:
        media = Path(tempfile.mkdtemp())
        (media / name / "shots").mkdir(parents=True)
        (media / name / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
        return media

    def test_only_shot_paths_tour_py_writes_are_uploaded(self) -> None:
        media = self.tour({"steps": []})
        directory = media / "core"
        (directory / "shots" / "01-launch.png").write_bytes(b"x")
        (directory / "secret.png").write_bytes(b"x")
        os.symlink("/etc/hosts", directory / "shots" / "02-link.png")
        self.assertEqual(publish.shot_file(directory, "shots/01-launch.png"), directory / "shots/01-launch.png")
        for bad in ("../core/shots/01-launch.png", "secret.png", "shots/02-link.png", "/etc/hosts",
                    "shots/../../x.png", ["shots/01-launch.png"], None):
            with self.subTest(bad=bad):
                self.assertIsNone(publish.shot_file(directory, bad))

    def test_folders_that_are_not_tour_slugs_are_skipped(self) -> None:
        self.assertEqual(publish.manifests(self.tour({"steps": []}, name="Bad Name")), [])
        self.assertEqual(len(publish.manifests(self.tour({"steps": [1, {"title": "x"}]}))), 1)
        self.assertEqual(publish.manifests(self.tour(["not", "an", "object"])), [])

    def test_manifest_text_is_escaped(self) -> None:
        section = publish.tour_section({"title": "<img src=x>", "steps": [
            {"index": 1, "title": "<script>", "status": "ok", "shot": ["odd"]}]}, {})
        self.assertNotIn("<script>", section)
        self.assertNotIn("<img src=x>", section)

    def test_markdown_mentions_and_code_spans_are_inert(self) -> None:
        media = self.tour({"title": "T", "steps": [
            {"index": 1, "title": "![x](https://tracker) @manaflow-ai/everyone", "status": "ok",
             "command": "cmux `rm` [a](b)"}]})
        (directory, manifest), = publish.manifests(media)
        section = publish.tour_section(manifest, {})
        self.assertNotIn("![x](", section)
        self.assertNotIn("@manaflow-ai", section)
        self.assertEqual(section.count("`"), 2)

    def test_a_newline_cannot_end_the_code_span_or_the_row(self) -> None:
        for newline in ("\n\n", "\r\r", "\r\n\r\n"):
            with self.subTest(newline=repr(newline)):
                media = self.tour({"title": "T", "steps": [
                    {"index": 1, "title": f"a{newline}@manaflow-ai/everyone", "status": "ok",
                     "command": f"x{newline}@manaflow-ai/everyone ![a](https://tracker.example/p.png)"}]})
                (directory, manifest), = publish.manifests(media)
                row = publish.step_row(manifest["steps"][0])
                self.assertNotIn("\n", row)
                self.assertNotIn("\r", row)
                self.assertNotIn("@manaflow-ai", row.replace("`x @manaflow-ai", ""))

    def test_malformed_step_values_do_not_crash_the_comment(self) -> None:
        media = self.tour({"title": ["x"], "error": {"a": 1}, "frames": "nope", "steps": [
            {"index": "1", "title": 5, "status": ["ok"], "detail": 7, "command": 3, "shot": 9},
            {"index": True, "status": "weird"}]})
        (directory, manifest), = publish.manifests(media)
        self.assertEqual([step["status"] for step in manifest["steps"]], ["failed", "failed"])
        self.assertEqual(manifest["frames"], [])
        self.assertIn("2 failed", publish.tour_section(manifest, {}))

    def test_no_capture_is_explained(self) -> None:
        section = publish.tour_section({"title": "T", "capture_mode": "none (direct: no permission)",
                                        "steps": [{"index": 1, "title": "Launch", "status": "ok"}]}, {})
        self.assertIn("screen capture is unavailable on this runner", section)


if __name__ == "__main__":
    unittest.main()
