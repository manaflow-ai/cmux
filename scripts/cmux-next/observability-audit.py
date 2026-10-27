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
- MQ6 and MQ15 read a done mark on the hit line, or (only the escape comment) in the comment lines right above
  it; a code line above with a trailing comment marks only itself.
- MQ7 reads a variable label (`DispatchQueue(label: label`) from the owning type's call sites, expands a table
  row's short forms (`.write` after `com.cmuxterm.next.localpty.read`), and counts a lane no row names: it gets
  a "classify" task line, so the count cannot reach 0 while a lane is unresolved.
- MQ7 and MQ8 count a registration for one site only: the site whose scope holds it (a Rust spawn closure or
  runtime builder), else the nearest site in its file. One registered lane never marks a second one done.
- MQ8 matches a builder chain across lines (`rg -U`) and reads the thread name from the whole match.
- MQ9 with --bundle evaluates each role once: `cmux` and its alias `cmux-tui` reach the same roles.
- MQ10 compares the options of both files in both directions; an app-only option set to `false` is not a diff.
- MQ11 finds `enum Command {` instead of a fixed line number, and after task 013 counts only the variants
  that `server/command_names.rs` does not name.
- MQ12 reads only `case` declarations (not `case let` arms of the name switch).
- MQ14 matches `Task.detached` at a word boundary, so the TracedTask.detached replacement is not a hit. It lists
  CmuxNextCompat's sites as excluded: Wakeups depends on Compat, so they cannot call TracedTask (task 124).
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
from typing import Callable, Dict, Iterable, List, Optional, Sequence, Set, Tuple

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
    # MotionFrameTrace: the `debug.motion trace_*` geometry sampler (a DEBUG socket method), not a timing trace; the
    # motion timing it watches ships in every build as motion.frame and motion.run (LayoutMotionTrace, task 026).
    MQ4_EXCLUDE = r"Debug[A-Z]|CEFEventTrace|BurstTrace\+Control|MotionFrameTrace"
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
    MQ13 = r"\bthread::spawn\("  # `\b`: echo_thread::spawn and cmux_threads::spawn name their thread
    MQ14 = r"\bTask\.detached"  # `\b`: TracedTask.detached, the replacement (task 124), is not a hit
    MQ15 = r"ContinuousClock"
    MQ16 = r"assertionFailure\("


# Done rules applied to the hits (not rg queries: they read the matched file around the hit).
WALL_CLOCK_ESCAPE = re.compile(r"//\s*wall-clock:\s*\S")
CONTINUOUS_CLOCK_REPLACED = re.compile(r"\bTraceClock\b|\bSuspendingClock\b")
CONTINUOUS_CLOCK_ESCAPE = re.compile(r"//\s*continuous-clock:\s*\S")
# One registration per line: a HangWatch register call, or a stored registration a lane gets injected.
SWIFT_REGISTRATION = re.compile(
    r"\bregister(Lane|Thread)\(|\b(let|var)\s+\w+\s*:\s*HangWatch\.Registration\b"
)
SWIFT_REGISTRATION_EXCLUDE = re.compile(r"\bfunc\s+register(Lane|Thread)\b")
RUST_REGISTRATION = re.compile(r"\bregister_thread\s*\(")
RUST_REGISTRATION_EXCLUDE = re.compile(r"^\s*(pub(\(\w+\))?\s+)?(use\s|fn\s)|\bfn\s+register_thread\b")
RUST_SCOPE_REGISTRATION = re.compile(r"\bregister_thread\s*\(|hang_watch::")
DUMP_WITHOUT_CRASHING = re.compile(r"dumpWithoutCrashing")
COMMENT_LINE = re.compile(r"^\s*(//|/\*|\*)")
LANE_LABEL = re.compile(r'DispatchQueue\(label:\s*"([^"\\]*)')
LANE_LABEL_VARIABLE = re.compile(r"DispatchQueue\(label:\s*(\$\d+|[A-Za-z_]\w*)\s*[,)]")
TYPE_DECL = re.compile(r"^\s*(?:@\w+\s+)*(?:(?:public|package|internal|private|fileprivate|final|nonisolated)\s+)*"
                       r"(?:class|struct|actor|enum)\s+(\w+)")
