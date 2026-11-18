//! A hidden page hears no other chat's list change (`_acpmux/watch {shown}`, capability
//! `session-list-shown-v1`). Leo, 2026-11-18: "Why should non visible thing even affect the
//! renderer thread anyways?" Every agent page watches the list, the hidden New Tab page and the
//! prewarmed spare page too, and all of them share one renderer: each change of any of 10K chats
//! was parsed and folded in every hidden page. A hidden connection now hears the chats it is
//! attached to only, and on show reads exactly the rows that changed meanwhile, by the list's
//! follow from the last position it was sent.

use crate::config::{Config, StoreMode};
use crate::rpc::{Message, method};
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const CAPABILITY: &str = "session-list-shown-v1";

fn hub_of(n: usize) -> Arc<crate::hub::Hub> {
    let mut config = Config::default();
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = crate::hub::Hub::new(config, store);
    for i in 0..n {
        let meta: crate::store::SessionMeta = serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA, "id": id(i), "name": id(i),
            "harness": "claude", "family": "claude", "cwd": "/w", "status": "idle",
            "createdAt": 1, "updatedAt": i + 1, "preview": "A short synthetic reply",
        }))
        .unwrap();
        hub.insert_test_session(meta);
    }
    hub
}

fn id(i: usize) -> String {
    format!("s-{i:05}")
}

struct Page {
    input: mpsc::Sender<String>,
    outgoing: mpsc::Receiver<String>,
    next: u64,
    /// Every notice read so far, oldest first.
    notices: Vec<Value>,
    capabilities: Value,
}

impl Page {
    async fn open(hub: &Arc<crate::hub::Hub>) -> Self {
        let (input, incoming) = mpsc::channel(64);
        let (output, outgoing) = mpsc::channel(65_536);
        tokio::spawn(super::serve_connection_with(
            hub.clone(),
            incoming,
            output,
            super::Origin::Local,
        ));
        let mut page =
            Page { input, outgoing, next: 1, notices: Vec::new(), capabilities: Value::Null };
        let hello = json!({"protocolVersion": 1, "clientInfo": {"name": "page", "version": "0"}});
        let reply = page.ok(method::INITIALIZE, hello).await;
        page.capabilities = reply["_meta"]["acpmux"]["capabilities"].clone();
        page
    }

    async fn ok(&mut self, m: &str, params: Value) -> Value {
        let id = self.next;
        self.next += 1;
        self.input.send(Message::request(id, m, params).to_line()).await.unwrap();
        let notices = &mut self.notices;
        let outgoing = &mut self.outgoing;
        let reply = tokio::time::timeout(Duration::from_secs(30), async {
            loop {
                let line: Value = serde_json::from_str(&outgoing.recv().await.unwrap()).unwrap();
                if line["id"] == json!(id) {
                    return line;
                }
                if line.get("method").is_some() {
                    notices.push(line);
                }
            }
        })
        .await
        .expect("an answer within 30 s");
        assert!(reply.get("error").is_none(), "{m}: {reply}");
        reply["result"].clone()
    }

    /// Reads notices until `session_changed` of `chat` with `kind` arrives: the fan-out sends in
    /// order, so every change broadcast before it has been sent (or not) by then.
    async fn until_changed(&mut self, chat: &str) {
        let outgoing = &mut self.outgoing;
        let notices = &mut self.notices;
        tokio::time::timeout(Duration::from_secs(30), async {
            loop {
                let line: Value = serde_json::from_str(&outgoing.recv().await.unwrap()).unwrap();
                let done = line["method"] == method::MUX_SESSION_CHANGED
                    && line["params"]["sessionId"] == chat;
                if line.get("method").is_some() {
                    notices.push(line);
                }
                if done {
                    return;
                }
            }
        })
        .await
        .expect("the attached chat's change arrives");
    }

    /// The chats `session_changed` named since notice `from`.
    fn changed_since(&self, from: usize) -> Vec<String> {
        self.notices[from..]
            .iter()
            .filter(|n| n["method"] == method::MUX_SESSION_CHANGED)
            .filter_map(|n| n["params"]["sessionId"].as_str().map(str::to_owned))
            .collect()
    }

    /// The highest `listSeq` the page applied, as `sessionPages.ts` keeps it.
    fn list_seq(&self, reply: &Value) -> u64 {
        self.notices
            .iter()
            .filter_map(|n| n["params"]["listSeq"].as_u64())
            .chain(reply["listSeq"].as_u64())
            .max()
            .unwrap_or(0)
    }
}

