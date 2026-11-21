#!/usr/bin/env python3
"""The react-apps-check shards a pull request runs: shard 1, and each other shard that holds a test the change
touches. A feat-cmux-next push runs every shard (ci-web.yml calls this only on a pull request).

    webviews_pr_shards.py --base REF [--head REF] --count N [--repo DIR]
    webviews_pr_shards.py --all --count N        # every shard: a push, the full-ci label, a failed pick
    webviews_pr_shards.py --base REF [--head REF] --count N --files-of 1,3   # those shards' test files
    webviews_pr_shards.py --base REF [--head REF] --count N --direct-out F   # also each picked shard's touched tests

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
    the picked shards from 2 to N become one job that runs only those touched tests (--direct-out), not each shard's
    whole share of the affected closure: the shards were picked for them, and the closure share is what the 0%
    above measured. Shard 1 keeps its whole share;
  - every shard for a build or runner input (webviews_affected.EVERYTHING: package.json, bun.lock, vite configs, the
    runner scripts, ci-web.yml, this file, the preload and what it imports) or a deleted source. A test helper
    (test/support/) or webviews script (webviews/scripts/) counts as a source here: the tests that import it.
A shard's files come from the very split it makes itself (run-webviews-tests.sh CMUX_WEB_TEST_LIST_ONLY with the
run's one duration manifest, widths and head start, passed in the environment), so the pick and the shards agree.
Every feat-cmux-next push still runs all N shards over every file: a red a skipped shard would have caught shows on
the base's next push (cmux-next-web.yml) and its base-red tracking.

Any error picks every shard: the pick may only ever run more.

--files-of prints the test files (webviews-relative, one a line) that the named shards run for this change, from the
same split. react-apps-base-early replays the base's red files only among them (RFD 0023 item 3, cmuxterm-hq
docs/rfd/0023-ci-cd-design.md): a head red can only be in a file a head shard ran, so a base verdict on any other file
is never read. Any error exits non-zero and prints nothing; the job then keeps its whole affected list.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import webviews_affected as wa  # noqa: E402

RUNNER = Path(__file__).resolve().parent / "run-webviews-tests.sh"
# Build inputs webviews_affected.EVERYTHING lists that a pull request's pick treats as sources: test helpers and
# webviews scripts. On 11-20's merges they made 14 of 17 every-shard picks; the import graph reaches their tests.
HOP = re.compile(r"^webviews/(test/support/|scripts/)")
# A JS block or line comment (a line comment starts a line or follows a space, so `https://` in a string stays).
COMMENT = re.compile(r"/\*[\s\S]*?\*/|(?:^|(?<=\s))//[^\n]*", re.M)


def matrix(shards: list[int], count: int) -> str:
    return json.dumps([{"shard": shard, "shard_count": count} for shard in shards], separators=(",", ":"))


def read_beyond_imports(selector: "wa.Selector", f: str) -> str:
    """Why a helper or script change must run every shard, or "" when only its importers can see it.

    A vite or compiler config (a code file at the top of webviews/) that imports it, directly or not, or names its
    path (`new URL("./scripts/lint/x.mjs")`) feeds every bundle a test may load. A module some test reaches that names
    its path without importing it reads it as data, and one that reads files and quotes its basename (10 or more
    characters, outside comments) may read it by a joined path: none of those is an import edge. A script only shard
    1's checks run (package.json scripts, a check's own baseline) needs no other shard: shard 1 always runs.
    """
    rel = f.removeprefix(wa.WEB)
    name = Path(f).name
    importers = selector.graph.importers.get(f, set())
    for source in selector.text:
        if "/" not in source.removeprefix(wa.WEB) and source.endswith(wa.ft.EXTENSIONS) and wa.EVERYTHING.search(source) \
                and (f in selector.closure(source) or rel in selector.text[source]):
            return f"{f} is loaded by the build input {source}"
    reached = set().union(*(selector.closure(t) for t in selector.graph.tests))
    reads = set().union(*(selector.closure(t) for t in selector.always)) if selector.always else set()
    quoted = re.compile(r"[\"'`]" + re.escape(name) + r"[\"'`]")
    for source in sorted(reached - importers - {f}):
        text = COMMENT.sub("", selector.text.get(source, ""))
        if rel in text or f in text:
            return f"{f} is read as data by {source}"
        if source in reads and len(name) >= wa.NAME_MIN and quoted.search(text):
            return f"{f} may be read by {source}, which reads files"
    return ""


def touched(selector: "wa.Selector", files: list[str]) -> tuple[set[str] | None, str]:
    """The tests the change touches directly (repo paths), or None for every shard, and why."""
    out: set[str] = set()
    for f in files:
        if f in selector.preload or (wa.EVERYTHING.search(f) and not HOP.search(f)):
            return None, f"{f} is a build or runner input"
        if wa.EVERYTHING.search(f):
            # A test helper or webviews script (not the preload's): the tests that import it, as for a source, unless a
            # build input loads it or a file reads it as data (below). A file nothing imports or names touches none;
            # shard 1 still runs its whole share.
            why = read_beyond_imports(selector, f)
            if why:
                return None, why
            out |= {t for t in selector.graph.importers.get(f, ()) if t in selector.graph.tests}
            continue
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


def pick(repo: Path, base: str, head: str, count: int) -> tuple[list[int], str, dict[int, list[str]]]:
    """The shards to run, why, and for each shard from 2 to N its touched tests (webviews-relative)."""
    everything = list(range(1, count + 1))
    try:
        files = wa.changed(repo, base, head)
    except subprocess.CalledProcessError as err:
        return everything, f"cannot diff {base}..{head} ({err.stderr.strip()})", {}
    selector = wa.Selector(repo)
    direct, why = touched(selector, files)
    if direct is None:
        return everything, why, {}
    if not direct:
        return [1], "the change touches no webviews test", {}
    selected, _ = selector.select(files)  # what each shard runs (None: every file), as the shards pick it
    hits = {shard: shard_files(repo, shard, count, selected) & direct for shard in everything[1:]}
    hits = {shard: hit for shard, hit in hits.items() if hit}
    if not hits:
        return [1], f"{len(direct)} touched tests, all in shard 1", {}
    # One job carries every touched test outside shard 1: a dozen files do not need a runner each, and each shard
    # job pays its own checkout, install and engines before its first test. It takes the lowest picked number.
    first = min(hits)
    own = {first: sorted(f.removeprefix(wa.WEB) for hit in hits.values() for f in hit)}
    return [1, first], f"{len(direct)} touched tests, {len(own[first])} outside shard 1 in one job", own


def files_of(repo: Path, base: str, head: str, count: int, shards: list[int]) -> list[str]:
    """The test files SHARDS run for BASE..HEAD (webviews-relative), as each splits them."""
    selected, _ = wa.Selector(repo).select(wa.changed(repo, base, head))
    out: set[str] = set()
    for shard in shards:
        out |= shard_files(repo, shard, count, selected)
    return sorted(f.removeprefix(wa.WEB) for f in out)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--base")
    ap.add_argument("--head", default="HEAD")
    ap.add_argument("--count", type=int, required=True)
    ap.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[2])
    ap.add_argument("--all", action="store_true", help="every shard (a push, full-ci): print the whole matrix")
    ap.add_argument("--files-of", help="comma-separated shards: print the test files they run, one a line")
    ap.add_argument("--direct-out", type=Path,
                    help="write {shard: [touched test files]} for the one picked shard past 1 (JSON)")
    args = ap.parse_args(argv)
    if args.files_of:
        if not args.base:
            ap.error("--base is required with --files-of")
        shards = [int(x) for x in args.files_of.split(",") if x.strip()]
        if not shards or any(not 1 <= x <= args.count for x in shards):
            ap.error(f"--files-of names shards outside 1..{args.count}")
        files = files_of(args.repo, args.base, args.head, args.count, shards)
        print(f"webviews pr shards: {len(files)} test files in shards {args.files_of}", file=sys.stderr)
        sys.stdout.write("".join(f + "\n" for f in files))
        return 0
    if args.all:
        print(matrix(list(range(1, args.count + 1)), args.count))
        return 0
    if not args.base:
        ap.error("--base is required without --all")
    own: dict[int, list[str]] = {}
    try:
        shards, why, own = pick(args.repo, args.base, args.head, args.count)
    except Exception as err:  # noqa: BLE001 - any failure runs every shard
        shards, why = list(range(1, args.count + 1)), f"the pick failed ({type(err).__name__}: {err})"
    if args.direct_out:
        # No entry for a shard (an empty map on every-shard picks) runs that shard's whole affected split.
        args.direct_out.write_text(json.dumps({str(k): v for k, v in own.items()}, separators=(",", ":")) + "\n")
    print(f"webviews pr shards: {len(shards)} of {args.count} ({','.join(map(str, shards))}): {why}", file=sys.stderr)
    print(matrix(shards, args.count))
    return 0


if __name__ == "__main__":
    sys.exit(main())
