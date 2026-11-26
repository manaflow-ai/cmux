#!/usr/bin/env python3
"""The feat-cmux-next acpmux channel, owned end to end: from a published tree to the channel every Linux lane
host follows, without waiting on any one GitHub job.

Leo, 2026-11-23, after the `cmux_next_ daemon tests` job hit its 60-minute limit and the channel stayed 11
commits behind #50566: "but why is it a job. we own/should own the in-between. like ci v2. we own the end to
end."

Linux hosts follow cmux-tui/channels/feat-cmux-next.json (`acpmux host self-update`, acpmux-update.timer). The
channel moves only to a published tree (tree/<key>/completion.json) that has passed the daemon tests
(tree/<key>/daemon-tests.json). Before this, the only thing that ran those tests was one job of a push's
cmux-tui-artifacts run: when it was skipped, superseded or cancelled at its wall, nothing noticed and nothing
tried again, and the channel sat.

  status [--json]    Measures the in-between: channel commit and age, how far feat-cmux-next's head is past it,
                     the newest published tree, whether it is daemon-tested, and the one thing holding the
                     channel. Read-only; exit 0 when the channel is on the newest published tree, 3 when not.
  drive [--dry-run]  Acts on what status found: runs the daemon tests (scripts/ci/cmux-next-daemon-tests.sh)
                     on our own machines at the newest published, untested tree's commit (--runner, default
                     `cmux-ci run`), and on a pass writes its marker and points the channel with the scripts
                     the workflow uses (cmux-tui-mark-daemon-tested.sh, cmux-tui-point-channel.sh). Those writes
                     need the R2 credentials (R2_ENDPOINT, AWS_*) and a GitHub token for the forward-only
                     compare (GH_TOKEN); without them it says so and exits 4 after the tests, so a green
                     result is never lost silently.

Run from a cmux checkout. It reads files.cmux.com and `git` only (no GitHub REST for status).
"""

from __future__ import annotations

import argparse
import json
import os
import shlex
import subprocess
import sys
import time
import urllib.error
import urllib.request
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BASE = os.environ.get("CMUX_TUI_FILES_BASE", "https://files.cmux.com/cmux-tui")
CHANNEL = "feat-cmux-next"
BRANCH = "feat-cmux-next"
DEFAULT_RUNNER = ("cmux-ci run --class isolated --script scripts/ci/cmux-next-daemon-tests.sh "
                  "--ref {commit} --timeout 7200")

EXIT_CURRENT, EXIT_BEHIND, EXIT_NO_CREDENTIALS = 0, 3, 4


def fetch(url: str) -> tuple[int, bytes]:
    """(HTTP status, body) for URL; 0 when it could not be asked. A fresh query so no cache answers."""
    sep = "&" if "?" in url else "?"
    request = urllib.request.Request(f"{url}{sep}keeper={int(time.time())}", headers={"User-Agent": "cmux-ci"})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as error:
        return error.code, b""
    except (urllib.error.URLError, TimeoutError, OSError):
        return 0, b""


def git(*args: str) -> str:
    return subprocess.run(["git", "-C", str(ROOT), *args], check=True, capture_output=True, text=True).stdout.strip()


def tree_key(commit: str) -> str:
    out = subprocess.run([str(ROOT / "scripts/cmux-next/pin-cmux-tui.sh"), "key", "--rev", commit],
                         cwd=ROOT, check=True, capture_output=True, text=True).stdout.strip()
    if len(out) != 40:
        raise RuntimeError(f"no tree key for {commit}: {out!r}")
    return out


def commit_time(commit: str) -> int:
    return int(git("show", "-s", "--format=%ct", commit))


@dataclass
class Tree:
    key: str
    commit: str  # the newest first-parent commit with this key
    published: bool = False
    tested: bool = False
    published_by_run: str = ""


@dataclass
class Report:
    now: str
    head: str
    channel_commit: str = ""
    channel_key: str = ""
    channel_age_minutes: float | None = None
    commits_behind_head: int | None = None
    newest_published: Tree | None = None
    newest_tested: Tree | None = None
    trees_walked: int = 0
    state: str = ""  # current | untested | point-due | unpublished | unreadable
    holding: str = ""
    walked: list[Tree] = field(default_factory=list)


def read_channel() -> dict | None:
    status, body = fetch(f"{BASE}/channels/{CHANNEL}.json")
    if status != 200:
        return None
    try:
        data = json.loads(body)
    except ValueError:
        return None
    return data if isinstance(data, dict) else None


