//! Stream visibility priority: a hidden snapshot viewer gets
//! nothing while its terminal prints and one READY at the right offset when
//! it shows; a quiet hidden one shows with no READY; a focused stream's
//! queued items move ahead of a visible one's; and the command answers like
//! `cancel-stream`.

use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::super::attach_lifecycle::attach_pump::tests::{
    connect, decoded, next_any, next_item, request,
};
use super::super::tests::captured_writer;
use super::super::{
    BoundedOutbound, ClientTransport, MessageWriter, OutboundStream, RenderService,
    disconnect_client, handle_command,
};
use super::StreamPriority;
use crate::{Mux, Surface, SurfaceOptions};
use cmux_ipc::StreamLane;

const WAIT: Duration = Duration::from_secs(10);
/// How long a hidden viewer is watched for items it must not get.
const QUIET: Duration = Duration::from_millis(200);

fn quiet_mux(session: &str) -> std::sync::Arc<Mux> {
    Mux::new_for_test(
        session,
        SurfaceOptions { command: Some(vec!["cat".to_string()]), ..SurfaceOptions::default() },
    )
}

fn priority(
    mux: &std::sync::Arc<Mux>,
    client: u64,
    writer: &MessageWriter,
    stream: u16,
    value: &str,
) -> Value {
    request(
        mux,
        client,
        writer,
        json!({"cmd": "set-stream-priority", "stream": stream, "priority": value}),
    )
}

/// A snapshot view of `surface` on `stream`; returns the offset of its READY.
fn attach_snapshot(
    mux: &std::sync::Arc<Mux>,
    client: u64,
    writer: &MessageWriter,
    outbound: &BoundedOutbound,
    surface: &Surface,
    stream: u16,
) -> u64 {
    request(
        mux,
        client,
        writer,
        json!({
            "cmd": "attach-surface", "surface": surface.id, "stream": stream,
            "snapshot": "ghostsnp", "snapshot_version": ghostty_vt::snapshot_version(),
        }),
    );
    let ready = next_item(outbound, WAIT).expect("READY");
    assert_eq!(
        (ready["event"].as_str(), ready["phase"].as_str()),
        (Some("snapshot"), Some("ready"))
    );
    drain_tail(outbound);
    ready["offset"].as_u64().expect("offset")
}

/// Takes the READY's history and images chunks (and anything else queued now).
fn drain_tail(outbound: &BoundedOutbound) -> Vec<Value> {
    let mut items = Vec::new();
    while let Some(item) = next_any(outbound, Duration::from_millis(50)) {
        items.push(item);
    }
    items
}

/// Items of `stream` written within `window`.
fn items_within(outbound: &BoundedOutbound, window: Duration) -> Vec<Value> {
    let deadline = Instant::now() + window;
    let mut items = Vec::new();
    while let Some(item) = next_any(outbound, deadline.saturating_duration_since(Instant::now())) {
        if !matches!(item["event"].as_str(), Some("notification" | "scroll-changed")) {
            items.push(item);
        }
    }
    items
}

#[test]
fn a_hidden_snapshot_viewer_gets_nothing_then_one_ready_at_the_right_offset() {
    let mux = quiet_mux("stream-priority-hidden");
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    let (writer, outbound, client) = connect(&mux);
    let offset = attach_snapshot(&mux, client, &writer, &outbound, &surface, 3);
    assert_eq!(
        priority(&mux, client, &writer, 3, "hidden"),
        json!({"stream": 3, "outcome": "applied"})
    );
    let mut printed = 0u64;
    for line in 0..200 {
        let bytes = format!("hidden line {line}\r\n");
        surface.inject_output_for_test(bytes.as_bytes());
        printed += bytes.len() as u64;
    }
    let while_hidden = items_within(&outbound, QUIET);
    assert!(while_hidden.is_empty(), "a hidden viewer got {while_hidden:?}");

    priority(&mux, client, &writer, 3, "visible");
    let ready = next_item(&outbound, WAIT).expect("the READY of the shown viewer");
    assert_eq!(ready["event"], "snapshot", "{ready}");
    assert_eq!(ready["phase"], "ready", "{ready}");
    assert_eq!(ready["stream"], 3);
    assert_eq!(ready["offset"].as_u64(), Some(offset + printed), "{ready}");
    drain_tail(&outbound);

    // Live output goes on from the READY's offset.
    surface.inject_output_for_test(b"shown\r\n");
    let output = loop {
        let item = next_item(&outbound, WAIT).expect("live output");
        if item["event"] == "output" {
            break item;
        }
    };
    assert_eq!(decoded(&output), b"shown\r\n");
    assert_eq!(output["offset"].as_u64(), Some(offset + printed + 7), "{output}");
    disconnect_client(&mux, client, false);
    mux.shutdown();
}

