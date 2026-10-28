#!/usr/bin/env python3
"""Every feature a Release build offers has a Release code path.

A Release build offers a feature (schemas/features/features.d) when its kind is `labs` (the Labs page
turns it on) or `killSwitch` (a signed remote document turns it off), or when any `defaults.release` is
true, and it is not `benchOnly` (those are compiled out of Release). For each such app feature (process
`app` or `both`), this reads the Swift sources and follows the switch from its read sites
(`isEnabled(.name)`, `resolution(of: .name)`, `effectiveLocalOverride(.name, ...)`, also with
`Feature.name`) through what each read sets:

  a local (`let pump = isEnabled(.x) ? A : nil`): followed in its own file;
  a property (`source.routesHostInput = ...`): followed in the files that name the receiver (`source`) or
    declare the property (`var routesHostInput`);
  an argument label (`hostInput: source.routesHostInput`): followed in the files that declare the callee
    (`func adopt`, a type and its extensions for `Type(...)` and `self.init(...)`);

for up to MAX_HOPS hops, until a use that decides something: a condition (`if`, `guard`, `if let`, `&&`,
`while`), an unlabelled argument, a `return`, an operand, a method call on it. The feature passes when one
such use is in code a Release build compiles. Code under a `#if` branch whose condition is false when DEBUG,
CMUX_BENCH_HOOKS and CMUX_BLOCKING_CHECKS are off (`#if DEBUG`, `#if DEBUG || CMUX_BENCH_HOOKS`,
`#if CMUX_BENCH_HOOKS`, an `#else` of `#if !DEBUG`, ...) is not. Other conditions (`os(...)`,
`canImport(...)`, GHOSTTY_* defines) count as maybe compiled.

What it does not see (it reads text, not a type-checked program):
- Names are followed by spelling inside the files above, not by type: a name another type in those files
  also uses can lead to that type's Release use and pass a feature that has none. A name in more than
  MAX_NAME_FILES of them is not followed; when nothing else decides, the feature is listed as "not judged"
  and never refused.
- A closure capture list (`[routesInput] in`) is not a use; the closure's own uses of the name are.
- A use inside a function that only DEBUG code calls counts as a Release use (callers are not followed).
- A condition's body is not checked: `if routes { #if DEBUG ... #endif }` passes.
- A feature read from strings or by another process (process `daemon`, `chromium`, or the Rust side of
  `both`) is not checked; a `both` feature the app never reads is "not judged".

  check-release-switch-paths.py                        # the working tree; offenders exit 1
  check-release-switch-paths.py --list                 # every offender and the not-judged, exit 0
  check-release-switch-paths.py --rev HEAD --base B     # only offenders HEAD has and no BASE has
  check-release-switch-paths.py --explain NAME          # the hops followed for one feature

What it does not see (each is "not judged" or "ok", never a refusal): a switch whose code compiles in Release but can
never run there (the host-mode switches before they became benchOnly: their supervisor is nil in Release); a switch
whose value goes into a name in more than MAX_NAME_FILES files (a rename onto a common name hides it); a handle read
indirectly (a gate list, a stored handle); a property that runs code when set or read (didSet, a getter); a chain past
MAX_HOPS. An offender is refused only with proof: no read and no handle anywhere, every read under a #if Release does
not compile, or every use the walk reached under such a #if.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import NamedTuple

HERE = Path(__file__).resolve().parent
FEATURES_DIR = "schemas/features/features.d"
SOURCES = ("Packages/macOS/CmuxNext/Sources",)
GENERATED = "Features.generated.swift"
# Defines a Release build never sets (Package.swift and the release workflows); everything else is unknown.
OFF_IN_RELEASE = frozenset({"DEBUG", "CMUX_BENCH_HOOKS", "CMUX_BLOCKING_CHECKS"})
READ_CALLS = ("isEnabled", "resolution", "effectiveLocalOverride")
MAX_HOPS = 6
MAX_NAME_FILES = 25
# The first line of a refusal (prepush-gate.py matches it).
HEADER = "check-release-switch-paths: features a Release build offers whose switch has no Release code path"


def _load_git_batch():
    """git_batch.py from this folder (python3 -I puts no script folder on sys.path), or None."""
    path = HERE / "git_batch.py"
    if not path.is_file():
        return None
    spec = importlib.util.spec_from_file_location("cmux_next_git_batch_release_paths", path)
    if spec is None or spec.loader is None:
        return None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# ---------------------------------------------------------------------------------------------------------
# Trees: the working tree (or a fixture folder) and a git revision.


class DirTree:
    """Files under ROOT on disk."""

    def __init__(self, root: Path):
        self.root = Path(root)
        self.cache: dict[str, str] = {}

    def feature_files(self) -> dict[str, str]:
        folder = self.root / FEATURES_DIR
        if not folder.is_dir():
            return {}
        return {f"{FEATURES_DIR}/{p.name}": p.read_text(encoding="utf-8") for p in sorted(folder.glob("*.json"))}

    def swift_files(self, roots: tuple[str, ...]) -> list[str]:
        found = []
        for root in roots:
            base = self.root / root
            if not base.is_dir():
                continue
            for folder, _dirs, files in os.walk(base):
                for name in files:
                    if name.endswith(".swift"):
                        found.append(Path(folder, name).relative_to(self.root).as_posix())
        return sorted(found)

    def read(self, path: str) -> str:
        if path not in self.cache:
            self.cache[path] = (self.root / path).read_text(encoding="utf-8", errors="replace")
        return self.cache[path]

    def files_with_words(self, words: set[str], roots: tuple[str, ...]) -> dict[str, set[str]]:
        """{word: files whose raw text has it as a whole word}."""
        pattern = re.compile(r"\b(" + "|".join(sorted(map(re.escape, words))) + r")\b")
        hits: dict[str, set[str]] = {w: set() for w in words}
        for path in self.swift_files(roots):
            for word in set(pattern.findall(self.read(path))):
                hits[word].add(path)
        return hits


    def files_declaring(self, names: set[str], roots: tuple[str, ...]) -> dict[str, set[str]]:
        """{name: files whose raw text declares it (`func name`, `var name`, a type `name` or its extension)}."""
        pattern = _declaration(names)
        found: dict[str, set[str]] = {n: set() for n in names}
        for path in self.swift_files(roots):
            for match in pattern.finditer(self.read(path)):
                found[match.group(1)].add(path)
        return found


def _declaration(names: set[str]) -> re.Pattern:
    return re.compile(r"\b(?:func|class|struct|enum|actor|extension|protocol|var|let)\s+(" + "|".join(sorted(map(re.escape, names)))
                      + r")\b")


class GitTree:
    """Files at REV of the repository REPO, read with git grep and one cat-file batch per call."""

    def __init__(self, repo: Path, rev: str):
        self.repo, self.rev = Path(repo), rev
        self.cache: dict[str, str] = {}
        self.git_batch = _load_git_batch()

    def _git(self, *args: str) -> str:
        done = subprocess.run(["git", "-C", str(self.repo), *args], capture_output=True, text=True,
                              stdin=subprocess.DEVNULL)
        if done.returncode not in (0, 1):  # git grep exits 1 when nothing matches
            raise RuntimeError(f"git {' '.join(args[:3])} failed: {done.stderr.strip()}")
        return done.stdout

    def _cat(self, paths: list[str]) -> None:
        missing = [p for p in paths if p not in self.cache]
        if not missing:
            return
        if self.git_batch is not None:
            blobs = self.git_batch.cat_file(self.repo, [f"{self.rev}:{p}" for p in missing])
            for path in missing:
                blob = blobs.get(f"{self.rev}:{path}")
                self.cache[path] = blob.decode("utf-8", "replace") if blob is not None else ""
            return
        for path in missing:
            self.cache[path] = self._git("show", f"{self.rev}:{path}")

    def feature_files(self) -> dict[str, str]:
        paths = [p for p in self._git("ls-tree", "-r", "--name-only", self.rev, "--", FEATURES_DIR).splitlines()
                 if p.endswith(".json")]
        self._cat(paths)
        return {p: self.cache[p] for p in paths}

    def swift_files(self, roots: tuple[str, ...]) -> list[str]:
        return sorted(p for p in self._git("ls-tree", "-r", "--name-only", self.rev, "--", *roots).splitlines()
                      if p.endswith(".swift"))

    def read(self, path: str) -> str:
        self._cat([path])
        return self.cache[path]

    def files_with_words(self, words: set[str], roots: tuple[str, ...]) -> dict[str, set[str]]:
        hits: dict[str, set[str]] = {w: set() for w in words}
        if not words:
            return hits
        args = ["grep", "-I", "-o", "-w", "--no-color", "-z"]
        for word in sorted(words):
            args += ["-e", word]
        out = self._git(*args, self.rev, "--", *(f"{r}/*.swift" for r in roots))
        prefix = f"{self.rev}:"
        # -z -o: "rev:path\0match\n" per match.
        for row in out.split("\n"):
            if "\0" not in row:
                continue
            path, word = row.split("\0", 1)
            path = path[len(prefix):] if path.startswith(prefix) else path
            if word in hits:
                hits[word].add(path)
        self._cat(sorted({p for files in hits.values() for p in files if len(files) <= MAX_NAME_FILES}))
        return hits

    def files_declaring(self, names: set[str], roots: tuple[str, ...]) -> dict[str, set[str]]:
        found: dict[str, set[str]] = {n: set() for n in names}
        if not names:
            return found
        pattern = _declaration(names)
        # POSIX ERE only (no \\b or \\s: macOS git may lack them); the Python pattern then judges each line.
        loose = "(func|class|struct|enum|actor|extension|protocol|var|let)[[:space:]]+(" + "|".join(sorted(names)) + ")"
        out = self._git("grep", "-I", "-E", "--no-color", "-z", "-e", loose, self.rev, "--",
                        *(f"{r}/*.swift" for r in roots))
        prefix = f"{self.rev}:"
        for row in out.split("\n"):
            if "\0" not in row:
                continue
            path, text = row.split("\0", 1)
            path = path[len(prefix):] if path.startswith(prefix) else path
            for match in pattern.finditer(text):
                found[match.group(1)].add(path)
        return found


# ---------------------------------------------------------------------------------------------------------
# Swift text: comments and string contents blanked, and which lines a Release build compiles.

_STRING_OPEN = re.compile(r'(#*)("""|")')


