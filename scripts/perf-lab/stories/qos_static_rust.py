#!/usr/bin/env python3
"""Story qos-static-rust: Rust threads started with no declared QoS (target row qos.rust).

A site is one production `thread::spawn` or `thread::Builder::new()` in `cmux-tui/crates/<crate>/src`. It is
declared when the first lines of the thread's closure set the thread's class (a QoS call, below) or when a
`// qos: <reason>` comment sits on the site's line, in the comment block directly above it or in those first lines.
`cmux_threads::spawn(name, qos, f)` takes its class as an argument, so it is never a site, and its own Builder (SEAMS)
is not one either. `qos.undeclared_rust` is
the number of undeclared sites, and target row qos.rust wants 0. Chromium's model: every thread starts with a
ThreadType (base/threading/platform_thread.h, `PlatformThread::CreateWithType`), never at an inherited default.

A QoS call is `cmux_threads::set_current`, `with_qos`, `register_current`, `QosScope::enter`,
`cmux_tui_platform::qos::WorkQos::enter`, cmux-tui-core's `thread_qos::set`, libc's `pthread_set_qos_class_self_np`,
or a call to a function of the same file whose first lines make one (cmux-holder's `run_at_echo_qos()`). A thread
whose body is such a function by name (`.spawn(listen)`) is judged by that function's first lines.

Production means compiled into a non-test build. Test code is excluded the way rustc excludes it: an item under
`#[cfg(test)]` (or a cfg that needs `test`, such as `all(test, unix)`), a `#[test]` function, a file whose
`#![cfg(test)]` says so, and every file that a test-only `mod NAME;` (or `include!`) brings in, with all its
submodules; `#[path]` and inline `mod NAME { mod child; }` resolve as rustc resolves them. `tests/`,
`examples/` and `benches/` sit outside `src` and are never read. A file that no crate root reaches is counted: the
story cannot prove it is test-only. Comments and string literals are masked before matching.

Linux, no build: it reads git objects only (ls-tree, cat-file), so the list is deterministic for a commit. The
counted commit, the runner arguments and the session follow stories/qos_static.py (its `measured_rev`).

  python3 scripts/perf-lab/stories/qos_static_rust.py --repo .                    # the count and the count per crate
  python3 scripts/perf-lab/stories/qos_static_rust.py --repo . --list             # MQ14: every site, by crate
  python3 scripts/perf-lab/stories/qos_static_rust.py --repo . --list --crate cmux-holder
  python3 scripts/perf-lab/stories/qos_static_rust.py --repo . --json
  python3 scripts/perf-lab/stories/qos_static_rust.py --repo . --out DIR          # result-v1 into DIR, sites beside it

Not a CI gate (Lawrence 2026-10-23); the lab runs it as a `linux` tier story (stories.d/qos-static-rust.json).
"""
from __future__ import annotations

import sys

sys.dont_write_bytecode = True  # importing the Swift story and its siblings must not write __pycache__

import argparse
import bisect
import collections
import hashlib
import importlib.util
import itertools
import json
import os
import posixpath
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path
from types import ModuleType
from typing import Iterable, Mapping

HERE = Path(__file__).resolve().parent
PERF_LAB = HERE.parent
SCRIPTS = PERF_LAB.parent

STORY = "qos-static-rust"
METRIC = "qos.undeclared_rust"
TARGET_ROW = "qos.rust"
SITES_FILE = "qos-static-rust.sites.json"
CRATES = "cmux-tui/crates/"
# The closure's first lines: its opening line and the next ones. A class set later leaves the thread's start, and
# everything it does first, at the inherited default.
FIRST_LINES = 4
QOS_COMMENT = re.compile(r"//\s*qos:\s*\S")
# The declaring seam itself: its Builder is handed to `start`, whose closure registers the thread at the caller's
# class before `f` runs. Every thread started through it declares its class, so its own Builder is no site.
SEAMS = frozenset({CRATES + "cmux-threads/src/spawn.rs"})


