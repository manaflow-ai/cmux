#!/usr/bin/env python3
"""Where an Xcode build's time went, task by task, from its result bundle.

-showBuildTimingSummary gives each task kind's summed seconds; it cannot say which
single task held the build up, or how many Swift compiles were cache replays. The
result bundle's build log (`xcrun xcresulttool get log --type build`) holds every
task with its own start and duration. This prints, for the job log:

- the time per kind of task (Swift compile split into cache replays, real
  compiles and unknown, emit-module, link, script phases, Swift library copy,
  signing, assets and plists, package resolution and planning, C compiles, other),
  as task count, summed seconds and the longest one;
- the build's wall span (first task start to last task end);
- the 15 slowest single tasks with their kind and target.

It writes the same as JSON with --json. Advisory only: any failure prints a note
and exits 0, so it never changes a build's verdict.

Usage: xcode_build_timeline.py (--xcresult PATH | --log-json PATH) [--json OUT] [--top N]
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from collections.abc import Iterator, Mapping
from pathlib import Path
from typing import Any

# (kind, pattern over the task's title and command signature), first match wins.
KINDS = (
    ("swift-emit-module", r"\bEmit(?:ting)?\s*module\b|SwiftEmitModule|\bMerg(?:e|ing) swiftmodule|SwiftMergeGeneratedHeaders"),
    ("swift-compile", r"\bSwiftCompile\b|\bCompil(?:e|ing)\b[^\n]*\.swift\b|\bCompileSwift"),
    ("link", r"^(?:Link(?:ing)?|Ld)\b|\bLd\s"),
    ("script-phase", r"PhaseScriptExecution|\bRun(?:ning)? (?:custom )?shell script|^Run script"),
    ("copy-swift-libs", r"CopySwiftLibs|Copy(?:ing)? Swift standard librar"),
    ("codesign", r"^(?:Sign|CodeSign)\b|\bCodeSign\b"),
    ("assets-plists", r"CompileAssetCatalog|asset catalog|ProcessInfoPlistFile|Info\.plist|CompileStoryboard|CompileXIB|"
                      r"CopyStringsFile|CompileXCStrings|\.xcstrings|ProcessProductPackaging|CopyPlistFile"),
    ("package-planning", r"Resolve Package|package graph|Prepar(?:e|ing) (?:packages|build)|Plan(?:ning)? build|"
                         r"Create(?:ing)? build description|Compute(?:ing)? (?:target )?dependenc|ComputePackagePrebuildTargetDependencyGraph|"
                         r"Build description|CreateBuildDirectory|WriteAuxiliaryFile|ScanDependencies"),
    ("c-compile", r"\bCompileC\b|\bCompil(?:e|ing)\b[^\n]*\.(?:c|m|mm|cpp|cc)\b|PrecompileModule|\bClang\b"),
)
KIND_RES = tuple((kind, re.compile(pattern, re.IGNORECASE | re.MULTILINE)) for kind, pattern in KINDS)
# Xcode's compilation-cache remarks (build_metrics.py reads the same ones from the text log).
HIT = re.compile(r"cache hit|replay(?:ed|ing)? (?:from )?(?:the )?cache|cache key query hit|local cache found for key",
                 re.IGNORECASE)
MISS = re.compile(r"cache miss|cache key query miss|\bmiss(?:ed|es)?\b[^\n]*\bcache\b", re.IGNORECASE)
TOP = 15


def kind_of(section: Mapping[str, Any]) -> str:
    details = section.get("commandInvocationDetails") or {}
    text = f"{section.get('title') or ''}\n{details.get('commandDetails') or ''}"[:4000]
    for kind, pattern in KIND_RES:
        if pattern.search(text):
            return kind
    return "other"


def cache_outcome(section: Mapping[str, Any]) -> str:
    """hit / miss / unknown, from the task's messages (Xcode's cache remarks)."""
    details = section.get("commandInvocationDetails") or {}
    texts = [str(message.get("title") or "") for message in section.get("messages") or [] if isinstance(message, Mapping)]
    texts.append(str(details.get("emittedOutput") or "")[:4000])
    joined = "\n".join(texts)
    if MISS.search(joined):
        return "miss"
    if HIT.search(joined):
        return "hit"
    return "unknown"


def tasks(section: Mapping[str, Any], target: str = "", depth: int = 0) -> Iterator[dict[str, Any]]:
    """The leaf sections (tasks) under section, each with the nearest target title above it."""
    children = [child for child in section.get("subsections") or [] if isinstance(child, Mapping)]
    title = str(section.get("title") or "")
    if not children:
        if depth == 0:
            return
        kind = kind_of(section)
        yield {"title": title[:200], "target": target, "kind": kind,
               "seconds": round(float(section.get("duration") or 0.0), 3),
               "start": section.get("startTime"),
               "cache": cache_outcome(section) if kind == "swift-compile" else ""}
        return
    # A target section's title names the target ("Build target cmux", or the target alone).
    if depth == 1 or str(section.get("domainType") or "").endswith("TargetSection") or section.get("productType"):
        target = re.sub(r"^(?:Build|Building|Check dependencies for|Compile) target\s+", "", title).split(" of project")[0] or target
    for child in children:
        yield from tasks(child, target, depth + 1)


def summarize(log: Mapping[str, Any], top: int = TOP) -> dict[str, Any]:
    found = list(tasks(log))
    kinds: dict[str, dict[str, Any]] = {}
    for task in found:
        name = task["kind"]
        if name == "swift-compile":
            name = {"hit": "swift-compile (cache replay)", "miss": "swift-compile (real)"}.get(task["cache"], "swift-compile (unknown)")
        row = kinds.setdefault(name, {"tasks": 0, "seconds": 0.0, "longest": 0.0})
        row["tasks"] += 1
        row["seconds"] = round(row["seconds"] + task["seconds"], 3)
        row["longest"] = max(row["longest"], task["seconds"])
    spans = [(float(task["start"]), float(task["start"]) + task["seconds"]) for task in found
             if isinstance(task["start"], (int, float))]
    wall = round(max(end for _, end in spans) - min(start for start, _ in spans), 3) if spans else None
    return {"build_seconds": round(float(log.get("duration") or 0.0), 3), "task_wall_seconds": wall,
            "tasks": len(found), "kinds": dict(sorted(kinds.items(), key=lambda item: -item[1]["seconds"])),
            "slowest": sorted(found, key=lambda task: -task["seconds"])[:top]}


def report(summary: Mapping[str, Any], stream=sys.stdout) -> None:
    print(f"Build timeline: {summary['tasks']} tasks, build {summary['build_seconds']}s, "
          f"first task start to last task end {summary['task_wall_seconds']}s", file=stream)
    print(f"  {'kind':<30} {'tasks':>6} {'summed s':>10} {'longest s':>10}", file=stream)
    for name, row in summary["kinds"].items():
        print(f"  {name:<30} {row['tasks']:>6} {row['seconds']:>10.1f} {row['longest']:>10.1f}", file=stream)
    print(f"Slowest {len(summary['slowest'])} tasks:", file=stream)
    for task in summary["slowest"]:
        cache = f" [{task['cache']}]" if task["cache"] else ""
        print(f"  {task['seconds']:>8.1f}s  {task['kind']}{cache}  {task['target'] or '-'}: {task['title']}", file=stream)


def read_log(args: argparse.Namespace) -> Mapping[str, Any]:
    if args.log_json:
        return json.loads(Path(args.log_json).read_text(encoding="utf-8"))
    out = subprocess.run(["xcrun", "xcresulttool", "get", "log", "--type", "build", "--compact", "--path", args.xcresult],
                         capture_output=True, text=True, timeout=120, check=True).stdout
    return json.loads(out)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--xcresult")
    source.add_argument("--log-json")
    parser.add_argument("--json")
    parser.add_argument("--top", type=int, default=TOP)
    args = parser.parse_args(argv)
    try:
        summary = summarize(read_log(args), args.top)
        report(summary)
        if args.json:
            Path(args.json).parent.mkdir(parents=True, exist_ok=True)
            Path(args.json).write_text(json.dumps(summary, indent=1) + "\n", encoding="utf-8")
    except Exception as error:  # noqa: BLE001 - advisory: never fail the build over its timeline
        print(f"xcode_build_timeline: no timeline ({type(error).__name__}: {error})", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
