#!/usr/bin/env python3
"""Tests that can't fail: no assertion, always skipped, or asserting only on mocks.

    vacuous_tests.py                          # the whole tree, one JSON report on stdout
    vacuous_tests.py --diff BASE [--head H]   # only tests in files BASE...H changed (a PR job)
    vacuous_tests.py --root cmux-tui --root tests   # other roots than the defaults
    vacuous_tests.py --min-confidence medium --strict   # exit 1 when a finding at or above it remains
    vacuous_tests.py --files a.rs b.test.ts   # explicit paths

Scans, statically and without building anything:

  rust    `#[test]` / `#[tokio::test]` fns in *.rs
  ts      `test(` / `it(` calls in *.test.ts(x) / *.test.js(x)
  swift   XCTest `func test*()` and Swift Testing `@Test` funcs in *.swift
  python  `test_*` functions and methods in tests/**/*.py (through `ast`)

Default roots: cmux-tui Native Packages webviews tests (those present). node_modules,
vendor, target, .build and dist trees are skipped.

Kinds:

  no_assertion   the body holds no assert*/expect/XCTAssert/#expect/#require/panic!/unwrap/
                 expect(/raise/throw, no `?` or `try` where an error fails the test, and no call
                 to a helper that asserts. A helper asserts when its name holds assert, check,
                 expect, verify, fail, require or ensure, or when a function of that name
                 defined in the same file, its folder or the parent folder (or in at most
                 five files of the language, anywhere) itself asserts.
                 confidence high: the body calls nothing at all (empty, or only bindings).
                 confidence medium: it calls code, so it fails only if that code panics/throws.
  skipped        always skipped: `#[ignore]` with no reason, `test.skip`/`it.skip`/`xit`/
                 `test.fixme`, a top-level `describe.skip` (an empty test in a `describe.skip`
                 inside a block is a runtime skip marker and not reported), `@Test(.disabled)` (high with no reason, medium with one),
                 `.enabled(if: false)`, `throw XCTSkip(...)` at the body's top level,
                 `@unittest.skip`/`@pytest.mark.skip`, `self.skipTest` at the top level.
  mocks_only     every assertion line is about mock calls: a mock framework's call assertion
                 (toHaveBeenCalled*, assert_called*, .times(), .mock.calls), or a call count
                 (call_count, callCount, .calls) on a line that names a mock/spy/fake/stub.
                 A heuristic: always confidence low.

Prints one JSON report:

    {"roots": [...], "diff": null | {"base": B, "head": H, "files": N},
     "scanned": {"rust": N, ...},
     "summary": {"by_language": {"rust": {"no_assertion": N, ...}}, "by_kind": {...},
                 "by_confidence": {...}, "total": N},
     "findings": [{"path", "line", "name", "language", "kind", "confidence", "why"}]}

Test: tests/test_ci_vacuous_tests.py.
"""
from __future__ import annotations

import argparse
import ast
import json
import re
import subprocess
import sys
from collections import Counter, defaultdict
from pathlib import Path

DEFAULT_ROOTS = ("cmux-tui", "Native", "Packages", "webviews", "tests")
SKIP_DIRS = {"node_modules", "vendor", "target", ".build", "dist", ".git", "build", "DerivedData"}
CONF_RANK = {"low": 0, "medium": 1, "high": 2}
# A cross-file helper counts only when few files of the language define its name: a common name
# (`run`, `setup`) asserting somewhere says nothing about the one a test calls.
GLOBAL_HELPER_MAX_FILES = 5

HELPER_NAME = re.compile(r"assert|check|expect|verify|fail|require|ensure", re.I)
NOT_HELPER = re.compile(r"checkout|checkbox|checked|expected|unchecked", re.I)
CALL = re.compile(r"\b([A-Za-z_]\w*)\s*(?:!\s*[(\[{]|\(|::<)")
SWIFT_TRAILING = re.compile(r"\b([A-Za-z_]\w*)\s*\{")
SWIFT_KEYWORDS = {
    "if", "else", "guard", "for", "while", "repeat", "do", "catch", "switch", "defer", "in",
    "get", "set", "willSet", "didSet", "return", "case", "default", "where", "async", "throws",
}

# A mock framework's own call assertions.
MOCK = re.compile(
    r"toHaveBeenCalled\w*|toBeCalled\w*|toHaveBeenLastCalledWith|toHaveBeenNthCalledWith|"
    r"assert_called\w*|assert_not_called|assert_any_call|assert_has_calls|\.mock\.calls\b|"
    r"\.times\s*\(|\.call_args\b"
)
# A call count read off something the line itself names as a double. Without the double's name
# (`host.calls`, `counting.calls`) the count is usually the real unit's own output: not a mock.
MOCK_COUNT = re.compile(r"call_count|callCount|calls?Count|\.calls\b|wasCalled|\bcalled\b")
DOUBLE = re.compile(r"mock|spy|fake|stub", re.I)

