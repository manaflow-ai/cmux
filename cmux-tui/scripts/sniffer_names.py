"""Wire names the server's sniffer modules serve (p05-ipc queue Q2).

server/connection_frame.rs offers each line to every server module that has a
`try_handle` before the `Command` enum in server.rs sees it. Such a module
serves:

- each variant of its `#[serde(tag = "cmd")]` enums (handler_commands.py);
- each name it compares with the command name, as a string literal or a `&str`
  const: `cmd == "x"`, `cmd != X`, an arm of `match cmd { "x" => .. }`, and
  `Some("x")` matched or compared against an expression that reads `"cmd"`;
- the names of the list it matches by, for the modules in NAME_LISTS (a
  listed module file that is gone serves nothing).

check-sdk-schema.py requires every one of these names in sdk-schema.json.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

from handler_commands import SERVER_DIR, handler_commands, production_source


# Modules that match the command against a name list defined elsewhere:
# module path under server/ -> (file under server/, const array name).
NAME_LISTS: dict[str, tuple[str, str]] = {
    # fs_wire.rs serves exactly the names fs_ops::frame_command accepts.
    "fs_wire.rs": ("../fs_ops.rs", "FS_COMMANDS"),
}

_NAME = r"[a-z][a-z0-9]*(?:[-.][a-z0-9]+)*"
_VALUE = rf'(?:"{_NAME}"|\b[A-Z][A-Z0-9_]*\b)'
_CONST = re.compile(
    rf'\bconst\s+([A-Z][A-Z0-9_]*)\s*:\s*&(?:\'static\s+)?str\s*=\s*"({_NAME})"\s*;'
)
_CHAR_LITERAL = re.compile(r"'(?:\\.|[^\\'])'")
_CMD_COMPARISON = re.compile(
    rf"\bcmd(?:\.as_str\(\))?\s*[!=]=\s*({_VALUE})|({_VALUE})\s*[!=]=\s*cmd\b"
)
_CMD_FIELD_COMPARISON = re.compile(rf'"cmd"[^;{{}}]*?[!=]=\s*Some\(\s*({_VALUE})\s*\)')
_MATCH = re.compile(r"\bmatch\s+([^{};]+?)\s*\{")
_ARM_VALUE = rf"(?:Some\(\s*{_VALUE}\s*\)|{_VALUE})"
_ARM = re.compile(rf"(?<![\w.:\"])({_ARM_VALUE}(?:\s*\|\s*{_ARM_VALUE})*)\s*=>")
_VALUE_TOKEN = re.compile(rf'"({_NAME})"|\b([A-Z][A-Z0-9_]*)\b')


class SnifferNameError(ValueError):
    """A sniffer module's served names cannot be read."""


@dataclass(frozen=True)
class SniffedName:
    """One wire name a sniffer module serves."""

    name: str
    # The module file, relative to server/ (posix).
    module: str


def code_only(source: str) -> str:
    """`source` without comments; string and char literals are kept."""

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


def _block_top_level(code: str, start: int) -> str:
    """The body of the `{` block at `start`, with every nested `{}` block blanked."""

    depth = 0
    output: list[str] = []
    index = start
    while index < len(code):
        char = code[index]
        if char == '"':
            end = index + 1
            while end < len(code) and code[end] != '"':
                end += 2 if code[end] == "\\" else 1
            if depth == 1:
                output.append(code[index : end + 1])
            index = end + 1
            continue
        if char == "{":
            depth += 1
            if depth == 1:
                index += 1
                continue
        elif char == "}":
            depth -= 1
            if depth == 0:
                return "".join(output)
        output.append(char if depth == 1 else " ")
        index += 1
    raise SnifferNameError("unterminated match block")


def _resolve(token: str, consts: dict[str, str]) -> str | None:
    found = _VALUE_TOKEN.fullmatch(token.strip())
    if found is None:
        return None
    literal, const = found.groups()
    return literal if literal is not None else consts.get(const)


def _values(text: str, consts: dict[str, str]) -> set[str]:
    names: set[str] = set()
    for literal, const in _VALUE_TOKEN.findall(text):
        name = literal or consts.get(const)
        if name is not None:
            names.add(name)
    return names


def literal_names(source: str, label: str) -> set[str]:
    """The names `source` compares with the command name (see the module doc)."""

    code = code_only(source)
    consts = dict(_CONST.findall(code))
    names: set[str] = set()
    for found in _CMD_COMPARISON.finditer(code):
        name = _resolve(found.group(1) or found.group(2), consts)
        if name is not None:
            names.add(name)
    for found in _CMD_FIELD_COMPARISON.finditer(code):
        name = _resolve(found.group(1), consts)
        if name is not None:
            names.add(name)
    for found in _MATCH.finditer(code):
        scrutinee = found.group(1).strip()
        if scrutinee not in {"cmd", "cmd.as_str()"} and '"cmd"' not in scrutinee:
            continue
        try:
            body = _block_top_level(code, found.end() - 1)
        except SnifferNameError as error:
            raise SnifferNameError(f"{label}: {error}") from error
        for arm in _ARM.finditer(body):
            names |= _values(arm.group(1), consts)
    return names


def _name_list(server: Path, relative: str, const: str, label: str) -> set[str]:
    path = (server / relative).resolve()
    try:
        code = code_only(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError) as error:
        raise SnifferNameError(f"{label}: cannot read {relative}: {error}") from error
    found = re.search(
        rf"\bconst\s+{re.escape(const)}\s*:\s*\[&(?:'static\s+)?str;\s*\d+\]\s*=\s*\[([^\]]*)\]",
        code,
    )
    if found is None:
        raise SnifferNameError(f"{label}: {relative} has no const {const}: [&str; N]")
    names = set(re.findall(rf'"({_NAME})"', found.group(1)))
    if not names:
        raise SnifferNameError(f"{label}: {relative} {const} lists no names")
    return names


def sniffer_names(tui: Path) -> dict[str, SniffedName]:
    """Every wire name a sniffer module under `tui`'s server directory serves."""

    server = tui / SERVER_DIR
    served: dict[str, SniffedName] = {}

    def add(name: str, module: str) -> None:
        earlier = served.get(name)
        if earlier is not None and earlier.module != module:
            raise SnifferNameError(
                f"{name} is served by both server/{earlier.module} and server/{module}"
            )
        served[name] = SniffedName(name, module)

    if not server.is_dir():
        return served
    sniffers: set[str] = set()
    for path in sorted(server.rglob("*.rs")):
        relative = path.relative_to(server)
        if path.name.endswith("_tests.rs") or "tests" in relative.parts[:-1]:
            continue
        source = production_source(path)
        if "fn try_handle(" not in source:
            continue
        module = relative.as_posix()
        sniffers.add(module)
        for name in sorted(literal_names(source, f"server/{module}")):
            add(name, module)
    for name, command in sorted(handler_commands(tui).items()):
        add(name, command.module.relative_to(server).as_posix())
    for module, (relative, const) in sorted(NAME_LISTS.items()):
        # A module file that is gone serves nothing.
        if not (server / module).exists():
            continue
        if module not in sniffers:
            raise SnifferNameError(f"NAME_LISTS names server/{module}, which has no try_handle")
        for name in sorted(_name_list(server, relative, const, f"server/{module}")):
            add(name, module)
    return served
