//! Search chats by what was said (HQ#5333): `_acpmux/chats_search {query}` finds a chat by a word
//! from any prompt or answer in its harness's store, not only its title and folder, and answers
//! with the message and a snippet around the words. Local socket only. Synthetic temp homes only.

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process starts no agent.
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

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

const CLAUDE_ID: &str = "5b6c7d8e-9f0a-4b1c-8d2e-3f4a5b6c7d8e";
const CODEX_ID: &str = "0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5c";
const DROID_ID: &str = "4f1c2a3b-5d6e-4f70-8a9b-0c1d2e3f4a5b";

struct Home(PathBuf);

impl Drop for Home {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn home() -> Home {
    // Under /tmp, not the temp dir: a worker's temp dir may be on another volume (`/Volumes`),
    // where no chat root is ever listed.
    let base = PathBuf::from("/tmp").join(format!("acpmux-search-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&base).expect("home");
    Home(std::fs::canonicalize(&base).expect("canonical home"))
}

fn write(path: &Path, text: &str) {
    std::fs::create_dir_all(path.parent().expect("parent")).expect("dirs");
    std::fs::write(path, text).expect("write");
}

fn lines(lines: &[Value]) -> String {
    lines.iter().map(|line| format!("{line}\n")).collect()
}

/// A Claude Code chat titled by its first prompt; the word searched for is in a later answer.
fn claude(h: &Path, project: &Path) {
    let line = |kind: &str, content: Value, at: &str| {
        json!({"type": kind, "isSidechain": false, "cwd": project, "sessionId": CLAUDE_ID,
               "timestamp": at, "message": {"role": kind, "content": content}})
    };
    let long = "word ".repeat(200);
    let text = lines(&[
        line("user", json!("Fix the sidebar test"), "2026-10-02T09:00:00.000Z"),
        line(
            "assistant",
            json!([{"type": "text", "text": "Looking."}]),
            "2026-10-02T09:00:02.000Z",
        ),
        line("user", json!("Why does it fail?"), "2026-10-02T09:01:00.000Z"),
        line(
            "assistant",
            json!([{"type": "text", "text": format!("{long}It panics in SidebarRowLayout when the row height is NaN. {long}")}]),
            "2026-10-02T09:01:05.000Z",
        ),
    ]);
    write(&h.join(format!(".claude/projects/-work-api/{CLAUDE_ID}.jsonl")), &text);
}

fn codex(h: &Path, project: &Path) {
    let text = lines(&[
        json!({"type": "session_meta", "payload": {"id": CODEX_ID, "cwd": project, "timestamp": "2026-10-02T10:00:00Z"}}),
        json!({"type": "event_msg", "timestamp": "2026-10-02T10:00:01Z", "payload": {"type": "user_message", "message": "Bump the version"}}),
        json!({"type": "event_msg", "timestamp": "2026-10-02T10:00:03Z", "payload": {"type": "agent_message", "message": "Bumped to 1.2 in Cargo.toml."}}),
    ]);
    let name = format!("sessions/2026/10/02/rollout-2026-10-02T10-00-00-{CODEX_ID}.jsonl");
    write(&h.join(".codex").join(name), &text);
}

/// A Droid chat: a tool result names the word too, which is not the conversation.
fn droid(h: &Path, project: &Path) {
    let text = lines(&[
        json!({"type": "session_start", "id": DROID_ID, "title": "Droid chat", "cwd": project}),
        json!({"type": "message", "timestamp": "2026-10-02T11:00:01Z", "message": {"role": "user", "content": [{"type": "text", "text": "List the files"}]}}),
        json!({"type": "message", "timestamp": "2026-10-02T11:00:05Z", "message": {"role": "assistant", "content": [{"type": "text", "text": "Listing."}, {"type": "tool_use", "id": "t1", "name": "Bash", "input": {}}]}}),
        json!({"type": "message", "timestamp": "2026-10-02T11:00:06Z", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "t1", "content": "Cargo.toml SidebarRowLayout.swift"}]}}),
        json!({"type": "message", "timestamp": "2026-10-02T11:00:09Z", "message": {"role": "assistant", "content": [{"type": "text", "text": "Two files."}]}}),
    ]);
    write(&h.join(format!(".factory/sessions/-work-api/{DROID_ID}.jsonl")), &text);
}

async fn hub_on(h: &Path) -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({"harnesses": {}})).expect("config");
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).expect("store");
    let hub = Hub::new(cfg, store);
    let sources = ChatSources {
        home: h.to_path_buf(),
        acpmux_home: h.join(".acpmux"),
        env: Arc::new(|_| None),
        launch_roots: Vec::new(),
        user_roots: Vec::new(),
    };
    hub.start_chats(sources).await.expect("chat index");
    hub
}

async fn connect(hub: &Arc<Hub>, origin: Origin) -> (mpsc::Sender<String>, mpsc::Receiver<String>) {
    let (tx, in_rx) = mpsc::channel(64);
    let (out_tx, rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, origin));
    let mut rx = rx;
    let hello = json!({"protocolVersion": 1, "clientInfo": {"name": "t"}});
    call(&tx, &mut rx, 1, method::INITIALIZE, hello).await;
    (tx, rx)
}

