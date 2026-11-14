use super::*;
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn remote_workflow_agent_journals_guarded_dispatch_and_reuses_the_reply() {
    let fixture = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_workflow_agent.py");
    let mut config: crate::config::Config = serde_json::from_value(json!({"defaultHarness":"fake",
            "harnesses":{"fake":{"argv":["python3",fixture]}}}))
    .unwrap();
    config.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    let owner: SessionMeta = serde_json::from_value(json!({"schema":crate::store::META_SCHEMA,
            "id":"remote-owner","name":"Remote owner","harness":"fake","cwd":std::env::temp_dir(),
            "status":"closed","createdAt":1,"updatedAt":2}))
    .unwrap();
    store.save(&owner).unwrap();
    let hub = Hub::new(config, store);
    let run = hub
        .workflow_runs
        .store()
        .start(RunRecord {
            version: 1,
            id: format!("wf-test-{}", uuid::Uuid::now_v7().simple()),
            name: "Remote workflow".into(),
            owner_session_id: owner.id,
            local_principal: false,
            source: "await agent('schema-once')".into(),
            source_hash: String::new(),
            args: json!([]),
            allowed_tools: None,
            cwd: std::env::temp_dir(),
            generation: 1,
            state: crate::workflow_runs::State::Running,
            activities: Default::default(),
            outcome: None,
            caller_subagent: None,
        })
        .unwrap();
    let activity = ActivityRecord {
        id: "remote-agent".into(),
        kind: "agent".into(),
        fingerprint: "pinned".into(),
        child: Child::Agent {
            session_id: "pending".into(),
            prompt_id: "pending".into(),
            host: Some("local".into()),
        },
        policy: Value::Null,
        outcome: None,
    };
    hub.workflow_runs
        .store()
        .register_activity(&run.id, run.generation, &run.owner_session_id, activity.clone())
        .unwrap();
    let runner = hub.workflow_runs.issue_runner(&run).unwrap().unwrap();
    for host in ["ci", "auto"] {
        let error = crate::server::workflow_owner_call(
            &hub,
            &run.owner_session_id,
            "_acpmux/workflow_activity",
            json!({"action":"start","runId":run.id,"activityId":format!("refused-{host}"),
                    "generation":run.generation,"runnerToken":runner,"kind":"agent",
                    "prompt":"task","options":{"on":host}}),
        )
        .await
        .unwrap_err();
        assert!(error.message.contains("explicit peer"), "{error:?}");
    }
    assert_eq!(hub.workflow_runs.store().get(&run.id).unwrap().activities.len(), 1);
    let options = json!({"harness":"fake","schema":{"type":"object","required":["ok"],"properties":{"ok":{"const":true}}}});
    let explicit_cwd = remote_request(
        &run,
        &activity,
        1,
        false,
        "task",
        &json!({"cwd":"/remote/project"}),
        "paired-machine",
        &None,
    );
    assert_eq!(explicit_cwd["cwd"], "/remote/project");
    assert!(
        hub.workflow_remote_agent(
            &run,
            run.generation,
            &activity,
            "task",
            &json!({"cwd":7}),
            "local"
        )
        .await
        .is_err()
    );
    // Exercise the complete owner-authenticated RPC path in process; the
    // peer transport itself is covered by dispatch_durable integration tests.
    let value = tokio::time::timeout(
        std::time::Duration::from_secs(20),
        hub.workflow_remote_agent(
            &run,
            run.generation,
            &activity,
            "schema-once",
            &options,
            "local",
        ),
    )
    .await
    .unwrap()
    .unwrap();
    assert_eq!(value, json!({"ok":true}));
    let saved = hub.workflow_runs.store().get(&run.id).unwrap();
    let attempts =
        saved.activities.values().filter(|a| a.kind == "remote_agent_prompt").collect::<Vec<_>>();
    assert_eq!(attempts.len(), 2, "schema correction budget did not persist");
    assert!(
        attempts.iter().all(|a| a.policy.get("remoteDispatch").is_some() && a.outcome.is_some())
    );
    let request = attempts[0].policy["remoteDispatch"].clone();
    let brief_id = request["briefId"].as_str().unwrap();
    let receipt = hub.briefs.get(brief_id).unwrap();
    assert!(receipt.get("receiptToken").is_none(), "receipt leaked its capability");
    let child = receipt["sessionId"].as_str().unwrap();
    // Even a valid different local caller holding the exact request cannot
    // replay or cancel the parent's receipt through its own connection.
    assert!(
        crate::server::workflow_owner_call(
            &hub,
            child,
            crate::rpc::method::MUX_DISPATCH,
            request.clone()
        )
        .await
        .is_err()
    );
    let mut cancel = request.clone();
    cancel["action"] = json!("cancel");
    assert!(
        crate::server::workflow_owner_call(&hub, child, crate::rpc::method::MUX_DISPATCH, cancel)
            .await
            .is_err()
    );
    let listed =
        crate::server::workflow_owner_call(&hub, child, crate::rpc::method::MUX_BRIEFS, json!({}))
            .await
            .unwrap();
    assert!(listed["briefs"].as_array().unwrap().is_empty());
    let listed = crate::server::workflow_owner_call(
        &hub,
        &run.owner_session_id,
        crate::rpc::method::MUX_BRIEFS,
        json!({}),
    )
    .await
    .unwrap();
    assert_eq!(
        listed["briefs"].as_array().unwrap().len(),
        2,
        "the proven initiating caller lost its own receipt visibility"
    );
    let saved_activity = saved.activities.get(&activity.id).unwrap();
    assert_eq!(
        hub.workflow_remote_agent(
            &saved,
            saved.generation,
            saved_activity,
            "schema-once",
            &options,
            "local"
        )
        .await
        .unwrap(),
        value
    );
    let replay = hub.workflow_runs.store().get(&run.id).unwrap();
    assert_eq!(replay.activities.len(), saved.activities.len(), "replay dispatched another effect");
    assert!(
        crate::server::workflow_owner_call(
            &hub,
            "nonexistent-owner",
            crate::rpc::method::MUX_STATUS,
            json!({})
        )
        .await
        .is_err()
    );
    hub.shutdown_all().await;
    std::fs::remove_dir_all(hub.workflow_runs.store().directory(&run.id).unwrap()).unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn remote_workflow_terminal_cancel_reaches_pending_child_and_preserves_sibling() {
    use crate::server::peer_auth::{PeerAuth, token_path};
    use crate::server::{WsAuth, bind_ws, serve_ws_with};
    let config = || {
        let mut config: crate::config::Config = serde_json::from_value(json!({
            "defaultHarness":"fake", "harnesses":{"fake":{"argv":["python3",
                concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py")] }},
            "webRoots":[std::env::temp_dir()], "webAskingModes":{"fake":["normal","strict"]}
        }))
        .unwrap();
        config.store.mode = crate::config::StoreMode::Memory;
        config
    };
    let local_config = config();
    let store =
        crate::store::open(&local_config.store, std::path::Path::new("/nonexistent")).unwrap();
    let owner: SessionMeta = serde_json::from_value(json!({"schema":crate::store::META_SCHEMA,
            "id":"cancel-remote-owner","name":"Cancel remote owner","harness":"fake",
            "cwd":std::env::temp_dir(),"status":"closed","createdAt":1,"updatedAt":2}))
    .unwrap();
    store.save(&owner).unwrap();
    let hub = Hub::new(local_config, store);
    let remote_config = config();
    let remote_store =
        crate::store::open(&remote_config.store, std::path::Path::new("/nonexistent")).unwrap();
    let remote = Hub::new(remote_config, remote_store);
    let directory = tempfile::tempdir().unwrap();
    let auth = PeerAuth::create(directory.path()).unwrap();
    let token = std::fs::read_to_string(token_path(directory.path())).unwrap();
    let listener = bind_ws("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let server = tokio::spawn(serve_ws_with(
        remote.clone(),
        listener,
        "remote-cancel-target".into(),
        WsAuth { local_app: None, peer: Some(Arc::new(auth)) },
    ));
    hub.add_peer(
        "paired-target",
        &format!("ws://127.0.0.1:{port}"),
        Some("remote-cancel-target".into()),
        Some(token),
        true,
    )
    .await
    .unwrap();
    let run = hub
        .workflow_runs
        .store()
        .start(RunRecord {
            version: 1,
            id: format!("wf-test-{}", uuid::Uuid::now_v7().simple()),
            name: "Remote cancellation".into(),
            owner_session_id: owner.id,
            local_principal: false,
            source: "await agent('task')".into(),
            source_hash: String::new(),
            args: json!([]),
            allowed_tools: None,
            cwd: std::env::temp_dir(),
            generation: 1,
            state: crate::workflow_runs::State::Running,
            activities: Default::default(),
            outcome: None,
            caller_subagent: None,
        })
        .unwrap();
    let parent = ActivityRecord {
        id: "test".into(),
        kind: "agent".into(),
        fingerprint: "pinned".into(),
        child: Child::Agent {
            session_id: "parent-only".into(),
            prompt_id: "parent-only".into(),
            host: Some("paired-target".into()),
        },
        policy: Value::Null,
        outcome: None,
    };
    let request = remote_request(
        &run,
        &parent,
        1,
        false,
        "task",
        &json!({"harness":"fake"}),
        "paired-target",
        &None,
    );
    let pending = ActivityRecord {
        id: "test-remote-1-0".into(),
        kind: "remote_agent_prompt".into(),
        fingerprint: crate::workflow_runs::digest(&request.to_string()),
        child: dispatch_child(&request, "paired-target").unwrap(),
        policy: json!({"remoteDispatch":request}),
        outcome: None,
    };
    let sibling = ActivityRecord { id: "test-remote-1-1".into(), ..parent.clone() };
    for activity in [&parent, &pending, &sibling] {
        hub.workflow_runs
            .store()
            .register_activity(&run.id, run.generation, &run.owner_session_id, activity.clone())
            .unwrap();
    }
    let current = hub.workflow_runs.store().get(&run.id).unwrap();
    hub.workflow_cancel_activity(&current, &parent.id).await.unwrap();
    let current = hub.workflow_runs.store().get(&run.id).unwrap();
    assert!(
        current.activities[&pending.id].outcome.is_some(),
        "pending remote child was not cancelled"
    );
    assert!(
        current.activities[&sibling.id].outcome.is_none(),
        "reserved-looking logical sibling was cancelled"
    );
    let brief = request["briefId"].as_str().unwrap();
    assert_eq!(
        remote.briefs.get(brief).unwrap()["dispatchCancelled"],
        true,
        "terminal failure must send the exact remote cancellation tombstone"
    );
    assert!(
        matches!(&pending.child, Child::Agent { session_id, .. } if remote.resolve(session_id).is_err()),
        "pre-launch cancellation created a remote child"
    );
    hub.shutdown_all().await;
    remote.shutdown_all().await;
    server.abort();
    std::fs::remove_dir_all(hub.workflow_runs.store().directory(&run.id).unwrap()).unwrap();
}

#[test]
fn remote_workflow_reply_never_falls_back_to_another_turn() {
    assert!(reply(&json!({"brief":{"sessionId":"other"},"lastReply":"unrelated"})).is_err());
    assert_eq!(
        reply(&json!({"brief":{"outcome":{"Ok":{"finalReply":"exact","promptOutcome":{}}}}}))
            .unwrap(),
        "exact"
    );
    assert!(reply(&json!({"brief":{"outcome":{"Ok":{"finalReply":"partial","promptOutcome":{"stopReason":"cancelled"}}}}})).is_err());
}
