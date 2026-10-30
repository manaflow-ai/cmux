use super::*;

#[tokio::test]
async fn recovery_attach_pages_forward_until_exhausted() {
    let (mut app, mut requests) = super::interaction_tests::app().await;
    let id = "test-session";
    let mut transcript = Transcript::default();
    transcript.last_seq = 40;
    app.transcripts.insert(id.into(), transcript);
    app.recovery_in_flight.insert(id.into());
    app.recovery_pages.insert(id.into(), 1);
    app.recovery_replayed.insert(id.into(), 0);
    app.recovery_start.insert(id.into(), 40);

    app.on_msg(AppMsg::Attached {
        id: id.into(),
        detail: json!({"status": "running"}),
        events: vec![
            json!({"seq": 41, "dir": "mux", "kind": "user_message", "msg": {"text": "one"}}),
            json!({"seq": 42, "dir": "mux", "kind": "user_message", "msg": {"text": "two"}}),
        ],
        after_seq: Some(40),
        has_more: true,
        last_seq: 43,
    });

    let request = tokio::time::timeout(std::time::Duration::from_secs(5), requests.recv())
        .await
        .unwrap()
        .unwrap();
    assert_eq!(request["method"], method::MUX_ATTACH);
    assert_eq!(request["params"]["afterSeq"], 42);
    assert_eq!(request["params"]["limit"], 3000);
    assert!(app.recovery_in_flight.contains(id));

    app.on_msg(AppMsg::Attached {
        id: id.into(),
        detail: json!({"status": "completed"}),
        events: vec![
            // The page boundary may be repeated by the daemon; dedup it.
            json!({"seq": 42, "dir": "mux", "kind": "user_message", "msg": {"text": "two"}}),
            json!({"seq": 43, "dir": "mux", "kind": "user_message", "msg": {"text": "three"}}),
        ],
        after_seq: Some(42),
        has_more: false,
        last_seq: 43,
    });

    let transcript = app.transcripts.get(id).unwrap();
    assert_eq!(transcript.last_seq, 43);
    assert!(!app.recovery_in_flight.contains(id));
    assert_eq!(app.status, "recovered 3 events from seq 40");
}

#[tokio::test]
async fn recovery_attach_stops_on_a_non_advancing_page() {
    let (mut app, _) = super::interaction_tests::app().await;
    let id = "test-session";
    let mut transcript = Transcript::default();
    transcript.last_seq = 41;
    app.transcripts.insert(id.into(), transcript);
    app.recovery_in_flight.insert(id.into());
    app.recovery_pages.insert(id.into(), 1);
    app.recovery_replayed.insert(id.into(), 0);
    app.recovery_start.insert(id.into(), 40);

    app.on_msg(AppMsg::Attached {
        id: id.into(),
        detail: json!({"status": "running"}),
        events: vec![
            json!({"seq": 41, "dir": "mux", "kind": "user_message", "msg": {"text": "duplicate"}}),
        ],
        after_seq: Some(40),
        has_more: true,
        last_seq: 42,
    });

    assert!(!app.recovery_in_flight.contains(id));
    assert_eq!(
        app.status,
        "recovery stopped after seq 41; 0 events recovered from seq 40, more remain"
    );
}

#[tokio::test]
async fn a_removed_steer_row_keeps_folds_on_their_rows() {
    // A steer re-run at turn end replaces its steer row (transcript.rs): the folds a
    // person flipped below that row move up with their rows.
    let (mut app, _) = super::interaction_tests::app().await;
    let id = "test-session";
    let mux = |seq: u64, kind: &str, msg: Value| json!({"sessionId": id, "seq": seq, "at": 1_000 + seq, "dir": "mux", "kind": kind, "msg": msg});
    let thought = json!({"sessionId": id, "seq": 13, "at": 1_013, "dir": "in", "kind": "session/update", "msg": {
        "method": "session/update",
        "params": {"sessionId": id, "update": {
            "sessionUpdate": "agent_thought_chunk",
            "content": {"type": "text", "text": "thinking"},
        }},
    }});
    for e in [
        mux(10, "user_message", json!({"text": "go", "promptId": "p1", "turnId": "t1"})),
        mux(11, "turn_started", json!({"turnId": "t1"})),
        mux(
            12,
            "user_message",
            json!({"text": "also", "steer": true, "promptId": "p2", "turnId": "t1"}),
        ),
        thought,
        mux(14, "turn_result", json!({"turnId": "t1", "stopReason": "end_turn"})),
    ] {
        app.on_notification(method::MUX_EVENT, e);
    }
    assert!(matches!(app.transcripts[id].items[2], Item::Thought { .. }));
    app.toggled.insert(
        id.into(),
        [Toggle::Turn(0), Toggle::Turn(1), Toggle::Item(2)].into_iter().collect(),
    );

    app.on_notification(
        method::MUX_EVENT,
        mux(15, "user_message", json!({"text": "also", "promptId": "p2", "turnId": "t2"})),
    );

    let items = &app.transcripts[id].items;
    assert!(matches!(items[1], Item::Thought { .. }), "{items:?}");
    assert_eq!(
        app.toggled[id],
        [Toggle::Turn(0), Toggle::Item(1)].into_iter().collect(),
        "the thought's fold moved with it; the removed row's fold is gone"
    );
}
