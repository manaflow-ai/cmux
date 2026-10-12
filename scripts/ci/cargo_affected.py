#!/usr/bin/env python3
"""Select the cmux-tui crates a change can affect, for cargo test, nextest and clippy gates.

The selection is every workspace crate that owns a changed file, plus every
workspace crate that depends on one of those (normal, dev and build
dependencies, transitively). It is printed as cargo package arguments
(`-p a -p b`), or `--workspace` when the change can reach every crate:

- Cargo.lock, any Cargo.toml in the workspace, rust-toolchain(.toml),
  .cargo/config(.toml), clippy.toml;
- a build script (build.rs, or a custom `build = ...` path that cargo metadata names);
- cmux-tui/spec/, cmux-tui/bindings/, a protocol crate (name ending in -protocol or -proto);
- a crate the workspace patches in ([patch] path, for example vendor/crossterm);
- a build input outside cmux-tui/ from scripts/cmux-next/cmux-tui-tree-inputs.txt
  (ghostty-next, the macOS cross scripts) that no crate reference below attributes;
- a .rs file that no workspace crate owns (a deleted or renamed crate, a stray source).

Files outside crate directories are mapped through the crates' own source: a
string literal of the form "../.." that resolves (from the source file or from
the crate directory) to an existing path outside the crate, as include_str!,
include_bytes! and CARGO_MANIFEST_DIR test fixtures use, selects that crate when
the path or anything under it changes. Other files (Swift, web, docs) select
nothing. Crates outside the workspace (their own [workspace], like
cmux-app-ffi) are reported on stderr when they change or depend on a selected
crate; run them with --manifest-path.

Changed paths come from `git diff --name-only BASE...HEAD` (--base), a file
(--files, `-` for stdin) or the arguments of --changed. Crates come from
`cargo metadata --no-deps` in the workspace, or from --metadata FILE (output
saved earlier, possibly on another host: paths are taken relative to its
workspace_root). With a command after `--`, the selection is inserted into it
(before its own `--`) and it runs with its exit status; an empty selection
skips it, because cargo without -p would test the default members.

  scripts/ci/cargo_affected.py --base origin/feat-cmux-next
  scripts/ci/cargo_affected.py --base origin/feat-cmux-next -- cargo test --locked
  scripts/ci/cargo_affected.py --changed $(git diff --name-only B...HEAD) -- cargo clippy --all-targets -- -D warnings

Run cargo only on a build host (rbx, Testbox, CI), never on the laptop.
Test: tests/test_ci_cargo_affected.py.
"""

from __future__ import annotations

import argparse
import collections
import dataclasses
import json
import os
import re
import subprocess
import sys
import tomllib
from pathlib import Path, PurePosixPath

WORKSPACE = "cmux-tui"
TREE_INPUTS = "scripts/cmux-next/cmux-tui-tree-inputs.txt"
ESCALATE_NAMES = {
    "Cargo.lock", "Cargo.toml", "build.rs", "rust-toolchain", "rust-toolchain.toml",
    "clippy.toml", ".clippy.toml",
}
ESCALATE_WORKSPACE_DIRS = ("spec", "bindings")
PROTOCOL_CRATE = re.compile(r"-(protocol|proto)$")
CARGO_CONFIG = re.compile(r"(^|/)\.cargo/config(\.toml)?$")
# "../x", "/../x" or "../../x/y": a relative reference that leaves the source file's directory.
RELATIVE_REF = re.compile(r'"(/?(?:\.\./)+[A-Za-z0-9_.][^"\s{}]*)"')


@dataclasses.dataclass
class Plan:
    changed: list[str]
    workspace: bool = False
    reasons: list[str] = dataclasses.field(default_factory=list)
    direct: list[str] = dataclasses.field(default_factory=list)
    crates: list[str] = dataclasses.field(default_factory=list)
    external: list[str] = dataclasses.field(default_factory=list)
    unmapped: list[str] = dataclasses.field(default_factory=list)
    members: int = 0

    def cargo_args(self) -> list[str]:
        if self.workspace:
            return ["--workspace"]
        return [arg for crate in self.crates for arg in ("-p", crate)]

    def as_json(self) -> dict:
        data = dataclasses.asdict(self)
        data["args"] = self.cargo_args()
        return data


