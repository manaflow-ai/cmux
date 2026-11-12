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

import contextlib
import io
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


os.environ["PR_STATUS_SETTLE_SECONDS"] = "0"  # no wait before the status comment's check


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
        # Kept as GitHub would, so the status comment's check after a write reads what it wrote.
        if method == "POST" and path.endswith("/issues/7/comments"):
            self._comments = [*self._comments, {"id": 1000, "body": body["body"], "user": {"login": cf.BOT}}]  # type: ignore[index]
        elif method == "PATCH" and "/issues/comments/" in path:
            cid = int(path.rsplit("/", 1)[1])
            self._comments = [dict(c, body=body["body"]) if c["id"] == cid else c  # type: ignore[index]
                              for c in self._comments]
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
        # The comments are read once before the write, and once after it: the status comment's
        # other lines belong to other jobs, so a write is checked (scripts/ci/pr_status.py).
        self.assertEqual(gh.reads, ["comments 7", "pull 7", "comments 7"])
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
        self.assertEqual(gh.reads, ["comments 7", "pull 7", "comments 7"])  # the last checks the write
        gh = CountingGitHub(comments=[BOT_COMMENT], state="closed")
        writer = cf.Writer(gh, dry_run=False)  # type: ignore[arg-type]
        self.assertEqual(cf.act_requested(gh, writer, run)["line"],  # type: ignore[arg-type]
                         "skipped: not the open pull request's head")
        self.assertEqual(gh.writes, [])


    def main_act(self, gh: "CountingGitHub", run: dict, classify=None) -> tuple[list[str], list[str]]:
        """classify_failures.main(["act"]) on `run` as the workflow_run event, with `gh` as its client.
        Returns (the runs classify_run read, stdout lines)."""
        classified: list[str] = []
        gh.calls = gh.read_calls = 0  # type: ignore[attr-defined]

        def fake_classify(client, event_run):  # noqa: ANN001, ANN202
            classified.append(str(event_run["id"]))
            found = classify(client) if classify else report([cf.CODE])
            for job in found["jobs"]:
                job.setdefault("signature", None)
            return found

        with tempfile.TemporaryDirectory() as temp:
            event = Path(temp) / "event.json"
            event.write_text(json.dumps({"workflow_run": run}))
            out = io.StringIO()
            saved = {name: getattr(cf, name) for name in ("GitHub", "classify_run")}
            env = {"GITHUB_EVENT_PATH": str(event), "GH_TOKEN": "t", "GITHUB_REPOSITORY": REPO}
            old_env = {key: os.environ.get(key) for key in env}
            try:
                cf.GitHub = lambda *args, **kwargs: gh  # type: ignore[assignment,misc]
                cf.classify_run = fake_classify  # type: ignore[assignment]
                os.environ.update(env)
                with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
                    self.assertEqual(cf.main(["act"]), 0)
            finally:
                for name, value in saved.items():
                    setattr(cf, name, value)
                for key, value in old_env.items():
                    if value is None:
                        os.environ.pop(key, None)
                    else:
                        os.environ[key] = value
        return classified, out.getvalue().splitlines()

    def test_a_red_run_on_a_moved_or_closed_head_reads_no_jobs(self) -> None:
        self.assertTrue(cf.moved_past(RUN, (7, {"state": "open", "head": {"sha": "b" * 40}})))
        self.assertTrue(cf.moved_past(RUN, (7, {"state": "closed", "head": {"sha": HEAD}, "merged_at": None})))
        self.assertTrue(cf.moved_past(RUN, (None, {})))
        self.assertFalse(cf.moved_past(RUN, (7, {"state": "open", "head": {"sha": HEAD}})))
        self.assertFalse(cf.moved_past(RUN, (7, {"state": "closed", "head": {"sha": HEAD}, "merged_at": "x"})))
        red = {**RUN, "status": "completed", "conclusion": "failure", "run_attempt": 1}
        gh = CountingGitHub(comments=[{**BOT_COMMENT, "body": cf.MARKER + "\n" + cf.head_marker(HEAD, "failed")}],
                            head="b" * 40)
        classified, _ = self.main_act(gh, red)
        self.assertEqual(classified, [])  # no jobs, logs or annotations read
        self.assertEqual(gh.writes, [("PATCH", f"repos/{REPO}/issues/comments/99")])  # marked pending
        gh = CountingGitHub(state="closed")
        classified, lines = self.main_act(gh, red)
        self.assertEqual((classified, gh.writes), ([], []))
        self.assertTrue(any("no open pull request" in line for line in lines))
        # A red run on the current head is classified as before.
        gh = CountingGitHub()
        self.assertEqual(self.main_act(gh, red)[0], ["42"])

    def test_a_pull_request_that_moves_while_its_logs_are_read_is_not_re_run(self) -> None:
        red = {**RUN, "status": "completed", "conclusion": "failure", "run_attempt": 1}
        gh = CountingGitHub()

        def moves_meanwhile(client) -> dict:  # noqa: ANN001
            client.head = "b" * 40  # a push lands while the jobs and logs are read
            return report([cf.MACHINE])

        classified, _ = self.main_act(gh, red, classify=moves_meanwhile)
        self.assertEqual(classified, ["42"])
        self.assertEqual(gh.reads.count("pull 7"), 2)  # read again before deciding the re-run
        self.assertNotIn(("POST", f"repos/{REPO}/actions/runs/42/rerun-failed-jobs"), gh.writes)


    NEXT_RUN = {**RUN, "id": 42, "conclusion": "success", "pull_requests": [
        {"number": 7, "base": {"ref": "feat-cmux-next", "repo": {"url": f"https://api.github.com/repos/{REPO}"}}}]}

    def test_a_green_run_into_feat_cmux_next_reads_only_the_comments(self) -> None:
        # feat-cmux-next's ci.yml skips `Fast static checks` and so `macos` by design: routing,
        # not "macOS never ran". Before, that skip read the pull request, its comments and its files.
        jobs = [{"name": "changes", "conclusion": "success"}, {"name": "Fast static checks", "conclusion": "skipped"}]
        self.assertEqual(cf.macos_blocked(jobs, "feat-cmux-next"), "")
        self.assertEqual(cf.macos_blocked(jobs, "main"), "`Fast static checks` skipped")
        rep = cf.green_next_report(CountingGitHub(), self.NEXT_RUN)  # type: ignore[arg-type]
        self.assertIsNotNone(rep)
        gh = CountingGitHub(files=["Packages/macOS/CmuxNext/Sources/A.swift"])
        result = cf.act(gh, cf.Writer(gh, dry_run=False), self.NEXT_RUN, rep)  # type: ignore[arg-type]
        self.assertEqual(gh.reads, ["comments 7"])  # no jobs, pull or files read
        self.assertEqual(gh.writes, [])
        self.assertEqual(result["line"], "skipped: nothing reported on this pull request")
        # An earlier report on the pull request is still updated to "passes".
        gh = CountingGitHub(comments=[BOT_COMMENT])
        cf.act(gh, cf.Writer(gh, dry_run=False), self.NEXT_RUN, cf.green_next_report(gh, self.NEXT_RUN))  # type: ignore[arg-type]
        self.assertEqual(gh.writes, [("PATCH", f"repos/{REPO}/issues/comments/99")])

    def test_only_a_green_run_into_feat_cmux_next_skips_the_jobs(self) -> None:
        gh = CountingGitHub()
        self.assertIsNone(cf.green_next_report(gh, {**self.NEXT_RUN, "conclusion": "failure"}))  # type: ignore[arg-type]
        main_run = {**self.NEXT_RUN, "pull_requests": [
            {"number": 7, "base": {"ref": "main", "repo": {"url": f"https://api.github.com/repos/{REPO}"}}}]}
        self.assertIsNone(cf.green_next_report(gh, main_run))  # type: ignore[arg-type]
        fork_pr = {**self.NEXT_RUN, "pull_requests": [
            {"number": 7, "base": {"ref": "feat-cmux-next", "repo": {"url": "https://api.github.com/repos/someone/cmux"}}}]}
        self.assertIsNone(cf.green_next_report(gh, fork_pr))  # type: ignore[arg-type]

    def test_feat_cmux_next_ci_skips_the_static_checks_and_gates_macos_on_them(self) -> None:
        shown = subprocess.run(["git", "-C", str(ROOT), "show", "origin/feat-cmux-next:.github/workflows/ci.yml"],
                               capture_output=True, text=True, check=False)
        if shown.returncode:
            self.skipTest("origin/feat-cmux-next is not fetched")
        jobs = yaml.safe_load(shown.stdout)["jobs"]
        static = next(name for name, job in jobs.items() if job.get("name") == cf.STATIC_CHECKS_JOB)
        self.assertIn("github.event.pull_request.base.ref != 'feat-cmux-next'", jobs[static]["if"])
        self.assertIn(f"needs.{static}.result == 'success'", jobs["macos"]["if"])


