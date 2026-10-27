#!/usr/bin/env python3
"""Absolute and incremental line coverage of a change or a refactor switch (p15-oracle-190).

Spec: plans/cmux-next/chrome-parity/p15-oracle.md (Mutation strength; MQ-coverage-gaps). Stdlib only,
Python 3.9+, safe under `python3 -I`. Linux VM only for collection; a report from tracefiles runs anywhere.
`oracle.py coverage ARGS` runs this script with ARGS.

    coverage.py --base A [--head B] [collection options]       the change MERGE_BASE(A, B)..B
    coverage.py --switch NAME [--head B] [--base A] [...]       the change since the switch was registered
    coverage.py --base A [--head B] --lcov TIER=FILE [--strip PREFIX]...   report from existing tracefiles
Collection options: --tiers daemon,swift (default both; an app switch defaults to swift), --suite S (repeatable;
default `all`, or the switch's `suites`), --jobs N (concurrent daemon runs, default 4), --workers N (swift test
--num-workers, default 200), --out DIR, --json (the report JSON on stdout), --dry-run (print the plan, run nothing).

What runs, all at HEAD only (the base is only the other end of the diff):
- daemon: `linux_run.sh run HEAD --coverage --suite S [--arm NAME=old|new]` per suite (and per arm of a daemon
  switch), through the runnerd queue: cmux-tui built with `-C instrument-coverage`, every case process writing
  counters through LLVM_PROFILE_FILE, merged into RUN_DIR/coverage.profdata. Here: `llvm-profdata merge -sparse`
  of the runs (per arm and all together), then `llvm-cov export -format=lcov` against the instrumented binary,
  with the tools its build receipt names (the SHA's own rustc LLVM).
- swift: a detached worktree of HEAD under /tmp/oracle-cov, its app FFI (`build-app-ffi.sh --linux`), then the
  HEAD's own `swift-tier.sh --scratch /tmp/oracle-cov/swift -- build --build-tests --enable-code-coverage` and
  `-- test --skip-build --enable-code-coverage --parallel`, then the toolchain's llvm-profdata and llvm-cov over
  the tier's test bundle. A tier that does not build gives no Swift coverage and says so (swift-tier.sh --all
  names its red targets). The worktree is removed at the end; the scratch stays as the next run's build cache.

The change is `git diff -U0 -M MERGE_BASE HEAD`: added and modified lines of the head, renames without their
unchanged lines. For a switch, MERGE_BASE is the parent of the commit that added
plans/cmux-next/refactor-switches/NAME.json (the new arm lands after its switch), unless --base is given; a daemon
switch runs its suites at both arms and the report gives each arm's incremental coverage beside the union.

Report (OUT/coverage.json, schema cmux-oracle-coverage-v1, and text on stdout):
- incremental: per changed file, its changed executable lines and how many ran; the total over the change;
- absolute: per changed file, all its executable lines and how many ran;
- uncovered hunks: `path:A-B` (or `path:A`) for every run of changed executable lines that never ran, bridging
  changed lines with no code (comments, blank lines) and split by a line that ran;
- unmeasured: changed .rs and .swift files no tier instrumented (not in the daemon binary or the Linux tier).
It is a report, not a gate: low numbers never change the exit code.
Exit codes: 0 a report; 2 bad arguments or a missing tool; 3 no tier produced coverage (the report says why).

Chrome reference (chromium/src):
- docs/testing/code_coverage_in_gerrit.md: absolute coverage of each file a CL touches and incremental coverage
  of the lines it changes, shown on the CL as information, not a submit requirement.
- docs/testing/code_coverage.md, tools/code_coverage/coverage.py: -fprofile-instr-generate -fcoverage-mapping,
  LLVM_PROFILE_FILE with a %Nm merge pool, `llvm-profdata merge -sparse`, `llvm-cov export`.
- testing/merge_scripts/code_coverage/merge_results.py: the profiles of every shard merge into one before export.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import datetime as dt
import fcntl
import json
import os
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Dict, Iterable, List, Mapping, Optional, Sequence, Tuple

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
SCHEMA = "cmux-oracle-coverage-v1"
TIERS = ("daemon", "swift")
MEASURED_SUFFIXES = (".rs", ".swift")
SWITCH_DIR = "plans/cmux-next/refactor-switches"
COV_ROOT = Path("/tmp/oracle-cov")
SWIFT_SCRATCH = COV_ROOT / "swift"
BUILD_TIMEOUT = 7200
TEST_TIMEOUT = 7200
EXIT_OK, EXIT_USAGE, EXIT_NO_COVERAGE = 0, 2, 3

# path -> line -> execution count, for the lines a tier instruments.
Trace = Dict[str, Dict[int, int]]
Hunk = Tuple[int, int]


class UsageError(Exception):
    """A bad argument, a ref that is not a commit, a missing tool: exit 2."""


# ---- tracefiles ------------------------------------------------------------------------------


def repo_path(path: str, strip: Sequence[str]) -> Optional[str]:
    """`path` relative to the checkout, or None for a file outside it (std, the cargo registry, SwiftPM checkouts)."""
    if not os.path.isabs(path):
        return os.path.normpath(path)
    for prefix in strip:
        root = prefix.rstrip("/") + "/"
        if path.startswith(root):
            return os.path.normpath(path[len(root):])
    return None


def parse_lcov(text: str, strip: Sequence[str] = ()) -> Trace:
    """The DA records of an lcov tracefile; a file in several records sums its counts."""
    trace: Trace = {}
    current: Optional[Dict[int, int]] = None
    for raw in text.splitlines():
        line = raw.strip()
        if line.startswith("SF:"):
            path = repo_path(line[3:], strip)
            current = None if path is None else trace.setdefault(path, {})
        elif line.startswith("DA:") and current is not None:
            fields = line[3:].split(",")
            if len(fields) < 2:
                raise UsageError(f"bad lcov line {raw!r}")
            number, count = int(fields[0]), int(float(fields[1]))
            current[number] = current.get(number, 0) + count
        elif line == "end_of_record":
            current = None
    return trace


def merge_traces(traces: Iterable[Trace]) -> Trace:
    merged: Trace = {}
    for trace in traces:
        for path, lines in trace.items():
            into = merged.setdefault(path, {})
            for number, count in lines.items():
                into[number] = into.get(number, 0) + count
    return merged


# ---- the change ------------------------------------------------------------------------------


HUNK_RE = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@")


def unquote_path(path: str) -> str:
    """A path as git prints it: C-quoted (octal UTF-8 bytes) when it has unusual characters."""
    if not (path.startswith('"') and path.endswith('"')):
        return path
    return path[1:-1].encode("latin-1").decode("unicode_escape").encode("latin-1").decode("utf-8")


def parse_diff(text: str) -> Dict[str, List[Hunk]]:
    """The added-line ranges (inclusive, head line numbers) per head path of a `git diff -U0` text."""
    changed: Dict[str, List[Hunk]] = {}
    path: Optional[str] = None
    for line in text.splitlines():
        if line.startswith("+++ "):
            # git ends a name that has a space with a tab; a name with a tab of its own is C-quoted.
            target = line[4:].removesuffix("\t")
            path = None if target == "/dev/null" else unquote_path(target)
            if path is not None and path.startswith("b/"):
                path = path[2:]
        elif line.startswith("@@") and path is not None:
            match = HUNK_RE.match(line)
            if not match:
                raise UsageError(f"bad hunk header {line!r}")
            start, count = int(match.group(1)), int(match.group(2) or "1")
            if count:
                changed.setdefault(path, []).append((start, start + count - 1))
    return changed


def git(repo: Path, *args: str) -> str:
    result = subprocess.run(["git", "-C", str(repo), "-c", "core.quotePath=false", *args], check=False,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if result.returncode != 0:
        raise UsageError(f"git {' '.join(args)}: {result.stderr.strip()}")
    return result.stdout


def resolve(repo: Path, ref: str) -> str:
    return git(repo, "rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}").strip()


def changed_lines(repo: Path, merge_base: str, head: str) -> Dict[str, List[Hunk]]:
    # Explicit prefixes: diff.noprefix or diff.mnemonicPrefix in the person's config would change them.
    text = git(repo, "diff", "--no-color", "--no-ext-diff", "--src-prefix=a/", "--dst-prefix=b/", "-U0", "-M",
               "--diff-filter=AMR", merge_base, head)
    return parse_diff(text)


# ---- switches --------------------------------------------------------------------------------


@dataclass(frozen=True)
class Switch:
    name: str
    kind: str  # daemon | app
    key: str
    suites: Tuple[str, ...]
    registered: str  # the commit that added the registry file

    def arms(self) -> Tuple[str, ...]:
        """The daemon runs' --arm values: both arms of a daemon switch; the app arms are not on Linux."""
        return (f"{self.name}=old", f"{self.name}=new") if self.kind == "daemon" else ("-",)


