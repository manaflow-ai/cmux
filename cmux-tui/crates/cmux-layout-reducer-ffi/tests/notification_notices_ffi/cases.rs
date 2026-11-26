//! `notification_notices_*` through the C ABI: the app sends its facts and acts on the answer
//! (cmux-window-rules `notification_notices` holds the rules and their cases).

use cmux_layout_reducer_ffi::{ERR_INVALID, OK, cmux_layout_reducer_json};
use serde_json::{Value, json};
use std::ffi::CStr;

fn call_raw(operation: &CStr, request: &[u8]) -> (i32, Value) {
    let mut output = vec![0u8; 1 << 12];
    let mut len = 0usize;
    // SAFETY: the request, operation and output buffers outlive the call, sized as passed.
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
    let body =
        if code == OK { serde_json::from_slice(&output[..len]).unwrap() } else { Value::Null };
    (code, body)
}

fn call(operation: &CStr, request: &Value) -> Value {
    let (code, body) = call_raw(operation, &serde_json::to_vec(request).unwrap());
    assert_eq!(code, OK, "{operation:?}");
    body
}

#[test]
fn an_unknown_op_or_bad_request_is_invalid() {
    assert_eq!(call_raw(c"notification_notices_nope", b"{}").0, ERR_INVALID);
    assert_eq!(call_raw(c"notification_notices_banner", b"[").0, ERR_INVALID);
}

#[test]
fn sound_and_delivery() {
    assert_eq!(
        call(c"notification_notices_sound", &json!({"notice": "handoff", "outcome": "needsYou"})),
        json!({"soundEvent": "message"})
    );
    assert_eq!(
        call(c"notification_notices_sound", &json!({"notice": "attention"})),
        json!({"soundEvent": "needsInput"})
    );
    assert_eq!(
        call(
            c"notification_notices_goes_on",
            &json!({"acknowledge": false, "postingEnabled": true})
        ),
        json!({"goesOn": true})
    );
    assert_eq!(
        call(c"notification_notices_delivery", &json!({"desktop": true, "sound": "Glass"})),
        json!({"banner": true, "defaultSound": false, "play": true})
    );
    assert_eq!(
        call(c"notification_notices_delivery", &json!({"desktop": true, "sound": "default"})),
        json!({"banner": true, "defaultSound": true, "play": null})
    );
}

#[test]
fn banner_words() {
    assert_eq!(
        call(
            c"notification_notices_handoff_text",
            &json!({"outcome": "succeeded", "summary": "Fixed the flaky test", "task": "", "chat": "Flaky test"})
        ),
        json!({"title": "Flaky test", "state": "done", "detail": "Fixed the flaky test"})
    );
    assert_eq!(
        call(c"notification_notices_handoff_text", &json!({"outcome": "needsYou", "task": ""})),
        json!({"title": null, "state": "needsYou", "detail": null})
    );
    assert_eq!(
        call(
            c"notification_notices_sandbox_run_text",
            &json!({"task": "\n  Fix the flaky test  \nthen push", "outcome": "timedOut"})
        ),
        json!({"title": "Fix the flaky test", "body": "timedOut"})
    );
}

#[test]
fn banner_ids_and_clicks() {
    assert_eq!(
        call(c"notification_notices_banner", &json!({"banner": "sandbox-run.r1"})),
        json!({"banner": {"notice": "sandboxRun", "id": "r1"}})
    );
    assert_eq!(
        call(c"notification_notices_banner", &json!({"banner": "other"})),
        json!({"banner": null})
    );
    assert_eq!(
        call(c"notification_notices_handoff_open", &json!({"found": true, "hasHost": false})),
        json!({"open": "activate"})
    );
    assert_eq!(
        call(c"notification_notices_sandbox_run_open", &json!({"found": true, "stale": true})),
        json!({"open": "newWorkspace"})
    );
}

