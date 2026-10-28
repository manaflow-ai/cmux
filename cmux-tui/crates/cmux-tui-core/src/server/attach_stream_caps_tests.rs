//! Stream caps: past the connection's or the daemon's cap on
//! open client-minted streams, only the open fails; the connection, its open
//! streams and the other connections are unchanged.

use std::sync::Arc;
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::super::tests::captured_writer;
use super::super::{
    ATTACH_STREAMS_PER_CLIENT_CAPACITY, ATTACH_STREAMS_SERVER_CAPACITY, BoundedOutbound,
    ClientTransport, Command, MessageWriter, disconnect_client, handle_command,
};
use super::{ATTACH_STREAMS_CAPABILITY, ClientStreamId};
use crate::{Mux, Surface, SurfaceOptions};

fn request(mux: &Arc<Mux>, client: u64, writer: &MessageWriter, value: Value) -> Value {
    let command: Command = serde_json::from_value(value).expect("raw command");
    handle_command(mux, client, command, writer).expect("request succeeds")
}

fn refusal(mux: &Arc<Mux>, client: u64, writer: &MessageWriter, value: Value) -> String {
    let command: Command = serde_json::from_value(value).expect("raw command");
    handle_command(mux, client, command, writer).expect_err("request is refused").to_string()
}

fn quiet_mux(session: &str) -> Arc<Mux> {
    Mux::new_for_test(
        session,
        SurfaceOptions { command: Some(vec!["cat".to_string()]), ..SurfaceOptions::default() },
    )
}

/// A Unix connection holding the stream grant.
fn connect(mux: &Arc<Mux>) -> (MessageWriter, Arc<BoundedOutbound>, u64) {
    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    request(
        mux,
        client,
        &writer,
        json!({"cmd": "set-client-info", "capabilities": [ATTACH_STREAMS_CAPABILITY]}),
    );
    (writer, outbound, client)
}

fn attach_line(surface: &Surface, stream: usize) -> Value {
    json!({"cmd": "attach-surface", "surface": surface.id, "stream": stream})
}

/// Items written so far, until `done` matches one or `timeout` passes.
fn read_until(
    outbound: &BoundedOutbound,
    timeout: Duration,
    mut done: impl FnMut(&Value) -> bool,
) -> Vec<Value> {
    let deadline = Instant::now() + timeout;
    let mut items = Vec::new();
    while Instant::now() < deadline {
        let Some(message) = outbound.try_pop() else {
            std::thread::sleep(Duration::from_millis(2));
            continue;
        };
        let value: Value = serde_json::from_str(&message).expect("outbound JSON");
        let finished = done(&value);
        items.push(value);
        if finished {
            break;
        }
    }
    items
}

fn is_output_of(item: &Value, stream: usize) -> bool {
    item["event"] == "output" && item["stream"] == stream
}

/// The connection's open stream still delivers: `surface`'s output reaches
/// `stream`.
fn assert_stream_flows(outbound: &BoundedOutbound, surface: &Surface, stream: usize) {
    surface.inject_output_for_test(b"still flowing\r\n");
    let items = read_until(outbound, Duration::from_secs(5), |item| is_output_of(item, stream));
    assert!(items.iter().any(|item| is_output_of(item, stream)), "{items:?}");
}

