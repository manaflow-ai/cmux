#!/usr/bin/env python3
"""Same-host A/B of the `action-perform` perf-hot bench (perf-hot-benches.json): base SHA against head SHA.

`run` makes a detached worktree of each SHA, copies the head's ActionPerformBench.swift into the base
worktree (the bench uses only API the base has), and runs `swift test -c release --filter
ActionPerformBench` in the two worktrees alternately, `--repeats` times each, on this one host, as the
oracle's same-host pairing does (p15-oracle task 008). Each run prints one line per round; a run's
mean is one sample. The result is head minus base in ns per perform, with a 95% Student t interval
over the paired runs (run i of base with run i of head), so run-to-run noise (build layout, thermal
state) is inside the interval. `compare` does the same from saved logs.

Fleet only (agents never compile on the person's Mac):
    cmux-ci run --class isolated --ref HEAD_SHA --script \
        "python3 scripts/cmux-next/action-perform-ab.py run --base BASE_SHA --head HEAD_SHA"
    python3 scripts/cmux-next/action-perform-ab.py compare base-1.log head-1.log base-2.log head-2.log ...
"""
import argparse
import json
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile
from typing import List, Sequence, Tuple

PACKAGE = "Packages/macOS/CmuxNext"
BENCH = "Tests/CmuxNextActionsTests/ActionPerformBench.swift"
ROUND = re.compile(r"^action-perform-bench round=(\d+) ns=([0-9.]+)$", re.MULTILINE)
# Two-sided 95% Student t quantiles by degrees of freedom; 1.96 past the table.
T95 = {1: 12.706, 2: 4.303, 3: 3.182, 4: 2.776, 5: 2.571, 6: 2.447, 7: 2.365, 8: 2.306, 9: 2.262,
       10: 2.228, 11: 2.201, 12: 2.179, 13: 2.160, 14: 2.145, 15: 2.131, 19: 2.093, 24: 2.064, 29: 2.045}


def t95(df: int) -> float:
    fitting = [key for key in T95 if key <= df]
    return T95[max(fitting)] if df <= 29 else 1.96


def rounds(text: str) -> List[float]:
    """The ns-per-perform values of one bench run's output."""
    return [float(match.group(2)) for match in ROUND.finditer(text)]


def mean(values: Sequence[float]) -> float:
    return sum(values) / len(values)


def paired(base_runs: Sequence[Sequence[float]], head_runs: Sequence[Sequence[float]]) -> dict:
    """Head minus base over paired run means, with a 95% interval (needs at least two pairs)."""
    if len(base_runs) != len(head_runs) or len(base_runs) < 2:
        raise ValueError("needs the same number of base and head runs, at least two")
    for run in list(base_runs) + list(head_runs):
        if not run:
            raise ValueError("a run printed no action-perform-bench rounds")
    base_means = [mean(run) for run in base_runs]
    head_means = [mean(run) for run in head_runs]
    differences = [head - base for base, head in zip(base_means, head_means)]
    delta = mean(differences)
    variance = sum((d - delta) ** 2 for d in differences) / (len(differences) - 1)
    half = t95(len(differences) - 1) * math.sqrt(variance / len(differences))
    return {"pairs": len(differences), "baseNs": mean(base_means), "headNs": mean(head_means),
            "deltaNs": delta, "ci95": [delta - half, delta + half], "underBudget": delta + half < 1000.0}


def describe(result: dict) -> str:
    low, high = result["ci95"]
    return (f"action-perform A/B: {result['pairs']} paired runs: base {result['baseNs']:.1f} ns/perform, "
            f"head {result['headNs']:.1f}; head adds {result['deltaNs']:.1f} ns (95% CI {low:.1f} to {high:.1f})")


def git(repo: str, *args: str) -> str:
    return subprocess.run(["git", "-C", repo, *args], check=True, capture_output=True, text=True).stdout.strip()


