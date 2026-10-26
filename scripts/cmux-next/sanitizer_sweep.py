#!/usr/bin/env python3
"""The Swift sanitizer sweep behind scripts/cmux-next/sanitizer-sweep.sh (p10-stability-013).

It runs every test target of CmuxNext and of the packages CmuxNext reaches through
`.package(path:)` (the mac closure) under each requested mode, and counts only real
sanitizer findings:

1. Enumerate: `swift package dump-package` from Packages/macOS/CmuxNext, following path
   dependencies under Packages/. Remote packages (Sentry, Sparkle, swift-atomics) have no
   tests here.
2. Base pass: every target runs once with no sanitizer. A target that is red here is
   base-red: it is listed, goes to its own fix queue and is not counted. This is the
   "without patch" retry of Chromium's test recipes
   (recipes/recipe_modules/chromium_tests/api.py): a test red without the change does not
   blame the change.
3. Each mode runs scripts/ci/package-test-lane.sh `suite` per package with the base-green
   targets: thread, address, undefined (CMUX_SWIFT_SANITIZE) and coop-strict
   (LIBDISPATCH_COOPERATIVE_POOL_STRICT=1).
4. Each sanitizer report in a suite's output goes through crash_signature.py
   (p10-stability-002). Only signatures of the mode's kind count (tsan, asan, ubsan); under
   coop-strict a base-green target that hangs counts. A suite that goes red with no report
   (a sanitizer slowdown, for example) is listed and not counted.

Exit status: 0 no finding, 1 at least one counted finding, 2 usage or refused (not a fleet
host, bad suppressions, HEAD is not --ref), 3 no verdict (a package did not build under a
mode, or a report crash_signature.py did not classify).
"""

from __future__ import annotations

import argparse
import dataclasses
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Callable, Iterable, Optional

ROOT_PACKAGE = "Packages/macOS/CmuxNext"
LANE = "scripts/ci/package-test-lane.sh"
SIGNATURE_TOOL = "scripts/cmux-next/crash_signature.py"
SUPPRESSIONS = "scripts/cmux-next/tsan-suppressions.txt"
MAX_SUPPRESSIONS = 10
# Suppressions are for third-party code only (Chromium's rule in
# build/sanitizers/tsan_suppressions.cc: each entry names a bug in code we do not own).
OWN_CODE = re.compile(r"cmux|messageslab", re.IGNORECASE)
SUPPRESSION_TYPES = {"race", "race_top", "thread", "mutex", "signal", "deadlock", "called_from_lib"}

EXIT_CLEAN, EXIT_FINDINGS, EXIT_USAGE, EXIT_NO_VERDICT = 0, 1, 2, 3


@dataclasses.dataclass(frozen=True)
class Mode:
    name: str
    sanitize: Optional[str]
    env: dict
    kinds: frozenset
    counts_hangs: bool = False


MODES = {
    "thread": Mode("thread", "thread", {}, frozenset({"tsan"})),
    "address": Mode("address", "address", {}, frozenset({"asan"})),
    "undefined": Mode("undefined", "undefined", {}, frozenset({"ubsan"})),
    "coop-strict": Mode("coop-strict", None, {"LIBDISPATCH_COOPERATIVE_POOL_STRICT": "1"}, frozenset(),
                        counts_hangs=True),
}
DEFAULT_MODES = ("thread", "address", "undefined", "coop-strict")


@dataclasses.dataclass
class Package:
    dir: str
    targets: list


# ---------------------------------------------------------------- enumerate


def swift_dump_package(package_dir: Path) -> dict:
    env = {k: v for k, v in os.environ.items() if k != "SDKROOT"}
    out = subprocess.run(["xcrun", "swift", "package", "dump-package", "--package-path", str(package_dir)],
                         check=True, capture_output=True, text=True, env=env, stdin=subprocess.DEVNULL)
    return json.loads(out.stdout)


def _path_dependencies(manifest: dict, package_dir: Path) -> list:
    paths = []
    for dependency in manifest.get("dependencies", []):
        for entry in dependency.get("fileSystem", []) or []:
            raw = entry.get("path") if isinstance(entry, dict) else None
            if raw:
                paths.append((package_dir / raw).resolve())
    return paths