#[test]
fn stream_caps_the_4097th_open_on_a_connection_fails_alone() {
    let mux = quiet_mux("stream-caps-connection");
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    let admission = mux.control_clients.attach_stream_admission.clone();
    let (writer, outbound, client) = connect(&mux);
    // Streams 0..4095 hold ids: one real view, the rest opened and idle.
    let viewed = ATTACH_STREAMS_PER_CLIENT_CAPACITY - 1;
    for id in 0..viewed {
        let id = u16::try_from(id).unwrap();
        writer.start_client_stream(ClientStreamId(id), &admission).expect("under the cap");
    }
    request(&mux, client, &writer, attach_line(&surface, viewed));
    read_until(&outbound, Duration::from_secs(5), |item| item["event"] == "vt-state");
    assert_eq!(admission.open(), ATTACH_STREAMS_PER_CLIENT_CAPACITY);

    let extra = ATTACH_STREAMS_PER_CLIENT_CAPACITY;
    let error = refusal(&mux, client, &writer, attach_line(&surface, extra));
    assert!(error.starts_with("stream_capacity"), "{error}");
    // Only the open failed: no stream-end for the refused id, the count and
    // the views are as they were, and the connection answers and delivers.
    let extra_id = ClientStreamId(u16::try_from(extra).unwrap());
    assert!(writer.client_stream(extra_id).is_none());
    assert_eq!(admission.open(), ATTACH_STREAMS_PER_CLIENT_CAPACITY);
    assert_eq!(mux.control_clients.attached_client_ids_for_surface(surface.id).len(), 1);
    request(&mux, client, &writer, json!({"cmd": "ping"}));
    assert_stream_flows(&outbound, &surface, viewed);
    let written = read_until(&outbound, Duration::from_millis(100), |_| false);
    assert!(written.iter().all(|item| item["stream"] != extra), "{written:?}");

    // A freed id makes room for the open that failed.
    request(&mux, client, &writer, json!({"cmd": "cancel-stream", "stream": 0}));
    request(&mux, client, &writer, attach_line(&surface, extra));
    let ready = read_until(&outbound, Duration::from_secs(5), |item| {
        item["event"] == "vt-state" && item["stream"] == extra
    });
    assert!(ready.last().is_some_and(|item| item["stream"] == extra), "{ready:?}");
    disconnect_client(&mux, client, false);
    assert_eq!(admission.open(), 0, "a closed connection frees its share of the daemon cap");
    mux.shutdown();
}

#[test]
fn stream_caps_a_full_daemon_fails_only_the_open() {
    let mux = quiet_mux("stream-caps-server");
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    let admission = mux.control_clients.attach_stream_admission.clone();
    // Other connections' streams hold all but one place under the daemon cap.
    let held: Vec<_> = (1..ATTACH_STREAMS_SERVER_CAPACITY)
        .map(|_| admission.try_reserve().expect("under the daemon cap"))
        .collect();
    let (first_writer, first_outbound, first) = connect(&mux);
    let (second_writer, _second_outbound, second) = connect(&mux);
    request(&mux, first, &first_writer, attach_line(&surface, 1));
    read_until(&first_outbound, Duration::from_secs(5), |item| item["event"] == "vt-state");

    let error = refusal(&mux, second, &second_writer, attach_line(&surface, 1));
    assert!(error.starts_with("server_stream_capacity"), "{error}");
    assert!(second_writer.client_stream(ClientStreamId(1)).is_none());
    assert_eq!(admission.open(), ATTACH_STREAMS_SERVER_CAPACITY);
    request(&mux, second, &second_writer, json!({"cmd": "ping"}));
    assert_stream_flows(&first_outbound, &surface, 1);

    // The first connection's stream ends: the second one's open fits.
    request(&mux, first, &first_writer, json!({"cmd": "cancel-stream", "stream": 1}));
    request(&mux, second, &second_writer, attach_line(&surface, 1));
    assert!(second_writer.client_stream(ClientStreamId(1)).is_some());
    disconnect_client(&mux, first, false);
    disconnect_client(&mux, second, false);
    drop(held);
    assert_eq!(admission.open(), 0);
    mux.shutdown();
}

#[test]
fn stream_caps_an_open_id_is_in_use_before_any_cap() {
    let mux = quiet_mux("stream-caps-order");
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    let admission = mux.control_clients.attach_stream_admission.clone();
    let (writer, _outbound, client) = connect(&mux);
    request(&mux, client, &writer, attach_line(&surface, 3));
    let held: Vec<_> = std::iter::from_fn(|| admission.try_reserve().ok()).collect();
    assert_eq!(held.len(), ATTACH_STREAMS_SERVER_CAPACITY - 1);
    let in_use = refusal(&mux, client, &writer, attach_line(&surface, 3));
    assert!(in_use.starts_with("stream_in_use"), "{in_use}");
    let full = refusal(&mux, client, &writer, attach_line(&surface, 4));
    assert!(full.starts_with("server_stream_capacity"), "{full}");
    drop(held);
    assert_eq!(admission.open(), 1, "refused opens hold no place");
    disconnect_client(&mux, client, false);
    mux.shutdown();
}