BACKTICKED = re.compile(r"`([^`]+)`")
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
    # A title per batch when the batches need different work (MQ7: register, or classify first).
    batch_titles: List[str] = field(default_factory=list)

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
    block: str = ""  # the match's lines from `line` on (a multiline match spans several)


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
        return [m.text for m in self.stdin_rg(pattern, text, pcre2=pcre2, multiline=multiline)]

    def stdin_rg(self, pattern: str, text: str, pcre2: bool = False, multiline: bool = False) -> List[RgMatch]:
        args = ["--json"]
        if pcre2:
            args.append("--pcre2")
        if multiline:
            args.append("-U")
        return parse_rg_json(self._run([*args, "-e", pattern, "-"], stdin=text))


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
            split = text.split("\n") if text else [""]
            matches.append(RgMatch(path, line, split[offset], "\n".join(split[offset:])))
    return matches


def text_offset_lines(block: bytes, byte_offset: int) -> int:
    """How many newlines come before `byte_offset` in a match block (rg reports byte offsets)."""
    return block[:byte_offset].count(b"\n")


def is_comment(text: str) -> bool:
    return bool(COMMENT_LINE.match(text))


RUST_TEST_ATTRIBUTE = re.compile(r"^\s*#\[(cfg\(test\)|cfg\(all\(test\b|test\]|tokio::test\b)")
RUST_TEST_MODULE = re.compile(r"^\s*(?:pub(?:\([^)]*\))?\s+)?mod\s+(\w+)\s*;")


def rust_test_lines(lines: List[str]) -> Tuple[Set[int], List[str]]:
    """The 1-based lines of a Rust file inside `#[cfg(test)]` and `#[test]` items, and the modules it declares
    test-only (`#[cfg(test)] mod name;`). The cmux-trace `thread_names` test applies the same rule."""
    inside: Set[int] = set()
    modules: List[str] = []
    i = 0
    while i < len(lines):
        if not RUST_TEST_ATTRIBUTE.match(lines[i]):
            i += 1
            continue
        depth, opened, j = 0, False, i
        while j < len(lines):
            code = re.sub(r'"(?:\\.|[^"\\])*"|\'\\?.\'|//.*', "", lines[j])
            if not opened and j > i and code.rstrip().endswith(";"):
                named = RUST_TEST_MODULE.match(code)
                if named:
                    modules.append(named.group(1))
                break
            depth += code.count("{") - code.count("}")
            opened = opened or "{" in code
            if opened and depth <= 0:
                break
            j += 1
        inside.update(range(i + 1, j + 2))
        i = j + 1
    return inside, modules


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


def marked(lines: List[str], line: int, on_line: re.Pattern, in_comment_above: Optional[re.Pattern] = None) -> bool:
    """Whether the hit on line `line` (1-based) is done: `on_line` matches the hit line itself, or
    `in_comment_above` matches the hit line or the run of comment-only lines right above it. A code line above
    (another hit with a trailing comment) never marks this one."""
    if not 0 < line <= len(lines):
        return False
    if on_line.search(lines[line - 1]):
        return True
    if in_comment_above is None:
        return False
    if in_comment_above.search(lines[line - 1]):
        return True
    i = line - 2
    while i >= 0 and is_comment(lines[i]):
        if in_comment_above.search(lines[i]):
            return True
        i -= 1
    return False


def assign_registrations(
    sites: List[Tuple[int, Optional[Tuple[int, int]]]], registrations: List[int]
) -> set:
    """The site lines one registration each covers, in one file.

    `sites` are (line, scope): the scope is the line range (inclusive) the site's own code runs in (a Rust
    builder chain and its spawn closure), or None when the site has no scope this script can see (a Swift
    queue). A registration inside a site's scope covers that site only. Each registration left (outside every
    scope: a lane registered in its init, a thread registered in the function its closure calls) covers the
    nearest uncovered site, one site per registration, so one registration never marks a second lane done."""
    covered = set()
    free = []
    for reg in registrations:
        owners = [(scope[1] - scope[0], line) for line, scope in sites if scope and scope[0] <= reg <= scope[1]]
        owner = min(owners)[1] if owners else None  # the innermost scope (a thread spawned inside another)
        if owner is None:
            free.append(reg)
        else:
            covered.add(owner)
    for reg in free:
        open_sites = [line for line, _ in sites if line not in covered]
        if not open_sites:
            break
        covered.add(min(open_sites, key=lambda line: (abs(line - reg), line)))
    return covered


def balanced_end(
    lines: List[str], start: int, opener: re.Pattern, limit: int = 400, opener_within: int = 20
) -> Optional[int]:
    """The 1-based line where the parenthesis that `opener` opens (first match within `opener_within` lines of line
    `start`) closes. Skips string literals and `//` comments; None when it does not close within `limit` lines."""
    i = start - 1
    while i < len(lines) and i < start - 1 + opener_within:
        m = opener.search(lines[i])
        if m:
            break
        i += 1
    else:
        return None
    depth = 0
    col = m.end() - 1  # the opening parenthesis
    while i < len(lines) and i < start - 1 + limit:
        text = lines[i]
        in_string = False
        while col < len(text):
            ch = text[col]
            if in_string:
                if ch == "\\":
                    col += 1
                elif ch == '"':
                    in_string = False
            elif ch == '"':
                in_string = True
            elif text.startswith("//", col):
                break
            elif ch == "'" and col + 2 < len(text) and text[col + 2] == "'":
                col += 2  # a char literal such as '('
            elif ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
                if depth == 0:
                    return i + 1
            col += 1
        i += 1
        col = 0
    return None


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