def load_switch(repo: Path, name: str, head: str) -> Switch:
    if not re.fullmatch(r"[a-z][a-z0-9-]{0,63}", name):
        raise UsageError(f"--switch {name!r}: not a switch name")
    path = f"{SWITCH_DIR}/{name}.json"
    try:
        doc = json.loads(git(repo, "show", f"{head}:{path}"))
    except UsageError:
        raise UsageError(f"--switch {name}: no {path} at {head[:12]}") from None
    if "daemon_key" in doc:
        kind, key = "daemon", doc["daemon_key"]
    elif "app_key" in doc:
        kind, key = "app", doc["app_key"]
    else:
        raise UsageError(f"{path} has neither daemon_key nor app_key (switches.py --check)")
    added = git(repo, "log", "-1", "--format=%H", "--diff-filter=A", head, "--", path).strip()
    if not added:
        raise UsageError(f"{path} was never added in the history of {head[:12]}")
    return Switch(name, kind, key, tuple(doc.get("suites") or ("all",)), added)


# ---- the report ------------------------------------------------------------------------------


def uncovered_hunks(hunks: Sequence[Hunk], lines: Mapping[int, int]) -> List[Hunk]:
    """Runs of changed executable lines that never ran, within one diff hunk each, bridging lines with no code."""
    found: List[Hunk] = []
    for start, end in hunks:
        run: Optional[List[int]] = None
        for number in range(start, end + 1):
            if number not in lines:
                continue
            if lines[number] > 0:
                if run:
                    found.append((run[0], run[1]))
                run = None
            elif run is None:
                run = [number, number]
            else:
                run[1] = number
        if run:
            found.append((run[0], run[1]))
    return found


