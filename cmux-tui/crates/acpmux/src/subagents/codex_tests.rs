use super::*;

fn subagents(tree: &mut SubagentTree, update: Value) -> Vec<Value> {
    subagents_for(tree, "s1", update)
}

fn subagents_for(tree: &mut SubagentTree, session_id: &str, update: Value) -> Vec<Value> {
    let mut params = json!({"sessionId": session_id, "update": update});
    tree.annotate(&mut params);
    params.pointer("/_meta/acpmux/subagents").and_then(Value::as_array).cloned().unwrap_or_default()
}

/// Leo's Codex chat (2026-10-22): its child `needs_you_review` reported
/// the chat's own thread as running, under the child's session. That is
/// not a spawn: the chat stays the root, its own updates stay its own, and
/// its next child sits beside the first rather than under the chat.
#[test]
fn a_child_reporting_its_parent_thread_never_makes_the_chat_a_subagent() {
    let chat = "01a1658b-c32f-72b1-ab04-d5444235a91c";
    let review = "01a16655-c696-7982-9c38-9ededd986f9b";
    let prior_art = "01a16656-bb2d-7513-b459-4a893451d37a";
    let mut tree = SubagentTree::default();
    tree.set_own(Some(chat));
    let mut annotate = |sid: &str, update: Value| {
        let mut params = json!({"sessionId": sid, "update": update});
        let owner = tree.annotate(&mut params);
        (owner, params.pointer("/_meta/acpmux").cloned())
    };
    annotate(
        chat,
        json!({"sessionUpdate": "subagent_spawned", "subagentSessionId": review,
                   "name": "needs_you_review", "task": "needs_you_review"}),
    );
    // The child names its parent thread.
    let (owner, mux) = annotate(
        review,
        json!({"sessionUpdate": "subagent_state_update", "subagentSessionId": chat, "state": "running"}),
    );
    assert_eq!(owner.as_deref(), Some(review));
    assert_eq!(mux, Some(json!({"subagent": review})), "the chat is not one of its subagents");
    // The chat's own words stay the chat's.
    let (owner, mux) = annotate(
        chat,
        json!({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "hi"}}),
    );
    assert_eq!((owner, mux), (None, None));
    // Its next child is a top-level subagent, not a grandchild under the chat.
    let (_, mux) = annotate(
        chat,
        json!({"sessionUpdate": "subagent_spawned", "subagentSessionId": prior_art,
                   "name": "needs_you_prior_art"}),
    );
    assert_eq!(mux.unwrap()["subagents"][0]["parent"], Value::Null);
    // A grandchild reporting on the subagent above it makes no loop either.
    let grandchild = "01a16657-46e1-79a0-a61e-d1a99a36d095";
    annotate(
        prior_art,
        json!({"sessionUpdate": "subagent_spawned", "subagentSessionId": grandchild, "name": "g"}),
    );
    let (_, mux) = annotate(
        grandchild,
        json!({"sessionUpdate": "subagent_state_update", "subagentSessionId": prior_art, "state": "running"}),
    );
    assert_eq!(mux, Some(json!({"subagent": grandchild})));
    assert!(!tree.owns(chat));
}

/// A failed Claude agent's entry says why and which agent a resume names.
#[test]
fn a_failed_subagent_carries_its_error_and_agent_id() {
    let mut tree = SubagentTree::default();
    subagents(
        &mut tree,
        json!({"sessionUpdate": "subagent_spawned", "subagentSessionId": "s1/t1", "name": "Push relay"}),
    );
    let end = subagents(
        &mut tree,
        json!({"sessionUpdate": "subagent_state_update", "subagentSessionId": "s1/t1", "state": "failed",
                   "agentId": "a8e1", "error": "API Error: 503"}),
    );
    assert_eq!(
        end,
        [
            json!({"id": "s1/t1", "parent": null, "state": "failed", "agentId": "a8e1", "error": "API Error: 503",
                    "name": "Push relay"})
        ]
    );
}

