#!/usr/bin/env python3
"""Linux Swift runner helper: plan, compiler-error queue, receipt (stdlib only, safe under `python3 -I`).

swift-tier.sh and swift-shared.sh run SwiftPM; this file does every decision that needs parsing:

    plan            ordered tier targets (sources, then tests) with their local dependencies and
                    the Skip flag from tests/oracle expectations
    shared-packages the Shared/iOS packages the shared runner covers (MQ-shared-packages rule), each
                    with the Skip flag from tests/oracle expectations
    receipt         reads the runner's ledger, logs and xunit files; writes the receipt and the
                    compiler-error queue; exits 1 on any failure no `[ linux ]` line expects
    selftest        parser, cluster, plan and receipt tests on fixtures

The queue copies Bun's (Jarred's) method for a port: build, collect every compiler error, cut the
errors into tasks of one file cluster of at most 400 lines in one target, hand each task to an agent.
Chrome's equivalent is the per-step failure list of a CQ builder: each failing compile step is one
line, and a failure is a red only when no TestExpectations line expects it
(third_party/blink/tools/blinkpy/web_tests/models/test_expectations.py).

Expectations: tests/oracle/Expectations.d/<suite>.txt with suites `swift-tier` and `swift-shared`.
A case is a target (tier) or a package (shared). A step is one test with the `()` dropped:
`Suite.test` in the tier (the case is the test module), `Module.Suite.test` in the shared runner. Only lines tagged `linux` count, so a mac line never excuses a Linux red.

Ledger (one TSV line per step, written by the runner):
    suite  case  kind  status  exit  seconds  log  xunit  detail
kind: phase setup missing build build-test package test incremental; status: pass fail timeout blocked skip.
`setup` steps (resolve, plan, dump-package, test-product link) have no target; a failed one is a red like a target.
`detail` of a blocked step names the step that blocked it.

Reds besides failed builds and tests: a target blocked by a dependency whose failure a line expects (or
that a Skip line names) is a red unless it has its own line, so one line on a root cannot quietly take
its dependents out of the tier; a test target that ran without one parsed test result; a failed or
timed-out --measure-incremental build, and one over INCREMENTAL_BUDGET_SECONDS.
"""

from __future__ import annotations

import argparse
import contextlib
import dataclasses
import hashlib
import io
import json
import re
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Iterable, Sequence

REPO_ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO_ROOT / "scripts" / "cmux-next" / "oracle"))

import expectations as oracle_exp  # noqa: E402  (path set above; -I drops the script dir)

CLUSTER_MAX_LINES = 400
LINUX_SHARE_BUDGET = 0.05
INCREMENTAL_BUDGET_SECONDS = 30.0
RECEIPT_SCHEMA = "cmux-linux-swift-receipt/1"

SOURCE_KINDS = ("regular", "executable", "macro")
SHARED_GROUPS = ("Packages/Shared", "Packages/iOS")
SHARED_EXTRA = ("Packages/macOS/CmuxPhonePush",)
SHARED_EXCLUDED = frozenset({"CmuxHomeRender", "CmuxAppAttest", "CmuxUpdater"})
SHARED_UI_FILE_LIMIT = 2
UI_IMPORT_RE = re.compile(
    r"^\s*(?:@[A-Za-z_]+ )*(?:public |package |internal )?import "
    r"(?:AppKit|UIKit|SwiftUI|WebKit|QuartzCore|CoreText|CoreImage|AVFoundation|DeviceCheck|Sparkle|WebRTC|VideoToolbox)\b",
    re.M,
)

ANSI_RE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
FILE_ERROR_RE = re.compile(
    r"^(?P<path>/[^:\n]+?):(?P<line>\d+):(?:(?P<col>\d+):)? (?:fatal )?error: (?P<msg>.+)$"
)
LOOSE_ERROR_RE = re.compile(r"^(?:fatal )?error: (?P<msg>.+)$")
# A Swift runtime trap (`try!`, precondition) in SwiftPM itself or in a test process.
FATAL_RE = re.compile(r"^(?P<where>\S+:\d+): Fatal error: (?P<msg>.+)$")
# A file inside a SwiftPM dependency checkout: `<scratch>/checkouts/<package>/...`.
CHECKOUT_RE = re.compile(r"(?:^|/)checkouts/(?P<pkg>[^/]+)/(?P<rest>.+)$")
DEPENDENCY_SAMPLE = 5
LINK_ERROR_RE = re.compile(r"undefined reference to [`'](?P<sym>[^`']+)'")
# compiler-rt report summaries: `SUMMARY: ThreadSanitizer: data race /path/File.swift:12:3 in f()`.
SANITIZER_RE = re.compile(r"^SUMMARY: (?P<tool>\w+Sanitizer): (?P<rest>.+)$")
NOISE_PREFIXES = (
    "fatalError",
    "emit-module command failed",
    "compile command failed due to signal",  # kept below when nothing else explains the failure
    "build had ",
)
TARGET_PATH_RE = re.compile(r"^(?P<pkg_path>Packages/[^/]+/(?P<pkg>[^/]+))/(?:Sources|Tests)/(?P<target>[^/]+)/")
STEP_CHAR_RE = re.compile(r"[^A-Za-z0-9._-]+")


# ------------------------------------------------------------------------------------------ model


@dataclasses.dataclass(frozen=True)
class CompileError:
    path: str  # repo-relative when the file is in the checkout, else absolute
    line: int
    col: int
    message: str


@dataclasses.dataclass(frozen=True)
class TestResult:
    step: str
    status: str  # pass fail skip
    message: str = ""


@dataclasses.dataclass(frozen=True)
class LedgerRecord:
    suite: str
    case: str
    kind: str
    status: str
    exit: int
    seconds: float
    log: str
    xunit: str
    detail: str = ""

    @classmethod
    def parse(cls, line: str) -> "LedgerRecord":
        parts = line.rstrip("\n").split("\t")
        parts += [""] * (9 - len(parts))
        suite, case, kind, status, code, seconds, log, xunit, detail = parts[:9]
        return cls(suite, case, kind, status, int(code or 0), float(seconds or 0), log, xunit, detail)