RUST_ASSERT = re.compile(
    r"\b(?:assert\w*|debug_assert\w*|panic|unreachable|todo|unimplemented|bail|ensure)\s*!"
    r"|\.\s*(?:unwrap|expect|unwrap_err|expect_err|unwrap_unchecked)\s*\("
)
SWIFT_ASSERT = re.compile(
    r"\bXCT(?:Assert\w*|Fail|Unwrap|Expect\w*)\b|#expect\b|#require\b"
    r"|\b(?:fatalError|precondition\w*|assert|assertionFailure|expect)\s*\("
    r"|\bIssue\s*\.\s*record\b|\bwait\s*\(\s*for\s*:|\bfulfillment\s*\(\s*of\s*:"
    r"|\bwaitForExpectations\b|\btry\b(?!\s*\?)|\bthrow\b"
)
TS_ASSERT = re.compile(
    r"\bexpect\s*[(.]|\bassert\w*\s*[(.]|\.\s*(?:toThrow\w*|rejects|resolves)\b|\bthrow\b"
    r"|\bfail\s*\(|\b(?:getBy|getAllBy|findBy|findAllBy)\w*\s*\("
)


# --- source stripping: blank comments and string contents, keep offsets and newlines ---------

def _blank(chars: list[str], start: int, end: int) -> None:
    for k in range(start, min(end, len(chars))):
        if chars[k] != "\n":
            chars[k] = " "


def strip_source(src: str, lang: str) -> str:
    """Comments and string/regex contents become spaces; delimiters, code and newlines stay."""
    out = list(src)
    n = len(src)
    i = 0
    nested = lang in ("rust", "swift")

    def skip_string(j: int, quote: str) -> int:
        # j is just past the opening quote; returns the index of the closing quote.
        while j < n:
            c = src[j]
            if c == "\\":
                if lang == "swift" and j + 1 < n and src[j + 1] == "(":
                    j = skip_parens(j + 2)
                    continue
                if lang == "ts" and quote == "`":
                    pass
                j += 2
                continue
            if lang == "ts" and quote == "`" and c == "$" and j + 1 < n and src[j + 1] == "{":
                j = skip_braces(j + 2)
                continue
            if c == quote:
                return j
            if c == "\n" and quote != "`" and lang != "rust":
                return j
            j += 1
        return n

    def skip_parens(j: int) -> int:
        depth = 1
        while j < n and depth:
            c = src[j]
            if c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
            elif c == '"':
                j = skip_string(j + 1, '"')
            j += 1
        return j

    def skip_braces(j: int) -> int:
        depth = 1
        while j < n and depth:
            c = src[j]
            if c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
            elif c in "\"'`":
                j = skip_string(j + 1, c)
            j += 1
        return j

    last_sig = ""  # last significant (non-space) code char, for TS regex literals
    while i < n:
        c = src[i]
        nxt = src[i + 1] if i + 1 < n else ""
        if c == "/" and nxt == "/":
            j = src.find("\n", i)
            j = n if j < 0 else j
            _blank(out, i, j)
            i = j
            continue
        if c == "/" and nxt == "*":
            depth, j = 1, i + 2
            while j < n and depth:
                if src.startswith("*/", j):
                    depth -= 1
                    j += 2
                elif nested and src.startswith("/*", j):
                    depth += 1
                    j += 2
                else:
                    j += 1
            _blank(out, i, j)
            i = j
            continue
        if lang == "rust" and c in "bcr" and (i == 0 or not (src[i - 1].isalnum() or src[i - 1] == "_")):
            m = re.match(r'[bc]?r(#*)"', src[i:i + 40])  # r"..", br#".."#, cr".."
            if m:
                close = '"' + m.group(1)
                j = src.find(close, i + len(m.group(0)))
                j = n if j < 0 else j
                _blank(out, i + len(m.group(0)), j)
                i = j + len(close)
                last_sig = '"'
                continue
        if lang == "rust" and c == "'":
            m = re.match(r"'(?:\\(?:x[0-9a-fA-F]{2}|u\{[0-9a-fA-F]+\}|.)|[^\\'\n])'", src[i:i + 14])
            if m:
                _blank(out, i + 1, i + len(m.group(0)) - 1)
                i += len(m.group(0))
                last_sig = "'"
                continue
            i += 1  # a lifetime
            continue
        if lang == "swift" and c == "#" and re.match(r'#+"', src[i:i + 10]):
            # A multi-line raw string's `"""` ends its line; `#""""#` is a one-line `"`.
            m = re.match(r'(#+)("""(?=[ \t]*\n)|")', src[i:i + 200])
            close = m.group(2) + m.group(1)
            j = src.find(close, i + len(m.group(0)))
            j = n if j < 0 else j
            _blank(out, i + len(m.group(0)), j)
            i = j + len(close)
            continue
        if lang == "swift" and src.startswith('"""', i):
            j = src.find('"""', i + 3)
            j = n if j < 0 else j
            _blank(out, i + 3, j)
            i = j + 3
            continue
        if c == '"' or (lang == "ts" and c in "'`"):
            j = skip_string(i + 1, c)
            _blank(out, i + 1, j)
            i = j + 1
            last_sig = '"'
            continue
        if lang == "ts" and c == "/" and (last_sig == "" or last_sig in "(,=:[!&|?{};+-*%<>~^"):
            j, in_class = i + 1, False
            while j < n and src[j] != "\n":
                if src[j] == "\\":
                    j += 2
                    continue
                if src[j] == "[":
                    in_class = True
                elif src[j] == "]":
                    in_class = False
                elif src[j] == "/" and not in_class:
                    break
                j += 1
            if j < n and src[j] == "/":
                _blank(out, i + 1, j)
                i = j + 1
                last_sig = '"'
                continue
        if not c.isspace():
            last_sig = c
        i += 1
    return "".join(out)


