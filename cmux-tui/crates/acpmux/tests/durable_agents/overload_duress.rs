//! Duress: sixteen chats in one 529 storm, with the daemon killed twice, each come back once.
//!
//! Leo, 2026-11-24: "i wonder what will happen with claudes on vms... do they get stranded!? what
//! do we do ab stops and wakeups... is our pausing good and is our logistics for being able to
//! durably wake them up good?" Each chat's turn is mid-flight when the daemon is SIGKILLed; the
//! next daemon adopts every agent host; then every provider call fails at once with "API Error:
//! Repeated 529 Overloaded errors"; while their continuations wait, the daemon is SIGKILLed again.
//! The third daemon restores each wait from disk and sends each continuation once.
//! It prints one `DURESS` line (how many came back, how fast after the last restart) before it
//! asserts, so a failing run still reports its number.
use super::*;

const CHATS: usize = 16;

#[tokio::test]
async fn sixteen_chats_in_a_529_storm_across_two_daemon_kills_each_come_back_once() {
    let mut daemon = Daemon::new("overload-duress", "approve-all");
    daemon.sigterm();
    std::fs::write(
        daemon.home.join("config.json"),
        json!({"harnesses": {"fake": {"argv": ["python3", FAKE]}},
            "defaultHarness": "fake", "permissionPolicy": "approve-all",
            "autoResumeDelaysMs": [1500, 1500]})
        .to_string(),
    )
    .unwrap();
    daemon.start();
    let mut client = daemon.rpc().await;
    let mut chats = Vec::new();
    for i in 0..CHATS {
        let session = new_session(&daemon).await;
        let gate = daemon.home.join(format!("gate-{i}"));
        make_fifo(&gate);
        client
            .send(
                "session/prompt",
                json!({"sessionId": session,
                    "prompt": [{"type": "text", "text": format!("overload-gate: {}", gate.display())}],
                    "_meta": {"acpmux": {"promptId": format!("p-{i}")}}}),
            )
            .await;
        chats.push((session, gate, format!("p-{i}")));
    }
    for (session, _, _) in &chats {
        daemon.wait_event(session, "before-gate chunk", |e| chunk(e, "before-gate"));
    }

    // Kill one: mid-turn. The agent hosts outlive it; the next daemon adopts them.
    daemon.sigkill();
    drop(client);
    daemon.start();
    for (session, _, _) in &chats {
        daemon.wait_event(session, "host_adopted", |e| e["kind"] == "host_adopted");
    }
    // The storm: every provider call fails at once.
    let storm: Vec<_> = chats
        .iter()
        .map(|(_, gate, _)| {
            let gate = gate.clone();
            std::thread::spawn(move || std::fs::write(gate, b"go").unwrap())
        })
        .collect();
    for t in storm {
        t.join().unwrap();
    }
    for (session, _, _) in &chats {
        daemon.wait_event(session, "its continuation scheduled", |e| {
            e["kind"] == "auto_resume_scheduled"
        });
    }

    // Kill two: mid-wait, before any continuation fires (1.5 s).
    daemon.sigkill();
    let restarted = Instant::now();
    daemon.start();
    let mut back_ms = Vec::new();
    let deadline = Instant::now() + Duration::from_secs(60);
    let mut pending: Vec<&(String, std::path::PathBuf, String)> = chats.iter().collect();
    while !pending.is_empty() && Instant::now() < deadline {
        pending.retain(|(session, _, prompt)| {
            let resume = format!("{prompt}~resume-1");
            let done = daemon.events(session).iter().any(|e| {
                e["kind"] == "turn_result"
                    && e["msg"]["promptId"] == resume.as_str()
                    && e["msg"]["status"] == "completed"
            });
            if done {
                back_ms.push(restarted.elapsed().as_millis());
            }
            !done
        });
        std::thread::sleep(Duration::from_millis(25));
    }
    tokio::time::sleep(Duration::from_millis(2000)).await;
    let (mut repeats, mut unretried) = (0, 0);
    for (session, _, prompt) in &chats {
        let events = daemon.events(session);
        let resume = format!("{prompt}~resume-1");
        let starts = events
            .iter()
            .filter(|e| e["kind"] == "turn_started")
            .filter_map(|e| e["msg"]["promptId"].as_str())
            .filter(|p| p.starts_with(&format!("{prompt}~resume-")))
            .collect::<Vec<_>>();
        repeats += starts.iter().filter(|p| **p != resume).count()
            + starts.iter().filter(|p| **p == resume).count().saturating_sub(1);
        unretried += events
            .iter()
            .filter(|e| e["kind"] == "auto_resume_settled" && e["msg"]["why"] == "not_retried")
            .count();
    }
    back_ms.sort_unstable();
    let at = |q: f64| back_ms.get(((back_ms.len() as f64 - 1.0) * q) as usize).copied();
    eprintln!(
        "DURESS chats={CHATS} back={} stranded={} repeats={repeats} not_retried={unretried} \
         p50_ms={:?} max_ms={:?} (after the second kill; continuation delay 1500 ms)",
        back_ms.len(),
        pending.len(),
        at(0.5),
        at(1.0)
    );
    assert!(pending.is_empty(), "stranded: {:?}", pending.iter().map(|c| &c.0).collect::<Vec<_>>());
    assert_eq!(repeats, 0, "a continuation went out twice");
    assert_eq!(unretried, 0, "a cut settled unretried");
}
