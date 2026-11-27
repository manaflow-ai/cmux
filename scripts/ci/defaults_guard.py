#!/usr/bin/env python3
"""The defaults snapshot and the settings exports' source stamp.

A default is what someone gets without configuring anything: an action's
default keys, a setting's default value, a Debug Tunable's `default:`, a
Ghostty keybind cmux writes (an unbind takes a chord from Ghostty), a feature
flag compiled on or off.

schemas/defaults/<app>.json is the golden snapshot of every default, made from
the sources of truth with no hand list:
- cmux NEXT: plans/cmux-next/action-surfaces.json (each action's default
  shortcut, chord and aliases, exported from the catalog by Swift) and
  schemas/settings/settings-schema.json (each setting's default), both kept
  current by the generated-files check; the Ghostty `keybind = ...` lines, the
  `static let ...Enabled = true|false` flags and each
  `Tunable<T>.choice|toggle|number|color|spring("key", ..., default: ...)` in
  the app's Swift sources. Tunable initializers/helpers and their symbolic source
  dependencies also have conservative declaration fingerprints (not whole-file hashes),
  so helper, interpolated-key and nonliteral defaults cannot silently stay unchanged
  when their defining declaration changes; comments and formatting do not count.
The snapshot is bot-only (#21946): the base autofix rewrites it after a merge and
no pull request commits it. cmux-tui reads it (cmux-action-catalog's
customize_elements.rs).

  python3 scripts/ci/defaults_guard.py snapshot           # regenerate it
  python3 scripts/ci/defaults_guard.py check-fresh        # it matches the sources

The settings exports' source stamp is derived, never committed (Leo 2026-10-21):
`source-stamp [--ref REF]` prints one `sha256  path` entry per CmuxNextSettings
source and export test at REF, a blank line apart. Base autofix compares the
stamp of the commit its exports were made at with the tip's: equal means the
exports' inputs did not move. A committed copy changed in every pull request that
touched a settings source and conflicted on nearly every base move (#22674); the
exports themselves are checked against a fresh Swift export (the generated files
job of cmux-next.yml).

Trees are read with git as data (or from a checkout, refusing links); nothing in
them runs. The file keeps its name, from when it also judged a pull request's
default changes (that check was deleted, Leo 2026-11-25), because many scripts
and workflows call it by path.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from collections.abc import Iterable, Mapping
from dataclasses import dataclass
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parents[2]
APP = "cmux-next"
SNAPSHOT = f"schemas/defaults/{APP}.json"
ACTION_SURFACES = "plans/cmux-next/action-surfaces.json"
SETTINGS_SCHEMA = "schemas/settings/settings-schema.json"
SWIFT_SOURCES = "Packages/macOS/CmuxNext/Sources"
# The settings exporter's inputs, which the source stamp hashes.
SETTINGS_SOURCE_DIR = "Packages/macOS/CmuxNext/Sources/CmuxNextSettings"
SETTINGS_SOURCE_SUFFIXES = (".swift", ".xcstrings")
SETTINGS_GENERATOR_INPUTS = ("schemas/settings/source", "schemas/settings/generator",
                             "schemas/settings/retired-keys.json", "scripts/cmux-next/gen-settings-sources.py")
SETTINGS_EXPORTER_FILES = (
    "Packages/macOS/CmuxNext/Tests/CmuxNextSettingsTests/ManagedPreferencesManifestTests.swift",
    "Packages/macOS/CmuxNext/Tests/CmuxNextSettingsTests/SettingsSchemaExportTests.swift",
)
# Default bindings that step aside in a context (a code editor, a focused terminal): a change to
# one changes what a key does there. The lists are catalog data in Rust since step B of the action
# catalog's move (`pub static YIELDS_TO_CODE_EDITOR: &[&str] = &[...]`, read as `yieldsToCodeEditor`);
# a tree from before it has them in Swift (`static let yieldsToCodeEditor: Set<ActionID> = [...]`).
KEY_BINDING_DEFAULTS = "Packages/macOS/CmuxNext/Sources/CmuxNextActions/KeyBindingDefaults.swift"
RUST_KEY_BINDING_DEFAULTS = "cmux-tui/crates/cmux-action-catalog/src/bindings.rs"
REGENERATE = "python3 scripts/ci/defaults_guard.py snapshot"

# AppKit's function-key characters, as the catalog export writes them.
FUNCTION_KEYS = {
    0xF700: "up", 0xF701: "down", 0xF702: "left", 0xF703: "right",
    0xF728: "forwarddelete", 0xF729: "home", 0xF72B: "end",
    0xF72C: "pageup", 0xF72D: "pagedown",
}
NAMED_KEYS = {"\t": "tab", "\r": "return", "\n": "return", " ": "space", "\x1b": "escape", "\x7f": "delete", "\x08": "delete"}
MODIFIER_ORDER = ("ctrl", "opt", "shift", "cmd")

KEYBIND_RE = re.compile(r'"keybind\s*=\s*([^"=]+?)\s*=\s*([^"]*)"')
YIELDS_RE = re.compile(r"static\s+let\s+(yieldsTo\w+)\s*:\s*Set<ActionID>\s*=\s*\[(.*?)\]", re.S)
RUST_YIELDS_RE = re.compile(r"pub\s+static\s+(YIELDS_TO_\w+)\s*:\s*&\[&str\]\s*=\s*&\[(.*?)\];", re.S)
FLAG_RE = re.compile(r"\bstatic\s+(?:let|var)\s+(\w*Enabled)\s*(?::\s*Bool\s*)?=\s*(true|false)\b")
# A Debug Tunable with a constant default. The call parser below handles commas and
# parentheses in nested arguments and string literals; interpolated keys are skipped.
TUNABLE_RE = re.compile(r'\bTunable<[\w.?]+>\s*\.(choice|toggle|number|color|spring)\(\s*"([^"\\]+)"')


# MARK: Reading a tree


class Tree:
    """Files of one commit (git, read as data) or of a directory (a checkout of one)."""

    @staticmethod
    def named(value: str) -> "Tree":
        """A directory when `value` is one, else a git commit of this repository."""
        path = Path(value)
        return Tree(None, path.resolve()) if path.is_dir() else Tree(value)

    def __init__(self, ref: str | None, root: Path = ROOT) -> None:
        self.ref = ref
        self.root = root

    def read(self, path: str) -> str | None:
        if self.ref is None:
            file = self.root / path
            self.refuse_links(file)
            return file.read_text(encoding="utf-8") if file.is_file() else None
        result = subprocess.run(["git", "-C", str(self.root), "show", f"{self.ref}:{path}"],
                                capture_output=True, text=True)
        return result.stdout if result.returncode == 0 else None

    def read_bytes(self, paths: list[str]) -> dict[str, bytes]:
        """The exact bytes of each file (a link is refused; a missing file raises)."""
        if self.ref is None:
            found = {}
            for path in paths:
                file = self.root / path
                self.refuse_links(file)
                if not file.is_file():
                    raise SystemExit(f"DEFAULTS tree: {path} is missing")
                found[path] = file.read_bytes()
            return found
        listing = self.blobs(paths)
        missing = [path for path in paths if path not in listing]
        if missing:
            raise SystemExit(f"DEFAULTS tree: {', '.join(missing)} is not in {self.ref}")
        request = "".join(f"{listing[path]}\n" for path in paths).encode()
        result = subprocess.run(["git", "-C", str(self.root), "cat-file", "--batch"],
                                input=request, capture_output=True, check=True)
        found, out, offset = {}, result.stdout, 0
        for path in paths:
            header_end = out.index(b"\n", offset)
            header = out[offset:header_end].split()
            if len(header) != 3 or header[1] != b"blob":
                raise SystemExit(f"DEFAULTS tree: {path} is not readable in {self.ref} ({header!r})")
            size = int(header[2])
            found[path] = out[header_end + 1:header_end + 1 + size]
            offset = header_end + 1 + size + 1
        return found

    def blobs(self, paths: Iterable[str]) -> dict[str, str]:
        """Object id of every blob at or under `paths` in the commit (a link is refused)."""
        result = subprocess.run(["git", "-C", str(self.root), "ls-tree", "-r", "-z", "--full-tree", self.ref, "--", *paths],
                                capture_output=True, check=True)
        listing = {}
        for entry in result.stdout.split(b"\0"):
            if not entry:
                continue
            meta, _, name = entry.partition(b"\t")
            mode, kind, oid = meta.decode().split()
            path = name.decode("utf-8")
            if mode == "120000":
                raise SystemExit(f"DEFAULTS tree: {path} is a symbolic link; this tool reads no links")
            if kind == "blob":
                listing[path] = oid
        return listing

    def files(self, path: str) -> list[str]:
        """Repository-relative paths of the regular files under `path` (a link is refused)."""
        if self.ref is not None:
            return sorted(self.blobs([path]))
        top = self.root / path
        if not top.exists():
            return []
        self.refuse_links(top)
        found = []
        for file in top.rglob("*"):
            self.refuse_links(file)
            if file.is_file():
                found.append(file.relative_to(self.root).as_posix())
        return found

    def refuse_links(self, file: Path) -> None:
        """A checked-out head is data: a link in it could read the runner's own files."""
        part = file
        while part != self.root and self.root in part.parents:
            if part.is_symlink():
                raise SystemExit(f"DEFAULTS tree: {part.relative_to(self.root)} is a symbolic link; this tool reads no links")
            part = part.parent

    def grep(self, pattern: str, path: str) -> list[tuple[str, str]]:
        """(file, line) for every line under `path` matching the extended regex `pattern`."""
        if self.ref is None:
            if not (self.root / path).exists():
                return []
            self.refuse_links(self.root / path)
            for found in (self.root / path).rglob("*"):
                self.refuse_links(found)
            args = ["git", "-C", str(self.root), "grep", "--no-index", "-I", "-E", "-e", pattern, "--", path]
        else:
            args = ["git", "-C", str(self.root), "grep", "-I", "-E", "-e", pattern, self.ref, "--", path]
        result = subprocess.run(args, capture_output=True, text=True)
        if result.returncode not in (0, 1):
            raise SystemExit(f"git grep failed: {result.stderr.strip()}")
        prefix = f"{self.ref}:" if self.ref else ""
        lines = []
        for raw in result.stdout.splitlines():
            raw = raw.removeprefix(prefix)
            name, _, line = raw.partition(":")
            lines.append((name, line))
        return lines


