//! Compact and send (`hub/return_compact.rs`): a prompt that asks for it (`cacheCompact:
//! "compact"`, the composer's chip, `acpmux send --compact-first`) runs `/compact` first and then
//! itself, queued behind the compaction; `keep` and a warm cache send it as it is; the chat's usage
//! says when "When You Return" would compact (`compactOnReturn`). One test function: the settings
//! file is read from this process's env. When the cache lapses is wall-clock time (5 minutes from
//! the fake's call), so the unasked compaction of a lapsed cache is `due`'s unit test.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

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

fn ran(text: &str, kind: Option<&str>) -> (String, Option<String>) {
    (text.to_owned(), kind.map(str::to_owned))
}

/// Whether any of the chat's logged updates says `compactOnReturn`.
fn flagged(hub: &Hub, id: &str) -> bool {
    hub.events(id, 0, 10_000)
        .unwrap()
        .iter()
        .any(|e| e.msg.to_string().contains("\"compactOnReturn\":true"))
}

#[tokio::test]
async fn a_prompt_runs_after_the_compaction_it_asked_for() {
    let root = std::env::temp_dir().join(format!("acpmux-return-compact-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(root.join("claude")).unwrap();
    let settings = root.join("cmux-next.json");
    let set = |doc: Value| std::fs::write(&settings, doc.to_string()).unwrap();
    set(json!({"agents": {"cacheCompact": {"mode": "onReturn", "returnMinTokens": 100000}}}));
    // SAFETY: the only test in this binary; set before any session starts.
    unsafe {
        std::env::set_var("CMUX_NEXT_CONFIG_FILE", &settings);
        std::env::set_var("ACPMUX_HOME", root.join("home"));
        std::env::set_var("FLEET_REGISTRY", root.join("fleet-registry.json"));
    }
    std::fs::write(root.join("fleet-registry.json"), r#"{"machines": {}}"#).unwrap();
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"claude": {"kind": "claude-stdio", "argv": ["python3", FAKE_CLAUDE],
            "env": {"CLAUDE_CONFIG_DIR": root.join("claude")}}},
        "defaultHarness": "claude",
        "permissionPolicy": "approve-all",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let mut c = Client::new(&hub).await;
    let new = json!({"cwd": std::env::temp_dir(), "mcpServers": []});
    let prompt = |id: &str, text: &str, choice: Option<&str>| {
        let mut p = json!({"sessionId": id, "prompt": [{"type": "text", "text": text}]});
        if let Some(choice) = choice {
            p["_meta"] = json!({"acpmux": {"cacheCompact": choice}});
        }
        p
    };

    // 150K of context with a warm 5 minute cache: over the floor, so the usage says so.
    let id = c.ok("session/new", new.clone()).await["sessionId"].as_str().unwrap().to_owned();
    c.ok("session/prompt", prompt(&id, "cache-probe", None)).await;
    assert!(flagged(&hub, &id), "the usage names compactOnReturn");

    // Unasked while the cache is warm, and `keep`: sent as they are.
    c.ok("session/prompt", prompt(&id, "warm", None)).await;
    c.ok("session/prompt", prompt(&id, "cold", Some("keep"))).await;
    assert_eq!(prompts(&hub, &id)[1..], [ran("warm", None), ran("cold", None)]);

    // `compact`: /compact runs first, then the prompt, whose answer comes after both.
    c.ok("session/prompt", prompt(&id, "after", Some("compact"))).await;
    let all = prompts(&hub, &id);
    assert_eq!(all[3..], [ran("/compact", Some("return_compact")), ran("after", None)], "{all:?}");

    // A compacted chat has no known cache: asked again, nothing is compacted.
    c.ok("session/prompt", prompt(&id, "again", Some("compact"))).await;
    assert_eq!(prompts(&hub, &id).last(), Some(&ran("again", None)));
    assert_eq!(prompts(&hub, &id).len(), 6, "{:?}", prompts(&hub, &id));

    // The mode off (the default): the usage names nothing.
    set(json!({}));
    let off = c.ok("session/new", new).await["sessionId"].as_str().unwrap().to_owned();
    c.ok("session/prompt", prompt(&off, "cache-probe", None)).await;
    assert!(!flagged(&hub, &off), "off by default");

    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}
