"""Wire names the server's sniffer modules serve (p05-ipc queue Q2).

A sniffer module reads a line's `cmd` before the `Command` enum in server.rs
sees it: today server/connection_frame.rs offers the line to each module's
`try_handle`, and line_connection.rs and websocket_listener.rs give it to
client_hello.rs's HelloGate. SNIFFER_MODULES lists them. Each one serves:

- each variant of its `#[serde(tag = "cmd")]` enums (handler_commands.py);
- each name it compares with the command name, as a string literal or a `&str`
  const: `cmd == "x"`, `cmd.eq(X)`, an arm of `match cmd { "x" if .. => }`,
  `matches!(cmd, "x" | "y")`, and `Some("x")` matched or compared against an
  expression that reads `"cmd"` (`cmd` or `command`, also as `&*cmd`,
  `cmd.as_str()` or `command.as_deref()`, is the command name);
- each name its feature route lists (server/routes.rs): `RouteName::Exact(x)`
  and the names of `RouteName::OneOf(&[x, y])`, `x` a literal or a `&str` const;
- the names of the list it matches by, for the modules in NAME_LISTS.

The scan reads source text, so it can miss a form it does not know. Two rules
make a miss fail: a listed module the scan finds no name in fails unless
NAMELESS_SNIFFERS says why, and for a module in server-module-commands.json
the scanned names must be the table's names.
"""

from __future__ import annotations

import json
import re
from collections.abc import Mapping, Set
from dataclasses import dataclass
from pathlib import Path

from handler_commands import SERVER_DIR, handler_commands, production_source


# Every module under server/ that reads `cmd` before the `Command` enum. A
# module with a `try_handle` must be here, and an entry whose file is gone
# fails, so a module keeps its coverage when it moves off `try_handle`.
SNIFFER_MODULES: frozenset[str] = frozenset(
    {
        "agent_cli_intents.rs",
        "agent_cli_job.rs",
        "agent_inventory.rs",
        "agent_inventory_watch.rs",
        "agent_session_attach.rs",
        "agent_session_observe.rs",
        "agent_transfer.rs",
        "agent_transfer/access_requests.rs",
        "agent_transfer/agent_update.rs",
        "apps.rs",
        "browser_runtime.rs",
        "client_hello.rs",
        "connection_frame/machine_catalog.rs",
        "debug_crash_inject.rs",
        "fs_wire.rs",
        "loopback_forward.rs",
        "page_router.rs",
        "scripts.rs",
    }
)

# Sniffer modules that serve no `cmd` name, and why.
NAMELESS_SNIFFERS: dict[str, str] = {
    "page_router.rs": "routes cmux.protocol/2 operations (spec/page-router.json), not a cmd",
}

# Modules that match the command against a name list defined elsewhere:
# module path under server/ -> (file under server/, const array name).
NAME_LISTS: dict[str, tuple[str, str]] = {
    # fs_wire.rs serves exactly the names fs_ops::frame_command accepts.
    "fs_wire.rs": ("../fs_ops.rs", "FS_COMMANDS"),
}

# The module table check-sdk-schema.py and check-spec-inventory.py read.
MODULE_TABLE = Path("scripts/server-module-commands.json")

