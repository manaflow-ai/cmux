//! A subagent's own conversation as its fork resumes it (`fork_subagent.rs`): Claude sidechains
//! and Codex child rollouts, each line once, cut at the last settled step.

use super::*;

fn lines(text: &str) -> Vec<Value> {
    text.lines().map(|l| serde_json::from_str(l).unwrap()).collect()
}

/// A Claude sidechain, as Claude Code writes `agent-<id>.jsonl`.
fn sidechain(dangling: bool) -> String {
    let mut out = vec![
        json!({"type": "user", "isSidechain": true, "agentId": "a1", "sessionId": "parent", "uuid": "u1",
               "message": {"role": "user", "content": "List the test files"}}),
        json!({"type": "assistant", "isSidechain": true, "agentId": "a1", "sessionId": "parent", "uuid": "u2",
               "message": {"role": "assistant", "content": [{"type": "tool_use", "id": "t1", "name": "Read", "input": {}}]}}),
        json!({"type": "user", "isSidechain": true, "agentId": "a1", "sessionId": "parent", "uuid": "u3",
               "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "t1", "content": "fn t() {}"}]}}),
        json!({"type": "assistant", "isSidechain": true, "agentId": "a1", "sessionId": "parent", "uuid": "u4",
               "message": {"role": "assistant", "stop_reason": "end_turn", "content": [{"type": "text", "text": "Found one test file"}]}}),
    ];
    if dangling {
        out.push(json!({"type": "assistant", "isSidechain": true, "agentId": "a1", "sessionId": "parent", "uuid": "u5",
               "message": {"role": "assistant", "content": [{"type": "tool_use", "id": "t2", "name": "Bash", "input": {}}]}}));
    }
    out.iter().map(|v| v.to_string() + "\n").collect()
}

#[test]
fn a_claude_sidechain_becomes_a_main_conversation_of_the_copy_each_line_once() {
    let (copy, cut) = claude_sidechain_copy(&sidechain(false), "new").unwrap();
    assert!(!cut);
    let records = lines(&copy);
    assert_eq!(records.len(), 4, "each line once: {copy}");
    for r in &records {
        assert_eq!(r["sessionId"], "new");
        assert_eq!(r["isSidechain"], false);
        assert!(r.get("agentId").is_none(), "{r}");
    }
    let uuids: Vec<&str> = records.iter().filter_map(|r| r["uuid"].as_str()).collect();
    assert_eq!(uuids, ["u1", "u2", "u3", "u4"]);
}

#[test]
fn a_running_claude_subagent_forks_through_its_last_settled_step() {
    let (copy, cut) = claude_sidechain_copy(&sidechain(true), "new").unwrap();
    assert!(cut, "the open tool call is left out");
    let records = lines(&copy);
    assert_eq!(records.len(), 4, "{copy}");
    assert!(!copy.contains("\"t2\""), "{copy}");
}

#[test]
fn a_subagent_with_no_settled_step_is_refused() {
    let only_call = json!({"type": "assistant", "isSidechain": true, "sessionId": "p",
        "message": {"content": [{"type": "tool_use", "id": "t1", "name": "Read", "input": {}}]}});
    let prompt = json!({"type": "user", "isSidechain": true, "sessionId": "p",
        "message": {"role": "user", "content": "go"}});
    let text = format!("{prompt}\n{only_call}\n");
    // Its prompt is a settled step on its own.
    assert!(claude_sidechain_copy(&text, "n").is_ok());
    assert!(claude_sidechain_copy(&format!("{only_call}\n"), "n").is_err());
    assert!(claude_sidechain_copy("", "n").is_err());
}

#[test]
fn the_copied_sidechain_reads_as_the_subagents_turns() {
    let dir = tempfile::tempdir().unwrap();
    let (copy, _) = claude_sidechain_copy(&sidechain(true), "new").unwrap();
    let file = dir.path().join("new.jsonl");
    std::fs::write(&file, copy).unwrap();
    let turns = crate::adopt_replay::read("claude", &file);
    assert_eq!(turns.len(), 1, "{turns:?}");
    assert_eq!(turns[0].prompt, "List the test files");
    assert_eq!(turns[0].answer, "Found one test file");
}

fn rollout(child: &str, parent: &str, dangling: bool) -> String {
    let mut out = vec![
        json!({"timestamp": "2026-11-22T00:00:00.000Z", "type": "session_meta", "payload": {
            "id": child, "session_id": parent, "parent_thread_id": parent, "cwd": "/w",
            "agent_nickname": "Ada", "agent_role": "explorer", "agent_path": "/root/ada",
            "thread_source": "subagent",
            "source": {"subagent": {"thread_spawn": {"parent_thread_id": parent, "depth": 1}}}}}),
        json!({"timestamp": "2026-11-22T00:00:01.000Z", "type": "event_msg", "payload": {"type": "task_started"}}),
        json!({"timestamp": "2026-11-22T00:00:01.000Z", "type": "response_item", "payload": {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "Map the crate"}]}}),
        json!({"timestamp": "2026-11-22T00:00:02.000Z", "type": "response_item", "payload": {"type": "function_call", "call_id": "c1", "name": "shell", "arguments": "{}"}}),
        json!({"timestamp": "2026-11-22T00:00:03.000Z", "type": "response_item", "payload": {"type": "function_call_output", "call_id": "c1", "output": "ok"}}),
        json!({"timestamp": "2026-11-22T00:00:04.000Z", "type": "response_item", "payload": {"type": "message", "role": "assistant", "phase": "final_answer", "content": [{"type": "output_text", "text": "Mapped"}]}}),
    ];
    if dangling {
        out.push(json!({"timestamp": "2026-11-22T00:00:05.000Z", "type": "response_item", "payload": {"type": "function_call", "call_id": "c2", "name": "shell", "arguments": "{}"}}));
    }
    out.iter().map(|v| v.to_string() + "\n").collect()
}

