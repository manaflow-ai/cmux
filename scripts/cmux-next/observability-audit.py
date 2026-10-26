#!/usr/bin/env python3
"""Observability audit: the machine queues MQ1-MQ16 of the p09-observability program, with done-check counts.

plans/cmux-next/chrome-parity/p09-observability.md section 6 defines each queue as an `rg` query; this script
runs those queries, applies each queue's "done" rule to the hits, and prints the counts the program's done checks
quote (section 5). Run by hand from any directory; it is not wired to CI or to a hook (program rule 1).

Subcommands (each prints JSON with --json, task lines with --tasks, else a summary):

  catalog     MQ1 reserved catalog names with no emitter, MQ2 raw OSSignposter outside the catalog, MQ3 non-canonical
              log subsystems, MQ4 DEBUG-only timing traces without a Release mark, MQ5 perf-hot ids with no trace
              point (the ids come from perf-hot-benches.json), and launch_names (launch.* names with an emitter).
  clocks      MQ6 wall-clock duration sites, MQ15 ContinuousClock sites on trace, histogram or deadline paths.
  lanes       MQ7 Swift lanes to register with HangWatch, MQ8 Rust loop threads and runtimes for cmux-hang-watch.
  rust        MQ9 shipped binaries without a panic log or a black box (`--bundle APP` reads a built bundle; without
              it, the static list of shipped process entry points), MQ11 Command variants without a wire name.
  sentry      MQ10 Sentry options that the app sets differently from the CLI's quiet policy.
  histograms  MQ12 histogram catalog ids with no record site.
  threads     MQ13 unnamed Rust threads.
  tasks       MQ14 untraced detached tasks.
  asserts     MQ16 silent Release invariants (assertionFailure with no dumpWithoutCrashing next to it).
  all         every queue above.

Each queue is `{queue, title, hits: [{file, line, symbol}], count}`; `counts` holds the done-check keys. The script
needs Python 3.9+ and `rg` only: no network, no writes (the self-test feeds fixtures to `rg` on stdin).

  python3 scripts/cmux-next/observability-audit.py catalog --json
  python3 scripts/cmux-next/observability-audit.py clocks --tasks
  python3 scripts/cmux-next/observability-audit.py rust --bundle "/path/to/cmux NEXT.app" --json
  python3 scripts/cmux-next/observability-audit.py all --repo /path/to/other/checkout
  python3 scripts/cmux-next/observability-audit.py --self-test

Where a queue's text in the plan cannot be run literally, the script keeps its intent:
- MQ1 and MQ12 skip comment lines (a doc example such as `Signposter.event(.frameTick, ...)` is not an emitter),
  and MQ1 also counts `flowOut`, `flowIn` and `counter`, the typed points task 000 added for the key echo hops.
- MQ8 matches a builder chain across lines (`rg -U`).
- MQ11 finds `enum Command {` instead of a fixed line number, and after task 013 counts only the variants
  that `server/command_names.rs` does not name.
- MQ12 reads only `case` declarations (not `case let` arms of the name switch).
- MQ14 lists CmuxNextCompat's sites as excluded: Wakeups depends on Compat, so they cannot call TracedTask (task 124).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Dict, Iterable, List, Optional, Sequence, Tuple

SOURCES = "Packages/macOS/CmuxNext/Sources"
SIGNPOST_NAME = f"{SOURCES}/CmuxNextSignposts/SignpostName.swift"
HISTOGRAM_ID = f"{SOURCES}/CmuxNextMetrics/HistogramID.swift"
PERF_HOT_BENCHES = "scripts/cmux-next/perf-hot-benches.json"
THREADING_MODEL = "plans/cmux-next/threading-model.md"
CRASH_REPORTER = f"{SOURCES}/CmuxNextCrashReporting/CrashReporter.swift"
CLI_SENTRY_POLICY = "Packages/Shared/CmuxSentryTelemetry/Sources/CmuxSentryReporting/CLISentryRuntimePolicy.swift"
SERVER_RS = "cmux-tui/crates/cmux-tui-core/src/server.rs"
COMMAND_NAMES_RS = "cmux-tui/crates/cmux-tui-core/src/server/command_names.rs"
BURST_TRACE = f"{SOURCES}/CmuxNextControl/Diagnostics/BurstTrace.swift"
CRATES = "cmux-tui/crates"


# The exact queries of section 6. Each is the pattern rg runs; the self-test checks it against fixtures.
class Q:
    MQ1_CASES = r'case \.(\w+): "'
    MQ1_EMITTER = (
        r"\.(begin|end|event|interval|endSpanningNestedLoop|asyncBegin|asyncEnd|flowOut|flowIn|counter)"
        r"\(\.(\w+)\b|SignpostName\.(\w+)\b"
    )
    MQ2 = r"OSSignposter\("
    MQ3 = r'subsystem: "(?!com\.cmuxterm\.app\.next")'
    MQ4_DEBUG = r"^#if DEBUG \|\| CMUX_BENCH_HOOKS|^#if DEBUG$"
    MQ4_NAME = r"(Trace|Timings?|Timer)(\+\w+)?\.swift$"
    MQ4_EXCLUDE = r"Debug[A-Z]|CEFEventTrace|BurstTrace\+Control"
    MQ5_MARKER = r"// perf-hot: \S+ (\S+)"
    MQ5_TRACE = (
        r"Signposter\.|KeyFrameSignpost|InputFrameSignpost|ScrollFrameSignpost|SignpostActionRunTiming|Trace\.scope"
    )
    MQ6 = r"CFAbsoluteTimeGetCurrent\(\)|Date\(\)\.timeIntervalSince"
    MQ7 = r"DispatchQueue\(label:|Thread\.detachNewThread|= Thread\("
    MQ8_THREADS = (
        r'thread::Builder::new\(\)\s*\.name\(\s*(format!\()?"(mux-control-dispatch|mux-conn|mux-line-out|'
        r'mux-session-journal|mux-terminal-work|terminal-host-(pty|parser|client-input)|holder-link|surface-)'
    )
    MQ8_RUNTIMES = r"new_multi_thread\(\)"
    MQ9_PANIC = r"cmux_panic_log::install"
    MQ9_BLACKBOX = r"\binit_blackbox\("
    MQ10 = r"options\.(enable\w+|appHangTimeoutInterval)"
    MQ11_VARIANT = r"^\s{4}[A-Z][A-Za-z0-9]*\s*(\{|\(|,)"
    MQ12_CASES = r"case (\w+)"
    MQ12_RECORD = r"record\(\.(\w+)\b"
    MQ13 = r"std::thread::spawn\(|thread::spawn\("
    MQ14 = r"Task\.detached"
    MQ15 = r"ContinuousClock"
    MQ16 = r"assertionFailure\("


# Done rules applied to the hits (not rg queries: they read the matched file around the hit).
WALL_CLOCK_ESCAPE = re.compile(r"//\s*wall-clock:\s*\S")
CONTINUOUS_CLOCK_DONE = re.compile(r"\bTraceClock\b|\bSuspendingClock\b|//\s*continuous-clock:\s*\S")
HANG_WATCH_SWIFT = re.compile(r"\bHangWatch(Scope)?\b|\bregisterLane\(|\bregisterThread\(")
HANG_WATCH_RUST = re.compile(r"hang_watch::")
DUMP_WITHOUT_CRASHING = re.compile(r"dumpWithoutCrashing")
COMMENT_LINE = re.compile(r"^\s*(//|/\*|\*)")
LANE_LABEL = re.compile(r'DispatchQueue\(label:\s*"([^"\\]*)')
LANE_KEEP = re.compile(r"^(Nothing|Never|Non-blocking)|socket|PTY|read\(2\)|\bwrite\b|frame|`poll`|mailbox", re.I)
LANE_DROP = re.compile(r"^Disk|kqueue|Condvar|GCD QoS", re.I)


class AuditError(Exception):
    """A missing tool or input; the script exits 2 with the message."""


@dataclass
class Hit:
    file: str
    line: int
    symbol: str
    extra: Dict[str, object] = field(default_factory=dict)

    def to_json(self) -> Dict[str, object]:
        out: Dict[str, object] = {"file": self.file, "line": self.line, "symbol": self.symbol}
        out.update(self.extra)
        return out


@dataclass
class Queue:
    queue: str
    title: str
    hits: List[Hit]
    batching: str
    count_key: str
    batches: List[List[Hit]] = field(default_factory=list)
    notes: Dict[str, object] = field(default_factory=dict)

    @property
    def count(self) -> int:
        return len(self.hits)

    def to_json(self) -> Dict[str, object]:
        out: Dict[str, object] = {
            "queue": self.queue,
            "title": self.title,
            "count": self.count,
            "hits": [hit.to_json() for hit in self.hits],
        }
        out.update(self.notes)
        return out


# ---------------------------------------------------------------------------------------------------------------
# rg


@dataclass(frozen=True)
class RgMatch:
    file: str
    line: int
    text: str


class Rg:
    """Runs rg in one checkout. Paths in and out are repo-relative."""

    def __init__(self, repo: Path) -> None:
        self.repo = repo

    def _run(self, args: Sequence[str], stdin: Optional[str] = None) -> str:
        try:
            proc = subprocess.run(
                ["rg", "--no-config", *args],
                cwd=self.repo,
                input=stdin,
                capture_output=True,
                text=True,
                check=False,
            )
        except FileNotFoundError as error:
            raise AuditError("rg is not on PATH (install ripgrep)") from error
        if proc.returncode not in (0, 1):
            raise AuditError(f"rg {' '.join(args)} failed: {proc.stderr.strip()}")
        return proc.stdout

    def existing(self, paths: Iterable[str]) -> List[str]:
        return [p for p in paths if (self.repo / p).exists()]

    def lines(
        self,
        pattern: str,
        paths: Sequence[str],
        globs: Sequence[str] = (),
        pcre2: bool = False,
        multiline: bool = False,
    ) -> List[RgMatch]:
        """`rg PATTERN PATHS`: one match per line a match starts on (a multiline match counts once)."""
        paths = self.existing(paths)
        if not paths:
            return []
        args = ["--json"]
        if pcre2:
            args.append("--pcre2")
        if multiline:
            args.append("-U")
        for glob in globs:
            args += ["-g", glob]
        return parse_rg_json(self._run([*args, "-e", pattern, "--", *paths]))

    def files(self, pattern: str, paths: Sequence[str], globs: Sequence[str] = ()) -> List[str]:
        """`rg -l PATTERN PATHS`, sorted."""
        paths = self.existing(paths)
        if not paths:
            return []
        args = ["-l", "--color=never"]
        for glob in globs:
            args += ["-g", glob]
        return sorted(line for line in self._run([*args, "-e", pattern, "--", *paths]).splitlines() if line)

    def list_files(self, paths: Sequence[str], globs: Sequence[str] = ()) -> List[str]:
        paths = self.existing(paths)
        if not paths:
            return []
        args = ["--files"]
        for glob in globs:
            args += ["-g", glob]
        return sorted(line for line in self._run([*args, "--", *paths]).splitlines() if line)

    def stdin_matches(self, pattern: str, text: str, pcre2: bool = False, multiline: bool = False) -> List[str]:
        """The lines of `text` a match starts on (self-test fixtures)."""
        args = ["--json"]
        if pcre2:
            args.append("--pcre2")
        if multiline:
            args.append("-U")
        out = self._run([*args, "-e", pattern, "-"], stdin=text)
        return [m.text for m in parse_rg_json(out)]


def parse_rg_json(out: str) -> List[RgMatch]:
    """rg --json output to one RgMatch per (file, start line) of each submatch, with that line's text."""
    matches: List[RgMatch] = []
    seen = set()
    for raw in out.splitlines():
        try:
            message = json.loads(raw)
        except ValueError:
            continue
        if message.get("type") != "match":
            continue
        data = message["data"]
        path = data["path"].get("text", "")
        path = path[2:] if path.startswith("./") else path
        text = data["lines"].get("text", "")
        block = text.encode("utf-8")
        for sub in data.get("submatches") or [{"start": 0}]:
            offset = text_offset_lines(block, sub["start"])
            line = data["line_number"] + offset
            key = (path, line)
            if key in seen:
                continue
            seen.add(key)
            matches.append(RgMatch(path, line, text.split("\n")[offset] if text else ""))
    return matches


