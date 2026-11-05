#!/usr/bin/env python3
"""Which build a change needs: only Rust (blaze) builds, or the app build too.

Leo, 2026-11-05: "Can't we deterministically say 'these types of changes only need a blaze
compile/build'". Every changed file gets one class, and the change takes the heavier:

  blaze  a file inside a cmux-tui crate that only Cargo builds read. The blaze (or cargo) builds
         of the Rust workspaces it reaches are the whole build, and the output names them: the
         crate's own workspace (cmux-tui, or its own when cmux-tui excludes it) and every
         workspace outside cmux-tui with a path dependency on it. No Xcode build, Swift compile or
         app build can change.
  app    anything else: a Swift compile, the app build or another language's build can read it.
         A file this script cannot place is `app`, so an unknown input never skips a build.

A crate is `app` when another language links it or the app build reads it:
  - every crate in the Cargo dependency closure of a staticlib, cdylib or *-ffi crate (in any
    workspace of the repo: CCmuxAppFFI, the iOS link FFI, cmux-rd-ffi, wasm), or of a crate a
    Package.swift names (a prebuilt xcframework such as cmux-terminal-client);
  - the router's lists (scripts/ci/cmux_next_route.py): the CCmuxAppFFI sources (app_ffi_inputs)
    and the files the app scheme's build phases name (scheme_phase_rust_inputs, read from
    cmux.xcodeproj; the cmux-tui Cargo.toml and Cargo.lock are among them).
A file in cmux-tui but in no crate, and every file outside cmux-tui, docs included (a crate can
include_str! a doc, a generator can read an image), is `app`.

The class is about compiles and builds only: a daemon change still runs the daemon tier's
live-daemon suites, which test what the new binary does.

Usage: build_class.py [--base REF] [--changed-files FILE] [--json]
Prints the class, then one line per file with its class and reason. Exit 0.
"""

from __future__ import annotations

import argparse
import functools
import json
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import cmux_next_route as route_mod  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
# "none" only for an empty change.
CLASSES = ("none", "blaze", "app")
FOREIGN_LINK = re.compile(r'crate-type\s*=\s*\[[^\]]*"(?:staticlib|cdylib)"')
SWIFT_NAMED_CRATE = re.compile(r"cmux-tui/((?:crates|bindings)/[A-Za-z0-9_-]+)")
WORKSPACE_PATH_DEP = re.compile(r'^\s*([A-Za-z0-9_-]+)\s*=\s*\{[^}\n]*\bpath\s*=\s*"([^"]+)"', re.M)


def tracked(root: Path, pattern: str) -> list[str]:
    out = subprocess.run(["git", "-C", str(root), "ls-files", pattern], check=True, capture_output=True, text=True).stdout
    return [p for p in out.splitlines() if (root / p).is_file()]


def workspace_root(root: Path, crate: str) -> str:
    """The nearest directory at or above crate whose Cargo.toml has a [workspace] that takes it in
    (cmux-tui excludes some crates: they are their own workspace)."""
    parent = Path(crate)
    while parent.as_posix() not in ("", "."):
        manifest = root / parent / "Cargo.toml"
        if manifest.is_file() and "[workspace]" in manifest.read_text(encoding="utf-8"):
            relative = Path(crate).relative_to(parent).as_posix()
            if parent.as_posix() == crate or not excluded(manifest.read_text(encoding="utf-8"), relative):
                return parent.as_posix()
        parent = parent.parent
    return crate


def excluded(manifest: str, member: str) -> bool:
    found = re.search(r"^\s*exclude\s*=\s*\[([^\]]*)\]", manifest, re.M)
    return bool(found) and member in re.findall(r'"([^"]+)"', found.group(1))


@functools.lru_cache(maxsize=None)
def cargo_graph(root: Path) -> tuple[dict[str, set[str]], set[str]]:
    """Every tracked crate's path dependencies (its own and its workspace's), and the crates another
    language links: staticlib, cdylib or *-ffi crates, and the cmux-tui crates a Package.swift names."""
    crates = {Path(p).parent.as_posix() for p in tracked(root, "*Cargo.toml")}
    deps: dict[str, set[str]] = {}
    foreign: set[str] = set()
    for crate in crates:
        text = (root / crate / "Cargo.toml").read_text(encoding="utf-8")
        found = [(Path(crate) / d).as_posix() for d in route_mod.CARGO_PATH.findall(text)]
        names = set(route_mod.CARGO_WORKSPACE_DEP.findall(text))
        workspace = workspace_root(root, crate)
        if names and workspace != crate:
            shared = (root / workspace / "Cargo.toml").read_text(encoding="utf-8")
            found += [(Path(workspace) / d).as_posix() for n, d in WORKSPACE_PATH_DEP.findall(shared) if n in names]
        deps[crate] = set()
        for dep in found:
            resolved = (root / dep).resolve()
            if resolved.is_relative_to(root.resolve()) and (resolved / "Cargo.toml").is_file():
                deps[crate].add(resolved.relative_to(root.resolve()).as_posix())
        if FOREIGN_LINK.search(text) or crate.endswith("-ffi"):
            foreign.add(crate)
    for package in tracked(root, "*Package.swift"):
        text = (root / package).read_text(encoding="utf-8")
        foreign |= {"cmux-tui/" + c for c in SWIFT_NAMED_CRATE.findall(text) if "cmux-tui/" + c in crates}
    return deps, foreign


