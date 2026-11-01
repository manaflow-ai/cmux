#!/usr/bin/env python3
"""Close the beads that merged pull requests name, so a landing never leaves its bead open.

Reads the pull requests merged into feat-cmux-next or main since the last run
(GitHub GraphQL search, one query per run; never a REST polling loop), takes
the beads each one names in its title, body, or commits, and for each open bead closes it only when the
landing says it is the whole bead:
  - the title or body says "closes", "fixes" or "resolves" <bead> (the
    convention for the final pull request of a bead), or
  - the title names the bead with no part or slice marker ("part 2", "2/3",
    "slice", "partial", "wip", ...) and no other open pull request names it,
and the bead is not an epic and has no open children. It closes with
"landed <sha> (#N): <title>" as `--actor leo`. Any other landing gets a bd
comment with the pull request link: a partial close is worse than none. A closed
or unknown bead is skipped. Open
pull requests on feat-cmux-next that name no bead get a task created from
their title, with the pull request as its external reference. That reference
is the whole link: nothing is written on the pull request (no comment, no status
line, no workflow dispatch), and a pull request a bead already names by its
external reference gets no second one. The board is reached through BEADS_SSH_HOST
(the host whose ~/agent-tasks holds the board) or, for tests, BEADS_BD_COMMAND
(an executable run with bd's arguments); with neither set it refuses to run.
State lives in BEAD_AUTOCLOSE_STATE: the latest merge handled, the pull
requests handled within OVERLAP of it, and open pull requests already checked
for bead creation. Each run searches from OVERLAP before that merge (search
indexes merges late) and skips the pull requests already handled, so a merge
is never handled twice. A board ssh cannot reach stops the run with its merges
and open pull requests unhandled; the next run retries them.

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
OVERLAP = timedelta(hours=1)
BEAD_ID = re.compile(r"\bcx-[a-z0-9]{2,8}(?:\.[0-9]+)*\b")
CLOSES = re.compile(r"\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\b:?\s+(" + BEAD_ID.pattern[2:] + r")", re.I)
PART = re.compile(r"\b(?:part|slice|step|phase|stage)\s*\d+|\b\d+\s*/\s*\d+\b|\b(?:partial|wip|slice|follow-?up)\b", re.I)
QUERY = """
query($q: String!, $after: String) {
  search(query: $q, type: ISSUE, first: 100, after: $after) {
    pageInfo { hasNextPage endCursor }
    nodes { ... on PullRequest {
      id number title body url mergedAt createdAt mergeCommit { oid } baseRefName
      commits(first: 100) { nodes { commit { message } } }
      comments(first: 50) { nodes { body } }
    } }
  }
}
"""


def merged_pull_requests(since: str) -> list[dict]:
    pulls, after = [], None
    # Search once, then filter the two accepted target branches locally. GitHub
    # search treats repeated `base:` qualifiers as AND, which would match none.
    query = f"repo:{REPO} is:pr is:merged merged:>={since}"
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
    query = f'repo:{REPO} is:pr is:open "{bead_id}" base:feat-cmux-next'
    args = ["gh", "api", "graphql", "-f", f"query={QUERY}", "-f", f"q={query}"]
    page = json.loads(subprocess.run(args, check=True, capture_output=True, text=True).stdout)
    return [node["number"] for node in page["data"]["search"]["nodes"]
            if node and bead_id in beads_named(node)]


def open_pull_requests() -> list[dict]:
    pulls, after = [], None
    query = f"repo:{REPO} is:pr is:open base:feat-cmux-next"
    while True:
        args = ["gh", "api", "graphql", "-f", f"query={QUERY}", "-f", f"q={query}"]
        if after:
            args += ["-f", f"after={after}"]
        page = json.loads(subprocess.run(args, check=True, capture_output=True, text=True).stdout)
        search = page["data"]["search"]
        pulls.extend(node for node in search["nodes"] if node and node.get("baseRefName") == "feat-cmux-next")
        if not search["pageInfo"]["hasNextPage"]:
            return pulls
        after = search["pageInfo"]["endCursor"]


class BoardUnreachable(Exception):
    pass


def bd(*args: str) -> subprocess.CompletedProcess:
    command = os.environ.get("BEADS_BD_COMMAND")
    if command:
        result = subprocess.run([command, *args], capture_output=True, text=True)
    else:
        host = os.environ["BEADS_SSH_HOST"]
        remote = "cd ~/agent-tasks && bd " + " ".join(shlex.quote(arg) for arg in args)
        result = subprocess.run(["ssh", host, remote], capture_output=True, text=True)
    if result.returncode == 255:  # ssh's own failure; bd exits 1
        raise BoardUnreachable((result.stderr or result.stdout).strip())
    return result


def bd_json(*args: str):
    result = bd(*args, "--json")
    if result.returncode != 0:
        return None
    try:
        return json.loads(result.stdout)
    except ValueError:
        return None


def explicit_closes(pull: dict) -> list[str]:
    return [match.lower() for match in CLOSES.findall(f"{pull['title']}\n{pull.get('body') or ''}")]


def beads_named(pull: dict, *, include_comments: bool = False) -> list[str]:
    texts = [pull.get("title") or "", pull.get("body") or ""]
    texts.extend(
        (commit.get("message") or (commit.get("commit") or {}).get("message") or "")
        for commit in (pull.get("commits") or {}).get("nodes", [])
    )
    if include_comments:
        texts.extend(comment.get("body") or "" for comment in (pull.get("comments") or {}).get("nodes", []))
    return list(dict.fromkeys(match.lower() for text in texts for match in BEAD_ID.findall(text)))


def board_pull_request_refs() -> set[str]:
    """The pull request links the board's beads (closed ones too) hold as external references."""
    beads = bd_json("list", "--all", "--limit", "0", "--external-contains", f"github.com/{REPO}/pull/")
    if beads is None:
        raise BoardUnreachable("bd list failed")
    return {str(bead.get("external_ref") or "").strip() for bead in beads}


