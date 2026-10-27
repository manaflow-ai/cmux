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

/// The next line the connection writes, within 2 s.
fn next_json(outbound: &BoundedOutbound) -> Value {
    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        if let Some(message) = outbound.try_pop() {
            return serde_json::from_str(&message).expect("outbound JSON");
        }
        assert!(Instant::now() < deadline, "timed out waiting for outbound JSON");
        std::thread::sleep(Duration::from_millis(2));
    }
}

/// The session event stream is a drain on the mux's work lanes
/// (p05-ipc-146): closing its outbound alone ends it, which frees its id
/// and its worker permit, and no thread is left waiting.
#[test]
fn session_event_stream_ends_when_its_outbound_closes_alone() {
    let mux = Mux::new_for_test("event-stream-close", crate::SurfaceOptions::default());
    let (writer, captured) = tests::captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let stream_id = "stream_22222222222242228222222222222222";
    let request = request("session.events", stream_id, json!({}));
    let (_, start) = prepare_session_event_stream(&mux, client, &writer, &request).unwrap();
    let outbound = start.outbound.clone();
    start_session_event_stream(mux.clone(), client, writer, start);
    let snapshot = next_json(&captured);
    assert_eq!(snapshot["item"]["kind"], "snapshot", "{snapshot}");
    let admission = &mux.control_clients.resource_stream_admission;
    assert!(
        !admission.wait_until_idle(Instant::now() + Duration::from_millis(100)),
        "the stream ended before its outbound closed"
    );
    outbound.close();
    assert!(
        admission.wait_until_idle(Instant::now() + Duration::from_secs(2)),
        "the session event stream kept its worker permit after its outbound closed"
    );
    let parsed = StreamPublicId::parse(stream_id.to_string()).unwrap();
    assert!(
        mux.control_clients.take_resource_stream(client, &parsed).is_none(),
        "the ended stream kept its id"
    );
}

/// A journal commit wakes the drain, which reads the page after its cursor
/// and sends it as the next item; with no commit it sends nothing more.
#[test]
fn session_event_stream_sends_each_commit_as_a_delta() {
    let mux = Mux::new_for_test("event-stream-delta", crate::SurfaceOptions::default());
    let (writer, captured) = tests::captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let request = request("session.events", "stream_44444444444444448444444444444444", json!({}));
    let (_, start) = prepare_session_event_stream(&mux, client, &writer, &request).unwrap();
    let outbound = start.outbound.clone();
    start_session_event_stream(mux.clone(), client, writer, start);
    assert_eq!(next_json(&captured)["item"]["kind"], "snapshot");

    mux.new_workspace_as(&crate::Actor::Daemon, Some("woken".into()), Some((80, 24))).unwrap();
    let delta = next_json(&captured);
    assert_eq!(delta["type"], "stream_item", "{delta}");
    assert_eq!(delta["item"]["kind"], "delta", "{delta}");
    assert_eq!(delta["sequence"], "1", "{delta}");
    // Test-only settle: nothing else is committed, so nothing else comes.
    std::thread::sleep(Duration::from_millis(200));
    while let Some(more) = captured.try_pop() {
        let more: Value = serde_json::from_str(&more).unwrap();
        assert_eq!(more["item"]["kind"], "delta", "{more}");
    }
    outbound.close();
    mux.shutdown();
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
