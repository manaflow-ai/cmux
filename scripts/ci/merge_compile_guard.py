#!/usr/bin/env python3
"""Refuse merging a feat-cmux-next pull request that changes Swift before its head's Release compile passed.

A Claude Code PreToolUse(Bash) hook (`merge_compile_guard.py --claude-hook`, reading the hook's JSON on
stdin). On 2026-10-21 #22835, #21480 and #21487 were merged by hand with `gh pr merge` while their
Release compile was still pending; #22764 and #22778 had broken the base compile the same way.
next-autoland waits for the same compile (leo-workspace tools/next_autoland.py `compile_verdict`).

It refuses `gh pr merge [N]` (with or without --auto) and `gh api .../pulls/N/merge` when the PR is
into feat-cmux-next, changes a Swift (or C header, module map, Xcode project or package manifest)
file, and its head's `cmux-next Release compile (Xcode 26)` check:

- is queued or running, or not created yet while cmux-next is still routing the head;
- or finished red or cancelled.

A compile the router skipped (iOS, packages outside the CmuxNext graph, forks) does not apply, and
neither does a PR that changes no Swift. When GitHub can't be read for a merge command it refuses,
since that merge could not be checked; the merge itself needs GitHub too.
"""
from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

BASE = "feat-cmux-next"
GUARDED_REPO = "manaflow-ai/cmux"
COMPILE = "cmux-next Release compile (Xcode 26)"
# Jobs that run before release-compile is created (its `needs`).
ROUTING = ("cmux-next path routing", "cmux-next push head preflight")
RUNNING = frozenset(("queued", "in_progress", "pending", "waiting", "requested"))
NOT_RUN = frozenset(("skipped", "neutral"))
TIMEOUT = 20
SWIFT_SUFFIXES = (".swift", ".xcconfig", ".h", ".m", ".mm", ".c", ".modulemap")
SWIFT_NAMES = ("Package.swift", "Package.resolved")

PR_MERGE = re.compile(r"\bgh\s+pr\s+merge\b(?P<rest>[^;&|]*)")
API_MERGE = re.compile(r"\bgh\s+api\b[^;&|]*?repos/(?P<repo>[\w.-]+/[\w.-]+|\{owner\}/\{repo\})/pulls/(?P<n>\d+)/merge\b")
REPO_FLAG = re.compile(r"(?:-R|--repo)[\s=]+(?P<repo>[\w.-]+/[\w.-]+)")
NUMBER = re.compile(r"(?:^|\s)(?:#|https://github\.com/(?P<urlrepo>[\w.-]+/[\w.-]+)/pull/)?(?P<n>\d+)\b")
FLAG_VALUES = re.compile(r"(?:-R|--repo|-b|--body|-t|--subject|-F|--body-file|--match-head-commit|-A|--author-email)"
                         r"(?:[\s=]+(?:\"[^\"]*\"|'[^']*'|\S+))")


def changes_swift(path: str) -> bool:
    return path.endswith(SWIFT_SUFFIXES) or path.rsplit("/", 1)[-1] in SWIFT_NAMES or ".xcodeproj/" in path


def run(args: list[str], cwd: str | None = None) -> str | None:
    try:
        done = subprocess.run(args, capture_output=True, text=True, timeout=TIMEOUT, cwd=cwd)
    except (OSError, subprocess.SubprocessError):
        return None
    return done.stdout.strip() if done.returncode == 0 else None


def checkout_repo(cwd: str | None) -> str | None:
    url = run(["git", "remote", "get-url", "origin"], cwd) or ""
    found = re.search(r"github\.com[:/]([\w.-]+/[\w.-]+?)(?:\.git)?$", url)
    return found.group(1) if found else None


def merge_targets(command: str, cwd: str | None) -> list[tuple[str | None, int | None]]:
    """(repo, number) for each merge in the command; None where it comes from the checkout or its branch."""
    targets = []
    for found in API_MERGE.finditer(command):
        repo = found.group("repo")
        targets.append((None if repo.startswith("{") else repo, int(found.group("n"))))
    for found in PR_MERGE.finditer(command):
        rest = found.group("rest")
        flag = REPO_FLAG.search(rest)
        repo = flag.group("repo") if flag else None
        number = NUMBER.search(FLAG_VALUES.sub(" ", rest))
        if number and number.group("urlrepo"):
            repo = repo or number.group("urlrepo")
        targets.append((repo, int(number.group("n")) if number else None))
    return targets


