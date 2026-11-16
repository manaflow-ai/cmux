#!/usr/bin/env python3
"""Every acpmux command a bench or measure script runs parses against acpmux's own clap grammar.

The tab switch bench ran `<acpmux> acp new ...`: `acp` is a word of the `cmux` CLI (`cmux acp new`,
cmux-tui's main.rs hands `acp|harness|chats` to acpmux's grammar), never of `acpmux` itself, so
every measurement exited 3 with "unrecognized subcommand 'acp'" (cmux-ci step
24fab655045655aabec9b210). This test reads the grammar from the Rust source, with no build:

  - acpmux's clap derive items under cmux-tui/crates/acpmux/src (cli/command.rs `Cli` and
    `Command`, the Args structs and Subcommand enums they name), and
  - the scope words cmux-tui/crates/cmux-tui/src/main.rs passes to acpmux (`cmux acp ...`).

It collects the argv lists the scripts under scripts/cmux-next, scripts/measure and scripts/ci (and
the shell scripts at scripts/ top level) build for acpmux or for `cmux acp|harness|chats`, follows
a binary held in a variable or passed as a parameter to where it is set, and checks each
subcommand and flag the way clap parses them. Where a script tries several forms in turn
(`[cli, *argv, ...]` over tab_switch_frames.py's `new_session_argvs`), the first, the primary form,
must parse; the later ones are fallbacks for older builds and are not read. A renamed or removed subcommand or flag fails the
pull request that renames it (scripts/ci/focused-tests-extra.json selects this test for any change
under cmux-tui/crates/acpmux/src/, cmux-tui/crates/cmux-tui/src/main.rs and the scanned scripts).

    python3 -m unittest tests/test_cmux_next_bench_cli_calls.py
"""
from __future__ import annotations

import ast
import re
import shlex
import unittest
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ACPMUX_SRC = "cmux-tui/crates/acpmux/src"
ACPMUX_ROOT_FILE = "cmux-tui/crates/acpmux/src/cli/command.rs"
ACPMUX_ENTRY = "cmux-tui/crates/acpmux/src/cli/entry.rs"
CMUX_MAIN = "cmux-tui/crates/cmux-tui/src/main.rs"
CMUX_ACP_SCOPE = "cmux-tui/crates/cmux-tui/src/acp.rs"
SCANNED_DIRS = ("scripts/cmux-next", "scripts/measure", "scripts/ci")
SCANNED_TOP = "scripts"

# Calls the detector must find, so a collector that goes blind fails instead of passing empty.
KNOWN_CALLS = (
    # The primary form of new_session_argvs; its `acp new` fallback is for builds older than the grammar here.
    ("scripts/cmux-next/tab_switch_frames.py", ("--json", "new", "-d", "-m")),
    ("scripts/cmux-next/bench_memory.py", ("acp", "new", "--json", "-d", "-m")),
    ("scripts/cmux-next/idle_cost_load.py", ("acp", "new", "--json", "-d", "-m")),
    ("scripts/cmux-next/idle_cost_load.py", ("send", "--no-wait")),
    ("scripts/fleet-quit-persistence.sh", ("new", "-d", "-m")),
)

# cmux-tui's acp.rs `run_as` answers these before acpmux's grammar sees them.
CMUX_SCOPE_SHORTCUTS = (("chats", "open"), ("open",), ("harness", "run"))


# ------------------------------------------------------------------------------------------------
# The grammar, from the Rust source.

def strip_comments(text: str) -> str:
    """Rust source without comments; strings, char literals and lifetimes kept as they are."""
    out, i, n = [], 0, len(text)
    while i < n:
        c = text[i]
        if text.startswith("//", i):
            j = text.find("\n", i)
            i = n if j < 0 else j
        elif text.startswith("/*", i):
            j = text.find("*/", i + 2)
            i = n if j < 0 else j + 2
        elif c == "r" and re.match(r'r#*"', text[i:i + 8]) and (i == 0 or not (text[i - 1].isalnum() or text[i - 1] == "_")):
            hashes = re.match(r'r(#*)"', text[i:]).group(1)
            end = text.find('"' + hashes, i + 2 + len(hashes))
            end = n if end < 0 else end + 1 + len(hashes)
            out.append(text[i:end])
            i = end
        elif c == '"':
            j = i + 1
            while j < n and text[j] != '"':
                j += 2 if text[j] == "\\" else 1
            out.append(text[i:j + 1])
            i = j + 1
        elif c == "'" and re.match(r"'(\\.|[^\\'])'", text[i:i + 4]):
            m = re.match(r"'(\\.|[^\\'])'", text[i:i + 4])
            out.append(m.group(0))
            i += len(m.group(0))
        else:
            out.append(c)
            i += 1
    return "".join(out)


def match_close(text: str, start: int) -> int:
    """The index just past the bracket that closes the one at `start` (strings skipped)."""
    pairs = {"{": "}", "(": ")", "[": "]"}
    stack, i = [], start
    while i < len(text):
        c = text[i]
        if c == '"':
            i += 1
            while i < len(text) and text[i] != '"':
                i += 2 if text[i] == "\\" else 1
        elif c == "'" and re.match(r"'(\\.|[^\\'])'", text[i:i + 4]):
            i += len(re.match(r"'(\\.|[^\\'])'", text[i:i + 4]).group(0)) - 1
        elif c in pairs:
            stack.append(pairs[c])
        elif stack and c == stack[-1]:
            stack.pop()
            if not stack:
                return i + 1
        i += 1
    raise ValueError(f"unclosed bracket at {start}")