def mask(text: str) -> str:
    """TEXT with comments and string-literal contents blanked to spaces (same length, line breaks kept)."""
    n, out = len(text), list(text)

    def blank(start: int, end: int) -> None:
        for k in range(start, min(end, n)):
            if out[k] != "\n":
                out[k] = " "

    def comment_end(i: int) -> int:
        if text.startswith("//", i):
            j = text.find("\n", i)
            return n if j < 0 else j
        depth, j = 1, i + 2
        while j < n and depth:
            if text.startswith("/*", j):
                depth, j = depth + 1, j + 2
            elif text.startswith("*/", j):
                depth, j = depth - 1, j + 2
            else:
                j += 1
        return j

    def string_end(literal: re.Match) -> int:
        hashes, quotes = literal.groups()
        close, escape, j = quotes + hashes, "\\" + hashes, literal.end()
        while j < n:
            if text.startswith(escape + "(", j):
                j = interpolation_end(j + len(escape) + 1)
            elif text.startswith(escape, j):
                j += len(escape) + 1
            elif text.startswith(close, j):
                return j + len(close)
            elif quotes == '"' and text[j] == "\n":
                return j
            else:
                j += 1
        return n

    def interpolation_end(i: int) -> int:
        depth = 1
        while i < n and depth:
            if text.startswith(("//", "/*"), i):
                i = comment_end(i)
            elif literal := _STRING_OPEN.match(text, i):
                i = string_end(literal)
            else:
                depth += (text[i] == "(") - (text[i] == ")")
                i += 1
        return i

    i = 0
    while i < n:
        if text.startswith(("//", "/*"), i):
            end = comment_end(i)
            blank(i, end)
            i = end
        elif (literal := _STRING_OPEN.match(text, i)) and not (i and (text[i - 1].isalnum() or text[i - 1] == "_")):
            end = string_end(literal)
            # Keep the delimiters' first character so `"` still separates tokens.
            blank(literal.end(), end)
            i = max(end, i + 1)
        else:
            i += 1
    return "".join(out)


