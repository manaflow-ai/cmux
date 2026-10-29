//! Requests read their own chat while the restart's hosted-log pass is still queued.

use super::*;

/// A prompt must prioritize its chat's log before waiting for adoption, while the pending
/// prompt still stays behind the turn the adopted host owns (covered by restart_reattach).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_prompt_reads_its_chat_log_before_waiting_for_adoption() {
    let mut daemon = Daemon::new("priority-prompt", "approve-all");
    let (session, gate) = super::restart_reattach::kept_turn(&mut daemon).await;
    daemon.start();
    let mut prompt = daemon.rpc().await;
    prompt
        .send(
            "session/prompt",
            json!({"sessionId": session,
        "prompt": [{"type": "text", "text": "after the kept turn"}]}),
        )
        .await;
    let mut info = daemon.rpc().await;
    tokio::time::timeout(Duration::from_millis(1_500), async {
        let mut ticks = tokio::time::interval(Duration::from_millis(20));
        loop {
            let reply =
                info.call("_acpmux/info", json!({"sessionId": session, "waitLogs": false})).await;
            if reply["logsLoading"] == false {
                break;
            }
            ticks.tick().await;
        }
    })
    .await
    .expect("the prompted log loads during the 3 s adoption hold");
    assert!(
        !daemon.events(&session).iter().any(|event| event["kind"] == "host_adopted"),
        "the log must load before adoption rather than after its global gate"
    );
    std::fs::write(gate, b"go").unwrap();
}

/// The existing demand path bypasses the live-log queue. Keep that property when startup's
/// metadata moves off the ready path: an attach to chat 25 must not wait for the other 24.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_attach_reads_its_chat_with_twenty_four_hosted_logs_queued() {
    let mut daemon = Daemon::new("priority-attach", "approve-all");
    let mut clients = Vec::new();
    let mut sessions = Vec::new();
    for _ in 0..25 {
        let mut rpc = daemon.rpc().await;
        let created = rpc.call("session/new", json!({"cwd": daemon.home, "mcpServers": []})).await;
        let session = created["sessionId"].as_str().unwrap().to_owned();
        let gate = daemon.home.join(format!("gate-{session}"));
        make_fifo(&gate);
        rpc.send(
            "session/prompt",
            json!({"sessionId": session,
            "prompt": [{"type": "text", "text": format!("gate: {}", gate.display())}]}),
        )
        .await;
        daemon.wait_event(&session, "before-gate", |event| chunk(event, "before-gate"));
        sessions.push(session);
        clients.push(rpc);
    }
    daemon.sigterm();
    drop(clients);
    daemon.env = vec![("ACPMUX_TEST_DELAY_LOAD_LOGS_MS".into(), "3000".into())];
    daemon.start();
    let mut rpc = daemon.rpc().await;
    let chosen = sessions.last().unwrap();
    let attached = tokio::time::timeout(
        Duration::from_millis(1_500),
        rpc.call("_acpmux/attach", json!({"sessionId": chosen, "limit": 0})),
    )
    .await
    .expect("the chosen chat attaches before the hosted-log pass starts");
    assert_eq!(attached["session"]["sessionId"].as_str(), Some(chosen.as_str()));
    for session in sessions.iter().take(24) {
        let info = rpc.call("_acpmux/info", json!({"sessionId": session, "waitLogs": false})).await;
        assert_eq!(info["logsLoading"], true, "another chat's log ran ahead of demand: {info}");
    }
    for session in &sessions {
        std::fs::write(daemon.home.join(format!("gate-{session}")), b"go").unwrap();
    }
}
