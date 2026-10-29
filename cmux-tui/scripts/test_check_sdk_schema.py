#!/usr/bin/env python3
"""Regression tests for SDK schema and runtime-inventory consistency."""

from __future__ import annotations

import contextlib
import copy
import io
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
SNIFFERS = sys.modules["sniffer_names"]


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

    def test_a_module_with_a_route_and_no_try_handle_serves_its_enum(self) -> None:
        enum = '#[serde(tag = "cmd")]\nenum Command {\n    #[serde(rename = "{0}")]\n    X,\n}\n'
        with tempfile.TemporaryDirectory() as directory:
            tui = Path(directory)
            self.write(
                tui,
                "routed.rs",
                enum.replace("{0}", "routed")
                + "pub(in crate::server) const ROUTES: &[Route] = &[];\n"
                "fn handle(line: &RouteLine<'_>) -> Option<bool> { None }\n",
            )
            self.write(
                tui,
                "unrouted.rs",
                enum.replace("{0}", "unrouted") + "fn handle() {}\n",
            )
            commands = HANDLERS.handler_commands(tui)
        self.assertEqual(set(commands), {"routed"})
        self.assertEqual(commands["routed"].module.name, "routed.rs")

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

    def test_an_empty_struct_variant_and_a_crate_path_payload_are_read(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            tui = Path(directory) / "cmux-tui"
            self.write(
                tui,
                "handler.rs",
                '#[derive(Deserialize)]\n#[serde(tag = "cmd", deny_unknown_fields)]\nenum Command {\n'
                '    #[serde(rename = "a.empty")]\n    Empty {},\n'
                '    #[serde(rename = "a.read")]\n    Read(crate::store::ops::ReadParams),\n}\n\n'
                "pub(super) fn try_handle() {}\n",
            )
            ops = tui / "crates/cmux-tui-core/src/store"
            ops.mkdir(parents=True)
            (ops / "ops.rs").write_text(
                "pub(crate) struct ReadParams {\n"
                "    pub(crate) path: String,\n"
                '    #[serde(default, deserialize_with = "non_null")]\n'
                "    offset: Option<u64>,\n"
                "}\n",
                encoding="utf-8",
            )
            with (
                patch.object(CHECKER, "TUI", tui),
                patch.object(CHECKER, "CORE_SRC", tui / "crates/cmux-tui-core/src"),
            ):
                fields = CHECKER.handler_command_fields({"a.empty", "a.read"})
        self.assertEqual(fields["a.empty"], {})
        self.assertEqual(set(fields["a.read"]), {"path", "offset"})
        self.assertEqual(
            CHECKER._runtime_field_presence(fields["a.read"]["offset"]), ("optional", False)
        )

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


class SnifferNameTests(unittest.TestCase):
    """sniffer_names.py: every name a sniffer module serves, and its schema coverage."""

    APPS_RS = (
        '#[derive(Deserialize)]\n#[serde(tag = "cmd")]\nenum Command {\n'
        '    #[serde(rename = "apps-list")]\n    List,\n'
        "EXTRA_VARIANTS"
        "}\n\n"
        "#[derive(Deserialize)]\nstruct Request {\n"
        "    #[serde(default)]\n    id: Option<Value>,\n"
        "    #[serde(flatten)]\n    command: Command,\n}\n\n"
        "pub(super) fn try_handle(message: &str) -> Option<bool> {\n"
        '    if cmd == "cancel-request" {\n        return None;\n    }\n'
        "    None\n}\n"
    )
    APPS_TABLE = (
        '{"modules": {"apps": {"enum": "Command", "literals": '
        '{"cancel-request": {"request": "CancelRequest", "handler": "cancel_request"}}}}}'
    )

    @classmethod
    def setUpClass(cls) -> None:
        cls.ir = CHECKER.load_ir(CHECKER.SPEC / "sdk-schema.json")

    def apps_rs(self, extra_variants: str) -> str:
        return self.APPS_RS.replace("EXTRA_VARIANTS", extra_variants)

    def served(self, files: dict[str, str], **options) -> dict:
        """sniffer_names over a fixture tree. `scripts/...` files go under
        the tui root, the rest under server/; by default every server file
        is a sniffer module and none is nameless."""

        server_files = {name for name in files if not name.startswith(("scripts/", "../"))}
        options.setdefault("modules", server_files)
        options.setdefault("nameless", {})
        options.setdefault("name_lists", {})
        with tempfile.TemporaryDirectory() as directory:
            tui = Path(directory)
            for name, text in files.items():
                if name.startswith("scripts/"):
                    path = tui / name
                else:
                    path = tui / "crates/cmux-tui-core/src/server" / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(text, encoding="utf-8")
            return SNIFFERS.sniffer_names(tui, **options)

    def names(self, source: str, shared: dict | None = None) -> set[str]:
        return SNIFFERS.literal_names(source, "fixture.rs", shared)

    def test_literal_forms_are_served_names(self) -> None:
        source = (
            'const COMMAND: &str = "by-const";\n'
            'const PLAN: &str = "plan-const";\n'
            'const CAPABILITY: &str = "never-compared-v1";\n'
            "pub(super) fn try_handle(message: &str) -> Option<bool> {\n"
            '    // cmd == "in-a-comment"\n'
            '    if !message.contains("\\"by-") {\n        return None;\n    }\n'
            '    let mode = match fields.remove("cmd").as_ref().and_then(Value::as_str) {\n'
            '        Some("some-arm") | Some("other-arm") => 1,\n'
            "        _ => return None,\n    };\n"
            '    if fields.remove("cmd").as_ref().and_then(Value::as_str) != Some(COMMAND) {\n'
            "        return None;\n    }\n"
            '    if cmd == "equal" || "reversed" == cmd || cmd.as_str() != PLAN {}\n'
            '    if error.code == "bad-request" {}\n'
            "    match cmd {\n"
            '        "arm" | "piped-arm" => {\n'
            '            match kind { "nested-arm" => {} _ => {} }\n'
            "        }\n"
            '        "fs.dotted" => "value-side",\n'
            "        _ => {}\n    }\n"
            '    match operation { "apps.store" => {} _ => {} }\n'
            "    None\n}\n"
        )
        served = self.served(
            {"sniffer.rs": source, "plain.rs": 'fn x() { cmd == "not-a-sniffer"; }\n'},
            modules={"sniffer.rs"},
        )
        self.assertEqual(
            set(served),
            {
                "by-const",
                "plan-const",
                "some-arm",
                "other-arm",
                "equal",
                "reversed",
                "arm",
                "piped-arm",
                "fs.dotted",
            },
        )
        self.assertEqual({entry.module for entry in served.values()}, {"sniffer.rs"})

    def test_route_names_are_served_names(self) -> None:
        # A typed route handler compares no `cmd`: its route's names are what it serves.
        source = (
            'const COMMAND: &str = "by-const";\n'
            "pub(in crate::server) const ROUTES: &[Route] = &[Route {\n"
            "    names: &[\n"
            "        RouteName::Exact(COMMAND),\n"
            '        crate::server::routes::RouteName::Exact("literal"),\n'
            '        RouteName::OneOf(&[COMMAND, "listed"]),\n'
            '        RouteName::Prefix("family-"),\n'
            "    ],\n"
            "    stage: FrameStage::Route,\n"
            "    entry: handle,\n"
            "}];\n"
        )
        self.assertEqual(self.names(source), {"by-const", "literal", "listed"})

    def test_guard_arms_matches_and_command_expressions(self) -> None:
        self.assertEqual(
            self.names('fn f() { match cmd { "a" if ok => 1, "b" => 2, _ => 0 } }'), {"a", "b"}
        )
        self.assertEqual(
            self.names(
                'fn f() { match v.get("cmd").and_then(Value::as_str) {\n'
                '    Some("g") if matches!(w, W::Open { y: false }) => 1, _ => 0 } }'
            ),
            {"g"},
        )
        self.assertEqual(self.names('fn f() { matches!(cmd, "a" | "b") }'), {"a", "b"})
        self.assertEqual(
            self.names(
                'const A: &str = "c-a";\nconst B: &str = "c-b";\n'
                'fn f() { matches!(fields.get("cmd").and_then(Value::as_str), Some(A | B)) }'
            ),
            {"c-a", "c-b"},
        )
        self.assertEqual(self.names('fn f() { matches!(key.as_str(), "cmd" | "id") }'), set())
        self.assertEqual(self.names('fn f() { match &*cmd { "deref" => 1, _ => 0 } }'), {"deref"})
        self.assertEqual(
            self.names('fn f() { match command.as_deref() { Some("opt") => 1, _ => 0 } }'),
            {"opt"},
        )
        self.assertEqual(
            self.names('fn f() { cmd.eq("by-eq"); command != Some("some-ne"); }'),
            {"by-eq", "some-ne"},
        )
        self.assertEqual(
            self.names("fn f() { match request.command { Command::List => 1, _ => 0 } }"), set()
        )

    def test_char_and_raw_string_literals_do_not_hide_names(self) -> None:
        self.assertEqual(
            self.names("fn f() { match cmd { \"a\" => c == '}', \"b\" => 1, _ => 0 } }"),
            {"a", "b"},
        )
        self.assertEqual(
            self.names("fn f() { let q = '\"'; if cmd == \"after-quote\" {} }"), {"after-quote"}
        )
        self.assertEqual(
            self.names('fn f() { let x = r#"x" // "#; if cmd == "after-raw" {} }'), {"after-raw"}
        )
        self.assertEqual(self.names('fn f() { if cmd == r"raw-name" {} }'), {"raw-name"})
        self.assertEqual(
            self.names("fn f<'a>(x: &'a str) { if cmd == \"after-lifetime\" {} }"),
            {"after-lifetime"},
        )

    def test_consts_resolve_locally_or_from_one_other_module(self) -> None:
        self.assertEqual(
            self.names("fn f() { if cmd == super::NAME {} }", {"NAME": {"imported"}}),
            {"imported"},
        )
        with self.assertRaisesRegex(SNIFFERS.SnifferNameError, "cannot resolve super::NAME"):
            self.names("fn f() { if cmd == super::NAME {} }")
        with self.assertRaisesRegex(SNIFFERS.SnifferNameError, "cannot resolve OTHER"):
            self.names("fn f() { match cmd { OTHER => 1, _ => 0 } }", {"OTHER": {"x", "y"}})
        served = self.served(
            {
                "parent.rs": (
                    'pub(super) const PLAN: &str = "child-plan";\n'
                    'fn try_handle() { if cmd == "parent-own" {} }\n'
                ),
                "parent/child.rs": "fn try_handle() { if cmd == super::PLAN {} }\n",
            },
        )
        self.assertEqual(served["child-plan"].module, "parent/child.rs")

    def test_tagged_enum_variants_and_submodules_are_served_names(self) -> None:
        served = self.served(
            {
                "apps.rs": self.apps_rs(""),
                "transfer/requests.rs": 'fn try_handle() { if cmd == "access-request" {} }\n',
            }
        )
        self.assertEqual(served["apps-list"].module, "apps.rs")
        self.assertEqual(served["cancel-request"].module, "apps.rs")
        self.assertEqual(served["access-request"].module, "transfer/requests.rs")

    def test_a_name_two_modules_serve_is_rejected(self) -> None:
        handler = 'fn try_handle() { if cmd == "same" {} }\n'
        with self.assertRaisesRegex(SNIFFERS.SnifferNameError, "served by both"):
            self.served({"a.rs": handler, "b.rs": handler})

    def test_sniffer_modules_cover_every_intercept(self) -> None:
        hello = (
            'const CLIENT_HELLO: &str = "client-hello";\n'
            "impl HelloGate {\n    fn observe(&mut self) {\n"
            '        match value.get("cmd").and_then(Value::as_str) {\n'
            "            Some(CLIENT_HELLO) => 1,\n            _ => 0,\n        };\n    }\n}\n"
        )
        served = self.served({"client_hello.rs": hello})
        self.assertEqual(served["client-hello"].module, "client_hello.rs")
        with self.assertRaisesRegex(SNIFFERS.SnifferNameError, "has a try_handle; add it"):
            self.served({"new.rs": 'fn try_handle() { if cmd == "n" {} }\n'}, modules=set())
        with self.assertRaisesRegex(SNIFFERS.SnifferNameError, "server/gone.rs, which is gone"):
            self.served({"a.rs": 'fn x() { cmd == "a"; }\n'}, modules={"a.rs", "gone.rs"})

    def test_a_sniffer_module_with_no_name_fails_unless_nameless(self) -> None:
        router = "fn try_handle() { let route = table::routed(&envelope.operation)?; }\n"
        with self.assertRaisesRegex(SNIFFERS.SnifferNameError, "serves no name the scan can read"):
            self.served({"router.rs": router})
        self.assertEqual(self.served({"router.rs": router}, nameless={"router.rs": "fixture"}), {})
        handler = 'fn try_handle() { cmd == "a"; }\n'
        with self.assertRaisesRegex(SNIFFERS.SnifferNameError, "drop it from NAMELESS_SNIFFERS"):
            self.served({"a.rs": handler}, nameless={"a.rs": "fixture"})
        with self.assertRaisesRegex(SNIFFERS.SnifferNameError, "not a sniffer module"):
            self.served({"a.rs": handler}, nameless={"b.rs": "fixture"})
        # A module that moved off try_handle and lost its readable names.
        moved = "fn route() { if COMMANDS.contains(&cmd) {} }\n"
        with self.assertRaisesRegex(SNIFFERS.SnifferNameError, "server/moved.rs serves no name"):
            self.served({"moved.rs": moved})

    def test_the_module_table_names_are_the_scanned_names(self) -> None:
        table = "scripts/server-module-commands.json"
        files = {"apps.rs": self.apps_rs(""), table: self.APPS_TABLE}
        self.assertEqual(set(self.served(files)), {"apps-list", "cancel-request"})
        hidden = dict(
            files,
            **{"apps.rs": files["apps.rs"].replace('cmd == "cancel-request"', "COMMANDS.contains(&cmd)")},
        )
        with self.assertRaisesRegex(
            SNIFFERS.SnifferNameError, "lists cancel-request for server/apps.rs, which the scan"
        ):
            self.served(hidden)
        extra = dict(
            files,
            **{
                "apps.rs": files["apps.rs"].replace(
                    'cmd == "cancel-request"', 'cmd == "cancel-request" || cmd == "identify"'
                )
            },
        )
        with self.assertRaisesRegex(
            SNIFFERS.SnifferNameError, f"serves identify, which {table} does not list"
        ):
            self.served(extra)
        self.assertIn("identify", self.served(extra, passed_on={"identify"}))
        with self.assertRaisesRegex(SNIFFERS.SnifferNameError, "add it to SNIFFER_MODULES"):
            self.served(files, modules=set())

    def test_unschemad_apps_variant_fails(self) -> None:
        extra = '    #[serde(rename = "apps-unschemad")]\n    Unschemad,\n'
        served = self.served({"apps.rs": self.apps_rs(extra)})
        with self.assertRaisesRegex(
            CHECKER.SdkSchemaError, r"not in sdk-schema\.json: apps-unschemad \(server/apps\.rs\)"
        ):
            CHECKER.validate_sniffed_coverage(self.ir, served)
        served.pop("apps-unschemad")
        with patch.object(CHECKER, "UNSCHEMAD_SNIFFED_COMMANDS", {}):
            CHECKER.validate_sniffed_coverage(self.ir, served)

    def test_unschemad_literal_name_fails(self) -> None:
        served = self.served({"x.rs": 'fn try_handle() { if cmd == "x-unschemad" {} }\n'})
        with patch.object(CHECKER, "UNSCHEMAD_SNIFFED_COMMANDS", {}):
            with self.assertRaisesRegex(CHECKER.SdkSchemaError, "x-unschemad \\(server/x\\.rs\\)"):
                CHECKER.validate_sniffed_coverage(self.ir, served)
        with patch.object(CHECKER, "UNSCHEMAD_SNIFFED_COMMANDS", {"x-unschemad": "fixture"}):
            CHECKER.validate_sniffed_coverage(self.ir, served)

    def test_stale_unschemad_entries_are_notes_not_failures(self) -> None:
        served = self.served({"apps.rs": self.apps_rs("")})
        stale = {"apps-list": "fixture", "gone-command": "fixture"}
        with patch.object(CHECKER, "UNSCHEMAD_SNIFFED_COMMANDS", stale):
            with contextlib.redirect_stderr(io.StringIO()) as stderr:
                notes = CHECKER.validate_sniffed_coverage(self.ir, served)
        self.assertEqual(
            notes,
            [
                "in sdk-schema.json now, drop from UNSCHEMAD_SNIFFED_COMMANDS: apps-list",
                "no sniffer module serves these, drop from UNSCHEMAD_SNIFFED_COMMANDS: "
                "gone-command",
            ],
        )
        self.assertIn("SDK schema note: in sdk-schema.json now", stderr.getvalue())

    def test_name_list_module_serves_the_listed_names(self) -> None:
        lists = {"fs_wire.rs": ("../fs_ops.rs", "FS_COMMANDS")}
        served = self.served(
            {
                "fs_wire.rs": "fn try_handle() { frame_command(message)?; }\n",
                "../fs_ops.rs": 'pub const FS_COMMANDS: [&str; 2] = ["fs.stat", "fs.list"];\n',
            },
            name_lists=lists,
        )
        self.assertEqual(set(served), {"fs.stat", "fs.list"})
        with self.assertRaisesRegex(SNIFFERS.SnifferNameError, "is in NAME_LISTS; add it"):
            self.served(
                {
                    "fs_wire.rs": "fn other() {}\n",
                    "../fs_ops.rs": 'pub const FS_COMMANDS: [&str; 1] = ["fs.stat"];\n',
                },
                modules=set(),
                name_lists=lists,
            )

    def test_live_tree_sniffers_are_all_accounted_for(self) -> None:
        served = CHECKER.sniffed_commands()
        for name, module in {
            "apps-set": "apps.rs",
            "cancel-request": "apps.rs",
            "script-run": "scripts.rs",
            "agent-inventory-refresh": "agent_inventory.rs",
            "agent-update-plan": "agent_transfer/agent_update.rs",
            "access-request": "agent_transfer/access_requests.rs",
            "machine-catalog-publish": "connection_frame/machine_catalog.rs",
            "client-hello": "client_hello.rs",
            "fs.read": "fs_wire.rs",
        }.items():
            self.assertEqual(served[name].module, module)
        # Stale entries are notes, so a schema task may land first.
        with contextlib.redirect_stderr(io.StringIO()):
            CHECKER.validate_sniffed_coverage(self.ir, served)


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
        schema_type = self.ir.command("clear-history")["request"]["fields"][
            "fallback_key"
        ]["type"]
        self.assertEqual(
            CHECKER._runtime_type_shape("Option<ProtocolKeyInput>"),
            "ref<TerminalKeyInput>",
        )
        self.assertEqual(
            CHECKER._schema_type_shape(schema_type, self.ir.types),
            "ref<TerminalKeyInput>",
        )

    def test_generated_family_commands_are_served_without_hand_written_fields(self) -> None:
        # terminal-io's Command variants come from the schema
        # (crates/cmux-ipc/server-families.json), so server.rs has none.
        generated = CHECKER.generated_command_names()
        self.assertIn("clear-history", generated)
        self.assertIn("send", generated)
        self.assertFalse(generated & set(CHECKER.runtime_command_fields()))
        document = copy.deepcopy(self.document)
        document["commands"]["send"]["request"]["fields"]["paste"]["presence"] = "required"
        self.validate(document, self.inventory)

    def test_tabs_family_commands_are_generated_not_written(self) -> None:
        # Tabs joined terminal-io in server-families.json, so its
        # Command variants (the boxed create-surface-with-receipt and
        # move-tab-to-column with its refused `sticky`) are no longer read
        # from server.rs, and a schema change to them is not drift.
        generated = CHECKER.generated_command_names()
        runtime = set(CHECKER.runtime_command_fields())
        for name in ("create-surface-with-receipt", "new-tab", "move-tab-to-column", "close-tabs"):
            self.assertIn(name, generated)
            self.assertNotIn(name, runtime)
        document = copy.deepcopy(self.document)
        fields = document["commands"]["new-tab"]["request"]["fields"]
        fields["keep"]["presence"] = "required"
        fields["keep"].pop("default")
        self.validate(document, self.inventory)

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
        document["commands"]["resize-surface"]["request"]["fields"].pop("rows")
        with self.assertRaisesRegex(CHECKER.SdkSchemaError, "request field"):
            self.validate(document, self.inventory)

    def test_wrong_request_field_presence_is_rejected(self) -> None:
        document = copy.deepcopy(self.document)
        document["commands"]["resize-surface"]["request"]["fields"]["rows"]["presence"] = "optional"
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

    def test_q5_module_commands_use_their_request_structs(self) -> None:
        fields = CHECKER.runtime_command_fields()
        # browser_runtime and loopback_forward are found by their tagged enum.
        fields.update(CHECKER.handler_command_fields(set(self.document["commands"])))
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
        table = {
            "connection_frame/machine_catalog": {
                "literals": {
                    "machine-catalog-publish": {
                        "request": ["client_registry/machine_catalog.rs::Nope"],
                        "handler": "handle",
                    }
                },
                "authority": "local-admin",
            }
        }
        with patch.object(CHECKER, "module_commands", lambda: table):
            with self.assertRaisesRegex(CHECKER.SdkSchemaError, "cannot find Rust struct Nope"):
                CHECKER.module_command_fields()

    def test_module_literal_raw_members_need_a_type_and_presence(self) -> None:
        def table(fields: dict[str, object]) -> dict[str, object]:
            return {
                "connection_frame/machine_catalog": {
                    "literals": {
                        "machine-catalog-publish": {
                            "request": ["client_registry/machine_catalog.rs::Publication"],
                            "fields": fields,
                            "handler": "handle",
                        }
                    },
                    "authority": "local-admin",
                }
            }

        owner = {"expected_machine_id": {"type": "String", "presence": "required"}}
        with patch.object(CHECKER, "module_commands", lambda: table(owner)):
            fields = CHECKER.module_command_fields()["machine-catalog-publish"]
        self.assertEqual(
            CHECKER._runtime_field_presence(fields["expected_machine_id"]), ("required", False)
        )
        for bad, message in [
            ({"expected_machine_id": {"type": "String"}}, "needs a Rust type and a presence"),
            ({"sequence": {"type": "u64", "presence": "required"}}, "request field 'sequence' twice"),
        ]:
            with (
                self.subTest(bad=bad),
                patch.object(CHECKER, "module_commands", lambda: table(bad)),
                self.assertRaisesRegex(CHECKER.SdkSchemaError, message),
            ):
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

    def test_sniffed_modules_of_p05_ipc_019_are_schemad(self) -> None:
        """agent_transfer (with access_requests and agent_update), fs_wire and
        scripts decode every command they serve through a typed enum, and
        each one is in the schema."""

        decoded = HANDLERS.handler_commands(CHECKER.TUI)
        modules = {"agent_transfer.rs", "access_requests.rs", "agent_update.rs", "fs_wire.rs", "scripts.rs"}
        served = {name for name, command in decoded.items() if command.module.name in modules}
        self.assertEqual(len(served), 26)
        self.assertEqual(served - set(self.ir.commands), set())
        commands = CHECKER.handler_command_fields(served)
        self.assertEqual(set(commands["fs.read"]), {"path", "offset", "max_bytes"})
        self.assertEqual(set(commands["agent-update-plan"]), {"expected_machine_id"})
        self.assertEqual(set(commands["access-request-list"]), set())
        self.assertEqual(
            set(commands["agent-transfer-read"]), {"transfer_id", "path", "offset", "limit"}
        )

    def test_missing_fs_request_field_is_rejected(self) -> None:
        document = copy.deepcopy(self.document)
        document["commands"]["fs.read"]["request"]["fields"].pop("max_bytes")
        with self.assertRaisesRegex(CHECKER.SdkSchemaError, "request field for fs.read"):
            self.validate(document, self.inventory)

    def test_fs_sort_struct_drift_is_rejected(self) -> None:
        document = copy.deepcopy(self.document)
        document["types"]["FsSort"]["fields"].pop("dirs_first")
        with self.assertRaisesRegex(CHECKER.SdkSchemaError, "request field for FsSort"):
            self.validate(document, self.inventory)

    def test_a_non_null_owner_condition_must_not_be_nullable(self) -> None:
        document = copy.deepcopy(self.document)
        document["commands"]["agent-update-apply"]["request"]["fields"]["expected_machine_id"][
            "nullable"
        ] = True
        with self.assertRaisesRegex(CHECKER.SdkSchemaError, "presence drift"):
            self.validate(document, self.inventory)

    def test_wrong_event_stream_is_rejected(self) -> None:
        document = copy.deepcopy(self.document)
        document["events"]["bell"]["streams"] = ["attach-byte"]
        with self.assertRaisesRegex(CHECKER.SdkSchemaError, "event stream drift"):
            self.validate(document, self.inventory)

    def test_agent_inventory_requests_come_from_the_enums_their_handlers_decode(self) -> None:
        commands = CHECKER.handler_command_fields(
            {"agent-inventory", "agent-inventory-refresh", "agent-inventory-watch"}
        )
        presence = {
            name: {field: CHECKER._runtime_field_presence(value) for field, value in fields.items()}
            for name, fields in commands.items()
        }
        self.assertEqual(
            presence,
            {
                "agent-inventory": {"expected_machine_id": ("optional", False)},
                "agent-inventory-refresh": {"expected_machine_id": ("required", False)},
                "agent-inventory-watch": {
                    "expected_machine_id": ("required", False),
                    "enabled": ("required", False),
                    "expected_watch_id": ("optional", False),
                    "admission_receipt": ("optional", False),
                },
            },
        )

    def test_agent_inventory_watch_field_type_drift_is_rejected(self) -> None:
        document = copy.deepcopy(self.document)
        document["commands"]["agent-inventory-watch"]["request"]["fields"]["enabled"]["type"] = {
            "kind": "scalar",
            "name": "string",
        }
        with self.assertRaisesRegex(CHECKER.SdkSchemaError, "type drift"):
            self.validate(document, self.inventory)

    def test_agent_inventory_watch_fence_presence_drift_is_rejected(self) -> None:
        document = copy.deepcopy(self.document)
        fields = document["commands"]["agent-inventory-watch"]["request"]["fields"]
        fields["expected_machine_id"]["presence"] = "optional"
        with self.assertRaisesRegex(CHECKER.SdkSchemaError, "presence drift"):
            self.validate(document, self.inventory)

    def test_present_non_null_option_is_optional_and_not_nullable(self) -> None:
        refusing = CHECKER.RuntimeField(
            "Option<String>", ('default, deserialize_with = "present_non_null"',)
        )
        self.assertEqual(CHECKER._runtime_field_presence(refusing), ("optional", False))
        document = copy.deepcopy(self.document)
        document["commands"]["agent-inventory"]["request"]["fields"]["expected_machine_id"][
            "nullable"
        ] = True
        with self.assertRaisesRegex(CHECKER.SdkSchemaError, "presence drift"):
            self.validate(document, self.inventory)


if __name__ == "__main__":
    unittest.main()
