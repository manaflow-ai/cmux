#!/usr/bin/env python3
"""Find a recorded pass of a cmux-next job on the same inputs.

A job that passes with `vars.CI_NEXT_JOB_REUSE` uploads an Actions artifact named
after its input key (scripts/ci/job_input_fingerprint.py: `job-pass-<job>-<hash>`).
Artifacts are listed repository-wide (GET /repos/{repo}/actions/artifacts?name=),
so a pull request finds the passes the base and other pull requests recorded; a
GitHub cache entry is readable only from its own ref and the base.

Any run can upload an artifact, a fork pull request's run included, so a pass
counts only when its run came from this repository: the run's repository and
head repository are both GITHUB_REPOSITORY_ID. The workflow uploads a pass only
from same-repository runs, and a fork's own upload is never taken here. The
planner's enforcement path can additionally require a named branch and event;
that path accepts only green producers from the trusted feat-cmux-next push.

`lookup --key K` prints `hit=true`, `run_url=` and `sha=` for $GITHUB_OUTPUT,
or `hit=false`. Every failure (no token, no repository id, an API error, a key
that is not a pass key) is a miss with a notice: the job then runs.
`--artifacts-json FILE` reads the listing from a file instead of the API.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.parse
import urllib.error
import urllib.request

KEY = re.compile(r"^job-pass-[a-z0-9-]+-[0-9a-f]{40}$")


class Miss(Exception):
    """No pass can be trusted."""


def pick(artifacts: list[dict], key: str, repository_id: str,
         trusted_branch: str | None = None, trusted_event: str | None = None,
         run_reader=None, trusted_workflow: str | None = None) -> dict | None:
    """The newest unexpired artifact from a trusted producer run."""
    trusted = []
    for item in artifacts:
        run = item.get("workflow_run") or {}
        if item.get("name") != key or item.get("expired"):
            continue
        repository = run.get("repository_id")
        head_repository = run.get("head_repository_id")
        if (repository is not None and str(repository) != repository_id) or \
                (head_repository is not None and str(head_repository) != repository_id):
            continue
        if trusted_event is None and (repository is None or head_repository is None):
            # Preserve the legacy lookup's fail-closed repository boundary;
            # only the narrowed planner path may fill omitted fields from the
            # authoritative run endpoint below.
            continue
        if trusted_branch is not None and run.get("head_branch") not in (None, trusted_branch):
            continue
        # The artifact-list response commonly omits ``event`` (and can omit
        # other producer identity fields).  A narrowed planner lookup must
        # resolve the authoritative workflow-run record instead of treating a
        # missing field as a trusted push.  Tests and offline callers provide a
        # run_reader; production uses the Actions API below.
        if trusted_event is not None:
            event = run.get("event")
            details = run_reader(run.get("id")) if run_reader is not None else None
            if details is not None:
                event = details.get("event")
                if details.get("head_branch") != trusted_branch:
                    continue
                repo = details.get("repository") or {}
                head_repo = details.get("head_repository") or {}
                if str(repo.get("id", details.get("repository_id"))) != repository_id:
                    continue
                if str(head_repo.get("id", details.get("head_repository_id"))) != repository_id:
                    continue
                if details.get("status") != "completed" or details.get("conclusion") != "success":
                    continue
                if trusted_workflow is not None and details.get("path") != trusted_workflow:
                    continue
            else:
                # A trusted planner lookup never falls back to artifact-list
                # metadata.  The list can be stale or incomplete, and an API
                # miss must remain a miss.
                continue
            if event != trusted_event:
                continue
        trusted.append(item)
    return max(trusted, key=lambda item: item.get("created_at") or "", default=None)


def note_call(headers, method: str, path: str) -> None:
    """One `gh-call` line for a response already received (scripts/ci/gh_call_log.py reads them).

    Inline rather than imported: this script is often checked out alone (sparse). Reads only headers this
    call already has; no request of its own, nothing outside Actions, and it never raises."""
    if os.environ.get("GITHUB_ACTIONS") != "true":
        return
    try:
        import datetime as _dt
        get = (lambda name: str((headers.get(name) if headers is not None else "") or "-").strip() or "-")
        fields = (_dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                  os.environ.get("GITHUB_WORKFLOW", ""), os.environ.get("GITHUB_JOB", ""),
                  get("X-RateLimit-Resource"), get("X-RateLimit-Used"), get("X-RateLimit-Remaining"),
                  get("X-RateLimit-Reset"), f"{method.upper()} {path.split('?', 1)[0]}")
        print("\t".join(["gh-call", *(" ".join(str(f).split()) or "-" for f in fields)]), file=sys.stderr, flush=True)
    except Exception:  # noqa: BLE001 - logging only
        pass


def listing(key: str, path: str | None) -> list[dict]:
    if path:
        text = open(path, encoding="utf-8").read()
    else:
        token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
        repo = os.environ.get("GITHUB_REPOSITORY")
        if not token or not repo:
            raise Miss("no token or repository to list artifacts with")
        api = os.environ.get("GITHUB_API_URL", "https://api.github.com")
        url = f"{api}/repos/{repo}/actions/artifacts?" + urllib.parse.urlencode({"name": key, "per_page": 100})
        request = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}",
                                                       "Accept": "application/vnd.github+json",
                                                       "X-GitHub-Api-Version": "2022-11-28"})
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                note_call(response.headers, "GET", f"/repos/{repo}/actions/artifacts")
                text = response.read().decode()
        except OSError as error:
            if isinstance(error, urllib.error.HTTPError):
                note_call(error.headers, "GET", f"/repos/{repo}/actions/artifacts")
            raise Miss(f"listing artifacts failed: {error}") from error
    try:
        data = json.loads(text)
        artifacts = data["artifacts"]
    except (ValueError, KeyError, TypeError) as error:
        raise Miss(f"the artifact listing does not parse: {error}") from error
    if not isinstance(artifacts, list):
        raise Miss("the artifact listing has no list")
    return artifacts


def run_listing(path: str | None) -> dict[int, dict] | None:
    """Read an optional fixture of authoritative workflow-run records."""
    if not path:
        return None
    try:
        data = json.loads(open(path, encoding="utf-8").read())
    except (OSError, ValueError) as error:
        raise Miss(f"the workflow-run listing does not parse: {error}") from error
    rows = data.get("workflow_runs", data) if isinstance(data, dict) else data
    if not isinstance(rows, list):
        raise Miss("the workflow-run listing has no list")
    result = {}
    for row in rows:
        if isinstance(row, dict) and row.get("id") is not None:
            result[int(row["id"])] = row
    return result


def producer_run(run_id: object, fixture: dict[int, dict] | None) -> dict | None:
    if run_id is None:
        return None
    if fixture is not None:
        return fixture.get(int(run_id))
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    repo = os.environ.get("GITHUB_REPOSITORY")
    if not token or not repo:
        return None
    api = os.environ.get("GITHUB_API_URL", "https://api.github.com")
    path = f"/repos/{repo}/actions/runs/{int(run_id)}"
    request = urllib.request.Request(f"{api}{path}", headers={
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28"})
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            note_call(response.headers, "GET", path)
            value = json.loads(response.read().decode())
    except OSError as error:
        if isinstance(error, urllib.error.HTTPError):
            note_call(error.headers, "GET", path)
        return None
    return value if isinstance(value, dict) else None


def lookup(key: str, path: str | None, trusted_branch: str | None = None,
           trusted_event: str | None = None, runs_path: str | None = None,
           trusted_workflow: str | None = None) -> dict[str, str]:
    if not KEY.match(key):
        raise Miss(f"{key!r} is not a pass key")
    repository_id = os.environ.get("GITHUB_REPOSITORY_ID", "").strip()
    if not repository_id:
        raise Miss("GITHUB_REPOSITORY_ID is not set, so no pass can be checked")
    fixture = run_listing(runs_path)
    reader = (lambda run_id: producer_run(run_id, fixture)) if trusted_event is not None else None
    found = pick(listing(key, path), key, repository_id, trusted_branch, trusted_event, reader, trusted_workflow)
    if found is None:
        return {"hit": "false"}
    run = found["workflow_run"]
    server = os.environ.get("GITHUB_SERVER_URL", "https://github.com")
    return {"hit": "true", "run_url": f"{server}/{os.environ.get('GITHUB_REPOSITORY', '')}/actions/runs/{run['id']}",
            "sha": str(run.get("head_sha") or "")}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    find = sub.add_parser("lookup", help="print hit=true|false and the run that passed")
    find.add_argument("--key", required=True)
    find.add_argument("--artifacts-json", help="read the artifact listing from this file")
    find.add_argument("--trusted-branch", help="require the producer run's head branch")
    find.add_argument("--trusted-event", help="require the producer run's event")
    find.add_argument("--runs-json", help="authoritative workflow-run records for offline tests")
    find.add_argument("--trusted-workflow", help="require the producer workflow path")
    args = parser.parse_args(argv)
    try:
        outputs = lookup(args.key, args.artifacts_json, args.trusted_branch, args.trusted_event,
                         args.runs_json, args.trusted_workflow)
    except Miss as why:
        print(f"::notice title=No reused pass::{why}", file=sys.stderr)
        outputs = {"hit": "false"}
    for name, value in outputs.items():
        print(f"{name}={value}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
