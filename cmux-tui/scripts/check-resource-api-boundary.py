#!/usr/bin/env python3
"""Enforce the cmux resource-v1 public boundary.

The resource protocol intentionally has a smaller vocabulary than cmux's
internal mux.  This checker keeps opaque ID and operation registries in sync,
then scans the public CLI, docs, and handwritten SDK sources for legacy or
numeric resource identities.  Generated wire files are discovered from their
manifests.  Raw and internal directories must say so in their path.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Iterator, Mapping, Sequence


ROOT = Path(__file__).resolve().parents[2]
TUI = ROOT / "cmux-tui"


@dataclass(frozen=True, order=True)
class Diagnostic:
    path: Path
    line: int
    column: int
    code: str
    message: str

    def render(self, root: Path) -> str:
        try:
            path = self.path.relative_to(root)
        except ValueError:
            path = self.path
        return f"{path}:{self.line}:{self.column}: {self.code}: {self.message}"


@dataclass(frozen=True)
class ScanRule:
    label: str
    path: str
    extensions: frozenset[str]
    exact_names: frozenset[str] = frozenset()
    cli_literals_only: bool = False


# Every high-level package is scanned.  Tests, examples, generated manifest
# members, and directories literally named raw/internal are outside this
# public-boundary pass and have their own conformance coverage.
SCAN_RULES = (
    ScanRule("docs", "docs", frozenset({".md"})),
    ScanRule(
        "public specs",
        "spec",
        frozenset({".md", ".json"}),
        frozenset(
            {
                "README.md",
                "bindings.md",
                "cli.md",
                "plugins.md",
                "programmability.md",
                "resource-api-v1.md",
                "resource-api-v1.json",
            }
        ),
    ),
    ScanRule("Rust SDK", "bindings/rust/src", frozenset({".rs"})),
    ScanRule("Rust SDK docs", "bindings/rust/README.md", frozenset({".md"})),
    ScanRule("Rust sidebar SDK", "bindings/rust-sidebar/src", frozenset({".rs"})),
    ScanRule("Rust sidebar SDK docs", "bindings/rust-sidebar/README.md", frozenset({".md"})),
    ScanRule("Python SDK", "bindings/python/cmux", frozenset({".py"})),
    ScanRule("Python SDK docs", "bindings/python/README.md", frozenset({".md"})),
    ScanRule("TypeScript SDK", "bindings/typescript/src", frozenset({".ts"})),
    ScanRule("TypeScript SDK docs", "bindings/typescript/README.md", frozenset({".md"})),
    ScanRule("Go SDK", "bindings/go", frozenset({".go"})),
    ScanRule("Go SDK docs", "bindings/go/README.md", frozenset({".md"})),
    ScanRule("Java SDK", "bindings/java/src/com/cmux", frozenset({".java"})),
    ScanRule("Java SDK docs", "bindings/java/README.md", frozenset({".md"})),
    ScanRule("C++ SDK", "bindings/cpp/include/cmux", frozenset({".h", ".hpp"})),
    ScanRule("C++ SDK docs", "bindings/cpp/README.md", frozenset({".md"})),
    ScanRule("Zig SDK", "bindings/zig/src", frozenset({".zig"})),
    ScanRule("Zig SDK docs", "bindings/zig/README.md", frozenset({".md"})),
    ScanRule(
        "public CLI",
        "crates/cmux-tui/src/main.rs",
        frozenset({".rs"}),
        cli_literals_only=True,
    ),
    ScanRule(
        "public CLI",
        "crates/cmux-tui/src/cli.rs",
        frozenset({".rs"}),
        cli_literals_only=True,
    ),
    ScanRule(
        "public CLI modules",
        "crates/cmux-tui/src/cli",
        frozenset({".rs"}),
        cli_literals_only=True,
    ),
)


# These handwritten v10 modules remain reachable only through `cmux::raw`.
# Keeping the filenames explicit prevents a new sibling from silently escaping
# the high-level scan.  New low-level code belongs in a raw/ or internal/ dir.
EXPLICIT_INTERNAL_FILES = frozenset(
    {
        "bindings/rust/src/client.rs",
        "bindings/rust/src/codec.rs",
        "bindings/rust/src/convenience.rs",
        "bindings/rust/src/presence.rs",
        "bindings/rust/src/topology.rs",
    }
)


# This is the one product-level registry intentionally repeated in the
# checker.  The normative Markdown table, JSON Schema, Rust types, and selector
# recognizer must all match it exactly.
PUBLIC_ID_TYPES = (
    ("MachinePublicId", "machine"),
    ("SessionPublicId", "session"),
    ("WorkspacePublicId", "ws"),
    ("ScreenPublicId", "screen"),
    ("PanePublicId", "pane"),
    ("TabPublicId", "tab"),
    ("TerminalPublicId", "term"),
    ("BrowserPublicId", "browser"),
    ("ClientPublicId", "client"),
    ("SplitPublicId", "split"),
    ("StreamPublicId", "stream"),
    ("NotificationPublicId", "notification"),
    ("AgentPublicId", "agent"),
    ("FrontendProjectionPublicId", "projection"),
    ("PairingRequestPublicId", "pairing"),
    ("SidebarViewPublicId", "sidebar_view"),
    ("SidebarPluginPublicId", "sidebar_plugin"),
    ("ProviderScopePublicId", "provider_scope"),
    ("ProviderActionPublicId", "provider_action"),
    ("ProviderNoticePublicId", "provider_notice"),
)
EXPECTED_PREFIXES = tuple(prefix for _, prefix in PUBLIC_ID_TYPES)
RESOURCE_PREFIXES = tuple(prefix for prefix in EXPECTED_PREFIXES if prefix != "stream")
MARKDOWN_ID_TYPES = (
    ("Machine", "machine"),
    ("Session", "session"),
    ("Workspace", "ws"),
    ("Screen", "screen"),
    ("Pane", "pane"),
    ("Tab", "tab"),
    ("Terminal", "term"),
    ("Browser", "browser"),
    ("Client", "client"),
    ("Split", "split"),
    ("Stream", "stream"),
    ("Notification", "notification"),
    ("Agent", "agent"),
    ("Projection", "projection"),
    ("Pairing request", "pairing"),
    ("Sidebar view", "sidebar_view"),
    ("Sidebar plugin", "sidebar_plugin"),
    ("Provider scope", "provider_scope"),
    ("Provider action", "provider_action"),
    ("Provider notice", "provider_notice"),
)


OPERATION_RE = re.compile(r"^[a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*)+$")
IDENTIFIER_RE = re.compile(r"[A-Za-z][A-Za-z0-9_-]*")
SHORT_ID_RE = re.compile(
    r"(?i)(?:\bshort[ _-]*ids?\b|\bids?[ _-]*short\b|\bnumeric[ _-]*ids?\b)"
)
COLON_ID_RE = re.compile(
    r"(?i)\b(?:machine|session|workspace|ws|screen|pane|tab|terminal|term|browser|"
    r"client|split|stream|notification|agent|projection|pairing|sidebar|provider):[0-9a-f]+\b"
)
NUMERIC_TYPE = (
    r"(?:u(?:8|16|32|64|128|size)|i(?:8|16|32|64|128|size)|uint(?:8|16|32|64)_t|"
    r"int(?:8|16|32|64)_t|int|long|Integer|Long|number|bigint)"
)
RESOURCE_ID_STEM = (
    r"(?:machine|session|workspace|ws|screen|pane|tab|terminal|term|browser|client|"
    r"split|stream|notification|agent|projection|pairing|sidebar|provider)"
)
# Plain `id` is checked because it is the natural field on every high-level
# handle.  Longer names must start with a public resource noun, which avoids
# treating implementation counters and Java serialVersionUID as resource IDs.
ID_NAME = rf"(?:id|{RESOURCE_ID_STEM}[A-Za-z0-9_]*(?:_id|Id|ID))"
NUMERIC_ID_PATTERNS = (
    re.compile(rf"\b(?P<name>{ID_NAME})\b\s*:\s*(?P<type>{NUMERIC_TYPE})\b"),
    re.compile(rf"\b(?P<type>{NUMERIC_TYPE})\b\s+(?P<name>{ID_NAME})\b"),
    re.compile(rf"\b(?P<name>{ID_NAME})\b\s+(?P<type>{NUMERIC_TYPE})\b"),
    re.compile(
        rf"\btype\s+(?P<name>[A-Za-z][A-Za-z0-9]*(?:Id|ID))\s*=\s*"
        rf"(?P<type>{NUMERIC_TYPE})\b"
    ),
    re.compile(rf"[\"'](?P<name>{ID_NAME})[\"']\s*:\s*-?[0-9]+\b"),
    re.compile(
        rf"[\"'](?P<name>{ID_NAME})[\"']\s*:\s*\{{\s*[\"']type[\"']\s*:\s*"
        rf"[\"'](?P<type>integer|number)[\"']",
        re.DOTALL,
    ),
)


def _line_column(text: str, offset: int) -> tuple[int, int]:
    line = text.count("\n", 0, offset) + 1
    previous = text.rfind("\n", 0, offset)
    return line, offset - previous


def _diagnostic_at(
    path: Path,
    text: str,
    offset: int,
    code: str,
    message: str,
) -> Diagnostic:
    line, column = _line_column(text, offset)
    return Diagnostic(path, line, column, code, message)


def _read(path: Path, diagnostics: list[Diagnostic]) -> str | None:
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        diagnostics.append(Diagnostic(path, 1, 1, "boundary.read", str(error)))
        return None


def _json_object(path: Path, diagnostics: list[Diagnostic]) -> Mapping[str, object] | None:
    text = _read(path, diagnostics)
    if text is None:
        return None

    def reject_duplicates(pairs: list[tuple[str, object]]) -> dict[str, object]:
        value: dict[str, object] = {}
        for key, item in pairs:
            if key in value:
                raise ValueError(f"duplicate object key {key!r}")
            value[key] = item
        return value

    try:
        value = json.loads(text, object_pairs_hook=reject_duplicates)
    except (json.JSONDecodeError, ValueError) as error:
        line = getattr(error, "lineno", 1)
        column = getattr(error, "colno", 1)
        diagnostics.append(Diagnostic(path, line, column, "boundary.json", str(error)))
        return None
    if not isinstance(value, dict):
        diagnostics.append(
            Diagnostic(path, 1, 1, "boundary.json", "top-level value must be an object")
        )
        return None
    return value


def _balanced_body(text: str, marker: re.Pattern[str]) -> tuple[str, int] | None:
    match = marker.search(text)
    if match is None:
        return None
    start = match.end()
    depth = 1
    for offset in range(start, len(text)):
        if text[offset] == "{":
            depth += 1
        elif text[offset] == "}":
            depth -= 1
            if depth == 0:
                return text[start:offset], start
    return None


def _compare_registry(
    diagnostics: list[Diagnostic],
    path: Path,
    text: str,
    actual: Iterable[str],
    expected: Iterable[str],
    label: str,
) -> None:
    actual_set = set(actual)
    expected_set = set(expected)
    for value in sorted(expected_set - actual_set):
        diagnostics.append(
            Diagnostic(path, 1, 1, "boundary.registry", f"{label} is missing {value!r}")
        )
    for value in sorted(actual_set - expected_set):
        offset = text.find(value)
        diagnostics.append(
            _diagnostic_at(
                path,
                text,
                max(offset, 0),
                "boundary.registry",
                f"{label} has unregistered value {value!r}",
            )
        )


def _markdown_prefixes(path: Path, diagnostics: list[Diagnostic]) -> set[str]:
    text = _read(path, diagnostics)
    if text is None:
        return set()
    lines = text.splitlines()
    header = next(
        (index for index, line in enumerate(lines) if line.strip() == "| Resource | Prefix |"),
        None,
    )
    if header is None:
        diagnostics.append(
            Diagnostic(path, 1, 1, "boundary.prefix", "missing Resource/Prefix table")
        )
        return set()
    prefixes: set[str] = set()
    resources: dict[str, str] = {}
    for index in range(header + 2, len(lines)):
        line = lines[index]
        if not line.startswith("|"):
            break
        cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
        if len(cells) != 2:
            diagnostics.append(
                Diagnostic(path, index + 1, 1, "boundary.prefix", "malformed prefix row")
            )
            continue
        match = re.fullmatch(r"`([a-z][a-z0-9_]*_)`", cells[1])
        if match is None:
            diagnostics.append(
                Diagnostic(
                    path,
                    index + 1,
                    1,
                    "boundary.prefix",
                    "prefix must be a lowercase backticked token ending in underscore",
                )
            )
            continue
        prefix = match.group(1)[:-1]
        resource = cells[0]
        if resource in resources:
            diagnostics.append(
                Diagnostic(path, index + 1, 1, "boundary.prefix", f"duplicate resource {resource!r}")
            )
        if prefix in prefixes:
            diagnostics.append(
                Diagnostic(path, index + 1, 1, "boundary.prefix", f"duplicate prefix {prefix!r}")
            )
        resources[resource] = prefix
        prefixes.add(prefix)
    _compare_registry(diagnostics, path, text, prefixes, EXPECTED_PREFIXES, "Markdown prefix table")
    expected_resources = dict(MARKDOWN_ID_TYPES)
    for resource, prefix in MARKDOWN_ID_TYPES:
        if resources.get(resource) != prefix:
            diagnostics.append(
                Diagnostic(
                    path,
                    header + 1,
                    1,
                    "boundary.prefix",
                    f"Markdown resource {resource!r} must use prefix {prefix!r}",
                )
            )
    for resource in sorted(set(resources) - set(expected_resources)):
        diagnostics.append(
            Diagnostic(
                path,
                header + 1,
                1,
                "boundary.prefix",
                f"Markdown prefix table has unregistered resource {resource!r}",
            )
        )
    return prefixes


def _schema_prefixes(path: Path, diagnostics: list[Diagnostic]) -> set[str]:
    document = _json_object(path, diagnostics)
    if document is None:
        return set()
    try:
        definitions = document["$defs"]
        if not isinstance(definitions, dict):
            raise TypeError("$defs must be an object")
        resource = definitions["resourceId"]
        stream = definitions["streamId"]
        if not isinstance(resource, dict) or not isinstance(stream, dict):
            raise TypeError("resourceId and streamId must be objects")
        resource_pattern = resource["pattern"]
        stream_pattern = stream["pattern"]
        if not isinstance(resource_pattern, str) or not isinstance(stream_pattern, str):
            raise TypeError("ID patterns must be strings")
    except (KeyError, TypeError) as error:
        diagnostics.append(Diagnostic(path, 1, 1, "boundary.prefix", str(error)))
        return set()

    expected_resource = f"^({'|'.join(RESOURCE_PREFIXES)})_[0-9a-f]{{32}}$"
    expected_stream = r"^stream_[0-9a-f]{32}$"
    text = path.read_text(encoding="utf-8")
    if resource_pattern != expected_resource:
        offset = text.find('"resourceId"')
        diagnostics.append(
            _diagnostic_at(
                path,
                text,
                max(offset, 0),
                "boundary.prefix",
                f"resourceId pattern must be {expected_resource!r}",
            )
        )
    if stream_pattern != expected_stream:
        offset = text.find('"streamId"')
        diagnostics.append(
            _diagnostic_at(
                path,
                text,
                max(offset, 0),
                "boundary.prefix",
                f"streamId pattern must be {expected_stream!r}",
            )
        )
    return set(EXPECTED_PREFIXES) if not any(
        item.path == path and item.code == "boundary.prefix" for item in diagnostics
    ) else set()


def _rust_prefixes(path: Path, diagnostics: list[Diagnostic]) -> set[str]:
    text = _read(path, diagnostics)
    if text is None:
        return set()
    declarations = re.findall(
        r"(?m)^public_id!\(([A-Z][A-Za-z0-9]*),\s*\"([a-z][a-z0-9_]*)\"\);$",
        text,
    )
    actual = {type_name: prefix for type_name, prefix in declarations}
    expected = dict(PUBLIC_ID_TYPES)
    if len(declarations) != len(actual):
        diagnostics.append(
            Diagnostic(path, 1, 1, "boundary.prefix", "Rust ID registry repeats a type")
        )
    declared_prefixes = [prefix for _, prefix in declarations]
    if len(declared_prefixes) != len(set(declared_prefixes)):
        diagnostics.append(
            Diagnostic(path, 1, 1, "boundary.prefix", "Rust ID registry repeats a prefix")
        )
    for type_name, prefix in PUBLIC_ID_TYPES:
        if type_name not in actual:
            diagnostics.append(
                Diagnostic(
                    path,
                    1,
                    1,
                    "boundary.prefix",
                    f"Rust ID registry is missing {type_name} with prefix {prefix!r}",
                )
            )
        elif actual[type_name] != prefix:
            offset = text.find(f"public_id!({type_name}")
            diagnostics.append(
                _diagnostic_at(
                    path,
                    text,
                    max(offset, 0),
                    "boundary.prefix",
                    f"{type_name} must use prefix {prefix!r}, found {actual[type_name]!r}",
                )
            )
    for type_name in sorted(set(actual) - set(expected)):
        offset = text.find(f"public_id!({type_name}")
        diagnostics.append(
            _diagnostic_at(
                path,
                text,
                max(offset, 0),
                "boundary.prefix",
                f"Rust ID registry has unregistered type {type_name}",
            )
        )

    selector = _balanced_body(
        text,
        re.compile(r"\bfn\s+is_registered_public_id\s*\([^)]*\)[^{]*\{"),
    )
    if selector is None:
        diagnostics.append(
            Diagnostic(path, 1, 1, "boundary.prefix", "missing is_registered_public_id")
        )
    else:
        body, body_offset = selector
        selector_prefixes = set(re.findall(r'"([a-z][a-z0-9_]*)"', body))
        missing = set(EXPECTED_PREFIXES) - selector_prefixes
        stale = selector_prefixes - set(EXPECTED_PREFIXES)
        for prefix in sorted(missing):
            line, column = _line_column(text, body_offset)
            diagnostics.append(
                Diagnostic(
                    path,
                    line,
                    column,
                    "boundary.prefix",
                    f"selector ID registry is missing {prefix!r}",
                )
            )
        for prefix in sorted(stale):
            relative = body.find(f'"{prefix}"')
            diagnostics.append(
                _diagnostic_at(
                    path,
                    text,
                    body_offset + max(relative, 0),
                    "boundary.prefix",
                    f"selector ID registry has unregistered prefix {prefix!r}",
                )
            )
    return set(actual.values())


def _runtime_operations(path: Path, diagnostics: list[Diagnostic]) -> dict[str, int]:
    text = _read(path, diagnostics)
    if text is None:
        return {}
    enum = _balanced_body(
        text,
        re.compile(r"\bpub\s+enum\s+ResourceOperation\s*\{"),
    )
    if enum is None:
        diagnostics.append(
            Diagnostic(path, 1, 1, "boundary.operation", "missing ResourceOperation enum")
        )
        return {}
    body, body_offset = enum
    operations: dict[str, int] = {}
    matches = list(
        re.finditer(
            r"#\[serde\(rename\s*=\s*\"([^\"]+)\"\)\]\s*"
            r"([A-Z][A-Za-z0-9]*)\s*(?:,|\{|\()",
            body,
        )
    )
    variants = re.findall(r"(?m)^\s*([A-Z][A-Za-z0-9]*)\s*(?:,|\{|\()", body)
    if len(matches) != len(variants):
        diagnostics.append(
            _diagnostic_at(
                path,
                text,
                body_offset,
                "boundary.operation",
                "every ResourceOperation variant must have one serde rename",
            )
        )
    for match in matches:
        operation = match.group(1)
        offset = body_offset + match.start(1)
        if not OPERATION_RE.fullmatch(operation):
            diagnostics.append(
                _diagnostic_at(
                    path,
                    text,
                    offset,
                    "boundary.operation",
                    f"invalid dotted operation {operation!r}",
                )
            )
        if operation in operations:
            diagnostics.append(
                _diagnostic_at(
                    path,
                    text,
                    offset,
                    "boundary.operation",
                    f"duplicate runtime operation {operation!r}",
                )
            )
        operations[operation] = offset
    return operations


def _inventory_operations(path: Path, diagnostics: list[Diagnostic]) -> dict[str, int]:
    document = _json_object(path, diagnostics)
    if document is None:
        return {}
    values = document.get("resource_operations")
    if not isinstance(values, list) or not all(isinstance(value, str) for value in values):
        diagnostics.append(
            Diagnostic(
                path,
                1,
                1,
                "boundary.operation",
                "resource_operations must be an array of exact dotted strings",
            )
        )
        return {}
    if not values:
        diagnostics.append(
            Diagnostic(path, 1, 1, "boundary.operation", "resource_operations cannot be empty")
        )
        return {}
    text = path.read_text(encoding="utf-8")
    if values != sorted(values):
        offset = text.find('"resource_operations"')
        diagnostics.append(
            _diagnostic_at(
                path,
                text,
                max(offset, 0),
                "boundary.operation",
                "resource_operations must be lexicographically sorted",
            )
        )
    operations: dict[str, int] = {}
    search_from = 0
    for operation in values:
        quoted = json.dumps(operation)
        offset = text.find(quoted, search_from)
        if offset < 0:
            offset = text.find(quoted)
        search_from = max(offset, 0) + len(quoted)
        value_offset = max(offset, 0) + 1
        if not OPERATION_RE.fullmatch(operation):
            diagnostics.append(
                _diagnostic_at(
                    path,
                    text,
                    value_offset,
                    "boundary.operation",
                    f"invalid dotted operation {operation!r}",
                )
            )
        if operation in operations:
            diagnostics.append(
                _diagnostic_at(
                    path,
                    text,
                    value_offset,
                    "boundary.operation",
                    f"duplicate inventory operation {operation!r}",
                )
            )
        operations[operation] = value_offset
    return operations


def _markdown_operations(path: Path, diagnostics: list[Diagnostic]) -> dict[str, int]:
    text = _read(path, diagnostics)
    if text is None:
        return {}
    lines = text.splitlines(keepends=True)
    section = next(
        (index for index, line in enumerate(lines) if line.strip() == "## Operations"),
        None,
    )
    if section is None:
        diagnostics.append(
            Diagnostic(path, 1, 1, "boundary.operation", "missing Operations section")
        )
        return {}
    operations: dict[str, int] = {}
    absolute_offset = sum(len(line) for line in lines[: section + 1])
    in_table = False
    for index in range(section + 1, len(lines)):
        line = lines[index]
        if line.startswith("## "):
            break
        if line.strip() == "| Scope | Operations |":
            in_table = True
            absolute_offset += len(line)
            continue
        if not in_table or re.fullmatch(r"\|[ :|-]+\|[ :|-]+\|\s*\n?", line):
            absolute_offset += len(line)
            continue
        if not line.startswith("|"):
            absolute_offset += len(line)
            continue
        cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
        if len(cells) != 2:
            diagnostics.append(
                Diagnostic(path, index + 1, 1, "boundary.operation", "malformed operation row")
            )
            absolute_offset += len(line)
            continue
        scope = re.sub(r"[ -]+", "_", cells[0].lower())
        tokens = list(re.finditer(r"`([^`]+)`", cells[1]))
        if not tokens:
            diagnostics.append(
                Diagnostic(path, index + 1, 1, "boundary.operation", "operation row is empty")
            )
        token_cursor = 0
        for token_match in tokens:
            token = token_match.group(1)
            operation = token if token.startswith(f"{scope}.") else f"{scope}.{token}"
            token_in_line = line.find(f"`{token}`", token_cursor) + 1
            token_cursor = token_in_line + len(token) + 1
            offset = absolute_offset + max(token_in_line, 0)
            if not OPERATION_RE.fullmatch(operation):
                diagnostics.append(
                    _diagnostic_at(
                        path,
                        text,
                        offset,
                        "boundary.operation",
                        f"invalid dotted operation {operation!r}",
                    )
                )
            if operation in operations:
                diagnostics.append(
                    _diagnostic_at(
                        path,
                        text,
                        offset,
                        "boundary.operation",
                        f"duplicate normative operation {operation!r}",
                    )
                )
            operations[operation] = offset
        absolute_offset += len(line)
    if not in_table:
        diagnostics.append(
            Diagnostic(path, section + 1, 1, "boundary.operation", "missing operation table")
        )
    return operations


def _compare_operations(
    diagnostics: list[Diagnostic],
    canonical_path: Path,
    canonical_text: str,
    canonical: Mapping[str, int],
    other_path: Path,
    other_text: str,
    other: Mapping[str, int],
    label: str,
) -> None:
    for operation in sorted(set(canonical) - set(other)):
        diagnostics.append(
            _diagnostic_at(
                canonical_path,
                canonical_text,
                canonical[operation],
                "boundary.operation",
                f"{operation!r} is missing from {label}",
            )
        )
    for operation in sorted(set(other) - set(canonical)):
        diagnostics.append(
            _diagnostic_at(
                other_path,
                other_text,
                other[operation],
                "boundary.operation",
                f"{operation!r} is not in canonical resource_operations",
            )
        )


def check_contracts(tui: Path) -> list[Diagnostic]:
    diagnostics: list[Diagnostic] = []
    markdown = tui / "spec/resource-api-v1.md"
    schema = tui / "spec/resource-api-v1.json"
    inventory = tui / "spec/inventory.json"
    resource = tui / "crates/cmux-tui-core/src/resource.rs"

    markdown_prefixes = _markdown_prefixes(markdown, diagnostics)
    schema_prefixes = _schema_prefixes(schema, diagnostics)
    rust_prefixes = _rust_prefixes(resource, diagnostics)
    if markdown_prefixes and schema_prefixes and markdown_prefixes != schema_prefixes:
        diagnostics.append(
            Diagnostic(markdown, 1, 1, "boundary.prefix", "Markdown and JSON prefixes differ")
        )
    if markdown_prefixes and rust_prefixes and markdown_prefixes != rust_prefixes:
        diagnostics.append(
            Diagnostic(resource, 1, 1, "boundary.prefix", "Rust and Markdown prefixes differ")
        )

    canonical = _inventory_operations(inventory, diagnostics)
    runtime = _runtime_operations(resource, diagnostics)
    normative = _markdown_operations(markdown, diagnostics)
    if canonical:
        canonical_text = inventory.read_text(encoding="utf-8")
        resource_text = resource.read_text(encoding="utf-8")
        markdown_text = markdown.read_text(encoding="utf-8")
        _compare_operations(
            diagnostics,
            inventory,
            canonical_text,
            canonical,
            resource,
            resource_text,
            runtime,
            "the Rust ResourceOperation registry",
        )
        _compare_operations(
            diagnostics,
            inventory,
            canonical_text,
            canonical,
            markdown,
            markdown_text,
            normative,
            "the normative operation table",
        )
    return sorted(set(diagnostics))


def _generated_manifest_paths(tui: Path, diagnostics: list[Diagnostic]) -> set[Path]:
    generated: set[Path] = set()
    bindings = tui / "bindings"
    if not bindings.exists():
        return generated
    for manifest in sorted(bindings.rglob(".cmux-sdk-manifest.json")):
        document = _json_object(manifest, diagnostics)
        if document is None:
            continue
        files = document.get("files")
        if not isinstance(files, list):
            diagnostics.append(
                Diagnostic(manifest, 1, 1, "boundary.manifest", "files must be an array")
            )
            continue
        for index, entry in enumerate(files):
            if not isinstance(entry, dict) or not isinstance(entry.get("path"), str):
                diagnostics.append(
                    Diagnostic(
                        manifest,
                        1,
                        1,
                        "boundary.manifest",
                        f"files[{index}].path must be a string",
                    )
                )
                continue
            relative = Path(entry["path"])
            if relative.is_absolute() or ".." in relative.parts:
                diagnostics.append(
                    Diagnostic(
                        manifest,
                        1,
                        1,
                        "boundary.manifest",
                        f"generated path must stay below manifest: {entry['path']!r}",
                    )
                )
                continue
            generated.add((manifest.parent / relative).resolve())
    return generated


def _is_raw_or_internal(path: Path, tui: Path) -> bool:
    try:
        relative = path.relative_to(tui)
    except ValueError:
        return False
    return relative.as_posix() in EXPLICIT_INTERNAL_FILES or any(
        part in {"raw", "internal"} for part in relative.parts
    )


def _is_test_or_example(path: Path) -> bool:
    parts = set(path.parts)
    name = path.name.lower()
    return (
        bool(parts & {"test", "tests", "example", "examples", "e2e", "cmd"})
        or name.endswith("_test.go")
        or "_test." in name
        or name.startswith("test_")
        or name.endswith("test.zig")
    )


def _files_for_rule(tui: Path, rule: ScanRule) -> Iterator[Path]:
    root = tui / rule.path
    if root.is_file():
        if root.suffix in rule.extensions:
            yield root
        return
    if not root.is_dir():
        return
    for path in sorted(root.rglob("*")):
        if not path.is_file() or path.suffix not in rule.extensions:
            continue
        if rule.exact_names and path.name not in rule.exact_names:
            continue
        yield path


def _rust_string_regions(text: str) -> Iterator[tuple[int, int]]:
    """Yield byte-index-equivalent Python offsets for Rust string contents."""
    index = 0
    while index < len(text):
        raw = re.match(r"(?:br|cr|r)(?P<hashes>#{0,255})\"", text[index:])
        if raw is not None:
            hashes = raw.group("hashes")
            content_start = index + raw.end()
            terminator = '"' + hashes
            end = text.find(terminator, content_start)
            if end < 0:
                return
            yield content_start, end
            index = end + len(terminator)
            continue
        if text[index] == '"':
            content_start = index + 1
            cursor = content_start
            while cursor < len(text):
                if text[cursor] == "\\":
                    cursor += 2
                elif text[cursor] == '"':
                    yield content_start, cursor
                    cursor += 1
                    break
                else:
                    cursor += 1
            index = cursor
            continue
        index += 1


def _identifier_parts(identifier: str) -> list[str]:
    value = re.sub(r"([a-z0-9])([A-Z])", r"\1_\2", identifier)
    return [part.lower() for part in re.split(r"[_-]+", value) if part]


def _scan_region(path: Path, text: str, start: int, end: int) -> list[Diagnostic]:
    diagnostics: list[Diagnostic] = []
    region = text[start:end]
    occupied: set[tuple[str, int]] = set()

    for match in IDENTIFIER_RE.finditer(region):
        parts = _identifier_parts(match.group(0))
        if "surface" in parts or "surfaces" in parts:
            offset = start + match.start()
            diagnostics.append(
                _diagnostic_at(
                    path,
                    text,
                    offset,
                    "boundary.surface",
                    f"legacy public resource word in {match.group(0)!r}; use terminal or browser",
                )
            )
            occupied.add(("surface", offset))

    for match in SHORT_ID_RE.finditer(region):
        offset = start + match.start()
        diagnostics.append(
            _diagnostic_at(
                path,
                text,
                offset,
                "boundary.short-id",
                "public resource IDs cannot have numeric or short forms",
            )
        )

    for match in COLON_ID_RE.finditer(region):
        offset = start + match.start()
        diagnostics.append(
            _diagnostic_at(
                path,
                text,
                offset,
                "boundary.short-id",
                f"legacy short selector {match.group(0)!r}; use an opaque prefixed ID",
            )
        )

    for pattern in NUMERIC_ID_PATTERNS:
        for match in pattern.finditer(region):
            offset = start + match.start("name")
            key = ("numeric", offset)
            if key in occupied:
                continue
            occupied.add(key)
            numeric = match.groupdict().get("type") or "integer literal"
            diagnostics.append(
                _diagnostic_at(
                    path,
                    text,
                    offset,
                    "boundary.numeric-id",
                    f"public ID {match.group('name')!r} uses numeric representation {numeric!r}",
                )
            )
    return diagnostics


def scan_public_boundaries(tui: Path) -> tuple[list[Diagnostic], int]:
    diagnostics: list[Diagnostic] = []
    generated = _generated_manifest_paths(tui, diagnostics)
    scanned: set[Path] = set()
    for rule in SCAN_RULES:
        for path in _files_for_rule(tui, rule):
            resolved = path.resolve()
            if resolved in scanned or resolved in generated:
                continue
            if _is_raw_or_internal(path, tui) or _is_test_or_example(path):
                continue
            scanned.add(resolved)
            text = _read(path, diagnostics)
            if text is None:
                continue
            regions: Iterable[tuple[int, int]]
            if rule.cli_literals_only:
                regions = _rust_string_regions(text)
            else:
                regions = ((0, len(text)),)
            for start, end in regions:
                diagnostics.extend(_scan_region(path, text, start, end))
    return sorted(set(diagnostics)), len(scanned)


def run(tui: Path) -> tuple[list[Diagnostic], int]:
    contract_diagnostics = check_contracts(tui)
    scan_diagnostics, scanned = scan_public_boundaries(tui)
    return sorted(set(contract_diagnostics + scan_diagnostics)), scanned


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--tui-root",
        type=Path,
        default=TUI,
        help="cmux-tui directory to check (default: repository cmux-tui)",
    )
    args = parser.parse_args(argv)
    tui = args.tui_root.resolve()
    diagnostics, scanned = run(tui)
    for diagnostic in diagnostics:
        print(diagnostic.render(tui), file=sys.stderr)
    if diagnostics:
        print(
            f"resource API boundary check failed with {len(diagnostics)} diagnostic(s)",
            file=sys.stderr,
        )
        return 1
    print(f"resource API boundary check passed ({scanned} public files scanned)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