def text_offset_lines(block: bytes, byte_offset: int) -> int:
    """How many newlines come before `byte_offset` in a match block (rg reports byte offsets)."""
    return block[:byte_offset].count(b"\n")


def is_comment(text: str) -> bool:
    return bool(COMMENT_LINE.match(text))


# ---------------------------------------------------------------------------------------------------------------
# File reading helpers (read-only)


class Files:
    def __init__(self, repo: Path) -> None:
        self.repo = repo
        self._cache: Dict[str, List[str]] = {}

    def lines(self, rel: str) -> List[str]:
        if rel not in self._cache:
            path = self.repo / rel
            try:
                self._cache[rel] = path.read_text(encoding="utf-8", errors="replace").splitlines()
            except OSError:
                self._cache[rel] = []
        return self._cache[rel]

    def exists(self, rel: str) -> bool:
        return (self.repo / rel).exists()


def near(lines: List[str], line: int, pattern: re.Pattern, before: int = 1, after: int = 0) -> bool:
    """Whether `pattern` matches line `line` (1-based) or the `before` lines above or `after` lines below it."""
    lo = max(0, line - 1 - before)
    hi = min(len(lines), line + after)
    return any(pattern.search(text) for text in lines[lo:hi])


IF_DIRECTIVE = re.compile(r"^\s*#\s*(if|elseif|else|endif)\b(.*)$")


def debug_only_lines(lines: List[str]) -> List[bool]:
    """For each line, whether it compiles only in DEBUG builds (inside an `#if DEBUG...` branch, not its `#else`)."""
    flags: List[bool] = []
    stack: List[bool] = []  # per open #if: is the current branch DEBUG-only
    for text in lines:
        m = IF_DIRECTIVE.match(text)
        if m:
            kind, cond = m.group(1), m.group(2)
            if kind == "if":
                stack.append(condition_is_debug(cond))
            elif kind == "elseif" and stack:
                stack[-1] = condition_is_debug(cond)
            elif kind == "else" and stack:
                stack[-1] = False
            elif kind == "endif" and stack:
                stack.pop()
            flags.append(any(stack))
            continue
        flags.append(any(stack))
    return flags


def condition_is_debug(cond: str) -> bool:
    cond = cond.strip()
    return bool(re.match(r"^\(?\s*DEBUG\b", cond)) and "!" not in cond.split("DEBUG")[0]


