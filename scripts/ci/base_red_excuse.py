#!/usr/bin/env python3
"""Excuse a red check that fails the same way on the base branch.

Run via scripts/gh-merge-green before it refuses a red cmux-next run or a red
required check. A failed job on the PR head is excused only when the same job
of the same workflow, on the latest completed run of the base branch that has
a verdict, also failed, and the head's failed steps and failing test names are
all among the base's. Error lines are compared only when no test failed (a
compile error, say), and warnings never are: they vary run to run (SwiftPM's
cache warnings refused #18147 on 2026-10-07). Names are compared, not counts:
the base may fail more. A runner refusal (no steps, a failed setup step, or the glaeda
hook's refusal), a cancelled or timed-out job, and a failure with no test or
error line to compare are never excused. A job whose runner was lost (test_reds.lost_runner: GitHub's "lost
communication with the server" annotation, a step left unfinished, no log stored) is refused as infra, not a
verdict: never the PR's own red, it needs a re-run like a cancelled job. One base red then no longer freezes
every pull request into that base (2026-10-07: four base reds, and the PRs
fixing them deadlocked on each other's reds).

A job that runs tests is judged per test by scripts/ci/test_reds.py, the one
classifier for "red on the base, so not ours" (2026-10-28: cmux#26346 landed
with its own test helper crash because the job was red on the base too). A
failing test the base's run does not fail is the head's; a crash (signal,
abort, EXC_*, Fatal error) is the head's whatever the base shows; and a run
whose per-test results are cut short (no summary, ended early, stuck) is the
head's, since nothing in it can be compared.

A failing test is the base's when it failed on any of the newest BASE_WINDOW base verdicts for its job, not only
the newest (2026-11-01). The newest verdict still decides whether the job is red on the base at all: when it is
not a failure, nothing older is read (fixed_on_base, below). When it is, a head failing test, failed step or error
line that the newest red run lacks is looked for in the older verdicts, newest first, at most BASE_WINDOW verdicts
within BASE_WINDOW_HOURS of the newest, and only back to the first green one: a green base run means every
test passed there, so an older red may predate a fix and never counts. A crash, a cut-short run, the
Chromium check, a process signal and the panic ratchet are judged against the newest alone, as before. Why: the
feat-cmux-next tip Swift suite fails 59 to 106 tests on every run and the set churns:
modelModeAndOptionPicksGoToThisChat() failed on run 41282022128, passed on 41298073172 and failed again on
41303556638, and 56 of the 115 tests that failed on the last six runs failed on only one of them. So a pull
request's test that is flaky on the base read as its own red whenever the newest run happened to pass it, and
reviewed PRs sat. The audit line names the run each such test failed on.

A compile check that gave no verdict (the build fleet's "no result", "No build-fleet verdict") is never a
base red, even with the base's identical line: nothing compiled the head. It is set aside only when the
same head has a real compile pass (a green Mac Release compile or a cmux-next/compile success). Error
lines are compared with commit shas masked, so a real red that names each run's own commit still matches.

No failure is exit 0: asked about no red run or check (or about a green ws-check), it prints why and exits 0. A
red run or check it was named that shows no failed job is still refused (2026-11-05: merge_hold asks it about
every merge, and a green head read as exit 1).

Every run is bounded: past DEADLINE_SECONDS of wall clock (BASE_RED_EXCUSE_DEADLINE_SECONDS) it stops and refuses as
infra, not a verdict. A --sha that is one character forty times (a test's "a" * 40, an all-zero sha) is refused at
once, before any read, unless BASE_RED_EXCUSE_FIXTURE_SHA=1 says a test fixture answers for it. 2026-11-05: a
gh-merge-green test run's classifier, --sha aaaa... against a fake gh whose list never ended, outlived its test and ran
for three days on gcp-agent-lane-2, holding 27.6 GB.
"""
from __future__ import annotations

# This check is a deterministic version comparison. Blacksmith's Actions log
# exposes only the generic exit annotation, so there is no useful output line
# for the normal signature matcher to compare. Its failed step is the stable
# failure identity; compare that step on the base just like a test name.
CHROMIUM_CURRENCY_JOB = "Shipped Chromium is at most one stable milestone behind"
CHROMIUM_CURRENCY_STEP = "Pinned Chromium against Chrome stable"

import argparse
import importlib.util
import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
import zipfile
from datetime import datetime, timedelta
from pathlib import Path

_spec = importlib.util.spec_from_file_location("main_fix_evidence", Path(__file__).with_name("main_fix_evidence.py"))
_evidence = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_evidence)
Refused, job_for, latest_checks = _evidence.Refused, _evidence.job_for, _evidence.latest_checks
# A read GitHub rate-limited, where the evidence reader tells it apart (main's main_fix_evidence.py): exit 3, which
# gh-merge-green reports as a rate limit rather than a red. A reader without it raises Refused (exit 1).
RateLimited = getattr(_evidence, "RateLimited", ())


class RateLimitedRead(Exception):
    """A read GitHub rate-limited, as judge() re-raises it so the comparison cannot swallow it.

    main's RateLimited is a Refused, and the comparison turns a Refused from a read into a refusal of its
    own ("no rollup red is excused", say) in a dozen places, so a rate limit read as a verdict on the red
    and main() returned 1 where gh-merge-green expects 3. This is not a Refused, so only main() catches it.
    """


def rate_limited_classes() -> tuple:
    """What main() reports as a rate limit, as one flat tuple. A reader without RateLimited leaves it the empty
    tuple, and `except ((), RateLimitedRead)` is a TypeError on every other refusal ("catching classes that do not
    inherit from BaseException"), which would break the ordinary exit-1 path. Read at call time, so a caller that
    loads a reader with RateLimited (main's) is honoured."""
    return ((RateLimited,) if isinstance(RateLimited, type) else tuple(RateLimited)) + (RateLimitedRead,)


def json_shape(route: str, found, *, paginate: bool = False, none: bool = False):
    """FOUND, GitHub's parsed answer to ROUTE, when it is a JSON object or list (a paginated read: each page is one);
    NONE lets a None through (a test fake's empty answer). Anything else is Refused as unread, naming the first
    SHAPE_CHARS characters of what came back, so no reader below calls `.get` on it. While the REST quota was spent
    a read of a workflow's runs came back as a str, and list_base_runs' `listed.get("workflow_runs")` raised
    AttributeError, a traceback merge_hold showed as the refusal (cmux#39676 at 9be3f014, 2026-11-10)."""
    for page in found if paginate and isinstance(found, list) else [found]:
        if not (isinstance(page, (dict, list)) or (none and page is None)):
            raise Refused(f"GitHub's answer to {route} could not be read: {str(page)[:SHAPE_CHARS]}")
    return found


SHAPE_CHARS = 200


def rate_limit_aware(github):
    """GITHUB with every rate-limited read raised as RateLimitedRead instead (above), and every `json` read that is not
    a JSON object or list Refused as unread (json_shape). Reads are looked up on each call, so a caller that replaces
    one (the tests' fakes) is still read, and checked."""
    class Aware:
        def __getattr__(self, name: str):
            attribute = getattr(github, name)
            if not callable(attribute):
                return attribute

            def read(*args, **kwargs):
                try:
                    found = attribute(*args, **kwargs)
                except RateLimited as error:
                    raise RateLimitedRead(str(error)) from None
                if name == "json" and args:
                    return json_shape(str(args[0]), found, paginate=bool(kwargs.get("paginate")), none=True)
                return found

            return read

    return Aware()


# The fields this script reads from each REST list it reads, as a `gh api --jq` projection. On an agent host the gh
# shim answers a REST read over GraphQL while the REST quota is under its floor, and GraphQL's answer has REST's
# common fields only, so a read with no --jq (a whole object) was refused there: manaflow-ai/cmux#38416's merge check
# stopped on "GraphQL could not answer `gh api repos/manaflow-ai/cmux/actions/runs/42476982159/jobs?...`: a whole REST
# object ...; add --jq naming fields" (2026-11-08). Naming the fields lets it answer, and on REST the projection
# keeps every field read here (a job's runner and labels are never read). A field added to a reader of these lists
# goes here too: a missing one reads as null, never as a refusal. Reads GraphQL can't answer whatever the fields
# (a single job, a compare's merge base, a run's check suite node id, artifacts, workflow runs) stay whole.
JOB_FIELDS = ("id, name, run_id, run_attempt, head_sha, head_branch, workflow_name, status, conclusion, started_at, "
              "completed_at, html_url, url, check_run_url")
STEP_FIELDS = "name, status, conclusion, number, started_at, completed_at"
PROJECTIONS = (
    # A run's jobs (filter=all or latest), one page each.
    (re.compile(r"repos/[^/]+/[^/]+/actions/runs/\d+(?:/attempts/\d+)?/jobs(?:\?.*)?"),
     f"{{total_count, jobs: [.jobs[] | {{{JOB_FIELDS}, steps: [.steps[]? | {{{STEP_FIELDS}}}]}}]}}"),
    # A commit's combined status.
    (re.compile(r"repos/[^/]+/[^/]+/commits/[^/?]+/status(?:\?.*)?"),
     "{state, sha, total_count, statuses: [.statuses[] | {context, state, description, target_url, created_at, "
     "updated_at}]}"),
    # A branch's commit history.
    (re.compile(r"repos/[^/]+/[^/]+/commits\?(?:.*&)?sha=.*"),
     "[.[] | {sha, commit: {committer: {date: .commit.committer.date}}, parents: [.parents[]? | {sha}]}]"),
)


def projection(route: str) -> str | None:
    """The `--jq` projection for ROUTE (PROJECTIONS), or None to read it whole."""
    return next((jq for pattern, jq in PROJECTIONS if pattern.fullmatch(route)), None)


ESCAPE_FLAG = "--allow-escape-sequences"
UNKNOWN_ESCAPE_FLAG = f"unknown flag: {ESCAPE_FLAG}"
REQUEST_FAILED = "GitHub evidence request failed: "


# Notes an agent host's gh wrappers write before the real gh's own stderr (a wait on a repeated read).
WRAPPER_NOTE_PREFIXES = ("glaeda-gh:", "gh-quota:")


def escape_flag_unknown(stderr: str) -> bool:
    """Whether an old gh rejected the optional ANSI-output flag itself: gh's first line, after any
    wrapper notes, is exactly the refusal. Another unknown flag first still refuses."""
    lines = [line.strip() for line in (stderr or "").strip().splitlines()]
    gh_lines = [line for line in lines if not line.startswith(WRAPPER_NOTE_PREFIXES)]
    return bool(gh_lines) and gh_lines[0] == UNKNOWN_ESCAPE_FLAG


class GitHub(_evidence.GitHub):
    """GitHub client for red attribution, including logs of finished jobs in live runs."""

    def log(self, repo: str, job: dict) -> str:
        # `gh run view --log` waits for every job in the run. The Actions job
        # endpoint serves a finished job while sibling jobs remain queued.
        route = f"repos/{repo}/actions/jobs/{job['id']}/logs"
        # Request ANSI-capable output first; old gh versions reject the flag, while modern
        # versions reject coloured output without it. Either way, normalize bytes in Python.
        # A log section can open with a byte-order mark before its timestamp, which hides that line from every
        # reader that matches a stamp or a prefix (cmuxterm-hq run 42391652834's WS_CHECK_RESULT, 2026-11-07).
        try:
            return self.run(["api", ESCAPE_FLAG, route]).replace("\ufeff", "")
        except Refused as error:
            said = str(error)
            if not (said.startswith(REQUEST_FAILED) and escape_flag_unknown(said[len(REQUEST_FAILED):])):
                raise
        return self.run(["api", route]).replace("\ufeff", "")

    def json(self, route: str, *, paginate: bool = False, per_page: int = 100):
        # A run's job list carries every job's steps; see JOBS_PAGE.
        if paginate and "/jobs?" in route:
            per_page = min(per_page, JOBS_PAGE)
        jq = projection(route)

        def fetch(url: str):
            # Each page is checked as it comes, so the pager never meets a str either (json_shape).
            said = self.run(["api", url, *(("--jq", jq) if jq is not None else ())])
            try:
                found = json.loads(said)
            except ValueError:
                raise Refused(f"GitHub's answer to {url} could not be read: {said[:SHAPE_CHARS]}") from None
            return json_shape(url, found)
        if not paginate:
            return fetch(route)
        try:
            return _evidence.gh_pages.pages(fetch, route, per_page=per_page)
        except _evidence.gh_pages.PageCapError as error:
            raise Refused(str(error)) from None

    def dispatch(self, repo: str, workflow: str, ref: str) -> int | None:
        """Start a workflow_dispatch run of WORKFLOW (a file name) on REF; its run id, or None when GitHub named none.
        Refused when this host's gh may not dispatch (base_dispatch)."""
        said = self.run(["api", "-X", "POST", f"repos/{repo}/actions/workflows/{workflow}/dispatches",
                         "-f", f"ref={ref}", "-F", "return_run_details=true"])
        try:
            run = json.loads(said or "{}").get("workflow_run_id")
        except (ValueError, AttributeError):
            return None
        return run if isinstance(run, int) else None

    def artifact_file(self, repo: str, artifact: int, member: str) -> str | None:
        """MEMBER's text in Actions ARTIFACT's zip, or None when the zip has no such file. Refused when the download
        fails, passes ARTIFACT_SECONDS, or the zip or the file passes ARTIFACT_MAX_BYTES."""
        with tempfile.TemporaryFile() as output, tempfile.TemporaryFile() as errors:
            # gh in a group of its own: a gh wrapper's child holds stdout too, and only killing the whole group
            # ends the read.
            process = subprocess.Popen(["gh", "api", f"repos/{repo}/actions/artifacts/{int(artifact)}/zip"],
                                       stdout=subprocess.PIPE, stderr=errors, start_new_session=True)

            def kill() -> None:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except (ProcessLookupError, PermissionError):  # gone, or a macOS zombie group
                    pass

            fired = threading.Event()

            def expire() -> None:
                fired.set()
                kill()

            # A read blocks while gh sends nothing: the deadline kills gh's group, which ends the read
            # (router-review F1 of #37969: a stalled download held the whole run's deadline, not ARTIFACT_SECONDS).
            end = time.monotonic() + ARTIFACT_SECONDS
            deadline = threading.Timer(ARTIFACT_SECONDS, expire)
            deadline.start()
            try:
                kept = 0
                while chunk := process.stdout.read(1 << 20):
                    kept += len(chunk)
                    if kept > ARTIFACT_MAX_BYTES:
                        raise Refused(f"artifact {artifact} is over {ARTIFACT_MAX_BYTES} bytes")
                    output.write(chunk)
                process.wait()
                if fired.is_set() or time.monotonic() > end:  # the timer thread may run late
                    raise Refused(f"artifact {artifact} took over {ARTIFACT_SECONDS} seconds to read")
            finally:
                deadline.cancel()
                kill()  # a stray child of a wrapper too, on every path
                process.wait()
            if process.returncode:
                errors.seek(0)
                raise Refused(REQUEST_FAILED + errors.read(2000).decode(errors="replace"))
            output.seek(0)
            try:
                with zipfile.ZipFile(output) as archive:
                    if member not in archive.namelist():
                        return None
                    info = archive.getinfo(member)
                    if info.file_size > ARTIFACT_MAX_BYTES:
                        raise Refused(f"artifact {artifact}: {member} unpacks past the cap")
                    with archive.open(info) as found:
                        raw = found.read(ARTIFACT_MAX_BYTES + 1)
            except zipfile.BadZipFile as error:
                raise Refused(f"artifact {artifact} is not a zip ({error})") from None
            if len(raw) > ARTIFACT_MAX_BYTES:
                raise Refused(f"artifact {artifact}: {member} unpacks past the cap")
            return raw.decode(errors="replace")

    def blob(self, repo: str, ref: str, path: str) -> str:
        """PATH's text in REPO at REF over GraphQL (`object(expression: "REF:PATH")`), never the contents API: an
        agent host's gh shim refuses `gh api repos/O/R/contents/...` as a source read that spends the shared REST
        quota (source_text). Refused when the object is missing, not a file, or binary."""
        owner, _, name = repo.partition("/")
        found = json.loads(self.run(["api", "graphql", "-f", f"query={BLOB_QUERY}", "-f", f"owner={owner}",
                                     "-f", f"name={name}", "-f", f"expression={ref}:{path}"]))
        repository = (found.get("data") or {}).get("repository") if isinstance(found, dict) else None
        blob = repository.get("object") if isinstance(repository, dict) else None
        if not isinstance(blob, dict) or blob.get("isBinary") or not isinstance(blob.get("text"), str):
            raise Refused(f"{repo}@{ref}: {path} is not a text file GitHub served")
        if blob.get("isTruncated"):
            raise Refused(f"{repo}@{ref}: {path} was served truncated")
        return blob["text"]


BLOB_QUERY = ("query($owner: String!, $name: String!, $expression: String!) { repository(owner: $owner, name: $name) "
              "{ object(expression: $expression) { ... on Blob { text isBinary isTruncated } } } }")
# Where git_text keeps its shallow, blob-less fetches of other repos (one bare repo each). Override for tests or a
# host whose cache lives elsewhere.
SOURCE_CACHE_ENV = "BASE_RED_EXCUSE_SOURCE_CACHE"
GIT_SECONDS = 60
# The whole run's wall-clock bound (module docs). Real runs read a few job logs and finish in well under a minute.
DEADLINE_SECONDS = 1200
PLACEHOLDER_SHA = re.compile(r"([0-9a-fA-F])\1{39}")


class Deadline(BaseException):
    """The run passed its deadline. A BaseException, so no `except Refused` or `except Exception` on the way out
    takes it for a verdict and reads on."""


def deadline_seconds() -> int:
    raw = os.environ.get("BASE_RED_EXCUSE_DEADLINE_SECONDS", "")
    try:
        value = int(raw) if raw else DEADLINE_SECONDS
    except ValueError:
        return DEADLINE_SECONDS
    return value if value > 0 else DEADLINE_SECONDS


def _past_deadline(signum, frame):
    raise Deadline()


def source_cache() -> Path:
    named = os.environ.get(SOURCE_CACHE_ENV)
    if named:
        return Path(named)
    return Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "base-red-excuse" / "src"


def git_remote(repo: str) -> str:
    return f"https://github.com/{repo}.git"


def git_text(repo: str, ref: str, path: str) -> str | None:
    """PATH's text in REPO at REF from git, or None when git cannot answer (no network, no credentials, no ref).

    A bare repo per REPO under source_cache(), fetched one commit deep with no blobs (`--depth=1 --filter=blob:none`),
    so a read costs one ref fetch and the one blob `git show` asks for, and no GitHub API quota at all. The fetch goes
    to a ref of this process's own, so two runs reading different bases at once never read each other's."""
    if not re.fullmatch(r"[\w.-]+/[\w.-]+", repo) or ref.startswith("-") or not ref:
        return None
    where = source_cache() / (repo.replace("/", "__") + ".git")
    env = {**os.environ, "GIT_TERMINAL_PROMPT": "0", "GIT_ASKPASS": "", "SSH_ASKPASS": ""}

    def git(*args: str) -> subprocess.CompletedProcess:
        return subprocess.run(["git", "--git-dir", str(where), *args], capture_output=True, env=env,
                              timeout=GIT_SECONDS, stdin=subprocess.DEVNULL)

    mine = f"refs/base-red-excuse/{os.getpid()}"
    try:
        if not (where / "HEAD").is_file():
            where.mkdir(parents=True, exist_ok=True)
            if subprocess.run(["git", "init", "-q", "--bare", str(where)], capture_output=True,
                              timeout=GIT_SECONDS).returncode:
                return None
        for key, value in (("remote.origin.url", git_remote(repo)), ("remote.origin.promisor", "true"),
                           ("remote.origin.partialclonefilter", "blob:none")):
            if git("config", key, value).returncode:
                return None
        if git("fetch", "-q", "--no-tags", "--depth=1", "--filter=blob:none", "origin",
               f"+{ref}:{mine}").returncode:
            return None
        shown = git("show", f"{mine}:{path}")
        if shown.returncode:
            return None
        return shown.stdout.decode()
    except (OSError, subprocess.SubprocessError, UnicodeDecodeError):
        return None
    finally:
        try:
            git("update-ref", "-d", mine)
        except (OSError, subprocess.SubprocessError):
            pass


def source_text(repo: str, ref: str, path: str, github) -> str:
    """PATH's text in REPO at REF: git first (git_text, no API quota), then GitHub's GraphQL blob (GitHub.blob).
    Never the REST contents API, which an agent host's gh shim refuses as a source read (glaeda-gh's API-source
    guard): the classifier needs no override of that guard on any path."""
    text = git_text(repo, ref, path)
    if text is not None:
        return text
    return github.blob(repo, ref, path)


_spec = importlib.util.spec_from_file_location("test_reds", Path(__file__).with_name("test_reds.py"))
test_reds = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(test_reds)

SETUP_STEPS = frozenset({"Set up job", "Set up runner"})
# Rollups: jobs that only report other jobs' results, judged by those jobs, never by themselves. Only which
# jobs are rollups is named here (workflow file, job id); the rest is derived from the workflows into
# ROLLUPS_FILE by `base_red_excuse.py --write-rollups` (derive_rollups): each rollup's check name (its
# `name:`), the jobs under it (its `needs:`, followed through their own `needs:`), and for a routed rollup
# (ci-guards.yml's Guard status) the route input each needed job runs on (its `if:`). The file is read with
# no YAML parser, so every host that runs this script reads the same contract; tests/test_base_red_excuse.py
# fails when it differs from the workflows. Anything in a workflow or in the file that does not have the
# expected shape is refused, never guessed at: a rollup red is then never excused.
# A run rollup is red when a job under it is red: the whole run's red jobs are judged. One in a called workflow names
# its caller (workflow file, job id), whose name is its check's prefix: ci-web.yml's Web status is 'web / Web status',
# red only when a web job under it is red, and was refused as "no failing test or error line to match" on every PR
# whose web shard red the base shares (2026-11-09, cmux#39559, hq#8503).
RUN_ROLLUPS = (("ci.yml", "ci-status"), ("ci-web.yml", "web-status", ("ci.yml", "web")))
ROUTED_ROLLUPS = (("ci-guards.yml", "guard-status"),)  # also reports each needed job's route (validate_guard_routes)
# Jobs a routed rollup needs only to place its runner (their outputs pick its runs-on): no guard verdict of their
# own, so the contract leaves them out of its routes (ci-guards.yml portable-placement, #34849).
ROLLUP_PLACEMENT_JOBS = frozenset({"portable-placement"})
ROLLUPS_FILE = Path(__file__).with_name("base_red_rollups.json")
WORKFLOWS = Path(__file__).resolve().parents[2] / ".github" / "workflows"
# The repo whose workflows sit beside this script: its contract is ROLLUPS_FILE.
HOME_REPO = "manaflow-ai/cmux"
# Rollups of the other repos this script judges (--repo), named the same way: (workflow file, job id). Their workflows
# are not in this checkout, so the contract is derived when a red is judged, from the repo's own workflow files at the
# base (derive_rollups over source_text: git, else GraphQL; load_rollups). A repo not named here has no rollups: every
# red job of it is judged as itself. cmuxterm-hq's Skill documentation tests only reports its shards (skills-tests.yml), and was
# refused on every HQ PR as "no failing test or error line to match" (2026-11-04: hq#7038, hq#7039).
OTHER_REPO_ROLLUPS = {
    "manaflow-ai/cmuxterm-hq": {"run": (("skills-tests.yml", "tests"),), "routed": ()},
}
# A called workflow's base verdict, from the workflow that calls it on base pushes (2026-11-07). ci.yml runs on pull
# requests only; on feat-cmux-next the same ci-web.yml runs from cmux-next-web.yml's `web` job, under the same
# 'web / ...' check names. ci.yml's newest feat-cmux-next run was a 2026-10-06 dispatch, so every web shard red on a
# PR was judged against that month-old pass and refused as having no verdict at or after its merge-base (cmux#37667's
# 'web / Web tests (1/4)', red on the base in cmux-next web run 42358745538). Keyed by (the base branch, the PR run's
# workflow file, the caller job id whose '<id> / ' prefix the check carries), the value is the workflow file whose job
# of the same id calls the same reusable workflow on pushes to that base branch, and only that one: a PR into `main`
# never reads cmux-next web, whose runs on `main` (a dispatch) are no base evidence. tests/test_base_red_excuse.py
# checks each entry against the workflows. Its verdict is read only when the PR run's own workflow has none at or
# after the merge-base.
BASE_WORKFLOW_FOR = {("feat-cmux-next", "ci.yml", "web"): "cmux-next-web.yml"}
# A workflow no base push or schedule runs gets its base verdict from a dispatch on the base tip (2026-11-07).
# nightly-next-cua-signed-host.yml runs on pull requests that touch it and on a schedule, but a schedule fires only
# from the default branch, where the file was not yet registered, so feat-cmux-next never had a run of it: every red
# 'signed host admission' (cmux#37855 at 960fd459, cmux#27704) was refused as having no base verdict, and no change to
# that workflow could land. For a (base, workflow file) here, a missing or stale base verdict starts one dispatch of
# the workflow on the base tip, unless one is still running or one started within BASE_DISPATCH_EVERY; the judge
# then refuses, naming that run, and the next check after it completes compares against it as any base run. The run
# list is the record, so every host shares one dedupe and nothing waits here. A host whose gh cannot dispatch (a lane
# VM's broker) refuses with the reason; the next check from a host that can starts it. Keep this list to workflows
# whose base verdict cannot come from a push: each dispatch is a Mac job.
BASE_DISPATCH = frozenset({("feat-cmux-next", "nightly-next-cua-signed-host.yml")})
BASE_DISPATCH_EVERY = timedelta(minutes=60)
ROUTE_IF = re.compile(r"\$\{\{ *inputs\.(\w+) *== *'true' *\}\}")
# A route report the Guard status prints: always read, even for a job the contract does not name (refused as unknown).
ROUTE_REPORT = r"workflow-guard-[\w-]+|linux_guard_\w+"
HOOK_REFUSAL = "glaeda-cmux-runner-hook: refused"
VERDICTS = frozenset({"success", "failure"})
# How far back the base lookup reads. A feat-cmux-next push skips swift-test, so its base verdict comes
# from the tip Swift suite (main's cmux-next-tip-swift-suite-dispatch.yml, about one run an hour), and
# DEV daily dispatches land between those runs every few minutes: on 2026-10-28, 16 of the base's 20
# newest completed runs were DEV daily runs, and the tip suite run fell out of a 20-run window, so
# no Swift red on any PR could be compared. One page of 100 runs reaches back hours; job listings
# are read newest first, at most BASE_JOB_READS per workflow, so a long run of runs with no verdict
# for the job stays bounded.
BASE_RUNS_PAGE = 100
BASE_JOB_READS = 40
# A run's job list carries every job's steps. GitHub answered the 34-job web run 41098664586's list with
# HTTP 502 at 100 and 50 per page, every time, and at 30 it answered (2026-10-30).
JOBS_PAGE = 30
# A job no feat-cmux-next push runs gets its base verdict from a dispatch: main's tip suite dispatcher
# (cmux-next-tip-swift-suite-dispatch.yml), cmux-next-base-tier-kick.yml (the base Mac tier, at most
# once every 15 minutes on the tip, cmuxterm-hq#5424), each a run named `<title><tested sha>`, or a hand
# dispatch. Base pushes land every minute or two, so the window above can miss them (2026-10-30: no
# daemon-test verdict on the base for hours, #27692). When it does, the base's newest completed dispatches
# are read too, newest first, and the first with a verdict for the job decides, a green one included: an
# older red never stands over a newer green. A suite that never runs the job (DEV daily runs, the other
# suites) is skipped unread, here and in the window above. At most TIP_SUITE_JOB_READS job lists; none of
# them with a verdict refuses as before.
SUITES = {
    "cmux-next tip Swift suite · ": frozenset({"cmux-next swift test"}),
    "cmux-next tip daemon suite · ": frozenset({"cmux-next daemon tests"}),
    # cmux-next.yml base_tier: path routing's base_tier branch routes these, and nothing else. Its generated
    # files are checked on the generated-files job itself (path routing's generated_host), never folded.
    "cmux-next base tier · ": frozenset({
        "cmux-next daemon tests", "cmux-next generated files", "cmux app scheme compile (Debug)",
        "cmux-next crash ends the app",
    }),
    # cmux-next.yml dispatches that route neither swift-test nor daemon-test (path routing's dev_daily branch).
    "cmux NEXT DEV daily": frozenset(),
}
# The base-red window (2026-11-01): how many of the newest base verdicts for a job a head's failing test may have
# failed on. Only the newest decides whether the job is red on the base at all; the window only widens which
# failing tests count as the base's (see the module docstring). The tip Swift suite runs about every 1.5 to 2 hours
# and one page of BASE_RUNS_PAGE dispatches reaches back about 11 hours (DEV daily runs land about 9 an hour), so 5
# verdicts (about 8 to 10 hours of the suite) fit in that page with TIP_SUITE_JOB_READS to spare for a lost run.
# Older verdicts are read only when the newer ones leave a head test unexcused, one log each, and never one more
# than BASE_WINDOW_HOURS older than the newest.
BASE_WINDOW = 5
BASE_WINDOW_HOURS = 24
TIP_SUITE_JOB_READS = BASE_WINDOW + 2
# The jobs of the cmux-tui tree tiers (cmux_next_tree_notify.TIERS: daemon, scheme). A tip daemon suite or base tier
# dispatch whose tree has not published yet skips them and leaves them to the same-tree run its publish dispatches,
# which carries the same `<title><tested sha>` name. So a suite run with a newer run of the same name (queued,
# running or done) is that first run: it is skipped unread for these jobs and never spends a job-list read. On
# 2026-10-31 the base tier's six newest completed dispatches were all such first runs, and the tip daemon suite
# run with the verdict, behind them, was never read: no pull request's daemon-test red could be compared.
TREE_JOBS = frozenset({"cmux-next daemon tests", "cmux app scheme compile (Debug)", "cmux-next crash ends the app"})


