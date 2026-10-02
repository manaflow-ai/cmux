use super::*;
use acpmux::adopt::HarnessHomes;

const ID: &str = "0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b";

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
    let mut cfg =
        Config { harnesses: agents, default_harness: Some("fakecodex".into()), ..Default::default() };
    cfg.store.mode = StoreMode::Memory;
    cfg.permission_policy = PermissionPolicy::ApproveAll;
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);

    let root = std::env::temp_dir().join(format!("acpmux-adopt-hub-{}", uuid::Uuid::now_v7()));
    let project = root.join("project");
    std::fs::create_dir_all(&project).unwrap();
    let rollout = root.join(format!("codex/sessions/2026/10/02/rollout-2026-10-02T09-00-00-{ID}.jsonl"));
    std::fs::create_dir_all(rollout.parent().unwrap()).unwrap();
    let record = json!({"type": "session_meta", "payload": {"id": ID, "cwd": project}});
    std::fs::write(&rollout, format!("{record}\n")).unwrap();
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
    json!({"mcpServers": [], "_meta": {"acpmux": {"harness": harness, "adopt": {"agentSessionId": id}}}})
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
    let mux = |kind: &str| events.iter().find(|e| e.dir == "mux" && e.kind == kind).map(|e| e.msg.clone());
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
    let unknown = c.request(method::SESSION_NEW, adopt("fakecodex", "0199a1b2-0000-7000-8000-000000000000")).await;
    assert!(unknown.unwrap_err().contains("no codex session"));
    let path = c.request(method::SESSION_NEW, adopt("fakecodex", "../../etc/passwd")).await;
    assert!(path.unwrap_err().contains("not a session id"));
    let no_load = c.request(method::SESSION_NEW, adopt("noload", ID)).await;
    assert!(no_load.unwrap_err().contains("could not resume"));
    assert!(hub.sessions().is_empty());
    let _ = std::fs::remove_dir_all(root);
}