# MARK: The defaults


def key_name(key: str) -> str:
    if len(key) == 1 and ord(key) in FUNCTION_KEYS:
        return FUNCTION_KEYS[ord(key)]
    if len(key) == 1 and 0xF704 <= ord(key) <= 0xF726:
        return f"f{ord(key) - 0xF703}"
    if key in NAMED_KEYS:
        return NAMED_KEYS[key]
    if len(key) == 1 and not key.isprintable():
        return f"U+{ord(key):04X}"
    return key.lower()


def stroke(value: Mapping[str, object]) -> str:
    modifiers = [str(m) for m in value.get("modifiers") or []]
    ordered = [m for m in MODIFIER_ORDER if m in modifiers] + sorted(m for m in modifiers if m not in MODIFIER_ORDER)
    return "+".join([*ordered, key_name(str(value.get("key", "")))])


def binding(keys: Iterable[Mapping[str, object]], when: object = None) -> str:
    text = " ".join(stroke(k) for k in keys)
    return f"{text} when {when}" if when else text


def action_keys(action: Mapping[str, object]) -> list[str]:
    keys: set[str] = set()
    shortcut = action.get("default_shortcut")
    if isinstance(shortcut, dict):
        keys.add(binding([shortcut]))
    chord = action.get("default_chord")
    if isinstance(chord, dict):
        keys.add(binding(chord.get("keys") or [chord]))
    elif isinstance(chord, list):
        keys.add(binding(chord))
    for alias in action.get("default_aliases") or []:
        if isinstance(alias, dict):
            keys.add(binding(alias.get("keys") or [], alias.get("when")))
    return sorted(keys)


