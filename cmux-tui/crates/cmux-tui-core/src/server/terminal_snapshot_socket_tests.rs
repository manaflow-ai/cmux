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
    handle_command(&mux, client, command(json!({"cmd": "attach-surface", "surface": surface.id})), &writer)
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
