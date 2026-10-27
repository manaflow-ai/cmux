//! `session.events {stream}` (p05-ipc-145): a v2 stream opened on a u16
//! client stream id the connection holds and ends as it holds and ends an
//! attach stream; with frames granted, its items are EVENT frames on that id.

use std::sync::Arc;
use std::time::{Duration, Instant};

use cmux_ipc::{Aux, FrameKind};
use serde_json::{Value, json};

use super::super::super::attach_streams::ATTACH_STREAMS_CAPABILITY;
use super::super::super::frame_dispatch::tests::{Client, Got};
use super::super::super::tests::captured_writer;
use super::super::super::{
    BoundedOutbound, ClientTransport, Command, ConnectionSurfaceScheduler, MessageWriter,
    disconnect_client, handle_command, handle_connection_message,
};
use crate::Mux;

const FIRST: &str = "stream_00000000000000000000000000000145";
const SECOND: &str = "stream_00000000000000000000000000000146";

fn v2_line(id: &str, operation: &str, params: Value) -> String {
    json!({
        "protocol":"cmux.protocol/2",
        "type":"request",
        "id":id,
        "operation":operation,
        "params":params,
    })
    .to_string()
}

fn open_line(id: &str, stream_id: &str, stream: u16) -> String {
    v2_line(
        id,
        "session.events",
        json!({"machine":"current","session":"current","stream_id":stream_id,"stream":stream}),
    )
}

fn command(mux: &Arc<Mux>, client: u64, writer: &MessageWriter, value: Value) -> Value {
    let command: Command = serde_json::from_value(value).expect("raw command");
    handle_command(mux, client, command, writer).expect("command succeeds")
}

fn pop(outbound: &BoundedOutbound) -> Value {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        if let Some(message) = outbound.try_pop() {
            return serde_json::from_str(&message).expect("outbound JSON");
        }
        assert!(Instant::now() < deadline, "nothing was written");
        std::thread::sleep(Duration::from_millis(2));
    }
}

fn reason(refused: &Value) -> &str {
    refused["error"]["details"]["reason"].as_str().unwrap_or_default()
}

/// One captured Unix connection, with or without the stream grant.
struct Connection {
    mux: Arc<Mux>,
    writer: MessageWriter,
    outbound: Arc<BoundedOutbound>,
    client: u64,
    scheduler: Arc<ConnectionSurfaceScheduler>,
}

impl Connection {
    fn new(label: &str, granted: bool) -> Connection {
        let mux = Mux::new_for_test(label, crate::SurfaceOptions::default());
        let (writer, outbound) = captured_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let scheduler =
            Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
        if granted {
            command(
                &mux,
                client,
                &writer,
                json!({"cmd":"set-client-info","capabilities":[ATTACH_STREAMS_CAPABILITY]}),
            );
        }
        Connection { mux, writer, outbound, client, scheduler }
    }

    /// Handles `line` and returns the first thing it wrote.
    fn line(&self, line: &str) -> Value {
        assert!(handle_connection_message(
            &self.mux,
            self.client,
            line,
            &self.writer,
            &self.scheduler
        ));
        pop(&self.outbound)
    }

    fn cancel_stream(&self, stream: u16) -> Value {
        command(
            &self.mux,
            self.client,
            &self.writer,
            json!({"cmd":"cancel-stream","stream":stream}),
        )
    }

    fn finish(self) {
        disconnect_client(&self.mux, self.client, false);
        self.mux.shutdown();
    }
}

#[test]
fn session_stream_items_and_end_carry_the_client_stream_and_cancel_stream_frees_it() {
    let connection = Connection::new("session-stream-tagged", true);
    let reply = connection.line(&open_line("open", FIRST, 5));
    assert_eq!((&reply["id"], &reply["ok"]), (&json!("open"), &json!(true)), "{reply}");
    assert_eq!(reply.get("stream"), None, "the open's reply is not an item of its stream");
    let snapshot = pop(&connection.outbound);
    assert_eq!(snapshot["type"], "stream_item", "{snapshot}");
    assert_eq!((&snapshot["stream_id"], &snapshot["stream"]), (&json!(FIRST), &json!(5)));

    // The id is the connection's while its stream is open.
    let refused = connection.line(&open_line("again", SECOND, 5));
    assert_eq!(refused["ok"], false, "{refused}");
    assert_eq!(refused["error"]["code"], "validation.invalid", "{refused}");
    assert!(reason(&refused).starts_with("stream_in_use"), "{refused}");

    // cancel-stream ends the v2 stream as stream.cancel does: its own
    // stream_end, tagged, before the reply.
    assert_eq!(connection.cancel_stream(5)["outcome"], "applied");
    let end = pop(&connection.outbound);
    assert_eq!(end["type"], "stream_end", "{end}");
    assert_eq!(
        (&end["stream_id"], &end["stream"], &end["reason"]),
        (&json!(FIRST), &json!(5), &json!("canceled"))
    );
    assert_eq!(connection.cancel_stream(5)["outcome"], "ended", "cancel-stream is idempotent");

    // The id is free once its stream_end is queued.
    let reopened = connection.line(&open_line("reopen", SECOND, 5));
    assert_eq!(reopened["ok"], true, "{reopened}");
    let snapshot = pop(&connection.outbound);
    assert_eq!((&snapshot["stream_id"], &snapshot["stream"]), (&json!(SECOND), &json!(5)));

    // stream.cancel ends it the same way and frees the id.
    let end = connection.line(&v2_line(
        "cancel",
        "stream.cancel",
        json!({"machine":"current","session":"current","stream":SECOND}),
    ));
    assert_eq!(end["type"], "stream_end", "{end}");
    assert_eq!((&end["stream"], &end["reason"]), (&json!(5), &json!("canceled")));
    let reply = pop(&connection.outbound);
    assert_eq!((&reply["id"], &reply["ok"]), (&json!("cancel"), &json!(true)), "{reply}");
    assert_eq!(connection.cancel_stream(5)["outcome"], "ended", "stream.cancel freed the id");
    assert!(connection.outbound.try_pop().is_none(), "an item followed stream_end");
    connection.finish();
}

