//! A fenced line a daemon handed its agent's host, still queued there when the daemon restarts
//! (#23322 a3 fence, the residual risk of #26241): the host logs a line before its stdin writer
//! writes it, so the next daemon must hold it again from its log, and an MDM off push waits for
//! it, or cuts it by ending the host, before it returns.

use super::*;

/// An ancestor's answer, resent under its fence after one restart, waits in the host's stdin
/// writer (the harness reads nothing until `reads-again` exists, and the answer is larger than
/// the pipe). The daemon is then stopped again, with MDM unset. The stopped daemon, the session
/// and the harness's pid.
async fn an_answer_queued_in_its_host(tag: &str) -> (Daemon, String, i64) {
    let mut daemon = Daemon::new(tag, "ask");
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
    (daemon, session, harness_pid)
}

/// Once the off push returned, the harness reads again: it never gets the answer checked under
/// the old bound, and the host that still queued it was ended.
async fn the_queued_answer_never_arrives(daemon: &Daemon, session: &str, harness_pid: i64) {
    std::fs::write(daemon.home.join("reads-again"), "").unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline {
        let got = daemon.events(session).iter().any(|e| chunk(e, "chose yes"));
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

/// The residual risk named on #26241: the daemon after the resend adopts the host, whose writer
/// still holds the answer; then MDM's off is pushed. Before the push returns, the answer is
/// written or can never be.
#[tokio::test]
async fn an_off_push_after_a_restart_cuts_a_fenced_line_its_host_still_queues() {
    let (mut daemon, session, harness_pid) = an_answer_queued_in_its_host("rfence").await;
    daemon.start();
    let adopted = || daemon.events(&session).iter().filter(|e| e["kind"] == "host_adopted").count();
    let deadline = Instant::now() + Duration::from_secs(30);
    while adopted() < 2 {
        assert!(Instant::now() < deadline, "the host was not adopted again");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    let pushed = daemon.rpc().await.call("_acpmux/chat_settings", mdm_off_push()).await;
    assert_eq!(pushed["applied"], true, "{pushed}");
    the_queued_answer_never_arrives(&daemon, &session, harness_pid).await;
}

/// Review round 3: the daemon after the resend can not read the host records, so it adopts
/// nothing. An off push still waits until it can end that host, then ends it.
#[tokio::test]
async fn an_off_push_waits_for_a_host_whose_records_could_not_be_read_at_adoption() {
    let (mut daemon, session, harness_pid) = an_answer_queued_in_its_host("rfencerec").await;
    let failing = daemon.home.join("records-fail");
    std::fs::write(&failing, "").unwrap();
    daemon.env.push(("ACPMUX_TEST_HOST_RECORDS_FAIL_FILE".into(), failing.display().to_string()));
    daemon.start();
    let mut rpc = daemon.rpc().await;
    let push = tokio::spawn(async move { rpc.call("_acpmux/chat_settings", mdm_off_push()).await });
    tokio::time::sleep(Duration::from_secs(3)).await;
    assert!(!push.is_finished(), "an off push returned while a host it could not read ran on");
    std::fs::remove_file(&failing).unwrap();
    let pushed = tokio::time::timeout(Duration::from_secs(30), push)
        .await
        .expect("the off push returned once the host could be ended")
        .unwrap();
    assert_eq!(pushed["applied"], true, "{pushed}");
    the_queued_answer_never_arrives(&daemon, &session, harness_pid).await;
}

/// Review round 4: the daemon after the resend can not list its chats (a link among them), and
/// its adoption is held back (`ACPMUX_TEST_DELAY_LOAD_LOGS_MS`). An off push pushed at once still
/// waits for that adoption, which ends the host no chat it knows names, so the push never returns
/// while that host can still write the answer.
#[tokio::test]
async fn an_off_push_waits_for_adoption_when_the_chats_could_not_be_listed() {
    let (mut daemon, session, _) = an_answer_queued_in_its_host("rfencelist").await;
    let host_pid = daemon.host_record(&session)["host_pid"].as_i64().unwrap();
    let sessions = daemon.home.join("sessions");
    std::os::unix::fs::symlink(&daemon.home, sessions.join("a-link")).unwrap();
    daemon.env.push(("ACPMUX_TEST_DELAY_LOAD_LOGS_MS".into(), "3000".into()));
    daemon.start();
    let pushed = daemon.rpc().await.call("_acpmux/chat_settings", mdm_off_push()).await;
    assert_eq!(pushed["applied"], true, "{pushed}");
    assert!(
        gone_within(host_pid, Duration::from_millis(500)),
        "an off push returned while a host the chat list hid could still write its line"
    );
    std::fs::remove_file(sessions.join("a-link")).unwrap();
}
