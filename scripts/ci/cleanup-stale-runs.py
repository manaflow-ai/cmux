#!/usr/bin/env python3
"""Report or remove Actions runs stranded by closed pull requests, or queued at a superseded head.

The scheduled workflow is deliberately report-only.  Destructive cleanup is
available only from an explicit workflow_dispatch and is bounded by a small
action limit.  Runs with no pull request, or with any open pull request for
their commit, are always ignored.

SUPERSEDED=true (dispatch only) also cancels queued pull_request runs whose
pull request is open at a newer head (classify_superseded): on 2026-11-19 cmux
had 2,500 queued runs against 118 in progress while Blacksmith's Linux labels
stalled, many of them at heads a later push had replaced. A run whose head is
any open pull request's head, a run that has started, a push or schedule run,
and every nightly, dev, promote or release workflow are always kept; each
cancel re-reads the run and its pull request first.

DEAD_QUEUED=true (dispatch only) runs one wider pass over the same queued
pull_request runs (classify_dead): superseded heads as above, runs of closed or
merged pull requests, older duplicates of one workflow at one head and pull
request (the newest is kept, and only once it has waited DUPLICATE_KEEPER_SECONDS
unstarted), and runs at a draft pull request's head unstarted over
DRAFT_STALE_HOURS. The same runs are always kept, plus any pull request labelled
`no-janitor`; each cancel re-reads the run, its pull request and, for a
duplicate, the kept run. The log and step summary count each kind.
"""

from __future__ import annotations

import datetime as dt
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from typing import Any


API = "https://api.github.com"
# Workflows a superseded-head cancel never touches, by file name or run name.
PROTECTED_WORKFLOW = re.compile(r"nightly|promote|release|appcast|notariz|(?:^|[-_ /])dev(?:[-_ .]|$)", re.I)
SUPERSEDED_MIN_AGE_SECONDS = 600
SUPERSEDED_LIMIT_MAX = 500
# GitHub's runs listing returns at most this many runs for one query, whatever total_count says.
LIST_CAP = 1000
# The superseded pass reads queued runs created this recently; older ones are the stale pass's.
QUEUED_WINDOW_HOURS = 72
# The kept run of a duplicate group must have waited this long unstarted: ci.yml's run for a plain label change on a
# feat-cmux-next PR skips every job and ends in seconds, and kept over a real run its ci-status would stand for it.
DUPLICATE_KEEPER_SECONDS = 600
DRAFT_STALE_HOURS = 24
JANITOR_OPT_OUT_LABEL = "no-janitor"


def parse_time(value: str) -> dt.datetime:
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))


def may_be_eligible(run: dict[str, Any], *, now: dt.datetime, min_age_seconds: int) -> bool:
    """Whether the run's own facts allow cleanup, before any pull request is read.

    classify_run() preserves every run this rejects whatever its pull requests
    say, so main() reads a commit's pull requests only for runs that pass. The
    janitor read them for every queued and in-progress run (about 140, each a
    GITHUB_TOKEN request, twice an hour) while nearly all were pushes, side
    lanes or younger than a day.
    """
    # Commit-to-PR association also exists for main pushes and scheduled runs.
    # Only ordinary PR runs are eligible; unknown event/state facts fail closed.
    if run.get("event") != "pull_request" or run.get("status") not in {"queued", "in_progress"}:
        return False
    created_at = run.get("created_at")
    if not created_at:
        return False
    return (now - parse_time(created_at)).total_seconds() >= min_age_seconds


def classify_run(
    run: dict[str, Any], pull_requests: list[dict[str, Any]], *, now: dt.datetime, min_age_seconds: int
) -> str | None:
    """Return an eligible reason, or None when the run must be preserved."""
    if not may_be_eligible(run, now=now, min_age_seconds=min_age_seconds):
        return None
    if not pull_requests or any(pr.get("state") != "closed" for pr in pull_requests):
        return None
    if any(pr.get("merged_at") for pr in pull_requests):
        return "merged PR"
    if any(pr.get("state") == "closed" for pr in pull_requests):
        return "closed PR"
    return None


