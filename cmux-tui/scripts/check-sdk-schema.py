#!/usr/bin/env python3
"""Reject drift between the runtime inventory and the language-neutral SDK IR."""

from __future__ import annotations

import json
import re
import sys
from collections.abc import Mapping
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
TUI = ROOT / "cmux-tui"
SPEC = TUI / "spec"
BINDINGS = TUI / "bindings"
SERVER = TUI / "crates/cmux-tui-core/src/server.rs"
RUNTIME_NAMED_REQUEST_REFS = {
    "crate::conversation_store::ImportedMessage": "ConversationImportMessage",
    "BrowserProviderTargetRequest": "BrowserProviderTarget",
    "crate::FrontendJournalEvent": "FrontendJournalEvent",
    "crate::ResourceSelectors": "ResourceSelectors",
    "ProtocolKeyInput": "TerminalKeyInput",
    "TabRef": "TabRef",
    "PaneRef": "PaneRef",
    "DetachClientTarget": "DetachClientTarget",
    "TerminalDetachActor": "SizeDetachActor",
    "TerminalSizingPolicy": "SizePolicy",
    "HostSizePolicyRequest": "HostSizePolicyRequest",
    "ClientIdentityWire": "SizingIdentity",
    "SplitRespawnRequest": "SplitRespawn",
    "crate::mux::CloseReason": "CloseReason",
    "crate::resource_name::NameSource": "NameSource",
    "AgentSessionParams": "AgentSessionSource",
    "ConversationTabSplitParams": "ConversationTabSplit",
    "crate::model::ColumnDock": "ColumnPin",
    "SnapshotHave": "SnapshotRequestHave",
    "RowMarkerPoint": "RowMarkerPoint",
    "RowHeight": "RowHeight",
    "ExpectAgent": "SendExpectAgent",
    "crate::apps::Origin": "AppOrigin",
    "crate::apps::HiddenAccess": "AppHiddenAccess",
    "GrantParam": "AppGrant",
    "AgentCLIIntent": "AgentCLIIntent",
    "AgentSessionAnsweredBy": "AgentSessionAnsweredBy",
}

# Named request types whose server struct is the authority for their fields:
# the SDK object type of the same name must have the same fields, checked like
# a command's request fields. Paths are under crates/cmux-tui-core/src.
RUNTIME_NAMED_REQUEST_STRUCTS = {
    "AgentCLIIntent": "workspace_registry/agent_cli_intents.rs",
    "AgentSessionAnsweredBy": "server/agent_session_attach.rs",
}


# Server modules that decode their own commands (p05-ipc queue Q2). One table
# for this checker and check-spec-inventory.py; its description names each key.
MODULE_COMMANDS_PATH = Path(__file__).with_name("server-module-commands.json")


def module_commands() -> dict[str, dict[str, Any]]:
    modules = json.loads(MODULE_COMMANDS_PATH.read_text(encoding="utf-8")).get("modules")
    if not isinstance(modules, dict):
        fail(f"{MODULE_COMMANDS_PATH.name} needs a modules object")
    return modules


# Request fields the server takes as raw JSON and then decodes element by
# element into a named type, so a bad element gets the command's own error
# code. The SDK types the field as that named type; the server struct named
# in the comment is the authority for its fields.
RUNTIME_DECODED_REQUEST_FIELDS = {
    # server/bookmarks.rs `import` decodes each node into
    # workspace_registry/personal_bookmarks.rs `BookmarkImportNode`.
    ("import-bookmarks", "nodes"): ("Vec<Value>", "array<ref<BookmarkImportNode>>"),
    # workspace_registry/agent_cli_intents.rs `normalize_receipt` accepts only
    # the receipt agent-cli-update-job returned.
    ("agent-cli-intents-attach", "receipt"): ("Value", "ref<AgentCLIJobReceipt>"),
}

