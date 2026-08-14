#!/usr/bin/env python3
"""Enforce the cmux resource-v2 public boundary.

The resource protocol intentionally has a smaller vocabulary than cmux's
internal mux.  This checker keeps opaque ID and operation registries in sync,
then scans the public CLI, docs, and handwritten SDK sources for legacy or
numeric resource identities.  Generated wire files are discovered from their
manifests.  Raw and internal directories must say so in their path.
"""

from __future__ import annotations

import argparse
import hashlib
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
    private_identity_exceptions: frozenset[str] = frozenset()


# Every high-level package is scanned.  Tests, examples, generated manifest
# members, and directories literally named raw/internal are outside this
# public-boundary pass and have their own conformance coverage.
SCAN_RULES = (
    ScanRule(
        "public docs",
        "docs",
        frozenset({".md"}),
        frozenset({"README.md", "getting-started.md"}),
    ),
    ScanRule(
        "public specs",
        "spec",
        frozenset({".md", ".json"}),
        frozenset(
            {
                "README.md",
                "bindings.md",
                "cli.md",
                "resource-api-v2.md",
                "resource-api-v2.json",
                "resource-operations-v2.md",
                "resource-operations-v2.json",
                "resource-operations-v2.schema.json",
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
        # The remote daemon's relay routing key belongs to its separately
        # versioned transport protocol, not to the resource-v2 selector model.
        private_identity_exceptions=frozenset({"relay-slot"}),
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
)

TRANSPORT_OPERATION_CLASSES = (
    "read",
    "mutation",
    "stream_open",
    "connection_control",
)
ALL_OPERATION_CLASSES = TRANSPORT_OPERATION_CLASSES + ("local",)
STRUCTURAL_SCOPES = frozenset({"workspace", "screen", "pane", "tab"})
# These operations can cross cmux's durable transaction boundary before their
# outcome is journaled. A daemon restart must never guess that repeating one is
# safe. Keep this set explicit so a future catalog edit cannot silently promise
# exactly-once delivery for an effect that cmux cannot prove completed.
EXTERNALLY_EFFECTFUL_MUTATIONS = frozenset(
    {
        "browser.activate",
        "browser.back",
        "browser.close",
        "browser.forward",
        "browser.input.key",
        "browser.input.mouse",
        "browser.input.text",
        "browser.input.wheel",
        "browser.navigate",
        "browser.reload",
        "notification.create",
        "pane.close",
        "pane.create",
        "pane.run",
        "pane.split",
        "screen.close",
        "screen.create",
        "screen.layout.undo",
        "session.open",
        "session.reload_config",
        "session.shutdown",
        "session.window.title.clear",
        "session.window.title.set",
        "sidebar_view.ensure",
        "sidebar_view.input",
        "sidebar_view.reload",
        "tab.close",
        "tab.create_browser",
        "tab.create_terminal",
        "terminal.close",
        "terminal.history.clear",
        "terminal.input.focus",
        "terminal.input.keys",
        "terminal.input.mouse",
        "terminal.input.write",
        "terminal.viewport.scroll",
        "workspace.close",
        "workspace.create",
        "workspace.layout.apply",
        "workspace.run",
    }
)
CORRELATED_CREATION_OPERATIONS = frozenset(
    {
        "pane.create",
        "pane.run",
        "pane.split",
        "screen.create",
        "tab.create_browser",
        "tab.create_terminal",
        "workspace.create",
        "workspace.run",
    }
)
FORBIDDEN_PUBLIC_IDENTITY_FIELDS = frozenset(
    {
        "key",
        "workspace_key",
        "requested_key",
        "slot",
        "numeric_id",
        "short_id",
        "surface",
        "surface_id",
        "incarnation",
    }
)
FORBIDDEN_PUBLIC_FIELDS = FORBIDDEN_PUBLIC_IDENTITY_FIELDS - {"key"}
SNAPSHOT_TYPE_RE = re.compile(r"(?:Snapshot|CreatedPath|CreatedWorkspace|CreatedTerminal|CreatedBrowser)$")


OPERATION_RE = re.compile(r"^[a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*)+$")
IDENTIFIER_RE = re.compile(r"[A-Za-z][A-Za-z0-9_-]*")
SHORT_ID_RE = re.compile(
    r"(?i)(?:\bshort[ _-]*ids?\b|\bids?[ _-]*short\b|\bnumeric[ _-]*ids?\b)"
)
PRIVATE_IDENTITY_RE = re.compile(
    r"(?i)\b(?:workspace[_-]?key|requested[_-]?key|slot|numeric[_-]?id|short[_-]?id|incarnation)\b"
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


def _runtime_operation_classes(
    path: Path,
    diagnostics: list[Diagnostic],
) -> tuple[dict[str, str], dict[str, str]]:
    text = _read(path, diagnostics)
    if text is None:
        return {}, {}

    def enum_registry(enum_name: str) -> tuple[dict[str, str], int]:
        enum = _balanced_body(
            text,
            re.compile(rf"\bpub\s+enum\s+{re.escape(enum_name)}\s*\{{"),
        )
        if enum is None:
            diagnostics.append(
                Diagnostic(path, 1, 1, "boundary.operation", f"missing {enum_name} enum")
            )
            return {}, 0
        body, body_offset = enum
        return {
            match.group(2): match.group(1)
            for match in re.finditer(
                r"#\[serde\(rename\s*=\s*\"([^\"]+)\"\)\]\s*"
                r"([A-Z][A-Za-z0-9]*)\s*(?:,|\{|\()",
                body,
            )
        }, body_offset

    variants, _ = enum_registry("ResourceOperation")
    local_variants, _ = enum_registry("LocalOperation")
    class_method = _balanced_body(
        text,
        re.compile(
            r"\bimpl\s+ResourceOperation\s*\{.*?"
            r"\bpub\s+const\s+fn\s+class\s*\(\s*self\s*\)\s*->\s*OperationClass\s*\{",
            re.DOTALL,
        ),
    )
    if class_method is None:
        diagnostics.append(
            Diagnostic(path, 1, 1, "boundary.operation-class", "missing ResourceOperation::class")
        )
        return {}, {operation: "local" for operation in local_variants.values()}

    body, body_offset = class_method
    classes: dict[str, str] = {}
    assigned_variants: set[str] = set()
    branch_re = re.compile(
        r"(?:\A\s*|\belse\s+)if\s+matches!\(\s*self\s*,(?P<variants>.*?)\)"
        r"\s*\{\s*OperationClass::(?P<class>[A-Z][A-Za-z0-9]*)",
        re.DOTALL,
    )
    for branch in branch_re.finditer(body):
        wire_class = re.sub(r"(?<!^)(?=[A-Z])", "_", branch.group("class")).lower()
        if wire_class not in TRANSPORT_OPERATION_CLASSES:
            diagnostics.append(
                _diagnostic_at(
                    path,
                    text,
                    body_offset + branch.start("class"),
                    "boundary.operation-class",
                    f"unsupported runtime operation class {wire_class!r}",
                )
            )
            continue
        for variant in re.findall(r"\bSelf::([A-Z][A-Za-z0-9]*)\b", branch.group("variants")):
            operation = variants.get(variant)
            if operation is None:
                diagnostics.append(
                    _diagnostic_at(
                        path,
                        text,
                        body_offset + branch.start("variants"),
                        "boundary.operation-class",
                        f"class registry references unknown ResourceOperation::{variant}",
                    )
                )
                continue
            if variant in assigned_variants:
                diagnostics.append(
                    _diagnostic_at(
                        path,
                        text,
                        body_offset + branch.start("variants"),
                        "boundary.operation-class",
                        f"ResourceOperation::{variant} has more than one class",
                    )
                )
            assigned_variants.add(variant)
            classes[operation] = wire_class

    if "OperationClass::Mutation" not in body:
        diagnostics.append(
            _diagnostic_at(
                path,
                text,
                body_offset,
                "boundary.operation-class",
                "ResourceOperation::class must have a Mutation fallback",
            )
        )
    for variant, operation in variants.items():
        if variant not in assigned_variants:
            classes[operation] = "mutation"
    return classes, {operation: "local" for operation in local_variants.values()}


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


def _markdown_operation_classes(
    path: Path,
    diagnostics: list[Diagnostic],
) -> tuple[dict[str, int], dict[str, str]]:
    text = _read(path, diagnostics)
    if text is None:
        return {}, {}
    lines = text.splitlines(keepends=True)
    section = next(
        (
            index
            for index, line in enumerate(lines)
            if line.strip() in {"## Operations", "## Typed operation catalog"}
        ),
        None,
    )
    if section is None:
        diagnostics.append(
            Diagnostic(path, 1, 1, "boundary.operation", "missing Operations section")
        )
        return {}, {}
    operations: dict[str, int] = {}
    classes: dict[str, str] = {}
    absolute_offset = sum(len(line) for line in lines[: section + 1])
    in_table = False
    for index in range(section + 1, len(lines)):
        line = lines[index]
        if line.startswith("## "):
            break
        if line.strip() == "| Class | Operations |":
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
        operation_class = cells[0].strip("`")
        if operation_class not in ALL_OPERATION_CLASSES:
            diagnostics.append(
                Diagnostic(
                    path,
                    index + 1,
                    1,
                    "boundary.operation-class",
                    f"invalid Markdown operation class {operation_class!r}",
                )
            )
        tokens = list(re.finditer(r"`([^`]+)`", cells[1]))
        if not tokens:
            diagnostics.append(
                Diagnostic(path, index + 1, 1, "boundary.operation", "operation row is empty")
            )
        token_cursor = 0
        for token_match in tokens:
            operation = token_match.group(1)
            token_in_line = line.find(f"`{operation}`", token_cursor) + 1
            token_cursor = token_in_line + len(operation) + 1
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
            classes[operation] = operation_class
        absolute_offset += len(line)
    if not in_table:
        diagnostics.append(
            Diagnostic(path, section + 1, 1, "boundary.operation", "missing operation table")
        )
    return operations, classes


def _markdown_operations(path: Path, diagnostics: list[Diagnostic]) -> dict[str, int]:
    operations, _ = _markdown_operation_classes(path, diagnostics)
    return operations


def _catalog_diagnostic(
    diagnostics: list[Diagnostic],
    path: Path,
    text: str,
    message: str,
    token: str = "",
    code: str = "boundary.catalog",
) -> None:
    offset = text.find(json.dumps(token)) if token else 0
    diagnostics.append(
        _diagnostic_at(path, text, max(offset, 0), code, message)
    )


def _validate_catalog_type(
    expression: object,
    *,
    context: str,
    path: Path,
    text: str,
    diagnostics: list[Diagnostic],
    type_names: set[str],
    generics: Mapping[str, object],
    scopes: set[str],
    parameters: set[str] = frozenset(),
) -> None:
    def fail(message: str, token: str = "") -> None:
        _catalog_diagnostic(diagnostics, path, text, f"{context}: {message}", token)

    if not isinstance(expression, dict):
        fail("type expression must be an object")
        return
    kind = expression.get("kind")
    allowed_by_kind = {
        "primitive": {"kind", "name", "minimum", "maximum", "min_length", "max_length"},
        "resource_id": {"kind", "resource"},
        "selector": {"kind", "resource"},
        "ref": {"kind", "name"},
        "parameter": {"kind", "name"},
        "apply": {"kind", "name", "arguments"},
        "enum": {"kind", "values"},
        "array": {"kind", "items", "min_items", "max_items"},
        "map": {"kind", "values"},
        "nullable": {"kind", "value"},
        "union": {
            "kind",
            "variants",
            "discriminator",
            "unknown_variant",
            "constraints",
        },
        "object": {"kind", "fields", "extra", "constraints"},
    }
    if kind not in allowed_by_kind:
        fail(f"unknown type kind {kind!r}")
        return
    unknown = set(expression) - allowed_by_kind[kind]
    if unknown:
        fail(f"unknown {kind} properties {sorted(unknown)!r}")

    if kind == "primitive":
        name = expression.get("name")
        primitives = {
            "string",
            "boolean",
            "uint16",
            "uint32",
            "uint64",
            "int32",
            "float64",
            "decimal",
            "base64",
            "json",
        }
        if name not in primitives:
            fail(f"unknown primitive {name!r}")
        if name == "json" and context != "types.JsonValue":
            fail("vague json is allowed only in the named JsonValue type")
        if name == "uint64":
            fail("uint64 wire values must use decimal strings")
        return
    if kind in {"resource_id", "selector"}:
        resource = expression.get("resource")
        if resource not in scopes:
            fail(f"unknown resource scope {resource!r}", str(resource))
        return
    if kind == "ref":
        name = expression.get("name")
        if name not in type_names:
            fail(f"unknown type reference {name!r}", str(name))
        if name == "JsonValue":
            allowed_json_contexts = {
                "types.FrontendProjectionSnapshot.fields.projection",
                "types.JournalEventSchema.fields.payload_schema",
                "types.JournalIngressEvent.fields.payload",
                "types.JournalRestorePreview.fields.state",
                "types.SessionJournalRecord.fields.payload",
                "types.StreamError.fields.details",
                "errors.operation.failed.details.fields.extra.values",
                "operations.frontend_projection.put.params.fields.projection",
            }
            is_explicit_extra = (
                context.startswith("types.")
                and context.endswith(".fields.extra.values")
            )
            if context not in allowed_json_contexts and not is_explicit_extra:
                fail("JsonValue reference is not an audited extension-point exception", "JsonValue")
        return
    if kind == "parameter":
        name = expression.get("name")
        if name not in parameters:
            fail(f"undeclared generic parameter {name!r}", str(name))
        return
    if kind == "apply":
        name = expression.get("name")
        generic = generics.get(name) if isinstance(name, str) else None
        arguments = expression.get("arguments")
        if not isinstance(generic, dict):
            fail(f"unknown generic {name!r}", str(name))
        if not isinstance(arguments, list) or not arguments:
            fail("generic application needs nonempty arguments")
            return
        declared = generic.get("parameters") if isinstance(generic, dict) else None
        if isinstance(declared, list) and len(arguments) != len(declared):
            fail(f"{name!r} expects {len(declared)} arguments, found {len(arguments)}")
        for index, argument in enumerate(arguments):
            _validate_catalog_type(
                argument,
                context=f"{context}.arguments[{index}]",
                path=path,
                text=text,
                diagnostics=diagnostics,
                type_names=type_names,
                generics=generics,
                scopes=scopes,
                parameters=parameters,
            )
        return
    if kind == "enum":
        values = expression.get("values")
        if (
            not isinstance(values, list)
            or not values
            or len({json.dumps(value, sort_keys=True) for value in values}) != len(values)
        ):
            fail("enum values must be nonempty and unique")
        return
    if kind == "array":
        _validate_catalog_type(
            expression.get("items"),
            context=f"{context}.items",
            path=path,
            text=text,
            diagnostics=diagnostics,
            type_names=type_names,
            generics=generics,
            scopes=scopes,
            parameters=parameters,
        )
        return
    if kind == "map":
        _validate_catalog_type(
            expression.get("values"),
            context=f"{context}.values",
            path=path,
            text=text,
            diagnostics=diagnostics,
            type_names=type_names,
            generics=generics,
            scopes=scopes,
            parameters=parameters,
        )
        return
    if kind == "nullable":
        _validate_catalog_type(
            expression.get("value"),
            context=f"{context}.value",
            path=path,
            text=text,
            diagnostics=diagnostics,
            type_names=type_names,
            generics=generics,
            scopes=scopes,
            parameters=parameters,
        )
        return
    if kind == "union":
        variants = expression.get("variants")
        unknown_variant = expression.get("unknown_variant")
        minimum_variants = 1 if unknown_variant is not None else 2
        if not isinstance(variants, list) or len(variants) < minimum_variants:
            fail(
                "open union needs at least one known variant"
                if unknown_variant is not None
                else "union needs at least two variants"
            )
            return
        if unknown_variant is not None:
            expected_unknown = {
                "sdk_name": "Unknown",
                "when": "unrecognized_discriminator",
                "preserve_discriminator": True,
                "preserve_raw_object": True,
            }
            if unknown_variant != expected_unknown:
                fail("unknown_variant must preserve its discriminator and complete raw object")
            if not isinstance(expression.get("discriminator"), str):
                fail("unknown_variant requires a discriminator")
        for index, variant in enumerate(variants):
            _validate_catalog_type(
                variant,
                context=f"{context}.variants[{index}]",
                path=path,
                text=text,
                diagnostics=diagnostics,
                type_names=type_names,
                generics=generics,
                scopes=scopes,
                parameters=parameters,
            )
        return

    fields = expression.get("fields")
    if not isinstance(fields, dict):
        fail("object fields must be an object")
        return
    if expression.get("extra") is not False:
        fail("object extra must be false; add an explicit extra field when needed")
    for field_name, field in fields.items():
        field_context = f"{context}.fields.{field_name}"
        if (
            field_name in FORBIDDEN_PUBLIC_FIELDS
            or (field_name == "key" and SNAPSHOT_TYPE_RE.search(context.removeprefix("types.")))
        ):
            fail(f"forbidden public identity field {field_name!r}", field_name)
        if not isinstance(field, dict):
            fail(f"{field_context} must be a field descriptor", field_name)
            continue
        unknown_field_keys = set(field) - {
            "required",
            "type",
            "default",
            "sensitive",
            "description",
        }
        if unknown_field_keys:
            fail(f"{field_context} has unknown properties {sorted(unknown_field_keys)!r}", field_name)
        if not isinstance(field.get("required"), bool) or "type" not in field:
            fail(f"{field_context} requires boolean required and a type", field_name)
        if field.get("sensitive") is True and not isinstance(field.get("description"), str):
            fail(f"{field_context} sensitive fields require a redaction description", field_name)
        _validate_catalog_type(
            field.get("type"),
            context=field_context,
            path=path,
            text=text,
            diagnostics=diagnostics,
            type_names=type_names,
            generics=generics,
            scopes=scopes,
            parameters=parameters,
        )


def _operation_catalog(
    path: Path,
    diagnostics: list[Diagnostic],
) -> tuple[dict[str, int], dict[str, str], dict[str, str]]:
    document = _json_object(path, diagnostics)
    if document is None:
        return {}, {}, {}
    text = path.read_text(encoding="utf-8")

    expected_root = {
        "$schema",
        "schema_version",
        "protocol",
        "resource_scopes",
        "types",
        "generics",
        "errors",
        "operations",
        "local_operations",
    }
    if set(document) != expected_root:
        _catalog_diagnostic(
            diagnostics,
            path,
            text,
            f"top-level keys must be exactly {sorted(expected_root)!r}",
        )
    if document.get("$schema") != "./resource-operations-v2.schema.json":
        _catalog_diagnostic(diagnostics, path, text, "catalog must reference its checked-in schema")
    if document.get("schema_version") != 1 or document.get("protocol") != "cmux.protocol/2":
        _catalog_diagnostic(
            diagnostics,
            path,
            text,
            "catalog schema_version must be 1 and protocol must be cmux.protocol/2",
        )

    scope_values = document.get("resource_scopes")
    if (
        not isinstance(scope_values, list)
        or not scope_values
        or not all(isinstance(value, str) for value in scope_values)
        or len(set(scope_values)) != len(scope_values)
    ):
        _catalog_diagnostic(diagnostics, path, text, "resource_scopes must be unique strings")
        scopes: set[str] = set()
    else:
        scopes = set(scope_values)

    types = document.get("types")
    generics = document.get("generics")
    errors = document.get("errors")
    operations = document.get("operations")
    local_operations = document.get("local_operations")
    if not isinstance(types, dict) or not types:
        _catalog_diagnostic(diagnostics, path, text, "types must be a nonempty object")
        types = {}
    if not isinstance(generics, dict) or not generics:
        _catalog_diagnostic(diagnostics, path, text, "generics must be a nonempty object")
        generics = {}
    if not isinstance(errors, dict) or not errors:
        _catalog_diagnostic(diagnostics, path, text, "errors must be a nonempty object")
        errors = {}
    if not isinstance(operations, dict) or not operations:
        _catalog_diagnostic(diagnostics, path, text, "operations must be a nonempty object")
        operations = {}
    if not isinstance(local_operations, dict) or not local_operations:
        _catalog_diagnostic(diagnostics, path, text, "local_operations must be a nonempty object")
        local_operations = {}

    type_names = set(types)
    for name, expression in types.items():
        _validate_catalog_type(
            expression,
            context=f"types.{name}",
            path=path,
            text=text,
            diagnostics=diagnostics,
            type_names=type_names,
            generics=generics,
            scopes=scopes,
        )
    expected_unknown_variant = {
        "sdk_name": "Unknown",
        "when": "unrecognized_discriminator",
        "preserve_discriminator": True,
        "preserve_raw_object": True,
    }
    open_union_types = (
        "SessionEventItem",
        "TerminalAttachItem",
        "BrowserAttachItem",
        "SidebarAttachItem",
        "ResourceChange",
    )
    for name in open_union_types:
        expression = types.get(name)
        if expression is None:
            continue
        variants = expression.get("variants") if isinstance(expression, dict) else None
        constraints = expression.get("constraints") if isinstance(expression, dict) else None
        if (
            not isinstance(expression, dict)
            or expression.get("kind") != "union"
            or expression.get("discriminator") != "kind"
            or expression.get("unknown_variant") != expected_unknown_variant
            or not isinstance(constraints, list)
            or not any("malformed" in value and "never Unknown" in value for value in constraints)
        ):
            _catalog_diagnostic(
                diagnostics,
                path,
                text,
                f"{name} must preserve unknown discriminators without accepting malformed known variants",
                name,
            )
            continue
        known_discriminators: set[object] = set()
        for variant in variants if isinstance(variants, list) else []:
            referenced = (
                types.get(variant.get("name"))
                if isinstance(variant, dict) and variant.get("kind") == "ref"
                else None
            )
            discriminator_field = (
                referenced.get("fields", {}).get("kind")
                if isinstance(referenced, dict)
                else None
            )
            values = (
                discriminator_field.get("type", {}).get("values")
                if isinstance(discriminator_field, dict)
                else None
            )
            if (
                not isinstance(referenced, dict)
                or referenced.get("kind") != "object"
                or not isinstance(discriminator_field, dict)
                or discriminator_field.get("required") is not True
                or not isinstance(values, list)
                or len(values) != 1
                or values[0] in known_discriminators
            ):
                _catalog_diagnostic(
                    diagnostics,
                    path,
                    text,
                    f"{name} known variants need unique required literal kind fields",
                    name,
                )
                break
            known_discriminators.add(values[0])
    for name, generic in generics.items():
        if not isinstance(generic, dict) or set(generic) != {"parameters", "body"}:
            _catalog_diagnostic(
                diagnostics, path, text, f"generics.{name} needs parameters and body", name
            )
            continue
        parameters = generic.get("parameters")
        if (
            not isinstance(parameters, list)
            or not parameters
            or not all(isinstance(value, str) for value in parameters)
            or len(set(parameters)) != len(parameters)
        ):
            _catalog_diagnostic(
                diagnostics, path, text, f"generics.{name}.parameters must be unique strings", name
            )
            parameters = []
        _validate_catalog_type(
            generic.get("body"),
            context=f"generics.{name}.body",
            path=path,
            text=text,
            diagnostics=diagnostics,
            type_names=type_names,
            generics=generics,
            scopes=scopes,
            parameters=set(parameters),
        )
    for code, descriptor in errors.items():
        if not OPERATION_RE.fullmatch(code):
            _catalog_diagnostic(diagnostics, path, text, f"invalid error code {code!r}", code)
        if not isinstance(descriptor, dict) or set(descriptor) != {"retryable", "details"}:
            _catalog_diagnostic(
                diagnostics, path, text, f"errors.{code} needs retryable and details", code
            )
            continue
        if not isinstance(descriptor.get("retryable"), bool):
            _catalog_diagnostic(
                diagnostics, path, text, f"errors.{code}.retryable must be boolean", code
            )
        _validate_catalog_type(
            descriptor.get("details"),
            context=f"errors.{code}.details",
            path=path,
            text=text,
            diagnostics=diagnostics,
            type_names=type_names,
            generics=generics,
            scopes=scopes,
        )

    def validate_params(operation: str, descriptor: Mapping[str, object]) -> None:
        value = descriptor.get("params")
        if not isinstance(value, dict):
            _catalog_diagnostic(
                diagnostics, path, text, f"{operation}.params must be an object", operation
            )
            return
        allowed = {"selectors", "fields", "extra", "constraints", "one_of"}
        if set(value) - allowed or not {"selectors", "fields", "extra"} <= set(value):
            _catalog_diagnostic(
                diagnostics, path, text, f"{operation}.params has a schema hole", operation
            )
        if value.get("extra") is not False:
            _catalog_diagnostic(
                diagnostics, path, text, f"{operation}.params.extra must be false", operation
            )
        selector_map = value.get("selectors")
        if not isinstance(selector_map, dict):
            _catalog_diagnostic(
                diagnostics, path, text, f"{operation}.params.selectors must be an object", operation
            )
            selector_map = {}
        for scope, presence in selector_map.items():
            if scope not in scopes or presence not in {"required", "optional"}:
                _catalog_diagnostic(
                    diagnostics,
                    path,
                    text,
                    f"{operation} has invalid selector {scope!r}: {presence!r}",
                    operation,
                )
        for ancestor in descriptor.get("ancestors", []):
            expected_presence = "optional" if ancestor in STRUCTURAL_SCOPES else "required"
            if selector_map.get(ancestor) != expected_presence:
                _catalog_diagnostic(
                    diagnostics,
                    path,
                    text,
                    f"{operation} ancestor selector {ancestor!r} must be {expected_presence}",
                    operation,
                )
        target = descriptor.get("target")
        if target in selector_map and selector_map.get(target) != "required":
            _catalog_diagnostic(
                diagnostics,
                path,
                text,
                f"{operation} target selector {target!r} must be required",
                operation,
            )
        fields = value.get("fields")
        synthetic = {"kind": "object", "fields": fields, "extra": False}
        _validate_catalog_type(
            synthetic,
            context=f"operations.{operation}.params",
            path=path,
            text=text,
            diagnostics=diagnostics,
            type_names=type_names,
            generics=generics,
            scopes=scopes,
        )
        one_of = value.get("one_of")
        if one_of is not None:
            if not isinstance(one_of, list) or len(one_of) < 2:
                _catalog_diagnostic(
                    diagnostics, path, text, f"{operation}.params.one_of needs variants", operation
                )
            else:
                field_names = set(fields) if isinstance(fields, dict) else set()
                for variant in one_of:
                    if not isinstance(variant, dict) or set(variant) != {"required", "forbidden"}:
                        _catalog_diagnostic(
                            diagnostics,
                            path,
                            text,
                            f"{operation}.params.one_of variants need required/forbidden",
                            operation,
                        )
                        continue
                    names = set(variant.get("required", [])) | set(variant.get("forbidden", []))
                    if not names <= field_names:
                        _catalog_diagnostic(
                            diagnostics,
                            path,
                            text,
                            f"{operation}.params.one_of references unknown fields {sorted(names - field_names)!r}",
                            operation,
                        )

    operation_offsets: dict[str, int] = {}
    classes: dict[str, str] = {}
    if list(operations) != sorted(operations):
        _catalog_diagnostic(diagnostics, path, text, "operations must be lexicographically sorted")
    for operation, descriptor in operations.items():
        offset = text.find(json.dumps(operation))
        operation_offsets[operation] = max(offset, 0) + 1
        if not OPERATION_RE.fullmatch(operation):
            _catalog_diagnostic(diagnostics, path, text, f"invalid operation {operation!r}", operation)
        if not isinstance(descriptor, dict):
            _catalog_diagnostic(diagnostics, path, text, f"{operation} descriptor must be an object")
            continue
        required = {"class", "idempotency", "target", "ancestors", "params", "result", "errors"}
        allowed = required | {"stream", "constraints"}
        if not required <= set(descriptor) or set(descriptor) - allowed:
            _catalog_diagnostic(
                diagnostics, path, text, f"{operation} descriptor has a schema hole", operation
            )
        operation_class = descriptor.get("class")
        classes[operation] = str(operation_class)
        if operation_class not in TRANSPORT_OPERATION_CLASSES:
            _catalog_diagnostic(
                diagnostics, path, text, f"{operation} has invalid class {operation_class!r}", operation
            )
        expected_idempotency = "required" if operation_class == "mutation" else "forbidden"
        if descriptor.get("idempotency") != expected_idempotency:
            _catalog_diagnostic(
                diagnostics,
                path,
                text,
                f"{operation} {operation_class} idempotency must be {expected_idempotency}",
                operation,
            )
        target = descriptor.get("target")
        ancestors = descriptor.get("ancestors")
        if target not in scopes:
            _catalog_diagnostic(diagnostics, path, text, f"{operation} has invalid target {target!r}")
        if (
            not isinstance(ancestors, list)
            or len(set(ancestors)) != len(ancestors)
            or any(ancestor not in scopes for ancestor in ancestors)
        ):
            _catalog_diagnostic(
                diagnostics, path, text, f"{operation} has invalid ancestor scopes", operation
            )
        validate_params(operation, descriptor)
        _validate_catalog_type(
            descriptor.get("result"),
            context=f"operations.{operation}.result",
            path=path,
            text=text,
            diagnostics=diagnostics,
            type_names=type_names,
            generics=generics,
            scopes=scopes,
        )
        result = descriptor.get("result")
        is_mutation_result = (
            isinstance(result, dict)
            and result.get("kind") == "apply"
            and result.get("name") == "MutationResult"
        )
        if (operation_class == "mutation") != is_mutation_result:
            _catalog_diagnostic(
                diagnostics,
                path,
                text,
                f"{operation} mutation result wrapping does not match its class",
                operation,
            )
        stream = descriptor.get("stream")
        if operation_class == "stream_open":
            if not isinstance(stream, dict) or not {"item", "end"} <= set(stream):
                _catalog_diagnostic(
                    diagnostics, path, text, f"{operation} stream schema is incomplete", operation
                )
            else:
                for member in ("item", "end"):
                    _validate_catalog_type(
                        stream.get(member),
                        context=f"operations.{operation}.stream.{member}",
                        path=path,
                        text=text,
                        diagnostics=diagnostics,
                        type_names=type_names,
                        generics=generics,
                        scopes=scopes,
                    )
                fields = descriptor.get("params", {}).get("fields", {})
                stream_field = fields.get("stream_id") if isinstance(fields, dict) else None
                if (
                    not isinstance(stream_field, dict)
                    or stream_field.get("required") is not True
                    or stream_field.get("type") != {"kind": "resource_id", "resource": "stream"}
                ):
                    _catalog_diagnostic(
                        diagnostics,
                        path,
                        text,
                        f"{operation} must require a typed stream_id",
                        operation,
                    )
        elif stream is not None:
            _catalog_diagnostic(
                diagnostics, path, text, f"{operation} non-stream operation has stream schema", operation
            )
        error_codes = descriptor.get("errors")
        if (
            not isinstance(error_codes, list)
            or not error_codes
            or len(set(error_codes)) != len(error_codes)
            or any(code not in errors for code in error_codes)
        ):
            _catalog_diagnostic(
                diagnostics, path, text, f"{operation} has invalid structured errors", operation
            )
        selector_map = descriptor.get("params", {}).get("selectors", {})
        if (
            isinstance(selector_map, dict)
            and any(
                scope in STRUCTURAL_SCOPES and presence == "optional"
                for scope, presence in selector_map.items()
            )
            and isinstance(error_codes, list)
            and "selector.wrong_parent" not in error_codes
        ):
            _catalog_diagnostic(
                diagnostics,
                path,
                text,
                f"{operation} optional structural scopes require selector.wrong_parent",
                operation,
            )

    expected_correlation_key = {
        "required": False,
        "type": {
            "kind": "primitive",
            "name": "string",
            "min_length": 1,
            "max_length": 128,
        },
        "description": (
            "Stable caller correlation across creation attempts. "
            "Defaults to the request idempotency key."
        ),
    }
    correlated_operations = {
        operation
        for operation, descriptor in operations.items()
        if isinstance(descriptor, dict)
        and descriptor.get("params", {})
        .get("fields", {})
        .get("correlation_key", {})
        .get("required")
        is False
    }
    expected_correlated_operations = CORRELATED_CREATION_OPERATIONS & set(operations)
    if correlated_operations != expected_correlated_operations:
        _catalog_diagnostic(
            diagnostics,
            path,
            text,
            "correlation_key must appear on every cataloged CreatedPath operation and no others",
        )
    for operation in expected_correlated_operations:
        descriptor = operations.get(operation)
        fields = (
            descriptor.get("params", {}).get("fields", {})
            if isinstance(descriptor, dict)
            else {}
        )
        error_codes = descriptor.get("errors", []) if isinstance(descriptor, dict) else []
        if (
            fields.get("correlation_key") != expected_correlation_key
            or "creation.conflict" not in error_codes
        ):
            _catalog_diagnostic(
                diagnostics,
                path,
                text,
                f"{operation} must expose exact creation correlation and conflict semantics",
                operation,
            )

    terminal_snapshot = types.get("TerminalSnapshot")
    if isinstance(terminal_snapshot, dict):
        fields = terminal_snapshot.get("fields", {})
        constraints = terminal_snapshot.get("constraints", [])
        if (
            types.get("TerminalLifecycle")
            != {
                "kind": "enum",
                "values": ["launching", "running", "exited"],
            }
            or fields.get("running")
            != {
                "required": True,
                "type": {"kind": "primitive", "name": "boolean"},
            }
            or fields.get("lifecycle")
            != {
                "required": True,
                "type": {"kind": "ref", "name": "TerminalLifecycle"},
            }
            or fields.get("exit")
            != {
                "required": False,
                "type": {"kind": "ref", "name": "TerminalExit"},
            }
            or "running is true exactly when lifecycle is running." not in constraints
            or "exit is present exactly when lifecycle is exited." not in constraints
        ):
            _catalog_diagnostic(
                diagnostics,
                path,
                text,
                "TerminalSnapshot must expose strict lifecycle and durable exit invariants",
                "TerminalSnapshot",
            )

    local_classes: dict[str, str] = {}
    if list(local_operations) != sorted(local_operations):
        _catalog_diagnostic(
            diagnostics, path, text, "local_operations must be lexicographically sorted"
        )
    for operation, descriptor in local_operations.items():
        local_classes[operation] = "local"
        if (
            not isinstance(descriptor, dict)
            or descriptor.get("class") != "local"
            or descriptor.get("idempotency") != "forbidden"
            or descriptor.get("target") != "sidebar_plugin"
            or descriptor.get("ancestors") != []
            or "stream" in descriptor
        ):
            _catalog_diagnostic(
                diagnostics, path, text, f"{operation} is not a valid LocalOperation", operation
            )
            continue
        validate_params(operation, descriptor)
        _validate_catalog_type(
            descriptor.get("result"),
            context=f"local_operations.{operation}.result",
            path=path,
            text=text,
            diagnostics=diagnostics,
            type_names=type_names,
            generics=generics,
            scopes=scopes,
        )

    mutation_result = generics.get("MutationResult")
    if mutation_result is not None:
        expected_mutation_result = {
            "parameters": ["T"],
            "body": {
                "kind": "object",
                "fields": {
                    "value": {
                        "required": True,
                        "type": {"kind": "parameter", "name": "T"},
                    },
                    "generation": {
                        "required": True,
                        "type": {
                            "kind": "primitive",
                            "name": "string",
                            "min_length": 1,
                            "max_length": 128,
                        },
                    },
                    "revision": {
                        "required": True,
                        "type": {"kind": "primitive", "name": "decimal"},
                    },
                    "replayed": {
                        "required": True,
                        "type": {"kind": "primitive", "name": "boolean"},
                    },
                },
                "extra": False,
            },
        }
        if mutation_result != expected_mutation_result or "MutationReceipt" in types:
            _catalog_diagnostic(
                diagnostics,
                path,
                text,
                "MutationResult must be flat value/generation/revision/replayed without a receipt",
                "MutationResult",
            )

    command_spec = types.get("CommandSpec")
    if isinstance(command_spec, dict):
        variants = command_spec.get("variants", [])
        argv_type = (
            variants[0].get("fields", {}).get("argv", {}).get("type")
            if isinstance(variants, list) and variants and isinstance(variants[0], dict)
            else None
        )
        command_constraints = command_spec.get("constraints", [])
        if (
            argv_type
            != {
                "kind": "array",
                "items": {"kind": "primitive", "name": "string"},
                "min_items": 1,
            }
            or not any(
                "argv[0] is non-empty" in value and "including empty" in value
                for value in command_constraints
            )
        ):
            _catalog_diagnostic(
                diagnostics,
                path,
                text,
                "CommandSpec must allow empty later argv values while requiring nonempty argv[0]",
                "CommandSpec",
            )

    plugin_install = local_operations.get("sidebar_plugin.install")
    if isinstance(plugin_install, dict):
        plugin_name = plugin_install.get("params", {}).get("fields", {}).get("name")
        if (
            not isinstance(plugin_name, dict)
            or plugin_name.get("type")
            != {"kind": "primitive", "name": "string", "min_length": 1}
            or "[a-z0-9-_]+" not in plugin_name.get("description", "")
        ):
            _catalog_diagnostic(
                diagnostics,
                path,
                text,
                "sidebar plugin install name must be a nonempty [a-z0-9-_]+ filesystem slug",
                "sidebar_plugin.install",
            )

    for operation in ("workspace.run", "pane.run"):
        if operation not in operations:
            continue
        descriptor = operations.get(operation)
        params_value = descriptor.get("params") if isinstance(descriptor, dict) else None
        fields = params_value.get("fields") if isinstance(params_value, dict) else None
        one_of = params_value.get("one_of") if isinstance(params_value, dict) else None
        expected_one_of = [
            {"required": ["argv"], "forbidden": ["shell"]},
            {"required": ["shell"], "forbidden": ["argv"]},
        ]
        if not isinstance(fields, dict) or one_of != expected_one_of:
            _catalog_diagnostic(
                diagnostics,
                path,
                text,
                f"{operation} must model exact argv/shell one-of",
                operation,
            )
        else:
            argv = fields.get("argv", {}).get("type")
            shell = fields.get("shell", {}).get("type")
            if (
                not isinstance(argv, dict)
                or argv.get("kind") != "array"
                or argv.get("min_items") != 1
                or argv.get("items") != {"kind": "primitive", "name": "string"}
                or shell != {"kind": "primitive", "name": "string", "min_length": 1}
                or not any(
                    "argv[0] is non-empty" in value and "including empty" in value
                    for value in params_value.get("constraints", [])
                )
            ):
                _catalog_diagnostic(
                    diagnostics,
                    path,
                    text,
                    f"{operation} argv/shell types are not exact",
                    operation,
                )

    workspace_create = operations.get("workspace.create")
    if isinstance(workspace_create, dict):
        create_fields = workspace_create.get("params", {}).get("fields")
        expected_initial_content = {
            "kind": "enum",
            "values": ["terminal", "empty"],
        }
        expected_correlation_key = {
            "kind": "primitive",
            "name": "string",
            "min_length": 1,
            "max_length": 128,
        }
        expected_revision = {
            "kind": "primitive",
            "name": "decimal",
        }
        if (
            not isinstance(create_fields, dict)
            or set(create_fields)
            != {"name", "initial_content", "correlation_key", "expected_revision"}
            or create_fields.get("name", {}).get("required") is not False
            or create_fields.get("name", {}).get("type")
            != {"kind": "primitive", "name": "string"}
            or create_fields.get("initial_content", {}).get("required") is not True
            or create_fields.get("initial_content", {}).get("type") != expected_initial_content
            or create_fields.get("correlation_key", {}).get("required") is not False
            or create_fields.get("correlation_key", {}).get("type")
            != expected_correlation_key
            or create_fields.get("expected_revision", {}).get("required") is not False
            or create_fields.get("expected_revision", {}).get("type") != expected_revision
        ):
            _catalog_diagnostic(
                diagnostics,
                path,
                text,
                "workspace.create params must be optional name, correlation_key, and expected_revision plus required initial_content",
                "workspace.create",
            )

    required_sensitive_paths = (
        ("types", "RendererGrantResult", "fields", "token"),
        ("types", "PairingRequestSnapshot", "fields", "code"),
    )
    for parts in required_sensitive_paths:
        owner = document.get(parts[0])
        if not isinstance(owner, dict) or parts[1] not in owner:
            continue
        value: object = document
        for part in parts:
            value = value.get(part) if isinstance(value, dict) else None
        if not isinstance(value, dict) or value.get("sensitive") is not True:
            _catalog_diagnostic(
                diagnostics,
                path,
                text,
                f"{'.'.join(parts)} must be sensitive",
                parts[-1],
            )

    client_metadata = operations.get("client.metadata.update", {})
    client_fields = client_metadata.get("params", {}).get("fields", {})
    client_name = client_fields.get("name")
    client_kind = client_fields.get("kind")
    expected_three_state = {
        "kind": "nullable",
        "value": {"kind": "primitive", "name": "string"},
    }
    expected_client_description = (
        "Omitted means no change, null clears, and a non-null string preserves its "
        "exact value, including empty, whitespace, and Unicode. A non-null value "
        "contains at most 64 Unicode scalars and no Unicode General_Category=Cc "
        "control scalar."
    )
    expected_client_constraints = [
        "At least one of name or kind is present.",
        "Each present non-null name or kind contains at most 64 Unicode scalars "
        "and no Unicode General_Category=Cc control scalar.",
        "A constraint violation returns validation.invalid before either field mutates.",
    ]
    if "client.metadata.update" in operations and (
        not isinstance(client_name, dict)
        or client_name.get("required") is not False
        or client_name.get("type") != expected_three_state
        or client_name.get("description") != expected_client_description
        or not isinstance(client_kind, dict)
        or client_kind.get("required") is not False
        or client_kind.get("type") != expected_three_state
        or client_kind.get("description") != expected_client_description
        or client_metadata.get("params", {}).get("constraints")
        != expected_client_constraints
        or "validation.invalid" not in client_metadata.get("errors", [])
    ):
        _catalog_diagnostic(
            diagnostics,
            path,
            text,
            "client.metadata.update name and kind must encode exact three-state values, "
            "64-scalar/Cc validation, and pre-mutation validation.invalid semantics",
            "client.metadata.update",
        )
    expected_shutdown_constraints = [
        "Requires a trusted local Unix-socket connection and is unavailable over WebSocket.",
        "With force=false, another connected native-browser owner rejects shutdown; "
        "force=true bypasses only that ownership check.",
        "On success, the durable receipt is committed and its response is queued before "
        "process exit is requested.",
        "A failed response queue cancels the shutdown handoff without requesting exit; "
        "same-key replay may reserve a new handoff and retry the post-response exit request.",
    ]
    if "session.shutdown" in operations and (
        operations.get("session.shutdown", {}).get("constraints")
        != expected_shutdown_constraints
    ):
        _catalog_diagnostic(
            diagnostics,
            path,
            text,
            "session.shutdown must encode trusted-local authority, owner-force scope, "
            "and durable-receipt-before-exit ordering",
            "session.shutdown",
        )
    for operation in ("workspace.rename",):
        if operation not in operations:
            continue
        name_field = (
            operations.get(operation, {}).get("params", {}).get("fields", {}).get("name")
        )
        if (
            not isinstance(name_field, dict)
            or name_field.get("required") is not True
            or name_field.get("type") != {"kind": "primitive", "name": "string"}
        ):
            _catalog_diagnostic(
                diagnostics,
                path,
                text,
                f"{operation} name must be a required unrestricted string",
                operation,
            )
    nullable_name = {
        "kind": "nullable",
        "value": {"kind": "primitive", "name": "string"},
    }
    for operation in ("screen.rename", "pane.rename", "tab.rename"):
        if operation not in operations:
            continue
        name_field = (
            operations.get(operation, {}).get("params", {}).get("fields", {}).get("name")
        )
        if (
            not isinstance(name_field, dict)
            or name_field.get("required") is not True
            or name_field.get("type") != nullable_name
            or "null clears" not in name_field.get("description", "")
        ):
            _catalog_diagnostic(
                diagnostics,
                path,
                text,
                f"{operation} name must distinguish null clear from exact strings",
                operation,
            )
    for type_name in ("ScreenSnapshot", "PaneSnapshot", "TabSnapshot", "ClientSnapshot"):
        if type_name not in types:
            continue
        name_field = types.get(type_name, {}).get("fields", {}).get("name")
        if (
            not isinstance(name_field, dict)
            or name_field.get("required") is not True
            or name_field.get("type") != nullable_name
        ):
            _catalog_diagnostic(
                diagnostics,
                path,
                text,
                f"{type_name}.name must be a required nullable string field",
                type_name,
            )
    expected_agent_state = {
        "kind": "enum",
        "values": ["working", "blocked", "idle", "done", "unknown"],
    }
    if "agent.list" in operations and types.get("AgentState") != expected_agent_state:
        _catalog_diagnostic(
            diagnostics,
            path,
            text,
            "AgentState must match the runtime working|blocked|idle|done|unknown set",
            "AgentState",
        )
    agent_state_ref = {"kind": "ref", "name": "AgentState"}
    agent_state_uses = (
        types.get("AgentSnapshot", {}).get("fields", {}).get("state", {}).get("type"),
        operations.get("agent.list", {})
        .get("params", {})
        .get("fields", {})
        .get("state", {})
        .get("type"),
        operations.get("agent.report", {})
        .get("params", {})
        .get("fields", {})
        .get("state", {})
        .get("type"),
    )
    if "agent.list" in operations and any(value != agent_state_ref for value in agent_state_uses):
        _catalog_diagnostic(
            diagnostics,
            path,
            text,
            "agent snapshot, report, and list filter must reference AgentState",
            "AgentState",
        )

    expected_notification_level = {
        "kind": "enum",
        "values": ["info", "warning", "error"],
    }
    notification_level_ref = {"kind": "ref", "name": "NotificationLevel"}
    if (
        "notification.create" in operations
        and types.get("NotificationLevel") != expected_notification_level
    ):
        _catalog_diagnostic(
            diagnostics,
            path,
            text,
            "NotificationLevel must match the runtime info|warning|error set",
            "NotificationLevel",
        )
    notification_uses = (
        types.get("NotificationSnapshot", {}).get("fields", {}).get("level", {}).get("type"),
        operations.get("notification.create", {})
        .get("params", {})
        .get("fields", {})
        .get("level", {})
        .get("type"),
    )
    if "notification.create" in operations and any(
        value != notification_level_ref for value in notification_uses
    ):
        _catalog_diagnostic(
            diagnostics,
            path,
            text,
            "notification snapshot and create must reference NotificationLevel",
            "NotificationLevel",
        )

    browser_snapshot = types.get("BrowserSnapshot")
    if isinstance(browser_snapshot, dict):
        browser_fields = browser_snapshot.get("fields", {})
        expected_browser_fields = {
            "id",
            "tab_id",
            "url",
            "title",
            "loading",
            "source",
            "status",
            "error",
            "frames_stalled",
            "size",
            "extra",
        }
        browser_constraints = browser_snapshot.get("constraints", [])
        if (
            set(browser_fields) != expected_browser_fields
            or types.get("BrowserSource")
            != {"kind": "enum", "values": ["external", "launched"]}
            or types.get("BrowserStatus")
            != {"kind": "enum", "values": ["starting", "live", "failed"]}
            or browser_fields.get("source", {}).get("type")
            != {"kind": "ref", "name": "BrowserSource"}
            or browser_fields.get("status", {}).get("type")
            != {"kind": "ref", "name": "BrowserStatus"}
            or browser_fields.get("error", {}).get("type")
            != {
                "kind": "nullable",
                "value": {"kind": "primitive", "name": "string"},
            }
            or browser_fields.get("frames_stalled", {}).get("type")
            != {"kind": "primitive", "name": "boolean"}
            or browser_fields.get("size", {}).get("type")
            != {"kind": "ref", "name": "Size"}
            or not any("target IDs" in value and "transport secrets" in value for value in browser_constraints)
        ):
            _catalog_diagnostic(
                diagnostics,
                path,
                text,
                "BrowserSnapshot must expose only safe cached browser state and no CDP identity or secrets",
                "BrowserSnapshot",
            )

    nullable_string = {
        "kind": "nullable",
        "value": {"kind": "primitive", "name": "string"},
    }
    client_snapshot = types.get("ClientSnapshot")
    if isinstance(client_snapshot, dict):
        client_fields = client_snapshot.get("fields", {})
        size_fields = types.get("ClientTerminalSize", {}).get("fields", {})
        if (
            client_fields.get("client_kind", {}).get("required") is not True
            or client_fields.get("client_kind", {}).get("type") != nullable_string
            or client_fields.get("transport", {}).get("type")
            != {"kind": "ref", "name": "ClientTransport"}
            or types.get("ClientTransport")
            != {"kind": "enum", "values": ["unix", "websocket"]}
            or client_fields.get("connected_seconds", {}).get("type")
            != {"kind": "primitive", "name": "decimal"}
            or client_fields.get("attached_terminal_ids", {}).get("type", {}).get("items")
            != {"kind": "resource_id", "resource": "terminal"}
            or client_fields.get("sizes", {}).get("type", {}).get("items")
            != {"kind": "ref", "name": "ClientTerminalSize"}
            or client_fields.get("self", {}).get("type")
            != {"kind": "primitive", "name": "boolean"}
            or "sizing_terminal_id" in client_fields
            or set(size_fields) != {"terminal_id", "cols", "rows", "participating"}
        ):
            _catalog_diagnostic(
                diagnostics,
                path,
                text,
                "ClientSnapshot must preserve per-terminal attachment, size, participation, transport, and self metadata",
                "ClientSnapshot",
            )

    if "AgentSnapshot" in types:
        agent_fields = types.get("AgentSnapshot", {}).get("fields", {})
        source_values = agent_fields.get("source", {}).get("type", {}).get("values")
        report_source_values = (
            operations.get("agent.report", {})
            .get("params", {})
            .get("fields", {})
            .get("source", {})
            .get("type", {})
            .get("values")
        )
        if (
            agent_fields.get("updated_at_ms", {}).get("type")
            != {"kind": "primitive", "name": "decimal"}
            or agent_fields.get("source_session", {}).get("type") != nullable_string
            or source_values != ["hook", "socket", "detected"]
            or report_source_values != ["hook", "socket"]
            or "reported_at" in agent_fields
        ):
            _catalog_diagnostic(
                diagnostics,
                path,
                text,
                "AgentSnapshot must use exact decimal time, nullable source session, and detected-only snapshot source",
                "AgentSnapshot",
            )

    if "NotificationSnapshot" in types:
        notification_fields = types.get("NotificationSnapshot", {}).get("fields", {})
        if (
            notification_fields.get("created_at_ms", {}).get("type")
            != {"kind": "primitive", "name": "decimal"}
            or notification_fields.get("unread", {}).get("type")
            != {"kind": "primitive", "name": "boolean"}
            or "created_at" in notification_fields
        ):
            _catalog_diagnostic(
                diagnostics,
                path,
                text,
                "NotificationSnapshot must expose decimal created_at_ms and unread state",
                "NotificationSnapshot",
            )

    if "PairingRequestSnapshot" in types:
        pairing_fields = types.get("PairingRequestSnapshot", {}).get("fields", {})
        pairing_code = pairing_fields.get("code")
        if (
            not {"peer", "code", "expires_in_seconds"} <= set(pairing_fields)
            or {"created_at", "client_name"} & set(pairing_fields)
            or pairing_fields.get("expires_in_seconds", {}).get("type")
            != {"kind": "primitive", "name": "decimal"}
            or not isinstance(pairing_code, dict)
            or pairing_code.get("sensitive") is not True
        ):
            _catalog_diagnostic(
                diagnostics,
                path,
                text,
                "PairingRequestSnapshot must model peer/code/expiry and redact the authorization code",
                "PairingRequestSnapshot",
            )

    if "RenderSnapshot" in types:
        render_snapshot_fields = types.get("RenderSnapshot", {}).get("fields", {})
        render_patch_fields = types.get("RenderPatch", {}).get("fields", {})
        render_run_fields = types.get("RenderRun", {}).get("fields", {})
        render_cursor_fields = types.get("RenderCursor", {}).get("fields", {})
        terminal_variants = [
            value.get("name")
            for value in types.get("TerminalAttachItem", {}).get("variants", [])
            if isinstance(value, dict)
        ]
        sidebar_variants = [
            value.get("name")
            for value in types.get("SidebarAttachItem", {}).get("variants", [])
            if isinstance(value, dict)
        ]
        history_rows = (
            types.get("TerminalHistoryResult", {})
            .get("fields", {})
            .get("rows", {})
            .get("type", {})
            .get("items")
        )
        if (
            set(render_snapshot_fields)
            != {"size", "cursor", "default_fg", "default_bg", "scrollback_rows", "rows"}
            or set(render_patch_fields)
            != {
                "cursor",
                "full_reset",
                "size",
                "default_fg",
                "default_bg",
                "scrollback_rows",
                "rows",
            }
            or set(render_run_fields)
            != {"text", "fg", "bg", "attrs", "underline", "width_hint"}
            or render_run_fields.get("attrs", {}).get("type")
            != {"kind": "primitive", "name": "uint32"}
            or set(render_cursor_fields)
            != {"x", "y", "style", "blink", "visible", "color"}
            or terminal_variants
            != ["TerminalAttachSnapshot", "TerminalAttachPatch", "TerminalAttachScroll"]
            or sidebar_variants
            != ["SidebarAttachSnapshot", "SidebarAttachPatch", "SidebarAttachScroll"]
            or history_rows != {"kind": "ref", "name": "RenderRow"}
            or {
                "TerminalAttachOutput",
                "TerminalAttachResize",
                "TerminalAttachDefaults",
                "StyledSegment",
                "StyledLine",
            }
            & set(types)
        ):
            _catalog_diagnostic(
                diagnostics,
                path,
                text,
                "terminal, sidebar, and history rendering must share the lossless protocol-v7 render model",
                "RenderSnapshot",
            )

    if "LayoutDocument" in types:
        layout_variants = [
            value.get("name")
            for value in types.get("LayoutNode", {}).get("variants", [])
            if isinstance(value, dict)
        ]
        layout_fields = types.get("LayoutDocument", {}).get("fields", {})
        screen_layout = (
            types.get("ScreenSnapshot", {}).get("fields", {}).get("layout", {}).get("type")
        )
        screen_create_result = operations.get("screen.create", {}).get("result")
        if (
            layout_variants
            != ["LayoutLeaf", "LayoutSplit", "LayoutStack", "LayoutViewport"]
            or not {"active_pane_id", "zoomed_pane_id", "root"} <= set(layout_fields)
            or layout_fields.get("zoomed_pane_id", {}).get("type")
            != {
                "kind": "nullable",
                "value": {"kind": "resource_id", "resource": "pane"},
            }
            or set(types.get("LayoutColumn", {}).get("fields", {}))
            != {"column_id", "width", "root"}
            or screen_layout != {"kind": "ref", "name": "LayoutDocument"}
            or (
                "screen.create" in operations
                and screen_create_result
                != {
                    "kind": "apply",
                    "name": "MutationResult",
                    "arguments": [{"kind": "ref", "name": "CreatedTerminalPath"}],
                }
            )
        ):
            _catalog_diagnostic(
                diagnostics,
                path,
                text,
                "layout documents must round-trip splits, stacks, viewport columns, focus, and zoom",
                "LayoutDocument",
            )

    if "MachineSnapshot" in types:
        machine_fields = types.get("MachineSnapshot", {}).get("fields", {})
        expected_machine_fields = {
            "id",
            "name",
            "origin",
            "status",
            "connectable",
            "deleted",
            "recoverable",
            "extra",
        }
        if (
            set(machine_fields) != expected_machine_fields
            or machine_fields.get("name", {}).get("required") is not True
            or machine_fields.get("origin", {}).get("type", {}).get("values")
            != ["local"]
            or machine_fields.get("status", {}).get("type", {}).get("values")
            != ["running", "connecting", "sleeping", "stopped", "unavailable"]
        ):
            _catalog_diagnostic(
                diagnostics,
                path,
                text,
                "MachineSnapshot must describe only the endpoint's local machine",
                "MachineSnapshot",
            )

    if "SidebarViewSnapshot" in types:
        sidebar_fields = types.get("SidebarViewSnapshot", {}).get("fields", {})
        ensure_fields = (
            operations.get("sidebar_view.ensure", {}).get("params", {}).get("fields", {})
        )
        if "plugin_id" in sidebar_fields or "plugin_id" in ensure_fields:
            _catalog_diagnostic(
                diagnostics,
                path,
                text,
                "transported sidebar view types must not expose local sidebar plugin identities",
                "SidebarViewSnapshot",
            )

    if (
        "RendererGrantResult" in types
        and "terminal.renderer_grant.create" in operations
    ):
        grant_fields = types.get("RendererGrantResult", {}).get("fields", {})
        if (
            set(grant_fields) != {"endpoint", "terminal_id", "token", "rights", "ttl_ms"}
            or "incarnation" in grant_fields
        ):
            _catalog_diagnostic(
                diagnostics,
                path,
                text,
                "renderer grants must bind lifecycle internally without exposing incarnation",
                "RendererGrantResult",
            )

    if "StreamEnd" in types:
        stream_end_fields = types.get("StreamEnd", {}).get("fields", {})
        stream_error_fields = types.get("StreamError", {}).get("fields", {})
        resource_source = path.parent.parent / "crates/cmux-tui-core/src/resource.rs"
        resource_text = (
            resource_source.read_text(encoding="utf-8") if resource_source.exists() else ""
        )
        if (
            stream_end_fields.get("error", {}).get("type")
            != {"kind": "ref", "name": "StreamError"}
            or "error_code" in stream_end_fields
            or set(stream_error_fields) != {"code", "message", "details", "retryable"}
            or (
                resource_text
                and not re.search(
                    r"struct StreamEndEnvelope\s*\{(?:(?!\n\}).)*"
                    r"error:\s*Option<ResourceError>",
                    resource_text,
                    re.DOTALL,
                )
            )
        ):
            _catalog_diagnostic(
                diagnostics,
                path,
                text,
                "StreamEnd must match core's optional full structured ResourceError",
                "StreamEnd",
            )

    if "ResourceChange" in types:
        session_changes = (
            types.get("SessionDelta", {})
            .get("fields", {})
            .get("changes", {})
            .get("type", {})
            .get("items")
        )
        screen_value = (
            types.get("ScreenSnapshot", {}).get("fields", {}).get("layout", {}).get("type")
        )
        if (
            "ResourceDelta" in types
            or session_changes != {"kind": "ref", "name": "ResourceChange"}
            or types.get("ResourceUpsert", {}).get("fields", {}).get("value", {}).get("type")
            != {"kind": "ref", "name": "ResourceEntitySnapshot"}
            or screen_value != {"kind": "ref", "name": "LayoutDocument"}
        ):
            _catalog_diagnostic(
                diagnostics,
                path,
                text,
                "session events must use typed upsert/delete changes with complete screen layouts",
                "ResourceChange",
            )

    input_modifier = types.get("InputModifier")
    if input_modifier is not None:
        browser_key_modifiers = (
            operations.get("browser.input.key", {})
            .get("params", {})
            .get("fields", {})
            .get("modifiers", {})
            .get("type", {})
            .get("items")
        )
        terminal_mouse = operations.get("terminal.input.mouse", {}).get("params", {})
        terminal_modifiers = (
            terminal_mouse.get("fields", {})
            .get("modifiers", {})
            .get("type", {})
            .get("items")
        )
        browser_mouse = operations.get("browser.input.mouse", {}).get("params", {})
        browser_wheel = operations.get("browser.input.wheel", {}).get("params", {})
        browser_frame_fields = types.get("BrowserAttachFrame", {}).get("fields", {})
        browser_mouse_fields = browser_mouse.get("fields", {})
        wheel_fields = browser_wheel.get("fields", {})
        pointer_decimal = {"kind": "primitive", "name": "decimal"}
        nullable_pointer_decimal = {"kind": "nullable", "value": pointer_decimal}
        if (
            input_modifier
            != {"kind": "enum", "values": ["shift", "control", "alt", "meta"]}
            or browser_key_modifiers != {"kind": "ref", "name": "InputModifier"}
            or terminal_modifiers != {"kind": "ref", "name": "InputModifier"}
            or browser_mouse_fields.get("button", {}).get("type", {}).get("values")
            != ["left", "middle", "right", "back", "forward"]
            or any(wheel_fields.get(name, {}).get("required") is not True for name in (
                "x_px",
                "y_px",
                "delta_x",
                "delta_y",
            ))
            or browser_frame_fields.get("pointer_frame_seq", {}).get("required") is not True
            or browser_frame_fields.get("pointer_frame_seq", {}).get("type")
            != nullable_pointer_decimal
            or browser_mouse_fields.get("pointer_frame_seq", {}).get("required") is not True
            or browser_mouse_fields.get("pointer_frame_seq", {}).get("type") != pointer_decimal
            or wheel_fields.get("pointer_frame_seq", {}).get("required") is not True
            or wheel_fields.get("pointer_frame_seq", {}).get("type") != pointer_decimal
            or not any("nonzero delta_rows" in value for value in terminal_mouse.get("constraints", []))
            or not any("must all be finite" in value for value in browser_wheel.get("constraints", []))
        ):
            _catalog_diagnostic(
                diagnostics,
                path,
                text,
                "input operations must share modifiers, require browser frame authority, and enforce exact finite mouse variants",
                "InputModifier",
            )

    undo = operations.get("screen.layout.undo")
    if isinstance(undo, dict):
        undo_fields = undo.get("params", {}).get("fields", {})
        confirmation = undo_fields.get("confirm_close")
        confirmation_token = undo_fields.get("confirmation_token")
        confirmation_error = errors.get("confirmation.required")
        confirmation_type = types.get("ConfirmationRequiredDetails")
        constraints = undo.get("constraints", [])
        expected_token_type = {
            "kind": "primitive",
            "name": "string",
            "min_length": 1,
            "max_length": 128,
        }
        expected_details_fields = {
            "confirmation_token": {
                "required": True,
                "type": expected_token_type,
                "description": (
                    "Opaque stale-state fence for the exact preview. "
                    "This is not an authentication credential."
                ),
            },
            "revision": {
                "required": True,
                "type": {"kind": "primitive", "name": "decimal"},
                "description": "Global session revision captured by the read-only preview.",
            },
            "closes_panes": {
                "required": True,
                "type": {
                    "kind": "array",
                    "items": {"kind": "resource_id", "resource": "pane"},
                    "min_items": 1,
                },
                "description": (
                    "Created panes that the previewed undo would close, "
                    "in stable layout traversal order."
                ),
            },
        }
        if (
            not isinstance(confirmation, dict)
            or confirmation.get("required") is not False
            or confirmation.get("type") != {"kind": "primitive", "name": "boolean"}
            or confirmation.get("default") is not False
            or not isinstance(confirmation_token, dict)
            or confirmation_token.get("required") is not False
            or confirmation_token.get("type") != expected_token_type
            or "confirmation.required" not in undo.get("errors", [])
            or confirmation_error
            != {
                "retryable": False,
                "details": {"kind": "ref", "name": "ConfirmationRequiredDetails"},
            }
            or not isinstance(confirmation_type, dict)
            or confirmation_type.get("fields") != expected_details_fields
            or not any("before changing the global revision" in value for value in constraints)
            or not any("new idempotency key" in value for value in constraints)
            or not any("Under the mutation lock" in value for value in constraints)
            or not any("live ordered tab IDs" in value for value in constraints)
            or not any("stale-state fence" in value for value in constraints)
        ):
            _catalog_diagnostic(
                diagnostics,
                path,
                text,
                "screen.layout.undo must use a read-only, state-bound close confirmation token",
                "screen.layout.undo",
            )

    indeterminate_error = errors.get("mutation.indeterminate")
    expected_indeterminate_error = {
        "retryable": False,
        "details": {
            "kind": "object",
            "fields": {
                "idempotency_key": {
                    "required": True,
                    "type": {"kind": "primitive", "name": "string"},
                },
                "operation": {
                    "required": True,
                    "type": {"kind": "primitive", "name": "string"},
                },
                "recovery": {
                    "required": True,
                    "type": {
                        "kind": "enum",
                        "values": ["inspect_state_then_retry_with_new_key"],
                    },
                },
            },
            "extra": False,
        },
    }
    actual_indeterminate_operations = {
        operation
        for operation, descriptor in operations.items()
        if isinstance(descriptor, dict)
        and isinstance(descriptor.get("errors"), list)
        and "mutation.indeterminate" in descriptor["errors"]
    }
    expected_indeterminate_operations = (
        EXTERNALLY_EFFECTFUL_MUTATIONS & set(operations)
    )
    if (
        expected_indeterminate_operations or indeterminate_error is not None
    ) and indeterminate_error != expected_indeterminate_error:
        _catalog_diagnostic(
            diagnostics,
            path,
            text,
            "mutation.indeterminate must be a stable non-retryable recovery result",
            "mutation.indeterminate",
        )
    if actual_indeterminate_operations != expected_indeterminate_operations:
        missing = sorted(expected_indeterminate_operations - actual_indeterminate_operations)
        unexpected = sorted(actual_indeterminate_operations - expected_indeterminate_operations)
        _catalog_diagnostic(
            diagnostics,
            path,
            text,
            "mutation.indeterminate coverage must match external effects"
            f" (missing={missing!r}, unexpected={unexpected!r})",
            "mutation.indeterminate",
        )
    for operation in sorted(expected_indeterminate_operations):
        descriptor = operations.get(operation)
        if not isinstance(descriptor, dict) or descriptor.get("class") != "mutation":
            _catalog_diagnostic(
                diagnostics,
                path,
                text,
                f"external-effect operation {operation!r} must remain a mutation",
                operation,
            )

    selector_constraints = (
        types.get("Selector", {}).get("constraints")
        if isinstance(types.get("Selector"), dict)
        else None
    )
    if "Selector" in types and (
        not isinstance(selector_constraints, list)
        or not any("complete contiguous" in value for value in selector_constraints)
        or not any("before reads or mutations run" in value for value in selector_constraints)
    ):
        _catalog_diagnostic(
            diagnostics,
            path,
            text,
            "Selector must define contiguous ancestor resolution and pre-execution wrong-parent rejection",
            "Selector",
        )
    return operation_offsets, classes, local_classes


def _schema_operation_classes(
    path: Path,
    diagnostics: list[Diagnostic],
) -> tuple[dict[str, int], dict[str, str]]:
    document = _json_object(path, diagnostics)
    if document is None:
        return {}, {}
    text = path.read_text(encoding="utf-8")
    try:
        operation = document["$defs"]["operation"]
        values = operation["enum"]
        class_groups = operation["x-operation-classes"]
    except (KeyError, TypeError):
        diagnostics.append(
            Diagnostic(path, 1, 1, "boundary.operation", "missing typed operation registry")
        )
        return {}, {}
    if not isinstance(values, list) or values != sorted(values):
        diagnostics.append(
            Diagnostic(path, 1, 1, "boundary.operation", "operation enum must be sorted")
        )
        values = values if isinstance(values, list) else []
    if not isinstance(class_groups, dict) or set(class_groups) != set(TRANSPORT_OPERATION_CLASSES):
        diagnostics.append(
            Diagnostic(
                path,
                1,
                1,
                "boundary.operation-class",
                "x-operation-classes must define the four transported classes",
            )
        )
        class_groups = {}
    classes: dict[str, str] = {}
    for class_name, members in class_groups.items():
        if not isinstance(members, list) or members != sorted(members):
            diagnostics.append(
                Diagnostic(
                    path,
                    1,
                    1,
                    "boundary.operation-class",
                    f"{class_name} operation class must be a sorted array",
                )
            )
            continue
        for name in members:
            if name in classes:
                diagnostics.append(
                    Diagnostic(
                        path,
                        1,
                        1,
                        "boundary.operation-class",
                        f"{name!r} appears in more than one operation class",
                    )
                )
            classes[name] = class_name
    try:
        idempotency_rule = document["$defs"]["request"]["allOf"][0]
        mutation_enum = idempotency_rule["if"]["properties"]["operation"]["enum"]
        requires_key = idempotency_rule["then"]["required"] == ["idempotency_key"]
        forbids_key = idempotency_rule["else"]["not"]["required"] == ["idempotency_key"]
    except (KeyError, IndexError, TypeError):
        mutation_enum = None
        requires_key = False
        forbids_key = False
    if (
        mutation_enum != class_groups.get("mutation")
        or not requires_key
        or not forbids_key
    ):
        diagnostics.append(
            Diagnostic(
                path,
                1,
                1,
                "boundary.operation-class",
                "request idempotency condition must use the exact mutation operation class",
            )
        )
    expected_idempotency_key = {
        "type": "string",
        "description": (
            "Contains 1 to 128 UTF-8 bytes, at least one Unicode scalar outside the "
            "White_Space property, and no Unicode General_Category=Cc control scalar. "
            "Leading, trailing, and internal non-control whitespace is preserved."
        ),
        "minLength": 1,
        "maxLength": 128,
        "pattern": (
            r"^(?=[\s\S]*[^\u0009-\u000D\u0020\u0085\u00A0\u1680\u2000-\u200A"
            r"\u2028\u2029\u202F\u205F\u3000])[^\u0000-\u001F\u007F-\u009F]+$"
        ),
        "x-cmux-max-utf8-bytes": 128,
    }
    try:
        idempotency_key = document["$defs"]["idempotencyKey"]
        request_key = document["$defs"]["request"]["properties"]["idempotency_key"]
    except (KeyError, TypeError):
        idempotency_key = None
        request_key = None
    if (
        idempotency_key != expected_idempotency_key
        or request_key != {"$ref": "#/$defs/idempotencyKey"}
    ):
        diagnostics.append(
            Diagnostic(
                path,
                1,
                1,
                "boundary.idempotency-key",
                "idempotency_key must use the canonical UTF-8, Unicode White_Space, and Cc contract",
            )
        )
    offsets = {
        name: max(text.find(json.dumps(name)), 0) + 1
        for name in values
        if isinstance(name, str)
    }
    return offsets, classes


def _sdk_descriptor_classes(
    tui: Path,
    diagnostics: list[Diagnostic],
    expected_catalog_sha256: str,
) -> list[tuple[Path, dict[str, str]]]:
    descriptors: list[tuple[Path, dict[str, str]]] = []
    bindings = tui / "bindings"
    if not bindings.exists():
        return descriptors
    package_names = ("cpp", "go", "java", "python", "rust", "typescript", "zig")
    paths: list[Path] = []
    for package_name in package_names:
        package = bindings / package_name
        if not package.exists():
            continue
        path = package / ".cmux-resource-api.json"
        if not path.is_file():
            diagnostics.append(
                Diagnostic(
                    path,
                    1,
                    1,
                    "boundary.sdk-descriptor",
                    f"{package_name} high-level SDK is missing .cmux-resource-api.json",
                )
            )
            continue
        paths.append(path)
    for path in paths:
        document = _json_object(path, diagnostics)
        if document is None:
            continue
        if document.get("protocol") != "cmux.protocol/2":
            diagnostics.append(
                Diagnostic(path, 1, 1, "boundary.sdk-descriptor", "protocol must be cmux.protocol/2")
            )
        if document.get("catalog_sha256") != expected_catalog_sha256:
            diagnostics.append(
                Diagnostic(
                    path,
                    1,
                    1,
                    "boundary.sdk-descriptor",
                    "catalog_sha256 must match canonical resource-operations-v2.json",
                )
            )
        value = document.get("operations")
        classes: dict[str, str] = {}
        if isinstance(value, dict):
            for name, descriptor in value.items():
                if isinstance(descriptor, dict) and isinstance(descriptor.get("class"), str):
                    classes[name] = descriptor["class"]
        elif isinstance(value, list):
            for descriptor in value:
                if (
                    isinstance(descriptor, dict)
                    and isinstance(descriptor.get("name"), str)
                    and isinstance(descriptor.get("class"), str)
                ):
                    classes[descriptor["name"]] = descriptor["class"]
        else:
            diagnostics.append(
                Diagnostic(
                    path,
                    1,
                    1,
                    "boundary.sdk-descriptor",
                    "operations must carry operation names and classes",
                )
            )
        descriptors.append((path, classes))
    return descriptors


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


def _compare_operation_classes(
    diagnostics: list[Diagnostic],
    canonical_path: Path,
    canonical: Mapping[str, str],
    other_path: Path,
    other: Mapping[str, str],
    label: str,
) -> None:
    for operation in sorted(set(canonical) & set(other)):
        if canonical[operation] != other[operation]:
            diagnostics.append(
                Diagnostic(
                    other_path,
                    1,
                    1,
                    "boundary.operation-class",
                    f"{operation!r} is {other[operation]!r} in {label}, "
                    f"expected {canonical[operation]!r} from {canonical_path.name}",
                )
            )


def check_contracts(tui: Path) -> list[Diagnostic]:
    diagnostics: list[Diagnostic] = []
    markdown = tui / "spec/resource-api-v2.md"
    schema = tui / "spec/resource-api-v2.json"
    catalog_schema = tui / "spec/resource-operations-v2.schema.json"
    catalog = tui / "spec/resource-operations-v2.json"
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

    inventory_operations = _inventory_operations(inventory, diagnostics)
    canonical, catalog_classes, local_classes = _operation_catalog(catalog, diagnostics)
    runtime = _runtime_operations(resource, diagnostics)
    runtime_classes, runtime_local_classes = _runtime_operation_classes(resource, diagnostics)
    normative, markdown_classes = _markdown_operation_classes(markdown, diagnostics)
    schema_operations, schema_classes = _schema_operation_classes(schema, diagnostics)

    catalog_schema_document = _json_object(catalog_schema, diagnostics)
    try:
        field_properties = catalog_schema_document["$defs"]["field"]["properties"]
        params_properties = catalog_schema_document["$defs"]["params"]["properties"]
        union_properties = catalog_schema_document["$defs"]["unionType"]["properties"]
        unknown_variant = catalog_schema_document["$defs"]["unknownVariant"]
        if field_properties.get("sensitive") != {"type": "boolean"}:
            raise KeyError("field.sensitive")
        if "one_of" not in params_properties:
            raise KeyError("params.one_of")
        if union_properties.get("unknown_variant") != {"$ref": "#/$defs/unknownVariant"}:
            raise KeyError("unionType.unknown_variant")
        if unknown_variant.get("additionalProperties") is not False:
            raise KeyError("unknownVariant.additionalProperties")
    except (KeyError, TypeError, AttributeError):
        diagnostics.append(
            Diagnostic(
                catalog_schema,
                1,
                1,
                "boundary.catalog",
                "catalog schema must type sensitive fields, parameter one-of groups, and open-union unknown variants",
            )
        )

    if canonical:
        canonical_text = catalog.read_text(encoding="utf-8")
        inventory_text = inventory.read_text(encoding="utf-8")
        resource_text = resource.read_text(encoding="utf-8")
        markdown_text = markdown.read_text(encoding="utf-8")
        schema_text = schema.read_text(encoding="utf-8")
        transported_normative = {
            operation: offset
            for operation, offset in normative.items()
            if markdown_classes.get(operation) != "local"
        }
        local_normative = {
            operation: offset
            for operation, offset in normative.items()
            if markdown_classes.get(operation) == "local"
        }
        _compare_operations(
            diagnostics,
            catalog,
            canonical_text,
            canonical,
            inventory,
            inventory_text,
            inventory_operations,
            "inventory.resource_operations",
        )
        _compare_operations(
            diagnostics,
            catalog,
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
            transported_normative,
            "the normative operation table",
        )
        _compare_operations(
            diagnostics,
            catalog,
            canonical_text,
            canonical,
            schema,
            schema_text,
            schema_operations,
            "the envelope operation enum",
        )
        local_offsets = {
            operation: max(canonical_text.find(json.dumps(operation)), 0) + 1
            for operation in local_classes
        }
        runtime_local_offsets = {
            operation: max(resource_text.find(json.dumps(operation)), 0) + 1
            for operation in runtime_local_classes
        }
        _compare_operations(
            diagnostics,
            catalog,
            canonical_text,
            local_offsets,
            resource,
            resource_text,
            runtime_local_offsets,
            "the Rust LocalOperation registry",
        )
        _compare_operations(
            diagnostics,
            catalog,
            canonical_text,
            local_offsets,
            markdown,
            markdown_text,
            local_normative,
            "the normative local operation table",
        )
        _compare_operation_classes(
            diagnostics,
            catalog,
            catalog_classes,
            resource,
            runtime_classes,
            "the Rust ResourceOperation registry",
        )
        _compare_operation_classes(
            diagnostics,
            catalog,
            catalog_classes,
            schema,
            schema_classes,
            "the envelope schema",
        )
        _compare_operation_classes(
            diagnostics,
            catalog,
            {**catalog_classes, **local_classes},
            markdown,
            markdown_classes,
            "the normative operation table",
        )
        _compare_operation_classes(
            diagnostics,
            catalog,
            local_classes,
            resource,
            runtime_local_classes,
            "the Rust LocalOperation registry",
        )
        catalog_document = json.loads(canonical_text)
        catalog_sha256 = hashlib.sha256(
            json.dumps(
                catalog_document,
                sort_keys=True,
                separators=(",", ":"),
                ensure_ascii=False,
            ).encode("utf-8")
        ).hexdigest()
        for descriptor_path, descriptor_classes in _sdk_descriptor_classes(
            tui, diagnostics, catalog_sha256
        ):
            _compare_operation_classes(
                diagnostics,
                catalog,
                catalog_classes,
                descriptor_path,
                descriptor_classes,
                "the SDK descriptor",
            )
            if set(descriptor_classes) != set(catalog_classes):
                diagnostics.append(
                    Diagnostic(
                        descriptor_path,
                        1,
                        1,
                        "boundary.sdk-descriptor",
                        "SDK descriptor operation set differs from the typed catalog",
                    )
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


def _scan_region(
    path: Path,
    text: str,
    start: int,
    end: int,
    private_identity_exceptions: frozenset[str] = frozenset(),
) -> list[Diagnostic]:
    diagnostics: list[Diagnostic] = []
    region = text[start:end]
    occupied: set[tuple[str, int]] = set()
    private_identity_exception_spans = [
        (match.start(), match.end())
        for exception in private_identity_exceptions
        for match in re.finditer(rf"(?i)\b{re.escape(exception)}\b", region)
    ]

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

    for match in PRIVATE_IDENTITY_RE.finditer(region):
        if any(
            exception_start <= match.start() and match.end() <= exception_end
            for exception_start, exception_end in private_identity_exception_spans
        ):
            continue
        offset = start + match.start()
        diagnostics.append(
            _diagnostic_at(
                path,
                text,
                offset,
                "boundary.private-identity",
                f"private resource identity field {match.group(0)!r} cannot cross resource v2",
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
                diagnostics.extend(
                    _scan_region(
                        path,
                        text,
                        start,
                        end,
                        rule.private_identity_exceptions,
                    )
                )
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
