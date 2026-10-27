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
from same-repository runs, and a fork's own upload is never taken here.

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


def pick(artifacts: list[dict], key: str, repository_id: str) -> dict | None:
    """The newest unexpired artifact named `key` whose run came from this repository."""
    trusted = []
    for item in artifacts:
        run = item.get("workflow_run") or {}
        if item.get("name") != key or item.get("expired"):
            continue
        if str(run.get("repository_id")) != repository_id or str(run.get("head_repository_id")) != repository_id:
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


def lookup(key: str, path: str | None) -> dict[str, str]:
    if not KEY.match(key):
        raise Miss(f"{key!r} is not a pass key")
    repository_id = os.environ.get("GITHUB_REPOSITORY_ID", "").strip()
    if not repository_id:
        raise Miss("GITHUB_REPOSITORY_ID is not set, so no pass can be checked")
    found = pick(listing(key, path), key, repository_id)
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
    args = parser.parse_args(argv)
    try:
        outputs = lookup(args.key, args.artifacts_json)
    except Miss as why:
        print(f"::notice title=No reused pass::{why}", file=sys.stderr)
        outputs = {"hit": "false"}
    for name, value in outputs.items():
        print(f"{name}={value}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
