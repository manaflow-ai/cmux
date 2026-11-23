//! `owner.fork_run`'s three verbs against the fake: start, get and select on cmux-platform's
//! `/v1/workspaces/{workspace}/fork-runs` routes, the run each answers and each refusal's code.

use super::*;

const RUN: &str = r#"{"id":"fork_1","workspace":"ws_1","sourceMachine":"vm_abcdefghij0123456789","sourceSnapshot":"snap_1","clientKey":"k","state":"ready","children":[{"id":"c_claude","harness":"claude","state":"ready","machineId":"vm_aaaaaaaaaaaaaaaaaaaa"},{"id":"c_codex","harness":"codex","state":"failed","error":"no capacity"}],"version":4,"createdAt":1,"updatedAt":2}"#;

fn run_answer(selected: Value) -> Value {
    json!({
        "id": "fork_1", "state": "ready", "workspace": "ws_1", "sourceMachine": VM,
        "sourceSnapshot": "snap_1", "selectedChild": selected, "version": 4,
        "children": [
            { "id": "c_claude", "harness": "claude", "state": "ready", "machineId": "vm_aaaaaaaaaaaaaaaaaaaa", "error": null },
            { "id": "c_codex", "harness": "codex", "state": "failed", "machineId": null, "error": "no capacity" },
        ],
    })
}

#[test]
fn a_fork_run_starts_with_its_key_machine_and_harnesses_and_answers_the_run() {
    let (origin, seen) = fake(|_| ok(RUN));
    let args = json!({ "workspace": "ws_1", "clientKey": "k", "sourceMachine": VM, "session": "s1", "harnesses": ["claude", "codex"] });
    let answer = go(&request(&origin, Auth::Owner, "owner.fork_run", args)).unwrap();
    assert_eq!(answer, run_answer(Value::Null));
    let seen = seen.lock().unwrap();
    assert_eq!(seen[0].target(), "POST /v1/workspaces/ws_1/fork-runs");
    assert_eq!(
        seen[0].json(),
        json!({ "clientKey": "k", "sourceMachine": VM, "session": "s1", "harnesses": ["claude", "codex"] })
    );
    assert_eq!(seen[0].header("authorization").as_deref(), Some("Bearer access"));
    assert_eq!(seen[0].header("x-cmux-team").as_deref(), Some("team-1"));
}

#[test]
fn a_fork_run_reads_the_workers_ok_value_shape_too() {
    let (origin, _seen) = fake(|_| ok(&format!(r#"{{"ok":true,"value":{RUN}}}"#)));
    let args = json!({ "workspace": "ws_1", "verb": "get", "run": "fork_1" });
    let answer = go(&request(&origin, Auth::Owner, "owner.fork_run", args)).unwrap();
    assert_eq!(answer, run_answer(Value::Null));
}

#[test]
fn a_fork_runs_status_is_a_get_of_the_run() {
    let (origin, seen) = fake(|_| ok(RUN));
    let args = json!({ "workspace": "ws_1", "verb": "get", "run": "fork_1" });
    go(&request(&origin, Auth::Owner, "owner.fork_run", args)).unwrap();
    let seen = seen.lock().unwrap();
    assert_eq!(seen[0].target(), "GET /v1/workspaces/ws_1/fork-runs/fork_1");
    assert!(seen[0].body.is_empty());
}

#[test]
fn selecting_a_child_posts_its_id_and_answers_the_selected_run() {
    let selected = RUN.replace(r#""version":4"#, r#""selectedChild":"c_claude","version":4"#);
    let (origin, seen) = fake(move |_| ok(&selected));
    let args =
        json!({ "workspace": "ws_1", "verb": "select", "run": "fork_1", "childId": "c_claude" });
    let answer = go(&request(&origin, Auth::Owner, "owner.fork_run", args)).unwrap();
    assert_eq!(answer, run_answer(json!("c_claude")));
    let seen = seen.lock().unwrap();
    assert_eq!(seen[0].target(), "POST /v1/workspaces/ws_1/fork-runs/fork_1/select");
    assert_eq!(seen[0].json(), json!({ "childId": "c_claude" }));
}

#[test]
fn a_fork_run_refusal_keeps_the_platforms_code_in_either_shape() {
    let (origin, _seen) = fake(|s| {
        if s.line.contains("/select") {
            Some((409, r#"{"_tag":"ForkRunConflict","code":"fork_run.selection_conflict","message":"another child was selected"}"#.into()))
        } else {
            Some((503, r#"{"ok":false,"error":{"code":"fork_run.placement_unavailable","message":"fork run service is unavailable"}}"#.into()))
        }
    });
    let select =
        json!({ "workspace": "ws_1", "verb": "select", "run": "fork_1", "childId": "c_codex" });
    assert_eq!(
        go(&request(&origin, Auth::Owner, "owner.fork_run", select)),
        Err(Failure::http(
            409,
            Some("fork_run.selection_conflict".into()),
            Some("another child was selected".into())
        ))
    );
    let start = json!({ "workspace": "ws_1", "clientKey": "k", "sourceMachine": VM, "harnesses": ["claude"] });
    assert_eq!(
        go(&request(&origin, Auth::Owner, "owner.fork_run", start)),
        Err(Failure::http(
            503,
            Some("fork_run.placement_unavailable".into()),
            Some("fork run service is unavailable".into())
        ))
    );
}

#[test]
fn a_fork_run_id_that_is_no_id_or_an_unknown_verb_sends_nothing() {
    let (origin, seen) = fake(|_| ok(RUN));
    for (args, message) in [
        (json!({ "workspace": "ws_1", "verb": "get", "run": "../x" }), "not a fork run id"),
        (
            json!({ "workspace": "ws_1", "verb": "select", "run": "fork_1", "childId": "a/b" }),
            "not a fork child id",
        ),
        (
            json!({ "workspace": "ws_1", "verb": "delete", "run": "fork_1" }),
            "no fork run verb \"delete\"",
        ),
    ] {
        assert_eq!(
            go(&request(&origin, Auth::Owner, "owner.fork_run", args)),
            Err(Failure::Transport(message.into()))
        );
    }
    assert!(seen.lock().unwrap().is_empty());
}

#[test]
fn an_answer_that_is_no_run_is_a_decoding_failure() {
    let (origin, _seen) =
        fake(|_| ok(r#"{"id":"fork_1","state":"ready","children":[{"id":"c"}]}"#));
    let args = json!({ "workspace": "ws_1", "verb": "get", "run": "fork_1" });
    assert_eq!(
        go(&request(&origin, Auth::Owner, "owner.fork_run", args)),
        Err(Failure::Decoding("/v1/workspaces/ws_1/fork-runs/fork_1: not a fork run".into()))
    );
}
