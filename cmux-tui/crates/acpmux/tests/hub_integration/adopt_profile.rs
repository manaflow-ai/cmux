//! An adopted Claude Code chat keeps the profile that ran it. Leo, 2026-10-30: "that visibility
//! into huge-blue guys was (and is?) pretty bad". Four deputies there had been started on the
//! `claude-sr2` profile (`sr2 claude2`: compaction capped, accounts rotated) and came back as
//! plain `claude`, carrying 290-330k of context per call. Every Claude Code profile reads the
//! one Claude store, but adopt went by the profile's family: it refused a `claude-sr2` adopt
//! ("adopt is not supported for claude-sr2 sessions"), so a recovery could only adopt as plain
//! `claude`, and that adopt missed the `claude-sr2` session that held the chat and started a
//! second session on the family default.
use super::*;
use acpmux::adopt::HarnessHomes;

/// Two Claude Code profiles over one Claude store (`CLAUDE_CONFIG_DIR`, as Claude Code lays it
/// out): `claude` and `claude-sr2`, a profile of its own family, as huge-blue's is.
fn two_claude_profiles(config_dir: &std::path::Path, mode: StoreMode) -> Config {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude.py");
    let profile = |family: Option<&str>| HarnessProfile {
        kind: acpmux::config::HarnessKind::ClaudeStdio,
        argv: vec!["python3".into(), fake.into()],
        env: BTreeMap::from([(
            "CLAUDE_CONFIG_DIR".to_owned(),
            config_dir.to_string_lossy().into_owned(),
        )]),
        description: None,
        fallback: None,
        family: family.map(str::to_owned),
        models: vec![],
        model: None,
        effort: None,
        policy: None,
    };
    let mut cfg = Config {
        harnesses: BTreeMap::from([
            ("claude".to_owned(), profile(None)),
            ("claude-sr2".to_owned(), profile(Some("claude-sr2"))),
        ]),
        default_harness: Some("claude".into()),
        ..Default::default()
    };
    cfg.store.mode = mode;
    cfg.permission_policy = PermissionPolicy::ApproveAll;
    cfg
}

async fn connect(hub: &Arc<Hub>, config_dir: &std::path::Path) -> TestClient {
    hub.set_harness_homes(HarnessHomes {
        claude: config_dir.to_owned(),
        codex: config_dir.join("no-codex"),
    });
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection(hub.clone(), in_rx, out_tx));
    let mut c = TestClient { tx: in_tx, rx: out_rx, next: 0 };
    c.request(method::INITIALIZE, json!({"protocolVersion": 1, "clientInfo": {"name": "test"}}))
        .await
        .unwrap();
    c
}

/// The adopt the app's open plan sends (`chats/open.rs` `plan_open`): the chat's folder, and the
/// profile it names.
fn adopt(harness: &str, id: &str, cwd: &std::path::Path) -> Value {
    let acpmux = json!({"harness": harness, "adopt": {"agentSessionId": id}});
    json!({"cwd": cwd, "mcpServers": [], "_meta": {"acpmux": acpmux}})
}

/// Red on the base: after a restart, adopting the chat as plain `claude` (what a client that only
/// knows the chat is Claude Code's sends) made a second session on `claude` instead of opening
/// the `claude-sr2` session that holds it.
#[tokio::test]
async fn a_restart_and_adopt_bring_a_claude_sr2_chat_back_on_claude_sr2() {
    let root = std::env::temp_dir().join(format!("acpmux-adopt-profile-{}", uuid::Uuid::now_v7()));
    let config_dir = root.join("claude");
    let project = root.join("project");
    std::fs::create_dir_all(&project).unwrap();
    let cfg = two_claude_profiles(&config_dir, StoreMode::Local);
    let state = root.join("acpmux");

    // A deputy on `claude-sr2` runs a turn: Claude Code stores its conversation.
    let hub = Hub::new(cfg.clone(), acpmux::store::open(&cfg.store, &state).unwrap());
    let mut c = connect(&hub, &config_dir).await;
    let s = c
        .request(
            method::SESSION_NEW,
            json!({"cwd": project, "mcpServers": [],
                   "_meta": {"acpmux": {"harness": "claude-sr2", "name": "dep-fleet"}}}),
        )
        .await
        .unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    c.request(
        method::SESSION_PROMPT,
        json!({"sessionId": id, "prompt": [{"type": "text", "text": "hi"}]}),
    )
    .await
    .unwrap();
    let chat = hub.resolve(&id).unwrap().meta().agent_session_id.expect("a Claude session id");
    assert!(acpmux::adopt::claude_session_exists(&config_dir, &chat));
    hub.shutdown_all().await;
    drop(c);
    drop(hub);

    // The daemon restarts; a recovery adopts the chat by its Claude id.
    let hub = Hub::new(cfg.clone(), acpmux::store::open(&cfg.store, &state).unwrap());
    let mut c = connect(&hub, &config_dir).await;
    for asked in ["claude", "claude-sr2"] {
        let again = c.request(method::SESSION_NEW, adopt(asked, &chat, &project)).await;
        let again = again.unwrap_or_else(|e| panic!("adopt as {asked}: {e}"));
        assert_eq!(again["sessionId"], id.as_str(), "adopt as {asked} opens the chat's session");
    }
    assert_eq!(hub.sessions().len(), 1);
    assert_eq!(hub.resolve(&id).unwrap().meta().harness, "claude-sr2");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(root);
}

/// Red on the base ("adopt is not supported for claude-sr2 sessions"): a chat this daemon never
/// ran adopts on the profile the request names, from the Claude store every Claude Code
/// profile reads.
#[tokio::test]
async fn adopt_names_a_claude_profile_of_another_family_and_runs_on_it() {
    let root = std::env::temp_dir().join(format!("acpmux-adopt-profile-{}", uuid::Uuid::now_v7()));
    let config_dir = root.join("claude");
    let project = root.join("project");
    std::fs::create_dir_all(&project).unwrap();
    let chat = uuid::Uuid::new_v4().to_string();
    let transcript = config_dir.join(format!("projects/p/{chat}.jsonl"));
    std::fs::create_dir_all(transcript.parent().unwrap()).unwrap();
    let line = json!({"type": "user", "cwd": project, "sessionId": chat,
                      "message": {"role": "user", "content": "hi"}});
    std::fs::write(&transcript, format!("{line}\n")).unwrap();
    let cfg = two_claude_profiles(&config_dir, StoreMode::Memory);
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let mut c = connect(&hub, &config_dir).await;
    let s = c.request(method::SESSION_NEW, adopt("claude-sr2", &chat, &project)).await.unwrap();
    let meta = hub.resolve(s["sessionId"].as_str().unwrap()).unwrap().meta();
    assert_eq!(meta.harness, "claude-sr2");
    assert_eq!(meta.agent_session_id.as_deref(), Some(chat.as_str()));
    assert_eq!(meta.cwd, project);
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(root);
}
