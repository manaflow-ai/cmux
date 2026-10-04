//! The host side of the server's JSON-lines channel for serve-loop tests:
//! the test writes op lines (and host frames), answers each
//! `relay.op` (vectors) and `relay.request` (classic fixtures) through the fake control plane, and
//! reads every line the server writes. The input stays open while the
//! test waits, so only a link or transfer event can wake the loop.

#![allow(dead_code)]

use crate::attach_common::{FakeSpawner, FakeTransport, attach};
use crate::common::FakeControlPlane;
use crate::edge_common::{FakeTransfer, FakeTunnel};
use cmux_cloud::api::{HostRelay, serve_with};
use cmux_cloud::link::Attach;
use cmux_cloud::ports::Edge;
use cmux_cloud::{ControlPlane, HttpCall, WireCall, WireReply};
use serde_json::{Value, json};
use std::io::{self, BufReader, Read, Write};
use std::sync::Arc;
use std::sync::mpsc::{Receiver, RecvTimeoutError, Sender, channel};
use std::thread::JoinHandle;
use std::time::Duration;

/// The bound on each wait for a server line in these tests.
pub const WAIT: Duration = Duration::from_secs(5);

/// Host input: bytes from the test; end of input when the test drops it.
struct Input {
    lines: Receiver<Vec<u8>>,
    pending: Vec<u8>,
}

impl Read for Input {
    fn read(&mut self, out: &mut [u8]) -> io::Result<usize> {
        if self.pending.is_empty() {
            match self.lines.recv() {
                Ok(bytes) => self.pending = bytes,
                Err(_) => return Ok(0),
            }
        }
        let n = out.len().min(self.pending.len());
        out[..n].copy_from_slice(&self.pending[..n]);
        self.pending.drain(..n);
        Ok(n)
    }
}

/// Host output: each complete line goes to the test.
struct Output {
    lines: Sender<String>,
    partial: Vec<u8>,
}

impl Write for Output {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        self.partial.extend_from_slice(bytes);
        while let Some(end) = self.partial.iter().position(|b| *b == b'\n') {
            let line: Vec<u8> = self.partial.drain(..=end).collect();
            let text = String::from_utf8_lossy(&line[..line.len() - 1]).into_owned();
            let _ = self.lines.send(text);
        }
        Ok(bytes.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

pub struct Host {
    input: Option<Sender<Vec<u8>>>,
    output: Receiver<String>,
    pub cloud: FakeControlPlane,
    pub spawner: FakeSpawner,
    serving: Option<JoinHandle<io::Result<()>>>,
}

fn method(name: &str) -> &'static str {
    match name {
        "GET" => "GET",
        "POST" => "POST",
        "PATCH" => "PATCH",
        "PUT" => "PUT",
        "DELETE" => "DELETE",
        other => panic!("unexpected method {other}"),
    }
}

impl Host {
    /// The serve loop with the fake link (test link details already given),
    /// tunnel and transfer.
    pub fn start(fixtures: &[&str]) -> Self {
        let spawner = FakeSpawner::default();
        let attach = attach(&spawner, &FakeTransport::default());
        let edge = Edge::new(Arc::new(FakeTunnel::default()), Box::new(FakeTransfer::default()));
        Self::start_with(fixtures, spawner, attach, edge)
    }

    /// The serve loop with the given attach state and edge; `spawner` is
    /// the fake spawner inside `attach`.
    pub fn start_with(fixtures: &[&str], spawner: FakeSpawner, attach: Attach, edge: Edge) -> Self {
        let (input, lines) = channel();
        let (sink, output) = channel();
        let relay = HostRelay::new(
            BufReader::new(Input { lines, pending: Vec::new() }),
            Output { lines: sink, partial: Vec::new() },
        );
        let serving = std::thread::spawn(move || serve_with(relay, attach, edge));
        Self {
            input: Some(input),
            output,
            cloud: FakeControlPlane::with(fixtures),
            spawner,
            serving: Some(serving),
        }
    }

