//! `window_*` through the C ABI: the app sends its facts and acts on the
//! answer (cmux-window-rules holds the rules and their cases).

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
fn close_toast_asks_an_idle_terminal() {
    let (code, body) = call_json(
        c"window_close_toast",
        &json!({"tabs": [{"kind": "browser", "url": "about:blank"}, {"kind": "pty"}]}),
    );
    assert_eq!(code, OK);
    assert_eq!(body, json!({"decision": "askTerminals", "terminals": [1]}));
}

#[test]
fn close_reads_then_warning_names_the_working_agent() {
    let (code, body) = call_json(
        c"window_close_reads",
        &json!({"tabs": [{"kind": "pty", "agentAtWork": true, "agent": "claude"}, {"kind": "pty"}],
                "warnTab": true, "warnAgent": true}),
    );
    assert_eq!(code, OK);
    assert_eq!(body, json!({"reads": {"agents": ["Claude"], "others": [1]}}));
    let (code, body) = call_json(
        c"window_close_warning",
        &json!({"agents": ["Claude"], "answers": [{"title": "zsh", "answered": true, "program": "vim"}],
                "unansweredAsks": true, "warnTab": true, "warnAgent": true}),
    );
    assert_eq!(code, OK);
    assert_eq!(body, json!({"warning": {"kind": "agent", "name": "Claude"}}));
}

#[test]
fn close_reads_nothing_with_both_warnings_off() {
    let (code, body) = call_json(c"window_close_reads", &json!({"tabs": [{"kind": "pty"}]}));
    assert_eq!(code, OK);
    assert_eq!(body, json!({"reads": null}));
}

#[test]
fn close_warning_names_a_terminal_that_gave_no_answer() {
    let (code, body) = call_json(
        c"window_close_warning",
        &json!({"answers": [{"title": "build", "answered": false}], "unansweredAsks": true, "warnTab": true}),
    );
    assert_eq!(code, OK);
    assert_eq!(
        body,
        json!({"warning": {"kind": "programs", "programs": [], "unanswered": ["build"]}})
    );
}

#[test]
fn unknown_window_ops_and_bad_json_are_refused() {
    assert_eq!(call(c"window_nope", b"{}").0, ERR_INVALID);
    assert_eq!(call(c"window_close_toast", b"not json").0, ERR_INVALID);
}

#[test]
fn tabs_new_tab_kind_gives_a_person_the_page() {
    let (code, body) = call_json(
        c"window_tabs_new_tab_kind",
        &json!({"selectedKind": "browser", "engine": "cef", "user": true, "followsSetting": true, "canHostAgent": true}),
    );
    assert_eq!(code, OK);
    assert_eq!(
        body,
        json!({"kind": {"kind": "page"}, "sameKind": {"kind": "browser", "engine": "cef"}})
    );
}

#[test]
fn tabs_browser_open_routes_a_chromium_page_to_chromium() {
    let (code, body) = call_json(
        c"window_tabs_browser_open",
        &json!({"hasText": true, "chromiumInternal": true,
                "chromium": {"url": "chrome://extensions/", "route": "chromium"}}),
    );
    assert_eq!(code, OK);
    assert_eq!(body, json!({"plan": "open", "url": "chrome://extensions/", "engine": "cef"}));
    let (_, body) = call_json(c"window_tabs_browser_open", &json!({"hasText": true}));
    assert_eq!(body, json!({"plan": "refuse", "reason": "invalidUrl"}));
}

#[test]
fn tabs_small_rules_answer_over_the_channel() {
    let (_, body) =
        call_json(c"window_tabs_reopen", &json!({"isBrowser": true, "target": "webkit"}));
    assert_eq!(body, json!({"decision": "same"}));
    let (_, body) =
        call_json(c"window_tabs_terminal_chat", &json!({"agent": "codex", "session": "s"}));
    assert_eq!(
        body,
        json!({"chat": {"route": "adopt", "harness": "codex", "session": "s"}, "harness": "codex"})
    );
    let (_, body) = call_json(c"window_tabs_duplicate", &json!({"tabs": [{"localPage": true}]}));
    assert_eq!(body, json!({"actions": null}));
    let (_, body) = call_json(c"window_tabs_by_number", &json!({"number": 9, "count": 4}));
    assert_eq!(body, json!({"index": 3}));
    let (_, body) = call_json(c"window_panes_by_number", &json!({"number": 5, "count": 4}));
    assert_eq!(body, json!({"index": null}));
    let (_, body) = call_json(c"window_tabs_move_to_split", &json!({"direction": "down"}));
    assert_eq!(body, json!({"decision": "split", "edge": "bottom"}));
    let (_, body) = call_json(c"window_tabs_group_collapse", &json!({"current": true}));
    assert_eq!(body, json!({"collapsed": false}));
    let (_, body) = call_json(c"window_tabs_restart", &json!({"pty": true}));
    assert_eq!(body, json!({"refusal": "tabNotDead"}));
    let (_, body) = call_json(c"window_tabs_icon_undo", &json!({"user": true, "previous": "a"}));
    assert_eq!(body, json!({"undo": "remove"}));
    let (_, body) = call_json(c"window_tabs_identifiers", &json!({"pane": "p", "surface": "t"}));
    assert_eq!(body, json!({"text": "pane_id=p\nsurface_id=t"}));
    let (_, body) = call_json(
        c"window_tabs_browser_placement",
        &json!({"scripted": true, "focusedHere": true}),
    );
    assert_eq!(body, json!({"background": true, "agentDriven": true}));
}

#[test]
fn panes_split_plans_a_left_split() {
    let (code, body) = call_json(
        c"window_panes_split",
        &json!({"direction": "left", "folders": {"inherited": "/w"}, "tool": "split"}),
    );
    assert_eq!(code, OK);
    assert_eq!(
        body,
        json!({"do": "split", "edge": "left", "horizontal": true, "daemonDirection": "right",
               "swapTowards": "right", "splitAction": "splitLeft", "cwd": "/w", "tabCwd": "/w"})
    );
    let (_, body) = call_json(
        c"window_panes_auto_direction",
        &json!({"width": 100.0, "height": 300.0, "roomRight": true}),
    );
    assert_eq!(body, json!({"preferred": "down", "fitting": "right"}));
    let (_, body) = call_json(c"window_panes_tab_bar", &json!({"pinnedDock": true}));
    assert_eq!(body, json!({"toggle": null, "newTab": "chiefPaneHasNoTabBar"}));
}

#[test]
fn panes_terminal_tables_answer_over_the_channel() {
    let (_, body) = call_json(c"window_panes_terminal_bindings", &json!({}));
    assert_eq!(body["bindings"][0], json!(["resetTerminal", "reset"]));
    let (_, body) =
        call_json(c"window_panes_clear_failure", &json!({"text": "timed out after 2s"}));
    assert_eq!(body, json!({"kind": "timed out"}));
    let (_, body) = call_json(c"window_panes_shell_quote", &json!({"text": "it's"}));
    assert_eq!(body, json!({"text": "'it'\\''s'"}));
    assert_eq!(call(c"window_tabs_nope", b"{}").0, ERR_INVALID);
    assert_eq!(call(c"window_panes_split", b"[").0, ERR_INVALID);
}