# ---------------------------------------------------------------------------------------------------------------
# Batching for --tasks


def chunk(items: List, size: int) -> List[List]:
    return [items[i : i + size] for i in range(0, len(items), size)] if items else []


def per_hit(hits: List[Hit]) -> List[List[Hit]]:
    return [[hit] for hit in hits]


def by_files(hits: List[Hit], files_per_batch: int) -> List[List[Hit]]:
    files: Dict[str, List[Hit]] = {}
    for hit in hits:
        files.setdefault(hit.file, []).append(hit)
    groups = chunk(sorted(files), files_per_batch)
    return [[hit for f in group for hit in files[f]] for group in groups]


def package_group(path: str) -> str:
    parts = path.split("/")
    if "Sources" in parts:
        i = parts.index("Sources")
        if i + 1 < len(parts):
            return parts[i + 1]
    return "/".join(parts[:3])


def by_package_files(hits: List[Hit], files_per_batch: int) -> List[List[Hit]]:
    """Batches of at most `files_per_batch` files; a batch takes whole packages while they fit."""
    packages: Dict[str, Dict[str, List[Hit]]] = {}
    for hit in hits:
        packages.setdefault(package_group(hit.file), {}).setdefault(hit.file, []).append(hit)
    batches: List[List[Hit]] = []
    current: List[str] = []
    current_files: Dict[str, List[Hit]] = {}
    for package in sorted(packages):
        files = packages[package]
        if current and len(current) + len(files) > files_per_batch:
            batches.append([h for f in current for h in current_files[f]])
            current, current_files = [], {}
        for f in sorted(files):
            if len(current) == files_per_batch:
                batches.append([h for g in current for h in current_files[g]])
                current, current_files = [], {}
            current.append(f)
            current_files[f] = files[f]
    if current:
        batches.append([h for f in current for h in current_files[f]])
    return batches


def by_hits(hits: List[Hit], size: int) -> List[List[Hit]]:
    return chunk(hits, size)


def one_task(hits: List[Hit]) -> List[List[Hit]]:
    return [hits] if hits else []


def task_lines(queue: Queue) -> List[str]:
    out: List[str] = []
    total = len(queue.batches)
    for i, batch in enumerate(queue.batches, 1):
        files = sorted({hit.file for hit in batch})
        if len(batch) == 1:
            hit = batch[0]
            where = f"{hit.file}:{hit.line}" if hit.line else hit.file
            out.append(f"{queue.queue} {i}/{total}: {queue.title}: {hit.symbol} ({where})")
        else:
            out.append(
                f"{queue.queue} {i}/{total}: {queue.title}: {len(batch)} hits in {len(files)} files: "
                + ", ".join(files)
            )
    return out


# ---------------------------------------------------------------------------------------------------------------
# Queues


