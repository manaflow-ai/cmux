#!/usr/bin/env python3
"""Delete GitHub Actions artifacts that only fed a job in their own run, once that run is old.

    actions_artifact_prune.py --repo OWNER/NAME [--delete] [--max-deletes N]

Until cmux#19180 (feat-cmux-next, 2026-10-11), cmux-tui-build-package.yml set no retention-days, so
every push's binaries, relay binaries, npm-packages and pypi-wheels kept the repository's 90-day
default, and gallery evidence stages kept 14 days. feat-cmux-next uploads now expire on their own (3
days, 1 for gallery stages); this deletes the backlog, main's copies, and anything a later caller
forgets to cap.

Rules, by exact artifact name (the repository-wide artifact list returns HTTP 500 at this size, so
each name is listed on its own):

  cmux-tui-<target>, cmux-relay-<target>, chatmux-relay-<target>,
  cmux-agent-screen-detection-<target>, npm-packages, pypi-wheels      older than 3 days
  gallery-stage-<stage>-<shard>                                         older than 1 day

An artifact from a run of cmux-tui-release.yml, cmux-tui-nightly.yml or relay-publish-npm.yml is kept
for 30 days, because tui-publish-npm.yml and tui-publish-pypi.yml download those by run id. If
cmux-tui-release.yml cannot be found the run stops: a rename must not quietly drop that protection.

Without --delete this is a dry run: it lists and reports, and sends no DELETE. One run sends at most
--max-deletes deletes, paced under GitHub's secondary limit (a DELETE costs 5 of 900 points a minute),
and stops cleanly when fewer than 50 API calls remain in the hour or GitHub asks it to slow down, so
a backlog drains over several hourly runs. Each name is read from its oldest page forward and stops
at the first page entirely inside its window. An artifact already gone (GitHub expired it between
the list and the delete) counts as done. The token comes from GITHUB_TOKEN.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

API = "https://api.github.com"
TARGETS = ("x86_64-unknown-linux-musl", "aarch64-unknown-linux-musl", "x86_64-apple-darwin", "aarch64-apple-darwin")
BUILD_DAYS = 3
STAGE_DAYS = 1
RELEASE_DAYS = 30
QUOTA_FLOOR = 50  # API calls left in the hour when a run stops deleting
RELEASE_WORKFLOWS = ("cmux-tui-release.yml", "cmux-tui-nightly.yml", "relay-publish-npm.yml")
REQUIRED_WORKFLOW = "cmux-tui-release.yml"  # the publish workflows accept only its runs
DELETE_INTERVAL = 0.4  # seconds between deletes: at most 150 a minute, 750 of the 900 points


class SlowDown(Exception):
    """GitHub's secondary rate limit: stop this run; the next one continues."""


def rules() -> dict[str, int]:
    """Artifact name -> days it may live."""
    names = {f"cmux-tui-{t}": BUILD_DAYS for t in TARGETS + ("x86_64-pc-windows-gnu",)}
    for family in ("cmux-relay", "chatmux-relay", "cmux-agent-screen-detection"):
        names.update({f"{family}-{t}": BUILD_DAYS for t in TARGETS})
    names.update({"npm-packages": BUILD_DAYS, "pypi-wheels": BUILD_DAYS})
    names.update({f"gallery-stage-{s}-{n}": STAGE_DAYS for s in ("base", "head", "repeat") for n in range(4)})
    return names


