#!/usr/bin/env python3
"""PR media: which tours a pull request gets, what the comment says, and the workflow's trust boundary."""
from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import sys
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/pr_media.py"
WORKFLOW = ROOT / ".github/workflows/pr-media.yml"
CI = ROOT / ".github/workflows/ci.yml"
SCENARIOS = ROOT / "dogfood/scenarios"

spec = importlib.util.spec_from_file_location("pr_media", SCRIPT)
assert spec and spec.loader
media = importlib.util.module_from_spec(spec)
sys.modules["pr_media"] = media
spec.loader.exec_module(media)

HEAD = "0123456789abcdef" * 2 + "01234567"
REPO = "manaflow-ai/cmux"


def scenarios(**paths: list[str]) -> dict[str, object]:
    return {name.replace("_", "-"): {"paths": globs, "steps": [{"wait": 1}]} for name, globs in paths.items()}


class SelectToursTests(unittest.TestCase):
    def test_matching_globs_rank_by_matched_files(self) -> None:
        tours = scenarios(browser_tour=["Sources/*Browser*"], sidebar_and_chrome_tour=["Sources/*Sidebar*"])
        picked, reason = media.select_tours(
            tours, ["Sources/Panels/BrowserPanel.swift", "Sources/BrowserOmnibar.swift", "Sources/Sidebar/Row.swift"],
            body="")
        self.assertEqual(picked, ["browser-tour", "sidebar-and-chrome-tour"])
        self.assertIn("matched", reason)

    def test_no_match_takes_the_default_tour(self) -> None:
        tours = scenarios(browser_tour=["Sources/*Browser*"], sidebar_and_chrome_tour=["Sources/*Sidebar*"])
        picked, _ = media.select_tours(tours, ["Sources/TerminalController.swift"], body=None)
        self.assertEqual(picked, [media.DEFAULT_TOUR])

    def test_editing_a_tour_shows_that_tour(self) -> None:
        tours = scenarios(browser_tour=[], sidebar_and_chrome_tour=[])
        picked, _ = media.select_tours(tours, ["dogfood/scenarios/browser-tour.json"], body=None)
        self.assertEqual(picked, ["browser-tour"])

    def test_body_override_wins_and_ignores_unknown_names(self) -> None:
        tours = scenarios(browser_tour=["Sources/*"], sidebar_and_chrome_tour=[])
        body = "Summary\n\nDogfood-tours: sidebar-and-chrome-tour.json, missing-tour\n"
        picked, reason = media.select_tours(tours, ["Sources/A.swift"], body=body)
        self.assertEqual(picked, ["sidebar-and-chrome-tour"])
        self.assertIn("missing-tour", reason)

    def test_body_override_none_turns_media_off(self) -> None:
        tours = scenarios(sidebar_and_chrome_tour=["Sources/*"])
        picked, _ = media.select_tours(tours, ["Sources/A.swift"], body="dogfood-tours: none")
        self.assertEqual(picked, [])

    def test_at_most_max_tours(self) -> None:
        tours = {f"tour-{index}": {"paths": ["Sources/*"]} for index in range(6)}
        picked, _ = media.select_tours(tours, ["Sources/A.swift"], body=None)
        self.assertEqual(len(picked), media.MAX_TOURS)

    def test_checked_in_tours_are_valid_and_the_default_exists(self) -> None:
        names = set()
        for path in sorted(SCENARIOS.glob("*.json")):
            scenario = json.loads(path.read_text())
            names.add(path.stem)
            self.assertRegex(path.stem, media.TOUR_NAME.pattern)
            # A tour without `paths` is still valid (a Dogfood-tours: line or an
            # edit to its own file picks it); a present one must be globs.
            if isinstance(scenario, dict) and "paths" in scenario:
                self.assertTrue(media.tour_globs(scenario), f"{path.name} has an empty or malformed paths list")
        self.assertIn(media.DEFAULT_TOUR, names)