def load_by_path(name: str, path: Path) -> ModuleType:
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module  # dataclasses resolve their module through sys.modules
    spec.loader.exec_module(module)
    return module


swift_story = load_by_path("perf_lab_qos_static_rust_swift_story", HERE / "qos_static.py")
perf_result = swift_story.perf_result
StoryError = swift_story.StoryError  # app_commit and measured_rev raise it
SESSION, SESSION_ENV = swift_story.SESSION, swift_story.SESSION_ENV
STATIC_HOST, STATIC_CONFIG = swift_story.STATIC_HOST, swift_story.STATIC_CONFIG
MEASURE_VERSION = 1


# ---------------------------------------------------------------------------------------------------------------
# Masking: comments and literals become spaces (newlines kept), so offsets and line numbers stay the source's.

# The next place where a comment or a literal may start: `//`, `/*`, a raw string, a string, a quote.
LEXEME = re.compile(r"""/[/*]|(?<![A-Za-z0-9_])(?:b|c)?r(#*)"|"|'""")
BLOCK_EDGE = re.compile(r"/\*|\*/")
STRING_END = re.compile(r'(?:[^"\\]|\\.)*"', re.S)
CHAR_LITERAL = re.compile(r"'(?:\\(?:u\{[0-9A-Fa-f_]*\}|x[0-9A-Fa-f]{2}|.)|[^\\'\n])'", re.S)
NOT_NEWLINE = re.compile(r"[^\n]")


def mask(source: str) -> str:
    pieces, done, i, n = [], 0, 0, len(source)

    def blank(start: int, end: int) -> None:
        nonlocal done
        pieces.append(source[done:start])
        pieces.append(NOT_NEWLINE.sub(" ", source[start:end]))
        done = end

    while True:
        match = LEXEME.search(source, i)
        if match is None:
            break
        token, i = match.group(0), match.start()
        if token == "//":
            end = source.find("\n", i)
            end = n if end < 0 else end
            blank(i, end)
            i = end
        elif token == "/*":
            depth, k = 1, i + 2
            while depth:
                edge = BLOCK_EDGE.search(source, k)
                if edge is None:
                    k = n
                    break
                depth += 1 if edge.group(0) == "/*" else -1
                k = edge.end()
            blank(i, k)
            i = k
        elif token.endswith('"') and token != '"':  # r"..", r#".."#, br"..", cr".."
            close = '"' + match.group(1)
            end = source.find(close, match.end())
            end = n if end < 0 else end
            blank(match.end(), end)
            i = min(n, end + len(close))
        elif token == '"':
            end = STRING_END.match(source, i + 1)
            stop = end.end() - 1 if end else n
            blank(i + 1, stop)
            i = stop + 1
        else:  # a quote: a char literal ('x', '\n', '\u{1F600}'), else a lifetime or a label
            char = CHAR_LITERAL.match(source, i)
            if char:
                blank(i + 1, char.end() - 1)
                i = char.end()
            else:
                i += 1
    pieces.append(source[done:])
    return "".join(pieces)


# ---------------------------------------------------------------------------------------------------------------
# Brackets, attributes and items.

BRACKET = re.compile(r"[()\[\]{}]")
ITEM_EDGE = re.compile(r"[;()\[\]{}]")


def matching(masked: str, start: int) -> int:
    """The offset just past the bracket that closes the one at START (len when it never closes)."""
    depth = 0
    for bracket in BRACKET.finditer(masked, start):
        depth += 1 if bracket.group(0) in "([{" else -1
        if depth == 0:
            return bracket.end()
    return len(masked)


def item_end(masked: str, start: int) -> int:
    """The end of the item or statement at START: its `;` or its body's closing brace, at bracket depth 0."""
    k = start
    while True:
        edge = ITEM_EDGE.search(masked, k)
        if edge is None:
            return len(masked)
        c = edge.group(0)
        if c == ";":
            return edge.end()
        if c == "{":
            return matching(masked, edge.start())
        if c in "([":
            k = matching(masked, edge.start())
            continue
        return edge.start()  # the enclosing block ends first (an attribute on the last expression)


