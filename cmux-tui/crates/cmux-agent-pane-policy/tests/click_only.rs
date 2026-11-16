//! The click rule (`policy.json` `click_only`, the Swift host's
//! `AcpmuxPaneMethods.answerAllowed`): an answer to a permission prompt, a
//! plan build and a preset approval go on the person's click only. The check
//! itself refuses such a frame for a host that holds a key press or no
//! gesture, so a host that never learned the rule cannot let one through.

use cmux_agent_pane_policy::gesture::{PermissionOptions, needs_click};
use cmux_agent_pane_policy::{
    Checked, FrameState, Gesture, PaneSessions, Refusal, check_frame, policy,
};
use serde_json::{Value, json};

/// The check of one later frame of the pane's session `own`. The daemon
/// offered `no` as a deny of the permission `p1`.
fn check(method: &str, params: Value, gesture: Gesture) -> Checked {
    let sessions = PaneSessions::new();
    sessions.add("own");
    let options = PermissionOptions::new();
    let pending = json!({"method": "_acpmux/permission_pending", "params": {
        "permissionId": "p1", "request": {"options": [{"optionId": "no", "kind": "reject_once"}]}}});
    options.observe(pending.as_object().expect("a frame object"), None);
    let state = FrameState {
        is_first: false,
        local_app_token: None,
        mode_fields: None,
        remote_wire: false,
        gesture,
        scope: &sessions,
        options: &options,
    };
    check_frame(
        &json!({"jsonrpc": "2.0", "id": 7, "method": method, "params": params}).to_string(),
        &state,
    )
}

