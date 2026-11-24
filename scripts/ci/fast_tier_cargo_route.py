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

When it runs on a pull request it runs only the entries the change reaches (`fast_tier_cargo_only`, a JSON list of
entry names; empty means every entry), and `fast_tier_cargo_build=false` when that leaves no cargo entry, so the job
builds no Rust. A cargo entry is reached by its own crate folder and the folder of every other entry package it
depends on (the reducer's change reaches the core entry: its dependents, within the registry), the workspace root
inputs, and for the core the ghostty-next gitlink; a script entry by its folder and SCRIPT_INPUTS. With --base-rev:
a Cargo.lock change reaches a cargo entry only when a package it changes is in the entry's lock closure, and a
cmux-next.yml change reaches the job only when the fast-tier-cargo job or the file's top (before `jobs:`) changed.
The 17 of 204 pull request heads of 2026-11-24T09:54..11:24Z it ran on: 7 changed only scripts/cmux-next/tests/ and
built 12 min of Rust for a Python test, 3 added a dependency to a crate neither entry builds, 2 touched another
job of cmux-next.yml. Every feat-cmux-next push still runs every entry (the batched tier).

    fast_tier_cargo_route.py --changed-files FILE [--labels a,b] [--root .] [--base-rev REV] [--github-output FILE]

Test: tests/test_cmux_next_checks_workflow.py FastTierCargoRoute.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
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
    "scripts/ci/pool-warm-target.sh",
    "scripts/ci/tests/pool-warm-target.test.sh",
    "scripts/blacksmith-testbox-source-mtimes.py",
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
    entries = registry_entries(root)
    if entries is None:
        return None
    prefixes = list(JOB_INPUTS) + list(SCRIPT_INPUTS) + list(LINKED)
    for entry in entries:
        prefixes.extend(entry_inputs(root, entry, entries))
    return prefixes


def registry_entries(root: Path) -> list[dict] | None:
    """The cargo and script entries of the registry, or None when it cannot be read."""
    try:
        registry = json.loads((root / REGISTRY).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return [e for e in registry.get("entries", []) if e.get("kind") in ("cargo", "script") and e.get("path")]


def own_dir(root: Path, entry: dict) -> str:
    path = entry["path"].rstrip("/")
    return (package_dir(root, path, entry["package"]) if entry.get("package") else None) or path + "/"


def entry_inputs(root: Path, entry: dict, entries: list[dict]) -> list[str]:
    """The path prefixes that reach one entry (JOB_INPUTS reach every entry and are not listed)."""
    path = entry["path"].rstrip("/")
    if entry["kind"] == "script":
        return [path.rsplit("/", 1)[0] + "/", *SCRIPT_INPUTS]
    prefixes = [f"{path}/{name}" for name in WORKSPACE_ROOT_INPUTS] + [own_dir(root, entry)]
    # The other entry packages this one builds on: a change to the reducer reaches the core's entry too.
    closure = lock_closure(lock_packages(read(root / path / "Cargo.lock")), entry["package"])
    prefixes += [own_dir(root, other) for other in entries
                 if other is not entry and other["kind"] == "cargo" and other["path"].rstrip("/") == path
                 and other.get("package") in closure]
    if entry.get("package") == "cmux-tui-core":
        prefixes += list(LINKED)
    return prefixes


def read(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except OSError:
        return ""


def git_show(root: Path, rev: str, path: str) -> str | None:
    try:
        out = subprocess.run(["git", "-C", str(root), "show", f"{rev}:{path}"], capture_output=True, text=True,
                             timeout=60)
    except (OSError, subprocess.SubprocessError):
        return None
    return out.stdout if out.returncode == 0 else None


def lock_packages(text: str) -> dict[tuple[str, str, str], str]:
    """Cargo.lock's [[package]] blocks by (name, version, source)."""
    blocks = {}
    for block in text.split("[[package]]")[1:]:
        fields = dict(re.findall(r'^(name|version|source) = "([^"]*)"', block, re.M))
        blocks[(fields.get("name", ""), fields.get("version", ""), fields.get("source", ""))] = block.strip()
    return blocks


def lock_closure(blocks: dict[tuple[str, str, str], str], root_name: str) -> set[str]:
    """Every package name reachable from ROOT_NAME along the lock's dependency lists (all targets and features)."""
    deps = {}
    for (name, _, _), block in blocks.items():
        listed = re.search(r"^dependencies = \[(.*?)^\]", block, re.M | re.S)
        deps.setdefault(name, set()).update(
            item.split()[0] for item in re.findall(r'"([^"]+)"', listed.group(1) if listed else ""))
    seen, todo = set(), [root_name]
    while todo:
        name = todo.pop()
        if name not in seen:
            seen.add(name)
            todo.extend(deps.get(name, ()))
    return seen


def lock_reaches(root: Path, base_rev: str, lock: str, package: str) -> bool:
    """Whether the Cargo.lock change between BASE_REV and the worktree touches PACKAGE's closure."""
    base_text = git_show(root, base_rev, lock)
    if base_text is None:
        return True
    base, head = lock_packages(base_text), lock_packages(read(root / lock))
    changed = {key[0] for key in set(base) ^ set(head)} | {key[0] for key in set(base) & set(head)
                                                           if base[key] != head[key]}
    return bool(changed & (lock_closure(base, package) | lock_closure(head, package)))


JOB_KEY = "fast-tier-cargo"


def workflow_part(text: str) -> str:
    """cmux-next.yml's top (everything before `jobs:`) and the fast-tier-cargo job's block."""
    top, _, jobs = text.partition("\njobs:\n")
    match = re.search(rf"^  {re.escape(JOB_KEY)}:\n(?:(?:    .*|\s*)\n)*", jobs, re.M)
    return top + "\n" + (match.group(0) if match else jobs)


def workflow_reaches(root: Path, base_rev: str, workflow: str) -> bool:
    base_text = git_show(root, base_rev, workflow)
    return base_text is None or workflow_part(base_text) != workflow_part(read(root / workflow))


def path_reaches(root: Path, path: str, prefix: str, base_rev: str | None, entry: dict | None) -> bool:
    if not _under(path, prefix):
        return False
    if base_rev and path == ".github/workflows/cmux-next.yml":
        return workflow_reaches(root, base_rev, path)
    if base_rev and entry and entry["kind"] == "cargo" and path == f"{entry['path'].rstrip('/')}/Cargo.lock":
        return lock_reaches(root, base_rev, path, entry["package"])
    return True


def select(changed: list[str], labels: set[str], root: Path,
           base_rev: str | None = None) -> tuple[bool, list[str], str]:
    """(reached, the entry names to run or [] for every entry, why)."""
    if labels & FORCE_LABELS:
        return True, [], "full-ci label"
    entries = registry_entries(root)
    if entries is None:
        return True, [], f"could not read {REGISTRY}; running it"
    for path in changed:
        for prefix in JOB_INPUTS:
            if path_reaches(root, path, prefix, base_rev, None):
                return True, [], f"{path} (under {prefix}): every entry"
    chosen, why = [], []
    for entry in entries:
        hit = next((f"{path} (under {prefix})" for path in changed for prefix in entry_inputs(root, entry, entries)
                    if path_reaches(root, path, prefix, base_rev, entry)), None)
        if hit:
            chosen.append(entry["name"])
            why.append(f"{entry['name']}: {hit}")
    if len(chosen) == len(entries):
        return True, [], "; ".join(why) + ": every entry"
    if not chosen:
        return False, [], ("no changed path is in a cargo entry's own crate, the workspace root, a script entry or "
                           "a job input")
    return True, chosen, "; ".join(why)


def reaches(changed: list[str], labels: set[str], root: Path, base_rev: str | None = None) -> tuple[bool, str]:
    reached, _, why = select(changed, labels, root, base_rev)
    return reached, why


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--changed-files", required=True)
    parser.add_argument("--labels", default="")
    parser.add_argument("--root", default=".")
    parser.add_argument("--base-rev", help="the pull request's base commit (HEAD^1 of its merge commit)")
    parser.add_argument("--github-output")
    args = parser.parse_args(argv)
    root = Path(args.root)
    chosen = []
    try:
        changed = [line.strip() for line in Path(args.changed_files).read_text(encoding="utf-8").splitlines()
                   if line.strip()]
    except OSError as error:
        changed, reached, why = [], True, f"could not read the changed files ({error}); running it"
    else:
        reached, chosen, why = select(changed, {label for label in args.labels.split(",") if label}, root,
                                      args.base_rev)
    entries = registry_entries(root) or []
    kinds = {e["name"]: e["kind"] for e in entries}
    build = not chosen or any(kinds.get(name, "cargo") == "cargo" for name in chosen)
    lines = [f"fast_tier_cargo={'true' if reached else 'false'}",
             f"fast_tier_cargo_only={json.dumps(chosen) if chosen else ''}",
             f"fast_tier_cargo_build={'true' if reached and build else 'false'}"]
    print(f"{lines[0]}: {why}")
    print("  " + ", ".join(lines[1:]))
    if args.github_output:
        with open(args.github_output, "a", encoding="utf-8") as out:
            out.write("\n".join(lines) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
