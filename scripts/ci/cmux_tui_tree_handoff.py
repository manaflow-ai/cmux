#!/usr/bin/env python3
"""Hand an unpublished cmux-tui tree key to one run that deferred to this one.

A cmux-tui artifacts run that took a tree key and ended without publishing it
(notify-unpublished-tree) re-runs one run that deferred the key to it: that
run left a cmux-tui-tree-deferred-<key> artifact. The re-run wins the claim and
builds the key.

Two limits keep the hand-off from spending the installation's API and
attestation quota in a loop (2026-10-27: tree runs reached attempts 15 to 17,
each re-running the next after its own hand-off, while the attestation quota
blocked every publish):
- a deferred run is re-run at most twice (attempt 3 is its last), because a
  re-run that defers again leaves a fresh marker; and
- an owner whose every failed job failed only on GitHub's quota (an
  attestation step, or a log that names a rate limit) hands nothing off: a
  re-run spends the same quota and fails the same way. The tree is published
  by the next push of the key, or by cmux-tui-tree-request.yml once the quota
  resets. One failed job that is not quota-only makes the run a real failure,
  and the hand-off goes ahead.

The hand-off is never silent (2026-11-13: an owner's hand-off read "API rate
limit exceeded for installation" on its first call, ended as a warning in a
green job, and no run built the tree; the nightly that waited for it gave up):
- when a call is refused for the rate limit and GH_TOKEN_SPARE holds another
  token, the hand-off moves to that token for the rest of its calls; and
- a hand-off that could not run exits 1 with an error annotation, and its
  step fails the job. A hand-off that re-ran a run and then could not delete
  its marker did run: that is a warning, and the step passes.

With --published the key is published (publish-tree, or a run that adopted
it): every run that deferred to it is re-run, not one. Such a run built
nothing and so wrote no cmux-tui/<sha>/manifest.json; its re-run finds the
tree published and writes that manifest from it with no build
(adopt-commit-manifest, scripts/ci/adopt_cmux_tui_commit.py). Only a run of
<sha> can attest its manifest, so the publisher re-runs it instead of writing
it. A re-run that finds the tree published never defers again, so the markers
(each used once) bound the re-runs; PUBLISHED_MAX_ATTEMPT is a backstop.
A run still in progress is left with its marker: its own adopt step, after its
marker, reads the tree this run already published.

Such a manifest re-run re-runs one job, not the run (rerun_manifest): the
deferred run's "write the commit manifest from the published tree" job and the
five jobs that need it. GitHub keeps every other job's attempt-1 outputs (the
tree key, deferred), and the adopt job reads the tree again. A whole-run re-run
also re-ran its preflight, channel pointers, nightly-next and Team-signed
requests and the manifest sweep: 827 manifest re-runs on 2026-11-20 spent
5,286 runner-min, 1,203 of them in the jobs a one-job re-run keeps. A run whose adopt job never ran
(skipped, cancelled) or whose job list cannot be read is re-run whole, as before.

The published path spends one artifact-list call, one page of this workflow's run list, and three calls per candidate
(its job list, rerun, marker deletion): 2+3N when candidates are on that page. A candidate missing from the page gets one
bounded run-by-id read, so the fallback is still fixed per candidate and never walks the repository's run history.

usage: cmux_tui_tree_handoff.py --repo OWNER/NAME --run-id ID --key KEY [--published]
Needs GH_TOKEN with actions: write (job logs are read with actions access).
GH_TOKEN_SPARE, optional: a second token with actions: write and its own rate limit.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from typing import Any, Callable, Iterable, Mapping, Sequence

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gh_pages  # noqa: E402

# A deferred run's last attempt the hand-off may start: two re-runs at most.
MAX_ATTEMPT = 3
# The same for --published: a deferred run may already be at MAX_ATTEMPT (f8a39fdd's run 43425734678
# deferred at attempt 3 on 2026-11-13), and its manifest re-run builds nothing.
PUBLISHED_MAX_ATTEMPT = MAX_ATTEMPT + 2
# publish to R2's actions/attest-build-provenance steps: "Attest raw binary subjects",
# its "(try 2)" / "(try 3)" / "(last try)" retries, and "Retry the attestation of ...".
ATTEST_STEP = re.compile(r"^(?:Attest raw binary subjects(?: \((?:try \d+|last try)\))?|Retry the attestation\b.*)$")
RATE_LIMIT_TEXT = re.compile(
    r"rate limit exceeded|secondary rate limit|too many requests|\bHTTP 429\b|status(?: code)?:? 429", re.IGNORECASE)
RATE_LIMIT_RESET = re.compile(r"(?:x[- ]?ratelimit[- ]?reset|reset(?:s)?(?: at)?)\s*[:=]?\s*(\d{10})", re.IGNORECASE)
# gh's answer for an artifact that no longer exists.
MARKER_GONE = re.compile(r"\bNot Found\b|\bHTTP 404\b")
# The job a manifest re-run re-runs (adopt-commit-manifest's name), and the conclusions that say it ran in
# that attempt: a skipped or cancelled job never read the tree, so its run is re-run whole.
ADOPT_JOB_NAME = "write the commit manifest from the published tree"
ADOPT_JOB_RAN = frozenset({"success", "failure"})
# Jobs that only follow a failure: they never make an owner's failure their own.
REPORTING_JOBS = frozenset({"report an unpublished cmux-tui tree to cmux-next"})
GLAEDA_BUDGET = Path(os.environ.get("GLAEDA_GH_DIR") or Path.home() / ".cache" / "glaeda" / "gh") / "budget.json"


class QuotaRefused(RuntimeError):
    """The repo installation's API limit refused a hand-off call."""

    def __init__(self, retry_before: str):
        self.retry_before = retry_before
        super().__init__(retry_before)