/// One granting frame of each click-only method.
fn answers() -> [(&'static str, Value); 4] {
    [
        (
            "_acpmux/presets",
            json!({"name": "night", "approveMode": true, "approveDigest": "sha256:ab", "sessionId": "own"}),
        ),
        (
            "_acpmux/plan/build",
            json!({"sessionId": "own", "permissionId": "p1", "target": "compare"}),
        ),
        (
            "_acpmux/permission_respond",
            json!({"sessionId": "own", "permissionId": "p1", "optionId": "yes"}),
        ),
        (
            "_acpmux/permission_group_respond",
            json!({"sessionId": "own", "groupId": "g1", "revision": 1, "decisionKey": "k", "decision": "allow_once"}),
        ),
    ]
}

#[test]
fn the_click_only_methods_are_requests_with_a_gesture_rule() {
    let p = policy();
    assert!(!p.click_only.is_empty(), "policy.json click_only is empty");
    for method in &p.click_only {
        assert!(p.requests.contains(method), "{method} is no request");
        assert!(p.gesture_rules.contains_key(method), "{method} has no gesture rule");
    }
    assert!(p.click_window_ms > 0, "policy.json click_window_ms is 0: no click is fresh");
}

#[test]
fn a_click_only_answer_is_refused_for_a_key_only_gesture() {
    for (method, params) in answers() {
        let Checked::Refuse { refused, spend } = check(method, params, Gesture::Key) else {
            panic!("{method} passed on a key press")
        };
        assert_eq!(refused.refusal, Refusal::GestureRequired, "{method}");
        assert_eq!(refused.refusal.code(), "transport.gesture_required");
        assert_eq!(refused.method.as_deref(), Some(method));
        assert_eq!(refused.request_id.as_deref(), Some("7"), "{method}");
        assert_eq!(spend, None, "{method}");
    }
}

/// A host that does not say which gesture it holds (the C check without the
/// gesture argument, [`Gesture::None`]) gets the same refuse.
#[test]
fn a_click_only_answer_is_refused_for_a_host_that_names_no_gesture() {
    for (method, params) in answers() {
        let Checked::Refuse { refused, .. } = check(method, params, Gesture::None) else {
            panic!("{method} passed with no gesture")
        };
        assert_eq!(refused.refusal, Refusal::GestureRequired, "{method}");
    }
}

#[test]
fn a_click_only_answer_passes_on_a_click_and_its_facts_say_so() {
    for (method, params) in answers() {
        let Checked::Frame { frame, facts } = check(method, params.clone(), Gesture::Click) else {
            panic!("{method} refused on a click")
        };
        assert_eq!(frame["params"], params, "{method}");
        assert!(facts.needs_gesture, "{method}");
        assert!(facts.needs_click, "{method}");
        assert_eq!(facts.to_json()["needs_click"], true, "{method}");
        assert!(!facts.free(), "{method}: the host spends its click on it");
    }
}

/// The crate is stricter than the Swift host here, on purpose. The Swift host
/// gives a ticket for a permission answer or a plan build after a click, and
/// for a permission answer also on the person's Return key on a question
/// (`AgentPaneTransport.reserveGesture`, `takeQuestionKeyTicket`); it then
/// passes the ticketed frame with no second click. This check knows nothing
/// of where a ticket came from, so a ticket is no click: the frame is refused
/// and its ticket spent, also the one the Return key gave (the `Key` arm
/// below). The move of the Swift host onto this check must bring those ticket
/// rules with it, and then change this test.
#[test]
fn a_ticket_is_no_click_which_differs_from_the_swift_host() {
    let ticketed = [
        (
            "_acpmux/permission_respond",
            json!({"sessionId": "own", "permissionId": "p1", "optionId": "yes",
                "_meta": {"cmuxGesture": "t1"}}),
        ),
        (
            "_acpmux/plan/build",
            json!({"sessionId": "own", "permissionId": "p1", "target": "compare",
                "_meta": {"cmuxGesture": "t1"}}),
        ),
    ];
    for (method, params) in ticketed {
        for gesture in [Gesture::None, Gesture::Key] {
            let Checked::Refuse { refused, spend } = check(method, params.clone(), gesture) else {
                panic!("{method} passed on a ticket with {gesture:?}")
            };
            assert_eq!(refused.refusal, Refusal::GestureRequired, "{method} {gesture:?}");
            assert_eq!(spend.as_deref(), Some("t1"), "{method} {gesture:?}: the ticket is spent");
        }
        let Checked::Frame { facts, .. } = check(method, params, Gesture::Click) else {
            panic!("{method} refused on a ticket with a click")
        };
        assert_eq!(facts.ticket.as_deref(), Some("t1"), "{method}");
        assert!(facts.needs_click, "{method}");
    }
}

/// `policy.json` gives each click-only method a gesture rule (the first test
/// of this file). Should an edit drop one, the rule fails closed: each frame
/// of that method needs a click, where `needs_gesture` alone would call it
/// free.
#[test]
fn a_click_only_method_with_no_gesture_rule_needs_a_click_on_each_frame() {
    // (click_only, ruled, needs_gesture)
    assert!(needs_click(true, false, false), "no rule: fail closed");
    assert!(needs_click(true, false, true));
    assert!(needs_click(true, true, true), "a granting answer");
    assert!(!needs_click(true, true, false), "a deny keeps its rule and needs no click");
    for ruled in [false, true] {
        for needs_gesture in [false, true] {
            assert!(!needs_click(false, ruled, needs_gesture), "no click-only method");
        }
    }
}

/// A deny grants nothing: it needs no gesture, so no click.
#[test]
fn a_deny_needs_no_click() {
    let denies = [
        (
            "_acpmux/permission_respond",
            json!({"sessionId": "own", "permissionId": "p1", "optionId": "no"}),
        ),
        (
            "_acpmux/permission_group_respond",
            json!({"sessionId": "own", "groupId": "g1", "revision": 1, "decisionKey": "k", "decision": "deny"}),
        ),
    ];
    for (method, params) in denies {
        for gesture in [Gesture::None, Gesture::Key, Gesture::Click] {
            let Checked::Frame { facts, .. } = check(method, params.clone(), gesture) else {
                panic!("the deny of {method} was refused with {gesture:?}")
            };
            assert!(!facts.needs_gesture, "{method} {gesture:?}");
            assert!(!facts.needs_click, "{method} {gesture:?}");
        }
    }
}

/// The rule is for the answer methods only: a send still goes on a key press.
#[test]
fn a_frame_of_another_method_needs_no_click() {
    let params = json!({"sessionId": "own", "prompt": []});
    for gesture in [Gesture::None, Gesture::Key, Gesture::Click] {
        let Checked::Frame { facts, .. } = check("session/prompt", params.clone(), gesture) else {
            panic!("a prompt was refused with {gesture:?}")
        };
        assert!(facts.needs_gesture, "{gesture:?}: the host still decides the gesture");
        assert!(!facts.needs_click, "{gesture:?}");
    }
}
