//! A message sent into a running turn (the Chief's `tell`: a steer with `steerOnly`) reaches
//! the agent at once, never at the end of the turn (user 2026-10-20: a tell sat as "Queued,
//! sends after this turn"). Claude Code reads a steer only at its next tool boundary, so a
//! steer it has not read within `steerReadDeadlineMs` (default 500 ms) stops the running tool:
//! the turn goes on and the agent reads every waiting message, in order. Codex takes a steer at
//! once. Each tell's `session/prompt` answers "steered" when the agent read it.
//!
//! Timings go to `<repo>/.build/tell-delivery.jsonl` (the fleet step returns it).

use super::busy_prompt::{Inbox, client, harnesses, hub_with, text_prompt};
use super::*;
use std::io::Write;
use std::time::Instant;

/// Longest a tell may take from its send to the agent reading it.
const DELIVERY_BUDGET: Duration = Duration::from_millis(1000);

fn timings(line: Value) {
    let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../.build");
    let _ = std::fs::create_dir_all(&dir);
    if let Ok(mut f) =
        std::fs::OpenOptions::new().create(true).append(true).open(dir.join("tell-delivery.jsonl"))
    {
        let _ = writeln!(f, "{line}");
    }
}

#[tokio::test]
async fn tells_during_a_long_tool_run_are_read_within_a_second_in_order_none_lost() {
    for (name, profile, _) in harnesses().into_iter().filter(|(n, _, _)| *n != "acp") {
        let hub = hub_with(profile, |_| {});
        let mut c = client(&hub).await;
        let s =
            c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
        let id = s["sessionId"].as_str().unwrap().to_owned();
        let turn = c
            .send(method::SESSION_PROMPT, text_prompt(&id, "long-tool", "p-long", json!({})))
            .await;
        let sid = id.clone();
        c.wait_for(method::SESSION_UPDATE, move |p| {
            p["sessionId"] == sid.as_str() && p["update"]["sessionUpdate"] == "agent_message_chunk"
        })
        .await;

        // Five tells, as the Chief sends them, each once acpmux took the one before.
        let mut inbox = Inbox::default();
        let mut sent = Vec::new();
        for k in 0..5 {
            let pid = format!("tell-{k}");
            let at = Instant::now();
            let rid = c
                .send(
                    method::SESSION_PROMPT,
                    text_prompt(
                        &id,
                        &format!("tell {k}"),
                        &pid,
                        json!({"steer": true, "steerOnly": true}),
                    ),
                )
                .await;
            let acc = inbox.accepted(&mut c, &pid).await;
            assert_eq!(acc["steer"], true, "{name} {pid}: went into the turn: {acc}");
            sent.push((pid, rid, at, at.elapsed()));
        }
        // Each is answered "steered" once the agent read it.
        let mut read = Vec::new();
        for (pid, rid, at, accepted) in &sent {
            let (arrived, r) = inbox.answer(&mut c, *rid).await;
            let r = r.unwrap_or_else(|e| panic!("{name} {pid}: not delivered: {e}"));
            let took = arrived.duration_since(*at);
            assert_eq!(r["stopReason"], "steered", "{name} {pid}: {r}");
            assert!(took <= DELIVERY_BUDGET, "{name} {pid}: read {took:?} after its send");
            timings(
                json!({"harness": name, "tell": pid, "acceptedMs": accepted.as_secs_f64() * 1000.0, "readMs": took.as_secs_f64() * 1000.0}),
            );
            read.push(took);
        }
        // The agent read them in the order they were sent, none lost or twice. A steer is
        // answered when the agent reads it; its "read:" line can stream a moment after.
        let text = inbox.text_with(&mut c, "read: tell 4").await;
        let events = hub.events(&id, 0, 5000).unwrap();
        let order: Vec<&str> = text.lines().filter_map(|l| l.strip_prefix("read: ")).collect();
        assert_eq!(order, ["tell 0", "tell 1", "tell 2", "tell 3", "tell 4"], "{name}: {text}");
        let shown: Vec<&str> = events
            .iter()
            .filter(|e| e.kind == "user_message")
            .filter_map(|e| e.msg["promptId"].as_str())
            .collect();
        assert_eq!(shown, ["p-long", "tell-0", "tell-1", "tell-2", "tell-3", "tell-4"], "{name}");
        assert!(!events.iter().any(|e| e.kind == "queued"), "{name}: a tell waited in the queue");
        // Codex keeps running its tool: stop the turn to end the test.
        if hub.resolve(&id).unwrap().turn().is_some() {
            let _ = hub.cancel(&hub.resolve(&id).unwrap()).await;
        }
        let _ = inbox.answer(&mut c, turn).await;
        hub.shutdown_all().await;
        let worst = read.iter().max().unwrap();
        eprintln!("TELL-DELIVERY {name}: worst {worst:?}");
    }
}
