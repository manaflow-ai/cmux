#!/usr/bin/env python3
"""The per-run workflow_run handlers spend as few GitHub API calls as they can (no network).

Every workflow in manaflow-ai/cmux shares one GITHUB_TOKEN budget. On
2026-10-06 it ran out ("API rate limit exceeded for installation") and the
required CLA and migration checks failed on every pull request. The handlers
that run on every CI, fast guard and CLA run now read what the event already
carries, read in the order that lets most runs stop after the first call, and
start no job when there is nothing to do. These cases pin the calls each makes.

The workflow steps run here as written, with a fake `gh` (and `date`, for
macOS) on PATH that records each call.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import classify_failures as cf  # noqa: E402
import guard_attribution as ga  # noqa: E402

REPO = "manaflow-ai/cmux"
HEAD = "a" * 40


# ---------------------------------------------------------------- CI failure attribution


class CountingGitHub:
    """classify_failures' GitHub with every read recorded."""

    repo = REPO

    def __init__(self, *, comments: list[dict] | None = None, state: str = "open", head: str = HEAD,
                 latest: dict | None = None, files: list[str] | None = None):
        self._comments, self.state, self.head = comments or [], state, head
        self.files = files or []
        self.latest = latest or {"run_attempt": 1, "status": "completed"}
        self.reads: list[str] = []
        self.writes: list[tuple[str, str]] = []

    def pull(self, number: int) -> dict:
        self.reads.append(f"pull {number}")
        return {"number": number, "state": self.state, "head": {"sha": self.head}, "merged_at": None}

    def comments(self, number: int) -> list[dict]:
        self.reads.append(f"comments {number}")
        return self._comments

    def run(self, run_id: int) -> dict:
        self.reads.append(f"run {run_id}")
        return self.latest

    def get(self, path: str) -> object:
        self.reads.append(path)
        if "/files?" in path:
            return [{"filename": f} for f in self.files] if "page=1" in path else []
        if "labels=main-full-suite-failure" in path:
            return []
        if "pulls?state=" in path:
            return []
        raise AssertionError(f"unexpected read {path}")

    def request(self, method: str, path: str, body: object = None) -> dict:
        self.writes.append((method, path))
        return {}


RUN = {"id": 42, "head_sha": HEAD, "head_branch": "topic", "head_repository": {"full_name": REPO},
       "pull_requests": [{"number": 7, "base": {"repo": {"url": f"https://api.github.com/repos/{REPO}"}}}]}
BOT_COMMENT = {"id": 99, "body": cf.MARKER + "\nred", "user": {"login": cf.BOT}}


def report(verdicts: list[str], conclusion: str = "failure", macos_blocked: str = "") -> dict:
    jobs = [{"name": f"job {i}", "verdict": v, "why": "because", "evidence": "", "url": None, "runner": "r"}
            for i, v in enumerate(verdicts)]
    return {"run_id": 42, "attempt": 1, "head_sha": HEAD, "run_url": "https://run", "conclusion": conclusion,
            "jobs": jobs, "macos_ran": not macos_blocked, "macos_blocked": macos_blocked}


def act(gh: CountingGitHub, rep: dict) -> dict:
    return cf.act(gh, cf.Writer(gh, dry_run=False), RUN, rep)  # type: ignore[arg-type]


