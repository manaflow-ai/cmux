//! A connection's stream sequences and the stream barrier,
//! through the connection's scheduler on a test mux.

use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::super::sequenced_pool::{PoolConfig, SequencePriority, SequencedPool};
use super::super::{
    BoundedOutbound, ClientTransport, ConnectionSurfaceScheduler, MessageWriter, QueuedSink,
    Request,
};
use super::{StreamLanes, StreamOpenError, StreamPostError, crosses_stream_ok};
use crate::Mux;

const WAIT: Duration = Duration::from_secs(5);

struct Connection {
    mux: Arc<Mux>,
    client: u64,
    writer: MessageWriter,
    outbound: Arc<BoundedOutbound>,
    scheduler: Arc<ConnectionSurfaceScheduler>,
}

impl Connection {
    /// A connection on a fresh test mux. close-surface reaches the registry
    /// (sqlite) on the control worker, a recorded request-thread site: the
    /// tests run in record mode, as the other request-thread tests that
    /// reach the registry do.
    fn new(name: &str) -> Self {
        cmux_threads::blocking::set_mode(cmux_threads::BlockingMode::Record);
        let mux = Mux::new_for_test(name, crate::SurfaceOptions::default());
        let outbound = Arc::new(BoundedOutbound::default());
        let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let scheduler =
            Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
        Self { mux, client, writer, outbound, scheduler }
    }

    fn send(&self, line: Value) {
        let mut request = Some(serde_json::from_value::<Request>(line).expect("a request"));
        let dispatched = self.scheduler.dispatch(
            self.mux.clone(),
            self.client,
            &mut request,
            0,
            self.writer.clone(),
        );
        assert_eq!(dispatched, Some(true));
    }

    /// The next message, waiting at most `bound`.
    fn reply_within(&self, bound: Duration) -> Option<Value> {
        let deadline = Instant::now() + bound;
        loop {
            if let Some(line) = self.outbound.try_pop() {
                return Some(serde_json::from_str(&line).expect("a JSON message"));
            }
            if Instant::now() >= deadline {
                return None;
            }
            std::thread::sleep(Duration::from_micros(100));
        }
    }

    /// Posts an item on `stream` that waits until the returned sender
    /// sends (or drops), then logs `label`; returns once it started.
    fn block_stream(
        &self,
        stream: u16,
        log: &Arc<Mutex<Vec<&'static str>>>,
        label: &'static str,
    ) -> mpsc::Sender<()> {
        let (release_tx, release_rx) = mpsc::channel::<()>();
        let (started_tx, started_rx) = mpsc::channel();
        let log = log.clone();
        self.scheduler
            .post_stream(stream, move || {
                started_tx.send(()).unwrap();
                let _ = release_rx.recv();
                log.lock().unwrap().push(label);
            })
            .unwrap();
        started_rx.recv_timeout(WAIT).expect("the stream item starts");
        release_tx
    }
}

impl Drop for Connection {
    fn drop(&mut self) {
        let _ = self.scheduler.close_and_wait(WAIT);
    }
}

/// "exit\n" on the stream, then close-surface on control: the close runs
/// only after the stream item ran, so the shell reads its exit first.
#[test]
fn exit_on_the_stream_then_close_surface_keeps_order() {
    let connection = Connection::new("stream-lanes-exit-close");
    let surface = connection.mux.new_workspace(None, Some((80, 24))).unwrap();
    connection
        .scheduler
        .open_stream(&connection.mux, 7, surface.id, SequencePriority::Input)
        .unwrap();
    let log = Arc::new(Mutex::new(Vec::new()));
    let release = connection.block_stream(7, &log, "exit");
    connection.send(json!({"id": 1, "cmd": "close-surface", "surface": surface.id}));
    assert_eq!(connection.reply_within(Duration::from_millis(100)), None, "close passed exit");
    assert!(connection.mux.surface(surface.id).is_some(), "the surface closed before exit ran");
    release.send(()).unwrap();
    let reply = connection.reply_within(WAIT).expect("close-surface answers");
    assert_eq!(reply["id"], 1, "{reply}");
    assert_eq!(*log.lock().unwrap(), ["exit"], "the stream item ran before the close");
}

/// The barrier holds the whole control sequence: a ping behind a fenced
/// close-surface answers after it, never before.
#[test]
fn a_fenced_command_holds_the_control_sequence_in_order() {
    let connection = Connection::new("stream-lanes-fifo");
    let surface = connection.mux.new_workspace(None, Some((80, 24))).unwrap();
    connection
        .scheduler
        .open_stream(&connection.mux, 3, surface.id, SequencePriority::Input)
        .unwrap();
    let log = Arc::new(Mutex::new(Vec::new()));
    let release = connection.block_stream(3, &log, "input");
    connection.send(json!({"id": 1, "cmd": "close-surface", "surface": surface.id}));
    connection.send(json!({"id": 2, "cmd": "ping"}));
    assert_eq!(connection.reply_within(Duration::from_millis(50)), None);
    release.send(()).unwrap();
    let ids: Vec<Value> =
        (0..2).map(|_| connection.reply_within(WAIT).expect("a reply")["id"].clone()).collect();
    assert_eq!(ids, [json!(1), json!(2)]);
}