class FeatCmuxNextSkips(unittest.TestCase):
    """CI runs of pull requests into feat-cmux-next start no guard analysis: that branch's ci.yml
    skips `fast-guards` for them, so the analysis read the run's jobs to find no verdict."""

    def test_guard_attribution_skips_feat_cmux_next_ci_runs(self) -> None:
        job, _ = workflow_step("ci-guard-attribution.yml", "analyze", "Analyze")
        self.assertIn("!(github.event.workflow_run.event == 'pull_request' && "
                      "github.event.workflow_run.path == '.github/workflows/ci.yml' && "
                      "github.event.workflow_run.pull_requests[0].base.ref == 'feat-cmux-next')", job["if"])
        shown = subprocess.run(["git", "-C", str(ROOT), "show", "origin/feat-cmux-next:.github/workflows/ci.yml"],
                               capture_output=True, text=True, check=False)
        if shown.returncode:
            self.skipTest("origin/feat-cmux-next is not fetched")
        guards = yaml.safe_load(shown.stdout)["jobs"]["fast-guards"]
        self.assertIn("github.event.pull_request.base.ref != 'feat-cmux-next'", guards["if"])


class ReadTokenRouting(unittest.TestCase):
    """guard_attribution.GitHub: reads on the App's token, writes and checks reads on GH_TOKEN."""

    def calls(self, steps, refuse: dict[str, int] | None = None) -> list[tuple[str, str, str]]:
        seen: list[tuple[str, str, str]] = []

        class Response:
            def __init__(self) -> None:
                self.headers: dict = {}

            def read(self) -> bytes:
                return b"{}"

            def __enter__(self):  # noqa: ANN204
                return self

            def __exit__(self, *exc: object) -> None:
                return None

        def urlopen(req, timeout=60):  # noqa: ANN001, ANN202
            token = req.unredirected_hdrs["Authorization"].split()[-1]
            path = req.full_url.split("api.github.com/")[1]
            seen.append((req.get_method(), path, token))
            code = (refuse or {}).get(token)
            if code:
                raise ga.urllib.error.HTTPError(req.full_url, code, "no", {}, io.BytesIO(b"refused"))  # type: ignore[arg-type]
            return Response()

        original = ga.urllib.request.urlopen
        ga.urllib.request.urlopen = urlopen  # type: ignore[assignment]
        try:
            gh = ga.GitHub(REPO, "workflow", read_token="app")
            steps(gh)
        finally:
            ga.urllib.request.urlopen = original  # type: ignore[assignment]
        return seen

    def test_reads_use_the_app_and_writes_the_workflow_token(self) -> None:
        def steps(gh: ga.GitHub) -> None:
            gh.get(f"repos/{REPO}/actions/runs/1/jobs?per_page=100")
            gh.get(f"repos/{REPO}/check-runs/5/annotations?per_page=50")
            gh.request("POST", f"repos/{REPO}/actions/runs/1/rerun-failed-jobs", {})
            gh.request("PATCH", f"repos/{REPO}/issues/comments/9", {"body": "x"})
        self.assertEqual([(m, t) for m, _, t in self.calls(steps)],
                         [("GET", "app"), ("GET", "workflow"), ("POST", "workflow"), ("PATCH", "workflow")])

    def test_a_refused_read_is_made_again_with_the_workflow_token(self) -> None:
        def steps(gh: ga.GitHub) -> None:
            gh.get(f"repos/{REPO}/pulls/7")
            gh.get(f"repos/{REPO}/pulls/8")
        for code, second in ((403, "app"), (401, "workflow")):
            with self.subTest(code=code), contextlib.redirect_stderr(io.StringIO()):
                tokens = [t for _, _, t in self.calls(steps, refuse={"app": code})]
                # 403 (no permission or no budget for this read) retries that read; 401 (an
                # expired token) keeps the workflow token from then on.
                self.assertEqual(tokens[:2], ["app", "workflow"])
                self.assertEqual(tokens[2], second)

    def test_without_a_read_token_everything_uses_the_workflow_token(self) -> None:
        gh = ga.GitHub(REPO, "workflow", read_token="workflow")
        self.assertEqual(gh.read_token, "")


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
        bot = {"login": "github-actions[bot]"}
        gh = GuardGitHub([{"id": 3, "body": ga.PR_MARKER + "\nold", "user": bot}, {"id": 4, "body": "unrelated", "user": bot}])
        rep = ga.analyze_pr(gh, self.RUN, ROOT, "")  # type: ignore[arg-type]
        self.assertEqual(rep["state"], "green")
        self.assertEqual(rep["comments"], [{"id": 3, "body": ga.PR_MARKER + "\nold", "user": bot}])
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
    if os.environ.get("FAKE_GH_TOKEN_LOG"):
        with open(os.environ["FAKE_GH_TOKEN_LOG"], "a") as log:
            log.write(os.environ.get("GH_TOKEN", "") + "\\n")
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

    def test_reads_use_the_read_token_and_the_rerun_the_workflow_token(self) -> None:
        self.assertEqual(self.STEP["env"]["READ_TOKEN"],
                         "${{ steps.cmux-bot-token.outputs.token || steps.glaeda-token.outputs.token }}")
        with tempfile.TemporaryDirectory() as tmp:
            tokens = Path(tmp) / "tokens"
            self.run_step(self.STEP["run"], {**self.ENV, "READ_TOKEN": "app", "FAKE_GH_TOKEN_LOG": str(tokens)},
                          {"runs/42": self.RUN, "runs/42/jobs": self.NO_RUNNER})
            # run, jobs on the App; the re-run on GH_TOKEN (github-actions[bot] routes attempt 3).
            self.assertEqual(tokens.read_text().split(), ["app", "app", "t"])

    def test_a_run_already_rerun_is_left_alone(self) -> None:
        calls, _, out = self.run_step(self.STEP["run"], self.ENV, {"runs/42": {**self.RUN, "run_attempt": 2}})
        self.assertEqual(len(calls), 1)
        self.assertIn("another rescue owns it", out)