class Audit:
    def __init__(self, repo: Path) -> None:
        self.repo = repo
        self.rg = Rg(repo)
        self.files = Files(repo)

    # MQ1 ---------------------------------------------------------------------------------------------------
    def catalog_names(self) -> List[Tuple[str, str, int]]:
        """(case, wire name, declaration line) for every SignpostName case."""
        lines = self.files.lines(SIGNPOST_NAME)
        if not lines:
            raise AuditError(f"{SIGNPOST_NAME} is missing")
        wire: Dict[str, str] = {}
        for m in self.rg.lines(Q.MQ1_CASES, [SIGNPOST_NAME]):
            cm = re.search(r'case \.(\w+): "([^"]*)"', m.text)
            if cm and cm.group(1) not in wire:
                wire[cm.group(1)] = cm.group(2)
        decl: Dict[str, int] = {}
        for i, text in enumerate(lines, 1):
            dm = re.match(r"\s*case (\w+)\s*(=|$)", text)
            if dm and dm.group(1) not in decl:
                decl[dm.group(1)] = i
        return [(case, name, decl.get(case, 0)) for case, name in wire.items()]

    def emitted_signpost_names(self) -> set:
        emitted = set()
        for m in self.rg.lines(
            Q.MQ1_EMITTER,
            [SOURCES],
            globs=["!**/SignpostName.swift", "!**/SignpostMetricKitMirror.swift"],
        ):
            if is_comment(m.text):
                continue
            for em in re.finditer(Q.MQ1_EMITTER, m.text):
                emitted.add(em.group(2) or em.group(3))
        return emitted

    def mq1(self) -> Tuple[Queue, int]:
        names = self.catalog_names()
        emitted = self.emitted_signpost_names()
        hits = [
            Hit(SIGNPOST_NAME, line, case, {"name": wire})
            for case, wire, line in names
            if case not in emitted
        ]
        launch_names = sum(1 for case, wire, _ in names if wire.startswith("launch.") and case in emitted)
        q = Queue("MQ1", "Reserved catalog name with no emitter", hits, "per hit", "reserved_without_emitter")
        q.batches = per_hit(hits)
        q.notes = {"catalog_size": len(names)}
        return q, launch_names

    # MQ2 ---------------------------------------------------------------------------------------------------
    def mq2(self) -> Queue:
        files = self.rg.files(Q.MQ2, [SOURCES], globs=["!**/CmuxNextSignposts/**"])
        hits: List[Hit] = []
        for f in files:
            first = next((m.line for m in self.rg.lines(Q.MQ2, [f])), 0)
            hits.append(Hit(f, first, "OSSignposter("))
        q = Queue("MQ2", "Raw OSSignposter to the catalog", hits, "3 files", "raw_ossignposter_outside_catalog")
        q.batches = by_files(hits, 3)
        return q

    # MQ3 ---------------------------------------------------------------------------------------------------
    def mq3(self) -> Queue:
        hits = [
            Hit(m.file, m.line, (re.search(r'subsystem: "([^"]*)"', m.text) or re.search(r"(.*)", m.text)).group(1))
            for m in self.rg.lines(Q.MQ3, [SOURCES], pcre2=True)
        ]
        q = Queue("MQ3", "Log subsystem to com.cmuxterm.app.next", hits, "1 task", "noncanonical_log_subsystem")
        q.batches = one_task(hits)
        return q

    # MQ4 ---------------------------------------------------------------------------------------------------
    def mq4_candidates(self) -> List[str]:
        files = [
            f
            for f in self.rg.files(Q.MQ4_DEBUG, [SOURCES])
            if re.search(Q.MQ4_NAME, f) and not re.search(Q.MQ4_EXCLUDE, f)
        ]
        if self.files.exists(BURST_TRACE) and BURST_TRACE not in files:
            files.append(BURST_TRACE)
        return sorted(files)

    def has_release_mark(self, rel: str) -> bool:
        lines = self.files.lines(rel)
        debug = debug_only_lines(lines)
        emitter = re.compile(Q.MQ1_EMITTER + "|" + Q.MQ5_TRACE)
        return any(
            not debug[i] and not is_comment(text) and emitter.search(text) for i, text in enumerate(lines)
        )

    def mq4(self) -> Queue:
        hits = [Hit(f, 0, Path(f).stem) for f in self.mq4_candidates() if not self.has_release_mark(f)]
        q = Queue(
            "MQ4", "Release mark from a DEBUG-only timing trace", hits, "3 files",
            "debug_only_timers_without_release_mark",
        )
        q.batches = by_files(hits, 3)
        return q

    # MQ5 ---------------------------------------------------------------------------------------------------
    def perf_hot_ids(self) -> Dict[str, dict]:
        path = self.repo / PERF_HOT_BENCHES
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as error:
            raise AuditError(f"{PERF_HOT_BENCHES}: {error}") from error
        paths = data.get("paths", {})
        if not isinstance(paths, dict):
            raise AuditError(f"{PERF_HOT_BENCHES}: `paths` is not an object")
        return paths

    def mq5(self) -> Queue:
        ids = self.perf_hot_ids()
        marked: Dict[str, List[RgMatch]] = {}
        for m in self.rg.lines(Q.MQ5_MARKER, ["Packages"], globs=["*.swift"]):
            mm = re.search(Q.MQ5_MARKER, m.text)
            if mm:
                marked.setdefault(mm.group(1), []).append(m)
        trace = re.compile(Q.MQ5_TRACE)
        hits: List[Hit] = []
        for pid in sorted(ids):
            entry = ids[pid] if isinstance(ids[pid], dict) else {}
            sites = marked.get(pid, [])
            files = sorted({s.file for s in sites})
            traced = [f for f in files if any(trace.search(t) for t in self.files.lines(f) if not is_comment(t))]
            reasons = []
            if not files:
                reasons.append("no `// perf-hot:` marker")
            elif not traced:
                reasons.append("no trace point in its marked files")
            if not entry.get("trace"):
                reasons.append("no `trace` field")
            if reasons:
                first = sites[0] if sites else None
                hits.append(
                    Hit(
                        first.file if first else PERF_HOT_BENCHES,
                        first.line if first else 0,
                        pid,
                        {"reasons": reasons, "marked_files": files},
                    )
                )
        q = Queue("MQ5", "perf-hot id with a trace point and a trace field", hits, "per hit", "perf_hot_ids_without_trace")
        q.batches = per_hit(hits)
        q.notes = {"ids": len(ids)}
        return q

    # MQ6 ---------------------------------------------------------------------------------------------------
    def mq6(self) -> Queue:
        hits = [
            Hit(m.file, m.line, m.text.strip()[:120])
            for m in self.rg.lines(Q.MQ6, [SOURCES])
            if not near(self.files.lines(m.file), m.line, WALL_CLOCK_ESCAPE)
        ]
        q = Queue("MQ6", "Wall clock to TraceClock", hits, "<=15 files per package group", "wallclock_duration_sites")
        q.batches = by_package_files(hits, 15)
        q.notes = {"files": len({h.file for h in hits})}
        return q

    # MQ15 --------------------------------------------------------------------------------------------------
    def mq15(self) -> Queue:
        all_matches = self.rg.lines(Q.MQ15, [SOURCES])
        hits = [
            Hit(m.file, m.line, m.text.strip()[:120])
            for m in all_matches
            if not near(self.files.lines(m.file), m.line, CONTINUOUS_CLOCK_DONE)
        ]
        q = Queue(
            "MQ15", "ContinuousClock to TraceClock or SuspendingClock, or say why", hits, "<=15 files",
            "continuous_clock_trace_sites",
        )
        q.batches = by_package_files(hits, 15)
        q.notes = {
            "lines_naming_continuous_clock": len(all_matches),
            "now_sites": sum(1 for m in all_matches if "ContinuousClock.now" in m.text or "ContinuousClock().now" in m.text),
            "files": len({h.file for h in hits}),
        }
        return q

    # MQ7 ---------------------------------------------------------------------------------------------------
    def threading_rows(self) -> List[Tuple[str, str]]:
        """(whole row, May block on) for each row of threading-model.md's thread table."""
        return thread_table_rows(self.files.lines(THREADING_MODEL))

    def mq7(self) -> Queue:
        rows = self.threading_rows()
        hits: List[Hit] = []
        unclassified: List[Hit] = []
        dropped: List[Hit] = []
        registered = 0
        for m in self.rg.lines(Q.MQ7, [SOURCES]):
            if is_comment(m.text):
                continue
            label_match = LANE_LABEL.search(m.text)
            label = label_match.group(1).split("\\(")[0] if label_match else ""
            stem = Path(m.file).stem.split("+")[0]
            row = next((r for r in rows if label and label in r[0]), None) or next(
                (r for r in rows if re.search(r"\b" + re.escape(stem) + r"\b", r[0])), None
            )
            hit = Hit(m.file, m.line, label or m.text.strip()[:80])
            if row is None:
                hit.extra["reason"] = "no threading-model row names this lane"
                unclassified.append(hit)
                continue
            hit.extra["may_block_on"] = row[1][:80]
            if LANE_DROP.search(row[1]) or not LANE_KEEP.search(row[1]):
                dropped.append(hit)
                continue
            if HANG_WATCH_SWIFT.search("\n".join(self.files.lines(m.file))):
                registered += 1
                continue
            hits.append(hit)
        q = Queue("MQ7", "Register the Swift lane with HangWatch", hits, "per file", "swift_lanes_unregistered")
        q.batches = by_files(hits, 1)
        q.notes = {
            "registered": registered,
            "dropped_by_threading_model": [h.to_json() for h in dropped],
            "unclassified": [h.to_json() for h in unclassified],
        }
        return q

    # MQ8 ---------------------------------------------------------------------------------------------------
    def mq8(self) -> Queue:
        thread_paths = [f"{CRATES}/{c}/src" for c in ("cmux-tui-core", "cmux-tui", "cmux-holder")]
        runtime_paths = [f"{CRATES}/{c}/src" for c in ("cmux-tui", "acpmux")]
        hits: List[Hit] = []
        registered = 0
        for kind, matches in (
            ("thread", self.rg.lines(Q.MQ8_THREADS, thread_paths, multiline=True)),
            ("runtime", self.rg.lines(Q.MQ8_RUNTIMES, runtime_paths)),
        ):
            for m in matches:
                if is_comment(m.text):
                    continue
                if HANG_WATCH_RUST.search("\n".join(self.files.lines(m.file))):
                    registered += 1
                    continue
                nm = re.search(r'\.name\(\s*(?:format!\()?"([^"{]*)', m.text)
                symbol = nm.group(1) if nm else ("new_multi_thread" if kind == "runtime" else "thread")
                hits.append(Hit(m.file, m.line, symbol, {"kind": kind}))
        q = Queue("MQ8", "Register the Rust loop thread with cmux-hang-watch", hits, "per file", "rust_loops_unregistered")
        q.batches = by_files(hits, 1)
        q.notes = {"registered": registered}
        return q

    # MQ9 ---------------------------------------------------------------------------------------------------
    def mq9(self, bundle: Optional[Path]) -> Tuple[Queue, Dict[str, object]]:
        roles = SHIPPED_ROLES
        if bundle is None:
            evaluated = [(role, role.bin, None) for role in roles]
            unmapped: List[str] = []
            source = "static"
        else:
            evaluated, unmapped = self.bundle_roles(bundle)
            source = str(bundle)
        hits: List[Hit] = []
        panic_missing = 0
        blackbox_missing = 0
        for role, binary, crate_dir in evaluated:
            paths = role.files if role.files else [crate_dir]
            has_panic = self.has_pattern(Q.MQ9_PANIC, paths)
            has_blackbox = self.has_pattern(Q.MQ9_BLACKBOX, paths)
            missing = []
            if role.panic and not has_panic:
                missing.append("panic_log")
                panic_missing += 1
            if role.blackbox and not has_blackbox:
                missing.append("blackbox")
                blackbox_missing += 1
            if missing:
                hits.append(Hit(paths[0], 0, role.name, {"binary": binary, "missing": missing}))
        q = Queue("MQ9", "Panic log and black box in the shipped binary", hits, "per hit", "panic_log_missing")
        q.batches = per_hit(hits)
        q.notes = {"source": source, "unmapped_binaries": unmapped}
        return q, {"panic_log_missing": panic_missing, "blackbox_init_missing": blackbox_missing}

    def has_pattern(self, pattern: str, paths: Sequence[str]) -> bool:
        return any(not is_comment(m.text) for m in self.rg.lines(pattern, paths, globs=["*.rs"]))

    def cargo_bins(self) -> Dict[str, Tuple[str, str]]:
        """Binary name -> (crate dir, entry file), from every Cargo.toml in the checkout."""
        bins: Dict[str, Tuple[str, str]] = {}
        for manifest in self.rg.list_files(["."], globs=["Cargo.toml", "!**/target/**"]):
            manifest = manifest[2:] if manifest.startswith("./") else manifest
            text = "\n".join(self.files.lines(manifest))
            crate_dir = str(Path(manifest).parent)
            for name, entry in parse_cargo_bins(text, crate_dir, lambda rel: self.files.exists(rel)):
                bins.setdefault(name, (crate_dir, entry))
        return bins

    def bundle_roles(self, bundle: Path) -> Tuple[List[Tuple["ShippedRole", str, Optional[str]]], List[str]]:
        if not bundle.is_dir():
            raise AuditError(f"--bundle {bundle}: not a directory")
        binaries = bundle_macho_names(bundle)
        cargo = self.cargo_bins()
        evaluated: List[Tuple[ShippedRole, str, Optional[str]]] = []
        unmapped: List[str] = []
        for binary in binaries:
            bin_name = BUNDLE_ALIASES.get(binary, binary)
            roles = [role for role in SHIPPED_ROLES if role.bin == bin_name]
            if roles:
                evaluated += [(role, binary, None) for role in roles]
            elif bin_name in cargo:
                crate_dir, _entry = cargo[bin_name]
                evaluated.append((ShippedRole(bin_name, bin_name, (), panic=True, blackbox=False), binary, crate_dir))
            else:
                unmapped.append(binary)
        return evaluated, unmapped

    # MQ10 --------------------------------------------------------------------------------------------------
    def mq10(self) -> Queue:
        app = sentry_options(self.rg.lines(Q.MQ10 + r"\s*=\s*[^\n]+", [CRASH_REPORTER]))
        cli = sentry_options(self.rg.lines(Q.MQ10 + r"\s*=\s*[^\n]+", [CLI_SENTRY_POLICY]))
        hits: List[Hit] = []
        for option, (cli_value, _line) in sorted(cli.items()):
            app_value, app_line = app.get(option, ("unset", 0))
            if app_value != cli_value:
                hits.append(
                    Hit(CRASH_REPORTER, app_line, option, {"app": app_value, "cli": cli_value})
                )
        hang = app.get("appHangTimeoutInterval")
        if hang and app.get("enableAppHangTracking", ("unset", 0))[0] != "false" and not any(
            h.symbol == "enableAppHangTracking" for h in hits
        ):
            hits.append(Hit(CRASH_REPORTER, hang[1], "appHangTimeoutInterval", {"app": hang[0], "cli": "tracking off"}))
        q = Queue("MQ10", "Sentry option that adds wakeups or swizzles", hits, "1 task", "sentry_option_diffs")
        q.batches = one_task(hits)
        return q

    # MQ11 --------------------------------------------------------------------------------------------------
    def command_variants(self) -> List[Tuple[str, int]]:
        lines = self.files.lines(SERVER_RS)
        start = next((i for i, t in enumerate(lines) if re.match(r"^(pub(\(\w+\))? )?enum Command \{", t)), None)
        if start is None:
            raise AuditError(f"{SERVER_RS}: `enum Command {{` not found")
        variants: List[Tuple[str, int]] = []
        variant = re.compile(Q.MQ11_VARIANT)
        for i in range(start + 1, len(lines)):
            text = lines[i]
            if text.startswith("}"):
                break
            if variant.match(text):
                variants.append((re.match(r"^\s{4}([A-Z][A-Za-z0-9]*)", text).group(1), i + 1))
        return variants

    def mq11(self) -> Queue:
        variants = self.command_variants()
        named = command_names_rows("\n".join(self.files.lines(COMMAND_NAMES_RS)))
        hits = [Hit(SERVER_RS, line, name) for name, line in variants if name not in named]
        q = Queue("MQ11", "Command variant with a wire name", hits, "1 task", "command_variants_without_wire_name")
        q.batches = one_task(hits)
        q.notes = {"variants": len(variants), "wire_name_match": self.files.exists(COMMAND_NAMES_RS)}
        return q

    # MQ12 --------------------------------------------------------------------------------------------------
    def histogram_ids(self) -> List[Tuple[str, int]]:
        ids: List[Tuple[str, int]] = []
        seen = set()
        for m in self.rg.lines(Q.MQ12_CASES, [HISTOGRAM_ID]):
            if is_comment(m.text):
                continue
            dm = re.match(r"^\s*case (\w+)\b", m.text)
            if dm and dm.group(1) not in ("let", "var") and dm.group(1) not in seen:
                seen.add(dm.group(1))
                ids.append((dm.group(1), m.line))
        return ids

    def mq12(self) -> Queue:
        if not self.files.exists(HISTOGRAM_ID):
            q = Queue("MQ12", "Histogram id with a record site", [], "per id", "histogram_ids_without_record")
            q.notes = {"catalog": "absent (before task 000)"}
            return q
        ids = self.histogram_ids()
        recorded = set()
        for m in self.rg.lines(Q.MQ12_RECORD, [SOURCES, CRATES]):
            if is_comment(m.text):
                continue
            recorded.update(rm.group(1) for rm in re.finditer(Q.MQ12_RECORD, m.text))
        hits = [Hit(HISTOGRAM_ID, line, name) for name, line in ids if name not in recorded]
        q = Queue("MQ12", "Histogram id with a record site", hits, "per id", "histogram_ids_without_record")
        q.batches = per_hit(hits)
        q.notes = {"ids": len(ids)}
        return q

    # MQ13 --------------------------------------------------------------------------------------------------
    def mq13(self) -> Queue:
        crates = ("cmux-tui-core", "cmux-tui", "cmux-holder", "acpmux", "cmux-app-host", "cmux-browser-host")
        hits = [
            Hit(m.file, m.line, m.text.strip()[:120])
            for m in self.rg.lines(
                Q.MQ13, [f"{CRATES}/{c}/src" for c in crates], globs=["!**/tests/**", "!**/*tests*.rs"]
            )
            if not is_comment(m.text)
        ]
        q = Queue("MQ13", "Name the Rust thread", hits, "<=40 hits", "unnamed_rust_threads")
        q.batches = by_hits(hits, 40)
        return q

    # MQ14 --------------------------------------------------------------------------------------------------
    def mq14(self) -> Queue:
        hits: List[Hit] = []
        excluded: List[Hit] = []
        for m in self.rg.lines(Q.MQ14, [SOURCES]):
            if is_comment(m.text):
                continue
            hit = Hit(m.file, m.line, m.text.strip()[:120])
            (excluded if "/CmuxNextCompat/" in m.file else hits).append(hit)
        q = Queue("MQ14", "TracedTask.detached for the detached task", hits, "<=30 hits", "untraced_detached_tasks")
        q.batches = by_hits(hits, 30)
        q.notes = {"excluded_compat": [h.to_json() for h in excluded]}
        return q

    # MQ16 --------------------------------------------------------------------------------------------------
    def mq16(self) -> Queue:
        hits = [
            Hit(m.file, m.line, m.text.strip()[:120])
            for m in self.rg.lines(Q.MQ16, [SOURCES])
            if not is_comment(m.text)
            and not near(self.files.lines(m.file), m.line, DUMP_WITHOUT_CRASHING, before=3, after=3)
        ]
        q = Queue("MQ16", "dumpWithoutCrashing next to the Release invariant", hits, "1 task", "silent_release_invariants")
        q.batches = one_task(hits)
        return q

    # Subcommands -------------------------------------------------------------------------------------------
    def run(self, command: str, bundle: Optional[Path]) -> Tuple[List[Queue], Dict[str, object]]:
        queues: List[Queue] = []
        counts: Dict[str, object] = {}

        def add(q: Queue) -> None:
            queues.append(q)
            counts[q.count_key] = q.count

        if command in ("catalog", "all"):
            q1, launch = self.mq1()
            add(q1)
            for q in (self.mq2(), self.mq3(), self.mq4(), self.mq5()):
                add(q)
            counts["perf_hot_ids"] = queues[-1].notes["ids"]
            counts["launch_names"] = launch
        if command in ("clocks", "all"):
            q6 = self.mq6()
            add(q6)
            counts["wallclock_duration_files"] = q6.notes["files"]
            add(self.mq15())
        if command in ("lanes", "all"):
            q7 = self.mq7()
            add(q7)
            counts["swift_lanes_unclassified"] = len(q7.notes["unclassified"])
            add(self.mq8())
        if command in ("rust", "all"):
            q9, rust_counts = self.mq9(bundle)
            queues.append(q9)
            counts.update(rust_counts)
            add(self.mq11())
        if command in ("sentry", "all"):
            add(self.mq10())
        if command in ("histograms", "all"):
            add(self.mq12())
        if command in ("threads", "all"):
            add(self.mq13())
        if command in ("tasks", "all"):
            add(self.mq14())
        if command in ("asserts", "all"):
            add(self.mq16())
        return queues, counts


