#!/usr/bin/env python3
"""Crash-class ratchet for cmux-next (plans/cmux-next/crash-elimination.md).

Counts the code patterns that can end the app or the daemon, per class and
per Swift module or Rust crate (so code can move between files), and compares
them with crash-safety-baseline.json next to this script. A module or crate
may never gain a hit of a class; fixing hits is free (run
--update-baseline to lower the baseline in the same commit). A hit on a line with
a reviewed `// crash-allow: <reason>` (Swift) or `// crash-allow: <reason>`
(Rust), on the line or the comment line above, is a waived hit: it is counted
apart, per class and module, in the baseline's "waived" section, and a module may
never gain a waived hit either (`swift <module>: <class>.waived N -> M`). So a
waiver is a counted, reviewed baseline change in the diff: a waiver added while
code moves to another module (B1, ba5e6df99f9) shows as the old module's count
going down and the new module's waived count going up, not as a reduction.

The baseline only goes down. --update-baseline lowers every row to the tree's
count and never raises one: a row the tree is over stays where it is, is printed,
and the run exits 1 (so recording your own fix or waiver never records another
change's regression). Two raises are allowed, each on purpose:
  --record-waivers  also raises the waived rows to the tree's count (a new reviewed
                    crash-allow); counted rows still only go down.
  --base REF        a hit that moved to another module carries its row: a row may
                    rise by the hits whose exact line left another module since
                    REF (proven by scanning REF's tree), as far as that module's
                    row in REF's baseline covers them; the old row goes down by as
                    much. A hit REF was already red on never moves into a row.
--baseline-against BASE_TREE judges a change's baseline against the base's (the CI
job and safe-push run it): a counted row above the base's row (after proven moves)
fails, a waived row above it is printed as a recorded waiver.

  Swift (Packages/macOS/CmuxNext/Sources and the Sources of every package in its
  `.package(path:)` closure, so code the app links is in scope, except third-party
  packages under vendor/; a module is keyed by its directory under Sources):
    force_unwrap      `x!` (a nil value traps)
    as_bang           `as!` (a failed cast traps)
    fatal_error       fatalError( outside a required init(coder:) or init(rootView:)
    precondition      precondition( / preconditionFailure( (trap in Release too)
    assume_isolated   MainActor.assumeIsolated (traps off the main actor); a hit with a
                      `// main-proof: <why the caller is on main>` comment does not count
    unowned           unowned references (trap after the owner is gone)
    iuo               implicitly unwrapped declarations (`var x: T!`)
    unchecked         nonisolated(unsafe) and @unchecked Sendable (data races)
    objc_selector     a non-override @objc func with a labeled parameter and no explicit
                      @objc(selector:) (Swift infers `mouseEnteredWith:` for
                      `mouseEntered(with:)`, and AppKit raised "unrecognized selector")
    render_font       in the background-render modules (RENDER_MODULES): an AppKit or Core
                      Text font made in place (NSFont/UIFont factories, NSFont(name:/descriptor:),
                      CTFontCreate*) outside a `static let`. Factories annotated nonnull return
                      nil when threads make and drop the last instance at once (cx-qpqs); fonts
                      come from a process-wide cache (HomeFonts) instead
    index_subscript   in the background, render and decoder modules (INDEX_MODULES): a
                      subscript with a computed index (`rows[i]`, `bytes[n - 1]`, a range), not
                      followed by `?`/`??` and not an optional binding; an out-of-range index
                      traps. Use a checked accessor (`rows[checked: i]` does not count).
                      A dictionary subscript cannot trap: a subscript on a name the module
                      declares as a dictionary (`var m: [K: V]`, `= [K: V]()`, `Dictionary<`)
                      and never otherwise (the file's own declarations decide when it has
                      any; else the module's), or with a `default:` argument, does not count.
                      Also a dictionary: `= Dictionary(...)`, `.reduce(into: [:])`,
                      `.reduce(into: [K: V]())`, `.mapValues`, `Dictionary(grouping:...)`.
                      An assignment through a subscript (`x[k] = v`, `x[k] = nil`) counts only
                      when the name is known to be indexable (an array type or literal,
                      `Data()`, `Array(...)`, `ContiguousArray`): one whose type is inferred
                      from another value (`var applied = memo.applied`) may be a dictionary,
                      where it cannot trap. A read (`x[i]` used as a value) still counts
    int_conversion    in INDEX_MODULES: `Int(x)`, `UInt8(x)`, ... that trap when the value does
                      not fit; use `exactly:` (optional), `clamping:` or `truncatingIfNeeded:`.
                      `UInt8(ascii:)`, a pure integer literal (`UInt8(0)`, checked by the
                      compiler) and a string parse with `radix:` (`Int(text, radix: 10)`
                      returns nil instead of trapping) do not count
    objc_observer     a selector-based NotificationCenter registration `addObserver(<target>, selector:`
                      (the call may span lines). The target method is @objc; when it is also
                      @MainActor, a post off the main thread traps in Swift's dynamic isolation
                      check (PointerHover's KeyWindowObserver trapped CmuxNextAppTests on a
                      willClose posted from a detached thread). Use the block form with
                      `queue: .main` and keep the token
    async_closure_default_arg  a parameter whose default value is an async closure literal
                      (`sleep: @Sendable (Duration) async throws -> Void = { ... }`). Swift 6.3.3
                      emits the default in every calling module under one weak symbol with
                      different async context sizes; the linker can pair a small context with a
                      large body: a heap overrun abort (cx-bsue). Use a named static function
                      or an overload without the parameter
    dynamic_dispatch  NSSelectorFromString, Selector("..."), KVC value/setValue by key
                      (an unknown selector or key raises an Objective-C exception)
    env_write         setenv( / unsetenv( / putenv( / an assignment to environ. Not in
                      the baseline and not waived by crash-allow: only the call sites in
                      env-write-allowlist.json (path, call, count, reason) pass. libghostty
                      keeps a slice of environ from ghostty_init, so a write after launch
                      left it reading a NULL or freed entry (SIGSEGV, cx-9dh7). Children
                      get their variables through their spawn environment. At run time,
                      ProcessEnvironmentGuard.write refuses an allowed write after its freeze.
  Rust (cmux-tui/crates/*/src, code before an inline #[cfg(test)] module, no tests/ folders):
    unwrap            .unwrap()
    expect            .expect(
    panic_macro       panic!, unreachable!, todo!, unimplemented!
    exit              process::exit / process::abort

BAN mode (crash-allowlist.json next to this script): a class named in "banned"
("swift.<class>", or "swift.<class>@<Module>" for one module; Rust classes are not bannable yet) is not in the baseline. Every hit fails, an inline
crash-allow does not waive it; only an "allow" entry {path, class, count, reason,
reviewer} passes that many hits in that file. Flip a class to banned in the commit
that brings it to zero (moving its reviewed crash-allow lines into the allowlist).

REPORT-ONLY classes (--report CLASS[,CLASS]; plans/cmux-next/chrome-parity/p10-stability.md, implementer rule 1):
counted over every package's Sources and printed as JSON {class: {"total": N, "modules": {module: hits}}}, never
compared, never in crash-safety-baseline.json, and never read by the CI compare mode (no flag, --baseline-against,
--update-baseline). A crash-allow does not hide a hit from the report. guardrails.py judges them before a push
(local only): raw_continuation is banned there, every hit in a file the push changes is refused (p10-stability-089).
    raw_continuation  with(Checked|Unsafe)(Throwing)?Continuation: a raw continuation traps on a second resume
                      and leaks its task when dropped. Use CmuxSafeConcurrency's withOnceContinuation /
                      withOnceThrowingContinuation (p10-stability-083); CmuxSafeConcurrency itself, which
                      implements them, is not counted
    trap_api          standard-library calls that trap on a bad argument (queue Q09, p10-stability-092):
                      `uniqueKeysWithValues:` (a duplicate key), `removeFirst()` / `removeLast()` and their
                      `(n)` forms (an empty or short collection) with no guard, `Array/ContiguousArray/String/
                      Data(repeating:count:)` and `repeatElement(_:count:)` (a negative count) unless the count
                      is literal arithmetic without a minus (`64 * 1024`), a `.count`, `max(0, n)` or `max(n, 0)`
                      (any non-negative literal), `K - x.count % K` (base64 padding, also `(...) % 4`), an
                      imported C buffer size (`Int(clamping: INET6_ADDRSTRLEN)`, C_SIZE_CONSTANTS), a ternary of
                      two of these, or one name shown non-negative in its scope before the call: a conjunct
                      `n >= 0` / `n > 0` of a `guard` above, of an `if` whose block or a ternary whose true
                      branch holds the call, or its nearest `let` / `var` / assignment with a safe whole value
                      (`let n = max(1, capacity)`), with no function boundary or reassignment in between, and
                      `index(_:offsetBy:)` / `formIndex(_:offsetBy:)` without `limitedBy:` (past the end). A
                      removal is guarded when its receiver's `isEmpty`, `count`, `first`, `last`, `hasPrefix`,
                      `hasSuffix` or `starts` is read on the same line before it, on one of the 3 lines above
                      (`guard !queue.isEmpty`, `while let x = queue.first`, `if s.hasPrefix("-") { s.removeFirst() }`)
                      or in a `guard ... else { ... }` that ends on the line above it (a long else block);
                      `popFirst()` / `popLast()` never count
    invariant_check   Invariant.check( (CmuxSafeConcurrency, p10-stability-099): traps in every build
    dump_will_be_check  Invariant.dumpWillBeCheck( (p10-stability-099): reports and never traps.
                      Invariant.notFatalUntil is not a class: it traps from its named build on.
                      guardrails.py's invariant-site rule (local only) refuses a site in a file the push
                      changes unless invariant-allowlist.json (read by nothing in CI) has an entry for its
                      file and class: for check, a reason that says what shared or persisted state going on
                      would corrupt; for dumpWillBeCheck, one that names the code that recovers
  The ratchet classes index_subscript and int_conversion are also report classes: by default over INDEX_MODULES
  (the CI rows, counted and waived together), with --all-modules over every module of every package.

REPORT BASELINE (crash-safety-report-baseline.json next to this script): the report classes' rows,
{class: {"scope": ..., "modules": {module: hits}}}. Only --report reads it: a class with a row in the scope
reported gains "baseline" (its total) and "over" ({module: {"baseline": b, "now": n}}) in the JSON, still exit 0.
--report CLASS --update-report-baseline writes the classes' rows: a class's first row records the tree, after that
a row only goes down; a row the tree is over stays, is printed, and the run exits 1. index_subscript and
int_conversion rows are recorded only with --all-modules (their INDEX_MODULES rows are crash-safety-baseline.json's).
The CI compare (no flag, --baseline-against, --update-baseline) never reads this file.

CLASSIFY (--classify, Q21 of plans/cmux-next/chrome-parity/p10-stability.md, task p10-stability-205): every hit of
--report's classes (without --report: every counted, waived and banned hit of the ratchet's scan) gets exactly one
trap class, printed as JSON with the rule that gave it; it compares nothing. `input`: the operand can come from outside
the process (a Q14 decode entry point, its callees, peer or file bytes), so the fix is validation that returns a typed
error to a boundary. `invariant`: an internal invariant, which goes to the Invariant API (Swift) or an
`INVARIANT:` expect (Rust). TrapClassifier.classify holds the rules, in order; trap-classes.json holds their data.
rust_panic_ratchet.py --classify classes clippy's hits with the same classifier.

notFatalUntil builds only go up (Invariant.notFatalUntil(cond, id, build: N), task p10-stability-099):
lowered_not_fatal_until() refuses a lowered or removed N without a `// not-fatal-until-lowered-allow: <reason>`.
It is a local-only rule: guardrails.py's `not-fatal-until-lowered` runs it on what a push changes; CI never does.

Usage: crash_ratchet.py [--repo ROOT] [--exported-tree]
                        [--update-baseline [--record-waivers] [--base REF] | --baseline-against BASE_TREE]
       crash_ratchet.py [--repo ROOT] [--exported-tree] --report CLASS[,CLASS] [--all-modules]
                        [--update-report-baseline | --classify]
       crash_ratchet.py [--repo ROOT] [--exported-tree] --classify
Exit 1 when a module or crate gained a hit or a waived hit; with --update-baseline, when
a row stays above the baseline; with --baseline-against, when a counted row rose; with --classify, when a
`// trap-class:` mark names no class or no reason.
"""
import argparse
import bisect
import difflib
import fnmatch
import subprocess
import json
import os
import re
import sys
import tempfile
from typing import NamedTuple

HERE = os.path.dirname(os.path.abspath(__file__))
BASELINE = os.path.join(HERE, "crash-safety-baseline.json")
# Report-only rows (--report); never read by the CI compare.
REPORT_BASELINE = os.path.join(HERE, "crash-safety-report-baseline.json")
# The baseline's section of waived hits ({lang: {class: {module: hits}}}), beside the counted ones.
WAIVED = "waived"
# The section of a baseline row (section, lang, class, module) that is not waived.
COUNTED = "counted"
# What a tree export needs for a scan (the swift package closure, the crates, this folder).
TREE_PATHS = ("Packages", "cmux-tui/crates", "scripts/cmux-next")
ALLOW = re.compile(r"//\s*crash-allow:\s*\S")

SWIFT = {
    "force_unwrap": re.compile(r"(?<![!=<>])[\w\)\]]!(?!=)(?=[\s\.\),\]\[;:]|$)"),
    "as_bang": re.compile(r"\bas!\s"),
    "fatal_error": re.compile(r"\bfatalError\("),
    "precondition": re.compile(r"\bprecondition(Failure)?\("),
    "assume_isolated": re.compile(r"\bassumeIsolated\b"),
    # Not an enum case or member named `unowned` (`case unowned = 0`, `.unowned`).
    "unowned": re.compile(r"(?<!\.)(?<!case )\bunowned\b"),
    # Declarations, parameters (`navigation: WKNavigation!`) and return types.
    "iuo": re.compile(r"(?:\b(?:var|let)\s+\w+|[(,]\s*(?:\w+\s+)?\w+)\s*:\s*[A-Z][\w\.]*(?:<[^>]*>)?!"
                      r"|->\s*[A-Z][\w\.]*(?:<[^>]*>)?!"),
    "unchecked": re.compile(r"nonisolated\(unsafe\)|@unchecked\s+Sendable"),
    "dynamic_dispatch": re.compile(
        r"\bNSSelectorFromString\(|\bSelector\(\"|\b(?:setValue|value)\((?:[^()]|\([^()]*\))*\bforKey(?:Path)?:"),
}
# Report-only classes (--report): counted for the report, never in the baseline or the CI compare. Each class's
# scope is every package's Sources less REPORT_OWNERS[class], the package that implements its safe replacement.
REPORT_SWIFT = {
    "raw_continuation": re.compile(r"\bwith(?:Checked|Unsafe)(?:Throwing)?Continuation\b"),
    "invariant_check": re.compile(r"\bInvariant\.check\("),
    "dump_will_be_check": re.compile(r"\bInvariant\.dumpWillBeCheck\("),
}
REPORT_OWNERS = {
    "raw_continuation": ("Packages/Shared/CmuxSafeConcurrency/",),
}
ASYNC_DEFAULT = re.compile(
    r"\w+\s*:\s*(?:@\w+(?:\([^)]*\))?\s+)*\((?:[^()]|\([^()]*\))*\)\s*async\b[^=]*?=\s*\{")
