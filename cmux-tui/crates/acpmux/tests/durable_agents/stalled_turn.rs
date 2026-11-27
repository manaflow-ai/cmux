//! A turn whose model went quiet for good, across a daemon restart (`hub/stalled_turn.rs`).

use super::*;

fn now_ms() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_millis() as u64
}

/// The session's row in `_acpmux/sessions`.
async fn listed(daemon: &Daemon, session: &str) -> Value {
    let all = daemon.rpc().await.call("_acpmux/sessions", json!({})).await;
    all["sessions"]
        .as_array()
        .and_then(|all| all.iter().find(|s| s["sessionId"] == session))
        .cloned()
        .unwrap_or(Value::Null)
}

/// The config of the `stalled` test's daemon: `stalled_ms` as `stalledTurnEndMs`, or the default.
fn stalled_config(daemon: &Daemon, stalled_ms: Option<u64>) {
    let mut config = json!({"harnesses": {"fake": {"argv": ["python3", FAKE]}},
                            "defaultHarness": "fake", "permissionPolicy": "approve-all"});
    if let Some(ms) = stalled_ms {
        config["stalledTurnEndMs"] = json!(ms);
    }
    std::fs::write(daemon.home.join("config.json"), config.to_string()).unwrap();
}

/// huge-blue, 2026-10-25: 72 Codex chats read `running` for a day. Each Codex sent its model
/// request, never heard back and lived on with the turn open, ignoring the cancel; each daemon
/// restart adopted its host and rebuilt the turn as just started. The adopted turn keeps its
/// logged start, and once its model has said nothing for `stalledTurnEndMs` (counted from the log,
/// not from the restart) acpmux ends it as failed, `stalled`; the idle harness exit then stops
/// the agent, so it no longer holds a slot.
///
/// No step waits in a wall-clock window (the full run on a loaded gate host missed the running
/// row between adoption and the stall's end): the first restart keeps the default period, so the
/// adopted turn runs until the test looks; the second sets a period the down time already passed,
/// and the turn's `stalledMs` (the product's own count) must cover that down time.
#[tokio::test]
async fn an_adopted_turn_whose_model_went_quiet_ends_as_stalled_and_frees_its_agent() {
    const STALLED_MS: u64 = 3_000;
    let mut daemon = Daemon::with_env("stalled", "approve-all", &[("ACPMUX_IDLE_CHILD_SECS", "1")]);
    daemon.sigterm();
    stalled_config(&daemon, None);
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

    // A restart keeps the adopted turn's logged start (the default period does not end it).
    daemon.sigterm();
    drop(client);
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

    // Down past the period: that silence counts too, so the next daemon ends the turn at once.
    daemon.sigterm();
    stalled_config(&daemon, Some(STALLED_MS));
    let down_until = heard + STALLED_MS + 2_000;
    std::thread::sleep(Duration::from_millis(down_until.saturating_sub(now_ms())));
    let restarted = now_ms();
    daemon.start();
    daemon.wait_event(&session, "host_adopted", |e| e["kind"] == "host_adopted");

    let result = daemon.wait_event(&session, "turn_result", |e| e["kind"] == "turn_result");
    assert_eq!(result["msg"]["status"], "failed", "{result}");
    assert_eq!(result["msg"]["detail"], "stalled", "{result}");
    assert_eq!(result["msg"]["errorSource"], "acpmux", "{result}");
    assert_eq!(result["msg"]["turnId"], started["msg"]["turnId"], "{result}");
    let quiet = result["msg"]["stalledMs"].as_u64().unwrap();
    assert!(quiet >= STALLED_MS, "ended before stalledTurnEndMs: {result}");
    let at = result["at"].as_u64().unwrap();
    assert!(at >= heard + STALLED_MS, "ended before stalledTurnEndMs: {result}");
    // Counted from the restart, the silence would start after `restarted`; counted from the
    // model's last word it holds the whole down time (ms rounding allowed).
    assert!(
        quiet + 10 >= restarted - heard,
        "counted from the restart, not the model's last word: {result} (heard {heard}, restarted {restarted})"
    );
    // The chat settles out of `running` (test polling): `finish_turn` logs the result and takes
    // the turn first and sets the status last, after it asks whether the agent is alive; a row
    // read in between (fix run 4 on a loaded gate host) shows `running` with no turn.
    let deadline = Instant::now() + Duration::from_secs(30);
    let row = loop {
        let row = listed(&daemon, &session).await;
        if row["status"] != "running" {
            break row;
        }
        assert!(Instant::now() < deadline, "the chat reads running with no turn: {row}");
        tokio::time::sleep(Duration::from_millis(50)).await;
    };
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