#[test]
fn a_codex_child_becomes_a_top_level_thread_of_its_own() {
    let (copy, cut) = codex_child_copy(&rollout("child", "root", false), "child", "new").unwrap();
    assert!(!cut);
    let records = lines(&copy);
    assert_eq!(records.len(), 6, "each record once: {copy}");
    let meta = &records[0]["payload"];
    assert_eq!(meta["id"], "new");
    assert_eq!(meta["session_id"], "new");
    assert_eq!(meta["forked_from_id"], "child");
    assert_eq!(meta["source"], "vscode");
    assert_eq!(meta["thread_source"], "user");
    for key in ["parent_thread_id", "agent_nickname", "agent_role", "agent_path"] {
        assert!(meta.get(key).is_none(), "{key}: {meta}");
    }
    assert!(codex_parent(meta).is_none());
}

#[test]
fn a_running_codex_child_forks_through_its_last_settled_step() {
    let (copy, cut) = codex_child_copy(&rollout("child", "root", true), "child", "new").unwrap();
    assert!(cut);
    assert_eq!(lines(&copy).len(), 6);
    assert!(!copy.contains("\"c2\""));
}

#[test]
fn a_codex_child_kept_by_reference_or_naming_another_thread_is_refused() {
    assert!(codex_child_copy(&rollout("child", "root", false), "other", "new").is_err());
    let referenced = rollout("child", "root", false).replacen(
        "\"cwd\":\"/w\"",
        "\"cwd\":\"/w\",\"history_base\":{\"ordinal\":3}",
        1,
    );
    assert!(codex_child_copy(&referenced, "child", "new").is_err(), "{referenced}");
}

#[test]
fn the_codex_parent_is_read_from_either_place() {
    assert_eq!(codex_parent(&json!({"parent_thread_id": "p"})), Some("p"));
    assert_eq!(
        codex_parent(&json!({"source": {"subagent": {"thread_spawn": {"parent_thread_id": "q"}}}})),
        Some("q")
    );
    assert_eq!(codex_parent(&json!({"source": "vscode"})), None);
}

fn store_rollout(home: &Path, id: &str, text: &str) {
    let day = home.join("sessions/2026/11/22");
    std::fs::create_dir_all(&day).unwrap();
    std::fs::write(day.join(format!("rollout-2026-11-22T00-00-00-{id}.jsonl")), text).unwrap();
}