STORED_DECL = re.compile(r"\b(?:var|let)\s+\w+\s*:")
# Counted by objc_selector_hits (needs the declaration, which may span two lines).
SWIFT_KINDS = list(SWIFT) + ["async_closure_default_arg", "objc_selector", "objc_observer", "render_font", "index_subscript", "int_conversion"]
# Modules whose drawing runs on background threads (RowBitmaps, tile and measure queues,
# the sidebar's concurrentPerform), and their font caches (allowlisted when banned).
RENDER_MODULES = {"MessagesLabHome", "MessagesLabSidebar", "CmuxHomeRender"}
RENDER_FONT = re.compile(
    r"\b(?:UIFont|NSFont)\s*\.\s*(?:systemFont|boldSystemFont|monospacedSystemFont|monospacedDigitSystemFont|userFont|userFixedPitchFont)\("
    r"|\b(?:UIFont|NSFont)\((?:name|descriptor):|\bCTFontCreate\w*\("
    r"|(?<![\w.])\.(?:systemFont|boldSystemFont|monospacedSystemFont|monospacedDigitSystemFont)\(ofSize")
STATIC_LET = re.compile(r"\bstatic\s+let\b")
# Modules that decode external input or draw on background threads (Lawrence, 2026-10-09).
INDEX_MODULES = {"MessagesLabHome", "MessagesLabSidebar", "CmuxHomeRender", "CMUXMobileCore", "CmuxIrxTransport",
                 "CmuxIrohTransport", "CmuxNextDaemon", "CmuxNextControl", "CmuxNextMobile", "CmuxTerminalSizing"}
INDEX_SUBSCRIPT = re.compile(r"(?<![\w.])(?:[a-z_]\w*|self)(?:\.\w+)*(?:\(\))?\[([^\[\]]+)\]")
OPTIONAL_BINDING = re.compile(r"\b(?:if|guard|while)\s+(?:let|var)\b|,\s*let\s+\w+\s*=")
INT_CONVERSION = re.compile(
    r"(?<![\w.])U?Int(?:8|16|32|64)?\((?!\s*(?:truncatingIfNeeded|clamping|exactly|bitPattern|littleEndian|bigEndian|ascii)\s*:)"
    r"(?!\s*\))(?!\s*(?:0x[0-9A-Fa-f_]+|0b[01_]+|0o[0-7_]+|\d[\d_]*)\s*\))")
# Declarations that name a dictionary or an array (for index_subscript; no types here).
DECLARED_TYPE = re.compile(r"\b(?:var|let)\s+(\w+)\s*(?::\s*(\S.*)|=\s*(\S.*))")
# Parameters (`func f(m: [K: V])`, `init(_ m: [K: V])`): only on func/init lines, so call
# labels (`reduce(into: [:])`) are not read as declarations.
# The type is read from the match end, so a later parameter on the same line is found too.
PARAMETER_TYPE = re.compile(r"[(,]\s*(?:\w+\s+)?(\w+)\s*:\s*(?:inout\s+)?(?=\[|(?:Dictionary|Array)\s*<)")
FUNC_OR_INIT = re.compile(r"\bfunc\s+\w+\s*(?:<[^>]*>)?\s*\(|(?<![.\w])init\??\s*(?:<[^>]*>)?\s*\(")


BOUND_BEFORE = re.compile(r"(?:\b(?:if|guard|while)\s+|,\s*)(?:let|var)\s+\w+(?:\s*:\s*[^=,]+)?\s*=\s*$")
BOUND_AFTER = re.compile(r"^\s*(?:,|\{|else\b|$)")


def is_bound_value(code, start, end):
    """True when CODE[start:end] is the whole value of an optional binding
    (`if let x = map[k] {`, `guard let n = Int(s), ...`): the binding unwraps it, so
    it cannot trap. A subscript or conversion elsewhere on a binding line still counts
    (`guard let c = CGContext(width: Int(w * scale), ...)` traps on NaN)."""
    return bool(BOUND_BEFORE.search(code[:start]) and BOUND_AFTER.match(code[end:]))


RADIX_ARGUMENT = re.compile(r",\s*radix\s*:")


def top_level(arguments):
    """ARGUMENTS with every nested (...) or [...] group removed, so a label inside a
    nested call (`UInt8(String(v, radix: 2).count)`) is not read as the outer one's."""
    out, depth = [], 0
    for ch in arguments:
        if ch in "([":
            depth += 1
        elif ch in ")]":
            depth -= 1
        elif depth == 0:
            out.append(ch)
    return "".join(out)


def int_conversion_hits(code):
    """Integer conversions in CODE that can trap. `Int(someString)` returns an optional:
    a conversion followed by `?`/`??` or inside an optional binding is not counted."""
    hits = 0
    binding = OPTIONAL_BINDING.search(code)
    for match in INT_CONVERSION.finditer(code):
        depth, end = 1, None
        for pos in range(match.end(), len(code)):
            if code[pos] == "(":
                depth += 1
            elif code[pos] == ")":
                depth -= 1
                if depth == 0:
                    end = pos + 1
                    break
        after = code[end:].lstrip() if end else ""
        if after.startswith("?") or (binding and end and is_bound_value(code, match.start(), end)):
            continue
        if end and RADIX_ARGUMENT.search(top_level(code[match.end():end - 1])):
            continue  # `Int(text, radix: 10)`: the failable string parse, never a trap
        hits += 1
    return hits


# Initializers and calls whose value is a dictionary or an indexable non-dictionary (for an assignment target).
DICT_VALUE = re.compile(r"\.reduce\(\s*into\s*:\s*\[(?::|[^\[\]]*:[^\[\]]*\]\s*\(\s*\))\s*\]?|\.mapValues\b|\.compactMapValues\b"
                        r"|^Dictionary\b|\bDictionary\s*\(")
INDEXABLE_VALUE = re.compile(r"^(?:Data|ContiguousArray|ArraySlice|\[UInt8\])\b|^Array\b")


def bracket_kind(text):
    """"dict" or "array" for a type or literal that starts with "[" (a top-level ":"
    makes a dictionary, `[:]` included) or with Dictionary/Array/Data, or a value
    built by a dictionary-returning call (`.reduce(into: [:])`, `.mapValues`); else None."""
    if text.startswith("Dictionary") or (not text.startswith("[") and DICT_VALUE.search(text)):
        return "dict"
    if INDEXABLE_VALUE.match(text):
        return "array"
    if not text.startswith("["):
        return None
    depth = 0
    for ch in text:
        if ch in "[(<":
            depth += 1
        elif ch in "])>":
            depth -= 1
            if depth == 0:
                return "array"
        elif ch == "?" and depth == 1:
            return None  # a ternary in an array literal, or an optional element type
        elif ch == ":" and depth == 1:
            return "dict"
    return None


def collection_names(lines):
    """({dictionary names}, {names declared any other way}) in LINES: a name declared
    as an array, or with an inferred or other type (`let rows = text.split(...)`), is
    in the second set, so its subscripts keep counting."""
    dicts, arrays, others = collection_kinds(lines)
    return dicts, arrays | others


def collection_kinds(lines):
    """({dictionary names}, {names declared as an indexable non-dictionary: an array type or
    literal, Data, Array(...)}, {names declared any other way: inferred or another type})."""
    dicts, arrays, others = set(), set(), set()
    signature_depth = 0  # > 0 while a func/init parameter list continues on later lines
    for line in lines:
        code = swift_code(line)
        found = [(m.group(1), (m.group(2) or m.group(3) or "").strip()) for m in DECLARED_TYPE.finditer(code)]
        head = FUNC_OR_INIT.search(code)
        if head or signature_depth > 0:
            # Only the parameter list: up to the parenthesis that closes it.
            text = code[head.end() - 1:] if head else code
            depth, stop = (0 if head else signature_depth), len(text)
            for pos, ch in enumerate(text):
                if ch == "(":
                    depth += 1
                elif ch == ")":
                    depth -= 1
                    if depth <= 0:
                        stop = pos + 1
                        break
            params = text[:stop] if head else "(" + text[:stop]
            found += [(m.group(1), params[m.end():].strip()) for m in PARAMETER_TYPE.finditer(params)]
            signature_depth = max(depth, 0) if stop == len(text) else 0
        for name, text in found:
            kind = bracket_kind(text)
            (dicts if kind == "dict" else arrays if kind == "array" else others).add(name)
    return dicts, arrays, others


ASSIGNED = re.compile(r"\s*=(?!=)")


def index_hits(code, dictionaries=frozenset()):
    """Computed subscripts in CODE that can trap (see index_subscript). DICTIONARIES:
    names the module declares only as dictionaries, or (file dictionaries, module
    dictionaries[, file indexables, module indexables]) from file_dictionaries. An
    assignment target (`x[k] = v`) counts only on a known indexable name."""
    hits = 0
    if isinstance(dictionaries, tuple) and len(dictionaries) == 4:
        local, module, local_arrays, module_arrays = dictionaries
    else:
        local, module = dictionaries if isinstance(dictionaries, tuple) else (dictionaries, dictionaries)
        local_arrays = module_arrays = None  # unknown: every assignment target counts, as before
    binding = OPTIONAL_BINDING.search(code)
    for match in INDEX_SUBSCRIPT.finditer(code):
        inner = match.group(1).strip()
        if not inner or inner[0] in "\"'" or re.fullmatch(r"\d+", inner):
            continue
        if re.match(r"checked\s*:", inner) or re.search(r",\s*default\s*:", inner):
            continue  # a checked accessor, or a dictionary subscript with a default
        chain = re.sub(r"\(\)$", "", match.group(0)[:match.group(0).index("[")])
        base = chain.split(".")[-1]
        # A file's own declarations decide only for a bare name (or self.name); a
        # member of another value (`transport.pending[i]`) uses the module rule.
        qualified = chain not in (base, "self." + base)
        if base in (module if qualified else local):
            continue
        if local_arrays is not None and ASSIGNED.match(code[match.end():]) and \
                base not in (module_arrays if qualified else local_arrays | module_arrays):
            continue  # `x[k] = v` on a name not known to be indexable: a dictionary cannot trap
        if re.fullmatch(r"[A-Z][\w.<>?, ]*(?:\s*:\s*[A-Z][\w.<>?, \[\]]*)?", inner):
            continue  # a type: [String], [Key: Value]
        after = code[match.end():].lstrip()
        if after.startswith("?"):
            continue
        if binding and is_bound_value(code, match.start(), match.end()):
            continue
        if checked_slot(code, match):
            continue
        hits += 1
    return hits


CHECKED_SLOT = re.compile(r"\blet\s+(\w+)\s*=\s*([\w.]+)\.checkedIndex\(")


def checked_slot(code, match):
    """`if let slot = rows.checkedIndex(i) { rows[slot] = v }`: the index came from the
    same collection's checked accessor on this line, so it is in range."""
    base = match.group(0)[:match.group(0).index("[")]
    inner = match.group(1).strip()
    return any(m.group(1) == inner and m.group(2) == base for m in CHECKED_SLOT.finditer(code[:match.start()]))


# trap_api (report-only, see the docstring).
UNIQUE_KEYS = re.compile(r"\buniqueKeysWithValues\s*:")
REMOVE_END = re.compile(r"\bremove(?:First|Last)\s*\(")
# The opening of a call that may be `(repeating:count:)`: its arguments (up to CALL_LINES lines on) need a top-level
# `repeating` label to count, so a formatter's wrapped form `Array(\n    repeating: 0,\n    count: n\n)` counts too.
REPEAT_INIT = re.compile(r"(?:(?<![\w.])(?:Array|ContiguousArray|String|Data)\s*(?:<[^()]*>)?"
                         r"|\[[^\[\]()]+\]|(?<!\w)\.init)\s*\(")
REPEAT_ELEMENT = re.compile(r"(?<![\w.])repeatElement\s*\(")
OFFSET_CALL = re.compile(r"(?<![\w])(?:index|formIndex)\s*\(")
RECEIVER = re.compile(r"((?:[A-Za-z_]\w*\??\.)*[A-Za-z_]\w*)\??\.\s*$")
# Count forms that are never negative (see safe_count): literal arithmetic without a minus (`64 * 1024`, `1 << 20`),
# a collection's count, one of the C buffer-size constants below (`NI_MAXHOST`, `Int(clamping: INET6_ADDRSTRLEN)`),
# and K minus a count modulo K, which is 1...K (base64 padding: `4 - value.count % 4`).
LITERAL_COUNT = re.compile(r"(?=[^-]*\d)[\d_\s*+<()]+|0x[\da-fA-F_]+")
COUNT_READ = re.compile(r"(?:[A-Za-z_]\w*(?:\(\))?\??\.)+count")
# Imported C constants that are buffer sizes, so positive by definition. Not any SCREAMING_SNAKE name: `INT_MIN`,
# `SEEK_CUR` or an errno is not a size.
C_SIZE_CONSTANTS = ("INET_ADDRSTRLEN", "INET6_ADDRSTRLEN", "NI_MAXHOST", "NI_MAXSERV", "PATH_MAX", "NAME_MAX",
                    "MAXPATHLEN", "IFNAMSIZ", "IF_NAMESIZE", "MAXCOMLEN", "PROC_PIDPATHINFO_MAXSIZE",
                    "CC_MD5_DIGEST_LENGTH", "CC_SHA1_DIGEST_LENGTH", "CC_SHA224_DIGEST_LENGTH",
                    "CC_SHA256_DIGEST_LENGTH", "CC_SHA384_DIGEST_LENGTH", "CC_SHA512_DIGEST_LENGTH",
                    "CMUX_RD_INPUT_PACKET_MAX", "CMUX_RD_BULK_FRAME_MAX", "CMUX_RD_BULK_CREDIT_MAX")
_C_SIZE = "(?:" + "|".join(C_SIZE_CONSTANTS) + ")"
C_CONSTANT = re.compile(_C_SIZE + r"|Int(?:32)?\(\s*(?:clamping:|truncatingIfNeeded:)?\s*" + _C_SIZE + r"\s*\)")
PADDING_COUNT = re.compile(r"(?P<K>\d+)\s*-\s*(?:[A-Za-z_]\w*(?:\(\))?\??\.)+count\s*%\s*(?P=K)")
COUNT_BINARY = ("+", "*", "/", "%")
COUNT_CALL = re.compile(r"(min|max)\s*\((.*)\)")


def top_level_split(text, separators):
    """TEXT split at the SEPARATORS (single characters) outside parentheses, brackets and braces.
    Returns (parts, the separators found)."""
    parts, found, depth, current = [], [], 0, []
    for ch in text:
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        if depth == 0 and ch in separators:
            parts.append("".join(current))
            found.append(ch)
            current = []
        else:
            current.append(ch)
    parts.append("".join(current))
    return parts, found


def wrapped(text):
    """Whether TEXT is one parenthesized group: its first "(" closes at its last character."""
    if not text.startswith("("):
        return False
    depth = 0
    for pos, ch in enumerate(text):
        depth += (ch in "([{") - (ch in ")]}")
        if depth == 0:
            return pos == len(text) - 1
    return False


