use super::*;

/// A guarded receive of `policy` (none: unset) from the person's own machine (`Control::Peer`).
async fn received(policy: Option<&str>) -> SessionMeta {
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
    cfg.harnesses.insert("benchecho".into(), profile);
    cfg.store.mode = crate::config::StoreMode::Local;
    let hub = Hub::new(cfg.clone(), crate::store::open(&cfg.store, &dir).unwrap());
    let bundle = dir.join("bundle");
    std::fs::create_dir_all(&bundle).unwrap();
    let mut meta = json!({
        "schema": crate::store::META_SCHEMA, "id": uuid::Uuid::now_v7().to_string(),
        "name": "moved", "harness": "benchecho", "cwd": work,
        "status": "idle", "createdAt": 1, "updatedAt": 1,
    });
    if let Some(p) = policy {
        meta["permissionPolicy"] = json!(p);
        meta["policySource"] = json!("set");
    }
    std::fs::write(bundle.join("session.json"), meta.to_string()).unwrap();
    let guard = Guard { control: Control::Peer, roots: vec![work], owner: true };
    let (meta, _) = hub.guard_session(&bundle, &guard, None, &json!({}), None).await.unwrap();
    let _ = std::fs::remove_dir_all(&dir);
    meta
}

/// Super-highway ring, 2026-11-28: a chat with no policy of its own came out of every move as
/// `ask`, so each start after a move held it to a mode that asks and refused a harness that
/// cannot ask: 124 of 203 messages were lost. A move between the person's machines keeps it unset.
#[tokio::test]
async fn a_peer_move_keeps_a_chat_with_no_policy_unset() {
    assert_eq!(received(None).await.permission_policy, None);
}

#[tokio::test]
async fn a_peer_move_keeps_the_policy_a_chat_has() {
    assert_eq!(
        received(Some("approve-reads")).await.permission_policy.as_deref(),
        Some("approve-reads")
    );
    assert_eq!(received(Some("ask")).await.permission_policy.as_deref(), Some("ask"));
}
