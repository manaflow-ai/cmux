#!/usr/bin/env python3
"""The focused tests for a change: which tests to run when these source paths change.

    focused_tests.py --base A --head B        # the files A..B changes (git diff --name-only)
    focused_tests.py --files a.swift b.py     # explicit paths
    focused_tests.py ... --root DIR           # another checkout (tests)

Prints one JSON plan on stdout:

    {"files": [...],
     "python": [{"path": "tests/test_x.py", "lane": "linux-guard", "why": "..."}],
     "swift":  [{"package": "Packages/macOS/CmuxNext", "filter": "CmuxNextFilesTests", "why": "..."}],
     "cargo":  {"changed": true, "files": [...]},
     "web": [{"path": "test/x.test.ts", "why": "..."}],     # relative to webviews/
     "web_dropped": 0,      # reached, but past WEB_CAP (60) nearest tests
     "native": [{"manifest": "Native/OptChat/optchat-chief/Cargo.toml", "why": "..."}],
     "docs": [...],
     "unmapped": [...]}

Nothing here is a hand list that rots: the map is derived from the tree at the head.

  swift   A file under <package>/Sources/<Target>/ selects every test target, in that package
          or in any package that depends on it by path (select_package_tests.py's
          path_dependencies, transitively), whose sources import <Target> (`import X`,
          `@testable import X`), plus <Target>Tests when it exists. A file under
          <package>/Tests/<T>/ selects <T>. A Package.swift or Package.resolved change selects
          every test target of the package.
          CmuxNext itself is routed by scripts/ci/cmux_next_route.py (its committed SwiftPM target
          graph), the same selection the PR's swift test tier uses.
  web     A changed webviews test file runs itself. A file under webviews/src/ selects the
          webviews test files that import it (`../src/<path>` without its extension, or a
          directory index). Run one process per file (scripts/ci/run-webviews-tests.sh with
          CMUX_WEB_TEST_FILES).
  native  A file in a Native/ cargo workspace (a Cargo.toml beside a Cargo.lock, such as
          Native/OptChat/optchat-chief) selects `cargo test --locked` on that manifest.
  docs    Markdown needs no test. A plans/ or docs/ data file goes through the python scan (tests
          name plans/cmux-next/action-surfaces.json) and is a doc only when no test names it.
  caps    At most 60 webviews files (nearest by import distance) and 8 Swift test targets per
          car; more, or a CmuxNext route that selects everything, is deferred to the candidate.
  cargo   The cmux-tui files the change touches. The crates come from cargo_affected.py
          (owners plus reverse dependencies, from cargo metadata), which the runner calls where
          cargo is installed; this map does not repeat it.
  python  A changed tests/test_*.py runs itself. Any other file selects the tests/test_*.py
          that name its repo path, or, for a script or workflow with a distinctive basename,
          that basename (`fast-tier.py`, `cmux-next.yml`). The lane comes from
          tests/test-execution.toml; a runner runs only the lanes it can (linux-guard on Linux).

scripts/ci/focused-tests-extra.json adds what the tree cannot show: {"rules": [{"prefix":
"Resources/markdown-viewer/", "python": ["tests/test_x.py"]}]}. Keep it small; a rule there is
a sign a test should name the path it covers.

A file no rule maps is listed in `unmapped`. The car guards (car_guards.py) report it; the
broader tiers (fast tier, swift test) still cover it at the candidate build.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

try:
    import tomllib
except ModuleNotFoundError:  # Python < 3.11
    tomllib = None

EXTRA = "scripts/ci/focused-tests-extra.json"
PYTHON_TEST_DIRS = ("tests", "scripts/tests")
WEB_CAP = int(os.environ.get("FOCUSED_WEB_CAP", "60"))
# More Swift test targets than this is a whole-package run: the candidate's swift test tier.
SWIFT_CAP = int(os.environ.get("FOCUSED_SWIFT_CAP", "8"))
REGISTRY = "tests/test-execution.toml"
IMPORT = re.compile(r"^\s*(?:@testable\s+)?import\s+(?:(?:struct|class|enum|func|protocol)\s+)?([A-Za-z_][A-Za-z0-9_]*)", re.M)
# A basename this common names many unrelated files; only its full path selects tests.
COMMON = {"README.md", "Package.swift", "Package.resolved", "Cargo.toml", "Cargo.lock", "index.ts",
          "index.js", "main.swift", "lib.rs", "main.rs", "mod.rs", "package.json", "Info.plist",
          "__init__.py", "action.yml", "CLAUDE.md", "AGENTS.md", "Makefile", "build.zig"}
BASENAME_DIRS = ("scripts/", ".github/workflows/", ".github/actions/", "tests/")


def changed_files(root: Path, base: str, head: str) -> list[str]:
    out = subprocess.run(["git", "-C", str(root), "diff", "--name-only", "--no-renames", f"{base}...{head}"],
                         check=True, capture_output=True, text=True).stdout
    return sorted({line for line in out.splitlines() if line})


def lanes(root: Path) -> dict[str, str]:
    path = root / REGISTRY
    if not path.is_file():
        return {}
    text = path.read_text(encoding="utf-8")
    if tomllib:
        return {t["path"]: (t.get("lane", ""), bool(t.get("serial"))) for t in tomllib.loads(text).get("test", [])}
    found, current = {}, None
    for line in text.splitlines():  # the registry's flat [[test]] shape, for an old python3
        m = re.match(r'\s*(path|lane)\s*=\s*"([^"]*)"', line)
        if m and m.group(1) == "path":
            current = m.group(2)
            found[current] = ("", False)
        elif m and current:
            found[current] = (m.group(2), found[current][1])
        elif current and re.match(r"\s*serial\s*=\s*true", line):
            found[current] = (found[current][0], True)
    return found


def swift_package(root: Path, path: str) -> tuple[str, str, str] | None:
    """(package dir, Sources|Tests, target) for a file inside a SwiftPM package's target."""
    parts = path.split("/")
    for i in range(len(parts) - 2, 0, -1):
        if parts[i] in ("Sources", "Tests") and (root / "/".join(parts[:i]) / "Package.swift").is_file():
            return "/".join(parts[:i]), parts[i], parts[i + 1]
    return None


