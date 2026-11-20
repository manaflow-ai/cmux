use super::*;
use crate::config::StoreMode;

fn memory_hub() -> Arc<Hub> {
    let mut config = Config::default();
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, Path::new("/unused")).unwrap();
    Hub::new(config, store)
}

fn chat(hub: &Hub) -> Arc<Session> {
    let meta: SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "finished-test", "name": "finished test",
        "harness": "fake", "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1
    }))
    .unwrap();
    hub.store.save(&meta).unwrap();
    hub.make_session(meta)
}

#[tokio::test]
async fn finished_sessions_survive_reload_and_refuse_every_prompt_source() {
    let dir = tempfile::tempdir().unwrap();
    let config = Config::default();
    let store = crate::store::open(&config.store, dir.path()).unwrap();
    let hub = Hub::new(config.clone(), store);
    let session = chat(&hub);
    hub.finish_session(&session, "PR merged; start afresh for new work").unwrap();
    let id = session.id.clone();
    drop(session);
    drop(hub);
    let hub = Hub::new(config.clone(), crate::store::open(&config.store, dir.path()).unwrap());
    let restored = hub.make_session(hub.store.load(&id).unwrap().unwrap());
    assert_eq!(hub.session_summary(&restored)["state"], "finished");
    for kind in [None, Some("auto_resume"), Some("notice"), Some("session_message")] {
        let opts = PromptOptions {
            provenance: kind.map(|kind| json!({"kind": kind})),
            ..Default::default()
        };
        let error = hub
            .prompt_with(
                &restored,
                vec![json!({"type": "text", "text": "continue"})],
                "test",
                false,
                opts,
            )
            .await
            .unwrap_err();
        assert_eq!(error.data.unwrap()["reason"], "session.finished");
    }
    assert!(hub.wake_finished(&restored, "  ").is_err());
    assert!(hub.check_finished(&restored).is_err());
    hub.wake_finished(&restored, "Investigate the follow-up explicitly").unwrap();
    assert!(hub.store.load(&id).unwrap().unwrap().finished.is_none());
    assert!(hub.check_finished(&restored).is_ok());
}

#[tokio::test]
async fn finished_fences_prepared_turns_and_pause_fences_automatic_turns() {
    let hub = memory_hub();
    let session = chat(&hub);
    let mut turn = TurnInfo::prompted("test", "work", "t", "p", Control::Local);
    turn.persons = false;
    hub.set_fleet_pause(true, "outage").unwrap();
    let error = hub.start_turn(&session, None, false, false, turn.clone()).unwrap_err();
    assert_eq!(error.data.unwrap()["reason"], "fleet.paused");
    // Turning the optional agent inbox off must not change pause admission.
    turn.persons = false;
    turn.prompted_by_person = true;
    hub.start_turn(&session, None, false, false, turn.clone()).unwrap();
    session.turn.lock().unwrap().take();
    hub.set_fleet_pause(false, "capacity restored").unwrap();
    hub.finish_session(&session, "done").unwrap();
    let error = hub.start_turn(&session, None, false, false, turn).unwrap_err();
    assert_eq!(error.data.unwrap()["reason"], "session.finished");
}

#[tokio::test(start_paused = true)]
async fn finished_or_paused_never_admits_notices_goals_or_unnamed_relay_messages() {
    for kind in ["notice", "auto_resume", "session_message", "unverified", "trigger"] {
        let hub = memory_hub();
        let session = chat(&hub);
        hub.set_fleet_pause(true, "outage").unwrap();
        let mut waiting = Box::pin(hub.prompt_with(
            &session,
            vec![json!({"type": "text", "text": "continue"})],
            "relay",
            false,
            PromptOptions { provenance: Some(json!({"kind": kind})), ..Default::default() },
        ));
        assert!(futures::poll!(&mut waiting).is_pending(), "{kind} bypassed pause");
        hub.finish_session(&session, "done while paused").unwrap();
        hub.set_fleet_pause(false, "capacity restored").unwrap();
        let error = waiting.await.unwrap_err();
        assert_eq!(error.data.unwrap()["reason"], "session.finished");
    }
}