def read_ledger(path: Path) -> list[LedgerRecord]:
    if not path.is_file():
        return []
    return [LedgerRecord.parse(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


# --------------------------------------------------------------------------------------- parsing


def step_name(classname: str, name: str, module: str) -> str:
    """`Module.Suite/Inner` + `test()` -> `Suite.Inner.test`; the expectations step for one test."""
    suite = classname
    if module and (suite == module or suite.startswith(module + ".")):
        suite = suite[len(module) + 1 :]
    test = name[:-2] if name.endswith("()") else name
    raw = f"{suite}.{test}" if suite else test
    text = STEP_CHAR_RE.sub("_", raw.replace("/", ".")).strip("._-")
    return text or "unnamed"


def parse_xunit(path: Path, module: str) -> list[TestResult]:
    """XCTest and swift-testing xunit files (`X.xml` and `X-swift-testing.xml`)."""
    results: list[TestResult] = []
    for candidate in (path, path.with_name(path.stem + "-swift-testing" + path.suffix)):
        if not candidate.is_file():
            continue
        try:
            root = ET.parse(candidate).getroot()
        except ET.ParseError:
            continue
        for case in root.iter("testcase"):
            step = step_name(case.get("classname", ""), case.get("name", ""), module)
            failure = case.find("failure")
            if failure is None:
                failure = case.find("error")
            if failure is not None:
                results.append(TestResult(step, "fail", (failure.get("message") or failure.text or "").strip()[:300]))
            elif case.find("skipped") is not None:
                results.append(TestResult(step, "skip"))
            else:
                results.append(TestResult(step, "pass"))
    return results


def relativize(path: str, prefixes: Sequence[str]) -> str:
    m = CHECKOUT_RE.search(path)
    if m:
        return f"checkouts/{m['pkg']}/{m['rest']}"  # one name for the checkout, whichever build dir holds it
    for prefix in prefixes:
        root = prefix.rstrip("/") + "/"
        if path.startswith(root):
            return path[len(root) :]
    return path


def parse_log(text: str, prefixes: Sequence[str]) -> tuple[list[CompileError], list[str]]:
    """File errors (deduplicated, in log order) and loose errors (no file: SwiftPM, linker)."""
    errors: dict[tuple[str, int, int, str], CompileError] = {}
    loose: dict[str, None] = {}
    for raw in text.splitlines():
        line = ANSI_RE.sub("", raw).rstrip()
        m = FILE_ERROR_RE.match(line)
        if m:
            err = CompileError(relativize(m["path"], prefixes), int(m["line"]), int(m["col"] or 0), m["msg"].strip())
            errors.setdefault((err.path, err.line, err.col, err.message), err)
            continue
        m = FATAL_RE.match(line)
        if m:
            loose.setdefault(f"Fatal error at {m['where']}: {relativize_words(m['msg'].strip(), prefixes)[:300]}", None)
            continue
        m = LINK_ERROR_RE.search(line)
        if m:
            loose.setdefault(f"undefined reference to {m['sym']}", None)
            continue
        m = LOOSE_ERROR_RE.match(line)
        if m:
            loose.setdefault(relativize_words(m["msg"].strip(), prefixes), None)
    messages = list(loose)
    useful = [msg for msg in messages if not msg.startswith(NOISE_PREFIXES)]
    if not useful and not errors:
        useful = [msg for msg in messages if msg.startswith("compile command failed due to signal")]
    return list(errors.values()), useful


def relativize_words(message: str, prefixes: Sequence[str]) -> str:
    for prefix in prefixes:
        message = message.replace(prefix.rstrip("/") + "/", "")
    return message


def log_tail(path: Path, lines: int = 15) -> list[str]:
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return []
    return [ANSI_RE.sub("", line) for line in text.splitlines()[-lines:]]


# --------------------------------------------------------------------------------------- queue


def owner_of(path: str, fallback: str) -> tuple[str, str]:
    """(target, package path) for a repo-relative file; external files group under their checkout."""
    m = TARGET_PATH_RE.match(path)
    if m:
        return m["target"], m["pkg_path"]
    m = CHECKOUT_RE.match(path)
    if m:
        return f"checkouts/{m['pkg']}", ""
    return fallback, ""


def file_lines(repo: Path, path: str) -> int:
    if path.startswith("/"):
        return 0
    try:
        with (repo / path).open("rb") as handle:
            return sum(1 for _ in handle)
    except OSError:
        return 0


def _units(repo: Path, path: str, errs: list[CompileError]) -> list[dict]:
    """A file of <= 400 lines is one unit; a longer one is cut into windows of <= 400 lines."""
    errs = sorted(errs, key=lambda e: (e.line, e.col, e.message))
    total = file_lines(repo, path)
    if 0 < total <= CLUSTER_MAX_LINES:
        return [{"path": path, "file_lines": total, "from": 1, "to": total, "size": total, "errors": errs}]
    units: list[dict] = []
    window: list[CompileError] = []
    for err in errs:
        if window and err.line >= window[0].line + CLUSTER_MAX_LINES:
            units.append(_window(path, total, window))
            window = []
        window.append(err)
    if window:
        units.append(_window(path, total, window))
    return units


def _window(path: str, total: int, errs: list[CompileError]) -> dict:
    lo, hi = errs[0].line, errs[-1].line
    return {"path": path, "file_lines": total, "from": lo, "to": hi, "size": hi - lo + 1, "errors": errs}


def dependency_entry(suite: str, target: str, errs: list[CompileError], cases: list[str]) -> dict:
    """A dependency checkout that does not compile is one root cause (a missing module or FFI), not a
    file cluster: one entry with a sample, for whoever fixes the package graph or the dependency."""
    return {
        "id": f"{suite}:{target}",
        "kind": "dependency",
        "suite": suite,
        "target": target,
        "needed_by": cases,
        "error_count": len(errs),
        "first_error": f"{errs[0].path}:{errs[0].line}: {errs[0].message}",
        "sample": [f"{e.path}:{e.line}: {e.message}" for e in errs[:DEPENDENCY_SAMPLE]],
    }


def cluster(repo: Path, suite: str, target: str, pkg_path: str, errs: list[CompileError]) -> list[dict]:
    by_file: dict[str, list[CompileError]] = {}
    for err in errs:
        by_file.setdefault(err.path, []).append(err)
    units = [u for path in sorted(by_file) for u in _units(repo, path, by_file[path])]
    groups: list[list[dict]] = []
    size = 0
    for unit in units:
        if groups and size + unit["size"] <= CLUSTER_MAX_LINES:
            groups[-1].append(unit)
            size += unit["size"]
        else:
            groups.append([unit])
            size = unit["size"]
    entries = []
    for group in groups:
        key = "|".join(f"{u['path']}:{u['from']}-{u['to']}" for u in group)
        all_errors = [e for u in group for e in u["errors"]]
        entries.append(
            {
                "id": f"{suite}:{target}:{hashlib.sha1(key.encode()).hexdigest()[:10]}",
                "kind": "compile",
                "suite": suite,
                "target": target,
                "package_path": pkg_path,
                "lines_total": sum(u["size"] for u in group),
                "error_count": len(all_errors),
                "first_error": f"{all_errors[0].path}:{all_errors[0].line}: {all_errors[0].message}",
                "files": [
                    {
                        "path": u["path"],
                        "file_lines": u["file_lines"],
                        "from": u["from"],
                        "to": u["to"],
                        "errors": [{"line": e.line, "col": e.col, "message": e.message} for e in u["errors"]],
                    }
                    for u in group
                ],
            }
        )
    return entries


# ---------------------------------------------------------------------------------------- plan


def _tier_names(value: object) -> list[str]:
    """Target names from a list of names, nested lists, wave objects or `{"name": ...}` objects.

    Keys starting with `_` are comments; string values under any key other than `name` are notes.
    """
    if isinstance(value, str):
        return [value]
    if isinstance(value, dict):
        if isinstance(value.get("name"), str):
            return [value["name"]]
        return [
            n
            for key, item in value.items()
            if not key.startswith("_") and isinstance(item, (list, dict))
            for n in _tier_names(item)
        ]
    if isinstance(value, list):
        return [n for item in value for n in _tier_names(item)]
    return []


def prune_tier(value: object, drop: set[str]) -> object:
    """The tier JSON without the dropped targets (both `X` and `CmuxNextX` spellings)."""

    def dropped(name: str) -> bool:
        return name in drop or f"CmuxNext{name}" in drop

    if isinstance(value, list):
        kept = []
        for item in value:
            if isinstance(item, str) and dropped(item):
                continue
            if isinstance(item, dict) and isinstance(item.get("name"), str) and dropped(item["name"]):
                continue
            kept.append(prune_tier(item, drop))
        return kept
    if isinstance(value, dict):
        return {k: (v if k.startswith("_") else prune_tier(v, drop)) for k, v in value.items()}
    return value


def _resolve_name(name: str, known: dict[str, dict]) -> str | None:
    for candidate in (name, f"CmuxNext{name}"):
        if candidate in known:
            return candidate
    return None


def _local_deps(target: dict, known: dict[str, dict]) -> list[str]:
    deps: list[str] = []
    for dep in target.get("dependencies", []):
        for key in ("byName", "target"):
            value = dep.get(key)
            if isinstance(value, list) and value and value[0] in known:
                deps.append(value[0])
    return deps


def plan(dump: dict, tier: dict | None) -> list[dict]:
    """Sources then tests, in tier order (manifest order without a tier file)."""
    known = {t["name"]: t for t in dump.get("targets", [])}
    buildable = {n: t for n, t in known.items() if t.get("type") in SOURCE_KINDS + ("test",)}
    rows: list[dict] = []
    if tier is None:
        sources = [n for n, t in buildable.items() if t["type"] != "test"]
        tests = [n for n, t in buildable.items() if t["type"] == "test"]
        missing: list[str] = []
    else:
        missing = []
        sources = []
        wave_tests: list[str] = []
        for name in _tier_names(tier.get("waves", [])):
            resolved = _resolve_name(name, buildable)
            if resolved is None:
                missing.append(name)
            elif buildable[resolved]["type"] == "test":
                wave_tests.append(resolved)
            elif resolved not in sources:
                sources.append(resolved)
        listed = tier.get("testTargets", tier.get("tests"))
        tests = [t for t in dict.fromkeys(wave_tests)]
        if listed is not None:
            for name in _tier_names(listed):
                resolved = _resolve_name(name, buildable)
                if resolved is None:
                    missing.append(name)
                elif resolved not in tests:
                    tests.append(resolved)
        if listed is None and not tests:
            source_set = set(sources)
            for name, target in buildable.items():
                deps = _local_deps(target, known)
                if target["type"] == "test" and deps and set(deps) <= source_set:
                    tests.append(name)
    def row(name: str, kind: str) -> dict:
        target = buildable[name]
        default = f"{'Tests' if target['type'] == 'test' else 'Sources'}/{name}"
        return {"name": name, "kind": kind, "deps": _local_deps(target, buildable), "path": target.get("path") or default}

    for name in topo_order(sources, {n: _local_deps(buildable[n], buildable) for n in sources}):
        rows.append(row(name, "source"))
    for name in tests:
        rows.append(row(name, "test"))
    for name in missing:
        rows.append({"name": name, "kind": "missing", "deps": [], "path": ""})
    return rows


def topo_order(names: list[str], deps: dict[str, list[str]]) -> list[str]:
    """Dependencies first; otherwise the given order (a stable depth-first sort; cycles keep list order)."""
    wanted = set(names)
    done: set[str] = set()
    active: set[str] = set()
    out: list[str] = []

    def visit(name: str) -> None:
        if name in done or name in active:
            return
        active.add(name)
        for dep in deps.get(name, []):
            if dep in wanted:
                visit(dep)
        active.discard(name)
        done.add(name)
        out.append(name)

    for name in names:
        visit(name)
    return out


def sanitizer_reports(text: str, prefixes: Sequence[str]) -> list[str]:
    """Unique sanitizer SUMMARY lines with checkout paths made relative (MQ-races dedups by stack later)."""
    found: dict[str, None] = {}
    for raw in text.splitlines():
        m = SANITIZER_RE.match(ANSI_RE.sub("", raw).strip())
        if m:
            found.setdefault(f"{m['tool']}: {relativize_words(m['rest'].strip(), prefixes)}", None)
    return list(found)


def linux_only(exp: oracle_exp.Expectations) -> oracle_exp.Expectations:
    return oracle_exp.Expectations([e for e in exp.entries if "linux" in e.tags], list(exp.diagnostics))


def run_config(sanitize: str) -> oracle_exp.RunConfig:
    build = {"address": "asan", "thread": "tsan"}.get(sanitize or "")
    return oracle_exp.RunConfig(platform="linux", build=build)


# ------------------------------------------------------------------------------ shared packages


def shared_packages(repo: Path) -> list[str]:
    """Shared/iOS packages (plus CmuxPhonePush) with <= 2 UI-importing source files, minus the named excludes."""
    candidates: list[Path] = []
    for group in SHARED_GROUPS:
        base = repo / group
        if base.is_dir():
            candidates.extend(sorted(p for p in base.iterdir() if (p / "Package.swift").is_file()))
    candidates.extend(repo / extra for extra in SHARED_EXTRA if (repo / extra / "Package.swift").is_file())
    chosen: list[str] = []
    for pkg in candidates:
        if pkg.name in SHARED_EXCLUDED:
            continue
        ui_files = 0
        sources = pkg / "Sources"
        if sources.is_dir():
            for swift in sources.rglob("*.swift"):
                try:
                    if UI_IMPORT_RE.search(swift.read_text(encoding="utf-8", errors="replace")):
                        ui_files += 1
                except OSError:
                    continue
        if ui_files <= SHARED_UI_FILE_LIMIT:
            chosen.append(str(pkg.relative_to(repo)))
    return chosen


# ------------------------------------------------------------------------------------- receipt


@dataclasses.dataclass
class CaseState:
    kind: str = ""  # source test package missing
    build: str = ""  # pass fail blocked skip ""
    run: str = ""  # pass fail timeout skip ""
    tests: list[TestResult] = dataclasses.field(default_factory=list)
    seconds: float = 0.0
    log: str = ""
    blocked_by: str = ""


def crash_cause(log: str, prefixes: Sequence[str]) -> str:
    """The trap message of a test process that exited non-zero without a failed test."""
    if log:
        try:
            _, loose = parse_log(Path(log).read_text(encoding="utf-8", errors="replace"), prefixes)
        except OSError:
            loose = []
        fatal = [m for m in loose if m.startswith("Fatal error")]
        if fatal:
            return fatal[0]
        tail = [line for line in log_tail(Path(log), 6) if line.strip()]
        if tail:
            return "exit without a failed test; log tail: " + " | ".join(tail)
    return "exit without a failed test"


def build_receipt(
    records: list[LedgerRecord],
    meta: dict,
    repo: Path,
    prefixes: Sequence[str],
    exp: oracle_exp.Expectations,
) -> tuple[dict, list[dict]]:
    """The receipt and the queue. receipt["ok"] is False on any red no `[ linux ]` line expects."""
    exp = linux_only(exp)
    config = run_config(meta.get("sanitize", ""))
    suite = meta["suite"]
    cases: dict[str, CaseState] = {}
    order: list[str] = []
    phases: dict[str, float] = {}
    incremental: dict | None = None
    failed_logs: list[tuple[str, Path]] = []
    sanitizer_logs: list[tuple[str, Path]] = []

    def state(name: str) -> CaseState:
        if name not in cases:
            cases[name] = CaseState()
            order.append(name)
        return cases[name]

    for r in records:
        if r.kind == "phase":
            phases[r.case] = phases.get(r.case, 0.0) + r.seconds
            continue
        if r.kind == "incremental":
            incremental = {
                "target": r.case,
                "status": r.status,
                "seconds": round(r.seconds, 2),
                "budget_seconds": INCREMENTAL_BUDGET_SECONDS,
                "within_budget": r.status == "pass" and r.seconds < INCREMENTAL_BUDGET_SECONDS,
            }
            if r.status in ("fail", "timeout") and r.log:
                failed_logs.append((r.case, Path(r.log)))
            continue
        s = state(r.case)
        if r.kind == "package":
            s.kind = s.kind or "package"
            s.build = r.status if s.build in ("", "pass") else s.build
        elif r.kind in ("build", "build-test", "missing", "setup"):
            s.kind = {"build": "source", "build-test": "test", "missing": "missing", "setup": "setup"}[r.kind]
            s.build = r.status
            s.blocked_by = r.detail if r.status == "blocked" else ""
        elif r.kind == "test":
            s.run = r.status
            s.log = r.log
            s.seconds += r.seconds
            if r.xunit:
                s.tests = parse_xunit(Path(r.xunit), r.case if suite == "swift-tier" else "")
        if r.status in ("fail", "timeout") and r.log and r.kind != "test":
            failed_logs.append((r.case, Path(r.log)))
        if r.kind == "test" and r.log and meta.get("sanitize"):
            sanitizer_logs.append((r.case, Path(r.log)))

    unexpected: list[dict] = []
    if meta.get("checkout_resolved_unchanged") is False:
        unexpected.append(
            {"case": "Package.resolved", "what": "the run wrote the checkout's Package.resolved", "result": "Failure"}
        )
    expected: list[dict] = []
    unexpected_pass: list[str] = []
    test_queue: list[dict] = []

    def judge(case: str, actual: oracle_exp.Actual, what: str, detail: str = "") -> bool:
        verdict = exp.evaluate(suite, case, config, actual)
        step = actual.divergences[0].step if actual.divergences else actual.step
        item = {"case": case, "what": what, "result": actual.result}
        if step:
            item["step"] = step
        if detail:
            item["detail"] = detail
        if verdict.outcome == oracle_exp.UNEXPECTED_FAILURE:
            unexpected.append(item)
            return False
        expected.append(item)
        return True

    whole_case_failure = oracle_exp.Actual(oracle_exp.FAILURE, (oracle_exp.Divergence(None, None),))
    per_case: dict[str, dict] = {}
    red: set[str] = set()  # cases with a red no line expects
    for name in order:
        s = cases[name]
        row: dict = {"kind": s.kind, "build": s.build or "not-built"}
        if s.build in ("fail", "timeout"):
            actual = oracle_exp.Actual(oracle_exp.TIMEOUT) if s.build == "timeout" else whole_case_failure
            row["expected"] = judge(name, actual, f"{s.kind or 'build'} build")
            if not row["expected"]:
                red.add(name)
        if s.run:
            passed = [t for t in s.tests if t.status == "pass"]
            failed = [t for t in s.tests if t.status == "fail"]
            skipped = [t for t in s.tests if t.status == "skip"]
            row.update(
                run=s.run,
                tests=len(passed) + len(failed),
                passed=len(passed),
                failed=len(failed),
                skipped=len(skipped),
                seconds=round(s.seconds, 2),
            )
            bad: list[dict] = []
            for t in failed:
                actual = oracle_exp.Actual(oracle_exp.FAILURE, (oracle_exp.Divergence(t.step, None),))
                if not judge(name, actual, "test", t.message):
                    bad.append({"step": t.step, "message": t.message})
            if s.run == "timeout":
                if not judge(name, oracle_exp.Actual(oracle_exp.TIMEOUT), "test run"):
                    bad.append({"step": None, "message": "test run timed out"})
            elif s.run == "fail" and not failed:
                cause = crash_cause(s.log, prefixes)
                if not judge(name, oracle_exp.Actual(oracle_exp.CRASH), "test run", cause):
                    bad.append({"step": None, "message": f"test process crashed: {cause}"})
            elif s.run == "pass" and not s.tests:
                # A filter that matched nothing or a lost xunit file looks like a green run.
                if not judge(name, whole_case_failure, "test run", "no tests executed"):
                    bad.append({"step": None, "message": "no tests executed"})
            elif s.run == "pass":
                verdict = exp.evaluate(suite, name, config, oracle_exp.Actual(oracle_exp.PASS))
                unexpected_pass.extend(verdict.unexpected_pass_lines)
            if bad:
                test_queue.append(
                    {
                        "id": f"{suite}:{name}:tests",
                        "kind": "test",
                        "suite": suite,
                        "target": name,
                        "tests": bad,
                    }
                )
        if s.kind in ("test", "package") and s.run not in ("", "skip"):
            row["linux_share"] = round(linux_share(exp, suite, name, config, row.get("tests", 0)), 4)
        per_case[name] = row

    # A blocked case did not build. Behind an unexpected red the run is red already; behind an
    # expected failure or a Skip only the case's own line keeps it out of the run, so one line on a
    # root never takes its dependents out of the tier unseen. The ledger lists blockers first.
    for name in order:
        s = cases[name]
        if s.build != "blocked":
            continue
        row = per_case[name]
        row["blocked_by"] = s.blocked_by
        if s.blocked_by in red:
            red.add(name)
            continue
        row["expected"] = judge(name, whole_case_failure, f"{s.kind or 'build'} blocked by {s.blocked_by or 'a dependency'}")
        if not row["expected"]:
            red.add(name)

    incremental_over_budget = False
    if incremental and incremental["status"] in ("fail", "timeout"):
        actual = oracle_exp.Actual(oracle_exp.TIMEOUT) if incremental["status"] == "timeout" else whole_case_failure
        judge(incremental["target"], actual, "incremental build")
    elif incremental and incremental["status"] == "pass" and not incremental["within_budget"]:
        incremental_over_budget = True

    budget = [
        {"case": name, "linux_share": row["linux_share"], "limit": LINUX_SHARE_BUDGET}
        for name, row in per_case.items()
        if row.get("linux_share", 0) > LINUX_SHARE_BUDGET
    ]

    # Compiler-error queue.
    compile_errors: dict[str, list[CompileError]] = {}
    pkg_paths: dict[str, str] = {}
    loose_by_case: dict[str, list[str]] = {}
    seen_logs: set[Path] = set()
    dependents: dict[str, set[str]] = {}
    for case, log in failed_logs:
        if log in seen_logs:
            continue
        seen_logs.add(log)
        try:
            text = log.read_text(encoding="utf-8", errors="replace")
        except OSError:
            text = ""
        errs, loose = parse_log(text, prefixes)
        for err in errs:
            target, pkg_path = owner_of(err.path, case)
            compile_errors.setdefault(target, []).append(err)
            if target.startswith("checkouts/"):
                dependents.setdefault(target, set()).add(case)
            if pkg_path:
                pkg_paths[target] = pkg_path
        if loose or not errs:
            bucket = loose_by_case.setdefault(case, [])
            for msg in loose or [f"no compiler error parsed; log tail: {' | '.join(log_tail(log, 8))}"]:
                if msg not in bucket:
                    bucket.append(msg)
    rank = {name: i for i, name in enumerate(order)}
    queue: list[dict] = []
    for target in sorted(compile_errors, key=lambda t: (rank.get(t, len(rank)), t)):
        unique = list(dict.fromkeys(compile_errors[target]))
        if target.startswith("checkouts/"):
            queue.append(dependency_entry(suite, target, unique, sorted(dependents.get(target, ()))))
        else:
            queue.extend(cluster(repo, suite, target, pkg_paths.get(target, ""), unique))
    for case in sorted(loose_by_case, key=lambda c: (rank.get(c, len(rank)), c)):
        if case in compile_errors and all(m.startswith("no compiler error parsed") for m in loose_by_case[case]):
            continue
        queue.append(
            {"id": f"{suite}:{case}:target", "kind": "target", "suite": suite, "target": case, "messages": loose_by_case[case]}
        )
    queue.extend(test_queue)
    for case, log in sanitizer_logs:
        try:
            reports = sanitizer_reports(log.read_text(encoding="utf-8", errors="replace"), prefixes)
        except OSError:
            reports = []
        for report in reports:
            digest = hashlib.sha1(report.encode()).hexdigest()[:10]
            queue.append({"id": f"{suite}:{case}:san:{digest}", "kind": "sanitizer", "suite": suite, "target": case, "report": report})

    def names(kind: str, status: str) -> list[str]:
        return [n for n in order if cases[n].kind == kind and cases[n].build == status]

    tests_total = {
        key: sum(row.get(key, 0) for row in per_case.values()) for key in ("tests", "passed", "failed", "skipped")
    }
    receipt = {
        "schema": RECEIPT_SCHEMA,
        "runner": meta.get("runner", ""),
        "suite": suite,
        "sha": meta.get("sha", ""),
        "dirty": bool(meta.get("dirty")),
        "toolchain": meta.get("toolchain", ""),
        "platform": "linux",
        "sanitize": meta.get("sanitize") or None,
        "resolved_file": meta.get("resolved_file", ""),
        "checkout_resolved_unchanged": meta.get("checkout_resolved_unchanged"),
        "started_at": meta.get("started_at", ""),
        "jobs": meta.get("jobs"),
        "workers": meta.get("workers"),
        "wall_seconds": {k: round(v, 2) for k, v in phases.items()},
        "targets": {
            "built": names("source", "pass"),
            "failed": names("source", "fail") + names("source", "timeout"),
            "blocked": names("source", "blocked"),
            "skipped": names("source", "skip"),
            "missing": [n for n in order if cases[n].kind == "missing"],
        },
        "test_targets": {
            "built": names("test", "pass"),
            "failed": names("test", "fail") + names("test", "timeout"),
            "blocked": names("test", "blocked"),
            "run": [n for n in order if cases[n].run not in ("", "skip")],
            "skipped": names("test", "skip"),
        },
        "setup": {
            "passed": names("setup", "pass"),
            "failed": names("setup", "fail") + names("setup", "timeout"),
        },
        "packages": {
            "built": names("package", "pass"),
            "failed": names("package", "fail") + names("package", "timeout"),
            "skipped": names("package", "skip"),
        },
        "tests": {
            "executed": tests_total["tests"],
            "passed": tests_total["passed"],
            "failed": tests_total["failed"],
            "skipped": tests_total["skipped"],
        },
        "cases": per_case,
        "unexpected": unexpected,
        "expected_failures": expected,
        "unexpected_passes": sorted(set(unexpected_pass)),
        "linux_share_over_budget": budget,
        "incremental": incremental,
        "errors_queue": {"path": meta.get("errors_queue", ""), "entries": len(queue)},
    }
    receipt["counts"] = {
        "targets_built": len(receipt["targets"]["built"]),
        "targets_failed": len(receipt["targets"]["failed"]) + len(receipt["targets"]["missing"]),
        "test_targets_built": len(receipt["test_targets"]["built"]),
        "packages_built": len(receipt["packages"]["built"]),
        "packages_failed": len(receipt["packages"]["failed"]),
    }
    receipt["incremental_over_budget"] = incremental_over_budget
    receipt["ok"] = not unexpected and not budget and not incremental_over_budget
    return receipt, queue


def linux_share(exp: oracle_exp.Expectations, suite: str, case: str, config: oracle_exp.RunConfig, tests: int) -> float:
    """Share of a test target's tests a `[ linux ]` line marks non-Pass; a whole-case line marks all."""
    steps: set[str] = set()
    for e in exp.entries:
        if e.suite != suite or e.case not in (case, "*") or not e.matches(config):
            continue
        if e.results <= {oracle_exp.PASS, oracle_exp.SLOW}:
            continue
        if e.step is None:
            return 1.0
        steps.add(e.step)
    if not steps:
        return 0.0
    return len(steps) / tests if tests else 1.0


def render_summary(receipt: dict) -> str:
    c = receipt["counts"]
    t = receipt["tests"]
    lines = [
        f"[{receipt['runner']}] {receipt['sha'][:12]} {receipt['toolchain']}"
        + (f" sanitize={receipt['sanitize']}" if receipt["sanitize"] else ""),
    ]
    if receipt["suite"] == "swift-shared":
        lines.append(
            f"packages built {c['packages_built']}, failed {c['packages_failed']}, "
            f"skipped {len(receipt['packages']['skipped'])}, missing {len(receipt['targets']['missing'])}"
        )
    else:
        lines.append(
            f"targets built {c['targets_built']}, failed {c['targets_failed']}, blocked {len(receipt['targets']['blocked'])}, "
            f"skipped {len(receipt['targets']['skipped'])}; test targets built {c['test_targets_built']}, "
            f"blocked {len(receipt['test_targets']['blocked'])}, skipped {len(receipt['test_targets']['skipped'])}"
        )
    lines.append(f"tests executed {t['executed']}, passed {t['passed']}, failed {t['failed']}, skipped {t['skipped']}")
    if receipt["incremental"]:
        inc = receipt["incremental"]
        lines.append(f"incremental {inc['target']}: {inc['seconds']} s ({inc['status']}, budget {inc['budget_seconds']} s)")
        if receipt["incremental_over_budget"]:
            lines.append(f"OVER BUDGET: the incremental build of {inc['target']} took {inc['seconds']} s (limit {inc['budget_seconds']} s)")
    lines.append(f"errors queue: {receipt['errors_queue']['entries']} entries")
    for item in receipt["unexpected"][:20]:
        where = item["case"] + (f"/{item['step']}" if item.get("step") else "")
        lines.append(f"UNEXPECTED {item['result']}: {receipt['suite']}/{where} ({item['what']})")
    if len(receipt["unexpected"]) > 20:
        lines.append(f"... {len(receipt['unexpected']) - 20} more unexpected results in the receipt")
    for item in receipt["linux_share_over_budget"]:
        lines.append(f"OVER BUDGET: {item['case']} has {item['linux_share']:.1%} of its tests under [ linux ] lines (limit 5%)")
    lines.append("OK" if receipt["ok"] else "FAILED: a red no [ linux ] Expectations line expects")
    return "\n".join(lines)


def write_queue(path: Path, queue: Iterable[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        for entry in queue:
            handle.write(json.dumps(entry, sort_keys=True) + "\n")


# ------------------------------------------------------------------------------------ selftest


def _selftest() -> int:
    failures: list[str] = []
    count = 0

    def check(name: str, condition: bool) -> None:
        nonlocal count
        count += 1
        if not condition:
            failures.append(name)

    with tempfile.TemporaryDirectory() as tmp_text:
        tmp = Path(tmp_text)
        repo = tmp / "repo"
        scratch = tmp / "scratch" / "src"
        src = repo / "Packages/macOS/CmuxNext/Sources/CmuxNextFoo"
        src.mkdir(parents=True)
        (src / "Small.swift").write_text("x\n" * 120)
        (src / "Big.swift").write_text("x\n" * 1000)
        (src / "Mid.swift").write_text("x\n" * 300)
        other = repo / "Packages/macOS/CmuxNext/Sources/CmuxNextBar"
        other.mkdir(parents=True)
        (other / "B.swift").write_text("x\n" * 300)
        s = f"{scratch}/Packages/macOS/CmuxNext/Sources"
        log = "\n".join(
            [
                "\x1b[1m[12/90] Compiling CmuxNextFoo Small.swift\x1b[0m",
                f"{s}/CmuxNextFoo/Small.swift:10:5: error: cannot find 'NSView' in scope",
                f"{s}/CmuxNextFoo/Small.swift:10:5: error: cannot find 'NSView' in scope",  # repeated by a second job
                f"{s}/CmuxNextFoo/Small.swift:11:1: warning: unused",
                f"{s}/CmuxNextFoo/Big.swift:20:1: error: no such module 'AppKit'",
                f"{s}/CmuxNextFoo/Big.swift:900:3: error: cannot find type 'CGColor' in scope",
                f"{s}/CmuxNextFoo/Mid.swift:5:3: error: cannot find 'kqueue' in scope",
                f"{s}/CmuxNextBar/B.swift:3:8: error: no such module 'os'",
                "error: emit-module command failed with exit code 1 (use -v to see invocation)",
                "error: fatalError",
                "/usr/bin/ld.gold: error: x.o: undefined reference to `cmux_layout_new'",
            ]
        )
        errs, loose = parse_log(log, [str(scratch), str(repo)])
        check("dedup + relativize", len(errs) == 5 and errs[0].path == "Packages/macOS/CmuxNext/Sources/CmuxNextFoo/Small.swift")
        check("warnings ignored", all("unused" not in e.message for e in errs))
        check("noise dropped, linker kept", loose == ["undefined reference to cmux_layout_new"])
        check("owner", owner_of(errs[0].path, "x") == ("CmuxNextFoo", "Packages/macOS/CmuxNext"))

        foo = [e for e in errs if "CmuxNextFoo" in e.path]
        entries = cluster(repo, "swift-tier", "CmuxNextFoo", "Packages/macOS/CmuxNext", foo)
        # Big.swift (1000 lines) gives two 1-line windows (errors at 20 and 900); Mid (300) and Small (120)
        # are whole files. Packed in path order under 400 lines: [Big, Big, Mid] = 302, then [Small] = 120.
        check("cluster count", [[f["path"].rsplit("/", 1)[1] for f in e["files"]] for e in entries]
              == [["Big.swift", "Big.swift", "Mid.swift"], ["Small.swift"]])
        check("cluster size cap", [e["lines_total"] for e in entries] == [302, 120])
        check("long file windows", [(f["from"], f["to"]) for f in entries[0]["files"][:2]] == [(20, 20), (900, 900)])
        ids = [e["id"] for e in entries]
        check("stable ids", ids == [e["id"] for e in cluster(repo, "swift-tier", "CmuxNextFoo", "", list(reversed(foo)))])

        noise_only, loose_only = parse_log("error: fatalError\nerror: compile command failed due to signal 11", [])
        check("signal kept when nothing else explains", not noise_only and loose_only == ["compile command failed due to signal 11"])

        check("step from swift-testing", step_name("CmuxNextFooTests.MutexTests", "lockUnlock()", "CmuxNextFooTests") == "MutexTests.lockUnlock")
        check("step from nested suite", step_name("M.Outer/Inner", "t(a:)", "M") == "Outer.Inner.t_a")
        check("step from xctest", step_name("M.FooTests", "testBar", "M") == "FooTests.testBar")
        check("step without module", step_name("Pkg.Suite", "x()", "") == "Pkg.Suite.x")

        # xunit: XCTest file plus swift-testing sibling.
        xunit = tmp / "xunit" / "CmuxNextFooTests.xml"
        xunit.parent.mkdir()
        xunit.write_text(
            '<testsuites><testsuite><testcase classname="CmuxNextFooTests.A" name="testOne"/>'
            '<testcase classname="CmuxNextFooTests.A" name="testTwo"><failure message="boom"/></testcase>'
            "</testsuite></testsuites>"
        )
        (xunit.parent / "CmuxNextFooTests-swift-testing.xml").write_text(
            '<testsuites><testsuite><testcase classname="CmuxNextFooTests.S" name="ok()"/>'
            '<testcase classname="CmuxNextFooTests.S" name="later()"><skipped/></testcase>'
            '<testcase classname="CmuxNextFooTests.S" name="linuxOnly()"><failure message="no epoll"/></testcase>'
            "</testsuite></testsuites>"
        )
        tests = parse_xunit(xunit, "CmuxNextFooTests")
        check("xunit both files", len(tests) == 5 and sum(t.status == "fail" for t in tests) == 2)

        # plan
        dump = {
            "targets": [
                {"name": "CmuxNextCompat", "type": "regular", "dependencies": []},
                {"name": "CmuxNextFoo", "type": "regular", "dependencies": [{"byName": ["CmuxNextCompat", None]}]},
                {"name": "CmuxNextAppKitThing", "type": "regular", "dependencies": []},
                {"name": "CCmuxAppFFI", "type": "binary", "dependencies": []},
                {"name": "CmuxNextFooTests", "type": "test", "dependencies": [{"target": ["CmuxNextFoo", None]}]},
                {"name": "CmuxNextAppKitThingTests", "type": "test", "dependencies": [{"byName": ["CmuxNextAppKitThing", None]}]},
            ]
        }
        rows = plan(dump, {"waves": [["Compat"], ["CmuxNextFoo", "Nope"]]})
        check(
            "plan tier order",
            [(r["name"], r["kind"]) for r in rows]
            == [("CmuxNextCompat", "source"), ("CmuxNextFoo", "source"), ("CmuxNextFooTests", "test"), ("Nope", "missing")],
        )
        check("plan deps", rows[1]["deps"] == ["CmuxNextCompat"])
        check("plan paths", [r["path"] for r in rows] == ["Sources/CmuxNextCompat", "Sources/CmuxNextFoo", "Tests/CmuxNextFooTests", ""])
        check("plan without tier", len(plan(dump, None)) == 5)
        check("plan dict waves", [r["name"] for r in plan(dump, {"waves": {"0": [{"name": "Compat"}]}, "tests": []})] == ["CmuxNextCompat"])

        # receipt: one expected test failure ([ linux ] step line), one unexpected; a mac line excuses nothing.
        exp_text = (
            "p15-oracle-120 [ linux ] swift-tier/CmuxNextFooTests/S.linuxOnly [ Failure ]\n"
            "p15-oracle-120 [ mac ] swift-tier/CmuxNextFooTests/A.testTwo [ Failure ]\n"
            "p15-oracle-121 [ linux ] swift-tier/CmuxNextBar [ Failure ]\n"
        )
        entries_exp, diags = oracle_exp.parse_text(exp_text, "swift-tier.txt", "expectations")
        check("expectation fixture parses", not diags and len(entries_exp) == 3)
        exp = oracle_exp.Expectations(entries_exp, diags)
        log_path = tmp / "build.log"
        log_path.write_text(log)
        ledger = [
            LedgerRecord("swift-tier", "sync", "phase", "pass", 0, 1.5, "", ""),
            LedgerRecord("swift-tier", "CmuxNextCompat", "build", "pass", 0, 0, "", ""),
            LedgerRecord("swift-tier", "CmuxNextFoo", "build", "fail", 1, 3, str(log_path), ""),
            LedgerRecord("swift-tier", "CmuxNextBar", "build", "fail", 1, 3, str(log_path), ""),
            LedgerRecord("swift-tier", "CmuxNextBaz", "build", "blocked", 0, 0, "", ""),
            LedgerRecord("swift-tier", "CmuxNextFooTests", "build-test", "pass", 0, 0, "", ""),
            LedgerRecord("swift-tier", "CmuxNextFooTests", "test", "fail", 1, 2, "", str(xunit)),
            LedgerRecord("swift-tier", "CmuxNextFoo", "incremental", "pass", 0, 12.3, "", ""),
        ]
        meta = {"suite": "swift-tier", "runner": "swift-tier", "sha": "abc", "errors_queue": "q.jsonl"}
        receipt, queue = build_receipt(ledger, meta, repo, [str(scratch)], exp)
        unexpected = {(u["case"], u.get("step")) for u in receipt["unexpected"]}
        check("foo build unexpected", ("CmuxNextFoo", None) in unexpected)
        check("bar build expected by [ linux ] case line", ("CmuxNextBar", None) not in unexpected)
        check("A.testTwo unexpected (mac line ignored)", ("CmuxNextFooTests", "A.testTwo") in unexpected)
        check("S.linuxOnly expected", ("CmuxNextFooTests", "S.linuxOnly") not in unexpected)
        check("not ok", receipt["ok"] is False)
        check("counts", receipt["counts"]["targets_built"] == 1 and receipt["counts"]["targets_failed"] == 2)
        check("blocked listed", receipt["targets"]["blocked"] == ["CmuxNextBaz"])
        check("tests counted", receipt["tests"] == {"executed": 4, "passed": 2, "failed": 2, "skipped": 1})
        check("phase time", receipt["wall_seconds"] == {"sync": 1.5})
        check("incremental", receipt["incremental"]["within_budget"] is True)
        kinds = [q["kind"] for q in queue]
        check("queue: compile entries first, ordered by the run", kinds[:3] == ["compile"] * 3 and kinds[3] != "compile"
              and [q["target"] for q in queue[:3]] == ["CmuxNextFoo", "CmuxNextFoo", "CmuxNextBar"])
        check("queue: linker error is a target entry", any(q["kind"] == "target" and "cmux_layout_new" in q["messages"][0] for q in queue))
        check("queue: unexpected test entry", queue[-1]["kind"] == "test" and queue[-1]["tests"] == [{"step": "A.testTwo", "message": "boom"}])
        # 1 step line over 4 executed tests: 25 % > 5 %.
        check("linux share budget", receipt["linux_share_over_budget"] == [{"case": "CmuxNextFooTests", "linux_share": 0.25, "limit": 0.05}])

        one_test = tmp / "xunit" / "one.xml"
        one_test.write_text('<testsuites><testsuite><testcase classname="Core.S" name="ok()"/></testsuite></testsuites>')
        green = [
            LedgerRecord("swift-shared", "CMUXAuthCore", "package", "pass", 0, 9, "", ""),
            LedgerRecord("swift-shared", "CMUXAuthCore", "test", "pass", 0, 1, "", str(one_test)),
            LedgerRecord("swift-shared", "CmuxTheme", "package", "skip", 0, 0, "", ""),
        ]
        ok_receipt, ok_queue = build_receipt(green, {"suite": "swift-shared"}, repo, [], oracle_exp.Expectations([], []))
        check("green run ok", ok_receipt["ok"] and not ok_queue and ok_receipt["counts"]["packages_built"] == 1)
        check("skipped package listed", ok_receipt["packages"]["skipped"] == ["CmuxTheme"])

        none_run = [
            LedgerRecord("swift-tier", "T", "build-test", "pass", 0, 1, "", ""),
            LedgerRecord("swift-tier", "T", "test", "pass", 0, 1, "", str(tmp / "absent.xml")),
        ]
        z_receipt, z_queue = build_receipt(none_run, {"suite": "swift-tier"}, repo, [], oracle_exp.Expectations([], []))
        check("a green test run with no test is a red", not z_receipt["ok"]
              and z_queue == [{"id": "swift-tier:T:tests", "kind": "test", "suite": "swift-tier", "target": "T",
                               "tests": [{"step": None, "message": "no tests executed"}]}])
        z_exp, _ = oracle_exp.parse_text("p15-oracle-120 [ linux ] swift-tier/T [ Failure ]\n", "swift-tier.txt", "expectations")
        z_ok, _ = build_receipt(none_run, {"suite": "swift-tier"}, repo, [], oracle_exp.Expectations(z_exp, []))
        check("a line excuses a run with no test", not z_ok["unexpected"])

        chain = [
            LedgerRecord("swift-tier", "Root", "build", "fail", 1, 1, "", ""),
            LedgerRecord("swift-tier", "Mid", "build", "blocked", 0, 0, "", "", "Root"),
            LedgerRecord("swift-tier", "MidTests", "build-test", "blocked", 0, 0, "", "", "Mid"),
            LedgerRecord("swift-tier", "Off", "build", "skip", 0, 0, "", ""),
            LedgerRecord("swift-tier", "OffUser", "build", "blocked", 0, 0, "", "", "Off"),
        ]
        none = oracle_exp.Expectations([], [])
        c_receipt, _ = build_receipt(chain, {"suite": "swift-tier"}, repo, [], none)
        check("behind an unexpected red, blocked cases add no red", [u["case"] for u in c_receipt["unexpected"]] == ["Root", "OffUser"])
        check("blocked and skipped listed", c_receipt["targets"]["blocked"] == ["Mid", "OffUser"]
              and c_receipt["test_targets"]["blocked"] == ["MidTests"] and c_receipt["targets"]["skipped"] == ["Off"]
              and c_receipt["cases"]["MidTests"]["blocked_by"] == "Mid")
        root_exp, _ = oracle_exp.parse_text(
            "p15-oracle-121 [ linux ] swift-tier/Root [ Failure ]\np15-oracle-122 [ linux ] swift-tier/Off [ Skip ]\n",
            "swift-tier.txt", "expectations",
        )
        r_receipt, _ = build_receipt(chain, {"suite": "swift-tier"}, repo, [], oracle_exp.Expectations(root_exp, []))
        check("a line on a root leaves its dependents red", [(u["case"], u["what"]) for u in r_receipt["unexpected"]]
              == [("Mid", "source blocked by Root"), ("OffUser", "source blocked by Off")])
        own_exp, _ = oracle_exp.parse_text(
            "p15-oracle-121 [ linux ] swift-tier/Root [ Failure ]\np15-oracle-121 [ linux ] swift-tier/Mid [ Failure ]\n"
            "p15-oracle-122 [ linux ] swift-tier/Off [ Skip ]\np15-oracle-122 [ linux ] swift-tier/OffUser [ Failure ]\n",
            "swift-tier.txt", "expectations",
        )
        o_receipt, _ = build_receipt(chain, {"suite": "swift-tier"}, repo, [], oracle_exp.Expectations(own_exp, []))
        check("a blocked case behind an expected red needs its own line",
              [u["case"] for u in o_receipt["unexpected"]] == ["MidTests"])

        built = [LedgerRecord("swift-tier", "A", "build", "pass", 0, 1, "", "")]
        inc_log = tmp / "inc.log"
        inc_log.write_text(f"{scratch}/Packages/macOS/CmuxNext/Sources/CmuxNextFoo/Small.swift:3:1: error: expected expression\n")
        i_fail, i_queue = build_receipt(built + [LedgerRecord("swift-tier", "A", "incremental", "fail", 1, 4, str(inc_log), "")],
                                        {"suite": "swift-tier"}, repo, [str(scratch)], none)
        check("a failed incremental build is a red with its errors queued",
              [(u["case"], u["what"]) for u in i_fail["unexpected"]] == [("A", "incremental build")]
              and [q["target"] for q in i_queue if q["kind"] == "compile"] == ["CmuxNextFoo"])
        i_slow, _ = build_receipt(built + [LedgerRecord("swift-tier", "A", "incremental", "pass", 0, 31, "", "")],
                                  {"suite": "swift-tier"}, repo, [], none)
        check("an incremental build over budget fails the run", not i_slow["ok"] and i_slow["incremental_over_budget"]
              and "OVER BUDGET: the incremental build of A" in render_summary(i_slow))
        i_blocked, _ = build_receipt(built + [LedgerRecord("swift-tier", "A", "incremental", "blocked", 0, 0, "", "", "A")],
                                     {"suite": "swift-tier"}, repo, [], none)
        check("an incremental build of a red target adds no red", i_blocked["ok"])

        crash = [
            LedgerRecord("swift-shared", "P", "package", "pass", 0, 1, "", ""),
            LedgerRecord("swift-shared", "P", "test", "fail", 139, 1, "", str(tmp / "missing.xml")),
        ]
        crash_receipt, _ = build_receipt(crash, {"suite": "swift-shared"}, repo, [], oracle_exp.Expectations([], []))
        check("crash without failures is unexpected", [u["result"] for u in crash_receipt["unexpected"]] == ["Crash"])

        unparsed = tmp / "resolve.log"
        unparsed.write_text("Fetching https://example.invalid/x\nsomething went wrong\n")
        resolve = [LedgerRecord("swift-tier", "resolve", "setup", "fail", 1, 1, str(unparsed), "")]
        r_receipt, r_queue = build_receipt(resolve, {"suite": "swift-tier"}, repo, [], oracle_exp.Expectations([], []))
        check("unparsed failure is a queue entry with the log tail", r_queue and "something went wrong" in r_queue[0]["messages"][0])
        check("setup failure fails the run", not r_receipt["ok"] and r_receipt["setup"]["failed"] == ["resolve"])

        # shared package selection
        shared = repo / "Packages/Shared"
        for name, ui in (("Core", 0), ("Ui", 3), ("CmuxAppAttest", 0), ("Two", 2)):
            pkg = shared / name / "Sources" / name
            pkg.mkdir(parents=True)
            (shared / name / "Package.swift").write_text("// swift-tools-version: 6.0\n")
            for i in range(ui):
                (pkg / f"V{i}.swift").write_text("@preconcurrency import SwiftUI\n")
            (pkg / "Core.swift").write_text("import Foundation\n// import AppKit is in a comment\n")
        check("shared selection", shared_packages(repo) == ["Packages/Shared/Core", "Packages/Shared/Two"])
        exp_root = tmp / "oracle"
        (exp_root / "Expectations.d").mkdir(parents=True)
        (exp_root / "Expectations.d" / "swift-shared.txt").write_text("p15-oracle-123 [ linux ] swift-shared/Two [ Skip ]\n")
        listing = io.StringIO()
        with contextlib.redirect_stdout(listing):
            main(["shared-packages", "--repo", str(repo), "--root", str(exp_root)])
        check("shared rows carry the Skip column", listing.getvalue() == "0\tPackages/Shared/Core\n1\tPackages/Shared/Two\n")

        check("topo order", topo_order(["C", "A", "B"], {"C": ["B"], "B": ["A"]}) == ["A", "B", "C"])
        check("topo cycle", sorted(topo_order(["A", "B"], {"A": ["B"], "B": ["A"]})) == ["A", "B"])
        check(
            "prune tier",
            prune_tier({"_c": "x", "waves": [["Compat", "CmuxNextFoo"], [{"name": "Bar"}]], "testTargets": ["CmuxNextFooTests"]},
                       {"CmuxNextFoo", "CmuxNextBar", "CmuxNextFooTests"})
            == {"_c": "x", "waves": [["Compat"], []], "testTargets": []},
        )
        san_log = tmp / "san.log"
        san_log.write_text(
            f"WARNING: ThreadSanitizer: data race\nSUMMARY: ThreadSanitizer: data race {repo}/Packages/A/B.swift:3:1 in f()\n"
            f"SUMMARY: ThreadSanitizer: data race {repo}/Packages/A/B.swift:3:1 in f()\n"
        )
        san = [
            LedgerRecord("swift-tier", "T", "build-test", "pass", 0, 1, "", ""),
            LedgerRecord("swift-tier", "T", "test", "fail", 66, 1, str(san_log), ""),
        ]
        s_receipt, s_queue = build_receipt(san, {"suite": "swift-tier", "sanitize": "thread"}, repo, [str(repo)], oracle_exp.Expectations([], []))
        check("sanitizer report queued once", [q["report"] for q in s_queue if q["kind"] == "sanitizer"]
              == ["ThreadSanitizer: data race Packages/A/B.swift:3:1 in f()"])
        tsan_exp, _ = oracle_exp.parse_text("p15-oracle-187 [ linux tsan ] swift-tier/T [ Crash ]\n", "swift-tier.txt", "expectations")
        e_receipt, _ = build_receipt(san, {"suite": "swift-tier", "sanitize": "thread"}, repo, [], oracle_exp.Expectations(tsan_exp, []))
        check("tsan crash expected by a [ linux tsan ] line", not e_receipt["unexpected"])
        check("a whole-target line counts as 100 % [ linux ]", e_receipt["linux_share_over_budget"][0]["linux_share"] == 1.0)
        n_receipt, _ = build_receipt(san, {"suite": "swift-tier"}, repo, [], oracle_exp.Expectations(tsan_exp, []))
        check("the tsan line does not excuse a plain run", not n_receipt["ok"])
        w_receipt, _ = build_receipt(green, {"suite": "swift-shared", "checkout_resolved_unchanged": False}, repo, [], oracle_exp.Expectations([], []))
        check("a written checkout Package.resolved fails the run", not w_receipt["ok"])

        dep_log = tmp / "dep.log"
        dep_log.write_text(
            f"{tmp}/scratch/build-shared/A/checkouts/iroh-ffi/Lib/X.swift:14:3: error: cannot find type 'RustBuffer' in scope\n"
            f"{tmp}/scratch/build-shared/B/checkouts/iroh-ffi/Lib/X.swift:14:3: error: cannot find type 'RustBuffer' in scope\n"
            f"{tmp}/scratch/build-shared/B/checkouts/iroh-ffi/Lib/X.swift:900:1: error: cannot find 'uniffi_x' in scope\n"
        )
        dep_log2 = tmp / "dep2.log"
        dep_log2.write_text(dep_log.read_text())
        dep = [
            LedgerRecord("swift-shared", "A", "package", "fail", 1, 1, str(dep_log), ""),
            LedgerRecord("swift-shared", "B", "package", "fail", 1, 1, str(dep_log2), ""),
        ]
        _, d_queue = build_receipt(dep, {"suite": "swift-shared"}, repo, [str(tmp / "scratch")], oracle_exp.Expectations([], []))
        check("one dependency entry for both packages",
              [(q["kind"], q["target"], q["error_count"], q["needed_by"]) for q in d_queue]
              == [("dependency", "checkouts/iroh-ffi", 2, ["A", "B"])])
        trap = tmp / "trap.log"
        trap.write_text(
            f"Tests/T/F.swift:56: Fatal error: 'try!' expression unexpectedly raised an error: {repo}/schemas/x.json missing\n"
            "*** Program crashed: Illegal instruction ***\n"
        )
        trap_run = [
            LedgerRecord("swift-shared", "P", "package", "pass", 0, 1, "", ""),
            LedgerRecord("swift-shared", "P", "test", "fail", 132, 1, str(trap), str(tmp / "none.xml")),
        ]
        _, t_queue = build_receipt(trap_run, {"suite": "swift-shared"}, repo, [str(repo)], oracle_exp.Expectations([], []))
        check("crash entry names the trap", t_queue[0]["tests"][0]["message"]
              == "test process crashed: Fatal error at Tests/T/F.swift:56: 'try!' expression unexpectedly raised an error: schemas/x.json missing")
        r_fatal, _ = parse_log("Foundation/EasyHandle.swift:293: Fatal error: 'try!' raised Code=43\n", [])
        check("fatal line is a loose message", parse_log("Foundation/EasyHandle.swift:293: Fatal error: boom\n", [])[1]
              == ["Fatal error at Foundation/EasyHandle.swift:293: boom"] and not r_fatal)

        ledger_file = tmp / "ledger.tsv"
        ledger_file.write_text("swift-tier\tX\tbuild\tpass\t0\t1.25\t/l.log\t\nswift-tier\tY\tbuild\tblocked\t0\t0\t\t\tX\n")
        check("ledger parse", read_ledger(ledger_file) == [
            LedgerRecord("swift-tier", "X", "build", "pass", 0, 1.25, "/l.log", ""),
            LedgerRecord("swift-tier", "Y", "build", "blocked", 0, 0, "", "", "X"),
        ])

    for name in failures:
        print(f"FAIL {name}")
    print(f"errors_queue selftest: {count - len(failures)}/{count} passed")
    return 1 if failures else 0


# ---------------------------------------------------------------------------------------- main


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    p_plan = sub.add_parser("plan", help="print `kind<TAB>name<TAB>deps<TAB>skip<TAB>path` rows in build order")
    p_plan.add_argument("--dump", type=Path, required=True, help="swift package dump-package output")
    p_plan.add_argument("--tier", type=Path, help="linux-tier.json (all manifest targets when absent)")
    p_plan.add_argument("--suite", default="swift-tier")
    p_plan.add_argument("--sanitize", default="")
    p_plan.add_argument("--root", type=Path, default=oracle_exp.DEFAULT_ROOT)

    p_shared = sub.add_parser("shared-packages", help="print `skip<TAB>path` rows of the shared runner's packages")
    p_shared.add_argument("--repo", type=Path, default=REPO_ROOT)
    p_shared.add_argument("--suite", default="swift-shared")
    p_shared.add_argument("--sanitize", default="")
    p_shared.add_argument("--root", type=Path, default=oracle_exp.DEFAULT_ROOT)

    p_receipt = sub.add_parser("receipt", help="write the receipt and the errors queue from a run's ledger")
    p_receipt.add_argument("--ledger", type=Path, required=True)
    p_receipt.add_argument("--receipt", type=Path, required=True)
    p_receipt.add_argument("--errors-queue", type=Path)
    p_receipt.add_argument("--repo", type=Path, default=REPO_ROOT)
    p_receipt.add_argument("--strip", action="append", default=[], help="path prefix to make repo-relative")
    p_receipt.add_argument("--root", type=Path, default=oracle_exp.DEFAULT_ROOT)
    p_receipt.add_argument("--meta", action="append", default=[], help="KEY=VALUE for the receipt header")

    p_prune = sub.add_parser("prune-tier", help="write the tier JSON without the named targets")
    p_prune.add_argument("--tier", type=Path, required=True)
    p_prune.add_argument("--out", type=Path, required=True)
    p_prune.add_argument("drop", nargs="*")

    sub.add_parser("selftest", help="run the self tests")
    args = parser.parse_args(argv)

    if args.command == "selftest":
        return _selftest()
    if args.command == "prune-tier":
        tier = json.loads(args.tier.read_text(encoding="utf-8"))
        args.out.write_text(json.dumps(prune_tier(tier, set(args.drop)), indent=2) + "\n", encoding="utf-8")
        return 0
    if args.command == "shared-packages":
        exp = linux_only(oracle_exp.Expectations.load_root(args.root))
        config = run_config(args.sanitize)
        for path in shared_packages(args.repo):
            skip = 0 if exp.should_run(args.suite, Path(path).name, config) else 1
            print(f"{skip}\t{path}")
        return 0
    if args.command == "plan":
        dump = json.loads(args.dump.read_text(encoding="utf-8"))
        tier = json.loads(args.tier.read_text(encoding="utf-8")) if args.tier and args.tier.is_file() else None
        exp = linux_only(oracle_exp.Expectations.load_root(args.root))
        config = run_config(args.sanitize)
        for row in plan(dump, tier):
            if row["kind"] == "missing":
                print(f"warning: tier target {row['name']} is not in the manifest", file=sys.stderr)
            skip = 0 if exp.should_run(args.suite, row["name"], config) else 1
            print(f"{row['kind']}\t{row['name']}\t{','.join(row['deps']) or '-'}\t{skip}\t{row['path'] or '-'}")
        return 0

    meta: dict = {}
    for item in args.meta:
        key, _, value = item.partition("=")
        meta[key] = value
    meta["dirty"] = meta.get("dirty") == "1"
    if "checkout_resolved_unchanged" in meta:
        meta["checkout_resolved_unchanged"] = meta["checkout_resolved_unchanged"] == "1"
    for key in ("jobs", "workers"):
        if meta.get(key, "").isdigit():
            meta[key] = int(meta[key])
    meta.setdefault("suite", "swift-tier")
    if args.errors_queue:
        meta["errors_queue"] = str(args.errors_queue)
    exp = oracle_exp.Expectations.load_root(args.root)
    receipt, queue = build_receipt(read_ledger(args.ledger), meta, args.repo, args.strip + [str(args.repo)], exp)
    args.receipt.parent.mkdir(parents=True, exist_ok=True)
    args.receipt.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    if args.errors_queue:
        write_queue(args.errors_queue, queue)
    print(render_summary(receipt))
    print(f"receipt: {args.receipt}")
    if args.errors_queue:
        print(f"errors queue: {args.errors_queue}")
    return 0 if receipt["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
