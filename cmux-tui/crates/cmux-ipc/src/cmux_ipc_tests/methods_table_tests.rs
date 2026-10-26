//! The tables agree with the schema they were built from, entry by entry, and
//! a schema the tables cannot encode is refused with its path.
//!
//! The agreement check reads the schema JSON on its own (serde_json here, not
//! the build-support reader), so a reader bug cannot hide behind itself.

use std::path::{Path, PathBuf};

use serde_json::{Value, json};

use crate::PriorityHint;
use crate::methods::{
    Coalesce, Durability, EventAttrs, EventId, FIXTURE_TABLES, MethodAttrs, MethodId, MethodTables,
    Ordering, Payload,
};

#[allow(dead_code, reason = "the build script uses the emitter; the tests use the reader")]
#[path = "../../build-support/method_tables.rs"]
mod reader;

fn spec_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../spec")
}

fn load(dir: &Path, file: &str) -> Value {
    let path = dir.join(file);
    let text = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    serde_json::from_str(&text).unwrap()
}

fn str_list(value: Option<&Value>) -> Vec<&str> {
    value
        .and_then(Value::as_array)
        .map(|items| items.iter().map(|item| item.as_str().unwrap()).collect())
        .unwrap_or_default()
}

fn check_method(attrs: &MethodAttrs, name: &str, node: &Value) {
    let text = |key: &str, default: &'static str| {
        node.get(key).and_then(Value::as_str).unwrap_or(default).to_owned()
    };
    let flag = |key: &str| node.get(key).and_then(Value::as_bool).unwrap_or(false);
    assert_eq!(attrs.name, name);
    assert_eq!(attrs.priority.schema_name(), text("priority", ""), "{name}");
    assert_eq!(attrs.ordering.as_str(), text("ordering", "sequence"), "{name}");
    assert_eq!(attrs.durability.as_str(), text("durability", ""), "{name}");
    let payload = match text("payload", "json").as_str() {
        "json" => Payload::Json,
        _ => Payload::Binary {
            layout_version: u8::try_from(node["layout_version"].as_u64().unwrap()).unwrap(),
        },
    };
    assert_eq!(attrs.payload, payload, "{name}");
    assert_eq!(attrs.stream_scoped, flag("stream_scoped"), "{name}");
    assert_eq!(attrs.urgent, flag("urgent"), "{name}");
    assert_eq!(
        attrs.crosses_stream_ok,
        node.get("crosses_stream_ok").and_then(Value::as_str),
        "{name}"
    );
    assert_eq!(
        attrs.max_bytes.map(u64::from),
        node.get("max_bytes").and_then(Value::as_u64),
        "{name}"
    );
    check_coalesce(attrs.coalesce, node, name);
}

fn check_coalesce(coalesce: Option<Coalesce>, node: &Value, name: &str) {
    match node.get("coalesce") {
        None => assert_eq!(coalesce, None, "{name}"),
        Some(spec) => {
            let coalesce = coalesce.unwrap_or_else(|| panic!("{name}: coalesce missing"));
            assert_eq!(coalesce.key, str_list(spec.get("key")).as_slice(), "{name}");
            assert_eq!(coalesce.additive, str_list(spec.get("additive")).as_slice(), "{name}");
        }
    }
}

fn check_event(attrs: &EventAttrs, name: &str, node: &Value) {
    assert_eq!(attrs.name, name);
    assert_eq!(attrs.priority.schema_name(), node["priority"].as_str().unwrap(), "{name}");
    check_coalesce(attrs.coalesce, node, name);
}

fn wire_id(node: &Value, key: &str) -> Option<u16> {
    node.get(key).map(|id| u16::try_from(id.as_u64().unwrap()).unwrap())
}

fn family_name(doc: &Value, family: u8) -> String {
    let families = doc.get("families").and_then(Value::as_object).unwrap();
    let (name, _) = families
        .iter()
        .find(|(_, entry)| entry["id"].as_u64() == Some(u64::from(family)))
        .unwrap_or_else(|| panic!("family 0x{family:02X} not declared"));
    name.clone()
}