def match_close(text: str, i: int) -> int:
    """text[i] is an opening bracket; the index just past its partner (len(text) if none)."""
    pairs = {"(": ")", "[": "]", "{": "}"}
    stack = [pairs[text[i]]]
    j = i + 1
    while j < len(text) and stack:
        c = text[j]
        if c in pairs:
            stack.append(pairs[c])
        elif c in ")]}":
            if c == stack[-1]:
                stack.pop()
            else:  # unbalanced: give up on this nesting level
                stack.pop()
        j += 1
    return j


def line_of(text: str, i: int) -> int:
    return text.count("\n", 0, i) + 1


def calls_in(body: str, lang: str) -> set[str]:
    names = set(CALL.findall(body))
    if lang == "swift":
        names |= {m for m in SWIFT_TRAILING.findall(body) if m not in SWIFT_KEYWORDS}
    return names


def helper_named(names: set[str]) -> bool:
    return any(HELPER_NAME.search(n) and not NOT_HELPER.search(n) for n in names)


# --- per-language extraction --------------------------------------------------------------
# Each extractor returns (tests, defs). A test is a dict with name, line, body (stripped text),
# attrs (the original text of its attributes/decorators) and flags; a def is (name, body).

def _fn_body(stripped: str, start: int) -> tuple[int, int] | None:
    """From a `fn`/`func` keyword: (open, close) of the body braces, None for a declaration."""
    p = stripped.find("(", start)
    if p < 0:
        return None
    j = match_close(stripped, p)
    while j < len(stripped):
        c = stripped[j]
        if c == "{":
            return j, match_close(stripped, j)
        if c == ";":
            return None
        if c in "(<[":
            j = match_close(stripped, j) if c != "<" else j + 1
            continue
        j += 1
    return None


RUST_TEST_ATTR = re.compile(r"#\[\s*(?:[\w:]+::)?test\b(?:\([^\]]*\))?\s*\]")
RUST_FN = re.compile(r"\bfn\s+(\w+)")


def extract_rust(src: str) -> tuple[list[dict], list[tuple[str, str]]]:
    s = strip_source(src, "rust")
    tests, defs, test_fn_starts = [], [], set()
    for m in RUST_TEST_ATTR.finditer(s):
        fm = RUST_FN.search(s, m.end())
        if not fm or s[m.end():fm.start()].count(";") or s[m.end():fm.start()].count("{"):
            continue
        # The attribute run: walk back over `#[...]` blocks and whitespace.
        a = m.start()
        while True:
            k = a - 1
            while k >= 0 and s[k].isspace():
                k -= 1
            if k >= 0 and s[k] == "]":
                depth, q = 0, k
                while q >= 0:
                    if s[q] == "]":
                        depth += 1
                    elif s[q] == "[":
                        depth -= 1
                        if depth == 0:
                            break
                    q -= 1
                if q > 0 and s[q - 1] == "#":
                    a = q - 1
                    continue
            break
        span = _fn_body(s, fm.end())
        if not span:
            continue
        o, c = span
        test_fn_starts.add(fm.start())
        sig = s[fm.end():o]
        tests.append({
            "name": fm.group(1), "line": line_of(s, fm.start()), "body": s[o + 1:c - 1],
            "attrs": src[a:fm.start()], "returns_result": bool(re.search(r"->\s*[\w:<>, ]*Result", sig)),
        })
    for fm in RUST_FN.finditer(s):
        if fm.start() in test_fn_starts:
            continue
        span = _fn_body(s, fm.end())
        if span:
            defs.append((fm.group(1), s[span[0] + 1:span[1] - 1]))
    for mm in re.finditer(r"\bmacro_rules!\s*(\w+)\s*\{", s):
        o = mm.end() - 1
        defs.append((mm.group(1), s[o + 1:match_close(s, o) - 1]))
    return tests, defs


