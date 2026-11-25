//! How long a home goes dark at a cmux NIGHTLY take-over: from the start of `daemon run
//! --take-over` to its ready line, while the daemon it takes over runs agents inside a tool call
//! and holds idle chats. Every one of those take-overs on Leo's NIGHTLY Mac logged "agents did not
//! stop within 1s" and "persistence still draining": the handover waited out its whole shutdown
//! budget for agents it keeps for the successor anyway. Prints each take-over's time and the p50
//! (`take_over_dark_time:` lines) so a run on the base and one on a fix compare, and fails past a
//! bound far above a healthy handover.
//!
//! Leo: "well ofc a lot of this stems from... well you guys shouldn't be showing that
//! message/shouldn't have that issue in the first place, which ive already complained about for a
//! while".

use super::*;

const RUNNING: usize = 6;
const IDLE: usize = 24;
const TAKE_OVERS: usize = 7;

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn take_over_dark_time_with_running_agents() {
    let mut daemon = Daemon::new("tvdark", "approve-all");
    let mut running = Vec::new();
    let mut clients = Vec::new();
    for i in 0..RUNNING {
        let session = new_session(&daemon).await;
        let gate = daemon.home.join(format!("d{i}"));
        make_fifo(&gate);
        let mut client = daemon.rpc().await;
        client
            .send(
                "session/prompt",
                json!({"sessionId": session,
                       "prompt": [{"type": "text", "text": format!("work-gate: {}", gate.display())}]}),
            )
            .await;
        clients.push(client);
        running.push((session, gate));
    }
    for (session, _) in &running {
        daemon.wait_event(session, "the running tool call", |e| e["kind"] == "tool_call");
    }
    drop(clients);
    for i in 0..IDLE {
        let session = new_session(&daemon).await;
        let mut rpc = daemon.rpc().await;
        let text = format!("idle chat {i}");
        rpc.call(
            "session/prompt",
            json!({"sessionId": session, "prompt": [{"type": "text", "text": text}]}),
        )
        .await;
    }
    let harness: Vec<i64> = running
        .iter()
        .map(|(s, _)| daemon.host_record(s)["harness_pid"].as_i64().unwrap())
        .collect();

    let mut took = Vec::new();
    for n in 0..TAKE_OVERS {
        let started = Instant::now();
        daemon.take_over();
        let ms = started.elapsed().as_millis();
        eprintln!("take_over_dark_time: take-over {n}: {ms} ms");
        took.push(ms);
        for (i, pid) in harness.iter().enumerate() {
            assert!(alive(*pid), "take-over {n}: running chat {i}'s agent died");
        }
        for (session, _) in &running {
            let deadline = Instant::now() + Duration::from_secs(30);
            while daemon.events(session).iter().filter(|e| e["kind"] == "host_adopted").count()
                < n + 1
            {
                assert!(Instant::now() < deadline, "take-over {n}: {session} never adopted");
                tokio::time::sleep(Duration::from_millis(50)).await;
            }
        }
    }
    for (_, gate) in &running {
        let mut writer = std::fs::OpenOptions::new()
            .write(true)
            .custom_flags(libc::O_NONBLOCK)
            .open(gate)
            .expect("the agent still waits on its gate");
        std::io::Write::write_all(&mut writer, b"go").unwrap();
    }
    for (session, _) in &running {
        daemon.wait_event(session, "the tool call's end", |e| chunk(e, "worked"));
    }
    let mut sorted = took.clone();
    sorted.sort_unstable();
    let p50 = sorted[sorted.len() / 2];
    let max = sorted[sorted.len() - 1];
    eprintln!("take_over_dark_time: all {took:?} p50 {p50} ms max {max} ms");
    // A healthy handover is well under a second; this bounds a regression, not the noise.
    assert!(p50 < 5_000, "the take-over p50 was {p50} ms: {took:?}");
}