def split_top(text: str) -> list[str]:
    """`text` split at commas outside brackets, angle brackets and strings; empty parts dropped."""
    parts, depth, angle, cur, i = [], 0, 0, [], 0
    while i < len(text):
        c = text[i]
        if c == '"':
            j = i + 1
            while j < len(text) and text[j] != '"':
                j += 2 if text[j] == "\\" else 1
            cur.append(text[i:j + 1])
            i = j + 1
            continue
        m = re.match(r"'(\\.|[^\\'])'", text[i:i + 4]) if c == "'" else None
        if m:
            cur.append(m.group(0))
            i += len(m.group(0))
            continue
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        elif c == "<" and depth == 0:
            angle += 1
        elif c == ">" and depth == 0 and angle and text[i - 1] != "-" and text[i - 1] != "=":
            angle -= 1
        if c == "," and depth == 0 and angle == 0:
            parts.append("".join(cur).strip())
            cur = []
        else:
            cur.append(c)
        i += 1
    parts.append("".join(cur).strip())
    return [p for p in parts if p]


def take_attributes(item: str) -> tuple[list[tuple[str, str]], str]:
    """Leading `#[name(args)]` attributes of an item as (name, args), and the rest."""
    attrs, item = [], item.strip()
    while item.startswith("#["):
        end = match_close(item, 1)
        inner = item[2:end - 1].strip()
        m = re.match(r"([\w:]+)\s*(?:\((.*)\))?\s*$", inner, re.S)
        if m:
            attrs.append((m.group(1), (m.group(2) or "").strip()))
        item = item[end:].strip()
    return attrs, item


def attr_keys(attrs: list[tuple[str, str]], names=("arg", "command", "clap")) -> list[tuple[str, str | None]]:
    """The keys of clap's attributes: [("long", None), ("short", "'x'"), ("alias", '"y"'), ...]."""
    out = []
    for name, args in attrs:
        if name not in names:
            continue
        for part in split_top(args):
            key, _, value = part.partition("=")
            out.append((key.strip(), value.strip() or None) if _ else (part.strip(), None))
    return out


def literal(value: str | None) -> str | None:
    if value is None:
        return None
    m = re.fullmatch(r'"((?:\\.|[^"\\])*)"|\'(.)\'', value.strip())
    return (m.group(1) if m.group(1) is not None else m.group(2)) if m else None


def literals(value: str | None) -> list[str]:
    if value is None:
        return []
    return [s for s in re.findall(r'"((?:\\.|[^"\\])*)"', value)]


def kebab(name: str) -> str:
    name = name.strip("_").replace("_", "-")
    return re.sub(r"(?<=[a-z0-9])(?=[A-Z])|(?<=[A-Z])(?=[A-Z][a-z])", "-", name).lower()


def type_name(ty: str) -> str:
    """The item a field or variant type names: `Box<crate::cli::x::Foo>` -> `crate::cli::x::Foo`."""
    ty = ty.strip()
    while True:
        m = re.fullmatch(r"(?:Box|Option|Vec)\s*<\s*(.*)\s*>", ty, re.S)
        if not m:
            return ty
        ty = m.group(1).strip()


@dataclass
class Flag:
    takes_value: bool
    global_: bool = False


@dataclass
class Node:
    name: str
    longs: dict[str, Flag] = field(default_factory=dict)
    shorts: dict[str, Flag] = field(default_factory=dict)
    subcommands: dict[str, "Node"] = field(default_factory=dict)
    positionals: int = 0
    trailing: bool = False  # trailing_var_arg / allow_hyphen_values: words after the first are values
    names: list[str] = field(default_factory=list)


@dataclass
class Item:
    kind: str  # "struct" or "enum"
    name: str
    body: str
    file: str
    derives: str


