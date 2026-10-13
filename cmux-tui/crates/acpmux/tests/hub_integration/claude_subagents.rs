//! Claude's Agent tool as a native subagent session (Lawrence 2026-10-12,
//! native subagents for Claude Code and Codex in the agent pane): the
//! subagent model names the kind of agent it is, and the child's own lines
//! arrive under it.

use super::*;

/// A Claude subagent's model names the kind of agent it is (its Agent call's
/// subagent_type), and its own read arrives under it.
#[tokio::test]
async fn claude_subagents_carry_their_kind() {
    let root = std::env::temp_dir().join(format!("acpmux-agent-{}", uuid::Uuid::now_v7()));
    let claude = root.join("claude");
    std::fs::create_dir_all(&claude).unwrap();
    let (hub, mut c) = claude_setup(&claude, &[]).await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": "agent-probe"}]});
    c.request(method::SESSION_PROMPT, prompt).await.unwrap();
    let events = hub.events(&id, 0, 10_000).unwrap();
    let mux: Vec<Value> =
        events.iter().filter_map(|e| e.msg.pointer("/params/_meta/acpmux").cloned()).collect();
    let spawn = mux
        .iter()
        .filter_map(|m| m.get("subagents").and_then(Value::as_array))
        .flatten()
        .find(|s| s["state"] == "running")
        .cloned()
        .unwrap_or_else(|| panic!("no subagent spawned: {mux:?}"));
    assert_eq!(spawn["kind"], "Explore");
    assert_eq!(spawn["name"], "Find the tests");
    assert!(mux.iter().any(|m| m.get("subagent") == Some(&spawn["id"])), "{mux:?}");
    let _ = std::fs::remove_dir_all(root);
}