/// A subagent's later progress and end repeat the name and task its spawn gave, so a reader
/// whose page starts after the spawn names it by its description, never "Subagent" (Leo,
/// 2026-11-03, on "Subagent finished: Subagent" for a background agent an hour old).
#[test]
fn later_events_repeat_the_spawns_name_and_task() {
    let mut tree = SubagentTree::default();
    subagents(
        &mut tree,
        json!({"sessionUpdate": "subagent_spawned", "subagentSessionId": "s1/t1",
                   "name": "Watch CI", "task": "Watch CI", "prompt": "Wait for the run"}),
    );
    let progress = subagents(
        &mut tree,
        json!({"sessionUpdate": "subagent_progress", "subagentSessionId": "s1/t1", "agentId": "a6ab"}),
    );
    assert_eq!(progress[0]["name"], "Watch CI");
    assert_eq!(progress[0]["task"], "Watch CI");
    assert_eq!(progress[0]["agentId"], "a6ab");
    assert!(progress[0].get("prompt").is_none());
    let end = subagents(
        &mut tree,
        json!({"sessionUpdate": "subagent_state_update", "subagentSessionId": "s1/t1", "state": "completed"}),
    );
    assert_eq!(end[0]["name"], "Watch CI");
    assert_eq!(end[0]["task"], "Watch CI");
}

/// A subagent's completed or cancelled end, which its harness sends with no agent id, still
/// says the agentId an earlier event gave it, beside its name and task: a page holding only
/// that end names the agent (cmux#33292, cmux#33336).
#[test]
fn an_end_repeats_the_agent_id_an_earlier_event_gave() {
    for state in ["completed", "cancelled"] {
        let mut tree = SubagentTree::default();
        subagents(
            &mut tree,
            json!({"sessionUpdate": "subagent_spawned", "subagentSessionId": "s1/t1",
                       "name": "Watch CI", "task": "Watch CI"}),
        );
        subagents(
            &mut tree,
            json!({"sessionUpdate": "subagent_progress", "subagentSessionId": "s1/t1", "agentId": "a6ab"}),
        );
        let end = subagents(
            &mut tree,
            json!({"sessionUpdate": "subagent_state_update", "subagentSessionId": "s1/t1", "state": state}),
        );
        assert_eq!(end[0]["state"], state);
        assert_eq!(end[0]["name"], "Watch CI");
        assert_eq!(end[0]["task"], "Watch CI");
        assert_eq!(end[0]["agentId"], "a6ab", "{state}: {end:?}");
    }
    // One whose resume named it (a SendMessage) keeps that id for its later end too.
    let mut tree = SubagentTree::default();
    subagents(
        &mut tree,
        json!({"sessionUpdate": "subagent_spawned", "subagentSessionId": "s1/t2", "task": "Fix it"}),
    );
    subagents(
        &mut tree,
        json!({"sessionUpdate": "subagent_state_update", "subagentSessionId": "s1/t2", "state": "running", "agentId": "a8e1"}),
    );
    let end = subagents(
        &mut tree,
        json!({"sessionUpdate": "subagent_state_update", "subagentSessionId": "s1/t2", "state": "completed"}),
    );
    assert_eq!(end[0]["agentId"], "a8e1", "{end:?}");
    assert_eq!(end[0]["task"], "Fix it");
}

/// Codex runs a `spawnAgent` child in its own thread: it outlives the turn
/// that spawned it (the model may end its turn without a `wait`), so it is
/// background work, and a client never ends it at the turn's end.
#[test]
fn codex_spawned_agents_are_background() {
    let mut tree = SubagentTree::default();
    let spawn = subagents(
        &mut tree,
        json!({"sessionUpdate": "tool_call", "toolCallId": "c1",
                   "rawInput": {"prompt": "Audit", "agentsStates": {"t1": {"status": "running"}}},
                   "_meta": {"codex": {"collaboration": {"tool": "spawnAgent", "receiverThreadIds": ["t1"]}}}}),
    );
    assert_eq!(spawn.len(), 1);
    assert_eq!(spawn[0]["background"], json!(true));
    let activity = subagents(
        &mut tree,
        json!({"sessionUpdate": "tool_call_update", "toolCallId": "c2",
                   "_meta": {"codex": {"subagent": {"threadId": "t1", "path": "/root/auditor", "activity": "working"}}}}),
    );
    assert_eq!(activity[0]["state"], json!("running"));
    assert_eq!(activity[0]["background"], json!(true));
}