ATTRIBUTE = re.compile(r"#(!?)\[")
WHITESPACE = re.compile(r"\s*")
STACKED_ATTRIBUTE = re.compile(r"\s*#\[")
CFG_TOKEN = re.compile(r"\s*(?:([A-Za-z_][A-Za-z0-9_]*)\s*(\()?|(\))|(,)|(=\s*\"[^\"]*\"))")


def needs_test(predicate: str) -> bool:
    """True when cfg PREDICATE can hold only in a test build: `test`, an `all` with such a part, an `any` of them."""
    tokens = []
    for match in CFG_TOKEN.finditer(predicate):
        name, opens, closes, comma, _value = match.groups()
        if name:
            tokens.append(("call", name) if opens else ("name", name))
        elif closes:
            tokens.append(("close", ""))
        elif comma:
            tokens.append(("comma", ""))

    def parse(at: int) -> tuple[bool, int]:
        kind, name = tokens[at] if at < len(tokens) else ("name", "")
        if kind == "name":
            return name == "test", at + 1
        if kind != "call":
            return False, at + 1
        parts, at = [], at + 1
        while at < len(tokens) and tokens[at][0] != "close":
            if tokens[at][0] == "comma":
                at += 1
                continue
            part, at = parse(at)
            parts.append(part)
        at += 1
        if name == "all":
            return any(parts), at
        if name == "any":
            return bool(parts) and all(parts), at
        return False, at  # not(...) and unknown predicates never need test

    return bool(tokens) and parse(0)[0]


def is_test_attribute(body: str) -> bool:
    """BODY is an attribute's text between `#[` and `]`, masked."""
    body = body.strip()
    if re.fullmatch(r"(?:[A-Za-z_][A-Za-z0-9_]*::)*test", body):  # #[test], #[tokio::test]
        return True
    cfg = re.fullmatch(r"cfg\s*\((.*)\)", body, re.S)
    return bool(cfg) and needs_test(cfg.group(1))


@dataclass(frozen=True)
class ModDecl:
    name: str
    offset: int
    test_only: bool
    path_attr: str | None
    inline_parents: tuple[str, ...]
    include: bool = False  # `include!("FILE")`: FILE sits beside the including file


@dataclass
class Parsed:
    masked: str
    test_ranges: list[tuple[int, int]]
    whole_file_test: bool
    mods: list[ModDecl]

    def in_test(self, offset: int) -> bool:
        return self.whole_file_test or any(start <= offset < end for start, end in self.test_ranges)


MOD_DECL = re.compile(r"\bmod\s+(?:r#)?([A-Za-z_][A-Za-z0-9_]*)\s*([;{])")
PATH_ATTR = re.compile(r'path\s*=\s*"([^"]*)"')
INCLUDE = re.compile(r'\binclude!\s*\(\s*"')
STRING_LITERAL = re.compile(r'"([^"\\]*)"')