class RenderingTests(unittest.TestCase):
    def test_key_shots_skip_bookkeeping_and_keep_failures(self) -> None:
        names = ["00-launched", "a", "b", "c", "d", "e", "f", "07-failed", "99-final", "99-final-screen"]
        picked = media.pick_key_shots(names, limit=4)
        self.assertIn("07-failed", picked)
        self.assertEqual(len(picked), 4)
        self.assertNotIn("00-launched", picked)
        self.assertNotIn("99-final-screen", picked)
        self.assertEqual(picked, [name for name in names if name in picked])  # tour order

    def test_a_tour_without_own_shots_shows_its_final_frame(self) -> None:
        self.assertEqual(media.pick_key_shots(["00-launched", "99-final", "99-final-screen"]), ["99-final"])

    def test_shot_titles_come_from_e2e_frames(self) -> None:
        self.assertEqual(media.shot_name("capture: split-right"), "split-right")
        self.assertIsNone(media.shot_name("Click Button"))

    def test_render_writes_small_pngs_and_a_gif(self) -> None:
        try:
            from PIL import Image
        except ImportError:
            self.skipTest("Pillow is not installed")
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            shots = []
            for index, name in enumerate(["00-launched", "split", "palette", "99-final", "99-final-screen"]):
                path = root / f"{name}.jpg"
                Image.new("RGB", (960, 540), (index * 40, 90, 160)).save(path)
                shots.append((name, path))
            # A full-screen fallback shot is taller than the window shots around it.
            Image.new("RGB", (960, 700), (200, 30, 30)).save(root / "palette.jpg")
            result = media.render(shots, root / "out", "tour @ 01234567")
            self.assertEqual([shot["name"] for shot in result["shots"]], ["split", "palette"])
            self.assertEqual(result["gif"], "tour.gif")
            self.assertEqual(result["frames"], 4)
            with Image.open(root / "out/tour.gif") as gif:
                self.assertEqual(gif.n_frames, 4)
                sizes = set()
                for index in range(gif.n_frames):
                    gif.seek(index)
                    sizes.add(gif.size)
                self.assertEqual(sizes, {(720, round(700 * 720 / 960) + 28)})


class GitHubStub:
    """Answers gh_json by path prefix and records writes made through subprocess.run."""

    def __init__(self, answers: dict[str, object]) -> None:
        self.answers = answers
        self.calls: list[str] = []
        self.writes: list[list[str]] = []

    def __call__(self, args, **_):
        self.calls.append(args[0])
        for prefix, answer in self.answers.items():
            if args[0].startswith(prefix):
                return answer() if callable(answer) else answer
        return None


class StubbedTest(unittest.TestCase):
    def stub(self, answers: dict[str, object]) -> GitHubStub:
        stub = GitHubStub(answers)
        original_json, original_run = media.gh_json, media.subprocess.run
        media.gh_json = stub

        class Done:
            returncode, stdout, stderr = 0, "", ""

        def run(args, **_):
            stub.writes.append(args)
            return Done()

        media.subprocess.run = run
        self.addCleanup(setattr, media, "gh_json", original_json)
        self.addCleanup(setattr, media.subprocess, "run", original_run)
        return stub


