#!/usr/bin/env python3
"""Swift package tests of the CmuxNext closure under sanitizers, with a base-red pre-pass.

Usage (a fleet step only; see README-sanitizers.md):
  cmux-ci run --class isolated --ref SHA --script scripts/cmux-next/sanitizer-sweep.sh -- \\
    --sanitize thread[,address,undefined,coop-strict] [--ref SHA] [--out FILE] [--package NAME]...

1. Enumerate: `swift package dump-package` of Packages/macOS/CmuxNext and, through its `.package(path:)`
   dependencies, every package of the closure under Packages/; the test targets of each.
2. Base pass: every package's test targets run once with no sanitizer (`package-test-lane.sh suite`).
   A target red here is base-red: it goes to base-red.jsonl and the printed base-red list, and nothing
   it reports under a sanitizer is counted.
3. One pass per mode: thread, address and undefined set CMUX_SWIFT_SANITIZE (the lane builds into its
   own scratch folder); coop-strict sets LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 on the base build.
4. Each target's output is read with crash_signature.py. Only the mode's own kind counts (thread: tsan,
   address: asan, undefined: ubsan, coop-strict: a hang sample of a stalled target). Each unique
   (mode, hash12) is one line of --out, the Q15 queue. Everything else goes to not-counted.jsonl.

This is Chromium's sanitizer bot split (docs/asan.md, tools/mb): a test red without the sanitizer is
the normal bots' failure, not a sanitizer finding. Timeouts scale under a sanitizer as Chromium's
base/test/test_timeouts.cc (kTimeoutMultiplier) scales them.

Exit status: 0 no finding; 1 findings; 2 bad arguments, a non-fleet host or a bad suppressions file;
3 no verdict (enumeration failed, or a mode did not build a package that built at the base).
"""

from __future__ import annotations

import argparse
import dataclasses
import importlib.util
import json
import os
import platform
import re
import subprocess
import sys
from pathlib import Path
from typing import Callable, Iterable, Mapping

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
ROOT_PACKAGE = "Packages/macOS/CmuxNext"
LANE = "scripts/ci/package-test-lane.sh"
SUPPRESSIONS = HERE / "tsan-suppressions.txt"
MAX_SUPPRESSIONS = 10
DEFAULT_OUT = Path(".build/sanitizer-sweep/findings.jsonl")

MODES = ("thread", "address", "undefined", "coop-strict")
COUNTED_KIND = {"thread": "tsan", "address": "asan", "undefined": "ubsan", "coop-strict": "hang"}
TIMEOUT_MULTIPLIER = {"thread": 3, "address": 2, "undefined": 2, "coop-strict": 1}
# The lane's own defaults (package-test-lane.sh run_suite).
STALL_SECONDS = 180
TIMEOUT_SECONDS = 900
TSAN_TYPES = ("race", "race_top", "thread", "mutex", "signal", "deadlock", "called_from_lib")

FLEET_COMMAND = ("cmux-ci run --class isolated --ref SHA --script scripts/cmux-next/sanitizer-sweep.sh"
                 " -- --sanitize thread")
ANSI = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
GROUP = re.compile(r"^::group::swift test --filter (?P<target>\S+)\s*$")
RESULTS = re.compile(r"^Swift suite results \(")
ROW = re.compile(r"^(?P<target>\S+)\s+(?P<result>passed|failed \(exit \d+\)|stalled/timeout)\s+\d+s\s*$")


