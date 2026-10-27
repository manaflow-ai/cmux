//! attach-streams-v1 through the raw v12 command path, with a captured
//! connection writer: the items a client reads, in write order.

use std::sync::Arc;
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::super::tests::captured_writer;
use super::super::{
    BoundedOutbound, ClientTransport, Command, MessageWriter, VIEW_ATTACHMENT_LEASE_CAPABILITY,
    disconnect_client, handle_command,
};
use super::{ATTACH_STREAMS_CAPABILITY, StreamEndReason, stream_end_json};
use crate::{Mux, Surface, SurfaceOptions};

fn command(value: Value) -> Command {
    serde_json::from_value(value).expect("raw command")
}

fn request(mux: &Arc<Mux>, client: u64, writer: &MessageWriter, value: Value) -> Value {
    handle_command(mux, client, command(value), writer).expect("request succeeds")
}

fn refusal(mux: &Arc<Mux>, client: u64, writer: &MessageWriter, value: Value) -> String {
    handle_command(mux, client, command(value), writer).expect_err("request is refused").to_string()
}

/// A mux whose terminals run `cat`, which prints nothing on its own.
fn quiet_mux(session: &str) -> Arc<Mux> {
    Mux::new_for_test(
        session,
        SurfaceOptions { command: Some(vec!["cat".to_string()]), ..SurfaceOptions::default() },
    )
}

/// A Unix connection that echoed the stream grant `identify` offered.
fn connect(mux: &Arc<Mux>) -> (MessageWriter, Arc<BoundedOutbound>, u64) {
    let (writer, outbound, client) = connect_without_grant(mux);
    request(
        mux,
        client,
        &writer,
        json!({"cmd": "set-client-info", "capabilities": [ATTACH_STREAMS_CAPABILITY]}),
    );
    (writer, outbound, client)
}

fn connect_without_grant(mux: &Arc<Mux>) -> (MessageWriter, Arc<BoundedOutbound>, u64) {
    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    (writer, outbound, client)
}

fn attach(mux: &Arc<Mux>, client: u64, writer: &MessageWriter, surface: &Surface, stream: u16) {
    request(
        mux,
        client,
        writer,
        json!({"cmd": "attach-surface", "surface": surface.id, "stream": stream}),
    );
}

/// Items written so far, until `done` matches one or `timeout` passes;
/// notifications and scroll changes are dropped.
fn read_until(
    outbound: &BoundedOutbound,
    timeout: Duration,
    mut done: impl FnMut(&Value) -> bool,
) -> Vec<Value> {
    let deadline = Instant::now() + timeout;
    let mut items = Vec::new();
    loop {
        if let Some(message) = outbound.try_pop() {
            let value: Value = serde_json::from_str(&message).expect("outbound JSON");
            if matches!(value["event"].as_str(), Some("notification" | "scroll-changed")) {
                continue;
            }
            let finished = done(&value);
            items.push(value);
            if finished {
                return items;
            }
            continue;
        }
        if Instant::now() >= deadline {
            return items;
        }
        std::thread::sleep(Duration::from_millis(2));
    }
}

fn is_end_of(item: &Value, stream: u16) -> bool {
    item["event"] == "stream-end" && item["stream"] == stream
}

fn is_output_of(item: &Value, stream: u16) -> bool {
    item["event"] == "output" && item["stream"] == stream
}

#[test]
fn stream_end_names_its_stream_and_reason() {
    let end = stream_end_json(super::ClientStreamId(7), StreamEndReason::Canceled);
    assert_eq!(end, json!({"event": "stream-end", "stream": 7, "reason": "canceled"}));
}

#[test]
fn the_grant_is_offered_and_a_stream_without_it_is_refused() {
    let mux = quiet_mux("attach-streams-identify");
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    let (writer, _outbound, client) = connect_without_grant(&mux);
    let identity = request(&mux, client, &writer, json!({"cmd": "identify"}));
    let capabilities = identity["capabilities"].as_array().expect("capabilities");
    assert!(capabilities.iter().any(|value| value == ATTACH_STREAMS_CAPABILITY), "{identity}");
    for line in [
        json!({"cmd": "attach-surface", "surface": surface.id, "stream": 1}),
        json!({"cmd": "cancel-stream", "stream": 1}),
        json!({"cmd": "release-attached-view-size", "surface": surface.id, "stream": 1}),
    ] {
        let error = refusal(&mux, client, &writer, line.clone());
        assert!(error.starts_with("streams_not_granted"), "{line}: {error}");
    }
    assert!(mux.control_clients.attached_client_ids_for_surface(surface.id).is_empty());
    // Without `stream`, attach-surface is as before.
    request(&mux, client, &writer, json!({"cmd": "attach-surface", "surface": surface.id}));
    disconnect_client(&mux, client, false);
    mux.shutdown();
}

