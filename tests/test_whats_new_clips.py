#!/usr/bin/env python3
"""scripts/cmux-next/media/whats-new-clips.py: specs, cutting a capture to its clip steps, the
idle-clip refusal, the clip's length, and the highlight's clip line. Encoding (ffmpeg, img2webp)
and the fleet capture are not run here."""
import importlib.util, json, sys, tempfile, unittest
from pathlib import Path
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/cmux-next/media/whats-new-clips.py"
spec = importlib.util.spec_from_file_location("whats_new_clips", SCRIPT)
clips = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = clips
spec.loader.exec_module(clips)

SPEC = {
    "caption": "Right-click a workspace and archive it.",
    "frameInterval": 0.25,
    "steps": [{"title": "Scene", "wait": 1}, {"title": "Archive", "wait": 1, "clip": True}, {"title": "End"}],
    "crop": [0, 0, 0.3, 0.6],
}
SHA = "b" * 64
URL = clips.URL_PREFIX + "sidebar-archive/0123456789ab.webp"


class SpecTests(unittest.TestCase):
    def test_a_good_spec_has_no_problems(self):
        self.assertEqual(clips.spec_problems(SPEC), [])

    def test_bad_specs_say_why(self):
        cases = {
            "caption": {**SPEC, "caption": ""},
            "clip": {**SPEC, "steps": [{"title": "Scene"}]},
            "not the whole window": {**SPEC, "crop": [0, 0, 1, 1]},
            "inside the window": {**SPEC, "crop": [0.5, 0, 0.6, 0.5]},
            "frameInterval": {**SPEC, "frameInterval": 2},
            "unknown key": {**SPEC, "speed": 2},
        }
        for words, bad in cases.items():
            self.assertTrue(any(words in p for p in clips.spec_problems(bad)), words)

    def test_the_capture_state_drops_the_clip_marks(self):
        state = clips.capture_state({**SPEC, "settings": {"a": 1}})
        self.assertEqual(state["frameInterval"], 0.25)
        self.assertEqual(state["settings"], {"a": 1})
        self.assertNotIn("clip", json.dumps(state["steps"]))
        self.assertNotIn("caption", state)


class CutTests(unittest.TestCase):
    frames = [Path(f"frames/frame-{i:05d}.png") for i in range(20)]

    def result(self, *starts, stills=18):
        return {"steps": [{"title": s["title"], "status": "ok", "frame": f} for s, f in zip(SPEC["steps"], starts)],
                "stillsFrame": stills}

    def test_the_clip_runs_from_its_first_step_to_the_step_after_its_last(self):
        picked = clips.clip_frames(SPEC, self.result(0, 6, 14), self.frames)
        self.assertEqual([clips.frame_number(f) for f in picked], list(range(5, 14)))  # and the frame before

    def test_a_last_clip_step_runs_to_the_stills(self):
        spec = {**SPEC, "steps": SPEC["steps"][:2]}
        picked = clips.clip_frames(spec, {**self.result(0, 6), "steps": self.result(0, 6)["steps"][:2]}, self.frames)
        self.assertEqual(clips.frame_number(picked[-1]), 17)

    def test_a_capture_without_step_frames_or_with_a_failed_step_is_refused(self):
        with self.assertRaisesRegex(clips.ClipError, "no frame per step"):
            clips.clip_frames(SPEC, {"steps": [{"title": "x", "status": "ok"}] * 3}, self.frames)
        failed = self.result(0, 6, 14)
        failed["steps"][1]["status"] = "failed"
        with self.assertRaisesRegex(clips.ClipError, "steps failed: Archive"):
            clips.clip_frames(SPEC, failed, self.frames)
        failed["steps"][1]["status"] = "unavailable"
        with self.assertRaisesRegex(clips.ClipError, "steps failed: Archive"):
            clips.clip_frames(SPEC, failed, self.frames)
        failed["steps"][1]["status"] = "ok"
        failed["steps"][0]["status"] = "unavailable"  # an optional scene step
        self.assertTrue(clips.clip_frames(SPEC, failed, self.frames))