def _load_crash_signature():
    if "crash_signature" in sys.modules:
        return sys.modules["crash_signature"]
    spec = importlib.util.spec_from_file_location("crash_signature", HERE / "crash_signature.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules["crash_signature"] = module
    spec.loader.exec_module(module)
    return module


cs = _load_crash_signature()


class SweepError(Exception):
    """A sweep that cannot reach a verdict (exit 3)."""


class UsageError(Exception):
    """Bad arguments, host or suppressions file (exit 2)."""


@dataclasses.dataclass(frozen=True)
class Package:
    path: str  # repository-relative, Packages/...
    name: str
    tests: tuple[str, ...]


@dataclasses.dataclass
class LaneRun:
    """One `package-test-lane.sh suite` run: each target's result and output."""

    status: int
    results: dict[str, str]  # target -> passed | failed (exit N) | stalled/timeout
    output: dict[str, str]  # target -> its `swift test --filter` text
    log: Path

    def built(self) -> bool:
        return bool(self.results)

    def result(self, target: str) -> str:
        return self.results.get(target) or f"build failed (exit {self.status})"


# ---------------------------------------------------------------- host and suppressions

def fleet_host_refusal(environ: Mapping[str, str], system: str) -> str:
    """Why this host may not run the sweep, or "" on a fleet step (cmux-ci sets CMUX_CI_STEP_KEY)."""
    if not environ.get("CMUX_CI_STEP_KEY"):
        return ("sanitizer-sweep builds and tests the whole CmuxNext closure several times and runs only as a "
                f"fleet step:\n  {FLEET_COMMAND}")
    if system != "Darwin":
        return f"sanitizer-sweep needs a macOS fleet host (this one is {system})"
    return ""


def check_suppressions(text: str) -> list[str]:
    """The suppression lines of tsan-suppressions.txt; UsageError unless each is third-party and reasoned.

    A line is blank, a `#` comment, or `type:pattern`. TSan reads the rest of a suppression line as the
    pattern, so each reason is the comment line right above it: `# third-party <component>: <why>`.
    """
    suppressions: list[str] = []
    previous = ""
    for number, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if line and not line.startswith("#"):
            kind, _, pattern = line.partition(":")
            if kind not in TSAN_TYPES or not pattern.strip():
                raise UsageError(f"tsan-suppressions.txt:{number}: not a TSan suppression: {line}")
            if re.search(r"cmux", pattern, re.IGNORECASE):
                raise UsageError(f"tsan-suppressions.txt:{number}: suppresses cmux code; fix the race instead")
            if not re.match(r"#\s*third-party [^:]+:\s*\S", previous):
                raise UsageError(f"tsan-suppressions.txt:{number}: needs a `# third-party <component>: <reason>` "
                                 "line right above it")
            suppressions.append(line)
        previous = line
    if len(suppressions) > MAX_SUPPRESSIONS:
        raise UsageError(f"tsan-suppressions.txt has {len(suppressions)} suppressions; the limit is "
                         f"{MAX_SUPPRESSIONS}")
    return suppressions


# ---------------------------------------------------------------- enumeration

def dump_package_with_swift(package_dir: Path) -> dict:
    completed = subprocess.run(["swift", "package", "dump-package", "--package-path", str(package_dir)],
                               capture_output=True, text=True, stdin=subprocess.DEVNULL)
    if completed.returncode != 0:
        raise SweepError(f"swift package dump-package {package_dir} failed: {completed.stderr.strip()[-2000:]}")
    return json.loads(completed.stdout)


def _path_dependencies(manifest: dict) -> list[str]:
    paths = []
    for dependency in manifest.get("dependencies") or []:
        entries = dependency.get("fileSystem") or []
        for entry in entries if isinstance(entries, list) else [entries]:
            if isinstance(entry, dict) and entry.get("path"):
                paths.append(entry["path"])
    return paths


def enumerate_closure(root: Path, dump: Callable[[Path], dict]) -> list[Package]:
    """CmuxNext first, then each repository package it reaches through `.package(path:)`, breadth first."""
    packages: list[Package] = []
    queue = [ROOT_PACKAGE]
    seen = {ROOT_PACKAGE}
    while queue:
        relative = queue.pop(0)
        manifest = dump(root / relative)
        tests = tuple(t["name"] for t in manifest.get("targets") or [] if t.get("type") == "test")
        packages.append(Package(relative, manifest.get("name") or Path(relative).name, tests))
        for raw in _path_dependencies(manifest):
            resolved = Path(os.path.normpath(root / relative / raw)) if not os.path.isabs(raw) else Path(raw)
            try:
                dependency = resolved.resolve().relative_to(root.resolve()).as_posix()
            except ValueError:
                continue  # outside the repository: not ours to test
            if dependency.startswith("Packages/") and dependency not in seen:
                seen.add(dependency)
                queue.append(dependency)
    return packages


# ---------------------------------------------------------------- the lane

def parse_lane_output(text: str) -> tuple[dict[str, str], dict[str, str]]:
    """The suite table's result per target, and each target's output (its group up to the next one)."""
    results: dict[str, str] = {}
    output: dict[str, list[str]] = {}
    current: str | None = None
    in_table = False
    for raw in text.splitlines():
        line = ANSI.sub("", raw).rstrip("\r")
        group = GROUP.match(line)
        if group:
            current = group.group("target")
            output.setdefault(current, [])
            in_table = False
            continue
        if RESULTS.match(line):
            current = None
            in_table = True
            continue
        if in_table:
            row = ROW.match(line.strip())
            if row:
                results[row.group("target")] = row.group("result")
            continue
        if current is not None:
            output[current].append(line)
    return results, {target: "\n".join(lines) for target, lines in output.items()}


def mode_environment(base: Mapping[str, str], mode: str | None) -> dict[str, str]:
    """The lane's environment: no sanitizer for the base pass, else the mode's variables and longer limits."""
    env = {k: v for k, v in base.items() if k not in ("CMUX_SWIFT_SANITIZE", "LIBDISPATCH_COOPERATIVE_POOL_STRICT")}
    if mode is None:
        return env
    if mode == "coop-strict":
        env["LIBDISPATCH_COOPERATIVE_POOL_STRICT"] = "1"
    else:
        env["CMUX_SWIFT_SANITIZE"] = mode
    multiplier = TIMEOUT_MULTIPLIER[mode]
    env.setdefault("CMUX_SWIFT_TEST_STALL_SECONDS", str(STALL_SECONDS * multiplier))
    env.setdefault("CMUX_SWIFT_PACKAGE_TEST_TIMEOUT_SECONDS", str(TIMEOUT_SECONDS * multiplier))
    if mode == "thread":
        options = [f"suppressions={SUPPRESSIONS}", "halt_on_error=0", "second_deadlock_stack=1"]
        env["TSAN_OPTIONS"] = " ".join(filter(None, [env.get("TSAN_OPTIONS", ""), *options]))
    if mode == "undefined":
        env["UBSAN_OPTIONS"] = " ".join(filter(None, [env.get("UBSAN_OPTIONS", ""), "print_stacktrace=1"]))
    return env


def run_lane_subprocess(root: Path, package: Package, env: Mapping[str, str], log: Path) -> LaneRun:
    """`package-test-lane.sh suite PACKAGE TARGET,...`, streamed to the step log and into `log`."""
    log.parent.mkdir(parents=True, exist_ok=True)
    command = ["bash", LANE, "suite", package.path, ",".join(package.tests)]
    with log.open("w", encoding="utf-8") as sink:
        process = subprocess.Popen(command, cwd=root, env=dict(env), stdin=subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace")
        assert process.stdout is not None
        for line in process.stdout:
            sink.write(line)
            sys.stdout.write(line)
        status = process.wait()
    results, output = parse_lane_output(log.read_text(encoding="utf-8", errors="replace"))
    return LaneRun(status, results, output, log)


# ---------------------------------------------------------------- the sweep

@dataclasses.dataclass
class Sweep:
    base_red: list[dict] = dataclasses.field(default_factory=list)
    findings: dict[tuple[str, str], dict] = dataclasses.field(default_factory=dict)
    not_counted: list[dict] = dataclasses.field(default_factory=list)
    incomplete: list[dict] = dataclasses.field(default_factory=list)


def classify(sweep: Sweep, mode: str, package: Package, run: LaneRun, base_red: set[str]) -> None:
    counted_kind = COUNTED_KIND[mode]
    if not run.built():
        sweep.incomplete.append({"mode": mode, "package": package.path, "result": run.result(""),
                                 "log": str(run.log)})
        return
    for target in package.tests:
        result = run.result(target)
        text = ANSI.sub("", run.output.get(target, ""))
        signatures = cs.signatures_from_text(text, f"{package.path}:{target}", process=f"{package.name}PackageTests")
        if mode == "coop-strict" and result != "stalled/timeout":
            signatures = [s for s in signatures if s.kind != "hang"]
        place = {"mode": mode, "package": package.path, "target": target, "result": result}
        counted = 0
        for signature in signatures:
            record = {**place, **signature.to_json()}
            if target in base_red or signature.kind != counted_kind:
                reason = "base-red" if target in base_red else f"kind {signature.kind} is not counted in {mode}"
                sweep.not_counted.append({**record, "reason": reason})
                continue
            counted += 1
            key = (mode, signature.hash12)
            finding = sweep.findings.setdefault(key, {**record, "count": 0, "targets": []})
            finding["count"] += 1
            if f"{package.path}:{target}" not in finding["targets"]:
                finding["targets"].append(f"{package.path}:{target}")
        if result != "passed" and not counted and target not in base_red:
            sweep.not_counted.append({**place, "reason": "red under the mode with no counted report",
                                      "log": str(run.log)})


def sweep(root: Path, modes: Iterable[str], packages: list[Package], out_dir: Path,
          run_lane: Callable[[Package, Mapping[str, str], Path], LaneRun],
          environ: Mapping[str, str]) -> Sweep:
    result = Sweep()
    base_runs: dict[str, LaneRun] = {}
    for package in packages:
        run = run_lane(package, mode_environment(environ, None), out_dir / "logs" / "base" / f"{package.name}.log")
        base_runs[package.path] = run
        for target in package.tests:
            if run.result(target) != "passed":
                result.base_red.append({"package": package.path, "target": target, "result": run.result(target),
                                        "log": str(run.log)})
    for mode in modes:
        for package in packages:
            base = base_runs[package.path]
            if not base.built():
                continue  # the whole package is base-red; a sanitizer build of it says nothing new
            red = {row["target"] for row in result.base_red if row["package"] == package.path}
            run = run_lane(package, mode_environment(environ, mode), out_dir / "logs" / mode / f"{package.name}.log")
            classify(result, mode, package, run, red)
    return result


def write_jsonl(path: Path, rows: Iterable[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as sink:
        for row in rows:
            sink.write(json.dumps(row, sort_keys=True) + "\n")


def report(result: Sweep, modes: list[str], out: Path, suppressions: list[str], ref: str) -> int:
    out_dir = out.parent
    findings = sorted(result.findings.values(), key=lambda f: (f["mode"], -f["count"], f["hash12"]))
    write_jsonl(out, findings)
    write_jsonl(out_dir / "base-red.jsonl", result.base_red)
    write_jsonl(out_dir / "not-counted.jsonl", result.not_counted)
    per_mode = {mode: sum(1 for f in findings if f["mode"] == mode) for mode in modes}
    summary = {"ref": ref, "modes": modes, "findings": per_mode, "base_red": len(result.base_red),
               "not_counted": len(result.not_counted), "incomplete": result.incomplete,
               "tsan_suppressions": len(suppressions)}
    (out_dir / "summary.json").write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    print(f"sanitizer-sweep: base-red suites (red with no sanitizer; listed, not counted): {len(result.base_red)}")
    for row in result.base_red:
        print(f"  {row['package']} {row['target']}: {row['result']}")
    for mode in modes:
        print(f"sanitizer-sweep: {mode}: {per_mode[mode]} {COUNTED_KIND[mode]} finding(s)")
    for finding in findings:
        print(f"  [{finding['mode']}] {finding['hash12']} {finding['exception']}: {' / '.join(finding['frames'])}"
              f" ({', '.join(finding['targets'])})")
    for row in result.incomplete:
        print(f"sanitizer-sweep: no verdict for {row['package']} under {row['mode']}: {row['result']} ({row['log']})")
    print(f"sanitizer-sweep: {len(result.not_counted)} not counted; TSan suppressions: {len(suppressions)}")
    print(f"sanitizer-sweep: findings {out}; base-red {out_dir / 'base-red.jsonl'}; "
          f"not counted {out_dir / 'not-counted.jsonl'}; logs {out_dir / 'logs'}")
    if findings:
        return 1
    return 3 if result.incomplete else 0


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(prog="sanitizer-sweep.sh", description=__doc__.split("\n\n", 1)[0])
    parser.add_argument("--sanitize", required=True,
                        help="comma list of " + ", ".join(MODES))
    parser.add_argument("--ref", default="", help="refuse unless the checkout is this commit")
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT, help="findings JSONL (the Q15 queue)")
    parser.add_argument("--package", action="append", default=[],
                        help="only this closure package (name or Packages/ path); repeatable")
    args = parser.parse_args(argv)
    modes = [m.strip() for m in args.sanitize.split(",") if m.strip()]
    unknown = [m for m in modes if m not in MODES]
    if not modes or unknown:
        parser.error(f"--sanitize takes {', '.join(MODES)} (got {args.sanitize!r})")
    args.modes = list(dict.fromkeys(modes))
    if args.ref and not re.fullmatch(r"[0-9a-f]{7,40}", args.ref):
        parser.error("--ref takes a commit sha")
    return args


def check_ref(root: Path, ref: str) -> str:
    head = subprocess.run(["git", "rev-parse", "HEAD"], cwd=root, capture_output=True, text=True).stdout.strip()
    if ref and not head.startswith(ref):
        raise UsageError(f"the checkout is {head or 'not a git checkout'}, not --ref {ref}")
    return head


def main(argv: list[str] | None = None, environ: Mapping[str, str] | None = None, system: str | None = None,
         dump: Callable[[Path], dict] = dump_package_with_swift,
         run_lane: Callable[[Package, Mapping[str, str], Path], LaneRun] | None = None,
         root: Path = ROOT) -> int:
    environ = dict(os.environ if environ is None else environ)
    try:
        args = parse_args(list(sys.argv[1:] if argv is None else argv))
    except SystemExit as error:
        return 2 if error.code else 0
    try:
        refusal = fleet_host_refusal(environ, platform.system() if system is None else system)
        if refusal:
            raise UsageError(refusal)
        suppressions = check_suppressions(SUPPRESSIONS.read_text(encoding="utf-8"))
        head = check_ref(root, args.ref)
        packages = [p for p in enumerate_closure(root, dump) if p.tests]
        if args.package:
            wanted = set(args.package)
            packages = [p for p in packages if p.name in wanted or p.path in wanted]
            if not packages:
                raise UsageError(f"--package {', '.join(args.package)} names no closure package with tests")
        out = args.out if args.out.is_absolute() else root / args.out
        lane = run_lane or (lambda package, env, log: run_lane_subprocess(root, package, env, log))
        print(f"sanitizer-sweep: {sum(len(p.tests) for p in packages)} test targets in {len(packages)} packages; "
              f"modes {', '.join(args.modes)}")
        result = sweep(root, args.modes, packages, out.parent, lane, environ)
        return report(result, args.modes, out, suppressions, head)
    except UsageError as error:
        print(f"sanitizer-sweep: {error}", file=sys.stderr)
        return 2
    except (SweepError, OSError, json.JSONDecodeError) as error:
        print(f"sanitizer-sweep: no verdict: {error}", file=sys.stderr)
        return 3


if __name__ == "__main__":
    sys.exit(main())
