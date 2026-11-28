use super::*;

/// A chat on `family` with stop condition `condition`, its goal as Codex reported it (`status`).
fn chat(family: &str, condition: Option<&str>, status: Option<&str>) -> (Arc<Hub>, Arc<Session>) {
    let cfg = crate::config::Config::default();
    let store = Box::new(crate::store::MemoryStore::default());
    let hub = Hub::new(cfg, store);
    let mut meta: SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "goal-stall", "name": "goal-stall",
        "harness": family, "cwd": "/tmp", "status": "running", "createdAt": 1, "updatedAt": 1,
    }))
    .unwrap();
    meta.family = Some(family.to_owned());
    meta.stop_condition = condition.map(str::to_owned);
    meta.goal = status.and_then(|s| {
        crate::goal::GoalState::from_value(
            &json!({"objective": "ship it", "status": s}),
            Some(family),
        )
    });
    let session = hub.make_session(meta);
    (hub, session)
}

const HOUR: u64 = 3_600_000_000_000;

/// A Codex chat whose goal is open gets [`GOAL_PERIOD`], not the 6 h default: a Codex chat read
/// `running` for 4.5 h after its model went quiet (acp-chief-issues 2026-11-27 08:25). Four
/// periods inside a tool call that has not ended, as for any turn. A chat with no goal, or a
/// goal that is done or blocked, keeps the configured period.
#[test]
fn a_chat_whose_goal_is_open_stalls_after_twenty_minutes() {
    let goal = GOAL_PERIOD.as_nanos() as u64;
    let (_hub, open) = chat("codex", Some("ship it"), Some("active"));
    assert_eq!(Hub::own_period(&open, 6 * HOUR), goal);
    open.open_tools.lock().unwrap().insert("t1".into());
    assert_eq!(Hub::own_period(&open, 6 * HOUR), goal * OPEN_TOOL_PERIODS);
    let (_hub, unreported) = chat("codex", Some("ship it"), None);
    assert_eq!(Hub::own_period(&unreported, 6 * HOUR), goal);
    // A shorter configured period stays.
    assert_eq!(Hub::own_period(&unreported, goal / 2), goal / 2);
    // A Claude Code chat's Stop hook keeps its turn going: its period stays.
    for (family, condition, status) in [
        ("claude", Some("ship it"), None),
        ("codex", None, None),
        ("codex", Some("ship it"), Some("complete")),
        ("codex", Some("ship it"), Some("blocked")),
    ] {
        let (_hub, s) = chat(family, condition, status);
        assert_eq!(Hub::own_period(&s, 6 * HOUR), 6 * HOUR, "{condition:?} {status:?}");
    }
}

/// A viewer or a busy owner does not hold a stalled turn of a chat whose goal is open: it goes on
/// by itself once ended. Any other chat keeps the hold.
#[test]
fn a_viewer_holds_no_stalled_turn_of_an_open_goal() {
    let (hub, open) = chat("codex", Some("ship it"), Some("active"));
    open.attached.store(1, Ordering::SeqCst);
    assert_eq!(hub.turn_held(&open), None);
    let (hub, plain) = chat("codex", None, None);
    plain.attached.store(1, Ordering::SeqCst);
    assert_eq!(hub.turn_held(&plain), Some(Hold::Watched));
}

/// A stalled turn of a chat whose goal is open is continued as a cut connection (`transport`);
/// any other stalled turn, and any other error, is not.
#[test]
fn a_stalled_turn_of_an_open_goal_goes_on_by_itself() {
    let answer = json!({"stopReason": "cancelled", "_meta": {"acpmux": {"stalledMs": 1_200_000}}});
    let error = Hub::stalled_error(&answer).unwrap().message;
    assert!(Hub::is_stalled_error(&error), "{error}");
    let (_hub, open) = chat("codex", Some("ship it"), Some("active"));
    assert_eq!(super::super::goal_watch::cut_cause(&open, &error), Some("transport"));
    assert_eq!(super::super::goal_watch::cut_cause(&open, "Not logged in"), None);
    let (_hub, plain) = chat("codex", None, None);
    assert_eq!(super::super::goal_watch::cut_cause(&plain, &error), None);
    let (_hub, done) = chat("codex", Some("ship it"), Some("complete"));
    assert_eq!(super::super::goal_watch::cut_cause(&done, &error), None);
}