    pub fn send(&self, line: &Value) {
        let mut bytes = line.to_string().into_bytes();
        bytes.push(b'\n');
        self.input.as_ref().expect("open").send(bytes).expect("server reads");
    }

    /// The next line that is not a relay request; relay requests are
    /// answered from the fixtures on the way. `None` after [`WAIT`].
    pub fn next(&mut self) -> Option<Value> {
        self.next_within(WAIT)
    }

    /// [`Host::next`] with its own bound on the wait.
    pub fn next_within(&mut self, wait: Duration) -> Option<Value> {
        loop {
            let line = match self.output.recv_timeout(wait) {
                Ok(line) => line,
                Err(RecvTimeoutError::Timeout | RecvTimeoutError::Disconnected) => return None,
            };
            let line: Value = serde_json::from_str(&line).expect("JSON line");
            if line["type"] == "relay.op" {
                let call = WireCall {
                    op: line["op"].as_str().expect("op").to_owned(),
                    params: line["params"].clone(),
                    idempotency_key: line["idempotency_key"].as_str().map(str::to_owned),
                };
                let answer = match self.cloud.call(&call).expect("fake reply") {
                    WireReply::Result(r) => json!({ "type": "relay.result", "id": line["id"],
                        "ok": true, "value": r.value, "revision": r.revision, "replayed": r.replayed }),
                    WireReply::Error(e) => json!({ "type": "relay.result", "id": line["id"],
                        "ok": false, "error": { "code": e.code, "message": e.message,
                        "retryable": e.retryable, "details": e.details } }),
                };
                self.send(&answer);
                continue;
            }
            if line["type"] != "relay.request" {
                return Some(line);
            }
            let call = HttpCall {
                op: line["op"].as_str().unwrap_or_default().to_owned(),
                method: method(line["method"].as_str().expect("method")),
                path: line["path"].as_str().expect("path").to_owned(),
                body: line.get("body").cloned(),
                idempotency_key: line["idempotency_key"].as_str().map(str::to_owned),
            };
            let reply = self.cloud.classic(&call).expect("fake reply");
            self.send(&json!({ "type": "relay.response", "id": line["id"],
                "status": reply.status, "body": reply.body }));
        }
    }

    /// Lines up to and including the result of op `id`.
    pub fn answer(&mut self, id: &str) -> Vec<Value> {
        let mut lines = Vec::new();
        loop {
            let line = self.next().unwrap_or_else(|| panic!("no result for op {id}: {lines:?}"));
            let done = line["type"] == "result" && line["id"] == id;
            lines.push(line);
            if done {
                return lines;
            }
        }
    }

    /// The op's result, after the lines that follow it at once (events of
    /// the op) were read.
    pub fn op(&mut self, id: &str, op: &str, args: Value, key: &str) -> Value {
        self.send(&json!({ "type": "op", "id": id, "op": op, "args": args,
            "origin": "user", "idempotency_key": key }));
        let lines = self.answer(id);
        let result = lines.last().expect("result").clone();
        assert_eq!(result["ok"], true, "{op}: {result}");
        result["result"].clone()
    }
}

impl Drop for Host {
    fn drop(&mut self) {
        // End of input: the loop returns and closes every forward.
        drop(self.input.take());
        if let Some(serving) = self.serving.take()
            && !std::thread::panicking()
        {
            serving.join().expect("serve thread").expect("serve");
        }
    }
}

impl Host {
    /// Sends an op and returns its result line, ok or not (the lines
    /// before it are dropped).
    pub fn result(&mut self, id: &str, op: &str, args: Value, key: Option<&str>) -> Value {
        let mut line = json!({ "type": "op", "id": id, "op": op, "args": args, "origin": "user" });
        if let Some(key) = key {
            line["idempotency_key"] = json!(key);
        }
        self.send(&line);
        self.answer(id).pop().expect("result")
    }

    /// Sends a read op and returns every line up to its result.
    pub fn answer_of(&mut self, id: &str, op: &str, args: Value) -> Vec<Value> {
        self.send(&json!({ "type": "op", "id": id, "op": op, "args": args, "origin": "user" }));
        self.answer(id)
    }
}
