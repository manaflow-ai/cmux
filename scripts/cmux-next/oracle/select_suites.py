#!/usr/bin/env python3
"""Changed paths to the oracle suites and cases they can change, with the reason for each (p15-oracle-009).

Spec: plans/cmux-next/chrome-parity/p15-oracle.md, 3F.6 and task 009. Stdlib only, safe under `python3 -I`.
The Rust graph needs tomllib (Python 3.11+, the VM); an older python3 selects conservatively (below).
This file is select_suites.py and not select.py: a `select.py` beside the oracle scripts would shadow the stdlib
`select` module (a shared library on macOS) for every oracle script run without -I.

    select_suites.py [PATH ...] [--paths-from FILE|-]   the paths given
    select_suites.py --base A --head B                  the paths `git diff A B` changes (one batch)
    select_suites.py --range A..B [--all-parents]       one selection per commit, oldest first, and their union
    select_suites.py check                              lint tests/oracle/suite-map.json against the tree
    oracle.py select ARGS                               the same (oracle.py delegates here)
Options: --map, --corpus, --repo, --json. The output names, per product, the `oracle.py run` or `oracle.py diff`
command of the selection (`--suite` for whole suites, `--filter` for single cases).

Map (tests/oracle/suite-map.json, schema cmux-oracle-suite-map-v1):
    products  {product: {"suites": [...], "cargo_roots": [package dir, ...]}}: the suites each product runs, and the
              Rust packages its binaries are built from (their normal and build path dependencies are the product).
    cargo     {"scope": [glob], "not_linked": [dir name], "reason"}: a path under scope belongs to the package of its
              nearest Cargo.toml; it selects every product whose closure holds that package. A package no product
              links, or a path under one of its not_linked dirs (tests, benches, examples), selects nothing. A
              package that is also its workspace's root owns only its manifest, src/, and the dirs of its lib, bins
              and build script; the rest of the workspace dir goes to the rules, ignore rules and unmapped policy.
    rules     [{"id", "paths": [glob], "except": [glob], "products": [p] or ["all"], "suites": [s], "cases":
              [suite/case glob], "reason"}]: every rule whose paths match applies. `suites` narrows the products'
              suites; `cases` narrows them to single cases.
    ignore    [{"id", "paths", "except", "reason"}]: a path no rule selects and an ignore rule matches selects nothing.
    unmapped  "all" or "none": what a path that no rule, no package and no ignore rule covers selects.
Globs are repo-relative: `*` and `?` stay inside one path segment, `**` spans segments.
Built in, before the map's rules: a case file under tests/oracle/corpus selects that case; another file there selects
the cases of its directory (a driver or generator reads `_tuning.json`, `_parity.json` and the like next to them);
Expectations.d/, NeverFix.d/ and SanitizerExpectations.d/<suite>.txt select the suite; a baseline under
tests/oracle/baselines selects its case.

The selection is a function of the set of changed paths, the map, the corpus and the Cargo manifests of the working
tree: the order and repetition of the paths do not change a byte of it. Status, after gn: "none" (no path selects a
case), "found" (a selection), or "all" (an unmapped path with `"unmapped": "all"`, or a rule over every product's
suites). Without tomllib every path under cargo.scope selects every product with cargo_roots, and the output says so.

Exit codes: 0 a selection was printed (any status), 1 `check` found problems, 2 bad arguments or input.

Chrome reference (chromium/src):
- gn analyze (gn/src/gn/analyzer.cc): the changed files and the build graph give the affected test targets, with
  the status "Found dependency", "No dependency", or "Found dependency (all)" when a build file changed and the graph
  cannot say. Here the graph is the Cargo path dependencies plus the reviewed rules of the map; an unmapped path is
  the "(all)" case.
- tools/mb/mb.py `analyze`: the recipe passes the files of the patch and runs only the returned test targets; a
  file outside the graph affects nothing.
- infra/config `location_filters` (LUCI CQ): a tryjob runs only when a changed path matches its regexes, which is
  what `rules` and `ignore` state per suite here.
"""

from __future__ import annotations

import argparse
import fnmatch
import functools
import hashlib
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, Iterable, List, Mapping, Optional, Sequence, Set, Tuple

try:
    import tomllib  # Python 3.11+
except ImportError:  # pragma: no cover - the fleet minis' system python3 is 3.9
    tomllib = None  # type: ignore[assignment]

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
DEFAULT_MAP = REPO / "tests" / "oracle" / "suite-map.json"
DEFAULT_CORPUS = REPO / "tests" / "oracle" / "corpus"
ORACLE = HERE / "oracle.py"
MAP_SCHEMA = "cmux-oracle-suite-map-v1"
SELECTION_SCHEMA = "cmux-oracle-selection-v1"
RANGE_SCHEMA = "cmux-oracle-selection-range-v1"
EMPTY_TREE = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
UNMAPPED_POLICIES = ("all", "none")

