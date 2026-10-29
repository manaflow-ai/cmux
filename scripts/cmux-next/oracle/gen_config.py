#!/usr/bin/env python3
"""The oracle's `config` suite: Swift vs Rust effective config (p15-oracle-212).

Spec: plans/cmux-next/chrome-parity/p15-oracle.md, section 3D (suite `config`, differential, >= 2,000 files)
and task 212. Stdlib only and safe under `python3 -I`.

The app (Swift `EffectiveSettings.merge` and `SettingDescriptor`) and the daemon (cmux-config
`EffectiveSettings::merge`, `schema::accepts`) each read cmux.json. This tool writes the corpus both
read, and compares what the two dump executables print for it:

The corpus is not committed: `python3 -I scripts/cmux-next/oracle/corpus_store.py ensure --suite config` (or this
tool) writes it before a dump.

  swift: swift run --package-path Packages/macOS/CmuxNext OracleConfigDump --corpus tests/oracle/corpus/config
  rust:  cargo run -p cmux-config --example oracle_effective -- --corpus tests/oracle/corpus/config

Chromium pins each enterprise policy's effective pref with one JSON row per policy
(chrome/test/data/policy/policy_test_cases.json, run by PolicyPrefsTest) and parsed JSON through two
implementations behind one interface (base/json/json_reader.cc, the C++ parser and the Rust
serde_json_lenient parser behind `features::kUseRustJsonParser`). The config suite does both: one file
per schema sample, read by the two implementations, compared after canonicalization.

Corpus (tests/oracle/corpus/config/, every file `.jsonc`, so `oracle.py check` does not read them as
cases):

  settings/schema/<key>.<accept|refuse|default|wrongtype>-<i>.jsonc   one schema sample at its key path
  settings/defaults/all-rows.jsonc                                     every row at its default
  settings/retired/<name>.jsonc                                        retired keys alone and with live keys
  settings/mutations/seed-<n>.jsonc                                    seeded JSONC spellings and breakage
  managed/seed-<n>.jsonc, managed/<name>.jsonc                         {"file", "forced", "recommended", "team"}
  keybindings/<name>.jsonc                                             {"strokes": [...], "when": [...]}
  coverage.json                                                        rows covered, file counts (oracle.py check --coverage)

Dump lines (JSONL; the first line is the header {"oracle_config_dump": 1, "producer": "swift"|"rust"}):

  settings, managed: {"file", "dump": {"readable", "effective", "values", "invalid", "retired", "managed",
                      "policy", "diagnostics"}}
  keybindings:       {"file", "dump": {"strokes": [stroke|null], "bare_when": [bool]}}

A Swift stroke is {"key": <key equivalent>, "cmd", "shift", "opt", "ctrl"}; a Rust stroke is the
normalized text (`cmd+shift+k`). Both become the stroke the app reads (`ShortcutBindingFormat.parseStroke`
of the daemon's text), so `cmd++` normalized to `cmd+plus` shows as the divergence it is.

Usage:
  gen_config.py [--out DIR]          write the corpus (oracle.py gen --suite config)
  gen_config.py --check [--out DIR]  exit 1 when DIR differs from a fresh generation. The repo corpus is not
                                     committed (corpus_store.py writes it with this generator), so there it only
                                     shows that the generator is deterministic
  gen_config.py diff --swift S.jsonl --rust R.jsonl [--out divergences.jsonl] [--show N]
      prints a summary; each divergence is one JSONL line {"file", "path", "swift", "rust"}, with a
      side omitted when that dump has no value at the path. Exit 0 when equal, 1 when not, 2 on bad input.
"""

from __future__ import annotations

import argparse
import json
import random
import re
import sys
from collections import Counter
from pathlib import Path
from typing import Any, Dict, Iterable, Iterator, List, Optional, Sequence, Tuple

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
SCHEMA = REPO / "schemas" / "settings" / "settings-schema.json"
RETIRED = REPO / "schemas" / "settings" / "retired-keys.json"
VECTORS = REPO / "schemas" / "keybindings" / "keybinding-vectors.json"
DEFAULT_OUT = REPO / "tests" / "oracle" / "corpus" / "config"

DUMP_VERSION = 1
MUTATION_SEEDS = 640
MANAGED_SEEDS = 240
STROKES_PER_FILE = 64
WHENS_PER_FILE = 32
MIN_FILES = 2000


class ConfigError(Exception):
    """Bad input: a dump that does not parse or a corpus that does not match."""


# ---------------------------------------------------------------------------------------
# Inputs


def load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise ConfigError(f"{path}: {error}") from None


