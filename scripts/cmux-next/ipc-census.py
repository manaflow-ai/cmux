#!/usr/bin/env python3
"""IPC census for the p05-ipc program: the machine queues Q1-Q18 of
plans/cmux-next/chrome-parity/p05-ipc.md, section 6.

Each queue is a list of sites, printed as JSON `[{file, line, key}]` (plus `group` where the spec
groups a queue, for example Q1 by directory). Every queue that the spec defines by a `git grep` also
carries that raw query: the census reports `raw_count` (what `RAW | wc -l` prints) next to `found`
(its sites) and `count` (the sites outside the allowlist), so a reviewer can check the numbers with
one shell command. Q1, Q2, Q7, Q10, Q11, Q13 and Q14 are their raw query (found == raw_count). No count is written in this file: `--record` writes them to
plans/cmux-next/ipc-targets.json, and `--check` compares the tree against that file.

Refinements over the raw queries (each is stated on its queue):
  Q3  Rust tests are dropped (test paths, `#[cfg(test)]` items and modules, `#[test]` functions),
      calls inside the primitives' own definitions are dropped, and the wrappers are derived: any
      function whose body calls a primitive is a wrapper (one level; a name defined twice is
      not), and each call of it is a site (caller-of-wrapper), so a new wrapper is counted
      without a regex change.
  Q4  `DaemonConnection(` counts with its first argument label on the same or the next line; raw
      `connect(fd, $0, ...)` calls, `NWConnection(to: .unix` and `DaemonBridge.open` count too;
      comments and strings never count. Sockets that are not a cmux-tui daemon (acpmux, the
      browser host, the control socket, Tasks) and LineTransport's own connect are allowlisted
      in ipc-targets.json with their reason, so the census still sees each one.
  Q8  thread name sites in cmux-tui/crates (tests dropped) whose spawned body does not begin with
      `cmux_tui_platform::qos::set_current`, plus journal writers spawned by name.
  Q17 one item per lock definition (rank and lock name), not per mention.

Schema queues (Q5, Q6, Q12, Q15) compare source against cmux-tui/spec/sdk-schema.json. Runtime
queues are read, not computed: Q9 and Q18 from a `CMUX_TUI_REQUEST_PATH_IO=record` run (lines with
`REQUEST_PATH_IO`, `kind=` and `site=FILE:LINE`, optional `op=`; passed with `--io-record FILE`
or stored by `--record --io-record FILE`), Q16 from `runtime.Q16`, which bench-daemon-latency.py
`--write-q16` writes (p05-ipc-002).

Usage:
  ipc-census.py                       counts of every queue
  ipc-census.py --queue Q1 [--queue Q4]  the sites as JSON
  ipc-census.py --callers DIR         call-site files of the Swift request types declared in DIR
  ipc-census.py --record              write the counts to ipc-targets.json
  ipc-census.py --check               fail on a queue above its recorded count or a bad allowlist entry

Stdlib only; reads tracked files of the working tree (`git ls-files`), like `git grep`.
"""
from __future__ import annotations

import argparse
import fnmatch
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

    @property
    def count(self) -> int:
        return len(self.hits)

    def groups(self) -> dict[str, int]:
        counts: dict[str, int] = {}
        for hit in self.hits:
            if hit.group is not None:
                counts[hit.group] = counts.get(hit.group, 0) + 1
        return dict(sorted(counts.items()))


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


def match_brace(blanked: str, open_index: int) -> int:
    """Index of the `}` closing the `{` at `open_index` (end of text when unbalanced)."""
    depth = 0
    for k in range(open_index, len(blanked)):
        ch = blanked[k]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return k
    return len(blanked) - 1


def line_of(text: str, offset: int) -> int:
    return text.count("\n", 0, offset) + 1


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

    def exists(self, path: str) -> bool:
        return (self.root / path).is_file()

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


# ---------------------------------------------------------------------------------------------
# Queues


