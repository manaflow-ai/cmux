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

/// A Chief subagent has a stop condition but no `goal_set` goal. Its "blocked on Lucas" was
/// refused ("this chat has no goal set"), so it could not say it waits, and its finish check
/// kept re-prompting it (user, 2026-11-23). Blocked and complete now work with no goal set;
/// running still needs one, which only `goal_set` gives.
#[test]
fn blocked_and_complete_work_with_no_goal_set() {
    let hub = hub();
    let session = chat(&hub);
    session.meta.lock().unwrap().stop_condition = Some("The task is landed.".into());
    assert!(hub.goal_update(&session, Reported::Running, None).is_err());
    assert!(session.meta.lock().unwrap().goal.is_none());

    let got =
        hub.goal_update(&session, Reported::Blocked, Some("waits for Lucas: push it")).unwrap();
    assert_eq!(got["objective"], "waits for Lucas: push it");
    let m = session.meta.lock().unwrap();
    let goal = m.goal.as_ref().unwrap();
    assert!(generic_goal::is_generic(goal));
    assert_ne!(goal.lifecycle(), "running", "a blocked goal gets no continuation");
    assert_eq!(generic_goal::done_when(goal), "The task is landed.");
    drop(m);

    let other = chat(&hub);
    hub.goal_update(&other, Reported::Complete, None).unwrap();
    assert_eq!(other.meta.lock().unwrap().goal.as_ref().unwrap().lifecycle(), "done");

    // A harness's own goal (Codex's) is never replaced by one.
    let planned = chat(&hub);
    let plan = crate::goal::GoalState::from_value(
        &json!({"objective": "Fix it", "status": "active"}),
        Some("codex"),
    )
    .unwrap();
    planned.meta.lock().unwrap().goal = Some(plan.clone());
    assert!(hub.goal_update(&planned, Reported::Blocked, Some("waits")).is_err());
    assert_eq!(planned.meta.lock().unwrap().goal.as_ref(), Some(&plan));
}
