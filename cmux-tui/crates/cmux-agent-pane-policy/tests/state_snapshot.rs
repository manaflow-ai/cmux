use cmux_agent_pane_policy::gesture::PermissionOptions;
use cmux_agent_pane_policy::{PaneScope, PaneSessions};
use serde_json::json;

fn permission_pending() -> serde_json::Map<String, serde_json::Value> {
    json!({
        "method": "_acpmux/permission_pending",
        "params": {
            "permissionId": "p1",
            "request": {
                "options": [
                    {"optionId": "allow", "kind": "allow"},
                    {"optionId": "deny", "kind": "reject_user"}
                ],
                "toolCall": {"_meta": {"acpmux": {"question": {
                    "items": [{"id": "choice", "prompt": "Which?"}]
                }}}}
            }
        }
    })
    .as_object()
    .unwrap()
    .clone()
}

#[test]
fn permission_snapshot_is_atomic_and_independent() {
    let options = PermissionOptions::new();
    options.observe(&permission_pending(), None);

    // One observation publishes both halves of the state together.
    assert_eq!(options.question_keys("p1").unwrap().len(), 2);
    assert!(options.is_known_allow("p1", "allow"));
    assert!(options.is_deny("p1", "deny"));

    let snapshot = options.snapshot();
    options.observe(
        &json!({
            "method": "_acpmux/permission_pending",
            "params": {"permissionId": "p1", "request": {
                "options": [{"optionId": "allow", "kind": "reject_policy"}]
            }}
        })
        .as_object()
        .unwrap()
        .clone(),
        None,
    );

    // The source advances to a deny, while the snapshot remains the prior
    // coherent generation (question keys plus allow/deny observations).
    assert!(!options.is_known_allow("p1", "allow"));
    assert!(options.is_deny("p1", "allow"));
    assert!(snapshot.is_known_allow("p1", "allow"));
    assert_eq!(snapshot.question_keys("p1").unwrap().len(), 2);
}

#[test]
fn session_snapshot_is_independent_for_sessions_and_handoffs() {
    let sessions = PaneSessions::new();
    sessions.add("s1");
    sessions.sent("_acpmux/handoff_prepare", Some("request-1"), Some("h1"), true);
    sessions.observe(
        &json!({
            "id": "request-1",
            "result": {"handoffId": "h1", "source": {"sessionId": "s1"}}
        })
        .as_object()
        .unwrap()
        .clone(),
    );
    let snapshot = sessions.snapshot();

    sessions.add("s2");
    assert!(sessions.contains("s2"));
    assert!(!snapshot.contains("s2"));
    assert!(snapshot.contains("s1"));
    assert!(snapshot.holds_source(&json!({"handoffId": "h1"}).as_object().unwrap()));
}
