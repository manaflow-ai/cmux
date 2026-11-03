use super::*;
use serde_json::json;

fn spec() -> RunRecord {
    RunRecord {
        version: 0,
        id: "wf-test".into(),
        name: "Release".into(),
        owner_session_id: "owner".into(),
        local_principal: false,
        source: "return agent('check');".into(),
        source_hash: String::new(),
        args: json!(["nightly"]),
        allowed_tools: Some(vec!["acpmux_send".into()]),
        cwd: std::env::temp_dir(),
        generation: 0,
        state: State::Paused,
        activities: BTreeMap::new(),
        outcome: None,
    }
}

#[test]
fn restart_preserves_pinned_inputs_and_refuses_mutation() {
    let dir = tempfile::tempdir().unwrap();
    let store = Store::new(dir.path().into());
    let run = store.start(spec()).unwrap();
    let reopened = Store::new(dir.path().into());
    assert_eq!(reopened.get(&run.id).unwrap(), run);
    for change in [0, 1, 2, 3] {
        let mut other = spec();
        match change {
            0 => other.source.push_str("different"),
            1 => other.args = json!(["other"]),
            2 => other.allowed_tools = None,
            _ => other.owner_session_id = "other".into(),
        }
        assert!(reopened.start(other).is_err());
    }
}

#[test]
fn pause_fences_every_late_runner_mutation_and_resume_gets_a_new_generation() {
    let dir = tempfile::tempdir().unwrap();
    let store = Store::new(dir.path().into());
    let run = store.start(spec()).unwrap();
    assert!(store.pause(&run.id, "intruder").is_err());
    let paused = store.pause(&run.id, "owner").unwrap();
    assert_eq!(paused.state, State::Pausing);
    assert!(paused.generation > run.generation);
    assert!(store.authorize(&run.id, run.generation, "owner").is_err());
    assert!(store.settle(&run.id, run.generation, "owner", Ok(json!("late"))).is_err());
    assert!(store.resume(&run.id, "owner", false).is_err());
    store.paused(&run.id, paused.generation).unwrap();
    let resumed = store.resume(&run.id, "owner", false).unwrap();
    assert!(resumed.generation > paused.generation);
    assert_eq!(resumed.source, run.source);
    assert!(store.settle(&run.id, resumed.generation, "intruder", Ok(json!("bad"))).is_err());
    store.settle(&run.id, resumed.generation, "owner", Ok(json!("done"))).unwrap();
    assert!(store.resume(&run.id, "owner", false).is_err());
}

#[test]
fn durable_activity_identity_is_exact_and_results_survive_resume() {
    let dir = tempfile::tempdir().unwrap();
    let store = Store::new(dir.path().into());
    let run = store.start(spec()).unwrap();
    let activity = ActivityRecord {
        id: "activity-1".into(),
        kind: "agent".into(),
        fingerprint: "hash".into(),
        child: Child::Agent { session_id: "child".into(), prompt_id: "prompt".into(), host: None },
        policy: Value::Null,
        outcome: None,
    };
    store.register_activity(&run.id, run.generation, "owner", activity.clone()).unwrap();
    let mut other = activity.clone();
    other.fingerprint = "another prompt".into();
    assert!(store.register_activity(&run.id, run.generation, "owner", other).is_err());
    let policy = json!({"attempt":1,"correction":"return JSON"});
    store
        .update_activity_policy(&run.id, run.generation, "owner", &activity.id, policy.clone())
        .unwrap();
    assert_eq!(
        store.activity(&run.id, run.generation, "owner", &activity.id).unwrap().unwrap().policy,
        policy
    );
    let outcome = Ok(json!({"reply":"green"}));
    store
        .complete_activity(&run.id, run.generation, "owner", &activity.id, outcome.clone())
        .unwrap();
    let paused = store.pause(&run.id, "owner").unwrap();
    assert!(
        store
            .update_activity_policy(&run.id, run.generation, "owner", &activity.id, json!({}))
            .is_err()
    );
    store.paused(&run.id, paused.generation).unwrap();
    let resumed = store.resume(&run.id, "owner", false).unwrap();
    assert_eq!(
        store
            .activity(&run.id, resumed.generation, "owner", &activity.id)
            .unwrap()
            .unwrap()
            .outcome,
        Some(outcome)
    );
}