def classify_superseded(run: dict[str, Any], open_heads: dict[int, str], *, now: dt.datetime) -> str | None:
    """'superseded head' when RUN is a queued pull_request run of an open PR whose head has moved on, else None.

    OPEN_HEADS maps every open pull request's number to its head sha. A run at any open pull request's head is kept
    (one commit can head two PRs), as is a run that names no pull request, has started, is younger than
    SUPERSEDED_MIN_AGE_SECONDS, or belongs to a PROTECTED_WORKFLOW."""
    if run.get("event") != "pull_request" or run.get("status") != "queued":
        return None
    sha = str(run.get("head_sha") or "")
    try:
        age = (now - parse_time(str(run.get("created_at") or ""))).total_seconds()
    except ValueError:
        # A missing or malformed time keeps the run rather than ending the job with a traceback.
        return None
    if not sha or age < SUPERSEDED_MIN_AGE_SECONDS:
        return None
    if PROTECTED_WORKFLOW.search(str(run.get("path") or "")) or PROTECTED_WORKFLOW.search(str(run.get("name") or "")):
        return None
    if sha in open_heads.values():
        return None
    numbers = [pr.get("number") for pr in run.get("pull_requests") or [] if isinstance(pr, dict)]
    if numbers and all(n in open_heads and open_heads[n] != sha for n in numbers):
        return "superseded head"
    return None


def run_age_seconds(run: dict[str, Any], now: dt.datetime) -> float | None:
    try:
        return (now - parse_time(str(run.get("created_at") or ""))).total_seconds()
    except (TypeError, ValueError):
        return None


def _pr_numbers(run: dict[str, Any]) -> list[Any]:
    return [pr.get("number") for pr in run.get("pull_requests") or [] if isinstance(pr, dict)]


def dead_base(run: dict[str, Any], now: dt.datetime) -> bool:
    """The facts every dead-queued kind needs: a queued first-attempt pull_request run with a head, past
    SUPERSEDED_MIN_AGE_SECONDS, of no PROTECTED_WORKFLOW. A rerun is someone asking for it again, however old the
    run's created_at (review of #47775, F1)."""
    if run.get("event") != "pull_request" or run.get("status") != "queued" or not run.get("head_sha"):
        return False
    if int(run.get("run_attempt") or 1) != 1:
        return False
    if PROTECTED_WORKFLOW.search(str(run.get("path") or "")) or PROTECTED_WORKFLOW.search(str(run.get("name") or "")):
        return False
    age = run_age_seconds(run, now)
    return age is not None and age >= SUPERSEDED_MIN_AGE_SECONDS


def duplicate_key(run: dict[str, Any]) -> tuple[Any, ...]:
    return (run.get("workflow_id") or run.get("path"), run.get("head_branch"), run.get("head_sha"),
            tuple(sorted(str(n) for n in _pr_numbers(run))))


def duplicate_keepers(runs: list[dict[str, Any]], now: dt.datetime) -> dict[Any, dict[str, Any]]:
    """Run id -> the newer run kept in its place, for every older queued first attempt of a duplicate group whose
    newest run has waited DUPLICATE_KEEPER_SECONDS unstarted."""
    groups: dict[tuple[Any, ...], list[dict[str, Any]]] = {}
    for run in runs:
        if dead_base(run, now) or (run.get("event") == "pull_request" and run.get("status") == "queued"):
            groups.setdefault(duplicate_key(run), []).append(run)
    out: dict[Any, dict[str, Any]] = {}
    for members in groups.values():
        if len(members) < 2:
            continue
        members.sort(key=lambda r: (str(r.get("created_at") or ""), r.get("id") or 0))
        keeper = members[-1]
        age = run_age_seconds(keeper, now)
        if age is None or age < DUPLICATE_KEEPER_SECONDS:
            continue
        for run in members[:-1]:
            if int(run.get("run_attempt") or 1) == 1:
                out[run.get("id")] = keeper
    return out


