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
    assert_eq!(ShutdownDaemonRequest::FORCE_CAPABILITY, "daemon-handoff-force-v1");
    assert_eq!(ShutdownDaemonRequest::END_TERMINALS_CAPABILITY, "terminal-reap-v1");
    assert_eq!(ShutdownDaemonRequest::KEEP_LAYOUT_CAPABILITY, "end-terminals-keep-layout-v1");
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
    let zoom = ZoomPaneRequest { mode: Some(Some(ZoomPaneRequestMode::Off)), pane: Some(Some(12)) };
    assert_eq!(bytes(&zoom.line(5)), r#"{"cmd":"zoom-pane","id":5,"mode":"off","pane":12}"#);
    // `mode` defaults to "toggle" but is nullable: `null` stays sendable.
    let null_mode = ZoomPaneRequest { mode: Some(None), pane: None };
    assert_eq!(bytes(&null_mode.line(5)), r#"{"cmd":"zoom-pane","id":5,"mode":null}"#);
}

#[test]
fn cli_wire_tagged_union_writes_its_tag() {
    let event = FrontendJournalEvent::Focus(FrontendJournalEventFocus {
        content_id: None,
        event_id: "e1".to_owned(),
        frontend_projection_id: "p1".to_owned(),
        generation: "g1".to_owned(),
        pane_id: Some(Some("pane-1".to_owned())),
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
fn cli_wire_optional_nullable_tells_absent_from_null() {
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

/// A request field's presence shape, as either generator spells it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Presence {
    /// Always sent, never null.
    Required,
    /// Always sent, may be null (SDK `Nullable<T>`, here `Option<T>`).
    RequiredNullable,
    /// May be left out, never null (`Option<T>` in both).
    Optional,
    /// Left out, null or a value (SDK `Optional<T>`, here `Option<Option<T>>`).
    OptionalNullable,
}

/// The trimmed lines of `pub struct {name} {` up to its closing brace.
fn struct_body<'a>(code: &'a str, name: &str) -> Option<Vec<&'a str>> {
    let open = format!("pub struct {name} {{");
    let mut lines = code.lines().skip_while(|line| line.trim() != open);
    lines.next()?;
    Some(lines.take_while(|line| line.trim() != "}").map(str::trim).collect())
}

/// The SDK's generated request struct: wire name and presence per field.
fn sdk_fields(code: &str, name: &str) -> Vec<(String, Presence)> {
    let body = struct_body(code, name).unwrap_or_else(|| panic!("the SDK has no {name}"));
    let mut rename = None;
    let mut fields = Vec::new();
    for line in body {
        if let Some(attr) = line.strip_prefix("#[serde(") {
            assert!(!attr.starts_with("flatten"), "{name} takes extra fields; the CLI type cannot");
            rename = attr
                .split("rename = \"")
                .nth(1)
                .and_then(|rest| rest.split('"').next())
                .map(str::to_owned);
            continue;
        }
        let Some((ident, ty)) = line.strip_prefix("pub ").and_then(|field| field.split_once(": "))
        else {
            continue;
        };
        let presence = if ty.starts_with("Optional<") {
            Presence::OptionalNullable
        } else if ty.starts_with("Nullable<") {
            Presence::RequiredNullable
        } else if ty.starts_with("Option<") {
            Presence::Optional
        } else {
            Presence::Required
        };
        let wire = rename.take().unwrap_or_else(|| ident.trim_start_matches("r#").to_owned());
        fields.push((wire, presence));
    }
    fields
}

/// This crate's generated request struct: wire name and presence per field.
/// The wire name is the first backticked word of the field's doc; a field
/// is left out when `None` if `insert_fields` wraps it in `if let Some`.
fn cli_fields(code: &str, name: &str) -> Vec<(String, Presence)> {
    let body = struct_body(code, name).unwrap_or_else(|| panic!("no generated {name}"));
    let insert = code
        .split(&format!("impl WireObject for {name} {{"))
        .nth(1)
        .and_then(|rest| rest.split("\n}\n").next())
        .unwrap_or_else(|| panic!("no WireObject for {name}"));
    let mut wire = None;
    let mut fields = Vec::new();
    for line in body {
        if line.starts_with("#[doc = ") {
            wire = line.split('`').nth(1).map(str::to_owned);
            continue;
        }
        let (ident, ty) = line
            .strip_prefix("pub ")
            .and_then(|field| field.split_once(": "))
            .unwrap_or_else(|| panic!("{name}: unexpected line {line:?}"));
        let omittable = insert.contains(&format!("if let Some(value) = &self.{ident} {{"));
        let presence = match (ty.starts_with("Option<Option<"), ty.starts_with("Option<")) {
            (true, _) => Presence::OptionalNullable,
            (false, true) if omittable => Presence::Optional,
            (false, true) => Presence::RequiredNullable,
            (false, false) => Presence::Required,
        };
        let wire = wire.take().unwrap_or_else(|| panic!("{name}.{ident} has no doc"));
        fields.push((wire, presence));
    }
    fields
}

fn pascal(name: &str) -> String {
    name.split(['-', '_', '.'])
        .flat_map(|part| {
            let mut chars = part.chars();
            chars.next().into_iter().flat_map(char::to_uppercase).chain(chars)
        })
        .collect()
}

#[test]
fn cli_wire_request_shapes_agree_with_the_sdk() {
    // Two generators read spec/sdk-schema.json: the SDK's (bindings/codegen)
    // and this crate's (build-support/client_requests.rs). Every `cli` request
    // has the same fields with the same presence in both. The SDK also types
    // literal fields, which this crate writes as constants.
    let generated = include_str!(concat!(env!("OUT_DIR"), "/client_requests.rs"));
    let sdk_path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../bindings/rust/src/generated/commands.rs");
    let sdk = std::fs::read_to_string(&sdk_path)
        .unwrap_or_else(|e| panic!("{}: {e}", sdk_path.display()));
    let schema = sdk_schema();
    for (name, _) in COMMANDS {
        let fields = &schema["commands"][*name]["request"]["fields"];
        let rust = format!("{}Request", pascal(name));
        let mut expected = sdk_fields(&sdk, &rust);
        expected.retain(|(wire, _)| fields[wire.as_str()]["type"]["kind"] != "literal");
        expected.sort_by(|a, b| a.0.cmp(&b.0));
        let mut actual = cli_fields(generated, &rust);
        actual.sort_by(|a, b| a.0.cmp(&b.0));
        assert_eq!(actual, expected, "{rust} ({name})");
    }
    assert!(COMMANDS.len() > 50, "only {} cli requests", COMMANDS.len());
}