/// Only a child of one of the chat's own threads (or of their children) forks: another chat's
/// thread is never read.
#[test]
fn only_a_child_of_the_chats_own_threads_is_found() {
    let dir = tempfile::tempdir().unwrap();
    store_rollout(dir.path(), "child", &rollout("child", "root", false));
    store_rollout(dir.path(), "grand", &rollout("grand", "child", false));
    store_rollout(dir.path(), "stranger", &rollout("stranger", "elsewhere", false));
    let own = vec!["root".to_owned()];
    assert!(codex_child_of(dir.path(), "child", &own).is_ok());
    assert!(codex_child_of(dir.path(), "grand", &own).is_ok(), "a grandchild is the chat's too");
    assert!(codex_child_of(dir.path(), "stranger", &own).is_err());
    assert!(
        codex_child_of(dir.path(), "root", &own).is_err(),
        "the chat's own thread is no subagent"
    );
    assert!(codex_child_of(dir.path(), "../x", &own).is_err());
    assert!(codex_child_of(dir.path(), "missing", &own).is_err());
}

fn record(entries: Value) -> EventRecord {
    EventRecord {
        seq: 1,
        at: 0,
        dir: "in".into(),
        kind: "subagent_spawned".into(),
        msg: json!({"params": {"_meta": {"acpmux": {"subagents": entries}}}}),
        host_seq: None,
    }
}

#[test]
fn a_subagent_is_found_by_its_id_or_its_agent_id_at_any_depth() {
    let records = vec![
        record(
            json!([{"id": "s/toolu_1", "parent": null, "name": "Find the tests", "prompt": "List", "state": "running"}]),
        ),
        record(
            json!([{"id": "s/toolu_2", "parent": "s/toolu_1", "task": "Inner", "state": "running"}]),
        ),
        record(json!([{"id": "s/toolu_1", "parent": null, "state": "completed", "agentId": "a1"}])),
    ];
    let by_id = entry_from_records(&records, "s/toolu_1").unwrap();
    assert_eq!(by_id.agent_id.as_deref(), Some("a1"));
    assert_eq!(by_id.name.as_deref(), Some("Find the tests"));
    assert_eq!(by_id.prompt.as_deref(), Some("List"));
    assert_eq!(by_id.state.as_deref(), Some("completed"));
    assert_eq!(entry_from_records(&records, "a1").unwrap().id, "s/toolu_1");
    let inner = entry_from_records(&records, "s/toolu_2").unwrap();
    assert_eq!(inner.name.as_deref(), Some("Inner"));
    assert!(entry_from_records(&records, "nope").is_none());
}

#[test]
fn a_fork_start_reads_its_fields_and_refuses_bad_ones() {
    let start = ForkStart::from_params(
        &json!({"_meta": {"acpmux": {"subagentId": "s/toolu_1", "mode": "plan", "model": "haiku"}}}),
        true,
    )
    .unwrap();
    assert_eq!(start.subagent.as_deref(), Some("s/toolu_1"));
    assert_eq!(start.mode.as_deref(), Some("plan"));
    assert_eq!(start.model.as_deref(), Some("haiku"));
    assert!(!start.is_plain());
    // With a harness the model is the switch's.
    let switch = ForkStart::from_params(
        &json!({"_meta": {"acpmux": {"harness": "codex", "model": "gpt"}}}),
        false,
    )
    .unwrap();
    assert!(switch.is_plain());
    assert!(
        ForkStart::from_params(&json!({"_meta": {"acpmux": {"subagentId": "a b"}}}), false)
            .is_err()
    );
    assert!(ForkStart::from_params(&json!({"_meta": {"acpmux": {"mode": 3}}}), false).is_err());
}

#[test]
fn a_mode_the_harness_does_not_list_is_refused_naming_those_it_does() {
    let mut meta: SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "c", "name": "c", "harness": "claude",
        "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 2
    }))
    .unwrap();
    meta.modes = Some(json!({"currentModeId": "default", "availableModes": [
        {"id": "default", "name": "Default"}, {"id": "plan", "name": "Plan"}]}));
    assert!(check_mode(&meta, "plan").is_ok());
    let e = check_mode(&meta, "yolo").unwrap_err();
    assert!(e.message.contains("default, plan"), "{}", e.message);
    assert_eq!(e.data.as_ref().unwrap()["reason"], "fork.mode_unknown");
    meta.modes = None;
    assert!(check_mode(&meta, "plan").is_err());
}
