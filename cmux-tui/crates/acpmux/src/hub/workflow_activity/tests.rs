use super::*;

fn activity_chat() -> (Arc<Hub>, RunRecord, ActivityRecord) {
    let fixture = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_workflow_agent.py");
    let mut config: crate::config::Config =
            serde_json::from_value(json!({"defaultHarness":"fake","autoResumeDelaysMs":[1000],
            "harnesses":{"fake":{"argv":["python3",fixture]},"fake-alternate":{"argv":["python3",fixture,"alternate"]}}}))
            .unwrap();
    config.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    let owner:crate::store::SessionMeta=serde_json::from_value(json!({"schema":crate::store::META_SCHEMA,
            "id":"owner","name":"owner","harness":"fake","cwd":"/tmp","status":"closed","createdAt":1,"updatedAt":2})).unwrap();
    store.save(&owner).unwrap();
    let hub = Hub::new(config, store);
    let id = format!("wf-test-{}", uuid::Uuid::now_v7().simple());
    let run = hub
        .workflow_runs
        .store()
        .start(RunRecord {
            version: 1,
            id: id.clone(),
            name: "Test workflow".into(),
            owner_session_id: "owner".into(),
            source: "await agent('test')".into(),
            source_hash: String::new(),
            args: json!([]),
            allowed_tools: None,
            cwd: std::env::temp_dir(),
            generation: 1,
            state: crate::workflow_runs::State::Running,
            activities: Default::default(),
            outcome: None,
            local_principal: false,
            caller_subagent: None,
        })
        .unwrap();
    let child = ActivityRecord {
        id: "activity".into(),
        kind: "agent".into(),
        fingerprint: "pinned".into(),
        child: Child::Agent {
            session_id: format!("{id}-child"),
            prompt_id: format!("{id}-prompt"),
            host: None,
        },
        policy: Value::Null,
        outcome: None,
    };
    hub.workflow_runs
        .store()
        .register_activity(&run.id, run.generation, "owner", child.clone())
        .unwrap();
    (hub, run, child)
}

async fn cleanup(hub: Arc<Hub>, run: RunRecord) {
    hub.shutdown_all().await;
    // This test created the UUID-named directory; no other run is touched.
    std::fs::remove_dir_all(hub.workflow_runs.store().directory(&run.id).unwrap()).unwrap();
}

fn turns(hub: &Hub, child: &ActivityRecord) -> usize {
    let Child::Agent { session_id, .. } = &child.child else { unreachable!() };
    let mut turns = 0;
    hub.store
        .scan_strict(session_id, 0, &mut |record| {
            if record.kind == "turn_started" {
                turns += 1;
            }
            true
        })
        .unwrap();
    turns
}

#[tokio::test]
async fn workflow_invalid_placement_cannot_create_a_local_agent() {
    let (hub, run, child) = activity_chat();
    for on in [json!(["ci"]), Value::Null, json!(true), json!(4), json!({"host":"ci"})] {
        let error = hub
            .workflow_execute(&run, run.generation, &child, "test", &json!({"on":on}))
            .await
            .unwrap_err();
        assert_eq!(error.code, RpcError::invalid_params("").code);
    }
    let Child::Agent { session_id, .. } = &child.child else { unreachable!() };
    assert!(hub.resolve(session_id).is_err(), "invalid placement cannot silently launch locally");
    cleanup(hub, run).await;
}

