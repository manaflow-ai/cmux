//! The serve loop wakes on link events: a link change and the forwards it
//! closes reach the host at once, with no op after the change.
//!
//! The host side of the JSON-lines channel is this test: it writes op lines,
//! answers each `relay.request` from the fixtures (through the fake control
//! plane) and reads every line the server writes. The input stays open while
//! the test waits, so only a link event can wake the loop.

mod attach_common;
mod common;
mod edge_common;

use attach_common::{FakeSpawner, FakeTransport, attach};
use cmux_cloud::api::{HostRelay, serve_with};
use cmux_cloud::ports::Edge;
use cmux_cloud::{ControlPlane, HttpCall};
use common::FakeControlPlane;
use edge_common::{FakeTransfer, FakeTunnel};
use serde_json::{Value, json};
use std::io::{self, BufReader, Read, Write};
use std::net::{Ipv4Addr, SocketAddr, TcpStream};
use std::sync::Arc;
use std::sync::mpsc::{Receiver, RecvTimeoutError, Sender, channel};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

/// The bound on each wait for a server line in these tests.
const WAIT: Duration = Duration::from_secs(5);

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

struct Host {
    input: Option<Sender<Vec<u8>>>,
    output: Receiver<String>,
    cloud: FakeControlPlane,
    spawner: FakeSpawner,
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
    fn start(fixtures: &[&str]) -> Self {
        let spawner = FakeSpawner::default();
        let (input, lines) = channel();
        let (sink, output) = channel();
        let relay = HostRelay::new(
            BufReader::new(Input { lines, pending: Vec::new() }),
            Output { lines: sink, partial: Vec::new() },
        );
        let attach = attach(&spawner, &FakeTransport::default());
        let edge = Edge::new(Arc::new(FakeTunnel::default()), Box::new(FakeTransfer::default()));
        let serving = std::thread::spawn(move || serve_with(relay, attach, edge));
        Self {
            input: Some(input),
            output,
            cloud: FakeControlPlane::with(fixtures),
            spawner,
            serving: Some(serving),
        }
    }

    fn send(&self, line: &Value) {
        let mut bytes = line.to_string().into_bytes();
        bytes.push(b'\n');
        self.input.as_ref().expect("open").send(bytes).expect("server reads");
    }

    /// The next line that is not a relay request; relay requests are
    /// answered from the fixtures on the way. `None` after [`WAIT`].
    fn next(&mut self) -> Option<Value> {
        loop {
            let line = match self.output.recv_timeout(WAIT) {
                Ok(line) => line,
                Err(RecvTimeoutError::Timeout | RecvTimeoutError::Disconnected) => return None,
            };
            let line: Value = serde_json::from_str(&line).expect("JSON line");
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
            let reply = self.cloud.call(&call).expect("fake reply");
            self.send(&json!({ "type": "relay.response", "id": line["id"],
                "status": reply.status, "body": reply.body }));
        }
    }

