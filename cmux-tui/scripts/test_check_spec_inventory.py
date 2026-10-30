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
from unittest.mock import patch


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

            with patch.object(CHECKER, "TUI", tui):
                self.assertEqual(
                    CHECKER.command_names(),
                    {"ping", "tuple-value", "struct-value", "bare-final"},
                )

    def test_command_names_include_module_commands(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            tui = Path(directory)
            server = tui / "crates/cmux-tui-core/src/server.rs"
            server.parent.mkdir(parents=True)
            server.write_text("enum Command {\n    Ping,\n}\n")
            apps = server.parent / "server/apps.rs"
            apps.parent.mkdir()
            apps.write_text(
                """\
enum Command {
    #[serde(rename = "apps-list")]
    List,
    /// Doc.
    #[serde(rename = "apps-unmount")]
    Unmount { mount_id: String },
}
fn try_handle(cmd: &str) -> bool { cmd == "cancel-request" }
"""
            )
            with patch.object(CHECKER, "TUI", tui):
                self.assertEqual(
                    CHECKER.command_names(),
                    {"ping", "apps-list", "apps-unmount", "cancel-request"},
                )
            apps.write_text(
                "enum Command {\n    List,\n}\nfn f() { \"cancel-request\" }\n"
            )
            errors = io.StringIO()
            with (
                patch.object(CHECKER, "TUI", tui),
                redirect_stderr(errors),
                self.assertRaises(SystemExit),
            ):
                CHECKER.command_names()
            self.assertIn("needs #[serde(rename", errors.getvalue())

    def test_command_names_include_literal_only_modules(self) -> None:
        table = {
            "connection_frame/machine_catalog": {
                "literals": {
                    "machine-catalog-publish": {"handler": "try_handle"}
                },
                "authority": "local-admin",
            }
        }
        with tempfile.TemporaryDirectory() as directory:
            tui = Path(directory)
            server = tui / "crates/cmux-tui-core/src/server.rs"
            server.parent.mkdir(parents=True)
            server.write_text("enum Command {\n    Ping,\n}\n")
            frame = server.parent / "server/connection_frame/machine_catalog.rs"
            frame.parent.mkdir(parents=True)
            frame.write_text(
                "fn try_handle(mux: &Mux, client: u64, m: &str) -> bool {\n"
                "    if !mux.control_clients.is_unix(client) { return false; }\n"
                '    m == "machine-catalog-publish"\n}\n'
            )
            with (
                patch.object(CHECKER, "TUI", tui),
                patch.object(CHECKER, "module_commands", lambda: table),
            ):
                self.assertEqual(CHECKER.command_names(), {"ping", "machine-catalog-publish"})
                self.assertEqual(
                    CHECKER.module_command_profiles(), {"machine-catalog-publish": "local-admin"}
                )
            frame.write_text("fn try_handle(m: &str) -> bool { false }\n")
            errors = io.StringIO()
            with (
                patch.object(CHECKER, "TUI", tui),
                patch.object(CHECKER, "module_commands", lambda: table),
                redirect_stderr(errors),
                self.assertRaises(SystemExit),
            ):
                CHECKER.command_names()
            self.assertIn("no longer matches 'machine-catalog-publish'", errors.getvalue())

    def test_hello_gate_transport_check_is_a_non_unix_refusal(self) -> None:
        source = (
            CHECKER.TUI / "crates/cmux-tui-core/src/server/client_hello.rs"
        ).read_text()
        body = CHECKER.rust_function_body(CHECKER.strip_rust_comments(source), "observe")
        self.assertRegex(body, CHECKER.NON_UNIX_REFUSAL)
        self.assertNotRegex("_ if matches!(self.transport, ClientTransport::Unix)", CHECKER.NON_UNIX_REFUSAL)

    def test_module_local_admin_needs_the_guard_in_every_handler(self) -> None:
        guarded = """\
enum Command {
    #[serde(rename = "apps-list")]
    List,
}
fn cancel_request(mux: &Mux, client: u64) -> bool {
    if !mux.control_clients.is_unix(client) { return false; }
    true
}
fn handle(mux: &Mux, client: u64, cmd: &str) -> Option<bool> {
    if cmd == "cancel-request" { return Some(cancel_request(mux, client)); }
    if !mux.control_clients.is_unix(client) { return Some(false); }
    Some(true)
}
"""
        # A Unix guard in a helper does not cover the unguarded literal handler.
        unguarded = """\
enum Command {
    #[serde(rename = "apps-list")]
    List,
}
fn helper(mux: &Mux, client: u64) -> bool { if !mux.control_clients.is_unix(client) { return false; } true }
fn cancel_request(mux: &Mux, client: u64) -> bool { true }
fn handle(mux: &Mux, client: u64, cmd: &str) -> Option<bool> {
    if cmd == "cancel-request" { return Some(cancel_request(mux, client)); }
    if !mux.control_clients.is_unix(client) { return Some(false); }
    Some(true)
}
"""
        with tempfile.TemporaryDirectory() as directory:
            tui = Path(directory)
            apps = tui / "crates/cmux-tui-core/src/server/apps.rs"
            apps.parent.mkdir(parents=True)
            apps.write_text(guarded)
            with patch.object(CHECKER, "TUI", tui):
                self.assertEqual(
                    CHECKER.module_command_profiles(),
                    {"apps-list": "local-admin", "cancel-request": "local-admin"},
                )
            apps.write_text(unguarded)
            errors = io.StringIO()
            with (
                patch.object(CHECKER, "TUI", tui),
                redirect_stderr(errors),
                self.assertRaises(SystemExit),
            ):
                CHECKER.module_command_profiles()
            self.assertIn("cancel_request does not refuse non-Unix connections", errors.getvalue())

    def test_literal_only_module_needs_its_guard_and_a_production_literal(self) -> None:
        guarded = """\
fn handle(mux: &Mux, client: u64, cmd: &str) -> Option<bool> {
    if cmd != "agent-session-observe" { return None; }
    if !mux.control_clients.is_unix(client) { return Some(false); }
    Some(true)
}
"""
        unguarded = guarded.replace("    if !mux.control_clients.is_unix(client) { return Some(false); }\n", "")
        test_only = """\
fn handle(mux: &Mux, client: u64, cmd: &str) -> Option<bool> {
    if !mux.control_clients.is_unix(client) { return Some(false); }
    None
}

#[cfg(test)]
mod tests {
    const CMD: &str = "agent-session-observe";
}
"""
        with tempfile.TemporaryDirectory() as directory:
            tui = Path(directory)
            observe = tui / "crates/cmux-tui-core/src/server/agent_session_observe.rs"
            observe.parent.mkdir(parents=True)
            observe.write_text(guarded)
            with patch.object(CHECKER, "TUI", tui):
                self.assertEqual(
                    CHECKER.module_command_profiles(),
                    {"agent-session-observe": "local-admin"},
                )
            for source, message in (
                (unguarded, "handle does not refuse non-Unix connections"),
                (test_only, "no longer matches 'agent-session-observe'"),
            ):
                observe.write_text(source)
                errors = io.StringIO()
                with (
                    patch.object(CHECKER, "TUI", tui),
                    redirect_stderr(errors),
                    self.assertRaises(SystemExit),
                ):
                    CHECKER.module_command_profiles()
                self.assertIn(message, errors.getvalue())

    def test_sniffed_command_names_come_from_handler_modules_only(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            tui = Path(temporary) / "cmux-tui"
            server = tui / "crates/cmux-tui-core/src/server"
            server.mkdir(parents=True)
            tagged = (
                '#[derive(Deserialize)]\n#[serde(tag = "cmd")]\nenum Command {{\n'
                '    #[serde(rename = "{0}")]\n    Served,\n}}\n'
            )
            (server / "handler.rs").write_text(
                tagged.format("served-cmd")
                + "pub(super) fn try_handle() {\n"
                '    let _ = "literal-cmd";\n'
                "}\n"
                "#[cfg(test)]\nmod tests {\n" + tagged.format("test-cmd") + "}\n"
            )
            (server / "helper.rs").write_text(tagged.format("helper-cmd"))
            (server / "handler_tests.rs").write_text(
                tagged.format("tests-file-cmd") + "fn try_handle() {}\n"
            )

            with patch.object(CHECKER, "TUI", tui):
                self.assertEqual(
                    CHECKER.sniffed_command_names(
                        {"served-cmd", "literal-cmd", "test-cmd", "helper-cmd", "tests-file-cmd"}
                    ),
                    {"served-cmd"},
                )

    def test_rust_function_body_ignores_braces_in_string_literals(self) -> None:
        source = r'''
fn metadata(&self) -> ActionMetadata {
    let closing = "}";
    let opening = r#"{"#;
    ActionMetadata::new("new-tab", ActionExecution::NewTab)
}

fn following() {}
'''
        body = CHECKER.rust_function_body(source, "metadata")
        self.assertIn("ActionMetadata::new", body)
        self.assertNotIn("fn following", body)

    def test_action_variants_ignore_commented_out_entries(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            tui = Path(directory)
            config = tui / "crates/cmux-tui/src/config.rs"
            config.parent.mkdir(parents=True)
            config.write_text(
                """\
enum Action {
    NewTab,
    /*
    CommentedOut,
    */
    BareFinal
}
"""
            )

            with patch.object(CHECKER, "TUI", tui):
                self.assertEqual(CHECKER.action_variants(), {"NewTab", "BareFinal"})

    def test_secondary_protocols_include_bare_final_and_tuple_variants(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            tui = Path(directory)
            host = tui / "crates/cmux-tui-core/src/terminal_host_protocol.rs"
            provider = tui / "crates/cmux-tui-machine-protocol/src/lib.rs"
            agent = tui / "crates/cmux-tui-machine-agent-protocol/src/lib.rs"
            management = tui / "crates/cmux-tui-core/src/provider_management.rs"
            host.parent.mkdir(parents=True)
            provider.parent.mkdir(parents=True)
            agent.parent.mkdir(parents=True)
            host.write_text(
                """\
enum MessageKind {
    Hello = 1,
    BareFinal = 2
}
"""
            )
            provider.write_text(
                """\
enum ProviderRequest {
    TupleRequest(u8),
    BareRequest
}

enum ProviderEvent {
    StructEvent { value: u8 },
    BareEvent
}
"""
            )
            agent.write_text(
                """\
enum Message {
    TupleMessage(u8),
    BareMessage
}
"""
            )
            management.write_text(
                """\
enum Request {
    TupleOperation(u8),
    BareOperation
}
"""
            )

            with patch.object(CHECKER, "TUI", tui):
                self.assertEqual(
                    CHECKER.secondary_protocols(),
                    {
                        "terminal_host_v1": {"Hello": 1, "BareFinal": 2},
                        "machine_provider_v1_requests": {
                            "tuple_request",
                            "bare_request",
                        },
                        "machine_provider_v1_events": {
                            "struct_event",
                            "bare_event",
                        },
                        "machine_agent_v1": {
                            "tuple_message",
                            "bare_message",
                        },
                        "provider_management_v1": {
                            "tuple_operation",
                            "bare_operation",
                        },
                    },
                )


class RuntimeMetadataTests(unittest.TestCase):
    def test_command_profiles_combine_sdk_metadata_and_rust_guards(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            tui = Path(directory)
            spec = tui / "spec"
            server = tui / "crates/cmux-tui-core/src/server.rs"
            server.parent.mkdir(parents=True)
            spec.mkdir()
            server.write_text(
                """\
enum Command {
    Ping,
    ShutdownDaemon { pid: u32 },
}
"""
            )
            # The router lives in server/command_dispatch.rs.
            (server.parent / "server").mkdir()
            (server.parent / "server/command_dispatch.rs").write_text(
                """\
fn handle_command_with_cancellation(cmd: Command) {
    match cmd {
        Command::Ping => {}
        Command::ShutdownDaemon { .. } => {
            mux.begin_daemon_handoff(client)?;
        }
    }
}
"""
            )
            (spec / "sdk-schema.json").write_text(
                json.dumps(
                    {
                        "commands": {
                            "ping": {"authority": "control"},
                            "shutdown-daemon": {"authority": "local-admin"},
                        }
                    }
                )
            )

            with (
                patch.object(CHECKER, "TUI", tui),
                patch.object(CHECKER, "SPEC", spec),
            ):
                self.assertEqual(
                    CHECKER.command_profiles(),
                    {
                        "control": {"ping"},
                        "local-admin": {"shutdown-daemon"},
                    },
                )

    def test_command_profile_guard_drift_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            tui = Path(directory)
            spec = tui / "spec"
            server = tui / "crates/cmux-tui-core/src/server.rs"
            server.parent.mkdir(parents=True)
            spec.mkdir()
            server.write_text(
                """\
enum Command {
    ShutdownDaemon { pid: u32 },
}
"""
            )
            # The router lives in server/command_dispatch.rs.
            (server.parent / "server").mkdir()
            (server.parent / "server/command_dispatch.rs").write_text(
                """\
fn handle_command_with_cancellation(cmd: Command) {
    match cmd {
        Command::ShutdownDaemon { .. } => {
            mux.begin_daemon_handoff(client)?;
        }
    }
}
"""
            )
            (spec / "sdk-schema.json").write_text(
                json.dumps(
                    {
                        "commands": {
                            "shutdown-daemon": {"authority": "control"},
                        }
                    }
                )
            )

            errors = io.StringIO()
            with (
                patch.object(CHECKER, "TUI", tui),
                patch.object(CHECKER, "SPEC", spec),
                redirect_stderr(errors),
                self.assertRaises(SystemExit),
            ):
                CHECKER.command_profiles()
            self.assertIn("command profile guard drift", errors.getvalue())

    def test_event_streams_combine_sdk_metadata_and_rust_serializers(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            tui = Path(directory)
            spec = tui / "spec"
            server = tui / "crates/cmux-tui-core/src/server.rs"
            mux = tui / "crates/cmux-tui-core/src/mux.rs"
            server.parent.mkdir(parents=True)
            spec.mkdir()
            server.write_text(
                """\
fn subscribed_event_json() {
    let _ = json!({"event": "bell"});
}

fn attached_event_json() {
    let _ = json!({"event": "notification"});
}

fn tree_delta_json() {}
fn render_state_json() {}
fn browser_state_json() {}
fn complete_daemon_shutdown_after_ack() {
    let _ = json!({"event": "daemon-shutdown"});
}
"""
            )
            mux.write_text(
                """\
impl TreeDeltaKind {
    fn wire_name(&self) -> &str {
        "noop"
    }
}
"""
            )
            (spec / "sdk-schema.json").write_text(
                json.dumps(
                    {
                        "events": {
                            "bell": {"streams": ["subscribe"]},
                            "notification": {
                                "streams": ["subscribe", "attach-byte"]
                            },
                            "daemon-shutdown": {"streams": ["control"]},
                        }
                    }
                )
            )

            with (
                patch.object(CHECKER, "TUI", tui),
                patch.object(CHECKER, "SPEC", spec),
            ):
                self.assertEqual(
                    CHECKER.event_streams(),
                    {
                        "bell": {"subscribe"},
                        "notification": {"subscribe", "attach-byte"},
                        "daemon-shutdown": {"control"},
                    },
                )

    def test_sdk_event_stream_that_contradicts_rust_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            tui = Path(directory)
            spec = tui / "spec"
            server = tui / "crates/cmux-tui-core/src/server.rs"
            mux = tui / "crates/cmux-tui-core/src/mux.rs"
            server.parent.mkdir(parents=True)
            spec.mkdir()
            server.write_text(
                """\
fn subscribed_event_json() {
    let _ = json!({"event": "bell"});
}

fn tree_delta_json() {}
fn render_state_json() {}
fn browser_state_json() {}
"""
            )
            mux.write_text(
                """\
impl TreeDeltaKind {
    fn wire_name(&self) -> &str {
        "noop"
    }
}
"""
            )
            (spec / "sdk-schema.json").write_text(
                json.dumps({"events": {"bell": {"streams": ["attach-byte"]}}})
            )

            errors = io.StringIO()
            with (
                patch.object(CHECKER, "TUI", tui),
                patch.object(CHECKER, "SPEC", spec),
                redirect_stderr(errors),
                self.assertRaises(SystemExit),
            ):
                CHECKER.event_streams()
            self.assertIn("contradicts Rust for bell", errors.getvalue())

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

            with patch.object(CHECKER, "TUI", tui):
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

    def test_action_metadata_dispatch_mismatch_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            tui = Path(directory)
            config = tui / "crates/cmux-tui/src/config.rs"
            config.parent.mkdir(parents=True)
            config.write_text(
                """\
enum Action {
    NewTab,
}

impl Action {
    fn metadata(&self) -> ActionMetadata {
        match self {
            Action::NewTab => ActionMetadata::new(
                "new-tab",
                ActionClassification::Direct,
                "new-tab",
                ActionExecution::CloseTab,
            ),
        }
    }
}
"""
            )

            errors = io.StringIO()
            with (
                patch.object(CHECKER, "TUI", tui),
                redirect_stderr(errors),
                self.assertRaises(SystemExit),
            ):
                CHECKER.action_metadata()
            self.assertIn("action metadata dispatch mismatch", errors.getvalue())

    def test_workspace_ownership_route_comes_from_runtime_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            tui = Path(directory)
            config = tui / "crates/cmux-tui/src/config.rs"
            config.parent.mkdir(parents=True)
            config.write_text(
                """\
enum Action {
    NewWorkspace,
}

impl Action {
    fn metadata(&self) -> ActionMetadata {
        match self {
            Action::NewWorkspace => ActionMetadata::workspace_ownership(
                "new-workspace",
                ActionClassification::Composite,
                WorkspaceOwnershipSource::ActiveWorkspaceSession,
                ActionRouteTarget::MuxCommand("new-workspace"),
                ActionRouteTarget::MachineProviderRequest("create_workspace"),
                UnknownOwnership::Reject,
                ActionExecution::NewWorkspace,
            ),
        }
    }
}
"""
            )

            with patch.object(CHECKER, "TUI", tui):
                self.assertEqual(
                    CHECKER.action_metadata(),
                    {
                        "NewWorkspace": {
                            "key": "new-workspace",
                            "classification": "composite",
                            "route": {
                                "ownership_source": "active-workspace-session",
                                "session_owned": {
                                    "kind": "mux-command",
                                    "operation": "new-workspace",
                                },
                                "provider_owned": {
                                    "kind": "machine-provider-request",
                                    "operation": "create_workspace",
                                },
                                "unknown_ownership": "reject",
                            },
                        },
                    },
                )

    def test_prompt_driven_actions_are_composite_routes(self) -> None:
        actions = CHECKER.action_metadata()
        expected_routes = {
            "NewBrowserTab": "frontend omnibar + new-browser-tab",
            "RenameTab": "frontend prompt + rename-surface",
            "RenameScreen": "frontend prompt + rename-screen",
            "RenameWorkspace": "frontend prompt + rename-workspace",
        }
        for variant, route in expected_routes.items():
            with self.subTest(variant=variant):
                self.assertEqual(actions[variant]["classification"], "composite")
                self.assertEqual(actions[variant]["route"], route)

    def test_menu_action_contracts_follow_keyboard_action_adapter(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            tui = Path(directory)
            app = tui / "crates/cmux-tui/src/app.rs"
            config = tui / "crates/cmux-tui/src/config.rs"
            app.parent.mkdir(parents=True)
            app.write_text(
                """\
enum MenuAction {
    RenameTab(u8),
    DisconnectClient(u64),
    TogglePaneZoom { pane: u8, zoomed: bool },
}

fn keyboard_action_for_menu(action: MenuAction) -> Option<Action> {
    match action {
        MenuAction::RenameTab(_) => Some(Action::RenameTab),
        MenuAction::TogglePaneZoom { .. } => Some(Action::ZoomPane),
        MenuAction::DisconnectClient(_) => None,
    }
}
"""
            )
            config.write_text(
                """\
enum Action {
    RenameTab,
    ZoomPane,
}

impl Action {
    fn metadata(&self) -> ActionMetadata {
        match self {
            Action::RenameTab => ActionMetadata::new(
                "rename-tab",
                ActionClassification::Composite,
                "frontend prompt + rename-surface",
                ActionExecution::RenameTab,
            ),
            Action::ZoomPane => ActionMetadata::new(
                "zoom-pane",
                ActionClassification::Direct,
                "zoom-pane",
                ActionExecution::ZoomPane,
            ),
        }
    }
}
"""
            )

            with patch.object(CHECKER, "TUI", tui):
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
                        "TogglePaneZoom": {
                            "classification": "direct",
                            "route": "zoom-pane explicit mode",
                        },
                    },
                )


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

    def test_private_protocol_domain_ids_match_inventory_version(self) -> None:
        inventory = self.inventory()
        private_domains = {
            domain["id"]
            for domain in inventory["protocol_domains"]
            if domain["spec"] in {"commands.md", "events.md"}
        }
        expected = {
            f"mux-control-v{inventory['mux_protocol']}",
            f"mux-events-v{inventory['mux_protocol']}",
        }
        self.assertEqual(private_domains, expected)

    def test_server_stats_uses_local_admin_profile_at_runtime_and_in_schema(self) -> None:
        inventory = self.inventory()
        self.assertIn("server-stats", inventory["commands"]["local-admin"])
        self.assertNotIn("server-stats", inventory["commands"]["control"])

        schema = json.loads((CHECKER.SPEC / "sdk-schema.json").read_text())
        self.assertEqual(schema["commands"]["server-stats"]["authority"], "local-admin")

        profiles = CHECKER.command_profiles()
        self.assertIn("server-stats", profiles["local-admin"])
        self.assertNotIn("server-stats", profiles["control"])

    def test_merged_terminal_shortcuts_head_is_not_pending(self) -> None:
        inventory = self.inventory()
        pending_urls = {head["url"] for head in inventory["pending_heads"]}
        self.assertNotIn(
            "https://github.com/manaflow-ai/cmux/pull/8698",
            pending_urls,
        )

    def test_programmability_prose_uses_current_protocol_and_no_pending_8698(self) -> None:
        inventory = self.inventory()
        prose = (CHECKER.SPEC / "programmability.md").read_text()
        self.assertIn(
            f"The implemented v{inventory['mux_protocol']} inventory",
            prose,
        )
        pending_8698_lines = [
            line
            for line in prose.splitlines()
            if "8698" in line and "pending" in line
        ]
        self.assertEqual(pending_8698_lines, [])

        # The history section is the human-readable status record for the
        # merged head. Keep the feature names and their implemented status in
        # the contract so a version-only edit cannot silently erase them.
        history = " ".join(prose.split("## Protocol head history", 1)[1].split())
        self.assertIn(
            "clear-history and structured shortcut work is now represented in "
            "the implemented command and action inventory",
            history,
        )

        commands = set(inventory["commands"]["control"])
        self.assertIn("clear-history", commands)
        actions = {action["key"]: action for action in inventory["tui_actions"]}
        self.assertEqual(actions["clear-history"]["variant"], "ClearHistory")
        self.assertEqual(actions["clear-history"]["classification"], "direct")
        self.assertEqual(actions["clear-history"]["route"], "clear-history")
        self.assertEqual(actions["show-shortcuts"]["variant"], "ShowShortcuts")
        self.assertEqual(
            actions["show-shortcuts"]["classification"], "presentation-only"
        )
        self.assertEqual(
            actions["show-shortcuts"]["route"], "frontend shortcut overlay"
        )

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
    let _ = Message { event: "struct-event" };
    write!(writer, "{{\\\"event\\\":\\\"manual-event\\\"}}");
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
        match self {
            Self::WorkspaceAdded => "workspace-added",
        }
    }
}
"""
            )

            with patch.object(CHECKER, "TUI", tui):
                self.assertTrue(
                    {"early-event", "struct-event", "manual-event"}.issubset(
                        CHECKER.event_names()
                    )
                )

    def test_event_discovery_reads_the_conversation_owner_events(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            tui = Path(directory)
            source = tui / "crates/cmux-tui-core/src"
            source.mkdir(parents=True)
            (source / "server.rs").write_text(
                """\
fn tree_delta_json() {
    let _ = json!({"event": "tree-changed"});
}
"""
            )
            (source / "mux.rs").write_text(
                """\
impl TreeDeltaKind {
    fn wire_name(&self) -> &str {
        match self {
            Self::WorkspaceAdded => "workspace-added",
        }
    }
}
"""
            )
            (source / "conversation_store.rs").write_text(
                """\
// json!({"event": "comment-only"})
impl ConversationEvent {
    pub(crate) fn wire_json(&self) -> Value {
        match self {
            Self::Changed { .. } => json!({"event": "conversation-changed", "rev": 1}),
            Self::Typing { .. } => json!({"event": "conversation-typing", "on": true}),
        }
    }
}
"""
            )

            with patch.object(CHECKER, "TUI", tui):
                names = CHECKER.event_names()
            self.assertTrue({"conversation-changed", "conversation-typing"}.issubset(names))
            self.assertNotIn("comment-only", names)

    def test_event_discovery_skips_only_the_listed_log_records(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            tui = Path(directory)
            source = tui / "crates/cmux-tui-core/src"
            (source / "server").mkdir(parents=True)
            (source / "server.rs").write_text(
                'fn tree_delta_json() {\n    let _ = json!({"event": "tree-changed"});\n}\n'
            )
            (source / "mux.rs").write_text(
                "impl TreeDeltaKind {\n    fn wire_name(&self) -> &str {\n"
                '        match self { Self::WorkspaceAdded => "workspace-added" }\n    }\n}\n'
            )
            watchdog = source / "server/request_watchdog.rs"
            # The hang log record is not a runtime event; a wire event beside it is.
            watchdog.write_text(
                'fn write_hang() { sink(json!({"event": "hang", "scope": "request"})); }\n'
                'fn wire() { send(json!({"event": "watchdog-changed"})); }\n'
            )
            logs = {"request_watchdog": frozenset({"hang"})}
            with patch.object(CHECKER, "TUI", tui), patch.object(CHECKER, "SERVER_LOG_RECORDS", logs):
                names = CHECKER.event_names()
            self.assertIn("watchdog-changed", names)
            self.assertNotIn("hang", names)
            # The same record in an unlisted module is a runtime event.
            (source / "server/other.rs").write_text('fn f() { json!({"event": "hang"}); }\n')
            with patch.object(CHECKER, "TUI", tui), patch.object(CHECKER, "SERVER_LOG_RECORDS", logs):
                self.assertIn("hang", CHECKER.event_names())
            (source / "server/other.rs").unlink()
            # A listed record the module no longer writes is stale.
            watchdog.write_text('fn wire() { send(json!({"event": "watchdog-changed"})); }\n')
            errors = io.StringIO()
            with (
                patch.object(CHECKER, "TUI", tui),
                patch.object(CHECKER, "SERVER_LOG_RECORDS", logs),
                redirect_stderr(errors),
                self.assertRaises(SystemExit),
            ):
                CHECKER.event_names()
            self.assertIn("no longer writes log record hang", errors.getvalue())
            # A listed module that is gone is stale too.
            watchdog.unlink()
            (source / "server/other.rs").write_text("fn f() {}\n")
            errors = io.StringIO()
            with (
                patch.object(CHECKER, "TUI", tui),
                patch.object(CHECKER, "SERVER_LOG_RECORDS", logs),
                redirect_stderr(errors),
                self.assertRaises(SystemExit),
            ):
                CHECKER.event_names()
            self.assertIn("names server/request_watchdog, which is gone", errors.getvalue())

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
        match self {
            Self::WorkspaceAdded => "workspace-added",
        }
    }
}
"""
            )

            with patch.object(CHECKER, "TUI", tui):
                names = CHECKER.event_names()
                self.assertIn("tree-changed", names)
                self.assertIn("workspace-added", names)
                self.assertNotIn("comment-only", names)
                self.assertNotIn("nested-comment-only", names)

    def test_event_discovery_handles_field_order_constants_and_insertions(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            tui = Path(directory)
            server = tui / "crates/cmux-tui-core/src/server.rs"
            mux = tui / "crates/cmux-tui-core/src/mux.rs"
            server.parent.mkdir(parents=True)
            server.write_text(
                """\
const CONSTANT_EVENT: &str = "constant-event";

fn serializers() {
    let _ = json!({"surface": 7, "event": "late-key-event"});
    let _ = json!({"surface": 8, "event": CONSTANT_EVENT});
    let mut value = json!({"surface": 9});
    value
        .as_object_mut()
        .unwrap()
        .insert("event".to_string(), json!("inserted-event"));
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

            with patch.object(CHECKER, "TUI", tui):
                names = CHECKER.event_names()
                self.assertTrue(
                    {
                        "late-key-event",
                        "constant-event",
                        "inserted-event",
                    }.issubset(names)
                )

    def test_new_workspace_route_covers_provider_owned_sessions(self) -> None:
        actions = {
            action["variant"]: action
            for action in self.inventory()["tui_actions"]
        }
        new_workspace = actions["NewWorkspace"]
        self.assertEqual(new_workspace["classification"], "composite")
        self.assertEqual(
            new_workspace["route"],
            {
                "ownership_source": "active-workspace-session",
                "session_owned": {
                    "kind": "mux-command",
                    "operation": "new-workspace",
                },
                "provider_owned": {
                    "kind": "machine-provider-request",
                    "operation": "create_workspace",
                },
                "unknown_ownership": "reject",
            },
        )

    def test_close_workspace_route_covers_provider_owned_sessions(self) -> None:
        actions = {
            action["variant"]: action
            for action in self.inventory()["tui_actions"]
        }
        close_workspace = actions["CloseWorkspace"]
        self.assertEqual(close_workspace["classification"], "composite")
        self.assertEqual(
            close_workspace["route"],
            {
                "ownership_source": "active-workspace-session",
                "session_owned": {
                    "kind": "mux-command",
                    "operation": "close-workspace",
                },
                "provider_owned": {
                    "kind": "machine-provider-request",
                    "operation": "delete_workspace",
                },
                "unknown_ownership": "reject",
            },
        )

    def test_new_workspace_route_rejects_unknown_authority_and_operations(self) -> None:
        route = {
            "ownership_source": "active-workspace-session",
            "session_owned": {
                "kind": "mux-command",
                "operation": "new-workspace",
            },
            "provider_owned": {
                "kind": "machine-provider-request",
                "operation": "create_workspace",
            },
            "unknown_ownership": "reject",
        }
        cases = [
            (
                ("ownership_source",),
                "guessed-owner",
                "unknown workspace ownership source",
            ),
            (
                ("session_owned", "operation"),
                "future-command",
                "unknown mux command",
            ),
            (
                ("provider_owned", "operation"),
                "future_request",
                "unknown machine-provider request",
            ),
            (
                ("unknown_ownership",),
                "fallback",
                "unknown workspace ownership must reject",
            ),
        ]
        for path, value, expected_error in cases:
            with self.subTest(path=path):
                inventory = copy.deepcopy(self.inventory())
                new_workspace = next(
                    action
                    for action in inventory["tui_actions"]
                    if action["variant"] == "NewWorkspace"
                )
                new_workspace["route"] = copy.deepcopy(route)
                target = new_workspace["route"]
                for key in path[:-1]:
                    target = target[key]
                target[path[-1]] = value
                errors = io.StringIO()
                with redirect_stderr(errors), self.assertRaises(SystemExit):
                    CHECKER.validate_tui_actions(inventory)
                self.assertIn(expected_error, errors.getvalue())

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
