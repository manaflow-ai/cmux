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
    daemon.sigkill();
    drop(rpc);

    daemon.start();
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