def parse(source: str) -> Parsed:
    masked = mask(source)
    test_ranges: list[tuple[int, int]] = []
    whole_file_test = False
    path_attrs: dict[int, str] = {}  # item start -> #[path = "..."] value
    k = 0
    while True:
        match = ATTRIBUTE.search(masked, k)
        if match is None:
            break
        close = matching(masked, match.end() - 1)
        body = masked[match.end():close - 1]
        inner = match.group(1) == "!"
        if inner:
            if is_test_attribute(body):
                whole_file_test = whole_file_test or match.start() < first_item(masked)
            k = close
            continue
        # The attribute applies to the item after this attribute and any others stacked on it.
        start = close
        attributes = [(match.start(), close)]
        while True:
            nxt = STACKED_ATTRIBUTE.match(masked, start)
            if not nxt:
                break
            end = matching(masked, nxt.end() - 1)
            attributes.append((nxt.end() - 2, end))
            start = end
        item = WHITESPACE.match(masked, start).end()
        for a_start, a_end in attributes:
            raw = source[a_start + 2:a_end - 1].strip()
            path = PATH_ATTR.fullmatch(raw)
            if path:
                path_attrs[item] = path.group(1)
        if any(is_test_attribute(masked[a + 2:e - 1]) for a, e in attributes):
            test_ranges.append((attributes[0][0], item_end(masked, item)))
        k = start
    inline: list[tuple[str, int, int]] = []  # inline `mod NAME { }` bodies
    found = []
    for match in MOD_DECL.finditer(masked):
        if match.group(2) == "{":
            inline.append((match.group(1), match.end() - 1, matching(masked, match.end() - 1)))
        else:
            found.append(match)
    parsed = Parsed(masked, test_ranges, whole_file_test, [])
    for match in found:
        offset = match.start()
        item = item_start(masked, offset)
        parents = tuple(name for name, start, end in sorted(inline, key=lambda m: m[1]) if start < offset < end)
        parsed.mods.append(ModDecl(match.group(1), offset, parsed.in_test(offset), path_attrs.get(item), parents))
    for match in INCLUDE.finditer(masked):  # the literal is masked: read it from the source at the same offsets
        literal = STRING_LITERAL.match(source, match.end() - 1)
        if literal:
            parsed.mods.append(ModDecl("", match.start(), parsed.in_test(match.start()), literal.group(1), (), True))
    return parsed


def first_item(masked: str) -> int:
    """The offset of the first token that is not an inner attribute (where `#![...]` stops being file-level)."""
    k = 0
    while True:
        rest = INNER_ATTRIBUTE.match(masked, k)
        if not rest:
            return WHITESPACE.match(masked, k).end()
        k = matching(masked, rest.end() - 1)


INNER_ATTRIBUTE = re.compile(r"\s*#!\[")
VISIBILITY = re.compile(r"(?:pub(?:\s*\([^)]*\))?\s+)$")
VISIBILITY_REACH = 64  # `pub(in crate::a::b) ` fits


def item_start(masked: str, offset: int) -> int:
    """OFFSET of `mod`, moved back over a `pub` / `pub(crate)` in front of it (where the attributes end)."""
    window = max(0, offset - VISIBILITY_REACH)
    visibility = VISIBILITY.search(masked, window, offset)
    return visibility.start() if visibility else offset


# ---------------------------------------------------------------------------------------------------------------
# Sites.

QOS_SETTERS = ("set_current", "with_qos", "register_current", "pthread_set_qos_class_self_np")
QOS_ENTERS = ("QosScope", "WorkQos")
QOS_PATHS = (r"thread_qos\s*::\s*set",)  # cmux-tui-core's ThreadType setter (thread_qos.rs)


def qos_call_pattern(helpers: Iterable[str]) -> re.Pattern:
    names = sorted(set(QOS_SETTERS) | set(helpers))
    alternatives = [rf"\b{re.escape(name)}\s*\(" for name in names]
    alternatives += [rf"\b{name}\s*::\s*enter\s*\(" for name in QOS_ENTERS]
    alternatives += [rf"\b{path}\s*\(" for path in QOS_PATHS]
    return re.compile("|".join(alternatives))


FN_DECL = re.compile(r"\bfn\s+([A-Za-z_][A-Za-z0-9_]*)\b")


def function_bodies(masked: str) -> dict[str, list[tuple[int, int]]]:
    """{name: [(the body's `{` offset, the offset past its `}`)]} for every `fn` of the file that has a body."""
    bodies: dict[str, list[tuple[int, int]]] = collections.defaultdict(list)
    for match in FN_DECL.finditer(masked):
        brace = masked.find("{", match.end())
        semi = masked.find(";", match.end())
        if brace >= 0 and not 0 <= semi < brace:
            bodies[match.group(1)].append((brace, matching(masked, brace)))
    return bodies