def gh_json(args: list[str], cwd: str | None):
    out = run(["gh", *args], cwd)
    if out is None:
        return None
    try:
        return json.loads(out)
    except ValueError:
        return None


def verdict(pr: dict, files: list[str], checks: list[dict]) -> str:
    """"" when the merge may go ahead, else why it is refused."""
    if pr.get("base") != BASE:
        return ""
    swift = [f for f in files if changes_swift(f)]
    if not swift:
        return ""
    named = [c for c in checks if c.get("name") == COMPILE]
    what = f"#{pr['number']} changes Swift ({swift[0]}{' and more' if len(swift) > 1 else ''})"
    if any(c.get("status") in RUNNING for c in named):
        return f"{what} and its {COMPILE} is still running on {pr['head'][:12]}; merge once it passes."
    if not named and any(c.get("name") in ROUTING and c.get("status") in RUNNING for c in checks):
        return f"{what} and cmux-next has not created its {COMPILE} on {pr['head'][:12]} yet; merge once it passes."
    ran = [c for c in named if c.get("conclusion") not in NOT_RUN]
    if ran and not any(c.get("conclusion") == "success" for c in ran):
        return (f"{what} and its {COMPILE} finished {ran[0].get('conclusion')} on {pr['head'][:12]}. "
                f"Fix it, or merge the base in when the base has the fix, and merge once it passes.")
    return ""


def gh_lines(args: list[str], cwd: str | None):
    """One JSON value per output line (`--paginate --jq` prints each page's values), or None."""
    out = run(["gh", *args], cwd)
    if out is None:
        return None
    try:
        return [json.loads(line) for line in out.splitlines() if line.strip()]
    except ValueError:
        return None


def read_pr(repo: str, number: int, cwd: str | None):
    pr = gh_json(["api", f"repos/{repo}/pulls/{number}", "--jq",
                  "{number: .number, base: .base.ref, head: .head.sha, state: .state}"], cwd)
    if not pr:
        return None
    files = gh_lines(["api", "--paginate", f"repos/{repo}/pulls/{number}/files?per_page=100", "--jq",
                      ".[].filename | tojson"], cwd)
    checks = gh_lines(["api", "--paginate", f"repos/{repo}/commits/{pr['head']}/check-runs?per_page=100", "--jq",
                       ".check_runs[] | {name, status, conclusion} | tojson"], cwd)
    if files is None or checks is None:
        return None
    return pr, files, checks


def refusal(command: str, cwd: str | None, reader=read_pr) -> str:
    for repo, number in merge_targets(command, cwd):
        repo = repo or checkout_repo(cwd)
        if repo != GUARDED_REPO:
            continue
        if number is None:
            found = gh_json(["pr", "view", "--json", "number"], cwd)
            number = (found or {}).get("number")
            if not number:
                return "merge-compile-guard: could not tell which pull request this merges; name it (gh pr merge N)."
        read = reader(repo, number, cwd)
        if read is None:
            return (f"merge-compile-guard: could not read #{number}'s files and checks from GitHub, so it can't "
                    f"tell whether its Swift compile passed. Try again once GitHub answers.")
        pr, files, checks = read
        why = verdict(pr, files, checks)
        if why:
            return f"merge-compile-guard: {why}"
    return ""


def claude_hook(stdin) -> int:
    try:
        payload = json.load(stdin)
    except ValueError:
        return 0
    command = ((payload.get("tool_input") or {}).get("command") or "")
    why = refusal(command, payload.get("cwd"))
    if why:
        json.dump({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                                          "permissionDecisionReason": why}}, sys.stdout)
    return 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--claude-hook"]:
        sys.exit(claude_hook(sys.stdin))
    print(__doc__)
    sys.exit(2)
