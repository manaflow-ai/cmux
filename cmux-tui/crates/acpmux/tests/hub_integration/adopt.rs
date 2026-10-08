use super::*;
use acpmux::adopt::HarnessHomes;

const ID: &str = "0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b";
const LIVE_ID: &str = "0199a1b2-1111-7e5f-8a9b-0c1d2e3f4a5b";

/// A hub whose fake harnesses are Codex-family, and a fixture Codex store
/// holding one rollout recorded in a temp project folder.
async fn adopt_setup() -> (Arc<Hub>, TestClient, std::path::PathBuf, std::path::PathBuf) {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let profile = |env: &[(&str, &str)]| HarnessProfile {
        kind: Default::default(),
        argv: vec!["python3".into(), fake.into()],
        env: env.iter().map(|(k, v)| ((*k).to_owned(), (*v).to_owned())).collect(),
        description: None,
        fallback: None,
        family: Some("codex".into()),
        models: vec![],
        model: None,
        effort: None,
        policy: None,
    };
    let mut agents = BTreeMap::new();
    agents.insert("fakecodex".to_owned(), profile(&[]));
    agents.insert("noload".to_owned(), profile(&[("FAKE_NO_LOAD", "1")]));
    let mut cfg = Config {
        harnesses: agents,
        default_harness: Some("fakecodex".into()),
        ..Default::default()
    };
    cfg.store.mode = StoreMode::Memory;
    cfg.permission_policy = PermissionPolicy::ApproveAll;
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);

    let root = std::env::temp_dir().join(format!("acpmux-adopt-hub-{}", uuid::Uuid::now_v7()));
    let project = root.join("project");
    std::fs::create_dir_all(&project).unwrap();
    let rollout =
        root.join(format!("codex/sessions/2026/10/02/rollout-2026-10-02T09-00-00-{ID}.jsonl"));
    std::fs::create_dir_all(rollout.parent().unwrap()).unwrap();
    let record = json!({"type": "session_meta", "payload": {"id": ID, "cwd": project}});
    std::fs::write(&rollout, format!("{record}\n")).unwrap();
    // Written long ago: a transcript written in the last minutes is a chat
    // still live elsewhere (the live-use tests).
    backdate(&rollout);
    hub.set_harness_homes(HarnessHomes { claude: root.join("claude"), codex: root.join("codex") });

    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection(hub.clone(), in_rx, out_tx));
    let mut client = TestClient { tx: in_tx, rx: out_rx, next: 0 };
    client
        .request(method::INITIALIZE, json!({"protocolVersion": 1, "clientInfo": {"name": "test"}}))
        .await
        .unwrap();
    (hub, client, root, project)
}

fn adopt(harness: &str, id: &str) -> Value {
    adopt_if_live(harness, id, None)
}

/// `adopt` with `ifLive` (`refuse`, `fork` or `open`) when given.
fn adopt_if_live(harness: &str, id: &str, if_live: Option<&str>) -> Value {
    let mut request = json!({"agentSessionId": id});
    if let Some(if_live) = if_live {
        request["ifLive"] = json!(if_live);
    }
    let acpmux = json!({"harness": harness, "adopt": request});
    json!({"mcpServers": [], "_meta": {"acpmux": acpmux}})
}

/// Sets `file`'s modification time an hour back.
fn backdate(file: &std::path::Path) {
    let hour_ago = std::time::SystemTime::now() - Duration::from_secs(3600);
    std::fs::File::options().write(true).open(file).unwrap().set_modified(hour_ago).unwrap();
}

#[tokio::test]
async fn adopt_loads_the_harness_session_in_its_recorded_cwd() {
    let (hub, mut c, root, project) = adopt_setup().await;
    let s = c.request(method::SESSION_NEW, adopt("fakecodex", ID)).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let session = hub.resolve(&id).unwrap();
    let meta = session.meta();
    assert_eq!(meta.agent_session_id.as_deref(), Some(ID));
    assert_eq!(meta.cwd, project);
    let events = hub.events(&session.id, 0, 10_000).unwrap();
    let mux = |kind: &str| {
        events.iter().find(|e| e.dir == "mux" && e.kind == kind).map(|e| e.msg.clone())
    };
    assert_eq!(mux("adopted"), Some(json!({"agentSessionId": ID})));
    assert_eq!(mux("resumed"), Some(json!({"level": "exact"})));
    assert!(events.iter().any(|e| e.dir == "out" && e.kind == "session/load"));
    assert!(!events.iter().any(|e| e.dir == "out" && e.kind == "session/new"));

    // Adopting the same id again, from any profile of the family, is the same session.
    let again = c.request(method::SESSION_NEW, adopt("noload", ID)).await.unwrap();
    assert_eq!(again["sessionId"], id.as_str());
    assert_eq!(hub.sessions().len(), 1);
    let _ = std::fs::remove_dir_all(root);
}

