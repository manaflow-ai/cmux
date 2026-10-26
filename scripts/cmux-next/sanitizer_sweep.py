#!/usr/bin/env python3
"""Swift package tests of the CmuxNext closure under sanitizers, with a base-red pre-pass.

Usage (a fleet step only; see README-sanitizers.md):
  cmux-ci run --class isolated --ref SHA --script scripts/cmux-next/sanitizer-sweep.sh -- \\
    --sanitize thread[,address,undefined,coop-strict] [--ref SHA] [--out FILE] [--package NAME]...

1. Toolchain: the lane's Xcode (DEVELOPER_DIR, else scripts/select-ci-xcode.sh) and that Xcode's macOS SDK
   (SDKROOT), for the enumeration and every lane run, as package-test-lane.sh select_xcode/pin_sdkroot do.
2. Enumerate: `xcrun swift package dump-package` of Packages/macOS/CmuxNext and, through its `.package(path:)`
   dependencies, every package of the closure under Packages/; the test targets of each.
3. Base pass: every package's test targets run once with no sanitizer (`package-test-lane.sh suite`).
   A target red here is base-red: it goes to base-red.jsonl and the printed base-red list, and nothing
   it reports under a sanitizer is counted. A package that does not build here has no verdict.
4. One pass per mode: thread, address and undefined set CMUX_SWIFT_SANITIZE (the lane builds into its
   own scratch folder); coop-strict sets CMUX_SWIFT_TEST_COOP_STRICT=1, so the lane gives
   LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 to the test runs and not to the build.
5. Each target's output is read with crash_signature.py. Only the mode's own kind counts (thread: tsan,
   address: asan, undefined: ubsan, coop-strict: the blocked cooperative-pool thread of a stalled test
   process). Each unique (mode, hash12) is one line of --out, the Q15 queue. Everything else goes to
   not-counted.jsonl. Every output file is rewritten after each lane run, so a killed step keeps its evidence.

This is Chromium's sanitizer bot split (docs/asan.md, tools/mb): a test red without the sanitizer is
the normal bots' failure, not a sanitizer finding. Timeouts scale under a sanitizer as Chromium's
base/test/test_timeouts.cc (kTimeoutMultiplier) scales them.

Exit status: 0 no finding; 1 findings; 2 bad arguments, a non-fleet host or a bad suppressions file;
3 no verdict (no toolchain, enumeration failed, a package did not build at the base, or a mode did not
build a package that built at the base).
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
import tempfile
from pathlib import Path
from typing import Callable, Iterable, Mapping

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
ROOT_PACKAGE = "Packages/macOS/CmuxNext"
LANE = "scripts/ci/package-test-lane.sh"
SELECT_XCODE = "scripts/select-ci-xcode.sh"
SUPPRESSIONS = HERE / "tsan-suppressions.txt"
MAX_SUPPRESSIONS = 10
# The shortest literal run a suppression may have: TSan matches a pattern anywhere in a function, file or
# module name, so `race:a` suppresses nearly everything.
MIN_SUPPRESSION_LITERAL = 4
DEFAULT_OUT = Path(".build/sanitizer-sweep/findings.jsonl")

MODES = ("thread", "address", "undefined", "coop-strict")
COUNTED_KIND = {"thread": "tsan", "address": "asan", "undefined": "ubsan", "coop-strict": "hang"}
TIMEOUT_MULTIPLIER = {"thread": 3, "address": 2, "undefined": 2, "coop-strict": 1}
# The lane's own defaults (package-test-lane.sh run_suite).
STALL_SECONDS = 180
TIMEOUT_SECONDS = 900
TSAN_TYPES = ("race", "race_top", "thread", "mutex", "signal", "deadlock", "called_from_lib")
LANE_MODE_VARIABLES = ("CMUX_SWIFT_SANITIZE", "CMUX_SWIFT_TEST_COOP_STRICT", "LIBDISPATCH_COOPERATIVE_POOL_STRICT")
POOL_STALL = "cooperative-pool stall"

FLEET_COMMAND = ("cmux-ci run --class isolated --ref SHA --script scripts/cmux-next/sanitizer-sweep.sh"
                 " -- --sanitize thread")
ANSI = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
GROUP = re.compile(r"^::group::swift test --filter (?P<target>\S+)\s*$")
RESULTS = re.compile(r"^Swift suite results \(")
ROW = re.compile(r"^(?P<target>\S+)\s+(?P<result>passed|failed \(exit \d+\)|stalled/timeout)\s+\d+s\s*$")
# hung_test_watchdog.py: one group per sampled process; TEST_PROCESS there names the test processes.
SAMPLE_GROUP = re.compile(r"^::group::Stack sample of (?P<name>.+) \(\d+\)\s*$")
TEST_PROCESS = re.compile(r"xctest|swiftpm-testing|PackageTests", re.IGNORECASE)
SAMPLE_THREAD = re.compile(r"^\s*\d+\s+Thread_\w+")
SAMPLE_COUNT = re.compile(r"^\s*(?P<count>\d+)\s")
SAMPLE_SECTION_ENDS = ("Total number in stack", "Sort by top of stack", "Binary Images")
SWIFT_CONCURRENCY_FRAME = re.compile(r"\(in libswift_Concurrency\.dylib\)")
# git grep -E (POSIX extended) patterns.
DECLARATION = r"\b(class|struct|enum|actor|protocol|func|typealias|extension)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*"
OBJC_DECLARATION = r"@(interface|implementation|protocol)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*"
IDENTIFIER = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


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


@dataclasses.dataclass(frozen=True)
class Toolchain:
    """The Xcode and macOS SDK every swift call of the sweep uses."""

    developer_dir: str
    sdkroot: str

    def environment(self, base: Mapping[str, str]) -> dict[str, str]:
        return {**base, "DEVELOPER_DIR": self.developer_dir, "SDKROOT": self.sdkroot}


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


def repository_names(root: Path = ROOT) -> list[str]:
    """What a TSan pattern could match in cmux code: each tracked Packages/ path and each type or function
    a Packages/ source declares (TSan matches the pattern in function, file and module names)."""
    def git(*args: str) -> list[str]:
        completed = subprocess.run(["git", *args], cwd=root, capture_output=True, text=True, stdin=subprocess.DEVNULL)
        if completed.returncode not in (0, 1):  # git grep exits 1 when nothing matches
            raise UsageError(f"git {args[0]} failed while checking tsan-suppressions.txt: {completed.stderr.strip()}")
        return completed.stdout.splitlines()

    names = git("ls-files", "--", "Packages/")
    for pattern, pathspecs in ((DECLARATION, ("Packages/*.swift",)),
                               (OBJC_DECLARATION, ("Packages/*.h", "Packages/*.m", "Packages/*.mm"))):
        for line in git("grep", "-ohE", pattern, "--", *pathspecs):
            names.append(line.split()[-1])
    return names


def _suppression_refusal(pattern: str, names: list[str], declared: set[str]) -> str:
    """Why a pattern may reach cmux code, or ""."""
    if pattern.startswith("*") or not pattern.strip("*^$"):
        return "starts with a wildcard; TSan already matches anywhere in the name, so name the library"
    literals = [part for part in pattern.strip("^$").split("*") if part]
    if max(len(part) for part in literals) < MIN_SUPPRESSION_LITERAL:
        return f"has no literal run of {MIN_SUPPRESSION_LITERAL} characters, so it matches too much"
    if re.search(r"cmux", pattern, re.IGNORECASE):
        return "suppresses cmux code; fix the race instead"
    for part in literals:
        hit = next((token for token in IDENTIFIER.findall(part) if token in declared), None)
        hit = hit or next((name for name in names if part in name), None)
        if hit is not None:
            return f"`{part}` also matches cmux code ({hit}); fix the race or name the third-party library"
    return ""


def check_suppressions(text: str, names: Callable[[], Iterable[str]] = repository_names) -> list[str]:
    """The suppression lines of tsan-suppressions.txt; UsageError unless each is third-party and reasoned.

    A line is blank, a `#` comment, or `type:pattern`. TSan reads the rest of a suppression line as the
    pattern, so each reason is the comment line right above it: `# third-party <component>: <why>`.
    A pattern may not start with a wildcard and may not match a Packages/ path or a type or function
    declared there.
    """
    suppressions: list[str] = []
    patterns: list[tuple[int, str]] = []
    previous = ""
    for number, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if line and not line.startswith("#"):
            kind, _, pattern = line.partition(":")
            if kind not in TSAN_TYPES or not pattern.strip():
                raise UsageError(f"tsan-suppressions.txt:{number}: not a TSan suppression: {line}")
            if not re.match(r"#\s*third-party [^:]+:\s*\S", previous):
                raise UsageError(f"tsan-suppressions.txt:{number}: needs a `# third-party <component>: <reason>` "
                                 "line right above it")
            suppressions.append(line)
            patterns.append((number, pattern.strip()))
        previous = line
    if len(suppressions) > MAX_SUPPRESSIONS:
        raise UsageError(f"tsan-suppressions.txt has {len(suppressions)} suppressions; the limit is "
                         f"{MAX_SUPPRESSIONS}")
    corpus = list(names()) if patterns else []
    # Type names (UpperCamelCase) also refuse a pattern that only contains them (`TerminalRegistry.register`);
    # function names (`framework`, `run`) are too common for that and refuse only a pattern inside them.
    declared = {name for name in corpus if "/" not in name and name[:1].isupper()}
    for number, pattern in patterns:
        refusal = _suppression_refusal(pattern, corpus, declared)
        if refusal:
            raise UsageError(f"tsan-suppressions.txt:{number}: {pattern} {refusal}")
    return suppressions


# ---------------------------------------------------------------- toolchain and enumeration

def _run(command: list[str], root: Path, env: Mapping[str, str]) -> subprocess.CompletedProcess:
    return subprocess.run(command, cwd=root, env=dict(env), capture_output=True, text=True, stdin=subprocess.DEVNULL)


def resolve_toolchain(root: Path, environ: Mapping[str, str]) -> Toolchain:
    """package-test-lane.sh select_xcode + pin_sdkroot: DEVELOPER_DIR, else select-ci-xcode.sh's pick without
    touching xcode-select; SDKROOT is that Xcode's macOS SDK, never one leaked from the environment."""
    developer_dir = environ.get("DEVELOPER_DIR", "")
    if not developer_dir:
        with tempfile.TemporaryDirectory(prefix="sanitizer-sweep-xcode.") as directory:
            env_file = Path(directory) / "xcode.env"
            env_file.write_text("", encoding="utf-8")
            completed = _run(["bash", SELECT_XCODE], root,
                             {**environ, "GITHUB_ENV": str(env_file), "CMUX_CI_SKIP_XCODE_SELECT": "1"})
            lines = [line.partition("=")[2] for line in env_file.read_text(encoding="utf-8").splitlines()
                     if line.startswith("DEVELOPER_DIR=")]
        if completed.returncode != 0 or not lines or not lines[-1]:
            raise SweepError(f"{SELECT_XCODE} chose no Xcode: {(completed.stdout + completed.stderr).strip()[-2000:]}")
        developer_dir = lines[-1]
    sdk_env = {k: v for k, v in environ.items() if k != "SDKROOT"}
    completed = _run(["xcrun", "--sdk", "macosx", "--show-sdk-path"], root, {**sdk_env, "DEVELOPER_DIR": developer_dir})
    sdkroot = completed.stdout.strip()
    if completed.returncode != 0 or not sdkroot:
        raise SweepError(f"xcrun found no macOS SDK in {developer_dir}: {completed.stderr.strip()[-2000:]}")
    return Toolchain(developer_dir, sdkroot)


