use super::*;

/// A guarded receive of `meta_policy` under `guard_of(work)`: the policy the chat lands with.
async fn landed_policy(meta_policy: Option<&str>, owner: bool) -> Option<String> {
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
    if let Some(p) = meta_policy {
        meta["permissionPolicy"] = json!(p);
        meta["policySource"] = json!(super::super::policy_source::SET);
    }
    std::fs::write(bundle.join("session.json"), meta.to_string()).unwrap();
    let guard = Guard { control: Control::Peer, roots: vec![work], owner };
    let (meta, _) = hub.guard_session(&bundle, &guard, None, &json!({}), None).await.unwrap();
    let _ = std::fs::remove_dir_all(&dir);
    meta.permission_policy
}

/// The offload round-trip probe, 2026-11-28 10:54Z: a benchecho chat moved by its own person
/// landed pinned to `ask`, which benchecho cannot keep, so every start was refused and the moved
/// chat took the probe's prompt into its inbox and never answered. The person's own move keeps
/// a chat that names no policy on none (this daemon's default); any other guarded receive asks.
#[tokio::test]
async fn the_persons_own_move_keeps_no_policy_and_others_ask() {
    assert_eq!(landed_policy(None, true).await, None, "own move: this daemon's default");
    assert_eq!(landed_policy(None, false).await.as_deref(), Some("ask"), "not theirs: asks");
    assert_eq!(landed_policy(Some("approve-all"), true).await.as_deref(), Some("approve-all"));
    assert_eq!(landed_policy(Some("ask"), true).await.as_deref(), Some("ask"));
}