/// A send blocked on stream A (its PTY write waiting for POLLOUT) delays
/// neither stream B nor a ping on control: each starts within 2 ms.
#[test]
fn a_blocked_stream_delays_neither_another_stream_nor_a_ping() {
    let connection = Connection::new("stream-lanes-independent");
    let (a, b) = (connection.mux.new_workspace(None, Some((80, 24))).unwrap(), {
        connection.mux.new_workspace(None, Some((80, 24))).unwrap()
    });
    for (stream, surface) in [(1, a.id), (2, b.id)] {
        connection
            .scheduler
            .open_stream(&connection.mux, stream, surface, SequencePriority::Input)
            .unwrap();
    }
    let log = Arc::new(Mutex::new(Vec::new()));
    let release = connection.block_stream(1, &log, "a");
    let (ran_tx, ran_rx) = mpsc::channel();
    let mut stream_waits = Vec::new();
    let mut ping_waits = Vec::new();
    for id in 0..21 {
        let ran = ran_tx.clone();
        let posted = Instant::now();
        connection.scheduler.post_stream(2, move || ran.send(Instant::now()).unwrap()).unwrap();
        let started = ran_rx.recv_timeout(WAIT).expect("stream B runs while A waits");
        stream_waits.push(started.saturating_duration_since(posted));
        let sent = Instant::now();
        connection.send(json!({"id": id, "cmd": "ping"}));
        let reply = connection.reply_within(WAIT).expect("ping answers while A waits");
        ping_waits.push(sent.elapsed());
        assert_eq!(reply["id"], id, "{reply}");
    }
    assert!(log.lock().unwrap().is_empty(), "stream A still waits");
    release.send(()).unwrap();
    stream_waits.sort();
    ping_waits.sort();
    let (stream, ping) = (stream_waits[10], ping_waits[10]);
    assert!(stream < Duration::from_millis(2), "stream B waited {stream:?}");
    assert!(ping < Duration::from_millis(2), "ping waited {ping:?}");
}

/// A control command on a surface with an idle stream, or on another
/// surface, takes no barrier.
#[test]
fn an_idle_stream_or_another_surface_takes_no_barrier() {
    let connection = Connection::new("stream-lanes-idle");
    let streamed = connection.mux.new_workspace(None, Some((80, 24))).unwrap();
    let other = connection.mux.new_workspace(None, Some((80, 24))).unwrap();
    connection
        .scheduler
        .open_stream(&connection.mux, 4, streamed.id, SequencePriority::Input)
        .unwrap();
    let log = Arc::new(Mutex::new(Vec::new()));
    let release = connection.block_stream(4, &log, "held");
    connection.send(json!({"id": 1, "cmd": "close-surface", "surface": other.id}));
    let reply = connection.reply_within(WAIT).expect("another surface's close answers");
    assert_eq!(reply["id"], 1, "{reply}");
    release.send(()).unwrap();
    let deadline = Instant::now() + WAIT;
    while !log.lock().unwrap().contains(&"held") {
        assert!(Instant::now() < deadline, "the stream item ran");
        std::thread::sleep(Duration::from_millis(1));
    }
    connection.send(json!({"id": 2, "cmd": "close-surface", "surface": streamed.id}));
    let reply = connection.reply_within(WAIT).expect("the drained stream's close answers");
    assert_eq!(reply["id"], 2, "{reply}");
}

/// A closed stream still runs what it held, and releases a command fenced
/// on it.
#[test]
fn closing_a_stream_runs_its_items_and_releases_the_barrier() {
    let connection = Connection::new("stream-lanes-close");
    let surface = connection.mux.new_workspace(None, Some((80, 24))).unwrap();
    connection
        .scheduler
        .open_stream(&connection.mux, 5, surface.id, SequencePriority::Input)
        .unwrap();
    let log = Arc::new(Mutex::new(Vec::new()));
    let release = connection.block_stream(5, &log, "last");
    connection.send(json!({"id": 1, "cmd": "close-surface", "surface": surface.id}));
    assert!(connection.scheduler.close_stream(5));
    assert_eq!(
        connection.scheduler.post_stream(5, || {}),
        Err(StreamPostError::UnknownStream),
        "a closed stream takes no item"
    );
    release.send(()).unwrap();
    let reply = connection.reply_within(WAIT).expect("the fenced close answers");
    assert_eq!(reply["id"], 1, "{reply}");
    assert_eq!(*log.lock().unwrap(), ["last"]);
}

