//! Session event and journal streams end when their outbound closes on its
//! own (a victim of a full connection queue), not only when the stream is
//! canceled or the connection closes. The outbound close fires the stream's
//! drain's stop; both run as drains on the work lanes (p05-ipc-146, 147)
//! and hold no thread.

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

/// The journal stream is a drain on the mux's work lanes (p05-ipc-147):
/// closing its outbound alone ends it, which frees its id and its worker
/// permit, and no thread is left waiting on the journal.
#[test]
fn session_journal_stream_ends_when_its_outbound_closes_alone() {
    let mux = Mux::new_for_test("journal-stream-close", crate::SurfaceOptions::default());
    let (writer, _captured) = tests::captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let stream_id = "stream_33333333333343338333333333333333";
    let request = request(
        "session.journal.subscribe",
        stream_id,
        json!({"start":"beginning","filter":{"kinds":["workspace.*"],"max_sensitivity":"sensitive"}}),
    );
    let (_, start) = prepare_session_journal_stream(&mux, client, &writer, &request).unwrap();
    let outbound = start.outbound.clone();
    start_session_journal_stream(mux.clone(), client, writer, start);
    let admission = &mux.control_clients.resource_stream_admission;
    assert!(
        !admission.wait_until_idle(Instant::now() + Duration::from_millis(100)),
        "the journal stream ended before its outbound closed"
    );
    outbound.close();
    assert!(
        admission.wait_until_idle(Instant::now() + Duration::from_secs(2)),
        "the journal stream kept its worker permit after its outbound closed"
    );
    let parsed = StreamPublicId::parse(stream_id.to_string()).unwrap();
    assert!(
        mux.control_clients.take_resource_stream(client, &parsed).is_none(),
        "the ended stream kept its id"
    );
    mux.shutdown();
}

/// A live journal stream sends each commit as the next item, woken by the
/// commit, not by a thread waiting on the journal (p05-ipc-147).
#[test]
fn session_journal_stream_sends_each_commit_as_it_lands() {
    let mux = Mux::new_for_test("journal-stream-live", crate::SurfaceOptions::default());
    let (writer, captured) = tests::captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let request = request(
        "session.journal.subscribe",
        "stream_55555555555545558555555555555555",
        json!({"filter":{"kinds":["workspace.*"],"max_sensitivity":"sensitive"}}),
    );
    let (_, start) = prepare_session_journal_stream(&mux, client, &writer, &request).unwrap();
    let outbound = start.outbound.clone();
    start_session_journal_stream(mux.clone(), client, writer, start);
    mux.new_workspace_as(&crate::Actor::Daemon, Some("woken".into()), Some((80, 24))).unwrap();
    let item = next_json(&captured);
    assert_eq!(item["type"], "stream_item", "{item}");
    assert_eq!(item["sequence"], "0", "{item}");
    assert!(item["item"]["kind"].as_str().is_some_and(|kind| kind.starts_with("workspace.")));
    outbound.close();
    mux.shutdown();
}

/// A bounded replay (`follow: false`) sends what the journal held when it
/// opened and ends `completed` behind those items, without a thread.
#[test]
fn session_journal_stream_bounded_replay_completes() {
    let mux = Mux::new_for_test("journal-stream-bounded", crate::SurfaceOptions::default());
    mux.new_workspace_as(&crate::Actor::Daemon, Some("held".into()), Some((80, 24))).unwrap();
    let (writer, captured) = tests::captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let request = request(
        "session.journal.subscribe",
        "stream_66666666666646668666666666666666",
        json!({"start":"beginning","follow":false,
               "filter":{"kinds":["workspace.*"],"max_sensitivity":"sensitive"}}),
    );
    let (_, start) = prepare_session_journal_stream(&mux, client, &writer, &request).unwrap();
    start_session_journal_stream(mux.clone(), client, writer, start);
    let mut items = 0;
    let end = loop {
        let line = next_json(&captured);
        if line["type"] == "stream_item" {
            items += 1;
            continue;
        }
        break line;
    };
    assert!(items > 0, "the replay sent no record");
    assert_eq!(end["type"], "stream_end", "{end}");
    assert_eq!(end["reason"], "completed", "{end}");
    let admission = &mux.control_clients.resource_stream_admission;
    assert!(admission.wait_until_idle(Instant::now() + Duration::from_secs(2)));
    mux.shutdown();
}