SWIFT_FUNC = re.compile(r"\bfunc\s+(\w+)")
SWIFT_TEST_ATTR = re.compile(r"@Test\b")
SWIFT_SUITE_ATTR = re.compile(r"@Suite\b")


def _swift_attr_args(s: str, i: int) -> tuple[int, str]:
    """i is just past `@Test`; (end, args) with args the stripped parenthesized text or ''."""
    j = i
    while j < len(s) and s[j] in " \t":
        j += 1
    if j < len(s) and s[j] == "(":
        e = match_close(s, j)
        return e, s[j:e]
    return i, ""


def extract_swift(src: str) -> tuple[list[dict], list[tuple[str, str]]]:
    s = strip_source(src, "swift")
    xctest = "XCTest" in s and re.search(r"\bimport\s+XCTest\b", s) is not None
    tests, defs, seen = [], [], set()
    attr_for: dict[int, tuple[int, str]] = {}
    for m in SWIFT_TEST_ATTR.finditer(s):
        end, args = _swift_attr_args(s, m.end())
        fm = SWIFT_FUNC.search(s, end)
        if fm and not re.search(r"[{};]", s[end:fm.start()]):
            attr_for[fm.start()] = (m.start(), args)
    disabled_suites = []
    for m in SWIFT_SUITE_ATTR.finditer(s):
        end, args = _swift_attr_args(s, m.end())
        if re.search(r"\.disabled\b(?!\s*\(\s*if\s*:)", args):
            b = s.find("{", end)
            if b >= 0:
                disabled_suites.append((b, match_close(s, b), src[m.start():end]))
    for fm in SWIFT_FUNC.finditer(s):
        span = _fn_body(s, fm.end())
        if not span:
            continue
        o, c = span
        name = fm.group(1)
        is_testing = fm.start() in attr_for
        # XCTest runs only public instance methods `func test*()` that return nothing.
        line_head = s[s.rfind("\n", 0, fm.start()) + 1:fm.start()]
        is_xctest = (xctest and name.startswith("test") and re.match(r"\s*\(\s*\)", s[fm.end():])
                     and not re.search(r"\b(static|class|private|fileprivate)\b", line_head)
                     and "->" not in s[fm.end():o])
        body = s[o + 1:c - 1]
        if not (is_testing or is_xctest):
            defs.append((name, body))
            continue
        a, args = attr_for.get(fm.start(), (fm.start(), ""))
        attrs = src[a:fm.start()]
        for b, e, sattr in disabled_suites:
            if b < fm.start() < e:
                attrs = sattr + "\n" + attrs
        seen.add(fm.start())
        tests.append({"name": name, "line": line_of(s, fm.start()), "body": body, "attrs": attrs,
                      "stripped_attrs": args})
    return tests, defs


TS_TEST = re.compile(
    r"(?<![\w.$])(test|it|xit|xtest)((?:\s*\.\s*(?:only|concurrent|skip|todo|fixme|serial|failing))*)\s*\("
)
TS_DEFS = (
    re.compile(r"\bfunction\s*\*?\s*(\w+)\s*(?=\()"),
    re.compile(r"\b(?:const|let|var)\s+(\w+)\s*(?::[^=;]+)?=\s*(?:async\s+)?(?:function\b|\([^;]*?\)\s*(?::[^=;]+)?=>|\w+\s*=>)"),
)


