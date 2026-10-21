#!/usr/bin/env python3
"""Refuse merging a feat-cmux-next pull request that changes Swift before its head's Release compile passed.

A Claude Code PreToolUse(Bash) hook (`merge_compile_guard.py --claude-hook`, reading the hook's JSON on
stdin). On 2026-10-21 (UTC) #22835, #21480 and #21487 were merged by hand with `gh pr merge` while their
Release compile was still pending; #22764 and #22778 had broken the base compile the same way.
next-autoland waits for the same compile (leo-workspace tools/next_autoland.py `compile_verdict`).

It refuses `gh pr merge [N|#N|URL|BRANCH]` (with or without --auto) and `gh api .../pulls/N/merge`
when the PR is into feat-cmux-next, changes a Swift (or C header or source, module map, xcconfig,
Xcode project or package manifest) file, and its head's `cmux-next Release compile (Xcode 26)`:

- is queued or running, or not created yet while cmux-next is still routing and placing the head
  (or the head has no checks at all yet);
- or finished red or cancelled with no passing rerun.

A compile the router skipped (iOS, packages outside the CmuxNext graph, forks) or a head cmux-next
never ran on does not apply, and neither does a PR that changes no Swift. The command is read the
way the shell splits it: quoted text and heredoc bodies are data, never a merge. When GitHub can't be
read for a merge it has to check, it refuses; the merge itself needs GitHub too.
"""
from __future__ import annotations

import json
import os
import re
import shlex
import subprocess
import sys

BASE = "feat-cmux-next"
GUARDED_REPO = "manaflow-ai/cmux"
COMPILE = "cmux-next Release compile (Xcode 26)"
# The jobs release-compile `needs`: until they finish, its check run does not exist.
ROUTING = ("cmux-next path routing", "cmux-next push head preflight", "cmux-next macOS placement")
RUNNING = frozenset(("queued", "in_progress", "pending", "waiting", "requested"))
NOT_RUN = frozenset(("skipped", "neutral"))
TIMEOUT = 15  # seconds per gh call; at most four calls fit the hook's 120 s
SWIFT_SUFFIXES = (".swift", ".xcconfig", ".h", ".m", ".mm", ".c", ".modulemap")
SWIFT_NAMES = ("Package.swift", "Package.resolved")

SEPARATORS = frozenset((";", "&", "&&", "|", "||", "(", ")", "\n", ";;", "|&"))
REDIRECT = re.compile(r"^[<>]+&?$|^&>+$")
ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
HEREDOC = re.compile(r"<<-?[ \t]*(['\"]?)([A-Za-z_][\w-]*)\1[^\n]*\n.*?^[ \t]*\2[ \t]*$", re.S | re.M)
# `gh pr merge` flags that take a value (the rest are switches).
VALUE_FLAGS = frozenset(("-R", "--repo", "-b", "--body", "-t", "--subject", "-F", "--body-file",
                         "--match-head-commit", "-A", "--author-email"))
PULL_URL = re.compile(r"^https://github\.com/([\w.-]+/[\w.-]+)/pull/(\d+)")
API_MERGE = re.compile(r"(?:^|/)repos/([^/\s]+/[^/\s]+)/pulls/([^/\s]+)/merge/?$")
UNKNOWN = "?"  # a selector the guard can't resolve (a shell variable, a GraphQL mutation)


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
    found = re.search(r"[:/]([\w.-]+/[\w.-]+?)(?:\.git)?/?$", url)
    return found.group(1) if found else None


def commands(text: str) -> list[list[str]]:
    """The simple commands in `text`, each as its words, split the way the shell splits them."""
    text = HEREDOC.sub("\n", text)
    lexer = shlex.shlex(text, posix=True, punctuation_chars=";&|()<>\n")
    lexer.whitespace = " \t\r"
    lexer.whitespace_split = True
    try:
        tokens = list(lexer)
    except ValueError:  # an unbalanced quote: bash would refuse the command too
        return []
    out, words, skip = [], [], False
    for i, token in enumerate(tokens):
        if skip:
            skip = False
            continue
        if token in SEPARATORS:
            if words:
                out.append(words)
            words = []
        elif REDIRECT.match(token):
            if words and words[-1].isdigit() and i and tokens[i - 1] == words[-1]:
                words.pop()  # the fd of `2>&1`, `2>/dev/null`
            skip = True  # its target
        else:
            words.append(token)
    if words:
        out.append(words)
    return out


