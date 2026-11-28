#!/usr/bin/env python3
"""Name the pull requests behind a red web bundle matrix, from the FILE:LINE it printed.

    web_bundle_culprit.py --failure OUT/failure.tsv --sha SHA [--repo-dir DIR] [--github-output FILE] [--summary FILE]

scripts/ci/web-bundle-matrix.sh writes `job|file|line|message` for its first red. A merged-tree build error
(a duplicate import, a missing export, a type error) is in a line one pull request added, and often against a
line another added: 2026-11-26/27 two pull requests each imported `layoutGeometry` into VirtualTranscript.tsx,
each green alone, and the nightly died on the pair for hours while seven lanes opened a fix each.

This blames the failing line at SHA, and, when the message names an identifier (`Identifier 'x' has already
been declared`, `Duplicate identifier 'x'`, `Cannot redeclare`), the other line of that file that mentions
it, and reads each commit's squash subject for its pull request. Outputs (GITHUB_OUTPUT):
  pr          the later merge of the pair (the one whose landing made the tree red): what a revert undoes
  merge_sha   its commit
  pair        "#A #B" every pull request named, oldest first
  signature   job:file:message, whitespace and numbers dropped: one fix per signature, however many pushes stay red
Empty pr when no commit of a pull request is named (a direct push, an unreadable blame): nothing to revert.

Reads git only (blame), never GitHub; the workflow opens the pull request.
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

PR_SUBJECT = re.compile(r"\(#(\d+)\)\s*$")
IDENT = re.compile(r"(?:[Ii]dentifier|[Dd]uplicate identifier|redeclare(?: block-scoped variable)?|[Cc]annot redeclare)\s+['`]([^'`]+)['`]")


def git(repo: Path, *args: str) -> str:
    done = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True)
    return done.stdout if done.returncode == 0 else ""


def blame(repo: Path, sha: str, path: str, line: int) -> tuple[str, str] | None:
    """(commit, subject) that last wrote LINE of PATH at SHA."""
    out = git(repo, "blame", "--porcelain", "-L", f"{line},{line}", sha, "--", path)
    first = out.split(None, 1)[0] if out.strip() else ""
    if not re.fullmatch(r"[0-9a-f]{40}", first):
        return None
    return first, git(repo, "log", "-1", "--format=%s", first).strip()


def other_line(repo: Path, sha: str, path: str, line: int, ident: str) -> int | None:
    """The line, other than LINE, where PATH at SHA first mentions IDENT as a whole word."""
    text = git(repo, "show", f"{sha}:{path}")
    word = re.compile(rf"(?<![\w$]){re.escape(ident)}(?![\w$])")
    for number, content in enumerate(text.splitlines(), 1):
        if number != line and word.search(content):
            return number
    return None


def pull(subject: str) -> int | None:
    match = PR_SUBJECT.search(subject)
    return int(match.group(1)) if match else None


def signature(job: str, path: str, message: str) -> str:
    return f"{job}:{path}:" + re.sub(r"[\d\s]+", "", message)[:80]


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--failure", type=Path, required=True)
    parser.add_argument("--sha", required=True)
    parser.add_argument("--repo-dir", type=Path, default=Path.cwd())
    parser.add_argument("--github-output", type=Path)
    parser.add_argument("--summary", type=Path)
    args = parser.parse_args(argv)

    job, path, line, message = (args.failure.read_text(encoding="utf-8").rstrip("\n").split("|", 3) + [""] * 4)[:4]
    found: list[tuple[int, str, int, str]] = []  # (pr, merge sha, file line, subject)
    if path and line.isdigit():
        lines = [int(line)]
        ident = IDENT.search(message)
        if ident and (other := other_line(args.repo_dir, args.sha, path, int(line), ident.group(1))):
            lines.append(other)
        for number in lines:
            who = blame(args.repo_dir, args.sha, path, number)
            if who and (pr := pull(who[1])) is not None and all(pr != seen[0] for seen in found):
                found.append((pr, who[0], number, who[1]))
    # The later landing is the one that made the merged tree red: the newest commit in the branch's history.
    order = {c: n for n, c in enumerate(git(args.repo_dir, "rev-list", args.sha).split())}  # 0 is the newest
    found.sort(key=lambda item: -order.get(item[1], len(order)))
    culprit = found[-1] if found else None
    values = {
        "pr": str(culprit[0]) if culprit else "",
        "merge_sha": culprit[1] if culprit else "",
        "pair": " ".join(f"#{item[0]}" for item in found),
        "signature": signature(job, path, message),
        "file": path, "line": line, "job": job,
    }
    text = (f"web bundle matrix red at {args.sha[:10]} in {job}: {path}:{line}: {message}\n"
            + (f"  blamed: {', '.join(f'#{i[0]} ({i[1][:10]}, {path}:{i[2]})' for i in found)}; the later landing, #{culprit[0]}, is the revert candidate\n"
               if culprit else "  no pull request blamed: nothing to revert automatically\n"))
    print(text, end="")
    if args.summary:
        with args.summary.open("a", encoding="utf-8") as stream:
            stream.write(text)
    if args.github_output:
        with args.github_output.open("a", encoding="utf-8") as stream:
            stream.write("".join(f"{key}={value}\n" for key, value in values.items()))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