/// Fails closed: an id the store lacks, a path-shaped id, and an agent that
/// cannot load the session are errors, and no session is left behind.
#[tokio::test]
async fn adopt_refuses_unknown_ids_and_agents_that_cannot_resume() {
    let (hub, mut c, root, _) = adopt_setup().await;
    let missing = "0199a1b2-0000-7000-8000-000000000000";
    let unknown = c.request(method::SESSION_NEW, adopt("fakecodex", missing)).await;
    assert!(unknown.unwrap_err().contains("no codex session"));
    let path = c.request(method::SESSION_NEW, adopt("fakecodex", "../../etc/passwd")).await;
    assert!(path.unwrap_err().contains("not a session id"));
    let no_load = c.request(method::SESSION_NEW, adopt("noload", ID)).await;
    assert!(no_load.unwrap_err().contains("could not resume"));
    assert!(hub.sessions().is_empty());
    let _ = std::fs::remove_dir_all(root);
}

/// A chat still live in another process (a terminal running
/// `codex resume <id>`, a transcript written minutes ago) is not adopted
/// silently: two harnesses resuming one conversation fork it. `ifLive:
/// "open"` adopts it anyway; only Claude Code chats fork on adopt.
#[tokio::test]
async fn adopt_refuses_a_chat_live_in_another_process() {
    let (hub, mut c, root, project) = adopt_setup().await;
    // Its own chat: the process below names it, and tests run in parallel.
    let rollout =
        root.join(format!("codex/sessions/2026/10/02/rollout-2026-10-02T10-00-00-{LIVE_ID}.jsonl"));
    let record = json!({"type": "session_meta", "payload": {"id": LIVE_ID, "cwd": project}});
    std::fs::write(&rollout, format!("{record}\n")).unwrap();
    backdate(&rollout);
    let mut other = std::process::Command::new("sh")
        .args(["-c", "sleep 60", "codex", "resume", LIVE_ID])
        .spawn()
        .unwrap();
    let refused = c.request(method::SESSION_NEW, adopt("fakecodex", LIVE_ID)).await.unwrap_err();
    assert!(refused.contains("open in another process"), "{refused}");
    assert!(refused.contains(&other.id().to_string()), "{refused}");
    let fork =
        c.request(method::SESSION_NEW, adopt_if_live("fakecodex", LIVE_ID, Some("fork"))).await;
    assert!(fork.unwrap_err().contains("only Claude Code chats fork"));
    assert!(hub.sessions().is_empty());
    let _ = other.kill();
    let _ = other.wait();

    // No process names it, but its transcript was just written.
    std::fs::File::options()
        .write(true)
        .open(&rollout)
        .unwrap()
        .set_modified(std::time::SystemTime::now())
        .unwrap();
    let recent = c.request(method::SESSION_NEW, adopt("fakecodex", LIVE_ID)).await.unwrap_err();
    assert!(recent.contains("written"), "{recent}");
    assert!(hub.sessions().is_empty());

    let opened =
        c.request(method::SESSION_NEW, adopt_if_live("fakecodex", LIVE_ID, Some("open"))).await;
    let id = opened.unwrap()["sessionId"].as_str().unwrap().to_owned();
    assert_eq!(hub.resolve(&id).unwrap().meta().agent_session_id.as_deref(), Some(LIVE_ID));
    let _ = std::fs::remove_dir_all(root);
}

/// `ifLive: "fork"` on a Claude Code chat starts a new chat from it
/// (`claude --resume <id> --fork-session`), leaving the live one alone.
#[tokio::test]
async fn adopt_forks_a_live_claude_chat_when_asked() {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude.py");
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fakeclaude": {"argv": ["python3", fake], "kind": "claude-stdio"}},
        "defaultHarness": "fakeclaude",
        "permissionPolicy": "approve-all",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let root = std::env::temp_dir().join(format!("acpmux-adopt-fork-{}", uuid::Uuid::now_v7()));
    let project = root.join("project");
    std::fs::create_dir_all(&project).unwrap();
    let transcript = root.join(format!("claude/projects/-project/{ID}.jsonl"));
    std::fs::create_dir_all(transcript.parent().unwrap()).unwrap();
    std::fs::write(&transcript, format!("{}\n", json!({"type": "user", "cwd": project}))).unwrap();
    hub.set_harness_homes(HarnessHomes { claude: root.join("claude"), codex: root.join("codex") });
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection(hub.clone(), in_rx, out_tx));
    let mut c = TestClient { tx: in_tx, rx: out_rx, next: 0 };
    c.request(method::INITIALIZE, json!({"protocolVersion": 1, "clientInfo": {"name": "test"}}))
        .await
        .unwrap();

    // Just written: live.
    let refused = c.request(method::SESSION_NEW, adopt("fakeclaude", ID)).await.unwrap_err();
    assert!(refused.contains("written"), "{refused}");
    let forked =
        c.request(method::SESSION_NEW, adopt_if_live("fakeclaude", ID, Some("fork"))).await;
    let id = forked.unwrap()["sessionId"].as_str().unwrap().to_owned();
    let session = hub.resolve(&id).unwrap();
    assert_eq!(session.meta().cwd, project);
    assert_ne!(session.meta().agent_session_id.as_deref(), Some(ID));
    let events = hub.events(&session.id, 0, 10_000).unwrap();
    let mux = |kind: &str| {
        events.iter().find(|e| e.dir == "mux" && e.kind == kind).map(|e| e.msg.clone())
    };
    assert_eq!(mux("adopted"), Some(json!({"agentSessionId": ID, "fork": true})));
    assert_eq!(mux("resumed"), Some(json!({"level": "fork"})));
    let _ = std::fs::remove_dir_all(root);
}
