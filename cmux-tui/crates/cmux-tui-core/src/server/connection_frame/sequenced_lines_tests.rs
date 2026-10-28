//! The reader runs no handler: every line goes to its
//! connection's control sequence in arrival order, so a slow v2 operation
//! never delays reading the next line, v2 and v1 replies leave in arrival
//! order, and in Debug a handler that runs on a `mux-conn` thread panics.
//! Each test reads its lines on a thread named `mux-conn`, as the
//! connection's reader is (listen.rs), so the debug assertion watches it.

use std::sync::Arc;
use std::sync::mpsc::channel;
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use crate::server::routes::{OperationRoute, RouteLine};
use crate::server::tests::{captured_writer, test_mux};
use crate::server::*;

/// How long a held handler runs.
const HOLD: Duration = Duration::from_millis(300);

/// The reader's budget to hand one line to its sequence.
const HANDOFF_P50: Duration = Duration::from_millis(2);

/// The v2 operation whose handler runs [`HOLD`] and answers `{}`.
const HELD_OPERATION: &str = "test.held";

/// The test operation routes (server/routes.rs `OPERATION_ROUTES`): a v2
/// handler that is really slow without a blocking call the detector
/// refuses on a request thread.
pub(in crate::server) const OPERATION_ROUTES: &[OperationRoute] = &[OperationRoute {
    names: |operation| operation == HELD_OPERATION,
    stage: FrameStage::PageRouter,
    entry: held,
}];

fn held(line: &RouteLine<'_>) -> Option<bool> {
    let value: Value = crate::line_parses::parse(line.message).ok()?;
    std::thread::sleep(HOLD);
    let reply = json!({"protocol":"cmux.protocol/2","type":"response","id":value["id"],
        "ok":true,"result":{}});
    Some(line.writer.send_control(&reply).is_ok())
}

/// Holds the mux state lock for `hold` on another thread.
fn hold_state(mux: &Arc<Mux>, hold: Duration) -> JoinHandle<()> {
    let (locked_tx, locked) = channel();
    let mux = mux.clone();
    let holder = std::thread::spawn(move || {
        let _state = mux.state.lock().unwrap();
        locked_tx.send(()).unwrap();
        std::thread::sleep(hold);
    });
    locked.recv().unwrap();
    holder
}

struct Conn {
    mux: Arc<Mux>,
    client: u64,
    writer: MessageWriter,
    outbound: Arc<BoundedOutbound>,
    scheduler: Arc<ConnectionSurfaceScheduler>,
}

impl Conn {
    fn new(mux: &Arc<Mux>) -> Self {
        let (writer, outbound) = captured_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let scheduler =
            Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
        Self { mux: mux.clone(), client, writer, outbound, scheduler }
    }

    /// Reads `lines` as the connection's reader does, on a `mux-conn`
    /// thread, and returns how long the reader took to hand each one on.
    fn read_on_reader(&self, lines: Vec<String>) -> Vec<Duration> {
        let (mux, client) = (self.mux.clone(), self.client);
        let (writer, scheduler) = (self.writer.clone(), self.scheduler.clone());
        std::thread::Builder::new()
            .name(WatchKind::MuxConn.name().into())
            .spawn(move || {
                lines
                    .iter()
                    .map(|line| {
                        let started = Instant::now();
                        assert!(handle_connection_frame_at(
                            &mux,
                            client,
                            ClientTransport::Unix,
                            line,
                            &writer,
                            &scheduler,
                            started,
                        ));
                        started.elapsed()
                    })
                    .collect()
            })
            .unwrap()
            .join()
            .expect("no handler runs on the reader")
    }

    /// Every reply, once the sequence drained.
    fn replies(&self) -> Vec<Value> {
        self.scheduler.finish_and_wait();
        std::iter::from_fn(|| self.outbound.try_pop())
            .map(|text| serde_json::from_str(&text).expect("a JSON reply"))
            .collect()
    }
}

fn v2(id: &str, operation: &str, params: Value) -> String {
    json!({"protocol":"cmux.protocol/2","type":"request","id":id,
        "operation":operation,"params":params})
    .to_string()
}

/// A `request.cancel` of a request that is not waiting: answered at once,
/// with nothing to cancel.
fn request_cancel(id: &str) -> String {
    v2(id, "request.cancel", json!({"request_id":"r-none"}))
}

/// The reply's id: a v1 reply's number or a v2 reply's string.
fn reply_id(reply: &Value) -> String {
    match &reply["id"] {
        Value::String(id) => id.clone(),
        id => id.to_string(),
    }
}

fn median(mut values: Vec<Duration>) -> Duration {
    values.sort();
    values[values.len() / 2]
}