SPAWN = re.compile(r"\bthread\s*::\s*spawn\b|\bthread\s*::\s*Builder\s*::\s*new\s*\(")
THREAD_IMPORT = re.compile(r"\buse\s+std\s*::\s*thread\s*::\s*(\{[^}]*\}|[A-Za-z_]+)")
BUILDER_SPAWN = re.compile(r"\s*\.\s*spawn(?:_scoped|_unchecked)?\s*\(")
IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
CHAIN_CALL = re.compile(r"\s*(?:\?\s*)?\.\s*[A-Za-z_][A-Za-z0-9_]*\s*(?:::\s*<[^>]*>\s*)?\(")
OPEN_PAREN = re.compile(r"\s*\(")
USE_ITEM = re.compile(r"\buse\s[^;]*;")
FUNCTION_ARG = re.compile(r"\s*(?:[A-Za-z_][A-Za-z0-9_]*\s*::\s*)*([A-Za-z_][A-Za-z0-9_]*)\s*,?\s*")
CLOSURE = re.compile(r"\s*(?:[A-Za-z_][A-Za-z0-9_]*\s*,\s*)?(?:move\s+)?\|")


def site_pattern(masked: str) -> re.Pattern:
    """`thread::spawn` / `thread::Builder::new()`, and their bare names where `use std::thread::...` imports them."""
    imported = set()
    for match in THREAD_IMPORT.finditer(masked):
        names = IDENT.findall(match.group(1))
        imported |= {name for name in names if name in ("spawn", "Builder")}
    alternatives = [SPAWN.pattern]
    if "spawn" in imported:
        alternatives.append(r"(?<![.:\w])spawn\s*\(")
    if "Builder" in imported:
        alternatives.append(r"(?<![:\w])Builder\s*::\s*new\s*\(")
    return re.compile("|".join(alternatives))


def call_args(masked: str, site: re.Match) -> tuple[int, int] | None:
    """The argument span of the call that starts the thread: `spawn(...)`, or a Builder chain's `.spawn(...)`."""
    text = site.group(0)
    if "Builder" in text:
        k = matching(masked, site.end() - 1)
        while k < len(masked):
            nxt = BUILDER_SPAWN.match(masked, k)
            if nxt:
                return nxt.end(), matching(masked, nxt.end() - 1) - 1
            step = CHAIN_CALL.match(masked, k)
            if not step:
                return None
            k = matching(masked, step.end() - 1)
        return None
    paren = OPEN_PAREN.match(masked, site.end())
    if not paren:
        return None  # a path (`.map(thread::spawn)`): no closure to read
    return paren.end(), matching(masked, paren.end() - 1) - 1


@dataclass(frozen=True, order=True)
class Site:
    path: str
    line: int
    text: str

    @property
    def crate(self) -> str:
        return crate_of(self.path)

    def record(self) -> dict:
        return {"crate": self.crate, "path": self.path, "line": self.line, "text": self.text}

    def describe(self) -> str:
        return f"{self.path}:{self.line}: {self.text}"


def crate_of(path: str) -> str:
    return path[len(CRATES):].split("/", 1)[0]


def undeclared_sites(path: str, source: str, parsed: Parsed) -> list[Site]:
    masked = parsed.masked
    imports = [(m.start(), m.end()) for m in USE_ITEM.finditer(masked)]
    matches = [match for match in site_pattern(masked).finditer(masked)
               if not parsed.in_test(match.start()) and not any(a <= match.start() < b for a, b in imports)]
    if not matches:
        return []
    scan = FileScan(source, masked)
    sites = []
    for match in matches:
        number = scan.line_of(match.start())
        if not scan.declared(number, call_args(masked, match)):
            sites.append(Site(path, number, scan.lines[number - 1].strip()))
    return sites


