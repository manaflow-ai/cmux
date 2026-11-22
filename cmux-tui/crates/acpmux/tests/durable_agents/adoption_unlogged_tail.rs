//! A restart while the host's last entries are ones the log keeps nowhere (Claude Code's raw
//! `stream_event` deltas, `hub/tap.rs`): the previous daemon acked them and the host dropped
//! them, so none comes back in the replay. Adoption waited out `REPLAY_STALL` (10 s) for them,
//! the log's last `hostSeq` being below the host's ack: a carrier fault run on 2026-11-22 read
//! the daemon's "startup complete" 10.0 s after "agents may start".

use super::*;

#[tokio::test]
async fn adoption_does_not_wait_for_entries_the_log_keeps_nowhere() {
    // Each turn's result asks Claude Code for its /context; the answer is kept nowhere (its
    // translated breakdown is), so an idle chat's last host entry is one the log does not hold.
    let mut daemon = Daemon::claude_router("unlogged-tail", &[("FAKE_CLAUDE_CONTEXT", "1")]);
    let session = new_session(&daemon).await;
    let mut client = daemon.rpc().await;
    client
        .call(
            "session/prompt",
            json!({"sessionId": session, "prompt": [{"type": "text", "text": "hello"}]}),
        )
        .await;
    daemon.wait_event(&session, "the turn's context breakdown", |e| {
        !e["msg"]["params"]["update"]["_meta"]["acpmux"]["contextBreakdown"].is_null()
    });
    // The daemon acks what it read; give the ack time to reach the host.
    std::thread::sleep(Duration::from_secs(1));
    daemon.sigkill();
    drop(client);
    let started = Instant::now();
    daemon.start();
    daemon.wait_event(&session, "host_adopted", |e| e["kind"] == "host_adopted");
    let took = started.elapsed();
    assert!(
        took < Duration::from_secs(6),
        "adoption took {took:?}: it waited for entries the host had already dropped"
    );
}