def defaults(tree: Tree) -> dict[str, object]:
    """Every default of the app in `tree`, by stable id."""
    found: dict[str, object] = {}
    surfaces = tree.read(ACTION_SURFACES)
    if surfaces is None:
        raise SystemExit(f"{ACTION_SURFACES} is missing")
    for action in json.loads(surfaces)["actions"]:
        keys = action_keys(action)
        if keys:
            found[f"key.{action['id']}"] = keys
    schema = tree.read(SETTINGS_SCHEMA)
    if schema is None:
        raise SystemExit(f"{SETTINGS_SCHEMA} is missing")
    for row in json.loads(schema)["rows"]:
        found[f"setting.{row['key']}"] = row.get("default")
    for _, line in tree.grep(r'"keybind *= *[^"]+=', SWIFT_SOURCES):
        for trigger, action in KEYBIND_RE.findall(line):
            # An interpolated line (`\(trigger)`) is built at run time from the user's config, not a default.
            if "\\(" not in trigger + action:
                found[f"ghostty.{trigger.strip()}"] = action.strip()
    for name, block in YIELDS_RE.findall(tree.read(KEY_BINDING_DEFAULTS) or ""):
        found[f"steps-aside.{name}"] = sorted(re.findall(r'"([^"]+)"', block))
    for name, block in RUST_YIELDS_RE.findall(tree.read(RUST_KEY_BINDING_DEFAULTS) or ""):
        # YIELDS_TO_CODE_EDITOR -> yieldsToCodeEditor, the name the Swift list had.
        first, *rest = name.lower().split("_")
        found[f"steps-aside.{first}{''.join(word.title() for word in rest)}"] = sorted(re.findall(r'"([^"]+)"', block))
    sources = sorted(name for name in tree.files(SWIFT_SOURCES) if name.endswith(".swift"))
    swift = {name: text.decode("utf-8") for name, text in tree.read_bytes(sources).items()}
    found.update(tunable_source_defaults(swift))
    for text in swift.values():
        for key, value in tunables(text):
            found[f"tunable.{key}"] = value
    for name, line in tree.grep(r"static +(let|var) +[A-Za-z0-9_]*Enabled *(: *Bool *)?= *(true|false)", SWIFT_SOURCES):
        for flag, value in FLAG_RE.findall(line):
            # The file's path under the sources keeps two `isEnabled` flags apart; a second one in
            # the same file gets a number, in file order.
            base = f"flag.{name.removeprefix(SWIFT_SOURCES + '/').removesuffix('.swift')}.{flag}"
            key, n = base, 2
            while key in found:
                key, n = f"{base}#{n}", n + 1
            found[key] = value == "true"
    return dict(sorted(found.items()))