def deferred_first_runs(runs: list[dict]) -> set[int]:
    """The ids of suite runs in RUNS (newest first) that have a newer run of the same name: first runs whose
    tree jobs went to that later same-tree run."""
    seen: set[str] = set()
    deferred: set[int] = set()
    for run in runs:
        title = run.get("display_title") or ""
        if not suite_jobs(run):
            continue
        if title in seen:
            deferred.add(run["id"])
        seen.add(title)
    return deferred


def suite_jobs(run: dict) -> frozenset[str] | None:
    """The jobs a base run's suite can carry, or None for a run of no known suite (a push, a hand dispatch)."""
    title = run.get("display_title") or ""
    return next((jobs for prefix, jobs in SUITES.items() if title.startswith(prefix)), None)


# The jobs some suite above is the base verdict for. Only these are ever skipped: every other job (checks,
# web bundles, the placement jobs) may run in any suite, so a suite run's verdict for it always counts.
SUITE_JOBS = frozenset().union(*SUITES.values())


# A cancelled base tier run is one the base tier kick found superseded with no Mac job in progress
# (cmux_next_base_tier.py cancel_superseded): read here it mostly spends the lookup limits that reach the run
# with a verdict. But since 2026-11-09 (cmux#39631) the kick also cancels a run whose daemon tests or generated
# files finished while its scheme compile still queued, so for those jobs (CANCELLED_TIER_VERDICT_JOBS) such a run
# can hold the newest verdict: a green there must stand over an older red. For them a cancelled base tier run is
# read only when its check suite shows a verdict for the job (or cannot be read), and one with none is passed
# over without spending a job-list read (cancelled_tier_without_verdict). For every other job it has none.
BASE_TIER_TITLE = "cmux-next base tier · "
CANCELLED_TIER_VERDICT_JOBS = frozenset({"cmux-next daemon tests", "cmux-next generated files"})


def cancelled_base_tier(run: dict) -> bool:
    return run.get("conclusion") == "cancelled" and (run.get("display_title") or "").startswith(BASE_TIER_TITLE)


def never_carries(run: dict, name: str) -> bool:
    """Whether RUN's suite never runs job NAME, so it has no verdict for it to read."""
    if cancelled_base_tier(run) and name not in CANCELLED_TIER_VERDICT_JOBS:
        return True
    jobs = suite_jobs(run)
    return name in SUITE_JOBS and jobs is not None and name not in jobs


def tested_sha(run: dict) -> str:
    """The commit a cmux-next.yml run tested: the sha its name ends in (a same-tree run tests it after the
    branch moved on), else its head_sha."""
    match = re.search(r" · ([0-9a-f]{40})$", run.get("display_title") or "")
    return match.group(1) if match else str(run.get("head_sha") or "")


ANSI = re.compile(r"\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1b\\))")
ERROR = re.compile(r"##\[error\]|\berror:")
WARNING = re.compile(r"##\[warning\]|\bwarning:")
# A job whose own script says its one red on a line of its own, not an annotation: that line is its error line.
# scripts/ci/cua_signed_host_check.py ends a red run with `FAIL: <why>` and then only the runner's generic exit-code
# annotation, so 'signed host admission' had no error line to compare, and its base red on cmux#37855 (the same
# "signed app pid N never kept an accepted host connection" on base run 42383535506) could not be matched.
JOB_ERROR = {"signed host admission": re.compile(r"^FAIL: ")}
# Release-notary helpers report successful validations as `ok: ... (error: ...)`.
# The parenthesized diagnostic is expected output, not a failed check; only
# error annotations outside a successful `ok:` wrapper are evidence.
SUCCESS_DIAGNOSTIC = re.compile(r"^\s*ok:\s+.*\berror:", re.IGNORECASE)
# Summaries carry counts, and a test's own lines already name it.
GENERIC = re.compile(r"Process completed with exit code|red tests?:|✘ Test |Test Case '|\.\.\. FAILED$")
SUMMARY_FAILURE = re.compile(
    r"(?i)\b(?:changed|stale|missing|mismatch|not stamped|not found|out of date|invalid|unavailable|"
    r"cannot|could not|failure|failed|fail|does not match|not match)\b"
)
STAMP = re.compile(r"^\d{4}-\d\d-\d\dT[\d:.]+Z ?")
# SwiftPM's line for a killed test helper, and the hang sampler's ::error lines for it.
CRASH = re.compile(r"exited with unexpected signal code (\d+)|the test helper died on signal (\d+)")
CRASH_LINE = re.compile(r"exited with unexpected signal code|the test helper died on signal|"
                        r"no \"Test run with\" summary line")
# A commit sha inside an error line: a full 40-hex sha, or 7 to 39 hex digits right after a word that
# names a commit (commit, sha, tree, revision). The same red on the head and the base names each run's
# own commit; any other hex id (an artifact, a hash) is compared as it is. A full 40-hex id right after
# a word that names a stored thing rather than a commit (ARTIFACT) is such an id: two different digests
# stayed one error line while every bare 40-hex token was masked, so a real red could pass as a base red
# (cmux#35902, from the review of #35893). A commit the line does not name as an artifact still masks,
# whatever word introduces it: a base red often names each run's own tree or stamp with no keyword at
# all ("source stamp <40-hex> != <40-hex>"), which is why the bare case cannot ask for one.
ARTIFACT = r"(?i:artifacts?|artefacts?|assets?|digests?|checksums?|hashe?s?|packs?|bundles?|archives?|images?|layers?)"
# What may stand between such a word and its id: spaces, one `:` or `=`, and an opening quote or bracket
# (`artifact: <40-hex>`, `checksum=<40-hex>`, `digest (<40-hex>)`), which the literal space alone missed
# (cmux#35941 F1); or an opening quote or bracket on its own, with no space or `:` before it
# (`artifact(<40-hex>)`, `pack"<40-hex>"`, `bundle[<40-hex>]`), which still fell to the bare branch
# (cmux#35941 F3). A separator of some kind is always required, so a bare 40-hex still masks.
NAMED = r"(?:(?:[ \t]+|[ \t]*[:=][ \t]*)[(\[`'\"]?|[(\[`'\"])"
SHA = re.compile(rf"(?P<artifact>\b{ARTIFACT}{NAMED}[0-9a-f]{{40}}\b)"
                 r"|\b[0-9a-f]{40}\b"
                 r"|\b(?P<commit>(?:commit|sha|tree|revision) `?)[0-9a-f]{7,39}\b")
# A compile check that gave no verdict (the build-fleet controller unreachable, timed out, or a result
# for another head): nothing compiled the head, so it is never a base red, whatever the base shows
# (2026-10-28: the fleet Release compile's "no result" was red on PRs and on the base alike while the
# controller was wedged). It is set aside only when another job compiled that same head: COMPILE_PASSES.
# Only the job's own ::error annotation counts (`##[error]` at the start of the line): the log also
# echoes the step's script, which spells these words out on every run, a real compile red included.
# Fail closed: of compile-status's own lines, only "(fail)" is a real compile red; every other state (no result,
# unavailable, mismatch, unreadable, pending, "last: ...", a pass it could not post) and a status it could not
# post at all are no verdict.
NO_VERDICT = re.compile(r"^##\[error\]\s*(?:cmux-next/compile is not a pass for \S+ \((?!fail\))|"
                        r"could not post the pending status|bad head sha |No build-fleet verdict for `)")
# The jobs that can end without a verdict: an unreadable log of one is never comparable either.
NO_VERDICT_JOBS = frozenset({"cmux-next fleet Release compile", "cmux-next app compile (build fleet)"})
# The shared generated-files check only reads the verdict produced by the Swift or daemon job that built
# the package.  A failed prerequisite (especially a cancelled-before-start runner job) leaves that value
# empty, so this check has no result of its own.  It must be rerun together with its host job; comparing its
# fail-closed diagnostic with the base would turn missing evidence into an apparent PR red.
GENERATED_VERDICT_JOB = "cmux-next generated files (shared build)"
GENERATED_NO_VERDICT = re.compile(
    r"^##\[error\]\s*(?:swift-test|daemon-test) \(cancelled\) gave no generated files verdict:"
)
# A summary gate whose dependencies judged nothing (cancelled, abandoned, skipped though required, an empty result)
# says so in one annotation that starts "no verdict: " (scripts/ci/needs_verdict.py, NO_VERDICT_PREFIX). It ends red
# so it never reads as a pass, but it is never the pull request's own red and never a base red: it gets re-run.
# 2026-11-09: #39791's `rust workspaces` summary read `plan: abandoned` as a red, compared it with a green base and
# refused the merge as the pull request's own. Only the live annotation counts (test_reds.lines_of drops the echoed
# script, which spells the same words).
SUMMARY_NO_VERDICT = re.compile(r"^##\[error\]\s*no verdict: ")
# The same rule's red: `summary red: <what>: <job>: failure; ...`. It names which needs failed, in words every summary
# shares, so it is never a signature, an error to compare or evidence of any kind (signature drops it): two summaries
# match on it whichever children failed (cmux#39857 review, 2026-11-09: rust workspaces failing crate-a on the head
# was excused by a base failing crate-b). A summary red is refused with "compare its failed children" unless its
# children are compared one by one, as Guard status's are (validate_guard_routes).
SUMMARY_RED = re.compile(r"^##\[error\]\s*summary red: ")
# A real compile pass at the head: the Mac Release compile (a check run), or the fleet's cmux-next/compile
# commit status.
COMPILE_PASS_CHECKS = ("cmux-next Release compile (Xcode 26)",)
COMPILE_PASS_STATUS = "cmux-next/compile"
# The Mac Release compile's steps that compile (or reuse a pass for the same inputs).
COMPILE_STEPS = frozenset({"Release compile", "Reuse that pass"})


# A matrix job named '<name> (${{ matrix.<key> }})' (ci-web.yml's Web tests): its jobs are '<name> (<value>)'.
MATRIX_NAME = re.compile(r"([^$]*[^$ ]) \(\$\{\{ *matrix\.(\w+) *\}\}\)")


def _check_matcher(job_id: str, job: dict, where: str) -> dict:
    """How the Actions jobs of JOB (id JOB_ID in a workflow) are named: {"exact": [...], "prefixes": [...]}. A job
    with no `name:` is named by its id; a called workflow's jobs are '<name> / <its job>'; a matrix job whose
    name holds no expression gets ' (<values>)' after it; a name may hold an expression only as a last
    ' / ${{ ... }}' segment. Any other shape is refused."""
    name = job.get("name", job_id)
    if not isinstance(name, str) or not name.strip() or name != name.strip():
        raise Refused(f"{where}: job {job_id} has no usable name")
    if "${{" in name and (one := MATRIX_NAME.fullmatch(name)):
        # 'Web tests (${{ matrix.shard }})': one name per value of that one matrix key, as Actions renders it.
        matrix = (job.get("strategy") or {}).get("matrix")
        key = one.group(2)
        values = None
        if isinstance(matrix, dict) and set(matrix) == {key} and isinstance(matrix[key], list):
            values = matrix[key]
        elif (isinstance(matrix, dict) and set(matrix) == {"include"} and isinstance(matrix["include"], list)
              and all(isinstance(row, dict) and key in row for row in matrix["include"])):
            values = [row[key] for row in matrix["include"]]
        if (not values or "uses" in job
                or not all(isinstance(v, (str, int)) and not isinstance(v, bool) and str(v) for v in values)):
            raise Refused(f"{where}: job {job_id}'s name {name!r} is not one matrix key over fixed values")
        return {"exact": [f"{one.group(1)} ({v})" for v in values], "prefixes": []}
    if "${{" in name:
        static, sep, expr = name.partition(" / ${{")
        if not sep or "${{" in static or not expr.endswith("}}") or "${{" in expr or "uses" in job:
            raise Refused(f"{where}: job {job_id}'s name {name!r} is not a fixed name with one last ' / ${{{{ }}}}' part")
        return {"exact": [], "prefixes": [static + " / "]}
    if "uses" in job:
        if (job.get("strategy") or {}).get("matrix"):
            raise Refused(f"{where}: job {job_id} calls a workflow over a matrix")
        return {"exact": [], "prefixes": [name + " / "]}
    if (job.get("strategy") or {}).get("matrix"):
        return {"exact": [name], "prefixes": [name + " ("]}
    return {"exact": [name], "prefixes": []}


def _needs(jobs: dict, job_id: str, where: str) -> list[str]:
    needs = jobs[job_id].get("needs", [])
    needs = [needs] if isinstance(needs, str) else needs
    if not isinstance(needs, list) or not all(isinstance(n, str) and isinstance(jobs.get(n), dict) for n in needs):
        raise Refused(f"{where}: job {job_id}'s needs {needs!r} are not jobs of its workflow")
    return needs


# PyYAML 6.0.3's pure-Python lib/yaml, unmodified (sdist sha256 d76623373421df22fb4cf8817020cbb7ef15c725b9d5e45f17e189bfc384190f,
# MIT, its LICENSE beside it): the YAML reader where the interpreter has no PyYAML. merge_hold runs this script as
# `python3 -I` under Homebrew's Python on the Mac that lands PRs, which has none, and every cmuxterm-hq rollup red
# was refused there with "no YAML parser" (2026-11-07, hq#7398).
VENDORED_YAML = Path(__file__).resolve().with_name("_vendor")


def yaml_module():
    """PyYAML: the interpreter's own, else the vendored copy (VENDORED_YAML). Refused when neither imports."""
    try:
        import yaml  # noqa: PLC0415 - only deriving reads YAML; judging this repo reads ROLLUPS_FILE
        return yaml
    except ImportError:
        pass
    if (VENDORED_YAML / "yaml" / "__init__.py").is_file():
        if str(VENDORED_YAML) not in sys.path:
            sys.path.append(str(VENDORED_YAML))
        try:
            import yaml  # noqa: PLC0415
            return yaml
        except ImportError:
            pass
    raise Refused("no YAML parser to read the workflows' rollups; no rollup red is excused")


def derive_rollups(workflows: Path = WORKFLOWS, *, run=RUN_ROLLUPS, routed=ROUTED_ROLLUPS, read=None) -> dict:
    """The rollups contract (ROLLUPS_FILE) derived from the workflow files; refuses any shape it does not know.
    RUN and ROUTED name the rollups (another repo's, OTHER_REPO_ROLLUPS); READ(file) gives a workflow's text when it
    is not under WORKFLOWS (another repo's, at its base)."""
    yaml = yaml_module()
    if read is None:
        def read(file: str) -> str:
            return (workflows / file).read_text()
    out: dict = {"run": {}, "routed": {}}
    for kind, declared in (("run", run), ("routed", routed)):
        for file, job_id, *caller in declared:
            where = f".github/workflows/{file}"
            doc, jobs = _workflow(yaml, read, file)
            if not isinstance(jobs.get(job_id), dict):
                raise Refused(f"{where}: no job {job_id}")
            check = _check_matcher(job_id, jobs[job_id], where)
            if check["prefixes"] or len(check["exact"]) != 1:
                raise Refused(f"{where}: rollup {job_id} has no fixed name")
            prefix = ""
            if caller:
                # A called workflow's jobs are '<its caller's name> / <job>' (_check_matcher of the caller job).
                (caller_file, caller_id), = caller
                caller_where = f".github/workflows/{caller_file}"
                caller_job = _workflow(yaml, read, caller_file)[1].get(caller_id)
                if not isinstance(caller_job, dict) or caller_job.get("uses") != f"./{where}":
                    raise Refused(f"{caller_where}: no job {caller_id} calling {where}")
                prefix = _check_matcher(caller_id, caller_job, caller_where)["prefixes"][0]
            name = prefix + check["exact"][0]
            if name in out["run"] or name in out["routed"]:
                raise Refused(f"{where}: two rollups are named {name!r}")
            needs = _needs(jobs, job_id, where)
            if not needs:
                raise Refused(f"{where}: rollup {job_id} needs no job")
            if kind == "run":
                under, todo = {}, list(needs)
                while todo:
                    need = todo.pop()
                    if need not in under:
                        matcher = _check_matcher(need, jobs[need], where)
                        under[need] = {kind_: [prefix + v for v in matcher[kind_]] for kind_ in ("exact", "prefixes")}
                        todo.extend(_needs(jobs, need, where))
                out["run"][name] = {"workflow": file, "job": job_id, "under": dict(sorted(under.items()))}
                continue
            triggers = doc.get(True, doc.get("on"))
            inputs = (triggers.get("workflow_call") or {}).get("inputs") if isinstance(triggers, dict) else None
            if not isinstance(triggers, dict) or set(triggers) != {"workflow_call"} or not isinstance(inputs, dict):
                raise Refused(f"{where}: a routed rollup's workflow must be called only, with inputs")
            routes = {}
            for need in needs:
                if need in ROLLUP_PLACEMENT_JOBS:
                    continue
                condition = jobs[need].get("if")
                route = None
                if condition is not None:
                    match = ROUTE_IF.fullmatch(condition.strip()) if isinstance(condition, str) else None
                    if match is None or match.group(1) not in inputs:
                        raise Refused(f"{where}: job {need}'s if {condition!r} is not one route input == 'true'")
                    route = match.group(1)
                routes[need] = {"route": route, **_check_matcher(need, jobs[need], where)}
            out["routed"][name] = {"workflow": file, "job": job_id, "routes": routes}
    return out


def _workflow(yaml, read, file: str) -> tuple[dict, dict]:
    """Workflow FILE (READ gives its text) and its `jobs:`; refused when unreadable or of another shape."""
    where = f".github/workflows/{file}"
    try:
        doc = yaml.safe_load(read(file))
    except (OSError, Refused, yaml.YAMLError) as error:
        raise Refused(f"{where}: unreadable ({error})") from None
    jobs = doc.get("jobs") if isinstance(doc, dict) else None
    if not isinstance(jobs, dict):
        raise Refused(f"{where}: no jobs")
    return doc, jobs


def _matcher_ok(matcher: object) -> bool:
    return (isinstance(matcher, dict) and set(matcher) >= {"exact", "prefixes"}
            and all(isinstance(matcher[k], list) and all(isinstance(v, str) and v for v in matcher[k])
                    for k in ("exact", "prefixes")))


_ROLLUPS: dict | None = None
# Other repos' contracts, derived by load_rollups: {repo: contract}.
_REPO_ROLLUPS: dict[str, dict] = {}
NO_ROLLUPS = {"run": {}, "routed": {}}


def load_rollups(repo: str, base: str, github) -> None:
    """Derive REPO's rollups contract from its own workflow files at BASE, once. HOME_REPO's is ROLLUPS_FILE."""
    if repo == HOME_REPO or repo in _REPO_ROLLUPS or repo not in OTHER_REPO_ROLLUPS:
        return
    declared = OTHER_REPO_ROLLUPS[repo]

    def read(file: str) -> str:
        return source_text(repo, base, f".github/workflows/{file}", github)

    try:
        _REPO_ROLLUPS[repo] = derive_rollups(run=declared["run"], routed=declared["routed"], read=read)
    except Refused as error:
        raise Refused(f"{repo} rollups at {base}: {error}; no rollup red is excused") from None


def rollups(repo: str = HOME_REPO) -> dict:
    """REPO's rollups contract. HOME_REPO's is ROLLUPS_FILE, checked for shape; refused (so no rollup red is
    excused) when missing or malformed. Another repo's is the one load_rollups derived (refused when it has not), and a
    repo with no rollups named in OTHER_REPO_ROLLUPS has none."""
    if repo != HOME_REPO:
        if repo not in OTHER_REPO_ROLLUPS:
            return NO_ROLLUPS
        if repo not in _REPO_ROLLUPS:
            raise Refused(f"{repo}: its rollups were not read from its workflows; no rollup red is excused")
        return _REPO_ROLLUPS[repo]
    global _ROLLUPS
    if _ROLLUPS is None:
        try:
            data = json.loads(ROLLUPS_FILE.read_text())
        except (OSError, ValueError) as error:
            raise Refused(f"{ROLLUPS_FILE.name}: unreadable ({error}); no rollup red is excused") from None
        run, routed = (data.get("run"), data.get("routed")) if isinstance(data, dict) else (None, None)
        ok = (isinstance(run, dict) and isinstance(routed, dict) and run and routed
              and all(isinstance(r, dict) and isinstance(r.get("under"), dict) and r["under"]
                      and all(_matcher_ok(m) for m in r["under"].values()) for r in run.values())
              and all(isinstance(r, dict) and isinstance(r.get("routes"), dict) and r["routes"]
                      and all(_matcher_ok(m) and (m.get("route") is None or isinstance(m.get("route"), str))
                              for m in r["routes"].values()) for r in routed.values()))
        if not ok:
            raise Refused(f"{ROLLUPS_FILE.name}: not a rollups contract; no rollup red is excused")
        _ROLLUPS = data
    return _ROLLUPS


def matches(matcher: dict, name: str, prefix: str = "") -> bool:
    """Whether Actions job NAME is one of the jobs MATCHER names, under a caller's PREFIX ('guards / ')."""
    return (any(name == prefix + exact for exact in matcher["exact"])
            or any(name.startswith(prefix + start) for start in matcher["prefixes"]))


def routed_rollup(name: str, repo: str = HOME_REPO) -> tuple[dict, str] | None:
    """(the routed rollup check NAME is, the caller prefix it runs under), or None. A routed rollup's workflow is
    only ever called, so its check is '<caller> / <name>' (a bare name is still one, with no prefix)."""
    for rollup, contract in rollups(repo)["routed"].items():
        if name == rollup or name.endswith(" / " + rollup):
            return contract, name[:-len(rollup)]
    return None


def is_aggregate(name: str, repo: str = HOME_REPO) -> bool:
    """Whether a check of REPO reports other jobs rather than running work itself."""
    return name in rollups(repo)["run"] or routed_rollup(name, repo) is not None


def _sub_shas(text: str, keep: list | None = None) -> str:
    """TEXT with its commit shas masked (SHA). With KEEP, each id the pattern preserves is set aside there and
    left as a marker of letters alone, so a later pass over TEXT's numbers cannot touch its digits."""
    def masked(match: re.Match[str]) -> str:
        if (named := match.group("artifact")) is not None:
            if keep is None:
                return named
            keep.append(named)
            return _marker(len(keep) - 1)
        return (match.group("commit") or "") + "<sha>"

    return SHA.sub(masked, text)


def _marker(index: int) -> str:
    """A placeholder for the id at INDEX of a keep list: letters between two NULs, so no number masking,
    and nothing test_reds.volatile rewrites, is in it."""
    letters = ""
    index += 1
    while index:
        index, rest = divmod(index - 1, 26)
        letters = chr(ord("a") + rest) + letters
    return f"\0{letters}\0"


def mask_shas(text: str) -> str:
    """TEXT with its commit shas masked, leaving every other hex id as it is (SHA)."""
    return _sub_shas(text)


def normalise_error(text: str) -> str:
    """An error line as compared with the base's: the annotation prefix dropped, commit shas, run-to-run tokens
    (test_reds.volatile: run-named temp dirs, the runner's checkout root, times) and then
    every number masked, so the same red on two runs is one line and a different red is not. An id mask_shas
    preserves keeps its digits: they are the whole of what tells two digests apart (cmux#35941 F2)."""
    kept: list = []
    said = _sub_shas(text.replace("##[error]", "").strip(), keep=kept)
    said = re.sub(r"\d+", "#", test_reds.volatile(said))
    for index, id_ in enumerate(kept):
        said = said.replace(_marker(index), id_)
    return said


def lines_of(log: str) -> list[str]:
    """The text of each `job<TAB>step<TAB>stamp text` line of `gh run view --log`."""
    found = []
    for line in log.replace("\ufeff", "").splitlines():  # a log section can open with a BOM; strip() keeps it
        parts = line.split("\t", 2)
        # `gh run view --log` prefixes each line with job and step columns.
        # The job-log API does not; preserve tabs in raw command output.
        text = parts[2] if len(parts) == 3 and STAMP.match(parts[2]) else line
        found.append(ANSI.sub("", STAMP.sub("", text)).strip())
    return found


# The line the runner opens each step's section of a job log with, after "Set up job" (the log's first lines): `Run
# <script's first line>` for a run: step, `Run owner/action@ref` for a uses: step (and a job hook's `Run '/setup.sh'`),
# `Post job cleanup.` for a post step. "Complete job" opens with no such line.
STEP_START = re.compile(r"^(?:##\[group\]Run |Post job cleanup\.$)")


def _stamp_time(value) -> datetime | None:
    try:
        parsed = datetime.fromisoformat(str(value).strip().replace("Z", "+00:00"))
    except (AttributeError, TypeError, ValueError):
        return None
    return parsed if parsed.tzinfo else None


FAILED, PASSED, AMBIGUOUS = "failed", "passed", "ambiguous"


