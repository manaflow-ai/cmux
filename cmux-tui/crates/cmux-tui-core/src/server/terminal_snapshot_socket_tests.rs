//! terminal-snapshot-v1 over the raw v12 command path, with a captured
//! connection writer: the stream a client reads.

use std::time::{Duration, Instant};

use base64::Engine as _;
use serde_json::{Value, json};

use super::super::tests::captured_writer;
use super::super::{BoundedOutbound, ClientTransport, Command, disconnect_client, handle_command};
use crate::{Mux, SurfaceOptions};

fn command(value: Value) -> Command {
    serde_json::from_value(value).expect("raw command")
}

/// The next stream event other than notifications, within `timeout`.
fn next_event(outbound: &BoundedOutbound, timeout: Duration) -> Option<Value> {
    let deadline = Instant::now() + timeout;
    loop {
        if let Some(message) = outbound.try_pop() {
            let value: Value = serde_json::from_str(&message).expect("outbound JSON");
            if value["event"] != "notification" {
                return Some(value);
            }
            continue;
        }
        if Instant::now() >= deadline {
            return None;
        }
        std::thread::sleep(Duration::from_millis(5));
    }
}

fn decoded_len(event: &Value) -> u64 {
    base64::engine::general_purpose::STANDARD
        .decode(event["data"].as_str().expect("data"))
        .expect("base64")
        .len() as u64
}

#[test]
fn snapshot_viewer_stream_carries_positions_digest_and_requested_snapshots() {
    let mux = Mux::new_for_test("snapshot-socket", SurfaceOptions::default());
    let surface = mux.new_workspace(None, None).unwrap();
    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let version = ghostty_vt::snapshot_version();
    let reply = handle_command(
        &mux,
        client,
        command(json!({
            "cmd": "attach-surface", "surface": surface.id,
            "snapshot": "ghostsnp", "snapshot_version": version,
        })),
        &writer,
    )
    .unwrap();
    assert!(reply.is_object());

    // The first stream event is the READY snapshot, not vt-state.
    let first = next_event(&outbound, Duration::from_secs(5)).expect("snapshot");
    assert_eq!(first["event"], "snapshot", "{first}");
    assert_eq!(first["phase"], "ready");
    assert_eq!(first["version"], version);
    let generation = first["generation"].as_u64().unwrap();
    let mut offset = first["offset"].as_u64().unwrap();

    // Output carries the generation and the offset after each frame.
    surface.inject_output_for_test(b"hello from the host\r\n");
    let mut saw_injected = false;
    let digest = loop {
        let event = next_event(&outbound, Duration::from_secs(6)).expect("output or digest");
        match event["event"].as_str() {
            Some("output") => {
                assert_eq!(event["generation"].as_u64(), Some(generation));
                offset += decoded_len(&event);
                assert_eq!(event["offset"].as_u64(), Some(offset), "offsets are contiguous");
                saw_injected = true;
            }
            Some("digest") => break event,
            // terminal-snapshot-history-v1: the READY's history chunks.
            Some("snapshot") if event["phase"] == "history" => {}
            Some("colors-changed" | "scroll-changed") => {}
            other => panic!("unexpected event {other:?}: {event}"),
        }
    };
    assert!(saw_injected);
    // The digest follows 2 s of idle output and names the viewer's position.
    assert_eq!(digest["offset"].as_u64(), Some(offset));
    assert_eq!(digest["generation"].as_u64(), Some(generation));
    assert_eq!(digest["sha256"].as_str().map(str::len), Some(64));

    // A request answers, and the requested snapshot follows on the stream.
    let reply = handle_command(
        &mux,
        client,
        command(json!({
            "cmd": "snapshot-request", "surface": surface.id,
            "reason": "digest_mismatch", "request_id": "r1",
        })),
        &writer,
    )
    .unwrap();
    assert_eq!(reply["status"], "accepted", "{reply}");
    assert_eq!(reply["request_id"], "r1");
    let snapshot = next_event(&outbound, Duration::from_secs(5)).expect("requested snapshot");
    assert_eq!(snapshot["event"], "snapshot", "{snapshot}");
    assert_eq!(snapshot["offset"].as_u64(), Some(offset));

    // A snapshot cancels the pending digest: none follows without output.
    let after = next_event(&outbound, Duration::from_millis(2_600));
    assert!(after.as_ref().is_none_or(|event| event["event"] != "digest"), "{after:?}");

    disconnect_client(&mux, client, false);
    mux.shutdown();
}