#[tokio::test]
async fn workflow_parallel_activities_have_distinct_names_with_same_title() {
    let (hub, run, first) = activity_chat();
    let mut second = first.clone();
    second.id = "second".into();
    second.child = Child::Agent {
        session_id: format!("{}-second", run.id),
        prompt_id: format!("{}-second-prompt", run.id),
        host: None,
    };
    hub.workflow_runs
        .store()
        .register_activity(&run.id, run.generation, "owner", second.clone())
        .unwrap();
    let options = json!({"harness":"fake","name":"Shared title"});
    let (a, b) = tokio::time::timeout(std::time::Duration::from_secs(15), async {
        tokio::join!(
            hub.workflow_execute(&run, run.generation, &first, "test", &options),
            hub.workflow_execute(&run, run.generation, &second, "test", &options)
        )
    })
    .await
    .unwrap();
    assert_eq!(a.unwrap(), json!("{\"ok\":true}"));
    assert_eq!(b.unwrap(), json!("{\"ok\":true}"));
    let name = |activity: &ActivityRecord| {
        let Child::Agent { session_id, .. } = &activity.child else { unreachable!() };
        hub.resolve(session_id).unwrap().meta().name
    };
    let (a, b) = (name(&first), name(&second));
    assert!(a.starts_with("Shared title · ") && b.starts_with("Shared title · "));
    // Each is its owning agent's (`created_by.rs`).
    let Child::Agent { session_id, .. } = &first.child else { unreachable!() };
    let by = hub.resolve(session_id).unwrap().meta().created_by;
    assert_eq!(
        by.map(|b| (b.kind, b.session)),
        Some((crate::store::CreatorKind::Agent, Some("owner".to_owned())))
    );
    assert_ne!(a, b);
    cleanup(hub, run).await;
}

#[tokio::test]
async fn workflow_cancellation_preserves_reserved_looking_logical_siblings() {
    let (hub, run, mut parent) = activity_chat();
    parent.id = "test".into();
    hub.workflow_runs
        .store()
        .register_activity(&run.id, run.generation, "owner", parent.clone())
        .unwrap();
    let Child::Agent { session_id, prompt_id, host } = &parent.child else { unreachable!() };
    let prompt = format!("{prompt_id}-g1-0-0");
    let owned = ActivityRecord {
        id: format!("test-prompt-{}", crate::workflow_runs::digest(&prompt)),
        kind: "agent_prompt".into(),
        child: Child::Agent {
            session_id: session_id.clone(),
            prompt_id: prompt,
            host: host.clone(),
        },
        ..parent.clone()
    };
    hub.workflow_runs
        .store()
        .register_activity(&run.id, run.generation, "owner", owned.clone())
        .unwrap();
    for id in ["test-lint", "test-prompt-x", "test-task-1", "test-nudge-x"] {
        let sibling = ActivityRecord { id: id.into(), ..parent.clone() };
        hub.workflow_runs
            .store()
            .register_activity(&run.id, run.generation, "owner", sibling)
            .unwrap();
    }
    let current = hub.workflow_runs.store().get(&run.id).unwrap();
    hub.workflow_cancel_activity(&current, "test").await.unwrap();
    let current = hub.workflow_runs.store().get(&run.id).unwrap();
    assert!(
        current.activities[&owned.id].outcome.is_some(),
        "owned internal prompt must be cancelled"
    );
    for id in ["test-lint", "test-prompt-x", "test-task-1", "test-nudge-x"] {
        assert!(current.activities[id].outcome.is_none(), "sibling {id} must survive");
    }
    cleanup(hub, run).await;
}

#[tokio::test]
async fn workflow_schema_corrects_once_and_replay_reuses_both_prompt_outcomes() {
    let (hub, run, child) = activity_chat();
    let options = json!({"harness":"fake","schema":{"type":"object","required":["ok"],"properties":{"ok":{"const":true}}}});
    let result = tokio::time::timeout(
        std::time::Duration::from_secs(15),
        hub.workflow_execute(&run, run.generation, &child, "schema-once", &options),
    )
    .await
    .unwrap()
    .unwrap();
    assert_eq!(result, json!({"ok":true}));
    assert_eq!(turns(&hub, &child), 2);
    let saved = hub
        .workflow_runs
        .store()
        .activity(&run.id, run.generation, "owner", &child.id)
        .unwrap()
        .unwrap();
    assert_eq!(
        hub.workflow_execute(&run, run.generation, &saved, "schema-once", &options).await.unwrap(),
        result
    );
    assert_eq!(turns(&hub, &child), 2, "replay must not create new turns");
    cleanup(hub, run).await;
}