def safe_count(count, known=lambda name: False):
    """Whether a `(repeating:count:)` COUNT is never negative by its form: a form of LITERAL_COUNT, COUNT_READ,
    C_CONSTANT or PADDING_COUNT; a name KNOWN accepts (validated before the call, count_validated); a sum,
    product, quotient or remainder of safe counts (no minus); `min` of safe counts; `max` with one safe count
    (`max(0, n)`); a ternary whose two results are safe (`ipv6 ? 16 : 4`), in parentheses or not."""
    count = count.strip()
    if not count:
        return False
    if any(form.fullmatch(count) for form in (LITERAL_COUNT, COUNT_READ, C_CONSTANT, PADDING_COUNT)):
        return True
    name = COUNT_NAME.fullmatch(count)
    if name:
        return known(name.group(1))
    if wrapped(count):
        return safe_count(count[1:-1], known)
    question, _ = top_level_split(count, "?")
    if len(question) == 2:
        results, _ = top_level_split(question[1], ":")
        return len(results) == 2 and all(safe_count(part, known) for part in results)
    if top_level_split(count, "-")[1]:
        return False
    operands, _ = top_level_split(count, "".join(COUNT_BINARY))
    if len(operands) > 1:
        return all(safe_count(part, known) for part in operands)
    call = COUNT_CALL.fullmatch(count)
    if call:
        arguments = top_level_arguments(call.group(2))
        test = all if call.group(1) == "min" else any
        return bool(arguments) and test(safe_count(part, known) for part in arguments)
    return False


# A count that is one name (`n`, `self.n`, `Self.n`, `Sizes.n`), qualifier and all: safe when it is validated, see
# count_validated. `self.n` and `n` are different names.
COUNT_NAME = re.compile(r"((?:(?:self|Self|[A-Z]\w*)\.)?[A-Za-z_]\w*)")
DECLARED_FUNC = re.compile(r"\bfunc\s+$")
# A line without one of these words starts no trap_api call (skips swift_code on most lines).
TRAP_HINT = re.compile(r"uniqueKeysWithValues|remove(?:First|Last)|repeatElement|[iI]ndex\s*\("
                       r"|(?:Array|String|Data)\s*(?:<[^()]*>)?\s*\(|\]\s*\(|\.init\s*\(")
# How many lines above a removal may hold its guard, and how many lines a call's arguments may continue on.
GUARD_LINES = 3
CALL_LINES = 3
# How far up a `guard ... else { ... }` that ends on the line above a call may start (its else block's length).
GUARD_BLOCK_LINES = 12
GUARD_WORD = re.compile(r"(?<![\w.])guard\b")


def guard_window(lines, index):
    """The code of the lines that may guard a call on LINES[INDEX]: the GUARD_LINES lines above it and, when a
    `guard ... else { ... }` ends on the code line above (`}` alone), that statement's first lines too (GUARD_LINES
    from its `guard`), so a guard whose else block runs several lines still counts:
    `guard let next = queue.first else {\n    idle()\n    return\n}\nqueue.removeFirst()`."""
    window = [swift_code(lines[i]) for i in range(max(0, index - GUARD_LINES), index)]
    # The code line above, past blank and comment lines.
    end = next((i for i in range(index - 1, max(-1, index - 1 - GUARD_LINES), -1) if swift_code(lines[i]).strip()),
               None)
    if end is None or swift_code(lines[end]).strip() != "}":
        return window
    depth = 0
    for i in range(end, max(-1, end - GUARD_BLOCK_LINES), -1):
        code = swift_code(lines[i])
        depth += code.count("}") - code.count("{")
        if depth > 0:
            continue
        # LINES[i] opens the else block; its guard starts on it or up to GUARD_LINES lines above (a wrapped
        # condition list).
        start = next((j for j in range(i, max(-1, i - 1 - GUARD_LINES), -1) if GUARD_WORD.search(swift_code(lines[j]))),
                     None)
        if start is not None:
            window += [swift_code(lines[j]) for j in range(start, i + 1)]
        break
    return window


def call_arguments(lines, index, code, start):
    """The argument text of the call whose "(" ends at CODE[start - 1] (CODE is LINES[INDEX] as swift_code
    reads it), up to its closing parenthesis; the arguments may continue on the next CALL_LINES lines."""
    text, depth, follow = code[start:], 1, index + 1
    while True:
        for pos, ch in enumerate(text):
            if ch in "([{":
                depth += 1
            elif ch in ")]}":
                depth -= 1
                if depth == 0:
                    return text[:pos]
        if follow >= len(lines) or follow > index + CALL_LINES:
            return text
        text += " " + swift_code(lines[follow])
        follow += 1


def top_level_arguments(arguments):
    """ARGUMENTS split at their top-level commas, each stripped."""
    parts, depth, current = [], 0, []
    for ch in arguments:
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        if ch == "," and depth == 0:
            parts.append("".join(current).strip())
            current = []
        else:
            current.append(ch)
    parts.append("".join(current).strip())
    return [part for part in parts if part]


def labeled(arguments, label):
    """The value of the top-level argument LABEL in ARGUMENTS, or None."""
    for part in top_level_arguments(arguments):
        name, colon, value = part.partition(":")
        if colon and name.strip() == label:
            return value.strip()
    return None


def removal_guarded(lines, index, code, start):
    """Whether the removal at CODE[start] reads its receiver's isEmpty, count, first, last, hasPrefix, hasSuffix
    or starts before it on its line or in guard_window, or its `(n)` is bounded by the receiver's count
    (`q.count`, `q.count / 4`, `min(q.count, <safe count>)`). An implicit-self removal looks for a bare `isEmpty`."""
    before = code[:start]
    receiver = None
    if before.rstrip().endswith("."):
        found = RECEIVER.search(before)
        if not found:
            return False  # `rows[i].removeFirst()`: no name to find a guard for
        receiver = re.sub(r"^self\.", "", found.group(1).replace("?", ""))
        before = before[:found.start()]
    name = r"(?:self\.)?" + re.escape(receiver) + r"\??\s*\." if receiver else r"(?:self\.)?"
    guard = re.compile(r"(?<![\w.])" + name + r"\s*(?:isEmpty|count|first|last|hasPrefix|hasSuffix|starts)\b")
    window = [before] + guard_window(lines, index)
    if any(guard.search(text) for text in window):
        return True
    # `(n)` bounded by the receiver's own count: `q.removeFirst(q.count / 4)`, `q.removeLast(min(q.count, n))`.
    paren = code.find("(", start)
    argument = call_arguments(lines, index, code, paren + 1).strip() if paren >= 0 else ""
    own = r"(?:self\.)?" + re.escape(receiver) + r"\??\s*\.\s*count" if receiver else r"count"
    bounded = re.compile(own + r"(?:\s*/\s*[1-9]\d*)?")
    if bounded.fullmatch(argument):
        return True
    call = COUNT_CALL.fullmatch(argument)
    if call and call.group(1) == "min":
        parts = top_level_arguments(call.group(2))
        return (any(bounded.fullmatch(part) for part in parts)
                and all(bounded.fullmatch(part) or safe_count(part) for part in parts))
    return False


# id(lines) -> (lines, the names LINES declares as non-negative type constants): one scan per file and report run.
STATIC_CONSTANTS = {}


def literal_constants(lines):
    """The names LINES declares only as `static let` constants whose every value is a safe count of literals and
    of such constants (`static let capacity = 1300`, `static let hashSize = hashWords * 4`)."""
    cached = STATIC_CONSTANTS.get(id(lines))
    if cached is not None and cached[0] is lines:
        return cached[1]
    if len(STATIC_CONSTANTS) > 256:
        STATIC_CONSTANTS.clear()
    values = {}
    for line in lines:
        if "static" not in line:
            continue
        code = swift_code(line).rstrip()
        found = STATIC_LET.search(code)
        if not found:
            continue
        for item in top_level_split(code[found.end():], ",;")[0]:
            bound = LET_ITEM.fullmatch(item.strip())
            if bound:
                values.setdefault(bound.group(1), []).append(bound.group(2))
    names = set()
    for _ in range(4):  # constants built from constants, a few levels deep
        grown = {name for name, items in values.items()
                 if all(safe_count(value, names.__contains__) for value in items)}
        if grown == names:
            break
        names = grown
    STATIC_CONSTANTS[id(lines)] = (lines, names)
    return names


# How many lines above a call count_validated reads, and how many bindings one count may follow
# (`let cols = max(1, t.columns)`, then `let cells = cols * 4`).
LET_LINES = 20
LET_DEPTH = 2
LET_ITEM = re.compile(r"([A-Za-z_]\w*)\s*(?::\s*Int\s*)?=\s*(.+)")
DECLARATION = re.compile(r"(?<![\w.])(?:let|var)\s+")
IF_WORD = re.compile(r"(?<![\w.#@])if\b")
ELSE_WORD = re.compile(r"(?<![\w.])else\b")
# A ternary's `?` (spaces around it; never optional chaining `a?.b` or `try?`).
TERNARY = re.compile(r"(?<=\s)\?(?=\s)")
# Where a name may start to mean another value: a function, initializer or subscript and its parameters.
SCOPE_START = re.compile(r"(?<![\w.])(?:func|init|deinit|subscript)\b")
# A closure's parameter list: `{ n in`, `{ [weak self] (a, n) in`.
CLOSURE_HEAD = re.compile(r"\{\s*(?:\[[^\[\]]*\]\s*)?\(?([\w\s,:]*?)\)?\s+in\b")
COMPOUND_ASSIGN = r"\s*(?:[-+*/%&|^]|<<|>>)?=(?!=)"
LOOP_WORD = re.compile(r"(?<![\w.])(?:for|while|repeat)\b")


def token_split(text, token):
    """TEXT split at TOKEN (`&&`, `||`) outside parentheses, brackets and braces."""
    parts, depth, last, pos = [], 0, 0, 0
    while pos < len(text):
        ch = text[pos]
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        elif depth == 0 and text.startswith(token, pos):
            parts.append(text[last:pos])
            pos += len(token)
            last = pos
            continue
        pos += 1
    parts.append(text[last:])
    return parts


def conjuncts(condition):
    """The conditions CONDITION requires every one of: its `,` clauses, each split at `&&` unless it has a `||`
    (`a && n > 0 || b` requires neither side)."""
    out = []
    for clause in top_level_split(condition, ",")[0]:
        out += [clause] if len(token_split(clause, "||")) > 1 else token_split(clause, "&&")
    return out


def shows_non_negative(clause, name):
    """Whether CLAUSE, one condition of a conjunction, is NAME compared with a non-negative literal: `n >= 0`,
    `n > 0`, `0 < n`, `(1 <= n)`."""
    clause = clause.strip()
    while wrapped(clause):
        clause = clause[1:-1].strip()
    word = re.escape(name)
    return re.fullmatch(word + r"\s*>=?\s*\d[\d_]*|\d[\d_]*\s*<=?\s*" + word, clause) is not None


def aliases(name):
    """The names that write NAME: `self.width` is also a bare `width` in its type's methods."""
    return [name, name[len("self."):]] if name.startswith("self.") else [name]


def reassigned(text, name):
    """Whether TEXT assigns NAME (`n = `, `n -= 1`, `self.n = ` for `self.n`), declares a new NAME or lends it
    inout (`&n`)."""
    return any(re.search(r"(?<![\w.])" + re.escape(alias) + COMPOUND_ASSIGN + r"|&\s*" + re.escape(alias)
                         + r"(?![\w.])", text) for alias in aliases(name))


def holds_to_end(text, begin, name, after=""):
    """Whether what TEXT shows about NAME at TEXT[begin] still holds at TEXT's end (the call): no `}` closes the
    scope BEGIN is in, no function, initializer, subscript or closure taking a parameter NAME starts, nothing
    assigns NAME, and when a loop starts in between, nothing in AFTER (the code after the call) assigns it for the
    next turn (`var room = 64; for ... { CALL; room = needed }`)."""
    depth = 0
    for ch in text[begin:]:
        depth += (ch == "{") - (ch == "}")
        if depth < 0:
            return False
    rest = text[begin:]
    if SCOPE_START.search(rest):
        return False
    bare = re.compile(r"(?<![\w.])" + re.escape(name.split(".")[-1]) + r"(?![\w.])")
    if any(bare.search(head.group(1)) for head in CLOSURE_HEAD.finditer(rest)):
        return False
    return not reassigned(rest, name) and not (LOOP_WORD.search(rest) and reassigned(after, name))


def condition_end(text, begin, stop):
    """Where the condition that starts at TEXT[begin] ends: at the `else` (STOP ELSE_WORD, a guard) or the `{`
    (STOP "{", an if) outside parentheses and brackets; None when a bracket closes first or TEXT ends."""
    depth = 0
    for pos in range(begin, len(text)):
        ch = text[pos]
        if depth == 0 and (ch == "{" if stop == "{" else bool(stop.match(text, pos))):
            return pos
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
            if depth < 0:
                return None
    return None


def matching_brace(text, open_at):
    """The position of the `}` that closes the `{` at TEXT[open_at], or None."""
    depth = 0
    for pos in range(open_at, len(text)):
        depth += (text[pos] == "{") - (text[pos] == "}")
        if depth == 0:
            return pos
    return None


def guard_shows(text, name, after=""):
    """Whether a `guard` in TEXT requires NAME non-negative in one of its conjuncts, its else block closed before
    TEXT's end and it holds_to_end from there: `guard s.isEmpty, n > 0 else { return }`, never
    `guard s.isEmpty || n > 0`."""
    for word in GUARD_WORD.finditer(text):
        end = condition_end(text, word.end(), ELSE_WORD)
        if end is None or not any(shows_non_negative(part, name) for part in conjuncts(text[word.end():end])):
            continue
        block = end + len("else")
        while block < len(text) and text[block].isspace():
            block += 1
        close = matching_brace(text, block) if block < len(text) and text[block] == "{" else None
        if close is not None and holds_to_end(text, close + 1, name, after):
            return True
    return False


def if_shows(text, name, after=""):
    """Whether TEXT ends inside the block of an `if` that requires NAME non-negative in one of its conjuncts
    (`if n > 0 { ... CALL`), never after the block or in its `else`."""
    for word in IF_WORD.finditer(text):
        block = condition_end(text, word.end(), "{")
        if block is not None and any(shows_non_negative(part, name) for part in conjuncts(text[word.end():block])) \
                and holds_to_end(text, block + 1, name, after):
            return True
    return False


def ternary_condition(text, question):
    """The condition of the ternary whose `?` is TEXT[question]: back to an unmatched opening bracket, a `,`, `;`,
    `:`, `?` or an assignment's `=` outside brackets, without a leading `return`, `try` or `await`."""
    depth, pos = 0, question - 1
    while pos >= 0:
        ch = text[pos]
        if ch in ")]}":
            depth += 1
        elif ch in "([{":
            depth -= 1
            if depth < 0:
                break
        elif depth == 0 and (ch in ",;:?" or (ch == "=" and text[pos - 1:pos] not in ("=", "!", "<", ">")
                                              and text[pos + 1:pos + 2] != "=")):
            break
        pos -= 1
    return re.sub(r"^\s*(?:(?:return|try|await)\s+)*", "", text[pos + 1:question])


def ternary_shows(prefix, name):
    """Whether PREFIX (the call's line before it) ends in the true branch of a ternary whose condition requires
    NAME non-negative: `n > 0 ? Array(...)`, never `n > 0 ? [] : Array(...)`."""
    for question in TERNARY.finditer(prefix):
        depth, branch = 0, prefix[question.end():]
        for ch in branch:
            depth += (ch in "([{") - (ch in ")]}")
            if depth < 0 or (depth == 0 and ch in ":,;"):
                break
        else:
            if (any(shows_non_negative(part, name) for part in conjuncts(ternary_condition(prefix, question.start())))
                    and not reassigned(branch, name)):
                return True
    return False


