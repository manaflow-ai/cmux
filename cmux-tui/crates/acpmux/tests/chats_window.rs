//! P-RUST item 2 (stall 2026-10-30): acpmux owns the chat list a client shows. A client asks for
//! its visible window (`_acpmux/chats_window`: filter, exclusions, limit) and gets the rows sorted
//! and filtered by acpmux; each index change then reaches it as a row diff with a revision: the
//! window's keys in order and only the rows whose value changed, never the index again. Every store
//! is a synthetic fixture in a temp home.

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

const CHATS: usize = 3000;
/// The chats of folder `/work/p<i % FOLDERS>`.
const FOLDERS: usize = 50;
const WINDOW: usize = 20;

struct Home(PathBuf);

impl Drop for Home {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn session_id(i: usize) -> String {
    format!("00000000-0000-4000-8000-{i:012}")
}

fn key(i: usize) -> String {
    format!("claude-code:{}", session_id(i))
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

fn keys(message: &Value) -> Vec<String> {
    message["keys"].as_array().unwrap().iter().map(|k| k.as_str().unwrap().to_owned()).collect()
}

fn row_keys(message: &Value) -> Vec<String> {
    message["rows"]
        .as_array()
        .unwrap()
        .iter()
        .map(|c| c["key"].as_str().unwrap().to_owned())
        .collect()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_window_over_three_thousand_chats_is_sorted_filtered_and_one_change_is_one_row() {
    // Under /tmp, not the temp dir: a worker's temp dir may be on another volume (`/Volumes`),
    // where no chat root is ever listed.
    let base = PathBuf::from("/tmp").join(format!("acpmux-window-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&base).unwrap();
    let home = Home(std::fs::canonicalize(&base).unwrap());
    let projects = home.0.join(".claude/projects");
    // A Claude chat's time is its file's: one second apart, a day ago, so the order is known and a
    // later write puts its chat on top.
    let day_ago = std::time::SystemTime::now() - Duration::from_secs(86_400);
    for i in 0..CHATS {
        let file = session_file(&projects, i);
        std::fs::create_dir_all(file.parent().unwrap()).unwrap();
        std::fs::write(&file, format!("{}\n", record(i, i, &format!("chat {i}")))).unwrap();
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
    let mut c = Client(in_tx, out_rx, 0, VecDeque::new());

    // Folder p7 holds 60 of the 3000 chats (7, 57, ..., 2957). The window: its newest 20 but the
    // one the client excludes (an open workspace shows it), newest first, sorted by acpmux.
    let folder: Vec<usize> = (0..CHATS).rev().filter(|i| i % FOLDERS == 7).collect();
    let excluded = folder[1];
    let ack = c
        .ok(
            "_acpmux/chats_window",
            json!({"window": "earlier", "folder": "/work/p7", "limit": WINDOW, "topLevel": true,
                   "exclude": [key(excluded)]}),
        )
        .await;
    assert_eq!(ack["window"], "earlier", "{ack}");
    let full = c.next_window().await;
    assert_eq!(full["window"], "earlier", "{full}");
    assert_eq!(full["full"], true, "{full}");
    let first_revision = full["revision"].as_u64().expect("a revision");
    let expected: Vec<String> =
        folder.iter().filter(|&&i| i != excluded).take(WINDOW).map(|&i| key(i)).collect();
    assert_eq!(keys(&full), expected, "sorted newest first, filtered, the excluded chat left out");
    assert_eq!(row_keys(&full), expected, "the open sends every row of the window, no more");
    assert_eq!(full["hasMore"], true, "{full}");
    assert!(full["rows"].as_array().unwrap().iter().all(|row| row["brand"] == "claude"));

    // One change in the window's folder: the oldest p7 chat moves to the top. The diff is the next
    // revision, the window's keys in order, and that one row alone.
    let moved = folder[folder.len() - 1];
    append(&session_file(&projects, moved), &record(moved, CHATS + 1, "a new prompt"));
    let diff = c.next_window().await;
    assert_eq!(diff["full"], false, "{diff}");
    assert_eq!(diff["revision"], first_revision + 1, "{diff}");
    let mut after = vec![key(moved)];
    after.extend(expected.iter().take(WINDOW - 1).cloned());
    assert_eq!(keys(&diff), after, "{diff}");
    assert_eq!(row_keys(&diff), vec![key(moved)], "only the changed row travels");

    // A change outside the window's filter sends nothing: the next message is the next p7 change,
    // one revision later.
    let other = 8;
    append(&session_file(&projects, other), &record(other, CHATS + 2, "another folder"));
    let next = folder[folder.len() - 2];
    append(&session_file(&projects, next), &record(next, CHATS + 3, "and another"));
    let diff = c.next_window().await;
    assert_eq!(
        diff["revision"],
        first_revision + 2,
        "a change outside the window sent a diff: {diff}"
    );
    assert_eq!(row_keys(&diff), vec![key(next)], "{diff}");
    assert_eq!(keys(&diff)[..2], [key(next), key(moved)], "{diff}");

    // Closing the window stops its diffs.
    c.ok("_acpmux/chats_window_close", json!({"window": "earlier"})).await;
}

/// acpmux groups its own index into each harness's project folders (`_acpmux/chat_projects`), so
/// the cmux daemon reads a few rows instead of walking every chat.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn chat_projects_are_each_folder_with_its_newest_chat() {
    const N: usize = 120;
    let base = PathBuf::from("/tmp").join(format!("acpmux-projects-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&base).unwrap();
    let home = Home(std::fs::canonicalize(&base).unwrap());
    let projects = home.0.join(".claude/projects");
    let day_ago = std::time::SystemTime::now() - Duration::from_secs(86_400);
    for i in 0..N {
        let file = session_file(&projects, i);
        std::fs::create_dir_all(file.parent().unwrap()).unwrap();
        std::fs::write(&file, format!("{}\n", record(i, i, &format!("chat {i}")))).unwrap();
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
    let mut c = Client(in_tx, out_rx, 0, VecDeque::new());

    let page = c.ok("_acpmux/chats", json!({"limit": N})).await;
    let newest_ms = |folder: usize| {
        page["chats"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|chat| chat["cwd"] == format!("/work/p{folder}"))
            .map(|chat| chat["updatedMs"].as_i64().unwrap())
            .max()
            .unwrap()
    };
    let result = c.ok("_acpmux/chat_projects", json!({})).await;
    assert_eq!(result["ready"], true, "{result}");
    assert_eq!(result["enabled"], true, "{result}");
    let rows = result["projects"].as_array().unwrap();
    assert_eq!(rows.len(), FOLDERS, "one row per folder: {result}");
    let mut paths: Vec<String> = (0..FOLDERS).map(|f| format!("/work/p{f}")).collect();
    paths.sort_unstable();
    let listed: Vec<&str> = rows.iter().map(|row| row["path"].as_str().unwrap()).collect();
    assert_eq!(listed, paths, "by harness, then path");
    for row in rows {
        assert_eq!(row["harness"], "claude-code", "{row}");
        let folder: usize = row["path"].as_str().unwrap()["/work/p".len()..].parse().unwrap();
        assert_eq!(row["lastUsedMs"].as_i64().unwrap(), newest_ms(folder), "{row}");
    }
}

/// Review F1 (#28055): the daemon runs each request as its own task, so two specs of one window sent
/// back to back may be applied in either order. The client names each spec with a generation
/// (`gen`); acpmux keeps the highest it saw, ignores an older spec or close, and echoes `gen` in
/// every message, so the window always ends on the last spec the client sent.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_last_spec_sent_wins_whatever_order_the_requests_run_in() {
    const N: usize = 40;
    let base = PathBuf::from("/tmp").join(format!("acpmux-window-gen-{}", uuid::Uuid::now_v7()));
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
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
    let mut c = Client(in_tx, out_rx, 0, VecDeque::new());

    // Many rounds: each sends specs gen 1..=5 (limit = gen) in one burst, then reads the answers.
    for round in 0..20u64 {
        let window = format!("w{round}");
        for g in 1..=5u64 {
            c.2 += 1;
            let params = json!({"window": window, "gen": g, "limit": g});
            c.0.send(Message::request(c.2, "_acpmux/chats_window", params).to_line())
                .await
                .unwrap();
        }
        let last_id = c.2;
        let mut last = None;
        loop {
            let v = c.next().await;
            if v["method"] == "_acpmux/chats_window_changed" && v["params"]["window"] == window {
                last = Some(v["params"].clone());
            }
            if v.get("id") == Some(&json!(last_id)) {
                break;
            }
        }
        // Answers may still be in flight after the last id: read until the gen-5 rows come.
        let mut last = last.unwrap_or(Value::Null);
        while last["gen"] != 5 {
            let v = c.next().await;
            if v["method"] == "_acpmux/chats_window_changed" && v["params"]["window"] == window {
                last = v["params"].clone();
            }
        }
        assert_eq!(last["full"], true, "round {round}: {last}");
        assert_eq!(
            last["keys"].as_array().unwrap().len(),
            5,
            "round {round}: the last spec (limit 5) wins: {last}"
        );
        // A close of an older generation is ignored; the window stays.
        c.ok("_acpmux/chats_window_close", json!({"window": window, "gen": 4})).await;
        let ack =
            c.ok("_acpmux/chats_window", json!({"window": window, "gen": 3, "limit": 1})).await;
        assert_eq!(ack["stale"], true, "round {round}: an older spec is refused as stale: {ack}");
        c.ok("_acpmux/chats_window_close", json!({"window": window, "gen": 6})).await;
    }
}

/// Review of #28090 (no regression): the palette's chats page found a chat by its harness and by
/// words anywhere in its title or folder, with the palette's ranker. A query window ranks the same
/// way, and says how many chats matched in all.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_query_window_ranks_like_the_palette_and_reports_how_many_matched() {
    const N: usize = 30;
    let base = PathBuf::from("/tmp").join(format!("acpmux-window-rank-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&base).unwrap();
    let home = Home(std::fs::canonicalize(&base).unwrap());
    let projects = home.0.join(".claude/projects");
    // Chat i's first prompt (its title) is "fix the flaky build i" for even i, "write docs i" else.
    for i in 0..N {
        let file = session_file(&projects, i);
        std::fs::create_dir_all(file.parent().unwrap()).unwrap();
        let text =
            if i % 2 == 0 { format!("fix the flaky build {i}") } else { format!("write docs {i}") };
        std::fs::write(&file, format!("{}\n", record(i, i, &text))).unwrap();
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
    let mut c = Client(in_tx, out_rx, 0, VecDeque::new());

    let spec = |window: &str, query: &str, limit: usize| json!({"window": window, "gen": 1, "query": query, "limit": limit});
    // The harness: no title or folder holds "claude", every chat is a claude-code chat.
    c.ok("_acpmux/chats_window", spec("harness", "claude", 5)).await;
    let full = c.next_window().await;
    assert_eq!(full["window"], "harness");
    assert_eq!(keys(&full).len(), 5, "the harness name finds its chats: {full}");
    assert_eq!(full["total"], N, "every chat matched: {full}");
    assert_eq!(full["hasMore"], true, "{full}");
    // Two words that are not next to each other: only the even chats hold both.
    c.ok("_acpmux/chats_window", spec("words", "fix build", 100)).await;
    let full = c.next_window().await;
    assert_eq!(full["window"], "words");
    assert_eq!(full["total"], N / 2, "the even chats: {full}");
    let index = |key: &String| key.rsplit('-').next().unwrap().parse::<usize>().unwrap();
    assert!(
        row_keys(&full).iter().all(|k| index(k) % 2 == 0),
        "only chats that hold both words: {full}"
    );
}

/// No regression (lead, review of #28090): the palette ranked a chat the person chose before above
/// one with the same match. The page sends its choice history (`history`: the palette ranker's
/// frecency for `chat:<key>` and its clock), and acpmux ranks with it. With no query the window
/// counts every chat it could show (`count`), so the page can say how many more there are.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_query_window_ranks_past_choices_first_and_a_counted_window_reports_its_total() {
    const N: usize = 30;
    let base =
        PathBuf::from("/tmp").join(format!("acpmux-window-history-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&base).unwrap();
    let home = Home(std::fs::canonicalize(&base).unwrap());
    let projects = home.0.join(".claude/projects");
    let day_ago = std::time::SystemTime::now() - Duration::from_secs(86_400);
    // Every chat's title is "fix the flaky build"; chat i was last used i seconds after a day ago.
    for i in 0..N {
        let file = session_file(&projects, i);
        std::fs::create_dir_all(file.parent().unwrap()).unwrap();
        std::fs::write(&file, format!("{}\n", record(i, i, "fix the flaky build"))).unwrap();
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
    let mut c = Client(in_tx, out_rx, 0, VecDeque::new());

    // The oldest chat was chosen often and lately: with an equal match it ranks first.
    let now = 1_000_000.0;
    let chosen = format!("chat:{}", key(0));
    let history = json!({"now": now, "frecency": {"entries": {chosen: {"score": 5.0, "lastUsed": now - 60.0}},
                                                  "halfLife": 259_200.0}});
    let params = json!({"window": "chosen", "gen": 1, "query": "fix build", "limit": 3,
                        "history": history.to_string()});
    c.ok("_acpmux/chats_window", params).await;
    let full = c.next_window().await;
    assert_eq!(keys(&full)[0], key(0), "the chat chosen before ranks first: {full}");
    assert_eq!(keys(&full)[1], key(N - 1), "then the newest: {full}");

    // No query: the newest chats, and how many chats the window could show in all.
    c.ok("_acpmux/chats_window", json!({"window": "newest", "gen": 1, "limit": 5, "count": true}))
        .await;
    let full = c.next_window().await;
    assert_eq!(keys(&full).len(), 5, "{full}");
    assert_eq!(keys(&full)[0], key(N - 1), "newest first: {full}");
    assert_eq!(full["total"], N, "a counted window reports its total: {full}");
}