class FileScan:
    """One file's lines, functions and QoS calls, for judging its sites."""

    def __init__(self, source: str, masked: str) -> None:
        self.masked = masked
        self.lines = source.split("\n")
        self.line_starts = list(itertools.accumulate((len(line) + 1 for line in self.lines[:-1]), initial=0))
        self.bodies = function_bodies(masked)
        self.qos_call = qos_call_pattern(())
        # Helpers: functions of this file whose first lines set the class, directly or through another helper.
        helpers: set[str] = set()
        while True:
            found = {name for name, spans in self.bodies.items() if name not in helpers
                     and any(self.starts_declared(start, end) for start, end in spans)}
            if not found:
                break
            helpers |= found
            self.qos_call = qos_call_pattern(helpers)

    def line_of(self, offset: int) -> int:
        """The 1-based line holding OFFSET."""
        return bisect.bisect_right(self.line_starts, offset)

    def declared(self, number: int, args: tuple[int, int] | None) -> bool:
        """A `// qos:` comment on site line NUMBER or in the comment block above it, or a thread body (the closure,
        or the function of this file that the thread runs) whose first lines make a QoS call or say `// qos:`."""
        if QOS_COMMENT.search(self.lines[number - 1]):
            return True
        above = number - 2
        while above >= 0 and self.lines[above].lstrip().startswith("//"):
            if QOS_COMMENT.search(self.lines[above]):
                return True
            above -= 1
        if args is None:
            return False
        start, end = args
        closure = CLOSURE.match(self.masked, start, end)
        if closure:
            return self.starts_declared(closure.end() - 1, end)
        function = FUNCTION_ARG.fullmatch(self.masked, start, end)
        return bool(function) and any(self.starts_declared(body, body_end)
                                      for body, body_end in self.bodies.get(function.group(1), ()))

    def starts_declared(self, start: int, end: int) -> bool:
        """The body at START..END makes a QoS call, or has a `// qos:` comment, in its first FIRST_LINES lines."""
        first = self.line_of(start)
        last = min(first + FIRST_LINES - 1, self.line_of(end))
        region_end = min(end, self.line_starts[last] if last < len(self.line_starts) else len(self.masked))
        if self.qos_call.search(self.masked, start, region_end):
            return True
        return any(QOS_COMMENT.search(self.lines[k - 1]) for k in range(first, last + 1))


# ---------------------------------------------------------------------------------------------------------------
# The tree: which files a test build alone compiles.

def module_dir(path: str) -> str:
    base = posixpath.basename(path)
    if base in ("lib.rs", "main.rs", "mod.rs") or is_crate_root(path):
        return posixpath.dirname(path)
    return path[:-len(".rs")]


def is_crate_root(path: str) -> bool:
    rest = path[len(CRATES):].split("/", 1)[1]  # src/...
    return rest in ("src/lib.rs", "src/main.rs") or bool(re.fullmatch(r"src/bin/[^/]+\.rs|src/bin/[^/]+/main\.rs", rest))


def child_file(parent: str, decl: ModDecl, files: Mapping[str, object]) -> str | None:
    if decl.path_attr is not None:
        base = posixpath.dirname(parent) if decl.include or not decl.inline_parents else posixpath.join(
            module_dir(parent), *decl.inline_parents)
        candidate = posixpath.normpath(posixpath.join(base, decl.path_attr))
        return candidate if candidate in files else None
    base = posixpath.join(module_dir(parent), *decl.inline_parents)
    for candidate in (posixpath.join(base, decl.name + ".rs"), posixpath.join(base, decl.name, "mod.rs")):
        if candidate in files:
            return candidate
    return None


def test_only_files(parsed: Mapping[str, Parsed]) -> set[str]:
    """Files that only a test build compiles: whole-file `#![cfg(test)]`, a test-only `mod NAME;`, and below."""
    edges: dict[str, list[tuple[str, bool]]] = collections.defaultdict(list)
    for path, file in parsed.items():
        for decl in file.mods:
            child = child_file(path, decl, parsed)
            if child is not None:
                edges[path].append((child, decl.test_only))
    roots = sorted(path for path in parsed if is_crate_root(path))
    production = reachable([path for path in roots if not parsed[path].whole_file_test],
                           lambda path: (child for child, test in edges[path]
                                         if not test and not parsed[child].whole_file_test))
    reached = reachable(roots, lambda path: (child for child, _ in edges[path]))
    # Reached only through a test edge: test-only. Never reached: kept (it cannot be proved test-only).
    return reached - production


