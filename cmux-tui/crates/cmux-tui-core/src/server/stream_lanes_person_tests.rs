//! The person-input lane (p01-process-235): the verified app's input to a
//! view runs ahead of control requests of other surfaces and of automation,
//! and keeps its order with control requests of its own surface.

use std::sync::mpsc;
use std::sync::{Arc, RwLock};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::super::sequenced_pool::{PoolConfig, SequencePriority, SequencedPool};
use super::super::{
    BoundedOutbound, CONNECTION_SURFACE_QUEUE_CAPACITY, ClientTransport,
    ConnectionSurfaceScheduler, MessageWriter, QueuedSink, Request,
};
use crate::Mux;
use crate::event_cause::{EventCause, EventCauseScope};

const WAIT: Duration = Duration::from_secs(5);
/// The acceptance bound: a person's key answers within 5 ms at p99.
const KEY_P99: Duration = Duration::from_millis(5);
const SAMPLES: usize = 101;

struct Connection {
    mux: Arc<Mux>,
    client: u64,
    writer: MessageWriter,
    outbound: Arc<BoundedOutbound>,
    scheduler: Arc<ConnectionSurfaceScheduler>,
}

impl Connection {
    /// A connection on a fresh test mux, the person-input lane `lane`.
    fn new(name: &str, lane: bool) -> Self {
        cmux_threads::blocking::set_mode(cmux_threads::BlockingMode::Record);
        let mux = Mux::new_for_test(name, crate::SurfaceOptions::default());
        mux.person_input_lane.set_for_test(lane);
        let outbound = Arc::new(BoundedOutbound::default());
        let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let scheduler =
            Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
        Self { mux, client, writer, outbound, scheduler }
    }

    fn surface(&self) -> crate::SurfaceId {
        self.mux.new_workspace(None, Some((80, 24))).unwrap().id
    }

    /// Dispatches `line` as a request of `cause`.
    fn send_as(&self, cause: EventCause, line: Value) {
        let _cause = EventCauseScope::enter(cause);
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

    /// A request of the verified app, made for the person.
    fn send(&self, line: Value) {
        self.send_as(EventCause::Frontend, line);
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
            std::hint::spin_loop();
        }
    }

    /// A request that holds the control sequence: a wait for output that
    /// never comes on `surface`, answered (timed out) after `timeout`.
    fn hold_control(&self, id: u64, surface: crate::SurfaceId, timeout: Duration) {
        self.send(json!({
            "id": id,
            "cmd": "wait-for",
            "surface": surface,
            "pattern": "never-printed-person-lane",
            "timeout_ms": u64::try_from(timeout.as_millis()).unwrap(),
        }));
    }
}

impl Drop for Connection {
    fn drop(&mut self) {
        let _ = self.scheduler.close_and_wait(WAIT);
    }
}

fn p99(mut samples: Vec<Duration>) -> Duration {
    samples.sort();
    samples[samples.len() * 99 / 100]
}

/// A control sequence held by a slow request with an automation flood past
/// the control queue's capacity behind it does not delay or refuse the
/// person's keys to another surface: each answers ok within 5 ms at p99.
#[test]
fn an_automation_flood_on_control_does_not_delay_a_person_key() {
    let connection = Connection::new("person-lane-flood", true);
    let (held, typed) = (connection.surface(), connection.surface());
    connection.hold_control(1, held, Duration::from_secs(60));
    let flood = CONNECTION_SURFACE_QUEUE_CAPACITY + 44;
    for id in 2..2 + flood {
        connection.send_as(EventCause::Automation, json!({"id": id, "cmd": "ping"}));
    }
    // The flood past control's capacity was refused as it arrived.
    let mut refused = 0;
    while let Some(line) = connection.outbound.try_pop() {
        let reply: Value = serde_json::from_str(&line).expect("a JSON message");
        assert_eq!(reply["ok"], false, "only flood refusals answer before the keys: {reply}");
        refused += 1;
    }
    assert!(refused > 0, "the flood did not fill the control queue");
    let mut waits = Vec::with_capacity(SAMPLES);
    for key in 0..SAMPLES {
        let id = 1_000 + key;
        let sent = Instant::now();
        connection.send(json!({"id": id, "cmd": "send-key", "surface": typed, "keys": ["a"]}));
        let reply = connection.reply_within(WAIT).expect("the key answers while control waits");
        waits.push(sent.elapsed());
        assert_eq!(reply["id"], id, "only the key answers: {reply}");
        assert_eq!(reply["ok"], true, "{reply}");
    }
    let p99 = p99(waits);
    assert!(p99 <= KEY_P99, "a person key waited {p99:?} at p99 behind the control flood");
}

/// With the feature off the same key waits behind the held control
/// sequence, as before the lane.
#[test]
fn with_the_lane_off_a_person_key_waits_behind_control() {
    let connection = Connection::new("person-lane-off", false);
    let (held, typed) = (connection.surface(), connection.surface());
    connection.hold_control(1, held, Duration::from_millis(300));
    connection.send(json!({"id": 2, "cmd": "send-key", "surface": typed, "keys": ["a"]}));
    let first = connection.reply_within(WAIT).expect("the held request answers");
    assert_eq!(first["id"], 1, "the key passed control with the lane off: {first}");
    let second = connection.reply_within(WAIT).expect("the key answers after it");
    assert_eq!(second["id"], 2, "{second}");
}

/// Input from automation stays on control even with the lane on.
#[test]
fn automation_input_stays_on_control() {
    let connection = Connection::new("person-lane-automation", true);
    let (held, typed) = (connection.surface(), connection.surface());
    connection.hold_control(1, held, Duration::from_millis(300));
    connection.send_as(
        EventCause::Automation,
        json!({"id": 2, "cmd": "send-key", "surface": typed, "keys": ["a"]}),
    );
    let first = connection.reply_within(WAIT).expect("the held request answers");
    assert_eq!(first["id"], 1, "automation input passed control: {first}");
    assert_eq!(connection.reply_within(WAIT).expect("the key answers")["id"], 2);
}

