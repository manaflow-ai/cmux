#!/usr/bin/env python3
"""IPC census for the p05-ipc program: the machine queues Q1-Q18 of
plans/cmux-next/chrome-parity/p05-ipc.md, section 6.

Each queue is a list of sites, printed as JSON `[{file, line, key}]` (plus `group` where the spec
groups a queue, for example Q1 by directory). Every queue that the spec defines by a `git grep` also
carries that raw query: the census reports `raw_count` (what `RAW | wc -l` prints) next to `found`
(its sites) and `count` (the sites outside the allowlist), so a reviewer can check the numbers with
one shell command. Q1, Q2, Q7, Q10, Q11, Q13 and Q14 are their raw query (found == raw_count). For
Q3, Q4, Q8 and Q17, which refine it, `--explain QN` lists each raw line the queue drops and each
site it adds, with a reason, so raw_count - dropped + added (+ further sites on one raw line) ==
found; `--queue QN` prints that sum. No count is written in this file: `--record` writes them to
plans/cmux-next/ipc-targets.json, and `--check` compares the tree against that file.

Refinements over the raw queries (each is stated on its queue):
  Q3  Rust tests are dropped (test paths, `#[cfg(test)]` items and modules, `#[test]` functions),
      calls inside the primitives' own definitions are dropped, and the wrappers are derived: any
      function whose body calls a primitive is a wrapper (one level), and each call of it is a site
      (caller-of-wrapper), so a new wrapper is counted without a regex change. A call reaches the
      definitions of its name that fit its form (method, `Type::`, free) and argument count; when
      they mix a wrapper and a function that wraps nothing, the site says `ambiguous wrapper`.
  Q4  `DaemonConnection(` counts with its first argument label on the same or the next line; raw
      `connect(fd, $0, ...)` calls, `NWConnection(to: .unix` and `DaemonBridge.open` count too;
      comments and strings never count. Sockets that are not a cmux-tui daemon (acpmux, the
      browser host, the control socket, Tasks) and LineTransport's own connect are allowlisted
      in ipc-targets.json with their reason, so the census still sees each one.
  Q8  thread name sites in cmux-tui/crates (tests dropped) whose spawned body does not begin with
      `cmux_tui_platform::qos::set_current` (or `cmux_threads::set_current`, `thread_qos::set`, or
      the `registry::register_current` of `cmux_threads::spawn`, which sets the declared QoS before
      the closure runs), plus journal writers spawned by name. The body is the
      `.spawn(` of the name's own builder chain (or of the `let` that holds the builder). A
      `.name(var)` of a thread builder counts too: the variable resolves through its `let`, a
      `for` loop over literals, or the arguments callers pass for a parameter; a name the census
      cannot follow is `<unresolved>`, never dropped.
  Q12 a decoder case that delegates to a name set (`case _ where T.eventNames.contains(name)`)
      decodes that set's literals; a set the census cannot read is a site.
  Q17 one item per lock definition (rank and lock name), not per mention.
  Q18 `ipc5_ops` in ipc-targets.json names the IPC-5 ops; sites without `op=` stay, and an empty
      list keeps every sqlite site (`--check` refuses it once Q9 has data).

Schema queues (Q5, Q6, Q12, Q15) compare source against cmux-tui/spec/sdk-schema.json. Runtime
queues are read, not computed: Q9 and Q18 from a `CMUX_TUI_REQUEST_PATH_IO=record` run (lines with
`REQUEST_PATH_IO`, `kind=` and `site=FILE:LINE`, optional `op=`; passed with `--io-record FILE`
or stored by `--record --io-record FILE`), Q16 from `runtime.Q16`, which bench-daemon-latency.py
`--write-q16` writes (p05-ipc-002).

Usage:
  ipc-census.py                       counts of every queue
  ipc-census.py --queue Q1 [--queue Q4]  the sites as JSON
  ipc-census.py --explain Q3          the raw lines a refined queue drops and the sites it adds
  ipc-census.py --callers DIR         call-site files of the Swift request types declared in DIR
  ipc-census.py --record              write the counts to ipc-targets.json
  ipc-census.py --check               fail on a queue above its recorded count, a bad allowlist
                                      entry or a bad ipc5_ops list

Stdlib only; reads tracked files of the working tree (`git ls-files`), like `git grep`.
"""
from __future__ import annotations

import argparse
import fnmatch
import functools
from dataclasses import dataclass
import json
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
TARGETS = "plans/cmux-next/ipc-targets.json"
APP = "Packages/macOS/CmuxNext/Sources"
CORE = "cmux-tui/crates/cmux-tui-core/src"
CLI = "cmux-tui/crates/cmux-tui/src"
RUST_CRATES = "cmux-tui/crates/*.rs"
SCHEMA = "cmux-tui/spec/sdk-schema.json"
EVENT_DECODER = f"{APP}/CmuxNextDaemon/Events/DaemonEvent+Decoding.swift"
SERVER = f"{CORE}/server.rs"
# Families whose Command variants cmux-ipc build.rs generates; Q15 counts only
# the hand-written ones.
SERVER_FAMILIES = "cmux-tui/crates/cmux-ipc/server-families.json"
RESOURCE_WIRE_NAMES = f"{CORE}/resource/wire_name.rs"
RUST_NOT_TESTS = (":!*tests*", ":!*_tests.rs")
QUEUE_IDS = tuple(f"Q{n}" for n in range(1, 19))


@dataclass(frozen=True, order=True)
class Hit:
    file: str
    line: int
    key: str
    group: str | None = None

    def as_json(self) -> dict:
        item = {"file": self.file, "line": self.line, "key": self.key}
        if self.group is not None:
            item["group"] = self.group
        return item


@dataclass
class Result:
    queue: str
    title: str
    hits: list[Hit]
    raw: str | None = None
    raw_count: int | None = None
    source: str = "tree"
    found: int = 0  # sites before the allowlist
    raw_lines: list[tuple[str, int, str]] | None = None  # what the raw query prints
    raw_pattern: str | None = None

    @property
    def count(self) -> int:
        return len(self.hits)

    def groups(self) -> dict[str, int]:
        counts: dict[str, int] = {}
        for hit in self.hits:
            if hit.group is not None:
                counts[hit.group] = counts.get(hit.group, 0) + 1
        return dict(sorted(counts.items()))


@dataclass(frozen=True)
class RustDefinition:
    file: str
    impl_type: str | None
    has_self: bool
    arity: int  # parameters besides self
    wraps: str | None  # the primitive its body calls


class CensusError(Exception):
    pass


# ---------------------------------------------------------------------------------------------
# Source access and lexing


TOKENS = {
    "rust": re.compile(r'//|/\*|(?<![\w])b?r(#*)"|"|\''),
    "swift": re.compile(r'//|/\*|(#+)(?:"""|")|"""|"'),
}
RUST_CHAR = re.compile(r"'(\\(x[0-9a-fA-F]{2}|u\{[0-9a-fA-F]{1,6}\}|.)|[^\\'\n])'")
RUST_STRING_END = re.compile(r'(?:[^"\\]|\\.)*"', re.DOTALL)
NOT_NEWLINE = re.compile(r"[^\n]")


def blank_code(text: str, lang: str) -> str:
    """`text` with comments and literal contents replaced by spaces (newlines and string
    delimiters kept), so offsets and line numbers stay and code patterns never match prose."""
    pieces: list[str] = []
    n = len(text)
    i = kept = 0

    def blank(start: int, end: int) -> None:
        nonlocal kept
        end = min(end, n)
        pieces.append(text[kept:start])
        pieces.append(NOT_NEWLINE.sub(" ", text[start:end]))
        kept = end

    tokens = TOKENS[lang]
    while (found := tokens.search(text, i)) is not None:
        token, i = found.group(0), found.start()
        if token == "//":
            end = text.find("\n", i)
            end = n if end < 0 else end
            blank(i, end)
            i = end
        elif token == "/*":
            depth, k = 1, i + 2
            while k < n and depth:
                if text.startswith("/*", k):
                    depth, k = depth + 1, k + 2
                elif text.startswith("*/", k):
                    depth, k = depth - 1, k + 2
                else:
                    k += 1
            blank(i, k)
            i = k
        elif found.group(1) is not None:  # Rust r#"..."#, Swift #"..."#
            close = ('"' + found.group(1)) if lang == "rust" else (token.lstrip("#") + found.group(1))
            end = text.find(close, found.end())
            end = n if end < 0 else end
            blank(found.end(), end)
            i = end + len(close)
        elif token == '"""':
            k = i + 3
            while k < n and not text.startswith('"""', k):
                k += 2 if text[k] == "\\" else 1
            blank(i + 3, k)
            i = k + 3
        elif token == '"' and lang == "rust":
            end = RUST_STRING_END.match(text, i + 1)
            k = end.end() - 1 if end else n
            blank(i + 1, k)
            i = k + 1
        elif token == '"':
            k, depth = i + 1, 0  # Swift interpolation `\( ... )` may hold quotes
            while k < n:
                ch = text[k]
                if ch == "\\":
                    if k + 1 < n and text[k + 1] == "(":
                        depth += 1
                    k += 2
                    continue
                if depth:
                    depth += 1 if ch == "(" else -1 if ch == ")" else 0
                elif ch in '"\n':
                    break
                k += 1
            blank(i + 1, k)
            i = k + 1
        else:  # Rust `'`: a char literal or a lifetime
            char = RUST_CHAR.match(text, i)
            if char:
                blank(i + 1, char.end() - 1)
                i = char.end()
            else:
                i += 1
    pieces.append(text[kept:])
    return "".join(pieces)


