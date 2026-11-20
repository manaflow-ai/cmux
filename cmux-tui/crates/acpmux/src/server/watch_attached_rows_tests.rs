//! `_acpmux/watch {enabled: false, attachedRows: true}` (`watch-attached-rows-v1`): a hidden page
//! parks its watch. It reads no list, hears no other chat's `session_changed`, and still hears
//! its own (attached) chat's row; turned on again from its cursor it reads only the rows changed
//! since. Every watching page heard every chat's change, so the shared renderer's cost grew with
//! chats times hidden pages (Leo, 2026-11-20: "My Mac is at load 272 on 15 cores").

use crate::config::{Config, StoreMode};
use crate::rpc::{Message, method};
use crate::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

fn hub(home: &Path) -> Arc<crate::hub::Hub> {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let cfg = json!({"harnesses": {"fake": {"argv": ["python3", fake]}}, "defaultHarness": "fake"});
    let mut cfg: Config = serde_json::from_value(cfg).unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, home).unwrap();
    crate::hub::Hub::new(cfg, store)
}

struct Client {
    input: mpsc::Sender<String>,
    outgoing: mpsc::Receiver<String>,
    next: u64,
    /// The `session_changed` notices heard so far, by chat id.
    changed: Vec<String>,
}

impl Client {
    async fn connect(hub: &Arc<crate::hub::Hub>) -> (Self, Value) {
        let (input, incoming) = mpsc::channel(64);
        let (output, outgoing) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), incoming, output, Origin::Local));
        let mut client = Client { input, outgoing, next: 1, changed: Vec::new() };
        let hello = json!({"protocolVersion": 1, "clientCapabilities": {},
            "clientInfo": {"name": "test", "version": "0"}});
        let reply = client.call(method::INITIALIZE, hello).await;
        (client, reply)
    }

    fn heard(&mut self, line: &Value) {
        if line["method"] == method::MUX_SESSION_CHANGED
            && let Some(id) = line["params"]["sessionId"].as_str()
        {
            self.changed.push(id.to_owned());
        }
    }

    async fn call(&mut self, m: &str, params: Value) -> Value {
        let id = self.next;
        self.next += 1;
        self.input.send(Message::request(id, m, params).to_line()).await.unwrap();
        tokio::time::timeout(Duration::from_secs(20), async {
            loop {
                let line = self.outgoing.recv().await.expect("the connection ended");
                let line: Value = serde_json::from_str(&line).unwrap();
                if line["id"] == json!(id) {
                    return line;
                }
                self.heard(&line);
            }
        })
        .await
        .expect("an answer within 20 s")
    }

    async fn ok(&mut self, m: &str, params: Value) -> Value {
        let reply = self.call(m, params).await;
        assert!(reply.get("error").is_none(), "{m}: {reply}");
        reply["result"].clone()
    }

    /// Every notice already sent, then a round trip so none is still on its way.
    async fn settle(&mut self) {
        self.ok(method::MUX_STATUS, json!({})).await;
        while let Ok(line) = self.outgoing.try_recv() {
            let line: Value = serde_json::from_str(&line).unwrap();
            self.heard(&line);
        }
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_parked_watch_hears_only_its_attached_chat_and_follows_from_its_cursor() {
    let home = tempfile::tempdir().unwrap();
    let hub = hub(home.path());
    let mut chats = Vec::new();
    for _ in 0..20 {
        let req = crate::hub::NewRequest { cwd: Some(std::env::temp_dir()), ..Default::default() };
        chats.push(hub.new_session(req).await.unwrap());
    }
    let own = chats[0].id.clone();
    let (mut page, hello) = Client::connect(&hub).await;
    let caps = &hello["result"]["_meta"]["acpmux"]["capabilities"];
    assert!(
        caps.as_array().is_some_and(|c| c.contains(&json!("watch-attached-rows-v1"))),
        "initialize names watch-attached-rows-v1: {caps}"
    );
    let listed = page.ok(method::MUX_WATCH, json!({"enabled": true})).await;
    let cursor = (listed["listSeq"].clone(), listed["listEpoch"].clone());
    assert!(cursor.0.is_u64(), "the list names its position: {listed}");
    page.ok(method::MUX_ATTACH, json!({"sessionId": own, "eventStream": true})).await;

    // Parked: answered with no list.
    let parked = page.ok(method::MUX_WATCH, json!({"enabled": false, "attachedRows": true})).await;
    assert_eq!(parked, json!({}), "a park reads no list");
    page.settle().await;
    page.changed.clear();

    for (n, chat) in chats.iter().enumerate() {
        hub.append(chat, "mux", "renamed", json!({"name": format!("renamed-{n}")}));
    }
    page.settle().await;
    assert!(
        page.changed.iter().all(|id| *id == own),
        "a parked watch heard another chat's change: {:?}",
        page.changed
    );
    assert!(page.changed.contains(&own), "a parked watch still hears its own chat's row");

    // Shown again: the rows changed since its cursor, not the list.
    let back = page
        .ok(
            method::MUX_WATCH,
            json!({"enabled": true, "afterSeq": cursor.0, "listEpoch": cursor.1}),
        )
        .await;
    assert_eq!(back["follow"], json!(true), "it follows from its cursor: {back}");
    let rows = back["sessions"].as_array().unwrap();
    assert_eq!(rows.len(), chats.len(), "every renamed chat, once: {back}");

    // Watching again, it hears every chat.
    page.changed.clear();
    hub.append(&chats[7], "mux", "renamed", json!({"name": "again"}));
    page.settle().await;
    assert!(page.changed.contains(&chats[7].id), "a watch turned back on hears other chats");
    hub.shutdown_all().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_watch_turned_off_without_attached_rows_still_answers_its_list() {
    let home = tempfile::tempdir().unwrap();
    let hub = hub(home.path());
    let req = crate::hub::NewRequest { cwd: Some(std::env::temp_dir()), ..Default::default() };
    let chat = hub.new_session(req).await.unwrap();
    let (mut page, _) = Client::connect(&hub).await;
    let off = page.ok(method::MUX_WATCH, json!({"enabled": false})).await;
    assert!(off["sessions"].is_array(), "the older off still lists: {off}");
    page.settle().await;
    page.changed.clear();
    hub.append(&chat, "mux", "renamed", json!({"name": "unheard"}));
    page.settle().await;
    assert!(page.changed.is_empty(), "a watch off hears nothing: {:?}", page.changed);
    hub.shutdown_all().await;
}
