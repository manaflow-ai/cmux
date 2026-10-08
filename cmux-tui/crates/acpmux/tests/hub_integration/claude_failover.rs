//! A Claude session moved onto its fallback profile (or respawned after its
//! process died) resumes only a conversation Claude stored. A launcher that
//! died before its first prompt reached Claude stored nothing, so `--resume`
//! of its id fails with "No conversation found with session ID" and the
//! whole turn failed (cmux-lawrence Chief, 2026-10-08: claude-sr's proxy
//! died, the `claude` fallback resumed the never-stored id).
use super::*;

/// A hub with two Claude stdio profiles over one fake session store:
/// `primary` dies on its first prompt and falls back to `direct`.
async fn claude_failover_setup(store: &std::path::Path) -> (Arc<Hub>, TestClient) {
    let fake_claude = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude.py");
    let profile = |die: bool, fallback: Option<&str>| HarnessProfile {
        kind: acpmux::config::HarnessKind::ClaudeStdio,
        argv: vec!["python3".into(), fake_claude.into()],
        env: {
            let mut env = BTreeMap::from([(
                "FAKE_CLAUDE_STORE".to_owned(),
                store.to_string_lossy().into_owned(),
            )]);
            if die {
                env.insert("FAKE_CLAUDE_DIE".into(), "1".into());
            }
            env
        },
        description: None,
        fallback: fallback.map(str::to_owned),
        family: None,
        models: vec![],
        model: None,
        effort: None,
        policy: None,
    };
    let agents = BTreeMap::from([
        ("primary".to_owned(), profile(true, Some("direct"))),
        ("direct".to_owned(), profile(false, None)),
    ]);
    let mut cfg =
        Config { harnesses: agents, default_harness: Some("primary".into()), ..Default::default() };
    cfg.store.mode = StoreMode::Memory;
    cfg.permission_policy = PermissionPolicy::ApproveAll;
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection(hub.clone(), in_rx, out_tx));
    let mut c = TestClient { tx: in_tx, rx: out_rx, next: 0 };
    c.request(method::INITIALIZE, json!({"protocolVersion": 1, "clientInfo": {"name": "test"}}))
        .await
        .unwrap();
    (hub, c)
}

#[tokio::test]
async fn a_fallback_never_resumes_a_conversation_the_dead_launcher_never_stored() {
    let store = std::env::temp_dir().join(format!("acpmux-claude-store-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&store).unwrap();
    let (hub, mut c) = claude_failover_setup(&store).await;
    let s = c
        .request(
            method::SESSION_NEW,
            json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": {"name": "cfo"}}}),
        )
        .await
        .unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let r = c
        .request(
            method::SESSION_PROMPT,
            json!({"sessionId": id, "prompt": [{"type": "text", "text": "hello"}]}),
        )
        .await;
    let session = hub.resolve(&id).unwrap();
    let kinds: Vec<String> =
        hub.events(&id, 0, 1000).unwrap().into_iter().map(|e| e.kind).collect();
    assert!(kinds.iter().any(|k| k == "failover"), "{kinds:?} {r:?}");
    assert_eq!(hub.session_summary(&session)["harness"], "direct");
    // The fallback answered this turn: a fresh conversation, not a resume.
    let ok = r.expect("the fallback answers the turn");
    assert_eq!(ok["stopReason"], "end_turn");

    // The fallback's conversation is stored now, so a respawn resumes it.
    hub.detach_child(&session).await;
    let again = c
        .request(
            method::SESSION_PROMPT,
            json!({"sessionId": id, "prompt": [{"type": "text", "text": "again"}]}),
        )
        .await
        .expect("a stored conversation resumes");
    assert_eq!(again["stopReason"], "end_turn");
    let resumed = hub
        .events(&id, 0, 1000)
        .unwrap()
        .into_iter()
        .filter(|e| e.kind == "resumed")
        .map(|e| e.msg["level"].as_str().unwrap_or("").to_owned())
        .collect::<Vec<_>>();
    assert_eq!(resumed, ["exact"], "the respawn resumes the stored conversation");
    let _ = std::fs::remove_dir_all(&store);
}

/// A daemon restart between a fresh Claude spawn and its first finished
/// turn (a dogfood reload) keeps the "never stored" mark: the session
/// record carries it, so the respawn after the restart starts fresh too.
#[tokio::test]
async fn a_restart_before_the_first_turn_still_never_resumes_an_unstored_conversation() {
    let root = std::env::temp_dir().join(format!("acpmux-claude-restart-{}", uuid::Uuid::now_v7()));
    let claude_store = root.join("claude");
    let state = root.join("acpmux");
    std::fs::create_dir_all(&claude_store).unwrap();
    let fake_claude = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude.py");
    let agents = BTreeMap::from([(
        "direct".to_owned(),
        HarnessProfile {
            kind: acpmux::config::HarnessKind::ClaudeStdio,
            argv: vec!["python3".into(), fake_claude.into()],
            env: BTreeMap::from([(
                "FAKE_CLAUDE_STORE".to_owned(),
                claude_store.to_string_lossy().into_owned(),
            )]),
            description: None,
            fallback: None,
            family: None,
            models: vec![],
            model: None,
            effort: None,
            policy: None,
        },
    )]);
    let mut cfg =
        Config { harnesses: agents, default_harness: Some("direct".into()), ..Default::default() };
    cfg.store.mode = StoreMode::Local;
    cfg.permission_policy = PermissionPolicy::ApproveAll;
    let connect = |hub: Arc<Hub>| async move {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection(hub, in_rx, out_tx));
        let mut c = TestClient { tx: in_tx, rx: out_rx, next: 0 };
        c.request(
            method::INITIALIZE,
            json!({"protocolVersion": 1, "clientInfo": {"name": "test"}}),
        )
        .await
        .unwrap();
        c
    };
    let hub = Hub::new(cfg.clone(), acpmux::store::open(&cfg.store, &state).unwrap());
    let mut c = connect(hub.clone()).await;
    let s = c
        .request(
            method::SESSION_NEW,
            json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": {"name": "reload"}}}),
        )
        .await
        .unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    // The daemon restarts before any prompt reached Claude.
    hub.shutdown_all().await;
    drop(c);
    drop(hub);
    let hub = Hub::new(cfg.clone(), acpmux::store::open(&cfg.store, &state).unwrap());
    let mut c = connect(hub.clone()).await;
    let r = c
        .request(
            method::SESSION_PROMPT,
            json!({"sessionId": id, "prompt": [{"type": "text", "text": "after the reload"}]}),
        )
        .await
        .expect("the first prompt after the restart starts a fresh conversation");
    assert_eq!(r["stopReason"], "end_turn");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}
