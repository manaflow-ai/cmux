//! The client-request emitter (build-support/client_requests.rs) types each
//! presence shape as documented and refuses, with its JSON path, a schema it
//! cannot type.

use serde_json::{Value, json};

#[path = "../../build-support/client_requests.rs"]
mod emitter;

fn schema(request_fields: Value, types: Value) -> Value {
    json!({
        "commands": {
            "probe-thing": {
                "method_id": 0x0101,
                "capability": "probe-v1",
                "clients": ["cli"],
                "request": {"kind": "object", "fields": request_fields},
            },
            "app-only": {
                "method_id": 0x0102,
                "clients": ["macos"],
                "request": {"kind": "object", "fields": {}},
            },
        },
        "types": types,
    })
}

fn field(kind: Value, presence: &str, nullable: bool, default: Option<Value>) -> Value {
    let mut node = json!({"type": kind, "presence": presence, "nullable": nullable});
    if let Some(default) = default {
        node["default"] = default;
    }
    node
}

fn string() -> Value {
    json!({"kind": "scalar", "name": "string"})
}

fn emit(doc: &Value) -> String {
    emitter::emit(doc, emitter::CLI).unwrap()
}

fn refusal(doc: &Value) -> emitter::ClientError {
    emitter::emit(doc, emitter::CLI).unwrap_err()
}

#[test]
fn cli_wire_emitter_types_each_presence_shape() {
    let doc = schema(
        json!({
            "required": field(string(), "required", false, None),
            "required_null": field(string(), "required", true, None),
            "optional": field(string(), "optional", false, Some(json!("x"))),
            "optional_null": field(string(), "optional", true, Some(Value::Null)),
            "tri_state": field(string(), "optional", true, None),
            "type": field(json!({"kind": "scalar", "name": "boolean"}), "required", false, None),
        }),
        json!({}),
    );
    let code = emit(&doc);
    for line in [
        "pub struct ProbeThingRequest {",
        "pub required: String,",
        "pub required_null: Option<String>,",
        "pub optional: Option<String>,",
        "pub optional_null: Option<Option<String>>,",
        "pub tri_state: Option<Option<String>>,",
        "pub type_: bool,",
        "fields.insert(\"type\".to_owned(), self.type_.wire_value());",
        "const CMD: &'static str = \"probe-thing\";",
        "const METHOD_ID: MethodId = MethodId::new(0x0101);",
        "const CAPABILITY: Option<&'static str> = Some(\"probe-v1\");",
        "(\"probe-thing\", MethodId::new(0x0101)),",
    ] {
        assert!(code.contains(line), "missing {line:?} in\n{code}");
    }
    assert!(!code.contains("AppOnly"), "a command of another client is not emitted");
    assert!(!code.contains("Default"), "a required field rules out Default");
}

#[test]
fn cli_wire_emitter_names_inline_and_referenced_types() {
    let doc = schema(
        json!({
            "mode": field(json!({"kind": "enum", "values": ["on", "page-down"]}), "optional", false, None),
            "size": field(json!({"kind": "ref", "name": "Size"}), "optional", true, Some(Value::Null)),
            "pane": field(json!({"kind": "ref", "name": "Id"}), "optional", true, Some(Value::Null)),
            "extra": field(json!({"kind": "ref", "name": "JsonValue"}), "optional", true, Some(Value::Null)),
        }),
        json!({
            "Size": {"kind": "object", "fields": {
                "cols": field(json!({"kind": "scalar", "name": "uint16"}), "required", false, None),
            }},
            "Id": {"kind": "alias", "target": {"kind": "scalar", "name": "uint64"}},
            "JsonValue": {"kind": "opaque_json", "reason": "any"},
        }),
    );
    let code = emit(&doc);
    for line in [
        "pub mode: Option<ProbeThingRequestMode>,",
        "pub enum ProbeThingRequestMode {",
        "PageDown,",
        "ProbeThingRequestMode::PageDown => \"page-down\",",
        "pub size: Option<Option<Size>>,",
        "pub struct Size {",
        "pub cols: u16,",
        "pub pane: Option<Option<u64>>,",
        "pub extra: Option<Option<Value>>,",
    ] {
        assert!(code.contains(line), "missing {line:?} in\n{code}");
    }
}