CORPUS_DIR = "tests/oracle/corpus/"
BASELINES_DIR = "tests/oracle/baselines/"
EXPECTATION_DIRS = ("tests/oracle/Expectations.d/", "tests/oracle/NeverFix.d/", "tests/oracle/SanitizerExpectations.d/")

STATUS_NONE, STATUS_FOUND, STATUS_ALL = "none", "found", "all"


class UsageError(Exception):
    """A bad argument or an unreadable map, corpus or repository: exit 2."""


# ---------------------------------------------------------------------------------------------------------- globs


def glob_regex(pattern: str) -> "re.Pattern[str]":
    """A repo-relative glob as a full-match regex: `*`/`?` within a segment, `**` across segments."""
    if not pattern or pattern.startswith(("/", "./")) or "\\" in pattern:
        raise UsageError(f"glob {pattern!r}: write a repo-relative path without a leading / or ./")
    out, i = [], 0
    while i < len(pattern):
        if pattern.startswith("**/", i):
            out.append("(?:.*/)?")
            i += 3
        elif pattern.startswith("/**", i) and i + 3 == len(pattern):
            out.append("(?:/.*)?")
            i += 3
        elif pattern.startswith("**", i):
            out.append(".*")
            i += 2
        elif pattern[i] == "*":
            out.append("[^/]*")
            i += 1
        elif pattern[i] == "?":
            out.append("[^/]")
            i += 1
        else:
            out.append(re.escape(pattern[i]))
            i += 1
    return re.compile("".join(out))


@dataclass(frozen=True)
class PathSet:
    """`paths` minus `except`, as compiled globs."""

    paths: Tuple[str, ...]
    excluded: Tuple[str, ...] = ()
    _compiled: Tuple[Tuple["re.Pattern[str]", ...], Tuple["re.Pattern[str]", ...]] = field(
        default=((), ()), compare=False, repr=False)

    @classmethod
    def of(cls, paths: Sequence[str], excluded: Sequence[str] = ()) -> "PathSet":
        compiled = (tuple(glob_regex(p) for p in paths), tuple(glob_regex(p) for p in excluded))
        return cls(tuple(paths), tuple(excluded), compiled)

    def matches(self, path: str) -> bool:
        include, exclude = self._compiled
        return any(r.fullmatch(path) for r in include) and not any(r.fullmatch(path) for r in exclude)


# ------------------------------------------------------------------------------------------------------------ map


@dataclass(frozen=True)
class Rule:
    id: str
    paths: PathSet
    reason: str
    products: Tuple[str, ...] = ()
    suites: Tuple[str, ...] = ()
    cases: Tuple[str, ...] = ()


@dataclass(frozen=True)
class SuiteMap:
    products: Dict[str, Tuple[str, ...]]
    cargo_roots: Dict[str, Tuple[str, ...]]
    cargo_scope: Optional[PathSet]
    cargo_not_linked: Tuple[str, ...]
    cargo_reason: str
    rules: Tuple[Rule, ...]
    ignore: Tuple[Rule, ...]
    unmapped: str
    sha256: str
    raw: Dict[str, Any]

    def products_running(self, suite: str) -> List[str]:
        return sorted(p for p, suites in self.products.items() if suite in suites)


def need(value: Any, kind: type, where: str) -> Any:
    if not isinstance(value, kind):
        raise UsageError(f"suite map: {where} must be a {kind.__name__}")
    return value


def strings(value: Any, where: str) -> Tuple[str, ...]:
    items = need(value if value is not None else [], list, where)
    if not all(isinstance(v, str) and v for v in items):
        raise UsageError(f"suite map: {where} must be a list of non-empty strings")
    return tuple(items)


def parse_rule(raw: Any, where: str, *, selecting: bool) -> Rule:
    need(raw, dict, where)
    rid = raw.get("id")
    if not isinstance(rid, str) or not rid:
        raise UsageError(f"suite map: {where} has no id")
    reason = raw.get("reason")
    if not isinstance(reason, str) or not reason.strip():
        raise UsageError(f"suite map: rule {rid} has no reason")
    paths = strings(raw.get("paths"), f"rule {rid} paths")
    if not paths:
        raise UsageError(f"suite map: rule {rid} has no paths")
    known = {"id", "paths", "except", "reason"} | ({"products", "suites", "cases"} if selecting else set())
    extra = sorted(set(raw) - known)
    if extra:
        raise UsageError(f"suite map: rule {rid} has unknown keys {extra}")
    products = strings(raw.get("products"), f"rule {rid} products") if selecting else ()
    if selecting and not products:
        raise UsageError(f"suite map: rule {rid} selects no product")
    return Rule(rid, PathSet.of(paths, strings(raw.get("except"), f"rule {rid} except")), reason.strip(), products,
                strings(raw.get("suites"), f"rule {rid} suites") if selecting else (),
                strings(raw.get("cases"), f"rule {rid} cases") if selecting else ())


