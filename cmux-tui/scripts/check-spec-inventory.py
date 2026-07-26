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

# Deliberately independent from inventory.json. Keeping this policy map in the
# checker makes authority-group drift fail even when the Command enum is
# unchanged.
EXPECTED_COMMAND_PROFILES = {
    "control": {
        "apply-layout",
        "clear-window-title",
        "close-pane",
        "close-screen",
        "close-surface",
        "close-terminal",
        "close-workspace",
        "copy",
        "create-terminal",
        "create-workspace",
        "detach-client",
        "export-layout",
        "focus-direction",
        "focus-pane",
        "get-frontend-projection",
        "identify",
        "ids",
        "list-agents",
        "list-clients",
        "list-terminals",
        "list-workspaces",
        "move-tab",
        "move-terminal",
        "move-workspace",
        "new-browser-tab",
        "new-pane",
        "new-screen",
        "new-tab",
        "new-workspace",
        "notify",
        "pane-neighbor",
        "ping",
        "process-info",
        "put-frontend-projection",
        "read-screen",
        "read-scrollback",
        "release-surface-size",
        "reload-config",
        "rename-pane",
        "rename-screen",
        "rename-surface",
        "rename-workspace",
        "report-agent",
        "resize-surface",
        "resolve-terminal",
        "run",
        "scroll-surface",
        "select-screen",
        "select-tab",
        "select-workspace",
        "send",
        "send-key",
        "set-client-info",
        "set-client-sizing",
        "set-default-colors",
        "set-ratio",
        "set-split-ratio",
        "set-window-title",
        "split",
        "swap-pane",
        "terminal-events",
        "vt-state",
        "wait-for",
        "zoom-pane",
    },
    "frontend": {
        "attach-surface",
        "browser-activate",
        "browser-back",
        "browser-forward",
        "browser-insert-text",
        "browser-key",
        "browser-mouse",
        "browser-navigate",
        "browser-reload",
        "browser-wheel",
        "mint-terminal-renderer",
        "set-cell-pixels",
        "sidebar-plugin",
        "subscribe",
    },
    "local-admin": {
        "pairing-response",
        "shutdown-daemon",
    },
    "provider-authority": {
        "close-provider-managed-workspace",
        "mark-workspaces-provider-managed",
        "rename-provider-managed-workspace",
    },
}

# Also independent from inventory.json. The sets model the production
# serializer paths that feed each public stream.
EXPECTED_EVENTS_BY_STREAM = {
    "subscribe": {
        "bell",
        "client-attached",
        "client-changed",
        "client-detached",
        "client-list-invalidated",
        "config-reload-requested",
        "empty",
        "frontend-projection-changed",
        "layout-changed",
        "notification",
        "overflow",
        "pairing-requested",
        "pairing-resolved",
        "scroll-changed",
        "status",
        "surface-exited",
        "surface-output",
        "surface-resize-failed",
        "surface-resized",
        "terminal-registry-changed",
        "title-changed",
        "tree-changed",
        "window-title-requested",
    },
    "subscribe-deltas": {
        "pane-added",
        "pane-closed",
        "screen-added",
        "screen-closed",
        "screen-renamed",
        "tab-added",
        "tab-closed",
        "tab-renamed",
        "workspace-added",
        "workspace-closed",
        "workspace-moved",
        "workspace-renamed",
    },
    "attach-byte": {
        "colors-changed",
        "detached",
        "notification",
        "output",
        "overflow",
        "resized",
        "scroll-changed",
        "vt-state",
    },
    "attach-render": {
        "detached",
        "overflow",
        "render-delta",
        "render-state",
        "scroll-changed",
    },
    "attach-browser": {
        "browser-state",
        "detached",
        "frame",
        "notification",
        "overflow",
        "scroll-changed",
    },
}


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
    if expected_type in type_matches and not type_matches[expected_type]:
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


def event_names() -> set[str]:
    server = (TUI / "crates/cmux-tui-core/src/server.rs").read_text()
    production = strip_rust_comments(server.split("\n#[cfg(test)]\nmod tests", 1)[0])
    names = set(
        re.findall(
            r'json\s*!\s*\(\s*\{\s*"event"\s*:\s*"([a-z][a-z0-9-]*)"',
            production,
        )
    )
    names.update(
        re.findall(
            r'value\["event"\]\s*=\s*json!\("([a-z][a-z0-9-]*)"\)',
            production,
        )
    )

    mux = strip_rust_comments((TUI / "crates/cmux-tui-core/src/mux.rs").read_text())
    delta_impl = mux.split("impl TreeDeltaKind", 1)
    if len(delta_impl) != 2:
        fail("cannot find TreeDeltaKind implementation")
    delta_impl = delta_impl[1].split("\n}", 1)[0]
    names.update(re.findall(r'=>\s*"([a-z]+(?:-[a-z]+)+)"', delta_impl))
    return names


