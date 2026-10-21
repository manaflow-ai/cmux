#!/usr/bin/env python3
"""The inputs of a cmux-next job as one fingerprint, so a pass can be reused.

With `vars.CI_NEXT_JOB_REUSE == '1'`, cmux-next.yml's fast-tier and
fast-tier-cargo jobs look up a pass recorded under
`job-pass-<job>-<fingerprint>` (actions/cache) before they build. A hit skips
the build and the tests and names the run that passed; a job that passes
records its own. The fingerprint covers what the job reads:

- the job's block in cmux-next.yml, the fast-tier registry and quarantine, and
  the scripts and actions its steps run (JOBS below);
- cargo entries: the crates the entry packages reach through path
  dependencies, the workspace manifest, lockfile and toolchain, and every file
  outside those crates their sources name with `../` (include_str!, path
  dependencies, fixtures; the ghostty-next gitlink);
- swift entries: the packages the entry packages reach through
  `.package(path:)`, and for CmuxNext every file its tests read
  (ci-target-graph.json `reads`, which routing already depends on);
- script entries: the script's directory;
- `--extra` values the runner adds (Xcode, OS and architecture).

When the sources reach a file it cannot name (a `../` path that is not in the
tree, or a crate that walks up from CARGO_MANIFEST_DIR or #filePath at run
time), it prints no key, and the job runs as without reuse. Prints
`key=` and `fingerprint=` lines for $GITHUB_OUTPUT and the inputs on stderr.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import posixpath
import re
import subprocess
import sys
from dataclasses import dataclass, field

try:
    import tomllib
except ModuleNotFoundError:  # Python < 3.11: no cargo closure, so no key
    tomllib = None

VERSION = 1
WORKFLOW = ".github/workflows/cmux-next.yml"
REGISTRY = "scripts/cmux-next/fast-tier.json"
GRAPH = "Packages/macOS/CmuxNext/ci-target-graph.json"
COMMON = (
    WORKFLOW + "#job",
    REGISTRY,
    "scripts/cmux-next/fast-tier.py",
    "scripts/cmux-next/quarantine.json",
    "scripts/ci/job_input_fingerprint.py",
)


@dataclass(frozen=True)
class Job:
    kinds: tuple[str, ...]
    paths: tuple[str, ...] = field(default=())


JOBS = {
    "fast-tier": Job(("swift", "script"), (
        "scripts/select-ci-xcode.sh",
        "scripts/ci/reset-stale-submodules.sh",
        "scripts/ci/owned_spm_scratch.py",
        "scripts/cmux-next/fast-tier-cache-key.sh",
        "scripts/ci/e2e_warm_derived_data.py",
        ".github/actions/cache-restore",
    )),
    "fast-tier-cargo": Job(("cargo",), (
        ".gitmodules",
        "ghostty-next",  # GHOSTTY_ZIG_SOURCE: ghostty-vt-sys builds libghostty-vt from this gitlink
        "scripts/ci/init-submodule.sh",
        "scripts/install-zig-ci.sh",
        "scripts/ghostty-zig-version.sh",  # install-zig-ci.sh's pin, with the Zig SDK's minimum version:
        "cmux-tui/bindings/zig/build.zig.zon",
        ".github/actions/setup-cmux-tui-rust",
    )),
}

# A quoted string that climbs out of its directory, and the compile-time forms of one. git grep -E
# patterns: a backslash in a bracket is literal there (`[^"\n]` would also refuse the letter n), and
# git grep matches line by line, so `[^"]` stays on one line.
ESCAPE = r'"[^"]*\.\./[^"]*"'
INCLUDE = r'include(_str|_bytes)?!\([^;]*"[^"]*\.\./[^"]*"'
TOML_PATH = r'path *= *"[^"]*\.\./[^"]*"'
# Code that finds files from where it sits at run time, which no `../` names.
WALKS_UP = {
    "cargo": ("CARGO_MANIFEST_DIR", re.compile(r"CARGO_MANIFEST_DIR[^;]{0,300}?(\.parent\(\)|\.ancestors\(\))")),
    "swift": ("#file", re.compile(r"#(file|filePath)\b[\s\S]{0,300}?deletingLastPathComponent")),
}


class Unresolved(Exception):
    """The job reads something the fingerprint cannot name."""


class Tree:
    """One commit's files, read through git."""

    def __init__(self, root: str, rev: str):
        self.root, self.rev = root, rev
        self._ids: dict[str, str] = {}
        self._dirs: set[str] | None = None

    def git(self, *args: str, stdin: str | None = None) -> str:
        return subprocess.run(["git", "-C", self.root, *args], input=stdin, capture_output=True, text=True,
                              check=True, timeout=120).stdout

    def ids(self, paths) -> dict[str, str]:
        """Object id (blob, tree or gitlink commit) of each path; "missing" when absent."""
        if "." in paths and "." not in self._ids:  # the whole tree
            self._ids["."] = self.git("rev-parse", f"{self.rev}^{{tree}}").strip()
        want = sorted({p for p in paths if p not in self._ids})
        if want:
            # ls-tree, not cat-file: a gitlink's commit is not in this repository.
            # A path and one below it in one call list only the lower one, so they go in separate calls.
            batches: list[list[str]] = []
            for path in want:
                batch = next((b for b in batches if not any(
                    path.startswith(o + "/") or o.startswith(path + "/") for o in b)), None)
                if batch is None:
                    batches.append(batch := [])
                batch.append(path)
            listed = {}
            for batch in batches:
                for record in self.git("ls-tree", "-z", "--full-tree", self.rev, "--", *batch).split("\0"):
                    if record:
                        meta, name = record.split("\t", 1)
                        listed[name] = meta.split()[2]
            for path in want:
                self._ids[path] = listed.get(path, "missing")
        return {p: self._ids[p] for p in paths}

    def exists(self, path: str) -> bool:
        if path in ("", "."):
            return True
        if path in self._ids:
            return self._ids[path] != "missing"
        if self._dirs is None:
            names = self.git("ls-tree", "-r", "-t", "--name-only", self.rev).splitlines()
            self._dirs = set(names)
        return path in self._dirs

    def read(self, path: str) -> str:
        return self.git("cat-file", "-p", f"{self.rev}:{path}")

    def grep(self, pattern: str, specs) -> list[tuple[str, str]]:
        """(file, match) for every match of an extended regex in files under specs."""
        result = subprocess.run(["git", "-C", self.root, "grep", "-o", "-I", "-E", "-e", pattern, self.rev, "--", *specs],
                                capture_output=True, text=True, timeout=120)
        if result.returncode not in (0, 1):
            raise RuntimeError(result.stderr.strip())
        found = []
        for line in result.stdout.splitlines():
            _, path, match = line.split(":", 2)
            found.append((path, match))
        return found

    def files_matching(self, token: str, pattern: re.Pattern, specs) -> list[str]:
        """Files under specs that contain `token` and match `pattern` across lines."""
        result = subprocess.run(["git", "-C", self.root, "grep", "-l", "-I", "-F", "-e", token, self.rev, "--", *specs],
                                capture_output=True, text=True, timeout=120)
        if result.returncode not in (0, 1):
            raise RuntimeError(result.stderr.strip())
        names = [line.split(":", 1)[1] for line in result.stdout.splitlines()]
        return [name for name in names if pattern.search(self.read(name))]


