#!/usr/bin/env python3
"""Test results per workspace crate, for ci/steps.toml's `cmux-next-daemon-tests` step.

That step's own key (scripts/ci/ci_steps.py, "Step results by input hash") covers every file under cmux-tui/**, so any
change in the workspace, a pull request's next head or a base move all change it: in its first day the store answered 1
hit in 510 lookups (2026-11-25). Inside the step the work is per crate. `cargo test -p A -p B ... cmux_next_`. So each
crate the step tests gets a key of its own, the sha256 over:

  - the crate's name and the test targets the step runs for it (scripts/ci/cmux-next-daemon-test-packages.sh);
  - every tracked file (path, mode, blob id) of the crate and of each package it reaches through a path dependency
    (normal, dev, build, target-specific; `workspace = true` through [workspace.dependencies]), transitively, a file
    belonging to the deepest package folder that holds it;
  - every tracked file under a path a source of those packages names with `../` (include_str!, a test's fixture
    folder): a literal that leaves the crate pulls in what it points at, the whole folder for a folder;
  - SHARED (the workspace manifest, Cargo.lock, the toolchain pin, cargo's config, [patch] folders, the ghostty-next
    gitlink, the Zig pin, the step's scripts and this file), the step's table entry and the machine kind.

`plan` asks the controller's step-result store (the same StepResults, step name `crate.<name>`) for each key and prints
the cargo arguments for the crates that missed, REUSED_ALL when every crate hit (the step then skips its toolchain, its
target restore and cargo). `post` stores a pass for each crate that ran, once the whole run passed. A failed run posts
nothing: one cargo run is one result. AUDIT_PERCENT of hits run anyway, as for steps. A plan it cannot make (a
`--workspace` fallback, an unreadable manifest, no store) prints the arguments it was given: every crate runs.
Off: CI_STEP_RESULTS=off, as for steps.

  crate_results.py plan STATE -- ARGS...   ARGS: the packages script's output; STATE: a file `post` reads
  crate_results.py post STATE
  crate_results.py replay [--commits N]    the hit share crate keys would have had over the last N first-parent
                                           commits of HEAD that touched the step's inputs, against the step's key
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import posixpath
import re
import subprocess
import sys
import time
import tomllib
from pathlib import Path
from typing import Callable

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ci_steps  # noqa: E402

ROOT = ci_steps.ROOT
STEP = "cmux-next-daemon-tests"
WORKSPACE = "cmux-tui"
CRATE_KEY_VERSION = 1
REUSED_ALL = "REUSED_ALL"  # plan's answer when every crate hit: an empty answer means it failed, and all run
SHARED = (
    "cmux-tui/Cargo.toml", "cmux-tui/Cargo.lock", "cmux-tui/rust-toolchain.toml", "cmux-tui/.cargo/config.toml",
    ".cargo/config.toml", "ghostty-next", "scripts/ci/zig-tarballs.sha256",
    "scripts/ci/cmux-next-daemon-test-packages.sh", "scripts/cmux-next/cargo-locks.py", "scripts/ci/crate_results.py",
)
DEP_SECTIONS = ("dependencies", "dev-dependencies", "build-dependencies")
LITERAL = re.compile(rb'"([^"\\\n]{1,240})"')
CLIMB = re.compile(r"\.\.(?:/\.\.)*/?")

Files = dict[str, tuple[str, str]]  # path -> (mode, object id)
Reader = Callable[[str], bytes | None]


def norm(path: str) -> str | None:
    """A repository-relative path, or None for one outside the repository."""
    p = posixpath.normpath(path)
    if p == ".":
        return ""
    return None if p.startswith("../") or p == ".." else p


def manifest(read: Reader, folder: str) -> dict | None:
    raw = read(f"{folder}/Cargo.toml" if folder else "Cargo.toml")
    if raw is None:
        return None
    try:
        return tomllib.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, tomllib.TOMLDecodeError):
        return None


def path_deps(folder: str, doc: dict, workspace_paths: dict[str, str]) -> set[str]:
    """The folders of a package's path dependencies, every kind and every target."""
    tables = [doc.get(s, {}) for s in DEP_SECTIONS]
    for spec in (doc.get("target") or {}).values():
        if isinstance(spec, dict):
            tables += [spec.get(s, {}) for s in DEP_SECTIONS]
    found = set()
    for table in tables:
        if not isinstance(table, dict):
            continue
        for name, spec in table.items():
            if not isinstance(spec, dict):
                continue
            if isinstance(spec.get("path"), str):
                p = norm(posixpath.join(folder, spec["path"]))
            elif spec.get("workspace") is True:
                p = workspace_paths.get(name)
            else:
                continue
            if p is not None:
                found.add(p)
    return found