class CmuxBotTokenWorkflowShape(unittest.TestCase):
    """High-volume bot jobs use the dedicated installation budget when configured."""

    JOBS = {
        "ci-queue-janitor.yml": ("sweep",),
        "ci-failure-attribution.yml": ("attribute",),
        "ci-compile-attribution.yml": ("analyze", "report", "fix"),
        "ci-guard-attribution.yml": ("analyze", "report"),
        "ci-hosted-queue-rescue.yml": ("rescue",),
        "ci-owned-pool-rescue.yml": ("rescue",),
        # The publish job runs in the artifacts environment, which is limited
        # to R2 credentials by the production-secret guard. Its explicitly
        # scoped GITHUB_TOKEN preserves that trust boundary. The capture runs on
        # the reused GUI mini, so the cmux-bot token is minted only in the two
        # short jobs around it, on a literal ephemeral label.
        "dogfood-artifact-publish.yml": ("capture-inputs", "capture-report"),
    }
    PERMISSIONS = {
        "permission-actions": "write",
        "permission-checks": "read",
        "permission-contents": "read",
        "permission-issues": "write",
        "permission-pull-requests": "write",
    }

    def test_bot_jobs_mint_and_use_the_scoped_app_token(self) -> None:
        for filename, job_names in self.JOBS.items():
            document = yaml.safe_load((ROOT / ".github/workflows" / filename).read_text())
            for job_name in job_names:
                with self.subTest(workflow=filename, job=job_name):
                    job = document["jobs"][job_name]
                    steps = job["steps"]
                    mint = next(step for step in steps if step.get("id") == "cmux-bot-token")
                    self.assertEqual(mint["uses"],
                                     "actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1")
                    self.assertIn("vars.CMUX_BOT_APP_ID != ''", mint["if"])
                    self.assertTrue(mint["continue-on-error"])
                    self.assertEqual(mint["with"]["app-id"], "${{ vars.CMUX_BOT_APP_ID }}")
                    self.assertEqual(mint["with"]["private-key"], "${{ secrets.CMUX_BOT_APP_KEY }}")
                    self.assertEqual({key: mint["with"][key] for key in self.PERMISSIONS}, self.PERMISSIONS)

                    # Every shell step that can call gh receives the App token,
                    # while the expression keeps forks and rollouts working.
                    token_envs = [(step.get("id") or step.get("name"), step.get("env", {}).get("GH_TOKEN"))
                                  for step in steps]
                    token_envs = [(step_id, value) for step_id, value in token_envs if value is not None]
                    self.assertTrue(token_envs)
                    for step_id, value in token_envs:
                        if str(step_id).startswith("Log the glaeda-route App budget "):
                            # The budget probes read that App installation's own rate_limit (free).
                            self.assertEqual(value, "${{ steps.glaeda-token.outputs.token }}")
                        elif filename == "ci-queue-janitor.yml" and step_id == "fresh":
                            # Ahead of the cmux-bot mint, so only the glaeda-route App's token.
                            self.assertEqual(value, "${{ steps.glaeda-token.outputs.token || github.token }}")
                        else:
                            self.assertIn("steps.cmux-bot-token.outputs.token", value)

    def test_the_gui_capture_job_holds_no_secret_and_no_app_token(self) -> None:
        # MACOS_RUNNER_DISPLAY (set by the overflow switch too) puts the capture on a reused mini:
        # it may read this run's artifacts and upload one, nothing more.
        document = yaml.safe_load((ROOT / ".github/workflows/dogfood-artifact-publish.yml").read_text())
        capture = document["jobs"]["capture"]
        self.assertIn("vars.MACOS_RUNNER_DISPLAY", capture["runs-on"])
        text = json.dumps(capture)
        for held in ("secrets.", "create-github-app-token", "cmux-bot-token", "GH_TOKEN", "github.token"):
            self.assertNotIn(held, text)
        self.assertEqual(capture["permissions"], {"actions": "read", "contents": "read"})
        self.assertEqual(capture["needs"], ["publish", "capture-inputs"])
        self.assertEqual(document["jobs"]["capture-report"]["needs"], ["publish", "capture"])
        uses = [step.get("uses", "").split("@")[0] for step in capture["steps"]]
        self.assertEqual(uses.count("actions/download-artifact"), 2)
        for name in ("capture-inputs", "capture-report"):
            self.assertNotIn("${{ vars.", document["jobs"][name]["runs-on"].split("||", 1)[1], name)

    def test_artifact_publisher_keeps_the_r2_environment_secret_boundary(self) -> None:
        document = yaml.safe_load((ROOT / ".github/workflows/dogfood-artifact-publish.yml").read_text())
        publish = document["jobs"]["publish"]
        self.assertEqual(publish["environment"], "artifacts")
        self.assertFalse(any(step.get("id") == "cmux-bot-token" for step in publish["steps"]))
        for step in publish["steps"]:
            token = step.get("env", {}).get("GH_TOKEN")
            if token is not None:
                self.assertEqual(token, "${{ github.token }}")


