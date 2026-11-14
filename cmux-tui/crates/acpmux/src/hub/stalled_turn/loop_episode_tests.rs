use super::*;

#[tokio::test]
async fn loop_episode_updates_summary_sequence_and_clears_on_progress() {
    let cfg = crate::config::Config::default();
    let store = Box::new(crate::store::MemoryStore::default());
    let hub = Hub::new(cfg, store);
    let meta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "loop-test", "name": "loop-test",
        "harness": "fake", "cwd": "/tmp", "status": "running", "createdAt": 1, "updatedAt": 1,
    }))
    .unwrap();
    let session = hub.make_session(meta);
    *session.turn.lock().unwrap() = Some(TurnInfo {
        trigger: false,
        started_at: 1,
        client: "test".into(),
        prompt_preview: String::new(),
        masked_preview: String::new(),
        turn_id: "turn-test".into(),
        prompt_id: "prompt-test".into(),
        turn_seq: 1,
        control: Control::Local,
        doing: Default::default(),
        notice: false,
        persons: false,
        accepted: true,
    });
    hub.watch_stalled_turn(&session, None);
    let before = session.state_seq.load(Ordering::SeqCst);
    for id in ["a", "b", "c", "d"] {
        hub.note_tool_update(&session, &json!({"sessionUpdate": "tool_call", "toolCallId": id,
                "kind": "execute", "title": "cargo test", "rawInput": {"command": "cargo test"}, "status": "in_progress"}));
        hub.note_tool_update(
            &session,
            &json!({"sessionUpdate": "tool_call_update", "toolCallId": id, "status": "failed"}),
        );
    }
    let summary = hub.session_summary(&session);
    assert_eq!(summary["state"], "running");
    assert_eq!(summary["loopEpisode"]["count"], 3);
    assert!(summary["stuckReason"].is_null());
    assert_eq!(session.state_seq.load(Ordering::SeqCst), before + 1, "one detection per episode");
    hub.note_tool_update(&session, &json!({"sessionUpdate": "tool_call_update", "toolCallId": "success", "status": "completed"}));
    let summary = hub.session_summary(&session);
    assert_eq!(
        summary.get("loopEpisode"),
        Some(&Value::Null),
        "clear must be explicit on the wire"
    );
    assert_eq!(summary["state"], "running");
    assert_eq!(session.state_seq.load(Ordering::SeqCst), before + 2);

    // A turn can finish while stuck. Publishing the next turn before its prompt is
    // written must not revive that episode; both reset paths must notify watchers.
    for reset_on_prompt_write in [false, true] {
        for id in ["next-a", "next-b", "next-c"] {
            hub.note_tool_update(
                &session,
                &json!({
                    "sessionUpdate": "tool_call", "toolCallId": id, "kind": "execute",
                    "rawInput": {"command": "cargo test"}, "status": "failed"
                }),
            );
        }
        assert!(hub.session_summary(&session)["loopEpisode"].is_object());
        let before_reset = session.state_seq.load(Ordering::SeqCst);
        if reset_on_prompt_write {
            hub.watch_stalled_turn(&session, None);
        } else {
            let mut next = session.turn.lock().unwrap().take().unwrap();
            assert_eq!(hub.session_summary(&session)["loopEpisode"], Value::Null);
            next.turn_id = "next-turn".into();
            *session.turn.lock().unwrap() = Some(next);
            assert_eq!(hub.session_summary(&session)["loopEpisode"], Value::Null);
            hub.hold_stalled_count(&session);
        }
        assert_eq!(session.state_seq.load(Ordering::SeqCst), before_reset + 1);
        assert_eq!(hub.session_summary(&session)["loopEpisode"], Value::Null);
        hub.watch_stalled_turn(&session, None);
        assert_eq!(session.state_seq.load(Ordering::SeqCst), before_reset + 1);
    }
    hub.shutdown_all().await;
}
