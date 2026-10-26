#!/usr/bin/env python3
"""Is this cmux-tui artifacts push superseded, so its run can skip its work?

On 2026-10-14 the owned Macs' side lane had ~285 queued jobs, and 37% of the
queued cmux-tui artifacts runs were already superseded: 61 cmux-tui-pin-* merge
trees whose pull request had a newer head, and 24 lane-branch pushes whose
branch had moved. Nobody needs their trees: a pull request's same-tree checks
use its newest head's merge tree, and a branch's newest push publishes its own.

The workflow's concurrency group cannot drop them. A run is admitted into its
group as soon as it is queued, so GitHub replaces only a newer pending run, and
cancel-in-progress would also stop runs that are uploading. So a run asks this
script when it gets a runner (tree-preflight, before it claims its tree key)
and again when its daemon tests get a Mac, and skips its builds and daemon
tests when the answer is yes. It never cancels anything.

Superseded means, for a push event only:
  - a lane branch (any ref but main, feat-cmux-next, next-batch/* and
    cmux-tui-pin-*) whose head is no longer SHA;
  - a cmux-tui-pin-* ref at GitHub's merge commit for a pull request
    ("Merge <head> into <base>", made by cmux-next-pr-merge-tree.yml) whose
    pull request is open with a different head now, and no pull request has
    that head any more;
  - such a pin whose pull request merged into feat-cmux-next at that head, and
    no open pull request has it: feat-cmux-next's push of the merge tests its own tree, and the pin's
    daemon tests held the side lane for hours after the merge (2026-10-21);
  - a push to a cp/*, lane/* or perf/* agent branch whose head is no open pull
    request's head, unless its head commit asks for the daemon tests
    (Cmux-Daemon-Tests: run). On 2026-10-26 those branches started about 215
    cmux-tui artifacts runs an hour, 93% of them at a head no open pull request
    had, while the workflow token's hourly budget ran out. A pull request's
    same-tree checks use its merge tree (cmux-next-pr-merge-tree.yml) or the
    base tree, never the lane head, so nobody needs those trees.
main, feat-cmux-next and next-batch/* runs gate latest/ and nightly-next
promotion and are never superseded here, nor is a dispatch, a pull request run,
or a pin of anything other than a pull request merge commit (pin-cmux-tui.sh,
next_batch.py). With --key, a run that another run of the key deferred to
(a cmux-tui-tree-deferred-<key> artifact, tree-owner-wait) is not superseded:
that run waits for its tree.

Every API failure answers no: the run then does its work as before.

Usage: cmux_tui_superseded_push.py --event E --ref REF --sha SHA [--key KEY --run-id ID]
Environment: GH_TOKEN (contents, pull-requests and actions read),
GITHUB_REPOSITORY, GITHUB_API_URL (default https://api.github.com).
Prints the reason and writes stale=true|false to $GITHUB_OUTPUT. Exits 0.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

PROTECTED = ("refs/heads/main", "refs/heads/feat-cmux-next")
PIN_PREFIX = "refs/heads/cmux-tui-pin-"
# Agent branches whose pushes publish nothing unless an open pull request has that head.
UNREVIEWED_PREFIXES = ("refs/heads/cp/", "refs/heads/lane/", "refs/heads/perf/")


class ApiError(Exception):
    pass


def api(path: str) -> tuple[int, object]:
    base = os.environ.get("GITHUB_API_URL", "https://api.github.com").rstrip("/")
    repo = os.environ["GITHUB_REPOSITORY"]
    request = urllib.request.Request(
        f"{base}/repos/{repo}/{path}",
        headers={
            "Authorization": f"Bearer {os.environ.get('GH_TOKEN', '')}",
            "Accept": "application/vnd.github+json",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            return response.status, json.loads(response.read().decode() or "null")
    except urllib.error.HTTPError as error:
        return error.code, None
    except (urllib.error.URLError, OSError, ValueError) as error:
        raise ApiError(f"GET {path}: {error}") from error


def lane_verdict(ref: str, sha: str) -> tuple[bool, str]:
    branch = ref.removeprefix("refs/heads/")
    status, data = api(f"git/ref/heads/{urllib.parse.quote(branch)}")
    if status == 404:
        return False, f"{branch} no longer exists; keeping the run"
    if status != 200 or not isinstance(data, dict):
        raise ApiError(f"GET git/ref/heads/{branch}: HTTP {status}")
    head = data.get("object", {}).get("sha", "")
    if head == sha:
        return False, f"{sha[:12]} is still the head of {branch}"
    return True, f"{branch} moved to {head[:12]}; its newest push publishes that tree"


def asks_for_daemon_tests(sha: str) -> bool:
    """Whether the checked-out head commit carries the trailer Cmux-Daemon-Tests: run (daemon-policy's opt-in)."""
    try:
        value = subprocess.run(
            ["git", "log", "-1", "--format=%(trailers:key=Cmux-Daemon-Tests,valueonly)", sha],
            capture_output=True, text=True, timeout=20, check=True).stdout
    except (OSError, subprocess.SubprocessError):
        return False
    return "".join(value.split()).lower() == "run"


def unreviewed_verdict(ref: str, sha: str) -> tuple[bool, str] | None:
    """Superseded when no open pull request of this repository has SHA at its head; None asks lane_verdict."""
    if asks_for_daemon_tests(sha):
        return None
    status, data = api(f"commits/{sha}/pulls?per_page=100")
    if status != 200 or not isinstance(data, list):
        raise ApiError(f"GET commits/{sha}/pulls: HTTP {status}")
    repo = os.environ["GITHUB_REPOSITORY"]
    if any(pr.get("state") == "open" and (pr.get("head") or {}).get("sha") == sha
           and ((pr.get("head") or {}).get("repo") or {}).get("full_name") == repo for pr in data):
        return None
    # A cmux-next dispatch on the branch (#22303) probes this exact commit's tree with no base fallback,
    # so a head some dispatch already asked about keeps its publisher.
    status, data = api(f"actions/workflows/cmux-next.yml/runs?head_sha={sha}&event=workflow_dispatch&per_page=1")
    if status != 200 or not isinstance(data, dict):
        raise ApiError(f"GET cmux-next.yml dispatches of {sha}: HTTP {status}")
    if data.get("total_count") or data.get("workflow_runs"):
        return None
    branch = ref.removeprefix("refs/heads/")
    return True, (f"no open pull request has {sha[:12]} ({branch}) at its head and no cmux-next dispatch "
                  "asked for it; a pull request's same-tree checks use its merge tree or the base tree. "
                  "To publish this tree anyway, add the trailer Cmux-Daemon-Tests: run, dispatch "
                  "cmux-tui-artifacts.yml on the branch, or dispatch cmux-next.yml before pushing")


def pin_verdict(sha: str) -> tuple[bool, str]:
    # Both jobs check out at depth 1, where git shows the pin commit without
    # parents (run 38608893139), so the parents and subject come from the API.
    status, data = api(f"commits/{sha}")
    if status != 200 or not isinstance(data, dict):
        raise ApiError(f"GET commits/{sha}: HTTP {status}")
    parents = [str((parent or {}).get("sha", "")) for parent in data.get("parents") or []]
    subject = str((data.get("commit") or {}).get("message") or "").partition("\n")[0].strip()
    if len(parents) != 2 or subject != f"Merge {parents[1]} into {parents[0]}":
        return False, "the pin is not a pull request merge commit; keeping the run"
    head = parents[1]
    status, data = api(f"commits/{head}/pulls?per_page=100")
    if status != 200 or not isinstance(data, list):
        raise ApiError(f"GET commits/{head}/pulls: HTTP {status}")
    repo = os.environ["GITHUB_REPOSITORY"]
    owners = [pr for pr in data if pr.get("head", {}).get("sha") == head]
    if any(pr.get("state") == "open" for pr in owners):
        return False, f"{head[:12]} is still a pull request head"
    merged = [pr for pr in owners if pr.get("merged_at") and (pr.get("base") or {}).get("ref") == "feat-cmux-next"
              and (pr.get("head", {}).get("repo") or {}).get("full_name") == repo]
    if merged:
        return True, f"#{merged[0].get('number')} merged at {head[:12]}; feat-cmux-next's push of it tests its own tree"
    if owners:
        return False, f"{head[:12]} is the head of a pull request closed without merging; keeping the run"
    moved = [pr for pr in data if pr.get("state") == "open"
             and (pr.get("head", {}).get("repo") or {}).get("full_name") == repo]
    if not moved:
        return False, f"no open pull request has {head[:12]}; keeping the run"
    pr = moved[0]
    return True, f"#{pr.get('number')} moved from {head[:12]} to {pr['head']['sha'][:12]}; its newer merge tree is pinned on its own"


def deferred_to(key: str, run_id: str) -> str:
    """A run of the key that deferred to this one, or ""."""
    status, data = api(f"actions/artifacts?name=cmux-tui-tree-deferred-{key}&per_page=100")
    if status != 200 or not isinstance(data, dict):
        raise ApiError(f"GET deferred artifacts of {key}: HTTP {status}")
    for artifact in data.get("artifacts", []):
        other = str((artifact.get("workflow_run") or {}).get("id", ""))
        if not artifact.get("expired") and other and other != run_id:
            return other
    return ""


def verdict(event: str, ref: str, sha: str, key: str, run_id: str) -> tuple[bool, str]:
    if event != "push":
        return False, f"a {event} run is never superseded here"
    if ref in PROTECTED or ref.startswith("refs/heads/next-batch/"):
        return False, f"{ref} gates promotion; its runs are kept"
    unreviewed = unreviewed_verdict(ref, sha) if ref.startswith(UNREVIEWED_PREFIXES) else None
    if unreviewed is not None:
        stale, reason = unreviewed
    else:
        stale, reason = pin_verdict(sha) if ref.startswith(PIN_PREFIX) else lane_verdict(ref, sha)
    if stale and key:
        waiting = deferred_to(key, run_id)
        if waiting:
            return False, f"{reason}, but run {waiting} deferred tree {key[:12]} to this run; keeping it"
    return stale, reason


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--event", required=True)
    parser.add_argument("--ref", required=True)
    parser.add_argument("--sha", required=True)
    parser.add_argument("--key", default="")
    parser.add_argument("--run-id", default="")
    args = parser.parse_args(argv)
    if not re.fullmatch(r"[0-9a-f]{40}", args.sha) or (args.key and not re.fullmatch(r"[0-9a-f]{40}", args.key)):
        print("error: --sha and --key must be 40-hex", file=sys.stderr)
        return 2
    try:
        stale, reason = verdict(args.event, args.ref, args.sha, args.key, args.run_id)
    except (ApiError, KeyError) as error:
        stale, reason = False, f"could not tell ({error}); keeping the run"
        print(f"::warning title=superseded check::{reason}")
    if stale:
        print(f"::notice title=superseded push::{args.sha[:12]} is superseded: {reason}. This run skips its builds and daemon tests.")
    else:
        print(f"Not superseded: {reason}")
    output = os.environ.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a", encoding="utf-8") as handle:
            handle.write(f"stale={'true' if stale else 'false'}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
