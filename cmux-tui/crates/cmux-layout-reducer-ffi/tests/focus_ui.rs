//! The focus UI decisions (`focus_ui_*`, cmux-focus-core `ui`), replayed
//! against schemas/focus-ui-guards/vectors.json.
//!
//! The vectors were written from a line-by-line transliteration of the Swift
//! `NoActivateKeyboardGuard`, `ShortcutHintModifierPolicy`,
//! `PaneNavigationHintPlan`, `UnseenKeyboardGuard`,
//! `ResponderMoveGate.takesFromTyping` and `CrossWindowInputGuard.dropsKey`
//! before the Mac app moved to the Rust rules: random event sequences over
//! random host readings (held mouse or Command, an inactive app, times on
//! and around each window's edge), random modifier holds, random pane
//! orders with partial bindings, and random view and window facts.

use cmux_layout_reducer_ffi::{ERR_BUFFER, ERR_INVALID, OK, cmux_layout_reducer_json};
use serde_json::{Value, json};

const VECTORS: &str = include_str!("../../../../schemas/focus-ui-guards/vectors.json");

fn raw(operation: &std::ffi::CStr, request: &[u8]) -> (i32, Value) {
    let mut capacity = 256;
    loop {
        let mut output = vec![0u8; capacity];
        let mut len = 0usize;
        let code = unsafe {
            cmux_layout_reducer_json(
                request.as_ptr(),
                request.len(),
                operation.as_ptr(),
                output.as_mut_ptr(),
                output.len(),
                &mut len,
            )
        };
        if code == ERR_BUFFER && len > capacity {
            capacity = len;
            continue;
        }
        if code != OK {
            return (code, Value::Null);
        }
        return (code, serde_json::from_slice(&output[..len]).unwrap());
    }
}

fn call(operation: &std::ffi::CStr, request: &Value) -> Value {
    let bytes = serde_json::to_vec(request).unwrap();
    let (code, answer) = raw(operation, &bytes);
    assert_eq!(code, OK, "{operation:?} refused {request}");
    answer
}

fn vectors() -> Value {
    let vectors: Value = serde_json::from_str(VECTORS).unwrap();
    assert_eq!(vectors["v"], 1);
    vectors
}

#[test]
fn the_no_activate_guard_answers_what_the_swift_guard_did() {
    let vectors = vectors();
    let cases = vectors["noActivate"].as_array().unwrap();
    assert!(cases.len() >= 50);
    let mut asked = 0;
    for (number, case) in cases.iter().enumerate() {
        let mut guardian = json!({"previousAppPid": case["previousAppPid"]});
        for (step_number, step) in case["steps"].as_array().unwrap().iter().enumerate() {
            let answer = call(
                c"focus_ui_no_activate",
                &json!({"guard": guardian, "host": step["host"], "event": step["event"]}),
            );
            let at = format!("case {number} step {step_number}: {}", step["event"]);
            assert_eq!(answer["effects"], step["effects"], "{at}");
            assert_eq!(answer["sequence"], step["sequence"], "{at}");
            assert_eq!(answer["accepted"], step["accepted"], "{at}");
            assert_eq!(answer["guard"]["totalGiveBacks"], step["giveBackCount"], "{at}");
            guardian = answer["guard"].clone();
            asked += 1;
        }
    }
    assert!(asked >= 1000, "only {asked} guard steps");
}

#[test]
fn the_hint_hold_answers_what_the_swift_policy_did() {
    let vectors = vectors();
    let cases = vectors["modifierPolicy"].as_array().unwrap();
    assert!(cases.len() >= 50);
    let mut asked = 0;
    for (number, steps) in cases.iter().enumerate() {
        let mut policy = json!({});
        for step in steps.as_array().unwrap() {
            if let Some(key_down) = step.get("keyDown") {
                let answer = call(
                    c"focus_ui_hint_policy",
                    &json!({"policy": policy, "event": {"kind": "keyDown", "keepsHints": key_down["keepsHints"]}}),
                );
                policy = answer["policy"].clone();
                continue;
            }
            let update = &step["update"];
            let answer = call(
                c"focus_ui_hint_policy",
                &json!({"policy": policy, "event": {"kind": "update", "flags": update["flags"],
                        "eligible": update["eligible"], "elapsedNs": update["elapsedNs"]}}),
            );
            assert_eq!(answer["shows"], step["shows"], "case {number}: {update}");
            assert_eq!(answer["armed"], step["armed"], "case {number}: {update}");
            policy = answer["policy"].clone();
            asked += 1;
        }
    }
    assert!(asked >= 300, "only {asked} updates");
}

#[test]
fn the_pane_hint_chips_are_what_the_swift_plan_drew() {
    let vectors = vectors();
    let cases = vectors["paneHints"].as_array().unwrap();
    assert!(cases.len() >= 100);
    for (number, case) in cases.iter().enumerate() {
        let answer = call(c"focus_ui_pane_hints", case);
        assert_eq!(answer["chips"], case["chips"], "plan {number}");
    }
}

#[test]
fn the_keyboard_guards_decide_what_the_swift_guards_did() {
    let vectors = vectors();
    let moves = vectors["responderMove"].as_array().unwrap();
    assert!(moves.len() >= 100);
    for (number, facts) in moves.iter().enumerate() {
        let answer = call(c"focus_ui_responder_move", facts);
        assert_eq!(answer["unseen"], facts["unseen"], "move {number}");
        assert_eq!(answer["takesFromTyping"], facts["takesFromTyping"], "move {number}");
    }
    let keys = vectors["crossWindow"].as_array().unwrap();
    assert!(keys.len() >= 100);
    for (number, facts) in keys.iter().enumerate() {
        let answer = call(c"focus_ui_cross_window", facts);
        assert_eq!(answer["drops"], facts["drops"], "key {number}");
    }
}

#[test]
fn a_request_without_its_event_or_state_is_refused() {
    let host = json!({"isAppActive": true, "nowNs": 1});
    for request in [
        json!({"guard": {}, "host": host}),
        json!({"host": host, "event": {"kind": "start"}}),
        json!({"guard": {}, "host": host, "event": {"kind": "settleWait"}}),
    ] {
        let bytes = serde_json::to_vec(&request).unwrap();
        assert_eq!(raw(c"focus_ui_no_activate", &bytes).0, ERR_INVALID, "{request}");
    }
    let bytes = serde_json::to_vec(&json!({"policy": {}})).unwrap();
    assert_eq!(raw(c"focus_ui_hint_policy", &bytes).0, ERR_INVALID);
    assert_eq!(raw(c"focus_ui_unknown", b"{}").0, ERR_INVALID);
}