def step_owners(job: dict, log: str) -> list[tuple[str, int | None, str]]:
    """Each line of LOG as (line, the index of the step of JOB that printed it or None, its status): FAILED or PASSED
    when that step is known and failed or passed, AMBIGUOUS when it cannot be told. The steps are the jobs API's steps
    that ran, by number, without skipped ones. The one owner of a line's step: failed_steps_log, signature,
    step_lines and every caller of theirs read lines through it. A comment shows FAILED and AMBIGUOUS lines; an excuse
    reads a head's FAILED and AMBIGUOUS lines as its evidence and a base's FAILED lines alone.

    A line's step is told by the log's own order, never by a step's name (names repeat, and a named step's header is
    `Run <its run: line>`, not its name: cmux-next-ios kit job 129951569749's "Select Xcode" opens with `Run
    ./scripts/select-ci-xcode.sh`) nor by whole-second times alone (steps share seconds: cmux#40497, cmux#40542). The log
    splits into blocks at each STEP_START line; the steps take the blocks in order, each step one run of them: "Set up
    job" from the first line, every other step from a STEP_START line, and "Complete job", which prints none, shares
    the last run with the step before it. A step may take more than one block: a composite action prints a STEP_START
    line per inner step, and a step's own output may print one (`::group::Run diagnostic details`). A placement holds
    when every stamped line is within its steps' [started_at - 1s, completed_at + 1s] (the metadata keeps whole
    seconds) and each step's first line carries a stamp. With no placement that holds (a step that printed nothing
    and no extra block to cover it, a step with no times, a line outside every step it could be given) every line is
    AMBIGUOUS.

    Order picks a line's step; time decides what that is sure of. A step's status is PASSED when the jobs API says
    success and none of its lines is `##[error]...` (a continue-on-error step that failed reads as a success there,
    but its section ends with `##[error]Process completed with exit code N.`); any other conclusion is FAILED. A line
    is AMBIGUOUS when placements that hold disagree on its step, or when its stamp (an unstamped line takes the one
    before it) is within [started_at, completed_at + 1s) of a step of the other status than its own: the metadata
    truncates to the second, so a line any step printed is within that step's window, and no line a failed step
    printed can read as PASSED, nor a passing step's as FAILED (an extra or a missing STEP_START line moves lines
    only between steps whose windows meet: LW#4177 F1, hq#8936 F1)."""
    lines = log.splitlines()
    unknown = [(line, None, AMBIGUOUS) for line in lines]
    steps = [step for step in job.get("steps") or [] if step.get("conclusion") != "skipped"]
    if all(isinstance(step.get("number"), int) for step in steps):
        steps.sort(key=lambda step: step["number"])
    spans = []
    for step in steps:
        start, end = _stamp_time(step.get("started_at")), _stamp_time(step.get("completed_at"))
        if start is None or end is None or end < start:
            return unknown
        spans.append((start, end + timedelta(seconds=1)))
    if len(steps) < 2:
        return unknown
    texts, times = lines_of(log), []
    for line in lines:
        parts = line.replace("﻿", "").split("\t", 2)
        stamp = STAMP.match(parts[2] if len(parts) == 3 and STAMP.match(parts[2]) else parts[0])
        at = _stamp_time(stamp.group()) if stamp else None
        if stamp and at is None:
            return unknown
        times.append(at)
    cuts = [0, *(n for n, text in enumerate(texts) if STEP_START.match(text)), len(lines)]
    blocks = list(zip(cuts, cuts[1:]))
    seen = [(min(found), max(found)) if (found := [t for t in times[a:z] if t is not None]) else None
            for a, z in blocks]
    runs = len(steps) - 1  # run k is step k's; the last is also "Complete job"'s
    one = timedelta(seconds=1)

    def owners_of(k: int) -> tuple[int, ...]:
        return (k, len(steps) - 1) if k == runs - 1 else (k,)

    def ends(k: int, first: int) -> list[int]:
        """Each block run k may end before, starting at block FIRST."""
        if first > 0 and times[blocks[first][0]] is None:
            return []  # a step's first line must carry its stamp; a continuation line may not
        low = min(spans[i][0] for i in owners_of(k)) - one
        high = max(spans[i][1] for i in owners_of(k))
        found = []
        for b in range(first, len(blocks)):
            if seen[b] is not None and not (low <= seen[b][0] and seen[b][1] <= high):
                break
            found.append(b + 1)
        return found

    ahead = [[False] * (len(blocks) + 1) for _ in range(runs + 1)]  # runs before k can fill the blocks before b
    ahead[0][0] = True
    for k in range(runs):
        for first in range(len(blocks)):
            if ahead[k][first]:
                for end in ends(k, first):
                    ahead[k + 1][end] = True
    behind = [[False] * (len(blocks) + 1) for _ in range(runs + 1)]  # runs from k on can fill the blocks from b on
    behind[runs][len(blocks)] = True
    for k in reversed(range(runs)):
        for first in range(len(blocks)):
            behind[k][first] = any(behind[k + 1][end] for end in ends(k, first))
    if not behind[0][0]:
        return unknown
    placed: list[set[int]] = [set() for _ in blocks]
    for k in range(runs):
        for first in range(len(blocks)):
            if ahead[k][first]:
                for end in ends(k, first):
                    if behind[k + 1][end]:
                        for b in range(first, end):
                            placed[b].add(k)
    owner = [next(iter(placed[b])) if len(placed[b]) == 1 else None for b, (a, z) in enumerate(blocks)
             for _ in range(a, z)]
    passed = [step.get("conclusion") == "success" for step in steps]
    for n, text in enumerate(texts):
        if text.startswith("##[error]"):
            if owner[n] is None:
                # An error line no single step owns: every step it could be makes no claim to have passed.
                for b, (a, z) in enumerate(blocks):
                    if a <= n < z:
                        for k in placed[b]:
                            for i in owners_of(k):
                                passed[i] = False
            else:
                for i in owners_of(owner[n]):
                    passed[i] = False
    passed[-1] = passed[-1] and passed[-2]  # "Complete job" shares the last run's lines
    found, at = [], None
    for n, line in enumerate(lines):
        at = times[n] or at
        k = owner[n]
        if k is None or at is None:
            found.append((line, None, AMBIGUOUS))
            continue
        mine = passed[k]
        if any(passed[i] != mine and spans[i][0] <= at < spans[i][1] for i in range(len(steps)) if i != k
               and not (k == runs - 1 and i == len(steps) - 1)):
            found.append((line, k, AMBIGUOUS))
        else:
            found.append((line, k, PASSED if mine else FAILED))
    return found


def failed_steps_log(job: dict, log: str) -> str:
    """LOG without the lines of JOB's passing steps: its FAILED and AMBIGUOUS lines (step_owners). A job runs many
    steps, and a passing one may print error-looking stderr on purpose: test_ghostty_licenses.py's negative cases print
    "pinned license manifest digest changed" and pass. 2026-11-10: cmux#40369's static checks failed only in "Every
    page's strings generate with no missing translation" (feat-cmux-next runs 42820823641, 42820590433), and the
    excuse quoted that digest line, sending an agent after the wrong cause. A line whose step cannot be told is kept:
    what is shown of a red never hides its evidence."""
    return "\n".join(line for line, _, status in step_owners(job, log) if status != PASSED)


def signature(job: dict, log: str, base: bool = False) -> tuple[set[str], set[str], set[str]]:
    """(failed step names, failing test names, error lines with numbers masked), from what the steps printed: the
    runner's echo of each step's script is never a test or an error (test_reds.echoed; 2026-10-30, cmux#28145 was
    excused because the base's log echoed the same `echo "::error::..."` lines of its step's script). Error lines come
    from the failed steps' own lines (step_owners): a head's FAILED and AMBIGUOUS lines, so a line whose step cannot be
    told stays evidence against it, and with BASE a base's FAILED lines alone, so a line a passing step may have
    printed never matches a head error (cmux#40542 F1: a composite's extra STEP_START line put a passing step's
    `Sources/New.swift` diagnostic in the base's errors, and judge() excused the head's new failure)."""
    steps = {step["name"] for step in job.get("steps") or []  # step-name: classify
             if step.get("conclusion") not in (None, "success", "skipped")}
    tests = test_reds.failed_names(test_reds.lines_of(log))
    errors: set[str] = set()
    keep = (FAILED,) if base else (FAILED, AMBIGUOUS)
    scope = "\n".join(line for line, _, status in step_owners(job, log) if status in keep)
    skip = test_reds.echoed(test_reds.log_lines(scope))
    for n, text in enumerate(lines_of(scope)):
        if n in skip or text.startswith(test_reds.TAP_MARKER) or SUMMARY_RED.match(text):
            continue
        if ((ERROR.search(text)
             or ((marker := JOB_ERROR.get(job.get("name", ""))) is not None and marker.search(text))
             or (not tests and ("default" in job.get("name", "").lower()
                                or "snapshot" in job.get("name", "").lower())
                 and SUMMARY_FAILURE.search(text)))
                and not GENERIC.search(text) and not WARNING.search(text) and not CRASH_LINE.search(text)
                and not SUCCESS_DIAGNOSTIC.search(text)):
            errors.add(normalise_error(text))
    return steps, tests, errors


def no_verdict(log: str) -> str | None:
    """The line where a compile check says it gave no verdict, if it does."""
    return next((text for text in lines_of(log) if NO_VERDICT.match(text)), None)


def summary_red(log: str) -> str | None:
    """The line where a summary gate names its failed needs (SUMMARY_RED), if it does."""
    return next((text for text in test_reds.lines_of(log) if SUMMARY_RED.match(text)), None)


def summary_no_verdict(log: str) -> str | None:
    """The line where a summary gate says nothing it summarizes was judged (SUMMARY_NO_VERDICT), if it does."""
    return next((text for text in test_reds.lines_of(log) if SUMMARY_NO_VERDICT.match(text)), None)


def generated_no_verdict(log: str) -> str | None:
    """The shared generated-files check's fail-closed prerequisite diagnostic, if it printed one.

    ``test_reds.lines_of`` removes the runner's echoed shell script, which also contains the ``echo
    ::error::`` branch.  Only the live annotation is evidence that the prerequisite produced no verdict.
    """
    return next((text for text in test_reds.lines_of(log) if GENERATED_NO_VERDICT.match(text)), None)


def compile_pass_at(repo: str, sha: str, github) -> str | None:
    """What compiled SHA itself and passed: the newest Mac Release compile job at SHA that ran (its
    `Release compile` or `Reuse that pass` step succeeded), a cmux-next/compile success, or else the fleet's compile
    receipt for SHA reading "pass" (compile_receipt: this repository, that exact commit, recipe 2, release-onone).

    The receipt is what cmux-next/compile publishes (cmux-next.yml's compile-status step maps the same fields to the
    same verdict), and the fleet keeps one for every same-repository PR head whether or not that job runs: a PR whose
    route skips the status job has no status, but its receipt still says whether the app compiled. The fleet compiles
    each head as the app executable (`--app --release`, compiled and linked), resolving the binary targets the
    head's own manifest pins (its url and checksum), so a pass compiled the app against the head's pin
    (cmux#39251, 2026-11-10: every app compile check skipped by routing, the receipt at 3c886d8d a pass). An unread
    receipt, or one of another commit, repository or recipe, refuses (compile_receipt)."""
    candidates = []
    # Every attempt (filter=all): one rerun into startup_failure ran no jobs and must not hide the pass before it.
    for page in github.json(f"repos/{repo}/commits/{sha}/check-runs?filter=all&per_page=100", paginate=True):
        for check in page.get("check_runs") or []:
            if (check.get("name") in COMPILE_PASS_CHECKS and check.get("head_sha") == sha
                    and check.get("app", {}).get("slug") == "github-actions" and check.get("status") == "completed"
                    and check.get("conclusion") != "skipped"):
                candidates.append(check)
    # Newest first; the same name is also release-compile-fast-admission's (a Linux wrapper that compiles
    # nothing), so only a job with the Mac compile's own steps counts, and the newest such attempt decides.
    for check in sorted(candidates, key=lambda found: found.get("id", -1), reverse=True):
        # The check run's own Actions job, from its details link (a check run id is not a job id).
        link = re.fullmatch(r"https://github\.com/" + re.escape(repo) + r"/actions/runs/(\d+)/job/(\d+)",
                            check.get("details_url") or "")
        if not link:
            continue
        job = github.json(f"repos/{repo}/actions/jobs/{link[2]}")
        if (job.get("head_sha") != sha or job.get("name") != check.get("name")
                or job.get("run_id") != int(link[1])):
            continue
        steps = {step.get("name"): step.get("conclusion") for step in job.get("steps") or []}  # step-name: classify
        if not COMPILE_STEPS & steps.keys():
            continue
        if job.get("conclusion") == "success" and any(steps.get(name) == "success" for name in COMPILE_STEPS):
            return f"'{check['name']}' (job {link[2]})"
        break
    status = github.json(f"repos/{repo}/commits/{sha}/status")
    for found in status.get("statuses") or []:
        if found.get("context") == COMPILE_PASS_STATUS:
            # The combined status lists the newest per context.
            if found.get("state") == "success":
                return f"the {COMPILE_PASS_STATUS} status"
            break
    receipt = compile_receipt(repo, sha)
    if receipt is not None and receipt.get("state") == "pass":
        return (f"the fleet's app compile receipt (job {receipt.get('job_id') or 'unnamed'}, recipe "
                f"{receipt['recipe_version']}, {receipt['configuration']})")
    return None


# An inherited compile red (2026-11-09): cmux#38644 and #38631 branched from feat-cmux-next while #39301 had broken
# its cmux-tui compile, and the fleet's receipt for each head read "fail" with the base's own error. The fleet Release
# compile runs only on pull requests, so no base run has its job, and its cmux-next/compile status links the source
# run, which has no job of that name: both reds were refused with nothing to compare. The fleet's receipts are kept
# per commit, base pushes included, so the head's red is the base's when the head's receipt is a real "fail" and so is
# its merge-base's. Every other receipt state (no verdict, unread, another commit) stays the head's.
COMPILE_RECEIPTS = os.environ.get("BASE_RED_EXCUSE_COMPILE_RECEIPTS", "https://gh-events.cmux.com/compile-checks/v1")
COMPILE_RECEIPT_SECONDS = 20
# The receipts host sits behind a proxy that answers Python's default User-Agent ("Python-urllib/3.x") with HTTP 403
# (error code 1010, a refused client signature), so every read was refused and no compile red could be judged
# (cmux#39582, 2026-11-09). Name the client.
COMPILE_RECEIPT_USER_AGENT = "cmux-base-red-excuse"
COMPILE_RECEIPT_RECIPE = (2, "release-onone")
FLEET_COMPILE_JOB = "cmux-next fleet Release compile"
FLEET_COMPILE_FAIL = re.compile(r"^##\[error\]\s*cmux-next/compile is not a pass for [0-9a-f]{40} \(fail\)")
# A gate that depends on one service (2026-11-10): from about 01:00Z the fleet controller was off, the receipts host
# answered HTTP 530 for every commit, and every compile red inherited_compile_red judged was refused on the unread
# receipt (cmux#40025, #40030, #40059 held with a SHIP at their heads). A busy or missing service makes a merge slower,
# never impossible: when the receipts host is unreachable (a connection error, a timeout, any 5xx), the same question is
# asked of GitHub instead (github_compile_red). GitHub's cmux-next/compile status is what compile-status posts from the
# same receipt, so a head that reads "The app did not compile" is compared with that status at its merge-base, or, when
# the merge-base has none completed, at the newest of the BASE_STATUS_COMMITS newest base commits that has one. Only
# the same failure there excuses; a pass there is the head's red, and no completed status anywhere refuses, saying so.
COMPILE_STATUS_FAIL = "The app did not compile"
COMPILE_RECEIPT_DOWN = 500  # an HTTP answer at or above this (5xx, Cloudflare's 52x and 530) is the service down


# The cmux-next/compile descriptions of compile-status that are no verdict (unavailable, no result in 40 minutes, a
# result for another head); only "The app did not compile" (COMPILE_STATUS_FAIL) is a fail. With the controller off
# every PR's status read "No compile result for this head in 40 minutes": no receipt and no base status can judge
# that (github_compile_red refuses it), but a compile that passed at the head elsewhere can. A no-verdict status is
# judged like the no-verdict job (NO_VERDICT_JOBS): another compile's pass at the head (compile_pass_at, the Mac
# Release compile first) ignores it, so a down controller makes landing slower, never impossible.
COMPILE_STATUS_NO_VERDICT = re.compile(r"No compile result for this head|The compile check gave no verdict|"
                                       r"The compile result does not match this head")


class ReceiptUnreachable(Refused):
    """The receipts host did not answer (a connection error, a timeout, a 5xx): no verdict, and no answer about the
    receipt either, so a caller may ask GitHub instead (github_compile_red)."""


def compile_receipt(repo: str, sha: str) -> dict | None:
    """The fleet's compile receipt for SHA (one anonymous read, no wait), or None when it has none (404). Any other
    answer refuses: an unread receipt is no verdict."""
    import urllib.error
    import urllib.request
    url = f"{COMPILE_RECEIPTS}/{sha}?repo={urllib.parse.quote(repo, safe='')}&wait=0"
    try:
        request = urllib.request.Request(url, headers={"User-Agent": COMPILE_RECEIPT_USER_AGENT})
        with urllib.request.urlopen(request, timeout=COMPILE_RECEIPT_SECONDS) as answer:
            receipt = json.loads(answer.read(1 << 16))
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        if error.code >= COMPILE_RECEIPT_DOWN:
            raise ReceiptUnreachable(f"the compile receipt of {sha[:12]}: HTTP {error.code}") from error
        raise Refused(f"the compile receipt of {sha[:12]}: HTTP {error.code}") from error
    except OSError as error:  # URLError, a refused connection, a timeout: the service did not answer
        raise ReceiptUnreachable(f"the compile receipt of {sha[:12]}: {type(error).__name__}: {error}") from error
    except ValueError as error:
        raise Refused(f"the compile receipt of {sha[:12]}: {type(error).__name__}: {error}") from error
    if not isinstance(receipt, dict) or receipt.get("sha") != sha or receipt.get("repo") != repo:
        raise Refused(f"the compile receipt of {sha[:12]} names another commit")
    # The receipt the workflow trusts (cmux-next.yml's compile-status step): recipe 2, Release at -Onone.
    if (receipt.get("recipe_version"), receipt.get("configuration")) != COMPILE_RECEIPT_RECIPE:
        raise Refused(f"the compile receipt of {sha[:12]} is of another recipe (recipe_version "
                      f"{receipt.get('recipe_version')}, configuration {receipt.get('configuration')})")
    return receipt


def inherited_compile_red(repo: str, base: str, sha: str, name: str, github) -> str:
    """The audit line excusing NAME's compile red at SHA when the head's fleet receipt and its merge-base's both read
    "fail", else Refused. When the receipts host is unreachable, GitHub decides (github_compile_red)."""
    try:
        head = compile_receipt(repo, sha)
    except ReceiptUnreachable as down:
        return github_compile_red(repo, base, sha, name, github, down)
    if (head or {}).get("state") != "fail":
        raise Refused(f"'{name}': the compile receipt of {sha[:12]} is {(head or {}).get('state') or 'missing'}, not "
                      "a fail: no verdict to compare with the base")
    diff = github.json(f"repos/{repo}/compare/{base}...{sha}?per_page=1")
    merge_base = (diff.get("merge_base_commit") or {}).get("sha") or ""
    if not re.fullmatch(r"[0-9a-f]{40}", merge_base):
        raise Refused(f"'{name}': no merge-base of {sha[:12]} with {base} to compare its compile receipt with")
    try:
        at_base = compile_receipt(repo, merge_base)
    except ReceiptUnreachable as down:
        return github_compile_red(repo, base, sha, name, github, down)
    if (at_base or {}).get("state") != "fail":
        raise Refused(f"'{name}': the compile receipt of {sha[:12]} is a fail, and its merge-base {merge_base[:12]} "
                      f"on {base} reads {(at_base or {}).get('state') or 'no receipt'}: the red is this head's")
    tip = (diff.get("base_commit") or {}).get("sha") or ""
    now = ""
    if re.fullmatch(r"[0-9a-f]{40}", tip) and tip != merge_base:
        try:
            now = f"; {base} {tip[:12]} reads {(compile_receipt(repo, tip) or {}).get('state') or 'no receipt'}"
        except Refused:
            now = ""
    log_decider(f"'{name}' at {sha[:12]} was decided by the fleet's compile receipts")
    return (f"excused '{name}': the compile receipt of {sha[:12]} is a fail, and so is its merge-base "
            f"{merge_base[:12]}'s on {base} (an inherited base red{now}; merge the base for a new verdict)")


def log_decider(message: str) -> None:
    """Which path decided a compile red (the receipts or GitHub), on stderr beside the audit."""
    print(f"base_red_excuse: {message}", file=sys.stderr)


def compile_status_at(repo: str, sha: str, github) -> dict | None:
    """SHA's newest cmux-next/compile commit status, or None when it has none."""
    statuses = github.json(f"repos/{repo}/commits/{sha}/status?per_page=100").get("statuses") or []
    return next((found for found in statuses if found.get("context") == COMPILE_PASS_STATUS), None)


def github_compile_red(repo: str, base: str, sha: str, name: str, github, down: Refused) -> str:
    """inherited_compile_red's question asked of GitHub while the receipts host is unreachable (DOWN): the audit line
    excusing NAME's compile red at SHA when GitHub's cmux-next/compile at SHA reads a real compile fail and the same
    status at the merge-base (else the newest of the BASE_STATUS_COMMITS newest BASE commits with one completed) reads
    the same fail, else Refused naming why. Reads: one status, one compare, at most BASE_STATUS_COMMITS + 2 more; no
    wait and no retry, so a GitHub that cannot answer refuses too."""
    why = f"the receipts host is unreachable ({down})"
    log_decider(f"'{name}' at {sha[:12]}: {why}; GitHub decides")
    head = compile_status_at(repo, sha, github) or {}
    said = head.get("description") or ""
    if head.get("state") not in ("failure", "error") or not said.startswith(COMPILE_STATUS_FAIL):
        raise Refused(f"'{name}': {why}, and GitHub's {COMPILE_PASS_STATUS} at {sha[:12]} reads "
                      f"{head.get('state') or 'no status'}: {said or 'no description'}; only a real compile fail can "
                      "be the base's (a no-verdict compile never is), so neither path can decide")
    diff = github.json(f"repos/{repo}/compare/{base}...{sha}?per_page=1")
    merge_base = (diff.get("merge_base_commit") or {}).get("sha") or ""
    if not re.fullmatch(r"[0-9a-f]{40}", merge_base):
        raise Refused(f"'{name}': {why}, and GitHub names no merge-base of {sha[:12]} with {base}")
    candidates = [merge_base] + [commit.get("sha") or "" for commit in
                                 github.json(f"repos/{repo}/commits?sha={base}&per_page={BASE_STATUS_COMMITS}") or []
                                 if (commit.get("sha") or "") != merge_base]
    for commit in candidates:
        found = compile_status_at(repo, commit, github)
        if found is None or found.get("state") == "pending":
            continue
        where = "its merge-base" if commit == merge_base else f"{base}"
        if found.get("state") == head.get("state") and (found.get("description") or "") == said:
            log_decider(f"'{name}' at {sha[:12]} was decided by GitHub: {where} {commit[:12]} fails the same way")
            return (f"excused '{name}': {why}; GitHub's {COMPILE_PASS_STATUS} at {sha[:12]} reads \"{said}\", and so "
                    f"does {where} {commit[:12]} (an inherited base red, decided over GitHub; merge the base for a "
                    "new verdict)")
        log_decider(f"'{name}' at {sha[:12]} was decided by GitHub: {where} {commit[:12]} reads {found.get('state')}")
        raise Refused(f"'{name}': {why}; GitHub's {COMPILE_PASS_STATUS} at {sha[:12]} reads \"{said}\", but {where} "
                      f"{commit[:12]} reads {found.get('state')}: {found.get('description') or 'no description'}: "
                      "the red is this head's")
    log_decider(f"'{name}' at {sha[:12]}: neither the receipts nor GitHub can decide")
    raise Refused(f"'{name}': {why}, and GitHub has no completed {COMPILE_PASS_STATUS} at its merge-base "
                  f"{merge_base[:12]} or the {BASE_STATUS_COMMITS} newest {base} commits to compare with: neither path "
                  "can decide; re-run it once the fleet answers")


# The Rust panic ratchet (scripts/cmux-next/rust_panic_ratchet.py, run by .github/scripts/cmux-tui-clippy-changed.py).
# Its error line names the packages the run checked, and a base run may check the whole workspace while a PR checks
# only its changed packages, so that line never matches (2026-10-31: cmux#26849's run 41176610742 failed on two rows
# that base run 41176544319 failed on word for word, and was refused). Its red is judged by the rows of its RED
# block instead (ratchet_red): each head row `CRATE: clippy::LINT N > WHERE` must be on the base with the same
# crate, lint and WHERE (`baseline M` or `new crate (must be 0)`) and a count at least the head's; every other
# line of the block but a hit location must be on the base word for word. A red with no row is never excused.
RATCHET_SCOPE = re.compile(r"^the panic ratchet is red for .+; its log above names each new hit")
RATCHET_RED, RATCHET_END = "rust-panic-ratchet: RED", "Fix the hit "
RATCHET_ROW = re.compile(r"^(\S+): clippy::(\w+) (\d+) > (baseline \d+|new crate \(must be 0\))$")
RATCHET_HIT = re.compile(r"^[^\s:]+\.rs:\d+:\d+$")


def ratchet_red(log: str) -> tuple[dict[tuple[str, str, str], int], set[str]]:
    """({(crate, lint, where): count} of the ratchet's RED rows, its other RED lines), hit locations left out."""
    rows: dict[tuple[str, str, str], int] = {}
    other: set[str] = set()
    skip = test_reds.echoed(test_reds.log_lines(log))
    inside = False
    for n, text in enumerate(lines_of(log)):
        if n in skip:
            continue
        if text == RATCHET_RED:
            inside = True
        elif inside and (text.startswith(RATCHET_END) or text.startswith("##[")):
            inside = False
        elif inside and text:
            if row := RATCHET_ROW.match(text):
                crate, lint, count, where = row.groups()
                key = (crate, lint, where)
                rows[key] = max(rows.get(key, 0), int(count))
            elif not RATCHET_HIT.match(text):
                other.add(text)
    return rows, other


def ratchet_unmatched(head_log: str, base_log: str) -> list[str]:
    """The head's panic ratchet failures its base run does not have (empty when every one is covered)."""
    head_rows, head_other = ratchet_red(head_log)
    if not head_rows:
        raise Refused("the panic ratchet is red with no per-lint row to compare with the base "
                      "(a clippy run that did not finish, say)")
    base_rows, base_other = ratchet_red(base_log)
    missing = [f"{crate}: clippy::{lint} {count} > {where}" + (
                   f" (the base has {base_rows[(crate, lint, where)]})" if (crate, lint, where) in base_rows else "")
               for (crate, lint, where), count in sorted(head_rows.items())
               if base_rows.get((crate, lint, where), -1) < count]
    return missing + sorted(head_other - base_other)


def crash_signals(log: str) -> set[str]:
    """The signals a test helper died on, from SwiftPM's or the hang sampler's lines."""
    return {first or second for first, second in CRASH.findall(log)}


def refused_at_setup(job: dict, log: str | None = None) -> bool:
    steps = job.get("steps") or []
    if not steps or any(step.get("name") in SETUP_STEPS  # step-name: classify
                        and step.get("conclusion") == "failure" for step in steps):
        return True
    return log is not None and HOOK_REFUSAL in log


def validate_guard_routes(repo: str, sha: str, guard: dict, children: list[dict], github) -> None:
    """A Guard status red must report only failed routes backed by concrete children.

    The wrapper also validates routing inputs and required-but-skipped jobs.
    Those failures cannot be waived by an unrelated child that is red on base.
    Children returned by head_jobs are still compared with base by judge.
    """
    name = guard["name"]
    found = routed_rollup(name, repo)
    if found is None:
        raise Refused(f"'{name}': not a routed rollup of {ROLLUPS_FILE.name}")
    contract, prefix = found
    routed = contract["routes"]
    if guard.get("head_sha") not in (None, sha):
        raise Refused(f"'{name}': job is not for the exact SHA {sha}")
    if guard.get("status") != "completed" or guard.get("conclusion") != "failure":
        raise Refused(f"'{name}': no completed failure verdict for its routes")
    text = github.log(repo, guard)
    if refused_at_setup(guard, text):
        raise Refused(f"'{name}' was refused at setup by its runner")
    steps, _, errors = signature(guard, text)
    if steps != {"Check routed guard jobs"}:
        raise Refused(f"'{name}': non-routing failed steps: {'; '.join(sorted(steps))}")
    # The step judges its needs with scripts/ci/needs_verdict.py's rule: no verdict is re-run, never compared. Its
    # red line (SUMMARY_RED) is no error here (signature drops it): the route reports below are the evidence.
    if (said := summary_no_verdict(text)) is not None:
        raise Refused(f"'{name}' gave no verdict ({said[:300]}): nothing it summarizes was judged, so it is "
                      "neither a pass nor this PR's own red; re-run it")
    if errors:
        raise Refused(f"'{name}': routing error: {'; '.join(sorted(errors))[:600]}")
    report = test_reds.read(text)
    if report.crashes or report.truncated:
        raise Refused(f"'{name}': routing process crashed or ended early")
    routes = []
    lines = lines_of(text)
    inputs = {route["route"] for route in routed.values() if route["route"]}
    report = rf"({ROUTE_REPORT}|{'|'.join(re.escape(key) for key in sorted(set(routed) | inputs))}): (.+)"
    # The runner's preamble (token permissions, and a called workflow's echoed `Inputs`, whose `linux_guard_tests: true`
    # reads like a route report) ends at its `Complete job name:` line; no step prints before it.
    started = next((at for at, line in enumerate(lines) if line.startswith("Complete job name: ")), None)
    for line in lines if started is None else lines[started + 1:]:
        match = re.fullmatch(report, line)
        if not match:
            continue
        route, result = match.groups()
        result_match = re.fullmatch(r"failure(?: \(route ([\w]+)=(true|false)\))?", result)
        if not result_match:
            raise Refused(f"'{name}': {route}: {result}")
        reported_route, enabled = result_match.groups()
        if route not in routed:
            raise Refused(f"'{name}': unknown routed job {route}")
        expected_route = routed[route]["route"]
        if reported_route is not None and (reported_route != expected_route or enabled != "true"):
            raise Refused(f"'{name}': route {reported_route} does not map to {route} (expected {expected_route}=true)")
        if reported_route is None and expected_route is not None:
            raise Refused(f"'{name}': {route} has no route mapping in its failure report")
        if not any(child.get("conclusion") == "failure" and matches(routed[route], child.get("name", ""), prefix)
                   for child in children):
            raise Refused(f"'{name}': no failed child for routed failure {route}")
        routes.append(route)
    if not routes:
        raise Refused(f"'{name}': no routed failure report to compare with its children")


