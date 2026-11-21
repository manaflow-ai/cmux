#!/usr/bin/env python3
"""Judge a pull request's red gate steps against its merge parent: a red the base has too is a warning.

    gate_base_again.py --gate VAR=CMD [--gate VAR=CMD]... [--base REF] [--timeout S]

Each --gate names a gate step's outcome variable (its value is read from the environment: success, failure,
skipped) and the command the step ran, from the repository root. For each gate whose outcome is failure, this runs
the same command again on the base (default HEAD^1, the merge parent of a pull request's merge commit) in a
detached worktree that borrows the head's installed node_modules, and compares:

- a unittest command (its output carries `FAIL: name (module.Class)` / `ERROR: ...` lines) is compared per test:
  the gate is the change's own red when any test red on the head is not red on the base;
- anything else is compared per step: red on both is the base's.

A base run that cannot be judged (the worktree failed, the command timed out on the base, the base passed) leaves
the red the change's. Nothing is excused on a guess.

It writes `own_red=true|false`, `own=VARS` and `base=VARS` to $GITHUB_OUTPUT, and one ::warning:: per base red.

Why (Leo, 2026-11-21: "these sorts of things probably shouldn't happen"): #48230 landed an experiment id with a dot
(`agent-pane.high-contrast-look`); 'Check PR-scoped webview rules' then failed on feat-cmux-next and on every web
pull request into it, and since #49118 a red gate also skipped the pull request's webview tests, so for hours no
web pull request got a test verdict for a red none of them made. The type check (fast_gate_webviews_checks.py) and
the tests (webviews-tests-new-reds.sh) already charged only new reds; these gates did not.
"""
from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

TEST_LINE = re.compile(r"^(?:FAIL|ERROR): (\S+ \([^)]*\))", re.M)
LINKED = ("node_modules", "webviews/node_modules")


def run(cmd: str, cwd: Path, timeout: int) -> tuple[int | None, str]:
    """(exit code, output); None for a timeout."""
    try:
        p = subprocess.run(cmd, shell=True, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           text=True, timeout=timeout, env={**os.environ, "CMUX_GATE_BASE_AGAIN": "1"})
    except subprocess.TimeoutExpired as e:
        out = e.stdout.decode(errors="replace") if isinstance(e.stdout, bytes) else (e.stdout or "")
        return None, out
    return p.returncode, p.stdout


def red_tests(output: str) -> set[str]:
    return set(TEST_LINE.findall(output))


def judge(head_out: str, base_code: int | None, base_out: str) -> tuple[str, str]:
    """('base' | 'own', why)."""
    if base_code is None:
        return "own", "the base run timed out, so it judges nothing"
    if base_code == 0:
        return "own", "it passes on the base"
    head_tests = red_tests(head_out)
    if head_tests:
        new = sorted(head_tests - red_tests(base_out))
        if new:
            return "own", "red only on the change: " + ", ".join(new)
        return "base", f"every red test is red on the base too ({len(head_tests)})"
    return "base", "the step is red on the base too"


def make_base_tree(root: Path, base: str) -> Path | None:
    tree = Path(tempfile.mkdtemp(prefix="gate-base-")) / "base"
    r = subprocess.run(["git", "-C", str(root), "worktree", "add", "--detach", str(tree), base],
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if r.returncode != 0:
        print(f"::warning::gate base-again: no worktree at {base}: {r.stdout.strip()[-400:]}")
        return None
    for rel in LINKED:
        src, dst = root / rel, tree / rel
        if src.is_dir() and not dst.exists():
            dst.parent.mkdir(parents=True, exist_ok=True)
            dst.symlink_to(src)
    return tree


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--gate", action="append", default=[], metavar="VAR=CMD")
    ap.add_argument("--base", default="HEAD^1")
    ap.add_argument("--root", default=".")
    ap.add_argument("--timeout", type=int, default=900)
    args = ap.parse_args(argv)

    root = Path(args.root).resolve()
    gates = [g.split("=", 1) for g in args.gate]
    failed = [(var, cmd) for var, cmd in gates if os.environ.get(var) == "failure"]
    own: list[str] = []
    base_reds: list[str] = []
    tree = make_base_tree(root, args.base) if failed else None
    try:
        for var, cmd in failed:
            if tree is None:
                own.append(var)
                continue
            head_code, head_out = run(cmd, root, args.timeout)
            if head_code == 0:
                # Passed when run again alone on the head: not this change's red either, but say so.
                print(f"::warning::{var}: red in the step, green when run again on the head (flaky)")
                base_reds.append(var)
                continue
            base_code, base_out = run(cmd, tree, args.timeout)
            verdict, why = judge(head_out, base_code, base_out)
            if verdict == "base":
                print(f"::warning::{var} is red on the base ({args.base}) too, so not this change's: {why}")
                base_reds.append(var)
            else:
                print(f"{var}: the change's red: {why}")
                own.append(var)
    finally:
        if tree is not None:
            subprocess.run(["git", "-C", str(root), "worktree", "remove", "--force", str(tree)],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            shutil.rmtree(tree.parent, ignore_errors=True)

    out = os.environ.get("GITHUB_OUTPUT")
    lines = [f"own_red={'true' if own else 'false'}", f"own={' '.join(own)}", f"base={' '.join(base_reds)}"]
    if out:
        with open(out, "a") as f:
            f.write("\n".join(lines) + "\n")
    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main())