#[test]
fn launch_proofs_are_ephemeral_and_old_proofs_fail_after_resume() {
    let dir = tempfile::tempdir().unwrap();
    let service = Service::with_root(dir.path().into());
    let run = service.store().start(spec()).unwrap();
    let proof = service.issue_runner(&run).unwrap().unwrap();
    assert!(service.issue_runner(&run).unwrap().is_none());
    assert!(service.authorize_runner(&run.id, run.generation, &proof).is_ok());
    let raw = std::fs::read_to_string(service.store().directory(&run.id).unwrap().join("run.json"))
        .unwrap();
    assert!(!raw.contains(&proof));
    let restarted = Service::with_root(dir.path().into());
    assert!(restarted.authorize_runner(&run.id, run.generation, &proof).is_err());
    let paused = service.store().pause(&run.id, "owner").unwrap();
    assert!(service.authorize_runner(&run.id, run.generation, &proof).is_err());
    service.store().paused(&run.id, paused.generation).unwrap();
    let resumed = service.store().resume(&run.id, "owner", false).unwrap();
    let fresh = service.issue_runner(&resumed).unwrap().unwrap();
    assert_ne!(fresh, proof);
    assert!(service.authorize_runner(&run.id, resumed.generation, &proof).is_err());
}

#[test]
fn source_corruption_and_path_traversal_fail_closed() {
    let dir = tempfile::tempdir().unwrap();
    let store = Store::new(dir.path().into());
    assert!(store.directory("../elsewhere").is_err());
    let run = store.start(spec()).unwrap();
    let path = store.directory(&run.id).unwrap().join("run.json");
    let mut value = serde_json::to_value(run).unwrap();
    value["source"] = json!("return 0");
    std::fs::write(path, serde_json::to_vec(&value).unwrap()).unwrap();
    assert!(store.get("wf-test").is_err());
}

#[tokio::test]
async fn pause_waits_for_owned_runner_exit_before_resume_can_take_the_journal() {
    let dir = tempfile::tempdir().unwrap();
    let service = std::sync::Arc::new(Service::with_root(dir.path().into()));
    let run = service.store().start(spec()).unwrap();
    let proof = service.issue_runner(&run).unwrap().unwrap();
    let (stop, finished) = service.track_runner(&run.id, run.generation);
    let (observed, wait_observed) = tokio::sync::oneshot::channel();
    let (allow_exit, exit_allowed) = tokio::sync::oneshot::channel();
    let child = tokio::spawn(async move {
        stop.await.unwrap();
        observed.send(()).unwrap();
        exit_allowed.await.unwrap();
        finished.send(()).unwrap();
    });
    let stopping = {
        let service = service.clone();
        let id = run.id.clone();
        tokio::spawn(async move { service.stop_runner(&id).await })
    };
    wait_observed.await.unwrap();
    assert!(!stopping.is_finished(), "pause acknowledged before owned runner exited");
    assert!(service.authorize_runner(&run.id, run.generation, &proof).is_err());
    allow_exit.send(()).unwrap();
    child.await.unwrap();
    stopping.await.unwrap();
}

#[test]
fn a_corrupt_run_does_not_hide_other_recoverable_workflows() {
    let dir = tempfile::tempdir().unwrap();
    let store = Store::new(dir.path().into());
    let run = store.start(spec()).unwrap();
    let mut other = spec();
    other.id = "wf-corrupt".into();
    store.start(other).unwrap();
    std::fs::write(store.directory("wf-corrupt").unwrap().join("run.json"), b"broken").unwrap();
    assert_eq!(store.list().unwrap(), vec![run]);
    assert!(store.get("wf-corrupt").is_err());
}