def call_arguments(text: str, start: int) -> list[str]:
    """Return top-level arguments in a Swift call whose arguments start at ``start``."""
    args, depth, current, i = [], 0, [], start
    while i < len(text):
        char = text[i]
        if char == '"':
            end = i + 1
            while end < len(text) and text[end] not in '"\n':
                end += 2 if text[end] == "\\" else 1
            current.append(text[i:end + 1])
            i = end + 1
            continue
        if char in "([{":
            depth += 1
        elif char in ")]}":
            if depth == 0:
                break
            depth -= 1
        elif char == "," and depth == 0:
            args.append("".join(current))
            current = []
            i += 1
            continue
        current.append(char)
        i += 1
    return [argument.strip() for argument in [*args, "".join(current)]]


def strip_swift_comments(text: str) -> str:
    """Replace Swift comments with spaces while preserving literals and newlines.

    This tool reads source as data, so it must not treat an example in a comment as a
    live Tunable. Keeping string bytes and line breaks intact also means a quoted default retains
    its exact contents when it is reported.
    """
    output, i, block_depth = [], 0, 0
    while i < len(text):
        if block_depth:
            if text.startswith("/*", i):
                block_depth += 1
                output.extend("  ")
                i += 2
            elif text.startswith("*/", i):
                block_depth -= 1
                output.extend("  ")
                i += 2
            else:
                output.append("\n" if text[i] == "\n" else " ")
                i += 1
            continue
        if text.startswith("//", i):
            output.extend("  ")
            i += 2
            while i < len(text) and text[i] != "\n":
                output.append(" ")
                i += 1
            continue
        if text.startswith("/*", i):
            block_depth = 1
            output.extend("  ")
            i += 2
            continue
        if text[i] == '"':
            end = i + 1
            while end < len(text):
                if text[end] == "\\":
                    end += 2
                elif text[end] == '"':
                    end += 1
                    break
                else:
                    end += 1
            output.append(text[i:end])
            i = end
            continue
        output.append(text[i])
        i += 1
    return "".join(output)


