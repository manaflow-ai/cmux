//! The generated `cli` request types (task 028): their lines equal, byte for
//! byte, the ones the CLI built by hand before (golden), and every type agrees
//! with the schema and the method tables.

use std::path::PathBuf;

use serde_json::{Value, json};

use crate::client::{
    COMMANDS, ClientRequest, FrontendFocusTarget, FrontendJournalEvent, FrontendJournalEventFocus,
    IdentifyRequest, JournalFrontendEventRequest, ReloadConfigRequest, ServerStatsRequest,
    ShutdownDaemonRequest, WireValue, ZoomPaneRequest, ZoomPaneRequestMode,
};
use crate::methods::{MethodId, MethodTables};

fn sdk_schema() -> Value {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../spec/sdk-schema.json");
    let text = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    serde_json::from_str(&text).unwrap()
}

/// The bytes a line goes out as (`writeln!(.., "{line}")` in the CLI).
fn bytes(line: &Value) -> String {
    line.to_string()
}

#[test]
fn cli_wire_pilot_lines_equal_the_hand_built_ones() {
    // Each pair: the generated line, and the `json!` the pilot files
    // (cli/lifecycle.rs, cli/wire.rs) wrote before task 028.
    let pairs = [
        (IdentifyRequest::default().line(1), json!({"id":1,"cmd":"identify"})),
        (
            IdentifyRequest::default().line(format!("stop-wait-{}", 3)),
            json!({"id": format!("stop-wait-{}", 3), "cmd": "identify"}),
        ),
        (
            IdentifyRequest::default().line("request-0f3a"),
            json!({"id":"request-0f3a","cmd":"identify"}),
        ),
        (ServerStatsRequest::default().line(2), json!({"id":2,"cmd":"server-stats"})),
        (ReloadConfigRequest::default().line(2), json!({"id":2,"cmd":"reload-config"})),
    ];
    for (generated, hand_built) in &pairs {
        assert_eq!(bytes(generated), bytes(hand_built));
    }
    for (force, end_terminals) in [(false, false), (true, false), (false, true), (true, true)] {
        let generated = ShutdownDaemonRequest {
            pid: 4242,
            generation: "gen-7".to_owned(),
            force: Some(force),
            end_terminals: Some(end_terminals),
            keep_layout: None,
        }
        .line(2);
        let hand_built = json!({
            "id":2,
            "cmd":"shutdown-daemon",
            "pid":4242_u32,
            "generation":"gen-7",
            "force":force,
            "end_terminals":end_terminals,
        });
        assert_eq!(bytes(&generated), bytes(&hand_built));
    }
}

#[test]
fn cli_wire_golden_bytes() {
    assert_eq!(bytes(&IdentifyRequest::default().line(1)), r#"{"cmd":"identify","id":1}"#);
    let stop = ShutdownDaemonRequest {
        pid: 9,
        generation: "g".to_owned(),
        force: Some(false),
        end_terminals: Some(true),
        keep_layout: None,
    };
    assert_eq!(
        bytes(&stop.line(2)),
        r#"{"cmd":"shutdown-daemon","end_terminals":true,"force":false,"generation":"g","id":2,"pid":9}"#
    );
}

#[test]
fn cli_wire_request_constants() {
    assert_eq!(IdentifyRequest::CMD, "identify");
    assert_eq!(IdentifyRequest::METHOD_ID, MethodId::new(0x0100));
    assert_eq!(IdentifyRequest::CAPABILITY, None);
    assert_eq!(ServerStatsRequest::CAPABILITY, Some("server-stats-v1"));
    assert_eq!(ShutdownDaemonRequest::CMD, "shutdown-daemon");
}

#[test]
fn cli_wire_commands_agree_with_the_schema_and_tables() {
    let schema = sdk_schema();
    let commands = schema["commands"].as_object().unwrap();
    let mut expected: Vec<(&str, u16)> = commands
        .iter()
        .filter(|(_, node)| {
            node["clients"].as_array().is_some_and(|clients| clients.iter().any(|c| c == "cli"))
        })
        .map(|(name, node)| {
            (name.as_str(), u16::try_from(node["method_id"].as_u64().unwrap()).unwrap())
        })
        .collect();
    expected.sort_unstable();
    let mut generated: Vec<(&str, u16)> =
        COMMANDS.iter().map(|(name, id)| (*name, id.raw())).collect();
    generated.sort_unstable();
    assert_eq!(generated, expected);
    let tables = MethodTables::schema();
    for (name, id) in COMMANDS {
        assert_eq!(tables.v12_id(name), Some(*id), "{name}");
    }
}

#[test]
fn cli_wire_optional_fields_are_left_out_and_enums_spell_the_schema() {
    assert_eq!(bytes(&ZoomPaneRequest::default().line(5)), r#"{"cmd":"zoom-pane","id":5}"#);
    let zoom = ZoomPaneRequest { mode: Some(ZoomPaneRequestMode::Off), pane: Some(12) };
    assert_eq!(bytes(&zoom.line(5)), r#"{"cmd":"zoom-pane","id":5,"mode":"off","pane":12}"#);
}

#[test]
fn cli_wire_tagged_union_writes_its_tag() {
    let event = FrontendJournalEvent::Focus(FrontendJournalEventFocus {
        content_id: None,
        event_id: "e1".to_owned(),
        frontend_projection_id: "p1".to_owned(),
        generation: "g1".to_owned(),
        pane_id: Some("pane-1".to_owned()),
        screen_id: None,
        tab_id: None,
        target: FrontendFocusTarget::MachineRail,
        workspace_id: None,
    });
    assert_eq!(
        event.wire_value(),
        json!({
            "kind": "focus",
            "event_id": "e1",
            "frontend_projection_id": "p1",
            "generation": "g1",
            "pane_id": "pane-1",
            "target": "machine_rail",
        })
    );
    let line = JournalFrontendEventRequest { event }.line(3);
    assert_eq!(line["cmd"], "journal-frontend-event");
    assert_eq!(line["event"]["kind"], "focus");
}

#[test]
fn cli_wire_nullable_without_default_tells_absent_from_null() {
    // Option<Option<T>>: None leaves the field out, Some(None) sends null.
    let line = crate::client::AccessRequestRequest {
        kind: "path".to_owned(),
        name: Some(None),
        path: Some(Some("/tmp".to_owned())),
        reason: None,
        session: None,
    }
    .line(1);
    assert_eq!(
        bytes(&line),
        r#"{"cmd":"access-request","id":1,"kind":"path","name":null,"path":"/tmp"}"#
    );
}
