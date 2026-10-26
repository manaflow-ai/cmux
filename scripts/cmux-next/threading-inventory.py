#!/usr/bin/env python3
"""Whole-tree threading inventory: every line of a revision judged by the pre-push threading rules.

guardrails.py judges only what a push adds. This tool imports it (its rules unchanged) and judges every Swift line
under Packages/macOS/CmuxNext/Sources at REV as a push from the empty tree (4b825dc6) would add it, so the
p02-threads machine queues (plans/cmux-next/chrome-parity/p02-threads.md section 6) come from the same definitions
the hook refuses. The rules model Chromium's blocking discipline: base/threading/scoped_blocking_call.h (a blocking
call is marked and may not run on the UI thread) and base/threading/thread_restrictions.h (the reviewed allow list).

Rules: main-blocking, raw-blocking, pool-blocking, maybe-main-blocking, task-priority, thread-doc, and the inventory's
own cpu-intensive (p02-threads-121: a raw JSON, property list, image, compression or regex call whose isolation, as
the hit reports it, is main, instead of its size-gated seam; MQ-18). The hook gives a raw primitive that surely runs
on main to main-blocking only (one refusal per line); the inventory lists each line under every rule it breaks, so
raw-blocking here also holds the raw primitives main-blocking took (each still needs its seam), and a raw primitive
on a pool thread is both raw-blocking and pool-blocking (MQ-3 counts the latter).

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

Reads git objects only (ls-tree, cat-file): no network, no file in the repo or beside the scripts, not even bytecode
caches. git_batch hands git its request through an unnamed temporary file in TMPDIR (a pipe hangs on some hosts),
which is gone when the read returns. Not a CI gate (Lawrence 2026-10-23); run it yourself.
"""
from __future__ import annotations

import sys

sys.dont_write_bytecode = True  # importing guardrails and its siblings must not write __pycache__

import argparse
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


def raw_blocking(changes: list, moved: collections.Counter) -> list:
    """guardrails' raw-blocking hits plus the raw primitives its main-blocking rule took (they still need a seam)."""
    hits = g.raw_blocking(changes, moved)
    for hit in g.blocking_on_main(changes, moved):
        code = g.code_of(hit.text)
        if g.blocking_match(g.RAW_SCAN, code) and not g.ALWAYS_SCAN.search(code):
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
    in_main_actor = [c for c in g.outside_seams(changes) if g.module_of(c.path) in targets]

    def judge(version, index: int, code: str) -> bool:
        match = CPU_INTENSIVE_SCAN.search(code)
        if match is None or index >= len(version.lines):
            return False
        return context_of(version.lines, index, code[:match.start()], True).isolation == "main"
    return g.changed_debt(in_main_actor, judge)


# The inventory's rules, in report order. Later p02-threads tasks add theirs here.
RULES: dict[str, Callable[[list, collections.Counter], list]] = {
    "main-blocking": guardrails_rule("main-blocking"),
    "raw-blocking": raw_blocking,
    "pool-blocking": guardrails_rule("pool-blocking"),
    "maybe-main-blocking": guardrails_rule("maybe-main-blocking"),
    "task-priority": guardrails_rule("task-priority"),
    "thread-doc": guardrails_rule("thread-doc"),
    "cpu-intensive": cpu_intensive,
}