def hunk_label(path: str, hunk: Hunk) -> str:
    return f"{path}:{hunk[0]}" if hunk[0] == hunk[1] else f"{path}:{hunk[0]}-{hunk[1]}"


def counts(lines: Mapping[int, int], only: Optional[Iterable[int]] = None) -> Dict[str, int]:
    numbers = list(lines) if only is None else [n for n in only if n in lines]
    return {"covered": sum(1 for n in numbers if lines[n] > 0), "executable": len(numbers)}


def changed_numbers(hunks: Sequence[Hunk]) -> List[int]:
    return [n for start, end in hunks for n in range(start, end + 1)]


def build_report(changed: Mapping[str, Sequence[Hunk]], tiers: Mapping[str, Trace],
                 arms: Optional[Mapping[str, Trace]] = None) -> Dict[str, object]:
    """Per-file absolute and incremental coverage of `changed` from each tier's trace (the first tier that
    instruments a file measures it); `arms` adds each arm's incremental numbers for files in its trace."""
    files: List[Dict[str, object]] = []
    unmeasured: List[str] = []
    skipped = 0
    total = {"covered": 0, "executable": 0}
    hunks_out: List[str] = []
    for path in sorted(changed):
        hunks = changed[path]
        tier = next((name for name, trace in tiers.items() if path in trace), None)
        if tier is None:
            if path.endswith(MEASURED_SUFFIXES):
                unmeasured.append(path)
            else:
                skipped += 1
            continue
        lines = tiers[tier][path]
        incremental = counts(lines, changed_numbers(hunks))
        uncovered = uncovered_hunks(hunks, lines)
        entry: Dict[str, object] = {
            "path": path,
            "tier": tier,
            "absolute": counts(lines),
            "incremental": incremental,
            "uncovered": [list(h) for h in uncovered],
        }
        if arms:
            entry["arms"] = {arm: counts(trace[path], changed_numbers(hunks))
                             for arm, trace in arms.items() if path in trace}
        files.append(entry)
        for key in total:
            total[key] += incremental[key]
        hunks_out.extend(hunk_label(path, h) for h in uncovered)
    absolute = {"covered": 0, "executable": 0}
    for entry in files:
        for key in absolute:
            absolute[key] += entry["absolute"][key]  # type: ignore[index]
    return {
        "incremental": total,
        "absolute": absolute,
        "files": files,
        "uncoveredHunks": hunks_out,
        "unmeasured": unmeasured,
        "notCode": skipped,
    }


