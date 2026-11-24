#!/usr/bin/env python3
"""Whether a pull request reaches cmux-next.yml's `cmux-next fast tier (cargo)` job (fast-tier-cargo).

That job runs `scripts/cmux-next/fast-tier.py --kind cargo --kind script`: the cargo tests of two cmux-tui
packages (each cargo entry's `package`) and the script entries of scripts/cmux-next/fast-tier.json. A pull
request runs it when a changed path is
- inside the crate folder of a cargo entry's own package (cmux-tui/crates/<dir>/ whose Cargo.toml names it);
- a file of the workspace root that reaches every crate (WORKSPACE_ROOT_INPUTS: Cargo.toml, Cargo.lock, the
  toolchain pin, .cargo/) or the ghostty-next gitlink the core links;
- in a script entry's folder;
- a file the job's steps or the script entries run (JOB_INPUTS, SCRIPT_INPUTS);
- or the pull request carries the full-ci label.
A change to another crate the entries depend on, or to another cmux-tui tree input (webviews/, schemas/, ...),
no longer runs it on the pull request: 111 of the workspace's 161 crates and every tree input reached it, so
59% of pull request heads ran it (12.6 min each, 43,295 runner-min on 2026-11-22T21..11-23T21, the largest
job of cmux-next.yml). Those changes are tested after the merge instead: every feat-cmux-next push runs the
job, and the merge car runs `cargo test` on cargo_affected.py's crates (the changed crates and every dependent,
so these two packages too) whenever no passing fast-tier-cargo check covers it (scripts/ci/car_guards.py REUSE).

Over 11-13..19 the job was 2.94% of pull request runner-minutes and its own red was the only real red on 6 of
9,361 heads (0.06%): cmuxterm-hq docs/ci/bottleneck-and-skip-candidates-2026-11-21.md.

A registry or workspace that cannot be read, or a cargo entry whose package no crate folder names, reads as the
whole entry `path` (the job runs on any change under it).

    fast_tier_cargo_route.py --changed-files FILE [--labels a,b] [--root .] [--github-output FILE]

Test: tests/test_cmux_next_checks_workflow.py FastTierCargoRoute.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

REGISTRY = "scripts/cmux-next/fast-tier.json"
# Files of a cargo workspace root that reach every crate in it, and what the core links outside cmux-tui/.
WORKSPACE_ROOT_INPUTS = ("Cargo.toml", "Cargo.lock", "rust-toolchain.toml", "rust-toolchain", ".cargo/")
LINKED = ("ghostty-next",)
# What the job's own steps read and run (cmux-next.yml fast-tier-cargo), and this router.
JOB_INPUTS = (
    ".github/workflows/cmux-next.yml",
    ".github/actions/setup-cmux-tui-rust/",
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


def package_dir(root: Path, workspace: str, package: str) -> str | None:
    """The folder (relative to root, ending in /) of the workspace crate whose Cargo.toml names `package`."""
    pattern = re.compile(r'^\s*name\s*=\s*"' + re.escape(package) + r'"\s*$', re.M)
    for manifest in sorted((root / workspace).glob("crates/*/Cargo.toml")):
        try:
            text = manifest.read_text(encoding="utf-8")
        except OSError:
            continue
        # Only the [package] table's own name, not a dependency's.
        if "[package]" in text and pattern.search(text.split("[package]", 1)[1].split("\n[", 1)[0]):
            return manifest.parent.relative_to(root).as_posix() + "/"
    return None


def inputs(root: Path) -> list[str] | None:
    """The path prefixes that reach the job, or None when the registry cannot be read."""
    try:
        registry = json.loads((root / REGISTRY).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    prefixes = list(JOB_INPUTS) + list(SCRIPT_INPUTS) + list(LINKED)
    for entry in registry.get("entries", []):
        path = (entry.get("path") or "").rstrip("/")
        if entry.get("kind") == "cargo" and path:
            prefixes.extend(f"{path}/{name}" for name in WORKSPACE_ROOT_INPUTS)
            own = package_dir(root, path, entry["package"]) if entry.get("package") else None
            prefixes.append(own or path + "/")
        elif entry.get("kind") == "script" and path:
            prefixes.append(path.rsplit("/", 1)[0] + "/")
    return prefixes


def reaches(changed: list[str], labels: set[str], root: Path) -> tuple[bool, str]:
    if labels & FORCE_LABELS:
        return True, "full-ci label"
    prefixes = inputs(root)
    if prefixes is None:
        return True, f"could not read {REGISTRY}; running it"
    for path in changed:
        for prefix in prefixes:
            if _under(path, prefix):
                return True, f"{path} (under {prefix})"
    return False, "no changed path is in a cargo entry's own crate, the workspace root, a script entry or a job input"


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
