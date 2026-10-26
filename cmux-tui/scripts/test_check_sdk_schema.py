#!/usr/bin/env python3
"""Regression tests for SDK schema and runtime-inventory consistency."""

from __future__ import annotations

import copy
import importlib.util
import tempfile
import unittest
from pathlib import Path


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

    def test_wrong_event_stream_is_rejected(self) -> None:
        document = copy.deepcopy(self.document)
        document["events"]["bell"]["streams"] = ["attach-byte"]
        with self.assertRaisesRegex(CHECKER.SdkSchemaError, "event stream drift"):
            self.validate(document, self.inventory)

    def test_sniffed_command_request_fields_come_from_its_module(self) -> None:
        served = CHECKER.sniffed_commands.resolve(CHECKER.SERVER.with_suffix(""))
        self.assertEqual(served["agent-inventory"].fields, {"expected_machine_id"})
        self.assertEqual(
            served["agent-inventory-watch"].fields,
            {"expected_machine_id", "enabled", "expected_watch_id", "admission_receipt"},
        )
        self.assertTrue(all(command.local_admin for command in served.values()))

    def test_sniffed_command_missing_request_field_is_rejected(self) -> None:
        document = copy.deepcopy(self.document)
        document["commands"]["agent-inventory-watch"]["request"]["fields"].pop("enabled")
        with self.assertRaisesRegex(CHECKER.SdkSchemaError, "request field for agent-inventory-watch"):
            self.validate(document, self.inventory)

    def test_sniffed_command_wrong_authority_is_rejected(self) -> None:
        document = copy.deepcopy(self.document)
        inventory = copy.deepcopy(self.inventory)
        document["commands"]["agent-inventory"]["authority"] = "control"
        inventory["commands"]["local-admin"].remove("agent-inventory")
        inventory["commands"]["control"].append("agent-inventory")
        with self.assertRaisesRegex(CHECKER.SdkSchemaError, "sniffed command authority drift"):
            self.validate(document, inventory)


class SniffedCommandSourceTests(unittest.TestCase):
    """sniffed_commands.resolve reads a fixture server/ directory."""

    CHAIN = "fn frame() { agent_inventory::try_handle(m, c, s, w); }\n"
    MODULE = (
        "pub(super) fn try_handle(mux: &Mux, message: &str) -> Option<bool> {\n"
        "    // fields.remove(\"commented_out\") is not a field\n"
        "    let mode = match fields.remove(\"cmd\").as_deref() {\n"
        "        Some(\"agent-inventory\") => 1,\n"
        "        _ => return None,\n"
        "    };\n"
        "    if !mux.control_clients.is_unix(client) { return Some(false); }\n"
        "    let quote = '\"';\n"
        "    let _ = fields.remove(\"expected_machine_id\");\n"
        "    Some(true)\n"
        "}\n"
    )

    def resolve(self, chain: str, module: str) -> dict:
        with tempfile.TemporaryDirectory() as directory:
            server = Path(directory)
            (server / "connection_frame.rs").write_text(chain, encoding="utf-8")
            (server / "agent_inventory.rs").write_text(module, encoding="utf-8")
            return CHECKER.sniffed_commands.resolve(server, {"agent-inventory"})

    def test_fields_and_guard_come_from_try_handle(self) -> None:
        served = self.resolve(self.CHAIN, self.MODULE)["agent-inventory"]
        self.assertEqual(served.fields, {"expected_machine_id"})
        self.assertTrue(served.local_admin)

    def test_a_module_off_the_sniffer_chain_is_rejected(self) -> None:
        with self.assertRaisesRegex(CHECKER.sniffed_commands.SniffedCommandError, "never calls"):
            self.resolve("fn frame() {}\n", self.MODULE)

    def test_a_module_that_no_longer_matches_the_name_is_rejected(self) -> None:
        module = self.MODULE.replace('Some("agent-inventory")', 'Some("agent-stock")')
        with self.assertRaisesRegex(CHECKER.sniffed_commands.SniffedCommandError, "never matches"):
            self.resolve(self.CHAIN, module)


if __name__ == "__main__":
    unittest.main()
