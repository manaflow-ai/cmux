//! Session event and journal streams end when their outbound closes on its
//! own (a victim of a full connection queue), not only when the stream is
//! canceled or the connection closes. The outbound close fires the stream's
//! interrupt; a loop that did not check the outbound returned from the wait
//! at once on every pass and spun at 100% CPU until the next journal event.

use super::super::*;

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

/// Runs `body` on a thread, lets it reach its wait loop, closes `outbound`
/// alone, and fails if `body` does not return within 2 s.
fn returns_after_outbound_close(
    what: &str,
    outbound: OutboundStream,
    body: impl FnOnce() + Send + 'static,
) {
    let (done_tx, done_rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        body();
        let _ = done_tx.send(());
    });
    // Test-only settle: the initial items are sent and the loop is waiting.
    std::thread::sleep(Duration::from_millis(300));
    assert!(done_rx.try_recv().is_err(), "{what} ended before its outbound closed");
    outbound.close();
    done_rx
        .recv_timeout(Duration::from_secs(2))
        .unwrap_or_else(|_| panic!("{what} kept running after its outbound closed"));
}

#[test]
fn session_event_stream_ends_when_its_outbound_closes_alone() {
    let mux = Mux::new_for_test("event-stream-close", crate::SurfaceOptions::default());
    let (writer, _outbound) = tests::captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let request = request("session.events", "stream_22222222222242228222222222222222", json!({}));
    let (_, start) = prepare_session_event_stream(&mux, client, &writer, &request).unwrap();
    let outbound = start.outbound.clone();
    returns_after_outbound_close("the session event stream", outbound, move || {
        run_session_event_stream(&mux, client, &writer, start);
    });
}

#[test]
fn session_journal_stream_ends_when_its_outbound_closes_alone() {
    let mux = Mux::new_for_test("journal-stream-close", crate::SurfaceOptions::default());
    let (writer, _outbound) = tests::captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let request = request(
        "session.journal.subscribe",
        "stream_33333333333343338333333333333333",
        json!({"start":"beginning","filter":{"kinds":["workspace.*"],"max_sensitivity":"sensitive"}}),
    );
    let (_, start) = prepare_session_journal_stream(&mux, client, &writer, &request).unwrap();
    let outbound = start.outbound.clone();
    returns_after_outbound_close("the session journal stream", outbound, move || {
        run_session_journal_stream(&mux, client, &writer, start);
    });
}