class Workspace:
    """The cmux-tui workspace's packages, their path-dependency graph and the files each one owns."""

    def __init__(self, files: Files, read: Reader) -> None:
        self.files = files
        self.read = read
        root = manifest(read, WORKSPACE)
        if root is None or "workspace" not in root:
            raise ValueError(f"{WORKSPACE}/Cargo.toml has no [workspace]")
        ws = root["workspace"]
        self.workspace_paths = {
            name: p for name, spec in (ws.get("dependencies") or {}).items()
            if isinstance(spec, dict) and isinstance(spec.get("path"), str)
            and (p := norm(posixpath.join(WORKSPACE, spec["path"]))) is not None
        }
        self.patches = sorted(
            p for table in (root.get("patch") or {}).values() if isinstance(table, dict)
            for spec in table.values() if isinstance(spec, dict) and isinstance(spec.get("path"), str)
            and (p := norm(posixpath.join(WORKSPACE, spec["path"]))) is not None
        )
        self.docs: dict[str, dict] = {}  # package folder -> its manifest
        self.names: dict[str, str] = {}  # package name -> folder
        self.deps: dict[str, set[str]] = {}
        todo = [p for m in ws.get("members", []) if (p := norm(posixpath.join(WORKSPACE, m))) is not None]
        if "package" in root:
            todo.append(WORKSPACE)
        todo += self.patches
        while todo:
            folder = todo.pop()
            if folder in self.docs:
                continue
            doc = manifest(read, folder)
            if doc is None or "package" not in doc:
                continue
            self.docs[folder] = doc
            name = doc["package"].get("name")
            if isinstance(name, str):
                self.names.setdefault(name, folder)
            self.deps[folder] = path_deps(folder, doc, self.workspace_paths)
            todo += sorted(self.deps[folder])
        # Each tracked file belongs to the deepest package folder that holds it.
        self.owned: dict[str, list[str]] = {f: [] for f in self.docs}
        for path in files:
            parts = path.split("/")
            for i in range(len(parts) - 1, -1, -1):
                folder = "/".join(parts[:i])
                if folder in self.owned:
                    self.owned[folder].append(path)
                    break
        self.under: dict[str, list[str]] = {}  # folder -> every tracked path below it
        for path in files:
            for i in range(1, path.count("/") + 1):
                self.under.setdefault(path.rsplit("/", i)[0], []).append(path)
        self.dirs = self.under.keys()
        self._escapes: dict[str, list[str]] = {}

    def closure(self, folder: str) -> list[str]:
        seen, todo = set(), [folder]
        while todo:
            f = todo.pop()
            if f in seen or f not in self.docs:
                continue
            seen.add(f)
            todo += self.deps[f]
        return sorted(seen)

    def exists(self, path: str) -> bool:
        return path in self.files or path in self.dirs

    def escapes(self, path: str, folder: str) -> list[str]:
        """The tracked paths outside its package's folder that a source names with a literal that climbs out.

        A literal like "../../spec/x.json" resolves against the source's own folder (include_str!) and the package's
        (a path joined to CARGO_MANIFEST_DIR); a bare climb ("../..") is joined with each other literal of the
        file (`.join("../..").join("Resources/x")`). Only a resolved path the tree has counts ("../" in path handling
        code names nothing), and never a folder that holds the package: that is a climb, not a file it reads."""
        oid = self.files[path][1]
        key = f"{oid}:{path}:{folder}"
        if key not in self._escapes:
            out = set()
            lits = [m.group(1).decode("utf-8", "replace") for m in LITERAL.finditer(self.read(path) or b"")]
            lits = [lit[1:] if lit.startswith("/..") else lit for lit in lits]
            words = [lit for lit in lits if lit and not lit.startswith(("/", "..")) and " " not in lit]
            for base in (posixpath.dirname(path), folder):
                for lit in lits:
                    if not lit.startswith(".."):
                        continue
                    climb = CLIMB.fullmatch(lit) is not None
                    for tail in (words if climb else [""]):
                        p = norm(posixpath.join(base, lit, tail) if tail else posixpath.join(base, lit))
                        # Its own folder or one around it ("..".join("crates")) names no file of another package.
                        if p and self.exists(p) and not (p == folder or p.startswith(folder + "/")
                                                         or folder.startswith(p + "/")):
                            out.add(p)
            self._escapes[key] = sorted(out)
        return self._escapes[key]

    def inputs(self, folder: str) -> list[str]:
        """Every tracked path the crate's tests read, as far as the tree shows: see the module's list."""
        paths: set[str] = set()
        prefixes: set[str] = set(self.patches)
        for f in self.closure(folder):
            for path in self.owned[f]:
                paths.add(path)
                if path.endswith(".rs"):
                    prefixes.update(self.escapes(path, f))
        if "" in prefixes:
            return sorted(self.files)
        for prefix in prefixes:
            if prefix in self.files:
                paths.add(prefix)
            paths.update(self.under.get(prefix, ()))
        paths.update(p for p in SHARED if p in self.files)
        return sorted(paths)

    def has_lib(self, folder: str) -> bool:
        return "lib" in self.docs[folder] or f"{folder}/src/lib.rs" in self.files

    def test_owner(self, test: str, folders: list[str]) -> list[str]:
        return [f for f in folders if f"{f}/tests/{test}.rs" in self.files or f"{f}/tests/{test}/main.rs" in self.files]