# Source fingerprints complement the readable literal values. Swift defaults may be built by a
# helper or depend on other declarations; reading an unchanged expression is not its value.
# Track those declarations and their dependencies instead of evaluating untrusted Swift.
SWIFT_TOKEN = re.compile(r'"(?:\\.|[^"\\])*"|[A-Za-z_]\w*|[^\s]', re.S)
STATIC_DECL = re.compile(r"\bstatic\s+(let|var|func)\s+(`?\w+`?)")


def static_declarations(text: str) -> list[tuple[str, str, list[str]]]:
    """Static initializer/function tokens; comments and formatting do not change a stamp."""
    text = strip_swift_comments(text)
    found = []
    # A help string may contain a Swift example; only actual declarations count.
    syntax = SWIFT_TOKEN.sub(lambda match: " " * len(match.group())
                             if match.group().startswith('"') else match.group(), text)
    for match in STATIC_DECL.finditer(syntax):
        kind, name = match.groups()
        name = name.strip("`")
        tokens = [kind, name]
        depth, started, previous_end = 0, False, match.end()
        for token in SWIFT_TOKEN.finditer(text, match.end()):
            value = token.group()
            gap = text[previous_end:token.start()]
            if depth == 0 and started:
                if value in ("}", ";"):
                    break
                if "\n" in gap and tokens[-1] not in ("=", ",", ".", ":", "+", "-", "*", "/", "%", "&", "|", "?", "??") and value not in (".", "{", "(", "+", "-", "*", "/", "%", "&", "|", "?", "=", "<", ">", "!"):
                    break
            if value in ("(", "[", "{"):
                depth += 1
            elif value in (")", "]", "}"):
                if depth == 0:
                    break
                depth -= 1
            if value == "=" or (value == "{" and kind in ("func", "var")):
                started = True
            tokens.append(value)
            previous_end = token.end()
        if started:
            found.append((kind, name, tokens))
    return found


TUNABLE_TYPE = re.compile(r"(?:Derived)?Tunable|\w+Tunable")
TYPEALIAS = re.compile(r"\btypealias\s+(\w+)(?:<[^=\n]*>)?\s*=\s*([^\n;]+)")
# `struct S: P, Q {`, `final class Sub: Base {`, `extension T: P where ... {`: the names after the colon.
TYPE_INHERITANCE = re.compile(r"\b(?:enum|struct|class|extension|protocol)\s+[\w.]+(?:<[^>{]*>)?\s*:\s*([^{]+)\{")


