//! Compact before the prompt cache expires (`hub/cache_compact.rs`): an idle Claude chat over the
//! context threshold runs `/compact` once, about 30 s before its cache lapses, only with the
//! setting on. One test function: the settings file is read from this process's env. The hub's
//! clock is a `ManualClock`, so the 5 minutes pass at once.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::clock::ManualClock;
use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::Message;
use acpmux::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE_CLAUDE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude.py");

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

impl Client {
    async fn new(hub: &Arc<Hub>) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
        Client(in_tx, out_rx, 0)
    }

    async fn ok(&mut self, m: &str, params: Value) -> Value {
        self.2 += 1;
        let id = self.2;
        self.0.send(Message::request(id, m, params).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(30), self.1.recv())
                .await
                .unwrap()
                .unwrap();
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                assert!(v.get("error").is_none(), "{m}: {v}");
                return v["result"].clone();
            }
        }
    }
}

/// The prompts the chat ran, as (text, provenance kind).
fn prompts(hub: &Hub, id: &str) -> Vec<(String, Option<String>)> {
    hub.events(id, 0, 10_000)
        .unwrap()
        .into_iter()
        .filter(|e| e.kind == "user_message")
        .map(|e| {
            let text = e.msg["text"].as_str().unwrap_or_default().to_owned();
            let kind = e.msg.pointer("/_meta/provenance/kind").and_then(Value::as_str);
            (text, kind.map(str::to_owned))
        })
        .collect()
}

fn compactions(hub: &Hub, id: &str) -> usize {
    prompts(hub, id).iter().filter(|(_, kind)| kind.as_deref() == Some("cache_compact")).count()
}