def load_map(path: Path) -> SuiteMap:
    try:
        text = path.read_text(encoding="utf-8")
        raw = json.loads(text)
    except (OSError, ValueError) as error:
        raise UsageError(f"{path}: cannot read the suite map: {error}") from None
    need(raw, dict, "the document")
    if raw.get("schema") != MAP_SCHEMA:
        raise UsageError(f"{path}: schema is {raw.get('schema')!r}, expected {MAP_SCHEMA}")
    products: Dict[str, Tuple[str, ...]] = {}
    roots: Dict[str, Tuple[str, ...]] = {}
    for name, spec in sorted(need(raw.get("products"), dict, "products").items()):
        need(spec, dict, f"products.{name}")
        products[name] = strings(spec.get("suites"), f"products.{name}.suites")
        roots[name] = strings(spec.get("cargo_roots"), f"products.{name}.cargo_roots")
    cargo = need(raw.get("cargo") or {}, dict, "cargo")
    scope = strings(cargo.get("scope"), "cargo.scope")
    rules = tuple(parse_rule(r, f"rules[{i}]", selecting=True) for i, r in enumerate(need(raw.get("rules") or [], list, "rules")))
    ignore = tuple(parse_rule(r, f"ignore[{i}]", selecting=False) for i, r in enumerate(need(raw.get("ignore") or [], list, "ignore")))
    seen: Set[str] = set()
    for rule in rules + ignore:
        if rule.id in seen or rule.id in BUILTIN_RULES:
            raise UsageError(f"suite map: rule id {rule.id} is used twice")
        seen.add(rule.id)
    unmapped = raw.get("unmapped", "all")
    if unmapped not in UNMAPPED_POLICIES:
        raise UsageError(f"suite map: unmapped is {unmapped!r}, expected one of {UNMAPPED_POLICIES}")
    return SuiteMap(products, roots, PathSet.of(scope) if scope else None,
                    strings(cargo.get("not_linked"), "cargo.not_linked"), str(cargo.get("reason") or "").strip(),
                    rules, ignore, unmapped, hashlib.sha256(text.encode("utf-8")).hexdigest(), raw)


# ----------------------------------------------------------------------------------------------------- cargo graph


@dataclass(frozen=True)
class CargoGraph:
    """Which products link the package at each repo-relative directory (normal and build path dependencies)."""

    linked_by: Dict[str, Tuple[str, ...]]
    available: bool
    note: str

    def package_of(self, repo: Path, path: str, scope_dirs: Sequence[str]) -> Optional[str]:
        """The repo-relative dir of the nearest Cargo.toml with a [package] above `path` (the working tree's)."""
        parts = path.split("/")[:-1]
        while parts:
            directory = "/".join(parts)
            manifest = repo / directory / "Cargo.toml"
            if (directory in self.linked_by or is_package(manifest)) and owns(manifest, path[len(directory) + 1:]):
                return directory
            if directory in scope_dirs:
                return None
            parts.pop()
        return None


@functools.lru_cache(maxsize=None)
def read_toml(path: Path) -> Optional[Dict[str, Any]]:
    """A parsed Cargo.toml (cached: callers only read it)."""
    try:
        with path.open("rb") as handle:
            return tomllib.load(handle)  # type: ignore[union-attr]
    except (OSError, ValueError):
        return None


@functools.lru_cache(maxsize=None)
def is_package(manifest: Path) -> bool:
    if not manifest.is_file():
        return False
    if tomllib is None:
        return True
    document = read_toml(manifest)
    return bool(document and isinstance(document.get("package"), dict))


@functools.lru_cache(maxsize=None)
def root_package_sources(manifest: Path) -> Optional[Tuple[str, ...]]:
    """What a package that is also its workspace's root owns: its manifest and the dirs of its linked targets.

    None for any other package, which owns its whole directory. A workspace root's directory holds the other
    members, frontends, scripts and docs; only the targets Cargo builds into a dependent (the lib, bins and the build
    script, at their `path` or Cargo's default src/ and build.rs) are the package (cmux-tui's source-watch package).
    """
    document = read_toml(manifest) if tomllib is not None else None
    if not document or not isinstance(document.get("workspace"), dict):
        return None
    targets = [t for t in [document.get("lib")] + list(document.get("bin") or []) if isinstance(t, dict)]
    paths = [t["path"] for t in targets if isinstance(t.get("path"), str)]
    build = (document.get("package") or {}).get("build")
    paths.append(build if isinstance(build, str) else "build.rs")
    owned = {"Cargo.toml", "src"} | {p.split("/", 1)[0] if "/" in p else p for p in paths}
    return tuple(sorted(owned))


