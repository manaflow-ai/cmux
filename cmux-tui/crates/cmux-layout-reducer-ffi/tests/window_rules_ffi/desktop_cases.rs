//! `window_notifications_desktop_*` through the C ABI (cmux-window-rules
//! holds the rules and their cases).

use cmux_layout_reducer_ffi::{ERR_INVALID, OK, cmux_layout_reducer_json};
use serde_json::{Value, json};
use std::ffi::CStr;

fn call(operation: &CStr, request: &[u8]) -> (i32, Value) {
    let mut output = vec![0u8; 1 << 12];
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
    let body =
        if code == OK { serde_json::from_slice(&output[..len]).unwrap() } else { Value::Null };
    (code, body)
}

fn call_json(operation: &CStr, request: &Value) -> (i32, Value) {
    call(operation, &serde_json::to_vec(request).unwrap())
}

#[test]
fn desktop_launch_follows_the_environment() {
    let (code, body) = call_json(
        c"window_notifications_desktop_launch",
        &json!({ "environment": { "NX_REMOTE": "1" }, "automation": false }),
    );
    assert_eq!(code, OK);
    assert_eq!(
        body,
        json!({ "usesSystemCenter": true, "asksPermission": false, "startsWithoutDeliveredBanners": false })
    );
    let (_, body) = call_json(
        c"window_notifications_desktop_launch",
        &json!({ "environment": { "CMUX_NEXT_NATIVE_NOTIFICATIONS": "1" }, "automation": true }),
    );
    assert_eq!(body["startsWithoutDeliveredBanners"], true);
    let (_, body) =
        call_json(c"window_notifications_desktop_launch", &json!({ "automation": true }));
    assert_eq!(body["usesSystemCenter"], false);
}

#[test]
fn desktop_banner_and_response() {
    let (code, body) = call_json(
        c"window_notifications_desktop_banner",
        &json!({ "approval": true, "alwaysAllow": true }),
    );
    assert_eq!(code, OK);
    assert_eq!(
        body,
        json!({ "category": "cmux.notification.approval.always", "approval": true, "redacted": false })
    );
    let (_, body) = call_json(
        c"window_notifications_desktop_banner",
        &json!({ "approval": true, "incognito": true }),
    );
    assert_eq!(body["approval"], false);
    assert_eq!(body["redacted"], true);
    let (_, body) = call_json(
        c"window_notifications_desktop_response",
        &json!({ "action": "cmux.notification.approval.deny" }),
    );
    assert_eq!(
        body,
        json!({ "open": false, "reply": false, "approve": false, "always": false, "markRead": false })
    );
    let (_, body) = call_json(
        c"window_notifications_desktop_response",
        &json!({ "action": "x", "systemDefault": true }),
    );
    assert_eq!(body["open"], true);
    assert_eq!(body["approve"], Value::Null);
}

#[test]
fn desktop_attention_changes_tab_and_stale() {
    let (code, body) = call_json(
        c"window_notifications_desktop_attention_changes",
        &json!({ "previous": ["a", "b"], "current": ["b", "c"] }),
    );
    assert_eq!(code, OK);
    assert_eq!(body, json!({ "post": [1], "withdraw": ["cmux-attention.a"], "posts": [1] }));
    let (_, body) = call_json(
        c"window_notifications_desktop_attention_changes",
        &json!({ "previous": null, "current": ["b", "c"], "eligible": ["b"] }),
    );
    assert_eq!(body, json!({ "post": [], "withdraw": [], "posts": [0] }));
    let (_, body) = call_json(
        c"window_notifications_desktop_attention_tab",
        &json!({ "banner": "cmux-attention.tab_1" }),
    );
    assert_eq!(body, json!({ "tab": "tab_1" }));
    let (_, body) = call_json(
        c"window_notifications_desktop_attention_tab",
        &json!({ "banner": "cmux-notification-3" }),
    );
    assert_eq!(body, json!({ "tab": null }));
    let (_, body) = call_json(
        c"window_notifications_desktop_attention_stale",
        &json!({
            "retained": ["cmux-attention.old", "cmux-attention.new", "other"],
            "currentLaunch": ["cmux-attention.new"]
        }),
    );
    assert_eq!(body, json!({ "stale": ["cmux-attention.old"] }));
}

#[test]
fn desktop_burst_join_and_read() {
    let (code, first) = call_json(
        c"window_notifications_desktop_burst_join",
        &json!({ "notification": 5, "finishedTurn": true, "tab": "claude" }),
    );
    assert_eq!(code, OK);
    assert_eq!(first["digest"], Value::Null);
    let (_, second) = call_json(
        c"window_notifications_desktop_burst_join",
        &json!({ "burst": first["burst"], "notification": 7, "finishedTurn": true, "tab": "codex" }),
    );
    assert_eq!(second["digest"], json!({ "count": 2, "replacing": ["cmux-notification-5"] }));
    assert_eq!(
        second["burst"]["showing"],
        json!([{ "id": "cmux-notification-7", "tab": "codex" }])
    );
    let (_, reply) = call_json(
        c"window_notifications_desktop_burst_join",
        &json!({ "notification": 8, "finishedTurn": true, "reply": true, "tab": "x" }),
    );
    assert_eq!(reply, json!({ "burst": null, "digest": null }));
    let (_, read) = call_json(
        c"window_notifications_desktop_burst_read",
        &json!({ "burst": second["burst"], "tab": "codex" }),
    );
    assert_eq!(read["closes"], false);
    assert_eq!(read["burst"]["tabs"], json!(["claude"]));
}

#[test]
fn desktop_announce_kind_and_speaks() {
    let (code, body) = call_json(
        c"window_notifications_desktop_announce_kind",
        &json!({ "level": "warning", "source": "agent" }),
    );
    assert_eq!(code, OK);
    assert_eq!(body, json!({ "kind": "needsYou" }));
    let (_, body) = call_json(
        c"window_notifications_desktop_announce_kind",
        &json!({ "level": "info", "source": "terminal" }),
    );
    assert_eq!(body, json!({ "kind": null }));
    let (_, body) = call_json(
        c"window_notifications_desktop_announce_speaks",
        &json!({ "attention": true, "desktop": true, "bannersDenied": true, "appActive": true }),
    );
    assert_eq!(body, json!({ "speaks": true }));
    let (_, body) = call_json(
        c"window_notifications_desktop_announce_speaks",
        &json!({ "attention": true, "desktop": true, "appActive": true }),
    );
    assert_eq!(body, json!({ "speaks": false }));
}

#[test]
fn desktop_refuses_an_unknown_op_and_bad_json() {
    assert_eq!(call(c"window_notifications_desktop_nope", b"{}").0, ERR_INVALID);
    assert_eq!(call(c"window_notifications_desktop_banner", b"not json").0, ERR_INVALID);
    assert_eq!(call(c"window_notifications_desktop_attention_tab", b"{}").0, ERR_INVALID);
}