#[test]
fn claude_context_occupancy_is_not_reported_as_tokens() {
    let mut tree = SubagentTree::default();
    subagents(
        &mut tree,
        json!({"sessionUpdate": "subagent_spawned", "subagentSessionId": "claude-child"}),
    );
    let mut usage = json!({
        "sessionId": "claude-child",
        "update": {"sessionUpdate": "usage_update", "used": 100, "size": 200000}
    });
    tree.annotate(&mut usage);
    let completed = subagents(
        &mut tree,
        json!({
            "sessionUpdate": "subagent_state_update",
            "subagentSessionId": "claude-child",
            "state": "completed"
        }),
    );
    assert!(
        completed[0].get("tokens").is_none(),
        "context occupancy leaked as tokens: {completed:?}"
    );
}

#[test]
fn claude_context_updates_do_not_erase_a_real_token_total() {
    let mut tree = SubagentTree::default();
    subagents(
        &mut tree,
        json!({"sessionUpdate": "subagent_spawned", "subagentSessionId": "claude-child"}),
    );
    let mut total = json!({
        "sessionId": "claude-child",
        "update": {"sessionUpdate": "usage_update", "totalTokens": 42}
    });
    tree.annotate(&mut total);
    let mut context = json!({
        "sessionId": "claude-child",
        "update": {"sessionUpdate": "usage_update", "used": 100, "size": 200000}
    });
    tree.annotate(&mut context);
    let completed = subagents(
        &mut tree,
        json!({
            "sessionUpdate": "subagent_state_update",
            "subagentSessionId": "claude-child",
            "state": "completed"
        }),
    );
    assert_eq!(completed[0]["tokens"], 42);
}

#[test]
fn subagent_progress_tokens_take_precedence_over_cached_usage() {
    let mut tree = SubagentTree::default();
    subagents(
        &mut tree,
        json!({"sessionUpdate": "subagent_spawned", "subagentSessionId": "child"}),
    );
    let mut usage =
        json!({"sessionId": "child", "update": {"sessionUpdate": "usage_update", "used": 100}});
    tree.annotate(&mut usage);
    let events = subagents(
        &mut tree,
        json!({"sessionUpdate": "subagent_progress", "subagentSessionId": "child", "tokens": 200}),
    );
    assert_eq!(events[0]["tokens"], 200);
    let completed = subagents(
        &mut tree,
        json!({
            "sessionUpdate": "subagent_state_update",
            "subagentSessionId": "child",
            "state": "completed"
        }),
    );
    assert_eq!(completed[0]["tokens"], 200);
    let explicit = subagents(
        &mut tree,
        json!({
            "sessionUpdate": "subagent_state_update",
            "subagentSessionId": "child",
            "state": "completed",
            "tokens": 300,
            "lastMessage": "final answer"
        }),
    );
    assert_eq!(explicit[0]["tokens"], 300);
    assert_eq!(explicit[0]["lastMessage"], "final answer");
}

fn stream(tree: &mut SubagentTree, child: &str, message: &str, chunks: &[&str]) {
    for chunk in chunks {
        let mut params = json!({"sessionId": child, "update": {
                "sessionUpdate": "agent_message_chunk", "messageId": message,
                "content": {"type": "text", "text": chunk}}});
        tree.annotate(&mut params);
    }
}

fn end(tree: &mut SubagentTree, child: &str, state: &str) -> Value {
    subagents(
            tree,
            json!({"sessionUpdate": "subagent_state_update", "subagentSessionId": child, "state": state}),
        )
        .remove(0)
}

/// Leo, 2026-11-09: the "Subagent finished" card cut the reply inside a bold span. Its
/// completed end carries the whole reply as `result`; `lastMessage` stays the tray's capped one.
#[test]
fn a_completed_end_carries_the_whole_reply_as_result() {
    let mut tree = SubagentTree::default();
    subagents(&mut tree, json!({"sessionUpdate": "subagent_spawned", "subagentSessionId": "c"}));
    let head = "a".repeat(230);
    let chunks = [head.as_str(), "\n\nSee **the bold", " span here** and", " more after it."];
    stream(&mut tree, "c", "m1", &chunks);
    let whole = chunks.concat();
    assert!(whole.chars().count() > LAST_MESSAGE_CHARS);
    let done = end(&mut tree, "c", "completed");
    assert_eq!(done["lastMessage"].as_str().unwrap().chars().count(), LAST_MESSAGE_CHARS);
    assert!(done["lastMessage"].as_str().unwrap().ends_with('…'));
    assert_eq!(done["result"], json!(whole));
    let preview = &tree.previews["c"];
    assert!(preview.result.is_empty() && preview.result.capacity() == 0, "buffer not freed");
}