/// Lets the hub's tasks run (the timer's prompt, its turn) for up to `cap` real time.
async fn settle_until(cap: Duration, done: impl Fn() -> bool) {
    let deadline = std::time::Instant::now() + cap;
    while !done() && std::time::Instant::now() < deadline {
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

#[tokio::test]
async fn an_idle_claude_chat_compacts_once_before_its_cache_expires_only_when_opted_in() {
    let root = std::env::temp_dir().join(format!("acpmux-cache-compact-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(root.join("claude")).unwrap();
    let settings = root.join("cmux-next.json");
    let set_at = |on: bool, percent: u64| {
        let doc =
            json!({"agents": {"cacheCompact": {"enabled": on, "minContextPercent": percent}}});
        std::fs::write(&settings, doc.to_string()).unwrap();
    };
    let set = |on: bool| set_at(on, 50);
    set(true);
    let compact_fails = root.join("compact-fails");
    // SAFETY: the only test in this binary; set before any session starts.
    unsafe {
        std::env::set_var("CMUX_NEXT_CONFIG_FILE", &settings);
        std::env::set_var("ACPMUX_HOME", root.join("home"));
        std::env::set_var("FLEET_REGISTRY", root.join("fleet-registry.json"));
    }
    std::fs::write(root.join("fleet-registry.json"), r#"{"machines": {}}"#).unwrap();
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"claude": {"kind": "claude-stdio", "argv": ["python3", FAKE_CLAUDE],
            "env": {"CLAUDE_CONFIG_DIR": root.join("claude"),
                "FAKE_CLAUDE_COMPACT_FAIL_IF": compact_fails}}},
        "defaultHarness": "claude",
        "permissionPolicy": "approve-all",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let clock = ManualClock::new();
    hub.set_clock(clock.clone());
    let mut c = Client::new(&hub).await;
    let new = json!({"cwd": std::env::temp_dir(), "mcpServers": []});
    let prompt =
        |id: &str, text: &str| json!({"sessionId": id, "prompt": [{"type": "text", "text": text}]});

    // Opted in, idle and at 75% of the window: /compact runs before the 5 minutes end, once.
    let id = c.ok("session/new", new.clone()).await["sessionId"].as_str().unwrap().to_owned();
    c.ok("session/prompt", prompt(&id, "cache-probe")).await;
    clock.advance(Duration::from_secs(200));
    settle_until(Duration::from_millis(300), || false).await;
    assert_eq!(compactions(&hub, &id), 0, "it waits until about 30 s before the expiry");
    clock.advance(Duration::from_secs(75));
    settle_until(Duration::from_secs(20), || compactions(&hub, &id) == 1).await;
    let ran = prompts(&hub, &id);
    assert_eq!(
        ran.last(),
        Some(&("/compact".to_owned(), Some("cache_compact".to_owned()))),
        "{ran:?}"
    );
    clock.advance(Duration::from_secs(3600));
    settle_until(Duration::from_millis(500), || false).await;
    assert_eq!(compactions(&hub, &id), 1, "once per idle stretch: {:?}", prompts(&hub, &id));

    // An unsent draft in one surface's composer (`_acpmux/composer_set`), with nobody typing:
    // the person is mid-message, so nothing is compacted under them.
    let drafted = c.ok("session/new", new.clone()).await["sessionId"].as_str().unwrap().to_owned();
    c.ok("session/prompt", prompt(&drafted, "cache-probe")).await;
    let surface = json!({"id": "pane-1", "name": "Pane"});
    let draft = json!({"sessionId": drafted, "surface": surface, "text": "half a thought"});
    c.ok("_acpmux/composer_set", draft).await;
    clock.advance(Duration::from_secs(3600));
    settle_until(Duration::from_millis(500), || false).await;
    assert_eq!(compactions(&hub, &drafted), 0, "{:?}", prompts(&hub, &drafted));

    // Four ways the timer must stay quiet, each recorded, so one run names every one that fails.
    let mut gaps = Vec::new();
    let mut quiet = |gap: &str, id: &str| {
        let n = compactions(&hub, id);
        if n != 0 {
            gaps.push(format!("{gap}: {n} compaction(s), {:?}", prompts(&hub, id)));
        }
    };

    // The person compacted it before the deadline (`/compact`, which reports no usage after):
    // the cache it was armed for is gone, so the timer ends with it.
    let manual = c.ok("session/new", new.clone()).await["sessionId"].as_str().unwrap().to_owned();
    c.ok("session/prompt", prompt(&manual, "cache-probe")).await;
    c.ok("session/prompt", prompt(&manual, "/compact")).await;
    clock.advance(Duration::from_secs(3600));
    settle_until(Duration::from_millis(500), || false).await;
    quiet("after a manual /compact", &manual);

    // Armed at 75% with the threshold at 50%, then the person raised it to 90%: the threshold
    // read at the deadline decides.
    let raised = c.ok("session/new", new.clone()).await["sessionId"].as_str().unwrap().to_owned();
    c.ok("session/prompt", prompt(&raised, "cache-probe")).await;
    set_at(true, 90);
    clock.advance(Duration::from_secs(3600));
    settle_until(Duration::from_millis(500), || false).await;
    set(true);
    quiet("after the threshold was raised past the context", &raised);

    // A background subagent still at work after the turn: the chat is not idle.
    let fifo = root.join("bg-agent-gate");
    assert!(std::process::Command::new("mkfifo").arg(&fifo).status().unwrap().success());
    let busy = c.ok("session/new", new.clone()).await["sessionId"].as_str().unwrap().to_owned();
    let gate = format!("bg-agent-gate: {}", fifo.display());
    c.ok("session/prompt", prompt(&busy, &gate)).await;
    c.ok("session/prompt", prompt(&busy, "cache-probe")).await;
    clock.advance(Duration::from_secs(3600));
    settle_until(Duration::from_millis(500), || false).await;
    quiet("while a background subagent works", &busy);
    let end = fifo.clone();
    tokio::task::spawn_blocking(move || std::fs::write(end, "done")).await.unwrap().unwrap();

    // The compaction's connection drops: no automatic continuation follows it (a model call
    // nobody asked for); the next turn's usage arms the timer again.
    std::fs::write(&compact_fails, "").unwrap();
    let cut = c.ok("session/new", new.clone()).await["sessionId"].as_str().unwrap().to_owned();
    c.ok("session/prompt", prompt(&cut, "cache-probe")).await;
    clock.advance(Duration::from_secs(275));
    settle_until(Duration::from_secs(20), || compactions(&hub, &cut) == 1).await;
    assert_eq!(compactions(&hub, &cut), 1, "{:?}", prompts(&hub, &cut));
    let resumes = |hub: &Hub| {
        let events = hub.events(&cut, 0, 10_000).unwrap();
        events.iter().filter(|e| e.kind == "auto_resume_scheduled").count()
    };
    settle_until(Duration::from_millis(500), || resumes(&hub) > 0).await;
    if resumes(&hub) != 0 {
        gaps.push(format!("a failed cache compaction was auto-resumed: {:?}", prompts(&hub, &cut)));
    }
    std::fs::remove_file(&compact_fails).unwrap();
    assert!(gaps.is_empty(), "{gaps:#?}");

    // Under the threshold (usage-probe: 4.2K of 200K, no cache tier): nothing is armed.
    let small = c.ok("session/new", new.clone()).await["sessionId"].as_str().unwrap().to_owned();
    c.ok("session/prompt", prompt(&small, "usage-probe")).await;
    clock.advance(Duration::from_secs(3600));
    settle_until(Duration::from_millis(500), || false).await;
    assert_eq!(compactions(&hub, &small), 0);

    // The setting off (the default): no compaction, however full and idle.
    set(false);
    let off = c.ok("session/new", new).await["sessionId"].as_str().unwrap().to_owned();
    c.ok("session/prompt", prompt(&off, "cache-probe")).await;
    clock.advance(Duration::from_secs(3600));
    settle_until(Duration::from_millis(500), || false).await;
    assert_eq!(compactions(&hub, &off), 0, "{:?}", prompts(&hub, &off));

    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}
