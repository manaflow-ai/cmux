//! `cloud.file.transfer.cancel`: a running transfer stops, its end is one
//! `cloud.file.transfer.changed` event with state `cancelled`, a cancelled
//! pull leaves no file, and a cancel of an ended transfer changes nothing.

mod attach_common;
mod common;
mod edge_common;
mod serve_common;

use attach_common::{FakeSpawner, FakeTransport, attach};
use cmux_cloud::ports::Edge;
use edge_common::{FakeTransfer, FakeTunnel};
use serde_json::{Value, json};
use serve_common::Host;
use std::path::{Path, PathBuf};
use std::sync::Arc;

const FIXTURES: &[&str] = &["vm-get", "connect-info-fs"];

fn host(transfer: &FakeTransfer) -> Host {
    let spawner = FakeSpawner::default();
    let attach = attach(&spawner, &FakeTransport::default());
    let edge = Edge::new(Arc::new(FakeTunnel::default()), Box::new(transfer.clone()));
    Host::start_with(FIXTURES, spawner, attach, edge)
}

fn folder(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("cmux-c12-cancel-{}-{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn entries(dir: &Path) -> Vec<String> {
    std::fs::read_dir(dir)
        .unwrap()
        .filter_map(Result::ok)
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .collect()
}

/// Every line up to the result of op `id`, and that result.
fn until_result(host: &mut Host, id: &str) -> (Vec<Value>, Option<Value>) {
    let mut seen = Vec::new();
    while let Some(line) = host.next() {
        if line["type"] == "result" && line["id"] == id {
            return (seen, Some(line));
        }
        seen.push(line);
    }
    (seen, None)
}

fn changed(lines: &[Value]) -> Vec<Value> {
    lines.iter().filter(|l| l["event"] == "cloud.file.transfer.changed").cloned().collect()
}

fn op(host: &Host, id: &str, op: &str, args: Value, key: Option<&str>) {
    let mut line = json!({ "type": "op", "id": id, "op": op, "args": args, "origin": "user" });
    if let Some(key) = key {
        line["idempotency_key"] = json!(key);
    }
    host.send(&line);
}

#[test]
fn a_cancelled_pull_stops_emits_one_cancelled_event_and_leaves_no_file() {
    let dir = folder("pull");
    let target = dir.join("notes.txt");
    let transfer = FakeTransfer::default();
    transfer.log().until_cancel = true;
    let mut host = host(&transfer);
    op(
        &host,
        "1",
        "cloud.file.pull",
        json!({ "machine": "vm-alpha01", "localPath": target, "path": "/home/cmux/notes.txt" }),
        Some("p-1"),
    );
    let (_, started) = until_result(&mut host, "1");
    let started = started.expect("the pull answers");
    assert_eq!(started["result"]["state"], "running", "{started}");
    let id = started["result"]["transfer"].clone();
    op(&host, "2", "cloud.file.transfer.cancel", json!({ "transfer": id }), Some("c-1"));
    let (mut lines, cancelled) = until_result(&mut host, "2");
    let cancelled = cancelled.expect("the cancel answers");
    assert_eq!(cancelled["ok"], true, "{cancelled}");
    assert_eq!(cancelled["result"]["state"], "cancelling", "{cancelled}");
    // A read op after the event: every line the cancel caused came by its result.
    while changed(&lines).is_empty() {
        let Some(line) = host.next() else { break };
        lines.push(line);
    }
    op(&host, "3", "cloud.port.list", json!({}), None);
    let (after, _) = until_result(&mut host, "3");
    lines.extend(after);
    let events = changed(&lines);
    assert_eq!(events.len(), 1, "exactly one changed event: {events:?}");
    assert_eq!(events[0]["transfer"], id);
    assert_eq!(events[0]["state"], "cancelled", "{}", events[0]);
    assert_eq!(transfer.log().cancelled, 1, "the copy saw its cancel");
    assert!(entries(&dir).is_empty(), "a cancelled pull leaves nothing: {:?}", entries(&dir));
    // A second cancel of the same transfer (a new key) changes nothing.
    op(&host, "4", "cloud.file.transfer.cancel", json!({ "transfer": id }), Some("c-2"));
    let (lines, again) = until_result(&mut host, "4");
    assert_eq!(again.map(|r| r["result"]["state"].clone()), Some(json!("ended")));
    assert!(changed(&lines).is_empty());
}

#[test]
fn a_cancel_of_an_ended_transfer_answers_ended_and_emits_nothing() {
    let dir = folder("push");
    let local = dir.join("upload.txt");
    std::fs::write(&local, b"payload").unwrap();
    let transfer = FakeTransfer::default();
    let mut host = host(&transfer);
    op(
        &host,
        "1",
        "cloud.file.push",
        json!({ "machine": "vm-alpha01", "localPath": local, "path": "/home/cmux/upload.txt" }),
        Some("p-1"),
    );
    let (_, started) = until_result(&mut host, "1");
    let id = started.expect("the push answers")["result"]["transfer"].clone();
    let mut done = None;
    while let Some(line) = host.next() {
        if line["event"] == "cloud.file.transfer.changed" {
            done = Some(line);
            break;
        }
    }
    assert_eq!(done.map(|d| d["state"].clone()), Some(json!("done")));
    op(&host, "2", "cloud.file.transfer.cancel", json!({ "transfer": id }), Some("c-1"));
    let (lines, answer) = until_result(&mut host, "2");
    let answer = answer.expect("the cancel answers");
    assert_eq!(answer["ok"], true, "{answer}");
    assert_eq!(answer["result"], json!({ "ok": true, "transfer": id, "state": "ended" }));
    op(&host, "3", "cloud.port.list", json!({}), None);
    let (after, _) = until_result(&mut host, "3");
    assert!(changed(&lines).is_empty() && changed(&after).is_empty(), "no new event");
    op(
        &host,
        "4",
        "cloud.file.transfer.cancel",
        json!({ "transfer": "transfer-999" }),
        Some("c-2"),
    );
    let (_, unknown) = until_result(&mut host, "4");
    let unknown = unknown.expect("the cancel answers");
    assert_eq!(unknown["error"]["code"], "cmux.cloud.not_found", "{unknown}");
}
