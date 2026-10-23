//! cx-zlox: acpmux decides each session's status dot once (`indicator` on
//! the session summary) and every client draws it, so the chat list, the tab
//! strip and the sidebar agree. First match wins: `input` (a permission or
//! question waits), `working`, `failed` (the last turn failed), `lost` (the
//! agent process is gone and the chat has no answer), `done` (the last turn
//! answered), else null. Whether `done` was seen stays with each client.

use super::*;

/// The session's wire summary (`_acpmux/watch`) once `settled` holds.
async fn settled(
    hub: &Hub,
    c: &mut TestClient,
    id: &str,
    settled: impl Fn(&Value) -> bool,
) -> Value {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    loop {
        let summary = hub.session_summary(&hub.resolve(id).unwrap());
        if settled(&summary) {
            break;
        }
        assert!(tokio::time::Instant::now() < deadline, "never settled: {summary}");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    let watched = c.request("_acpmux/watch", json!({"enabled": true})).await.unwrap();
    watched["sessions"].as_array().unwrap().iter().find(|s| s["sessionId"] == id).unwrap().clone()
}

#[tokio::test]
async fn an_answered_turn_is_done() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, "done").await;
    c.request(method::SESSION_PROMPT, prompt(&id, "hello", None)).await.unwrap();
    let s = settled(&hub, &mut c, &id, |s| s["lastTurn"]["status"] == "completed").await;
    assert_eq!(s.get("indicator"), Some(&json!("done")), "{s}");
}

#[tokio::test]
async fn a_failed_turn_is_failed_while_its_agent_still_runs() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, "failed").await;
    let failed = c.request(method::SESSION_PROMPT, prompt(&id, "fail-streamed: boom", None)).await;
    assert!(failed.is_err(), "{failed:?}");
    let s = settled(&hub, &mut c, &id, |s| s["status"] == "ready").await;
    assert_eq!(s["lastTurn"]["status"], "failed", "{s}");
    assert_eq!(s.get("indicator"), Some(&json!("failed")), "{s}");
}

#[tokio::test]
async fn an_agent_gone_without_an_answer_is_lost() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, "lost").await;
    c.send(method::SESSION_PROMPT, prompt(&id, "until-cancel-then-exit", None)).await;
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["content"]["text"] == "running").await;
    c.tx.send(Message::notification(method::SESSION_CANCEL, json!({"sessionId": id})).to_line())
        .await
        .unwrap();
    // The exit can land before the cancelled turn is recorded: wait for both.
    let s = settled(&hub, &mut c, &id, |s| {
        s["status"] == "disconnected" && s["lastTurn"]["status"] == "cancelled"
    })
    .await;
    assert_eq!(s.get("indicator"), Some(&json!("lost")), "{s}");
}

/// An agent that exits with nothing lost leaves the chat idle: the next prompt starts it again
/// on the same conversation (`hub/auto_resume/revive.rs`).
#[tokio::test]
async fn an_agent_gone_before_any_prompt_shows_nothing() {
    let env = BTreeMap::from([("FAKE_EXIT_AFTER_NEW".to_owned(), "1".to_owned())]);
    let (hub, mut c) = setup_env(PermissionPolicy::ApproveAll, env).await;
    let id = new_session(&mut c, "unprompted").await;
    let s = settled(&hub, &mut c, &id, |s| s["status"] == "idle").await;
    assert!(s["lastTurn"].is_null(), "{s}");
    assert_eq!(s["indicator"], Value::Null, "{s}");
}

#[tokio::test]
async fn an_agent_gone_after_its_answer_is_done() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, "answered").await;
    c.request(method::SESSION_PROMPT, prompt(&id, "answer-then-exit", None)).await.unwrap();
    // The agent is gone; the chat keeps its answer, so it is done, not lost, and idle.
    let s = settled(&hub, &mut c, &id, |s| s["status"] == "idle").await;
    assert_eq!(s["lastTurn"]["status"], "completed", "{s}");
    assert_eq!(s.get("indicator"), Some(&json!("done")), "{s}");
}

#[tokio::test]
async fn a_running_turn_is_working_and_a_waiting_permission_is_input() {
    let (hub, mut c) = setup(PermissionPolicy::Ask).await;
    let id = new_session(&mut c, "live").await;
    c.send(method::SESSION_PROMPT, prompt(&id, "until-cancel", None)).await;
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["content"]["text"] == "running").await;
    let s = settled(&hub, &mut c, &id, |s| s["status"] == "running").await;
    assert_eq!(s.get("indicator"), Some(&json!("working")), "{s}");
    c.tx.send(Message::notification(method::SESSION_CANCEL, json!({"sessionId": id})).to_line())
        .await
        .unwrap();
    settled(&hub, &mut c, &id, |s| s["turn"].is_null()).await;

    c.send(method::SESSION_PROMPT, prompt(&id, "ask: rm -rf /", None)).await;
    let s = settled(&hub, &mut c, &id, |s| s["pendingPermissions"].as_u64() > Some(0)).await;
    assert_eq!(s.get("indicator"), Some(&json!("input")), "{s}");
}

#[tokio::test]
async fn process_death_quotes_the_last_stderr_line() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let s = c
        .request(
            method::SESSION_NEW,
            json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": {"name": "die"}}}),
        )
        .await
        .unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let r = c.request(method::SESSION_PROMPT, json!({"sessionId": id, "prompt": [{"type": "text", "text": "die: Not logged in · Please run /login"}]})).await;
    let err = r.unwrap_err();
    assert!(err.contains("agent process closed (fake): Not logged in"), "{err}");
    let session = hub.resolve(&id).unwrap();
    let last =
        hub.events(&id, 0, 1000).unwrap().into_iter().rfind(|e| e.kind == "turn_result").unwrap();
    assert_eq!(last.msg["status"], "failed");
    assert!(last.msg["error"].as_str().unwrap().contains("Not logged in"));
    assert_eq!(hub.session_summary(&session)["status"], "disconnected");
}

/// A harness that dies while it starts (a wrapper such as `sr2 claude` that
/// refuses, a CLI that is not signed in) fails `session/new` with its own
/// last stderr line, not a bare "agent process closed" (the Chief's
/// "session/new: agent process closed", 2026-10-19, said nothing of why).
#[tokio::test]
async fn a_harness_that_dies_at_start_fails_session_new_with_its_stderr() {
    let env = BTreeMap::from([(
        "FAKE_DIE_AT_START".to_owned(),
        "subrouter: no account can serve this session".to_owned(),
    )]);
    let (_hub, mut c) = setup_env(PermissionPolicy::ApproveAll, env).await;
    let err = c
        .request(
            method::SESSION_NEW,
            json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": {"name": "dies"}}}),
        )
        .await
        .unwrap_err();
    assert!(
        err.contains("agent process closed (fake): subrouter: no account can serve this session"),
        "{err}"
    );
}
