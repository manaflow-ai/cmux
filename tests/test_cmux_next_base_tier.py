#!/usr/bin/env python3
"""feat-cmux-next's base Mac tier runs at most once every 15 minutes, on the tip (cmuxterm-hq#5424).

Leo (2026-10-30): "do we REALLY need to be compiling/testing THAT often...?" A feat-cmux-next push ran
daemon tests, generated files and the Debug app scheme compile on every landing (557 a day, a median
1.4 minutes apart). A push now leaves those three to `cmux-next base tier · <tip>`, which
cmux-next-base-tier-kick.yml dispatches at most once per window (scripts/ci/cmux_next_base_tier.py).
The Release compiles, the DEV landing compile and the fast tier stay on every push.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import cmux_next_base_tier as tier  # noqa: E402

WORKFLOW = ROOT / ".github/workflows/cmux-next.yml"
KICK = ROOT / ".github/workflows/cmux-next-base-tier-kick.yml"
REPO = "manaflow-ai/cmux"
OLD, MID, TIP = "a" * 40, "b" * 40, "c" * 40
T0 = 1_800_000_000.0


def stamp(at: float) -> str:
    import datetime as dt
    return dt.datetime.fromtimestamp(at, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class FakeApi:
    def __init__(self, runs: list[tuple[str, float]], tip: str, files: list[str] | None = None,
                 compare_error: bool = False, dispatch_status: int = 204):
        self.runs = [{"display_title": f"{tier.TITLE}{sha}", "created_at": stamp(at)} for sha, at in runs]
        self.runs.append({"display_title": f"cmux NEXT DEV daily · {OLD}", "created_at": stamp(T0)})
        self.tip = tip
        self.files = files if files is not None else ["Packages/macOS/CmuxNext/Sources/CmuxNextApp/App.swift"]
        self.compare_error = compare_error
        self.dispatch_status = dispatch_status
        self.dispatched: list[tuple[str, dict]] = []
        self.cancelled: list[int] = []
        self.landed: str | None = None  # a commit that lands between the tip read and the dispatch
        self.jobs: dict[int, list[dict]] = {}
        self.gets: list[str] = []

    def open_run(self, run_id: int, sha: str, at: float, status: str = "queued",
                 jobs: list[dict] | None = None, title: str = tier.TITLE) -> None:
        """A listed run with an id and a status, and its jobs (None: its job list cannot be read)."""
        self.runs.insert(0, {"id": run_id, "status": status, "display_title": f"{title}{sha}",
                             "created_at": stamp(at)})
        if jobs is not None:
            self.jobs[run_id] = jobs

    def get(self, path: str):
        self.gets.append(path)
        if "/actions/workflows/cmux-next.yml/runs?" in path:
            return {"workflow_runs": self.runs}
        if (match := re.search(r"/actions/runs/(\d+)/jobs\?", path)):
            jobs = self.jobs.get(int(match.group(1)))
            if jobs is None:
                raise RuntimeError("HTTP 502")
            return {"jobs": jobs}
        if path.endswith(f"/git/ref/heads/{tier.BRANCH}"):
            return {"object": {"sha": self.tip}}
        if "/compare/" in path:
            if self.compare_error:
                raise RuntimeError("HTTP 502")
            return {"status": "ahead", "files": [{"filename": name} for name in self.files]}
        raise AssertionError(path)

    def post(self, path: str, body: dict) -> int:
        if (match := re.fullmatch(rf"repos/{REPO}/actions/runs/(\d+)/cancel", path)):
            self.cancelled.append(int(match.group(1)))
            return 202
        self.dispatched.append((path, body))
        if self.dispatch_status == 204:
            # The run the dispatch starts, titled with the branch tip when GitHub took it.
            self.runs.insert(0, {"id": 99, "status": "queued", "display_title": f"{tier.TITLE}{self.landed or self.tip}",
                                 "created_at": stamp(T0 + 10**6)})
        return self.dispatch_status


class Clock:
    def __init__(self, at: float):
        self.at = at
        self.slept: list[float] = []
        self.during_wait = lambda: None  # landings or dispatches that happen while a kick waits

    def now(self) -> float:
        return self.at

    def sleep(self, seconds: float) -> None:
        self.slept.append(seconds)
        self.at += seconds
        self.during_wait()


def kick(api: FakeApi, clock: Clock, patterns: list[str] | None = None):
    patterns = tier.push_paths(WORKFLOW.read_text()) if patterns is None else patterns
    return tier.kick(api, REPO, patterns, now=clock.now, sleep=clock.sleep, log=lambda _: None)


def job(name: str, status: str, conclusion: str | None = None) -> dict:
    return {"name": name, "status": status, "conclusion": conclusion}


QUEUED_MAC = [job("cmux-next path routing", "completed", "success"), job("cmux-next daemon tests", "queued"),
              job("cmux-next generated files", "queued"), job("cmux app scheme compile (Debug)", "queued")]


class CancelSuperseded(unittest.TestCase):
    """Once the tip has a base tier run, older ones whose Mac jobs never started are cancelled."""

    def test_a_dispatch_cancels_older_runs_waiting_for_a_mac(self):
        api, clock = FakeApi([(OLD, T0)], TIP), Clock(T0 + 20 * 60)
        api.open_run(11, OLD, T0, "in_progress", QUEUED_MAC)
        api.open_run(12, MID, T0 + 5 * 60, "queued", [])
        self.assertEqual(kick(api, clock), TIP)
        self.assertEqual(len(api.dispatched), 1)
        self.assertEqual(sorted(api.cancelled), [11, 12])

    def test_a_run_titled_with_a_commit_that_landed_after_the_tip_read_is_kept(self):
        # The dispatch takes the branch ref, so its run may name a newer commit than the tip read.
        api, clock = FakeApi([(OLD, T0)], TIP), Clock(T0 + 20 * 60)
        api.landed = "d" * 40
        api.jobs[99] = QUEUED_MAC
        api.open_run(11, OLD, T0, "queued", QUEUED_MAC)
        self.assertEqual(kick(api, clock), TIP)
        self.assertEqual(api.cancelled, [11])

    def test_a_re_run_is_left_alone(self):
        # An earlier attempt may have run its Mac jobs; the latest attempt's list would not show them.
        api, clock = FakeApi([(OLD, T0)], TIP), Clock(T0 + 20 * 60)
        api.open_run(11, OLD, T0, "queued", QUEUED_MAC)
        api.runs[0]["run_attempt"] = 2
        kick(api, clock)
        self.assertEqual(api.cancelled, [])

    def test_a_tip_that_already_has_a_run_still_cancels_the_older_waiting_ones(self):
        # A hand dispatch on the tip leaves the older waiting runs to the next kick.
        api, clock = FakeApi([(TIP, T0)], TIP), Clock(T0 + 20 * 60)
        api.open_run(11, OLD, T0 - 60, "queued", QUEUED_MAC)
        self.assertIsNone(kick(api, clock))
        self.assertEqual(api.dispatched, [])
        self.assertEqual(api.cancelled, [11])

    def test_a_run_whose_mac_job_started_or_finished_is_left_alone(self):
        api, clock = FakeApi([(OLD, T0)], TIP), Clock(T0 + 20 * 60)
        running = [job("cmux-next daemon tests", "in_progress")] + QUEUED_MAC[2:]
        finished = [job("cmux-next generated files", "completed", "failure"), job("cmux-next daemon tests", "queued")]
        api.open_run(11, OLD, T0, "in_progress", running)
        api.open_run(12, MID, T0 + 60, "in_progress", finished)
        kick(api, clock)
        self.assertEqual(api.cancelled, [])

    def test_skipped_or_cancelled_mac_jobs_never_started(self):
        api, clock = FakeApi([(OLD, T0)], TIP), Clock(T0 + 20 * 60)
        api.open_run(11, OLD, T0, "in_progress", [job("cmux app scheme compile (Debug)", "completed", "skipped"),
                                                   job("cmux-next daemon tests", "completed", "cancelled"),
                                                   job("cmux-next generated files", "queued")])
        kick(api, clock)
        self.assertEqual(api.cancelled, [11])

    def test_an_unreadable_job_list_counts_as_started(self):
        api, clock = FakeApi([(OLD, T0)], TIP), Clock(T0 + 20 * 60)
        api.open_run(11, OLD, T0, "queued", None)
        kick(api, clock)
        self.assertEqual(api.cancelled, [])

    def test_the_tips_own_runs_finished_runs_and_other_titles_are_never_cancelled(self):
        api, clock = FakeApi([(TIP, T0)], TIP), Clock(T0 + 20 * 60)
        api.open_run(11, TIP, T0 + 60, "queued", QUEUED_MAC)  # the tip's same-tree run
        api.open_run(12, OLD, T0 - 60, "completed", QUEUED_MAC)
        api.open_run(13, OLD, T0 - 60, "queued", QUEUED_MAC, title="cmux NEXT DEV daily · ")
        api.open_run(14, OLD, T0 - 60, "queued", QUEUED_MAC, title="cmux-next tip daemon suite · ")
        kick(api, clock)
        self.assertEqual(api.cancelled, [])

    def test_no_dispatch_cancels_nothing(self):
        # Not due (no cmux-next push path changed): the last run is the newest verdict and stays.
        api = FakeApi([(OLD, T0)], TIP, files=["README.md"])
        api.open_run(11, OLD, T0, "queued", QUEUED_MAC)
        self.assertIsNone(kick(api, Clock(T0 + 20 * 60)))
        self.assertEqual(api.cancelled, [])

    def test_mac_jobs_are_the_base_tier_jobs_of_cmux_next(self):
        jobs = yaml.safe_load(WORKFLOW.read_text())["jobs"]
        names = {jobs["daemon-test"]["name"], jobs["generated-files"]["name"]}
        self.assertEqual(names | {"cmux app scheme compile (Debug)"}, set(tier.MAC_JOBS))
        # The scheme compile's name outside the DEV daily (the base tier is never a DEV daily).
        self.assertIn("|| 'cmux app scheme compile (Debug)' }}", jobs["cmux-scheme-compile"]["name"])


class Kick(unittest.TestCase):
    def test_a_landing_with_the_window_open_is_dispatched_at_once(self):
        api, clock = FakeApi([(OLD, T0)], TIP), Clock(T0 + 20 * 60)
        self.assertEqual(kick(api, clock), TIP)
        [(path, body)] = api.dispatched
        self.assertEqual(path, f"repos/{REPO}/actions/workflows/cmux-next.yml/dispatches")
        self.assertEqual(body, {"ref": "refs/heads/feat-cmux-next", "inputs": {"base_tier": "true"}})
        # No wait before the dispatch; only the settle after it, so the next kick lists the new run.
        self.assertEqual(clock.slept, [tier.SETTLE_S])

    def test_a_landing_inside_the_window_waits_once_and_takes_the_tip_then(self):
        api, clock = FakeApi([(OLD, T0)], MID), Clock(T0 + 5 * 60)

        clock.during_wait = lambda: setattr(api, "tip", TIP)  # landings during the wait

        self.assertEqual(tier.kick(api, REPO, ["Packages/**"], now=clock.now, sleep=clock.sleep, log=lambda _: None), TIP)
        self.assertEqual(clock.slept[0], 10 * 60)
        self.assertEqual(len(api.dispatched), 1)

    def test_a_new_base_tier_run_while_waiting_owns_its_full_window(self):
        # A hand dispatch can start while this kick sleeps. The first run's
        # deadline must never let a second Mac tier start inside the new window.
        # The older run still waits for a Mac: the new run supersedes it, so it is
        # cancelled even though this kick dispatches nothing.
        api, clock = FakeApi([], TIP), Clock(T0 + 5 * 60)
        api.open_run(11, OLD, T0, "queued", QUEUED_MAC)

        clock.during_wait = lambda: api.open_run(12, MID, T0 + 12 * 60, "queued", QUEUED_MAC)

        self.assertIsNone(tier.kick(api, REPO, ["Packages/**"], now=clock.now,
                                    sleep=clock.sleep, log=lambda _: None))
        self.assertEqual(clock.slept, [10 * 60])
        self.assertEqual(api.dispatched, [])
        self.assertEqual(api.cancelled, [11])
        self.assertEqual(sum("/actions/workflows/cmux-next.yml/runs?" in p for p in api.gets), 3)

    def test_a_kick_never_waits_longer_than_the_window(self):
        # A clock behind the run's created_at (skew) still waits at most one window.
        api, clock = FakeApi([(OLD, T0)], TIP), Clock(T0 - 3600)
        kick(api, clock)
        self.assertEqual(clock.slept[0], tier.WINDOW_S)

    def test_a_skewed_clock_still_dispatches_after_the_capped_wait(self):
        # The run seen before the sleep is not a new run: a clock still behind its
        # created_at after the capped wait must dispatch, not return (that starved
        # the base tier on every kick).
        api, clock = FakeApi([(OLD, T0)], TIP), Clock(T0 - 3600)
        self.assertEqual(kick(api, clock), TIP)
        self.assertEqual(clock.slept[0], tier.WINDOW_S)
        self.assertEqual(len(api.dispatched), 1)

    def test_a_tip_that_already_has_a_base_tier_run_is_left_alone(self):
        api, clock = FakeApi([(TIP, T0)], TIP), Clock(T0 + 20 * 60)
        self.assertIsNone(kick(api, clock))
        self.assertEqual(api.dispatched, [])

    def test_a_tip_whose_landings_change_no_cmux_next_push_path_is_left_alone(self):
        # The same paths that start a cmux-next push run: a docs-only burst runs no base tier.
        api = FakeApi([(OLD, T0)], TIP, files=["README.md", "docs/blog/post.md"])
        self.assertIsNone(kick(api, Clock(T0 + 20 * 60)))
        self.assertEqual(api.dispatched, [])

    def test_an_unreadable_compare_runs_the_base_tier(self):
        api = FakeApi([(OLD, T0)], TIP, compare_error=True)
        self.assertEqual(kick(api, Clock(T0 + 20 * 60)), TIP)

    def test_no_earlier_base_tier_run_dispatches_at_once(self):
        api, clock = FakeApi([], TIP), Clock(T0)
        self.assertEqual(kick(api, clock), TIP)
        self.assertFalse([path for path in api.gets if "/compare/" in path])

    def test_the_first_run_of_a_commit_counts_not_its_same_tree_run(self):
        # A same-tree run of OLD, created later, carries the same name: the window starts at the first.
        api, clock = FakeApi([(OLD, T0), (OLD, T0 + 12 * 60)], TIP), Clock(T0 + 16 * 60)
        kick(api, clock)
        self.assertEqual(clock.slept, [tier.SETTLE_S])

    def test_a_refused_dispatch_fails_the_kick(self):
        with self.assertRaisesRegex(RuntimeError, "HTTP 403"):
            kick(FakeApi([(OLD, T0)], TIP, dispatch_status=403), Clock(T0 + 20 * 60))


class PushPaths(unittest.TestCase):
    def test_it_reads_cmux_next_push_paths(self):
        patterns = tier.push_paths(WORKFLOW.read_text())
        on = yaml.safe_load(WORKFLOW.read_text()).get(True) or {}
        self.assertEqual(patterns, on["push"]["paths"])

    def test_globs_match_like_github_path_filters(self):
        self.assertTrue(tier.matches("Packages/macOS/CmuxNext/Sources/A/B.swift", ["Packages/macOS/CmuxNext/**"]))
        self.assertTrue(tier.matches("scripts/ci/x.py", ["scripts/ci/*.py"]))
        self.assertFalse(tier.matches("scripts/ci/sub/x.py", ["scripts/ci/*.py"]))
        self.assertTrue(tier.matches("a/b/c.swift", ["**/*.swift"]))
        self.assertTrue(tier.matches("c.swift", ["**/*.swift"]))
        self.assertFalse(tier.matches("docs/a.md", ["docs/**", "!docs/*.md"]))
        self.assertTrue(tier.matches("docs/a.md", ["!docs/*.md", "docs/**"]))


class Defer(unittest.TestCase):
    ROUTED = ["native=true", "macos=true", "scheme=true", "generated=true", "swift=false", "daemon=true",
              "fast_tier=true", "swift_targets="]

    def test_a_push_leaves_only_the_base_tier_to_the_kick(self):
        out = dict(line.split("=", 1) for line in tier.defer(self.ROUTED))
        self.assertEqual((out["daemon"], out["scheme"], out["generated"]), ("false", "false", "false"))
        # The Release compiles (native), the Mac placement and the fast tier still run on the push.
        self.assertEqual((out["native"], out["macos"], out["fast_tier"]), ("true", "true", "true"))
        self.assertEqual(out["base_tier"], "deferred")
        self.assertEqual(out["base_tier_deferred"], "scheme,generated,daemon")

    def test_the_scheme_compile_stays_when_it_is_the_dev_landing_build(self):
        out = dict(line.split("=", 1) for line in tier.defer(self.ROUTED, ("scheme",)))
        self.assertEqual((out["daemon"], out["scheme"], out["generated"]), ("false", "true", "false"))


def route_step() -> dict:
    steps = yaml.safe_load(WORKFLOW.read_text())["jobs"]["path_route"]["steps"]
    return next(step for step in steps if step.get("id") == "route")


class RouteStep(unittest.TestCase):
    """path_route's route step, run with a stub router: what a push and a base tier dispatch route."""

    def run_step(self, event: str, **env: str) -> dict[str, str]:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "scripts/ci").mkdir(parents=True)
            shutil.copy(ROOT / "scripts/ci/cmux_next_base_tier.py", root / "scripts/ci/")
            shutil.copy(ROOT / "scripts/ci/cmux_next_tree_notify.py", root / "scripts/ci/")
            (root / "scripts/ci/cmux_next_route.py").write_text(
                "import sys\nout = sys.argv[sys.argv.index('--github-output') + 1]\n"
                "open(out, 'a').write('native=true\\nmacos=true\\nscheme=true\\ngenerated=true\\n"
                "daemon=true\\nfast_tier=true\\n')\n")
            output, summary = root / "out", root / "summary"
            values = {"PATH": os.environ["PATH"], "EVENT_NAME": event, "GITHUB_REF": "refs/heads/feat-cmux-next",
                      "GITHUB_OUTPUT": str(output), "GITHUB_STEP_SUMMARY": str(summary), "RUNNER_TEMP": tmp,
                      "GITHUB_RUN_ATTEMPT": "1", "DEV_DAILY": "false", "TIP_SWIFT_SUITE": "false",
                      "TIP_DAEMON_SUITE": "false", "BASE_TIER": "false", "BASE_TIER_COALESCE": "true",
                      "DEV_LANDING_COMPILE": "", **env}
            subprocess.run(["bash", "-c", route_step()["run"]], cwd=root, env=values, check=True,
                           capture_output=True, text=True)
            return dict(line.split("=", 1) for line in output.read_text().splitlines() if "=" in line)

    def test_a_feat_cmux_next_push_defers_the_base_tier(self):
        out = self.run_step("push")
        self.assertEqual((out["daemon"], out["scheme"], out["generated"]), ("false", "false", "false"))
        self.assertEqual((out["native"], out["fast_tier"]), ("true", "true"))

    def test_coalescing_off_or_another_branch_runs_the_base_tier_on_the_push(self):
        for env in ({"BASE_TIER_COALESCE": "false"}, {"GITHUB_REF": "refs/heads/next-batch/1"}):
            with self.subTest(env=env):
                out = self.run_step("push", **env)
                self.assertEqual((out["daemon"], out["scheme"], out["generated"]), ("true", "true", "true"))

    def test_a_push_whose_scheme_compile_is_the_dev_landing_build_keeps_it(self):
        out = self.run_step("push", DEV_LANDING_COMPILE="0")
        self.assertEqual((out["daemon"], out["scheme"], out["generated"]), ("false", "true", "false"))

    def test_the_base_tier_dispatch_runs_exactly_the_base_tier(self):
        out = self.run_step("workflow_dispatch", BASE_TIER="true")
        self.assertEqual((out["daemon"], out["scheme"], out["generated"], out["macos"]), ("true",) * 4)
        for name in ("native", "swift", "full", "swift_canary", "cmuxnext_swift"):
            self.assertEqual(out[name], "false", name)

    def test_the_base_tier_dispatch_runs_only_on_feat_cmux_next(self):
        with self.assertRaises(subprocess.CalledProcessError):
            self.run_step("workflow_dispatch", BASE_TIER="true", GITHUB_REF="refs/heads/lane/x")