def owns(manifest: Path, rel: str) -> bool:
    """Whether the package of `manifest` owns the file at `rel` (relative to the package dir)."""
    sources = root_package_sources(manifest)
    return sources is None or any(rel == s or rel.startswith(s + "/") for s in sources)


def workspace_root(package_dir: Path, stop: Path) -> Optional[Path]:
    """The nearest dir at or above `package_dir` whose Cargo.toml has [workspace]."""
    current = package_dir
    while True:
        document = read_toml(current / "Cargo.toml") if (current / "Cargo.toml").is_file() else None
        if document and isinstance(document.get("workspace"), dict):
            return current
        if current == stop or current.parent == current:
            return None
        current = current.parent


def dependency_tables(document: Mapping[str, Any]) -> Iterable[Mapping[str, Any]]:
    """[dependencies] and [build-dependencies], also per target; dev-dependencies are not in a product."""
    for key in ("dependencies", "build-dependencies"):
        if isinstance(document.get(key), dict):
            yield document[key]
    for target in (document.get("target") or {}).values():
        if isinstance(target, dict):
            for key in ("dependencies", "build-dependencies"):
                if isinstance(target.get(key), dict):
                    yield target[key]


def path_dependencies(repo: Path, package_dir: Path) -> List[Path]:
    document = read_toml(package_dir / "Cargo.toml") or {}
    found: List[Path] = []
    root: Optional[Path] = None
    for table in dependency_tables(document):
        for name, spec in sorted(table.items()):
            if not isinstance(spec, dict):
                continue
            if isinstance(spec.get("path"), str):
                found.append((package_dir / spec["path"]).resolve())
            elif spec.get("workspace") is True:
                root = root or workspace_root(package_dir, repo)
                inherited = ((read_toml(root / "Cargo.toml") or {}).get("workspace", {}).get("dependencies", {})
                             if root else {}).get(name)
                if root and isinstance(inherited, dict) and isinstance(inherited.get("path"), str):
                    found.append((root / inherited["path"]).resolve())
    return found


def load_cargo_graph(repo: Path, roots: Mapping[str, Sequence[str]]) -> CargoGraph:
    if tomllib is None:
        return CargoGraph({}, False, "no tomllib (Python < 3.11): every path under cargo.scope selects every product "
                                     "with cargo_roots")
    repo = repo.resolve()
    linked: Dict[str, Set[str]] = {}
    missing: List[str] = []
    for product, product_roots in sorted(roots.items()):
        stack = [(repo / r).resolve() for r in product_roots]
        seen: Set[Path] = set()
        while stack:
            directory = stack.pop()
            if directory in seen:
                continue
            seen.add(directory)
            if not is_package(directory / "Cargo.toml"):
                missing.append(str(directory))
                continue
            try:
                rel = directory.relative_to(repo).as_posix()
            except ValueError:
                continue  # a path dependency outside the repository is not a changed path here
            linked.setdefault(rel, set()).add(product)
            stack.extend(path_dependencies(repo, directory))
    note = "Cargo.toml path dependencies of the working tree"
    if missing:
        note += "; missing packages: " + ", ".join(sorted(set(missing)))
    return CargoGraph({k: tuple(sorted(v)) for k, v in sorted(linked.items())}, True, note)


# ------------------------------------------------------------------------------------------------------- selection


@dataclass(frozen=True)
class Hit:
    rule: str
    reason: str
    targets: Tuple[Tuple[str, str, Optional[str]], ...]  # (product, suite, case glob or None for the whole suite)


BUILTIN_RULES = ("corpus-case", "corpus-dir", "expectations", "baselines", "cargo", "unmapped")


def corpus_hit(smap: SuiteMap, path: str) -> Optional[Hit]:
    """The built-in rules over tests/oracle: corpus, expectations and baselines name their suite and case."""
    def targets(suite: str, case: Optional[str]) -> Tuple[Tuple[str, str, Optional[str]], ...]:
        return tuple((p, suite, case) for p in smap.products_running(suite))

    if path.startswith(CORPUS_DIR):
        rel = path[len(CORPUS_DIR):]
        parts = rel.split("/")
        if len(parts) < 2:
            return None
        suite, name = parts[0], parts[-1]
        if name.endswith(".json") and name != "coverage.json" and not name.startswith("_"):
            case = rel[: -len(".json")]
            return Hit("corpus-case", f"the case {case} changed", targets(suite, case))
        directory = "/".join(parts[:-1])
        glob = None if len(parts) == 2 else directory + "/*"
        return Hit("corpus-dir", f"{name} sits beside the cases of {directory}", targets(suite, glob))
    for prefix in EXPECTATION_DIRS:
        if path.startswith(prefix) and path.endswith(".txt") and "/" not in path[len(prefix):]:
            suite = path[len(prefix): -len(".txt")]
            return Hit("expectations", f"the {prefix.split('/')[-2]} lines of {suite} changed", targets(suite, None))
    if path.startswith(BASELINES_DIR) and path.endswith(".expected.jsonl"):
        parts = path[len(BASELINES_DIR): -len(".expected.jsonl")].split("/")
        if parts[:1] == ["platform"] and len(parts) > 2:
            parts = parts[2:]
        if parts[:1] == ["arm"] and len(parts) > 2:
            parts = parts[2:]
        if len(parts) >= 2:
            case = "/".join(parts)
            return Hit("baselines", f"a baseline of {case} changed", targets(parts[0], case))
    return None


