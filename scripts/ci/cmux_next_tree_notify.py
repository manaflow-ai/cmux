#!/usr/bin/env python3
"""Start the cmux-next tree jobs that waited for a cmux-tui tree.

cmux-next's path routing probes the same-tree cmux-tui once
(pin-cmux-tui.sh probe). When the tree is not published yet, it uploads a
marker artifact named `cmux-next-tree-wait-<key>` (marker.json: the commit to
test, the commit to report on, the tree tiers, the origin event) and skips the
tree jobs. No runner waits.

The cmux-tui artifacts workflow runs this when it publishes <key> (--state
ready) or ends without publishing it (--state failed). For each current marker
it dispatches cmux-next.yml in same-tree mode, which runs only the daemon tests
and scheme compile on that commit, or reports the failure. An unpublished PR
tree is skipped: its failed marker is retained for a later trusted publication,
without dispatching a red check or creating a cmux-tui-pin-* ref.

--state failed is checked against the tree's completion.json on R2 first.
publish-cmux-tui-tree.py writes it last and only once, so it is the record
that the tree is published: a run cancelled after (or while another run)
published the key reports ready, not the run's conclusion (#23517).

A failed marker is kept (a later publication of the key still starts its
jobs), so every artifacts run that fails the same key would report it in red
again. A key that cannot build (a stale Cargo.lock on the base it came from)
is failed by every branch push cut from that base: on 2026-11-02 three
`cmux-next base tier` markers were re-dispatched in red about every 2 minutes
for hours, draining the routing App's REST quota. So a failed state is
reported once per marker: the run history of cmux-next.yml (read once per
notify) is the record, and a marker whose run name already has a dispatch
created after the marker was uploaded is not dispatched again. A ready
state always dispatches.

A failed state is first taken over (cmux_tui_tree_takeover.py): a waiting
feat-cmux-next commit re-runs its own artifacts run, which claims, builds
and publishes the key (never the reporting run itself); its publish
then starts every marker's tree jobs. Only when no waiter can take it over
are the markers reported in red. One run that died (or whose jobs GitHub
never created) no longer turns every commit waiting on its tree red.

A same-tree run that reported a tree red leaves a marker of its own, marked
`reported` (cmux_next_same_tree_failed.py; cmux-next.yml same-tree-cmux-tui):
the record of that red, keyed by the tree. A publication dispatches it like
any marker, so every tier the run reported red runs again, even when the
marker that started the red run is gone (2026-11-11, cmux#40449 at ec4a30d2:
the publish re-dispatched the daemon tests only, and `cmux app scheme compile
(Debug) (same-tree)` stayed red from run 43009515785). A failed state never
dispatches a reported marker: its red is already posted. Markers of one run
(the same run name, commits and refs) start one same-tree run, with every
tier any of them carries. The failed reason always names the tree (`tree
<key>`): the same-tree run reads the tree's publish record by it, so a re-run
of a red run whose tree has been published since starts the ready jobs.

A pull request's same-tree run has a concurrency group of its own and no
cancel, and is_current() is read only at the dispatch, so when the head moves
on its older same-tree runs stay in the Mac queue (2026-11-09: 14 runs waiting
only for their scheme compile, 3 of them for one branch). After a dispatch on a
same-repository pull request's head branch, and after a marker of that
pull request is found superseded, cancel_superseded_same_tree() cancels that
branch's superseded same-tree runs, but keeps the newest run, the runs of the
pull request's head and the oldest candidate (base tier:
cmux_next_base_tier.py). The sweep reads only what GitHub records (the
artifact's run, pulls/<n>). A marker that a fork pull request's run uploaded
(it runs the fork's workflow file, so it can write any marker) starts and
cancels nothing; the fork keeps its pull_request run.

Usage: cmux_next_tree_notify.py --repo OWNER/NAME --key KEY --state ready|failed
       [--reason TEXT]
Needs GH_TOKEN with actions: write (dispatch, delete markers, cancel runs), contents: read
and pull-requests: read. Exits 0 when the API fails: a notify problem must not
turn a good publication red; it prints a ::warning:: instead.
"""

from __future__ import annotations

