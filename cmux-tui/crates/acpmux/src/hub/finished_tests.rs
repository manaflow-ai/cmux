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
    let hub = memory_hub();
    let session = chat(&hub);
    hub.finish_session(&session, "PR merged; start afresh for new work").unwrap();
    let restored = hub.make_session(hub.store.load(&session.id).unwrap().unwrap());
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
    assert!(hub.store.load(&session.id).unwrap().unwrap().finished.is_none());
    assert!(hub.check_finished(&restored).is_ok());
}

#[tokio::test]
async fn a_finish_fences_an_already_prepared_turn_and_pause_fences_automatic_turns() {
    let hub = memory_hub();
    let session = chat(&hub);
    let mut turn = TurnInfo::prompted("test", "work", "t", "p", Control::Local);
    turn.persons = false;
    hub.set_fleet_pause(true, "outage").unwrap();
    let error = hub.start_turn(&session, None, false, false, turn.clone()).unwrap_err();
    assert_eq!(error.data.unwrap()["reason"], "fleet.paused");
    turn.persons = true;
    hub.start_turn(&session, None, false, false, turn.clone()).unwrap();
    session.turn.lock().unwrap().take();
    hub.set_fleet_pause(false, "capacity restored").unwrap();
    hub.finish_session(&session, "done").unwrap();
    let error = hub.start_turn(&session, None, false, false, turn).unwrap_err();
    assert_eq!(error.data.unwrap()["reason"], "session.finished");
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
    let result = tokio::time::timeout(Duration::from_secs(180), async {
        while recovered.len() < 90 {
            let event = events.recv().await.unwrap();
            if event.record.kind == "turn_result" && event.record.msg["status"] == "completed" {
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
}