def rule_hit(smap: SuiteMap, rule: Rule) -> Hit:
    products = sorted(smap.products) if "all" in rule.products else sorted(rule.products)
    out: List[Tuple[str, str, Optional[str]]] = []
    for product in products:
        suites = smap.products.get(product, ())
        if rule.cases:
            for glob in rule.cases:
                suite = glob.split("/", 1)[0]
                if suite in suites and (not rule.suites or suite in rule.suites):
                    out.append((product, suite, glob))
        else:
            out.extend((product, s, None) for s in suites if not rule.suites or s in rule.suites)
    return Hit(rule.id, rule.reason, tuple(out))


@dataclass
class PathVerdict:
    path: str
    status: str  # selected, ignored or unmapped
    hits: List[Hit]


def scope_dirs(smap: SuiteMap) -> List[str]:
    """The literal directory prefixes of cargo.scope: the walk up for a Cargo.toml stops there."""
    if not smap.cargo_scope:
        return []
    return sorted({p.split("*", 1)[0].rstrip("/") for p in smap.cargo_scope.paths})


def cargo_hit(smap: SuiteMap, graph: CargoGraph, repo: Path, path: str) -> Optional[Hit]:
    """The Cargo graph's verdict on a path under cargo.scope: a hit with targets, one without (not linked), or None."""
    if not smap.cargo_scope or not smap.cargo_scope.matches(path):
        return None
    if not graph.available:
        cargo_products = sorted(p for p, roots in smap.cargo_roots.items() if roots)
        return Hit("cargo", f"{smap.cargo_reason} ({graph.note})",
                   tuple((p, s, None) for p in cargo_products for s in smap.products[p]))
    package = graph.package_of(repo, path, scope_dirs(smap))
    if package is None:
        return None
    inner = path[len(package) + 1:].split("/", 1)[0]
    users = graph.linked_by.get(package, ())
    if inner in smap.cargo_not_linked and "/" in path[len(package) + 1:]:
        return Hit("cargo", f"{package}/{inner}/ is not linked into a product binary", ())
    if users:
        return Hit("cargo", f"{package} is linked by {', '.join(users)}: {smap.cargo_reason}",
                   tuple((p, s, None) for p in users for s in smap.products[p]))
    return Hit("cargo", f"no product's cargo_roots link {package}", ())


def classify(smap: SuiteMap, graph: CargoGraph, repo: Path, path: str) -> PathVerdict:
    hits: List[Hit] = []
    builtin = corpus_hit(smap, path)
    if builtin is not None:
        hits.append(builtin)
    hits.extend(rule_hit(smap, rule) for rule in smap.rules if rule.paths.matches(path))
    cargo = cargo_hit(smap, graph, repo, path)
    quiet: List[Hit] = []
    if cargo is not None:
        (hits if cargo.targets else quiet).append(cargo)
    if hits:
        return PathVerdict(path, "selected", hits)
    if quiet:
        return PathVerdict(path, "ignored", quiet)
    ignored = [Hit(rule.id, rule.reason, ()) for rule in smap.ignore if rule.paths.matches(path)]
    if ignored:
        return PathVerdict(path, "ignored", ignored[:1])
    if smap.unmapped == "all":
        return PathVerdict(path, "unmapped", [Hit("unmapped", "no rule, package or ignore rule covers this path",
                                                  tuple((p, s, None) for p in sorted(smap.products) for s in smap.products[p]))])
    return PathVerdict(path, "unmapped", [Hit("unmapped", "no rule covers this path; the map's unmapped policy is none", ())])


def load_cases(corpus: Path) -> Dict[str, List[Tuple[str, frozenset, Tuple[str, ...]]]]:
    """Per suite: (case id, requires, platforms) of every case file, as oracle.py's load_corpus reads them."""
    out: Dict[str, List[Tuple[str, frozenset, Tuple[str, ...]]]] = {}
    if str(HERE) not in sys.path:
        sys.path.insert(0, str(HERE))
    import corpus_store  # noqa: E402,PLC0415 - sibling: the stored suites (tests/oracle/corpus-store.json)

    for error in corpus_store.load_errors(corpus):
        print(f"select_suites: warning: {error}", file=sys.stderr)
    if not corpus.is_dir():
        return out
    for path in sorted(corpus.rglob("*.json")):
        rel = path.relative_to(corpus)
        if path.name == "coverage.json" or path.name.startswith("_") or len(rel.parts) < 2:
            continue
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            data = {}
        data = data if isinstance(data, dict) else {}
        out.setdefault(rel.parts[0], []).append(
            (rel.with_suffix("").as_posix(), frozenset(data.get("requires") or ()), tuple(data.get("platforms") or ())))
    return out