def escapes(tree: Tree, dirs: list[str], specs: list[str], pattern: str = ESCAPE, walks: str | None = None) -> set[str]:
    """Paths outside `dirs` that the files under them name with `../` (resolved from the file and from its
    dir in `dirs`). A name that is not in the tree is skipped: nothing can read it. With `walks`, code that
    climbs from its own location at run time makes the inputs unnameable."""
    inside = lambda p: any(p == d or p.startswith(d + "/") for d in dirs)  # noqa: E731
    patterns = [f"{d}/{s}" for d in dirs for s in specs]
    if walks:
        walkers = tree.files_matching(*WALKS_UP[walks], patterns)
        if walkers:
            raise Unresolved(f"finds files from its own location at run time: {', '.join(sorted(walkers)[:5])}")
    found: set[str] = set()
    for path, match in tree.grep(pattern, patterns):
        text = match[match.rfind('"', 0, len(match) - 1) + 1:-1]
        relative = text[text.find("../"):].split("{")[0].split("\\")[0].rstrip("/")
        owner = next(d for d in dirs if path.startswith(d + "/"))
        for base in (posixpath.dirname(path), owner):
            candidate = posixpath.normpath(posixpath.join(base, relative))
            if candidate.startswith("..") or inside(candidate) or not tree.exists(candidate):
                continue
            if candidate == "." or path.startswith(candidate + "/"):
                found |= joined(tree, path, candidate)
            else:
                found.add(candidate)
    return found