def dump_package(toolchain: Toolchain, package_dir: Path, environ: Mapping[str, str]) -> dict:
    completed = subprocess.run(["xcrun", "--sdk", "macosx", "swift", "package", "dump-package",
                                "--package-path", str(package_dir)],
                               env=toolchain.environment(environ), capture_output=True, text=True,
                               stdin=subprocess.DEVNULL)
    if completed.returncode != 0:
        raise SweepError(f"swift package dump-package {package_dir} failed (DEVELOPER_DIR={toolchain.developer_dir} "
                         f"SDKROOT={toolchain.sdkroot}): {completed.stderr.strip()[-2000:]}")
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
    env = {k: v for k, v in base.items() if k not in LANE_MODE_VARIABLES}
    if mode is None:
        return env
    if mode == "coop-strict":
        env["CMUX_SWIFT_TEST_COOP_STRICT"] = "1"
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


# ---------------------------------------------------------------- coop-strict stalls

def _test_process_samples(text: str) -> list[str]:
    """The `sample` reports hung_test_watchdog.py printed for the test processes (not the SwiftPM driver)."""
    samples: list[str] = []
    current: list[str] | None = None
    for line in text.splitlines():
        group = SAMPLE_GROUP.match(line)
        if group:
            current = [] if TEST_PROCESS.search(group.group("name")) else None
            continue
        if line.startswith("::endgroup::"):
            if current is not None:
                samples.append("\n".join(current))
            current = None
            continue
        if current is not None:
            current.append(line)
    return samples


