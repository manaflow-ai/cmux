//! The placement handlers' ops (`handlers_placement_*`) through the C ABI:
//! the app's facts answer the route, and a request the ops do not know is refused.

use cmux_layout_reducer_ffi::{ERR_INVALID, OK, cmux_layout_reducer_json};
use serde_json::{Value, json};
use std::ffi::CString;

fn call(op: &str, request: &[u8]) -> (i32, Option<Value>) {
    let op = CString::new(op).expect("op");
    let mut output = vec![0u8; 4096];
    let mut len = 0usize;
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
        (code == OK).then(|| serde_json::from_slice(&output[..len]).expect("answer is JSON"));
    (code, body)
}

#[test]
fn an_agents_browser_in_a_split_is_made_marked_then_moved() {
    let (code, body) = call(
        "handlers_placement_new_at",
        br#"{"kind":"browser","op":"split","edge":"right","madeInPlace":true,"origin":"cli","frontendBrowserTabs":true}"#,
    );
    assert_eq!(code, OK);
    assert_eq!(
        body,
        Some(
            json!({"route":"open","create":null,"made":"browser","agentDriven":true,"place":{"move":"split","edge":"right"}})
        )
    );
}

#[test]
fn a_persons_terminal_split_is_its_own_create() {
    let (code, body) = call(
        "handlers_placement_new_at",
        br#"{"kind":"terminal","op":"split","edge":"bottom","madeInPlace":true,"origin":"user"}"#,
    );
    assert_eq!(code, OK);
    assert_eq!(body.expect("body")["create"], json!({"create":"terminalSplit","direction":"down"}));
}

#[test]
fn a_browser_off_a_tab_without_the_capability_is_refused() {
    let (_, body) = call(
        "handlers_placement_new_at",
        br#"{"kind":"browser","op":"window","madeInPlace":false}"#,
    );
    assert_eq!(body, Some(json!({"route":"needsFrontendBrowserTabs"})));
}

#[test]
fn the_gates_and_the_submenu_place() {
    let (_, body) =
        call("handlers_placement_new_at_gate", br#"{"kind":"terminal","place":"columnLeft"}"#);
    assert_eq!(body, Some(json!({"gate":"columnLeft","place":"columnLeft"})));
    let (_, body) = call("handlers_placement_new_at_gate", br#"{"kind":"browser"}"#);
    assert_eq!(body, Some(json!({"gate":null,"place":"right"})));
}

#[test]
fn the_dock_ops_answer() {
    let (_, body) = call(
        "handlers_placement_dock_ask",
        br#"{"action":"column.dockTop","settingMode":"overlay"}"#,
    );
    assert_eq!(body, Some(json!({"edge":"top","mode":"overlay"})));
    let (_, body) =
        call("handlers_placement_dock_failure", br#"{"refusal":"unchanged","undocking":true}"#);
    assert_eq!(body, Some(json!({"failure":"noTarget","reason":"columnNotDocked"})));
    let (code, _) = call("handlers_placement_dock_ask", br#"{"action":"column.undock"}"#);
    assert_eq!(code, ERR_INVALID);
}

#[test]
fn the_chat_ops_answer() {
    let (_, body) = call(
        "handlers_placement_beside_dock_open",
        br#"{"respawn":{"kind":"browser","url":"https://example.com"}}"#,
    );
    assert_eq!(body, Some(json!("openOnHome")));
    let (_, body) =
        call("handlers_placement_chat_route", br#"{"placement":"dockChat","respawn":true}"#);
    assert_eq!(body, Some(json!("here")));
    let (_, body) = call(
        "handlers_placement_new_chat_opening",
        br#"{"placed":true,"placement":"newDock","select":true}"#,
    );
    assert_eq!(
        body,
        Some(
            json!({"inDock":false,"focusDock":false,"select":false,"hidden":true,"splitRight":false,"docks":true})
        )
    );
    let (_, body) = call(
        "handlers_placement_lone_chat",
        br#"{"panes":1,"tabs":[{"agentSession":true},{"newTabPage":true}],"ignoringPages":true}"#,
    );
    assert_eq!(body, Some(json!({"lone":true})));
}

#[test]
fn an_unknown_op_or_request_is_refused() {
    assert_eq!(call("handlers_placement_nope", b"{}").0, ERR_INVALID);
    assert_eq!(call("handlers_placement_new_at", b"not json").0, ERR_INVALID);
}