# Names a sniffer module serves (sniffer_names.py) that sdk-schema.json does
# not describe yet, each with the task that adds it or why it stays out. Any
# other unschema'd served name fails. An entry that is in the schema or no
# longer served only prints a note, so the task that schemas a name can land
# before or after this list drops it.
UNSCHEMAD_SNIFFED_COMMANDS = {
    **dict.fromkeys(
        ("agent-inventory", "agent-inventory-refresh", "agent-inventory-watch"),
        "p05-ipc-015",
    ),
    **dict.fromkeys(
        (
            "browser-runtime-start",
            "browser-runtime-status",
            "browser-runtime-stop",
            "client-hello",
            "loopback-close",
            "loopback-credit",
            "loopback-data",
            "loopback-open",
            "loopback-shutdown",
            "loopback-status",
            "machine-catalog-publish",
        ),
        "p05-ipc-016",
    ),
    **dict.fromkeys(
        (
            "agent-session-attach",
            "agent-session-cancel",
            "agent-session-children",
            "agent-session-detach",
            "agent-session-events",
            "agent-session-media",
            "agent-session-observe",
            "agent-session-permission",
            "agent-session-prompt",
            "agent-session-start",
            "agent-session-trust",
        ),
        "p05-ipc-018",
    ),
    **dict.fromkeys(
        (
            "access-request",
            "access-request-answer",
            "access-request-list",
            "access-request-status",
            "agent-transfer-abort",
            "agent-transfer-begin",
            "agent-transfer-commit",
            "agent-transfer-finish",
            "agent-transfer-read",
            "agent-transfer-receive",
            "agent-transfer-receive-abort",
            "agent-transfer-source",
            "agent-transfer-write",
            "agent-update-apply",
            "agent-update-plan",
            "fs.delete",
            "fs.list",
            "fs.mkdir",
            "fs.read",
            "fs.rename",
            "fs.stat",
            "fs.write",
            "script-repl-close",
            "script-repl-eval",
            "script-repl-open",
            "script-run",
        ),
        "p05-ipc-019",
    ),
    "oracle-state": "debug and --features oracle builds only (p15-oracle-021), not an SDK command",
}

sys.path.insert(0, str(BINDINGS))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from codegen.ir import SdkIR, load_ir, load_ir_document  # noqa: E402
from handler_commands import HandlerCommandError, handler_commands  # noqa: E402
from sniffer_names import SniffedName, SnifferNameError, sniffer_names  # noqa: E402


class SdkSchemaError(ValueError):
    pass


class RuntimeField:
    """One top-level request field decoded by the Rust protocol server."""

    __slots__ = ("rust_type", "attributes")

    def __init__(self, rust_type: str, attributes: tuple[str, ...]) -> None:
        self.rust_type = rust_type
        self.attributes = attributes


def fail(message: str) -> None:
    raise SdkSchemaError(message)


def _reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            fail(f"duplicate JSON object key {key!r}")
        value[key] = item
    return value


def load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=_reject_duplicate_keys,
        )
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        fail(f"cannot load {path.relative_to(ROOT)}: {error}")
    if not isinstance(value, dict):
        fail(f"{path.relative_to(ROOT)} must contain a JSON object")
    return value


def inventory_commands(inventory: Mapping[str, Any]) -> dict[str, str]:
    commands: dict[str, str] = {}
    for profile, names in inventory["commands"].items():
        for name in names:
            if name in commands:
                fail(f"inventory command {name!r} appears in more than one profile")
            commands[name] = profile
    return commands


def inventory_events(inventory: Mapping[str, Any]) -> dict[str, Mapping[str, Any]]:
    events: dict[str, Mapping[str, Any]] = {}
    for event in inventory["events"]:
        name = event["name"]
        if name in events:
            fail(f"inventory event {name!r} appears more than once")
        events[name] = event
    return events


def compare_names(actual: set[str], expected: set[str], label: str) -> None:
    missing = sorted(expected - actual)
    stale = sorted(actual - expected)
    if missing or stale:
        details: list[str] = []
        if missing:
            details.append(f"missing: {', '.join(missing)}")
        if stale:
            details.append(f"stale: {', '.join(stale)}")
        fail(f"{label} drift, {'; '.join(details)}")


def camel_to_kebab(name: str) -> str:
    return re.sub(r"(?<!^)(?=[A-Z])", "-", name).lower()


def _rust_enum_body(source: str, name: str) -> str:
    match = re.search(rf"(?m)^enum {re.escape(name)} \{{\n", source)
    if not match:
        fail(f"cannot find Rust enum {name}")
    start = match.end()
    end = source.find("\n}\n", start)
    if end < 0:
        fail(f"cannot find end of Rust enum {name}")
    return source[start:end]


def _rust_struct_fields(source: str, name: str) -> dict[str, RuntimeField]:
    match = re.search(
        rf"(?m)^(?:pub(?:\([a-z:]+\))? )?struct {re.escape(name)} \{{\n", source
    )
    if not match:
        fail(f"cannot find Rust struct {name}")
    start = match.end()
    end = source.find("\n}\n", start)
    if end < 0:
        fail(f"cannot find end of Rust struct {name}")
    return _parse_rust_fields(source[start:end], f"Rust struct {name}")


