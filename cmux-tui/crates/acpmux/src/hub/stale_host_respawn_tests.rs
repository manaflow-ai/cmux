use super::*;

#[test]
fn only_a_host_whose_running_file_differs_from_its_launch_path_is_stale() {
    let stale = stale_hosts([
        ("moved".to_owned(), Some((1, 10)), Some((1, 20))),
        ("current".to_owned(), Some((1, 20)), Some((1, 20))),
        ("unreadable".to_owned(), None, Some((1, 20))),
        ("relative".to_owned(), Some((1, 10)), None),
    ]);
    assert_eq!(stale, BTreeSet::from(["moved".to_owned()]));
}

#[cfg(unix)]
#[test]
fn a_moved_file_is_stale_and_a_symlink_or_hard_link_to_it_is_not() {
    let dir = tempfile::tempdir().unwrap();
    let bin = dir.path().join("cmux");
    std::fs::write(&bin, b"old").unwrap();
    let link = dir.path().join("acpmux");
    std::os::unix::fs::symlink(&bin, &link).unwrap();
    let hard = dir.path().join("hard");
    std::fs::hard_link(&bin, &hard).unwrap();
    let running = file_id(&bin);
    assert_eq!(running, file_id(&link));
    assert_eq!(running, file_id(&hard));
    // The update: the old file moves away and a new one takes its path.
    std::fs::rename(&bin, dir.path().join("backup-cmux")).unwrap();
    std::fs::write(&bin, b"new").unwrap();
    assert_ne!(running, file_id(&link));
}

#[test]
fn this_process_is_not_stale() {
    let pid = std::process::id();
    if let (Some(running), Some(launched)) = (running_file(pid), launched_file(pid)) {
        assert_eq!(running, launched);
    }
}

async fn live_chat() -> (Arc<Hub>, Arc<Session>) {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut config: crate::config::Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    config.store.mode = crate::config::StoreMode::Memory;
    config.profile_sources = crate::config::ProfileSources::none();
    let store = crate::store::open(&config.store, Path::new("/unused")).unwrap();
    let hub = Hub::new(config, store);
    let session = hub
        .new_session(NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() })
        .await
        .unwrap();
    hub.prompt(&session, vec![json!({"type": "text", "text": "hello"})], "test", false)
        .await
        .unwrap();
    (hub, session)
}

#[tokio::test]
async fn automatic_restart_keeps_queued_prompts_and_work_below_even_before_retry() {
    let (hub, session) = live_chat().await;
    let first = session.child.lock().await.clone().unwrap();
    session.queued.fetch_add(1, Ordering::SeqCst);
    for retry in [None, Some(0)] {
        assert!(!hub.end_quiet_stale(&session, "test", retry).await);
    }
    session.queued.fetch_sub(1, Ordering::SeqCst);
    *session.work_below_since.lock().unwrap() = 1;
    for retry in [None, Some(0)] {
        assert!(!hub.end_quiet_stale(&session, "test", retry).await);
    }
    assert!(Arc::ptr_eq(&first, session.child.lock().await.as_ref().unwrap()));
    *session.work_below_since.lock().unwrap() = 0;
    assert!(hub.end_quiet_stale(&session, "test", None).await);
    assert!(session.child.lock().await.is_none());
    assert_ne!(session.meta().hibernated_ms, 0);
    hub.shutdown_all().await;
}

#[tokio::test]
async fn automatic_restart_retry_preserves_held_prompts_but_waits_for_admission() {
    let (hub, session) = live_chat().await;
    hub.append(
        &session,
        "mux",
        "queued",
        json!({"promptId": "held", "turnId": "held-turn", "text": "after retry", "client": "test"}),
    );
    hub.append(&session, "mux", "queue_paused", json!({"held": ["held"]}));
    hub.restore_queue(&session);
    assert_eq!(session.queued(), 1);
    assert!(session.queue()[0].held);
    assert!(!hub.end_quiet_stale(&session, "test", None).await);

    // A second prompt has reserved its count but is not in the durable queue yet.
    session.queued.fetch_add(1, Ordering::SeqCst);
    assert!(!hub.end_quiet_stale(&session, "test", Some(0)).await);
    assert!(session.child.lock().await.is_some());
    session.queued.fetch_sub(1, Ordering::SeqCst);

    // Once admission ends, the retry can replace its agent without releasing or losing
    // the failed turn's held prompt. That prompt still waits for the continuation.
    assert!(hub.end_quiet_stale(&session, "test", Some(0)).await);
    assert!(session.child.lock().await.is_none());
    assert_eq!(session.queued(), 1);
    let queue = session.queue();
    assert_eq!(queue[0].prompt_id, "held");
    assert!(queue[0].held);
    hub.shutdown_all().await;
}

#[cfg(unix)]
#[tokio::test]
async fn automatic_restart_censuses_unreported_work_before_ending_a_stale_agent() {
    let (hub, session) = live_chat().await;
    let dir = tempfile::tempdir().unwrap();
    let probe = dir.path().join("child.json");
    hub.prompt(
        &session,
        vec![json!({"type": "text",
        "text": format!("class-probe: {}", probe.display())})],
        "test",
        false,
    )
    .await
    .unwrap();
    assert!(hub.idle_eligible(&session), "the child is absent from the agent's work tables");
    let first = session.child.lock().await.clone().unwrap();
    for retry in [None, Some(0)] {
        assert!(
            !hub.end_quiet_stale(&session, "test", retry).await,
            "an automatic restart cut an unreported child (retry={retry:?})"
        );
    }
    assert!(Arc::ptr_eq(&first, session.child.lock().await.as_ref().unwrap()));
    assert_eq!(session.meta().hibernated_ms, 0);
    hub.shutdown_all().await;
}

#[tokio::test]
async fn a_daemon_with_no_running_agents_restarts_no_stale_proxy_agent() {
    let mut config: crate::config::Config =
        serde_json::from_value(serde_json::json!({"harnesses": {}})).unwrap();
    config.store.mode = crate::config::StoreMode::Memory;
    config.profile_sources = crate::config::ProfileSources::none();
    let store = crate::store::open(&config.store, Path::new("/unused")).unwrap();
    let out = Hub::new(config, store).respawn_stale_proxies().await;
    assert_eq!((out.now, out.after_turn, out.failed.len()), (0, 0, 0));
}

#[tokio::test]
async fn a_daemon_with_no_running_agents_restarts_nothing() {
    let mut config: crate::config::Config =
        serde_json::from_value(serde_json::json!({"harnesses": {}})).unwrap();
    config.store.mode = crate::config::StoreMode::Memory;
    config.profile_sources = crate::config::ProfileSources::none();
    let store = crate::store::open(&config.store, Path::new("/unused")).unwrap();
    let out = Hub::new(config, store).respawn_stale_hosts().await;
    assert_eq!((out.now, out.after_turn, out.failed.len()), (0, 0, 0));
}