def _pool_thread_report(sample: str) -> str:
    """The sample's header and its heaviest cooperative-pool thread, or "" when it has none.

    A thread is a pool thread when its header names a `.cooperative` queue or one of its frames is in the
    Swift concurrency runtime; the main thread is never one (an async main runs its drain loop there).
    """
    lines = sample.splitlines()
    try:
        graph = lines.index("Call graph:")
    except ValueError:
        return ""
    threads: list[list[str]] = []
    for line in lines[graph + 1:]:
        if line.startswith(SAMPLE_SECTION_ENDS):
            break
        if SAMPLE_THREAD.match(line):
            threads.append([line])
        elif threads:
            threads[-1].append(line)
    pool = [thread for thread in threads if "com.apple.main-thread" not in thread[0]
            and (".cooperative" in thread[0] or any(SWIFT_CONCURRENCY_FRAME.search(line) for line in thread[1:]))]
    if not pool:
        return ""
    heaviest = max(pool, key=lambda thread: int(SAMPLE_COUNT.match(thread[0]).group("count")))
    return "\n".join([*lines[:graph + 1], *heaviest])


def pool_stall_signatures(text: str, source: str) -> list:
    """One signature per sampled test process: its blocked cooperative-pool thread's heaviest stack.

    crash_signature.parse_hang reads the main thread, which a test runner parks in its run loop or
    dispatch_main whatever deadlocked; the strict pool's one worker is where the blocking code is.
    """
    signatures = []
    for sample in _test_process_samples(text):
        report = _pool_thread_report(sample)
        for signature in cs.parse_hang(report, cs.IgnoreList.load(), source) if report else []:
            signatures.append(dataclasses.replace(signature, exception=POOL_STALL,
                                                  hash12=cs.signature_hash("hang", POOL_STALL, signature.frames)))
    return signatures