class Grammar:
    """acpmux's clap derive grammar, read from its source."""

    def __init__(self, root: Path):
        self.items: dict[str, list[Item]] = {}
        src = root / ACPMUX_SRC
        for path in sorted(src.rglob("*.rs")):
            rel = str(path.relative_to(root))
            if path.name.endswith("tests.rs") or "/tests/" in rel:
                continue
            text = strip_comments(path.read_text(encoding="utf-8", errors="replace"))
            for m in re.finditer(r"\b(struct|enum)\s+(\w+)\s*(?:<[^>{;]*>)?\s*\{", text):
                derives = self._derives_before(text, m.start())
                if not re.search(r"\b(Parser|Subcommand|Args)\b", derives):
                    continue
                brace = m.end() - 1
                body = text[brace + 1:match_close(text, brace) - 1]
                self.items.setdefault(m.group(2), []).append(Item(m.group(1), m.group(2), body, rel, derives))
        self._built: dict[tuple[str, str], Node] = {}
        roots = [i for i in self.items.get("Cli", []) if i.file == ACPMUX_ROOT_FILE]
        if not roots:
            raise AssertionError(f"no clap `Cli` in {ACPMUX_ROOT_FILE}")
        self.root = Node("acpmux", names=["acpmux"])
        self.root.longs.update({"help": Flag(False), "version": Flag(False)})
        self.root.shorts.update({"h": Flag(False), "V": Flag(False)})
        self._add_fields(self.root, roots[0], set())

    @staticmethod
    def _derives_before(text: str, start: int) -> str:
        """The attributes right above an item (`#[derive(...)]` and the rest), as one string."""
        head = text[:start].rstrip()
        head = re.sub(r"(pub(\s*\([^)]*\))?)\s*$", "", head).rstrip()
        attrs = []
        while head.endswith("]"):
            depth, i = 0, len(head) - 1
            while i >= 0:
                if head[i] == "]":
                    depth += 1
                elif head[i] == "[":
                    depth -= 1
                    if depth == 0:
                        break
                i -= 1
            if i <= 0 or head[i - 1] != "#":
                break
            attrs.append(head[i - 1:])
            head = head[:i - 1].rstrip()
        return " ".join(reversed(attrs))

    def item(self, ty: str, near: str) -> Item | None:
        """The clap item a type names; with two of one name, the one whose file matches the path."""
        path = type_name(ty)
        name = path.split("::")[-1]
        found = self.items.get(name, [])
        if len(found) <= 1:
            return found[0] if found else None
        segments = [s for s in path.split("::")[:-1] if s not in ("crate", "self", "super")]
        if segments:
            want = "/".join(segments)
            exact = [i for i in found if want in i.file]
            if exact:
                return exact[0]
        same = [i for i in found if i.file == near]
        return same[0] if same else found[0]

    def _add_fields(self, node: Node, item: Item, seen: set[str]) -> None:
        if item.kind != "struct":
            raise AssertionError(f"{item.name} ({item.file}) is not an Args struct")
        if (item.file, item.name) in seen:
            return
        seen = seen | {(item.file, item.name)}
        for part in split_top(item.body):
            attrs, rest = take_attributes(part)
            m = re.match(r"(?:pub(?:\s*\([^)]*\))?\s+)?(\w+)\s*:\s*(.+)$", rest, re.S)
            if not m:
                continue
            self._add_field(node, m.group(1), m.group(2).strip(), attrs, item.file, seen)

    def _add_field(self, node: Node, name: str, ty: str, attrs, near: str, seen: set) -> None:
        keys = attr_keys(attrs)
        has = {k for k, _ in keys}
        if "skip" in has:
            return
        if "flatten" in has:
            inner = self.item(ty, near)
            if inner is None:
                raise AssertionError(f"flattened {ty} not found ({near})")
            self._add_fields(node, inner, seen)
            return
        if "subcommand" in has:
            inner = self.item(ty, near)
            if inner is None:
                raise AssertionError(f"subcommand enum {ty} not found ({near})")
            self._add_variants(node, inner, seen)
            return
        bare = type_name(ty) == "bool" and not ty.strip().startswith("Option")
        action = dict(keys).get("action") or ""
        takes = not (bare or "Count" in action or "SetTrue" in action or "SetFalse" in action)
        flag = Flag(takes, "global" in has)
        if "long" not in has and "short" not in has:
            node.positionals += 1
            if "trailing_var_arg" in has or "allow_hyphen_values" in has or "last" in has:
                node.trailing = True
            return
        for key, value in keys:
            if key == "long":
                node.longs[literal(value) or kebab(name)] = flag
            elif key in ("alias", "visible_alias"):
                node.longs[literal(value)] = flag
            elif key in ("aliases", "visible_aliases"):
                for alias in literals(value):
                    node.longs[alias] = flag
            elif key == "short":
                node.shorts[literal(value) or name.strip("_")[0]] = flag
            elif key in ("short_alias", "visible_short_alias"):
                node.shorts[literal(value)] = flag

    def _add_variants(self, node: Node, item: Item, seen: set) -> None:
        if item.kind != "enum":
            raise AssertionError(f"{item.name} ({item.file}) is not a Subcommand enum")
        for part in split_top(item.body):
            attrs, rest = take_attributes(part)
            keys = attr_keys(attrs)
            has = {k for k, _ in keys}
            if "skip" in has:
                continue
            m = re.match(r"(\w+)\s*(.*)$", rest, re.S)
            if not m:
                continue
            variant, shape = m.group(1), m.group(2).strip()
            if "flatten" in has and shape.startswith("("):
                inner = self.item(shape[1:-1], item.file)
                if inner is not None and inner.kind == "enum":
                    self._add_variants(node, inner, seen)
                    continue
            values = dict(keys)
            name = literal(values.get("name")) or kebab(variant)
            child = Node(name, names=[name])
            for key, value in keys:
                if key in ("alias", "visible_alias"):
                    child.names.append(literal(value))
                elif key in ("aliases", "visible_aliases"):
                    child.names.extend(literals(value))
            child.longs["help"] = Flag(False)
            child.shorts["h"] = Flag(False)
            if shape.startswith("{"):
                body = shape[1:match_close(shape, 0) - 1]
                self._add_fields(child, Item("struct", f"{item.name}::{variant}", body, item.file, ""), seen)
            elif shape.startswith("("):
                inner = self.item(shape[1:match_close(shape, 0) - 1], item.file)
                if inner is None:
                    raise AssertionError(f"{item.name}::{variant}: {shape} not found")
                if inner.kind == "enum":
                    self._add_variants(child, inner, seen)
                else:
                    self._add_fields(child, inner, seen)
            for alias in child.names:
                node.subcommands[alias] = child

    # --------------------------------------------------------------------------------------------
    # Parsing an argv the way clap does.

    def check(self, words: list[str | None]) -> str | None:
        """None when `acpmux WORDS` parses (as far as the words are known), else clap's complaint.
        A None word is one the script computes at run time: any value, never a subcommand."""
        words = list(words)
        at = next((i for i, w in enumerate(words) if w not in ("--json", "--suppress-reads")), len(words))
        # entry.rs rewrites before clap: `stop NAME` is `session stop NAME`; `--skill`/`--guide` are `skill`.
        if at < len(words) and words[at] == "stop":
            words[at:at + 1] = ["session", "stop"]
        if at < len(words) and words[at] in ("--skill", "--guide"):
            words[at] = "skill"
        node, globals_, path = self.root, {}, ["acpmux"]
        positional = 0
        i = 0
        while i < len(words):
            word = words[i]
            i += 1
            for k, v in node.longs.items():
                if v.global_:
                    globals_[k] = v
            if word is None:
                if node.subcommands and positional == 0:
                    return None  # a computed subcommand: nothing past it can be checked
                positional += 1
                continue
            if word == "--":
                return None
            if word.startswith("--") and len(word) > 2 and not (node.trailing and positional):
                name, eq, _ = word[2:].partition("=")
                flag = node.longs.get(name) or globals_.get(name)
                if flag is None:
                    return f"{' '.join(path)}: unexpected argument '--{name}'"
                if flag.takes_value and not eq:
                    i += 1
                continue
            if word.startswith("-") and len(word) > 1 and not re.fullmatch(r"-\d+(\.\d+)?", word) \
                    and not (node.trailing and positional):
                for j, ch in enumerate(word[1:]):
                    flag = node.shorts.get(ch)
                    if flag is None:
                        return f"{' '.join(path)}: unexpected argument '-{ch}'"
                    if flag.takes_value:
                        if j == len(word) - 2:
                            i += 1
                        break
                continue
            if node.subcommands and positional == 0:
                child = node.subcommands.get(word)
                if child is None:
                    if word == "help":
                        return None
                    return f"{' '.join(path)}: unrecognized subcommand '{word}'"
                node, positional = child, 0
                path.append(word)
                continue
            positional += 1
        return None