def enumerate_closure(repo: Path, dump: Callable[[Path], dict], root: str = ROOT_PACKAGE) -> list:
    """Packages (repo-relative, root first, then sorted) with their test targets."""
    packages_root = (repo / "Packages").resolve()
    seen: dict = {}
    queue = [(repo / root).resolve()]
    while queue:
        package_dir = queue.pop(0)
        if package_dir in seen:
            continue
        manifest = dump(package_dir)
        seen[package_dir] = sorted(t["name"] for t in manifest.get("targets", []) if t.get("type") == "test")
        for dependency in _path_dependencies(manifest, package_dir):
            if dependency.is_relative_to(packages_root) and dependency not in seen:
                queue.append(dependency)
    root_dir = (repo / root).resolve()
    ordered = [root_dir] + sorted(d for d in seen if d != root_dir)
    return [Package(str(d.relative_to(repo.resolve())), seen[d]) for d in ordered if seen[d]]


def prefix_overlaps(targets: Iterable[str]) -> list:
    """`swift test --filter A` is a regex, so it also runs target AB's tests."""
    names = sorted(set(targets))
    return [(a, b) for a in names for b in names if a != b and b.startswith(a)]


# ---------------------------------------------------------------- lane output

RESULTS_HEADER = re.compile(r"^Swift suite results \((?P<package>[^)]*)\):$")
RESULT_ROW = re.compile(r"^(?P<suite>\S+)\s+(?P<result>passed|stalled/timeout|failed \(exit \d+\))\s+\d+s$")
GROUP_START = re.compile(r"^::group::swift test .*--filter (?P<suite>\S+)\s*$")
GROUP_END = "::endgroup::"


# The lane runs tests on a pseudo-terminal, where the sanitizer runtimes and swift test color their output.
ANSI = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
# A Swift Testing or XCTest test start: a strict-pool stall after one is the code's, before one SwiftPM's.
TEST_STARTED = re.compile(r"\bTest .+ started\.?$|^Test Case '.+' started\.$")


def clean_lines(text: str) -> list:
    return [ANSI.sub("", line).rstrip("\r") for line in text.splitlines()]


def parse_results(text: str) -> dict:
    """The lane's per-suite result table; empty when the lane stopped before it (a build failure)."""
    results: dict = {}
    in_table = False
    for line in clean_lines(text):
        if RESULTS_HEADER.match(line):
            in_table = True
            continue
        if in_table:
            row = RESULT_ROW.match(line.strip())
            if row:
                results[row.group("suite")] = row.group("result")
            elif line.strip() and not line.startswith("suite "):
                in_table = False
    return results


def split_segments(text: str) -> list:
    """(suite, lines) per `swift test --filter` group of the lane; output outside a group is dropped."""
    segments = []
    suite, lines = None, []
    for line in clean_lines(text):
        start = GROUP_START.match(line)
        if start:
            suite, lines = start.group("suite"), []
        elif line == GROUP_END and suite is not None:
            segments.append((suite, lines))
            suite = None
        elif suite is not None:
            lines.append(line)
    if suite is not None:
        segments.append((suite, lines))
    return segments


REPORT_START = re.compile(
    r"WARNING: ThreadSanitizer:|ERROR: AddressSanitizer:|ERROR: LeakSanitizer:|: runtime error: ")
REPORT_END = re.compile(r"SUMMARY: (ThreadSanitizer|AddressSanitizer|LeakSanitizer|UndefinedBehaviorSanitizer):")
STACK_FRAME = re.compile(r"^\s+#\d+\s")
MAX_REPORT_LINES = 600


def header_kind(line: str) -> str:
    if "ThreadSanitizer" in line:
        return "tsan"
    if "AddressSanitizer" in line:
        return "asan"
    if "LeakSanitizer" in line:
        return "lsan"
    return "ubsan"


def extract_reports(lines: list) -> list:
    """(kind from the header, report text) for each sanitizer report in a suite's output."""
    reports = []
    i = 0
    while i < len(lines):
        if not REPORT_START.search(lines[i]):
            i += 1
            continue
        kind = header_kind(lines[i])
        block = [lines[i]]
        i += 1
        while i < len(lines) and len(block) < MAX_REPORT_LINES:
            line = lines[i]
            if REPORT_START.search(line):
                break
            if kind == "ubsan" and not (STACK_FRAME.match(line) or REPORT_END.search(line) or not line.strip()):
                break
            block.append(line)
            i += 1
            if REPORT_END.search(line):
                break
        reports.append((kind, "\n".join(block).rstrip() + "\n"))
    return reports