/// Every framed method of the schema is in the tables with its attributes,
/// under its id and its name, and the tables hold nothing else.
fn assert_agrees(tables: &MethodTables, sdk: &Value, v2: &Value) {
    let mut v12_count = 0;
    for (name, node) in sdk["commands"].as_object().unwrap() {
        let Some(id) = wire_id(node, "method_id") else {
            assert_eq!(tables.v12_id(name), None, "{name} has no method_id");
            continue;
        };
        let id = MethodId::new(id);
        let attrs = tables.v12(id).unwrap_or_else(|| panic!("{name}: 0x{:04X} missing", id.raw()));
        assert_eq!(attrs.id, id);
        assert!(std::ptr::eq(tables.method(id).unwrap(), attrs));
        assert_eq!(tables.v2(id), None, "{name}");
        assert_eq!(tables.v12_id(name), Some(id));
        check_method(attrs, name, node);
        v12_count += 1;
    }
    let mut v2_count = 0;
    for (name, node) in v2["operations"].as_object().unwrap() {
        let Some(id) = wire_id(node, "method_id") else {
            assert_eq!(tables.v2_id(name), None, "{name} has no method_id");
            continue;
        };
        let id = MethodId::new(id);
        let attrs = tables.v2(id).unwrap_or_else(|| panic!("{name}: 0x{:04X} missing", id.raw()));
        assert!(std::ptr::eq(tables.method(id).unwrap(), attrs));
        assert_eq!(tables.v12(id), None, "{name}");
        assert_eq!(tables.v2_id(name), Some(id));
        check_method(attrs, name, node);
        v2_count += 1;
    }
    let mut event_count = 0;
    for (name, node) in sdk["events"].as_object().unwrap() {
        let Some(id) = wire_id(node, "event_id") else {
            assert_eq!(tables.event_id(name), None, "{name} has no event_id");
            continue;
        };
        let id = EventId::new(id);
        let attrs =
            tables.event(id).unwrap_or_else(|| panic!("{name}: 0x{:04X} missing", id.raw()));
        assert_eq!(attrs.id, id);
        assert_eq!(tables.event_id(name), Some(id));
        check_event(attrs, name, node);
        event_count += 1;
    }

    assert_eq!(tables.v12_families().flat_map(|f| f.iter()).count(), v12_count);
    assert_eq!(tables.v2_families().flat_map(|f| f.iter()).count(), v2_count);
    assert_eq!(tables.event_families().flat_map(|f| f.iter()).count(), event_count);
    for family in tables.v12_families().chain(tables.v2_families()) {
        let doc = if family.id < 0x60 { sdk } else { v2 };
        assert_eq!(family.name, family_name(doc, family.id));
        for (ordinal, slot) in family.entries.iter().enumerate() {
            if let Some(attrs) = slot {
                assert_eq!(attrs.id.family(), family.id);
                assert_eq!(usize::from(attrs.id.ordinal()), ordinal);
            }
        }
        // Dense: the last ordinal is held, so no trailing free slots.
        assert!(family.entries.last().is_some_and(Option::is_some));
    }
    for family in tables.event_families() {
        assert_eq!(family.name, family_name(sdk, family.id));
        assert!(family.entries.last().is_some_and(Option::is_some));
    }
}

#[test]
fn methods_table_fixture_agrees_with_its_schema() {
    let dir = spec_dir().join("fixtures/ipc-method-tables");
    assert_agrees(
        &FIXTURE_TABLES,
        &load(&dir, "sdk-schema.json"),
        &load(&dir, "resource-operations-v2.json"),
    );
}

#[test]
fn methods_table_agrees_with_the_schema() {
    let dir = spec_dir();
    assert_agrees(
        MethodTables::schema(),
        &load(&dir, "sdk-schema.json"),
        &load(&dir, "resource-operations-v2.json"),
    );
}

