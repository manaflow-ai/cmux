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

/// The tabs family's field shapes. A nullable field keeps `null`
/// apart from absent where the schema gives it no default, and a required
/// nullable one must be present.
#[test]
fn server_families_nullable_fields_keep_null_apart_from_absent() {
    let string = json!({"kind": "scalar", "name": "string"});
    let families = emitter::read(
        &schema_with(json!({
            "cleared": {"type": string, "presence": "optional", "nullable": true},
            "plain": {"type": string, "presence": "optional", "nullable": true, "default": null},
            "must": {"type": string, "presence": "required", "nullable": true},
            "env": {
                "type": {"kind": "map", "values": string},
                "presence": "optional",
                "nullable": false,
                "default": {}
            },
        })),
        &["probe-family".to_owned()],
    )
    .unwrap();
    let field = |name: &str| {
        families[0].commands[0].fields.iter().find(|field| field.wire == name).unwrap().clone()
    };
    let cleared = field("cleared");
    assert_eq!(
        cleared.rust_type,
        "::core::option::Option<::core::option::Option<::std::string::String>>"
    );
    assert_eq!(cleared.reader, Some(emitter::Reader::PresentNullable));
    assert!(cleared.serde.contains(&"deserialize_with = \"present_nullable\"".to_owned()));
    let plain = field("plain");
    assert_eq!((plain.serde.clone(), plain.reader), (vec!["default".to_owned()], None));
    let must = field("must");
    assert_eq!(must.serde, ["deserialize_with = \"required_nullable\""]);
    assert_eq!(must.reader, Some(emitter::Reader::RequiredNullable));
    let env = field("env");
    assert_eq!(
        env.rust_type,
        "::std::collections::BTreeMap<::std::string::String, ::std::string::String>"
    );
    assert_eq!(env.serde, ["default"]);
    let code = emitter::emit(&families);
    assert_eq!(code.matches("fn present_nullable<").count(), 1, "one reader per family");
    assert_eq!(code.matches("fn required_nullable<").count(), 1, "one reader per family");
}

#[test]
fn server_families_tabs_has_every_schema_command_and_its_refused_field() {
    let sdk = sdk_schema();
    let path = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("server-families.json");
    let list: Value = serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
    let mut families = emitter::read(&sdk, &listed()).unwrap();
    emitter::add_refused_fields(&mut families, &list).unwrap();
    let tabs = families.iter().find(|family| family.name == "tabs").unwrap();
    let family_id = sdk["families"]["tabs"]["id"].as_u64().unwrap();
    let expected = sdk["commands"]
        .as_object()
        .unwrap()
        .values()
        .filter(|command| command["method_id"].as_u64().is_some_and(|id| id >> 8 == family_id))
        .count();
    assert_eq!(tabs.commands.len(), expected);
    let column = tabs.commands.iter().find(|command| command.wire == "move-tab-to-column").unwrap();
    let sticky = column.fields.iter().find(|field| field.wire == "sticky").unwrap();
    assert_eq!(sticky.rust_type, emitter::REFUSED_TYPE);
}

#[test]
fn server_families_refused_fields_need_a_listed_command_and_a_reason() {
    let string = json!({"kind": "scalar", "name": "string"});
    let schema =
        schema_with(json!({"a": {"type": string, "presence": "required", "nullable": false}}));
    let families = emitter::read(&schema, &["probe-family".to_owned()]).unwrap();
    let refuse = |list: Value| emitter::add_refused_fields(&mut families.clone(), &list);
    let unknown = refuse(json!({"refused_fields": {"other": {"x": "why"}}})).unwrap_err();
    assert_eq!(unknown.path, "$.refused_fields.other");
    let no_reason = refuse(json!({"refused_fields": {"probe": {"x": " "}}})).unwrap_err();
    assert_eq!(no_reason.path, "$.refused_fields.probe.x");
    let schema_field = refuse(json!({"refused_fields": {"probe": {"a": "why"}}})).unwrap_err();
    assert!(schema_field.message.contains("schema field"), "{schema_field}");
    assert!(refuse(json!({"refused_fields": {"probe": {"x": "why"}}})).is_ok());
}

#[test]
fn server_families_boxed_needs_a_listed_command_with_params_and_a_reason() {
    let string = json!({"kind": "scalar", "name": "string"});
    let schema =
        schema_with(json!({"a": {"type": string, "presence": "required", "nullable": false}}));
    let families = emitter::read(&schema, &["probe-family".to_owned()]).unwrap();
    let boxed = |list: Value| {
        let mut families = families.clone();
        emitter::box_variants(&mut families, &list).map(|()| families)
    };
    let unknown = boxed(json!({"boxed": {"other": "why"}})).unwrap_err();
    assert_eq!(unknown.path, "$.boxed.other");
    let no_reason = boxed(json!({"boxed": {"probe": " "}})).unwrap_err();
    assert_eq!(no_reason.path, "$.boxed.probe");
    let mut empty = emitter::read(&schema_with(json!({})), &["probe-family".to_owned()]).unwrap();
    let no_params =
        emitter::box_variants(&mut empty, &json!({"boxed": {"probe": "why"}})).unwrap_err();
    assert!(no_params.message.contains("no params"), "{no_params}");
    let unboxed = emitter::emit(&families);
    assert!(unboxed.contains("Probe($probe_family::ProbeParams),"), "{unboxed}");
    let code = emitter::emit(&boxed(json!({"boxed": {"probe": "why"}})).unwrap());
    assert!(code.contains("Probe(::std::boxed::Box<$probe_family::ProbeParams>),"), "{code}");
}

#[test]
fn server_families_boxes_create_surface_with_receipt() {
    let path = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("server-families.json");
    let list: Value = serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
    let mut families = emitter::read(&sdk_schema(), &listed()).unwrap();
    emitter::box_variants(&mut families, &list).unwrap();
    let boxed: Vec<&str> = families
        .iter()
        .flat_map(|family| &family.commands)
        .filter(|command| command.boxed)
        .map(|command| command.wire.as_str())
        .collect();
    assert_eq!(boxed, ["create-surface-with-receipt"]);
}
