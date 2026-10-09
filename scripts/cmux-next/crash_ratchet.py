#!/usr/bin/env python3
"""Crash-class ratchet for cmux-next (plans/cmux-next/crash-elimination.md).

Counts the code patterns that can end the app or the daemon, per class and
per Swift module or Rust crate (so code can move between files), and compares
them with crash-safety-baseline.json next to this script. A module or crate
may never gain a hit of a class; fixing hits is free (run
--update-baseline to lower the baseline in the same commit). A line with a
reviewed `// crash-allow: <reason>` (Swift) or `// crash-allow: <reason>`
(Rust), on the line or the comment line above, does not count.

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
                      any; else the module's), or with a `default:` argument, does not count
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

Usage: crash_ratchet.py [--repo ROOT] [--update-baseline]
Exit 1 when a module or crate gained a hit.
"""
import argparse
import subprocess
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
BASELINE = os.path.join(HERE, "crash-safety-baseline.json")
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


def bracket_kind(text):
    """"dict" or "array" for a type or literal that starts with "[" (a top-level ":"
    makes a dictionary, `[:]` included) or with Dictionary/Array; else None."""
    if text.startswith("Dictionary"):
        return "dict"
    if text.startswith("Array"):
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
    dicts, others = set(), set()
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
            (dicts if bracket_kind(text) == "dict" else others).add(name)
    return dicts, others


def index_hits(code, dictionaries=frozenset()):
    """Computed subscripts in CODE that can trap (see index_subscript). DICTIONARIES:
    names the module declares only as dictionaries."""
    hits = 0
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
        local, module = dictionaries if isinstance(dictionaries, tuple) else (dictionaries, dictionaries)
        qualified = "." in chain and not chain.startswith("self.")
        if base in (module if qualified else local):
            continue
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


def allowed(lines, index):
    return bool(ALLOW.search(lines[index]) or (index > 0 and ALLOW.search(lines[index - 1])))


def tracked_files(repo, root):
    """Files under ROOT that git tracks (absolute paths, sorted). Ignored and untracked
    files never count: build or sync output in a per-job tree made the ratchet red while
    every tracked file equalled the tip (2026-10-07). Outside a git checkout every file
    under ROOT is scanned, with a warning."""
    rel = os.path.relpath(root, repo)
    try:
        out = subprocess.run(["git", "-C", repo, "ls-files", "-z", "--", rel],
                             check=True, capture_output=True).stdout.decode("utf-8", "replace")
        return sorted(os.path.join(repo, p) for p in out.split("\0") if p)
    except (OSError, subprocess.CalledProcessError) as error:
        print(f"crash-ratchet: WARNING: {repo} is not a git checkout ({error}); scanning every file under {rel}, "
              "ignored build output included", file=sys.stderr)
        return sorted(os.path.join(d, n) for d, _, names in os.walk(root) for n in names)


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


def module_dictionaries(repo):
    """{index module: names it declares as dictionaries and never as arrays}."""
    declared = {}
    for root in swift_source_roots(repo):
        sources = os.path.join(repo, root)
        for path in tracked_files(repo, sources):
            module = os.path.relpath(path, sources).split(os.sep)[0]
            if module not in INDEX_MODULES or not path.endswith(".swift") or not os.path.isfile(path):
                continue
            dicts, arrays = collection_names(open(path, encoding="utf-8", errors="replace").read().split("\n"))
            entry = declared.setdefault(module, (set(), set()))
            entry[0].update(dicts)
            entry[1].update(arrays)
    return {module: frozenset(d - a) for module, (d, a) in declared.items()}


def file_dictionaries(lines, module_dicts):
    """Names that LINES (one file) subscript as dictionaries: a name the file declares
    only as a dictionary, or one it does not declare at all that its module declares only
    as a dictionary (a property from the type's main file used in an extension file). A
    same-named array or inferred local in another file of the module no longer hides a
    dictionary declared in this one; one declared any other way in this file still counts."""
    dicts, others = collection_names(lines)
    declared = dicts | others
    return (frozenset((dicts - others) | {name for name in module_dicts if name not in declared}),
            frozenset(module_dicts))


def scan_swift(repo, counts, banned_files=None):
    """Ratchet counts per module into COUNTS; hits of banned classes per file (crash-allow
    ignored) into BANNED_FILES {(kind, repo-relative path): hits}."""
    banned = banned_kinds("swift")
    banned_modules = banned_in("swift")
    dictionaries = module_dictionaries(repo)
    for root in swift_source_roots(repo):
        sources = os.path.join(repo, root)
        for path in tracked_files(repo, sources):
            name = os.path.basename(path)
            if not name.endswith(".swift") or not os.path.isfile(path):
                continue
            rel = os.path.relpath(path, sources).split(os.sep)[0]  # the Swift module
            lines = open(path, encoding="utf-8", errors="replace").read().split("\n")
            file_dicts = file_dictionaries(lines, dictionaries.get(rel, frozenset())) if rel in INDEX_MODULES else frozenset()
            for index, line in enumerate(lines):
                if line.lstrip().startswith("//"):
                    continue
                is_allowed = allowed(lines, index)
                for kind, hits in swift_line_hits(lines, index, rel, file_dicts).items():
                    if kind in banned or (kind, rel) in banned_modules:
                        if banned_files is not None:
                            key = (kind, os.path.relpath(path, repo))
                            banned_files[key] = banned_files.get(key, 0) + hits
                        continue
                    if is_allowed:
                        continue
                    counts.setdefault(kind, {}).setdefault(rel, 0)
                    counts[kind][rel] += hits