#[test]
fn a_short_reply_gets_result_and_only_the_last_message_counts() {
    let mut tree = SubagentTree::default();
    subagents(&mut tree, json!({"sessionUpdate": "subagent_spawned", "subagentSessionId": "c"}));
    stream(&mut tree, "c", "m1", &["Looking", " around"]);
    stream(&mut tree, "c", "m2", &["Done: ", "**3** files."]);
    let done = end(&mut tree, "c", "completed");
    assert_eq!(done["lastMessage"], "Done: **3** files.");
    assert_eq!(done["result"], "Done: **3** files.");
}

#[test]
fn a_failed_or_cancelled_end_carries_no_result() {
    for state in ["failed", "cancelled"] {
        let mut tree = SubagentTree::default();
        subagents(
            &mut tree,
            json!({"sessionUpdate": "subagent_spawned", "subagentSessionId": "c"}),
        );
        stream(&mut tree, "c", "m1", &["partial ", "work"]);
        let done = end(&mut tree, "c", state);
        assert_eq!(done["lastMessage"], "partial work");
        assert!(done.get("result").is_none(), "{state}: {done}");
        assert!(tree.previews["c"].result.is_empty());
    }
}

#[test]
fn an_overlong_reply_omits_result() {
    let mut tree = SubagentTree::default();
    subagents(&mut tree, json!({"sessionUpdate": "subagent_spawned", "subagentSessionId": "c"}));
    let big = "x".repeat(RESULT_CHARS);
    stream(&mut tree, "c", "m1", &[big.as_str(), "y"]);
    let done = end(&mut tree, "c", "completed");
    assert!(done.get("result").is_none());
    assert_eq!(done["lastMessage"].as_str().unwrap().chars().count(), LAST_MESSAGE_CHARS);
}

#[test]
fn an_explicit_last_message_is_the_result_unless_capped() {
    let mut tree = SubagentTree::default();
    stream(&mut tree, "c", "m1", &["streamed"]);
    let explicit = subagents(
        &mut tree,
        json!({"sessionUpdate": "subagent_state_update", "subagentSessionId": "c",
                   "state": "completed", "lastMessage": "final answer"}),
    );
    assert_eq!(explicit[0]["result"], "final answer");
    let capped = subagents(
        &mut tree,
        json!({"sessionUpdate": "subagent_state_update", "subagentSessionId": "c",
                   "state": "completed", "lastMessage": "z".repeat(300)}),
    );
    assert!(capped[0].get("result").is_none());
}

#[test]
fn native_and_codex_subagents_carry_orchestration_fields() {
    let mut tree = SubagentTree::default();
    let native = subagents(
        &mut tree,
        json!({"sessionUpdate": "subagent_spawned", "subagentSessionId": "claude/task",
                "model": "claude-opus", "effort": "high", "lastMessage": "é".repeat(300)}),
    );
    assert_eq!(native[0]["model"], "claude-opus");
    assert_eq!(native[0]["effort"], "high");
    assert_eq!(native[0]["lastMessage"].as_str().unwrap().chars().count(), 240);

    let codex = subagents(
        &mut tree,
        json!({"sessionUpdate": "tool_call_update",
                "_meta": {"codex": {"subagent": {"threadId": "codex/task",
                    "activity": "working", "model": "gpt-6", "effort": "xhigh",
                    "lastMessage": "Reviewing", "tokens": 1234}}}}),
    );
    assert_eq!(
        codex[0],
        json!({"id": "codex/task", "parent": null,
                "model": "gpt-6", "effort": "xhigh", "lastMessage": "Reviewing", "tokens": 1234,
                "state": "running", "background": true})
    );
}
/// A Codex root's native thread id may be echoed by a direct child as a legacy
/// activity item. It is the root that issued the call, never a child of that
/// direct child; later root spawns must remain siblings in the model.
#[test]
fn codex_root_thread_is_never_inserted_as_a_nested_subagent() {
    let mut tree = SubagentTree::default();
    let root = "root-native-thread";
    let review = "review-thread";
    let prior_art = "prior-art-thread";
    tree.set_root(root);

    let first = subagents_for(
        &mut tree,
        "acp-root",
        json!({"sessionUpdate": "tool_call", "toolCallId": "spawn-review",
                   "rawInput": {"prompt": "Review", "agentsStates": {}},
                   "_meta": {"codex": {"collaboration": {"tool": "spawnAgent",
                     "senderThreadId": root, "receiverThreadIds": [review]}}}}),
    );
    assert_eq!(first[0]["id"], review);
    assert_eq!(first[0]["parent"], Value::Null);

    // The child reports an activity item carrying the root's own native id.
    let echoed = subagents_for(
        &mut tree,
        review,
        json!({"sessionUpdate": "tool_call_update", "toolCallId": "echo-root",
                   "_meta": {"codex": {"subagent": {"threadId": root,
                     "path": "/root", "activity": "working"}}}}),
    );
    assert!(echoed.is_empty(), "root echo became a child: {echoed:?}");

    let second = subagents_for(
        &mut tree,
        root,
        json!({"sessionUpdate": "tool_call", "toolCallId": "spawn-prior-art",
                   "rawInput": {"prompt": "Prior art", "agentsStates": {}},
                   "_meta": {"codex": {"collaboration": {"tool": "spawnAgent",
                     "senderThreadId": root, "receiverThreadIds": [prior_art]}}}}),
    );
    assert_eq!(second[0]["id"], prior_art);
    assert_eq!(second[0]["parent"], Value::Null);
}

