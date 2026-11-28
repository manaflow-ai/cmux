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
async fn automatic_restart_ordinary_prompt_hibernates_required_stale_agent() {
    let (hub, session) = live_chat().await;
    let old = session.child.lock().await.clone().expect("live fake child");
    let last_turn = session.meta().last_turn.expect("initial turn");
    hub.set_waiting_for_test(
        &session,
        last_turn["turnId"].as_str().expect("initial turn ID"),
        crate::protocol::session::RetryReason::Transport,
    );
    assert!(hub.continuation_pending(&session));
    hub.respawn_when_quiet_required(&session);
    assert_eq!(session.queued(), 0, "the ordinary prompt has not entered the queue yet");

    hub.prompt(
        &session,
        vec![json!({"type": "text", "text": "ordinary after route change"})],
        "test",
        false,
    )
    .await
    .expect("ordinary prompt after a required restart");

    let current = session.child.lock().await.clone().expect("prompt starts replacement child");
    assert!(!Arc::ptr_eq(&old, &current), "ordinary prompt reused the stale child");
    assert!(!old.is_alive().await, "quiet restart left the stale child alive");
    assert!(current.is_alive().await, "replacement child did not survive the prompt");
    assert_eq!(session.meta().hibernated_ms, 0, "the replacement has woken from hibernation");
    assert!(
        !session.respawn_when_quiet.load(Ordering::SeqCst),
        "restart mark remained after replacement"
    );
    assert!(
        !session.respawn_required.load(Ordering::SeqCst),
        "required restart mark remained after replacement"
    );
    hub.shutdown_all().await;
}

#[tokio::test]
async fn automatic_restart_deadline_defers_and_restores_next_prompt_in_order() {
    let (hub, session) = live_chat().await;
    let old = session.child.lock().await.clone().expect("live fake child");
    // Work outlives its turn and keeps the old harness alive across the admission deadline.
    *session.work_below_since.lock().unwrap() = 1;
    hub.respawn_when_quiet_required(&session);
    let (accepted, receipt) = tokio::sync::oneshot::channel();
    let opts = PromptOptions {
        prompt_id: Some("next-after-fallback".into()),
        on_accepted: Some(Box::new(move |v| {
            let _ = accepted.send(v);
        })),
        ..PromptOptions::default()
    };
    let mut next = Box::pin(hub.prompt_with(
        &session,
        vec![json!({"type": "text", "text": "next after fallback"})],
        "test",
        false,
        opts,
    ));
    let bound = std::time::Duration::from_secs(10);
    let receipt = tokio::select! {
        receipt = tokio::time::timeout(bound, receipt) => {
            receipt.expect("admission answers by its deadline").unwrap()
        }
        result = &mut next => panic!("prompt completed before its held harness was quiet: {result:?}"),
    };
    assert_eq!(receipt["state"], "queued", "{receipt}");
    assert_eq!(receipt["deferred"], true, "{receipt}");
    let (accepted, later_receipt) = tokio::sync::oneshot::channel();
    let mut later = Box::pin(hub.prompt_with(
        &session,
        vec![json!({"type": "text", "text": "later prompt"})],
        "test",
        false,
        PromptOptions {
            prompt_id: Some("later-prompt".into()),
            on_accepted: Some(Box::new(move |v| {
                let _ = accepted.send(v);
            })),
            ..PromptOptions::default()
        },
    ));
    let later_receipt = tokio::select! {
        receipt = tokio::time::timeout(bound, later_receipt) => {
            receipt.expect("the later prompt is accepted while work continues").unwrap()
        }
        result = &mut later => panic!("later prompt ran while work continued: {result:?}"),
    };
    assert_eq!(later_receipt["state"], "queued", "{later_receipt}");
    assert!(old.is_alive().await, "the harness was ended during active work");
    let dispatched = || {
        hub.events(&session.id, 0, 10_000)
            .unwrap()
            .into_iter()
            .filter(|r| r.kind == "user_message")
            .map(|r| r.msg["promptId"].clone())
            .filter(|id| matches!(id.as_str(), Some("next-after-fallback" | "later-prompt")))
            .collect::<Vec<_>>()
    };
    assert!(dispatched().is_empty(), "prompts were dispatched before the old child was quiet");
    *session.work_below_since.lock().unwrap() = 0;
    let (next, later) = tokio::time::timeout(bound, async { tokio::join!(next, later) })
        .await
        .expect("both prompts proceed once the harness is quiet");
    for reply in [next.unwrap(), later.unwrap()] {
        assert_eq!(reply["stopReason"], "end_turn", "{reply}");
    }
    assert_eq!(dispatched(), [json!("next-after-fallback"), json!("later-prompt")]);
    let current = session.child.lock().await.clone().expect("replacement child");
    assert!(!Arc::ptr_eq(&old, &current), "the restored prompt reused the stale child");
    assert!(!old.is_alive().await);
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