def unknown_trace_names(trace: object, catalog: set) -> List[str]:
    """The names in a perf-hot id's `trace` that are no SignpostName rawValue (a misspelling or a removed name)."""
    names = trace if isinstance(trace, list) else []
    return [str(name) for name in names if name not in catalog]


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
        title = queue.batch_titles[i - 1] if queue.batch_titles else queue.title
        if len(batch) == 1:
            hit = batch[0]
            where = f"{hit.file}:{hit.line}" if hit.line else hit.file
            out.append(f"{queue.queue} {i}/{total}: {title}: {hit.symbol} ({where})")
        else:
            out.append(
                f"{queue.queue} {i}/{total}: {title}: {len(batch)} hits in {len(files)} files: "
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
        catalog = {wire for _, wire, _ in self.catalog_names()}
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
            for name in unknown_trace_names(entry.get("trace"), catalog):
                hits.append(Hit(PERF_HOT_BENCHES, 0, pid, {"reasons": ["unknown trace name"], "name": name}))
        q = Queue("MQ5", "perf-hot id with a trace point and a trace field", hits, "per hit", "perf_hot_ids_without_trace")
        q.batches = per_hit(hits)
        q.notes = {"ids": len(ids)}
        return q

    # MQ6 ---------------------------------------------------------------------------------------------------
    def mq6(self) -> Queue:
        hits = [
            Hit(m.file, m.line, m.text.strip()[:120])
            for m in self.rg.lines(Q.MQ6, [SOURCES])
            if not marked(self.files.lines(m.file), m.line, WALL_CLOCK_ESCAPE, WALL_CLOCK_ESCAPE)
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
            if not marked(self.files.lines(m.file), m.line, CONTINUOUS_CLOCK_REPLACED, CONTINUOUS_CLOCK_ESCAPE)
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

    def lane_labels(self, m: RgMatch) -> Tuple[List[str], str]:
        """The labels a lane site's queue can have, and the type that owns it.

        A literal label is read from the site. A variable label (`DispatchQueue(label: label`, `$0`) is read
        from the owning type's call sites (`TerminalOutputLane(surface: s, label: "com...")`); an
        interpolated call-site label keeps its literal prefix, and one with no literal prefix is not a label."""
        owner = enclosing_type(self.files.lines(m.file), m.line)
        literal = LANE_LABEL.search(m.text)
        if literal:
            label = literal.group(1).split("\\(")[0]
            return ([label] if label else []), owner
        if not owner or not LANE_LABEL_VARIABLE.search(m.text):
            return [], owner
        labels: List[str] = []
        call = re.compile(r"\b" + re.escape(owner) + r'\([^)]*\blabel:\s*"([^"\\]*)')
        for site in self.rg.lines(r"\b" + re.escape(owner) + r"\(", [SOURCES]):
            if is_comment(site.text):
                continue
            cm = call.search(site.text)
            label = cm.group(1).split("\\(")[0] if cm else ""
            if label and label not in labels:
                labels.append(label)
        return labels, owner

    def mq7(self) -> Queue:
        rows = self.threading_rows()
        unregistered: List[Hit] = []
        unclassified: List[Hit] = []
        dropped: List[Hit] = []
        registered = 0
        sites: Dict[str, List[RgMatch]] = {}
        for m in self.rg.lines(Q.MQ7, [SOURCES]):
            if not is_comment(m.text):
                sites.setdefault(m.file, []).append(m)
        for f in sorted(sites):
            lines = self.files.lines(f)
            regs = [
                i
                for i, text in enumerate(lines, 1)
                if not is_comment(text) and SWIFT_REGISTRATION.search(text) and not SWIFT_REGISTRATION_EXCLUDE.search(text)
            ]
            covered = assign_registrations([(m.line, None) for m in sites[f]], regs)
            for m in sites[f]:
                labels, owner = self.lane_labels(m)
                hit = Hit(m.file, m.line, labels[0] if len(labels) == 1 else (", ".join(labels) or m.text.strip()[:80]))
                if m.line in covered:
                    registered += 1
                    continue
                row = lane_row(rows, labels, [Path(m.file).stem.split("+")[0], owner])
                if row is None:
                    hit.extra["kind"] = "unclassified"
                    hit.extra["reason"] = "no threading-model row names this lane's label or type"
                    unclassified.append(hit)
                    continue
                hit.extra["may_block_on"] = row[1][:80]
                if LANE_DROP.search(row[1]) or not LANE_KEEP.search(row[1]):
                    dropped.append(hit)
                    continue
                hit.extra["kind"] = "unregistered"
                unregistered.append(hit)
        # An unclassified lane counts: the queue is not done until threading-model.md says whether it is kept.
        hits = unregistered + unclassified
        q = Queue("MQ7", "Register the Swift lane with HangWatch", hits, "per file", "swift_lanes_unregistered")
        register = by_files(unregistered, 1)
        classify = by_files(unclassified, 1)
        q.batches = register + classify
        q.batch_titles = [q.title] * len(register) + [
            "Classify the Swift lane in threading-model.md (a row naming its label or type), then register it if kept"
        ] * len(classify)
        q.notes = {
            "registered": registered,
            "unregistered_kept": len(unregistered),
            "dropped_by_threading_model": [h.to_json() for h in dropped],
            "unclassified": [h.to_json() for h in unclassified],
        }
        return q

    # MQ8 ---------------------------------------------------------------------------------------------------
    def mq8(self) -> Queue:
        thread_paths = [f"{CRATES}/{c}/src" for c in ("cmux-tui-core", "cmux-tui", "cmux-holder")]
        runtime_paths = [f"{CRATES}/{c}/src" for c in ("cmux-tui", "acpmux")]
        sites: Dict[str, List[Tuple[str, RgMatch]]] = {}
        for kind, matches in (
            ("thread", self.rg.lines(Q.MQ8_THREADS, thread_paths, multiline=True)),
            ("runtime", self.rg.lines(Q.MQ8_RUNTIMES, runtime_paths)),
        ):
            for m in matches:
                if not is_comment(m.text):
                    sites.setdefault(m.file, []).append((kind, m))
        hits: List[Hit] = []
        registered = 0
        for f in sorted(sites):
            lines = self.files.lines(f)
            scoped: List[Tuple[int, Optional[Tuple[int, int]]]] = []
            for kind, m in sites[f]:
                scoped.append((m.line, rust_site_scope(lines, m.line, kind)))
            regs = rust_registrations(lines, [scope for _, scope in scoped if scope])
            covered = assign_registrations(scoped, regs)
            for kind, m in sites[f]:
                if m.line in covered:
                    registered += 1
                    continue
                hits.append(Hit(m.file, m.line, rust_site_symbol(m, kind), {"kind": kind}))
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
        return map_bundle_binaries(bundle_macho_names(bundle), self.cargo_bins())

    # MQ10 --------------------------------------------------------------------------------------------------
    def mq10(self) -> Queue:
        app = sentry_options(self.rg.lines(Q.MQ10 + r"\s*=\s*[^\n]+", [CRASH_REPORTER]))
        cli = sentry_options(self.rg.lines(Q.MQ10 + r"\s*=\s*[^\n]+", [CLI_SENTRY_POLICY]))
        hits = sentry_diffs(app, cli)
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
        roots = [f"{CRATES}/{c}/src" for c in crates]
        globs = ["!**/tests/**", "!**/*tests*.rs"]
        # Test code ships nothing: `#[cfg(test)]` items and test-only modules are not hits.
        test_files: List[str] = []
        test_dirs: List[str] = []
        for rel in self.rg.files(r"#\[cfg\((all\()?test\b", roots, globs):
            path = Path(rel)
            folder = path.parent if path.stem in ("mod", "lib", "main") else path.parent / path.stem
            for module in rust_test_lines(self.files.lines(rel))[1]:
                test_files.append(str(folder / f"{module}.rs"))
                test_dirs.append(f"{folder / module}/")
        hits = [
            Hit(m.file, m.line, m.text.strip()[:120])
            for m in self.rg.lines(Q.MQ13, roots, globs=globs)
            if not is_comment(m.text)
            and m.file not in test_files
            and not m.file.startswith(tuple(test_dirs))
            and m.line not in rust_test_lines(self.files.lines(m.file))[0]
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
    """The Mach-O file names in Contents/Resources/{bin,libexec} and Contents/Frameworks/*.app/Contents/MacOS, each
    name once. An alias symlink keeps its own name: the binary picks its role from argv[0] (`bin/acpmux -> cmux`
    runs acpmux), so map_bundle_binaries removes the duplicates by role, not by file."""
    dirs = [bundle / "Contents/Resources/bin", bundle / "Contents/Resources/libexec"]
    frameworks = bundle / "Contents/Frameworks"
    if frameworks.is_dir():
        dirs += sorted(p / "Contents/MacOS" for p in frameworks.glob("*.app"))
    entries: List[str] = []
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
            if is_macho(head):
                entries.append(path.name)
    return list(dict.fromkeys(entries))


def map_bundle_binaries(
    binaries: Sequence[str], cargo: Dict[str, Tuple[str, str]]
) -> Tuple[List[Tuple[ShippedRole, str, Optional[str]]], List[str]]:
    """Each shipped role once (`cmux` and its alias `cmux-tui` both reach the daemon and mcp-serve roles; they count
    once), and the binaries no role or Cargo [[bin]] names."""
    evaluated: List[Tuple[ShippedRole, str, Optional[str]]] = []
    unmapped: List[str] = []
    seen_roles = set()
    for binary in binaries:
        bin_name = BUNDLE_ALIASES.get(binary, binary)
        roles = [role for role in SHIPPED_ROLES if role.bin == bin_name]
        if roles:
            for role in roles:
                if role.name not in seen_roles:
                    seen_roles.add(role.name)
                    evaluated.append((role, binary, None))
        elif bin_name in cargo:
            if bin_name not in seen_roles:
                seen_roles.add(bin_name)
                crate_dir, _entry = cargo[bin_name]
                evaluated.append((ShippedRole(bin_name, bin_name, (), panic=True, blackbox=False), binary, crate_dir))
        else:
            unmapped.append(binary)
    return evaluated, unmapped


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


SWIFT_STRING_OR_COMMENT = re.compile(r'"(?:[^"\\]|\\.)*"|//.*$')


def enclosing_type(lines: List[str], line: int) -> str:
    """The innermost type whose body holds line `line` (1-based): the type whose init or method a lane site is in.
    A nested type that closed above the line (`private struct State { ... }`) is not it."""
    stack: List[List[object]] = []  # [name, depth before its declaration, body opened]
    depth = 0
    for text in lines[: max(0, line - 1)]:
        m = TYPE_DECL.match(text)
        if m:
            stack.append([m.group(1), depth, False])
        code = SWIFT_STRING_OR_COMMENT.sub("", text)
        for ch in code:
            if ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
            for entry in stack:
                if not entry[2] and depth > entry[1]:
                    entry[2] = True
            while stack and stack[-1][2] and depth <= stack[-1][1]:
                stack.pop()
    return str(stack[-1][0]) if stack else ""


def row_labels(row: str) -> List[str]:
    """The backticked names of a threading-model row, with short forms expanded: in
    `` `com.cmuxterm.next.localpty.read` / `.write` `` the second is `com.cmuxterm.next.localpty.write`, and in
    `` `acpmux-socket-read` / `-write` `` the second is `acpmux-socket-write`."""
    out: List[str] = []
    full = ""
    for token in BACKTICKED.findall(row):
        if full and re.fullmatch(r"[.-][\w.<>-]+", token) and token[0] in full:
            out.append(full.rsplit(token[0], 1)[0] + token)
        else:
            out.append(token)
            full = token
    return out


def label_names_row_label(label: str, name: str) -> bool:
    """Whether a lane label is a row's backticked name: equal, or the literal prefix of an interpolated label
    (`com.cmuxterm.next.control.` for `com.cmuxterm.next.control.<id>`)."""
    if label == name:
        return True
    if "<" in name and label == name.split("<", 1)[0]:
        return True
    return label[-1:] in (".", "-") and name.startswith(label)


def lane_row(rows: List[Tuple[str, str]], labels: Sequence[str], names: Sequence[str]) -> Optional[Tuple[str, str]]:
    """The thread-table row a lane belongs to: a backticked name equal to one of its labels, else a row whose text
    holds the label, else a row naming the lane's file stem or owning type as a word."""
    for label in labels:
        for row in rows:
            if any(label_names_row_label(label, name) for name in row_labels(row[0])):
                return row
    for label in labels:
        for row in rows:
            if label in row[0]:
                return row
    for name in names:
        if not name:
            continue
        word = re.compile(r"\b" + re.escape(name) + r"\b")
        for row in rows:
            if word.search(row[0]):
                return row
    return None


RUST_SPAWN = re.compile(r"\.spawn(_scoped)?\s*\(")
RUST_BUILD = re.compile(r"\.build\(\)")
RUST_THREAD_NAME = re.compile(r'\.name\(\s*(?:format!\()?"([^"{]*)')


def rust_site_scope(lines: List[str], line: int, kind: str) -> Optional[Tuple[int, int]]:
    """The lines a Rust site's own code runs in: a thread's builder chain through the end of its spawn closure, a
    runtime's builder chain through `.build()` (where its thread hooks go)."""
    if kind == "thread":
        end = balanced_end(lines, line, RUST_SPAWN)
    else:
        end = next((i for i in range(line, min(len(lines), line + 40) + 1) if RUST_BUILD.search(lines[i - 1])), None)
    return (line, end) if end else None


def rust_registrations(lines: List[str], scopes: Sequence[Tuple[int, int]]) -> List[int]:
    """Registration lines in one Rust file: any `hang_watch::` use or `register_thread(` call inside a site's scope
    (a runtime's hooks call into cmux-hang-watch), and outside every scope only a `register_thread(` call (a
    thread registered in the function its closure runs)."""
    regs: List[int] = []
    for i, text in enumerate(lines, 1):
        if is_comment(text) or RUST_REGISTRATION_EXCLUDE.search(text):
            continue
        inside = any(lo <= i <= hi for lo, hi in scopes)
        if (RUST_SCOPE_REGISTRATION if inside else RUST_REGISTRATION).search(text):
            regs.append(i)
    return regs


def rust_site_symbol(m: RgMatch, kind: str) -> str:
    """The thread name a builder chain gives (read from the whole multiline match), or the runtime builder."""
    if kind == "runtime":
        return "new_multi_thread"
    nm = RUST_THREAD_NAME.search(m.block or m.text)
    return nm.group(1) if nm else "thread"


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


def sentry_diffs(app: Dict[str, Tuple[str, int]], cli: Dict[str, Tuple[str, int]]) -> List[Hit]:
    """Every option either file sets (both directions) whose app value differs from the CLI's. An app-only option
    counts unless the app sets it `false` (quieter than Sentry's default, as the CLI's policy wants), so an app
    `options.enableSwizzling = true` the CLI never names is a hit."""
    hits: List[Hit] = []
    for option in sorted(set(app) | set(cli)):
        if option == "appHangTimeoutInterval" and option not in cli:
            continue  # meaningful only with hang tracking on: the rule below
        app_value, app_line = app.get(option, ("unset", 0))
        cli_value = cli.get(option, ("unset", 0))[0]
        if option not in cli and app_value == "false":
            continue
        if app_value != cli_value:
            hits.append(Hit(CRASH_REPORTER, app_line, option, {"app": app_value, "cli": cli_value}))
    hang = app.get("appHangTimeoutInterval")
    if hang and app.get("enableAppHangTracking", ("unset", 0))[0] != "false" and not any(
        h.symbol == "enableAppHangTracking" for h in hits
    ):
        hits.append(Hit(CRASH_REPORTER, hang[1], "appHangTimeoutInterval", {"app": hang[0], "cli": "tracking off"}))
    return hits


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
             "A/BurstTrace+Control.swift", "A/Tracer.swift", "A/TerminalTimings.swift", "A/MotionFrameTrace.swift"]
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
    expect("MQ5 unknown trace name", unknown_trace_names(["key.flow", "key.flwo"], {"key.flow"}), ["key.flwo"])
    expect("MQ5 no trace field", unknown_trace_names(None, {"key.flow"}), [])
    expect("MQ6", len(lines_of(Q.MQ6, "let t = CFAbsoluteTimeGetCurrent()\nDate().timeIntervalSince(a)\nDate()\n")), 2)
    expect("MQ6 escape", marked(["let t = CFAbsoluteTimeGetCurrent() // wall-clock: shown to the person"], 1,
                                WALL_CLOCK_ESCAPE, WALL_CLOCK_ESCAPE), True)
    expect("MQ6 escape above", marked(["// wall-clock: a date", "let t = Date().timeIntervalSince(a)"], 2,
                                      WALL_CLOCK_ESCAPE, WALL_CLOCK_ESCAPE), True)
    expect("MQ6 escape above a comment block", marked(["// wall-clock: a date", "// shown in the row",
                                                       "let t = Date().timeIntervalSince(a)"], 3,
                                                      WALL_CLOCK_ESCAPE, WALL_CLOCK_ESCAPE), True)
    adjacent = ["let shown = Date() // wall-clock: shown to the person", "let elapsed = CFAbsoluteTimeGetCurrent() - t"]
    expect("MQ6 adjacent hits", [marked(adjacent, i, WALL_CLOCK_ESCAPE, WALL_CLOCK_ESCAPE) for i in (1, 2)], [True, False])
    expect("MQ7", len(lines_of(Q.MQ7, 'DispatchQueue(label: "a")\nThread.detachNewThread {}\nlet t = Thread(block: b)\nThread.current\n')), 3)
    expect("MQ7 label", LANE_LABEL.search('DispatchQueue(label: "com.cmuxterm.next.control.\\(id)")').group(1).split("\\(")[0],
           "com.cmuxterm.next.control.")
    expect("MQ7 keep", [bool(LANE_KEEP.search(t)) and not LANE_DROP.search(t)
                        for t in ("Nothing", "Blocking `read(2)` (reader)", "Disk", "PTY read/write", "GCD QoS")],
           [True, True, False, True, False])
    expect("MQ7 variable label", [LANE_LABEL_VARIABLE.search(t).group(1) for t in (
        "self.queue = DispatchQueue(label: label, qos: .userInteractive)",
        "slots = names.map { DispatchQueue(label: $0, qos: .unspecified) }",
        "self.queue = DispatchQueue(label: label)")], ["label", "$0", "label"])
    expect("MQ7 owner", enclosing_type(["import Foundation", "final class TerminalOutputLane: Sendable {",
                                        "    private struct Backlog {", '        var s = "}"', "    }",
                                        "    init(label: String) {", "        q = DispatchQueue(label: label)"], 7),
           "TerminalOutputLane")
    expect("MQ7 nested owner", enclosing_type(["final class A {", "    struct B", "    {", "        let q = 1"], 4), "B")
    lane_rows = [
        ("| **Daemon connection** reader; writer queue `com.cmuxterm.next.daemon.write` | x | Blocking `read(2)` |", "Blocking `read(2)`"),
        ("| **Terminal output lane** `com.cmuxterm.next.terminal.output`; local PTY `com.cmuxterm.next.localpty.read` / `.write` | x | PTY read/write |", "PTY read/write"),
        ("| **DispatchSource handlers** (`com.cmuxterm.next.control.accept`, `com.cmuxterm.next.control.<id>`; `FrameScheduler`) | x | Non-blocking reads |", "Non-blocking reads"),
        ("| **acpmux** (`acpmux-socket-read` / `-write`) | x | Socket I/O |", "Socket I/O"),
    ]
    expect("MQ7 short forms", row_labels(lane_rows[1][0])[1:] + row_labels(lane_rows[3][0]),
           ["com.cmuxterm.next.localpty.read", "com.cmuxterm.next.localpty.write", "acpmux-socket-read", "acpmux-socket-write"])
    expect("MQ7 rows", [(lane_row(lane_rows, labels, names) or ("", "none"))[1] for labels, names in (
        (["com.cmuxterm.next.localpty.write"], ["LocalPTYTerminalIO"]),
        (["com.cmuxterm.next.daemon.write"], ["SocketWriter"]),  # resolved from `SocketWriter(fd:, label: "...")`
        (["com.cmuxterm.next.control."], ["ControlConnection"]),
        ([], ["FrameScheduler"]),
        ([], ["LaneScheduler"]),
    )], ["PTY read/write", "Blocking `read(2)`", "Non-blocking reads", "Non-blocking reads", "none"])
    expect("MQ7 one registration per lane", assign_registrations([(25, None), (90, None)], [92]), {90})
    expect("MQ7 registration lines", [bool(SWIFT_REGISTRATION.search(t)) and not SWIFT_REGISTRATION_EXCLUDE.search(t) for t in (
        'let lane = runtime.hangWatch.registerLane("terminal-output")',
        "private let watch: HangWatch.Registration",
        "public func registerLane(_ name: StaticString) -> Registration {",
        "let scope = hangWatch.watch(lane, deadline: .seconds(1))")], [True, True, False, False])
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
    expect("MQ8 multiline symbol", [rust_site_symbol(m, "thread") for m in rg.stdin_rg(Q.MQ8_THREADS, "x()\n" + multi, multiline=True)],
           ["mux-conn"])
    rust = [
        "fn start() {",
        "    let a = std::thread::Builder::new()",
        '        .name("mux-conn".into())',
        "        .spawn(move || {",
        '            let _g = cmux_hang_watch::register_thread("mux-conn");',
        '            serve(")");',
        "        });",
        '    let b = std::thread::Builder::new().name("mux-line-out".into()).spawn(move || {',
        "        write_loop();",
        "    });",
        "}",
    ]
    scopes = [(2, rust_site_scope(rust, 2, "thread")), (8, rust_site_scope(rust, 8, "thread"))]
    expect("MQ8 scopes", [scope for _, scope in scopes], [(2, 7), (8, 10)])
    expect("MQ8 one registration per thread",
           assign_registrations(scopes, rust_registrations(rust, [sc for _, sc in scopes if sc])), {2})
    expect("MQ8 registration in the called function",
           assign_registrations(scopes, rust_registrations(rust + ["fn write_loop() {", '    let _g = register_thread("mux-line-out");', "}"],
                                                           [sc for _, sc in scopes if sc])), {2, 8})
    expect("MQ8 use line", rust_registrations(["use cmux_hang_watch::register_thread;"], []), [])
    expect("MQ8 runtime scope", rust_site_scope(["let rt = tokio::runtime::Builder::new_multi_thread()",
                                                 "    .on_thread_start(cmux_hang_watch::tokio::on_start)",
                                                 "    .build()?;"], 1, "runtime"), (1, 3))
    expect("MQ8 format", len(lines_of(Q.MQ8_THREADS, 'thread::Builder::new().name(format!("surface-{id}"))\n')), 1)
    expect("MQ8 other", lines_of(Q.MQ8_THREADS, 'thread::Builder::new().name("other".into())\n'), [])
    expect("MQ8 runtime", len(lines_of(Q.MQ8_RUNTIMES, "tokio::runtime::Builder::new_multi_thread()\n")), 1)
    expect("MQ9 panic", len(lines_of(Q.MQ9_PANIC, "cmux_panic_log::install(p)\ncmux_panic_log::install_with_opener(a)\n")), 2)
    expect("MQ9 blackbox", len(lines_of(Q.MQ9_BLACKBOX, "cmux_trace::init_blackbox(dir)\nmy_init_blackbox(x)\n")), 1)
    # install-cmux-tui-client.sh: bin/cmux, with bin/cmux-tui and bin/acpmux as symlinks to it.
    mapped, unmapped_bins = map_bundle_binaries(["acpmux", "cmux", "cmux-tui", "cmux-holder", "other"], {})
    expect("MQ9 one role once", [role.name for role, _, _ in mapped],
           ["acpmux", "agent-host", "daemon", "mcp-serve", "holder"])
    expect("MQ9 unmapped", unmapped_bins, ["other"])
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
    diffs = sentry_diffs(
        {"enableLogs": ("false", 3), "enableSwizzling": ("true", 4), "enableCaptureFailedRequests": ("false", 5)},
        {"enableLogs": ("false", 1), "enableMetricKit": ("false", 2)},
    )
    expect("MQ10 both directions", [(h.symbol, h.extra["app"], h.extra["cli"]) for h in diffs],
           [("enableMetricKit", "unset", "false"), ("enableSwizzling", "true", "unset")])
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
    expect("MQ13", len(lines_of(Q.MQ13, "std::thread::spawn(move || {})\nthread::spawn(f)\nthread::Builder::new().spawn(f)\n"
                                        "echo_thread::spawn(\"mux-line-out\", f)\ncmux_threads::spawn(n, q, f)\n")), 2)
    expect("MQ13 test code", rust_test_lines(["fn a() { thread::spawn(f); }", "#[cfg(test)]", "mod tests {",
                                              "    fn t() { let c = '{'; thread::spawn(|| {}); }", "}",
                                              "#[cfg(all(test, unix))]", "mod test_pty;", "fn b() {}"]),
           ({2, 3, 4, 5, 6, 7}, ["test_pty"]))
    expect("MQ14", lines_of(Q.MQ14, "Task.detached(priority: .utility) {}\nTask {}\n"
                                    "TracedTask.detached(priority: .utility) {}\n_Concurrency.Task.detached {}\n"),
           ["Task.detached(priority: .utility) {}", "_Concurrency.Task.detached {}"])
    expect("MQ15", len(lines_of(Q.MQ15, "let c = ContinuousClock()\nlet s = SuspendingClock()\n")), 1)
    def clock_done(lines: List[str], line: int) -> bool:
        return marked(lines, line, CONTINUOUS_CLOCK_REPLACED, CONTINUOUS_CLOCK_ESCAPE)

    expect("MQ15 done", [clock_done([t], 1) for t in
                         ("ContinuousClock.now // continuous-clock: counts sleep on purpose", "ContinuousClock.now",
                          "let c: any Clock = SuspendingClock() as ContinuousClock?")],
           [True, False, True])
    expect("MQ15 TraceClock above", clock_done(["let t0 = TraceClock.nowNanos()", "let start = ContinuousClock.now"], 2), False)
    expect("MQ15 escape above", clock_done(["// continuous-clock: counts sleep on purpose", "let s = ContinuousClock.now"], 2), True)
    expect("MQ15 trailing escape above", clock_done(["let a = ContinuousClock.now // continuous-clock: x",
                                                     "let b = ContinuousClock.now"], 2), False)
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