#[test]
fn codex_child_sender_remains_the_parent_of_a_grandchild() {
    let mut tree = SubagentTree::default();
    let child = "review-thread";
    let grandchild = "review-helper-thread";
    let first = subagents_for(
        &mut tree,
        "acp-root",
        json!({"sessionUpdate": "tool_call", "toolCallId": "spawn-review",
                   "rawInput": {"prompt": "Review", "agentsStates": {}},
                   "_meta": {"codex": {"collaboration": {"tool": "spawnAgent",
                     "senderThreadId": "root-native-thread", "receiverThreadIds": [child]}}}}),
    );
    assert_eq!(first[0]["parent"], Value::Null);
    let nested = subagents_for(
        &mut tree,
        child,
        json!({"sessionUpdate": "tool_call", "toolCallId": "spawn-helper",
                   "rawInput": {"prompt": "Helper", "agentsStates": {}},
                   "_meta": {"codex": {"collaboration": {"tool": "spawnAgent",
                     "senderThreadId": child, "receiverThreadIds": [grandchild]}}}}),
    );
    assert_eq!(nested[0]["id"], grandchild);
    assert_eq!(nested[0]["parent"], child);
}

#[test]
fn a_known_child_sender_wins_over_the_wrapper_session_id() {
    let mut tree = SubagentTree::default();
    let child = "review-thread";
    let helper = "review-helper-thread";
    let first = subagents_for(
        &mut tree,
        "acp-root",
        json!({"sessionUpdate": "tool_call", "toolCallId": "spawn-review",
                   "rawInput": {"prompt": "Review", "agentsStates": {}},
                   "_meta": {"codex": {"collaboration": {"tool": "spawnAgent",
                     "senderThreadId": "root-native-thread", "receiverThreadIds": [child]}}}}),
    );
    assert_eq!(first[0]["parent"], Value::Null);
    let nested = subagents_for(
        &mut tree,
        "acp-root",
        json!({"sessionUpdate": "tool_call", "toolCallId": "spawn-helper",
                   "rawInput": {"prompt": "Helper", "agentsStates": {}},
                   "_meta": {"codex": {"collaboration": {"tool": "spawnAgent",
                     "senderThreadId": child, "receiverThreadIds": [helper]}}}}),
    );
    assert_eq!(nested[0]["id"], helper);
    assert_eq!(nested[0]["parent"], child);
}