def schema_rows() -> List[Dict[str, Any]]:
    return list(load_json(SCHEMA)["rows"])


def retired_keys() -> List[str]:
    return [entry["key"] for entry in load_json(RETIRED)["retired"]]


def nest(path: Sequence[str], value: Any) -> Dict[str, Any]:
    out: Any = value
    for part in reversed(path):
        out = {part: out}
    return out


def merge_into(root: Dict[str, Any], path: Sequence[str], value: Any) -> None:
    """Sets `value` at `path`; a non-object in the way is replaced (both products do the same)."""
    node = root
    for part in path[:-1]:
        child = node.get(part)
        if not isinstance(child, dict):
            child = {}
            node[part] = child
        node = child
    node[path[-1]] = value


def pretty(value: Any) -> str:
    return json.dumps(value, indent=2, ensure_ascii=False) + "\n"


# ---------------------------------------------------------------------------------------
# Wrong-type values: a value of a JSON type the row's kind never takes.

OBJECT_KINDS = {"time_range", "string_map", "choice_or_url"}


def wrong_type(kind: str) -> Any:
    return [True, "oracle"] if kind in OBJECT_KINDS else {"oracle": [1, "wrong type"]}


def file_name(key: str) -> str:
    """A file-system-safe spelling of a dotted key (keys are ASCII identifiers and dots today)."""
    return "".join(c if c.isalnum() or c in "._-" else f"~{ord(c):x}" for c in key)


# ---------------------------------------------------------------------------------------
# Generators. Each yields (relative path, text).


def schema_files(rows: Sequence[Dict[str, Any]]) -> Iterator[Tuple[str, str]]:
    for row in rows:
        key, path = row["key"], row["path"]
        accepts, refuses = list(row.get("accepts") or []), list(row.get("refuses") or [])
        for index, value in enumerate(accepts):
            yield f"settings/schema/{file_name(key)}.accept-{index}.jsonc", pretty(nest(path, value))
        for index, value in enumerate(refuses):
            yield f"settings/schema/{file_name(key)}.refuse-{index}.jsonc", pretty(nest(path, value))
        default = row.get("default")
        if default is not None and default not in accepts:
            yield f"settings/schema/{file_name(key)}.default-0.jsonc", pretty(nest(path, default))
        if not refuses:
            yield f"settings/schema/{file_name(key)}.wrongtype-0.jsonc", pretty(nest(path, wrong_type(row["kind"])))


def defaults_files(rows: Sequence[Dict[str, Any]]) -> Iterator[Tuple[str, str]]:
    root: Dict[str, Any] = {}
    for row in rows:
        if row.get("default") is not None:
            merge_into(root, row["path"], row["default"])
    yield "settings/defaults/all-rows.jsonc", pretty(root)
    yield "settings/defaults/empty-object.jsonc", "{}\n"
    yield "settings/defaults/empty-file.jsonc", ""


def retired_files(rows: Sequence[Dict[str, Any]], retired: Sequence[str]) -> Iterator[Tuple[str, str]]:
    live = next((row for row in rows if row["kind"] == "toggle"), rows[0])
    values = [True, "retired", {"nested": 1}]
    for key in retired:
        path = key.split(".")
        for index, value in enumerate(values):
            yield f"settings/retired/{file_name(key)}-{index}.jsonc", pretty(nest(path, value))
        root = nest(path, True)
        merge_into(root, live["path"], (live.get("accepts") or [True])[0])
        yield f"settings/retired/{file_name(key)}-with-live.jsonc", pretty(root)
    every: Dict[str, Any] = {}
    for key in retired:
        merge_into(every, key.split("."), "retired")
    yield "settings/retired/all.jsonc", pretty(every)


def sample_values(row: Dict[str, Any]) -> List[Any]:
    values = list(row.get("accepts") or []) + list(row.get("refuses") or [])
    if row.get("default") is not None:
        values.append(row["default"])
    return values or [wrong_type(row["kind"])]


def random_document(rows: Sequence[Dict[str, Any]], rng: random.Random, low: int, high: int) -> Dict[str, Any]:
    root: Dict[str, Any] = {}
    for row in rng.sample(list(rows), rng.randint(low, high)):
        merge_into(root, row["path"], rng.choice(sample_values(row)))
    return root