def cmux_scope_heads(root: Path) -> set[str]:
    """The first words `cmux` hands to acpmux's grammar (main.rs: `Some(head @ ("acp" | ...))`)."""
    text = strip_comments((root / CMUX_MAIN).read_text(encoding="utf-8"))
    m = re.search(r"Some\(\s*head\s*@\s*\(([^)]*)\)\s*\)", text)
    if not m:
        raise AssertionError(f"{CMUX_MAIN}: no `Some(head @ (\"acp\" | ...))` scope dispatch")
    return set(re.findall(r'"([\w-]+)"', m.group(1)))


def check_call(grammar: Grammar, heads: set[str], kind: str, words: list[str | None]) -> str | None:
    if kind == "acpmux":
        return grammar.check(words)
    rest = [w for w in words]
    while rest and rest[0] == "--json":
        rest = rest[1:]
    if not rest or rest[0] not in heads:
        return None  # a cmux command outside the acp scope: cmux-tui's own grammar, not checked here
    for shortcut in CMUX_SCOPE_SHORTCUTS:
        tail = rest[1:] if rest[0] == "acp" else rest
        if tuple(tail[:len(shortcut)]) == shortcut:
            return None
    error = grammar.check(rest[1:] if rest[0] == "acp" else rest)
    return error and error.replace("acpmux", f"cmux {rest[0]}" if rest[0] == "acp" else "cmux", 1)


# ------------------------------------------------------------------------------------------------
# The calls, from the scripts.

def path_kind(text: str) -> str | None:
    """The CLI a path or program name runs: `.../bin/acpmux` -> acpmux, `.../bin/cmux` -> cmux."""
    base = text.rstrip("/").rsplit("/", 1)[-1].strip("\"'")
    if base == "acpmux":
        return "acpmux"
    if base in ("cmux", "cmux-tui"):
        return "cmux"
    return None


@dataclass
class Call:
    file: str
    line: int
    kind: str
    words: list[str | None]

    def argv(self) -> str:
        return " ".join([self.kind] + [w if w is not None else "<computed>" for w in self.words])


LAUNCHERS = {"run", "Popen", "check_output", "check_call", "call", "execv", "execvp", "spawn", "run_cmd", "sh"}
MENTIONS_CLI = re.compile(r"acpmux|[\"']acp[\"']|bin/cmux|[\"']cmux[\"']|cmux-tui")


def target_key(node: ast.AST) -> str | None:
    """`cli` or `self.cli` for an assignment target or a read; None for anything else."""
    if isinstance(node, ast.Name):
        return node.id
    if isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name):
        return f"{node.value.id}.{node.attr}"
    return None


