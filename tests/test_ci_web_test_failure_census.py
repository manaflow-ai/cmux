#!/usr/bin/env python3
"""Web test failure census: bun log and JUnit parsing, and the census over a fake GitHub."""
import importlib.util
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).parents[1]
sys.path.insert(0, str(ROOT / "scripts/ci"))
spec = importlib.util.spec_from_file_location("web_census", ROOT / "scripts/ci/web_test_failure_census.py")
census = importlib.util.module_from_spec(spec)
spec.loader.exec_module(census)

# Trimmed from job 117692683085 (PR #21651): bun prints a header per file, the
# failure with its timeout note, and repeats the failure in a closing summary.
LOG = """\
2026-10-18T13:51:01.6350638Z ##[group]tests/vm-route-deadlines.test.ts:
2026-10-18T13:51:03.1000000Z (pass) VM route answer deadlines > a mutation that never answers [1.20ms]
2026-10-18T13:51:08.5993523Z (fail) VM route answer deadlines > the window is measured from the request's start, with a floor [5017.41ms]
2026-10-18T13:51:08.6000924Z   ^ this test timed out after 5000ms.
2026-10-18T13:51:08.7000000Z ##[endgroup]
2026-10-18T13:51:08.8000000Z ##[group]tests/vm-workflows.test.ts:
2026-10-18T13:51:09.0000000Z (fail) VM workflows > pause records a wake
2026-10-18T13:51:09.1000000Z error: expect(received).toBe(expected)
2026-10-18T13:51:15.8202579Z 2 tests failed:
2026-10-18T13:51:15.8202781Z (fail) VM route answer deadlines > the window is measured from the request's start, with a floor [5017.41ms]
2026-10-18T13:51:15.8203023Z   ^ this test timed out after 5000ms.
2026-10-18T13:51:15.8203024Z (fail) VM workflows > pause records a wake
2026-10-18T13:51:15.8203159Z  1257 pass
"""

# bun 1.3's JUnit report: one suite per file, nested suites per describe block.
JUNIT = """<?xml version="1.0" encoding="UTF-8"?>
<testsuites name="bun test" tests="3" failures="2">
  <testsuite name="./tests/vm-route-deadlines.test.ts" file="./tests/vm-route-deadlines.test.ts">
    <testsuite name="VM route answer deadlines" file="./tests/vm-route-deadlines.test.ts" line="30">
      <testcase name="passes" classname="VM route answer deadlines" file="./tests/vm-route-deadlines.test.ts" line="31" />
      <testcase name="the window &lt;floor&gt;" classname="x" file="./tests/vm-route-deadlines.test.ts" line="40">
        <failure type="TimeoutError" />
      </testcase>
    </testsuite>
    <testcase name="top level" classname="" file="./tests/vm-route-deadlines.test.ts" line="90">
      <failure type="AssertionError" />
    </testcase>
  </testsuite>
</testsuites>
"""

NOW = datetime(2026, 10, 18, 20, 0, tzinfo=timezone.utc)