def reachable(starts: Iterable[str], children) -> set[str]:
    seen: set[str] = set()
    stack = list(starts)
    while stack:
        path = stack.pop()
        if path not in seen:
            seen.add(path)
            stack.extend(children(path))
    return seen


# ---------------------------------------------------------------------------------------------------------------
# Reading a commit.

def git(repo: Path, *args: str, stdin: bytes | None = None) -> bytes:
    done = subprocess.run(["git", "-C", str(repo), *args], input=stdin, capture_output=True)
    if done.returncode != 0:
        raise StoryError(f"git {' '.join(args[:2])} failed in {repo}: {done.stderr.decode(errors='replace').strip()}")
    return done.stdout


SOURCE_PATH = re.compile(re.escape(CRATES) + r"[^/]+/src/.+\.rs")


def read_tree(repo: Path, rev: str) -> tuple[str, dict[str, str]]:
    """(REV's commit sha, {path: text} for every `.rs` file under cmux-tui/crates/*/src at that commit)."""
    try:
        sha = git(repo, "rev-parse", "--verify", "--quiet", f"{rev}^{{commit}}").decode().strip()
    except StoryError:
        raise StoryError(f"{rev} is not a commit in {repo}") from None
    entries = []
    for record in git(repo, "ls-tree", "-r", "-z", sha, "--", CRATES.rstrip("/")).split(b"\0"):
        if not record:
            continue
        meta, path = record.decode().split("\t", 1)
        mode, kind, oid = meta.split()
        if kind == "blob" and mode != "120000" and SOURCE_PATH.fullmatch(path):
            entries.append((path, oid))
    if not entries:
        return sha, {}
    batch = git(repo, "cat-file", "--batch", stdin="".join(f"{oid}\n" for _, oid in entries).encode())
    sources, k = {}, 0
    for path, _ in entries:
        header_end = batch.index(b"\n", k)
        size = int(batch[k:header_end].split()[2])
        sources[path] = batch[header_end + 1:header_end + 1 + size].decode("utf-8", errors="replace")
        k = header_end + 1 + size + 1
    return sha, sources


@dataclass(frozen=True)
class Report:
    sha: str
    sites: tuple[Site, ...]
    files: int

    @property
    def count(self) -> int:
        return len(self.sites)

    @property
    def per_crate(self) -> dict[str, int]:
        counts = collections.Counter(site.crate for site in self.sites)
        return dict(sorted(counts.items(), key=lambda item: (-item[1], item[0])))

    def record(self) -> dict:
        return {"story": STORY, "metric": METRIC, "sha": self.sha, "count": self.count, "files": self.files,
                "crates": self.per_crate, "sites": [site.record() for site in self.sites]}


def judge(sha: str, sources: Mapping[str, str]) -> Report:
    parsed = {path: parse(text) for path, text in sources.items()}
    tests = test_only_files(parsed)
    sites = []
    for path in sorted(parsed):
        if path in tests or path in SEAMS or parsed[path].whole_file_test:
            continue
        sites.extend(undeclared_sites(path, sources[path], parsed[path]))
    return Report(sha, tuple(sorted(sites)), len(parsed) - len(tests))


def count(repo: Path, rev: str = "HEAD") -> Report:
    return judge(*read_tree(repo, rev))


def result(report: Report, run=None):
    """The story's result-v1: one sample, the site count, claiming target row qos.rust."""
    fingerprint = hashlib.sha256("\0".join(STATIC_HOST.values()).encode()).hexdigest()
    return perf_result.Result(
        story=STORY, metric=METRIC, unit="count", better="lower", samples=[report.count],
        build=perf_result.Build(sha=report.sha, config=STATIC_CONFIG, measure_version=MEASURE_VERSION),
        host=perf_result.Host(fingerprint=fingerprint, host_class=STATIC_HOST["class"], chip=STATIC_HOST["chip"],
                              macos=None, macos_build=None, display_hz=None),
        engine="none", session=SESSION, run=run or perf_result.Run.start(),
        target_ref=perf_result.TargetRef(target=TARGET_ROW))


