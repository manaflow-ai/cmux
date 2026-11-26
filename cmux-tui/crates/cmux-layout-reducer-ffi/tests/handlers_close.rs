//! `handlers_close_*` through the C ABI: each op's request shape and answer, and malformed
//! requests refused.

use std::ffi::CStr;

use cmux_layout_reducer_ffi::{ERR_INVALID, OK, cmux_layout_reducer_json};
use serde_json::{Value, json};

fn call(operation: &CStr, request: &str) -> (i32, Option<Value>) {
    let mut output = vec![0u8; 4096];
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
        (code == OK).then(|| serde_json::from_slice(&output[..len]).expect("answer is JSON"));
    (code, body)
}

fn ok(operation: &CStr, request: &str) -> Value {
    let (code, body) = call(operation, request);
    assert_eq!(code, OK, "{operation:?} {request}");
    body.expect("an answer")
}

#[test]
fn hides_reads_the_parts() {
    let parts = r#"{"parts":[{"sameDaemon":true},{"sameDaemon":true,"emptied":true,"canShowPaneClose":true}]}"#;
    assert_eq!(ok(c"handlers_close_hides", parts), json!({"hides": true}));
    let asks = r#"{"parts":[{"sameDaemon":true}],"knownToAsk":true}"#;
    assert_eq!(ok(c"handlers_close_hides", asks), json!({"hides": false}));
    assert_eq!(ok(c"handlers_close_hides", "{}"), json!({"hides": false}));
}