_NAME = r"[a-z][a-z0-9]*(?:[-.][a-z0-9]+)*"
_PATH_CONST = r"(?<![\w:])(?:[a-z_][a-z0-9_]*::)*[A-Z][A-Z0-9_]*\b"
_VALUE = rf'(?:"{_NAME}"|{_PATH_CONST})'
_CONST = re.compile(
    rf'\bconst\s+([A-Z][A-Z0-9_]*)\s*:\s*&(?:\'static\s+)?str\s*=\s*"({_NAME})"\s*;'
)
_CHAR_LITERAL = re.compile(r"'(?:\\(?:u\{[0-9a-fA-F]+\}|x[0-9a-fA-F]{2}|.)|[^\\'\n])'")
_RAW_STRING = re.compile(r'(?<![\w"])b?r(#*)"')
# The command name as an expression: `cmd`, `&*cmd`, `command.as_deref()`, ...
_CMD = r"(?<![\w.])(?:[&*]\s*)*(?:cmd|command)\b(?:\s*\.\s*(?:as_str|as_ref|as_deref|deref)\(\))*"
_CMD_SCRUTINEE = re.compile(rf"\s*{_CMD}\s*")
_SOME_VALUE = rf"(?:Some\(\s*)?&?\s*({_VALUE})"
_CMD_COMPARISON = re.compile(
    rf"{_CMD}\s*[!=]=\s*{_SOME_VALUE}"
    rf"|(?<![\w.]){_SOME_VALUE}\s*\)?\s*[!=]=\s*{_CMD}"
    rf"|{_CMD}\s*\.\s*eq\(\s*&?\s*({_VALUE})\s*\)"
)
_CMD_FIELD_COMPARISON = re.compile(rf'"cmd"[^;{{}}]*?[!=]=\s*Some\(\s*({_VALUE})\s*\)')
_MATCH = re.compile(r"\bmatch\s+([^{};]+?)\s*\{")
_MATCHES = re.compile(r"\bmatches!\s*\(")
_ARM_VALUE = rf"(?:Some\(\s*{_VALUE}(?:\s*\|\s*{_VALUE})*\s*\)|{_VALUE})"
_ARM = re.compile(
    rf"(?<![\w.:\"])({_ARM_VALUE}(?:\s*\|\s*{_ARM_VALUE})*)\s*(?:\bif\b(?:(?!=>).)*?)?=>",
    re.DOTALL,
)
_VALUE_TOKEN = re.compile(rf'"({_NAME})"|({_PATH_CONST})')
_GUARD = re.compile(r"\bif\b")
# The names a module's feature route lists (server/routes.rs).
_ROUTE_EXACT = re.compile(rf"\bRouteName::Exact\(\s*({_VALUE})\s*\)")
_ROUTE_ONE_OF = re.compile(rf"\bRouteName::OneOf\(\s*&\s*\[([^\]]*)\]\s*\)")


class SnifferNameError(ValueError):
    """A sniffer module's served names cannot be read."""


@dataclass(frozen=True)
class SniffedName:
    """One wire name a sniffer module serves."""

    name: str
    # The module file, relative to server/ (posix).
    module: str


def _string_end(source: str, start: int) -> int:
    """The index just past the `"` literal that opens at `start`."""

    end = start + 1
    while end < len(source) and source[end] != '"':
        end += 2 if source[end] == "\\" else 1
    return end + 1


def code_only(source: str) -> str:
    """`source` without comments, every char literal as `' '` and every raw
    string as a plain one (empty unless it is a wire name), so no later scan
    sees a brace or quote inside a literal."""

    output: list[str] = []
    index = 0
    while index < len(source):
        char = source[index]
        raw = _RAW_STRING.match(source, index) if char in "br" else None
        literal = _CHAR_LITERAL.match(source, index) if char == "'" else None
        if raw:
            terminator = '"' + raw.group(1)
            end = source.find(terminator, raw.end())
            end = len(source) if end < 0 else end
            content = source[raw.end() : end]
            output.append(f'"{content}"' if re.fullmatch(_NAME, content) else '""')
            index = end + len(terminator)
        elif literal:
            output.append("' '")
            index = literal.end()
        elif char == '"':
            end = _string_end(source, index)
            output.append(source[index:end])
            index = end
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
    """The body of the `{` block at `start` in code_only text, with every
    nested `{}` block blanked."""

    depth = 0
    output: list[str] = []
    index = start
    while index < len(code):
        char = code[index]
        if char == '"':
            end = _string_end(code, index)
            if depth == 1:
                output.append(code[index:end])
            index = end
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


