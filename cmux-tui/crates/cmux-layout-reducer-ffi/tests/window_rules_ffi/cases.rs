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
fn notifications_plan_reads_the_oldest_and_opens_the_next() {
    let (code, body) = call_json(
        c"window_notifications_plan",
        &json!({"verb": "markOldestAndJumpNext", "unread": [{"createdAtMs": 9}, {}, {"createdAtMs": 4}]}),
    );
    assert_eq!(code, OK);
    assert_eq!(body, json!({"acknowledge": [1], "open": 2, "refusal": null}));
    let (_, body) = call_json(c"window_notifications_plan", &json!({"verb": "markAllRead"}));
    assert_eq!(body["refusal"], json!("noUnread"));
}

#[test]
fn notifications_last_prompt_mute_and_banners() {
    let (_, body) = call_json(c"window_notifications_last_prompt", &json!({"prompts": [3, 7, 5]}));
    assert_eq!(body, json!({"index": 1}));
    let (_, body) = call_json(c"window_notifications_last_prompt", &json!({}));
    assert_eq!(body, json!({"refusal": "noPrompt"}));
    let (_, body) =
        call_json(c"window_notifications_toggle_mute", &json!({"muted": ["b"], "key": "a"}));
    assert_eq!(body, json!({"muted": ["a", "b"]}));
    let (_, body) = call_json(c"window_notifications_toggle_banners", &json!({"desktop": "never"}));
    assert_eq!(body, json!({"desktop": "unlessFocused"}));
}

#[test]
fn history_actions_and_layout_undo() {
    let (code, body) = call_json(c"window_history_actions", &json!({}));
    assert_eq!(code, OK);
    assert_eq!(
        body["walks"][0],
        json!({"action": "focusHistoryBack", "direction": "back", "nowhere": "nothingBack"})
    );
    assert_eq!(body["pages"][1], json!({"action": "recentlyClosed", "page": "closed"}));
    let (_, body) = call_json(
        c"window_history_undo_reply",
        &json!({"confirmationRequired": true, "revision": 8}),
    );
    assert_eq!(body, json!({"pending": 8, "closesPanes": 1}));
}

#[test]
fn remote_machine_and_terminal_here() {
    let machines = json!([{"id": "m1", "names": ["Box"]}, {"id": "m2", "names": ["dev"]}]);
    let (_, body) =
        call_json(c"window_remote_machine", &json!({"target": "BOX", "machines": machines}));
    assert_eq!(body, json!({"index": 0}));
    let (_, body) = call_json(c"window_remote_machine", &json!({"machines": machines}));
    assert_eq!(body, json!({"refusal": "noMachine"}));
    let (_, body) =
        call_json(c"window_remote_machine", &json!({"target": "x", "machines": machines}));
    assert_eq!(body, json!({"refusal": "unknownMachine", "target": "x"}));
    let (_, body) = call_json(
        c"window_remote_terminal_here",
        &json!({"direction": "below", "sameMachine": true}),
    );
    assert_eq!(body, json!({"decision": "open", "split": "down"}));
    let (_, body) = call_json(c"window_remote_terminal_here", &json!({"sameMachine": true}));
    assert_eq!(body, json!({"decision": "newSurface"}));
}

#[test]
fn browser_fit_device_and_picture_in_picture() {
    let (_, body) = call_json(c"window_browser_fit", &json!({"fixed": "1280", "current": "1280"}));
    assert_eq!(body, json!({"decision": "set", "fit": null, "capability": "browserFit"}));
    let (_, body) = call_json(c"window_browser_fit_actions", &json!({}));
    assert_eq!(body["actions"][2], json!({"action": "browserFit", "fit": null}));
    let (_, body) = call_json(c"window_browser_menu_fits", &json!({"fit": true}));
    assert_eq!(body, json!({"fits": [{"action": "browserFitDesktop", "fit": "16:9"}]}));
    let (_, body) = call_json(c"window_browser_device", &json!({"device": "none"}));
    assert_eq!(body, json!({"decision": "emulate", "device": null, "orientation": null}));
    let (_, body) =
        call_json(c"window_browser_pip_page", &json!({"card": true, "shownVideo": true}));
    assert_eq!(body, json!({"decision": "shown"}));
    let (_, body) = call_json(
        c"window_browser_pip_row",
        &json!({"enabled": true, "target": "tab", "video": true, "floating": true}),
    );
    assert_eq!(body, json!({"hidden": false, "exit": true}));
}

#[test]
fn files_open_rules() {
    let (_, body) =
        call_json(c"window_files_open_markdown", &json!({"path": "a.md", "local": false}));
    assert_eq!(body, json!({"decision": "refused", "refusal": "pathNotAbsolute", "path": "a.md"}));
    let (_, body) = call_json(c"window_files_open_diff", &json!({"paneFolder": "/r"}));
    assert_eq!(body, json!({"decision": "folder", "folder": "/r", "focus": false}));
    let (_, body) = call_json(c"window_files_diff_failed", &json!({"local": true}));
    assert_eq!(body, json!({"failed": "pickerNeedsFocus"}));
    let (_, body) = call_json(
        c"window_files_editor_bindings",
        &json!({"actions": [{"action": "findNext"}, {"action": "editorRun", "runsEditorCommand": true}]}),
    );
    assert_eq!(body, json!({"bindings": [{"action": "editorRun", "needsText": true}]}));
    let (_, body) = call_json(
        c"window_files_vscode",
        &json!({"local": true, "installed": true, "terminal": true, "cwd": "/w"}),
    );
    assert_eq!(body, json!({"decision": "serve", "folder": "/w"}));
    let (_, body) = call_json(c"window_files_open_with", &json!({"byPerson": false}));
    assert_eq!(body, json!({"decision": "noSuchApp"}));
}

#[test]
fn appearance_verb_ring_style_and_keymap_toast() {
    let (_, body) = call_json(
        c"window_appearance_verb",
        &json!({"scope": "workspace", "property": "theme", "propertyLevels": ["workspace"], "set": true}),
    );
    assert_eq!(
        body,
        json!({"decision": "apply", "level": "workspace", "themeAction": "workspace.setTheme", "properties": []})
    );
    let (_, body) = call_json(c"window_appearance_verb", &json!({"scope": "app", "set": false}));
    assert_eq!(body, json!({"decision": "refused", "refusal": "badProperty"}));
    let (_, body) = call_json(
        c"window_appearance_focus_ring_style",
        &json!({"style": "glow", "wasEnabled": false}),
    );
    assert_eq!(
        body,
        json!({"edits": [{"path": ["focusRing", "style"], "value": "glow"}, {"path": ["focusRing", "enabled"], "value": true}]})
    );
    let (_, body) =
        call_json(c"window_appearance_keymap_toast", &json!({"preset": "tmux", "changed": []}));
    assert_eq!(body, json!({"lines": ["title", "noChanges"], "undo": false, "seconds": 6}));
}

#[test]
fn remote_connect_step_opens_recovery_for_the_current_attempt_only() {
    let (code, body) = call_json(
        c"window_remote_connect_step",
        &json!({"failureAttempt": 2, "currentAttempt": 2}),
    );
    assert_eq!(code, OK);
    assert_eq!(
        body,
        json!({"showWorkspace": false, "end": false, "openWindow": true, "recovery": true})
    );
    let (_, body) = call_json(
        c"window_remote_connect_step",
        &json!({"failureAttempt": 1, "currentAttempt": 2, "hasWindow": true}),
    );
    assert_eq!(body["recovery"], json!(false));
}
