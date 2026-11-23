//! Pause and resume on request (`hub/pause.rs`): `_acpmux/pause` (`acpmux session pause`) ends an
//! idle session's agent now and `_acpmux/wake` (`acpmux session wake`) or its next prompt starts it
//! again on the same conversation. Leo (2026-11-03): "i think acpmux ought to be like ultra
//! conducive to pause/resume. we can absolutely own the fuck out of that layer".
//!
//! The rig is `session_hibernate.rs`'s: the fake harness under a shell that records its own pid and
//! its stand-in MCP server's. With Codex's own store (`rig_with_store`), the agent's conversation
//! lives in its rollout file: `session/load` fails for an id it does not hold, and "history-probe"
//! answers with the prompts and session ids the loaded conversation holds, so what the agent
//! remembers after a resume is read from the agent itself.

use super::session_hibernate::{alive, rig, rig_with_store};
use super::*;

/// What the agent's own conversation holds: "history-probe"'s answer.
async fn agent_history(r: &mut super::session_hibernate::Rig, id: &str) -> Value {
    let before = r.hub.events(id, 0, 10_000).unwrap().last().map_or(0, |e| e.seq);
    r.c.request(method::SESSION_PROMPT, prompt(id, "history-probe", None)).await.unwrap();
    let text: String = r
        .hub
        .events(id, before, 10_000)
        .unwrap()
        .iter()
        .filter(|e| e.kind == "agent_message_chunk")
        .filter_map(|e| e.msg.pointer("/params/update/content/text").and_then(Value::as_str))
        .collect();
    serde_json::from_str(&text).unwrap_or_else(|e| panic!("{e}: {text}"))
}

/// A paused session resumes with its state intact: the pause ends its harness and MCP server at
/// once (no idle wait) and keeps the chat open; the wake starts exactly one new harness, which
/// loads the same agent conversation (same agent session id, same prompts), and the next prompt
/// continues it. The pause and the resume times are printed.
#[tokio::test]
async fn a_paused_session_resumes_its_conversation_with_its_state_intact() {
    let mut r = rig_with_store(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut r.c, "pause").await;
    r.c.request(method::SESSION_PROMPT, prompt(&id, "remember 42", None)).await.unwrap();
    let before = agent_history(&mut r, &id).await;
    assert_eq!(before["prompts"], json!(["remember 42"]), "{before}");
    let agent_sid = r.hub.resolve(&id).unwrap().meta().agent_session_id.expect("an agent id");
    assert_eq!(before["sessions"], json!([agent_sid]), "{before}");
    let (harness, sidecar) = (r.pids("harness")[0], r.pids("sidecar")[0]);

    let paused = r.c.request(method::MUX_PAUSE, json!({"sessionId": id})).await.unwrap();
    assert_eq!(paused["paused"], true, "{paused}");
    r.until("the paused harness kept running", || !alive(harness)).await;
    r.until("the paused harness's MCP server kept running", || !alive(sidecar)).await;
    assert_eq!(r.status(&id), "idle", "a pause closed the chat");
    let meta = r.hub.resolve(&id).unwrap().meta();
    assert_ne!(meta.hibernated_ms, 0, "the pause was not stored as a hibernation");
    assert_eq!(meta.agent_session_id.as_deref(), Some(agent_sid.as_str()));
    // A second pause finds it paused.
    let again = r.c.request(method::MUX_PAUSE, json!({"sessionId": id})).await.unwrap();
    assert_eq!((again["paused"].clone(), again["reason"].clone()), (json!(false), json!("paused")));

    let woke = r.c.request(method::MUX_WAKE, json!({"sessionId": id})).await.unwrap();
    assert_eq!(woke["woke"], true, "{woke}");
    eprintln!(
        "pause: harness exited in {} ms; wake: resumed in {} ms",
        paused["exitMs"], woke["tookMs"]
    );
    assert_eq!(r.pids("harness").len(), 2, "the wake did not start exactly one new harness");
    assert_eq!(r.status(&id), "ready");
    let events = r.hub.events(&id, 0, 10_000).unwrap();
    let resumed = events.iter().rev().find(|e| e.kind == "resumed").expect("no resumed record");
    assert_eq!(resumed.msg["wake"], true, "{}", resumed.msg);
    // A wake of a running agent does nothing.
    let running = r.c.request(method::MUX_WAKE, json!({"sessionId": id})).await.unwrap();
    assert_eq!(
        (running["woke"].clone(), running["reason"].clone()),
        (json!(false), json!("running"))
    );
    assert_eq!(r.pids("harness").len(), 2);

    // The agent itself still holds the conversation it had, under the same id.
    let after = agent_history(&mut r, &id).await;
    assert_eq!(after, before, "the resumed agent lost its conversation");
    r.c.request(method::SESSION_PROMPT, prompt(&id, "what was the number?", None)).await.unwrap();
    let continued = agent_history(&mut r, &id).await;
    assert_eq!(continued["prompts"], json!(["remember 42", "what was the number?"]), "{continued}");
    assert_eq!(continued["sessions"], json!([agent_sid]), "{continued}");
    assert_eq!(r.pids("harness").len(), 2, "the prompt after the wake started another harness");
}

