//! The C13 data plane on the serve loop (`dataPlane` of
//! `cmux.terminal.connector/1`): a user connect that carries the host's
//! open token opens a frame link with the host op
//! `cmux.terminal.connector.open`, then the pump moves bytes between the
//! link's carrier socket and `data`/`credit`/`end` frame lines, inside the
//! credit, with one `end` per channel.

mod attach_common;
mod common;
mod edge_common;
mod serve_common;

use attach_common::{FakeSpawner, FakeTransport, attach};
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use cmux_cloud::connector::port::{CarrierPort, PortEvent, PortOpener};
use cmux_cloud::link::LinkWake;
use cmux_cloud::ports::Edge;
use edge_common::{FakeTransfer, FakeTunnel};
use serde_json::{Value, json};
use serve_common::Host;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

const FIXTURES: &[&str] = &["vm-list", "vm-resume"];
const WINDOW: u64 = 256 * 1024;

/// What one fake carrier port saw, and the events the test feeds it.
#[derive(Default)]
struct PortLog {
    socket: PathBuf,
    reads: Vec<usize>,
    writes: Vec<Vec<u8>>,
    shutdown: bool,
    events: Vec<PortEvent>,
    wake: Option<LinkWake>,
}

#[derive(Clone, Default)]
struct FakePorts(Arc<Mutex<Vec<Arc<Mutex<PortLog>>>>>);

impl FakePorts {
    fn port(&self, index: usize) -> Arc<Mutex<PortLog>> {
        Arc::clone(&self.0.lock().unwrap()[index])
    }

    fn count(&self) -> usize {
        self.0.lock().unwrap().len()
    }

    /// The carrier gives the port an event; the serve loop wakes.
    fn feed(&self, index: usize, event: PortEvent) {
        let port = self.port(index);
        let wake = {
            let mut log = port.lock().unwrap();
            log.events.push(event);
            log.wake.clone()
        };
        (wake.expect("the serve loop gave a wake"))();
    }
}

struct FakePort(Arc<Mutex<PortLog>>);

impl CarrierPort for FakePort {
    fn read(&mut self, max: usize) {
        self.0.lock().unwrap().reads.push(max);
    }

    fn write(&mut self, bytes: Vec<u8>) {
        self.0.lock().unwrap().writes.push(bytes);
    }

    fn take_events(&mut self) -> Vec<PortEvent> {
        std::mem::take(&mut self.0.lock().unwrap().events)
    }

    fn shutdown(&mut self) {
        self.0.lock().unwrap().shutdown = true;
    }
}

impl PortOpener for FakePorts {
    fn open(
        &mut self,
        socket: &Path,
        wake: Option<LinkWake>,
    ) -> std::io::Result<Box<dyn CarrierPort>> {
        let log = Arc::new(Mutex::new(PortLog {
            socket: socket.to_owned(),
            wake,
            ..PortLog::default()
        }));
        self.0.lock().unwrap().push(Arc::clone(&log));
        Ok(Box::new(FakePort(log)))
    }
}

fn start() -> (Host, FakePorts) {
    let spawner = FakeSpawner::default();
    let ports = FakePorts::default();
    let attach = attach(&spawner, &FakeTransport::default())
        .with_carrier_ports(Box::new(ports.clone()));
    let edge = Edge::new(Arc::new(FakeTunnel::default()), Box::new(FakeTransfer::default()));
    let mut host = Host::start_with(FIXTURES, spawner, attach, edge);
    host.answer_of("1", "cloud.machine.list", json!({}));
    (host, ports)
}

/// The next line the server writes that satisfies `want` (others skipped).
fn next_where(host: &mut Host, what: &str, want: impl Fn(&Value) -> bool) -> Value {
    let mut seen = Vec::new();
    while let Some(line) = host.next() {
        if want(&line) {
            return line;
        }
        seen.push(line);
    }
    panic!("no {what}; saw {seen:?}");
}

