use super::*;

#[tokio::test]
async fn peer_events_update_selected_transcript_and_preserve_selection_when_sorted() {
    let (mut app, _requests) = interaction_tests::app().await;
    app.drafts.clear();
    let local = json!({"sessionId": "raw", "name": "local", "updatedAt": 2});
    let remote = json!({"sessionId": "raw", "peer": "worker", "qualifiedSessionId": "worker/raw", "name": "worker/remote", "updatedAt": 1});
    app.sessions = vec![local.clone(), remote.clone()];
    app.selected = 1;
    app.transcripts.insert("worker/raw".into(), Transcript::default());
    app.on_notification(method::SESSION_UPDATE, json!({
            "sessionId": "raw", "peer": "worker",
            "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "remote reply"}}
        }));
    assert!(
        !app.transcripts["worker/raw"].items.is_empty(),
        "remote update must reach the selected transcript"
    );
    assert!(
        !app.transcripts.contains_key("raw"),
        "remote output must not enter a local transcript"
    );
    let mut changed = remote.clone();
    changed["updatedAt"] = json!(3);
    app.on_notification(
        method::MUX_SESSION_CHANGED,
        json!({"sessionId": "raw", "peer": "worker", "session": changed, "kind": "turn_start"}),
    );
    assert_eq!(app.sessions.len(), 2);
    assert_eq!(app.selected, 0);
    assert_eq!(app.selected_id().as_deref(), Some("worker/raw"));
    assert_eq!(app.sessions[1], local);
    // The returned list may already have a new order before sort_sessions runs.
    app.on_msg(AppMsg::Sessions(vec![local.clone(), remote]));
    assert_eq!(app.selected_id().as_deref(), Some("worker/raw"));
    app.on_notification(method::MUX_SESSION_CHANGED, json!({"sessionId": "raw", "peer": "worker", "session": {"sessionId": "raw"}, "kind": "purged"}));
    assert_eq!(app.sessions, vec![local]);
    assert!(!app.transcripts.contains_key("worker/raw"));
}
