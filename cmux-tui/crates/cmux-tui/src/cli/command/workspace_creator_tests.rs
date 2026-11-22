use serde_json::json;

#[test]
fn an_acpmux_session_creates_as_an_agent_naming_its_session() {
    assert_eq!(
        super::creator("ws_a".into(), Some("b5a59c5f".into())),
        json!({"kind": "agent", "workspace": "ws_a", "session": "b5a59c5f"})
    );
    assert_eq!(super::creator("ws_a".into(), None), json!({"kind": "script", "workspace": "ws_a"}));
    assert_eq!(
        super::creator("ws_a".into(), Some(String::new())),
        json!({"kind": "script", "workspace": "ws_a"})
    );
}