_TOKEN = re.compile(r"\s*(\|\||&&|!|\(|\)|[A-Za-z_][A-Za-z0-9_]*(?:\s*\([^()]*\))?)")


def evaluate(condition: str) -> bool | None:
    """A `#if` condition with OFF_IN_RELEASE false: True, False, or None when it depends on other defines."""
    tokens, pos = [], 0
    condition = condition.strip()
    while pos < len(condition):
        match = _TOKEN.match(condition, pos)
        if not match:
            return None
        tokens.append(match.group(1))
        pos = match.end()
        if not condition[pos:].strip():
            break
    index = 0

    def peek() -> str | None:
        return tokens[index] if index < len(tokens) else None

    def take() -> str | None:
        nonlocal index
        index += 1
        return tokens[index - 1] if index <= len(tokens) else None

    def disjunction():
        value = conjunction()
        while peek() == "||":
            take()
            right = conjunction()
            value = True if value is True or right is True else (False if value is False and right is False else None)
        return value

    def conjunction():
        value = unary()
        while peek() == "&&":
            take()
            right = unary()
            value = False if value is False or right is False else (True if value is True and right is True else None)
        return value

    def unary():
        if peek() == "!":
            take()
            value = unary()
            return None if value is None else not value
        token = take()
        if token == "(":
            value = disjunction()
            take()
            return value
        if token in OFF_IN_RELEASE:
            return False
        if token == "true":
            return True
        if token == "false":
            return False
        return None

    try:
        return disjunction()
    except IndexError:
        return None