#[test]
fn attention_banners() {
    assert_eq!(
        call(
            c"notification_notices_attention_changes",
            &json!({"previous": ["a", "b"], "current": ["b", "c"]})
        ),
        json!({"post": [1], "withdraw": ["cmux-attention.a"]})
    );
    assert_eq!(
        call(
            c"notification_notices_attention_changes",
            &json!({"current": ["a"], "eligible": ["a"]})
        ),
        json!({"post": [0], "withdraw": []})
    );
    assert_eq!(
        call(
            c"notification_notices_attention_stale",
            &json!({"retained": ["cmux-attention.a", "handoff.h"], "currentLaunch": []})
        ),
        json!({"stale": ["cmux-attention.a"]})
    );
    assert_eq!(
        call(
            c"notification_notices_attention_show",
            &json!({"banner": "cmux-attention.a", "shared": true, "posted": true, "marked": ["a"]})
        ),
        json!({"show": "open", "tab": "a"})
    );
}

#[test]
fn tab_unread_mark() {
    assert_eq!(
        call(
            c"notification_notices_tab_unread_toggle",
            &json!({"showsUnread": true, "hasUnread": true, "attention": true})
        ),
        json!({"refuse": "tabAttentionRequestId", "steps": []})
    );
    assert_eq!(
        call(c"notification_notices_tab_unread_toggle", &json!({"markSupported": true})),
        json!({"refuse": null, "steps": ["mark"]})
    );
    assert_eq!(
        call(
            c"notification_notices_tab_unread_write",
            &json!({"write": "clearMark", "supported": false})
        ),
        json!({"step": "nothing"})
    );
    assert_eq!(
        call(
            c"notification_notices_tab_unread_write",
            &json!({"write": "mark", "supported": false})
        ),
        json!({"step": "refuse", "capability": "tabMarkUnread"})
    );
    assert_eq!(
        call(
            c"notification_notices_tab_unread_entered",
            &json!({"viewed": ["a", "b"], "previous": ["a"]})
        ),
        json!({"entered": ["b"]})
    );
}

#[test]
fn shown_tab_and_entry_blink() {
    assert_eq!(
        call(c"notification_notices_shown_tab", &json!({"count": 3, "defaultIndex": 9})),
        json!({"index": 2})
    );
    assert_eq!(
        call(c"notification_notices_shown_tab", &json!({"count": 0})),
        json!({"index": null})
    );
    assert_eq!(
        call(
            c"notification_notices_flashes_on_entry",
            &json!({"trigger": "keystroke", "flashesOnRead": true, "flashesOnTyping": false})
        ),
        json!({"flashes": false})
    );
}

#[test]
fn status_runs() {
    let busy = call(
        c"notification_notices_status_runs_finished",
        &json!({"statuses": [{"workspace": "w", "entries": [{"key": "run:1", "state": "busy"}]}]}),
    );
    assert_eq!(busy, json!({"finished": [], "running": [{"workspace": "w", "key": "run:1"}]}));
    assert_eq!(
        call(
            c"notification_notices_status_runs_finished",
            &json!({"running": busy["running"], "statuses": [{"workspace": "w", "entries": [{"key": "run:1", "state": "success"}]}]})
        ),
        json!({"finished": [{"status": 0, "entry": 0}], "running": []})
    );
    let visible =
        json!({"tabSelected": true, "paneOnScreen": true, "windowShown": true, "appActive": true});
    assert_eq!(
        call(
            c"notification_notices_status_run_notifies",
            &json!({"durationMs": 12000, "minimumSeconds": 10.0, "visibility": visible})
        ),
        json!({"notifies": false, "visible": true})
    );
}

#[test]
fn program_alerts() {
    assert_eq!(
        call(
            c"notification_notices_program_match",
            &json!({"title": "Claude needs approval", "body": "", "level": "warning", "records": [
                {"state": "blocked", "kind": "permission", "title": "Claude", "updatedSeq": 1}
            ]})
        ),
        json!({"match": {"record": 0, "reason": "permission"}})
    );
    assert_eq!(
        call(
            c"notification_notices_program_looks_like_alert",
            &json!({"title": "Build failed", "level": "error"})
        ),
        json!({"alert": true})
    );
    assert_eq!(
        call(c"notification_notices_program_notifies", &json!({"reason": "done"})),
        json!({"notifies": true})
    );
}
