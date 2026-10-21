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
- or finished red or cancelled with no passing rerun;

unless that compile is still waiting (queued, running or not created yet) and the build fleet compiled
the exact head: `fleet/compile-check` on the head is a success
status posted by GitHub Actions whose run is a finished, green fleet-compile-check.yml dispatch from
feat-cmux-next titled with the full head, whose workflow file came from a commit on that branch. A
token can post any status, and a workflow on another branch or a tag any run, so the guard trusts only
that run. A Release compile that finished red stays a refusal: the fleet compiles on Linux with the pool
SDK, not Xcode 26 Release. The pass covers what `cmux-ci compile-check --app`
compiles (#22845 sat queued over an hour after its fleet pass, with 60 minis offline).

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
import time

BASE = "feat-cmux-next"
GUARDED_REPO = "manaflow-ai/cmux"
COMPILE = "cmux-next Release compile (Xcode 26)"
# The jobs release-compile `needs`: until they finish, its check run does not exist.
ROUTING = ("cmux-next path routing", "cmux-next push head preflight", "cmux-next macOS placement")
RUNNING = frozenset(("queued", "in_progress", "pending", "waiting", "requested"))
NOT_RUN = frozenset(("skipped", "neutral"))
TIMEOUT = 15  # seconds per gh call
BUDGET = 100  # seconds for every call together, under the hook's 120 s: a hook that times out lets the command run
STARTED = time.monotonic()
FLEET_WORKFLOW = "fleet-compile-check.yml"
FLEET_CONTEXT = "fleet/compile-check"
FLEET_TITLE = "fleet compile-check "  # + the full sha: the workflow's run-name
FLEET_POSTER = "github-actions[bot]"
FLEET_RUNS_READ = 2  # newest first; each run read is one gh call
SWIFT_SUFFIXES = (".swift", ".xcconfig", ".h", ".m", ".mm", ".c", ".modulemap")
SWIFT_NAMES = ("Package.swift", "Package.resolved")

SEPARATORS = frozenset((";", "&", "&&", "|", "||", "(", ")", "\n", ";;", "|&", "`"))
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
        left = BUDGET - (time.monotonic() - STARTED)
        if left < 1:
            return None  # out of time: an unread answer refuses, or counts as no fleet pass
        done = subprocess.run(args, capture_output=True, text=True, timeout=min(TIMEOUT, left), cwd=cwd)
    except (OSError, subprocess.SubprocessError):
        return None
    return done.stdout.strip() if done.returncode == 0 else None


def checkout_repo(cwd: str | None) -> str | None:
    url = run(["git", "remote", "get-url", "origin"], cwd) or ""
    found = re.search(r"[:/]([\w.-]+/[\w.-]+?)(?:\.git)?/?$", url)
    return found.group(1) if found else None


FD_REDIRECT = re.compile(r"(?<![^\s;&|()])\d+(?=[<>])")  # the fd of `2>&1`, touching its operator
ANSI_C = re.compile(r"\$'(?:[^'\\]|\\.)*'")
WRAPPERS = frozenset(("env", "command", "builtin", "exec", "time", "nice", "nohup", "sudo", "xargs", "caffeinate",
                      "timeout", "gtimeout"))
KEYWORDS = frozenset(("if", "then", "else", "elif", "do", "while", "until", "{", "}", "!", "time"))
SHELLS = frozenset(("bash", "sh", "zsh", "dash"))
REMOTE = object()  # the cwd of a command run on another host: its checkout can't be read here


def strip_comments(text: str) -> str:
    """`text` without shell comments (a `#` that starts a word, outside quotes, up to its newline)."""
    out, quote, i = [], None, 0
    while i < len(text):
        c = text[i]
        if quote:
            if c == "\\" and quote == '"' and i + 1 < len(text):
                out.append(text[i:i + 2])
                i += 2
                continue
            if c == quote:
                quote = None
        elif c == "\\" and i + 1 < len(text):
            out.append(text[i:i + 2])
            i += 2
            continue
        elif c in "'\"":
            quote = c
        elif c == "#" and (i == 0 or text[i - 1] in " \t\n;&|()"):
            while i < len(text) and text[i] != "\n":
                i += 1
            continue
        out.append(c)
        i += 1
    return "".join(out)


def commands(text: str) -> list[list[str]] | None:
    """The simple commands in `text`, each as its words, split the way the shell splits them; None when
    the text can't be split (an unbalanced quote)."""
    text = HEREDOC.sub("\n", text)
    text = ANSI_C.sub("''", text)
    text = FD_REDIRECT.sub("", strip_comments(text))
    lexer = shlex.shlex(text, posix=True, punctuation_chars=";&|()<>\n`")
    lexer.whitespace = " \t\r"
    lexer.whitespace_split = True
    lexer.commenters = ""
    try:
        tokens = list(lexer)
    except ValueError:
        return None
    out, words, skip = [], [], False
    for token in tokens:
        if skip:
            skip = False
            continue
        if token in SEPARATORS:
            if words:
                out.append(words)
            words = []
        elif REDIRECT.match(token):
            skip = True  # its target
        else:
            words.append(token)
    if words:
        out.append(words)
    return out


def unwrap(words: list[str]) -> tuple[list[str], dict]:
    """The command `words` runs once its env assignments and wrappers (env, nice -n 10, sudo...) are
    peeled off, and the assignments."""
    env = {}
    while words:
        if words[0] in KEYWORDS:
            words = words[1:]
        elif ASSIGNMENT.match(words[0]):
            name, _, value = words[0].partition("=")
            env[name] = value
            words = words[1:]
        elif os.path.basename(words[0]) in WRAPPERS:
            timed = os.path.basename(words[0]) in ("timeout", "gtimeout")
            words = words[1:]
            while words and words[0].startswith("-"):
                words = words[2:] if words[0] in ("-n", "-u", "-g", "-C", "-s", "-k") else words[1:]
            if timed and words:
                words = words[1:]  # its duration
        else:
            break
    if words:
        words = [os.path.basename(words[0]), *words[1:]]
    return words, env


def merge_targets(command: str, cwd) -> list[tuple[str | None, str | None, object]]:
    """(repo, selector, cwd) for each merge the command runs. repo None: the checkout's (or GH_REPO's);
    selector None: the checkout's branch; UNKNOWN: a PR the guard can't name."""
    parsed = commands(command)
    if parsed is None:
        return [(None, UNKNOWN, cwd)] if "gh" in command and "merge" in command else []
    targets = []
    for words in parsed:
        words, env = unwrap(words)
        if not words:
            continue
        if words[0] == "cd":
            target = words[1] if len(words) > 1 else "~"
            if cwd is REMOTE or "$" in target or "`" in target:
                cwd = REMOTE
            else:
                cwd = os.path.join(cwd or os.getcwd(), os.path.expanduser(target))
            continue
        if words[0] in SHELLS:
            for i, word in enumerate(words[1:-1], 1):
                if word.startswith("-") and "c" in word.lstrip("-"):
                    targets += merge_targets(words[i + 1], cwd)
                    break
            continue
        if words[0] == "ssh":
            rest = words[1:]
            while rest and rest[0].startswith("-"):  # options, and the value of those that take one
                rest = rest[2:] if len(rest[0]) == 2 and rest[0][1] in "bcDEeFIiJLlmOopQRSWw" else rest[1:]
            targets += merge_targets(" ".join(rest[1:]), REMOTE)  # the remote shell joins the words
            continue
        if words[0] != "gh":
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


def verdict(pr: dict, files: list[str], checks: list[dict], fleet_passed: bool = False) -> str:
    """"" when the merge may go ahead, else why it is refused."""
    if pr.get("base") != BASE:
        return ""
    swift = [f for f in files if changes_swift(f)]
    if not swift:
        return ""
    why = compile_refusal(pr, swift, checks)
    if not why or not compile_wait(checks):
        return why
    if fleet_passed:
        return ""
    return why + (f" Or compile-check the head on the build fleet: gh workflow run {FLEET_WORKFLOW} --ref {BASE} "
                  f"-f sha={pr['head']}")


def compile_wait(checks: list[dict]) -> bool:
    """The Release compile has not finished on the head yet: no checks, queued or running, or not created
    while cmux-next routes and places it."""
    named = [c for c in checks if c.get("name") == COMPILE]
    finished = [c.get("conclusion") for c in named if c.get("status") == "completed"]
    if any(c not in NOT_RUN and c != "success" for c in finished) and "success" not in finished:
        return False  # an attempt finished red: a rerun queued after it is no wait (every attempt is read)
    return (not checks or any(c.get("status") in RUNNING for c in named)
            or (not named and any(c.get("name") in ROUTING and c.get("status") in RUNNING for c in checks)))


def compile_refusal(pr: dict, swift: list[str], checks: list[dict]) -> str:
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
    checks = gh_lines(["api", "--paginate", f"repos/{repo}/commits/{pr['head']}/check-runs?filter=all&per_page=100", "--jq",
                       ".check_runs[] | {name, status, conclusion} | tojson"], cwd)
    if checks is None:
        raise Unreadable
    why = verdict(pr, files, checks)
    if why and compile_wait(checks) and fleet_passed(repo, pr["head"], cwd):
        return ""
    return why


def fleet_passed(repo: str, head: str, cwd: str | None) -> bool:
    """Whether a fleet-compile-check.yml run from the base, dispatched for exactly `head`, passed. The
    head's fleet/compile-check statuses only point at runs; an unreadable one counts as no pass."""
    statuses = gh_lines(["api", "--paginate", f"repos/{repo}/commits/{head}/statuses?per_page=100", "--jq",
                         f'.[] | select(.context == "{FLEET_CONTEXT}") | '
                         '{state, creator: .creator.login, url: .target_url} | tojson'], cwd) or []
    prefix = f"https://github.com/{repo}/actions/runs/"
    seen = set()
    for found in statuses:
        url = found.get("url") or ""
        run_id = url[len(prefix):]
        if (found.get("state") != "success" or found.get("creator") != FLEET_POSTER or not url.startswith(prefix)
                or not run_id.isdigit() or run_id in seen):
            continue
        if len(seen) == FLEET_RUNS_READ:
            break
        seen.add(run_id)
        run = gh_json(["api", f"repos/{repo}/actions/runs/{run_id}", "--jq",
                       "{path, head_branch, event, status, conclusion, display_title, head_sha}"], cwd) or {}
        if (run.get("path") == f".github/workflows/{FLEET_WORKFLOW}" and run.get("head_branch") == BASE
                and run.get("event") == "workflow_dispatch" and run.get("status") == "completed"
                and run.get("conclusion") == "success" and run.get("display_title") == FLEET_TITLE + head
                and on_base(repo, run.get("head_sha") or "", cwd)):
            return True
    return False


def on_base(repo: str, sha: str, cwd: str | None) -> bool:
    """Whether `sha` is on the base branch. A dispatch on a tag named like the branch reports that
    head_branch too, with whatever workflow file the tag holds."""
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        return False
    tip = gh_json(["api", f"repos/{repo}/branches/{BASE}", "--jq", ".commit.sha | tojson"], cwd)
    if not isinstance(tip, str) or not re.fullmatch(r"[0-9a-f]{40}", tip):
        return False
    return gh_json(["api", f"repos/{repo}/compare/{sha}...{tip}", "--jq", ".status | tojson"], cwd) in (
        "ahead", "identical")


def refusal(command: str, cwd: str | None, reader=read_pr) -> str:
    for repo, selector, where in merge_targets(command, cwd):
        if repo is None and where is REMOTE:
            return ("merge-compile-guard: this merges a pull request in a checkout the guard can't read (over "
                    "ssh or after `cd $VAR`); run `gh pr merge N -R OWNER/REPO` so its compile is checked.")
        repo = repo or checkout_repo(where)
        if repo is None:
            return ("merge-compile-guard: can't tell which repository this merges in (its checkout's origin "
                    "could not be read); run `gh pr merge N -R OWNER/REPO` so its compile is checked.")
        if repo != GUARDED_REPO:
            continue
        where = None if where is REMOTE else where
        if selector == UNKNOWN:
            return ("merge-compile-guard: this merges a manaflow-ai/cmux pull request the guard can't name (a shell "
                    "variable or a GraphQL mutation); run `gh pr merge N` with its number so its compile is checked.")
        if selector is None or not selector.isdigit():
            # gh refuses `pr view -R` without a selector: the checkout's branch is looked up in the checkout.
            args = [selector, "-R", repo] if selector else []
            found = gh_json(["pr", "view", *args, "--json", "number"], where)
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
