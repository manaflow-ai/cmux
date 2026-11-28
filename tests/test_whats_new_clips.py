#!/usr/bin/env python3
"""scripts/cmux-next/media/whats-new-clips.py: specs, cutting a capture to its clip steps, the
idle-clip refusal, the clip's length, and the highlight's clip line. Encoding (ffmpeg, img2webp)
and the fleet capture are not run here."""
import hashlib
import re
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


class SettingsStepTests(unittest.TestCase):
    """A clip opens Settings in front (`"focus": true`), opens a row that is there, and never sets a userOnly row."""

    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.schema = Path(folder.name) / "settings-schema.json"
        self.schema.write_text(json.dumps({"rows": [
            {"key": "mobile.autoApprovePhones", "agent_settable": False, "agent_refusal": "userOnly"},
            {"key": "home.chiefBubbleStyle", "agent_settable": True, "agent_refusal": None},
            {"key": "updates.installWhenIdleMinutes", "page_hidden": True, "consumers": ["cmux-next"]},
            {"key": "classic.only", "consumers": ["cmux"]}],
            "sections": [{"id": "appearance"}],
            "page": {"categories": [{"id": "appearance", "actions": ["appearance"], "lead": ["looksGallery"]}]}}))
        # The native gate's names (SettingsAnchor.swift's shape): looksGallery is a page card, not one of these.
        self.anchors = Path(folder.name) / "SettingsAnchor.swift"
        self.anchors.write_text("""public enum SettingsCardID: String, CaseIterable, Sendable {
    case theme, terminal

    public var section: SettingsSection {
        switch self {
        case .theme: .appearance
        case .terminal: .terminal
        }
    }
}

public enum SettingsPageAnchor: String, CaseIterable, Sendable {
    case joinControl = "devices.join.control"
    public static func joinConsent(_ surface: String) -> SettingsPageAnchor? { nil }
}
""")

    def problems(self, *steps):
        return clips.settings_problems(list(steps), self.schema, self.anchors)

    def test_open_settings_needs_focus(self):
        step = {"title": "Settings", "rpc": {"method": "action.run", "params": {
            "action": "openSettings", "arguments": {"setting": "home.chiefBubbleStyle"}}}}
        self.assertTrue(any('"focus": true' in p for p in self.problems(step)))
        step["rpc"]["params"]["focus"] = True
        self.assertEqual(self.problems(step), [])

    def test_open_settings_names_a_row_that_is_there(self):
        step = {"title": "Settings", "rpc": {"method": "action.run", "params": {
            "action": "openSettings", "arguments": {"setting": "updates.gone"}, "focus": True}}}
        self.assertTrue(any("no row or card updates.gone" in p for p in self.problems(step)))
        self.assertEqual(self.problems({**step, "optional": "the before app has no updates.gone"}), [])

    def test_open_settings_names_a_card_that_is_there(self):
        def opening(key):
            return {"title": "Card", "rpc": {"method": "action.run", "params": {
                "action": "openSettings", "arguments": {"setting": key}, "focus": True}}}
        for key in ("card.theme", "theme", "card.terminal", "section.appearance", "action.appearance.appearance",
                    "devices.join.control"):
            self.assertEqual(self.problems(opening(key)), [], key)
        # The page links looksGallery, but the app's gate refuses it (media run 45837430593), and the
        # switch's `case .theme:` lines are not cards.
        for key in ("card.looksGallery", "card.gone", "card..theme: .appearance", "card.theme.inner", "section.gone"):
            self.assertTrue(any(f"no row or card {key}" in p for p in self.problems(opening(key))), key)

    def test_open_settings_skips_a_row_the_page_hides(self):
        def opening(key):
            return {"title": "Row", "rpc": {"method": "action.run", "params": {
                "action": "openSettings", "arguments": {"setting": key}, "focus": True}}}
        for key in ("updates.installWhenIdleMinutes", "classic.only"):
            self.assertTrue(any(f"no row or card {key}" in p for p in self.problems(opening(key))), key)

    def test_the_real_gate_has_no_looks_gallery_card(self):
        places = clips.settings_cards()
        self.assertIn("card.theme", places)
        self.assertNotIn("card.looksGallery", places)
        self.assertIn("section.appearance", places)

    def test_a_user_only_row_is_never_set(self):
        self.assertTrue(any("agents may not change mobile.autoApprovePhones" in p for p in self.problems(
            {"title": "On", "cmux": ["settings", "set", "mobile.autoApprovePhones", "true"]})))
        self.assertTrue(self.problems({"title": "Off", "cmux": ["settings", "reset", "mobile.autoApprovePhones"]}))
        self.assertEqual(self.problems({"title": "Theme", "cmux": ["settings", "set", "home.chiefBubbleStyle", "theme"]}), [])

    def test_the_shipped_specs_pass(self):
        self.assertEqual([p for p in clips.check() if "settings" in p.lower() or "focus" in p], [])


class SpecTests(unittest.TestCase):
    def test_the_oh_my_zsh_clip_installs_only_into_the_tours_shell_home(self):
        # Its before is a real Oh My Zsh asking to update on an app from before the fix; the install
        # writes a .zshrc, so it must stop unless ZDOTDIR is tour.py's own shell-home, never a Mac's.
        spec = clips.load_spec("oh-my-zsh-never-asks-to-update")
        self.assertEqual(clips.spec_problems(spec), [])
        typed = [s["cmux"][-1] for s in spec["steps"] if s.get("cmux", [])[-2:-1] == ["--text"]]
        install = next(t for t in typed if "ohmyzsh" in t)
        self.assertTrue(install.startswith("[[ $ZDOTDIR == */shell-home ]] && "), install)
        self.assertNotRegex(install, r"(^|[\s\"'=])~/")
        self.assertNotIn("$HOME", install)
        # A stale update stamp and a commit behind upstream: what makes Oh My Zsh ask.
        self.assertIn("LAST_EPOCH=1", install)
        self.assertIn("reset -q --hard HEAD~1", install)

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

    def test_declared_waits_warn_at_the_limit_without_failing_the_spec_check(self):
        steps = [{"title": "Setup", "wait": 20}, {"title": "Start", "wait": 5, "clip": True},
                 {"title": "Between", "wait": 2}, {"title": "End cut", "wait": 1, "clip": True},
                 {"title": "Cleanup", "wait": 20}]
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp, "demo.json")
            Path(tmp, "demo.md").touch()
            for between, warned in [(2, True), (1.5, False)]:
                steps[2]["wait"] = between
                path.write_text(json.dumps({**SPEC, "steps": steps}))
                with mock.patch("sys.stdout", new_callable=io.StringIO) as stdout:
                    self.assertEqual(clips.check(Path(tmp), Path(tmp)), [])
                self.assertEqual("declared waits in the cut span 8 s" in stdout.getvalue(), warned)

    def test_the_capture_state_runs_the_fixture_fake_agent(self):
        fixture = {"harnesses": {"fake": {"argv": ["/usr/bin/python3",
                                                  "{repo}/cmux-tui/crates/acpmux/tests/fake_agent.py"]}}}
        state = clips.capture_state({**SPEC, "harnessFixture": fixture})
        self.assertEqual(state["fakeHarness"], {"id": "fake"})
        self.assertNotIn("harnessFixture", state)
        self.assertNotIn("fakeHarness", clips.capture_state(SPEC))

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

    def test_a_before_that_never_changes_is_its_one_frame_held(self):
        # space-button-spacing's before (2026-11-27): the old app has no spacing setting, so the window is
        # the same throughout, and that window is the before. An after like it stays refused (above).
        frames = [Path(f"f{i}.png") for i in range(8)]
        with mock.patch.object(clips, "gray", return_value=bytes([10] * 64)):
            plan = clips.timeline(SPEC, frames, "crop", still=True)
        self.assertEqual(plan, [(Path("f0.png"), clips.MIN_SECONDS)])

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


