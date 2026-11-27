//! `op.cancel` (coordinator decision 2026-10-04): the host sends
//! `{"type":"op.cancel","id":<op id>}` when its caller drops a request. A
//! running op answers its ORIGINAL id exactly once with
//! `cmux.op.cancelled` and its work stops (a file op's dial child ends); an
//! unknown or finished id gets no reply; a second cancel is a no-op.

mod attach_common;
mod common;
mod edge_common;
mod serve_common;

use attach_common::{FakeSpawner, FakeTransport, attach};
use cmux_cloud::CloudError;
use cmux_cloud::fs::{Cancel, DaemonFiles, DialTarget};
use cmux_cloud::ports::Edge;
use edge_common::{FakeTransfer, FakeTunnel};
use serde_json::{Value, json};
use serve_common::Host;
use std::sync::mpsc::{Receiver, Sender, channel};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

const FIXTURES: &[&str] = &["vm-get", "connect-info-fs"];

/// `/slow` waits until released or cancelled; the cancel is recorded.
struct GatedFiles {
    gate: Mutex<Receiver<&'static str>>,
    opener: Sender<&'static str>,
    cancels: Arc<Mutex<usize>>,
}

impl DaemonFiles for GatedFiles {
    fn call(
        &self,
        _target: &DialTarget,
        _op: &str,
        params: Value,
        cancel: &Cancel,
    ) -> Result<Value, CloudError> {
        if params["path"] == "/slow" {
            let opener = self.opener.clone();
            let cancels = Arc::clone(&self.cancels);
            cancel.on_cancel(move || {
                *cancels.lock().unwrap() += 1;
                let _ = opener.send("cancelled");
            });
            if self.gate.lock().unwrap().recv() != Ok("release") {
                return Err(CloudError::new("cmux.cloud.link_down", "the dial child ended"));
            }
        }
        Ok(json!({ "name": "x", "kind": "file", "size": 1 }))
    }
}

fn host() -> (Host, Sender<&'static str>, Arc<Mutex<usize>>) {
    let (opener, gate) = channel();
    let cancels = Arc::new(Mutex::new(0));
    let files = Arc::new(GatedFiles {
        gate: Mutex::new(gate),
        opener: opener.clone(),
        cancels: Arc::clone(&cancels),
    });
    let spawner = FakeSpawner::default();
    let attach = attach(&spawner, &FakeTransport::default());
    let edge = Edge::new(Arc::new(FakeTunnel::default()), Box::new(FakeTransfer::default()))
        .with_files(files);
    (Host::start_with(FIXTURES, spawner, attach, edge), opener, cancels)
}

fn stat(host: &Host, id: &str, path: &str) {
    host.send(&json!({ "type": "op", "id": id, "op": "cloud.fs.stat",
        "args": { "machine": "vm-alpha01", "path": path } }));
}

fn cancel(host: &Host, id: &str) {
    host.send(&json!({ "type": "op.cancel", "id": id }));
}

/// Every result line for `id` within `wait`.
fn results(host: &mut Host, id: &str, wait: Duration) -> Vec<Value> {
    let until = Instant::now() + wait;
    let mut found = Vec::new();
    while let Some(line) = host.next_within(until.saturating_duration_since(Instant::now())) {
        if line["type"] == "result" && line["id"] == id {
            found.push(line);
        }
    }
    found
}

#[test]
fn a_cancelled_file_op_answers_once_with_op_cancelled_and_stops() {
    let (mut host, release, cancels) = host();
    stat(&host, "slow", "/slow");
    // Let the op start on its worker (its gate read is answered on the way).
    assert!(results(&mut host, "slow", Duration::from_millis(300)).is_empty());
    cancel(&host, "slow");
    let answers = results(&mut host, "slow", Duration::from_secs(2));
    let _ = release.send("release");
    assert_eq!(answers.len(), 1, "exactly one answer: {answers:?}");
    assert_eq!(answers[0]["ok"], false);
    assert_eq!(answers[0]["error"]["code"], "cmux.op.cancelled", "{}", answers[0]);
    assert_eq!(*cancels.lock().unwrap(), 1, "the op's work was cancelled");
    assert!(results(&mut host, "slow", Duration::from_millis(500)).is_empty(), "no late answer");
}

#[test]
fn cancelling_an_unknown_or_finished_op_gets_no_reply() {
    let (mut host, _release, _) = host();
    cancel(&host, "nobody");
    assert!(
        results(&mut host, "nobody", Duration::from_millis(300)).is_empty(),
        "unknown: no reply"
    );
    stat(&host, "fast", "/fast");
    let fast = results(&mut host, "fast", Duration::from_secs(2));
    assert_eq!(fast.len(), 1);
    assert_eq!(fast[0]["ok"], true);
    cancel(&host, "fast");
    assert!(
        results(&mut host, "fast", Duration::from_millis(300)).is_empty(),
        "finished: no reply"
    );
}

#[test]
fn a_second_cancel_is_a_no_op() {
    let (mut host, release, cancels) = host();
    stat(&host, "slow", "/slow");
    assert!(results(&mut host, "slow", Duration::from_millis(300)).is_empty());
    cancel(&host, "slow");
    cancel(&host, "slow");
    let answers = results(&mut host, "slow", Duration::from_secs(2));
    let _ = release.send("release");
    assert_eq!(answers.len(), 1, "one answer for two cancels: {answers:?}");
    assert_eq!(*cancels.lock().unwrap(), 1);
}
