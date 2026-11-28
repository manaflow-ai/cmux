//! The op loop end to end over the JSON-lines channel: result first, then the
//! `cloud.machine.watch` events; stray relay answers get no reply; a team
//! wire event updates the projection and emits its watch event at once.

mod common;

use cmux_cloud::api::{HostRelay, serve};
use common::wire_common::vectors;
use serde_json::{Value, json};
use std::io::Cursor;

fn run(input: String) -> Vec<Value> {
    let mut out = Vec::new();
    serve(HostRelay::new(Cursor::new(input), &mut out)).expect("serve");
    String::from_utf8(out)
        .expect("utf8")
        .lines()
        .map(|l| serde_json::from_str(l).expect("JSON line"))
        .collect()
}

fn default_list() -> Value {
    let doc = vectors();
    doc["cases"]
        .as_array()
        .expect("cases")
        .iter()
        .find(|c| c["name"] == "machine.list.default")
        .expect("default list")["responses"][0]["body"]["value"]
        .clone()
}

#[test]
fn a_list_answers_then_emits_its_events() {
    let input = format!(
        "{}\n{}\n{}\n",
        r#"{"type":"relay.result","id":"r99","ok":true,"value":{}}"#,
        r#"{"type":"op","id":"1","op":"cloud.machine.list","origin":"user"}"#,
        json!({ "type": "relay.result", "id": "r1", "ok": true, "value": default_list(), "revision": "41" }),
    );
    let lines = run(input);
    // The server asks for the link details before anything else.
    assert_eq!(
        lines[0],
        json!({ "t": "host.request", "id": 1, "op": "cmux.host.link.get", "params": {} })
    );
    let lines = &lines[1..];
    let kinds: Vec<&str> = lines.iter().map(|l| l["type"].as_str().expect("type")).collect();
    // The list fills an empty projection: one upsert per machine, one revision.
    assert_eq!(kinds, ["relay.op", "result", "event", "event", "event"], "{lines:?}");
    assert_eq!(lines[0]["op"], "cloud.machine.list");
    assert_eq!(lines[0]["params"], json!({}));
    assert!(lines[0].get("idempotency_key").is_none(), "a read carries no key");
    assert_eq!(lines[1]["id"], "1");
    assert_eq!(lines[1]["ok"], true);
    assert_eq!(lines[1]["result"]["revision"], 1);
    for (line, id) in lines[2..].iter().zip([common::vm(1), common::vm(2), common::vm(3)]) {
        assert_eq!(line["event"], "cloud.machine.watch");
        assert_eq!(line["data"]["type"], "upsert");
        assert_eq!(line["data"]["revision"], 1);
        assert_eq!(line["data"]["machine"]["id"], id);
    }
}

#[test]
fn a_team_event_line_updates_the_projection_with_no_answer() {
    let doc = vectors();
    let event = doc["events"]
        .as_array()
        .expect("events")
        .iter()
        .find(|e| e["name"] == "machine.upsert.new")
        .expect("event")
        .clone();
    let input = format!(
        "{}\n{}\n",
        json!({ "type": "team.event", "event": event["event"], "data": event["data"] }),
        json!({ "type": "team.event", "event": "cloud.unknown.thing", "data": {} }),
    );
    let lines = run(input);
    let lines = &lines[1..];
    assert_eq!(lines.len(), 1, "one watch event, no result line: {lines:?}");
    assert_eq!(lines[0]["event"], "cloud.machine.watch");
    assert_eq!(lines[0]["data"]["machine"]["id"], common::vm(8));
}
