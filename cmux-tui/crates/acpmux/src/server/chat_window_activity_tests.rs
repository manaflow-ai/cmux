//! A window recomputes for an activity change of a chat it shows, and for the changes no row of
//! it names: a session that moved to another chat (the chat it left changes too), and a session
//! whose tag expires (a lapsed `archived` folds its children again) (review of the window skip).

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

/// Three chats in a temp home, the chat index started, and one connection.
async fn setup() -> Setup {
    let home = tempfile::tempdir().unwrap();
    let home_path = std::fs::canonicalize(home.path()).unwrap();
    let projects = home_path.join(".claude/projects/-work");
    std::fs::create_dir_all(&projects).unwrap();
    for i in 0..3 {
        let line = json!({"type": "user", "isSidechain": false, "cwd": "/work",
            "sessionId": session_id(i), "timestamp": format!("2026-10-01T01:00:0{i}.000Z"),
            "message": {"role": "user", "content": format!("chat {i}")}});
        std::fs::write(projects.join(format!("{}.jsonl", session_id(i))), format!("{line}\n"))
            .unwrap();
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
