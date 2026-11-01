//! An automatic retry waiting during a daemon restart keeps its deadline and runs once.
use super::*;

fn now_ms() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_millis() as u64
}

#[tokio::test]
async fn pending_retry_survives_restart_at_its_original_deadline_once() {
    let mut daemon = Daemon::new("retry-restore", "approve-all");
    daemon.sigterm();
    std::fs::write(
        daemon.home.join("config.json"),
        json!({"harnesses": {"fake": {"argv": ["python3", FAKE]}},
            "defaultHarness": "fake", "permissionPolicy": "approve-all",
            "autoResumeDelaysMs": [10000]})
        .to_string(),
    )
    .unwrap();
    daemon.start();
    let mut rpc = daemon.rpc().await;
    let created = rpc.call("session/new", json!({"cwd": daemon.home, "mcpServers": []})).await;
    let session = created["sessionId"].as_str().unwrap().to_owned();
    let result = rpc
        .reply(
            "session/prompt",
            json!({"sessionId": session,
        "prompt": [{"type": "text", "text": "net-fail-once: keep working"}],
        "_meta": {"acpmux": {"promptId": "retry-original"}}}),
        )
        .await;
    assert!(result.get("error").is_some(), "{result}");
    let scheduled = daemon
        .wait_event(&session, "pending automatic retry", |e| e["kind"] == "auto_resume_scheduled");
    let deadline = scheduled["msg"]["nextAt"].as_u64().unwrap();
    assert_eq!(scheduled["msg"]["promptId"], "retry-original");
    assert_eq!(scheduled["msg"]["attempt"], 1);
    assert_eq!(scheduled["msg"]["of"], 1);
    assert_eq!(scheduled["msg"]["reason"], "transport");
    assert!(scheduled["msg"]["turnId"].is_string());
    daemon.sigkill();
    drop(rpc);

    // A crash may persist the schedule before the async session metadata writer catches up.
    // The retry and its failed cut turn must be recovered from the journal in that case too.
    let meta_path = daemon.home.join("sessions").join(&session).join("session.json");
    let mut meta: Value = serde_json::from_slice(&std::fs::read(&meta_path).unwrap()).unwrap();
    meta.as_object_mut().unwrap().remove("lastTurn");
    std::fs::write(&meta_path, serde_json::to_vec(&meta).unwrap()).unwrap();

    daemon.start();
    let restored = daemon.wait_event(&session, "the restored automatic retry", |e| {
        e["kind"] == "auto_resume_restored"
    });
    assert_eq!(restored["msg"]["nextAt"], deadline);
    assert_eq!(restored["msg"]["promptId"], "retry-original");
    assert_eq!(restored["msg"]["turnId"], scheduled["msg"]["turnId"]);
    assert_eq!(restored["msg"]["attempt"], 1);
    let mut rpc = daemon.rpc().await;
    let attached = rpc.call("_acpmux/attach", json!({"sessionId": session, "limit": 0})).await;
    assert_eq!(
        attached["session"]["retry"]["nextAt"], deadline,
        "the restart must restore the original deadline: {attached:#}"
    );
    assert_eq!(attached["session"]["retry"]["attempt"], 1);
    assert!(
        !daemon
            .events(&session)
            .iter()
            .any(|e| e["kind"] == "turn_started"
                && e["msg"]["promptId"] == "retry-original~resume-1"),
        "retry fired early"
    );

    // Crash again before it fires, then remain down until its original deadline is past.
    daemon.sigkill();
    drop(rpc);
    tokio::time::sleep(Duration::from_millis(deadline.saturating_sub(now_ms()) + 50)).await;
    daemon.start();
    let result = daemon.wait_event(&session, "the recovered retry completing", |e| {
        e["kind"] == "turn_result" && e["msg"]["promptId"] == "retry-original~resume-1"
    });
    assert_eq!(result["msg"]["status"], "completed", "{result:#}");
    assert!(result["at"].as_u64().unwrap() >= deadline);

    // A completed retry is not re-armed by the next restart.
    daemon.sigkill();
    daemon.start();
    let mut rpc = daemon.rpc().await;
    let attached = rpc.call("_acpmux/attach", json!({"sessionId": session, "limit": 0})).await;
    assert_eq!(attached["session"]["retry"], Value::Null, "{attached:#}");
    assert_eq!(attached["session"]["lastTurn"]["promptId"], "retry-original~resume-1");
    let events = daemon.events(&session);
    assert_eq!(
        events
            .iter()
            .filter(|e| e["kind"] == "turn_started"
                && e["msg"]["promptId"] == "retry-original~resume-1")
            .count(),
        1
    );
    assert_eq!(
        events.iter().filter(|e| e["kind"] == "auto_resume_scheduled").count(),
        1,
        "recovery must not schedule another attempt or reset its deadline"
    );
}

