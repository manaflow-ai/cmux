//! A chat whose adopted host is below this build's level moves onto the installed build at its
//! next idle point, long before the idle period, and its next prompt is answered by a new host
//! (`hub/host_level.rs`). One on this build's level stays up as before. Before, a daemon update
//! left every busy chat on the host it started from, and with it the translator fix that stops
//! next-prompt suggestions after agent turns (sr2 audit, 2026-11-21: about 1,100 an hour).

use super::*;

/// A daemon with a 10-minute idle period and one answered Claude chat, restarted so the next
/// daemon adopts its host; `older` first rewrites the host's record as a build before
/// `HOST_LEVEL` wrote it (no level, another build). Returns the daemon, the chat and its harness.
async fn adopted_chat(tag: &str, older: bool) -> (Daemon, String, i64) {
    let mut daemon = Daemon::claude_router(tag, &[]);
    let session = new_session(&daemon).await;
    let prompt = json!({"sessionId": session, "prompt": [{"type": "text", "text": "hello"}]});
    let answer = daemon.rpc().await.call("session/prompt", prompt).await;
    assert_eq!(answer["stopReason"], "end_turn", "the first prompt was not answered: {answer}");
    let record = daemon.host_record(&session);
    assert_eq!(
        record["host_level"],
        acpmux::agent_host::HOST_LEVEL,
        "this build's host says its level"
    );
    let harness = record["harness_pid"].as_i64().unwrap();
    daemon.sigterm();
    if older {
        let path = daemon.home.join("hosts").join(format!("{session}.json"));
        let mut old = record.clone();
        old.as_object_mut().unwrap().remove("host_level");
        old["host_build"] = json!("1.0.0 (70fdd225f 2026-11-20)");
        std::fs::write(&path, old.to_string()).unwrap();
    }
    daemon.env.push(("ACPMUX_IDLE_CHILD_SECS".into(), "600".into()));
    daemon.start();
    daemon.wait_event(&session, "host_adopted", |e| e["kind"] == "host_adopted");
    (daemon, session, harness)
}

#[tokio::test]
async fn an_adopted_host_below_the_level_moves_at_its_next_idle_point_and_its_chat_goes_on() {
    let (daemon, session, harness) = adopted_chat("hlmove", true).await;
    // Its idle period is 10 minutes: only the move ends the harness within half a minute.
    let moved = gone_within(harness, Duration::from_secs(30));
    if !moved {
        daemon.rpc().await.call("_acpmux/kill", json!({"sessionId": session})).await;
    }
    assert!(moved, "a host below the level kept its chat on the old build while idle");
    let prompt = json!({"sessionId": session, "prompt": [{"type": "text", "text": "again"}]});
    let answer = daemon.rpc().await.call("session/prompt", prompt).await;
    assert_eq!(answer["stopReason"], "end_turn", "the moved chat did not answer: {answer}");
    let record = daemon.host_record(&session);
    assert_ne!(record["harness_pid"].as_i64().unwrap(), harness, "no new harness answered");
    assert_eq!(
        record["host_level"],
        acpmux::agent_host::HOST_LEVEL,
        "the new host is not at the level"
    );
}

#[tokio::test]
async fn an_adopted_host_at_the_level_stays_up_until_its_idle_period() {
    let (daemon, session, harness) = adopted_chat("hlstay", false).await;
    // Longer than the move's 10 s, far shorter than the 10-minute idle period.
    std::thread::sleep(Duration::from_secs(20));
    let kept = alive(harness);
    daemon.rpc().await.call("_acpmux/kill", json!({"sessionId": session})).await;
    assert!(kept, "a host at the level was ended before its idle period");
}
