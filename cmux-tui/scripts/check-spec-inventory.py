#!/usr/bin/env python3
"""Reject drift between cmux-tui runtime surfaces and the protocol inventory."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
TUI = ROOT / "cmux-tui"
SPEC = TUI / "spec"


def fail(message: str) -> None:
    print(f"spec inventory error: {message}", file=sys.stderr)
    raise SystemExit(1)


def unique(values: list[str], label: str) -> set[str]:
    duplicates = sorted({value for value in values if values.count(value) > 1})
    if duplicates:
        fail(f"duplicate {label}: {', '.join(duplicates)}")
    return set(values)


def validate_schema_literals(value: object, schema: dict[str, object], path: str) -> None:
    if "const" in schema and value != schema["const"]:
        fail(f"{path} must equal {schema['const']!r}")
    if "enum" in schema and value not in schema["enum"]:
        fail(f"{path} must be one of {schema['enum']!r}")


def validate_schema_type(value: object, schema: dict[str, object], path: str) -> None:
    expected_type = schema.get("type")
    type_matches = {
        "object": isinstance(value, dict),
        "array": isinstance(value, list),
        "string": isinstance(value, str),
        "integer": isinstance(value, int) and not isinstance(value, bool),
    }
    if isinstance(expected_type, list):
        if not any(type_matches.get(item, False) for item in expected_type):
            fail(f"{path} must be one of the JSON types {expected_type!r}")
    elif expected_type in type_matches and not type_matches[expected_type]:
        fail(f"{path} must be a JSON {expected_type}")


def validate_schema_string(value: str, schema: dict[str, object], path: str) -> None:
    if len(value) < int(schema.get("minLength", 0)):
        fail(f"{path} is shorter than minLength")
    pattern = schema.get("pattern")
    if pattern and not re.search(str(pattern), value):
        fail(f"{path} does not match {pattern!r}")


def validate_schema_integer(value: int, schema: dict[str, object], path: str) -> None:
    minimum = schema.get("minimum")
    if minimum is not None and value < int(minimum):
        fail(f"{path} is smaller than {minimum}")


def validate_schema_array(value: list, schema: dict[str, object], path: str) -> None:
    if len(value) < int(schema.get("minItems", 0)):
        fail(f"{path} has too few items")
    if schema.get("uniqueItems"):
        encoded = [json.dumps(item, sort_keys=True, separators=(",", ":")) for item in value]
        if len(encoded) != len(set(encoded)):
            fail(f"{path} contains duplicate items")
    item_schema = schema.get("items")
    if isinstance(item_schema, dict):
        for index, item in enumerate(value):
            validate_schema(item, item_schema, f"{path}[{index}]")


def validate_schema_object(value: dict, schema: dict[str, object], path: str) -> None:
    required = schema.get("required", [])
    for key in required:
        if key not in value:
            fail(f"{path} is missing required property {key!r}")
    properties = schema.get("properties", {})
    additional = schema.get("additionalProperties", True)
    for key, item in value.items():
        child_path = f"{path}.{key}"
        if key in properties:
            validate_schema(item, properties[key], child_path)
        elif additional is False:
            fail(f"{path} has unknown property {key!r}")
        elif isinstance(additional, dict):
            validate_schema(item, additional, child_path)


def validate_schema(value: object, schema: dict[str, object], path: str = "$") -> None:
    """Validate the JSON Schema subset used by inventory.schema.json."""
    validate_schema_literals(value, schema, path)
    validate_schema_type(value, schema, path)
    if isinstance(value, str):
        validate_schema_string(value, schema, path)
    elif isinstance(value, int) and not isinstance(value, bool):
        validate_schema_integer(value, schema, path)
    elif isinstance(value, list):
        validate_schema_array(value, schema, path)
    elif isinstance(value, dict):
        validate_schema_object(value, schema, path)


def rust_enum_body(source: str, name: str) -> str:
    match = re.search(rf"\benum\s+{re.escape(name)}\s*\{{", source)
    if not match:
        fail(f"cannot find Rust enum {name}")
    start = match.end()
    depth = 1
    for index in range(start, len(source)):
        char = source[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return source[start:index]
    fail(f"unterminated Rust enum {name}")
    return ""


def rust_enum_variants(source: str, name: str) -> set[str]:
    body = rust_enum_body(source, name)
    return set(
        re.findall(
            r"(?m)^    ([A-Z][A-Za-z0-9]*)[ \t]*(?=,|\(|\{|(?://.*)?$)",
            body,
        )
    )


def camel_to_kebab(name: str) -> str:
    return re.sub(r"(?<!^)(?=[A-Z])", "-", name).lower()


def camel_to_snake(name: str) -> str:
    return re.sub(r"(?<!^)(?=[A-Z])", "_", name).lower()


def command_names() -> set[str]:
    source = (TUI / "crates/cmux-tui-core/src/server.rs").read_text()
    variants = rust_enum_variants(source, "Command")
    return {camel_to_kebab(variant) for variant in variants}


def rust_function_body(source: str, name: str) -> str:
    match = re.search(rf"\bfn\s+{re.escape(name)}\s*\([^)]*\)[^{{]*\{{", source)
    if not match:
        fail(f"cannot find Rust function {name}")
    start = match.end()
    depth = 1
    index = start
    while index < len(source):
        raw_end = rust_raw_string_end(source, index)
        if raw_end is not None:
            index = raw_end
            continue
        if source[index] == '"':
            index += 1
            while index < len(source):
                if source[index] == "\\":
                    index += 2
                elif source[index] == '"':
                    index += 1
                    break
                else:
                    index += 1
            continue
        char = source[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return source[start:index]
        index += 1
    fail(f"unterminated Rust function {name}")
    return ""


def command_profiles() -> dict[str, set[str]]:
    source = strip_rust_comments(
        (TUI / "crates/cmux-tui-core/src/server.rs").read_text()
    )
    body = rust_function_body(source, "profile")
    profiles: dict[str, set[str]] = {}
    mapped_variants: set[str] = set()
    for variant, profile in re.findall(
        r"Command::([A-Z][A-Za-z0-9]*)"
        r"(?:\s*\{[^}]*\}|\s*\([^)]*\))?\s*=>\s*(?:\{\s*)?"
        r"CommandProfile::([A-Z][A-Za-z0-9]*)",
        body,
    ):
        if variant in mapped_variants:
            fail(f"duplicate command profile metadata for {variant}")
        mapped_variants.add(variant)
        profiles.setdefault(camel_to_kebab(profile), set()).add(camel_to_kebab(variant))
    enum_variants = rust_enum_variants(source, "Command")
    if mapped_variants != enum_variants:
        missing = sorted(enum_variants - mapped_variants)
        stale = sorted(mapped_variants - enum_variants)
        fail(
            "command profile metadata is not exhaustive, "
            f"missing={missing}, stale={stale}"
        )
    return profiles


def rust_raw_string_end(source: str, start: int) -> int | None:
    if source.startswith(("br", "cr"), start):
        marker = start + 2
    elif source.startswith("r", start):
        marker = start + 1
    else:
        return None
    hashes = 0
    while marker + hashes < len(source) and source[marker + hashes] == "#":
        hashes += 1
    quote = marker + hashes
    if quote >= len(source) or source[quote] != '"':
        return None
    terminator = '"' + ("#" * hashes)
    closing = source.find(terminator, quote + 1)
    return len(source) if closing < 0 else closing + len(terminator)


def strip_rust_comments(source: str) -> str:
    output = list(source)
    index = 0
    while index < len(source):
        raw_end = rust_raw_string_end(source, index)
        if raw_end is not None:
            index = raw_end
            continue
        if source[index] == '"':
            index += 1
            while index < len(source):
                if source[index] == "\\":
                    index += 2
                elif source[index] == '"':
                    index += 1
                    break
                else:
                    index += 1
            continue
        if source.startswith("//", index):
            end = source.find("\n", index)
            end = len(source) if end < 0 else end
            for offset in range(index, end):
                output[offset] = " "
            index = end
            continue
        if source.startswith("/*", index):
            depth = 1
            end = index + 2
            while end < len(source) and depth:
                if source.startswith("/*", end):
                    depth += 1
                    end += 2
                elif source.startswith("*/", end):
                    depth -= 1
                    end += 2
                else:
                    end += 1
            for offset in range(index, end):
                if output[offset] != "\n":
                    output[offset] = " "
            index = end
            continue
        index += 1
    return "".join(output)


def rust_tokens(source: str) -> list[str]:
    """Tokenize the Rust subset needed to inspect JSON event construction."""
    tokens: list[str] = []
    index = 0
    while index < len(source):
        if source[index].isspace():
            index += 1
            continue
        raw_end = rust_raw_string_end(source, index)
        if raw_end is not None:
            tokens.append(source[index:raw_end])
            index = raw_end
            continue
        if source[index] == '"':
            end = index + 1
            while end < len(source):
                if source[end] == "\\":
                    end += 2
                elif source[end] == '"':
                    end += 1
                    break
                else:
                    end += 1
            tokens.append(source[index:end])
            index = end
            continue
        identifier = re.match(r"[A-Za-z_][A-Za-z0-9_]*", source[index:])
        if identifier:
            token = identifier.group(0)
            tokens.append(token)
            index += len(token)
            continue
        if source[index] in "{}()[],:;!.=":
            tokens.append(source[index])
        index += 1
    return tokens


def rust_string_value(token: str) -> str | None:
    if token.startswith('"'):
        try:
            value = json.loads(token)
        except json.JSONDecodeError:
            return None
        return value if isinstance(value, str) else None
    raw = re.fullmatch(r"(?:br|cr|r)(#*)\"(.*)\"\1", token, re.DOTALL)
    return raw.group(2) if raw else None


def matching_token(tokens: list[str], start: int) -> int | None:
    pairs = {"(": ")", "[": "]", "{": "}"}
    opener = tokens[start]
    if opener not in pairs:
        return None
    stack = [pairs[opener]]
    for index in range(start + 1, len(tokens)):
        token = tokens[index]
        if token in pairs:
            stack.append(pairs[token])
        elif token in {")", "]", "}"}:
            if not stack or token != stack[-1]:
                return None
            stack.pop()
            if not stack:
                return index
    return None


def expression_tokens(tokens: list[str], start: int) -> list[str]:
    pairs = {"(": ")", "[": "]", "{": "}"}
    stack: list[str] = []
    expression: list[str] = []
    for token in tokens[start:]:
        if token in pairs:
            stack.append(pairs[token])
        elif token in {")", "]", "}"}:
            if not stack:
                break
            if token != stack[-1]:
                break
            stack.pop()
        elif token in {",", ";"} and not stack:
            break
        expression.append(token)
    return expression


def split_rust_arguments(tokens: list[str]) -> list[list[str]]:
    pairs = {"(": ")", "[": "]", "{": "}"}
    stack: list[str] = []
    arguments: list[list[str]] = [[]]
    for token in tokens:
        if token == "," and not stack:
            arguments.append([])
            continue
        arguments[-1].append(token)
        if token in pairs:
            stack.append(pairs[token])
        elif token in {")", "]", "}"} and stack and token == stack[-1]:
            stack.pop()
    return arguments


def rust_string_constants(tokens: list[str]) -> dict[str, str]:
    constants: dict[str, str] = {}
    for index, token in enumerate(tokens):
        if token != "const" or index + 1 >= len(tokens):
            continue
        name = tokens[index + 1]
        try:
            equals = tokens.index("=", index + 2)
            semicolon = tokens.index(";", equals + 1)
        except ValueError:
            continue
        for candidate in tokens[equals + 1 : semicolon]:
            value = rust_string_value(candidate)
            if value is not None:
                constants[name] = value
                break
    return constants


def wire_names_from_tokens(tokens: list[str], constants: dict[str, str]) -> set[str]:
    names: set[str] = set()
    for token in tokens:
        value = rust_string_value(token)
        if value is None:
            value = constants.get(token)
        if value is not None and re.fullmatch(r"[a-z][a-z0-9-]*", value):
            names.add(value)
    return names


def json_macro_event_names(tokens: list[str], constants: dict[str, str]) -> set[str]:
    names: set[str] = set()
    for index in range(len(tokens) - 2):
        if tokens[index : index + 2] != ["json", "!"]:
            continue
        close = matching_token(tokens, index + 2)
        if close is None:
            continue
        body = tokens[index + 3 : close]
        for key_index in range(len(body) - 2):
            if rust_string_value(body[key_index]) != "event" or body[key_index + 1] != ":":
                continue
            names.update(
                wire_names_from_tokens(
                    expression_tokens(body, key_index + 2),
                    constants,
                )
            )
    return names


def inserted_event_names(tokens: list[str], constants: dict[str, str]) -> set[str]:
    names: set[str] = set()
    for index, token in enumerate(tokens[:-1]):
        if token != "insert" or tokens[index + 1] != "(":
            continue
        close = matching_token(tokens, index + 1)
        if close is None:
            continue
        arguments = split_rust_arguments(tokens[index + 2 : close])
        if len(arguments) < 2:
            continue
        keys = {
            rust_string_value(candidate) or constants.get(candidate)
            for candidate in arguments[0]
        }
        if "event" in keys:
            names.update(wire_names_from_tokens(arguments[1], constants))
    return names


def assigned_event_names(tokens: list[str], constants: dict[str, str]) -> set[str]:
    names: set[str] = set()
    for index in range(len(tokens) - 3):
        if (
            tokens[index] == "["
            and rust_string_value(tokens[index + 1]) == "event"
            and tokens[index + 2 : index + 4] == ["]", "="]
        ):
            names.update(
                wire_names_from_tokens(
                    expression_tokens(tokens, index + 4),
                    constants,
                )
            )
    return names


def event_names() -> set[str]:
    server = (TUI / "crates/cmux-tui-core/src/server.rs").read_text()
    production = strip_rust_comments(server.split("\n#[cfg(test)]\nmod tests", 1)[0])
    tokens = rust_tokens(production)
    constants = rust_string_constants(tokens)
    names = json_macro_event_names(tokens, constants)
    names.update(inserted_event_names(tokens, constants))
    names.update(assigned_event_names(tokens, constants))

    mux = strip_rust_comments((TUI / "crates/cmux-tui-core/src/mux.rs").read_text())
    delta_impl = mux.split("impl TreeDeltaKind", 1)
    if len(delta_impl) != 2:
        fail("cannot find TreeDeltaKind implementation")
    delta_impl = delta_impl[1].split("\n}", 1)[0]
    names.update(re.findall(r'=>\s*"([a-z]+(?:-[a-z]+)+)"', delta_impl))
    return names


def event_streams() -> dict[str, set[str]]:
    source = strip_rust_comments(
        (TUI / "crates/cmux-tui-core/src/server.rs").read_text()
    )
    catalog_match = re.search(
        r"const\s+PUBLIC_EVENT_CATALOG\s*:\s*&\[PublicEvent\]\s*=\s*&\[(.*?)\n\];",
        source,
        re.DOTALL,
    )
    if not catalog_match:
        fail("cannot find PUBLIC_EVENT_CATALOG")
    streams_by_event: dict[str, set[str]] = {}
    for name, stream_body in re.findall(
        r'PublicEvent::new\(\s*"([a-z][a-z0-9-]*)"\s*,\s*&\[(.*?)\]\s*,?\s*\)',
        catalog_match.group(1),
        re.DOTALL,
    ):
        if name in streams_by_event:
            fail(f"duplicate public event metadata for {name}")
        streams = {
            camel_to_kebab(stream)
            for stream in re.findall(
                r"PublicEventStream::([A-Z][A-Za-z0-9]*)",
                stream_body,
            )
        }
        if not streams:
            fail(f"public event {name} has no runtime stream")
        streams_by_event[name] = streams
    if not streams_by_event:
        fail("PUBLIC_EVENT_CATALOG has no parseable entries")
    return streams_by_event


def action_variants() -> set[str]:
    source = strip_rust_comments((TUI / "crates/cmux-tui/src/config.rs").read_text())
    return rust_enum_variants(source, "Action")


def action_metadata() -> dict[str, dict[str, object]]:
    source = strip_rust_comments((TUI / "crates/cmux-tui/src/config.rs").read_text())
    body = rust_function_body(source, "metadata")
    metadata: dict[str, dict[str, object]] = {}
    for variant, key, classification, route, execution in re.findall(
        r"Action::([A-Z][A-Za-z0-9]*)"
        r"(?:\s*\([^)]*\))?\s*=>\s*ActionMetadata::new\(\s*"
        r'"([^"]+)"\s*,\s*'
        r"ActionClassification::([A-Z][A-Za-z0-9]*)\s*,\s*"
        r'"([^"]+)"\s*,\s*'
        r"ActionExecution::([A-Z][A-Za-z0-9]*)",
        body,
        re.DOTALL,
    ):
        if variant in metadata:
            fail(f"duplicate action metadata for {variant}")
        if execution != variant:
            fail(
                f"action metadata dispatch mismatch for {variant}: "
                f"executes {execution}"
            )
        metadata[variant] = {
            "key": key,
            "classification": camel_to_kebab(classification),
            "route": route,
        }
    for (
        variant,
        key,
        classification,
        ownership_source,
        session_kind,
        session_operation,
        provider_kind,
        provider_operation,
        unknown_ownership,
        execution,
    ) in re.findall(
        r"Action::([A-Z][A-Za-z0-9]*)"
        r"(?:\s*\([^)]*\))?\s*=>\s*ActionMetadata::workspace_ownership\(\s*"
        r'"([^"]+)"\s*,\s*'
        r"ActionClassification::([A-Z][A-Za-z0-9]*)\s*,\s*"
        r"WorkspaceOwnershipSource::([A-Z][A-Za-z0-9]*)\s*,\s*"
        r'ActionRouteTarget::([A-Z][A-Za-z0-9]*)\(\s*"([^"]+)"\s*\)\s*,\s*'
        r'ActionRouteTarget::([A-Z][A-Za-z0-9]*)\(\s*"([^"]+)"\s*\)\s*,\s*'
        r"UnknownOwnership::([A-Z][A-Za-z0-9]*)\s*,\s*"
        r"ActionExecution::([A-Z][A-Za-z0-9]*)",
        body,
        re.DOTALL,
    ):
        if variant in metadata:
            fail(f"duplicate action metadata for {variant}")
        if execution != variant:
            fail(
                f"action metadata dispatch mismatch for {variant}: "
                f"executes {execution}"
            )
        metadata[variant] = {
            "key": key,
            "classification": camel_to_kebab(classification),
            "route": {
                "ownership_source": camel_to_kebab(ownership_source),
                "session_owned": {
                    "kind": camel_to_kebab(session_kind),
                    "operation": session_operation,
                },
                "provider_owned": {
                    "kind": camel_to_kebab(provider_kind),
                    "operation": provider_operation,
                },
                "unknown_ownership": camel_to_kebab(unknown_ownership),
            },
        }
    variants = rust_enum_variants(source, "Action")
    if set(metadata) != variants:
        missing = sorted(variants - set(metadata))
        stale = sorted(set(metadata) - variants)
        fail(f"action metadata is not exhaustive, missing={missing}, stale={stale}")
    return metadata


def menu_action_variants() -> set[str]:
    source = (TUI / "crates/cmux-tui/src/app.rs").read_text()
    return rust_enum_variants(source, "MenuAction")


def menu_action_metadata() -> dict[str, dict[str, str]]:
    source = strip_rust_comments((TUI / "crates/cmux-tui/src/app.rs").read_text())
    body = rust_function_body(source, "metadata")
    metadata: dict[str, dict[str, str]] = {}
    for variant, classification, route, execution in re.findall(
        r"MenuAction::([A-Z][A-Za-z0-9]*)"
        r"(?:\s*\([^)]*\)|\s*\{[^}]*\})?\s*=>\s*MenuActionMetadata::new\(\s*"
        r"MenuActionClassification::([A-Z][A-Za-z0-9]*)\s*,\s*"
        r'"([^"]+)"\s*,\s*'
        r"MenuActionExecution::([A-Z][A-Za-z0-9]*)",
        body,
        re.DOTALL,
    ):
        if variant in metadata:
            fail(f"duplicate menu action metadata for {variant}")
        if execution != variant:
            fail(
                f"menu action metadata dispatch mismatch for {variant}: "
                f"executes {execution}"
            )
        metadata[variant] = {
            "classification": camel_to_kebab(classification),
            "route": route,
        }
    variants = rust_enum_variants(source, "MenuAction")
    if set(metadata) != variants:
        missing = sorted(variants - set(metadata))
        stale = sorted(set(metadata) - variants)
        fail(
            f"menu action metadata is not exhaustive, missing={missing}, stale={stale}"
        )
    return metadata


def mux_protocol_version() -> int:
    source = (TUI / "crates/cmux-tui-core/src/server.rs").read_text()
    constants = {
        name: expression
        for name, expression in re.findall(
            r"(?m)^pub const ([A-Z][A-Z0-9_]*): u32 = ([A-Z][A-Z0-9_]*|[0-9]+);",
            source,
        )
    }

    def resolve(name: str, seen: set[str]) -> int:
        if name in seen:
            fail(f"cyclic Rust protocol constant {name}")
        expression = constants.get(name)
        if expression is None:
            fail(f"cannot resolve Rust protocol constant {name}")
        if expression.isdigit():
            return int(expression)
        return resolve(expression, seen | {name})

    return resolve("PROTOCOL_VERSION", set())


def secondary_protocols() -> dict[str, object]:
    host_source = strip_rust_comments(
        (TUI / "crates/cmux-tui-core/src/terminal_host_protocol.rs").read_text()
    )
    host_body = rust_enum_body(host_source, "MessageKind")
    host_messages = {
        name: int(value)
        for name, value in re.findall(
            r"(?m)^    ([A-Z][A-Za-z0-9]*)\s*=\s*([0-9]+)"
            r"[ \t]*(?=,|(?://.*)?$)",
            host_body,
        )
    }

    provider_source = strip_rust_comments(
        (TUI / "crates/cmux-tui-machine-protocol/src/lib.rs").read_text()
    )
    provider_requests = {
        camel_to_snake(name)
        for name in rust_enum_variants(provider_source, "ProviderRequest")
    }
    provider_events = {
        camel_to_snake(name)
        for name in rust_enum_variants(provider_source, "ProviderEvent")
    }

    agent_source = strip_rust_comments(
        (TUI / "crates/cmux-tui-machine-agent-protocol/src/lib.rs").read_text()
    )
    agent_messages = {
        camel_to_snake(name)
        for name in rust_enum_variants(agent_source, "Message")
    }

    management_source = strip_rust_comments(
        (TUI / "crates/cmux-tui-core/src/provider_management.rs").read_text()
    )
    management_operations = {
        camel_to_snake(name)
        for name in rust_enum_variants(management_source, "Request")
    }
    return {
        "terminal_host_v1": host_messages,
        "machine_provider_v1_requests": provider_requests,
        "machine_provider_v1_events": provider_events,
        "machine_agent_v1": agent_messages,
        "provider_management_v1": management_operations,
    }


def documented_headings(path: Path) -> list[str]:
    return re.findall(r"(?m)^### ([a-z][a-z0-9-]*(?: / [a-z][a-z0-9-]*)?)$", path.read_text())


def documented_sections(path: Path) -> dict[str, str]:
    sections: dict[str, str] = {}
    source = path.read_text()
    pattern = re.compile(
        r"(?ms)^### ([a-z][a-z0-9-]*(?: / [a-z][a-z0-9-]*)?)\n"
        r"(.*?)(?=^### |^## |\Z)"
    )
    for heading, body in pattern.findall(source):
        for name in heading.split(" / "):
            sections[name] = body
    return sections


def compare(actual: set[str], expected: set[str], label: str) -> None:
    missing = sorted(actual - expected)
    stale = sorted(expected - actual)
    if missing or stale:
        details = []
        if missing:
            details.append(f"missing from inventory: {', '.join(missing)}")
        if stale:
            details.append(f"not implemented: {', '.join(stale)}")
        fail(f"{label} drift, {'; '.join(details)}")


def compare_mapping(
    actual: dict[str, set[str]],
    expected: dict[str, set[str]],
    label: str,
) -> None:
    changed = sorted(
        key
        for key in set(actual) | set(expected)
        if actual.get(key, set()) != expected.get(key, set())
    )
    if not changed:
        return
    details = [
        f"{key}: inventory={sorted(actual.get(key, set()))}, "
        f"policy={sorted(expected.get(key, set()))}"
        for key in changed
    ]
    fail(f"{label} drift, {'; '.join(details)}")


def load_inventory() -> tuple[dict, dict]:
    inventory = json.loads((SPEC / "inventory.json").read_text())
    schema = json.loads((SPEC / "inventory.schema.json").read_text())
    validate_schema(inventory, schema)
    return inventory, schema


def validate_inventory_header(inventory: dict, schema: dict) -> None:
    if inventory.get("schema_version") != schema["properties"]["schema_version"]["const"]:
        fail("inventory schema_version does not match its schema")
    runtime_mux_version = mux_protocol_version()
    if inventory["mux_protocol"] != runtime_mux_version:
        fail(
            "mux protocol drift, "
            f"runtime is {runtime_mux_version} and inventory is {inventory['mux_protocol']}"
        )


def validate_commands(inventory: dict) -> set[str]:
    profiles = inventory["profiles"]
    expected_profiles = {"control", "frontend", "local-admin", "provider-authority"}
    if set(profiles) != expected_profiles:
        fail("profile definitions must be control, frontend, local-admin, provider-authority")
    command_groups = inventory["commands"]
    if set(command_groups) != set(profiles):
        fail("command profile keys must exactly match profile definitions")
    actual_profiles = {
        profile: set(names)
        for profile, names in command_groups.items()
    }
    runtime_profiles = command_profiles()
    compare_mapping(actual_profiles, runtime_profiles, "command profile")
    commands = [name for group in command_groups.values() for name in group]
    inventory_commands = unique(commands, "command")
    runtime_commands = command_names()
    profile_commands = set().union(*runtime_profiles.values())
    compare(runtime_commands, profile_commands, "command profile metadata")
    compare(runtime_commands, inventory_commands, "command")

    command_sections = documented_sections(SPEC / "commands.md")
    command_headings = set(command_sections)
    undocumented_commands = sorted(inventory_commands - command_headings)
    if undocumented_commands:
        fail(f"commands without a commands.md section: {', '.join(undocumented_commands)}")
    bad_command_status = sorted(
        name
        for name in inventory_commands
        if not re.search(r"(?m)^\| status \| implemented(?:[ |])", command_sections[name])
    )
    if bad_command_status:
        fail(f"implemented commands with a stale status: {', '.join(bad_command_status)}")
    return inventory_commands


def validate_events(inventory: dict) -> set[str]:
    events = inventory["events"]
    inventory_events = unique([event["name"] for event in events], "event")
    runtime_events = event_names()
    policy_streams = event_streams()
    inventory_streams = {
        event["name"]: set(event["streams"])
        for event in events
    }
    compare(runtime_events, set(policy_streams), "event stream policy")
    compare(runtime_events, inventory_events, "event")
    compare_mapping(inventory_streams, policy_streams, "event stream")
    event_headings = documented_headings(SPEC / "events.md")
    duplicate_event_sections = sorted(
        name for name in inventory_events if event_headings.count(name) != 1
    )
    if duplicate_event_sections:
        fail(
            "implemented events need exactly one events.md section: "
            + ", ".join(duplicate_event_sections)
        )
    event_sections = documented_sections(SPEC / "events.md")
    bad_event_status = sorted(
        event["name"]
        for event in events
        if (
            event.get("emission", "live") == "live"
            and not re.search(
                r"(?m)^\| status \| implemented(?:[ |])",
                event_sections[event["name"]],
            )
        )
        or (
            event.get("emission") == "serialized-never-emitted"
            and not re.search(
                r"(?m)^\| status \| reserved serializer(?:[; |])",
                event_sections[event["name"]],
            )
        )
    )
    if bad_event_status:
        fail(f"events with a stale emission status: {', '.join(bad_event_status)}")
    return inventory_events


def validate_tui_action_route(inventory: dict, action: dict) -> None:
    route = action["route"]
    variant = action["variant"]
    if variant not in {"NewWorkspace", "CloseWorkspace"}:
        if not isinstance(route, str) or not route.strip():
            fail(f"TUI action {variant} has no programmability route")
        return
    if not isinstance(route, dict):
        fail(f"{variant} requires a structured workspace ownership route")
    if route.get("ownership_source") != "active-workspace-session":
        fail(f"{variant} has an unknown workspace ownership source")

    session_owned = route.get("session_owned")
    if not isinstance(session_owned, dict) or session_owned.get("kind") != "mux-command":
        fail(f"{variant} session-owned route must target a mux command")
    session_operation = session_owned.get("operation")
    commands = {
        name
        for profile_commands in inventory["commands"].values()
        for name in profile_commands
    }
    if session_operation not in commands:
        fail(f"{variant} references unknown mux command {session_operation!r}")

    provider_owned = route.get("provider_owned")
    if (
        not isinstance(provider_owned, dict)
        or provider_owned.get("kind") != "machine-provider-request"
    ):
        fail(f"{variant} provider-owned route must target a machine-provider request")
    provider_operation = provider_owned.get("operation")
    provider_requests = set(
        inventory["secondary_protocols"]["machine_provider_v1"]["requests"]
    )
    if provider_operation not in provider_requests:
        fail(
            f"{variant} references unknown machine-provider request "
            f"{provider_operation!r}"
        )
    if route.get("unknown_ownership") != "reject":
        fail(f"{variant} unknown workspace ownership must reject")


def validate_tui_actions(inventory: dict) -> list[dict]:
    actions = inventory["tui_actions"]
    inventory_actions = unique([action["variant"] for action in actions], "TUI action")
    compare(action_variants(), inventory_actions, "TUI action")
    for action in actions:
        validate_tui_action_route(inventory, action)
    runtime_metadata = action_metadata()
    inventory_metadata = {
        action["variant"]: {
            "key": action["key"],
            "classification": action["classification"],
            "route": action["route"],
        }
        for action in actions
    }
    changed = sorted(
        variant
        for variant in set(runtime_metadata) | set(inventory_metadata)
        if runtime_metadata.get(variant) != inventory_metadata.get(variant)
    )
    if changed:
        details = [
            f"{variant}: inventory={inventory_metadata.get(variant)}, "
            f"runtime={runtime_metadata.get(variant)}"
            for variant in changed
        ]
        fail(f"TUI action metadata drift, {'; '.join(details)}")
    allowed = {"direct", "composite", "presentation-only"}
    for action in actions:
        if action["classification"] not in allowed:
            fail(f"bad TUI action classification for {action['variant']}")
    return actions


def validate_menu_actions(inventory: dict) -> list[dict]:
    menu_actions = inventory["menu_actions"]
    inventory_menu_actions = unique(
        [action["variant"] for action in menu_actions], "menu action"
    )
    compare(menu_action_variants(), inventory_menu_actions, "menu action")
    runtime_metadata = menu_action_metadata()
    inventory_metadata = {
        action["variant"]: {
            "classification": action["classification"],
            "route": action["route"],
        }
        for action in menu_actions
    }
    changed = sorted(
        variant
        for variant in set(runtime_metadata) | set(inventory_metadata)
        if runtime_metadata.get(variant) != inventory_metadata.get(variant)
    )
    if changed:
        details = [
            f"{variant}: inventory={inventory_metadata.get(variant)}, "
            f"runtime={runtime_metadata.get(variant)}"
            for variant in changed
        ]
        fail(f"menu action metadata drift, {'; '.join(details)}")
    menu_allowed = {"direct", "composite", "presentation-only", "external-protocol"}
    for action in menu_actions:
        if action["classification"] not in menu_allowed:
            fail(f"bad menu action classification for {action['variant']}")
        if not action["route"].strip():
            fail(f"menu action {action['variant']} has no programmability route")
    return menu_actions


def validate_feature_families(inventory: dict, schema: dict) -> list[dict]:
    families = inventory["feature_families"]
    family_ids = unique([family["id"] for family in families], "feature family")
    schema_family_ids = set(
        schema["properties"]["feature_families"]["items"]["properties"]["id"]["enum"]
    )
    compare(schema_family_ids, family_ids, "feature family")
    wire_statuses = {
        "implemented",
        "partial",
        "proposed",
        "presentation-only",
        "external-protocol",
    }
    programmability_statuses = {"complete", "partial", "missing", "not-applicable"}
    for family in families:
        if (
            family["wire_status"] not in wire_statuses
            or family["programmability"] not in programmability_statuses
            or not family["route"].strip()
        ):
            fail(f"feature family {family['id']} has no valid status and route")
    return families


def validate_secondary_protocols(
    inventory: dict,
) -> tuple[dict[str, int], list[str], list[str]]:
    secondary = inventory["secondary_protocols"]
    runtime_secondary = secondary_protocols()
    expected_host = secondary["terminal_host_v1"]["messages"]
    if runtime_secondary["terminal_host_v1"] != expected_host:
        fail("terminal-host v1 message inventory drift")
    terminal_host_doc = (SPEC / "terminal-host.md").read_text()
    undocumented_host = sorted(
        name for name in expected_host if f"`{name}`" not in terminal_host_doc
    )
    if undocumented_host:
        fail(f"terminal-host messages without prose: {', '.join(undocumented_host)}")
    compare(
        runtime_secondary["machine_provider_v1_requests"],
        unique(secondary["machine_provider_v1"]["requests"], "machine-provider request"),
        "machine-provider request",
    )
    compare(
        runtime_secondary["machine_provider_v1_events"],
        unique(secondary["machine_provider_v1"]["events"], "machine-provider event"),
        "machine-provider event",
    )
    compare(
        runtime_secondary["machine_agent_v1"],
        unique(secondary["machine_agent_v1"]["messages"], "machine-agent message"),
        "machine-agent message",
    )
    compare(
        runtime_secondary["provider_management_v1"],
        unique(
            secondary["provider_management_v1"]["operations"],
            "provider-management operation",
        ),
        "provider-management operation",
    )
    provider_doc = (SPEC / "machine-provider.md").read_text()
    undocumented_provider = sorted(
        name
        for name in secondary["machine_provider_v1"]["requests"]
        if f"`{name}`" not in provider_doc
    )
    if undocumented_provider:
        fail(f"machine-provider requests without prose: {', '.join(undocumented_provider)}")
    undocumented_provider_events = sorted(
        name
        for name in secondary["machine_provider_v1"]["events"]
        if f"`{name}`" not in provider_doc
    )
    if undocumented_provider_events:
        fail(
            "machine-provider events without prose: "
            + ", ".join(undocumented_provider_events)
        )
    machine_agent_doc = (SPEC / "machine-agent.md").read_text()
    undocumented_agent = sorted(
        name
        for name in secondary["machine_agent_v1"]["messages"]
        if f"`{name}`" not in machine_agent_doc
    )
    if undocumented_agent:
        fail(f"machine-agent messages without prose: {', '.join(undocumented_agent)}")
    management_doc = (SPEC / "provider-management.md").read_text()
    undocumented_management = sorted(
        name
        for name in secondary["provider_management_v1"]["operations"]
        if f'"operation":"{name}"' not in management_doc
    )
    if undocumented_management:
        fail(
            "provider-management operations without examples: "
            + ", ".join(undocumented_management)
        )
    return (
        expected_host,
        secondary["machine_provider_v1"]["requests"],
        secondary["machine_agent_v1"]["messages"],
    )


def validate_protocol_domains(inventory: dict) -> None:
    for domain in inventory["protocol_domains"]:
        if not (SPEC / domain["spec"]).is_file():
            fail(f"protocol domain {domain['id']} points to missing {domain['spec']}")


def main() -> None:
    inventory, schema = load_inventory()
    validate_inventory_header(inventory, schema)
    inventory_commands = validate_commands(inventory)
    inventory_events = validate_events(inventory)
    actions = validate_tui_actions(inventory)
    menu_actions = validate_menu_actions(inventory)
    families = validate_feature_families(inventory, schema)
    expected_host, provider_requests, agent_messages = validate_secondary_protocols(inventory)
    validate_protocol_domains(inventory)

    print(
        "spec inventory ok: "
        f"{len(inventory_commands)} commands, "
        f"{len(inventory_events)} events, "
        f"{len(actions)} TUI actions, "
        f"{len(menu_actions)} menu actions, "
        f"{len(families)} feature families, "
        f"{len(expected_host)} terminal-host messages, "
        f"{len(provider_requests)} machine-provider requests, "
        f"{len(agent_messages)} machine-agent messages"
    )


if __name__ == "__main__":
    main()