#[tokio::test]
async fn non_hosted_outcome_unknown_gets_attempt_one_without_a_retry_delay() {
    let mut daemon =
        Daemon::with_env("retry-unknown", "approve-all", &[("ACPMUX_AGENT_HOSTS", "0")]);
    let session = new_session(&daemon).await;
    let gate = daemon.home.join("gate");
    make_fifo(&gate);
    let mut rpc = daemon.rpc().await;
    rpc.send(
        "session/prompt",
        json!({"sessionId": session,
        "prompt": [{"type": "text", "text": format!("gate: {}", gate.display())}],
        "_meta": {"acpmux": {"promptId": "unknown-original"}}}),
    )
    .await;
    daemon.wait_event(&session, "running non-hosted turn", |e| chunk(e, "before-gate"));
    daemon.sigkill();
    drop(rpc);
    daemon.start();
    let unknown = daemon.wait_event(&session, "restart outcome unknown", |e| {
        e["kind"] == "turn_result" && e["msg"]["detail"] == "outcome_unknown"
    });
    assert_eq!(unknown["msg"]["status"], "failed");
    assert_eq!(unknown["msg"]["errorText"], "the daemon restarted before this turn settled");
    let scheduled = daemon.wait_event(&session, "immediate restart continuation", |e| {
        e["kind"] == "auto_resume_scheduled" && e["msg"]["promptId"] == "unknown-original"
    });
    assert_eq!(scheduled["msg"]["attempt"], 1);
    assert_eq!(scheduled["msg"]["delayMs"], 0);
    assert_eq!(scheduled["msg"]["turnId"], unknown["msg"]["turnId"]);
    let result = daemon.wait_event(&session, "restart continuation completing", |e| {
        e["kind"] == "turn_result" && e["msg"]["promptId"] == "unknown-original~resume-1"
    });
    assert_eq!(result["msg"]["status"], "completed");
    assert_eq!(
        daemon
            .events(&session)
            .iter()
            .filter(|e| e["kind"] == "turn_started"
                && e["msg"]["promptId"] == "unknown-original~resume-1")
            .count(),
        1
    );
}

#[tokio::test]
async fn blocked_web_retry_is_settled_and_not_rearmed_by_a_later_restart() {
    let mut daemon =
        Daemon::with_env("retry-web-ended", "approve-all", &[("ACPMUX_AGENT_HOSTS", "0")]);
    let session = new_session(&daemon).await;
    let mut rpc = daemon.rpc().await;
    let result = rpc
        .reply(
            "session/prompt",
            json!({"sessionId": session,
                "prompt": [{"type": "text", "text": "net-fail-once: web retry"}],
                "_meta": {"acpmux": {"promptId": "web-retry"}}}),
        )
        .await;
    assert!(result.get("error").is_some(), "{result}");
    let scheduled =
        daemon.wait_event(&session, "pending Web retry", |e| e["kind"] == "auto_resume_scheduled");
    let turn_id = scheduled["msg"]["turnId"].as_str().unwrap().to_owned();
    let events_dir = daemon.home.join("sessions").join(&session).join("events");
    let mut files: Vec<_> =
        std::fs::read_dir(&events_dir).unwrap().filter_map(|e| e.ok().map(|e| e.path())).collect();
    files.sort();
    let path = files.last().expect("event log");
    let seq = daemon.events(&session).iter().filter_map(|e| e["seq"].as_u64()).max().unwrap();
    let raised = json!({"seq": seq + 1, "at": 0, "dir": "mux", "kind": "turn_control",
        "msg": {"turnId": turn_id.clone(), "control": "web"}});
    let ended = json!({"seq": seq + 2, "at": 0, "dir": "mux", "kind": "remote_control_ended",
        "msg": {"mode": "ask"}});
    let mut log = std::fs::OpenOptions::new().append(true).open(path).unwrap();
    std::io::Write::write_all(&mut log, format!("{raised}\n{ended}\n").as_bytes()).unwrap();
    drop(log);
    daemon.sigkill();
    drop(rpc);

    daemon.start();
    let skipped = daemon.wait_event(&session, "blocked retry decision", |e| {
        e["kind"] == "auto_resume_skipped" && e["msg"]["skipped"] == "remote_control_ended"
    });
    assert_eq!(skipped["msg"]["promptId"], "web-retry");
    assert_eq!(skipped["msg"]["attempt"], 1);
    assert_eq!(skipped["msg"]["turnId"], turn_id);
    let mut rpc = daemon.rpc().await;
    let _ = rpc.call("_acpmux/attach", json!({"sessionId": session, "limit": 0})).await;
    daemon.sigkill();
    drop(rpc);

    daemon.start();
    let mut rpc = daemon.rpc().await;
    let attached = rpc.call("_acpmux/attach", json!({"sessionId": session, "limit": 0})).await;
    assert_eq!(attached["session"]["retry"], Value::Null, "{attached:#}");
    let events = daemon.events(&session);
    assert_eq!(
        events
            .iter()
            .filter(|e| e["kind"] == "auto_resume_skipped"
                && e["msg"]["skipped"] == "remote_control_ended")
            .count(),
        1,
        "{events:#?}"
    );
    assert!(!events.iter().any(|e| e["kind"] == "auto_resume_restored"));
    assert!(
        !events
            .iter()
            .any(|e| e["kind"] == "turn_started" && e["msg"]["promptId"] == "web-retry~resume-1")
    );
}

