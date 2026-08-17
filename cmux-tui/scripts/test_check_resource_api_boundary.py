#!/usr/bin/env python3
"""Regression tests for the resource-v2 public-boundary checker."""

from __future__ import annotations

import importlib.util
import hashlib
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
    mutation_operations: list[str] = []
    schema = {
        "$defs": {
            "idempotencyKey": {
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
            },
            "resourceId": {"pattern": f"^({prefixes})_[0-9a-f]{{32}}$"},
            "streamId": {"pattern": r"^stream_[0-9a-f]{32}$"},
            "operation": {
                "enum": sorted(operations),
                "x-operation-classes": {
                    "read": sorted(operations),
                    "mutation": mutation_operations,
                    "stream_open": [],
                    "connection_control": [],
                },
            },
            "request": {
                "properties": {
                    "idempotency_key": {"$ref": "#/$defs/idempotencyKey"}
                },
                "allOf": [
                    {
                        "if": {
                            "properties": {
                                "operation": {"enum": mutation_operations},
                            }
                        },
                        "then": {"required": ["idempotency_key"]},
                        "else": {"not": {"required": ["idempotency_key"]}},
                    }
                ]
            },
        }
    }
    write(
        tui / "spec/resource-api-v2.json",
        json.dumps(schema, indent=2, sort_keys=True) + "\n",
    )
    prefix_rows = "\n".join(
        f"| {resource} | `{prefix}_` |"
        for resource, prefix in CHECKER.MARKDOWN_ID_TYPES
    )
    operation_rows = (
        "| read | "
        + ", ".join(f"`{operation}`" for operation in sorted(operations))
        + " |\n| local | `sidebar_plugin.list` |"
    )
    write(
        tui / "spec/resource-api-v2.md",
        f"""\
# resource API

| Resource | Prefix |
| --- | --- |
{prefix_rows}

## Typed operation catalog

| Class | Operations |
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
    read_variants = " | ".join(f"Self::Operation{index}" for index in range(len(operations)))
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

pub enum OperationClass {{
    Read,
    Mutation,
    StreamOpen,
    ConnectionControl,
    Local,
}}

pub enum LocalOperation {{
    #[serde(rename = "sidebar_plugin.list")]
    SidebarPluginList,
}}

impl ResourceOperation {{
    pub const fn class(self) -> OperationClass {{
        if matches!(self, {read_variants}) {{
            OperationClass::Read
        }} else {{
            OperationClass::Mutation
        }}
    }}
}}
""",
    )
    object_type = {"kind": "object", "fields": {}, "extra": False}
    operation_catalog = {
        "$schema": "./resource-operations-v2.schema.json",
        "schema_version": 1,
        "protocol": "cmux.protocol/2",
        "resource_scopes": ["terminal", "workspace", "sidebar_plugin"],
        "types": {
            "JsonValue": {"kind": "primitive", "name": "json"},
            "EmptyResult": object_type,
            "RendererGrantResult": {
                "kind": "object",
                "fields": {
                    "token": {
                        "required": True,
                        "type": {"kind": "primitive", "name": "string"},
                        "sensitive": True,
                        "description": "redacted",
                    }
                },
                "extra": False,
            },
            "ProviderCredential": {
                "kind": "object",
                "fields": {
                    "value": {
                        "required": True,
                        "type": {"kind": "primitive", "name": "string"},
                        "sensitive": True,
                        "description": "redacted",
                    }
                },
                "extra": False,
            },
        },
        "generics": {
            "MutationResult": {
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
        },
        "errors": {
            "validation.invalid": {
                "retryable": False,
                "details": object_type,
            }
        },
        "operations": {
            operation: {
                "class": "read",
                "idempotency": "forbidden",
                "target": operation.split(".", 1)[0],
                "ancestors": [],
                "params": {
                    "selectors": {operation.split(".", 1)[0]: "required"},
                    "fields": {},
                    "extra": False,
                },
                "result": {"kind": "ref", "name": "EmptyResult"},
                "errors": ["validation.invalid"],
            }
            for operation in sorted(operations)
        },
        "local_operations": {
            "sidebar_plugin.list": {
                "class": "local",
                "idempotency": "forbidden",
                "target": "sidebar_plugin",
                "ancestors": [],
                "params": {"selectors": {}, "fields": {}, "extra": False},
                "result": {"kind": "ref", "name": "EmptyResult"},
                "errors": ["validation.invalid"],
            }
        },
    }
    write(
        tui / "spec/resource-operations-v2.json",
        json.dumps(operation_catalog, indent=2) + "\n",
    )
    write(
        tui / "spec/resource-operations-v2.schema.json",
        json.dumps(
            {
                "$defs": {
                    "field": {"properties": {"sensitive": {"type": "boolean"}}},
                    "params": {"properties": {"one_of": {}}},
                    "unionType": {
                        "properties": {
                            "unknown_variant": {"$ref": "#/$defs/unknownVariant"}
                        }
                    },
                    "unknownVariant": {"additionalProperties": False},
                }
            },
            indent=2,
        )
        + "\n",
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
    pub workspace_key: String,
    pub slot: u32,
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
            self.assertTrue(
                any(
                    item.startswith("bindings/rust/src/lib.rs:5:")
                    and "private-identity" in item
                    for item in rendered
                ),
                rendered,
            )
            self.assertTrue(
                any(
                    item.startswith("bindings/rust/src/lib.rs:6:")
                    and "private-identity" in item
                    for item in rendered
                ),
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

    def test_cli_allows_relay_transport_slot_but_rejects_resource_slot(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            tui = Path(directory)
            path = tui / "crates/cmux-tui/src/main.rs"
            write(
                path,
                """\
const REMOTE_HELP: &str = "--relay-slot <routing-key>";
const RESOURCE_HELP: &str = "--slot <value>";
""",
            )

            diagnostics, _ = CHECKER.scan_public_boundaries(tui)

            self.assertEqual(len(diagnostics), 1)
            self.assertEqual(diagnostics[0].code, "boundary.private-identity")
            self.assertEqual(diagnostics[0].line, 2)

    def test_docs_scan_only_public_entrypoints(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            tui = Path(directory)
            public = tui / "docs/README.md"
            implementation = tui / "docs/protocol.md"
            raw_spec = tui / "spec/commands.md"
            write(public, "Public users must pass surface_id.\n")
            write(implementation, "Implementation wire field: surface_id.\n")
            write(raw_spec, "Raw protocol field: surface_id.\n")

            diagnostics, scanned = CHECKER.scan_public_boundaries(tui)

            self.assertEqual(scanned, 1)
            self.assertTrue(diagnostics)
            self.assertEqual({item.path for item in diagnostics}, {public})


class ContractRegistryTests(unittest.TestCase):
    def test_live_typed_catalog_matches_every_registry(self) -> None:
        tui = SCRIPT.parents[1]

        self.assertEqual(CHECKER.check_contracts(tui), [])

    def test_live_selector_contract_allows_direct_ids_and_rejects_wrong_parents_first(self) -> None:
        tui = SCRIPT.parents[1]
        catalog = json.loads(
            (tui / "spec/resource-operations-v2.json").read_text(encoding="utf-8")
        )
        terminal_get = catalog["operations"]["terminal.get"]

        self.assertEqual(terminal_get["params"]["selectors"]["machine"], "required")
        self.assertEqual(terminal_get["params"]["selectors"]["session"], "required")
        for scope in ("workspace", "screen", "pane", "tab"):
            self.assertEqual(terminal_get["params"]["selectors"][scope], "optional")
        self.assertEqual(terminal_get["params"]["selectors"]["terminal"], "required")
        self.assertIn("selector.wrong_parent", terminal_get["errors"])
        selector_constraints = catalog["types"]["Selector"]["constraints"]
        self.assertTrue(any("complete contiguous" in value for value in selector_constraints))
        self.assertTrue(any("before reads or mutations run" in value for value in selector_constraints))
        prose = (tui / "spec/resource-api-v2.md").read_text(encoding="utf-8")
        self.assertIn("cannot partially mutate", prose)

    def test_live_runtime_semantic_enums_have_exact_parity(self) -> None:
        catalog = json.loads(
            (SCRIPT.parents[1] / "spec/resource-operations-v2.json").read_text(encoding="utf-8")
        )

        self.assertEqual(
            catalog["types"]["AgentState"]["values"],
            ["working", "blocked", "idle", "done", "unknown"],
        )
        self.assertEqual(
            catalog["types"]["NotificationLevel"]["values"],
            ["info", "warning", "error"],
        )
        self.assertEqual(
            catalog["operations"]["agent.report"]["params"]["fields"]["state"]["type"],
            {"kind": "ref", "name": "AgentState"},
        )
        self.assertEqual(
            catalog["operations"]["agent.list"]["params"]["fields"]["state"]["type"],
            {"kind": "ref", "name": "AgentState"},
        )

    def test_live_open_stream_unions_preserve_unknown_without_masking_known_errors(self) -> None:
        tui = SCRIPT.parents[1]
        catalog = json.loads(
            (tui / "spec/resource-operations-v2.json").read_text(encoding="utf-8")
        )
        expected_unknown = {
            "sdk_name": "Unknown",
            "when": "unrecognized_discriminator",
            "preserve_discriminator": True,
            "preserve_raw_object": True,
        }

        for name in (
            "SessionEventItem",
            "TerminalAttachItem",
            "BrowserAttachItem",
            "SidebarAttachItem",
            "ResourceChange",
        ):
            union = catalog["types"][name]
            self.assertEqual(union["discriminator"], "kind")
            self.assertEqual(union["unknown_variant"], expected_unknown)
            self.assertTrue(any("malformed" in value for value in union["constraints"]))

        schema = json.loads(
            (tui / "spec/resource-operations-v2.schema.json").read_text(encoding="utf-8")
        )
        self.assertEqual(
            schema["$defs"]["unionType"]["properties"]["unknown_variant"],
            {"$ref": "#/$defs/unknownVariant"},
        )

    def test_live_render_session_and_layout_models_are_lossless_and_typed(self) -> None:
        catalog = json.loads(
            (SCRIPT.parents[1] / "spec/resource-operations-v2.json").read_text(encoding="utf-8")
        )
        types = catalog["types"]

        self.assertEqual(
            types["RenderRun"]["fields"]["attrs"]["type"],
            {"kind": "primitive", "name": "uint32"},
        )
        self.assertEqual(
            set(types["RenderRun"]["fields"]),
            {"text", "fg", "bg", "attrs", "underline", "width_hint"},
        )
        self.assertEqual(
            [item["name"] for item in types["TerminalAttachItem"]["variants"]],
            ["TerminalAttachSnapshot", "TerminalAttachPatch", "TerminalAttachScroll"],
        )
        self.assertEqual(
            [item["name"] for item in types["SidebarAttachItem"]["variants"]],
            ["SidebarAttachSnapshot", "SidebarAttachPatch", "SidebarAttachScroll"],
        )
        self.assertEqual(
            types["TerminalHistoryResult"]["fields"]["rows"]["type"]["items"],
            {"kind": "ref", "name": "RenderRow"},
        )
        self.assertNotIn("ResourceDelta", types)
        self.assertEqual(
            types["SessionDelta"]["fields"]["changes"]["type"]["items"],
            {"kind": "ref", "name": "ResourceChange"},
        )
        self.assertEqual(
            [item["name"] for item in types["LayoutNode"]["variants"]],
            ["LayoutLeaf", "LayoutSplit", "LayoutStack", "LayoutViewport"],
        )
        self.assertEqual(
            types["ScreenSnapshot"]["fields"]["layout"]["type"],
            {"kind": "ref", "name": "LayoutDocument"},
        )

    def test_live_mutation_client_and_sensitive_shapes_are_exact(self) -> None:
        catalog = json.loads(
            (SCRIPT.parents[1] / "spec/resource-operations-v2.json").read_text(encoding="utf-8")
        )
        types = catalog["types"]
        mutation_fields = catalog["generics"]["MutationResult"]["body"]["fields"]

        self.assertEqual(
            set(mutation_fields),
            {"value", "generation", "revision", "replayed"},
        )
        self.assertNotIn("MutationReceipt", types)
        self.assertEqual(
            set(types["ClientSnapshot"]["fields"]),
            {
                "id",
                "session_id",
                "name",
                "client_kind",
                "transport",
                "connected_seconds",
                "attached_terminal_ids",
                "sizes",
                "self",
                "extra",
            },
        )
        self.assertNotIn("ProviderScopeSnapshot", types)
        self.assertNotIn("ProviderActionSnapshot", types)
        self.assertNotIn("ProviderNoticeSnapshot", types)
        self.assertNotIn("plugin_id", types["SidebarViewSnapshot"]["fields"])
        self.assertNotIn(
            "plugin_id",
            catalog["operations"]["sidebar_view.ensure"]["params"]["fields"],
        )
        self.assertTrue(types["PairingRequestSnapshot"]["fields"]["code"]["sensitive"])
        self.assertNotIn("incarnation", types["RendererGrantResult"]["fields"])
        self.assertEqual(
            set(types["StreamError"]["fields"]),
            {"code", "message", "details", "retryable"},
        )

    def test_live_external_effects_fail_closed_after_an_indeterminate_crash(self) -> None:
        tui = SCRIPT.parents[1]
        catalog = json.loads(
            (tui / "spec/resource-operations-v2.json").read_text(encoding="utf-8")
        )
        expected_error = {
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

        self.assertEqual(catalog["errors"]["mutation.indeterminate"], expected_error)
        actual = {
            operation
            for operation, descriptor in catalog["operations"].items()
            if "mutation.indeterminate" in descriptor["errors"]
        }
        self.assertEqual(actual, CHECKER.EXTERNALLY_EFFECTFUL_MUTATIONS)
        self.assertTrue(
            all(
                catalog["operations"][operation]["class"] == "mutation"
                for operation in actual
            )
        )
        prose = (tui / "spec/resource-api-v2.md").read_text(encoding="utf-8")
        self.assertIn("marks it executing before invoking the effect", prose)
        self.assertIn("is never\nrepeated automatically", prose)
        self.assertIn("inspect_state_then_retry_with_new_key", prose)

    def test_live_argv_preserves_empty_later_arguments_and_inputs_are_exact(self) -> None:
        catalog = json.loads(
            (SCRIPT.parents[1] / "spec/resource-operations-v2.json").read_text(encoding="utf-8")
        )
        argv = ["printf", "%s", ""]
        self.assertEqual(json.loads(json.dumps(argv)), argv)
        for owner in (
            catalog["types"]["CommandSpec"]["variants"][0]["fields"]["argv"]["type"],
            catalog["operations"]["workspace.run"]["params"]["fields"]["argv"]["type"],
            catalog["operations"]["pane.run"]["params"]["fields"]["argv"]["type"],
        ):
            self.assertEqual(owner["items"], {"kind": "primitive", "name": "string"})
            self.assertEqual(owner["min_items"], 1)
        self.assertEqual(
            catalog["types"]["InputModifier"]["values"],
            ["shift", "control", "alt", "meta"],
        )
        wheel = catalog["operations"]["browser.input.wheel"]["params"]
        self.assertTrue(
            all(wheel["fields"][name]["required"] for name in (
                "x_px",
                "y_px",
                "delta_x",
                "delta_y",
                "pointer_frame_seq",
            ))
        )
        decimal = {"kind": "primitive", "name": "decimal"}
        self.assertEqual(wheel["fields"]["pointer_frame_seq"]["type"], decimal)
        mouse_pointer = catalog["operations"]["browser.input.mouse"]["params"]["fields"][
            "pointer_frame_seq"
        ]
        self.assertTrue(mouse_pointer["required"])
        self.assertEqual(mouse_pointer["type"], decimal)
        frame_pointer = catalog["types"]["BrowserAttachFrame"]["fields"][
            "pointer_frame_seq"
        ]
        self.assertTrue(frame_pointer["required"])
        self.assertEqual(
            frame_pointer["type"],
            {"kind": "nullable", "value": decimal},
        )

    def test_live_catalog_counts_and_local_endpoint_scope_are_frozen(self) -> None:
        catalog = json.loads(
            (SCRIPT.parents[1] / "spec/resource-operations-v2.json").read_text(encoding="utf-8")
        )
        self.assertEqual(len(catalog["operations"]), 124)
        self.assertEqual(len(catalog["local_operations"]), 6)
        self.assertEqual(
            set(catalog["types"]["MachineSnapshot"]["fields"]),
            {
                "id",
                "name",
                "origin",
                "status",
                "connectable",
                "deleted",
                "recoverable",
                "extra",
            },
        )
        self.assertEqual(
            catalog["types"]["MachineSnapshot"]["fields"]["origin"]["type"]["values"],
            ["local"],
        )

    def test_live_creation_correlation_is_exactly_the_eight_created_path_operations(
        self,
    ) -> None:
        catalog = json.loads(
            (SCRIPT.parents[1] / "spec/resource-operations-v2.json").read_text(encoding="utf-8")
        )
        actual = {
            operation
            for operation, descriptor in catalog["operations"].items()
            if descriptor["params"]["fields"]
            .get("correlation_key", {})
            .get("required")
            is False
        }
        self.assertEqual(actual, CHECKER.CORRELATED_CREATION_OPERATIONS)
        self.assertTrue(
            all("creation.conflict" in catalog["operations"][operation]["errors"] for operation in actual)
        )

    def test_live_terminal_snapshot_has_strict_public_lifecycle(self) -> None:
        catalog = json.loads(
            (SCRIPT.parents[1] / "spec/resource-operations-v2.json").read_text(encoding="utf-8")
        )
        self.assertEqual(
            catalog["types"]["TerminalLifecycle"],
            {"kind": "enum", "values": ["launching", "running", "exited"]},
        )
        snapshot = catalog["types"]["TerminalSnapshot"]
        self.assertEqual(
            snapshot["fields"]["lifecycle"],
            {
                "required": True,
                "type": {"kind": "ref", "name": "TerminalLifecycle"},
            },
        )
        self.assertIn("exit is present exactly when lifecycle is exited.", snapshot["constraints"])

    def test_live_layout_undo_confirmation_is_precommit_and_retry_safe(self) -> None:
        catalog = json.loads(
            (SCRIPT.parents[1] / "spec/resource-operations-v2.json").read_text(encoding="utf-8")
        )
        undo = catalog["operations"]["screen.layout.undo"]

        self.assertEqual(
            undo["params"]["fields"]["confirm_close"],
            {
                "required": False,
                "type": {"kind": "primitive", "name": "boolean"},
                "default": False,
            },
        )
        self.assertEqual(
            undo["params"]["fields"]["confirmation_token"],
            {
                "required": False,
                "type": {
                    "kind": "primitive",
                    "name": "string",
                    "min_length": 1,
                    "max_length": 128,
                },
                "description": (
                    "Exact opaque token returned by the read-only "
                    "confirmation preview."
                ),
            },
        )
        details = catalog["types"]["ConfirmationRequiredDetails"]["fields"]
        self.assertEqual(
            details["confirmation_token"]["type"],
            {
                "kind": "primitive",
                "name": "string",
                "min_length": 1,
                "max_length": 128,
            },
        )
        self.assertEqual(
            set(details),
            {"confirmation_token", "revision", "closes_panes"},
        )
        self.assertIn("confirmation.required", undo["errors"])
        self.assertTrue(
            any("before changing the global revision" in value for value in undo["constraints"])
        )
        self.assertTrue(any("new idempotency key" in value for value in undo["constraints"]))
        self.assertTrue(any("Under the mutation lock" in value for value in undo["constraints"]))
        self.assertTrue(any("live ordered tab IDs" in value for value in undo["constraints"]))
        self.assertTrue(any("stale-state fence" in value for value in undo["constraints"]))

    def test_live_inventory_schema_types_dotted_resource_operations(self) -> None:
        schema_path = SCRIPT.parents[1] / "spec/inventory.schema.json"
        schema = json.loads(schema_path.read_text(encoding="utf-8"))
        resource_schema = schema["properties"]["resource_operations"]
        self.assertIn("resource_operations", schema["required"])

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
            schema_path = tui / "spec/resource-api-v2.json"
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

    def test_catalog_rejects_class_idempotency_and_result_schema_holes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            tui = Path(directory)
            matching_contract(tui, ["workspace.list"])
            catalog_path = tui / "spec/resource-operations-v2.json"
            catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
            operation = catalog["operations"]["workspace.list"]
            operation["class"] = "mutation"
            operation["idempotency"] = "forbidden"
            del operation["result"]
            write(catalog_path, json.dumps(catalog, indent=2) + "\n")

            diagnostics = CHECKER.check_contracts(tui)
            messages = [item.message for item in diagnostics]

            self.assertTrue(any("idempotency must be required" in item for item in messages), messages)
            self.assertTrue(any("descriptor has a schema hole" in item for item in messages), messages)

    def test_catalog_rejects_client_metadata_label_contract_drift(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            tui = Path(directory)
            matching_contract(tui, ["client.metadata.update"])
            catalog_path = tui / "spec/resource-operations-v2.json"
            catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
            operation = catalog["operations"]["client.metadata.update"]
            description = (
                "Omitted means no change, null clears, and a non-null string preserves "
                "its exact value, including empty, whitespace, and Unicode. A non-null "
                "value contains at most 64 Unicode scalars and no Unicode "
                "General_Category=Cc control scalar."
            )
            nullable_string = {
                "kind": "nullable",
                "value": {"kind": "primitive", "name": "string"},
            }
            operation["params"]["fields"] = {
                field: {
                    "required": False,
                    "type": nullable_string,
                    "description": description,
                }
                for field in ("name", "kind")
            }
            operation["params"]["constraints"] = [
                "At least one of name or kind is present.",
                "Each present non-null name or kind contains at most 64 Unicode scalars "
                "and no Unicode General_Category=Cc control scalar.",
                "A constraint violation returns validation.invalid before either field mutates.",
            ]
            write(catalog_path, json.dumps(catalog, indent=2) + "\n")

            diagnostics: list[CHECKER.Diagnostic] = []
            CHECKER._operation_catalog(catalog_path, diagnostics)
            self.assertFalse(
                any("client.metadata.update name and kind" in item.message for item in diagnostics),
                diagnostics,
            )

            catalog["operations"]["client.metadata.update"]["params"]["fields"]["kind"][
                "description"
            ] = "string sets"
            write(catalog_path, json.dumps(catalog, indent=2) + "\n")
            diagnostics = []
            CHECKER._operation_catalog(catalog_path, diagnostics)
            self.assertTrue(
                any("client.metadata.update name and kind" in item.message for item in diagnostics),
                diagnostics,
            )

    def test_catalog_rejects_session_shutdown_lifecycle_contract_drift(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            tui = Path(directory)
            matching_contract(tui, ["session.shutdown"])
            catalog_path = tui / "spec/resource-operations-v2.json"
            catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
            operation = catalog["operations"]["session.shutdown"]
            operation["constraints"] = [
                "Requires a trusted local Unix-socket connection and is unavailable over WebSocket.",
                "With force=false, another connected native-browser owner rejects shutdown; "
                "force=true bypasses only that ownership check.",
                "On success, the durable receipt is committed and its response is queued before "
                "process exit is requested.",
                "A failed response queue cancels the shutdown handoff without requesting exit; "
                "same-key replay may reserve a new handoff and retry the post-response exit request.",
            ]
            write(catalog_path, json.dumps(catalog, indent=2) + "\n")

            diagnostics: list[CHECKER.Diagnostic] = []
            CHECKER._operation_catalog(catalog_path, diagnostics)
            self.assertFalse(
                any("session.shutdown must encode" in item.message for item in diagnostics),
                diagnostics,
            )

            operation["constraints"].pop()
            write(catalog_path, json.dumps(catalog, indent=2) + "\n")
            diagnostics = []
            CHECKER._operation_catalog(catalog_path, diagnostics)
            self.assertTrue(
                any("session.shutdown must encode" in item.message for item in diagnostics),
                diagnostics,
            )

    def test_catalog_rejects_external_effect_without_indeterminate_recovery(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            tui = Path(directory)
            matching_contract(tui, ["workspace.run"])
            catalog_path = tui / "spec/resource-operations-v2.json"
            catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
            operation = catalog["operations"]["workspace.run"]
            operation["class"] = "mutation"
            operation["idempotency"] = "required"
            operation["result"] = {
                "kind": "apply",
                "name": "MutationResult",
                "arguments": [{"kind": "ref", "name": "EmptyResult"}],
            }
            write(catalog_path, json.dumps(catalog, indent=2) + "\n")

            diagnostics: list[CHECKER.Diagnostic] = []
            CHECKER._operation_catalog(catalog_path, diagnostics)

            self.assertTrue(
                any(
                    "stable non-retryable recovery result" in item.message
                    for item in diagnostics
                ),
                diagnostics,
            )
            self.assertTrue(
                any(
                    "coverage must match external effects" in item.message
                    for item in diagnostics
                ),
                diagnostics,
            )

    def test_run_catalog_requires_exact_argv_or_shell_one_of(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            tui = Path(directory)
            matching_contract(tui, ["workspace.run"])

            diagnostics = CHECKER.check_contracts(tui)

            self.assertTrue(
                any("must model exact argv/shell one-of" in item.message for item in diagnostics),
                diagnostics,
            )

    def test_catalog_rejects_unknown_fallback_that_can_mask_malformed_known_variants(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            tui = Path(directory)
            matching_contract(tui)
            catalog_path = tui / "spec/resource-operations-v2.json"
            catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
            catalog["types"]["KnownSessionEvent"] = {
                "kind": "object",
                "fields": {
                    "kind": {
                        "required": True,
                        "type": {"kind": "enum", "values": ["known"]},
                    }
                },
                "extra": False,
            }
            catalog["types"]["SessionEventItem"] = {
                "kind": "union",
                "variants": [{"kind": "ref", "name": "KnownSessionEvent"}],
                "discriminator": "kind",
                "unknown_variant": {
                    "sdk_name": "Unknown",
                    "when": "unrecognized_discriminator",
                    "preserve_discriminator": True,
                    "preserve_raw_object": True,
                },
                "constraints": ["Malformed known payloads may become Unknown."],
            }
            write(catalog_path, json.dumps(catalog, indent=2) + "\n")

            diagnostics: list[CHECKER.Diagnostic] = []
            CHECKER._operation_catalog(catalog_path, diagnostics)

            self.assertTrue(
                any(
                    "without accepting malformed known variants" in item.message
                    for item in diagnostics
                ),
                diagnostics,
            )

    def test_catalog_rejects_forbidden_identity_fields_and_missing_redaction(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            tui = Path(directory)
            matching_contract(tui)
            catalog_path = tui / "spec/resource-operations-v2.json"
            catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
            catalog["types"]["WorkspaceSnapshot"] = {
                "kind": "object",
                "fields": {
                    "workspace_key": {
                        "required": True,
                        "type": {"kind": "primitive", "name": "string"},
                    }
                },
                "extra": False,
            }
            catalog["types"]["RendererGrantResult"]["fields"]["token"]["sensitive"] = False
            write(catalog_path, json.dumps(catalog, indent=2) + "\n")

            diagnostics: list[CHECKER.Diagnostic] = []
            CHECKER._operation_catalog(catalog_path, diagnostics)
            messages = [item.message for item in diagnostics]

            self.assertTrue(any("forbidden public identity field" in item for item in messages), messages)
            self.assertTrue(any("RendererGrantResult.fields.token must be sensitive" in item for item in messages), messages)

    def test_sdk_descriptor_operation_class_drift_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            tui = Path(directory)
            matching_contract(tui, ["workspace.list"])
            write(
                tui / "bindings/python/.cmux-resource-api.json",
                json.dumps(
                    {
                        "protocol": "cmux.protocol/2",
                        "catalog_sha256": hashlib.sha256(
                            json.dumps(
                                json.loads(
                                    (tui / "spec/resource-operations-v2.json").read_text(
                                        encoding="utf-8"
                                    )
                                ),
                                sort_keys=True,
                                separators=(",", ":"),
                                ensure_ascii=False,
                            ).encode("utf-8")
                        ).hexdigest(),
                        "operations": {
                            "workspace.list": {"class": "mutation"},
                        },
                    },
                    indent=2,
                )
                + "\n",
            )

            diagnostics = CHECKER.check_contracts(tui)

            self.assertTrue(
                any(
                    item.code == "boundary.operation-class"
                    and "SDK descriptor" in item.message
                    for item in diagnostics
                ),
                diagnostics,
            )

    def test_sdk_descriptor_catalog_hash_drift_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            tui = Path(directory)
            matching_contract(tui, ["workspace.list"])
            write(
                tui / "bindings/python/.cmux-resource-api.json",
                json.dumps(
                    {
                        "protocol": "cmux.protocol/2",
                        "catalog_sha256": "0" * 64,
                        "operations": {
                            "workspace.list": {"class": "read"},
                        },
                    },
                    indent=2,
                )
                + "\n",
            )

            diagnostics = CHECKER.check_contracts(tui)

            self.assertTrue(
                any(
                    item.code == "boundary.sdk-descriptor"
                    and "catalog_sha256" in item.message
                    for item in diagnostics
                ),
                diagnostics,
            )

    def test_existing_high_level_sdk_requires_catalog_descriptor(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            tui = Path(directory)
            matching_contract(tui, ["workspace.list"])
            write(tui / "bindings/python/cmux/__init__.py", "")

            diagnostics = CHECKER.check_contracts(tui)

            self.assertTrue(
                any(
                    item.code == "boundary.sdk-descriptor"
                    and "python high-level SDK is missing" in item.message
                    for item in diagnostics
                ),
                diagnostics,
            )


if __name__ == "__main__":
    unittest.main()