#[test]
fn cli_wire_emitter_refuses_what_it_cannot_type() {
    let cases = [
        (
            schema(
                json!({"x": field(json!({"kind": "scalar", "name": "uint128"}), "required", false, None)}),
                json!({}),
            ),
            "$.commands.probe-thing.request.fields.x.type",
            "unknown scalar",
        ),
        (
            schema(json!({"cmd": field(string(), "required", false, None)}), json!({})),
            "$.commands.probe-thing.request.fields.cmd",
            "collides with the line envelope",
        ),
        (
            schema(
                json!({"k": field(json!({"kind": "literal", "value": "a"}), "optional", false, None)}),
                json!({}),
            ),
            "$.commands.probe-thing.request.fields.k",
            "optional literal",
        ),
        (
            schema(
                json!({"m": field(json!({"kind": "enum", "values": ["page-down", "page_down"]}), "required", false, None)}),
                json!({}),
            ),
            "$.commands.probe-thing.request.fields.m.type.values[1]",
            "are both",
        ),
        (
            schema(
                json!({"r": field(json!({"kind": "ref", "name": "Missing"}), "required", false, None)}),
                json!({}),
            ),
            "$.commands.probe-thing.request.fields.r.type",
            "no type",
        ),
        (
            schema(
                json!({"r": field(json!({"kind": "ref", "name": "ProbeThingRequest"}), "required", false, None)}),
                json!({"ProbeThingRequest": {"kind": "enum", "values": ["a"]}}),
            ),
            "$.types.ProbeThingRequest",
            "is also",
        ),
        (
            union_schema(json!({"kind": "object", "fields": {
                "n": field(json!({"kind": "scalar", "name": "uint32"}), "required", false, None),
            }})),
            "$.types.Event.variants.focus.fields.kind",
            "required literal \"focus\"",
        ),
        (
            union_schema(json!({"kind": "object", "fields": {
                "type": field(json!({"kind": "literal", "value": "focus"}), "required", false, None),
            }})),
            "$.types.Event.variants.focus.fields.kind",
            "required literal \"focus\"",
        ),
        (
            union_schema(json!({"kind": "object", "fields": {
                "kind": field(json!({"kind": "literal", "value": "focused"}), "required", false, None),
            }})),
            "$.types.Event.variants.focus.fields.kind",
            "required literal \"focus\"",
        ),
        (
            union_schema(json!({"kind": "object", "fields": {
                "kind": field(json!({"kind": "scalar", "name": "string"}), "required", false, None),
            }})),
            "$.types.Event.variants.focus.fields.kind",
            "required literal \"focus\"",
        ),
    ];
    for (doc, path, message) in cases {
        let error = refusal(&doc);
        assert_eq!(error.path, path, "{error}");
        assert!(error.message.contains(message), "{error}");
    }
    let mut no_id = schema(json!({}), json!({}));
    no_id["commands"]["probe-thing"].as_object_mut().unwrap().remove("method_id");
    let error = refusal(&no_id);
    assert_eq!(error.path, "$.commands.probe-thing.method_id");
    let mut no_tag = union_schema(json!({"kind": "object", "fields": {}}));
    no_tag["types"]["Event"].as_object_mut().unwrap().remove("tag");
    let error = refusal(&no_tag);
    assert_eq!(error.path, "$.types.Event.tag", "{error}");
}

/// A command whose `event` field is the union `Event` (tag `kind`) with the
/// one variant `focus`.
fn union_schema(focus: Value) -> Value {
    schema(
        json!({"event": field(json!({"kind": "ref", "name": "Event"}), "required", false, None)}),
        json!({"Event": {"kind": "tagged_union", "tag": "kind", "variants": {"focus": focus}}}),
    )
}

#[test]
fn cli_wire_emitter_declares_an_alias_target_once() {
    let doc = schema(
        json!({
            "first": field(json!({"kind": "ref", "name": "Mode"}), "required", false, None),
            "second": field(json!({"kind": "ref", "name": "Mode"}), "optional", false, None),
            "size": field(json!({"kind": "ref", "name": "Size"}), "required", false, None),
            "other_size": field(json!({"kind": "ref", "name": "Size"}), "optional", true, None),
        }),
        json!({
            "Mode": {"kind": "alias", "target": {"kind": "enum", "values": ["on", "off"]}},
            "Size": {"kind": "alias", "target": {"kind": "object", "fields": {
                "cols": field(json!({"kind": "scalar", "name": "uint16"}), "required", false, None),
            }}},
        }),
    );
    let code = emit(&doc);
    for line in [
        "pub first: Mode,",
        "pub second: Option<Mode>,",
        "pub size: Size,",
        "pub other_size: Option<Option<Size>>,",
    ] {
        assert!(code.contains(line), "missing {line:?} in\n{code}");
    }
    assert_eq!(code.matches("pub enum Mode {").count(), 1, "{code}");
    assert_eq!(code.matches("pub struct Size {").count(), 1, "{code}");
}

#[test]
fn cli_wire_emitter_names_field_capabilities() {
    let mut gated = field(json!({"kind": "scalar", "name": "boolean"}), "optional", false, None);
    gated["capability"] = json!("probe-force-v1");
    let doc = schema(json!({"force": gated}), json!({}));
    let code = emit(&doc);
    let line = "pub const FORCE_CAPABILITY: &'static str = \"probe-force-v1\";";
    assert!(code.contains(line), "missing {line:?} in\n{code}");
}

#[test]
fn cli_wire_emitter_writes_union_tags_as_literals() {
    let doc = schema(
        json!({"event": field(json!({"kind": "ref", "name": "Event"}), "required", false, None)}),
        json!({"Event": {"kind": "tagged_union", "tag": "kind", "variants": {
            "focus": {"kind": "object", "fields": {
                "kind": field(json!({"kind": "literal", "value": "focus"}), "required", false, None),
                "n": field(json!({"kind": "scalar", "name": "uint32"}), "required", false, None),
            }},
        }}}),
    );
    let code = emit(&doc);
    for line in [
        "pub enum Event {",
        "Focus(EventFocus),",
        "pub struct EventFocus {",
        "fields.insert(\"kind\".to_owned(), Value::from(\"focus\"));",
        "Event::Focus(variant) => variant.wire_value(),",
    ] {
        assert!(code.contains(line), "missing {line:?} in\n{code}");
    }
    assert!(!code.contains("pub kind:"), "a literal has no Rust field");
}

#[test]
fn cli_wire_emitter_writes_the_real_schema() {
    let path =
        std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../spec/sdk-schema.json");
    let doc: Value = serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
    let code = emit(&doc);
    assert!(code.contains("pub struct ShutdownDaemonRequest {"));
    assert_eq!(emit(&doc), code, "the output is deterministic");
}
