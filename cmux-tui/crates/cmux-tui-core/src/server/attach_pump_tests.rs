//! Attach streams drain on the sequenced pool: a pump runs
//! nothing before its attach commits, coalesces wakes, stops at its
//! stream's backpressure cap and resumes when the writer takes an item,
//! and a snapshot viewer's idle digest is a delayed task of its sequence.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, mpsc};
use std::time::{Duration, Instant};

use base64::Engine as _;
use serde_json::{Value, json};

use super::{AttachDrain, AttachPump, PumpTimer, Turn};
use crate::server::sequenced_pool::{PoolConfig, SequencePriority, SequencedPool};
use crate::server::tests::captured_writer;
use crate::server::{
    BoundedOutbound, ClientTransport, Command, MessageWriter, disconnect_client, handle_command,
};
use crate::{Mux, SurfaceOptions};

pub(crate) const WAIT: Duration = Duration::from_secs(10);

/// Counts its turns; ends after `turns_left` reaches zero.
struct Counting {
    turns: Arc<AtomicUsize>,
    abandoned: mpsc::Sender<()>,
}

impl AttachDrain for Counting {
    fn turn(&mut self, _timer: &PumpTimer<'_>) -> Turn {
        self.turns.fetch_add(1, Ordering::SeqCst);
        Turn::Idle
    }

    fn abandon(self: Box<Self>) {
        let _ = self.abandoned.send(());
    }
}

fn counting_pump(pool: &SequencedPool) -> (AttachPump, Arc<AtomicUsize>, mpsc::Receiver<()>) {
    let pump = AttachPump::new(pool, SequencePriority::Input);
    let turns = Arc::new(AtomicUsize::new(0));
    let (abandoned, abandons) = mpsc::channel();
    pump.install(Box::new(Counting { turns: turns.clone(), abandoned }));
    (pump, turns, abandons)
}

pub(crate) fn eventually(what: &str, done: impl Fn() -> bool) {
    let deadline = Instant::now() + WAIT;
    while !done() {
        assert!(Instant::now() < deadline, "timed out waiting until {what}");
        std::thread::sleep(Duration::from_millis(1));
    }
}

#[test]
fn a_pump_runs_nothing_before_it_starts_and_abandons_its_drain_unstarted() {
    let pool = SequencedPool::new(PoolConfig::for_cores(4));
    let (pump, turns, abandons) = counting_pump(&pool);
    let hook = pump.hook();
    hook();
    hook();
    std::thread::sleep(Duration::from_millis(30));
    assert_eq!(turns.load(Ordering::SeqCst), 0, "a wake before the commit ran the drain");
    drop(pump);
    abandons.recv_timeout(WAIT).expect("the unstarted drain is abandoned");
    hook();
    std::thread::sleep(Duration::from_millis(30));
    assert_eq!(turns.load(Ordering::SeqCst), 0);
}

#[test]
fn a_started_pump_runs_once_per_wake_and_stops_with_its_interrupt() {
    let pool = SequencedPool::new(PoolConfig::for_cores(4));
    let (pump, turns, abandons) = counting_pump(&pool);
    let hook = pump.hook();
    let stop = pump.stop().clone();
    pump.start().expect("posted");
    eventually("the first turn", || turns.load(Ordering::SeqCst) == 1);
    hook();
    eventually("the woken turn", || turns.load(Ordering::SeqCst) == 2);
    stop.fire();
    // The stop interrupt wakes the drain once more, so it sees its close.
    eventually("the stop turn", || turns.load(Ordering::SeqCst) == 3);
    assert!(abandons.try_recv().is_err(), "a started drain is never abandoned");
}

pub(crate) fn command(value: Value) -> Command {
    serde_json::from_value(value).expect("raw command")
}

pub(crate) fn request(mux: &Arc<Mux>, client: u64, writer: &MessageWriter, value: Value) -> Value {
    handle_command(mux, client, command(value), writer).expect("request succeeds")
}

/// A captured connection that granted attach streams.
pub(crate) fn connect(mux: &Arc<Mux>) -> (MessageWriter, Arc<BoundedOutbound>, u64) {
    connect_with(mux, &[])
}

/// [`connect`], granted `capabilities` as well.
pub(crate) fn connect_with(
    mux: &Arc<Mux>,
    capabilities: &[&str],
) -> (MessageWriter, Arc<BoundedOutbound>, u64) {
    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let mut granted = vec!["attach-streams-v1"];
    granted.extend_from_slice(capabilities);
    request(
        mux,
        client,
        &writer,
        json!({"cmd": "set-client-info", "kind": "tui", "capabilities": granted}),
    );
    (writer, outbound, client)
}