#[tokio::test]
async fn adopted_running_prompt_resend_joins_its_live_outcome() {
    let mut daemon = Daemon::new("retry-adopted", "approve-all");
    let session = new_session(&daemon).await;
    let gate = daemon.home.join("gate");
    make_fifo(&gate);
    let params = json!({"sessionId": session,
        "prompt": [{"type": "text", "text": format!("gate: {}", gate.display())}],
        "_meta": {"acpmux": {"promptId": "adopted-original", "resend": true}}});
    let mut rpc = daemon.rpc().await;
    rpc.send("session/prompt", params.clone()).await;
    daemon.wait_event(&session, "running hosted turn", |e| chunk(e, "before-gate"));
    daemon.sigkill();
    drop(rpc);
    daemon.start();
    daemon.wait_event(&session, "host adoption", |e| e["kind"] == "host_adopted");
    let attached =
        daemon.rpc().await.call("_acpmux/attach", json!({"sessionId": session, "limit": 0})).await;
    assert_eq!(attached["session"]["status"], "running", "{attached:#}");
    let mut rpc = daemon.rpc().await;
    let request_id = rpc.send("session/prompt", params.clone()).await;
    // An adopted prompt must join the pending ledger entry, not answer "interrupted" from
    // the journal. Wait for acceptance before checking it stays pending behind the gate.
    loop {
        let line = tokio::time::timeout(Duration::from_secs(30), rpc.lines.next_line())
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        let reply: Value = serde_json::from_str(&line).unwrap();
        assert_ne!(
            reply.get("id"),
            Some(&json!(request_id)),
            "running prompt answered early: {reply}"
        );
        if reply["method"] == "_acpmux/prompt_accepted"
            && reply["params"]["promptId"] == "adopted-original"
        {
            assert_eq!(reply["params"]["duplicate"], true);
            break;
        }
    }
    let early = tokio::time::timeout(Duration::from_millis(150), async {
        loop {
            let line = rpc.lines.next_line().await.unwrap().unwrap();
            let reply: Value = serde_json::from_str(&line).unwrap();
            if reply.get("id") == Some(&json!(request_id)) {
                break reply;
            }
        }
    })
    .await;
    assert!(early.is_err(), "running prompt returned a terminal outcome: {early:?}");
    std::fs::write(&gate, b"go").unwrap();
    let reply = loop {
        let line = tokio::time::timeout(Duration::from_secs(30), rpc.lines.next_line())
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        let reply: Value = serde_json::from_str(&line).unwrap();
        if reply.get("id") == Some(&json!(request_id)) {
            break reply;
        }
    };
    assert_eq!(reply["result"]["stopReason"], "end_turn", "{reply}");
    assert_eq!(reply["result"].pointer("/_meta/acpmux/duplicate"), Some(&json!(true)));
    assert_eq!(reply["result"].pointer("/_meta/acpmux/promptId"), Some(&json!("adopted-original")));
    let again = rpc.call("session/prompt", params).await;
    assert_eq!(again["stopReason"], "end_turn");
    assert_eq!(
        daemon
            .events(&session)
            .iter()
            .filter(|e| e["kind"] == "turn_started" && e["msg"]["promptId"] == "adopted-original")
            .count(),
        1
    );
}