class Parsing(unittest.TestCase):
    def test_log_failures_keep_their_file_and_timeout_and_skip_the_summary_repeat(self):
        found = census.parse_log(LOG)
        self.assertEqual(found, [
            {"file": "tests/vm-route-deadlines.test.ts",
             "test": "VM route answer deadlines > the window is measured from the request's start, with a floor",
             "kind": "timeout", "message": "timed out after 5000ms"},
            {"file": "tests/vm-workflows.test.ts", "test": "VM workflows > pause records a wake",
             "kind": "failure", "message": ""},
        ])

    def test_a_failure_only_in_the_summary_is_kept_without_a_file(self):
        found = census.parse_log("1 tests failed:\n(fail) crashed before its header [3ms]\n")
        self.assertEqual([(f["file"], f["test"]) for f in found], [("", "crashed before its header")])

    def test_junit_joins_describe_names_like_the_console_and_marks_timeouts(self):
        found = census.parse_junit(JUNIT)
        self.assertEqual([(f["file"], f["test"], f["kind"]) for f in found], [
            ("tests/vm-route-deadlines.test.ts", "VM route answer deadlines > the window <floor>", "timeout"),
            ("tests/vm-route-deadlines.test.ts", "top level", "failure"),
        ])

    def test_absolute_runner_paths_become_web_relative(self):
        self.assertEqual(census.web_path("/home/runner/_work/cmux/cmux/web/tests/a.test.ts"), "tests/a.test.ts")
        self.assertEqual(census.web_path("./tests/a.test.ts"), "tests/a.test.ts")

    def test_matching_by_basename_path_and_name_substring(self):
        item = {"file": "tests/vm-route-deadlines.test.ts", "test": "VM route answer deadlines > floor"}
        self.assertTrue(census.matches(item, None, "vm-route-deadlines.test.ts"))
        self.assertTrue(census.matches(item, None, "web/tests/vm-route-deadlines.test.ts"))
        self.assertTrue(census.matches(item, "answer DEADLINES", None))
        self.assertFalse(census.matches(item, None, "route-deadlines.test.ts"))
        self.assertFalse(census.matches(item, "pause", None))

    def test_a_report_declaring_entities_is_refused(self):
        bomb = '<?xml version="1.0"?><!DOCTYPE x [<!ENTITY a "aaaa">]><testsuites>&a;</testsuites>'
        with self.assertRaises(ValueError):
            census.parse_junit(bomb)

    def test_only_this_repositorys_main_is_main(self):
        self.assertTrue(census.is_fork({"head_repository_id": 2, "repository_id": 1}))
        self.assertFalse(census.is_fork({"head_repository_id": 1, "repository_id": 1}))
        self.assertFalse(census.is_fork({}))
        slim = census.slim_run({"id": 9, "head_repository": {"id": 2}, "repository": {"id": 1}})
        self.assertTrue(census.is_fork(slim))

    def test_web_shard_job_names(self):
        self.assertEqual(census.shard_of("web / Web tests (2/4)"), 2)
        self.assertIsNone(census.shard_of("web / Web typecheck"))


class Reruns(unittest.TestCase):
    failure = {"run_id": 1, "attempt": 1, "shard": 2}

    def test_a_later_attempt_that_passed_the_shard(self):
        jobs = [{"name": "web / Web tests (2/4)", "run_attempt": 1, "conclusion": "failure"},
                {"name": "web / Web tests (2/4)", "run_attempt": 2, "conclusion": "success"}]
        self.assertEqual(census.rerun_outcome(self.failure, [], jobs), "passed")

    def test_a_later_attempt_that_failed_it_again(self):
        jobs = [{"name": "web / Web tests (2/4)", "run_attempt": 2, "conclusion": "failure"},
                {"name": "web / Web tests (1/4)", "run_attempt": 2, "conclusion": "success"}]
        self.assertEqual(census.rerun_outcome(self.failure, [], jobs), "failed")

    def test_another_green_run_of_the_same_sha(self):
        runs = [{"id": 1, "run_attempt": 1, "conclusion": "failure"}, {"id": 2, "run_attempt": 1, "conclusion": "success"}]
        self.assertEqual(census.rerun_outcome(self.failure, runs, []), "passed")

    def test_the_failed_attempt_itself_is_not_a_rerun(self):
        runs = [{"id": 1, "run_attempt": 1, "conclusion": "success"}]
        self.assertEqual(census.rerun_outcome(self.failure, runs, []), "none")


class FakeGitHub:
    repo = "manaflow-ai/cmux"
    calls = 0


class FakeSource(census.Source):
    """Canned API answers, keyed like the real calls."""

    def __init__(self, artifacts=None, reports=None, runs=None, jobs=None, logs=None, sha_runs=None, prs=None,
                 remaining=5000):
        super().__init__(FakeGitHub(), None)
        self._artifacts, self._reports = artifacts or {}, reports or {}
        self._runs, self._jobs, self._logs = runs or {}, jobs or {}, logs or {}
        self._sha_runs, self._prs, self.remaining = sha_runs or {}, prs or {}, remaining
        self.listed = []

    def core_remaining(self):
        return self.remaining, 0

    def artifacts(self, name, since):
        self.listed.append(name)
        return [a for a in self._artifacts.get(name, []) if census.parse_time(a["created_at"]) >= since]

    def junit(self, artifact):
        return self._reports[artifact["id"]]

    def runs(self, since, max_runs, branch=None):
        return self._runs.get(branch, [])[:max_runs]

    def jobs(self, run, attempt=None):
        return self._jobs.get(run["id"], [])

    def log(self, job_id):
        return self._logs[job_id]

    def sha_runs(self, sha):
        return self._sha_runs.get(sha, [])

    def pr_for_branch(self, branch):
        return self._prs.get(branch)