async fn call(
    tx: &mpsc::Sender<String>,
    rx: &mut mpsc::Receiver<String>,
    id: i64,
    m: &str,
    params: Value,
) -> Value {
    tx.send(Message::request(id, m, params).to_line()).await.expect("send");
    loop {
        let line = tokio::time::timeout(Duration::from_secs(20), rx.recv())
            .await
            .expect("answer in time")
            .expect("connection open");
        let v: Value = serde_json::from_str(&line).expect("json");
        if v.get("id") == Some(&json!(id)) {
            return v;
        }
    }
}

fn keys(answer: &Value) -> Vec<String> {
    let hits = answer["result"]["hits"].as_array().unwrap_or_else(|| panic!("{answer}"));
    hits.iter().map(|hit| hit["chat"]["key"].as_str().unwrap_or("").to_owned()).collect()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_chat_is_found_by_a_word_from_its_conversation_on_the_local_socket_only() {
    let h = home();
    let project = h.0.join("work/api");
    std::fs::create_dir_all(&project).expect("project");
    claude(&h.0, &project);
    codex(&h.0, &project);
    droid(&h.0, &project);
    let hub = hub_on(&h.0).await;
    let (tx, mut rx) = connect(&hub, Origin::Local).await;
    let claude_key = format!("claude-code:{CLAUDE_ID}");
    let codex_key = format!("codex:{CODEX_ID}");

    // A word from a later answer (not the title, not the folder), in any case, finds the chat;
    // the tool result that names it too is not the conversation.
    let found =
        call(&tx, &mut rx, 2, "_acpmux/chats_search", json!({"query": "sidebarrowlayout"})).await;
    assert_eq!(keys(&found), [claude_key.as_str()], "{found}");
    let hit = &found["result"]["hits"][0];
    assert_eq!(hit["role"], "answer", "{hit}");
    assert_eq!(hit["turn"], 1, "{hit}");
    assert_eq!(hit["chat"]["harness"], "claude-code", "{hit}");
    // The snippet is the text around the words, cut short on both sides.
    let snippet = hit["snippet"].as_str().unwrap_or_else(|| panic!("{hit}"));
    assert!(snippet.contains("SidebarRowLayout when the row height is NaN"), "{snippet}");
    assert!(snippet.starts_with('…') && snippet.ends_with('…'), "{snippet}");
    assert!(snippet.chars().count() <= 200, "{snippet}");
    assert_eq!(found["result"]["partial"], false, "{found}");
    assert!(found["result"]["nextCursor"].is_null(), "{found}");

    // Every word, in any order, within one message; a prompt is found too.
    let both = call(&tx, &mut rx, 3, "_acpmux/chats_search", json!({"query": "NaN panics"})).await;
    assert_eq!(keys(&both), [claude_key.as_str()], "{both}");
    let split =
        call(&tx, &mut rx, 4, "_acpmux/chats_search", json!({"query": "panics version"})).await;
    assert_eq!(keys(&split), Vec::<String>::new(), "{split}");
    let prompt = call(&tx, &mut rx, 5, "_acpmux/chats_search", json!({"query": "version"})).await;
    assert_eq!(keys(&prompt), [codex_key.as_str()], "{prompt}");
    assert_eq!(prompt["result"]["hits"][0]["role"], "prompt", "{prompt}");
    // A word inside a word matches too; the newest message holding it is the hit.
    let newest = call(&tx, &mut rx, 11, "_acpmux/chats_search", json!({"query": "bump"})).await;
    assert_eq!(newest["result"]["hits"][0]["role"], "answer", "{newest}");
    assert_eq!(newest["result"]["hits"][0]["matches"], 2, "{newest}");

    // Newest chat first; `limit` cuts the page and the cursor goes on from it.
    let all = call(&tx, &mut rx, 6, "_acpmux/chats_search", json!({"query": "the"})).await;
    let page =
        call(&tx, &mut rx, 7, "_acpmux/chats_search", json!({"query": "the", "limit": 1})).await;
    assert_eq!(keys(&all).len(), 3, "{all}");
    assert_eq!(keys(&page), keys(&all)[..1], "{page}");
    let cursor = page["result"]["nextCursor"].as_str().unwrap_or_else(|| panic!("{page}"));
    let rest = call(
        &tx,
        &mut rx,
        8,
        "_acpmux/chats_search",
        json!({"query": "the", "limit": 5, "cursor": cursor}),
    )
    .await;
    assert_eq!(keys(&rest), keys(&all)[1..], "{rest}");

    // The filters of `_acpmux/chats` apply.
    let codex_only =
        call(&tx, &mut rx, 9, "_acpmux/chats_search", json!({"query": "the", "harness": "codex"}))
            .await;
    assert_eq!(keys(&codex_only), [codex_key.as_str()], "{codex_only}");

    // An empty query is refused: that is `_acpmux/chats`.
    let empty = call(&tx, &mut rx, 10, "_acpmux/chats_search", json!({"query": "  "})).await;
    assert_eq!(empty["error"]["code"], -32602, "{empty}");

    // What was said is user data: no WebSocket origin reads it.
    for (i, origin) in [Origin::Web, Origin::LocalApp, Origin::Peer].into_iter().enumerate() {
        let (tx, mut rx) = connect(&hub, origin).await;
        let id = 20 + i as i64;
        let refused =
            call(&tx, &mut rx, id, "_acpmux/chats_search", json!({"query": "bump"})).await;
        assert_eq!(refused["error"]["code"], -32601, "{origin:?}: {refused}");
    }
}