LITERAL = re.compile(r'"([^"\n{}\\ ]+)"')


def joined(tree: Tree, path: str, ancestor: str) -> set[str]:
    """What a file reads below a directory it climbs to (`root.join("Packages/...")`): the paths its literals
    name there, or the whole directory when they name none."""
    named = set()
    for literal in LITERAL.findall(tree.read(path)):
        if literal.startswith(("/", "..")):
            continue
        target = posixpath.normpath(posixpath.join(ancestor, literal))
        if target != ancestor and tree.exists(target):
            named.add(target)
    return named or {ancestor}


def cargo_inputs(tree: Tree, entries: list[dict]) -> set[str]:
    if tomllib is None:
        raise Unresolved("python has no tomllib")
    inputs: set[str] = set()
    for root in sorted({e["path"] for e in entries}):
        manifest = tomllib.loads(tree.read(f"{root}/Cargo.toml"))
        workspace = manifest.get("workspace", {})
        paths = {name: dep["path"] for name, dep in workspace.get("dependencies", {}).items()
                 if isinstance(dep, dict) and "path" in dep}
        by_name: dict[str, str] = {}
        for member in workspace.get("members", []):
            if "*" in member or not tree.exists(f"{root}/{member}/Cargo.toml"):
                continue
            name = tomllib.loads(tree.read(f"{root}/{member}/Cargo.toml")).get("package", {}).get("name")
            if name:
                by_name[name] = member
        by_name.update({name: path for name, path in paths.items() if name not in by_name})

        def deps(crate: str, dev: bool) -> set[str]:
            data = tomllib.loads(tree.read(f"{root}/{crate}/Cargo.toml"))
            tables = [data.get("dependencies", {}), data.get("build-dependencies", {})]
            if dev:
                tables.append(data.get("dev-dependencies", {}))
            for target in data.get("target", {}).values():
                tables += [target.get("dependencies", {}), target.get("build-dependencies", {})]
                if dev:
                    tables.append(target.get("dev-dependencies", {}))
            found = set()
            for table in tables:
                for name, dep in table.items():
                    if not isinstance(dep, dict):
                        continue
                    name = dep.get("package", name)
                    if "path" in dep:
                        found.add(posixpath.normpath(posixpath.join(crate, dep["path"])))
                    elif dep.get("workspace") and name in paths:
                        found.add(posixpath.normpath(paths[name]))
            return found

        seen: set[str] = set()
        todo = [(by_name[e["package"]], True) for e in entries if e["path"] == root]
        while todo:
            crate, dev = todo.pop()
            if crate in seen:
                continue
            seen.add(crate)
            if crate.startswith(".."):
                raise Unresolved(f"{root} depends on {crate}, outside its workspace")
            todo += [(dep, False) for dep in deps(crate, dev)]
        crates = sorted(f"{root}/{c}" for c in seen)
        inputs |= set(crates)
        inputs |= {f"{root}/{name}" for name in ("Cargo.toml", "Cargo.lock", "rust-toolchain.toml", ".cargo",
                                                    "build-support")}
        # What the compiler reads (every crate), then what the entry crates' tests read at run time.
        inputs |= escapes(tree, crates, ["*.rs"], INCLUDE) | escapes(tree, crates, ["Cargo.toml"], TOML_PATH)
        inputs |= escapes(tree, crates, ["build.rs"])
        entry_crates = sorted({f"{root}/{by_name[e['package']]}" for e in entries if e["path"] == root})
        inputs |= escapes(tree, entry_crates, ["*.rs", "*.json", "*.toml"], walks="cargo")
    return inputs


