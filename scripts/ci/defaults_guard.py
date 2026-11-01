#!/usr/bin/env python3
"""Guard against unannounced default changes (Leo 2026-10-13).

A default is what someone gets without configuring anything: an action's
default keys, a setting's default value, a Debug Tunable's `default:`, a
Ghostty keybind cmux writes (an unbind takes a chord from Ghostty), a feature
flag compiled on or off. Changing one changes what everyone gets, so it needs
a call.

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
  so helper, interpolated-key and nonliteral defaults cannot silently remain unchanged
  when their defining declaration changes. An edit to a tracked declaration's help text
  also needs review; comments and formatting do not.

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
  python3 scripts/ci/defaults_guard.py check --base B --head H [--pr N --repo R]

`check` compares the defaults at the merge base with the ones at the head, each
computed from that tree's exports and sources (the trees are read with git as
data; nothing from the head runs). The snapshot is bot-only (#21946): the base
autofix rewrites it after a merge, no pull request commits it, and `check`
never reads it, so a hand-edited copy hides nothing.

A setting the pull request adds whose default is off (false, null, "off",
"never", "none", "disabled" or empty) keeps the behavior from before it
existed (new things ship off), so it passes on its own (Leo 2026-10-21); it
stays listed. Any other change passes with an independent review receipt on
the head: a comment or review whose first line is
`Review (<reviewer>): SHIP at <full head sha>` from a member (OWNER, MEMBER or
COLLABORATOR, a user, not a bot), not a self-review, the grammar
scripts/ci/risk_tier.py reads. The newest verdict naming the head decides, so
a later BLOCK beats an earlier SHIP, and a push needs a new receipt. The
workflow's token cannot see a private org membership (GitHub reports such a
member as CONTRIBUTOR to it), so a receipt's author who reads as untrusted is
looked up once: write, maintain or admin access to the repository trusts them
too. An approving review of the head from a call owner in
.github/defaults-call-owners.json other than the author still passes too. The
`needs a call` label alone never passes. The workflow (pull_request_target
only) runs this script and reads the owners file from the base branch, so a
pull request cannot approve itself by editing either.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import time
from collections.abc import Callable, Iterable, Mapping
from dataclasses import dataclass, field
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parents[2]
APP = "cmux-next"
SNAPSHOT = f"schemas/defaults/{APP}.json"
OWNERS = ".github/defaults-call-owners.json"
ACTION_SURFACES = "plans/cmux-next/action-surfaces.json"
SETTINGS_SCHEMA = "schemas/settings/settings-schema.json"
SWIFT_SOURCES = "Packages/macOS/CmuxNext/Sources"
# The settings exporter's inputs, which the source stamp hashes.
SETTINGS_SOURCE_DIR = "Packages/macOS/CmuxNext/Sources/CmuxNextSettings"
SETTINGS_SOURCE_SUFFIXES = (".swift", ".xcstrings")
SETTINGS_EXPORTER_FILES = (
    "Packages/macOS/CmuxNext/Tests/CmuxNextSettingsTests/ManagedPreferencesManifestTests.swift",
    "Packages/macOS/CmuxNext/Tests/CmuxNextSettingsTests/SettingsSchemaExportTests.swift",
)
# Default bindings that step aside in a context (a code editor, a focused terminal): a change to
# one changes what a key does there.
KEY_BINDING_DEFAULTS = "Packages/macOS/CmuxNext/Sources/CmuxNextActions/KeyBindingDefaults.swift"
MARKER = "<!-- cmux:defaults-guard -->"
REGENERATE = "python3 scripts/ci/defaults_guard.py snapshot"
# The guard's own files: changing how defaults are read or who approves is a call too.
GUARD_FILES = (
    "scripts/ci/defaults_guard.py",
    OWNERS,
)

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
FLAG_RE = re.compile(r"\bstatic\s+(?:let|var)\s+(\w*Enabled)\s*(?::\s*Bool\s*)?=\s*(true|false)\b")
# A Debug Tunable with a constant default. The call parser below handles commas and
# parentheses in nested arguments and string literals; interpolated keys are skipped.
TUNABLE_RE = re.compile(r'\bTunable<[\w.?]+>\s*\.(choice|toggle|number|color|spring)\(\s*"([^"\\]+)"')
# An independent review's verdict on the exact head, on a comment's or review's first line:
# "Review (subagent, correctness first): SHIP at <full head sha>". Same grammar as
# scripts/ci/risk_tier.py RECEIPT (and next_autoland, merge_audit).
RECEIPT = re.compile(r"^\W*(?:independent\s+)?review\s*\(([^)\n]*)\)\s*:\W*(ship|block|fix|not ship|hold)(?![\w-])",
                     re.I)
TRUSTED = ("OWNER", "MEMBER", "COLLABORATOR")
# Repository roles that trust a receipt's author whose association reads as untrusted: a member who
# keeps the org membership private is CONTRIBUTOR to the workflow's token (#26153).
WRITER_ROLES = ("admin", "maintain", "write")
# GitHub returns the App slug as `cmux-bot` in some GraphQL connections and the
# REST-normalized `cmux-bot[bot]` form in others. Both are the same actor only
# when paired with this immutable node id; a name alone is never sufficient.
CMUX_BOT_LOGINS = frozenset(("cmux-bot", "cmux-bot[bot]"))
CMUX_BOT_NODE_ID = "BOT_kgDOFMYsLQ"
# Default values that read as "off": a new setting with one of them changes nothing for anyone.
OFF_WORDS = ("off", "never", "none", "disabled", "")


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
                raise SystemExit(f"DEFAULTS tree: {path} is a symbolic link; the defaults guard reads no links")
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
                raise SystemExit(f"DEFAULTS tree: {part.relative_to(self.root)} is a symbolic link; the defaults guard reads no links")
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

    The defaults guard reads source as data, so it must not treat an example in a comment as a
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


def tunable_source_defaults(sources: Mapping[str, str]) -> dict[str, object]:
    """Fingerprint tunable initializers, their helpers and symbolic source dependencies.

    This is conservative source tracking, not a Swift interpreter: editing a selected declaration's
    help text or implementation also needs review. Unrelated declarations in its file do not.
    Same-file names and qualified Type.member references resolve to all possible source declarations
    (including extensions); ambiguity adds evidence rather than silently choosing one definition.
    """
    nodes, by_file_name, types = {}, {}, {}
    for path, text in sources.items():
        for type_name in re.findall(r"\b(?:enum|struct|class|extension)\s+(\w+)", strip_swift_comments(text)):
            types.setdefault(type_name, set()).add(path)
        for kind, name, tokens in static_declarations(text):
            key = f"tunable-source.{path.removeprefix(SWIFT_SOURCES + '/')}:{name}"
            while key in nodes:
                key += "#"
            nodes[key] = (path, kind, name, tokens)
            by_file_name.setdefault((path, name), set()).add(key)
    selected = {key for key, (_, _, _, tokens) in nodes.items()
                if any(re.fullmatch(r"(?:Derived)?Tunable|\w+Tunable", token) for token in tokens)}
    # A helper returning Tunable (e.g. points) has callers whose initializer has no Tunable token.
    helper_names = {name for key, (_, kind, name, _) in nodes.items()
                    if key in selected and kind == "func"}
    for key, (_, _, _, tokens) in nodes.items():
        if any(token in helper_names for token in tokens):
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


def command_text(text: str) -> str:
    """A workflow command's message, encoded as the runner expects."""
    return plain(text).replace("%", "%25")