def classify_dead(run: dict[str, Any], open_prs: dict[int, dict[str, Any]], keepers: dict[Any, dict[str, Any]],
                  *, now: dt.datetime) -> str | None:
    """'superseded head', 'closed PR', 'duplicate' or 'stale draft' for a queued pull_request run nobody will read,
    else None. OPEN_PRS maps every open pull request's number to {"sha", "draft", "labels"}; KEEPERS is
    duplicate_keepers(). A run at a non-draft open pull request's head is kept, as is one naming no pull request or
    one whose pull request carries JANITOR_OPT_OUT_LABEL."""
    if not dead_base(run, now):
        return None
    sha = str(run.get("head_sha"))
    numbers = _pr_numbers(run)
    if not numbers or any(JANITOR_OPT_OUT_LABEL in open_prs.get(n, {}).get("labels", ()) for n in numbers):
        return None
    at_head = [pr for pr in open_prs.values() if pr.get("sha") == sha]
    if not at_head:
        if all(n not in open_prs for n in numbers):
            return "closed PR"
        if all(n in open_prs for n in numbers):
            return "superseded head"
        return None
    if any(not pr.get("draft") or JANITOR_OPT_OUT_LABEL in pr.get("labels", ()) for pr in at_head):
        return "duplicate" if run.get("id") in keepers else None
    age = run_age_seconds(run, now)
    if age is not None and age >= DRAFT_STALE_HOURS * 3600:
        return "stale draft"
    return "duplicate" if run.get("id") in keepers else None