class GateTests(StubbedTest):
    JOBS = "repos/o/r/actions/runs/9/attempts/1/jobs"

    def gate(self, jobs: list[dict], run_status: str = "in_progress") -> str:
        self.stub({self.JOBS: {"jobs": jobs}, "repos/o/r/actions/runs/9": {"status": run_status}})
        return media.app_build_gate("o/r", "9", "1", 42, sleep=lambda _: None)

    def test_an_app_pull_request_with_a_macos_build_passes(self) -> None:
        jobs = [{"name": "Dogfood build #42", "status": "completed", "conclusion": "success"},
                {"name": "macos / macOS compile admission", "status": "in_progress", "conclusion": None}]
        self.assertEqual(self.gate(jobs), media.BUILT)

    def test_media_waits_for_a_successful_dogfood_comment(self) -> None:
        admission = {"name": "macos / macOS compile admission", "status": "in_progress", "conclusion": None}
        self.assertEqual(self.gate([{"name": "Dogfood build #42", "status": "completed", "conclusion": "failure"},
                                    admission]), media.NO_BUILD)
        self.assertEqual(self.gate([{"name": "Dogfood build #42", "status": "in_progress", "conclusion": None},
                                    admission], run_status="completed"), media.NO_BUILD)

    def test_a_skipped_macos_caller_reuses_an_earlier_build(self) -> None:
        jobs = [{"name": "Dogfood build #42", "status": "completed", "conclusion": "success"},
                {"name": "macos", "status": "completed", "conclusion": "skipped"}]
        self.assertEqual(self.gate(jobs), media.REUSED)  # at once, though the run is still going

    def test_a_skipped_dogfood_job_means_no_app_change(self) -> None:
        self.assertEqual(self.gate([{"name": "Dogfood build #42", "status": "completed", "conclusion": "skipped"}]),
                         media.NO_BUILD)

    def test_a_cli_only_pull_request_compiles_no_app(self) -> None:
        jobs = [{"name": "Dogfood build #42", "status": "completed", "conclusion": "success"}]
        self.assertEqual(self.gate(jobs, run_status="completed"), media.NO_BUILD)

    def test_a_skipped_admission_leaves_the_fingerprint_lookup_to_decide(self) -> None:
        jobs = [{"name": "Dogfood build #42", "status": "completed", "conclusion": "success"},
                {"name": "macos / macOS compile admission", "status": "completed", "conclusion": "skipped"}]
        self.assertEqual(self.gate(jobs), media.REUSED)


class AdmittedBuildTests(StubbedTest):
    def test_a_tour_only_push_loads_the_earlier_build_of_the_same_inputs(self) -> None:
        earlier = "c" * 40
        runs = {"workflow_runs": [
            {"id": 9, "head_repository": {"full_name": "o/r"}},
            {"id": 8, "head_repository": {"full_name": "o/r"}, "html_url": "https://github.com/o/r/actions/runs/8"}]}
        self.stub({
            "repos/o/r/actions/runs/9/artifacts?per_page": {"artifacts": [{"name": "build-inputs-fp1-1"}]},
            "repos/o/r/actions/workflows/ci.yml/runs": runs,
            "repos/o/r/actions/runs/8/jobs": {"jobs": [
                {"name": "macos / macOS compile admission", "run_attempt": 1, "status": "completed",
                 "conclusion": "success"}]},
            "repos/o/r/actions/runs/8/artifacts?name=build-inputs-fp1-1": {"total_count": 1},
            "repos/o/r/actions/runs/8": {"id": 8, "head_sha": earlier},
        })
        found = media.admitted_build_run("o/r", {"id": 9, "head_branch": "topic"}, "1")
        self.assertEqual(found.get("head_sha"), earlier)

    def test_no_fingerprint_means_no_earlier_build(self) -> None:
        self.stub({"repos/o/r/actions/runs/9/artifacts": {"artifacts": []}})
        self.assertEqual(media.admitted_build_run("o/r", {"id": 9, "head_branch": "topic"}, "1"), {})

    def test_only_this_attempts_fingerprint_counts(self) -> None:
        stub = self.stub({"repos/o/r/actions/runs/9/artifacts": {"artifacts": [{"name": "build-inputs-fp1-1"}]}})
        self.assertEqual(media.admitted_build_run("o/r", {"id": 9, "head_branch": "t"}, "2"), {})
        self.assertFalse([call for call in stub.calls if "workflows/ci.yml/runs" in call])

    def test_an_api_error_in_the_lookup_means_no_earlier_build(self) -> None:
        def refuse():
            raise RuntimeError("HTTP 403")

        self.stub({"repos/o/r/actions/runs/9/artifacts": {"artifacts": [{"name": "build-inputs-fp1-1"}]},
                   "repos/o/r/actions/workflows/ci.yml/runs": refuse})
        self.assertEqual(media.admitted_build_run("o/r", {"id": 9, "head_branch": "topic"}, "1"), {})

    def test_the_section_names_the_build_the_tour_loaded(self) -> None:
        manifest = {"tour": "t", "result": "passed", "build_sha": "c" * 40, "run_url": "https://x"}
        self.assertIn(f"on the app CI built for `{'c' * 8}`", media.section("o/r", 1, HEAD, [manifest]))