def _rel(path: str, base: str) -> str:
    return PurePosixPath(os.path.relpath(path, base)).as_posix()


def _under(path: str, directory: str) -> bool:
    return directory in ("", ".") or path == directory or path.startswith(directory + "/")


@dataclasses.dataclass
class Crate:
    name: str
    dir: str            # repo-relative
    owned: list[str]    # repo-relative directories whose files belong to this crate
    build_scripts: set[str]
    path_deps: set[str]  # repo-relative directories of path dependencies (any kind)


def load_members(meta: dict, ws: str) -> list[Crate]:
    """Workspace members from cargo metadata, with paths relative to the repository."""
    host_root = meta["workspace_root"]
    member_ids = set(meta["workspace_members"])
    crates = []
    for pkg in meta["packages"]:
        if pkg["id"] not in member_ids:
            continue
        crate_dir = _rel(os.path.dirname(pkg["manifest_path"]), host_root)
        repo_dir = ws if crate_dir == "." else f"{ws}/{crate_dir}"
        builds = {f"{ws}/{_rel(t['src_path'], host_root)}" for t in pkg["targets"] if "custom-build" in t["kind"]}
        if crate_dir == ".":
            # The workspace root package owns only its targets' directories, not every
            # file under cmux-tui/ (docs, scripts, other crates).
            owned = sorted({f"{ws}/{_rel(os.path.dirname(t['src_path']), host_root)}" for t in pkg["targets"]})
        else:
            owned = [repo_dir]
        deps = set()
        for dep in pkg["dependencies"]:
            if dep.get("path"):
                dep_dir = _rel(dep["path"], host_root)
                deps.add(ws if dep_dir == "." else f"{ws}/{dep_dir}")
        crates.append(Crate(pkg["name"], repo_dir, owned, builds, deps))
    return crates


def external_crates(root: Path, ws: str, member_dirs: set[str]) -> dict[str, set[str]]:
    """Cargo packages under the workspace directory that are not members: dir -> path deps (repo-relative)."""
    out: dict[str, set[str]] = {}
    for manifest in sorted((root / ws).rglob("Cargo.toml")):
        rel_dir = manifest.parent.relative_to(root).as_posix()
        if rel_dir in member_dirs or {"target", "node_modules"} & set(rel_dir.split("/")):
            continue
        try:
            data = tomllib.loads(manifest.read_text(encoding="utf-8"))
        except (OSError, tomllib.TOMLDecodeError):
            data = {}
        deps = set()
        for table in ("dependencies", "dev-dependencies", "build-dependencies"):
            for spec in data.get(table, {}).values():
                if isinstance(spec, dict) and "path" in spec:
                    deps.add(os.path.normpath(os.path.join(rel_dir, spec["path"])))
        out[rel_dir] = deps
    return out


def patched_dirs(root: Path, ws: str) -> set[str]:
    """Directories the workspace manifest patches in with [patch.<registry>] path entries."""
    try:
        data = tomllib.loads((root / ws / "Cargo.toml").read_text(encoding="utf-8"))
    except (OSError, tomllib.TOMLDecodeError):
        return set()
    out = set()
    for registry in data.get("patch", {}).values():
        for spec in registry.values():
            if isinstance(spec, dict) and "path" in spec:
                out.add(os.path.normpath(os.path.join(ws, spec["path"])))
    return out


def crate_references(root: Path, crates: list[Crate]) -> dict[str, set[str]]:
    """Existing repo paths outside a crate that its sources name with a "../" literal: path -> crate names."""
    refs: dict[str, set[str]] = collections.defaultdict(set)
    top = os.path.abspath(root)
    for crate in crates:
        for owned in crate.owned:
            base = os.path.join(top, owned)
            for cur, dirs, files in os.walk(base):
                dirs[:] = [d for d in dirs if d not in ("target", "node_modules", ".git")]
                for name in files:
                    if not name.endswith(".rs"):
                        continue
                    with open(os.path.join(cur, name), encoding="utf-8", errors="replace") as handle:
                        text = handle.read()
                    if "../" not in text:
                        continue
                    for literal in RELATIVE_REF.findall(text):
                        rel = literal.lstrip("/")
                        for anchor in (cur, os.path.join(top, crate.dir)):
                            target = os.path.normpath(os.path.join(anchor, rel))
                            repo_rel = PurePosixPath(os.path.relpath(target, top)).as_posix()
                            if repo_rel.startswith("..") or _under(repo_rel, crate.dir) or not os.path.exists(target):
                                continue
                            refs[repo_rel].add(crate.name)
    return refs