def calls_helper(path: str, tokens: list[str], helper_files: Mapping[str, set[str]],
                 types: Mapping[str, set[str]], file_types: Mapping[str, set[str]],
                 inherits: Mapping[str, set[str]]) -> bool:
    """Whether a declaration's tokens (after its kind and name) call a Tunable helper it can reach: the caller's
    types (those its file declares, plus the superclasses and protocols they name) meet a type the helper's file
    declares. Only the caller's side takes inheritance: a subclass reaches its base's helper and a conforming type
    a protocol extension's, but a helper file conforming to Sendable reaches no other Sendable type."""
    for i in range(2, len(tokens)):
        files = helper_files.get(tokens[i])
        if not files:
            continue
        reach = file_types.get(path, set()) | inherits.get(path, set())  # bare `helper` or `Self.helper`
        if tokens[i - 1] == ".":
            owner = tokens[i - 2] if i >= 3 else ""
            if owner != "Self":
                if owner not in types:
                    continue  # x.helper or .helper: some other member that shares the name
                reach = {owner}.union(*(inherits.get(file, set()) for file in types[owner]))  # Type.helper
        if any(reach & file_types.get(file, set()) for file in files):
            return True
    return False


def tunable_source_defaults(sources: Mapping[str, str]) -> dict[str, object]:
    """Fingerprint tunable initializers, their helpers and symbolic source dependencies.

    This is conservative source tracking, not a Swift interpreter: editing a selected declaration's
    help text or implementation also changes the snapshot. Unrelated declarations in its file do not.
    Same-file names and qualified Type.member references resolve to all possible source declarations
    (including extensions); ambiguity adds evidence rather than silently choosing one definition.
    A typealias of a Tunable counts as a Tunable token; a Tunable helper is matched by the call that can
    reach it (calls_helper), never by a token that only shares its name.
    """
    nodes, by_file_name, types = {}, {}, {}
    aliases: dict[str, list[str]] = {}  # typealias name -> the names on its right-hand side
    inherits: dict[str, set[str]] = {}  # file -> the superclasses and protocols its types name
    for path, text in sources.items():
        code = strip_swift_comments(text)
        for type_name in re.findall(r"\b(?:enum|struct|class|extension|protocol)\s+(?!(?:func|var|let|subscript|init)\b)(\w+)", code):
            types.setdefault(type_name, set()).add(path)
        for clause in TYPE_INHERITANCE.findall(code):
            inherits.setdefault(path, set()).update(re.findall(r"\w+", clause.split(" where ")[0]))
        for alias, target in TYPEALIAS.findall(code):
            aliases.setdefault(alias, []).extend(re.findall(r"\w+", target))
        for kind, name, tokens in static_declarations(text):
            key = f"tunable-source.{path.removeprefix(SWIFT_SOURCES + '/')}:{name}"
            while key in nodes:
                key += "#"
            nodes[key] = (path, kind, name, tokens)
            by_file_name.setdefault((path, name), set()).add(key)
    # A typealias of a Tunable (`typealias TD = Tunable<Double>`, or an alias of such an alias) is a Tunable token.
    tunable_names = {name for name, target in aliases.items() if any(TUNABLE_TYPE.fullmatch(t) for t in target)}
    while grown := {name for name, target in aliases.items() if name not in tunable_names and set(target) & tunable_names}:
        tunable_names |= grown
    selected = {key for key, (_, _, _, tokens) in nodes.items()
                if any(TUNABLE_TYPE.fullmatch(token) or token in tunable_names for token in tokens)}
    # A helper returning Tunable (e.g. points) has callers whose initializer has no Tunable token. A call is
    # matched to the helper it can reach: a bare `helper` or `Self.helper` in a file whose types share one with
    # the helper's file, or `Type.helper` where Type's files do. A file's types are the types and extensions it
    # declares plus the superclasses and protocols they name, so a subclass reaches its base's helper and a
    # conforming type a protocol extension's. A token that only shares the name (`model.toggle()`, a closure
    # named `make`, `JSONValue.number`) is not a call of it: that matched every `static func bind` in the app
    # (#32983, #32979). Not resolved (the reader before #33161 caught them by name; no Tunable helper in the tree
    # is called this way, 2026-11-03; a Tunable that uses one changes its default without a snapshot change):
    # - a conformance or superclass declared in another file than the caller (`extension C: HasPoints {}`
    #   elsewhere, or `extension Sub` in another file than `class Sub: Base`): inheritance is read per file
    # - inheritance more than one level deep (`Leaf: Mid`, `Mid: Base`; `protocol Q: HasPoints`)
    # - a nested generic clause before the colon (`struct G<T: Collection<Int>>: HasPoints`)
    # - a typealias of the helper's type (`typealias CT = ChromeTunables`, then `CT.points`), or a local
    #   `let T = ChromeTunables.self`
    # - a helper reached through a generic parameter (`T.points`)
    # A `class func` helper is no node at all (static_declarations reads `static` only).
    helper_files: dict[str, set[str]] = {}
    for key, (path, kind, name, _) in nodes.items():
        if key in selected and kind == "func":
            helper_files.setdefault(name, set()).add(path)
    file_types: dict[str, set[str]] = {}
    for type_name, paths in types.items():
        for path in paths:
            file_types.setdefault(path, set()).add(type_name)
    for key, (path, _, _, tokens) in nodes.items():
        if key not in selected and calls_helper(path, tokens, helper_files, types, file_types, inherits):
            selected.add(key)
    pending = list(selected)
    while pending:
        key = pending.pop()
        path, _, _, tokens = nodes[key]
        dependencies = set()
        for i, token in enumerate(tokens):
            dependencies.update(by_file_name.get((path, token), ()))
            if i + 2 < len(tokens) and tokens[i + 1] == ".":
                for owner in types.get(token, ()):
                    dependencies.update(by_file_name.get((owner, tokens[i + 2]), ()))
        for dependency in dependencies - selected:
            selected.add(dependency)
            pending.append(dependency)
    return {key: hashlib.sha256(json.dumps(nodes[key][3], ensure_ascii=False).encode()).hexdigest()
            for key in sorted(selected)}