def percent(pair: Mapping[str, int]) -> str:
    if not pair["executable"]:
        return "-"
    return f"{100.0 * pair['covered'] / pair['executable']:.1f}%"


def fraction(pair: Mapping[str, int]) -> str:
    return f"{pair['covered']}/{pair['executable']} {percent(pair)}"


def render_text(doc: Mapping[str, object]) -> str:
    report = doc["report"]  # type: ignore[assignment]
    head, merge_base = str(doc["head"]), str(doc["mergeBase"])
    out = [f"coverage of {merge_base[:12]}..{head[:12]} (a report, not a gate)"]
    switch = doc.get("switch")
    if switch:
        out.append(f"switch {switch['name']} ({switch['kind']} key {switch['key']}), registered in "  # type: ignore[index]
                   f"{str(switch['registered'])[:12]}")  # type: ignore[index]
    for tier in doc["tiers"]:  # type: ignore[union-attr]
        state = "measured" if tier.get("lcov") else "no coverage"
        out.append(f"tier {tier['name']}: {state}" + "".join(f"; {note}" for note in tier.get("notes", [])))
    out.append(f"incremental: {fraction(report['incremental'])} of the changed executable lines ran")
    out.append(f"absolute (changed files): {fraction(report['absolute'])}")
    if report["files"]:
        width = max(len(str(f["path"])) for f in report["files"])
        out.append("")
        out.append(f"{'file'.ljust(width)}  {'incremental':>18}  {'absolute':>20}  tier")
        for entry in report["files"]:
            arms = entry.get("arms") or {}
            arm_text = "".join(f"  {arm} {fraction(pair)}" for arm, pair in sorted(arms.items()))
            out.append(f"{str(entry['path']).ljust(width)}  {fraction(entry['incremental']):>18}  "
                       f"{fraction(entry['absolute']):>20}  {entry['tier']}{arm_text}")
    if report["uncoveredHunks"]:
        out.append("")
        out.extend(f"uncovered {label}" for label in report["uncoveredHunks"])
    if report["unmeasured"]:
        out.append("")
        out.append("not measured (no Linux tier instruments them):")
        out.extend(f"  {path}" for path in report["unmeasured"])
    return "\n".join(out) + "\n"


# ---- collection ------------------------------------------------------------------------------


Run = Callable[..., subprocess.CompletedProcess]


@dataclass
class TierResult:
    name: str
    lcov: Optional[str] = None
    strip: List[str] = field(default_factory=list)
    arms: Dict[str, str] = field(default_factory=dict)  # arm -> lcov
    notes: List[str] = field(default_factory=list)
    detail: Dict[str, object] = field(default_factory=dict)

    def record(self) -> Dict[str, object]:
        return {"name": self.name, "lcov": self.lcov, "strip": self.strip, "arms": self.arms,
                "notes": self.notes, **self.detail}


def last_line(text: str) -> str:
    lines = [line for line in text.splitlines() if line.strip()]
    return lines[-1].strip() if lines else ""


