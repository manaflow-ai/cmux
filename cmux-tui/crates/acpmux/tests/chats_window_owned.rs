//! R6 for `_acpmux/chats_window` (lead 2026-10-30): a connection's window task is owned. It ends
//! when the client closes its last window and when the connection closes, so no task outlives
//! what it serves. Its own test binary: the task count is process-wide.

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process starts no agent.
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use acpmux::chats::ChatSources;
use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::Message;
use acpmux::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use std::collections::VecDeque;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

/// The chats of folder `/work/p<i % FOLDERS>`.
const FOLDERS: usize = 50;

struct Home(PathBuf);

impl Drop for Home {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn session_id(i: usize) -> String {
    format!("00000000-0000-4000-8000-{i:012}")
}

fn record(i: usize, seconds: usize, text: &str) -> Value {
    let (h, m, s) = (seconds / 3600, seconds / 60 % 60, seconds % 60);
    json!({"type":"user","isSidechain":false,"cwd":format!("/work/p{}", i % FOLDERS),"sessionId":session_id(i),
           "timestamp":format!("2026-10-01T{h:02}:{m:02}:{s:02}.000Z"),
           "message":{"role":"user","content":text}})
}

fn session_file(projects: &Path, i: usize) -> PathBuf {
    projects.join(format!("-work-p{}", i % FOLDERS)).join(format!("{}.jsonl", session_id(i)))
}

fn hub() -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", "-c", "pass"]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

/// The connection, the last request id, and the notifications read while waiting for an answer
/// (a window's rows are queued before the answer to its open).
struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64, VecDeque<Value>);

impl Client {
    async fn next(&mut self) -> Value {
        if let Some(v) = self.3.pop_front() {
            return v;
        }
        let line = tokio::time::timeout(Duration::from_secs(30), self.1.recv())
            .await
            .expect("a message within 30 s")
            .expect("connection open");
        serde_json::from_str(&line).unwrap()
    }

    async fn ok(&mut self, m: &str, params: Value) -> Value {
        self.2 += 1;
        let id = self.2;
        self.0.send(Message::request(id, m, params).to_line()).await.unwrap();
        let mut held = VecDeque::new();
        loop {
            let v = self.next().await;
            if v.get("id") == Some(&json!(id)) {
                assert!(v.get("error").is_none(), "{m}: {v}");
                held.extend(self.3.drain(..));
                self.3 = held;
                return v["result"].clone();
            }
            held.push_back(v);
        }
    }

    /// The next `_acpmux/chats_window_changed`.
    async fn next_window(&mut self) -> Value {
        loop {
            let v = self.next().await;
            if v["method"] == "_acpmux/chats_window_changed" {
                return v["params"].clone();
            }
        }
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_window_task_ends_with_its_last_window_and_with_its_connection() {
    const N: usize = 10;
    let base = PathBuf::from("/tmp").join(format!("acpmux-window-owned-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&base).unwrap();
    let home = Home(std::fs::canonicalize(&base).unwrap());
    let projects = home.0.join(".claude/projects");
    for i in 0..N {
        let file = session_file(&projects, i);
        std::fs::create_dir_all(file.parent().unwrap()).unwrap();
        std::fs::write(&file, format!("{}\n", record(i, i, &format!("chat {i}")))).unwrap();
    }
    let hub = hub();
    hub.start_chats(ChatSources {
        home: home.0.clone(),
        acpmux_home: home.0.join(".acpmux"),
        env: Arc::new(|_: &str| None),
        launch_roots: Vec::new(),
        user_roots: Vec::new(),
    })
    .await
    .unwrap();
    assert_eq!(acpmux::server::live_chat_window_tasks(), 0);
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
    let mut c = Client(in_tx, out_rx, 0, VecDeque::new());

    // Two windows, one task; the task lives until the last one closes.
    for window in ["a", "b"] {
        c.ok("_acpmux/chats_window", json!({"window": window, "limit": 3})).await;
        assert_eq!(c.next_window().await["window"], window);
    }
    assert_eq!(acpmux::server::live_chat_window_tasks(), 1, "one task per connection");
    c.ok("_acpmux/chats_window_close", json!({"window": "a"})).await;
    assert_eq!(acpmux::server::live_chat_window_tasks(), 1, "window b is still open");
    c.ok("_acpmux/chats_window_close", json!({"window": "b"})).await;
    tasks_reach_zero("the last window closed").await;

    // A later open starts a new task; closing the connection ends it.
    c.ok("_acpmux/chats_window", json!({"window": "a", "limit": 3})).await;
    assert_eq!(c.next_window().await["full"], true, "a reopened window sends every row");
    assert_eq!(acpmux::server::live_chat_window_tasks(), 1);
    drop(c);
    tasks_reach_zero("the connection closed").await;
}

/// Waits (bounded) for the task count to reach 0: the task ends on its own executor turn.
async fn tasks_reach_zero(after: &str) {
    let ended = tokio::time::timeout(Duration::from_secs(10), async {
        while acpmux::server::live_chat_window_tasks() != 0 {
            tokio::task::yield_now().await;
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await;
    assert!(ended.is_ok(), "a chat window task outlived {after}");
}