def validate_run_rollup(name: str, children: list[dict], repo: str = HOME_REPO) -> None:
    """Run rollup NAME (ci-status), red, needs a failed job under it (its needs, ROLLUPS_FILE): a red run whose only
    failed jobs are outside them did not turn it red, so its own verdict did, and nothing here can compare that."""
    under = rollups(repo)["run"][name]["under"]
    if not any(child.get("conclusion") == "failure" and any(matches(m, child.get("name", "")) for m in under.values())
               for child in children):
        raise Refused(f"'{name}': no failed job under its needs ({', '.join(sorted(under))}) to compare with the base")


# A status-only check (2026-11-02, cmux#30294): a same-tree run reports its verdict as a commit status on the
# head it tested ('cmux-next daemon tests (same-tree)', cmux-next.yml's "Report the same-tree result on the tested
# commit"), so the head has no check run of that name and every such red was refused as "has not run on exact
# head", even when the base failed the same tests. The status is judged by the job that gave it: the job of the
# same name without the " (same-tree)" suffix, in the run its target_url links (else the newest run that tested
# the head and has that job). It is then compared per test like any job; a run that cannot be found is refused.
# Once excused, its audit line names the status context too (cmux#37038 at 1f4963c0): merge_hold covers each red
# at the head only by a line naming it, and named only the job, it refused 'cmux-next daemon tests (same-tree)'.
SAME_TREE_SUFFIX = " (same-tree)"
# cmux-next-fast-gates.yml's status: the PR head merged with the base named in its description (`base <sha>`). A
# dispatched run's head_sha is the feat-cmux-next tip, not the PR head, so its red is never compared by the run: it is
# the PR's own at that base (a merger reruns one at a stale base), never a base red (cmux#38640, 2026-11-09).
FAST_GATES_STATUS = "cmux-next/fast-gates"


def status_job(repo: str, sha: str, name: str, github, base: str | None = None,
               suites: SuiteChecks | None = None) -> dict | str | None:
    """The completed Actions job behind commit status NAME on SHA, or None when SHA has no status NAME. A red
    status no Actions job gave (Vercel's) is the audit line of base_status when BASE shares it, else refused."""
    statuses = github.json(f"repos/{repo}/commits/{sha}/status?per_page=100").get("statuses") or []
    # The combined status lists the newest per context.
    status = next((found for found in statuses if found.get("context") == name), None)
    if status is None:
        return None
    state, job_name = status.get("state"), name.removesuffix(SAME_TREE_SUFFIX)
    if state == "pending":
        raise Refused(f"'{name}': its status is still pending on {sha}")
    if name == FAST_GATES_STATUS and state in ("failure", "error"):
        description = status.get("description") or ""
        tested = re.search(r"\bbase ([0-9a-f]{40})\b", description)
        run = re.search(r"/actions/runs/(\d+)", status.get("target_url") or "")
        raise Refused(f"'{name}': {state} at base {tested[1][:12] if tested else '(none named)'}"
                      f"{f' (run {run[1]})' if run else ''} is the pull request's own: the fast gates ran on it merged "
                      "with that base, never a base red; fix it, or dispatch them again on the tip if that base is stale")
    if name == COMPILE_PASS_STATUS and base and state in ("failure", "error"):
        description = status.get("description") or ""
        if COMPILE_STATUS_NO_VERDICT.match(description):
            try:
                proof, unread = compile_pass_at(repo, sha, github), ""
            except Refused as why:  # the receipt is read last: nothing before it passed
                proof, unread = None, f"; {why}"
            if proof is None:
                raise Refused(f"'{name}' gave no compile verdict ({description[:140]}) and nothing else compiled "
                              f"{sha}{unread}: a no-verdict compile is never a base red; re-run it once the fleet "
                              "answers, or once the Mac Release compile passes at this head")
            return f"ignored '{name}': it gave no compile verdict, but {proof} compiled {sha} and passed"
        # Its target_url is the source run, with no job of this name (inherited_compile_red).
        return inherited_compile_red(repo, base, sha, name, github)
    url = status.get("target_url") or ""
    match = re.fullmatch(r"https://github\.com/" + re.escape(repo) + r"/actions/runs/(\d+)(?:/job/\d+)?/?", url)
    if match:
        runs = [github.json(f"repos/{repo}/actions/runs/{match[1]}")]
        if tested_sha(runs[0]) != sha:
            raise Refused(f"'{name}': its status links run {match[1]}, which tested {tested_sha(runs[0])[:12]}, "
                          f"not {sha}")
    else:
        listed = github.json(f"repos/{repo}/actions/runs?head_sha={sha}&per_page=100")
        runs = [run for run in listed.get("workflow_runs") or [] if tested_sha(run) == sha]
    suites = suites or SuiteChecks(github)
    for index, run in enumerate(runs):
        # A run whose suite has no check run of that name has no such job in any attempt (the sweep limit, above).
        if not match and not may_hold(suites, runs, index, job_name, verdict=False):
            continue
        found = next((job for job in last_real_jobs(repo, run["id"], github) if job.get("name") == job_name), None)
        if found is None:
            continue
        if found.get("status") != "completed":
            raise Refused(f"'{name}': job '{job_name}' in run {run['id']} has not completed")
        if found.get("conclusion") == "success" or state == "success":
            raise Refused(f"'{name}': its status is {state} but job '{job_name}' in run {run['id']} is "
                          f"{found.get('conclusion')}; nothing to compare with the base")
        return found
    if not match and base and state in ("failure", "error"):
        return base_status(repo, base, name, state, status.get("description") or "", github, sha=sha)
    where = f"run {match[1]} (its target_url)" if match else f"any run that tested {sha}"
    raise Refused(f"'{name}': a status ({state}: {status.get('description') or 'no description'}) with no job "
                  f"'{job_name}' in {where} to compare with the base")


# A status no Actions job gave (2026-11-04, cmuxterm-hq#7039): Vercel posts "Deployment rate limited — retry in 24
# hours." on every commit, the base's included, while its build limit lasts, and there is no job or log behind it to
# compare per test. It is the base's only when the newest of the BASE_STATUS_COMMITS newest base commits that has a
# status of that context has it in the same state with the same description; one the base does not share, or shares
# with another description, stays the head's.
BASE_STATUS_COMMITS = 10

# Vercel's build quota (2026-11-05, cmuxterm-hq#7192): the head reads "Deployment rate limited — retry in 24 hours."
# while the base's newest Vercel status is a build Vercel skipped ("Canceled by Ignored Build Step"), so the two never
# match. A rate-limited deploy built nothing, so it is no result rather than a red, but only when the base did not
# build either (an ignored or canceled build, never a real success) and the PR changes nothing under web/, the tree
# Vercel deploys. Any other Vercel failure, or a PR that touches web/, still refuses.
VERCEL_RATE_LIMITED = re.compile(r"Deployment rate limited\b")
VERCEL_NOT_BUILT = re.compile(r"(?i)\bIgnored Build Step\b|\bcancel(?:l?ed)?\b")
VERCEL_TREE = "web/"
# A PR's files are read PR_FILES_PAGE at a time through files(after:) until the last page (cmux#37362 at 54470673
# changes 108 files; one page of 100 refused it). The PR's head and base commits must stay the same on every page, so
# the pages all list one diff.
PR_FILES_PAGE = 100
PR_FILES_PAGES = 30  # 3000 files, GitHub's own limit on a PR's file list
PR_FILES_QUERY = ("query($owner: String!, $name: String!, $oid: GitObjectID!, $after: String) { repository(owner: "
                  "$owner, name: $name) { object(oid: $oid) { ... on Commit { associatedPullRequests(first: 10) { "
                  f"nodes {{ number baseRefName baseRefOid headRefOid changedFiles files(first: {PR_FILES_PAGE}, "
                  "after: $after) { nodes { path } pageInfo { hasNextPage endCursor } } } } } } } }")


def pr_paths(repo: str, base: str, sha: str, github) -> tuple[int, list[str]]:
    """The open PR into BASE whose head is SHA, and every path it changes, over GraphQL (no REST), page by page.
    Refused when there is no such PR, when its base moves while it is read, or when GitHub lists fewer files than
    the PR changes."""
    owner, _, name = repo.partition("/")
    number, base_oid, paths, after, pr, info = None, None, [], None, {}, {}
    for _page in range(PR_FILES_PAGES):
        found = json.loads(github.run(["api", "graphql", "-f", f"query={PR_FILES_QUERY}", "-f", f"owner={owner}",
                                       "-f", f"name={name}", "-f", f"oid={sha}",
                                       "-F" if after is None else "-f", f"after={after or 'null'}"]))
        commit = (((found.get("data") or {}).get("repository") or {}).get("object") or {}) \
            if isinstance(found, dict) else {}
        pr = next((node for node in (commit.get("associatedPullRequests") or {}).get("nodes") or []
                   if node.get("headRefOid") == sha and node.get("baseRefName") == base
                   and (number is None or node.get("number") == number)), None)
        if pr is None:
            if number is None:
                raise Refused(f"no PR into {base} has head {sha} to read its changed files from")
            raise Refused(f"#{number}: no longer a PR into {base} with head {sha} while its files were read")
        if number is None:
            number, base_oid = pr.get("number"), pr.get("baseRefOid")
        elif pr.get("baseRefOid") != base_oid:
            raise Refused(f"#{number}: its base moved from {base_oid} to {pr.get('baseRefOid')} while its files "
                          "were read")
        files = pr.get("files") or {}
        paths += [node.get("path") for node in files.get("nodes") or [] if isinstance(node.get("path"), str)]
        info = files.get("pageInfo") or {}
        after = info.get("endCursor")
        if not info.get("hasNextPage") or not after:
            break
    if info.get("hasNextPage") or len(paths) != pr.get("changedFiles"):
        raise Refused(f"#{number}: GitHub listed {len(paths)} of its {pr.get('changedFiles')} changed files, too "
                      f"few to judge what it changes")
    return number, paths


# A step-A Rust change (cmux#37292, 2026-11-06): the app links one pinned release of the app FFI, and
# scripts/cmux-next/check-app-ffi-pin.sh reports "error: the app FFI sources changed since the pinned source" on any PR
# that changes its inputs. app-ffi-release.yml publishes only from a feat-cmux-next push, so such a PR can never carry
# its own pin: its merge is what publishes the release the re-pin then names. That error alone, in the cmux-next checks
# job, is excused when the PR changes FFI inputs, leaves Package.swift (the pin) alone and changes no Swift, so no app
# code calls a symbol or op the pinned library lacks. Any other red in the job is judged as before.
#
# Neither rule excuses a PR that changes a file that decides the pin verdict (FFI_PIN_CHECK_CODE; 2026-11-09, review of
# cmux#39194): it could make the pin error print for any change, and the published base pin rule excuses nearly every
# PR, since a head inherits the base's published pin.
#
# A published base pin (2026-11-07): step-A PRs change the FFI sources faster than releases publish, so a step-B PR (its
# Swift, or a re-pin) could never pin a release built from its own sources. Any other PR with that error has it excused
# when both hold: (a) the release its head pins (Package.swift's canonical CCmuxAppFFI block, app_ffi_pin.py: this
# repository's own cmux-app-ffi-<sha> release download and its checksum; any other shape refuses; or, at a head that
# has app-ffi-pin.json, that file read strictly with Package.swift holding only its one loader block, as cmux#37645
# moves the pin, so this base classifier can judge that PR) is
# published, its SOURCE_SHA names that sha, its SHA256SUMS carries that checksum for the archive, and that sha is on
# the PR's base (an ancestor of the base tip); (b) the app compile check passed at the
# PR's exact head (compile_pass_at: the Mac Release compile, cmux-next/compile, or the fleet's compile receipt for that
# head, which cmux-next/compile publishes and which a PR whose route skips the status job still has). The pin in Package.swift at the head is the pin that compile built with: SwiftPM
# resolves the binary target from that URL and checksum, nothing else. Drift since the pinned source can then only be
# other PRs' additive FFI changes, and the compile proves the symbols the app calls are in the pinned library.
FFI_PIN_JOB = "cmux-next checks (god files, concurrency, crash safety, l10n)"
FFI_PIN_CHECK = "Check the app FFI pin"
FFI_PIN_ROLLUP_STEP = "Fail on any red check"  # the job's last step, red when a continue-on-error check is
FFI_PIN_ERROR = "error: the app FFI sources changed since the pinned source"
FFI_PIN_MANIFEST = "Packages/macOS/CmuxNext/Package.swift"
FFI_PIN_FILE = "Packages/macOS/CmuxNext/app-ffi-pin.json"
FFI_PIN_PATHS = (FFI_PIN_FILE, FFI_PIN_MANIFEST)  # a PR changing either moves the pin
FFI_INPUTS = ("cmux-tui/crates/", "cmux-tui/rust-toolchain.toml", "scripts/cmux-next/build-app-ffi.sh")
# The files that decide the pin check's verdict: the check, the pin reader it runs, every step's BASH_ENV, this
# classifier and the workflow holding the pin step and its rollup (the checks job uses no .github/actions/). A PR
# changing one could make the pin error print for any change, so neither rule below excuses it (review of cmux#39194,
# the main copy of the step-A rule). Only these: a new FFI crate also changes app-ffi-release.yml, the router and the
# licence list (cmux#37869), which do not decide the verdict (review of cmux#39471).
FFI_PIN_CHECK_CODE = ("scripts/cmux-next/check-app-ffi-pin.sh", "scripts/ci/app_ffi_pin.py", "scripts/ci/api_call_log/",
                      "scripts/ci/base_red_excuse.py", ".github/workflows/cmux-next.yml")
FFI_RELEASE_SECONDS = 30
FFI_ASSET = "CCmuxAppFFI.xcframework.zip"


# The pin is read by scripts/ci/app_ffi_pin.py's fail-closed canonical match (2026-11-07), shared with the repin
# picker and the repin script: no Swift is parsed, and anything but the canonical block refuses.
_spec = importlib.util.spec_from_file_location("app_ffi_pin", Path(__file__).with_name("app_ffi_pin.py"))
app_ffi_pin = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(app_ffi_pin)
_spec = importlib.util.spec_from_file_location("github_release_download",
                                          Path(__file__).with_name("github_release_download.py"))
release_download = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(release_download)


def ffi_binary_target(manifest: str, repo: str, pin_file: str | None = None) -> tuple[str | None, str | None, str]:
    """(source sha, checksum, "") of the head's pin; else (None, None, why). With PIN_FILE (app-ffi-pin.json's text,
    None when the head has none) it is that file's pin (app_ffi_pin.read_pin_file) and MANIFEST (Package.swift's text)
    must hold only its loader block (app_ffi_pin.check_loader); without it, MANIFEST's canonical CCmuxAppFFI pin
    (app_ffi_pin.read). Either way REPO's own cmux-app-ffi-<sha> release download and a 64-hex checksum."""
    try:
        if pin_file is not None:
            sha, checksum = app_ffi_pin.read_pin_file(pin_file, repo)
            app_ffi_pin.check_loader(manifest, checksum)
        else:
            sha, checksum, _ = app_ffi_pin.read(manifest, repo)
    except app_ffi_pin.NotCanonical as why:
        return None, None, str(why)
    return sha, checksum, ""


def ffi_pin_file_at(repo: str, sha: str, github) -> str | None:
    """app-ffi-pin.json's text at SHA, or None when GitHub serves none there (the head is in the template form). A head
    whose file is unread is read in the template form, which refuses a JSON-era Package.swift: never a looser read."""
    try:
        return source_text(repo, sha, FFI_PIN_FILE, github)
    except Refused:
        return None


def ffi_release_file(repo: str, tag: str, name: str) -> str | None:
    """File NAME of the published release TAG of REPO, read anonymously from its release download (no API quota), or
    None when it is not published (404, or a release without it). A download that fails otherwise is read through
    the release-assets API (github_release_download.py; 2026-11-08 every release download answered 503 or 504 and
    every merge was held). Any other failure raises: an unread release is no answer."""
    import urllib.error
    url = f"https://github.com/{repo}/releases/download/{tag}/{name}"
    try:
        with tempfile.TemporaryDirectory(prefix="cmux-ffi-release-") as tmp:
            out = Path(tmp) / name
            release_download.download(url, out, FFI_RELEASE_SECONDS,
                                      log=lambda message: print(f"base_red_excuse: {message}", file=sys.stderr))
            with open(out, "rb") as answer:
                return answer.read(1 << 16).decode("utf-8", "replace")
    except release_download.NoAsset:
        return None
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        raise Refused(f"{url}: HTTP {error.code}; the pinned release could not be read") from error
    except (OSError, ValueError) as error:
        raise Refused(f"{url}: {type(error).__name__}: {error}; the pinned release could not be read") from error


def ffi_published_base_pin(repo: str, base: str, sha: str, github) -> tuple[str | None, str]:
    """(audit, "") when the head SHA's app FFI pin (its one CCmuxAppFFI binary target) is a published release of REPO
    built from a commit on BASE, its checksum the release's archive entry, and the app compile check passed at SHA
    (the published base pin rule above); else (None, the part of that rule that does not hold)."""
    pin, checksum, why = ffi_binary_target(source_text(repo, sha, FFI_PIN_MANIFEST, github), repo,
                                           ffi_pin_file_at(repo, sha, github))
    if pin is None:
        return None, why
    tag = f"cmux-app-ffi-{pin}"
    source = ffi_release_file(repo, tag, "SOURCE_SHA")
    sums = ffi_release_file(repo, tag, "SHA256SUMS") if source is not None else None
    if source is None or sums is None:
        return None, f"the pinned release {tag} is not published (its {'SOURCE_SHA' if source is None else 'SHA256SUMS'} is 404)"
    if source.strip() != pin:
        return None, f"the pinned release {tag} records SOURCE_SHA {source.strip()[:40]!r}, not {pin}"
    if f"{checksum}  {FFI_ASSET}" not in sums.splitlines():
        return None, f"the pinned checksum {checksum[:12]} is not {tag}'s SHA256SUMS entry for {FFI_ASSET}"
    status = github.json(f"repos/{repo}/compare/{base}...{pin}?per_page=1").get("status")
    if status not in ("behind", "identical"):
        return None, f"the pinned release's source {pin[:12]} is not an ancestor of {base} (it is {status or 'unread'})"
    proof = compile_pass_at(repo, sha, github)
    if proof is None:
        return None, (f"no app compile check passed at {sha} (cmux-next/compile, the Release compile, or the fleet's "
                      f"compile receipt), so nothing proves the app builds against {tag}")
    return (f"pins {tag}, a published release built from {pin[:12]}, which is on {base}, and {proof} compiled {sha} "
            "against that pin and passed"), ""


def ffi_pin_step_a(repo: str, base: str, sha: str, name: str, steps: set[str], errors: set[str], tests: set[str],
                   log: str, github) -> tuple[str | None, str | None]:
    """The audit line for a cmux-next checks job whose only red is the stale app FFI pin of a step-A Rust PR, or of a
    PR whose pin is a published base release its app compile passed against (the rules above). Wherever the pin error
    shows, the PR must be one a rule covers, whatever else is red: Refused when it changes Swift or Package.swift or no
    FFI input and its pin is not a published base release it compiled against, since the base comparison may set the
    error aside beside another red the base shares (review of d5c11dd8). None when there is no pin error, or when
    something else is red too (another failed step, a failing test, a crash, another error): that red is judged as
    before. The caller asks only after test_reds.read found no crash or cut-short run.

    Returns (audit line, set-aside line). The first is the excuse when the pin is the job's only red. The second, when
    other reds stand beside a pin a rule covers, says why the pin's own parts (without_ffi_pin) leave the base
    comparison: before 2026-11-07 they stayed in it, and since the base never has the pin error, a step-A PR whose
    job also carried reds the base shares (cmux#37767: the iOS CmuxTabsKit notice, a next-batch line) was refused."""
    pin, rollup = normalise_error(FFI_PIN_ERROR), normalise_error(f"red check: {FFI_PIN_CHECK}")
    if name != FFI_PIN_JOB or not any(error.startswith(pin) for error in errors):
        return None, None
    number, paths = pr_paths(repo, base, sha, github)
    if check_code := [path for path in paths if any(touches(path, code) for code in FFI_PIN_CHECK_CODE)]:
        raise Refused(f"'{name}': its app FFI pin is red, and #{number} changes the app FFI pin check's code "
                      f"({'; '.join(check_code[:5])}): a PR never excuses its own red by changing the check; land "
                      "the check change on its own, with the pin check green")
    if moved := [path for path in FFI_PIN_PATHS if path in paths]:
        why = (f"#{number} changes {moved[0]}: a PR that moves the pin must pin a release built from its own "
               "sources")
    elif swift := [path for path in paths if path.endswith(".swift")]:
        why = (f"#{number} changes Swift ({'; '.join(swift[:5])}): app code may call what the pinned library lacks; "
               "land the Rust alone, then the Swift after the re-pin")
    elif not any(touches(path, read) for path in paths for read in FFI_INPUTS):
        why = f"#{number} changes no app FFI input"
    else:
        why = None
    published = None
    if why is not None:
        published, missing = ffi_published_base_pin(repo, base, sha, github)
        if published is None:
            raise Refused(f"'{name}': its app FFI pin is red, and {why}; nor is its pin a published base release it "
                          f"compiled against: {missing}")
    others = {error for error in errors if not error.startswith(pin)} - {rollup}
    reason = (f"#{number} {published}" if published is not None else
              f"#{number} changes app FFI inputs, not {FFI_PIN_MANIFEST} and no Swift: a step-A Rust change, pinned "
              "by the release its merge publishes")
    # The rollup must have named the pin as its red check: a rollup that failed before saying so is another red.
    if (tests or crash_signals(log) or not steps or steps - {FFI_PIN_CHECK, FFI_PIN_ROLLUP_STEP} or others
            or rollup not in errors):
        return None, f"set aside '{FFI_PIN_CHECK}' (\"{FFI_PIN_ERROR}\"): {reason}"
    return f"excused '{name}': only '{FFI_PIN_CHECK}' is red (\"{FFI_PIN_ERROR}\"), and {reason}", None


def without_ffi_pin(head: tuple[set[str], set[str], set[str]]) -> tuple[set[str], set[str], set[str]]:
    """HEAD's signature (failed steps, failing tests, error lines) without the app FFI pin's own parts: its check step,
    its error lines and the rollup's line naming it. The rollup step stays: the base must have failed it too."""
    steps, tests, errors = head
    pin, rollup = normalise_error(FFI_PIN_ERROR), normalise_error(f"red check: {FFI_PIN_CHECK}")
    return (steps - {FFI_PIN_CHECK}, tests,
            {error for error in errors if not error.startswith(pin) and error != rollup})


def vercel_not_built(repo: str, base: str, sha: str | None, name: str, description: str, found: dict, github) -> str | None:
    """The audit line for a rate-limited Vercel deploy on SHA when the base's own Vercel status is a skipped build and
    the PR changes nothing under web/; None when the rule does not apply (the caller refuses as before)."""
    if not (sha and name.startswith("Vercel") and VERCEL_RATE_LIMITED.match(description)):
        return None
    if not VERCEL_NOT_BUILT.search(found.get("description") or ""):
        return None
    number, paths = pr_paths(repo, base, sha, github)
    if web := [path for path in paths if path.startswith(VERCEL_TREE)]:
        raise Refused(f"'{name}': \"{description}\" and #{number} changes {VERCEL_TREE} ({'; '.join(web[:5])}), "
                      "which Vercel deploys")
    return (f"excused '{name}': no result: \"{description}\" (Vercel built nothing), base status "
            f"{found.get('state')} \"{found.get('description')}\" (a skipped build), and #{number} changes no "
            f"{VERCEL_TREE} files")


def base_status(repo: str, base: str, name: str, state: str, description: str, github, *, sha: str | None = None) -> str:
    """The audit line excusing jobless status NAME (STATE, DESCRIPTION) when the base has the same, else Refused."""
    if not description:
        raise Refused(f"'{name}': a status ({state}) with no description and no job: nothing to compare with the base")
    for commit in github.json(f"repos/{repo}/commits?sha={base}&per_page={BASE_STATUS_COMMITS}") or []:
        statuses = github.json(f"repos/{repo}/commits/{commit['sha']}/status?per_page=100").get("statuses") or []
        found = next((found for found in statuses if found.get("context") == name), None)
        if found is None:
            continue
        if (found.get("state"), found.get("description") or "") != (state, description):
            if line := vercel_not_built(repo, base, sha, name, description, found, github):
                return line
            raise Refused(f"'{name}': a status ({state}: {description}) with no job, and {base} {commit['sha']} has "
                          f"it {found.get('state')}: {found.get('description') or 'no description'}")
        return f"excused '{name}': base {commit['sha']} status {state} \"{description}\""
    raise Refused(f"'{name}': a status ({state}: {description}) with no job, and none of the {BASE_STATUS_COMMITS} "
                  f"newest {base} commits has a status '{name}' to compare with")


# A run's jobs as its last real attempt left them (cmux#35906, 2026-11-05). GitHub's latest-attempt views
# (jobs?filter=latest, and check-runs with no filter) show only the newest attempt, and an attempt that ended in
# startup_failure runs no jobs: after two such reruns of run 41931705470 they showed no job at all, its 'publish
# tree-addressed cmux-tui' red included, and the head read as having no red. Such an attempt is no result, never a
# green, so every attempt is read (filter=all) and each job name keeps the jobs of the newest attempt that ran it. A
# real rerun (red, then green) still decides; a run whose only attempt ran nothing has no jobs, which is no result.
def last_real_jobs(repo: str, run: int, github) -> list[dict]:
    jobs = [job for page in github.json(f"repos/{repo}/actions/runs/{run}/jobs?filter=all&per_page=100", paginate=True)
            for job in page.get("jobs") or []]
    for job in jobs:
        # glaeda's slim job list names no run_id (and a --jq projection of it reads null); the run read is the job's
        # run (superseding_check reads it)
        if job.get("run_id") is None:
            job["run_id"] = run
    newest: dict[str, int] = {}
    for job in jobs:
        newest[job.get("name", "")] = max(newest.get(job.get("name", ""), 0), job.get("run_attempt") or 1)
    return [job for job in jobs if (job.get("run_attempt") or 1) == newest[job.get("name", "")]]


# The sweep limit (2026-11-06, cmux#36958). glaeda-gh refuses a caller that reads the jobs of more than 30 different
# runs or jobs in ten minutes, and this script read one job list per run it looked in. A status with no run link
# ('next-autoland / verdict') read the job list of every run that tested the head, 32 of them, looking for a job of its
# name; a base red read a job list per base run until one had a verdict for it, up to BASE_JOB_READS per workflow, most
# of them runs that skipped or cancelled the job. merge_hold asks about every red of a head in one call, so a head with
# a few reds was refused partway through its reads. Now which runs hold a job of a name is asked of their check suites
# over GraphQL, SUITES_PER_QUERY suites a request: every Actions job is a check run of its run's suite under the same
# name, one per attempt. A run is read only when its suite can answer: for a base verdict, a check run of the name
# with a verdict conclusion; for a status, a check run of the name. The job of a run's newest attempt is one of those
# check runs, so a run passed over could not have answered and every verdict is the same. A passed-over base run
# still counts toward BASE_JOB_READS, as the read it replaces did. A run with no check suite id, or a suite GraphQL
# did not answer in full, is read over REST as before.
SUITES_PER_QUERY = 25
SUITE_CHECKS_QUERY = ("query($name: String!) {{ nodes(ids: [{ids}]) {{ ... on CheckSuite {{ id checkRuns(first: 100, "
                      "filterBy: {{checkType: ALL, checkName: $name}}) {{ nodes {{ conclusion }} pageInfo "
                      "{{ hasNextPage }} }} }} }} }}")
NODE_ID = re.compile(r"[A-Za-z0-9_=+/-]{1,200}")


