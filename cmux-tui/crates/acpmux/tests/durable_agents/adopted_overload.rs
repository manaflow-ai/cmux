//! A turn an overload cuts after a daemon restart adopted it goes on by itself, once.
//!
//! Census of 2026-11-24 (overload-census): 22 chats on 9 lane VMs sat idle 12 to 366 minutes
//! after a 503 pool, 529 or 502 ended a turn the daemon had adopted across a restart
//! (`host_adopted` mid-turn in 20 of the 20 traced). The adopted turn's end continued nothing
//! (`hosts.rs`, "A recovered turn is not continued"), while the same error on a turn the daemon
//! started would have been retried. Leo: "i wonder what will happen with claudes on vms... do
//! they get stranded!?"
use super::*;

#[tokio::test]
async fn an_overload_after_a_restart_adopted_the_turn_goes_on_once() {
    let mut daemon = Daemon::new("adopted-overload", "approve-all");
    daemon.sigterm();
    std::fs::write(
        daemon.home.join("config.json"),
        json!({"harnesses": {"fake": {"argv": ["python3", FAKE]}},
            "defaultHarness": "fake", "permissionPolicy": "approve-all",
            "autoResumeDelaysMs": [50, 50]})
        .to_string(),
    )
    .unwrap();
    daemon.start();
    let session = new_session(&daemon).await;
    let gate = daemon.home.join("gate");
    make_fifo(&gate);
    let mut client = daemon.rpc().await;
    client
        .send(
            "session/prompt",
            json!({"sessionId": session,
                "prompt": [{"type": "text", "text": format!("overload-gate: {}", gate.display())}],
                "_meta": {"acpmux": {"promptId": "p-adopted"}}}),
        )
        .await;
    daemon.wait_event(&session, "before-gate chunk", |e| chunk(e, "before-gate"));
    let harness_pid = daemon.host_record(&session)["harness_pid"].as_i64().unwrap();

    // The daemon restarts mid-turn; its agent host outlives it and the next daemon adopts it.
    daemon.sigkill();
    drop(client);
    assert!(alive(harness_pid), "the agent died with the daemon");
    daemon.start();
    daemon.wait_event(&session, "host_adopted", |e| e["kind"] == "host_adopted");
    // Only then the provider overloads.
    std::fs::write(&gate, b"go").unwrap();

    let cut = daemon.wait_event(&session, "the cut turn's result", |e| {
        e["kind"] == "turn_result" && e["msg"]["promptId"] == "p-adopted"
    });
    assert_eq!(cut["msg"]["status"], "failed", "{cut}");
    let scheduled = daemon.wait_event(&session, "its continuation scheduled", |e| {
        e["kind"] == "auto_resume_scheduled"
    });
    assert_eq!(scheduled["msg"]["reason"], "capacity", "{scheduled}");
    assert_eq!(scheduled["msg"]["promptId"], "p-adopted", "{scheduled}");
    assert_eq!(scheduled["msg"]["turnId"], cut["msg"]["turnId"], "{scheduled}");
    let resumed = daemon.wait_event(&session, "the continuation's result", |e| {
        e["kind"] == "turn_result" && e["msg"]["promptId"] == "p-adopted~resume-1"
    });
    assert_eq!(resumed["msg"]["status"], "completed", "{resumed}");

    tokio::time::sleep(Duration::from_millis(300)).await;
    let events = daemon.events(&session);
    let started: Vec<&str> = events
        .iter()
        .filter(|e| e["kind"] == "turn_started")
        .filter_map(|e| e["msg"]["promptId"].as_str())
        .collect();
    assert_eq!(started, ["p-adopted", "p-adopted~resume-1"], "one continuation, no repeat");
    assert!(
        !events
            .iter()
            .any(|e| e["kind"] == "auto_resume_settled" && e["msg"]["why"] == "not_retried"),
        "the adopted cut settled unretried"
    );
}
