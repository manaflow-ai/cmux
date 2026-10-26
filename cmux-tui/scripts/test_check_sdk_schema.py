#!/usr/bin/env python3
"""Regression tests for SDK schema and runtime-inventory consistency."""

from __future__ import annotations

import copy
import importlib.util
import sys
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
HANDLERS = sys.modules["handler_commands"]


class DuplicateKeyTests(unittest.TestCase):
    def test_duplicate_object_keys_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "duplicate.json"
            path.write_text('{"event": 1, "event": 2}\n', encoding="utf-8")
            with self.assertRaisesRegex(CHECKER.SdkSchemaError, "duplicate JSON"):
                CHECKER.load_json(path)


class HandlerCommandTests(unittest.TestCase):
    """handler_commands.py, the one rule for commands a handler module decodes."""

    def write(self, tui: Path, name: str, text: str) -> None:
        server = tui / "crates/cmux-tui-core/src/server"
        server.mkdir(parents=True, exist_ok=True)
        (server / name).write_text(text, encoding="utf-8")

    def test_tagged_enum_variants_are_the_served_commands(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            tui = Path(directory)
            self.write(
                tui,
                "handler.rs",
                "#[derive(Deserialize)]\n"
                '#[serde(tag = "cmd", rename_all = "kebab-case")]\n'
                "enum Command {\n"
                "    /// A doc line.\n"
                "    ListThings,\n"
                "    Move(Params),\n"
                "    Pick { key: String, map: BTreeMap<String, u64> },\n"
                "}\n\n"
                "#[derive(Deserialize)]\n"
                "enum Untagged {\n"
                "    Other,\n"
                "}\n\n"
                "pub(super) fn try_handle() {}\n",
            )
            self.write(
                tui,
                "no_handler.rs",
                '#[serde(tag = "cmd")]\nenum Command {\n    Hidden,\n}\n',
            )
            commands = HANDLERS.handler_commands(tui)
        self.assertEqual(set(commands), {"list-things", "move", "pick"})
        self.assertEqual(commands["move"].payload, "Params")
        self.assertEqual(
            commands["pick"].payload, "key: String,\nmap: BTreeMap<String, u64>,"
        )

    def test_the_struct_that_flattens_the_enum_adds_its_fields_to_every_command(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            tui = Path(directory) / "cmux-tui"
            self.write(
                tui,
                "handler.rs",
                '#[derive(Deserialize)]\n#[serde(tag = "cmd")]\nenum Command {\n'
                '    #[serde(rename = "pick")]\n    Pick { key: String },\n}\n\n'
                "#[derive(Deserialize)]\nstruct Request {\n"
                "    #[serde(default)]\n    id: Option<Value>,\n"
                "    #[serde(default)]\n    origin: Origin,\n"
                "    #[serde(flatten)]\n    command: Command,\n}\n\n"
                "pub(super) fn try_handle() {}\n",
            )
            with patch.object(CHECKER, "TUI", tui):
                fields = CHECKER.handler_command_fields({"pick"})["pick"]
        self.assertEqual(set(fields), {"origin", "key"})
        self.assertEqual(fields["origin"].attributes, ("default",))

    def test_a_command_two_modules_decode_is_rejected(self) -> None:
        enum = '#[serde(tag = "cmd")]\nenum Command {\n    #[serde(rename = "x")]\n    X,\n}\n'
        with tempfile.TemporaryDirectory() as directory:
            tui = Path(directory)
            self.write(tui, "a.rs", enum + "fn try_handle() {}\n")
            self.write(tui, "b.rs", enum + "fn try_handle() {}\n")
            with self.assertRaisesRegex(HANDLERS.HandlerCommandError, "decoded by both"):
                HANDLERS.handler_commands(tui)

    def test_an_unread_variant_attribute_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            tui = Path(directory)
            self.write(
                tui,
                "a.rs",
                '#[serde(tag = "cmd")]\nenum Command {\n    #[serde(alias = "y")]\n    X,\n}\n'
                "fn try_handle() {}\n",
            )
            with self.assertRaisesRegex(HANDLERS.HandlerCommandError, "cannot read attribute"):
                HANDLERS.handler_commands(tui)


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

    def test_handler_command_fields_come_from_the_enum_the_handler_decodes(self) -> None:
        commands = CHECKER.handler_command_fields(
            {"agent-cli-intents-attach", "agent-cli-intents-list", "agent-cli-update-job-resolve"}
        )
        self.assertEqual(
            set(commands["agent-cli-intents-attach"]),
            {"expected_machine_id", "expected_session_id", "key", "receipt"},
        )
        self.assertEqual(
            set(commands["agent-cli-intents-list"]),
            {"expected_machine_id", "expected_session_id"},
        )
        self.assertEqual(
            set(commands["agent-cli-update-job-resolve"]),
            {"expected_machine_id", "expected_session_id", "cli", "idempotency_key"},
        )

    def test_handler_variant_change_is_drift(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            tui = Path(directory) / "cmux-tui"
            server = tui / "crates/cmux-tui-core/src/server"
            server.mkdir(parents=True)
            (server / "handler.rs").write_text(
                "#[derive(Deserialize)]\n"
                '#[serde(tag = "cmd", deny_unknown_fields)]\n'
                "enum Command {\n"
                '    #[serde(rename = "ping")]\n'
                "    Ping { owner: String, body: u64 },\n"
                "}\n\n"
                "pub(super) fn try_handle() {}\n",
                encoding="utf-8",
            )
            with patch.object(CHECKER, "TUI", tui):
                fields = CHECKER.handler_command_fields({"ping", "unserved"})
        self.assertEqual(set(fields), {"ping"})
        self.assertEqual(set(fields["ping"]), {"owner", "body"})
        document = copy.deepcopy(self.document)
        runtime = CHECKER.runtime_command_fields()
        runtime["ping"] = fields["ping"]
        with patch.object(CHECKER, "runtime_command_fields", return_value=runtime):
            with self.assertRaisesRegex(CHECKER.SdkSchemaError, "request field for ping"):
                self.validate(document, self.inventory)

    def test_missing_sniffed_request_field_is_rejected(self) -> None:
        document = copy.deepcopy(self.document)
        document["commands"]["agent-cli-intents-record"]["request"]["fields"].pop(
            "expected_session_id"
        )
        with self.assertRaisesRegex(CHECKER.SdkSchemaError, "request field"):
            self.validate(document, self.inventory)

    def test_decoded_receipt_is_not_nullable(self) -> None:
        document = copy.deepcopy(self.document)
        document["commands"]["agent-cli-intents-attach"]["request"]["fields"]["receipt"][
            "nullable"
        ] = True
        with self.assertRaisesRegex(CHECKER.SdkSchemaError, "presence drift"):
            self.validate(document, self.inventory)

    def test_named_request_struct_drift_is_rejected(self) -> None:
        document = copy.deepcopy(self.document)
        document["types"]["AgentCLIIntent"]["fields"].pop("root_key")
        with self.assertRaisesRegex(CHECKER.SdkSchemaError, "request field for AgentCLIIntent"):
            self.validate(document, self.inventory)

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

    def test_agent_session_literals_use_the_struct_the_module_decodes(self) -> None:
        fields = CHECKER.runtime_command_fields()
        page = {"surface", "after_seq", "before_seq", "limit", "kinds"}
        self.assertEqual(set(fields["agent-session-attach"]), page)
        self.assertEqual(set(fields["agent-session-observe"]), page)
        self.assertEqual(set(fields["agent-session-children"]), {"surface"})
        self.assertIn("cwd", fields["agent-session-start"])
        self.assertEqual(set(fields["agent-session-trust"]), {"surface", "cwd", "level", "home_confirmed"})
        self.assertEqual(
            CHECKER._runtime_type_shape(fields["agent-session-permission"]["answered_by"].rust_type),
            "ref<AgentSessionAnsweredBy>",
        )

    def test_agent_session_request_field_drift_is_rejected(self) -> None:
        document = copy.deepcopy(self.document)
        document["commands"]["agent-session-prompt"]["request"]["fields"].pop("prompt_id")
        with self.assertRaisesRegex(CHECKER.SdkSchemaError, "request field for agent-session-prompt"):
            self.validate(document, self.inventory)
        document = copy.deepcopy(self.document)
        document["types"]["AgentSessionAnsweredBy"]["fields"].pop("feed_item")
        with self.assertRaisesRegex(CHECKER.SdkSchemaError, "request field for AgentSessionAnsweredBy"):
            self.validate(document, self.inventory)

    def test_a_literal_must_name_the_struct_its_module_decodes(self) -> None:
        source = """\
enum AgentSessionCommand {
    Attach(PageParams),
    Children(SurfaceParams),
}

fn parse(cmd: &str, params: Value) -> Option<Self> {
    Some(match cmd {
        "agent-session-attach" => Self::Attach(from_value(params).ok()?),
        "agent-session-children" => Self::Children(from_value(params).ok()?),
        _ => return None,
    })
}

fn start(params: Map) -> bool {
    let Ok(params) = serde_json::from_value::<agent_session_start::StartParams>(params) else {
        return false;
    };
    true
}

struct PageParams {
    surface: SurfaceId,
}

struct SurfaceParams {
    surface: SurfaceId,
}
"""
        literal = {"request": "SurfaceParams", "handler": "try_handle", "variant": "AgentSessionCommand::Children"}
        self.assertEqual(
            set(CHECKER._module_literal_fields(source, "agent-session-children", literal, "fixture")),
            {"surface"},
        )
        wrong = {**literal, "request": "PageParams"}
        with self.assertRaisesRegex(CHECKER.SdkSchemaError, "decodes 'agent-session-children' as SurfaceParams"):
            CHECKER._module_literal_fields(source, "agent-session-children", wrong, "fixture")
        moved = {**literal, "variant": "AgentSessionCommand::Attach"}
        with self.assertRaisesRegex(CHECKER.SdkSchemaError, "no longer decodes 'agent-session-children'"):
            CHECKER._module_literal_fields(source, "agent-session-children", moved, "fixture")
        handled = {"request": "agent_session_trust::TrustParams", "handler": "start"}
        with self.assertRaisesRegex(CHECKER.SdkSchemaError, "as StartParams, not agent_session_trust::TrustParams"):
            CHECKER._module_literal_fields(source, "agent-session-start", handled, "fixture")

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