def parse_args(args: list[str]) -> tuple[list[str], list[str], list[str]] | None:
    """(packages, flags, tests) of the packages script's output, or None for a form it cannot split."""
    packages, flags, tests = [], [], []
    i = 0
    while i < len(args):
        a = args[i]
        if a in ("-p", "--test") and i + 1 < len(args):
            (packages if a == "-p" else tests).append(args[i + 1])
            i += 2
            continue
        if a in ("--lib", "--bins"):
            flags.append(a)
            i += 1
            continue
        return None
    return (packages, flags, tests) if packages else None


def step_doc(env: dict[str, str]) -> dict:
    step = ci_steps.load().steps.get(STEP)
    fields = {} if step is None else {f: getattr(step, f) for f in ci_steps.Step.__dataclass_fields__
                                      if f not in ("title", "about")}
    return {"step": fields, "machine": {v: env.get(v, "") for v in ci_steps.MACHINE_VARS}}


def crate_key(ws: Workspace, folder: str, name: str, flags: list[str], tests: list[str], context: dict) -> str:
    doc = {
        "v": CRATE_KEY_VERSION,
        "crate": name,
        "targets": {"flags": sorted(flags), "tests": sorted(tests)},
        "context": context,
        "files": [[p, *ws.files[p]] for p in ws.inputs(folder)],
    }
    raw = json.dumps(doc, sort_keys=True, separators=(",", ":"), default=list)
    return hashlib.sha256(raw.encode("utf-8", "surrogateescape")).hexdigest()


def crates(ws: Workspace, args: list[str]) -> list[tuple[str, str, list[str], list[str]]] | None:
    """(name, folder, flags, tests) of each crate the arguments test, or None when they cannot be split."""
    parsed = parse_args(args)
    if parsed is None:
        return None
    packages, flags, tests = parsed
    folders = []
    for name in packages:
        if name not in ws.names:
            return None
        folders.append(ws.names[name])
    owners = {t: ws.test_owner(t, folders) for t in tests}
    if any(not o for o in owners.values()):
        return None  # a test target with no owner it can name: every crate runs
    out = []
    for name, folder in zip(packages, folders):
        own_flags = [f for f in flags if f != "--lib" or ws.has_lib(folder)]
        out.append((name, folder, own_flags, sorted(t for t, o in owners.items() if folder in o)))
    return out


def miss_args(planned: list[tuple[str, str, list[str], list[str]]], args_flags: list[str]) -> list[str]:
    out = []
    for name, *_ in planned:
        out += ["-p", name]
    flags = sorted({f for _n, _f, fl, _t in planned for f in fl if f in args_flags})
    tests = sorted({t for *_x, ts in planned for t in ts})
    return out + flags + [w for t in tests for w in ("--test", t)]


def tree_files(root: Path) -> Files | None:
    listed = ci_steps.tracked_files(root)
    return None if listed is None else {p: (mode, oid) for p, mode, oid in listed}


def disk_reader(root: Path) -> Reader:
    def read(path: str) -> bytes | None:
        try:
            return (root / path).read_bytes()
        except OSError:
            return None
    return read