def action_variants() -> set[str]:
    source = (TUI / "crates/cmux-tui/src/config.rs").read_text()
    return rust_enum_variants(source, "Action")


def menu_action_variants() -> set[str]:
    source = (TUI / "crates/cmux-tui/src/app.rs").read_text()
    return rust_enum_variants(source, "MenuAction")


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
    host_source = (TUI / "crates/cmux-tui-core/src/terminal_host_protocol.rs").read_text()
    host_body = rust_enum_body(host_source, "MessageKind")
    host_messages = {
        name: int(value)
        for name, value in re.findall(
            r"(?m)^    ([A-Z][A-Za-z0-9]*)\s*=\s*([0-9]+),", host_body
        )
    }

    provider_source = (
        TUI / "crates/cmux-tui-machine-protocol/src/lib.rs"
    ).read_text()
    request_body = rust_enum_body(provider_source, "ProviderRequest")
    provider_requests = {
        camel_to_snake(name)
        for name in re.findall(
            r"(?m)^    ([A-Z][A-Za-z0-9]*)\s*(?:\(|\{|,)", request_body
        )
    }
    event_body = rust_enum_body(provider_source, "ProviderEvent")
    provider_events = {
        camel_to_snake(name)
        for name in re.findall(
            r"(?m)^    ([A-Z][A-Za-z0-9]*)\s*(?:\(|\{|,)", event_body
        )
    }

    management_source = (
        TUI / "crates/cmux-tui-core/src/provider_management.rs"
    ).read_text()
    management_body = rust_enum_body(management_source, "Request")
    management_operations = {
        camel_to_snake(name)
        for name in re.findall(
            r"(?m)^    ([A-Z][A-Za-z0-9]*)\s*(?:\{|,)", management_body
        )
    }
    return {
        "terminal_host_v1": host_messages,
        "machine_provider_v1_requests": provider_requests,
        "machine_provider_v1_events": provider_events,
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


def expected_event_streams() -> dict[str, set[str]]:
    streams_by_event: dict[str, set[str]] = {}
    for stream, event_names_for_stream in EXPECTED_EVENTS_BY_STREAM.items():
        for name in event_names_for_stream:
            streams_by_event.setdefault(name, set()).add(stream)
    return streams_by_event


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
    compare_mapping(actual_profiles, EXPECTED_COMMAND_PROFILES, "command profile")
    commands = [name for group in command_groups.values() for name in group]
    inventory_commands = unique(commands, "command")
    runtime_commands = command_names()
    expected_profile_commands = set().union(*EXPECTED_COMMAND_PROFILES.values())
    compare(runtime_commands, expected_profile_commands, "command profile policy")
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
    policy_streams = expected_event_streams()
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


def validate_tui_actions(inventory: dict) -> list[dict]:
    actions = inventory["tui_actions"]
    inventory_actions = unique([action["variant"] for action in actions], "TUI action")
    compare(action_variants(), inventory_actions, "TUI action")
    allowed = {"direct", "composite", "presentation-only"}
    for action in actions:
        if action["classification"] not in allowed:
            fail(f"bad TUI action classification for {action['variant']}")
        if not action["route"].strip():
            fail(f"TUI action {action['variant']} has no programmability route")
    return actions


def validate_menu_actions(inventory: dict) -> list[dict]:
    menu_actions = inventory["menu_actions"]
    inventory_menu_actions = unique(
        [action["variant"] for action in menu_actions], "menu action"
    )
    compare(menu_action_variants(), inventory_menu_actions, "menu action")
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


def validate_secondary_protocols(inventory: dict) -> tuple[list[str], list[str]]:
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
    return expected_host, secondary["machine_provider_v1"]["requests"]


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
    expected_host, provider_requests = validate_secondary_protocols(inventory)
    validate_protocol_domains(inventory)

    print(
        "spec inventory ok: "
        f"{len(inventory_commands)} commands, "
        f"{len(inventory_events)} events, "
        f"{len(actions)} TUI actions, "
        f"{len(menu_actions)} menu actions, "
        f"{len(families)} feature families, "
        f"{len(expected_host)} terminal-host messages, "
        f"{len(provider_requests)} machine-provider requests"
    )


if __name__ == "__main__":
    main()
