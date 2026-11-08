//! Tests of `races.rs`.

use super::*;

fn test_meta(id: &str, status: &str, parent: Option<&str>) -> SessionMeta {
    let mut value = json!({
        "schema": crate::store::META_SCHEMA,
        "id": id,
        "name": id,
        "harness": "codex",
        "cwd": "/tmp",
        "status": status,
        "createdAt": 1,
        "updatedAt": 2
    });
    if let Some(parent) = parent {
        value["subsession"] = json!({
            "startedBy": parent,
            "shortName": id,
            "depth": 1,
            "offered": false
        });
    }
    serde_json::from_value(value).unwrap()
}

fn race() -> Race {
    serde_json::from_value(json!({
        "id": "019a0000000070008000000000000000", "parent": "parent", "prompt": "fix it",
        "state": "reviewing", "reviewer": {"harness": "review"},
        "reviewerSessionId": null, "winnerId": null, "reason": null,
        "createdAt": 1, "updatedAt": 1,
        "candidates": [
            {"id": "c1", "target": {"harness": "codex", "model": "sol"}, "state": "completed",
             "sessionId": "one", "cwd": "/one", "reply": "done", "error": null, "base": "base", "turnId": "turn-1"},
            {"id": "c2", "target": {"harness": "codex", "model": "astra"}, "state": "failed",
             "sessionId": "two", "cwd": "/two", "reply": null, "error": "failed", "base": "base", "turnId": "turn-2"}
        ]
    }))
    .unwrap()
}