def code(text: str) -> str:
    """Head text as a Markdown code span: no formatting, links or mentions."""
    text = plain(text)
    # The fence is longer than any run of backticks in the text, so nothing inside can close it.
    longest = max((len(run) for run in re.findall(r"`+", text)), default=0)
    fence = "`" * (longest + 1)
    return f"{fence} {text} {fence}" if longest else f"`{text}`"


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


def is_off(value: object) -> bool:
    return value is None or value is False or value == [] or value == {} or \
        (isinstance(value, str) and value.lower() in OFF_WORDS)


def exempt(found: list[Change], before: Mapping[str, object]) -> list[Change]:
    """The settings the head adds with an off default: what everyone got before the setting existed."""
    return [c for c in found if c.id.startswith("setting.") and c.id not in before and is_off(c.new)]


def guard_changes(base: Tree, head: Tree) -> list[Change]:
    found = []
    for path in GUARD_FILES:
        before, after = base.read(path), head.read(path)
        if before != after:
            state = "added" if before is None else "removed" if after is None else "edited"
            found.append(Change(f"guard.{path}", None, state))
    return found


# MARK: Approval


@dataclass
class Approval:
    owners: list[str]
    author: str
    head: str
    approvers: list[str] = field(default_factory=list)
    stale: list[str] = field(default_factory=list)
    shipped: str | None = None  # the reviewer whose SHIP receipt is the newest verdict on the head
    blocked: str | None = None  # the reviewer whose BLOCK receipt is

    @property
    def eligible(self) -> list[str]:
        return [o for o in self.owners if o.lower() != self.author.lower()]

    @property
    def approved(self) -> bool:
        return bool(self.approvers) or self.shipped is not None


