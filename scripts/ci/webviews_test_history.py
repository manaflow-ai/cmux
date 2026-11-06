#!/usr/bin/env python3
"""The webview tests' recent verdicts on feat-cmux-next pushes, and which tests flip on them.

    webviews_test_history.py inputs [--root DIR]
        print the key of HEAD's webview test inputs: the files and folders web_subareas.py routes the
        webview suite on (its REACT_PREFIXES, REACT_EXACT and ALL_SUBAREA_INPUTS), as git has them
    webviews_test_history.py record HISTORY OUT --sha SHA --time EPOCH --inputs KEY RESULTS.json...
        append one push run (its shards' webviews_test_results.py maps) to HISTORY (missing or
        unreadable: an empty one) and write the newest KEEP runs to OUT
    webviews_test_history.py flaky HISTORY [--names NAMES.json]
        print, one a line, the tests and files that passed and failed on the same inputs: two base
        pushes with the same inputs key gave them different verdicts. With NAMES (a {name: passed} map,
        a head's results), only names among its reds.

Why: a pull request fails only on the webview tests its base replay (react-apps-base-check)
passes, and that replay runs each red file once, alone, on the merge parent. A test that fails
now and then on the base passed there by chance and was charged to the change:
agent-pane-suggested-tasks' sent image (base runs 41075124126 red and 41075808917 green on the same
tree) was a new red on 9 of 40 sampled red pull request runs (2026-10-30). guards_new_reds.py
--flaky keeps such a test a warning.

A flake is a test whose verdict changes while its inputs do not. Most feat-cmux-next pushes change
no webview input (Swift, Rust, docs), so the same inputs run again and again. A verdict that only
follows the code (a break, then its revert: green, red, green) changes its inputs each time, so it
is never called a flake. The inputs are the paths the router (web_subareas.py) runs the webview
suite for; a test that reads a file outside them is a router gap, which also skips it on pull requests.
Each run stores only what it needs: its inputs key, the files that ran and the names that were red.
A test is green on a run whose file ran and named neither it nor the file as red; a file red
without naming tests (a timeout, a crash) says nothing about that file's tests on that run.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

KEEP = 120  # push runs kept: several hours of feat-cmux-next pushes, a few MB


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
            and isinstance(r.get("red"), list) and isinstance(r.get("inputs"), str) and r["inputs"]]


def inputs(root: str | Path = ".") -> str:
    """HEAD's webview test inputs key: the git ids of every path web_subareas.py routes the suite on."""
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import web_subareas  # noqa: PLC0415
    paths = sorted({p.rstrip("/") for p in (*web_subareas.REACT_PREFIXES, *web_subareas.REACT_EXACT,
                                            *web_subareas.ALL_SUBAREA_INPUTS)})
    listed = subprocess.run(["git", "-C", str(root), "ls-tree", "HEAD", "--", *paths],
                            check=True, capture_output=True, text=True).stdout
    return hashlib.sha256(listed.encode()).hexdigest()[:20]


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


def record(history: list[dict], sha: str, time: float, found: dict[str, bool], key: str,
           attempt: int = 1, keep: int = KEEP) -> list[dict]:
    """The history with this run in it (one per sha and attempt: a re-run of the same push is more evidence), oldest
    first."""
    if not found:
        return history[-keep:]
    run = {
        "sha": sha,
        "attempt": attempt,
        "time": time,
        "inputs": key,
        "files": sorted({name.split(" > ", 1)[0] for name in found}),
        "red": sorted(name for name, ok in found.items() if not ok),
    }
    runs = [r for r in history if (r["sha"], r.get("attempt", 1)) != (sha, attempt)] + [run]
    runs.sort(key=lambda r: (r["time"], r["sha"], r.get("attempt", 1)))
    return runs[-keep:]


def verdicts(runs: list[dict], name: str) -> list[tuple[str, bool]]:
    """NAME's (inputs key, verdict) on each run that says one, oldest first."""
    file = name.split(" > ", 1)[0]
    out = []
    for run in runs:
        if file not in run["files"]:
            continue
        red = set(run["red"])
        if name in red:
            out.append((run["inputs"], False))
        elif name != file and file in red:
            continue  # the file failed without reaching or naming its tests
        else:
            out.append((run["inputs"], True))
    return out


def flips(found: list[tuple[str, bool]]) -> bool:
    """Whether some inputs gave both verdicts."""
    seen: dict[str, set[bool]] = {}
    for key, ok in found:
        seen.setdefault(key, set()).add(ok)
    return any(len(both) == 2 for both in seen.values())


def flaky(runs: list[dict], names: list[str] | None = None) -> list[str]:
    if names is None:
        names = sorted({name for run in runs for name in run["red"]})
    return sorted(name for name in names if flips(verdicts(runs, name)))


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    keyed = sub.add_parser("inputs")
    keyed.add_argument("--root", default=".")
    rec = sub.add_parser("record")
    rec.add_argument("history")
    rec.add_argument("out")
    rec.add_argument("--sha", required=True)
    rec.add_argument("--time", type=float, required=True)
    rec.add_argument("--inputs", required=True)
    rec.add_argument("--attempt", type=int, default=1)
    rec.add_argument("results", nargs="+")
    fl = sub.add_parser("flaky")
    fl.add_argument("history")
    fl.add_argument("--names")
    args = parser.parse_args(argv)
    if args.command == "inputs":
        print(inputs(args.root))
        return 0
    if args.command == "record":
        runs = record(load(args.history), args.sha, args.time, results(args.results), args.inputs, args.attempt)
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
