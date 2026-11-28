#!/usr/bin/env python3
"""The webview test files a post-merge batch tick runs: every file whose last recorded pass the change since cannot
reach, left out; every other file run. And the react-apps-check shard count that file list needs.

    webviews_batch_select.py HISTORY --out FILES --count-out COUNT [--head REF] [--repo DIR] [--now EPOCH]
                             [--durations MANIFEST.json] [--shards N] [--summary FILE]

HISTORY is the base's webview test history (webviews_test_history.py fetch): for each feat-cmux-next push and batch
run, the commit, the files it ran and the names that failed. That is the per-file pass ledger. A test file is left out
of this tick only when all of these hold, else it runs:
  - its newest verdict in HISTORY is a pass (a red, a timeout or a file never recorded runs: a standing red runs every
    tick until it is fixed, so a full run's reds are never skipped);
  - webviews_affected.py's selector, on the diff from the commit it passed at to HEAD, resolves (no build, lockfile,
    config, runner or shared-harness input changed: EVERY_TEST, the preload and its imports, a resolution config, a
    deleted source a non-code file names) and does not select it. That selection is the file's whole input key: its
    import closure (assets and `?raw` fixtures included), every file a source of it names, the gallery zone of a
    gallery, sweep or page test, and the inputs every test loads (package.json, bun.lock, bunfig, tsconfig, the React
    Compiler config, the preload, the runner scripts, ci-web.yml, which pins Bun and every CMUX_WEB_TEST_* knob);
  - it is not in the always-run set (a test that reads files, spawns, runs Vite or a browser: no graph follows it);
  - the commit it passed at still diffs against HEAD (a commit the checkout cannot fetch runs the file).
What the repository does not hold (the runner image, its Node, a repository variable) is bounded by a daily
backstop: the first tick of each UTC day (no recorded run yet that day) runs every file. A full tick's own shards
still stop at their deadline (tick 46081509797 left 279 of 3,699 unrun; the 11-27 ticks recorded 2,186 to 3,652), so
"full" is a day boundary, not a file count.

The shard count is the full matrix's share for the selected files' recorded seconds: a tick whose files take a tenth
of the suite's seconds runs on a tenth of the shards (at least 1), so each shard carries what a full-matrix shard does.

Prints nothing on stdout. FILES is the list (relative to webviews/) for CMUX_WEB_TEST_FILES_FROM; no FILES (removed)
means every file runs. COUNT is the shard count. Undo: the repository variable CI_WEBVIEWS_BATCH_SELECT=0
(ci-web.yml) runs every file on every tick again.
"""
from __future__ import annotations

import argparse
import json
import math
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import webviews_affected as wa  # noqa: E402
import webviews_test_history as th  # noqa: E402

WEB = wa.WEB
DAY = 24 * 3600
DEFAULT_SECONDS = 13.0  # a file with no recorded duration: the suite's median


def repo_path(name: str) -> str:
    return name if name.startswith(WEB) else WEB + name


def last_verdicts(runs: list[dict]) -> dict[str, tuple[str, bool]]:
    """{test file (repo path): (commit, passed)} from each file's newest run in RUNS (oldest first)."""
    out: dict[str, tuple[str, bool]] = {}
    for run in runs:
        red_files = {name.split(" > ", 1)[0] for name in run["red"]}
        for name in run["files"]:
            out[repo_path(name)] = (run["sha"], name not in red_files)
    return out