def tour_folders(results, ids, roles):
    """The folders tour.py writes for each tour that ran (RESULTS/ROLE/ID)."""
    for role in roles:
        for clip_id in ids:
            (Path(results) / role / clip_id).mkdir(parents=True, exist_ok=True)


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
                if clips.is_iphone(json.loads(path.read_text())):
                    continue  # recorded on a simulator step, never a tour
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

    def test_the_plan_reads_published_clips_from_the_pr_media_tree_not_a_rate_limited_head(self):
        # 2026-11-25 (cmux run 45636169467): raw.githubusercontent.com answered HTTP 429 to the published
        # HEADs, two published clips planned again, and iphone-pairs-without-qr waited past PLAN_LIMIT.
        tree = {"truncated": False, "tree": [
            {"path": "better", "type": "tree"},
            {"path": "better/clip-auto-after.webp", "type": "blob"},
            {"path": "archive/clip-auto-after.failed.json", "type": "blob"}]}
        asked = []
        root = [{"name": "README.md", "type": "file", "sha": "f" * 40}, {"name": "whats-new", "type": "dir", "sha": "a" * 40}]
        files = clips.pr_media_files(get=lambda path: asked.append(path) or (root if "contents" in path else tree))
        self.assertEqual(asked, ["repos/manaflow-ai/cmux/contents?ref=pr-media",
                                 f"repos/manaflow-ai/cmux/git/trees/{'a' * 40}?recursive=1"])
        self.assertEqual(files, {"whats-new/better/clip-auto-after.webp", "whats-new/archive/clip-auto-after.failed.json"})
        def limited(url):
            raise AssertionError(f"asked raw for {url}")
        with mock.patch.object(clips, "published", limited):
            exists = clips.listed(files, clips.published)
            self.assertTrue(exists(clips.auto_url("better", "after")))
            self.assertFalse(exists(clips.auto_url("better", "before")))
        markers = []
        marker = clips.listed(files, lambda url: markers.append(url) or {"spec": "x"})
        self.assertIsNone(marker(clips.failed_url("better", "after")))
        self.assertEqual(marker(clips.failed_url("archive", "after")), {"spec": "x"})
        self.assertEqual(markers, [clips.failed_url("archive", "after")])
        with tempfile.TemporaryDirectory() as tmp:
            repo, base, head = self.repo(tmp)
            with mock.patch.object(clips, "SPECS", repo / "release-notes/next/clips"), \
                 mock.patch.object(clips, "published", limited):
                rows = clips.plan(base, head, Path(tmp, "tours"), exists=clips.listed(files, clips.published),
                                  root=repo)
            self.assertEqual([(r["id"], r["roles"]) for r in rows],
                             [("archive", ["after"]), ("better", ["before"]), ("uncategorized", ["after"])])
        # A tree that cannot be read whole leaves each clip to its own HEAD, as before.
        with mock.patch("sys.stderr", io.StringIO()):
            self.assertIsNone(clips.pr_media_files(get=lambda path: (_ for _ in ()).throw(OSError("down"))))
        self.assertIsNone(clips.pr_media_files(get=lambda path: root if "contents" in path else {"truncated": True, "tree": []}))
        with mock.patch("sys.stderr", io.StringIO()):  # no whats-new/ on the branch
            self.assertIsNone(clips.pr_media_files(get=lambda path: root[:1]))
        self.assertIs(clips.listed(None, clips.failure_marker), clips.failure_marker)

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
            # The tip's own one first, before on the previous tip; then the earlier ones, oldest first, both on
            # the one extra app: the parent of the oldest one's commit, which predates both changes.
            self.assertEqual([(r["id"], r["roles"], r.get("before")) for r in rows],
                             [("fresh", ["after", "before"], previous),
                              ("better", ["after", "before"], root),
                              ("later", ["after", "before"], root)])
            self.assertNotEqual(other, better)
            # With only `later` left, its before is on its own commit's parent.
            done = {clips.auto_url(i, "after") for i in ("fresh", "better", "later")} | {
                clips.auto_url(i, "before") for i in ("fresh", "better")}
            again = clips.plan(tip, self.commit(repo, "next", t0 + 3 * day, {"README": "n\n"}), Path(tmp, "t2"),
                               exists=lambda url: url in done, root=repo)
            self.assertEqual([(r["id"], r["roles"], r.get("before")) for r in again], [("later", ["before"], other)])

    def test_waiting_befores_from_different_commits_share_one_older_app(self):
        # 2026-11-16: five Improved highlights from earlier nightlies, each with its after published, waited for
        # a before on its own commit's parent, one such app a tour, so they drained at one a nightly.
        day = 86400
        with tempfile.TemporaryDirectory() as tmp:
            repo = self.history(tmp)
            t0 = 1_800_000_000
            self.commit(repo, "root", t0, {"README": "r\n"})
            names = ("w1", "w2", "w3", "w4", "w5")
            parents = []
            for index, name in enumerate(names):
                parents.append(self.commit(repo, f"before {name}", t0 + day + 120 * index, {"README": f"{name}\n"}))
                self.commit(repo, name, t0 + day + 120 * index + 60, self.highlight(name, "improved"))
            previous = self.commit(repo, "previous tip", t0 + 2 * day, {"README": "p\n"})
            tip = self.commit(repo, "tip", t0 + 2 * day + 60, self.highlight("fresh", "improved"))
            done = {clips.auto_url(name, "after") for name in names}
            tours = Path(tmp, "t")
            with mock.patch("sys.stdout"):
                rows = clips.plan(previous, tip, tours, limit=6, exists=lambda url: url in done, root=repo)
            # The tip's own one on the previous tip as before; all five waiting befores on the parent of the
            # oldest one's commit, so the tour builds one extra app, not five over five nightlies.
            self.assertEqual([(r["id"], r["roles"], r.get("before")) for r in rows],
                             [("fresh", ["after", "before"], previous)]
                             + [(name, ["before"], parents[0]) for name in names])
            plan = Path(tmp, "plan.json")
            plan.write_text(json.dumps(rows))
            out = io.StringIO()
            with mock.patch("sys.stdout", out):
                clips.main(["tours", "--plan", str(plan), "--role", "before", "--dir", str(tours),
                            "--before", previous, "--other-befores"])
            # The workflow builds an app for each line: one.
            self.assertEqual(out.getvalue().split(), [parents[0]])
            # A waiting one whose tour already failed with this spec still goes after the ones not tried, and
            # the shared app is still the oldest of the ones planned.
            digest = clips.spec_digest("w1", repo / "release-notes/next/clips")
            failed = {clips.failed_url("w1", "before"): {"spec": digest}}
            with mock.patch("sys.stdout"):
                rows = clips.plan(previous, tip, Path(tmp, "t2"), limit=6, exists=lambda url: url in done, root=repo,
                                  marker=failed.get)
            self.assertEqual([r["id"] for r in rows], ["fresh", "w2", "w3", "w4", "w5", "w1"])
            self.assertEqual({r["before"] for r in rows[1:]}, {parents[0]})
            # Past the limit the failed one waits, and the shared app is the oldest of the ones left (the
            # before-only rows count against their own limit).
            with mock.patch("sys.stdout"):
                rows = clips.plan(previous, tip, Path(tmp, "t3"), limit=5, exists=lambda url: url in done, root=repo,
                                  marker=failed.get, before_only=4)
            self.assertEqual([(r["id"], r.get("before")) for r in rows],
                             [("fresh", previous)] + [(name, parents[1]) for name in names[1:]])

    def test_an_improvement_with_a_clip_line_still_records_its_before(self):
        # A hand-published `clip:` line is the after; an Improved one's before still comes from its spec
        # (buttons-always-visible-minimal-mode shipped in a nightly with no before). A New one has nothing left.
        day = 86400
        with tempfile.TemporaryDirectory() as tmp:
            repo = self.history(tmp)
            t0 = 1_800_000_000
            previous = self.commit(repo, "root", t0, {"README": "r\n"})
            files = {}
            for name, category in (("tidy", "improved"), ("fresh", "new")):
                files[f"release-notes/next/highlights/{name}.md"] = (
                    f"title: {name.title()}\ncategory: {category}\nclip: {URL} | {SHA}\n\nBody.\n")
                files[f"release-notes/next/clips/{name}.json"] = json.dumps(SPEC)
            tip = self.commit(repo, "clip lines", t0 + day, files)
            rows = clips.plan(previous, tip, Path(tmp, "t"), exists=lambda url: False, root=repo)
            self.assertEqual([(r["id"], r["roles"], r.get("before")) for r in rows], [("tidy", ["before"], previous)])
            self.assertEqual(sorted(p.stem for p in Path(tmp, "t").glob("*.json")), ["tidy"])
            done = {clips.auto_url("tidy", "before")}
            self.assertEqual(clips.plan(previous, tip, Path(tmp, "t2"), exists=lambda url: url in done, root=repo), [])

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

    def failing_four_then_a_newer_one(self, tmp):
        """Four highlights whose tours fail, then a newer one added before the previous tip (the nightly of
        2026-11-15: four failing specs held all four slots and omnibar-preload was never planned)."""
        day = 86400
        repo = self.history(tmp)
        t0 = 1_800_000_000
        self.commit(repo, "root", t0, {"README": "r\n"})
        for index, name in enumerate(("f1", "f2", "f3", "f4")):
            self.commit(repo, f"failing {name}", t0 + day + 60 * index, self.highlight(name))
        self.commit(repo, "newer", t0 + 2 * day, self.highlight("newer"))
        previous = self.commit(repo, "previous tip", t0 + 2 * day + 60, {"README": "p\n"})
        tip = self.commit(repo, "tip", t0 + 3 * day, {"README": "t\n"})
        return repo, previous, tip

    def test_a_spec_whose_tour_failed_leaves_its_slot_to_one_not_tried(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo, previous, tip = self.failing_four_then_a_newer_one(tmp)
            digest = clips.spec_digest("f1", repo / "release-notes/next/clips")
            failed = {clips.failed_url(name, "after"): {"tip": "a" * 40, "spec": digest} for name in ("f1", "f2", "f3", "f4")}
            with mock.patch("sys.stdout"):
                before = clips.plan(previous, tip, Path(tmp, "t0"), limit=4, exists=lambda url: False, root=repo)
                rows = clips.plan(previous, tip, Path(tmp, "t"), limit=4, exists=lambda url: False, root=repo,
                                  marker=failed.get)
            # With no markers: oldest first, the newer one waits behind the four.
            self.assertEqual([r["id"] for r in before], ["f1", "f2", "f3", "f4"])
            # The one never tried goes first; the failed ones still take the slots left, in their order.
            self.assertEqual([r["id"] for r in rows], ["newer", "f1", "f2", "f3"])

    def test_a_repaired_spec_is_planned_as_never_tried(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo, previous, tip = self.failing_four_then_a_newer_one(tmp)
            # The markers name the spec the tours failed with; f1's spec has been repaired since.
            old = {clips.failed_url(name, "after"): {"spec": "0" * 64} for name in ("f1",)}
            digest = clips.spec_digest("f2", repo / "release-notes/next/clips")
            old.update({clips.failed_url(name, "after"): {"spec": digest} for name in ("f2", "f3", "f4")})
            with mock.patch("sys.stdout"):
                rows = clips.plan(previous, tip, Path(tmp, "t"), limit=2, exists=lambda url: False, root=repo,
                                  marker=old.get)
            self.assertEqual([r["id"] for r in rows], ["f1", "newer"])

    def test_publish_auto_marks_each_clip_whose_tour_failed_with_its_tip_and_spec(self):
        def render_tour(clip_id, tour_dir, out, keep, role="after"):
            raise clips.ClipError("the tour did not run every step")
        put = mock.Mock()
        module = mock.Mock(put_files=put)
        with tempfile.TemporaryDirectory() as tmp:
            specs = Path(tmp, "clips")
            specs.mkdir()
            (specs / "better.json").write_text(json.dumps(SPEC))
            tour_folders(Path(tmp), ["better"], ["after", "before"])
            with mock.patch.object(clips, "render_tour", render_tour), \
                    mock.patch.object(clips, "pr_media_module", lambda: module):
                problems = clips.publish_auto([{"id": "better", "roles": ["after", "before"]}], Path(tmp), Path(tmp),
                                              tip="c" * 40, specs=specs)
                self.assertEqual(len(problems), 2)
                (_, _, markers, _), _ = put.call_args
                self.assertEqual(sorted(markers), ["whats-new/better/clip-auto-after.failed.json",
                                                   "whats-new/better/clip-auto-before.failed.json"])
                marker = json.loads(markers["whats-new/better/clip-auto-after.failed.json"].read_text())
            digest = clips.spec_digest("better", specs)
        self.assertEqual(len(digest), 64)
        self.assertEqual(marker, {"tip": "c" * 40, "spec": digest})
        self.assertEqual(clips.failed_url("better", "after"),
                         clips.URL_PREFIX + "better/clip-auto-after.failed.json")

    def test_waiting_befores_share_the_newest_nightly_tip_at_or_before_them(self):
        # 2026-11-16: the shared before was the bare parent of the oldest waiting highlight, 62da55823d7, which
        # did not compile (SetupCardRoute.swift: no JSONValue); two tours lost every before they planned.
        day = 86400
        with tempfile.TemporaryDirectory() as tmp:
            repo = self.history(tmp)
            t0 = 1_800_000_000
            self.commit(repo, "root", t0, {"README": "r\n"})
            shipped = self.commit(repo, "a nightly tip", t0 + day, {"README": "s\n"})
            broken = self.commit(repo, "does not compile", t0 + day + 60, {"README": "b\n"})
            self.commit(repo, "w1", t0 + day + 120, self.highlight("w1", "improved"))
            later_tip = self.commit(repo, "a later nightly tip", t0 + day + 180, {"README": "l\n"})
            self.commit(repo, "w2", t0 + day + 240, self.highlight("w2", "improved"))
            previous = self.commit(repo, "previous tip", t0 + 2 * day, {"README": "p\n"})
            tip = self.commit(repo, "tip", t0 + 2 * day + 60, {"README": "t\n"})
            done = {clips.auto_url(name, "after") for name in ("w1", "w2")}
            asked = []

            def tips(until):
                asked.append(until)
                # Newest first; one tip is past this checkout's history (a shallow boundary).
                return [later_tip, "f" * 40, shipped]
            rows = clips.plan(previous, tip, Path(tmp, "t"), exists=lambda url: url in done, root=repo, tips=tips)
            self.assertEqual([(r["id"], r["roles"], r["before"]) for r in rows],
                             [("w1", ["before"], shipped), ("w2", ["before"], shipped)])
            self.assertEqual(len(asked), 1)
            self.assertGreaterEqual(asked[0], t0 + day + 60)
            # The parent itself, when it is a nightly tip.
            rows = clips.plan(previous, tip, Path(tmp, "t2"), exists=lambda url: url in done, root=repo,
                              tips=lambda until: [broken, shipped])
            self.assertEqual({r["before"] for r in rows}, {broken})
            # No tip read: the parent, as before.
            with mock.patch("sys.stdout"):
                rows = clips.plan(previous, tip, Path(tmp, "t3"), exists=lambda url: url in done, root=repo,
                                  tips=lambda until: [])
            self.assertEqual({r["before"] for r in rows}, {broken})

    def test_nightly_tips_are_the_successful_nightly_next_push_runs_newest_first(self):
        paths = []

        def get(path):
            paths.append(path)
            return {"workflow_runs": [{"head_sha": "a" * 40, "created_at": "2026-11-15T10:00:00Z"},
                                      {"head_sha": "b" * 40, "created_at": "2026-11-15T12:00:00Z"},
                                      {"head_sha": "not a sha", "created_at": "2026-11-15T13:00:00Z"},
                                      {"head_sha": "a" * 40, "created_at": "2026-11-15T09:00:00Z"}]}
        self.assertEqual(clips.nightly_tips(1_800_000_000, get=get), ["b" * 40, "a" * 40])
        self.assertIn("actions/workflows/nightly.yml/runs?branch=nightly-next&event=push&status=success", paths[0])
        self.assertIn("created=%3C%3D2027-01-15T08:00:00Z", paths[0])

        def fails(path):
            raise clips.ClipError("gh exited 1")
        with mock.patch("sys.stdout"):
            self.assertEqual(clips.nightly_tips(1_800_000_000, get=fails), [])

    def test_before_only_rows_take_no_plan_limit_slot(self):
        # The tour of 2026-11-16 (nightly-next 3674b7fcca): one row of the tip, six Improved highlights waiting
        # for a before alone, all six marked failed (their app had not built). PLAN_LIMIT 4 planned the three
        # oldest and left screen-sharing-sidebar, pane-close-and-unzoom-are-quicker and zoom-dims-other-panes
        # waiting, though each is one short tour on the one shared app.
        day = 86400
        with tempfile.TemporaryDirectory() as tmp:
            repo = self.history(tmp)
            t0 = 1_800_000_000
            self.commit(repo, "root", t0, {"README": "r\n"})
            names = ("b1", "b2", "b3", "b4", "b5", "b6")
            for index, name in enumerate(names):
                self.commit(repo, name, t0 + day + 60 * index, self.highlight(name, "improved"))
            self.commit(repo, "both roles", t0 + day + 600, self.highlight("both", "improved"))
            previous = self.commit(repo, "previous tip", t0 + 2 * day, {"README": "p\n"})
            tip = self.commit(repo, "tip", t0 + 2 * day + 60, self.highlight("fresh", "improved"))
            done = {clips.auto_url(name, "after") for name in names}
            digest = clips.spec_digest("b1", repo / "release-notes/next/clips")
            failed = {clips.failed_url(name, "before"): {"spec": digest} for name in names}
            with mock.patch("sys.stdout"):
                rows = clips.plan(previous, tip, Path(tmp, "t"), limit=4, exists=lambda url: url in done,
                                  root=repo, marker=failed.get)
            self.assertEqual([(r["id"], r["roles"]) for r in rows],
                             [("fresh", ["after", "before"]), ("both", ["after", "before"])]
                             + [(name, ["before"]) for name in names])
            # They have their own limit.
            with mock.patch("sys.stdout"):
                rows = clips.plan(previous, tip, Path(tmp, "t2"), limit=1, exists=lambda url: url in done,
                                  root=repo, marker=failed.get, before_only=2)
            self.assertEqual([r["id"] for r in rows], ["fresh", "b1", "b2"])

    def test_publish_auto_marks_no_failure_for_a_tour_that_never_ran(self):
        # "no app at 62da558...; its befores wait": the before tours never ran, and publish-auto marked them
        # failed with their spec, which put them behind every other row on the next plan.
        def render_tour(clip_id, tour_dir, out, keep, role="after"):
            raise clips.ClipError("the tour did not run every step")
        put = mock.Mock()
        module = mock.Mock(put_files=put)
        with tempfile.TemporaryDirectory() as tmp:
            specs = Path(tmp, "clips")
            specs.mkdir()
            (specs / "better.json").write_text(json.dumps(SPEC))
            tour_folders(Path(tmp), ["better"], ["after"])  # the after ran and failed; the before never ran
            with mock.patch.object(clips, "render_tour", render_tour), \
                    mock.patch.object(clips, "pr_media_module", lambda: module):
                problems = clips.publish_auto([{"id": "better", "roles": ["after", "before"]}], Path(tmp), Path(tmp),
                                              tip="c" * 40, specs=specs)
                (_, _, markers, _), _ = put.call_args
            self.assertEqual(sorted(markers), ["whats-new/better/clip-auto-after.failed.json"])
            self.assertEqual(len(problems), 2)
            self.assertIn("did not run", problems[1])
            # No tour ran at all: nothing is marked.
            put.reset_mock()
            with mock.patch.object(clips, "render_tour", render_tour), \
                    mock.patch.object(clips, "pr_media_module", lambda: module):
                clips.publish_auto([{"id": "other", "roles": ["before"]}], Path(tmp), Path(tmp), specs=specs)
            put.assert_not_called()

    def test_a_spec_carries_its_harness_fixture_and_the_tour_fills_in_the_checkout(self):
        fixture = {"harnesses": {"fake": {"argv": ["/usr/bin/python3", "{repo}/agent.py"]}}}
        self.assertEqual(clips.spec_problems({**SPEC, "harnessFixture": fixture}), [])
        self.assertTrue(clips.spec_problems({**SPEC, "harnessFixture": ["fake"]}))
        tour = clips.tour_from_spec({**SPEC, "harnessFixture": fixture}, "T")
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp, "t.json")
            path.write_text(json.dumps(tour))
            loaded = clips.tour_module().load_tour(path)
        argv = loaded["harness_fixture"]["harnesses"]["fake"]["argv"]
        self.assertEqual(argv, ["/usr/bin/python3", str(SCRIPT.parents[3] / "agent.py")])

    def test_a_menu_clip_records_the_apps_menus(self):
        # customizations-menu: the native menu is its own window, so its clip asks tour.py for the app's menus.
        self.assertEqual(clips.spec_problems({**SPEC, "menus": True}), [])
        self.assertTrue(clips.spec_problems({**SPEC, "menus": "yes"}))
        self.assertTrue(clips.spec_problems({**IPHONE_SPEC, "menus": True}))
        self.assertIs(clips.tour_from_spec({**SPEC, "menus": True}, "T")["menus"], True)
        self.assertNotIn("menus", clips.tour_from_spec(SPEC, "T"))
        self.assertIs(clips.load_spec("customizations-menu").get("menus"), True)

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

    def test_a_window_that_goes_away_in_a_clip_step_ends_the_clip_on_an_empty_frame(self):
        # warn-before-quit-shortcut's before (2026-11-27): the old app quits on the first ⌘Q, its frames stop
        # 0.1 s into the step, and the clip was refused as "1 frame(s)". It now ends on the window, then empty.
        manifest = self.manifest(0.0, 2.0, 3.5, video=False)
        manifest["frames"] = [{"file": f"frames/frame-{i:05d}.jpg", "step": step, "time": t}
                              for i, (step, t) in enumerate([(1, 0.0), (1, 1.9), (2, 2.0), (2, 2.1)])]
        made = []
        with tempfile.TemporaryDirectory() as tmp, \
                mock.patch.object(clips, "size_of", return_value=(660, 612)), \
                mock.patch.object(clips, "run", side_effect=lambda argv, **kw: made.append(argv)):
            with self.assertRaisesRegex(clips.ClipError, "span 1 frame"):
                clips.tour_frames(SPEC, manifest, Path("/tour"), Path(tmp))
            self.assertEqual(made, [], "no empty frame while the window is there")
            manifest["frames_ended"] = {"step": 2, "time": 2.2, "reason": "no window"}
            ended = clips.tour_frames(SPEC, manifest, Path("/tour"), Path(tmp))
        self.assertEqual([f.name for f in ended], ["frame-00001.jpg", "frame-00003.jpg", "closed.png"])
        self.assertIn(f"color=c={clips.CLOSED_COLOR}:s=660x612", made[0])
        # A window that went away outside the clip steps adds nothing.
        manifest["frames_ended"]["step"] = 3
        with self.assertRaisesRegex(clips.ClipError, "span 1 frame"):
            clips.tour_frames(SPEC, manifest, Path("/tour"), Path("/unused"))

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

    def test_successful_publish_reports_every_planned_role_rejected(self):
        names = ["fade-inactive-panes", "theme-flourishes"]
        tip = "7682aa4571235d820f8e136c90202e2d93cabd1e"

        def render(clip_id, *args, **kwargs):
            # Run the real quality checks on an idle crop and a ten-second changing crop.
            frames = [Path(str(i)) for i in range(10)]
            pixels = [bytes([0])] * 5 + [bytes([0 if clip_id == names[0] else 255])] * 5
            with mock.patch.object(clips, "gray", side_effect=pixels):
                clips.timeline({**SPEC, "frameInterval": 1}, frames, "crop")

        media = mock.Mock()
        with tempfile.TemporaryDirectory() as tmp:
            tour_folders(Path(tmp), names, ["after"])
            plan = Path(tmp, "plan.json")
            plan.write_text(json.dumps([{"id": name, "roles": ["after"]} for name in names]))
            with mock.patch.object(clips, "render_tour", render), mock.patch.object(clips, "pr_media_module", return_value=media), \
                    mock.patch("sys.stdout", new_callable=io.StringIO) as stdout:
                self.assertEqual(clips.main(["publish-auto", "--plan", str(plan), "--results", tmp, "--tip", tip]), 0)
        receipt = json.loads(stdout.getvalue().split("```json\n")[1].splitlines()[0])
        self.assertEqual((receipt["kind"], receipt["tip"]), ("whats-new-clip-delivery", tip))
        self.assertEqual(receipt["counts"], {"planned": 2, "published": 0, "rejected": 2, "no_tour": 0, "unpublished": 0})
        self.assertEqual([(c["id"], c["role"], c["status"]) for c in receipt["clips"]],
                         [(name, "after", "rejected") for name in names])
        self.assertIn("every frame of the clip is alike", receipt["clips"][0]["reason"])
        self.assertIn("10.0 s; at most 8", receipt["clips"][1]["reason"])
        media.put_file.assert_not_called()
        media.put_files.assert_called_once()  # failure markers are not published clips

    def test_delivery_receipt_preserves_confirmed_writes_when_a_later_upload_fails(self):
        media = mock.Mock()
        media.put_file.side_effect = [None, RuntimeError("upload failed")]

        def render(clip_id, tour_dir, out, keep, role):
            out.write_bytes(b"clip")
            keep.mkdir()
            (keep / "0000.png").touch()

        with tempfile.TemporaryDirectory() as tmp:
            tour_folders(Path(tmp), ["better"], ["before", "after"])
            rows = [{"id": "better", "roles": ["after", "before"]}, {"id": "later", "roles": ["before"]}]
            with mock.patch.object(clips, "render_tour", render), mock.patch.object(clips, "pr_media_module", return_value=media), \
                    mock.patch("sys.stdout", new_callable=io.StringIO) as stdout, self.assertRaisesRegex(RuntimeError, "upload failed"):
                clips.publish_auto(rows, Path(tmp), Path(tmp))
        receipt = json.loads(stdout.getvalue().split("```json\n")[1].splitlines()[0])
        self.assertEqual(receipt["counts"], {"planned": 3, "published": 1, "rejected": 0, "no_tour": 1, "unpublished": 1})
        self.assertEqual(receipt["clips"][0], {"id": "better", "role": "after", "status": "published", "bytes": 4,
                         "url": clips.auto_url("better", "after"), "sha256": hashlib.sha256(b"clip").hexdigest()})
        self.assertEqual([c["status"] for c in receipt["clips"][1:]], ["unpublished", "no_tour"])

    def test_publish_auto_renders_each_role_from_its_tour_folder_and_uploads_nothing_without_ocr(self):
        rendered = []

        def render_tour(clip_id, tour_dir, out, keep, role="after"):
            rendered.append((clip_id, tour_dir.parent.name, tour_dir.name))
            keep.mkdir(parents=True)
            (keep / "0000.png").write_bytes(b"png")
        with tempfile.TemporaryDirectory() as tmp, \
                mock.patch.object(clips, "render_tour", render_tour), \
                mock.patch.dict("os.environ", {"PR_MEDIA_PRIVACY_OCR": "none"}):
            tour_folders(Path(tmp), ["better"], ["after", "before"])
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

            def render_tour(clip_id, tour_dir, out, keep=None, role="after"):
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
                tour_folders(tmp, ["clean", "leaky"], ["after"])
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



IPHONE_SPEC = {
    "app": "iphone",
    "caption": "Open the drawer from the edge.",
    "frameInterval": 0.25,
    "launch_args": ["-cmux-mobile-demo", "drawer"],
    "env": {"CMUX_MOBILE_FEED_STRESS": "20"},
    "steps": [{"title": "Launch", "wait": 2}, {"title": "Drawer", "wait": 3, "clip": True},
              {"title": "Open link", "openurl": "cmux-mobile://feed", "wait": 1}],
    "crop": [0, 0.1, 1, 0.6],
}


def said_pipe(data: bytes):
    """A pipe's read end that holds DATA and then ends, as a recorder's stderr."""
    import os
    read, write = os.pipe()
    os.write(write, data)
    os.close(write)
    return os.fdopen(read, "rb")


class IPhoneClipTests(unittest.TestCase):
    """An `"app": "iphone"` spec: planned without a Mac tour, recorded by a fleet simulator step
    (cmux-next-ios-sim.sh clips, record-iphone), rendered by publish-auto like a tour."""

    def test_an_iphone_spec_is_valid_and_says_what_it_cannot_have(self):
        self.assertEqual(clips.spec_problems(IPHONE_SPEC), [])
        cases = {
            "settings": {**IPHONE_SPEC, "settings": {"a": 1}},
            "an iPhone step takes only": {**IPHONE_SPEC, "steps": [{"title": "T", "cmux": ["x"], "clip": True}]},
            "CMUX_MOBILE_": {**IPHONE_SPEC, "env": {"HOME": "/tmp"}},
            "appearance": {**IPHONE_SPEC, "appearance": "sepia"},
            "wait 0 to": {**IPHONE_SPEC, "steps": [{"title": "T", "wait": 300, "clip": True}]},
            "openurl": {**IPHONE_SPEC, "steps": [{"title": "T", "openurl": "not a link", "clip": True}]},
            "app:": {**IPHONE_SPEC, "app": "ipad"},
        }
        for words, bad in cases.items():
            self.assertTrue(any(words in p for p in clips.spec_problems(bad)), words)
        # A Mac spec has no iPhone environment.
        self.assertTrue(any("iPhone spec" in p for p in clips.spec_problems({**SPEC, "env": {"CMUX_MOBILE_X": "1"}})))

    def test_the_fleet_capture_refuses_an_iphone_spec_and_names_the_simulator_step(self):
        with tempfile.TemporaryDirectory() as tmp:
            Path(tmp, "phone.json").write_text(json.dumps(IPHONE_SPEC))
            with mock.patch.object(clips, "SPECS", Path(tmp)), mock.patch.dict("os.environ", {"CMUX_HQ": tmp}):
                with self.assertRaisesRegex(clips.ClipError, "cmux-next-ios-sim.sh .*--arg clips --arg id=phone"):
                    clips.record("phone", "a" * 40, None, Path(tmp, "out.webp"))

    def repo(self, tmp):
        repo = Path(tmp, "repo")
        git(repo.parent, "init", "-q", str(repo))
        git(repo, "config", "user.email", "t@example.com")
        git(repo, "config", "user.name", "t")
        (repo / "README").write_text("r\n")
        git(repo, "add", ".")
        git(repo, "commit", "-q", "-m", "base")
        base = git(repo, "rev-parse", "HEAD")
        notes = repo / "release-notes/next"
        (notes / "highlights").mkdir(parents=True)
        (notes / "clips").mkdir(parents=True)
        for name, category, spec in (("mac-thing", "new", SPEC), ("phone-new", "new", IPHONE_SPEC),
                                     ("phone-better", "improved", IPHONE_SPEC)):
            (notes / f"highlights/{name}.md").write_text(f"title: {name}\ncategory: {category}\n\nBody.\n")
            (notes / f"clips/{name}.json").write_text(json.dumps(spec))
        git(repo, "add", ".")
        git(repo, "commit", "-q", "-m", "head")
        return repo, base, git(repo, "rev-parse", "HEAD")

    def test_the_plan_routes_iphone_specs_to_the_simulator_with_no_tour(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo, base, head = self.repo(tmp)
            tours = Path(tmp, "tours")
            rows = clips.plan(base, head, tours, exists=lambda url: False, root=repo)
            self.assertEqual([(r["id"], r["roles"], r.get("app"), r.get("before")) for r in rows],
                             [("mac-thing", ["after"], None, None),
                              ("phone-better", ["after", "before"], "iphone", base),
                              ("phone-new", ["after"], "iphone", None)])
            # Only the Mac highlight is a tour.py tour; tour.py could not run an iPhone spec.
            self.assertEqual(sorted(p.stem for p in tours.glob("*.json")), ["mac-thing"])
            plan = Path(tmp, "plan.json")
            plan.write_text(json.dumps(rows))

            def main(*args):
                out = io.StringIO()
                with mock.patch("sys.stdout", out):
                    self.assertEqual(clips.main(list(args)), 0)
                return out.getvalue().splitlines()
            self.assertEqual(main("iphone-runs", "--plan", str(plan)),
                             [f"phone-better after,before {base}", "phone-new after -"])
            self.assertEqual(main("count", "--plan", str(plan), "--app", "mac"), ["1"])
            self.assertEqual(main("count", "--plan", str(plan), "--app", "iphone"), ["2"])
            # The Mac tour records neither the iPhone clips nor their befores.
            self.assertEqual(main("tours", "--plan", str(plan), "--role", "after", "--dir", "D"), ["D/mac-thing.json"])
            self.assertEqual(main("tours", "--plan", str(plan), "--role", "before", "--dir", "D", "--before", "f" * 40,
                                  "--other-befores"), [])
            with mock.patch("sys.stdout"):
                kept = clips.write_tours(rows, Path(tmp, "t2"), root=repo)
            self.assertEqual([r["id"] for r in kept], ["mac-thing"])

    def test_an_earlier_iphone_improvement_keeps_its_before_past_the_mac_extra_before_limit(self):
        # The Mac tour builds at most PLAN_EXTRA_BEFORES apps besides the previous tip's; an iPhone before builds
        # on its own simulator step, so it is never put off.
        row = NightlyTourTests()
        day = 86400
        with tempfile.TemporaryDirectory() as tmp:
            repo = row.history(tmp)
            t0 = 1_800_000_000
            row.commit(repo, "root", t0, {"README": "r\n"})
            mac = row.commit(repo, "mac", t0 + day, row.highlight("mac-better", "improved"))
            files = {"release-notes/next/highlights/phone.md": "title: Phone\ncategory: improved\n\nBody.\n",
                     "release-notes/next/clips/phone.json": json.dumps(IPHONE_SPEC)}
            before_phone = row.commit(repo, "other", t0 + day + 60, {"README": "o\n"})
            row.commit(repo, "phone", t0 + day + 120, files)
            previous = row.commit(repo, "previous", t0 + day + 180, {"README": "p\n"})
            tip = row.commit(repo, "tip", t0 + 2 * day, {"README": "t\n"})
            rows = clips.plan(previous, tip, Path(tmp, "t"), exists=lambda url: False, root=repo)
            self.assertEqual([(r["id"], r["roles"]) for r in rows],
                             [("mac-better", ["after", "before"]), ("phone", ["after", "before"])])
            self.assertEqual(rows[1]["before"], before_phone)
            self.assertNotEqual(mac, before_phone)

    def test_record_iphone_writes_a_tour_folder_publish_auto_cuts_like_a_mac_tour(self):
        now = [100.0]
        calls, signals = [], []

        class Recorder:
            def __init__(self, argv, **kw):
                calls.append(("popen", argv))
                self.stderr = said_pipe(b"Recording started\n")
                self.video = Path(argv[-1])

            def send_signal(self, sig):
                signals.append(sig)
                self.video.write_bytes(b"mp4")

            def wait(self, timeout=None):
                return 0

        def call(argv, **kw):
            calls.append(("run", argv, kw.get("env", {}).get("SIMCTL_CHILD_CMUX_MOBILE_FEED_STRESS"),
                          kw.get("env", {}).get("SIMCTL_CHILD_CMUX_MOBILE_MOCK_AUTH")))
            return mock.Mock(returncode=0)

        def sleep(seconds):
            now[0] += seconds

        simctl = ["xcrun", "simctl", "--set", "/sims"]
        with tempfile.TemporaryDirectory() as tmp:
            Path(tmp, "specs").mkdir()
            Path(tmp, "specs/phone-drawer.json").write_text(json.dumps(IPHONE_SPEC))
            with mock.patch.object(clips, "SPECS", Path(tmp, "specs")):
                manifest = clips.record_iphone("phone-drawer", simctl, "U", "dev.cmux.app", Path("/dd/App.app"),
                                               Path(tmp, "after"), popen=Recorder, call=call,
                                               clock=lambda: now[0], sleep=sleep, ready=lambda stream, timeout: True)
            folder = Path(tmp, "after", clips.tour_module().slug("phone-drawer"))
            self.assertEqual(json.loads((folder / "manifest.json").read_text()), manifest)
            self.assertEqual(manifest["video"], "capture.mp4")
            self.assertEqual([(s["title"], s["status"], s["at"]) for s in manifest["steps"]],
                             [("Launch", "ok", 0.0), ("Drawer", "ok", 2.0), ("Open link", "ok", 5.0)])
            verbs = [c[1][4] for c in calls]
            # A clean install, then the recorder, then the launch into the spec's scene, then its link.
            self.assertEqual(verbs[:3], ["terminate", "uninstall", "install"])
            self.assertLess(verbs.index("io"), verbs.index("launch"))
            launch = next(c for c in calls if c[0] == "run" and c[1][4] == "launch")
            self.assertEqual(launch[1][5:], ["U", "dev.cmux.app", "-cmux-mobile-demo", "drawer"])
            self.assertEqual(launch[2:], ("20", "1"))
            self.assertIn(["xcrun", "simctl", "--set", "/sims", "openurl", "U", "cmux-mobile://feed"],
                          [c[1] for c in calls])
            self.assertEqual(len(signals), 1)
            # publish-auto's cut: from the frame before the clip step to the step after it.
            cut = []

            def fake_run(argv, **kw):
                cut.append(argv)
                for i in range(3):
                    (Path(argv[-1]).parent / f"frame-{i:05d}.png").write_bytes(b"x")
            with mock.patch.object(clips, "run", fake_run), tempfile.TemporaryDirectory() as scratch:
                clips.tour_frames(IPHONE_SPEC, manifest, folder, Path(scratch))
            self.assertEqual(cut[0][cut[0].index("-ss") + 1], "1.750")
            self.assertEqual(cut[0][cut[0].index("-t") + 1], "3.250")
            self.assertEqual(cut[0][cut[0].index("-i") + 1], str(folder / "capture.mp4"))

    def test_record_iphone_sees_the_start_line_behind_another_line_of_the_same_write(self):
        """simctl can write a diagnostic and "Recording started" in one write: a buffered readline() took both,
        returned the first, and select() then waited out the whole timeout on an empty pipe."""
        import signal, subprocess

        class Recorder(subprocess.Popen):
            def __init__(self, argv, **kw):
                self.video = Path(argv[-1])
                super().__init__([sys.executable, "-c", "import os, time; os.write(2, b'note: using the default codec\\nRecording started\\n'); time.sleep(30)"], **kw)

            def send_signal(self, sig):
                self.video.write_bytes(b"mp4")
                super().send_signal(signal.SIGTERM)
        with tempfile.TemporaryDirectory() as tmp:
            Path(tmp, "specs").mkdir()
            Path(tmp, "specs/phone.json").write_text(json.dumps(IPHONE_SPEC))
            with mock.patch.object(clips, "SPECS", Path(tmp, "specs")), mock.patch.object(clips, "RECORD_START_TIMEOUT", 3):
                manifest = clips.record_iphone("phone", ["simctl"], "U", "b", Path("/a.app"), Path(tmp, "out"),
                                               popen=Recorder, call=lambda argv, **kw: mock.Mock(returncode=0),
                                               sleep=lambda s: None)
            self.assertEqual(manifest["video"], "capture.mp4")
            self.assertNotIn("error", manifest)

    def test_record_iphone_gives_up_when_the_recorder_never_starts(self):
        class Recorder:
            def __init__(self, argv, **kw):
                self.stderr = said_pipe(b"")

            def send_signal(self, sig):
                pass

            def wait(self, timeout=None):
                return 0
        with tempfile.TemporaryDirectory() as tmp:
            Path(tmp, "specs").mkdir()
            Path(tmp, "specs/phone.json").write_text(json.dumps(IPHONE_SPEC))
            with mock.patch.object(clips, "SPECS", Path(tmp, "specs")):
                with self.assertRaisesRegex(clips.ClipError, "did not start"):
                    clips.record_iphone("phone", ["simctl"], "U", "b", Path("/a.app"), Path(tmp, "out"),
                                        popen=Recorder, call=lambda argv, **kw: mock.Mock(returncode=0),
                                        clock=lambda: 0.0, sleep=lambda s: None, ready=lambda s, t: True)
            manifest = json.loads(next(Path(tmp, "out").glob("*/manifest.json")).read_text())
            self.assertIn("did not start", manifest["error"])
            self.assertNotIn("video", manifest)


class IPhoneSimStepTests(unittest.TestCase):
    """cmux-next-ios-sim.sh clips: its arguments are checked before anything builds."""
    SIM = SCRIPT.parents[3] / "scripts/ci/cmux-next-ios-sim.sh"

    def sim(self, *args):
        import os, subprocess
        env = {**os.environ, "CMUX_CI_STEP_KEY": "test"}
        return subprocess.run(["bash", str(self.SIM), *args], capture_output=True, text=True, env=env, timeout=30)

    def test_clips_wants_an_id_and_a_base_for_a_before(self):
        for args, words in ((["clips"], "clips needs id=ID"),
                            (["clips", "id=Bad Id"], "id= wants a highlight id"),
                            (["clips", "id=phone", "roles=before"], "needs base=SHA"),
                            (["clips", "id=phone", "base=abc"], "base= wants a 40-character"),
                            (["clips", "id=phone", "speed=2"], "clips takes id=ID")):
            done = self.sim(*args)
            self.assertEqual(done.returncode, 2, (args, done.stderr))
            self.assertIn(words, done.stderr)

    def test_clips_records_each_role_with_record_iphone_and_zips_only_the_clips(self):
        text = self.SIM.read_text()
        block = text.split('if [[ "$mode" == clips ]]; then\n  t0=$SECONDS', 1)[1].split("\nfi\n", 1)[0]
        self.assertIn("whats-new-clips.py record-iphone", block)
        self.assertIn('[[ "$role" == after ]] || side_app="$base_app"', block)
        self.assertIn("zip -qr whats-new-clips.zip whats-new-clips", block)
        # A before whose app does not build leaves the after to record: the base builds in a subshell.
        self.assertIn('if ( build_base_app ) >"$work/base-app.log" 2>&1; then', text)
        self.assertIn('if [[ -z "$side_app" ]]; then', block)


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
        # The tour's own call (bounded() and the comments before it name tour.py too, cmux#56365).
        self.assertIn("|| echo", run.split("media/tour.py --app", 1)[1].split("}", 1)[0])

    def test_iphone_clips_have_their_own_nightly_workflow_with_no_pull_request_job(self):
        import yaml
        # The media workflow plans only Mac clips; a pull request starts no iPhone job.
        self.assertIn("plan --app mac", self.step("route", "clips")["run"])
        self.assertNotIn("iphone-clips", self.jobs)
        doc = yaml.safe_load((SCRIPT.parents[3] / ".github/workflows/cmux-next-iphone-clips.yml").read_text())
        on = doc.get("on", doc.get(True))
        self.assertEqual(on, {"push": {"branches": ["nightly-next"]}})
        jobs = doc["jobs"]
        self.assertIn("plan --app iphone", next(s for s in jobs["plan"]["steps"] if s.get("id") == "plan")["run"])
        self.assertEqual(jobs["record"]["needs"], "plan")
        self.assertEqual(jobs["record"]["runs-on"], "${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || 'mac-gateway' }}")
        run = next(s for s in jobs["record"]["steps"] if s.get("id") == "record")["run"]
        self.assertTrue(run.startswith("set +e\n"))
        self.assertIn("--class simulator --script scripts/ci/cmux-next-ios-sim.sh", run)
        self.assertIn("--artifact artifacts/ios-sim/whats-new-clips.zip", run)
        self.assertIn("whats-new-clips.py iphone-runs", run)
        self.assertIn('artifact --failed "$step"', run)
        self.assertLess(run.index("done < <("), run.index('"$out/plan.json"'))
        # Bounded to its job (cmux-next-iphone-clips on 11-26: clips one after another, each with an unbounded
        # queue wait, sat to the 240-min timeout): every clip's step starts at once, then the job waits for all,
        # and the queue wait, cmux-ci's uncounted compile (5400 s) and the run fit the job with room to upload.
        self.assertIn('record_one "$id" "$roles" "$before" &', run)
        self.assertLess(run.index("record_one \"$id\""), run.index("\nwait\n"))
        self.assertIn('--deadline "${QUEUE_S}s"', run)
        # The step's key names the nightly, so the controller ranks it in the delivery class (nightlyOrPromoteJob:
        # "nightly" in the key), not at -9 behind every queued simulator step (46020149254: 0 clips).
        key = re.search(r'--key "([^"]+)"', run)
        self.assertIsNotNone(key, "each clip step passes its own --key")
        self.assertIn("nightly", key.group(1).lower())
        self.assertIn("$id", key.group(1))
        self.assertIn("GITHUB_RUN_ID", key.group(1))
        self.assertIn('--queue-timeout "$QUEUE_S" --timeout "$RUN_S"', run)
        bounds = dict(re.findall(r"\b(QUEUE_S|RUN_S)=\"?(?:\$\{\w+:-)?(\d+)", run))  # QUEUE_S defaults a repo variable (#63019)
        self.assertLessEqual(int(bounds["QUEUE_S"]) + 5400 + int(bounds["RUN_S"]),
                             (jobs["record"]["timeout-minutes"] - 20) * 60)
        self.assertIn('"$client" cancel', run)
        publish = jobs["publish"]
        self.assertEqual((publish["needs"], publish["environment"]), ("record", "pr-media"))
        self.assertIn("publish-auto", next(s for s in publish["steps"] if s.get("name") == "Publish the clips")["with"]["command"])

    def test_the_plan_takes_one_app_at_a_time(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo, base, head = IPhoneClipTests().repo(tmp)
            mac = clips.plan(base, head, Path(tmp, "t1"), exists=lambda url: False, root=repo, app="mac")
            phone = clips.plan(base, head, Path(tmp, "t2"), exists=lambda url: False, root=repo, app="iphone")
            self.assertEqual([r["id"] for r in mac], ["mac-thing"])
            self.assertEqual([r["id"] for r in phone], ["phone-better", "phone-new"])
            self.assertFalse(Path(tmp, "t2").exists())


if __name__ == "__main__":
    unittest.main()


class PublishedProbeTests(unittest.TestCase):
    """A failed HEAD probe never ends the plan (nightly plan 45160205493 died on one)."""

    def probe(self, *outcomes):
        import urllib.error
        calls = []

        def urlopen(request, timeout):
            calls.append(request.full_url)
            outcome = outcomes[min(len(calls), len(outcomes)) - 1]
            if isinstance(outcome, BaseException):
                raise outcome
            response = mock.MagicMock()
            response.__enter__.return_value.status = outcome
            return response
        with mock.patch("urllib.request.urlopen", urlopen), mock.patch("time.sleep"), \
                mock.patch("sys.stderr", io.StringIO()):
            return clips.published("https://x/clip.webp"), len(calls)

    def test_200_and_404(self):
        import urllib.error
        self.assertEqual(self.probe(200), (True, 1))
        self.assertEqual(self.probe(urllib.error.HTTPError("u", 404, "nf", {}, None)), (False, 1))

    def test_transient_error_is_retried(self):
        import urllib.error
        self.assertEqual(self.probe(urllib.error.HTTPError("u", 503, "x", {}, None), 200), (True, 2))
        self.assertEqual(self.probe(TimeoutError("timed out"), 200), (True, 2))

    def test_persistent_error_is_unpublished_not_a_crash(self):
        import urllib.error
        self.assertEqual(self.probe(urllib.error.URLError("reset")), (False, 3))
        self.assertEqual(self.probe(urllib.error.HTTPError("u", 500, "x", {}, None)), (False, 3))
