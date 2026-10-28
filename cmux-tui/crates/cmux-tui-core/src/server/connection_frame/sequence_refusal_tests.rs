//! What a line that its full control sequence refuses gets:
//! a remote client only a code, a forwarded stream its end (never a silent
//! hole in its bytes), and what each line is charged to. Each test fills
//! the sequence by hand with no pump to run it, so the refusal does not
//! depend on timing.

use std::io::Read;
use std::sync::Arc;
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use crate::event_cause::EventCause;
use crate::panic_free::RecoverPoison;
use crate::server::loopback_forward::{open_idle_stream_for_test, stream_is_open_for_test};
use crate::server::tests::{captured_writer, test_mux};
use crate::server::*;

struct Conn {
    mux: Arc<Mux>,
    client: u64,
    transport: ClientTransport,
    writer: MessageWriter,
    outbound: Arc<BoundedOutbound>,
    scheduler: Arc<ConnectionSurfaceScheduler>,
}

impl Conn {
    fn new(mux: &Arc<Mux>, transport: ClientTransport) -> Self {
        let (writer, outbound) = captured_writer();
        let client = mux.control_clients.register(transport, writer.clone());
        let scheduler =
            Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
        Self { mux: mux.clone(), client, transport, writer, outbound, scheduler }
    }

    /// Marks a pump scheduled without posting one, so what the sequence
    /// takes stays queued, then queues `count` placeholder `Command`s.
    fn hold_sequence(&self, count: usize) {
        let mut state = self.scheduler.state.lock().recover_poison();
        state.pump_scheduled = true;
        for _ in 0..count {
            state.requests.push_back(SequencedItem::Request(PendingSurfaceRequest {
                request: Request { id: None, cmd: Command::Ping },
                arrival: RequestArrival::now(),
                cause: EventCause::Program,
                frame_call: None,
                retained_bytes: 0,
                _bytes_permit: self.scheduler.admission.try_reserve_bytes(0).unwrap(),
                stream_barrier: None,
            }));
        }
    }

    fn fill_sequence(&self) {
        self.hold_sequence(CONNECTION_SURFACE_QUEUE_CAPACITY);
    }

    /// The reader's part of `line`; whether the connection stays open.
    fn read(&self, line: &str) -> bool {
        handle_connection_frame_at(
            &self.mux,
            self.client,
            self.transport,
            line,
            &self.writer,
            &self.scheduler,
            Instant::now(),
        )
    }

    fn queued(&self) -> (usize, usize) {
        let state = self.scheduler.state.lock().recover_poison();
        (state.requests.len(), state.queued_bytes)
    }

    fn sent(&self) -> Vec<Value> {
        std::iter::from_fn(|| self.outbound.try_pop())
            .map(|text| serde_json::from_str(&text).expect("a JSON message"))
            .collect()
    }
}

impl Drop for Conn {
    fn drop(&mut self) {
        self.scheduler.close();
    }
}

/// A remote-relay line its full sequence refuses gets the relay's code and
/// nothing else: no queue text, no I/O error text (remote_relay/mod.rs,
/// "Refusals are codes only").
#[test]
fn remote_relay_a_refused_line_gets_only_the_relay_code() {
    let mux = test_mux();
    let conn = Conn::new(&mux, ClientTransport::Remote);
    conn.fill_sequence();
    let line = json!({"id": 7, "cmd": "identify"}).to_string();
    assert!(conn.read(&line));
    let sent = conn.sent();
    assert_eq!(
        sent,
        [json!({"id": 7, "ok": false, "error": "remote_error", "error_code": "remote_error"})],
        "{sent:?}"
    );
}