#[tokio::test]
async fn workflow_route_error_nudges_once_then_restarts_and_validates_new_generation() {
    let (hub, run, child) = activity_chat();
    let options = json!({"harness":"fake","fallbackHarness":"fake-alternate","schema":{"type":"object","required":["ok"],"properties":{"ok":{"const":true}}}});
    let result = tokio::time::timeout(
        std::time::Duration::from_secs(15),
        hub.workflow_execute(&run, run.generation, &child, "route-failure-schema", &options),
    )
    .await
    .unwrap()
    .unwrap();
    assert_eq!(result, json!({"ok":true}));
    assert_eq!(turns(&hub, &child), 2, "original route gets one continuation only");
    let Child::Agent { session_id, .. } = &child.child else { unreachable!() };
    let mut restarted = 0;
    hub.store
        .scan_strict(&format!("{session_id}-restart"), 0, &mut |event| {
            if event.kind == "turn_started" {
                restarted += 1;
            }
            true
        })
        .unwrap();
    assert_eq!(restarted, 1, "alternate route gets one schema-checked attempt");
    let saved = hub
        .workflow_runs
        .store()
        .activity(&run.id, run.generation, "owner", &child.id)
        .unwrap()
        .unwrap();
    assert_eq!(
        hub.workflow_execute(&run, run.generation, &saved, "route-failure-schema", &options)
            .await
            .unwrap(),
        result
    );
    assert_eq!(turns(&hub, &child), 2, "replay must not repeat original effects");
    cleanup(hub, run).await;
}

#[tokio::test]
async fn workflow_explicit_resume_replaces_fenced_wait_on_same_harness() {
    let (hub, run, child) = activity_chat();
    let mut recovery = RecoveryState::new(AttemptKey::new(&child.id));
    recovery.observe(&AttemptKey::new(&child.id), 1, RecoveryEvent::Waiting(WaitReason::Capacity));
    let policy = Policy {
        epoch: run.generation,
        observation: 1,
        waiting_for: Some("old-prompt~resume-1".into()),
        recovery: Some(recovery),
        ..Default::default()
    };
    hub.workflow_runs
        .store()
        .update_activity_policy(
            &run.id,
            run.generation,
            "owner",
            &child.id,
            serde_json::to_value(policy).unwrap(),
        )
        .unwrap();
    hub.workflow_pause(&run.id, "owner").await.unwrap();
    let resumed = hub.workflow_runs.store().resume(&run.id, "owner", false).unwrap();
    let saved = hub
        .workflow_runs
        .store()
        .activity(&run.id, resumed.generation, "owner", &child.id)
        .unwrap()
        .unwrap();
    let result = tokio::time::timeout(
        std::time::Duration::from_secs(15),
        hub.workflow_execute(
            &resumed,
            resumed.generation,
            &saved,
            "test",
            &json!({"harness":"fake","fallbackHarness":"fake-alternate"}),
        ),
    )
    .await
    .unwrap()
    .unwrap();
    assert_eq!(result, json!("{\"ok\":true}"));
    let Child::Agent { session_id, .. } = &child.child else { unreachable!() };
    assert_eq!(hub.resolve(session_id).unwrap().meta().harness, "fake");
    assert!(
        hub.resolve(&format!("{session_id}-restart")).is_err(),
        "explicit resume must not select the alternate account/harness"
    );
    assert_eq!(turns(&hub, &child), 1);
    cleanup(hub, resumed).await;
}

