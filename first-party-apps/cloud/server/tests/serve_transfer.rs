//! File transfers run off the op loop: `cloud.file.push` answers at once
//! with a transfer id, other ops run while the copy runs, and the end
//! arrives as a `cloud.file.transfer.changed` event.

mod attach_common;
mod common;
mod edge_common;
mod serve_common;

use attach_common::{FakeSpawner, FakeTransport, attach};
use cmux_cloud::ports::Edge;
use edge_common::{FakeTransfer, FakeTunnel};
use serde_json::{Value, json};
use serve_common::Host;
use std::sync::Arc;
use std::sync::mpsc::channel;

const FIXTURES: &[&str] = &["vm-get", "attach_endpoint_alpha", "scp-endpoint"];

fn host(transfer: &FakeTransfer) -> Host {
    let spawner = FakeSpawner::default();
    let attach = attach(&spawner, &FakeTransport::default());
    let edge = Edge::new(Arc::new(FakeTunnel::default()), Box::new(transfer.clone()));
    Host::start_with(FIXTURES, spawner, attach, edge)
}

fn local_file() -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!("cmux-c10-transfer-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join("upload.txt");
    std::fs::write(&file, b"payload").unwrap();
    file
}

/// The result line of op `id`, or `None` when none came in time.
fn result_of(host: &mut Host, id: &str) -> Option<Value> {
    while let Some(line) = host.next() {
        if line["type"] == "result" && line["id"] == id {
            return Some(line);
        }
    }
    None
}

#[test]
fn a_push_answers_before_the_copy_ends_and_its_end_is_an_event() {
    let transfer = FakeTransfer::default();
    let (release, hold) = channel();
    transfer.log().hold = Some(hold);
    let mut host = host(&transfer);
    host.send(&json!({ "type": "op", "id": "1", "op": "cloud.file.push", "origin": "user",
        "idempotency_key": "p-1",
        "args": { "machine": "vm-alpha01", "localPath": local_file(), "path": "/home/cmux/upload.txt" } }));
    let started = result_of(&mut host, "1");
    assert_eq!(
        started.as_ref().map(|r| (r["ok"].clone(), r["result"]["state"].clone())),
        Some((json!(true), json!("running"))),
        "the op answers while the copy is held: {started:?}"
    );
    let id = started.as_ref().map(|r| r["result"]["transfer"].clone()).unwrap_or_default();
    assert!(id.as_str().is_some_and(|t| !t.is_empty()), "a transfer id: {started:?}");
    host.send(&json!({ "type": "op", "id": "2", "op": "cloud.port.list", "args": {} }));
    let read = result_of(&mut host, "2");
    assert_eq!(read.map(|r| r["ok"].clone()), Some(json!(true)), "other ops run meanwhile");
    assert!(transfer.log().jobs.is_empty(), "the copy has not ended yet");
    release.send(()).unwrap();
    let mut changed = None;
    while let Some(line) = host.next() {
        if line["event"] == "cloud.file.transfer.changed" {
            changed = Some(line);
            break;
        }
    }
    let changed = changed.expect("a cloud.file.transfer.changed line after the release");
    assert_eq!(changed["transfer"], id);
    assert_eq!(changed["state"], "done", "{changed}");
    assert_eq!(changed["machine"], "vm-alpha01");
    assert_eq!(changed["direction"], "push");
    assert_eq!(changed["bytes"], 42);
    assert_eq!(transfer.log().jobs.len(), 1);
}
