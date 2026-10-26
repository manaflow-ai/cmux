#!/usr/bin/env python3
"""Regression tests for SDK schema and runtime-inventory consistency."""

from __future__ import annotations

import copy
import importlib.util
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


SCRIPT = Path(__file__).with_name("check-sdk-schema.py")
SPEC = importlib.util.spec_from_file_location("check_sdk_schema", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot load {SCRIPT}")
CHECKER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECKER)


class DuplicateKeyTests(unittest.TestCase):
    def test_duplicate_object_keys_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "duplicate.json"
            path.write_text('{"event": 1, "event": 2}\n', encoding="utf-8")
            with self.assertRaisesRegex(CHECKER.SdkSchemaError, "duplicate JSON"):
                CHECKER.load_json(path)


class LiveSchemaTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.document = CHECKER.load_json(CHECKER.SPEC / "sdk-schema.json")
        cls.schema = CHECKER.load_json(CHECKER.SPEC / "sdk-schema.schema.json")
        cls.inventory = CHECKER.load_json(CHECKER.SPEC / "inventory.json")
        cls.ir = CHECKER.load_ir(CHECKER.SPEC / "sdk-schema.json")

    def validate(self, document: dict, inventory: dict) -> None:
        ir = CHECKER.load_ir_document(document)
        CHECKER.validate_sdk_ir(ir, document, self.schema, inventory)

    def test_live_schema_matches_runtime_inventory(self) -> None:
        CHECKER.validate_sdk_ir(
            self.ir,
            self.document,
            self.schema,
            self.inventory,
        )

    def test_protocol_key_input_maps_to_the_named_terminal_key_input_type(self) -> None:
        runtime_field = CHECKER.runtime_command_fields()["clear-history"]["fallback_key"]
        schema_type = self.ir.command("clear-history")["request"]["fields"][
            "fallback_key"
        ]["type"]
        self.assertEqual(
            CHECKER._runtime_type_shape(runtime_field.rust_type),
            "ref<TerminalKeyInput>",
        )
        self.assertEqual(
            CHECKER._schema_type_shape(schema_type, self.ir.types),
            "ref<TerminalKeyInput>",
        )

    def test_boxed_command_request_uses_its_named_struct_fields(self) -> None:
        fields = CHECKER.runtime_command_fields()["create-surface-with-receipt"]

        self.assertEqual(set(fields), {
            "operation",
            "origin",
            "receipt",
            "idempotency_key",
            "selectors",
            "selector_fallbacks",
            "pane",
            "workspace",
            "argv",
            "cwd",
            "url",
            "width",
            "cols",
            "rows",
        })
        self.assertEqual(
            CHECKER._runtime_type_shape(fields["selectors"].rust_type),
            "ref<ResourceSelectors>",
        )

    def test_struct_fields_accept_restricted_visibility(self) -> None:
        fields = CHECKER._parse_rust_fields(
            "    pub(super) conversation: String,\n"
            "    pub(crate) limit: Option<u32>,\n"
            "    pub(in crate::server) cursor: Option<String>,\n"
            "    pub id: u64,\n"
            "    plain: bool,\n",
            "Rust struct Fixture",
        )
        self.assertEqual(
            {name: field.rust_type for name, field in fields.items()},
            {
                "conversation": "String",
                "limit": "Option<u32>",
                "cursor": "Option<String>",
                "id": "u64",
                "plain": "bool",
            },
        )

    def test_handler_module_request_uses_its_struct_and_flattened_key(self) -> None:
        fields = CHECKER.runtime_command_fields()["move-bookmark"]
        self.assertEqual(
            set(fields), {"origin", "mutation_id", "bookmark", "parent", "index"}
        )

    def test_missing_command_is_rejected(self) -> None:
        document = copy.deepcopy(self.document)
        document["commands"].pop("ping")
        with self.assertRaisesRegex(CHECKER.SdkSchemaError, "SDK command drift"):
            self.validate(document, self.inventory)

    def test_wrong_command_authority_is_rejected(self) -> None:
        document = copy.deepcopy(self.document)
        document["commands"]["ping"]["authority"] = "frontend"
        with self.assertRaisesRegex(CHECKER.SdkSchemaError, "authority drift"):
            self.validate(document, self.inventory)

    def test_missing_request_field_is_rejected(self) -> None:
        document = copy.deepcopy(self.document)
        document["commands"]["send"]["request"]["fields"].pop("surface")
        with self.assertRaisesRegex(CHECKER.SdkSchemaError, "request field"):
            self.validate(document, self.inventory)

    def test_wrong_request_field_presence_is_rejected(self) -> None:
        document = copy.deepcopy(self.document)
        document["commands"]["send"]["request"]["fields"]["paste"]["presence"] = "required"
        with self.assertRaisesRegex(CHECKER.SdkSchemaError, "presence drift"):
            self.validate(document, self.inventory)

    def test_wrong_request_field_type_is_rejected(self) -> None:
        document = copy.deepcopy(self.document)
        document["commands"]["resize-surface"]["request"]["fields"]["cols"]["type"] = {
            "kind": "scalar",
            "name": "uint32",
        }
        with self.assertRaisesRegex(CHECKER.SdkSchemaError, "type drift"):
            self.validate(document, self.inventory)

    def test_wrong_flattened_request_alias_is_rejected(self) -> None:
        document = copy.deepcopy(self.document)
        document["commands"]["create-workspace"]["request"]["fields"][
            "expected_revision"
        ]["aliases"] = []
        with self.assertRaisesRegex(CHECKER.SdkSchemaError, "alias drift"):
            self.validate(document, self.inventory)

    def test_apps_module_commands_use_their_variant_and_envelope_fields(self) -> None:
        fields = CHECKER.runtime_command_fields()
        self.assertEqual(
            set(fields["apps-set"]),
            {
                "idempotency_key",
                "app",
                "installed",
                "enabled",
                "hidden",
                "hidden_access",
                "sandboxed",
                "grant",
                "origin",
            },
        )
        self.assertEqual(set(fields["apps-list"]), {"origin"})
        self.assertEqual(set(fields["apps-unmount"]), {"mount_id", "origin"})
        # The handler refuses every member but demand_sequence before decoding.
        self.assertEqual(set(fields["apps-agent-inventory-changed"]), {"demand_sequence"})
        self.assertEqual(set(fields["cancel-request"]), {"target"})
        self.assertEqual(
            CHECKER._runtime_type_shape(fields["apps-set"]["hidden_access"].rust_type),
            "ref<AppHiddenAccess>",
        )

    def test_apps_request_field_drift_is_rejected(self) -> None:
        document = copy.deepcopy(self.document)
        document["commands"]["apps-set"]["request"]["fields"].pop("grant")
        with self.assertRaisesRegex(CHECKER.SdkSchemaError, "request field for apps-set"):
            self.validate(document, self.inventory)
        document = copy.deepcopy(self.document)
        document["commands"]["apps-logs"]["request"]["fields"]["follow"]["presence"] = "required"
        with self.assertRaisesRegex(CHECKER.SdkSchemaError, "presence drift for apps-logs"):
            self.validate(document, self.inventory)

    def test_q5_module_commands_use_their_request_structs(self) -> None:
        fields = CHECKER.runtime_command_fields()
        self.assertEqual(set(fields["browser-runtime-status"]), set())
        self.assertEqual(set(fields["browser-runtime-start"]), {"url"})
        self.assertEqual(set(fields["browser-runtime-stop"]), {"runtime"})
        self.assertEqual(set(fields["loopback-open"]), {"stream", "host", "port", "window"})
        self.assertEqual(set(fields["loopback-data"]), {"stream", "data"})
        self.assertEqual(set(fields["loopback-status"]), set())
        self.assertEqual(set(fields["client-hello"]), {"role", "install_id", "page", "proof"})
        # The owner fence and the publication struct in client_registry/.
        self.assertEqual(
            set(fields["machine-catalog-publish"]),
            {"expected_machine_id", "sequence", "machines"},
        )
        self.assertEqual(
            CHECKER._runtime_type_shape(fields["machine-catalog-publish"]["machines"].rust_type),
            "array<ref<MachineCatalogEntry>>",
        )

    def test_q5_module_request_field_drift_is_rejected(self) -> None:
        for command, field, change, message in [
            ("loopback-open", "window", {"presence": "required"}, "presence drift for loopback-open"),
            ("browser-runtime-stop", "runtime", {"type": {"kind": "scalar", "name": "string"}},
             "type drift for browser-runtime-stop"),
            # A null install id is client_hello.bad_request, so it is not nullable.
            ("client-hello", "install_id", {"nullable": True}, "presence drift for client-hello"),
            ("machine-catalog-publish", "sequence", {"presence": "optional"},
             "presence drift for machine-catalog-publish"),
        ]:
            document = copy.deepcopy(self.document)
            document["commands"][command]["request"]["fields"][field].update(change)
            with self.subTest(command=command), self.assertRaisesRegex(
                CHECKER.SdkSchemaError, message
            ):
                self.validate(document, self.inventory)
        document = copy.deepcopy(self.document)
        document["commands"]["client-hello"]["request"]["fields"].pop("proof")
        with self.assertRaisesRegex(CHECKER.SdkSchemaError, "request field for client-hello"):
            self.validate(document, self.inventory)

    def test_module_literal_request_struct_in_another_file_must_exist(self) -> None:
        spec = CHECKER.ModuleCommands(
            enum_name=None,
            envelope=None,
            literals={"machine-catalog-publish": ("client_registry/machine_catalog.rs::Nope",)},
            refused_envelope_fields={},
        )
        with patch.dict(CHECKER.MODULE_COMMANDS, {"connection_frame/machine_catalog": spec}):
            with self.assertRaisesRegex(CHECKER.SdkSchemaError, "cannot find Rust struct Nope"):
                CHECKER.module_command_fields()

    def test_module_enum_parser_reads_every_variant_form(self) -> None:
        body = """\
    #[serde(rename = "x-unit")]
    Unit,
    /// A doc comment.
    #[serde(rename = "x-one")]
    One { id: String, count: Option<u32> },
    #[serde(rename = "x-many")]
    Many {
        #[serde(default)]
        follow: bool,
    },
"""
        commands = CHECKER._module_enum_fields(body, "fixture Command")
        self.assertEqual(
            {name: sorted(fields) for name, fields in commands.items()},
            {"x-unit": [], "x-one": ["count", "id"], "x-many": ["follow"]},
        )
        with self.assertRaisesRegex(CHECKER.SdkSchemaError, "needs #\\[serde\\(rename"):
            CHECKER._module_enum_fields("    Bare,\n", "fixture Command")

    def test_wrong_event_stream_is_rejected(self) -> None:
        document = copy.deepcopy(self.document)
        document["events"]["bell"]["streams"] = ["attach-byte"]
        with self.assertRaisesRegex(CHECKER.SdkSchemaError, "event stream drift"):
            self.validate(document, self.inventory)


if __name__ == "__main__":
    unittest.main()