def _ceil_minute(value: datetime) -> datetime:
    """Round a UTC time up to the next minute boundary."""
    value = value.astimezone(timezone.utc)
    if value.second or value.microsecond:
        value += timedelta(minutes=1)
    return value.replace(second=0, microsecond=0)


def _reset_time(text: str) -> datetime | None:
    """Read a Unix reset timestamp from a GitHub response or rate_limit answer."""
    match = RATE_LIMIT_RESET.search(text)
    raw = match.group(1) if match else (text.strip() if text.strip().isdigit() else None)
    if raw is None:
        return None
    try:
        return datetime.fromtimestamp(int(raw), timezone.utc)
    except (OverflowError, OSError, ValueError):
        return None


def quota_retry_before(text: str, now: datetime | None = None) -> str:
    """Return a safe UTC HH:MMZ boundary from a response or a one-hour fallback."""
    reset = _reset_time(text)
    if reset is not None:
        return _ceil_minute(reset).strftime("%H:%MZ")
    current = now or datetime.now(timezone.utc)
    boundary = _ceil_minute(current + timedelta(hours=1))
    return boundary.strftime("%H:%MZ")


def _budget_reset(now: datetime) -> datetime | None:
    """Return the earliest future reset of a spent REST counter recorded by glaeda-gh."""
    try:
        document = json.loads(GLAEDA_BUDGET.read_text())
    except (OSError, ValueError):
        return None
    if not isinstance(document, dict):
        return None
    counters = document.get("restCounters") if isinstance(document.get("restCounters"), list) else []
    resets = []
    for counter in [*counters, document.get("rest")]:
        try:
            remaining = float(counter["remaining"])
            limit = float(counter["limit"])
            reset = float(counter["reset"])
        except (TypeError, KeyError, ValueError):
            continue
        if limit > 0 and remaining / limit < 0.01 and reset > now.timestamp():
            resets.append(datetime.fromtimestamp(reset, timezone.utc))
    return min(resets) if resets else None


def _rate_limit_retry_before(refused: str) -> str:
    """Use the refused call's reset, then glaeda's poorest REST counter, then a bounded fallback."""
    # Separate `gh api rate_limit` answers can describe a different REST window from the call that failed.
    reset = _reset_time(refused)
    if reset is not None:
        return _ceil_minute(reset).strftime("%H:%MZ")
    if (reset := _budget_reset(datetime.now(timezone.utc))) is not None:
        return _ceil_minute(reset).strftime("%H:%MZ")
    # Without the refusal header or a current budget reading, do not guess :00: give the installation a full hour
    # from this refusal instead.
    return quota_retry_before("", datetime.now(timezone.utc))