def receipt_items(pull: Mapping[str, object]) -> list[tuple[Mapping[str, object], object]]:
    items = [(c, c.get("createdAt")) for c in (pull.get("comments") or {}).get("nodes") or []]
    return items + [(r, r.get("submittedAt")) for r in (pull.get("reviews") or {}).get("nodes") or []]


def receipt_line(item: Mapping[str, object], head: str) -> re.Match[str] | None:
    """The receipt on the item's first line when it names the full head and is not a self-review."""
    first = next((line for line in str(item.get("body") or "").splitlines() if line.strip()), "")
    line = RECEIPT.match(first)
    return line if head and line and "self" not in line.group(1).lower() and head in first else None


def receipt_verdict(pull: Mapping[str, object], head: str,
                    writers: Iterable[str] = ()) -> tuple[str, str] | None:
    """("ship" or "block", reviewer) of the newest receipt naming the full head sha on the first line
    of a trusted comment or review body; a self-review never counts and a BLOCK wins a tie. The
    cmux-bot App is trusted only when GitHub reports its exact Bot login and immutable node id.
    A user whose association reads as untrusted is trusted when listed in `writers` (repository
    write access, looked up by `repo_writers`)."""
    writers = {w.lower() for w in writers}
    found = []
    for item, at in receipt_items(pull):
        author = item.get("author") or {}
        if author.get("__typename") == "Bot":
            trusted = (str(author.get("login") or "") in CMUX_BOT_LOGINS
                       and str(author.get("id") or "") == CMUX_BOT_NODE_ID)
        elif author.get("__typename") == "User":
            trusted = (item.get("authorAssociation") in TRUSTED
                       or str(author.get("login") or "").lower() in writers)
        else:
            trusted = False
        if not trusted:
            continue
        line = receipt_line(item, head)
        if line:
            verdict = "ship" if line.group(2).lower() == "ship" else "block"
            found.append((str(at or ""), verdict == "block", verdict, f"review ({line.group(1).strip()})"))
    if not found:
        return None
    _, _, verdict, who = max(found)
    return verdict, who


def owners_for(text: str | None) -> list[str]:
    if text is None:
        return []
    return [str(o) for o in json.loads(text).get(APP, [])]


def repo_writers(repo: str, pull: Mapping[str, object], head: str) -> list[str]:
    """The authors of receipts on the head whose association reads as untrusted but who have write,
    maintain or admin access to the repository. GitHub hides a private org membership from the
    workflow's token, so such a member reads as CONTRIBUTOR here (#26153). One lookup per author;
    a lookup that fails (404: not a collaborator) trusts nobody."""
    logins: dict[str, str] = {}
    for item, _ in receipt_items(pull):
        author = item.get("author") or {}
        login = str(author.get("login") or "")
        if (login and author.get("__typename") == "User" and item.get("authorAssociation") not in TRUSTED
                and receipt_line(item, head)):
            logins.setdefault(login.lower(), login)
    writers = []
    for login in logins.values():
        result = subprocess.run(["gh", "api", f"repos/{repo}/collaborators/{login}/permission", "--jq", ".role_name"],
                                capture_output=True, text=True)
        if result.returncode == 0 and result.stdout.strip() in WRITER_ROLES:
            writers.append(login)
        elif result.returncode != 0 and "404" not in result.stderr:
            print(f"::warning title=Defaults reviewer lookup failed::{command_text(login)}: "
                  f"{command_text(result.stderr.strip()[:200])}")
    return writers


