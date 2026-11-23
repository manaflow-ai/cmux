#!/usr/bin/env python3
"""Whether a pull request reaches cmux-next.yml's `cmux-next fast tier (cargo)` job (fast-tier-cargo).

That job runs `scripts/cmux-next/fast-tier.py --kind cargo --kind script`: the cargo tests of cmux-tui crates
and the script entries of scripts/cmux-next/fast-tier.json. A pull request's change reaches it when a changed
path is
- inside a cargo entry's workspace (its `path`), or in a script entry's folder;
- a cmux-tui build input (scripts/cmux-next/cmux-tui-tree-inputs.txt: a `tree` folder, a `blob` file or a
  `gitlink`; scripts/ci/check_cmux_tui_tree_inputs.py keeps that list complete for the crates' embeds);
- a file the job's steps or the script entries run (JOB_INPUTS, SCRIPT_INPUTS);
- or the pull request carries the full-ci label.
Any other change (Swift, web, docs, other CI) cannot move the job's verdict, so the pull request skips the job
(a job-level `if:`, which reports skipped). Every feat-cmux-next push still runs it, and the merge car runs the
cargo kind itself when no passing fast-tier-cargo check covers it (scripts/ci/car_guards.py REUSE).

Over 11-13..19 the job was 2.94% of pull request runner-minutes and its own red was the only real red on 6 of
9,361 heads (0.06%): cmuxterm-hq docs/ci/bottleneck-and-skip-candidates-2026-11-21.md.

A registry or inputs file that cannot be read reads as reached (the job runs).

    fast_tier_cargo_route.py --changed-files FILE [--labels a,b] [--root .] [--github-output FILE]

Test: tests/test_cmux_next_checks_workflow.py FastTierCargoRoute.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

REGISTRY = "scripts/cmux-next/fast-tier.json"
TREE_INPUTS = "scripts/cmux-next/cmux-tui-tree-inputs.txt"
# What the job's own steps read and run (cmux-next.yml fast-tier-cargo), and this router.
JOB_INPUTS = (
    ".github/workflows/cmux-next.yml",
    ".github/actions/setup-cmux-tui-rust/",
    ".github/actions/ghostty-zig-packages/",
    ".gitmodules",
    "scripts/cmux-next/fast-tier.py",
    "scripts/cmux-next/fast-tier.json",
    "scripts/cmux-next/cargo-locks.py",
    "scripts/ci/oops/",
    "scripts/ci/init-submodule.sh",
    "scripts/install-zig-ci.sh",
    "scripts/ci/fast_tier_cargo_route.py",
)
# What the script entries import or read outside their own folder (test_perf_completeness.py: the perf gate).
SCRIPT_INPUTS = ("scripts/cmux-next/perf-budgets.py", "scripts/cmux-next/perf-budgets.json", "scripts/perf-bench/")
FORCE_LABELS = {"full-ci"}


def _under(path: str, prefix: str) -> bool:
    """A prefix ending in / is a folder; any other is one file (or a submodule's gitlink)."""
    return path.startswith(prefix) if prefix.endswith("/") else path == prefix


def inputs(root: Path) -> list[str] | None:
    """The path prefixes that reach the job, or None when the registry or tree inputs cannot be read."""
    try:
        registry = json.loads((root / REGISTRY).read_text(encoding="utf-8"))
        tree = (root / TREE_INPUTS).read_text(encoding="utf-8")
    except (OSError, ValueError):
        return None
    prefixes = list(JOB_INPUTS) + list(SCRIPT_INPUTS)
    for entry in registry.get("entries", []):
        if entry.get("kind") == "cargo" and entry.get("path"):
            prefixes.append(entry["path"].rstrip("/") + "/")
        elif entry.get("kind") == "script" and entry.get("path"):
            prefixes.append(entry["path"].rsplit("/", 1)[0] + "/")
    for raw in tree.splitlines():
        parts = raw.split("#", 1)[0].split()
        if len(parts) != 2:
            continue
        kind, name = parts
        prefixes.append(name.rstrip("/") + "/" if kind == "tree" else name)
    return prefixes


def reaches(changed: list[str], labels: set[str], root: Path) -> tuple[bool, str]:
    if labels & FORCE_LABELS:
        return True, "full-ci label"
    prefixes = inputs(root)
    if prefixes is None:
        return True, f"could not read {REGISTRY} or {TREE_INPUTS}; running it"
    for path in changed:
        for prefix in prefixes:
            if _under(path, prefix):
                return True, f"{path} (under {prefix})"
    return False, "no changed path is a cargo, script-entry or job input"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--changed-files", required=True)
    parser.add_argument("--labels", default="")
    parser.add_argument("--root", default=".")
    parser.add_argument("--github-output")
    args = parser.parse_args(argv)
    try:
        changed = [line.strip() for line in Path(args.changed_files).read_text(encoding="utf-8").splitlines()
                   if line.strip()]
    except OSError as error:
        changed, reached, why = [], True, f"could not read the changed files ({error}); running it"
    else:
        reached, why = reaches(changed, {label for label in args.labels.split(",") if label}, Path(args.root))
    line = f"fast_tier_cargo={'true' if reached else 'false'}"
    print(f"{line}: {why}")
    if args.github_output:
        with open(args.github_output, "a", encoding="utf-8") as out:
            out.write(line + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