# ---------------------------------------------------------------------------------------------------------------
# MQ9 inputs


@dataclass(frozen=True)
class ShippedRole:
    """One shipped Rust process: the files its `main` path runs through, and what it must install."""

    name: str
    bin: str
    files: Tuple[str, ...]
    panic: bool
    blackbox: bool


# The static fallback of MQ9 (section 6), and the role map a bundle's binaries go through. `blackbox` follows task
# 095's seven mains; `panic` follows tasks 080, 099 and 100.
SHIPPED_ROLES: Tuple[ShippedRole, ...] = (
    ShippedRole("daemon", "cmux-tui", (f"{CRATES}/cmux-tui/src/owner_start.rs", f"{CRATES}/cmux-tui/src/owner_start"), True, True),
    ShippedRole("mcp-serve", "cmux-tui", (f"{CRATES}/cmux-tui/src/cli/mcp.rs",), True, False),
    ShippedRole("terminal-host", "cmux-tui-host", (f"{CRATES}/cmux-tui/src/bin/cmux-tui-host.rs",), True, True),
    ShippedRole("holder", "cmux-holder", (f"{CRATES}/cmux-holder/src/main.rs",), True, True),
    ShippedRole("acpmux", "acpmux", (f"{CRATES}/acpmux/src/daemon.rs",), True, True),
    ShippedRole("agent-host", "acpmux", (f"{CRATES}/acpmux/src/agent_host/host.rs",), True, True),
    ShippedRole("app-host", "cmux-app-host", (f"{CRATES}/cmux-app-host/src/main.rs",), True, True),
    ShippedRole("browser-host", "cmux-browser-host", (f"{CRATES}/cmux-browser-host/src/bin/cmux-browser-host.rs",), True, True),
    ShippedRole("cmux-cloud", "cmux-cloud", ("first-party-apps/cloud/server/src/main.rs",), True, False),
    ShippedRole("optchat-chief", "optchat-chief", ("Native/OptChat/optchat-chief/src/main.rs",), True, False),
    ShippedRole("diff-sidecar", "cmux-diff-sidecar", ("Native/DiffSidecar/src/main.rs",), True, False),
)

