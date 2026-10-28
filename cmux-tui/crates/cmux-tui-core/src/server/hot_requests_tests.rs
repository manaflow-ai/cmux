//! A binary request decodes into the `Command` its JSON line parses to
//! (spec/fixtures/ipc-hot-codec/golden.json), and every binary method of the
//! schema is one this daemon decodes.

use std::path::PathBuf;

use cmux_ipc::{MethodTables, Payload};
use serde_json::{Value, json};

use super::{decode, decodes};
use crate::server::{Command, Request};

fn golden_request(name: &str) -> (Value, Vec<u8>) {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../spec/fixtures/ipc-hot-codec/golden.json");
    let doc: Value = serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
    let case = doc["cases"]
        .as_array()
        .unwrap()
        .iter()
        .find(|case| case["name"] == name && case["part"] == "request")
        .unwrap_or_else(|| panic!("no golden request of {name}"))
        .clone();
    let hex = case["hex"].as_str().unwrap();
    let bytes = (0..hex.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(hex.get(i..i + 2).unwrap(), 16).unwrap())
        .collect();
    let mut line = case["json"].clone();
    line["cmd"] = json!(name);
    (line, bytes)
}

/// The golden request of `name`: its bytes decoded, and its JSON parsed.
fn both(name: &str) -> (Command, Command) {
    let tables = MethodTables::schema();
    let method = tables.v12_id(name).and_then(|id| tables.method(id)).unwrap();
    let (line, bytes) = golden_request(name);
    let decoded: Request = decode(method, &bytes).expect("a layout").expect("the golden bytes");
    assert!(decoded.id.is_none(), "a binary request has no id");
    let parsed: Request = serde_json::from_value(line).unwrap();
    (decoded.cmd, parsed.cmd)
}

#[test]
fn hot_requests_decode_to_the_command_their_line_parses_to() {
    match both("resize-attached-view") {
        (
            Command::ResizeAttachedView { surface, lease, view, identity, cols, rows, stream },
            Command::ResizeAttachedView {
                surface: s2,
                lease: l2,
                view: v2,
                identity: i2,
                cols: c2,
                rows: r2,
                stream: st2,
            },
        ) => {
            assert_eq!((surface, lease, view, cols, rows, stream), (s2, l2, v2, c2, r2, st2));
            assert_eq!(format!("{identity:?}"), format!("{i2:?}"));
            assert!(identity.is_some(), "the golden case has an identity");
        }
        _ => panic!("resize-attached-view"),
    }
    match both("set-client-sizing") {
        (
            Command::SetClientSizing { surface, client, enabled, exclusive },
            Command::SetClientSizing { surface: s2, client: c2, enabled: e2, exclusive: x2 },
        ) => assert_eq!((surface, client, enabled, exclusive), (s2, c2, e2, x2)),
        _ => panic!("set-client-sizing"),
    }
    match both("scroll-surface") {
        (Command::ScrollSurface(decoded), Command::ScrollSurface(parsed)) => {
            assert_eq!(format!("{decoded:?}"), format!("{parsed:?}"));
        }
        _ => panic!("scroll-surface"),
    }
    match both("snapshot-request") {
        (Command::SnapshotRequest(decoded), Command::SnapshotRequest(parsed)) => {
            assert_eq!(format!("{decoded:?}"), format!("{parsed:?}"));
            assert!(decoded.have.is_some(), "the golden case has a have");
        }
        _ => panic!("snapshot-request"),
    }
}

/// An absent `exclusive` is `false`, as its line's `#[serde(default)]`.
#[test]
fn hot_requests_an_absent_exclusive_is_false() {
    use cmux_ipc::hot::{SET_CLIENT_SIZING_REQUEST, SetClientSizingRequest};
    let tables = MethodTables::schema();
    let method = tables.v12_id("set-client-sizing").and_then(|id| tables.method(id)).unwrap();
    let mut bytes = Vec::new();
    let body = SetClientSizingRequest { client: None, enabled: true, exclusive: None, surface: 4 };
    SET_CLIENT_SIZING_REQUEST.encode(&body, &mut bytes).unwrap();
    match decode(method, &bytes).unwrap().unwrap().cmd {
        Command::SetClientSizing { surface: 4, client: None, enabled: true, exclusive } => {
            assert!(!exclusive);
        }
        _ => panic!("set-client-sizing"),
    }
}

/// Every `payload: "binary"` command of the schema is one this daemon reads
/// the layout of, and no JSON command is.
#[test]
fn hot_requests_cover_every_binary_command() {
    let tables = MethodTables::schema();
    for method in tables.v12_families().flat_map(|family| family.iter()) {
        let binary = matches!(method.payload, Payload::Binary { .. });
        assert_eq!(decodes(method), binary, "{}", method.name);
        if binary {
            assert!(Command::method_of_wire(method.name).is_some(), "{}", method.name);
        }
    }
    assert!(
        tables
            .v2_families()
            .flat_map(|family| family.iter())
            .all(|method| { method.payload == Payload::Json })
    );
}
