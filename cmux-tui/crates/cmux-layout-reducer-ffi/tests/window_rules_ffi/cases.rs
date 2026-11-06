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
    let (code, body) = call_json(
        c"window_close_reads",
        &json!({"tabs": [{"kind": "pty"}], "warnTab": false, "warnAgent": false}),
    );
    assert_eq!(code, OK);
    assert_eq!(body, json!({"reads": null}));
}

#[test]
fn close_warning_names_a_terminal_that_gave_no_answer() {
    let (code, body) = call_json(
        c"window_close_warning",
        &json!({"answers": [{"title": "build", "answered": false}], "unansweredAsks": true, "warnTab": true, "warnAgent": false}),
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
fn close_ops_refuse_a_request_missing_a_warning_setting() {
    let tabs = json!([{"kind": "pty"}]);
    assert_eq!(call_json(c"window_close_reads", &json!({"tabs": tabs})).0, ERR_INVALID);
    assert_eq!(
        call_json(c"window_close_reads", &json!({"tabs": tabs, "warnTab": true})).0,
        ERR_INVALID
    );
    assert_eq!(
        call_json(c"window_close_warning", &json!({"answers": [], "warnAgent": true})).0,
        ERR_INVALID
    );
}

#[test]
fn target_ordinal_step_and_named_lookup() {
    let (code, body) =
        call_json(c"window_target_ordinal", &json!({"number": 9, "count": 4, "pastEnd": "refuse"}));
    assert_eq!((code, body), (OK, json!({"index": 3})));
    let (_, body) =
        call_json(c"window_target_ordinal", &json!({"number": 6, "count": 4, "pastEnd": "refuse"}));
    assert_eq!(body, json!({"index": null}));
    let (_, body) =
        call_json(c"window_target_step", &json!({"index": 0, "offset": -1, "count": 4}));
    assert_eq!(body, json!({"index": 3}));
    let (_, body) = call_json(
        c"window_target_named",
        &json!({"text": "Work", "folded": "work", "candidates": [{"id": "a", "folded": "home"}, {"id": "b", "folded": "work"}]}),
    );
    assert_eq!(body, json!({"index": 1}));
}

#[test]
fn target_explicit_tabs_and_refusals() {
    let (_, body) = call_json(
        c"window_target_explicit",
        &json!({"candidates": [{"kind": "window", "id": "w"}, null, {"kind": "tab", "id": "t"}], "kinds": ["tab"]}),
    );
    assert_eq!(body, json!({"index": 2}));
    let (_, body) = call_json(c"window_target_tab_ids", &json!({"list": " a, ,b "}));
    assert_eq!(body, json!({"ids": ["a", "b"]}));
    let (_, body) = call_json(c"window_target_one_pane", &json!({"panes": ["p", "q"]}));
    assert_eq!(body, json!({"refusal": "tabsInDifferentPanes"}));
    let (_, body) = call_json(c"window_target_refusal", &json!({"quiet": true}));
    assert_eq!(body, json!({"refusal": "quiet"}));
}

#[test]
fn workspace_bulk_close_plan_survivor_and_prompt() {
    let (_, body) =
        call_json(c"window_workspace_bulk_close", &json!({"id": "palette.closeWorkspacesAbove"}));
    assert_eq!(
        body,
        json!({"close": {"id": "palette.closeWorkspacesAbove", "plan": "aroundSelection", "nothingToClose": "noWorkspacesAbove", "byGroup": false}})
    );
    let (_, body) = call_json(c"window_workspace_bulk_close_ids", &json!({}));
    assert_eq!(body["ids"].as_array().map(Vec::len), Some(8));
    let (_, body) = call_json(
        c"window_workspace_survivor",
        &json!({"active": 0, "windows": [["a"], ["b", "c"]], "closing": ["a", "b"]}),
    );
    assert_eq!(body, json!({"window": 1}));
    let (_, body) =
        call_json(c"window_workspace_rows_window", &json!({"owners": ["w", null, "v"]}));
    assert_eq!(body, json!({"spans": true, "window": null}));
    let (_, body) = call_json(
        c"window_workspace_close_prompt",
        &json!({"count": 2, "programs": ["vim"], "askWithoutUndo": false}),
    );
    assert_eq!(
        body,
        json!({"prompt": {"title": {"kind": "count", "count": 2}, "body": {"kind": "running", "programs": ["vim"]}, "suppressesWarning": true}})
    );
}

#[test]
fn workspace_confirmation_and_space_questions() {
    let (_, body) =
        call_json(c"window_workspace_confirmation", &json!({"id": "space.delete", "stash": false}));
    assert_eq!(body, json!({"confirmation": "spaceDelete"}));
    let (_, body) = call_json(
        c"window_workspace_space_delete",
        &json!({"warn": true, "resolved": true, "programs": ["vim"]}),
    );
    assert_eq!(body, json!({"ask": "prompt", "programs": ["vim"]}));
    let (_, body) = call_json(
        c"window_workspace_space_clear_defaults",
        &json!({"resolved": true, "connected": true, "held": "notAsked"}),
    );
    assert_eq!(body, json!({"clear": "readDaemon"}));
    let (_, body) =
        call_json(c"window_workspace_space_defaults", &json!({"cwd": {"text": "/Users/me/src"}}));
    assert_eq!(
        body,
        json!({"patch": {"cwd": {"kind": "set", "path": "/Users/me/src"}, "env": null}})
    );
    let (_, body) = call_json(c"window_workspace_space_defaults", &json!({"env": {}}));
    assert_eq!(body, json!({"refusal": "defaultsMustBeText"}));
}

#[test]
fn workspace_notes_directory_and_groups() {
    let (_, body) =
        call_json(c"window_workspace_notes", &json!({"verb": "cycleStatus", "current": "review"}));
    assert_eq!(
        body,
        json!({"update": {"description": {"kind": "unchanged"}, "taskStatus": {"kind": "set", "value": "done"}, "capabilities": ["workspace-status-v1"]}})
    );
    let (_, body) =
        call_json(c"window_workspace_notes", &json!({"verb": "setStatus", "status": "x"}));
    assert_eq!(body["choices"][0], json!("auto"));
    let (_, body) = call_json(
        c"window_workspace_directory",
        &json!({"tabs": [{"id": "a", "cwd": "/a", "terminal": true}], "terminalsOnly": true}),
    );
    assert_eq!(body, json!({"cwd": "/a"}));
    let (_, body) = call_json(
        c"window_workspace_group_focus",
        &json!({"collapsed": true, "workspaces": [{"id": "w", "pending": false}]}),
    );
    assert_eq!(body, json!({"expands": true, "workspace": "w", "reopens": false}));
    let (_, body) = call_json(
        c"window_workspace_group_chain",
        &json!({"start": "a", "parents": {"a": "b", "b": null}}),
    );
    assert_eq!(body, json!({"chain": ["a", "b"]}));
}

#[test]
fn workspace_screen_closes_and_moves() {
    let (_, body) = call_json(
        c"window_workspace_screen_close",
        &json!({"verb": "others", "index": 0, "pinned": [false, true, false]}),
    );
    assert_eq!(body, json!({"close": [2]}));
    let (_, body) =
        call_json(c"window_workspace_screen_move", &json!({"index": 0, "offset": -1, "count": 2}));
    assert_eq!(body, json!({"index": null}));
    let (_, body) = call_json(
        c"window_workspace_screen_group_move",
        &json!({"group": "g", "forward": true, "screens": [{"group": "g"}, {}]}),
    );
    assert_eq!(body, json!({"index": 1}));
}

#[test]
fn closed_history_rows_and_cmd_shift_t() {
    let page = json!({"kind": "tab", "tabs": [{"kind": "browser", "url": "https://a.test"}], "machine": "m"});
    let (_, body) = call_json(
        c"window_close_history_once",
        &json!({"items": [page, {"kind": "screen"}, page]}),
    );
    assert_eq!(body, json!({"keep": [0, 1]}));
    let (_, body) =
        call_json(c"window_close_history_closes", &json!({"items": [page, page], "target": 1}));
    assert_eq!(body, json!({"closes": [0, 1]}));
    let (_, body) = call_json(
        c"window_close_history_newest",
        &json!({"entries": [{"kind": "tab", "workspaceWindow": "v"}, {"kind": "tab"}], "window": "w"}),
    );
    assert_eq!(body, json!({"index": 1}));
}

#[test]
fn close_undo_reducer_round_trips_its_state() {
    let (code, body) = call_json(
        c"window_close_undo_expect",
        &json!({"token": 4, "tabs": [{"id": "a", "index": 0}], "panes": ["p"], "costly": true}),
    );
    assert_eq!(code, OK);
    assert_eq!(body["announced"], json!({"outcome": "waiting", "dropped": []}));
    let (_, body) = call_json(
        c"window_close_undo_record",
        &json!({"state": body["state"], "items": [{"id": "i", "kind": "tab", "pane": "p", "tabs": 1}]}),
    );
    assert_eq!(
        body,
        json!({"state": {"expected": []}, "recorded": {"matched": [true], "settled": [{"token": 4, "items": ["i"], "tabs": 1, "shows": true}]}})
    );
    let (_, body) =
        call_json(c"window_close_undo_toast", &json!({"tabs": 1, "shown": 2, "allowed": false}));
    assert_eq!(body, json!({"show": "join", "tabs": 3}));
}
