//! A fork survives a daemon restart (cmux#50096, cmux#50084). Leo, 2026-11-22: "we ought to
//! really hammer it hard and just test tons of variations of it."
//!
//! A Claude fork gets its chat's conversation when its agent first starts (`--resume <chat>
//! --fork-session`). A restart between the fork and that start (the fork-hammer lane's race: a
//! fork 0.4 s before `acpmux daemon restart`, or at the same moment) left a fork that listed the
//! chat's turns while its agent began a fresh conversation. And the retry the cut-off fork's
//! `daemon_closed` invited made a second fork with the same name.

use super::*;

const FORK_OP: &str = "acp.session.fork";

struct Daemon {
    cfg: Config,
    dir: std::path::PathBuf,
}

impl Daemon {
    /// A Claude profile (fake_claude.py in Claude Code's own store layout) whose fork starts
    /// hang at initialize while `hold` exists, over a store kept on disk across restarts.
    fn new(root: &std::path::Path, hold: &std::path::Path) -> Self {
        let claude = root.join("claude");
        std::fs::create_dir_all(&claude).unwrap();
        let fake_claude = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude.py");
        let env = BTreeMap::from([
            ("CLAUDE_CONFIG_DIR".to_owned(), claude.to_string_lossy().into_owned()),
            ("FAKE_CLAUDE_HOLD_FORK_IF".to_owned(), hold.to_string_lossy().into_owned()),
            // system/init only once a turn starts, as Claude Code sends it. Sent right after
            // initialize instead, it raced the fork's start: read in time, the fork knew its id
            // and skipped its priming turn; read late (a loaded runner), the priming prompt was in
            // the fork's conversation. Now a fork always primes, as it does with Claude Code.
            ("FAKE_CLAUDE_INIT_ON_TURN".to_owned(), "1".to_owned()),
        ]);
        let profile = HarnessProfile {
            kind: acpmux::config::HarnessKind::ClaudeStdio,
            argv: vec!["python3".into(), fake_claude.into()],
            env,
            description: None,
            fallback: None,
            family: None,
            models: vec![],
            model: None,
            effort: None,
            policy: None,
        };
        let mut cfg = Config {
            harnesses: BTreeMap::from([("claude".to_owned(), profile)]),
            default_harness: Some("claude".into()),
            ..Default::default()
        };
        cfg.store.mode = StoreMode::Local;
        cfg.permission_policy = PermissionPolicy::ApproveAll;
        Self { cfg, dir: root.join("store") }
    }

    /// A daemon on the store, as a restart starts one, and a client of it.
    async fn start(&self) -> (Arc<Hub>, TestClient) {
        let store = acpmux::store::open(&self.cfg.store, &self.dir).unwrap();
        let hub = Hub::new(self.cfg.clone(), store);
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection(hub.clone(), in_rx, out_tx));
        let mut c = TestClient { tx: in_tx, rx: out_rx, next: 0 };
        c.request(
            method::INITIALIZE,
            json!({"protocolVersion": 1, "clientInfo": {"name": "pane"}}),
        )
        .await
        .unwrap();
        (hub, c)
    }
}

async fn chat(c: &mut TestClient) -> String {
    let s = c
        .request(
            method::SESSION_NEW,
            json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": {"name": "p"}}}),
        )
        .await
        .unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    for text in ["Remember this codeword: PERIWINKLE-4471", "say BANANA 2"] {
        let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": text}]});
        c.request(method::SESSION_PROMPT, prompt).await.unwrap();
    }
    id
}

/// The prompts the session's Claude conversation held before the probe (fake_claude.py's
/// "history-probe").
async fn conversation(hub: &Arc<Hub>, c: &mut TestClient, id: &str) -> Value {
    let before = hub.events(id, 0, 10_000).unwrap().last().map_or(0, |e| e.seq);
    let probe = json!({"sessionId": id, "prompt": [{"type": "text", "text": "history-probe"}]});
    c.request(method::SESSION_PROMPT, probe).await.unwrap();
    let text: String = hub
        .events(id, before, 10_000)
        .unwrap()
        .iter()
        .filter(|e| e.kind == "agent_message_chunk")
        .filter_map(|e| e.msg.pointer("/params/update/content/text").and_then(Value::as_str))
        .collect();
    let prompts =
        serde_json::from_str::<Value>(&text).unwrap_or_else(|e| panic!("{e}: {text}"))["prompts"]
            .clone();
    // A forked Claude process is primed with one prompt so it learns its new id (lifecycle.rs);
    // that prompt is the daemon's, not the chat's conversation.
    Value::Array(
        prompts
            .as_array()
            .unwrap_or_else(|| panic!("{text}"))
            .iter()
            .filter(|p| p.as_str().is_none_or(|p| !p.starts_with("This session was just forked")))
            .cloned()
            .collect(),
    )
}

fn live_fork(id: &str, request: &str) -> Value {
    json!({"sessionId": id, "live": true, "requestId": request})
}