def write(report: Report, out: Path, repo: Path) -> Path:
    """result-v1 into OUT (validated first), and the site list beside it in SITES_FILE (not `*.ndjson`, so the
    ingest reads only the result)."""
    path = perf_result.write_ndjson(out, [result(report)], repo_root=repo)
    temporary = out / f".{SITES_FILE}.tmp"
    temporary.write_text(json.dumps(report.record(), indent=1, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temporary, out / SITES_FILE)
    return path


def parse_args(argv: list[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0],
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo", type=Path, default=None, help="the checkout (default: the one holding the cwd)")
    parser.add_argument("--rev", "--sha", dest="rev", default=None,
                        help=f"the commit to count (default ${swift_story.SHA_ENV}, else --app's CMUXCommit, else HEAD)")
    output = parser.add_mutually_exclusive_group()
    output.add_argument("--list", action="store_true", help="print every site, grouped by crate (MQ14)")
    output.add_argument("--json", action="store_true", help="print the count, the count per crate and the sites")
    parser.add_argument("--crate", action="append", default=None, help="only this crate's sites (repeatable)")
    parser.add_argument("--out", type=Path, default=None,
                        help=f"write the result-v1 file into this directory, and {SITES_FILE} beside it")
    runner = parser.add_argument_group("story runner", "what scripts/perf-lab/run_story.py passes (stories.d/README.md)")
    runner.add_argument("--app", type=Path, default=None, help="the measured build; its CMUXCommit is the commit to count")
    runner.add_argument("--tag", default=None, help="the measured build's tag (unused: a source count runs no app)")
    runner.add_argument("--session", default=None, help=f"the session (default ${SESSION_ENV}); only {SESSION}")
    runner.add_argument("session_word", nargs="?", default=None, metavar="SESSION", help="the session, as a word")
    args = parser.parse_args(argv)
    sessions = {s for s in (args.session, args.session_word) if s is not None}
    if len(sessions) > 1:
        parser.error(f"two sessions: {', '.join(sorted(sessions))}")
    args.session = sessions.pop() if sessions else None
    if args.crate and args.out is not None:
        parser.error("--crate filters what is printed; --out records the whole count")
    return args


def main(argv: list[str] | None = None, environ: Mapping[str, str] | None = None) -> int:
    args = parse_args(argv)
    environ = os.environ if environ is None else environ
    session = args.session or environ.get(SESSION_ENV) or SESSION
    if session != SESSION:
        print(f"{STORY}: session {session!r}: this story runs only {SESSION!r}", file=sys.stderr)
        return 2
    repo = swift_story.repo_root(args.repo)
    try:
        report = count(repo, swift_story.measured_rev(args.rev, args.app, environ))
    except StoryError as error:
        print(f"{STORY}: {error}", file=sys.stderr)
        return 2
    if args.out is not None:
        args.out.mkdir(parents=True, exist_ok=True)
        print(f"{STORY}: wrote {write(report, args.out, repo)}", file=sys.stderr)
    crates = set(args.crate or ())
    shown = [site for site in report.sites if not crates or site.crate in crates]
    if args.json:
        record = report.record()
        if crates:
            record["sites"] = [site.record() for site in shown]
        print(json.dumps(record, sort_keys=True))
    elif args.list:
        by_crate: dict[str, list[Site]] = collections.defaultdict(list)
        for site in shown:
            by_crate[site.crate].append(site)
        for crate in sorted(by_crate):
            print(f"{crate} {len(by_crate[crate])}")
            for site in by_crate[crate]:
                print(f"  {site.describe()}")
    else:
        print(f"{METRIC} {report.count}  ({report.sha}, {report.files} production files)")
        for crate, n in report.per_crate.items():
            if not crates or crate in crates:
                print(f"  {crate} {n}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
