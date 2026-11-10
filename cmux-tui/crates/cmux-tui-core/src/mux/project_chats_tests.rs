//! The chat-index import rule: the same lists the app's Swift relay
//! (`ProjectsImport.batches`, removed with this move) sent as
//! `project.observe {source, entries, complete: true}`.

use serde_json::{Value, json};

use super::*;

fn seen(path: &str, last_used_ms: i64) -> Observation {
    Observation { path: path.to_owned(), last_used_ms }
}

fn answer(projects: Value) -> Value {
    json!({"ready": true, "enabled": true, "projects": projects})
}

#[test]
fn project_chats_groups_each_harness_sorted_by_harness_then_path() {
    let result = answer(json!([
        {"harness": "codex", "path": "/srv/b", "lastUsedMs": 7},
        {"harness": "claude-code", "path": "/srv/z", "lastUsedMs": 3},
        {"harness": "codex", "path": "/srv/a", "lastUsedMs": 9},
        {"harness": "claude-code", "path": "/srv/a", "lastUsedMs": 4},
    ]));
    assert_eq!(
        batches(&result, &Imported::new()),
        vec![
            ("claude-code".to_owned(), vec![seen("/srv/a", 4), seen("/srv/z", 3)]),
            ("codex".to_owned(), vec![seen("/srv/a", 9), seen("/srv/b", 7)]),
        ]
    );
}

#[test]
fn project_chats_imports_nothing_while_the_index_is_not_ready_off_or_unread() {
    let rows = json!([{"harness": "codex", "path": "/srv/a", "lastUsedMs": 1}]);
    let mut imported = Imported::new();
    imported.insert("codex".to_owned(), vec![seen("/srv/old", 1)]);
    for result in [
        json!({"ready": false, "enabled": true, "projects": rows}),
        json!({"ready": true, "enabled": false, "projects": rows}),
        // No `ready`: an older acpmux or a partial answer.
        json!({"enabled": true, "projects": rows}),
        // An error answer has no result.
        Value::Null,
    ] {
        assert_eq!(batches(&result, &imported), Vec::new(), "{result}");
    }
    // A missing `enabled` reads as on, as the relay read it.
    assert_eq!(
        batches(&json!({"ready": true, "projects": rows}), &Imported::new()),
        vec![("codex".to_owned(), vec![seen("/srv/a", 1)])]
    );
}

#[test]
fn project_chats_leaves_out_a_harness_whose_list_is_already_imported() {
    let result = answer(json!([
        {"harness": "claude-code", "path": "/srv/a", "lastUsedMs": 4},
        {"harness": "codex", "path": "/srv/b", "lastUsedMs": 7},
    ]));
    let mut imported = Imported::new();
    imported.insert("claude-code".to_owned(), vec![seen("/srv/a", 4)]);
    imported.insert("codex".to_owned(), vec![seen("/srv/b", 6)]);
    // A newer chat in a known folder is a change; the same list is not.
    assert_eq!(batches(&result, &imported), vec![("codex".to_owned(), vec![seen("/srv/b", 7)])]);
}

#[test]
fn project_chats_sends_an_empty_complete_list_for_a_harness_with_no_folder_left() {
    let result = answer(json!([{"harness": "codex", "path": "/srv/b", "lastUsedMs": 7}]));
    let mut imported = Imported::new();
    imported.insert("pi".to_owned(), vec![seen("/srv/p", 1)]);
    imported.insert("codex".to_owned(), vec![seen("/srv/b", 7)]);
    assert_eq!(batches(&result, &imported), vec![("pi".to_owned(), Vec::new())]);
    // Once that empty list is imported, it is not sent again.
    imported.insert("pi".to_owned(), Vec::new());
    assert_eq!(batches(&result, &imported), Vec::new());
}