def call(run: Run, argv: Sequence[str], *, cwd: Path, timeout: float,
         stdout_to: Optional[Path] = None) -> subprocess.CompletedProcess:
    """`argv` under nice, its stderr passed through; stdout captured, or written to `stdout_to`."""
    command = ["nice", "-n", "10", *argv]
    if stdout_to is None:
        return run(command, cwd=str(cwd), timeout=timeout, check=False, stdout=subprocess.PIPE, text=True)
    with open(stdout_to, "w", encoding="utf-8") as handle:
        return run(command, cwd=str(cwd), timeout=timeout, check=False, stdout=handle, text=True)


def export_lcov(run: Run, tools: Mapping[str, str], profiles: Sequence[Path], objects: Sequence[str],
                profdata: Path, lcov: Path) -> None:
    merged = call(run, [tools["llvmProfdata"], "merge", "-sparse", "--failure-mode=all", "-o", str(profdata),
                        *map(str, profiles)], cwd=profdata.parent, timeout=BUILD_TIMEOUT)
    if merged.returncode != 0:
        raise RuntimeError(f"llvm-profdata merge exited {merged.returncode}")
    argv = [tools["llvmCov"], "export", "-format=lcov", "--skip-branches", f"-instr-profile={profdata}",
            objects[0], *(f"-object={obj}" for obj in objects[1:])]
    exported = call(run, argv, cwd=profdata.parent, timeout=BUILD_TIMEOUT, stdout_to=lcov)
    if exported.returncode != 0:
        raise RuntimeError(f"llvm-cov export exited {exported.returncode}")


def daemon_plan(head: str, suites: Sequence[str], arms: Sequence[str]) -> List[List[str]]:
    script = str(HERE / "linux_run.sh")
    plan = []
    for suite in suites:
        for arm in arms:
            argv = ["bash", script, "run", head, "--coverage", "--suite", suite]
            if arm != "-":
                argv += ["--arm", arm]
            plan.append(argv)
    return plan


def collect_daemon(run: Run, repo: Path, head: str, suites: Sequence[str], arms: Sequence[str], out: Path,
                   jobs: int) -> TierResult:
    result = TierResult("daemon")
    build = call(run, ["bash", str(HERE / "linux_run.sh"), "build", head, "--coverage"], cwd=repo,
                 timeout=BUILD_TIMEOUT)
    binary = last_line(build.stdout or "")
    receipt_path = Path(binary).parent / "build.json"
    if build.returncode != 0 or not binary or not receipt_path.is_file():
        result.notes.append(f"the instrumented build of {head[:12]} failed (exit {build.returncode})")
        return result
    receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
    tools = receipt.get("coverage") or {}
    if not tools.get("llvmProfdata"):
        result.notes.append(f"{receipt_path} is not an instrumented build")
        return result
    result.strip = [tools["sourceRoot"]]
    plan = daemon_plan(head, suites, arms)
    runs: List[Dict[str, object]] = []

    def one(argv: List[str]) -> Dict[str, object]:
        done = call(run, argv, cwd=repo, timeout=BUILD_TIMEOUT + TEST_TIMEOUT)
        run_dir = last_line(done.stdout or "")
        profile = Path(run_dir) / "coverage.profdata" if run_dir else None
        suite = argv[argv.index("--suite") + 1]
        arm = argv[argv.index("--arm") + 1] if "--arm" in argv else "-"
        return {"suite": suite, "arm": arm, "exit": done.returncode, "runDir": run_dir or None,
                "profdata": str(profile) if profile and profile.is_file() else None}

    with concurrent.futures.ThreadPoolExecutor(max(1, jobs)) as pool:
        runs = list(pool.map(one, plan))
    result.detail = {"binary": binary, "build": str(receipt_path), "runs": runs}
    for entry in runs:
        if entry["exit"]:
            result.notes.append(f"suite {entry['suite']} arm {entry['arm']}: oracle exit {entry['exit']} "
                                "(its counters still count)")
        if not entry["profdata"]:
            result.notes.append(f"suite {entry['suite']} arm {entry['arm']}: no counters")
    profiles = {arm: [Path(str(e["profdata"])) for e in runs if e["arm"] == arm and e["profdata"]] for arm in arms}
    every = [p for ps in profiles.values() for p in ps]
    if not every:
        return result
    try:
        if len(arms) > 1:
            for arm, paths in profiles.items():
                if paths:
                    side = arm.split("=", 1)[-1]
                    lcov = out / f"daemon-{side}.lcov"
                    export_lcov(run, tools, paths, [binary], out / f"daemon-{side}.profdata", lcov)
                    result.arms[side] = str(lcov)
        export_lcov(run, tools, every, [binary], out / "daemon.profdata", out / "daemon.lcov")
        result.lcov = str(out / "daemon.lcov")
    except (RuntimeError, OSError, subprocess.TimeoutExpired) as error:
        result.notes.append(f"export: {error}")
    return result