class JsoncWriter:
    """Writes a value as JSONC with seeded spellings both parsers must read the same."""

    def __init__(self, rng: random.Random) -> None:
        self.rng = rng
        self.comments = rng.random() < 0.6
        self.trailing_commas = rng.random() < 0.4
        self.escape_strings = rng.random() < 0.3
        self.number_spellings = rng.random() < 0.4
        self.duplicate_members = rng.random() < 0.15
        self.compact = rng.random() < 0.2
        self.indent = rng.choice(["  ", "    ", "\t"])

    def comment(self) -> str:
        if not self.comments or self.rng.random() < 0.6:
            return ""
        if self.rng.random() < 0.5:
            return "// " + self.rng.choice(["note", "a { brace", "\"quoted\"", "url: https://localhost/x"]) + "\n"
        return "/* " + self.rng.choice(["block", "*", "// inside", "{\"k\": 1}"]) + " */ "

    def string(self, text: str) -> str:
        if not self.escape_strings:
            return json.dumps(text, ensure_ascii=False)
        out = []
        for char in text:
            if char.isalpha() and self.rng.random() < 0.3:
                out.append("\\u%04x" % ord(char) if ord(char) < 0x10000 else json.dumps(char)[1:-1])
            elif char == "/" and self.rng.random() < 0.5:
                out.append("\\/")
            else:
                out.append(json.dumps(char, ensure_ascii=False)[1:-1])
        return '"' + "".join(out) + '"'

    def number(self, value: Any) -> str:
        if isinstance(value, bool) or not self.number_spellings:
            return json.dumps(value)
        if isinstance(value, int) and abs(value) < 10**12:
            return self.rng.choice([str(value), f"{value}.0", f"{value}e0", f"{value * 10}E-1"])
        if isinstance(value, float) and value == value and abs(value) < 1e12:
            return self.rng.choice([repr(value), f"{value!r}e0" if "e" not in repr(value) else repr(value)])
        return json.dumps(value)

    def write(self, value: Any, level: int = 0) -> str:
        if isinstance(value, dict):
            return self.members(value, level)
        if isinstance(value, list):
            return self.items(value, level)
        if isinstance(value, str):
            return self.string(value)
        if isinstance(value, (int, float)) and not isinstance(value, bool):
            return self.number(value)
        return json.dumps(value)

    def separator(self, level: int) -> str:
        return "" if self.compact else "\n" + self.indent * level

    def members(self, value: Dict[str, Any], level: int) -> str:
        if not value:
            return "{" + self.comment().replace("\n", " ") + "}" if self.comments else "{}"
        parts = []
        for key, item in value.items():
            if self.duplicate_members and self.rng.random() < 0.2:
                # The earlier spelling of a duplicated member: JSON leaves the winner open, so the
                # two parsers have to agree on one (both keep the last today).
                parts.append(self.string(key) + ": " + json.dumps(self.rng.choice([0, "shadowed", None])))
            parts.append(self.comment() + self.string(key) + (":" if self.compact else ": ") + self.write(item, level + 1))
        inner = ("," + self.separator(level + 1)).join(parts)
        tail = "," if self.trailing_commas and self.rng.random() < 0.5 else ""
        return "{" + self.separator(level + 1) + inner + tail + self.separator(level) + "}"

    def items(self, value: List[Any], level: int) -> str:
        if not value:
            return "[]"
        inner = ", ".join(self.write(item, level + 1) for item in value)
        tail = "," if self.trailing_commas and self.rng.random() < 0.5 else ""
        return "[" + inner + tail + "]"


# Ways a file stops being a readable cmux.json object, or edges of the format around that line.
BREAKAGES = [
    ("unterminated-block-comment", lambda text: text + "/* not closed\n"),
    ("missing-closing-brace", lambda text: text.rstrip().rstrip("}") + "\n"),
    ("trailing-garbage", lambda text: text + "\n}\n"),
    ("root-array", lambda text: "[" + text + "]\n"),
    ("root-string", lambda text: json.dumps(text) + "\n"),
    ("root-number", lambda text: "42\n"),
    ("root-null", lambda text: "null\n"),
    ("comment-only", lambda text: "// nothing here\n/* at all */\n"),
    ("byte-order-mark", lambda text: "\ufeff" + text),
    ("crlf", lambda text: text.replace("\n", "\r\n")),
    ("single-quotes", lambda text: text.replace('"', "'", 2)),
    ("bare-key", lambda text: text.replace('"', "", 2)),
    ("nan", lambda text: text.rstrip().rstrip("}") + ', "oracle": NaN}\n'),
    ("leading-comma", lambda text: text.replace("{", "{,", 1)),
    ("double-trailing-comma", lambda text: text.rstrip().rstrip("}") + ",,}\n"),
    ("unicode-line-separator", lambda text: text.replace("\n", "\u2028\n", 1)),
    ("huge-number", lambda text: text.rstrip().rstrip("}") + ', "oracle": 1e400}\n'),
    ("big-integer", lambda text: text.rstrip().rstrip("}") + ', "oracle": 12345678901234567890}\n'),
    ("lone-surrogate", lambda text: text.rstrip().rstrip("}") + ', "oracle": "\\ud800"}\n'),
    ("nul-escape", lambda text: text.rstrip().rstrip("}") + ', "oracle": "a\\u0000b"}\n'),
]