class GitHub:
    def __init__(self, repo: str, token: str):
        self.repo, self.token = repo, token
        self.calls = 0
        self.remaining: int | None = None

    def request(self, method: str, path: str, query: dict | None = None):
        url = f"{API}/repos/{self.repo}{path}" + (f"?{urllib.parse.urlencode(query)}" if query else "")
        request = urllib.request.Request(url, method=method, headers={
            "Authorization": f"Bearer {self.token}", "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28"})
        self.calls += 1
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                body = response.read()
                remaining = response.headers.get("X-RateLimit-Remaining")
        except urllib.error.HTTPError as error:
            if error.code == 429 or (error.code == 403 and (
                    error.headers.get("Retry-After") or error.headers.get("X-RateLimit-Remaining") == "0")):
                raise SlowDown(f"{method} {path}: HTTP {error.code}") from error
            raise
        if remaining is not None and remaining.isdigit():
            self.remaining = int(remaining)
        return json.loads(body) if body else None

    def artifact_pages(self, name: str):
        """Pages of one name's artifacts, oldest page first. The API lists newest first, so walking
        from the last page back means a delete never shifts a page still to be read."""
        first = self.request("GET", "/actions/artifacts", {"name": name, "per_page": 100, "page": 1})
        pages = max(1, -(-int(first.get("total_count", 0)) // 100))
        for page in range(pages, 0, -1):
            data = first if page == 1 else self.request(
                "GET", "/actions/artifacts", {"name": name, "per_page": 100, "page": page})
            yield data.get("artifacts", [])

    def runs_since(self, workflow: str, since: dt.datetime) -> list[int]:
        ids, page = [], 1
        while True:
            try:
                data = self.request("GET", f"/actions/workflows/{workflow}/runs",
                                    {"created": f">={since.strftime('%Y-%m-%d')}", "per_page": 100, "page": page})
            except urllib.error.HTTPError as error:
                # A workflow not on the default branch has no runs to keep, except the one that must exist.
                if error.code == 404 and workflow != REQUIRED_WORKFLOW:
                    return ids
                raise
            batch = data.get("workflow_runs", [])
            ids += [run["id"] for run in batch]
            if len(batch) < 100:
                return ids
            page += 1

    def delete(self, artifact_id: int) -> None:
        try:
            self.request("DELETE", f"/actions/artifacts/{artifact_id}")
        except urllib.error.HTTPError as error:
            if error.code not in (404, 410):  # already gone is done
                raise
        time.sleep(DELETE_INTERVAL)


def created(artifact: dict) -> dt.datetime:
    return dt.datetime.fromisoformat(artifact["created_at"].replace("Z", "+00:00"))


def expiring(artifact: dict, now: dt.datetime) -> bool:
    stamp = artifact.get("expires_at")
    return bool(stamp) and dt.datetime.fromisoformat(stamp.replace("Z", "+00:00")) <= now


def prune(api, now: dt.datetime, *, delete: bool, max_deletes: int) -> dict:
    since = now - dt.timedelta(days=RELEASE_DAYS)
    # Read every protected run id before the first delete: a failure here must stop the run, not
    # leave release artifacts unprotected.
    protected = {run for workflow in RELEASE_WORKFLOWS for run in api.runs_since(workflow, since)}
    summary = {"protected_runs": len(protected), "candidates": 0, "candidate_bytes": 0,
               "deleted": 0, "deleted_bytes": 0, "kept_release": 0, "capped": False, "by_name": {}}
    for name, days in rules().items():
        cutoff = now - dt.timedelta(days=days)
        row = summary["by_name"].setdefault(name, {"candidates": 0, "bytes": 0})
        if summary["capped"] or low_quota(api):
            summary["capped"] = True
            break
        try:
            capped = prune_name(api, name, cutoff, now, since, protected, row, summary,
                                delete=delete, max_deletes=max_deletes)
        except SlowDown as error:
            print(f"stopping: {error}", file=sys.stderr)
            capped = True
        summary["capped"] = summary["capped"] or capped
    return summary


def prune_name(api, name, cutoff, now, since, protected, row, summary, *, delete, max_deletes) -> bool:
    """True when this run must stop here (delete cap or API quota)."""
    for page in api.artifact_pages(name):
        fresh = 0
        for artifact in sorted(page, key=created):
            if artifact.get("expired") or expiring(artifact, now) or artifact.get("name") != name:
                continue
            if created(artifact) >= cutoff:
                fresh += 1
                continue
            run = (artifact.get("workflow_run") or {}).get("id")
            if run in protected and created(artifact) >= since:
                summary["kept_release"] += 1
                continue
            size = int(artifact.get("size_in_bytes") or 0)
            row["candidates"] += 1
            row["bytes"] += size
            summary["candidates"] += 1
            summary["candidate_bytes"] += size
            if not delete:
                continue
            if summary["deleted"] >= max_deletes or low_quota(api):
                return True
            api.delete(artifact["id"])
            summary["deleted"] += 1
            summary["deleted_bytes"] += size
        # Pages run oldest to newest: once a whole page is inside its window, the rest are too.
        if page and fresh == len(page):
            return False
        if low_quota(api):
            return True
    return False


def low_quota(api) -> bool:
    remaining = getattr(api, "remaining", None)
    return remaining is not None and remaining < QUOTA_FLOOR


def render(summary: dict, delete: bool) -> str:
    gib = lambda b: f"{b / 1024 ** 3:.1f} GiB"
    lines = [f"{'deleted' if delete else 'would delete'} "
             f"{summary['deleted'] if delete else summary['candidates']} artifacts, "
             f"{gib(summary['deleted_bytes'] if delete else summary['candidate_bytes'])} "
             f"(candidates {summary['candidates']}, {gib(summary['candidate_bytes'])}); "
             f"kept {summary['kept_release']} from {summary['protected_runs']} release runs"
             + ("; capped, the rest go next run" if summary["capped"] else "")]
    for name, row in sorted(summary["by_name"].items(), key=lambda kv: -kv[1]["bytes"]):
        if row["candidates"]:
            lines.append(f"  {name}: {row['candidates']} artifacts, {gib(row['bytes'])}")
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", required=True)
    parser.add_argument("--delete", action="store_true")
    parser.add_argument("--max-deletes", type=int, default=850)
    args = parser.parse_args(argv)
    token = os.environ.get("GITHUB_TOKEN", "")
    if not token:
        raise SystemExit("GITHUB_TOKEN is required")
    api = GitHub(args.repo, token)
    summary = prune(api, dt.datetime.now(dt.timezone.utc), delete=args.delete, max_deletes=args.max_deletes)
    print(render(summary, args.delete))
    print(f"API calls: {api.calls}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
