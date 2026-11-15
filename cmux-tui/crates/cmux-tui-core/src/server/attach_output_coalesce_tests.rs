//! `attach-output-coalesce-v1` over the raw v12 command path, with captured
//! connection writers: what a byte viewer reads with and without the
//! capability.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use base64::Engine as _;
use serde_json::{Value, json};

use super::tests::captured_writer;
use super::{
    BoundedOutbound, ClientTransport, Command, MessageWriter, disconnect_client, handle_command,
};
use crate::{Mux, Surface, SurfaceOptions};

fn command(value: Value) -> Command {
    serde_json::from_value(value).expect("raw command")
}

/// A surface whose program prints nothing: every byte the viewers read is
/// one the test injected.
fn quiet_surface(name: &str) -> (Arc<Mux>, Arc<Surface>) {
    let options = SurfaceOptions {
        command: Some(vec!["/bin/sh".into(), "-c".into(), "exec sleep 600".into()]),
        ..SurfaceOptions::default()
    };
    let mux = Mux::new_for_test(name, options);
    let surface = mux.new_workspace(None, None).unwrap();
    (mux, surface)
}

struct Viewer {
    client: u64,
    outbound: Arc<BoundedOutbound>,
    _writer: MessageWriter,
}

/// A byte attach on its own connection; `capability` declares
/// `attach-output-coalesce-v1` first. Returns once the `vt-state` arrived.
fn attach(mux: &Arc<Mux>, surface: &Surface, capability: bool, extra: Value) -> Viewer {
    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    if capability {
        handle_command(
            mux,
            client,
            command(json!({
                "cmd": "set-client-info", "name": "coalesce test",
                "capabilities": ["attach-output-coalesce-v1"],
            })),
            &writer,
        )
        .unwrap();
    }
    let mut request = json!({"cmd": "attach-surface", "surface": surface.id});
    for (key, value) in extra.as_object().expect("fields") {
        request[key] = value.clone();
    }
    handle_command(mux, client, command(request), &writer).unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let message = outbound.try_pop();
        if let Some(message) = message {
            let value: Value = serde_json::from_str(&message).expect("outbound JSON");
            if value["event"] == "vt-state" {
                break;
            }
            continue;
        }
        assert!(Instant::now() < deadline, "no vt-state");
        std::thread::sleep(Duration::from_millis(2));
    }
    Viewer { client, outbound, _writer: writer }
}

/// One `output` event as read: when, its raw line and its bytes.
struct Output {
    at: Instant,
    line: String,
    bytes: Vec<u8>,
}

impl Viewer {
    /// The next `output` within `timeout`; other events are skipped.
    fn next_output(&self, timeout: Duration) -> Option<Output> {
        next_output(&self.outbound, timeout)
    }
}

/// The next `output` on `outbound` within `timeout`; other events are skipped.
fn next_output(outbound: &BoundedOutbound, timeout: Duration) -> Option<Output> {
    let deadline = Instant::now() + timeout;
    loop {
        if let Some(message) = outbound.try_pop() {
            let value: Value = serde_json::from_str(&message).expect("outbound JSON");
            if value["event"] != "output" {
                continue;
            }
            let bytes = base64::engine::general_purpose::STANDARD
                .decode(value["data"].as_str().expect("data"))
                .expect("base64");
            return Some(Output { at: Instant::now(), line: message, bytes });
        }
        if Instant::now() >= deadline {
            return None;
        }
        std::thread::sleep(Duration::from_micros(500));
    }
}

/// Reads every `output` as it comes, as a client does (an unread connection
/// backs up and the daemon merges queued reads), until `done` is set and
/// `quiet` passes with none.
fn read_outputs(outbound: &BoundedOutbound, done: &AtomicBool, quiet: Duration) -> Vec<Output> {
    let mut outputs = Vec::new();
    let mut last = Instant::now();
    while !done.load(Ordering::Acquire) || last.elapsed() < quiet {
        if let Some(output) = next_output(outbound, Duration::from_millis(1)) {
            outputs.push(output);
            last = Instant::now();
        }
    }
    outputs
}

fn joined(outputs: &[Output]) -> Vec<u8> {
    outputs.iter().flat_map(|output| output.bytes.iter().copied()).collect()
}