class PyScripts:
    """The Python scripts' argv lists, with the binary each runs followed to where it is set."""

    def __init__(self, root: Path, files: list[Path]):
        self.root = root
        self.modules: dict[str, ast.Module] = {}
        for path in files:
            try:
                text = path.read_text(encoding="utf-8")
            except UnicodeDecodeError:
                continue
            if not MENTIONS_CLI.search(text):
                continue  # names no CLI of ours: no call to check, no binary to pass on
            try:
                self.modules[str(path.relative_to(root))] = ast.parse(text)
            except SyntaxError:
                continue
        self.parents: dict[int, ast.AST] = {}
        self.assigns: dict[tuple[str, str], list[ast.AST]] = {}
        self.functions: dict[str, list[tuple[str, ast.FunctionDef]]] = {}
        self.calls: dict[str, list[tuple[str, ast.Call]]] = {}
        self._binary: dict[tuple[str, int], set[str]] = {}
        for rel, module in self.modules.items():
            returns = []
            for node in ast.walk(module):
                for child in ast.iter_child_nodes(node):
                    self.parents[id(child)] = node
                if isinstance(node, (ast.Assign, ast.AnnAssign)) and node.value is not None:
                    for target in node.targets if isinstance(node, ast.Assign) else [node.target]:
                        key = target_key(target)
                        if key:
                            self.assigns.setdefault((rel, key), []).append(node.value)
                elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                    self.functions.setdefault(node.name, []).append((rel, node))
                elif isinstance(node, ast.Return) and node.value is not None:
                    returns.append(node)
                elif isinstance(node, ast.Call):
                    name = node.func.attr if isinstance(node.func, ast.Attribute) else getattr(node.func, "id", None)
                    if name:
                        self.calls.setdefault(name, []).append((rel, node))
            # A property or method returning the binary: `self.cli_path` reads its return.
            for ret in returns:
                fn = self.enclosing_function(ret)
                if fn is not None:
                    self.assigns.setdefault((rel, f"self.{fn.name}"), []).append(ret.value)

    def imports_from(self, rel: str, call: ast.Call, stem: str) -> bool:
        """Whether `call` in module `rel` calls into module `stem` (`load.f()` after
        `import stem as load`, or `f()` after `from stem import f`)."""
        if not hasattr(self, "_imports"):
            self._imports: dict[str, dict[str, str]] = {}
            for r, module in self.modules.items():
                names: dict[str, str] = {}
                for node in ast.walk(module):
                    if isinstance(node, ast.Import):
                        for alias in node.names:
                            names[alias.asname or alias.name] = alias.name.rsplit(".", 1)[-1]
                    elif isinstance(node, ast.ImportFrom) and node.module:
                        for alias in node.names:
                            names[alias.asname or alias.name] = node.module.rsplit(".", 1)[-1]
                self._imports[r] = names
        names = self._imports.get(rel, {})
        if isinstance(call.func, ast.Attribute) and isinstance(call.func.value, ast.Name):
            return names.get(call.func.value.id) == stem
        if isinstance(call.func, ast.Name):
            return names.get(call.func.id) == stem
        return False

    def attribute_values(self, attr: str) -> list[tuple[str, ast.AST]]:
        if not hasattr(self, "_by_attr"):
            self._by_attr: dict[str, list[tuple[str, ast.AST]]] = {}
            for (r, key), values in self.assigns.items():
                if key.startswith("self."):
                    self._by_attr.setdefault(key[5:], []).extend((r, v) for v in values)
        return self._by_attr.get(attr, [])

    def enclosing_function(self, node: ast.AST):
        while id(node) in self.parents:
            node = self.parents[id(node)]
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                return node
        return None

    def caller_args(self, rel: str, node: ast.Name, depth: int):
        """The expressions callers pass for parameter `node.id` of the function `node` is in."""
        fn = self.enclosing_function(node)
        if fn is None:
            return
        params = [a.arg for a in fn.args.posonlyargs + fn.args.args]
        if node.id not in params:
            return
        index = params.index(node.id)
        method = bool(params) and params[0] in ("self", "cls")
        stem = Path(rel).stem
        for caller_rel, call in self.calls.get(fn.name, []):
            if caller_rel != rel and not self.imports_from(caller_rel, call, stem):
                continue  # another module's function of the same name
            position = index - (1 if method and isinstance(call.func, ast.Attribute) else 0)
            arg = next((k.value for k in call.keywords if k.arg == node.id), None)
            if arg is None and 0 <= position < len(call.args) and not any(
                    isinstance(a, ast.Starred) for a in call.args[:position + 1]):
                arg = call.args[position]
            if arg is not None:
                yield caller_rel, arg

    def binary(self, rel: str, expr: ast.AST, depth: int = 0) -> set[str]:
        """The CLIs an expression can name: {"acpmux"}, {"cmux"}, or empty when it is no CLI of ours."""
        if depth > 6:
            return set()
        key = (rel, id(expr))
        if key not in self._binary:
            self._binary[key] = set()  # a cycle reads as nothing
            self._binary[key] = self._binary_of(rel, expr, depth)
        return self._binary[key]

    def _binary_of(self, rel: str, expr: ast.AST, depth: int) -> set[str]:
        if isinstance(expr, ast.Constant) and isinstance(expr.value, str):
            kind = path_kind(expr.value)
            return {kind} if kind else set()
        if isinstance(expr, ast.JoinedStr):
            tail = [v.value for v in expr.values if isinstance(v, ast.Constant)]
            kind = path_kind(tail[-1]) if tail and expr.values[-1] is not None and isinstance(expr.values[-1], ast.Constant) else None
            return {kind} if kind else set()
        if isinstance(expr, ast.BinOp) and isinstance(expr.op, ast.Div):
            return self.binary(rel, expr.right, depth + 1)
        if isinstance(expr, ast.Call):
            name = expr.func.attr if isinstance(expr.func, ast.Attribute) else getattr(expr.func, "id", "")
            if "acpmux" in name.lower():
                return {"acpmux"}
            if name in ("join", "Path", "str", "abspath", "realpath", "resolve", "expanduser") and expr.args:
                return self.binary(rel, expr.args[-1], depth + 1)
            if isinstance(expr.func, ast.Attribute) and name == "resolve":
                return self.binary(rel, expr.func.value, depth + 1)
            return set()
        if isinstance(expr, ast.IfExp):
            return self.binary(rel, expr.body, depth + 1) | self.binary(rel, expr.orelse, depth + 1)
        if isinstance(expr, ast.BoolOp):
            return set().union(*(self.binary(rel, v, depth + 1) for v in expr.values))
        if isinstance(expr, (ast.Name, ast.Attribute)):
            text = target_key(expr)
            found: set[str] = set()
            for value in self.assigns.get((rel, text), []) if text else []:
                found |= self.binary(rel, value, depth + 1)
            if isinstance(expr, ast.Name):
                for caller_rel, arg in self.caller_args(rel, expr, depth):
                    found |= self.binary(caller_rel, arg, depth + 1)
            elif not (isinstance(expr.value, ast.Name) and expr.value.id == "self"):
                # `app.cli_path` or `self.app.cli_path`, another class's instance: this module's
                # `self.cli_path`, else every module's when they all name one CLI.
                own = [(rel, v) for v in self.assigns.get((rel, f"self.{expr.attr}"), [])]
                if not own:
                    own = [(r, v) for r, v in self.attribute_values(expr.attr)]
                kinds = [self.binary(r, v, depth + 1) for r, v in own]
                union = set().union(*kinds) if kinds else set()
                if len(union) == 1 or (own and own[0][0] == rel):
                    found |= union
            return found
        return set()

    def prefixes(self, rel: str, expr: ast.AST, depth: int = 0) -> list[tuple[str, list[str | None]]]:
        """The (CLI, words) an argv expression can be."""
        if depth > 6:
            return []
        if isinstance(expr, (ast.List, ast.Tuple)) and expr.elts:
            first, rest = expr.elts[0], expr.elts[1:]
            if isinstance(first, ast.Starred):
                heads = self.prefixes(rel, first.value, depth + 1)
            else:
                heads = [(kind, []) for kind in sorted(self.binary(rel, first, depth))]
            out = []
            for kind, words in heads:
                tail = list(words)
                for elt in rest:
                    if isinstance(elt, ast.Starred):
                        # `[cli, *argv, ...]` with argv one of several forms: the first, the primary one,
                        # must parse; the later ones are fallbacks for older builds.
                        forms = self.word_lists(rel, elt.value, depth + 1)
                        if not forms:
                            tail.append(None)
                            break
                        tail.extend(forms[0])
                        continue
                    tail.append(elt.value if isinstance(elt, ast.Constant) and isinstance(elt.value, str) else None)
                out.append((kind, tail))
            return out
        if isinstance(expr, ast.BinOp) and isinstance(expr.op, ast.Add):
            out = []
            for kind, words in self.prefixes(rel, expr.left, depth + 1):
                right = expr.right
                if isinstance(right, (ast.List, ast.Tuple)):
                    tail = []
                    for elt in right.elts:
                        if isinstance(elt, ast.Starred):
                            tail.append(None)
                            break
                        tail.append(elt.value if isinstance(elt, ast.Constant) and isinstance(elt.value, str) else None)
                    out.append((kind, words + tail))
                else:
                    out.append((kind, words + [None]))
            return out
        if isinstance(expr, ast.Name):
            out = []
            for value in self.assigns.get((rel, expr.id), []):
                if isinstance(value, (ast.List, ast.Tuple, ast.BinOp)):
                    out += self.prefixes(rel, value, depth + 1)
            for caller_rel, arg in self.caller_args(rel, expr, depth):
                out += self.prefixes(caller_rel, arg, depth + 1)
            return out
        return []

    def word_lists(self, rel: str, expr: ast.AST, depth: int) -> list[list[str | None]]:
        """The constant word lists a `*argv` can be, in source order (the first is the primary form):
        argv a loop variable over a list of lists, a variable or attribute set to one, or a call of
        this module's function that appends or returns them (`new_session_argvs`)."""
        if depth > 6:
            return []

        def words(node):
            return [e.value if isinstance(e, ast.Constant) and isinstance(e.value, str) else None for e in node.elts]

        if isinstance(expr, (ast.List, ast.Tuple)):
            if not expr.elts:
                return []
            if all(isinstance(e, (ast.List, ast.Tuple)) for e in expr.elts):
                return [words(e) for e in expr.elts]
            return [words(expr)] if all(isinstance(e, ast.Constant) for e in expr.elts) else []
        if isinstance(expr, ast.BoolOp):
            return [w for v in expr.values for w in self.word_lists(rel, v, depth + 1)]
        if isinstance(expr, ast.Name):
            node = expr
            while id(node) in self.parents:  # a loop variable: `for argv in ITER`
                node = self.parents[id(node)]
                if isinstance(node, ast.For) and isinstance(node.target, ast.Name) and node.target.id == expr.id:
                    return self.word_lists(rel, node.iter, depth + 1)
        key = target_key(expr)
        if key and isinstance(expr, (ast.Name, ast.Attribute)):
            return [w for v in self.assigns.get((rel, key), []) for w in self.word_lists(rel, v, depth + 1)]
        if isinstance(expr, ast.Call):
            name = expr.func.attr if isinstance(expr.func, ast.Attribute) else getattr(expr.func, "id", "")
            found = []
            for fn_rel, fn in self.functions.get(name, []):
                if fn_rel != rel:
                    continue
                for node in sorted((n for n in ast.walk(fn) if isinstance(n, (ast.Call, ast.Return))),
                                   key=lambda n: (n.lineno, n.col_offset)):
                    if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) \
                            and node.func.attr == "append" and node.args \
                            and isinstance(node.args[0], (ast.List, ast.Tuple)):
                        found += self.word_lists(rel, node.args[0], depth + 1)
                    elif isinstance(node, ast.Return) and node.value is not None:
                        found += self.word_lists(rel, node.value, depth + 1)
            return found
        return []

    def launched(self, node: ast.AST) -> bool:
        """Whether a list is the argv of a process launch (`subprocess.run([...])` and the like)."""
        parent = self.parents.get(id(node))
        if not isinstance(parent, ast.Call) or not parent.args or parent.args[0] is not node:
            return False
        name = parent.func.attr if isinstance(parent.func, ast.Attribute) else getattr(parent.func, "id", "")
        return name in LAUNCHERS

    def calls_found(self) -> list[Call]:
        found = []
        for rel, module in self.modules.items():
            for node in ast.walk(module):
                is_list = isinstance(node, (ast.List, ast.Tuple)) and len(node.elts) >= 2
                is_concat = isinstance(node, ast.BinOp) and isinstance(node.op, ast.Add) and isinstance(node.left, ast.Name)
                if not (is_list or is_concat):
                    continue
                if is_list and isinstance(self.parents.get(id(node)), ast.BinOp):
                    continue  # the concatenation it is part of is the call
                if is_list and isinstance(node.elts[0], ast.Constant) and not self.launched(node):
                    continue  # ("acpmux", "cmux-tui", ...): a list of names, not an argv
                for kind, words in self.prefixes(rel, node):
                    if words and any(w is not None for w in words):
                        found.append(Call(rel, node.lineno, kind, words))
        return found