def approval(owners: list[str], pull: Mapping[str, object], writers: Iterable[str] = ()) -> Approval:
    """Who approved the head: each reviewer's latest decisive review counts."""
    author = str((pull.get("author") or {}).get("login") or "")
    head = str(pull.get("headRefOid") or "")
    result = Approval(owners=owners, author=author, head=head)
    latest: dict[str, Mapping[str, object]] = {}
    for review in (pull.get("reviews") or {}).get("nodes") or []:
        login = str((review.get("author") or {}).get("login") or "")
        if review.get("state") in ("APPROVED", "CHANGES_REQUESTED", "DISMISSED") and login:
            latest[login.lower()] = review
    for owner in result.eligible:
        review = latest.get(owner.lower())
        if not review or review.get("state") != "APPROVED":
            continue
        if str((review.get("commit") or {}).get("oid") or "") == head:
            result.approvers.append(owner)
        else:
            result.stale.append(owner)
    receipt = receipt_verdict(pull, head, writers)
    if receipt:
        if receipt[0] == "ship":
            result.shipped = receipt[1]
        else:
            result.blocked = receipt[1]
    return result


PULL_QUERY = """
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      author { login } headRefOid merged mergeCommit { oid }
      reviews(last: 100) { nodes { author { login __typename ... on Bot { id } } authorAssociation state body submittedAt commit { oid } } }
      comments(last: 100) { nodes { databaseId body createdAt authorAssociation author { login __typename ... on Bot { id } } } }
    }
  }
}
"""


def gh(args: list[str]) -> str:
    result = subprocess.run(["gh", *args], capture_output=True, text=True)
    if result.returncode != 0:
        raise SystemExit(f"gh {' '.join(args[:3])} failed: {result.stderr.strip()}")
    return result.stdout


def fetch_pull(repo: str, number: int) -> dict:
    owner, name = repo.split("/", 1)
    out = gh(["api", "graphql", "-f", f"query={PULL_QUERY}", "-f", f"owner={owner}", "-f", f"name={name}",
              "-F", f"number={number}"])
    return json.loads(out)["data"]["repository"]["pullRequest"]


# MARK: Report


def signed(verdict: Approval) -> str:
    who = [f"@{a}" for a in verdict.approvers] + ([f"`{plain(verdict.shipped)}`"] if verdict.shipped else [])
    return ", ".join(who)


def comment_body(found: list[Change], verdict: Approval | None, head: str, merged: str | None = None,
                 free: list[Change] | None = None) -> str:
    lines = [MARKER, "## Default changes"]
    if not found:
        lines.append(f"No defaults change at `{head[:12]}`.")
        return "\n".join(lines) + "\n"
    lines.append(f"This pull request changes {len(found)} default{'s' if len(found) != 1 else ''} at `{head[:12]}` "
                 "(what everyone gets without configuring anything):")
    lines.append("")
    free = free or []
    lines += [f"- {code(c.id)}: {code(c.detail)}" + (" (a new setting, off by default: passes on its own)" if c in free else "")
              for c in found]
    lines.append("")
    if all(c in free for c in found):
        lines.append("Every change is a new setting that defaults to off, the behavior from before it existed.")
    elif verdict is not None:
        if verdict.approved:
            lines.append(f"Signed off on this commit by {signed(verdict)}.")
        else:
            who = " or ".join(f"@{o}" for o in verdict.eligible) or "(no eligible call owner)"
            if verdict.blocked:
                lines.append(f"The newest verdict on this commit is a BLOCK from `{plain(verdict.blocked)}`.")
            lines.append(f"**Needs a review.** It passes with an independent review receipt on this commit: a comment "
                         f"or review whose first line is `Review (<reviewer>): SHIP at {head}`, from a member, not a "
                         "self-review (the newest verdict naming the head decides; a later BLOCK beats an earlier "
                         f"SHIP), or with an approving review on this commit from {who} (the call owners in `{OWNERS}`, "
                         "never the author). A receipt posted as a review re-runs this check; after a plain comment, "
                         "re-run it. The `needs a call` label alone does not pass, and a new push needs a new receipt.")
            if verdict.stale:
                lines.append(f"Earlier approvals on an older commit: {', '.join('@' + s for s in verdict.stale)}.")
    if merged:
        lines += ["", f"**Merge receipt:** merged as `{merged[:12]}` with these defaults changed"
                  + (f", signed off by {signed(verdict)}." if verdict and verdict.approved
                     else ", WITHOUT a SHIP receipt or an approving call owner review on its head.")]
    lines += ["", f"Regenerate the snapshot with `{REGENERATE}`."]
    return "\n".join(lines) + "\n"


def annotate(found: list[Change]) -> None:
    for c in found:
        print(f"::warning title=Default changed::{command_text(c.line)}")