# ---------------------------------------------------------------- suppressions


def check_suppressions(path: Path) -> tuple:
    """(active entries, errors): <= 10 entries, each right after a `# reason` line, none naming cmux code."""
    errors, active, reason = [], 0, False
    for number, raw in enumerate(path.read_text().splitlines(), 1):
        line = raw.strip()
        if not line:
            reason = False
            continue
        if line.startswith("#"):
            reason = bool(line.lstrip("#").strip())
            continue
        active += 1
        kind, _, pattern = line.partition(":")
        if kind not in SUPPRESSION_TYPES or not pattern:
            errors.append(f"{path}:{number}: '{line}' is not TYPE:PATTERN (types: {', '.join(sorted(SUPPRESSION_TYPES))})")
        if not reason:
            errors.append(f"{path}:{number}: '{line}' has no '# reason' comment on the line before it")
        if OWN_CODE.search(pattern):
            errors.append(f"{path}:{number}: '{line}' suppresses cmux code; fix the race instead")
        reason = False
    if active > MAX_SUPPRESSIONS:
        errors.append(f"{path}: {active} suppressions, at most {MAX_SUPPRESSIONS}")
    return active, errors


# ---------------------------------------------------------------- signatures


def run_signature_tool(repo: Path, report: Path) -> list:
    """crash_signature.py's records ({kind, process, exception, frames, hash12}) for one report file."""
    proc = subprocess.run([sys.executable, "-I", str(repo / SIGNATURE_TOOL), str(report)],
                          capture_output=True, text=True, stdin=subprocess.DEVNULL)
    if proc.returncode != 0:
        return []
    return parse_records(proc.stdout)


def parse_records(text: str) -> list:
    text = text.strip()
    if not text:
        return []
    try:
        value = json.loads(text)
        values = value if isinstance(value, list) else [value]
    except json.JSONDecodeError:
        values = []
        for line in text.splitlines():
            try:
                values.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return [v for v in values if isinstance(v, dict) and v.get("hash12")]


# ---------------------------------------------------------------- the sweep


def slug(text: str) -> str:
    return re.sub(r"[^A-Za-z0-9_.-]+", "-", text).strip("-")


def lane_env(base: dict, mode: Optional[Mode], suppressions: Path) -> dict:
    env = dict(base)
    for name in ("CMUX_SWIFT_SANITIZE", "LIBDISPATCH_COOPERATIVE_POOL_STRICT"):
        env.pop(name, None)
    if mode is None:
        return env
    env.update(mode.env)
    if mode.sanitize:
        env["CMUX_SWIFT_SANITIZE"] = mode.sanitize
        # An instrumented test runs 2-15 times slower; the lane's 180 s stall limit is for plain builds.
        env.setdefault("CMUX_SWIFT_TEST_STALL_SECONDS", "900")
        env.setdefault("CMUX_SWIFT_PACKAGE_TEST_TIMEOUT_SECONDS", "3600")
    if mode.sanitize == "thread":
        # Chromium's TSan defaults (build/sanitizers/sanitizer_options.cc): keep reporting after the
        # first race, the second stack of a lock-order inversion, used suppressions printed.
        options = f"halt_on_error=0:second_deadlock_stack=1:history_size=7:print_suppressions=1:suppressions={suppressions}"
        env["TSAN_OPTIONS"] = f"{env['TSAN_OPTIONS']}:{options}" if env.get("TSAN_OPTIONS") else options
    if mode.sanitize == "undefined":
        env.setdefault("UBSAN_OPTIONS", "print_stacktrace=1")
    return env


def run_lane_subprocess(repo: Path, package: str, targets: list, env: dict, log: Path) -> str:
    """package-test-lane.sh suite PACKAGE TARGETS, streamed to stdout and to LOG."""
    log.parent.mkdir(parents=True, exist_ok=True)
    command = ["bash", LANE, "suite", package, ",".join(targets)]
    chunks = []
    with log.open("w") as sink:
        proc = subprocess.Popen(command, cwd=repo, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True, errors="replace")
        assert proc.stdout is not None
        for line in proc.stdout:
            sys.stdout.write(line)
            sink.write(line)
            chunks.append(line)
        proc.wait()
    sys.stdout.flush()
    return "".join(chunks)