class SuiteChecks:
    """The conclusions of each check suite's check runs of a name, every attempt, read in batches over GraphQL."""

    def __init__(self, github):
        self.github = github
        self.known: dict[tuple[str, str], frozenset[str] | None] = {}

    def conclusions(self, runs: list[dict], index: int, name: str) -> frozenset[str] | None:
        """The conclusions ('' for one not finished) of every check run named NAME in RUNS[INDEX]'s check suite, or
        None when that cannot be told. The unread suites after it in RUNS are asked in the same request."""
        suite = suite_id(runs[index])
        if suite is None:
            return None
        if (suite, name) not in self.known:
            batch: list[str] = []
            for run in runs[index:]:
                other = suite_id(run)
                if other is not None and (other, name) not in self.known and other not in batch:
                    batch.append(other)
                    if len(batch) == SUITES_PER_QUERY:
                        break
            self.read(batch, name)
        return self.known.get((suite, name))

    def read(self, suites: list[str], name: str) -> None:
        self.known.update(((suite, name), None) for suite in suites)
        query = SUITE_CHECKS_QUERY.format(ids=", ".join(json.dumps(suite) for suite in suites))
        try:
            found = json.loads(self.github.run(["api", "graphql", "-f", f"query={query}", "-f", f"name={name}"]))
        except (Refused, ValueError):
            return  # read over REST instead, as before
        if not isinstance(found, dict) or found.get("errors") or not isinstance(found.get("data"), dict):
            return
        for node in found["data"].get("nodes") or []:
            checks = node.get("checkRuns") if isinstance(node, dict) else None
            if (not isinstance(checks, dict) or node.get("id") not in suites
                    or (checks.get("pageInfo") or {}).get("hasNextPage") is not False
                    or not isinstance(checks.get("nodes"), list)
                    or not all(isinstance(check, dict) for check in checks["nodes"])):
                continue
            self.known[(node["id"], name)] = frozenset(str(check.get("conclusion") or "").lower()
                                                       for check in checks["nodes"])


def suite_id(run: dict) -> str | None:
    suite = run.get("check_suite_node_id")
    return suite if isinstance(suite, str) and NODE_ID.fullmatch(suite) else None


def may_hold(suites: SuiteChecks, runs: list[dict], index: int, name: str, verdict: bool) -> bool:
    """Whether RUNS[INDEX] can hold a job NAME (with a verdict conclusion, when VERDICT): False only when its check
    suite was read and has no such check run in any attempt."""
    found = suites.conclusions(runs, index, name)
    return found is None or bool(found & VERDICTS if verdict else found)


def cancelled_tier_without_verdict(suites: SuiteChecks, runs: list[dict], index: int, name: str) -> bool:
    """Whether RUNS[INDEX] is a cancelled base tier run whose check suite shows no verdict for job NAME: passed over
    before it counts toward a job-list limit (never_carries' note)."""
    return cancelled_base_tier(runs[index]) and not may_hold(suites, runs, index, name, verdict=True)


# A completed base run's job list, kept on disk so the next merge check on the same base reads none of them again.
# Keyed by run, attempt and updated_at: a re-run changes both, so a kept list is the one GitHub would serve.
JOBS_CACHE_ENV = "BASE_RED_EXCUSE_JOBS_CACHE"  # a directory, or "off"
JOBS_CACHE_SECONDS = 6 * 3600


def jobs_cache() -> Path | None:
    named = os.environ.get(JOBS_CACHE_ENV)
    if named == "off":
        return None
    if named:
        return Path(named)
    return Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "base-red-excuse" / "jobs"


def base_run_jobs(repo: str, run: dict, github) -> list[dict]:
    """The jobs of base RUN's newest attempt (jobs?filter=latest), from the disk cache when RUN is completed."""
    where, key = jobs_cache(), None
    if (where is not None and run.get("status") == "completed" and isinstance(run.get("run_attempt"), int)
            and re.fullmatch(r"[0-9TZ:.+-]{10,40}", str(run.get("updated_at") or ""))):
        stamp = re.sub(r"[^0-9]", "", run["updated_at"])
        key = where / f"{repo.replace('/', '--')}-{int(run['id'])}-{run['run_attempt']}-{stamp}.json"
        try:
            kept = json.loads(key.read_text())
            if (isinstance(kept, list) and all(isinstance(job, dict) and job.get("run_id") == run["id"] for job in kept)
                    and time.time() - key.stat().st_mtime < JOBS_CACHE_SECONDS):
                return kept
        except (OSError, ValueError):
            pass
    jobs = [found for page in github.json(f"repos/{repo}/actions/runs/{run['id']}/jobs?filter=latest&per_page=100",
                                          paginate=True)
            for found in page.get("jobs") or []]
    for job in jobs:  # a --jq projection of glaeda's slim list reads a null run_id; the cache check above needs it
        if job.get("run_id") is None:
            job["run_id"] = run["id"]
    if key is not None:
        try:
            key.parent.mkdir(parents=True, exist_ok=True)
            spare = key.with_name(f".{key.name}.{os.getpid()}")
            spare.write_text(json.dumps(jobs))
            os.replace(spare, key)
            for old in key.parent.glob("*.json"):
                if time.time() - old.stat().st_mtime > JOBS_CACHE_SECONDS:
                    old.unlink(missing_ok=True)
        except OSError:
            pass
    return jobs


# A cancelled job with a newer run of its name: the newest completed run of a check name is its verdict, as glaeda-gh
# reads a head ("superseded: ... cancelled (not counted)"). cmux#36965 at 004465b3: run 42179149655's 'risk evidence'
# was cancelled by concurrency while run 42179187468 of the same workflow passed it, and the cancelled one refused the
# merge as a red with no verdict. Only a cancelled (or stale) job is passed over, and only for a newer run of the same
# workflow on the same head: a failure is a verdict and stays red whatever a later run says (merge_hold's
# _superseded_cancels, router-review F1 at 241b0da0).
SUPERSEDABLE = ("cancelled", "stale")
GREEN = ("success", "skipped", "neutral")
ACTIONS_JOB_URL = r"https://github\.com/{repo}/actions/runs/(\d+)/job/(\d+)"


def linked_checks(repo: str, sha: str, name: str, github, seen: dict) -> list[tuple[int, int, dict]]:
    """(Actions job id, run id, check run) of each GitHub Actions check run of NAME on SHA, every attempt, newest job
    first. Recency is the job id each check run links (its details URL), never the check run's own id: one kind of id
    whatever the check run's own is. SEEN keeps the head's check runs for one judge call."""
    if "checks" not in seen:
        listed = github.json(f"repos/{repo}/commits/{sha}/check-runs?filter=all&per_page=100", paginate=True)
        seen["checks"] = [check for page in listed for check in page.get("check_runs") or []
                          if (check.get("app") or {}).get("slug") == "github-actions"]
    url = re.compile(ACTIONS_JOB_URL.format(repo=re.escape(repo)))
    linked = [(int(match[2]), int(match[1]), check) for check in seen["checks"]
              if check.get("name") == name and (match := url.fullmatch(check.get("details_url") or ""))]
    return sorted(linked, key=lambda found: found[0], reverse=True)


def rest_run(repo: str, run: int, github, seen: dict | None = None) -> dict:
    """RUN's REST record. A lane VM's gh chain can answer `actions/runs/ID` with glaeda's 12-field run summary, which
    has the run's head_sha but no workflow_id or path: base_red_excuse then asked `actions/workflows/None/runs` (a 404
    that refused cmux#37033), and a cancelled run superseded by newer greens of its workflow was read as having none
    (cmux#36971 at b265fe8c, risk-tier's 42191711726). Such a record is completed from `actions/runs?head_sha=SHA`,
    one read per head kept in SEEN, which names every run at it. The workflow is only GitHub's workflow_id, never a
    name two workflows can share; a list that does not name the run leaves the summary, whose workflow_id is None."""
    found = github.json(f"repos/{repo}/actions/runs/{run}")
    sha = found.get("head_sha") if isinstance(found, dict) else None
    if not isinstance(found, dict) or "workflow_id" in found or not re.fullmatch(r"[0-9a-f]{40}", str(sha or "")):
        return found
    seen = {} if seen is None else seen
    key = ("runs-at", sha)
    if key not in seen:
        listed = github.json(f"repos/{repo}/actions/runs?head_sha={sha}&per_page=100", paginate=True)
        seen[key] = {listed_run.get("id"): listed_run for page in listed
                     for listed_run in page.get("workflow_runs") or [] if isinstance(listed_run, dict)}
    full = seen[key].get(run)
    return full if isinstance(full, dict) and isinstance(full.get("workflow_id"), int) else found


def run_workflow(repo: str, run: int, github, seen: dict):
    """RUN's workflow id, read once per judge call (SEEN); None when GitHub's answer names none (rest_run)."""
    if run not in seen:
        seen[run] = rest_run(repo, run, github, seen).get("workflow_id")
    return seen[run]


def superseding_check(repo: str, sha: str, job: dict, github, seen: dict) -> dict | None:
    """The newest check run of JOB's name on SHA in a newer run of JOB's workflow, when it has completed with a
    verdict; None when there is none, it is still running, it was cancelled too, or a workflow cannot be read."""
    mine = None
    for job_id, run, check in linked_checks(repo, sha, job.get("name", ""), github, seen):
        if job_id <= job["id"] or run == job["run_id"]:
            continue  # older, or a later attempt of the same run (last_real_jobs reads those)
        mine = run_workflow(repo, job["run_id"], github, seen) if mine is None else mine
        if mine is None or run_workflow(repo, run, github, seen) != mine:
            continue
        # The newest run of this workflow and name decides; it must have finished with a verdict of its own.
        if check.get("status") != "completed" or check.get("conclusion") in SUPERSEDABLE:
            return None
        return {**check, "job_id": job_id}
    return None


def superseded_by_green(repo: str, sha: str, job: dict, github, seen: dict) -> list[dict]:
    """The older red check runs of green JOB's name on SHA when every one is a cancelled (or stale) run of JOB's own
    workflow, so JOB, the newest, supersedes them all; [] when there is none, or any is a failure (a verdict that
    stays red whatever a later run says) or another workflow's or a still-running run's."""
    mine = run_workflow(repo, job["run_id"], github, seen)
    older = [(job_id, run, check) for job_id, run, check in linked_checks(repo, sha, job.get("name", ""), github, seen)
             if job_id < job["id"]]
    reds = [(run, check) for _, run, check in older if check.get("conclusion") not in GREEN]
    if mine is None or not reds:
        return []
    for run, check in reds:
        if (check.get("status") != "completed" or check.get("conclusion") not in SUPERSEDABLE
                or run_workflow(repo, run, github, seen) != mine):
            return []
    return [check for _, check in reds]


def head_jobs(repo: str, sha: str, runs: list[int], checks: list[str], github, *, base: str | None = None,
              excused: list[str] | None = None, suites: SuiteChecks | None = None,
              ignored: list[str] | None = None, seen: dict | None = None) -> list[dict]:
    """Failed head jobs; a check that is a jobless status red the base shares adds its line to EXCUSED, and a cancelled
    job a newer run of its workflow passed adds its line to IGNORED (superseding_check)."""
    jobs: dict[int, dict] = {}
    contexts: dict[int, list[str]] = {}  # the status contexts each job was judged for (status_job)
    seen = {} if seen is None else seen
    for run in runs:
        guards = []
        run_rollups = []
        children = []
        for job in last_real_jobs(repo, run, github):
            if (job.get("status") == "completed" and job.get("conclusion") in SUPERSEDABLE
                    and (newer := superseding_check(repo, sha, job, github, seen)) is not None):
                name = job.get("name", "")
                if newer.get("conclusion") in GREEN:
                    if ignored is not None:
                        ignored.append(f"ignored '{name}': its {job['conclusion']} job in run {run} is superseded by "
                                       f"job {newer['job_id']} of the same workflow, {newer['conclusion']} on {sha}; "
                                       "the newest completed run is the verdict")
                    continue
                # The newer run's red is the verdict: judge that job, not the cancelled one.
                job = job_for(repo, newer, sha, github)
                if is_aggregate(name, repo):
                    if job.get("conclusion") != "failure":
                        raise Refused(f"'{name}': the newest aggregate job is {job.get('conclusion')}, not failure")
                    found = head_jobs(repo, sha, [job["run_id"]], [], github, ignored=ignored, seen=seen)
                    if not found:
                        raise Refused(f"run {job['run_id']}: its aggregate check failed with no failed job to "
                                      "compare with the base")
                    jobs.update((child["id"], child) for child in found)
                    continue
                jobs[job["id"]] = job
                continue
            if is_aggregate(job.get("name", ""), repo):
                if job.get("conclusion") not in ("success", "skipped", "neutral", None):
                    (run_rollups if job.get("name") in rollups(repo)["run"] else guards).append(job)
                continue
            if job.get("status") == "completed" and job.get("conclusion") not in ("success", "skipped", "neutral"):
                if job.get("head_sha") not in (None, sha):
                    raise Refused(f"{job.get('name')}: job is not for the exact SHA {sha}")
                jobs[job["id"]] = job
                children.append(job)
        for guard in guards:
            if not children:
                raise Refused(f"run {run}: its aggregate check failed with no failed job to compare with the base")
            validate_guard_routes(repo, sha, guard, children, github)
        for rollup in run_rollups:
            validate_run_rollup(rollup["name"], children, repo)
    if checks:
        latest = latest_checks(repo, sha, github)
        aggregate_jobs = []
        aggregate_runs = []
        for name in checks:
            if name not in latest:
                if (job := status_job(repo, sha, name, github, base if excused is not None else None, suites)) is None:
                    raise Refused(f"{name}: has not run on exact head {sha}")
                if isinstance(job, str):
                    excused.append(job)
                    continue
                jobs[job["id"]] = job
                contexts.setdefault(job["id"], []).append(name)
                continue
            job = job_for(repo, latest[name], sha, github)
            if is_aggregate(name, repo):
                # The check-run can remain failed while its Actions job has
                # been retried or replaced.  Never discard this exact job and
                # rescan the run: a green/missing aggregate must not allow its
                # child failures to be excused (a run rollup like ci-status too).
                if job.get("conclusion") != "failure":
                    raise Refused(f"'{name}': exact aggregate job is {job.get('conclusion')}, not failure")
                if name in rollups(repo)["run"]:
                    aggregate_runs.append((name, job["run_id"]))
                    continue
                aggregate_jobs.append(job)
            else:
                if job.get("conclusion") in GREEN and (cancelled := superseded_by_green(repo, sha, job, github, seen)):
                    # The newest run of the name passed; the reds GitHub still lists for it are cancelled runs of
                    # its workflow that it superseded (cmux#36965's 'risk evidence').
                    if ignored is not None:
                        ignored.append(f"ignored '{name}': its newest job {job['id']} on {sha} is "
                                       f"{job['conclusion']}, superseding {len(cancelled)} cancelled run(s) of the "
                                       "same workflow; the newest completed run is the verdict")
                    continue
                if (job.get("conclusion") in SUPERSEDABLE
                        and (newer := superseding_check(repo, sha, job, github, seen)) is not None):
                    # GitHub's latest is by check run id; a newer job of the name decides (linked_checks).
                    if newer.get("conclusion") in GREEN:
                        if ignored is not None:
                            ignored.append(f"ignored '{name}': its {job['conclusion']} job {job['id']} is superseded "
                                           f"by job {newer['job_id']} of the same workflow, {newer['conclusion']} on "
                                           f"{sha}; the newest completed run is the verdict")
                        continue
                    job = job_for(repo, newer, sha, github)
                jobs[job["id"]] = job
        for name, run in aggregate_runs:
            found = head_jobs(repo, sha, [run], [], github, ignored=ignored, seen=seen)
            if not found:
                raise Refused(f"run {run}: its aggregate check failed with no failed job to compare with the base")
            validate_run_rollup(name, found, repo)
            jobs.update((job["id"], job) for job in found)
        for guard in aggregate_jobs:
            found = head_jobs(repo, sha, [guard["run_id"]], [], github, ignored=ignored, seen=seen)
            if not found:
                raise Refused(f"run {guard['run_id']}: its aggregate check failed with no failed job to compare with the base")
            validate_guard_routes(repo, sha, guard, found, github)
            jobs.update((job["id"], job) for job in found)
    # Kept apart until here, so a later entry for the same job (another status, or its check run) drops none.
    return [dict(job, status_contexts=contexts[key]) if key in contexts else job for key, job in jobs.items()]


def tip_suite_verdicts(repo: str, base: str, workflow, name: str, github, base_jobs: dict[int, list[dict] | None],
                       suites: SuiteChecks | None = None):
    """(run, job) for each completed suite run of BASE with a verdict for job NAME, newest first, read lazily."""
    # Every status, so a first run's same-tree run is seen while it still queues or runs (TREE_JOBS).
    listed = github.json(f"repos/{repo}/actions/workflows/{workflow}/runs?branch={base}&event=workflow_dispatch"
                         f"&per_page={BASE_RUNS_PAGE}")
    runs = listed.get("workflow_runs") or []
    deferred = deferred_first_runs(runs) if name in TREE_JOBS else set()
    suites = suites or SuiteChecks(github)
    candidates = [run for index, run in enumerate(runs)
                  if run.get("status") == "completed" and run.get("conclusion") != "skipped"
                  and not never_carries(run, name) and run["id"] not in deferred
                  and not cancelled_tier_without_verdict(suites, runs, index, name)]
    candidates = candidates[:TIP_SUITE_JOB_READS]
    for index, run in enumerate(candidates):
        if base_jobs.get(run["id"]) is None:
            if not may_hold(suites, candidates, index, name, verdict=True):
                continue
            base_jobs[run["id"]] = base_run_jobs(repo, run, github)
        found = next((found for found in base_jobs[run["id"]] if found.get("name") == name), None)
        if found is not None and found.get("conclusion") in VERDICTS and not refused_at_setup(found):
            yield run, found


def base_verdicts(repo: str, base: str, workflow, name: str, github, base_runs: dict, base_jobs: dict,
                  job_reads: dict, suites: SuiteChecks | None = None):
    """(run, job) for each completed BASE run with a verdict for job NAME, newest first, read lazily: the window of
    BASE_RUNS_PAGE runs (at most BASE_JOB_READS job lists per workflow), then, for a SUITE_JOBS job, the base's
    dispatches (tip_suite_verdicts). A base push run's Mac job is often cancelled by the next push, or refused by a
    mini, so a run with no verdict for the job is passed over. BASE_JOBS[run] is None for a run counted toward
    BASE_JOB_READS whose job list was not read, since its check suite showed no verdict for a job read so far."""
    seen: set[int] = set()
    suites = suites or SuiteChecks(github)
    runs = base_runs[workflow]
    for index, candidate_run in enumerate(runs):
        if never_carries(candidate_run, name) or cancelled_tier_without_verdict(suites, runs, index, name):
            continue
        if candidate_run["id"] not in base_jobs:
            if job_reads.get(workflow, 0) >= BASE_JOB_READS:
                break
            job_reads[workflow] = job_reads.get(workflow, 0) + 1
            base_jobs[candidate_run["id"]] = None
        if base_jobs[candidate_run["id"]] is None:
            if not may_hold(suites, runs, index, name, verdict=True):
                continue
            base_jobs[candidate_run["id"]] = base_run_jobs(repo, candidate_run, github)
        found = next((found for found in base_jobs[candidate_run["id"]] if found.get("name") == name), None)
        if found is not None and found.get("conclusion") in VERDICTS and not refused_at_setup(found):
            seen.add(candidate_run["id"])
            yield candidate_run, found
    if name in SUITE_JOBS:
        for run, found in tip_suite_verdicts(repo, base, workflow, name, github, base_jobs, suites):
            if run["id"] not in seen:
                seen.add(run["id"])
                yield run, found


# A stale base pass (2026-11-02): base_red_excuse.py read only completed base runs, and a base run completes when its
# slowest job does. Between 09:13Z and 09:23Z every feat-cmux-next run from #31930 on was still running, so the newest
# completed run was 41418052327 at c47a99fcb9, before #31930 and before cmux#31338's merge-base e3c495d3 (#31931). Its
# 'cmux-next guards / defaults-snapshot' passed, and the real base red #31930 caused there was refused as the PR's own.
# So the base window lists runs of every status, and a finished job in a running run is a verdict. And a pass that
# tested a commit before the PR's merge-base says nothing about the base the PR was built on: a red then waits for a
# newer verdict (before_merge_base) instead of being called the PR's own.


def before_merge_base(repo: str, base: str, sha: str, base_run: dict, github, cache: dict[str, str]) -> str | None:
    """Why BASE_RUN tested a commit older than the merge-base of SHA with BASE, or None when it did not (or that
    cannot be told). CACHE holds the merge-base, read once per judge."""
    if sha not in cache:
        diff = github.json(f"repos/{repo}/compare/{base}...{sha}?per_page=1")
        cache[sha] = ((diff.get("merge_base_commit") or {}).get("sha")) or ""
    merge_base, tested = cache[sha], tested_sha(base_run)
    if not re.fullmatch(r"[0-9a-f]{40}", merge_base) or not re.fullmatch(r"[0-9a-f]{40}", tested):
        return None
    if tested == merge_base:
        return None
    status = github.json(f"repos/{repo}/compare/{merge_base}...{tested}?per_page=1").get("status")
    if status in ("ahead", "identical"):
        return None
    return f"tested {tested[:12]}, which is {status or 'not after'} the merge-base {merge_base[:12]}"


def created(run: dict) -> datetime | None:
    try:
        return datetime.fromisoformat(str(run.get("created_at")).replace("Z", "+00:00"))
    except ValueError:
        return None


# Fixed on the base (2026-10-31): a pull request whose merge-base is older than a base fix keeps the red the fix
# removed. The release-notary and workflow guard tests (tests/*.py, run by unittest or pytest) read the workflows,
# the scripts and the release manifests, not the pull request's product code, so a red one that passes on the newest
# base was the base's at the merge-base: cmux#27584, #27918, #27905 and #27775 were stranded as their own reds by
# test_every_part_of_bun_run_check_runs_in_the_warn_branch and test_cmux_next_follows_the_committed_target_graph.
# A failing test is excused as fixed on the base only when all of these hold:
#   (a) the newest base verdict for its job is a pass, at a commit strictly after the pull request's merge-base;
#   (b) it is a tests/*.py guard test whose file the log names (a pytest id, or the unittest traceback's own frame),
#       every failed step of the job is such a test's (or the job's own `red check:` rollup of them), and the pull
#       request's diff from its merge-base touches neither that file nor any path the test reads. Only a test whose
#       file is declared in GUARD_READS qualifies (GUARD_READS_DEFAULT plus its own product paths): an undeclared
#       test may read anything (tests/test_docs_deploy_auth_guard.py reads web/), so it is refused, never guessed;
#   (c) the run is whole: a crash or a cut-short run never counts (refused before this is asked).
# Only a declared guard job (GUARD_JOBS) qualifies, and each failing test must be one its failed step's own script
# runs (the step's echo names the test file) with a whole test-run summary printed: a Swift, cargo or webview job, or
# product code printing a `FAILED tests/x.py::...` line, is never fixed on the base, unless it is a package job whose
# inputs are declared (PACKAGE_JOBS, below).
TOP_LEVEL = "top-level files"  # every path with no directory: package.json, .gitmodules, the entitlements, ...
RELEASE_MANIFESTS = (TOP_LEVEL, "release-notes/", "homebrew-cmux/", "cmux.xcodeproj/", "Resources/", "ghostty-next",
                     "vendor/")
GUARD_READS_DEFAULT = (".github/", "scripts/", "tests/") + RELEASE_MANIFESTS
# The guard tests that can be fixed on the base, by file, with the product paths each reads beyond the default. A
# test is declared here only after its reads are checked; any other test's red is refused.
GUARD_READS = {
    # cmux_next_route and the warn-branch check read the CmuxNext target graph, webviews/package.json and the
    # cmux-tui and Native Cargo manifests.
    "tests/test_cmux_next_checks_workflow.py": ("Packages/", "webviews/", "cmux-tui/", "Native/"),
    # focused_tests.plan reads the tree: Swift imports, the CmuxNext target graph, the webviews import graph, Cargo.
    "tests/test_car_guards.py": ("Packages/", "webviews/", "cmux-tui/", "Native/"),
}
# The jobs that run the declared guard tests: cmux-next.yml's checks job, and ci-guards.yml's release-notary group
# (its check is '<caller> / workflow-guard-tests / release-notary').
GUARD_JOBS = frozenset({"cmux-next checks (god files, concurrency, crash safety, l10n)"})
GUARD_JOB_SUFFIXES = ("workflow-guard-tests / release-notary",)
GUARD_TEST_FILE = re.compile(r"tests/[\w.-]+\.py")
# A finished test run: unittest's `Ran N tests in`, or pytest's closing `==== ... in Ns ====` line.
TEST_RUN_SUMMARY = re.compile(r"^Ran \d+ tests? in [\d.]+s$|^=+ .*\bin [\d.]+s\b.*=+$")
# A traceback frame in a tests/*.py file: `File "/…/tests/test_x.py", line 12, in test_y`.
TRACEBACK_FRAME = re.compile(r'^\s*File "(?:[^"]*/)?(tests/[\w.-]+\.py)", line \d+, in (\w+)$')
# The cmux-next checks job's last step (`Fail on any red check`) names each red step it rolls up.
ROLLUP_RED = re.compile(r"^##\[error\]red check: \S")
# A compare lists at most 300 files: a longer diff cannot be shown to stay out of a test's paths.
COMPARE_FILES_CAP = 300


# Fixed on the base for a package's own test job (2026-11-07). cmux#36988 (policy.json, pane methods and the web
# Context screen, d286aa2f) failed CmuxMobileKit's silentDropDetectionBenchmark, a wall-clock bound a loaded runner
# missed with no CmuxMobileKit change in the PR; once the base fixed the test (#37535), a PR branched before the fix
# kept that red as its own. A package job is the test run of one Swift package and the Rust it links, so a PR that
# changes none of its inputs cannot have caused a red that passes on the newest base after its merge-base: (a) and
# (c) above hold as for a guard test, and instead of (b) every failed step is one of the job's test steps, naming at
# least one failing test, and the PR's diff touches none of the job's declared reads nor GUARD_READS_DEFAULT. The
# reads are declared, never guessed: the package directories, the Rust crates its FFI builds and the files their
# sources include_str! (cmux-rd-ffi's tests read schemas/remote-tab/) and the repository files its Swift names by path
# (its tests read cmux-tui/spec/ and schemas/deeplinks/ at run time), checked against the tree by
# tests/test_base_red_excuse.py. At the head they are checked again: every Swift package Package.swift reaches by
# path and every Rust crate the Cargo manifests reach by path (cargo_crates, which must cover every path crate in the
# Cargo.lock) must lie in them, and every failed step must name its own failing test, else the red is refused (a new dependency the
# declaration has not caught up with reads paths this rule cannot see).
PACKAGE_JOBS = {
    "CmuxMobileKit tests (macOS swift test, iOS simulator)": {
        "steps": ("swift test (macOS)", "xcodebuild test (iOS simulator)"),
        "swift": ("cmux-next-ios/CmuxMobileKit",),
        "cargo_lock": "cmux-next-ios/rust/Cargo.lock",
        "reads": ("cmux-next-ios/CmuxMobileKit/", "cmux-next-ios/rust/", "cmux-next-ios/.cargo/", ".cargo/",
                  "Packages/Shared/", "Packages/iOS/", "cmux-tui/Cargo.toml", "cmux-tui/Cargo.lock",
                  "cmux-tui/rust-toolchain.toml", "cmux-tui/rust-toolchain", "cmux-tui/.cargo/",
                  "cmux-tui/crates/cmux-rd-core/", "cmux-tui/crates/cmux-rd-engine/", "cmux-tui/crates/cmux-rd-ffi/",
                  # cmux-wg's remote_stream_bench example dev-depends on cmux-rd-link
                  "cmux-tui/crates/cmux-rd-link/",
                  "cmux-tui/crates/cmux-rd-proto/", "cmux-tui/crates/cmux-remote-browser/",
                  "cmux-tui/crates/cmux-terminal-prediction/",
                  "cmux-tui/crates/cmux-transport/", "cmux-tui/crates/cmux-wg/", "schemas/remote-tab/",
                  # cmux-wg's smoltcp is the vendored copy ([patch.crates-io] in cmux-next-ios/rust)
                  "cmux-tui/vendor/smoltcp/",
                  # cmux-mobile-host's tests read the Mac's lane policy to keep the two in step
                  "Packages/macOS/CmuxNext/Sources/CmuxNextMobile/DaemonLane/DaemonLanePolicy.swift",
                  # the kit's Swift tests read the shared specs from the repository root at run time
                  "cmux-tui/spec/full-access-modes.json", "schemas/deeplinks/agent-link.json"),
    },
}
SWIFT_PATH_PACKAGE = re.compile(r'\.package\s*\(\s*(?:name:\s*"[^"]*"\s*,\s*)?path:\s*"([^"]+)"')
SWIFT_URL_PACKAGE = re.compile(r'\.package\s*\(\s*(?:name:\s*"[^"]*"\s*,\s*)?(?:url|id):\s*"')
SWIFT_PACKAGE_TOKEN = re.compile(r"\.package\b")


