use super::*;

#[test]
fn parent_ask_reads_absent_null_and_an_id() {
    assert_eq!(parent_ask(None).unwrap(), ParentAsk::Caller);
    assert_eq!(parent_ask(Some(&json!({}))).unwrap(), ParentAsk::Caller);
    assert_eq!(parent_ask(Some(&json!({"parent": null}))).unwrap(), ParentAsk::Root);
    assert_eq!(parent_ask(Some(&json!({"parent": "s1"}))).unwrap(), ParentAsk::Named("s1".into()));
    assert!(parent_ask(Some(&json!({"parent": 3}))).is_err());
    assert!(parent_ask(Some(&json!({"parent": ""}))).is_err());
}

#[test]
fn tool_call_id_is_bounded() {
    assert_eq!(
        tool_call_id(Some(&json!({"spawnToolCallId": "toolu_1"}))).unwrap().as_deref(),
        Some("toolu_1")
    );
    assert_eq!(tool_call_id(Some(&json!({"spawnToolCallId": ""}))).unwrap(), None);
    assert_eq!(tool_call_id(None).unwrap(), None);
    assert!(tool_call_id(Some(&json!({"spawnToolCallId": "x".repeat(257)}))).is_err());
    assert!(tool_call_id(Some(&json!({"spawnToolCallId": 7}))).is_err());
}

#[test]
fn a_running_start_session_call_names_the_child_it_asks_for() {
    let mut calls = StartCalls::new();
    let call = |id: &str, prompt: &str| {
        json!({"toolCallId": id, "status": "pending", "title": "start_session",
                   "_meta": {"claude": {"tool": "mcp__cmux-subsessions__start_session"}},
                   "rawInput": {"prompt": prompt}})
    };
    // Another tool is never kept.
    track(&mut calls, &json!({"toolCallId": "bash", "title": "ls", "status": "pending"}));
    assert_eq!(asking(&calls, "x"), None);
    track(&mut calls, &call("t1", "review"));
    // The only call running names a start even when its input is not known yet.
    assert_eq!(asking(&calls, "other").as_deref(), Some("t1"));
    track(&mut calls, &call("t2", "tests"));
    assert_eq!(asking(&calls, "tests").as_deref(), Some("t2"));
    assert_eq!(asking(&calls, "review").as_deref(), Some("t1"));
    // Two running calls and no prompt match: unknown, never a guess.
    assert_eq!(asking(&calls, "other"), None);
    track(&mut calls, &json!({"toolCallId": "t1", "status": "completed"}));
    track(&mut calls, &json!({"toolCallId": "t2", "status": "failed"}));
    assert!(calls.is_empty());
}

#[test]
fn a_lineage_round_trips_and_an_old_meta_has_none() {
    let old = json!({
        "schema": crate::store::META_SCHEMA, "id": "c", "name": "c", "harness": "fake",
        "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1,
    });
    let mut m: SessionMeta = serde_json::from_value(old).unwrap();
    assert_eq!(m.lineage, None);
    assert!(serde_json::to_value(&m).unwrap().get("lineage").is_none());
    m.lineage = Some(Lineage {
        parent: "p".into(),
        root: "r".into(),
        depth: 2,
        tool_call_id: Some("toolu_9".into()),
    });
    let saved = serde_json::to_value(&m).unwrap();
    assert_eq!(
        saved["lineage"],
        json!({"parent": "p", "root": "r", "depth": 2, "toolCallId": "toolu_9"})
    );
    let back: SessionMeta = serde_json::from_value(saved).unwrap();
    assert_eq!(back.lineage, m.lineage);
}