def merge_targets(command: str, cwd: str | None) -> list[tuple[str | None, str | None, str | None]]:
    """(repo, selector, cwd) for each merge the command runs. repo None: the checkout's (or GH_REPO's);
    selector None: the checkout's branch; UNKNOWN: a PR the guard can't name."""
    targets = []
    for words in commands(command):
        env = {}
        while words and ASSIGNMENT.match(words[0]):
            name, _, value = words.pop(0).partition("=")
            env[name] = value
        if words[:1] == ["cd"] and len(words) > 1:
            cwd = os.path.join(cwd or os.getcwd(), os.path.expanduser(words[1]))
            continue
        if words[:1] != ["gh"]:
            continue
        default_repo = env.get("GH_REPO") or os.environ.get("GH_REPO")
        if words[1:3] == ["pr", "merge"]:
            repo, selector, rest = default_repo, None, words[3:]
            i = 0
            while i < len(rest):
                word = rest[i]
                flag, eq, value = word.partition("=")
                if flag in VALUE_FLAGS:
                    if not eq:
                        value = rest[i + 1] if i + 1 < len(rest) else ""
                        i += 1
                    if flag in ("-R", "--repo"):
                        repo = value
                elif not word.startswith("-") and selector is None:
                    selector = word
                i += 1
            if selector:
                url = PULL_URL.match(selector)
                if url:
                    repo, selector = repo or url.group(1), url.group(2)
                elif "$" in selector or "`" in selector:
                    selector = UNKNOWN
                else:
                    selector = selector.lstrip("#")
            targets.append((repo, selector, cwd))
        elif words[1:2] == ["api"]:
            if any("mergePullRequest" in w for w in words):
                targets.append((default_repo, UNKNOWN, cwd))
                continue
            for word in words[2:]:
                found = API_MERGE.search(word)
                if found:
                    repo, number = found.groups()
                    repo = None if repo == "{owner}/{repo}" else repo
                    targets.append((repo or default_repo, number if number.isdigit() else UNKNOWN, cwd))
    return targets


def gh_json(args: list[str], cwd: str | None):
    out = run(["gh", *args], cwd)
    if out is None:
        return None
    try:
        return json.loads(out)
    except ValueError:
        return None


def gh_lines(args: list[str], cwd: str | None):
    """One JSON value per output line (`--paginate --jq` prints each page's values), or None."""
    out = run(["gh", *args], cwd)
    if out is None:
        return None
    try:
        return [json.loads(line) for line in out.splitlines() if line.strip()]
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
    head = pr["head"][:12]
    what = f"#{pr['number']} changes Swift ({swift[0]}{' and more' if len(swift) > 1 else ''})"
    if not checks:
        return f"{what} and {head} has no checks yet; merge once its {COMPILE} passes."
    if any(c.get("status") in RUNNING for c in named):
        return f"{what} and its {COMPILE} is still running on {head}; merge once it passes."
    if not named and any(c.get("name") in ROUTING and c.get("status") in RUNNING for c in checks):
        return f"{what} and cmux-next has not created its {COMPILE} on {head} yet; merge once it passes."
    ran = [c for c in named if c.get("conclusion") not in NOT_RUN]
    if ran and not any(c.get("conclusion") == "success" for c in ran):
        return (f"{what} and its {COMPILE} finished {ran[0].get('conclusion')} on {head}. "
                f"Fix it, or merge the base in when the base has the fix, and merge once it passes.")
    return ""


class Unreadable(Exception):
    pass


def read_pr(repo: str, number: int, cwd: str | None) -> str:
    """verdict() for the PR, reading only as much of GitHub as it needs."""
    pr = gh_json(["api", f"repos/{repo}/pulls/{number}", "--jq", "{number: .number, base: .base.ref, head: .head.sha}"],
                 cwd)
    if not pr:
        raise Unreadable
    if pr.get("base") != BASE:
        return ""
    files = gh_lines(["api", "--paginate", f"repos/{repo}/pulls/{number}/files?per_page=100", "--jq",
                      ".[].filename | tojson"], cwd)
    if files is None:
        raise Unreadable
    if not any(changes_swift(f) for f in files):
        return ""
    checks = gh_lines(["api", "--paginate", f"repos/{repo}/commits/{pr['head']}/check-runs?per_page=100", "--jq",
                       ".check_runs[] | {name, status, conclusion} | tojson"], cwd)
    if checks is None:
        raise Unreadable
    return verdict(pr, files, checks)


def refusal(command: str, cwd: str | None, reader=read_pr) -> str:
    for repo, selector, where in merge_targets(command, cwd):
        repo = repo or checkout_repo(where)
        if repo != GUARDED_REPO:
            continue
        if selector == UNKNOWN:
            return ("merge-compile-guard: this merges a manaflow-ai/cmux pull request the guard can't name (a shell "
                    "variable or a GraphQL mutation); run `gh pr merge N` with its number so its compile is checked.")
        if selector is None or not selector.isdigit():
            found = gh_json(["pr", "view", *([selector] if selector else []), "-R", repo, "--json", "number"], where)
            number = (found or {}).get("number")
            if not number:
                return (f"merge-compile-guard: could not tell which pull request `gh pr merge {selector or ''}` merges; "
                        f"name it by number (gh pr merge N).")
        else:
            number = int(selector)
        try:
            why = reader(repo, number, where)
        except Unreadable:
            return (f"merge-compile-guard: could not read #{number} from GitHub (a REST rate limit or 403 is the usual "
                    f"cause), so it can't tell whether its Swift compile passed. Merge once GitHub answers.")
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