CLOSING = {"{": "}", "(": ")", "[": "]"}


def match_brace(blanked: str, open_index: int) -> int:
    """Index of the bracket closing the `{`, `(` or `[` at `open_index` (end of text when
    unbalanced). Only that bracket kind is counted: comments and literals are blanked already."""
    opening = blanked[open_index]
    closing = CLOSING.get(opening, "}")
    depth = 0
    for k in range(open_index, len(blanked)):
        ch = blanked[k]
        if ch == opening:
            depth += 1
        elif ch == closing:
            depth -= 1
            if depth == 0:
                return k
    return len(blanked) - 1


def split_top_level(blanked: str, start: int, end: int, angles: bool = False) -> list[tuple[int, int]]:
    """(start, end) spans of the comma-separated items of `blanked[start:end]`, ignoring commas
    inside brackets (and inside `<...>` when `angles`, for type lists); empty items are dropped."""
    items, depth, k0 = [], 0, start
    for k in range(start, end):
        ch = blanked[k]
        if ch in "([{" or (angles and ch == "<"):
            depth += 1
        elif ch in ")]}" or (angles and ch == ">" and blanked[k - 1] != "-"):
            depth -= 1
        elif ch == "," and depth == 0:
            items.append((k0, k))
            k0 = k + 1
    items.append((k0, end))
    return [(a, b) for a, b in items if blanked[a:b].strip()]


def line_of(text: str, offset: int) -> int:
    return text.count("\n", 0, offset) + 1


def line_offset(text: str, number: int) -> int:
    """Offset of the first character of line `number` (1-based)."""
    offset = 0
    for _ in range(number - 1):
        offset = text.index("\n", offset) + 1
    return offset


class Repo:
    def __init__(self, root: Path):
        self.root = Path(root)
        self._files: dict[tuple[str, ...], list[str]] = {}
        self._text: dict[str, str] = {}
        self._blank: dict[str, str] = {}
        self._rust_test_files: set[str] | None = None
        self._rust_test_spans: dict[str, list[tuple[int, int]]] = {}

    def git(self, *args: str) -> str:
        done = subprocess.run(["git", "-C", str(self.root), *args], capture_output=True, text=True)
        if done.returncode != 0:
            raise CensusError(f"git {' '.join(args)}: {done.stderr.strip()}")
        return done.stdout

    def files(self, pathspecs: tuple[str, ...]) -> list[str]:
        """Tracked files of `pathspecs`, as `git grep -- PATHSPECS` reads them. Exclusions
        (`:!glob`) are applied here, with git's default pathspec matching (`*` crosses `/`): git
        2.43's `ls-files` drops every file when a pathspec list has an exclusion."""
        if pathspecs not in self._files:
            include = [spec for spec in pathspecs if not spec.startswith(":!")]
            exclude = [spec[2:] for spec in pathspecs if spec.startswith(":!")]
            listed = self.git("ls-files", "-z", "--", *include).split("\0")
            self._files[pathspecs] = sorted(
                path for path in listed
                if path and not any(fnmatch.fnmatchcase(path, glob) or path.startswith(glob.rstrip("/") + "/") for glob in exclude)
            )
        return self._files[pathspecs]

    def text(self, path: str) -> str:
        if path not in self._text:
            try:
                data = (self.root / path).read_bytes()
            except OSError:
                data = b""
            # git grep skips binary files (a NUL in the first 8000 bytes); so does the census.
            self._text[path] = "" if b"\0" in data[:8000] else data.decode("utf-8", "surrogateescape")
        return self._text[path]

    def lines(self, path: str) -> list[str]:
        return self.text(path).split("\n")

    def blanked(self, path: str) -> str:
        if path not in self._blank:
            lang = "rust" if path.endswith(".rs") else "swift"
            self._blank[path] = blank_code(self.text(path), lang)
        return self._blank[path]

    def head(self) -> str:
        return self.git("rev-parse", "HEAD").strip()

    # Rust tests ------------------------------------------------------------------------------

    TEST_ATTR = re.compile(r"#\[(?:cfg\((?:all\()?\s*test\b[^\]]*\)|test|tokio::test[^\]]*)\]")
    TEST_MODULE_DECLARATION = re.compile(
        r"#\[cfg\((?:all\()?\s*test\b[^\]]*\)\]\s*(?:#\[[^\]]*\]\s*)*(?:pub(?:\([^)]*\))?\s+)?mod\s+\w+\s*;"
    )

    def _test_items(self, path: str) -> tuple[list[tuple[int, int]], list[tuple[str, str | None]]]:
        """Spans of `#[cfg(test)]` / `#[test]` items in `path`, and the out-of-line test modules
        it declares (`#[cfg(test)] mod name;`, with an optional `#[path]`)."""
        blanked = self.blanked(path)
        text = self.text(path)
        spans: list[tuple[int, int]] = []
        modules: list[tuple[str, str | None]] = []
        for attr in self.TEST_ATTR.finditer(blanked):
            k = attr.end()
            path_attr = None
            while True:
                gap = re.match(r"\s*", blanked[k:])
                k += gap.end()
                if blanked.startswith("#[", k):
                    close = blanked.find("]", k)
                    found = re.match(r'#\[path\s*=\s*"([^"]*)"\]', text[k:close + 1])
                    if found:
                        path_attr = found.group(1)
                    k = close + 1
                    continue
                break
            end, stop = k, ""
            depth = 0
            while end < len(blanked):  # the attributed item, field or expression ends here
                ch = blanked[end]
                if ch in "([":
                    depth += 1
                elif ch in ")]":
                    depth -= 1
                elif depth <= 0 and ch in "{;,}":
                    stop = ch
                    break
                end += 1
            if stop == "{":
                end = match_brace(blanked, end)
            elif stop == ";":
                declared = re.match(r"(?:pub(?:\([^)]*\))?\s+)?mod\s+([a-z_][a-z0-9_]*)\s*;", blanked[k:end + 1])
                if declared:
                    modules.append((declared.group(1), path_attr))
            spans.append((line_of(blanked, attr.start()), line_of(blanked, end)))
        return spans, modules

    def rust_test_spans(self, path: str) -> list[tuple[int, int]]:
        if path not in self._rust_test_spans:
            self._rust_test_spans[path] = self._test_items(path)[0]
        return self._rust_test_spans[path]

    def rust_test_files(self) -> set[str]:
        """Files of out-of-line `#[cfg(test)]` modules (and everything under their directory)."""
        if self._rust_test_files is None:
            found: set[str] = set()
            all_rust = self.files((RUST_CRATES,))
            for path in all_rust:
                if not self.TEST_MODULE_DECLARATION.search(self.text(path)):
                    continue
                _, modules = self._test_items(path)
                pure = PurePosixPath(path)
                base = pure.parent if pure.name in ("mod.rs", "lib.rs", "main.rs") else pure.parent / pure.stem
                for name, path_attr in modules:
                    if path_attr:
                        found.add(str(pure.parent / path_attr))
                        continue
                    found.add(str(base / f"{name}.rs"))
                    prefix = f"{base / name}/"
                    found.update(other for other in all_rust if other.startswith(prefix))
            self._rust_test_files = found
        return self._rust_test_files

    def in_rust_test(self, path: str, line: int) -> bool:
        if path in self.rust_test_files():
            return True
        return any(start <= line <= end for start, end in self.rust_test_spans(path))


def raw_command(pattern: str, pathspecs: tuple[str, ...]) -> str:
    specs = " ".join(f"'{spec}'" for spec in pathspecs)
    return f"git grep -n -E '{pattern}' -- {specs} | wc -l"


def raw_scan(repo: Repo, pattern: str, pathspecs: tuple[str, ...]) -> list[tuple[str, int, str]]:
    """What `git grep -n -E PATTERN -- PATHSPECS` prints, one tuple per line."""
    regex = re.compile(pattern)
    anywhere = re.compile(pattern, re.MULTILINE)
    hits = []
    for path in repo.files(pathspecs):
        text = repo.text(path)
        if not text or not anywhere.search(text):
            continue
        for number, line in enumerate(text.split("\n"), 1):
            if regex.search(line):
                hits.append((path, number, line))
    return hits


SWIFT_TYPE_DECLARATION = re.compile(
    r"^\s*(?:@[\w.]+(?:\([^)]*\))?\s+)*((?:\w+\s+)*?)(?:class|struct|enum|actor|extension|protocol)\s+([A-Za-z_][\w.]*)"
)


@dataclass(frozen=True, order=True)
class SwiftType:
    qualified: str  # Outer.Inner
    name: str
    outer: str | None  # the enclosing type, for a nested type
    file: str | None  # its file, when private or fileprivate (visible only there)


