#!/usr/bin/env python3
"""Alarm when feat-cmux-next work waits too long to reach the nightly-next feed.

nightly-next ships feat-cmux-next: a green push is promoted to the
`nightly-next` branch, whose nightly.yml run publishes appcast-arm64.xml. Any
stage can stall: a red Release compile or an unpublished cmux-tui tree stops
promotion, a red nightly stops publication. Lawrence and Leo daily-drive the
feed, so this checks it every 30 minutes from main (schedule runs only there).

Waiting is measured from the oldest feat-cmux-next push after the published
commit's own push (cmux-next guards runs on every such push), so a quiet spell
never alarms however old the feed is, and a push that landed while the
published build ran still counts. Past --max-lag-hours it keeps ONE open
`nightly-next-feed-stale` issue, updated in place, naming the last published
commit and the stage that is stuck; it comments only when that reason changes,
and closes the issue once nothing has waited that long. While stale it also
exits 1, so the scheduled run is red rather than green (a stall from 01:44Z on
2026-10-21 sat behind green runs for four hours). A promotion stall quotes the
latest nightly-next tick's refusal tally (nightly-next-tick.yml).

The alarm is the lesser half. The starvation guards below are the part that
heals: past 25 minutes without a publication they start a build of the current
tip, so no feed stays more than 30 minutes behind its branch. They run before
the alarm and each inside its own boundary, because they are three cheap calls
each while the alarm pages through runs and jobs and is the first thing a tight
installation budget refuses.

usage: nightly_next_feed_watch.py --repo OWNER/NAME [--max-lag-hours 3] [--dry-run]
Needs GH_TOKEN with actions: read and issues: write.
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass
import datetime as dt
import email.utils
import http.client
import json
import os
import re
import sys
import urllib.parse
import urllib.request

# Every way a read can fail in transit. `urllib` raises OSError for a refused
# connection, a timeout or an HTTP status, but a truncated response arrives as
# http.client.IncompleteRead, which is an HTTPException and not an OSError;
# one of those on 2026-10-26 was two guards away from taking the whole check
# down. A read that fails in transit is always a warning, never a traceback.
TRANSPORT = (OSError, http.client.HTTPException)

FEED_URL = "https://files-next.cmux.com/nightly-next/next/appcast-arm64.xml"  # cmux NEXT (cx-x7hwx)
# nightly-next writes two appcasts: the bare path an installed app polls and
# the `/next/` channel path. They can disagree -- on 2026-10-26 the bare feed
# was two hours ahead of `/next/` -- so freshness is the OLDER of the two and a
# build that reached one path and not the other still counts as behind.
BARE_FEED_URL = "https://files-next.cmux.com/nightly-next/appcast-arm64.xml"
NEXT_FEED_URLS = (BARE_FEED_URL, FEED_URL)
CLASSIC_FEED_URL = "https://files.cmux.com/nightly/appcast-arm64.xml"
# The old feed, nightly.yml's NIGHTLY_NEXT_LEGACY_FEED_BASE: cmux NIGHTLY (com.cmuxterm.app.nightly,
# Leo's daily driver) has it as SUFeedURL. Only publish-nightly-identity-legacy writes it, re-signing
# each cmux NEXT Nightly build, so a failed legacy job leaves it behind while FEED_URL looks current
# (7 hours on 2026-10-25, every legacy job 403'd on the Actions token's rate limit).
LEGACY_FEED_URL = BARE_FEED_URL
# Job ids from the nightly-next branch's nightly.yml, the copy those runs execute (main's differs).
LEGACY_JOBS = ("legacy-identity-target", "sign-nightly-identity-legacy", "verify-nightly-identity-legacy", "publish-nightly-identity-legacy")
# Nightly freshness (rulebook): no feed more than 30 minutes behind; a legacy job's re-run takes ~15.
LEGACY_MAX_LAG_MINUTES = 15.0
LEGACY_MAX_ATTEMPTS = 3
LABEL = "nightly-next-feed-stale"
PUSH_WORKFLOW = "cmux-next-guards.yml"  # every feat-cmux-next push, no path filter
RELEASE_COMPILE_JOB = "cmux-next Release compile (Xcode 26)"
TICK_WORKFLOW = "nightly-next-tick.yml"
TICK_ANNOTATION = "nightly-next tick"  # the tick's refusal tally
PUBLISHED_MARKER = re.compile(r"<!--\s*cmux-published-sha:\s*([0-9a-f]{40})\s*-->", re.IGNORECASE)


@dataclass(frozen=True)
class Stage:
    """What the watcher found; `reason` is the issue line that names the stuck stage. `detail`
    (the tick's refusal tally) changes every tick, so it goes in the body, never in a comment."""
    stale: bool
    waited_hours: float
    since: dt.datetime | None
    reason: str
    detail: str = ""


def as_utc(when: dt.datetime) -> dt.datetime:
    """Every time in this file is aware UTC.

    An appcast pubDate may carry no zone and `fromisoformat` accepts a naive
    string, and mixing one of those into `now - feed` raises TypeError. A
    zoneless time is read as UTC, which is what both producers write.
    """
    return when.replace(tzinfo=dt.timezone.utc) if when.tzinfo is None else when.astimezone(dt.timezone.utc)


def parse_time(value: str) -> dt.datetime:
    return as_utc(dt.datetime.fromisoformat(value.replace("Z", "+00:00")))


def newest_item(feed_xml: str) -> dt.datetime | None:
    dates = []
    for raw in re.findall(r"<pubDate>([^<]+)</pubDate>", feed_xml):
        try:
            dates.append(as_utc(email.utils.parsedate_to_datetime(raw)))
        except (TypeError, ValueError):
            continue  # one malformed item never hides the rest of the feed
    return max(dates) if dates else None


def failed_steps(jobs: list[dict]) -> str:
    out = []
    for job in jobs:
        if job.get("conclusion") not in ("failure", "timed_out"):
            continue
        steps = [step["name"] for step in job.get("steps") or [] if step.get("conclusion") == "failure"]
        out.append(f"{job['name']} (step: {', '.join(steps)})" if steps else job["name"])
    return "; ".join(out) or "no failed job recorded"


def assess(now: dt.datetime, newest: dt.datetime, pushes: list[dict], nightly: list[dict],
           jobs_of, artifacts: list[dict], compiles: list[dict], max_lag_hours: float, tick_refusal=lambda: "") -> Stage:
    """pushes: the waiting feat-cmux-next push runs (only the oldest matters); nightly: nightly-next push runs since
    `newest` (newest first); artifacts / compiles: the latest feat-cmux-next cmux-tui artifacts
    and cmux-next push runs (newest first); jobs_of(run) lists a run's jobs; tick_refusal() is the
    latest nightly-next tick's refusal tally, read only for a promotion stall."""
    if not pushes:
        return Stage(False, 0.0, None, "No feat-cmux-next push since the feed's newest item.")
    since = min(parse_time(run["created_at"]) for run in pushes)
    waited = (now - since).total_seconds() / 3600
    detail = ""
    # The newest nightly-next run that is building or decided: a newer build supersedes an older failure.
    latest = next((run for run in nightly if run.get("status") != "completed" or run.get("conclusion") in ("success", "failure", "timed_out")), None)
    if latest and latest.get("status") != "completed":
        reason = f"nightly-next run {latest['html_url']} on {latest['head_sha'][:12]} is still building."
    elif latest and latest.get("conclusion") == "success":
        reason = f"nightly-next run {latest['html_url']} on {latest['head_sha'][:12]} passed but did not publish (debounced or skipped publication)."
    elif latest:
        reason = f"nightly-next run {latest['html_url']} on {latest['head_sha'][:12]} failed: {failed_steps(jobs_of(latest))}."
    else:
        reason = "Nothing was promoted to nightly-next since the feed's newest item."
        refusal = tick_refusal()
        if refusal:
            detail = f"The latest nightly-next tick refused every newer commit: {refusal}"
        artifact = artifacts[0] if artifacts else None
        if artifact and artifact.get("conclusion") == "failure":
            reason += f" The latest feat-cmux-next cmux-tui artifacts run {artifact['html_url']} failed, so its tree is unpublished: {failed_steps(jobs_of(artifact))}."
        # Superseded pushes cancel or skip their compile; read the newest one that finished.
        for compile_run in (run for run in compiles if run.get("status") == "completed"):
            compile_job = next((job for job in jobs_of(compile_run) if job["name"] == RELEASE_COMPILE_JOB), None)
            conclusion = compile_job.get("conclusion") if compile_job else None
            if conclusion in ("failure", "timed_out"):
                reason += f" The latest feat-cmux-next {RELEASE_COMPILE_JOB} is {conclusion}: {compile_run['html_url']}."
            if conclusion in ("success", "failure", "timed_out"):
                break
    return Stage(waited > max_lag_hours, waited, since, reason, detail)


def issue_body(stage: Stage, newest: dt.datetime, now: dt.datetime, published_sha: str, max_lag_hours: float, run_url: str) -> str:
    feed_hours = (now - newest).total_seconds() / 3600
    return "\n\n".join([
        f"feat-cmux-next pushes have waited {stage.waited_hours:.1f} hours (limit {max_lag_hours:g}h) for the nightly-next feed, "
        f"since {stage.since.isoformat(timespec='minutes') if stage.since else '?'}. The feed's newest item is {feed_hours:.1f} hours old "
        f"({newest.isoformat(timespec='minutes')}). Installed nightly-next apps report \"Up to Date\".",
        f"Last published commit: {published_sha or '(unknown)'}.",
        " ".join(filter(None, [stage.reason, stage.detail])),
        f"Checked by {run_url}. This issue is updated in place every 30 minutes, gets a comment when the stuck stage changes, and closes when the feed catches up.",
    ])


def stamp(when: dt.datetime) -> str:
    return when.astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class GitHub:
    def __init__(self, repo: str, token: str, dry_run: bool):
        self.base = f"https://api.github.com/repos/{repo}"
        self.token = token
        self.dry_run = dry_run

    def call(self, method: str, path: str, body: dict | None = None):
        if self.dry_run and method != "GET":
            print(f"dry run: {method} {path} {json.dumps(body)[:200] if body else ''}")
            return {}
        request = urllib.request.Request(
            self.base + path, method=method, data=json.dumps(body).encode() if body is not None else None,
            headers={"Authorization": f"Bearer {self.token}", "Accept": "application/vnd.github+json",
                     "X-GitHub-Api-Version": "2022-11-28"})
        with urllib.request.urlopen(request, timeout=30) as response:
            data = response.read()
        return json.loads(data) if data else None

    def runs_page(self, workflow: str, branch: str, created: str | None = None, per_page: int = 100, page: int = 1, **extra) -> dict:
        query = {"branch": branch, "event": "push", "per_page": per_page, "page": page, **extra}
        if created:
            query["created"] = created
        return self.call("GET", f"/actions/workflows/{workflow}/runs?{urllib.parse.urlencode(query)}")

    def runs(self, workflow: str, branch: str, created_since: dt.datetime | None = None, per_page: int = 100):
        return self.runs_page(workflow, branch, ">=" + stamp(created_since) if created_since else None, per_page)["workflow_runs"]

    def jobs(self, run: dict) -> list[dict]:
        return self.call("GET", f"/actions/runs/{run['id']}/jobs?filter=latest&per_page=100")["jobs"]

    def recent_runs(self, workflow: str, branch: str | None = None,
                    now: dt.datetime | None = None) -> list[dict]:
        """Every run of one workflow new enough to still be active.

        Runs come back newest first, so this pages only until a page's oldest
        run predates ACTIVE_LOOKBACK: no delivery run outlives its own timeout
        by six hours, so nothing active can be older than that. A quiet
        workflow costs one call; a busy one pages until it is sure, instead of
        stopping at 100 and missing a stuck run displaced by newer ones.
        Filtering by status would be fewer rows but would miss `requested` and
        `pending`, which ACTIVE counts.
        """
        cutoff = (now or dt.datetime.now(dt.timezone.utc)) - ACTIVE_LOOKBACK
        runs: list[dict] = []
        for page in range(1, 11):
            query = {"per_page": 100, "page": page}
            if branch:
                query["branch"] = branch
            batch = self.call("GET", f"/actions/workflows/{workflow}/runs?{urllib.parse.urlencode(query)}")["workflow_runs"]
            runs.extend(batch)
            if len(batch) < 100:
                break
            oldest = min((parse_time(run["created_at"]) for run in batch if run.get("created_at")),
                         default=None)
            if oldest is not None and oldest < cutoff:
                break
        return runs

    def ref_sha(self, branch: str) -> str:
        return self.call("GET", f"/git/ref/heads/{branch}")["object"]["sha"]

    def ref_commit(self, branch: str) -> tuple[str, dt.datetime | None]:
        """The branch tip and when it landed, for the age comparison below.

        The time is None when it cannot be read; a guard treats that as "every
        active run might already carry the tip" and so never doubles a build.
        """
        sha = self.ref_sha(branch)
        try:
            return sha, parse_time(self.call("GET", f"/commits/{sha}")["commit"]["committer"]["date"])
        except (*TRANSPORT, AttributeError, KeyError, TypeError, ValueError):
            return sha, None

    def dispatch(self, workflow: str, ref: str, inputs: dict[str, str] | None = None) -> None:
        self.call("POST", f"/actions/workflows/{workflow}/dispatches", {"ref": ref, "inputs": inputs or {}})

    def tick_refusal(self) -> str:
        try:
            runs = self.call("GET", f"/actions/workflows/{TICK_WORKFLOW}/runs?status=success&per_page=1")["workflow_runs"]
            for job in self.jobs(runs[0]) if runs else []:
                for note in self.call("GET", f"/check-runs/{job['id']}/annotations?per_page=50"):
                    if note.get("title") == TICK_ANNOTATION:
                        return f"{note.get('message', '').strip()} ({runs[0]['html_url']})"
        except (*TRANSPORT, KeyError, IndexError, TypeError):
            pass
        return ""


ACTIVE = {"queued", "requested", "waiting", "pending", "in_progress"}
# No nightly, tick, train or promotion run outlives its own timeout by this
# much, so a run older than this cannot still be delivering.
ACTIVE_LOOKBACK = dt.timedelta(hours=6)


def is_active_delivery_run(workflow: str, branch: str | None, run: dict) -> bool:
    if run.get("status") not in ACTIVE:
        return False
    if workflow == "nightly.yml" and branch == "main" and run.get("event") == "schedule":
        title = run.get("display_title", "")
        if "17 */6" in title:
            return False
        if "47 8" in title:
            return True
        # Legacy unnamed schedules fail closed during rollout: never dispatch
        # a competing classic publication while its purpose is ambiguous.
        return True
    return True


def published_commit_for_release(gh: GitHub, tag: str) -> str:
    try:
        body = gh.call("GET", f"/releases/tags/{tag}").get("body") or ""
    except TRANSPORT:
        return ""
    match = PUBLISHED_MARKER.search(body)
    return match.group(1).lower() if match else ""


def carries_tip(run: dict, tip: str, tip_landed: dt.datetime | None) -> bool:
    """Whether an active run can already be building `tip`.

    True when it is that commit, or when the run was created after the commit
    landed: a tick, a train and a promotion all read the branch tip themselves
    when they dispatch, so anything that started later may be carrying it. A
    run that started earlier is building something older by construction.
    """
    if (run.get("head_sha") or "").lower() == tip.lower():
        return True
    created = run.get("created_at")
    if tip_landed is None or not created:
        return True
    try:
        return parse_time(created) >= tip_landed
    except ValueError:
        return True


def starvation_dispatch(gh: GitHub, now: dt.datetime, *, feed: dt.datetime | None,
                        published_sha: str, branch: str, workflow: str,
                        ref: str, inputs: dict[str, str] | None = None,
                        active_workflows: list[tuple[str, str | None]] | None = None,
                        minutes: float = 25.0, tip_input: str | None = None,
                        feed_unknown: bool = False) -> str:
    """Start one build of the branch tip after `minutes` without a publication.

    Nothing is ever cancelled: a newer tip builds alongside a running build,
    it never evicts it. An active run suppresses the dispatch only when it
    could already carry this tip (`carries_tip`). Before that test, ANY active
    run suppressed it, so a build stuck on an old commit held the feed back for
    as long as it hung -- on 2026-10-26 three nightly-next runs created at
    03:27Z, 04:18Z and 04:23Z kept the guard quiet while the tip moved four
    hours ahead of the feed.

    Two scheduled runs cannot race here: the workflow's concurrency group
    `nightly-next-feed-watch` has `cancel-in-progress: false`, so one runs at
    a time. A run that is already building the tip but started before the tip
    landed can still make this dispatch a duplicate; the tick coalesces, and
    the promotion ignores a request that does not move nightly-next forward.

    Two limits this does not close. `tip_landed` is the commit's committer
    date, not the moment it reached the branch; for this repository they are
    the same, because every commit on these branches arrives by squash merge,
    which sets the committer date at merge time.

    And a tip the release marker already calls published dispatches nothing
    even when a feed path is behind or unreadable. A build cannot fix that
    case -- the promotion ignores a request that does not move the branch
    forward -- and the alarm does not raise it either, because no push is
    waiting. Nothing here covers it, so the run says so in as many words
    rather than reporting a bare "unchanged".

    `tip_input` names the dispatch input that carries the commit, filled in
    from the tip this call resolved. Reading it here rather than in the
    caller's argument list keeps a `fresh` or `unchanged` answer free of API
    calls, and means the dispatched commit is exactly the one that was
    judged stale.
    """
    if feed_unknown:
        # A feed path we could not read is not evidence of freshness. Usually
        # it is a path the publish step never wrote, which a build does fix,
        # so treat it as stale and let the checks below decide. They are the
        # bound on how often this can fire: a branch that has not moved past
        # the published commit dispatches nothing at all.
        pass
    elif feed is None:
        return "feed unknown, nothing dispatched"
    elif (now - feed).total_seconds() < minutes * 60:
        return "fresh"
    tip, tip_landed = gh.ref_commit(branch)
    if not tip:
        return "unchanged"
    if tip == published_sha:
        # The branch has not moved past what the release already carries, so a
        # build would be dispatched for a commit the promotion then ignores.
        # The feed's age is reported, not diagnosed: on a branch that has been
        # quiet for an hour an old newest item is exactly what a correct feed
        # looks like, and this check cannot tell that from a publication that
        # never reached a path. Only the alarm, which compares the feed against
        # the pushes waiting behind it, can, and nothing here covers the case
        # where the tip is published and a feed path still lags.
        if feed_unknown or feed is None:
            return "unchanged: the tip is published and its feed could not be read"
        return f"unchanged: the tip is published, feed newest {feed.isoformat()}"
    active = [run for name, run_branch in (active_workflows or [(workflow, branch)])
              for run in gh.recent_runs(name, run_branch, now)
              if is_active_delivery_run(name, run_branch, run) and carries_tip(run, tip, tip_landed)]
    if active:
        return f"running {active[0].get('html_url', active[0].get('id', '?'))}"
    gh.dispatch(workflow, ref, {**(inputs or {}), tip_input: tip} if tip_input else inputs)
    return f"dispatched {workflow} for {tip}"


def published_commit(gh: GitHub) -> str:
    try:
        body = gh.call("GET", "/releases/tags/nightly-next").get("body") or ""
    except Exception:  # noqa: BLE001 - the issue only loses one line
        return ""
    match = PUBLISHED_MARKER.search(body)  # scripts/ci/nightly-publication-marker.py
    return match.group(1).lower() if match else ""


def oldest_waiting_push(gh: GitHub, published_sha: str, newest: dt.datetime) -> dict | None:
    """The oldest feat-cmux-next push after the published commit's push (else since the
    feed's newest item). Runs list newest first and a busy day has hundreds, so read
    the count and then the last page; a filtered listing stops at 1000 results, which
    is still far past the limit."""
    created = ">=" + stamp(newest)
    if published_sha:
        own = gh.runs_page(PUSH_WORKFLOW, "feat-cmux-next", per_page=1, head_sha=published_sha)["workflow_runs"]
        if own:
            created = ">" + stamp(parse_time(own[0]["created_at"]))
    total = gh.runs_page(PUSH_WORKFLOW, "feat-cmux-next", created, per_page=1)["total_count"]
    if not total:
        return None
    return gh.runs_page(PUSH_WORKFLOW, "feat-cmux-next", created, per_page=1, page=min(total, 1000))["workflow_runs"][0]


def fetch_feed(url: str) -> str:
    # The CDN answers Python's default user agent with 403.
    request = urllib.request.Request(url, headers={"Cache-Control": "no-cache", "User-Agent": "cmux-nightly-next-feed-watch"})
    with urllib.request.urlopen(request, timeout=30) as response:
        return response.read().decode("utf-8", "replace")


def read_feed(url: str) -> dt.datetime | None:
    return newest_item(fetch_feed(url))


def nightly_builds(feed_xml: str) -> list[tuple[int, dt.datetime]]:
    """Each Nightly-ring item's build and date: tagged cmux-next, as nightly_next_ring.py select
    keeps them (an untagged item is on no ring)."""
    builds = []
    for item in re.findall(r"<item>.*?</item>", feed_xml, re.DOTALL):
        channel = re.search(r"<sparkle:channel>([^<]*)</sparkle:channel>", item)
        version = re.search(r"<sparkle:version>\s*(\d+)\s*</sparkle:version>", item)
        date = re.search(r"<pubDate>([^<]+)</pubDate>", item)
        if not (version and date and channel and channel.group(1) == "cmux-next"):
            continue
        try:
            builds.append((int(version.group(1)), as_utc(email.utils.parsedate_to_datetime(date.group(1)))))
        except (TypeError, ValueError):
            continue  # one malformed item never hides the rest of the feed, as in newest_item
    return builds


def legacy_lag(now: dt.datetime, next_xml: str, legacy_xml: str,
               max_lag_minutes: float = LEGACY_MAX_LAG_MINUTES) -> tuple[int | None, str]:
    """(the build cmux NIGHTLY's feed has waited for past the limit, or None; what was found).
    Reads only the two feeds, so an API error never hides a stale feed."""
    legacy = nightly_builds(legacy_xml)
    old, old_published = max(legacy, default=(0, None))
    # Every Nightly build cmux NIGHTLY's feed lacks. The wait runs from the oldest of them, so a
    # newer publication never restarts it; the newest is the one the legacy jobs should publish.
    builds = nightly_builds(next_xml)
    missing = sorted(item for item in builds if item[0] > old)
    if not missing:
        return None, f"current at build {old}"
    since = min(published for _, published in missing)
    # A skipped republish leaves cmux NEXT's feed without its earlier items (cx-urd.67), so the
    # oldest missing build may be gone: then the wait runs from cmux NIGHTLY's own newest build.
    if old_published is not None and not any(build <= old for build, _ in builds):
        since = min(since, old_published)
    waited = (now - since).total_seconds() / 60
    build = missing[-1][0]
    if waited <= max_lag_minutes:
        return None, f"build {build} is {waited:.0f} min behind; the legacy jobs have {max_lag_minutes:g}"
    return build, f"cmux NIGHTLY's feed {LEGACY_FEED_URL} is at build {old}, {waited:.0f} min behind cmux NEXT (newest {build})"


def legacy_rerun(gh: GitHub, build: int) -> str:
    """Re-run the earliest failed legacy job of the nightly-next run that built `build` (a nightly
    build is its run id and a two-digit attempt: 4023540480101 is run 40235404801). A job's re-run
    also re-runs the jobs that need it, so the later legacy jobs follow; no other job is touched."""
    run = gh.call("GET", f"/actions/runs/{build // 100}")
    url = run.get("html_url", str(build // 100))
    if not str(run.get("path", "")).endswith("nightly.yml") or run.get("head_branch") != "nightly-next":
        return f"run {url} is not a nightly-next nightly.yml run"
    if run.get("status") in ACTIVE:
        return f"its run {url} is still running"
    failed = {job["name"]: job for job in gh.jobs(run) if job.get("name") in LEGACY_JOBS and job.get("conclusion") in ("failure", "timed_out")}
    if not failed:
        return f"run {url} has no failed legacy job to re-run"
    if int(run.get("run_attempt") or 1) >= LEGACY_MAX_ATTEMPTS:
        return f"{', '.join(failed)} still failed after {LEGACY_MAX_ATTEMPTS} attempts of {url}"
    first = next(name for name in LEGACY_JOBS if name in failed)
    gh.call("POST", f"/actions/jobs/{failed[first]['id']}/rerun")
    return f"re-ran {first} of {url}"


def read_feeds(urls) -> tuple[dt.datetime | None, list[str]]:
    """The OLDEST newest-item across `urls`, and a note for every feed that failed.

    A feed that errors or carries no dated item is reported rather than guessed
    at, and never makes the others look fresher than the slowest one.
    """
    newest: dt.datetime | None = None
    missing: list[str] = []
    for url in urls:
        try:
            item = read_feed(url)
        except (*TRANSPORT, ValueError) as error:
            missing.append(f"{url}: {error}")
            continue
        if item is None:
            missing.append(f"{url}: no dated item")
            continue
        newest = item if newest is None else min(newest, item)
    return newest, missing


def heal(label: str, guard) -> None:
    """Run one starvation guard inside its own boundary.

    No guard may be skipped because another call failed. On 2026-10-26 every
    scheduled run from 01:35Z to 04:52Z hit a 403 on the installation's REST
    budget inside the alarm path and returned before reaching the guards, so
    the feed sat four hours stale while the schedule stayed green.

    Every exception is caught, not just OSError: the guards run before the
    alarm now, so a malformed response (a KeyError or a JSONDecodeError, not
    only a transport error) must not take the alarm down with it.
    """
    try:
        print(f"{label} starvation: {guard()}")
    except Exception as error:  # noqa: BLE001 - a guard never takes the check down
        print(f"::warning::{label} starvation guard skipped: {error!r}")


def sync_issue(gh: GitHub, stage: Stage, body: str, max_lag_hours: float, run_url: str) -> str:
    """One open issue while stale (oldest kept, duplicates closed); closed when not."""
    open_issues = sorted(gh.call("GET", f"/issues?labels={LABEL}&state=open&per_page=100"), key=lambda issue: issue["number"])
    if not stage.stale:
        for issue in open_issues:
            gh.call("POST", f"/issues/{issue['number']}/comments", {"body": f"The nightly-next feed caught up: {run_url}"})
            gh.call("PATCH", f"/issues/{issue['number']}", {"state": "closed"})
        return f"current ({stage.waited_hours:.1f}h waited); closed {len(open_issues)} issue(s)"
    title = f"nightly-next feed: feat-cmux-next pushes waiting more than {max_lag_hours:g}h"
    if not open_issues:
        gh.call("POST", "/issues", {"title": title, "body": body, "labels": [LABEL]})
        return "stale; opened an issue"
    keep, *duplicates = open_issues
    gh.call("PATCH", f"/issues/{keep['number']}", {"title": title, "body": body})
    if stage.reason not in (keep.get("body") or ""):
        gh.call("POST", f"/issues/{keep['number']}/comments", {"body": stage.reason})
    for issue in duplicates:
        gh.call("POST", f"/issues/{issue['number']}/comments", {"body": f"Duplicate of #{keep['number']}."})
        gh.call("PATCH", f"/issues/{issue['number']}", {"state": "closed"})
    return f"stale; updated #{keep['number']}"


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--max-lag-hours", type=float, default=3.0)
    parser.add_argument("--feed-url", dest="feed_urls", action="append",
                        help="a cmux NEXT appcast; repeatable, and defaults to both NEXT feeds")
    parser.add_argument("--classic-feed-url", default=CLASSIC_FEED_URL)
    parser.add_argument("--legacy-feed-url", default=LEGACY_FEED_URL)
    parser.add_argument("--legacy-identity", default="on",
                        help="repository variable NIGHTLY_NEXT_LEGACY_IDENTITY; off stops the legacy jobs, so their feed is not watched")
    parser.add_argument("--run-url", default="this check")
    parser.add_argument("--dry-run", action="store_true", help="read and decide, never write issues")
    args = parser.parse_args(argv)
    token = os.environ.get("GH_TOKEN", "")
    if not token:
        print("GH_TOKEN is required", file=sys.stderr)
        return 2
    newest, missing = read_feeds(args.feed_urls or list(NEXT_FEED_URLS))
    classic_newest, classic_missing = read_feeds([args.classic_feed_url])
    for note in missing + classic_missing:
        print(f"::warning::could not read {note}")
    if newest is None:
        # The alarm needs a timestamp, but the classic guard does not: it
        # watches a different feed and must still run.
        print("::warning::no cmux NEXT feed had a dated item")
    gh = GitHub(args.repo, token, args.dry_run)
    now = dt.datetime.now(dt.timezone.utc)

    # Read each release marker once, inside whichever boundary asks for it
    # first. Reading them up here instead is what made the 2026-10-26 stall
    # invisible: one 403 on a release lookup raised before any guard ran, and
    # the run still reported success.
    seen: dict[str, str] = {}

    def published(tag: str = "") -> str:
        if tag not in seen:
            seen[tag] = published_commit_for_release(gh, tag) if tag else published_commit(gh)
        return seen[tag]

    # Heal first, and each guard inside its own boundary: a failure in one, or
    # in the alarm below, must never cost the other its dispatch.
    heal("next", lambda: starvation_dispatch(
        gh, now, feed=newest, published_sha=published(),
        branch="feat-cmux-next", workflow="nightly-next-tick.yml", ref="main", tip_input="sha",
        feed_unknown=bool(missing),
        active_workflows=[("nightly-next-tick.yml", "main"), ("nightly-next-train.yml", "feat-cmux-next"),
                          ("nightly.yml", "nightly-next"), ("nightly.yml", "main")]))
    heal("classic", lambda: starvation_dispatch(
        gh, now, feed=classic_newest, published_sha=published("nightly"),
        branch="main", workflow="nightly.yml", ref="main", inputs={"force": "false"},
        feed_unknown=bool(classic_missing)))

    # cmux NIGHTLY's feed on its own: its staleness comes from the two feeds, so neither a failed
    # re-run nor an API error elsewhere can turn a stale feed green.
    try:
        if args.legacy_identity == "off":
            legacy_build, legacy = None, "not watched: NIGHTLY_NEXT_LEGACY_IDENTITY is off"
        else:
            legacy_build, legacy = legacy_lag(now, fetch_feed(FEED_URL), fetch_feed(args.legacy_feed_url))
    except (*TRANSPORT, ValueError) as error:
        legacy_build, legacy = None, ""
        print(f"::warning::could not compare cmux NIGHTLY's feed {args.legacy_feed_url} with {FEED_URL}: {error}")
    legacy_stale = legacy_build is not None
    if legacy_stale:
        try:
            legacy = f"{legacy}; {legacy_rerun(gh, legacy_build)}"
        except Exception as error:  # noqa: BLE001 - a failed re-run never hides the stale feed
            legacy = f"{legacy}; the re-run failed: {error!r}"
    if legacy:
        print("cmux NIGHTLY feed: " + legacy)

    if newest is None:
        if legacy_stale:
            print(f"::error title=cmux NIGHTLY feed behind::{legacy}")
            return 1
        return 0
    try:
        published_sha = published()
        oldest = oldest_waiting_push(gh, published_sha, newest)
        stage = assess(
            now, newest,
            pushes=[oldest] if oldest else [],
            nightly=gh.runs("nightly.yml", "nightly-next", newest),
            jobs_of=gh.jobs,
            artifacts=gh.runs("cmux-tui-artifacts.yml", "feat-cmux-next", per_page=1),
            compiles=gh.runs("cmux-next.yml", "feat-cmux-next", per_page=5),
            max_lag_hours=args.max_lag_hours,
            tick_refusal=gh.tick_refusal,
        )
        print(f"feed newest {newest.isoformat()}, waited {stage.waited_hours:.1f}h: {stage.reason}")
        print(sync_issue(gh, stage, issue_body(stage, newest, now, published_sha, args.max_lag_hours, args.run_url), args.max_lag_hours, args.run_url))
    except TRANSPORT as error:  # the next check runs in 30 minutes
        print(f"::warning::GitHub API error, skipped this check: {error}")
        if legacy_stale:
            print(f"::error title=cmux NIGHTLY feed behind::{legacy}")
            return 1
        return 0
    if stage.stale:
        print(f"::error title=nightly-next feed stale::feat-cmux-next pushes have waited {stage.waited_hours:.1f}h "
              f"(limit {args.max_lag_hours:g}h). {' '.join(filter(None, [stage.reason, stage.detail]))}")
        return 1
    if legacy_stale:
        print(f"::error title=cmux NIGHTLY feed behind::{legacy}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