def binding_value(code, name):
    """What CODE assigns NAME, and where in CODE the assignment ends: a `let` / `var` item's value (`let n = 4`,
    `var w = max(0, a), h = 0`) or an assignment's to its statement's end (`self.width = max(0, width)`); the value
    is "" for a compound assignment (`n -= 1`, never shown safe). None when CODE assigns NAME nothing."""
    if "." not in name:
        found = DECLARATION.search(code)
        if found:
            items, _ = top_level_split(code[found.end():], ",;")
            end = found.end()
            for item in items:
                end += len(item)
                bound = LET_ITEM.fullmatch(item.strip())
                if bound and bound.group(1) == name:
                    return bound.group(2), end
                end += 1
    for alias in aliases(name):
        found = re.search(r"(?<![\w.])" + re.escape(alias) + r"\s*((?:[-+*/%&|^]|<<|>>)?)=(?!=)(.*)", code)
        if found:
            value = top_level_split(found.group(2), ";")[0][0]
            return ("" if found.group(1) else value), found.start(2) + len(value)
    return None


def count_validated(lines, index, code, start, name, depth=0):
    """Whether NAME, a name in a `(repeating:count:)` count, is non-negative at the call at CODE[start] (CODE is
    LINES[INDEX] as swift_code reads it), from the LET_LINES lines above and CODE before the call: a type constant
    of its file (literal_constants); a `guard` (guard_shows) or an `if` whose block holds the call (if_shows) or a
    ternary whose true branch holds it (ternary_shows) that requires `NAME >= 0`, `NAME > 0`, `0 < NAME`; or its
    nearest `let` / `var` / assignment, whole value a safe count (`let cols = max(1, t.columns)`, not
    `var m = max(0, x) - 10`). Each holds_to_end: same scope, no new function, no reassignment."""
    qualifier, _, last = name.rpartition(".")
    if (not qualifier or qualifier == "Self" or qualifier[0].isupper()) and last in literal_constants(lines):
        return True
    first = max(0, index - LET_LINES)
    segments = [swift_code(lines[i]) for i in range(first, index)] + [code[:start]]
    text = "\n".join(segments)
    after = "\n".join([code[start:]] + [swift_code(line) for line in lines[index + 1:index + 1 + LET_LINES]])
    if guard_shows(text, name, after) or if_shows(text, name, after) or ternary_shows(code[:start], name):
        return True
    begin = len(text) + 1
    for offset in range(len(segments) - 1, -1, -1):
        begin -= len(segments[offset]) + 1
        binding = binding_value(segments[offset], name)
        if binding is None:
            continue
        value, end = binding
        line = first + offset
        line_code = code if line == index else segments[offset]
        return holds_to_end(text, begin + end, name, after) and safe_count(
            value, lambda inner: depth < LET_DEPTH and count_validated(lines, line, line_code, 0, inner, depth + 1))
    return False


def trap_api_hits(lines, index, code=None):
    """trap_api calls that start on LINES[INDEX] (see the docstring); a comment line has none. CODE: the line as
    swift_code reads it, when the caller has it."""
    if not TRAP_HINT.search(lines[index]) or lines[index].lstrip().startswith("//"):
        return 0
    code = swift_code(lines[index]) if code is None else code
    hits = len(UNIQUE_KEYS.findall(code))
    for match in REMOVE_END.finditer(code):
        if DECLARED_FUNC.search(code[:match.start()]):
            continue
        if not removal_guarded(lines, index, code, match.start()):
            hits += 1
    for match in REPEAT_INIT.finditer(code):
        arguments = call_arguments(lines, index, code, match.end())
        count = labeled(arguments, "count")
        if (labeled(arguments, "repeating") is not None and count is not None
                and not safe_count(count, lambda name: count_validated(lines, index, code, match.start(), name))):
            hits += 1
    for match in REPEAT_ELEMENT.finditer(code):
        count = labeled(call_arguments(lines, index, code, match.end()), "count")
        if count is not None and not safe_count(
                count, lambda name: count_validated(lines, index, code, match.start(), name)):
            hits += 1
    for match in OFFSET_CALL.finditer(code):
        if DECLARED_FUNC.search(code[:match.start()]):
            continue
        arguments = call_arguments(lines, index, code, match.end())
        if labeled(arguments, "offsetBy") is not None and labeled(arguments, "limitedBy") is None:
            hits += 1
    return hits

ADD_OBSERVER = re.compile(r"\baddObserver\(")
SELECTOR_OBSERVER = re.compile(r"addObserver\(\s*[^,()]+?,\s*selector\s*:")
OBJC_ATTR = re.compile(r"@objc(?![\w(])")
OBJC_FUNC = re.compile(r"\bfunc\s+[\w`]+\s*(?:<[^>]*>)?\s*\(")
OTHER_DECL = re.compile(r"\b(protocol|class|struct|enum|extension|var|let|init|subscript|case)\b")
MAIN_PROOF = re.compile(r"//\s*main-proof:\s*\S")
ALLOWLIST = os.path.join(HERE, "crash-allowlist.json")
APP_PACKAGE = "Packages/macOS/CmuxNext"
PACKAGE_PATH = re.compile(r"\.package\(\s*path:\s*\"([^\"]+)\"")
RUST = {
    "unwrap": re.compile(r"\.unwrap\(\)"),
    "expect": re.compile(r"\.expect\("),
    "panic_macro": re.compile(r"\b(panic|unreachable|todo|unimplemented)!\s*[\(\{\[]"),
    "exit": re.compile(r"\bprocess::(exit|abort)\("),
}
ENV_WRITE = re.compile(r"\b(setenv|unsetenv|putenv)\s*\(|\benviron\s*(\[[^\]]*\]\s*)?=(?!=)")
ENV_ALLOWLIST = os.path.join(HERE, "env-write-allowlist.json")
# A test-only cfg: `cfg(test)`, or `cfg(all(...))` with `test` as one of its
# top-level predicates (`cfg(all(test, unix))`). Never `any(test, ...)` or
# `not(test)`: those also compile outside tests.
_CFG_ITEM = r'(?:(?:any|all|not)\([^()]*\)|\w+\s*=\s*"[^"]*"|\w+)'
_TEST_CFG = (r"(?:test|all\(\s*(?:" + _CFG_ITEM + r"\s*,\s*)*test\s*(?:,\s*" + _CFG_ITEM
             + r"\s*)*,?\s*\))")
INLINE_TESTS = re.compile(r"#\[cfg\(" + _TEST_CFG
                          + r"\)\]\s*(#\[[^\]]*\]\s*)*(pub(\([^)]*\))?\s+)?mod\s+\w+\s*\{")
# An out-of-line test-only module: `#[cfg(test)] mod name;` (attributes such as `#[path = "x.rs"]`
# may sit between). Its file, and every file below it, compiles only in tests.
TEST_MOD_DECL = re.compile(r"#\[cfg\(" + _TEST_CFG + r"\)\]\s*(?P<attrs>(?:#\[[^\]]*\]\s*)*)"
                           r"(?:pub(?:\([^)]*\))?\s+)?mod\s+(?P<name>\w+)\s*;")
RUST_PATH_ATTR = re.compile(r'#\[path\s*=\s*"(?P<path>[^"]+)"\s*\]')
UNREACHABLE_INIT = re.compile(r"\binit\??\((coder|rootView)\b")


def swift_code(line):
    """LINE without its comments and with string literal text blanked (quotes and
    interpolated code kept), so `"Hello! world"` or `// x!` never count and
    `"\\(value!)"` still does. One line at a time: the inside of a multi-line string
    literal is read as code."""
    out, i, n = [], 0, len(line)
    in_string, depth = False, 0  # depth > 0: inside \( ... ) of a string
    while i < n:
        ch = line[i]
        if in_string and depth == 0:
            if ch == "\\" and i + 1 < n and line[i + 1] == "(":
                out.append("\\(")
                depth, i = 1, i + 2
                continue
            if ch == "\\":
                out.append("  ")
                i += 2
                continue
            if ch == '"':
                in_string = False
                out.append(ch)
            else:
                out.append(" ")
            i += 1
            continue
        if line.startswith("//", i):
            break
        if line.startswith("/*", i):
            end = line.find("*/", i + 2)
            if end < 0:
                break
            out.append(" " * (end + 2 - i))
            i = end + 2
            continue
        if ch == '"':
            in_string = True
        elif in_string and ch == "(":
            depth += 1
        elif in_string and ch == ")":
            depth -= 1
        out.append(ch)
        i += 1
    return "".join(out)


def allow_lines(lines, index):
    """The 0-based lines whose `// crash-allow:` waives LINES[INDEX]: the line itself and the line directly
    above. guardrails.py reads the same window, so it never passes a line this ratchet counts."""
    return [index, index - 1] if index > 0 else [index]


def allowed(lines, index):
    return any(ALLOW.search(lines[i]) for i in allow_lines(lines, index))


# An exported tree (--exported-tree, git archive of a ref) holds tracked files only, so every
# file under a root counts. safe-push-ratchet.py passes it for the remote tip's export.
SOURCE_SUFFIXES = (".swift", ".rs")


def refuse(message):
    print(f"crash-ratchet: refused: {message}", file=sys.stderr)
    raise SystemExit(2)


def tracked_files(repo, root, exported):
    """Files under ROOT that git tracks (absolute paths, sorted). Ignored and untracked
    files never count: build or sync output in a per-job tree made the ratchet red while
    every tracked file equalled the tip (2026-10-07). Outside a git checkout, or with an
    index that lists none of ROOT's sources (a Testbox sync), the ratchet refuses (exit 2):
    walking every file counted build output and vendored crates and gave a false red on
    2026-10-09. An exported tree (--exported-tree) is walked."""
    rel = os.path.relpath(root, repo)
    if exported:
        return sorted(os.path.join(d, n) for d, _, names in os.walk(root) for n in names)
    try:
        out = subprocess.run(["git", "-C", repo, "ls-files", "-z", "--", rel],
                             check=True, capture_output=True).stdout.decode("utf-8", "replace")
    except (OSError, subprocess.CalledProcessError) as error:
        refuse(f"{repo} is not a git checkout ({error}). Run in a checkout, or pass --exported-tree "
               "for a tree that holds only tracked files (git archive).")
    files = sorted(os.path.join(repo, p) for p in out.split("\0") if p)
    if not files and os.path.isdir(root) and any(
            n.endswith(SOURCE_SUFFIXES) for _, _, names in os.walk(root) for n in names):
        refuse(f"the git index of {repo} lists no file under {rel}, but the folder has sources "
               "(a sync without a usable index). Run in a real checkout.")
    return files


def swift_source_roots(repo):
    """Sources/ of the app package and of every package in its `.package(path:)` closure
    (transitively), relative to REPO. Without the app's Package.swift (a partial tree),
    only its Sources/."""
    roots, seen, queue = [], set(), [APP_PACKAGE]
    while queue:
        pkg = os.path.normpath(queue.pop(0))
        # vendor/ is third-party source we do not edit (tracked as its own risk, not here).
        if pkg in seen or pkg.startswith("..") or pkg.split(os.sep)[0] == "vendor":
            continue
        seen.add(pkg)
        if os.path.isdir(os.path.join(repo, pkg, "Sources")):
            roots.append(os.path.join(pkg, "Sources"))
        manifest = os.path.join(repo, pkg, "Package.swift")
        if os.path.isfile(manifest):
            for dep in PACKAGE_PATH.findall(open(manifest, encoding="utf-8").read()):
                queue.append(os.path.join(pkg, dep))
    return roots


def objc_selector_hits(lines, index, code):
    """1 when LINE starts a non-override @objc func that has a labeled parameter and no
    explicit selector. The declaration may continue on the next line."""
    if not OBJC_ATTR.search(code):
        return 0
    decl = code[OBJC_ATTR.search(code).start():]
    if OTHER_DECL.search(decl) and not OBJC_FUNC.search(decl):
        return 0
    follow = index + 1
    while not OBJC_FUNC.search(decl) and not OTHER_DECL.search(decl) and follow < len(lines) and follow <= index + 2:
        decl += " " + swift_code(lines[follow]).strip()
        follow += 1
    match = OBJC_FUNC.search(decl)
    if not match or re.search(r"\boverride\b", decl[:match.start()]) or re.search(r"\boverride\b", code):
        return 0
    depth, start, params = 0, match.end(), None
    for pos in range(start, len(decl)):
        if decl[pos] in "([<":
            depth += 1
        elif decl[pos] in ")]>":
            if depth == 0:
                params = decl[start:pos]
                break
            depth -= 1
    if not params or not params.strip():
        return 0
    parts, depth, current = [], 0, ""
    for ch in params:
        if ch in "([<":
            depth += 1
        elif ch in ")]>":
            depth -= 1
        if ch == "," and depth == 0:
            parts.append(current)
            current = ""
        else:
            current += ch
    parts.append(current)
    for part in parts:
        names = part.split(":", 1)[0].split()
        if names and names[0] != "_":
            return 1
    return 0


def objc_observer_hits(lines, index, code):
    """Selector-based addObserver calls that start in LINE; the arguments may continue
    on the next two lines."""
    starts = [m.start() for m in ADD_OBSERVER.finditer(code)]
    if not starts:
        return 0
    follow = " ".join(swift_code(l).strip() for l in lines[index + 1:index + 3])
    return sum(1 for start in starts if SELECTOR_OBSERVER.match(code[start:] + " " + follow))


def swift_line_hits(lines, index, module=None, dictionaries=frozenset()):
    """{kind: hits} for one Swift line (comment lines and crash-allow are the caller's)."""
    line = lines[index]
    code = swift_code(line)
    # A force unwrap is not `as!`, `try!` (own classes) or an IUO type (`: T!`).
    unwrap_code = SWIFT["iuo"].sub(lambda m: " " * len(m.group(0)), re.sub(r"\b(as|try)!", r"\1 ", code))
    hits = {}
    for kind, pattern in SWIFT.items():
        found = len(pattern.findall(unwrap_code if kind == "force_unwrap" else code))
        if not found:
            continue
        if kind == "fatal_error" and UNREACHABLE_INIT.search(" ".join(lines[max(0, index - 2):index + 1])):
            continue
        if kind == "assume_isolated" and (MAIN_PROOF.search(line) or (index > 0 and MAIN_PROOF.search(lines[index - 1]))):
            continue
        hits[kind] = found
    match = ASYNC_DEFAULT.search(code)
    if match and not STORED_DECL.search(code[:match.start() + len(match.group(0).split(":")[0]) + 1]):
        hits["async_closure_default_arg"] = 1
    if objc_selector_hits(lines, index, code):
        hits["objc_selector"] = 1
    found = objc_observer_hits(lines, index, code)
    if found:
        hits["objc_observer"] = found
    if module in INDEX_MODULES:
        found = index_hits(code, dictionaries)
        if found:
            hits["index_subscript"] = found
        found = int_conversion_hits(code)
        if found:
            hits["int_conversion"] = found
    if module in RENDER_MODULES and not STATIC_LET.search(code):
        found = len(RENDER_FONT.findall(code))
        if found:
            hits["render_font"] = found
    return hits


def module_dictionaries(repo, exported):
    """{index module: names it declares as dictionaries and never as arrays}."""
    return {module: d for module, (d, _) in module_collections(repo, exported).items()}


def module_collections(repo, exported):
    """{index module: (names it declares as dictionaries and never otherwise, names it declares
    as an indexable non-dictionary anywhere)}."""
    declared = {}
    for root in swift_source_roots(repo):
        sources = os.path.join(repo, root)
        for path in tracked_files(repo, sources, exported):
            module = os.path.relpath(path, sources).split(os.sep)[0]
            if module not in INDEX_MODULES or not path.endswith(".swift") or not os.path.isfile(path):
                continue
            dicts, arrays, others = collection_kinds(open(path, encoding="utf-8", errors="replace").read().split("\n"))
            entry = declared.setdefault(module, (set(), set(), set()))
            entry[0].update(dicts)
            entry[1].update(arrays)
            entry[2].update(others)
    return {module: (frozenset(d - a - o), frozenset(a)) for module, (d, a, o) in declared.items()}