def mutation_files(rows: Sequence[Dict[str, Any]], seeds: int) -> Iterator[Tuple[str, str]]:
    for seed in range(seeds):
        rng = random.Random(f"p15-oracle-212/mutation/{seed}")
        root = random_document(rows, rng, 1, 12)
        if rng.random() < 0.3:
            merge_into(root, ["oracleUnknown", "nested"], {"key": rng.choice([1, "x", [True]])})
        if rng.random() < 0.15:
            # A scalar where a section object belongs, then the section's members after it.
            section = rng.choice([row["path"] for row in rows if len(row["path"]) > 1])
            root = {section[0]: rng.choice([True, "flat", 3]), **root}
        text = JsoncWriter(rng).write(root) + "\n"
        name = f"seed-{seed:04d}"
        if rng.random() < 0.25:
            label, breakage = rng.choice(BREAKAGES)
            text = breakage(text)
            name += f"-{label}"
        yield f"settings/mutations/{name}.jsonc", text


def managed_envelope(file_text: str, forced: Dict[str, Any], recommended: Dict[str, Any],
                     team_name: str, defaults: Dict[str, Any], enforced: Dict[str, Any]) -> str:
    return pretty({
        "file": file_text,
        "forced": forced,
        "recommended": recommended,
        "team": {"name": team_name, "defaults": defaults, "enforced": enforced},
    })


def managed_files(rows: Sequence[Dict[str, Any]], seeds: int) -> Iterator[Tuple[str, str]]:
    toggles = [row for row in rows if row["kind"] == "toggle"]
    first, second = toggles[0], toggles[1]
    k1, k2 = first["key"], second["key"]
    yield "managed/forced-overrides-file.jsonc", managed_envelope(
        pretty(nest(first["path"], True)), {k1: False}, {}, "", {}, {})
    yield "managed/team-enforced-overrides-file.jsonc", managed_envelope(
        pretty(nest(first["path"], True)), {}, {}, "Oracle Team", {}, {k1: False})
    yield "managed/forced-and-team-conflict.jsonc", managed_envelope(
        "{}\n", {k1: True}, {}, "Oracle Team", {}, {k1: False})
    yield "managed/recommended-below-file.jsonc", managed_envelope(
        pretty(nest(first["path"], False)), {}, {k1: True, k2: True}, "", {}, {})
    yield "managed/recommended-over-team-default.jsonc", managed_envelope(
        "{}\n", {}, {k1: True}, "Oracle Team", {k1: False, k2: False}, {})
    yield "managed/team-non-catalog-keys.jsonc", managed_envelope(
        "{}\n", {}, {}, "Oracle Team", {"oracle.notASetting": 1, "shortcuts": {}}, {"customActions": []})
    yield "managed/policy-keys.jsonc", managed_envelope(
        "{}\n", {"EnrollmentToken": "  token  ", "DisabledFeatures": ["oracle"], "DisableTelemetry": True},
        {"EnrollmentToken": "recommended-only"}, "", {}, {})
    yield "managed/forced-object-and-nested-key.jsonc", managed_envelope(
        "{}\n", {first["path"][0]: {"oracle": 1}, k1: True}, {}, "", {}, {})
    yield "managed/legacy-link-key-forced.jsonc", managed_envelope(
        "{}\n", {"browser.openTerminalLinksInCmuxBrowser": False}, {}, "", {}, {})
    yield "managed/legacy-link-key-in-file.jsonc", managed_envelope(
        pretty({"browser": {"openTerminalLinksInCmuxBrowser": False}}), {}, {}, "", {}, {})
    yield "managed/unreadable-file.jsonc", managed_envelope("{ not jsonc", {k1: False}, {}, "", {}, {})
    for seed in range(seeds):
        rng = random.Random(f"p15-oracle-212/managed/{seed}")
        file_root = random_document(rows, rng, 0, 6)
        layers: List[Dict[str, Any]] = [{}, {}, {}, {}]
        for row in rng.sample(list(rows), rng.randint(1, 8)):
            layers[rng.randrange(4)][row["key"]] = rng.choice(sample_values(row))
            if rng.random() < 0.2:
                # The same key in a second layer: the merge order decides.
                layers[rng.randrange(4)][row["key"]] = rng.choice(sample_values(row))
        forced, recommended, defaults, enforced = layers
        team = rng.choice(["", "Oracle Team", "Ünïcode Team"])
        yield f"managed/seed-{seed:04d}.jsonc", managed_envelope(
            pretty(file_root), forced, recommended, team, defaults, enforced)