#[tokio::test]
async fn workflow_restart_reconciles_persisted_automatic_retry_target() {
    let (hub, run, child) = activity_chat();
    let Child::Agent { session_id, prompt_id, .. } = &child.child else { unreachable!() };
    let session = hub
        .new_session_with_id(
            NewRequest {
                harness: Some("fake".into()),
                name: Some("Original retry".into()),
                cwd: Some(run.cwd.clone()),
                ..Default::default()
            },
            Some(session_id.clone()),
        )
        .await
        .unwrap();
    let retry_id = format!("{prompt_id}-g1-0-0-route-nudge~resume-1");
    let worker_hub = hub.clone();
    let worker_session = session.clone();
    let worker_id = retry_id.clone();
    let mut events = hub.subscribe();
    let worker = tokio::spawn(async move {
        worker_hub
            .prompt_with(
                &worker_session,
                vec![json!({"type":"text","text":"until-cancel"})],
                "workflow",
                false,
                PromptOptions { prompt_id: Some(worker_id), ..Default::default() },
            )
            .await
    });
    tokio::time::timeout(std::time::Duration::from_secs(15), async {
        loop {
            let event = events.recv().await.unwrap();
            if event.session_id == session.id && event.record.kind == "agent_message_chunk" {
                break;
            }
        }
    })
    .await
    .unwrap();
    let key = AttemptKey::new(&child.id);
    let mut recovery = RecoveryState::new(key.clone());
    assert_eq!(recovery.observe(&key, 1, RecoveryEvent::RouteError), RecoveryAction::Nudge);
    assert!(matches!(
        recovery.observe(&key, 2, RecoveryEvent::Stalled),
        RecoveryAction::Restart { .. }
    ));
    // Simulate a crash after persisting Restart but before cancelling the actual retry.
    let policy = Policy {
        recovery: Some(recovery),
        epoch: run.generation,
        observation: 2,
        restart_prompt_id: Some(retry_id),
        ..Default::default()
    };
    hub.workflow_runs
        .store()
        .update_activity_policy(
            &run.id,
            run.generation,
            "owner",
            &child.id,
            serde_json::to_value(policy).unwrap(),
        )
        .unwrap();
    let saved = hub
        .workflow_runs
        .store()
        .activity(&run.id, run.generation, "owner", &child.id)
        .unwrap()
        .unwrap();
    let result = tokio::time::timeout(
        std::time::Duration::from_secs(15),
        hub.workflow_execute(
            &run,
            run.generation,
            &saved,
            "test",
            &json!({"harness":"fake","fallbackHarness":"fake-alternate"}),
        ),
    )
    .await
    .unwrap()
    .unwrap();
    assert_eq!(result, json!("{\"ok\":true}"));
    tokio::time::timeout(std::time::Duration::from_secs(15), worker)
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    assert!(session.turn().is_none(), "the original retry cannot outlive fallback admission");
    cleanup(hub, run).await;
}

#[tokio::test]
async fn workflow_automatic_retry_stall_nudges_then_restarts_after_running_admission() {
    let (hub, run, child) = activity_chat();
    let result=tokio::time::timeout(std::time::Duration::from_secs(15),hub.workflow_execute(&run,run.generation,&child,"capacity-then-stall",&json!({"harness":"fake","fallbackHarness":"fake-alternate","stallMs":200,"schema":{"type":"object","required":["ok"]}}))).await.unwrap().unwrap();
    assert_eq!(result, json!({"ok":true}));
    let Child::Agent { session_id, .. } = &child.child else { unreachable!() };
    let mut working = None;
    let mut nudges = Vec::new();
    hub.store
        .scan_strict(session_id, 0, &mut |event| {
            match event.msg.pointer("/params/update/content/text").and_then(Value::as_str) {
                Some("retry working") => working = Some(event.seq),
                Some("nudge accepted") => nudges.push(event.seq),
                _ => {}
            }
            true
        })
        .unwrap();
    assert_eq!(nudges.len(), 1, "the running retry gets its one stall nudge");
    assert!(working.unwrap() < nudges[0], "capacity waiting must not trigger a premature nudge");
    assert_eq!(turns(&hub, &child), 2, "original turn and same-account daemon retry only");
    assert_eq!(
        hub.resolve(&format!("{session_id}-restart")).unwrap().meta().harness,
        "fake-alternate"
    );
    cleanup(hub, run).await;
}

#[tokio::test]
async fn workflow_route_error_without_alternate_fails_after_one_nudge() {
    let (hub, run, child) = activity_chat();
    let error = tokio::time::timeout(
        std::time::Duration::from_secs(15),
        hub.workflow_execute(
            &run,
            run.generation,
            &child,
            "route-failure",
            &json!({"harness":"fake"}),
        ),
    )
    .await
    .unwrap()
    .unwrap_err();
    assert!(error.message.contains("no different permitted fallback"));
    assert_eq!(turns(&hub, &child), 2);
    cleanup(hub, run).await;
}