class GitHub:
    def __init__(self, token: str, repo: str) -> None:
        self.repo = repo
        self.headers = {
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "cmux-stale-run-janitor",
        }

    def request(self, method: str, path: str, *, missing_is_empty: bool = False) -> Any:
        request = urllib.request.Request(API + path, headers=self.headers, method=method)
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                if response.status == 204:
                    return {}
                return json.load(response)
        except urllib.error.HTTPError as error:
            if error.code == 404 and missing_is_empty:
                return []
            raise RuntimeError(f"GitHub API request failed ({error.code})") from error
        except urllib.error.URLError as error:
            raise RuntimeError("GitHub API request failed") from error

    def runs(self, status: str, pages: int = 10, *, created: str | None = None) -> list[dict[str, Any]]:
        """The repository's pull_request runs in `status` (classify_run() keeps every other event)."""
        return self.listing(status, pages, created=created)[0]

    def listing(self, status: str, pages: int = 10, *, created: str | None = None) -> tuple[list[dict[str, Any]], bool]:
        """runs(), and whether the listing reached its empty last page within PAGES."""
        result: list[dict[str, Any]] = []
        for page in range(1, pages + 1):
            params: dict[str, Any] = {"status": status, "event": "pull_request"}
            if created:
                params["created"] = created
            query = urllib.parse.urlencode(params | {"per_page": 100, "page": page})
            payload = self.request("GET", f"/repos/{self.repo}/actions/runs?{query}")
            page_runs = payload.get("workflow_runs", [])
            # A short page is not the last one: GitHub drops runs it hides from a page (98 of 100 on
            # 2026-11-19), so only an empty page ends the listing.
            if not page_runs:
                return result, True
            result.extend(page_runs)
        return result, False

    def queued_pull_request_runs(self, *, now: dt.datetime, hours: int = QUEUED_WINDOW_HOURS) -> list[dict[str, Any]]:
        """Every queued pull_request run created in the last HOURS, read in created-time windows.

        GitHub lists at most LIST_CAP runs for one query whatever total_count says: on 2026-11-19
        cmux had more than 2,500 queued runs, page 11 came back empty, and the one-query listing saw
        98 of them, none superseded, so the pass cancelled nothing. A window whose listing ends before an
        empty page is halved until each one is read whole: short pages can cap it below LIST_CAP runs (98 a
        page is 980; review of #47775, F3)."""
        seen: dict[Any, dict[str, Any]] = {}
        windows = [(now - dt.timedelta(hours=hours), now)]
        while windows:
            start, end = windows.pop()
            created = f"{start.strftime('%Y-%m-%dT%H:%M:%SZ')}..{end.strftime('%Y-%m-%dT%H:%M:%SZ')}"
            runs, whole = self.listing("queued", pages=LIST_CAP // 100, created=created)
            if not whole and end - start > dt.timedelta(minutes=1):
                middle = start + (end - start) / 2
                windows += [(start, middle), (middle, end)]
                continue
            for run in runs:
                seen[run.get("id")] = run
        return list(seen.values())

    def open_heads(self) -> dict[int, str]:
        """Every open pull request's number and head sha, paged until an empty page (at most 60 pages)."""
        heads: dict[int, str] = {}
        for page in range(1, 61):
            query = urllib.parse.urlencode({"state": "open", "per_page": 100, "page": page})
            payload = self.request("GET", f"/repos/{self.repo}/pulls?{query}")
            if not payload:
                return heads
            for pr in payload:
                heads[int(pr["number"])] = str(pr["head"]["sha"])
        raise RuntimeError("more than 6,000 open pull requests: the superseded pass would not see them all")

    def open_prs(self) -> dict[int, dict[str, Any]]:
        """Every open pull request's number -> {"sha", "draft", "labels"}, paged until an empty page."""
        prs: dict[int, dict[str, Any]] = {}
        for page in range(1, 61):
            query = urllib.parse.urlencode({"state": "open", "per_page": 100, "page": page})
            payload = self.request("GET", f"/repos/{self.repo}/pulls?{query}")
            if not payload:
                return prs
            for pr in payload:
                prs[int(pr["number"])] = pr_facts(pr)
        raise RuntimeError("more than 6,000 open pull requests: the dead-queued pass would not see them all")

    def pull_requests_for_commit(self, sha: str) -> list[dict[str, Any]]:
        path = f"/repos/{self.repo}/commits/{urllib.parse.quote(sha, safe='')}/pulls"
        return self.request("GET", path, missing_is_empty=True)


def pr_facts(pr: dict[str, Any]) -> dict[str, Any]:
    return {"sha": str(pr["head"]["sha"]), "draft": pr.get("draft") is True,
            "labels": tuple(str(label.get("name")) for label in pr.get("labels") or [] if isinstance(label, dict))}


def dead_queued_pass(janitor: GitHub, repo: str, *, cleanup: bool, limit: int) -> int:
    """Cancel (or, without CLEANUP, list) up to LIMIT queued runs classify_dead() names; 1 on any failure."""
    try:
        open_prs = janitor.open_prs()
        now = dt.datetime.now(dt.timezone.utc)
        queued = janitor.queued_pull_request_runs(now=now)
        keepers = duplicate_keepers(queued, now)
        eligible = [(run, kind) for run in sorted(queued, key=lambda r: str(r.get("created_at") or ""))
                    if (kind := classify_dead(run, open_prs, keepers, now=now))]
    except RuntimeError as error:
        print(f"stale-run-janitor: dead-queued: {error}", file=sys.stderr)
        return 1
    found: dict[str, int] = {}
    for _, kind in eligible:
        found[kind] = found.get(kind, 0) + 1
    print(f"stale-run-janitor: dead-queued {'CLEANUP' if cleanup else 'DRY-RUN'}; open_prs={len(open_prs)}; "
          f"queued={len(queued)}; eligible={len(eligible)} {json.dumps(found, sort_keys=True)}; limit={limit}")
    done: dict[str, int] = {}
    failures = 0
    for run, kind in eligible[:limit]:
        run_id = run.get("id")
        if not cleanup:
            done[kind] = done.get(kind, 0) + 1
            print(f"would cancel run {run_id} ({run.get('path')}, {str(run.get('head_sha'))[:12]}, {kind})")
            continue
        endpoint = f"/repos/{repo}/actions/runs/{run_id}"
        try:
            # The run can start, its pull request can move, close, reopen or leave draft, and a kept run can start.
            current = janitor.request("GET", endpoint)
            live = dict(open_prs)
            opted_out = False
            for number in set(_pr_numbers(current)):
                pr = janitor.request("GET", f"/repos/{repo}/pulls/{number}", missing_is_empty=True)
                if isinstance(pr, dict) and pr.get("state") == "open":
                    live[number] = pr_facts(pr)
                elif isinstance(pr, dict) and pr.get("state") == "closed":
                    live.pop(number, None)
                    # The inventory reads only open PRs' labels (review of #47775, F2).
                    if JANITOR_OPT_OUT_LABEL in pr_facts(pr)["labels"]:
                        opted_out = True
                else:
                    raise RuntimeError(f"pull request {number} unread")
            for pr in janitor.pull_requests_for_commit(str(current.get("head_sha") or "")):
                if isinstance(pr, dict) and pr.get("state") == "open" and isinstance(pr.get("number"), int):
                    live[pr["number"]] = pr_facts(pr)
            kept = {}
            if run_id in keepers:
                fresh = janitor.request("GET", f"/repos/{repo}/actions/runs/{keepers[run_id].get('id')}")
                if fresh.get("status") == "queued" and fresh.get("head_sha") == current.get("head_sha"):
                    kept = {run_id: fresh}
            again = None if opted_out else classify_dead(current, live, kept, now=dt.datetime.now(dt.timezone.utc))
            if again != kind:
                print(f"preserved run {run_id}: no longer {kind} ({again or 'kept'})")
                continue
            janitor.request("POST", endpoint + "/cancel")
            done[kind] = done.get(kind, 0) + 1
            print(f"cancelled run {run_id} ({current.get('path')}, {str(current.get('head_sha'))[:12]}, {kind})")
        except (RuntimeError, KeyError, TypeError) as error:
            failures += 1
            print(f"failed run {run_id}: {error}", file=sys.stderr)
    verb = "cancelled" if cleanup else "would_cancel"
    print(f"stale-run-janitor: dead-queued {verb}={sum(done.values())} {json.dumps(done, sort_keys=True)}; "
          f"failures={failures}")
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write(f"## Dead queued runs ({'cleanup' if cleanup else 'dry run'})\n\n"
                         f"Queued pull_request runs read: {len(queued)}; open PRs: {len(open_prs)}; limit {limit}.\n\n"
                         "| kind | eligible | " + verb.replace("_", " ") + " |\n| --- | --- | --- |\n"
                         + "".join(f"| {k} | {found[k]} | {done.get(k, 0)} |\n" for k in sorted(found))
                         + f"\nFailures: {failures}.\n")
    return 1 if failures else 0


def env_bool(name: str, default: bool = False) -> bool:
    return os.environ.get(name, "true" if default else "false").lower() in {"1", "true", "yes"}


def superseded_pass(janitor: GitHub, repo: str, *, cleanup: bool, limit: int) -> int:
    """Cancel (or, without CLEANUP, list) up to LIMIT queued runs at a superseded head; 1 on any failure."""
    try:
        open_heads = janitor.open_heads()
        now = dt.datetime.now(dt.timezone.utc)
        queued = janitor.queued_pull_request_runs(now=now)
        eligible = [run for run in queued if classify_superseded(run, open_heads, now=now)]
    except RuntimeError as error:
        print(f"stale-run-janitor: superseded: {error}", file=sys.stderr)
        return 1
    print(f"stale-run-janitor: superseded {'CLEANUP' if cleanup else 'DRY-RUN'}; open_prs={len(open_heads)}; "
          f"queued={len(queued)}; eligible={len(eligible)}; limit={limit}")
    if not cleanup:
        for run in eligible[:limit]:
            print(f"would cancel run {run.get('id')} ({run.get('path')}, {run.get('head_sha', '')[:12]}, superseded head)")
        return 0
    cancelled = failures = 0
    for run in eligible[:limit]:
        run_id = run.get("id")
        endpoint = f"/repos/{repo}/actions/runs/{run_id}"
        try:
            # The run can start, and its pull request can move back to this head, after the inventory.
            current = janitor.request("GET", endpoint)
            live = dict(open_heads)
            for number in {pr.get("number") for pr in current.get("pull_requests") or [] if isinstance(pr, dict)}:
                if number in live:
                    pr = janitor.request("GET", f"/repos/{repo}/pulls/{number}")
                    if pr.get("state") == "open":
                        live[number] = str(pr["head"]["sha"])
                    else:
                        del live[number]
            # Any other pull request pushed back to this commit since the inventory makes it a live head again.
            for pr in janitor.pull_requests_for_commit(str(current.get("head_sha") or "")):
                if isinstance(pr, dict) and pr.get("state") == "open" and isinstance(pr.get("number"), int):
                    live[pr["number"]] = str(pr["head"]["sha"])
            if not classify_superseded(current, live, now=dt.datetime.now(dt.timezone.utc)):
                print(f"preserved run {run_id}: no longer a queued run at a superseded head")
                continue
            janitor.request("POST", endpoint + "/cancel")
            cancelled += 1
            print(f"cancelled run {run_id} ({current.get('path')}, {current.get('head_sha', '')[:12]}, superseded head)")
        except (RuntimeError, KeyError, TypeError) as error:
            failures += 1
            print(f"failed run {run_id}: {error}", file=sys.stderr)
    print(f"stale-run-janitor: superseded cancelled={cancelled}; failures={failures}")
    return 1 if failures else 0


def main() -> int:
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    repo = os.environ.get("GH_REPO") or os.environ.get("GITHUB_REPOSITORY")
    if not token or not repo:
        print("stale-run-janitor: GH_TOKEN and GH_REPO are required", file=sys.stderr)
        return 2

    try:
        min_age_minutes = int(os.environ.get("MIN_AGE_MINUTES", "1440"))
        max_actions = int(os.environ.get("MAX_ACTIONS", "25"))
    except ValueError:
        print("stale-run-janitor: MIN_AGE_MINUTES and MAX_ACTIONS must be integers", file=sys.stderr)
        return 2
    if min_age_minutes < 1 or max_actions < 1:
        print("stale-run-janitor: age and action limits must be positive", file=sys.stderr)
        return 2
    if max_actions > 25:
        print("stale-run-janitor: MAX_ACTIONS must not exceed 25", file=sys.stderr)
        return 2

    cleanup_requested = env_bool("CLEANUP") and os.environ.get("GITHUB_EVENT_NAME") == "workflow_dispatch"
    janitor = GitHub(token, repo)
    if env_bool("DEAD_QUEUED") and os.environ.get("GITHUB_EVENT_NAME") == "workflow_dispatch":
        try:
            limit = int(os.environ.get("MAX_SUPERSEDED", "200"))
        except ValueError:
            limit = 0
        if not 1 <= limit <= SUPERSEDED_LIMIT_MAX:
            print(f"stale-run-janitor: MAX_SUPERSEDED must be 1..{SUPERSEDED_LIMIT_MAX}", file=sys.stderr)
            return 2
        return dead_queued_pass(janitor, repo, cleanup=cleanup_requested, limit=limit)
    if env_bool("SUPERSEDED") and os.environ.get("GITHUB_EVENT_NAME") == "workflow_dispatch":
        try:
            limit = int(os.environ.get("MAX_SUPERSEDED", "200"))
        except ValueError:
            limit = 0
        if not 1 <= limit <= SUPERSEDED_LIMIT_MAX:
            print(f"stale-run-janitor: MAX_SUPERSEDED must be 1..{SUPERSEDED_LIMIT_MAX}", file=sys.stderr)
            return 2
        return superseded_pass(janitor, repo, cleanup=cleanup_requested, limit=limit)
    now = dt.datetime.now(dt.timezone.utc)
    eligible: list[tuple[dict[str, Any], str]] = []
    # One read per commit in the inventory: on 2026-11-22 the report-only schedule read commits/{sha}/pulls for 227
    # old runs of 19 commits, twice an hour, from the GITHUB_TOKEN hour the production promote gates read. A pull
    # request that closes during the pass only shows in the next one, and cleanup reads again before it acts.
    commit_prs: dict[str, list[dict[str, Any]]] = {}
    try:
        for status in ("queued", "in_progress"):
            for run in janitor.runs(status):
                if not may_be_eligible(run, now=now, min_age_seconds=min_age_minutes * 60):
                    continue
                sha = run.get("head_sha", "")
                if sha not in commit_prs:
                    commit_prs[sha] = janitor.pull_requests_for_commit(sha)
                prs = commit_prs[sha]
                reason = classify_run(run, prs, now=now, min_age_seconds=min_age_minutes * 60)
                if reason:
                    eligible.append((run, reason))
    except RuntimeError as error:
        print(f"stale-run-janitor: {error}", file=sys.stderr)
        return 1

    mode = "CLEANUP" if cleanup_requested else "DRY-RUN"
    print(f"stale-run-janitor: {mode}; eligible={len(eligible)}; limit={max_actions}")
    if not cleanup_requested:
        for run, reason in eligible[:max_actions]:
            print(f"would process run {run.get('id')} ({run.get('status')}, {reason})")
        return 0

    processed = 0
    failures = 0
    for run, reason in eligible[:max_actions]:
        run_id = run.get("id")
        endpoint = f"/repos/{repo}/actions/runs/{run_id}"
        try:
            # Runs can complete and PRs can reopen after inventory collection.
            current = janitor.request("GET", endpoint)
            prs = janitor.pull_requests_for_commit(current.get("head_sha", ""))
            reason = classify_run(current, prs, now=dt.datetime.now(dt.timezone.utc),
                                  min_age_seconds=min_age_minutes * 60)
            if not reason:
                print(f"preserved run {run_id}: no longer eligible")
                continue
            method = "DELETE" if current.get("status") == "queued" else "POST"
            janitor.request(method, endpoint + ("/cancel" if method == "POST" else ""))
            processed += 1
            print(f"processed run {run_id} ({reason})")
        except RuntimeError as error:
            failures += 1
            print(f"failed run {run_id}: {error}", file=sys.stderr)
    print(f"stale-run-janitor: processed={processed}; failures={failures}")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