/// A prompt resumes a paused session by itself, on the same conversation, and reaches its agent
/// once.
#[tokio::test]
async fn a_prompt_resumes_a_paused_session_on_its_conversation() {
    let mut r = rig_with_store(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut r.c, "pause-prompt").await;
    r.c.request(method::SESSION_PROMPT, prompt(&id, "first", None)).await.unwrap();
    let paused = r.c.request(method::MUX_PAUSE, json!({"sessionId": id})).await.unwrap();
    assert_eq!(paused["paused"], true, "{paused}");
    let harness = r.pids("harness")[0];
    r.until("the paused harness kept running", || !alive(harness)).await;
    r.c.request(method::SESSION_PROMPT, prompt(&id, "second", None)).await.unwrap();
    assert_eq!(r.pids("harness").len(), 2);
    let history = agent_history(&mut r, &id).await;
    assert_eq!(history["prompts"], json!(["first", "second"]), "{history}");
    assert_eq!(r.texts(&id, "user_message").iter().filter(|t| *t == "second").count(), 1);
}

/// A pause of a busy session is refused and changes nothing: the running turn (with its tool
/// call) runs on with its harness. Once the turn is done, the pause goes through.
#[cfg(unix)]
#[tokio::test]
async fn a_busy_session_is_not_paused() {
    let mut r = rig(PermissionPolicy::ApproveAll).await;
    let gate = r.dir.join("gate");
    assert!(std::process::Command::new("mkfifo").arg(&gate).status().unwrap().success());
    let id = new_session(&mut r.c, "pause-busy").await;
    let turn = format!("work-gate: {}", gate.display());
    let first = r.c.send(method::SESSION_PROMPT, prompt_with_id(&id, &turn, "p-turn", false)).await;
    r.c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "p-turn").await;
    let refused = r.c.request(method::MUX_PAUSE, json!({"sessionId": id})).await.unwrap_err();
    assert!(refused.contains("not idle") && refused.contains("not paused"), "{refused}");
    assert_eq!(r.status(&id), "running");
    assert!(alive(r.pids("harness")[0]), "a refused pause ended the harness");
    let open = gate.clone();
    tokio::task::spawn_blocking(move || std::fs::write(open, b"open")).await.unwrap().unwrap();
    assert_eq!(r.c.response(first).await.0.unwrap()["stopReason"], "end_turn");
    let paused = r.c.request(method::MUX_PAUSE, json!({"sessionId": id})).await.unwrap();
    assert_eq!(paused["paused"], true, "{paused}");
    let harness = r.pids("harness")[0];
    r.until("the paused harness kept running", || !alive(harness)).await;
}