# Bundle file names that are not their Cargo binary name ("Bundle cmux-tui" installs cmux-tui as `cmux`).
BUNDLE_ALIASES = {"cmux": "cmux-tui"}

MACHO_MAGICS = {
    b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe",
    b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca",
}


def is_macho(head: bytes) -> bool:
    return head[:4] in MACHO_MAGICS


def bundle_macho_names(bundle: Path) -> List[str]:
    """The Mach-O file names in Contents/Resources/{bin,libexec} and Contents/Frameworks/*.app/Contents/MacOS."""
    dirs = [bundle / "Contents/Resources/bin", bundle / "Contents/Resources/libexec"]
    frameworks = bundle / "Contents/Frameworks"
    if frameworks.is_dir():
        dirs += sorted(p / "Contents/MacOS" for p in frameworks.glob("*.app"))
    names: List[str] = []
    seen = set()
    for d in dirs:
        if not d.is_dir():
            continue
        for path in sorted(d.iterdir()):
            if not path.is_file():
                continue
            try:
                with open(path, "rb") as handle:
                    head = handle.read(4)
            except OSError:
                continue
            if is_macho(head) and path.name not in seen:
                seen.add(path.name)
                names.append(path.name)
    return names


def parse_cargo_bins(text: str, crate_dir: str, exists: Callable[[str], bool]) -> List[Tuple[str, str]]:
    """(binary name, entry file) for a Cargo.toml: its [[bin]] tables plus Cargo's implicit binaries."""
    package = None
    autobins = True
    bins: List[Tuple[str, str]] = []
    section = ""
    current: Dict[str, str] = {}

    def flush() -> None:
        if section == "[[bin]]" and current.get("name"):
            bins.append((current["name"], f"{crate_dir}/{current.get('path', 'src/main.rs')}"))

    for raw in text.splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        if line.startswith("["):
            flush()
            section, current = line, {}
            continue
        km = re.match(r'^([A-Za-z0-9_-]+)\s*=\s*(.+)$', line)
        if not km:
            continue
        key, value = km.group(1), km.group(2).strip()
        sm = re.match(r'^"([^"]*)"$', value)
        if section == "[package]":
            if key == "name" and sm:
                package = sm.group(1)
            elif key == "autobins":
                autobins = value != "false"
        elif section == "[[bin]]" and sm:
            current[key] = sm.group(1)
    flush()
    declared = {name for name, _ in bins}
    entries = {entry for _, entry in bins}
    if autobins and package and package not in declared and exists(f"{crate_dir}/src/main.rs") and f"{crate_dir}/src/main.rs" not in entries:
        bins.append((package, f"{crate_dir}/src/main.rs"))
    return bins


