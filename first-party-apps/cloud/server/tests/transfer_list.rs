//! `cloud.file.transfer.list`: running transfers and a bounded history of
//! finished ones (at most 32, none older than an hour by the injected
//! clock), so a new page session can show them again.

mod attach_common;
mod common;
mod edge_common;

use attach_common::{FakeSpawner, FakeTransport, attach};
use cmux_cloud::clock::{Clock, Timer};
use cmux_cloud::ports::Edge;
use cmux_cloud::{Origin, Request, Server};
use common::FakeControlPlane;
use edge_common::{FakeTransfer, FakeTunnel};
use serde_json::{Value, json};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::channel;

const FIXTURES: &[&str] = &["vm-get", "attach_endpoint_alpha", "scp-endpoint"];
const HOUR_MS: u64 = 60 * 60 * 1000;

/// Time the test sets; its timers never fire.
#[derive(Clone, Default)]
struct TestClock(Arc<AtomicU64>);

impl Clock for TestClock {
    fn after(&self, _: std::time::Duration, _: Box<dyn FnOnce() + Send>) -> Timer {
        Timer::new(Box::new(|| {}))
    }
    fn now_unix_ms(&self) -> u64 {
        self.0.load(Ordering::SeqCst)
    }
}

fn server(transfer: &FakeTransfer, clock: &TestClock) -> Server<FakeControlPlane> {
    let edge = Edge::new(Arc::new(FakeTunnel::default()), Box::new(transfer.clone()))
        .with_clock(Arc::new(clock.clone()));
    Server::with_parts(
        FakeControlPlane::with(FIXTURES),
        attach(&FakeSpawner::default(), &FakeTransport::default()),
        edge,
    )
}

fn local() -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!("cmux-c12-list-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join("upload.txt");
    std::fs::write(&file, b"payload").unwrap();
    file
}

fn push(s: &mut Server<FakeControlPlane>, key: &str) -> String {
    let request = Request::new(
        "cloud.file.push",
        json!({ "machine": "vm-alpha01", "localPath": local(), "path": "/home/cmux/a" }),
    )
    .key(key)
    .origin(Origin::User);
    s.handle(&request).expect("push")["transfer"].as_str().expect("id").to_owned()
}

fn list(s: &mut Server<FakeControlPlane>) -> Vec<Value> {
    let answer = s.handle(&Request::new("cloud.file.transfer.list", json!({}))).expect("list");
    answer["transfers"].as_array().expect("transfers").clone()
}

fn states_are_known(entries: &[Value]) {
    for entry in entries {
        let state = entry["state"].as_str().unwrap_or_default();
        assert!(["running", "done", "failed", "cancelled"].contains(&state), "{entry}");
        assert!(["push", "pull"].contains(&entry["direction"].as_str().unwrap_or_default()));
    }
}

#[test]
fn a_running_transfer_is_listed_then_its_end_with_ended_at() {
    let transfer = FakeTransfer::default();
    let clock = TestClock::default();
    clock.0.store(1_000, Ordering::SeqCst);
    let (release, hold) = channel();
    transfer.log().hold = Some(hold);
    let mut s = server(&transfer, &clock);
    let id = push(&mut s, "p-1");
    let running = list(&mut s);
    assert_eq!(running.len(), 1, "{running:?}");
    assert_eq!(running[0]["transfer"], id.as_str());
    assert_eq!(running[0]["state"], "running");
    assert_eq!(running[0]["machine"], "vm-alpha01");
    assert_eq!(running[0]["direction"], "push");
    assert_eq!(running[0]["started_at"], 1_000);
    assert!(running[0].get("ended_at").is_none());
    states_are_known(&running);
    clock.0.store(2_500, Ordering::SeqCst);
    release.send(()).unwrap();
    s.wait_transfers();
    assert_eq!(s.take_transfer_events().len(), 1);
    let ended = list(&mut s);
    assert_eq!(ended.len(), 1, "{ended:?}");
    assert_eq!(ended[0]["state"], "done");
    assert_eq!(ended[0]["started_at"], 1_000);
    assert_eq!(ended[0]["ended_at"], 2_500);
    states_are_known(&ended);
}

#[test]
fn a_cancelled_transfer_is_listed_as_cancelled() {
    let transfer = FakeTransfer::default();
    transfer.log().until_cancel = true;
    let clock = TestClock::default();
    let mut s = server(&transfer, &clock);
    let id = push(&mut s, "p-1");
    let cancel = Request::new("cloud.file.transfer.cancel", json!({ "transfer": id })).key("c-1");
    assert_eq!(s.handle(&cancel).expect("cancel")["state"], "cancelling");
    s.wait_transfers();
    let entries = list(&mut s);
    assert_eq!(entries.len(), 1, "{entries:?}");
    assert_eq!(entries[0]["state"], "cancelled");
    assert!(entries[0]["ended_at"].is_u64());
    states_are_known(&entries);
}

#[test]
fn the_history_keeps_at_most_32_and_drops_the_oldest_and_the_old() {
    let transfer = FakeTransfer::default();
    let clock = TestClock::default();
    let mut s = server(&transfer, &clock);
    let mut ids = Vec::new();
    for n in 0..34u64 {
        clock.0.store(10_000 + n, Ordering::SeqCst);
        ids.push(push(&mut s, &format!("p-{n}")));
        s.wait_transfers();
    }
    let entries = list(&mut s);
    assert_eq!(entries.len(), 32, "at most 32 finished");
    let listed: Vec<&str> = entries.iter().map(|e| e["transfer"].as_str().unwrap()).collect();
    assert_eq!(listed[0], ids[33], "newest end first");
    assert!(!listed.contains(&ids[0].as_str()) && !listed.contains(&ids[1].as_str()), "oldest out");
    assert!(listed.contains(&ids[2].as_str()));
    states_are_known(&entries);
    clock.0.store(10_033 + HOUR_MS + 1, Ordering::SeqCst);
    assert!(list(&mut s).is_empty(), "finished entries older than an hour are gone");
}