def _ts_def_body(s: str, i: int) -> str:
    """From the end of a def's name, the body: its braces, or an arrow's expression."""
    arrow = s.find("=>", i)
    brace = s.find("{", i)
    p = s.find("(", i)
    if p >= 0 and (brace < 0 or p < brace):
        j = match_close(s, p)
        brace = s.find("{", j)
        arrow2 = s.find("=>", j)
        if arrow2 >= 0 and (brace < 0 or arrow2 < brace):
            arrow = arrow2
        else:
            arrow = -1
    if arrow >= 0 and (brace < 0 or arrow < brace):
        k = arrow + 2
        while k < len(s) and s[k].isspace():
            k += 1
        if k < len(s) and s[k] == "{":
            return s[k + 1:match_close(s, k) - 1]
        j = k
        while j < len(s) and s[j] not in ";\n":
            if s[j] in "([{":
                j = match_close(s, j)
                continue
            if s[j] in ")]}":
                break
            j += 1
        return s[k:j]
    if brace >= 0:
        return s[brace + 1:match_close(s, brace) - 1]
    return ""


def extract_ts(src: str) -> tuple[list[dict], list[tuple[str, str]]]:
    s = strip_source(src, "ts")
    tests, defs = [], []
    # `describe.skip(...)` spans: (start, end, top_level). One at the file's top level always
    # skips; one inside a block (a `catch` when no browser engine is installed) is a runtime
    # skip marker, and the empty test it holds is a placeholder, not a vacuous test.
    skips = []
    for m in re.finditer(r"(?<![\w.$])(?:describe|suite)\s*\.\s*skip\s*\(", s):
        depth = s.count("{", 0, m.start()) - s.count("}", 0, m.start())
        skips.append((m.start(), match_close(s, m.end() - 1), depth == 0))
    for m in TS_TEST.finditer(s):
        p = m.end() - 1
        # The first argument must be a string literal: `test.skip(cond, reason)` inside a body
        # is a conditional skip, not a declaration.
        q = p + 1
        while q < len(s) and s[q].isspace():
            q += 1
        if q >= len(s) or s[q] not in "\"'`":
            continue
        close = s.find(s[q], q + 1)
        name = src[q + 1:close] if close > 0 else ""
        e = match_close(s, p)
        mods = re.sub(r"\s", "", m.group(2))
        body = s[close + 1:e - 1]
        outer = next((sk for sk in skips if sk[0] < m.start() < sk[1]), None)
        if outer and not outer[2] and not re.search(r"\{\s*[^\s}]", body.split("=>", 1)[-1]):
            continue  # a runtime skip marker's placeholder
        if outer:
            mods += ".skip" if outer[2] else ".skip(in-block)"
        tests.append({
            "name": name, "line": line_of(s, m.start()), "body": body,
            "attrs": m.group(1) + mods, "todo": ".todo" in mods,
        })
    for rx in TS_DEFS:
        for m in rx.finditer(s):
            defs.append((m.group(1), _ts_def_body(s, m.end())))
    return tests, defs


# --- Python -----------------------------------------------------------------------------

def _py_call_name(node: ast.Call) -> str:
    f = node.func
    if isinstance(f, ast.Name):
        return f.id
    if isinstance(f, ast.Attribute):
        return f.attr
    return ""


def _py_dotted(node: ast.AST) -> str:
    if isinstance(node, ast.Call):
        node = node.func
    parts = []
    while isinstance(node, ast.Attribute):
        parts.append(node.attr)
        node = node.value
    if isinstance(node, ast.Name):
        parts.append(node.id)
    return ".".join(reversed(parts))


def _py_skip_decorator(decs: list[ast.expr]) -> str | None:
    for d in decs:
        name = _py_dotted(d)
        if name in ("unittest.skip", "skip", "pytest.mark.skip", "mark.skip"):
            return name
    return None


def extract_python(src: str) -> tuple[list[dict], list[tuple[str, ast.AST]]]:
    try:
        tree = ast.parse(src)
    except SyntaxError:
        return [], []
    tests, defs = [], []

    def visit(body: list[ast.stmt], cls_skip: str | None, in_class: bool) -> None:
        for node in body:
            if isinstance(node, ast.ClassDef):
                visit(node.body, _py_skip_decorator(node.decorator_list) or cls_skip, True)
            elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                # A `test_*` that returns a value is a helper (test_files() -> list), not a test.
                returns = any(isinstance(r, ast.Return) and r.value is not None
                              for r in ast.walk(node)) or (node.returns is not None and not (
                                  isinstance(node.returns, ast.Constant) and node.returns.value is None))
                if not returns and (node.name.startswith("test_") or (in_class and node.name.startswith("test"))):
                    tests.append({"name": node.name, "line": node.lineno, "node": node,
                                  "skip": _py_skip_decorator(node.decorator_list) or cls_skip})
                else:
                    defs.append((node.name, node))
    visit(tree.body, None, False)
    return tests, defs


