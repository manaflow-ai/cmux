#!/usr/bin/env python3
"""Name the first commit in a landing range that grew what a hibernated item costs (acpmux + cmux-tui, Linux).

Leo, 2026-11-22 (ask-5b56389121): "i also want us to keep pursuing the ability to have infinite f***ing tabs and
workspaces and s*** without getting starved of cpu/ram". memory_gate.py says whether one change grew the cost;
this walks a range (say the landings between two nightlies, or a PR's commits) and binary-searches it:

    memory_bisect.py --good SHA --bad SHA [--metric infinite_items.n100.mb_per_item] [--repeat 3]
                     [--counts 100] [--days 1] [--tolerance 0.10] [--floor-mb 0.05] [--direction grew|shrank]
        prints MEMORY_BISECT first=SHA (or first=none); exit 0 found, 1 none, 2 could not run

Run it in a clean checkout at the head whose harness should measure (`cmux-ci test -- python3
scripts/measure/memory_bisect.py --good FULLSHA --bad FULLSHA` runs at the pushed PR head). A fleet job's source is
shallow with no credential, so the range comes in by SHA from the public repository (fetch-commit.sh); pass
full SHAs of pushed commits (a landing range, or a lane branch's commits), not branch names. Candidates are the first-parent commits in
good..bad that touch cmux-tui/ (others build the same daemons). Each probe puts that commit's cmux-tui/ in place,
builds it with no LTO and 16 codegen units (the heap a run holds is data, not code; infinite-items-linux.sh's
alloc_ab note), caches the three binaries, puts HEAD's cmux-tui/ back, and runs this head's infinite-items.py on
the good build and the probe build interleaved, `repeat` times each; memory_gate.judge decides. A commit that pins
another ghostty-next, or fails to build, is skipped as git bisect skips. About 3 to 5 probes for a range of 20.
"""
from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
from typing import Callable

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import memory_gate  # noqa: E402

BINS = ("acpmux", "cmux-tui", "cmux-tui-host")


def git(root: str, *args: str) -> str:
    return subprocess.run(["git", "-C", root, *args], check=True, capture_output=True, text=True).stdout.strip()


def ensure_range(root: str, good: str, bad: str, depth: int) -> None:
    """Make good..bad present in a shallow or remote-less checkout (a fleet step's source, a `cmux-ci test` job).

    Pass full SHAs: a job cannot resolve a branch name it never fetched. Each commit comes through
    measure_fetch_commit (scripts/measure/fetch-commit.sh: origin when there is one, else the public repository,
    by SHA, no credential), the bad end with `depth` parents, deepened until the good end is in it."""
    helper = os.path.join(root, "scripts/measure/fetch-commit.sh")
    have = lambda sha: subprocess.run(["git", "-C", root, "cat-file", "-e", f"{sha}^{{commit}}"],
                                      capture_output=True).returncode == 0
    fetch = lambda sha, n: subprocess.run(["bash", "-c", 'source "$1"; measure_fetch_commit "$2" "$3" "$4"', "_",
                                           helper, root, sha, str(n)]).returncode == 0
    if not have(good) and not fetch(good, 1):
        raise SystemExit(f"memory_bisect: cannot fetch --good {good}")
    n = depth
    while True:
        if not fetch(bad, n):
            raise SystemExit(f"memory_bisect: cannot fetch --bad {bad} with {n} parents")
        if subprocess.run(["git", "-C", root, "merge-base", "--is-ancestor", good, bad], capture_output=True).returncode == 0:
            return
        if n >= 4096:
            raise SystemExit(f"memory_bisect: {good} is not an ancestor of {bad} within 4096 commits")
        n *= 4


def candidates(root: str, good: str, bad: str) -> list[str]:
    out = git(root, "rev-list", "--first-parent", "--reverse", f"{good}..{bad}", "--", "cmux-tui")
    shas = out.split()
    full_bad = git(root, "rev-parse", f"{bad}^{{commit}}")
    if not shas or shas[-1] != full_bad:
        # The bad end is judged as itself even when its own diff misses cmux-tui/: what it builds is its tree.
        shas.append(full_bad)
    return shas