def tunables(text: str) -> list[tuple[str, object]]:
    """Return (key, default) for Tunables with a literal default value."""
    text = strip_swift_comments(text)
    found = []
    for match in TUNABLE_RE.finditer(text):
        kind, key = match.groups()
        value = next((argument.partition(":")[2].strip()
                      for argument in call_arguments(text, match.end())
                      if re.match(r"^default\s*:", argument)), None)
        if value is None:
            continue
        if kind == "toggle" and value in ("true", "false"):
            found.append((key, value == "true"))
            continue
        if value.startswith('"') and value.endswith('"'):
            try:
                found.append((key, json.loads(value)))
                continue
            except json.JSONDecodeError:
                pass
        if re.fullmatch(r"\.[A-Za-z_]\w*", value):
            found.append((key, value[1:]))
        elif re.fullmatch(r"-?\d+(?:\.\d+)?", value):
            found.append((key, float(value)))
        # Nonliteral defaults are covered by tunable-source dependency fingerprints above.
        # Never present an expression such as devDefault as though it were the default value.
    return found


def render_snapshot(values: Mapping[str, object]) -> str:
    lines = [f"    {json.dumps(key)}: {json.dumps(value, ensure_ascii=False, sort_keys=True)}" for key, value in values.items()]
    header = {"app": APP, "regenerate": REGENERATE, "version": 1}
    head = ",\n".join(f"  {json.dumps(k)}: {json.dumps(v)}" for k, v in header.items())
    return "{\n" + head + ',\n  "defaults": {\n' + ",\n".join(lines) + "\n  }\n}\n"


def snapshot_of(tree: Tree) -> dict[str, object] | None:
    text = tree.read(SNAPSHOT)
    return None if text is None else dict(json.loads(text)["defaults"])


# MARK: Changes


def plain(text: str) -> str:
    """Text from the head on one line: a newline cannot start a workflow command or a Markdown block."""
    return text.replace("\r", "\\r").replace("\n", "\\n")


