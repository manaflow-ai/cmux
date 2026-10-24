#!/usr/bin/env python3
"""Report the CmuxNext package layering (plans/cmux-next/architecture-refactor-DESIGN.md).

Reads CmuxNext's target graph from `swift package dump-package` (manifest only, no build), adds the targets and
edges of its local package closure (arch_counts.py's read_paths and closure_manifest, the arch ratchet's scope since
method v5: every package CmuxNext links by `.package(path:)`, directly or through another one, and a `.product` of
one as an edge to that product's targets), and reads each target's layer from
plans/cmux-next/architecture-layers.json, then prints:

  layers       targets and Swift lines per layer
  violations   hard: a core, service or domain target that depends on a ui or app target;
               soft: a service target that depends on a domain target;
               upward: any other edge that points up (core -> service, core -> domain)
               (the classes and the map reader are scripts/cmux-next/arch_counts.py's `edge_class` and
               `LayerMap`, the ones the arch ratchet and the pre-push layer gate use)
  impure core  a target labeled core whose Swift holds runtime state or I/O (a shared instance,
               stored static state, a lock, file or defaults I/O, a notification observation,
               observable state), with the first file:line of each kind. The label is what the
               target holds (the _doc rule), so such a target is labeled at its highest layer
               with `mixes`, or the state moves out (72673e48762 labeled DesignTokens core by its
               imports alone, and the report dropped an edge that had not changed).
  app          Swift lines in CmuxNextApp (the composition root's target)

The closure comes from the git objects at HEAD of --repo (default this checkout) and its manifests and Swift from
that working tree. With --dump and no --repo the dump is the whole graph (a dump describes one package).

This is a report for the refactor lane, not a CI gate (Lawrence 2026-10-23: no new CI gates).
The inventory of singletons, broadcasts and DEBUG-only code is PL-guardrails'
plans/cmux-next/codebase-health.md; `--counts` prints the grep counts the design doc used, except observers: those
are arch_counts.py's observer_sites (the ratchet's row: registrations counted through wrappers such as
`MainActorObservation(`, at each use a caller configures).

Targets are the regular, executable and binary ones (arch_counts.py's MAPPED_KINDS, the same set the ratchet
and the gate read); test targets are left out.

Usage: scripts/cmux-next/arch-layers.py [--dump FILE] [--repo DIR] [--layers FILE] [--json] [--counts]
  --dump FILE    read dump-package JSON from FILE instead of running swift
  --repo DIR     the checkout whose local package closure is added (default this one; with --dump, none)
  --layers FILE  read the layer map from FILE instead of plans/cmux-next/architecture-layers.json
  --json         print one JSON object (for before/after rows in commit messages)
  --counts       add the grep counts (static shared, MainActor.assumeIsolated, observers, #if DEBUG)
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PACKAGE = ROOT / "Packages/macOS/CmuxNext"
SOURCES = PACKAGE / "Sources"
LAYERS = ROOT / "plans/cmux-next/architecture-layers.json"


def load_counts():
    """scripts/cmux-next/arch_counts.py, next to this file (standard library only)."""
    spec = importlib.util.spec_from_file_location("cmux_next_arch_counts", Path(__file__).resolve().parent / "arch_counts.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module  # dataclasses resolve their module through sys.modules
    spec.loader.exec_module(module)
    return module


def load_graph(dump: str | None, mapped_types: set[str]) -> dict[str, list[str]]:
    """Target -> dependency names for the dump's targets whose `type` is in MAPPED_TYPES."""
    if dump:
        data = json.loads(Path(dump).read_text())
    else:
        out = subprocess.run(["swift", "package", "dump-package"], cwd=PACKAGE, check=True,
                             capture_output=True, text=True).stdout
        data = json.loads(out)
    graph: dict[str, list[str]] = {}
    for target in data["targets"]:
        if target["type"] not in mapped_types:
            continue
        deps = []
        for dep in target.get("dependencies", []):
            for key in ("byName", "target"):
                if key in dep:
                    deps.append(dep[key][0])
        graph[target["name"]] = deps
    return graph


def swift_lines(path: Path) -> int:
    return sum(p.read_text(errors="ignore").count("\n") for p in path.rglob("*.swift"))


COUNTS = {
    "static_shared": re.compile(r"static\s+(?:let|var)\s+shared\b"),
    "assume_isolated": re.compile(r"MainActor\.assumeIsolated"),
    "if_debug": re.compile(r"^\s*#if\s+DEBUG\b", re.M),
}