def handle(pull: dict, bead_id: str, dry_run: bool) -> str:
    shown = bd_json("show", bead_id)
    if not shown:
        return f"skip {bead_id}: not on the board"
    bead = shown[0] if isinstance(shown, list) else shown
    if bead.get("status") == "closed":
        return f"skip {bead_id}: already closed"
    sha = (pull.get("mergeCommit") or {}).get("oid", "")[:12]
    link = pull.get("url") or f"https://github.com/{REPO}/pull/{pull['number']}"
    landed = f"landed {sha} (#{pull['number']}): {pull['title']}"
    actor = "leo"
    children = bd_json("children", bead_id) or []
    open_children = [child["id"] for child in children if child.get("status") != "closed"]
    explicit = bead_id in explicit_closes(pull)
    still_open = [] if explicit else open_pull_requests_naming(bead_id)
    why = ("an epic" if bead.get("issue_type") == "epic"
           else f"open children {', '.join(open_children)}" if open_children
           else "" if explicit
           else "a part or slice marker in the title" if PART.search(pull["title"])
           else f"open pull requests {', '.join(f'#{n}' for n in still_open)}" if still_open
           else "")
    if why:
        if not dry_run:
            bd("--actor", actor, "comment", bead_id,
               f"{landed} {link} (not closed: {why}; the final pull request says \"closes {bead_id}\")")
        return f"comment {bead_id} as {actor}: {why}"
    if not dry_run:
        result = bd("--actor", actor, "close", bead_id, "--reason",
                    f"{landed} [auto-closed on merge; reopen if more of it lands]")
        if result.returncode != 0:
            return f"failed {bead_id} as {actor}: {(result.stderr or result.stdout).strip()}"
    return f"close {bead_id} as {actor}: {landed}"