def swift_tools(run: Run) -> Dict[str, str]:
    """llvm-profdata and llvm-cov of the Swift toolchain that swift-tier.sh runs (SWIFT, else swift on PATH)."""
    swift = os.environ.get("SWIFT") or shutil.which("swift") or "swift"
    info = run([swift, "-print-target-info"], check=False, stdout=subprocess.PIPE, text=True, timeout=120)
    if info.returncode != 0:
        raise UsageError(f"{swift} -print-target-info exited {info.returncode} (scripts/cmux-next/linux/setup-swift.sh)")
    resource = Path(json.loads(info.stdout)["paths"]["runtimeResourcePath"])  # <toolchain>/usr/lib/swift
    bin_dir = resource.parent.parent / "bin"
    tools = {"llvmProfdata": str(bin_dir / "llvm-profdata"), "llvmCov": str(bin_dir / "llvm-cov")}
    for path in tools.values():
        if not os.access(path, os.X_OK):
            raise UsageError(f"{path}: not in the Swift toolchain")
    return tools


def swift_plan(worktree: Path, workers: int) -> List[List[str]]:
    tier = ["bash", str(worktree / "scripts/cmux-next/linux/swift-tier.sh"), "--scratch", str(SWIFT_SCRATCH), "--"]
    return [
        tier + ["build", "--build-tests", "--enable-code-coverage", "-j", "240"],
        tier + ["build", "--show-bin-path", "--enable-code-coverage"],
        tier + ["test", "--skip-build", "--enable-code-coverage", "--parallel", "--num-workers", str(workers)],
    ]


