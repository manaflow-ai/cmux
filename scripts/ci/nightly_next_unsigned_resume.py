#!/usr/bin/env python3
"""Retry only the signing and publication of a failed nightly-next run.

A nightly-next push run compiles the app (build-nightly-app), then signs,
notarizes, verifies and publishes it. When a step after the compile fails,
nightly.yml can resume from that run's saved unsigned app without compiling
again: a workflow_dispatch on nightly-next with nightly_next_unsigned_run and
nightly_next_unsigned_attempt (scripts/ci/resume-unsigned-nightly.py, cmux
#21161). Until now only a person dispatched it, so a failed signing waited for
the next tick's whole new build. Leo, 2026-10-28: "HOW THE FUCK CAN YOU NOT
JUST FUCKING INCREMENTALLY FUCKING RETRY".

main's nightly-next-feed-watch.yml runs this every 30 minutes. It dispatches
one resume when all of these hold, newest failed run first:
  - the run is a completed nightly-next push run that ended failure (the
    resume validator accepts only failure or success; a cancelled tip is the
    tick's: nightly_next_cancelled_tip.sh);
  - build-nightly-app and build-nightly-ghostty-cli-helper succeeded, both in
    the same attempt (the producer attempt the resume names);
  - its build (run id and two-digit producer attempt) is above the newest
    build in the nightly-next feed, so publication would not refuse it as
    superseded;
  - its unsigned inputs are still kept (cmux-nightly-unsigned-app is kept one
    day) and it holds no notarization recovery artifact, which
    continue-nightly-next.sh publishes once Apple accepts;
  - no resume of any run is queued or running, and this run has been resumed
    fewer than --max-resumes times (default 2; 0 turns this off).
A resume is told apart by its title, "Resume nightly-next run ID attempt N"
(nightly.yml's run-name). Until nightly-next's nightly.yml carries that title
nothing is dispatched, because the count could not see earlier resumes.

Nothing is cancelled. A resume runs in its own concurrency group beside any
build of the newer tip (the freshness rule), and publication stays latest-wins.
The dispatched run re-validates everything above it needs before signing.

usage: nightly_next_unsigned_resume.py --repo OWNER/NAME [--max-resumes 2] [--dry-run]
Needs GH_TOKEN with actions: write. A failed read only warns: exit 0.
"""
from __future__ import annotations

import argparse
import datetime as dt
import os
from pathlib import Path
import sys
import urllib.parse
import urllib.request

sys.path.insert(0, str(Path(__file__).resolve().parent))
from nightly_next_feed_watch import (  # noqa: E402
    ACTIVE, FEED_URL, RESUME_TITLE, TRANSPORT, GitHub, fetch_feed, nightly_builds)

WORKFLOW = "nightly.yml"
BRANCH = "nightly-next"
RUN_NAME_MARKER = "Resume nightly-next run "
PRODUCERS = ("build-nightly-app", "build-nightly-ghostty-cli-helper")
UNSIGNED_ARTIFACTS = ("cmux-nightly-unsigned-app", "cmux-nightly-remote-daemon", "cmux-nightly-ghostty-cli-helper",
                      "cmux-next-license-trees", "cmux-next-source-archive")
RECOVERY_PREFIX = "cmux-nightly-notarization-recovery-"
FAILED = {"failure"}  # resume-unsigned-nightly.py validate() refuses timed_out
PUSH_RUNS_READ = 30  # nightly-next push runs read, newest first: more than a day of ticks
# Resumes are counted over every nightly-next dispatch in this window: the unsigned app they
# resume is kept one day, so no earlier resume of a still-resumable run is older.
RESUME_LOOKBACK = dt.timedelta(hours=26)
JOB_PAGES = 3
# Every failed push run newer than the feed is judged, newest first, until one resumes: a run
# older than the feed costs no read, so this is bounded by the push runs read, not a fixed few
# (a valid run behind three failed compiles must still be found).
CANDIDATES_READ = PUSH_RUNS_READ


