#!/usr/bin/env python3
"""Report the CmuxNext package layering (plans/cmux-next/architecture-refactor-DESIGN.md).

Reads the target graph from `swift package dump-package` (manifest only, no build) and each
target's layer from plans/cmux-next/architecture-layers.json, then prints:

  layers       targets and Swift lines per layer
  violations   hard: a core, service or domain target that depends on a ui or app target;
               soft: a service target that depends on a domain target;
               upward: any other edge that points up (core -> service, core -> domain)
               (the classes and the map reader are scripts/cmux-next/arch_counts.py's `edge_class` and
               `LayerMap`, the ones the arch ratchet and the pre-push layer gate use)
  app          Swift lines in CmuxNextApp (the composition root's target)

This is a report for the refactor lane, not a CI gate (Lawrence 2026-10-23: no new CI gates).
The inventory of singletons, broadcasts and DEBUG-only code is PL-guardrails'
plans/cmux-next/codebase-health.md; `--counts` prints the grep counts the design doc used, except observers: those
are arch_counts.py's observer_sites (the ratchet's row; `MainActorObservation(` wrapper sites count).

Targets are the regular, executable and binary ones (arch_counts.py's MAPPED_KINDS, the same set the ratchet
and the gate read); test targets are left out.

Usage: scripts/cmux-next/arch-layers.py [--dump FILE] [--layers FILE] [--json] [--counts]
  --dump FILE    read dump-package JSON from FILE instead of running swift
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


def grep_counts() -> dict[str, int]:
    """The `--counts` numbers over the Swift under SOURCES. nc_observers is arch_counts.py's observer_sites
    (`observer_calls`, the arch ratchet's row: the `MainActorObservation(` wrapper counts, comments do not),
    never a regex of its own, so the ratchet, codebase-health.md and this report count one set."""
    counts = load_counts()
    totals = {**dict.fromkeys(COUNTS, 0), "nc_observers": 0}
    for path in SOURCES.rglob("*.swift"):
        text = path.read_text(errors="ignore")
        for name, pattern in COUNTS.items():
            totals[name] += len(pattern.findall(text))
        totals["nc_observers"] += len(counts.observer_calls(counts.strip(text)))
    return totals


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dump")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--counts", action="store_true")
    parser.add_argument("--layers", default=str(LAYERS))
    args = parser.parse_args()

    counts = load_counts()
    layer_map = counts.LayerMap.parse(Path(args.layers).read_text())
    if layer_map.error:
        print(f"{args.layers} does not parse: {layer_map.error}", file=sys.stderr)
        return 2
    graph = load_graph(args.dump, {counts.DUMP_TYPES[kind] for kind in counts.MAPPED_KINDS})

    unplaced = sorted(name for name in graph if layer_map.placed(name) is None)
    found: dict[str, list[tuple[str, str, str, str]]] = {kind: [] for kind in counts.EDGE_CLASSES}
    for source, deps in sorted(graph.items()):
        for dep in dict.fromkeys(deps):
            kind = layer_map.classify(source, dep)
            if kind is not None:
                found[kind].append((source, layer_map.placed(source), dep, layer_map.placed(dep)))
    hard, soft, upward = found["hard"], found["soft"], found["upward"]

    per_layer: dict[str, list[int]] = {name: [0, 0] for name in layer_map.order}
    for name in graph:
        layer = layer_map.placed(name)
        if layer is None:
            continue
        per_layer[layer][0] += 1
        per_layer[layer][1] += swift_lines(SOURCES / name)

    report = {
        "targets": len(graph),
        "unplaced": unplaced,
        "app_lines": swift_lines(SOURCES / "CmuxNextApp"),
        "hard_violations": len(hard),
        "soft_violations": len(soft),
        "upward_violations": len(upward),
        "layers": {name: {"targets": t, "lines": n} for name, (t, n) in per_layer.items()},
    }
    if args.counts:
        report["counts"] = grep_counts()
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
    if args.counts:
        print("counts: " + ", ".join(f"{k} {v}" for k, v in report["counts"].items()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
