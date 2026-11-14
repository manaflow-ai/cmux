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
/// screen holds `lines` lines of scrollback, at the default scrollback limit.
fn quiet_surface_with_scrollback(
    session: &str,
    lines: usize,
) -> (std::sync::Arc<Mux>, std::sync::Arc<crate::Surface>) {
    quiet_surface_with_scrollback_limit(session, lines, SurfaceOptions::default().scrollback)
}

/// [`quiet_surface_with_scrollback`] with an explicit scrollback limit in
/// bytes (`scrollback-limit-bytes`), for tests that need more history than
/// the default limit keeps.
fn quiet_surface_with_scrollback_limit(
    session: &str,
    lines: usize,
    scrollback: usize,
) -> (std::sync::Arc<Mux>, std::sync::Arc<crate::Surface>) {
    let mux = Mux::new_for_test(
        session,
        SurfaceOptions {
            command: Some(vec!["cat".to_string()]),
            scrollback,
            ..SurfaceOptions::default()
        },
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
    // 50 MB, not the 10 MB default (about 15,000 rows, #20257): the default
    // keeps too few of the 60k lines for the history to outlast the
    // mid-history request below.
    let (mux, surface) =
        quiet_surface_with_scrollback_limit("snapshot-history-priority", 60_000, 50_000_000);
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

// ---- Kitty images in GHOSTSNP ------------------------------------------

/// Kitty `a=T` of one `width`x`height` RGBA image with id `id`, placed at the
/// cursor over 4x2 cells. `noise` fills it with pseudo-random pixels (they
/// do not compress), else one color.
fn kitty_image(id: u32, width: u32, height: u32, noise: bool) -> Vec<u8> {
    let mut pixels = vec![0x3c_u8; (width * height * 4) as usize];
    if noise {
        let mut state = 0x9e37_79b9_7f4a_7c15_u64 ^ u64::from(id);
        for chunk in pixels.chunks_mut(8) {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            let bytes = state.to_le_bytes();
            chunk.copy_from_slice(&bytes[..chunk.len()]);
        }
    }
    let data = base64::engine::general_purpose::STANDARD.encode(pixels);
    format!("\x1b_Ga=T,t=d,f=32,i={id},p=1,s={width},v={height},c=4,r=2,q=2;{data}\x1b\\")
        .into_bytes()
}

/// A quiet surface with scrollback that shows one Kitty image.
fn quiet_surface_with_image(
    session: &str,
    width: u32,
    height: u32,
    noise: bool,
) -> (std::sync::Arc<Mux>, std::sync::Arc<crate::Surface>) {
    let (mux, surface) = quiet_surface_with_scrollback(session, 200);
    surface.inject_output_for_test(b"image below\r\n");
    surface.inject_output_for_test(&kitty_image(7, width, height, noise));
    surface.inject_output_for_test(b"\r\nafter the image\r\n");
    let shown = surface
        .with_terminal(|term| term.kitty_graphics_snapshot().map(|graphics| graphics.images.len()))
        .expect("PTY surface")
        .expect("kitty graphics");
    assert_eq!(shown, 1, "the host stores the image (Kitty graphics enabled)");
    (mux, surface)
}

/// A GHOSTSNP attach the way older Mac apps ask: with the former
/// `terminal-snapshot-images-v1` opt-in `snapshot_images: true`, which the
/// host accepts and ignores.
fn attach_images_viewer(
    mux: &std::sync::Arc<Mux>,
    surface: &crate::Surface,
    local_history: bool,
) -> (super::super::MessageWriter, std::sync::Arc<BoundedOutbound>, u64) {
    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    handle_command(
        mux,
        client,
        command(json!({
            "cmd": "attach-surface", "surface": surface.id,
            "snapshot": "ghostsnp", "snapshot_version": ghostty_vt::snapshot_version(),
            "snapshot_images": true, "snapshot_local_history": local_history,
        })),
        &writer,
    )
    .unwrap();
    (writer, outbound, client)
}

/// After `ready`: the complete snapshot, READY plus its history through
/// `done`. Other events are skipped; any other snapshot phase fails.
fn drain_snapshot(outbound: &BoundedOutbound, ready: &Value) -> Vec<u8> {
    let mut complete = data(ready);
    loop {
        let event = next_event(outbound, Duration::from_secs(10)).expect("history");
        if event["event"] != "snapshot" {
            continue;
        }
        assert_eq!(event["phase"], "history", "only history follows a READY: {event}");
        assert_eq!(event["generation"], ready["generation"]);
        complete.extend(history_bytes(&event));
        if event["done"] == true {
            return complete;
        }
    }
}

/// GHOSTSNP owns image transport: the host no longer offers the separate
/// images phase.
#[test]
fn the_former_snapshot_images_capability_is_not_advertised() {
    let mux = Mux::new_for_test("snapshot-images-identify", SurfaceOptions::default());
    let (writer, _outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let identity =
        handle_command(&mux, client, command(json!({"cmd": "identify"})), &writer).unwrap();
    let capabilities = identity["capabilities"].as_array().expect("capabilities");
    assert!(capabilities.iter().all(|value| value != "terminal-snapshot-images-v1"), "{identity}");
    disconnect_client(&mux, client, false);
    mux.shutdown();
}

/// A 64x64 8-bit RGB PNG (one color), base64.
const PNG_64_RGB_BASE64: &str = "iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAAAT0lEQVR42u3PQQkAAAgEsItjJhMbywi+hcEKLFP9WgQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQELgs6CKEtxmKJKgAAAABJRU5ErkJggg==";

/// The dogfood transmission (400 short lines, then `f=100,a=T,c=8,r=4` with
/// a PNG, no id, no `q`) through the reader's parse path, then an attach by
/// identity (no surface) gets a GHOSTSNP whose READY plus history restore
/// the image: one KITTY_IMAGE_STORAGE and one KITTY_IMAGE_PAYLOAD record,
/// and the restored terminal re-encodes the host's storage record. The real
/// PTY child and terminal host flow is the cmux-tui integration test
/// `a_hosted_png_reaches_a_snapshot_viewer` (this test mux runs no host).
#[test]
fn a_png_transmission_reaches_an_identity_attach_in_ghostsnp() {
    use ghostty_vt::snapshot_tag::{KITTY_IMAGE_PAYLOAD, KITTY_IMAGE_STORAGE};
    let (mux, surface) = quiet_surface_with_scrollback("snapshot-images-png", 0);
    for line in 0..400 {
        surface.inject_output_for_test(format!("line {line}\r\n").as_bytes());
    }
    surface.inject_output_for_test(
        format!("\x1b_Gf=100,a=T,c=8,r=4;{PNG_64_RGB_BASE64}\x1b\\IMAGE-PRINTED\r\n").as_bytes(),
    );
    let stored = surface
        .with_terminal(|term| {
            let images = term.kitty_graphics_snapshot().map(|g| g.images.len()).unwrap_or(0);
            (images, term.kitty_image_generation().unwrap_or(0))
        })
        .unwrap();
    assert_eq!(stored.0, 1, "the host terminal stores the PNG image");
    assert!(stored.1 > 0, "the Kitty image generation moved");

    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    handle_command(
        &mux,
        client,
        command(json!({
            "cmd": "attach-surface",
            "expected_generation": mux.registry_identity().1,
            "expected_terminal_id": surface.terminal_public_id().unwrap().as_str(),
            "snapshot": "ghostsnp", "snapshot_version": ghostty_vt::snapshot_version(),
        })),
        &writer,
    )
    .unwrap();
    let ready = next_event(&outbound, Duration::from_secs(10)).expect("ready");
    assert_eq!(ready["phase"], "ready", "{ready}");
    let complete = drain_snapshot(&outbound, &ready);
    let tags = record_tags(&complete);
    let count = |tag: u16| tags.iter().filter(|seen| **seen == tag).count();
    assert_eq!(count(KITTY_IMAGE_STORAGE), 1, "{tags:?}");
    assert_eq!(count(KITTY_IMAGE_PAYLOAD), 1, "GHOSTSNP carries the PNG pixels: {tags:?}");
    let storage = |snapshot: &[u8]| {
        ghostty_vt::snapshot_records(snapshot)
            .find(|record| record.tag == KITTY_IMAGE_STORAGE)
            .map(|record| record.payload().to_vec())
    };
    let restored = ghostty_vt::reencode_ready(&complete).expect("the snapshot decodes");
    assert!(storage(&data(&ready)).is_some(), "the READY names the PNG");
    assert_eq!(storage(&restored), storage(&data(&ready)), "GHOSTSNP alone restores the PNG");
    assert_no_snapshot_event(&outbound, Duration::from_millis(500), "nothing after the history");
    disconnect_client(&mux, client, false);
    mux.shutdown();
}

/// No snapshot event arrives within `wait`.
fn assert_no_snapshot_event(outbound: &BoundedOutbound, wait: Duration, why: &str) {
    while let Some(event) = next_event(outbound, wait) {
        assert_ne!(event["event"], "snapshot", "{why}: {event}");
    }
}

// ---- one owner of image transport --------------------------------------

/// SNAPSHOT DOUBLE IMAGE: since the ghostty-next sync of #35478 (upstream
/// c7f68a7f4), GHOSTSNP itself carries every Kitty image: a
/// KITTY_IMAGE_STORAGE record (tag 8) before READY and a KITTY_IMAGE_PAYLOAD
/// record (tag 9) with the pixels in the history. An attach that asks for
/// images the way the Mac app does (`snapshot_images: true`) gets each image
/// once: one payload record, no images phase after the history, and the READY
/// plus its history alone restore the host's images and placements.
#[test]
fn an_attach_sends_each_kitty_image_once() {
    use ghostty_vt::snapshot_tag::{KITTY_IMAGE_PAYLOAD, KITTY_IMAGE_STORAGE};
    let (mux, surface) = quiet_surface_with_image("snapshot-image-once", 64, 64, false);
    let (_writer, outbound, client) = attach_images_viewer(&mux, &surface, false);
    let ready = next_event(&outbound, Duration::from_secs(10)).expect("ready");
    assert_eq!(ready["phase"], "ready", "{ready}");
    let ready_bytes = data(&ready);
    let mut complete = ready_bytes.clone();
    let (mut history_done, mut images_phase_bytes, mut snapshot_bytes) =
        (false, 0usize, ready["data"].as_str().unwrap().len());
    // Every snapshot event until 500 ms after the last history chunk.
    loop {
        let wait = if history_done { Duration::from_millis(500) } else { Duration::from_secs(10) };
        let Some(event) = next_event(&outbound, wait) else { break };
        if event["event"] != "snapshot" {
            continue;
        }
        snapshot_bytes += event["data"].as_str().map_or(0, str::len);
        match event["phase"].as_str() {
            Some("history") => {
                assert!(!history_done, "history after its last chunk: {event}");
                complete.extend(history_bytes(&event));
                history_done = event["done"] == true;
            }
            Some("images") => images_phase_bytes += data(&event).len(),
            _ => panic!("unexpected snapshot event: {event}"),
        }
    }
    assert!(history_done, "the READY's history arrived through its last chunk");
    let tags = record_tags(&complete);
    let count = |tag: u16| tags.iter().filter(|seen| **seen == tag).count();
    println!(
        "snapshot-image-once: base64 bytes on the attach {snapshot_bytes}, \
         GHOSTSNP payload records {}, images phase bytes {images_phase_bytes}",
        count(KITTY_IMAGE_PAYLOAD)
    );
    assert_eq!(count(KITTY_IMAGE_STORAGE), 1, "the primary screen's image storage: {tags:?}");
    assert_eq!(count(KITTY_IMAGE_PAYLOAD), 1, "GHOSTSNP carries the pixels once: {tags:?}");
    assert_eq!(
        images_phase_bytes, 0,
        "the attach sends the image a second time, in an images phase after the history"
    );
    // A decoder that reads GHOSTSNP only restores the image and its
    // placement: re-encoding the restored terminal gives the host's storage
    // record.
    let storage = |snapshot: &[u8]| {
        ghostty_vt::snapshot_records(snapshot)
            .find(|record| record.tag == KITTY_IMAGE_STORAGE)
            .map(|record| record.payload().to_vec())
    };
    let restored = ghostty_vt::reencode_ready(&complete).expect("the snapshot decodes");
    assert!(storage(&ready_bytes).is_some(), "the READY names the image");
    assert_eq!(storage(&restored), storage(&ready_bytes), "GHOSTSNP alone restores the image");
    disconnect_client(&mux, client, false);
    mux.shutdown();
}

// ---- golden contract fixture --------------------------------------------

/// The checked-in host event lines of the dogfood PNG attach.
const DOGFOOD_PNG_FIXTURE: &str = "spec/fixtures/terminal-snapshot-dogfood-png.jsonl";

/// One snapshot event as a fixture line. Volatile values become fixed
/// placeholders: `surface` (a per-process surface counter) and
/// `marker_epoch` (a process-wide counter) are `0`. Every other field is the
/// host's real value.
fn fixture_line(event: &Value) -> String {
    let mut event = event.clone();
    event["surface"] = json!(0);
    if event.get("marker_epoch").is_some() {
        event["marker_epoch"] = json!(0);
    }
    serde_json::to_string(&event).expect("fixture JSON")
}

/// Golden contract of the S3k dogfood flow: an 80x24 terminal with 40 short
/// lines of scrollback and one 64x64 RGB PNG (`f=100,a=T,c=8,r=4`, no id, no
/// `q`); a plain READY attach with `snapshot_local_history` (and the ignored
/// former `snapshot_images` opt-in) gets READY and its history chunks; then a
/// resize to 60x20 gives one local READY. The lines must equal
/// `spec/fixtures/terminal-snapshot-dogfood-png.jsonl`;
/// `CMUX_UPDATE_SNAPSHOT_FIXTURE=1` rewrites the file. GHOSTSNP carries the
/// image (the ghostty-next sync of #35478, upstream c7f68a7f4): a
/// `kitty_image_storage` record (tag 8) before READY and a
/// `kitty_image_payload` record (tag 9) in the history chunk.
#[test]
fn dogfood_png_snapshot_events_match_the_golden_fixture() {
    let (mux, surface) = quiet_surface_with_scrollback("snapshot-images-fixture", 0);
    for line in 0..40 {
        surface.inject_output_for_test(format!("line {line}\r\n").as_bytes());
    }
    surface.inject_output_for_test(
        format!("\x1b_Gf=100,a=T,c=8,r=4;{PNG_64_RGB_BASE64}\x1b\\\r\nafter\r\n").as_bytes(),
    );
    let (_writer, outbound, client) = attach_images_viewer(&mux, &surface, true);
    let mut lines = Vec::new();
    let ready = next_event(&outbound, Duration::from_secs(10)).expect("ready");
    assert_eq!(ready["phase"], "ready", "{ready}");
    lines.push(fixture_line(&ready));
    loop {
        let event = next_event(&outbound, Duration::from_secs(10)).expect("history");
        if event["event"] != "snapshot" {
            continue;
        }
        assert_eq!(event["phase"], "history", "{event}");
        lines.push(fixture_line(&event));
        if event["done"] == true {
            break;
        }
    }
    surface.resize(60, 20).unwrap();
    let local = loop {
        let event = next_event(&outbound, Duration::from_secs(10)).expect("local ready");
        if event["event"] == "snapshot" {
            break event;
        }
    };
    assert_eq!(local["history"], "local", "{local}");
    lines.push(fixture_line(&local));
    disconnect_client(&mux, client, false);
    mux.shutdown();

    let actual = lines.join("\n") + "\n";
    let path =
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../..").join(DOGFOOD_PNG_FIXTURE);
    if std::env::var_os("CMUX_UPDATE_SNAPSHOT_FIXTURE").is_some() {
        std::fs::write(&path, &actual).expect("write the fixture");
        return;
    }
    let expected = std::fs::read_to_string(&path).unwrap_or_default();
    assert!(
        actual == expected,
        "{DOGFOOD_PNG_FIXTURE} differs from the host's events; rerun with \
         CMUX_UPDATE_SNAPSHOT_FIXTURE=1 and review the diff"
    );
}

/// SWITCH FRAMES SF-5 C (busy gate on a 2x display, 2026-11-02): with 8 warm hidden terminals printing 20 lines/s,
/// the Mac app woke about 115 times a second, because each hidden terminal's attach stream sent every output frame
/// at once. A viewer that says it does not show its terminal (`set-attach-visibility`, `attach-visibility-v1`) gets
/// its output batched to once per wall-clock second, at once when it is shown again, and loses no byte. What the
/// person sees without the terminal (a title set by the program) still reaches the viewer within one batch window.
#[test]
fn a_hidden_snapshot_viewer_gets_output_once_a_second_and_at_once_when_shown() {
    let mux = Mux::new_for_test("snapshot-hidden-batch", SurfaceOptions::default());
    let surface = mux.new_workspace(None, None).unwrap();
    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let version = ghostty_vt::snapshot_version();
    handle_command(
        &mux,
        client,
        command(json!({
            "cmd": "attach-surface", "surface": surface.id,
            "snapshot": "ghostsnp", "snapshot_version": version,
        })),
        &writer,
    )
    .unwrap();
    let first = next_event(&outbound, Duration::from_secs(5)).expect("snapshot");
    assert_eq!(first["event"], "snapshot", "{first}");
    let mut offset = first["offset"].as_u64().unwrap();
    // The READY's history chunks and any first scroll or colors event.
    while let Some(event) = next_event(&outbound, Duration::from_millis(300)) {
        assert_ne!(event["event"], "output", "output before the test wrote any: {event}");
    }

    let reply = handle_command(
        &mux,
        client,
        command(json!({"cmd": "set-attach-visibility", "surface": surface.id, "visible": false})),
        &writer,
    )
    .unwrap();
    assert_eq!(reply["viewers"], 1, "{reply}");

    // A busy program while hidden: a title, then 20 lines 100 ms apart.
    let started = Instant::now();
    surface.inject_output_for_test(b"\x1b]0;hidden-title\x07");
    let mut output_events = 0;
    let mut title_on_attach_at = None;
    let mut collect = |outbound: &BoundedOutbound,
                       until: Instant,
                       output_events: &mut usize,
                       offset: &mut u64| {
        while Instant::now() < until {
            let Some(event) = next_event(outbound, Duration::from_millis(5)) else { continue };
            if event["event"] == "output" {
                *output_events += 1;
                *offset += decoded_len(&event);
                assert_eq!(
                    event["offset"].as_u64(),
                    Some(*offset),
                    "offsets are contiguous: {event}"
                );
                let data = base64::engine::general_purpose::STANDARD
                    .decode(event["data"].as_str().unwrap())
                    .unwrap();
                if title_on_attach_at.is_none()
                    && String::from_utf8_lossy(&data).contains("hidden-title")
                {
                    title_on_attach_at = Some(started.elapsed());
                }
            }
        }
    };
    for line in 0..20 {
        surface.inject_output_for_test(format!("hidden line {line}\r\n").as_bytes());
        collect(
            &outbound,
            Instant::now() + Duration::from_millis(100),
            &mut output_events,
            &mut offset,
        );
    }
    assert!(
        output_events <= 3,
        "{output_events} output events for 21 writes in 2 s to a hidden viewer: each wakes the app (want at most one per second)"
    );
    let title_at = title_on_attach_at.expect("the hidden viewer never got the title bytes");
    assert!(
        title_at <= Duration::from_millis(1_300),
        "the title reached the hidden viewer after {title_at:?}: more than one batch window"
    );

    // Shown again: what waits goes out at once, not at the next second.
    surface.inject_output_for_test(b"shown again\r\n");
    std::thread::sleep(Duration::from_millis(20));
    let shown_at = Instant::now();
    let reply = handle_command(
        &mux,
        client,
        command(json!({"cmd": "set-attach-visibility", "surface": surface.id, "visible": true})),
        &writer,
    )
    .unwrap();
    assert_eq!(reply["viewers"], 1, "{reply}");
    let mut flushed = false;
    while shown_at.elapsed() < Duration::from_millis(250) {
        if let Some(event) = next_event(&outbound, Duration::from_millis(5))
            && event["event"] == "output"
        {
            offset += decoded_len(&event);
            assert_eq!(event["offset"].as_u64(), Some(offset), "offsets are contiguous: {event}");
            flushed = true;
        }
    }
    assert!(flushed, "a shown viewer got its waiting output only at the next second");
    assert_eq!(offset, surface_offset(&mux, surface.id), "the viewer missed output bytes");

    disconnect_client(&mux, client, false);
    mux.shutdown();
}

/// The daemon's output offset of `surface` (its snapshot digest's position).
fn surface_offset(mux: &Mux, surface: crate::SurfaceId) -> u64 {
    mux.surface(surface).expect("surface").snapshot_digest().expect("digest").offset
}

/// Review of #32446: a hidden terminal's scroll position moves once per daemon frame while it prints, and each
/// `scroll-changed` on its attach stream woke the app's reader as an output frame did. A hidden snapshot viewer gets
/// none while hidden, and the newest one at once when it is shown again.
#[test]
fn a_hidden_snapshot_viewer_gets_no_scroll_changed_until_shown() {
    let mux = Mux::new_for_test("snapshot-hidden-scroll", SurfaceOptions::default());
    let surface = mux.new_workspace(None, None).unwrap();
    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let version = ghostty_vt::snapshot_version();
    handle_command(
        &mux,
        client,
        command(json!({
            "cmd": "attach-surface", "surface": surface.id,
            "snapshot": "ghostsnp", "snapshot_version": version,
        })),
        &writer,
    )
    .unwrap();
    while next_event(&outbound, Duration::from_millis(300)).is_some() {}
    handle_command(
        &mux,
        client,
        command(json!({"cmd": "set-attach-visibility", "surface": surface.id, "visible": false})),
        &writer,
    )
    .unwrap();

    for offset in 1..=20 {
        mux.emit_terminal_scroll(surface.id, offset, true);
        std::thread::sleep(Duration::from_millis(10));
    }
    let mut scrolls = 0;
    while let Some(event) = next_event(&outbound, Duration::from_millis(300)) {
        if event["event"] == "scroll-changed" {
            scrolls += 1;
        }
    }
    assert_eq!(
        scrolls, 0,
        "{scrolls} scroll-changed events reached a hidden viewer: each wakes the app"
    );

    handle_command(
        &mux,
        client,
        command(json!({"cmd": "set-attach-visibility", "surface": surface.id, "visible": true})),
        &writer,
    )
    .unwrap();
    let mut last = None;
    while let Some(event) = next_event(&outbound, Duration::from_millis(300)) {
        if event["event"] == "scroll-changed" {
            last = Some(event);
        }
    }
    let last = last.expect("a shown viewer got no scroll position");
    assert_eq!(
        last["offset"].as_u64(),
        Some(20),
        "the shown viewer's scroll position is not the newest: {last}"
    );

    disconnect_client(&mux, client, false);
    mux.shutdown();
}

/// Lead 17:4xZ (SF-5 C): the host bench was too noisy to show that batching engages, so this counts it. A busy
/// program's 60 lines over 3 s (20 lines/s, as the busy gate) reach a terminal whose snapshot viewer is hidden; each
/// write comes with the scroll move the frame producer publishes. Every message on the viewer's stream is one wake of
/// the app's attach reader (output, scroll-changed, digest, ...). Shown, that is two per line (about 120); hidden, at
/// most one per batch window (one per aligned second, plus the window the writes start in).
#[test]
fn a_hidden_viewer_of_a_busy_program_wakes_its_reader_at_most_once_per_second() {
    let mux = Mux::new_for_test("snapshot-hidden-busy-program", SurfaceOptions::default());
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let version = ghostty_vt::snapshot_version();
    handle_command(
        &mux,
        client,
        command(json!({
            "cmd": "attach-surface", "surface": surface.id,
            "snapshot": "ghostsnp", "snapshot_version": version,
        })),
        &writer,
    )
    .unwrap();
    while next_event(&outbound, Duration::from_millis(500)).is_some() {}
    handle_command(
        &mux,
        client,
        command(json!({"cmd": "set-attach-visibility", "surface": surface.id, "visible": false})),
        &writer,
    )
    .unwrap();

    let started = Instant::now();
    let mut messages = Vec::new();
    for line in 0..60u64 {
        surface.inject_output_for_test(format!("busy line {line}\r\n").as_bytes());
        mux.emit_terminal_scroll(surface.id, line + 1, true);
        let until = Instant::now() + Duration::from_millis(50);
        while Instant::now() < until {
            if let Some(event) = next_event(&outbound, Duration::from_millis(5)) {
                messages.push(event["event"].as_str().unwrap_or("?").to_string());
            }
        }
    }
    while started.elapsed() < Duration::from_millis(4_200) {
        if let Some(event) = next_event(&outbound, Duration::from_millis(20)) {
            messages.push(event["event"].as_str().unwrap_or("?").to_string());
        }
    }
    let outputs = messages.iter().filter(|event| *event == "output").count();
    assert!(outputs >= 1, "the hidden viewer got none of the program's output: {messages:?}");
    assert!(
        messages.len() <= 6,
        "{} stream messages in 4.2 s for 60 hidden lines (each wakes the app's attach reader; want at most one per second): {messages:?}",
        messages.len()
    );

    disconnect_client(&mux, client, false);
    mux.shutdown();
}

// ---- attach-replay-history-rows-v1 ------------------------------------

/// The first `vt-state` of a bytes attach with these extra fields.
fn byte_attach_vt_state(
    mux: &std::sync::Arc<Mux>,
    surface: &crate::Surface,
    extra: Value,
) -> Value {
    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let mut request = json!({"cmd": "attach-surface", "surface": surface.id});
    for (key, value) in extra.as_object().expect("fields") {
        request[key] = value.clone();
    }
    handle_command(mux, client, command(request), &writer).unwrap();
    let first = next_event(&outbound, Duration::from_secs(5)).expect("vt-state");
    assert_eq!(first["event"], "vt-state", "{first}");
    disconnect_client(mux, client, false);
    first
}

#[test]
fn replay_history_rows_capability_is_advertised() {
    let mux = Mux::new_for_test("replay-history-rows-identify", SurfaceOptions::default());
    let (writer, _outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let identity =
        handle_command(&mux, client, command(json!({"cmd": "identify"})), &writer).unwrap();
    let capabilities = identity["capabilities"].as_array().expect("capabilities");
    assert!(
        capabilities.iter().any(|value| value == "attach-replay-history-rows-v1"),
        "{identity}"
    );
    disconnect_client(&mux, client, false);
    mux.shutdown();
}

/// Latest screen first (cmuxterm-hq#7231): a bytes attach with
/// `replay_history_rows` gets a `vt-state` that rebuilds the screen and only
/// that many of the newest history rows, and names how many older rows it
/// left out; the same terminal attached without the field still gets its
/// whole history and no new field.
#[test]
fn a_byte_attach_with_a_history_allowance_gets_the_latest_screen_first() {
    let (mux, surface) = quiet_surface_with_scrollback("replay-history-rows", 5_000);
    let full = byte_attach_vt_state(&mux, &surface, json!({}));
    assert!(full.get("history_rows_omitted").is_none(), "{}", full["history_rows_omitted"]);
    let screen = byte_attach_vt_state(&mux, &surface, json!({"replay_history_rows": 0}));
    let tail = byte_attach_vt_state(&mux, &surface, json!({"replay_history_rows": 100}));

    let screen_omitted = screen["history_rows_omitted"].as_u64().expect("omitted rows");
    let tail_omitted = tail["history_rows_omitted"].as_u64().expect("omitted rows");
    assert!(screen_omitted >= 4_900, "only {screen_omitted} rows were left out of 5,000");
    assert_eq!(screen_omitted - tail_omitted, 100, "the allowance keeps 100 more rows");

    let (full_bytes, screen_bytes, tail_bytes) = (data(&full), data(&screen), data(&tail));
    assert!(
        screen_bytes.len() * 50 < full_bytes.len(),
        "a screen-only replay of {} bytes against the whole history's {}",
        screen_bytes.len(),
        full_bytes.len()
    );
    assert!(screen_bytes.len() < tail_bytes.len() && tail_bytes.len() < full_bytes.len());

    // Each rebuilds the same screen.
    let screen_text = |bytes: &[u8]| {
        let mut term =
            ghostty_vt::Terminal::new(80, 24, 10_000_000, ghostty_vt::Callbacks::default())
                .unwrap();
        term.vt_write(bytes);
        term.viewport_text().unwrap()
    };
    let expected = screen_text(&full_bytes);
    assert!(expected.contains("004999"), "{expected}");
    assert_eq!(screen_text(&screen_bytes), expected);
    assert_eq!(screen_text(&tail_bytes), expected);
    mux.shutdown();
}

/// Bench (off unless CMUX_LATEST_SCREEN_BENCH=<attaches per arm>): a bytes
/// attach of an 80x24 terminal with 10,000 and 50,000 lines of history, the
/// whole replay (today) against the latest screen first
/// (`replay_history_rows: 0`), interleaved. Per arm: the first `vt-state`
/// line's wire bytes and the time from the request to that line on the
/// connection's queue (p50/p95). Prints LATEST-SCREEN-BENCH lines and writes
/// them to $FAST_CHECKS_OUT/latest-screen-bench.txt when that is set.
#[test]
fn latest_screen_first_bench() {
    let Some(runs) = std::env::var("CMUX_LATEST_SCREEN_BENCH")
        .ok()
        .and_then(|runs| runs.parse::<usize>().ok())
        .filter(|runs| *runs > 0)
    else {
        return;
    };
    let mut lines_out = Vec::new();
    for history in [10_000, 50_000] {
        let (mux, surface) =
            quiet_surface_with_scrollback_limit("latest-screen-bench", history, 50_000_000);
        let attach = |extra: Value| {
            let (writer, outbound) = captured_writer();
            let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
            let mut request = json!({"cmd": "attach-surface", "surface": surface.id});
            for (key, value) in extra.as_object().expect("fields") {
                request[key] = value.clone();
            }
            let started = Instant::now();
            handle_command(&mux, client, command(request), &writer).unwrap();
            let line = loop {
                if let Some(message) = outbound.try_pop() {
                    if message.contains("\"event\":\"vt-state\"") {
                        break message;
                    }
                    continue;
                }
                assert!(started.elapsed() < Duration::from_secs(30), "no vt-state");
                std::thread::yield_now();
            };
            let elapsed = started.elapsed().as_secs_f64() * 1000.0;
            disconnect_client(&mux, client, false);
            (line.len(), elapsed)
        };
        let (mut whole, mut screen) = (Vec::new(), Vec::new());
        let (mut whole_bytes, mut screen_bytes) = (0, 0);
        for round in 0..runs {
            let arms: [bool; 2] = if round % 2 == 0 { [false, true] } else { [true, false] };
            for tail in arms {
                if tail {
                    let (bytes, ms) = attach(json!({"replay_history_rows": 0}));
                    screen_bytes = bytes;
                    screen.push(ms);
                } else {
                    let (bytes, ms) = attach(json!({}));
                    whole_bytes = bytes;
                    whole.push(ms);
                }
            }
        }
        let percentiles = |times: &mut Vec<f64>| {
            times.sort_by(f64::total_cmp);
            let at = |p: f64| times[((times.len() - 1) as f64 * p).round() as usize];
            format!("p50 {:.2} ms p95 {:.2} ms", at(0.5), at(0.95))
        };
        let profile = if cfg!(debug_assertions) { "dev-profile" } else { "release" };
        lines_out.push(format!(
            "LATEST-SCREEN-BENCH {profile} 80x24 {history} lines, {runs} attaches per arm: \
             whole replay {whole_bytes} wire bytes, {}; latest screen first {screen_bytes} \
             wire bytes, {}",
            percentiles(&mut whole),
            percentiles(&mut screen)
        ));
        mux.shutdown();
    }
    for line in &lines_out {
        eprintln!("{line}");
    }
    if let Ok(dir) = std::env::var("FAST_CHECKS_OUT") {
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            std::path::Path::new(&dir).join("latest-screen-bench.txt"),
            lines_out.join("\n") + "\n",
        )
        .unwrap();
    }
}