#[test]
fn every_item_of_a_view_carries_its_stream_and_the_ready_goes_first() {
    let mux = quiet_mux("attach-streams-tags");
    let first = mux.new_workspace(None, Some((80, 24))).unwrap();
    let second = mux.new_workspace(None, Some((80, 24))).unwrap();
    let (writer, outbound, client) = connect(&mux);
    attach(&mux, client, &writer, &first, 1);
    attach(&mux, client, &writer, &second, 2);
    let ready = read_until(&outbound, Duration::from_secs(5), |item| item["event"] == "vt-state");
    assert_eq!(ready.last().map(|item| item["stream"].clone()), Some(json!(1)), "{ready:?}");
    let ready = read_until(&outbound, Duration::from_secs(5), |item| item["event"] == "vt-state");
    assert_eq!(ready.last().map(|item| item["stream"].clone()), Some(json!(2)), "{ready:?}");

    first.inject_output_for_test(b"one\r\n");
    second.inject_output_for_test(b"two\r\n");
    let mut seen = Vec::new();
    let items = read_until(&outbound, Duration::from_secs(5), |item| {
        if item["event"] == "output" {
            seen.push(item["stream"].as_u64());
        }
        seen.len() == 2
    });
    for item in &items {
        let stream = item["stream"].as_u64().expect("every item is tagged");
        let surface = if stream == 1 { first.id } else { second.id };
        assert_eq!(item["surface"], surface, "{item}");
    }
    seen.sort_unstable();
    assert_eq!(seen, vec![Some(1), Some(2)]);
    disconnect_client(&mux, client, false);
    mux.shutdown();
}

#[test]
fn an_open_id_is_in_use_and_the_connection_stays_usable() {
    let mux = quiet_mux("attach-streams-in-use");
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    let other = mux.new_workspace(None, Some((80, 24))).unwrap();
    let (writer, _outbound, client) = connect(&mux);
    attach(&mux, client, &writer, &surface, 3);
    let error = refusal(
        &mux,
        client,
        &writer,
        json!({"cmd": "attach-surface", "surface": other.id, "stream": 3}),
    );
    assert!(error.starts_with("stream_in_use"), "{error}");
    // A refused open leaves the open stream and the connection as they were.
    assert!(writer.client_stream(super::ClientStreamId(3)).is_some());
    request(&mux, client, &writer, json!({"cmd": "ping"}));
    attach(&mux, client, &writer, &other, 4);
    disconnect_client(&mux, client, false);
    mux.shutdown();
}

#[test]
fn cancel_stream_ends_last_is_idempotent_and_frees_the_id() {
    let mux = quiet_mux("attach-streams-cancel");
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    let (writer, outbound, client) = connect(&mux);
    attach(&mux, client, &writer, &surface, 5);
    read_until(&outbound, Duration::from_secs(5), |item| item["event"] == "vt-state");

    let reply = request(&mux, client, &writer, json!({"cmd": "cancel-stream", "stream": 5}));
    assert_eq!(reply, json!({"stream": 5, "outcome": "applied"}));
    // The reply is a cleanup fence: the view is gone, the id is free.
    assert!(mux.control_clients.attached_client_ids_for_surface(surface.id).is_empty());
    assert!(writer.client_stream(super::ClientStreamId(5)).is_none());
    let again = request(&mux, client, &writer, json!({"cmd": "cancel-stream", "stream": 5}));
    assert_eq!(again, json!({"stream": 5, "outcome": "ended"}));
    let never = request(&mux, client, &writer, json!({"cmd": "cancel-stream", "stream": 77}));
    assert_eq!(never, json!({"stream": 77, "outcome": "ended"}));

    surface.inject_output_for_test(b"after the end\r\n");
    let items = read_until(&outbound, Duration::from_millis(400), |_| false);
    let ends = items.iter().filter(|item| is_end_of(item, 5)).count();
    assert_eq!(ends, 1, "exactly one stream-end: {items:?}");
    let end = items.iter().position(|item| is_end_of(item, 5)).unwrap();
    assert_eq!(items[end]["reason"], "canceled");
    assert!(
        items[end + 1..].iter().all(|item| item["stream"] != 5),
        "nothing of stream 5 after its stream-end: {items:?}"
    );

    // The id opens a new view once its stream-end is queued.
    attach(&mux, client, &writer, &surface, 5);
    let ready = read_until(&outbound, Duration::from_secs(5), |item| item["event"] == "vt-state");
    assert_eq!(ready.last().map(|item| item["stream"].clone()), Some(json!(5)));
    disconnect_client(&mux, client, false);
    mux.shutdown();
}