class PlanTests(StubbedTest):
    EARLIER = "c" * 40

    def plan(self, answers: dict[str, object], env: dict[str, str]) -> dict[str, str]:
        import os
        import tempfile
        self.stub({"repos/o/r/pulls/42/files": [[{"filename": "Sources/App.swift"}]],
                   "repos/o/r/pulls/42": {"head": {"sha": HEAD, "repo": {"full_name": "o/r"}}, "body": ""},
                   **answers})
        original = media.head_scenarios
        media.head_scenarios = lambda _sha: scenarios(sidebar_and_chrome_tour=["Sources/**"])
        self.addCleanup(setattr, media, "head_scenarios", original)
        with tempfile.NamedTemporaryFile("r", suffix=".out") as out:
            keys = {"GITHUB_OUTPUT": out.name, "PR": "42", "SOURCE_RUN_ID": "", **env}
            saved = {key: os.environ.get(key) for key in keys}
            os.environ.update(keys)
            try:
                media.plan("o/r")
            finally:
                for key, value in saved.items():
                    os.environ.pop(key, None) if value is None else os.environ.__setitem__(key, value)
            return dict(line.split("=", 1) for line in out.read().splitlines())

    def test_a_manual_dispatch_without_a_ci_run_still_tours_the_head(self) -> None:
        outputs = self.plan({"repos/o/r/actions/workflows/ci.yml/runs": {"workflow_runs": []}}, {})
        self.assertEqual(outputs["build_sha"], HEAD)
        self.assertEqual(json.loads(outputs["run"]), ["sidebar-and-chrome-tour"])

    def test_a_tour_only_push_tours_the_earlier_build(self) -> None:
        run = {"id": 9, "run_attempt": 1, "head_sha": HEAD, "head_branch": "topic", "event": "pull_request",
               "path": media.CI_WORKFLOW_PATH, "head_repository": {"full_name": "o/r"},
               "pull_requests": [{"number": 42}], "status": "completed"}
        original = media.admitted_build_run
        media.admitted_build_run = lambda _repo, _run, _attempt: {"head_sha": self.EARLIER}
        self.addCleanup(setattr, media, "admitted_build_run", original)
        outputs = self.plan({
            "repos/o/r/actions/runs/9/attempts/1/jobs": {"jobs": [
                {"name": "Dogfood build #42", "status": "completed", "conclusion": "success"},
                {"name": "macos", "status": "completed", "conclusion": "skipped"}]},
            "repos/o/r/actions/runs/9": run}, {"SOURCE_RUN_ID": "9", "SOURCE_RUN_ATTEMPT": "1"})
        self.assertEqual(outputs["build_sha"], self.EARLIER)

    def test_an_automatic_run_without_a_build_tours_nothing(self) -> None:
        run = {"id": 9, "run_attempt": 1, "head_sha": HEAD, "event": "pull_request", "status": "completed",
               "path": media.CI_WORKFLOW_PATH, "head_repository": {"full_name": "o/r"},
               "pull_requests": [{"number": 42}]}
        outputs = self.plan({
            "repos/o/r/actions/runs/9/attempts/1/jobs": {"jobs": [
                {"name": "Dogfood build #42", "status": "completed", "conclusion": "skipped"}]},
            "repos/o/r/actions/runs/9": run}, {"SOURCE_RUN_ID": "9", "SOURCE_RUN_ATTEMPT": "1"})
        self.assertEqual(outputs["run"], "[]")