def plan(state: Path, args: list[str], env: dict[str, str], root: Path = ROOT, store=None, out=sys.stdout) -> list[str]:
    """The cargo arguments for the crates whose keys missed; writes the keys `post` stores."""
    state.write_text("{}", encoding="utf-8")
    store = store if store is not None else ci_steps.StepResults.from_env(env)
    if store is None:
        print("crate results: no store here (CI_STEP_RESULTS off, or not a fleet Actions run); every crate runs", file=out)
        return args
    files = tree_files(root)
    try:
        ws = Workspace(files or {}, disk_reader(root))
        planned = crates(ws, args) if files else None
    except ValueError as err:
        print(f"crate results: {err}; every crate runs", file=out)
        return args
    if planned is None:
        print(f"crate results: cannot split {' '.join(args) or 'no arguments'} by crate; every crate runs", file=out)
        return args
    context = step_doc(env)
    keys = {name: crate_key(ws, folder, name, fl, ts, context) for name, folder, fl, ts in planned}
    runs, audits = [], []
    for entry in planned:
        name = entry[0]
        audit = ci_steps.audited(keys[name], env)
        hit = store.lookup(keys[name], f"crate.{name}", audit)
        if hit and not audit:
            print(f"crate results: {name} reused: its inputs (key {keys[name][:16]}) passed in "
                  f"{hit.get('run_url', '?')}; its tests do not run again", file=out)
            continue
        if hit:
            audits.append(name)
            print(f"crate results: {name} passed under its key before; audited, so it runs anyway", file=out)
        runs.append(entry)
    if store.error:
        print(f"crate results: the store: {store.error}", file=out)
    state.write_text(json.dumps({"started": time.time(), "audits": audits,
                                 "keys": {e[0]: keys[e[0]] for e in runs}}), encoding="utf-8")
    print(f"crate results: {len(planned) - len(runs)} of {len(planned)} crates reused, {len(runs)} run", file=out)
    return miss_args(runs, parse_args(args)[1]) if runs else []