MODIFIER_SPELLINGS = [
    ["cmd"], ["command"], ["meta"], ["⌘"], ["shift"], ["⇧"], ["opt"], ["option"], ["alt"], ["⌥"],
    ["ctrl"], ["control"], ["ctl"], ["⌃"], ["CMD"], ["Ctrl"], ["cmd", "shift"], ["shift", "cmd"],
    ["ctrl", "opt", "shift", "cmd"], ["cmd", "cmd"], [], ["hyper"], [""],
]
KEY_TOKENS = (
    list("abcxyzAZ019") + [",", ".", "/", "\\", ";", "'", "`", "-", "=", "[", "]", "+", "é", "ß"]
    + ["left", "right", "up", "down", "tab", "return", "enter", "escape", "esc", "delete", "backspace",
       "space", "spacebar", "home", "end", "pageup", "pagedown", "plus", "equals", "comma", "period", "dot",
       "slash", "backslash", "semicolon", "quote", "apostrophe", "backtick", "grave", "minus", "hyphen",
       "leftbracket", "openbracket", "rightbracket", "closebracket", "arrowleft", "leftarrow", "arrowup",
       "uparrow", "arrowdown", "downarrow", "arrowright", "rightarrow", "Left", "TAB", "←", "↑", "⇥", "↩",
       "⎋", "⌫", "<space>", "f0", "f1", "f9", "f12", "f13", "f20", "f21", "F5", "insert", "", " ", "ab"]
)


def vector_texts() -> Tuple[List[str], List[str]]:
    """Every stroke and `when` text of keybinding-vectors.json, in file order."""
    strokes: List[str] = []
    whens: List[str] = []
    for vector in load_json(VECTORS)["vectors"]:
        for keys in vector.get("keys") or []:
            strokes.extend(part for part in keys.split(" ") if part)
        for entry in (vector.get("bindings") or []) + (vector.get("removals") or []):
            if isinstance(entry.get("key"), str):
                strokes.extend(part for part in entry["key"].split(" ") if part)
            if isinstance(entry.get("when"), str):
                whens.append(entry["when"])
    return strokes, whens


WHEN_TERMS = [
    "diffViewerFocused", "markdownReadOnlyFocused", "textInputFocus", "terminalFocused", "browserFocused",
    "agentPaneFocused", "omnibarFocused", "!textInputFocus", "surfaceKind == 'diff'", "true", "false",
    "markdownEditorFocused", "codeEditorFocused", "textBoxFocused", "resourceScheme =~ /^file$/i",
    "surfaceKind in panes", "surfaceKind not in panes",
]


def generated_whens(rng: random.Random, count: int) -> List[str]:
    whens = []
    for _ in range(count):
        terms = rng.sample(WHEN_TERMS, rng.randint(1, 3))
        joiner = rng.choice([" && ", " || ", "&&", " && "])
        text = joiner.join(terms)
        if rng.random() < 0.2:
            text = f"({text})" + rng.choice(["", " && diffViewerFocused", " || markdownReadOnlyFocused"])
        if rng.random() < 0.1:
            text = rng.choice([text + " &&", "(" + text, text + ")", "!" + text, "!!" + text])
        whens.append(text)
    return whens


def keybinding_files() -> Iterator[Tuple[str, str]]:
    vector_strokes, vector_whens = vector_texts()
    strokes = list(vector_strokes)
    for modifiers in MODIFIER_SPELLINGS:
        for token in KEY_TOKENS:
            strokes.append("+".join(modifiers + [token]))
    strokes += ["cmd++", "+", "++", "cmd+", "cmd+shift+", " cmd+k ", "cmd + k", "cmd+k+", "cmd++k", "ctrl+f1"]
    rng = random.Random("p15-oracle-212/keybindings")
    whens = list(vector_whens) + generated_whens(rng, 512)
    whens += ["", " ", "&&", "()", "diffViewerFocused && textInputFocus", "diffViewerFocused||textInputFocus"]
    stroke_chunks = [strokes[i:i + STROKES_PER_FILE] for i in range(0, len(strokes), STROKES_PER_FILE)]
    when_chunks = [whens[i:i + WHENS_PER_FILE] for i in range(0, len(whens), WHENS_PER_FILE)]
    for index in range(max(len(stroke_chunks), len(when_chunks))):
        yield f"keybindings/vectors-{index:04d}.jsonc", pretty({
            "strokes": stroke_chunks[index] if index < len(stroke_chunks) else [],
            "when": when_chunks[index] if index < len(when_chunks) else [],
        })