def bisect(shas: list[str], is_bad: Callable[[str], "bool | None"], log=print) -> "str | None":
    """First sha in `shas` (oldest first, the last known bad) for which is_bad is True; None if the last is not bad.

    is_bad returns None for a commit that cannot be judged (skipped: the search moves to a neighbour)."""
    lo, hi = -1, len(shas) - 1  # shas[lo] good (lo=-1: the --good commit), shas[hi] bad once confirmed
    verdict = is_bad(shas[hi])
    log(f"MEMORY_BISECT probe {shas[hi][:12]} bad={verdict}")
    if not verdict:
        return None
    skipped: set[int] = set()
    while hi - lo > 1:
        mid = (lo + hi) // 2
        # Step off skipped commits toward the good end first, then toward the bad end.
        probe = next((i for i in list(range(mid, lo, -1)) + list(range(mid + 1, hi)) if i not in skipped), None)
        if probe is None:
            break
        verdict = is_bad(shas[probe])
        log(f"MEMORY_BISECT probe {shas[probe][:12]} bad={verdict}")
        if verdict is None:
            skipped.add(probe)
        elif verdict:
            hi = probe
        else:
            lo = probe
    return shas[hi]


class Builder:
    """Builds a commit's cmux-tui/ in this checkout and caches its three binaries."""

    def __init__(self, root: str, cache: str):
        self.root, self.cache = root, cache
        self.env = dict(os.environ, CARGO_PROFILE_RELEASE_LTO="false", CARGO_PROFILE_RELEASE_CODEGEN_UNITS="16",
                        CARGO_INCREMENTAL="0")
        # The memory gate's target folder (memory-gate-linux.sh): the no-LTO profile would evict the cached release.
        self.env.setdefault("CARGO_TARGET_DIR", os.path.join(os.environ.get("RUNNER_TEMP", "/tmp"), "memory-gate-target"))
        # What infinite-items-linux.sh sets up before it builds (the ghostty-next submodule a fast-checks snapshot
        # leaves empty, the pinned Zig as CMUX_ZIG): without it every probe fails in ghostty-vt-sys's build script.
        out = subprocess.run(["bash", "-c", 'source "$1" && measure_linux_build_env "$2" >&2 && env -0', "_",
                              os.path.join(root, "scripts/measure/linux-build-env.sh"), root],
                             env=self.env, check=True, stdout=subprocess.PIPE).stdout
        self.env = dict(kv.split("=", 1) for kv in out.decode().split("\0") if "=" in kv)
        meta = subprocess.run(["cargo", "metadata", "--locked", "--no-deps", "--format-version", "1"],
                              cwd=os.path.join(root, "cmux-tui"), env=self.env, check=True, capture_output=True,
                              text=True).stdout
        import json
        self.target = json.loads(meta)["target_directory"]
        self.pin = git(root, "rev-parse", "HEAD:ghostty-next")

    def build(self, sha: str) -> "str | None":
        dest = os.path.join(self.cache, sha)
        if os.path.isdir(dest):
            return dest
        if git(self.root, "rev-parse", f"{sha}:ghostty-next") != self.pin:
            print(f"MEMORY_BISECT skip {sha[:12]}: pins another ghostty-next", flush=True)
            return None
        try:
            git(self.root, "restore", f"--source={sha}", "--staged", "--worktree", "--", "cmux-tui")
            rc = subprocess.run(["cargo", "build", "--locked", "--release", "-p", "acpmux", "--bin", "acpmux",
                                 "-p", "cmux-tui", "--bin", "cmux-tui", "--bin", "cmux-tui-host"],
                                cwd=os.path.join(self.root, "cmux-tui"), env=self.env).returncode
        finally:
            git(self.root, "restore", "--source=HEAD", "--staged", "--worktree", "--", "cmux-tui")
        if rc != 0:
            print(f"MEMORY_BISECT skip {sha[:12]}: build failed ({rc})", flush=True)
            return None
        os.makedirs(dest)
        for name in BINS:
            shutil.copy2(os.path.join(self.target, "release", name), dest)
        return dest