#[tokio::test]
async fn pending_retry_stopped_after_recovery_stays_stopped_across_restart() {
    let mut daemon = Daemon::new("retry-stopped", "approve-all");
    let mut rpc = daemon.rpc().await;
    let created = rpc.call("session/new", json!({"cwd": daemon.home, "mcpServers": []})).await;
    let session = created["sessionId"].as_str().unwrap().to_owned();
    let result = rpc
        .reply(
            "session/prompt",
            json!({"sessionId": session,
        "prompt": [{"type": "text", "text": "net-fail-once: stop this retry"}],
        "_meta": {"acpmux": {"promptId": "retry-stopped"}}}),
        )
        .await;
    assert!(result.get("error").is_some(), "{result}");
    let scheduled = daemon
        .wait_event(&session, "pending automatic retry", |e| e["kind"] == "auto_resume_scheduled");
    daemon.sigkill();
    drop(rpc);
    daemon.start();
    daemon.wait_event(&session, "the restored automatic retry", |e| {
        e["kind"] == "auto_resume_restored"
    });
    let mut rpc = daemon.rpc().await;
    let attached = rpc.call("_acpmux/attach", json!({"sessionId": session, "limit": 0})).await;
    assert_eq!(attached["session"]["retry"]["nextAt"], scheduled["msg"]["nextAt"]);
    rpc.call("session/cancel", json!({"sessionId": session})).await;
    daemon.wait_event(&session, "the stop decision", |e| {
        e["kind"] == "auto_resume_settled" && e["msg"]["why"] == "stopped"
    });
    daemon.sigkill();
    drop(rpc);
    daemon.start();
    let attached =
        daemon.rpc().await.call("_acpmux/attach", json!({"sessionId": session, "limit": 0})).await;
    assert_eq!(attached["session"]["retry"], Value::Null, "{attached:#}");
    assert!(
        !daemon.events(&session).iter().any(
            |e| e["kind"] == "turn_started" && e["msg"]["promptId"] == "retry-stopped~resume-1"
        )
    );
}

/// A turn still running in its agent host when the daemon restarts is `running` from its
/// adoption on. The log has no `ready` between `host_adopted` and that turn's end: the adoption
/// logged `ready` before it recovered the turn, so a client that attached between the two saw an
/// idle chat (`adopted_running_prompt_resend_joins_its_live_outcome` read `ready` on a loaded
/// fleet Mac).
#[tokio::test]
async fn an_adopted_running_turn_is_never_logged_ready() {
    let mut daemon = Daemon::new("adopt-ready", "approve-all");
    let session = new_session(&daemon).await;
    let gate = daemon.home.join("gate");
    make_fifo(&gate);
    let params = json!({"sessionId": session,
        "prompt": [{"type": "text", "text": format!("gate: {}", gate.display())}]});
    let mut rpc = daemon.rpc().await;
    rpc.send("session/prompt", params).await;
    daemon.wait_event(&session, "running hosted turn", |e| chunk(e, "before-gate"));
    daemon.sigkill();
    drop(rpc);
    daemon.start();
    daemon.wait_event(&session, "host adoption", |e| e["kind"] == "host_adopted");
    std::fs::write(&gate, b"go").unwrap();
    daemon.wait_event(&session, "the adopted turn's end", |e| e["kind"] == "turn_result");
    let events = daemon.events(&session);
    let adopted = events.iter().position(|e| e["kind"] == "host_adopted").unwrap();
    let ended = events.iter().position(|e| e["kind"] == "turn_result").unwrap();
    let statuses: Vec<&Value> = events[adopted..ended]
        .iter()
        .filter(|e| e["kind"] == "status")
        .map(|e| &e["msg"]["status"])
        .collect();
    assert!(!statuses.iter().any(|s| *s == "ready"), "statuses after adoption: {statuses:?}");
}

/// A chat saved `waiting` with nothing left to ask (the previous daemon sent the answer and
/// stopped before it logged `ready`) is `ready` once its idle host is adopted: the adoption
/// replaces a loaded status that nothing it recovered set, as a turn's end does.
#[tokio::test]
async fn an_adopted_idle_chat_saved_waiting_with_nothing_asked_is_ready() {
    let mut daemon = Daemon::new("adopt-waiting", "approve-all");
    let session = new_session(&daemon).await;
    let mut rpc = daemon.rpc().await;
    let prompt = json!({"sessionId": session, "prompt": [{"type": "text", "text": "hi"}]});
    assert_eq!(rpc.call("session/prompt", prompt).await["stopReason"], "end_turn");
    drop(rpc);
    daemon.sigkill();
    let path = daemon.home.join("sessions").join(&session).join("session.json");
    let mut meta: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    meta["status"] = json!("waiting");
    std::fs::write(&path, serde_json::to_vec_pretty(&meta).unwrap()).unwrap();
    daemon.start();
    daemon.wait_event(&session, "host adoption", |e| e["kind"] == "host_adopted");
    let attached =
        daemon.rpc().await.call("_acpmux/attach", json!({"sessionId": session, "limit": 0})).await;
    assert_eq!(attached["session"]["status"], "ready", "{attached:#}");
}
