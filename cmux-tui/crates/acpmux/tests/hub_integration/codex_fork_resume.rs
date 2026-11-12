//! A fork of an idle Codex chat (`hub/fork.rs`, `session/fork` to the chat's
//! own agent) resumes its own thread in its own app-server. The parent's
//! app-server makes the thread (`thread/fork`) and so holds it; Codex lets one
//! app-server write a thread, and refused the fork's own `thread/resume`
//! ("already has an active writer"). The fork then fell back to a fresh thread
//! fed acpmux's transcript (`resumed` level `rehydrate`), its tool state lost.
//! The fake app-server keeps that rule under FAKE_CODEX_WRITERS.

use super::codex_processes::{chat, codex_hub_env};
use super::*;

/// The fork's log has no refused load and no fresh-thread fallback: its agent
/// loaded the thread the parent's `session/fork` made.
#[tokio::test]
async fn codex_fork_resumes_its_own_thread_natively() {
    let writers =
        std::env::temp_dir().join(format!("acpmux-cxfork-writers-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&writers).unwrap();
    let held = writers.to_string_lossy().into_owned();
    let (hub, mut c, root) = codex_hub_env(&[("FAKE_CODEX_WRITERS", held.as_str())]).await;
    let id = chat(&mut c, "first").await;

    // Idle: the hub asks the chat's own agent for `session/fork`.
    let f = c
        .request(method::SESSION_FORK, json!({"sessionId": id, "cwd": cwd()}))
        .await
        .unwrap_or_else(|e| panic!("an idle Codex chat forks: {e:?}"));
    let fid = f["sessionId"].as_str().unwrap().to_owned();
    assert_ne!(fid, id);
    let thread = hub.resolve(&fid).unwrap().meta().agent_session_id;
    assert!(
        thread.as_deref().is_some_and(|t| t.starts_with("fake-fork-")),
        "the fork names the thread the parent's agent forked: {thread:?}"
    );

    // Its first prompt runs on its own agent, started by now or by this prompt.
    let r = c
        .request(
            method::SESSION_PROMPT,
            json!({"sessionId": fid, "prompt": [{"type": "text", "text": "second"}]}),
        )
        .await
        .unwrap();
    assert_eq!(r["stopReason"], "end_turn", "{r}");

    let events = hub.events(&fid, 0, 10_000).unwrap();
    let failed: Vec<&Value> = events
        .iter()
        .filter(|e| e.dir == "mux" && e.kind == "resume_failed")
        .map(|e| &e.msg)
        .collect();
    assert!(failed.is_empty(), "the fork's own app-server refused its thread: {failed:?}");
    let resumed: Vec<&Value> =
        events.iter().filter(|e| e.dir == "mux" && e.kind == "resumed").map(|e| &e.msg).collect();
    assert!(
        !resumed.iter().any(|m| m["level"] == "rehydrate"),
        "the fork fell back to a fresh thread: {resumed:?}"
    );
    assert!(
        resumed.iter().any(|m| m["level"] == "exact"),
        "the fork loaded its own thread: {resumed:?}"
    );
    assert_eq!(
        hub.resolve(&fid).unwrap().meta().agent_session_id,
        thread,
        "the fork still runs the thread it was made with"
    );

    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
    let _ = std::fs::remove_dir_all(&writers);
}