class CacheAndMergeTests(StubbedTest):
    def test_only_a_tour_that_ran_counts_as_published(self) -> None:
        import base64
        def content(manifest: dict) -> dict:
            return {"content": base64.b64encode(json.dumps(manifest).encode()).decode()}
        self.stub({"repos/o/r/contents/": content({"tour": "t", "result": "not run"})})
        self.assertIsNone(media.published("o/r", 1, HEAD, "t"))
        self.stub({"repos/o/r/contents/": content({"tour": "t", "run_url": "https://x"})})
        self.assertEqual(media.published("o/r", 1, HEAD, "t")["run_url"], "https://x")

    def test_built_merge_reads_the_merge_ci_checked_out(self) -> None:
        merge = "b" * 40
        run = {"referenced_workflows": [{"ref": "refs/pull/7/merge", "sha": merge},
                                        {"ref": "refs/heads/main", "sha": "c" * 40}]}
        self.assertEqual(media.built_merge(run), merge)
        self.assertEqual(media.built_merge({"referenced_workflows": []}), "")


class UploaderTests(unittest.TestCase):
    def test_uploads_go_through_the_pr_media_tool(self) -> None:
        import inspect
        tool = media.uploader()
        self.assertEqual(list(inspect.signature(tool.put_file).parameters)[:5],
                         ["repo", "branch", "path", "local", "message"])
        self.assertLess(media.GIF_MAX_BYTES, tool.INLINE_MAX_BYTES)


class RefusedTests(StubbedTest):
    def test_a_run_that_refused_to_compile_is_recognised(self) -> None:
        step = {"name": media.REFUSE_STEP, "conclusion": "failure"}
        self.stub({"repos/o/r/actions/runs/3/jobs": {"jobs": [{"name": "build", "steps": [step]}]}})
        self.assertTrue(media.refused_to_compile("o/r", "3"))
        self.stub({"repos/o/r/actions/runs/3/jobs": {"jobs": [{"name": "build", "steps": [{**step, "conclusion": "skipped"}]}]}})
        self.assertFalse(media.refused_to_compile("o/r", "3"))

    def test_the_step_name_matches_test_e2e(self) -> None:
        self.assertIn(f"- name: {media.REFUSE_STEP}", (ROOT / ".github/workflows/test-e2e.yml").read_text())


class UploadRetryTests(unittest.TestCase):
    def test_a_lost_race_is_retried(self) -> None:
        calls = []

        class Tool:
            MediaError = RuntimeError

            @staticmethod
            def put_file(*args):
                calls.append(args)
                if len(calls) < 3:
                    raise RuntimeError("409")

        media.upload(Tool, "o/r", "1/x/t/a.png", Path("a.png"), "m", sleep=lambda _: None)
        self.assertEqual(len(calls), 3)


class TourCacheTests(StubbedTest):
    def run_tour(self, conclusion: str, media_made: dict) -> dict:
        import tempfile
        self.stub({})

        class FakeDispatch:
            def __init__(self, repository):
                self.run_id, self.tested = "7", None

            def start(self, command):
                return 0

            def cancel(self, *_):
                pass

            def wait(self):
                return {"conclusion": conclusion}

        originals = (media.Dispatch, media.refused_to_compile, media.tour_media)
        media.Dispatch = FakeDispatch
        media.refused_to_compile = lambda *_: False
        media.tour_media = lambda *_: media_made
        self.addCleanup(lambda: (setattr(media, "Dispatch", originals[0]),
                                 setattr(media, "refused_to_compile", originals[1]),
                                 setattr(media, "tour_media", originals[2])))
        import signal
        for signum in (signal.SIGINT, signal.SIGTERM):
            self.addCleanup(signal.signal, signum, signal.getsignal(signum))
        with tempfile.TemporaryDirectory() as tmp:
            media.tour("o/r", "t", Path(tmp) / "s.json", HEAD, Path(tmp) / "out", False)
            return json.loads((Path(tmp) / "out/manifest.json").read_text())

    def test_only_a_verdict_with_media_is_cached(self) -> None:
        made = {"gif": "tour.gif", "shots": [], "failures": []}
        self.assertIn("run_url", self.run_tour("success", made))
        self.assertIn("run_url", self.run_tour("failure", made))
        for conclusion, found in (("cancelled", made), ("success", {"shots": [], "note": "no frames"})):
            with self.subTest(conclusion=conclusion):
                manifest = self.run_tour(conclusion, found)
                self.assertNotIn("run_url", manifest)
                self.assertIn("log_url", manifest)


