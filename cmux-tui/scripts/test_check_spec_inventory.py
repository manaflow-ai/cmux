#!/usr/bin/env python3
"""Regression tests for the cmux-tui specification inventory checker."""

from __future__ import annotations

import copy
import importlib.util
import io
import json
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path


SCRIPT = Path(__file__).with_name("check-spec-inventory.py")
SPEC = importlib.util.spec_from_file_location("check_spec_inventory", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot load {SCRIPT}")
CHECKER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECKER)


class RustEnumVariantTests(unittest.TestCase):
    def test_command_names_include_bare_final_variant(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            tui = Path(directory)
            server = tui / "crates/cmux-tui-core/src/server.rs"
            server.parent.mkdir(parents=True)
            server.write_text(
                """\
enum Command {
    Ping,
    TupleValue(u8),
    StructValue { value: u8 },
    BareFinal
}
"""
            )

            original_tui = CHECKER.TUI
            CHECKER.TUI = tui
            try:
                self.assertEqual(
                    CHECKER.command_names(),
                    {"ping", "tuple-value", "struct-value", "bare-final"},
                )
            finally:
                CHECKER.TUI = original_tui


class RuntimeMetadataTests(unittest.TestCase):
    def test_command_profiles_come_from_rust_dispatch_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            tui = Path(directory)
            server = tui / "crates/cmux-tui-core/src/server.rs"
            server.parent.mkdir(parents=True)
            server.write_text(
                """\
enum Command {
    Ping,
    ShutdownDaemon { pid: u32 },
}

impl Command {
    fn profile(&self) -> CommandProfile {
        match self {
            Command::Ping => CommandProfile::Control,
            Command::ShutdownDaemon { .. } => CommandProfile::LocalAdmin,
        }
    }
}
"""
            )

            original_tui = CHECKER.TUI
            CHECKER.TUI = tui
            try:
                self.assertEqual(
                    CHECKER.command_profiles(),
                    {
                        "control": {"ping"},
                        "local-admin": {"shutdown-daemon"},
                    },
                )
            finally:
                CHECKER.TUI = original_tui

    def test_event_streams_come_from_rust_writer_catalog(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            tui = Path(directory)
            server = tui / "crates/cmux-tui-core/src/server.rs"
            server.parent.mkdir(parents=True)
            server.write_text(
                """\
const PUBLIC_EVENT_CATALOG: &[PublicEvent] = &[
    PublicEvent::new("bell", &[PublicEventStream::Subscribe]),
    PublicEvent::new(
        "notification",
        &[
            PublicEventStream::Subscribe,
            PublicEventStream::AttachByte,
        ],
    ),
];
"""
            )

            original_tui = CHECKER.TUI
            CHECKER.TUI = tui
            try:
                self.assertEqual(
                    CHECKER.event_streams(),
                    {
                        "bell": {"subscribe"},
                        "notification": {"subscribe", "attach-byte"},
                    },
                )
            finally:
                CHECKER.TUI = original_tui

    def test_action_contracts_come_from_rust_execution_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            tui = Path(directory)
            config = tui / "crates/cmux-tui/src/config.rs"
            config.parent.mkdir(parents=True)
            config.write_text(
                """\
enum Action {
    NewTab,
    SelectTab(u8),
}

impl Action {
    fn metadata(&self) -> ActionMetadata {
        match self {
            Action::NewTab => ActionMetadata::new(
                "new-tab",
                ActionClassification::Direct,
                "new-tab",
                ActionExecution::NewTab,
            ),
            Action::SelectTab(number) => ActionMetadata::new(
                "select-tab-{number}",
                ActionClassification::Direct,
                "select-tab index",
                ActionExecution::SelectTab(*number),
            ),
        }
    }
}
"""
            )

            original_tui = CHECKER.TUI
            CHECKER.TUI = tui
            try:
                self.assertEqual(
                    CHECKER.action_metadata(),
                    {
                        "NewTab": {
                            "key": "new-tab",
                            "classification": "direct",
                            "route": "new-tab",
                        },
                        "SelectTab": {
                            "key": "select-tab-{number}",
                            "classification": "direct",
                            "route": "select-tab index",
                        },
                    },
                )
            finally:
                CHECKER.TUI = original_tui

    def test_menu_action_contracts_come_from_rust_execution_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            tui = Path(directory)
            app = tui / "crates/cmux-tui/src/app.rs"
            app.parent.mkdir(parents=True)
            app.write_text(
                """\
enum MenuAction {
    RenameTab(u8),
    DisconnectClient(u64),
}

impl MenuAction {
    fn metadata(&self) -> MenuActionMetadata {
        match self {
            MenuAction::RenameTab(id) => MenuActionMetadata::new(
                MenuActionClassification::Composite,
                "frontend prompt + rename-surface",
                MenuActionExecution::RenameTab(*id),
            ),
            MenuAction::DisconnectClient(client) => MenuActionMetadata::new(
                MenuActionClassification::Composite,
                "self: close frontend transport; peer: detach-client",
                MenuActionExecution::DisconnectClient(*client),
            ),
        }
    }
}
"""
            )

            original_tui = CHECKER.TUI
            CHECKER.TUI = tui
            try:
                self.assertEqual(
                    CHECKER.menu_action_metadata(),
                    {
                        "RenameTab": {
                            "classification": "composite",
                            "route": "frontend prompt + rename-surface",
                        },
                        "DisconnectClient": {
                            "classification": "composite",
                            "route": "self: close frontend transport; peer: detach-client",
                        },
                    },
                )
            finally:
                CHECKER.TUI = original_tui


class DocumentationConsistencyTests(unittest.TestCase):
    def test_python_browser_attach_uses_the_protocol_six_floor(self) -> None:
        style = (CHECKER.TUI / "bindings/styles/python.md").read_text()
        self.assertIn("browser attach streams from protocol 6", style)
        self.assertNotIn("browser attach streams from protocol 9", style)

    def test_subscribe_belongs_to_the_frontend_profile(self) -> None:
        spec = (CHECKER.SPEC / "programmability.md").read_text()
        control_row = next(
            line for line in spec.splitlines() if line.startswith("| `control` |")
        )
        frontend_row = next(
            line for line in spec.splitlines() if line.startswith("| `frontend` |")
        )
        self.assertNotIn("subscriptions", control_row)
        self.assertIn("subscriptions", frontend_row)


class SchemaValidationTests(unittest.TestCase):
    SCHEMA = {
        "type": "object",
        "required": ["names"],
        "properties": {
            "names": {
                "type": "array",
                "minItems": 1,
                "uniqueItems": True,
                "items": {
                    "type": "string",
                    "minLength": 2,
                    "pattern": "^[a-z]+$",
                },
            }
        },
        "additionalProperties": False,
    }

    def test_nested_schema_subset_accepts_valid_values(self) -> None:
        CHECKER.validate_schema({"names": ["alpha", "beta"]}, self.SCHEMA)

    def test_nested_schema_subset_preserves_error_path(self) -> None:
        errors = io.StringIO()
        with redirect_stderr(errors), self.assertRaises(SystemExit):
            CHECKER.validate_schema({"names": ["alpha", "AA"]}, self.SCHEMA)
        self.assertIn("$.names[1] does not match", errors.getvalue())

    def test_nested_schema_subset_rejects_unknown_properties(self) -> None:
        errors = io.StringIO()
        with redirect_stderr(errors), self.assertRaises(SystemExit):
            CHECKER.validate_schema({"names": ["alpha"], "extra": True}, self.SCHEMA)
        self.assertIn("$ has unknown property 'extra'", errors.getvalue())


class InventoryContractTests(unittest.TestCase):
    def inventory(self) -> dict:
        return json.loads((CHECKER.SPEC / "inventory.json").read_text())

    def test_command_profile_drift_is_rejected(self) -> None:
        inventory = copy.deepcopy(self.inventory())
        inventory["commands"]["local-admin"].remove("shutdown-daemon")
        inventory["commands"]["control"].append("shutdown-daemon")
        errors = io.StringIO()
        with redirect_stderr(errors), self.assertRaises(SystemExit):
            CHECKER.validate_commands(inventory)
        self.assertIn("command profile", errors.getvalue())

    def test_event_stream_drift_is_rejected(self) -> None:
        inventory = copy.deepcopy(self.inventory())
        bell = next(event for event in inventory["events"] if event["name"] == "bell")
        bell["streams"] = ["attach-byte"]
        errors = io.StringIO()
        with redirect_stderr(errors), self.assertRaises(SystemExit):
            CHECKER.validate_events(inventory)
        self.assertIn("event stream", errors.getvalue())

    def test_event_discovery_scans_early_production_serializers(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            tui = Path(directory)
            server = tui / "crates/cmux-tui-core/src/server.rs"
            mux = tui / "crates/cmux-tui-core/src/mux.rs"
            server.parent.mkdir(parents=True)
            server.write_text(
                """\
fn early_serializer() {
    let _ = json!({"event": "early-event"});
}

fn tree_delta_json() {
    let _ = json!({"event": "tree-changed"});
}
"""
            )
            mux.write_text(
                """\
impl TreeDeltaKind {
    fn wire_name(&self) -> &str {
        "workspace-added"
    }
}
"""
            )

            original_tui = CHECKER.TUI
            CHECKER.TUI = tui
            try:
                self.assertIn("early-event", CHECKER.event_names())
            finally:
                CHECKER.TUI = original_tui

    def test_event_discovery_ignores_event_shaped_comments(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            tui = Path(directory)
            server = tui / "crates/cmux-tui-core/src/server.rs"
            mux = tui / "crates/cmux-tui-core/src/mux.rs"
            server.parent.mkdir(parents=True)
            server.write_text(
                """\
//! This is documentation, not a serializer: json!({"event": "comment-only"})
/* Nested comments are also not serializers:
   /* json!({"event": "nested-comment-only"}) */
*/
fn tree_delta_json() {
    let _ = json!({"event": "tree-changed"});
}
"""
            )
            mux.write_text(
                """\
impl TreeDeltaKind {
    fn wire_name(&self) -> &str {
        "workspace-added"
    }
}
"""
            )

            original_tui = CHECKER.TUI
            CHECKER.TUI = tui
            try:
                names = CHECKER.event_names()
                self.assertNotIn("comment-only", names)
                self.assertNotIn("nested-comment-only", names)
            finally:
                CHECKER.TUI = original_tui

    def test_new_workspace_route_covers_provider_owned_sessions(self) -> None:
        actions = {
            action["variant"]: action
            for action in self.inventory()["tui_actions"]
        }
        new_workspace = actions["NewWorkspace"]
        self.assertEqual(new_workspace["classification"], "composite")
        self.assertIn("new-workspace", new_workspace["route"])
        self.assertIn("machine-provider create_workspace", new_workspace["route"])

    def test_menu_action_route_drift_is_rejected(self) -> None:
        inventory = copy.deepcopy(self.inventory())
        disconnect = next(
            action
            for action in inventory["menu_actions"]
            if action["variant"] == "DisconnectClient"
        )
        disconnect["classification"] = "direct"
        disconnect["route"] = "detach-client"
        errors = io.StringIO()
        with redirect_stderr(errors), self.assertRaises(SystemExit):
            CHECKER.validate_menu_actions(inventory)
        self.assertIn("menu action metadata drift", errors.getvalue())


if __name__ == "__main__":
    unittest.main()