def swift_without_comments(text: str) -> str | None:
    """TEXT with its Swift comments (`//` to the line end, `/* */` nested as Swift nests them) blanked, plain string
    literals kept whole (a url's `//` is not a comment); None when it has a raw (`#"`), multiline or interpolated
    (`\\(`) literal, which this reader does not parse: an interpolation's own quotes would end the literal early."""
    out, i, n = [], 0, len(text)
    while i < n:
        if text.startswith('"""', i) or text.startswith('#"', i):
            return None
        if text[i] == '"':
            j = i + 1
            while j < n and text[j] not in '"\n':
                if text.startswith("\\(", j):
                    return None
                j += 2 if text[j] == "\\" else 1
            out.append(text[i:j + 1])
            i = j + 1
        elif text.startswith("//", i):
            j = text.find("\n", i)
            i = n if j < 0 else j
            out.append(" ")
        elif text.startswith("/*", i):
            depth, j = 1, i + 2
            while j < n and depth:
                if text.startswith("/*", j):
                    depth, j = depth + 1, j + 2
                elif text.startswith("*/", j):
                    depth, j = depth - 1, j + 2
                else:
                    j += 1
            out.append(" ")
            i = j
        else:
            out.append(text[i])
            i += 1
    return "".join(out)


CARGO_DEPENDENCY_TABLES = ("dependencies", "dev-dependencies", "build-dependencies")
CARGO_MANIFESTS = 200  # a bound on the manifests one resolution reads


def cargo_crates(repo: str, sha: str, lock: str, github) -> dict[str, str]:
    """{directory: its crate's name} of every path crate the Cargo workspace beside LOCK builds at SHA: its members,
    then each path dependency (a `path`, or `workspace = true` resolved in the crate's own workspace root, the nearest
    ancestor manifest with a [workspace]), read from the manifests at SHA, never from a declaration. Raises Refused
    when a manifest cannot be read or parsed, a member is a glob, or a path crate in LOCK resolves to no directory."""
    import posixpath
    import tomllib
    manifests: dict[str, dict | None] = {}

    def manifest(where: str, required: bool) -> dict | None:
        if where not in manifests:
            if len(manifests) >= CARGO_MANIFESTS:
                raise Refused(f"resolving {lock}'s crates read more than {CARGO_MANIFESTS} manifests")
            path = f"{where}/Cargo.toml" if where else "Cargo.toml"
            try:
                text = source_text(repo, sha, path, github)
            except Refused as why:
                if required:
                    raise Refused(f"{path} could not be read at {sha[:12]}: {why}") from None
                text = None
            try:
                manifests[where] = None if text is None else tomllib.loads(text)
            except tomllib.TOMLDecodeError as why:
                raise Refused(f"{path} could not be parsed at {sha[:12]}: {why}") from None
        return manifests[where]

    def workspace_of(where: str) -> tuple[str, dict]:
        at = where
        while True:
            found = manifest(at, at == where)
            if found is not None and isinstance(found.get("workspace"), dict):
                return at, found["workspace"]
            if not at:
                return where, {}
            at = posixpath.dirname(at)

    root = posixpath.dirname(lock)
    top = (manifest(root, True) or {}).get("workspace")
    if not isinstance(top, dict):
        raise Refused(f"{root}/Cargo.toml has no [workspace]")
    members = top.get("members") or []
    if any(not isinstance(member, str) or any(c in member for c in "*?[") for member in members):
        raise Refused(f"{root}/Cargo.toml names its members by a glob")
    queue = [posixpath.normpath(posixpath.join(root, member)) for member in members] + [root]
    crates: dict[str, str] = {}  # by directory: two path crates may share a name (an aliased dependency)
    seen: set[str] = set()
    while queue:
        where = queue.pop()
        if where in seen:
            continue
        seen.add(where)
        if where.startswith(".."):
            raise Refused(f"a path crate of {lock} is outside the repository ({where})")
        found = manifest(where, True) or {}
        package = found.get("package")
        if isinstance(package, dict) and isinstance(package.get("name"), str):
            crates[where] = package["name"]
        home, workspace = workspace_of(where)
        shared = workspace.get("dependencies") if isinstance(workspace.get("dependencies"), dict) else {}
        tables = [found.get(name) for name in CARGO_DEPENDENCY_TABLES]
        targets = found.get("target") if isinstance(found.get("target"), dict) else {}
        tables += [target.get(name) for target in targets.values() if isinstance(target, dict)
                   for name in CARGO_DEPENDENCY_TABLES]
        tables += [patch for patch in (found.get("patch") or {}).values() if isinstance(patch, dict)]
        tables += [shared] if where == home else []
        for table in tables:
            for name, spec in (table or {}).items() if isinstance(table, dict) else ():
                if not isinstance(spec, dict):
                    continue
                if isinstance(spec.get("path"), str):
                    base = home if table is shared else where
                    queue.append(posixpath.normpath(posixpath.join(base, spec["path"])))
                elif spec.get("workspace") and isinstance(shared.get(name), dict) \
                        and isinstance(shared[name].get("path"), str):
                    queue.append(posixpath.normpath(posixpath.join(home, shared[name]["path"])))
    try:
        locked = tomllib.loads(source_text(repo, sha, lock, github)).get("package", [])
    except (Refused, tomllib.TOMLDecodeError) as why:
        raise Refused(f"{lock} could not be read at {sha[:12]}: {why}") from None
    if missing := sorted({str(crate.get("name")) for crate in locked if isinstance(crate, dict)
                          and "source" not in crate} - set(crates.values())):
        raise Refused(f"{lock} has path crates its manifests do not reach: {', '.join(missing)}")
    return crates


def package_reads(repo: str, sha: str, package: dict, github) -> tuple[str, ...]:
    """PACKAGE's declared reads, once its Swift path packages and Cargo.lock path crates at SHA are shown to lie in
    them; raises Refused naming the first that does not."""
    import posixpath
    reads = package["reads"]
    seen: set[str] = set()
    queue = list(package["swift"])
    while queue:
        where = queue.pop()
        if where in seen:
            continue
        seen.add(where)
        if not any(touches(where + "/Package.swift", read) for read in reads + GUARD_READS_DEFAULT):
            raise Refused(f"its Swift package {where} is outside its declared reads (PACKAGE_JOBS)")
        try:
            manifest = source_text(repo, sha, f"{where}/Package.swift", github)
        except Refused as why:
            raise Refused(f"{where}/Package.swift could not be read at {sha[:12]}: {why}") from None
        # Read with its comments blanked. Every `.package` token is then a path dependency read below or a url (or
        # registry id) one: any other spelling (a variable path, a raw or multiline literal) could reach a package
        # this rule cannot see, so it refuses.
        code = swift_without_comments(manifest)
        if code is None:
            raise Refused(f"{where}/Package.swift has a raw, multiline or interpolated string literal, which this rule "
                          "does not read")
        known = {found.start() for pattern in (SWIFT_PATH_PACKAGE, SWIFT_URL_PACKAGE) for found in pattern.finditer(code)}
        if unread := [found.start() for found in SWIFT_PACKAGE_TOKEN.finditer(code) if found.start() not in known]:
            line = code.count("\n", 0, unread[0]) + 1
            raise Refused(f"{where}/Package.swift:{line} declares a package dependency in a form this rule does not "
                          "read; it could reach a package outside the declared reads")
        for found in SWIFT_PATH_PACKAGE.finditer(code):
            path = posixpath.normpath(posixpath.join(where, found.group(1)))
            if path.startswith(".."):
                raise Refused(f"{where}/Package.swift reaches {found.group(1)}, outside the repository")
            queue.append(path)
    crates = cargo_crates(repo, sha, package["cargo_lock"], github)
    for where, crate in sorted(crates.items()):
        if not any(touches(where + "/Cargo.toml", read) for read in reads + GUARD_READS_DEFAULT):
            raise Refused(f"its Rust crate {crate} at {where} is outside its declared reads (PACKAGE_JOBS)")
    return reads


def package_tests(package: dict, job: dict, head_log: str) -> list[str]:
    """The failing tests of a PACKAGE_JOBS job, whose every failed step is one of its test steps and names a failing
    test of its own (one step's test failure never covers another's compile error); raises Refused."""
    steps, _, _ = signature(job, head_log)
    if other := sorted(steps - set(package["steps"])):
        raise Refused(f"its failed step {other[0]!r} is not one of the job's test steps")
    if not steps:
        raise Refused("no failing test in its test steps")
    placed = step_lines(job, head_log)
    if placed is None:
        raise Refused("its log's lines cannot each be told to one step by the log's step order (step_owners)")
    tests: set[str] = set()
    for step, lines in placed:
        if not step_failed(step):
            continue
        found = test_reds.read("\n".join(lines)).failed
        if not found:
            said = step.get("name")  # step-name: display
            raise Refused(f"its failed step {said!r} names no failing test of its own")
        tests |= found
    return sorted(tests)


def guard_job(name: str) -> bool:
    return name in GUARD_JOBS or any(name == end or name.endswith(" / " + end) for end in GUARD_JOB_SUFFIXES)


def guard_test_file(name: str, output: list[str]) -> str | None:
    """The tests/*.py file failing test NAME is in, from its pytest id or its own unittest traceback frame in OUTPUT
    (the failed step's printed lines); None when it is no such test or the log does not name one file for it."""
    if "::" in name:
        path = name.split("::", 1)[0]
        return path if GUARD_TEST_FILE.fullmatch(path) else None
    method = name.split(" ", 1)[0]
    frames = {m.group(1) for text in output for m in [TRACEBACK_FRAME.match(text)] if m and m.group(2) == method}
    return frames.pop() if len(frames) == 1 else None


def guard_tests(log: str) -> dict[str, str]:
    """{failing test: its tests/*.py file} for a job whose every failed step is a guard test's; raises Refused naming
    the first step or test that is not."""
    lines = test_reds.log_lines(log)
    skip = test_reds.echoed(lines)
    starts = [n for n in sorted(skip) if test_reds.ECHO_START.match(lines[n])]
    found: dict[str, str] = {}
    tested_steps = rolled_up = 0
    for start, end in zip([0] + starts, starts + [len(lines)]):
        output = [lines[n] for n in range(start, end) if n not in skip]
        script = [lines[n] for n in range(start, end) if n in skip]
        errors = [text for text in output if test_reds.STEP_ERROR.match(text)]
        if not errors:
            continue
        rollup = [text for text in errors if ROLLUP_RED.match(text)]
        if rollup and all(ROLLUP_RED.match(text) or test_reds.PROCESS_EXIT.match(text) for text in errors):
            rolled_up += len(rollup)
            continue
        names = test_reds.failed_names(output)
        if not names:
            raise Refused(f"a failed step names no failing test ({errors[0][:200]})")
        if not any(TEST_RUN_SUMMARY.match(text) for text in output):
            raise Refused(f"the failed step naming {sorted(names)[0]} printed no test-run summary")
        for name in sorted(names):
            path = guard_test_file(name, output)
            if path is None:
                raise Refused(f"{name} is not a tests/*.py guard test whose file its log names")
            if not any(path in text for text in script):
                raise Refused(f"{name}: its failed step's script does not run {path}")
            found[name] = path
        tested_steps += 1
    if not found:
        raise Refused("no failing guard test")
    if rolled_up > tested_steps:
        raise Refused(f"its rollup names {rolled_up} red checks and only {tested_steps} failed with a guard test")
    return found


def touches(path: str, read: str) -> bool:
    if read == TOP_LEVEL:
        return "/" not in path
    return path.startswith(read) if read.endswith("/") else path == read or path.startswith(read + "/")


# The pull request a fixed-on-base red may be excused for (2026-11-08, cmuxterm-hq#7948): next-autoland lands a head
# with a base red since fixed, with no base merge, only when (1) an independent SHIP names that exact head, (2) it is
# not risk:high, (3) GitHub does not call it conflicting, (4) the job was red at the PR's merge-base and (5) passes on
# the newest base after it, and (6) none of the PR's files feeds the check. (5) and (6) are the rule above; this adds
# (1)-(4), so a lane's own land and autoland's agree. Any one missing keeps the red: the head takes a base merge and a
# run on the combined tree. The receipt grammar is risk_tier.py's (its one copy, as defaults_guard reads it). A merged
# pull request (merge_audit) has no conflict to read.
SCRIPT_DIR = Path(__file__).resolve().parent
FIXED_ON_BASE_RISK = "risk:high"


def receipt_grammar():
    if str(SCRIPT_DIR) not in sys.path:
        sys.path.insert(0, str(SCRIPT_DIR))
    import risk_tier
    return risk_tier


def fixed_on_base_pull(repo: str, base: str, sha: str, name: str, merge_base: str, github) -> str:
    """The pull request whose head is SHA, when (1)-(4) above hold for the red job NAME; raises Refused otherwise."""
    pulls = [p for p in github.json(f"repos/{repo}/commits/{sha}/pulls?per_page=100") or []
             if isinstance(p, dict) and (p.get("head") or {}).get("sha") == sha
             and (p.get("base") or {}).get("ref") == base]
    if len(pulls) != 1:
        raise Refused(f"no single pull request into {base} has {sha[:12]} as its head ({len(pulls)} found)")
    number = pulls[0].get("number")
    pull = github.json(f"repos/{repo}/pulls/{number}")
    labels = {str((label or {}).get("name") or "").lower() for label in pull.get("labels") or []}
    if FIXED_ON_BASE_RISK in labels:
        raise Refused(f"#{number} is {FIXED_ON_BASE_RISK}: it keeps its base merge and a run on the combined tree")
    if pull.get("state") == "open" and (pull.get("mergeable") is False
                                         or str(pull.get("mergeable_state") or "").lower() == "dirty"):
        raise Refused(f"GitHub calls #{number} conflicting")
    # A paginated read is its list of pages ([[comment, ...], ...]); signed_off reads the items.
    comments = [item for page in github.json(f"repos/{repo}/issues/{number}/comments", paginate=True) or []
                for item in _evidence.gh_pages.page_items(page)]
    reviews = [item for page in github.json(f"repos/{repo}/pulls/{number}/reviews", paginate=True) or []
               for item in _evidence.gh_pages.page_items(page)]
    author = (pull.get("user") or {}).get("login") or ""
    if not receipt_grammar().signed_off(comments, reviews, sha, author, pull):
        raise Refused(f"#{number} has no independent SHIP at its exact head {sha[:12]}")
    runs = github.json(f"repos/{repo}/commits/{merge_base}/check-runs?check_name={urllib.parse.quote(name, safe='')}&filter=latest&per_page=100")
    seen = [run for run in (runs or {}).get("check_runs") or [] if isinstance(run, dict) and run.get("name") == name]
    if not any(run.get("status") == "completed" and run.get("conclusion") in ("failure", "timed_out") for run in seen):
        raise Refused(f"'{name}' has no red verdict at the merge-base {merge_base[:12]} "
                      f"({', '.join(sorted({str(r.get('conclusion') or r.get('status')) for r in seen})) or 'none'}): "
                      "the base red that would excuse it is not shown there")
    return f"#{number}, SHIP at {sha[:12]}, red at the merge-base {merge_base[:12]}"


def fixed_on_base(repo: str, base: str, sha: str, name: str, head_log: str, base_run: dict, github,
                  job: dict | None = None) -> str:
    """The audit line for a red job whose every failing test is fixed on the base (the rule above); raises Refused
    with the reason it is not. BASE_RUN is the newest base run with a verdict for the job, and that verdict passed."""
    package = PACKAGE_JOBS.get(name)
    if not guard_job(name) and package is None:
        raise Refused(f"'{name}' is not a declared guard job (GUARD_JOBS) or package job (PACKAGE_JOBS); its tests "
                      "may read product code")
    tests = guard_tests(head_log) if package is None else dict.fromkeys(package_tests(package, job or {}, head_log))
    tested = tested_sha(base_run)
    if not re.fullmatch(r"[0-9a-f]{40}", tested):
        raise Refused(f"{base} run {base_run['id']} names no commit it tested")
    diff = github.json(f"repos/{repo}/compare/{base}...{sha}")
    merge_base = ((diff.get("merge_base_commit") or {}).get("sha")) or ""
    files = diff.get("files")
    if not re.fullmatch(r"[0-9a-f]{40}", merge_base) or not isinstance(files, list):
        raise Refused(f"no merge-base and diff for {sha} against {base}")
    if len(files) >= COMPARE_FILES_CAP:
        raise Refused(f"the diff from its merge-base lists {len(files)} files, too many to show it stays out of "
                      "the tests' paths")
    after = github.json(f"repos/{repo}/compare/{merge_base}...{tested}?per_page=1")
    if after.get("status") != "ahead":
        raise Refused(f"the passing {base} run {base_run['id']} tested {tested[:12]}, which is not after the merge-base "
                      f"{merge_base[:12]} ({after.get('status')})")
    changed = sorted({path for found in files for path in (found.get("filename"), found.get("previous_filename"))
                      if isinstance(path, str) and path})
    if package is not None:
        tests = dict.fromkeys(tests, package_reads(repo, sha, package, github))
    elif undeclared := sorted({path for path in tests.values() if path not in GUARD_READS}):
        raise Refused(f"{', '.join(undeclared)} declares no read paths (GUARD_READS), so a pass on the base proves "
                      "nothing about this PR")
    reads: list[str] = []
    for test, path in sorted(tests.items()):
        test_reads = (path + GUARD_READS_DEFAULT if package is not None
                      else (path,) + GUARD_READS_DEFAULT + GUARD_READS.get(path, ()))
        if hit := [changed_path for changed_path in changed if any(touches(changed_path, r) for r in test_reads)]:
            raise Refused(f"{test} reads paths the PR changes: {'; '.join(hit[:5])}")
        reads.extend(r for r in test_reads if r not in reads)
    pull = fixed_on_base_pull(repo, base, sha, name, merge_base, github)
    url = base_run.get("html_url") or f"https://github.com/{repo}/actions/runs/{base_run['id']}"
    return (f"excused '{name}': fixed on base (passes at {tested[:12]} in {base} run {base_run['id']}, after the "
            f"merge-base {merge_base[:12]}; PR does not touch {', '.join(reads)}; {pull}) ({url}): "
            f"{'; '.join(sorted(tests))[:400]}")


# cmux-next-guards.yml's "cmux-next CI guard group" runs every routed guard step of ci-guards.yml (the workflow guard
# profile) on the change and again on its base, and fails only on a step red on the change and not on that base
# (scripts/ci/guards_new_reds.py). Its log names each red step on one plain line, `guard red step (KIND): STEP`: `new`
# (red on this change), `base` (red on the base too), `flaky`, or `tip` (a push judged at its tip). A pull request's
# red in it is judged per step, the way the job itself reports "N red on the base too": every step the head calls
# `new` must be red at the newest base run of the job, whatever that run's conclusion (a push judged against the
# previous tip lists a red that persists as `base` and stays green). A whole verdict is one with the closing summary
# line; anything else is refused. Before this the job was not a declared guard job (GUARD_JOBS), so a red in it was
# never excused, and the base's own reds in it stayed green on every push (18 steps, until #31366).
GUARD_GROUP_JOB = "cmux-next CI guard group"
GUARD_GROUP_STEP = "Run the ci guard group and the routed groups"
GUARD_RED_STEP = re.compile(r"^guard red step \((new|base|flaky|tip)\): (.+)$")
GUARD_SUMMARY = re.compile(r"^\d+ guard steps red (?:on this change|at the tip)\b")
# run_ci_guards.py's closing line. The red step lines are read only after the last one: a failing step's own output
# (printed above it) may quote them.
GUARD_RUN_DONE = re.compile(r"^cmux guards: \d+ steps passed, \d+ failed\b")


def guard_red_steps(log: str) -> dict[str, set[str]] | None:
    """{kind: red steps} from a guard group job's log, or None when it printed no closing summary (cut short)."""
    lines = test_reds.log_lines(log)
    skip = test_reds.echoed(lines)
    found: dict[str, set[str]] = {"new": set(), "base": set(), "flaky": set(), "tip": set()}
    done = whole = False
    for n, text in enumerate(lines):
        if n in skip:
            continue
        if GUARD_RUN_DONE.match(text):
            found, done, whole = {kind: set() for kind in found}, True, False
        elif not done:
            continue  # a cut-short run's step output may quote verdict lines; none count before the run finished
        elif match := GUARD_RED_STEP.match(text):
            found[match.group(1)].add(match.group(2).strip())
        elif GUARD_SUMMARY.match(text):
            whole = True
    return found if whole else None


def guard_group(repo: str, base: str, name: str, job: dict, head_log: str, base_run: dict, base_job: dict,
                github) -> str:
    """The audit line for a red guard group job whose every red step is red at the newest base verdict for the job
    (the rule above); raises Refused naming the first step that is not."""
    failed = {step["name"] for step in job.get("steps") or []  # step-name: classify
              if step.get("conclusion") not in (None, "success", "skipped")}
    if failed != {GUARD_GROUP_STEP}:
        raise Refused(f"'{name}': failed steps {sorted(failed)}, not only '{GUARD_GROUP_STEP}'; nothing to compare "
                      "step by step")
    head = guard_red_steps(head_log)
    if head is None:
        raise Refused(f"'{name}': its guard comparison printed no summary (a cut-short run is never a base red)")
    charged = head["new"] | head["tip"]
    if not charged:
        raise Refused(f"'{name}': red, but names no red step of its own; nothing to compare with the base")
    found = guard_red_steps(github.log(repo, base_job))
    url = base_run.get("html_url") or f"https://github.com/{repo}/actions/runs/{base_run['id']}"
    if found is None:
        raise Refused(f"'{name}': {base} run {base_run['id']} names no red steps with a closing summary ({url})")
    red_on_base = set().union(*found.values())
    if missing := sorted(charged - red_on_base):
        raise Refused(f"'{name}': guard steps red on this change and not on {base} run {base_run['id']} ({url}): "
                      f"{'; '.join(missing)[:600]}")
    at = f" at {tested_sha(base_run)[:10]}" if tested_sha(base_run) else ""
    return (f"excused '{name}': every red guard step is red on {base} run {base_run['id']}{at} "
            f"(the newest {base} verdict for it, {base_job.get('conclusion')}) ({url}): {'; '.join(sorted(charged))[:400]}")


class Final(Refused):
    """A refusal no older base verdict can lift: it is judged against the newest verdict alone."""


def compare_window(repo: str, base: str, name: str, head: tuple, head_log: str, window: list,
                   chromium_without_diagnostics: bool, *, flake_state: dict | None = None,
                   workflow: str = "") -> str:
    """The audit line for red job NAME (HEAD: its signature) when each of its failures is on some red base verdict of
    WINDOW (newest first: (run, log, signature)); raises Refused naming the first that is on none, Final when the
    newest verdict's log alone (the Chromium check, a process signal, the panic ratchet) refuses it."""
    base_run, base_log, _ = window[0]
    runs = f"run {base_run['id']}" if len(window) == 1 else "any of runs " + ", ".join(str(w[0]["id"]) for w in window)
    head_steps, head_tests, head_errors = head
    head_crash = crash_signals(head_log)
    base_steps, base_tests, base_errors, on = set(), set(), set(), {}
    for run, _, (steps, tests, errors) in window:
        base_steps, base_tests, base_errors = base_steps | steps, base_tests | tests, base_errors | errors
        for test in tests:
            on.setdefault(test, run["id"])
    if chromium_without_diagnostics and (window[0][2][1] or window[0][2][2] or crash_signals(base_log)):
        raise Final(f"'{name}': no failing test or error line to match; nothing to compare with the base")
    known = test_reds.flaky_failures(head_log, name, workflow, flake_state) if base == "feat-cmux-next" else {}
    base_tests |= known.keys()
    verdict = test_reds.classify_any(head_log, [(f"{base} run {run['id']}", text) for run, text, _ in window], name,
                                   flake_state=flake_state if base == "feat-cmux-next" else None, workflow=workflow)
    if verdict is not None and verdict.own:
        raise Refused(f"'{name}': " + "; ".join(verdict.reasons)[:800])
    # Not a test job (a compile or tool that died on a signal): the base must have died the same way.
    if missing := sorted(head_crash - crash_signals(base_log)):
        raise Final(f"'{name}': the process died on signal {', '.join(missing)}, "
                    f"and {base} run {base_run['id']} did not")
    # The ratchet's error line names the run's packages, not its red: its rows are compared instead (RATCHET_SCOPE).
    ratchet = {error for error in head_errors if RATCHET_SCOPE.match(error)}
    if ratchet:
        try:
            unmatched = ratchet_unmatched(head_log, base_log)
        except Refused as error:
            raise Final(f"'{name}': {error}") from None
        if unmatched:
            raise Final(f"'{name}': panic ratchet failures not on {base} run {base_run['id']}: "
                        f"{'; '.join(unmatched)[:600]}")
        head_errors = head_errors - ratchet
    compared = [("failed steps", head_steps, base_steps), ("failing tests", head_tests, base_tests)]
    # A crash-class rule line is a named failure, but its job also has steps that print only error lines
    # (the concurrency rule): those stay compared unless a real test failed.
    if not any(not test_reds.is_crash_rule_failure(test) for test in head_tests):
        compared.append(("errors", head_errors, base_errors))
    for kind, head, seen in compared:
        if missing := sorted(head - seen):
            raise Refused(f"'{name}': {kind} not on {base} {runs}: {'; '.join(missing)[:600]}")
    rows = [f"{crate}: clippy::{lint} {count} > {where}"
            for (crate, lint, where), count in sorted(ratchet_red(head_log)[0].items())] if ratchet else []
    what = ("; ".join(test if on.get(test) == base_run["id"] else
                      f"{test} ({known[test]})" if test in known else f"{test} (red on run {on[test]})"
                      for test in sorted(head_tests))
            or "; ".join(rows + sorted(head_errors)))
    url = base_run.get("html_url") or f"https://github.com/{repo}/actions/runs/{base_run['id']}"
    # The base verdict is the newest one, not necessarily the base tip's: the base tier runs at most
    # once every 15 minutes, so name the commit and time it is from.
    at = f" at {tested_sha(base_run)[:10]}" if tested_sha(base_run) else ""
    when = f", {base_run['created_at']}" if base_run.get("created_at") else ""
    older = (f" or one of the {len(window) - 1} red {base} verdict(s) before it (runs "
             f"{', '.join(str(w[0]['id']) for w in window[1:])})") if len(window) > 1 else ""
    return (f"excused '{name}': {base} run {base_run['id']}{at} (the newest {base} verdict for it{when}){older} "
            f"fails the same way ({url}): {what[:400]}")


class Infra(Refused):
    """A red that is the infrastructure's (test_reds.lost_runner: the runner was lost), not a verdict: never the
    pull request's own red, never excused, and it needs a re-run, like a cancelled job."""


def infra(name: str, job: dict, why: str) -> Infra:
    return Infra(f"'{name}' is infra, not a verdict (job {job.get('id')}: {why}); it is never this PR's own red "
                 "and needs a re-run, like a cancelled job")


def lost_runner_log(repo: str, name: str, job: dict, github) -> str:
    """JOB's log, after refusing a job that lost its runner (test_reds.lost_runner) as Infra. Its steps decide first, at
    no cost; a log GitHub cannot serve (a lost runner leaves none: BlobNotFound) has its check run's annotations read
    to tell a lost runner from an unreadable verdict, which stays the refusal it was."""
    if why := test_reds.lost_runner(job):
        raise infra(name, job, why)
    try:
        return github.log(repo, job)
    except Refused as error:
        try:
            notes = github.json(f"repos/{repo}/check-runs/{job['id']}/annotations")
        except (Refused, KeyError, ValueError):
            notes = []
        if why := test_reds.lost_runner(job, notes if isinstance(notes, list) else [], str(error)):
            raise infra(name, job, why) from None
        raise