def tree_inputs(root: Path, ws: str) -> list[str]:
    path = root / TREE_INPUTS
    if not path.is_file():
        return []
    out = []
    for raw in path.read_text(encoding="utf-8").splitlines():
        raw = raw.strip()
        if not raw or raw.startswith("#"):
            continue
        _kind, entry = raw.split(maxsplit=1)
        if entry != ws:
            out.append(entry)
    return out


def plan(root: Path, meta: dict, changed: list[str], ws: str = WORKSPACE) -> Plan:
    result = Plan(changed=sorted(set(changed)))
    crates = load_members(meta, ws)
    result.members = len(crates)
    by_dir = {c.dir: c for c in crates}
    owned = sorted(((d, c) for c in crates for d in c.owned), key=lambda item: -len(item[0]))
    externals = external_crates(root, ws, set(by_dir))
    patched = patched_dirs(root, ws)
    refs = crate_references(root, crates)
    inputs = tree_inputs(root, ws)
    build_scripts = {s for c in crates for s in c.build_scripts}

    def escalate(path: str, why: str) -> None:
        result.workspace = True
        result.reasons.append(f"{path}: {why}")

    direct: set[str] = set()
    direct_external: set[str] = set()
    for path in result.changed:
        name = PurePosixPath(path).name
        in_ws = _under(path, ws)
        if in_ws and name in ESCALATE_NAMES:
            escalate(path, f"{name} changes the build of every crate")
            continue
        if name in ("rust-toolchain", "rust-toolchain.toml") or CARGO_CONFIG.search(path):
            escalate(path, "toolchain or cargo configuration")
            continue
        if path in build_scripts:
            escalate(path, "build script")
            continue
        if in_ws and any(_under(path, f"{ws}/{d}") for d in ESCALATE_WORKSPACE_DIRS):
            escalate(path, "protocol spec or SDK bindings")
            continue
        referrers = {crate for ref, names in refs.items() if _under(path, ref) for crate in names}
        if in_ws:
            owner = next((c for d, c in owned if _under(path, d)), None)
            if owner is not None:
                if PROTOCOL_CRATE.search(owner.name):
                    escalate(path, f"protocol crate {owner.name}")
                    continue
                direct.add(owner.name)
                # Another crate that names this file (or a directory inside this crate) reads it
                # too, e.g. acpmux embedding cmux-browser-host/js/guide.md. A reference to an
                # ancestor of the owner (cmux-tui/, cmux-tui/crates/) is a tree walk or a
                # false positive; counting it would pull that crate into every change.
                for ref, names in refs.items():
                    if _under(path, ref) and _under(ref, owner.dir):
                        direct |= names
                continue
            ext = max((d for d in externals if _under(path, d)), key=len, default=None)
            if ext is not None:
                if ext in patched:
                    escalate(path, f"{ext} is patched into the workspace dependency graph")
                else:
                    direct_external.add(ext)
                continue
        if in_ws and path.endswith(".rs"):
            # Before references: a broad reference (cmux-tui/crates) must not turn a new or
            # renamed crate's source into a selection of the referring crate.
            escalate(path, "Rust source that no workspace crate owns")
            continue
        if referrers:
            direct |= referrers
            continue
        hit = next((entry for entry in inputs if _under(path, entry)), None)
        if hit is not None:
            escalate(path, f"cmux-tui build input ({TREE_INPUTS}: {hit}) that no crate source names")
            continue
        result.unmapped.append(path)

    if result.workspace:
        result.crates = sorted(c.name for c in crates)
        result.direct = sorted(direct)
        result.external = sorted(f"{d}/Cargo.toml" for d in externals if d not in patched)
        return result

    # Reverse dependencies over every path package (members and outside crates).
    dependents: dict[str, set[str]] = collections.defaultdict(set)
    for c in crates:
        for dep in c.path_deps:
            dependents[dep].add(c.dir)
    for ext_dir, deps in externals.items():
        for dep in deps:
            dependents[dep].add(ext_dir)
    name_dir = {c.name: c.dir for c in crates}
    seen = {name_dir[n] for n in direct} | direct_external
    pending = list(seen)
    while pending:
        for parent in dependents[pending.pop()]:
            if parent not in seen:
                seen.add(parent)
                pending.append(parent)
    result.direct = sorted(direct)
    result.crates = sorted(by_dir[d].name for d in seen if d in by_dir)
    result.external = sorted(f"{d}/Cargo.toml" for d in seen if d in externals and d not in patched)
    return result