@dataclasses.dataclass
class Sweep:
    repo: Path
    out_dir: Path
    packages: list
    modes: list
    suppressions: Path
    run_lane: Callable[[str, list, dict, Path], str]
    signature: Callable[[Path], list]
    include_base_red: bool = False
    base_env: dict = dataclasses.field(default_factory=lambda: dict(os.environ))

    def __post_init__(self):
        self.base_red: list = []
        self.findings: dict = {}
        self.per_mode: dict = {}
        self.unclassified: list = []

    def base_pass(self) -> None:
        for package in self.packages:
            text = self.run_lane(package.dir, package.targets, lane_env(self.base_env, None, self.suppressions),
                                 self.out_dir / "base" / f"{slug(package.dir)}.log")
            results = parse_results(text)
            for target in package.targets:
                result = results.get(target, "no result (the package did not build)" if not results else "no result")
                if result != "passed":
                    self.base_red.append({"package": package.dir, "suite": target, "result": result})

    def is_base_red(self, package: str, suite: str) -> bool:
        return any(r["package"] == package and r["suite"] == suite for r in self.base_red)

    def run_mode(self, mode: Mode) -> None:
        stats = {"suites_run": 0, "red_without_report": [], "no_verdict": [], "other_kind": 0}
        self.per_mode[mode.name] = stats
        for package in self.packages:
            targets = [t for t in package.targets if self.include_base_red or not self.is_base_red(package.dir, t)]
            if not targets:
                continue
            text = self.run_lane(package.dir, targets, lane_env(self.base_env, mode, self.suppressions),
                                 self.out_dir / mode.name / f"{slug(package.dir)}.log")
            results = parse_results(text)
            if not results:
                stats["no_verdict"].append({"package": package.dir, "reason": "no suite result (the build failed)"})
                continue
            reports_by_suite: dict = {}
            started: set = set()
            for suite, lines in split_segments(text):
                reports_by_suite.setdefault(suite, []).extend(extract_reports(lines))
                if any(TEST_STARTED.search(line.strip()) for line in lines):
                    started.add(suite)
            for suite in targets:
                result = results.get(suite)
                if result is None:
                    stats["no_verdict"].append({"package": package.dir, "suite": suite, "reason": "no suite result"})
                    continue
                stats["suites_run"] += 1
                counted = not self.is_base_red(package.dir, suite)
                found = self.classify(mode, package.dir, suite, reports_by_suite.get(suite, []), counted)
                if mode.counts_hangs and result == "stalled/timeout" and suite not in started:
                    stats["no_verdict"].append({"package": package.dir, "suite": suite,
                                                "reason": "stalled before any test started (swift test itself)"})
                    continue
                if mode.counts_hangs and result == "stalled/timeout" and counted:
                    self.add_finding(mode, package.dir, suite, {
                        "kind": "coop-strict-hang",
                        "hash12": hashlib.sha1(f"{mode.name}|{package.dir}|{suite}".encode()).hexdigest()[:12],
                        "exception": "hang under LIBDISPATCH_COOPERATIVE_POOL_STRICT=1", "frames": []}, None, True)
                    found = True
                if result != "passed" and not found:
                    stats["red_without_report"].append({"package": package.dir, "suite": suite, "result": result})

    def classify(self, mode: Mode, package: str, suite: str, reports: list, counted: bool) -> bool:
        found = False
        for index, (kind, text) in enumerate(reports, 1):
            path = self.out_dir / "reports" / mode.name / slug(package) / f"{slug(suite)}-{index}.txt"
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
            records = self.signature(path)
            if not records:
                self.unclassified.append({"mode": mode.name, "package": package, "suite": suite,
                                          "header_kind": kind, "report": str(path)})
                continue
            for record in records:
                if record.get("kind") in mode.kinds:
                    self.add_finding(mode, package, suite, record, path, counted)
                    found = True
                elif record.get("kind") == kind:
                    self.add_finding(mode, package, suite, record, path, False)
                    self.per_mode[mode.name]["other_kind"] += 1
                else:
                    self.unclassified.append({"mode": mode.name, "package": package, "suite": suite,
                                              "header_kind": kind, "signature_kind": record.get("kind"),
                                              "report": str(path)})
        return found

    def add_finding(self, mode: Mode, package: str, suite: str, record: dict, path: Optional[Path],
                    counted: bool) -> None:
        key = (mode.name, record["hash12"])
        row = self.findings.get(key)
        if row is None:
            row = self.findings[key] = {
                "mode": mode.name, "kind": record.get("kind"), "hash12": record["hash12"],
                "process": record.get("process"), "exception": record.get("exception"),
                "frames": list(record.get("frames") or [])[:3], "package": package, "suites": [],
                "count": 0, "reports": [], "counted": False}
        row["count"] += 1
        row["counted"] = row["counted"] or counted
        if suite not in row["suites"]:
            row["suites"].append(suite)
        if path is not None and len(row["reports"]) < 5:
            row["reports"].append(str(path))

    def counted_findings(self) -> list:
        return [row for row in self.findings.values() if row["counted"]]

    def run(self) -> int:
        self.base_pass()
        for mode in self.modes:
            self.run_mode(mode)
        return self.verdict()

    def verdict(self) -> int:
        if self.counted_findings():
            return EXIT_FINDINGS
        if self.unclassified or any(stats["no_verdict"] for stats in self.per_mode.values()):
            return EXIT_NO_VERDICT
        return EXIT_CLEAN

    def write(self, findings_out: Path, head: str) -> None:
        findings_out.parent.mkdir(parents=True, exist_ok=True)
        with findings_out.open("w") as sink:
            for row in sorted(self.findings.values(), key=lambda r: (not r["counted"], r["mode"], -r["count"])):
                sink.write(json.dumps(row, sort_keys=True) + "\n")
        (self.out_dir / "base-red.json").write_text(json.dumps(self.base_red, indent=2) + "\n")
        summary = {
            "head": head, "modes": [m.name for m in self.modes],
            "packages": [dataclasses.asdict(p) for p in self.packages],
            "base_red": self.base_red, "per_mode": self.per_mode, "unclassified": self.unclassified,
            "counted_findings": len(self.counted_findings()), "findings_out": str(findings_out),
            "exit": self.verdict()}
        (self.out_dir / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")

    def report(self) -> str:
        out = []
        out.append("Base-red suites (red with no sanitizer; not counted, fix queue):")
        out += [f"  {r['package']}  {r['suite']}  {r['result']}" for r in self.base_red] or ["  (none)"]
        for mode in self.modes:
            stats = self.per_mode.get(mode.name, {})
            counted = [r for r in self.counted_findings() if r["mode"] == mode.name]
            out.append(f"Mode {mode.name}: {stats.get('suites_run', 0)} suites, {len(counted)} signatures counted, "
                       f"{len(stats.get('red_without_report', []))} red without a sanitizer report, "
                       f"{len(stats.get('no_verdict', []))} without a verdict")
            for row in stats.get("red_without_report", []):
                out.append(f"  red, no report: {row['package']}  {row['suite']}  {row['result']}")
            for row in stats.get("no_verdict", []):
                out.append(f"  no verdict: {row['package']}  {row.get('suite', '*')}  {row['reason']}")
        rows = sorted(self.findings.values(), key=lambda r: (not r["counted"], r["mode"], -r["count"]))
        if rows:
            out.append("Signatures:")
        for row in rows:
            tag = "COUNTED" if row["counted"] else "not counted"
            frames = " | ".join(row["frames"]) or row.get("exception") or ""
            out.append(f"  {tag:11} {row['mode']:11} {row['kind']:16} {row['hash12']} x{row['count']} "
                       f"{','.join(row['suites'])}  {frames}")
        for row in self.unclassified:
            out.append(f"  UNCLASSIFIED {row['mode']} {row['suite']} {row['header_kind']} report {row['report']}")
        out.append(f"sanitizer-sweep: {len(self.counted_findings())} counted signatures, "
                   f"{len(self.base_red)} base-red suites, {len(self.unclassified)} unclassified reports")
        return "\n".join(out)


# ---------------------------------------------------------------- CLI


def on_fleet(env: dict) -> bool:
    return bool(env.get("CMUX_CI_STEP_KEY")) or env.get("GITHUB_ACTIONS") == "true"


def parse_modes(value: str) -> list:
    names = [part.strip() for part in value.split(",") if part.strip()]
    unknown = [name for name in names if name not in MODES]
    if unknown or not names:
        raise argparse.ArgumentTypeError(f"--sanitize takes {','.join(DEFAULT_MODES)} (got '{value}')")
    return [MODES[name] for name in dict.fromkeys(names)]


def main(argv: Optional[list] = None) -> int:
    parser = argparse.ArgumentParser(prog="sanitizer-sweep.sh", description=__doc__.split("\n\n")[0])
    parser.add_argument("--sanitize", type=parse_modes, default=[MODES[m] for m in DEFAULT_MODES],
                        help=f"comma list of {','.join(DEFAULT_MODES)} (default: all)")
    parser.add_argument("--ref", help="refuse unless the checkout's HEAD is this commit")
    parser.add_argument("--out", type=Path, help="findings JSONL (default OUT_DIR/findings.jsonl)")
    parser.add_argument("--out-dir", type=Path, default=Path(".build/sanitizer-sweep"))
    parser.add_argument("--package", action="append", default=[], help="only this Packages/ directory (repeatable)")
    parser.add_argument("--target", action="append", default=[], help="only this test target (repeatable)")
    parser.add_argument("--include-base-red", action="store_true",
                        help="run base-red targets under the modes too; their signatures are recorded, not counted")
    parser.add_argument("--list", action="store_true", help="print the packages and test targets, run nothing")
    args = parser.parse_args(argv)

    if not on_fleet(os.environ):
        print("sanitizer-sweep.sh runs only on the build fleet or a GitHub runner (it runs swift test under "
              "sanitizers).\nRun it there:\n  cmux-ci run --class isolated --ref SHA --script "
              "scripts/cmux-next/sanitizer-sweep.sh -- --sanitize thread", file=sys.stderr)
        return EXIT_USAGE
    repo = Path(subprocess.run(["git", "rev-parse", "--show-toplevel"], check=True, capture_output=True,
                               text=True).stdout.strip())
    head = subprocess.run(["git", "-C", str(repo), "rev-parse", "HEAD"], check=True, capture_output=True,
                          text=True).stdout.strip()
    if args.ref and not (len(args.ref) >= 7 and head.startswith(args.ref.lower())):
        print(f"sanitizer-sweep: HEAD is {head}, not --ref {args.ref}", file=sys.stderr)
        return EXIT_USAGE
    suppressions = repo / SUPPRESSIONS
    active, errors = check_suppressions(suppressions)
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return EXIT_USAGE
    if not (repo / SIGNATURE_TOOL).is_file():
        print(f"sanitizer-sweep: {SIGNATURE_TOOL} is missing (p10-stability-002); no report can be counted",
              file=sys.stderr)
        return EXIT_USAGE

    packages = enumerate_closure(repo, swift_dump_package)
    if args.package:
        wanted = {p.rstrip("/") for p in args.package}
        packages = [p for p in packages if p.dir in wanted]
    if args.target:
        packages = [Package(p.dir, [t for t in p.targets if t in args.target]) for p in packages]
        packages = [p for p in packages if p.targets]
    if not packages:
        print("sanitizer-sweep: no test target selected", file=sys.stderr)
        return EXIT_USAGE
    for package in packages:
        for short, long in prefix_overlaps(package.targets):
            print(f"sanitizer-sweep: note: --filter {short} also runs {long} in {package.dir}")
    if args.list:
        for package in packages:
            print(f"{package.dir}: {' '.join(package.targets)}")
        return EXIT_CLEAN

    out_dir = args.out_dir if args.out_dir.is_absolute() else repo / args.out_dir
    findings_out = args.out or out_dir / "findings.jsonl"
    print(f"sanitizer-sweep: {head} modes {','.join(m.name for m in args.sanitize)}; "
          f"{sum(len(p.targets) for p in packages)} test targets in {len(packages)} packages; "
          f"{active} TSan suppressions")
    sweep = Sweep(repo=repo, out_dir=out_dir, packages=packages, modes=args.sanitize, suppressions=suppressions,
                  run_lane=lambda pkg, targets, env, log: run_lane_subprocess(repo, pkg, targets, env, log),
                  signature=lambda path: run_signature_tool(repo, path), include_base_red=args.include_base_red)
    status = sweep.run()
    sweep.write(findings_out, head)
    print(sweep.report())
    print(f"sanitizer-sweep: findings {findings_out}; summary {out_dir / 'summary.json'}")
    return status


if __name__ == "__main__":
    sys.exit(main())