def file_dictionaries(lines, module_dicts, module_arrays=None):
    """Names that LINES (one file) subscript as dictionaries: a name the file declares
    only as a dictionary, or one it does not declare at all that its module declares only
    as a dictionary (a property from the type's main file used in an extension file). A
    same-named array or inferred local in another file of the module no longer hides a
    dictionary declared in this one; one declared any other way in this file still counts."""
    dicts, arrays, others = collection_kinds(lines)
    others = others | arrays
    declared = dicts | others
    local = frozenset((dicts - others) | {name for name in module_dicts if name not in declared})
    if module_arrays is None:
        return local, frozenset(module_dicts)
    return local, frozenset(module_dicts), frozenset(arrays), frozenset(module_arrays)


class Site(NamedTuple):
    """One line's hits of one class, by place (--classify reads these)."""
    section: str  # counted, waived or banned (the ratchet's scan), or report (a --report class)
    lang: str
    kind: str
    module: str
    path: str  # relative to the repo
    line: int  # 1-based
    hits: int


class Scan:
    """One tree's hits: counted and waived ({lang: {class: {module: hits}}}), banned hits per
    file {(class, repo-relative path): hits}, and every counted or waived hit by its line
    {(section, lang, class, module, stripped line): hits}, which proves a move between modules.
    With SITES (--classify), every hit is also kept by its place: Site rows in .sites."""

    def __init__(self, sites=False):
        self.counts = {"swift": {}, "rust": {}}
        self.waived = {"swift": {}, "rust": {}}
        self.banned_files = {}
        self.lines = {}
        self.sites = [] if sites else None

    def add(self, waived, lang, kind, module, line, hits, rel=None, number=None):
        section = self.waived if waived else self.counts
        section[lang].setdefault(kind, {}).setdefault(module, 0)
        section[lang][kind][module] += hits
        key = (WAIVED if waived else COUNTED, lang, kind, module, line.strip())
        self.lines[key] = self.lines.get(key, 0) + hits
        self.site(WAIVED if waived else COUNTED, lang, kind, module, rel, number, hits)

    def site(self, section, lang, kind, module, rel, number, hits):
        if self.sites is not None and rel is not None:
            self.sites.append(Site(section, lang, kind, module, rel, number, hits))


def scan_tree(repo, exported, sites=False):
    """The Swift and Rust hits of the tree at REPO (a checkout, or an exported tree); SITES keeps each hit's place."""
    scan = Scan(sites)
    scan_swift(repo, scan, exported)
    scan_rust(repo, scan, exported)
    return scan


def scan_swift(repo, scan, exported):
    """Ratchet hits per module into SCAN (counted, or waived by a crash-allow); hits of banned
    classes per file (crash-allow ignored) into its banned_files."""
    banned = banned_kinds("swift")
    banned_modules = banned_in("swift")
    collections = module_collections(repo, exported)
    for root in swift_source_roots(repo):
        sources = os.path.join(repo, root)
        for path in tracked_files(repo, sources, exported):
            name = os.path.basename(path)
            if not name.endswith(".swift") or not os.path.isfile(path):
                continue
            rel = os.path.relpath(path, sources).split(os.sep)[0]  # the Swift module
            lines = open(path, encoding="utf-8", errors="replace").read().split("\n")
            module_dicts, module_arrays = collections.get(rel, (frozenset(), frozenset()))
            file_dicts = file_dictionaries(lines, module_dicts, module_arrays) if rel in INDEX_MODULES else frozenset()
            for index, line in enumerate(lines):
                if line.lstrip().startswith("//"):
                    continue
                is_allowed = allowed(lines, index)
                for kind, hits in swift_line_hits(lines, index, rel, file_dicts).items():
                    if kind in banned or (kind, rel) in banned_modules:
                        key = (kind, os.path.relpath(path, repo))
                        scan.banned_files[key] = scan.banned_files.get(key, 0) + hits
                        scan.site("banned", "swift", kind, rel, key[1], index + 1, hits)
                        continue
                    scan.add(is_allowed, "swift", kind, rel, line, hits, os.path.relpath(path, repo), index + 1)


def package_sources(repo, exported):
    """Every Swift file under a package's Sources (Packages/**/Sources/**/*.swift), relative to REPO, sorted:
    the report-only classes' scope, wider than the ratchet's app closure. vendor/ is outside Packages/."""
    root = os.path.join(repo, "Packages")
    if not os.path.isdir(root):
        return []
    files = (os.path.relpath(path, repo) for path in tracked_files(repo, root, exported))
    return sorted(rel for rel in files
                  if rel.endswith(".swift") and "Sources" in rel.split(os.sep)[:-1])


def report_owned(kind, rel):
    """Whether REL (relative to the repo) is in the package that implements KIND's safe replacement."""
    return rel.replace(os.sep, "/").startswith(REPORT_OWNERS.get(kind, ()))


# Ratchet classes that are report classes too: counted over INDEX_MODULES, or every module with --all-modules.
REPORT_INDEX = ("index_subscript", "int_conversion")
# Report classes judged by a function of (lines, index) instead of one regex.
REPORT_LINE = {"trap_api": trap_api_hits}
REPORT_CLASSES = sorted(set(REPORT_SWIFT) | set(REPORT_LINE) | set(REPORT_INDEX))
SCOPE_PACKAGES, SCOPE_INDEX_MODULES, SCOPE_ALL_MODULES = "packages", "index-modules", "all-modules"
# A raw line that does not match its class's hint has no hit of the class (so most lines skip swift_code).
REPORT_HINTS = {"trap_api": TRAP_HINT, "index_subscript": re.compile(r"\["),
                "int_conversion": re.compile(r"Int(?:8|16|32|64)?\("),
                **{kind: pattern for kind, pattern in REPORT_SWIFT.items()}}


def report_scope(kind, all_modules):
    """Where the report counts KIND: every package's Sources, INDEX_MODULES of them, or all their modules."""
    if kind not in REPORT_INDEX:
        return SCOPE_PACKAGES
    return SCOPE_ALL_MODULES if all_modules else SCOPE_INDEX_MODULES


def collections_by_module(repo, sources):
    """{module: (names it declares as dictionaries and never otherwise, names it declares as an indexable
    non-dictionary)} over SOURCES (paths relative to REPO), as module_collections() reads the index modules."""
    declared = {}
    for rel in sources:
        with open(os.path.join(repo, rel), encoding="utf-8", errors="replace") as handle:
            dicts, arrays, others = collection_kinds(handle.read().split("\n"))
        entry = declared.setdefault(module_of(rel), (set(), set(), set()))
        entry[0].update(dicts)
        entry[1].update(arrays)
        entry[2].update(others)
    return {module: (frozenset(d - a - o), frozenset(a)) for module, (d, a, o) in declared.items()}


def report_line_hits(kind, lines, index, code, dictionaries):
    """KIND's hits on LINES[INDEX] (CODE is the line as swift_code reads it)."""
    if kind in REPORT_LINE:
        return REPORT_LINE[kind](lines, index, code)
    if kind == "index_subscript":
        return index_hits(code, dictionaries)
    if kind == "int_conversion":
        return int_conversion_hits(code)
    return len(REPORT_SWIFT[kind].findall(code))


def report_sites(repo, exported, kinds, all_modules=False):
    """Site rows (section "report") of the report KINDS over package_sources(), each class outside its owner
    and in its report_scope(): what --report counts and --classify classes. Comment lines and string contents
    never count (swift_code); a crash-allow does not hide a hit."""
    sites = []
    sources = [rel for rel in package_sources(repo, exported) if os.path.isfile(os.path.join(repo, rel))]

    def index_scope(module):
        return all_modules or module in INDEX_MODULES

    collections = {}
    if any(kind in REPORT_INDEX for kind in kinds):
        collections = collections_by_module(repo, [rel for rel in sources if index_scope(module_of(rel))])
    for rel in sources:
        module = module_of(rel)
        judged = [kind for kind in kinds if not report_owned(kind, rel)
                  and (kind not in REPORT_INDEX or index_scope(module))]
        if not judged:
            continue
        with open(os.path.join(repo, rel), encoding="utf-8", errors="replace") as handle:
            lines = handle.read().split("\n")
        dictionaries = frozenset()
        if any(kind in REPORT_INDEX for kind in judged):
            dictionaries = file_dictionaries(lines, *collections.get(module, (frozenset(), frozenset())))
        for index, line in enumerate(lines):
            here = [kind for kind in judged if REPORT_HINTS[kind].search(line)]
            if not here or line.lstrip().startswith("//"):
                continue
            code = swift_code(line)
            for kind in here:
                hits = report_line_hits(kind, lines, index, code, dictionaries)
                if hits:
                    sites.append(Site("report", "swift", kind, module, rel, index + 1, hits))
    return sites


def report_counts(repo, exported, kinds, all_modules=False):
    """({class: {module: hits}}, {class: [site]}) of the report KINDS (report_sites). A site is one line with hits:
    {"path", "line" (1-based), "class", "module", "hits"}, sorted by path and line."""
    counts = {kind: {} for kind in kinds}
    sites = {kind: [] for kind in kinds}
    for site in report_sites(repo, exported, kinds, all_modules):
        counts[site.kind][site.module] = counts[site.kind].get(site.module, 0) + site.hits
        sites[site.kind].append({"path": site.path.replace(os.sep, "/"), "line": site.line, "class": site.kind,
                                 "module": site.module, "hits": site.hits})
    for found in sites.values():
        found.sort(key=lambda site: (site["path"], site["line"]))
    return counts, sites


def load_report_baseline():
    """{class: {"scope": ..., "modules": {module: hits}}} of crash-safety-report-baseline.json ({} without it)."""
    data = load_baseline(REPORT_BASELINE) or {}
    return {kind: row for kind, row in data.items() if not kind.startswith("_") and isinstance(row, dict)}


def report_kinds(names):
    """The report classes NAMES (comma-separated) asks for, or None (printed) when one is unknown or none is given."""
    kinds = [name for name in (part.strip() for part in names.split(",")) if name]
    unknown = [kind for kind in kinds if kind not in REPORT_CLASSES]
    if unknown or not kinds:
        print(f"crash-ratchet: unknown report class {', '.join(unknown) or '(none)'}; report classes: "
              f"{', '.join(REPORT_CLASSES)}", file=sys.stderr)
        return None
    return kinds


def report(repo, exported, names, all_modules=False):
    """Prints the report classes NAMES (comma-separated) as JSON, {class: {"total", "modules": {module: hits},
    "hits": [{"path", "line", "class", "module", "hits"}]}}, each beside its report-baseline row when the row has
    the same scope; exit 0 (it judges nothing), 2 for an unknown class."""
    kinds = report_kinds(names)
    if kinds is None:
        return 2
    counts, sites = report_counts(repo, exported, kinds, all_modules)
    baseline = load_report_baseline()
    out = {}
    for kind, modules in counts.items():
        entry = {"total": sum(modules.values()), "modules": dict(sorted(modules.items())), "hits": sites[kind]}
        row = baseline.get(kind)
        if row and row.get("scope") == report_scope(kind, all_modules):
            known = row.get("modules", {})
            entry["baseline"] = sum(known.values())
            entry["over"] = {module: {"baseline": known.get(module, 0), "now": hits}
                             for module, hits in sorted(modules.items()) if hits > known.get(module, 0)}
        out[kind] = entry
    print(json.dumps(out, indent=2, sort_keys=True))
    return 0


# ---------------------------------------------------------------- trap classes (--classify, Q21)
TRAP_CLASSES = os.path.join(HERE, "trap-classes.json")
TRAP_CLASS_NAMES = ("input", "invariant")
TRAP_LANGS = ("swift", "rust")
# `// trap-class: <class> <reason>`; a colon after the class is optional.
TRAP_CLASS_MARK = re.compile(r"//\s*trap-class:\s*(?P<cls>[\w-]*)\s*:?\s*(?P<reason>.*?)\s*$")
# rust-panic-free.md rule 1's spelling of a checked Rust invariant (a comment, or an #[expect]/#[allow] reason).
INVARIANT_REASON = re.compile(r"\bINVARIANT:\s*\S")
# The next place source_code() must read past: a comment, a string, or (Rust) a character literal or a lifetime.
SOURCE_TOKEN = {
    "swift": re.compile(r'//|/\*|#+"|"'),
    "rust": re.compile(r"//|/\*|(?<![\w])b?r#*\"|'|\""),
}
BLOCK_COMMENT = re.compile(r"/\*|\*/")
RUST_CHAR = re.compile(r"'(?:\\(?:u\{[0-9A-Fa-f]{1,6}\}|x[0-9A-Fa-f]{2}|.)|[^\\'\n])'")
NOT_NEWLINE = re.compile(r"[^\n]")
BRACE = re.compile(r"[{}]")
# A function declaration; the name is its first group that matched. init and subscript are read up to their `(`.
FUNCTION_DECL = {
    "swift": re.compile(r"\bfunc\s+(?P<name>[^\s(<]+)|(?<![.\w])(?P<init>init)(?=\s*[?!]?\s*(?:<[^>]*>)?\s*\()"
                        r"|\b(?P<subscript>subscript)(?=\s*[(<])"),
    "rust": re.compile(r"\bfn\s+(?P<name>\w+)"),
}
# A line that starts another declaration ends a body-less signature (a protocol requirement).
NEXT_DECLARATION = re.compile(
    r"[ \t]*(?:@|#\[|(?:public|private|fileprivate|internal|open|package|static|class|final|override|mutating"
    r"|nonisolated|var|let|case|func|init|deinit|subscript|struct|actor|enum|extension|protocol|typealias|fn|pub"
    r"|impl|mod|const|type|trait|use)\b)")
# A call by name: `helper(`, `self.helper(`, `Self::helper(`, `helper::<T>(`.
CALL = re.compile(r"(?<![\w])(\w+)\s*(?:::\s*<[^<>]*>\s*)?\(")


def block_comment_end(text, start):
    """The offset past the block comment that opens at TEXT[START] (Swift and Rust block comments nest)."""
    depth, j = 0, start
    while True:
        match = BLOCK_COMMENT.search(text, j)
        if not match:
            return len(text)
        depth += 1 if match.group(0) == "/*" else -1
        j = match.end()
        if depth == 0:
            return j


def string_end(text, match, lang):
    """The offset past the string literal that MATCH opens: Swift `"`, `\"\"\"` and `#"..."#` (an escape is `\\`
    plus the delimiter's `#`s; an interpolation `\\(...)` may hold strings), Rust `"` and `r#"..."#`. A one-line
    Swift string with no closing quote ends at its line."""
    tok, n = match.group(0), len(text)
    hashes = tok.count("#")
    if lang == "rust" and "r" in tok:
        close = '"' + "#" * hashes
        end = text.find(close, match.end())
        return n if end < 0 else end + len(close)
    quote_at = match.end() - 1
    quote = '"""' if lang == "swift" and text.startswith('"""', quote_at) else '"'
    close, escape = quote + "#" * hashes, "\\" + "#" * hashes
    j = quote_at + len(quote)
    while j < n:
        if lang == "swift" and text.startswith(escape + "(", j):
            j, depth = j + len(escape) + 1, 1
            while j < n and depth:
                if text[j] == '"':
                    k = text.find('"', j + 1)
                    j = n if k < 0 else k + 1
                    continue
                depth += {"(": 1, ")": -1}.get(text[j], 0)
                j += 1
        elif text.startswith(escape, j):
            j += len(escape) + 1
        elif text.startswith(close, j):
            return j + len(close)
        elif lang == "swift" and quote == '"' and text[j] == "\n":
            return j
        else:
            j += 1
    return n


