//! The server family emitter (build-support/server_families.rs): what it
//! makes of the real terminal-io family, and the schemas it refuses with
//! their path. cmux-tui-core's server_generated_terminal_io tests check that
//! the expanded structs decode as the hand-written variants did.

use serde_json::{Value, json};

#[allow(dead_code, reason = "the build script uses every item; the tests use some")]
#[path = "../../build-support/server_families.rs"]
mod emitter;

fn sdk_schema() -> Value {
    let path =
        std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../spec/sdk-schema.json");
    serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap()
}

fn listed() -> Vec<String> {
    let path = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("server-families.json");
    let doc: Value = serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
    emitter::listed_families(&doc).unwrap()
}

/// A one-family schema whose `probe` command has `fields`.
fn schema_with(fields: Value) -> Value {
    json!({
        "families": {"probe-family": {"id": 9}},
        "types": {"Id": {"kind": "alias", "target": {"kind": "scalar", "name": "uint64"}}},
        "commands": {
            "probe": {"method_id": 0x0900, "request": {"kind": "object", "fields": fields}}
        }
    })
}

fn refusal(fields: Value) -> emitter::EmitError {
    emitter::read(&schema_with(fields), &["probe-family".to_owned()]).unwrap_err()
}

#[test]
fn server_families_terminal_io_has_every_schema_command() {
    let sdk = sdk_schema();
    let families = emitter::read(&sdk, &listed()).unwrap();
    let terminal_io = families.iter().find(|family| family.name == "terminal-io").unwrap();
    let family_id = sdk["families"]["terminal-io"]["id"].as_u64().unwrap();
    let mut expected: Vec<(u64, String)> = sdk["commands"]
        .as_object()
        .unwrap()
        .iter()
        .filter_map(|(wire, command)| {
            let id = command["method_id"].as_u64()?;
            (id >> 8 == family_id).then(|| (id, wire.clone()))
        })
        .collect();
    expected.sort();
    let found: Vec<(u64, String)> = terminal_io
        .commands
        .iter()
        .map(|command| (u64::from(command.method_id), command.wire.clone()))
        .collect();
    assert_eq!(found, expected);
    let refs: Vec<&str> = terminal_io.refs.iter().map(String::as_str).collect();
    assert_eq!(
        refs,
        ["RowMarkerPoint", "SendExpectAgent", "SnapshotRequestHave", "TerminalKeyInput"]
    );
}

#[test]
fn server_families_fields_follow_presence_nullable_and_default() {
    let sdk = sdk_schema();
    let families = emitter::read(&sdk, &["terminal-io".to_owned()]).unwrap();
    let command = |wire: &str| {
        families[0].commands.iter().find(|command| command.wire == wire).unwrap().clone()
    };
    let field = |wire: &str, name: &str| {
        command(wire).fields.into_iter().find(|field| field.wire == name).unwrap()
    };
    let surface = field("read-screen", "surface");
    assert_eq!((surface.rust_type.as_str(), surface.serde.len()), ("u64", 0));
    let text = field("send", "text");
    assert_eq!(text.rust_type, "::core::option::Option<::std::string::String>");
    assert_eq!(text.serde, ["default"]);
    let paste = field("send", "paste");
    assert_eq!((paste.rust_type.as_str(), paste.serde.clone()), ("bool", vec!["default".into()]));
    let ttl = field("mint-terminal-renderer", "ttl_ms");
    assert_eq!(ttl.serde, ["default = \"mint_terminal_renderer_ttl_ms_default\""]);
    assert_eq!(
        ttl.default_fn,
        Some(("mint_terminal_renderer_ttl_ms_default".into(), "u64".into(), "30000".into()))
    );
    let fallback = field("clear-history", "fallback_key");
    assert_eq!(fallback.rust_type, "::core::option::Option<$TerminalKeyInput>");
    let keys = field("send-key", "keys");
    assert_eq!(keys.rust_type, "::std::vec::Vec<::std::string::String>");
    let mode = field("copy", "mode");
    assert_eq!(mode.rust_type, "::std::string::String", "string enums stay strings");
    assert_eq!(command("get-cell-pixels").params(), None, "no fields: a unit variant");
    assert_eq!(command("send").params().as_deref(), Some("SendParams"));
}

#[test]
fn server_families_emit_both_macros() {
    let families = emitter::read(&sdk_schema(), &listed()).unwrap();
    let code = emitter::emit(&families);
    assert!(code.contains("macro_rules! terminal_io_params {"));
    assert!(code.contains("macro_rules! server_command_enum {"));
    assert!(code.contains("        terminal_io = $terminal_io:ident;"));
    assert!(code.contains("            Send($terminal_io::SendParams),"));
    assert!(code.contains(
        "            #[serde(rename = \"get-cell-pixels\")]\n            GetCellPixels,"
    ));
    assert_eq!(code, emitter::emit(&families), "the output is deterministic");
}

#[test]
fn server_families_keyword_fields_are_raw_identifiers() {
    let fields =
        json!({"type": {"type": {"kind": "scalar", "name": "string"}, "presence": "required"}});
    let families = emitter::read(&schema_with(fields), &["probe-family".to_owned()]).unwrap();
    assert_eq!(families[0].commands[0].fields[0].ident, "r#type");
}

#[test]
fn server_families_refuse_what_they_cannot_generate() {
    let string = json!({"kind": "scalar", "name": "string"});
    let required_nullable =
        refusal(json!({"a": {"type": string, "presence": "required", "nullable": true}}));
    assert_eq!(required_nullable.path, "$.commands.probe.request.fields.a");
    let no_default =
        refusal(json!({"a": {"type": string, "presence": "optional", "nullable": false}}));
    assert!(no_default.message.contains("needs a default"), "{no_default}");
    let bad_default = refusal(json!({
        "a": {"type": {"kind": "scalar", "name": "uint16"}, "presence": "optional", "default": 70000}
    }));
    assert_eq!(bad_default.path, "$.commands.probe.request.fields.a.default");
    let union = refusal(
        json!({"a": {"type": {"kind": "untagged_union", "variants": []}, "presence": "required"}}),
    );
    assert!(union.message.contains("not generated yet"), "{union}");
    let unknown = emitter::read(&schema_with(json!({})), &["no-such".to_owned()]).unwrap_err();
    assert_eq!(unknown.path, "$.families.no-such");
    let twice = emitter::listed_families(&json!({"families": ["a", "a"]})).unwrap_err();
    assert_eq!(twice.path, "$.families[1]");
}