def _parse_rust_fields(body: str, label: str) -> dict[str, RuntimeField]:
    fields: dict[str, RuntimeField] = {}
    attributes: list[str] = []
    for raw_line in body.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("///") or line.startswith("//"):
            continue
        attribute = re.fullmatch(r"#\[serde\((.*)\)\]", line)
        if attribute:
            attributes.append(attribute.group(1))
            continue
        # Field visibility (pub, pub(crate), pub(super), pub(in path)) does not change the wire shape.
        field = re.fullmatch(r"(?:pub(?:\((?:crate|super|self|in [a-z_:]+)\))? )?([a-z][A-Za-z0-9_]*): (.+),", line)
        if not field:
            fail(f"cannot parse {label} line {line!r}")
        name, rust_type = field.groups()
        if name in fields:
            fail(f"duplicate {label} field {name!r}")
        fields[name] = RuntimeField(rust_type, tuple(attributes))
        attributes.clear()
    if attributes:
        fail(f"orphan serde attributes in {label}")
    return fields


def runtime_command_fields() -> dict[str, dict[str, RuntimeField]]:
    """Extract request fields from the server's authoritative Deserialize enum."""

    try:
        source = SERVER.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        fail(f"cannot read {SERVER.relative_to(ROOT)}: {error}")
    body = _rust_enum_body(source, "Command")
    commands: dict[str, dict[str, RuntimeField]] = {}
    lines = body.splitlines()
    index = 0
    while index < len(lines):
        line = lines[index]
        unit = re.fullmatch(r"    ([A-Z][A-Za-z0-9]*),", line)
        if unit:
            commands[camel_to_kebab(unit.group(1))] = {}
            index += 1
            continue
        boxed = re.fullmatch(
            r"    ([A-Z][A-Za-z0-9]*)\(Box<([A-Z][A-Za-z0-9]*)>\),",
            line,
        )
        if boxed:
            variant, request_type = boxed.groups()
            commands[camel_to_kebab(variant)] = _rust_struct_fields(source, request_type)
            index += 1
            continue
        # A request struct in a handler module: `Variant(module::Params)`
        # reads `server/<module>.rs`.
        external = re.fullmatch(
            r"    ([A-Z][A-Za-z0-9]*)\(([a-z_]+)::([A-Z][A-Za-z0-9]*)\),",
            line,
        )
        if external:
            variant, module, request_type = external.groups()
            module_path = SERVER.with_suffix("") / f"{module}.rs"
            try:
                module_source = module_path.read_text(encoding="utf-8")
            except (OSError, UnicodeError) as error:
                fail(f"cannot read {module_path.relative_to(ROOT)}: {error}")
            commands[camel_to_kebab(variant)] = _expand_flattened(
                module_source,
                _rust_struct_fields(module_source, request_type),
                f"Command::{variant}",
            )
            index += 1
            continue
        structured = re.fullmatch(r"    ([A-Z][A-Za-z0-9]*) \{", line)
        if not structured:
            if line.strip() and not line.strip().startswith(("///", "//")):
                fail(f"cannot parse Rust Command line {line.strip()!r}")
            index += 1
            continue
        variant = structured.group(1)
        variant_lines: list[str] = []
        index += 1
        while index < len(lines) and lines[index] != "    },":
            variant_lines.append(lines[index])
            index += 1
        if index == len(lines):
            fail(f"unterminated Rust Command variant {variant}")
        parsed = _parse_rust_fields(
            "\n".join(variant_lines),
            f"Rust Command::{variant}",
        )
        commands[camel_to_kebab(variant)] = _expand_flattened(
            source, parsed, f"Command::{variant}"
        )
        index += 1
    for name, fields in module_command_fields().items():
        if name in commands:
            fail(f"command {name!r} is in the server Command enum and a module")
        commands[name] = fields
    return commands


def _without_reply_id(fields: dict[str, RuntimeField]) -> dict[str, RuntimeField]:
    return {name: field for name, field in fields.items() if name != "id"}


def module_command_fields() -> dict[str, dict[str, RuntimeField]]:
    """Request fields of the commands server-module-commands.json lists. A
    module file that is gone serves nothing, so its schema commands become
    stale."""

    commands: dict[str, dict[str, RuntimeField]] = {}
    for module, spec in module_commands().items():
        path = SERVER.with_suffix("") / f"{module}.rs"
        if not path.exists():
            continue
        source = path.read_text(encoding="utf-8").split("\n#[cfg(test)]\nmod tests", 1)[0]
        label = f"server/{module}.rs"
        found = _module_enum_commands(source, spec, label) if "enum" in spec else {}
        for name, literal in spec.get("literals", {}).items():
            if f'"{name}"' not in source:
                fail(f"{label} no longer matches {name!r}")
            if name in found:
                fail(f"module command {name!r} is served twice")
            found[name] = _module_literal_fields(source, name, literal, label)
        for name, fields in found.items():
            if name in commands:
                fail(f"module command {name!r} is served twice")
            commands[name] = fields
    return commands


