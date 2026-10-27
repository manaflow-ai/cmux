#!/usr/bin/env python3
"""scripts/cmux-next/stability_bisect.py on a throwaway repository with a fake fleet, and its real fleet adapter
against fake cmux-ci, crash_signature.py and stability_issues.py executables.

The repository has a first-parent line with merge commits (their side-branch commits must never be tested) and a bare
remote named like manaflow-ai/cmux (the overlay commits' scratch branches go there). The fake fleet answers cmux-ci
status/build/wait, os-matrix.sh and package-test-lane.sh steps from a table: which commits reproduce (and how often),
which do not build or lose their build, which builds already exist, and how many wait timeouts a job gives before it
ends. Its "reports" are files whose text is a hash12, which the fake crash_signature reads back; its test steps print
package-test-lane.sh's per-run sections and suite table.

Covered: the first bad commit of a 12-commit range in about log2 steps with 3 replays each; a wait timeout waits again
on the same job and never resubmits; a deadline exits 75 and the same command resumes the same job; 1 or 2 of 3
reproductions is flaky and blames no commit; a done fleet build is reused only when it is a clean build of the commit
(never a working-tree or dirty one) and preferred as the midpoint; a reused build that failed is built once; a commit
that does not compile is skipped, a cancelled build is built again; a run with another signature or an unreadable
report does not count as good; a replay step without a verdict re-attaches while it runs and takes a new attempt only
after it ended; the test replay lays the runner ref's test over old commits, and a run that ran no test, failed
another test or hit a toolchain mismatch is not a reproduction; --post records first_bad and flaky only; the real
CmuxCi argv, exit mapping, receipts and .pending refusal; bad arguments are refused.

Not a CI job (Lawrence 2026-10-23: no new CI gates). Run it yourself:
  python3 -I scripts/cmux-next/tests/test_stability_bisect.py      (or python3 -m pytest on the same file)
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[1] / "stability_bisect.py"
HASH = "a1b2c3d4e5f6"
OTHER_HASH = "0f0f0f0f0f0f"
TEST_REPLAY = "test:Packages/macOS/Demo:DemoTests/testCrash"
GIT_ENV = {"GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"}


def load():
    spec = importlib.util.spec_from_file_location("stability_bisect", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    sys.modules["stability_bisect"] = module
    spec.loader.exec_module(module)
    return module


sb = load()


def git(repo: Path, *args: str, check: bool = True) -> str:
    env = {"GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t",
           "PATH": "/usr/bin:/bin", **GIT_ENV}
    return subprocess.run(["git", "-C", str(repo), *args], check=check, capture_output=True, text=True,
                          env=env).stdout.strip()


def make_repo(root: Path, length: int = 13) -> tuple[Path, list[str], list[str], Path]:
    """A main line of `length` commits (every 4th is a --no-ff merge of a side commit) and its bare remote; returns
    the repo, the main line oldest first, the side commits and the remote."""
    repo = root / "repo"
    repo.mkdir()
    git(repo, "init", "-q", "-b", "main")
    remote = root / "remote" / "manaflow-ai" / "cmux.git"
    remote.mkdir(parents=True)
    git(remote, "init", "-q", "--bare")
    git(repo, "remote", "add", "origin", str(remote))
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
    git(repo, "push", "-q", "origin", "main")
    return repo, main, side, remote


def suite_section(test_filter: str, outcome: str) -> tuple[str, str]:
    """package-test-lane.sh's `swift test --filter` section for one run, and its table result."""
    started = "◇ Test testCrash() started."
    run_failed = "✘ Test run with 1 test failed after 0.002 seconds with 1 issue."
    lines, result = {
        "hit": ([started, "✘ Test testCrash() recorded an issue at DemoTests.swift:1:1: Expectation failed",
                 "✘ Test testCrash() failed after 0.001 seconds with 1 issue.", run_failed], "failed (exit 1)"),
        "miss": ([started, "✔ Test testCrash() passed after 0.001 seconds.",
                  "✔ Test run with 1 test passed after 0.001 seconds."], "passed"),
        "other": (["◇ Test testOther() started.", started, "✔ Test testCrash() passed after 0.001 seconds.",
                   "✘ Test testOther() failed after 0.001 seconds with 1 issue.", run_failed], "failed (exit 1)"),
        "notests": (["error: no tests found; create a target in the 'Tests' directory"], "failed (exit 1)"),
        "toolchain": (["error: Invalid manifest"], "failed (exit 1)"),
        "hang": ([started, "::group::Stack sample of xctest (123)", HASH, "::endgroup::"], "stalled/timeout"),
        "hang-other": ([started, "::group::Stack sample of xctest (123)", OTHER_HASH, "::endgroup::"],
                       "stalled/timeout"),
        "crash": ([started, "error: Exited with unexpected signal code 11"], "failed (exit 1)"),
    }[outcome]
    return "\n".join([f"::group::swift test --filter {test_filter}", *lines, "::endgroup::"]), result


