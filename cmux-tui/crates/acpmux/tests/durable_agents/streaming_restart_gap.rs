//! A turn that keeps streaming across a restart with a gap, as an update relaunch makes one (the
//! old daemon stops when its app's bundle is replaced, the next starts when the app relaunches a
//! few seconds later): the next daemon logs the agent's new output within seconds of its start.
//! The relaunch-reconnect bench (scripts/cmux-next/bench_relaunch_reconnect.py) read the shown
//! chat's first live event 120 s after such a relaunch (manaflow-ai/cmuxterm-hq#6338).

use super::*;

fn ticks(daemon: &Daemon, session: &str) -> usize {
    let tick = |e: &Value| {
        e["msg"]["params"]["update"]["sessionUpdate"] == "agent_message_chunk"
            && e["msg"]["params"]["update"]["content"]["text"].as_str().is_some_and(|t| t.starts_with("tick"))
    };
    daemon.events(session).iter().filter(|e| tick(e)).count()
}

#[tokio::test]
async fn a_streaming_turn_logs_new_output_within_seconds_after_a_restart_with_a_gap() {
    let mut daemon = Daemon::new("stgap", "approve-all");
    let session = new_session(&daemon).await;
    let mut client = daemon.rpc().await;
    // A word every 100 ms for 5 minutes: a reply still streaming through the restart.
    client
        .send(
            "session/prompt",
            json!({"sessionId": session, "prompt": [{"type": "text", "text": "ticking:3000:100"}]}),
        )
        .await;
    daemon.wait_event(&session, "tick5", |e| chunk(e, "tick5 "));
    let host = daemon.host_record(&session);
    let harness_pid = host["harness_pid"].as_i64().unwrap();
    daemon.sigterm();
    drop(client);
    // The relaunch's gap: the agent streams on with no daemon (about 30 words).
    std::thread::sleep(Duration::from_secs(3));
    let before = ticks(&daemon, &session);
    let started = Instant::now();
    daemon.start();
    // Live again: the gap's backlog and then words the agent writes after the start, so at least
    // 30 (the backlog) plus 20 more (2 s of new output) past what the old daemon logged.
    let want = before + 50;
    let deadline = started + Duration::from_secs(60);
    while ticks(&daemon, &session) < want && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(50));
    }
    let took = started.elapsed();
    let got = ticks(&daemon, &session);
    assert!(alive(harness_pid), "the agent died across the restart");
    eprintln!("streaming restart gap: {got} ticks logged ({before} before), {:.1} s after the start", took.as_secs_f64());
    assert!(
        got >= want && took < Duration::from_secs(10),
        "the next daemon logged {} new words in {:.1} s (want {} within 10 s): the adopted turn's live output waited",
        got.saturating_sub(before),
        took.as_secs_f64(),
        want - before
    );
    daemon.rpc().await.send("session/cancel", json!({"sessionId": session})).await;
}