import argparse
import http.client
import io
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
import zipfile
from pathlib import Path
from typing import Callable, Protocol

sys.path.insert(0, str(Path(__file__).resolve().parent))
import deadline_http  # noqa: E402  - every call's transport: nothing is sent past its bound

SHA = re.compile(r"^[0-9a-f]{40}$")
ISO_TIME = re.compile(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")
REF = re.compile(r"^[A-Za-z0-9._/-]{1,200}$")
TIERS = ("daemon", "scheme")
# A marker's tip_suite -> the tiers it may carry and the dispatch input that names its same-tree run
# (`cmux-next tip daemon suite · <sha>`, `cmux-next base tier · <sha>`).
TIP_SUITES = {"daemon": {"daemon"}, "base": {"daemon", "scheme"}}
TIP_SUITE_INPUTS = {"daemon": "tip_daemon_suite", "base": "base_tier"}
MAX_MARKERS = 50
# The run history read for the once-per-marker failed report: 100 runs a page.
RUN_PAGES = 5
WORKFLOW = "cmux-next.yml"
# A run in one of these states has not finished.
OPEN = ("queued", "in_progress", "waiting", "pending", "requested")
# The Mac jobs of a same-tree run (its tiers, TIERS). A run with one of them in progress is never cancelled.
MAC_JOBS = ("cmux-next daemon tests", "cmux app scheme compile (Debug)")
# Jobs whose `if` reads `inputs.same_tree_sha == ''`: a same-tree run lists both as skipped (run 42607592895),
# a plain dispatch runs them. The REST API returns no dispatch inputs, and a plain dispatch on the branch has
# the same `cmux-next · <sha>` name, so these are what tells a same-tree run apart.
SAME_TREE_SKIPPED_JOBS = ("cmux-next push head preflight", "cmux-next path routing")
# Branches never swept: cmux-next.yml's push-origin same-tree runs (base verdicts) run on them.
NEVER_SWEPT = ("main", "feat-cmux-next")
TREE_BASE = "https://files.cmux.com/cmux-tui/tree"


class Api(Protocol):
    def get(self, path: str): ...
    def download(self, url: str) -> bytes: ...
    def post(self, path: str, body: dict) -> int: ...
    def delete(self, path: str) -> int: ...


# One call's longest wait for GitHub, from its start to the last byte of its answer. A caller that must
# finish before a deadline budgets this much for each call it makes there, a write included.
REQUEST_TIMEOUT_S = 30


# A call that did not finish within its bound (deadline_http.RequestTimeout). It ran on the caller's
# thread and stopped at its bound, so nothing was sent after it; a write sent before it (a dispatch, a
# cancel) may have reached GitHub, so the caller treats it as unknown, never as done and never as refused.
RequestTimeout = deadline_http.RequestTimeout


class GitHub:
    # Every call's whole-request bound (deadline_http.request); a test sets a fraction of a second.
    timeout: float = REQUEST_TIMEOUT_S

    def __init__(self, token: str, api_url: str = "https://api.github.com"):
        self.token = token
        self.api_url = api_url.rstrip("/")

    def _send(self, method: str, url: str, body: dict | None = None) -> tuple[int, bytes, dict[str, str]]:
        """One call, with its response headers. RequestTimeout past self.timeout."""
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(url, data=data, method=method, headers={
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        })
        # Unredirected: an artifact download redirects to blob storage, which
        # must not receive the token.
        request.add_unredirected_header("Authorization", f"Bearer {self.token}")
        return deadline_http.request(request, self.timeout)

    def _request(self, method: str, url: str, body: dict | None = None):
        status, payload, _ = self._send(method, url, body)
        return status, payload

    def get(self, path: str):
        status, payload = self._request("GET", f"{self.api_url}/{path}")
        if status != 200:
            raise RuntimeError(f"GET {path}: HTTP {status}")
        return json.loads(payload)

    def download(self, url: str) -> bytes:
        status, payload = self._request("GET", url)
        if status != 200:
            raise RuntimeError(f"download {url}: HTTP {status}")
        return payload

    def post(self, path: str, body: dict) -> int:
        return self._request("POST", f"{self.api_url}/{path}", body)[0]

    def delete(self, path: str) -> int:
        return self._request("DELETE", f"{self.api_url}/{path}")[0]


def fetch_completion(key: str) -> object | None:
    """The tree's published completion.json, or None when it is absent or unreadable."""
    # The query string bypasses a cached 404 at the CDN edge.
    url = f"{TREE_BASE}/{key}/completion.json?notify={int(time.time())}"
    try:
        status, payload, _ = deadline_http.request(url, REQUEST_TIMEOUT_S)
        return json.loads(payload) if status == 200 else None
    except (urllib.error.URLError, http.client.HTTPException, OSError, ValueError):
        return None


def completion_attests(completion: object, key: str) -> bool:
    """The checks the artifacts workflow makes of a completion.json: its key and a binaries object."""
    return (isinstance(completion, dict) and completion.get("key") == key
            and isinstance(completion.get("binaries"), dict))


def read_marker(api: Api, artifact: dict, key: str) -> dict | None:
    """The validated marker, or None when it is not one this script wrote."""
    try:
        with zipfile.ZipFile(io.BytesIO(api.download(artifact["archive_download_url"]))) as archive:
            marker = json.loads(archive.read("marker.json"))
    except (KeyError, ValueError, zipfile.BadZipFile, RuntimeError, OSError):
        return None
    if not isinstance(marker, dict) or marker.get("key") != key:
        return None
    if not all(SHA.match(str(marker.get(field, ""))) for field in ("sha", "status_sha")):
        return None
    tiers = marker.get("tiers")
    if not isinstance(tiers, list) or not tiers or any(tier not in TIERS for tier in tiers):
        return None
    if not isinstance(marker.get("reported", False), bool):
        return None
    dev_daily = marker.get("dev_daily", False)
    if dev_daily:
        if marker.get("dev_daily_sha") != marker.get("sha"):
            return None
        if marker.get("branch") != "feat-cmux-next":
            return None
    elif dev_daily is not False:
        return None
    # The tip daemon suite (cmux-next.yml tip_daemon_suite): a dispatch on feat-cmux-next of the daemon
    # tier only, which tests its exact commit whatever the tip is by then. The base tier
    # (cmux-next.yml base_tier, cmux-next-base-tier-kick.yml) likewise, with the daemon and scheme tiers.
    tip_suite = marker.get("tip_suite")
    if tip_suite is not None and (not isinstance(tip_suite, str) or tip_suite not in TIP_SUITES
                                  or marker.get("origin") != "dispatch" or dev_daily
                                  or marker.get("branch") != "feat-cmux-next"
                                  or marker.get("ref_kind", "heads") != "heads"
                                  or not set(tiers) <= TIP_SUITES[tip_suite]):
        return None
    if marker.get("origin") in ("push", "dispatch"):
        if dev_daily and marker.get("origin") != "push":
            return None
        # A dispatch may run on a tag; a push marker names a branch.
        if marker.get("ref_kind", "heads") not in (("heads", "tags") if marker["origin"] == "dispatch" else ("heads",)):
            return None
        return marker if REF.match(str(marker.get("branch", ""))) else None
    if marker.get("origin") == "pull_request":
        if not re.fullmatch(r"[0-9]{1,9}", str(marker.get("pr", ""))):
            return None
        if not REF.match(str(marker.get("base_ref", ""))):
            return None
        return marker
    return None


def dispatch_refs(marker: dict, repo: str) -> list[str]:
    """Where cmux-next.yml runs: the push's branch; a pull request's head
    branch (its checks then show on the pull request) and then its base.
    A dispatch on a branch runs there again, like a push."""
    if marker["origin"] in ("push", "dispatch"):
        return [marker["branch"]]
    refs = []
    head_ref = str(marker.get("head_ref", ""))
    if marker.get("head_repo") == repo and REF.match(head_ref):
        refs.append(head_ref)
    refs.append(marker["base_ref"])
    return refs


def is_current(api: Api, repo: str, marker: dict, pull: dict | None = None) -> bool:
    """Whether the marker's commit is still what its branch or pull request tests. PULL is pulls/<pr>, when
    the caller already read it."""
    if marker["origin"] in ("push", "dispatch"):
        # A scheduled DEV build owns an immutable SHA. Its tree may finish
        # after feat-cmux-next advances, so the branch pointer is not an
        # admission signal for this marker. same-tree mode checks out the
        # recorded SHA and the publisher's source gate verifies it again.
        if marker.get("dev_daily"):
            return True
        # Likewise the tip daemon suite and the base tier: each is the base's verdict for that commit, and in a
        # landing burst the tip always moves before its tree publishes (2026-10-30: no base daemon-test
        # verdict for hours, so no pull request's daemon-test red could be compared with the base).
        if marker.get("tip_suite"):
            return True
        # A tag has no head to move on (and is not a branch to look up).
        if marker.get("ref_kind") == "tags":
            return True
        head = api.get(f"repos/{repo}/git/ref/heads/{marker['branch']}")
        return head.get("object", {}).get("sha") == marker["sha"]
    if pull is None:
        pull = api.get(f"repos/{repo}/pulls/{marker['pr']}")
    return pull.get("state") == "open" and pull.get("head", {}).get("sha") == marker["status_sha"]


def run_name(marker: dict) -> str:
    """The name cmux-next.yml's run-name gives this marker's same-tree run."""
    if marker.get("dev_daily"):
        return f"cmux NEXT DEV daily · {marker['dev_daily_sha']}"
    if marker.get("tip_suite") == "daemon":
        return f"cmux-next tip daemon suite · {marker['sha']}"
    if marker.get("tip_suite") == "base":
        return f"cmux-next base tier · {marker['sha']}"
    return f"cmux-next · {marker['sha']}"


def run_identity(marker: dict, repo: str) -> tuple:
    """What makes two markers the same same-tree run: its name, commits, origin and dispatch refs."""
    return (run_name(marker), marker["sha"], marker["status_sha"], marker["origin"],
            tuple(dispatch_refs(marker, repo)))


def dispatched_runs(api: Api, repo: str, since: str) -> dict[str, list[str]]:
    """cmux-next.yml dispatch runs created at or after `since`: run name -> created_at times."""
    names: dict[str, list[str]] = {}
    for page in range(1, RUN_PAGES + 1):
        listing = api.get(f"repos/{repo}/actions/workflows/{WORKFLOW}/runs?event=workflow_dispatch"
                          f"&created=%3E%3D{since}&per_page=100&page={page}")
        runs = listing.get("workflow_runs", []) if isinstance(listing, dict) else []
        for run in runs:
            if not isinstance(run, dict):
                continue
            # The evaluated run-name: `display_title` (GitHub also puts it in `name` when the workflow
            # sets run-name, as cmux-next.yml does; both are read so neither field alone is relied on).
            for title in {run.get("display_title"), run.get("name")}:
                if isinstance(title, str):
                    names.setdefault(title, []).append(str(run.get("created_at", "")))
        if len(runs) < 100:
            break
    return names


def run_jobs(api: Api, repo: str, run_id: int) -> list[dict] | None:
    """The jobs of a run's latest attempt, or None when they are unreadable."""
    try:
        listed = api.get(f"repos/{repo}/actions/runs/{run_id}/jobs?filter=latest&per_page=100")
    except (RuntimeError, OSError, ValueError):
        return None
    jobs = listed.get("jobs") if isinstance(listed, dict) else None
    return [job for job in jobs if isinstance(job, dict)] if isinstance(jobs, list) else None


def is_same_tree(jobs: list[dict]) -> bool:
    """Whether these are a same-tree run's jobs: its routing jobs are skipped (SAME_TREE_SKIPPED_JOBS)."""
    skipped = {job.get("name") for job in jobs if job.get("conclusion") == "skipped"}
    return all(name in skipped for name in SAME_TREE_SKIPPED_JOBS)


def mac_job_running(jobs: list[dict]) -> bool:
    return any(job.get("name") in MAC_JOBS and job.get("status") == "in_progress" for job in jobs)


def from_same_repository(artifact: dict) -> bool:
    """Whether GitHub records the artifact's run as a same-repository run (not a fork pull request's).

    A fork pull request's run executes the fork's own workflow file, so it can upload any marker.json under
    the marker's name (review of #39634, comment 6744212258). Its marker must neither choose a dispatch ref
    nor sweep; the fork keeps its pull_request run. A missing id counts as a fork."""
    run = artifact.get("workflow_run")
    if not isinstance(run, dict):
        return False
    repository, head_repository = run.get("repository_id"), run.get("head_repository_id")
    return isinstance(repository, int) and repository == head_repository


def sweep_branch(marker: dict, repo: str, artifact: dict, pull: dict | None) -> str | None:
    """The head branch whose same-tree runs a pull request marker may sweep, or None.

    Only a same-repository pull request's head branch: only that pull request's same-tree runs run there. A
    fork's runs go to the base branch (dispatch_refs), which holds every fork pull request's same-tree runs
    and the push verdicts. The decision reads what GitHub records, never the marker's claims: the artifact's
    run (from_same_repository, its head_branch) and PULL, pulls/<pr>. The head branch must be the pull
    request's, in this repository, not its base, not main or feat-cmux-next (their push-origin same-tree
    runs are base verdicts), and the one the marker and the artifact's run name. Anything missing: None."""
    if marker.get("origin") != "pull_request" or not from_same_repository(artifact) or not isinstance(pull, dict):
        return None
    head, base = pull.get("head"), pull.get("base")
    if not isinstance(head, dict) or not isinstance(base, dict) or not isinstance(head.get("repo"), dict):
        return None
    head_ref, base_ref = head.get("ref"), base.get("ref")
    if (head["repo"].get("full_name") != repo or not isinstance(head_ref, str) or not REF.match(head_ref)
            or not isinstance(base_ref, str) or not base_ref or head_ref == base_ref
            or head_ref in NEVER_SWEPT or head_ref != marker.get("head_ref")
            or artifact["workflow_run"].get("head_branch") != head_ref):
        return None
    return head_ref


def cancel_superseded_same_tree(api: Api, repo: str, branch: str, head: str,
                                log: Callable[[str], None] = print) -> list[int]:
    """Cancel a pull request's superseded same-tree runs on its head BRANCH; returns their ids.

    The runs looked at are cmux-next.yml's open first-attempt dispatch runs on BRANCH named
    `cmux-next · <their head>` (base tier, tip suite, DEV daily and uncached runs have other names). The
    newest of them is kept, and so is every run of HEAD, the pull request's head (two markers of one head
    may carry other tiers). The others are superseded; of those, a run whose jobs are unreadable, that is
    not a same-tree run (is_same_tree) or that has a Mac job in progress is kept, and the rest are the
    candidates. The OLDEST candidate is kept
    too: its queued Mac job is nearest a runner, so the pull request still gets verdicts when the Mac wait
    is longer than its push interval (cancelling every older run starved the DEV publisher on 2026-10-26).
    The other candidates are cancelled. The jobs are read just before the cancels; a Mac job that starts
    in the instant between loses seconds of superseded work."""
    listed = api.get(f"repos/{repo}/actions/workflows/{WORKFLOW}/runs?branch={branch}"
                     f"&event=workflow_dispatch&per_page=100")
    runs = []
    for run in (listed.get("workflow_runs") or []) if isinstance(listed, dict) else []:
        if not isinstance(run, dict):
            continue
        sha = str(run.get("head_sha", ""))
        title = run.get("display_title") or run.get("name") or ""
        if (run.get("event") != "workflow_dispatch" or run.get("head_branch") != branch or not SHA.match(sha)
                or title != f"cmux-next · {sha}" or not isinstance(run.get("id"), int)
                or run.get("status") not in OPEN or not ISO_TIME.match(str(run.get("created_at", "")))):
            continue
        runs.append(run)
    runs.sort(key=lambda run: (run["created_at"], run["id"]))
    if len(runs) < 2:
        return []
    newest = runs[-1]
    candidates = []
    for run in runs[:-1]:
        if run.get("run_attempt", 1) != 1:
            continue
        if run["head_sha"] == head:
            continue
        jobs = run_jobs(api, repo, run["id"])
        if jobs is None or not is_same_tree(jobs):
            continue
        if mac_job_running(jobs):
            log(f"same-tree run {run['id']} ({run['head_sha'][:12]}) on {branch} has a Mac job running; left alone")
            continue
        candidates.append(run)
    if not candidates:
        return []
    oldest = candidates[0]
    log(f"same-tree run {oldest['id']} ({oldest['head_sha'][:12]}) on {branch} is the oldest superseded run "
        f"waiting for a Mac; kept, with the newest run {newest['id']} ({newest['head_sha'][:12]})")
    cancelled: list[int] = []
    for run in candidates[1:]:
        status = api.post(f"repos/{repo}/actions/runs/{run['id']}/cancel", {})
        if status in (202, 204):
            cancelled.append(run["id"])
            log(f"cancelled same-tree run {run['id']} ({run['head_sha'][:12]}) on {branch}: superseded by "
                f"{newest['id']} ({newest['head_sha'][:12]}), no Mac job running")
        else:
            log(f"could not cancel same-tree run {run['id']} on {branch}: HTTP {status}")
    return cancelled


def notify(api: Api, *, repo: str, key: str, state: str, reason: str,
           log: Callable[[str], None] = print,
           fetch_completion: Callable[[str], object | None] = fetch_completion, exclude_run: int = 0,
           quota_only: Callable[[], bool] = lambda: False) -> int:
    """Dispatches same-tree runs for the markers of <key>; returns how many."""
    if state == "failed" and completion_attests(fetch_completion(key), key):
        log(f"tree {key}: its completion.json is published, so the tree is ready whatever the "
            f"reporting run's conclusion; starting the tree jobs (ready)")
        state = "ready"
        reason = f"tree {key} is published ({TREE_BASE}/{key}/completion.json)"
    if f"tree {key}" not in reason:
        # cmux_next_same_tree_failed.py reads the key from the reason (a dispatch input every cmux-next.yml has).
        reason = f"tree {key}: {reason}" if reason else f"tree {key} is unavailable"
    listing = api.get(f"repos/{repo}/actions/artifacts?name=cmux-next-tree-wait-{key}&per_page=100")
    artifacts = [artifact for artifact in listing.get("artifacts", [])
                 if isinstance(artifact, dict) and not artifact.get("expired")]
    # A fork's marker starts and cancels nothing (from_same_repository), so it is dropped before the MAX_MARKERS
    # cut: newer fork markers (GitHub lists the newest first) must not hide a same-repository one.
    foreign = [artifact for artifact in artifacts if not from_same_repository(artifact)]
    if foreign:
        log(f"{len(foreign)} marker(s) were uploaded by a fork pull request's run or have no run "
            f"({', '.join(str(artifact.get('id')) for artifact in foreign[:10])}"
            f"{', ...' if len(foreign) > 10 else ''}); a fork's marker starts and cancels nothing; ignored")
        artifacts = [artifact for artifact in artifacts if from_same_repository(artifact)]
    dispatched = 0
    # Head branches a superseded marker already swept in this notify.
    swept: set[str] = set()
    # The failed report goes out once per marker (module docstring): read the run history once.
    history: dict[str, list[str]] | None = None
    # A failed state: the first waiting feat-cmux-next commit that can take the publish over does, and no
    # marker is reported red (cmux_tui_tree_takeover.py). Each commit is tried once per notify.
    # A fork's marker (from_same_repository) is not read: it neither starts a takeover nor a same-tree run.
    markers = {id(artifact): read_marker(api, artifact, key) if from_same_repository(artifact) else None
               for artifact in artifacts[:MAX_MARKERS]}
    taken_over = False
    if state == "failed" and quota_only():
        # Like the hand-off (cmux_tui_tree_handoff.py): a re-run would spend the same exhausted quota.
        log(f"tree {key}: the reporting run failed only on GitHub's rate limit or attestation; not taken over")
    elif state == "failed":
        # Imported here: the base-tier kick sparse-checks out this file alone for run_name and never fails a tree.
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import cmux_tui_tree_takeover as takeover

        taken_over = takeover.take_over_any(
            api, repo=repo, key=key, log=log, exclude_run=exclude_run,
            commits=[marker["sha"] for marker in markers.values()
                     if marker is not None and marker.get("origin") in ("push", "dispatch")
                     and marker.get("branch") == takeover.BRANCH and marker.get("ref_kind", "heads") == "heads"])
    stamps = [str(artifact.get("created_at", "")) for artifact in artifacts[:MAX_MARKERS]]
    stamps = [stamp for stamp in stamps if ISO_TIME.match(stamp)]
    if state == "failed" and stamps:
        try:
            history = dispatched_runs(api, repo, min(stamps))
        except (RuntimeError, OSError, ValueError) as error:
            log(f"::warning::could not read cmux-next.yml's run history ({error}); "
                f"failed markers are reported again")
    # pulls/<n> read once per pull request in this notify.
    pulls: dict[str, dict] = {}
    # Markers of one same-tree run (run_identity) start it once, with every tier any of them carries.
    tiers_of: dict[tuple, set[str]] = {}
    for marker in markers.values():
        if marker is not None:
            tiers_of.setdefault(run_identity(marker, repo), set()).update(marker["tiers"])
    started: set[tuple] = set()
    for artifact in artifacts[:MAX_MARKERS]:
        # from_same_repository (above) kept only artifacts whose workflow_run is an object.
        run_id = artifact["workflow_run"].get("id")
        marker = markers[id(artifact)]
        if marker is None:
            log(f"marker {artifact.get('id')} (run {run_id}) is not a valid tree marker; ignored")
            continue
        if marker["origin"] == "pull_request" and marker.get("head_ref") != artifact["workflow_run"].get("head_branch"):
            # dispatch_refs reads the marker's head_ref; GitHub records the run's branch. A mismatch is a marker
            # this run did not write for its own pull request: it starts nothing.
            log(f"marker {artifact.get('id')} (run {run_id}) names head branch {marker.get('head_ref')!r}, but its "
                f"run is on {artifact['workflow_run'].get('head_branch')!r}; ignored")
            continue
        pull = None
        try:
            if marker["origin"] == "pull_request":
                number = str(marker["pr"])
                if number not in pulls:
                    pulls[number] = api.get(f"repos/{repo}/pulls/{number}")
                pull = pulls[number]
            current = is_current(api, repo, marker, pull)
        except RuntimeError as error:
            log(f"::warning::run {run_id}: could not check whether it is current: {error}")
            continue
        if not current:
            log(f"run {run_id} ({marker['origin']} {marker['status_sha'][:12]}) was superseded; nothing to start")
            api.delete(f"repos/{repo}/actions/artifacts/{artifact['id']}")
            # Its pull request moved on: the branch's older same-tree runs are superseded too. Once per branch.
            branch = sweep_branch(marker, repo, artifact, pull)
            if branch is not None and branch not in swept:
                swept.add(branch)
                try:
                    head = str((pull or {}).get("head", {}).get("sha", ""))
                    if SHA.match(head):
                        cancel_superseded_same_tree(api, repo, branch, head, log)
                except (RuntimeError, OSError, ValueError) as error:
                    log(f"::warning::run {run_id}: could not cancel the superseded same-tree runs on {branch}: {error}")
            continue
        if marker["origin"] == "pull_request" and state == "failed":
            log(f"::notice title=same-tree cmux-tui skipped::run {run_id} ({marker['status_sha'][:12]}): "
                f"tree {key} is unavailable; no pin ref is created. Re-run after a trusted publication.")
            continue
        if state == "failed" and marker.get("reported"):
            log(f"run {run_id}: its same-tree run {marker.get('reported_run') or '?'} already reported tree {key} "
                f"red; not dispatched again (a publication of the key starts it)")
            continue
        identity = run_identity(marker, repo)
        if identity in started:
            log(f"run {run_id}: `{run_name(marker)}` was already started by another marker of it in this notify")
            if state == "ready":
                api.delete(f"repos/{repo}/actions/artifacts/{artifact['id']}")
            continue
        if state == "failed" and taken_over:
            log(f"run {run_id}: tree {key} was taken over by a waiting feat-cmux-next commit; not reported red "
                f"(its marker stays, so the publication starts its tree jobs)")
            continue
        uploaded = str(artifact.get("created_at", ""))
        if state == "failed" and history is not None and ISO_TIME.match(uploaded) and any(
                created >= uploaded for created in history.get(run_name(marker), [])):
            log(f"run {run_id}: `{run_name(marker)}` already reported tree {key} after this marker; "
                f"not dispatched again (a publication of the key still starts it)")
            continue
        inputs = {
            "same_tree_sha": marker["sha"],
            "same_tree_status_sha": marker["status_sha"],
            "same_tree_tiers": ",".join(tier for tier in TIERS if tier in tiers_of[identity]),
            "same_tree_state": state,
            "same_tree_reason": reason[:900],
            "same_tree_origin": marker["origin"],
            "same_tree_origin_run": str(run_id or ""),
        }
        if marker.get("dev_daily"):
            inputs.update(dev_daily="true", dev_daily_sha=marker["dev_daily_sha"])
        if marker.get("tip_suite"):
            # Names the run `cmux-next tip daemon suite · <sha>` or `cmux-next base tier · <sha>`, which
            # the dispatchers and base_red_excuse.py look up.
            inputs[TIP_SUITE_INPUTS[marker["tip_suite"]]] = "true"
        for ref in dispatch_refs(marker, repo):
            status = api.post(f"repos/{repo}/actions/workflows/{WORKFLOW}/dispatches", {"ref": ref, "inputs": inputs})
            if status == 204:
                dispatched += 1
                started.add(identity)
                log(f"run {run_id}: dispatched {WORKFLOW} same-tree mode ({state}) on {ref} "
                    f"for {marker['sha'][:12]}, tiers {inputs['same_tree_tiers']}")
                if state == "ready":
                    api.delete(f"repos/{repo}/actions/artifacts/{artifact['id']}")
                if ref == sweep_branch(marker, repo, artifact, pull):
                    try:
                        # is_current read the pull request's head as this marker's status_sha.
                        cancel_superseded_same_tree(api, repo, ref, marker["status_sha"], log)
                    except (RuntimeError, OSError, ValueError) as error:
                        log(f"::warning::run {run_id}: could not cancel the superseded same-tree runs on {ref}: {error}")
                break
            log(f"run {run_id}: dispatch on {ref} refused (HTTP {status})")
        else:
            log(f"::warning::run {run_id}: no ref accepted the same-tree dispatch; its tree jobs did not start")
    log(f"tree {key}: {len(artifacts)} marker(s), {dispatched} same-tree run(s) started ({state})")
    return dispatched


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", required=True)
    parser.add_argument("--key", required=True)
    parser.add_argument("--state", choices=("ready", "failed"), required=True)
    parser.add_argument("--reason", default="")
    args = parser.parse_args(argv)
    if not SHA.match(args.key):
        print(f"::warning::not a tree key: {args.key!r}")
        return 0
    token = os.environ.get("GH_TOKEN", "")
    if not token:
        print("::warning::no GH_TOKEN; cannot start the deferred cmux-next tree jobs")
        return 0
    api = GitHub(token, os.environ.get("GITHUB_API_URL", "https://api.github.com"))
    try:
        # This script runs inside the artifacts run that reports: that run is no publisher to wait on.
        own_run = os.environ.get("GITHUB_RUN_ID", "")
        run_id = int(own_run) if own_run.isdigit() else 0

        def quota_only() -> bool:
            if not run_id:
                return False
            import cmux_tui_tree_handoff as handoff  # same directory; needs the gh CLI the artifacts job has
            jobs = handoff._list(f"repos/{args.repo}/actions/runs/{run_id}/jobs?filter=latest&per_page=100", "jobs")

            def log_of(job: dict) -> str | None:
                result = handoff._gh("api", f"repos/{args.repo}/actions/jobs/{job['id']}/logs")
                return result.stdout if result.returncode == 0 else None

            return handoff.quota_only_failure(jobs, log_of)

        def safe_quota_only() -> bool:
            try:
                return quota_only()
            except Exception as error:  # an unreadable run is no evidence of a quota failure
                print(f"::warning::could not read run {run_id}'s jobs for the quota check: {error}")
                return False

        notify(api, repo=args.repo, key=args.key, state=args.state, reason=args.reason,
               exclude_run=run_id, quota_only=safe_quota_only)
    except (RuntimeError, OSError, ValueError) as error:
        print(f"::warning::could not start the deferred cmux-next tree jobs for tree {args.key}: {error}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