def product_capabilities() -> Dict[str, frozenset]:
    """oracle.py's PRODUCTS (capabilities per product), read without importing its CLI."""
    if str(HERE) not in sys.path:
        sys.path.insert(0, str(HERE))
    import oracle  # noqa: E402 - sibling

    return dict(oracle.PRODUCTS)


def count_cases(cases: Mapping[str, Sequence[Tuple[str, frozenset, Tuple[str, ...]]]], caps: frozenset,
                suite: str, globs: Optional[Sequence[str]]) -> int:
    return sum(1 for cid, requires, _ in cases.get(suite, ())
               if requires <= caps and (globs is None or any(fnmatch.fnmatchcase(cid, g) for g in globs)))


def oracle_command(product: str, suites: Sequence[str], filters: Sequence[str], base: Optional[str],
                   head: Optional[str]) -> List[str]:
    command = ["python3", "-I", "scripts/cmux-next/oracle/oracle.py"]
    command += ["diff", "--base", base, "--head", head] if base and head else ["run"]
    command += ["--product", product, "--suite", ",".join(suites)]
    return command + (["--filter", ",".join(filters)] if filters else [])


def select(smap: SuiteMap, graph: CargoGraph, repo: Path, paths: Iterable[str], *,
           cases: Mapping[str, Sequence[Tuple[str, frozenset, Tuple[str, ...]]]],
           capabilities: Mapping[str, frozenset], base: Optional[str] = None, head: Optional[str] = None) -> Dict[str, Any]:
    verdicts = [classify(smap, graph, repo, p) for p in sorted(set(paths))]
    table: Dict[str, Dict[str, Dict[str, Any]]] = {}
    for verdict in verdicts:
        for hit in verdict.hits:
            for product, suite, glob in hit.targets:
                entry = table.setdefault(product, {}).setdefault(suite, {"whole": False, "cases": set(), "reasons": set()})
                if glob is None:
                    entry["whole"] = True
                else:
                    entry["cases"].add(glob)
                entry["reasons"].add((verdict.path, hit.rule))
    everything = all(table.get(p, {}).get(s, {}).get("whole") for p, suites in smap.products.items() for s in suites)
    selection: Dict[str, Dict[str, Any]] = {}
    runs: List[Dict[str, Any]] = []
    for product in sorted(table):
        caps = capabilities.get(product, frozenset())
        suites_out: Dict[str, Any] = {}
        whole, filtered, filters = [], [], []
        for suite in sorted(table[product]):
            entry = table[product][suite]
            globs = None if entry["whole"] else sorted(entry["cases"])
            suites_out[suite] = {
                "whole": entry["whole"],
                "cases": [] if entry["whole"] else globs,
                "selected": count_cases(cases, caps, suite, globs),
                "reasons": [{"path": p, "rule": r} for p, r in sorted(entry["reasons"])],
            }
            if entry["whole"]:
                whole.append(suite)
            else:
                filtered.append(suite)
                filters.extend(globs or ())
        selection[product] = suites_out
        if whole:
            runs.append({"product": product, "suites": whole, "filters": [],
                         "cases": sum(suites_out[s]["selected"] for s in whole),
                         "command": oracle_command(product, whole, [], base, head)})
        if filtered:
            runs.append({"product": product, "suites": filtered, "filters": filters,
                         "cases": sum(suites_out[s]["selected"] for s in filtered),
                         "command": oracle_command(product, filtered, filters, base, head)})
    status = STATUS_NONE if not runs else (STATUS_ALL if everything else STATUS_FOUND)
    return {
        "schema": SELECTION_SCHEMA,
        "status": status,
        "map_sha256": smap.sha256,
        "graph": {"available": graph.available, "note": graph.note},
        "counts": {k: sum(1 for v in verdicts if v.status == k) for k in ("selected", "ignored", "unmapped")},
        "paths": [{"path": v.path, "status": v.status,
                   "because": [{"rule": h.rule, "reason": h.reason,
                                "targets": sorted({f"{p}/{c or s}" for p, s, c in h.targets})} for h in v.hits]}
                  for v in verdicts],
        "selection": selection,
        "runs": runs,
    }


# ------------------------------------------------------------------------------------------------------------- git


def git(repo: Path, *args: str) -> str:
    proc = subprocess.run(["git", "-C", str(repo), *args], check=False, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, text=True)
    if proc.returncode != 0:
        raise UsageError(f"git {' '.join(args)}: {proc.stderr.strip()}")
    return proc.stdout