def full_due(runs: list[dict], now: float) -> bool:
    """No run recorded yet in NOW's UTC day: this tick is the day's full run."""
    return not any(int(run["time"] // DAY) == int(now // DAY) for run in runs)


def select(selector: wa.Selector, runs: list[dict], head: str, now: float, diff=None) -> tuple[set[str] | None, str, dict]:
    """(the test files to run, or None for every file; why; counts by reason)."""
    tests = set(selector.graph.tests)
    if not runs:
        return None, "no webview test history", {}
    if full_due(runs, now):
        return None, "the first tick of the UTC day (the daily full run)", {}
    diff = diff or (lambda base: wa.changed(selector.root, base, head))
    verdicts = last_verdicts(runs)
    by_sha: dict[str, set[str]] = {}
    run: set[str] = set()
    counts = {"never_recorded": 0, "red": 0, "always_run": 0, "reached": 0, "unresolved": 0, "carried": 0}
    for f in tests:
        found = verdicts.get(f)
        if found is None:
            counts["never_recorded"] += 1
            run.add(f)
        elif not found[1]:
            counts["red"] += 1
            run.add(f)
        elif f in selector.always:
            counts["always_run"] += 1
            run.add(f)
        else:
            by_sha.setdefault(found[0], set()).add(f)
    reach: dict[str, set[str] | None] = {}
    for sha, files in by_sha.items():
        if sha not in reach:
            try:
                picked, _ = selector.select(diff(sha)) if sha != head else (set(), "")
            except (subprocess.CalledProcessError, OSError):
                picked = None
            reach[sha] = picked
        picked = reach[sha]
        if picked is None:
            counts["unresolved"] += len(files)
            run |= files
            continue
        hit = files & picked
        counts["reached"] += len(hit)
        counts["carried"] += len(files) - len(hit)
        run |= hit
    return run, "", counts


def shard_count(selected: set[str], tests: set[str], seconds: dict[str, float], shards: int) -> int:
    def secs(f: str) -> float:
        return float(seconds.get(f.removeprefix(WEB), seconds.get(f, DEFAULT_SECONDS)))
    total = sum(secs(f) for f in tests) or 1.0
    return max(1, min(shards, math.ceil(shards * sum(secs(f) for f in selected) / total)))


def durations(path: Path | None) -> dict[str, float]:
    if not path:
        return {}
    try:
        data = json.loads(path.read_text())
    except (OSError, ValueError):
        return {}
    data = data.get("files", data) if isinstance(data, dict) else {}
    return {str(k): float(v) for k, v in data.items() if isinstance(v, (int, float))} if isinstance(data, dict) else {}


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("history", type=Path)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--count-out", type=Path, required=True)
    ap.add_argument("--head", default="HEAD")
    ap.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[2])
    ap.add_argument("--now", type=float, default=None)
    ap.add_argument("--durations", type=Path)
    ap.add_argument("--shards", type=int, default=12)
    ap.add_argument("--summary", type=Path)
    args = ap.parse_args(argv)
    args.out.unlink(missing_ok=True)
    args.count_out.write_text(f"{args.shards}\n")
    try:
        head = subprocess.run(["git", "-C", str(args.repo), "rev-parse", args.head], capture_output=True, text=True,
                              check=True).stdout.strip()
    except subprocess.CalledProcessError:
        print("webviews batch select: HEAD does not resolve; every file runs", file=sys.stderr)
        return 0
    selector = wa.Selector(args.repo)
    tests = set(selector.graph.tests)
    picked, why, counts = select(selector, th.load(args.history), head, args.now or time.time())
    if picked is None:
        line = f"every file runs: {why}"
    else:
        count = shard_count(picked, tests, durations(args.durations), args.shards)
        args.out.write_text("".join(f.removeprefix(WEB) + "\n" for f in sorted(picked)))
        args.count_out.write_text(f"{count}\n")
        line = (f"{len(picked)} of {len(tests)} test files on {count} of {args.shards} shards; left out "
                f"{counts['carried']} whose last pass the change since cannot reach ({json.dumps(counts)})")
    print(f"webviews batch select: {line}", file=sys.stderr)
    if args.summary:
        with args.summary.open("a") as out:
            out.write(f"### react-apps-check batch selection\n\n{line}\n\nUndo: `CI_WEBVIEWS_BATCH_SELECT=0`.\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
