"""Commands a server handler module decodes before the daemon's `Command` enum.

server/connection_frame.rs hands a line whose `cmd` a feature route names
(server/routes.rs) to that route before the `Command` enum in server.rs. A
handler module serves a command when its production source has a route (a
`ROUTES` const) or a `try_handle` and an enum tagged
`#[serde(tag = "cmd")]` with that command as a variant: the enum is what the
handler decodes, so its variants are both the served wire names and the
request fields. A tuple variant's type is a struct of the same module, or
`crate::<path>::Type`, a struct of the file that path names (server/fs_wire.rs
decodes into `crate::fs_ops::ops::ReadParams`). A struct that flattens the
enum (`#[serde(flatten)] command: Command`) adds its other fields, apart from
the `id` every request carries, to every variant. check-sdk-schema.py and check-spec-inventory.py share this
one rule.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path


SERVER_DIR = Path("crates/cmux-tui-core/src/server")


class HandlerCommandError(ValueError):
    """A handler module's tagged command enum cannot be read."""


@dataclass(frozen=True)
class HandlerCommand:
    """One variant of a handler module's `cmd`-tagged enum."""

    name: str
    module: Path
    source: str
    enum: str
    variant: str
    # "unit", "tuple" (payload is the inner type) or "struct" (payload is the
    # field lines, one `name: Type,` per line, with their attributes).
    kind: str
    payload: str
    # The field lines of the struct that flattens the enum, without `id`.
    envelope: str


_TAGGED_ENUM = re.compile(r"(?m)^((?:#\[[^\n]*\]\n)+)(?:pub(?:\([a-z]+\))? )?enum (\w+) \{\n")
_UNIT = re.compile(r"    ([A-Z][A-Za-z0-9]*),")
# `Variant {},`: no fields, but unlike a unit variant it refuses unknown ones.
_EMPTY_STRUCT = re.compile(r"    ([A-Z][A-Za-z0-9]*) \{\},")
_TUPLE = re.compile(r"    ([A-Z][A-Za-z0-9]*)\(([A-Za-z0-9_:<>, ]+)\),")
_INLINE_STRUCT = re.compile(r"    ([A-Z][A-Za-z0-9]*) \{ (.*) \},")
_STRUCT = re.compile(r"    ([A-Z][A-Za-z0-9]*) \{")
_RENAME = re.compile(r'    #\[serde\(rename = "([^"]+)"\)\]')
_STRUCT_DECL = re.compile(r"(?m)^(?:pub(?:\([a-z]+\))? )?struct (\w+) \{\n")
# A module's route list (server/routes.rs): its typed handlers decode their lines.
_ROUTES = re.compile(r"(?m)^pub(?:\([^)]*\))? const ROUTES: ")


def production_source(path: Path) -> str:
    """The module source before its inline `mod tests`."""

    return path.read_text(encoding="utf-8").split("\n#[cfg(test)]\nmod tests", 1)[0]


def _kebab(name: str) -> str:
    return re.sub(r"(?<!^)([A-Z])", r"-\1", name).lower()


def _split_top_level_commas(text: str) -> list[str]:
    parts: list[str] = []
    depth = 0
    start = 0
    for index, char in enumerate(text):
        if char in "<([":
            depth += 1
        elif char in ">)]":
            depth -= 1
        elif char == "," and depth == 0:
            parts.append(text[start:index].strip())
            start = index + 1
    tail = text[start:].strip()
    if tail:
        parts.append(tail)
    return parts