#[test]
fn methods_table_fixture_lookups() {
    let tables = &FIXTURE_TABLES;
    let send = tables.v12(MethodId::new(0x0100)).unwrap();
    assert_eq!(
        (send.name, send.priority, send.urgent, send.stream_scoped),
        ("send", PriorityHint::Input, true, true)
    );
    assert_eq!((send.id.family(), send.id.ordinal()), (0x01, 0x00));
    assert_eq!(PriorityHint::Input.wire(), 0);
    assert_eq!(PriorityHint::Background.wire(), 3);

    // A free ordinal inside a family, an ordinal past its end, an absent
    // family, and ids of another space are all misses.
    assert_eq!(tables.v12(MethodId::new(0x0101)), None);
    assert_eq!(tables.v12(MethodId::new(0x01FF)), None);
    assert_eq!(tables.v12(MethodId::new(0x0200)), None);
    assert_eq!(tables.method(MethodId::new(0x0000)), None);
    assert_eq!(tables.method(MethodId::new(0xFFFF)), None);
    assert_eq!(tables.v12(MethodId::new(0x6000)), None);
    assert_eq!(tables.event(EventId::new(0x0100)), None);
    assert_eq!(tables.event(EventId::new(0xC001)).map(|e| e.name), Some("size-state"));
    assert_eq!(tables.event(EventId::new(0xC201)), None);

    let new_tab = tables.method(MethodId::new(0x0300)).unwrap();
    assert_eq!((new_tab.name, new_tab.durability), ("new-tab", Durability::ReplyBeforeJournal));
    let close = tables.v12(tables.v12_id("close-tab").unwrap()).unwrap();
    assert_eq!(
        (close.ordering, close.durability, close.payload),
        (Ordering::Sequence, Durability::ReplyAfterJournal, Payload::Json)
    );
    let binary = tables.v12(tables.v12_id("send-binary").unwrap()).unwrap();
    assert_eq!(
        (binary.payload, binary.max_bytes),
        (Payload::Binary { layout_version: 1 }, Some(65536))
    );
    let scroll = tables.v12(tables.v12_id("scroll-surface").unwrap()).unwrap();
    assert_eq!(
        scroll.coalesce.map(|c| (c.key, c.additive)),
        Some((&["surface"][..], &["delta"][..]))
    );

    let history = tables.method(tables.v2_id("workspace.read_history").unwrap()).unwrap();
    assert_eq!(
        (history.id.raw(), history.priority, history.ordering),
        (0x6203, PriorityHint::Bulk, Ordering::Independent)
    );
    // The Rust tables hold every framed method, whatever its clients: the
    // daemon serves the CLI and the SDK too. The Swift table leaves these out.
    let inventory = tables.v12(MethodId::new(0x0302)).unwrap();
    assert_eq!((inventory.name, inventory.durability), ("tab-inventory", Durability::ReadOnly));
    assert_eq!(tables.v12_id("attach-cli"), Some(MethodId::new(0x0105)));
    assert_eq!(tables.v2_id("agent.attach_cli"), Some(MethodId::new(0x6002)));

    // Names are per id space: a v2 name is no v12 command.
    assert_eq!(tables.v12_id("agent.list"), None);
    assert_eq!(tables.v2_id("send"), None);
    assert_eq!(tables.v12_id("unframed-legacy"), None);
    assert_eq!(tables.v12_id(""), None);
}

// The reader refuses what the tables cannot encode -------------------------

fn sdk(families: Value, commands: Value, events: Value) -> Value {
    json!({ "families": families, "commands": commands, "events": events })
}

fn v2_empty() -> Value {
    json!({ "operations": {} })
}

fn refused(sdk: &Value, v2: &Value) -> String {
    let error = reader::read(sdk, v2).expect_err("schema must be refused");
    error.to_string()
}

#[test]
fn methods_table_refuses_a_duplicate_id() {
    let doc = sdk(
        json!({ "tabs": { "id": 3, "description": "" } }),
        json!({
            "a": { "method_id": 0x0300, "priority": "control", "durability": "memory" },
            "b": { "method_id": 0x0300, "priority": "control", "durability": "memory" }
        }),
        json!({}),
    );
    let message = refused(&doc, &v2_empty());
    assert!(message.contains("$.commands.b.method_id"), "{message}");
    assert!(message.contains("also held by \"a\""), "{message}");
}

