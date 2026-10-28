//! A view's drain on the sequenced pool never holds a worker the echo path
//! shares: its end does not wait for room on a full
//! connection and each item is an echo hang scope. Bulk work runs off the
//! drain (snapshot_attach_out_tests.rs).

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, mpsc};
use std::time::Duration;

use serde_json::{Value, json};

use super::tests::{WAIT, connect, decoded, next_any, next_item, request};
use super::{AttachPump, PumpTimer, Step, ViewDrain, ViewOut, ViewSource};
use crate::server::attach_streams::ClientStreamId;
use crate::server::request_watchdog::{HangSink, REQUEST_WATCHDOG_THRESHOLD};
use crate::server::sequenced_pool::SequencePriority;
use crate::server::tests::captured_writer;
use crate::server::{
    BoundedOutbound, ClientTransport, MessageWriter, OUTBOUND_CONNECTION_CAPACITY, RequestWatchdog,
    WatchKind, disconnect_client,
};
use crate::surface::AttachLifecycle;
use crate::{Mux, SurfaceId, SurfaceOptions};

/// A source with nothing to send; `ended` hears its end.
struct Quiet {
    ended: mpsc::Sender<()>,
}

impl ViewSource for Quiet {
    const WATCH: WatchKind = WatchKind::AttachOut;

    fn next(&mut self, _out: &mut ViewOut, _timer: &PumpTimer<'_>) -> Step {
        Step::Empty
    }

    fn end(self, _out: &ViewOut) {
        let _ = self.ended.send(());
    }
}

/// The output of view `stream` of `surface` on `writer`, woken by `pump`.
fn bind(
    pump: &AttachPump,
    mux: &Arc<Mux>,
    client: u64,
    surface: SurfaceId,
    writer: &MessageWriter,
    stream: u16,
) -> (ViewOut, AttachLifecycle) {
    let outbound = writer
        .start_client_stream(ClientStreamId(stream), &mux.control_clients.attach_stream_admission)
        .expect("stream id");
    let lifecycle = AttachLifecycle::default();
    let out = ViewOut::bind(pump, mux, client, surface, writer, &outbound, &lifecycle, false);
    (out, lifecycle)
}

/// Fills the connection's stream budget with items of streams it may end.
fn fill_connection(writer: &MessageWriter, outbound: &BoundedOutbound) {
    let mut filler = None;
    let mut queued = 0;
    while outbound.queued_stream_items() < OUTBOUND_CONNECTION_CAPACITY {
        if queued % 200 == 0 {
            filler = Some(writer.start_stream(&json!({"event": "overflow"})).expect("filler"));
        }
        let stream = filler.as_ref().expect("a filler stream");
        writer.send_stream(&json!({"event": "fill"}), stream).expect("room");
        queued += 1;
    }
}

/// Two views end while their connection has no room for their
/// `stream-end`: they leave both input workers free (a byte view on another
/// connection still echoes), and each `stream-end` follows once the
/// connection's reader takes an item.
#[test]
fn views_ending_on_a_full_connection_hold_no_worker() {
    let mux = Mux::new_for_test("attach-pump-full", SurfaceOptions::default());
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    let (full_writer, full) = captured_writer();
    let full_client = mux.control_clients.register(ClientTransport::Unix, full_writer.clone());
    let (ended, ends) = mpsc::channel();
    let mut lifecycles = Vec::new();
    for stream in [1, 2] {
        let pump = AttachPump::new(&mux.sequenced_pool, SequencePriority::Input);
        let (out, lifecycle) = bind(&pump, &mux, full_client, surface.id, &full_writer, stream);
        pump.install(Box::new(ViewDrain::new(out, Quiet { ended: ended.clone() })));
        pump.start().expect("posted");
        lifecycles.push(lifecycle);
    }
    fill_connection(&full_writer, &full);
    for lifecycle in &lifecycles {
        lifecycle.cancel();
    }
    for _ in 0..2 {
        ends.recv_timeout(WAIT).expect("the view ends");
    }

    // Both input workers are free: a byte view on another connection echoes.
    let (writer, outbound, client) = connect(&mux);
    request(
        &mux,
        client,
        &writer,
        json!({"cmd": "attach-surface", "surface": surface.id, "stream": 9}),
    );
    assert_eq!(next_item(&outbound, WAIT).expect("READY")["event"], "vt-state");
    surface.inject_output_for_test(b"echo\r\n");
    let output = loop {
        let item = next_item(&outbound, WAIT).expect("the echo while two views wait for room");
        if item["event"] == "output" {
            break item;
        }
    };
    assert_eq!(decoded(&output), b"echo\r\n");
    for stream in [1, 2] {
        assert!(
            full_writer.client_stream(ClientStreamId(stream)).is_some(),
            "stream {stream} ended on a connection with no room"
        );
    }

    // The reader takes items: each view's `stream-end` follows its items.
    let mut ends = Vec::new();
    while ends.len() < 2 {
        let item = next_any(&full, WAIT).expect("the stream-ends once there is room");
        if item["event"] == "stream-end" {
            assert_eq!(item["reason"], "detached", "{item}");
            ends.push(item["stream"].as_u64().unwrap());
        }
    }
    ends.sort_unstable();
    assert_eq!(ends, [1, 2]);
    disconnect_client(&mux, client, false);
    disconnect_client(&mux, full_client, false);
    mux.shutdown();
}

/// Its first item takes 150 ms.
struct Slow {
    done: Arc<AtomicBool>,
}

impl ViewSource for Slow {
    const WATCH: WatchKind = WatchKind::RenderAttachOut;

    fn next(&mut self, _out: &mut ViewOut, _timer: &PumpTimer<'_>) -> Step {
        if self.done.swap(true, Ordering::SeqCst) {
            return Step::Empty;
        }
        std::thread::sleep(Duration::from_millis(150));
        Step::Sent
    }
}

/// A drain item busy past the echo tier (100 ms) is one hang record naming
/// its view's scope, as on the legacy `mux-render-attach-out` thread.
#[test]
fn a_stalled_drain_item_is_reported_as_an_echo_hang() {
    let (records, received) = mpsc::channel::<Value>();
    let records = Mutex::new(records);
    let sink: HangSink = Box::new(move |record| {
        let _ = records.lock().unwrap().send(record);
    });
    let watchdog = RequestWatchdog::for_hang_test(
        REQUEST_WATCHDOG_THRESHOLD,
        Duration::from_millis(100),
        sink,
    );
    let mux = Mux::new_for_test("attach-pump-hang", SurfaceOptions::default());
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    let (writer, _outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let pump = AttachPump::new(&mux.sequenced_pool, SequencePriority::Input);
    let (out, _lifecycle) = bind(&pump, &mux, client, surface.id, &writer, 1);
    let source = Slow { done: Arc::new(AtomicBool::new(false)) };
    pump.install(Box::new(ViewDrain { out, source: Some(source), hangs: watchdog.echo_watch() }));
    pump.start().expect("posted");
    let record = received.recv_timeout(WAIT).expect("a hang record");
    assert_eq!(record["scope"], "mux-render-attach-out", "{record}");
    assert_eq!(record["method"], "frame", "{record}");
    disconnect_client(&mux, client, false);
    mux.shutdown();
}