#[test]
fn a_known_root_sender_clears_a_wrong_parent_even_on_a_child_session_update() {
    let mut tree = SubagentTree::default();
    let root = "root-native-thread";
    let child = "review-thread";
    let prior_art = "prior-art-thread";
    tree.set_root(root);
    let _ = subagents_for(
        &mut tree,
        "acp-root",
        json!({"sessionUpdate": "tool_call", "toolCallId": "spawn-review",
                   "rawInput": {"prompt": "Review", "agentsStates": {}},
                   "_meta": {"codex": {"collaboration": {"tool": "spawnAgent",
                     "senderThreadId": root, "receiverThreadIds": [child]}}}}),
    );
    // Simulate a malformed persisted first record; the next authoritative
    // root call must normalize it to a direct child.
    let malformed = subagents_for(
        &mut tree,
        child,
        json!({"sessionUpdate": "tool_call", "toolCallId": "old-spawn",
                   "rawInput": {"prompt": "Prior art", "agentsStates": {}},
                   "_meta": {"codex": {"collaboration": {"tool": "spawnAgent",
                     "receiverThreadIds": [prior_art]}}}}),
    );
    assert_eq!(malformed[0]["parent"], child);
    let repaired = subagents_for(
        &mut tree,
        child,
        json!({"sessionUpdate": "tool_call_update", "toolCallId": "root-replay",
                   "rawInput": {"prompt": "Prior art", "agentsStates": {}},
                   "_meta": {"codex": {"collaboration": {"tool": "spawnAgent",
                     "senderThreadId": root, "receiverThreadIds": [prior_art]}}}}),
    );
    assert_eq!(repaired[0]["parent"], Value::Null);
}

#[test]
fn an_unseen_sender_does_not_fall_back_to_the_update_owner() {
    let mut tree = SubagentTree::default();
    let owner = "known-child";
    let _ = subagents_for(
        &mut tree,
        "acp-root",
        json!({"sessionUpdate": "subagent_spawned", "subagentSessionId": owner}),
    );
    let child = subagents_for(
        &mut tree,
        owner,
        json!({"sessionUpdate": "tool_call", "toolCallId": "unknown-sender",
                   "rawInput": {"prompt": "Unknown", "agentsStates": {}},
                   "_meta": {"codex": {"collaboration": {"tool": "spawnAgent",
                     "senderThreadId": "unseen-child", "receiverThreadIds": ["grandchild"]}}}}),
    );
    assert_eq!(child[0]["parent"], Value::Null);
}

#[test]
fn an_unseen_sender_keeps_the_childs_parent() {
    let mut tree = SubagentTree::default();
    let root = "root-native-thread";
    tree.set_root(root);
    let spawn = |tree: &mut SubagentTree, sender: &str, child: &str| {
        subagents_for(
            tree,
            "acp-root",
            json!({"sessionUpdate": "tool_call", "toolCallId": format!("spawn-{child}"),
                       "rawInput": {"prompt": "Work", "agentsStates": {}},
                       "_meta": {"codex": {"collaboration": {"tool": "spawnAgent",
                         "senderThreadId": sender, "receiverThreadIds": [child]}}}}),
        )
    };
    spawn(&mut tree, root, "child");
    spawn(&mut tree, "child", "grandchild");
    assert_eq!(tree.parents.get("grandchild"), Some(&Some("child".to_owned())));
    // A later update names a sender whose spawn is outside the retained history.
    let again = spawn(&mut tree, "outside-history", "grandchild");
    assert_eq!(again[0]["parent"], "child");
    assert_eq!(tree.parents.get("grandchild"), Some(&Some("child".to_owned())));
}

#[test]
fn a_grandchild_replayed_before_its_parent_is_reparented() {
    let mut tree = SubagentTree::default();
    let root = "root-native-thread";
    let child = "child-thread";
    let grandchild = "grandchild-thread";
    tree.set_root(root);

    let early = subagents_for(
        &mut tree,
        "acp-root",
        json!({"sessionUpdate": "tool_call", "toolCallId": "spawn-grandchild",
                   "rawInput": {"prompt": "Grandchild", "agentsStates": {}},
                   "_meta": {"codex": {"collaboration": {"tool": "spawnAgent",
                     "senderThreadId": child, "receiverThreadIds": [grandchild]}}}}),
    );
    assert_eq!(early[0]["parent"], Value::Null);

    let _ = subagents_for(
        &mut tree,
        "acp-root",
        json!({"sessionUpdate": "tool_call", "toolCallId": "spawn-child",
                   "rawInput": {"prompt": "Child", "agentsStates": {}},
                   "_meta": {"codex": {"collaboration": {"tool": "spawnAgent",
                     "senderThreadId": root, "receiverThreadIds": [child]}}}}),
    );
    assert_eq!(tree.parents.get(grandchild), Some(&Some(child.to_owned())));
}