def command_with_selection(cmd: list[str], args: list[str]) -> list[str]:
    """Insert package args before the command's own `--` (test binary arguments), else at the end."""
    if "--" in cmd:
        at = cmd.index("--")
        return [*cmd[:at], *args, *cmd[at:]]
    return [*cmd, *args]


def changed_from_git(root: Path, base: str, head: str) -> list[str]:
    out = subprocess.run(["git", "-C", str(root), "diff", "--name-only", "--no-renames", f"{base}...{head}"],
                         check=True, capture_output=True, text=True).stdout
    return [line for line in out.splitlines() if line]


def cargo_metadata(root: Path, ws: str) -> dict:
    return json.loads(subprocess.run(
        ["cargo", "metadata", "--no-deps", "--format-version", "1", "--manifest-path", str(root / ws / "Cargo.toml")],
        check=True, capture_output=True, text=True).stdout)


def summary(result: Plan) -> str:
    lines = []
    if result.workspace:
        lines.append(f"cargo_affected: full workspace ({result.members} crates):")
        lines += [f"  {reason}" for reason in result.reasons]
    elif result.crates:
        lines.append(f"cargo_affected: {len(result.crates)} of {result.members} crates "
                     f"(changed {', '.join(result.direct) or 'none'}; the rest depend on them)")
    else:
        lines.append(f"cargo_affected: no cmux-tui crate is affected by {len(result.changed)} changed paths")
    for manifest in result.external:
        lines.append(f"  outside the workspace, also run: cargo test --manifest-path {manifest}")
    return "\n".join(lines)


def main(argv: list[str]) -> int:
    cmd: list[str] = []
    if "--" in argv:
        at = argv.index("--")
        argv, cmd = argv[:at], argv[at + 1:]
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0],
                                     formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    parser.add_argument("--root", default=str(Path(__file__).resolve().parents[2]), help="repository root")
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--base", help="diff BASE...HEAD (merge-base diff)")
    source.add_argument("--files", help="file with repo-relative changed paths, one per line; - for stdin")
    source.add_argument("--changed", nargs="*", help="repo-relative changed paths")
    parser.add_argument("--head", default="HEAD")
    parser.add_argument("--metadata", help="saved `cargo metadata --no-deps --format-version 1` output")
    parser.add_argument("--format", choices=("args", "json", "lines"), default="args")
    args = parser.parse_args(argv)

    root = Path(args.root)
    if args.base:
        changed = changed_from_git(root, args.base, args.head)
    elif args.files:
        text = sys.stdin.read() if args.files == "-" else Path(args.files).read_text(encoding="utf-8")
        changed = [line.strip() for line in text.splitlines() if line.strip()]
    else:
        changed = list(args.changed or [])
    meta = json.loads(Path(args.metadata).read_text(encoding="utf-8")) if args.metadata else cargo_metadata(root, WORKSPACE)
    result = plan(root, meta, changed)
    print(summary(result), file=sys.stderr, flush=True)

    if cmd:
        selection = result.cargo_args()
        if not selection:
            print("cargo_affected: skipping: " + " ".join(cmd), file=sys.stderr)
            return 0
        full = command_with_selection(cmd, selection)
        print("cargo_affected: running: " + " ".join(full), file=sys.stderr, flush=True)
        return subprocess.call(full)
    if args.format == "json":
        print(json.dumps(result.as_json(), indent=2))
    elif args.format == "lines":
        print("\n".join(["--workspace"] if result.workspace else result.crates))
    else:
        print(" ".join(result.cargo_args()))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