def swift_type_chain(lines: list[str], index: int) -> list[tuple[str, bool]]:
    """The types around line `index` (0-based), outermost first: (name as written, private or
    fileprivate). Each less-indented line above is an enclosing scope; the type declarations
    among them are the chain (`extension A.B` gives `A.B`)."""
    indent = len(lines[index]) - len(lines[index].lstrip())
    chain = []
    for k in range(index - 1, -1, -1):
        line = lines[k]
        stripped = line.strip()
        if not stripped or stripped.startswith(("//", "*", "/*", "}", ")", "]", "#")):
            continue
        level = len(line) - len(line.lstrip())
        if level >= indent:
            continue
        indent = level
        found = SWIFT_TYPE_DECLARATION.match(line)
        if found and not re.search(r"\b(?:func|var|let|case|return)\b", found.group(1)):
            chain.append((found.group(2), bool(re.search(r"\b(?:private|fileprivate)\b", found.group(1)))))
        if level == 0:
            break
    return chain[::-1]


def swift_enclosing(lines: list[str], index: int) -> tuple[str, str]:
    """(type, member) around line `index` (0-based): the nearest less-indented declarations."""
    indent = len(lines[index]) - len(lines[index].lstrip())
    member = type_name = ""
    decl = re.compile(
        r"\b(?:(func)\s+([A-Za-z_]\w*)|(init|deinit)\b|(?<!if )(?<!guard )(?<!while )(?<!case )(?:var|let)\s+([A-Za-z_]\w*)\s*(?::[^=]*)?\{"
        r"|(?:class|struct|enum|actor|extension|protocol)\s+([A-Za-z_][\w.]*))"
    )
    for k in range(index, -1, -1):
        line = lines[k]
        stripped = line.strip()
        if not stripped or stripped.startswith(("//", "*", "/*")):
            continue
        level = len(line) - len(line.lstrip())
        if level >= indent and k != index:
            continue
        found = decl.search(line)
        if not found:
            continue
        if found.group(5):
            type_name = found.group(5)
            break
        if not member:
            member = found.group(2) or found.group(3) or found.group(4) or ""
        indent = level
    return type_name, member


@functools.lru_cache(maxsize=256)
def rust_functions(blanked: str) -> list[tuple[str, int, int, int]]:
    """(name, start offset, body open, body close) of every Rust fn with a body."""
    functions = []
    for found in re.finditer(r"\bfn\s+([a-z_][a-z0-9_]*)", blanked):
        k, depth = found.end(), 0
        while k < len(blanked):
            ch = blanked[k]
            if ch in "(<[":
                depth += 1
            elif ch in ")>]":
                depth -= 1 if not (ch == ">" and blanked[k - 1] == "-") else 0
            elif ch == ";" and depth <= 0:
                k = -1
                break
            elif ch == "{" and depth <= 0:
                break
            k += 1
        if 0 <= k < len(blanked):
            functions.append((found.group(1), found.start(), k, match_brace(blanked, k)))
    return functions


def enclosing_function(functions: list[tuple[str, int, int, int]], offset: int) -> tuple[str, int, int, int] | None:
    best = None
    for function in functions:
        if function[2] <= offset <= function[3] and (best is None or function[2] > best[2]):
            best = function
    return best


RUST_SELF_PARAM = re.compile(r"\s*(?:&\s*(?:'\w+\s+)?)?(?:mut\s+)?self\b")
RUST_IMPL = re.compile(r"\bimpl\b\s*(?:<[^{;]*?>\s*)?(?:[\w:]+(?:<[^{;]*?>)?\s+for\s+)?(?:[\w]+::)*([A-Z]\w*)[^{;]*\{")


def rust_signature(blanked: str, function: tuple[str, int, int, int]) -> tuple[bool, list[tuple[int, int]]]:
    """(has a self receiver, spans of the other parameters) of a `rust_functions` entry."""
    open_ = blanked.find("(", function[1], function[2])
    if open_ < 0:
        return False, []
    params = split_top_level(blanked, open_ + 1, match_brace(blanked, open_), angles=True)
    if params and RUST_SELF_PARAM.match(blanked[params[0][0]:params[0][1]]):
        return True, params[1:]
    return False, params


@functools.lru_cache(maxsize=256)
def rust_impl_blocks(blanked: str) -> tuple[tuple[str, int, int], ...]:
    return tuple((found.group(1), found.end() - 1, match_brace(blanked, found.end() - 1)) for found in RUST_IMPL.finditer(blanked))


def rust_impl_type(blanked: str, offset: int) -> str | None:
    """The type of the innermost `impl` block holding `offset`, if any."""
    best = None
    for name, open_, close in rust_impl_blocks(blanked):
        if open_ <= offset <= close and (best is None or open_ > best[1]):
            best = (name, open_)
    return best[0] if best else None


def call_arguments(blanked: str, open_paren: int) -> list[tuple[int, int]]:
    """Spans of the arguments of the call whose `(` is at `open_paren`."""
    return split_top_level(blanked, open_paren + 1, match_brace(blanked, open_paren))


# ---------------------------------------------------------------------------------------------
# Queues


