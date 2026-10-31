//! A purged session stays purged (2026-10-20). The Chief's compactor purges
//! each node's session as soon as the node is built; the chat's generated
//! title arrived a few seconds later and saved the session's record again,
//! so the next daemon start loaded every one of them as a closed session
//! (about 450 `optchat-compact-*` rows in two hours).

use super::*;

/// A daemon config with a store on disk whose title command waits a moment,
/// touches `mark` and prints a title.
fn titled_config(mark: &std::path::Path) -> Config {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut agents = BTreeMap::new();
    agents.insert(
        "fake".to_owned(),
        HarnessProfile {
            kind: Default::default(),
            argv: vec!["python3".into(), fake.into()],
            env: BTreeMap::new(),
            description: None,
            fallback: None,
            family: None,
            models: vec![],
            model: None,
            effort: None,
            policy: None,
        },
    );
    let mut cfg =
        Config { harnesses: agents, default_harness: Some("fake".into()), ..Default::default() };
    cfg.store.mode = StoreMode::Local;
    cfg.permission_policy = PermissionPolicy::ApproveAll;
    cfg.titles.command = Some(vec![
        "/bin/sh".into(),
        "-c".into(),
        format!("cat >/dev/null; sleep 0.5; touch '{}'; echo 'A late title'", mark.display()),
    ]);
    cfg
}

#[tokio::test]
async fn a_title_that_arrives_after_the_purge_does_not_bring_the_session_back() {
    let dir = std::env::temp_dir().join(format!("acpmux-purged-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&dir).unwrap();
    let mark = dir.join("titled");
    let cfg = titled_config(&mark);
    let hub = Hub::new(cfg.clone(), acpmux::store::open(&cfg.store, &dir).unwrap());
    let mut c = connect(&hub).await;
    // No name: the chat is titled after its first turn.
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    c.request(method::SESSION_PROMPT, prompt(&id, "summarize the chat", None)).await.unwrap();
    // Purged as soon as the turn ends, as the compactor does.
    c.request("_acpmux/kill", json!({"sessionId": id, "purge": true})).await.unwrap();
    let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    while !mark.exists() {
        assert!(tokio::time::Instant::now() < deadline, "the title command never ran");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    // The title's own save runs right after its command prints.
    tokio::time::sleep(Duration::from_secs(2)).await;
    hub.shutdown_all().await;
    drop(hub);

    let hub2 = Hub::new(cfg.clone(), acpmux::store::open(&cfg.store, &dir).unwrap());
    assert!(hub2.resolve(&id).is_err(), "the purged session came back after a restart");
    assert!(
        hub2.sessions().iter().all(|s| s.id != id),
        "the purged session is listed after a restart"
    );
    let _ = std::fs::remove_dir_all(&dir);
}