def corpus() -> Dict[str, str]:
    rows = schema_rows()
    files: Dict[str, str] = {}
    generators: Iterable[Iterator[Tuple[str, str]]] = (
        schema_files(rows), defaults_files(rows), retired_files(rows, retired_keys()),
        mutation_files(rows, MUTATION_SEEDS), managed_files(rows, MANAGED_SEEDS), keybinding_files(),
    )
    for generator in generators:
        for rel, text in generator:
            if rel in files:
                raise ConfigError(f"generator wrote {rel} twice")
            files[rel] = text
    keys_with_files = {rel.split("/")[2].rsplit(".", 2)[0] for rel in files if rel.startswith("settings/schema/")}
    missing = sorted(row["key"] for row in rows if file_name(row["key"]) not in keys_with_files)
    by_kind = Counter(rel.split("/")[0] if not rel.startswith("settings/") else "/".join(rel.split("/")[:2])
                      for rel in files)
    files["coverage.json"] = json.dumps({
        "suite": "config",
        "generator": "scripts/cmux-next/oracle/gen_config.py",
        "unit": "settings schema rows with at least one sample file",
        "covered": len(rows) - len(missing),
        "total": len(rows),
        "excluded": {},
        "missing": missing,
        "files": dict(sorted(by_kind.items())),
        "file_count": len(files),
    }, indent=2, sort_keys=True) + "\n"
    if len(files) - 1 < MIN_FILES:
        raise ConfigError(f"the corpus has {len(files) - 1} files, the suite needs >= {MIN_FILES}")
    return files


def write_corpus(out: Path, files: Dict[str, str]) -> None:
    out.mkdir(parents=True, exist_ok=True)
    stale = {p for p in out.rglob("*") if p.is_file()} - {out / rel for rel in files}
    for path in stale:
        path.unlink()
    for rel, text in files.items():
        path = out / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        if not path.is_file() or path.read_bytes() != text.encode("utf-8"):
            path.write_bytes(text.encode("utf-8"))


def check_corpus(out: Path, files: Dict[str, str]) -> List[str]:
    problems = []
    on_disk = {p.relative_to(out).as_posix() for p in out.rglob("*") if p.is_file()} if out.is_dir() else set()
    for rel in sorted(on_disk - files.keys()):
        problems.append(f"{rel}: not generated (stale)")
    for rel, text in sorted(files.items()):
        path = out / rel
        if rel not in on_disk:
            problems.append(f"{rel}: missing")
        elif path.read_bytes() != text.encode("utf-8"):
            problems.append(f"{rel}: differs from a fresh generation")
    return problems


# ---------------------------------------------------------------------------------------
# Diff


def read_dump(path: Path, producer: str) -> Dict[str, Any]:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as error:
        raise ConfigError(f"{path}: {error}") from None
    records: Dict[str, Any] = {}
    header: Optional[Dict[str, Any]] = None
    for number, line in enumerate(lines, 1):
        if not line.strip():
            continue
        try:
            record = json.loads(line)
        except ValueError as error:
            raise ConfigError(f"{path}:{number}: {error}") from None
        if header is None:
            header = record
            if record.get("oracle_config_dump") != DUMP_VERSION or record.get("producer") != producer:
                raise ConfigError(f"{path}: the first line must be "
                                  f'{{"oracle_config_dump": {DUMP_VERSION}, "producer": "{producer}"}}, got {line[:120]}')
            continue
        if not isinstance(record, dict) or not isinstance(record.get("file"), str) or "dump" not in record:
            raise ConfigError(f"{path}:{number}: a line is {{\"file\", \"dump\"}}")
        if record["file"] in records:
            raise ConfigError(f"{path}:{number}: {record['file']} is dumped twice")
        records[record["file"]] = record["dump"]
    if header is None:
        raise ConfigError(f"{path}: empty dump")
    return records