PACKAGE_PATH = re.compile(r'\.package\(\s*(?:name:\s*"[^"]*",\s*)?path:\s*"([^"]+)"')


def swift_inputs(tree: Tree, entries: list[dict]) -> set[str]:
    seen: set[str] = set()
    todo = [e["package"] for e in entries]
    while todo:
        package = posixpath.normpath(todo.pop())
        if package in seen:
            continue
        if package.startswith("..") or not tree.exists(f"{package}/Package.swift"):
            raise Unresolved(f"package {package} is not in the tree")
        seen.add(package)
        todo += [posixpath.join(package, p) for p in PACKAGE_PATH.findall(tree.read(f"{package}/Package.swift"))]
    inputs = set(seen)
    graph_packages = {posixpath.dirname(GRAPH)}
    if seen & graph_packages:
        graph = json.loads(tree.read(GRAPH))
        inputs |= {read.rstrip("/") for target in graph["targets"].values() for read in target.get("reads", [])}
    # What the build reads outside the packages (flags, plugins), then what the entry packages' tests read
    # at run time; CmuxNext's are its graph's reads.
    inputs |= escapes(tree, sorted(seen), ["Package.swift"])
    tested = sorted({posixpath.normpath(e["package"]) for e in entries} - graph_packages)
    if tested:
        inputs |= escapes(tree, tested, ["Tests/*.swift"], walks="swift")
    return inputs


def job_block(text: str, job: str) -> str:
    """The job's block in the workflow, after the workflow-level `env:` every job inherits."""
    lines = text.splitlines()
    env = []
    if "env:" in lines:
        at = lines.index("env:")
        env = [lines[at]] + [line for line in lines[at + 1:next(
            (i for i in range(at + 1, len(lines)) if lines[i] and not lines[i].startswith((" ", "#"))), len(lines))]]
    start = lines.index(f"  {job}:")
    end = next((i for i in range(start + 1, len(lines))
                if lines[i] and not lines[i].startswith((" ", "#")) or re.match(r"  [A-Za-z0-9_-]+:\s*$", lines[i])),
               len(lines))
    return "\n".join(env + lines[start:end])


def fingerprint(tree: Tree, job: str, extra: list[str]) -> tuple[str, dict]:
    spec = JOBS[job]
    entries = [e for e in json.loads(tree.read(REGISTRY))["entries"] if e.get("kind") in spec.kinds]
    paths = set(COMMON[1:]) | set(spec.paths)
    paths |= cargo_inputs(tree, [e for e in entries if e["kind"] == "cargo"]) if any(
        e["kind"] == "cargo" for e in entries) else set()
    paths |= swift_inputs(tree, [e for e in entries if e["kind"] == "swift"]) if any(
        e["kind"] == "swift" for e in entries) else set()
    paths |= {posixpath.dirname(e["path"]) or e["path"] for e in entries if e["kind"] == "script"}
    value = {
        "version": VERSION,
        "job": job,
        "block": hashlib.sha256(job_block(tree.read(WORKFLOW), job).encode()).hexdigest(),
        "inputs": tree.ids(sorted(paths)),
        "extra": sorted(extra),
    }
    raw = json.dumps(value, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(raw.encode()).hexdigest(), value


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("job", choices=sorted(JOBS))
    parser.add_argument("--root", default=".")
    parser.add_argument("--rev", default="HEAD")
    parser.add_argument("--extra", action="append", default=[], help="KEY=VALUE the runner adds (repeatable)")
    args = parser.parse_args(argv)
    try:
        digest, value = fingerprint(Tree(args.root, args.rev), args.job, args.extra)
    except Unresolved as why:
        print(f"::notice title=No reuse for {args.job}::its inputs can't all be named: {why}", file=sys.stderr)
        return 0
    for path, oid in value["inputs"].items():
        print(f"{oid[:12]} {path}", file=sys.stderr)
    print(f"{len(value['inputs'])} inputs, extra {value['extra']}", file=sys.stderr)
    print(f"key=job-pass-{args.job}-{digest[:40]}")
    print(f"fingerprint={digest}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
