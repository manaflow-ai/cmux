use super::initial_session_matches;
use serde_json::json;

#[test]
fn initial_selection_accepts_a_peer_qualified_id() {
    let session = json!({"sessionId": "raw", "peer": "peer", "qualifiedSessionId": "peer/raw"});
    assert!(initial_session_matches(&session, "peer/raw"));
    assert!(!initial_session_matches(&session, "raw"));
    assert!(!initial_session_matches(&session, "other/raw"));
}

#[test]
fn initial_selection_keeps_the_local_owner_when_a_peer_reuses_its_id() {
    // The more recent peer row precedes the requested local row in the sidebar.
    let sessions = [
        json!({"sessionId": "raw", "peer": "peer", "qualifiedSessionId": "peer/raw"}),
        json!({"sessionId": "raw", "qualifiedSessionId": "local/raw"}),
    ];
    let initial = |id| sessions.iter().position(|s| initial_session_matches(s, id));
    assert_eq!(initial("raw"), Some(1), "a peer must not capture the local attach target");
    assert_eq!(initial("peer/raw"), Some(0));
}
