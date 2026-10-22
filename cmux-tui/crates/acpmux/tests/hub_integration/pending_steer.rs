//! A steer the agent has not read yet is the person's to take back or change (Leo, 2026-10-21: "I
//! CAN'T EDIT AND CANCEL THESE"). Claude Code reads a steer at its next tool boundary, so one sent
//! during a long tool call waits unread; acpmux keeps it until the call ends, and until then
//! `queue_remove` takes it back (the agent is never sent it) and `queue_edit` `update` changes it
//! (the agent is sent the new text).
use super::*;

fn steer(id: &str, prompt_id: &str, text: &str) -> Value {
    json!({"sessionId": id, "prompt": [{"type": "text", "text": text}], "_meta": {"acpmux": {"promptId": prompt_id, "steer": true}}})
}

/// A Claude chat whose turn runs a tool call that ends when the gate opens.
#[cfg(unix)]
async fn in_a_long_tool_call() -> (Arc<Hub>, TestClient, String, std::path::PathBuf) {
    let gate = std::env::temp_dir().join(format!("acpmux-steer-gate-{}", uuid::Uuid::now_v7()));
    assert!(std::process::Command::new("mkfifo").arg(&gate).status().unwrap().success());
    let env = BTreeMap::from([("FAKE_CLAUDE_STEER".to_owned(), "1".to_owned())]);
    let (hub, mut c) = setup_env(PermissionPolicy::ApproveAll, env).await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let work = format!("work-gate: {}", gate.display());
    c.send(method::SESSION_PROMPT, prompt(&id, &work, Some("p-work"))).await;
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["toolCallId"] == "wg-1").await;
    (hub, c, id, gate)
}

#[cfg(unix)]
async fn open(gate: std::path::PathBuf) {
    tokio::task::spawn_blocking(move || std::fs::write(gate, b"open")).await.unwrap().unwrap();
}

/// The text of every prompt acpmux sent the agent, once the chat settled: no turn runs and
/// nothing waits (up to 10 s), then a moment more.
async fn sent_to_agent(hub: &Hub, id: &str) -> Vec<String> {
    let session = hub.resolve(id).unwrap();
    for _ in 0..200 {
        if session.turn().is_none() && session.queue().is_empty() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    tokio::time::sleep(Duration::from_millis(300)).await;
    hub.events(id, 0, 10_000)
        .unwrap()
        .into_iter()
        .filter(|e| e.dir == "out" && e.kind == method::SESSION_PROMPT)
        .map(|e| e.msg.to_string())
        .collect()
}

#[cfg(unix)]
#[tokio::test]
async fn a_steer_taken_back_during_a_long_tool_call_never_reaches_the_agent() {
    let (hub, mut c, id, gate) = in_a_long_tool_call().await;
    c.send(method::SESSION_PROMPT, steer(&id, "p-steer", "stop and use the other file")).await;
    c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "p-steer").await;
    let removed =
        c.request("_acpmux/queue_remove", json!({"sessionId": id, "promptId": "p-steer"})).await;
    open(gate).await;
    assert_eq!(removed.as_ref().map(|r| r["removed"].clone()), Ok(json!(true)), "{removed:?}");
    let sent = sent_to_agent(&hub, &id).await;
    assert!(sent.iter().all(|t| !t.contains("other file")), "the agent was sent it: {sent:?}");
}

#[cfg(unix)]
#[tokio::test]
async fn a_steer_edited_during_a_long_tool_call_reaches_the_agent_as_edited() {
    let (hub, mut c, id, gate) = in_a_long_tool_call().await;
    c.send(method::SESSION_PROMPT, steer(&id, "p-steer", "use the old name")).await;
    c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "p-steer").await;
    let edited = c
        .request(
            "_acpmux/queue_edit",
            json!({"sessionId": id, "promptId": "p-steer", "op": "update", "text": "use the new name"}),
        )
        .await;
    open(gate).await;
    assert_eq!(edited.as_ref().map(|r| r["ok"].clone()), Ok(json!(true)), "{edited:?}");
    let sent = sent_to_agent(&hub, &id).await;
    assert!(sent.iter().any(|t| t.contains("use the new name")), "{sent:?}");
    assert!(sent.iter().all(|t| !t.contains("use the old name")), "the old text went: {sent:?}");
}

/// A tool call that never reports its end holds a steer until its turn ends: then the steer runs
/// as the next prompt, so it still reaches the agent, once.
#[cfg(unix)]
#[tokio::test]
async fn a_steer_held_by_a_call_that_never_ends_runs_when_the_turn_ends() {
    let env = BTreeMap::from([("FAKE_CLAUDE_STEER".to_owned(), "1".to_owned())]);
    let (hub, mut c) = setup_env(PermissionPolicy::ApproveAll, env).await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    // "quiet-tool" opens a tool call it never ends, then ends its turn a second later.
    c.send(method::SESSION_PROMPT, prompt(&id, "quiet-tool", Some("p-work"))).await;
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["toolCallId"] == "q1").await;
    c.send(method::SESSION_PROMPT, steer(&id, "p-steer", "then read the notes")).await;
    c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "p-steer").await;
    let sent = sent_to_agent(&hub, &id).await;
    let steered = sent.iter().filter(|t| t.contains("then read the notes")).count();
    assert_eq!(steered, 1, "{sent:?}");
    let events = hub.events(&id, 0, 10_000).unwrap();
    let ran = events
        .iter()
        .find(|e| e.kind == "user_message" && e.msg["promptId"] == "p-steer")
        .map(|e| e.msg.clone());
    assert!(ran.as_ref().is_some_and(|m| m["steer"] != json!(true)), "{ran:?}");
}