def source_code(text, lang):
    """TEXT with its comments and its string and character literals blanked, newlines kept (offsets and line
    numbers stay TEXT's): what SourceModel reads braces, declarations and calls in. Unlike swift_code (one line at a
    time), it reads block comments and multi-line and raw strings across lines. A Rust `'` that opens no character
    literal is a lifetime and stays."""
    token, out, i, n = SOURCE_TOKEN[lang], [], 0, len(text)
    while i < n:
        match = token.search(text, i)
        if not match:
            break
        start, tok = match.start(), match.group(0)
        if tok == "//":
            end = text.find("\n", start)
            end = n if end < 0 else end
        elif tok == "/*":
            end = block_comment_end(text, start)
        elif tok == "'":
            literal = RUST_CHAR.match(text, start)
            if not literal:
                out.append(text[i:match.end()])
                i = match.end()
                continue
            end = literal.end()
        else:
            end = string_end(text, match, lang)
        out.append(text[i:start])
        out.append(NOT_NEWLINE.sub(" ", text[start:end]))
        i = end
    out.append(text[i:])
    return "".join(out)


class Function(NamedTuple):
    name: str
    start: int  # 1-based line of the declaration
    end: int  # 1-based line of the body's closing brace
    signature: str  # code from the declaration to the body's `{`
    body: str  # code of the body, nested functions and closures included


def body_open(code, start, limit, lang):
    """The offset of the `{` that opens the body of the declaration whose signature continues at CODE[START], or None
    (no body before LIMIT, the next declaration: a protocol or trait requirement)."""
    depth = 0
    for j in range(start, limit):
        ch = code[j]
        if ch in "([":
            depth += 1
        elif ch in ")]":
            depth -= 1
            if depth < 0:
                return None
        elif depth == 0:
            if ch == "{":
                return j
            if ch == "}" or (ch == ";" and lang == "rust"):
                return None
            if ch == "\n" and NEXT_DECLARATION.match(code, j + 1):
                return None
    return None


def function_spans(code, lang):
    """The functions with a body in CODE (source_code's output), in declaration order."""
    closes, stack = {}, []
    for brace in BRACE.finditer(code):
        if brace.group(0) == "{":
            stack.append(brace.start())
        elif stack:
            closes[stack.pop()] = brace.start()
    starts = [0] + [m.end() for m in re.finditer("\n", code)]
    decls = list(FUNCTION_DECL[lang].finditer(code))
    out = []
    for k, decl in enumerate(decls):
        limit = decls[k + 1].start() if k + 1 < len(decls) else len(code)
        opened = body_open(code, decl.end(), limit, lang)
        if opened is None or opened not in closes:
            continue
        name = next(value for value in decl.groupdict().values() if value)
        out.append(Function(name, bisect.bisect_right(starts, decl.start()), bisect.bisect_right(starts, closes[opened]),
                            code[decl.start():opened], code[opened:closes[opened]]))
    return out


def first_marker(markers, text):
    """The name of the first (name, pattern) of MARKERS that TEXT matches, or None."""
    return next((name for name, pattern in markers if pattern.search(text)), None)


class SourceModel:
    """One file as TrapClassifier reads it: its lines (for marks), its code lines, its functions, and the functions
    that are input-reachable, each with the rule that made it so (the Q14 proxy, a same-file call graph): a decode
    entry point by its declaration (ENTRIES), a function whose body reads peer or file bytes (BYTE_READS), then every
    function of the file such a function calls by name, transitively."""

    def __init__(self, lang, text, entries, byte_reads):
        self.lines = text.split("\n")
        code = source_code(text, lang)
        self.code_lines = code.split("\n")
        self.functions = function_spans(code, lang)
        self.byte_reads = byte_reads
        self.reach = {}
        by_name, queue = {}, []
        for index, function in enumerate(self.functions):
            by_name.setdefault(function.name, []).append(index)
            entry = first_marker(entries, function.signature)
            read = None if entry else first_marker(byte_reads, function.body)
            if entry or read:
                self.reach[index] = f"entry:{function.name} ({entry})" if entry else f"bytes:{function.name} ({read})"
                queue.append(index)
        while queue:
            caller = self.functions[queue.pop()]
            for name in sorted(set(CALL.findall(caller.body))):
                for index in by_name.get(name, ()):
                    if index not in self.reach:
                        self.reach[index] = f"callee:{name} <- {caller.name}"
                        queue.append(index)

    def input_rule(self, number):
        """Why line NUMBER (1-based) is input-reachable, or None: its innermost enclosing function that is reachable,
        else a byte read on the line itself (code outside any function: a stored property's initializer)."""
        enclosing = [i for i, f in enumerate(self.functions) if f.start <= number <= f.end]
        for index in sorted(enclosing, key=lambda i: self.functions[i].start, reverse=True):
            if index in self.reach:
                return self.reach[index]
        if 0 < number <= len(self.code_lines):
            read = first_marker(self.byte_reads, self.code_lines[number - 1])
            if read:
                return f"bytes:line ({read})"
        return None


def trap_markers(data, key, path):
    """{lang: [(name, compiled pattern)]} of trap-classes.json's KEY section; a bad pattern refuses the run."""
    out = {}
    for lang in TRAP_LANGS:
        out[lang] = []
        for name, pattern in sorted(data.get(key, {}).get(lang, {}).items()):
            try:
                out[lang].append((name, re.compile(pattern)))
            except re.error as error:
                refuse(f"{path}: {key}.{lang}.{name}: {error}")
    return out


class TrapClassifier:
    """Classes each trap or panic hit `input` (outside input can reach its operand: validate it and return a typed
    error to a boundary, never clamp, never default) or `invariant` (an internal invariant: the Invariant API in
    Swift, an `INVARIANT:` expect in Rust). Chrome's checks.md draws the same line between a CHECK and handling
    untrusted input (mojo's ReportBadMessage). The rules are in classify(); their data in trap-classes.json."""

    def __init__(self, repo, path=TRAP_CLASSES):
        if not os.path.isfile(path):
            refuse(f"--classify reads its rules' data from {path}, which is missing")
        try:
            with open(path, encoding="utf-8") as handle:
                data = json.load(handle)
        except json.JSONDecodeError as error:
            refuse(f"{path}: {error}")
        self.paths = []
        for entry in data.get("paths", []):
            if (not entry.get("glob") or entry.get("class") not in TRAP_CLASS_NAMES
                    or not str(entry.get("reason", "")).strip()):
                refuse(f"{path}: a paths entry needs a glob, a class ({' or '.join(TRAP_CLASS_NAMES)}) and a "
                       f"reason: {entry}")
            self.paths.append((entry["glob"], entry["class"]))
        self.entries = trap_markers(data, "entries", path)
        self.byte_reads = trap_markers(data, "byte_reads", path)
        self.repo, self.models, self.errors = repo, {}, set()

    def model(self, lang, rel):
        if (lang, rel) not in self.models:
            path = os.path.join(self.repo, rel)
            model = None
            if os.path.isfile(path):
                with open(path, encoding="utf-8", errors="replace") as handle:
                    model = SourceModel(lang, handle.read(), self.entries[lang], self.byte_reads[lang])
            self.models[(lang, rel)] = model
        return self.models[(lang, rel)]

    def classify(self, lang, rel, number):
        """(class, rule) of the hit at line NUMBER (1-based) of REL (relative to the repo). The first rule that
        applies decides, so every hit has exactly one class and names the rule that gave it:
          1. annotation        `// trap-class: input <why>` or `// trap-class: invariant <why>` on the hit's line or
                               the line above (allow_lines, the crash-allow window). A mark with another class or no
                               reason decides nothing and is an error (--classify exits 1).
          2. invariant-reason  Rust only: `INVARIANT: <why>` in that window (a comment, or an #[expect]/#[allow]
                               reason): rust-panic-free.md rule 1's spelling of a checked invariant.
          3. path:<glob>       the first trap-classes.json "paths" entry whose glob matches REL (fnmatch; `*` also
                               matches `/`): a reviewed class for a whole crate, module or file (a wire crate).
          4. entry:/bytes:/callee:  the Q14 reachability proxy (SourceModel): the hit is in a function whose
                               declaration is a decode entry point (trap-classes.json "entries": Rust
                               `fn decode|parse|from_bytes|read_frame|from_slice...`, the Q14 names; Swift
                               `func decode|parse...` and `init(from decoder:)`), or whose body reads peer or file
                               bytes ("byte_reads": decoders, loadUnaligned, withUnsafeBytes, file and socket reads),
                               or in a function of the same file that one of those calls by name, transitively; or
                               the hit's own line reads bytes. Closures and nested functions belong to the function
                               around them. A callee in another file is not followed: give it a path entry or a mark.
          5. default           invariant: nothing above ties the operand to outside input.
        The proxy errs toward input (two functions with one name both count as called): the safe side, since an input
        site gets validation and a typed error where an invariant would trap."""
        model = self.model(lang, rel)
        index = number - 1
        if model and 0 <= index < len(model.lines):
            window = allow_lines(model.lines, index)
            for i in window:
                mark = TRAP_CLASS_MARK.search(model.lines[i])
                if not mark:
                    continue
                if mark.group("cls") in TRAP_CLASS_NAMES and mark.group("reason"):
                    return mark.group("cls"), "annotation"
                self.errors.add(f"{rel}:{i + 1}: a `// trap-class:` mark needs {' or '.join(TRAP_CLASS_NAMES)} "
                                f"and a reason: {mark.group(0).strip()!r}")
            if lang == "rust" and any(INVARIANT_REASON.search(model.lines[i]) for i in window):
                return "invariant", "invariant-reason"
        posix = rel.replace(os.sep, "/")
        for glob, cls in self.paths:
            if fnmatch.fnmatchcase(posix, glob):
                return cls, "path:" + glob
        why = model.input_rule(number) if model else None
        return ("input", why) if why else ("invariant", "default")


def classified(classifier, sites):
    """The --classify document of SITES: every Site with its class and rule ("hits"), the hits per class
    ("classes") and per lang.class ("kinds"), and the bad marks ("errors"). A row is one line, so all its hits share
    one class; the per-class counts add up to every hit."""
    rows, totals, kinds = [], dict.fromkeys(TRAP_CLASS_NAMES, 0), {}
    for site in sorted(sites, key=lambda s: (s.path, s.line, s.lang, s.kind, s.section)):
        cls, rule = classifier.classify(site.lang, site.path, site.line)
        rows.append({**site._asdict(), "class": cls, "rule": rule})
        totals[cls] += site.hits
        kinds.setdefault(f"{site.lang}.{site.kind}", dict.fromkeys(TRAP_CLASS_NAMES, 0))[cls] += site.hits
    return {"classes": totals, "kinds": dict(sorted(kinds.items())), "hits": rows,
            "errors": sorted(classifier.errors)}


def classify(repo, exported, names, all_modules=False):
    """Prints --classify's JSON for the report classes NAMES (None: every hit of the ratchet's scan), each over the
    scope --report counts it in (report_sites, --all-modules too). It compares nothing: exit 0, 1 when a
    `// trap-class:` mark is bad, 2 for an unknown report class."""
    if names is not None:
        kinds = report_kinds(names)
        if kinds is None:
            return 2
        sites = report_sites(repo, exported, kinds, all_modules)
    else:
        sites = scan_tree(repo, exported, sites=True).sites
    document = classified(TrapClassifier(repo), sites)
    print(json.dumps(document, indent=1, sort_keys=True))
    for error in document["errors"]:
        print("crash-ratchet: classify: " + error, file=sys.stderr)
    return 1 if document["errors"] else 0


# ---------------------------------------------------------------- notFatalUntil builds only go up
# Invariant.notFatalUntil(cond, id, build: N) reports until build N, then traps, like Chrome's
# base::NotFatalUntil::M<n>. Lowering N, or turning the site into check / dumpWillBeCheck, changes when users crash, so
# it needs a written reason. Local only: guardrails.py's `not-fatal-until-lowered` runs this on a push's changed files.
INVARIANT_CALL = re.compile(r"\bInvariant\s*\.\s*(?P<api>check|notFatalUntil|dumpWillBeCheck)\s*\(")
NOT_FATAL_UNTIL_ALLOW = re.compile(r"//\s*not-fatal-until-lowered-allow:\s*\S")
ARGUMENT_LABEL = re.compile(r"(\w+)\s*:(?!:)")
INTEGER = re.compile(r"\d[\d_]*")
INTEGER_MAX = {f"{sign}Int{bits}.max": (1 << ((int(bits) if bits else 64) - (0 if sign else 1))) - 1
               for sign in ("", "U") for bits in ("", "8", "16", "32", "64")}
# A build: argument that names a constant (`fatalFromBuild`, `Self.fatalFromBuild`); its last component is the name.
BUILD_NAME = re.compile(r"(?:[A-Za-z_]\w*\s*\.\s*)*(?P<name>[A-Za-z_]\w*)")
INVARIANT_CALL_LINES = 12  # an Invariant call's arguments may continue on this many lines


class InvariantSite(NamedTuple):
    api: str  # check, notFatalUntil or dumpWillBeCheck
    id: str  # the id argument's source text (`"daemon.frame.size"`, `.frameSize`), whitespace folded
    build: "str | None"  # the build: argument's source text, whitespace folded
    line: int  # 1-based line of `Invariant.`
    end: int  # 1-based line of the call's closing parenthesis


def invariant_arguments(text, start):
    """(top-level arguments (source text, stripped), offset past the `)`) of the call whose `(` is TEXT[START], or
    None when it does not close in TEXT. String literals and `//` comments never split or close it."""
    args, current, depth, i, n = [], [], 0, start + 1, len(text)
    while i < n:
        ch = text[i]
        if ch == '"':
            j = i + 1
            while j < n and text[j] not in '"\n':
                j += 2 if text[j] == "\\" else 1
            current.append(text[i:j + 1])
            i = j + 1
            continue
        if text.startswith("//", i):
            j = text.find("\n", i)
            i = n if j < 0 else j
            continue
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            if depth == 0:
                args.append("".join(current).strip())
                return [arg for arg in args if arg], i + 1
            depth -= 1
        elif ch == "," and depth == 0:
            args.append("".join(current).strip())
            current = []
            i += 1
            continue
        current.append(ch)
        i += 1
    return None


def invariant_sites(lines):
    """The Invariant.check / notFatalUntil / dumpWillBeCheck calls of LINES (one Swift file) whose id it can read:
    the `id:` argument, else the second unlabeled one (`notFatalUntil(cond, id, build: N)`)."""
    sites = []
    for index, line in enumerate(lines):
        if line.lstrip().startswith("//"):
            continue
        for match in INVARIANT_CALL.finditer(swift_code(line)):
            text = "\n".join([line[match.end() - 1:]] + lines[index + 1:index + INVARIANT_CALL_LINES])
            parsed = invariant_arguments(text, 0)
            if parsed is None:
                continue
            args, close = parsed
            labeled, unlabeled = {}, []
            for arg in args:
                label = ARGUMENT_LABEL.match(arg)
                if label:
                    labeled[label.group(1)] = " ".join(arg[label.end():].split())
                else:
                    unlabeled.append(arg)
            ident = labeled.get("id", unlabeled[1] if len(unlabeled) > 1 else None)
            if ident:
                sites.append(InvariantSite(match.group("api"), " ".join(ident.split()), labeled.get("build"),
                                           index + 1, index + 1 + text.count("\n", 0, close)))
    return sites


