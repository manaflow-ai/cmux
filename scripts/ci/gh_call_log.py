#!/usr/bin/env python3
"""Attribute GitHub API calls to the workflow and job that made them, from calls already made.

GitHub's API Insights is not available on this organization, and GET /rate_limit
only says how much of a bucket is gone, not who spent it. So the shared helpers
that already call the API note each response here: `note(headers, method, path)`
prints one line to the job log with the response's X-RateLimit-Resource,
X-RateLimit-Used, X-RateLimit-Remaining and X-RateLimit-Reset, and the job's
GITHUB_WORKFLOW and GITHUB_JOB. It reads only headers the helper already has; it
makes no request of its own, and outside Actions (no GITHUB_ACTIONS) it prints
nothing.

    gh-call<TAB>2026-10-26T22:47:50Z<TAB>workflow<TAB>job<TAB>resource<TAB>used<TAB>remaining<TAB>reset<TAB>GET /path

`rank` reads job logs (files or directories of them, as `gh run view --log`
or the run logs zip writes them) and prints calls per workflow per hour, most
first, with each hour's highest X-RateLimit-Used per bucket (reset) beside them
for scale:

    gh_call_log.py rank LOG... [--top 10] [--resource core]
"""
from __future__ import annotations

import argparse
import collections
import datetime as dt
import os
import re
import sys
from pathlib import Path
from typing import Iterable, Mapping

PREFIX = "gh-call"
FIELDS = ("time", "workflow", "job", "resource", "used", "remaining", "reset", "request")
# A log line may carry the runner's own timestamp (and the `job<TAB>step<TAB>` columns
# `gh run view --log` adds) before what the helper printed.
LINE = re.compile(rf"(?:^|\t| ){PREFIX}\t(?P<rest>.*)$")


def header(headers: Mapping[str, str] | None, name: str) -> str:
    if not headers:
        return ""
    getter = getattr(headers, "get", None)
    value = getter(name) if getter else None
    if value is None:
        lowered = {str(key).lower(): val for key, val in dict(headers).items()}
        value = lowered.get(name.lower())
    return str(value or "").strip()


def clean(value: str) -> str:
    return re.sub(r"[\t\r\n]+", " ", value or "").strip() or "-"


# Query strings may carry tokens in other APIs; the path before the first `?` is enough to attribute a call.
def line(headers: Mapping[str, str] | None, method: str, path: str, *,
         env: Mapping[str, str] = os.environ, now: dt.datetime | None = None) -> str:
    stamp = (now or dt.datetime.now(dt.timezone.utc)).strftime("%Y-%m-%dT%H:%M:%SZ")
    values = (stamp, env.get("GITHUB_WORKFLOW", ""), env.get("GITHUB_JOB", ""),
              header(headers, "X-RateLimit-Resource"), header(headers, "X-RateLimit-Used"),
              header(headers, "X-RateLimit-Remaining"), header(headers, "X-RateLimit-Reset"),
              f"{method.upper()} {path.split('?', 1)[0]}")
    return "\t".join([PREFIX, *(clean(value) for value in values)])


def note(headers: Mapping[str, str] | None, method: str, path: str, *,
         env: Mapping[str, str] = os.environ, stream=None) -> None:
    """One log line for a response already received. Never raises: attribution must not fail a step."""
    if env.get("GITHUB_ACTIONS") != "true":
        return
    try:
        print(line(headers, method, path, env=env), file=stream or sys.stderr, flush=True)
    except Exception:  # noqa: BLE001 - logging only
        pass


def parse(lines: Iterable[str]) -> Iterable[dict[str, str]]:
    for raw in lines:
        match = LINE.search(raw.rstrip("\n"))
        if not match:
            continue
        parts = match.group("rest").split("\t")
        if len(parts) != len(FIELDS):
            continue
        yield dict(zip(FIELDS, parts))


def log_lines(paths: Iterable[Path]) -> Iterable[str]:
    for path in paths:
        files = sorted(p for p in path.rglob("*") if p.is_file()) if path.is_dir() else [path]
        for file in files:
            with open(file, encoding="utf-8", errors="replace") as handle:
                yield from handle


def rank(records: Iterable[Mapping[str, str]], *, resource: str | None = "core") -> list[tuple[str, str, int, int]]:
    """(hour, workflow, calls, highest X-RateLimit-Used seen that hour), hours in order, most calls first."""
    calls: collections.Counter[tuple[str, str]] = collections.Counter()
    used: dict[str, int] = {}
    for record in records:
        if resource and record["resource"] not in (resource, "-"):
            continue
        hour = record["time"][:13] + ":00Z"
        calls[(hour, record["workflow"])] += 1
        if record["used"].isdigit():
            used[hour] = max(used.get(hour, 0), int(record["used"]))
    return sorted(((hour, workflow, count, used.get(hour, 0)) for (hour, workflow), count in calls.items()),
                  key=lambda row: (row[0], -row[2], row[1]))


def table(rows: list[tuple[str, str, int, int]], top: int) -> str:
    out, shown = ["| hour (UTC) | workflow | calls | highest used that hour |", "|---|---|---:|---:|"], {}
    for hour, workflow, count, used in rows:
        shown[hour] = shown.get(hour, 0) + 1
        if shown[hour] <= top:
            out.append(f"| {hour} | {workflow} | {count} | {used} |")
    return "\n".join(out)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    ranked = sub.add_parser("rank")
    ranked.add_argument("logs", nargs="+", type=Path)
    ranked.add_argument("--top", type=int, default=10)
    ranked.add_argument("--resource", default="core", help="the X-RateLimit-Resource to count; '' for all")
    noted = sub.add_parser("note", help="note one response from a shell helper: METHOD PATH [HEADER-FILE]")
    noted.add_argument("method")
    noted.add_argument("path")
    noted.add_argument("headers", nargs="?", type=Path)
    args = parser.parse_args(argv)
    if args.command == "note":
        headers: dict[str, str] = {}
        if args.headers and args.headers.is_file():
            for raw in args.headers.read_text(encoding="utf-8", errors="replace").splitlines():
                name, sep, value = raw.partition(":")
                if sep:
                    headers[name.strip()] = value.strip()
        note(headers, args.method, args.path)
        return 0
    rows = rank(parse(log_lines(args.logs)), resource=args.resource or None)
    print(table(rows, args.top))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