_DIRECTIVE = re.compile(r"^[ \t]*#(if|elseif|else|endif)\b(.*)$")


def release_lines(masked: str) -> list[bool]:
    """Per line (index 0 is line 1): False when a Release build cannot compile it, True otherwise."""
    stack: list[list] = []  # [any earlier branch maybe true, this branch's value]
    live = []
    for line in masked.split("\n"):
        directive = _DIRECTIVE.match(line)
        if directive:
            kind, rest = directive.groups()
            if kind == "if":
                stack.append([None, evaluate(rest)])
                stack[-1][0] = stack[-1][1]
            elif kind in ("elseif", "else") and stack:
                earlier = stack[-1][0]
                cond = evaluate(rest) if kind == "elseif" else True
                # This branch runs when no earlier one did and its condition holds.
                not_earlier = None if earlier is None else not earlier
                value = False if not_earlier is False or cond is False else (
                    True if not_earlier is True and cond is True else None)
                stack[-1][1] = value
                stack[-1][0] = True if earlier is True or cond is True else (
                    False if earlier is False and cond is False else None)
            elif kind == "endif" and stack:
                stack.pop()
            live.append(True)
            continue
        live.append(all(frame[1] is not False for frame in stack))
    return live


class Source(NamedTuple):
    path: str
    masked: str
    live: list[bool]
    line_starts: list[int]

    def line_of(self, offset: int) -> int:
        lo, hi = 0, len(self.line_starts) - 1
        while lo < hi:
            mid = (lo + hi + 1) // 2
            if self.line_starts[mid] <= offset:
                lo = mid
            else:
                hi = mid - 1
        return lo + 1

    def is_live(self, offset: int) -> bool:
        return self.live[self.line_of(offset) - 1]


def parse(path: str, text: str) -> Source:
    masked = mask(text)
    starts = [0] + [m.end() for m in re.finditer("\n", masked)]
    return Source(path, masked, release_lines(masked), starts)


# ---------------------------------------------------------------------------------------------------------
# What an expression at an offset does: sets a name (and which), is a capture, or decides something.

_CONTINUES = set("=&|?:+-*/<>!")
_ASSIGN = re.compile(r"\s*(?:(?:[\w@]+\s+)*?(let|var)\s+)?(?P<receiver>(?:[\w?!]+\.)*)(\w+)\s*(?::[^=]*)?"
                     r"(?<![=!<>+\-*/%&|^])=(?!=)")
_LABEL = re.compile(r"\s*(\w+)\s*:(?!:)")
_CONSUMER_START = re.compile(r"\s*(if|guard|while|return|case|switch|else|repeat|throw|try|await)\b")


class Context(NamedTuple):
    kind: str  # "sets", "capture", "decides"
    name: str = ""
    local: bool = False  # a `let`/`var` of its own file
    callee: str = ""  # for an argument label: the function or type called
    receiver: str = ""  # for `a.b.prop = ...`: b


def _enclosing_open(masked: str, pos: int) -> int:
    """The offset of the bracket that holds POS unclosed, or -1."""
    depth = 0
    for k in range(pos - 1, -1, -1):
        c = masked[k]
        if c in ")]}":
            depth += 1
        elif c in "([{":
            if depth == 0:
                return k
            depth -= 1
    return -1


def _callee(masked: str, start: int) -> str:
    """The function or type called with the argument list that holds START (`Foo(a: x)` -> Foo), or ""."""
    opener = _enclosing_open(masked, start)
    if opener < 0 or masked[opener] != "(":
        return ""
    name = re.search(r"(?:(\w+)\s*\.\s*)?(\w+)\s*$", masked[:opener])
    if not name:
        return ""
    if name.group(2) == "init" and name.group(1) not in (None, "self", "Self", "super"):
        return name.group(1)  # `Foo.init(`
    if name.group(2) in ("init", "self", "Self", "super"):
        # `self.init(` and `Self(`: the enclosing type (`super.init(` is approximated by it too).
        types = re.findall(r"\b(?:class|struct|enum|actor|extension)\s+(\w+)", masked[:opener])
        return types[-1] if types else ""
    return name.group(2)