def tree_state(tree: Tree) -> None:
    status, body = fetch(f"{BASE}/tree/{tree.key}/completion.json")
    if status == 200:
        try:
            tree.published = json.loads(body).get("key") == tree.key
        except ValueError:
            tree.published = False
    if tree.published:
        tree.tested = fetch(f"{BASE}/tree/{tree.key}/daemon-tests.json")[0] == 200
        status, body = fetch(f"{BASE}/tree/{tree.key}/source.json")
        if status == 200:
            try:
                tree.published_by_run = str(json.loads(body).get("run") or json.loads(body).get("runId") or "")
            except ValueError:
                pass


def measure(limit: int, fetch_branch: bool = True) -> Report:
    if fetch_branch:
        git("fetch", "--quiet", "--no-tags", "origin", f"+refs/heads/{BRANCH}:refs/remotes/origin/{BRANCH}")
    head = git("rev-parse", f"origin/{BRANCH}")
    report = Report(now=datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), head=head)
    channel = read_channel()
    if channel is None:
        report.state, report.holding = "unreadable", f"{BASE}/channels/{CHANNEL}.json could not be read"
        return report
    report.channel_commit = str(channel.get("commit") or "")
    report.channel_key = str(channel.get("key") or "")
    try:
        report.commits_behind_head = int(git("rev-list", "--count", f"{report.channel_commit}..{head}"))
        report.channel_age_minutes = round((time.time() - commit_time(report.channel_commit)) / 60, 1)
    except subprocess.CalledProcessError:
        pass  # a channel commit this checkout does not have

    # Newest first along the first parent: one Tree per distinct key, until the channel's own key.
    seen: dict[str, Tree] = {}
    for commit in git("rev-list", "--first-parent", f"-n{limit}", head).splitlines():
        if commit == report.channel_commit:
            break
        key = tree_key(commit)
        if key == report.channel_key:
            break
        if key in seen:
            continue
        tree = Tree(key=key, commit=commit)
        tree_state(tree)
        seen[key] = tree
        report.walked.append(tree)
        if tree.published and tree.tested:
            report.newest_tested = tree
            break
        if tree.published and report.newest_published is None:
            report.newest_published = tree
    report.trees_walked = len(report.walked)

    if not report.walked:
        report.state, report.holding = "current", "the channel is on the newest tree"
    elif report.newest_published is not None:
        report.state = "untested"
        report.holding = (f"tree {report.newest_published.key[:12]} ({report.newest_published.commit[:12]}) is "
                          f"published but has no daemon-tests marker: nothing has passed the daemon tests on it")
    elif report.newest_tested is not None:
        report.state = "point-due"
        report.holding = (f"tree {report.newest_tested.key[:12]} ({report.newest_tested.commit[:12]}) is published "
                          f"and daemon-tested; the channel is not on it yet")
    else:
        report.state = "unpublished"
        report.holding = f"none of the {report.trees_walked} newer trees is published yet"
    return report


def print_report(report: Report) -> None:
    print(f"channel {CHANNEL}: commit {report.channel_commit[:12]} key {report.channel_key[:12]}")
    if report.channel_age_minutes is not None:
        print(f"  its commit is {report.channel_age_minutes:.0f} min old; feat-cmux-next head {report.head[:12]} "
              f"is {report.commits_behind_head} commits past it")
    for tree in report.walked:
        marks = ("published" if tree.published else "unpublished") + (", daemon-tested" if tree.tested else "")
        print(f"  tree {tree.key[:12]} at {tree.commit[:12]}: {marks}")
    print(f"state: {report.state}: {report.holding}")


def summary(report: Report) -> None:
    """The measurement, also in the GitHub step summary when there is one."""
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if not path:
        return
    lines = [f"### feat-cmux-next channel: {report.state}", "",
             f"- channel: `{report.channel_commit[:12]}` (tree `{report.channel_key[:12]}`)",
             f"- head `{report.head[:12]}` is {report.commits_behind_head} commits past it; "
             f"the channel's commit is {report.channel_age_minutes} min old",
             f"- {report.holding}", ""]
    with open(path, "a", encoding="utf-8") as handle:
        handle.write("\n".join(lines))