def step_lines(job: dict, head_log: str) -> list[tuple[dict, list[str]]] | None:
    """[(step, the lines of HEAD_LOG it surely printed)] for each step of JOB that ran, by number (step_owners: its
    FAILED or PASSED lines, never an AMBIGUOUS one), or None when no line's step can be told. A failing test named only
    on an AMBIGUOUS line is no step's own, so no caller reads one step's output as another's. Each line is its stamp
    and text (`gh run view --log`'s job and step columns dropped)."""
    owned = step_owners(job, head_log)
    steps = [step for step in job.get("steps") or [] if step.get("conclusion") != "skipped"]
    if all(isinstance(step.get("number"), int) for step in steps):
        steps.sort(key=lambda step: step["number"])
    if all(status == AMBIGUOUS and index is None for _, index, status in owned):
        return None
    found: list[list[str]] = [[] for _ in steps]
    for line, index, status in owned:
        if index is not None and status != AMBIGUOUS:
            parts = line.split("\t", 2)
            found[index].append(parts[2] if len(parts) == 3 and STAMP.match(parts[2]) else line)
    return list(zip(steps, found))


def step_failed(step: dict) -> bool:
    return step.get("conclusion") not in (None, "success", "skipped")


def quarantined_only(job: dict, head_log: str, known: dict) -> bool:
    """A whole test-step red explained entirely by matching quarantines, with no additional failing step/error."""
    found = test_reds.read(head_log)
    steps, _, errors = signature(job, head_log)
    if (not found.failed or found.crashes or found.truncated or found.failed - known.keys()
            or not steps or any(not re.search(r"\btests?\b", step, re.I) for step in steps)):
        return False
    # A generic failed test-named step must not borrow a quarantined test from another step: each failed step's own
    # lines (step_lines, by the log's step order, AMBIGUOUS lines left out) name its quarantined tests.
    placed = step_lines(job, head_log)
    if placed is None:
        return False
    for step, lines in placed:
        if not step_failed(step):
            continue
        result = test_reds.read("\n".join(lines))
        if not result.failed or result.crashes or result.truncated or result.failed - known.keys():
            return False
    normalized = normalise_error
    diagnostics = set()
    for observed in test_reds.observations(head_log):
        if observed["outcome"] != "fail":
            continue
        for line in observed["signature"].splitlines():
            # Bun stores its `error:` headline without that prefix, then its assertion block separated by ` / `.
            headline = line.split(" / ", 1)[0]
            diagnostics.update((normalized(line), normalized(headline), normalized("error: " + headline)))
    return errors <= diagnostics


# teamleaderleo/leo-workspace's `ws-check` (2026-11-05). That repo's Actions are off, so its checks run in
# manaflow-ai/cmuxterm-hq Actions (fast-checks.yml through cmux-ci, or fleet-reconciler-ws-check.yml's per-head check
# job) and come back as one commit status, `ws-check`, whose target_url is that run. The head has no Actions job or
# check run of its own, so every red read "no failed job found on the head to compare with the base" and none could
# be excused. Its verdict is judged here per test, from the run's log: tools/ws_check_run.py prints each step between
# `##[group]STEP` and `ws-check step FAILED: STEP (exit ...)`, then one WS_CHECK_RESULT=<json> line whose `failed`
# lists the red steps. A red step's tests are unittest's `FAIL: ...`/`ERROR: ...` lines (their count must equal its
# FAILED (...) summary, else the step's list is unreadable); a red step with none (a lint) is compared by every line
# it printed, numbers and the runner's checkout root masked, so a new violation is a new line.
# A head red is excused only when each of its failing tests (and its step's own `ws-check: ...` lines) fails on the
# base too, judged the way Actions jobs are: the newest base commit with a ws-check verdict decides (a pass there means
# the base is green: the head's red is its own, or fixed on the base when that pass is after the merge-base); a red one
# is compared first, then older red verdicts, at most BASE_WINDOW within BASE_WINDOW_HOURS, never past a pass. A
# pending, error (ws-check's "no verdict") or missing status is no result: never excused on the head, skipped on the
# base. A failure whose description, run, job or log cannot be read as above is refused, never guessed.
# The PR's merge-base (2026-11-05, LW#3538 at 5e80abcb): main at 187b3ca3 failed `host_budget and lane_place`; #3524
# (209e7eb6) fixed it, and main then went red on another step. The head, branched at 187b3ca3, failed that same step,
# but the window (the newest red verdict, then older ones) never reached 187b3ca3, so a red the PR started from read as
# its own and only merging main could clear it. When the newest base verdict is red, a failure the window does not
# show is also looked up at the merge-base commit's own ws-check verdict (that commit's, never an older commit's):
# red there too is not this PR's red. A green newest verdict still refuses as above: there merging main makes the
# head green. A red one means merging main cannot, which is why only then is the merge-base read. When a base pass
# between the merge-base and the tip ended the window (LW#3538: #3524's pass at 209e7eb6), the failure was fixed on
# the base after the PR branched. It is excused only when the PR changes none of the paths that changed between
# the merge-base and that pass, so the PR cannot have undone the fix; else, or when either diff can't be listed
# whole, it is refused (cmux#36638 F1). A merge-base with no verdict, a pending one or a pass excuses nothing; one
# whose failure cannot be read is refused.
WS_CHECK = "ws-check"
WS_CHECK_REPOS = {"teamleaderleo/leo-workspace": "manaflow-ai/cmuxterm-hq"}  # repo: the repo its runs are in
WS_CHECK_COMMITS = 30  # base commits read for a verdict, newest first (most main commits get none)
WS_CHECK_DESCRIPTION = re.compile(r"(\d+) of (\d+) steps failed: (.*)", re.S)
UNITTEST_RED = re.compile(r"^(?:FAIL|ERROR): (\S.*)$")
UNITTEST_SUMMARY = re.compile(r"^FAILED \(([^)]*)\)$")
# A step that crashed (a signal, a fatal interpreter error) is never compared by its test names: a crash after a
# complete unittest summary would otherwise hide behind a failure the base shares (cmux#36219 F1).
WS_CHECK_CRASH = re.compile(r"Segmentation fault|core dumped|Fatal Python error|\bKilled\b|\bAborted\b|"
                            r"MemoryError|died on signal|unexpected signal")
# tools/ws_check_run.py's step line; since leo-workspace#3746 it also ends with the step's time (", 62.1 s").
WS_CHECK_STEP_EXIT = re.compile(r" \(exit (-?\d+), ran \d+, skipped \d+, gh calls \d+(?:, [\d.]+ s)?\)$")
# The checkout root a ws-check run's paths start with: fast-checks.yml's workspace, or ws-check-heads.yml's clone.
WS_CHECK_ROOT = re.compile(r"(?:/[\w.-]+)*/_work/(?:cmuxterm-hq/cmuxterm-hq|_temp/lw)/")


def ws_check_status(repo: str, sha: str, github) -> dict | None:
    statuses = github.json(f"repos/{repo}/commits/{sha}/status?per_page=100").get("statuses") or []
    # The combined status lists the newest per context.
    return next((found for found in statuses if found.get("context") == WS_CHECK), None)


def ws_check_step(lines: list[str], end: int, step: str) -> dict:
    """{"tests", "lines"} for red STEP, whose closing line is LINES[END]; Refused when its output cannot be read."""
    start = next((n for n in range(end - 1, -1, -1) if lines[n] in (f"##[group]{step}", f"::group::{step}")), None)
    if start is None:
        raise Refused(f"no '##[group]{step}' line before its result")
    section = [text for text in lines[start + 1:end] if text and text not in ("##[endgroup]", "::endgroup::")]
    code = WS_CHECK_STEP_EXIT.search(lines[end])
    if code is None:
        raise Refused(f"'{step}': its result line names no exit code")
    if int(code[1]) < 0 or int(code[1]) > 128:
        raise Refused(f"'{step}' exited {code[1]} (a signal): a crash is never a base red")
    if crashed := next((text for text in section if WS_CHECK_CRASH.search(text)), None):
        raise Refused(f"'{step}' crashed ({crashed[:200]}): a crash is never a base red")
    reds = [match[1] for text in section if (match := UNITTEST_RED.match(text))]
    counted = 0
    for text in section:
        if match := UNITTEST_SUMMARY.match(text):
            for part in match[1].split(","):
                key, _, value = part.strip().partition("=")
                if key in ("failures", "errors", "unexpected successes"):
                    counted += int(value) if value.isdigit() else 0
    if len(reds) != counted:
        raise Refused(f"'{step}' prints {len(reds)} FAIL/ERROR line(s) but its unittest summaries count {counted}; "
                      "its failing tests cannot be listed")

    def norm(text: str) -> str:
        return normalise_error(WS_CHECK_ROOT.sub("", text))

    own = {norm(text) for text in section if text.startswith("ws-check: ")}
    if not reds and not section:
        raise Refused(f"'{step}' failed with no failing test and no output to compare")
    return {"tests": frozenset(reds), "lines": frozenset(own if reds else {norm(text) for text in section})}


def ws_check_verdict(repo: str, sha: str, github) -> tuple[str, dict]:
    """(kind, verdict) of SHA's ws-check status: kind "none" (no result), "pass" or "fail". A fail's verdict has
    "steps" ({step: {"tests", "lines"}}), "url" and "at" (the status time); Refused when a failure cannot be read."""
    status = ws_check_status(repo, sha, github)
    if status is None:
        return "none", {"why": "no ws-check status"}
    state, description = status.get("state"), status.get("description") or ""
    found = {"url": status.get("target_url") or "", "at": status.get("updated_at") or status.get("created_at") or ""}
    if state in ("pending", "error"):
        return "none", dict(found, why=f"ws-check is {state} ({description or 'no description'})")
    if state == "success":
        return "pass", found
    where = f"'{WS_CHECK}' on {sha}"
    if state != "failure":
        raise Refused(f"{where}: an unknown status state {state!r}")
    named = WS_CHECK_DESCRIPTION.fullmatch(description)
    if not named:
        raise Refused(f"{where}: failure \"{description}\" names no failed steps; only 'N of M steps failed: ...' is "
                      "read per test")
    host = WS_CHECK_REPOS[repo]
    link = re.fullmatch(r"https://github\.com/" + re.escape(host) + r"/actions/runs/(\d+)(?:/job/\d+)?/?", found["url"])
    if not link:
        raise Refused(f"{where}: its status links {found['url'] or 'nothing'}, not a {host} Actions run")
    run = github.json(f"repos/{host}/actions/runs/{link[1]}")
    jobs = last_real_jobs(host, int(link[1]), github)
    # fleet-reconciler-ws-check.yml runs one check job per head, named for it; fast-checks.yml runs one, `checks`.
    picked = ([job for job in jobs if sha in (job.get("name") or "")]
              or [job for job in jobs if job.get("name") == "checks"])
    if len(picked) != 1:
        raise Refused(f"{where}: run {link[1]} has {len(picked)} ws-check jobs for it, not one")
    job = picked[0]
    if job.get("status") != "completed" or job.get("conclusion") not in ("success", "failure"):
        # No verdict (startup_failure, cancelled, still running): no result, skipped on the base (cmux#36219 F2).
        return "none", dict(found, why=f"job '{job.get('name')}' in run {link[1]} is {job.get('status')}/"
                                       f"{job.get('conclusion')}: no result to read")
    lines = lines_of(github.log(host, job))
    at = next((n for n in range(len(lines) - 1, -1, -1) if lines[n].startswith("WS_CHECK_RESULT=")), None)
    try:
        result = json.loads(lines[at].split("=", 1)[1]) if at is not None else None
    except ValueError:
        result = None
    failed = result.get("failed") if isinstance(result, dict) else None
    if (not isinstance(failed, list) or not failed or not all(isinstance(step, str) and step for step in failed)
            or result.get("ok") is not False or len(set(failed)) != len(failed)):
        raise Refused(f"{where}: run {link[1]} has no WS_CHECK_RESULT line listing its failed steps")
    if result.get("head") != sha:
        # Through cmux-ci the run tests a snapshot commit of the head: its own receipt must name that snapshot and run.
        receipt = next((text for text in reversed(lines) if text.startswith("FAST_CHECKS_RECEIPT=")), "")
        try:
            receipt = json.loads(receipt.split("=", 1)[1]) if receipt else {}
        except ValueError:
            receipt = {}
        if not (isinstance(receipt, dict) and result.get("head") and receipt.get("source_sha") == result.get("head")
                and str(receipt.get("run_id")) == link[1]
                and re.fullmatch(r"Fast checks " + re.escape(str(result.get("head"))) + r"(?: tests \S+)?",
                                 run.get("display_title") or "")):
            raise Refused(f"{where}: the WS_CHECK_RESULT of run {link[1]} is from another checkout")
    if (int(named[1]), int(named[2])) != (len(failed), result.get("steps")) or not failed[0].startswith(named[3]):
        raise Refused(f"{where}: its status (\"{description}\") does not match run {link[1]}'s WS_CHECK_RESULT")
    steps = {}
    for step in failed:
        end = next((n for n in range(at - 1, -1, -1) if lines[n].startswith(f"ws-check step FAILED: {step} (exit ")),
                   None)
        if end is None:
            raise Refused(f"{where}: run {link[1]} has no 'ws-check step FAILED: {step}' line")
        try:
            steps[step] = ws_check_step(lines, end, step)
        except Refused as error:
            raise Refused(f"{where}: run {link[1]}: {error}") from None
    return "fail", dict(found, steps=steps)


def ws_check_units(steps: dict) -> list[tuple[str, str, str]]:
    """(step, kind, item) for each thing a red must match on the base: each failing test, and each compared line."""
    return [(step, "test", test) for step, red in steps.items() for test in sorted(red["tests"])] + [
        (step, "line", line) for step, red in steps.items() for line in sorted(red["lines"])]


def ws_check_fix_untouched(repo: str, base: str, sha: str, merge_base: str, passed: str, github) -> None:
    """Refused unless the PR (BASE...SHA) changes none of the paths changed from MERGE_BASE to the base pass PASSED,
    when PASSED is after MERGE_BASE (a pass before it ended nothing the merge-base fallback crosses)."""
    fix = github.json(f"repos/{repo}/compare/{merge_base}...{passed}")
    if fix.get("status") == "behind":
        return
    where = f"'{WS_CHECK}': {base} passed at {passed[:12]}, after this PR's merge-base {merge_base[:12]}"
    if fix.get("status") != "ahead":
        raise Refused(f"{where}? GitHub compares them as {fix.get('status')!r}; nothing shows the fix stays intact")
    pr = github.json(f"repos/{repo}/compare/{base}...{sha}")

    def paths(diff: dict, what: str) -> set[str]:
        files = diff.get("files")
        if not isinstance(files, list) or len(files) >= COMPARE_FILES_CAP:
            raise Refused(f"{where}: {what} lists {len(files) if isinstance(files, list) else 'no'} files, too many "
                          "or none to show this PR leaves the fix alone")
        return {path for found in files for path in (found.get("filename"), found.get("previous_filename"))
                if isinstance(path, str) and path}

    if hit := sorted(paths(fix, "the fix") & paths(pr, "this PR")):
        raise Refused(f"{where} (fixed on {base}), and this PR changes what that fix changed: {'; '.join(hit[:5])}; "
                      f"merge {base}")


def ws_check(repo: str, base: str, sha: str, github) -> list[str]:
    """Audit lines excusing SHA's red ws-check status, one per failing test; Refused (with a line per test) else."""
    kind, head = ws_check_verdict(repo, sha, github)
    if kind == "none":
        raise Refused(f"'{WS_CHECK}' has no result on {sha}: {head['why']}; never excused, wait for its verdict")
    if kind == "pass":
        # No failure is exit 0 (NoFailureExitsZero): a merge check may ask about every head, green ones included.
        return [f"'{WS_CHECK}' passed on {sha}: no failure to excuse"]
    units = ws_check_units(head["steps"])
    diff = github.json(f"repos/{repo}/compare/{base}...{sha}?per_page=1")
    merge_base = ((diff.get("merge_base_commit") or {}).get("sha")) or ""
    verdicts = ((commit["sha"], *ws_check_verdict(repo, commit["sha"], github))
                for commit in github.json(f"repos/{repo}/commits?sha={base}&per_page={WS_CHECK_COMMITS}") or []
                if isinstance(commit, dict) and isinstance(commit.get("sha"), str))
    verdicts = (found for found in verdicts if found[1] != "none")
    newest = next(verdicts, None)
    if newest is None:
        raise Refused(f"'{WS_CHECK}': none of the {WS_CHECK_COMMITS} newest {base} commits has a ws-check verdict to "
                      "compare with")
    tip, tip_kind, tip_verdict = newest
    tested = f"{base} {tip[:12]} ({tip_verdict['url'] or 'no run'})"
    if tip_kind == "pass":
        after = (merge_base == tip or (re.fullmatch(r"[0-9a-f]{40}", merge_base) and github.json(
            f"repos/{repo}/compare/{merge_base}...{tip}?per_page=1").get("status") in ("ahead", "identical")))
        why = (f"passes on {tested}, the newest {base} verdict: fixed on {base}; merge {base}" if after else
               f"the newest {base} verdict, a pass at {tested}, is before the merge-base {merge_base[:12]}; "
               f"re-check once a {base} commit at or after it has a ws-check verdict")
        lines = [f"not excused '{WS_CHECK}' test '{step} :: {test}': {why}"
                 for step, red in head["steps"].items() for test in sorted(red["tests"])]
        lines += [f"not excused '{WS_CHECK}' step '{step}' (no test names): {why}"
                  for step, red in head["steps"].items() if not red["tests"]]
        raise Refused(f"'{WS_CHECK}' is green on {base} {tip[:12]}, red on {sha[:12]}\n" + "\n".join(lines))
    window, when = [(tip, tip_verdict)], created({"created_at": tip_verdict["at"]})
    at_merge_base: list[tuple[str, dict]] = []

    def has(verdict: dict, unit) -> bool:
        step, kind, item = unit
        return step in verdict["steps"] and item in verdict["steps"][step]["tests" if kind == "test" else "lines"]

    def on(unit) -> tuple[str, dict] | None:
        return next(((commit, verdict) for commit, verdict in window + at_merge_base if has(verdict, unit)), None)

    def older() -> str:
        return f" or the {len(window) - 1} red {base} verdict(s) before it" if len(window) > 1 else ""

    def mb_note() -> str:
        return f" or at the merge-base {merge_base[:12]}" if at_merge_base else ""

    passed_at = ""  # the base pass that ended the window, if one did
    while any(on(unit) is None for unit in units) and len(window) < BASE_WINDOW:
        before = next(verdicts, None)
        if before is None or before[1] != "fail":
            passed_at = before[0] if before is not None and before[1] == "pass" else ""
            break
        then = created({"created_at": before[2]["at"]})
        if when and then and when - then > timedelta(hours=BASE_WINDOW_HOURS):
            break
        window.append((before[0], before[2]))
    if (any(on(unit) is None for unit in units) and re.fullmatch(r"[0-9a-f]{40}", merge_base)
            and merge_base not in (commit for commit, _ in window)):
        mb_kind, mb_verdict = ws_check_verdict(repo, merge_base, github)
        if mb_kind == "fail":
            if passed_at:
                ws_check_fix_untouched(repo, base, sha, merge_base, passed_at, github)
            at_merge_base.append((merge_base, mb_verdict))
    lines, missing = [], []

    def where(found: tuple[str, dict]) -> str:
        crossed = (f" (fixed on {base} at {passed_at[:12]} after it; this PR changes none of that fix's paths)"
                   if passed_at else "")
        return (f"red at this PR's merge-base {found[0][:12]} too{crossed}, so not this PR's red"
                if at_merge_base and found[0] == at_merge_base[0][0] else f"red on {base} {found[0][:12]} too")
    for step, red in head["steps"].items():
        # One line per failing test; a step with none (a lint) is one line, matched by every line it printed.
        for test in sorted(red["tests"]):
            if (found := on((step, "test", test))) is not None:
                lines.append(f"excused '{WS_CHECK}' test '{step} :: {test}': {where(found)} "
                             f"({found[1]['url'] or 'no run'})")
            else:
                missing.append(f"'{step} :: {test}'")
                lines.append(f"not excused '{WS_CHECK}' test '{step} :: {test}': not red on {tested}{older()}"
                             f"{mb_note()}; this head's own red")
        unmatched = [line for line in sorted(red["lines"]) if on((step, "line", line)) is None]
        label = f"step '{step}'" + (" (its ws-check lines)" if red["tests"] else " (no test names: its output)")
        if unmatched:
            missing.append(f"'{step}' line '{unmatched[0][:200]}'")
            lines.append(f"not excused '{WS_CHECK}' {label}: {len(unmatched)} of {len(red['lines'])} line(s) not on "
                         f"{tested}{older()}{mb_note()}, first '{unmatched[0][:200]}'; this head's own red")
        elif not red["tests"]:
            found = {on((step, "line", line))[0] for line in red["lines"]}
            lines.append(f"excused '{WS_CHECK}' {label}: its {len(red['lines'])} line(s) are red on {base} "
                         f"{', '.join(sorted(commit[:12] for commit in found)) or tip[:12]} too"
                         + (" (the merge-base's included)" if at_merge_base and at_merge_base[0][0] in found else ""))
    if missing:
        raise Refused(f"'{WS_CHECK}': {len(missing)} failure(s) not on {base}: {'; '.join(missing)[:600]}\n"
                      + "\n".join(lines))
    via = (f"; at this PR's merge-base {merge_base[:12]} ({at_merge_base[0][1]['url'] or 'no run'}) for what the "
           "window does not show" if at_merge_base and any(on(unit)[0] == merge_base for unit in units) else "")
    return [f"excused '{WS_CHECK}': every failure on {sha[:12]} is red on {base} too (newest {base} verdict "
            f"{tested}{via})"] + lines


def list_base_runs(repo: str, base: str, workflow, github, base_runs: dict) -> None:
    """BASE_RUNS[WORKFLOW] (a workflow id or file name): its BASE runs, newest first, read once per judge."""
    if workflow in base_runs:
        return
    # Every status: a job's verdict is final once the job completes, so a base run still running its slower jobs
    # already answers for its finished ones (before_merge_base's note).
    listed = github.json(f"repos/{repo}/actions/workflows/{workflow}/runs?branch={base}&per_page={BASE_RUNS_PAGE}")
    # Newest first, whatever order GitHub lists them in; a run in a PR's context (pull_request or
    # pull_request_target) is never the base's.
    base_runs[workflow] = sorted(
        (run for run in (listed.get("workflow_runs") if isinstance(listed, dict) else None) or []
         if isinstance(run, dict) and run.get("event") not in ("pull_request", "pull_request_target")
         and run.get("conclusion") != "skipped"),
        key=lambda run: run.get("created_at") or "", reverse=True)


def base_caller(repo: str, base: str, run: dict, name: str) -> str | None:
    """The workflow file that runs job NAME on pushes to BASE when RUN's own workflow (a pull-request-only caller of
    the same reusable workflow) does not (BASE_WORKFLOW_FOR); None for any other job, base, repo or unread workflow
    path."""
    path = run.get("path") if isinstance(run, dict) else None
    if repo != HOME_REPO or not isinstance(path, str) or not path.startswith(".github/workflows/"):
        return None
    file = path.removeprefix(".github/workflows/").split("@", 1)[0]
    return next((caller for (branch, pr_file, job_id), caller in BASE_WORKFLOW_FOR.items()
                 if branch == base and pr_file == file and name.startswith(f"{job_id} / ")), None)


def base_dispatch(repo: str, base: str, run: dict, runs: list[dict], github, now: datetime | None = None) -> str | None:
    """For RUN's workflow in BASE_DISPATCH: the state of its base dispatch, starting one when none is running and
    none started within BASE_DISPATCH_EVERY (RUNS: its BASE runs, newest first, as list_base_runs read them). None for
    any other workflow, base or repo."""
    path = run.get("path") if isinstance(run, dict) else None
    if repo != HOME_REPO or not isinstance(path, str) or not path.startswith(".github/workflows/"):
        return None
    file = path.removeprefix(".github/workflows/").split("@", 1)[0]
    if (base, file) not in BASE_DISPATCH:
        return None
    dispatched = [found for found in runs if found.get("event") == "workflow_dispatch"]
    if (pending := next((found for found in dispatched if found.get("status") != "completed"), None)) is not None:
        return (f"its {base} dispatch run {pending['id']} is {pending.get('status')}; "
                "re-check once it completes")
    now = now or datetime.now().astimezone()
    if dispatched and (started := created(dispatched[0])) is not None and now - started < BASE_DISPATCH_EVERY:
        return (f"its newest {base} dispatch run {dispatched[0]['id']} gave no verdict for it; the next dispatch "
                f"starts after {(started + BASE_DISPATCH_EVERY).strftime('%H:%MZ')}")
    try:
        started_run = github.dispatch(repo, file, base)
    except Refused as why:
        return (f"no {base} dispatch of {file} could start from this host ({str(why)[:200]}); a check from a host "
                "whose gh may dispatch starts it")
    named = f" run {started_run}" if started_run is not None else ""
    return f"dispatched {file}{named} on the {base} tip for a base verdict; re-check once it completes"


# A gallery health shard of a pull request replays its red states on the base it merged with (gallery-health.yml's
# GALLERY_REPLAY_STEP). When the base itself does not load, the replay dies before it compares and the shard is red
# with no per-state verdict: 2026-11-07, base d7e68dec's webviews imported 'pillAsks' from JumpPill.tsx after it
# moved ("SyntaxError: Export named 'pillAsks' not found", job 128448409188), and merge_hold refused cmux#37916, the
# fix itself, as "'health (1)': no failing test or error line to match". Such a shard is judged as its replay would
# have judged it (test_reds.gallery_classify), against the newest first-parent base commit, at or before the replay's
# base and within GALLERY_FALLBACK_COMMITS / GALLERY_FALLBACK_HOURS, whose gallery health run gave every shard a whole
# health.json. The same rule as cmuxterm-hq#7649 (next_autoland.crashed_webview_replay): only a crash in the replay of
# the base counts, its first failed step the replay and a load error after the replay starts. A head that does not
# load never reaches the replay (it names no red state), and stays its own red.
GALLERY_WORKFLOW = ".github/workflows/gallery-health.yml"
GALLERY_JOB = re.compile(r"health \((\d+)\)")
GALLERY_RENDER_STEP = "Render the gallery and judge it"
GALLERY_REPLAY_STEP = "Judge the red states against the base"
GALLERY_REPLAY_START = re.compile(r"^replaying on base ([0-9a-f]{40}): \S")
GALLERY_ARTIFACT = "gallery-health-"
GALLERY_HEALTH = "health.json"
# cmuxterm-hq#7649's BASE_LOAD_CRASH: a module that does not load.
BASE_LOAD_CRASH = re.compile(r"SyntaxError|Export named '[^']*' not found|No matching export|Cannot find module|"
                             r"Could not resolve|Module not found|failed to load module", re.I)
GALLERY_FALLBACK_COMMITS = 50
GALLERY_FALLBACK_HOURS = 48
GALLERY_FALLBACK_RUNS = 6  # base runs whose jobs and artifacts are read, newest first
COMMITS_PAGES = 3
ARTIFACT_MAX_BYTES = 64 * 1024 * 1024  # a shard's zip, screenshots included, was 18 MB on 2026-11-07
ARTIFACT_SECONDS = 120


def gallery_replay_crash(job: dict, head_log: str) -> tuple[str, str] | None:
    """(the replay's base sha, its load error) when gallery health shard JOB's base replay crashed loading the base:
    its first failed step is GALLERY_REPLAY_STEP and a BASE_LOAD_CRASH line follows the replay's start, before the
    next step. None otherwise: any other red, or a crash before the replay (the head's own)."""
    failed = [step.get("name") for step in job.get("steps") or []  # step-name: classify
              if step.get("conclusion") not in (None, "success", "skipped")]
    if not failed or failed[0] != GALLERY_REPLAY_STEP:
        return None
    base = None
    for text in lines_of(head_log):
        if base is None:
            if started := GALLERY_REPLAY_START.match(text):
                base = started.group(1)
        elif text.startswith("##[group]Run "):
            return None  # the next step: the replay ended without a load error
        elif BASE_LOAD_CRASH.search(text):
            return base, text[:300]
    return None