def tier_suites():
    sys.path.insert(0, str(ROOT / "scripts/ci"))
    import base_red_excuse
    return base_red_excuse.SUITES


class Workflows(unittest.TestCase):
    def test_the_dispatch_input_names_the_tested_commit(self):
        text = WORKFLOW.read_text()
        self.assertRegex(text, r"\n      base_tier:\n(?:        .*\n)*?        type: boolean\n")
        self.assertIn("format('cmux-next base tier · {0}', inputs.same_tree_sha || github.sha)", text)
        self.assertEqual(tier.TITLE, "cmux-next base tier · ")

    def test_its_tree_wait_marker_is_a_base_tier_suite(self):
        route = yaml.safe_load(WORKFLOW.read_text())["jobs"]["path_route"]
        marker = next(step for step in route["steps"] if step.get("id") == "marker")
        self.assertEqual(marker["env"]["BASE_TIER"], "${{ inputs.base_tier || false }}")
        self.assertIn('marker.update(tip_suite="base")', marker["run"])

    def test_push_attribution_runs_for_a_red_base_tier(self):
        jobs = yaml.safe_load(WORKFLOW.read_text())["jobs"]
        self.assertIn("inputs.base_tier == true", jobs["push-attribution"]["if"])

    def test_a_red_crash_gate_alone_starts_push_attribution(self):
        # failure() reads only the needed jobs: the crash gate is one of the base tier's jobs.
        jobs = yaml.safe_load(WORKFLOW.read_text())["jobs"]
        self.assertIn("crash-ends-app", jobs["push-attribution"]["needs"])

    def test_a_base_tier_run_checks_generated_files_on_their_own_job(self):
        # A pull request's standalone `cmux-next generated files` red is compared with the base tier's
        # verdict for that job, so a base tier run never folds it into daemon-test's build.
        jobs = yaml.safe_load(WORKFLOW.read_text())["jobs"]
        host = jobs["path_route"]["outputs"]["generated_host"]
        self.assertTrue(host.startswith("${{ steps.route.outputs.generated != 'true' && 'none' || "
                                        "inputs.base_tier == true && 'generated-files' || "), host)
        self.assertIn("cmux-next generated files", tier_suites()["cmux-next base tier · "])
        self.assertNotIn("cmux-next generated files (shared build)", tier_suites()["cmux-next base tier · "])

    def test_the_kick_is_serialized_and_its_own_runs_are_never_cancelled(self):
        kick_doc = yaml.safe_load(KICK.read_text())
        on = kick_doc.get(True) or kick_doc.get("on")
        self.assertEqual(on, {"push": {"branches": ["feat-cmux-next"]}})
        self.assertEqual(kick_doc["concurrency"], {"group": "cmux-next-base-tier-kick", "cancel-in-progress": False})
        job = kick_doc["jobs"]["kick"]
        self.assertIn("CMUX_NEXT_BASE_TIER_COALESCE", job["if"])
        self.assertGreater(job["timeout-minutes"] * 60, tier.WINDOW_S + tier.SETTLE_S)
        self.assertEqual(job["permissions"], {"actions": "write", "contents": "read"})
        self.assertIn("cmux_next_base_tier.py kick", job["steps"][-1]["run"])

    def test_sleeping_dispatcher_reads_the_linux_pool(self):
        # A pure Python timer/API call reads the reconciled Linux pool, never a fixed
        # Blacksmith size that can stall (tests/test_ci_linux_single_size.py).
        expression = yaml.safe_load(KICK.read_text())["jobs"]["kick"]["runs-on"]
        self.assertIn("'ubuntu-24.04'", expression)
        self.assertNotIn("32vcpu", expression)
        self.assertNotIn("vars.LINUX_RUNNER", expression)
        self.assertTrue(expression.rstrip().endswith("|| fromJSON(vars.RUNNER_POOLS).linux }}"), expression)

    def test_the_push_and_the_kick_read_the_same_switch(self):
        env = route_step()["env"]
        self.assertIn("vars.CMUX_NEXT_BASE_TIER_COALESCE) != '0'", env["BASE_TIER_COALESCE"])
        self.assertIn("vars.CMUX_NEXT_BASE_TIER_COALESCE) != '0'", yaml.safe_load(KICK.read_text())["jobs"]["kick"]["if"])

    def test_nightly_dev_and_release_producers_are_not_deferred(self):
        # Only the three base tier outputs are rewritten; nightly-next's Release compile (native), the DEV
        # landing compile (its own job) and the fast tier keep their push routing.
        self.assertEqual(tier.TIERS, ("daemon", "scheme", "generated"))
        text = route_step()["run"]
        self.assertTrue(re.search(r'"\$EVENT_NAME" == push && "\$GITHUB_REF" == refs/heads/feat-cmux-next && '
                                  r'"\$BASE_TIER_COALESCE" == true', text))


if __name__ == "__main__":
    unittest.main()