def py_asserts(node: ast.AST, helpers: set[str]) -> tuple[list[ast.AST], bool]:
    """(assertion nodes, has_calls) under node, nested defs included."""
    found, has_calls = [], False
    for sub in ast.walk(node):
        if sub is node:
            continue
        if isinstance(sub, (ast.Assert, ast.Raise)):
            found.append(sub)
        elif isinstance(sub, ast.Call):
            has_calls = True
            name = _py_call_name(sub)
            if (HELPER_NAME.search(name) and not NOT_HELPER.search(name)) or "raises" in name.lower() \
                    or name in helpers or name == "fail":
                found.append(sub)
            elif any(k.arg == "check" and isinstance(k.value, ast.Constant) and k.value.value is True
                     for k in sub.keywords):
                found.append(sub)
    return found, has_calls


def py_calls(node: ast.AST) -> set[str]:
    return {_py_call_name(s) for s in ast.walk(node) if isinstance(s, ast.Call)} - {""}


def py_unconditional_skip(fn: ast.AST) -> bool:
    for st in fn.body:
        if isinstance(st, ast.Expr) and isinstance(st.value, ast.Call) \
                and _py_call_name(st.value) == "skipTest":
            return True
        if isinstance(st, ast.Raise) and st.exc is not None and "SkipTest" in _py_dotted(st.exc):
            return True
    return False


# --- the scan ---------------------------------------------------------------------------

def language_of(rel: str) -> str | None:
    if rel.endswith(".rs"):
        return "rust"
    if rel.endswith(".swift"):
        return "swift"
    if re.search(r"\.test\.[jt]sx?$", rel):
        return "ts"
    if rel.endswith(".py") and (rel.startswith("tests/") or "/tests/" in rel):
        return "python"
    return None


def walk_files(root: Path, roots: list[str]) -> list[str]:
    out = []
    for r in roots:
        base = root / r
        if not base.exists():
            continue
        stack = [base]
        while stack:
            d = stack.pop()
            try:
                entries = list(d.iterdir())
            except OSError:
                continue
            for e in entries:
                if e.is_dir():
                    if e.name not in SKIP_DIRS and not e.is_symlink():
                        stack.append(e)
                elif e.is_file():
                    rel = e.relative_to(root).as_posix()
                    if language_of(rel):
                        out.append(rel)
    return sorted(set(out))


ASSERT_RX = {"rust": RUST_ASSERT, "swift": SWIFT_ASSERT, "ts": TS_ASSERT}


class Index:
    """Function names that assert, per language: same-file always, cross-file when rare."""

    def __init__(self) -> None:
        self.defs: dict[str, list[tuple[str, str, bool, set[str]]]] = defaultdict(list)

    def add(self, lang: str, path: str, name: str, asserts: bool, calls: set[str]) -> None:
        self.defs[lang].append((path, name, asserts, calls))

    def finish(self) -> None:
        self.asserting: dict[str, set[str]] = {}
        self.global_ok: dict[str, set[str]] = {}
        self.local: dict[str, dict[str, set[str]]] = {}
        self.by_dir: dict[str, dict[str, set[str]]] = {}
        for lang, rows in self.defs.items():
            files = defaultdict(set)
            for path, name, _, _ in rows:
                files[name].add(path)
            yes = {name for _, name, a, _ in rows if a}
            for _ in range(4):  # helpers calling helpers, a few levels deep
                grew = {name for _, name, a, calls in rows if name not in yes and calls & yes}
                if not grew:
                    break
                yes |= grew
            self.asserting[lang] = yes
            self.global_ok[lang] = {n for n in yes if len(files[n]) <= GLOBAL_HELPER_MAX_FILES}
            by_path = defaultdict(set)
            for path, name, _, _ in rows:
                if name in yes:
                    by_path[path].add(name)
            self.local[lang] = by_path
            by_dir = defaultdict(set)
            for path, names in by_path.items():
                by_dir[path.rsplit("/", 1)[0] if "/" in path else ""] |= names
            self.by_dir[lang] = by_dir

    def helpers_for(self, lang: str, path: str) -> "_Either":
        """Asserting names a test in path may call: its own file's, its folder's and the parent
        folder's (a crate's `mod.rs`, a suite's support file), and rare names from anywhere."""
        here = path.rsplit("/", 1)[0] if "/" in path else ""
        up = here.rsplit("/", 1)[0] if "/" in here else ""
        dirs = self.by_dir.get(lang, {})
        return _Either(self.global_ok.get(lang, set()), self.local.get(lang, {}).get(path, set()),
                       dirs.get(here, set()), dirs.get(up, set()))


