#!/usr/bin/env python3
"""Env audit (MQ7): every environment name the app and the daemon read, where, and what it does in Release.

    python3 scripts/features/env_audit.py --check          # exit 1: a name is new or unclassified, or an
                                                           #   automatic class (Debug-only, ...) no longer holds
    python3 scripts/features/env_audit.py --unclassified   # MQ7: names to classify, and Release perf-path
                                                           #   names that no feature replaces yet
    python3 scripts/features/env_audit.py --write          # rescan, keep the classifications, refresh sites
    python3 scripts/features/env_audit.py --summary        # names per scope and class

The two queries (plans/cmux-next/chrome-parity/p12-perf-process.md section 7, MQ7):

  app     every `"CMUX_...` string literal in Packages/macOS/CmuxNext/Sources/**/*.swift
          (the `CMUX_NEXT_*` names are part of it)
  daemon  every `"CMUX_TUI_...` string literal in cmux-tui/crates/**/*.rs

The result is schemas/features/env-audit.json: per scope and name, its class, a note on what it changes,
and every site (file:line, the kind of use, the compile condition and whether a Release build compiles it:
true, false, or null when it depends on the target or a build variant). Swift sites take their condition
from the `#if` stack. Rust sites take theirs from `#[cfg(...)]`, `#[test]`, `if cfg!(...) {`, `#![cfg(...)]`,
the `mod` declarations that include the file (`#[path]` too; any of them) and the crate's tests/, benches/ and
examples/ folders. A string constant is judged at each use that names it: a Swift use by its type, a Rust use
by its path (`crate::`, `super::`, `self::`, a module name, or a `use` import).

Classes. The script sets the first four and checks them on every run; a person sets the others:

  debugOnly        every code site is compiled only into DEBUG builds
  benchOnly        every code site is compiled only into DEBUG or CMUX_BENCH_HOOKS (bench) builds
  testOnly         every code site is Rust test code (cfg(test), #[test], tests/, benches/, examples/)
  docOnly          the literal is only in comments
  childEnv         set, forwarded or removed for a child process; it does not change this process
  devGated         compiled into Release, read only behind a runtime DEV, tagged, bench or test-bundle check
  releaseConfig    changes Release behavior off the perf paths (paths, ids, endpoints, binaries, opt-outs)
  diagnostics      an opt-in measurement or diagnostics switch that Release honors (tracing, probes)
  releasePerfPath  changes Release behavior on a perf path; `followup` names its entry in `followups`
  notEnv           the literal is not an environment name (a prefix of a family of names, message text)

Every manual class needs a `note`. A follow-up (`followups`, one per task) has a title and a resolution:
`feature:<name>` (the name leaves the MQ7 queue when schemas/features/features.d/<name>.json lists it in
`replaces`) or `compileOut` (it leaves when its sites are no longer Release code; --write then records the
automatic class). This is Chrome's model: a base::Feature (base/feature_list.h), not an environment switch,
gates a perf path, and a switch that stays is a documented debug, test or diagnostics switch
(content/public/common/content_switches.cc). Standard library only.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from collections.abc import Iterable
from dataclasses import dataclass, field

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
AUDIT = "schemas/features/env-audit.json"
FEATURES_DIR = "schemas/features/features.d"
RUST_TOP = "cmux-tui/crates"


@dataclass(frozen=True)
class Query:
    scope: str
    top: str
    suffix: str
    pattern: str  # a git grep -E pattern and a Python regex; group 1 is the name


QUERIES = (
    Query("app", "Packages/macOS/CmuxNext/Sources", ".swift", r'"(CMUX_[A-Z0-9_]+)'),
    Query("daemon", RUST_TOP, ".rs", r'"(CMUX_TUI_[A-Z0-9_]+)'),
)
AUTO_CLASSES = ("debugOnly", "benchOnly", "testOnly", "docOnly")
MANUAL_CLASSES = ("childEnv", "devGated", "releaseConfig", "diagnostics", "releasePerfPath", "notEnv")
COMPILE_OUT = "compileOut"  # a follow-up resolution: the name leaves Release code
CLASSES = AUTO_CLASSES + MANUAL_CLASSES
UNCLASSIFIED = "unclassified"
AUTO_NOTES = {
    "debugOnly": "Every code site is compiled only into DEBUG builds.",
    "benchOnly": "Every code site is compiled only into DEBUG or CMUX_BENCH_HOOKS builds.",
    "testOnly": "Every code site is test code.",
    "docOnly": "Named only in comments.",
}

# Swift: what Release and bench (`scripts/reload.sh --config bench`: -DCMUX_BENCH_HOOKS, no DEBUG) builds
# define. Other names (CMUX_NO_*, GHOSTTY_GPU_RESIDENT) and arch() are unknown: the line may be compiled.
# CMUX_BLOCKING_CHECKS is unknown too: the nightly-next Release build defines it (nightly.yml).
SWIFT_OFF = frozenset({"DEBUG", "CMUX_BENCH_HOOKS", "CMUX_UI_LAYER_PREVIEW"})
SWIFT_BENCH_ON = frozenset({"CMUX_BENCH_HOOKS"})
SWIFT_CONFIGS = (frozenset(), SWIFT_BENCH_ON, frozenset({"DEBUG"}))  # the names on in (release, bench, debug)
SWIFT_PLATFORM = {"os": {"macOS"}}
# Rust: what `cargo build --release` of the daemon sets, and a debug build that is not a test build.
# Targets and cargo features are unknown.
RUST_OFF = frozenset({"debug_assertions", "test", "miri", "doc", "doctest", "fuzzing"})
RUST_DEBUG_OFF = RUST_OFF - {"debug_assertions"}
RUST_TEST_DIRS = ("tests", "benches", "examples")


class AuditError(RuntimeError):
    """The tree or the audit file cannot be read."""


# ---------------------------------------------------------------------------------------------
# Three-valued conditions: True compiled, False not compiled, None depends on the target

def _and(values: Iterable[bool | None]) -> bool | None:
    out: bool | None = True
    for value in values:
        if value is False:
            return False
        if value is None:
            out = None
    return out


def _or(values: Iterable[bool | None]) -> bool | None:
    out: bool | None = False
    for value in values:
        if value is True:
            return True
        if value is None:
            out = None
    return out


def _not(value: bool | None) -> bool | None:
    return None if value is None else not value


@dataclass(frozen=True)
class Gate:
    """The compile condition of a site: its text, and its value in a Release, a bench and a debug (not test)
    build. A Rust site that a debug build does not compile is test code."""

    text: str = ""
    release: bool | None = True
    bench: bool | None = True
    debug: bool | None = True


def _combine(gates: Iterable[Gate | None]) -> Gate:
    """All of the gates (a site inside each of them)."""
    present: list[Gate] = []
    for gate in gates:
        if gate is not None and gate.text and gate not in present:
            present.append(gate)
    if not present:
        return Gate()
    return Gate(" && ".join(gate.text for gate in present), _and(gate.release for gate in present),
                _and(gate.bench for gate in present), _and(gate.debug for gate in present))


def _either(gates: Iterable[Gate]) -> Gate:
    """Any of the gates (a file that more than one `mod` declaration includes)."""
    present: list[Gate] = []
    for gate in gates:
        if not gate.text:
            return Gate()
        if gate not in present:
            present.append(gate)
    if len(present) == 1:
        return present[0]
    return Gate("(%s)" % " || ".join(gate.text for gate in present), _or(gate.release for gate in present),
                _or(gate.bench for gate in present), _or(gate.debug for gate in present))


_SWIFT_TOKEN = re.compile(r"\s*(\|\||&&|!|\(|\)|\w+\([^()]*\)|\w+)")


class SwiftCondition:
    """A `#if` condition: identifiers, ||, &&, !, parentheses and os()/arch()/canImport()/compiler() calls."""

    def __init__(self, text: str):
        self.text = text.split("//")[0].strip()
        self.tokens: list[str] = []
        position = 0
        while position < len(self.text):
            match = _SWIFT_TOKEN.match(self.text, position)
            if not match or not match.group(1):
                raise AuditError("cannot read #if condition %r" % self.text)
            self.tokens.append(match.group(1))
            position = match.end()
        self._position, self._on = 0, frozenset()

    def value(self, on: frozenset[str]) -> bool | None:
        self._position, self._on = 0, on
        result = self._or()
        if self._position != len(self.tokens):
            raise AuditError("cannot read #if condition %r" % self.text)
        return result

    def _peek(self) -> str | None:
        return self.tokens[self._position] if self._position < len(self.tokens) else None

    def _next(self) -> str | None:
        token = self._peek()
        self._position += 1
        return token

    def _or(self) -> bool | None:
        values = [self._and()]
        while self._peek() == "||":
            self._next()
            values.append(self._and())
        return _or(values)

    def _and(self) -> bool | None:
        values = [self._unary()]
        while self._peek() == "&&":
            self._next()
            values.append(self._unary())
        return _and(values)

    def _unary(self) -> bool | None:
        token = self._next()
        if token == "!":
            return _not(self._unary())
        if token == "(":
            result = self._or()
            if self._next() != ")":
                raise AuditError("unbalanced #if condition %r" % self.text)
            return result
        call = re.fullmatch(r"(\w+)\(([^()]*)\)", token or "")
        if call:
            name, argument = call.group(1), call.group(2).strip()
            return (argument in SWIFT_PLATFORM[name]) if name in SWIFT_PLATFORM else None
        if token is None or not re.fullmatch(r"\w+", token):
            raise AuditError("cannot read #if condition %r" % self.text)
        if token in ("true", "false"):
            return token == "true"
        if token in self._on:
            return True
        return False if token in SWIFT_OFF else None


def swift_gates(text: str) -> list[Gate]:
    """Per line of a Swift file (index 0 is line 1), the `#if` branches that compile it."""
    # One entry per open #if group: (this branch's gate, the earlier branches' values per SWIFT_CONFIGS).
    stack: list[tuple[Gate, list[tuple[bool | None, ...]]]] = []
    out: list[Gate] = []
    for line in text.splitlines():
        directive = re.match(r"\s*#(if|elseif|else|endif)\b(.*)", line)
        if directive:
            kind, rest = directive.group(1), directive.group(2)
            if kind in ("if", "elseif"):
                condition = SwiftCondition(rest)
                values = tuple(condition.value(on) for on in SWIFT_CONFIGS)
            if kind == "if":
                stack.append((Gate(condition.text, *values), [values]))
            elif kind in ("elseif", "else") and stack:
                earlier = stack[-1][1]
                none = tuple(_not(_or(value[k] for value in earlier)) for k in range(len(SWIFT_CONFIGS)))
                if kind == "elseif":
                    branch = tuple(_and(pair) for pair in zip(none, values))
                    stack[-1] = (Gate("#elseif " + condition.text, *branch), earlier + [values])
                else:
                    first = stack[-1][0].text if len(earlier) == 1 else "the #if group"
                    stack[-1] = (Gate("#else of " + first, *none), earlier)
            elif kind == "endif" and stack:
                stack.pop()
        out.append(_combine(entry[0] for entry in stack))
    return out


# ---------------------------------------------------------------------------------------------
# Rust: a small lexer and the cfg in force at each token

@dataclass(frozen=True)
class Token:
    kind: str  # ident, str, char, comment, punct
    text: str
    line: int
    col: int


_RUST_LEX = re.compile(r"""
    (?P<ws>\s+)
  | (?P<line_comment>//[^\n]*)
  | (?P<block_comment>/\*)
  | (?P<raw>b?r(?P<hashes>\#*)")
  | (?P<str>b?"(?:[^"\\]|\\.)*")
  | (?P<char>b?'(?:[^'\\\n]|\\(?:x[0-9a-fA-F]{2}|u\{[0-9a-fA-F_]+\}|.))')
  | (?P<ident>[A-Za-z_][A-Za-z0-9_]*)
  | (?P<number>[0-9][A-Za-z0-9_]*)
  | (?P<lifetime>'[A-Za-z_][A-Za-z0-9_]*)
  | (?P<punct>.)
""", re.S | re.X)


def rust_tokens(text: str) -> list[Token]:
    """Identifiers, string literals (their content), comments and one-character punctuation."""
    tokens: list[Token] = []
    position, line, line_start, size = 0, 1, 0, len(text)
    while position < size:
        match = _RUST_LEX.match(text, position)
        kind = match.lastgroup if match.lastgroup != "hashes" else "raw"
        end = match.end()
        value = None
        if kind == "block_comment":
            depth, end = 1, position + 2
            while end < size and depth:
                if text.startswith("/*", end):
                    depth, end = depth + 1, end + 2
                elif text.startswith("*/", end):
                    depth, end = depth - 1, end + 2
                else:
                    end += 1
            kind, value = "comment", text[position:end]
        elif kind == "raw":
            close = '"' + match.group("hashes")
            stop = text.find(close, match.end())
            stop = size if stop < 0 else stop
            kind, value, end = "str", text[match.end():stop], min(size, stop + len(close))
        elif kind == "str":
            body = match.group(0)
            value = body[body.index('"') + 1:-1]
        elif kind == "line_comment":
            kind, value = "comment", match.group(0)
        elif kind in ("ident", "punct", "char"):
            value = match.group(0)
        if value is not None:
            tokens.append(Token(kind, value, line, position - line_start))
        newlines = text.count("\n", position, end)
        if newlines:
            line += newlines
            line_start = text.rindex("\n", position, end) + 1
        position = end
    return tokens


def _rust_predicate_text(tokens: list[Token]) -> str:
    pieces = []
    for token in tokens:
        if token.kind == "str":
            pieces.append('"%s"' % token.text)
        else:
            pieces.append({"=": " = ", ",": ", "}.get(token.text, token.text))
    return "".join(pieces)


def rust_predicate(tokens: list[Token], off: frozenset[str] = RUST_OFF) -> bool | None:
    """The value of a cfg predicate (`name`, `name = "v"`, not(..), all(..), any(..)) in a build where the
    names in `off` are not set: a Release build by default."""
    position = 0

    def parse() -> bool | None:
        nonlocal position
        if position >= len(tokens) or tokens[position].kind != "ident":
            raise AuditError("cannot read cfg predicate %r" % _rust_predicate_text(tokens))
        name = tokens[position].text
        position += 1
        if position < len(tokens) and tokens[position].text == "(" and name in ("not", "all", "any"):
            position += 1
            values = []
            while position < len(tokens) and tokens[position].text != ")":
                values.append(parse())
                if position < len(tokens) and tokens[position].text == ",":
                    position += 1
            position += 1
            if name == "not":
                return _not(values[0]) if values else None
            return _and(values) if name == "all" else _or(values)
        if position < len(tokens) and tokens[position].text == "=":
            position += 2  # `= "value"`: a target or feature, unknown
            return None
        return False if name in off else None

    return parse()


def _cfg_gate(text: str, predicate: list[Token]) -> Gate:
    release = rust_predicate(predicate)
    return Gate(text % _rust_predicate_text(predicate), release, release, rust_predicate(predicate, RUST_DEBUG_OFF))


def _attribute(tokens: list[Token], start: int) -> tuple[int, Gate | None, str | None, bool]:
    """Parse `#[..]` or `#![..]` at `start`: (index after it, its cfg gate, its #[path] value, inner)."""
    i = start + 1
    inner = tokens[i].text == "!"
    i += 2 if inner else 1  # past `[`
    depth, body_start = 1, i
    while i < len(tokens) and depth:
        if tokens[i].kind == "punct" and tokens[i].text in "([{":
            depth += 1
        elif tokens[i].kind == "punct" and tokens[i].text in ")]}":
            depth -= 1
        i += 1
    body = tokens[body_start:i - 1]
    words = [token.text for token in body]
    if len(body) >= 3 and words[:2] == ["cfg", "("]:
        return i, _cfg_gate("cfg(%s)", body[2:-1]), None, inner
    if words and words[-1] in ("test", "bench") and all(word == ":" or word.isidentifier() for word in words):
        return i, Gate("#[%s]" % "".join(words), False, False, False), None, inner
    if len(body) == 3 and words[:2] == ["path", "="] and body[2].kind == "str":
        return i, None, body[2].text, inner
    return i, None, None, inner


# The first keyword after an item's attributes decides where the item ends.
_BLOCK_ITEMS = frozenset({"fn", "impl", "struct", "enum", "mod", "trait", "union", "macro_rules"})
_SEMI_ITEMS = frozenset({"const", "static", "let", "use", "type"})
_MODIFIERS = frozenset({"pub", "async", "unsafe", "default", "extern", "crate"})


@dataclass
class _Pending:
    """Outer attributes waiting for their item, at bracket depth `depth`."""

    depth: int
    gates: list[Gate] = field(default_factory=list)
    path: str | None = None
    kind: str | None = None  # block (ends at its `{` or `;`), semi (ends at `;`), expr (`,` `;` or `{`)


@dataclass
class RustFile:
    """Per token, the cfg gate and the inline module (`mod name { }`) in force; per identifier, its gates;
    the `mod name;` declarations; the `use` leaves."""

    # line -> [(col, kind, gate, inline module path)]
    tokens: dict[int, list[tuple[int, str, Gate, tuple[str, ...]]]] = field(default_factory=dict)
    idents: dict[str, list[tuple[int, Gate]]] = field(default_factory=dict)
    file_gate: Gate = field(default_factory=Gate)
    mods: list[tuple[str, str | None, Gate]] = field(default_factory=list)  # (name, #[path], gate)
    # (inline module of the `use`, module path as written, imported name or `*`, local name)
    imports: list[tuple[tuple[str, ...], tuple[str, ...], str, str]] = field(default_factory=list)

    def _entry(self, line: int, column: int) -> tuple[int, str, Gate, tuple[str, ...]] | None:
        for number in range(line, 0, -1):
            entries = self.tokens.get(number, [])
            if number == line:
                entries = [entry for entry in entries if entry[0] <= column]
            if entries:
                return entries[-1]
        return None

    def at(self, line: int, column: int) -> tuple[str, Gate]:
        """(kind, gate) of the token at or before (line, column); a line inside a long token takes its own."""
        entry = self._entry(line, column)
        return (entry[1], entry[2]) if entry else ("punct", Gate())

    def scope(self, line: int, column: int) -> tuple[str, ...]:
        """The inline modules around (line, column), outermost first."""
        entry = self._entry(line, column)
        return entry[3] if entry else ()


def analyze_rust(text: str) -> RustFile:
    """Follow the open brackets (a `{` may carry a gate) and the outer attributes waiting for their item."""
    tokens = rust_tokens(text)
    result = RustFile()
    stack: list[Gate | None] = []
    modules: list[str | None] = []  # per open bracket: the inline module it opens
    scope: tuple[str, ...] = ()
    pending: list[_Pending] = []
    file_gates: list[Gate] = []

    def active() -> Gate:  # the file's own #![cfg] is RustFile.file_gate, kept apart
        return _combine(stack + [gate for entry in pending for gate in entry.gates])

    i = 0
    while i < len(tokens):
        token = tokens[i]
        depth = len(stack)
        top = pending[-1] if pending and pending[-1].depth == depth else None
        opener = [t.text for t in tokens[i + 1:i + 3]]
        if token.kind == "punct" and token.text == "#" and (opener[:1] == ["["] or opener == ["!", "["]):
            end, gate, path, inner = _attribute(tokens, i)
            if inner and gate is not None:
                if stack:
                    stack[-1] = _combine([stack[-1], gate])
                else:
                    file_gates.append(gate)
            elif not inner:
                if top is None or top.kind is not None:
                    top = _Pending(depth)
                    pending.append(top)
                if gate is not None:
                    top.gates.append(gate)
                if path is not None:
                    top.path = path
            i = end
            continue
        if top is not None and top.kind is None and token.kind != "comment":
            if token.kind == "ident" and token.text in _MODIFIERS:
                pass
            elif token.kind == "ident" and token.text in _BLOCK_ITEMS:
                top.kind = "block"
            elif token.kind == "ident" and token.text in _SEMI_ITEMS:
                top.kind = "semi"
            else:
                top.kind = "expr"
        elif top is not None and top.kind == "semi" and token.kind == "ident" and token.text == "fn":
            top.kind = "block"  # const fn, unsafe fn
        result.tokens.setdefault(token.line, []).append((token.col, token.kind, active(), scope))
        if token.kind == "ident":
            if (token.text == "mod" and i + 2 < len(tokens) and tokens[i + 1].kind == "ident"
                    and tokens[i + 2].text == ";"):
                result.mods.append((tokens[i + 1].text, top.path if top is not None else None, active()))
            if token.text == "use":
                result.imports += [(scope, *leaf) for leaf in rust_use_tree(tokens, i + 1)]
            if token.text == "if" and [t.text for t in tokens[i + 1:i + 4]] == ["cfg", "!", "("]:
                j, nesting = i + 4, 1
                while j < len(tokens) and nesting:
                    if tokens[j].kind == "punct":
                        nesting += {"(": 1, ")": -1}.get(tokens[j].text, 0)
                    j += 1
                if j < len(tokens) and tokens[j].text == "{":
                    stack.append(_cfg_gate("cfg!(%s)", tokens[i + 4:j - 1]))
                    modules.append(None)
                    i = j + 1
                    continue
            result.idents.setdefault(token.text, []).append((token.line, active()))
        elif token.kind == "punct":
            if token.text in "([{":
                gate = None
                if token.text == "{" and top is not None and top.kind in ("block", "expr"):
                    gate = _combine(top.gates)
                    pending.pop()
                stack.append(gate)
                inline = token.text == "{" and i >= 2 and tokens[i - 2].text == "mod" and tokens[i - 1].kind == "ident"
                modules.append(tokens[i - 1].text if inline else None)
                scope = scope + (tokens[i - 1].text,) if inline else scope
            elif token.text in ")]}":
                if stack:
                    stack.pop()
                if modules and modules.pop() is not None:
                    scope = scope[:-1]
                while pending and pending[-1].depth > len(stack):
                    pending.pop()
            elif top is not None and (token.text == ";" or (token.text == "," and top.kind == "expr")):
                pending.pop()
        i += 1
    result.file_gate = _combine(file_gates)
    return result


def rust_use_tree(tokens: list[Token], start: int) -> list[tuple[tuple[str, ...], str, str]]:
    """(module path as written, imported name or `*`, local name) of each leaf of the `use` tree that starts
    at token `start` (just after `use`)."""
    out: list[tuple[tuple[str, ...], str, str]] = []

    def tree(i: int, prefix: tuple[str, ...]) -> int:
        segments = list(prefix)
        while i < len(tokens):
            token = tokens[i]
            if token.kind == "comment":
                pass
            elif token.kind == "ident" and token.text != "as":
                segments.append(token.text)
            elif token.text == "*":
                out.append((tuple(segments), "*", "*"))
                return i + 1
            elif token.text == "{":
                i += 1
                while i < len(tokens) and tokens[i].text not in ("}", ";"):
                    i = max(tree(i, tuple(segments)) if tokens[i].text != "," else i, i + 1)
                return i + 1
            elif token.text != ":":
                break
            i += 1
        if len(segments) > len(prefix):
            local = segments[-1]
            if i + 1 < len(tokens) and tokens[i].text == "as" and tokens[i + 1].kind == "ident":
                local, i = tokens[i + 1].text, i + 2
            out.append((tuple(segments[:-1]), segments[-1], local))
        return i

    tree(start, ())
    return out


# ---------------------------------------------------------------------------------------------
# Tree reading

def _read(path: str) -> str:
    with open(path, encoding="utf-8", errors="replace") as handle:
        return handle.read()


def _git_grep(root: str, pattern: str, pathspec: str, list_files: bool) -> list[str] | None:
    """`git grep -E` lines (or files with -l) in a checkout, new files too; None outside one."""
    command = ["git", "-C", root, "grep", "--untracked", "-I", "-E", "-l" if list_files else "-n", pattern,
               "--", pathspec]
    try:
        done = subprocess.run(command, capture_output=True, text=True, check=False)
    except OSError:
        return None
    if done.returncode not in (0, 1) or done.stderr.strip():
        return None
    return [row for row in done.stdout.splitlines() if row]


def _walk(root: str, top: str, suffix: str) -> list[str]:
    out = []
    for directory, subdirs, files in os.walk(os.path.join(root, top)):
        subdirs[:] = sorted(name for name in subdirs if name not in (".git", ".build", "target", "node_modules"))
        for name in sorted(files):
            if name.endswith(suffix):
                out.append(os.path.relpath(os.path.join(directory, name), root).replace(os.sep, "/"))
    return out


def _grep(root: str, pattern: str, top: str, suffix: str) -> list[tuple[str, int, str]]:
    """(path, line number, line) of every match of `pattern` in files under `top` ending in `suffix`."""
    rows = _git_grep(root, pattern, "%s/*%s" % (top, suffix), list_files=False)
    if rows is not None:
        out = []
        for row in rows:
            path, number, line = row.split(":", 2)
            out.append((path, int(number), line))
        return out
    regex, out = re.compile(pattern), []
    for rel in _walk(root, top, suffix):
        for number, line in enumerate(_read(os.path.join(root, rel)).splitlines(), 1):
            if regex.search(line):
                out.append((rel, number, line))
    return out


def candidate_files(root: str, query: Query) -> list[str]:
    """Repo-relative files under the query's folder with a match."""
    listed = _git_grep(root, query.pattern, "%s/*%s" % (query.top, query.suffix), list_files=True)
    if listed is not None:
        return sorted(listed)
    pattern = re.compile(query.pattern)
    return [rel for rel in _walk(root, query.top, query.suffix) if pattern.search(_read(os.path.join(root, rel)))]


@dataclass(frozen=True)
class Site:
    at: str  # path:line
    kind: str  # use, write, constant, compileTime, comment, or `via NAME` (a use of the constant NAME)
    gate: Gate

    def document(self) -> dict:
        return {"at": self.at, "kind": self.kind, "cond": self.gate.text, "release": self.gate.release}


def _sort_key(site: Site) -> tuple[str, int, str]:
    path, line = site.at.rsplit(":", 1)
    return path, int(line), site.kind


def _outside_strings(text: str) -> bool:
    """Whether the end of `text` is outside a string literal (an even count of unescaped quotes)."""
    return len(re.findall(r'(?<!\\)"', text)) % 2 == 0


def _swift_comment(before: str) -> bool:
    """Whether a Swift line that starts with `before` is in a comment at that point."""
    if before.lstrip().startswith(("//", "*", "/*")):
        return True
    comment = before.find("//")
    return comment >= 0 and _outside_strings(before[:comment])


def _swift_kind(line: str, start: int, end: int) -> tuple[str, str | None]:
    """(kind, constant name) of the literal that starts at `start` and whose name ends at `end`."""
    before, after = line[:start], line[end:]
    if _swift_comment(before):
        return "comment", None
    # A named constant: `static let`, or a `let` at the top level of the file. A local `let` is a use.
    constant = re.search(r"\b(?:let|var)\s+(\w+)\s*(?::\s*String\s*)?=\s*$", before)
    if constant and (re.search(r"\bstatic\b", before) or not before[:1].isspace()):
        return "constant", constant.group(1)
    if (re.match(r'"\s*\]\s*=(?!=)', after) or re.search(r"\b(?:setenv|unsetenv)\s*\(\s*$", before)
            or re.search(r"\b(?:removeValue\(forKey|updateValue\([^,]*,\s*forKey):\s*$", before)):
        return "write", None
    if re.match(r'"\s*:(?!:)', after) and not re.search(r"\bcase\s*$", before):
        return "write", None
    return "use", None


def _rust_kind(before: str) -> tuple[str, str | None]:
    constant = re.search(r"\b(?:const|static)\s+(?:mut\s+)?([A-Z][A-Z0-9_]*)\s*"
                         r"(?::\s*&\s*(?:'static\s+)?str\s*)?=\s*$", before)
    if constant:
        return "constant", constant.group(1)
    if re.search(r"\b(?:option_)?env!\s*\(\s*$", before):
        return "compileTime", None
    if re.search(r"\.(?:env|env_remove)\s*\(\s*$|\b(?:set_var|remove_var)\s*\(\s*$", before):
        return "write", None
    return "use", None


@dataclass(frozen=True)
class Constant:
    """A named string constant that holds an env name; its uses are sites of the name."""

    name: str
    ident: str
    rel: str
    line: int
    owner: str | None  # the enclosing Swift type


_SWIFT_TYPE = re.compile(r"^(\s*)(?:@\w+(?:\([^)]*\))?\s+)*"
                         r"(?:(?:public|package|internal|private|fileprivate|open|final|nonisolated|indirect)\s+)*"
                         r"(?:struct|enum|class|actor|extension|protocol)\s+([A-Za-z_][\w.]*)")


def _swift_owner(lines: list[str], index: int) -> str | None:
    """The type (or extended type) whose body holds line `index`: walking up, each less indented code
    line is an enclosing scope, so a closed sibling type at the same indent is skipped."""
    threshold = len(lines[index]) - len(lines[index].lstrip())
    for line in reversed(lines[:index]):
        stripped = line.lstrip()
        if not stripped or stripped.startswith(("//", "/*", "*", "#")):
            continue
        indent = len(line) - len(stripped)
        if indent < threshold:
            match = _SWIFT_TYPE.match(line)
            if match:
                return match.group(2).split(".")[-1]
            threshold = indent
    return None


def scan_swift(root: str, query: Query, rel: str, gates: list[Gate]) -> tuple[dict[str, list[Site]], list[Constant]]:
    lines = _read(os.path.join(root, rel)).splitlines()
    pattern = re.compile(query.pattern)
    found: dict[str, list[Site]] = {}
    constants: list[Constant] = []
    for number, line in enumerate(lines, 1):
        for match in pattern.finditer(line):
            name = match.group(1)
            kind, constant = _swift_kind(line, match.start(), match.end())
            found.setdefault(name, []).append(Site("%s:%d" % (rel, number), kind, gates[number - 1]))
            if constant:
                constants.append(Constant(name, constant, rel, number, _swift_owner(lines, number - 1)))
    return found, constants


def _join(directory: str, path: str) -> str:
    return os.path.normpath(os.path.join(directory, path)).replace(os.sep, "/")


class RustTree:
    """The tree's Rust files, each with the gate of the whole file (its cfgs through the `mod` chain)."""

    MOD_LINE = r"^\s*(pub(\([^)]*\))?\s+)?mod\s+[A-Za-z_][A-Za-z0-9_]*\s*;"
    PATH_LINE = r'#\[path\s*=\s*"[^"]+"\]'

    def __init__(self, root: str):
        self.root = root
        self._files: dict[str, RustFile] = {}
        self._gates: dict[str, Gate] = {}
        self._by_name: dict[str, list[str]] | None = None
        self._by_path: dict[str, list[str]] | None = None
        self._modules: dict[str, frozenset[tuple[str, ...]]] = {}

    def file(self, rel: str) -> RustFile:
        if rel not in self._files:
            self._files[rel] = analyze_rust(_read(os.path.join(self.root, rel)))
        return self._files[rel]

    def _index(self) -> None:
        """Who may declare each file: by module name (`mod name;`) and by `#[path = "..."]` target."""
        if self._by_name is not None:
            return
        self._by_name, self._by_path = {}, {}
        for path, _, line in _grep(self.root, self.MOD_LINE, RUST_TOP, ".rs"):
            name = re.search(r"\bmod\s+(\w+)", line)
            if name:
                self._by_name.setdefault(name.group(1), []).append(path)
        for path, _, line in _grep(self.root, self.PATH_LINE, RUST_TOP, ".rs"):
            for target in re.findall(r'#\[path\s*=\s*"([^"]+)"\]', line):
                self._by_path.setdefault(_join(os.path.dirname(path), target), []).append(path)

    @staticmethod
    def _child_paths(parent: str, name: str) -> tuple[str, ...]:
        """Where `mod name;` in `parent` finds its file (Rust 2018): next to a mod.rs, lib.rs, main.rs or
        build.rs, and in the folder named after any other file."""
        directory, base = os.path.dirname(parent), os.path.basename(parent)
        if base not in ("mod.rs", "lib.rs", "main.rs", "build.rs"):
            directory = os.path.join(directory, base[:-3])
        return (_join(directory, name + ".rs"), _join(directory, name + "/mod.rs"))

    def _declarations(self, rel: str) -> list[tuple[str, str, Gate]]:
        """(parent file, module name, gate of its `mod` line) of every declaration that includes `rel`."""
        self._index()
        out: list[tuple[str, str, Gate]] = []
        for parent in self._by_path.get(rel, []):
            for declared, path_attr, gate in self.file(parent).mods:
                if path_attr and _join(os.path.dirname(parent), path_attr) == rel:
                    out.append((parent, declared, gate))
        parts = rel.split("/")
        name = parts[-2] if parts[-1] == "mod.rs" else parts[-1][:-3]
        for parent in self._by_name.get(name, []):
            if parent == rel or rel not in self._child_paths(parent, name):
                continue
            for declared, path_attr, gate in self.file(parent).mods:
                if declared == name and path_attr is None:
                    out.append((parent, name, gate))
        return out

    @staticmethod
    def _crate_root(rel: str) -> bool:
        parts = rel.split("/")
        return (len(parts) > 4 and parts[3] in RUST_TEST_DIRS) or (len(parts) == 4 and parts[-1] == "build.rs")

    def modules(self, rel: str, seen: frozenset[str] = frozenset()) -> frozenset[tuple[str, ...]]:
        """The module paths of a file in its crate (`crate::a::b` is ("a", "b")): through the `mod`
        declarations that include it, else from its place under src/."""
        if rel in self._modules:
            return self._modules[rel]
        out: set[tuple[str, ...]] = set()
        if not self._crate_root(rel):
            for parent, name, _ in self._declarations(rel):
                if parent not in seen:
                    out |= {path + (name,) for path in self.modules(parent, seen | {rel})}
        if not out:
            parts = rel.split("/")[3:]
            inner = parts[parts.index("src") + 1:] if "src" in parts[:-1] else []
            if inner[:1] == ["bin"] or inner[-1:] in (["lib.rs"], ["main.rs"]):
                inner = []
            elif inner[-1:] == ["mod.rs"]:
                inner = inner[:-1]
            elif inner:
                inner[-1] = inner[-1][:-3]
            out.add(tuple(inner))
        modules = frozenset(out)
        if not seen:
            self._modules[rel] = modules
        return modules

    def gate(self, rel: str, seen: frozenset[str] = frozenset()) -> Gate:
        if rel in self._gates:
            return self._gates[rel]
        parts = rel.split("/")
        gates = [self.file(rel).file_gate]
        if len(parts) > 4 and parts[3] in RUST_TEST_DIRS:  # cmux-tui/crates/<crate>/tests/...
            gates.append(Gate(parts[3] + "/", False, False, False))
        elif parts[-1] == "build.rs" and len(parts) == 4:
            gates.append(Gate("build.rs", None, None, None))
        else:
            included = [_combine([self.gate(parent, seen | {rel}), gate])
                        for parent, _, gate in self._declarations(rel) if parent not in seen]
            if included:
                gates.append(_either(included))
        gate = _combine(gates)
        self._gates[rel] = gate
        return gate


def scan_rust(tree: RustTree, query: Query, rel: str) -> tuple[dict[str, list[Site]], list[Constant]]:
    parsed, file_gate = tree.file(rel), tree.gate(rel)
    pattern = re.compile(query.pattern)
    found: dict[str, list[Site]] = {}
    constants: list[Constant] = []
    for number, line in enumerate(_read(os.path.join(tree.root, rel)).splitlines(), 1):
        for match in pattern.finditer(line):
            name = match.group(1)
            token_kind, gate = parsed.at(number, match.start())
            kind, constant = ("comment", None) if token_kind == "comment" else _rust_kind(line[:match.start()])
            found.setdefault(name, []).append(Site("%s:%d" % (rel, number), kind, _combine([file_gate, gate])))
            if constant:
                constants.append(Constant(name, constant, rel, number, None))
    return found, constants


def _crate(rel: str) -> str:
    return "/".join(rel.split("/")[:3])


class RustPaths:
    """Which Rust constant a path names. A path that starts with `crate`, `self` or `super` resolves in its
    crate; another (a crate name, or a module in scope) names a constant whose module is its last segment;
    a bare name is a constant of its own module or one that a `use` there (a glob `use` too) brings in.
    Modules are files and inline `mod name { }` blocks."""

    def __init__(self, tree: RustTree, files: Iterable[str]):
        self.tree = tree
        self.crate_files: dict[str, list[str]] = {}  # the files that may re-export a constant
        for rel in sorted(set(files)):
            self.crate_files.setdefault(_crate(rel), []).append(rel)

    def _modules(self, rel: str, scope: tuple[str, ...]) -> frozenset[tuple[str, ...]]:
        return frozenset(path + scope for path in self.tree.modules(rel))

    def _home(self, constant: Constant) -> tuple[tuple[str, ...], frozenset[tuple[str, ...]]]:
        """(inline module, crate module paths) of the constant's declaration."""
        scope = self.tree.file(constant.rel).scope(constant.line, 1 << 30)
        return scope, self._modules(constant.rel, scope)

    def module_names(self, constant: Constant) -> set[str]:
        crate_name = _crate(constant.rel).rsplit("/", 1)[-1].replace("-", "_")
        return {path[-1] if path else crate_name for path in self._home(constant)[1]}

    @staticmethod
    def resolve(here: frozenset[tuple[str, ...]], segments: tuple[str, ...]) -> set[tuple[str, ...]] | None:
        """The crate modules that `segments`, written in module `here`, may name; None unless it starts with
        `crate`, `self` or `super`."""
        if segments[:1] == ("crate",):
            return {segments[1:]}
        if segments[:1] == ("self",):
            return {path + segments[1:] for path in here}
        if segments[:1] != ("super",):
            return None
        ups = len(segments) - len(tuple(segment for segment in segments if segment != "super"))
        return {path[:len(path) - ups] + segments[ups:] for path in here if ups <= len(path)}

    def names_module(self, crate: str, here: frozenset[tuple[str, ...]], segments: tuple[str, ...],
                     constant: Constant, reexport: bool = True) -> bool:
        """Whether module path `segments`, written in module `here` of `crate`, is the constant's module or
        (one level) a module that imports the constant."""
        targets = self.resolve(here, segments)
        if targets is None:
            return bool(segments) and segments[-1] in self.module_names(constant)
        if crate != _crate(constant.rel):
            return False
        if targets & self._home(constant)[1]:
            return True
        return reexport and any(
            self._modules(other, scope) & targets and self.brings(crate, self._modules(other, scope), leaf, constant)
            for other in self.crate_files.get(crate, []) for scope, *leaf in self.tree.file(other).imports)

    def brings(self, crate: str, here: frozenset[tuple[str, ...]], leaf: list, constant: Constant) -> bool:
        """Whether the `use` leaf (module, name, local), in module `here`, brings the constant in under its
        own name."""
        module, name, local = leaf
        return ((name == "*" or (name == constant.ident and local == constant.ident))
                and self.names_module(crate, here, module, constant, reexport=False))

    def names(self, rel: str, line: int, column: int, qualifier: tuple[str, ...], constant: Constant) -> bool:
        """Whether `qualifier::IDENT` (a bare IDENT when empty) at (line, column) of `rel` names the constant."""
        scope, crate = self.tree.file(rel).scope(line, column), _crate(rel)
        here = self._modules(rel, scope)
        if not qualifier:
            return ((rel == constant.rel and scope == self._home(constant)[0])
                    or any(self.brings(crate, here, leaf, constant)
                           for inline, *leaf in self.tree.file(rel).imports if inline == scope))
        if rel == constant.rel and (qualifier[-1] == "Self" or qualifier[-1][:1].isupper()):
            return True  # an associated constant of a type in this file
        return self.names_module(crate, here, qualifier, constant)


def constant_uses(root: str, query: Query, constants: list[Constant], tree: RustTree,
                  swift_gates_of) -> list[tuple[str, Site]]:
    """(env name, site) for every use of a constant. An identifier declared once (in the sources for
    Swift, in the crate for Rust) counts everywhere there. Otherwise a Rust use counts when its path names
    the constant (RustPaths); a Swift use counts when it is qualified by the constant's type, or
    unqualified (or `Self.`) inside that type or an extension of it."""
    if not constants:
        return []
    idents = sorted({constant.ident for constant in constants})
    word = r"(^|[^A-Za-z0-9_])(%s)([^A-Za-z0-9_]|$)" % "|".join(re.escape(ident) for ident in idents)
    rows = _grep(root, word, query.top, query.suffix)
    swift = query.suffix == ".swift"
    declaration = (re.compile(r"\b(?:let|var)\s+(\w+)\s*(?::\s*String\s*)?=") if swift
                   else re.compile(r"\b(?:const|static)\s+(?:mut\s+)?([A-Z][A-Z0-9_]*)\s*:"))
    declared: dict[tuple[str, str], int] = {}  # (ident, "" for Swift or the crate) -> declarations
    for path, _, line in rows:
        for match in declaration.finditer(line):
            key = (match.group(1), "" if swift else _crate(path))
            declared[key] = declared.get(key, 0) + 1
    lines_of: dict[str, list[str]] = {}
    by_ident: dict[str, list[Constant]] = {}
    for constant in constants:
        by_ident.setdefault(constant.ident, []).append(constant)
    paths = RustPaths(tree, (row[0] for row in rows))

    def counts(constant: Constant, path: str, number: int, line: str, column: int) -> bool:
        if path == constant.rel and number == constant.line:
            return False
        unique = declared.get((constant.ident, "" if swift else _crate(constant.rel)), 0) == 1
        if not swift:
            if unique and _crate(path) == _crate(constant.rel):
                return True
            qualifier = re.search(r"(?:[A-Za-z_]\w*\s*::\s*)*$", line[:column]).group(0)
            return paths.names(path, number, column, tuple(re.findall(r"[A-Za-z_]\w*", qualifier)), constant)
        if unique:
            return True
        qualifier = re.search(r"(\w+)\s*\.\s*$", line[:column])
        if qualifier and qualifier.group(1) not in ("Self", "self"):
            return qualifier.group(1) == constant.owner
        lines = lines_of.setdefault(path, _read(os.path.join(root, path)).splitlines())
        return constant.owner is not None and _swift_owner(lines, number - 1) == constant.owner

    out: list[tuple[str, Site]] = []
    for path, number, line in rows:
        for match in re.finditer(word, line):
            ident, column = match.group(2), match.start(2)
            for constant in by_ident.get(ident, []):
                if not counts(constant, path, number, line, column):
                    continue
                if swift:
                    if _swift_comment(line[:column]):
                        continue
                    gate = swift_gates_of(path)[number - 1]
                else:
                    token_kind, token_gate = tree.file(path).at(number, column)
                    if token_kind == "comment":
                        continue
                    gate = _combine([tree.gate(path), token_gate])
                out.append((constant.name, Site("%s:%d" % (path, number), "via " + ident, gate)))
    return out


def scan(root: str = ROOT) -> dict[str, dict[str, list[Site]]]:
    """{scope: {name: [sites]}}: every name each query returns, with every site."""
    out: dict[str, dict[str, list[Site]]] = {}
    tree = RustTree(root)
    gate_cache: dict[str, list[Gate]] = {}

    def swift_gates_of(rel: str) -> list[Gate]:
        if rel not in gate_cache:
            gate_cache[rel] = swift_gates(_read(os.path.join(root, rel)))
        return gate_cache[rel]

    for query in QUERIES:
        names: dict[str, list[Site]] = {}
        constants: list[Constant] = []
        for rel in candidate_files(root, query):
            if query.suffix == ".swift":
                found, declared = scan_swift(root, query, rel, swift_gates_of(rel))
            else:
                found, declared = scan_rust(tree, query, rel)
            constants += declared
            for name, sites in found.items():
                names.setdefault(name, []).extend(sites)
        for name, site in constant_uses(root, query, constants, tree, swift_gates_of):
            names[name].append(site)
        out[query.scope] = {name: sorted(set(sites), key=_sort_key) for name, sites in sorted(names.items())}
    return out


# ---------------------------------------------------------------------------------------------
# Classification

def effective_sites(sites: list[Site]) -> list[Site]:
    """The code sites that decide a name's class: a constant's declaration counts only when no use of a
    constant holding the name was found."""
    used = any(site.kind.startswith("via ") for site in sites)
    return [site for site in sites if site.kind != "comment" and not (used and site.kind == "constant")]


def automatic_class(scope: str, sites: list[Site]) -> str | None:
    """The automatic class of a name, or None when a Release build may compile one of its code sites."""
    code = effective_sites(sites)
    if not code:
        return "docOnly"
    if any(site.gate.release is not False for site in code):
        return None
    if scope == "daemon":
        return "testOnly" if all(site.gate.debug is False for site in code) else "debugOnly"
    return "benchOnly" if any(site.gate.bench is not False for site in code) else "debugOnly"


def release_sites(sites: list[Site]) -> list[Site]:
    return [site for site in effective_sites(sites) if site.gate.release is not False]


def load_audit(root: str) -> dict:
    path = os.path.join(root, AUDIT)
    if not os.path.exists(path):
        return {"app": {}, "daemon": {}}
    try:
        with open(path, encoding="utf-8") as handle:
            document = json.load(handle)
    except (OSError, json.JSONDecodeError) as error:
        raise AuditError("cannot read %s: %s" % (AUDIT, error)) from error
    for query in QUERIES:
        if not isinstance(document.get(query.scope), dict):
            raise AuditError("%s has no %r object" % (AUDIT, query.scope))
    return document


def replaced_names(root: str) -> dict[str, str]:
    """env name -> the feature in features.d that lists it in `replaces`."""
    out: dict[str, str] = {}
    directory = os.path.join(root, FEATURES_DIR)
    if not os.path.isdir(directory):
        return out
    for name in sorted(os.listdir(directory)):
        if not name.endswith(".json"):
            continue
        try:
            with open(os.path.join(directory, name), encoding="utf-8") as handle:
                feature = json.load(handle)
        except (OSError, json.JSONDecodeError):
            continue
        for key in feature.get("replaces", []) if isinstance(feature, dict) else []:
            if isinstance(key, str) and key.startswith("CMUX_"):
                out[key] = feature.get("name", name[:-5])
    return out


@dataclass(frozen=True)
class Finding:
    scope: str
    name: str
    where: str
    reason: str
    blocking: bool  # --check fails on it


def _followup_errors(followups: object) -> list[str]:
    if not isinstance(followups, dict):
        return ["`followups` is not an object"]
    errors = []
    for key, followup in followups.items():
        if not isinstance(followup, dict) or not str(followup.get("title", "")).strip():
            errors.append("follow-up %s needs a title" % key)
            continue
        resolution = followup.get("resolution", "")
        if resolution != COMPILE_OUT and not re.fullmatch(r"feature:[a-z][A-Za-z0-9]*", str(resolution)):
            errors.append("follow-up %s: resolution must be %r or feature:<name>, not %r"
                          % (key, COMPILE_OUT, resolution))
    return errors


def audit(root: str, scanned: dict[str, dict[str, list[Site]]], document: dict) -> list[Finding]:
    """What --check and --unclassified report: blocking findings, and the open perf-path follow-ups."""
    raw = document.get("followups", {})
    findings = [Finding("-", "followups", AUDIT, error, True) for error in _followup_errors(raw)]
    followups = {key: value for key, value in raw.items() if isinstance(value, dict)} if isinstance(raw, dict) else {}
    replaced = replaced_names(root)
    for query in QUERIES:
        entries = document.get(query.scope, {})
        for name, sites in scanned[query.scope].items():
            first = (release_sites(sites) or sites)[0].at
            entry = entries.get(name)
            automatic = automatic_class(query.scope, sites)

            def add(reason: str, blocking: bool = True) -> None:
                findings.append(Finding(query.scope, name, first, reason, blocking))

            if not isinstance(entry, dict):
                add("new name: run --write, then set its class and note")
                continue
            klass, key = entry.get("class"), entry.get("followup")
            if klass == UNCLASSIFIED:
                add("unclassified")
            elif klass not in CLASSES:
                add("unknown class %r" % klass)
            elif klass in AUTO_CLASSES and klass != automatic:
                add("recorded %s, now %s: run --write and classify it" % (klass, automatic or "compiled into Release"))
            elif klass in MANUAL_CLASSES and not str(entry.get("note", "")).strip():
                add("%s needs a note" % klass)
            elif key is not None and key not in followups:
                add("follow-up %r is not in `followups`" % key)
            elif klass == "releasePerfPath" and key is None:
                add("releasePerfPath needs a follow-up")
            elif klass == "releasePerfPath":
                resolution = followups[key].get("resolution")
                if resolution == COMPILE_OUT and automatic:
                    add("resolved (now %s): --write records it" % automatic, False)
                elif resolution == COMPILE_OUT:
                    add("perf path: %s, compile it out of Release" % key, False)
                elif name not in replaced:
                    add("perf path: %s, %s with this name in `replaces`" % (key, resolution), False)
    return findings


def stale_names(scanned: dict[str, dict[str, list[Site]]], document: dict) -> list[tuple[str, str]]:
    return [(query.scope, name) for query in QUERIES for name in sorted(document.get(query.scope, {}))
            if name not in scanned[query.scope]]


CLASS_NOTES = {
    **AUTO_NOTES,
    "childEnv": "Set, forwarded or removed for a child process; it does not change this process.",
    "devGated": "Compiled into Release; read only behind a runtime DEV, tagged, bench or test check.",
    "releaseConfig": "Changes Release behavior off the perf paths: paths, ids, endpoints, binaries, opt-outs.",
    "diagnostics": "An opt-in measurement or diagnostics switch that Release honors: tracing, probes, thresholds "
                   "(Chrome keeps these as documented switches, like --trace-startup).",
    "releasePerfPath": "Changes Release behavior on a perf path; its follow-up makes it a feature or compiles it out.",
    "notEnv": "Not an environment name: a prefix of a family of names, or message text.",
    UNCLASSIFIED: "Compiled into Release and not yet classified (MQ7).",
}


def rewrite(scanned: dict[str, dict[str, list[Site]]], document: dict) -> dict:
    """The audit document for this scan: classifications kept, automatic classes recomputed (a compiled-out
    perf-path name takes its automatic class), sites fresh."""
    out = {"$comment": "Written by scripts/features/env_audit.py --write: the sites and the automatic classes. "
                       "The class, note and followup of the other names and the followups are kept by hand. The "
                       "script's docstring has the queries and the classes.",
           "classes": CLASS_NOTES, "followups": document.get("followups", {})}
    for query in QUERIES:
        previous = document.get(query.scope, {})
        entries = {}
        for name, sites in scanned[query.scope].items():
            old = previous.get(name) if isinstance(previous.get(name), dict) else {}
            automatic = automatic_class(query.scope, sites)
            resolved = old.get("class") == "releasePerfPath" and automatic is not None
            if old.get("class") in MANUAL_CLASSES and not resolved:
                entry = {key: old[key] for key in ("class", "note", "followup") if key in old}
            elif automatic:
                entry = {"class": automatic, "auto": True}
            else:
                entry = {"class": UNCLASSIFIED, **({"note": old["note"]} if old.get("note") else {})}
            entry["sites"] = [site.document() for site in sites]
            entries[name] = entry
        out[query.scope] = entries
    return out


def dumps(document: dict) -> str:
    """Stable JSON with one site per line, so a diff shows the sites that moved."""
    scopes = [query.scope for query in QUERIES]
    parts = []
    for key, value in document.items():
        if key not in scopes:
            text = json.dumps(value, indent=2, ensure_ascii=False).replace("\n", "\n  ")
            parts.append("  %s: %s" % (json.dumps(key), text))
            continue
        names = []
        for name, entry in value.items():
            rows = ["      %s: %s" % (json.dumps(field_name), json.dumps(field_value, ensure_ascii=False))
                    for field_name, field_value in entry.items() if field_name != "sites"]
            sites = ",\n".join("        " + json.dumps(site, ensure_ascii=False) for site in entry.get("sites", []))
            rows.append('      "sites": [\n%s\n      ]' % sites if sites else '      "sites": []')
            names.append("    %s: {\n%s\n    }" % (json.dumps(name), ",\n".join(rows)))
        parts.append("  %s: {\n%s\n  }" % (json.dumps(key), ",\n".join(names)))
    return "{\n" + ",\n".join(parts) + "\n}\n"


# ---------------------------------------------------------------------------------------------
# Command line

def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true", help="exit 1 on a new, unclassified or no longer true entry")
    mode.add_argument("--unclassified", action="store_true",
                      help="MQ7: names to classify and open perf-path follow-ups")
    mode.add_argument("--write", action="store_true", help="rewrite %s from a fresh scan" % AUDIT)
    mode.add_argument("--summary", action="store_true", help="names per scope and class")
    parser.add_argument("--root", default=ROOT, help="the checkout (default: this script's)")
    parser.add_argument("--json", action="store_true", help="with --unclassified: JSON rows")
    parser.add_argument("--counts", action="store_true", help="with --unclassified: counts only")
    args = parser.parse_args(argv)
    try:
        scanned = scan(args.root)
        document = load_audit(args.root)
    except AuditError as error:
        print("env_audit: %s" % error, file=sys.stderr)
        return 2

    if args.write:
        updated = rewrite(scanned, document)
        os.makedirs(os.path.dirname(os.path.join(args.root, AUDIT)), exist_ok=True)
        with open(os.path.join(args.root, AUDIT), "w", encoding="utf-8") as handle:
            handle.write(dumps(updated))
        for scope, name in stale_names(scanned, document):
            print("removed %s %s (no query returns it)" % (scope, name))
        open_rows = [row for row in audit(args.root, scanned, updated) if row.blocking]
        print("wrote %s: %d app and %d daemon names, %d to classify"
              % (AUDIT, len(updated["app"]), len(updated["daemon"]), len(open_rows)))
        return 0

    findings = audit(args.root, scanned, document)
    if args.summary:
        for query in QUERIES:
            counts: dict[str, int] = {}
            for name in scanned[query.scope]:
                entry = document.get(query.scope, {}).get(name)
                klass = entry.get("class", UNCLASSIFIED) if isinstance(entry, dict) else "new"
                counts[klass] = counts.get(klass, 0) + 1
            print("%s: %d names; %s" % (query.scope, len(scanned[query.scope]),
                                         ", ".join("%s %d" % item for item in sorted(counts.items()))))
        return 0
    if args.unclassified:
        if args.counts:
            blocking = sum(1 for row in findings if row.blocking)
            print("MQ7 env switches: %d to classify, %d perf-path follow-ups" % (blocking, len(findings) - blocking))
        elif args.json:
            print(json.dumps([row.__dict__ for row in findings], indent=2))
        else:
            for row in findings:
                print("%-7s %-48s %s  %s" % (row.scope, row.name, row.reason, row.where))
        return 0

    blocking = [row for row in findings if row.blocking]
    for scope, name in stale_names(scanned, document):
        print("note: %s %s is in %s but no query returns it; --write removes it" % (scope, name, AUDIT),
              file=sys.stderr)
    for row in blocking:
        print("%s %s: %s (%s)" % (row.scope, row.name, row.reason, row.where), file=sys.stderr)
    if blocking:
        print("env_audit: %d of %d names need a classification in %s (python3 scripts/features/env_audit.py "
              "--write, then set class and note)" % (len(blocking), sum(map(len, scanned.values())), AUDIT),
              file=sys.stderr)
        return 1
    print("env_audit: %d app and %d daemon names classified; %d perf-path follow-ups open"
          % (len(scanned["app"]), len(scanned["daemon"]), len(findings)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
