//! A window recomputes for an activity change of a chat it shows, and for the changes no row of
//! it names: a session that moved to another chat (the chat it left changes too), and a session
//! whose tag expires (a lapsed `archived` folds its children again), and a chat past the page
//! whose fold decides `hasMore` (review of the window skip).

use crate::chats::ChatSources;
use crate::config::{Config, StoreMode};
use crate::hub::{Hub, Session};
use crate::rpc::{Message, method};
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

fn session_id(i: usize) -> String {
    format!("00000000-0000-4000-8000-{i:012}")
}

fn chat(i: usize) -> String {
    format!("claude-code:{}", session_id(i))
}

struct Setup {
    _home: tempfile::TempDir,
    hub: Arc<Hub>,
    input: mpsc::Sender<String>,
    out: mpsc::Receiver<String>,
}

/// Three chats in a temp home, chat 2 newest, the chat index started, and one connection.
async fn setup() -> Setup {
    let home = tempfile::tempdir().unwrap();
    let home_path = std::fs::canonicalize(home.path()).unwrap();
    let projects = home_path.join(".claude/projects/-work");
    std::fs::create_dir_all(&projects).unwrap();
    for i in 0..3 {
        let line = json!({"type": "user", "isSidechain": false, "cwd": "/work",
            "sessionId": session_id(i), "timestamp": format!("2026-10-01T01:00:0{i}.000Z"),
            "message": {"role": "user", "content": format!("chat {i}")}});
        let file = projects.join(format!("{}.jsonl", session_id(i)));
        std::fs::write(&file, format!("{line}\n")).unwrap();
        // A Claude chat's order is its file's mtime: files written in one millisecond would tie.
        let at = std::time::UNIX_EPOCH + Duration::from_secs(1_790_000_000 + i as u64);
        std::fs::File::options().write(true).open(&file).unwrap().set_modified(at).unwrap();
    }
    let mut config = Config::default();
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(config, store);
    hub.start_chats(ChatSources {
        home: home_path.clone(),
        acpmux_home: home_path.join(".acpmux"),
        env: Arc::new(|_: &str| None),
        launch_roots: Vec::new(),
        user_roots: Vec::new(),
    })
    .await
    .unwrap();
    let (input, incoming) = mpsc::channel(8);
    let (output, out) = mpsc::channel(4096);
    tokio::spawn(super::serve_connection_with(hub.clone(), incoming, output, super::Origin::Local));
    let hello =
        json!({"protocolVersion": 1, "clientInfo": {"name": "window-test", "version": "0"}});
    input.send(Message::request(1, method::INITIALIZE, hello).to_line()).await.unwrap();
    Setup { _home: home, hub, input, out }
}

fn session(hub: &Hub, id: &str, chat: usize, unread: bool) -> Arc<Session> {
    let meta: crate::store::SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": id, "name": id, "harness": "claude",
        "family": "claude", "agentSessionId": session_id(chat), "cwd": "/work", "status": "idle",
        "createdAt": 1, "updatedAt": 1, "unread": unread,
    }))
    .unwrap();
    hub.insert_test_session(meta)
}

async fn next_window(out: &mut mpsc::Receiver<String>) -> Value {
    tokio::time::timeout(Duration::from_secs(30), async {
        loop {
            let v: Value = serde_json::from_str(&out.recv().await.unwrap()).unwrap();
            if v["method"] == "_acpmux/chats_window_changed" {
                return v["params"].clone();
            }
        }
    })
    .await
    .expect("a window message within 30 s")
}

fn attention_of(message: &Value, key: &str) -> Option<Value> {
    message["rows"].as_array()?.iter().find(|r| r["key"] == key).map(|r| r["attention"].clone())
}