def _module_enum_commands(
    source: str, spec: Mapping[str, Any], label: str
) -> dict[str, dict[str, RuntimeField]]:
    """Request fields of a module's `cmd`-tagged enum, envelope fields included."""

    envelope = {
        name: field
        for name, field in _without_reply_id(_rust_struct_fields(source, spec["envelope"])).items()
        if not any(re.search(r"\bflatten\b", value) for value in field.attributes)
    }
    enum_name = spec["enum"]
    refused_fields = {
        name: set(fields) for name, fields in spec.get("refused_envelope_fields", {}).items()
    }
    found = _module_enum_fields(_rust_enum_body(source, enum_name), f"{label} {enum_name}")
    for name in refused_fields:
        if name not in found:
            fail(f"{label}: refused envelope fields name unknown command {name!r}")
    for name, fields in found.items():
        shared = {
            key: field
            for key, field in envelope.items()
            if key not in refused_fields.get(name, set())
        }
        duplicate = sorted(set(fields) & set(shared))
        if duplicate:
            fail(f"{label} {name} repeats envelope fields {duplicate}")
        found[name] = {**fields, **shared}
    return found


def _module_literal_fields(
    source: str, name: str, literal: Mapping[str, Any], label: str
) -> dict[str, RuntimeField]:
    """Request fields of a command a module matches by name. The module must
    decode the listed struct for it: the literal's match arm builds `variant`
    and that variant holds the struct, or the handler calls
    `from_value::<Struct>`. `module::Struct` is in server/<module>.rs."""

    request = literal["request"]
    struct_module, _, struct_name = request.rpartition("::")
    variant = literal.get("variant")
    if variant is not None:
        enum_name, _, variant_name = variant.partition("::")
        arm = rf'"{re.escape(name)}"\s*=>\s*(?:Self|{re.escape(enum_name)})::{re.escape(variant_name)}\('
        if not re.search(arm, source):
            fail(f"{label} no longer decodes {name!r} as {variant}")
        payload = re.search(
            rf"(?m)^    {re.escape(variant_name)}\((?:[a-z_]+::)*(\w+)\),$",
            _rust_enum_body(source, enum_name),
        )
        decoded = payload.group(1) if payload else None
    else:
        body = _rust_function_body(source, literal["handler"], label)
        decodes = re.findall(r"from_value::<(?:[a-z_]+::)*(\w+)>\(", body)
        decoded = decodes[0] if len(decodes) == 1 else None
    if decoded != struct_name:
        fail(f"{label} decodes {name!r} as {decoded or 'no single struct'}, not {request}")
    struct_source = source
    if struct_module:
        module_path = SERVER.with_suffix("") / f"{struct_module}.rs"
        try:
            struct_source = module_path.read_text(encoding="utf-8")
        except (OSError, UnicodeError) as error:
            fail(f"cannot read {module_path.relative_to(ROOT)}: {error}")
    return _without_reply_id(
        _expand_flattened(
            struct_source, _rust_struct_fields(struct_source, struct_name), f"{label} {name}"
        )
    )