def integer_value(text):
    """The value of an integer literal (`1_300`) or a fixed-width `.max` (`UInt64.max`), or None."""
    text = text.strip()
    if INTEGER.fullmatch(text):
        return int(text.replace("_", ""))
    return INTEGER_MAX.get(re.sub(r"\s+", "", text))


def build_constant(name, files):
    """(value, path, 0-based line) of the first `let NAME[: Type] = <integer literal | Int.max form>` in FILES (a
    list of (path, lines), the call's own file first), or None. A `var` can change at run time, so it never resolves."""
    declaration = re.compile(r"\blet\s+" + re.escape(name) + r"\s*(?::\s*[\w.]+\s*)?=\s*(?P<value>[^;]+?)\s*$")
    for path, lines in files:
        for index, line in enumerate(lines):
            found = declaration.search(swift_code(line))
            if found:
                value = integer_value(found.group("value"))
                return None if value is None else (value, path, index)
    return None


class Build(NamedTuple):
    text: str  # the build: argument's source text
    value: "int | None"  # its value: a literal, an Int.max form, or a `let` constant (None: unknown)
    constant: "tuple | None"  # (path, 0-based line) of the constant it read, if it read one


def resolve_build(text, path, files):
    """TEXT (a build: argument in PATH) as a Build: a constant is read from PATH first, then the other FILES (one side
    of the push's changed Swift files, {path: lines})."""
    value = integer_value(text)
    if value is not None:
        return Build(text, value, None)
    name = BUILD_NAME.fullmatch(text.replace(" ", ""))
    if not name:
        return Build(text, None, None)
    order = [(path, files[path])] + [(p, lines) for p, lines in sorted(files.items()) if p != path]
    constant = build_constant(name.group("name"), order)
    if constant is None:
        return Build(text, None, None)
    return Build(text, constant[0], constant[1:])


def not_fatal_change(base, base_build, site, head_build):
    """Why the head call SITE lowers or removes the notFatalUntil build of the base call BASE it replaces, or None.
    BASE_BUILD and HEAD_BUILD are their resolved Builds."""
    shown = base.build if base_build.value is None or base.build == str(base_build.value) else \
        f"{base.build} ({base_build.value})"
    renamed = f" (renamed from {base.id})" if base.id != site.id else ""
    if site.api != "notFatalUntil":
        return f"build {shown} removed (now Invariant.{site.api}){renamed}"
    if head_build is None:
        return f"build {shown} removed (notFatalUntil without build:){renamed}"
    if base_build.value is None or head_build.value is None:
        if base_build.value is None and head_build.value is None and base.build == site.build:
            return None
        return (f"build {shown} -> {site.build}{renamed} (not an integer literal or a `let` constant of one: it cannot "
                "be shown not to be lower)")
    if head_build.value >= base_build.value:
        return None
    now = site.build if site.build == str(head_build.value) else f"{site.build} ({head_build.value})"
    return f"build {shown} -> {now}{renamed} (lowered)"


def invariant_pairs(base_lines, head_lines):
    """[(head site, base site or None)] of one file, and the base sites no head site took. A head call pairs by
    place, never by its id's text alone (two calls may share an id; Invariant.siteHash keys a site by id, file and
    line): a call that starts on an unchanged line pairs with the base call on that line; the calls that start in one
    changed hunk pair with that hunk's base calls, same id first, then in order (a renamed id)."""
    base_sites, head_sites = invariant_sites(base_lines), invariant_sites(head_lines)
    base_at = {site.line: site for site in base_sites}
    taken, pairs = set(), []
    matcher = difflib.SequenceMatcher(None, base_lines, head_lines, autojunk=False)
    for tag, i1, i2, j1, j2 in matcher.get_opcodes():
        heads = [site for site in head_sites if j1 < site.line <= j2]
        if tag == "equal":
            for site in heads:
                base = base_at.get(site.line - j1 + i1)
                taken.add(base)
                pairs.append((site, base))
            continue
        bases = [site for site in base_sites if i1 < site.line <= i2]
        paired = {}
        for site in heads:
            base = next((b for b in bases if b.id == site.id and b not in paired.values()), None)
            if base:
                paired[site] = base
        rest = [b for b in bases if b not in paired.values()]
        for site in heads:
            if site not in paired and rest:
                paired[site] = rest.pop(0)
        taken.update(paired.values())
        pairs.extend((site, paired.get(site)) for site in heads)
    return pairs, [site for site in base_sites if site not in taken]


def lowered_not_fatal_until(base_files, head_files):
    """[(path, line, why)] for each head Invariant call that lowers or removes the notFatalUntil build of the base
    call it replaces. BASE_FILES and HEAD_FILES map a path to its lines on each side (a push's changed Swift files).
    The rules (p10-stability-099: the ratchet refuses a lowered or removed N without a reason):
      - pairing (invariant_pairs): by place in the file's diff; a renamed id in the same hunk keeps the base build;
        a head call with no base call in its hunk takes a base call of the same id that left any changed file (it
        moved), else it is new and passes;
      - lowered: the paired head call is notFatalUntil with a lower build. A build is an integer literal, an
        `Int.max` form, or a `let` constant of one (read in the call's file first, then the other changed files), so
        lowering the constant behind an unchanged call is lowered too;
      - removed: the paired head call is check or dumpWillBeCheck, or notFatalUntil without build:;
      - unprovable: a build whose value it cannot read on a side, with a text the base call did not have (lowered);
      - a raised or unchanged build, a new call, and a base call that left with its code pass;
      - `// not-fatal-until-lowered-allow: <reason>` on the head call's first line or the line above it, or on the
        head constant's line or the line above it, passes the call."""
    pairs, vanished = [], []
    for path in sorted(set(base_files) | set(head_files)):
        file_pairs, gone = invariant_pairs(base_files.get(path, []), head_files.get(path, []))
        pairs.extend((path, site, base) for site, base in file_pairs if path in head_files)
        vanished.extend((path, site) for site in gone)
    found = []
    for path, site, base in pairs:
        base_path = path
        if base is None:
            moved = next((item for item in vanished if item[1].id == site.id), None)
            if moved is None:
                continue
            vanished.remove(moved)
            base_path, base = moved
        if base.api != "notFatalUntil" or base.build is None:
            continue
        lines = head_files[path]
        base_build = resolve_build(base.build, base_path, base_files)
        head_build = None if site.build is None else resolve_build(site.build, path, head_files)
        why = not_fatal_change(base, base_build, site, head_build)
        if not why:
            continue
        allow = [(lines, site.line - 1)]
        if head_build and head_build.constant:
            const_path, const_line = head_build.constant
            allow.append((head_files[const_path], const_line))
            if const_path != path or const_line != site.line - 1:
                why += f"; set at {const_path}:{const_line + 1}"
        if any(NOT_FATAL_UNTIL_ALLOW.search(text[i]) for text, at in allow for i in allow_lines(text, at)):
            continue
        found.append((path, site.line, f"Invariant.{site.api} {site.id}: {why}"))
    return found


REPORT_BASELINE_COMMENT = ("Report-only rows of crash_ratchet.py --report (p10-stability rule 1: no CI gates). Written "
                           "only by --report CLASS --update-report-baseline, which records a class's first row and "
                           "after that only lowers rows; the CI compare never reads this file.")


def update_report_baseline(repo, exported, names, all_modules):
    """Writes the report-baseline rows of the classes NAMES: a class's first row records the tree, after that each
    module's row only goes down. Exit 1 when a row stays above (it is printed; the rest is written), 2 for an
    unknown class or an index class without --all-modules (its index-module rows are the CI baseline's)."""
    kinds = report_kinds(names)
    if kinds is None:
        return 2
    narrow = [kind for kind in kinds if report_scope(kind, all_modules) == SCOPE_INDEX_MODULES]
    if narrow:
        print(f"crash-ratchet: the report baseline records {', '.join(narrow)} over every module only: pass "
              "--all-modules (the index modules' rows are crash-safety-baseline.json's)", file=sys.stderr)
        return 2
    counts, _ = report_counts(repo, exported, kinds, all_modules)
    data = load_baseline(REPORT_BASELINE) or {}
    held = []
    for kind in kinds:
        scope, found, row = report_scope(kind, all_modules), counts[kind], data.get(kind)
        if not isinstance(row, dict) or row.get("scope") != scope:
            modules = dict(found)
            print(f"crash-ratchet: report baseline: {kind} ({scope}) recorded at {sum(modules.values())}")
        else:
            known = row.get("modules", {})
            modules = {}
            for module in sorted(set(known) | set(found)):
                now, was = found.get(module, 0), known.get(module, 0)
                if now > was:
                    held.append(f"{kind} {module} {was} -> {now}")
                modules[module] = min(now, was)
        data[kind] = {"scope": scope, "modules": {m: n for m, n in sorted(modules.items()) if n}}
    data["_comment"] = REPORT_BASELINE_COMMENT
    with open(REPORT_BASELINE, "w") as out:
        json.dump(data, out, indent=1, sort_keys=True)
        out.write("\n")
    totals = ", ".join(f"{kind} {sum(data[kind]['modules'].values())}" for kind in kinds)
    print(f"crash-ratchet: report baseline written: {totals}")
    for line in held:
        print(f"crash-ratchet: not raised: {line}")
    if held:
        print(f"crash-ratchet: {len(held)} report row(s) stay above the report baseline; it never raises a row. "
              "Fix those hits.")
        return 1
    return 0


def load_allowlist():
    if not os.path.exists(ALLOWLIST):
        return {"banned": [], "allow": []}
    with open(ALLOWLIST, encoding="utf-8") as handle:
        data = json.load(handle)
    data.setdefault("banned", [])
    data.setdefault("allow", [])
    return data


def banned_kinds(lang):
    """Classes banned everywhere ("swift.<class>"); a "swift.<class>@<Module>" entry bans
    the class in that module only (see banned_in)."""
    return {entry.split(".", 1)[1] for entry in load_allowlist()["banned"]
            if entry.startswith(lang + ".") and "@" not in entry}


def banned_in(lang):
    """{(class, module)} of per-module bans: a module that reached zero keeps zero while
    the class stays a ratchet elsewhere."""
    return {tuple(entry.split(".", 1)[1].split("@", 1)) for entry in load_allowlist()["banned"]
            if entry.startswith(lang + ".") and "@" in entry}


def module_of(path):
    parts = path.split(os.sep)
    return parts[parts.index("Sources") + 1] if "Sources" in parts else path


def check_banned(banned_files):
    """Lines "swift <module>: <kind> <allowed> -> <hits>" for files over their allowlist
    entry, plus notes for entries that allow more than the file has."""
    allow = {}
    for entry in load_allowlist()["allow"]:
        lang, kind = entry["class"].split(".", 1)
        for field in ("path", "count", "reason", "reviewer"):
            if not entry.get(field):
                raise SystemExit(f"crash-ratchet: allowlist entry without {field}: {entry}")
        allow[(kind, entry["path"])] = allow.get((kind, entry["path"]), 0) + int(entry["count"])
    over, notes = {}, []
    for (kind, path), hits in sorted(banned_files.items()):
        allowed_hits = allow.get((kind, path), 0)
        if hits > allowed_hits:
            key = (module_of(path), kind)
            a, h = over.get(key, (0, 0))
            over[key] = (a + allowed_hits, h + hits)
            print(f"crash-ratchet: banned {kind} in {path}: {hits} hit(s), {allowed_hits} allowed by crash-allowlist.json")
    for (kind, path), allowed_hits in sorted(allow.items()):
        if banned_files.get((kind, path), 0) < allowed_hits:
            notes.append(f"crash-allowlist.json allows {allowed_hits} {kind} in {path} but it has "
                         f"{banned_files.get((kind, path), 0)}: lower the entry")
    return [f"swift {m}: {k} {a} -> {h}" for (m, k), (a, h) in sorted(over.items())], notes


def scan_env_writes(repo, exported):
    """Process environment writes in Swift sources beyond env-write-allowlist.json:
    ["<swift module> (<path>: <call> <allowed> -> <found>)", ...]. A crash-allow comment
    does not waive one; only the allowlist (with its reason) does."""
    sources = os.path.join(repo, "Packages/macOS/CmuxNext/Sources")
    allow = json.load(open(ENV_ALLOWLIST)) if os.path.exists(ENV_ALLOWLIST) else {}
    found = {}
    for path in tracked_files(repo, sources, exported):
        if not path.endswith(".swift") or not os.path.isfile(path):
            continue
        rel = os.path.relpath(path, repo)
        for line in open(path, encoding="utf-8").read().split("\n"):
            if line.lstrip().startswith("//"):
                continue
            for match in ENV_WRITE.finditer(swift_code(line)):
                call = match.group(1) or "environ="
                found[(rel, call)] = found.get((rel, call), 0) + 1
    over = {}
    for (rel, call), hits in sorted(found.items()):
        allowed_hits = allow.get(rel, {}).get(call, 0)
        if hits > allowed_hits:
            module = os.path.relpath(rel, "Packages/macOS/CmuxNext/Sources").split(os.sep)[0]
            over.setdefault(module, []).append(f"{rel}: {call} {allowed_hits} -> {hits}")
    return over


def rust_test_modules(paths):
    """(files, folders) that hold only test code: the targets of `#[cfg(test)] mod name;` declarations
    (`name.rs` or `name/mod.rs`, or a `#[path]`) in PATHS, and the folder of each such module, which holds its
    own submodules. 2026-10-24: shell_integration's `#[cfg(all(test, unix))] mod test_pty;` and `mod fork_watch;`
    counted 22 test unwraps and expects as cmux-tui-core's own, because only `tests.rs`, `*_tests.rs`,
    `*_test.rs` and inline `mod x { }` blocks were cut."""
    files, folders = set(), set()
    for path in paths:
        if not path.endswith(".rs") or not os.path.isfile(path):
            continue
        text = open(path, encoding="utf-8", errors="replace").read()
        if "mod " not in text:
            continue
        here, name = os.path.split(path)
        # A mod.rs, lib.rs or main.rs owns its folder; any other file foo.rs owns foo/.
        owner = here if name in ("mod.rs", "lib.rs", "main.rs") else os.path.join(here, name[:-3])
        for decl in TEST_MOD_DECL.finditer(text):
            attr = RUST_PATH_ATTR.search(decl.group("attrs") or "")
            if attr:
                target = os.path.normpath(os.path.join(here, attr.group("path")))
                files.add(target)
                folders.add(os.path.dirname(target) if os.path.basename(target) == "mod.rs" else target[:-3])
                continue
            module = os.path.join(owner, decl.group("name"))
            files.update((module + ".rs", os.path.join(module, "mod.rs")))
            folders.add(module)
    return files, folders