class _Either:
    """Membership in any of a few sets, without copying the large global one per file."""

    def __init__(self, *sets: set[str]) -> None:
        self.sets = sets

    def __contains__(self, name: object) -> bool:
        return any(name in s for s in self.sets)


def body_asserts(lang: str, t: dict) -> list[re.Match]:
    hits = list(ASSERT_RX[lang].finditer(t["body"]))
    if lang == "rust" and t.get("returns_result"):
        hits += list(re.finditer(r"\?", t["body"]))
    return hits


def skip_reason(lang: str, t: dict) -> tuple[str, str] | None:
    """(confidence, why) when the test always skips."""
    attrs = t.get("attrs", "")
    if lang == "rust":
        if re.search(r"#\[\s*ignore\s*\]", attrs):
            return "high", "#[ignore] with no reason"
    elif lang == "ts":
        if ".skip(in-block)" in attrs:
            return "medium", "inside a describe.skip that runs under a condition"
        if attrs.startswith(("xit", "xtest")) or ".skip" in attrs or ".fixme" in attrs:
            return "high", f"{attrs}(...)"
    elif lang == "swift":
        # Traits come before `arguments:`; a `.disabled` case among the arguments is a value.
        sa = t.get("stripped_attrs", "").split("arguments:", 1)[0]
        if re.search(r"[(,]\s*\.disabled\b(?!\s*\(\s*if\s*:)", sa):
            has_reason = re.search(r"\.disabled\s*\(\s*\"", attrs) is not None
            return ("medium" if has_reason else "high"), "@Test(.disabled)"
        if re.search(r"@Suite\b[^\n]*\.disabled\b(?!\s*\(\s*if\s*:)", attrs):
            return "high", "@Suite(.disabled)"
        if re.search(r"\.enabled\s*\(\s*if\s*:\s*false\s*\)", sa):
            return "high", "@Test(.enabled(if: false))"
        body = t["body"]
        for m in re.finditer(r"\bthrow\s+XCTSkip\b", body):
            depth = body[:m.start()].count("{") - body[:m.start()].count("}")
            stmt = body[:m.start()].rsplit("\n", 1)[-1]
            if depth == 0 and not re.search(r"\b(if|guard|else|case)\b", stmt):
                return "high", "throw XCTSkip at the top level"
    return None


def mocks_only(hits: list[str]) -> bool:
    return bool(hits) and all(MOCK.search(h) or (MOCK_COUNT.search(h) and DOUBLE.search(h)) for h in hits)


def _line_around(text: str, i: int) -> str:
    a = text.rfind("\n", 0, i) + 1
    b = text.find("\n", i)
    return text[a:b if b >= 0 else len(text)]


def scan(root: Path, roots: list[str], only: set[str] | None = None,
         files: list[str] | None = None) -> dict:
    paths = files if files is not None else walk_files(root, roots)
    parsed: dict[str, tuple[str, list[dict]]] = {}
    index = Index()
    for rel in paths:
        lang = language_of(rel)
        if not lang:
            continue
        try:
            src = (root / rel).read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        if lang == "python":
            tests, defs = extract_python(src)
            # Tests go in too: a test may call another test method as its check.
            for name, node in defs + [(t["name"], t["node"]) for t in tests]:
                found, _ = py_asserts(node, set())
                index.add(lang, rel, name, bool(found), py_calls(node))
        else:
            if lang == "rust" and "test" not in src:
                tests, defs = [], extract_rust(src)[1]
            else:
                tests, defs = {"rust": extract_rust, "swift": extract_swift, "ts": extract_ts}[lang](src)
            for name, body in defs:
                asserts = bool(ASSERT_RX[lang].search(body)) or helper_named(calls_in(body, lang))
                index.add(lang, rel, name, asserts, calls_in(body, lang))
        if tests and (only is None or rel in only):
            parsed[rel] = (lang, tests)
    index.finish()

    findings, scanned = [], Counter()
    for rel, (lang, tests) in sorted(parsed.items()):
        helpers = index.helpers_for(lang, rel)
        for t in tests:
            scanned[lang] += 1
            f = classify(lang, t, helpers)
            if f:
                findings.append({"path": rel, "line": t["line"], "name": t["name"], "language": lang,
                                 "kind": f[0], "confidence": f[1], "why": f[2]})
    by_lang: dict[str, Counter] = defaultdict(Counter)
    for f in findings:
        by_lang[f["language"]][f["kind"]] += 1
    return {
        "roots": roots,
        "scanned": dict(scanned),
        "summary": {
            "by_language": {k: dict(v) for k, v in sorted(by_lang.items())},
            "by_kind": dict(Counter(f["kind"] for f in findings)),
            "by_confidence": dict(Counter(f["confidence"] for f in findings)),
            "total": len(findings),
        },
        "findings": findings,
    }


