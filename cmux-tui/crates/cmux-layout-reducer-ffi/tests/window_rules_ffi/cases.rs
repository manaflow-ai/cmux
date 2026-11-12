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
fn close_toast_skips_an_idle_terminal() {
    let (code, body) = call_json(
        c"window_close_toast",
        &json!({"tabs": [{"kind": "browser", "url": "about:blank"}, {"kind": "pty"}]}),
    );
    assert_eq!(code, OK);
    assert_eq!(body, json!({"decision": "skip"}));
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

#[test]
fn chat_agent_tables_list_the_page_commands_and_team_lines() {
    let (code, body) = call_json(c"window_chat_agent_tables", &json!({}));
    assert_eq!(code, OK);
    assert_eq!(
        body["pageCommands"][2],
        json!({"action": "agentPane.editInstructions", "command": "editProjectInstructions", "refusesRemote": true})
    );
    assert_eq!(body["teams"][1]["shellLine"], "codex -c features.multi_agent=true\n");
    assert_eq!(
        body["copyFiles"][0],
        json!({"action": "agentChat.copyTranscriptFile", "kinds": ["transcript"]})
    );
}

#[test]
fn chat_agent_zoom_clamps() {
    let (code, body) = call_json(
        c"window_chat_agent_zoom",
        &json!({"current": 1.95, "delta": 0.1, "lower": 0.5, "upper": 2.0}),
    );
    assert_eq!(code, OK);
    assert_eq!(body, json!({"zoom": 2.0, "percent": 200}));
}

#[test]
fn chat_agent_open_file_place_and_check() {
    let (code, body) =
        call_json(c"window_chat_agent_file_place", &json!({"path": "/a", "place": "editor"}));
    assert_eq!(code, OK);
    assert_eq!(body, json!({"decision": "open", "target": "editor", "paneless": true}));
    let (_, body) =
        call_json(c"window_chat_agent_file_place", &json!({"path": "/a", "place": "x"}));
    assert_eq!(body, json!({"decision": "invalidPlace", "place": "x"}));
    let (code, body) = call_json(
        c"window_chat_agent_file_check",
        &json!({"path": "/a", "target": "editor", "remote": true}),
    );
    assert_eq!(code, OK);
    assert_eq!(body, json!({"refusal": "remotePreview"}));
}

#[test]
fn chat_agent_routes_a_new_chat() {
    let (code, body) = call_json(c"window_chat_agent_pane_route", &json!({"topPage": true}));
    assert_eq!(code, OK);
    assert_eq!(body, json!({"route": "overTopPage"}));
    let (code, body) = call_json(
        c"window_chat_agent_host_plan",
        &json!({"route": {"kind": "peer", "peer": "blue"}, "ready": true, "activeLocal": false}),
    );
    assert_eq!(code, OK);
    assert_eq!(body, json!({"host": "blue", "open": {"kind": "localPlacement"}}));
    let (code, body) = call_json(
        c"window_chat_agent_targeted_route",
        &json!({"applies": true, "found": true, "shown": false}),
    );
    assert_eq!(code, OK);
    assert_eq!(body, json!({"route": "store", "selects": true}));
}

#[test]
fn chat_agent_places_the_memory_inspector() {
    let (code, body) = call_json(
        c"window_chat_agent_inspector_placement",
        &json!({"focused": 1, "inHome": true, "columns": [{"panes": [1], "dock": true}, {"panes": [2]}]}),
    );
    assert_eq!(code, OK);
    assert_eq!(body, json!({"placement": {"kind": "tab", "pane": 2}}));
    let (code, body) = call_json(
        c"window_chat_agent_inspector_anchor",
        &json!({"workspaces": [{"home": true, "hasPane": true}, {"hasPane": true}]}),
    );
    assert_eq!(code, OK);
    assert_eq!(body, json!({"kind": "workspace", "index": 1}));
}

#[test]
fn chat_agent_memory_routes_round_trip() {
    let (code, body) = call_json(c"window_chat_agent_memory_route", &json!({"chief": "01J"}));
    assert_eq!(code, OK);
    assert_eq!(body, json!({"route": "local:01J"}));
    let (code, body) =
        call_json(c"window_chat_agent_memory_place", &json!({"route": "server:mini"}));
    assert_eq!(code, OK);
    assert_eq!(body, json!({"place": {"kind": "server", "machineId": "mini"}}));
    let (_, body) = call_json(c"window_chat_agent_memory_place", &json!({"route": "cloud:x"}));
    assert_eq!(body, json!({"place": null}));
}

#[test]
fn chat_agent_model_catalog_and_session_placement() {
    let (code, body) = call_json(
        c"window_chat_agent_model_catalog",
        &json!({"harnesses": [{"harness": "local/claude", "models": [{"id": "opus", "name": "Opus"}]}]}),
    );
    assert_eq!(code, OK);
    assert_eq!(
        body["harnesses"][0],
        json!({"harness": "claude", "models": [{"value": "opus", "title": "Opus"}]})
    );
    let (code, body) = call_json(c"window_chat_agent_session_placement", &json!({"top": true}));
    assert_eq!(code, OK);
    assert_eq!(body, json!({"joinsGroup": false, "belowCaller": false, "defaultSlot": "top"}));
}

#[test]
fn chat_column_reads_a_lone_chat_that_docks() {
    let (code, body) = call_json(
        c"window_chat_column",
        &json!({"pane": "c", "columns": [{"panes": ["c"], "loneChat": true}], "recent": [], "zoomed": false}),
    );
    assert_eq!(code, OK);
    assert_eq!(body["placement"], json!({"placement": "dockChat"}));
    assert_eq!(body["newChat"], json!({"placement": "here"}));
    assert_eq!(body["pagePick"], Value::Null);
    assert_eq!(body["refusesMove"], json!(false));
}

#[test]
fn chat_column_sends_the_docks_new_tab_to_the_strip_and_refuses_a_tool() {
    let (code, body) = call_json(
        c"window_chat_column",
        &json!({"pane": "chat", "columns": [{"panes": ["chat"], "dock": {"role": "agentChat"}}, {"panes": ["page"]}],
                "moving": {"samePane": false, "chat": false}}),
    );
    assert_eq!(code, OK);
    assert_eq!(body["placement"], json!({"placement": "tab", "pane": "page"}));
    assert_eq!(body["newChat"], json!({"placement": "dock", "pane": "chat"}));
    assert_eq!(body["keepsNewTabPage"], json!(true));
    assert_eq!(body["pagePick"], json!("page"));
    assert_eq!(body["chatDock"], json!(true));
    assert_eq!(body["splitsDown"], json!(true));
    assert_eq!(body["refusesMove"], json!(true));
    assert_eq!(body["chatDockTop"], json!("chat"));
}

#[test]
fn chat_docked_open_focuses_the_chat_dock() {
    let (code, body) = call_json(
        c"window_chat_docked_open",
        &json!({"user": true, "canHost": true, "dockRoles": true, "shown": true, "pane": "t", "chatDockTop": "d"}),
    );
    assert_eq!(code, OK);
    assert_eq!(body, json!({"open": "focus", "pane": "d"}));
    let (_, body) = call_json(c"window_chat_docked_open", &json!({"pane": "t"}));
    assert_eq!(body, json!({"open": "notHandled"}));
}

#[test]
fn chat_drop_and_destinations() {
    let (code, body) =
        call_json(c"window_chat_drop", &json!({"intoChatDock": true, "chatDocks": [true, false]}));
    assert_eq!(code, OK);
    assert_eq!(body, json!({"split": "refusedChatDock", "pane": 1}));
    let workspaces = json!([{"id": "a", "key": "k", "panes": [{"id": "a1", "focusedAt": 1}, {"id": "a2", "focusedAt": 4}]}]);
    let (code, body) = call_json(
        c"window_chat_destination",
        &json!({"windows": [{"workspace": "a", "remembered": {"a": "a1"}}], "workspaces": workspaces}),
    );
    assert_eq!(code, OK);
    assert_eq!(body, json!({"destination": {"workspace": 0, "pane": "a1"}}));
    let (_, body) = call_json(c"window_chat_latest", &json!({"workspaces": workspaces}));
    assert_eq!(body, json!({"destination": {"workspace": 0, "pane": "a2"}}));
    let (_, body) = call_json(
        c"window_chat_target",
        &json!({"kind": "workspace", "id": "k", "workspaces": workspaces}),
    );
    assert_eq!(body, json!({"destination": {"workspace": 0, "pane": "a2"}}));
    let (_, body) = call_json(
        c"window_chat_cwd",
        &json!({"tabs": ["/a", null], "selected": 1, "agentFolder": null}),
    );
    assert_eq!(body, json!({"cwd": null}));
}

#[test]
fn columns_plan_and_availability() {
    let (code, body) = call_json(c"window_columns_actions", &json!({}));
    assert_eq!(code, OK);
    assert_eq!(body["canvas"][0], json!({"id": "canvasTidy", "arrangement": "tidy"}));
    let (code, body) = call_json(
        c"window_columns_plan",
        &json!({"action": "column.moveRight", "column": {"width": 0.5, "panes": ["p"]}, "right": ["r"], "handle": true}),
    );
    assert_eq!(code, OK);
    assert_eq!(body, json!({"plan": "swapPane", "side": "right", "pane": "p"}));
    let (_, body) = call_json(
        c"window_columns_plan",
        &json!({"action": "column.widthFull", "column": {"width": 1.0}}),
    );
    assert_eq!(
        body,
        json!({"plan": "refuse", "refusal": {"reason": "alreadyHasWidth"}, "quiet": true})
    );
    let (_, body) = call_json(
        c"window_columns_availability",
        &json!({"action": "column.moveLeft", "column": {"implicit": true}}),
    );
    assert_eq!(body, json!({"unavailable": "addSecondColumn"}));
    let (_, body) = call_json(c"window_columns_dock", &json!({"band": true, "dockColumns": true}));
    assert_eq!(body, json!({"needs": "edge-docks-v1"}));
    let (_, body) = call_json(
        c"window_columns_dock_move",
        &json!({"pane": "p", "paneTabs": 1, "columnPanes": ["p"], "hasTab": true, "edgeDocks": true, "tabColumnRespawn": true}),
    );
    assert_eq!(body, json!({"move": "move", "respawn": true, "anchor": "p"}));
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
        &json!({"scope": "workspace", "property": "theme", "set": true}),
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