def _closing(masked: str, opener: int) -> int:
    pairs = {"(": ")", "[": "]", "{": "}"}
    want, depth = pairs[masked[opener]], 0
    for k in range(opener, len(masked)):
        c = masked[k]
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
            if depth == 0:
                return k if c == want else -1
    return -1


def context(masked: str, start: int) -> Context:
    """What the expression starting at START feeds: a name it sets, a closure capture, or a use that decides."""
    depth, i = 0, start - 1
    while i >= 0:
        c = masked[i]
        if c in ")]}":
            depth += 1
        elif c in "([{":
            if depth == 0:
                break
            depth -= 1
        elif depth == 0 and c in ",;":
            break
        elif depth == 0 and c == "\n":
            before = masked[:i].rstrip()
            if not before or before[-1] not in _CONTINUES:
                break
        i -= 1
    segment = masked[i + 1:start] if i >= 0 else masked[:start]
    opener = masked[i] if i >= 0 else ""
    if opener == ",":
        # A list item: find the list's opener (a call's arguments, an array, a capture list) or a condition list.
        depth, j = 0, i - 1
        while j >= 0:
            c = masked[j]
            if c in ")]}":
                depth += 1
            elif c in "([{":
                if depth == 0:
                    break
                depth -= 1
            j -= 1
        if j < 0 or masked[j] == "{":
            line_start = masked.rfind("\n", 0, i) + 1
            if _CONSUMER_START.match(masked, line_start):
                return Context("decides")
            # `let a = x, b = <expr>`: B is a local too.
            if re.match(r"\s*(?:[\w@]+\s+)*?(?:let|var)\s", masked[line_start:i]) and (assign := _ASSIGN.match(segment)):
                return Context("sets", assign.group(3), local=True)
        else:
            opener, i = masked[j], j
    if opener == "[":
        close = _closing(masked, i)
        if close >= 0 and re.match(r"\s*(?:\([^()]*\)\s*)?(?:->\s*[\w?.<>\[\]]+\s*)?in\b", masked[close + 1:]):
            return Context("capture")
    if _CONSUMER_START.match(segment):
        return Context("decides")
    assign = _ASSIGN.match(segment)
    if assign:
        receiver = assign.group("receiver").rstrip(".").split(".")[-1].rstrip("?!")
        return Context("sets", assign.group(3), local=bool(assign.group(1)),
                       receiver="" if receiver in ("", "self", "Self") else receiver)
    label = _LABEL.match(segment)
    if label and opener in "(,\n" and opener != "":
        return Context("sets", label.group(1), callee=_callee(masked, start))
    if not segment.strip() and opener == "{":
        # `var shows: Bool { features.isEnabled(.x) }`: the property is the next name.
        head = masked[:i].rstrip()
        prop = re.search(r"\bvar\s+(\w+)\s*:\s*[\w?.<>\[\]]+$", head)
        if prop:
            return Context("sets", prop.group(1))
    return Context("decides")


def _chain_start(masked: str, offset: int) -> int:
    """Where the postfix chain that ends in the name at OFFSET starts (`a.b?.name` -> a)."""
    k = offset
    while k > 0 and (masked[k - 1].isalnum() or masked[k - 1] in "_.?!"):
        k -= 1
        if masked[k] == "." and k > 0 and masked[k - 1] == ")":
            # `call().name`: step over the call's arguments.
            depth, j = 0, k - 1
            while j >= 0:
                if masked[j] == ")":
                    depth += 1
                elif masked[j] == "(":
                    depth -= 1
                    if depth == 0:
                        break
                j -= 1
            k = max(j, 0)
    return k


# ---------------------------------------------------------------------------------------------------------
# The check.


class Feature(NamedTuple):
    name: str
    kind: str
    process: str
    why: str  # why a Release build offers it


def offered_features(tree) -> list[Feature]:
    features = []
    for path, text in sorted(tree.feature_files().items()):
        try:
            data = json.loads(text)
        except json.JSONDecodeError as error:
            raise RuntimeError(f"{path}: {error}") from error
        if data.get("benchOnly") or data.get("process") not in ("app", "both"):
            continue
        kind, defaults = data.get("kind", ""), data.get("defaults", {})
        if kind == "labs":
            why = "kind labs"
        elif kind == "killSwitch":
            why = "kind killSwitch"
        elif defaults.get("release"):
            why = "defaults.release true"
        else:
            continue
        features.append(Feature(data["name"], kind, data["process"], why))
    return features