/// Red first: a v2 operation whose handler runs 300 ms no longer runs on
/// the reader, so the reader hands it on at once and reads the 20 `send`
/// lines behind it within its 2 ms budget each. (Before, the reader ran
/// the operation itself and read nothing for 300 ms.) The `send` replies
/// wait their turn on the same control sequence. The other half of the
/// acceptance, a `send` on a stream of its own written within 2 ms while
/// the held operation runs, is not covered here: it is blocked on the
/// stream sequences of p05-ipc-073 (now in this task's `depends_on`).
#[test]
fn resource_connection_a_held_v2_op_does_not_delay_reading_the_next_line() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    let conn = Conn::new(&mux);
    let mut lines = vec![v2("r-held", HELD_OPERATION, json!({}))];
    lines.extend((0..20).map(|id| {
        json!({"id": id, "cmd": "send", "surface": surface.id, "text": "x"}).to_string()
    }));
    let handoffs = conn.read_on_reader(lines);
    let read_all = handoffs.iter().sum::<Duration>();

    assert!(read_all < HOLD / 3, "the reader waited on the held operation: {handoffs:?}");
    let sends = handoffs[1..].to_vec();
    assert!(median(sends.clone()) < HANDOFF_P50, "send hand-offs: {sends:?}");
    let replies = conn.replies();
    let ids: Vec<String> = replies.iter().map(reply_id).collect();
    let mut expected = vec!["r-held".to_owned()];
    expected.extend((0..20).map(|id| id.to_string()));
    assert_eq!(ids, expected, "{replies:?}");
    mux.close_surface(surface.id).unwrap();
}

/// Red first: v1 and v2 lines interleaved on one connection are answered
/// in arrival order. A held v1 `list-tab-groups` (on the sequence before)
/// used to be overtaken by the v2 `request.cancel` behind it, which the
/// reader answered itself.
#[test]
fn resource_connection_interleaved_v2_and_v1_replies_keep_arrival_order() {
    let mux = test_mux();
    let conn = Conn::new(&mux);
    let lines = vec![
        json!({"id": 1, "cmd": "list-tab-groups"}).to_string(),
        request_cancel("r-2"),
        json!({"id": 3, "cmd": "ping"}).to_string(),
        v2("r-4", HELD_OPERATION, json!({})),
        // A feature route answers in turn too.
        json!({"id": 5, "cmd": "loopback-status"}).to_string(),
        request_cancel("r-6"),
    ];
    let holder = hold_state(&mux, HOLD);
    conn.read_on_reader(lines);
    holder.join().unwrap();

    let replies = conn.replies();
    let ids: Vec<String> = replies.iter().map(reply_id).collect();
    assert_eq!(ids, ["1", "r-2", "3", "r-4", "5", "r-6"], "{replies:?}");
    assert_eq!(replies[1]["ok"], true, "{}", replies[1]);
}

/// A line the sequence answers keeps the reply it got on the reader: a
/// refused v2 envelope and a line whose `cmd` names nothing still get
/// their error replies, in order with the lines around them.
#[test]
fn connection_frame_sequenced_error_replies_keep_their_answer_and_order() {
    let mux = test_mux();
    let conn = Conn::new(&mux);
    let lines = vec![
        v2("r-1", "no.such.operation", json!({})),
        json!({"id": 2, "cmd": "ping"}).to_string(),
        r#"{"id":3,"cmd":"no-such-command"}"#.to_owned(),
        "not json".to_owned(),
        json!({"id": 5, "cmd": "ping"}).to_string(),
    ];
    conn.read_on_reader(lines);
    let replies = conn.replies();
    let ids: Vec<String> = replies.iter().map(reply_id).collect();
    assert_eq!(ids, ["r-1", "2", "3", "null", "5"], "{replies:?}");
    assert_eq!(replies[0]["error"]["code"], "validation.invalid", "{}", replies[0]);
    assert_eq!(replies[2]["ok"], false, "{}", replies[2]);
    assert_eq!(replies[3]["ok"], false, "{}", replies[3]);
    assert_eq!(replies[4]["ok"], true, "{}", replies[4]);
}

/// In Debug a request handler that runs on a connection's reader thread
/// panics: the reader only reads, cuts and sequences.
#[cfg(debug_assertions)]
#[test]
fn connection_frame_a_handler_on_the_reader_thread_panics_in_debug() {
    let mux = test_mux();
    let conn = Conn::new(&mux);
    let (writer, client) = (conn.writer.clone(), conn.client);
    let ran = std::thread::Builder::new()
        .name(WatchKind::MuxConn.name().into())
        .spawn(move || {
            handle_request(
                &mux,
                client,
                Request { id: Some(json!(1)), cmd: Command::Ping },
                &writer,
            )
        })
        .unwrap()
        .join();
    assert!(ran.is_err(), "a handler ran on the reader without the debug assertion");
}