# ---------------------------------------------------------------- the sweep

@dataclasses.dataclass
class Sweep:
    base_red: list[dict] = dataclasses.field(default_factory=list)
    findings: dict[tuple[str, str], dict] = dataclasses.field(default_factory=dict)
    not_counted: list[dict] = dataclasses.field(default_factory=list)
    incomplete: list[dict] = dataclasses.field(default_factory=list)
    runs: list[str] = dataclasses.field(default_factory=list)  # "<base|mode> <package>" done so far


def _target_signatures(mode: str, package: Package, target: str, result: str, text: str) -> list:
    source = f"{package.path}:{target}"
    signatures = cs.signatures_from_text(text, source, process=f"{package.name}PackageTests")
    if mode != "coop-strict":
        return signatures
    # A main-thread hang sample says nothing about the strict pool; the pool thread of a stall does.
    signatures = [s for s in signatures if s.kind != "hang"]
    return signatures + (pool_stall_signatures(text, source) if result == "stalled/timeout" else [])


def classify(sweep: Sweep, mode: str, package: Package, run: LaneRun, base_red: set[str]) -> None:
    counted_kind = COUNTED_KIND[mode]
    if not run.built():
        sweep.incomplete.append({"mode": mode, "package": package.path, "result": run.result(""),
                                 "log": str(run.log)})
        return
    for target in package.tests:
        result = run.result(target)
        text = ANSI.sub("", run.output.get(target, ""))
        place = {"mode": mode, "package": package.path, "target": target, "result": result}
        counted = 0
        for signature in _target_signatures(mode, package, target, result, text):
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
            reason = ("stalled with no cooperative-pool thread in a test-process sample"
                      if mode == "coop-strict" and result == "stalled/timeout"
                      else "red under the mode with no counted report")
            sweep.not_counted.append({**place, "reason": reason, "log": str(run.log)})