#[test]
fn reviewer_must_choose_an_existing_completed_candidate_with_evidence() {
    let race = race();
    assert_eq!(verdict(&race, r#"{"winnerId":"c1","reason":"tests passed"}"#).unwrap().0, "c1");
    for text in [
        r#"{"winnerId":"c2","reason":"failed"}"#,
        r#"{"winnerId":"other","reason":"x"}"#,
        r#"{"winnerId":null,"reason":"none adequate"}"#,
        r#"{"winnerId":"c1","reason":" "}"#,
        "winner: c1",
    ] {
        assert!(verdict(&race, text).is_err(), "{text}");
    }
    assert!(
        verdict(&race, "```json\n{\"winnerId\":\"c1\",\"reason\":\"checked diff\"}\n```").is_ok()
    );
}

#[test]
fn statistics_count_completed_races_once_per_model() {
    let mut race = race();
    assert_eq!(statistics(&[race.clone()])["models"], json!([]));
    race.state = "completed".into();
    race.winner_id = Some("c1".into());
    let mut duplicate = race.candidates[0].clone();
    duplicate.id = "c3".into();
    race.candidates.push(duplicate);
    let stats = statistics(&[race.clone()]);
    assert_eq!(
        stats["models"][0],
        json!({"harness":"codex","model":"astra","wins":0,"races":1,"winRate":0.0})
    );
    assert_eq!(
        stats["models"][1],
        json!({"harness":"codex","model":"sol","wins":1,"races":1,"winRate":1.0})
    );
    for state in ["cancelled", "failed", "running"] {
        race.state = state.into();
        assert_eq!(statistics(&[race.clone()])["models"], json!([]));
    }
}

#[test]
fn a_closed_child_is_terminal_even_when_last_turn_is_from_another_generation() {
    let old = json!({"status":"completed", "turnId":"old", "reply":"done"});
    assert_eq!(turn_outcome("completed", Some("old"), Some("new"), false, &old), None);
    assert_eq!(
        turn_outcome("completed", Some("old"), Some("new"), true, &old),
        Some((false, None))
    );
    assert_eq!(turn_outcome("failed", Some("new"), Some("new"), false, &old), Some((false, None)));
    assert_eq!(
        turn_outcome("completed", Some("new"), Some("new"), false, &old),
        Some((true, None))
    );
}

#[test]
fn durable_race_round_trip_keeps_ownership_and_distinct_recovery_names() {
    let race = race();
    let restored: Race = serde_json::from_value(serde_json::to_value(&race).unwrap()).unwrap();
    assert_eq!(restored.parent, "parent");
    assert!(!restored.local); // Old records never gain local authority.
    assert!(!restored.owner_authorized); // Nor the new worktree authorization.
    let mut authorized = race.clone();
    authorized.owner_authorized = true;
    let resumed: Race = serde_json::from_value(serde_json::to_value(&authorized).unwrap()).unwrap();
    assert!(resumed.owner_authorized);
    assert_eq!(resumed.parent, authorized.parent);
    let names: Vec<_> =
        ["c1", "c2", "review"].into_iter().map(|c| child_name(&race.id, c)).collect();
    assert!(names.iter().all(|n| n.len() <= 40));
    assert_ne!(names[0], names[1]);
    assert_ne!(names[0], names[2]);
}

#[test]
fn cancellation_wins_over_late_terminal_transitions() {
    let mut cancelled = race();
    cancelled.state = "cancelled".into();
    complete_race(&mut cancelled, "c1", "reviewed");
    assert_eq!(cancelled.state, "cancelled");
    assert_eq!(cancelled.winner_id, None);

    fail_race(&mut cancelled, "review failed");
    assert_eq!(cancelled.state, "cancelled");
    assert_eq!(cancelled.reason, None);
}

#[test]
fn restart_resumes_only_unfinished_cancellation_cleanup() {
    let mut historical = race();
    historical.state = "cancelled".into();
    assert!(!race_needs_resume(&historical));
    historical.cleanup_pending = true;
    assert!(race_needs_resume(&historical));
}

#[test]
fn restart_requires_an_accepted_or_queued_prompt() {
    assert!(!recovery_prompt_accepted(None, false, &[]));
    assert!(recovery_prompt_accepted(Some("turn"), false, &[]));
    assert!(recovery_prompt_accepted(None, true, &[]));
    let queued = crate::store::EventRecord {
        seq: 1,
        at: 0,
        dir: "mux".into(),
        kind: "queued".into(),
        msg: json!({}),
        host_seq: None,
    };
    assert!(recovery_prompt_accepted(None, false, &[queued]));
}

#[tokio::test]
async fn recovery_finishes_persisted_verdict_after_reviewer_closed() {
    let mut config: crate::config::Config = serde_json::from_value(json!({})).unwrap();
    config.store.mode = crate::config::StoreMode::Memory;
    let hub = Hub::new(config, Box::new(crate::store::MemoryStore::default()));
    let parent = hub.insert_test_session(test_meta("parent", "idle", None));
    let reviewer = hub.insert_test_session(test_meta("reviewer", "closed", Some("parent")));
    hub.save_meta(&parent);
    hub.save_meta(&reviewer);
    let race: Race = serde_json::from_value(json!({
        "id": "race-recovery",
        "parent": "parent",
        "prompt": "fix it",
        "state": "reviewing",
        "candidates": [
            {"id":"c1","target":{"harness":"codex","model":"sol"},"state":"completed"},
            {"id":"c2","target":{"harness":"codex","model":"astra"},"state":"completed"}
        ],
        "reviewer":{"harness":"codex"},
        "reviewerSessionId":"reviewer",
        "reviewerTurnId":"review-turn",
        "winnerId":"c1",
        "reason":"tests passed",
        "createdAt":1,
        "updatedAt":2,
        "cleanupPending":true
    }))
    .unwrap();
    parent.meta.lock().unwrap().races = Arc::new(vec![race]);
    hub.save_meta(&parent);

    hub.run_race(&parent, "race-recovery", true).await.unwrap();
    let done = hub.race_get(&parent, "race-recovery").unwrap();
    assert_eq!(done.state, "completed");
    assert_eq!(done.winner_id.as_deref(), Some("c1"));
    assert_eq!(done.reason.as_deref(), Some("tests passed"));
    assert!(!done.cleanup_pending);
    assert!(done.reviewer_cleanup_done);
    assert_eq!(done.reviewer_session_id.as_deref(), Some("reviewer"));
    assert_eq!(done.reviewer_turn_id.as_deref(), Some("review-turn"));
    assert_eq!(done.candidates.iter().filter(|c| c.state == "discarded").count(), 1);
    let stats = hub.race_stats(&parent);
    let models = stats["models"].as_array().unwrap();
    assert_eq!(models.len(), 2);
    assert!(models.iter().all(|model| model["races"] == 1));
    assert_eq!(models.iter().filter(|model| model["wins"] == 1).count(), 1);
    hub.run_race(&parent, "race-recovery", true).await.unwrap();
    assert_eq!(hub.race_stats(&parent), stats);
}

#[tokio::test]
async fn historical_cancelled_race_does_not_close_reopened_child() {
    let mut config: crate::config::Config = serde_json::from_value(json!({})).unwrap();
    config.store.mode = crate::config::StoreMode::Memory;
    let hub = Hub::new(config, Box::new(crate::store::MemoryStore::default()));
    let parent = hub.insert_test_session(test_meta("parent", "idle", None));
    let child = hub.insert_test_session(test_meta("cancel-child", "idle", Some("parent")));
    hub.save_meta(&parent);
    hub.save_meta(&child);
    let race: Race = serde_json::from_value(json!({
        "id":"cancelled-old", "parent":"parent", "prompt":"fix", "state":"cancelled",
        "candidates":[{"id":"c1","target":{"harness":"codex"},"state":"running","sessionId":"cancel-child"}],
        "reviewer":{"harness":"codex"}, "winnerId":null, "reason":"cancelled",
        "createdAt":1,"updatedAt":2,"cleanupPending":false
    }))
    .unwrap();
    parent.meta.lock().unwrap().races = Arc::new(vec![race]);
    hub.save_meta(&parent);
    hub.run_race(&parent, "cancelled-old", true).await.unwrap();
    assert_eq!(child.meta().status, SessionStatus::Idle);
}

fn memory_hub() -> Arc<Hub> {
    let mut config: crate::config::Config = serde_json::from_value(json!({})).unwrap();
    config.store.mode = crate::config::StoreMode::Memory;
    Hub::new(config, Box::new(crate::store::MemoryStore::default()))
}

/// Review of #34437 (F1): a guarded move's bundle may carry a race with the source daemon's
/// worktree authorization, still running with completed candidates. Neither the import nor a
/// restart here resumes it, and no race keeps that authority or a local origin.
#[tokio::test]
async fn a_guarded_import_never_resumes_a_race_or_keeps_its_authority() {
    use super::super::transfer_guard::{Guard, GuardedImport};
    let dir = std::env::temp_dir().join(format!("acpmux-test-{}", uuid::Uuid::now_v7()));
    let work = dir.join("work");
    std::fs::create_dir_all(&work).unwrap();
    let work = std::fs::canonicalize(&work).unwrap();
    let profile = crate::config::HarnessProfile {
        kind: Default::default(),
        argv: vec!["true".into()],
        env: Default::default(),
        description: None,
        fallback: None,
        family: None,
        models: vec![],
        model: None,
        effort: None,
        policy: None,
    };
    let mut cfg = crate::config::Config::default();
    cfg.harnesses.insert("codex".into(), profile);
    cfg.store.mode = crate::config::StoreMode::Local;
    let hub = Hub::new(cfg.clone(), crate::store::open(&cfg.store, &dir).unwrap());
    let bundle = dir.join("bundle");
    std::fs::create_dir_all(&bundle).unwrap();
    let id = uuid::Uuid::now_v7().to_string();
    let candidates = json!([
        {"id": "c1", "target": {"harness": "codex"}, "state": "completed"},
        {"id": "c2", "target": {"harness": "codex"}, "state": "completed"}
    ]);
    let race = |race: &str, state: &str| {
        json!({
            "id": race, "parent": id, "prompt": "fix", "state": state,
            "candidates": candidates, "reviewer": {"harness": "codex"},
            "winnerId": null, "reason": null, "createdAt": 1, "updatedAt": 2,
            "local": true, "ownerAuthorized": true, "cleanupPending": true
        })
    };
    let meta = json!({
        "schema": crate::store::META_SCHEMA, "id": id, "name": "moved", "harness": "codex",
        "cwd": work, "status": "idle", "createdAt": 1, "updatedAt": 1,
        "races": [race("running-race", "running"), race("cancelled-race", "cancelled")],
    });
    std::fs::write(bundle.join("session.json"), meta.to_string()).unwrap();
    let guard = Guard { control: Control::Peer, roots: vec![work] };
    hub.guard_session(&bundle, &guard, None, &json!({}), None).await.unwrap();
    let guarded = GuardedImport { guard: &guard, replace_native: false };
    let session = hub.import_into(&bundle, None, false, Some(guarded), false, false).await.unwrap();
    let settled = |races: &[Race]| {
        assert_eq!(races.len(), 2);
        assert!(races.iter().all(|r| !r.owner_authorized && !r.local && !race_needs_resume(r)));
        assert_eq!(races[0].state, "failed");
        assert_eq!(races[1].state, "cancelled");
    };
    settled(&session.read_meta(|m| m.races.clone()));
    hub.resume_races();
    assert!(hub.races_running.lock().unwrap().is_empty(), "the import resumes nothing");
    // A restart reads what the import saved: still nothing to resume, no authority.
    let stored = hub.store.load(&id).unwrap().unwrap();
    settled(&stored.races);
    let restarted = memory_hub();
    restarted.insert_test_session(stored);
    restarted.resume_races();
    assert!(restarted.races_running.lock().unwrap().is_empty(), "the restart resumes nothing");
    let _ = std::fs::remove_dir_all(&dir);
}

/// Review of #34437 (F2): a candidate's prompt stopped while it still waited in the queue
/// (stop_session close:false) or refused at dispatch has no turn to end; its removal settles it.
#[tokio::test]
async fn a_prompt_that_left_the_queue_unrun_settles_its_candidate() {
    let hub = memory_hub();
    let child = hub.insert_test_session(test_meta("queued-child", "idle", Some("parent")));
    hub.save_meta(&child);
    assert_eq!(hub.settled(&child, Some("t1")), None, "no record yet: still waiting");
    hub.append(&child, "mux", "queue_removed", json!({"turnId": "t1", "reason": "stopped"}));
    let (ok, error) = hub.settled(&child, Some("t1")).unwrap();
    assert!(!ok);
    assert!(error.unwrap().contains("stopped"));
    hub.append(&child, "mux", "prompt_refused", json!({"turnId": "t2", "error": "trust"}));
    assert!(!hub.settled(&child, Some("t2")).unwrap().0);
    // Removed and later run under the same turn: its turn decides, not the removal.
    hub.append(&child, "mux", "queue_removed", json!({"turnId": "t3"}));
    hub.append(&child, "mux", "turn_started", json!({"turnId": "t3"}));
    assert_eq!(hub.settled(&child, Some("t3")), None);
    assert_eq!(hub.settled(&child, None), None);
}

/// Review of #34437 (F3): the reviewer starts after the candidates, which keep their slots, so
/// a race that leaves no slot for it is refused before anything starts.
#[tokio::test]
async fn a_race_without_a_slot_for_its_reviewer_is_refused_up_front() {
    let hub = memory_hub();
    let mut meta = test_meta("narrow", "idle", None);
    meta.subsession_limits.max_children = Some(2);
    let parent = hub.insert_test_session(meta);
    let codex = || Target { harness: "codex".into(), model: None, effort: None };
    let refused = hub
        .race_start(&parent, "fix".into(), vec![codex(), codex()], codex(), true, true)
        .await
        .unwrap_err();
    assert!(refused.message.contains("needs 3 free sub-session slots"), "{}", refused.message);
    assert!(parent.read_meta(|m| m.races.is_empty()), "nothing recorded or started");
}