class FailureAttributionCalls(unittest.TestCase):
    def setUp(self) -> None:
        summary = tempfile.NamedTemporaryFile(delete=False)
        summary.close()
        self.summary = Path(summary.name)
        self.addCleanup(self.summary.unlink)
        os.environ["GITHUB_STEP_SUMMARY"] = str(self.summary)
        self.addCleanup(os.environ.pop, "GITHUB_STEP_SUMMARY", None)

    def test_a_green_run_where_nothing_was_reported_reads_only_the_comments(self) -> None:
        gh = CountingGitHub()
        result = act(gh, report([], conclusion="success"))
        self.assertEqual(gh.reads, ["comments 7"])  # was: pull 7, comments 7
        self.assertEqual(gh.writes, [])
        self.assertFalse(result["rerun"])
        # The job summary still says it passes.
        self.assertIn("CI passes on", self.summary.read_text())

    def test_a_green_run_with_a_comment_still_updates_it(self) -> None:
        gh = CountingGitHub(comments=[BOT_COMMENT])
        act(gh, report([], conclusion="success"))
        self.assertEqual(gh.reads, ["comments 7", "pull 7"])  # the comments are read once
        self.assertEqual(gh.writes, [("PATCH", f"repos/{REPO}/issues/comments/99")])

    def test_a_green_run_with_a_comment_on_a_moved_head_marks_it_pending(self) -> None:
        gh = CountingGitHub(comments=[{**BOT_COMMENT, "body": cf.MARKER + "\n" + cf.head_marker(HEAD, "failed")}],
                            head="b" * 40)
        self.assertTrue(act(gh, report([], conclusion="success"))["line"].startswith("marked pending"))
        self.assertEqual(gh.writes, [("PATCH", f"repos/{REPO}/issues/comments/99")])

    def test_a_green_run_whose_macos_jobs_never_ran_still_comments(self) -> None:
        gh = CountingGitHub(files=["Sources/App.swift"])
        act(gh, report([], conclusion="success", macos_blocked="`changes` failure"))
        self.assertEqual(gh.reads[:2], ["pull 7", "comments 7"])
        self.assertEqual(gh.writes, [("POST", f"repos/{REPO}/issues/7/comments")])

    def test_a_cancelled_run_with_no_failed_job_and_no_comment_reads_only_the_comments(self) -> None:
        gh = CountingGitHub()
        act(gh, report([], conclusion="cancelled"))
        self.assertEqual(gh.reads, ["comments 7"])
        self.assertEqual(gh.writes, [])

    def test_a_code_failure_never_reads_the_run_again(self) -> None:
        gh = CountingGitHub()
        result = act(gh, report([cf.CODE]))
        self.assertNotIn("run 42", gh.reads)  # was read on every red run
        self.assertIn("is not a machine failure", result["line"])
        self.assertEqual(gh.writes, [("POST", f"repos/{REPO}/issues/7/comments")])

    def test_a_machine_failure_reads_the_run_before_re_running(self) -> None:
        gh = CountingGitHub()
        self.assertTrue(act(gh, report([cf.MACHINE]))["rerun"])
        self.assertIn("run 42", gh.reads)
        gh = CountingGitHub(latest={"run_attempt": 2, "status": "completed"})
        self.assertFalse(act(gh, report([cf.MACHINE]))["rerun"])

    def test_a_started_run_without_a_comment_reads_only_the_comments(self) -> None:
        gh = CountingGitHub()
        writer = cf.Writer(gh, dry_run=False)  # type: ignore[arg-type]
        run = {**RUN, "status": "requested", "html_url": "https://run/2"}
        self.assertEqual(cf.act_requested(gh, writer, run)["line"], "nothing to mark")  # type: ignore[arg-type]
        self.assertEqual(gh.reads, ["comments 7"])  # was: pull 7, comments 7
        gh = CountingGitHub(comments=[{**BOT_COMMENT, "body": cf.MARKER + "\n" + cf.head_marker("c" * 40, "failed")}])
        writer = cf.Writer(gh, dry_run=False)  # type: ignore[arg-type]
        self.assertTrue(cf.act_requested(gh, writer, run)["line"].startswith("marked pending"))  # type: ignore[arg-type]
        self.assertEqual(gh.reads, ["comments 7", "pull 7"])
        gh = CountingGitHub(comments=[BOT_COMMENT], state="closed")
        writer = cf.Writer(gh, dry_run=False)  # type: ignore[arg-type]
        self.assertEqual(cf.act_requested(gh, writer, run)["line"],  # type: ignore[arg-type]
                         "skipped: not the open pull request's head")
        self.assertEqual(gh.writes, [])


# ---------------------------------------------------------------- CI guard attribution