fn keys(message: &Value) -> Vec<String> {
    message["keys"].as_array().unwrap().iter().map(|k| k.as_str().unwrap().to_owned()).collect()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_session_that_moves_to_another_chat_clears_the_chat_it_left() {
    let Setup { _home, hub, input, mut out } = setup().await;
    let session = session(&hub, "s-a", 0, true);
    let open = json!({"window": "w", "limit": 10});
    input.send(Message::request(2, "_acpmux/chats_window", open).to_line()).await.unwrap();
    let full = next_window(&mut out).await;
    assert_eq!(attention_of(&full, &chat(0)), Some(json!("unread")), "{full}");

    // An activity record that changes nothing the window shows: no message.
    hub.append(&session, "mux", "status", json!({"status": "idle"}));
    // Its recompute reads the session before it moves (a later one would show the move anyway).
    tokio::time::sleep(Duration::from_millis(300)).await;

    // The session starts on another agent session, one no chat of the window is: the chat it
    // left has no session now, and its row says so.
    hub.edit_test_meta(&session, |m| m.agent_session_id = Some(session_id(9)));
    hub.append(&session, "mux", "status", json!({"status": "idle"}));
    let diff = next_window(&mut out).await;
    assert_eq!(attention_of(&diff, &chat(0)), Some(Value::Null), "{diff}");
    drop(input);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_parents_archive_that_lapses_folds_its_child_on_the_next_record_of_any_chat() {
    let Setup { _home, hub, input, mut out } = setup().await;
    let parent = session(&hub, "s-parent", 1, false);
    let child = session(&hub, "s-child", 0, false);
    let other = session(&hub, "s-other", 9, false);
    let soon = crate::store::now_ms() + 400;
    hub.edit_test_meta(&parent, |m| {
        let tag = crate::store::Tag { value: "true".into(), expires_at: Some(soon) };
        m.tags.insert("archived".into(), tag);
    });
    hub.edit_test_meta(&child, |m| {
        let tag = crate::store::Tag { value: "s-parent".into(), expires_at: None };
        m.tags.insert("spawnedBy".into(), tag);
    });
    // The parent's own chat is open elsewhere: the window names neither it nor, while it is
    // archived, it as anyone's parent.
    let open = json!({"window": "w", "limit": 10, "topLevel": true, "exclude": [chat(1)]});
    input.send(Message::request(2, "_acpmux/chats_window", open).to_line()).await.unwrap();
    let full = next_window(&mut out).await;
    assert!(keys(&full).contains(&chat(0)), "an archived parent's child is listed: {full}");

    // Every session was heard of once (a first record recomputes): then the archive lapses, and
    // a record of a chat no window shows comes.
    for s in [&parent, &child, &other] {
        hub.append(s, "mux", "status", json!({"status": "idle"}));
    }
    tokio::time::sleep(Duration::from_millis(600)).await;
    hub.append(&other, "mux", "status", json!({"status": "idle"}));
    let diff = next_window(&mut out).await;
    assert!(!keys(&diff).contains(&chat(0)), "the child folds under its parent again: {diff}");
    drop(input);
}

/// The next window message whose `hasMore` is `more` (one record's recompute may come later).
async fn has_more_becomes(out: &mut mpsc::Receiver<String>, more: bool) -> Value {
    loop {
        let message = next_window(out).await;
        if message["hasMore"] == more {
            return message;
        }
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_chat_past_the_page_that_folds_or_unfolds_moves_has_more() {
    let Setup { _home, hub, input, mut out } = setup().await;
    // Chat 1 has two sessions: a child of chat 0's session, and one of its own. The newest of
    // them (each record makes it so) decides whether chat 1 folds; the child is, at first.
    let parent = session(&hub, "s-parent", 0, false);
    let child = session(&hub, "s-child", 1, false);
    let own = session(&hub, "s-own", 1, false);
    hub.edit_test_meta(&child, |m| {
        let tag = crate::store::Tag { value: "s-parent".into(), expires_at: None };
        m.tags.insert("spawnedBy".into(), tag);
        m.updated_at = 2;
    });
    // One row: chat 2. Chat 1 comes after it, folded; chat 0 is open elsewhere.
    let open = json!({"window": "w", "limit": 1, "topLevel": true, "exclude": [chat(0)]});
    input.send(Message::request(2, "_acpmux/chats_window", open).to_line()).await.unwrap();
    let full = next_window(&mut out).await;
    assert_eq!(keys(&full), vec![chat(2)], "{full}");
    assert_eq!(full["hasMore"], false, "{full}");

    // A record of each session (a first one recomputes); the child stays newest.
    hub.append(&parent, "mux", "status", json!({"status": "idle"}));
    hub.append(&child, "mux", "status", json!({"status": "idle"}));
    tokio::time::sleep(Duration::from_millis(300)).await;
    hub.append(&own, "mux", "status", json!({"status": "idle"}));
    has_more_becomes(&mut out, true).await;

    // Every session is known now. The first chat past the page folds: nothing more to show.
    tokio::time::sleep(Duration::from_millis(20)).await;
    hub.append(&child, "mux", "status", json!({"status": "idle"}));
    has_more_becomes(&mut out, false).await;
    // And chat 1, folded past the page, unfolds: more again.
    tokio::time::sleep(Duration::from_millis(20)).await;
    hub.append(&own, "mux", "status", json!({"status": "idle"}));
    let diff = has_more_becomes(&mut out, true).await;
    assert_eq!(keys(&diff), vec![chat(2)], "{diff}");
    drop(input);
}

/// The next window message whose `total` is `total`.
async fn total_becomes(out: &mut mpsc::Receiver<String>, total: u64) -> Value {
    loop {
        let message = next_window(out).await;
        if message["total"] == total {
            return message;
        }
    }
}

fn recomputes(window: &str) -> usize {
    super::chat_windows::RECOMPUTES.lock().unwrap().get(window).copied().unwrap_or(0)
}

/// A `topLevel` window that ranks a query and counts its total reads every chat's fold, but a
/// record moves its result only when it folds or unfolds the chat it names, or that chat is shown.
/// A record of any other chat recomputed the window: a ranked recompute reads every chat (150 ms
/// per keystroke at 2,000 chats), once per status, turn and permission record of any session.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_ranked_top_level_window_recomputes_only_when_a_chats_fold_moves() {
    const WINDOW: &str = "w-ranked-fold";
    let Setup { _home, hub, input, mut out } = setup().await;
    // Chat 1 has two sessions: a child of chat 0's session, and one of its own. The newest of
    // them (each record makes it so) decides whether chat 1 folds.
    let parent = session(&hub, "s-parent", 0, false);
    let child = session(&hub, "s-child", 1, false);
    let own = session(&hub, "s-own", 1, false);
    let two = session(&hub, "s-two", 2, false);
    hub.edit_test_meta(&child, |m| {
        let tag = crate::store::Tag { value: "s-parent".into(), expires_at: None };
        m.tags.insert("spawnedBy".into(), tag);
        m.updated_at = 2;
    });
    let open = json!({"window": WINDOW, "limit": 1, "topLevel": true, "query": "chat",
        "count": true});
    input.send(Message::request(2, "_acpmux/chats_window", open).to_line()).await.unwrap();
    let full = next_window(&mut out).await;
    assert_eq!(full["total"], 2, "chat 1 folds: {full}");
    let shown = keys(&full);
    // The chat of 0 and 2 the window does not show, and its session.
    let unshown = if shown.contains(&chat(0)) { &two } else { &parent };

    // A first record of each session recomputes (what chat it continues is learned); the child's
    // last, so it is newest and chat 1 stays folded.
    for s in [&parent, &two, &own, &child] {
        tokio::time::sleep(Duration::from_millis(20)).await;
        hub.append(s, "mux", "status", json!({"status": "idle"}));
    }
    tokio::time::sleep(Duration::from_millis(300)).await;
    // What those recomputes sent: the totals below are read from later messages only.
    while out.try_recv().is_ok() {}
    let before = recomputes(WINDOW);

    // Records of a chat the window does not show and whose fold stays: no recompute.
    for _ in 0..3 {
        tokio::time::sleep(Duration::from_millis(20)).await;
        hub.append(unshown, "mux", "status", json!({"status": "idle"}));
        hub.append(&child, "mux", "status", json!({"status": "idle"}));
    }
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(recomputes(WINDOW) - before, 0, "records that move nothing recomputed the window");

    // Chat 1 unfolds (its own session is newest): the total counts it.
    tokio::time::sleep(Duration::from_millis(20)).await;
    hub.append(&own, "mux", "status", json!({"status": "idle"}));
    total_becomes(&mut out, 3).await;
    // And folds again.
    tokio::time::sleep(Duration::from_millis(20)).await;
    hub.append(&child, "mux", "status", json!({"status": "idle"}));
    total_becomes(&mut out, 2).await;
    drop(input);
}
