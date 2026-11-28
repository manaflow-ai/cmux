#!/usr/bin/env python3
"""Fail on a workflow finding this change adds: the actionlint findings at HEAD that its base does not have.

    workflow_start_lint.py --actionlint PATH [--base REV]

A workflow file GitHub cannot parse starts no job: the run ends `failure` with 0 jobs, no check run and no log, named
by its file path ("workflow did not start (0 jobs)"). When that file is a callee of pr-router.yml, every pull request
whose head carries it gets a pr-router run with 0 jobs, so no routed check runs (cmux#55346 put `continue-on-error`
twice in one step of cmux-next-size-budget.yml at 08:45Z on 2026-11-25; every head branched before #56090's fix at
10:26Z then failed pr-router, 300 runs in two hours, and helpers merged past it). Nothing linted feat-cmux-next pull
requests: ci-guards.yml's "Lint every workflow" runs in the CI guard group, which those skip unless labeled full-ci.

This runs actionlint (shellcheck and pyflakes off: a few seconds, and the findings are the ones that stop a run
starting or misread an expression) over every workflow at HEAD and at BASE (a copy of BASE's .github/), and fails on
each finding HEAD has more of than BASE, matched by file, kind and message with line and column numbers dropped, so a
finding already on the base, or one that moved, never fails the change. `runner-label` findings are not compared: the
pool labels (cmux-linux) live in expressions and repository variables actionlint cannot read.

Exit 0: no new finding. 1: a new finding (each printed as a GitHub error annotation). 2: actionlint could not run.
"""
from __future__ import annotations

import argparse
import collections
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
IGNORED_KINDS = frozenset({"runner-label"})
POSITION = re.compile(r"\bline:?\s*\d+(,\s*col:?\s*\d+)?|\bcol(umn)?:?\s*\d+", re.IGNORECASE)


def findings(actionlint: str, tree: Path) -> list[dict]:
    """actionlint's findings for every workflow under TREE/.github/workflows (an empty list when it found none)."""
    if not (tree / ".github" / "workflows").is_dir():
        return []
    proc = subprocess.run([actionlint, "-shellcheck=", "-pyflakes=", "-format", "{{json .}}"], cwd=tree,
                          capture_output=True, text=True, timeout=300, check=False)
    # 0: none; 1: findings; anything else is actionlint failing to run.
    if proc.returncode not in (0, 1):
        raise RuntimeError(f"actionlint exited {proc.returncode} in {tree}: {proc.stderr.strip()[:2000]}")
    out = proc.stdout.strip()
    return [f for f in (json.loads(out) if out else []) if f.get("kind") not in IGNORED_KINDS]


def key(finding: dict) -> tuple[str, str, str]:
    """A finding with its positions dropped, so one that only moved matches its base twin."""
    return finding.get("filepath", ""), finding.get("kind", ""), POSITION.sub("", finding.get("message", ""))


def new_findings(head: list[dict], base: list[dict]) -> list[dict]:
    """HEAD's findings beyond BASE's count of the same key, in HEAD's order."""
    left = collections.Counter(key(f) for f in base)
    added = []
    for finding in head:
        k = key(finding)
        if left[k]:
            left[k] -= 1
        else:
            added.append(finding)
    return added


def base_tree(rev: str, into: Path) -> bool:
    """Write REV's .github/ under INTO (a git repository, so actionlint finds its project); False when REV has none."""
    subprocess.run(["git", "init", "-q", str(into)], check=True)
    listed = subprocess.run(["git", "ls-tree", "-r", "--name-only", rev, "--", ".github"], cwd=ROOT,
                            capture_output=True, text=True, check=True).stdout.split()
    if not listed:
        return False
    archive = subprocess.run(["git", "archive", "--format=tar", rev, ".github"], cwd=ROOT, capture_output=True,
                             check=True).stdout
    subprocess.run(["tar", "-x", "-C", str(into)], input=archive, check=True)
    return True


def annotate(finding: dict) -> str:
    message = finding.get("message", "").replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
    return (f"::error file={finding.get('filepath')},line={finding.get('line')},col={finding.get('column')},"
            f"title=workflow finding this change adds ({finding.get('kind')})::{message}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--actionlint", required=True, help="the actionlint binary")
    parser.add_argument("--base", default="HEAD^1", help="the revision to compare with (default HEAD^1)")
    args = parser.parse_args(argv)
    try:
        head = findings(args.actionlint, ROOT)
        with tempfile.TemporaryDirectory(prefix="workflow-start-lint-") as tmp:
            base = findings(args.actionlint, Path(tmp)) if base_tree(args.base, Path(tmp)) else []
    except (RuntimeError, subprocess.SubprocessError, OSError, json.JSONDecodeError) as err:
        print(f"workflow_start_lint: could not lint: {err}", file=sys.stderr)
        return 2
    added = new_findings(head, base)
    print(f"workflow_start_lint: {len(head)} finding(s) at HEAD, {len(base)} at {args.base}, {len(added)} new")
    for finding in added:
        print(annotate(finding))
        print(f"{finding.get('filepath')}:{finding.get('line')}:{finding.get('column')}: {finding.get('message')} "
              f"[{finding.get('kind')}]")
    if added:
        print("A workflow GitHub cannot parse starts 0 jobs, and when pr-router.yml calls it every pull request's router "
              "run fails with it. Fix the finding; never merge past a 0-job router run.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    os.environ.setdefault("PYTHONDONTWRITEBYTECODE", "1")
    sys.exit(main())
