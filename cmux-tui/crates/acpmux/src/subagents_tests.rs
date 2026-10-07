//! Subagent attribution: native ACP subagent sessions (draft #1992) and
//! Codex's legacy collaboration calls become one tree, written into each
//! update's `_meta.acpmux`.

use crate::subagents::SubagentTree;
use serde_json::{Value, json};

fn update(session: &str, update: Value) -> Value {
    json!({"sessionId": session, "update": update})
}

fn mux(params: &Value) -> &Value {
    &params["_meta"]["acpmux"]
}

#[test]
fn a_child_sessions_updates_name_their_subagent() {
    let mut tree = SubagentTree::default();
    let mut spawned = update(
        "root",
        json!({"sessionUpdate": "subagent_spawned", "subagentSessionId": "c1", "name": "Branch A", "task": "Explore", "prompt": "look around", "capabilities": {}, "_meta": {"claude": {"toolUseId": "toolu_1"}}}),
    );
    assert_eq!(tree.annotate(&mut spawned), None);
    assert_eq!(
        mux(&spawned)["subagents"],
        json!([{"id": "c1", "parent": null, "name": "Branch A", "task": "Explore", "prompt": "look around", "state": "running", "toolCallId": "toolu_1"}])
    );

    let mut child = update(
        "c1",
        json!({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "hi"}}),
    );
    assert_eq!(tree.annotate(&mut child).as_deref(), Some("c1"));
    assert_eq!(mux(&child)["subagent"], "c1");
}

#[test]
fn a_childs_own_subagents_name_it_as_their_parent() {
    let mut tree = SubagentTree::default();
    tree.annotate(&mut update(
        "root",
        json!({"sessionUpdate": "subagent_spawned", "subagentSessionId": "c1", "name": "A", "task": "t", "capabilities": {}}),
    ));
    let mut nested = update(
        "c1",
        json!({"sessionUpdate": "subagent_spawned", "subagentSessionId": "c1.1", "name": "A1", "task": "t", "capabilities": {}}),
    );
    assert_eq!(tree.annotate(&mut nested).as_deref(), Some("c1"));
    assert_eq!(mux(&nested)["subagents"][0]["parent"], "c1");

    let mut grandchild = update("c1.1", json!({"sessionUpdate": "tool_call", "toolCallId": "x"}));
    assert_eq!(tree.annotate(&mut grandchild).as_deref(), Some("c1.1"));
}

#[test]
fn a_state_update_ends_its_subagent() {
    let mut tree = SubagentTree::default();
    tree.annotate(&mut update(
        "root",
        json!({"sessionUpdate": "subagent_spawned", "subagentSessionId": "c1", "name": "A", "task": "t", "capabilities": {}}),
    ));
    let mut done = update(
        "root",
        json!({"sessionUpdate": "subagent_state_update", "subagentSessionId": "c1", "state": "failed"}),
    );
    tree.annotate(&mut done);
    assert_eq!(mux(&done)["subagents"], json!([{"id": "c1", "parent": null, "state": "failed"}]));
}

#[test]
fn the_parents_own_updates_are_left_alone() {
    let mut tree = SubagentTree::default();
    let mut plain = update(
        "root",
        json!({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "hi"}}),
    );
    let before = plain.clone();
    assert_eq!(tree.annotate(&mut plain), None);
    assert_eq!(plain, before);
}

/// Codex without native subagent sessions reports its children only through
/// `spawnAgent` collaboration calls and subagent activity items.
#[test]
fn codex_collaboration_calls_spawn_and_end_subagents() {
    let mut tree = SubagentTree::default();
    let collab = |status: &str, states: Value| {
        update(
            "root",
            json!({
                "sessionUpdate": "tool_call",
                "toolCallId": "call-1",
                "kind": "other",
                "title": "spawnAgent",
                "status": status,
                "rawInput": {"prompt": "split the work", "senderThreadId": "root-thread", "receiverThreadIds": ["t1", "t2"], "agentsStates": states},
                "_meta": {"codex": {"collaboration": {"tool": "spawnAgent", "senderThreadId": "root-thread", "receiverThreadIds": ["t1", "t2"]}}}
            }),
        )
    };
    let mut started = collab(
        "in_progress",
        json!({"t1": {"status": "pendingInit"}, "t2": {"status": "running"}}),
    );
    tree.annotate(&mut started);
    assert_eq!(
        mux(&started)["subagents"],
        json!([
            {"id": "t1", "parent": null, "task": "split the work", "state": "running", "toolCallId": "call-1"},
            {"id": "t2", "parent": null, "task": "split the work", "state": "running", "toolCallId": "call-1"},
        ])
    );
    let mut ended =
        collab("completed", json!({"t1": {"status": "completed"}, "t2": {"status": "errored"}}));
    tree.annotate(&mut ended);
    let states: Vec<&Value> =
        mux(&ended)["subagents"].as_array().unwrap().iter().map(|e| &e["state"]).collect();
    assert_eq!(states, [&json!("completed"), &json!("failed")]);
}

#[test]
fn codex_subagent_activity_names_its_subagent() {
    let mut tree = SubagentTree::default();
    let activity = |kind: &str| {
        update(
            "root",
            json!({
                "sessionUpdate": "tool_call",
                "toolCallId": format!("act-{kind}"),
                "title": format!("{kind} subagent branch_a"),
                "rawInput": {"agentThreadId": "t3", "agentPath": "/root/branch_a", "activityKind": kind},
                "_meta": {"codex": {"subagent": {"threadId": "t3", "path": "/root/branch_a", "activity": kind}}}
            }),
        )
    };
    let mut started = activity("started");
    tree.annotate(&mut started);
    assert_eq!(
        mux(&started)["subagents"],
        json!([{"id": "t3", "parent": null, "name": "branch_a", "state": "running"}])
    );
    let mut stopped = activity("interrupted");
    tree.annotate(&mut stopped);
    assert_eq!(mux(&stopped)["subagents"][0]["state"], "cancelled");
}