def failed_jobs(jobs: Sequence[Mapping[str, Any]]) -> list[Mapping[str, Any]]:
    return [job for job in jobs if job.get("conclusion") == "failure" and job.get("name") not in REPORTING_JOBS]


def job_quota_only(job: Mapping[str, Any], log_text: str | None) -> bool:
    """A failed job failed only on GitHub's quota: each failed step is an attestation step, or its log names a
    rate limit. An unreadable log (None) is no evidence of a quota failure."""
    steps = [step.get("name") or "" for step in job.get("steps") or [] if step.get("conclusion") == "failure"]
    if steps and all(ATTEST_STEP.match(name) for name in steps):
        return True
    return log_text is not None and bool(RATE_LIMIT_TEXT.search(log_text))


def quota_only_failure(jobs: Sequence[Mapping[str, Any]], log_of: Callable[[Mapping[str, Any]], str | None]) -> bool:
    """True when the run has failed jobs and every one of them failed only on GitHub's quota."""
    failed = failed_jobs(jobs)
    return bool(failed) and all(job_quota_only(job, log_of(job)) for job in failed)


def order_candidates(artifacts: Iterable[Mapping[str, Any]], self_run: int) -> list[tuple[int, int, str, Mapping[str, Any]]]:
    """(artifact id, run id, branch, embedded run record) of unexpired deferred markers left by other runs, feat-cmux-next
    pushes first, newest run first within each branch class."""
    rows = []
    for artifact in artifacts:
        run = artifact.get("workflow_run") or {}
        if artifact.get("expired") or not run.get("id") or int(run["id"]) == self_run:
            continue
        rows.append((int(artifact["id"]), int(run["id"]), str(run.get("head_branch") or ""), run))
    return sorted(rows, key=lambda row: (row[2] != "feat-cmux-next", -row[1]))


def may_rerun(run: Mapping[str, Any], cap: int = MAX_ATTEMPT) -> tuple[bool, str]:
    """Whether a deferred run may be re-run now: completed (GitHub refuses a live one) and under the cap."""
    attempt = int(run.get("run_attempt") or 1)
    if run.get("status") != "completed":
        return False, f"run is {run.get('status')}"
    if attempt >= cap:
        return False, f"attempt {attempt} reached the cap of {cap}"
    return True, f"attempt {attempt}"


def _gh(*args: str) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(["gh", *args], capture_output=True, text=True)
    spare = os.environ.get("GH_TOKEN_SPARE")
    refused = f"{result.stderr}\n{result.stdout}"
    if result.returncode != 0 and spare and spare != os.environ.get("GH_TOKEN") and RATE_LIMIT_TEXT.search(refused):
        # One switch for the whole hand-off: the spare token is now GH_TOKEN, so a second refusal is final.
        print("::notice title=tree hand-off token::GH_TOKEN is rate limited; the hand-off continues on GH_TOKEN_SPARE")
        os.environ["GH_TOKEN"] = spare
        del os.environ["GH_TOKEN_SPARE"]
        result = subprocess.run(["gh", *args], capture_output=True, text=True)
        refused = f"{result.stderr}\n{result.stdout}"
    if result.returncode != 0 and RATE_LIMIT_TEXT.search(refused):
        raise QuotaRefused(_rate_limit_retry_before(refused))
    return result


def _list(path: str, key: str) -> list[dict]:
    """Every item of the `key` list of a paginated endpoint, one bounded `gh api` call per page
    (scripts/ci/gh_pages.py; the gh quota wrapper refuses an unbounded paginating call)."""
    def fetch(url: str) -> Any:
        result = _gh("api", url)
        if result.returncode != 0:
            raise RuntimeError(f"gh api {url} failed: {result.stderr.strip()}")
        return {key: json.loads(result.stdout)[key]}
    try:
        return gh_pages.items(fetch, path)
    except gh_pages.PageCapError as error:
        raise RuntimeError(str(error)) from None