# Where on the hit line the judged call starts: braces before it enclose the call, braces after it are its own.
LOCATORS = {
    "task-priority": g.TASK_CALL,
    "thread-doc": g.THREAD_SCAN.pattern,
    "cpu-intensive": CPU_INTENSIVE,
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
    """The Swift sources of one revision ({path: text}) and the files the rules read beside them."""
    sources: dict[str, str]
    threading_doc: str | None = None
    manifest: str | None = None


def read_tree(repo: Path, rev: str) -> Tree:
    listing = g.git(repo, "ls-tree", "-r", "--name-only", rev, "--", g.SOURCES)
    paths = [p for p in listing.split("\n") if p.endswith(".swift")]
    texts = g.blobs(repo, [(rev, p) for p in paths] + [(rev, g.THREADING_DOC), (rev, g.PACKAGE_MANIFEST)])
    return Tree({p: texts[(rev, p)] for p in paths if (rev, p) in texts},
                texts.get((rev, g.THREADING_DOC)), texts.get((rev, g.PACKAGE_MANIFEST)))


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


def judge(tree: Tree, rules: Iterable[str], paths: Callable[[str], bool]) -> list[tuple[str, object]]:
    """[(rule, guardrails hit)] over the matching files, each rule judging every line against the empty tree."""
    texts: dict[tuple[str, str], str] = {}
    rev = "inventory"
    if tree.threading_doc is not None:
        texts[(rev, g.THREADING_DOC)] = tree.threading_doc
    if tree.manifest is not None:
        texts[(rev, g.PACKAGE_MANIFEST)] = tree.manifest
    g.load_blocking_context(texts, rev)
    targets = g.swift_scope.package_targets(tree.manifest or "")
    changes = []
    for path in sorted(tree.sources):
        if not paths(path):
            continue
        change = file_change(path, tree.sources[path])
        change.head_main = change.base_main = g.main_by_default(path, targets)
        changes.append(change)
    found = []
    for rule_id in rules:
        rule = RULE_BY_ID.get(rule_id)
        scope = rule.scope if rule is not None else (g.SOURCES,)
        scoped = [c for c in changes if c.path.startswith(scope)]
        found += [(rule_id, hit) for hit in RULES[rule_id](scoped, collections.Counter())]
    return found


def scope_key(scope: str, path: str) -> Scope:
    return (scope, path if scope == "file" else g.module_of(path) if scope == "module" else "")


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
    """{callee: its call sites in its scope}. A call site is `name(` or `name {` in code (comments and string
    contents dropped), not `func name(` or an enum case pattern, whose labels and receiver fit the callee."""
    counts: dict[Callee, int] = collections.Counter()
    by_name: dict[str, list[Callee]] = collections.defaultdict(list)
    for callee in set(callees):
        by_name[callee.name].append(callee)
        if callee.kind == "init":
            by_name["init"].append(callee)
    if not by_name:
        return counts
    for path, text in tree.sources.items():
        here = {("file", path), ("module", g.module_of(path)), ("tree", "")}
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
                        counts[callee] += 1
    return counts


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
        module = g.module_of(hit.path)
        ctx = context_of(lines, index, prefix, module in targets)
        owner = ctx.types[0] if ctx.types else None
        callee = None
        if ctx.func_name:
            callee = Callee(ctx.func_name, ctx.func_kind, owner, ctx.func_static and ctx.func_kind == "func",
                            parameters(*ctx.func_header) if ctx.func_header else None,
                            scope_key(call_scope(ctx), hit.path),
                            bool(ctx.func_header) and returns_own_type(ctx.func_header[0], owner))
        hits.append(Hit(rule_id, hit.path, hit.number, module, module in targets, lines[index].strip(),
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
                        help="repo-relative files, folders or globs to judge (default: all of Sources)")
    parser.add_argument("--count", action="store_true", help="print the hits per rule (and per group with --group)")
    parser.add_argument("--group", choices=("module", "root"), help="chunk the hits by module or call-graph root")
    parser.add_argument("--max-hits", type=int, default=None, help="hits per chunk with --group (default 25)")
    parser.add_argument("--jsonl", action="store_true", help="one JSON object per hit (or the counts as JSON)")
    parser.add_argument("--rev", default="HEAD", help="the revision to judge (default HEAD)")
    parser.add_argument("--repo", type=Path, default=None, help="the checkout (default: the one holding the cwd)")
    args = parser.parse_args(argv)
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
    tree = read_tree(repo_root(args.repo), args.rev)
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
        totals = collections.Counter(h.rule for h in hits)
        counts = {rule: totals[rule] for rule in args.rules}
        if args.jsonl:
            print(json.dumps({"rules": counts, **({"groups": {label: len(c) for label, c in groups}} if groups else {})}))
        else:
            for rule, n in counts.items():
                print(f"{rule} {n}")
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