def resolve(repo: Path, ref: str) -> str:
    return git(repo, "rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}").strip()


def changed_paths(repo: Path, a: str, b: str) -> List[str]:
    """Both sides of a rename: a moved file leaves one path and arrives at another."""
    out = git(repo, "diff", "--name-only", "-z", "--no-renames", "--no-ext-diff", a, b)
    return sorted({p for p in out.split("\0") if p})


def range_commits(repo: Path, spec: str, first_parent: bool) -> List[Tuple[str, str, List[str]]]:
    """(sha, subject, parents) of every commit of A..B, oldest first."""
    args = ["log", "--reverse", "--format=%H%x00%P%x00%s"] + (["--first-parent"] if first_parent else []) + [spec]
    commits = []
    for line in git(repo, *args).splitlines():
        sha, parents, subject = line.split("\0", 2)
        commits.append((sha, subject, parents.split()))
    return commits


# ------------------------------------------------------------------------------------------------------------- check


def tracked_files(repo: Path) -> List[str]:
    return [p for p in git(repo, "ls-files", "-z").split("\0") if p]


def check(smap: SuiteMap, graph: CargoGraph, repo: Path, corpus: Path, cases: Mapping[str, Sequence[Any]],
          capabilities: Mapping[str, frozenset]) -> List[str]:
    """Problems of the map against the tree: unknown names, globs that match nothing, suites no product runs."""
    problems: List[str] = []
    files = tracked_files(repo)
    # A suite is a corpus directory; a generated suite may have no case yet (its coverage.json says why).
    corpus_suites = {p.name for p in corpus.iterdir() if p.is_dir()} if corpus.is_dir() else set()
    for product, suites in sorted(smap.products.items()):
        if product not in capabilities:
            problems.append(f"products.{product}: not an oracle.py product ({', '.join(sorted(capabilities))})")
        for suite in suites:
            if suite not in corpus_suites:
                problems.append(f"products.{product}: suite {suite} is not a directory of the corpus")
    for suite in sorted(corpus_suites - {s for suites in smap.products.values() for s in suites}):
        problems.append(f"suite {suite} is in the corpus but no product of the map runs it")

    def stale(where: str, globs: Sequence[str]) -> None:
        for glob in globs:
            regex = glob_regex(glob)
            if not any(regex.fullmatch(f) for f in files):
                problems.append(f"{where}: {glob!r} matches no tracked file")

    for rule in smap.rules:
        stale(f"rule {rule.id} paths", rule.paths.paths)
        stale(f"rule {rule.id} except", rule.paths.excluded)
        for product in rule.products:
            if product != "all" and product not in smap.products:
                problems.append(f"rule {rule.id}: product {product} is not in the map's products")
        known = {s for p in (smap.products if "all" in rule.products else rule.products) for s in smap.products.get(p, ())}
        for suite in rule.suites:
            if suite not in known:
                problems.append(f"rule {rule.id}: no product of the rule runs suite {suite}")
        for glob in rule.cases:
            suite = glob.split("/", 1)[0]
            if suite not in known:
                problems.append(f"rule {rule.id}: case glob {glob} names suite {suite}, which no product of the rule runs")
            elif not any(fnmatch.fnmatchcase(cid, glob) for cid, *_ in cases.get(suite, ())):
                problems.append(f"rule {rule.id}: case glob {glob} matches no case")
        if not rule_hit(smap, rule).targets:
            problems.append(f"rule {rule.id} selects no suite")
    for rule in smap.ignore:
        stale(f"ignore {rule.id} paths", rule.paths.paths)
        stale(f"ignore {rule.id} except", rule.paths.excluded)
        matched = [f for f in files if rule.paths.matches(f)]
        if graph.available and matched and all((cargo_hit(smap, graph, repo, f) or Hit("", "", ())).targets
                                               for f in matched):
            problems.append(f"ignore {rule.id}: the cargo graph selects every tracked path it matches, so it never applies")
    if smap.cargo_scope:
        stale("cargo.scope", smap.cargo_scope.paths)
    if graph.available:
        for product, roots in sorted(smap.cargo_roots.items()):
            for root in roots:
                if root not in graph.linked_by:
                    problems.append(f"products.{product}.cargo_roots: {root} has no Cargo.toml with a [package]")
        if "missing packages" in graph.note:
            problems.append(f"cargo graph: {graph.note}")
    return problems


# --------------------------------------------------------------------------------------------------------------- CLI


def read_paths(args: argparse.Namespace) -> List[str]:
    paths = list(args.paths)
    if args.paths_from:
        text = sys.stdin.read() if str(args.paths_from) == "-" else Path(args.paths_from).read_text(encoding="utf-8")
        paths += [line.strip() for line in text.splitlines() if line.strip()]
    for path in paths:
        if path.startswith(("/", "./")) or "\\" in path or ".." in path.split("/"):
            raise UsageError(f"{path!r}: changed paths are repo-relative, as git prints them")
    return paths


