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
        tokio::spawn(async move { hub.warm_sessions(&[id], 1, false, true).await })
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
    write_executable(
        &bin,
        format!("#!/bin/sh\nexec python3 {}\n", crate::daemon_env::sh_quote(fake)),
    );
    // `npx -y -p PKG -c 'command -v fake-acp'` prints the bin; any other
    // use is a launch through npx.
    let npx = dir.join("npx");
    write_executable(
        &npx,
        format!(
            "#!/bin/sh\ncase \" $* \" in *\" -c \"*) echo resolve >> {log}; echo {bin}; exit 0;; esac\necho run >> {log}\nexec python3 {fake}\n",
            log = crate::daemon_env::sh_quote(log.display()),
            bin = crate::daemon_env::sh_quote(bin.display()),
            fake = crate::daemon_env::sh_quote(fake),
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
/// (measured on the hub's injected clock): no turn, no activity. A client
/// attached to it does not keep it (`hub/idle.rs`): the attached session's
/// harness exits too. The session keeps its record and resumes on the next
/// prompt.
#[tokio::test]
async fn an_idle_session_harness_exits_attached_or_not_and_resumes_on_the_next_prompt() {
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
    assert_eq!(status("idle-attached"), "ready", "stopped before the idle period ended");
    clock.advance(Duration::from_secs(2));
    let deadline = std::time::Instant::now() + Duration::from_secs(20);
    while status("idle-gone") != "idle" || status("idle-attached") != "idle" {
        assert!(std::time::Instant::now() < deadline, "the idle harnesses never exited");
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    // The stopped sessions resume on their next prompt.
    for id in &ids {
        let r = c
            .request(
                method::SESSION_PROMPT,
                json!({"sessionId": id, "prompt": [{"type": "text", "text": "back"}]}),
            )
            .await
            .unwrap();
        assert_eq!(r["stopReason"], "end_turn");
        let kinds: Vec<String> =
            hub.events(id, 0, 1000).unwrap().into_iter().map(|e| e.kind).collect();
        assert!(kinds.iter().any(|k| k == "resumed"), "{kinds:?}");
    }
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
#[cfg(unix)]
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

/// cx-m5up: an agent that stays alive but never answers its start fails
/// the request with a typed deadline instead of holding the session's spawn
/// lock (and every later request of the session) forever, and the same
/// session starts normally once the agent answers.
#[tokio::test]
async fn an_agent_that_never_answers_its_start_fails_with_a_deadline() {
    let gate = std::env::temp_dir().join(format!("acpmux-start-gate-{}", uuid::Uuid::now_v7()));
    std::fs::write(&gate, b"").unwrap();
    let env = BTreeMap::from([("FAKE_START_GATE".to_owned(), gate.to_string_lossy().into_owned())]);
    let (hub, _person) = setup_env(PermissionPolicy::ApproveAll, env).await;
    // An agent's connection: the person's start has no deadline (the tests below).
    let mut c = agent_client(&hub);
    let created = c
        .request(
            method::SESSION_NEW,
            json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": {"name": "gated"}}}),
        )
        .await
        .unwrap();
    let id = created["sessionId"].as_str().unwrap().to_owned();
    // Stop the agent; the next prompt starts a fresh one that never reads.
    c.request(method::MUX_KILL, json!({"sessionId": id})).await.unwrap();
    std::fs::remove_file(&gate).unwrap();
    // The short budget bounds only the start that never answers. The healthy
    // starts keep the default: one took 0.3-2.5 s while this binary ran its
    // tests at once on rbx, past a 1.5 s budget (cx-nx5mb).
    hub.config.write().await.agent_start_timeout_ms = Some(1_500);
    let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": "hello"}]});
    let refused = c
        .request(method::SESSION_PROMPT, prompt.clone())
        .await
        .expect_err("a prompt whose agent never started succeeded");
    assert!(refused.contains("agent_start did not finish within"), "{refused}");
    // The agent answers from now on: the same session prompts normally.
    std::fs::write(&gate, b"").unwrap();
    hub.config.write().await.agent_start_timeout_ms = None;
    let answered = c.request(method::SESSION_PROMPT, prompt).await.unwrap();
    assert!(answered["stopReason"].is_string(), "{answered}");
    let _ = std::fs::remove_file(&gate);
}

/// A connection that is not the person: an agent's or a lane's `acpmux` client.
fn agent_client(hub: &Arc<Hub>) -> TestClient {
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection(hub.clone(), in_rx, out_tx));
    TestClient { tx: in_tx, rx: out_rx, next: 0 }
}

/// A hub with two harnesses: `fake`, and `gated`, whose agent starts only once `gate` exists.
async fn gated_hub(gate: &std::path::Path, extra: &[(&str, &str)]) -> (Arc<Hub>, TestClient) {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let profile = |env: BTreeMap<String, String>| HarnessProfile {
        kind: Default::default(),
        argv: vec!["python3".into(), fake.into()],
        env,
        description: None,
        fallback: None,
        family: None,
        models: vec![],
        model: None,
        effort: None,
        policy: None,
    };
    let mut gated = BTreeMap::from([("FAKE_START_GATE".to_owned(), gate.display().to_string())]);
    gated.extend(extra.iter().map(|(k, v)| ((*k).to_owned(), (*v).to_owned())));
    let harnesses = BTreeMap::from([
        ("fake".to_owned(), profile(BTreeMap::new())),
        ("gated".to_owned(), profile(gated)),
    ]);
    let mut cfg = Config { harnesses, default_harness: Some("fake".into()), ..Default::default() };
    cfg.store.mode = StoreMode::Memory;
    cfg.permission_policy = PermissionPolicy::ApproveAll;
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    hold_person_key(&hub);
    let c = connect(&hub).await;
    (hub, c)
}

fn new_params(name: &str, harness: &str) -> Value {
    json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": {"name": name, "harness": harness}}})
}

/// The `agent_start_waiting` records of session `name` (`Hub::person_start`).
fn start_waits(hub: &Hub, name: &str) -> usize {
    let Ok(s) = hub.resolve(name) else { return 0 };
    hub.events(&s.id, 0, 100_000)
        .unwrap()
        .iter()
        .filter(|e| e.kind == "agent_start_waiting")
        .count()
}

/// Leo, 2026-10-31: "I TSHOULDN'T FUCKING MATTER IF MY COMPUTER IS LOADED" / "I SHOULD BE ALWAYS
/// ABLE TO SATRT NEW FUCKGN CHATS". On a host at load ~390 the person's new chats failed with "no
/// harness session within 90s". The person's start has no deadline: past `agentStartTimeoutMs` it
/// keeps waiting and says so (`agent_start_waiting`), and the chat starts once its agent answers.
#[tokio::test]
async fn the_persons_slow_start_keeps_waiting_past_the_start_budget_and_says_so() {
    let gate = std::env::temp_dir().join(format!("acpmux-person-gate-{}", uuid::Uuid::now_v7()));
    let (hub, mut person) = gated_hub(&gate, &[]).await;
    hub.config.write().await.agent_start_timeout_ms = Some(300);
    let started = tokio::spawn(async move {
        person.request(method::SESSION_NEW, new_params("slow-host", "gated")).await
    });
    let deadline = std::time::Instant::now() + Duration::from_secs(20);
    while start_waits(&hub, "slow-host") < 3 {
        assert!(!started.is_finished(), "the person's start ended: {:?}", started.await);
        assert!(std::time::Instant::now() < deadline, "the start never said it still waits");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    // Several budgets later the start still waits: the agent answers now.
    assert!(!started.is_finished(), "the person's start ended: {:?}", started.await);
    std::fs::write(&gate, b"").unwrap();
    let created = tokio::time::timeout(Duration::from_secs(20), started)
        .await
        .expect("the start never ended once its agent answered")
        .unwrap()
        .expect("the person's slow start failed");
    assert!(created["sessionId"].is_string(), "{created}");
    let _ = std::fs::remove_file(&gate);
}

/// The person's start still fails at once on a real error: its agent exits.
#[tokio::test]
async fn the_persons_start_fails_when_its_agent_exits() {
    let gate = std::env::temp_dir().join(format!("acpmux-person-die-{}", uuid::Uuid::now_v7()));
    std::fs::write(&gate, b"").unwrap();
    let (hub, mut person) = gated_hub(&gate, &[("FAKE_DIE_AT_START", "no login")]).await;
    hub.config.write().await.agent_start_timeout_ms = Some(300);
    let refused = tokio::time::timeout(
        Duration::from_secs(30),
        person.request(method::SESSION_NEW, new_params("dies", "gated")),
    )
    .await
    .expect("the person's start waited on an agent that exited")
    .expect_err("an agent that exited started");
    assert!(!refused.contains("did not finish within"), "{refused}");
    let _ = std::fs::remove_file(&gate);
}

/// A stop ends the person's start that is still waiting: nothing holds the chat.
#[tokio::test]
async fn a_stop_ends_the_persons_start_that_still_waits() {
    let gate = std::env::temp_dir().join(format!("acpmux-person-stop-{}", uuid::Uuid::now_v7()));
    let (hub, mut person) = gated_hub(&gate, &[]).await;
    hub.config.write().await.agent_start_timeout_ms = Some(300);
    let started = tokio::spawn(async move {
        person.request(method::SESSION_NEW, new_params("stopped", "gated")).await
    });
    let deadline = std::time::Instant::now() + Duration::from_secs(20);
    while start_waits(&hub, "stopped") == 0 {
        assert!(std::time::Instant::now() < deadline, "the start never said it still waits");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let id = hub.resolve("stopped").unwrap().id.clone();
    let mut other = connect(&hub).await;
    other.request(method::MUX_KILL, json!({"sessionId": id})).await.unwrap();
    let ended = tokio::time::timeout(Duration::from_secs(20), started)
        .await
        .expect("the person's start outlived its stop")
        .unwrap();
    assert!(ended.is_err(), "{ended:?}");
}

/// A person's new chat never waits behind agents' starts: with four lanes' agents stuck in their
/// start, the person's chat on another harness starts at once.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_persons_start_never_waits_behind_lanes_that_are_stuck_starting() {
    let gate = std::env::temp_dir().join(format!("acpmux-lanes-gate-{}", uuid::Uuid::now_v7()));
    let (hub, mut person) = gated_hub(&gate, &[]).await;
    let mut lanes = Vec::new();
    for i in 0..4 {
        let mut lane = agent_client(&hub);
        lanes.push(tokio::spawn(async move {
            lane.request(method::SESSION_NEW, new_params(&format!("lane-{i}"), "gated")).await
        }));
    }
    let deadline = std::time::Instant::now() + Duration::from_secs(20);
    while (0..4).filter(|i| hub.resolve(&format!("lane-{i}")).is_ok()).count() < 4 {
        assert!(std::time::Instant::now() < deadline, "the lanes' chats were never created");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let began = std::time::Instant::now();
    let created = tokio::time::timeout(
        Duration::from_secs(20),
        person.request(method::SESSION_NEW, new_params("person-chat", "fake")),
    )
    .await
    .expect("the person's start waited behind the lanes")
    .expect("the person's start failed");
    assert!(created["sessionId"].is_string(), "{created}");
    assert!(lanes.iter().all(|l| !l.is_finished()), "a lane's start ended before its gate opened");
    eprintln!("person start beside 4 stuck lane starts: {:?}", began.elapsed());
    std::fs::write(&gate, b"").unwrap();
    for lane in lanes {
        let _ = tokio::time::timeout(Duration::from_secs(30), lane).await;
    }
    let _ = std::fs::remove_file(&gate);
}

/// The PR's load bench (not run by default): `LOAD_STARTS` starts of each kind at once on a host
/// under synthetic CPU load (`LOAD_BURNERS` busy loops, default 4 per CPU), with a 2 s
/// `agentStartTimeoutMs`. The agent connection's starts keep the deadline, as every start did
/// before; the person's wait. Prints how many failed and how long the person's took.
/// `cargo test -p acpmux --test hub_integration -- --ignored starts_under_load --nocapture`
#[tokio::test(flavor = "multi_thread", worker_threads = 8)]
#[ignore = "a load bench: run by hand"]
async fn starts_under_load() {
    let n: usize = std::env::var("LOAD_STARTS").ok().and_then(|v| v.parse().ok()).unwrap_or(24);
    let cpus = std::thread::available_parallelism().map_or(4, |n| n.get());
    let burners: usize =
        std::env::var("LOAD_BURNERS").ok().and_then(|v| v.parse().ok()).unwrap_or(4 * cpus);
    let gate = std::env::temp_dir().join(format!("acpmux-load-gate-{}", uuid::Uuid::now_v7()));
    std::fs::write(&gate, b"").unwrap();
    let (hub, _person) = gated_hub(&gate, &[]).await;
    hub.config.write().await.agent_start_timeout_ms = Some(2_000);
    // Our own busy loops, ended below by their handles.
    let mut load: Vec<std::process::Child> = (0..burners)
        .map(|_| {
            std::process::Command::new("sh")
                .args(["-c", "while :; do :; done"])
                .spawn()
                .expect("a busy loop")
        })
        .collect();
    tokio::time::sleep(Duration::from_secs(2)).await;
    let mut runs = Vec::new();
    for i in 0..n {
        for person in [true, false] {
            let mut c = if person { connect(&hub).await } else { agent_client(&hub) };
            let name = format!("{}-{i}", if person { "person" } else { "agent" });
            runs.push(tokio::spawn(async move {
                let began = std::time::Instant::now();
                let r = c.request(method::SESSION_NEW, new_params(&name, "fake")).await;
                (person, r.is_ok(), began.elapsed(), r.err())
            }));
        }
    }
    let mut person_ms = Vec::new();
    let (mut person_failed, mut agent_failed) = (0, 0);
    let mut agent_ms = Vec::new();
    for run in runs {
        let (person, ok, took, err) =
            tokio::time::timeout(Duration::from_secs(600), run).await.unwrap().unwrap();
        let ms = took.as_millis() as u64;
        match (person, ok) {
            (true, true) => person_ms.push(ms),
            (true, false) => {
                person_failed += 1;
                eprintln!("person start failed: {err:?}");
            }
            (false, true) => agent_ms.push(ms),
            (false, false) => agent_failed += 1,
        }
    }
    for child in &mut load {
        let _ = child.kill();
        let _ = child.wait();
    }
    let _ = std::fs::remove_file(&gate);
    let pct = |v: &mut Vec<u64>, p: usize| {
        v.sort_unstable();
        v.get((v.len().saturating_sub(1)) * p / 100).copied().unwrap_or(0)
    };
    eprintln!(
        "LOAD cpus={cpus} burners={burners} starts={n}/kind budget=2000ms | agent (as before): failed {agent_failed}/{n}, p50 {} ms max {} ms | person: failed {person_failed}/{n}, p50 {} ms max {} ms",
        pct(&mut agent_ms, 50),
        pct(&mut agent_ms, 100),
        pct(&mut person_ms, 50),
        pct(&mut person_ms, 100),
    );
    assert_eq!(person_failed, 0, "a person's start failed under load");
}