def sweep(root: Path, modes: Iterable[str], packages: list[Package], out_dir: Path,
          run_lane: Callable[[Package, Mapping[str, str], Path], LaneRun],
          environ: Mapping[str, str], checkpoint: Callable[[Sweep], None] = lambda _: None) -> Sweep:
    result = Sweep()
    base_runs: dict[str, LaneRun] = {}
    for package in packages:
        run = run_lane(package, mode_environment(environ, None), out_dir / "logs" / "base" / f"{package.name}.log")
        base_runs[package.path] = run
        for target in package.tests:
            if run.result(target) != "passed":
                result.base_red.append({"package": package.path, "target": target, "result": run.result(target),
                                        "log": str(run.log)})
        if not run.built():
            # No suite ran, so no sanitizer pass of this package can be read against a base: no verdict.
            result.incomplete.append({"mode": "base", "package": package.path, "result": run.result(""),
                                      "log": str(run.log)})
        result.runs.append(f"base {package.path}")
        checkpoint(result)
    for mode in modes:
        for package in packages:
            if not base_runs[package.path].built():
                continue
            red = {row["target"] for row in result.base_red if row["package"] == package.path}
            run = run_lane(package, mode_environment(environ, mode), out_dir / "logs" / mode / f"{package.name}.log")
            classify(result, mode, package, run, red)
            result.runs.append(f"{mode} {package.path}")
            checkpoint(result)
    return result


