//! A forced turn end (`cancel.rs` `end_turn_forced`) against what can go wrong around it: a cancel
//! that cannot be written, a person's Stop since it was decided (cmux#47879).

use super::*;

/// A hub whose chat runs turn `turn-1` (set by hand) on its stand-in agent.
async fn running_turn() -> (Arc<Hub>, Arc<Session>) {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: crate::config::Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}}, "defaultHarness": "fake"}))
    .unwrap();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let req = NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let session = hub.new_session(req).await.unwrap();
    *session.turn.lock().unwrap() =
        Some(TurnInfo::prompted("person", "hi", "turn-1", "p-1", Control::Local));
    (hub, session)
}

fn stalled() -> Value {
    json!({"stopReason": "cancelled", "_meta": {"acpmux": {"stalledMs": 5}}})
}

/// The cancel cannot be written (the agent's input is held by a writer that never finishes): the
/// turn is not ended meanwhile, and Stop's escalation ends it, restarting the agent, still with
/// its cause.
#[tokio::test]
async fn a_forced_end_whose_cancel_is_never_written_ends_through_the_escalation() {
    let (hub, session) = running_turn().await;
    let writer = session.input_handoff.clone().lock_owned().await;
    hub.end_turn_forced(&session, "turn-1", stalled(), |_| true).expect("the end starts");
    tokio::time::sleep(std::time::Duration::from_millis(500)).await;
    assert!(session.steer_end.borrow().is_none(), "the turn ended before its agent let go");
    assert!(super::forced_ending(&session, "turn-1"));
    assert!(super::is_stopping(&session, "turn-1"), "an agent's message would go into it");

    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
    let answer = loop {
        if let Some((turn, answer)) = session.steer_end.borrow().clone() {
            assert_eq!(turn, "turn-1");
            break answer;
        }
        assert!(std::time::Instant::now() < deadline, "the escalation never ended the turn");
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    };
    drop(writer);
    let ended = super::settle_forced_end(&session, "turn-1", Ok(answer)).unwrap();
    assert_eq!(ended.pointer("/_meta/acpmux/stalledMs"), Some(&json!(5)), "{ended}");
    assert_eq!(ended.pointer("/_meta/acpmux/restarted"), Some(&json!(true)), "{ended}");
    assert!(Hub::stalled_error(&ended).is_some());
    let steps: Vec<String> = hub
        .events(&session.id, 0, 10_000)
        .unwrap()
        .into_iter()
        .filter(|e| e.kind == "stop_escalated")
        .filter_map(|e| e.msg["step"].as_str().map(str::to_owned))
        .collect();
    assert_eq!(steps, ["interrupt", "restart"]);
    assert!(!super::forced_ending(&session, "turn-1"), "taken by the turn's end");
}

/// However the harness answers, the turn ends with the cause; a person's Stop since wins.
#[tokio::test]
async fn a_forced_end_keeps_its_cause_unless_a_stop_came_since() {
    let (hub, session) = running_turn().await;
    hub.end_turn_forced(&session, "turn-1", stalled(), |_| false);
    tokio::task::yield_now().await;
    tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    assert!(!super::forced_ending(&session, "turn-1"), "not ours any more: not carried out");

    for natural in [
        Ok(json!({"stopReason": "cancelled"})),
        Ok(json!({"stopReason": "end_turn"})),
        Err(RpcError::internal("agent process closed")),
    ] {
        *session.forced_end.lock().unwrap() = Some(super::ForcedEnd {
            turn_id: "turn-1".into(),
            answer: stalled(),
            cancels: session.cancels.load(Ordering::SeqCst),
        });
        let ended = super::settle_forced_end(&session, "turn-1", natural).unwrap();
        assert_eq!(ended, stalled());
    }
    // Another turn's end reads nothing of it.
    *session.forced_end.lock().unwrap() = Some(super::ForcedEnd {
        turn_id: "turn-1".into(),
        answer: stalled(),
        cancels: session.cancels.load(Ordering::SeqCst),
    });
    let other = super::settle_forced_end(&session, "turn-2", Ok(json!({"stopReason": "end_turn"})));
    assert_eq!(other.unwrap()["stopReason"], "end_turn");
    // A person's Stop since: the turn ends as stopped.
    session.cancels.fetch_add(1, Ordering::SeqCst);
    let stopped =
        super::settle_forced_end(&session, "turn-1", Ok(json!({"stopReason": "cancelled"})));
    assert_eq!(stopped.unwrap(), json!({"stopReason": "cancelled"}));
    assert!(session.forced_end.lock().unwrap().is_none());
}