# ---------------------------------------------------------------- risk tier


# Records each call with the token it used. FAIL_READ_TOKEN refuses every call made with that
# token; MISSING_LABELS fails --add-label until a label was created.
FAKE_RISK_GH = textwrap.dedent("""\
    #!/usr/bin/env python3
    import json, os, sys
    log = os.environ["FAKE_GH_LOG"]
    calls = [json.loads(line) for line in open(log)] if os.path.getsize(log) else []
    with open(log, "a") as handle:
        handle.write(json.dumps({"token": os.environ.get("GH_TOKEN"), "args": sys.argv[1:]}) + "\\n")
    if os.environ["GH_TOKEN"] == os.environ.get("FAIL_READ_TOKEN"):
        sys.exit(1)
    if sys.argv[1:3] == ["pr", "view"]:
        print(os.environ.get("CURRENT_LABELS", ""))
    elif ("--add-label" in sys.argv and os.environ.get("MISSING_LABELS")
          and not any(c["args"][:2] == ["label", "create"] for c in calls)):
        sys.exit(1)
    """)

# Stands in for risk_tier.py: records the token it graded with and writes a verdict.
FAKE_RISK_TIER = textwrap.dedent("""\
    import os, sys
    if os.environ["GH_TOKEN"] == os.environ.get("FAIL_READ_TOKEN"):
        open(sys.argv[sys.argv.index("--github-output") + 1], "a").write("tier=partial\\n")
        sys.exit(1)
    open(os.environ["FAKE_GH_LOG"], "a").write('{"token": "%s", "args": ["grade"]}\\n' % os.environ["GH_TOKEN"])
    ready = "false" if os.environ["GH_TOKEN"] == os.environ.get("HELD_ON") else "true"
    open(sys.argv[sys.argv.index("--github-output") + 1], "a").write("tier=normal\\nlabel=risk:normal\\nready=%s\\n" % ready)
    open(sys.argv[sys.argv.index("--summary") + 1], "a").write("## Risk tier: normal\\n")
    """)