class PublishTests(StubbedTest):
    def comment(self, body: str) -> list[list[dict]]:
        return [[{"id": 5, "user": {"login": "github-actions[bot]"}, "body": body}]]

    def publish(self, tmp: Path, head: str, comments, **extra) -> GitHubStub:
        folder = tmp / "sidebar-and-chrome-tour"
        folder.mkdir()
        (folder / "tour.gif").write_bytes(b"GIF89a")
        (folder / "manifest.json").write_text(json.dumps(
            {"tour": "sidebar-and-chrome-tour", "result": "not run", "note": "skipped", "gif": "tour.gif", "shots": [],
             **extra}))
        stub = self.stub({"repos/o/r/pulls/1": {"head": {"sha": head}}, "repos/o/r/issues/1/comments": comments})
        stub.uploads = []

        class Tool:
            MediaError = RuntimeError

            @staticmethod
            def put_file(repo, branch, path, local, message):
                stub.uploads.append((repo, branch, path, local.read_bytes()))

        original = media.uploader
        media.uploader = lambda: Tool
        self.addCleanup(setattr, media, "uploader", original)
        media.publish("o/r", 1, HEAD, ["sidebar-and-chrome-tour"], tmp)
        return stub

    def test_a_tour_that_did_not_run_uploads_no_manifest_but_still_shows_its_note(self) -> None:
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            stub = self.publish(Path(tmp), HEAD, self.comment(f"{media.DOGFOOD_MARKER}\nof `{HEAD}`"),
                                log_url="https://x/runs/1")
        uploaded = [path for _, _, path, _ in stub.uploads]
        self.assertEqual(uploaded, [f"1/{HEAD[:8]}/sidebar-and-chrome-tour/tour.gif"])
        self.assertEqual({branch for _, branch, _, _ in stub.uploads}, {"pr-media"})
        self.assertTrue(any(w[:4] == ["gh", "api", "-X", "PATCH"] for w in stub.writes))

    def test_a_tour_that_never_dispatched_stays_out_of_the_comment(self) -> None:
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            stub = self.publish(Path(tmp), HEAD, self.comment(f"{media.DOGFOOD_MARKER}\nof `{HEAD}`"))
        self.assertFalse(any(w[:4] == ["gh", "api", "-X", "PATCH"] for w in stub.writes))

    def test_a_moved_head_or_a_comment_for_another_head_is_left_alone(self) -> None:
        import tempfile
        for head, body in (("f" * 40, f"of `{HEAD}`"), (HEAD, f"of `{'e' * 40}`")):
            with self.subTest(head=head[:4]), tempfile.TemporaryDirectory() as tmp:
                stub = self.publish(Path(tmp), head, self.comment(f"{media.DOGFOOD_MARKER}\n{body}"))
                self.assertFalse(any(w[:4] == ["gh", "api", "-X", "PATCH"] for w in stub.writes))
                self.assertFalse(any(w[:4] == ["gh", "api", "-X", "POST"] for w in stub.writes))


