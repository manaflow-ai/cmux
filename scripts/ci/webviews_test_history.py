#!/usr/bin/env python3
"""The webview tests' recent verdicts on feat-cmux-next pushes, and which tests flip on them.

    webviews_test_history.py record HISTORY OUT --sha SHA --time EPOCH RESULTS.json...
        append one push run (its shards' webviews_test_results.py maps) to HISTORY (missing or
        unreadable: an empty one) and write the newest KEEP runs to OUT
    webviews_test_history.py flaky HISTORY [--names NAMES.json]
        print, one a line, the tests and files whose verdict flipped by itself on the base:
        red on one push with green pushes on both sides, or green on one with red on both sides.
        With NAMES (a {name: passed} map, a head's results), only names among its reds.

Why: a pull request fails only on the webview tests its base replay (react-apps-base-check)
passes, and that replay runs each red file once, alone, on the merge parent. A test that fails
now and then on the base passed there by chance and was charged to the change:
agent-pane-suggested-tasks' sent image (base runs 41075124126 red and 41075808917 green on the same
tree) was a new red on 9 of 40 sampled red pull request runs (2026-10-30). guards_new_reds.py
--flaky keeps such a test a warning.

A verdict that flips for one push and back is a flake: a real break or fix holds for many pushes
(feat-cmux-next takes a push every few minutes), so it makes one change of state, never a lone
push. Each run stores only what it needs: the files that ran and the names that were red.
A test is green on a run whose file ran and named neither it nor the file as red; a file red
without naming tests (a timeout, a crash) says nothing about that file's tests on that run.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys

KEEP = 60  # push runs kept: about two to four hours of feat-cmux-next pushes


def load(path: str | Path) -> list[dict]:
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []
    runs = data.get("runs") if isinstance(data, dict) else None
    if not isinstance(runs, list):
        return []
    return [r for r in runs if isinstance(r, dict) and isinstance(r.get("sha"), str)
            and isinstance(r.get("time"), (int, float)) and isinstance(r.get("files"), list)
            and isinstance(r.get("red"), list)]


def results(paths: list[str]) -> dict[str, bool]:
    merged: dict[str, bool] = {}
    for path in paths:
        try:
            found = json.loads(Path(path).read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if isinstance(found, dict):
            for name, ok in found.items():
                merged[str(name)] = merged.get(str(name), True) and bool(ok)
    return merged


def record(history: list[dict], sha: str, time: float, found: dict[str, bool], keep: int = KEEP) -> list[dict]:
    """The history with this run in it (one run per sha: a re-run replaces it), oldest first."""
    if not found:
        return history[-keep:]
    run = {
        "sha": sha,
        "time": time,
        "files": sorted({name.split(" > ", 1)[0] for name in found}),
        "red": sorted(name for name, ok in found.items() if not ok),
    }
    runs = [r for r in history if r["sha"] != sha] + [run]
    runs.sort(key=lambda r: (r["time"], r["sha"]))
    return runs[-keep:]


def verdicts(runs: list[dict], name: str) -> list[bool]:
    """NAME's verdict on each run that says one, oldest first."""
    file = name.split(" > ", 1)[0]
    out = []
    for run in runs:
        if file not in run["files"]:
            continue
        red = set(run["red"])
        if name in red:
            out.append(False)
        elif name != file and file in red:
            continue  # the file failed without reaching or naming its tests
        else:
            out.append(True)
    return out


def flips(sequence: list[bool]) -> bool:
    """Whether one verdict differs from the verdicts on both sides of it."""
    return any(sequence[i] != sequence[i - 1] and sequence[i] != sequence[i + 1] for i in range(1, len(sequence) - 1))


def flaky(runs: list[dict], names: list[str] | None = None) -> list[str]:
    if names is None:
        names = sorted({name for run in runs for name in run["red"]})
    return sorted(name for name in names if flips(verdicts(runs, name)))


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    rec = sub.add_parser("record")
    rec.add_argument("history")
    rec.add_argument("out")
    rec.add_argument("--sha", required=True)
    rec.add_argument("--time", type=float, required=True)
    rec.add_argument("results", nargs="+")
    fl = sub.add_parser("flaky")
    fl.add_argument("history")
    fl.add_argument("--names")
    args = parser.parse_args(argv)
    if args.command == "record":
        runs = record(load(args.history), args.sha, args.time, results(args.results))
        Path(args.out).parent.mkdir(parents=True, exist_ok=True)
        Path(args.out).write_text(json.dumps({"runs": runs}, separators=(",", ":")) + "\n", encoding="utf-8")
        print(f"webview test history: {len(runs)} push runs")
        return 0
    names = None
    if args.names:
        names = sorted(name for name, ok in results([args.names]).items() if not ok)
    for name in flaky(load(args.history), names):
        print(name)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
