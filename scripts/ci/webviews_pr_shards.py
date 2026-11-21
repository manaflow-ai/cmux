#!/usr/bin/env python3
"""The react-apps-check shards a pull request runs: shard 1, and each other shard that holds a test the change
touches. A feat-cmux-next push runs every shard (ci-web.yml calls this only on a pull request).

    webviews_pr_shards.py --base REF [--head REF] --count N [--repo DIR]
    webviews_pr_shards.py --all --count N        # every shard: a push, the full-ci label, a failed pick

Prints the shard matrix as JSON (`[{"shard": 1, "shard_count": N}, ...]`) on stdout, and why on stderr.

Leo, 2026-11-21: "id rather we simply cut shit now and revisit later." Over 11-13..19 (16,970 pull request heads,
cmuxterm-hq docs/ci/bottleneck-and-skip-candidates-2026-11-21.md), shards 2 to 12 were 20.5% of pull request
runner-minutes and never caught a red that no other check caught (0 of 3,078 heads); shard 1 caught 9 of its own. So
a pull request runs:
  - shard 1 always (it holds the shard-independent checks: Oxlint, Oxfmt, type check, budgets, PR-scoped rules);
  - a shard from 2 to N only when it holds a touched test: a test file the change edits, or a test that itself
    imports a changed webviews file (one hop of webviews_affected.py's import graph, not its closure, and not its
    always-run set: the browser, Vite and file-reading tests that run on nearly every change are what the 0% above
    measured skipping; the closure put a test of every shard behind any shared module);
  - every shard for a build or runner input (webviews_affected.EVERYTHING: package.json, bun.lock, vite configs, the
    runner scripts, ci-web.yml, this file) or a deleted source.
A shard's files come from the very split it makes itself (run-webviews-tests.sh CMUX_WEB_TEST_LIST_ONLY with the
run's one duration manifest, widths and head start, passed in the environment), so the pick and the shards agree.
Every feat-cmux-next push still runs all N shards over every file: a red a skipped shard would have caught shows on
the base's next push (cmux-next-web.yml) and its base-red tracking.

Any error picks every shard: the pick may only ever run more.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import webviews_affected as wa  # noqa: E402

RUNNER = Path(__file__).resolve().parent / "run-webviews-tests.sh"


def matrix(shards: list[int], count: int) -> str:
    return json.dumps([{"shard": shard, "shard_count": count} for shard in shards], separators=(",", ":"))


def touched(selector: "wa.Selector", files: list[str]) -> tuple[set[str] | None, str]:
    """The tests the change touches directly (repo paths), or None for every shard, and why."""
    out: set[str] = set()
    for f in files:
        if wa.EVERYTHING.search(f) or f in selector.preload:
            return None, f"{f} is a build or runner input"
        if not f.startswith(wa.WEB):
            continue
        if f in selector.graph.tests:
            out.add(f)
            continue
        if not (selector.root / f).exists() and f.endswith(wa.ft.EXTENSIONS) and not wa.ft.WEB_TEST.search(f):
            return None, f"{f} was deleted"
        # One hop: the tests that import the changed file themselves. The whole import closure reached 278 to 1,856
        # tests for one source edit on 2026-11-20's feat-cmux-next commits, every shard every time.
        out |= {t for t in selector.graph.importers.get(f, ()) if t in selector.graph.tests}
    return out, ""


def shard_files(repo: Path, shard: int, count: int, selected: set[str] | None) -> set[str]:
    """SHARD's test files (repo paths), as run-webviews-tests.sh splits them with this environment."""
    env = dict(os.environ, CMUX_WEB_TEST_LIST_ONLY="1", CMUX_WEB_TEST_SHARD=str(shard), CMUX_WEB_TEST_SHARD_COUNT=str(count))
    env.pop("CMUX_WEB_TEST_FILES", None)
    if selected is not None:
        env["CMUX_WEB_TEST_FILES"] = "\n".join(sorted(f.removeprefix(wa.WEB) for f in selected))
    out = subprocess.run(["bash", str(RUNNER)], cwd=repo / "webviews", env=env, capture_output=True, text=True,
                         check=True).stdout
    return {wa.WEB + line for line in out.splitlines() if line}


def pick(repo: Path, base: str, head: str, count: int) -> tuple[list[int], str]:
    everything = list(range(1, count + 1))
    try:
        files = wa.changed(repo, base, head)
    except subprocess.CalledProcessError as err:
        return everything, f"cannot diff {base}..{head} ({err.stderr.strip()})"
    selector = wa.Selector(repo)
    direct, why = touched(selector, files)
    if direct is None:
        return everything, why
    if not direct:
        return [1], "the change touches no webviews test"
    selected, _ = selector.select(files)  # what each shard runs (None: every file), as the shards pick it
    run = [1] + [shard for shard in everything[1:] if shard_files(repo, shard, count, selected) & direct]
    return run, f"{len(direct)} touched tests"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--base")
    ap.add_argument("--head", default="HEAD")
    ap.add_argument("--count", type=int, required=True)
    ap.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[2])
    ap.add_argument("--all", action="store_true", help="every shard (a push, full-ci): print the whole matrix")
    args = ap.parse_args(argv)
    if args.all:
        print(matrix(list(range(1, args.count + 1)), args.count))
        return 0
    if not args.base:
        ap.error("--base is required without --all")
    try:
        shards, why = pick(args.repo, args.base, args.head, args.count)
    except Exception as err:  # noqa: BLE001 - any failure runs every shard
        shards, why = list(range(1, args.count + 1)), f"the pick failed ({type(err).__name__}: {err})"
    print(f"webviews pr shards: {len(shards)} of {args.count} ({','.join(map(str, shards))}): {why}", file=sys.stderr)
    print(matrix(shards, args.count))
    return 0


if __name__ == "__main__":
    sys.exit(main())
