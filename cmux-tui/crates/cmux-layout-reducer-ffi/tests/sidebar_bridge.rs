//! `sidebar_bridge` through the C ABI: the app's sidebar bridge asks one
//! decision rule per call and acts on the reply.

use cmux_layout_reducer_ffi::{ERR_INVALID, OK, cmux_layout_reducer_json};
use serde_json::{Value, json};

fn call(request: &[u8]) -> (i32, Value) {
    let mut output = vec![0u8; 1 << 12];
    let mut len = 0usize;
    let code = unsafe {
        cmux_layout_reducer_json(
            request.as_ptr(),
            request.len(),
            c"sidebar_bridge".as_ptr(),
            output.as_mut_ptr(),
            output.len(),
            &mut len,
        )
    };
    let body =
        if code == OK { serde_json::from_slice(&output[..len]).unwrap() } else { Value::Null };
    (code, body)
}

fn ask(request: Value) -> Value {
    let (code, body) = call(request.to_string().as_bytes());
    assert_eq!(code, OK, "{request}");
    body
}

#[test]
fn each_rule_answers_over_the_c_abi() {
    assert_eq!(
        ask(json!({"rule": "reorder_pins", "section": {"kind": "pinned"},
                   "workspaces": [{"pinned": true, "daemon": 1}, {"pinned": false, "daemon": 1}]})),
        json!({"kind": "pin", "workspaces": [1]})
    );
    assert_eq!(
        ask(json!({"rule": "pin_commands", "supports": [true, false]})),
        json!({"send": [0], "refused": true, "snap_back": false})
    );
    assert_eq!(ask(json!({"rule": "same_daemon", "owners": [4, null, 4]})), json!(4));
    assert_eq!(
        ask(json!({"rule": "new_workspace", "local_window": true, "window_daemon": true})),
        json!({"kind": "new_tab"})
    );
    assert_eq!(
        ask(
            json!({"rule": "new_workspace", "machine": true, "local_window": true, "window_daemon": true})
        ),
        json!({"kind": "create", "on": "machine"})
    );
    assert_eq!(
        ask(
            json!({"rule": "new_group", "by_user": true, "unnamed": true, "personal": true, "whole": true})
        ),
        json!({"edit_whole": true, "edit_new": false})
    );
    assert_eq!(ask(json!({"rule": "group_create_index", "requested": i64::MAX})), Value::Null);
    assert_eq!(
        ask(json!({"rule": "editor_item", "item": "sidebar.group.keep"})),
        json!({"keeps_group": true, "performs": false})
    );
    assert_eq!(
        ask(json!({"rule": "placement_commands", "steps": [{"moves": true, "index": 2}],
                   "group": "g", "state_personal": true, "regroup": ["h"], "first": 2})),
        json!({"moving": [0], "places": [{"step": 0, "group": {"kind": "set", "id": "g"}, "index": 2}],
               "regroups": [{"group": "h", "top_index": 2}]})
    );
    assert_eq!(
        ask(
            json!({"rule": "machine_status", "kind": "cloud", "connection": "failed", "live": true,
                   "compatibility": "incompatible", "startup_unavailable": true})
        ),
        json!({"status": "updateRequired", "compatibility_detail": true})
    );
    assert_eq!(
        ask(json!({"rule": "ssh_status", "link": "connected", "update_offered": true})),
        json!({"status": "updateAvailable", "compatibility_detail": false})
    );
    assert_eq!(
        ask(json!({"rule": "pane_use", "link": "offline", "reconnects_on_use": true})),
        json!("down")
    );
    assert_eq!(
        ask(json!({"rule": "row_link", "connected": false, "server_state": "paused"})),
        json!("paused")
    );
    assert_eq!(
        ask(json!({"rule": "notice_action", "card": "tip:t", "action": "try"})),
        json!({"kind": "tip", "tip": "t"})
    );
    assert_eq!(
        ask(json!({"rule": "dismiss_notice", "card": "announcement:a"})),
        json!({"kind": "announcement", "id": "a"})
    );
    assert_eq!(
        ask(json!({"rule": "app_activation", "app": "acme/notes"})),
        json!([{"action": "cmux.apps.open", "app_argument": true}, {"action": "app.open", "app_argument": true}])
    );
}

#[test]
fn an_unknown_rule_or_a_bad_value_is_invalid() {
    assert_eq!(call(br#"{"rule":"nope"}"#).0, ERR_INVALID);
    assert_eq!(call(br#"{"rule":"ssh_status","link":"sideways"}"#).0, ERR_INVALID);
}

/// acpmux's whole link state reaches the dot through the same op the app calls.
#[test]
fn a_link_rule_answers_over_the_op() {
    assert_eq!(
        ask(json!({"rule": "peer_link", "link": "restarting"})),
        json!({"link": "connecting", "reconnects_on_use": false})
    );
    assert_eq!(
        ask(json!({"rule": "joined_link", "hub": "online", "peer": "offline"})),
        json!({"link": "offline", "reconnects_on_use": true})
    );
    assert_eq!(
        ask(json!({"rule": "status_links"}))["disconnected"],
        json!({"link": "attention", "reconnects_on_use": true})
    );
}
