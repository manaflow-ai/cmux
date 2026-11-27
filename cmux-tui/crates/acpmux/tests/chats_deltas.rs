//! cx-9c8m.6: with a real-size chat list (5000 chats), acpmux owns the order
//! and each chat's brand, and a watcher gets one numbered delta per change,
//! never the list again. Every store is a synthetic fixture in a temp home.

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
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const CHATS: usize = 5000;

struct Home(PathBuf);

impl Drop for Home {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn session_id(i: usize) -> String {
    format!("00000000-0000-4000-8000-{i:012}")
}

/// Session `i` was last used `i` seconds after the base time: the newest is the last.
fn record(i: usize, seconds: usize, text: &str) -> Value {
    let (h, m, s) = (seconds / 3600, seconds / 60 % 60, seconds % 60);
    json!({"type":"user","isSidechain":false,"cwd":format!("/work/p{}", i % 50),"sessionId":session_id(i),
           "timestamp":format!("2026-10-01T{h:02}:{m:02}:{s:02}.000Z"),
           "message":{"role":"user","content":text}})
}

fn session_file(projects: &Path, i: usize) -> PathBuf {
    projects.join(format!("-work-p{}", i % 50)).join(format!("{}.jsonl", session_id(i)))
}

fn append(file: &Path, record: &Value) {
    use std::io::Write;
    let mut f = std::fs::OpenOptions::new().append(true).open(file).unwrap();
    writeln!(f, "{record}").unwrap();
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

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

impl Client {
    async fn next(&mut self) -> Value {
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
        loop {
            let v = self.next().await;
            if v.get("id") == Some(&json!(id)) {
                assert!(v.get("error").is_none(), "{m}: {v}");
                return v["result"].clone();
            }
        }
    }

    /// The next `_acpmux/chat_changed`, whatever its chat.
    async fn next_change(&mut self) -> Value {
        loop {
            let v = self.next().await;
            if v["method"] == "_acpmux/chat_changed" {
                return v["params"].clone();
            }
        }
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn five_thousand_chats_one_change_is_one_numbered_delta() {
    // Under /tmp, not the temp dir: a worker's temp dir may be on another volume (`/Volumes`),
    // where no chat root is ever listed.
    let base = PathBuf::from("/tmp").join(format!("acpmux-deltas-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&base).unwrap();
    let home = Home(std::fs::canonicalize(&base).unwrap());
    let projects = home.0.join(".claude/projects");
    for i in 0..CHATS {
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
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
    let mut c = Client(in_tx, out_rx, 0);

    // The page: every chat, newest first, each with its brand, and the seq it holds.
    let page = c.ok("_acpmux/chats_watch", json!({"limit": CHATS})).await;
    let chats = page["chats"].as_array().unwrap();
    assert_eq!(chats.len(), CHATS);
    let mut keys: Vec<&str> = chats.iter().map(|chat| chat["key"].as_str().unwrap()).collect();
    // acpmux's order: newest `updatedMs` first, then the key ascending.
    let order = |chat: &Value| {
        (-chat["updatedMs"].as_i64().unwrap(), chat["key"].as_str().unwrap().to_owned())
    };
    let sorted = chats.windows(2).all(|pair| order(&pair[0]) < order(&pair[1]));
    assert!(sorted, "acpmux sends the list sorted");
    let head = keys[0].to_owned();
    keys.sort_unstable();
    let mut expected: Vec<String> =
        (0..CHATS).map(|i| format!("claude-code:{}", session_id(i))).collect();
    expected.sort_unstable();
    assert_eq!(keys, expected, "every chat is in the page once");
    assert!(chats.iter().all(|chat| chat["brand"] == "claude"), "every chat names its brand");
    let seq = page["seq"].as_u64().expect("the page names its seq");

    // One file change: one delta with the next seq, the chat alone (never the list).
    let touched = 10;
    append(&session_file(&projects, touched), &record(touched, CHATS + 1, "a new prompt"));
    let delta = c.next_change().await;
    assert_eq!(delta["kind"], "upsert", "{delta}");
    assert_eq!(delta["key"], format!("claude-code:{}", session_id(touched)), "{delta}");
    assert_eq!(delta["seq"], seq + 1, "{delta}");
    assert_eq!(delta["chat"]["brand"], "claude", "{delta}");

    // The next change is the next delta: nothing came between the two.
    let second = 20;
    append(&session_file(&projects, second), &record(second, CHATS + 2, "another prompt"));
    let delta = c.next_change().await;
    assert_eq!(delta["key"], format!("claude-code:{}", session_id(second)), "{delta}");
    assert_eq!(delta["seq"], seq + 2, "{delta}");

    // A new page holds both changes (its seq) and the order acpmux keeps.
    let again = c.ok("_acpmux/chats", json!({"limit": 3})).await;
    assert_eq!(again["seq"], seq + 2, "{again}");
    let newest: Vec<&str> =
        again["chats"].as_array().unwrap().iter().map(|c| c["key"].as_str().unwrap()).collect();
    assert_eq!(
        newest,
        vec![
            format!("claude-code:{}", session_id(second)),
            format!("claude-code:{}", session_id(touched)),
            head,
        ]
    );
}

/// All Chats pages the list as the reader scrolls, while chats keep changing under it: a chat that
/// moves to the top or leaves must not make the next page repeat a chat or skip one. The cursor
/// names the last chat a page held, not how many came before it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_page_cursor_holds_its_place_while_chats_move() {
    const N: usize = 30;
    let base = PathBuf::from("/tmp").join(format!("acpmux-keyset-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&base).unwrap();
    let home = Home(std::fs::canonicalize(&base).unwrap());
    let projects = home.0.join(".claude/projects");
    for i in 0..N {
        let file = session_file(&projects, i);
        std::fs::create_dir_all(file.parent().unwrap()).unwrap();
        std::fs::write(&file, format!("{}\n", record(i, i, &format!("chat {i}")))).unwrap();
        // A Claude chat's time is its file's: one second apart, a day ago, so the order is known
        // and a later write puts its chat on top.
        let day_ago = std::time::SystemTime::now() - Duration::from_secs(86_400);
        let at = day_ago + Duration::from_secs(i as u64);
        std::fs::File::options().write(true).open(&file).unwrap().set_modified(at).unwrap();
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
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
    let mut c = Client(in_tx, out_rx, 0);
    let key = |i: usize| format!("claude-code:{}", session_id(i));
    let keys = |page: &Value| -> Vec<String> {
        page["chats"]
            .as_array()
            .unwrap()
            .iter()
            .map(|c| c["key"].as_str().unwrap().to_owned())
            .collect()
    };

    // Newest first: chats 29 to 20.
    let first = c.ok("_acpmux/chats_watch", json!({"limit": 10})).await;
    assert_eq!(keys(&first), (20..N).rev().map(key).collect::<Vec<_>>());
    let cursor = first["nextCursor"].as_str().expect("more chats").to_owned();
    assert!(cursor.len() <= 32, "the host passes a cursor of at most 32 characters: {cursor}");

    // Chat 5 moves to the top, and chats 25 and 24 (on the page the reader holds) leave: the chats
    // after the page shift up by one, so an offset would skip chat 19.
    append(&session_file(&projects, 5), &record(5, N + 1, "a new prompt"));
    assert_eq!(c.next_change().await["key"], key(5));
    for gone in [25, 24] {
        std::fs::remove_file(session_file(&projects, gone)).unwrap();
        assert_eq!(c.next_change().await["key"], key(gone));
    }

    // The next page is still the ten chats after 20, and the one after it the rest but chat 5.
    let second = c.ok("_acpmux/chats", json!({"limit": 10, "cursor": cursor})).await;
    assert_eq!(keys(&second), (10..20).rev().map(key).collect::<Vec<_>>());
    let cursor = second["nextCursor"].as_str().expect("more chats").to_owned();
    let third = c.ok("_acpmux/chats", json!({"limit": 10, "cursor": cursor})).await;
    assert_eq!(keys(&third), (0..10).rev().filter(|&i| i != 5).map(key).collect::<Vec<_>>());
    assert!(third["nextCursor"].is_null(), "{third}");
}