#[test]
fn account_and_permission_waits_never_escalate_to_route_fallback() {
    for (message, data, expected) in [
        (
            "route unavailable HTTP 429",
            json!({"reason":"route.unavailable"}),
            WaitReason::UsageLimit { reset_at_ms: None },
        ),
        ("route unavailable HTTP 503", json!({"reason":"route.unavailable"}), WaitReason::Capacity),
        ("route unavailable", json!({"reason":"permission.denied"}), WaitReason::Permission),
    ] {
        assert_eq!(
            workflow_error_observation(&RpcError::internal(message).with_data(data)),
            RecoveryEvent::Waiting(expected)
        );
    }
}

#[tokio::test]
async fn workflow_schema_second_mismatch_is_terminal_without_third_prompt() {
    let (hub, run, child) = activity_chat();
    let result = tokio::time::timeout(
        std::time::Duration::from_secs(15),
        hub.workflow_execute(
            &run,
            run.generation,
            &child,
            "schema-twice",
            &json!({"harness":"fake","schema":{"type":"object"}}),
        ),
    )
    .await
    .unwrap();
    assert!(result.unwrap_err().message.contains("after correction"));
    assert_eq!(turns(&hub, &child), 2);
    cleanup(hub, run).await;
}

#[tokio::test]
async fn workflow_pause_resume_preserves_child_and_restarts_only_cancelled_prompt() {
    let (hub, run, child) = activity_chat();
    let mut events = hub.subscribe();
    let worker_hub = hub.clone();
    let worker_run = run.clone();
    let worker_child = child.clone();
    let worker = tokio::spawn(async move {
        worker_hub
            .workflow_execute(
                &worker_run,
                worker_run.generation,
                &worker_child,
                "until-cancel",
                &json!({"harness":"fake"}),
            )
            .await
    });
    tokio::time::timeout(std::time::Duration::from_secs(15), async {
        loop {
            let event = events.recv().await.unwrap();
            if event.record.kind == "agent_message_chunk" {
                break;
            }
        }
    })
    .await
    .unwrap();
    let paused = hub.workflow_pause(&run.id, "owner").await.unwrap();
    assert_eq!(paused.state, crate::workflow_runs::State::Paused);
    assert!(worker.await.unwrap().is_err(), "paused generation cannot save a late outcome");
    let resumed = hub.workflow_runs.store().resume(&run.id, "owner", false).unwrap();
    let saved = hub
        .workflow_runs
        .store()
        .activity(&run.id, resumed.generation, "owner", &child.id)
        .unwrap()
        .unwrap();
    let result = tokio::time::timeout(
        std::time::Duration::from_secs(15),
        hub.workflow_execute(
            &resumed,
            resumed.generation,
            &saved,
            "until-cancel",
            &json!({"harness":"fake"}),
        ),
    )
    .await
    .unwrap()
    .unwrap();
    assert_eq!(result, json!("{\"ok\":true}"));
    assert_eq!(turns(&hub, &child), 2, "same session, one cancelled and one resumed turn");
    cleanup(hub, resumed).await;
}

