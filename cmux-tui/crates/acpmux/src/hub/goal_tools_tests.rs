use super::*;

fn hub() -> Arc<Hub> {
    let mut config = Config::default();
    config.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/unused")).unwrap();
    Hub::new(config, store)
}

fn chat(hub: &Hub) -> Arc<Session> {
    let meta: SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "g", "name": "pi chat", "harness": "pi",
        "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1
    }))
    .unwrap();
    hub.store.save(&meta).unwrap();
    hub.make_session(meta)
}

fn request(objective: &str) -> GoalRequest {
    GoalRequest {
        objective: objective.into(),
        done_when: "cargo test passes".into(),
        token_budget: None,
        time_budget_minutes: None,
    }
}

/// The provenance a continuation is sent with, as `continue_goal` makes it after its step.
fn step(session: &Session) -> Value {
    let mut m = session.meta.lock().unwrap();
    let goal = m.goal.as_mut().unwrap();
    assert!(matches!(generic_goal::next_step(goal, None, now_ms()), Step::Continue(_)));
    json!({"kind": "notice", "from": SENDER, MARK: generic_goal::mark(goal)})
}

fn moved_on(result: Result<(), RpcError>) -> bool {
    result.is_err_and(|e| e.data.is_some_and(|d| d["reason"] == MOVED_ON))
}

/// A continuation that waited behind the person's prompt runs only while its goal is the
/// one it was sent for, still running. Codex review of #36413, finding F1.
#[test]
fn a_continuation_is_refused_once_its_goal_moved_on() {
    let hub = hub();
    let session = chat(&hub);
    hub.goal_set(&session, &request("Make the suite pass")).unwrap();
    let mark = step(&session);
    assert!(check_goal_mark(&session, Some(&mark)).is_ok());
    assert!(check_goal_mark(&session, None).is_ok());

    // That turn's agent reported it complete.
    hub.goal_update(&session, Reported::Complete, None).unwrap();
    assert!(moved_on(check_goal_mark(&session, Some(&mark))));

    // Running again resets its count: the older continuation is still not this goal's.
    hub.goal_update(&session, Reported::Running, None).unwrap();
    assert!(moved_on(check_goal_mark(&session, Some(&mark))));

    // A new goal replaced it.
    let mark = step(&session);
    hub.goal_set(&session, &request("Ship the docs")).unwrap();
    assert!(moved_on(check_goal_mark(&session, Some(&mark))));

    // A later turn's step sent a newer continuation.
    let older = step(&session);
    let newer = step(&session);
    assert!(moved_on(check_goal_mark(&session, Some(&older))));
    assert!(check_goal_mark(&session, Some(&newer)).is_ok());
}