def swift_package_root(root: Path, path: str) -> str | None:
    if Path(path).name not in ("Package.swift", "Package.resolved"):
        return None
    package = str(Path(path).parent)
    return package if (root / package / "Package.swift").is_file() else None


class SwiftTests:
    """A package's test targets and the modules each imports, read once."""

    def __init__(self, root: Path):
        self.root, self._imports = root, {}

    def imports(self, package: str) -> dict[str, set[str]]:
        if package not in self._imports:
            found: dict[str, set[str]] = {}
            tests = self.root / package / "Tests"
            for target in sorted(p for p in tests.iterdir() if p.is_dir()) if tests.is_dir() else []:
                names = set()
                for source in target.rglob("*.swift"):
                    names |= set(IMPORT.findall(source.read_text(encoding="utf-8", errors="replace")))
                found[target.name] = names
            self._imports[package] = found
        return self._imports[package]

    def for_source(self, package: str, target: str) -> list[str]:
        tests = self.imports(package)
        return sorted(t for t, names in tests.items() if target in names or t == f"{target}Tests")


def dependents(root: Path) -> dict[str, set[str]]:
    """Package dir -> the package dirs that depend on it by path, transitively (itself included)."""
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import select_package_tests as packages  # noqa: E402

    dirs = sorted(packages.package_dirs(root).values())
    direct = {d: {dep for dep in packages.path_dependencies(root, d)} for d in dirs}
    out = {}
    for target in dirs:
        found, frontier = {target}, {target}
        while frontier:
            frontier = {d for d in dirs if direct[d] & frontier} - found
            found |= frontier
        out[target] = found
    return out


WEB = "webviews/"
WEB_TEST = re.compile(r"\.(test|spec)\.(ts|tsx|js|jsx|mjs)$|_(test|spec)\.(ts|tsx)$")


SPECIFIER = re.compile(r"""(?:from\s+|import\s*\(\s*|import\s+|require\(\s*)["'](\.{1,2}/[^"']+)["']""")
EXTENSIONS = (".ts", ".tsx", ".js", ".jsx", ".mjs")


def tracked(root: Path, prefix: str) -> list[str]:
    out = subprocess.run(["git", "-C", str(root), "ls-files", "-z", "--", prefix], capture_output=True, text=True)
    return [p for p in out.stdout.split("\0") if p] if out.returncode == 0 else []


