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
- or the pull request carries the full-ci label and the change can reach the entries' inputs (graph_inputs): a
  crate the entries' packages depend on (path dependencies, transitively), a file outside those crates that their
  sources name with a "../" literal (cargo_affected.py's rule, `// affected-reads:` included), cmux-tui/spec/ or
  bindings/, or a cmux-tui tree input no crate names (ghostty-next, the macOS cross scripts). A tooling-only change
  (scripts/ci/tooling_only.py) routes by the paths above under full-ci too. When the graph cannot be read, full-ci
  runs it. Leo, 2026-11-23: "de facto, im asking for 99% fewer minutes of ci time, period." Before, full-ci ran it
  for any change: 2026-11-26T11..11-27T11 it ran on full-ci heads of Swift- and web-only merged pull requests,
  about 2,100 of its 9,500 pull request runner-min/day (goal ci-min-per-pr-14, the affected-set replay in
  leo-workspace goals/ci-min-per-pr-breakdown.md).
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
import os
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import tooling_only  # noqa: E402

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
    "scripts/ci/tooling_only.py",
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


def _repo_paths(root: Path) -> set[str]:
    """Every file and folder of HEAD, from git's trees: the router's sparse checkout lacks most of the files the
    crates name (webviews/, Resources/), and a blob:none clone still has every tree. Empty without git."""
    try:
        out = subprocess.run(["git", "-C", str(root), "ls-tree", "-r", "-t", "--name-only", "HEAD"], check=True,
                             capture_output=True, text=True, timeout=60).stdout
    except (OSError, subprocess.SubprocessError):
        return set()
    return set(out.splitlines())


def graph_inputs(root: Path) -> list[str] | None:
    """The path prefixes the cargo entries' packages can read (full-ci's route), or None when the graph cannot be
    read: a registry, a manifest or an entry package that is missing, or a source that names the whole tree."""
    # Imported here: fast-tier.py and rebuild_mirror.py import this module on hosts whose Python lacks tomllib.
    try:
        import tomllib  # noqa: PLC0415
        from cargo_affected import AFFECTED_READS, RELATIVE_REF, TREE_INPUTS  # noqa: PLC0415
    except ImportError:
        return None
    try:
        registry = json.loads((root / REGISTRY).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    top = os.path.abspath(root)
    known = _repo_paths(root)

    def exists(rel: str) -> bool:
        return rel in known or os.path.exists(os.path.join(top, rel))

    prefixes: list[str] = []
    for workspace in sorted({(e.get("path") or "").rstrip("/") for e in registry.get("entries", [])
                             if e.get("kind") == "cargo" and e.get("path")}):
        try:
            members = {m.parent.relative_to(root).as_posix(): tomllib.loads(m.read_text(encoding="utf-8"))
                       for m in sorted((root / workspace).glob("crates/*/Cargo.toml"))
                       + sorted((root / workspace).glob("crates/*/*/Cargo.toml"))}
            shared = tomllib.loads((root / workspace / "Cargo.toml").read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return None
        shared = shared.get("workspace", {}).get("dependencies", {})
        by_name = {data.get("package", {}).get("name"): rel for rel, data in members.items()}

        def deps(rel: str) -> set[str]:
            data = members.get(rel, {})
            out = set()
            for table in [data, *data.get("target", {}).values()]:
                for kind in ("dependencies", "dev-dependencies", "build-dependencies"):
                    for name, spec in table.get(kind, {}).items():
                        if isinstance(spec, dict) and spec.get("workspace"):
                            spec, base = shared.get(name), workspace
                        else:
                            base = rel
                        if isinstance(spec, dict) and "path" in spec:
                            out.add(os.path.normpath(os.path.join(base, spec["path"])))
            return out

        todo = [by_name.get(e.get("package")) for e in registry["entries"]
                if e.get("kind") == "cargo" and (e.get("path") or "").rstrip("/") == workspace]
        if None in todo:
            return None
        closure: set[str] = set()
        while todo:
            crate = todo.pop()
            if crate not in closure:
                closure.add(crate)
                todo.extend(deps(crate))
        # What any member's sources name outside it ("../" literals): path -> the members that name it.
        named: dict[str, set[str]] = {}
        for rel in members:
            for folder, dirs, files in os.walk(root / rel):
                dirs[:] = [d for d in dirs if d not in ("target", "node_modules", ".git")]
                for file in files:
                    if not file.endswith(".rs"):
                        continue
                    text = Path(folder, file).read_text(encoding="utf-8", errors="replace")
                    if "../" not in text:
                        continue
                    for literal in RELATIVE_REF.findall(text):
                        for anchor in (os.path.join(top, os.path.relpath(folder, root)), os.path.join(top, rel)):
                            target = Path(os.path.relpath(os.path.normpath(os.path.join(anchor, literal.lstrip("/"))),
                                                          top)).as_posix()
                            if target.startswith("..") or target == rel or target.startswith(rel + "/"):
                                continue
                            if target == ".":
                                listed = " ".join(AFFECTED_READS.findall(text)).split()
                                if listed == ["none"]:
                                    continue
                                reads = listed if listed and all(exists(p) for p in listed) else ["."]
                            elif exists(target):
                                reads = [target]
                            else:
                                continue
                            for read in reads:
                                named.setdefault(read, set()).add(rel)
        for read, crates in named.items():
            if crates & closure:
                if read == ".":
                    return None
                prefixes.append(read)
        prefixes += [crate + "/" for crate in closure if crate != workspace]
        prefixes += [f"{workspace}/spec/", f"{workspace}/bindings/"]
        try:
            lines = (root / TREE_INPUTS).read_text(encoding="utf-8").splitlines()
        except OSError:
            return None
        for line in lines:
            parts = line.split()
            if len(parts) == 2 and not line.startswith("#") and parts[1] != workspace:
                entry = parts[1]
                if not any(read == entry or read.startswith(entry + "/") for read in named):
                    prefixes.append(entry)
    return prefixes


def _reached(path: str, prefix: str) -> bool:
    """A graph prefix is a file or a folder, with or without its trailing /."""
    prefix = prefix.rstrip("/")
    return path == prefix or path.startswith(prefix + "/")


def reaches(changed: list[str], labels: set[str], root: Path) -> tuple[bool, str]:
    prefixes = inputs(root)
    if labels & FORCE_LABELS and not tooling_only.tooling_only(changed):
        graph = graph_inputs(root) if changed and prefixes is not None else None
        if graph is None:
            return True, "full-ci label (the cargo graph could not be read)"
        for path in changed:
            for prefix in prefixes:
                if _under(path, prefix):
                    return True, f"full-ci label: {path} (under {prefix})"
            for prefix in graph:
                if _reached(path, prefix):
                    return True, f"full-ci label: {path} (the entries read {prefix})"
        return False, "full-ci label, but no changed path is in the cargo entries' crates, their dependencies or what they read"
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