#[test]
fn a_client_without_snapshot_gets_the_replay_stream() {
    let mux = Mux::new_for_test("snapshot-socket-replay", SurfaceOptions::default());
    let surface = mux.new_workspace(None, None).unwrap();
    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    handle_command(
        &mux,
        client,
        command(json!({"cmd": "attach-surface", "surface": surface.id})),
        &writer,
    )
    .unwrap();
    let first = next_event(&outbound, Duration::from_secs(5)).expect("vt-state");
    assert_eq!(first["event"], "vt-state", "{first}");
    surface.inject_output_for_test(b"replay viewer\r\n");
    loop {
        let event = next_event(&outbound, Duration::from_secs(5)).expect("output");
        if event["event"] == "output" {
            // The replay stream is unchanged: no snapshot position fields.
            assert!(event.get("generation").is_none() && event.get("offset").is_none(), "{event}");
            break;
        }
    }
    disconnect_client(&mux, client, false);
    mux.shutdown();
}

// ---- terminal-snapshot-history-v1 -------------------------------------

/// A surface running `cat` (it prints nothing on its own) whose primary
/// screen holds `lines` lines of scrollback.
fn quiet_surface_with_scrollback(
    session: &str,
    lines: usize,
) -> (std::sync::Arc<Mux>, std::sync::Arc<crate::Surface>) {
    let mux = Mux::new_for_test(
        session,
        SurfaceOptions { command: Some(vec!["cat".to_string()]), ..SurfaceOptions::default() },
    );
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    let mut chunk = String::new();
    for line in 0..lines {
        chunk.push_str(&format!(
            "\x1b[32m{line:06}\x1b[0m compiling crate-{} v0.{}.{} (/home/dev/src/project/crates/c{}) in {}ms\r\n",
            line % 977,
            line % 13,
            line % 101,
            line % 31,
            line % 4099
        ));
        if chunk.len() > 1 << 16 {
            surface.inject_output_for_test(chunk.as_bytes());
            chunk.clear();
        }
    }
    surface.inject_output_for_test(chunk.as_bytes());
    (mux, surface)
}

fn attach_snapshot_viewer(
    mux: &std::sync::Arc<Mux>,
    surface: &crate::Surface,
) -> (super::super::MessageWriter, std::sync::Arc<BoundedOutbound>, u64) {
    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    handle_command(
        mux,
        client,
        command(json!({
            "cmd": "attach-surface", "surface": surface.id,
            "snapshot": "ghostsnp", "snapshot_version": ghostty_vt::snapshot_version(),
        })),
        &writer,
    )
    .unwrap();
    (writer, outbound, client)
}

fn data(event: &Value) -> Vec<u8> {
    base64::engine::general_purpose::STANDARD
        .decode(event["data"].as_str().expect("data"))
        .expect("base64")
}

/// A history chunk's uncompressed bytes: `data` is raw DEFLATE (RFC 1951,
/// no zlib or gzip framing) of at most 1 MiB, and inflates alone to
/// `raw_bytes`.
fn history_bytes(event: &Value) -> Vec<u8> {
    use std::io::Read as _;
    assert_eq!(event["compression"], "deflate", "{event}");
    let packed = data(event);
    let mut raw = Vec::new();
    flate2::read::DeflateDecoder::new(&packed[..]).read_to_end(&mut raw).expect("raw deflate");
    assert_eq!(event["raw_bytes"].as_u64(), Some(raw.len() as u64), "raw_bytes");
    assert!(raw.len() <= 1 << 20, "a history chunk holds at most 1 MiB");
    assert!(packed.len() < raw.len().max(64), "the chunk is compressed");
    raw
}