def post(state: Path, env: dict[str, str], store=None, out=sys.stdout) -> int:
    try:
        doc = json.loads(state.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return 0
    keys = doc.get("keys") or {}
    store = store if store is not None else ci_steps.StepResults.from_env(env)
    if not keys or store is None:
        return 0
    each = max(0.0, time.time() - float(doc.get("started") or time.time())) / len(keys)
    for name, key in keys.items():
        store.post(key, f"crate.{name}", "pass", each, audit=name in (doc.get("audits") or []))
    print(f"crate results: stored a pass for {len(keys)} crate(s)"
          + (f"; the store: {store.error}" if store.error else ""), file=out)
    return 0


# Replay: the hit share crate keys would have had, from git alone.

class GitTree:
    """A commit's tracked files and their contents, read through one `git cat-file --batch`."""

    def __init__(self, root: Path) -> None:
        self.root = root
        self.cat = subprocess.Popen(["git", "cat-file", "--batch"], cwd=root, stdin=subprocess.PIPE,
                                    stdout=subprocess.PIPE)
        self.blobs: dict[str, bytes | None] = {}

    def files(self, commit: str) -> Files:
        raw = subprocess.run(["git", "ls-tree", "-r", "-z", "--full-tree", commit], cwd=self.root,
                             capture_output=True, check=True).stdout.decode("utf-8", "surrogateescape")
        out = {}
        for entry in raw.split("\0"):
            if entry:
                meta, _, path = entry.partition("\t")
                mode, _kind, oid = meta.split(" ", 2)
                out[path] = (mode, oid)
        return out

    def blob(self, oid: str) -> bytes | None:
        if oid not in self.blobs:
            self.cat.stdin.write(oid.encode() + b"\n")
            self.cat.stdin.flush()
            header = self.cat.stdout.readline().split()
            if len(header) < 3:
                self.blobs[oid] = None
            else:
                data = self.cat.stdout.read(int(header[2]))
                self.cat.stdout.read(1)
                self.blobs[oid] = data if header[1] == b"blob" else None
        return self.blobs[oid]

    def reader(self, files: Files) -> Reader:
        return lambda path: self.blob(files[path][1]) if path in files else None


def replay(root: Path, commits: int, out=sys.stdout) -> dict:
    """Walks HEAD's first-parent history oldest first: a key seen at an earlier commit is a hit.

    Counts only commits whose change routes the step (it touches the step's inputs), as CI does."""
    table = ci_steps.load()
    step = table.steps[STEP]
    revs = subprocess.run(["git", "rev-list", "--first-parent", f"-n{commits * 6}", "HEAD"], cwd=root,
                          capture_output=True, text=True, check=True).stdout.split()
    routed = []
    for rev in revs:
        changed = subprocess.run(["git", "diff", "--name-only", f"{rev}^", rev], cwd=root, capture_output=True,
                                 text=True).stdout.split()
        if ci_steps.routed(step, changed):
            routed.append((rev, changed))
        if len(routed) == commits:
            break
    routed.reverse()
    git = GitTree(root)
    context = {"replay": True}
    seen_steps, seen_crates = set(), set()
    step_runs = step_hits = crate_runs = crate_hits = 0
    rows = []
    for rev, changed in routed:
        files = git.files(rev)
        ws = Workspace(files, git.reader(files))
        planned = crates(ws, packages_args(root, rev))
        step_k = hashlib.sha256(json.dumps(sorted([p, *v] for p, v in files.items() if ci_steps.routed(step, [p])))
                                .encode()).hexdigest()
        step_runs += 1
        step_hit = step_k in seen_steps
        step_hits += step_hit
        seen_steps.add(step_k)
        hits = 0
        for name, folder, fl, ts in planned or []:
            k = crate_key(ws, folder, name, fl, ts, context)
            crate_runs += 1
            if k in seen_crates:
                hits += 1
            seen_crates.add(k)
        crate_hits += hits
        rows.append({"commit": rev[:11], "step_hit": step_hit, "crates": len(planned or []), "crate_hits": hits})
        print(f"{rev[:11]} step {'hit ' if step_hit else 'miss'}  crates {hits}/{len(planned or [])} hit", file=out)
    result = {"commits": len(routed), "step_runs": step_runs, "step_hits": step_hits, "crate_runs": crate_runs,
              "crate_hits": crate_hits, "rows": rows}
    print(f"step: {step_hits}/{step_runs} hit; crates: {crate_hits}/{crate_runs} hit "
          f"({100 * crate_hits / max(1, crate_runs):.1f}%)", file=out)
    return result


def packages_args(root: Path, rev: str) -> list[str]:
    """The packages script's arguments at a past commit, from `git grep` at that commit (the script reads the work
    tree, so replay rebuilds its answer: members by name, --lib --bins for src/, --test NAME for tests/)."""
    listing = subprocess.run(["git", "grep", "-l", "cmux_next_", rev, "--", "cmux-tui/*.rs"], cwd=root,
                             capture_output=True, text=True).stdout.split()
    names, tests, flags = [], set(), set()
    for entry in listing:
        path = entry.split(":", 1)[1]
        parts = path.split("/")
        for i in range(len(parts) - 1, 0, -1):
            folder = "/".join(parts[:i])
            raw = subprocess.run(["git", "show", f"{rev}:{folder}/Cargo.toml"], cwd=root, capture_output=True).stdout
            if raw and b"[package]" in raw:
                name = re.search(rb'^name *= *"([^"]*)"', raw, re.M)
                if not name:
                    return ["--workspace"]
                n = name.group(1).decode()
                if n not in names:
                    names.append(n)
                rel = path[len(folder) + 1:]
                if rel.startswith("src/"):
                    flags.update(("--lib", "--bins"))
                elif rel.startswith("tests/"):
                    tests.add(rel.split("/")[1].removesuffix(".rs"))
                break
        else:
            return ["--workspace"]
    out = [w for n in sorted(names) for w in ("-p", n)] + sorted(flags)
    return out + [w for t in sorted(tests) for w in ("--test", t)]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("plan")
    p.add_argument("state", type=Path)
    p.add_argument("args", nargs=argparse.REMAINDER)
    q = sub.add_parser("post")
    q.add_argument("state", type=Path)
    r = sub.add_parser("replay")
    r.add_argument("--commits", type=int, default=20)
    r.add_argument("--json", type=Path)
    a = parser.parse_args(argv)
    env = dict(os.environ)
    if a.command == "plan":
        args = a.args[1:] if a.args[:1] == ["--"] else a.args
        try:
            runs = plan(a.state, args, env, out=sys.stderr)
        except Exception as err:  # a plan that breaks never skips a test: every crate runs
            print(f"crate results: plan failed ({type(err).__name__}: {err}); every crate runs", file=sys.stderr)
            runs = args
        print(" ".join(runs) if runs else REUSED_ALL)
        return 0
    if a.command == "post":
        return post(a.state, env)
    result = replay(ROOT, a.commits)
    if a.json:
        a.json.write_text(json.dumps(result, indent=1), encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