/// Red first: a `loopback-data` line its full sequence refuses ends its
/// stream with `queue-full`, so the client sees `loopback-closed` and the
/// target sees the stream end, instead of the bytes going missing while the
/// stream goes on. A line with an `id` also gets the error reply.
#[test]
fn loopback_a_refused_data_line_ends_its_stream() {
    let mux = test_mux();
    let conn = Conn::new(&mux, ClientTransport::Unix);
    let capabilities = [LOOPBACK_FORWARD_CAPABILITY];
    let hello =
        json!({"id": 1, "cmd": "set-client-info", "name": "t", "capabilities": capabilities});
    // Its own sequence: the connection's stays without a pump.
    let hello_sequence = Arc::new(ConnectionSurfaceScheduler::default());
    assert!(handle_connection_frame(
        &mux,
        conn.client,
        ClientTransport::Unix,
        &hello.to_string(),
        &conn.writer,
        &hello_sequence,
    ));
    hello_sequence.finish_and_wait();
    let mut target = open_idle_stream_for_test(&mux, conn.client, 7, &conn.writer);
    open_idle_stream_for_test(&mux, conn.client, 8, &conn.writer);
    conn.sent();
    conn.fill_sequence();

    let data = json!({"cmd": "loopback-data", "stream": 7, "data": "eA=="}).to_string();
    assert!(conn.read(&data), "the connection stays open");
    let credit = json!({"id": 9, "cmd": "loopback-credit", "stream": 8, "bytes": 1}).to_string();
    assert!(conn.read(&credit));

    let sent = conn.sent();
    let closed = |stream: u64| {
        sent.iter().any(|message| {
            *message == json!({"event": "loopback-closed", "stream": stream, "error": "queue-full"})
        })
    };
    assert!(closed(7) && closed(8), "{sent:?}");
    let refused = sent.iter().find(|message| message["id"] == 9).expect("the credit's reply");
    assert_eq!(refused["ok"], false, "{refused}");
    assert!(!stream_is_open_for_test(&mux, conn.client, 7));
    assert!(!stream_is_open_for_test(&mux, conn.client, 8));
    target.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
    let mut received = Vec::new();
    assert_eq!(target.read_to_end(&mut received).unwrap(), 0, "the target sees the end");
}

/// The largest line the reader accepts (`MAX_JSON_LINE_BYTES` and its
/// `\n`): an `fs.write` of that size.
fn largest_fs_write(id: u64) -> String {
    let mut line =
        json!({"id": id, "cmd": "fs.write", "path": "/tmp/x", "mode": "create"}).to_string();
    line.push_str(&" ".repeat(MAX_JSON_LINE_BYTES - line.len()));
    line.push('\n');
    line
}

/// Every line the reader accepts fits its connection's sequence, also
/// behind another of the largest size; feature-route and v2 lines are held
/// to their connection's caps only, so another connection's large lines
/// (here the whole daemon surface-operation budget) never refuse them, as
/// before they were sequenced. `Command`s are still charged to that budget.
#[cfg(unix)]
#[test]
fn connection_frame_the_largest_lines_are_sequenced_while_the_daemon_budget_is_full() {
    let mux = test_mux();
    let other = mux
        .surface_operation_admission
        .try_reserve_bytes(SERVER_SURFACE_RETAINED_BYTE_CAPACITY)
        .expect("another connection's large lines take the whole budget");

    let writes = Conn::new(&mux, ClientTransport::Unix);
    writes.hold_sequence(0);
    let (first, second) = (largest_fs_write(1), largest_fs_write(2));
    assert!(writes.read(&first));
    assert!(writes.read(&second));
    assert_eq!(writes.queued(), (2, first.len() + second.len()));
    assert_eq!(writes.sent(), Vec::<Value>::new(), "nothing refused");

    let mixed = Conn::new(&mux, ClientTransport::Unix);
    mixed.hold_sequence(0);
    let ping = json!({"id": 3, "cmd": "ping"}).to_string();
    assert!(mixed.read(&ping));
    let sent = mixed.sent();
    assert_eq!(sent.len(), 1, "{sent:?}");
    assert_eq!(sent[0]["id"], 3);
    assert!(sent[0]["error"].as_str().is_some_and(|error| error.contains("byte budget")));
    let v2 = json!({"protocol":"cmux.protocol/2","type":"request","id":"r-4",
        "operation":"session.ping","params":{"machine":"current","session":"current"}});
    assert!(mixed.read(&v2.to_string()));
    assert!(mixed.read(&largest_fs_write(5)));
    assert_eq!(mixed.queued().0, 2);
    assert_eq!(mixed.sent(), Vec::<Value>::new(), "nothing refused");
    drop(other);
}
