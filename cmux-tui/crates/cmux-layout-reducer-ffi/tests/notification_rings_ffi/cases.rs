//! `notification_rings_*` through the C ABI: the app sends its tab facts and
//! applies the answer (cmux-window-rules holds the rules and their cases).

use cmux_layout_reducer_ffi::{ERR_INVALID, OK, cmux_layout_reducer_json};
use serde_json::{Value, json};
use std::ffi::CStr;

fn call(operation: &CStr, request: &[u8]) -> (i32, Value) {
    let mut output = vec![0u8; 1 << 12];
    let mut len = 0usize;
    // SAFETY: every pointer is live for the call, with its length.
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
fn notification_rings_ring_sends_a_marks_generation_as_text() {
    let (code, body) = call_json(
        c"notification_rings_ring",
        &json!({"tab": {"markedUnread": true, "markedGeneration": 3}}),
    );
    assert_eq!(code, OK);
    assert_eq!(body, json!({"generation": ((1u64 << 63) | 3).to_string()}));
    let (code, body) = call_json(
        c"notification_rings_ring",
        &json!({"tab": {"hasUnread": true, "notification": 7}, "dismissed": 7}),
    );
    assert_eq!(code, OK);
    assert_eq!(body, json!({"generation": null}));
}

#[test]
fn notification_rings_reads_and_on_sight() {
    let tab = json!({"hasUnread": true, "notification": 1, "clearsSource": true, "viewed": true});
    let (code, body) = call_json(
        c"notification_rings_reads",
        &json!({"trigger": "focus", "tab": tab, "policy": {"clearsAgent": true}}),
    );
    assert_eq!(code, OK);
    assert_eq!(body, json!({"reads": true}));
    let held = json!({"hasUnread": true, "clearsSource": true, "viewed": true, "held": true});
    let (code, body) =
        call_json(c"notification_rings_reads", &json!({"onSight": true, "tab": held}));
    assert_eq!(code, OK);
    assert_eq!(body, json!({"reads": false}));
}

#[test]
fn notification_rings_marks_ring_unread_panes() {
    let (code, body) = call_json(
        c"notification_rings_marks",
        &json!({
            "local": true,
            "ringsTerminal": true,
            "panes": [
                {"pane": "a", "tab": {"hasUnread": true, "notification": 4}},
                {"pane": "b", "tab": {}},
                {"pane": "c", "tab": {"agentChat": true, "finished": 2, "quiet": true}},
            ],
            "policy": {"ringsChat": true},
        }),
    );
    assert_eq!(code, OK);
    assert_eq!(
        body,
        json!({"marks": [
            {"pane": "a", "generation": "4", "agentChat": false, "quiet": false, "color": "source"},
            {"pane": "c", "generation": "2", "agentChat": true, "quiet": true, "color": "agent"},
        ]})
    );
}

#[test]
fn notification_rings_interaction_plans_a_look() {
    let (code, body) = call_json(
        c"notification_rings_interaction",
        &json!({
            "trigger": "click",
            "local": true,
            "flashes": true,
            "tab": {"hasUnread": true, "clearsSource": true, "markedUnread": true},
        }),
    );
    assert_eq!(code, OK);
    assert_eq!(
        body,
        json!({
            "endsHold": true, "seesWorkspace": true, "readsTurn": false, "hidesAttention": false,
            "readsMark": true, "ack": "read", "entryRead": true,
        })
    );
    let (code, body) = call_json(
        c"notification_rings_interaction",
        &json!({"trigger": "open", "ownerCannotAck": true,
                "tab": {"hasUnread": true, "clearsSource": true}}),
    );
    assert_eq!(code, OK);
    assert_eq!(body["ack"], json!("refused"));
}

#[test]
fn notification_rings_dismiss_highlight_and_turn_ended() {
    let (code, body) = call_json(
        c"notification_rings_dismiss_highlight",
        &json!({"local": true, "flashesOnRead": true, "dismissed": 1,
                "tabs": [{"hasUnread": true, "notification": 3}, {}, {"attention": true}]}),
    );
    assert_eq!(code, OK);
    assert_eq!(body["through"], json!(3));
    assert_eq!(body["steps"].as_array().map(Vec::len), Some(2));
    assert_eq!(body["steps"][1]["index"], json!(2));
    assert_eq!(body["steps"][1]["hidesAttention"], json!(true));

    let (code, body) = call_json(
        c"notification_rings_turn_ended",
        &json!({"rings": true, "sincePulseMs": 100.0, "generation": 4, "viewed": [false, true]}),
    );
    assert_eq!(code, OK);
    assert_eq!(
        body,
        json!({"rings": [{"index": 0, "generation": 5, "quiet": true}], "generation": 5, "pulsed": false})
    );
}

#[test]
fn notification_rings_reply_arrival_and_mark_send() {
    let (code, body) = call_json(
        c"notification_rings_reply",
        &json!({"banner": "cmux-notification-9", "located": true, "pty": true,
                "marker": 9, "markerUnread": true}),
    );
    assert_eq!(code, OK);
    assert_eq!(body, json!({"allowed": true}));

    let (code, body) = call_json(
        c"notification_rings_arrival",
        &json!({"located": true, "terminalSource": true, "looksLikeAlert": true}),
    );
    assert_eq!(code, OK);
    assert_eq!(body, json!({"route": "holdForRecord"}));

    let (code, body) =
        call_json(c"notification_rings_program_seen", &json!({"clearsFocus": false}));
    assert_eq!(code, OK);
    assert_eq!(body, json!({"route": "keepSeen"}));

    let (code, body) = call_json(
        c"notification_rings_mark_send",
        &json!({"marked": false, "current": true, "throttled": true,
                "last": {"marked": false, "agoMs": 500.0}}),
    );
    assert_eq!(code, OK);
    assert_eq!(body, json!({"send": false}));
}

#[test]
fn notification_rings_entered_blinks_removed_panes() {
    let (code, body) = call_json(
        c"notification_rings_entered",
        &json!({"removed": ["a", "b"], "anyEntryReads": true,
                "panes": [{"pane": "a", "tabs": [{"entryRead": true}]},
                          {"pane": "b", "tabs": [{}]}]}),
    );
    assert_eq!(code, OK);
    assert_eq!(body, json!({"panes": ["a"]}));
}

#[test]
fn notification_rings_refuses_an_unknown_op_and_bad_json() {
    let (code, _) = call_json(c"notification_rings_nope", &json!({}));
    assert_eq!(code, ERR_INVALID);
    let (code, _) = call(c"notification_rings_marks", b"{");
    assert_eq!(code, ERR_INVALID);
}