# Swift `ShortcutBindingFormat.keyEquivalent(forToken:)` for the key names the daemon writes: the
# key the app reads from a normalized stroke. NS*FunctionKey code points (AppKit NSEvent.h).
FUNCTION_KEYS = {
    "up": "\uf700", "down": "\uf701", "left": "\uf702", "right": "\uf703",
    "home": "\uf729", "end": "\uf72b", "pageup": "\uf72c", "pagedown": "\uf72d",
}
FUNCTION_KEYS.update({f"f{n}": chr(0xF704 + n - 1) for n in range(1, 21)})
PUNCTUATION_NAMES = {
    "comma": ",", "period": ".", "slash": "/", "backslash": "\\", "semicolon": ";", "quote": "'",
    "backtick": "`", "minus": "-", "plus": "=", "leftbracket": "[", "rightbracket": "]",
}
NAMED_EQUIVALENTS = {
    **FUNCTION_KEYS, "tab": "\t", "return": "\r", "escape": "\u001b", "delete": "\u0008", "space": " ",
    **PUNCTUATION_NAMES,
}
# Every other spelling `keyEquivalent(forToken:)` reads, matched after `lowercased()`.
TOKEN_ALIASES = {
    "arrowleft": "left", "leftarrow": "left", "←": "left",
    "arrowright": "right", "rightarrow": "right", "→": "right",
    "arrowup": "up", "uparrow": "up", "↑": "up",
    "arrowdown": "down", "downarrow": "down", "↓": "down",
    "⇥": "tab", "enter": "return", "↩": "return", "esc": "escape", "⎋": "escape",
    "backspace": "delete", "⌫": "delete", "spacebar": "space", "<space>": "space",
    "dot": "period", "apostrophe": "quote", "grave": "backtick", "hyphen": "minus", "equals": "plus",
    "openbracket": "leftbracket", "closebracket": "rightbracket",
}
EQUIVALENT_NAMES = {equivalent: name for name, equivalent in NAMED_EQUIVALENTS.items()
                    if name not in PUNCTUATION_NAMES}
EQUIVALENT_NAMES["\u007f"] = "delete"


def app_key_equivalent(token: str) -> Optional[str]:
    """Swift `ShortcutBindingFormat.keyEquivalent(forToken:)`: the key the app reads for a token, or None."""
    trimmed = token.strip(" \t")
    if not trimmed:
        return " " if token == " " else None
    lowered = trimmed.lower()
    name = TOKEN_ALIASES.get(lowered, lowered)
    if name in NAMED_EQUIVALENTS and not name.startswith("f"):
        return NAMED_EQUIVALENTS[name]
    # Swift `Int(String)`: an optional sign, then ASCII digits.
    if re.fullmatch(r"f[+-]?[0-9]+", lowered) and 1 <= int(lowered[1:]) <= 20:
        return FUNCTION_KEYS[f"f{int(lowered[1:])}"]
    return lowered if len(lowered) == 1 else None


def stroke_text(equivalent: str, cmd: bool, shift: bool, opt: bool, ctrl: bool) -> str:
    """`cmd+shift+opt+ctrl+<key>`: named keys by name, every other key as its character."""
    names = [name for on, name in ((cmd, "cmd"), (shift, "shift"), (opt, "opt"), (ctrl, "ctrl")) if on]
    return "+".join(names + [EQUIVALENT_NAMES.get(equivalent, equivalent)])


def canonical_rust_stroke(value: Any) -> Any:
    if not isinstance(value, str):
        return value
    head, _, key = value.rpartition("+")
    if not key and head.endswith("+"):
        head, key = head[:-1], "+"  # `cmd++`, as `parseStroke` reads it
    modifiers = set(head.split("+")) if head else set()
    equivalent = app_key_equivalent(key)
    if equivalent is None:
        # The daemon wrote a stroke the app cannot read: a divergence, never a match.
        return {"unreadable_by_app": value}
    return stroke_text(equivalent, "cmd" in modifiers, "shift" in modifiers, "opt" in modifiers, "ctrl" in modifiers)


def canonical_swift_stroke(value: Any) -> Any:
    if not isinstance(value, dict) or not isinstance(value.get("key"), str):
        return value
    return stroke_text(value["key"], *(bool(value.get(name)) for name in ("cmd", "shift", "opt", "ctrl")))


def canonical_value(value: Any) -> Any:
    """Numbers as the app's Double (Swift JSONValue holds every number as one); keys sorted on output."""
    if isinstance(value, bool) or value is None or isinstance(value, str):
        return value
    if isinstance(value, (int, float)):
        number = float(value)
        return int(number) if number.is_integer() and abs(number) < 1e15 else number
    if isinstance(value, list):
        return [canonical_value(item) for item in value]
    if isinstance(value, dict):
        return {key: canonical_value(item) for key, item in value.items()}
    return value


SET_FIELDS = ("invalid", "retired", "diagnostics")


def canonical_dump(dump: Any, producer: str) -> Any:
    if not isinstance(dump, dict):
        return dump
    out = canonical_value(dump)
    if "strokes" in out and isinstance(out["strokes"], list):
        convert = canonical_swift_stroke if producer == "swift" else canonical_rust_stroke
        out["strokes"] = [convert(item) for item in dump["strokes"]]
    for field in SET_FIELDS:
        if isinstance(out.get(field), list):
            out[field] = sorted(out[field], key=lambda item: json.dumps(item, sort_keys=True))
    return out