def _rust_function_body(source: str, name: str, label: str) -> str:
    """The text between a function's braces (brace count; the handlers this
    reads have no unbalanced brace in a string)."""

    match = re.search(rf"(?m)^(?:pub(?:\([a-z]+\))? )?fn {re.escape(name)}\(", source)
    if not match:
        fail(f"cannot find fn {name} in {label}")
    start = source.find("{", match.end())
    depth = 0
    for index in range(start, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[start + 1:index]
    fail(f"unterminated fn {name} in {label}")
    return ""


def _module_enum_fields(body: str, label: str) -> dict[str, dict[str, RuntimeField]]:
    """Variants of a module's `#[serde(tag = "cmd")]` enum by serde rename:
    unit, one-line `V { a: T }` and multi-line struct variants."""

    commands: dict[str, dict[str, RuntimeField]] = {}
    rename: str | None = None
    lines = body.splitlines()
    index = 0
    while index < len(lines):
        line = lines[index].strip()
        index += 1
        if not line or line.startswith("//"):
            continue
        attribute = re.fullmatch(r'#\[serde\(rename\s*=\s*"([a-z][a-z0-9-]*)"\)\]', line)
        if attribute:
            rename = attribute.group(1)
            continue
        unit = re.fullmatch(r"([A-Z][A-Za-z0-9]*),", line)
        one_line = re.fullmatch(r"([A-Z][A-Za-z0-9]*) \{ (.+) \},", line)
        multi_line = re.fullmatch(r"([A-Z][A-Za-z0-9]*) \{", line)
        if unit:
            variant, fields = unit.group(1), {}
        elif one_line:
            variant = one_line.group(1)
            parts = re.split(r",\s*(?=[a-z][A-Za-z0-9_]*:)", one_line.group(2))
            fields = _parse_rust_fields(
                "\n".join(part.rstrip(",") + "," for part in parts), f"{label}::{variant}"
            )
        elif multi_line:
            variant = multi_line.group(1)
            variant_lines: list[str] = []
            while index < len(lines) and lines[index].strip() != "},":
                variant_lines.append(lines[index])
                index += 1
            if index == len(lines):
                fail(f"unterminated {label}::{variant}")
            index += 1
            fields = _parse_rust_fields("\n".join(variant_lines), f"{label}::{variant}")
        else:
            fail(f"cannot parse {label} line {line!r}")
        if rename is None:
            fail(f"{label}::{variant} needs #[serde(rename = ...)]")
        if rename in commands:
            fail(f"duplicate {label} command {rename!r}")
        commands[rename] = fields
        rename = None
    return commands


def handler_command_fields(names: set[str]) -> dict[str, dict[str, RuntimeField]]:
    """Request fields of the `names` a handler module decodes before the
    Command enum (handler_commands.py); names no handler decodes are left out,
    and so are the modules server-module-commands.json lists, whose fields
    module_command_fields reads."""

    try:
        decoded = handler_commands(TUI)
    except (HandlerCommandError, OSError, UnicodeError) as error:
        fail(f"cannot read the handler modules: {error}")
    listed = {SERVER.with_suffix("") / f"{module}.rs" for module in module_commands()}
    commands: dict[str, dict[str, RuntimeField]] = {}
    for name in sorted(names & set(decoded)):
        command = decoded[name]
        if command.module in listed:
            continue
        label = f"{command.module.name} {command.enum}::{command.variant}"
        if command.kind == "unit":
            fields: dict[str, RuntimeField] = {}
        elif command.kind == "tuple":
            fields = _rust_struct_fields(command.source, command.payload)
        else:
            fields = _parse_rust_fields(command.payload, label)
        envelope = _parse_rust_fields(command.envelope, f"{label} envelope")
        overlap = set(envelope) & set(fields)
        if overlap:
            fail(f"{label} repeats envelope fields {sorted(overlap)}")
        commands[name] = _expand_flattened(command.source, {**envelope, **fields}, label)
    return commands


def _expand_flattened(
    source: str, parsed: dict[str, RuntimeField], label: str
) -> dict[str, RuntimeField]:
    """Replace each `#[serde(flatten)]` field by the fields of its struct,
    which must be declared in the same Rust source."""

    expanded: dict[str, RuntimeField] = {}
    for field_name, field in parsed.items():
        if any(re.search(r"\bflatten\b", value) for value in field.attributes):
            # `module::Type` names a request struct in `server/<module>.rs`.
            flat_source, flat_type = source, field.rust_type
            qualified = re.fullmatch(r"([a-z_]+)::([A-Z][A-Za-z0-9]*)", field.rust_type)
            if qualified:
                module_path = SERVER.with_suffix("") / f"{qualified.group(1)}.rs"
                try:
                    flat_source = module_path.read_text(encoding="utf-8")
                except (OSError, UnicodeError) as error:
                    fail(f"cannot read {module_path.relative_to(ROOT)}: {error}")
                flat_type = qualified.group(2)
            if not re.fullmatch(r"[A-Z][A-Za-z0-9]*", flat_type) or not re.search(
                rf"(?m)^(?:pub(?:\([a-z:]+\))? )?struct {re.escape(flat_type)} \{{",
                flat_source,
            ):
                fail(f"unsupported flattened Rust request type {field.rust_type!r} in {label}")
            for flat_name, flat_field in _rust_struct_fields(flat_source, flat_type).items():
                if flat_name in expanded:
                    fail(f"duplicate flattened request field {flat_name!r} in {label}")
                expanded[flat_name] = flat_field
        else:
            if field_name in expanded:
                fail(f"duplicate request field {field_name!r} in {label}")
            expanded[field_name] = field
    return expanded


def _unwrap_rust_option(rust_type: str) -> tuple[str, bool]:
    match = re.fullmatch(r"Option<(.+)>", rust_type)
    return (match.group(1), True) if match else (rust_type, False)


def _runtime_field_presence(field: RuntimeField) -> tuple[str, bool]:
    rust_type, optional_type = _unwrap_rust_option(field.rust_type)
    # An `Option<T>` with the `required_nullable` deserializer must be present
    # and may be null.
    if optional_type and any("required_nullable" in value for value in field.attributes):
        return "required", True
    has_default = any(re.search(r"\bdefault\b", value) for value in field.attributes)
    presence = "optional" if optional_type or has_default else "required"
    # serde_json::Value includes JSON null even though it is not Option<Value>.
    nullable = optional_type or rust_type == "Value"
    return presence, nullable


def _runtime_field_aliases(field: RuntimeField) -> set[str]:
    aliases: set[str] = set()
    for attribute in field.attributes:
        aliases.update(re.findall(r'\balias\s*=\s*"([^"]+)"', attribute))
    return aliases


def _split_rust_generic(value: str, name: str) -> str | None:
    prefix = f"{name}<"
    return value[len(prefix) : -1] if value.startswith(prefix) and value.endswith(">") else None


def _runtime_type_shape(rust_type: str) -> str:
    rust_type, optional = _unwrap_rust_option(rust_type)
    # `Option<Option<T>>` with a present-or-null deserializer is an optional
    # nullable T on the wire.
    while optional:
        rust_type, optional = _unwrap_rust_option(rust_type)
    if inner := _split_rust_generic(rust_type, "Vec"):
        return f"array<{_runtime_type_shape(inner)}>"
    if inner := _split_rust_generic(rust_type, "BTreeMap"):
        key, separator, value = inner.partition(", ")
        if not separator or key != "String":
            fail(f"unsupported Rust map request type {rust_type!r}")
        return f"map<{_runtime_type_shape(value)}>"
    if sdk_type := RUNTIME_NAMED_REQUEST_REFS.get(rust_type):
        return f"ref<{sdk_type}>"
    scalars = {
        "String": "string",
        "bool": "boolean",
        "i32": "int32",
        "u16": "uint16",
        "u32": "uint32",
        "isize": "int64",
        "usize": "uint64",
        "u64": "uint64",
        "f32": "float32",
        "f64": "float64",
        "Value": "opaque-json",
        "LayoutRequest": "declarative-layout",
        "SurfaceId": "uint64",
        "PaneId": "uint64",
        "SplitId": "uint64",
        "ScreenId": "uint64",
        "WorkspaceId": "uint64",
    }
    try:
        return scalars[rust_type]
    except KeyError:
        fail(f"unsupported Rust request type {rust_type!r}")
    return ""


def _schema_type_shape(
    expression: Mapping[str, Any],
    types: Mapping[str, Any],
    seen: frozenset[str] = frozenset(),
) -> str:
    kind = expression["kind"]
    if kind == "scalar":
        return str(expression["name"])
    if kind == "literal":
        value = expression["value"]
        if isinstance(value, bool):
            return "boolean"
        if isinstance(value, str):
            return "string"
        if isinstance(value, int):
            return "int64"
        if isinstance(value, float):
            return "float64"
        return "opaque-json"
    if kind == "enum":
        values = expression["values"]
        if all(isinstance(value, str) for value in values):
            return "string"
        if all(isinstance(value, bool) for value in values):
            return "boolean"
        return "int64"
    if kind == "array":
        return f"array<{_schema_type_shape(expression['items'], types, seen)}>"
    if kind == "map":
        return f"map<{_schema_type_shape(expression['values'], types, seen)}>"
    if kind == "opaque_json":
        return "opaque-json"
    if kind == "alias":
        return _schema_type_shape(expression["target"], types, seen)
    if kind == "ref":
        name = str(expression["name"])
        if name == "DeclarativeLayout":
            return "declarative-layout"
        if name in RUNTIME_NAMED_REQUEST_REFS.values() or any(
            f"ref<{name}>" in shape for _, shape in RUNTIME_DECODED_REQUEST_FIELDS.values()
        ):
            return f"ref<{name}>"
        if name in seen:
            fail(f"cyclic SDK type reference while checking Rust request field: {name}")
        target = types.get(name)
        if not isinstance(target, Mapping):
            fail(f"unknown SDK request field type reference {name!r}")
        return _schema_type_shape(target, types, seen | {name})
    fail(f"unsupported SDK request field type kind {kind!r}")
    return ""


# Fields the server reads only to refuse them with invalid-argument: a
# pre-rename name an older client may still send. They are not part of the
# SDK contract, so the SDKs never send them.
REFUSED_LEGACY_REQUEST_FIELDS = {
    # R87 DOCK-WIRE: `sticky` was renamed to `dock`; ignoring it would turn an
    # older client's pin into a plain column.
    "move-tab-to-column": {"sticky"},
}


def validate_runtime_request_fields(ir: SdkIR) -> None:
    """Reject request-field drift against the server's Deserialize contract."""

    runtime_commands = runtime_command_fields()
    for name, fields in handler_command_fields(set(ir.commands)).items():
        if name in runtime_commands:
            fail(f"{name} is both a Command variant and a handler module command")
        runtime_commands[name] = fields
    for command_name, refused in REFUSED_LEGACY_REQUEST_FIELDS.items():
        fields = runtime_commands.get(command_name, {})
        missing = refused - set(fields)
        if missing:
            fail(f"refused legacy request field missing from {command_name}: {sorted(missing)}")
        for name in refused:
            del fields[name]
    compare_names(set(ir.commands), set(runtime_commands), "runtime SDK command")
    for command_name, command in ir.commands.items():
        request = command["request"]
        assert isinstance(request, Mapping)
        _compare_request_fields(
            command_name, request["fields"], runtime_commands[command_name], ir.types
        )
    validate_named_request_structs(ir)


def sniffed_commands() -> dict[str, SniffedName]:
    # A sniffer module may compare with a name it passes on to the Command
    # enum (client_hello.rs and identify) without its module table entry.
    passed_on = set(runtime_command_fields()) - set(module_command_fields())
    try:
        return sniffer_names(TUI, passed_on)
    except (SnifferNameError, HandlerCommandError, OSError, UnicodeError) as error:
        fail(f"cannot read the sniffer modules: {error}")
    return {}


def validate_sniffed_coverage(ir: SdkIR, served: Mapping[str, SniffedName]) -> list[str]:
    """Every name a sniffer module serves is a schema command or an
    UNSCHEMAD_SNIFFED_COMMANDS entry. Returns, and prints, a note for each
    entry that is no longer needed."""

    unschemad = {name for name in served if name not in ir.commands}
    unlisted = sorted(unschemad - set(UNSCHEMAD_SNIFFED_COMMANDS))
    if unlisted:
        fail(
            "served but not in sdk-schema.json: "
            + ", ".join(f"{name} (server/{served[name].module})" for name in unlisted)
        )
    notes: list[str] = []
    schemad = sorted(name for name in UNSCHEMAD_SNIFFED_COMMANDS if name in ir.commands)
    if schemad:
        notes.append(
            "in sdk-schema.json now, drop from UNSCHEMAD_SNIFFED_COMMANDS: " + ", ".join(schemad)
        )
    unserved = sorted(set(UNSCHEMAD_SNIFFED_COMMANDS) - set(served) - set(schemad))
    if unserved:
        notes.append(
            "no sniffer module serves these, drop from UNSCHEMAD_SNIFFED_COMMANDS: "
            + ", ".join(unserved)
        )
    for note in notes:
        print(f"SDK schema note: {note}", file=sys.stderr)
    return notes


def validate_named_request_structs(ir: SdkIR) -> None:
    """Reject drift between RUNTIME_NAMED_REQUEST_STRUCTS and their SDK types."""

    for type_name, relative_path in RUNTIME_NAMED_REQUEST_STRUCTS.items():
        path = TUI / "crates/cmux-tui-core/src" / relative_path
        try:
            source = path.read_text(encoding="utf-8")
        except (OSError, UnicodeError) as error:
            fail(f"cannot read {path.relative_to(ROOT)}: {error}")
        sdk_type = ir.types.get(type_name)
        if not isinstance(sdk_type, Mapping) or sdk_type.get("kind") != "object":
            fail(f"SDK type {type_name} must be an object type")
        _compare_request_fields(
            type_name, sdk_type["fields"], _rust_struct_fields(source, type_name), ir.types
        )


def _compare_request_fields(
    label: str,
    schema_fields: Mapping[str, Any],
    runtime_fields: Mapping[str, RuntimeField],
    types: Mapping[str, Any],
) -> None:
    """Fields of one request (a command name) or one named request type."""

    compare_names(set(schema_fields), set(runtime_fields), f"SDK request field for {label}")
    for field_name, runtime_field in runtime_fields.items():
        schema_field = schema_fields[field_name]
        assert isinstance(schema_field, Mapping)
        runtime_presence = _runtime_field_presence(runtime_field)
        runtime_shape = _runtime_type_shape(runtime_field.rust_type)
        decoded = RUNTIME_DECODED_REQUEST_FIELDS.get((label, field_name))
        if decoded is not None:
            rust_type, decoded_shape = decoded
            if runtime_field.rust_type.replace(" ", "") != rust_type:
                fail(
                    f"decoded request field {label}.{field_name} is no longer "
                    f"{rust_type} at runtime: {runtime_field.rust_type}"
                )
            runtime_shape = decoded_shape
            if rust_type == "Value":
                # The decoder refuses the null a bare Value would take.
                runtime_presence = (runtime_presence[0], False)
        schema_presence = (schema_field["presence"], bool(schema_field["nullable"]))
        if runtime_presence != schema_presence:
            fail(
                f"SDK request field presence drift for {label}.{field_name}, "
                f"SDK={schema_presence}, runtime={runtime_presence}"
            )
        runtime_aliases = _runtime_field_aliases(runtime_field)
        # Several legacy aliases repeat the canonical snake_case field
        # name. They do not add another accepted wire spelling.
        runtime_aliases.discard(field_name)
        schema_aliases = set(schema_field.get("aliases", ()))
        if runtime_aliases != schema_aliases:
            fail(
                f"SDK request field alias drift for {label}.{field_name}, "
                f"SDK={sorted(schema_aliases)}, runtime={sorted(runtime_aliases)}"
            )
        type_expression = schema_field["type"]
        assert isinstance(type_expression, Mapping)
        schema_shape = _schema_type_shape(type_expression, types)
        if runtime_shape != schema_shape:
            fail(
                f"SDK request field type drift for {label}.{field_name}, "
                f"SDK={schema_shape}, runtime={runtime_shape}"
            )


def validate_sdk_ir(
    ir: SdkIR,
    document: Mapping[str, Any],
    schema: Mapping[str, Any],
    inventory: Mapping[str, Any],
) -> None:
    expected_schema_version = schema["properties"]["schema_version"]["const"]
    if ir.schema_version != expected_schema_version:
        fail(
            "SDK schema_version drift, "
            f"document={ir.schema_version}, schema={expected_schema_version}"
        )
    if document.get("$schema") != "./sdk-schema.schema.json":
        fail("SDK document must reference ./sdk-schema.schema.json")
    if ir.mux_protocol != inventory["mux_protocol"]:
        fail(
            "SDK mux protocol drift, "
            f"SDK={ir.mux_protocol}, inventory={inventory['mux_protocol']}"
        )

    expected_profiles = set(inventory["profiles"])
    compare_names(set(ir.profiles), expected_profiles, "SDK profile")

    expected_commands = inventory_commands(inventory)
    compare_names(set(ir.commands), set(expected_commands), "SDK command")
    authority_mismatches = sorted(
        name
        for name, command in ir.commands.items()
        if command["authority"] != expected_commands[name]
    )
    if authority_mismatches:
        details = ", ".join(
            f"{name}: SDK={ir.commands[name]['authority']}, "
            f"inventory={expected_commands[name]}"
            for name in authority_mismatches
        )
        fail(f"SDK command authority drift, {details}")
    validate_runtime_request_fields(ir)
    validate_sniffed_coverage(ir, sniffed_commands())

    expected_events = inventory_events(inventory)
    compare_names(set(ir.events), set(expected_events), "SDK event")
    for name, event in ir.events.items():
        sdk_streams = set(event["streams"])
        expected_streams = set(expected_events[name]["streams"])
        if sdk_streams != expected_streams:
            fail(
                f"SDK event stream drift for {name}, "
                f"SDK={sorted(sdk_streams)}, inventory={sorted(expected_streams)}"
            )
        expected_emission = (
            "serialized-never-emitted"
            if expected_events[name].get("emission") == "serialized-never-emitted"
            else "emitted"
        )
        if event["emission"] != expected_emission:
            fail(
                f"SDK event emission drift for {name}, "
                f"SDK={event['emission']}, inventory={expected_emission}"
            )


def check() -> SdkIR:
    document = load_json(SPEC / "sdk-schema.json")
    schema = load_json(SPEC / "sdk-schema.schema.json")
    inventory = load_json(SPEC / "inventory.json")
    ir = load_ir(SPEC / "sdk-schema.json")
    validate_sdk_ir(ir, document, schema, inventory)
    return ir


def main() -> int:
    try:
        ir = check()
    except (SdkSchemaError, ValueError) as error:
        print(f"SDK schema error: {error}", file=sys.stderr)
        return 1
    print(
        "SDK schema ok: "
        f"protocol {ir.mux_protocol}, "
        f"{len(ir.commands)} commands, "
        f"{len(ir.events)} events, "
        f"{len(ir.types)} named types, "
        f"IR {ir.ir_sha256}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