def run_items(root: str, bindir: str, counts: str, days: str) -> list[str]:
    proc = subprocess.run([sys.executable, os.path.join(root, "scripts/measure/infinite-items.py"),
                           "--acpmux", os.path.join(bindir, "acpmux"), "--tui", os.path.join(bindir, "cmux-tui"),
                           "--counts", counts, "--days", days], capture_output=True, text=True)
    return proc.stdout.splitlines()


def make_judge(build: Callable[[str], "str | None"], measure: Callable[[str], list[str]], good: str, args,
               log=print) -> Callable[[str], "bool | None"]:
    def is_bad(sha: str) -> "bool | None":
        good_dir, probe_dir = build(good), build(sha)
        if good_dir is None:
            raise SystemExit("memory_bisect: the --good commit does not build here")
        if probe_dir is None:
            return None
        lines = []
        for i in range(1, args.repeat + 1):
            lines += [f"BEFORE r{i} {line}" for line in measure(good_dir)]
            lines += [f"AFTER r{i} {line}" for line in measure(probe_dir)]
        rows = memory_gate.parse(lines)
        if args.direction == "shrank":
            rows = {k: {"before": [-x for x in v["before"]], "after": [-x for x in v["after"]]} for k, v in rows.items()}
        state, judged = memory_gate.verdict(rows, args.metric, args.tolerance, args.floor_mb)
        for name, j in judged.items():
            log(f"MEMORY_BISECT {sha[:12]} {name} good={abs(j['before_median'])} probe={abs(j['after_median'])} "
                f"change={j['delta']:+} bound={j['bound']}")
        if state == "no-data":
            return None
        return state == "grew"
    return is_bad


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--good", required=True)
    p.add_argument("--bad", required=True)
    p.add_argument("--metric", default="infinite_items.n100.mb_per_item")
    p.add_argument("--repeat", type=int, default=3)
    p.add_argument("--counts", default="100")
    p.add_argument("--days", default="1")
    p.add_argument("--tolerance", type=float, default=0.10)
    p.add_argument("--floor-mb", type=float, default=0.05)
    p.add_argument("--direction", choices=("grew", "shrank"), default="grew",
                   help="shrank finds the commit that cut the cost (to credit a fix)")
    p.add_argument("--list", action="store_true", help="print the candidates and stop")
    p.add_argument("--depth", type=int, default=32, help="first fetch depth below --bad in a shallow checkout")
    args = p.parse_args(argv)
    root = git(os.getcwd(), "rev-parse", "--show-toplevel")
    ensure_range(root, args.good, args.bad, args.depth)
    shas = candidates(root, args.good, args.bad)
    print(f"MEMORY_BISECT range {args.good[:12]}..{args.bad[:12]} candidates={len(shas)}", flush=True)
    if args.list:
        print("\n".join(shas))
        return 0
    if git(root, "status", "--porcelain", "--untracked-files=no", "--", "cmux-tui"):
        print("memory_bisect: cmux-tui/ has uncommitted changes; each probe swaps it out", file=sys.stderr)
        return 2
    cache = tempfile.mkdtemp(prefix="memory-bisect-")
    try:
        builder = Builder(root, cache)
        is_bad = make_judge(builder.build, lambda d: run_items(root, d, args.counts, args.days), args.good, args,
                            log=lambda s: print(s, flush=True))
        first = bisect(shas, is_bad, log=lambda s: print(s, flush=True))
    finally:
        shutil.rmtree(cache, ignore_errors=True)
    if first is None:
        print(f"MEMORY_BISECT first=none ({args.bad[:12]} did not {args.direction} against {args.good[:12]})")
        return 1
    subject = git(root, "log", "-1", "--format=%s", first)
    print(f"MEMORY_BISECT first={first} {subject}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