fn frame(host: &mut Host, t: &str) -> Value {
    next_where(host, t, |l| l["t"] == t)
}

/// A user connect with an open token, answered by the host's open answer
/// `link-1`; returns once the carrier port is open.
fn open_link(host: &mut Host, ports: &FakePorts) -> Value {
    host.send(&json!({ "type": "op", "id": "2", "op": "cloud.machine.connect",
        "args": { "machine": "vm-beta02" }, "origin": "user", "idempotency_key": "c-2",
        "open_token": "tok-1" }));
    let result = next_where(host, "connect result", |l| l["type"] == "result" && l["id"] == "2");
    assert_eq!(result["ok"], true, "{result}");
    let request = next_where(host, "connector.open", |l| l["t"] == "host.request");
    assert_eq!(request["op"], "cmux.terminal.connector.open");
    assert_eq!(
        request["params"],
        json!({ "kind": "cloud-vm", "target": "vm-beta02", "open_token": "tok-1" })
    );
    host.send(&json!({ "t": "host.result", "id": request["id"],
        "value": { "channel": "link-1", "window_bytes": WINDOW } }));
    // The pump asks the carrier for bytes inside the out credit.
    let read = frame_or_read(host, ports);
    assert_eq!(read, 64 * 1024, "one frame of at most 64 KiB is read at a time");
    result
}

/// Waits until the port of the first link got its first read request.
fn frame_or_read(host: &mut Host, ports: &FakePorts) -> usize {
    // The open answer gives no line back; a no-op read op flushes the loop.
    host.answer_of("9", "cloud.port.list", json!({}));
    assert_eq!(ports.count(), 1, "one carrier port per link");
    let port = ports.port(0);
    let log = port.lock().unwrap();
    assert_eq!(log.socket, PathBuf::from("/tmp/cmux-test/vm-beta02-1.sock"));
    *log.reads.first().expect("a read request")
}

#[test]
fn a_connect_without_an_open_token_opens_no_frame_link() {
    let (mut host, ports) = start();
    host.op("2", "cloud.machine.connect", json!({ "machine": "vm-beta02" }), "c-2");
    host.answer_of("3", "cloud.port.list", json!({}));
    assert_eq!(ports.count(), 0);
}

#[test]
fn carrier_bytes_go_to_the_host_as_data_frames_and_host_data_to_the_carrier() {
    let (mut host, ports) = start();
    open_link(&mut host, &ports);

    ports.feed(0, PortEvent::Read(b"snapshot".to_vec()));
    let data = frame(&mut host, "data");
    assert_eq!(data["channel"], "link-1");
    assert_eq!(data["offset"], 8);
    assert_eq!(STANDARD.decode(data["bytes"].as_str().unwrap()).unwrap(), b"snapshot");
    assert_eq!(ports.port(0).lock().unwrap().reads.len(), 2, "the next read follows at once");

    host.send(&json!({ "t": "data", "channel": "link-1", "offset": 5,
        "bytes": STANDARD.encode(b"input") }));
    host.answer_of("4", "cloud.port.list", json!({}));
    assert_eq!(ports.port(0).lock().unwrap().writes, vec![b"input".to_vec()]);
    // Credit only after the carrier took the bytes.
    ports.feed(0, PortEvent::Wrote(5));
    let credit = frame(&mut host, "credit");
    assert_eq!(credit, json!({ "t": "credit", "channel": "link-1", "direction": "in", "bytes": 5 }));
}