def collect_swift(run: Run, repo: Path, head: str, out: Path, workers: int, tools: Mapping[str, str]) -> TierResult:
    src = SWIFT_SCRATCH / "src"
    # swift-tier.sh compiles in the realpath of its scratch.
    result = TierResult("swift", strip=sorted({str(src), os.path.realpath(src)}))
    COV_ROOT.mkdir(parents=True, exist_ok=True)
    # swift-tier.sh locks its scratch per command; this lock holds it from the sync to the export.
    with open(COV_ROOT / "swift.lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        worktree = COV_ROOT / f"wt-{head[:12]}-{os.getpid()}"
        git(repo, "worktree", "add", "--detach", "--quiet", str(worktree), head)
        try:
            return swift_in_worktree(run, worktree, tools, head, out, workers, result)
        finally:
            git(repo, "worktree", "remove", "--force", str(worktree))


def swift_in_worktree(run: Run, worktree: Path, tools: Mapping[str, str], head: str, out: Path, workers: int,
                      result: TierResult) -> TierResult:
    ffi = worktree / "scripts/cmux-next/build-app-ffi.sh"
    if ffi.is_file():
        built = call(run, ["bash", str(ffi), "--linux"], cwd=worktree, timeout=BUILD_TIMEOUT)
        if built.returncode != 0:
            result.notes.append(f"build-app-ffi.sh --linux exited {built.returncode} at {head[:12]}")
            return result
    build, bin_path, test = swift_plan(worktree, workers)
    built = call(run, build, cwd=worktree, timeout=BUILD_TIMEOUT)
    if built.returncode != 0:
        result.notes.append(f"the Swift tier does not build at {head[:12]} (swift-tier.sh --all names the red targets)")
        return result
    bin_dir = Path(last_line(call(run, bin_path, cwd=worktree, timeout=600).stdout or ""))
    codecov = bin_dir / "codecov"
    for stale in codecov.glob("*.profraw"):
        stale.unlink()
    tested = call(run, test, cwd=worktree, timeout=TEST_TIMEOUT)
    result.detail = {"testExit": tested.returncode, "binPath": str(bin_dir)}
    if tested.returncode != 0:
        result.notes.append(f"swift test exited {tested.returncode} (its counters still count)")
    profiles = sorted(codecov.glob("*.profraw"))
    bundles = sorted(str(p) for p in bin_dir.glob("*.xctest") if p.is_file())
    if not profiles or not bundles:
        result.notes.append(f"no counters or no test bundle in {bin_dir}")
        return result
    try:
        export_lcov(run, tools, profiles, bundles, out / "swift.profdata", out / "swift.lcov")
        result.lcov = str(out / "swift.lcov")
    except (RuntimeError, OSError, subprocess.TimeoutExpired) as error:
        result.notes.append(f"export: {error}")
    return result


# ---- main ------------------------------------------------------------------------------------


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(prog="coverage.py", description=__doc__.split("\n\n")[0])
    parser.add_argument("--base", help="the change's base ref (its merge base with --head is the diff's base)")
    parser.add_argument("--head", default="HEAD", help="the measured ref (default HEAD)")
    parser.add_argument("--switch", help="a refactor switch: the change since its registry file was added")
    parser.add_argument("--tiers", help="comma-separated: daemon, swift (default both; swift for an app switch)")
    parser.add_argument("--suite", action="append", default=[], help="daemon suite (repeatable)")
    parser.add_argument("--jobs", type=int, default=4, help="daemon runs submitted at once")
    parser.add_argument("--workers", type=int, default=200, help="swift test --num-workers")
    parser.add_argument("--lcov", action="append", default=[], metavar="TIER=FILE",
                        help="report from this tracefile instead of collecting (repeatable)")
    parser.add_argument("--strip", action="append", default=[], metavar="PREFIX",
                        help="with --lcov: the source root to strip from absolute paths (repeatable)")
    parser.add_argument("--out", help="output dir (default /tmp/oracle/coverage/<head>-<time>-<pid>)")
    parser.add_argument("--repo", default=str(REPO), help=argparse.SUPPRESS)
    parser.add_argument("--json", action="store_true", help="print the report JSON instead of the text")
    parser.add_argument("--dry-run", action="store_true", help="print the plan and run nothing")
    args = parser.parse_args(argv)
    if not args.base and not args.switch:
        parser.error("give --base or --switch")
    if args.jobs < 1 or args.workers < 1:
        parser.error("--jobs and --workers are positive")
    if args.strip and not args.lcov:
        parser.error("--strip goes with --lcov")
    return args


def output_dir(args: argparse.Namespace, repo: Path, head: str) -> Path:
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    out = Path(args.out or f"/tmp/oracle/coverage/{head[:12]}-{stamp}-{os.getpid()}").resolve()
    if out == repo or repo in out.parents:
        raise UsageError(f"--out {out}: output stays outside the checkout")
    return out


def tiers_of(args: argparse.Namespace, switch: Optional[Switch]) -> Tuple[str, ...]:
    if args.tiers:
        names = tuple(t for t in args.tiers.split(",") if t)
        unknown = [t for t in names if t not in TIERS]
        if unknown or not names:
            raise UsageError(f"--tiers {args.tiers}: one or more of {', '.join(TIERS)}")
        return names
    return ("swift",) if switch and switch.kind == "app" else TIERS


def main(argv: Optional[Sequence[str]] = None, run: Run = subprocess.run) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        return report_main(args, run)
    except UsageError as error:
        print(f"coverage.py: {error}", file=sys.stderr)
        return EXIT_USAGE


def report_main(args: argparse.Namespace, run: Run) -> int:
    repo = Path(args.repo).resolve()
    head = resolve(repo, args.head)
    if not head:
        raise UsageError(f"--head {args.head}: not a commit")
    switch = load_switch(repo, args.switch, head) if args.switch else None
    base_ref = args.base or f"{switch.registered}^"  # type: ignore[union-attr]
    base = resolve(repo, base_ref)
    if not base:
        raise UsageError(f"base {base_ref}: not a commit")
    merge_base = git(repo, "merge-base", base, head).strip()
    tiers = tiers_of(args, switch)
    suites = tuple(args.suite) or (switch.suites if switch else ("all",))
    arms = switch.arms() if switch else ("-",)
    if args.dry_run:
        print(f"change {merge_base[:12]}..{head[:12]}; tiers {','.join(tiers)}")
        if "daemon" in tiers and not args.lcov:
            for argv in daemon_plan(head, suites, arms):
                print(" ".join(argv))
        if "swift" in tiers and not args.lcov:
            print(f"git worktree add --detach {COV_ROOT}/wt-{head[:12]}-PID {head}")
            for argv in swift_plan(COV_ROOT / f"wt-{head[:12]}-PID", args.workers):
                print(" ".join(argv))
        return EXIT_OK

    out = output_dir(args, repo, head)
    out.mkdir(parents=True, exist_ok=True)
    results: List[TierResult] = []
    if args.lcov:
        for spec in args.lcov:
            name, sep, path = spec.partition("=")
            if not sep or not name or not Path(path).is_file():
                raise UsageError(f"--lcov {spec}: TIER=FILE with an existing file")
            results.append(TierResult(name, lcov=str(Path(path).resolve()), strip=list(args.strip)))
    else:
        if sys.platform != "linux":
            raise UsageError("collection runs on the Linux VM only (linux_run.sh, swift-tier.sh); "
                             "use --lcov for a report from tracefiles")
        # A missing toolchain is a usage error before anything is queued.
        tools = swift_tools(run) if "swift" in tiers else {}
        with concurrent.futures.ThreadPoolExecutor(2) as pool:
            futures = []
            if "daemon" in tiers:
                futures.append(pool.submit(collect_daemon, run, repo, head, suites, arms, out, args.jobs))
            if "swift" in tiers:
                futures.append(pool.submit(collect_swift, run, repo, head, out, args.workers, tools))
            results = [future.result() for future in futures]

    traces: Dict[str, Trace] = {}
    arm_traces: Dict[str, Trace] = {}
    for result in results:
        if result.lcov:
            traces[result.name] = merge_traces([traces.get(result.name, {}),
                                                parse_lcov(Path(result.lcov).read_text(encoding="utf-8"),
                                                           result.strip)])
        for arm, path in result.arms.items():
            arm_traces[arm] = parse_lcov(Path(path).read_text(encoding="utf-8"), result.strip)
    changed = changed_lines(repo, merge_base, head)
    doc = {
        "schema": SCHEMA,
        "base": base,
        "head": head,
        "mergeBase": merge_base,
        "switch": None if switch is None else {"name": switch.name, "kind": switch.kind, "key": switch.key,
                                               "registered": switch.registered, "arms": list(arms),
                                               "suites": list(suites)},
        "tiers": [result.record() for result in results],
        "report": build_report(changed, traces, arm_traces or None),
    }
    with open(out / "coverage.json", "w", encoding="utf-8") as handle:
        json.dump(doc, handle, indent=2, sort_keys=True)
        handle.write("\n")
    text = render_text(doc)
    (out / "report.txt").write_text(text, encoding="utf-8")
    sys.stdout.write(json.dumps(doc, indent=2, sort_keys=True) + "\n" if args.json else text)
    print(f"coverage.py: {out / 'coverage.json'}", file=sys.stderr)
    return EXIT_OK if traces else EXIT_NO_COVERAGE


if __name__ == "__main__":
    sys.exit(main())
