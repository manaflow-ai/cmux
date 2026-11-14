use super::*;

#[test]
fn workflow_disabled_tool_injection_is_never_an_unrestricted_ceiling() {
    let mut profile: crate::config::HarnessProfile = serde_json::from_value(json!({
        "argv":["/bin/true"],"env":{crate::agent_tools::SWITCH_ENV:"0"}
    }))
    .unwrap();
    let mut meta: SessionMeta = serde_json::from_value(json!({
        "schema":crate::store::META_SCHEMA,"id":"workflow-off","name":"Workflow off",
        "harness":"fake","cwd":std::env::temp_dir(),"status":"idle","createdAt":1,"updatedAt":1
    }))
    .unwrap();
    assert_eq!(workflow_profile_tools(&profile, &meta), Some(Vec::new()));
    profile.env.clear();
    profile.argv.push("--strict-mcp-config".into());
    assert_eq!(workflow_profile_tools(&profile, &meta), Some(Vec::new()));
    profile.argv.pop();
    meta.tools.off.push("mcp:cmux".into());
    assert_eq!(workflow_profile_tools(&profile, &meta), Some(Vec::new()));
}

#[tokio::test]
async fn workflow_tool_fold_keeps_disabled_servers_and_workspace_scope() {
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Memory;
    cfg.harnesses.insert(
        "workflow-fold-test".into(),
        serde_json::from_value(json!({
            "argv":["/bin/true"], "kind":"claude-stdio"
        }))
        .unwrap(),
    );
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let meta: SessionMeta = serde_json::from_value(json!({
        "schema":crate::store::META_SCHEMA,"id":"workflow-fold-test","name":"Workflow fold",
        "harness":"workflow-fold-test","cwd":std::env::temp_dir(),"status":"idle",
        "createdAt":1,"updatedAt":1,"workspaceId":"workflow-workspace",
        "tools":{"off":["mcp:disabled-server"]}
    }))
    .unwrap();
    let profile = hub.workflow_tool_profile(&meta).await.unwrap();
    let env = &profile.env;
    assert_eq!(env.get(crate::agent_tools::OFF_ENV).map(String::as_str), Some("disabled-server"));
    assert_eq!(
        env.get(crate::agent_displays::WORKSPACE_KEY).map(String::as_str),
        crate::agent_displays::per_workspace().then_some("workflow-workspace")
    );
}

fn recovery_fixture() -> (tempfile::TempDir, Arc<Hub>, RunRecord) {
    let dir = tempfile::tempdir().unwrap();
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    // Construct before entering a runtime, so no background hub task holds a clone.
    let mut hub = Hub::new(cfg, store);
    Arc::get_mut(&mut hub).unwrap().workflow_runs =
        crate::workflow_runs::Service::with_root(dir.path().into());
    let run = hub
        .workflow_runs
        .store()
        .start(RunRecord {
            version: 1,
            id: "wf-live-recovery".into(),
            name: "Recovery".into(),
            owner_session_id: "owner".into(),
            local_principal: false,
            source: "return 1;".into(),
            source_hash: String::new(),
            args: Value::Null,
            allowed_tools: None,
            cwd: dir.path().into(),
            generation: 0,
            state: State::Running,
            activities: BTreeMap::new(),
            outcome: None,
            caller_subagent: None,
        })
        .unwrap();
    (dir, hub, run)
}

#[test]
fn workflow_runs_recovery_preserves_a_runner_launched_by_this_daemon() {
    let (_dir, hub, run) = recovery_fixture();
    // A local resume can finish before startup recovery takes its snapshot.
    let proof = hub.workflow_runs.issue_runner(&run).unwrap().unwrap();
    let (mut stop, finished) = hub.workflow_runs.track_runner(&run.id, run.generation);
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap()
        .block_on(hub.recover_workflows());
    assert_eq!(
        hub.workflow_runs.store().get(&run.id).unwrap(),
        run,
        "recovery replaced a runner that this daemon already owns"
    );
    assert!(hub.workflow_runs.authorize_runner(&run.id, run.generation, &proof).is_ok());
    assert!(matches!(stop.try_recv(), Err(tokio::sync::oneshot::error::TryRecvError::Empty)));
    finished.send(()).unwrap();
    hub.workflow_runs.retire_runner(&run.id, run.generation);
}