class Verdict(NamedTuple):
    feature: Feature
    status: str  # "ok", "offender", "not judged"
    detail: str
    trail: list[str]


class Checker:
    def __init__(self, tree, roots: tuple[str, ...] = SOURCES):
        self.tree, self.roots = tree, roots
        self.parsed: dict[str, Source] = {}
        self.word_files: dict[str, set[str]] = {}
        self.declared: dict[str, set[str]] = {}

    def prefetch(self, words: set[str], callees: set[str] = frozenset()) -> None:
        """Looks up every word of WORDS and every declaration of CALLEES not looked up yet, one search each."""
        missing = {w for w in words if w not in self.word_files}
        if missing:
            self.word_files.update(self.tree.files_with_words(missing, self.roots))
        missing = {c for c in callees if c not in self.declared}
        if missing:
            self.declared.update(self.tree.files_declaring(missing, self.roots))

    def source(self, path: str) -> Source:
        if path not in self.parsed:
            self.parsed[path] = parse(path, self.tree.read(path))
        return self.parsed[path]

    def read_sites(self, names: list[str]) -> dict[str, list[tuple[Source, int]]]:
        """{feature: [(file, offset of the read call's start)]} for switch reads of NAMES. Also fills
        ``live_handles``: the features whose handle (`.name`, `Feature.name`) Release code names anywhere, read or
        not (a gate list, a stored handle)."""
        sites: dict[str, list[tuple[Source, int]]] = {n: [] for n in names}
        self.live_handles: set[str] = set()
        if not names:
            return sites
        hits = self.tree.files_with_words(set(names), self.roots)
        member = re.compile(r"(?<![\w)\]?!])(?:Feature)?\.(" + "|".join(map(re.escape, names)) + r")\b")
        for path in sorted({p for files in hits.values() for p in files}):
            if path.endswith(GENERATED):
                continue
            src = self.source(path)
            for match in member.finditer(src.masked):
                if src.is_live(match.start()):
                    self.live_handles.add(match.group(1))
                call = self._enclosing_read_call(src.masked, match.start())
                if call is not None:
                    sites[match.group(1)].append((src, call))
        return sites

    @staticmethod
    def _enclosing_read_call(masked: str, offset: int) -> int | None:
        """The start of the `x.isEnabled(` chain whose argument list holds OFFSET, or None."""
        depth, k = 0, offset - 1
        while k >= 0:
            c = masked[k]
            if c in ")]}":
                depth += 1
            elif c in "([{":
                if depth == 0:
                    break
                depth -= 1
            k -= 1
        if k < 0 or masked[k] != "(":
            return None
        callee = re.search(r"(\w+)\s*$", masked[:k])
        if not callee or callee.group(1) not in READ_CALLS:
            return None
        return _chain_start(masked, callee.start(1))

    def judge(self, feature: Feature, sites: list[tuple[Source, int]]):
        """A generator: yields the set of names its next hop reads (the driver looks them all up at once, for
        every feature), and returns the Verdict."""
        trail: list[str] = []
        if not sites and feature.process == "both":
            return Verdict(feature, "not judged", "no switch read in the app; its daemon side (Rust) is not checked",
                           trail)
        if not sites and feature.name in getattr(self, "live_handles", set()):
            return Verdict(feature, "not judged", "no direct switch read, but Release code names its handle (a gate "
                           "list or a stored handle the walk does not follow)", trail)
        if not sites:
            return Verdict(feature, "offender", "no switch read (isEnabled, resolution(of:), effectiveLocalOverride) "
                           "and no mention of its handle in the sources", trail)
        live_sites = [(s, o) for s, o in sites if s.is_live(o)]
        for src, off in sites:
            trail.append(f"read {src.path}:{src.line_of(off)}{'' if src.is_live(off) else ' (not in Release)'}")
        if not live_sites:
            where = ", ".join(f"{s.path}:{s.line_of(o)}" for s, o in sites)
            return Verdict(feature, "offender", f"every switch read is under a #if Release does not compile ({where})",
                           trail)
        # A name to follow and where: ("file", path) for a local, ("callee", name) for an argument label (the
        # files that declare the callee), ("member", receiver) for `receiver.prop = ...`, ("all", "") otherwise.
        frontier: list[tuple[str, tuple[str, str]]] = []
        for src, off in live_sites:
            ctx = context(src.masked, off)
            if ctx.kind == "decides":
                trail.append(f"decides at {src.path}:{src.line_of(off)}")
                return Verdict(feature, "ok", f"read decides at {src.path}:{src.line_of(off)}", trail)
            if ctx.kind == "sets":
                trail.append(f"{src.path}:{src.line_of(off)} sets {ctx.name}")
                frontier.append((ctx.name, self._scope(ctx, src.path)))
        seen: set[tuple[str, tuple[str, str]]] = set()
        chain: list[str] = []
        dead_uses: list[str] = []
        skipped: list[str] = []
        unmodeled: list[str] = []  # a followed property whose declaration runs code (didSet, willSet, a getter)
        for _hop in range(MAX_HOPS):
            frontier = [f for f in dict.fromkeys(frontier) if f not in seen]
            if not frontier:
                break
            seen.update(frontier)
            chain.extend(n for n, _ in frontier if n not in chain)
            yield ({name for name, _ in frontier} | {where for _, (kind, where) in frontier if kind == "member"},
                   {where for _, (kind, where) in frontier if kind == "callee"}
                   | {name for name, (kind, _) in frontier if kind == "member"})
            following: list[tuple[str, tuple[str, str]]] = []
            for name, (kind, where) in frontier:
                if kind == "file":
                    files = [where]
                elif kind == "callee":
                    files = sorted(self.declared.get(where, set()) & self.word_files.get(name, set()))
                elif kind == "member":
                    # `recv.prop = ...`: the files that name the receiver too, and the files that declare `prop`.
                    files = sorted(self.word_files.get(name, set())
                                   & (self.word_files.get(where, set()) | self.declared.get(name, set())))
                    if len(files) > MAX_NAME_FILES:
                        # A common name (`isEnabled`): only the files that declare it, where its type uses it.
                        files = sorted(self.word_files.get(name, set()) & self.declared.get(name, set()))
                else:
                    files = sorted(self.word_files.get(name, ()))
                if len(files) > MAX_NAME_FILES:
                    trail.append(f"{name}: in {len(files)} files, not followed")
                    skipped.append(f"`{name}` ({len(files)} files)")
                    continue
                observed = re.compile(r"\bvar\s+" + re.escape(name) + r"\b[^\n{=]*(?:=[^\n{]*)?\{\s*(?:didSet|willSet|get|set)\b"
                                      r"|\bvar\s+" + re.escape(name) + r"\s*:\s*[^\n={]+\{(?!\s*(?:didSet|willSet))")
                for path in files:
                    src = self.source(path)
                    if observed.search(src.masked):
                        unmodeled.append(f"`{name}` ({path})")
                    for use in re.finditer(r"(?<![\w$])" + re.escape(name) + r"\b", src.masked):
                        ctx = self._use(src, use)
                        if ctx is None or ctx.kind == "capture":
                            continue
                        line = src.line_of(use.start())
                        if not src.is_live(use.start()):
                            dead_uses.append(f"{path}:{line}")
                            continue
                        if ctx.kind == "decides":
                            trail.append(f"{name} decides at {path}:{line}")
                            return Verdict(feature, "ok", f"{name} decides at {path}:{line}", trail)
                        if ctx.name != name or ctx.local:
                            trail.append(f"{name} at {path}:{line} sets {ctx.name}")
                        following.append((ctx.name, self._scope(ctx, path)))
            frontier = following
        names = " -> ".join(chain) or "nothing"
        if skipped:
            return Verdict(feature, "not judged", f"no Release use found through {names}; not followed: "
                           f"{', '.join(skipped)} (over {MAX_NAME_FILES} files)", trail)
        dead_uses = list(dict.fromkeys(dead_uses))
        # An offender needs proof: a use of what it sets that only a Debug or bench build compiles. A walk that found
        # no use at all, or ran out of hops, cannot tell a no-op switch from a use this text walk does not model (a
        # memberwise init read elsewhere, a `didSet`, `.init(...)` shorthand, a chain over MAX_HOPS): not judged, so
        # correct code is never refused.
        if not dead_uses or frontier or unmodeled:
            why = ("ran out of hops" if frontier else
                   f"reached a property that runs code when set or read ({', '.join(unmodeled[:3])})" if unmodeled
                   else "found no use it can follow")
            return Verdict(feature, "not judged", f"read in Release; the walk through {names} {why}", trail)
        where = f"; its uses are only under #if Release does not compile ({', '.join(dead_uses[:6])}" + (
            ", ..." if len(dead_uses) > 6 else "") + ")"
        return Verdict(feature, "offender", f"read in Release, but what it sets ({names}) decides nothing a Release "
                       f"build compiles{where}", trail)

    @staticmethod
    def _scope(ctx: Context, path: str) -> tuple[str, str]:
        if ctx.local:
            return ("file", path)
        if ctx.callee:
            return ("callee", ctx.callee)
        if ctx.receiver:
            return ("member", ctx.receiver)
        return ("all", "")

    @staticmethod
    def _use(src: Source, use: re.Match) -> Context | None:
        """What the occurrence USE of a followed name does, or None when it is not a read of its value."""
        masked, start, end = src.masked, use.start(), use.end()
        after = masked[end:end + 40]
        before = masked[max(0, start - 40):start]
        if after.startswith(":") and not after.startswith("::"):
            return None  # a label or a declaration's name
        if re.match(r"\s*(?<![=!<>])=(?!=)", after) or re.match(r"\s*[-+*/%|&^]=", after):
            return None  # assigned, not read
        if re.search(r"\b(let|var)\s+$", before) and re.match(r"\s*(,|\{|else\b)", after):
            return Context("decides")  # `if let name {` / `guard let name else`: unwrapping it decides
        if re.search(r"\b(let|var|func|case|class|struct|enum|protocol|typealias)\s+$", before):
            return None
        if re.match(r"\s+in\b", after) or re.match(r"\s*,[\w\s,]*\bin\b", after) and before.rstrip().endswith("{"):
            return None  # a closure parameter
        return context(masked, _chain_start(masked, start))

    def run(self) -> list[Verdict]:
        features = offered_features(self.tree)
        sites = self.read_sites([f.name for f in features])
        verdicts: dict[str, Verdict] = {}
        running = {f.name: self.judge(f, sites[f.name]) for f in features}
        wants = {name: None for name in running}
        while running:
            words: set[str] = set()
            callees: set[str] = set()
            for name, judging in list(running.items()):
                try:
                    wants[name] = next(judging) if wants[name] is None else wants[name]
                    words |= wants[name][0]
                    callees |= wants[name][1]
                except StopIteration as done:
                    verdicts[name] = done.value
                    del running[name]
            self.prefetch(words, callees)
            for name in running:
                wants[name] = None
        return [verdicts[f.name] for f in features]