#[test]
fn an_authoritative_parent_clears_a_stale_pending_sender() {
    let mut tree = SubagentTree::default();
    let root = "root-native-thread";
    let parent = "parent-thread";
    let child = "child-thread";
    let unseen = "unseen-sender";
    tree.set_root(root);
    let spawn = |tree: &mut SubagentTree, sender: &str, id: &str| {
        subagents_for(
            tree,
            "acp-root",
            json!({"sessionUpdate": "tool_call", "toolCallId": format!("spawn-{id}"),
                       "rawInput": {"prompt": "Work", "agentsStates": {}},
                       "_meta": {"codex": {"collaboration": {"tool": "spawnAgent",
                         "senderThreadId": sender, "receiverThreadIds": [id]}}}}),
        )
    };
    let _ = spawn(&mut tree, root, parent);
    let _ = spawn(&mut tree, unseen, child);
    let _ = spawn(&mut tree, root, child);
    let _ = spawn(&mut tree, root, unseen);

    assert_eq!(tree.parents.get(parent), Some(&None));
    assert_eq!(tree.parents.get(child), Some(&None));
    assert_eq!(tree.parents.get(unseen), Some(&None));
}

#[test]
fn learning_the_root_promotes_its_pending_children() {
    let mut tree = SubagentTree::default();
    let root = "root-native-thread";
    let child = "child-thread";
    tree.parents.insert(child.to_owned(), Some("stale-parent".to_owned()));
    tree.pending.entry(root.to_owned()).or_default().insert(child.to_owned());

    tree.set_root(root);

    assert_eq!(tree.parents.get(child), Some(&None));
    assert!(!tree.pending.contains_key(root));
}

/// A root echo that arrives before the root is known reads as a running
/// background child. Learning the root later must drop it from the
/// background set too: no end event ever comes for it, so it would keep the
/// session busy after the real child finishes.
#[test]
fn a_late_known_root_stops_counting_as_a_background_subagent() {
    let mut tree = SubagentTree::default();
    let root = "root-native-thread";
    let review = "review-thread";
    let echoed = subagents_for(
        &mut tree,
        "acp-root",
        json!({"sessionUpdate": "tool_call_update", "toolCallId": "echo-root",
                   "_meta": {"codex": {"subagent": {"threadId": root,
                     "path": "/root", "activity": "working"}}}}),
    );
    assert_eq!(echoed[0]["background"], json!(true));
    let _ = subagents_for(
        &mut tree,
        "acp-root",
        json!({"sessionUpdate": "tool_call", "toolCallId": "spawn-review",
                   "rawInput": {"prompt": "Review", "agentsStates": {}},
                   "_meta": {"codex": {"collaboration": {"tool": "spawnAgent",
                     "senderThreadId": root, "receiverThreadIds": [review]}}}}),
    );
    assert_eq!(tree.background_running(), 2);
    tree.set_root(root);
    let _ = subagents_for(
        &mut tree,
        "acp-root",
        json!({"sessionUpdate": "tool_call_update", "toolCallId": "review-done",
                   "_meta": {"codex": {"subagent": {"threadId": review,
                     "activity": "completed"}}}}),
    );
    assert_eq!(tree.background_running(), 0, "the root is not background work");
}