SHELL_OPERATORS = {";", "&&", "||", "|", "&", "(", ")", ";;", "|&", "{", "}", "!", "then", "do", "else", "if", "while", "until"}
SHELL_REDIRECT = re.compile(r"^[<>]|^&>|^>&")


def shell_word(token: str) -> str | None:
    return None if "$" in token or "`" in token else token


def shell_calls(root: Path, path: Path) -> list[Call]:
    """`acpmux ...` and `cmux acp ...` command lines of a shell script: a path to the binary, a
    variable set to one, or a wrapper function (`acp() { "$BIN/acpmux" "$@"; }`)."""
    rel = str(path.relative_to(root))
    text = path.read_text(encoding="utf-8", errors="replace")
    logical, line_of = [], []
    buf, start = "", 1
    for n, line in enumerate(text.splitlines(), 1):
        if not buf:
            start = n
        if line.endswith("\\"):
            buf += line[:-1] + " "
            continue
        logical.append(buf + line)
        line_of.append(start)
        buf = ""
    wrappers: dict[str, tuple[str, list[str | None]]] = {}
    variables: dict[str, str] = {}
    for line in logical:
        m = re.match(r"\s*(?:function\s+)?([\w-]+)\s*\(\)\s*\{\s*(.*?)\s*;?\s*\}\s*$", line)
        if m:
            try:
                body = shlex.split(m.group(2), comments=True)
            except ValueError:
                continue
            if body and body[-1] == "$@" and path_kind(body[0]):
                wrappers[m.group(1)] = (path_kind(body[0]), [shell_word(t) for t in body[1:-1]])
            continue
        m = re.match(r"\s*(?:export\s+|local\s+|readonly\s+)?(\w+)=(\S+)\s*$", line)
        if m and path_kind(m.group(2).strip("\"'")):
            variables[m.group(1)] = path_kind(m.group(2).strip("\"'"))
    calls = []
    for line, n in zip(logical, line_of):
        if re.match(r"\s*(?:function\s+)?[\w-]+\s*\(\)\s*\{", line) or line.lstrip().startswith("#"):
            continue
        lexer = shlex.shlex(line, posix=True, punctuation_chars=";&|()<>")
        lexer.whitespace_split = True
        lexer.commenters = "#"
        try:
            tokens = list(lexer)
        except ValueError:
            continue
        command_start = True
        i = 0
        while i < len(tokens):
            token = tokens[i]
            if token in SHELL_OPERATORS or token.endswith("$"):
                command_start = True
                i += 1
                continue
            if not command_start:
                i += 1
                continue
            command_start = False
            if re.fullmatch(r"\w+=\S*", token):
                command_start = True  # an environment assignment before the command
                i += 1
                continue
            kind, words = None, []
            if token in wrappers:
                kind, words = wrappers[token][0], list(wrappers[token][1])
            elif re.fullmatch(r"\$\{?(\w+)\}?", token) and re.fullmatch(r"\$\{?(\w+)\}?", token).group(1) in variables:
                kind = variables[re.fullmatch(r"\$\{?(\w+)\}?", token).group(1)]
            elif path_kind(token) and ("/" in token or token in ("acpmux",)):
                kind = path_kind(token)
            i += 1
            if kind is None:
                continue
            while i < len(tokens) and tokens[i] not in SHELL_OPERATORS and not SHELL_REDIRECT.match(tokens[i]):
                if i + 1 < len(tokens) and re.fullmatch(r"\d", tokens[i]) and SHELL_REDIRECT.match(tokens[i + 1]):
                    break
                words.append(shell_word(tokens[i]))
                i += 1
            if words:
                calls.append(Call(rel, n, kind, words))
    return calls


