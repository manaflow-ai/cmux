use super::*;

/// Review of #27851: a guarded move with no agent file starts its agent fresh, but its
/// acpmux history still names the old root, so that root stays retired (never a worker).
#[tokio::test]
async fn a_guarded_move_without_its_agent_file_retires_the_old_root() {
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
    let meta = json!({
        "schema": crate::store::META_SCHEMA, "id": uuid::Uuid::now_v7().to_string(),
        "name": "moved", "harness": "codex", "cwd": work, "agentSessionId": "root-now",
        "retiredAgentSessionIds": ["root-before"],
        "status": "idle", "createdAt": 1, "updatedAt": 1,
    });
    std::fs::write(bundle.join("session.json"), meta.to_string()).unwrap();
    let guard = Guard { control: Control::Peer, roots: vec![work] };
    let (meta, taken) = hub.guard_session(&bundle, &guard, None, &json!({}), None).await.unwrap();
    assert!(!taken);
    assert_eq!(meta.agent_session_id, None, "no agent file: the agent starts fresh");
    assert_eq!(meta.retired_agent_session_ids, ["root-before", "root-now"]);
    assert!(meta.previous_agent_session_ids.is_empty(), "never transcript authority");
    let written: SessionMeta =
        serde_json::from_slice(&std::fs::read(bundle.join("session.json")).unwrap()).unwrap();
    assert_eq!(written.retired_agent_session_ids, ["root-before", "root-now"]);
    let _ = std::fs::remove_dir_all(&dir);
}
