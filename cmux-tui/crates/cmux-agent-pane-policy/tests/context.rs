//! Context reads and persistent edits through the full pane transport gate.
use cmux_agent_pane_policy::gesture::PermissionOptions;
use cmux_agent_pane_policy::{Checked, FrameState, Gesture, PaneSessions, Refusal, check_frame};
use serde_json::{Value, json};

fn check(method: &str, params: Value, first: bool) -> Checked {
    let sessions = PaneSessions::new();
    sessions.add("own");
    let options = PermissionOptions::new();
    let state = FrameState {
        is_first: first,
        local_app_token: None,
        mode_fields: None,
        // A Cloud chat's pane: the relayed wire this command serves.
        remote_wire: true,
        gesture: Gesture::None,
        scope: &sessions,
        options: &options,
    };
    check_frame(
        &json!({"jsonrpc":"2.0", "id":7, "method":method, "params":params}).to_string(),
        &state,
    )
}

#[test]
fn context_reads_reach_the_wire_without_a_gesture() {
    let params = json!({"sessionId":"own"});
    let Checked::Frame { frame, facts } = check("_acpmux/context", params.clone(), false) else {
        panic!("Context read refused before the wire")
    };
    assert!(facts.free());
    assert!(!facts.needs_gesture);
    assert_eq!(frame["params"], params);
}

#[test]
fn context_edits_empty_overrides_and_resets_wait_for_the_persons_click() {
    for scope in ["user", "project"] {
        for text in [json!("Read independent sources concurrently."), json!(""), Value::Null] {
            let params = json!({"sessionId":"own", "scope":scope, "text":text, "partId":"cmux-system-prompt"});
            let Checked::Frame { frame, facts } =
                check("_acpmux/context_override", params.clone(), false)
            else {
                panic!("Context edit refused before the wire")
            };
            assert!(facts.needs_gesture);
            assert!(!facts.free());
            assert_eq!(frame["params"], params);
        }
    }
}

fn expect_refusal(method: &str, params: Value, first: bool, expected: Refusal) {
    let Checked::Refuse { refused, .. } = check(method, params, first) else {
        panic!("Context request escaped the transport gate")
    };
    assert_eq!(refused.refusal, expected);
}

#[test]
fn context_requires_the_panes_session() {
    for method in ["_acpmux/context", "_acpmux/context_override"] {
        for params in [
            json!({}),
            json!({"sessionId":"foreign"}),
            json!({"sessionId":null}),
            json!({"sessionId":7}),
        ] {
            expect_refusal(method, params, false, Refusal::SessionNotInPane);
        }
    }
}

/// A forged key never reaches the daemon: one the method does not take is dropped (P0, so a newer
/// page keeps its chats), and `_meta` that is not an object is refused.
#[test]
fn context_drops_forged_params_and_refuses_forged_metadata() {
    for method in ["_acpmux/context", "_acpmux/context_override"] {
        for key in ["cwd", "host", "unknown"] {
            let mut params = json!({"sessionId":"own"});
            params[key] = json!("/other/project");
            let Checked::Frame { frame, facts } = check(method, params, false) else {
                panic!("{method} refused a frame whose forged {key} the strip drops")
            };
            assert_eq!(frame["params"], json!({"sessionId":"own"}), "{method} {key}");
            assert_eq!(facts.dropped, [key]);
        }
        let params = json!({"sessionId":"own", "_meta":"/other/project"});
        expect_refusal(method, params, false, Refusal::IntentInvalid);
    }
}

#[test]
fn context_cannot_replace_the_handshake() {
    for method in ["_acpmux/context", "_acpmux/context_override"] {
        expect_refusal(method, json!({"sessionId":"own"}), true, Refusal::FirstFrameNotInitialize);
    }
}