def _call_arguments(code: str, start: int) -> list[str]:
    """The top-level comma-separated arguments of the `(` call at `start`."""

    depth = 0
    arguments: list[str] = []
    current: list[str] = []
    index = start
    while index < len(code):
        char = code[index]
        if char == '"':
            end = _string_end(code, index)
            current.append(code[index:end])
            index = end
            continue
        if char in "([{":
            depth += 1
            if depth == 1:
                index += 1
                continue
        elif char in ")]}":
            depth -= 1
            if depth == 0:
                arguments.append("".join(current))
                return arguments
        if char == "," and depth == 1:
            arguments.append("".join(current))
            current = []
        else:
            current.append(char)
        index += 1
    raise SnifferNameError("unterminated matches!")


def str_consts(code: str) -> dict[str, str]:
    """The `const NAME: &str = "wire-name";` declarations of code_only text."""

    return dict(_CONST.findall(code))


class _Names:
    """Resolves compared values of one module to wire names."""

    def __init__(self, label: str, consts: Mapping[str, str], shared: Mapping[str, set[str]]):
        self.label = label
        self.consts = consts
        self.shared = shared
        self.names: set[str] = set()

    def add(self, token: str) -> None:
        literal, const = _VALUE_TOKEN.fullmatch(token.strip()).groups()
        if literal is not None:
            self.names.add(literal)
            return
        name = const.rpartition("::")[2]
        if name in self.consts:
            self.names.add(self.consts[name])
            return
        values = self.shared.get(name, set())
        if len(values) != 1:
            raise SnifferNameError(
                f"{self.label}: cannot resolve {const}, compared with the command name, "
                "to one &str const"
            )
        self.names |= values

    def add_all(self, text: str) -> None:
        for found in _VALUE_TOKEN.finditer(text):
            self.add(found.group(0))


def literal_names(
    source: str, label: str, shared: Mapping[str, set[str]] | None = None
) -> set[str]:
    """The names `source` compares with the command name (see the module
    doc). `shared` maps a const name to the values it has in other modules,
    for a const the module imports; a const that does not resolve fails."""

    code = code_only(source)
    names = _Names(label, str_consts(code), shared or {})
    for found in _CMD_COMPARISON.finditer(code):
        names.add(next(group for group in found.groups() if group is not None))
    for found in _CMD_FIELD_COMPARISON.finditer(code):
        names.add(found.group(1))
    for found in _ROUTE_EXACT.finditer(code):
        names.add(found.group(1))
    for found in _ROUTE_ONE_OF.finditer(code):
        names.add_all(found.group(1))
    for found in _MATCH.finditer(code):
        scrutinee = found.group(1)
        if not _CMD_SCRUTINEE.fullmatch(scrutinee) and '"cmd"' not in scrutinee:
            continue
        try:
            body = _block_top_level(code, found.end() - 1)
        except SnifferNameError as error:
            raise SnifferNameError(f"{label}: {error}") from error
        for arm in _ARM.finditer(body):
            names.add_all(arm.group(1))
    for found in _MATCHES.finditer(code):
        try:
            arguments = _call_arguments(code, found.end() - 1)
        except SnifferNameError as error:
            raise SnifferNameError(f"{label}: {error}") from error
        if len(arguments) < 2:
            continue
        scrutinee, pattern = arguments[0], ",".join(arguments[1:])
        if not _CMD_SCRUTINEE.fullmatch(scrutinee) and '"cmd"' not in scrutinee:
            continue
        names.add_all(_GUARD.split(pattern, 1)[0])
    return names.names


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


def _crate_consts(server: Path) -> dict[str, set[str]]:
    """Every `&str` const of the crate's production sources, by name."""

    consts: dict[str, set[str]] = {}
    for path in sorted(server.parent.rglob("*.rs")):
        if path.name.endswith("_tests.rs"):
            continue
        for name, value in str_consts(code_only(production_source(path))).items():
            consts.setdefault(name, set()).add(value)
    return consts