class CommentTests(unittest.TestCase):
    def manifest(self) -> dict:
        return {"tour": "sidebar-and-chrome-tour", "head_sha": HEAD, "result": "passed",
                "run_url": "https://github.com/manaflow-ai/cmux/actions/runs/1", "gif": "tour.gif",
                "shots": [{"name": "split-right", "file": "split-right.png"}]}

    def test_section_embeds_raw_urls_labelled_with_tour_and_sha(self) -> None:
        text = media.section(REPO, 42, HEAD, [self.manifest()])
        base = f"https://raw.githubusercontent.com/{REPO}/pr-media/42/{HEAD[:8]}/sidebar-and-chrome-tour"
        self.assertIn(f'src="{base}/tour.gif"', text)
        self.assertIn(f'src="{base}/split-right.png"', text)
        self.assertIn(f"sidebar-and-chrome-tour split-right at {HEAD[:8]}", text)
        self.assertTrue(text.startswith(media.SECTION_START) and text.endswith(media.SECTION_END))
        self.assertNotIn("—", text)

    def test_merge_section_replaces_in_place_and_keeps_the_dogfood_link(self) -> None:
        body = f"{media.DOGFOOD_MARKER}\n**Dogfood build** of `x`\n"
        once = media.merge_section(body, media.section(REPO, 42, HEAD, [self.manifest()]))
        twice = media.merge_section(once, media.section(REPO, 42, HEAD, [{**self.manifest(), "result": "failure"}]))
        self.assertTrue(twice.startswith(body.rstrip()))
        self.assertEqual(twice.count(media.SECTION_START), 1)
        self.assertIn("failure", twice)

    def test_override_line_parsing(self) -> None:
        self.assertIsNone(media.parse_override("no line here"))
        self.assertEqual(media.parse_override("Dogfood-tours: a b,c"), ["a", "b", "c"])
        self.assertEqual(media.parse_override("DOGFOOD-TOURS: None"), [])


class WorkflowTests(unittest.TestCase):
    def test_trust_boundary(self) -> None:
        document = yaml.safe_load(WORKFLOW.read_text())
        self.assertEqual(document["permissions"], {})
        self.assertEqual(document[True]["workflow_run"]["workflows"], ["CI"])
        jobs = document["jobs"]
        for job in jobs.values():
            for step in job["steps"]:
                checkout = step.get("uses", "").startswith("actions/checkout@")
                if checkout:
                    self.assertEqual(step["with"]["ref"], "${{ github.event.repository.default_branch }}")
                    self.assertIs(step["with"]["persist-credentials"], False)
                # Values from the pull request reach scripts only through the environment.
                self.assertNotIn("needs.plan.outputs", str(step.get("run", "")))
                self.assertNotIn("matrix.tour", str(step.get("run", "")))
        self.assertNotIn("contents", {k for k, v in jobs["tour"]["permissions"].items() if v == "write"})
        self.assertEqual(jobs["publish"]["permissions"], {"contents": "write", "pull-requests": "write"})
        self.assertIn("head_repository.full_name == github.repository", jobs["plan"]["if"])
        tour_step = next(step for step in jobs["tour"]["steps"] if "pr_media.py tour" in step.get("run", ""))
        self.assertTrue(tour_step["run"].startswith("exec "), tour_step["run"])

    def test_gate_names_the_dogfood_job(self) -> None:
        name = yaml.safe_load(CI.read_text())["jobs"]["dogfood-build"]["name"]
        self.assertTrue(name.startswith(media.DOGFOOD_JOB_PREFIX), name)
        self.assertIn(media.DOGFOOD_MARKER, CI.read_text())

    def test_media_is_never_part_of_the_ci_verdict(self) -> None:
        self.assertNotIn("pr-media", CI.read_text())


class AdoptOnlyTests(unittest.TestCase):
    def test_adopts_on_matches_the_product_family(self) -> None:
        spec = importlib.util.spec_from_file_location("focused_dispatch_for_media", ROOT / "scripts/ci/dispatch-focused-test.py")
        assert spec and spec.loader
        sys.path.insert(0, str(ROOT / "scripts/ci"))
        dispatch = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(dispatch)
        self.assertTrue(dispatch.adopts_on("blacksmith-12vcpu-macos-26", "blacksmith-6vcpu-macos-26"))
        self.assertFalse(dispatch.adopts_on("glaeda-std-xcode-26.6", "blacksmith-6vcpu-macos-26"))
        self.assertTrue(dispatch.adopts_on("glaeda-std-xcode-26.6", "glaeda-std-xcode-26.6"))
        self.assertFalse(dispatch.adopts_on(None, "glaeda-std-xcode-26.6"))
        self.assertEqual(dispatch.NO_PRODUCT_EXIT, media.NO_PRODUCT_EXIT)


if __name__ == "__main__":
    unittest.main()