def offenders(tree, roots: tuple[str, ...] = SOURCES) -> dict[str, Verdict]:
    return {v.feature.name: v for v in Checker(tree, roots).run() if v.status == "offender"}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--repo", type=Path, default=None, help="the repository (default: this checkout)")
    parser.add_argument("--rev", default=None, help="judge this revision (default: the working tree)")
    parser.add_argument("--base", action="append", default=[], help="refuse only offenders no BASE has (repeatable)")
    parser.add_argument("--root", type=Path, default=None, help="judge this folder instead of a repository")
    parser.add_argument("--list", action="store_true", help="print every offender and the not-judged; exit 0")
    parser.add_argument("--explain", metavar="FEATURE", help="print the hops followed for FEATURE")
    args = parser.parse_args(argv)
    repo = args.repo or HERE.parent.parent
    try:
        tree = DirTree(args.root) if args.root else (GitTree(repo, args.rev) if args.rev else DirTree(repo))
        verdicts = Checker(tree).run()
        if args.explain:
            for v in verdicts:
                if v.feature.name == args.explain:
                    print(f"{v.feature.name}: {v.status}: {v.detail}")
                    print("\n".join(f"  {step}" for step in v.trail))
                    return 0
            print(f"{args.explain}: not a feature a Release build offers", file=sys.stderr)
            return 2
        bad = {v.feature.name: v for v in verdicts if v.status == "offender"}
        old: set[str] = set()
        for base in args.base:
            old |= set(offenders(GitTree(repo, base)))
    except Exception as error:  # a broken feature file or a bug here must never refuse a push (exit 2: no verdict)
        print(f"check-release-switch-paths: error: {type(error).__name__}: {error}", file=sys.stderr)
        return 2
    if args.list:
        for v in verdicts:
            if v.status != "ok":
                print(f"{v.status}\t{v.feature.name}\t{v.feature.why}\t{v.detail}")
        print(f"{len(bad)} offenders, {sum(v.status == 'not judged' for v in verdicts)} not judged, "
              f"{len(verdicts)} features a Release build offers")
        return 0
    new = {name: v for name, v in bad.items() if name not in old}
    if not new:
        return 0
    print(HEADER)
    for name, v in sorted(new.items()):
        print(f"  {name} ({v.feature.why}): {v.detail}")
    print("Compile the switch's behavior in every configuration (keep #if only around debug recording), or stop "
          "offering the feature in Release (benchOnly, or kind perfPath with every default false).")
    return 1


if __name__ == "__main__":
    sys.exit(main())
