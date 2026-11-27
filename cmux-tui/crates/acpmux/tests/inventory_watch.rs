//! Cached inventory watch over the actual JSON-RPC server. No live CLIs,
//! credentials, registry requests or health checks are needed by a watcher.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use acpmux::config::{Config, ProfileSources, StoreMode};
use acpmux::harness_health::Settings;
use acpmux::hub::Hub;
use acpmux::rpc::{Message, method};
use acpmux::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use std::collections::VecDeque;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const WATCH: &str = "_acpmux/harness/inventory/watch";
const EVENT: &str = "_acpmux/harness_inventory";
const FEATURE: &str = "harnessInventoryWatch";

struct Fixture {
    root: PathBuf,
    hub: Arc<Hub>,
}

impl Fixture {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!("acpmux-inventory-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&root).unwrap();
        let config = root.join("config.json");
        std::fs::write(&config, "{}").unwrap();
        let mut cfg = Config::load_from_with(&config, &ProfileSources::none()).unwrap();
        cfg.store.mode = StoreMode::Memory;
        let store = acpmux::store::open(&cfg.store, &root).unwrap();
        Self { root, hub: Hub::new(cfg, store) }
    }

    fn cache(&self, rows: Value) {
        let cache = self.root.join("health.json");
        std::fs::write(&cache, rows.to_string()).unwrap();
        self.hub.health.attach(Settings {
            cache: Some(cache),
            home: self.root.join("home"),
            ..Settings::default()
        });
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

struct Client {
    tx: mpsc::Sender<String>,
    rx: mpsc::Receiver<String>,
    task: tokio::task::JoinHandle<()>,
    notes: VecDeque<Value>,
    next: u64,
}

impl Client {
    fn open(f: &Fixture, origin: Origin) -> Self {
        let (tx, inbound) = mpsc::channel(64);
        let (out, rx) = mpsc::channel(64);
        let task = tokio::spawn(serve_connection_with(f.hub.clone(), inbound, out, origin));
        Self { tx, rx, task, notes: VecDeque::new(), next: 1 }
    }

    async fn frame(&mut self) -> Value {
        let line = tokio::time::timeout(Duration::from_secs(3), self.rx.recv())
            .await
            .expect("server frame timed out")
            .expect("server closed");
        serde_json::from_str(&line).unwrap()
    }

    async fn call(&mut self, op: &str, params: Value) -> Result<Value, Value> {
        let id = self.next;
        self.next += 1;
        self.tx.send(Message::request(id, op, params).to_line()).await.unwrap();
        loop {
            let frame = self.frame().await;
            if frame["id"] == id {
                return match frame.get("error") {
                    Some(error) => Err(error.clone()),
                    None => Ok(frame["result"].clone()),
                };
            }
            self.notes.push_back(frame);
        }
    }

    async fn event(&mut self) -> Value {
        loop {
            let frame = match self.notes.pop_front() {
                Some(frame) => frame,
                None => self.frame().await,
            };
            if frame["method"] == EVENT {
                return frame["params"].clone();
            }
        }
    }

    async fn quiet(&mut self) {
        assert!(!self.notes.iter().any(|n| n["method"] == EVENT));
        while let Ok(Some(line)) =
            tokio::time::timeout(Duration::from_millis(40), self.rx.recv()).await
        {
            let frame: Value = serde_json::from_str(&line).unwrap();
            assert_ne!(frame["method"], EVENT, "unsolicited inventory notification");
        }
    }

    async fn close(self) {
        drop(self.tx);
        tokio::time::timeout(Duration::from_secs(3), self.task).await.unwrap().unwrap();
    }
}

fn row(id: &str, version: &str) -> Value {
    json!({"id":id,"program":"codex","path":"/private/secret/codex","channel":"npm",
        "package":"@openai/codex","version":version,"latest":"2.0.0","latestCheckedAt":4,
        "outdated":true,"auth":"signedIn","checkedAt":5,
        "authDetail":"private@example.test secret-token","problem":"secret-token",
        "login":"secret-token","update":{"argv":["secret-token"],"command":"secret-token","elevated":false}})
}

#[tokio::test]
async fn cmux_next_inventory_watch_negotiates_and_never_runs_an_empty_cache_check() {
    let f = Fixture::new();
    let mut client = Client::open(&f, Origin::Local);
    let hello = client.call(method::INITIALIZE, json!({})).await.unwrap();
    assert!(
        hello
            .pointer("/_meta/acpmux/features")
            .unwrap()
            .as_array()
            .unwrap()
            .contains(&json!(FEATURE))
    );
    let initial = client.call(WATCH, json!({"enabled":true})).await.unwrap();
    assert_eq!(initial, json!({"view":"inventory","cached":true,"harnesses":[],"revision":0}));
    assert!(f.hub.health.rows().is_empty());
    client.close().await;
}

#[tokio::test]
async fn cmux_next_inventory_watch_publishes_sanitized_changes_and_removal() {
    let f = Fixture::new();
    f.cache(json!([row("codex", "1.0.0")]));
    let mut client = Client::open(&f, Origin::Local);
    let initial = client.call(WATCH, json!({"enabled":true})).await.unwrap();
    assert_eq!(initial["harnesses"][0]["version"], "1.0.0");
    f.cache(json!([row("codex", "1.1.0")]));
    let changed = client.event().await;
    assert_eq!(changed["harnesses"][0]["version"], "1.1.0");
    assert!(changed["revision"].as_u64().unwrap() > initial["revision"].as_u64().unwrap());
    for snapshot in [initial, changed.clone()] {
        let text = snapshot.to_string();
        for private in [
            "secret-token",
            "private@example.test",
            "/private/secret",
            "program",
            "update",
            "login",
        ] {
            assert!(!text.contains(private), "private field in inventory: {private}");
        }
    }
    f.cache(json!([]));
    let removed = client.event().await;
    assert_eq!(removed["harnesses"], json!([]));
    assert!(removed["revision"].as_u64().unwrap() > changed["revision"].as_u64().unwrap());
    client.close().await;
}

#[tokio::test]
async fn cmux_next_inventory_watch_requires_explicit_subscription_and_stops_when_disabled() {
    let f = Fixture::new();
    let mut client = Client::open(&f, Origin::Local);
    client.call(method::INITIALIZE, json!({})).await.unwrap();
    f.cache(json!([row("codex", "1.0.0")]));
    client.quiet().await;
    let initial = client.call(WATCH, json!({"enabled":true})).await.unwrap();
    assert_eq!(initial["harnesses"][0]["version"], "1.0.0");
    assert_eq!(client.call(WATCH, json!({"enabled":false})).await.unwrap(), json!({}));
    // Notifications already queued before the disable ACK may precede it.
    client.notes.clear();
    f.cache(json!([row("codex", "1.1.0")]));
    client.quiet().await;
    client.close().await;
}

#[tokio::test]
async fn cmux_next_inventory_watch_refuses_nonlocal_origins_and_control_parameters() {
    let f = Fixture::new();
    for origin in [Origin::LocalApp, Origin::Web, Origin::Peer] {
        let mut client = Client::open(&f, origin);
        let error = client
            .call(WATCH, json!({"enabled":true}))
            .await
            .expect_err("nonlocal inventory watch");
        assert_eq!(error["code"], -32602);
        client.close().await;
    }
    let mut client = Client::open(&f, Origin::Local);
    for params in [
        json!({}),
        json!({"enabled":"true"}),
        json!({"enabled":true,"refresh":true}),
        json!({"enabled":true,"command":"bad"}),
        json!({"enabled":true,"machine":"other"}),
        json!({"enabled":true,"sessionId":"peer:session"}),
        json!({"enabled":true,"session":"peer:session"}),
    ] {
        assert_eq!(client.call(WATCH, params).await.unwrap_err()["code"], -32602);
    }
    f.cache(json!([row("codex", "1.0.0")]));
    client.quiet().await;
    client.close().await;
}

#[tokio::test]
async fn cmux_next_inventory_watch_bounds_snapshots_and_coalesces_cache_bursts() {
    let f = Fixture::new();
    let mut client = Client::open(&f, Origin::Local);
    client.call(WATCH, json!({"enabled":true})).await.unwrap();
    // No await: a stalled consumer need only retain the newest full snapshot.
    for i in 0..100 {
        f.cache(json!([row("codex", &format!("1.0.{i}"))]));
    }
    let latest = client.event().await;
    assert_eq!(latest["harnesses"][0]["version"], "1.0.99");
    f.cache(Value::Array((0..300).map(|i| row(&format!("profile-{i}"), "1.0.0")).collect()));
    let bounded = client.event().await;
    assert_eq!(bounded["harnesses"].as_array().unwrap().len(), 256);
    client.close().await;
}

#[tokio::test]
async fn cmux_next_inventory_watch_preserves_legacy_cached_read_shape() {
    let f = Fixture::new();
    f.cache(json!([row("codex", "1.0.0")]));
    let mut client = Client::open(&f, Origin::Local);
    let legacy =
        client.call(method::MUX_HARNESS_HEALTH, json!({"view":"inventory"})).await.unwrap();
    assert_eq!(legacy["harnesses"][0]["family"], "codex");
    assert_eq!(
        legacy.as_object().unwrap().keys().cloned().collect::<Vec<_>>(),
        ["cached", "harnesses", "view"]
    );
    client.quiet().await;
    client.close().await;
}

#[tokio::test]
async fn cmux_next_inventory_watch_ignores_private_only_cache_changes() {
    let f = Fixture::new();
    let mut cached = row("codex", "1.0.0");
    f.cache(json!([cached]));
    let mut client = Client::open(&f, Origin::Local);
    let initial = client.call(WATCH, json!({"enabled":true})).await.unwrap();
    cached["authDetail"] = json!("another-private-value");
    cached["problem"] = json!("another-private-problem");
    f.cache(json!([cached]));
    client.quiet().await;
    let current = client.call(WATCH, json!({"enabled":true})).await.unwrap();
    assert_eq!(initial, current, "private diagnostics changed the public revision");
    client.close().await;
}

#[tokio::test]
async fn cmux_next_inventory_watch_follows_owner_health_commits_without_starting_one() {
    let f = Fixture::new();
    f.cache(json!([row("codex", "1.0.0")]));
    let mut client = Client::open(&f, Origin::Local);
    let initial = client.call(WATCH, json!({"enabled":true})).await.unwrap();
    assert_eq!(f.hub.health.rows().len(), 1, "subscription replaced the cache");
    // The owner independently checks its now-empty subject set. The watcher
    // must receive that committed removal without asking for another check.
    assert!(f.hub.health.check(Vec::new(), false).await.is_empty());
    let removed = client.event().await;
    assert_eq!(removed["harnesses"], json!([]));
    assert!(removed["revision"].as_u64().unwrap() > initial["revision"].as_u64().unwrap());
    client.close().await;
}