def summary(text: str) -> None:
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if path:
        with open(path, "a", encoding="utf-8") as handle:
            handle.write(text)


def post_comment(repo: str, number: int, pull: Mapping[str, object], body: str, found: list[Change]) -> None:
    # Snapshot/check-fresh also run from small fixture checkouts without the writer.
    import pr_status

    if not found:
        # Do not create a clean-defaults section unless this PR previously had one.
        # Read the full comment list, not fetch_pull's last-100 receipt window.
        comments = pr_status.list_comments(pr_status.http_api, repo, number)
        previous = pr_status.bot_comments(comments, MARKER)
        status = pr_status.bot_comments(comments, pr_status.MARKER)
        if not previous and not any("defaults" in pr_status.parse(c["body"]) for c in status):
            return
    pr_status.upsert(repo, number, "defaults", body.removeprefix(MARKER).strip(), legacy=MARKER)


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
        path for path in tree.files(SETTINGS_SOURCE_DIR) if PurePosixPath(path).suffix in SETTINGS_SOURCE_SUFFIXES]
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


def command_check(args: argparse.Namespace) -> int:
    base, head = Tree.named(args.base), Tree.named(args.head)
    head_sha = args.head_sha or args.head
    # Both sides are judged by their sources and exports, never by a committed
    # snapshot: the snapshot is bot-only (#21946), so a pull request does not
    # commit it, and a hand-edited copy could hide a change.
    problems: list[str] = []
    before = defaults(base)
    after = defaults(head)
    found = changes(before, after) + guard_changes(base, head)
    free = exempt(found, before)
    trusted = Tree(None)  # the base checkout the workflow runs from
    owners = owners_for(trusted.read(OWNERS))
    pull = None
    if args.pull_json:
        pull = json.loads(Path(args.pull_json).read_text(encoding="utf-8"))
    elif args.pr and args.repo:
        pull = fetch_pull(args.repo, args.pr)
        # Right after a push GitHub can still report the previous head for a few seconds.
        for _ in range(4):
            if str(pull.get("headRefOid") or "") == head_sha:
                break
            time.sleep(5)
            pull = fetch_pull(args.repo, args.pr)
    writers = repo_writers(args.repo, pull, head_sha) if pull is not None and args.repo else []
    verdict = approval(owners, pull, writers) if pull is not None else None
    if pull is not None and verdict is not None and verdict.head != head_sha:
        problems.append(f"DEFAULTS head: the pull request's head is {verdict.head[:12]}, not {head_sha[:12]}; re-run on the new head")
    merged = str((pull.get("mergeCommit") or {}).get("oid") or "") if pull and pull.get("merged") else None
    body = comment_body(found, verdict, head_sha, merged, free)
    annotate(found)
    for problem in problems:
        print(f"::error title=Defaults snapshot::{command_text(problem)}" if not problem.startswith("  ") else plain(problem))
    for c in found:
        print(c.line)
    summary(body)
    if args.comment and pull is not None:
        try:
            post_comment(args.repo, args.pr, pull, body, found)
        # comment failures never change the verdict; a checkout without the writer (main's
        # pull_request_target sparse list may lag the guard) is one of them
        except (SystemExit, RuntimeError, OSError, ImportError) as error:
            print(f"::warning title=Defaults comment not posted::{error}")
    if problems:
        return 1
    needed = [c for c in found if c not in free]
    if needed and not (verdict and verdict.approved):
        who = " or ".join(verdict.eligible) if verdict else "a call owner"
        print(f"::error title=Default changes need a review::{len(needed)} default(s) changed; needs a comment or review "
              f"whose first line is `Review (<reviewer>): SHIP at {head_sha}` from a member (not a self-review), "
              f"or an approving review on {head_sha[:12]} from {who}")
        return 1
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
    check = sub.add_parser("check", help="list changed defaults between two commits and judge the approval")
    check.add_argument("--base", required=True, help="the merge base: a commit, or a directory checked out at it")
    check.add_argument("--head", required=True, help="the head: a commit, or a directory checked out at it")
    check.add_argument("--head-sha", help="the head commit when --head is a directory")
    check.add_argument("--repo")
    check.add_argument("--pr", type=int)
    check.add_argument("--pull-json", help="the pull request as fetch_pull returns it (tests)")
    check.add_argument("--comment", action="store_true", help="post or update the sticky comment")
    check.set_defaults(run=command_check)
    args = parser.parse_args(argv)
    return args.run(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
