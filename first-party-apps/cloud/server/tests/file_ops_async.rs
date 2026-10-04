//! File ops never hold the op loop (coordinator MUST-FIX, 2026-10-04): each
//! runs on its own worker with a bound on how many run; a slow op does not
//! delay another; a client that goes away cancels its ops; and the
//! `connect_info` read that gates them is cached with an expiry.

mod attach_common;
mod common;
mod edge_common;
mod serve_common;

use attach_common::{FakeSpawner, FakeTransport, attach};
use cmux_cloud::clock::{Clock, Timer};
use cmux_cloud::fs::{Cancel, DaemonFiles, DialTarget};
use cmux_cloud::ports::Edge;
use cmux_cloud::{CloudError, Request, Server};
use common::FakeControlPlane;
use edge_common::{FakeFiles, FakeTransfer, FakeTunnel};
use serde_json::{Value, json};
use serve_common::Host;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{Receiver, Sender, channel};
use std::sync::{Arc, Mutex};
use std::time::Duration;

const FIXTURES: &[&str] = &["vm-get", "connect-info-fs"];

/// Daemon file ops where `/slow` waits until released or cancelled.
struct GatedFiles {
    gate: Mutex<Receiver<&'static str>>,
    opener: Sender<&'static str>,
    cancelled: Arc<Mutex<Vec<String>>>,
}

impl DaemonFiles for GatedFiles {
    fn call(
        &self,
        _target: &DialTarget,
        _op: &str,
        params: Value,
        cancel: &Cancel,
    ) -> Result<Value, CloudError> {
        let path = params["path"].as_str().unwrap_or_default().to_owned();
        if path == "/slow" {
            let opener = self.opener.clone();
            let cancelled = Arc::clone(&self.cancelled);
            cancel.on_cancel(move || {
                cancelled.lock().unwrap().push(path);
                let _ = opener.send("cancelled");
            });
            if self.gate.lock().unwrap().recv() != Ok("release") {
                return Err(CloudError::new("cmux.cloud.link_down", "cancelled"));
            }
        }
        Ok(json!({ "name": "x", "kind": "file", "size": 1, "mtime": 1.0 }))
    }
}

fn gated() -> (Arc<GatedFiles>, Sender<&'static str>) {
    let (opener, gate) = channel();
    let files = Arc::new(GatedFiles {
        gate: Mutex::new(gate),
        opener: opener.clone(),
        cancelled: Arc::default(),
    });
    (files, opener)
}

fn host(files: Arc<GatedFiles>) -> Host {
    let spawner = FakeSpawner::default();
    let attach = attach(&spawner, &FakeTransport::default());
    let edge = Edge::new(Arc::new(FakeTunnel::default()), Box::new(FakeTransfer::default()))
        .with_files(files);
    Host::start_with(FIXTURES, spawner, attach, edge)
}

fn stat(host: &Host, id: &str, path: &str) {
    host.send(&json!({ "type": "op", "id": id, "op": "cloud.fs.stat",
        "args": { "machine": "vm-alpha01", "path": path } }));
}

/// The result line of op `id` within `wait`, other lines skipped.
fn result_within(host: &mut Host, id: &str, wait: Duration) -> Option<Value> {
    let until = std::time::Instant::now() + wait;
    while let Some(line) = host.next_within(until.saturating_duration_since(std::time::Instant::now()))
    {
        if line["type"] == "result" && line["id"] == id {
            return Some(line);
        }
    }
    None
}

#[test]
fn a_slow_file_op_does_not_hold_a_second_one() {
    let (files, release) = gated();
    let mut host = host(files);
    stat(&host, "slow", "/slow");
    stat(&host, "fast", "/fast");
    let fast = result_within(&mut host, "fast", Duration::from_secs(5));
    let _ = release.send("release");
    assert!(fast.is_some_and(|l| l["ok"] == true), "the second op answered while the first waits");
    let slow = result_within(&mut host, "slow", Duration::from_secs(5));
    assert!(slow.is_some_and(|l| l["ok"] == true), "the slow op answers when released");
}

#[test]
fn a_client_that_goes_away_cancels_its_file_ops() {
    let (files, release) = gated();
    let cancelled = Arc::clone(&files.cancelled);
    let mut host = host(files);
    stat(&host, "slow", "/slow");
    // Let the op start (its connect_info read is answered on the way).
    let _ = result_within(&mut host, "none", Duration::from_millis(300));
    host.close_input();
    let mut seen = false;
    for _ in 0..200 {
        if !cancelled.lock().unwrap().is_empty() {
            seen = true;
            break;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    // Unblock a server that did not cancel, so the test can end.
    let _ = release.send("release");
    assert!(seen, "the end of the host's input cancelled the running op");
}

#[test]
fn too_many_running_file_ops_answer_busy_at_once() {
    let (files, release) = gated();
    let mut host = host(files);
    let max = cmux_cloud::fs::MAX_FILE_OPS;
    for n in 0..max {
        stat(&host, &format!("slow-{n}"), "/slow");
    }
    stat(&host, "extra", "/fast");
    let extra = result_within(&mut host, "extra", Duration::from_secs(5));
    for _ in 0..max {
        let _ = release.send("release");
    }
    let extra = extra.expect("the extra op answers at once");
    assert_eq!(extra["error"]["code"], "cmux.cloud.file_ops_busy", "{extra}");
    assert_eq!(extra["error"]["retryable"], true);
}

/// A clock whose `now` the test sets.
#[derive(Clone, Default)]
struct TestClock(Arc<AtomicU64>);

impl Clock for TestClock {
    fn after(&self, _delay: Duration, _fire: Box<dyn FnOnce() + Send>) -> Timer {
        Timer::new(Box::new(|| {}))
    }
    fn now_unix_ms(&self) -> u64 {
        self.0.load(Ordering::SeqCst)
    }
}

#[test]
fn the_connect_info_gate_is_cached_until_it_expires_or_the_machine_changes() {
    let clock = TestClock::default();
    clock.0.store(1_000_000, Ordering::SeqCst);
    let files = FakeFiles::default();
    files.answer("fs.stat", json!({ "name": "x", "kind": "file", "size": 1 }));
    let spawner = FakeSpawner::default();
    let edge = Edge::new(Arc::new(FakeTunnel::default()), Box::new(FakeTransfer::default()))
        .with_files(Arc::new(files));
    let mut s = Server::with_parts(
        FakeControlPlane::with(FIXTURES),
        attach(&spawner, &FakeTransport::default()).with_info_clock(Arc::new(clock.clone())),
        edge,
    );
    let reads = |s: &Server<FakeControlPlane>| {
        s.control_plane().ops().iter().filter(|o| *o == "cloud.machine.connect_info").count()
    };
    let op = || Request::new("cloud.fs.stat", json!({ "machine": "vm-alpha01", "path": "/a" }));
    s.handle(&op()).expect("stat");
    s.handle(&op()).expect("stat");
    assert_eq!(reads(&s), 1, "one read for two ops");
    clock.0.fetch_add(301_000, Ordering::SeqCst);
    s.handle(&op()).expect("stat");
    assert_eq!(reads(&s), 2, "an entry older than 300 s is read again");
    s.team_event("cloud.machine.removed", &json!({ "machine": "vm-alpha01", "revision": "9" }))
        .expect("event");
    s.handle(&op()).expect("stat");
    assert_eq!(reads(&s), 3, "a machine change drops the entry");
}