def escape(token: str) -> str:
    return token.replace("~", "~0").replace("/", "~1")


ABSENT = object()


def differences(swift: Any, rust: Any, path: str = "") -> Iterator[Tuple[str, Any, Any]]:
    if isinstance(swift, dict) and isinstance(rust, dict):
        for key in sorted(swift.keys() | rust.keys()):
            yield from differences(swift.get(key, ABSENT), rust.get(key, ABSENT), f"{path}/{escape(key)}")
    elif isinstance(swift, list) and isinstance(rust, list) and len(swift) == len(rust) and path.endswith(("/strokes", "/bare_when")):
        for index, (left, right) in enumerate(zip(swift, rust)):
            yield from differences(left, right, f"{path}/{index}")
    elif swift is ABSENT or rust is ABSENT or json.dumps(swift, sort_keys=True) != json.dumps(rust, sort_keys=True):
        yield path, swift, rust


def diff_records(swift: Dict[str, Any], rust: Dict[str, Any]) -> List[Dict[str, Any]]:
    out = []
    for file in sorted(swift.keys() | rust.keys()):
        left = canonical_dump(swift[file], "swift") if file in swift else ABSENT
        right = canonical_dump(rust[file], "rust") if file in rust else ABSENT
        for path, a, b in differences(left, right):
            record: Dict[str, Any] = {"file": file, "path": path}
            if a is not ABSENT:
                record["swift"] = a
            if b is not ABSENT:
                record["rust"] = b
            out.append(record)
    return out


def group_of(path: str) -> str:
    parts = path.split("/")
    return "/".join(parts[:3]) if len(parts) > 2 and parts[1] in {"values", "managed"} else "/".join(parts[:2]) or "/"


def cmd_diff(argv: Sequence[str]) -> int:
    parser = argparse.ArgumentParser(prog="gen_config.py diff", description="compare the Swift and Rust config dumps")
    parser.add_argument("--swift", type=Path, required=True)
    parser.add_argument("--rust", type=Path, required=True)
    parser.add_argument("--out", type=Path, help="write every divergence as JSONL here")
    parser.add_argument("--show", type=int, default=20, help="divergences and groups to print")
    args = parser.parse_args(argv)
    try:
        swift, rust = read_dump(args.swift, "swift"), read_dump(args.rust, "rust")
    except ConfigError as error:
        print(f"gen_config diff: {error}", file=sys.stderr)
        return 2
    records = diff_records(swift, rust)
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text("".join(json.dumps(r, ensure_ascii=False, sort_keys=True) + "\n" for r in records),
                            encoding="utf-8")
    files = sorted(swift.keys() | rust.keys())
    divergent = {r["file"] for r in records}
    print(f"config parity: {len(files)} files, {len(files) - len(divergent)} equal, "
          f"{len(divergent)} divergent, {len(records)} differences")
    for group, count in Counter(group_of(r["path"]) for r in records).most_common(args.show):
        print(f"  {count:6d}  {group}")
    for record in records[:args.show]:
        print("  " + json.dumps(record, ensure_ascii=False, sort_keys=True)[:400])
    return 1 if records else 0


def cmd_gen(argv: Sequence[str]) -> int:
    parser = argparse.ArgumentParser(prog="gen_config.py", description=__doc__.split("\n\n")[0])
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    parser.add_argument("--check", action="store_true", help="compare the corpus on disk to a fresh generation")
    args = parser.parse_args(argv)
    try:
        files = corpus()
    except ConfigError as error:
        print(f"gen_config: {error}", file=sys.stderr)
        return 2
    if args.check:
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        import corpus_store  # noqa: PLC0415 - sibling: the suite is written at use time, not committed

        if args.out.name == "config":
            corpus_store.ensure(args.out.parent, ["config"])
        problems = check_corpus(args.out, files)
        for problem in problems[:50]:
            print(problem)
        print(f"gen_config --check: {len(files)} files, {len(problems)} problems"
              + ("" if not problems else " (run scripts/cmux-next/oracle/gen_config.py)"))
        return 1 if problems else 0
    write_corpus(args.out, files)
    print(f"gen_config: wrote {len(files)} files to {args.out}")
    return 0


def main(argv: Optional[Sequence[str]] = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv[:1] == ["diff"]:
        return cmd_diff(argv[1:])
    return cmd_gen(argv)


if __name__ == "__main__":
    sys.exit(main())