#[test]
fn a_session_stream_id_needs_the_grant_and_a_nonzero_u16() {
    let connection = Connection::new("session-stream-grant", false);
    let refused = connection.line(&open_line("open", FIRST, 3));
    assert_eq!(refused["ok"], false, "{refused}");
    assert!(reason(&refused).starts_with("streams_not_granted"), "{refused}");
    assert!(connection.outbound.try_pop().is_none(), "a refused open queued an item");
    connection.finish();

    let connection = Connection::new("session-stream-range", true);
    for stream in [json!(0), json!(65_536), json!("5")] {
        let refused = connection.line(&v2_line(
            "open",
            "session.events",
            json!({"machine":"current","session":"current","stream_id":FIRST,"stream":stream}),
        ));
        assert_eq!(refused["ok"], false, "stream {stream}: {refused}");
        assert_eq!(refused["error"]["code"], "validation.invalid", "stream {stream}: {refused}");
    }
    // Without `stream`, the stream's lines are untagged, as before.
    let reply = connection.line(&v2_line(
        "plain",
        "session.events",
        json!({"machine":"current","session":"current","stream_id":FIRST}),
    ));
    assert_eq!(reply["ok"], true, "{reply}");
    let snapshot = pop(&connection.outbound);
    assert_eq!(snapshot["type"], "stream_item", "{snapshot}");
    assert_eq!(snapshot.get("stream"), None, "{snapshot}");
    connection.finish();
}

/// With frames granted, every item is an EVENT frame on the client stream,
/// its aux the item's sequence and its payload the item without a
/// `"stream"` tag; the `stream_end` stays a line and is the stream's last.
#[test]
fn with_frames_session_stream_items_are_event_frames_on_the_client_stream() {
    let mut client = Client::granted_with("session-stream-frames", &[ATTACH_STREAMS_CAPABILITY]);
    let open = |id: &str, stream_id: &str| -> Value {
        serde_json::from_str(&open_line(id, stream_id, 9)).expect("open line")
    };
    client.line(&open("open", FIRST));
    match client.next() {
        Some(Got::Line(reply)) => assert_eq!(reply["ok"], true, "{reply}"),
        other => panic!("expected the open's reply: {other:?}"),
    }
    match client.next() {
        Some(Got::Frame(header, item)) => {
            assert_eq!((header.kind(), header.stream()), (FrameKind::Event, 9));
            assert_eq!(header.aux(), Aux::Offset(0));
            assert_eq!((&item["type"], &item["sequence"]), (&json!("stream_item"), &json!("0")));
            assert_eq!(item["stream_id"], FIRST);
            assert_eq!(item.get("stream"), None, "the header names the stream: {item}");
        }
        other => panic!("expected the snapshot as an EVENT frame: {other:?}"),
    }
    client.line(&json!({"id": 30, "cmd": "cancel-stream", "stream": 9}));
    match client.next() {
        Some(Got::Line(end)) => {
            assert_eq!(end["type"], "stream_end", "{end}");
            assert_eq!((&end["stream"], &end["reason"]), (&json!(9), &json!("canceled")));
        }
        other => panic!("expected the stream_end before the reply: {other:?}"),
    }
    match client.next() {
        Some(Got::Line(reply)) => {
            assert_eq!(reply["id"], 30, "{reply}");
            assert_eq!(reply["data"]["outcome"], "applied", "{reply}");
        }
        other => panic!("expected the cancel-stream reply: {other:?}"),
    }
    // The id is free again: a new stream opens on it.
    client.line(&open("reopen", SECOND));
    match client.next() {
        Some(Got::Line(reply)) => assert_eq!(reply["ok"], true, "{reply}"),
        other => panic!("expected the reopen's reply: {other:?}"),
    }
    match client.next() {
        Some(Got::Frame(header, item)) => {
            assert_eq!((header.kind(), header.stream()), (FrameKind::Event, 9));
            assert_eq!(item["stream_id"], SECOND);
        }
        other => panic!("expected the new stream's snapshot frame: {other:?}"),
    }
    let _ = client.finish();
}
