#!/usr/bin/env python3
"""Time the macOS dev loop (scripts/reload.sh) after typical edits, on an already built DerivedData.

Each scenario applies one edit on top of the previous ones, reruns reload.sh with Swift incremental
diagnostics on, and records the wall time, xcodebuild's per-phase timing summary, how many Swift files the
driver compiled, and whether the app module was re-emitted. Nothing is reverted between scenarios: each
build measures only its own delta.

Usage: app-edit-loop-benchmark.py --tag TAG --derived-data DIR [--out results.json]
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HOT_VIEW = ROOT / "Sources/Cloud/CloudTreeOutlineView.swift"
HOT_TYPE = ROOT / "Sources/Surfaces/SurfaceCatalog.swift"
PACKAGE_FILE = ROOT / "Packages/macOS/CmuxCloud/Sources/CmuxCloud/Display/CloudDisplayCoordinator.swift"


def append(path: Path, text: str) -> None:
    with path.open("a", encoding="utf-8") as handle:
        handle.write(text)


def replace_once(path: Path, old: str, new: str) -> None:
    body = path.read_text(encoding="utf-8")
    if old not in body:
        raise SystemExit(f"benchmark anchor not found in {path.relative_to(ROOT)}: {old!r}")
    path.write_text(body.replace(old, new, 1), encoding="utf-8")


def insert_after_line(path: Path, pattern: str, text: str) -> None:
    lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
    rx = re.compile(pattern)
    for index, line in enumerate(lines):
        if rx.search(line):
            lines.insert(index + 1, text)
            path.write_text("".join(lines), encoding="utf-8")
            return
    raise SystemExit(f"benchmark anchor not found in {path.relative_to(ROOT)}: {pattern!r}")


def toggle_body_literal() -> None:
    plain = 'defaultValue: "New Workspace")) { [nodeActions] in nodeActions.newWorkspace(machine) }'
    spaced = 'defaultValue: "New Workspace ")) { [nodeActions] in nodeActions.newWorkspace(machine) }'
    body = HOT_VIEW.read_text(encoding="utf-8")
    old, new = (plain, spaced) if plain in body else (spaced, plain)
    replace_once(HOT_VIEW, old, new)


# (name, what it models, edit taking the pass number so repeated passes never redeclare a name)
SCENARIOS = [
    ("noop", "rebuild with nothing changed: the fixed floor", lambda n: None),
    ("comment", "comment edit in a hot app view (CloudTreeOutlineView)",
     lambda n: append(HOT_VIEW, f"\n// edit-loop benchmark: comment edit {n}\n")),
    ("body", "string literal change inside a function body of the same view", lambda n: toggle_body_literal()),
    ("top_level_private", "new fileprivate top-level func in the view",
     lambda n: append(HOT_VIEW, f"\nfileprivate func editLoopBenchmarkPrivateProbe{n}() {{}}\n")),
    ("top_level_internal", "new internal top-level struct in the view (what adding a small type does)",
     lambda n: append(HOT_VIEW, f"\nstruct EditLoopBenchmarkInternalProbe{n} {{}}\n")),
    ("member_hot_type", "new internal method on SurfaceCatalog (a widely used app type)",
     lambda n: insert_after_line(HOT_TYPE, r"^final class SurfaceCatalog\b.*\{\s*$",
                                 f"    func editLoopBenchmarkMemberProbe{n}() {{}}\n")),
    ("package_body", "body-level comment edit in a CmuxCloud package file the app imports",
     lambda n: append(PACKAGE_FILE, f"\n// edit-loop benchmark: package comment edit {n}\n")),
]

# Variants rerun every scenario with different reload.sh settings. The first build of a variant
# ("prime") absorbs the flag change and is reported separately.
VARIANTS = {
    "base": {},
    "no_app_module": {"CMUX_RELOAD_APP_EMIT_MODULE": "0"},
}

TIMING_RE = re.compile(r"^(?P<phase>[A-Za-z][A-Za-z0-9 ]+?) \((?P<tasks>\d+) tasks?\) \| (?P<secs>[\d.]+) seconds")
COMPILE_RE = re.compile(r"^SwiftCompile normal \S+ .*?(?P<file>[^/\s]+\.swift)\b")
EMIT_RE = re.compile(r"^SwiftEmitModule normal \S+ ")
TARGET_RE = re.compile(r"\(in target '(?P<target>[^']+)'")


def parse_log(log: str) -> dict:
    phases: dict[str, float] = {}
    compiled: list[str] = []
    by_target: dict[str, int] = {}
    emitted: list[str] = []
    in_summary = False
    for raw in log.splitlines():
        line = raw.strip()
        if line.startswith("Build Timing Summary"):
            in_summary = True
            continue
        if in_summary:
            match = TIMING_RE.match(line)
            if match:
                phases[match["phase"]] = phases.get(match["phase"], 0.0) + float(match["secs"])
                continue
            if line.startswith("**"):
                in_summary = False
        target = TARGET_RE.search(line)
        match = COMPILE_RE.match(line)
        if match:
            compiled.append(match["file"])
            key = target["target"] if target else "?"
            by_target[key] = by_target.get(key, 0) + 1
            continue
        if EMIT_RE.match(line):
            emitted.append(target["target"] if target else "?")
    return {
        "phases": dict(sorted(phases.items(), key=lambda kv: -kv[1])),
        "swift_files_compiled": len(compiled),
        "swift_files_by_target": dict(sorted(by_target.items(), key=lambda kv: -kv[1])),
        "compiled_sample": compiled[:8],
        "modules_emitted": sorted(set(emitted)),
    }


def run_reload(tag: str, derived: str, log_path: Path, extra_env: dict[str, str]) -> tuple[float, int]:
    env = dict(os.environ, CMUX_SWIFT_INCREMENTAL_DIAGNOSTICS="1", **extra_env)
    started = time.monotonic()
    proc = subprocess.run(["./scripts/reload.sh", "--tag", tag, "--derived-data", derived,
                           "--swift-frontend-workaround"], cwd=ROOT, env=env, text=True,
                          capture_output=True, check=False)
    seconds = time.monotonic() - started
    if proc.returncode != 0:
        sys.stderr.write(proc.stdout[-4000:] + proc.stderr[-4000:])
        if log_path.exists():
            sys.stderr.write(log_path.read_text(errors="replace")[-8000:])
    return seconds, proc.returncode


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--tag", required=True)
    parser.add_argument("--derived-data", required=True)
    parser.add_argument("--out", default="edit-loop-results.json")
    parser.add_argument("--only", help="comma-separated scenario names")
    parser.add_argument("--variants", default="base,no_app_module", help=f"comma-separated, from {sorted(VARIANTS)}")
    args = parser.parse_args()
    slug = re.sub(r"[^a-z0-9]+", "-", args.tag.lower()).strip("-")
    log_path = Path(f"/tmp/cmux-reload-{slug}.log")
    wanted = set(args.only.split(",")) if args.only else None
    variants = args.variants.split(",")
    results = []
    failed = False
    for n, variant in enumerate(variants):
        extra_env = VARIANTS[variant]
        steps = [("prime", "first build with this variant's settings", lambda n: None)] if n else []
        for name, what, edit in steps + SCENARIOS:
            if wanted and name not in wanted and name != "prime":
                continue
            edit(n)
            seconds, code = run_reload(args.tag, args.derived_data, log_path, extra_env)
            log = log_path.read_text(errors="replace") if log_path.exists() else ""
            record = {"variant": variant, "scenario": name, "models": what, "seconds": round(seconds, 1),
                      "exit": code, **parse_log(log)}
            (Path(args.out).parent / f"reload-{variant}-{name}.log").write_text(log)
            results.append(record)
            print(json.dumps(record), flush=True)
            if code != 0:
                failed = True
                break
        if failed:
            break
    Path(args.out).write_text(json.dumps(results, indent=2) + "\n")
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write("### App edit loop (reload.sh, incremental)\n\n")
            handle.write("| variant | scenario | wall s | Swift files | modules emitted | top phases |\n"
                         "| --- | --- | --- | --- | --- | --- |\n")
            for r in results:
                top = ", ".join(f"{k} {v:.1f}s" for k, v in list(r["phases"].items())[:4])
                handle.write(f"| {r['variant']} | {r['scenario']} | {r['seconds']} | {r['swift_files_compiled']} | "
                             f"{', '.join(r['modules_emitted']) or '-'} | {top} |\n")
    return 0 if all(r["exit"] == 0 for r in results) else 1


if __name__ == "__main__":
    sys.exit(main())