def scan_rust(repo, scan, exported):
    crates = os.path.join(repo, "cmux-tui/crates")
    skipped_dirs = {"target", "tests", "benches", "examples", "node_modules", "fixtures"}
    paths = tracked_files(repo, crates, exported)
    test_files, test_folders = rust_test_modules(paths)
    for path in paths:
        dirpath, name = os.path.split(path)
        parts = os.path.relpath(dirpath, crates).split(os.sep)
        if skipped_dirs.intersection(parts) or os.sep + "src" not in dirpath or not os.path.isfile(path):
            continue
        if not name.endswith(".rs") or name in ("tests.rs",) or name.endswith("_tests.rs") or name.endswith("_test.rs"):
            continue
        if path in test_files or any(path.startswith(folder + os.sep) for folder in test_folders):
            continue
        rel = os.path.relpath(path, crates).split(os.sep)[0]  # the crate
        text = open(path, encoding="utf-8", errors="replace").read()
        # Inline test modules (`#[cfg(test)] mod x {`) are cut; a
        # `#[cfg(test)] mod x;` declaration is not code.
        inline = INLINE_TESTS.search(text)
        lines = (text if not inline else text[:inline.start()]).split("\n")
        for index, line in enumerate(lines):
            stripped = line.lstrip()
            if stripped.startswith("//"):
                continue
            is_allowed = allowed(lines, index)
            code = line.split("//", 1)[0] if '"' not in line else line
            for kind, pattern in RUST.items():
                hits = len(pattern.findall(code))
                if hits:
                    scan.add(is_allowed, "rust", kind, rel, line, hits, os.path.relpath(path, repo), index + 1)


# The baseline's path in a tree (a checkout, or a git archive export of a ref).
BASELINE_REL = "scripts/cmux-next/crash-safety-baseline.json"


def load_baseline(path):
    """The baseline file's data, or None when the file does not exist."""
    if not os.path.exists(path):
        return None
    with open(path) as f:
        return json.load(f)


def baseline_rows(data):
    """{(section, lang, class, module): hits} of baseline DATA, counted and waived rows."""
    rows = {}
    counted = {lang: kinds for lang, kinds in data.items() if lang != WAIVED}
    for section, langs in ((COUNTED, counted), (WAIVED, data.get(WAIVED, {}))):
        for lang, kinds in langs.items():
            for kind, modules in kinds.items():
                for module, hits in modules.items():
                    if hits:
                        rows[(section, lang, kind, module)] = hits
    return rows


def scan_rows(scan):
    return baseline_rows({**scan.counts, WAIVED: scan.waived})


def baseline_data(rows):
    """Baseline file data for ROWS (the inverse of baseline_rows)."""
    data = {"swift": {}, "rust": {}, WAIVED: {"swift": {}, "rust": {}}}
    for (section, lang, kind, module), hits in sorted(rows.items()):
        if hits:
            target = data[WAIVED] if section == WAIVED else data
            target.setdefault(lang, {}).setdefault(kind, {})[module] = hits
    return data


def row_label(row):
    section, lang, kind, module = row
    return f"{lang} {module}: {kind}{'.waived' if section == WAIVED else ''}"


def proven_moves(old, new):
    """{(section, lang, class, from module, to module): hits}: hits whose exact (stripped) line
    left one module between the scans OLD and NEW and is in another module in NEW. Only the
    same line in the same section and class moves: an edited, newly waived or new hit does not."""
    by_line = {}
    for which, scan in ((0, old), (1, new)):
        for (section, lang, kind, module, line), hits in scan.lines.items():
            by_line.setdefault((section, lang, kind, line), ({}, {}))[which][module] = hits
    moves = {}
    for (section, lang, kind, _), (before, after) in sorted(by_line.items()):
        left = [[m, n - after.get(m, 0)] for m, n in sorted(before.items()) if n > after.get(m, 0)]
        came = [[m, n - before.get(m, 0)] for m, n in sorted(after.items()) if n > before.get(m, 0)]
        for target in came:
            for source in left:
                hits = min(target[1], source[1])
                if hits:
                    key = (section, lang, kind, source[0], target[0])
                    moves[key] = moves.get(key, 0) + hits
                    target[1] -= hits
                    source[1] -= hits
    return moves


def carry_moves(base_rows, risen, moves):
    """(allowance, carried): each row's allowed count, BASE_ROWS with proven MOVES carried into
    the RISEN rows ({row: its new count}) as far as they rose. A move carries no more than the
    source module's base row holds, so a hit the base was already red on does not move; the
    source row's allowance goes down by what it carries. carried: [(from row, to row, hits)]."""
    allowance = dict(base_rows)
    carried = []
    for row in sorted(risen):
        section, lang, kind, _ = row
        need = risen[row] - allowance.get(row, 0)
        for (s, l, k, source, target), hits in sorted(moves.items()):
            if need <= 0:
                break
            if (s, l, k, target) != row:
                continue
            source_row = (s, l, k, source)
            hits = min(need, hits, allowance.get(source_row, 0))
            if hits:
                allowance[source_row] -= hits
                allowance[row] = allowance.get(row, 0) + hits
                need -= hits
                carried.append((source_row, row, hits))
    return allowance, carried


def print_moves(carried):
    for (section, lang, kind, source), (_, _, _, target), hits in carried:
        suffix = ".waived" if section == WAIVED else ""
        print(f"crash-ratchet: moved: {lang} {source} -> {target}: {kind}{suffix} {hits} (the same lines)")


def export_ref(repo, ref, into):
    """git archive of REF's scanned paths (TREE_PATHS) from the checkout REPO into INTO."""
    try:
        subprocess.run(["git", "-C", repo, "rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}"],
                       check=True, capture_output=True)
    except (OSError, subprocess.CalledProcessError):
        refuse(f"--base {ref} is not a commit in {repo}")
    paths = [p for p in TREE_PATHS if subprocess.run(
        ["git", "-C", repo, "cat-file", "-e", f"{ref}:{p}"], capture_output=True).returncode == 0]
    if paths:
        archive = subprocess.run(["git", "-C", repo, "archive", "--format=tar", ref, *paths],
                                 check=True, capture_output=True).stdout
        subprocess.run(["tar", "-x", "-C", into], input=archive, check=True)


def update_baseline(repo, scan, base_ref, record_waivers):
    """Writes the baseline: every row lowered to SCAN's count, never raised, except waived rows
    with RECORD_WAIVERS and rows a proven move from BASE_REF carries. Exit 1 when a row stays
    above the baseline (it is printed; the rest is written)."""
    current = scan_rows(scan)
    moves = {}
    if base_ref:
        with tempfile.TemporaryDirectory(prefix="crash-ratchet-base-") as tree:
            export_ref(repo, base_ref, tree)
            base = load_baseline(os.path.join(tree, BASELINE_REL))
            if base is None:
                refuse(f"--base {base_ref} has no {BASELINE_REL} to carry rows from")
            base_rows = baseline_rows(base)
            if any(n > base_rows.get(row, 0) for row, n in current.items()):
                moves = proven_moves(scan_tree(tree, True), scan)
    else:
        existing = load_baseline(BASELINE)
        if existing is None:
            # The first baseline records the tree as it is; after that it only goes down.
            base_rows = dict(current)
        else:
            base_rows = baseline_rows(existing)
    risen = {row: n for row, n in current.items()
             if n > base_rows.get(row, 0) and not (record_waivers and row[0] == WAIVED)}
    allowance, carried = carry_moves(base_rows, risen, moves)
    written, held = {}, []
    for row, n in sorted(current.items()):
        limit = allowance.get(row, 0)
        if record_waivers and row[0] == WAIVED:
            if n > base_rows.get(row, 0):
                print(f"crash-ratchet: waiver recorded: {row_label(row)} {base_rows.get(row, 0)} -> {n}")
            written[row] = n
        elif n > limit:
            written[row] = limit
            held.append(f"{row_label(row)} {limit} -> {n}")
        else:
            written[row] = n
    print_moves(carried)
    with open(BASELINE, "w") as out:
        json.dump(baseline_data(written), out, indent=1, sort_keys=True)
        out.write("\n")
    totals = {}
    for (section, lang, kind, _), hits in written.items():
        key = f"{lang}.{kind}{'.waived' if section == WAIVED else ''}"
        totals[key] = totals.get(key, 0) + hits
    print("crash-ratchet: baseline written: " + ", ".join(f"{k} {v}" for k, v in sorted(totals.items())))
    if not held:
        return 0
    for line in held:
        print(f"crash-ratchet: not raised: {line}")
    print(f"crash-ratchet: {len(held)} row(s) stay above the baseline; --update-baseline never raises a row. "
          "Fix those hits. A reviewed `// crash-allow: <reason>` is recorded with --record-waivers; a hit "
          "that moved from another module carries its row with --base <the base commit, e.g. "
          "origin/feat-cmux-next>.")
    return 1


def baseline_against(repo, exported, base_tree):
    """Judges this baseline against BASE_TREE's (an exported tree): a counted row may only go
    down, or rise by a proven move; a waived row above the base's is a recorded waiver (printed,
    not a failure). Exit 1 when a counted row rose."""
    base = load_baseline(os.path.join(base_tree, BASELINE_REL))
    if base is None:
        print(f"crash-ratchet: baseline ok (the base has no {BASELINE_REL} to compare with)")
        return 0
    head_rows = baseline_rows(load_baseline(BASELINE) or {})
    base_rows = baseline_rows(base)
    if WAIVED not in base:
        # The base predates the waived section: this baseline records it for the first time.
        first = {row: n for row, n in head_rows.items() if row[0] == WAIVED}
        print(f"crash-ratchet: note: the base's baseline has no {WAIVED} section; this one records it for the "
              f"first time ({len(first)} rows, {sum(first.values())} waived hits)")
        head_rows = {row: n for row, n in head_rows.items() if row[0] != WAIVED}
    risen = {row: n for row, n in head_rows.items() if n > base_rows.get(row, 0)}
    moves = proven_moves(scan_tree(base_tree, True), scan_tree(repo, exported)) if risen else {}
    allowance, carried = carry_moves(base_rows, risen, moves)
    print_moves(carried)
    raised = 0
    for row, n in sorted(head_rows.items()):
        limit, was = allowance.get(row, 0), base_rows.get(row, 0)
        if n <= limit:
            continue
        after = f" ({limit} after the move)" if limit != was else ""
        text = f"{row_label(row)} base {was}, head {n}{after}"
        if row[0] == WAIVED:
            print(f"crash-ratchet: waiver recorded: {text}")
        else:
            raised += 1
            print(f"crash-ratchet: baseline raised: {text}")
    if raised:
        print(f"crash-ratchet: {raised} counted baseline row(s) rose above the base's; the baseline may only go "
              "down. Fix the hits instead (a hit that moved from another module carries its row: "
              "crash_ratchet.py --update-baseline --base <the base commit>).")
        return 1
    print("crash-ratchet: baseline ok")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", default=os.path.abspath(os.path.join(HERE, "../..")))
    parser.add_argument("--update-baseline", action="store_true",
                        help="lower the baseline to the tree's counts; never raises a row")
    parser.add_argument("--record-waivers", action="store_true",
                        help="--update-baseline, and also raise the waived rows to the tree's count")
    parser.add_argument("--base", metavar="REF",
                        help="with --update-baseline: rows of hits that moved to another module since REF move too")
    parser.add_argument("--baseline-against", metavar="BASE_TREE",
                        help="judge this baseline against BASE_TREE's (an exported tree); no tree check")
    parser.add_argument("--exported-tree", action="store_true",
                        help="REPO holds only tracked files (git archive): scan every file, no git needed")
    parser.add_argument("--report", metavar="CLASS[,CLASS]",
                        help="print these report classes' counts per module and hit sites as JSON ("
                        + ", ".join(REPORT_CLASSES) + "); compares nothing")
    parser.add_argument("--all-modules", action="store_true",
                        help="with --report: count " + " and ".join(REPORT_INDEX)
                        + " in every module, not only the index modules")
    parser.add_argument("--update-report-baseline", action="store_true",
                        help="with --report: lower the classes' rows in crash-safety-report-baseline.json "
                        "(a class's first row records the tree)")
    parser.add_argument("--classify", action="store_true",
                        help="print every hit (of --report's classes, else of the ratchet's scan) with its trap class "
                        "(input or invariant) and the rule that gave it, as JSON; compares nothing")
    opts = parser.parse_args()
    if opts.report is not None or opts.classify:
        if opts.update_baseline or opts.record_waivers or opts.base or opts.baseline_against:
            parser.error("--report and --classify only report: they do not go with --update-baseline, --base or "
                         "--baseline-against")
        if opts.classify and opts.update_report_baseline:
            parser.error("--classify does not write the report baseline")
        if opts.all_modules and opts.report is None:
            parser.error("--all-modules goes with --report")
        if opts.classify:
            return classify(opts.repo, opts.exported_tree, opts.report, opts.all_modules)
        if opts.update_report_baseline:
            return update_report_baseline(opts.repo, opts.exported_tree, opts.report, opts.all_modules)
        return report(opts.repo, opts.exported_tree, opts.report, opts.all_modules)
    if opts.all_modules or opts.update_report_baseline:
        parser.error("--all-modules and --update-report-baseline go with --report")
    updating = opts.update_baseline or opts.record_waivers
    if opts.base and not updating:
        parser.error("--base goes with --update-baseline or --record-waivers")
    if opts.base and opts.exported_tree:
        parser.error("--base reads REF from git: REPO must be a checkout")
    if opts.baseline_against and updating:
        parser.error("--baseline-against judges the baseline; it does not write it")
    if opts.baseline_against:
        return baseline_against(opts.repo, opts.exported_tree, opts.baseline_against)
    scan = scan_tree(opts.repo, opts.exported_tree)
    if updating:
        return update_baseline(opts.repo, scan, opts.base, opts.record_waivers)
    counts, waived = scan.counts, scan.waived
    baseline = load_baseline(BASELINE) or {}
    grown, shrunk = [], 0
    for found, known_section, suffix in ((counts, baseline, ""), (waived, baseline.get(WAIVED, {}), ".waived")):
        for lang, kinds in found.items():
            for kind, files in kinds.items():
                known = known_section.get(lang, {}).get(kind, {})
                for rel, hits in sorted(files.items()):
                    if hits > known.get(rel, 0):
                        grown.append(f"{lang} {rel}: {kind}{suffix} {known.get(rel, 0)} -> {hits}")
            for kind, files in known_section.get(lang, {}).items():
                if kind in banned_kinds(lang):
                    continue
                files = {m: n for m, n in files.items() if (kind, m) not in banned_in(lang)}
                for rel, hits in files.items():
                    if found[lang].get(kind, {}).get(rel, 0) < hits:
                        shrunk += 1
    banned_over, banned_notes = check_banned(scan.banned_files)
    grown.extend(banned_over)
    for line in banned_notes:
        print("crash-ratchet: note: " + line)
    env_over = scan_env_writes(opts.repo, opts.exported_tree)
    for module, details in sorted(env_over.items()):
        hits = sum(int(d.rsplit(" ", 1)[1]) for d in details)
        grown.append(f"swift {module}: env_write 0 -> {hits}")
        for detail in details:
            print("crash-ratchet: env_write " + detail + " (not in scripts/cmux-next/env-write-allowlist.json)")
    for line in grown:
        print("crash-ratchet: " + line)
    if grown:
        print(f"crash-ratchet: {len(grown)} module(s) or crate(s) gained a crash-class hit (plans/cmux-next/crash-elimination.md). "
              "Remove it. A reviewed `// crash-allow: <reason>` still counts, as a waived hit: record it with "
              "--record-waivers (the module's <class>.waived row goes up; CI annotates every recorded waiver). "
              "A hit that moved from another module carries its row with --update-baseline --base <the base "
              "commit>. --update-baseline never raises a row. Banned classes: only a reviewed "
              "scripts/cmux-next/crash-allowlist.json entry; env_write: never, pass the value in the child's "
              "spawn environment instead.")
        return 1
    note = f"; {shrunk} count(s) went down: run scripts/cmux-next/crash_ratchet.py --update-baseline" if shrunk else ""
    print(f"crash-ratchet: ok{note}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
