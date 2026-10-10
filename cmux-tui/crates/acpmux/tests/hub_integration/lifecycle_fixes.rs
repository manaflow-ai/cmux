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
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let dir = std::env::temp_dir().join(format!("acpmux-npx-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&dir).unwrap();
    let log = dir.join("npx.log");
    let bin = dir.join("fake-acp");
    write_executable(&bin, format!("#!/bin/sh\nexec python3 {fake}\n"));
    // `npx -y -p PKG -c 'command -v fake-acp'` prints the bin; any other
    // use is a launch through npx.
    let npx = dir.join("npx");
    write_executable(
        &npx,
        format!(
            "#!/bin/sh\ncase \" $* \" in *\" -c \"*) echo resolve >> {log}; echo {bin}; exit 0;; esac\necho run >> {log}\nexec python3 {fake}\n",
            log = log.display(),
            bin = bin.display(),
        ),
    );
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

/// Shutdown owns every child from its first step: once it stopped the idle
/// reaper, the reaper never stops a harness again (a hosted one is handed
/// off to the next daemon, not terminated), even for a child published
/// after that step. (Once the shutdown reads its plan no agent starts at
/// all, `quit_spawn.rs`.)
#[tokio::test]
async fn the_idle_reaper_stops_for_good_when_shutdown_starts() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let clock = acpmux::clock::ManualClock::new();
    hub.set_clock(clock.clone());
    hub.set_idle_child(Some(Duration::from_secs(300)));
    hub.stop_idle_reaper();
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

/// Creates an executable (0755) script without this process ever holding a
/// write descriptor for it.
///
/// Tests run on many threads. A sibling test that forks while this process
/// holds such a descriptor hands a copy to its child until that child execs,
/// and executing the script in that window fails with ETXTBSY ("Text file
/// busy"). `O_CLOEXEC` does not close that window, and a temp file plus a
/// rename does not either (the child holds the same inode). A short-lived
/// `sh` opens, writes, and closes the file in its own process, so no fork of
/// this process can inherit it. (The same helper as cmux-tui's `test_exec`.)
fn write_executable(path: impl AsRef<std::path::Path>, contents: impl AsRef<[u8]>) {
    use std::io::Write as _;
    use std::process::{Command, Stdio};
    let path = path.as_ref();
    let mut child = Command::new("/bin/sh")
        .args(["-c", "cat >\"$1\" && chmod 755 \"$1\"", "sh"])
        .arg(path)
        .stdin(Stdio::piped())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(contents.as_ref()).unwrap();
    assert!(child.wait().unwrap().success(), "could not write {}", path.display());
}

/// LAUNCH-NO-TCC-PROMPTS: a model probe starts an agent and opens a session
/// in its folder, so it never runs in the home folder or `/` (an agent
/// there reads Downloads, Documents and Desktop at once and macOS asks the
/// user in the app's name). It runs in acpmux's own probe folder.
#[tokio::test]
async fn a_model_probe_runs_its_agent_outside_the_home_folder() {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let dir = std::env::temp_dir().join(format!("acpmux-probe-cwd-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let report = dir.join("probe-cwd.txt");
    let argv = vec![
        "/bin/sh".to_owned(),
        "-c".to_owned(),
        format!("/bin/pwd -P > '{}'; exec python3 '{fake}'", report.display()),
    ];
    let mut agents = BTreeMap::new();
    agents.insert(
        "fake".to_owned(),
        HarnessProfile {
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
        },
    );
    let mut cfg =
        Config { harnesses: agents, default_harness: Some("fake".into()), ..Default::default() };
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    hub.begin_startup(false);
    hub.finish_startup().await;
    let deadline = std::time::Instant::now() + Duration::from_secs(20);
    let mut cwd = String::new();
    while cwd.is_empty() && std::time::Instant::now() < deadline {
        tokio::time::sleep(Duration::from_millis(20)).await;
        cwd = std::fs::read_to_string(&report).unwrap_or_default().trim().to_owned();
    }
    assert!(!cwd.is_empty(), "the model probe never ran");
    let home = dirs::home_dir().and_then(|h| std::fs::canonicalize(h).ok()).unwrap();
    assert_ne!(std::path::Path::new(&cwd), home.as_path(), "probe ran in the home folder");
    assert_ne!(cwd, "/", "probe ran in the root folder");
    assert_eq!(
        acpmux::protected_folders::unasked_refusal(std::path::Path::new(&cwd)),
        None,
        "probe ran in a guarded folder: {cwd}"
    );
    let _ = std::fs::remove_dir_all(&dir);
}

/// A client that uses a few harnesses (the Chief: `ACPMUX_PROBE_HARNESSES`)
/// gets model probes for those only: a Claude-only Chief never starts
/// codex-acp at daemon start.
#[tokio::test]
async fn the_model_probes_start_only_the_listed_harnesses() {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let dir = std::env::temp_dir().join(format!("acpmux-probe-only-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&dir).unwrap();
    let report = |name: &str| dir.join(format!("{name}.started"));
    let profile = |name: &str| HarnessProfile {
        kind: Default::default(),
        argv: vec![
            "/bin/sh".to_owned(),
            "-c".to_owned(),
            format!("touch '{}'; exec python3 '{fake}'", report(name).display()),
        ],
        env: BTreeMap::new(),
        description: None,
        fallback: None,
        family: None,
        models: vec![],
        model: None,
        effort: None,
        policy: None,
    };
    let agents = BTreeMap::from([
        ("used".to_owned(), profile("used")),
        ("unused".to_owned(), profile("unused")),
    ]);
    let mut cfg =
        Config { harnesses: agents, default_harness: Some("used".into()), ..Default::default() };
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    hub.set_probe_only(Some(["used".to_owned()].into()));
    hub.begin_startup(false);
    hub.finish_startup().await;
    let deadline = std::time::Instant::now() + Duration::from_secs(20);
    while !report("used").exists() && std::time::Instant::now() < deadline {
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert!(report("used").exists(), "the listed harness was never probed");
    // Both probes start at once: a moment more for one that should not.
    tokio::time::sleep(Duration::from_secs(2)).await;
    assert!(!report("unused").exists(), "a harness outside the list was started");
    let _ = std::fs::remove_dir_all(&dir);
}

/// An engine change to a harness outside the start-time list (a Claude-only
/// Chief set to codex) still gets that harness's model list: the client asks
/// for it (`_acpmux/models {"probe": [...]}`), and the probe runs then.
#[tokio::test]
async fn a_harness_allowed_later_is_probed_and_its_models_listed() {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let dir = std::env::temp_dir().join(format!("acpmux-probe-later-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&dir).unwrap();
    let started = dir.join("later.started");
    let profile = |marker: Option<&std::path::Path>| HarnessProfile {
        kind: Default::default(),
        argv: match marker {
            Some(m) => vec![
                "/bin/sh".to_owned(),
                "-c".to_owned(),
                format!("touch '{}'; exec python3 '{fake}'", m.display()),
            ],
            None => vec!["python3".to_owned(), fake.to_owned()],
        },
        env: BTreeMap::new(),
        description: None,
        fallback: None,
        family: None,
        models: vec![],
        model: None,
        effort: None,
        policy: None,
    };
    let agents = BTreeMap::from([
        ("claude-only".to_owned(), profile(None)),
        ("later".to_owned(), profile(Some(&started))),
    ]);
    let mut cfg = Config {
        harnesses: agents,
        default_harness: Some("claude-only".into()),
        ..Default::default()
    };
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    hub.set_probe_only(Some(["claude-only".to_owned()].into()));
    hub.begin_startup(false);
    hub.finish_startup().await;
    let listed = |catalog: &serde_json::Value| {
        catalog["harnesses"]
            .as_array()
            .into_iter()
            .flatten()
            .any(|h| h["harness"] == "later" && h["models"].to_string().contains("m2"))
    };
    // Outside the start-time list: never started.
    tokio::time::sleep(Duration::from_secs(2)).await;
    assert!(!started.exists(), "a harness outside the list was started at daemon start");
    hub.allow_probes(["later".to_owned()].into()).await;
    let deadline = std::time::Instant::now() + Duration::from_secs(20);
    let mut catalog = hub.models_catalog().await;
    while !listed(&catalog) && std::time::Instant::now() < deadline {
        tokio::time::sleep(Duration::from_millis(50)).await;
        catalog = hub.models_catalog().await;
    }
    assert!(started.exists(), "the later harness was never probed");
    assert!(listed(&catalog), "the later harness has no probed model list: {catalog}");
    let _ = std::fs::remove_dir_all(&dir);
}
