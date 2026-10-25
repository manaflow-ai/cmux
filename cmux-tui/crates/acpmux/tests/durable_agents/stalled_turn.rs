//! A turn whose model went quiet for good, across a daemon restart (`hub/stalled_turn.rs`).

use super::*;

/// The session's row in `_acpmux/sessions`.
async fn listed(daemon: &Daemon, session: &str) -> Value {
    let all = daemon.rpc().await.call("_acpmux/sessions", json!({})).await;
    all["sessions"]
        .as_array()
        .and_then(|all| all.iter().find(|s| s["sessionId"] == session))
        .cloned()
        .unwrap_or(Value::Null)
}

/// huge-blue, 2026-10-25: 77 Codex chats read `running` for a day. Each Codex sent its model
/// request, never heard back and lived on with the turn open, ignoring the cancel; each daemon
/// restart adopted its host and rebuilt the turn as just started. The adopted turn keeps its
/// logged start, and once its model has said nothing for `stalledTurnMs` (counted from the log,
/// not from the restart) acpmux ends it as failed, `stalled`; the idle harness exit then stops
/// the agent, so it no longer holds a slot.
#[tokio::test]
async fn an_adopted_turn_whose_model_went_quiet_ends_as_stalled_and_frees_its_agent() {
    let mut daemon = Daemon::with_env("stalled", "approve-all", &[("ACPMUX_IDLE_CHILD_SECS", "1")]);
    daemon.sigterm();
    std::fs::write(
        daemon.home.join("config.json"),
        json!({"harnesses": {"fake": {"argv": ["python3", FAKE]}}, "defaultHarness": "fake",
               "permissionPolicy": "approve-all", "stalledTurnMs": 6000})
        .to_string(),
    )
    .unwrap();
    daemon.start();
    let session = new_session(&daemon).await;
    let mut client = daemon.rpc().await;
    // "hang": one word, then nothing, and no answer to the cancel either.
    client
        .send(
            "session/prompt",
            json!({"sessionId": session, "prompt": [{"type": "text", "text": "hang"}]}),
        )
        .await;
    daemon.wait_event(&session, "working chunk", |e| chunk(e, "working"));
    let started = daemon.wait_event(&session, "turn_started", |e| e["kind"] == "turn_started");
    let harness_pid = daemon.host_record(&session)["harness_pid"].as_i64().unwrap();

    daemon.sigterm();
    drop(client);
    daemon.start();
    daemon.wait_event(&session, "host_adopted", |e| e["kind"] == "host_adopted");
    let row = listed(&daemon, &session).await;
    assert_eq!(row["status"], "running", "{row}");
    assert_eq!(
        row["turn"]["startedAt"], started["at"],
        "the restart made the adopted turn new: {row}"
    );

    let result = daemon.wait_event(&session, "turn_result", |e| e["kind"] == "turn_result");
    assert_eq!(result["msg"]["status"], "failed", "{result}");
    assert_eq!(result["msg"]["detail"], "stalled", "{result}");
    assert_eq!(result["msg"]["errorSource"], "acpmux", "{result}");
    assert_eq!(result["msg"]["turnId"], started["msg"]["turnId"], "{result}");
    let quiet = result["msg"]["stalledMs"].as_u64().unwrap();
    assert!(quiet >= 6000, "ended before stalledTurnMs: {result}");
    let heard = daemon.wait_event(&session, "working chunk", |e| chunk(e, "working"))["at"]
        .as_u64()
        .unwrap();
    assert!(
        result["at"].as_u64().unwrap() < heard + 6000 + 20_000,
        "counted from the restart, not the model's last word: {result}"
    );
    let row = listed(&daemon, &session).await;
    assert_ne!(row["status"], "running", "{row}");
    assert!(row["turn"].is_null(), "{row}");
    assert_eq!(row["lastTurn"]["detail"], "stalled", "{row}");
    assert!(gone_within(harness_pid, Duration::from_secs(20)), "the stalled agent still runs");
}
