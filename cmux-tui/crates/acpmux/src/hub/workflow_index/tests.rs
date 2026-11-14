use super::*;

fn spawn(id: &str) -> Value {
    json!({"id": id, "parent": null, "name": "Workflow", "kind": "workflow", "state": "running"})
}

#[test]
fn a_workflow_is_listed_from_its_spawn_to_its_end() {
    let index = WorkflowIndex::default();
    index.observe("chat-1", &[spawn("acp-1/toolu_w")], 10);
    // A plain subagent is not a workflow.
    index.observe(
        "chat-1",
        &[json!({"id": "acp-1/toolu_a", "parent": null, "kind": "Explore"})],
        11,
    );
    index.observe(
            "chat-1",
            &[json!({"id": "acp-1/toolu_w", "state": "running", "name": "deep-review", "runId": "wf_4fe",
                "argsDigest": "a1", "agents": {"done": 3, "started": 5}, "tokens": 120000, "action": "Review: r1"})],
            20,
        );
    let listed = index.list(false);
    assert_eq!(listed.len(), 1, "{listed:?}");
    let row = &listed[0];
    assert_eq!(
        (row["sessionId"].clone(), row["subagentSessionId"].clone()),
        (json!("chat-1"), json!("acp-1/toolu_w"))
    );
    assert_eq!(
        (row["name"].clone(), row["runId"].clone(), row["state"].clone()),
        (json!("deep-review"), json!("wf_4fe"), json!("running"))
    );
    assert_eq!(row["agents"], json!({"done": 3, "started": 5}));
    assert_eq!((row["startedAt"].clone(), row["updatedAt"].clone()), (json!(10), json!(20)));

    index.observe(
        "chat-1",
        &[json!({"id": "acp-1/toolu_w", "state": "cancelled", "reason": "paused"})],
        30,
    );
    assert!(index.list(false).is_empty());
    let ended = index.list(true);
    assert_eq!(
        (ended[0]["state"].clone(), ended[0]["reason"].clone(), ended[0]["endedAt"].clone()),
        (json!("cancelled"), json!("paused"), json!(30))
    );
    index.forget(&HashSet::from(["chat-1".to_owned()]));
    assert!(index.list(true).is_empty());
}

/// Two running workflows of one name and the same args digest, in any chat, list each other.
#[test]
fn the_same_workflow_running_twice_is_a_duplicate() {
    let index = WorkflowIndex::default();
    let progress =
        |id: &str, digest: &str| json!({"id": id, "name": "session-review", "argsDigest": digest});
    index.observe("chat-1", &[spawn("a/w1"), progress("a/w1", "d7")], 1);
    index.observe("chat-2", &[spawn("b/w2"), progress("b/w2", "d7")], 2);
    index.observe("chat-2", &[spawn("b/w3"), progress("b/w3", "d8")], 3);
    let listed = index.list(false);
    let of = |id: &str| {
        listed.iter().find(|row| row["subagentSessionId"] == id).unwrap()["duplicateOf"].clone()
    };
    assert_eq!(
        (of("a/w1"), of("b/w2"), of("b/w3")),
        (json!(["b/w2"]), json!(["a/w1"]), Value::Null)
    );
    // A run with no args digest is never a duplicate, even of a same-named one.
    index.observe("chat-3", &[spawn("c/w4"), json!({"id": "c/w4", "name": "session-review"})], 5);
    index.observe("chat-3", &[spawn("c/w5"), json!({"id": "c/w5", "name": "session-review"})], 6);
    let listed = index.list(false);
    let of = |id: &str| {
        listed.iter().find(|row| row["subagentSessionId"] == id).unwrap()["duplicateOf"].clone()
    };
    assert_eq!((of("c/w4"), of("c/w5")), (Value::Null, Value::Null));
    // Once one ends, the other is no longer a duplicate.
    index.observe("chat-2", &[json!({"id": "b/w2", "state": "completed"})], 4);
    assert_eq!(
        index.list(false).iter().find(|row| row["subagentSessionId"] == "a/w1").unwrap()["duplicateOf"],
        Value::Null
    );
}

/// A chat's agent exited: its workflows ran in that process, so they end.
#[test]
fn a_chats_exit_ends_its_running_workflows() {
    let index = WorkflowIndex::default();
    index.observe("chat-1", &[spawn("a/w1")], 1);
    index.observe("chat-2", &[spawn("b/w2")], 2);
    index.end_session("chat-1", 3);
    let listed = index.list(false);
    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0]["subagentSessionId"], "b/w2");
    let ended = index.list(true);
    let gone = ended.iter().find(|row| row["subagentSessionId"] == "a/w1").unwrap();
    assert_eq!((gone["state"].clone(), gone["endedAt"].clone()), (json!("disconnected"), json!(3)));
}

#[test]
fn running_workflows_are_bounded_too() {
    let index = WorkflowIndex::default();
    for n in 0..(RUNNING_MAX as u64 + 3) {
        index.observe("chat", &[spawn(&format!("s/w{n}"))], n);
    }
    let listed = index.list(false);
    assert_eq!(listed.len(), RUNNING_MAX);
    assert!(listed.iter().all(|row| row["subagentSessionId"] != "s/w0"), "the quietest went");
}

#[test]
fn only_the_latest_ended_workflows_are_kept() {
    let index = WorkflowIndex::default();
    for n in 0..(2 * ENDED_KEPT as u64 + 1) {
        let id = format!("s/w{n}");
        index.observe("chat", &[spawn(&id), json!({"id": id, "state": "completed"})], n);
    }
    index.observe("chat", &[spawn("s/live")], 1000);
    let listed = index.list(true);
    assert_eq!(listed.len(), ENDED_KEPT + 1);
    assert_eq!(listed[0]["subagentSessionId"], "s/live", "running first");
    assert!(listed.iter().all(|row| row["subagentSessionId"] != "s/w0"), "the oldest went");
}