class GuardGitHub:
    repo = REPO

    def __init__(self, comments: list[dict]):
        self._comments, self.reads = comments, 0

    def comments(self, number: int) -> list[dict]:
        self.reads += 1
        return self._comments


class GuardAttributionCalls(unittest.TestCase):
    RUN = {"head_sha": HEAD, "conclusion": "success", "html_url": "u", "pull_requests": [
        {"number": 7, "base": {"repo": {"url": f"https://api.github.com/repos/{REPO}"}}}]}

    def test_a_green_pr_with_a_guard_comment_reads_the_comments_once(self) -> None:
        gh = GuardGitHub([{"id": 3, "body": ga.PR_MARKER + "\nold"}, {"id": 4, "body": "unrelated"}])
        rep = ga.analyze_pr(gh, self.RUN, ROOT, "")  # type: ignore[arg-type]
        self.assertEqual(rep["state"], "green")
        self.assertEqual(rep["comments"], [{"id": 3, "body": ga.PR_MARKER + "\nold"}])
        rep = json.loads(json.dumps(rep))  # the artifact between analyze and report
        writer = ga.Writer(None, True)
        ga.report_pr(writer, gh, REPO, rep)  # type: ignore[arg-type]
        self.assertEqual(gh.reads, 1)  # was 2: analyze, then report again
        self.assertEqual(writer.log[0].splitlines()[0], f"--- would PATCH repos/{REPO}/issues/comments/3")

    def test_a_green_pr_never_reported_on_stays_a_noop(self) -> None:
        gh = GuardGitHub([{"id": 4, "body": "unrelated"}])
        rep = ga.analyze_pr(gh, self.RUN, ROOT, "")  # type: ignore[arg-type]
        self.assertEqual(rep["state"], "noop")
        self.assertNotIn("comments", rep)

    def test_a_red_report_still_reads_the_comments(self) -> None:
        gh = GuardGitHub([])
        ga.report_pr(ga.Writer(None, True), gh, REPO,  # type: ignore[arg-type]
                     {"branch": "pr", "state": "red", "pr": 7, "sha": "abc", "run_url": "u", "steps": []})
        self.assertEqual(gh.reads, 1)


# ---------------------------------------------------------------- workflow steps under a fake gh


FAKE_GH = textwrap.dedent("""\
    #!/usr/bin/env python3
    import json, os, sys
    with open(os.environ["FAKE_GH_LOG"], "a") as log:
        log.write(json.dumps(sys.argv[1:]) + "\\n")
    args = [a for a in sys.argv[1:] if a.startswith("repos/")]
    responses = json.loads(os.environ.get("FAKE_GH_RESPONSES", "{}"))
    path = args[0] if args else ""
    for key, value in responses.items():
        if path.endswith(key) or path.split("?")[0].endswith(key):
            sys.stdout.write(json.dumps(value))
            sys.exit(0)
    sys.stdout.write("{}")
    """)

# GNU date's `-u -d <iso> +%s`, which the Linux runners have and macOS lacks.
FAKE_DATE = textwrap.dedent("""\
    #!/usr/bin/env python3
    import sys
    from datetime import datetime
    when = sys.argv[sys.argv.index("-d") + 1]
    print(int(datetime.fromisoformat(when.replace("Z", "+00:00")).timestamp()))
    """)


def workflow_step(workflow: str, job: str, step_name: str) -> tuple[dict, dict]:
    data = yaml.safe_load((ROOT / ".github/workflows" / workflow).read_text())
    job_data = data["jobs"][job]
    return job_data, next(s for s in job_data["steps"] if s.get("name") == step_name)