def thread_table_rows(lines: List[str]) -> List[Tuple[str, str]]:
    """(whole row, May block on) for each row of the table headed `| Thread / queue |`, not the later tables."""
    rows: List[Tuple[str, str]] = []
    inside = False
    for text in lines:
        if not text.startswith("|"):
            if inside:
                break
            continue
        cells = [c.strip() for c in text.strip().strip("|").split("|")]
        if cells[0] == "Thread / queue":
            inside = True
            continue
        if inside and not text.startswith("|---") and len(cells) >= 3 and cells[2]:
            rows.append((text, cells[2]))
    return rows


COMMAND_TABLE_ROW = re.compile(r'^\s*([A-Z][A-Za-z0-9]*)\s*=>\s*"', re.M)
COMMAND_PATH = re.compile(r"Command::([A-Z][A-Za-z0-9]*)")


def command_names_rows(text: str) -> set:
    """The variants command_names.rs names: `command_table!` rows (`Ping => "ping", Query;`) or `Command::X` arms."""
    code = "\n".join(line for line in text.splitlines() if not is_comment(line))
    return set(COMMAND_TABLE_ROW.findall(code)) | set(COMMAND_PATH.findall(code))


def sentry_options(matches: List[RgMatch]) -> Dict[str, Tuple[str, int]]:
    out: Dict[str, Tuple[str, int]] = {}
    for m in matches:
        if is_comment(m.text):
            continue
        om = re.search(r"options\.(\w+)\s*=\s*(.+?)\s*(//.*)?$", m.text)
        if om:
            out[om.group(1)] = (om.group(2), m.line)
    return out


# ---------------------------------------------------------------------------------------------------------------
# Output


def summary(queues: List[Queue], counts: Dict[str, object]) -> str:
    out = []
    for q in queues:
        out.append(f"{q.queue:5} {q.count:5}  {q.title}")
    out.append("")
    for key, value in counts.items():
        out.append(f"{key} = {value}")
    return "\n".join(out)


# ---------------------------------------------------------------------------------------------------------------
# Self-test: every query against fixture strings, and the done rules against in-memory files.


