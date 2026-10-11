//! Activity view (meeting 2026-10-08, AV): a chat in the device index
//! carries what its live acpmux session needs from the person (`attention`)
//! and its latest reply (`preview`), and a chats watcher hears every change
//! of either as `_acpmux/chat_changed {kind: "activity"}`. Synthetic temp
//! homes only.

use acpmux::adopt::HarnessHomes;
use acpmux::chats::ChatSources;
use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::{Message, method};
use acpmux::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const CODEX_ID: &str = "0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b";
const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

struct Home(PathBuf);

impl Drop for Home {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn home() -> Home {
    let base = std::env::temp_dir().join(format!("acpmux-activity-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&base).unwrap();
    Home(std::fs::canonicalize(&base).unwrap())
}

fn mkdir(path: &Path) -> PathBuf {
    std::fs::create_dir_all(path).unwrap();
    path.to_path_buf()
}

/// A Codex rollout written an hour ago (a recent one is live elsewhere and adopt refuses it).
fn write_rollout(codex_home: &Path, cwd: &Path) {
    let rollout = codex_home
        .join(format!("sessions/2026/10/02/rollout-2026-10-02T09-00-00-{CODEX_ID}.jsonl"));
    std::fs::create_dir_all(rollout.parent().unwrap()).unwrap();
    let record = json!({"type": "session_meta", "payload": {"id": CODEX_ID, "cwd": cwd, "timestamp": "2026-10-02T09:00:00Z"}});
    std::fs::write(&rollout, format!("{record}\n")).unwrap();
    let hour_ago = std::time::SystemTime::now() - Duration::from_secs(3600);
    std::fs::File::options().write(true).open(&rollout).unwrap().set_modified(hour_ago).unwrap();
}

struct Client {
    tx: mpsc::Sender<String>,
    rx: mpsc::Receiver<String>,
    next: i64,
}

impl Client {
    async fn new(hub: &Arc<Hub>) -> Self {
        let (tx, in_rx) = mpsc::channel(64);
        let (out_tx, rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
        let mut client = Self { tx, rx, next: 1 };
        client
            .call(method::INITIALIZE, json!({"protocolVersion": 1, "clientInfo": {"name": "t"}}))
            .await;
        client
    }

    async fn send(&mut self, m: &str, params: Value) -> i64 {
        let id = self.next;
        self.next += 1;
        self.tx.send(Message::request(id, m, params).to_line()).await.unwrap();
        id
    }

    async fn call(&mut self, m: &str, params: Value) -> Value {
        let id = self.send(m, params).await;
        loop {
            let v = self.line().await;
            if v.get("id") == Some(&json!(id)) {
                assert!(v.get("error").is_none(), "{m}: {v}");
                return v["result"].clone();
            }
        }
    }

    async fn line(&mut self) -> Value {
        let line =
            tokio::time::timeout(Duration::from_secs(20), self.rx.recv()).await.unwrap().unwrap();
        serde_json::from_str(&line).unwrap()
    }

    /// The first `activity` change of `key` that `wanted` accepts.
    async fn activity(&mut self, key: &str, wanted: impl Fn(&Value) -> bool) -> Value {
        loop {
            let v = self.line().await;
            let params = &v["params"];
            if v["method"] == "_acpmux/chat_changed"
                && params["kind"] == "activity"
                && params["key"] == key
                && wanted(params)
            {
                return params.clone();
            }
        }
    }
}

fn chat<'a>(page: &'a Value, key: &str) -> &'a Value {
    page["chats"].as_array().unwrap().iter().find(|c| c["key"] == key).unwrap_or(&Value::Null)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_chat_carries_its_live_sessions_attention_and_latest_reply() {
    let h = home();
    let project = mkdir(&h.0.join("work/api"));
    let codex = mkdir(&h.0.join("codex-alt"));
    write_rollout(&codex, &project);
    let mut cfg: Config = serde_json::from_value(json!({"harnesses": {"fakecodex": {
        "argv": ["python3", FAKE], "family": "codex", "env": {"CODEX_HOME": codex}}}}))
    .unwrap();
    cfg.default_harness = Some("fakecodex".into());
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    hub.set_harness_homes(HarnessHomes { claude: h.0.join(".claude"), codex: h.0.join(".codex") });
    let mut sources = ChatSources {
        home: h.0.clone(),
        acpmux_home: h.0.join(".acpmux"),
        env: Arc::new(|_| None),
        launch_roots: Vec::new(),
        user_roots: Vec::new(),
    };
    sources.launch_roots = acpmux::chats::launch_roots(&*hub.config.read().await);
    hub.start_chats(sources).await.unwrap();
    let key = format!("codex:{CODEX_ID}");

    // The sidebar's connection watches chats; it never attaches to the session.
    let mut watcher = Client::new(&hub).await;
    let page = watcher.call("_acpmux/chats_watch", json!({"enabled": true})).await;
    assert!(chat(&page, &key).is_object(), "{page}");
    assert!(chat(&page, &key)["attention"].is_null(), "no live session yet: {page}");

    // Another client continues the chat in acpmux.
    let mut pane = Client::new(&hub).await;
    let plan = pane.call("_acpmux/chat_open", json!({"key": key})).await;
    let session = pane.call(method::SESSION_NEW, plan["sessionNew"].clone()).await;
    let sid = session["sessionId"].as_str().unwrap().to_owned();
    let prompt = |text: &str| json!({"sessionId": sid, "prompt": [{"type": "text", "text": text}]});

    pane.call(method::SESSION_PROMPT, prompt("hello there")).await;
    let done = watcher
        .activity(&key, |p| p["preview"].as_str().is_some_and(|t| t.contains("hello there")))
        .await;
    assert!(done["attention"].is_null(), "the watching pane read the reply: {done}");

    // The turn fails (the prompt answers with an error).
    pane.send(method::SESSION_PROMPT, prompt("fail-streamed: boom")).await;
    watcher.activity(&key, |p| p["attention"] == "failed").await;

    // The agent asks for a permission; the turn waits for the person.
    pane.send(method::SESSION_PROMPT, prompt("ask: rm -rf build")).await;
    watcher.activity(&key, |p| p["attention"] == "needsInput").await;

    let page = watcher.call("_acpmux/chats", json!({})).await;
    assert_eq!(chat(&page, &key)["attention"], "needsInput", "{page}");
}