class TimelineTests(unittest.TestCase):
    def plan(self, pixels, spec=SPEC):
        frames = [Path(f"f{i}.png") for i in range(len(pixels))]
        with mock.patch.object(clips, "gray", side_effect=lambda f, _crop: pixels[int(f.stem[1:])]):
            return clips.timeline(spec, frames, "crop")

    def test_alike_frames_merge_and_the_ends_are_held(self):
        a, b = bytes([10] * 64), bytes([200] * 64)
        plan = self.plan([a, a, b, b, b])
        self.assertEqual([seconds for _, seconds in plan], [0.6, 2.4])  # lead 0.6; hold 1.2, then filled to 3 s
        self.assertGreaterEqual(sum(s for _, s in plan), clips.MIN_SECONDS)

    def test_a_frame_caught_mid_animation_is_folded_into_the_settled_state(self):
        a, mid, b = bytes([10] * 64), bytes([100] * 64), bytes([200] * 64)
        plan = self.plan([a, a, a, mid, b, b, b, b])
        self.assertEqual([f.stem for f, _ in plan], ["f0", "f4"])
        self.assertEqual(plan[0][1], 0.75)
        self.assertEqual(plan[1][1], 2.25)  # the mid frame's 0.25 s, then held to fill 3 s

    def test_a_clip_that_never_changes_is_refused(self):
        with self.assertRaisesRegex(clips.ClipError, "idle"):
            self.plan([bytes([10] * 64)] * 8)

    def test_a_clip_past_eight_seconds_is_refused(self):
        frames = [bytes([i * 7 % 256] * 64) for i in range(40)]
        with self.assertRaisesRegex(clips.ClipError, "at most 8"):
            self.plan(frames)


class HighlightTests(unittest.TestCase):
    def test_the_clip_line_goes_in_the_front_matter_once(self):
        text = "title: T\ncategory: new\nclip: old\n\nBody.\n\nMore.\n"
        self.assertEqual(clips.set_clip_line(text, f"clip: {URL} | {SHA}"),
                         f"title: T\ncategory: new\nclip: {URL} | {SHA}\n\nBody.\n\nMore.\n")

    def test_check_wants_a_spec_for_each_clip_and_a_highlight_for_each_spec(self):
        with tempfile.TemporaryDirectory() as tmp:
            specs, highlights = Path(tmp, "clips"), Path(tmp, "highlights")
            specs.mkdir()
            highlights.mkdir()
            (highlights / "sidebar-archive.md").write_text(f"title: T\nclip: {URL} | {SHA}\n\nBody.\n")
            self.assertTrue(any("needs its spec" in p for p in clips.check(specs, highlights)))
            (specs / "sidebar-archive.json").write_text(json.dumps(SPEC))
            self.assertEqual(clips.check(specs, highlights), [])
            (specs / "gone.json").write_text(json.dumps(SPEC))
            self.assertTrue(any("no highlight gone.md" in p for p in clips.check(specs, highlights)))
            (highlights / "other.md").write_text(f"title: T\nclip: {URL} | {SHA}\n\nBody.\n")
            self.assertTrue(any("lives at" in p for p in clips.check(specs, highlights)))
            (highlights / "other.md").unlink()
            (highlights / "sidebar-archive.md").write_text(f"title: T\nclip: {URL}?x=1 | {SHA}\n\nBody.\n")
            self.assertTrue(any("lives at" in p for p in clips.check(specs, highlights)))  # release-notes.py drops it

    def test_publish_wants_ocr_and_uploads_nothing_without_it(self):
        with tempfile.TemporaryDirectory() as tmp:
            highlights = Path(tmp)
            (highlights / "sidebar-archive.md").write_text("title: T\n\nBody.\n")
            clip = Path(tmp, "clip.webp")
            clip.write_bytes(b"RIFF\0\0\0\0WEBPVP8 ")
            with mock.patch.object(clips, "load_spec"), mock.patch.dict("os.environ", {"PR_MEDIA_PRIVACY_OCR": "none"}):
                with self.assertRaisesRegex(clips.ClipError, "Apple Vision"):
                    clips.publish("sidebar-archive", clip, highlights)
            self.assertNotIn("clip:", (highlights / "sidebar-archive.md").read_text())