class Census:
    def __init__(self, repo: Repo, targets: dict, io_record: list[str] | None = None):
        self.repo = repo
        self.targets = targets
        self.io_record = io_record
        self._results: dict[str, Result] = {}
        self._unfiltered: dict[str, list[Hit]] = {}

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
        hits = []
        for path, number, line in raw_scan(self.repo, pattern, pathspecs):
            hits.append(Hit(path, number, key(path, number, line), group(path) if group else None))
        return Result(queue, title, hits, raw_command(pattern, pathspecs), len(hits))

    # Q1 ------------------------------------------------------------------------------------
    Q1_PATTERN = r'static (let|var) command(: String)? = "'
    Q1_PATHS = (APP, ":!*.generated.swift")

    def q1(self) -> Result:
        def key(path, number, line):
            found = re.search(r'command(?:: String)? = "([^"]*)"', line)
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

    def q3_wrappers(self, files: list[str]) -> dict[str, str]:
        """Wrapper name -> the primitive it calls: non-test functions whose body calls a
        primitive. A name defined more than once in the crate is not a wrapper: its calls could be
        any of the definitions."""
        primitive = re.compile(r"(?<![\w])(" + "|".join(self.Q3_PRIMITIVES) + r")\s*\(")
        wrappers: dict[str, str] = {}
        for path in files:
            if not primitive.search(self.repo.text(path)):
                continue
            blanked = self.repo.blanked(path)
            for name, start, open_, close in rust_functions(blanked):
                if name in self.Q3_PRIMITIVES or self.repo.in_rust_test(path, line_of(blanked, start)):
                    continue
                called = primitive.search(blanked, open_, close)
                if called:
                    wrappers.setdefault(name, called.group(1))
        if not wrappers:
            return {}
        definition = re.compile(r"\bfn\s+(" + "|".join(map(re.escape, wrappers)) + r")\b")
        definitions: dict[str, int] = {}
        for path in files:
            if not definition.search(self.repo.text(path)):
                continue
            blanked = self.repo.blanked(path)
            for found in definition.finditer(blanked):
                if not self.repo.in_rust_test(path, line_of(blanked, found.start())):
                    definitions[found.group(1)] = definitions.get(found.group(1), 0) + 1
        return {name: callee for name, callee in wrappers.items() if definitions.get(name) == 1}

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
                if re.search(r"\bfn\s+$", blanked[max(0, found.start() - 8):found.start()]):
                    continue  # the definition itself
                number = line_of(blanked, found.start())
                if self.repo.in_rust_test(path, number):
                    continue
                inside = enclosing_function(functions, found.start())
                caller = inside[0] if inside else "<module>"
                if caller in self.Q3_PRIMITIVES or caller == name:
                    continue  # a primitive's own definition delegating to another primitive
                what = name if name in self.Q3_PRIMITIVES else f"{name} (wraps {wrappers[name]})"
                hits.append(Hit(path, number, f"{caller} -> {what}"))
        raw = raw_scan(self.repo, self.Q3_RAW, pathspecs)
        return Result("Q3", "F10 receipt waits", hits, raw_command(self.Q3_RAW, pathspecs), len(raw))

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
                    hits.append(Hit(path, number, f"{where}: {token}"))
        raw = raw_scan(self.repo, self.Q4_RAW, self.Q4_PATHS)
        return Result("Q4", "side connections", hits, raw_command(self.Q4_RAW, self.Q4_PATHS), len(raw))

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
    Q8_RAW = (
        r'\.name\((format!\()?"(mux-|surface-|terminal-host-(client|client-input|parser)"|cmux-link-(in|out)")'
        r'|spawn_journal_writer\("'
    )
    Q8_PATHS = (RUST_CRATES, *RUST_NOT_TESTS)
    Q8_QOS = re.compile(r"\s*(?:cmux_tui_platform::)?qos::set_current\b")

    def q8_body_sets_qos(self, blanked: str, start: int) -> bool:
        """Whether the thread spawned after `start` begins with the QoS call."""
        spawn = re.compile(r"\.spawn\(\s*")
        found = spawn.search(blanked, start, start + 600)
        if found:
            k = found.end()
        else:  # spawn_journal_writer("name", body)
            comma = blanked.find(",", start)
            k = comma + 1 if comma >= 0 else start
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

    def q8(self) -> Result:
        name_site = re.compile(r"\.name\(\s*(?:format!\(\s*)?" + self.Q8_NAME + r"|spawn_journal_writer\(\s*" + self.Q8_NAME)
        hits = []
        for path in self.repo.files(self.Q8_PATHS):
            if not path.endswith(".rs"):
                continue
            text = self.repo.text(path)
            if ".name(" not in text and "spawn_journal_writer(" not in text:
                continue
            blanked = self.repo.blanked(path)
            for found in name_site.finditer(text):
                if blanked[found.start()] != text[found.start()]:
                    continue  # inside a comment or string
                number = line_of(text, found.start())
                if self.repo.in_rust_test(path, number) or self.q8_body_sets_qos(blanked, found.end()):
                    continue
                hits.append(Hit(path, number, found.group(1) or found.group(2)))
        raw = raw_scan(self.repo, self.Q8_RAW, self.Q8_PATHS)
        return Result("Q8", "threads without QoS", hits, raw_command(self.Q8_RAW, self.Q8_PATHS), len(raw))

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
        hits, source = self.io_sites()
        ops = set(self.targets.get("ipc5_ops", []))
        chosen = []
        for hit in hits:
            fields = dict(part.split("=", 1) for part in hit.key.split() if "=" in part)
            if fields.get("kind") != "sqlite":
                continue
            if "op" in fields and fields["op"] not in ops:
                continue
            chosen.append(hit)
        return Result("Q18", "request-path SQLite reads", chosen, source=source)

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
    def q12(self) -> Result:
        decoded: set[str] = set()
        for found in re.finditer(r'\bcase\s+("[^"\n]+"(?:\s*,\s*"[^"\n]+")*)\s*:', self.repo.text(EVENT_DECODER)):
            decoded.update(re.findall(r'"([^"]+)"', found.group(1)))
        hits = [
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
            if not path.endswith(".rs") or path.endswith("/lock_rank.rs"):
                continue  # lock_rank.rs defines the ranks, not locks
            text = self.repo.text(path)
            if "LockRank::" not in text:
                continue
            blanked = self.repo.blanked(path)
            for found in rank.finditer(blanked):
                if re.search(r"HeldRank::check\(\s*(?:crate::lock_rank::)?$", blanked[max(0, found.start() - 60):found.start()]):
                    continue  # a check of a held rank, not a definition
                number = line_of(blanked, found.start())
                if self.repo.in_rust_test(path, number):
                    continue
                label = name.match(text, found.end())
                lock = (label.group(2) if label.group(2) is not None else label.group(3)) if label else "?"
                key = f"{found.group(1)} {lock}"
                if key in seen:
                    continue
                seen.add(key)
                hits.append(Hit(path, number, key))
        raw = raw_scan(self.repo, pattern, (CORE,))
        return Result("Q17", "ranked lock definitions", hits, raw_command(pattern, (CORE,)), len(raw))

    # --callers ------------------------------------------------------------------------------
    def callers(self, directory: str) -> list[Hit]:
        directory = directory.rstrip("/")
        if not directory.startswith(APP):
            directory = f"{APP}/{directory}"
        types: set[str] = set()
        for hit in self.unfiltered("Q1"):
            if hit.file.startswith(directory + "/"):
                type_name, _ = swift_enclosing(self.repo.lines(hit.file), hit.line - 1)
                if type_name:
                    types.add(type_name.split(".")[-1])
        if not types:
            return []
        reference = re.compile(r"(?<![\w.])(" + "|".join(sorted(map(re.escape, types))) + r")\b")
        declaration = re.compile(r"\b(?:struct|enum|class|actor|extension|typealias)\s+$")
        hits = []
        for path in self.repo.files((f"{APP}/*.swift", ":!*.generated.swift")):
            if not any(name in self.repo.text(path) for name in types):
                continue
            blanked = self.repo.blanked(path)
            first: dict[str, int] = {}
            for found in reference.finditer(blanked):
                line_start = blanked.rfind("\n", 0, found.start()) + 1
                if declaration.search(blanked[line_start:found.start()]):
                    continue
                first.setdefault(found.group(1), line_of(blanked, found.start()))
            hits.extend(Hit(path, number, type_name) for type_name, number in first.items())
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
        groups = result.groups()
        if groups:
            entry["groups"] = groups
        queues[queue] = entry
    targets["base"] = {"sha": census.repo.head(), "queues": queues}
    if census.io_record is not None:
        targets.setdefault("runtime", {})["Q9"] = [hit.as_json() for hit in census.result("Q9").hits]
    path.write_text(json.dumps(targets, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return targets


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
        if args.queue:
            shown = {queue: [hit.as_json() for hit in census.result(queue).hits] for queue in args.queue}
            for queue in args.queue:
                result = census.result(queue)
                raw = f"; raw {result.raw_count}: {result.raw}" if result.raw is not None else ""
                print(f"{queue} {result.title}: {result.count} ({result.found} before the allowlist){raw}", file=sys.stderr)
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
