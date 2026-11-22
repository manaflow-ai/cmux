//! A restart while the host's last entries are ones the log keeps nowhere (Claude Code's raw
//! `stream_event` deltas, `hub/tap.rs`): the previous daemon acked them and the host dropped
//! them, so none comes back in the replay. Adoption waited out `REPLAY_STALL` (10 s) for them,
//! the log's last `hostSeq` being below the host's ack: a carrier fault run on 2026-11-22 read
//! the daemon's "startup complete" 10.0 s after "agents may start".

use super::*;

#[tokio::test]
async fn adoption_does_not_wait_for_entries_the_log_keeps_nowhere() {
    let mut daemon = Daemon::claude_router("unlogged-tail", &[]);
    let session = new_session(&daemon).await;
    let mut client = daemon.rpc().await;
    // "slow-stop" streams one delta ("working", no `message_start` before it, so not logged)
    // and runs on until an interrupt: the host's last entry is that delta.
    client
        .send(
            "session/prompt",
            json!({"sessionId": session, "prompt": [{"type": "text", "text": "slow-stop"}]}),
        )
        .await;
    daemon.wait_event(&session, "the turn's words", |e| chunk(e, "working"));
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