def resume_source(run: dict) -> tuple[int, int] | None:
    """(source run id, producer attempt) of a resume run, from its title; None for any other run."""
    if run.get("event") != "workflow_dispatch":
        return None
    match = RESUME_TITLE.match(str(run.get("display_title") or ""))
    return (int(match.group(1)), int(match.group(2))) if match else None


def failed_push_runs(runs: list[dict], feed_build: int) -> list[dict]:
    """Completed failed nightly-next push runs, newest first, that could still be newer than the feed."""
    found = [run for run in runs
             if run.get("event") == "push" and run.get("head_branch") == BRANCH and run.get("status") == "completed"
             and run.get("conclusion") in FAILED and int(run["id"]) * 100 + 99 > feed_build]
    return sorted(found, key=lambda run: int(run["id"]), reverse=True)


def producer_attempt(jobs: list[dict]) -> int | str:
    """The newest attempt in which every producer job itself ran and succeeded, or why there is none.

    `jobs` lists every attempt's jobs (filter=all), because resume-unsigned-nightly.py validates the
    exact attempt that produced the artifacts: a failed-jobs re-run's latest view can carry a
    producer from an earlier attempt, and the newest attempt of a job is not always the one that
    succeeded."""
    common: set[int] | None = None
    for name in PRODUCERS:
        good = {int(job.get("run_attempt") or 0) for job in jobs
                if job.get("name") == name and job.get("conclusion") == "success"} - {0}
        if not good:
            return f"{name} did not succeed"
        common = good if common is None else common & good
    if not common:
        return "the compile and the helper succeeded in different attempts"
    return max(common)


def artifact_problem(artifacts: list[dict]) -> str:
    """Why the run's saved inputs cannot be resumed, or "" when they can."""
    kept = {artifact.get("name") for artifact in artifacts if not artifact.get("expired")}
    if any(str(name).startswith(RECOVERY_PREFIX) for name in kept):
        return "it holds a notarization recovery artifact (continue-nightly-next.sh publishes it once Apple accepts)"
    missing = [name for name in UNSIGNED_ARTIFACTS if name not in kept]
    return f"its {', '.join(missing)} expired or was never saved" if missing else ""


def all_jobs(gh: GitHub, run_id: int) -> list[dict]:
    """Every attempt's jobs of one run, at most JOB_PAGES pages (a nightly has about 25 jobs an attempt)."""
    jobs: list[dict] = []
    for page in range(1, JOB_PAGES + 1):
        batch = gh.call("GET", f"/actions/runs/{run_id}/jobs?filter=all&per_page=100&page={page}")["jobs"]
        jobs.extend(batch)
        if len(batch) < 100:
            break
    return jobs


def feed_newest_build(feed_xml: str) -> int | None:
    builds = nightly_builds(feed_xml)
    return max(build for build, _ in builds) if builds else None


def ref_names_resumes(gh: GitHub) -> bool:
    """Whether nightly.yml on nightly-next titles a resume run (run-name), so resumes can be counted."""
    request = urllib.request.Request(
        f"{gh.base}/contents/.github/workflows/{WORKFLOW}?{urllib.parse.urlencode({'ref': BRANCH})}",
        headers={"Authorization": f"Bearer {gh.token}", "Accept": "application/vnd.github.raw",
                 "X-GitHub-Api-Version": "2022-11-28"})
    with urllib.request.urlopen(request, timeout=30) as response:
        return RUN_NAME_MARKER.encode() in response.read()


