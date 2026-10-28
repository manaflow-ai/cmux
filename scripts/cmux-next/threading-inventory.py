#!/usr/bin/env python3
"""Whole-tree threading inventory: every line of a revision judged by the pre-push threading rules.

guardrails.py judges only what a push adds. This tool imports it (its rules unchanged) and judges every Swift line
under Packages/macOS/CmuxNext/Sources at REV as a push from the empty tree (4b825dc6) would add it, so the
p02-threads machine queues (plans/cmux-next/chrome-parity/p02-threads.md section 6) come from the same definitions
the hook refuses. The rules model Chromium's blocking discipline: base/threading/scoped_blocking_call.h (a blocking
call is marked and may not run on the UI thread) and base/threading/thread_restrictions.h (the reviewed allow list).

The linked section (p02-threads-130): CmuxNext's Package.swift links Shared, macOS and iOS packages by path, and
the library targets its `.target`s reach through `.product` dependencies (guardrails' linked_closure, transitively;
not test-only products, executables or macros) run in the app. Those targets' sources are judged by the same
rules, by their own targets' isolation (none is main actor by default), with CmuxThreading's `blockingCall` closure as
their seam, and `--count` reports them apart: `linked:<rule> N` lines after the CmuxNext ones (`"linked"` in
`--count --jsonl`), so the CmuxNext counts stay comparable across revisions. `--paths` and `--group` take them as any
other file (a linked hit's module is the folder after its package's `Sources/`).

Rules: main-blocking, raw-blocking, pool-blocking, raw-blocking-ext, maybe-main-blocking, task-priority, thread-doc,
once-blocking (p02-threads-122: a blocking call in a static, lazy or global initializer, MQ-22),
awaited-low-priority (p02-threads-113: a low-priority task whose value main-actor code awaits; MQ-19), and the
inventory's own cpu-intensive (p02-threads-121: a raw JSON, property list, image, compression or regex call whose isolation,
as the hit reports it, is main, instead of its size-gated seam; MQ-18). The hook gives a raw primitive that surely runs on
main to main-blocking only (one refusal per line); the inventory lists each line under every rule it breaks, so
raw-blocking here also holds the raw primitives main-blocking took (each still needs its seam), and a raw primitive on a
pool thread is both raw-blocking and pool-blocking (MQ-3 counts the latter). raw-blocking-ext (POSIX, FileHandle, ImageIO,
sqlite3, sysctl and FileManager variables) is reported on any thread, by the hook too.

Each hit carries its call-graph context, read lexically from the source:
  enclosing_func  `Type.name` of the function, initializer, subscript or computed property around the line
  is_async        whether that declaration is `async` (effects after its parameter list)
  isolation       main | pool | nonisolated | actor | unknown: the innermost main-thread opener (`MainActor.run {`,
                  `DispatchQueue.main.asyncAfter {`, a `{ @MainActor in` closure), pool opener (`Task.detached {`,
                  `queue.async {`, `group.addTask {`, a global queue), or declaration that states isolation
                  (`@MainActor`, `@concurrent`, `nonisolated`, an `actor`, minus its `static` members), else the
                  target's default. Control flow, `Task {`, an immediately called closure and the inline forms
                  (`map`, `forEach`, `withLock`, `withTaskGroup`, ...) keep their context's isolation; any other
                  closure (an assigned handler, a completion, `@Sendable`) is `unknown`: it may run later or
                  elsewhere, as guardrails' runs_on_main says.
  caller_count    call sites of the function where Swift lets them be: its file (`private`), its module (internal,
                  the default) or all Sources (`public`, `package`, `open`, also inside an extension that states no
                  access); `Type(` for an initializer; null for a deinit, subscript or accessor. A call site has the
                  function's name, argument labels that fit its parameters (defaults may be left out, a trailing
                  closure fills the rest), and a receiver that fits: `Type.` / `Self.` / a bare call inside the
                  type for a static member, any value or a bare call inside the type for an instance member. A
                  value's type is not resolved, so a same-named, same-labelled method of another type still counts:
                  an upper bound. Lexical: an extension in another file does not tell its type's isolation.

  threading-inventory.py --count                                   # hits per rule at HEAD
  threading-inventory.py --rev 772cdfc45ac --count
  threading-inventory.py --rule raw-blocking --group root --max-hits 25
  threading-inventory.py --rule main-blocking --jsonl
  threading-inventory.py --rule pool-blocking --group module --max-hits 25   # MQ-3
  threading-inventory.py --rule cpu-intensive --group module --max-hits 25   # MQ-18
  threading-inventory.py --rule raw-blocking --paths Packages/macOS/CmuxNext/Sources/CmuxNextFiles/
  threading-inventory.py --rule raw-blocking-ext --group module --max-hits 25   # MQ-16
  threading-inventory.py --rule raw-blocking --rule raw-blocking-ext --rule pool-blocking --rule task-priority --paths Packages/Shared Packages/iOS Packages/macOS/CmuxUpdater --group module   # MQ-17
  threading-inventory.py --rule sync-inversion --jsonl                          # MQ-8
  threading-inventory.py --rule once-blocking --jsonl                           # MQ-22
  threading-inventory.py --rule awaited-low-priority                            # MQ-19
  threading-inventory.py --task-graph plans/cmux-next/chrome-parity/design-result.json --program p02-threads

--task-graph (p02-threads-110) expands each task's file list at REV (files, folders, globs, `{a,b}` lists, ranges such
as p02-threads-060..101 split by module as section 9 lists them, and machine-queue placeholders resolved to the files
with hits of the queue's rule) and prints, for every file more than one task touches, {file, tasks, resolution}: the
depends_on edges that order its tasks (by task id; directory-wide tasks after the tasks that name the file) so each
file has one owner per wave, a wave being a dependency level. It reads the plan file and git objects only.

Reads git objects only (ls-tree, cat-file): no network, no file in the repo or beside the scripts, not even bytecode
caches. git_batch hands git its request through an unnamed temporary file in TMPDIR (a pipe hangs on some hosts),
which is gone when the read returns. Not a CI gate (Lawrence 2026-10-23); run it yourself.
"""
from __future__ import annotations

import sys

sys.dont_write_bytecode = True  # importing guardrails and its siblings must not write __pycache__

import argparse
import bisect
import collections
import fnmatch
import importlib.util
import json
import re
import subprocess
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Callable, Iterable

HERE = Path(__file__).resolve().parent


