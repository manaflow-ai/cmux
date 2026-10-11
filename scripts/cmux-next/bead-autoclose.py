#!/usr/bin/env python3
"""Close the beads that merged pull requests name, so a landing never leaves its bead open.

Reads the pull requests merged into feat-cmux-next or main since the last run
(GitHub GraphQL search, one query per run; never a REST polling loop), takes
every bead id in each title (cx-xxxx, cx-xxxx.N), and for each open bead:
  - closes it with "landed <sha> (#N): <title>", as its assignee (the claim
    guard refuses anyone else without --force, which this never passes) or as
    leo when it is unassigned;
  - only comments on an epic, a bead with open children, or a bead another
    open pull request still names: the landing is part of it, not all of it.
    A bead whose next pull request opens only after this merge still closes;
    its reason says to reopen it then.
A closed or unknown bead is skipped. The board is reached through BEADS_SSH_HOST
(the host whose ~/agent-tasks holds the board) or, for tests, BEADS_BD_COMMAND
(an executable run with bd's arguments); with neither set it refuses to run.
State (the last merge time handled) lives in BEAD_AUTOCLOSE_STATE.

Usage: scripts/cmux-next/bead-autoclose.py [--dry-run] [--since ISO8601]
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

REPO = "manaflow-ai/cmux"
BASES = ("feat-cmux-next", "main")
BEAD_ID = re.compile(r"\bcx-[a-z0-9]{2,8}(?:\.[0-9]+)*\b")
QUERY = """
query($q: String!, $after: String) {
  search(query: $q, type: ISSUE, first: 100, after: $after) {
    pageInfo { hasNextPage endCursor }
    nodes { ... on PullRequest { number title mergedAt mergeCommit { oid } baseRefName } }
  }
}
"""


def merged_pull_requests(since: str) -> list[dict]:
    pulls, after = [], None
    base = " ".join(f"base:{name}" for name in BASES)
    query = f"repo:{REPO} is:pr is:merged merged:>={since} {base}"
    while True:
        args = ["gh", "api", "graphql", "-f", f"query={QUERY}", "-f", f"q={query}"]
        if after:
            args += ["-f", f"after={after}"]
        page = json.loads(subprocess.run(args, check=True, capture_output=True, text=True).stdout)
        search = page["data"]["search"]
        pulls += [node for node in search["nodes"] if node and node.get("baseRefName") in BASES]
        if not search["pageInfo"]["hasNextPage"]:
            return sorted(pulls, key=lambda pull: pull["mergedAt"])
        after = search["pageInfo"]["endCursor"]


def open_pull_requests_naming(bead_id: str) -> list[int]:
    query = f'repo:{REPO} is:pr is:open "{bead_id}" in:title'
    args = ["gh", "api", "graphql", "-f", f"query={QUERY}", "-f", f"q={query}"]
    page = json.loads(subprocess.run(args, check=True, capture_output=True, text=True).stdout)
    return [node["number"] for node in page["data"]["search"]["nodes"]
            if node and bead_id in BEAD_ID.findall(node["title"])]


def bd(*args: str) -> subprocess.CompletedProcess:
    command = os.environ.get("BEADS_BD_COMMAND")
    if command:
        return subprocess.run([command, *args], capture_output=True, text=True)
    host = os.environ["BEADS_SSH_HOST"]
    remote = "cd ~/agent-tasks && bd " + " ".join(shlex.quote(arg) for arg in args)
    return subprocess.run(["ssh", host, remote], capture_output=True, text=True)


def bd_json(*args: str):
    result = bd(*args, "--json")
    if result.returncode != 0:
        return None
    try:
        return json.loads(result.stdout)
    except ValueError:
        return None


def handle(pull: dict, bead_id: str, dry_run: bool) -> str:
    shown = bd_json("show", bead_id)
    if not shown:
        return f"skip {bead_id}: not on the board"
    bead = shown[0] if isinstance(shown, list) else shown
    if bead.get("status") == "closed":
        return f"skip {bead_id}: already closed"
    sha = (pull.get("mergeCommit") or {}).get("oid", "")[:12]
    landed = f"landed {sha} (#{pull['number']}): {pull['title']}"
    assignee = bead.get("assignee") or ""
    actor = assignee if assignee and assignee != "unassigned" else "leo"
    children = bd_json("children", bead_id) or []
    open_children = [child["id"] for child in children if child.get("status") != "closed"]
    still_open = open_pull_requests_naming(bead_id)
    why = ("an epic" if bead.get("issue_type") == "epic"
           else f"open children {', '.join(open_children)}" if open_children
           else f"open pull requests {', '.join(f'#{n}' for n in still_open)}" if still_open
           else "")
    if why:
        if not dry_run:
            bd("--actor", actor, "comment", bead_id, f"{landed} (part of this bead: {why}; not closed)")
        return f"comment {bead_id} as {actor}: {why}"
    if not dry_run:
        result = bd("--actor", actor, "close", bead_id, "--reason",
                    f"{landed} [auto-closed on merge; reopen if more of it lands]")
        if result.returncode != 0:
            return f"failed {bead_id} as {actor}: {(result.stderr or result.stdout).strip()}"
    return f"close {bead_id} as {actor}: {landed}"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--dry-run", action="store_true", help="print what it would do; change nothing")
    parser.add_argument("--since", help="merge time to start from (default: the state file, else 24 h ago)")
    args = parser.parse_args()
    if not os.environ.get("BEADS_BD_COMMAND") and not os.environ.get("BEADS_SSH_HOST"):
        print("bead-autoclose: set BEADS_SSH_HOST (or BEADS_BD_COMMAND for tests)", file=sys.stderr)
        return 2
    state = Path(os.environ.get("BEAD_AUTOCLOSE_STATE",
                                Path.home() / ".local/state/cmux-bead-autoclose/last-merged-at"))
    since = args.since or (state.read_text().strip() if state.exists() else "")
    if not since:
        since = (datetime.now(timezone.utc) - timedelta(hours=24)).strftime("%Y-%m-%dT%H:%M:%SZ")
    last = since
    for pull in merged_pull_requests(since):
        for bead_id in dict.fromkeys(BEAD_ID.findall(pull["title"])):
            print(f"#{pull['number']} {handle(pull, bead_id, args.dry_run)}")
        last = max(last, pull["mergedAt"])
    if not args.dry_run:
        state.parent.mkdir(parents=True, exist_ok=True)
        state.write_text(last + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