class StepHarness(unittest.TestCase):
    def run_step(self, script: str, env: dict[str, str], responses: dict) -> tuple[list[list[str]], str, str]:
        with tempfile.TemporaryDirectory() as tmp:
            bin_dir = Path(tmp) / "bin"
            bin_dir.mkdir()
            for name, text in (("gh", FAKE_GH), ("date", FAKE_DATE)):
                (bin_dir / name).write_text(text)
                (bin_dir / name).chmod(0o755)
            log, output = Path(tmp) / "gh.log", Path(tmp) / "output"
            log.touch()
            output.touch()
            result = subprocess.run(
                ["bash", "-c", script], capture_output=True, text=True, check=False,
                env={**os.environ, **env, "PATH": f"{bin_dir}:{os.environ['PATH']}", "FAKE_GH_LOG": str(log),
                     "FAKE_GH_RESPONSES": json.dumps(responses), "GITHUB_OUTPUT": str(output),
                     "GH_REPO": REPO, "GH_TOKEN": "t"})
            self.assertEqual(result.returncode, 0, result.stderr)
            calls = [json.loads(line) for line in log.read_text().splitlines()]
            return calls, output.read_text(), result.stdout


class DogfoodPublishCalls(StepHarness):
    JOB, STEP = workflow_step("dogfood-artifact-publish.yml", "publish", "Find the trusted org-member dogfood artifact")
    ENV = {"RUN_ID": "42", "PR_NUMBER": "7", "HEAD_SHA": HEAD, "WORKFLOW_NAME": "CI",
           "BUILD_TIME": "2026-10-06T21:00:00Z"}

    def pull(self, labels=("dev-build",)) -> dict:
        return {"state": "open", "author_association": "MEMBER", "labels": [{"name": n} for n in labels],
                "head": {"sha": HEAD, "repo": {"full_name": REPO}}, "base": {"ref": "main"}}

    def responses(self, pull: dict, artifact: bool = True) -> dict:
        return {
            "pulls/7": pull,
            "runs/42/artifacts": {"artifacts": [{"name": f"dogfood-app-7-{HEAD}", "expired": False}] if artifact else []},
            "runs/42/jobs": {"jobs": [{"name": "Dogfood build #7", "conclusion": "success"}]},
        }

    def paths(self, calls: list[list[str]]) -> list[str]:
        return [next(a for a in call if a.startswith("repos/")) for call in calls]

    def test_a_run_with_no_pull_request_never_starts(self) -> None:
        self.assertIn("toJSON(github.event.workflow_run.pull_requests) != '[]'", self.JOB["if"])
        calls, output, _ = self.run_step(self.STEP["run"], {**self.ENV, "PR_NUMBER": ""}, {})
        self.assertEqual(calls, [])
        self.assertEqual(output, "publish=false\n")

    def test_the_pull_request_and_times_come_from_the_event(self) -> None:
        env = self.STEP["env"]
        self.assertEqual(env["PR_NUMBER"], "${{ github.event.workflow_run.pull_requests[0].number }}")
        self.assertIn("github.event.workflow_run.updated_at", env["BUILD_TIME"])
        self.assertNotIn('actions/runs/$RUN_ID"', self.STEP["run"])

    def test_a_pull_request_without_dev_build_costs_one_read(self) -> None:
        calls, output, _ = self.run_step(self.STEP["run"], self.ENV, self.responses(self.pull(labels=())))
        self.assertEqual(self.paths(calls), [f"repos/{REPO}/pulls/7"])  # was 5 reads
        self.assertEqual(output, "publish=false\n")

    def test_a_missing_artifact_stops_before_the_jobs(self) -> None:
        calls, output, _ = self.run_step(self.STEP["run"], self.ENV, self.responses(self.pull(), artifact=False))
        self.assertEqual(self.paths(calls), [f"repos/{REPO}/pulls/7", f"repos/{REPO}/actions/runs/42/artifacts?per_page=100"])
        self.assertEqual(output, "publish=false\n")

    def test_a_trusted_artifact_publishes_after_three_reads(self) -> None:
        calls, output, _ = self.run_step(self.STEP["run"], self.ENV, self.responses(self.pull()))
        self.assertEqual(self.paths(calls), [f"repos/{REPO}/pulls/7",
                                             f"repos/{REPO}/actions/runs/42/artifacts?per_page=100",
                                             f"repos/{REPO}/actions/runs/42/jobs?per_page=100"])
        self.assertEqual(output, f"publish=true\npr=7\nsha={HEAD}\nworkflow=CI\nbuild_time=2026-10-06T21:00:00Z\n")

    def test_every_trust_condition_still_holds(self) -> None:
        for change in ({"state": "closed"}, {"author_association": "CONTRIBUTOR"},
                       {"head": {"sha": "b" * 40, "repo": {"full_name": REPO}}},
                       {"head": {"sha": HEAD, "repo": {"full_name": "someone/cmux"}}},
                       {"base": {"ref": "feat-cmux-next"}}):
            calls, output, _ = self.run_step(self.STEP["run"], self.ENV, self.responses({**self.pull(), **change}))
            self.assertEqual(output, "publish=false\n", change)
        responses = self.responses(self.pull())
        responses["runs/42/jobs"] = {"jobs": [{"name": "Dogfood build #7", "conclusion": "failure"}]}
        self.assertEqual(self.run_step(self.STEP["run"], self.ENV, responses)[1], "publish=false\n")

    def test_comment_lookups_read_a_hundred_at_a_time(self) -> None:
        text = (ROOT / ".github/workflows/dogfood-artifact-publish.yml").read_text()
        self.assertNotIn('issues/$PR/comments" --paginate', text)
        self.assertEqual(text.count('issues/$PR/comments?per_page=100" --paginate'), 2)


