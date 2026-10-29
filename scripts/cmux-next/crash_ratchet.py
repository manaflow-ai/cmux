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
    env_write         setenv( / unsetenv( / putenv( / an assignment to environ, in Sources
                      and in the app package's Tests. Not in
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

Usage: crash_ratchet.py [--repo ROOT] [--exported-tree]
                        [--update-baseline [--record-waivers] [--base REF] | --baseline-against BASE_TREE]
Exit 1 when a module or crate gained a hit or a waived hit; with --update-baseline, when
a row stays above the baseline; with --baseline-against, when a counted row rose.
"""
import argparse
import subprocess
import json
import os
import re
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
BASELINE = os.path.join(HERE, "crash-safety-baseline.json")
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


class Scan:
    """One tree's hits: counted and waived ({lang: {class: {module: hits}}}), banned hits per
    file {(class, repo-relative path): hits}, and every counted or waived hit by its line
    {(section, lang, class, module, stripped line): hits}, which proves a move between modules."""

    def __init__(self):
        self.counts = {"swift": {}, "rust": {}}
        self.waived = {"swift": {}, "rust": {}}
        self.banned_files = {}
        self.lines = {}

    def add(self, waived, lang, kind, module, line, hits):
        section = self.waived if waived else self.counts
        section[lang].setdefault(kind, {}).setdefault(module, 0)
        section[lang][kind][module] += hits
        key = (WAIVED if waived else COUNTED, lang, kind, module, line.strip())
        self.lines[key] = self.lines.get(key, 0) + hits


def scan_tree(repo, exported):
    """The Swift and Rust hits of the tree at REPO (a checkout, or an exported tree)."""
    scan = Scan()
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
                        continue
                    scan.add(is_allowed, "swift", kind, rel, line, hits)


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


ENV_WRITE_ROOTS = ("Packages/macOS/CmuxNext/Sources", "Packages/macOS/CmuxNext/Tests")


def scan_env_writes(repo, exported):
    """Process environment writes in Swift sources and tests beyond env-write-allowlist.json:
    {"<swift module>": ["<path>: <call> <allowed> -> <found>", ...]}. A crash-allow comment
    does not waive one; only the allowlist (with its reason) does. Tests count too: a test
    that writes the environment after GhosttyRuntime.shared ran ghostty_init frees the environ
    copy libghostty reads, and the suite's process crashes (GhosttyImageStorageLimitTests,
    signal 11 in ghostty_config_finalize, 2026-10-29). A test passes the value as an argument
    instead (GhosttyRuntime.loadConfig(configFile:))."""
    allow = json.load(open(ENV_ALLOWLIST)) if os.path.exists(ENV_ALLOWLIST) else {}
    found = {}
    paths = [path for root in ENV_WRITE_ROOTS if os.path.isdir(os.path.join(repo, root))
             for path in tracked_files(repo, os.path.join(repo, root), exported)]
    for path in paths:
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
            parts = os.path.relpath(rel, "Packages/macOS/CmuxNext").split(os.sep)
            module = parts[1] if parts[0] == "Sources" else "/".join(parts[:2])
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
                    scan.add(is_allowed, "rust", kind, rel, line, hits)


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
    opts = parser.parse_args()
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
