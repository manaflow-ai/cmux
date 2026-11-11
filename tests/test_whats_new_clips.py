#!/usr/bin/env python3
"""scripts/cmux-next/media/whats-new-clips.py: specs, cutting a capture to its clip steps, the
idle-clip refusal, the clip's length, and the highlight's clip line. Encoding (ffmpeg, img2webp)
and the fleet capture are not run here."""
import importlib.util, io, json, sys, tempfile, unittest
from pathlib import Path
from unittest import mock
# tests/git_fixture_env.py, loaded by path: `python3 -I` puts no script folder on sys.path.
import importlib.util as _git_fixture_importlib  # noqa: E402
from os import path as _git_fixture_path  # noqa: E402
_git_fixture_spec = _git_fixture_importlib.spec_from_file_location(
    "git_fixture_env", _git_fixture_path.join(_git_fixture_path.dirname(_git_fixture_path.abspath(__file__)), "git_fixture_env.py"))
git_fixture_env = _git_fixture_importlib.module_from_spec(_git_fixture_spec)
_git_fixture_spec.loader.exec_module(git_fixture_env)

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

    def commit(self, repo, message, when, files):
        """Commits FILES ({relative path: text}) at WHEN (seconds since the epoch); returns the commit."""
        import os
        for name, text in files.items():
            (repo / name).parent.mkdir(parents=True, exist_ok=True)
            (repo / name).write_text(text)
        git(repo, "add", "-A")
        env = {**os.environ, "GIT_AUTHOR_DATE": f"@{when} +0000", "GIT_COMMITTER_DATE": f"@{when} +0000"}
        import subprocess
        subprocess.run(["git", "-C", str(repo), "commit", "-q", "--allow-empty", "-m", message],
                       capture_output=True, check=True, env=env)
        return git(repo, "rev-parse", "HEAD")

    def history(self, tmp):
        repo = Path(tmp, "hist")
        repo.mkdir()
        git(repo, "init", "-q")
        git(repo, "config", "user.email", "t@example.com")
        git(repo, "config", "user.name", "t")
        return repo

    @staticmethod
    def highlight(name, category="new"):
        return {f"release-notes/next/highlights/{name}.md": f"title: {name.title()}\ncategory: {category}\n\nBody.\n",
                f"release-notes/next/clips/{name}.json": json.dumps(SPEC)}

    def test_highlights_past_the_limit_are_planned_by_the_next_nightly(self):
        # Five eligible highlights in one tip: the tour records four, and the next tip, which adds none,
        # records the fifth (a plan of only the tip's own adds dropped it for good).
        day = 86400
        with tempfile.TemporaryDirectory() as tmp:
            repo = self.history(tmp)
            t0 = 1_800_000_000
            previous = self.commit(repo, "root", t0, {"README": "r\n"})
            files = {}
            for name in ("a1", "a2", "a3", "a4", "a5"):
                files.update(self.highlight(name))
            tip = self.commit(repo, "five highlights", t0 + day, files)
            published = set()
            exists = lambda url: url in published
            with mock.patch("sys.stdout"):
                first = clips.plan(previous, tip, Path(tmp, "t1"), limit=4, exists=exists, root=repo)
            self.assertEqual([r["id"] for r in first], ["a1", "a2", "a3", "a4"])
            published |= {clips.auto_url(r["id"], "after") for r in first}
            next_tip = self.commit(repo, "unrelated", t0 + 2 * day, {"README": "r2\n"})
            second = clips.plan(tip, next_tip, Path(tmp, "t2"), limit=4, exists=exists, root=repo)
            self.assertEqual([r["id"] for r in second], ["a5"])
            published.add(clips.auto_url("a5", "after"))
            self.assertEqual(clips.plan(next_tip, self.commit(repo, "more", t0 + 3 * day, {"README": "r3\n"}),
                                        Path(tmp, "t3"), exists=exists, root=repo), [])

    def test_an_earlier_improvement_records_its_before_on_the_commit_before_its_highlight(self):
        day = 86400
        with tempfile.TemporaryDirectory() as tmp:
            repo = self.history(tmp)
            t0 = 1_800_000_000
            root = self.commit(repo, "root", t0, {"README": "r\n"})
            better = self.commit(repo, "better", t0 + day, self.highlight("better", "improved"))
            other = self.commit(repo, "other", t0 + day + 60, {"README": "o\n"})
            later = self.commit(repo, "later", t0 + day + 120, self.highlight("later", "improved"))
            previous = self.commit(repo, "previous tip", t0 + day + 180, {"README": "p\n"})
            tip = self.commit(repo, "tip", t0 + 2 * day, self.highlight("fresh", "improved"))
            rows = clips.plan(previous, tip, Path(tmp, "t"), exists=lambda url: False, root=repo)
            # The tip's own one first, before on the previous tip; then the earlier ones, oldest first, each
            # on its own commit's parent, with one extra before app a tour: `later` waits for its before.
            self.assertEqual([(r["id"], r["roles"], r.get("before")) for r in rows],
                             [("fresh", ["after", "before"], previous),
                              ("better", ["after", "before"], root),
                              ("later", ["after"], None)])
            self.assertNotEqual(other, better)
            done = {clips.auto_url(i, "after") for i in ("fresh", "better", "later")} | {
                clips.auto_url(i, "before") for i in ("fresh", "better")}
            again = clips.plan(tip, self.commit(repo, "next", t0 + 3 * day, {"README": "n\n"}), Path(tmp, "t2"),
                               exists=lambda url: url in done, root=repo)
            self.assertEqual([(r["id"], r["roles"], r.get("before")) for r in again], [("later", ["before"], other)])

    def test_a_spec_added_after_its_highlight_shipped_is_planned(self):
        day = 86400
        with tempfile.TemporaryDirectory() as tmp:
            repo = self.history(tmp)
            t0 = 1_800_000_000
            self.commit(repo, "root", t0, {"README": "r\n"})
            shipped = self.commit(repo, "highlight, no spec", t0 + day, {
                "release-notes/next/highlights/drag.md": "title: Drag\ncategory: new\n\nBody.\n"})
            self.assertEqual(clips.plan("HEAD~1", shipped, Path(tmp, "t0"), exists=lambda url: False, root=repo), [])
            tip = self.commit(repo, "its spec", t0 + 2 * day, {"release-notes/next/clips/drag.json": json.dumps(SPEC)})
            rows = clips.plan(shipped, tip, Path(tmp, "t"), exists=lambda url: False, root=repo)
            self.assertEqual([(r["id"], r["roles"]) for r in rows], [("drag", ["after"])])
            # Past the window it is not reconsidered.
            late = self.commit(repo, "late", t0 + day + (clips.CLIP_REANNOUNCE_DAYS + 1) * day, {"README": "l\n"})
            self.assertEqual(clips.plan(tip, late, Path(tmp, "t2"), exists=lambda url: False, root=repo), [])

    def test_write_tours_makes_the_route_jobs_plan_into_tours_and_drops_a_row_with_no_spec(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for name, spec in {"drag": SPEC, "gone": None}.items():
                (root / "release-notes/next/highlights").mkdir(parents=True, exist_ok=True)
                (root / f"release-notes/next/highlights/{name}.md").write_text(f"title: {name.title()}\ncategory: new\n\nBody.\n")
                if spec:
                    (root / "release-notes/next/clips").mkdir(parents=True, exist_ok=True)
                    (root / f"release-notes/next/clips/{name}.json").write_text(json.dumps(spec))
            rows = [{"id": "drag", "category": "new", "roles": ["after"]}, {"id": "gone", "category": "new", "roles": ["after"]}]
            with mock.patch("sys.stdout"):
                kept = clips.write_tours(rows, root / "tours", root=root)
            self.assertEqual([r["id"] for r in kept], ["drag"])
            self.assertEqual(json.loads((root / "tours/drag.json").read_text())["title"], "Drag")
            self.assertFalse((root / "tours/gone.json").exists())

    def test_the_tours_command_splits_the_befores_by_commit(self):
        with tempfile.TemporaryDirectory() as tmp:
            plan = Path(tmp, "plan.json")
            plan.write_text(json.dumps([
                {"id": "a", "category": "improved", "roles": ["after", "before"], "before": "b" * 40},
                {"id": "b", "category": "improved", "roles": ["before"], "before": "c" * 40},
                {"id": "c", "category": "new", "roles": ["after"]}]))
            def tours(*args):
                out = io.StringIO()
                with mock.patch("sys.stdout", out):
                    self.assertEqual(clips.main(["tours", "--plan", str(plan), "--dir", "D", *args]), 0)
                return out.getvalue().split()
            self.assertEqual(tours("--role", "after"), ["D/a.json", "D/c.json"])
            self.assertEqual(tours("--role", "before", "--before", "b" * 40), ["D/a.json"])
            self.assertEqual(tours("--role", "before", "--before", "b" * 40, "--other-befores"), ["c" * 40])

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

        def render_tour(clip_id, tour_dir, out, keep):
            rendered.append((clip_id, tour_dir.parent.name, tour_dir.name))
            keep.mkdir(parents=True)
            (keep / "0000.png").write_bytes(b"png")
        with tempfile.TemporaryDirectory() as tmp, \
                mock.patch.object(clips, "render_tour", render_tour), \
                mock.patch.dict("os.environ", {"PR_MEDIA_PRIVACY_OCR": "none"}):
            with self.assertRaisesRegex(clips.ClipError, "no OCR"):
                clips.publish_auto([{"id": "better", "roles": ["after", "before"]}], Path(tmp), Path(tmp))
        self.assertEqual(rendered, [("better", "after", "better"), ("better", "before", "better")])


    def test_publish_auto_checks_the_clips_frames_never_the_animated_webp(self):
        """The Linux OCR (tesseract on Leptonica) cannot decode an animated WebP: a check of the .webp itself
        refused every clip as unreadable. The check reads the PNG frames the encoder made the clip from."""
        import os, stat
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            # An OCR tool like pr_media_ocr_tesseract.py on an animated WebP: it fails on a .webp, reads a PNG.
            ocr = tmp / "ocr.sh"
            ocr.write_text('#!/bin/sh\ncase "$1" in *.webp) exit 2;; esac\ncat "$1"\n')
            ocr.chmod(ocr.stat().st_mode | stat.S_IEXEC)

            def render_tour(clip_id, tour_dir, out, keep=None):
                out.parent.mkdir(parents=True, exist_ok=True)
                out.write_bytes(b"RIFF\0\0\0\0WEBPVP8X animated")
                keep.mkdir(parents=True)
                for index, text in enumerate(["Sidebar", "Archive" if clip_id == "clean" else "acme-secret-host"]):
                    (keep / f"{index:04d}.png").write_text(text + "\n")

            put = mock.Mock()
            def pr_media_module():
                module = real()
                module.put_file = put
                return module
            real = clips.pr_media_module
            env = {k: v for k, v in os.environ.items() if k != "GITHUB_ACTIONS"}
            env.update({"PR_MEDIA_PRIVACY_OCR": str(ocr), "PR_MEDIA_PRIVATE_TERMS": json.dumps(["acme-secret-host"]),
                        "HOME": str(tmp)})
            with mock.patch.object(clips, "render_tour", render_tour), \
                    mock.patch.object(clips, "pr_media_module", pr_media_module), \
                    mock.patch.dict("os.environ", env, clear=True), mock.patch("sys.stderr"), mock.patch("sys.stdout"):
                self.assertEqual(clips.publish_auto([{"id": "clean", "roles": ["after"]}], tmp, tmp / "a"), [])
                self.assertEqual([c.args[2] for c in put.call_args_list], ["whats-new/clean/clip-auto-after.webp"])
                put.reset_mock()
                with self.assertRaises(Exception) as refused:
                    clips.publish_auto([{"id": "clean", "roles": ["after"]}, {"id": "leaky", "roles": ["after"]}],
                                       tmp, tmp / "b")
                self.assertEqual(type(refused.exception).__name__, "PrivacyError")
                self.assertIn("whats-new/leaky/clip-auto-after.webp.frames/0001.png", str(refused.exception))
                self.assertNotIn("acme-secret-host", str(refused.exception))
                put.assert_not_called()



class WorkflowTests(unittest.TestCase):
    """cmux-next-media.yml's clip steps: planned before the Mac pick, recorded past a failed tour."""

    def setUp(self):
        try:
            import yaml
        except ImportError:
            self.skipTest("PyYAML is not installed")
        self.jobs = yaml.safe_load((SCRIPT.parents[3] / ".github/workflows/cmux-next-media.yml").read_text())["jobs"]

    def step(self, job, step_id):
        return next(s for s in self.jobs[job]["steps"] if s.get("id") == step_id)

    def test_the_route_job_plans_the_clips_before_it_picks_a_mac_and_a_plan_forces_one(self):
        # A tip that adds only a highlight and its spec maps to no UI path: planned on the Mac, the pick had
        # already skipped the tour.
        ids = [s.get("id") for s in self.jobs["route"]["steps"]]
        self.assertLess(ids.index("clips"), ids.index("pick"))
        self.assertIn("whats-new-clips.py plan", self.step("route", "clips")["run"])
        sparse = self.jobs["route"]["steps"][0]["with"]["sparse-checkout"]
        for path in ("whats-new-clips.py", "media/tour.py", "release-notes/next/highlights", "release-notes/next/clips"):
            self.assertIn(path, sparse)
        pick = self.step("route", "pick")
        self.assertEqual(pick["env"]["CLIPS_PLAN"], "${{ steps.clips.outputs.plan }}")
        self.assertIn("force=(--force-mac)", pick["run"].split("CLIPS_PLAN", 2)[2])
        scope = self.step("tour", "scope")
        self.assertEqual(scope["env"]["CLIPS_PLAN"], "${{ needs.route.outputs.clips_plan }}")
        self.assertNotIn("whats-new-clips.py plan --", scope["run"])
        self.assertIn("write-tours", scope["run"])

    def test_a_failed_tour_does_not_end_the_record_step_before_its_count(self):
        run = self.step("tour", "clips")["run"]
        self.assertTrue(run.startswith("set +e\n"), "GitHub's bash -e ends the step at the first failed tour")
        self.assertLess(run.index("count="), run.index("record after"))
        self.assertIn("|| echo", run.split("tour.py", 1)[1].split("}", 1)[0])


if __name__ == "__main__":
    unittest.main()