def bench(worktree: str) -> List[float]:
    env = dict(os.environ, CMUX_ACTION_PERFORM_BENCH="1")
    done = subprocess.run(["swift", "test", "-c", "release", "--filter", "ActionPerformBench"],
                          cwd=os.path.join(worktree, PACKAGE), env=env, capture_output=True, text=True)
    if done.returncode != 0:
        sys.stderr.write(done.stdout[-4000:] + done.stderr[-4000:])
        raise SystemExit(f"swift test failed in {worktree}")
    return rounds(done.stdout)


def run(args: argparse.Namespace) -> int:
    repo = git(os.getcwd(), "rev-parse", "--show-toplevel")
    work = tempfile.mkdtemp(prefix="action-perform-ab-")
    trees = {"base": os.path.join(work, "base"), "head": os.path.join(work, "head")}
    try:
        for arm, sha in (("base", args.base), ("head", args.head)):
            git(repo, "worktree", "add", "--detach", trees[arm], sha)
        shutil.copyfile(os.path.join(trees["head"], PACKAGE, BENCH), os.path.join(trees["base"], PACKAGE, BENCH))
        runs: dict = {"base": [], "head": []}
        for index in range(args.repeats):
            # Alternate which SHA goes first, so neither always runs on a warmer host.
            for arm in (("base", "head") if index % 2 == 0 else ("head", "base")):
                runs[arm].append(bench(trees[arm]))
        result = paired(runs["base"], runs["head"])
        result.update({"base": args.base, "head": args.head})
        print(describe(result))
        print(json.dumps(result, sort_keys=True))
        return 0
    finally:
        for tree in trees.values():
            if os.path.isdir(tree):
                subprocess.run(["git", "-C", repo, "worktree", "remove", "--force", tree], check=False)
        shutil.rmtree(work, ignore_errors=True)


def compare(args: argparse.Namespace) -> int:
    if len(args.logs) % 2:
        raise SystemExit("compare takes base and head logs in pairs: BASE1 HEAD1 BASE2 HEAD2 ...")
    texts = []
    for name in args.logs:
        with open(name, encoding="utf-8") as handle:
            texts.append(rounds(handle.read()))
    result = paired(texts[0::2], texts[1::2])
    print(describe(result))
    print(json.dumps(result, sort_keys=True))
    return 0


def self_test() -> int:
    text = "noise\naction-perform-bench round=0 ns=10.500\naction-perform-bench round=1 ns=11.500\n"
    assert rounds(text) == [10.5, 11.5]
    result = paired([[10.0, 12.0], [11.0, 11.0], [12.0, 10.0]], [[13.0, 13.0], [12.0, 14.0], [13.0, 12.0]])
    assert result["pairs"] == 3 and abs(result["deltaNs"] - (13.0 - 11.0 + 13.0 - 11.0 + 12.5 - 11.0) / 3) < 1e-9
    low, high = result["ci95"]
    assert low < result["deltaNs"] < high and result["underBudget"]
    assert t95(4) == 2.776 and t95(17) == 2.131 and t95(100) == 1.96
    for bad in (([[1.0]], [[2.0]]), ([[1.0], [2.0]], [[1.0]]), ([[1.0], []], [[1.0], [2.0]])):
        try:
            paired(*bad)
        except ValueError:
            continue
        raise AssertionError(f"accepted {bad}")
    print("action-perform-ab self-test: ok")
    return 0


def main(argv: Sequence[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    run_parser = commands.add_parser("run", help="build and run both SHAs alternately on this host")
    run_parser.add_argument("--base", required=True)
    run_parser.add_argument("--head", required=True)
    run_parser.add_argument("--repeats", type=int, default=5, help="runs per SHA (at least 2)")
    compare_parser = commands.add_parser("compare", help="the A/B from saved bench logs")
    compare_parser.add_argument("logs", nargs="+", help="BASE1 HEAD1 BASE2 HEAD2 ...")
    commands.add_parser("self-test", help="check the parser and the statistics")
    args = parser.parse_args(argv)
    if args.command == "run":
        if args.repeats < 2:
            parser.error("--repeats must be at least 2")
        return run(args)
    if args.command == "compare":
        return compare(args)
    return self_test()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
