#!/usr/bin/env python3
"""Regression tests for the resource-v1 public-boundary checker."""

from __future__ import annotations

import importlib.util
import io
import json
import sys
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path


SCRIPT = Path(__file__).with_name("check-resource-api-boundary.py")
SPEC = importlib.util.spec_from_file_location("check_resource_api_boundary", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot load {SCRIPT}")
CHECKER = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = CHECKER
SPEC.loader.exec_module(CHECKER)

INVENTORY_SCRIPT = Path(__file__).with_name("check-spec-inventory.py")
INVENTORY_SPEC = importlib.util.spec_from_file_location(
    "check_spec_inventory_for_resource_boundary",
    INVENTORY_SCRIPT,
)
if INVENTORY_SPEC is None or INVENTORY_SPEC.loader is None:
    raise RuntimeError(f"cannot load {INVENTORY_SCRIPT}")
INVENTORY_CHECKER = importlib.util.module_from_spec(INVENTORY_SPEC)
sys.modules[INVENTORY_SPEC.name] = INVENTORY_CHECKER
INVENTORY_SPEC.loader.exec_module(INVENTORY_CHECKER)


def write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def matching_contract(tui: Path, operations: list[str] | None = None) -> None:
    operations = operations or ["terminal.get", "workspace.list"]
    prefixes = "|".join(CHECKER.RESOURCE_PREFIXES)
    schema = {
        "$defs": {
            "resourceId": {"pattern": f"^({prefixes})_[0-9a-f]{{32}}$"},
            "streamId": {"pattern": r"^stream_[0-9a-f]{32}$"},
        }
    }
    write(
        tui / "spec/resource-api-v1.json",
        json.dumps(schema, indent=2, sort_keys=True) + "\n",
    )
    prefix_rows = "\n".join(
        f"| {resource} | `{prefix}_` |"
        for resource, prefix in CHECKER.MARKDOWN_ID_TYPES
    )
    grouped: dict[str, list[str]] = {}
    for operation in operations:
        scope, suffix = operation.split(".", 1)
        grouped.setdefault(scope, []).append(suffix)
    operation_rows = "\n".join(
        f"| {scope} | " + ", ".join(f"`{suffix}`" for suffix in suffixes) + " |"
        for scope, suffixes in grouped.items()
    )
    write(
        tui / "spec/resource-api-v1.md",
        f"""\
# resource API

| Resource | Prefix |
| --- | --- |
{prefix_rows}

## Operations

| Scope | Operations |
| --- | --- |
{operation_rows}
""",
    )
    write(
        tui / "spec/inventory.json",
        json.dumps({"resource_operations": sorted(operations)}, indent=2) + "\n",
    )
    public_ids = "\n".join(
        f'public_id!({type_name}, "{prefix}");'
        for type_name, prefix in CHECKER.PUBLIC_ID_TYPES
    )
    selector_prefixes = " | ".join(f'"{prefix}"' for prefix in CHECKER.EXPECTED_PREFIXES)
    variants = "\n".join(
        f'    #[serde(rename = "{operation}")]\n    Operation{index},'
        for index, operation in enumerate(operations)
    )
    write(
        tui / "crates/cmux-tui-core/src/resource.rs",
        f"""\
{public_ids}

fn is_registered_public_id(value: &str) -> bool {{
    matches!(value, {selector_prefixes})
}}

pub enum ResourceOperation {{
{variants}
}}
""",
    )


class PublicBoundaryScanTests(unittest.TestCase):
    def test_raw_internal_and_manifest_generated_occurrences_are_allowed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            tui = Path(directory)
            write(tui / "bindings/rust/src/lib.rs", "pub struct Workspace { pub id: String }\n")
            write(
                tui / "bindings/rust/src/raw/protocol.rs",
                "pub surface_id: u64; pub short_id: u64;\n",
            )
            write(
                tui / "bindings/rust/src/internal/adapter.rs",
                "let surface: u64 = 7;\n",
            )
            write(
                tui / "bindings/rust/src/client.rs",
                "pub fn legacy(surface_id: u64) {}\n",
            )
            write(tui / "bindings/go/generated.go", "type Surface struct { ID uint64 }\n")
            write(
                tui / "bindings/go/.cmux-sdk-manifest.json",
                json.dumps({"files": [{"path": "generated.go"}]}) + "\n",
            )

            diagnostics, scanned = CHECKER.scan_public_boundaries(tui)

            self.assertEqual(diagnostics, [])
            self.assertEqual(scanned, 1)

    def test_public_leaks_report_precise_file_and_line(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            tui = Path(directory)
            path = tui / "bindings/rust/src/lib.rs"
            write(
                path,
                """\
pub struct Workspace {
    pub id: u64,
    pub short_id: String,
    pub surface_id: u64,
}
""",
            )

            diagnostics, _ = CHECKER.scan_public_boundaries(tui)
            rendered = [diagnostic.render(tui) for diagnostic in diagnostics]

            self.assertTrue(
                any(item.startswith("bindings/rust/src/lib.rs:2:") and "numeric-id" in item for item in rendered),
                rendered,
            )
            self.assertTrue(
                any(item.startswith("bindings/rust/src/lib.rs:3:") and "short-id" in item for item in rendered),
                rendered,
            )
            self.assertTrue(
                any(item.startswith("bindings/rust/src/lib.rs:4:") and "surface" in item for item in rendered),
                rendered,
            )

    def test_cli_scans_public_strings_but_not_private_slot_identifiers(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            tui = Path(directory)
            path = tui / "crates/cmux-tui/src/main.rs"
            write(
                path,
                """\
const HELP: &str = r#"cmux attach-surface"#;
fn internal() { let surface_id: u64 = 4; }
""",
            )

            diagnostics, _ = CHECKER.scan_public_boundaries(tui)

            self.assertEqual(len(diagnostics), 1)
            self.assertEqual(diagnostics[0].code, "boundary.surface")
            self.assertEqual(diagnostics[0].line, 1)


class ContractRegistryTests(unittest.TestCase):
    def test_live_inventory_schema_types_dotted_resource_operations(self) -> None:
        schema_path = SCRIPT.parents[1] / "spec/inventory.schema.json"
        schema = json.loads(schema_path.read_text(encoding="utf-8"))
        resource_schema = schema["properties"]["resource_operations"]

        INVENTORY_CHECKER.validate_schema(
            ["session.window.title.set", "terminal.get"],
            resource_schema,
        )
        errors = io.StringIO()
        with redirect_stderr(errors), self.assertRaises(SystemExit):
            INVENTORY_CHECKER.validate_schema(["new-workspace"], resource_schema)
        self.assertIn("does not match", errors.getvalue())

    def test_matching_prefix_and_operation_registries_pass(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            tui = Path(directory)
            matching_contract(tui)

            self.assertEqual(CHECKER.check_contracts(tui), [])

    def test_schema_prefix_drift_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            tui = Path(directory)
            matching_contract(tui)
            schema_path = tui / "spec/resource-api-v1.json"
            document = json.loads(schema_path.read_text(encoding="utf-8"))
            document["$defs"]["resourceId"]["pattern"] = r"^(workspace)_[0-9a-f]{32}$"
            write(schema_path, json.dumps(document, indent=2) + "\n")

            diagnostics = CHECKER.check_contracts(tui)

            prefix_errors = [item for item in diagnostics if item.code == "boundary.prefix"]
            self.assertTrue(prefix_errors, diagnostics)
            self.assertTrue(all(item.path == schema_path for item in prefix_errors), diagnostics)
            self.assertGreater(prefix_errors[0].line, 1)

    def test_inventory_runtime_operation_drift_names_both_sides(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            tui = Path(directory)
            matching_contract(tui, ["workspace.list"])
            resource_path = tui / "crates/cmux-tui-core/src/resource.rs"
            source = resource_path.read_text(encoding="utf-8").replace(
                'serde(rename = "workspace.list")',
                'serde(rename = "workspace.get")',
            )
            write(resource_path, source)

            diagnostics = CHECKER.check_contracts(tui)
            messages = [item.message for item in diagnostics]

            self.assertIn(
                "'workspace.list' is missing from the Rust ResourceOperation registry",
                messages,
            )
            self.assertIn(
                "'workspace.get' is not in canonical resource_operations",
                messages,
            )
            self.assertTrue(
                all(item.line > 1 for item in diagnostics if item.code == "boundary.operation"),
                diagnostics,
            )

    def test_inventory_must_be_sorted(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            tui = Path(directory)
            matching_contract(tui, ["workspace.list", "terminal.get"])
            inventory = tui / "spec/inventory.json"
            write(
                inventory,
                json.dumps(
                    {"resource_operations": ["workspace.list", "terminal.get"]},
                    indent=2,
                )
                + "\n",
            )

            diagnostics = CHECKER.check_contracts(tui)

            self.assertTrue(
                any("lexicographically sorted" in item.message for item in diagnostics),
                diagnostics,
            )


if __name__ == "__main__":
    unittest.main()