#[test]
fn workflow_runs_recovery_finishes_pause_even_if_a_launch_proof_remains() {
    let (_dir, hub, run) = recovery_fixture();
    let pausing = hub.workflow_runs.store().pause(&run.id, &run.owner_session_id).unwrap();
    // Even an outstanding current-generation launch proof cannot skip cleanup.
    hub.workflow_runs.issue_runner(&pausing).unwrap().unwrap();
    assert!(hub.workflow_runs.owns_runner(&run.id, pausing.generation));
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap()
        .block_on(hub.recover_workflows());
    let recovered = hub.workflow_runs.store().get(&run.id).unwrap();
    assert_eq!(recovered.state, State::Paused);
    assert_eq!(recovered.generation, pausing.generation);
    assert!(!hub.workflow_runs.owns_runner(&run.id, pausing.generation));
}

#[tokio::test]
async fn workflow_cancellation_accepts_machine_handles_that_never_launched() {
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let owner = format!("workflow-unlaunched-{}", uuid::Uuid::now_v7().simple());
    let meta: SessionMeta = serde_json::from_value(json!({
        "schema":crate::store::META_SCHEMA,"id":owner,"name":"Workflow machine owner",
        "harness":"fake","cwd":std::env::temp_dir(),"status":"idle","createdAt":1,"updatedAt":1
    }))
    .unwrap();
    store.save(&meta).unwrap();
    let hub = Hub::new(cfg, store);
    let run = RunRecord {
        version: 1,
        id: format!("wf-{}", uuid::Uuid::now_v7().simple()),
        name: "Unlaunched machine".into(),
        owner_session_id: owner.clone(),
        local_principal: false,
        source: "source".into(),
        source_hash: String::new(),
        args: json!([]),
        allowed_tools: None,
        cwd: std::env::temp_dir(),
        generation: 1,
        state: State::Pausing,
        activities: BTreeMap::from([(
            "machine".into(),
            crate::workflow_runs::ActivityRecord {
                id: "machine".into(),
                kind: "machine".into(),
                fingerprint: "pinned".into(),
                child: Child::Machine {
                    session_id: owner,
                    task_id: "never-launched".into(),
                    host: None,
                },
                policy: Value::Null,
                outcome: None,
            },
        )]),
        outcome: None,
        caller_subagent: None,
    };
    hub.workflow_cancel_children(&run).await.unwrap();
}

#[tokio::test]
async fn cancelling_a_stale_activity_never_fences_another_prompt() {
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let meta: SessionMeta = serde_json::from_value(json!({
        "schema":crate::store::META_SCHEMA,"id":"workflow-child","name":"Workflow child",
        "harness":"fake","cwd":std::env::temp_dir(),"status":"idle","createdAt":1,"updatedAt":1
    }))
    .unwrap();
    store.save(&meta).unwrap();
    let hub = Hub::new(cfg, store);
    let session = hub.resolve("workflow-child").unwrap();
    *session.turn.lock().unwrap() = Some(TurnInfo {
        trigger: false,
        started_at: 1,
        client: "person".into(),
        prompt_preview: String::new(),
        masked_preview: String::new(),
        turn_id: "person-turn".into(),
        prompt_id: "person-prompt".into(),
        turn_seq: 1,
        control: Control::Local,
        doing: Default::default(),
        notice: false,
        persons: true,
        accepted: true,
    });
    let before = session.cancels.load(Ordering::SeqCst);
    // The activity ended before pause arrived; it must not change even the
    // session-wide cancellation generation that a later prompt will observe.
    hub.cancel_prompt(&session, "already-ended-workflow-prompt").await.unwrap();
    assert_eq!(session.cancels.load(Ordering::SeqCst), before);
    assert_eq!(session.turn().unwrap().prompt_id, "person-prompt");
}