class RiskTierCalls(unittest.TestCase):
    """risk evidence reads on the glaeda-route App's budget and creates no label that exists (2026-10-26)."""

    def run_step(self, name: str, **env: str) -> tuple[list[dict], str]:
        _, step = workflow_step("risk-tier.yml", "evidence", name)
        with tempfile.TemporaryDirectory() as tmp:
            bin_dir = Path(tmp) / "bin"
            (Path(tmp) / "scripts/ci").mkdir(parents=True)
            (Path(tmp) / "scripts/ci/risk_tier.py").write_text(FAKE_RISK_TIER)
            bin_dir.mkdir()
            (bin_dir / "gh").write_text(FAKE_RISK_GH)
            (bin_dir / "gh").chmod(0o755)
            log, output, summary = Path(tmp) / "gh.log", Path(tmp) / "output", Path(tmp) / "summary"
            for path in (log, output, summary):
                path.touch()
            result = subprocess.run(
                ["bash", "-e", "-c", step["run"]], capture_output=True, text=True, check=False, cwd=tmp,
                env={**os.environ, "PATH": f"{bin_dir}:{os.environ['PATH']}", "FAKE_GH_LOG": str(log),
                     "GITHUB_OUTPUT": str(output), "GITHUB_STEP_SUMMARY": str(summary), "RUNNER_TEMP": tmp,
                     "REPO": REPO, "NUMBER": "7", "LABEL": "risk:normal", "GH_TOKEN": "workflow", **env})
            self.assertEqual(result.returncode, 0, result.stderr)
            return [json.loads(line) for line in log.read_text().splitlines()], output.read_text()

    def test_the_step_tokens_are_the_app_for_reads_and_the_workflow_token_for_writes(self) -> None:
        for name in ("Grade the pull request", "Set the risk label"):
            with self.subTest(step=name):
                _, step = workflow_step("risk-tier.yml", "evidence", name)
                self.assertEqual(step["env"]["READ_TOKEN"], "${{ steps.glaeda-token.outputs.token }}")
                self.assertEqual(step["env"]["GH_TOKEN"], "${{ github.token }}")
        _, mint = workflow_step("risk-tier.yml", "evidence", "Mint the glaeda-route token")
        self.assertTrue(mint["continue-on-error"])
        self.assertEqual({k: v for k, v in mint["with"].items() if k.startswith("permission-")},
                         {"permission-contents": "read", "permission-issues": "read", "permission-pull-requests": "read"})

    def test_grading_reads_on_the_app_token(self) -> None:
        calls, output = self.run_step("Grade the pull request", READ_TOKEN="app")
        self.assertEqual(calls, [{"token": "app", "args": ["grade"]}])
        self.assertEqual(output, "tier=normal\nlabel=risk:normal\nready=true\n")

    def test_a_refused_app_read_grades_again_on_the_workflow_token_with_one_verdict(self) -> None:
        calls, output = self.run_step("Grade the pull request", READ_TOKEN="app", FAIL_READ_TOKEN="app")
        self.assertEqual(calls, [{"token": "workflow", "args": ["grade"]}])
        self.assertEqual(output, "tier=normal\nlabel=risk:normal\nready=true\n")

    def test_a_held_app_verdict_is_graded_again_on_the_workflow_token(self) -> None:
        calls, output = self.run_step("Grade the pull request", READ_TOKEN="app", HELD_ON="app")
        self.assertEqual(calls, [{"token": "app", "args": ["grade"]}, {"token": "workflow", "args": ["grade"]}])
        self.assertEqual(output, "tier=normal\nlabel=risk:normal\nready=true\n")

    def test_the_risk_labels_are_in_the_label_manifest(self) -> None:
        manifest = json.loads((ROOT / ".github/labels.json").read_text())
        names = {label["name"] for label in manifest["labels"]}
        self.assertTrue({"risk:low", "risk:normal", "risk:high", "risk:human-ok"} <= names)

    def test_without_an_app_token_grading_uses_the_workflow_token(self) -> None:
        calls, _ = self.run_step("Grade the pull request", READ_TOKEN="")
        self.assertEqual(calls, [{"token": "workflow", "args": ["grade"]}])

    def test_an_unchanged_label_costs_one_app_read_and_nothing_else(self) -> None:
        calls, _ = self.run_step("Set the risk label", READ_TOKEN="app", CURRENT_LABELS="risk:normal")
        self.assertEqual([(c["token"], c["args"][:2]) for c in calls], [("app", ["pr", "view"])])

    def test_a_new_tier_swaps_labels_on_the_workflow_token_without_creating_any(self) -> None:
        calls, _ = self.run_step("Set the risk label", READ_TOKEN="app", CURRENT_LABELS="risk:low")
        writes = [c for c in calls if c["args"][:2] != ["pr", "view"]]
        self.assertEqual([c["token"] for c in writes], ["workflow", "workflow"])
        self.assertIn("--remove-label", writes[0]["args"])
        self.assertIn("--add-label", writes[1]["args"])

    def test_a_missing_label_is_created_then_added(self) -> None:
        calls, _ = self.run_step("Set the risk label", READ_TOKEN="app", MISSING_LABELS="1")
        self.assertEqual(sum(c["args"][:2] == ["label", "create"] for c in calls), 4)
        self.assertEqual(sum("--add-label" in c["args"] for c in calls), 2)

    def test_a_refused_app_read_reads_the_labels_on_the_workflow_token(self) -> None:
        calls, _ = self.run_step("Set the risk label", READ_TOKEN="app", FAIL_READ_TOKEN="app",
                                 CURRENT_LABELS="risk:normal")
        self.assertEqual([(c["token"], c["args"][:2]) for c in calls],
                         [("app", ["pr", "view"]), ("workflow", ["pr", "view"])])


if __name__ == "__main__":
    unittest.main()