class Census:
    def __init__(self, repo: Repo, targets: dict, io_record: list[str] | None = None):
        self.repo = repo
        self.targets = targets
        self.io_record = io_record
        self._results: dict[str, Result] = {}
        self._unfiltered: dict[str, list[Hit]] = {}
        self._drops: dict[str, dict[tuple[str, int], str]] = {}  # raw lines a refined queue drops, with why
        self._added: dict[tuple[str, Hit], str] = {}  # why a site off the raw lines counts

    # The allowlist: entries `{queue, file, key?, reason}`; a key-less entry covers the file.
    def allowlist(self) -> list[dict]:
        return list(self.targets.get("allowlist", []))

    def allowed(self, queue: str, hit: Hit) -> bool:
        for entry in self.allowlist():
            if entry.get("queue") == queue and entry.get("file") == hit.file and entry.get("key", hit.key) == hit.key:
                return True
        return False

    def result(self, queue: str) -> Result:
        if queue not in self._results:
            builder = getattr(self, f"q{queue[1:]}")
            result = builder()
            self._unfiltered[queue] = list(result.hits)
            result.found = len(result.hits)
            result.hits = sorted(hit for hit in result.hits if not self.allowed(queue, hit))
            self._results[queue] = result
        return self._results[queue]

    def unfiltered(self, queue: str) -> list[Hit]:
        self.result(queue)
        return self._unfiltered[queue]

    def exact(self, queue: str, title: str, pattern: str, pathspecs: tuple[str, ...], key, group=None) -> Result:
        """A queue that is its raw query: one site per matching line."""
        raw = raw_scan(self.repo, pattern, pathspecs)
        hits = [Hit(path, number, key(path, number, line), group(path) if group else None) for path, number, line in raw]
        return Result(queue, title, hits, raw_command(pattern, pathspecs), len(raw), raw_lines=raw, raw_pattern=pattern)

    def refined(self, queue: str, title: str, hits: list[Hit], pattern: str, pathspecs: tuple[str, ...]) -> Result:
        """A queue that refines its raw query; `breakdown` explains the difference line by line."""
        raw = raw_scan(self.repo, pattern, pathspecs)
        return Result(queue, title, hits, raw_command(pattern, pathspecs), len(raw), raw_lines=raw, raw_pattern=pattern)

    def drop(self, queue: str, path: str, line: int, reason: str) -> None:
        """Note why a candidate on `line` is no site (the first reason for a line wins)."""
        self._drops.setdefault(queue, {}).setdefault((path, line), reason)

    def added(self, queue: str, hit: Hit, reason: str) -> Hit:
        """Note why `hit` counts when the raw query does not print its line."""
        self._added[(queue, hit)] = reason
        return hit

    def breakdown(self, queue: str) -> dict | None:
        """How the raw query's `wc -l` becomes the queue's `found`, for a queue with a raw query:
        raw_count - sum(dropped) + sum(added) + same_line == found. `dropped` are raw lines with no
        site (each with its reason), `added` are sites on lines the raw query does not print, and
        `same_line` counts the second and later sites of one raw line."""
        result = self.result(queue)
        if result.raw_lines is None:
            return None
        hits = self.unfiltered(queue)
        on_line: dict[tuple[str, int], int] = {}
        for hit in hits:
            on_line[(hit.file, hit.line)] = on_line.get((hit.file, hit.line), 0) + 1
        raw_lines = {(path, number): line for path, number, line in result.raw_lines}
        pattern = re.compile(result.raw_pattern)
        dropped_lines = []
        for (path, number), line in sorted(raw_lines.items()):
            if (path, number) in on_line:
                continue
            reason = self._drops.get(queue, {}).get((path, number))
            if reason is None:
                offset = line_offset(self.repo.text(path), number) + pattern.search(line).start()
                in_prose = self.repo.blanked(path)[offset] != self.repo.text(path)[offset]
                reason = "comment or string" if in_prose else "unexplained"
            dropped_lines.append({"file": path, "line": number, "reason": reason, "text": line.strip()})
        added_sites = [
            {**hit.as_json(), "reason": self._added.get((queue, hit), "a site the raw pattern does not print")}
            for hit in sorted(hits) if (hit.file, hit.line) not in raw_lines
        ]

        def tally(items: list[dict]) -> dict[str, int]:
            counts: dict[str, int] = {}
            for item in items:
                counts[item["reason"]] = counts.get(item["reason"], 0) + 1
            return dict(sorted(counts.items()))

        return {
            "raw_count": result.raw_count,
            "dropped": tally(dropped_lines),
            "added": tally(added_sites),
            "same_line": sum(count - 1 for line, count in on_line.items() if line in raw_lines),
            "found": len(hits),
            "dropped_lines": dropped_lines,
            "added_sites": added_sites,
        }

    # Q1 ------------------------------------------------------------------------------------
    # A DaemonRequest names its command `static let commandName: DaemonCommandName = "..."`; older
    # types still say `static let command = "..."`. Both are a hand-written command.
    Q1_PATTERN = r'static (let|var) command(Name)?(: (String|DaemonCommandName))? = "'
    Q1_PATHS = (APP, ":!*.generated.swift")

    def q1(self) -> Result:
        def key(path, number, line):
            found = re.search(r'command(?:Name)?(?:: (?:String|DaemonCommandName))? = "([^"]*)"', line)
            return found.group(1) if found else line.strip()

        def group(path):
            return str(PurePosixPath(path).parent.relative_to(APP))

        return self.exact("Q1", "hand-written Swift commands", self.Q1_PATTERN, self.Q1_PATHS, key, group)

    # Q2 ------------------------------------------------------------------------------------
    def q2(self) -> Result:
        def key(path, number, line):
            found = re.search(r"fn (try_handle\w*)", line)
            return found.group(1) if found else line.strip()

        return self.exact("Q2", "daemon sniffers", "fn try_handle", (f"{CORE}/server",), key)

    # Q3 ------------------------------------------------------------------------------------
    Q3_PRIMITIVES = (
        "commit_registry_intent", "commit_registry_intent_with", "flush_terminal_journal",
        "send_durable", "send_durable_until", "send_producer",
    )
    Q3_RAW = (
        r"\.commit_terminal\(|commit_workspace_registry\(|commit_effect_intent\(|\.send_durable(_until)?\("
        r"|\.send_producer\(|commit_registry_intent(_with)?\(|flush_terminal_journal\("
    )

    def q3_wrappers(self, files: list[str]) -> dict[str, list[RustDefinition]]:
        """Wrapper name -> every non-test definition of that name. A wrapper is a non-test function
        whose body calls a primitive; a name can also have definitions that wrap nothing (another
        type's method), so each call resolves to its definitions in `q3_resolve`."""
        primitive = re.compile(r"(?<![\w])(" + "|".join(self.Q3_PRIMITIVES) + r")\s*\(")
        wrapping: set[str] = set()
        for path in files:
            if not primitive.search(self.repo.text(path)):
                continue
            blanked = self.repo.blanked(path)
            for name, start, open_, close in rust_functions(blanked):
                if name in self.Q3_PRIMITIVES or self.repo.in_rust_test(path, line_of(blanked, start)):
                    continue
                if primitive.search(blanked, open_, close):
                    wrapping.add(name)
        if not wrapping:
            return {}
        definition = re.compile(r"\bfn\s+(" + "|".join(map(re.escape, sorted(wrapping))) + r")\b")
        definitions: dict[str, list[RustDefinition]] = {}
        for path in files:
            if not definition.search(self.repo.text(path)):
                continue
            blanked = self.repo.blanked(path)
            for function in rust_functions(blanked):
                name, start, open_, close = function
                if name not in wrapping or self.repo.in_rust_test(path, line_of(blanked, start)):
                    continue
                has_self, params = rust_signature(blanked, function)
                called = primitive.search(blanked, open_, close)
                definitions.setdefault(name, []).append(RustDefinition(
                    path, rust_impl_type(blanked, start), has_self, len(params), called.group(1) if called else None,
                ))
        return definitions

    @staticmethod
    def q3_resolve(definitions: list[RustDefinition], blanked: str, path: str, start: int, open_paren: int) -> list[RustDefinition]:
        """The definitions a call can reach, by its form (`x.name(` a method, `Type::name(` /
        `Self::name(` an impl's function, `module::name(` or `name(` a free function) and its
        argument count. A call no definition fits keeps them all: it is never dropped."""
        before = blanked[max(0, start - 200):start]
        if re.search(r"\.\s*$", before):
            candidates = [d for d in definitions if d.has_self]
            if re.search(r"(?<![\w.])self\s*\.\s*$", before):
                own = rust_impl_type(blanked, start)
                candidates = [d for d in candidates if d.impl_type == own] or candidates
        elif owner := re.search(r"(\w+)\s*::\s*$", before):
            name = rust_impl_type(blanked, start) if owner.group(1) == "Self" else owner.group(1)
            if name and name[0].isupper():
                candidates = [d for d in definitions if d.impl_type == name]
            else:
                candidates = [d for d in definitions if d.impl_type is None and PurePosixPath(d.file).stem == name]
        else:
            candidates = [d for d in definitions if d.impl_type is None and not d.has_self]
        arity = len(call_arguments(blanked, open_paren))
        return [d for d in candidates if d.arity == arity] or candidates or definitions

    def q3(self) -> Result:
        pathspecs = (CORE, *RUST_NOT_TESTS)
        files = [path for path in self.repo.files(pathspecs) if path.endswith(".rs")]
        wrappers = self.q3_wrappers(files)
        names = sorted(set(self.Q3_PRIMITIVES) | set(wrappers), key=len, reverse=True)
        call = re.compile(r"(?<![\w])(" + "|".join(names) + r")\s*\(")
        hits = []
        for path in files:
            if not call.search(self.repo.text(path)):
                continue
            blanked = self.repo.blanked(path)
            functions = rust_functions(blanked)
            for found in call.finditer(blanked):
                name = found.group(1)
                number = line_of(blanked, found.start())
                if re.search(r"\bfn\s+$", blanked[max(0, found.start() - 8):found.start()]):
                    self.drop("Q3", path, number, "definition")
                    continue
                if self.repo.in_rust_test(path, number):
                    self.drop("Q3", path, number, "test")
                    continue
                inside = enclosing_function(functions, found.start())
                caller = inside[0] if inside else "<module>"
                if caller in self.Q3_PRIMITIVES:
                    self.drop("Q3", path, number, "inside a primitive's own definition")
                    continue
                if name in self.Q3_PRIMITIVES:
                    hits.append(self.added("Q3", Hit(path, number, f"{caller} -> {name}"), "a primitive call the raw pattern misses"))
                    continue
                reached = self.q3_resolve(wrappers[name], blanked, path, found.start(), found.end() - 1)
                wraps = sorted({d.wraps for d in reached if d.wraps})
                if not wraps:
                    self.drop("Q3", path, number, "a same-named function that wraps no primitive")
                    continue
                ambiguous = "ambiguous wrapper: " if any(d.wraps is None for d in reached) else ""
                hit = Hit(path, number, f"{caller} -> {name} ({ambiguous}wraps {', '.join(wraps)})")
                hits.append(self.added("Q3", hit, "a caller of a wrapper"))
        return self.refined("Q3", "F10 receipt waits", hits, self.Q3_RAW, pathspecs)

    # Q4 ------------------------------------------------------------------------------------
    Q4_RAW = (
        r"LineTransport\(path:|DaemonConnection\(([a-z][A-Za-z]*:|$)|NWConnection\(to: \.unix"
        r"|connect\([a-z][A-Za-z]*, \$0,|[bB]ridge\??\.open\(\)"
    )
    Q4_PATHS = (f"{APP}/*.swift",)
    Q4_SITES = (
        ("LineTransport(path:", re.compile(r"(?<![\w.])LineTransport\(path:")),
        ("DaemonConnection(", re.compile(r"(?<![\w.])DaemonConnection\(([ \t]*\n)?[ \t]*[a-z]\w*[ \t]*:")),
        ("NWConnection(to: .unix", re.compile(r"(?<![\w.])NWConnection\(to:\s*\.unix\b")),
        ("connect(", re.compile(r"(?<![\w])(?:Darwin\.|Glibc\.)?connect\(\s*\w+\s*,\s*\$0\s*,")),
        ("DaemonBridge.open", re.compile(r"\b\w*[bB]ridge\??\.open\(\s*\)")),
    )

    def q4(self) -> Result:
        hits = []
        for path in self.repo.files(self.Q4_PATHS):
            text = self.repo.text(path)
            if not any(token in text for token in ("LineTransport(", "DaemonConnection(", "NWConnection(", "connect(", ".open(")):
                continue
            blanked = self.repo.blanked(path)
            lines = text.split("\n")
            for token, regex in self.Q4_SITES:
                for found in regex.finditer(blanked):
                    start = found.start() + (found.group(0).find("connect(") if token == "connect(" else 0)
                    number = line_of(blanked, start)
                    type_name, member = swift_enclosing(lines, number - 1)
                    where = ".".join(part for part in (type_name, member) if part) or "<file>"
                    hit = Hit(path, number, f"{where}: {token}")
                    why = "argument label on the next line" if token == "DaemonConnection(" else "spacing or a module prefix the raw pattern misses"
                    hits.append(self.added("Q4", hit, why))
        return self.refined("Q4", "side connections", hits, self.Q4_RAW, self.Q4_PATHS)

    # Schema helpers ------------------------------------------------------------------------
    def schema(self) -> dict:
        if not hasattr(self, "_schema"):
            text = self.repo.text(SCHEMA)
            self._schema = json.loads(text) if text else {}
        return self._schema

    def schema_line(self, section: str, name: str) -> int:
        """Line of `name` among the first-level keys of the schema's top-level `section`."""
        if not hasattr(self, "_schema_lines"):
            self._schema_lines: dict[str, dict[str, int]] = {}
            lines = self.repo.lines(SCHEMA)
            current: dict[str, int] | None = None
            width = -1
            for number, line in enumerate(lines, 1):
                header = re.match(r'^ ?"(\w+)"\s*:\s*\{\s*$', line)
                if header and len(line) - len(line.lstrip()) <= 1:
                    current = self._schema_lines.setdefault(header.group(1), {})
                    width = -1
                    continue
                entry = re.match(r'^(\s*)"([^"]+)"\s*:', line)
                if current is None or not entry:
                    continue
                if width < 0:
                    width = len(entry.group(1))
                if len(entry.group(1)) == width:
                    current.setdefault(entry.group(2), number)
        return self._schema_lines.get(section, {}).get(name, 1)

    def families(self) -> dict[int, str]:
        """Family id -> name from the schema's `families` table (p05-ipc-010), when present."""
        table = self.schema().get("families") or {}
        if isinstance(table, dict):
            pairs = [(value.get("id"), name) for name, value in table.items() if isinstance(value, dict)]
        else:
            pairs = [(value.get("id"), value.get("name")) for value in table if isinstance(value, dict)]
        return {family: name for family, name in pairs if isinstance(family, int)}

    # Q5 ------------------------------------------------------------------------------------
    def q5(self) -> Result:
        commands = set(self.schema().get("commands", {}))
        seen: set[str] = set()
        hits = []
        for hit in sorted(self.unfiltered("Q1")):
            if not re.fullmatch(r"[a-z0-9][a-z0-9._-]*", hit.key) or hit.key in commands or hit.key in seen:
                continue  # one site per wire name; UI text such as "cmux task serve" is no wire name
            seen.add(hit.key)
            hits.append(Hit(hit.file, hit.line, hit.key, hit.group))
        return Result("Q5", "schema gaps (Swift wire names not in sdk-schema)", hits)

    # Q6 ------------------------------------------------------------------------------------
    def q6(self) -> Result:
        hits = []
        for name, command in self.schema().get("commands", {}).items():
            missing = [field for field in ("method_id", "priority") if field not in command]
            if missing:
                hits.append(Hit(SCHEMA, self.schema_line("commands", name), f"command {name}: {', '.join(missing)}"))
        for name, event in self.schema().get("events", {}).items():
            if "event_id" not in event:
                hits.append(Hit(SCHEMA, self.schema_line("events", name), f"event {name}: event_id"))
        return Result("Q6", "schema attributes missing", hits)

    # Q7 ------------------------------------------------------------------------------------
    def q7(self) -> Result:
        pattern = r"write_base64_json_(string|parts)\(|general_purpose::STANDARD\.(encode|decode)"

        def key(path, number, line):
            return re.search(pattern, line).group(0).rstrip("(")

        return self.exact("Q7", "base64 bulk paths", pattern, (CORE,), key, group=lambda path: path)

    # Q8 ------------------------------------------------------------------------------------
    Q8_NAME = r'"(mux-[^"]*|surface-[^"]*|terminal-host-(?:client|client-input|parser)|cmux-link-(?:in|out))"'
    Q8_NAME_SET = re.compile(r"(?s:mux-.*|surface-.*|terminal-host-(?:client|client-input|parser)|cmux-link-(?:in|out))")
    Q8_RAW = (
        r'\.name\((format!\()?"(mux-|surface-|terminal-host-(client|client-input|parser)"|cmux-link-(in|out)")'
        r'|spawn_journal_writer\("'
    )
    Q8_PATHS = (RUST_CRATES, *RUST_NOT_TESTS)
    # The QoS call a thread body begins with: the spec's `qos::set_current`, cmux-threads'
    # `set_current`, `thread_qos::set`, or the registration `cmux_threads::spawn` makes before it
    # runs the closure (registry.rs `register_current` sets the declared QoS).
    Q8_QOS = re.compile(
        r"\s*(?:(?:cmux_tui_platform::)?qos::set_current|cmux_threads::set_current|(?:crate::)?thread_qos::set"
        r"|registry::register_current)\b"
    )
    Q8_LITERAL_SITE = re.compile(r"\.name\(\s*(?:format!\(\s*)?" + Q8_NAME + r"|spawn_journal_writer\(\s*" + Q8_NAME)
    Q8_VARIABLE = r"&?\s*([a-z_][a-z0-9_]*)\s*(?:\.\s*(?:into|to_string|to_owned|clone)\s*\(\s*\)\s*)?"
    Q8_VARIABLE_SITE = re.compile(r"\.name\(\s*" + Q8_VARIABLE + r"\)")
    Q8_LITERAL_VALUE = re.compile(r'\s*&?\s*(?:format!\(\s*|String::from\(\s*)?"((?:[^"\\]|\\.)*)"')
    Q8_DEPTH = 4  # callers followed for a name passed in as a parameter

    @staticmethod
    def q8_spawn(blanked: str, site: int, after: int) -> int | None:
        """Offset of the argument of the `.spawn(` that starts the thread of the builder whose
        `.name(...)` call begins at `site` and ends at `after`: only `.method(...)` calls (and `?`)
        may come between, so another builder's spawn is never read. A builder bound by
        `let b = ...;` counts through the `b.spawn(` that follows in the same function."""
        k = after
        step = re.compile(r"\s*\??\s*\.\s*(\w+)\s*\(")
        while found := step.match(blanked, k):
            if found.group(1) == "spawn":
                return found.end()
            k = match_brace(blanked, found.end() - 1) + 1
        statement = max(blanked.rfind(ch, 0, site) for ch in ";{}") + 1
        bound = re.match(r"\s*let\s+(?:mut\s+)?([a-z_]\w*)\s*(?::[^=]*)?=", blanked[statement:site])
        if bound and re.match(r"\s*;", blanked[k:]):
            function = enclosing_function(rust_functions(blanked), site)
            end = function[3] if function else len(blanked)
            later = re.compile(r"\b" + bound.group(1) + r"\s*\.\s*spawn\s*\(").search(blanked, k, end)
            if later:
                return later.end()
        return None

    def q8_body_sets_qos(self, blanked: str, k: int) -> bool:
        """Whether the thread body passed at offset `k` begins with the QoS call."""
        rest = blanked[k:k + 2000]
        closure = re.match(r"\s*(?:move\s*)?\|[^|]*\|\s*", rest)
        if closure:
            body = rest[closure.end():]
            return body.startswith("{") and bool(self.Q8_QOS.match(body[1:]))
        block = re.match(r"\s*\{", rest)
        if block:
            inner = re.search(r"(?:move\s*)?\|[^|]*\|\s*\{", rest)
            return bool(inner) and bool(self.Q8_QOS.match(rest[inner.end():]))
        ident = re.match(r"\s*([a-z_][a-z0-9_]*)\s*\)", rest)
        if ident:
            name = re.escape(ident.group(1))
            local = re.compile(r"\blet\s+" + name + r"\s*=\s*(?:move\s*)?\|[^|]*\|\s*\{|\bfn\s+" + name + r"\s*\([^)]*\)[^{]*\{")
            for definition in local.finditer(blanked):
                if self.Q8_QOS.match(blanked[definition.end():]):
                    return True
        return False

    def q8_values(self, path: str, start: int, end: int, depth: int) -> list[tuple[str | None, tuple[str, int] | None]]:
        """The names the expression `start:end` of `path` can hold, as (literal, (file, offset of
        its quote)); (None, None) stands for a value the census cannot follow."""
        literal = self.Q8_LITERAL_VALUE.match(self.repo.text(path), start, end)
        if literal:
            return [(literal.group(1), (path, literal.start(1) - 1))]
        variable = re.fullmatch(r"\s*" + self.Q8_VARIABLE + r"\s*", self.repo.blanked(path)[start:end])
        if variable:
            return self.q8_resolve(path, start, variable.group(1), depth)
        return [(None, None)]

    def q8_resolve(self, path: str, offset: int, variable: str, depth: int = 0) -> list[tuple[str | None, tuple[str, int] | None]]:
        """The names `variable` holds at `offset`: its `let` in the same function, the array a
        `for` loop takes it from, or, for a parameter, the argument every non-test caller passes."""
        blanked = self.repo.blanked(path)
        function = enclosing_function(rust_functions(blanked), offset)
        if function is None or depth > self.Q8_DEPTH:
            return [(None, None)]
        open_ = function[2]
        word = re.compile(r"\b" + re.escape(variable) + r"\b")
        binding = None
        for found in re.finditer(r"\blet\s+(?:mut\s+)?" + re.escape(variable) + r"\b\s*(?::[^=;]*)?=", blanked[open_:offset]):
            binding = ("let", found)
        for found in re.finditer(r"\bfor\s+(\([^)]*\)|[a-z_]\w*)\s+in\s+(?:&\s*)?\[", blanked[open_:offset]):
            if word.search(found.group(1)) and (binding is None or found.start() > binding[1].start()):
                binding = ("for", found)
        if binding and binding[0] == "let":
            start = open_ + binding[1].end()
            end = blanked.find(";", start, offset)
            return self.q8_values(path, start, end if end >= 0 else offset, depth)
        if binding:
            return self.q8_loop_values(path, open_ + binding[1].end() - 1, binding[1].group(1), word, depth)
        has_self, params = rust_signature(blanked, function)
        parameter = re.compile(r"\s*(?:mut\s+)?" + re.escape(variable) + r"\s*:")
        index = next((k for k, (a, b) in enumerate(params) if parameter.match(blanked[a:b])), -1)
        if index < 0:
            return [(None, None)]
        return self.q8_caller_values(path, function, has_self, index, len(params), depth)

    def q8_loop_values(self, path: str, array: int, pattern: str, word: re.Pattern, depth: int):
        """The names of a `for PATTERN in [...]` loop variable: one per array element (for a tuple
        pattern, the element's item at the variable's position)."""
        blanked = self.repo.blanked(path)
        index = None
        if pattern.startswith("("):
            parts = [pattern[a:b].strip() for a, b in split_top_level(pattern, 1, len(pattern) - 1)]
            index = next((k for k, part in enumerate(parts) if word.fullmatch(part)), -1)
        values = []
        for a, b in split_top_level(blanked, array + 1, match_brace(blanked, array)):
            if index is not None:
                tuple_open = blanked.find("(", a, b)
                items = split_top_level(blanked, tuple_open + 1, match_brace(blanked, tuple_open)) if tuple_open >= 0 else []
                if not 0 <= index < len(items):
                    values.append((None, None))
                    continue
                a, b = items[index]
            values.extend(self.q8_values(path, a, b, depth + 1))
        return values

    def q8_caller_values(self, path: str, function: tuple[str, int, int, int], has_self: bool, index: int, arity: int, depth: int):
        """The values every non-test caller of `function` passes as parameter `index`; a call with
        another argument count is another function of that name."""
        name = re.escape(function[0])
        owner = rust_impl_type(self.repo.blanked(path), function[1])
        if has_self:
            call = re.compile(r"\.\s*" + name + r"\s*\(")
        elif owner:
            call = re.compile(r"\b(?:" + owner + r"|Self)\s*::\s*" + name + r"\s*\(")
        else:
            call = re.compile(r"(?<![\w.])" + name + r"\s*\(")
        values = []
        for caller in self.repo.files(self.Q8_PATHS):
            if not caller.endswith(".rs") or function[0] not in self.repo.text(caller):
                continue
            blanked = self.repo.blanked(caller)
            for found in call.finditer(blanked):
                if re.search(r"\bfn\s+$", blanked[max(0, found.start() - 8):found.start()]):
                    continue
                if self.repo.in_rust_test(caller, line_of(blanked, found.start())):
                    continue
                arguments = call_arguments(blanked, found.end() - 1)
                if len(arguments) == arity:
                    values.extend(self.q8_values(caller, *arguments[index], depth + 1))
        return values or [(None, None)]

    def q8(self) -> Result:
        files = [path for path in self.repo.files(self.Q8_PATHS) if path.endswith(".rs")]
        counted: set[tuple[str, int]] = set()  # (file, offset of the quote) of literal-site names
        hits = []
        for path in files:
            text = self.repo.text(path)
            if ".name(" not in text and "spawn_journal_writer(" not in text:
                continue
            blanked = self.repo.blanked(path)
            for found in self.Q8_LITERAL_SITE.finditer(text):
                number = line_of(text, found.start())
                if blanked[found.start()] != text[found.start()]:
                    self.drop("Q8", path, number, "comment or string")
                    continue
                group = 1 if found.group(1) is not None else 2
                counted.add((path, found.start(group) - 1))
                if self.repo.in_rust_test(path, number):
                    self.drop("Q8", path, number, "test")
                    continue
                if group == 2:  # spawn_journal_writer("name", body)
                    comma = blanked.find(",", found.end())
                    body = comma + 1 if comma >= 0 else None
                else:
                    paren = blanked.index("(", found.start())
                    body = self.q8_spawn(blanked, found.start(), match_brace(blanked, paren) + 1)
                if body is not None and self.q8_body_sets_qos(blanked, body):
                    self.drop("Q8", path, number, "the body begins with the QoS call")
                    continue
                hits.append(Hit(path, number, found.group(group)))
        for path in files:
            if ".name(" not in self.repo.text(path):
                continue
            blanked = self.repo.blanked(path)
            for found in self.Q8_VARIABLE_SITE.finditer(blanked):
                number = line_of(blanked, found.start())
                if self.repo.in_rust_test(path, number):
                    continue
                body = self.q8_spawn(blanked, found.start(), found.end())
                builder = re.search(r"Builder::new\(\)\s*$", blanked[max(0, found.start() - 200):found.start()])
                if body is None and not builder:
                    continue  # not a thread builder (clap's `Command::name`, for one)
                if body is not None and self.q8_body_sets_qos(blanked, body):
                    continue
                keys = set()
                for name, where in self.q8_resolve(path, found.start(), found.group(1)):
                    if name is None:
                        keys.add("<unresolved>")
                    elif where not in counted and self.Q8_NAME_SET.fullmatch(name):
                        keys.add(name)
                for key in sorted(keys):
                    why = "a name the census cannot follow" if key == "<unresolved>" else "a name through a variable"
                    hits.append(self.added("Q8", Hit(path, number, key), why))
        return self.refined("Q8", "threads without QoS", hits, self.Q8_RAW, self.Q8_PATHS)

    # Q9 and Q18 (runtime) ---------------------------------------------------------------------
    def io_sites(self) -> tuple[list[Hit], str]:
        if self.io_record is not None:
            return parse_io_record(self.io_record), "--io-record"
        stored = self.targets.get("runtime", {}).get("Q9")
        if stored:
            return [Hit(item["file"], int(item.get("line", 0)), item["key"]) for item in stored], f"{TARGETS} runtime.Q9"
        return [], "not recorded (p05-ipc-003 record run)"

    def q9(self) -> Result:
        hits, source = self.io_sites()
        return Result("Q9", "request-path I/O", hits, source=source)

    def q18(self) -> Result:
        """The `kind=sqlite` sites of the Q9 run hit by an op of `ipc5_ops` (ipc-targets.json; the
        IPC-5 ops of p05-ipc.md section 5). A site without `op=` stays: the record cannot show it is
        off the IPC-5 path. An empty or missing `ipc5_ops` keeps every sqlite site, and `--check`
        refuses it once Q9 has data, so the list never filters by being empty."""
        hits, source = self.io_sites()
        ops = set(self.targets.get("ipc5_ops") or [])
        chosen = []
        for hit in hits:
            fields = dict(part.split("=", 1) for part in hit.key.split() if "=" in part)
            if fields.get("kind") != "sqlite":
                continue
            if ops and "op" in fields and fields["op"] not in ops:
                continue
            chosen.append(hit)
        if not ops:
            source += "; ipc5_ops is empty: every op"
        return Result("Q18", "request-path SQLite reads", chosen, source=source)

    def ipc5_op_problems(self) -> list[str]:
        """`ipc5_ops` must name the IPC-5 ops by wire name: a daemon Command variant, or a v2
        resource operation of resource/wire_name.rs (a name with a dot)."""
        ops = self.targets.get("ipc5_ops") or []
        if not ops:
            if self.result("Q9").count:
                return ["ipc5_ops is empty, so Q18 keeps every sqlite site; list the IPC-5 ops (p05-ipc.md section 5)"]
            return []
        variants = {wire for wire, _ in self.command_variants()} | self.generated_commands()
        resource = self.repo.text(RESOURCE_WIRE_NAMES)
        return [
            f"ipc5_ops {op}: not a daemon Command variant or a v2 operation of {RESOURCE_WIRE_NAMES}"
            for op in ops
            if (f'"{op}"' not in resource if "." in op else op not in variants)
        ]

    # Q10 -----------------------------------------------------------------------------------
    def q10(self) -> Result:
        pattern = r"JSONDecoder\(\)|JSONSerialization\.|WireCoding\.decoder\(\)|base64"
        dirs = tuple(f"{APP}/CmuxNextDaemon/{name}" for name in ("Connection", "Terminal", "Events", "Loopback"))

        def key(path, number, line):
            return re.search(pattern, line).group(0)

        return self.exact("Q10", "JSON and base64 in the app connection layer", pattern, dirs, key, group=lambda path: path)

    # Q11 -----------------------------------------------------------------------------------
    def q11(self) -> Result:
        pattern = r'resourceRequest\(|ResourceRequestEnvelope\(|operation: "|transport\.request\(cmd: "[a-z_]+\.'
        lines_cache: dict[str, list[str]] = {}

        def key(path, number, line):
            lines = lines_cache.setdefault(path, self.repo.lines(path))
            for k in range(number - 1, min(number + 2, len(lines))):
                found = re.search(r'(?:operation|cmd): "([^"]+)"', lines[k])
                if found:
                    return found.group(1)
            return re.search(pattern, line).group(0).rstrip("(")

        return self.exact("Q11", "hand-built v2 envelopes", pattern, (f"{APP}/*.swift",), key, group=lambda path: path)

    # Q12 -----------------------------------------------------------------------------------
    Q12_DELEGATE = re.compile(r"\bcase\s+_\s+where\s+([A-Z]\w*)\s*\.\s*([a-z]\w*)\s*\.\s*contains\(\s*name\s*\)")

    def swift_string_set(self, type_name: str, member: str) -> set[str] | None:
        """The literals of `static let MEMBER: Set<String> = [...]` declared in `type_name` (or
        an extension of it) in the app sources; None when no such declaration is found."""
        declaration = re.compile(r"\bstatic\s+(?:let|var)\s+" + re.escape(member) + r"\s*(?::\s*Set<String>\s*)?=\s*(?:Set\(\s*)?\[")
        for path in self.repo.files((f"{APP}/*.swift",)):
            text = self.repo.text(path)
            if member not in text or type_name not in text:
                continue
            blanked = self.repo.blanked(path)
            for found in declaration.finditer(blanked):
                owner, _ = swift_enclosing(text.split("\n"), line_of(blanked, found.start()) - 1)
                if owner.split(".")[-1] != type_name:
                    continue
                close = match_brace(blanked, found.end() - 1)
                return set(re.findall(r'"((?:[^"\\\n]|\\.)*)"', text[found.end():close]))
        return None

    def q12(self) -> Result:
        """Schema events the app's DaemonEvent decoder has no case for. A case can delegate to a
        name set (`case _ where CloudConversationsEvent.eventNames.contains(name):`); that set's
        literals count as decoded. A delegate the census cannot read is a site of its own."""
        text = self.repo.text(EVENT_DECODER)
        blanked = self.repo.blanked(EVENT_DECODER)
        decoded: set[str] = set()
        for found in re.finditer(r'\bcase\s+("[^"\n]+"(?:\s*,\s*"[^"\n]+")*)\s*:', text):
            if blanked[found.start()] == text[found.start()]:
                decoded.update(re.findall(r'"([^"]+)"', found.group(1)))
        hits = []
        for found in self.Q12_DELEGATE.finditer(blanked):
            names = self.swift_string_set(found.group(1), found.group(2))
            if names is None:
                hits.append(Hit(EVENT_DECODER, line_of(blanked, found.start()), f"<unread delegate {found.group(1)}.{found.group(2)}>"))
            else:
                decoded |= names
        hits += [
            Hit(SCHEMA, self.schema_line("events", name), name)
            for name in self.schema().get("events", {})
            if name not in decoded
        ]
        return Result("Q12", "events not decoded natively", hits)

    # Q13 -----------------------------------------------------------------------------------
    def q13(self) -> Result:
        pattern = r"unchecked_transaction\(|\.transaction\(\)"

        def key(path, number, line):
            return re.search(pattern, line).group(0).lstrip(".").rstrip("()")

        return self.exact("Q13", "request-side SQLite transactions", pattern, (CORE, *RUST_NOT_TESTS), key, group=lambda path: path)

    # Q14 -----------------------------------------------------------------------------------
    def q14(self) -> Result:
        def key(path, number, line):
            found = re.search(r'"cmd"\s*:\s*"([^"]+)"', line)
            return found.group(1) if found else '"cmd"'

        return self.exact("Q14", 'Rust CLI hand-built "cmd" requests', '"cmd"', (CLI,), key, group=lambda path: path)

    # Q15 -----------------------------------------------------------------------------------
    @staticmethod
    def kebab(name: str) -> str:
        """serde `rename_all = "kebab-case"`: a dash before every capital but the first."""
        return "".join(("-" if index and ch.isupper() else "") + ch.lower() for index, ch in enumerate(name))

    def command_variants(self) -> list[tuple[str, int]]:
        text = self.repo.text(SERVER)
        blanked = self.repo.blanked(SERVER)
        found = re.search(r"\benum\s+Command\s*\{", blanked)
        if not found:
            return []
        open_ = found.end() - 1
        close = match_brace(blanked, open_)
        variants = []
        depth, k, rename = 0, open_ + 1, None
        while k < close:
            ch = blanked[k]
            if ch in "{([":
                depth += 1
            elif ch in "})]":
                depth -= 1
            elif depth == 0 and blanked.startswith("#[", k):
                end = blanked.find("]", k)
                attribute = re.search(r'rename\s*=\s*"([^"]+)"', text[k:end + 1])
                rename = attribute.group(1) if attribute else rename
                k = end + 1
                continue
            elif depth == 0 and (ident := re.match(r"[A-Z][A-Za-z0-9]*", blanked[k:])) and not blanked[k - 1].isalnum():
                variants.append((rename or self.kebab(ident.group(0)), line_of(blanked, k)))
                rename = None
                k += ident.end()
                continue
            k += 1
        return variants

    def generated_commands(self) -> set[str]:
        """Commands of the families SERVER_FAMILIES lists: served by generated variants."""
        text = self.repo.text(SERVER_FAMILIES)
        listed = set(json.loads(text).get("families") or []) if text else set()
        ids = {family_id for family_id, name in self.families().items() if name in listed}
        return {
            wire
            for wire, command in self.schema().get("commands", {}).items()
            if isinstance(command.get("method_id"), int) and command["method_id"] >> 8 in ids
        }

    def q15(self) -> Result:
        commands = self.schema().get("commands", {})
        families = self.families()
        hits = []
        for wire, number in self.command_variants():
            command = commands.get(wire)
            if command is None:
                group = "not-in-schema"
            elif isinstance(command.get("method_id"), int):
                group = families.get(command["method_id"] >> 8, f"family-{command['method_id'] >> 8:#04x}")
            else:  # before p05-ipc-011 assigns families, the capability is the closest grouping
                group = f"capability:{command.get('capability') or 'base'}"
            hits.append(Hit(SERVER, number, wire, group))
        return Result("Q15", "daemon Command variants", hits)

    # Q16 -----------------------------------------------------------------------------------
    def q16(self) -> Result:
        stored = self.targets.get("runtime", {}).get("Q16")
        if stored is None:
            return Result("Q16", "slow ops (p95 > 2 ms)", [], source="not recorded (bench-daemon-latency.py --write-q16)")
        hits = [Hit(item.get("file", "cmux-tui/scripts/bench-daemon-latency.py"), int(item.get("line", 0)), item["key"]) for item in stored]
        return Result("Q16", "slow ops (p95 > 2 ms)", hits, source=f"{TARGETS} runtime.Q16")

    # Q17 -----------------------------------------------------------------------------------
    def q17(self) -> Result:
        pattern = r"LockRank::[A-Z]"
        rank = re.compile(r"LockRank::([A-Z]\w*)")
        name = re.compile(r'\s*,\s*("([^"]*)"|([A-Z][A-Z0-9_]+)\b)')
        seen: set[str] = set()
        hits = []
        for path in self.repo.files((CORE,)):
            if not path.endswith(".rs"):
                continue
            text = self.repo.text(path)
            if "LockRank::" not in text:
                continue
            blanked = self.repo.blanked(path)
            for found in rank.finditer(blanked):
                number = line_of(blanked, found.start())
                if path.endswith("/lock_rank.rs"):
                    self.drop("Q17", path, number, "lock_rank.rs defines the ranks, not locks")
                    continue
                if re.search(r"HeldRank::check\(\s*(?:crate::lock_rank::)?$", blanked[max(0, found.start() - 60):found.start()]):
                    self.drop("Q17", path, number, "a check of a held rank, not a definition")
                    continue
                if self.repo.in_rust_test(path, number):
                    self.drop("Q17", path, number, "test")
                    continue
                label = name.match(text, found.end())
                lock = (label.group(2) if label.group(2) is not None else label.group(3)) if label else "?"
                key = f"{found.group(1)} {lock}"
                if key in seen:
                    self.drop("Q17", path, number, "a lock counted at an earlier line")
                    continue
                seen.add(key)
                hits.append(Hit(path, number, key))
        return self.refined("Q17", "ranked lock definitions", hits, pattern, (CORE,))

    # --callers ------------------------------------------------------------------------------
    def request_types(self, directory: str) -> list[SwiftType]:
        """The types that declare the Q1 commands of `directory`, with their enclosing types."""
        directory = directory.rstrip("/")
        if not directory.startswith(APP):
            directory = f"{APP}/{directory}"
        types: dict[tuple[str, str | None], SwiftType] = {}
        for hit in self.unfiltered("Q1"):
            if not hit.file.startswith(directory + "/"):
                continue
            chain = swift_type_chain(self.repo.lines(hit.file), hit.line - 1)
            if not chain:
                continue
            path = [part for name, _ in chain for part in name.split(".")]
            private = any(hidden for _, hidden in chain)
            found = SwiftType(".".join(path), path[-1], path[-2] if len(path) > 1 else None, hit.file if private else None)
            types[(found.qualified, found.file)] = found
        return sorted(types.values())

    def callers(self, directory: str) -> list[Hit]:
        """The first reference in each app file to each request type of `directory`. A top-level
        type matches by its name; a nested type matches as `Outer.Inner`, or by its own name only
        inside `Outer` or its extensions; a private or fileprivate type only in its own file."""
        types = self.request_types(directory)
        sources = self.repo.files((f"{APP}/*.swift", ":!*.generated.swift"))
        modules = {PurePosixPath(path).relative_to(APP).parts[0] for path in sources}  # `CmuxNextDaemon.Name`
        declaration = re.compile(r"\b(?:struct|enum|class|actor|extension|typealias|protocol)\s+$")
        hits = []
        for path in sources:
            text = self.repo.text(path)
            for swift_type in types:
                if (swift_type.file and swift_type.file != path) or swift_type.name not in text:
                    continue
                blanked, lines = self.repo.blanked(path), self.repo.lines(path)
                first = None
                for found in re.finditer(r"(?<![\w])(?:(\w+)\s*\.\s*)?" + re.escape(swift_type.name) + r"\b", blanked):
                    qualifier = found.group(1)
                    line_start = blanked.rfind("\n", 0, found.start()) + 1
                    if declaration.search(blanked[line_start:found.start()]):
                        continue
                    prefix = re.search(r"(\w+)\s*\.\s*$", blanked[line_start:found.start()])
                    if prefix and prefix.group(1) not in modules:
                        continue  # a member of a value: `a.b.Name`
                    number = line_of(blanked, found.start())
                    if qualifier is not None and qualifier not in modules and qualifier != swift_type.outer:
                        continue  # `value.Name` is a member, `Other.Name` another type's nested type
                    if swift_type.outer is not None and qualifier != swift_type.outer:
                        around = [part for name, _ in swift_type_chain(lines, number - 1) for part in name.split(".")]
                        if swift_type.outer not in around:
                            continue  # the bare name means another type here
                    first = number
                    break
                if first is not None:
                    hits.append(Hit(path, first, swift_type.qualified))
        return sorted(hits)


