//! Browser rules through the C ABI. The app asks where a link opens, how an engine event updates
//! a tab, and how URL filtering, agent navigation, downloads and password filling are decided.

use cmux_layout_reducer_ffi::{ERR_INVALID, OK, cmux_layout_reducer_json};
use serde_json::{Value, json};
use std::ffi::CString;

fn call(op: &str, request: &[u8]) -> (i32, Value) {
    let op = CString::new(op).unwrap();
    let mut output = vec![0u8; 1 << 12];
    let mut len = 0usize;
    // SAFETY: every pointer is live for the call, with its length.
    let code = unsafe {
        cmux_layout_reducer_json(
            request.as_ptr(),
            request.len(),
            op.as_ptr(),
            output.as_mut_ptr(),
            output.len(),
            &mut len,
        )
    };
    let body =
        if code == OK { serde_json::from_slice(&output[..len]).unwrap() } else { Value::Null };
    (code, body)
}

#[test]
fn browser_rules_window_decide_inserts_a_middle_click_as_a_background_tab() {
    let request = json!({
        "request": {"kind": 0, "disposition": 4, "sourceBrowser": 11,
                    "url": "https://example.com/", "userGesture": true, "profilePath": "/profile",
                    "persistentProfile": true},
        "candidates": [{"anchor": 7, "profilePath": "/profile", "holdsSource": true,
                        "lastShown": true, "visible": true}],
        "links": {"mapping": {"cmdClick": "linkPlacement"},
                  "click": {"gesture": "middle", "timestamp": 1.0}, "now": 1.0},
    });
    let (code, body) = call("browser_rules_window_decide", &serde_json::to_vec(&request).unwrap());
    assert_eq!(code, OK);
    assert_eq!(body, json!({"insert": {"anchor": 7, "disposition": "backgroundTab"}}));
}

#[test]
fn browser_rules_webkit_link_click_opens_cmd_click_where_links_go() {
    let request = json!({"command": true, "button": 0, "mapping": {"cmdClick": "linkPlacement"}});
    let (code, body) =
        call("browser_rules_webkit_link_click", &serde_json::to_vec(&request).unwrap());
    assert_eq!(code, OK);
    assert_eq!(body, json!({"open": {"_0": "linkPlacement"}}));
}

#[test]
fn browser_rules_tab_state_apply_ignores_a_superseded_loads_late_failure() {
    let (code, machine) = call("browser_rules_tab_state_new", b"{}");
    assert_eq!(code, OK);
    let request = json!({"machine": machine, "events": [
        {"started": {"_0": {"rawValue": 1}, "url": "https://a.example/"}},
        {"started": {"_0": {"rawValue": 2}, "url": "https://b.example/"}},
        {"failed": {"_0": {"rawValue": 1}, "_1": {"domain": "NSURLErrorDomain", "code": -1009,
                    "message": "offline", "failingURL": "https://a.example/"}}},
        {"committed": {"_0": {"rawValue": 2}}},
    ]});
    let (code, body) =
        call("browser_rules_tab_state_apply", &serde_json::to_vec(&request).unwrap());
    assert_eq!(code, OK);
    assert_eq!(body["changed"], true);
    let state = &body["machine"]["state"];
    assert_eq!(state["phase"], json!({"committed": {}}));
    assert_eq!(state["url"], "https://b.example/");
    assert_eq!(state["security"], json!({"secure": {}}));
    assert_eq!(state["activeNavigation"], json!({"rawValue": 2}));
}

#[test]
fn browser_rules_url_policies_answer_through_the_c_abi() {
    let request = json!({"blocklist": ["*"], "allowlist": ["example.com"],
                         "urls": ["https://docs.example.com/a", "https://other.org", "about:blank"]});
    let (code, body) =
        call("browser_rules_url_filter_blocks", &serde_json::to_vec(&request).unwrap());
    assert_eq!(code, OK);
    assert_eq!(body, json!([false, true, false]));

    let (code, body) =
        call("browser_rules_agent_url_refuses", br#"{"url": "chrome://password-manager"}"#);
    assert_eq!(code, OK);
    assert_eq!(body, json!(true));

    let (code, body) =
        call("browser_rules_download_decision", br#"{"isFirst": false, "setting": "ask"}"#);
    assert_eq!(code, OK);
    assert_eq!(body, json!({"ask": {}}));

    let (code, body) = call("browser_rules_password_fill_switch", br#"{"agentDriven": true}"#);
    assert_eq!(code, OK);
    assert_eq!(body, json!({"state": {"allowedByProfile": true, "switchedOff": true}, "value": 0}));
}

#[test]
fn browser_rules_refuse_a_request_that_is_not_their_json() {
    let (code, _) = call("browser_rules_link_action", br#"{"gesture": "wave"}"#);
    assert_eq!(code, ERR_INVALID);
}