# What a core target may not hold (architecture-refactor-DESIGN.md section 2: Sendable values, IDs, protocol seams,
# pure rules). Matched on code with comments and string contents blanked. AppKit imports are allowed in core
# for platform value types, so imports are not evidence.
IMPURE = (
    ("shared instance", re.compile(r"\bstatic\s+(?:let|var)\s+shared\b")),
    # A `@TaskLocal` static is scoped to a task, not process-wide.
    ("stored static state", re.compile(r"^(?!.*@TaskLocal\b).*\bstatic\s+var\s+\w+\s*(?::[^={]*)?(?:=|$)")),
    ("lock", re.compile(r"\b(?:OSAllocatedUnfairLock|NSLock|NSRecursiveLock|Mutex)\s*(?:<[^()]*>)?\s*\(|\bos_unfair_lock\b"
                        r"|\bpthread_mutex_t\b")),
    ("file or defaults I/O", re.compile(r"\b(?:FileManager|FileHandle|UserDefaults|URLSession)\b|\bData\(contentsOf:"
                                        r"|\bProcess\(\)")),
    ("notification observation", re.compile(r"\b(?:Distributed)?NotificationCenter\b")),
    ("observable state", re.compile(r"@Observable\b|\bObservableObject\b")),
)
# A class or actor's `static let system`/`standard`/`current`/`live`/`default` is a shared instance by another name;
# a struct or enum's is a value constant (CLAUDE.md "No shared-singleton accessors").
NAMED_INSTANCE = re.compile(r"\bstatic\s+let\s+(?:system|standard|current|live|`default`)\b")
TYPE_OPENER = re.compile(r"\b(class|actor|struct|enum|extension|protocol)\b[^{]*$")


def code_lines(text: str) -> list[str]:
    """TEXT's lines with comments removed and string contents blanked (line count kept)."""
    out, line, i, n = [], [], 0, len(text)
    block = in_string = False
    while i < n:
        c = text[i]
        if c == "\n":
            out.append("".join(line))
            line = []
            in_string = False  # a single-line literal never spans lines; a multi-line one is blanked line by line
        elif block:
            if text.startswith("*/", i):
                block = False
                i += 1
        elif in_string:
            if c == "\\":
                i += 1
            elif c == '"':
                in_string = False
                line.append(c)
        elif text.startswith("//", i):
            j = text.find("\n", i)
            i = (n if j < 0 else j) - 1
        elif text.startswith("/*", i):
            block = True
            i += 1
        elif c == '"':
            in_string = True
            line.append(c)
        else:
            line.append(c)
        i += 1
    out.append("".join(line))
    return out


def impurities(target: Path) -> dict[str, str]:
    """{kind: first file:line} of the runtime state and I/O in TARGET's Swift files (path order)."""
    found: dict[str, str] = {}
    for path in sorted(target.rglob("*.swift")):
        kinds: list[str] = []  # the type kind of each open brace
        for number, code in enumerate(code_lines(path.read_text(errors="ignore")), 1):
            where = f"{path.relative_to(target)}:{number}"
            for kind, pattern in IMPURE:
                if kind not in found and pattern.search(code):
                    found[kind] = where
            if "shared instance" not in found and NAMED_INSTANCE.search(code) and kinds and kinds[-1] in ("class", "actor"):
                found["shared instance"] = where
            for at, c in enumerate(code):
                if c == "{":
                    opener = TYPE_OPENER.search(code[:at])
                    kinds.append(opener.group(1) if opener else "")
                elif c == "}" and kinds:
                    kinds.pop()
    return found


def grep_counts(closure=None) -> dict[str, int]:
    """The `--counts` numbers over the Swift under SOURCES, and under every Sources of CLOSURE (a Closure) when
    given. nc_observers is arch_counts.py's observer_sites (`observer_registrations`, the arch ratchet's row:
    registrations through wrappers such as `MainActorObservation(` count at each use, comments do not), never a regex
    of its own, so the ratchet, codebase-health.md and this report count one set."""
    counts = load_counts()
    totals = {**dict.fromkeys(COUNTS, 0), "nc_observers": 0}
    texts: dict[str, str] = {}
    roots = [(closure.repo / d, d) for d in closure.scope.sources] if closure else [(SOURCES, counts.SOURCES)]
    for root, prefix in roots:
        for path in root.rglob("*.swift"):
            text = path.read_text(errors="ignore")
            for name, pattern in COUNTS.items():
                totals[name] += len(pattern.findall(text))
            # Keyed like the repository path, so a file's Swift module (its package directory) is the same.
            texts[f"{prefix}/{path.relative_to(root).as_posix()}"] = text
    totals["nc_observers"] = counts.observer_registrations(texts, closure.scope if closure else None).total()
    return totals