class FakeFleet:
    """cmux-ci, os-matrix.sh, package-test-lane.sh, crash_signature.py and stability_issues.py in one table."""

    def __init__(self, hits: dict[str, list[str]], default: str = "miss", repo: Path | None = None,
                 remote: Path | None = None) -> None:
        # hits[sha] = per-attempt (VM) or per-run (test) outcomes, cycled: VM "hit", "miss", "other", "unreadable",
        # "noverdict", "noverdict-running"; test: the suite_section() outcomes.
        self.hits = hits
        self.default = default
        self.repo = repo
        self.remote = remote
        self.build_fails: set[str] = set()
        self.build_cancels: dict[str, int] = {}
        self.timeouts_per_job = 0
        self.job_table: dict[str, dict] = {}
        self.wait_calls: list[tuple[str, float]] = []
        self.submits: list[str] = []
        self.receipts: list[str] = []
        self.steps: list[tuple[str, int]] = []
        self.step_jobs: dict[str, str] = {}
        self.posted: list[tuple[str, dict]] = []
        self.test_runs: list[tuple[str, str, str]] = []
        self.timeouts_left: dict[str, int] = {}
        self.seq = 0

    def _id(self) -> str:
        self.seq += 1
        return f"{self.seq:024x}"

    def add_build(self, sha: str, state: str = "done", variant: str = "dev", **extra) -> str:
        job = self._id()
        self.job_table[job] = {"id": job, "kind": "cmux", "ref": sha, "state": state, "variant": variant,
                               "created_at": f"2026-10-25T00:00:{self.seq:02d}Z", **extra}
        return job

    def origin(self, ref: str) -> str:
        """The bisected commit a test step's ref stands for: its parent when it is an overlay commit."""
        if self.repo is None or git(self.repo, "log", "-1", "--format=%s", ref) != sb.OVERLAY_SUBJECT:
            return ref
        fetchable = subprocess.run(["git", "--git-dir", str(self.remote), "cat-file", "-e", f"{ref}^{{commit}}"],
                                   env={"PATH": "/usr/bin:/bin", **GIT_ENV}).returncode == 0
        assert fetchable, "a step ran an overlay commit the remote does not have"
        return git(self.repo, "rev-parse", f"{ref}^1")

    # Fleet protocol

    def jobs(self, ref=None):
        return [dict(job) for job in self.job_table.values() if ref is None or job.get("ref") == ref]

    def job(self, job_id):
        return dict(self.job_table[job_id])

    def submit_build(self, sha, tag, workspace, receipt):
        assert tag.startswith("bisect-") and len(tag) <= 64, tag
        assert not receipt.exists(), "a build was submitted over an existing receipt"
        job = self.add_build(sha, state="queued", source_digest=sha)
        self.timeouts_left[job] = self.timeouts_per_job
        receipt.parent.mkdir(parents=True, exist_ok=True)
        receipt.write_text(json.dumps({"id": job}))
        self.submits.append(sha)
        self.receipts.append(receipt.name)
        return job

    def wait(self, job_id, timeout):
        self.wait_calls.append((job_id, timeout))
        job = self.job_table[job_id]
        if self.timeouts_left.get(job_id, 0) > 0:
            self.timeouts_left[job_id] -= 1
            return 2
        if job["kind"] == "cmux" and job["state"] in sb.ACTIVE_STATES:
            if self.build_cancels.get(job["ref"], 0) > 0:
                self.build_cancels[job["ref"]] -= 1
                job.update(state="cancelled", error="cancelled: worker aws-m4pro-3 lost its lease")
            elif job["ref"] in self.build_fails:
                job.update(state="failed", error="exit status 65")
            else:
                job["state"] = "done"
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
        report = {"hit": HASH, "other": OTHER_HASH, "unreadable": "unreadable"}.get(outcome)
        if report:
            (out / "26" / "crash.ips").write_text(report)
        code = 0 if outcome in ("miss", "unreadable") else 1
        return sb.StepRun(code, step, f"cmux-ci: step {step}\nMATRIX VERDICT {'PASS' if code == 0 else 'FAIL'}")

    def run_tests(self, sha, package, filters, key, timeout):
        assert timeout > 0, "a step client must be bounded by the deadline"
        origin = self.origin(sha)
        self.test_runs.append((origin, sha, key))
        step = self._id()
        sections, rows = [], []
        for index, test_filter in enumerate(filters):
            section, result = suite_section(test_filter, self._outcome(origin, index + 1))
            sections.append(section)
            rows.append(f"{test_filter:<48} {result:<18} {3:>6}s")
        log = (f"cmux-ci: step {step}\n" + "\n".join(sections) + f"\nSwift suite results ({package}):\n"
               + f"{'suite':<48} {'result':<18} {'time':>7}\n" + "\n".join(rows) + "\n")
        return sb.StepRun(0 if all("passed" in row for row in rows) else 1, step, log)

    def signatures(self, paths):
        reports = sb.Reports()
        for path in paths:
            text = Path(path).read_text().strip()
            if sb.HASH12.match(text):
                reports.hashes.add(text)
            else:
                reports.unread.append(f"{Path(path).name}: no signature")
        return reports

    def post(self, hash12, verdict):
        self.posted.append((hash12, verdict))