def load_guardrails():
    """guardrails.py beside this file, as a module: the rules are read from it, never copied."""
    spec = importlib.util.spec_from_file_location("cmux_next_guardrails_inventory", HERE / "guardrails.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module  # its dataclasses resolve their module through sys.modules
    spec.loader.exec_module(module)
    return module


g = load_guardrails()
RULE_BY_ID = {rule.id: rule for rule in g.RULES}


def module_of(path: str) -> str:
    """The Swift module of PATH: guardrails' for CmuxNext's Sources, else the folder after a linked package's
    `Sources/` (`Packages/Shared/CmuxHomeCore/Sources/CmuxHomeCore/X.swift` -> `CmuxHomeCore`)."""
    if path.startswith(g.SOURCES):
        return g.module_of(path)
    parts = path.split("/Sources/", 1)
    return parts[1].split("/", 1)[0] if len(parts) == 2 else ""


def main_default(path: str, targets: set[str]) -> bool:
    """Whether PATH's target is main actor by default: one of CmuxNext's TARGETS (`uiSwiftSettings`), or a linked
    package's target that says so."""
    return g.linked_main_default(path) if g.linked_package(path) else module_of(path) in targets


def raw_blocking(changes: list, moved: collections.Counter) -> list:
    """guardrails' raw-blocking hits plus the raw primitives its main-blocking rule took (they still need a seam;
    in a linked package, CmuxThreading's `blockingCall` closure around one is its seam)."""
    hits = g.raw_blocking(changes, moved)
    by_path = {change.path: change for change in changes}
    for hit in g.blocking_on_main(changes, moved):
        code = g.code_of(hit.text)
        if (g.blocking_match(g.RAW_SCAN, code) and not g.ALWAYS_SCAN.search(code)
                and not g.linked_seam_marked(by_path[hit.path].head, hit.number - 1, code)):
            hits.append(hit)
    return hits


def guardrails_rule(rule_id: str) -> Callable[[list, collections.Counter], list]:
    return RULE_BY_ID[rule_id].find


# Long CPU work whose cost grows with its input: Codable, JSONSerialization and PropertyListSerialization decoding,
# image decoding, compression and regular-expression searches. Chrome disallows it on the UI thread
# (`AssertLongCPUWorkAllowed`, base/threading/thread_restrictions.h) and sends large JSON and image decodes to its data
# decoder service (services/data_decoder/public/cpp/data_decoder.h). Each has a size-gated seam in
# CmuxNextCompat/Threading/CPUIntensive+Blocking.swift (`decoder.blockingDecode`, `JSONSerialization.blockingJSONObject`,
# `PropertyListSerialization.blockingPropertyList`, `blockingImageDecode` (wrap its CGImage for an NSImage,
# NSBitmapImageRep or CIImage), `blockingCompress`, `blockingDecompress`, `regex.blockingRegexMatches`). A keyed
# container's `decode(_:forKey:)` decodes no bytes, making an NSRegularExpression searches nothing, and a `matches(in:)`
# with no `range:` is not NSRegularExpression's (a search over an NSRange): none is a hit.
CPU_INTENSIVE = re.compile(
    r"(?<![\w.])(?:JSONDecoder|PropertyListDecoder)\(\)\s*\.decode\("
    r"|(?<!\bSelf)\.decode\((?:[^()]|\([^()]*\))*?,\s*from:"
    r"|\bJSONSerialization\.jsonObject\("
    r"|\bPropertyListSerialization\.propertyList\(from:"
    r"|\bCGImageSourceCreate(?:WithData|WithURL|WithDataProvider|ImageAtIndex|ThumbnailAtIndex|Incremental)\("
    r"|\bNSImage\((?:data|contentsOf|contentsOfFile):"
    r"|\bNSBitmapImageRep\(data:"
    r"|\bCIImage\(data:"
    r"|\.(?:compressed|decompressed)\(using:"
    r"|\.(?:matches|firstMatch|numberOfMatches|enumerateMatches|stringByReplacingMatches|replaceMatches|"
    r"rangeOfFirstMatch)\(in:(?:[^()]|\([^()]*(?:\([^()]*\)[^()]*)*\))*?\brange:")
CPU_INTENSIVE_SCAN = g.Prefiltered(CPU_INTENSIVE, (".decode(", "jsonObject(", "propertyList(from:", "CGImageSourceCreate",
                                                   "NSImage(", "NSBitmapImageRep(", "CIImage(", "compressed(using:",
                                                   "(in:"))


def cpu_intensive(changes: list, moved: collections.Counter) -> list:
    """Raw long-CPU calls (CPU_INTENSIVE) that run on the main thread, outside the seams: each goes through its
    size-gated seam, which is the plain call off the main thread and below its gate, and a ``cpu-intensive`` site on
    the main thread above it. A line counts when the inventory's own context reader (context_of, the `isolation`
    the hit reports) puts it on main in a main-actor target (`uiSwiftSettings`): directly in main-actor code, or in
    a closure that keeps that isolation (`Task {`, `map {`, `withLock {`, control flow) or that runs on main
    (`MainActor.run {`). A line in a pool closure (`Task.detached {`, `queue.async {`, `Task {` off any actor), an
    actor's method, a `nonisolated` or `@concurrent` declaration, or a closure that may run elsewhere is already off
    the main thread (or not known to be on it), so it is not a hit: the pool and the `.cpu` lane are where this work
    belongs. `// blocking-allow:` escapes a line, as for the other blocking rules."""
    targets = g.ui_targets()
    in_main_actor = [c for c in g.outside_seams(changes) if main_default(c.path, targets)]

    def judge(version, index: int, code: str) -> bool:
        match = CPU_INTENSIVE_SCAN.search(code)
        if match is None or index >= len(version.lines):
            return False
        return context_of(version.lines, index, code[:match.start()], True).isolation == "main"
    return g.changed_debt(in_main_actor, judge)


# sync-inversion: a thread waits for a serial queue (`queue.sync {`, `queue.blockingSync {`,
# `asyncAndWait`) that runs below the waiter's QoS, so the waiter's frame or reply sits behind everything queued there
# at a lower class. Main-thread waits must be donating ones only (p02-threads.md D): a Mutex, or `blockingSync` onto a
# serial queue of greater or equal QoS; Chrome's UI thread never waits on a lower-priority sequence
# (base/threading/thread_restrictions.h, `ScopedAllowBaseSyncPrimitives` is the reviewed exception). A queue's QoS is
# its `DispatchQueue(label:qos:)` (none states `.default`; a `target:` or a computed qos is unknown and not judged),
# found in the file or another file of the same type (`extension T`), or `DispatchQueue.global(qos:)`. The waiter's QoS
# is user-interactive on the main thread, the queue's own inside a `queue.async {` / `queue.sync {` closure, and
# otherwise its function's callers' (one level, through the same call sites caller_count counts): a call site on main
# or in a queue closure above the queue. `allowBlocking(.reason) {` (a reviewed terminate wait) and
# `// blocking-allow:` escape a line.
QOS_RANK = {"background": 0, "utility": 1, "default": 2, "unspecified": 2, "userInitiated": 3, "userInteractive": 4}
MAIN_RANK = QOS_RANK["userInteractive"]
QUEUE_DECLARATION = re.compile(
    r"(?:\b(?:let|var)\s+|\bself\.)`?(\w+)`?\s*(?::\s*DispatchQueue[?!]?\s*)?=\s*DispatchQueue\s*\(")
QOS_ARGUMENT = re.compile(r"\bqos:\s*\.(\w+)\s*[,)]")
SYNC_WAIT = re.compile(r"(?<![\w$.])(?:self\s*\.\s*)?`?(\w+)`?\s*\.\s*(?:sync|blockingSync|asyncAndWait)\s*[({]")
GLOBAL_SYNC_WAIT = re.compile(
    r"\bDispatchQueue\.global\(\s*qos:\s*\.(\w+)\s*\)\s*\.\s*(?:sync|blockingSync|asyncAndWait)\s*[({]")
QUEUE_CLOSURE = re.compile(
    r"(?<![\w$.])(?:self\s*\.\s*)?`?(\w+)`?\s*\.\s*(?:async|asyncAfter|sync|blockingSync|asyncAndWait)\b[^{]*\{$")
ALLOW_BLOCKING = re.compile(r"\ballowBlocking\s*\(")
SYNC_KEYS = (".sync", "blockingSync", "asyncAndWait")


class QueueTable:
    """The declared QoS rank of each named queue, by (module, innermost type, name); None for one that targets another
    queue or states a computed qos. Read once from every source file of the tree."""

    def __init__(self, sources: dict[str, str]):
        self.ranks: dict[tuple[str, str | None, str], int | None] = {}
        for path, text in sources.items():
            if "DispatchQueue" not in text:
                continue
            lines = text.split("\n")
            types: list | None = None
            for index, line in enumerate(lines):
                code = g.code_of(line)
                for match in QUEUE_DECLARATION.finditer(code):
                    if types is None:
                        types = type_by_line(lines)
                    arguments = self.arguments(lines, index, code, match.end() - 1)
                    self.ranks[(module_of(path), types[index], match.group(1))] = self.rank(arguments)

    @staticmethod
    def arguments(lines: list[str], index: int, code: str, start: int) -> str | None:
        text, k = code[start:], index
        while (end := closing(text, 0)) < 0:
            k += 1
            if k >= len(lines) or k - index > CALL_LINES:
                return None
            text += " " + g.code_of(lines[k])
        return text[1:end]

    @staticmethod
    def rank(arguments: str | None) -> int | None:
        if arguments is None or "target:" in arguments:
            return None
        if "qos:" not in arguments:
            return QOS_RANK["default"]
        found = QOS_ARGUMENT.search(arguments + ")")
        return QOS_RANK.get(found.group(1)) if found else None

    def of(self, path: str, owner: str | None, name: str) -> int | None:
        return self.ranks.get((module_of(path), owner, name))


def waiter_rank(lines: list[str], index: int, prefix: str, path: str, queues: QueueTable, types: list) -> int | str | None:
    """The QoS rank of the thread that runs LINES[INDEX] (PREFIX: the code before the wait): MAIN_RANK on the main
    thread, a queue's rank inside its closure, "callers" when only its function's callers can tell, None when unknown
    (an escaping closure, the pool, an actor). "allowed" inside an `allowBlocking(` scope."""
    for opener, number in g.enclosing_openers(lines, index, NEVER, prefix):
        header, _ = declaration_header(lines, number, opener) if number - 1 != index else (opener, "")
        if g.DECLARATION_OPENER.search(header):
            break
        statement = own_statement(opener)
        if ALLOW_BLOCKING.search(statement):
            return "allowed"
        queue = QUEUE_CLOSURE.search(statement)
        if queue and queue.group(1) != "main":
            return queues.of(path, types[number - 1], queue.group(1))
        isolation = closure_isolation(lines, number, opener, header)
        if isolation == "main":
            return MAIN_RANK
        if isolation is not None:
            return None
    ctx = context_of(lines, index, prefix, main_default(path, g.ui_targets()))
    if ctx.isolation == "main":
        return MAIN_RANK
    if ctx.isolation in ("nonisolated", "unknown") and ctx.func_name and ctx.is_async is False:
        return "callers"
    return None


def sync_inversion(changes: list, moved: collections.Counter, tree: "Tree") -> list:
    """Sync waits onto a serial queue below the waiter's QoS (the comment above QOS_RANK)."""
    queues = QueueTable(tree.sources)
    targets = g.ui_targets()
    caller_ranks: dict[Callee, int | None] = {}
    site_files: dict[str, tuple[list[str], list]] = {}

    def site_file(path: str) -> tuple[list[str], list]:
        if path not in site_files:
            lines = tree.sources[path].split("\n")
            site_files[path] = (lines, type_by_line(lines))
        return site_files[path]

    def highest_caller(lines: list[str], index: int, prefix: str, path: str) -> int | None:
        ctx = context_of(lines, index, prefix, main_default(path, targets))
        callee = callee_of(ctx, path)
        if callee is None:
            return None
        if callee not in caller_ranks:
            ranks = []
            for site_path, site_index, before in call_sites(tree, [callee]).get(callee, []):
                site_lines, site_types = site_file(site_path)
                rank = waiter_rank(site_lines, site_index, before, site_path, queues, site_types)
                ranks.append(rank if isinstance(rank, int) else None)
            caller_ranks[callee] = max((r for r in ranks if r is not None), default=None)
        return caller_ranks[callee]

    def judge(version, index: int, code: str) -> bool:
        if not any(key in code for key in SYNC_KEYS) or index >= len(version.lines):
            return False
        lines, path = version.lines, version.path
        if "types_by_line" not in version.memo:
            version.memo["types_by_line"] = type_by_line(lines)
        types = version.memo["types_by_line"]
        for match in SYNC_WAIT.finditer(code):
            if match.group(1) == "main":
                continue  # DispatchQueue.main.sync: main-blocking's
            target = queues.of(path, types[index], match.group(1))
            if target is not None and inverted(lines, index, code[:match.start()], path, target, types):
                return True
        for match in GLOBAL_SYNC_WAIT.finditer(code):
            target = QOS_RANK.get(match.group(1))
            if target is not None and inverted(lines, index, code[:match.start()], path, target, types):
                return True
        return False

    def inverted(lines: list[str], index: int, prefix: str, path: str, target: int, types: list) -> bool:
        waiter = waiter_rank(lines, index, prefix, path, queues, types)
        if waiter == "callers":
            waiter = highest_caller(lines, index, prefix, path)
        return isinstance(waiter, int) and waiter > target

    return g.changed_debt(g.outside_seams(changes), judge)


# The inventory's rules, in report order. Later p02-threads tasks add theirs here.
RULES: dict[str, Callable[[list, collections.Counter], list]] = {
    "main-blocking": guardrails_rule("main-blocking"),
    "raw-blocking": raw_blocking,
    "pool-blocking": guardrails_rule("pool-blocking"),
    "raw-blocking-ext": guardrails_rule("raw-blocking-ext"),
    "maybe-main-blocking": guardrails_rule("maybe-main-blocking"),
    "task-priority": guardrails_rule("task-priority"),
    "thread-doc": guardrails_rule("thread-doc"),
    "cpu-intensive": cpu_intensive,
    "sync-inversion": sync_inversion,
    "once-blocking": guardrails_rule("once-blocking"),
    "awaited-low-priority": guardrails_rule("awaited-low-priority"),
}
# Rules that read the whole tree beside the judged files (sync-inversion: queue declarations and call sites).
TREE_RULES = {"sync-inversion"}

# Where on the hit line the judged call starts: braces before it enclose the call, braces after it are its own.
LOCATORS = {
    "task-priority": g.TASK_CALL,
    "thread-doc": g.THREAD_SCAN.pattern,
    "raw-blocking-ext": re.compile(g.RAW_BLOCKING_EXT.pattern + r"|(?<![\w$])\w+[?!]?\.(" + g.FILE_OPS + r")\("),
    "cpu-intensive": CPU_INTENSIVE,
    "sync-inversion": re.compile(SYNC_WAIT.pattern + "|" + GLOBAL_SYNC_WAIT.pattern),
    "once-blocking": re.compile(g.MAIN_SCAN.pattern.pattern + "|" + g.RAW_BLOCKING_EXT.pattern),
    "awaited-low-priority": g.LOW_TASK,
}
DEFAULT_LOCATOR = g.MAIN_SCAN.pattern
ALWAYS = g.ALWAYS_BLOCKING

NEVER = re.compile(r"(?!)")
# Closures that run their body on the main thread, checked before POOL_OPENER: `DispatchQueue.main.asyncAfter(…) {`
# and `RunLoop.main.perform {` are not guardrails' MAIN_OPENER forms, and `Task.detached { @MainActor in` is a pool
# opener's text. Matched on the joined header, which ends with the `{`.
MAIN_CALL = re.compile(r"\b(?:DispatchQueue|RunLoop|OperationQueue)\.main\s*\.\s*(?:async|asyncAfter|sync|perform|addOperation)\b"
                       r"[^{]*\{$|\bMainActor\s*\.\s*(?:run|assumeIsolated)\b[^{]*\{$")
CLOSURE_ATTRIBUTES = re.compile(r"\s*(?:@\w+(?:\([^)]*\))?\s*)*")
POOL_OPENER = re.compile(r"\bTask\.detached\b|\bDispatchQueue\.global\(|\.concurrentPerform\b|\bdetachNewThread\b"
                         r"|(?:^|[=(,]\s*|\breturn\s+)Thread\s*(\{|\(block:)|\baddOperation\s*\{"
                         r"|\baddTask(?:UnlessCancelled)?\s*(\([^{]*\))?\s*\{"
                         r"|(?<!\bmain)\.async(After)?\s*(\([^{]*\))?\s*\{")
# Closures that run inline, in their context's isolation: `Task {` inherits it, and these calls run their closure
# before they return.
INLINE_CALLS = g.INLINE_CALLS
INLINE_CLOSURE = re.compile(rf"\bTask\s*(?:\([^{{}}]*\))?\s*\{{$|\b(?:{INLINE_CALLS})\s*(?:\([^{{}}]*\))?\s*\{{$"
                            rf"|\b(?:{INLINE_CALLS})\(\s*(?:\w+\s*:\s*)?\{{$")
ASSIGNED_CLOSURE = re.compile(r"(?<![=!<>])=\s*\{$")
INVOKED_LINES = 400  # how far an assigned closure is followed to its `}()`
FUNC_KINDS = {"func", "init", "deinit", "subscript"}
ACCESSORS = {"get", "set", "willSet", "didSet", "_read", "_modify"}
TYPE_KINDS = {"class", "struct", "enum", "actor", "extension", "protocol"}
FUNC_NAME = re.compile(r"\bfunc\s+`?([^\s(<`]+)")
VAR_NAME = re.compile(r"\bvar\s+`?(\w+)")
VAR_KEYWORD = re.compile(r"\bvar\b")
TYPE_NAME = re.compile(r"\b(?:class|struct|enum|actor|protocol)\s+(\w+)|\bextension\s+([\w.]+)")
EFFECTS = re.compile(r"\s*((?:async|reasync|throws(?:\s*\([^)]*\))?|rethrows)\b\s*)*")
NONISOLATED = re.compile(r"\bnonisolated\b(?!\s*\(unsafe\))")
STATIC = re.compile(r"\bstatic\b|\bclass\s+(?=(?:func|var|let|subscript)\b)")
PRIVATE = re.compile(r"\b(private|fileprivate)\b(?!\s*\(set\))")
PUBLIC = re.compile(r"\b(public|open|package)\b(?!\s*\(set\))")
INTERNAL = re.compile(r"\binternal\b(?!\s*\(set\))")
# A line of attributes only (`@MainActor @Observable`); guardrails' ATTRIBUTE_LINE takes one.
ATTRIBUTES_LINE = re.compile(rf"^\s*(?:{g.ATTRIBUTE}\s*)+$")
CALL = re.compile(r"(?<![\w$])`?(\w+)`?\s*\(")
# A call site: `name(`, or a trailing-closure-only `name {`.
CALL_SITE = re.compile(r"(?<![\w$])`?(\w+)`?\s*([({])")
NOT_A_CALL_BEFORE = re.compile(r"(\bfunc|\bcase\s*\.?|\bcase\s+let\s+\.?)\s*$")
# What may stand before a trailing-closure-only call `name {`. A type list (`: P, Q {`), a condition (`if ok {`,
# `x == y {`) or a declaration is not a call.
BRACE_CALL_BEFORE = re.compile(r"(?:^|(?<![=!<>])=|[(.]|\b(?:return|await|try[?!]?))\s*$")
ARG_LABEL = re.compile(r"\s*`?(\w+)`?\s*:(?!:)")
CALL_LINES = 30  # how far an argument list is read across lines


@dataclass
class Hit:
    rule: str
    path: str
    line: int
    module: str
    ui_target: bool
    text: str
    enclosing_func: str | None
    is_async: bool | None
    isolation: str
    caller_count: int | None
    enclosing_type: str | None = None
    group: str | None = None
    # Not reported: what caller_count and --group root need.
    func_name: str | None = field(default=None, repr=False)
    func_line: int | None = field(default=None, repr=False)
    callee: Callee | None = field(default=None, repr=False)

    def record(self) -> dict:
        out = asdict(self)
        for key in ("func_name", "func_line", "callee"):
            out.pop(key)
        if out["group"] is None:
            out.pop("group")
        return out


Scope = tuple[str, str]  # ("file", path) | ("module", module) | ("tree", "")


@dataclass(frozen=True)
class Param:
    label: str  # the argument label a call writes (`_` for none)
    optional: bool  # a default value or a variadic: a call may leave it out
    variadic: bool = False  # takes any number of arguments
    plain_value: bool = False  # a String, number, URL, Data, array...: no trailing closure can fill it


@dataclass(frozen=True)
class Callee:
    """What a call site of a hit's function must match: name, kind (func | init), the type it is a member of, whether
    it is static, its parameters (None when the header could not be read: any labels fit) and the scope callers are
    in."""
    name: str
    kind: str
    owner: str | None
    static: bool
    params: tuple[Param, ...] | None
    scope: Scope
    returns_own_type: bool = False  # `-> Self` or `-> Owner`: an implicit member `.name(` can reach a static one


@dataclass
class Context:
    enclosing_func: str | None = None
    func_name: str | None = None  # the name a call site uses (`Type` for an initializer)
    func_kind: str | None = None
    func_line: int | None = None  # 1-based line of the declaration's `{`
    func_header: tuple[str, int] | None = None  # (joined header, end of its keyword)
    func_access: str | None = None  # file | tree | module (`internal`) | None (unstated): the declaration's own
    func_static: bool = False  # `static` / `class` on the function or a function around it
    type_access: str | None = None  # file | tree | module | None (unstated) of the innermost type or extension
    type_is_extension: bool = False
    in_private_type: bool = False  # some type or extension around it is private or fileprivate
    is_async: bool | None = None
    isolation: str | None = None
    types: list[str] = field(default_factory=list)  # innermost first


HEADER_END = re.compile(r"[{};]\s*$|^\s*$|^\s*(//|\*|/\*)")


def declaration_header(lines: list[str], number: int, opener: str) -> tuple[str, str]:
    """(header, attribute lines above it) of the block that opens on 1-based line NUMBER. A one-line header is the
    opener; a wrapped one is joined back to the previous statement's end, like guardrails' block_header, except
    that a line starting with an attribute (`@concurrent static func f(`) belongs to it: block_header stops there."""
    k = number - 2
    parts = [opener]
    if not g.DECLARATION_OPENER.search(opener):
        while k >= 0 and number - 1 - k <= g.HEADER_LINES:
            text = g.code_of(lines[k])
            if HEADER_END.search(text) or ATTRIBUTES_LINE.match(text):
                break
            parts.insert(0, text)
            k -= 1
    above = []
    while k >= 0 and (ATTRIBUTES_LINE.match(lines[k]) or g.COMMENT_LINE.match(lines[k])
                      or g.code_of(lines[k]).strip() == "nonisolated"):
        if not g.COMMENT_LINE.match(lines[k]):
            above.insert(0, g.code_of(lines[k]).strip())
        k -= 1
    return " ".join(part.strip() for part in parts), " ".join(above)


def access_of(prefix: str) -> str | None:
    """Where a declaration with these modifiers can be called from: its file, the whole tree, its module
    (`internal` stated), or None when no access is stated."""
    if PRIVATE.search(prefix):
        return "file"
    if PUBLIC.search(prefix):
        return "tree"
    if INTERNAL.search(prefix):
        return "module"
    return None


def call_scope(ctx: Context) -> str:
    """Where the enclosing function's callers can be (Swift access control): file, module or tree. A member is
    internal unless it says otherwise; a private type or extension keeps its members in its file. A public member
    of a type is as visible as the type. In an extension the extended type limits it, and a lexical reader cannot
    see that type, so a public member of an extension that states no access counts the whole tree (an upper bound);
    only `internal extension` keeps it in its module. A `public extension` makes its unmarked members public."""
    if ctx.func_access == "file" or ctx.type_access == "file" or ctx.in_private_type:
        return "file"
    if ctx.type_is_extension:
        if ctx.func_access == "tree":
            return "module" if ctx.type_access == "module" else "tree"
        return "tree" if ctx.type_access == "tree" else "module"
    if ctx.func_access == "tree":
        return "tree" if not ctx.types or ctx.type_access == "tree" else "module"
    return "module"


def declared_isolation(prefix: str, kind: str, static_member: bool = False) -> str | None:
    """The isolation a declaration with PREFIX states. An actor's static members are not isolated to it: they run
    where their caller does (STATIC_MEMBER)."""
    if "@MainActor" in prefix:
        return "main"
    if "@concurrent" in prefix:
        return "pool"
    if NONISOLATED.search(prefix):
        return "nonisolated"
    if kind == "actor":
        return "nonisolated" if static_member else "actor"
    return None


def is_async(header: str, keyword_end: int, kind: str) -> bool:
    """Whether the declaration's effects (after its parameter list, or after an accessor keyword) say `async`."""
    rest = header[keyword_end:]
    if kind in FUNC_KINDS:
        if kind == "deinit":
            return False
        start = rest.find("(")
        if start < 0:
            return False
        depth = 0
        for i in range(start, len(rest)):
            depth += rest[i] == "("
            depth -= rest[i] == ")"
            if depth == 0:
                rest = rest[i + 1:]
                break
        else:
            return False
    elif kind == "var":
        return False
    return "async" in EFFECTS.match(rest).group(0).split()


def invoked_inline(lines: list[str], number: int, opener: str) -> bool:
    """Whether the closure whose `{` ends OPENER on 1-based line NUMBER is called where it stands (`= { ... }()`)."""
    depth, k, start = 0, number - 1, len(opener) - 1
    while k < len(lines) and k - (number - 1) <= INVOKED_LINES:
        code = g.code_of(lines[k])
        for pos in range(start, len(code)):
            depth += code[pos] == "{"
            depth -= code[pos] == "}"
            if depth == 0:
                return code[pos + 1:].lstrip().startswith("(")
        k, start = k + 1, 0
    return False


CASE_LABEL = re.compile(r"^\s*(?:case\b[^:]*|default\s*):")


def own_statement(opener: str) -> str:
    """The statement OPENER's last `{` belongs to: OPENER after any `}` that closes a block opened above it and any
    `{` still open before it (a closure argument closed on the line stays), and after a `case ...:` label."""
    cut, open_at = 0, []
    for pos, c in enumerate(opener[:-1]):
        if c == "{":
            open_at.append(pos)
        elif c == "}":
            if open_at:
                open_at.pop()
            else:
                cut = pos + 1
    cut = max([cut] + [pos + 1 for pos in open_at[-1:]])
    return CASE_LABEL.sub("", opener[cut:], count=1)


def is_control(lines: list[str], number: int, opener: str) -> bool:
    """Whether the block OPENER opens on 1-based line NUMBER is control flow. The header may wrap (`if a,\\n b {`),
    and the line above may end a statement with no `;`, so each start back to the previous statement's end is
    tried."""
    text = own_statement(opener)
    k = number - 2 if len(text) == len(opener) else -1  # a brace before it on the line ends the header there
    while not g.CONTROL_OPENER.search(text):
        if k < 0 or number - 1 - k > g.HEADER_LINES:
            return False
        code = g.code_of(lines[k])
        if HEADER_END.search(code) or ATTRIBUTES_LINE.match(code):
            return False
        text, k = f"{code} {text}", k - 1
    return True


def closure_isolation(lines: list[str], number: int, opener: str, header: str) -> str | None:
    """The isolation a non-declaration block on 1-based line NUMBER gives its body, or None when it keeps its
    context's: control flow, `Task {`, an inline call (`forEach {`, `withLock {`) or a closure called where it
    stands. Any other closure may run later or on another thread (guardrails' runs_on_main does not judge it):
    unknown."""
    attributes = CLOSURE_ATTRIBUTES.match(g.code_of(lines[number - 1])[len(opener):]).group(0)
    statement = own_statement(opener)
    if "@MainActor" in attributes or MAIN_CALL.search(header) or g.MAIN_OPENER.search(statement):
        return "main"
    if POOL_OPENER.search(statement):
        return "pool"
    if is_control(lines, number, opener):
        return None
    if "@Sendable" in attributes:
        return "unknown"
    if INLINE_CLOSURE.search(header):
        return None
    if ASSIGNED_CLOSURE.search(header) and invoked_inline(lines, number, opener):
        return None
    return "unknown"


def context_of(lines: list[str], index: int, prefix: str, default_main: bool) -> Context:
    """The declaration, isolation and enclosing types of LINES[INDEX] (0-based), walking its openers outward."""
    ctx = Context()
    accessor: tuple[str, int, str, int] | None = None  # (keyword, opener line, header, keyword end)
    static_line = bool(STATIC.search(prefix))  # a type-level `static let q = ...` hit
    typed = False  # the innermost type or extension was seen
    for opener, number in g.enclosing_openers(lines, index, NEVER, prefix):
        header, attributes = declaration_header(lines, number, opener) if number - 1 != index else (opener, "")
        match = g.DECLARATION_OPENER.search(header)
        if match is None:
            if ctx.isolation is None and ctx.func_kind is None:
                ctx.isolation = closure_isolation(lines, number, opener, header)
            continue
        kind = match.group(4) or "var"
        kind = "init" if kind.startswith("init") else kind
        keyword_start = match.start(4) if match.group(4) else VAR_KEYWORD.search(header).start()
        keyword_end = match.end(4) if match.group(4) else keyword_start + 3
        decl_prefix = f"{attributes} {header[:keyword_start]}"
        if kind not in TYPE_KINDS and kind not in ACCESSORS and STATIC.search(decl_prefix):
            ctx.func_static = True
        if ctx.isolation is None:
            static_member = ctx.func_static if ctx.func_kind is not None or accessor else static_line
            ctx.isolation = declared_isolation(decl_prefix, kind, static_member)
        if kind in ACCESSORS:
            accessor = accessor or (kind, number, header, keyword_end)
            continue
        if kind in TYPE_KINDS:
            access = access_of(decl_prefix)
            ctx.in_private_type = ctx.in_private_type or access == "file"
            if not typed:
                typed, ctx.type_access, ctx.type_is_extension = True, access, kind == "extension"
            name = TYPE_NAME.search(header[keyword_start:])
            if name:
                ctx.types.append((name.group(1) or name.group(2)).split(".")[-1])
            if accessor is not None and ctx.func_kind is None:
                ctx.func_kind, ctx.func_name, ctx.func_line = accessor[0], None, accessor[1]
                ctx.is_async = is_async(accessor[2], accessor[3], accessor[0])
            continue
        if ctx.func_kind is not None:
            continue  # a local function's outer function: the hit belongs to the innermost one
        ctx.func_kind, ctx.func_line, ctx.func_header = kind, number, (header, keyword_end)
        ctx.func_access = access_of(decl_prefix)
        if kind == "func":
            found = FUNC_NAME.search(header)
            ctx.func_name = found.group(1) if found else None
            ctx.is_async = is_async(header, keyword_end, kind)
        elif kind == "var":
            found = VAR_NAME.search(header)
            ctx.func_name = found.group(1) if found else None
            ctx.is_async = is_async(accessor[2], accessor[3], accessor[0]) if accessor else False
        else:
            ctx.func_name = kind
            ctx.is_async = is_async(header, keyword_end, kind)
    if ctx.isolation is None:
        ctx.isolation = "main" if default_main else "nonisolated"
    if ctx.func_kind is not None:
        outer = ctx.types[0] if ctx.types else None
        own = ctx.func_name or ctx.func_kind
        ctx.enclosing_func = f"{outer}.{own}" if outer else own
        if ctx.func_kind == "init":
            ctx.func_name = outer  # an initializer is called by its type's name
        elif ctx.func_kind not in ("func",):
            ctx.func_name = None  # deinit, subscript, accessors: no name-based call site
    return ctx


# ---------------------------------------------------------------- the tree


@dataclass
class Tree:
    """The Swift sources of one revision ({path: text}) and the files the rules read beside them: PACKAGES are the
    linked packages ({folder: guardrails.LinkedPackage}, guardrails' linked_closure of MANIFEST), whose reached
    targets' sources are in SOURCES too and form the report's linked section."""
    sources: dict[str, str]
    threading_doc: str | None = None
    manifest: str | None = None
    packages: dict = field(default_factory=dict)

    def read_package(self, paths: list[str]) -> dict[str, str]:
        """linked_closure's reader over PACKAGES."""
        return {p: self.packages[p.removesuffix("/Package.swift")].text for p in paths
                if p.removesuffix("/Package.swift") in self.packages}


def read_tree(repo: Path, rev: str) -> Tree:
    texts = g.blobs(repo, [(rev, g.THREADING_DOC), (rev, g.PACKAGE_MANIFEST)])
    manifest = texts.get((rev, g.PACKAGE_MANIFEST))

    def read(paths: list[str]) -> dict[str, str]:
        found = g.blobs(repo, [(rev, p) for p in paths])
        return {p: found[(rev, p)] for p in paths if (rev, p) in found}

    packages = g.linked_closure(manifest or "", read)
    roots = [g.SOURCES] + sorted(f"{folder}/{target.path}/" for folder, targets in g.linked_targets(packages).items()
                                 for target in targets)
    listing = g.git(repo, "ls-tree", "-r", "--name-only", rev, "--", *roots)
    paths = [p for p in listing.split("\n") if p.endswith(".swift")]
    texts.update(g.blobs(repo, [(rev, p) for p in paths]))
    return Tree({p: texts[(rev, p)] for p in paths if (rev, p) in texts},
                texts.get((rev, g.THREADING_DOC)), manifest, packages)


def section_of(path: str) -> str:
    """`linked` for a linked package's file (the report's own section), `sources` for CmuxNext's."""
    return "linked" if g.linked_package(path) else "sources"


def path_matcher(patterns: list[str] | None) -> Callable[[str], bool]:
    """A path filter: each pattern is a repo-relative file, folder (prefix) or fnmatch glob (`*` crosses folders)."""
    if not patterns:
        return lambda path: True
    cleaned = [p[2:] if p.startswith("./") else p for p in patterns]

    def match(path: str) -> bool:
        for pattern in cleaned:
            if any(c in pattern for c in "*?["):
                if fnmatch.fnmatchcase(path, pattern):
                    return True
            elif path == pattern or path.startswith(pattern.rstrip("/") + "/"):
                return True
        return False
    return match


def file_change(path: str, text: str):
    """PATH as a new file: every line added over the empty tree."""
    lines = text.split("\n")
    return g.FileChange(path, lines, added=[g.Added(path, i + 1, line) for i, line in enumerate(lines)],
                        base_lines=[], is_new=True)


def load_context(tree: Tree) -> None:
    """Point guardrails' blocking context (threading doc, manifest, UI targets, linked packages) at TREE."""
    texts: dict[tuple[str, str], str] = {}
    rev = "inventory"
    if tree.threading_doc is not None:
        texts[(rev, g.THREADING_DOC)] = tree.threading_doc
    if tree.manifest is not None:
        texts[(rev, g.PACKAGE_MANIFEST)] = tree.manifest
    g.load_blocking_context(texts, rev)
    g.load_linked_packages(tree.manifest, tree.read_package)


def judge(tree: Tree, rules: Iterable[str], paths: Callable[[str], bool]) -> list[tuple[str, object]]:
    """[(rule, guardrails hit)] over the matching files, each rule judging every line against the empty tree."""
    load_context(tree)
    targets = g.swift_scope.package_targets(tree.manifest or "")
    changes = []
    for path in sorted(tree.sources):
        if not paths(path):
            continue
        change = file_change(path, tree.sources[path])
        main = g.linked_main_default(path) if g.linked_package(path) else g.main_by_default(path, targets)
        change.head_main = change.base_main = main
        changes.append(change)
    found = []
    for rule_id in rules:
        rule = RULE_BY_ID.get(rule_id)
        scope = rule.scope if rule is not None else g.LINKED_RULE_SCOPE
        scoped = [c for c in changes if g.in_rule_scope(c.path, scope)]
        extra = (tree,) if rule_id in TREE_RULES else ()
        found += [(rule_id, hit) for hit in RULES[rule_id](scoped, collections.Counter(), *extra)]
    return found


def scope_key(scope: str, path: str) -> Scope:
    return (scope, path if scope == "file" else module_of(path) if scope == "module" else "")


OPEN, CLOSE = "([{", ")]}"


def split_top(text: str, angles: bool) -> list[str]:
    """TEXT split at its top-level commas; ANGLES counts `<...>` as nesting (a type, not a comparison)."""
    parts, depth, start = [], 0, 0
    for i, c in enumerate(text):
        if c in OPEN or (angles and c == "<"):
            depth += 1
        elif c in CLOSE or (angles and c == ">" and text[i - 1:i] != "-"):
            depth -= 1
        elif c == "," and depth == 0:
            parts.append(text[start:i])
            start = i + 1
    parts.append(text[start:])
    return [part for part in parts if part.strip()]


def closing(text: str, start: int) -> int:
    """The index of the bracket that closes TEXT[START], or -1."""
    depth = 0
    for i in range(start, len(text)):
        depth += text[i] in OPEN
        depth -= text[i] in CLOSE
        if depth == 0:
            return i
    return -1


LEADING_ATTRIBUTES = re.compile(rf"^\s*(?:{g.ATTRIBUTE}\s*)*")
PLAIN_VALUE = re.compile(r"^\s*(?:inout\s+)?(?:String|Substring|Character|U?Int(?:8|16|32|64)?|Bool|Double|Float|"
                         r"CGFloat|TimeInterval|URL|Data|Date|UUID|\[[^\]]*\])[?!]?\s*$")
DEFAULT_VALUE = re.compile(r"(?<![=!<>-])=(?!=)")


def parameters(header: str, keyword_end: int) -> tuple[Param, ...] | None:
    """The parameters of the function or initializer HEADER declares (its keyword ends at KEYWORD_END), or None when
    the header holds no whole parameter list."""
    rest, angle, i = header[keyword_end:], 0, 0
    while i < len(rest) and not (rest[i] == "(" and angle <= 0):
        if rest[i] == "{":
            return None
        angle += rest[i] == "<"
        angle -= rest[i] == ">" and rest[i - 1:i] != "-"
        i += 1
    end = closing(rest, i) if i < len(rest) else -1
    if end < 0:
        return None
    params = []
    for part in split_top(rest[i + 1:end], angles=True):
        part = part[LEADING_ATTRIBUTES.match(part).end():]
        names, colon, kind = part.partition(":")
        if not colon or not names.split():
            return None
        typed = DEFAULT_VALUE.split(kind, 1)
        variadic = "..." in typed[0]
        params.append(Param(names.split()[0].strip("`"), len(typed) > 1 or variadic, variadic,
                            bool(PLAIN_VALUE.match(typed[0]))))
    return tuple(params)


RETURN_TYPE = re.compile(r"->\s*([\w.]+)[?!]?\s*(?:where\b[^{]*)?\{?\s*$")


def returns_own_type(header: str, owner: str | None) -> bool:
    """Whether the declaration HEADER returns `Self` or its type OWNER (optionally optional)."""
    found = RETURN_TYPE.search(header)
    return found is not None and found.group(1).split(".")[-1] in ("Self", owner)


def call_arguments(lines: list[str], index: int, code: str, start: int) -> tuple[list[str], bool] | None:
    """(argument labels, whether a trailing closure follows) of the call whose `(` is CODE[START] on LINES[INDEX]
    (`_` for an unlabelled argument), or None when its `)` is not within CALL_LINES lines."""
    text, k = code[start:], index
    while True:
        end = closing(text, 0)
        if end >= 0:
            labels = [label.group(1) if (label := ARG_LABEL.match(arg)) else "_"
                      for arg in split_top(text[1:end], angles=False)]
            return labels, text[end + 1:].lstrip().startswith("{")
        k += 1
        if k >= len(lines) or k - index > CALL_LINES:
            return None
        text += " " + g.code_of(lines[k])


def fits(params: tuple[Param, ...] | None, labels: list[str] | None, trailing: bool) -> bool:
    """Whether a call with LABELS (and a TRAILING closure) can call a function with PARAMS: each label takes the next
    parameter of that label, skipping only ones that may be left out; what is left may be left out, except that a
    trailing closure fills the last one. Unknown parameters or labels fit (an upper bound)."""
    if params is None or labels is None:
        return True
    i = 0
    for label in labels:
        while i < len(params) and params[i].label != label:
            if not params[i].optional:
                return False
            i += 1
        if i == len(params):
            return False
        i += not params[i].variadic
    rest = params[i:]
    if trailing:
        return bool(rest) and not rest[-1].plain_value and all(p.optional for p in rest[:-1])
    return all(p.optional for p in rest)


def receiver_of(before: str) -> tuple[str, str | None]:
    """What a call is made on, from the code BEFORE its name: bare, self, Self, a type (`Type.`), an implicit
    member (`.make(` on the contextual type) or a value (`x.`, `f().`, `x?.`, `super.`)."""
    found = RECEIVER.search(before)
    if found is None:
        return "bare", None
    name = found.group(1)
    if name is None:
        dot = before.rstrip()[:-1].rstrip()
        if not dot:
            return "chain", None  # `.name(` starting a line: a chain on the line above, or an implicit member
        return ("value", None) if dot[-1].isalnum() or dot[-1] in ")]?!_" else ("implicit", None)
    if name in ("self", "Self"):
        return name, None
    return ("type", name) if name[0].isupper() else ("value", name)


def receiver_fits(callee: Callee, called: str, receiver: tuple[str, str | None], caller_type) -> bool:
    """Whether a call named CALLED on RECEIVER can reach CALLEE; CALLER_TYPE() is the type the call is written in."""
    kind, name = receiver
    if callee.kind == "init":
        if called != "init":
            return kind in ("bare", "type")  # `Type(`, `Outer.Type(`
        if kind == "type":
            return name == callee.owner  # `Type.init(`
        return kind in ("self", "Self") and caller_type() == callee.owner  # `self.init(` delegating
    if kind == "type":
        return callee.static and name == callee.owner
    if kind == "implicit":
        return callee.static and callee.returns_own_type  # `.make(` builds the contextual type
    if kind == "value":
        return not callee.static and callee.owner is not None
    if kind == "chain":
        return callee.owner is not None
    if callee.owner is None:
        return kind == "bare"  # a free function
    return caller_type() == callee.owner  # bare, `self.` or `Self.` inside the type


def type_by_line(lines: list[str]) -> list[str | None]:
    """The innermost type or extension (its last name component) each line starts in, by a forward brace scan."""
    out, stack = [], []
    for i, line in enumerate(lines):
        out.append(next((name for name in reversed(stack) if name), None))
        code = g.code_of(line)
        start = 0
        for brace in re.finditer(r"[{};]", code):
            c = brace.group(0)
            if c == "{":
                segment = code[start:brace.end()]
                header = g.block_header(lines, i + 1, segment) if start == 0 else segment
                match = g.DECLARATION_OPENER.search(header)
                name = None
                if match and match.group(4) in TYPE_KINDS:
                    found = TYPE_NAME.search(header[match.start(4):])
                    name = (found.group(1) or found.group(2)).split(".")[-1] if found else None
                stack.append(name)
            elif c == "}" and stack:
                stack.pop()
            start = brace.end()
    return out


def caller_counts(tree: Tree, callees: Iterable[Callee]) -> dict[Callee, int]:
    """{callee: how many call sites it has in its scope} (call_sites)."""
    return collections.Counter({callee: len(sites) for callee, sites in call_sites(tree, callees).items()})


def call_sites(tree: Tree, callees: Iterable[Callee]) -> dict[Callee, list[tuple[str, int, str]]]:
    """{callee: its call sites in its scope, as (path, 0-based line, the code before the call's name)}. A call site
    is `name(` or `name {` in code (comments and string contents dropped), not `func name(` or an enum case pattern,
    whose labels and receiver fit the callee."""
    sites: dict[Callee, list[tuple[str, int, str]]] = collections.defaultdict(list)
    by_name: dict[str, list[Callee]] = collections.defaultdict(list)
    for callee in set(callees):
        by_name[callee.name].append(callee)
        if callee.kind == "init":
            by_name["init"].append(callee)
    if not by_name:
        return sites
    for path, text in tree.sources.items():
        here = {("file", path), ("module", module_of(path)), ("tree", "")}
        lines = text.split("\n")
        types: list | None = None
        for index, line in enumerate(lines):
            if "(" not in line and "{" not in line:
                continue
            code = g.code_of(line)
            for match in CALL_SITE.finditer(code):
                candidates = by_name.get(match.group(1))
                before = code[:match.start()]
                if not candidates or NOT_A_CALL_BEFORE.search(before):
                    continue
                candidates = [c for c in candidates if c.scope in here]
                if not candidates:
                    continue
                if match.group(2) == "(":
                    arguments = call_arguments(lines, index, code, match.end() - 1)
                    labels, trailing = arguments if arguments else (None, False)
                elif BRACE_CALL_BEFORE.search(before):
                    labels, trailing = [], True
                else:
                    continue
                receiver = receiver_of(before)

                def caller_type(index=index):
                    nonlocal types
                    if types is None:
                        types = type_by_line(lines)
                    return types[index]
                for callee in candidates:
                    if fits(callee.params, labels, trailing) and receiver_fits(callee, match.group(1), receiver,
                                                                               caller_type):
                        sites[callee].append((path, index, before))
    return sites


def callee_of(ctx: Context, path: str) -> Callee | None:
    """What a call site of CTX's function must match (Callee), or None outside a named function."""
    if not ctx.func_name:
        return None
    owner = ctx.types[0] if ctx.types else None
    return Callee(ctx.func_name, ctx.func_kind, owner, ctx.func_static and ctx.func_kind == "func",
                  parameters(*ctx.func_header) if ctx.func_header else None, scope_key(call_scope(ctx), path),
                  bool(ctx.func_header) and returns_own_type(ctx.func_header[0], owner))


def inventory(tree: Tree, rules: Iterable[str] = tuple(RULES), paths: Callable[[str], bool] = lambda p: True
              ) -> list[Hit]:
    """Every hit of RULES in TREE's files that PATHS matches, with its call-graph context, in rule then path order."""
    rules = list(rules)
    found = judge(tree, rules, paths)
    targets = g.ui_targets()  # judge() loaded TREE's manifest
    lines_of: dict[str, list[str]] = {}
    hits = []
    for rule_id, hit in found:
        lines = lines_of.setdefault(hit.path, tree.sources[hit.path].split("\n"))
        index = hit.number - 1
        code = g.code_of(lines[index])
        locator = LOCATORS.get(rule_id, DEFAULT_LOCATOR)
        match = locator.search(code) or ALWAYS.search(code)
        prefix = code[:match.start()] if match else code
        module = module_of(hit.path)
        main = main_default(hit.path, targets)
        ctx = context_of(lines, index, prefix, main)
        owner = ctx.types[0] if ctx.types else None
        callee = callee_of(ctx, hit.path)
        hits.append(Hit(rule_id, hit.path, hit.number, module, main, lines[index].strip(),
                        ctx.enclosing_func, ctx.is_async, ctx.isolation, None, owner,
                        func_name=ctx.func_name, func_line=ctx.func_line, callee=callee))
    counts = caller_counts(tree, (hit.callee for hit in hits if hit.callee))
    for hit in hits:
        if hit.callee:
            hit.caller_count = counts.get(hit.callee, 0)
    order = {rule: i for i, rule in enumerate(rules)}
    hits.sort(key=lambda h: (order[h.rule], h.path, h.line))
    return hits


# ---------------------------------------------------------------- grouping


def chunked(label: str, items: list, size: int) -> list[tuple[str, list]]:
    parts = [items[i:i + size] for i in range(0, len(items), size)] or [[]]
    if len(parts) == 1:
        return [(label, parts[0])]
    return [(f"{label}#{n}", part) for n, part in enumerate(parts, 1)]


def group_by_module(hits: list[Hit], max_hits: int) -> list[tuple[str, list[Hit]]]:
    by_module: dict[str, list[Hit]] = collections.defaultdict(list)
    for hit in hits:
        by_module[hit.module].append(hit)
    out = []
    for module in sorted(by_module):
        out += chunked(f"module:{module}", sorted(by_module[module], key=lambda h: (h.path, h.line)), max_hits)
    return out


RECEIVER = re.compile(r"(?:\b(\w+)\s*)?\.\s*$")


def callees(candidates: list, before: str, caller: Hit, units: dict) -> list:
    """The units of CANDIDATES (same module and name) a call resolves to by its receiver: a bare, `self.` or
    `Self.` call is the caller's own type's (a bare call else a free function's), `Type.name(` that type's. A call
    on a value (`data.write(`, `raw.append(`) names no type lexically, so it joins nothing."""
    receiver = RECEIVER.search(before)
    if receiver is None or receiver.group(1) in ("self", "Self"):
        own = [k for k in candidates if units[k][0].enclosing_type == caller.enclosing_type]
        return own or ([k for k in candidates if units[k][0].enclosing_type is None] if receiver is None else [])
    name = receiver.group(1)
    if not name or not name[0].isupper():
        return []
    return [k for k in candidates if units[k][0].enclosing_type == name]


def group_by_root(tree: Tree, hits: list[Hit], max_hits: int) -> list[tuple[str, list[Hit]]]:
    """Hits in chunks of at most MAX_HITS that follow the call graph: the functions holding hits are joined when
    one calls another in the same module (a call `name(` in its body), so a caller and its callee land in one
    chunk; components of one module are packed together up to MAX_HITS, a larger one is split. A chunk is named
    by its first component's root: the function no other function of the component calls."""
    units: dict[tuple[str, int | None], list[Hit]] = collections.defaultdict(list)
    for hit in hits:
        units[(hit.path, hit.func_line)].append(hit)
    keys = sorted(units, key=lambda k: (k[0], k[1] or 0))
    parent = {k: k for k in keys}

    def find(k):
        while parent[k] != k:
            parent[k] = parent[parent[k]]
            k = parent[k]
        return k

    by_name: dict[tuple[str, str], list] = collections.defaultdict(list)
    for key in keys:
        hit = units[key][0]
        if hit.func_name and key[1] is not None:
            by_name[(hit.module, hit.func_name)].append(key)
    called: set = set()
    for key in keys:
        path, opener = key
        if opener is None:
            continue
        lines = tree.sources[path].split("\n")
        caller = units[key][0]
        end = g.block_end(lines, opener - 1)
        for k in range(opener - 1, end + 1):
            code = g.code_of(lines[k])
            for match in CALL.finditer(code) if "(" in code else ():
                candidates = by_name.get((caller.module, match.group(1)))
                for callee in callees(candidates, code[:match.start()], caller, units) if candidates else ():
                    if callee != key:
                        called.add(callee)
                        parent[find(callee)] = find(key)
    components: dict = collections.defaultdict(list)
    for key in keys:
        components[find(key)].append(key)

    used: collections.Counter = collections.Counter()

    def root_label(members: list) -> str:
        """`root:Module/Type.func` of the component's root; the second chunk group with the same root is `~2`."""
        roots = [k for k in members if k not in called] or members
        hit = units[roots[0]][0]
        label = f"root:{hit.module}/{hit.enclosing_func or Path(hit.path).name}"
        used[label] += 1
        return label if used[label] == 1 else f"{label}~{used[label]}"

    ordered = sorted(components.values(), key=lambda m: (units[m[0]][0].module, m[0][0], m[0][1] or 0))
    out: list[tuple[str, list[Hit]]] = []
    pending: list[Hit] = []
    pending_label, pending_module = "", ""
    for members in ordered:
        member_hits = sorted((h for k in members for h in units[k]), key=lambda h: (h.path, h.line))
        module = member_hits[0].module
        if pending and (module != pending_module or len(pending) + len(member_hits) > max_hits):
            out.append((pending_label, pending))
            pending = []
        if len(member_hits) > max_hits:
            out += chunked(root_label(members), member_hits, max_hits)
            continue
        if not pending:
            pending_label, pending_module = root_label(members), module
        pending += member_hits
    if pending:
        out.append((pending_label, pending))
    return out


# ---------------------------------------------------------------- task graph
#
# --task-graph reads the plan's tasks (design-result.json), expands each file list at REV and orders the tasks that
# share a file so that every file has one owner per wave. A wave is a dependency level: a task runs once everything
# it depends on has landed, so a chain of depends_on edges through a file's tasks puts each in its own wave.

QUEUE_RULES = {  # p02-threads.md section 6: the inventory rule behind each machine queue
    "MQ-1": "raw-blocking", "MQ-2": "main-blocking", "MQ-3": "pool-blocking", "MQ-4": "maybe-main-blocking",
    "MQ-5": "task-priority", "MQ-8": "sync-inversion", "MQ-9": "thread-doc", "MQ-16": "raw-blocking-ext",
    "MQ-18": "cpu-intensive", "MQ-19": "awaited-low-priority", "MQ-22": "once-blocking",
}
MQ7_EXCLUDE = ("*/CmuxNextCompat/Threading/*", "*/CmuxNextCompatAppKit/Threading/*", "*/CmuxNextCompatAppKit/NSWorkspace+Background.swift")


@dataclass(frozen=True)
class Pattern:
    """The lines a placeholder stands for where the plan names a pattern instead of a rule (INV-2, INV-5)."""
    regex: str
    exclude: tuple[str, ...] = ()  # fnmatch globs (`*` crosses folders)


TASK_HITS: dict[str, str | Pattern] = {  # placeholders whose task is narrower than its queue
    # 036 owns every lock file (the design's 20); which locks become Mutex is its own judgement.
    "p02-threads-036": Pattern(r"\bOSAllocatedUnfairLock\b|\bNSLock\(|\bNSRecursiveLock\b",
                               ("*/CmuxNextWakeups/*", "*/CmuxNextCompat/*")),
    "p02-threads-054..055": Pattern(r"SecItem(CopyMatching|Add|Update|Delete)\(|SecTrustEvaluate|"
                                    r"SecStaticCodeCheckValidity|SecCodeCopy|AuthorizationCopyRights", MQ7_EXCLUDE),
    "p02-threads-056": Pattern(r"NSWorkspace\.shared\.(urlForApplication|urlsForApplications|icon\()", MQ7_EXCLUDE),
    "p02-threads-057": Pattern(r"NSWorkspace\.shared\.(open\(|activateFileViewerSelecting|selectFile)",
                               ("*/NSWorkspace+Background.swift",)),
    "p02-threads-059": Pattern(r"AXUIElement(Copy|PerformAction|SetAttributeValue)|getaddrinfo\(|"
                               r"CGWindowList(Copy|Create)|SCShareableContent|LSCopy", MQ7_EXCLUDE),
}

# p02-threads.md section 9 (041-045, 047-052, 060-101, 141-144, 213-218): the files each id of a range takes, in id
# order, as (ids, selector). A selector's tokens are Swift modules without the CmuxNext prefix, `Module:glob` for some
# of a module's files, `First..Last` for the modules from First to Last (and those Last prefixes), or a path glob (a
# token with a `/`; `*` crosses folders) for files outside the Swift modules. `*` takes the files no other selector of
# the range takes, `**` all of them. A file goes to the first selector that takes it. Several ids split their files in
# path order. expand_tasks reports the files no selector takes, and a range not listed here, which splits all its
# files in path order.
TUI = "cmux-tui/crates/"
TUI_CORE = TUI + "cmux-tui-core/src/"
SPAWN_CRATES = ("cmux-browser-host", "cmux-remote-browser-host", "cmux-tui-cdp", "cmux-host", "cmux-holder", "cmux-pty",
                "cmux-process", "cmux-git", "cmux-tasks", "cmux-config", "acpmux")
RANGE_PARTS: dict[str, list[tuple[int, str]]] = {
    "p02-threads-041..045": [
        (1, "HomeEngine Pages ImportCards"), (1, "AgentPane MacScreen ComputerUse Mobile RemoteViewSessions"),
        (1, "Browser..Daemon"), (2, "App")],
    "p02-threads-213..218": [  # 216 also takes the crate root, where its deny attribute goes
        (1, f"{TUI_CORE}server*"),
        (1, " ".join(f"{TUI_CORE}{name}*" for name in ("mux", "surface", "resource_router"))),
        (1, " ".join(f"{TUI_CORE}{name}*" for name in ("journal", "chief_brains", "browser", "state",
                                                       "provider_management", "apps"))),
        (1, " ".join(f"{TUI_CORE}{name}" for name in ("lib.rs", "terminal_host_runtime*", "holder_runtime*",
                                                      "terminal_backend*", "shell_integration*"))),
        (1, f"{TUI}cmux-tui/src/*"),
        (1, " ".join(f"{TUI}{crate}/src/*" for crate in SPAWN_CRATES))],
    "p02-threads-141..144": [
        (1, "App"), (1, "AgentPane HomeEngine"), (1, "Control Daemon ComputerUse Wakeups Cloud Design DesignTokens"),
        (1, "*")],
    "p02-threads-047..052": [
        (1, "AgentPane"), (1, "HomeEngine Home"), (1, "App"),
        (1, "Browser BrowserImport BrowserCore BrowserAutomation Design"),
        (1, "Daemon DaemonService Mobile Remote Cloud Settings MacScreen"), (1, "*")],
    "p02-threads-060..101": [
        (1, "AgentPane:Acpmux*.swift AgentPane:AgentChatPullRequestReader.swift"), (3, "AgentPane"),
        (4, "HomeEngine"), (7, "App"), (2, "BrowserImport"), (2, "Updater"), (2, "Browser"), (1, "Design"),
        (1, "Files"), (1, "Daemon"), (1, "Mobile"), (1, "Diff"), (1, "Onboarding"), (1, "Cloud"), (1, "Control"),
        (1, "Settings"), (1, "Phone"), (1, "ChromiumRuntime CLIInstall"), (1, "Pages Home"),
        (1, "BrowserAutomation BrowserCore"), (1, "CrashReporting HangReports ErrorJournal"), (1, "Terminal Remote"),
        (1, "DesignTokens Palette FilesUI Icons FileGrid"),
        (1, "ImportSuggestions ImportCards Bookmarks History Screenshots"),
        (1, "Wakeups Apps MobileHost ComputerUse ServerHelper"),
        (1, "RemoteBrowser HostedChief NowPlaying MacScreen AgentActivity DaemonService"), (1, "*"), (1, "**")],
}
RANGE_ID = re.compile(r"^(?P<prefix>.*-)(?P<first>\d+)\.\.(?P<last>\d+)$")


@dataclass
class TaskUnit:
    """One task of the graph: a plan task, or one id of a plan range (`p02-threads-060..101`)."""
    id: str
    entry: str  # the plan task it came from
    files: dict[str, bool]  # path -> directory-wide (from a directory or a placeholder, not named)
    depends_on: set[str]


@dataclass
class TaskGraph:
    units: dict[str, TaskUnit]
    shared: list[tuple[str, list[str], list[tuple[str, str]]]]  # (file, owners in order, new (task, depends_on))
    waves_before: dict[str, int]
    waves_after: dict[str, int]
    unresolved: list[tuple[str, str, str]]  # (task, entry, note) the tool could not read exactly
    unknown_dependencies: list[tuple[str, str]]  # (task, dependency) not in the task set


def plan_tasks(document, programs: list[str] | None) -> list[dict]:
    """The tasks of a design-result.json ({programs: {name: {tasks}}}), a {tasks: [...]} or a bare list."""
    if "programs" not in document:
        if programs:
            raise ValueError("--program needs a plan with programs (design-result.json)")
        return document if isinstance(document, list) else list(document.get("tasks", []))
    unknown = sorted(set(programs or ()) - set(document["programs"]))
    if unknown:
        raise ValueError(f"no program {', '.join(unknown)} in the plan (it has {', '.join(document['programs'])})")
    return [task for name, program in document["programs"].items()
            if not programs or name in programs for task in program.get("tasks", [])]


def range_ids(task_id: str) -> list[str]:
    match = RANGE_ID.match(task_id)
    if match is None:
        return [task_id]
    width = len(match["first"])
    return [f"{match['prefix']}{n:0{width}d}" for n in range(int(match["first"]), int(match["last"]) + 1)]


def module_name(short: str) -> str:
    return short if short.startswith("CmuxNext") else f"CmuxNext{short}"


def token_matches(token: str, path: str) -> bool:
    """One selector token (see RANGE_PARTS) against a repo path."""
    if "/" in token:
        return fnmatch.fnmatchcase(path, token)
    module = g.module_of(path)
    if not module.startswith("CmuxNext"):
        return False
    if ".." in token:
        first, _, last = token.partition("..")
        short = module[len("CmuxNext"):]
        return first <= short and (short <= last or short.startswith(last))
    name, _, glob = token.partition(":")
    return module == module_name(name) and (not glob or fnmatch.fnmatchcase(path.rsplit("/", 1)[-1], glob))


def selector_matches(selector: str, path: str) -> bool:
    return any(token_matches(token, path) for token in selector.split())


def split_by_weight(files: list[str], weights: dict[str, int], parts: int) -> list[list[str]]:
    """FILES in path order cut into PARTS runs of about equal weight; a file is never split."""
    out: list[list[str]] = [[] for _ in range(parts)]
    total = sum(weights.get(f, 1) for f in files)
    done = 0
    for path in sorted(files):
        out[min(parts - 1, done * parts // total)].append(path)
        done += weights.get(path, 1)
    return out


def split_range(ids: list[str], files: dict[str, int],
                parts: list[tuple[int, str]] | None) -> tuple[list[list[str]], list[str]]:
    """The files (path -> weight) of a range task, one list per id, by PARTS when the plan names them (else in path
    order), and the files no part takes."""
    if parts is None:
        return split_by_weight(list(files), files, len(ids)), []
    if sum(count for count, _ in parts) != len(ids):
        raise ValueError(f"RANGE_PARTS of {ids[0]}..: {sum(c for c, _ in parts)} ids, the plan has {len(ids)}")
    claimed: dict[int, list[str]] = collections.defaultdict(list)
    rest = next((i for i, (_, selector) in enumerate(parts) if selector == "*"), None)
    every = [i for i, (_, selector) in enumerate(parts) if selector == "**"]
    orphans: list[str] = []
    for path in sorted(files):
        owner = next((i for i, (_, selector) in enumerate(parts)
                      if selector not in ("*", "**") and selector_matches(selector, path)), rest)
        if owner is None and not every:
            orphans.append(path)
        for i in ([owner] if owner is not None else []) + every:
            claimed[i].append(path)
    out: list[list[str]] = []
    for i, (count, _) in enumerate(parts):
        out += split_by_weight(claimed[i], files, count) if claimed[i] else [[] for _ in range(count)]
    return out, orphans


def orphan_note(orphans: list[str]) -> str:
    """Names the modules (or, outside Swift modules, the folders) of the files no part of a range takes."""
    places = sorted({g.module_of(p) or p.rsplit("/", 1)[0] + "/" for p in orphans})
    shown = ", ".join(places[:12]) + (f" and {len(places) - 12} more" if len(places) > 12 else "")
    return f"{len(orphans)} files no part of the range names, left without an owner of the range: {shown}"


class Expander:
    """A task's file entries at one revision: files, folders, globs and the placeholders the inventory resolves."""

    def __init__(self, tree: Tree, listing: list[str]):
        self.tree = tree
        self.listing = sorted(listing)
        self.paths = set(listing)
        self.cache: dict[str | Pattern, collections.Counter | None] = {}

    def under(self, folder: str) -> list[str]:
        prefix = folder.rstrip("/") + "/"
        start = bisect.bisect_left(self.listing, prefix)
        return self.listing[start:bisect.bisect_left(self.listing, prefix[:-1] + "0", start)]  # "0" follows "/"

    def hits(self, finder: str | Pattern) -> collections.Counter | None:
        """Hits per file of an inventory rule or a Pattern; None for a rule this inventory does not have."""
        if finder not in self.cache:
            self.cache[finder] = (self.pattern_hits(finder) if isinstance(finder, Pattern) else
                                  collections.Counter(hit.path for _, hit in judge(self.tree, [finder], lambda p: True))
                                  if finder in RULES else None)
        return self.cache[finder]

    def pattern_hits(self, pattern: Pattern) -> collections.Counter:
        regex = re.compile(pattern.regex)
        found: collections.Counter = collections.Counter()
        for path, text in self.tree.sources.items():
            if any(fnmatch.fnmatchcase(path, glob) for glob in pattern.exclude) or not regex.search(text):
                continue
            found[path] = sum(1 for line in text.split("\n") if regex.search(g.code_of(line)))
        return +found  # a match only in a comment or a string is no hit

    def entry(self, entry: str, finders: list[str | Pattern]) -> tuple[dict[str, tuple[bool, int]], str | None]:
        """({path: (directory-wide, weight)}, note) for one entry of a task's file list. The note says what the tool
        could not read exactly: a placeholder no rule resolves takes its whole folder; prose or a branch, nothing.
        Besides its first word, every path of the listing the entry's prose names counts (`A/ and B/ packages`)."""
        token, _, note = entry.strip().partition(" ")
        note = note.strip()
        files: dict[str, tuple[bool, int]] = {}
        whole: list[str] = []
        for word in [token, *(w for w in self.paths_in(note) if w != token)]:
            expanded, wide = self.word(word, note, finders)
            files.update(expanded)
            if wide:
                whole.append(word)
        if whole:
            return files, f"no rule for the placeholder: the whole folder of {', '.join(whole)}"
        return files, None if files else "no path"

    def paths_in(self, prose: str) -> list[str]:
        """The words of PROSE that are a file or a folder of the listing."""
        words = (w.strip("()[],;:`'\"") for w in prose.split())
        return list(dict.fromkeys(w for w in words if "/" in w and (w in self.paths or self.under(w))))

    def word(self, word: str, note: str, finders: list[str | Pattern]) -> tuple[dict[str, tuple[bool, int]], bool]:
        """The files of one path word of an entry, and whether it took its whole folder for want of a rule."""
        if "<" in word or (note and (word.endswith("/") or self.under(word)) and word not in self.paths):
            folder = word.split("<", 1)[0]
            found = self.placeholder(folder, finders)
            if found is not None:
                return found, False
            return {p: (True, 1) for p in self.under(folder)}, True
        return self.literal(word, note), False

    def literal(self, token: str, note: str) -> dict[str, tuple[bool, int]]:
        if "{" in token:
            head, _, rest = token.partition("{")
            names, _, tail = rest.partition("}")
            out: dict[str, tuple[bool, int]] = {}
            for name in names.split(","):
                out.update(self.literal(head + name + tail, note))
            return out
        if any(c in token for c in "*?["):
            return {p: (False, 1) for p in self.listing if fnmatch.fnmatchcase(p, token)}
        if token in self.paths:
            return {token: (False, 1)}
        if token.endswith("/") or self.under(token):
            return {p: (True, 1) for p in self.under(token)} or {token: (True, 1)}
        if "/" in token and note in ("", "(new)"):
            return {token: (False, 1)}  # a file the task creates
        return {}

    def placeholder(self, folder: str, finders: list[str | Pattern]) -> dict[str, tuple[bool, int]] | None:
        """The files under FOLDER with hits of FINDERS (weight: the hits), or None when one has no rule here."""
        counts = [self.hits(finder) for finder in finders]
        if not counts or any(c is None for c in counts):
            return None
        total: collections.Counter = sum(counts, collections.Counter())
        return {p: (False, n) for p, n in total.items() if p.startswith(folder)}


def task_finders(task: dict) -> list[str | Pattern]:
    if task["id"] in TASK_HITS:
        return [TASK_HITS[task["id"]]]
    queues = re.findall(r"MQ-\d+", task.get("machine_queue") or "")
    return [QUEUE_RULES.get(q, q) for q in queues]


def expand_tasks(tasks: list[dict], expander: Expander) -> tuple[dict[str, TaskUnit], list[tuple[str, str, str]]]:
    """One unit per task id (each id of a range is a module sweep, so directory-wide), and the entries the expander
    could not read exactly as (task, entry, note)."""
    units: dict[str, TaskUnit] = {}
    unresolved: list[tuple[str, str, str]] = []
    aliases = {task["id"]: range_ids(task["id"]) for task in tasks}
    for task in tasks:
        finders = task_finders(task)
        files: dict[str, tuple[bool, int]] = {}
        for entry in task.get("files", []):
            expanded, note = expander.entry(entry, finders)
            files.update(expanded)
            if note:
                unresolved.append((task["id"], entry, note))
        deps = {d for dep in task.get("depends_on") or [] for d in aliases.get(dep, [dep])}
        ids = aliases[task["id"]]
        if len(ids) == 1:
            units[task["id"]] = TaskUnit(task["id"], task["id"], {p: wide for p, (wide, _) in files.items()}, deps)
            continue
        weights = {p: weight for p, (_, weight) in files.items()}
        parts = RANGE_PARTS.get(task["id"])
        split, orphans = split_range(ids, weights, parts)
        if parts is None and files:
            unresolved.append((task["id"], "(range)", "no RANGE_PARTS row: its files split in path order"))
        if orphans:
            unresolved.append((task["id"], "(range)", orphan_note(orphans)))
        for unit_id, paths in zip(ids, split):
            units[unit_id] = TaskUnit(unit_id, task["id"], dict.fromkeys(paths, True), set(deps))
    return units, unresolved


def depends_on_all(deps: dict[str, set[str]], task: str) -> set[str]:
    """Every task TASK waits for, directly or through others."""
    seen: set[str] = set()
    stack = [task]
    while stack:
        for dep in deps.get(stack.pop(), ()):
            if dep not in seen:
                seen.add(dep)
                stack.append(dep)
    return seen


def waves(deps: dict[str, set[str]]) -> dict[str, int]:
    """Each task's dependency level: 0 without dependencies, else one more than its latest dependency."""
    waiting = {task: set(ds) for task, ds in deps.items()}
    dependents: dict[str, list[str]] = collections.defaultdict(list)
    for task, ds in deps.items():
        for dep in ds:
            dependents[dep].append(task)
    ready = [task for task, ds in waiting.items() if not ds]
    level = dict.fromkeys(ready, 0)
    while ready:
        done = ready.pop()
        for task in dependents[done]:
            waiting[task].discard(done)
            if not waiting[task]:
                level[task] = 1 + max(level[d] for d in deps[task])
                ready.append(task)
    if len(level) < len(deps):
        raise ValueError(f"depends_on cycle among {', '.join(sorted(t for t in deps if t not in level))}")
    return level


def shared_per_wave(units: dict[str, TaskUnit], level: dict[str, int]) -> int:
    """(wave, file) pairs with more than one owner."""
    owners = collections.Counter((level[u.id], path) for u in units.values() for path in u.files)
    return sum(1 for n in owners.values() if n > 1)


def owner_order(members: list[str], directory_wide: dict[str, bool], deps: dict[str, set[str]]) -> list[str]:
    """MEMBERS in the order they take a file: by task id, directory-wide tasks after those that name the file, and
    never before a task they already wait for."""
    waits = {m: depends_on_all(deps, m) & set(members) for m in members}
    order: list[str] = []
    while len(order) < len(members):
        ready = [m for m in members if m not in order and waits[m] <= set(order)]
        order.append(min(ready, key=lambda m: (directory_wide[m], m)))
    return order


def task_graph(units: dict[str, TaskUnit], unresolved: list[tuple[str, str, str]]) -> TaskGraph:
    """Order the owners of each shared file (owner_order) with depends_on edges, so every file has one owner per
    wave. The edges follow an order the graph already allows, so they never close a cycle."""
    unknown = sorted((u.id, d) for u in units.values() for d in u.depends_on if d not in units)
    deps = {u.id: {d for d in u.depends_on if d in units} for u in units.values()}
    before = waves(deps)
    owners: dict[str, list[str]] = collections.defaultdict(list)
    for unit in units.values():
        for path in unit.files:
            owners[path].append(unit.id)
    shared = []
    for path in sorted(p for p, members in owners.items() if len(members) > 1):
        members = sorted(owners[path])
        order = owner_order(members, {m: units[m].files[path] for m in members}, deps)
        added = []
        for earlier, later in zip(order, order[1:]):
            if earlier not in depends_on_all(deps, later):
                deps[later].add(earlier)
                added.append((later, earlier))
        shared.append((path, order, added))
    for unit in units.values():
        unit.depends_on = deps[unit.id] | {d for d in unit.depends_on if d not in units}
    return TaskGraph(units, shared, before, waves(deps), unresolved, unknown)


def build_task_graph(tree: Tree, listing: list[str], document, programs: list[str] | None = None) -> TaskGraph:
    units, unresolved = expand_tasks(plan_tasks(document, programs), Expander(tree, listing))
    return task_graph(units, unresolved)


def print_task_graph(graph: TaskGraph, jsonl: bool) -> None:
    before = shared_per_wave(graph.units, graph.waves_before)
    after = shared_per_wave(graph.units, graph.waves_after)
    edges = [edge for _, _, added in graph.shared for edge in added]
    if jsonl:
        for path, order, added in graph.shared:
            print(json.dumps({"file": path, "tasks": order,
                              "resolution": {"depends_on": [list(edge) for edge in added]}}))
        print(json.dumps({"summary": {
            "tasks": len(graph.units), "files": len({p for u in graph.units.values() for p in u.files}),
            "shared_files": len(graph.shared), "new_edges": len(edges),
            "shared_per_wave": {"before": before, "after": after},
            "waves": dict(sorted(graph.waves_after.items())),
            "unresolved": [{"task": t, "entry": e, "note": n} for t, e, n in graph.unresolved],
            "unknown_dependencies": [{"task": t, "depends_on": d} for t, d in graph.unknown_dependencies]}}))
        return
    for path, order, added in graph.shared:
        resolution = ", ".join(f"{later} after {earlier}" for later, earlier in added) or "already ordered"
        print(f"{path}: {' '.join(order)} ({resolution})")
    print(f"== {len(graph.units)} tasks, {len(graph.shared)} shared files, {len(edges)} new depends_on edges; "
          f"shared files per wave: {before} before, {after} after")
    for wave in sorted(set(graph.waves_after.values())):
        print(f"wave {wave}: {' '.join(sorted(t for t, w in graph.waves_after.items() if w == wave))}")
    for task, entry, note in graph.unresolved:
        print(f"unresolved {task}: {entry} ({note})")
    for task, dep in graph.unknown_dependencies:
        print(f"unknown dependency {task}: {dep}")


# ---------------------------------------------------------------- output


def describe(hit: Hit) -> str:
    where = [hit.enclosing_func or "type level", hit.isolation]
    if hit.is_async is not None:
        where.append("async" if hit.is_async else "sync")
    if hit.caller_count is not None:
        where.append(f"callers {hit.caller_count}")
    return f"{hit.path}:{hit.line}: [{hit.rule}] {hit.text}  ({', '.join(where)})"


def parse_args(argv: list[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0],
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--rule", action="append", default=None,
                        help=f"a rule to report (repeat or comma-separate; default all): {', '.join(RULES)}")
    parser.add_argument("--paths", nargs="+", action="extend", default=None,
                        help="repo-relative files, folders or globs to judge (default: all of Sources and the linked packages' Sources)")
    parser.add_argument("--count", action="store_true", help="print the hits per rule (and per group with --group)")
    parser.add_argument("--group", choices=("module", "root"), help="chunk the hits by module or call-graph root")
    parser.add_argument("--max-hits", type=int, default=None, help="hits per chunk with --group (default 25)")
    parser.add_argument("--jsonl", action="store_true", help="one JSON object per hit (or the counts as JSON)")
    parser.add_argument("--rev", default="HEAD", help="the revision to judge (default HEAD)")
    parser.add_argument("--repo", type=Path, default=None, help="the checkout (default: the one holding the cwd)")
    parser.add_argument("--task-graph", type=Path, default=None, metavar="TASKS.json",
                        help="expand the plan's task file lists at REV and print the depends_on edges that leave one "
                             "owner per file per wave (design-result.json, {tasks: [...]} or a list)")
    parser.add_argument("--program", action="append", default=None,
                        help="with --task-graph: only this design-result.json program (repeat; default all)")
    args = parser.parse_args(argv)
    if args.task_graph is not None and (args.rule or args.paths or args.count or args.group):
        parser.error("--task-graph takes no --rule, --paths, --count or --group")
    if args.program and args.task_graph is None:
        parser.error("--program needs --task-graph")
    rules = [r.strip() for value in (args.rule or []) for r in value.split(",") if r.strip()]
    unknown = [r for r in rules if r not in RULES]
    if unknown:
        parser.error(f"unknown rule {', '.join(unknown)}; known: {', '.join(RULES)}")
    args.rules = rules or list(RULES)
    if args.max_hits is not None and args.group is None:
        parser.error("--max-hits needs --group")
    if args.max_hits is not None and args.max_hits < 1:
        parser.error("--max-hits must be at least 1")
    args.max_hits = args.max_hits or 25
    return args


def repo_root(repo: Path | None) -> Path:
    if repo is not None:
        return repo.resolve()
    result = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True)
    return Path(result.stdout.strip()) if result.returncode == 0 else HERE.parents[1]


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    repo = repo_root(args.repo)
    tree = read_tree(repo, args.rev)
    if args.task_graph is not None:
        listing = g.git(repo, "ls-tree", "-r", "--name-only", args.rev).split("\n")
        try:
            graph = build_task_graph(tree, [p for p in listing if p], json.loads(args.task_graph.read_text()),
                                     args.program)
        except (OSError, ValueError, RuntimeError) as error:  # unreadable plan, depends_on cycle, RANGE_PARTS mismatch
            print(f"threading-inventory: {error}", file=sys.stderr)
            return 2
        print_task_graph(graph, args.jsonl)
        return 0
    try:
        hits = inventory(tree, args.rules, path_matcher(args.paths))
    except RuntimeError as error:  # thread-doc without the threading doc at REV
        print(f"threading-inventory: {error}", file=sys.stderr)
        return 2
    groups: list[tuple[str, list[Hit]]] = []
    if args.group == "module":
        groups = group_by_module(hits, args.max_hits)
    elif args.group == "root":
        groups = group_by_root(tree, hits, args.max_hits)
    for label, chunk in groups:
        for hit in chunk:
            hit.group = label
    if args.count:
        totals = collections.Counter((section_of(h.path), h.rule) for h in hits)
        counts = {rule: totals[("sources", rule)] for rule in args.rules}
        linked = {rule: totals[("linked", rule)] for rule in args.rules} if tree.packages else {}
        if args.jsonl:
            print(json.dumps({"rules": counts, **({"linked": linked} if linked else {}),
                              **({"groups": {label: len(c) for label, c in groups}} if groups else {})}))
        else:
            for rule, n in counts.items():
                print(f"{rule} {n}")
            for rule, n in linked.items():
                print(f"linked:{rule} {n}")
            for label, chunk in groups:
                print(f"{label} {len(chunk)}")
        return 0
    if args.jsonl:
        ordered = [h for _, chunk in groups for h in chunk] if groups else hits
        for hit in ordered:
            print(json.dumps(hit.record()))
        return 0
    if groups:
        for label, chunk in groups:
            print(f"== {label} ({len(chunk)} hits)")
            for hit in chunk:
                print(describe(hit))
        return 0
    for hit in hits:
        print(describe(hit))
    return 0


if __name__ == "__main__":
    sys.exit(main())