def parse_io_record(lines: list[str]) -> list[Hit]:
    """Sites of a `CMUX_TUI_REQUEST_PATH_IO=record` run (`uniq -c` counts allowed)."""
    seen: set[tuple[str, str, int, str]] = set()
    hits = []
    for line in lines:
        if "REQUEST_PATH_IO" not in line:
            continue
        fields = dict(re.findall(r"\b(kind|site|op)=(\S+)", line))
        if "kind" not in fields or "site" not in fields:
            continue
        site = re.match(r"(.+?):(\d+)(?::\d+)?$", fields["site"])
        file, number = (site.group(1), int(site.group(2))) if site else (fields["site"], 0)
        key = f"kind={fields['kind']}" + (f" op={fields['op']}" if "op" in fields else "")
        if (key, file, number, "") in seen:
            continue
        seen.add((key, file, number, ""))
        hits.append(Hit(file, number, key))
    return sorted(hits)


# ---------------------------------------------------------------------------------------------
# Targets file: record and check


def load_targets(path: Path) -> dict:
    if not path.exists():
        return {}
    return json.loads(path.read_text(encoding="utf-8"))


def record(census: Census, path: Path) -> dict:
    targets = dict(census.targets)
    queues = {}
    for queue in QUEUE_IDS:
        result = census.result(queue)
        entry: dict = {"title": result.title, "count": result.count, "found": result.found}
        if result.raw is not None:
            entry["raw"] = result.raw
            entry["raw_count"] = result.raw_count
        if result.source != "tree":
            entry["source"] = result.source
        explained = census.breakdown(queue)
        if explained and (explained["dropped"] or explained["added"] or explained["same_line"]):
            entry["breakdown"] = {key: explained[key] for key in ("dropped", "added", "same_line")}
        groups = result.groups()
        if groups:
            entry["groups"] = groups
        queues[queue] = entry
    targets["base"] = {"sha": census.repo.head(), "queues": queues}
    if census.io_record is not None:
        targets.setdefault("runtime", {})["Q9"] = [hit.as_json() for hit in census.result("Q9").hits]
    path.write_text(json.dumps(targets, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return targets


def breakdown_line(explained: dict) -> str:
    """`raw 38 - test 9 + wrapper caller 4 = found 33`, from `Census.breakdown`."""
    parts = [f"raw {explained['raw_count']}"]
    parts += [f"- {reason} {count}" for reason, count in explained["dropped"].items()]
    parts += [f"+ {reason} {count}" for reason, count in explained["added"].items()]
    if explained["same_line"]:
        parts.append(f"+ more sites on one raw line {explained['same_line']}")
    return " ".join(parts) + f" = found {explained['found']}"


def check(census: Census) -> list[str]:
    problems = []
    for index, entry in enumerate(census.allowlist()):
        label = f"allowlist[{index}] {entry.get('queue')} {entry.get('file')} {entry.get('key', '')}".rstrip()
        if entry.get("queue") not in QUEUE_IDS:
            problems.append(f"{label}: unknown queue")
            continue
        if not isinstance(entry.get("reason"), str) or not entry["reason"].strip():
            problems.append(f"{label}: needs one reason")
        matches = [
            hit for hit in census.unfiltered(entry["queue"])
            if hit.file == entry.get("file") and entry.get("key", hit.key) == hit.key
        ]
        if not matches:
            problems.append(f"{label}: matches no site (stale; remove it)")
    problems += census.ipc5_op_problems()
    recorded = census.targets.get("base", {}).get("queues", {})
    for queue in QUEUE_IDS:
        if queue not in recorded:
            continue
        result = census.result(queue)
        if result.count > recorded[queue]["count"]:
            problems.append(
                f"{queue} ({result.title}): {result.count} sites, recorded {recorded[queue]['count']};"
                f" see ipc-census.py --queue {queue}"
            )
    return problems


# ---------------------------------------------------------------------------------------------


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--repo", type=Path, default=ROOT, help="repository root (default: this checkout)")
    parser.add_argument("--targets", type=Path, help=f"targets file (default: REPO/{TARGETS})")
    parser.add_argument("--queue", action="append", choices=QUEUE_IDS, help="print a queue's sites as JSON")
    parser.add_argument("--callers", metavar="DIR", help="call-site files of the Swift request types in DIR (under the app Sources)")
    parser.add_argument("--explain", metavar="QN", choices=QUEUE_IDS,
                        help="how a queue's found count follows from its raw query: each dropped raw line and each added site, with a reason")
    parser.add_argument("--io-record", type=Path, metavar="FILE", help="output of a CMUX_TUI_REQUEST_PATH_IO=record run (Q9, Q18)")
    parser.add_argument("--record", action="store_true", help=f"write the counts to {TARGETS}")
    parser.add_argument("--check", action="store_true", help="fail on a queue above its recorded count or a bad allowlist entry")
    args = parser.parse_args(argv)

    repo = Repo(args.repo.resolve())
    targets_path = args.targets or repo.root / TARGETS
    io_record = args.io_record.read_text(encoding="utf-8", errors="replace").split("\n") if args.io_record else None
    try:
        census = Census(repo, load_targets(targets_path), io_record)
        if args.callers:
            print(json.dumps([hit.as_json() for hit in census.callers(args.callers)], indent=1))
            return 0
        if args.explain:
            explained = census.breakdown(args.explain)
            if explained is None:
                print(f"ipc-census: {args.explain} has no raw query to explain", file=sys.stderr)
                return 2
            print(breakdown_line(explained), file=sys.stderr)
            print(json.dumps(explained, indent=1))
            return 0
        if args.queue:
            shown = {queue: [hit.as_json() for hit in census.result(queue).hits] for queue in args.queue}
            for queue in args.queue:
                result = census.result(queue)
                raw = f"; raw {result.raw_count}: {result.raw}" if result.raw is not None else ""
                print(f"{queue} {result.title}: {result.count} ({result.found} before the allowlist){raw}", file=sys.stderr)
                explained = census.breakdown(queue)
                if explained and explained["raw_count"] != explained["found"]:
                    print(f"  {breakdown_line(explained)}; each line: --explain {queue}", file=sys.stderr)
            print(json.dumps(shown[args.queue[0]] if len(args.queue) == 1 else shown, indent=1))
            return 0
        if args.record:
            record(census, targets_path)
            print(f"recorded {len(QUEUE_IDS)} queues at {repo.head()[:12]} in {targets_path}")
            return 0
        if args.check:
            problems = check(census)
            for problem in problems:
                print(f"ipc-census: {problem}", file=sys.stderr)
            outside = census.result("Q4").count
            print(f"ipc-census: IPC-1: {outside} Q4 sites outside the allowlist (done when 0; --queue Q4)")
            if not problems:
                print("ipc-census: every queue is at or below its recorded count; the allowlist is current")
            return 1 if problems else 0
        print(f"{'queue':<5} {'count':>5} {'found':>5} {'raw':>5}  title (count: after the allowlist; raw: the raw query's wc -l)")
        for queue in QUEUE_IDS:
            result = census.result(queue)
            raw = str(result.raw_count) if result.raw is not None else "-"
            source = f"  ({result.source})" if result.source != "tree" else ""
            print(f"{queue:<5} {result.count:>5} {result.found:>5} {raw:>5}  {result.title}{source}")
        return 0
    except CensusError as error:
        print(f"ipc-census: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