/// The tree lives as long as the hub session, but a harness restart or a new
/// Codex conversation gives the session a new native root id. The new root
/// must be treated as a root too, not as an ordinary subagent; an echo of it
/// recorded before the restart was known stops counting as background work.
#[test]
fn a_root_learned_after_a_restart_is_also_a_root() {
    let mut tree = SubagentTree::default();
    let first_root = "root-before-restart";
    let root = "root-after-restart";
    let review = "review-thread";
    let prior_art = "prior-art-thread";
    tree.set_root(first_root);

    // After the restart, the new root is echoed before the session metadata
    // names it, so it reads as running background work.
    let early = subagents_for(
        &mut tree,
        "acp-root",
        json!({"sessionUpdate": "tool_call_update", "toolCallId": "echo-early",
                   "_meta": {"codex": {"subagent": {"threadId": root,
                     "path": "/root", "activity": "working"}}}}),
    );
    assert_eq!(early[0]["background"], json!(true));
    tree.set_root(root);
    assert_eq!(tree.background_running(), 0, "the new root is not background work");

    let first = subagents_for(
        &mut tree,
        "acp-root",
        json!({"sessionUpdate": "tool_call", "toolCallId": "spawn-review",
                   "rawInput": {"prompt": "Review", "agentsStates": {}},
                   "_meta": {"codex": {"collaboration": {"tool": "spawnAgent",
                     "senderThreadId": root, "receiverThreadIds": [review]}}}}),
    );
    assert_eq!(first[0]["id"], review);
    assert_eq!(first[0]["parent"], Value::Null);

    let echoed = subagents_for(
        &mut tree,
        review,
        json!({"sessionUpdate": "tool_call_update", "toolCallId": "echo-root",
                   "_meta": {"codex": {"subagent": {"threadId": root,
                     "path": "/root", "activity": "working"}}}}),
    );
    assert!(echoed.is_empty(), "the new root's echo became a child: {echoed:?}");

    let second = subagents_for(
        &mut tree,
        root,
        json!({"sessionUpdate": "tool_call", "toolCallId": "spawn-prior-art",
                   "rawInput": {"prompt": "Prior art", "agentsStates": {}},
                   "_meta": {"codex": {"collaboration": {"tool": "spawnAgent",
                     "senderThreadId": root, "receiverThreadIds": [prior_art]}}}}),
    );
    assert_eq!(second[0]["id"], prior_art);
    assert_eq!(second[0]["parent"], Value::Null);
    assert!(!tree.owns(root), "the new root is not a subagent");
}

/// Leo's Session Info (2026-11-02) named most running subagents by their raw ids: a client
/// that read the chat from a page after a spawn met them through progress, which names none.
/// Every event carries the name the spawn gave, and a later name replaces it.
#[test]
fn a_progress_update_carries_the_name_its_spawn_gave() {
    let mut tree = SubagentTree::default();
    subagents(
        &mut tree,
        json!({"sessionUpdate": "subagent_spawned", "subagentSessionId": "s1/toolu_a",
                   "name": "Drop server login", "task": "Drop server login"}),
    );
    let progress = subagents(
        &mut tree,
        json!({"sessionUpdate": "subagent_progress", "subagentSessionId": "s1/toolu_a", "tokens": 10}),
    );
    assert_eq!(progress[0]["name"], json!("Drop server login"));
    let ended = subagents(
        &mut tree,
        json!({"sessionUpdate": "subagent_state_update", "subagentSessionId": "s1/toolu_a", "state": "completed"}),
    );
    assert_eq!(ended[0]["name"], json!("Drop server login"));
    subagents(
        &mut tree,
        json!({"sessionUpdate": "subagent_progress", "subagentSessionId": "s1/toolu_a", "name": "Renamed"}),
    );
    let next = subagents(
        &mut tree,
        json!({"sessionUpdate": "subagent_progress", "subagentSessionId": "s1/toolu_a", "tokens": 11}),
    );
    assert_eq!(next[0]["name"], json!("Renamed"));
    // A task-only spawn names it too.
    subagents(
        &mut tree,
        json!({"sessionUpdate": "subagent_spawned", "subagentSessionId": "s1/toolu_t", "task": "Check the rail"}),
    );
    let later = subagents(
        &mut tree,
        json!({"sessionUpdate": "subagent_progress", "subagentSessionId": "s1/toolu_t", "tokens": 1}),
    );
    assert_eq!(later[0]["name"], json!("Check the rail"));
}

/// A name holding a secret across the label's cut is masked before the cut, so the cached name a
/// later nameless event carries holds none of it.
#[test]
fn a_cached_name_is_masked_before_its_cut() {
    let body: String = "aZ3kQ9mX7pL2vB8nR4tW6yC1dF5gH0jS".chars().cycle().take(36).collect();
    let token = format!("gh{}_{body}", "p");
    assert_eq!(crate::secret_scan::mask(&token), "[GitHub Personal Access Token]");
    let name = format!("{} {token}", "x".repeat(50));
    let mut tree = SubagentTree::default();
    subagents(
        &mut tree,
        json!({"sessionUpdate": "subagent_spawned", "subagentSessionId": "s1/toolu_s", "name": name}),
    );
    let later = subagents(
        &mut tree,
        json!({"sessionUpdate": "subagent_progress", "subagentSessionId": "s1/toolu_s", "tokens": 1}),
    );
    let cached = later[0]["name"].as_str().unwrap();
    assert!(!cached.contains("aZ3kQ9"), "{cached}");
}