class Closure:
    """CmuxNext's local package closure in the checkout REPO: SCOPE (arch_counts.read_paths at HEAD) and MANIFEST
    (closure_manifest of the working tree's manifests: every target, with the edges `.product` dependencies make)."""

    def __init__(self, counts, repo: Path) -> None:
        self.repo = repo
        self.scope = counts.read_paths(repo, "HEAD")
        texts = {}
        for path in self.scope.manifests:
            try:
                texts[path] = (repo / path).read_text()
            except OSError:
                texts[path] = None
        self.manifest = counts.closure_manifest(texts)

    def add_to(self, counts, graph: dict[str, list[str]]) -> None:
        """Every MAPPED_KINDS target of the other closure packages into GRAPH, and the closure's edges of every
        target (CmuxNext's `.product` edges to a local package)."""
        for name, target in self.manifest.targets.items():
            if target.kind not in counts.MAPPED_KINDS:
                continue
            if name in graph or target.manifest != counts.MANIFEST:
                graph[name] = list(dict.fromkeys(graph.get(name, []) + sorted(target.deps)))

    def source_dir(self, name: str) -> Path | None:
        """NAME's sources in REPO, None for a target the closure does not declare."""
        return self.repo / self.manifest.source_dir(name) if name in self.manifest.targets else None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dump")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--counts", action="store_true")
    parser.add_argument("--layers", default=str(LAYERS))
    parser.add_argument("--repo")
    args = parser.parse_args()

    counts = load_counts()
    layer_map = counts.LayerMap.parse(Path(args.layers).read_text())
    if layer_map.error:
        print(f"{args.layers} does not parse: {layer_map.error}", file=sys.stderr)
        return 2
    graph = load_graph(args.dump, {counts.DUMP_TYPES[kind] for kind in counts.MAPPED_KINDS})
    repo = Path(args.repo).resolve() if args.repo else (None if args.dump else ROOT)
    closure = Closure(counts, repo) if repo is not None else None
    if closure is not None:
        closure.add_to(counts, graph)

    def sources_of(name: str) -> Path:
        found = closure.source_dir(name) if closure is not None else None
        return found if found is not None else SOURCES / name

    unplaced = sorted(name for name in graph if layer_map.placed(name) is None)
    found: dict[str, list[tuple[str, str, str, str]]] = {kind: [] for kind in counts.EDGE_CLASSES}
    for source, deps in sorted(graph.items()):
        for dep in dict.fromkeys(deps):
            kind = layer_map.classify(source, dep)
            if kind is not None:
                found[kind].append((source, layer_map.placed(source), dep, layer_map.placed(dep)))
    hard, soft, upward = found["hard"], found["soft"], found["upward"]

    impure = {}
    for name in sorted(graph):
        if layer_map.placed(name) == "core":
            found_here = impurities(sources_of(name))
            if found_here:
                impure[name] = found_here

    per_layer: dict[str, list[int]] = {name: [0, 0] for name in layer_map.order}
    for name in graph:
        layer = layer_map.placed(name)
        if layer is None:
            continue
        per_layer[layer][0] += 1
        per_layer[layer][1] += swift_lines(sources_of(name))

    report = {
        "targets": len(graph),
        "unplaced": unplaced,
        "app_lines": swift_lines(SOURCES / "CmuxNextApp"),
        "hard_violations": len(hard),
        "soft_violations": len(soft),
        "upward_violations": len(upward),
        "layers": {name: {"targets": t, "lines": n} for name, (t, n) in per_layer.items()},
        "impure_core": impure,
    }
    if args.counts:
        report["counts"] = grep_counts(closure)
    if args.json:
        print(json.dumps(report, sort_keys=True))
        return 0
    print(f"targets {report['targets']}, CmuxNextApp {report['app_lines']} lines")
    for name, row in report["layers"].items():
        print(f"  {name:8} {row['targets']:3} targets {row['lines']:7} lines")
    if unplaced:
        print("unplaced (add to architecture-layers.json): " + ", ".join(unplaced))
    print(f"hard violations {len(hard)} (lower layer -> ui/app):")
    for source, a, dep, b in hard:
        print(f"  {source} ({a}) -> {dep} ({b})")
    print(f"soft violations {len(soft)} (service -> domain):")
    for source, a, dep, b in soft:
        print(f"  {source} -> {dep}")
    print(f"upward violations {len(upward)} (core -> service/domain; edges only point down):")
    for source, a, dep, b in upward:
        print(f"  {source} ({a}) -> {dep} ({b})")
    if impure:
        print(f"core targets that hold state or I/O {len(impure)} (label each at its highest layer with mixes, "
              "or move the state out):")
        for name, found in impure.items():
            print(f"  {name}: " + ", ".join(f"{kind} {where}" for kind, where in found.items()))
    if args.counts:
        print("counts: " + ", ".join(f"{k} {v}" for k, v in report["counts"].items()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