def _variants(body: str, label: str, rename_all: str | None) -> list[tuple[str, str, str, str]]:
    """(wire name, variant, kind, payload) for each variant of an enum body."""

    variants: list[tuple[str, str, str, str]] = []
    rename: str | None = None
    lines = body.splitlines()
    index = 0
    while index < len(lines):
        line = lines[index]
        stripped = line.strip()
        index += 1
        if not stripped or stripped.startswith("//"):
            continue
        renamed = _RENAME.fullmatch(line)
        if renamed:
            rename = renamed.group(1)
            continue
        if stripped.startswith("#["):
            raise HandlerCommandError(f"cannot read attribute {stripped!r} in {label}")
        if unit := _UNIT.fullmatch(line):
            variant, kind, payload = unit.group(1), "unit", ""
        elif empty := _EMPTY_STRUCT.fullmatch(line):
            variant, kind, payload = empty.group(1), "struct", ""
        elif tuple_ := _TUPLE.fullmatch(line):
            variant, kind, payload = tuple_.group(1), "tuple", tuple_.group(2)
        elif inline := _INLINE_STRUCT.fullmatch(line):
            variant, kind = inline.group(1), "struct"
            payload = "\n".join(f"{field}," for field in _split_top_level_commas(inline.group(2)))
        elif structured := _STRUCT.fullmatch(line):
            variant, kind = structured.group(1), "struct"
            field_lines: list[str] = []
            while index < len(lines) and lines[index] != "    },":
                field_lines.append(lines[index])
                index += 1
            if index == len(lines):
                raise HandlerCommandError(f"unterminated variant {variant} in {label}")
            index += 1
            payload = "\n".join(field_lines)
        else:
            raise HandlerCommandError(f"cannot read variant line {stripped!r} in {label}")
        if rename is not None:
            name = rename
        elif rename_all == "kebab-case":
            name = _kebab(variant)
        elif rename_all is None:
            name = variant
        else:
            raise HandlerCommandError(f"unsupported rename_all {rename_all!r} in {label}")
        variants.append((name, variant, kind, payload))
        rename = None
    return variants


def _envelope(source: str, enum: str, label: str) -> str:
    """Field lines of the struct that flattens `enum`, without that field and `id`."""

    envelopes: list[str] = []
    for found in _STRUCT_DECL.finditer(source):
        end = source.find("\n}\n", found.end())
        if end < 0:
            continue
        lines = source[found.end():end].splitlines()
        kept: list[str] = []
        attributes: list[str] = []
        flattens = False
        for line in lines:
            stripped = line.strip()
            if not stripped or stripped.startswith("//"):
                continue
            if stripped.startswith("#["):
                attributes.append(line)
                continue
            field = re.fullmatch(r"(?:pub(?:\([a-z]+\))? )?(\w+): (.+),", stripped)
            if field and field.group(2) == enum and any("flatten" in a for a in attributes):
                flattens = True
            elif not (field and field.group(1) == "id"):
                kept.extend(attributes)
                kept.append(line)
            attributes = []
        if flattens:
            envelopes.append("\n".join(kept))
    if len(envelopes) > 1:
        raise HandlerCommandError(f"more than one struct flattens enum {enum} in {label}")
    return envelopes[0] if envelopes else ""


def module_commands(path: Path, label: str) -> list[HandlerCommand]:
    """The `cmd`-tagged enum variants of one handler module (none if it has no route
    and no `try_handle`)."""

    source = production_source(path)
    if "fn try_handle(" not in source and not _ROUTES.search(source):
        return []
    commands: list[HandlerCommand] = []
    for found in _TAGGED_ENUM.finditer(source):
        attributes, enum = found.groups()
        serde = re.search(r"#\[serde\(([^\n]*)\)\]", attributes)
        if serde is None or not re.search(r'\btag = "cmd"', serde.group(1)):
            continue
        rename_all = re.search(r'\brename_all = "([^"]+)"', serde.group(1))
        end = source.find("\n}\n", found.end())
        if end < 0:
            raise HandlerCommandError(f"cannot find the end of enum {enum} in {label}")
        envelope = _envelope(source, enum, label)
        for name, variant, kind, payload in _variants(
            source[found.end():end], f"{label} enum {enum}", rename_all and rename_all.group(1)
        ):
            commands.append(
                HandlerCommand(name, path, source, enum, variant, kind, payload, envelope)
            )
    return commands


def handler_commands(tui: Path) -> dict[str, HandlerCommand]:
    """Every command a handler module under `tui`'s server directory decodes."""

    server = tui / SERVER_DIR
    commands: dict[str, HandlerCommand] = {}
    if not server.is_dir():
        return commands
    for path in sorted(server.rglob("*.rs")):
        relative = path.relative_to(server)
        if path.name.endswith("_tests.rs") or "tests" in relative.parts[:-1]:
            continue
        for command in module_commands(path, f"server/{relative}"):
            earlier = commands.get(command.name)
            if earlier is not None:
                raise HandlerCommandError(
                    f"{command.name} is decoded by both {earlier.module.name} and {path.name}"
                )
            commands[command.name] = command
    return commands