class HostedQueueRescueCalls(StepHarness):
    JOB, STEP = workflow_step("ci-hosted-queue-rescue.yml", "rescue", "Rerun only a no-runner hosted queue timeout")
    ENV = {"RUN_ID": "42", "EVENT_ATTEMPT": "1", "MIN_QUEUE_AGE_SECONDS": "840",
           "EVENT_CREATED_AT": "2026-10-06T21:00:00Z", "EVENT_UPDATED_AT": "2026-10-06T21:15:00Z"}
    RUN = {"run_attempt": 1, "created_at": "2026-10-06T21:00:00Z", "updated_at": "2026-10-06T21:15:00Z"}
    NO_RUNNER = {"jobs": [{"conclusion": "cancelled", "runner_id": 0, "runner_name": "", "steps": []}]}

    def test_the_times_come_from_the_event(self) -> None:
        env = self.STEP["env"]
        self.assertEqual(env["EVENT_CREATED_AT"], "${{ github.event.workflow_run.created_at }}")
        self.assertEqual(env["EVENT_UPDATED_AT"], "${{ github.event.workflow_run.updated_at }}")

    def test_a_run_that_ended_in_seconds_costs_nothing(self) -> None:
        calls, _, out = self.run_step(self.STEP["run"], {**self.ENV, "EVENT_UPDATED_AT": "2026-10-06T21:00:20Z"}, {})
        self.assertEqual(calls, [])  # was 1: the run, read again
        self.assertIn("run ended before the hosted queue timeout (20s)", out)

    def test_a_third_attempt_costs_nothing(self) -> None:
        calls, _, out = self.run_step(self.STEP["run"], {**self.ENV, "EVENT_ATTEMPT": "3"}, {})
        self.assertEqual(calls, [])
        self.assertIn("retry limit reached", out)

    def test_a_no_runner_timeout_is_still_checked_live_and_rerun(self) -> None:
        calls, _, out = self.run_step(self.STEP["run"], self.ENV,
                                      {"runs/42": self.RUN, "runs/42/jobs": self.NO_RUNNER})
        self.assertEqual([c[-1] if c[0] != "api" or c[1] != "-X" else " ".join(c[1:4]) for c in calls], [
            f"repos/{REPO}/actions/runs/42",
            f"repos/{REPO}/actions/runs/42/jobs?per_page=100",
            f"-X POST repos/{REPO}/actions/runs/42/rerun"])
        self.assertIn("rerunning hosted queue timeout 42", out)

    def test_a_run_already_rerun_is_left_alone(self) -> None:
        calls, _, out = self.run_step(self.STEP["run"], self.ENV, {"runs/42": {**self.RUN, "run_attempt": 2}})
        self.assertEqual(len(calls), 1)
        self.assertIn("another rescue owns it", out)


if __name__ == "__main__":
    unittest.main()