def artifact(id_, run_id, sha, branch, at="2026-10-18T13:51:20Z", head_repo=1):
    return {"id": id_, "created_at": at, "expired": False,
            "workflow_run": {"id": run_id, "head_sha": sha, "head_branch": branch,
                             "head_repository_id": head_repo, "repository_id": 1}}


class Census(unittest.TestCase):
    def test_junit_census_splits_main_and_prs_with_rerun_and_links(self):
        src = FakeSource(
            artifacts={
                "web-test-junit-shard2-attempt1": [artifact(10, 100, "aaa", "fix/repause"),
                                                   artifact(11, 200, "bbb", "main"),
                                                   artifact(12, 300, "ccc", "old", at="2026-09-01T00:00:00Z")],
            },
            reports={10: JUNIT, 11: JUNIT.replace("TimeoutError", "AssertionError")},
            sha_runs={"aaa": [{"id": 100, "run_attempt": 2, "conclusion": "success"}]},
            jobs={100: [{"name": "web / Web tests (2/4)", "run_attempt": 1, "conclusion": "failure",
                         "html_url": "https://github.com/x/job/1"},
                        {"name": "web / Web tests (2/4)", "run_attempt": 2, "conclusion": "success"}]},
            prs={"fix/repause": 21651},
        )
        report = census.census(src, test="window", file="vm-route-deadlines.test.ts", days=7, now=NOW)
        self.assertEqual(report["source"], "junit")
        self.assertEqual(report["junit_reports_read"], 2)  # the September report is outside the window
        by_run = {f["run_id"]: f for f in report["failures"]}
        self.assertEqual(set(by_run), {100, 200})
        self.assertEqual((by_run[100]["where"], by_run[100]["pr"], by_run[100]["rerun"]), ("pr", 21651, "passed"))
        self.assertEqual(by_run[100]["job_url"], "https://github.com/x/job/1")
        self.assertEqual((by_run[200]["where"], by_run[200]["rerun"]), ("main", "none"))
        self.assertEqual(report["summary"]["main"], 1)
        self.assertEqual(report["summary"]["prs"], ["21651"])
        self.assertIn("1 on main", census.render(report))

    def test_a_forks_main_counts_as_a_pr_and_skips_the_pr_lookup(self):
        src = FakeSource(
            artifacts={"web-test-junit-shard1-attempt1": [artifact(10, 100, "aaa", "main", head_repo=77)]},
            reports={10: JUNIT}, prs={"main": 1})
        report = census.census(src, test="top level", file=None, days=7, now=NOW)
        [item] = report["failures"]
        self.assertEqual((item["where"], item["fork"], item.get("pr")), ("pr", True, None))
        self.assertEqual(report["summary"]["main"], 0)

    def test_a_poisoned_report_is_skipped_not_fatal(self):
        src = FakeSource(artifacts={"web-test-junit-shard1-attempt1": [artifact(10, 100, "aaa", "main")]},
                         reports={10: "<!DOCTYPE x><testsuites/>"})
        report = census.census(src, test=None, file="a.test.ts", days=7, now=NOW)
        self.assertEqual(report["failures"], [])

    def test_junit_listing_stops_at_the_first_attempt_no_shard_reached(self):
        src = FakeSource(artifacts={"web-test-junit-shard1-attempt1": [artifact(10, 100, "aaa", "main")]},
                         reports={10: JUNIT})
        census.census(src, test=None, file="x.test.ts", days=7, now=NOW)
        self.assertEqual(src.listed, [f"web-test-junit-shard{s}-attempt{a}" for a in (1, 2) for s in (1, 2, 3, 4)])

    def test_logs_fallback_reads_main_named_branches_and_a_capped_sample(self):
        run = lambda i, branch: {"id": i, "run_attempt": 1, "status": "completed", "conclusion": "failure",
                                 "head_sha": f"s{i}", "head_branch": branch}
        web_job = lambda i: {"id": i * 10, "name": "web / Web tests (2/4)", "run_attempt": 1,
                             "conclusion": "failure", "html_url": f"https://github.com/x/job/{i * 10}",
                             "started_at": f"2026-10-18T1{i}:00:00Z"}
        src = FakeSource(
            runs={"main": [run(1, "main")], "fix/repause": [run(2, "fix/repause")],
                  None: [run(1, "main"), run(3, "other"), run(4, "another")]},
            jobs={1: [web_job(1)], 2: [web_job(2)], 3: [web_job(3)], 4: [web_job(4)]},
            logs={10: LOG, 20: LOG, 30: LOG, 40: LOG},
        )
        report = census.census(src, test=None, file="vm-route-deadlines.test.ts", days=7, source="logs",
                               max_main_runs=10, max_runs=1, branches=["fix/repause"], now=NOW)
        self.assertEqual(report["source"], "logs")
        self.assertEqual(report["runs_inspected"], 3)  # main, the named branch, one sampled other run
        self.assertEqual(sorted(f["branch"] for f in report["failures"]), ["fix/repause", "main", "other"])
        self.assertTrue(all(f["kind"] == "timeout" for f in report["failures"]))

    def logs_census(self, error):
        run = lambda i: {"id": i, "run_attempt": 1, "status": "completed", "conclusion": "failure",
                         "head_sha": f"s{i}", "head_branch": "main"}

        class Erroring(FakeSource):
            def jobs(self, run, attempt=None):
                if run["id"] == 2:
                    raise RuntimeError(error)
                return super().jobs(run, attempt)

        src = Erroring(runs={"main": [run(1), run(2)]},
                       jobs={1: [{"id": 10, "name": "web / Web tests (2/4)", "run_attempt": 1,
                                  "conclusion": "failure", "html_url": "https://github.com/x/job/10"}]},
                       logs={10: LOG})
        return census.census(src, test=None, file="vm-route-deadlines.test.ts", days=7, source="logs",
                             max_main_runs=10, max_runs=0, now=NOW)

    def test_one_unreadable_run_is_skipped_and_reported(self):
        report = self.logs_census("GET repos/x/actions/runs/2/jobs: HTTP 404 Not Found")
        self.assertEqual(report["runs_unreadable"], 1)
        self.assertEqual(len(report["failures"]), 1)
        self.assertIn("1 run(s) unreadable", census.render(report))

    def test_a_rate_limit_aborts_instead_of_returning_partial_history(self):
        for status in ("403 API rate limit exceeded", "429 Too Many Requests"):
            with self.subTest(status), self.assertRaises(SystemExit) as raised:
                self.logs_census(f"GET repos/x/actions/runs/2/jobs: HTTP {status}")
            self.assertIn("rate limit", str(raised.exception))

    def test_auto_falls_back_to_logs_when_no_reports_exist(self):
        src = FakeSource(runs={"main": []})
        report = census.census(src, test=None, file="a.test.ts", days=7, now=NOW)
        self.assertEqual(report["source"], "logs")
        self.assertEqual(report["failures"], [])

    def test_refuses_to_start_without_rate_limit_headroom(self):
        with self.assertRaises(SystemExit) as raised:
            census.check_budget(FakeSource(remaining=30), 100)
        self.assertIn("30 calls left", str(raised.exception))

    def test_a_truncated_response_is_retried_once_then_reported(self):
        import http.client

        class FlakyGitHub(FakeGitHub):
            def __init__(self, failures):
                self.failures, self.paths = failures, []

            def get(self, path):
                self.paths.append(path)
                if len(self.paths) <= self.failures:
                    raise http.client.IncompleteRead(b"partial", 10)
                return {"jobs": []}

        once = FlakyGitHub(1)
        self.assertEqual(census.Source(once, None).jobs({"id": 1, "status": "completed"}), [])
        self.assertEqual(len(once.paths), 2)
        with self.assertRaises(RuntimeError):
            census.Source(FlakyGitHub(2), None).jobs({"id": 1, "status": "completed"})

    def test_cache_keeps_completed_job_lists_and_skips_running_ones(self):
        class CountingGitHub(FakeGitHub):
            def __init__(self):
                self.paths = []

            def get(self, path):
                self.paths.append(path)
                return {"jobs": [{"id": 1, "name": "web / Web tests (1/4)"}]}

        with tempfile.TemporaryDirectory() as tmp:
            gh = CountingGitHub()
            src = census.Source(gh, Path(tmp))
            src.jobs({"id": 5, "run_attempt": 1, "status": "in_progress"})
            src.jobs({"id": 5, "run_attempt": 1, "status": "in_progress"})
            self.assertEqual(len(gh.paths), 2)
            src.jobs({"id": 6, "run_attempt": 1, "status": "completed"})
            src.jobs({"id": 6, "run_attempt": 1, "status": "completed"})
            self.assertEqual(len(gh.paths), 3)
            # A re-run attempt is a new key.
            src.jobs({"id": 6, "run_attempt": 2, "status": "completed"})
            self.assertEqual(len(gh.paths), 4)


if __name__ == "__main__":
    unittest.main()