/// "exit\n" queued on a stream, the stream closed, then close-surface on
/// control: the closed stream still runs what it held, and the close waits
/// for it.
#[test]
fn a_command_after_its_stream_closed_still_waits_for_the_held_items() {
    let connection = Connection::new("stream-lanes-closed-then-close");
    let surface = connection.mux.new_workspace(None, Some((80, 24))).unwrap();
    connection
        .scheduler
        .open_stream(&connection.mux, 5, surface.id, SequencePriority::Input)
        .unwrap();
    let log = Arc::new(Mutex::new(Vec::new()));
    let release = connection.block_stream(5, &log, "exit");
    assert!(connection.scheduler.close_stream(5));
    connection.send(json!({"id": 1, "cmd": "close-surface", "surface": surface.id}));
    assert_eq!(connection.reply_within(Duration::from_millis(100)), None, "close passed exit");
    assert!(connection.mux.surface(surface.id).is_some(), "the surface closed before exit ran");
    release.send(()).unwrap();
    let reply = connection.reply_within(WAIT).expect("close-surface answers");
    assert_eq!(reply["id"], 1, "{reply}");
    assert_eq!(*log.lock().unwrap(), ["exit"], "the stream item ran before the close");
}

#[test]
fn stream_ids_open_once_and_never_zero() {
    let pool = SequencedPool::new(PoolConfig::for_cores(4));
    let mut lanes = StreamLanes::default();
    assert_eq!(
        lanes.open(&pool, 0, 1, SequencePriority::Input),
        Err(StreamOpenError::ControlStream)
    );
    assert_eq!(lanes.open(&pool, 9, 1, SequencePriority::Input), Ok(()));
    assert_eq!(lanes.open(&pool, 9, 2, SequencePriority::Input), Err(StreamOpenError::InUse));
    assert_eq!(lanes.surface(9), Some(1));
    assert_eq!(lanes.post(8, || {}), Err(StreamPostError::UnknownStream));
    assert!(lanes.close(9));
    assert!(!lanes.close(9));
    assert_eq!(lanes.open(&pool, 9, 2, SequencePriority::Input), Ok(()), "an idle id is reusable");
}

/// A closed stream's id opens again only once the items it held ran, so a
/// reopened stream never runs before, or beside, the old one.
#[test]
fn a_closed_stream_id_reopens_only_after_its_items_ran() {
    let pool = SequencedPool::new(PoolConfig::for_cores(4));
    let mut lanes = StreamLanes::default();
    lanes.open(&pool, 6, 1, SequencePriority::Input).unwrap();
    let (release_tx, release_rx) = mpsc::channel::<()>();
    let (started_tx, started_rx) = mpsc::channel();
    lanes
        .post(6, move || {
            started_tx.send(()).unwrap();
            let _ = release_rx.recv();
        })
        .unwrap();
    started_rx.recv_timeout(WAIT).unwrap();
    assert!(lanes.close(6));
    assert_eq!(lanes.surface(6), None, "a closed stream routes nothing");
    assert_eq!(lanes.post(6, || {}), Err(StreamPostError::UnknownStream));
    assert_eq!(
        lanes.open(&pool, 6, 1, SequencePriority::Input),
        Err(StreamOpenError::InUse),
        "the old stream still runs"
    );
    assert!(!lanes.close(6), "a closing stream is not open");
    release_tx.send(()).unwrap();
    let deadline = Instant::now() + WAIT;
    while lanes.open(&pool, 6, 1, SequencePriority::Input).is_err() {
        assert!(Instant::now() < deadline, "the id reopens once the old stream drained");
        std::thread::sleep(Duration::from_millis(1));
    }
    assert_eq!(lanes.surface(6), Some(1));
}

/// A stream's sequence queues at most the connection queue's capacity.
#[test]
fn a_full_stream_refuses_the_item() {
    let pool = SequencedPool::new(PoolConfig::for_cores(4));
    let mut lanes = StreamLanes::default();
    lanes.open(&pool, 1, 1, SequencePriority::Input).unwrap();
    let (release_tx, release_rx) = mpsc::channel::<()>();
    let (started_tx, started_rx) = mpsc::channel();
    lanes
        .post(1, move || {
            started_tx.send(()).unwrap();
            let _ = release_rx.recv();
        })
        .unwrap();
    started_rx.recv_timeout(WAIT).unwrap();
    for _ in 0..super::super::CONNECTION_SURFACE_QUEUE_CAPACITY {
        lanes.post(1, || {}).unwrap();
    }
    assert_eq!(lanes.post(1, || {}), Err(StreamPostError::Full));
    assert_eq!(lanes.depth(1), Some(super::super::CONNECTION_SURFACE_QUEUE_CAPACITY + 1));
    release_tx.send(()).unwrap();
}

/// No command carries `crosses_stream_ok` yet, so every control command on
/// a streamed surface waits; an unknown name waits too.
#[test]
fn commands_without_the_attribute_wait_for_the_stream() {
    assert!(!crosses_stream_ok("close-surface"));
    assert!(!crosses_stream_ok("ping"));
    assert!(!crosses_stream_ok("no-such-command"));
}