def classify(lang: str, t: dict, helpers: set[str]) -> tuple[str, str, str] | None:
    """(kind, confidence, why) or None for a test that can fail."""
    if lang == "python":
        if t["skip"]:
            return "skipped", "high", f"@{t['skip']}"
        node = t["node"]
        if py_unconditional_skip(node):
            return "skipped", "high", "skipTest at the top level"
        found, has_calls = py_asserts(node, helpers)
        if not found:
            return "no_assertion", ("medium" if has_calls else "high"), \
                "calls code but asserts nothing" if has_calls else "calls nothing"
        lines = [ast.unparse(n) for n in found]
        if mocks_only(lines):
            return "mocks_only", "low", "every assertion is on mock calls"
        return None

    skip = skip_reason(lang, t)
    if skip:
        return "skipped", skip[0], skip[1]
    if lang == "ts" and t.get("todo"):
        return None  # a declared placeholder, not a test that runs
    if lang == "rust" and re.search(r"#\[\s*should_panic", t.get("attrs", "")):
        return None
    body = t["body"]
    hits = body_asserts(lang, t)
    names = calls_in(body, lang)
    helper_hits = [n for n in names if n in helpers or (HELPER_NAME.search(n) and not NOT_HELPER.search(n))]
    if not hits and not helper_hits:
        if lang == "rust" and re.search(r"\w\s*<[^<>]*\b(Send|Sync|'static)\b", body):
            return None  # a compile-time bound check
        if names:
            return "no_assertion", "medium", "calls code but asserts nothing"
        return "no_assertion", "high", "calls nothing"
    lines = [_line_around(body, m.start()) for m in hits]
    for n in helper_hits:
        m = re.search(r"\b" + re.escape(n) + r"\b", body)
        if m:
            lines.append(_line_around(body, m.start()))
    if mocks_only(lines):
        return "mocks_only", "low", "every assertion is on mock calls"
    return None


def changed_files(root: Path, base: str, head: str) -> list[str]:
    out = subprocess.run(
        ["git", "-C", str(root), "diff", "--name-only", "--diff-filter=AMR", f"{base}...{head}"],
        check=True, capture_output=True, text=True,
    ).stdout
    return [p for p in out.splitlines() if p.strip()]


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--repo", default=str(Path(__file__).resolve().parents[2]))
    ap.add_argument("--root", action="append", help="a root to scan (repeatable)")
    ap.add_argument("--diff", metavar="BASE", help="only tests in files BASE...HEAD changed")
    ap.add_argument("--head", default="HEAD")
    ap.add_argument("--files", nargs="+", help="scan only these paths (relative to --repo)")
    ap.add_argument("--min-confidence", choices=list(CONF_RANK), default="low")
    ap.add_argument("--strict", action="store_true", help="exit 1 when a finding remains")
    ap.add_argument("--output", help="write the report here as well as stdout")
    args = ap.parse_args(argv)
    root = Path(args.repo).resolve()
    roots = args.root or [r for r in DEFAULT_ROOTS if (root / r).exists()]
    only, diff = None, None
    files = None
    if args.files:
        files = [f for f in args.files if language_of(f)]
    if args.diff:
        changed = changed_files(root, args.diff, args.head)
        only = {p for p in changed if language_of(p)}
        diff = {"base": args.diff, "head": args.head, "files": len(only)}
    report = scan(root, roots, only=only, files=files)
    floor = CONF_RANK[args.min_confidence]
    if floor:
        report["findings"] = [f for f in report["findings"] if CONF_RANK[f["confidence"]] >= floor]
        fs = report["findings"]
        by_lang: dict[str, Counter] = defaultdict(Counter)
        for f in fs:
            by_lang[f["language"]][f["kind"]] += 1
        report["summary"] = {
            "by_language": {k: dict(v) for k, v in sorted(by_lang.items())},
            "by_kind": dict(Counter(f["kind"] for f in fs)),
            "by_confidence": dict(Counter(f["confidence"] for f in fs)),
            "total": len(fs),
        }
    report["diff"] = diff
    text = json.dumps(report, indent=1)
    if args.output:
        Path(args.output).parent.mkdir(parents=True, exist_ok=True)
        Path(args.output).write_text(text + "\n")
    print(text)
    print(json.dumps(report["summary"]), file=sys.stderr)
    return 1 if args.strict and report["findings"] else 0


if __name__ == "__main__":
    sys.exit(main())