#[test]
fn methods_table_refuses_an_undeclared_or_foreign_family() {
    let undeclared = sdk(
        json!({}),
        json!({ "a": { "method_id": 0x0300, "priority": "control", "durability": "memory" } }),
        json!({}),
    );
    assert!(refused(&undeclared, &v2_empty()).contains("not declared"));

    // An event id in the command space.
    let foreign = sdk(
        json!({ "ev": { "id": 0xC0, "description": "" } }),
        json!({ "a": { "method_id": 0xC000, "priority": "control", "durability": "memory" } }),
        json!({}),
    );
    assert!(refused(&foreign, &v2_empty()).contains("outside families 0x01-0x5F"));

    // A v2 family declared in sdk-schema.json.
    let v2_in_sdk =
        sdk(json!({ "agent": { "id": 0x60, "description": "" } }), json!({}), json!({}));
    assert!(refused(&v2_in_sdk, &v2_empty()).contains("outside this file's family ranges"));

    // Two families with one id.
    let twice = sdk(
        json!({ "a": { "id": 3, "description": "" }, "b": { "id": 3, "description": "" } }),
        json!({}),
        json!({}),
    );
    assert!(refused(&twice, &v2_empty()).contains("is also family"));
}

#[test]
fn methods_table_refuses_attributes_it_cannot_encode() {
    let families = json!({ "tabs": { "id": 3, "description": "" } });
    let cases = [
        (json!({ "method_id": 0x0300 }), "needs priority"),
        (json!({ "method_id": 0x0300, "priority": "urgent" }), "must be one of input"),
        (
            json!({ "method_id": 0x0300, "priority": "input", "payload": "binary" }),
            "layout version",
        ),
        (json!({ "method_id": 0x0300, "priority": "input", "layout_version": 1 }), "needs payload"),
        (json!({ "method_id": 0x0300, "priority": "input", "max_bytes": 33554433 }), "max_bytes"),
        (
            json!({ "method_id": 0x0300, "priority": "input", "crosses_stream_ok": " " }),
            "non-empty reason",
        ),
        (
            json!({ "method_id": 0x0300, "priority": "input", "durability": "memory", "stream_scoped": "yes" }),
            "boolean",
        ),
        (json!({ "method_id": 65536, "priority": "input" }), "must be a u16"),
        (
            json!({ "method_id": 0x0300, "priority": "input", "durability": "memory", "coalesce": { "key": [1] } }),
            "field names",
        ),
        // Durability has no default: a framed command states it.
        (json!({ "method_id": 0x0300, "priority": "control" }), "needs durability"),
        (
            json!({ "method_id": 0x0300, "priority": "control", "durability": "journal" }),
            "must be one of read_only",
        ),
        (
            json!({ "method_id": 0x0300, "priority": "control", "durability": "memory", "clients": [] }),
            "$.commands.a.clients",
        ),
        (
            json!({ "method_id": 0x0300, "priority": "control", "durability": "memory", "clients": "macos" }),
            "non-empty array of client names",
        ),
    ];
    for (command, expected) in cases {
        let doc = sdk(families.clone(), json!({ "a": command }), json!({}));
        let message = refused(&doc, &v2_empty());
        assert!(message.contains(expected), "{command}: {message}");
    }
}

#[test]
fn methods_table_refuses_v2_ids_outside_the_v2_families() {
    let v2 = json!({
        "families": { "agent": { "id": 0x60, "description": "" } },
        "operations": { "agent.list": { "method_id": 0x0100, "priority": "control", "durability": "memory" } }
    });
    let message = refused(&sdk(json!({}), json!({}), json!({})), &v2);
    assert!(
        message.starts_with("resource-operations-v2.json: $.operations.agent.list.method_id"),
        "{message}"
    );
}

#[test]
fn methods_table_emit_is_deterministic() {
    let dir = spec_dir().join("fixtures/ipc-method-tables");
    let sdk = load(&dir, "sdk-schema.json");
    let v2 = load(&dir, "resource-operations-v2.json");
    let first = reader::emit(&reader::read(&sdk, &v2).unwrap(), "T");
    let second = reader::emit(&reader::read(&sdk, &v2).unwrap(), "T");
    assert_eq!(first, second);
}