#[test]
fn the_carrier_is_not_read_past_the_out_credit_until_the_host_grants_more() {
    let (mut host, ports) = start();
    open_link(&mut host, &ports);
    for _ in 0..4 {
        ports.feed(0, PortEvent::Read(vec![1; 64 * 1024]));
        frame(&mut host, "data");
    }
    host.answer_of("4", "cloud.port.list", json!({}));
    assert_eq!(ports.port(0).lock().unwrap().reads.len(), 4, "no read once the credit is spent");
    host.send(&json!({ "t": "credit", "channel": "link-1", "direction": "out", "bytes": 10 }));
    host.answer_of("5", "cloud.port.list", json!({}));
    assert_eq!(ports.port(0).lock().unwrap().reads, vec![65536, 65536, 65536, 65536, 10]);
}

#[test]
fn a_closed_carrier_ends_the_channel_once() {
    let (mut host, ports) = start();
    open_link(&mut host, &ports);
    ports.feed(0, PortEvent::Read(Vec::new()));
    let end = frame(&mut host, "end");
    assert_eq!(end["channel"], "link-1");
    assert_eq!(end["lost"]["retryable"], true);
    assert!(ports.port(0).lock().unwrap().shutdown);
    host.answer_of("4", "cloud.port.list", json!({}));
    let lines: Vec<Value> = std::iter::from_fn(|| host.next_within(std::time::Duration::ZERO))
        .filter(|l| l["t"] == "end")
        .collect();
    assert!(lines.is_empty(), "one end per channel: {lines:?}");
}

#[test]
fn host_data_past_the_credit_ends_the_channel_with_lost_credit() {
    let (mut host, ports) = start();
    open_link(&mut host, &ports);
    let too_much = vec![0u8; usize::try_from(WINDOW).unwrap() + 1];
    host.send(&json!({ "t": "data", "channel": "link-1", "offset": WINDOW + 1,
        "bytes": STANDARD.encode(&too_much) }));
    let end = frame(&mut host, "end");
    assert_eq!(end["lost"], json!({ "reason": "credit", "retryable": false }));
    assert!(ports.port(0).lock().unwrap().writes.is_empty());
    assert!(ports.port(0).lock().unwrap().shutdown);
}

#[test]
fn the_hosts_close_event_ends_the_link_and_its_carrier_port() {
    let (mut host, ports) = start();
    open_link(&mut host, &ports);
    host.send(&json!({ "t": "host.event", "op": "cmux.terminal.connector.close",
        "data": { "channel": "link-1" } }));
    let end = frame(&mut host, "end");
    assert_eq!(end["channel"], "link-1");
    assert!(ports.port(0).lock().unwrap().shutdown);
}

#[test]
fn the_hosts_end_frame_ends_the_link_without_an_end_back() {
    let (mut host, ports) = start();
    open_link(&mut host, &ports);
    host.send(&json!({ "t": "end", "channel": "link-1",
        "lost": { "reason": "closed", "retryable": true } }));
    host.answer_of("4", "cloud.port.list", json!({}));
    assert!(ports.port(0).lock().unwrap().shutdown);
    let ends: Vec<Value> = std::iter::from_fn(|| host.next_within(std::time::Duration::ZERO))
        .filter(|l| l["t"] == "end")
        .collect();
    assert!(ends.is_empty(), "{ends:?}");
}

#[test]
fn a_refused_open_leaves_the_connect_and_its_socket_working() {
    let (mut host, ports) = start();
    host.send(&json!({ "type": "op", "id": "2", "op": "cloud.machine.connect",
        "args": { "machine": "vm-beta02" }, "origin": "user", "idempotency_key": "c-2",
        "open_token": "tok-1" }));
    let result = next_where(&mut host, "connect result", |l| l["id"] == "2");
    assert_eq!(result["result"]["socket"], "/tmp/cmux-test/vm-beta02-1.sock");
    let request = next_where(&mut host, "connector.open", |l| l["t"] == "host.request");
    host.send(&json!({ "t": "host.error", "id": request["id"], "code": "denied",
        "message": "denied: the app does not implement cmux.terminal.connector/1",
        "retryable": false }));
    host.answer_of("4", "cloud.port.list", json!({}));
    assert_eq!(ports.count(), 0);
}
