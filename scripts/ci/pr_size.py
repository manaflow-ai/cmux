#!/usr/bin/env python3
"""Size check for feat-cmux-next pull requests: over the limit warns unless the body says why.

Counts added plus deleted lines over the files a pull request changes, leaving
out the paths scripts/ci/pr_size_exclusions.json lists (generated exports,
lockfiles, localization catalogs, fixture and vector data). Above the limit it
writes a workflow warning and a step summary with a hint on how to split, and
exits OVER (3). A line in the pull request body starting `Size:` followed by a
reason overrides it: the check prints the reason and passes clean.

The limit is a warning, never a gate. Leo, 2026-10-28: "don't some things warrant
going a little bit higher? Like 1,200, 1,500, 2,000? I mean, just, like, as long
as you're mindful about it, I feel like it's reasonable, but you don't need to
make it, like, a hard gate". So the workflow passes on exit 3 (the warning is
the answer), and any other non-zero exit is the script's own failure, which it
also reports as a warning and passes. Input is the pull request's files, one JSON object per line with
`filename`, `additions` and `deletions` (the workflow reads them from one
paginated pulls/N/files call; JSON keeps a file name with a tab or newline in
one record), and the pull_request event payload for the body.

    pr_size.py --files FILES.jsonl --event "$GITHUB_EVENT_PATH"
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import dataclasses
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
EXCLUSIONS = Path(__file__).resolve().with_name("pr_size_exclusions.json")
OVER = 3  # the exit code for a pull request over the limit with no `Size:` line
OVERRIDE = re.compile(r"^[ \t]*Size:[ \t]*(\S.*?)[ \t\r]*$", re.MULTILINE)
SPLIT_HINT = (
    "How to split: one pull request per surface or directory; keep each change's tests "
    "in the same pull request as its code; land mechanical moves, renames and "
    "reformatting first, on their own, so the behaviour change that follows is small. "
    "A pull request over about 800 lines should say in its body why it isn't split: "
    "if this size is right, add a line to the body starting `Size:` with the reason."
)


@lru_cache(maxsize=None)
def glob_regex(glob: str) -> re.Pattern[str]:
    """Translate a path glob: `**` spans directories, `*` and `?` stay in one."""
    parts = glob.split("/")
    out: list[str] = []
    for index, part in enumerate(parts):
        last = index == len(parts) - 1
        if part == "**":
            out.append(".*" if last else "(?:[^/]+/)*")
            continue
        piece = "".join(
            "[^/]*" if ch == "*" else "[^/]" if ch == "?" else re.escape(ch) for ch in part
        )
        out.append(piece if last else piece + "/")
    return re.compile("".join(out) + r"\Z")


def load_config(path: Path = EXCLUSIONS) -> tuple[int, tuple[str, ...]]:
    data = json.loads(path.read_text(encoding="utf-8"))
    return int(data["limit"]), tuple(entry["glob"] for entry in data["exclude"])


def excluded_by(path: str, globs: tuple[str, ...]) -> str | None:
    for glob in globs:
        if glob_regex(glob).match(path):
            return glob
    return None


@dataclass(frozen=True)
class Result:
    counted: int
    excluded: int
    limit: int
    override: str | None
    files: tuple[tuple[str, int, str | None], ...]

    @property
    def over(self) -> bool:
        return self.counted > self.limit


def parse_files(text: str) -> list[tuple[str, int]]:
    rows = []
    # Split on newline only: jq escapes newlines inside names, but not U+2028.
    for line in text.split("\n"):
        if not line.strip():
            continue
        row = json.loads(line)
        rows.append((row["filename"], int(row["additions"]) + int(row["deletions"])))
    return rows


def override_reason(body: str | None) -> str | None:
    match = OVERRIDE.search(body or "")
    return match.group(1) if match else None


def measure(rows: list[tuple[str, int]], body: str | None, limit: int, globs: tuple[str, ...]) -> Result:
    files = tuple((path, lines, excluded_by(path, globs)) for path, lines in rows)
    counted = sum(lines for _, lines, glob in files if glob is None)
    excluded = sum(lines for _, lines, glob in files if glob is not None)
    return Result(counted, excluded, limit, override_reason(body), files)


def escape_command(text: str) -> str:
    return text.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def code(path: str) -> str:
    """A path as markdown inline code, on one line."""
    return "`" + path.replace("`", "'").replace("\r", " ").replace("\n", " ") + "`"


def report(result: Result) -> tuple[str, str]:
    """Return (workflow commands for stdout, markdown for the step summary)."""
    headline = f"{result.counted} counted lines (added + deleted), limit {result.limit}"
    if result.excluded:
        headline += f"; {result.excluded} more in allowlisted generated, lockfile, localization or fixture files"
    if not result.over:
        status, command = "within the limit", f"::notice title=PR size::{escape_command(headline)}"
    elif result.override:
        status = f"over the limit, overridden. Size: {result.override}"
        command = f"::notice title=PR size (Size: override)::{escape_command(headline + '. Size: ' + result.override)}"
    else:
        status = "over the limit"
        command = f"::warning title=PR size over {result.limit} lines::{escape_command(headline + '. ' + SPLIT_HINT)}"

    largest = sorted((f for f in result.files if f[2] is None), key=lambda f: -f[1])[:15]
    lines = [f"## PR size: {status}", "", headline + ".", ""]
    if result.over and not result.override:
        lines += [SPLIT_HINT, ""]
    if largest:
        lines += ["| counted lines | file |", "| ---: | --- |"]
        lines += [f"| {count} | {code(path).replace('|', '&#124;')} |" for path, count, _ in largest]
        lines.append("")
    skipped = [f for f in result.files if f[2] is not None]
    if skipped:
        lines += [f"<details><summary>{len(skipped)} allowlisted files not counted "
                  "(scripts/ci/pr_size_exclusions.json)</summary>", ""]
        lines += [f"- {code(path)} ({count}, `{glob}`)" for path, count, glob in skipped[:100]]
        lines += ["", "</details>", ""]
    return command, "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--files", required=True, type=Path)
    parser.add_argument("--event", required=True, type=Path)
    parser.add_argument("--config", type=Path, default=EXCLUSIONS)
    args = parser.parse_args(argv)

    limit, globs = load_config(args.config)
    event = json.loads(args.event.read_text(encoding="utf-8"))
    pull = event.get("pull_request") or {}
    result = measure(parse_files(args.files.read_text(encoding="utf-8")), pull.get("body"), limit, globs)
    # GitHub's files list stops at 3000 files. A list it cut can hide counted lines, so such a pull
    # request is over the limit: one that big needs its `Size:` line anyway.
    changed = pull.get("changed_files")
    truncated = isinstance(changed, int) and changed > len(result.files)
    if truncated and not result.over:
        result = dataclasses.replace(result, counted=max(result.counted, result.limit + 1))
    command, summary = report(result)
    print(command)
    if truncated:
        print(f"::notice title=PR size::the files list stops at {len(result.files)} of "
              f"{changed} files; the pull request counts as over the limit")
    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_path:
        with open(summary_path, "a", encoding="utf-8") as handle:
            handle.write(summary + "\n")
    else:
        print(summary)
    return OVER if result.over and not result.override else 0


if __name__ == "__main__":
    sys.exit(main())