#[test]
fn a_quiet_hidden_viewer_shows_with_no_ready_and_goes_on_at_its_offset() {
    let mux = quiet_mux("stream-priority-quiet");
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    let (writer, outbound, client) = connect(&mux);
    let offset = attach_snapshot(&mux, client, &writer, &outbound, &surface, 4);
    priority(&mux, client, &writer, 4, "hidden");
    priority(&mux, client, &writer, 4, "focused");
    let shown = items_within(&outbound, QUIET);
    assert!(shown.is_empty(), "showing an unchanged viewer sent {shown:?}");
    surface.inject_output_for_test(b"after\r\n");
    let output = loop {
        let item = next_item(&outbound, WAIT).expect("live output");
        assert_ne!(item["event"], "snapshot", "{item}");
        if item["event"] == "output" {
            break item;
        }
    };
    assert_eq!(output["offset"].as_u64(), Some(offset + 7), "{output}");
    disconnect_client(&mux, client, false);
    mux.shutdown();
}

/// Red before the fix: a hidden view never polled its viewer queue, so its
/// surface closing sent nothing until the stream showed again.
#[test]
fn a_hidden_viewer_whose_surface_closes_ends_detached() {
    let mux = quiet_mux("stream-priority-hidden-close");
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    let (writer, outbound, client) = connect(&mux);
    attach_snapshot(&mux, client, &writer, &outbound, &surface, 5);
    priority(&mux, client, &writer, 5, "hidden");
    surface.inject_output_for_test(b"printed while hidden\r\n");
    // The terminal ends: its attach taps go, as at its exit.
    surface.end_attachments_for_test();
    let deadline = Instant::now() + WAIT;
    let mut events = Vec::new();
    while let Some(item) = next_any(&outbound, deadline.saturating_duration_since(Instant::now())) {
        if item["stream"] != 5 {
            continue;
        }
        let event = item["event"].as_str().unwrap_or_default().to_string();
        let end = event == "stream-end";
        if end {
            assert_eq!(item["reason"], "detached", "{item}");
        }
        events.push(event);
        if end {
            break;
        }
    }
    assert_eq!(events, ["detached", "stream-end"]);
    disconnect_client(&mux, client, false);
    mux.shutdown();
}

#[test]
fn a_focused_streams_queued_items_go_before_a_visible_ones() {
    let service = RenderService::new();
    let outbound = BoundedOutbound::default();
    let overflow =
        |id: u64| service.serialize_control(&json!({"event": "overflow", "id": id})).unwrap();
    let visible = OutboundStream::with_sequence(1, overflow(1), false, StreamLane::Bulk);
    let focused = OutboundStream::with_sequence(2, overflow(2), false, StreamLane::Bulk);
    for index in 0..3 {
        outbound.push_regular(service.serialize(&json!({"v": index})).unwrap(), &visible).unwrap();
    }
    outbound.push_regular(service.serialize(&json!({"f": 0})).unwrap(), &focused).unwrap();
    outbound.set_stream_lane(&focused, StreamPriority::Focused.lane());
    assert_eq!(focused.lane(), StreamLane::Input);
    outbound.push_regular(service.serialize(&json!({"f": 1})).unwrap(), &focused).unwrap();
    let order: Vec<Value> = std::iter::from_fn(|| outbound.try_pop())
        .map(|text| serde_json::from_str(&text).unwrap())
        .collect();
    assert_eq!(
        order,
        vec![json!({"f": 0}), json!({"f": 1}), json!({"v": 0}), json!({"v": 1}), json!({"v": 2})]
    );
}

#[test]
fn the_command_answers_like_cancel_stream() {
    let mux = quiet_mux("stream-priority-answers");
    let (writer, _outbound, client) = connect(&mux);
    assert_eq!(
        priority(&mux, client, &writer, 9, "hidden"),
        json!({"stream": 9, "outcome": "ended"})
    );
    let bad = handle_command(
        &mux,
        client,
        serde_json::from_value(
            json!({"cmd": "set-stream-priority", "stream": 9, "priority": "loud"}),
        )
        .unwrap(),
        &writer,
    )
    .expect_err("an unknown priority is refused")
    .to_string();
    assert!(bad.starts_with("bad request"), "{bad}");
    let (plain, _plain_outbound) = captured_writer();
    let other = mux.control_clients.register(ClientTransport::Unix, plain.clone());
    let refused = handle_command(
        &mux,
        other,
        serde_json::from_value(
            json!({"cmd": "set-stream-priority", "stream": 1, "priority": "focused"}),
        )
        .unwrap(),
        &plain,
    )
    .expect_err("needs the grant")
    .to_string();
    assert!(refused.starts_with("streams_not_granted"), "{refused}");
    disconnect_client(&mux, client, false);
    disconnect_client(&mux, other, false);
    mux.shutdown();
}
