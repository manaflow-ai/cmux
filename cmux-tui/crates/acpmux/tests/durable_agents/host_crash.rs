//! The agent holder (cmuxterm-hq `docs/design/process-sharing.md`, "Agent sessions"): a SIGKILL of a
//! session's `__agent-host` mid-turn no longer cuts the turn. The daemon keeps a copy of the
//! harness's stdio pipes and of the host's output ring, so the harness never sees its pipes close;
//! a replacement host adopts them and replays the ring from the last line the daemon logged.
//!
//! Before, nothing else held the pipes: the harness died on its next write, the turn failed with
//! `agent.exited` and the hub sent the "interrupted" auto-resume prompt to a fresh agent.

use super::*;

/// Chunks the stand-in agent streams (`ticking:N:MS`, `tests/fake_agent.py`) and their spacing.
const CHUNKS: usize = 60;
const CHUNK_MS: u64 = 50;

/// Which chunk `e` is, when it is one of the turn's (`tick<i> `).
fn tick(e: &Value) -> Option<usize> {
    if e["msg"]["params"]["update"]["sessionUpdate"] != "agent_message_chunk" {
        return None;
    }
    let text = e["msg"]["params"]["update"]["content"]["text"].as_str()?;
    text.strip_prefix("tick")?.trim_end().parse().ok()
}

fn ticks(daemon: &Daemon, session: &str) -> Vec<usize> {
    daemon.events(session).iter().filter_map(tick).collect()
}

/// The answer to request `id` on `rpc`, read off the stream (its notifications are skipped).
async fn answer(rpc: &mut Rpc, id: i64, within: Duration) -> Option<Value> {
    let deadline = Instant::now() + within;
    loop {
        let left = deadline.checked_duration_since(Instant::now())?;
        let line = tokio::time::timeout(left, rpc.lines.next_line()).await.ok()?.ok()??;
        let v: Value = serde_json::from_str(&line).ok()?;
        if v.get("id") == Some(&json!(id)) {
            return Some(v);
        }
    }
}

#[tokio::test]
async fn agent_host_sigkill_mid_turn_keeps_the_harness_and_the_turn() {
    sigkill_mid_turn("hostkill", &[("ACPMUX_AGENT_HOLDER", "1")]).await;
}

/// The agent holder is on by default: with no switch set, a host crash still keeps the turn.
#[tokio::test]
async fn agent_host_sigkill_mid_turn_keeps_the_turn_by_default() {
    sigkill_mid_turn("hostkilld", &[]).await;
}

async fn sigkill_mid_turn(tag: &str, env: &[(&str, &str)]) {
    let daemon = Daemon::with_env(tag, "approve-all", env);
    let session = new_session(&daemon).await;
    let mut client = daemon.rpc().await;
    let prompt = format!("ticking:{CHUNKS}:{CHUNK_MS}");
    let id = client
        .send(
            "session/prompt",
            json!({"sessionId": session, "prompt": [{"type": "text", "text": prompt}]}),
        )
        .await;
    daemon.wait_event(&session, "the turn's fifth chunk", |e| tick(e) == Some(5));
    let host = daemon.host_record(&session);
    let host_pid = host["host_pid"].as_i64().unwrap();
    let harness_pid = host["harness_pid"].as_i64().unwrap();
    let before = ticks(&daemon, &session).into_iter().max().unwrap_or(0);

    let killed = Instant::now();
    // SAFETY: the session's host by the pid its record names; this test's own agent.
    assert_eq!(unsafe { libc::kill(host_pid as i32, libc::SIGKILL) }, 0, "SIGKILL the host");
    // How long the output stopped: the first chunk after the kill that the log has.
    let mut recovery_ms = None;
    while killed.elapsed() < Duration::from_secs(20) {
        if ticks(&daemon, &session).into_iter().any(|t| t > before + 1) {
            recovery_ms = Some(killed.elapsed().as_millis());
            break;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    let reply = answer(&mut client, id, Duration::from_secs(30)).await;
    let harness_alive = alive(harness_pid);

    let seen = ticks(&daemon, &session);
    let distinct: std::collections::BTreeSet<usize> = seen.iter().copied().collect();
    let lost = (0..CHUNKS).filter(|i| !distinct.contains(i)).count();
    let repeated = seen.len() - distinct.len();
    let in_order = seen.windows(2).all(|w| w[0] < w[1]);
    let events = daemon.events(&session);
    let resumed: Vec<&Value> = events
        .iter()
        .filter(|e| {
            e["kind"].as_str().is_some_and(|k| k.starts_with("auto_resume"))
                || e["msg"]["params"]["_meta"]["provenance"]["kind"] == "auto_resume"
                || e["msg"]["_meta"]["provenance"]["kind"] == "auto_resume"
        })
        .collect();
    let completed = reply.as_ref().is_some_and(|r| r["result"]["stopReason"] == "end_turn");
    let turns_cut = usize::from(!completed || !resumed.is_empty());
    println!(
        "AGENT-HOST-CRASH chunks_lost={lost} chunks_repeated={repeated} turns_cut={turns_cut} recovery_ms={} harness_alive={harness_alive}",
        recovery_ms.map_or_else(|| "none".to_owned(), |ms| ms.to_string())
    );

    assert!(harness_alive, "the harness died with its host");
    assert!(completed, "the turn was cut: {reply:?}");
    assert_eq!(lost, 0, "chunks lost: {seen:?}");
    assert_eq!(repeated, 0, "chunks repeated: {seen:?}");
    assert!(in_order, "chunks out of order: {seen:?}");
    assert!(resumed.is_empty(), "an auto-resume prompt was sent: {resumed:#?}");
    let result = daemon.wait_event(&session, "turn_result", |e| e["kind"] == "turn_result");
    assert_eq!(result["msg"]["status"], "completed", "{result}");

    // The session takes a next prompt, on the same harness.
    let reply = client
        .call(
            "session/prompt",
            json!({"sessionId": session, "prompt": [{"type": "text", "text": "hello again"}]}),
        )
        .await;
    assert_eq!(reply["stopReason"], "end_turn", "{reply}");
    assert_eq!(
        daemon.host_record(&session)["harness_pid"].as_i64(),
        Some(harness_pid),
        "a second agent replaced the first"
    );
    assert!(alive(harness_pid), "the harness ended after the next prompt");
}