def write_jsonl(path: Path, rows: Iterable[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    with temporary.open("w", encoding="utf-8") as sink:
        for row in rows:
            sink.write(json.dumps(row, sort_keys=True) + "\n")
    temporary.replace(path)


@dataclasses.dataclass(frozen=True)
class Outputs:
    """findings.jsonl (the --out file), base-red.jsonl, not-counted.jsonl and summary.json, in --out's folder."""

    out: Path
    modes: tuple[str, ...]
    suppressions: int
    ref: str

    def findings(self, result: Sweep) -> list[dict]:
        return sorted(result.findings.values(), key=lambda f: (f["mode"], -f["count"], f["hash12"]))

    def write(self, result: Sweep, complete: bool) -> None:
        out_dir = self.out.parent
        findings = self.findings(result)
        write_jsonl(self.out, findings)
        write_jsonl(out_dir / "base-red.jsonl", result.base_red)
        write_jsonl(out_dir / "not-counted.jsonl", result.not_counted)
        summary = {"ref": self.ref, "modes": list(self.modes), "complete": complete, "runs": result.runs,
                   "findings": {mode: sum(1 for f in findings if f["mode"] == mode) for mode in self.modes},
                   "base_red": len(result.base_red), "not_counted": len(result.not_counted),
                   "incomplete": result.incomplete, "tsan_suppressions": self.suppressions}
        summary_path = out_dir / "summary.json"
        temporary = summary_path.with_name("summary.json.tmp")
        temporary.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        temporary.replace(summary_path)


def report(result: Sweep, outputs: Outputs) -> int:
    outputs.write(result, complete=True)
    findings = outputs.findings(result)
    out_dir = outputs.out.parent
    print(f"sanitizer-sweep: base-red suites (red with no sanitizer; listed, not counted): {len(result.base_red)}")
    for row in result.base_red:
        print(f"  {row['package']} {row['target']}: {row['result']}")
    for mode in outputs.modes:
        count = sum(1 for f in findings if f["mode"] == mode)
        print(f"sanitizer-sweep: {mode}: {count} {COUNTED_KIND[mode]} finding(s)")
    for finding in findings:
        print(f"  [{finding['mode']}] {finding['hash12']} {finding['exception']}: {' / '.join(finding['frames'])}"
              f" ({', '.join(finding['targets'])})")
    for row in result.incomplete:
        print(f"sanitizer-sweep: no verdict for {row['package']} under {row['mode']}: {row['result']} ({row['log']})")
    print(f"sanitizer-sweep: {len(result.not_counted)} not counted; TSan suppressions: {outputs.suppressions}")
    print(f"sanitizer-sweep: findings {outputs.out}; base-red {out_dir / 'base-red.jsonl'}; "
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
         resolve: Callable[[Path, Mapping[str, str]], Toolchain] = resolve_toolchain,
         dump: Callable[[Toolchain, Path, Mapping[str, str]], dict] = dump_package,
         run_lane: Callable[[Package, Mapping[str, str], Path], LaneRun] | None = None,
         names: Callable[[], Iterable[str]] | None = None, root: Path = ROOT) -> int:
    environ = dict(os.environ if environ is None else environ)
    try:
        args = parse_args(list(sys.argv[1:] if argv is None else argv))
    except SystemExit as error:
        return 2 if error.code else 0
    try:
        refusal = fleet_host_refusal(environ, platform.system() if system is None else system)
        if refusal:
            raise UsageError(refusal)
        suppressions = check_suppressions(SUPPRESSIONS.read_text(encoding="utf-8"),
                                          names or (lambda: repository_names(root)))
        head = check_ref(root, args.ref)
        toolchain = resolve(root, environ)
        print(f"sanitizer-sweep: Xcode {toolchain.developer_dir}; SDK {toolchain.sdkroot}")
        lane_environ = toolchain.environment(environ)
        packages = [p for p in enumerate_closure(root, lambda path: dump(toolchain, path, environ)) if p.tests]
        if args.package:
            wanted = set(args.package)
            packages = [p for p in packages if p.name in wanted or p.path in wanted]
            if not packages:
                raise UsageError(f"--package {', '.join(args.package)} names no closure package with tests")
        out = args.out if args.out.is_absolute() else root / args.out
        outputs = Outputs(out, tuple(args.modes), len(suppressions), head)
        outputs.write(Sweep(), complete=False)  # no stale file of an earlier run survives a killed step
        lane = run_lane or (lambda package, env, log: run_lane_subprocess(root, package, env, log))
        print(f"sanitizer-sweep: {sum(len(p.tests) for p in packages)} test targets in {len(packages)} packages; "
              f"modes {', '.join(args.modes)}")
        result = sweep(root, args.modes, packages, out.parent, lane, lane_environ,
                       checkpoint=lambda partial: outputs.write(partial, complete=False))
        return report(result, outputs)
    except UsageError as error:
        print(f"sanitizer-sweep: {error}", file=sys.stderr)
        return 2
    except (SweepError, OSError, json.JSONDecodeError) as error:
        print(f"sanitizer-sweep: no verdict: {error}", file=sys.stderr)
        return 3


if __name__ == "__main__":
    sys.exit(main())