def closure(deps: dict[str, set[str]], start: set[str]) -> set[str]:
    seen: set[str] = set()
    pending = list(start)
    while pending:
        crate = pending.pop()
        if crate not in seen:
            seen.add(crate)
            pending += deps.get(crate, ())
    return seen


@functools.lru_cache(maxsize=None)
def foreign_closure(root: Path) -> dict[str, str]:
    """Each crate another language's build reads, with the linked crate that reaches it."""
    deps, foreign = cargo_graph(root)
    reached: dict[str, str] = {}
    for crate in sorted(foreign):
        for dep in closure(deps, {crate}):
            reached.setdefault(dep, crate)
    return reached


def rust_workspaces(root: Path, crate: str) -> list[str]:
    """The Cargo workspaces whose builds compile crate: its own, and every one with a crate that reaches it."""
    deps, _ = cargo_graph(root)
    users = {c for c in deps if crate in closure(deps, {c})}
    return sorted({workspace_root(root, c) for c in users})


def crate_dir(root: Path, path: str) -> str | None:
    """The cmux-tui crate (a directory below cmux-tui/ with a Cargo.toml) that holds path."""
    parent = Path(path).parent
    while parent.as_posix().startswith(route_mod.CMUX_TUI):
        if (root / parent / "Cargo.toml").is_file():
            return parent.as_posix()
        parent = parent.parent
    return None


def classify_path(root: Path, path: str) -> tuple[str, str]:
    if not path.startswith(route_mod.CMUX_TUI):
        return "app", "outside cmux-tui: the app build's rules (cmux_next_route.py) place it"
    if any(route_mod.matches(path, prefix) for prefix in route_mod.app_ffi_inputs(root)):
        return "app", "a CCmuxAppFFI source: the Swift compiles link it"
    if any(route_mod.matches(path, prefix) for prefix in route_mod.scheme_phase_rust_inputs(root)):
        return "app", "an input of the app scheme's build phases (cmux.xcodeproj)"
    crate = crate_dir(root, path)
    if crate is None:
        return "app", "in cmux-tui but in no crate: no rule proves the app build skips it"
    linked = foreign_closure(root).get(crate)
    if linked:
        return "app", f"crate {crate} is in the dependency closure of {linked}, which another language links"
    return "blaze", f"crate {crate}: only Cargo builds read it (blaze build {', '.join(rust_workspaces(root, crate))})"


def classify(root: Path, changed: list[str]) -> dict:
    files = [{"path": p, "class": c, "reason": r} for p in changed for c, r in [classify_path(root, p)]]
    cls = max((f["class"] for f in files), key=CLASSES.index, default="none")
    return {"class": cls, "files": files}


def changed_files(base: str) -> list[str]:
    merge_base = subprocess.run(["git", "-C", str(ROOT), "merge-base", base, "HEAD"],
                                check=True, capture_output=True, text=True).stdout.strip()
    diff = subprocess.run(["git", "-C", str(ROOT), "diff", "--name-only", "--no-renames", merge_base],
                          check=True, capture_output=True, text=True).stdout
    return [p for p in diff.splitlines() if p]


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--base", default="origin/feat-cmux-next",
                        help="compare the working tree with its merge base with this ref (default: %(default)s)")
    parser.add_argument("--changed-files", help="a file of changed paths, one per line, instead of --base")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    if args.changed_files:
        changed = [p.strip() for p in Path(args.changed_files).read_text(encoding="utf-8").splitlines() if p.strip()]
    else:
        changed = changed_files(args.base)
    result = classify(ROOT, changed)
    if args.json:
        print(json.dumps(result, indent=2))
        return 0
    print(result["class"])
    for item in result["files"]:
        print(f"  {item['class']:<10} {item['path']}: {item['reason']}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
