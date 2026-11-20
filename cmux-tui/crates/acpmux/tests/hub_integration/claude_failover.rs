//! A Claude session moved onto its fallback profile (or respawned after its
//! process died) resumes only a conversation Claude stored. A launcher that
//! died before its first prompt reached Claude stored nothing, so `--resume`
//! of its id fails with "No conversation found with session ID" and the
//! whole turn failed (cmux-lawrence Chief, 2026-10-08: claude-sr's proxy
//! died, the `claude` fallback resumed the never-stored id).
use super::*;

/// A hub with two Claude stdio profiles over one fake session store:
/// `primary` fails authentication on its first prompt and falls back to `direct`.
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
                env.insert("FAKE_CLAUDE_AUTH_FAIL".into(), "1".into());
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

/// A Claude conversation lives in the store of the profile that ran it
/// (its CLAUDE_CONFIG_DIR). A failover onto a profile with another store
/// after a finished turn resumed an id that store never had: "No
/// conversation found with session ID" (E1, 2026-10-09). The fallback
/// starts a fresh conversation, with the restored transcript, instead.
#[tokio::test]
async fn a_failover_to_another_store_starts_fresh_with_the_transcript() {
    let root = std::env::temp_dir().join(format!("acpmux-claude-stores-{}", uuid::Uuid::now_v7()));
    let (store_a, store_b, die) = (root.join("a"), root.join("b"), root.join("die"));
    std::fs::create_dir_all(&store_a).unwrap();
    std::fs::create_dir_all(&store_b).unwrap();
    let fake_claude = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude.py");
    let profile = |store: &std::path::Path, fallback: Option<&str>| {
        let mut env = BTreeMap::from([(
            "CLAUDE_CONFIG_DIR".to_owned(),
            store.to_string_lossy().into_owned(),
        )]);
        if fallback.is_some() {
            env.insert("FAKE_CLAUDE_DIE_IF".into(), die.to_string_lossy().into_owned());
            env.insert("FAKE_CLAUDE_AUTH_FAIL".into(), "1".into());
        }
        HarnessProfile {
            kind: acpmux::config::HarnessKind::ClaudeStdio,
            argv: vec!["python3".into(), fake_claude.into()],
            env,
            description: None,
            fallback: fallback.map(str::to_owned),
            family: None,
            models: vec![],
            model: None,
            effort: None,
            policy: None,
        }
    };
    let agents = BTreeMap::from([
        ("primary".to_owned(), profile(&store_a, Some("direct"))),
        ("direct".to_owned(), profile(&store_b, None)),
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
    let s = c
        .request(
            method::SESSION_NEW,
            json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": {"name": "stores"}}}),
        )
        .await
        .unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    // Turn 1 finishes on primary: its conversation is in primary's store.
    let one = c
        .request(
            method::SESSION_PROMPT,
            json!({"sessionId": id, "prompt": [{"type": "text", "text": "one"}]}),
        )
        .await
        .expect("turn 1 answers on primary");
    assert_eq!(one["stopReason"], "end_turn");
    // Primary's launcher now dies on its prompt: acpmux fails over to direct.
    std::fs::write(&die, "").unwrap();
    let session = hub.resolve(&id).unwrap();
    hub.detach_child(&session).await;
    let two = c
        .request(
            method::SESSION_PROMPT,
            json!({"sessionId": id, "prompt": [{"type": "text", "text": "two"}]}),
        )
        .await
        .expect("the fallback answers turn 2 instead of failing on --resume");
    assert_eq!(two["stopReason"], "end_turn");
    assert_eq!(hub.session_summary(&session)["harness"], "direct");
    let kinds: Vec<String> =
        hub.events(&id, 0, 1000).unwrap().into_iter().map(|e| e.kind).collect();
    assert!(kinds.iter().any(|k| k == "failover"), "{kinds:?}");
    assert!(
        kinds.iter().any(|k| k == "resume_failed"),
        "the skipped resume is recorded: {kinds:?}"
    );
    let _ = std::fs::remove_dir_all(&root);
}

/// The chat's `_acpmux/info` `contextBreakdown`, polled until `want(breakdown)` or 5 s.
async fn info_breakdown(c: &mut TestClient, id: &str, want: impl Fn(&Value) -> bool) -> Value {
    let mut got = Value::Null;
    for _ in 0..100 {
        let info = c.request(method::MUX_INFO, json!({"sessionId": id})).await.unwrap();
        got = info["contextBreakdown"].clone();
        if want(&got) {
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    got
}

/// A hub whose `primary` Claude answers /context and falls over to `direct` (which does not)
/// once `root/die` exists: by dying, or with `late` by a usage limit, leaving a process that
/// answers /context for it after the failover and then creates `root/late`.
async fn context_failover_setup(root: &std::path::Path, late: bool) -> (Arc<Hub>, TestClient) {
    let claude_store = root.join("claude");
    std::fs::create_dir_all(&claude_store).unwrap();
    let fake_claude = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude.py");
    let profile = |primary: bool| {
        let path = |name: &str| root.join(name).to_string_lossy().into_owned();
        let mut env = BTreeMap::from([("FAKE_CLAUDE_STORE".to_owned(), path("claude"))]);
        if primary {
            env.insert("FAKE_CLAUDE_CONTEXT".into(), "1".into());
            env.insert("FAKE_CLAUDE_LIMITS".into(), "1".into());
            env.insert("FAKE_CLAUDE_DIE_IF".into(), path("die"));
            env.insert("FAKE_CLAUDE_AUTH_FAIL".into(), "1".into());
            if late {
                env.insert("FAKE_CLAUDE_LATE_CONTEXT".into(), path("late"));
            }
        }
        HarnessProfile {
            kind: acpmux::config::HarnessKind::ClaudeStdio,
            argv: vec!["python3".into(), fake_claude.into()],
            env,
            description: None,
            fallback: primary.then(|| "direct".to_owned()),
            family: None,
            models: vec![],
            model: None,
            effort: None,
            policy: None,
        }
    };
    let agents = BTreeMap::from([
        ("primary".to_owned(), profile(true)),
        ("direct".to_owned(), profile(false)),
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

/// A chat on `primary` whose first turn left its /context breakdown; the next prompt fails over.
async fn chat_with_a_breakdown(c: &mut TestClient) -> String {
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": "hi"}]});
    c.request(method::SESSION_PROMPT, prompt).await.unwrap();
    let before = info_breakdown(c, &id, |b| !b.is_null()).await;
    assert!(!before.is_null(), "the primary's turn leaves its /context breakdown");
    let info = c.request(method::MUX_INFO, json!({"sessionId": id})).await.unwrap();
    assert!(!info["usageLimits"].is_null(), "the primary's turn leaves its usage limits: {info}");
    id
}

/// A failover moves the chat onto another harness: the last harness's /context breakdown is
/// not the fallback's, so the chat stops showing it.
#[tokio::test]
async fn a_failover_drops_the_last_harnesss_context_breakdown() {
    let root = std::env::temp_dir().join(format!("acpmux-failover-ctx-{}", uuid::Uuid::now_v7()));
    let (hub, mut c) = context_failover_setup(&root, false).await;
    let id = chat_with_a_breakdown(&mut c).await;
    // The primary's launcher dies on the next prompt; the turn goes on, on `direct`.
    std::fs::write(root.join("die"), "").unwrap();
    let again = json!({"sessionId": id, "prompt": [{"type": "text", "text": "again"}]});
    let r = c.request(method::SESSION_PROMPT, again).await;
    let session = hub.resolve(&id).unwrap();
    assert_eq!(hub.session_summary(&session)["harness"], "direct", "{r:?}");
    let after = info_breakdown(&mut c, &id, Value::is_null).await;
    assert!(after.is_null(), "the primary's breakdown outlived the failover: {after}");
    assert!(session.meta().context_breakdown.is_none(), "the saved meta keeps the old breakdown");
    // Nor do the primary account's usage limits stay.
    let info = c.request(method::MUX_INFO, json!({"sessionId": id})).await.unwrap();
    assert!(info["usageLimits"].is_null(), "the primary's limits outlived the failover: {info}");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

/// The replaced harness's /context answer that comes after the failover (it was still on its
/// way) is not the fallback's either: the chat keeps none.
#[tokio::test]
async fn a_replaced_harnesss_late_context_breakdown_is_not_kept() {
    let root = std::env::temp_dir().join(format!("acpmux-failover-late-{}", uuid::Uuid::now_v7()));
    let (hub, mut c) = context_failover_setup(&root, true).await;
    let id = chat_with_a_breakdown(&mut c).await;
    std::fs::write(root.join("die"), "").unwrap();
    let again = json!({"sessionId": id, "prompt": [{"type": "text", "text": "again"}]});
    let r = c.request(method::SESSION_PROMPT, again).await;
    let session = hub.resolve(&id).unwrap();
    assert_eq!(hub.session_summary(&session)["harness"], "direct", "{r:?}");
    // The old process writes its answer after the failover, then a probe line: once the probe is
    // logged, the reader has read the answer before it.
    let events = |hub: &Arc<Hub>| hub.events(&id, 0, 10_000).unwrap();
    let mut probed = false;
    for _ in 0..100 {
        probed = events(&hub).iter().any(|e| e.kind.contains("late_probe"));
        if probed {
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert!(probed, "the replaced process's late lines never reached its reader");
    let info = c.request(method::MUX_INFO, json!({"sessionId": id})).await.unwrap();
    assert!(info["contextBreakdown"].is_null(), "the late answer came back: {info}");
    assert!(info["usageLimits"].is_null(), "the late limits came back: {info}");
    assert!(session.meta().context_breakdown.is_none());
    // Nor is it in the log after the failover, where a pane's replay would take it up.
    let log = events(&hub);
    let failover = log.iter().find(|e| e.kind == "failover").map(|e| e.seq).unwrap();
    let late: Vec<_> = log
        .iter()
        .filter(|e| e.seq > failover)
        .filter(|e| {
            let meta = e.msg.pointer("/params/update/_meta/acpmux");
            meta.is_some_and(|m| {
                m.get("contextBreakdown").is_some() || m.get("usageLimits").is_some()
            })
        })
        .collect();
    assert!(late.is_empty(), "a breakdown or limits were logged after the failover: {late:?}");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}