def print_selection(document: Mapping[str, Any], *, header: str = "select") -> None:
    counts = document["counts"]
    print(f"{header}: {document['status']} ({counts['selected']} selected, {counts['ignored']} ignored, "
          f"{counts['unmapped']} unmapped paths)")
    if not document["graph"]["available"]:
        print(f"  cargo graph: {document['graph']['note']}")
    for run in document["runs"]:
        what = f"{len(run['filters'])} case globs" if run["filters"] else "whole suites"
        print(f"  {run['product']}: {','.join(run['suites'])} ({what}, {run['cases']} cases)")
        print(f"    {' '.join(run['command'])}")
    for row in document["paths"]:
        if row["status"] != "selected":
            print(f"  {row['status']}: {row['path']} [{row['because'][0]['rule']}: {row['because'][0]['reason']}]")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="select_suites.py", description=__doc__.split("\n\n")[0])
    parser.add_argument("paths", nargs="*", help="repo-relative changed paths ('check' lints the map)")
    parser.add_argument("--paths-from", help="a file of changed paths, one per line, or - for stdin")
    parser.add_argument("--base", help="the batch base: select the paths `git diff BASE HEAD` changes")
    parser.add_argument("--head", help="the batch head")
    parser.add_argument("--range", dest="range_spec", help="A..B: one selection per commit, oldest first")
    parser.add_argument("--all-parents", action="store_true",
                        help="with --range: every commit, not only the first-parent line (the merges of a batch)")
    parser.add_argument("--map", type=Path, default=DEFAULT_MAP)
    parser.add_argument("--corpus", type=Path, default=DEFAULT_CORPUS)
    parser.add_argument("--repo", type=Path, default=REPO, help="the git checkout (default: this one)")
    parser.add_argument("--json", action="store_true")
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        smap = load_map(args.map)
        graph = load_cargo_graph(args.repo, smap.cargo_roots)
        cases = load_cases(args.corpus)
        capabilities = product_capabilities()
        if args.paths[:1] == ["check"]:
            if len(args.paths) > 1 or args.base or args.head or args.range_spec or args.paths_from:
                raise UsageError("check takes no paths")
            problems = check(smap, graph, args.repo, args.corpus, cases, capabilities)
            for problem in problems:
                print(f"suite-map: {problem}", file=sys.stderr)
            print(f"suite-map: {len(problems)} problems; {len(smap.rules)} rules, {len(smap.ignore)} ignore rules, "
                  f"{len(graph.linked_by)} linked packages ({graph.note})")
            return 1 if problems else 0
        if bool(args.base) != bool(args.head):
            raise UsageError("--base and --head go together")
        sources = sum(1 for x in (args.base, args.range_spec, args.paths or args.paths_from) if x)
        if sources != 1:
            raise UsageError("give changed paths, --paths-from, --base/--head or --range (one of them)")
        if args.range_spec:
            if ".." not in args.range_spec or "..." in args.range_spec:
                raise UsageError("--range takes A..B")
            start, end = args.range_spec.split("..", 1)
            base, head = resolve(args.repo, start), resolve(args.repo, end)
            commits = []
            union: Set[str] = set()
            for sha, subject, parents in range_commits(args.repo, f"{base}..{head}", not args.all_parents):
                paths = changed_paths(args.repo, parents[0] if parents else EMPTY_TREE, sha)
                union.update(paths)
                document = select(smap, graph, args.repo, paths, cases=cases, capabilities=capabilities,
                                  base=parents[0] if parents else None, head=sha)
                commits.append({"sha": sha, "subject": subject, **document})
            total = select(smap, graph, args.repo, union, cases=cases, capabilities=capabilities, base=base, head=head)
            result = {"schema": RANGE_SCHEMA, "base": base, "head": head, "first_parent": not args.all_parents,
                      "commits": commits, "union": total}
            if args.json:
                print(json.dumps(result, indent=1, sort_keys=True))
            else:
                for commit in commits:
                    print_selection(commit, header=f"{commit['sha'][:12]} {commit['subject'][:60]}")
                print_selection(total, header=f"union of {len(commits)} commits")
            return 0
        if args.base:
            base, head = resolve(args.repo, args.base), resolve(args.repo, args.head)
            paths = changed_paths(args.repo, base, head)
        else:
            base = head = None
            paths = read_paths(args)
        document = select(smap, graph, args.repo, paths, cases=cases, capabilities=capabilities, base=base, head=head)
        if args.json:
            print(json.dumps(document, indent=1, sort_keys=True))
        else:
            print_selection(document)
        return 0
    except UsageError as error:
        print(f"select: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
