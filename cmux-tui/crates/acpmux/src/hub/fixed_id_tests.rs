use super::*;

fn test_hub(root: Option<&std::path::Path>) -> Arc<Hub> {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: crate::config::Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    cfg.store.mode = if root.is_some() {
        crate::config::StoreMode::Local
    } else {
        crate::config::StoreMode::Memory
    };
    let store =
        crate::store::open(&cfg.store, root.unwrap_or(std::path::Path::new("/nonexistent")))
            .unwrap();
    Hub::new(cfg, store)
}

fn request() -> NewRequest {
    NewRequest { cwd: Some(std::env::temp_dir()), ..Default::default() }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn concurrent_fixed_id_creations_publish_exactly_one_session() {
    let hub = test_hub(None);
    let id = uuid::Uuid::now_v7().to_string();
    let (a, b) = tokio::join!(
        hub.new_session_with_id(request(), Some(id.clone())),
        hub.new_session_with_id(request(), Some(id.clone())),
    );
    assert_ne!(a.is_ok(), b.is_ok(), "exactly one creation must win");
    let winner = a.ok().or_else(|| b.ok()).unwrap();
    assert_eq!(winner.id, id);
    assert!(Arc::ptr_eq(&hub.resolve(&id).unwrap(), &winner));
    assert_eq!(hub.sessions.lock().unwrap().len(), 1);
    hub.shutdown_all().await;
}

#[tokio::test]
async fn fixed_id_refuses_persisted_chat_after_restart() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-fixed");
    let hub = test_hub(Some(dir.path()));
    let id = uuid::Uuid::now_v7().to_string();
    let original = hub.new_session_with_id(request(), Some(id.clone())).await.unwrap();
    hub.shutdown_all().await;
    drop(hub);
    let restarted = test_hub(Some(dir.path()));
    let before = restarted.store.load(&id).unwrap().unwrap();
    assert!(restarted.new_session_with_id(request(), Some(id.clone())).await.is_err());
    let after = restarted.store.load(&id).unwrap().unwrap();
    assert_eq!(after.created_at, before.created_at);
    assert_eq!(after.agent_session_id, original.meta().agent_session_id);
    restarted.shutdown_all().await;
}

#[tokio::test]
async fn fixed_id_refuses_partial_or_corrupt_durable_chat() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-fixed-corrupt");
    let hub = test_hub(Some(dir.path()));
    let id = uuid::Uuid::now_v7().to_string();
    let path = hub.store.session_dir(&id).unwrap();
    std::fs::create_dir_all(&path).unwrap();
    assert!(hub.new_session_with_id(request(), Some(id.clone())).await.is_err());
    std::fs::write(path.join("session.json"), "unreadable metadata").unwrap();
    assert!(hub.new_session_with_id(request(), Some(id)).await.is_err());
    assert_eq!(std::fs::read_to_string(path.join("session.json")).unwrap(), "unreadable metadata");
    hub.shutdown_all().await;
}

#[tokio::test]
async fn fixed_id_cannot_take_an_import_reservation() {
    let hub = test_hub(None);
    let id = uuid::Uuid::now_v7().to_string();
    hub.importing.lock().unwrap().insert(id.clone());
    assert!(hub.new_session_with_id(request(), Some(id.clone())).await.is_err());
    assert!(hub.sessions.lock().unwrap().is_empty());
    assert!(hub.store.load(&id).unwrap().is_none());
    hub.importing.lock().unwrap().remove(&id);
    hub.shutdown_all().await;
}

#[tokio::test]
async fn fixed_id_cannot_adopt_a_different_chat() {
    let hub = test_hub(None);
    let mut req = request();
    req.adopt = crate::adopt::AdoptRequest::from_meta(Some(&json!({
        "adopt": {"agentSessionId": "another-chat"}
    })))
    .unwrap();
    let result = hub.new_session_with_id(req, Some("fixed-chat".into())).await;
    assert!(result.err().unwrap().message.contains("cannot adopt"));
    assert!(hub.sessions.lock().unwrap().is_empty());
    hub.shutdown_all().await;
}

#[tokio::test]
async fn failed_creation_cleanup_leaves_replacement_incarnation_intact() {
    let hub = test_hub(None);
    let id = uuid::Uuid::now_v7().to_string();
    let original = hub.new_session_with_id(request(), Some(id.clone())).await.unwrap();
    hub.kill(&original, false).await.unwrap();
    let replacement = hub.make_session(original.meta());
    hub.sessions.lock().unwrap().insert(id.clone(), replacement.clone());
    hub.write_meta(&replacement).unwrap();
    let before = hub.events(&id, 0, 10000).unwrap().len();
    hub.discard_failed_creation_owned(&original, original.stops.load(Ordering::SeqCst), None).await;
    assert!(Arc::ptr_eq(&hub.resolve(&id).unwrap(), &replacement));
    assert!(hub.store.load(&id).unwrap().is_some());
    assert_eq!(hub.events(&id, 0, 10000).unwrap().len(), before);
    assert!(!replacement.purged.load(Ordering::SeqCst));
    hub.shutdown_all().await;
}

#[test]
fn fixed_id_accepts_bare_session_ids_only() {
    assert!(crate::adopt::is_bare_id("0192f7f4-8f53-7c10-8f1c-2f950f3e2d9a"));
    assert!(crate::adopt::is_bare_id("codex_session_1"));
    assert!(!crate::adopt::is_bare_id("../escape"));
    assert!(!crate::adopt::is_bare_id(""));
    assert!(!crate::adopt::is_bare_id(&"x".repeat(129)));
}