def _table_names(tui: Path, server: Path, modules: Set[str]) -> dict[str, set[str]]:
    """The names server-module-commands.json gives each module that exists:
    its literals and, with an `enum`, that module's handler_commands names."""

    path = tui / MODULE_TABLE
    if not path.exists():
        return {}
    try:
        specs = json.loads(path.read_text(encoding="utf-8")).get("modules", {})
    except (OSError, UnicodeError, ValueError) as error:
        raise SnifferNameError(f"cannot read {MODULE_TABLE}: {error}") from error
    decoded = handler_commands(tui)
    table: dict[str, set[str]] = {}
    for key, spec in specs.items():
        module = f"{key}.rs"
        if not (server / module).exists():
            continue
        if module not in modules:
            raise SnifferNameError(
                f"{MODULE_TABLE} lists server/{module}; add it to SNIFFER_MODULES"
            )
        names = set(spec.get("literals", {}))
        if "enum" in spec:
            names |= {
                name
                for name, command in decoded.items()
                if command.module.relative_to(server).as_posix() == module
            }
        table[module] = names
    return table


def sniffer_names(
    tui: Path,
    passed_on: Set[str] = frozenset(),
    modules: Set[str] = SNIFFER_MODULES,
    nameless: Mapping[str, str] = NAMELESS_SNIFFERS,
    name_lists: Mapping[str, tuple[str, str]] = NAME_LISTS,
) -> dict[str, SniffedName]:
    """Every wire name a sniffer module under `tui`'s server directory serves.

    `passed_on` names commands the `Command` enum serves: a table module may
    compare with them (client_hello.rs passes `identify` on) without the
    table listing them."""

    server = tui / SERVER_DIR
    served: dict[str, SniffedName] = {}
    by_module: dict[str, set[str]] = {module: set() for module in modules}

    def add(name: str, module: str) -> None:
        earlier = served.get(name)
        if earlier is not None and earlier.module != module:
            raise SnifferNameError(
                f"{name} is served by both server/{earlier.module} and server/{module}"
            )
        served[name] = SniffedName(name, module)
        by_module[module].add(name)

    def listed(module: str, why: str) -> None:
        if module not in modules:
            raise SnifferNameError(f"server/{module} {why}; add it to SNIFFER_MODULES")

    if not server.is_dir():
        return served
    for module in sorted(modules):
        if not (server / module).exists():
            raise SnifferNameError(f"SNIFFER_MODULES names server/{module}, which is gone")
    for module in sorted(set(nameless) - set(modules)):
        raise SnifferNameError(f"NAMELESS_SNIFFERS names server/{module}, not a sniffer module")
    for path in sorted(server.rglob("*.rs")):
        relative = path.relative_to(server)
        if path.name.endswith("_tests.rs") or "tests" in relative.parts[:-1]:
            continue
        if "fn try_handle(" in production_source(path):
            listed(relative.as_posix(), "has a try_handle")
    shared = _crate_consts(server)
    for module in sorted(modules):
        source = production_source(server / module)
        for name in sorted(literal_names(source, f"server/{module}", shared)):
            add(name, module)
    for name, command in sorted(handler_commands(tui).items()):
        module = command.module.relative_to(server).as_posix()
        listed(module, f"decodes {name}")
        add(name, module)
    for module, (relative, const) in sorted(name_lists.items()):
        listed(module, "is in NAME_LISTS")
        for name in sorted(_name_list(server, relative, const, f"server/{module}")):
            add(name, module)
    for module, names in sorted(by_module.items()):
        if not names and module not in nameless:
            raise SnifferNameError(
                f"server/{module} serves no name the scan can read: compare cmd with "
                "a literal or local const, or list it in NAMELESS_SNIFFERS with why"
            )
        if names and module in nameless:
            raise SnifferNameError(
                f"server/{module} serves {', '.join(sorted(names))}; drop it from "
                "NAMELESS_SNIFFERS"
            )
    for module, names in sorted(_table_names(tui, server, modules).items()):
        missed = sorted(names - by_module[module])
        if missed:
            raise SnifferNameError(
                f"{MODULE_TABLE} lists {', '.join(missed)} for server/{module}, "
                "which the scan does not find there"
            )
        unlisted = sorted(by_module[module] - names - set(passed_on))
        if unlisted:
            raise SnifferNameError(
                f"server/{module} serves {', '.join(unlisted)}, which {MODULE_TABLE} "
                "does not list for it"
            )
    return served