/// The next item other than notifications and scroll changes, within `timeout`.
pub(crate) fn next_item(outbound: &BoundedOutbound, timeout: Duration) -> Option<Value> {
    let deadline = Instant::now() + timeout;
    loop {
        let value = next_any(outbound, deadline.saturating_duration_since(Instant::now()))?;
        if !matches!(value["event"].as_str(), Some("notification" | "scroll-changed")) {
            return Some(value);
        }
    }
}

/// The next item, whatever it is, within `timeout`.
pub(crate) fn next_any(outbound: &BoundedOutbound, timeout: Duration) -> Option<Value> {
    let deadline = Instant::now() + timeout;
    loop {
        if let Some(message) = outbound.try_pop() {
            return Some(serde_json::from_str(&message).expect("outbound JSON"));
        }
        if Instant::now() >= deadline {
            return None;
        }
        std::thread::sleep(Duration::from_millis(2));
    }
}

pub(crate) fn decoded(item: &Value) -> Vec<u8> {
    base64::engine::general_purpose::STANDARD
        .decode(item["data"].as_str().expect("data"))
        .expect("base64")
}

/// 400 outputs, spaced so each would be its own item, while nobody reads: a
/// drain that sent past its stream's cap would overflow the stream (256
/// items); stopped at the cap, the tap merges them and the writer's pops
/// wake the drain until all arrived, in order.
#[test]
fn a_stream_view_stops_at_its_cap_and_resumes_when_the_writer_takes_an_item() {
    let mux = Mux::new_for_test("attach-pump-cap", SurfaceOptions::default());
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    let (writer, outbound, client) = connect(&mux);
    request(
        &mux,
        client,
        &writer,
        json!({"cmd": "attach-surface", "surface": surface.id, "stream": 3}),
    );
    let ready = next_item(&outbound, WAIT).expect("READY");
    assert_eq!((ready["event"].as_str(), ready["stream"].as_u64()), (Some("vt-state"), Some(3)));
    let mut sent = Vec::new();
    for index in 0..400 {
        let chunk = format!("line {index}\r\n");
        surface.inject_output_for_test(chunk.as_bytes());
        sent.extend_from_slice(chunk.as_bytes());
        // Time for the drain to take each output as an item of its own.
        std::thread::sleep(Duration::from_micros(300));
    }
    let mut received = Vec::new();
    while received.len() < sent.len() {
        let item = next_item(&outbound, WAIT).expect("the drain resumes");
        assert_eq!(item["stream"], 3, "{item}");
        match item["event"].as_str() {
            Some("output") => received.extend(decoded(&item)),
            Some("colors-changed") => {}
            other => panic!("unexpected {other:?}: {item}"),
        }
    }
    assert_eq!(received, sent);
    disconnect_client(&mux, client, false);
    mux.shutdown();
}

/// A snapshot viewer on a stream gets its idle digest from a delayed task of
/// its sequence: no thread waits for it.
#[test]
fn a_stream_snapshot_viewer_gets_its_idle_digest() {
    let mux = Mux::new_for_test("attach-pump-digest", SurfaceOptions::default());
    let surface = mux.new_workspace(None, None).unwrap();
    let (writer, outbound, client) = connect(&mux);
    let version = ghostty_vt::snapshot_version();
    request(
        &mux,
        client,
        &writer,
        json!({
            "cmd": "attach-surface", "surface": surface.id, "stream": 5,
            "snapshot": "ghostsnp", "snapshot_version": version,
        }),
    );
    let ready = next_item(&outbound, WAIT).expect("READY");
    assert_eq!(ready["event"], "snapshot", "{ready}");
    assert_eq!(ready["stream"], 5);
    let mut offset = ready["offset"].as_u64().unwrap();
    surface.inject_output_for_test(b"hello from the host\r\n");
    let digest = loop {
        let item = next_item(&outbound, WAIT).expect("output or digest");
        assert_eq!(item["stream"], 5, "{item}");
        match item["event"].as_str() {
            Some("output") => offset += decoded(&item).len() as u64,
            Some("digest") => break item,
            Some("snapshot") if item["phase"] == "history" => {}
            Some("colors-changed") => {}
            other => panic!("unexpected {other:?}: {item}"),
        }
    };
    assert_eq!(digest["offset"].as_u64(), Some(offset), "{digest}");
    disconnect_client(&mux, client, false);
    mux.shutdown();
}