def can_write() -> list[str]:
    return [name for name in ("R2_ENDPOINT", "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "GH_TOKEN")
            if not os.environ.get(name)]


def write_marker_and_point(tree: Tree, run_id: str, run_url: str, dry_run: bool) -> int:
    env = dict(os.environ, GITHUB_SHA=tree.commit, GITHUB_RUN_ID=run_id, AWS_DEFAULT_REGION="auto",
               GITHUB_SERVER_URL=os.environ.get("GITHUB_SERVER_URL", "https://github.com"),
               GITHUB_REPOSITORY=os.environ.get("GITHUB_REPOSITORY", "manaflow-ai/cmux"),
               GITHUB_API_URL=os.environ.get("GITHUB_API_URL", "https://api.github.com"),
               CMUX_TUI_TESTED_RUN_URL=run_url)
    steps = []
    if not tree.tested:
        steps.append([str(ROOT / "scripts/ci/cmux-tui-mark-daemon-tested.sh"), tree.key])
    steps.append([str(ROOT / "scripts/ci/cmux-tui-point-channel.sh"), CHANNEL, tree.key])
    for argv in steps:
        print("+ " + shlex.join(argv), flush=True)
        if not dry_run:
            subprocess.run(argv, cwd=ROOT, env=env, check=True)
    return EXIT_CURRENT


def drive(args: argparse.Namespace) -> int:
    report = measure(args.limit, fetch_branch=not args.no_fetch)
    print_report(report)
    summary(report)
    if report.state in ("current", "unreadable", "unpublished"):
        # A newer tree still building is the normal case for a push's point step: nothing to do, not red.
        return EXIT_CURRENT if report.state == "current" or args.point_only else EXIT_BEHIND
    if args.point_only and report.newest_tested is None:
        print("point only: no published, daemon-tested tree past the channel; nothing to point at.")
        return EXIT_CURRENT
    missing = can_write()
    # The newest published tree; an older tested one is pointed at only when nothing newer is published.
    tree = report.newest_tested if args.point_only else (report.newest_published or report.newest_tested)
    if tree is None:
        return EXIT_BEHIND
    run_id, run_url = f"keeper-{int(time.time())}", ""
    if not tree.tested:
        command = args.runner.format(commit=tree.commit, key=tree.key)
        print(f"running the daemon tests on our own machines at {tree.commit[:12]} (tree {tree.key[:12]}):")
        print("+ " + command, flush=True)
        if args.dry_run:
            print("(dry run: not run)")
        else:
            started = time.monotonic()
            result = subprocess.run(command, shell=True, cwd=ROOT)
            minutes = (time.monotonic() - started) / 60
            print(f"daemon tests at {tree.commit[:12]}: exit {result.returncode} after {minutes:.1f} min")
            if result.returncode != 0:
                print(f"red: tree {tree.key[:12]} failed its daemon tests; the channel stays where it is.")
                return result.returncode
            run_url = os.environ.get("CMUX_KEEPER_RUN_URL", "")
    if missing and not args.dry_run:
        print(f"tree {tree.key[:12]} passed; this host cannot write its marker or point the channel "
              f"(missing {', '.join(missing)}). The next feat-cmux-next push's run, or a rerun of "
              f"{tree.published_by_run or 'its publisher run'}, writes them.")
        return EXIT_NO_CREDENTIALS
    return write_marker_and_point(tree, run_id, run_url, args.dry_run)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("status", "drive"):
        p = sub.add_parser(name)
        p.add_argument("--limit", type=int, default=300, help="first-parent commits to walk back from the head")
        p.add_argument("--no-fetch", action="store_true", help="use origin/feat-cmux-next as it is")
        if name == "status":
            p.add_argument("--json", action="store_true")
        else:
            p.add_argument("--runner", default=os.environ.get("CMUX_KEEPER_RUNNER", DEFAULT_RUNNER),
                           help="the command that runs the daemon tests at {commit} on our own machines")
            p.add_argument("--dry-run", action="store_true")
            p.add_argument("--point-only", action="store_true",
                           help="only point the channel at a published, daemon-tested tree it skipped; run no tests")
    args = parser.parse_args(argv)
    if args.command == "status":
        report = measure(args.limit, fetch_branch=not args.no_fetch)
        if args.json:
            print(json.dumps(asdict(report), indent=2))
        else:
            print_report(report)
        return EXIT_CURRENT if report.state == "current" else EXIT_BEHIND
    return drive(args)


if __name__ == "__main__":
    sys.exit(main())