def runs_to_judge(gh: GitHub, now: dt.datetime) -> list[dict]:
    """The newest push runs, and every dispatch run of the resume window (to count resumes)."""
    def listing(**query) -> list[dict]:
        path = f"/actions/workflows/{WORKFLOW}/runs?{urllib.parse.urlencode({'branch': BRANCH, **query})}"
        return gh.call("GET", path)["workflow_runs"]
    since = (now - RESUME_LOOKBACK).strftime("%Y-%m-%dT%H:%M:%SZ")
    dispatches: list[dict] = []
    for page in range(1, 4):  # at most 300 dispatches a day; there are a few dozen
        batch = listing(event="workflow_dispatch", created=f">={since}", per_page=100, page=page)
        dispatches.extend(batch)
        if len(batch) < 100:
            break
    return listing(event="push", per_page=PUSH_RUNS_READ) + dispatches


def decide(gh: GitHub, feed_build: int, runs: list[dict], max_resumes: int, names_resumes) -> str:
    """Dispatch at most one resume and say what was decided. `names_resumes` is read only before a dispatch."""
    if max_resumes <= 0:
        return "off: --max-resumes is 0"
    resumes: dict[tuple[int, int], list[dict]] = {}
    for run in runs:
        source = resume_source(run)
        if source:
            resumes.setdefault(source, []).append(run)
            if run.get("status") in ACTIVE:
                return f"waiting: resume {run.get('html_url', run.get('id'))} is still running"
    notes = []
    for run in failed_push_runs(runs, feed_build)[:CANDIDATES_READ]:
        run_id = int(run["id"])
        attempt = producer_attempt(all_jobs(gh, run_id))
        if isinstance(attempt, str):
            notes.append(f"run {run_id}: {attempt}")
            continue
        build = run_id * 100 + attempt
        if build <= feed_build:
            notes.append(f"run {run_id}: build {build} is not above the feed's {feed_build}")
            continue
        earlier = resumes.get((run_id, attempt), [])
        if len(earlier) >= max_resumes:
            notes.append(f"run {run_id}: resumed {len(earlier)} times already "
                         f"({', '.join(str(r.get('html_url', r.get('id'))) for r in earlier)})")
            continue
        problem = artifact_problem(gh.call("GET", f"/actions/runs/{run_id}/artifacts?per_page=100")["artifacts"])
        if problem:
            notes.append(f"run {run_id}: {problem}")
            continue
        if not names_resumes():
            return (f"not dispatching: nightly-next's {WORKFLOW} does not title resume runs yet, so earlier resumes "
                    f"could not be counted (run {run_id} attempt {attempt} would be resumed)")
        gh.dispatch(WORKFLOW, BRANCH, {"nightly_next_unsigned_run": str(run_id),
                                       "nightly_next_unsigned_attempt": str(attempt)})
        return (f"dispatched {WORKFLOW} on {BRANCH} to resume run {run.get('html_url', run_id)} attempt {attempt} "
                f"(build {build}, feed {feed_build}, resume {len(earlier) + 1} of {max_resumes})"
                + ("; skipped " + "; ".join(notes) if notes else ""))
    return "nothing to resume" + (": " + "; ".join(notes) if notes else "")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--max-resumes", type=int, default=2)
    parser.add_argument("--feed-url", default=FEED_URL)
    parser.add_argument("--dry-run", action="store_true", help="read and decide, never dispatch")
    args = parser.parse_args(argv)
    token = os.environ.get("GH_TOKEN", "")
    if not token:
        print("GH_TOKEN is required", file=sys.stderr)
        return 2
    gh = GitHub(args.repo, token, args.dry_run)
    try:
        feed_build = feed_newest_build(fetch_feed(args.feed_url))
        if feed_build is None:
            print(f"::warning::no Nightly build in {args.feed_url}; not resuming anything")
            return 0
        runs = runs_to_judge(gh, dt.datetime.now(dt.timezone.utc))
        print("nightly-next unsigned resume: " + decide(gh, feed_build, runs, args.max_resumes, lambda: ref_names_resumes(gh)))
    except (*TRANSPORT, KeyError, TypeError, ValueError) as error:
        print(f"::warning::nightly-next unsigned resume skipped this check: {error!r}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
