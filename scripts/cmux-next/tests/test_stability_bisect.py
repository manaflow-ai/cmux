#!/usr/bin/env python3
"""scripts/cmux-next/stability_bisect.py on a throwaway repository with a fake fleet.

The repository has a first-parent line with merge commits (their side-branch commits must never be tested). The
fake fleet answers cmux-ci status/build/wait, os-matrix.sh and package-test-lane.sh steps from a table: which commits
reproduce (and how often), which do not build, which builds already exist, and how many wait timeouts a job gives
before it ends. Its "reports" are files whose text is a hash12, which the fake crash_signature reads back.

Covered: the first bad commit of a 12-commit range in about log2 steps with 3 replays each; a wait timeout waits again
on the same job and never resubmits; a deadline exits 75 and the same command resumes the same job; 1 or 2 of 3
reproductions is flaky and blames no commit (in the middle and at the bad end); a done fleet build is reused and
preferred as the midpoint; a reused build that failed is built once; a commit that does not build is skipped
(ambiguous when it is next to the first bad commit); a run that failed with another signature does not count as
good; a replay step without a verdict re-attaches while it runs and takes a new attempt only after it ended; the
Swift test replay parses the suite table; --post records first_bad and flaky only; bad arguments are refused.

Not a CI job (Lawrence 2026-10-23: no new CI gates). Run it yourself:
  python3 -I scripts/cmux-next/tests/test_stability_bisect.py      (or python3 -m pytest on the same file)
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "stability_bisect.py"
HASH = "a1b2c3d4e5f6"
OTHER_HASH = "0f0f0f0f0f0f"


def load():
    spec = importlib.util.spec_from_file_location("stability_bisect", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    sys.modules["stability_bisect"] = module
    spec.loader.exec_module(module)
    return module


sb = load()


def git(repo: Path, *args: str) -> str:
    env = {"GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t",
           "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null", "PATH": "/usr/bin:/bin"}
    return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, text=True,
                          env=env).stdout.strip()


def make_repo(root: Path, length: int = 13) -> tuple[Path, list[str], list[str]]:
    """A main line of `length` commits (every 4th is a --no-ff merge of a side commit); returns the repo, the main
    line oldest first, and the side commits."""
    repo = root / "repo"
    repo.mkdir()
    git(repo, "init", "-q", "-b", "main")
    pkg = repo / "Packages/macOS/Demo"
    pkg.mkdir(parents=True)
    (pkg / "Package.swift").write_text("// demo\n")
    git(repo, "add", ".")
    git(repo, "commit", "-q", "-m", "c0")
    main, side = [git(repo, "rev-parse", "HEAD")], []
    for i in range(1, length):
        if i % 4 == 0:
            git(repo, "checkout", "-q", "-b", f"side{i}")
            (repo / f"side{i}.txt").write_text(str(i))
            git(repo, "add", ".")
            git(repo, "commit", "-q", "-m", f"side {i}")
            side.append(git(repo, "rev-parse", "HEAD"))
            git(repo, "checkout", "-q", "main")
            git(repo, "merge", "-q", "--no-ff", "-m", f"merge {i}", f"side{i}")
        else:
            (repo / f"f{i}.txt").write_text(str(i))
            if i == 6:
                (pkg / "DemoTests.swift").write_text("func testCrash() {}\n")
            git(repo, "add", ".")
            git(repo, "commit", "-q", "-m", f"c{i}")
        main.append(git(repo, "rev-parse", "HEAD"))
    return repo, main, side


class FakeFleet:
    """cmux-ci, os-matrix.sh, package-test-lane.sh, crash_signature.py and stability_issues.py in one table."""

    def __init__(self, hits: dict[str, list[str]], default: str = "miss") -> None:
        # hits[sha] = per-attempt outcomes ("hit", "miss", "other", "noverdict", "noverdict-running"), cycled.
        self.hits = hits
        self.default = default
        self.build_fails: set[str] = set()
        self.timeouts_per_job = 0
        self.job_table: dict[str, dict] = {}
        self.wait_calls: list[tuple[str, float]] = []
        self.submits: list[str] = []
        self.steps: list[tuple[str, int]] = []
        self.step_jobs: dict[str, str] = {}
        self.posted: list[tuple[str, dict]] = []
        self.test_runs: list[tuple[str, str]] = []
        self.timeouts_left: dict[str, int] = {}
        self.seq = 0

    def _id(self) -> str:
        self.seq += 1
        return f"{self.seq:024x}"

    def add_build(self, sha: str, state: str = "done", variant: str = "dev") -> str:
        job = self._id()
        self.job_table[job] = {"id": job, "kind": "cmux", "ref": sha, "state": state, "variant": variant,
                               "created_at": f"2026-10-25T00:00:{self.seq:02d}Z"}
        return job

    # Fleet protocol

    def jobs(self, ref=None):
        return [dict(job) for job in self.job_table.values() if ref is None or job.get("ref") == ref]

    def job(self, job_id):
        return dict(self.job_table[job_id])

    def submit_build(self, sha, tag, workspace, receipt):
        assert tag.startswith("bisect-") and len(tag) <= 64, tag
        job = self.add_build(sha, state="queued")
        self.timeouts_left[job] = self.timeouts_per_job
        receipt.parent.mkdir(parents=True, exist_ok=True)
        receipt.write_text(json.dumps({"id": job}))
        self.submits.append(sha)
        return job

    def wait(self, job_id, timeout):
        self.wait_calls.append((job_id, timeout))
        job = self.job_table[job_id]
        if self.timeouts_left.get(job_id, 0) > 0:
            self.timeouts_left[job_id] -= 1
            return 2
        if job["kind"] == "cmux" and job["state"] in sb.ACTIVE_STATES:
            job["state"] = "failed" if job["ref"] in self.build_fails else "done"
        if job["kind"] == "ci-step" and job["state"] in sb.ACTIVE_STATES:
            job["state"] = "done"
        return 0 if job["state"] == "done" else 1

    def _outcome(self, sha, attempt):
        seq = self.hits.get(sha, [self.default])
        return seq[(attempt - 1) % len(seq)]

    def os_matrix(self, build_job, majors, suite, seed, minutes, runner_ref, attempt, out, timeout):
        assert timeout > 0, "a step client must be bounded by the deadline"
        sha = self.job_table[build_job]["ref"]
        assert self.job_table[build_job]["state"] == "done", "a replay must use a done build"
        self.steps.append((sha, attempt))
        key = f"{sha}-{attempt}"
        if key not in self.step_jobs:
            self.step_jobs[key] = self._id()
        step = self.step_jobs[key]
        outcome = self._outcome(sha, attempt)
        if outcome.startswith("noverdict"):
            running = outcome == "noverdict-running" and step not in self.job_table
            self.job_table.setdefault(step, {"id": step, "kind": "ci-step", "state": "running" if running else "failed"})
            if self.job_table[step]["state"] == "done":  # re-attached after the wait: the step's own verdict
                return self._verdict(out, step, "hit" if sha in self.hits and "hit" in self.hits[sha] else "miss")
            return sb.StepRun(75, step, f"cmux-ci: step {step}\nos-matrix: no verdict")
        self.job_table[step] = {"id": step, "kind": "ci-step", "state": "done"}
        return self._verdict(out, step, outcome)

    def _verdict(self, out, step, outcome):
        (out / "26").mkdir(parents=True, exist_ok=True)
        if outcome == "hit":
            (out / "26" / "crash.ips").write_text(HASH)
        if outcome == "other":
            (out / "26" / "crash.ips").write_text(OTHER_HASH)
        code = 0 if outcome == "miss" else 1
        return sb.StepRun(code, step, f"cmux-ci: step {step}\nMATRIX VERDICT {'PASS' if code == 0 else 'FAIL'}")

    def run_tests(self, sha, package, filters, key, timeout):
        assert timeout > 0, "a step client must be bounded by the deadline"
        self.test_runs.append((sha, key))
        step = self._id()
        rows = [f"{f:<48} {'failed (exit 1)' if self._outcome(sha, i + 1) == 'hit' else 'passed':<18} {3:>6}s"
                for i, f in enumerate(filters)]
        log = f"cmux-ci: step {step}\nSwift suite results ({package}):\n" + "\n".join(rows) + "\n"
        return sb.StepRun(1 if "failed" in log else 0, step, log)

    def signatures(self, paths):
        return {Path(p).read_text().strip() for p in paths}

    def post(self, hash12, verdict):
        self.posted.append((hash12, verdict))


class BisectTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.repo, self.main, self.side = make_repo(self.root)
        self.git = sb.Git(self.repo)
        self.state = self.root / "state" / f"{HASH}.json"
        self.now = [0.0]

    def tearDown(self):
        self.tmp.cleanup()

    def clock(self):
        return self.now[0]

    def run_cli(self, fleet, *extra, replay="fuzz:21:30", good=None, bad=None, cmd="run"):
        argv = [cmd, "--hash12", HASH, "--good", good or self.main[0], "--bad", bad or self.main[-1],
                "--replay", replay, "--os", "26", "--runner-ref", self.main[-1], *extra]
        if cmd == "run":
            argv += ["--state", str(self.state)]
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = sb.main(argv, fleet=fleet, git=self.git, clock=self.clock)
        self.err = err.getvalue()
        return code, (json.loads(out.getvalue()) if out.getvalue().strip() else None)

    def bad_from(self, index, outcome=("hit",)):
        return {sha: list(outcome) for sha in self.main[index:]}

    def test_finds_first_bad_commit_on_the_first_parent_line(self):
        fleet = FakeFleet(self.bad_from(7))
        code, verdict = self.run_cli(fleet, "--post")
        self.assertEqual(code, 0, self.err)
        self.assertEqual(verdict["result"], "first_bad")
        self.assertEqual(verdict["sha"], self.main[7])
        self.assertIn("3/3 replays reproduced", verdict["evidence"])
        tested = {sha for sha, _ in fleet.steps}
        self.assertFalse(tested & set(self.side), "a side-branch commit was tested")
        self.assertLessEqual(len(tested), 2 + 4)  # both ends + ceil(log2(12))
        self.assertTrue(all(count == 3 for count in [sum(1 for s, _ in fleet.steps if s == sha) for sha in tested]))
        self.assertEqual(len(fleet.submits), len(tested))
        self.assertEqual(fleet.posted, [(HASH, verdict)])

    def test_wait_timeout_waits_again_and_never_resubmits(self):
        fleet = FakeFleet(self.bad_from(5))
        fleet.timeouts_per_job = 2
        code, verdict = self.run_cli(fleet)
        self.assertEqual(code, 0, self.err)
        self.assertEqual(verdict["sha"], self.main[5])
        self.assertEqual(len(fleet.submits), len(set(fleet.submits)), "a commit was submitted twice")
        for job in {job for job, _ in fleet.wait_calls}:
            self.assertGreaterEqual(sum(1 for j, _ in fleet.wait_calls if j == job), 3)
        self.assertIn("waiting again, not resubmitting", self.err)

    def test_deadline_exits_75_and_the_same_command_resumes_the_same_job(self):
        fleet = FakeFleet(self.bad_from(5))
        fleet.timeouts_per_job = 1
        original_wait = fleet.wait

        def slow_wait(job_id, timeout):
            self.now[0] += 4 * 3600  # every wait slice uses up 4 h of the 12 h default
            return original_wait(job_id, timeout)

        fleet.wait = slow_wait
        code, _ = self.run_cli(fleet)
        self.assertEqual(code, 75, self.err)
        submitted = list(fleet.submits)
        saved = json.loads(self.state.read_text())
        self.assertTrue(saved["builds"])
        fleet.wait = original_wait
        self.now[0] = 0.0
        code, verdict = self.run_cli(fleet)
        self.assertEqual(code, 0, self.err)
        self.assertEqual(verdict["sha"], self.main[5])
        self.assertEqual(fleet.submits[:len(submitted)], submitted)
        self.assertEqual(len(fleet.submits), len(set(fleet.submits)), "the resumed run resubmitted a build")

    def test_two_of_three_in_the_middle_is_flaky_and_blames_no_commit(self):
        hits = self.bad_from(9)
        for sha in self.main[3:9]:
            hits[sha] = ["hit", "miss", "hit"]
        fleet = FakeFleet(hits)
        code, verdict = self.run_cli(fleet, "--post")
        self.assertEqual(code, 0, self.err)
        self.assertEqual(verdict["result"], "flaky")
        self.assertEqual(verdict["hits"], "2/3")
        self.assertNotIn("first_bad", json.dumps(verdict))
        self.assertEqual(fleet.posted[0][1]["result"], "flaky")

    def test_one_of_three_at_the_bad_end_is_flaky(self):
        fleet = FakeFleet({self.main[-1]: ["miss", "hit", "miss"]})
        code, verdict = self.run_cli(fleet)
        self.assertEqual(code, 0, self.err)
        self.assertEqual((verdict["result"], verdict["hits"], verdict["sha"]), ("flaky", "1/3", self.main[-1]))
        self.assertEqual({sha for sha, _ in fleet.steps}, {self.main[-1]}, "a flaky bad end must stop the bisect")

    def test_no_repro_at_the_bad_end_is_not_posted(self):
        fleet = FakeFleet({})
        code, verdict = self.run_cli(fleet, "--post")
        self.assertEqual(code, 0, self.err)
        self.assertEqual(verdict["result"], "no_repro")
        self.assertEqual(fleet.posted, [])

    def test_bug_at_the_good_end_is_reported(self):
        fleet = FakeFleet(self.bad_from(0))
        code, verdict = self.run_cli(fleet)
        self.assertEqual(verdict["result"], "bad_at_good")

    def test_reuses_done_builds_and_prefers_them_as_midpoint(self):
        fleet = FakeFleet(self.bad_from(8))
        fleet.add_build(self.main[0])
        fleet.add_build(self.main[-1])
        fleet.add_build(self.main[5])
        fleet.add_build(self.main[7], variant="dev-release")  # a Release build is not the DEV app the VM runs
        code, verdict = self.run_cli(fleet)
        self.assertEqual(code, 0, self.err)
        self.assertEqual(verdict["sha"], self.main[8])
        self.assertNotIn(self.main[0], fleet.submits)
        self.assertNotIn(self.main[-1], fleet.submits)
        self.assertNotIn(self.main[5], fleet.submits)
        self.assertEqual(fleet.steps[6][0], self.main[5], "the built commit near the middle goes first")

    def test_reused_failed_build_is_built_once_by_the_bisect(self):
        fleet = FakeFleet(self.bad_from(4))
        failed = fleet.add_build(self.main[-1], state="running")
        fleet.build_fails.add(self.main[-1])
        original_wait = fleet.wait

        def wait(job_id, timeout):
            if job_id == failed:
                fleet.job_table[job_id]["state"] = "failed"
                return 1
            fleet.build_fails.discard(self.main[-1])
            return original_wait(job_id, timeout)

        fleet.wait = wait
        code, verdict = self.run_cli(fleet)
        self.assertEqual(code, 0, self.err)
        self.assertEqual(verdict["sha"], self.main[4])
        self.assertEqual(fleet.submits.count(self.main[-1]), 1)

    def test_commit_that_does_not_build_is_skipped(self):
        fleet = FakeFleet(self.bad_from(7))
        fleet.build_fails.add(self.main[6])
        code, verdict = self.run_cli(fleet)
        self.assertEqual(code, 0, self.err)
        self.assertEqual(verdict["result"], "ambiguous")
        self.assertEqual(verdict["candidates"], [self.main[6], self.main[7]])
        fleet = FakeFleet(self.bad_from(9))
        fleet.build_fails.add(self.main[6])
        self.state = self.root / "state2" / f"{HASH}.json"  # its own receipts: a new fleet knows no old job
        code, verdict = self.run_cli(fleet)
        self.assertEqual((verdict["result"], verdict["sha"]), ("first_bad", self.main[9]))

    def test_other_crash_is_not_good(self):
        hits = self.bad_from(7)
        hits[self.main[6]] = ["other"]
        fleet = FakeFleet(hits)
        code, verdict = self.run_cli(fleet)
        self.assertEqual(code, 0, self.err)
        self.assertEqual(verdict["result"], "ambiguous")
        saved = json.loads(self.state.read_text())
        self.assertEqual(saved["results"][self.main[6]]["verdict"], "untestable")

    def test_step_past_the_deadline_exits_75_and_resumes_with_the_same_attempt(self):
        fleet = FakeFleet(self.bad_from(5))
        original = fleet.os_matrix
        attempts = []

        def slow_step(*args):
            attempts.append(args[6])
            if len(attempts) == 1:
                raise sb.Pending("replay step fuzz (attempt 1) has not finished")
            return original(*args)

        fleet.os_matrix = slow_step
        code, _ = self.run_cli(fleet)
        self.assertEqual(code, 75, self.err)
        code, verdict = self.run_cli(fleet)
        self.assertEqual(code, 0, self.err)
        self.assertEqual(verdict["sha"], self.main[5])
        self.assertEqual(attempts[:2], [1, 1], "the resumed run must re-attach to attempt 1, not start attempt 2")
        self.assertEqual(len(fleet.submits), len(set(fleet.submits)), "the resumed run resubmitted a build")

    def test_running_step_without_verdict_reattaches_then_new_attempt_only_after_it_ended(self):
        hits = self.bad_from(7)
        hits[self.main[-1]] = ["noverdict-running", "hit", "hit"]
        hits[self.main[0]] = ["noverdict", "miss", "miss", "miss"]
        fleet = FakeFleet(hits)
        code, verdict = self.run_cli(fleet)
        self.assertEqual(code, 0, self.err)
        self.assertEqual(verdict["sha"], self.main[7])
        bad_attempts = [attempt for sha, attempt in fleet.steps if sha == self.main[-1]]
        self.assertEqual(bad_attempts[:2], [1, 1], "a running step is re-attached with the same attempt")
        good_attempts = [attempt for sha, attempt in fleet.steps if sha == self.main[0]]
        self.assertEqual(good_attempts, [1, 2, 3, 4], "an ended step without a verdict takes a new attempt")

    def test_repeated_no_verdict_makes_the_commit_untestable(self):
        hits = self.bad_from(7)
        hits[self.main[-1]] = ["noverdict"]
        fleet = FakeFleet(hits)
        code, verdict = self.run_cli(fleet)
        self.assertEqual(verdict["result"], "untestable")
        self.assertEqual(len(fleet.steps), 1 + sb.DEFAULT_INFRA_RETRIES)

    def test_swift_test_replay_needs_the_test_at_the_good_end(self):
        fleet = FakeFleet({sha: ["hit"] for sha in self.main[9:]})
        code, verdict = self.run_cli(fleet, replay="test:Packages/macOS/Demo:DemoTests/testCrash")
        self.assertEqual(code, 0, self.err)
        self.assertEqual(verdict["result"], "untestable")  # c6 adds the test: the good end c0 cannot run it
        self.assertIn("the good end", verdict["evidence"])
        self.assertEqual([sha for sha, _ in fleet.test_runs], [self.main[-1]])

    def test_swift_test_replay_from_a_commit_with_the_test(self):
        fleet = FakeFleet({sha: ["hit"] for sha in self.main[9:]})
        code, verdict = self.run_cli(fleet, replay="test:Packages/macOS/Demo:DemoTests/testCrash", good=self.main[6])
        self.assertEqual(code, 0, self.err)
        self.assertEqual((verdict["result"], verdict["sha"]), ("first_bad", self.main[9]))
        self.assertEqual(fleet.submits, [], "a test replay builds no app")

    def test_plan_submits_nothing(self):
        fleet = FakeFleet({})
        fleet.add_build(self.main[3])
        code, plan = self.run_cli(fleet, cmd="plan")
        self.assertEqual(code, 0, self.err)
        self.assertEqual(plan["first_parent_commits"], len(self.main) - 1)
        self.assertEqual(plan["reusable_builds"], [self.main[3]])
        self.assertEqual(fleet.submits, [])

    def test_refuses_bad_arguments(self):
        fleet = FakeFleet({})
        self.assertEqual(self.run_cli(fleet, good=self.side[0])[0], 1)  # not on the first-parent line
        self.assertIn("first-parent", self.err)
        self.assertEqual(self.run_cli(fleet, replay="repro:missing")[0], 1)
        self.assertEqual(self.run_cli(fleet, replay="fuzz:1:99")[0], 1)
        self.assertEqual(self.run_cli(fleet, replay="fuzz-input:x")[0], 1)
        self.assertEqual(fleet.submits, [])

    def test_state_of_another_bisect_is_refused(self):
        fleet = FakeFleet(self.bad_from(7))
        self.assertEqual(self.run_cli(fleet)[0], 0)
        self.assertEqual(self.run_cli(fleet, good=self.main[1])[0], 1)
        self.assertIn("another bisect", self.err)


class UnitTests(unittest.TestCase):
    def test_test_results_parses_the_suite_table(self):
        log = ("Swift suite results (Packages/macOS/CmuxNext):\nsuite result time\n"
               "A/testX                                          passed                  3s\n"
               "A/testX                                          failed (exit 1)         4s\n"
               "A/testX                                          stalled/timeout       900s\n")
        self.assertEqual(sb.test_results(log, ["A/testX"] * 3), ["miss", "hit", "hit"])
        self.assertIsNone(sb.test_results("error: build failed", ["A/testX"] * 3))

    def test_run_step_stops_the_client_group_at_the_deadline(self):
        with tempfile.TemporaryDirectory() as tmp:
            marker = Path(tmp) / "child.pid"
            # The client forks a child that holds the output pipe, as `os-matrix.sh | tee` does.
            script = 'sleep 300 & echo "$!" > "$1"; echo "cmux-ci: step ' + "b" * 24 + '"; wait'
            started = time.monotonic()
            with self.assertRaises(sb.Pending):
                sb.run_step(["/bin/bash", "-c", script, "client", str(marker)], Path(tmp), None, 1.5, "replay step")
            self.assertLess(time.monotonic() - started, 30)
            child = int(marker.read_text())
            for _ in range(50):
                try:
                    os.kill(child, 0)
                except ProcessLookupError:
                    break
                time.sleep(0.1)
            else:
                self.fail("the client's child outlived the deadline")
            run = sb.run_step(["/bin/bash", "-c", 'echo "cmux-ci: step ' + "c" * 24 + '"; exit 1'], Path(tmp), None,
                              30, "test step")
            self.assertEqual((run.code, run.step), (1, "c" * 24))

    def test_report_paths_include_hang_samples(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            (out / "26").mkdir()
            for name in ("a.ips", "b.hang", "hang-3.sample.txt", "hang-3.live-sample.txt", "cmux-panic.jsonl",
                         "step.log", "shot.png", "result.json"):
                (out / "26" / name).write_text("x")
            self.assertEqual([path.name for path in sb.report_paths(out)],
                             ["a.ips", "b.hang", "cmux-panic.jsonl", "hang-3.live-sample.txt", "hang-3.sample.txt"])

    def test_midpoint_prefers_built_commits_near_the_middle(self):
        commits = [f"{i:040x}" for i in range(20)]
        open_ = list(range(0, 19))
        self.assertEqual(sb.midpoint(open_, -1, 19, set(), commits), 9)
        self.assertEqual(sb.midpoint(open_, -1, 19, {commits[12]}, commits), 12)
        self.assertEqual(sb.midpoint(open_, -1, 19, {commits[1]}, commits), 9)  # too far from the middle

    def test_pick_build_takes_done_dev_builds_only(self):
        sha = "a" * 40
        jobs = [{"id": "1" * 24, "kind": "cmux", "ref": sha, "state": "failed"},
                {"id": "2" * 24, "kind": "cmux", "ref": sha, "state": "done", "variant": "production"},
                {"id": "3" * 24, "kind": "cmux", "ref": sha, "state": "running", "variant": "dev"}]
        self.assertEqual(sb.pick_build(jobs, sha)["id"], "3" * 24)
        jobs.append({"id": "4" * 24, "kind": "cmux", "ref": sha, "state": "done"})
        self.assertEqual(sb.pick_build(jobs, sha)["id"], "4" * 24)

    def test_parse_replay(self):
        self.assertEqual(sb.parse_replay("repro:close-window").suite, "repro:close-window")
        self.assertEqual(sb.parse_replay("fuzz:21:30").seed, 21)
        self.assertFalse(sb.parse_replay("test:Packages/macOS/CmuxNext:CmuxNextAppTests/testA").needs_app)
        for bad in ("repro:../x", "fuzz:01:5", "test:Packages/../x:A", "test:Packages/a:A.", "shell:rm"):
            with self.assertRaises(sb.BisectError):
                sb.parse_replay(bad)


if __name__ == "__main__":
    unittest.main()