def scanned_files(root: Path, suffix: str) -> list[Path]:
    files = sorted((root / SCANNED_TOP).glob(f"*{suffix}"))
    for directory in SCANNED_DIRS:
        files += sorted((root / directory).rglob(f"*{suffix}"))
    # Test files hold fixtures (fake `ps` lines, fake binaries), not commands a script runs.
    return [f for f in files if f.is_file() and "tests" not in f.relative_to(root).parts
            and not f.name.startswith("test_")]


def all_calls(root: Path) -> list[Call]:
    calls = PyScripts(root, scanned_files(root, ".py")).calls_found()
    for path in scanned_files(root, ".sh"):
        calls += shell_calls(root, path)
    return calls


# ------------------------------------------------------------------------------------------------

class GrammarTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.grammar = Grammar(ROOT)
        cls.heads = cmux_scope_heads(ROOT)

    def test_reads_acpmux_grammar(self):
        root = self.grammar.root
        for word in ("new", "run", "exec", "send", "ls", "session", "cancel", "wait"):
            self.assertIn(word, root.subcommands, f"acpmux {word} not read from {ACPMUX_ROOT_FILE}")
        new = root.subcommands["new"]
        for flag in ("detach", "model", "name", "policy", "stall", "cwd"):
            self.assertIn(flag, new.longs, f"acpmux new --{flag} not read")
        self.assertIn("json", root.longs)
        self.assertTrue(root.longs["json"].global_)
        self.assertIn("tail", root.subcommands["session"].subcommands)
        self.assertEqual(self.heads >= {"acp"}, True, f"{CMUX_MAIN} no longer hands `cmux acp` to acpmux")

    def test_refuses_what_clap_refuses(self):
        g, h = self.grammar, self.heads
        self.assertIn("unrecognized subcommand 'acp'", check_call(g, h, "acpmux", ["acp", "new", "--json", "-d", "-m", "x", "hi"]))
        self.assertIn("unexpected argument '--bogus'", check_call(g, h, "acpmux", ["new", "--bogus", "hi"]))
        self.assertIn("unexpected argument '-Q'", check_call(g, h, "acpmux", ["new", "-dQ", "hi"]))
        self.assertIn("unrecognized subcommand 'nope'", check_call(g, h, "cmux", ["acp", "nope"]))
        self.assertIn("unrecognized subcommand 'nope'", check_call(g, h, "acpmux", ["session", "nope", "s"]))

    def test_accepts_what_clap_accepts(self):
        g, h = self.grammar, self.heads
        for kind, words in (
            ("acpmux", ["new", "--json", "-d", "-m", "agent", "turn: 0"]),
            ("acpmux", ["--json", "new", "-d", "-m", "agent", None]),
            ("acpmux", ["send", "--no-wait", None, "stream: 5 2.0"]),
            ("acpmux", ["stop", None]),
            ("acpmux", ["session", "tail", "qp-agent"]),
            ("cmux", ["acp", "new", "--json", "-d", "-m", "agent", "text"]),
            ("cmux", ["--json", "acp", "ls"]),
            ("cmux", ["workspace", "create", "--name", "x"]),
        ):
            self.assertIsNone(check_call(g, h, kind, words), f"{kind} {words}")

    def test_collects_the_primary_form_and_a_misnamed_binary(self):
        import tempfile
        source = (
            "import subprocess\n"
            "def argvs(help_text):\n"
            "    out = []\n"
            "    out.append(['--json', PRIMARY])\n"
            "    out.append(['--json', 'new'])\n"
            "    return out or [['--json', 'new']]\n"
            "class Chats:\n"
            "    def __init__(self, bundle):\n"
            "        self.cli = icl.bundled_acpmux(bundle)\n"
            "        self.forms = argvs('')\n"
            "    def new(self, agent, text):\n"
            "        for argv in self.forms:\n"
            "            subprocess.run([self.cli, *argv, '-d', '-m', agent, text])\n"
            "    def old(self, agent):\n"
            "        subprocess.run([self.cli, 'acp', 'new', '-d', '-m', agent])\n"
        )
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "scripts").mkdir()
            (root / "scripts" / "bench.py").write_text(source.replace("PRIMARY", "'acp', 'new'"), encoding="utf-8")
            calls = PyScripts(root, [root / "scripts" / "bench.py"]).calls_found()
        errors = sorted(check_call(self.grammar, self.heads, c.kind, c.words) or "" for c in calls)
        # The `acp new` primary form and the plain `acp new` call are both refused; the fallback is not read.
        self.assertEqual(sum("unrecognized subcommand 'acp'" in e for e in errors), 2, [c.argv() for c in calls])

    def test_every_bench_call_parses(self):
        calls = all_calls(ROOT)
        refused = []
        for call in calls:
            error = check_call(self.grammar, self.heads, call.kind, call.words)
            if error:
                refused.append(f"{call.file}:{call.line}: {call.argv()}\n    {error}")
        self.assertEqual(refused, [], "scripts run acpmux commands its grammar refuses (acpmux --help, "
                         "cmux acp --help; a binary from bundled_acpmux takes `new`, `cmux` takes `acp new`):\n"
                         + "\n".join(refused))
        for rel, words in KNOWN_CALLS:
            self.assertTrue(
                any(c.file == rel and [w for w in c.words if w is not None][:len(words)] == list(words) for c in calls),
                f"the detector no longer finds `{' '.join(words)}` in {rel}: it went blind, or the call moved")


if __name__ == "__main__":
    unittest.main()
