//! Restore reaches the daemon only for this pane's session and durable evidence IDs.
use cmux_agent_pane_policy::check::{Checked, FrameState, PaneScope, check_frame};
use cmux_agent_pane_policy::gesture::PermissionOptions;
use cmux_agent_pane_policy::Refusal;
use serde_json::{Map, Value, json};

struct Scope;

impl PaneScope for Scope {
    fn contains(&self, session: &str) -> bool {
        session == "pane-session"
    }

    fn holds_source(&self, _params: &Map<String, Value>) -> bool {
        false
    }
}

fn check(params: Value) -> Checked {
    check_frame(
        &json!({"jsonrpc": "2.0", "id": 37, "method": "_acpmux/test_tampering_restore", "params": params})
            .to_string(),
        &FrameState {
            is_first: false,
            local_app_token: None,
            mode_fields: None,
            remote_wire: false,
            scope: &Scope,
            options: &PermissionOptions::default(),
        },
    )
}

fn target() -> Value {
    json!({"sessionId": "pane-session", "eventSeq": 74, "fileIndex": 0, "findingIndex": 0})
}

#[test]
fn restore_passes_the_full_transport_check_with_only_durable_evidence() {
    // One click can issue several independent bounded inverses; daemon auth and evidence
    // validation remain mandatory for each. No page-supplied path or replacement is accepted.
    for finding in [0, 1] {
        let mut params = target();
        params["findingIndex"] = json!(finding);
        let Checked::Frame { frame, facts } = check(params.clone()) else {
            panic!("the pane's Restore must reach the daemon");
        };
        assert_eq!(frame["params"], params);
        assert!(!facts.needs_gesture);
        assert!(!facts.needs_path_check);
    }
}

#[test]
fn restore_cannot_select_another_panes_session_or_omit_its_session() {
    for session in [json!("other-session"), Value::Null, json!(42)] {
        let mut params = target();
        params["sessionId"] = session;
        assert!(matches!(check(params), Checked::Refuse { refused, .. }
            if refused.refusal == Refusal::SessionNotInPane));
    }
    let mut params = target();
    params.as_object_mut().unwrap().remove("sessionId");
    assert!(matches!(check(params), Checked::Refuse { refused, .. }
        if refused.refusal == Refusal::SessionNotInPane));
}

#[test]
fn restore_cannot_supply_filesystem_content_or_authority() {
    for (key, value) in [
        ("path", json!("/tmp/another-file")),
        ("replacement", json!("untrusted replacement")),
        ("command", json!("untrusted command")),
        ("personVerified", json!(true)),
        ("_meta", json!({"acpmux": {"localAppToken": "forged"}})),
    ] {
        let mut params = target();
        params[key] = value;
        assert!(matches!(check(params), Checked::Refuse { refused, .. }
            if refused.refusal == Refusal::IntentInvalid), "unexpectedly allowed {key}");
    }
}
