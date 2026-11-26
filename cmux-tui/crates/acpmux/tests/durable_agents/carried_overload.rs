//! A carried turn a restart cut (`hub/carried_turn.rs` `recover_carried`), then an overload cut
//! after the next daemon ran it on, goes on by itself, once. Before, a recovered carried turn
//! was never continued, so a 529 there stranded the chat as `adopted_overload.rs`'s turn did.
//! Leo, 2026-11-24: "i wonder what will happen with claudes on vms... do they get stranded!?"
use super::*;

#[tokio::test]
async fn a_recovered_carried_turn_an_overload_cut_goes_on_once() {
    let mut daemon = Daemon::claude_router("carry-overload", &[]);
    daemon.sigterm();
    let config_path = daemon.home.join("config.json");
    let mut config: Value =
        serde_json::from_str(&std::fs::read_to_string(&config_path).unwrap()).unwrap();
    config["autoResumeDelaysMs"] = json!([50, 50]);
    std::fs::write(&config_path, config.to_string()).unwrap();
    // This daemon holds a carried turn before its prompt goes out; the next one does not.
    daemon.env.push(("ACPMUX_TEST_CARRY_HOLD_MS".into(), "60000".into()));
    daemon.start();
    let session = new_session(&daemon).await;
    let gate = daemon.home.join("carry-gate");
    let open = |n: u32, how: &str| {
        let tmp = gate.with_extension(format!("{n}.tmp"));
        std::fs::write(&tmp, how).unwrap();
        std::fs::rename(&tmp, format!("{}.{n}", gate.display())).unwrap();
    };
    let mut client = daemon.rpc().await;
    let text = format!("gated: {}", gate.display());
    client
        .send(
            "session/prompt",
            json!({"sessionId": session, "prompt": [{"type": "text", "text": text}]}),
        )
        .await;
    daemon.wait_event(&session, "the first turn's words", |e| chunk(e, "gated turn 1"));
    let mut steerer = daemon.rpc().await;
    steerer
        .send(
            "session/prompt",
            json!({"sessionId": session, "prompt": [{"type": "text", "text": "LATE-1"}], "_meta": {"acpmux": {"steer": true, "promptId": "p-late"}}}),
        )
        .await;
    daemon.wait_event(&session, "the steer on Claude's stdin", |e| {
        e["kind"] == "claude.stdin" && e["msg"].to_string().contains("LATE-1")
    });
    open(1, "end");
    let carried = daemon.wait_event(&session, "the carried turn's start", |e| {
        e["kind"] == "turn_started" && !e["msg"]["carried"].is_null()
    });
    let (turn_id, prompt_id) =
        (carried["msg"]["turnId"].clone(), carried["msg"]["promptId"].clone());

    daemon.sigkill();
    drop((client, steerer));
    daemon.env.clear();
    daemon.start();
    daemon.wait_event(&session, "host_adopted", |e| e["kind"] == "host_adopted");
    until_turn_restored(&daemon, &session).await;
    // Only now the provider overloads, in the carried turn the new daemon ran on.
    open(2, "overload");

    let cut = daemon.wait_event(&session, "the carried turn's result", |e| {
        e["kind"] == "turn_result" && e["msg"]["turnId"] == turn_id
    });
    assert_eq!(cut["msg"]["status"], "failed", "{cut}");
    let scheduled = daemon.wait_event(&session, "its continuation scheduled", |e| {
        e["kind"] == "auto_resume_scheduled"
    });
    assert_eq!(scheduled["msg"]["reason"], "capacity", "{scheduled}");
    assert_eq!(scheduled["msg"]["turnId"], turn_id, "{scheduled}");
    assert_eq!(scheduled["msg"]["promptId"], prompt_id, "{scheduled}");
    let resume_id = format!("{}~resume-1", prompt_id.as_str().unwrap());
    let resumed = daemon.wait_event(&session, "the continuation's result", |e| {
        e["kind"] == "turn_result" && e["msg"]["promptId"] == resume_id.as_str()
    });
    assert_eq!(resumed["msg"]["status"], "completed", "{resumed}");
    // Once: no second continuation, and nothing settled it as not retried.
    tokio::time::sleep(Duration::from_millis(500)).await;
    let events = daemon.events(&session);
    let started: Vec<&Value> = events
        .iter()
        .filter(|e| e["dir"] == "mux" && e["kind"] == "turn_started")
        .map(|e| &e["msg"]["promptId"])
        .collect();
    assert_eq!(
        started.iter().filter(|p| p.as_str() == Some(resume_id.as_str())).count(),
        1,
        "{started:?}"
    );
    assert!(
        !started.iter().any(|p| p.as_str().is_some_and(|p| p.ends_with("~resume-2"))),
        "{started:?}"
    );
    let settled = events
        .iter()
        .find(|e| e["kind"] == "auto_resume_settled" && e["msg"]["why"] == "not_retried");
    assert!(settled.is_none(), "{settled:?}");
}