class BisectTests(unittest.TestCase):
    def setUp(self):
        self.env = mock.patch.dict(os.environ, GIT_ENV)
        self.env.start()
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.repo, self.main, self.side, self.remote = make_repo(self.root)
        self.git = sb.Git(self.repo)
        self.state = self.root / "state" / f"{HASH}.json"
        self.now = [0.0]

    def tearDown(self):
        self.tmp.cleanup()
        self.env.stop()

    def clock(self):
        return self.now[0]

    def fleet(self, hits, **kwargs):
        return FakeFleet(hits, repo=self.repo, remote=self.remote, **kwargs)

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

    def saved(self):
        return json.loads(self.state.read_text())

    def bad_from(self, index, outcome=("hit",)):
        return {sha: list(outcome) for sha in self.main[index:]}

    def test_finds_first_bad_commit_on_the_first_parent_line(self):
        fleet = self.fleet(self.bad_from(7))
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
        fleet = self.fleet(self.bad_from(5))
        fleet.timeouts_per_job = 2
        code, verdict = self.run_cli(fleet)
        self.assertEqual(code, 0, self.err)
        self.assertEqual(verdict["sha"], self.main[5])
        self.assertEqual(len(fleet.submits), len(set(fleet.submits)), "a commit was submitted twice")
        for job in {job for job, _ in fleet.wait_calls}:
            self.assertGreaterEqual(sum(1 for j, _ in fleet.wait_calls if j == job), 3)
        self.assertIn("waiting again, not resubmitting", self.err)

    def test_deadline_exits_75_and_the_same_command_resumes_the_same_job(self):
        fleet = self.fleet(self.bad_from(5))
        fleet.timeouts_per_job = 1
        original_wait = fleet.wait

        def slow_wait(job_id, timeout):
            self.now[0] += 4 * 3600  # every wait slice uses up 4 h of the 12 h default
            return original_wait(job_id, timeout)

        fleet.wait = slow_wait
        code, _ = self.run_cli(fleet)
        self.assertEqual(code, 75, self.err)
        submitted = list(fleet.submits)
        self.assertTrue(self.saved()["builds"])
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
        fleet = self.fleet(hits)
        code, verdict = self.run_cli(fleet, "--post")
        self.assertEqual(code, 0, self.err)
        self.assertEqual(verdict["result"], "flaky")
        self.assertEqual(verdict["hits"], "2/3")
        self.assertNotIn("first_bad", json.dumps(verdict))
        self.assertEqual(fleet.posted[0][1]["result"], "flaky")

    def test_one_of_three_at_the_bad_end_is_flaky(self):
        fleet = self.fleet({self.main[-1]: ["miss", "hit", "miss"]})
        code, verdict = self.run_cli(fleet)
        self.assertEqual(code, 0, self.err)
        self.assertEqual((verdict["result"], verdict["hits"], verdict["sha"]), ("flaky", "1/3", self.main[-1]))
        self.assertEqual({sha for sha, _ in fleet.steps}, {self.main[-1]}, "a flaky bad end must stop the bisect")

    def test_no_repro_at_the_bad_end_is_not_posted(self):
        fleet = self.fleet({})
        code, verdict = self.run_cli(fleet, "--post")
        self.assertEqual(code, 0, self.err)
        self.assertEqual(verdict["result"], "no_repro")
        self.assertEqual(fleet.posted, [])

    def test_bug_at_the_good_end_is_reported(self):
        fleet = self.fleet(self.bad_from(0))
        code, verdict = self.run_cli(fleet)
        self.assertEqual(verdict["result"], "bad_at_good")

    def test_reuses_done_builds_and_prefers_them_as_midpoint(self):
        fleet = self.fleet(self.bad_from(8))
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

    def test_working_tree_and_dirty_builds_of_the_commit_are_not_reused(self):
        fleet = self.fleet(self.bad_from(8))
        # `cmux-ci build --working-tree`: ref = the merge base, a synthetic source digest and a patch.
        fleet.add_build(self.main[-1], source_digest="e" * 40, source_ref={"patch": "sha256:" + "1" * 64})
        # `--local-source --dirty`: ref = HEAD, source digest = HEAD, plus a patch.
        fleet.add_build(self.main[0], source_digest=self.main[0], source_ref={"patch": "sha256:" + "2" * 64})
        # A clean --local-source upload of the commit is its exact code.
        clean = fleet.add_build(self.main[5], source_digest=self.main[5], source_ref={"id": "bundle"})
        code, verdict = self.run_cli(fleet)
        self.assertEqual(code, 0, self.err)
        self.assertEqual(verdict["sha"], self.main[8])
        self.assertIn(self.main[-1], fleet.submits, "a working-tree build stood in for the commit")
        self.assertIn(self.main[0], fleet.submits, "a dirty build stood in for the commit")
        self.assertNotIn(self.main[5], fleet.submits)
        self.assertEqual(self.saved()["builds"][self.main[5]]["job"], clean)

    def test_reused_failed_build_is_built_once_by_the_bisect(self):
        fleet = self.fleet(self.bad_from(4))
        failed = fleet.add_build(self.main[-1], state="running")
        fleet.build_fails.add(self.main[-1])
        original_wait = fleet.wait

        def wait(job_id, timeout):
            if job_id == failed:
                fleet.job_table[job_id].update(state="failed", error="exit status 65")
                return 1
            fleet.build_fails.discard(self.main[-1])
            return original_wait(job_id, timeout)

        fleet.wait = wait
        code, verdict = self.run_cli(fleet)
        self.assertEqual(code, 0, self.err)
        self.assertEqual(verdict["sha"], self.main[4])
        self.assertEqual(fleet.submits.count(self.main[-1]), 1)

    def test_commit_that_does_not_build_is_skipped(self):
        fleet = self.fleet(self.bad_from(7))
        fleet.build_fails.add(self.main[6])
        code, verdict = self.run_cli(fleet)
        self.assertEqual(code, 0, self.err)
        self.assertEqual(verdict["result"], "ambiguous")
        self.assertEqual(verdict["candidates"], [self.main[6], self.main[7]])
        self.assertEqual(fleet.submits.count(self.main[6]), 1, "a build that does not compile is not built again")
        self.assertIn("exit status 65", self.saved()["results"][self.main[6]]["why"])
        fleet = self.fleet(self.bad_from(9))
        fleet.build_fails.add(self.main[6])
        self.state = self.root / "state2" / f"{HASH}.json"  # its own receipts: a new fleet knows no old job
        code, verdict = self.run_cli(fleet)
        self.assertEqual((verdict["result"], verdict["sha"]), ("first_bad", self.main[9]))

    def test_cancelled_own_build_is_built_again_under_a_new_receipt(self):
        fleet = self.fleet(self.bad_from(7))
        fleet.build_cancels[self.main[6]] = 1  # next to the first bad commit: losing it makes the verdict ambiguous
        code, verdict = self.run_cli(fleet)
        self.assertEqual(code, 0, self.err)
        self.assertEqual((verdict["result"], verdict["sha"]), ("first_bad", self.main[7]))
        self.assertEqual(fleet.submits.count(self.main[6]), 2)
        self.assertIn(f"{self.main[6][:12]}-submit-2.json", fleet.receipts)
        ended = self.saved()["builds"][self.main[6]]["ended"]
        self.assertEqual([(item["state"], item["failure"]) for item in ended], [("cancelled", "infra")])

    def test_build_lost_past_the_retries_makes_the_commit_untestable(self):
        fleet = self.fleet(self.bad_from(7))
        fleet.build_cancels[self.main[-1]] = 99
        code, verdict = self.run_cli(fleet)
        self.assertEqual(code, 0, self.err)
        self.assertEqual(verdict["result"], "untestable")
        self.assertEqual(fleet.submits.count(self.main[-1]), 1 + sb.DEFAULT_INFRA_RETRIES)
        self.assertIn("builds ended without a result", verdict["evidence"])

    def test_other_crash_is_not_good(self):
        hits = self.bad_from(7)
        hits[self.main[6]] = ["other"]
        fleet = self.fleet(hits)
        code, verdict = self.run_cli(fleet)
        self.assertEqual(code, 0, self.err)
        self.assertEqual(verdict["result"], "ambiguous")
        self.assertEqual(self.saved()["results"][self.main[6]]["verdict"], "untestable")

    def test_unreadable_report_of_a_passing_run_is_not_clean(self):
        hits = self.bad_from(7)
        hits[self.main[6]] = ["unreadable"]  # os-matrix PASS, but crash_signature.py could not read its report
        fleet = self.fleet(hits)
        code, verdict = self.run_cli(fleet)
        self.assertEqual(code, 0, self.err)
        self.assertEqual(verdict["result"], "ambiguous")
        result = self.saved()["results"][self.main[6]]
        self.assertEqual(result["verdict"], "untestable")
        self.assertIn("unreadable report", result["why"])

    def test_step_past_the_deadline_exits_75_and_resumes_with_the_same_attempt(self):
        fleet = self.fleet(self.bad_from(5))
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
        fleet = self.fleet(hits)
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
        fleet = self.fleet(hits)
        code, verdict = self.run_cli(fleet)
        self.assertEqual(verdict["result"], "untestable")
        self.assertEqual(len(fleet.steps), 1 + sb.DEFAULT_INFRA_RETRIES)

    # -- test replays

    def test_test_replay_lays_the_runner_refs_test_over_commits_without_it(self):
        fleet = self.fleet(self.bad_from(9))
        code, verdict = self.run_cli(fleet, replay=TEST_REPLAY)
        self.assertEqual(code, 0, self.err)
        self.assertEqual((verdict["result"], verdict["sha"]), ("first_bad", self.main[9]))
        self.assertEqual(fleet.submits, [], "a test replay builds no app")
        ran = {origin: ref for origin, ref, _ in fleet.test_runs}
        self.assertIn(self.main[0], ran, "the good end, which predates the test (c6), ran it")
        for origin, ref in ran.items():
            if self.main.index(origin) < 6:
                self.assertNotEqual(ref, origin)
                self.assertEqual(git(self.repo, "rev-parse", f"{ref}^1"), origin)
                self.assertEqual(git(self.repo, "show", f"{ref}:Packages/macOS/Demo/DemoTests.swift"),
                                 "func testCrash() {}")
            else:
                self.assertEqual(ref, origin, "a commit with the runner ref's test runs as itself")
        self.assertEqual(git(self.remote, "for-each-ref", "refs/heads/stability-bisect"), "",
                         "every scratch branch is deleted once its commit is judged")
        self.assertEqual(self.saved()["test_files"], ["Packages/macOS/Demo/DemoTests.swift"])

    def test_overlay_commit_is_the_same_on_every_run(self):
        files = ["Packages/macOS/Demo/DemoTests.swift"]
        first = self.git.overlay(self.main[2], self.main[-1], files)
        self.assertEqual(self.git.overlay(self.main[2], self.main[-1], files), first)
        self.assertEqual(self.git.overlay(self.main[7], self.main[-1], files), self.main[7])
        with self.assertRaises(sb.BisectError):
            self.git.overlay(self.main[7], self.main[2], files)  # not at the runner ref

    def test_test_replay_that_ran_no_test_is_untestable_not_bad(self):
        hits = self.bad_from(9)
        hits[self.main[6]] = ["notests"]  # the first midpoint: every run "failed (exit 1)" with no test found
        fleet = self.fleet(hits)
        code, verdict = self.run_cli(fleet, replay=TEST_REPLAY)
        self.assertEqual(code, 0, self.err)
        self.assertEqual((verdict["result"], verdict["sha"]), ("first_bad", self.main[9]))
        result = self.saved()["results"][self.main[6]]
        self.assertEqual(result["verdict"], "untestable")
        self.assertIn("ran no test", result["why"])

    def test_test_replay_failing_another_way_is_not_blamed(self):
        hits = self.bad_from(9)
        hits[self.main[8]] = ["other"]  # the commit before the first bad one fails another test
        fleet = self.fleet(hits)
        code, verdict = self.run_cli(fleet, "--post", replay=TEST_REPLAY)
        self.assertEqual(code, 0, self.err)
        self.assertEqual(verdict["result"], "ambiguous")
        self.assertEqual(verdict["candidates"], [self.main[8], self.main[9]])
        self.assertEqual(fleet.posted, [], "no commit is blamed")
        self.assertIn("another test", self.saved()["results"][self.main[8]]["why"])

    def test_test_replay_hang_of_the_test_with_the_signature_is_a_hit(self):
        hits = self.bad_from(9, ("hang",))
        hits[self.main[8]] = ["hang-other"]  # hung, but its stack sample is another signature
        fleet = self.fleet(hits)
        code, verdict = self.run_cli(fleet, replay=TEST_REPLAY)
        self.assertEqual(code, 0, self.err)
        self.assertEqual(verdict["result"], "ambiguous")
        self.assertEqual(verdict["candidates"], [self.main[8], self.main[9]])
        self.assertIn(OTHER_HASH, self.saved()["results"][self.main[8]]["why"])

    def test_test_replay_crash_of_the_test_is_a_hit(self):
        fleet = self.fleet(self.bad_from(9, ("crash",)))
        code, verdict = self.run_cli(fleet, replay=TEST_REPLAY)
        self.assertEqual((verdict["result"], verdict["sha"]), ("first_bad", self.main[9]))

    def test_test_replay_toolchain_mismatch_is_no_verdict(self):
        hits = self.bad_from(9)
        hits[self.main[-1]] = ["toolchain"]
        fleet = self.fleet(hits)
        code, verdict = self.run_cli(fleet, replay=TEST_REPLAY)
        self.assertEqual(code, 0, self.err)
        self.assertEqual(verdict["result"], "untestable")
        self.assertEqual(len(fleet.test_runs), 1 + sb.DEFAULT_INFRA_RETRIES, "a toolchain mismatch takes new attempts")
        self.assertEqual(len({key for _, _, key in fleet.test_runs}), 1 + sb.DEFAULT_INFRA_RETRIES)

    def test_test_at_commit_skips_commits_without_the_test(self):
        fleet = self.fleet({sha: ["hit"] for sha in self.main[9:]})
        code, verdict = self.run_cli(fleet, "--test-at-commit", replay=TEST_REPLAY)
        self.assertEqual(code, 0, self.err)
        self.assertEqual(verdict["result"], "untestable")  # c6 adds the test: the good end c0 cannot run it
        self.assertIn("the good end", verdict["evidence"])
        self.assertEqual([origin for origin, _, _ in fleet.test_runs], [self.main[-1]])
        code, verdict = self.run_cli(fleet, "--test-at-commit", replay=TEST_REPLAY, good=self.main[6])
        self.assertEqual(code, 1)  # another bisect's state
        self.state = self.root / "state2" / f"{HASH}.json"
        code, verdict = self.run_cli(fleet, "--test-at-commit", replay=TEST_REPLAY, good=self.main[6])
        self.assertEqual((verdict["result"], verdict["sha"]), ("first_bad", self.main[9]))

    def test_test_replay_refuses_a_remote_of_another_repository(self):
        git(self.repo, "remote", "set-url", "origin", str(self.root / "elsewhere.git"))
        code, _ = self.run_cli(self.fleet({}), replay=TEST_REPLAY)
        self.assertEqual(code, 1)
        self.assertIn("is not manaflow-ai/cmux", self.err)

    # -- CLI

    def test_plan_submits_nothing(self):
        fleet = self.fleet({})
        fleet.add_build(self.main[3])
        code, plan = self.run_cli(fleet, cmd="plan")
        self.assertEqual(code, 0, self.err)
        self.assertEqual(plan["first_parent_commits"], len(self.main) - 1)
        self.assertEqual(plan["reusable_builds"], [self.main[3]])
        self.assertEqual(fleet.submits, [])
        code, plan = self.run_cli(fleet, cmd="plan", replay=TEST_REPLAY)
        self.assertEqual(plan["test_files"], ["Packages/macOS/Demo/DemoTests.swift"])

    def test_refuses_bad_arguments(self):
        fleet = self.fleet({})
        self.assertEqual(self.run_cli(fleet, good=self.side[0])[0], 1)  # not on the first-parent line
        self.assertIn("first-parent", self.err)
        self.assertEqual(self.run_cli(fleet, replay="repro:missing")[0], 1)
        self.assertEqual(self.run_cli(fleet, replay="fuzz:1:99")[0], 1)
        self.assertEqual(self.run_cli(fleet, replay="fuzz-input:x")[0], 1)
        self.assertEqual(self.run_cli(fleet, "--test-at-commit")[0], 1)  # not a test replay
        self.assertEqual(self.run_cli(fleet, "--test-file", "elsewhere/T.swift", replay=TEST_REPLAY)[0], 1)
        self.assertEqual(fleet.submits, [])

    def test_state_of_another_bisect_is_refused(self):
        fleet = self.fleet(self.bad_from(7))
        self.assertEqual(self.run_cli(fleet)[0], 0)
        self.assertEqual(self.run_cli(fleet, good=self.main[1])[0], 1)
        self.assertIn("another bisect", self.err)