#[test]
fn project_chats_skips_rows_without_a_harness_a_path_or_a_time() {
    let result = answer(json!([
        {"path": "/srv/a", "lastUsedMs": 1},
        {"harness": "codex", "lastUsedMs": 1},
        {"harness": "codex", "path": "/srv/a", "lastUsedMs": "1"},
        {"harness": "codex", "path": "/srv/a"},
        {"harness": "codex", "path": "/srv/ok", "lastUsedMs": 2},
        {"harness": "codex", "path": "/srv/float", "lastUsedMs": 3.9},
    ]));
    // Paths go to the store as acpmux wrote them: the reducer normalizes and
    // refuses them (rule 7), as it did for the relay's `project.observe`.
    assert_eq!(
        batches(&result, &Imported::new()),
        vec![("codex".to_owned(), vec![seen("/srv/float", 3), seen("/srv/ok", 2)])]
    );
}

#[test]
fn project_chats_reads_again_on_the_watch_answer_an_index_change_or_a_lag() {
    let watching =
        json!({"jsonrpc": "2.0", "id": WATCH_ID, "result": {"ready": true, "chats": []}});
    assert_eq!(signal(&watching, None), Signal::Changed);
    let refused = json!({"jsonrpc": "2.0", "id": WATCH_ID, "error": {"code": -32601}});
    assert_eq!(signal(&refused, None), Signal::Other);
    let initialized = json!({"jsonrpc": "2.0", "id": 1, "result": {}});
    assert_eq!(signal(&initialized, None), Signal::Other);
    for kind in ["upsert", "removed"] {
        let change = json!({"jsonrpc": "2.0", "method": "_acpmux/chat_changed",
            "params": {"kind": kind, "seq": 4, "key": "k"}});
        assert_eq!(signal(&change, None), Signal::Changed, "{kind}");
    }
    let activity = json!({"jsonrpc": "2.0", "method": "_acpmux/chat_changed",
        "params": {"kind": "activity", "key": "k"}});
    assert_eq!(signal(&activity, None), Signal::Other);
    for lag in [
        json!({"jsonrpc": "2.0", "method": "_acpmux/chats_lagged", "params": {}}),
        json!({"jsonrpc": "2.0", "method": "_acpmux/lagged", "params": {"reason": "slow"}}),
    ] {
        assert_eq!(signal(&lag, None), Signal::Changed, "{lag}");
    }
    let too_large = json!({"jsonrpc": "2.0", "method": "_acpmux/lagged",
        "params": {"reason": "message_too_large"}});
    assert_eq!(signal(&too_large, None), Signal::Other);
    let other = json!({"jsonrpc": "2.0", "method": "_acpmux/chats_window_changed", "params": {}});
    assert_eq!(signal(&other, None), Signal::Other);
}

#[test]
fn project_chats_takes_the_answer_to_the_read_in_flight_ok_or_failed() {
    let ok = json!({"jsonrpc": "2.0", "id": 5, "result": {"ready": true, "projects": []}});
    assert_eq!(signal(&ok, Some(5)), Signal::Projects);
    let failed = json!({"jsonrpc": "2.0", "id": 5, "error": {"code": -32603}});
    assert_eq!(signal(&failed, Some(5)), Signal::Projects);
    assert_eq!(signal(&ok, Some(6)), Signal::Other);
    assert_eq!(signal(&ok, None), Signal::Other);
}

#[test]
fn project_chats_folds_changes_during_a_read_into_one_more_read() {
    let mut reads = Reads { asked: None, again: false, next_id: WATCH_ID + 1 };
    let mut sent = Vec::new();
    for _ in 0..3 {
        reads.ask(&mut sent).unwrap();
    }
    let lines: Vec<Value> = String::from_utf8(sent.clone())
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    assert_eq!(lines.len(), 1, "one read in flight: {lines:?}");
    assert_eq!(lines[0]["method"], "_acpmux/chat_projects");
    assert_eq!(lines[0]["id"], WATCH_ID + 1);
    assert_eq!(reads.asked, Some(WATCH_ID + 1));
    assert!(reads.again);
}
