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

/// A background Claude subagent still running after its parent's turn ended
/// asks for permission: the ask reaches the person and the answer reaches the
/// subagent (cx-jo8yo).
#[tokio::test]
async fn a_claude_subagent_asking_after_the_turn_ended_reaches_the_person() {
    let root = std::env::temp_dir().join(format!("acpmux-late-{}", uuid::Uuid::now_v7()));
    let claude = root.join("claude");
    std::fs::create_dir_all(&claude).unwrap();
    let (hub, mut c) = claude_setup(&claude, &[]).await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    hub.set_policy(&hub.resolve(&id).unwrap(), PermissionPolicy::Ask).await;
    let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": "late-agent-ask"}]});
    let rid = c.send(method::SESSION_PROMPT, prompt).await;
    // The ask comes in while the prompt's own response is on its way: its
    // notification comes before that response or after it (cx-nx5mb).
    let (done, before) = c.response(rid).await;
    done.unwrap();
    let asked = match before.into_iter().find(|(m, _)| m == method::MUX_PERMISSION_PENDING) {
        Some((_, pending)) => pending,
        None => c.wait_for(method::MUX_PERMISSION_PENDING, |_| true).await,
    };
    let pid = asked["permissionId"].as_str().unwrap().to_owned();
    // The chat waits on the person after its turn ended, not ready.
    let session = hub.resolve(&id).unwrap();
    assert_eq!(hub.session_summary(&session)["status"], "waiting");
    // This client is not the person, so it rejects (an allow needs the app's
    // decision proof): the person's answer, not a cancel, reaches the subagent.
    c.request(
        method::MUX_PERMISSION_RESPOND,
        json!({"sessionId": id, "permissionId": pid, "optionId": "reject_once"}),
    )
    .await
    .unwrap();
    let decision = hub
        .events(&id, 0, 10_000)
        .unwrap()
        .into_iter()
        .rfind(|e| e.kind == "permission_decision")
        .expect("a decision");
    assert_eq!(decision.msg["outcome"]["outcome"], "selected", "{}", decision.msg);
    assert_eq!(decision.msg["outcome"]["optionId"], "reject_once");
    let said = super::super::transcript_events::late_chunk(&hub, &id, |m| {
        m.pointer("/params/_meta/acpmux/subagent").is_some()
    })
    .await;
    assert_eq!(said["params"]["update"]["content"]["text"], "late deny", "{said}");
    assert_eq!(hub.session_summary(&session)["status"], "ready");
    let _ = std::fs::remove_dir_all(root);
}