fn status(hub: &crate::hub::Hub, chat: &str, status: &str) {
    let session = hub.resolve(chat).unwrap();
    hub.append(&session, "mux", "status", json!({"status": status}));
}

/// A hidden page hears its own chat only; shown again, it reads the rows changed while hidden, and
/// only those, from the last position it was sent, even though its own chat's notices moved its
/// cursor past them.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_hidden_page_hears_its_own_chat_only_and_reads_the_rest_on_show() {
    let hub = hub_of(50);
    let own = id(0);
    let mut page = Page::open(&hub).await;
    assert!(
        page.capabilities.as_array().is_some_and(|c| c.contains(&json!(CAPABILITY))),
        "initialize names {CAPABILITY}: {}",
        page.capabilities
    );
    let watched = page.ok(method::MUX_WATCH, json!({"enabled": true, "limit": 10})).await;
    let epoch = watched["listEpoch"].as_str().unwrap().to_owned();
    page.ok(method::MUX_ATTACH, json!({"sessionId": own})).await;

    // Hidden, as `sessionPages.ts` `hide` says it: a follow from its cursor, not the list.
    let at = page.list_seq(&watched);
    let hide = json!({"enabled": true, "shown": false, "afterSeq": at, "listEpoch": epoch});
    let hidden = page.ok(method::MUX_WATCH, hide).await;
    assert_eq!(hidden["follow"], json!(true), "hiding reads no list: {hidden}");
    let from = page.notices.len();
    for i in 1..=20 {
        status(&hub, &id(i), "running");
    }
    status(&hub, &own, "running");
    page.until_changed(&own).await;
    let heard = page.changed_since(from);
    assert_eq!(
        heard.iter().filter(|chat| **chat != own).count(),
        0,
        "a hidden page hears no other chat's change: {heard:?}"
    );

    // Shown: the follow from the page's own cursor, which its chat's notice moved past the rows
    // that changed while it was hidden.
    let after = page.list_seq(&watched);
    let shown = page
        .ok(
            method::MUX_WATCH,
            json!({"enabled": true, "shown": true, "limit": 10, "afterSeq": after, "listEpoch": epoch}),
        )
        .await;
    assert_eq!(shown["follow"], json!(true), "the show is a follow, not the list: {shown}");
    let mut rows: Vec<String> = shown["sessions"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|row| row["sessionId"].as_str().map(str::to_owned))
        .collect();
    rows.sort();
    let mut changed: Vec<String> = (1..=20).map(id).collect();
    changed.push(own.clone());
    changed.sort();
    // The page's own chat may come again (its change was sent while it was hidden): no other.
    rows.retain(|row| *row != own);
    changed.retain(|row| *row != own);
    assert_eq!(rows, changed, "exactly the rows changed while hidden");

    // Shown, it hears every chat again.
    let from = page.notices.len();
    status(&hub, &id(30), "running");
    status(&hub, &own, "idle");
    page.until_changed(&own).await;
    assert!(page.changed_since(from).contains(&id(30)), "a shown page hears every chat");
}

/// A page born hidden (the prewarmed spare page) reads the list once and then nothing until it
/// shows; a client that names no `shown` (an older page) hears every chat as before.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_page_born_hidden_reads_the_list_and_an_older_page_hears_all() {
    let hub = hub_of(20);
    let own = id(0);
    let mut hidden = Page::open(&hub).await;
    let mut older = Page::open(&hub).await;
    let first =
        hidden.ok(method::MUX_WATCH, json!({"enabled": true, "shown": false, "limit": 50})).await;
    assert_eq!(first["sessions"].as_array().map(Vec::len), Some(20), "the list: {first}");
    older.ok(method::MUX_WATCH, json!({"enabled": true, "limit": 50})).await;
    hidden.ok(method::MUX_ATTACH, json!({"sessionId": own})).await;
    older.ok(method::MUX_ATTACH, json!({"sessionId": own})).await;
    let (from_hidden, from_older) = (hidden.notices.len(), older.notices.len());
    for i in 1..=5 {
        status(&hub, &id(i), "running");
    }
    status(&hub, &own, "running");
    hidden.until_changed(&own).await;
    older.until_changed(&own).await;
    let heard = hidden.changed_since(from_hidden);
    assert!(heard.iter().all(|chat| *chat == own), "born hidden, it hears its own chat: {heard:?}");
    let heard = older.changed_since(from_older);
    assert!(heard.contains(&id(3)), "an older page hears every chat: {heard:?}");
}