@dataclass(frozen=True)
class Change:
    id: str
    old: object
    new: object

    @staticmethod
    def show(value: object) -> str:
        if value is None:
            return "(none)"
        if isinstance(value, list):
            return ", ".join(str(v) for v in value) if value else "(none)"
        return json.dumps(value, ensure_ascii=False)

    @property
    def detail(self) -> str:
        if isinstance(self.old, list) or isinstance(self.new, list):
            old = set(self.old if isinstance(self.old, list) else [])
            new = set(self.new if isinstance(self.new, list) else [])
            parts = [f"+ {k}" for k in sorted(new - old)] + [f"- {k}" for k in sorted(old - new)]
            return "; ".join(parts)
        return f"{self.show(self.old)} -> {self.show(self.new)}"

    @property
    def line(self) -> str:
        return plain(f"DEFAULTS {self.id}: {self.detail}")


def changes(old: Mapping[str, object], new: Mapping[str, object]) -> list[Change]:
    found = []
    for key in sorted(set(old) | set(new)):
        if old.get(key) != new.get(key) or (key in old) != (key in new):
            found.append(Change(key, old.get(key), new.get(key)))
    return found


# MARK: Commands


def command_snapshot(args: argparse.Namespace) -> int:
    path = ROOT / SNAPSHOT
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(render_snapshot(defaults(Tree(None))), encoding="utf-8")
    print(f"wrote {SNAPSHOT}")
    return 0


def freshness(tree: Tree) -> list[str]:
    """Problems with the committed snapshot of `tree` (empty when it matches the sources)."""
    committed = tree.read(SNAPSHOT)
    if committed is None:
        return [f"DEFAULTS snapshot: {SNAPSHOT} is missing; run `{REGENERATE}`"]
    if committed != render_snapshot(defaults(tree)):
        stale = changes(dict(json.loads(committed)["defaults"]), defaults(tree))
        return [f"DEFAULTS snapshot: {SNAPSHOT} does not match the sources; run `{REGENERATE}` and commit it"] + \
            [f"  {c.line}" for c in stale]
    return []


def settings_source_stamp(tree: Tree) -> str:
    """The settings exports' source stamp: one `sha256  path` entry per exporter input
    (lowercase hex of the file's bytes, two spaces, the repository-relative path) in UTF-8 path
    order, with a blank line between entries and a newline at the end. It is derived for a
    commit, never committed."""
    paths = list(SETTINGS_EXPORTER_FILES) + [
        path for path in tree.files(SETTINGS_SOURCE_DIR) if PurePosixPath(path).suffix in SETTINGS_SOURCE_SUFFIXES] + [
        # The settings Swift the build generates (SettingsSchemaPlugin, RFD 0048) is not in git: its inputs.
        path for top in SETTINGS_GENERATOR_INPUTS for path in tree.files(top)]
    paths.sort(key=lambda path: path.encode("utf-8"))
    contents = tree.read_bytes(paths)
    return "\n\n".join(f"{hashlib.sha256(contents[path]).hexdigest()}  {path}" for path in paths) + "\n"


def command_check_fresh(args: argparse.Namespace) -> int:
    tree = Tree.named(args.ref) if args.ref else Tree(None)
    problems = freshness(tree)
    for problem in problems:
        print(problem)
    return 1 if problems else 0


def command_source_stamp(args: argparse.Namespace) -> int:
    """The stamp the settings sources of a commit give. Base autofix compares the stamp of the commit
    its exports were made at with the tip's: equal means the exports' inputs did not move."""
    sys.stdout.write(settings_source_stamp(Tree.named(args.ref) if args.ref else Tree(None)))
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("snapshot", help="regenerate the golden snapshot from the sources").set_defaults(run=command_snapshot)
    fresh = sub.add_parser("check-fresh", help="the committed snapshot matches the sources")
    fresh.add_argument("--ref", help="a commit to check instead of the working tree")
    fresh.set_defaults(run=command_check_fresh)
    source = sub.add_parser("source-stamp", help="print the settings export stamp the CmuxNextSettings sources give")
    source.add_argument("--ref", help="a commit to read instead of the working tree")
    source.set_defaults(run=command_source_stamp)
    args = parser.parse_args(argv)
    return args.run(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