def self_test() -> int:
    rg = Rg(Path.cwd())
    checks = 0
    failures: List[str] = []

    def expect(label: str, got, want) -> None:
        nonlocal checks
        checks += 1
        if got != want:
            failures.append(f"{label}: got {got!r}, want {want!r}")

    def lines_of(pattern: str, text: str, **kw) -> List[str]:
        return rg.stdin_matches(pattern, text, **kw)

    expect("MQ1 cases", lines_of(Q.MQ1_CASES, 'case .motionFrame: "motion.frame"\ncase motionFrame = 4\n'),
           ['case .motionFrame: "motion.frame"'])
    emit = (
        "Signposter.motion.begin(.motionFrame, \"x\")\n"
        "Signposter.asyncBegin(.createTab, id: 1)\n"
        "TraceRuntime.shared.flowOut(.keyEchoLineOut, flow: f)\n"
        "let name = SignpostName.cefPump\n"
        "foo.beginning(.motionRun)\n"
    )
    expect("MQ1 emitter", len(lines_of(Q.MQ1_EMITTER, emit)), 4)
    found = set()
    for text in emit.splitlines():
        for m in re.finditer(Q.MQ1_EMITTER, text):
            found.add(m.group(2) or m.group(3))
    expect("MQ1 emitter names", found, {"motionFrame", "createTab", "keyEchoLineOut", "cefPump"})
    expect("comment line", [is_comment(t) for t in ("/// Signposter.event(.frameTick)", "  // x", "x // y")],
           [True, True, False])
    expect("MQ2", lines_of(Q.MQ2, "let s = OSSignposter(subsystem: a)\nOSSignposter.shared\n"),
           ["let s = OSSignposter(subsystem: a)"])
    expect("MQ3", lines_of(Q.MQ3, 'Logger(subsystem: "com.cmuxterm.app.next", category: "a")\n'
                                  'Logger(subsystem: "com.cmuxterm.next", category: "b")\n'
                                  'Logger(subsystem: "com.cmuxterm.app.nextgen")\n', pcre2=True),
           ['Logger(subsystem: "com.cmuxterm.next", category: "b")', 'Logger(subsystem: "com.cmuxterm.app.nextgen")'])
    expect("MQ4 debug", lines_of(Q.MQ4_DEBUG, "#if DEBUG\n#if DEBUG || CMUX_BENCH_HOOKS\n#if DEBUG && X\n"),
           ["#if DEBUG", "#if DEBUG || CMUX_BENCH_HOOKS"])
    names = ["A/NewTerminalTrace.swift", "A/DebugTimings.swift", "A/FooTimer+Bar.swift", "A/CEFEventTrace.swift",
             "A/BurstTrace+Control.swift", "A/Tracer.swift", "A/TerminalTimings.swift"]
    expect("MQ4 names", [n for n in names if re.search(Q.MQ4_NAME, n) and not re.search(Q.MQ4_EXCLUDE, n)],
           ["A/NewTerminalTrace.swift", "A/FooTimer+Bar.swift", "A/TerminalTimings.swift"])
    file_lines = [
        "#if DEBUG",
        "Signposter.event(.createTab, arg0: 1)",
        "#else",
        "let x = 1",
        "#endif",
        "#if !DEBUG",
        "y()",
        "#endif",
    ]
    expect("debug regions", debug_only_lines(file_lines), [True, True, False, False, False, False, False, False])
    expect("MQ5 marker", re.search(Q.MQ5_MARKER, "    // perf-hot: 2ms frame-tick").group(1), "frame-tick")
    expect("MQ5 trace", len(lines_of(Q.MQ5_TRACE, "Signposter.event(.x)\nKeyFrameSignpost.begin()\nTrace.scope(a)\nfoo()\n")), 3)
    expect("MQ6", len(lines_of(Q.MQ6, "let t = CFAbsoluteTimeGetCurrent()\nDate().timeIntervalSince(a)\nDate()\n")), 2)
    expect("MQ6 escape", near(["let t = CFAbsoluteTimeGetCurrent() // wall-clock: shown to the person"], 1, WALL_CLOCK_ESCAPE), True)
    expect("MQ6 escape above", near(["// wall-clock: a date", "let t = Date().timeIntervalSince(a)"], 2, WALL_CLOCK_ESCAPE), True)
    expect("MQ7", len(lines_of(Q.MQ7, 'DispatchQueue(label: "a")\nThread.detachNewThread {}\nlet t = Thread(block: b)\nThread.current\n')), 3)
    expect("MQ7 label", LANE_LABEL.search('DispatchQueue(label: "com.cmuxterm.next.control.\\(id)")').group(1).split("\\(")[0],
           "com.cmuxterm.next.control.")
    expect("MQ7 keep", [bool(LANE_KEEP.search(t)) and not LANE_DROP.search(t)
                        for t in ("Nothing", "Blocking `read(2)` (reader)", "Disk", "PTY read/write", "GCD QoS")],
           [True, True, False, True, False])
    model = [
        "| Thread / queue | Owns | May block on | QoS |",
        "|---|---|---|---|",
        "| **Frame clock** | Ticks | Never | main |",
        "| **Per-stream lanes** | Not yet | | |",
        "",
        "| WorkPriority | from MainWorkClass | GCD QoS | Swift TaskPriority |",
        "| userBlocking | input, frame | userInitiated | high |",
    ]
    expect("MQ7 thread table", [cells for _, cells in thread_table_rows(model)], ["Never"])
    multi = 'std::thread::Builder::new()\n    .name("mux-conn".into())\n'
    expect("MQ8 thread", lines_of(Q.MQ8_THREADS, "x()\n" + multi, multiline=True), ["std::thread::Builder::new()"])
    expect("MQ8 format", len(lines_of(Q.MQ8_THREADS, 'thread::Builder::new().name(format!("surface-{id}"))\n')), 1)
    expect("MQ8 other", lines_of(Q.MQ8_THREADS, 'thread::Builder::new().name("other".into())\n'), [])
    expect("MQ8 runtime", len(lines_of(Q.MQ8_RUNTIMES, "tokio::runtime::Builder::new_multi_thread()\n")), 1)
    expect("MQ9 panic", len(lines_of(Q.MQ9_PANIC, "cmux_panic_log::install(p)\ncmux_panic_log::install_with_opener(a)\n")), 2)
    expect("MQ9 blackbox", len(lines_of(Q.MQ9_BLACKBOX, "cmux_trace::init_blackbox(dir)\nmy_init_blackbox(x)\n")), 1)
    expect("Mach-O", [is_macho(b) for b in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"#!/b")], [True, True, False])
    cargo = (
        '[package]\nname = "cmux-tui"\n\n[[bin]]\nname = "cmux-tui"\npath = "src/bin/cmux-tui.rs"\n\n'
        '[[bin]]\nname = "cmux-tui-host"\npath = "src/bin/cmux-tui-host.rs"\n[dependencies]\nname = "x"\n'
    )
    expect("cargo bins", parse_cargo_bins(cargo, "c", lambda rel: False),
           [("cmux-tui", "c/src/bin/cmux-tui.rs"), ("cmux-tui-host", "c/src/bin/cmux-tui-host.rs")])
    expect("cargo implicit", parse_cargo_bins('[package]\nname = "optchat-chief"\n', "n", lambda rel: True),
           [("optchat-chief", "n/src/main.rs")])
    sentry = [RgMatch("a", 1, "        options.enableLogs = false"), RgMatch("a", 2, "options.appHangTimeoutInterval = 8.0 // s")]
    expect("MQ10 parse", sentry_options(sentry), {"enableLogs": ("false", 1), "appHangTimeoutInterval": ("8.0", 2)})
    expect("MQ10", len(lines_of(Q.MQ10, "options.enableMetricKit = false\noptions.appHangTimeoutInterval = 8\noptions.dsn = x\n")), 2)
    enum = "    Identify {\n        machine: bool,\n    },\n    Ping,\n    Resize(Size),\n    // Note\n"
    expect("MQ11", len(lines_of(Q.MQ11_VARIANT, enum)), 3)
    table = (
        '// `Variant => "wire-name" | "alias", Class;`\n'
        'command_table! {\n    Identify => "identify", Query;\n    Ping => "ping" | "p", Query;\n}\n'
        '            Command::Resize { .. } => "resize",\n'
    )
    expect("MQ11 named", command_names_rows(table), {"Identify", "Ping", "Resize"})
    expect("MQ12 decl", [m.group(1) for t in ("    case keyFrame(KeyTarget)", "        case let .keyFrame(t): x", "    case mainTurn")
                         for m in [re.match(r"^\s*case (\w+)\b", t)] if m and m.group(1) != "let"],
           ["keyFrame", "mainTurn"])
    expect("MQ12 record", [m.group(1) for m in re.finditer(Q.MQ12_RECORD, "metrics.record(.keyFrame(.view), 3); m.record(.mainTurn, d)")],
           ["keyFrame", "mainTurn"])
    expect("MQ13", len(lines_of(Q.MQ13, "std::thread::spawn(move || {})\nthread::spawn(f)\nthread::Builder::new().spawn(f)\n")), 2)
    expect("MQ14", len(lines_of(Q.MQ14, "Task.detached(priority: .utility) {}\nTask {}\n")), 1)
    expect("MQ15", len(lines_of(Q.MQ15, "let c = ContinuousClock()\nlet s = SuspendingClock()\n")), 1)
    expect("MQ15 done", [bool(CONTINUOUS_CLOCK_DONE.search(t)) for t in
                         ("ContinuousClock.now // continuous-clock: counts sleep on purpose", "ContinuousClock.now", "TraceClock.nowNanos()")],
           [True, False, True])
    expect("MQ16", len(lines_of(Q.MQ16, 'assertionFailure("x")\nassert(x)\n')), 1)
    expect("MQ16 done", near(['assertionFailure("x")', "Diagnostics.dumpWithoutCrashing(site: \"x\")"], 1,
                             DUMP_WITHOUT_CRASHING, before=3, after=3), True)
    hits = [Hit(f"{SOURCES}/{pkg}/F{i}.swift", 1, "x") for pkg, n in (("A", 10), ("B", 10), ("C", 3)) for i in range(n)]
    batches = by_package_files(hits, 15)
    expect("package batches", [len({h.file for h in b}) for b in batches], [10, 13])
    expect("big package split", [len(b) for b in by_package_files([Hit(f"{SOURCES}/A/F{i}.swift", 1, "x") for i in range(20)], 15)],
           [15, 5])

    for failure in failures:
        print(f"FAIL {failure}", file=sys.stderr)
    print(f"self-test: {checks - len(failures)}/{checks} checks passed")
    return 1 if failures else 0


# ---------------------------------------------------------------------------------------------------------------


COMMANDS = ("catalog", "clocks", "lanes", "rust", "sentry", "histograms", "threads", "tasks", "asserts", "all")


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="Run the p09-observability machine queues MQ1-MQ16 and print their done-check counts.",
    )
    parser.add_argument("command", nargs="?", choices=COMMANDS)
    parser.add_argument("--json", action="store_true", help="print JSON")
    parser.add_argument("--tasks", action="store_true", help="print one task line per hit or batch")
    parser.add_argument("--bundle", type=Path, help="rust: a built .app to read the shipped Mach-O binaries from")
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[2],
                        help="the checkout to audit (default: this script's checkout)")
    parser.add_argument("--self-test", action="store_true", help="check every query against fixture strings")
    args = parser.parse_args(argv)

    try:
        if args.self_test:
            return self_test()
        if not args.command:
            parser.error("a command is required (or --self-test)")
        if args.bundle and args.command not in ("rust", "all"):
            parser.error("--bundle applies to rust and all")
        repo = args.repo.resolve()
        queues, counts = Audit(repo).run(args.command, args.bundle)
    except AuditError as error:
        print(f"observability-audit: {error}", file=sys.stderr)
        return 2

    tasks = [line for q in queues for line in task_lines(q)]
    if args.json:
        payload: Dict[str, object] = {
            "command": args.command,
            "repo": str(repo),
            "counts": counts,
            "queues": [q.to_json() for q in queues],
        }
        if args.tasks:
            payload["tasks"] = tasks
        print(json.dumps(payload, indent=2))
    elif args.tasks:
        print("\n".join(tasks))
    else:
        print(summary(queues, counts))
    return 0


if __name__ == "__main__":
    sys.exit(main())