def rerun_manifest(repo: str, run_id: int) -> tuple[subprocess.CompletedProcess[str], str]:
    """Re-run what writes run `run_id`'s commit manifest: its adopt job alone (GitHub re-runs the jobs that need
    it too), else the whole run. (the rerun's result, what was re-run)."""
    try:
        jobs = _list(f"repos/{repo}/actions/runs/{run_id}/jobs?filter=latest&per_page=100", "jobs")
    except RuntimeError as error:
        print(f"::notice::could not read the jobs of run {run_id} ({error}); re-running the whole run")
        jobs = []
    adopt = next((job for job in jobs if job.get("name") == ADOPT_JOB_NAME
                  and job.get("conclusion") in ADOPT_JOB_RAN and job.get("id")), None)
    if adopt is not None:
        return _gh("run", "rerun", "--job", str(adopt["id"]), "--repo", repo), f"job {adopt['id']} ({ADOPT_JOB_NAME})"
    return _gh("run", "rerun", str(run_id), "--repo", repo), "the whole run"


def _delete_marker(repo: str, artifact: int, deferred: int) -> None:
    # Right after the re-run the delete can answer 404: the marker is gone already
    # (2026-11-13: run 43364473890 re-ran its deferred run and went red on that 404).
    deleted = _gh("api", "-X", "DELETE", f"repos/{repo}/actions/artifacts/{artifact}")
    if deleted.returncode != 0 and MARKER_GONE.search(deleted.stderr):
        print(f"Deferred marker {artifact} of run {deferred} was already gone.")
    elif deleted.returncode != 0:
        print(f"::warning::could not delete deferred marker {artifact} of run {deferred}: {deleted.stderr.strip()}")


def deferred_runs(repo: str, candidates: Sequence[tuple[int, int, str, Mapping[str, Any]]]) -> dict[int, Mapping[str, Any]]:
    """Read candidate run records from one workflow page, then one bounded id read for each page miss."""
    embedded = {deferred: run for _, deferred, _, run in candidates
                if run.get("status") is not None or run.get("run_attempt") is not None}
    missing = [row for row in candidates if row[1] not in embedded]
    if not missing:
        return embedded
    # Artifact workflow_run objects do not include status/run_attempt/created_at. Read one page scoped to this
    # workflow, never the repository-wide run list (which is far past gh_pages.MAX_PAGES on this repository).
    page = _gh("api", f"repos/{repo}/actions/workflows/cmux-tui-artifacts.yml/runs?per_page=100&page=1")
    if page.returncode == 0:
        runs = json.loads(page.stdout).get("workflow_runs", [])
        embedded.update({int(run["id"]): run for run in runs if run.get("id") is not None})
    still_missing = [row for row in missing if row[1] not in embedded]
    for _, deferred, _, _ in still_missing:
        result = _gh("api", f"repos/{repo}/actions/runs/{deferred}")
        if result.returncode == 0 and result.stdout.strip():
            embedded[deferred] = json.loads(result.stdout)
    return embedded


def rerun_published(repo: str, run_id: int, key: str) -> None:
    """Re-run every completed run that deferred to published tree `key`, so each writes its commit manifest."""
    artifacts = _list(f"repos/{repo}/actions/artifacts?name=cmux-tui-tree-deferred-{key}&per_page=100", "artifacts")
    candidates = order_candidates(artifacts, run_id)
    if not candidates:
        print(f"No run of tree {key} deferred to it.")
        return
    records = deferred_runs(repo, candidates)
    failed = []
    for artifact, deferred, branch, _ in candidates:
        run = records.get(deferred)
        if run is None:
            failed.append(f"could not read run {deferred} ({branch}) from the batched run list")
            continue
        allowed, why = may_rerun(run, PUBLISHED_MAX_ATTEMPT)
        if not allowed:
            print(f"Not re-running run {deferred} ({branch}): {why}.")
            continue
        rerun, what = rerun_manifest(repo, deferred)
        if rerun.returncode != 0:
            failed.append(f"could not re-run run {deferred} ({branch}): {rerun.stderr.strip()}")
            continue
        print(f"Re-ran run {deferred} ({branch}, {why}; {what}): tree {key} is published, and that run writes its commit manifest from it.")
        _delete_marker(repo, artifact, deferred)
    if failed:
        raise RuntimeError("; ".join(failed))


