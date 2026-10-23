#!/usr/bin/env python3
"""Report the CmuxNext package layering (plans/cmux-next/architecture-refactor-DESIGN.md).

Reads the target graph from `swift package dump-package` (manifest only, no build) and each
target's layer from plans/cmux-next/architecture-layers.json, then prints:

  layers       targets and Swift lines per layer
  violations   hard: a core, service or domain target that depends on a ui or app target;
               soft: a service target that depends on a domain target
  app          Swift lines in CmuxNextApp (the composition root's target)

This is a report for the refactor lane, not a CI gate (Lawrence 2026-10-23: no new CI gates).
The inventory of singletons, broadcasts and DEBUG-only code is PL-guardrails'
plans/cmux-next/codebase-health.md; `--counts` prints the same grep counts the design doc used.

Usage: scripts/cmux-next/arch-layers.py [--dump FILE] [--json] [--counts]
  --dump FILE  read dump-package JSON from FILE instead of running swift
  --json       print one JSON object (for before/after rows in commit messages)
  --counts     add the grep counts (static shared, MainActor.assumeIsolated, observers, #if DEBUG)
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PACKAGE = ROOT / "Packages/macOS/CmuxNext"
SOURCES = PACKAGE / "Sources"
LAYERS = ROOT / "plans/cmux-next/architecture-layers.json"


def load_graph(dump: str | None) -> dict[str, list[str]]:
    if dump:
        data = json.loads(Path(dump).read_text())
    else:
        out = subprocess.run(["swift", "package", "dump-package"], cwd=PACKAGE, check=True,
                             capture_output=True, text=True).stdout
        data = json.loads(out)
    graph: dict[str, list[str]] = {}
    for target in data["targets"]:
        if target["type"] not in ("regular", "binary"):
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
    "nc_observers": re.compile(r"addObserver\s*\(|\.notifications\s*\(\s*named\s*:|\.publisher\s*\(\s*for\s*:"),
    "if_debug": re.compile(r"^\s*#if\s+DEBUG\b", re.M),
}


def grep_counts() -> dict[str, int]:
    totals = dict.fromkeys(COUNTS, 0)
    for path in SOURCES.rglob("*.swift"):
        text = path.read_text(errors="ignore")
        for name, pattern in COUNTS.items():
            totals[name] += len(pattern.findall(text))
    return totals


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dump")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--counts", action="store_true")
    args = parser.parse_args()

    spec = json.loads(LAYERS.read_text())
    order = {name: index for index, name in enumerate(spec["order"])}
    layers = {name: entry["layer"] for name, entry in spec["targets"].items()}
    graph = load_graph(args.dump)

    unplaced = sorted(set(graph) - set(layers))
    hard, soft = [], []
    for source, deps in sorted(graph.items()):
        if source not in layers:
            continue
        for dep in deps:
            if dep not in layers:
                continue
            a, b = layers[source], layers[dep]
            if order[b] > order[a] and b in ("ui", "app"):
                hard.append((source, a, dep, b))
            elif a == "service" and b == "domain":
                soft.append((source, a, dep, b))

    per_layer: dict[str, list[int]] = {name: [0, 0] for name in spec["order"]}
    for name, layer in layers.items():
        if name not in graph:
            continue
        per_layer[layer][0] += 1
        per_layer[layer][1] += swift_lines(SOURCES / name)

    report = {
        "targets": len(graph),
        "unplaced": unplaced,
        "app_lines": swift_lines(SOURCES / "CmuxNextApp"),
        "hard_violations": len(hard),
        "soft_violations": len(soft),
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
    if args.counts:
        print("counts: " + ", ".join(f"{k} {v}" for k, v in report["counts"].items()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