def first_parent_chain(repo: str, base_sha: str, github) -> list[tuple[str, datetime]]:
    """BASE_SHA and its first parents, newest first: at most GALLERY_FALLBACK_COMMITS, none committed over
    GALLERY_FALLBACK_HOURS before BASE_SHA, read from up to COMMITS_PAGES pages of the commit listing."""
    by_sha: dict[str, dict] = {}
    chain: list[tuple[str, datetime]] = []
    sha, newest = base_sha, None
    for page in range(1, COMMITS_PAGES + 1):
        listed = github.json(f"repos/{repo}/commits?sha={base_sha}&per_page=100&page={page}")
        by_sha.update((commit["sha"], commit) for commit in listed if isinstance(commit, dict)
                      and isinstance(commit.get("sha"), str))
        while sha in by_sha and len(chain) < GALLERY_FALLBACK_COMMITS:
            stamp = ((by_sha[sha].get("commit") or {}).get("committer") or {}).get("date") or ""
            try:
                when = datetime.fromisoformat(stamp.replace("Z", "+00:00"))
            except ValueError:
                return chain
            newest = newest or when
            if newest - when > timedelta(hours=GALLERY_FALLBACK_HOURS):
                return chain
            chain.append((sha, when))
            parents = by_sha[sha].get("parents") or []
            sha = parents[0].get("sha") if parents and isinstance(parents[0], dict) else None
        if sha is None or len(chain) >= GALLERY_FALLBACK_COMMITS or len(listed) < 100:
            return chain
    return chain


def newest_artifacts(listed: dict) -> dict[str, dict]:
    """A run's unexpired artifacts by name; of one name (a re-run's), the newest."""
    found: dict[str, dict] = {}
    for item in sorted((item for item in listed.get("artifacts") or []
                        if isinstance(item, dict) and isinstance(item.get("id"), int) and not item.get("expired")),
                       key=lambda item: item["id"]):
        found[str(item.get("name"))] = item
    return found


def gallery_run_results(repo: str, run: dict, github) -> list[str] | None:
    """Every rendered shard's health.json of gallery health RUN, or None when RUN gave no whole verdict: a shard
    job without a verdict conclusion, a shard whose render crashed (no health.json, or one with no per-state
    results), or a run that rendered nothing."""
    jobs = [job for job in base_run_jobs(repo, run, github) if GALLERY_JOB.fullmatch(job.get("name") or "")]
    if not jobs or any(job.get("conclusion") not in VERDICTS for job in jobs):
        return None
    for job in jobs:
        failed = [step.get("name") for step in job.get("steps") or []  # step-name: classify
                  if step.get("conclusion") not in (None, "success", "skipped")]
        if failed and failed[0] != GALLERY_REPLAY_STEP:
            return None  # red before its verdict step (a checkout, the entries it renders): no verdict
    rendered = [job for job in jobs if any(step.get("name") == GALLERY_RENDER_STEP  # step-name: classify
                                           and step.get("conclusion") not in (None, "skipped")
                                           for step in job.get("steps") or [])]
    if not rendered:
        return None
    listed = github.json(f"repos/{repo}/actions/runs/{run['id']}/artifacts?per_page=100")
    artifacts = newest_artifacts(listed)
    texts = []
    for job in rendered:
        item = artifacts.get(GALLERY_ARTIFACT + GALLERY_JOB.fullmatch(job["name"]).group(1))
        text = github.artifact_file(repo, item["id"], GALLERY_HEALTH) if item else None
        found = test_reds.gallery_read(text)
        if found.truncated or found.crashes:
            return None
        texts.append(text)
    return texts


def gallery_fallback(repo: str, base: str, workflow, base_sha: str, github,
                     base_runs: dict) -> tuple[str, list[str]] | str:
    """("SHA12 (run R)", its shards' health.json) for the newest gallery health run of a commit in BASE_SHA's
    first-parent chain (first_parent_chain) with a whole verdict, or why there is none."""
    chain = first_parent_chain(repo, base_sha, github)
    list_base_runs(repo, base, workflow, github, base_runs)
    by_sha: dict[str, list[dict]] = {}
    for run in base_runs[workflow]:
        if run.get("status") == "completed" and run.get("conclusion") in VERDICTS:
            by_sha.setdefault(tested_sha(run), []).append(run)
    reads = 0
    for sha, _ in chain:
        for run in sorted(by_sha.get(sha, []), key=lambda found: found["id"], reverse=True):
            if reads >= GALLERY_FALLBACK_RUNS:
                return (f"none of the {GALLERY_FALLBACK_RUNS} newest {base} gallery health runs before it gave "
                        "every shard a whole result")
            reads += 1
            if (texts := gallery_run_results(repo, run, github)) is not None:
                return f"{sha[:12]} (run {run['id']})", texts
    return (f"no {base} commit in the last {GALLERY_FALLBACK_COMMITS} first-parent commits or "
            f"{GALLERY_FALLBACK_HOURS} h at or before {base_sha[:12]} has a gallery health run with a whole result "
            f"(read {reads} of the {base} runs listed)")


def gallery_crash_verdict(repo: str, base: str, name: str, job: dict, head_log: str, workflow_info: dict,
                          github, base_runs: dict) -> str | None:
    """The audit line for gallery health shard JOB (NAME) whose base replay crashed loading the base
    (gallery_replay_crash), judged per state against an older base verdict (gallery_fallback); None for any other
    job or red. Raises Refused when a red state is not red the same way there, or nothing could be judged."""
    path = str(workflow_info.get("path") or "").split("@", 1)[0]
    if path != GALLERY_WORKFLOW or not (shard := GALLERY_JOB.fullmatch(name)):
        return None
    if (crash := gallery_replay_crash(job, head_log)) is None:
        return None
    base_sha, error = crash
    said = f"'{name}': its base replay crashed loading {base} {base_sha[:12]} ({error})"
    listed = github.json(f"repos/{repo}/actions/runs/{job['run_id']}/artifacts?per_page=100")
    head = newest_artifacts(listed).get(GALLERY_ARTIFACT + shard.group(1))
    if head is None:
        raise Refused(f"{said}, and its own {GALLERY_ARTIFACT}{shard.group(1)} artifact is not readable")
    head_text = github.artifact_file(repo, head["id"], GALLERY_HEALTH)
    fallback = gallery_fallback(repo, base, workflow_info["workflow_id"], base_sha, github, base_runs)
    if isinstance(fallback, str):
        raise Refused(f"{said}; {fallback}: fix the base, then re-run it")
    where, texts = fallback
    verdict = test_reds.gallery_classify(head_text, texts, f"{base} {where}")
    if verdict is None:
        raise Refused(f"{said}, and its {GALLERY_HEALTH} names no red state: nothing to judge")
    if verdict.own:
        raise Refused(f"{said}, so judged against {base} {where}: " + "; ".join(verdict.reasons)[:800])
    return (f"excused '{name}': its base replay crashed loading {base} {base_sha[:12]} ({error}); judged per state "
            f"against {base} {where}, the newest whole gallery health verdict before it, where each red state is "
            f"red the same way: {'; '.join(verdict.shared)[:400]}")


# A webview test job is judged per test, never by its job name (2026-11-08). A pull request's red files run in a head
# shard (`web / react-apps-check (N)`) and are replayed on the merge parent by `web / react-apps-base-check (N)`, a job
# ci-web.yml runs on pull requests only. So no base push ever has a job of the replay's name, and every red replay was
# refused as "no feat-cmux-next run of its workflow has a verdict for it to compare with" (cmux#34111 at 64617d70,
# replays (2), (5) and (7)), whatever the base showed. And the base's own push runs a test in whichever shard its split
# puts it, so even a head shard's name matches a base job that ran other files. test_reds.classify_web_window judges
# such a red the way next-autoland's web_red (cmuxterm-hq) does: the tests a replay charged to the change (its head
# re-run's verdict), with their errors from the head shard N of the same run, or a head shard's own failing tests,
# against the red shards of the base's newest webview runs (BASE_WORKFLOW_FOR's push caller, cmux-next-web.yml): a
# test is the base's when one of those runs fails it with the same error. The window is the base-red window: at most
# BASE_WINDOW runs that gave every shard a verdict, within BASE_WINDOW_HOURS of the newest, back to the first all-green
# run (every test passed there, so an older red never counts), reading at most WEB_BASE_JOB_READS job lists.
WEB_TEST_JOB = re.compile(r"web / react-apps-(base-)?check \((\d+)\)")
WEB_SHARD = "web / react-apps-check ({})"
WEB_SHARD_JOB = re.compile(r"web / react-apps-check \(\d+\)")
WEB_BASE_JOB_READS = BASE_JOB_READS
# The steps whose failure is a webview test red, as the jobs API shows them: every other step of these jobs that can
# fail is continue-on-error (it reads as a success there) and is gathered by the job's own last step, 'Fail on the gate
# checks' in a shard (bundles, type check, PR rules) or a head build step in a replay. A job with any other failed step
# failed outside its tests, and a per-test match never excuses it (review F1 on #38380): a head shard is then judged
# by its name and failed steps as before, and a replay, which has no base job of its name, is refused.
WEB_TEST_STEPS = {"replay": frozenset({"Re-run the change's reds alone on the head", "Fail on the change's own reds"}),
                  "shard": frozenset({"Test webviews"})}


def web_base_runs(repo: str, base: str, workflow, github, base_runs: dict):
    """(run, its red webview shard jobs) for each of BASE's newest webview runs of WORKFLOW that gave every shard a
    verdict, newest first, read lazily: the window above. An all-green run is yielded and ends it."""
    list_base_runs(repo, base, workflow, github, base_runs)
    reads, count, newest = 0, 0, None
    for run in base_runs[workflow]:
        if run.get("status") == "completed" and run.get("conclusion") in ("cancelled", "skipped"):
            continue  # a superseded coalesced run: no shard of it ran
        if reads >= WEB_BASE_JOB_READS:
            return
        reads += 1
        shards = [job for job in base_run_jobs(repo, run, github) if WEB_SHARD_JOB.fullmatch(job.get("name") or "")]
        if not shards or any(job.get("status") != "completed" or job.get("conclusion") not in VERDICTS
                             for job in shards):
            continue
        when = created(run)
        newest = newest or when
        if newest and when and newest - when > timedelta(hours=BASE_WINDOW_HOURS):
            return
        red = sorted((job for job in shards if job.get("conclusion") == "failure"), key=lambda job: job["name"])
        yield run, red
        count += 1
        if not red or count >= BASE_WINDOW:
            return


def web_test_verdict(repo: str, base: str, name: str, job: dict, head_log: str, workflow_info: dict, github,
                     base_runs: dict) -> str | None:
    """The audit line for a red webview test job NAME (WEB_TEST_JOB) judged per test against the base's newest webview
    runs (the rule above); None for any other job, or a head shard whose log names no failing webview test (judged by
    its name as before). Raises Refused when a test is not red on the base the same way, or nothing could be judged."""
    found = WEB_TEST_JOB.fullmatch(name)
    if repo != HOME_REPO or found is None:
        return None
    replay = bool(found.group(1))
    failed = [step.get("name") or "" for step in job.get("steps") or []  # step-name: classify
              if step.get("conclusion") not in (None, "success", "skipped")]
    outside = [step for step in failed if step not in WEB_TEST_STEPS["replay" if replay else "shard"]]
    if outside or not failed:
        if not replay:
            return None
        raise Refused(f"'{name}' failed outside its webview test steps: {', '.join(outside) or 'no step failed'}; "
                      f"a replay has no {base} job of its name to compare with, so it is never a base red")
    head_logs: list[str | None] = [head_log]
    if replay:
        shard = WEB_SHARD.format(found.group(2))
        sibling = next((other for other in base_run_jobs(repo, {"id": job["run_id"]}, github)
                        if other.get("name") == shard), None)
        try:
            head_logs.append(github.log(repo, sibling) if sibling is not None else None)
        except Refused as why:
            raise Refused(f"'{name}': the log of its head shard '{shard}', where its tests' errors are printed, "
                          f"could not be read: {str(why)[:300]}") from None
        if sibling is None:
            raise Refused(f"'{name}': its run has no head shard '{shard}' whose errors its tests could be "
                          "compared by")
    workflow = base_caller(repo, base, workflow_info, name) or workflow_info["workflow_id"]
    green: list[dict] = []
    unread: list[str] = []  # why a base log could not be read, named in the refusal

    def windows():
        for run, red in web_base_runs(repo, base, workflow, github, base_runs):
            if not red:
                green.append(run)
                return
            logs = []
            for found_job in red:
                try:
                    logs.append(github.log(repo, found_job))
                except Refused as why:
                    unread.append(f"job {found_job.get('id')}: {str(why)[:200]}")
                    logs.append(None)
            yield f"{base} run {run['id']}", logs

    verdict = test_reds.classify_web_window(head_logs, windows(), name, base)
    if verdict is None:
        if not replay:
            return None
        raise Refused(f"'{name}': its replay names no failing webview test (it failed outside its tests); a replay "
                      f"has no {base} job of its name to compare with, so it is never a base red")
    if verdict.own:
        said = "; ".join(verdict.reasons)
        if green:
            said += f" (every webview test passed on {base} run {green[0]['id']}, which ends the window)"
        if unread:
            said += f" (unread: {unread[0]})"
        raise Refused(f"'{name}' judged per test against {base}'s webview runs: {said}"[:1000])
    return f"excused '{name}': each failing webview test is red the same way on {base}: " + "; ".join(verdict.shared)[:600]


# A head shard GitHub cancelled or timed out mid-run is judged per file (test_reds.classify_web_cut_short): cmux#39676's
# `web / react-apps-check (1)` was cancelled after 31 min (jobs 129249378930 and 129359593602) while every file it
# failed fails on feat-cmux-next too, and every merge was refused as "no verdict" (claude-sr2-coord, 2026-11-09: "a
# timed-out/cancelled shard whose failing files also fail the same way on base is classified as base red, not 'no
# verdict'"). Only a head shard (a replay's cancel leaves no charged-test verdict), only when the one step cut short is
# its test step, and only when its log names a red file: a shard cancelled while green, in setup or in another step
# still has no verdict and gets re-run.
CUT_SHORT = frozenset({"cancelled", "timed_out"})


def cut_short_web_verdict(repo: str, base: str, name: str, job: dict, github, run_reads: dict,
                          base_runs: dict) -> str | None:
    """The audit line excusing cancelled or timed-out head shard NAME, every red file of which is red on BASE's
    webview runs; None when it is not such a shard or its log names no red file (the caller refuses it as no verdict).
    Raises Refused when a red file is not red on the base, or the run crashed or timed a file out."""
    if repo != HOME_REPO or job.get("conclusion") not in CUT_SHORT or not WEB_SHARD_JOB.fullmatch(name):
        return None
    cut = [step.get("name") or "" for step in job.get("steps") or []  # step-name: classify
           if step.get("conclusion") not in (None, "success", "skipped")]
    if not cut or any(step not in WEB_TEST_STEPS["shard"] for step in cut):
        return None
    try:
        head_log = github.log(repo, job)
    except Refused:
        return None
    if test_reds.classify_web_cut_short(head_log, (), name, base) is None:
        return None  # no red file: nothing to compare, and no base run is read
    workflow_info = rest_run(repo, job["run_id"], github, run_reads)
    workflow = base_caller(repo, base, workflow_info, name) or workflow_info.get("workflow_id")
    if workflow is None:
        return None
    green: list[dict] = []
    unread: list[str] = []

    def windows():
        for run, red in web_base_runs(repo, base, workflow, github, base_runs):
            if not red:
                green.append(run)
                return
            logs = []
            for found_job in red:
                try:
                    logs.append(github.log(repo, found_job))
                except Refused as why:
                    unread.append(f"job {found_job.get('id')}: {str(why)[:200]}")
                    logs.append(None)
            yield f"{base} run {run['id']}", logs

    verdict = test_reds.classify_web_cut_short(head_log, windows(), name, base)
    if verdict is None:
        return None
    if verdict.own:
        said = "; ".join(verdict.reasons)
        if green:
            said += f" (every webview test passed on {base} run {green[0]['id']}, which ends the window)"
        if unread:
            said += f" (unread: {unread[0]})"
        raise Refused(f"'{name}' is {job['conclusion']}; judged per file against {base}'s webview runs: {said}"[:1000])
    return (f"excused '{name}': {job['conclusion']} mid-run (job {job.get('id')}), and each file it failed or left "
            f"running is red on {base}: " + "; ".join(verdict.shared)[:600]
            + "; the files the cancel kept from running are not judged")


def judge(repo: str, base: str, sha: str, runs: list[int], github, *, checks: list[str] = (),
          flake_state: dict | None = None) -> list[str]:
    """Audit lines for every excused failure; raises Refused on the first that is not, or RateLimitedRead
    when a read was rate-limited (no verdict on any red, so nothing below may excuse or charge one)."""
    github = rate_limit_aware(github)
    audit: list[str] = []
    base_runs: dict[int | str, list[dict]] = {}  # by workflow id, or file name for a base caller (BASE_WORKFLOW_FOR)
    base_jobs: dict[int, list[dict] | None] = {}
    job_reads: dict[int | str, int] = {}
    suites = SuiteChecks(github)
    merge_bases: dict[str, str] = {}
    run_reads: dict = {}  # head_jobs' SEEN: the head's check runs, each run's workflow, each head's run list
    load_rollups(repo, base, github)
    checks = list(checks)
    if repo in WS_CHECK_REPOS and (WS_CHECK in checks or not (runs or checks)):
        # Its one gate is a commit status judged per test (WS_CHECK); with no run or check named it is the one.
        checks = [name for name in checks if name != WS_CHECK]
        audit.extend(ws_check(repo, base, sha, github))
        if not (runs or checks):
            return audit
    if not (runs or checks):
        # Asked about no red run or check: no failure, exit 0 (cmuxterm-hq#7234 at ce69ab6d, 16/16 green, exited 1
        # here as "no failed job found", and a merge check that asks about every head refused every green PR). A red
        # run or check that was named and shows no failed job is still refused below.
        return audit or [f"no red run or check named on {sha}: no failure to excuse"]
    jobs = head_jobs(repo, sha, runs, checks, github, base=base, excused=audit, suites=suites, ignored=audit,
                     seen=run_reads)
    if not jobs and not audit:
        # A red run or check with no failed job to show has nothing the base can excuse.
        raise Refused("no failed job found on the head to compare with the base")
    for job in jobs:
        name = job.get("name", "")
        if job.get("conclusion") != "failure":
            if (cut := cut_short_web_verdict(repo, base, name, job, github, run_reads, base_runs)) is not None:
                audit.append(cut)
                continue
            raise Refused(f"'{name}' is {job.get('conclusion')}: it has no verdict to compare with the base; re-run it")
        if refused_at_setup(job):
            raise Refused(f"'{name}' was refused at setup by its runner; it gets re-run, never excused")
        head_log = lost_runner_log(repo, name, job, github)
        if refused_at_setup(job, head_log):
            raise Refused(f"'{name}' was refused at setup by its runner; it gets re-run, never excused")
        if name == GENERATED_VERDICT_JOB and (said := generated_no_verdict(head_log)) is not None:
            raise Refused(f"'{name}' gave no generated files verdict ({said[:300]}); "
                          "re-run its prerequisite and this dependent job together")
        if (said := summary_no_verdict(head_log)) is not None:
            raise Refused(f"'{name}' gave no verdict ({said[:300]}): nothing it summarizes was judged, so it is "
                          "neither a pass nor this PR's own red; re-run it")
        if (said := summary_red(head_log)) is not None:
            raise Refused(f"'{name}' is a summary red ({said[:300]}): its line names failed children in words every "
                          "summary shares, never a red the base can share; compare its failed children, each as itself")
        if name in NO_VERDICT_JOBS and (said := no_verdict(head_log)) is not None:
            proof = compile_pass_at(repo, sha, github)
            if proof is None:
                raise Refused(f"'{name}' gave no compile verdict ({said[:300]}) and nothing else compiled {sha}: "
                              "a no-verdict compile is never a base red; re-run it once the fleet answers")
            audit.append(f"ignored '{name}': it gave no compile verdict, but {proof} compiled {sha} and passed")
            continue
        if name == FLEET_COMPILE_JOB and any(FLEET_COMPILE_FAIL.match(text) for text in lines_of(head_log)):
            # A pull-request-only job: the fleet's receipts at the merge-base are its base verdict. When they do not
            # excuse it, the job is compared with base runs below, as before.
            try:
                audit.append(inherited_compile_red(repo, base, sha, name, github))
                continue
            except Refused:
                pass
        head_steps, head_tests, head_errors = signature(job, head_log)
        chromium_without_diagnostics = (name == CHROMIUM_CURRENCY_JOB
                                        and CHROMIUM_CURRENCY_STEP in head_steps
                                        and not (head_tests or head_errors or crash_signals(head_log)))
        # A webview replay's log holds the merge parent's run too: only its head part can crash or be cut short as
        # the head's (test_reds.web_head_part; cmux#34111's replay (2), whose merge parent timed out a file).
        own = test_reds.read(test_reds.web_head_part(head_log) if WEB_TEST_JOB.fullmatch(name) else head_log)
        if own.crashes or (own.truncated and not chromium_without_diagnostics):
            raise Refused(f"'{name}': " + "; ".join(own.crashes + own.truncated[:1])[:800]
                          + " (a crash or a cut-short run is never a base red)")
        pinned, aside = ffi_pin_step_a(repo, base, sha, name, head_steps, head_errors, head_tests, head_log, github)
        if pinned is not None:
            audit.append(pinned)
            continue
        workflow_info = rest_run(repo, job["run_id"], github, run_reads)
        workflow = workflow_info.get("workflow_id")
        if not isinstance(workflow, int):
            # never `actions/workflows/None/runs` (cmux#37033's 404): a run whose workflow is unread has no base
            raise Refused(f"'{name}': run {job['run_id']} came back without its workflow_id; nothing to compare "
                          "with the base")
        # This supplement uses only measured base observations with an active public quarantine issue. It can
        # bridge a green base run; it never changes the deterministic comparison when state is absent or invalid.
        known = test_reds.flaky_failures(head_log, name, workflow_info.get("name", ""), flake_state)
        if base == "feat-cmux-next" and quarantined_only(job, head_log, known):
            audit.append(f"excused '{name}': quarantined base flakes: "
                         + "; ".join(f"{test} ({why})" for test, why in sorted(known.items())))
            continue
        if (crashed := gallery_crash_verdict(repo, base, name, job, head_log, workflow_info, github,
                                             base_runs)) is not None:
            audit.append(crashed)
            continue
        if (web := web_test_verdict(repo, base, name, job, head_log, workflow_info, github, base_runs)) is not None:
            audit.append(web)
            continue
        list_base_runs(repo, base, workflow, github, base_runs)
        # The newest base run where this job has a verdict decides whether it is red on the base.
        verdicts = base_verdicts(repo, base, workflow, name, github, base_runs, base_jobs, job_reads, suites)
        base_run, base_job = next(verdicts, (None, None))
        if ((caller := base_caller(repo, base, workflow_info, name)) is not None
                and (base_run is None or before_merge_base(repo, base, sha, base_run, github, merge_bases))):
            # The PR run's workflow has no base verdict at or after the merge-base: the workflow that runs the same
            # called job on base pushes may (BASE_WORKFLOW_FOR). Its verdict decides only when it is at or after the
            # merge-base, or when the PR's workflow has none at all; else the stale one below refuses as before.
            list_base_runs(repo, base, caller, github, base_runs)
            pushed = base_verdicts(repo, base, caller, name, github, base_runs, base_jobs, job_reads, suites)
            pushed_run, pushed_job = next(pushed, (None, None))
            if pushed_run is not None and (
                    base_run is None or before_merge_base(repo, base, sha, pushed_run, github, merge_bases) is None):
                base_run, base_job, verdicts = pushed_run, pushed_job, pushed
        if base_run is None:
            dispatch = base_dispatch(repo, base, workflow_info, base_runs[workflow], github)
            raise Refused(f"'{name}': no {base} run of its workflow has a verdict for it to compare with "
                          f"(read the {BASE_RUNS_PAGE} newest, up to {BASE_JOB_READS} job lists, "
                          f"and its tip suite runs)" + (f": {dispatch}" if dispatch else ""))
        if name == GUARD_GROUP_JOB:
            audit.append(guard_group(repo, base, name, job, head_log, base_run, base_job, github))
            continue
        if base_job.get("conclusion") != "failure":
            try:
                audit.append(fixed_on_base(repo, base, sha, name, head_log, base_run, github, job))
            except Refused as why:
                if (stale := before_merge_base(repo, base, sha, base_run, github, merge_bases)) is not None:
                    dispatch = base_dispatch(repo, base, workflow_info, base_runs[workflow], github)
                    raise Refused(f"'{name}' has no {base} verdict at or after this PR's merge-base yet: the newest, "
                                  f"a pass in run {base_run['id']}, {stale}; re-check once a {base} run at or after "
                                  "the merge-base has a verdict for it" + (f": {dispatch}" if dispatch else "")
                                  ) from None
                raise Refused(f"'{name}' is not red on {base} run {base_run['id']} ({base_job.get('conclusion')}), "
                              f"and not fixed on base: {why}; fix it on this head") from None
            continue
        head = signature(job, head_log)
        if aside is not None:
            head = without_ffi_pin(head)
        if not head[1] and not head[2] and not crash_signals(head_log) and not chromium_without_diagnostics:
            raise Refused(f"'{name}': no failing test or error line to match; nothing to compare with the base")
        # The window: the newest verdict first, then older red ones, up to BASE_WINDOW verdicts within
        # BASE_WINDOW_HOURS of it, read only while a head failure is on none so far. A green verdict ends it.
        def red(run: dict, found: dict) -> tuple:
            text = github.log(repo, found)
            return run, text, signature(found, text, base=True)
        window, newest, read = [red(base_run, base_job)], created(base_run), 1
        while True:
            try:
                audit.append(compare_window(repo, base, name, head, head_log, window, chromium_without_diagnostics,
                                            flake_state=flake_state, workflow=workflow_info.get("name", ""))
                             + (f"; {aside}" if aside is not None else ""))
                break
            except Final:
                raise
            except Refused:
                run, found = next(verdicts, (None, None)) if read < BASE_WINDOW else (None, None)
                if (run is None or found.get("conclusion") != "failure"
                        or (newest and created(run) and newest - created(run) > timedelta(hours=BASE_WINDOW_HOURS))):
                    raise
                read += 1
                window.append(red(run, found))
    # A status judged by its job (status_job) is named too, the way merge_hold reads the head's reds: by the
    # status's own context. Every job above was excused or ignored, or judge() raised.
    for job in jobs:
        for context in job.get("status_contexts", ()):
            name = job.get("name", "")
            verb = next((line.split(" ", 1)[0] for line in reversed(audit)
                         if line.startswith((f"excused '{name}'", f"ignored '{name}'"))), "excused")
            audit.append(f"{verb} '{context}': its status is the verdict of job '{name}' {job['id']} in run "
                         f"{job.get('run_id')}, {verb} above")
    return audit


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    if argv is None:
        argv = sys.argv[1:]
    if argv == ["--write-rollups"]:
        ROLLUPS_FILE.write_text(json.dumps(derive_rollups(), indent=2, sort_keys=True) + "\n")
        return 0
    parser.add_argument("--repo", required=True)
    parser.add_argument("--base", required=True)
    parser.add_argument("--sha", required=True)
    parser.add_argument("--run", type=int, action="append", default=[], help="a failed workflow run on the head")
    parser.add_argument("--check", action="append", default=[], help="a red required check on the head")
    parser.add_argument("--flake-state", help="tap-tests/v1 JSON; TAP_TESTS_STATE=off disables base-flake quarantine")
    args = parser.parse_args(argv)
    if PLACEHOLDER_SHA.fullmatch(args.sha) and os.environ.get("BASE_RED_EXCUSE_FIXTURE_SHA") != "1":
        print(f"not excused: --sha {args.sha} is a placeholder, not a commit; nothing was read", file=sys.stderr)
        return 1
    limit = deadline_seconds()
    previous = signal.signal(signal.SIGALRM, _past_deadline) if hasattr(signal, "SIGALRM") else None
    if previous is not None:
        signal.alarm(limit)
    try:
        audit = judge(args.repo, args.base, args.sha, args.run, GitHub(), checks=args.check,
                      flake_state=test_reds.load_flake_state(args.flake_state, fetch=True))
    except rate_limited_classes() as error:
        print(f"rate-limited: {error}", file=sys.stderr)
        return 3
    except Infra as error:
        print(f"not excused: infra, not a verdict: {error}", file=sys.stderr)
        return 1
    except (Refused, KeyError, ValueError) as error:
        print(f"not excused: {error}", file=sys.stderr)
        return 1
    except Deadline:
        print(f"not excused: infra, not a verdict: ran past its {limit} s deadline", file=sys.stderr)
        return 1
    finally:
        if previous is not None:
            signal.alarm(0)
            signal.signal(signal.SIGALRM, previous)
    print("\n".join(audit))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