    /// Lines up to and including the result of op `id`.
    fn answer(&mut self, id: &str) -> Vec<Value> {
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
    fn op(&mut self, id: &str, op: &str, args: Value, key: &str) -> Value {
        self.send(&json!({ "type": "op", "id": id, "op": op, "args": args,
            "origin": "user", "idempotency_key": key }));
        let lines = self.answer(id);
        let result = lines.last().expect("result").clone();
        assert_eq!(result["ok"], true, "{op}: {result}");
        result["result"].clone()
    }

    /// Every line that arrives within `window`, with no op sent.
    fn lines_within(&mut self, window: Duration) -> Vec<Value> {
        let deadline = Instant::now() + window;
        let mut lines = Vec::new();
        while let Some(left) = deadline.checked_duration_since(Instant::now()) {
            match self.output.recv_timeout(left) {
                Ok(line) => lines.push(serde_json::from_str(&line).expect("JSON line")),
                Err(_) => break,
            }
        }
        lines
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

const FIXTURES: &[&str] = &["vm-get", "attach_endpoint_alpha"];

fn link_changed(line: &Value) -> bool {
    line["type"] == "event" && line["event"] == "cloud.link.changed"
}

fn port_changed(line: &Value) -> bool {
    line["type"] == "event" && line["event"] == "cloud.port.changed"
}

fn local(answer: &Value) -> SocketAddr {
    let port = u16::try_from(answer["localPort"].as_u64().expect("localPort")).expect("u16");
    SocketAddr::from((Ipv4Addr::LOCALHOST, port))
}

/// Whether `addr` refuses connections before `WAIT` ends (a closed listener).
fn refuses_within(addr: SocketAddr) -> bool {
    let deadline = Instant::now() + WAIT;
    while Instant::now() < deadline {
        if TcpStream::connect_timeout(&addr, Duration::from_millis(200)).is_err() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    false
}

#[test]
fn a_link_exit_reaches_the_host_with_no_op_after_it() {
    let mut host = Host::start(FIXTURES);
    let carrier = host.op("1", "cloud.machine.connect", json!({"machine": "vm-alpha01"}), "c-1");
    assert_eq!(carrier["state"], "up");
    // The op's own lines (the up event) are read; nothing else is pending.
    let quiet = host.lines_within(Duration::from_millis(200));
    assert!(quiet.iter().all(|l| !link_changed(l) || l["state"] == "up"), "{quiet:?}");

    host.spawner.exit("vm-alpha01", 1);
    let line = host.next().expect("a cloud.link.changed line with no op after the link exit");
    assert!(link_changed(&line), "{line}");
    assert_eq!(line["machine"], "vm-alpha01");
    assert_eq!(line["state"], "down");
    assert_eq!(line["generation"], 1);
    assert_eq!(line["retryable"], true);
}

#[test]
fn a_forward_on_a_dead_link_closes_with_no_op_after_the_death() {
    let mut host = Host::start(FIXTURES);
    let forward =
        host.op("1", "cloud.port.forward", json!({"machine": "vm-alpha01", "port": 3000}), "f-1");
    let addr = local(&forward);
    TcpStream::connect(addr).expect("the forward listens while the link is up");

    host.spawner.exit("vm-alpha01", 1);
    assert!(refuses_within(addr), "the listener of a dead link must close with no op");
    let lines = host.lines_within(Duration::from_millis(500));
    let down = lines.iter().find(|l| port_changed(l)).unwrap_or_else(|| panic!("{lines:?}"));
    assert_eq!(down["machine"], "vm-alpha01");
    assert_eq!(down["port"], 3000);
    assert_eq!(down["localPort"], forward["localPort"]);
    assert_eq!(down["state"], "down");
}

#[test]
fn the_events_of_one_link_death_keep_their_order() {
    let mut host = Host::start(FIXTURES);
    let first =
        host.op("1", "cloud.port.forward", json!({"machine": "vm-alpha01", "port": 3000}), "f-1");
    let second =
        host.op("2", "cloud.port.forward", json!({"machine": "vm-alpha01", "port": 5173}), "f-2");

    host.spawner.exit("vm-alpha01", 1);
    let mut lines = Vec::new();
    while lines.len() < 3 {
        let line = host.next().unwrap_or_else(|| panic!("three lines with no op: {lines:?}"));
        lines.push(line);
    }
    // The cause first, then each forward it closed, in port order.
    assert!(link_changed(&lines[0]) && lines[0]["state"] == "down", "{lines:?}");
    assert!(port_changed(&lines[1]) && lines[1]["port"] == 3000, "{lines:?}");
    assert_eq!(lines[1]["localPort"], first["localPort"]);
    assert!(port_changed(&lines[2]) && lines[2]["port"] == 5173, "{lines:?}");
    assert_eq!(lines[2]["localPort"], second["localPort"]);
    // Each change goes out once: an op after it repeats none of them.
    let lines = host.answer_of("3", "cloud.port.list", json!({}));
    assert!(lines.iter().all(|l| !link_changed(l) && !port_changed(l)), "{lines:?}");
}

impl Host {
    /// Sends a read op and returns every line up to its result.
    fn answer_of(&mut self, id: &str, op: &str, args: Value) -> Vec<Value> {
        self.send(&json!({ "type": "op", "id": id, "op": op, "args": args, "origin": "user" }));
        self.answer(id)
    }
}