/// A key to the surface a control request holds stays behind it: the lane
/// never reorders one surface's requests.
#[test]
fn a_person_key_keeps_order_with_control_of_its_surface() {
    let connection = Connection::new("person-lane-same-surface", true);
    let surface = connection.surface();
    connection.hold_control(1, surface, Duration::from_millis(300));
    connection.send(json!({"id": 2, "cmd": "send-key", "surface": surface, "keys": ["a"]}));
    let first = connection.reply_within(WAIT).expect("the held request answers");
    assert_eq!(first["id"], 1, "the key passed its surface's control request: {first}");
    assert_eq!(connection.reply_within(WAIT).expect("the key answers")["id"], 2);
}

/// A key to a surface whose clear-history runs on its own worker (the pump
/// handed it off and moved on) stays behind the clear, as on control.
#[test]
fn a_person_key_waits_for_an_active_clear_of_its_surface() {
    let connection = Connection::new("person-lane-clear", true);
    let surface = connection.surface();
    connection.scheduler.state.lock().unwrap().active_clear_surfaces.insert(surface);
    connection.send(json!({"id": 7, "cmd": "send-key", "surface": surface, "keys": ["a"]}));
    assert_eq!(
        connection.reply_within(Duration::from_millis(200)),
        None,
        "the key passed the active clear of its surface"
    );
    connection.scheduler.finish_clear(surface);
    let reply = connection.reply_within(WAIT).expect("the key answers after the clear");
    assert_eq!(reply["id"], 7, "{reply}");
    assert_eq!(reply["ok"], true, "{reply}");
}

/// A control command of a surface the lane holds input for waits for that
/// input; one of another surface does not.
#[test]
fn a_control_command_waits_for_person_input_of_its_surface() {
    let connection = Connection::new("person-lane-fence", true);
    let (typed, other) = (connection.surface(), connection.surface());
    let (release_tx, release_rx) = mpsc::channel::<()>();
    let (started_tx, started_rx) = mpsc::channel();
    let (ran_tx, ran_rx) = mpsc::channel();
    connection
        .scheduler
        .post_person_item(&connection.mux, typed, move || {
            started_tx.send(()).unwrap();
            let _ = release_rx.recv();
            ran_tx.send(()).unwrap();
        })
        .unwrap();
    started_rx.recv_timeout(WAIT).expect("the person item starts");
    connection.send(json!({"id": 1, "cmd": "close-surface", "surface": other}));
    let reply = connection.reply_within(WAIT).expect("another surface's close answers");
    assert_eq!(reply["id"], 1, "{reply}");
    connection.send(json!({"id": 2, "cmd": "close-surface", "surface": typed}));
    assert_eq!(connection.reply_within(Duration::from_millis(100)), None, "close passed the key");
    assert!(connection.mux.surface(typed).is_some(), "the surface closed before its input ran");
    release_tx.send(()).unwrap();
    let reply = connection.reply_within(WAIT).expect("the fenced close answers");
    assert_eq!(reply["id"], 2, "{reply}");
    ran_rx.try_recv().expect("the input ran before the close");
}

/// A closing connection waits for the person input it queued.
#[test]
fn a_finished_connection_drains_its_person_input() {
    let connection = Connection::new("person-lane-drain", true);
    let surface = connection.surface();
    let (release_tx, release_rx) = mpsc::channel::<()>();
    connection
        .scheduler
        .post_person_item(&connection.mux, surface, move || {
            let _ = release_rx.recv();
        })
        .unwrap();
    connection.scheduler.finish();
    assert!(
        !connection.scheduler.wait_for_completion(Some(Duration::from_millis(50))),
        "drained with person input running"
    );
    release_tx.send(()).unwrap();
    assert!(connection.scheduler.wait_for_completion(Some(WAIT)), "drained after it ran");
}

/// Across connections: control sequences that hold every control worker
/// (automation floods on 50 connections) do not delay an input sequence's
/// items, which run on the input workers.
#[test]
fn a_control_flood_across_connections_does_not_delay_input() {
    let pool = SequencedPool::new(PoolConfig::for_cores(4));
    let gate = Arc::new(RwLock::new(()));
    let held = gate.write().unwrap();
    let floods: Vec<_> = (0..50).map(|_| pool.sequence(SequencePriority::Control)).collect();
    let (busy_tx, busy_rx) = mpsc::channel();
    for flood in &floods {
        let (gate, busy) = (gate.clone(), busy_tx.clone());
        flood
            .post(move || {
                // The flood outlives the test's receiver; a late send is fine.
                let _ = busy.send(());
                drop(gate.read());
            })
            .unwrap();
    }
    for _ in 0..pool.config().workers(SequencePriority::Control) {
        busy_rx.recv_timeout(WAIT).expect("the flood holds every control worker");
    }
    let input = pool.sequence(SequencePriority::Input);
    let (ran_tx, ran_rx) = mpsc::channel();
    let mut waits = Vec::with_capacity(SAMPLES);
    for _ in 0..SAMPLES {
        let ran = ran_tx.clone();
        let posted = Instant::now();
        input.post(move || ran.send(Instant::now()).unwrap()).unwrap();
        let started = ran_rx.recv_timeout(WAIT).expect("input runs during the flood");
        waits.push(started.saturating_duration_since(posted));
    }
    drop(held);
    let p99 = p99(waits);
    assert!(p99 <= KEY_P99, "input waited {p99:?} at p99 behind the control flood");
}