/// The open forks of `parent`.
fn open_forks(hub: &Hub, parent: &str) -> Vec<String> {
    hub.sessions()
        .iter()
        .map(|s| s.meta())
        .filter(|m| {
            m.parent_id.as_deref() == Some(parent)
                && m.status != acpmux::store::SessionStatus::Closed
        })
        .map(|m| m.id)
        .collect()
}

/// Every session's name and status, for a failed assertion.
fn names(hub: &Hub) -> Vec<(String, String)> {
    hub.sessions().iter().map(|s| s.meta()).map(|m| (m.name, format!("{:?}", m.status))).collect()
}

/// The race: the fork answers, its agent is still starting, the daemon restarts. The next
/// daemon starts the fork's agent from the chat's conversation, and the same fork request sent
/// again (the CLI's retry after `daemon_closed`) answers that fork, never a second one.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_fork_whose_agent_a_restart_cut_off_resumes_its_chat_and_a_retry_finds_it() {
    let root = std::env::temp_dir().join(format!("acpmux-fork-restart-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&root).unwrap();
    let hold = root.join("hold-fork");
    let daemon = Daemon::new(&root, &hold);
    let (hub, mut c) = daemon.start().await;
    let id = chat(&mut c).await;
    std::fs::write(&hold, "").unwrap();
    let f = c.request(FORK_OP, live_fork(&id, "click-1")).await.unwrap();
    let fid = f["sessionId"].as_str().unwrap().to_owned();
    // The same click's request again on this daemon: the one fork.
    let again = c.request(FORK_OP, live_fork(&id, "click-1")).await.unwrap();
    assert_eq!(again["sessionId"], fid.as_str());
    assert_eq!(open_forks(&hub, &id), vec![fid.clone()], "{:?}", names(&hub));
    // Restart while the fork's agent is starting (held at initialize).
    hub.shutdown_all().await;
    drop(hub);
    std::fs::remove_file(&hold).unwrap();

    let (hub, mut c) = daemon.start().await;
    let summary = hub.session_summary(&hub.resolve(&fid).unwrap());
    assert_ne!(summary["status"], "closed", "{summary}");
    // The retry after the restart: still the one fork.
    let retried = c.request(FORK_OP, live_fork(&id, "click-1")).await.unwrap();
    assert_eq!(retried["sessionId"], fid.as_str());
    assert_eq!(open_forks(&hub, &id), vec![fid.clone()], "{:?}", names(&hub));
    // Its agent resumed the chat's conversation: it knows the codeword.
    let held = conversation(&hub, &mut c, &fid).await;
    assert_eq!(
        held,
        json!(["Remember this codeword: PERIWINKLE-4471", "say BANANA 2"]),
        // Its priming turn (`Hub::cold_start`) is the daemon's, and `conversation` leaves it out.
        "the fork's agent holds the chat's conversation"
    );
    // Nothing pending is left in its meta once its agent took the conversation.
    let meta = hub.resolve(&fid).unwrap().meta();
    assert!(meta.fork_start.is_none(), "{:?}", meta.fork_start);
    // Another click is another fork.
    let other = c.request(FORK_OP, live_fork(&id, "click-2")).await.unwrap();
    assert_ne!(other["sessionId"], fid.as_str());
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(root);
}

/// A fork the restart cut off while it was being made (its meta written, its history not all in)
/// is closed at the next start, never listed as a copy, and the retry makes the fork again.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_fork_cut_off_while_it_was_made_is_closed_at_the_next_start() {
    let root = std::env::temp_dir().join(format!("acpmux-fork-cut-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&root).unwrap();
    let hold = root.join("hold-fork");
    let daemon = Daemon::new(&root, &hold);
    let (hub, mut c) = daemon.start().await;
    let id = chat(&mut c).await;
    std::fs::write(&hold, "").unwrap();
    let f = c.request(FORK_OP, live_fork(&id, "click-1")).await.unwrap();
    let fid = f["sessionId"].as_str().unwrap().to_owned();
    hub.shutdown_all().await;
    drop(hub);
    std::fs::remove_file(&hold).unwrap();
    // As the store holds a fork whose daemon stopped between its meta and its `forked` record.
    {
        let store = acpmux::store::open(&daemon.cfg.store, &daemon.dir).unwrap();
        let mut meta = store.list().unwrap().into_iter().find(|m| m.id == fid).unwrap();
        meta.fork_start.get_or_insert_with(Default::default).made = false;
        store.save(&meta).unwrap();
        store.flush().unwrap();
    }

    let (hub, mut c) = daemon.start().await;
    let summary = hub.session_summary(&hub.resolve(&fid).unwrap());
    assert_eq!(summary["status"], "closed", "{summary}");
    let retried = c.request(FORK_OP, live_fork(&id, "click-1")).await.unwrap();
    let rid = retried["sessionId"].as_str().unwrap().to_owned();
    assert_ne!(rid, fid, "the cut-off fork is not answered as made");
    assert_eq!(open_forks(&hub, &id), vec![rid.clone()], "{:?}", names(&hub));
    let held = conversation(&hub, &mut c, &rid).await;
    assert_eq!(held[0], "Remember this codeword: PERIWINKLE-4471", "{held}");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(root);
}