#[tokio::test]
async fn finished_fresh_session_seeds_only_the_handoff_and_retires_the_old_harness() {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut config: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}}, "defaultHarness": "fake",
        "permissionPolicy": "approve-all"
    }))
    .unwrap();
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, Path::new("/unused")).unwrap();
    let hub = Hub::new(config, store);
    let source = hub
        .new_session(NewRequest {
            name: Some("completed-work".into()),
            cwd: Some(std::env::temp_dir()),
            ..Default::default()
        })
        .await
        .unwrap();
    hub.finish_session(&source, "Merged #123; next task is independent").unwrap();
    hub.retire_finished(&source).await.unwrap();
    assert!(source.child.lock().await.is_none());
    let fresh = hub.fresh_from_finished(&source, "new-work", None).await.unwrap();
    let target = hub.resolve(fresh["sessionId"].as_str().unwrap()).unwrap();
    assert_ne!(target.id, source.id);
    assert_eq!(
        target.meta().composer_draft.as_deref(),
        Some("Merged #123; next task is independent")
    );
    assert!(target.meta().finished.is_none());
    assert!(hub.check_finished(&source).is_err());
    assert_eq!(target.meta().turn_count, 0);
    hub.wake_finished(&source, "Explicit follow-up").unwrap();
    let reply =
        hub.prompt(&source, vec![json!({"type": "text", "text": "hello"})], "test", false).await;
    hub.shutdown_all().await;
    assert!(reply.is_ok(), "{reply:?}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn finished_admission_recovers_100_fake_503_sessions_without_a_stampede() {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut config: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}}, "defaultHarness": "fake",
        "autoResumeDelaysMs": [1000], "permissionPolicy": "approve-all"
    }))
    .unwrap();
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, Path::new("/unused")).unwrap();
    let hub = Hub::new(config, store);
    hub.set_fleet_pause(true, "synthetic capacity outage").unwrap();
    let mut sessions = Vec::new();
    for n in 0..100 {
        let session = hub
            .new_session(NewRequest {
                name: Some(format!("fake-503-{n}")),
                cwd: Some(std::env::temp_dir()),
                ..Default::default()
            })
            .await
            .unwrap();
        let error = hub
            .prompt_with(
                &session,
                vec![json!({"type": "text", "text": "cap-fail-once: build it"})],
                "test",
                false,
                PromptOptions { prompt_id: Some(format!("capacity-{n}")), ..Default::default() },
            )
            .await
            .unwrap_err();
        assert!(error.message.contains("no non-exhausted claude accounts"), "{error:?}");
        sessions.push(session);
    }
    for session in &sessions[..10] {
        hub.finish_session(session, "finished during the outage").unwrap();
    }
    let mut events = hub.subscribe();
    hub.set_fleet_pause(false, "synthetic capacity is back").unwrap();
    let mut recovered = std::collections::HashSet::new();
    let mut started_at = Vec::new();
    let mut active = std::collections::HashSet::new();
    let mut peak = 0;
    let result = tokio::time::timeout(Duration::from_secs(180), async {
        while recovered.len() < 90 {
            let event = events.recv().await.unwrap();
            if event.record.kind == "turn_started" {
                started_at.push(event.record.at);
                active.insert(event.session_id.clone());
                peak = peak.max(active.len());
            }
            if event.record.kind == "turn_result" && event.record.msg["status"] == "completed" {
                active.remove(&event.session_id);
                recovered.insert(event.session_id.clone());
            }
        }
    })
    .await;
    hub.shutdown_all().await;
    result.expect("100-session recovery exceeded its bound");
    for session in &sessions[..10] {
        assert!(!recovered.contains(&session.id), "a finished session resumed");
    }
    assert_eq!(recovered.len(), 90);
    assert_eq!(started_at.len(), 90);
    assert!(peak <= 4, "peak concurrent retries: {peak}");
    // Real harness startup may vary after admission. Exact one-second spacing is asserted
    // with a paused clock; this harness verifies that recovery still spans the release window.
    assert!(started_at.last().unwrap() - started_at.first().unwrap() >= 85_000);
    eprintln!(
        "100-session outage: 10 finished stayed stopped; 90 recovered; peak={peak}; recovery_span_ms={}",
        started_at.last().unwrap() - started_at.first().unwrap()
    );
}