#[test]
fn a_closed_surface_ends_its_stream_with_nothing_after_stream_end() {
    let mux = quiet_mux("attach-streams-closed");
    let closing = mux.new_workspace(None, Some((80, 24))).unwrap();
    let staying = mux.new_workspace(None, Some((80, 24))).unwrap();
    let (writer, outbound, client) = connect(&mux);
    attach(&mux, client, &writer, &closing, 1);
    attach(&mux, client, &writer, &staying, 2);
    read_until(&outbound, Duration::from_secs(5), |item| {
        item["event"] == "vt-state" && item["stream"] == 2
    });

    // Closing the terminal ends its output tap once its last reference goes.
    let identity = mux.resource_terminal_host_identity(&closing).expect("a hosted terminal");
    drop(closing);
    mux.close_terminal(&identity.terminal_id, &identity.incarnation).unwrap();
    let items = read_until(&outbound, Duration::from_secs(5), |item| is_end_of(item, 1));
    let end = items.last().expect("stream-end");
    assert!(is_end_of(end, 1), "{items:?}");
    assert_eq!(end["reason"], "detached");
    assert!(items.iter().any(|item| item["event"] == "detached" && item["stream"] == 1));

    staying.inject_output_for_test(b"still here\r\n");
    let later = read_until(&outbound, Duration::from_secs(5), |item| is_output_of(item, 2));
    assert!(later.iter().any(|item| is_output_of(item, 2)), "{later:?}");
    assert!(later.iter().all(|item| item["stream"] != 1), "{later:?}");
    attach(&mux, client, &writer, &staying, 1);
    disconnect_client(&mux, client, false);
    mux.shutdown();
}

#[test]
fn a_stalled_stream_does_not_hold_back_the_other_view_or_a_control_reply() {
    let mux = quiet_mux("attach-streams-stalled");
    let flooded = mux.new_workspace(None, Some((80, 24))).unwrap();
    let echoing = mux.new_workspace(None, Some((80, 24))).unwrap();
    let (writer, outbound, client) = connect(&mux);
    attach(&mux, client, &writer, &flooded, 1);
    attach(&mux, client, &writer, &echoing, 2);
    read_until(&outbound, Duration::from_secs(5), |item| {
        item["event"] == "vt-state" && item["stream"] == 2
    });

    // Stream 1's queue fills while nobody reads: its worker parks on its
    // own backpressure (2 queued items), with the rest of the flood in its tap.
    let chunk = vec![b'x'; 64 * 1024];
    for _ in 0..64 {
        flooded.inject_output_for_test(&chunk);
    }
    std::thread::sleep(Duration::from_millis(100));

    let started = Instant::now();
    echoing.inject_output_for_test(b"echo\r\n");
    writer.send_control(&json!({"id": 9, "ok": true, "data": {"pong": true}})).unwrap();
    // The reply leaves first; the echo leaves behind at most stream 1's
    // queued items.
    let first = read_until(&outbound, Duration::from_secs(2), |_| true);
    assert_eq!(first.first().map(|item| item["id"].clone()), Some(json!(9)), "{first:?}");
    let mut before_echo = 0;
    let items = read_until(&outbound, Duration::from_secs(2), |item| {
        let echo = is_output_of(item, 2);
        before_echo += usize::from(!echo);
        echo
    });
    let elapsed = started.elapsed();
    assert!(items.last().is_some_and(|item| is_output_of(item, 2)), "{} items", items.len());
    assert!(before_echo <= 8, "{before_echo} items of the stalled stream went first");
    assert!(elapsed < Duration::from_millis(500), "echo after {elapsed:?}");
    disconnect_client(&mux, client, false);
    mux.shutdown();
}

#[test]
fn view_requests_check_the_stream_they_name() {
    let mux = quiet_mux("attach-streams-checked");
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    let other = mux.new_workspace(None, Some((80, 24))).unwrap();
    let (writer, outbound, client) = connect(&mux);
    request(
        &mux,
        client,
        &writer,
        json!({"cmd": "set-client-info",
               "capabilities": [VIEW_ATTACHMENT_LEASE_CAPABILITY, ATTACH_STREAMS_CAPABILITY]}),
    );
    attach(&mux, client, &writer, &surface, 1);
    attach(&mux, client, &writer, &other, 2);

    let unknown = refusal(
        &mux,
        client,
        &writer,
        json!({"cmd": "release-attached-view-size", "surface": surface.id, "stream": 9}),
    );
    assert!(unknown.starts_with("unknown_stream"), "{unknown}");
    let mismatch = refusal(
        &mux,
        client,
        &writer,
        json!({"cmd": "detach-attached-view", "surface": surface.id, "stream": 2}),
    );
    assert!(mismatch.starts_with("stream_surface_mismatch"), "{mismatch}");
    let lease = refusal(
        &mux,
        client,
        &writer,
        json!({"cmd": "detach-attached-view", "surface": surface.id, "stream": 1, "lease": "nope"}),
    );
    assert!(lease.starts_with("stream_lease_mismatch"), "{lease}");
    let snapshot = refusal(
        &mux,
        client,
        &writer,
        json!({"cmd": "snapshot-request", "surface": other.id, "stream": 1}),
    );
    assert!(snapshot.starts_with("stream_surface_mismatch"), "{snapshot}");

    // The stream alone selects its view: detaching it ends only stream 1.
    let detached = request(
        &mux,
        client,
        &writer,
        json!({"cmd": "detach-attached-view", "surface": surface.id, "stream": 1}),
    );
    assert_eq!(detached["outcome"], "applied", "{detached}");
    let items = read_until(&outbound, Duration::from_secs(5), |item| is_end_of(item, 1));
    assert_eq!(items.last().map(|item| item["reason"].clone()), Some(json!("canceled")));
    assert!(writer.client_stream(super::ClientStreamId(2)).is_some());
    disconnect_client(&mux, client, false);
    mux.shutdown();
}