def load_allowlist():
    if not os.path.exists(ALLOWLIST):
        return {"banned": [], "allow": []}
    data = json.load(open(ALLOWLIST))
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


def scan_env_writes(repo):
    """Process environment writes in Swift sources beyond env-write-allowlist.json:
    ["<swift module> (<path>: <call> <allowed> -> <found>)", ...]. A crash-allow comment
    does not waive one; only the allowlist (with its reason) does."""
    sources = os.path.join(repo, "Packages/macOS/CmuxNext/Sources")
    allow = json.load(open(ENV_ALLOWLIST)) if os.path.exists(ENV_ALLOWLIST) else {}
    found = {}
    for path in tracked_files(repo, sources):
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


def scan_rust(repo, counts):
    crates = os.path.join(repo, "cmux-tui/crates")
    skipped_dirs = {"target", "tests", "benches", "examples", "node_modules", "fixtures"}
    for path in tracked_files(repo, crates):
        dirpath, name = os.path.split(path)
        parts = os.path.relpath(dirpath, crates).split(os.sep)
        if skipped_dirs.intersection(parts) or os.sep + "src" not in dirpath or not os.path.isfile(path):
            continue
        if not name.endswith(".rs") or name in ("tests.rs",) or name.endswith("_tests.rs") or name.endswith("_test.rs"):
            continue
        rel = os.path.relpath(path, crates).split(os.sep)[0]  # the crate
        text = open(path, encoding="utf-8", errors="replace").read()
        # Inline test modules (`#[cfg(test)] mod x {`) are cut; a
        # `#[cfg(test)] mod x;` declaration is not code.
        inline = INLINE_TESTS.search(text)
        lines = (text if not inline else text[:inline.start()]).split("\n")
        for index, line in enumerate(lines):
            stripped = line.lstrip()
            if stripped.startswith("//") or allowed(lines, index):
                continue
            code = line.split("//", 1)[0] if '"' not in line else line
            for kind, pattern in RUST.items():
                hits = len(pattern.findall(code))
                if hits:
                    counts.setdefault(kind, {}).setdefault(rel, 0)
                    counts[kind][rel] += hits


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", default=os.path.abspath(os.path.join(HERE, "../..")))
    parser.add_argument("--update-baseline", action="store_true")
    opts = parser.parse_args()
    counts = {"swift": {}, "rust": {}}
    banned_files = {}
    scan_swift(opts.repo, counts["swift"], banned_files)
    scan_rust(opts.repo, counts["rust"])
    if opts.update_baseline:
        with open(BASELINE, "w") as out:
            json.dump(counts, out, indent=1, sort_keys=True)
            out.write("\n")
        totals = {f"{lang}.{kind}": sum(files.values()) for lang, kinds in counts.items() for kind, files in kinds.items()}
        print("crash-ratchet: baseline written: " + ", ".join(f"{k} {v}" for k, v in sorted(totals.items())))
        return 0
    baseline = json.load(open(BASELINE)) if os.path.exists(BASELINE) else {}
    grown, shrunk = [], 0
    for lang, kinds in counts.items():
        for kind, files in kinds.items():
            known = baseline.get(lang, {}).get(kind, {})
            for rel, hits in sorted(files.items()):
                if hits > known.get(rel, 0):
                    grown.append(f"{lang} {rel}: {kind} {known.get(rel, 0)} -> {hits}")
        for kind, files in baseline.get(lang, {}).items():
            if kind in banned_kinds(lang):
                continue
            files = {m: n for m, n in files.items() if (kind, m) not in banned_in(lang)}
            for rel, hits in files.items():
                if counts[lang].get(kind, {}).get(rel, 0) < hits:
                    shrunk += 1
    banned_over, banned_notes = check_banned(banned_files)
    grown.extend(banned_over)
    for line in banned_notes:
        print("crash-ratchet: note: " + line)
    env_over = scan_env_writes(opts.repo)
    for module, details in sorted(env_over.items()):
        hits = sum(int(d.rsplit(" ", 1)[1]) for d in details)
        grown.append(f"swift {module}: env_write 0 -> {hits}")
        for detail in details:
            print("crash-ratchet: env_write " + detail + " (not in scripts/cmux-next/env-write-allowlist.json)")
    for line in grown:
        print("crash-ratchet: " + line)
    if grown:
        print(f"crash-ratchet: {len(grown)} module(s) or crate(s) gained a crash-class hit (plans/cmux-next/crash-elimination.md). "
              "Remove it, or add a reviewed `// crash-allow: <reason>` (banned classes: only a reviewed "
              "scripts/cmux-next/crash-allowlist.json entry; env_write: never, pass the value in the child's "
              "spawn environment instead).")
        return 1
    note = f"; {shrunk} count(s) went down: run scripts/cmux-next/crash_ratchet.py --update-baseline" if shrunk else ""
    print(f"crash-ratchet: ok{note}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