class WebTests:
    """The webviews import graph by relative path, read once. A test file (in test/ or beside its
    source) covers what it imports, transitively: `./ops` from src/pages/settings/x.test.ts is
    src/pages/settings/ops.ts, `../src/agent-session` is that directory's index, and a component
    imported by a module that a test imports is covered by that test. A .css file is covered
    through the module that imports it."""

    def __init__(self, root: Path):
        self.root = root
        files = [f for f in tracked(root, WEB) if "/node_modules/" not in f]
        self.known = set(files)
        self.importers: dict[str, set[str]] = {}
        self.tests: set[str] = set()
        for source in files:
            if not source.endswith(EXTENSIONS):
                continue
            if WEB_TEST.search(source):
                self.tests.add(source)
            text = (root / source).read_text(encoding="utf-8", errors="replace")
            for spec in SPECIFIER.findall(text):
                target = self.resolve(source, spec)
                if target:
                    self.importers.setdefault(target, set()).add(source)

    def resolve(self, source: str, spec: str) -> str | None:
        base = os.path.normpath(os.path.join(os.path.dirname(source), spec))
        for candidate in (base, *(base + e for e in EXTENSIONS), *(f"{base}/index{e}" for e in EXTENSIONS)):
            if candidate in self.known:
                return candidate
        return None

    def browser(self, test: str) -> bool:
        """A file that launches a browser engine (requireBrowserLane, playwright) needs the
        webviews job's bundles and engines; the car defers it to the candidate's web tier."""
        text = (self.root / test).read_text(encoding="utf-8", errors="replace")
        return "requireBrowserLane" in text or "playwright" in text

    def for_file(self, path: str) -> list[tuple[int, str]]:
        """(import distance, test) for every test that reaches `path`, nearest first."""
        distance, frontier, found = 0, [path], []
        seen = {path}
        while frontier:
            found += [(distance, f) for f in sorted(frontier) if f in self.tests]
            distance += 1
            frontier = sorted({i for f in frontier for i in self.importers.get(f, ()) if i not in seen})
            seen.update(frontier)
        return found


def native_manifest(root: Path, path: str) -> str | None:
    if not path.startswith("Native/"):
        return None
    parts = path.split("/")
    for i in range(len(parts) - 1, 0, -1):
        directory = root / "/".join(parts[:i])
        if (directory / "Cargo.toml").is_file() and (directory / "Cargo.lock").is_file():
            return "/".join(parts[:i]) + "/Cargo.toml"
    return None


def is_doc(path: str) -> bool:
    return path.endswith(".md") or path.startswith("plans/") or path.startswith("docs/")


def cmux_next_tests(root: Path, files: list[str]) -> tuple[list[str] | None, set[str]]:
    """(test targets or None for all, the files the graph owns) from cmux_next_route.py."""
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import cmux_next_route as route  # noqa: E402

    mine = [f for f in files if f.startswith(route.PACKAGE)]
    if not mine or not (root / route.GRAPH).is_file():
        return [], set()
    result = route.route(root, "pull_request", mine, set())
    return (None if result.full else sorted(result.tests)), set(mine)


def python_tests(root: Path) -> dict[str, str]:
    return {str(p.relative_to(root)): p.read_text(encoding="utf-8", errors="replace")
            for directory in PYTHON_TEST_DIRS for p in sorted((root / directory).glob("test_*.py"))}


def distinctive(path: str) -> str | None:
    name = Path(path).name
    if not path.startswith(BASENAME_DIRS) or name in COMMON or "." not in name or len(name) < 8:
        return None
    return name