def create_for_pull(pull: dict, dry_run: bool) -> tuple[str, str]:
    """Create the bead for a new bead-less pull request; its external reference is the link."""
    title = (pull.get("title") or "").strip()
    url = pull.get("url") or f"https://github.com/{REPO}/pull/{pull['number']}"
    description = (
        f"Automatically created for {url}.\n\n"
        f"Opened pull request: {url}\n\n{pull.get('body') or ''}"
    )
    if dry_run:
        return "dry-run", f"create bead for {url}: {title}"
    result = bd("--actor", "leo", "create", title, "--description", description,
                "--external-ref", url, "--labels", "cmux-next", "--json")
    if result.returncode:
        return "", f"failed create for #{pull['number']}: {(result.stderr or result.stdout).strip()}"
    try:
        created = json.loads(result.stdout)
    except ValueError:
        return "", f"failed create for #{pull['number']}: bd returned invalid JSON"
    if isinstance(created, list):
        created = created[0] if created else {}
    bead_id = str(created.get("id") or "").strip()
    if not bead_id:
        return "", f"failed create for #{pull['number']}: bd returned no id"
    return bead_id, f"create {bead_id} for #{pull['number']}"


def parse_time(text: str) -> datetime:
    return datetime.fromisoformat(text.replace("Z", "+00:00"))


def format_time(moment: datetime) -> str:
    return moment.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def read_state(path: Path) -> tuple[str, dict[str, str], str, dict[str, str]]:
    """Return merge state and the open PRs already checked for a bead."""
    try:
        text = path.read_text().strip()
    except OSError:
        return "", {}, "", {}
    try:
        state = json.loads(text)
    except ValueError:
        return text, {}, "", {}  # a bare merge time
    return (state.get("last", ""), dict(state.get("handled", {})),
            state.get("since", ""), dict(state.get("open", {})))


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
    last, handled, pending, open_handled = read_state(state)
    if args.since:
        since = args.since
    elif last:
        since = format_time(parse_time(last) - OVERLAP)
    else:
        since = pending or format_time(datetime.now(timezone.utc) - timedelta(hours=24))

    def save() -> None:
        if args.dry_run:
            return
        snapshot = {"handled": handled, "open": open_handled}
        if not last:
            # Nothing handled yet (the board was unreachable): keep this run's
            # window start, so the next run does not lose its merges.
            snapshot["since"] = since
        else:
            keep = parse_time(last) - OVERLAP
            snapshot["last"] = last
            snapshot["handled"] = {
                number: at for number, at in handled.items()
                if parse_time(at) >= keep
            }
        state.parent.mkdir(parents=True, exist_ok=True)
        state.write_text(json.dumps(snapshot, sort_keys=True) + "\n")

    open_failed = False
    try:
        for pull in merged_pull_requests(since):
            number = str(pull["number"])
            if number in handled:
                continue
            outcomes = [handle(pull, bead_id, args.dry_run)
                        for bead_id in beads_named(pull)]
            for outcome in outcomes:
                print(f"#{number} {outcome}")
            if not any(outcome.startswith("failed ") for outcome in outcomes):
                handled[number] = pull["mergedAt"]  # a failed close retries while in the window
                last = max(last, pull["mergedAt"]) if last else pull["mergedAt"]
        board_refs = None
        for pull in open_pull_requests():
            number = str(pull["number"])
            if number in open_handled:
                continue
            if board_refs is None:
                board_refs = board_pull_request_refs()
            url = pull.get("url") or f"https://github.com/{REPO}/pull/{number}"
            if beads_named(pull, include_comments=True) or url in board_refs:
                open_handled[number] = pull.get("createdAt") or format_time(datetime.now(timezone.utc))
                continue
            _, outcome = create_for_pull(pull, args.dry_run)
            print(f"#{pull['number']} {outcome}")
            open_failed = open_failed or outcome.startswith("failed ")
            if not outcome.startswith("failed "):
                open_handled[number] = pull.get("createdAt") or format_time(datetime.now(timezone.utc))
    except BoardUnreachable as error:
        save()
        print(f"bead-autoclose: the board is unreachable ({error}); the rest waits for the next run",
              file=sys.stderr)
        return 1
    save()
    return 1 if open_failed else 0


if __name__ == "__main__":
    sys.exit(main())
