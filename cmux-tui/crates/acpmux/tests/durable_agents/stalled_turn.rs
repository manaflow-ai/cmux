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

/// huge-blue, 2026-10-25: 72 Codex chats read `running` for a day. Each Codex sent its model
/// request, never heard back and lived on with the turn open, ignoring the cancel; each daemon
/// restart adopted its host and rebuilt the turn as just started. The adopted turn keeps its
/// logged start, and once its model has said nothing for `stalledTurnEndMs` (counted from the log,
/// not from the restart) acpmux ends it as failed, `stalled`; the idle harness exit then stops
/// the agent, so it no longer holds a slot.
#[tokio::test]
async fn an_adopted_turn_whose_model_went_quiet_ends_as_stalled_and_frees_its_agent() {
    let mut daemon = Daemon::with_env("stalled", "approve-all", &[("ACPMUX_IDLE_CHILD_SECS", "1")]);
    daemon.sigterm();
    std::fs::write(
        daemon.home.join("config.json"),
        json!({"harnesses": {"fake": {"argv": ["python3", FAKE]}}, "defaultHarness": "fake",
               "permissionPolicy": "approve-all", "stalledTurnEndMs": 8000})
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
    let heard = daemon.wait_event(&session, "working chunk", |e| chunk(e, "working"))["at"]
        .as_u64()
        .unwrap();
    let started = daemon.wait_event(&session, "turn_started", |e| e["kind"] == "turn_started");
    let harness_pid = daemon.host_record(&session)["harness_pid"].as_i64().unwrap();

    daemon.sigterm();
    drop(client);
    // Down for 5 s: that silence counts too.
    std::thread::sleep(Duration::from_secs(5));
    daemon.start();
    daemon.wait_event(&session, "host_adopted", |e| e["kind"] == "host_adopted");
    // `host_adopted` is logged before recovery restores the turn in flight
    // (`hub/hosts.rs` `recover_work`): until then the row has no turn.
    until_turn_restored(&daemon, &session).await;
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
    assert!(quiet >= 8000, "ended before stalledTurnEndMs: {result}");
    let at = result["at"].as_u64().unwrap();
    assert!(at >= heard + 8000, "ended before stalledTurnEndMs: {result}");
    // Counted from the restart it would end 8 s after it, past 13 s.
    assert!(at < heard + 12_000, "counted from the restart, not the model's last word: {result}");
    let row = listed(&daemon, &session).await;
    assert_ne!(row["status"], "running", "{row}");
    assert!(row["turn"].is_null(), "{row}");
    assert_eq!(row["lastTurn"]["detail"], "stalled", "{row}");
    assert!(gone_within(harness_pid, Duration::from_secs(20)), "the stalled agent still runs");
}

/// An adopted turn quiet inside a tool call that had not ended when the daemon restarted still
/// gets four periods: its open tool calls come from the log too.
#[tokio::test]
async fn an_adopted_turn_inside_an_open_tool_call_gets_four_periods() {
    let mut daemon = Daemon::new("stalltool", "approve-all");
    daemon.sigterm();
    std::fs::write(
        daemon.home.join("config.json"),
        json!({"harnesses": {"fake": {"argv": ["python3", FAKE]}}, "defaultHarness": "fake",
               "permissionPolicy": "approve-all", "stalledTurnEndMs": 2500})
        .to_string(),
    )
    .unwrap();
    daemon.start();
    let session = new_session(&daemon).await;
    let mut client = daemon.rpc().await;
    client
        .send(
            "session/prompt",
            json!({"sessionId": session, "prompt": [{"type": "text", "text": "tool-hang"}]}),
        )
        .await;
    let heard = daemon.wait_event(&session, "open tool call", |e| {
        e["kind"] == "tool_call" && e["msg"]["params"]["update"]["toolCallId"] == "th-1"
    })["at"]
        .as_u64()
        .unwrap();
    daemon.sigterm();
    drop(client);
    std::thread::sleep(Duration::from_secs(1));
    daemon.start();
    daemon.wait_event(&session, "host_adopted", |e| e["kind"] == "host_adopted");

    let result = daemon.wait_event(&session, "turn_result", |e| e["kind"] == "turn_result");
    assert_eq!(result["msg"]["detail"], "stalled", "{result}");
    let at = result["at"].as_u64().unwrap();
    assert!(at >= heard + 10_000, "ended inside its open tool call before 4 periods: {result}");
}
