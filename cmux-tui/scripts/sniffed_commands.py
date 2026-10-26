"""Schema commands that a server module answers in its `try_handle` sniffer.

server/connection_frame.rs offers each control line to a chain of
`<module>::try_handle` sniffers before it parses a `Command`. A sniffer that
recognizes its `cmd` replies itself, so its commands have no `Command`
variant. Each command listed here has a sdk-schema.json entry (p05-ipc tasks
013-016, 018 and 019 add them); check-sdk-schema.py and
check-spec-inventory.py read the serving module instead of the enum:

- connection_frame.rs calls `<call>::try_handle(`;
- the module's `try_handle` matches the command's literal name;
- the request fields are the `fields.remove("<name>")` keys of that
  `try_handle` (except `cmd` and `id`), and they equal the schema's;
- `try_handle` refuses a non-Unix client (`if !mux.control_clients.is_unix(`)
  exactly when the schema authority is local-admin.

p05-ipc-017 replaces this table with a scan of every sniffer module.
"""

from __future__ import annotations

import re
from collections.abc import Iterable
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Server:
    """Where a sniffed command is served: a file in server/ and its call path."""

    file: str
    call: str


_AGENT_INVENTORY = Server("agent_inventory.rs", "agent_inventory")
_AGENT_INVENTORY_WATCH = Server("agent_inventory_watch.rs", "agent_inventory::watch")

SNIFFED_COMMANDS: dict[str, Server] = {
    "agent-inventory": _AGENT_INVENTORY,
    "agent-inventory-refresh": _AGENT_INVENTORY,
    "agent-inventory-watch": _AGENT_INVENTORY_WATCH,
}

# Envelope members every sniffer removes before it reads the request.
ENVELOPE_FIELDS = frozenset({"cmd", "id"})
_UNIX_GUARD = re.compile(r"if\s+!\s*mux\.control_clients\.is_unix\(")
_CHAR_LITERAL = re.compile(r"'(?:\\.|[^\\'])'")
_REMOVED_FIELD = re.compile(r'\bfields\s*\.\s*remove\(\s*"([A-Za-z0-9_]+)"\s*\)')


class SniffedCommandError(ValueError):
    pass


@dataclass(frozen=True)
class SniffedCommand:
    name: str
    server: Server
    fields: frozenset[str]
    local_admin: bool


def _code_only(source: str) -> str:
    """`source` without comments; strings and char literals are kept (no raw strings in sniffers)."""

    output: list[str] = []
    index = 0
    while index < len(source):
        char = source[index]
        literal = _CHAR_LITERAL.match(source, index) if char == "'" else None
        if literal:
            output.append(literal.group(0))
            index = literal.end()
        elif char == '"':
            end = index + 1
            while end < len(source) and source[end] != '"':
                end += 2 if source[end] == "\\" else 1
            output.append(source[index : end + 1])
            index = end + 1
        elif source.startswith("//", index):
            end = source.find("\n", index)
            index = len(source) if end < 0 else end
        elif source.startswith("/*", index):
            end = source.find("*/", index + 2)
            index = len(source) if end < 0 else end + 2
        else:
            output.append(char)
            index += 1
    return "".join(output)


def _function_body(source: str, name: str, label: str) -> str:
    match = re.search(rf"\bfn\s+{re.escape(name)}\s*\(", source)
    if match is None:
        raise SniffedCommandError(f"{label} has no fn {name}")
    start = source.find("{", match.end())
    depth = 0
    index = start
    while 0 <= index < len(source):
        char = source[index]
        literal = _CHAR_LITERAL.match(source, index) if char == "'" else None
        if literal:
            index = literal.end() - 1
        elif char == '"':
            index += 1
            while index < len(source) and source[index] != '"':
                index += 2 if source[index] == "\\" else 1
        elif char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return source[start + 1 : index]
        index += 1
    raise SniffedCommandError(f"{label}: unterminated fn {name}")


def _read(path: Path) -> str:
    try:
        return _code_only(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError) as error:
        raise SniffedCommandError(f"cannot read {path}: {error}") from error


def resolve(server_dir: Path, names: Iterable[str] | None = None) -> dict[str, SniffedCommand]:
    """The listed sniffed commands (all of them by default), read from `server_dir` (src/server)."""

    selected = SNIFFED_COMMANDS if names is None else {
        name: SNIFFED_COMMANDS[name] for name in names if name in SNIFFED_COMMANDS
    }
    if not selected:
        return {}
    chain = _read(server_dir / "connection_frame.rs")
    bodies: dict[Server, str] = {}
    resolved: dict[str, SniffedCommand] = {}
    for name, server in sorted(selected.items()):
        label = f"server/{server.file}"
        if not re.search(rf"(?<![A-Za-z0-9_:]){re.escape(server.call)}::try_handle\(", chain):
            raise SniffedCommandError(
                f"sniffed command {name}: server/connection_frame.rs never calls {server.call}::try_handle"
            )
        if server not in bodies:
            bodies[server] = _function_body(_read(server_dir / server.file), "try_handle", label)
        body = bodies[server]
        if f'Some("{name}")' not in body:
            raise SniffedCommandError(f'sniffed command {name}: {label} try_handle never matches Some("{name}")')
        fields = frozenset(_REMOVED_FIELD.findall(body)) - ENVELOPE_FIELDS
        resolved[name] = SniffedCommand(name, server, fields, bool(_UNIX_GUARD.search(body)))
    return resolved