def plan(root: Path, files: list[str]) -> dict:
    swift_tests, registry = SwiftTests(root), lanes(root)
    users = None
    corpus = python_tests(root)
    extra = json.loads((root / EXTRA).read_text(encoding="utf-8")).get("rules", []) if (root / EXTRA).is_file() else []
    python: dict[str, str] = {}
    swift: dict[tuple[str, str], str] = {}
    cargo: list[str] = []
    web: dict[str, str] = {}
    native: dict[str, str] = {}
    docs: list[str] = []
    unmapped = []
    corpus_web = None  # WebTests, read on the first webviews change
    next_tests, next_files = cmux_next_tests(root, files)
    next_package = "Packages/macOS/CmuxNext"
    swift_deferred = ""
    if next_files and next_tests is None:
        # The route marks everything (a manifest, the target graph, a file in no target): every
        # CmuxNext suite is the candidate's swift test tier, not a fast guard.
        swift_deferred = "cmux_next_route.py selects every CmuxNext test target"
    elif next_files:
        for target in next_tests:
            swift.setdefault((next_package, target), "cmux_next_route.py")
    for path in files:
        hit = path in next_files and bool(next_tests is None or next_tests)
        if path.endswith(".md"):
            docs.append(path)
            continue
        if path.startswith(WEB):
            if corpus_web is None:
                corpus_web = WebTests(root)
            for distance, test in corpus_web.for_file(path):
                rel = test[len(WEB):]
                if rel not in web or web[rel][0] > distance:
                    web[rel] = (distance, "changed" if test == path else f"imports {path[len(WEB):]} ({distance} hop{'s' if distance > 1 else ''})")
                hit = True
        manifest = native_manifest(root, path)
        if manifest:
            native.setdefault(manifest, path)
            hit = True
        if path.startswith(tuple(d + "/" for d in PYTHON_TEST_DIRS)) and Path(path).name.startswith("test_") and path.endswith(".py"):
            if (root / path).is_file():
                python.setdefault(path, "changed")
                hit = True
        package = swift_package_root(root, path)
        if package and package != next_package:
            if len(swift_tests.imports(package)) > SWIFT_CAP:
                swift_deferred = swift_deferred or f"{path} selects every test target of {package}"
            else:
                for target in swift_tests.imports(package):
                    swift.setdefault((package, target), f"{path} changed")
            hit = True
        found = None if path in next_files else swift_package(root, path)
        if found:
            package, kind, target = found
            if kind == "Tests":
                selected = [(package, target)]
            else:
                if users is None:
                    users = dependents(root)
                selected = [(user, test) for user in sorted(users.get(package, {package}))
                            for test in swift_tests.for_source(user, target)]
            for key in selected:
                swift.setdefault(key, path)
            hit = hit or bool(selected)
        if path.startswith("cmux-tui/"):
            cargo.append(path)
            hit = True
        name = distinctive(path)
        for test, text in corpus.items():
            if test != path and (path in text or (name and name in text)):
                python.setdefault(test, f"names {path if path in text else name}")
                hit = True
        for rule in extra:
            if path.startswith(rule["prefix"]):
                for test in rule.get("python", []):
                    python.setdefault(test, f"{EXTRA}: {rule['prefix']}")
                hit = True
        if not hit and is_doc(path):
            docs.append(path)  # a plans/ or docs/ file no test names
        elif not hit:
            unmapped.append(path)
    # A module most of the suite reaches would make the car's guard the whole web suite: keep the
    # nearest WEB_CAP tests (by import distance, then name). The candidate's web tier runs the rest.
    nearest = sorted(web.items(), key=lambda item: (item[1][0], item[0]))[:WEB_CAP]
    return {
        "files": files,
        "python": [{"path": p, "lane": registry.get(p, ("", False))[0], "serial": registry.get(p, ("", False))[1], "why": why}
                   for p, why in sorted(python.items())],
        "swift": [] if swift_deferred or len(swift) > SWIFT_CAP else
                 [{"package": p, "filter": t, "why": why} for (p, t), why in sorted(swift.items())],
        "swift_deferred": swift_deferred or (f"{len(swift)} Swift test targets (over {SWIFT_CAP})" if len(swift) > SWIFT_CAP else ""),
        "cargo": {"changed": bool(cargo), "files": cargo},
        "web": [{"path": p, "why": why, "browser": corpus_web.browser(WEB + p)} for p, (_, why) in sorted(nearest)],
        "web_dropped": len(web) - len(nearest),
        "native": [{"manifest": m, "why": why} for m, why in sorted(native.items())],
        "docs": docs,
        "unmapped": unmapped,
    }


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", default=".")
    parser.add_argument("--base")
    parser.add_argument("--head", default="HEAD")
    parser.add_argument("--files", nargs="*")
    args = parser.parse_args(argv)
    root = Path(args.root).resolve()
    if args.files is not None:
        files = sorted(set(args.files))
    elif args.base:
        files = changed_files(root, args.base, args.head)
    else:
        parser.error("give --base (and --head) or --files")
    print(json.dumps(plan(root, files), indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