def handoff(repo: str, run_id: int, key: str) -> None:
    jobs = _list(f"repos/{repo}/actions/runs/{run_id}/jobs?filter=latest&per_page=100", "jobs")

    def log_of(job: Mapping[str, Any]) -> str | None:
        result = _gh("api", f"repos/{repo}/actions/jobs/{job['id']}/logs")
        if result.returncode != 0:
            print(f"::warning::could not read the log of job {job['id']} ({job.get('name')}): {result.stderr.strip()}")
            return None
        return result.stdout

    if quota_only_failure(jobs, log_of):
        print(f"::warning title=tree hand-off skipped::run {run_id} failed only on GitHub's rate limit or "
              f"attestation; a re-run would spend the same quota. Tree {key} is left for the next push of the key.")
        return
    artifacts = _list(f"repos/{repo}/actions/artifacts?name=cmux-tui-tree-deferred-{key}&per_page=100", "artifacts")
    candidates = order_candidates(artifacts, run_id)
    if not candidates:
        print(f"No run of tree {key} deferred to this one.")
        return
    for artifact, deferred, branch, _ in candidates:
        result = _gh("api", f"repos/{repo}/actions/runs/{deferred}")
        if result.returncode != 0 or not result.stdout.strip():
            print(f"::warning::could not read run {deferred} ({branch}): {result.stderr.strip()}")
            continue
        allowed, why = may_rerun(json.loads(result.stdout))
        if not allowed:
            print(f"Not re-running run {deferred} ({branch}): {why}.")
            continue
        rerun = _gh("run", "rerun", str(deferred), "--repo", repo)
        if rerun.returncode != 0:
            print(f"::warning::could not re-run run {deferred} ({branch}): {rerun.stderr.strip()}")
            continue
        print(f"Re-ran run {deferred} ({branch}, {why}), which deferred to this one, to build tree {key}.")
        # The marker is used once. If it cannot be deleted, a later owner may re-run this run again, but only
        # up to MAX_ATTEMPT: the cap is read from the run itself, not from the marker. The key was handed on,
        # so the step passes.
        _delete_marker(repo, artifact, deferred)
        return
    print(f"::warning::no run that deferred tree {key} to this one could be re-run")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--run-id", required=True, type=int)
    parser.add_argument("--key", required=True)
    parser.add_argument("--published", action="store_true",
                        help="the key is published: re-run every run that deferred to it, for its commit manifest")
    args = parser.parse_args(argv)
    if not os.environ.get("GH_TOKEN"):
        print("::warning::tree hand-off needs GH_TOKEN; nothing was handed off", file=sys.stderr)
        return 2
    if args.published:
        try:
            rerun_published(args.repo, args.run_id, args.key)
        except QuotaRefused as error:
            print(f"::error title=deferred runs not re-run::[quota-only] deferred runs not re-run for the "
                  f"published tree; run {args.run_id}; no attempt before {error.retry_before}; the repo "
                  "installation's API limit refused its API call. Deferred markers remain for the next run.")
            return 1
        except Exception as error:  # the step fails its job: a deferred commit is left without its manifest
            print(f"::error title=deferred runs not re-run::tree {args.key} is published, but {error}. Those "
                  "commits have no cmux-tui manifest until their runs are re-run (gh run rerun RUN).")
            return 1
        return 0
    try:
        handoff(args.repo, args.run_id, args.key)
    except QuotaRefused as error:
        print(f"::error title=tree not handed off::tree {args.key} was not handed off: the repo installation's "
              f"API limit refused its API call; no attempt before {error.retry_before}. Dispatch "
              "cmux-tui-tree-request.yml after that window.")
        return 1
    except Exception as error:  # the step fails its job: say why nothing was handed off, and the way out
        print(f"::error title=tree not handed off::tree {args.key} was not handed off: {error}. "
              "No run may build it now: dispatch cmux-tui-tree-request.yml with a commit of the tree.")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
