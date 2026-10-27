//! Resource streams run as drains on the sequenced pool (p01-process-204).
//!
//! Session event and journal streams end when their outbound closes on its
//! own (a victim of a full connection queue), not only when the stream is
//! canceled or the connection closes: the outbound close fires the pump's
//! stop interrupt, and the next turn releases the stream. (As threads, a
//! loop that did not check the outbound returned from its wait at once on
//! every pass and spun at 100% CPU until the next journal event.)
//!
//! None of them holds a thread: many streams on one connection add none
//! beyond the pool's workers.

use super::super::*;
use std::time::Instant;

fn request(
    operation: &str,
    stream: &str,
    extra: Value,
) -> crate::resource_router::ParsedResourceRequest {
    let mut params = json!({"machine":"current","session":"current","stream_id":stream});
    for (key, value) in extra.as_object().unwrap() {
        params[key] = value.clone();
    }
    let message = json!({
        "protocol":"cmux.protocol/2",
        "type":"request",
        "id":"stream-close",
        "operation":operation,
        "params":params,
    });
    crate::resource_router::parse_resource_request(&message.to_string()).unwrap()
}

fn stream_id(id: &str) -> StreamPublicId {
    serde_json::from_value(json!(id)).unwrap()
}

/// Waits up to 2 s for `done`.
fn eventually(what: &str, done: impl Fn() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(2);
    while !done() {
        assert!(Instant::now() < deadline, "{what}");
        // Test-only poll of state the pool's workers change.
        std::thread::sleep(Duration::from_millis(5));
    }
}

/// Lets the stream reach its idle turn, closes `outbound` alone, and fails
/// if the stream still holds its registration 2 s later.
fn releases_after_outbound_close(
    what: &str,
    mux: &Arc<Mux>,
    client: u64,
    id: &str,
    outbound: OutboundStream,
) {
    // Test-only settle: the initial items are sent and the drain is idle.
    std::thread::sleep(Duration::from_millis(300));
    let registered = || mux.control_clients.resource_stream_registered(client, &stream_id(id));
    assert!(registered(), "{what} ended before its outbound closed");
    outbound.close();
    eventually(&format!("{what} kept its registration after its outbound closed"), || {
        !registered()
    });
}

#[test]
fn session_event_stream_ends_when_its_outbound_closes_alone() {
    let mux = Mux::new_for_test("event-stream-close", crate::SurfaceOptions::default());
    let (writer, _outbound) = tests::captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let id = "stream_22222222222242228222222222222222";
    let request = request("session.events", id, json!({}));
    let (_, start) = prepare_session_event_stream(&mux, client, &writer, &request).unwrap();
    let outbound = start.outbound.clone();
    start_session_event_stream(mux.clone(), client, writer, start);
    releases_after_outbound_close("the session event stream", &mux, client, id, outbound);
}

#[test]
fn session_journal_stream_ends_when_its_outbound_closes_alone() {
    let mux = Mux::new_for_test("journal-stream-close", crate::SurfaceOptions::default());
    let (writer, _outbound) = tests::captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let id = "stream_33333333333343338333333333333333";
    let request = request(
        "session.journal.subscribe",
        id,
        json!({"start":"beginning","filter":{"kinds":["workspace.*"],"max_sensitivity":"sensitive"}}),
    );
    let (_, start) = prepare_session_journal_stream(&mux, client, &writer, &request).unwrap();
    let outbound = start.outbound.clone();
    start_session_journal_stream(mux.clone(), client, writer, start);
    releases_after_outbound_close("the session journal stream", &mux, client, id, outbound);
}

/// A live session event stream follows the journal with no thread of its
/// own: a commit wakes its drain, which sends the delta.
#[test]
fn session_event_stream_sends_a_delta_for_a_commit_without_a_thread() {
    let mux = Mux::new_for_test("event-stream-delta", crate::SurfaceOptions::default());
    let (writer, outbound) = tests::captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let id = "stream_44444444444444448444444444444444";
    let request = request("session.events", id, json!({}));
    let (_, start) = prepare_session_event_stream(&mux, client, &writer, &request).unwrap();
    start_session_event_stream(mux.clone(), client, writer, start);
    let snapshot = tests::pop_json(&outbound);
    assert_eq!(snapshot["item"]["kind"], "snapshot", "{snapshot}");

    mux.new_workspace(Some("delta".to_string()), Some((80, 24))).unwrap();
    let delta = tests::pop_json(&outbound);
    assert_eq!(delta["type"], "stream_item", "{delta}");
    assert_eq!(delta["stream_id"], id);
    assert_eq!(delta["sequence"], "1");
    assert_eq!(delta["item"]["kind"], "delta", "{delta}");
}

/// A bounded journal replay whose `completed` end finds the stream at its
/// backpressure cap does not wait for room: the connection wakes the drain
/// when an item leaves its queue, and `completed` follows every item.
#[test]
fn bounded_journal_replay_completes_behind_its_items_without_waiting() {
    let mux = Mux::new_for_test("journal-replay-complete", crate::SurfaceOptions::default());
    for index in 0..8 {
        mux.new_workspace(Some(format!("replay-{index}")), Some((80, 24))).unwrap();
    }
    let (writer, outbound) = tests::captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let id = "stream_55555555555545558555555555555555";
    let request = request(
        "session.journal.subscribe",
        id,
        json!({
            "start":"beginning",
            "follow":false,
            "filter":{"kinds":["workspace.*"],"max_sensitivity":"sensitive"},
        }),
    );
    let (_, start) = prepare_session_journal_stream(&mux, client, &writer, &request).unwrap();
    start_session_journal_stream(mux.clone(), client, writer, start);

    let mut items = 0;
    loop {
        let message = tests::pop_json(&outbound);
        if message["type"] == "stream_item" {
            assert_eq!(message["sequence"], items.to_string(), "{message}");
            items += 1;
            continue;
        }
        assert_eq!(message["type"], "stream_end", "{message}");
        assert_eq!(message["reason"], "completed", "{message}");
        break;
    }
    assert!(items > OUTBOUND_BACKPRESSURED_STREAM_CAPACITY, "{items} items");
    eventually("the replay kept its registration", || {
        !mux.control_clients.resource_stream_registered(client, &stream_id(id))
    });
}
