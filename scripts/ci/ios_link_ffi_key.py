#!/usr/bin/env python3
"""Cache key for CmuxMobileLinkFFI.xcframework: the git tree ids of every input its build reads.

cmux-next-ios/rust/scripts/build-xcframework.sh builds the cmux-mobile-link-ffi library for the iOS and simulator
slices, generates its Swift bindings, and typechecks them. What it reads, and so what the key names:

- every local package the library compiles: cmux-mobile-link-ffi and its path dependencies, which reach into
  cmux-tui/crates and cmux-tui/vendor, followed transitively through each Cargo.toml (normal, build and target
  dependencies, a `workspace = true` dependency by its name in the workspace's `[workspace.dependencies]`, and the
  workspace's `[patch]`); dev-dependencies are not built and stay out, and so do a workspace's other members;
- the building workspace's (cmux-next-ios/rust) Cargo.toml, Cargo.lock and .cargo/config.toml, and every other
  root's Cargo.toml (inherited fields), as files, not a root's whole tree;
- the pinned Rust toolchain (cmux-tui/rust-toolchain.toml), the build script itself, and the checked-in bindings
  (the workflow's drift check compares the generated ones with them, so a hit means that check passed too).

The selected Xcode is not in the tree; the workflow adds its version to the key. Every id comes from git objects at
REF (default HEAD), never the working tree, so a sparse checkout, the cargo cache's restored target/ or a build's
leftovers never change the key. A path the walk cannot read fails the key (exit 1): the workflow then builds.

  python3 scripts/ci/ios_link_ffi_key.py [--ref REF] [--list]
"""
from __future__ import annotations

import argparse
import hashlib
import posixpath
import subprocess
import sys

try:
    import tomllib  # 3.11+; the workflow's step falls back to a build when it is missing
except ModuleNotFoundError:
    tomllib = None

FFI = "cmux-next-ios/rust/crates/cmux-mobile-link-ffi"
FIXED = (
    "cmux-tui/rust-toolchain.toml",
    "cmux-next-ios/rust/scripts/build-xcframework.sh",
    "cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileLinkFFI/CmuxMobileLinkFFI.swift",
)
BUILT_TABLES = ("dependencies", "build-dependencies")


def git(ref: str, *args: str) -> str:
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout


def object_id(ref: str, path: str) -> str:
    return git(ref, "rev-parse", f"{ref}:{path}").strip()


def manifest(ref: str, directory: str) -> dict | None:
    try:
        text = git(ref, "show", f"{ref}:{directory}/Cargo.toml")
    except subprocess.CalledProcessError:
        return None
    return tomllib.loads(text)


def dep_tables(doc: dict) -> list[dict]:
    """The dependency tables a library build reads: normal, build, per-target, and [patch.*]."""
    tables = [doc.get(name) or {} for name in BUILT_TABLES]
    for target in (doc.get("target") or {}).values():
        tables += [(target or {}).get(name) or {} for name in BUILT_TABLES]
    tables += list((doc.get("patch") or {}).values())
    return tables


def workspace_root(ref: str, directory: str) -> str | None:
    """The nearest directory at or above DIRECTORY whose Cargo.toml has a [workspace] table."""
    here = directory
    while True:
        doc = manifest(ref, here)
        if doc is not None and "workspace" in doc:
            return here
        if here in ("", "."):
            return None
        here = posixpath.dirname(here)


def closure(ref: str) -> tuple[list[str], list[str]]:
    """(every local package directory the library build compiles, every workspace root those packages sit in),
    repo-relative and sorted. A workspace root contributes its manifest and Cargo.lock, not its other members."""
    packages: set[str] = set()
    roots: set[str] = set()
    todo = [FFI]
    while todo:
        directory = posixpath.normpath(todo.pop())
        if directory in packages:
            continue
        doc = manifest(ref, directory)
        if doc is None:
            raise SystemExit(f"ios_link_ffi_key: no Cargo.toml at {ref}:{directory}")
        packages.add(directory)
        root = workspace_root(ref, directory)
        root_doc = manifest(ref, root) if root is not None else None
        tables = dep_tables(doc)
        if root is not None and root not in roots:
            roots.add(root)
            for patch in (root_doc.get("patch") or {}).values():
                todo += [posixpath.join(root, spec["path"]) for spec in (patch or {}).values()
                         if isinstance(spec, dict) and isinstance(spec.get("path"), str)]
        inherited = ((root_doc or {}).get("workspace") or {}).get("dependencies") or {}
        for table in tables:
            for name, spec in table.items():
                if not isinstance(spec, dict):
                    continue
                if isinstance(spec.get("path"), str):
                    todo.append(posixpath.join(directory, spec["path"]))
                elif spec.get("workspace") is True:
                    base = inherited.get(name)
                    if isinstance(base, dict) and isinstance(base.get("path"), str):
                        todo.append(posixpath.join(root, base["path"]))
    return sorted(packages), sorted(roots)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--ref", default="HEAD")
    parser.add_argument("--list", action="store_true", help="print each input and its id, then the key")
    args = parser.parse_args()
    if tomllib is None:
        raise SystemExit("ios_link_ffi_key: needs Python 3.11+ (tomllib)")
    packages, roots = closure(args.ref)
    inputs = [(directory, object_id(args.ref, directory)) for directory in packages]
    building = workspace_root(args.ref, FFI)
    for root in roots:
        # Cargo reads only the building workspace's lock and config; another root lends its manifest's inherited
        # fields and [workspace.dependencies] alone.
        for name in ("Cargo.toml", "Cargo.lock", ".cargo/config.toml") if root == building else ("Cargo.toml",):
            path = posixpath.join(root, name)
            try:
                inputs.append((path, object_id(args.ref, path)))
            except subprocess.CalledProcessError:
                pass  # no lock or config in this workspace: nothing to read
    inputs += [(path, object_id(args.ref, path)) for path in FIXED]
    digest = hashlib.sha256("".join(f"{path} {oid}\n" for path, oid in inputs).encode()).hexdigest()[:32]
    if args.list:
        for path, oid in inputs:
            print(f"{oid} {path}")
    print(digest)
    return 0


if __name__ == "__main__":
    sys.exit(main())