#[test]
fn the_capability_is_advertised() {
    let (mux, _surface) = quiet_surface("coalesce-identify");
    let (writer, _outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let identity =
        handle_command(&mux, client, command(json!({"cmd": "identify"})), &writer).unwrap();
    let capabilities = identity["capabilities"].as_array().expect("capabilities");
    assert!(capabilities.iter().any(|value| value == "attach-output-coalesce-v1"), "{identity}");
    disconnect_client(&mux, client, false);
    mux.shutdown();
}

/// A build log at 200 lines a second for 2 s: the viewer that declared the
/// capability reads at most 61 `output` events a second, carrying the same
/// bytes in the same order as the viewer that did not, which still reads one
/// event per write.
#[test]
fn a_coalescing_viewer_reads_at_most_one_output_per_frame() {
    let (mux, surface) = quiet_surface("coalesce-rate");
    let plain = attach(&mux, &surface, false, json!({}));
    let coalesced = attach(&mux, &surface, true, json!({}));
    let period = Duration::from_millis(5);
    let length = Duration::from_secs(2);
    let done = AtomicBool::new(false);
    let quiet = Duration::from_millis(500);
    let (writes, seconds, plain_outputs, coalesced_outputs) = std::thread::scope(|scope| {
        let plain_reader = scope.spawn(|| read_outputs(&plain.outbound, &done, quiet));
        let coalesced_reader = scope.spawn(|| read_outputs(&coalesced.outbound, &done, quiet));
        let start = Instant::now();
        let mut writes = 0u32;
        while start.elapsed() < length {
            surface.inject_output_for_test(
                format!(
                    "\x1b[1;32m   Compiling\x1b[0m crate-{writes} v0.1.0 (/src/crate-{writes})\r\n"
                )
                .as_bytes(),
            );
            writes += 1;
            let next = start + period * writes;
            if let Some(wait) = next.checked_duration_since(Instant::now()) {
                std::thread::sleep(wait);
            }
        }
        let seconds = start.elapsed().as_secs_f64();
        done.store(true, Ordering::Release);
        (
            writes,
            seconds,
            plain_reader.join().expect("plain reader"),
            coalesced_reader.join().expect("coalesced reader"),
        )
    });
    assert!(!plain_outputs.is_empty() && !coalesced_outputs.is_empty());
    assert_eq!(
        joined(&coalesced_outputs),
        joined(&plain_outputs),
        "the coalesced stream carries the same bytes in the same order"
    );
    // The window ends at the last write; the last held bytes go out within
    // one frame after it, so allow that one event.
    let per_second = (coalesced_outputs.len().saturating_sub(1)) as f64 / seconds;
    assert!(
        per_second <= 61.0,
        "{} coalesced output events in {seconds:.2} s ({per_second:.1}/s) for {writes} writes",
        coalesced_outputs.len()
    );
    // Without the capability: one event per write (a busy worker may merge a
    // few queued reads, never many).
    assert!(
        plain_outputs.len() as f64 >= f64::from(writes) * 0.8,
        "{} plain output events for {writes} writes",
        plain_outputs.len()
    );
    disconnect_client(&mux, plain.client, false);
    disconnect_client(&mux, coalesced.client, false);
    mux.shutdown();
}

/// Leading edge: after an idle interval the first bytes (a keypress echo) go
/// out at once; bytes right behind them wait for the interval's end and go
/// out as one event.
#[test]
fn the_first_output_after_idle_is_not_delayed() {
    let (mux, surface) = quiet_surface("coalesce-leading-edge");
    // A long interval, so "at once" and "at the interval's end" are far apart.
    let viewer = attach(&mux, &surface, true, json!({"output_coalesce_ms": 600}));
    std::thread::sleep(Duration::from_millis(700));
    let typed = Instant::now();
    surface.inject_output_for_test(b"a");
    let first = viewer.next_output(Duration::from_secs(5)).expect("the echo");
    assert_eq!(first.bytes, b"a");
    let echo = first.at.duration_since(typed);
    assert!(echo < Duration::from_millis(200), "the echo took {echo:?}");
    surface.inject_output_for_test(b"b");
    surface.inject_output_for_test(b"c");
    let second = viewer.next_output(Duration::from_secs(5)).expect("the held bytes");
    assert_eq!(second.bytes, b"bc", "the bytes behind the echo go out as one event");
    let gap = second.at.duration_since(first.at);
    assert!(gap >= Duration::from_millis(450), "the held bytes went out after {gap:?}");
    disconnect_client(&mux, viewer.client, false);
    mux.shutdown();
}

/// A connection that did not declare the capability gets today's stream: one
/// event per write in today's exact line shape, even with
/// `output_coalesce_ms` on its attach.
#[test]
fn a_viewer_without_the_capability_gets_one_output_per_write() {
    let (mux, surface) = quiet_surface("coalesce-off");
    let viewer = attach(&mux, &surface, false, json!({"output_coalesce_ms": 600}));
    let mut outputs = Vec::new();
    for chunk in [b"one".as_slice(), b"two", b"three"] {
        let written = Instant::now();
        surface.inject_output_for_test(chunk);
        let output = viewer.next_output(Duration::from_secs(5)).expect("output");
        assert!(output.at.duration_since(written) < Duration::from_millis(200));
        assert_eq!(output.bytes, chunk);
        outputs.push(output);
        std::thread::sleep(Duration::from_millis(20));
    }
    let expected = format!(
        "{{\"event\":\"output\",\"surface\":{},\"data\":\"{}\"}}",
        surface.id,
        base64::engine::general_purpose::STANDARD.encode(b"two")
    );
    assert_eq!(outputs[1].line.trim_end(), expected);
    disconnect_client(&mux, viewer.client, false);
    mux.shutdown();
}

#[test]
fn an_interval_over_the_limit_is_refused() {
    let (mux, surface) = quiet_surface("coalesce-limit");
    let (writer, _outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    handle_command(
        &mux,
        client,
        command(json!({"cmd": "set-client-info", "capabilities": ["attach-output-coalesce-v1"]})),
        &writer,
    )
    .unwrap();
    let error = handle_command(
        &mux,
        client,
        command(
            json!({"cmd": "attach-surface", "surface": surface.id, "output_coalesce_ms": 5000}),
        ),
        &writer,
    )
    .expect_err("over the limit");
    assert!(error.to_string().contains("output_coalesce_ms"), "{error}");
    disconnect_client(&mux, client, false);
    mux.shutdown();
}

/// Every `scroll-changed` offset on `outbound`, read as it comes, until
/// `done` is set and `quiet` passes with none, with the time each was read.
fn scroll_offsets(
    outbound: &BoundedOutbound,
    done: &AtomicBool,
    quiet: Duration,
) -> Vec<(Instant, u64)> {
    let mut offsets = Vec::new();
    let mut last = Instant::now();
    while !done.load(Ordering::Acquire) || last.elapsed() < quiet {
        match outbound.try_pop() {
            Some(message) => {
                let value: Value = serde_json::from_str(&message).expect("outbound JSON");
                if value["event"] == "scroll-changed" {
                    offsets.push((Instant::now(), value["offset"].as_u64().expect("offset")));
                    last = Instant::now();
                }
            }
            None => std::thread::sleep(Duration::from_micros(200)),
        }
    }
    offsets
}

/// A coalescing byte viewer's `scroll-changed` follows its frame clock: the
/// first at once, then at most one per interval, the newest position last.
/// A viewer without the capability gets them as they come.
#[test]
fn a_coalescing_viewer_reads_the_newest_scroll_position_once_per_frame() {
    let (mux, surface) = quiet_surface("coalesce-scroll");
    let plain = attach(&mux, &surface, false, json!({}));
    let coalesced = attach(&mux, &surface, true, json!({"output_coalesce_ms": 100}));
    let done = AtomicBool::new(false);
    let quiet = Duration::from_millis(400);
    let (plain_offsets, coalesced_offsets) = std::thread::scope(|scope| {
        let plain_reader = scope.spawn(|| scroll_offsets(&plain.outbound, &done, quiet));
        let coalesced_reader = scope.spawn(|| scroll_offsets(&coalesced.outbound, &done, quiet));
        for offset in 1..=40u64 {
            mux.emit(crate::MuxEvent::ScrollChanged {
                surface: surface.id,
                offset,
                at_bottom: false,
            });
            std::thread::sleep(Duration::from_millis(5));
        }
        done.store(true, Ordering::Release);
        (plain_reader.join().expect("plain"), coalesced_reader.join().expect("coalesced"))
    });
    assert_eq!(plain_offsets.last().map(|(_, offset)| *offset), Some(40), "{plain_offsets:?}");
    let first = coalesced_offsets.first().expect("a position");
    assert_eq!(first.1, 1, "the first position goes out at once");
    assert_eq!(coalesced_offsets.last().map(|(_, offset)| *offset), Some(40), "the newest last");
    // One per 100 ms interval at most (some slack for the reader's clock).
    for pair in coalesced_offsets.windows(2) {
        let gap = pair[1].0.duration_since(pair[0].0);
        assert!(
            gap >= Duration::from_millis(80),
            "{gap:?} between positions: {coalesced_offsets:?}"
        );
    }
    // Without the capability, positions come as the mailbox delivers them:
    // more than one per 100 ms over this 200 ms of scrolling.
    assert!(
        plain_offsets.len() > coalesced_offsets.len(),
        "plain {plain_offsets:?} coalesced {coalesced_offsets:?}"
    );
    disconnect_client(&mux, plain.client, false);
    disconnect_client(&mux, coalesced.client, false);
    mux.shutdown();
}