FAKE_CI = r'''
import json, os, sys, time
from pathlib import Path
control = Path(os.environ["FAKE_CI"])
state = json.loads(control.read_text())
state["calls"].append(sys.argv[1:])
control.write_text(json.dumps(state))
cmd, args = sys.argv[1], sys.argv[2:]
def save():
    control.write_text(json.dumps(state))
if cmd == "status":
    if args and args[0] == "--ref":
        print(json.dumps({"jobs": [job for job in state["jobs"].values() if job["ref"] == args[1]]}))
    elif args:
        print(json.dumps(state["jobs"][args[0]]))
    else:
        print(json.dumps({"jobs": list(state["jobs"].values())}))
elif cmd == "build":
    receipt = Path(args[args.index("--receipt") + 1])
    ref = args[args.index("--ref") + 1]
    mode = state.get("build", "ok")
    if mode in ("hang", "lost"):
        receipt.with_name(receipt.name + ".pending").write_text("{}")
        if mode == "hang":
            time.sleep(60)
        sys.exit(1)
    job = f"{len(state['jobs']) + 1:024x}"
    state["jobs"][job] = {"id": job, "kind": "cmux", "ref": ref, "state": "queued", "variant": "dev",
                          "source_digest": ref}
    save()
    receipt.write_text(json.dumps({"id": job}))
elif cmd == "wait":
    code = state["wait_codes"].pop(0) if state["wait_codes"] else 0
    if code == 0:
        state["jobs"][args[0]]["state"] = "done"
    save()
    sys.exit(code)
elif cmd == "run":
    print("cmux-ci: step " + "e" * 24 + " (light, key " + args[args.index("--key") + 1] + ")", file=sys.stderr)
    print(state.get("run_log", ""))
    sys.exit(state.get("run_code", 0))
else:
    sys.exit(2)
'''

