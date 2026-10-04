//! Session lifecycle fixes: the load race, the npx launch cache, model
//! probe errors and the idle harness exit.
use super::*;

/// A prompt that arrives while another caller is still loading the
/// session's respawned agent waits for the load: the agent is not handed
/// out before `session/load` answered (it would answer "Session not found",
/// and the prompt would be lost).
#[tokio::test]
async fn a_prompt_during_a_slow_session_load_waits_for_the_load() {
    let gate = std::env::temp_dir().join(format!("acpmux-load-gate-{}", uuid::Uuid::now_v7()));
    let env = BTreeMap::from([("FAKE_LOAD_GATE".to_owned(), gate.to_string_lossy().into_owned())]);
    let (hub, mut c) = setup_env(PermissionPolicy::ApproveAll, env).await;
    let s = c
        .request(
            method::SESSION_NEW,
            json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": {"name": "slow-load"}}}),
        )
        .await
        .unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let session = hub.resolve("slow-load").unwrap();
    hub.detach_child(&session).await;
    // Another caller (the pane's `_acpmux/warm`) respawns it; the load hangs.
    let warmer = {
        let hub = hub.clone();
        let id = id.clone();
        tokio::spawn(async move { hub.warm_sessions(&[id], 1).await })
    };
    let load_sent = || {
        hub.events(&id, 0, 10_000)
            .unwrap()
            .iter()
            .any(|e| e.dir == "out" && e.kind == method::SESSION_LOAD)
    };
    let deadline = std::time::Instant::now() + Duration::from_secs(20);
    while !load_sent() {
        assert!(std::time::Instant::now() < deadline, "session/load was never sent");
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    c.next += 1;
    let prompt_id = c.next;
    c.tx.send(
        Message::request(
            prompt_id,
            method::SESSION_PROMPT,
            json!({"sessionId": id, "prompt": [{"type": "text", "text": "during load"}]}),
        )
        .to_line(),
    )
    .await
    .unwrap();
    // The prompt is in flight before the load answers.
    tokio::time::sleep(Duration::from_millis(200)).await;
    std::fs::write(&gate, b"open").unwrap();
    let answer = loop {
        let line = tokio::time::timeout(Duration::from_secs(20), c.rx.recv())
            .await
            .expect("timeout waiting for the prompt answer")
            .expect("connection closed");
        if let Message::Response { id: rid, result, error } = Message::parse(&line).unwrap()
            && rid == prompt_id
        {
            break (result, error);
        }
    };
    let _ = std::fs::remove_file(&gate);
    assert!(answer.1.is_none(), "prompt during load failed: {:?}", answer.1);
    assert_eq!(answer.0.unwrap()["stopReason"], "end_turn");
    warmer.await.unwrap();
}

/// A harness launched as `npx -y PACKAGE` (Codex without codex-acp on
/// PATH) is resolved to the package's installed bin once, in the
/// background after startup; the model probe and every session spawn run
/// that bin, never npx.
#[cfg(unix)]
#[tokio::test]
async fn an_npx_package_launch_is_resolved_once_and_never_spawned_through_npx() {
    use std::os::unix::fs::PermissionsExt;
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let dir = std::env::temp_dir().join(format!("acpmux-npx-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&dir).unwrap();
    let log = dir.join("npx.log");
    let bin = dir.join("fake-acp");
    std::fs::write(&bin, format!("#!/bin/sh\nexec python3 {fake}\n")).unwrap();
    // `npx -y -p PKG -c 'command -v fake-acp'` prints the bin; any other
    // use is a launch through npx.
    let npx = dir.join("npx");
    std::fs::write(
        &npx,
        format!(
            "#!/bin/sh\ncase \" $* \" in *\" -c \"*) echo resolve >> {log}; echo {bin}; exit 0;; esac\necho run >> {log}\nexec python3 {fake}\n",
            log = log.display(),
            bin = bin.display(),
        ),
    )
    .unwrap();
    for p in [&bin, &npx] {
        std::fs::set_permissions(p, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
    let mut agents = BTreeMap::new();
    agents.insert(
        "fake".to_owned(),
        HarnessProfile {
            kind: Default::default(),
            argv: vec![
                npx.to_string_lossy().into_owned(),
                "-y".into(),
                "@scope/fake-acp@1.0.0".into(),
            ],
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
    cfg.store.mode = StoreMode::Memory;
    cfg.permission_policy = PermissionPolicy::ApproveAll;
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    hub.begin_startup(false);
    hub.finish_startup().await;
    let lines = || std::fs::read_to_string(&log).unwrap_or_default();
    let deadline = std::time::Instant::now() + Duration::from_secs(20);
    // The startup model probe has run (it lists the fake's models).
    while !hub.models_catalog().await.to_string().contains("\"m2\"") {
        assert!(
            std::time::Instant::now() < deadline,
            "the model probe never ran; npx log: {}",
            lines()
        );
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    for name in ["npx-a", "npx-b"] {
        hub.new_session(acpmux::hub::NewRequest {
            name: Some(name.into()),
            cwd: Some(std::env::temp_dir()),
            ..Default::default()
        })
        .await
        .unwrap();
    }
    assert_eq!(lines(), "resolve\n", "npx ran as a launcher, or resolved more than once");
    let _ = std::fs::remove_dir_all(&dir);
}

/// A harness whose startup model probe fails (Gemini: the adapter dies
/// before it answers) is reported with the probe's error in
/// `_acpmux/models` and `_acpmux/harnesses`, so the pane can show it
/// unavailable with the reason instead of failing the pick seconds later.
#[tokio::test]
async fn a_failed_model_probe_is_reported_with_its_reason() {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let profile = |argv: Vec<String>| HarnessProfile {
        kind: Default::default(),
        argv,
        env: BTreeMap::new(),
        description: None,
        fallback: None,
        family: None,
        models: vec![],
        model: None,
        effort: None,
        policy: None,
    };
    let mut agents = BTreeMap::new();
    agents.insert("fake".to_owned(), profile(vec!["python3".into(), fake.into()]));
    agents.insert(
        "broken".to_owned(),
        profile(vec!["python3".into(), "-c".into(), "import sys; sys.exit(3)".into()]),
    );
    let mut cfg =
        Config { harnesses: agents, default_harness: Some("fake".into()), ..Default::default() };
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    hub.begin_startup(false);
    hub.finish_startup().await;
    let entry = |catalog: &Value, name: &str| {
        catalog["harnesses"]
            .as_array()
            .unwrap()
            .iter()
            .find(|h| h["harness"] == name)
            .cloned()
            .unwrap()
    };
    let deadline = std::time::Instant::now() + Duration::from_secs(20);
    loop {
        let catalog = hub.models_catalog().await;
        if entry(&catalog, "broken").get("probeError").is_some_and(|e| !e.is_null())
            && catalog.to_string().contains("\"m2\"")
        {
            assert!(
                entry(&catalog, "fake").get("probeError").is_none(),
                "a good probe reports no error: {catalog}"
            );
            break;
        }
        assert!(std::time::Instant::now() < deadline, "no probe error reported: {catalog}");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection(hub.clone(), in_rx, out_tx));
    let mut c = TestClient { tx: in_tx, rx: out_rx, next: 0 };
    let listed = c.request(method::MUX_HARNESSES, json!({})).await.unwrap();
    let reason = listed["harnesses"]["broken"]["probeError"].as_str().unwrap_or_default();
    assert!(!reason.is_empty(), "{listed}");
    assert!(listed["harnesses"]["fake"].get("probeError").is_none(), "{listed}");
}

/// A session's harness that nobody uses exits after the idle period
/// (measured on the hub's injected clock): no client attached, no turn, no
/// activity. The session keeps its record and resumes on the next prompt.
/// An attached session's harness stays.
#[tokio::test]
async fn an_idle_detached_session_harness_exits_and_resumes_on_the_next_prompt() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let clock = acpmux::clock::ManualClock::new();
    hub.set_clock(clock.clone());
    hub.set_idle_child(Some(Duration::from_secs(300)));
    let mut ids = Vec::new();
    for name in ["idle-gone", "idle-attached"] {
        let s = c
            .request(
                method::SESSION_NEW,
                json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": {"name": name}}}),
            )
            .await
            .unwrap();
        ids.push(s["sessionId"].as_str().unwrap().to_owned());
    }
    // session/new attached this connection to both; let go of the first.
    c.request(method::MUX_DETACH, json!({"sessionId": ids[0]})).await.unwrap();
    let status = |name: &str| hub.session_summary(&hub.resolve(name).unwrap())["status"].clone();
    let settle = || tokio::time::sleep(Duration::from_millis(150));
    clock.advance(Duration::from_secs(299));
    settle().await;
    assert_eq!(status("idle-gone"), "ready", "stopped before the idle period ended");
    clock.advance(Duration::from_secs(2));
    let deadline = std::time::Instant::now() + Duration::from_secs(20);
    while status("idle-gone") != "idle" {
        assert!(std::time::Instant::now() < deadline, "the idle harness never exited");
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    clock.advance(Duration::from_secs(900));
    settle().await;
    assert_eq!(status("idle-attached"), "ready", "an attached session's harness was stopped");
    // The stopped session resumes on its next prompt.
    let r = c
        .request(
            method::SESSION_PROMPT,
            json!({"sessionId": ids[0], "prompt": [{"type": "text", "text": "back"}]}),
        )
        .await
        .unwrap();
    assert_eq!(r["stopReason"], "end_turn");
    let kinds: Vec<String> =
        hub.events(&ids[0], 0, 1000).unwrap().into_iter().map(|e| e.kind).collect();
    assert!(kinds.iter().any(|k| k == "resumed"), "{kinds:?}");
}

/// Shutdown owns every child from its first step: once it started, the
/// idle reaper never stops a harness again (a hosted one is handed off to
/// the next daemon, not terminated).
#[tokio::test]
async fn the_idle_reaper_stops_for_good_when_shutdown_starts() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let clock = acpmux::clock::ManualClock::new();
    hub.set_clock(clock.clone());
    hub.set_idle_child(Some(Duration::from_secs(300)));
    hub.shutdown_all().await;
    let s = c
        .request(
            method::SESSION_NEW,
            json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": {"name": "after-stop"}}}),
        )
        .await
        .unwrap();
    c.request(method::MUX_DETACH, json!({"sessionId": s["sessionId"]})).await.unwrap();
    clock.advance(Duration::from_secs(3600));
    tokio::time::sleep(Duration::from_millis(300)).await;
    let session = hub.resolve("after-stop").unwrap();
    assert_eq!(hub.session_summary(&session)["status"], "ready", "reaped during shutdown");
}