#[test]
fn press_reads_the_event() {
    assert_eq!(
        ok(c"handlers_close_press", r#"{"event":"keyDown","isRepeat":true}"#),
        json!({"eventTime": true, "isKey": true, "isRepeat": true})
    );
    assert_eq!(
        ok(c"handlers_close_press", r#"{"event":"mouse","isRepeat":true}"#),
        json!({"eventTime": true, "isKey": false, "isRepeat": false})
    );
    assert_eq!(
        ok(c"handlers_close_press", r#"{"event":"flagsChanged"}"#),
        json!({"eventTime": false, "isKey": false, "isRepeat": false})
    );
}

#[test]
fn tab_prompt_builds_the_question() {
    let agent = r#"{"warning":{"kind":"agent","name":"codex"},"titles":["build"]}"#;
    assert_eq!(
        ok(c"handlers_close_tab_prompt", agent),
        json!({
            "title": {"kind": "one", "title": "build"},
            "body": [{"kind": "agentWorking", "agent": "codex"}],
            "suppresses": "agentSession"
        })
    );
    let programs = r#"{"warning":{"kind":"programs","programs":["top"],"unanswered":["sh","zsh"]},"titles":["a","b"]}"#;
    assert_eq!(
        ok(c"handlers_close_tab_prompt", programs),
        json!({
            "title": {"kind": "count", "count": 2},
            "body": [
                {"kind": "stillRunning", "joined": "top"},
                {"kind": "noAnswer", "joined": "sh, zsh"}
            ],
            "suppresses": "tab"
        })
    );
    assert_eq!(call(c"handlers_close_tab_prompt", r#"{"titles":["a"]}"#).0, ERR_INVALID);
    assert_eq!(
        call(c"handlers_close_tab_prompt", r#"{"warning":{"kind":"other"}}"#).0,
        ERR_INVALID
    );
}

#[test]
fn chat_route_reads_the_facts() {
    assert_eq!(
        ok(c"handlers_close_chat_route", r#"{"kind":"agent","user":true,"shown":true}"#),
        json!({"asTab": false, "column": true, "docks": true})
    );
    assert_eq!(
        ok(
            c"handlers_close_chat_route",
            r#"{"kind":"agent","user":true,"shown":true,"plusChatIsTab":true}"#
        ),
        json!({"asTab": true, "column": false, "docks": false})
    );
}

#[test]
fn reopen_step_reads_the_daemons_answer() {
    assert_eq!(
        ok(c"handlers_close_reopen_step", r#"{"decision":"reopen","hasTab":true}"#),
        json!({"kind": "reopen"})
    );
    assert_eq!(
        ok(
            c"handlers_close_reopen_step",
            r#"{"decision":"refuse","reason":"chromiumUnavailable","hasTab":true}"#
        ),
        json!({"kind": "refuse", "refusal": "chromiumUnavailable"})
    );
    assert_eq!(
        ok(c"handlers_close_reopen_step", "{}"),
        json!({"kind": "refuse", "refusal": "notABrowserTab"})
    );
}

#[test]
fn link_open_reads_the_target() {
    assert_eq!(
        ok(c"handlers_close_link_open", r#"{"target":{"kind":"pane","other":true}}"#),
        json!({"inTargetPane": true, "newColumnBeside": false})
    );
    assert_eq!(
        ok(c"handlers_close_link_open", r#"{"target":{"kind":"splitRight"}}"#),
        json!({"inTargetPane": false, "newColumnBeside": true})
    );
    assert_eq!(call(c"handlers_close_link_open", "{}").0, ERR_INVALID);
}

#[test]
fn restart_and_history_steps() {
    assert_eq!(ok(c"handlers_close_restart_step", r#"{"answered":true}"#), json!("restart"));
    assert_eq!(
        ok(c"handlers_close_restart_step", r#"{"refusal":"notATerminal"}"#),
        json!("refuseNotATerminal")
    );
    assert_eq!(ok(c"handlers_close_restart_step", "{}"), json!("refuseTabNotDead"));
    assert_eq!(
        ok(c"handlers_close_history_opening", r#"{"lookup":"found","available":true}"#),
        json!("open")
    );
    assert_eq!(
        ok(c"handlers_close_history_opening", r#"{"lookup":"stillLoading"}"#),
        json!("stillLoading")
    );
    assert_eq!(ok(c"handlers_close_history_opening", r#"{"lookup":"found"}"#), json!("entryGone"));
}

#[test]
fn toast_ops() {
    assert_eq!(ok(c"handlers_close_recent_overflow", r#"{"count":10}"#), json!({"drop": 2}));
    assert_eq!(
        ok(c"handlers_close_toast_message", r#"{"tabs":2}"#),
        json!({"kind": "tabsClosed", "count": 2})
    );
    assert_eq!(
        ok(c"handlers_close_toast_message", r#"{"tabs":1,"title":"x"}"#),
        json!({"kind": "tabClosed", "title": "x"})
    );
    assert_eq!(ok(c"handlers_close_toast_message", r#"{"tabs":1}"#), json!({"kind": "untitled"}));
    assert_eq!(ok(c"handlers_close_one_group", r#"{"daemons":[1,1]}"#), json!({"oneGroup": true}));
    assert_eq!(ok(c"handlers_close_one_group", r#"{"daemons":[1,2]}"#), json!({"oneGroup": false}));
}

#[test]
fn workspace_close_ops() {
    assert_eq!(
        ok(
            c"handlers_close_bulk_run",
            r#"{"user":true,"count":2,"oneWindow":true,"survivor":true}"#
        ),
        json!("selection")
    );
    assert_eq!(ok(c"handlers_close_bulk_run", r#"{"refusesEmpty":true}"#), json!("nothingToClose"));
    assert_eq!(
        ok(c"handlers_close_group_offers_undo", r#"{"user":true,"names":1,"survivor":true}"#),
        json!({"offers": true})
    );
    assert_eq!(
        ok(c"handlers_close_selection_offers_undo", r#"{"names":1,"survivor":true}"#),
        json!({"offers": false})
    );
}

#[test]
fn fixed_prompt_names_the_question_and_return() {
    assert_eq!(
        ok(c"handlers_close_fixed_prompt", r#"{"id":"cloudKillMachine"}"#),
        json!({"prompt": "killMachine", "returnConfirms": true})
    );
    assert_eq!(
        ok(c"handlers_close_fixed_prompt", r#"{"id":"git.worktree.remove"}"#),
        json!({"prompt": "worktreeRemove", "returnConfirms": false})
    );
    assert_eq!(ok(c"handlers_close_fixed_prompt", r#"{"id":"closeTab"}"#), json!({"prompt": null}));
    assert_eq!(call(c"handlers_close_fixed_prompt", "{}").0, ERR_INVALID);
}

#[test]
fn closed_history_ops() {
    assert_eq!(ok(c"handlers_close_history_id", r#"{"id":"a"}"#), json!({"historyId": "daemon:a"}));
    assert_eq!(ok(c"handlers_close_daemon_id", r#"{"id":"daemon:a"}"#), json!({"daemonId": "a"}));
    assert_eq!(ok(c"handlers_close_daemon_id", r#"{"id":"web:a"}"#), json!({"daemonId": null}));
    assert_eq!(ok(c"handlers_close_record_window", r#"{"record":"i/w"}"#), json!({"window": "w"}));
    assert_eq!(ok(c"handlers_close_since_ms", r#"{"seconds":2.25}"#), json!({"sinceMs": 2250}));
    assert_eq!(ok(c"handlers_close_since_ms", r#"{"seconds":-1}"#), json!({"sinceMs": 0}));
    assert_eq!(
        ok(c"handlers_close_clears", r#"{"closedAtMs":5,"sinceMs":6}"#),
        json!({"clears": false})
    );
    assert_eq!(ok(c"handlers_close_clears", r#"{"closedAtMs":5}"#), json!({"clears": true}));
    assert_eq!(
        ok(c"handlers_close_reopen_failure", r#"{"kind":"workspace","code":"resource.not_found"}"#),
        json!("noRecentlyClosedWorkspace")
    );
    assert_eq!(ok(c"handlers_close_reopen_failure", r#"{"kind":"tab"}"#), json!("error"));
    assert_eq!(
        ok(c"handlers_close_delete_done", r#"{"code":"resource.not_found"}"#),
        json!({"done": true})
    );
    assert_eq!(ok(c"handlers_close_delete_done", "{}"), json!({"done": false}));
    assert_eq!(ok(c"handlers_close_reopen_show", r#"{"kind":"window"}"#), json!("window"));
    assert_eq!(
        ok(c"handlers_close_reopen_show", r#"{"kind":"tab","tabInPane":true}"#),
        json!("selectTab")
    );
    assert_eq!(
        ok(c"handlers_close_reopen_show", r#"{"kind":"workspace","grouped":true}"#),
        json!("nothing")
    );
}

#[test]
fn malformed_requests_and_unknown_ops_are_refused() {
    assert_eq!(call(c"handlers_close_hides", "not json").0, ERR_INVALID);
    assert_eq!(call(c"handlers_close_since_ms", r#"{"seconds":"x"}"#).0, ERR_INVALID);
    assert_eq!(call(c"handlers_close_nope", "{}").0, ERR_INVALID);
}