#[tokio::test]
async fn workflow_reconciles_persisted_nudge_intent_without_duplicate_effect() {
    let (hub, run, child) = activity_chat();
    let mut events = hub.subscribe();
    let worker_hub = hub.clone();
    let worker_run = run.clone();
    let worker_child = child.clone();
    let worker = tokio::spawn(async move {
        worker_hub
            .workflow_execute(
                &worker_run,
                worker_run.generation,
                &worker_child,
                "until-cancel",
                &json!({"harness":"fake"}),
            )
            .await
    });
    tokio::time::timeout(std::time::Duration::from_secs(15), async {
        loop {
            let event = events.recv().await.unwrap();
            if event.record.kind == "agent_message_chunk" {
                break;
            }
        }
    })
    .await
    .unwrap();
    let Child::Agent { session_id, .. } = &child.child else { unreachable!() };
    let session = hub.resolve(session_id).unwrap();
    let target = session.turn().unwrap().prompt_id;
    let intent = Nudge {
        id: "activity-nudge".into(),
        session_id: session.id.clone(),
        prompt_id: format!("{target}-nudge"),
        target_prompt_id: target,
    };
    let mut recovery = RecoveryState::new(AttemptKey::new(&child.id));
    recovery.observe(&AttemptKey::new(&child.id), 1, RecoveryEvent::Stalled);
    let policy = Policy {
        nudge: Some(intent.clone()),
        recovery: Some(recovery),
        epoch: run.generation,
        ..Default::default()
    };
    hub.workflow_runs
        .store()
        .update_activity_policy(
            &run.id,
            run.generation,
            "owner",
            &child.id,
            serde_json::to_value(policy).unwrap(),
        )
        .unwrap();
    // Simulate the gap after the durable decision and before its child/effect existed.
    assert!(
        hub.workflow_runs
            .store()
            .activity(&run.id, run.generation, "owner", &intent.id)
            .unwrap()
            .is_none()
    );
    hub.workflow_nudge(&run, run.generation, &intent).await.unwrap();
    tokio::time::timeout(std::time::Duration::from_secs(15), async {
        loop {
            let event = events.recv().await.unwrap();
            if event.record.msg.pointer("/params/update/content/text").and_then(Value::as_str)
                == Some("nudge accepted")
            {
                break;
            }
        }
    })
    .await
    .unwrap();
    hub.workflow_nudge(&run, run.generation, &intent).await.unwrap();
    assert!(
        hub.workflow_runs
            .store()
            .activity(&run.id, run.generation, "owner", &intent.id)
            .unwrap()
            .unwrap()
            .outcome
            .is_some()
    );
    let mut nudges = 0;
    hub.store
        .scan_strict(&session.id, 0, &mut |event| {
            if event.msg.pointer("/params/update/content/text").and_then(Value::as_str)
                == Some("nudge accepted")
            {
                nudges += 1;
            }
            true
        })
        .unwrap();
    assert_eq!(nudges, 1, "reconciled intent must steer only once");
    hub.workflow_pause(&run.id, "owner").await.unwrap();
    assert!(worker.await.unwrap().is_err());
    cleanup(hub, run).await;
}

#[tokio::test]
async fn workflow_reply_reads_only_exact_final_message_before_human_followup() {
    let mut config = crate::config::Config::default();
    config.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    let meta = serde_json::from_value(json!({"schema":crate::store::META_SCHEMA,"id":"s",
            "name":"s","harness":"fake","cwd":"/tmp","status":"closed","createdAt":1,"updatedAt":2})).unwrap();
    store.save(&meta).unwrap();
    let hub = Hub::new(config, store);
    let session = hub.resolve("s").unwrap();
    hub.append(&session, "mux", "turn_started", json!({"promptId":"workflow-prompt","turnId":"t"}));
    let chunk = |text| json!({"method":"session/update","params":{"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":text}}}});
    hub.append(&session, "in", "agent_message_chunk", chunk("Working on it"));
    hub.append(&session, "in", "tool_call", json!({}));
    hub.append(&session, "in", "agent_message_chunk", chunk("{\"ok\":"));
    hub.append(&session, "in", "agent_message_chunk", chunk("true}"));
    let mut subagent = chunk("WRONG SUBAGENT");
    subagent["params"]["_meta"] = json!({"acpmux":{"subagent":"child"}});
    hub.append(&session, "in", "agent_message_chunk", subagent);
    hub.append(&session, "mux", "turn_end", json!({"turnId":"t"}));
    hub.append(&session, "mux", "turn_started", json!({"promptId":"human","turnId":"later"}));
    hub.append(&session, "in", "agent_message_chunk", chunk("WRONG FOLLOWUP"));
    assert_eq!(
        hub.workflow_final_reply(&session, "workflow-prompt", &json!({})).unwrap(),
        "{\"ok\":true}"
    );
    assert!(hub.workflow_final_reply(&session, "missing", &json!({})).is_err());
    hub.shutdown_all().await;
}