def git(repo, *args):
    import subprocess
    return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, check=True).stdout.strip()


class NightlyTourTests(unittest.TestCase):
    """What the nightly media tour records: the plan, a spec as a tour, the clip cut out of a tour folder."""

    def test_a_spec_becomes_a_tour_with_its_steps_in_order_and_no_shots(self):
        tour = clips.tour_from_spec({**SPEC, "launch_args": ["--showcase"], "settings": {"a": 1},
                                     "steps": [*SPEC["steps"][:1], {"title": "Rec", "record": True}, *SPEC["steps"][1:]]},
                                    "Archive")
        self.assertEqual([s["title"] for s in tour["steps"]], ["Scene", "Rec", "Archive", "End"])
        self.assertTrue(all(s["shot"] is False and "clip" not in s and "record" not in s for s in tour["steps"]))
        self.assertEqual((tour["title"], tour["launch_args"], tour["settings"]), ("Archive", ["--showcase"], {"a": 1}))
        self.assertNotIn("caption", tour)

    def test_every_spec_in_the_repo_is_a_tour_tour_py_runs(self):
        validate = clips.tour_module().load_tour
        with tempfile.TemporaryDirectory() as tmp:
            for path in sorted(clips.SPECS.glob("*.json")):
                with self.subTest(spec=path.stem):
                    tour = Path(tmp, path.name)
                    tour.write_text(json.dumps(clips.tour_from_spec(clips.load_spec(path.stem), "T")))
                    self.assertEqual(len(validate(tour)["steps"]), len(json.loads(path.read_text())["steps"]))

    def test_tour_py_refuses_launch_args_that_are_not_strings(self):
        with tempfile.TemporaryDirectory() as tmp:
            tour = Path(tmp, "t.json")
            tour.write_text(json.dumps({"title": "T", "steps": [{"title": "S"}], "launch_args": "--showcase"}))
            with self.assertRaisesRegex(Exception, "launch_args"):
                clips.tour_module().load_tour(tour)

    def repo(self, tmp):
        repo = Path(tmp, "repo")
        (repo / "release-notes/next/highlights").mkdir(parents=True)
        (repo / "release-notes/next/clips").mkdir(parents=True)
        git(repo, "init", "-q")
        git(repo, "config", "user.email", "t@example.com")
        git(repo, "config", "user.name", "t")
        (repo / "release-notes/next/highlights/old.md").write_text("title: Old\ncategory: new\n\nBody.\n")
        (repo / "release-notes/next/clips/old.json").write_text(json.dumps(SPEC))
        git(repo, "add", ".")
        git(repo, "commit", "-q", "-m", "base")
        base = git(repo, "rev-parse", "HEAD")
        notes = repo / "release-notes/next"
        for name, head in {"archive": "category: new", "better": "category: improved", "fixed": "category: fixed",
                           "has-clip": f"category: new\nclip: {URL} | {SHA}", "no-spec": "category: new",
                           "uncategorized": ""}.items():
            (notes / f"highlights/{name}.md").write_text(f"title: {name.title()}\n{head}\n\nBody.\n".replace("\n\n\n", "\n\n"))
            if name != "no-spec":
                (notes / f"clips/{name}.json").write_text(json.dumps(SPEC))
        git(repo, "add", ".")
        git(repo, "commit", "-q", "-m", "head")
        return repo, base, git(repo, "rev-parse", "HEAD")

    def test_the_plan_takes_the_tips_new_and_improved_highlights_with_a_spec_and_no_clip(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo, base, head = self.repo(tmp)
            tours = Path(tmp, "tours")
            with mock.patch.object(clips, "SPECS", repo / "release-notes/next/clips"):
                rows = clips.plan(base, head, tours, exists=lambda url: False, root=repo)
                self.assertEqual([(r["id"], r["roles"]) for r in rows],
                                 [("archive", ["after"]), ("better", ["after", "before"]), ("uncategorized", ["after"])])
                self.assertEqual(sorted(p.stem for p in tours.glob("*.json")), ["archive", "better", "uncategorized"])
                self.assertEqual(json.loads((tours / "better.json").read_text())["title"], "Better")
                published = lambda url: url == clips.auto_url("better", "after")
                self.assertEqual([(r["id"], r["roles"]) for r in clips.plan(base, head, tours, exists=published, root=repo)],
                                 [("archive", ["after"]), ("better", ["before"]), ("uncategorized", ["after"])])
                with mock.patch("sys.stdout"):  # its "more wait" notice
                    self.assertEqual(len(clips.plan(base, head, tours, limit=1, exists=lambda url: False, root=repo)), 1)

    def manifest(self, *ats, video=True, statuses=None):
        steps = [{"index": i + 1, "title": s["title"], "status": (statuses or {}).get(i, "ok"), "at": at}
                 for i, (s, at) in enumerate(zip(SPEC["steps"], ats))]
        return {"steps": steps, "video": "capture.mov"} if video else {"steps": steps, "frames": []}

    def test_a_video_tour_is_cut_from_the_frame_before_the_clip_to_the_step_after_it(self):
        calls = []

        def fake_run(argv, **kw):
            calls.append(argv)
            out = Path(argv[-1]).parent
            for i in range(3):
                (out / f"frame-{i:05d}.png").write_bytes(b"x")
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(clips, "run", fake_run):
            frames = clips.tour_frames(SPEC, self.manifest(0.0, 2.0, 3.5), Path("/tour"), Path(tmp))
        argv = calls[0]
        self.assertEqual(argv[argv.index("-ss") + 1], "1.750")
        self.assertEqual(argv[argv.index("-t") + 1], "1.750")
        self.assertEqual(argv[argv.index("-i") + 1], "/tour/capture.mov")
        self.assertIn("fps=1/0.25", argv)
        self.assertEqual(len(frames), 3)

    def test_still_frames_of_the_clip_steps_and_the_one_before_are_kept_at_the_spec_pace(self):
        manifest = self.manifest(0.0, 2.0, 3.5, video=False)
        manifest["frames"] = [{"file": f"frames/frame-{i:05d}.jpg", "step": step, "time": i * 0.1}
                              for i, step in enumerate([1, 1, 2, 2, 2, 2, 2, 2, 3])]
        frames = clips.tour_frames(SPEC, manifest, Path("/tour"), Path("/unused"))
        self.assertEqual([f.name for f in frames], ["frame-00001.jpg", "frame-00004.jpg", "frame-00007.jpg"])

    def test_a_tour_with_a_failed_clip_step_or_no_step_times_is_refused(self):
        with self.assertRaisesRegex(clips.ClipError, "steps failed: Archive"):
            clips.tour_frames(SPEC, self.manifest(0, 1, 2, statuses={1: "unavailable"}), Path("/t"), Path("/u"))
        no_times = self.manifest(0, 1, 2)
        for step in no_times["steps"]:
            del step["at"]
        with self.assertRaisesRegex(clips.ClipError, "no times"):
            clips.tour_frames(SPEC, no_times, Path("/t"), Path("/u"))
        with self.assertRaisesRegex(clips.ClipError, "did not run every step"):
            clips.tour_frames(SPEC, {"steps": [], "error": "launch: no app"}, Path("/t"), Path("/u"))

    def test_publish_auto_renders_each_role_from_its_tour_folder_and_uploads_nothing_without_ocr(self):
        rendered = []
        with tempfile.TemporaryDirectory() as tmp, \
                mock.patch.object(clips, "render_tour", lambda i, d, out: rendered.append((i, d.parent.name, d.name))), \
                mock.patch.dict("os.environ", {"PR_MEDIA_PRIVACY_OCR": "none"}):
            with self.assertRaisesRegex(clips.ClipError, "no OCR"):
                clips.publish_auto([{"id": "better", "roles": ["after", "before"]}], Path(tmp), Path(tmp))
        self.assertEqual(rendered, [("better", "after", "better"), ("better", "before", "better")])


if __name__ == "__main__":
    unittest.main()
