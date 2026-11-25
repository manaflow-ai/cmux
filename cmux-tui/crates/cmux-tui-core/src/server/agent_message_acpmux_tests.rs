use super::session_info;
use serde_json::json;

#[test]
fn peer_session_info_is_allowed_only_for_forwarding() {
    assert!(session_info(&json!({"sessionId": "chat"}), "chat", true));
    assert!(session_info(&json!({"sessionId": "chat", "peer": null}), "chat", true));
    assert!(!session_info(&json!({"sessionId": "chat", "peer": "other"}), "chat", true));
    assert!(!session_info(&json!({"sessionId": "other"}), "chat", true));
    assert!(session_info(&json!({"sessionId": "chat", "peer": "other"}), "chat", false));
}
