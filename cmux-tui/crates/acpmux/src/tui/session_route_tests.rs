use super::session_route_id;
use serde_json::json;

#[test]
fn peer_rows_keep_the_qualified_route_for_tui_requests() {
    assert_eq!(
        session_route_id(
            &json!({"sessionId": "raw", "peer": "box", "qualifiedSessionId": "box/raw"})
        ),
        Some("box/raw".into())
    );
    assert_eq!(session_route_id(&json!({"sessionId": "local"})), Some("local".into()));
}
