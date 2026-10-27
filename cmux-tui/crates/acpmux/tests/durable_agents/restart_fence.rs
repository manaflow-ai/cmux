//! A fenced line a daemon handed its agent's host, still queued there when the daemon restarts
//! (#23322 a3 fence, the residual risk of #26241): the host logs a line before its stdin writer
//! writes it, so the next daemon must hold it again from its log, and an MDM off push waits for
//! it, or cuts it by ending the host, before it returns.

use super::*;

/// The residual risk named on #26241: an ancestor's answer, resent under its fence after one
/// restart, waits in the host's stdin writer (the harness reads nothing, and the answer is larger
/// than the pipe). The daemon restarts again with MDM unset; then MDM's off is pushed. Before the
/// push returns, the answer is written or can never be: once the harness reads again, it never
/// gets an answer checked under the old bound.
#[tokio::test]
async fn an_off_push_after_a_restart_cuts_a_fenced_line_its_host_still_queues() {
    let mut daemon = Daemon::new("rfence", "ask");
    daemon.sigterm();
    let reads = daemon.home.join("reads-again");
    std::fs::write(
        daemon.home.join("config.json"),
        json!({"harnesses": {"fake": {"argv": [
                   "/usr/bin/env", format!("FAKE_ASK_HOLDS_STDIN={}", reads.display()), "python3", FAKE]}},
               "defaultHarness": "fake", "permissionPolicy": "ask"})
        .to_string(),
    )
    .unwrap();
    daemon.start();
    let session = new_session(&daemon).await;
    let mut client = daemon.rpc().await;
    let prompt = json!({"sessionId": session, "prompt": [{"type": "text", "text": "ask: deploy"}]});
    client.send("session/prompt", prompt).await;
    let asked =
        daemon.wait_event(&session, "permission_request", |e| e["kind"] == "permission_request");
    let permission_id = asked["msg"]["permissionId"].as_str().unwrap().to_owned();
    let agent_request = asked["msg"]["agentRequestId"].clone();
    daemon.sigterm();
    drop(client);
    // An ancestor's answer the agent never got, larger than the harness's stdin pipe.
    let pad = "x".repeat(1 << 20);
    let decision = json!({"permissionId": permission_id,
                          "outcome": {"outcome": "selected", "optionId": "yes", "_meta": {"pad": pad}},
                          "answeredBy": {"session": "an-ancestor", "name": "parent"}});
    log_while_down(&daemon, &session, "permission_decision", decision);
    // The next daemon resends it under its fence (MDM unset); its host takes it and queues it.
    daemon.start();
    daemon.wait_event(&session, "the resent answer", |e| {
        e["dir"] == "out" && e["kind"] == "response" && e["msg"]["id"] == agent_request
    });
    let harness_pid = daemon.host_record(&session)["harness_pid"].as_i64().unwrap();
    daemon.sigterm();
    // The daemon after it adopts the host, whose writer still holds the answer.
    daemon.start();
    let adopted = || daemon.events(&session).iter().filter(|e| e["kind"] == "host_adopted").count();
    let deadline = Instant::now() + Duration::from_secs(30);
    while adopted() < 2 {
        assert!(Instant::now() < deadline, "the host was not adopted again");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    let pushed = daemon.rpc().await.call("_acpmux/chat_settings", mdm_off_push()).await;
    assert_eq!(pushed["applied"], true, "{pushed}");
    // The push returned: the harness reads again.
    std::fs::write(&reads, "").unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline {
        let got = daemon.events(&session).iter().any(|e| chunk(e, "chose yes"));
        assert!(
            !got,
            "an answer queued across a restart reached the agent after the off push returned"
        );
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert!(
        gone_within(harness_pid, Duration::from_secs(10)),
        "the host that still queued the answer was not ended"
    );
}