FAKE_SIGNATURE = r'''
import json, sys
from pathlib import Path
status = 0
for name in sys.argv[1:]:
    text = Path(name).read_text().strip()
    if text == "traceback":
        print('{"hash12": "0f0f0f0f0f0f", "kind": "ips"}')
        sys.stderr.write("Traceback (most recent call last):\nValueError: bad frame\n")
        sys.exit(1)
    if text == "unreadable":
        print(f"crash_signature: {name}: [Errno 13] Permission denied", file=sys.stderr)
        status = 1
    elif text:
        print(json.dumps({"hash12": text, "kind": "ips"}))
sys.exit(status)
'''

FAKE_ISSUES = r'''
import json, os, sys
from pathlib import Path
Path(os.environ["FAKE_ISSUES_ARGV"]).write_text(json.dumps(sys.argv[1:]))
sys.exit(int(os.environ.get("FAKE_ISSUES_EXIT", "0")))
'''

FAKE_OS_MATRIX = r'''
import json, os, sys
from pathlib import Path
Path(os.environ["FAKE_OS_MATRIX_ARGV"]).write_text(json.dumps({"argv": sys.argv[1:], "client": os.environ["CMUX_CI"]}))
print("cmux-ci: step " + "d" * 24)
sys.exit(1)
'''