/// Record tags after the envelope; panics when a record is incomplete.
fn record_tags(snapshot: &[u8]) -> Vec<u16> {
    let mut consumed = ghostty_vt::SNAPSHOT_ENVELOPE_LEN;
    let tags: Vec<u16> = ghostty_vt::snapshot_records(snapshot)
        .map(|record| {
            consumed += record.bytes.len();
            record.tag
        })
        .collect();
    assert_eq!(consumed, snapshot.len(), "the snapshot ends on a record boundary");
    tags
}

#[test]
fn snapshot_history_capability_is_advertised() {
    let mux = Mux::new_for_test("snapshot-history-identify", SurfaceOptions::default());
    let (writer, _outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let identity =
        handle_command(&mux, client, command(json!({"cmd": "identify"})), &writer).unwrap();
    let capabilities = identity["capabilities"].as_array().expect("capabilities");
    assert!(capabilities.iter().any(|value| value == "terminal-snapshot-history-v1"), "{identity}");
    disconnect_client(&mux, client, false);
    mux.shutdown();
}

/// READY plus the history chunks that follow it, at the same generation and
/// offset, form one COMPLETE snapshot: HISTORY manifests, PAGE records and
/// FINISH, which `ghostty_surface_restore_snapshot(HISTORY)` needs.
#[test]
fn every_ready_is_followed_by_its_history_through_finish() {
    let (mux, surface) = quiet_surface_with_scrollback("snapshot-history-complete", 2_000);
    let (_writer, outbound, client) = attach_snapshot_viewer(&mux, &surface);
    let ready = next_event(&outbound, Duration::from_secs(5)).expect("ready");
    assert_eq!(ready["phase"], "ready", "{ready}");
    let mut complete = data(&ready);
    loop {
        let event = next_event(&outbound, Duration::from_secs(5)).expect("history");
        if event["event"] != "snapshot" {
            continue;
        }
        assert_eq!(event["phase"], "history", "{event}");
        assert_eq!(event["generation"], ready["generation"]);
        assert_eq!(event["offset"], ready["offset"]);
        assert_eq!(event["version"], ready["version"]);
        complete.extend_from_slice(&history_bytes(&event));
        if event["done"] == true {
            break;
        }
    }
    let tags = record_tags(&complete);
    let ready_at = tags.iter().position(|tag| *tag == ghostty_vt::snapshot_tag::READY).unwrap();
    assert_eq!(tags[ready_at + 1], ghostty_vt::snapshot_tag::HISTORY);
    assert_eq!(tags.last(), Some(&ghostty_vt::snapshot_tag::FINISH));
    // `cat` prints nothing, so the terminal is still at the snapshot's cut:
    // READY plus history is byte for byte the host's COMPLETE encode.
    let host = surface.encode_terminal_snapshot(ghostty_vt::SnapshotPhase::Complete).unwrap();
    assert!(complete == host, "READY + history equals the COMPLETE snapshot");
    let pages = ghostty_vt::primary_history_pages(&complete).expect("valid history");
    let rows: u64 = pages.iter().map(|page| u64::from(page.rows)).sum();
    assert!(rows >= 1_000, "the scrollback travels with the snapshot: {rows} rows");
    disconnect_client(&mux, client, false);
    mux.shutdown();
}

/// History is lower priority than live output: a viewer with megabytes of
/// scrollback still gets new output before its history is done. A
/// snapshot-request in the middle replaces the old history: no chunk of it
/// ends before the new READY, and the new READY gets a full history.
#[test]
fn live_output_overtakes_history_and_a_new_ready_cancels_the_old_history() {
    let (mux, surface) = quiet_surface_with_scrollback("snapshot-history-priority", 60_000);
    let (writer, outbound, client) = attach_snapshot_viewer(&mux, &surface);
    let ready = next_event(&outbound, Duration::from_secs(10)).expect("ready");
    assert_eq!(ready["phase"], "ready", "{ready}");
    let first = next_event(&outbound, Duration::from_secs(10)).expect("first history chunk");
    assert_eq!(first["phase"], "history", "{first}");
    // About 18 MiB of history (styled rows): many more chunks than the two
    // the outbound stream holds plus the one the worker is sending.
    assert_ne!(first["done"], true, "60k styled lines take many chunks");

    // The worker is blocked on the outbound stream (nothing drains): live
    // output queues meanwhile and must go out before the rest of the history.
    surface.inject_output_for_test(b"live while history streams\r\n");
    loop {
        let event = next_event(&outbound, Duration::from_secs(10)).expect("event");
        match (event["event"].as_str(), event["phase"].as_str()) {
            (Some("output"), _) => {
                assert_eq!(event["generation"], ready["generation"]);
                break;
            }
            (Some("snapshot"), Some("history")) => {
                assert_ne!(event["done"], true, "history finished before the live output");
            }
            _ => {}
        }
    }

    // Mid-history request (after the 500 ms request interval).
    std::thread::sleep(Duration::from_millis(600));
    let reply = handle_command(
        &mux,
        client,
        command(json!({"cmd": "snapshot-request", "surface": surface.id, "reason": "gap"})),
        &writer,
    )
    .unwrap();
    assert_eq!(reply["status"], "accepted", "{reply}");
    let second = loop {
        let event = next_event(&outbound, Duration::from_secs(10)).expect("event");
        if event["event"] != "snapshot" {
            continue;
        }
        if event["phase"] == "ready" {
            break event;
        }
        assert_ne!(event["done"], true, "the old history must not finish after the request");
    };
    let mut complete = data(&second);
    loop {
        let event = next_event(&outbound, Duration::from_secs(10)).expect("history");
        if event["event"] != "snapshot" {
            continue;
        }
        assert_eq!(event["phase"], "history", "{event}");
        assert_eq!(event["offset"], second["offset"]);
        complete.extend_from_slice(&history_bytes(&event));
        if event["done"] == true {
            break;
        }
    }
    assert_eq!(record_tags(&complete).last(), Some(&ghostty_vt::snapshot_tag::FINISH));
    ghostty_vt::primary_history_pages(&complete).expect("the new READY gets a full history");
    disconnect_client(&mux, client, false);
    mux.shutdown();
}

/// A burst of grid changes while the worker is busy (its history fills the
/// outbound stream, which nothing drains) collapses into the snapshot of the
/// last grid: the pending snapshot absorbs every later change.
#[test]
fn a_burst_of_grid_changes_collapses_into_the_last_grid() {
    let (mux, surface) = quiet_surface_with_scrollback("snapshot-history-burst", 20_000);
    let (_writer, outbound, client) = attach_snapshot_viewer(&mux, &surface);
    let first = next_event(&outbound, Duration::from_secs(10)).expect("ready");
    assert_eq!(first["phase"], "ready", "{first}");
    for step in 0..10u16 {
        surface.resize(60 + step, 20).unwrap();
        std::thread::sleep(Duration::from_millis(20));
    }
    let mut readies = Vec::new();
    while let Some(event) = next_event(&outbound, Duration::from_secs(3)) {
        if event["event"] == "snapshot" && event["phase"] == "ready" {
            readies.push((event["cols"].as_u64(), event["rows"].as_u64()));
        }
    }
    assert!(
        readies.len() <= 2,
        "10 grid changes sent {} READY snapshots: {readies:?}",
        readies.len()
    );
    assert_eq!(readies.last(), Some(&(Some(69), Some(20))), "the last READY has the settled grid");
    disconnect_client(&mux, client, false);
    mux.shutdown();
}

/// Bytes per settled resize for a large styled scrollback (measurement).
/// `cargo test -p cmux-tui-core --release --lib snapshot_bytes_per_settled_resize -- --ignored --nocapture`
#[test]
#[ignore = "measurement"]
fn snapshot_bytes_per_settled_resize() {
    let (mux, surface) = quiet_surface_with_scrollback("snapshot-history-bytes", 100_000);
    let (_writer, outbound, client) = attach_snapshot_viewer(&mux, &surface);
    let started = Instant::now();
    let (mut ready_b64, mut history_b64, mut raw, mut chunks) = (0usize, 0usize, 0usize, 0usize);
    loop {
        let event = next_event(&outbound, Duration::from_secs(30)).expect("snapshot");
        if event["event"] != "snapshot" {
            continue;
        }
        let len = event["data"].as_str().unwrap().len();
        if event["phase"] == "ready" {
            ready_b64 += len;
            continue;
        }
        history_b64 += len;
        raw += history_bytes(&event).len();
        chunks += 1;
        if event["done"] == true {
            break;
        }
    }
    println!(
        "snapshot-bytes-per-resize ready_b64={ready_b64} history_b64={history_b64} \
         history_raw={raw} chunks={chunks} total_b64={} elapsed_ms={}",
        ready_b64 + history_b64,
        started.elapsed().as_millis()
    );
    disconnect_client(&mux, client, false);
    mux.shutdown();
}

// ---- terminal-snapshot-local-history-v1 -------------------------------

fn attach_local_history_viewer(
    mux: &std::sync::Arc<Mux>,
    surface: &crate::Surface,
) -> (super::super::MessageWriter, std::sync::Arc<BoundedOutbound>, u64) {
    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    handle_command(
        mux,
        client,
        command(json!({
            "cmd": "attach-surface", "surface": surface.id,
            "snapshot": "ghostsnp", "snapshot_version": ghostty_vt::snapshot_version(),
            "snapshot_local_history": true,
        })),
        &writer,
    )
    .unwrap();
    (writer, outbound, client)
}

/// Drain the attach READY and its history through `done`; returns the READY.
fn drain_ready_and_history(outbound: &BoundedOutbound) -> Value {
    let ready = next_event(outbound, Duration::from_secs(10)).expect("ready");
    assert_eq!(ready["phase"], "ready", "{ready}");
    loop {
        let event = next_event(outbound, Duration::from_secs(10)).expect("history");
        if event["event"] == "snapshot" && event["phase"] == "history" && event["done"] == true {
            return ready;
        }
    }
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

#[test]
fn snapshot_local_history_capability_is_advertised() {
    let mux = Mux::new_for_test("snapshot-local-history-identify", SurfaceOptions::default());
    let (writer, _outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let identity =
        handle_command(&mux, client, command(json!({"cmd": "identify"})), &writer).unwrap();
    let capabilities = identity["capabilities"].as_array().expect("capabilities");
    assert!(
        capabilities.iter().any(|value| value == "terminal-snapshot-local-history-v1"),
        "{identity}"
    );
    disconnect_client(&mux, client, false);
    mux.shutdown();
}

/// A viewer that reflows its own history gets every output frame before a
/// resize, then one READY of the new grid at exactly the resize's generation
/// and offset, with the host's history check and no history after it; later
/// output carries the new generation and continues the offsets.
#[test]
fn a_resize_reaches_a_local_history_viewer_as_one_ready_at_the_resize_cut() {
    let (mux, surface) = quiet_surface_with_scrollback("snapshot-local-history-cut", 2_000);
    let (_writer, outbound, client) = attach_local_history_viewer(&mux, &surface);
    let first = drain_ready_and_history(&outbound);
    let generation = first["generation"].as_u64().unwrap();
    let mut offset = first["offset"].as_u64().unwrap();

    surface.inject_output_for_test(b"before the resize\r\n");
    let (cut_generation, cut_offset) = surface.snapshot_stream_position().unwrap();
    surface.resize(60, 20).unwrap();
    assert_eq!(cut_generation, generation);

    let mut saw_before = false;
    let ready = loop {
        let event = next_event(&outbound, Duration::from_secs(5)).expect("output or ready");
        match (event["event"].as_str(), event["phase"].as_str()) {
            (Some("output"), _) => {
                assert_eq!(event["generation"].as_u64(), Some(generation), "{event}");
                offset += decoded_len(&event);
                assert_eq!(event["offset"].as_u64(), Some(offset));
                saw_before = true;
            }
            (Some("snapshot"), Some("ready")) => break event,
            (Some("snapshot"), _) => panic!("no history before the local READY: {event}"),
            _ => {}
        }
    };
    assert!(saw_before, "the output before the resize is not dropped");
    assert_eq!(ready["history"], "local", "{ready}");
    assert_eq!(ready["generation"].as_u64(), Some(cut_generation + 1));
    assert_eq!(ready["offset"].as_u64(), Some(cut_offset));
    assert_eq!(ready["offset"].as_u64(), Some(offset));
    assert_eq!((ready["cols"].as_u64(), ready["rows"].as_u64()), (Some(60), Some(20)));
    // `cat` prints nothing: the host is still at the cut.
    let host = surface.encode_terminal_snapshot(ghostty_vt::SnapshotPhase::Ready).unwrap();
    assert!(data(&ready) == host, "the local READY is the host's READY of the new grid");
    let check = surface.terminal_history_digest().expect("history digest");
    assert_eq!(ready["history_rows"].as_u64(), Some(check.rows));
    assert_eq!(ready["history_digest"].as_str(), Some(hex(&check.digest).as_str()));

    surface.inject_output_for_test(b"after the resize\r\n");
    let output = loop {
        let event = next_event(&outbound, Duration::from_secs(5)).expect("output");
        match (event["event"].as_str(), event["phase"].as_str()) {
            (Some("output"), _) => break event,
            (Some("snapshot"), _) => panic!("nothing follows a local READY: {event}"),
            _ => {}
        }
    };
    assert_eq!(output["generation"].as_u64(), Some(cut_generation + 1));
    assert_eq!(output["offset"].as_u64(), Some(cut_offset + decoded_len(&output)));
    while let Some(event) = next_event(&outbound, Duration::from_millis(500)) {
        assert_ne!(event["event"], "snapshot", "no history follows a local READY: {event}");
    }
    disconnect_client(&mux, client, false);
    mux.shutdown();
}

/// A burst of resizes gives one local READY per resize, in order, each at
/// its own generation.
#[test]
fn a_burst_of_resizes_gives_one_local_ready_per_resize_in_order() {
    let (mux, surface) = quiet_surface_with_scrollback("snapshot-local-history-burst", 2_000);
    let (_writer, outbound, client) = attach_local_history_viewer(&mux, &surface);
    let first = drain_ready_and_history(&outbound);
    let generation = first["generation"].as_u64().unwrap();
    for step in 0..10u16 {
        surface.resize(60 + step, 20).unwrap();
    }
    let mut readies = Vec::new();
    while let Some(event) = next_event(&outbound, Duration::from_secs(2)) {
        if event["event"] != "snapshot" {
            continue;
        }
        assert_eq!(event["phase"], "ready", "no history in a burst of local READYs: {event}");
        assert_eq!(event["history"], "local", "{event}");
        assert_eq!(event["offset"], first["offset"]);
        readies.push((event["generation"].as_u64().unwrap(), event["cols"].as_u64().unwrap()));
    }
    let expected: Vec<(u64, u64)> =
        (0..10u64).map(|step| (generation + 1 + step, 60 + step)).collect();
    assert_eq!(readies, expected);
    disconnect_client(&mux, client, false);
    mux.shutdown();
}

/// A local-history viewer still receiving the history of its attach READY
/// cannot reflow a history it does not have: a resize then brings a READY
/// with the complete history at a new cut.
#[test]
fn a_local_history_viewer_behind_on_history_gets_ready_and_history() {
    let (mux, surface) = quiet_surface_with_scrollback("snapshot-local-history-behind", 20_000);
    let (_writer, outbound, client) = attach_local_history_viewer(&mux, &surface);
    let first = next_event(&outbound, Duration::from_secs(10)).expect("ready");
    assert_eq!(first["phase"], "ready", "{first}");
    let chunk = next_event(&outbound, Duration::from_secs(10)).expect("history chunk");
    assert_eq!(chunk["phase"], "history", "{chunk}");
    assert_ne!(chunk["done"], true, "20k styled lines take many chunks");
    surface.resize(60, 20).unwrap();
    let ready = loop {
        let event = next_event(&outbound, Duration::from_secs(10)).expect("event");
        if event["event"] == "snapshot" && event["phase"] == "ready" {
            break event;
        }
    };
    assert!(ready.get("history").is_none(), "{ready}");
    assert_eq!(ready["cols"].as_u64(), Some(60));
    let mut complete = data(&ready);
    loop {
        let event = next_event(&outbound, Duration::from_secs(10)).expect("history");
        if event["event"] != "snapshot" {
            continue;
        }
        assert_eq!(event["phase"], "history", "{event}");
        assert_eq!(event["generation"], ready["generation"]);
        complete.extend_from_slice(&history_bytes(&event));
        if event["done"] == true {
            break;
        }
    }
    assert_eq!(record_tags(&complete).last(), Some(&ghostty_vt::snapshot_tag::FINISH));
    disconnect_client(&mux, client, false);
    mux.shutdown();
}

/// A viewer that did not opt in keeps READY plus history at every resize.
#[test]
fn a_viewer_without_local_history_gets_ready_and_history_at_a_resize() {
    let (mux, surface) = quiet_surface_with_scrollback("snapshot-local-history-off", 2_000);
    let (_writer, outbound, client) = attach_snapshot_viewer(&mux, &surface);
    drain_ready_and_history(&outbound);
    surface.resize(60, 20).unwrap();
    let ready = loop {
        let event = next_event(&outbound, Duration::from_secs(5)).expect("ready");
        if event["event"] == "snapshot" {
            break event;
        }
    };
    assert_eq!(ready["phase"], "ready", "{ready}");
    assert!(ready.get("history").is_none() && ready.get("history_digest").is_none(), "{ready}");
    loop {
        let event = next_event(&outbound, Duration::from_secs(5)).expect("history");
        if event["event"] != "snapshot" {
            continue;
        }
        assert_eq!(event["phase"], "history", "{event}");
        assert_eq!(event["generation"], ready["generation"]);
        if event["done"] == true {
            break;
        }
    }
    disconnect_client(&mux, client, false);
    mux.shutdown();
}

/// Bytes per settled resize with local history for a large styled scrollback
/// (measurement).
/// `cargo test -p cmux-tui-core --release --lib snapshot_bytes_per_settled_resize_with_local_history -- --ignored --nocapture`
#[test]
#[ignore = "measurement"]
fn snapshot_bytes_per_settled_resize_with_local_history() {
    let (mux, surface) = quiet_surface_with_scrollback("snapshot-local-history-bytes", 100_000);
    let (_writer, outbound, client) = attach_local_history_viewer(&mux, &surface);
    drain_ready_and_history(&outbound);
    let started = Instant::now();
    surface.resize(100, 30).unwrap();
    let (mut ready_b64, mut history_b64, mut events) = (0usize, 0usize, 0usize);
    while let Some(event) = next_event(&outbound, Duration::from_secs(2)) {
        if event["event"] != "snapshot" {
            continue;
        }
        events += 1;
        let len = event["data"].as_str().unwrap().len();
        if event["phase"] == "ready" {
            assert_eq!(event["history"], "local", "{event}");
            ready_b64 += len;
        } else {
            history_b64 += len;
        }
    }
    println!(
        "snapshot-bytes-per-resize-local ready_b64={ready_b64} history_b64={history_b64} \
         snapshot_events={events} total_b64={} elapsed_ms={}",
        ready_b64 + history_b64,
        started.elapsed().as_millis().saturating_sub(2_000)
    );
    disconnect_client(&mux, client, false);
    mux.shutdown();
}
