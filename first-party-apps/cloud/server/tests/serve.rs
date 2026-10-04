//! The op loop end to end over the JSON-lines channel: result first, then the
//! projection events; stray relay answers get no reply.

use cmux_cloud::api::{HostRelay, serve};
use serde_json::Value;
use std::io::Cursor;

#[test]
fn a_mutation_answers_then_emits_its_event() {
    let list = std::fs::read_to_string(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/tests/fixtures/vm-list.json"
    ))
    .expect("fixture");
    let body: Value = serde_json::from_str::<Value>(&list).expect("JSON")["body"].clone();
    let input = format!(
        "{}\n{}\n{}\n",
        r#"{"type":"relay.response","id":"r99","status":200}"#,
        r#"{"type":"op","id":"1","op":"cloud.machine.list","origin":"user"}"#,
        serde_json::json!({ "type": "relay.response", "id": "r1", "status": 200, "body": body }),
    );
    let mut out = Vec::new();
    serve(HostRelay::new(Cursor::new(input), &mut out)).expect("serve");
    let lines: Vec<Value> = String::from_utf8(out)
        .expect("utf8")
        .lines()
        .map(|l| serde_json::from_str(l).expect("JSON line"))
        .collect();
    let kinds: Vec<&str> = lines.iter().map(|l| l["type"].as_str().expect("type")).collect();
    assert_eq!(kinds, ["relay.request", "result", "event"], "{lines:?}");
    assert_eq!(lines[0]["path"], "/api/vm");
    assert_eq!(lines[1]["id"], "1");
    assert_eq!(lines[1]["ok"], true);
    assert_eq!(lines[2]["event"], "cloud.machine.changed");
    assert_eq!(lines[2]["change"], "reset");
    assert_eq!(lines[2]["revision"], 1);
}