def executable(path: Path, body: str) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(f"#!{sys.executable}\n{body}")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)
    return path


class CmuxCiTests(unittest.TestCase):
    """The real adapter: argv, exit codes, receipts, and the bisect's never-resubmit rule through it."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.client = executable(self.root / "bin/cmux-ci", FAKE_CI)
        executable(self.root / "scripts/cmux-next/crash_signature.py", FAKE_SIGNATURE)
        executable(self.root / "scripts/cmux-next/stability_issues.py", FAKE_ISSUES)
        executable(self.root / "scripts/cmux-next/os-matrix.sh", FAKE_OS_MATRIX)
        self.control = self.root / "control.json"
        self.write({"calls": [], "jobs": {}, "wait_codes": []})
        self.env = mock.patch.dict(os.environ, {"FAKE_CI": str(self.control), **GIT_ENV,
                                                "FAKE_ISSUES_ARGV": str(self.root / "issues.json"),
                                                "FAKE_OS_MATRIX_ARGV": str(self.root / "os-matrix.json")})
        self.env.start()
        self.ci = sb.CmuxCi(self.root, str(self.client), "manaflow-ai/cmux", submit_timeout=2, tool_timeout=30)
        self.repo, self.main, _, _ = make_repo(self.root)
        self.now = [0.0]

    def tearDown(self):
        self.env.stop()
        self.tmp.cleanup()

    def write(self, state):
        self.control.write_text(json.dumps(state))

    def read(self):
        return json.loads(self.control.read_text())

    def update(self, **values):
        self.write({**self.read(), **values})

    def calls(self, cmd):
        return [call for call in self.read()["calls"] if call[0] == cmd]

    def bisect(self, deadline=10_000.0):
        opts = sb.Options(hash12=HASH, good=self.main[0], bad=self.main[-1], replay=sb.parse_replay("fuzz:1:5"),
                          majors="26", runner_ref=self.main[-1])
        bisect = sb.Bisect(opts, self.ci, sb.Git(self.repo), self.root / "state" / f"{HASH}.json", deadline=deadline,
                           clock=self.tick, log=lambda text: None)
        bisect.load()
        return bisect

    def tick(self):
        self.now[0] += 1000
        return self.now[0]

    def test_build_argv_and_receipt(self):
        sha = self.main[3]
        receipt = self.root / "work" / "r.json"
        job = self.ci.submit_build(sha, "bisect-x", "stability-bisect-x", receipt)
        self.assertEqual(sb.read_receipt(receipt), job)
        self.assertEqual(self.calls("build"), [["build", "cmux", "--ref", sha, "--tag", "bisect-x", "--workspace",
                                                "stability-bisect-x", "--agent", "stability-bisect", "--receipt",
                                                str(receipt)]])

    def test_wait_timeouts_never_resubmit_and_a_resumed_run_waits_on_the_same_job(self):
        self.update(wait_codes=[2] * 50)
        with self.assertRaises(sb.Pending):
            self.bisect(deadline=4500.0).build(self.main[-1])
        waits = self.calls("wait")
        self.assertGreaterEqual(len(waits), 2)
        self.assertEqual(len(self.calls("build")), 1)
        job = waits[0][1]
        self.assertTrue(all(call[1] == job for call in waits), "every wait is on the one submitted job")
        self.assertEqual(waits[0][2:4], ["--interval", "30"])
        self.update(wait_codes=[])
        self.now[0] = 0.0
        self.assertEqual(self.bisect().build(self.main[-1]), job)
        self.assertEqual(len(self.calls("build")), 1, "the resumed run resubmitted")

    def test_client_timeout_on_submission_leaves_pending_and_never_resubmits(self):
        self.update(build="hang")
        with self.assertRaises(sb.Pending):
            self.bisect().build(self.main[-1])
        self.update(build="ok")
        with self.assertRaises(sb.Pending) as raised:
            self.bisect().build(self.main[-1])
        self.assertIn("unknown outcome", str(raised.exception))
        self.assertEqual(len(self.calls("build")), 1)

    def test_lost_submission_response_refuses_with_pending(self):
        self.update(build="lost")
        with self.assertRaises(sb.Pending) as raised:
            self.ci.submit_build(self.main[3], "t", "w", self.root / "work" / "r.json")
        self.assertIn(".pending", str(raised.exception))

    def test_wait_exit_1_is_a_failure_only_when_the_job_ended(self):
        sha = self.main[3]
        job = self.ci.submit_build(sha, "t", "w", self.root / "work" / "r.json")
        bisect = self.bisect()
        state = self.read()
        state["jobs"][job]["state"] = "running"
        state["wait_codes"] = [1]
        self.write(state)
        with self.assertRaises(sb.Pending):
            bisect.await_job(job, "build")
        state = self.read()
        state["jobs"][job].update(state="cancelled", error="cancelled")
        state["wait_codes"] = [1]
        self.write(state)
        self.assertEqual(bisect.await_job(job, "build"), "failed")

    def test_run_tests_argv_and_step(self):
        sha = self.main[3]
        self.update(run_log="Swift suite results (P):", run_code=1)
        run = self.ci.run_tests(sha, "Packages/macOS/Demo", ["A/b"] * 3, "key-1", 30)
        self.assertEqual((run.code, run.step), (1, "e" * 24))
        self.assertEqual(self.calls("run"), [["run", "--class", "light", "--script", "scripts/ci/package-test-lane.sh",
                                              "--ref", sha, "--repo", "manaflow-ai/cmux", "--background", "--key",
                                              "key-1", "--arg=suite", "--arg=Packages/macOS/Demo", "--arg=A/b",
                                              "--arg=A/b", "--arg=A/b"]])

    def test_os_matrix_argv(self):
        run = self.ci.os_matrix("b" * 24, "26", "fuzz", 21, 30, self.main[-1], 2, self.root / "out", 30)
        self.assertEqual((run.code, run.step), (1, "d" * 24))
        seen = json.loads((self.root / "os-matrix.json").read_text())
        self.assertEqual(seen["client"], str(self.client))
        self.assertEqual(seen["argv"], ["--build", "b" * 24, "--os", "26", "--suite", "fuzz", "--ref", self.main[-1],
                                        "--attempt", "2", "--out", str(self.root / "out"), "--seed", "21",
                                        "--minutes", "30"])

    def test_signatures_name_every_report_they_could_not_read(self):
        reports = self.root / "reports"
        reports.mkdir()
        paths = []
        for name, text in (("a.ips", HASH), ("b.ips", "unreadable"), ("c.ips", "traceback"), ("d.ips", "")):
            (reports / name).write_text(text)
            paths.append(reports / name)
        found = self.ci.signatures(paths)
        self.assertEqual(found.hashes, {HASH, OTHER_HASH})
        self.assertEqual([item.split(":")[0] for item in found.unread], ["b.ips", "c.ips", "d.ips"])
        self.assertIn("ValueError", found.unread[1])
        self.assertEqual(self.ci.signatures([]), sb.Reports())

    def test_post_argv_and_deferral(self):
        verdict = {"result": "first_bad", "sha": self.main[5], "range": "a..b", "evidence": "3/3"}
        self.ci.post(HASH, verdict)
        self.assertEqual(json.loads((self.root / "issues.json").read_text()),
                         ["bisect-result", "--hash12", HASH, "--first-bad", self.main[5], "--range", "a..b",
                          "--evidence", "3/3"])
        self.ci.post(HASH, {"result": "flaky", "hits": "1/3", "range": "a..b"})
        self.assertEqual(json.loads((self.root / "issues.json").read_text())[3:5], ["--flaky", "1/3"])
        with mock.patch.dict(os.environ, {"FAKE_ISSUES_EXIT": "75"}):
            with self.assertRaises(sb.Pending):
                self.ci.post(HASH, verdict)
        with mock.patch.dict(os.environ, {"FAKE_ISSUES_EXIT": "1"}):
            with self.assertRaises(sb.BisectError):
                self.ci.post(HASH, verdict)


class UnitTests(unittest.TestCase):
    def test_suite_runs_pair_each_row_with_its_section(self):
        sections = [suite_section("A/testCrash", outcome) for outcome in ("miss", "hit", "hang")]
        log = ("\n".join(section for section, _ in sections) + "\nSwift suite results (Packages/macOS/CmuxNext):\n"
               + "suite result time\n" + "\n".join(f"A/testCrash {result} 3s" for _, result in sections) + "\n")
        runs = sb.suite_runs(log, ["A/testCrash"] * 3)
        self.assertEqual([run.result for run in runs], ["passed", "failed (exit 1)", "stalled/timeout"])
        self.assertIn("recorded an issue", runs[1].section)
        self.assertNotIn("Swift suite results", runs[2].section)
        self.assertIsNone(sb.suite_runs("error: build failed", ["A/testCrash"] * 3))

    def classify(self, outcome, hashes=(), unread=()):
        section, result = suite_section("DemoTests/testCrash", outcome)
        return sb.classify_test_run(sb.SuiteRun(result, section), "testCrash", HASH,
                                    sb.Reports(set(hashes), list(unread)))

    def test_classify_test_run(self):
        self.assertEqual(self.classify("miss")[0], "miss")
        self.assertEqual(self.classify("hit")[0], "hit")
        self.assertEqual(self.classify("crash")[0], "hit")
        self.assertEqual(self.classify("hang", hashes={HASH})[0], "hit")
        self.assertEqual(self.classify("hang-other", hashes={OTHER_HASH})[0], "other")
        self.assertEqual(self.classify("hit", unread=["x: no signature"])[0], "other")
        self.assertEqual(self.classify("other")[0], "other")
        self.assertEqual(self.classify("notests")[0], "other")
        self.assertEqual(self.classify("toolchain")[0], "no-verdict")
        # One test ran and failed under a display name without the filter's token: still this test.
        run = sb.SuiteRun("failed (exit 1)", '◇ Test "Crash on close" started.\n'
                                             '✘ Test "Crash on close" failed after 0.1 seconds with 1 issue.\n')
        self.assertEqual(sb.classify_test_run(run, "testCrash", HASH, sb.Reports())[0], "hit")
        xctest = sb.SuiteRun("failed (exit 1)", "Test Case '-[DemoTests.DemoTests testOther]' started.\n"
                                                "Test Case '-[DemoTests.DemoTests testOther]' failed (0.1 seconds).\n"
                                                "Test Case '-[DemoTests.DemoTests testCrash]' started.\n"
                                                "Test Case '-[DemoTests.DemoTests testCrash]' failed (0.1 seconds).\n")
        self.assertEqual(sb.classify_test_run(xctest, "testCrash", HASH, sb.Reports())[0], "hit")

    def test_report_texts_hold_samples_and_sanitizer_output(self):
        section = ("x\n::group::Stack sample of xctest (1)\nCall graph:\n  frame\n::endgroup::\n"
                   "==12==ERROR: AddressSanitizer: heap-use-after-free\n")
        texts = sb.report_texts(section)
        self.assertEqual([name for name, _ in texts], ["hang-0.sample.txt", "sanitizer.log"])
        self.assertEqual(texts[0][1], "Call graph:\n  frame\n")
        self.assertNotIn("Call graph", texts[1][1])
        self.assertEqual(sb.report_texts("plain failure\n"), [])

    def test_build_failure_separates_compile_from_infra(self):
        self.assertEqual(sb.build_failure({"state": "failed", "error": "exit status 65"}), "compile")
        self.assertEqual(sb.build_failure({"state": "failed", "error": "exit status 78"}), "infra")
        self.assertEqual(sb.build_failure({"state": "cancelled", "error": "exit status 65"}), "infra")
        for error in ("stalled: no job log output for 30m0s", "lease lost: aws2 stopped renewing", "", None,
                      "artifact_missing: the worker reported artifact x but no store or cache has it"):
            self.assertEqual(sb.build_failure({"state": "failed", "error": error}), "infra", error)

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

    def test_pick_build_takes_done_clean_dev_builds_only(self):
        sha = "a" * 40
        jobs = [{"id": "1" * 24, "kind": "cmux", "ref": sha, "state": "failed"},
                {"id": "2" * 24, "kind": "cmux", "ref": sha, "state": "done", "variant": "production"},
                {"id": "3" * 24, "kind": "cmux", "ref": sha, "state": "running", "variant": "dev"},
                {"id": "5" * 24, "kind": "cmux", "ref": sha, "state": "done", "source_digest": "b" * 40},
                {"id": "6" * 24, "kind": "cmux", "ref": sha, "state": "done", "source_ref": {"patch": "sha256:x"}}]
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
