//! `_acpmux/attach` `alsoKinds` (`also_kinds.rs`) across phone and daemon versions: the new
//! phone's attach written with `initialize` and the watch, before either answered, reads what an
//! older phone's attach after `initialize` reads; an older phone's attach is unchanged.

use crate::config::{Config, StoreMode};
use crate::rpc::{Message, method};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const ID: &str = "also-kinds-chat";
const CHAT_KINDS: &[&str] = &[
    "transcript",
    "queue_updated",
    "queue_order",
    "queue_paused",
    "queue_resumed",
    "claude.system.api_retry",
    "bookmarks",
];
const ELEVATION: &[&str] = &["elevation_request", "elevation_decision"];

fn hub_with_chat() -> Arc<crate::hub::Hub> {
    let mut config = Config::default();
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    let meta: crate::store::SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": ID, "name": "also", "harness": "claude",
        "cwd": "/tmp", "status": "idle", "createdAt": 3, "updatedAt": 3,
    }))
    .unwrap();
    store.save(&meta).unwrap();
    let hub = crate::hub::Hub::new(config, store);
    let session = hub.make_session(meta);
    hub.sessions.lock().unwrap().insert(ID.to_owned(), session.clone());
    hub.append(&session, "mux", "user_message", json!({"text": "hi", "turnId": "t1"}));
    hub.append(&session, "mux", "elevation_request", json!({"requestId": "e1"}));
    hub.append(&session, "mux", "not_asked", json!({}));
    hub
}

struct Client {
    input: mpsc::Sender<String>,
    outgoing: mpsc::Receiver<String>,
    next: u64,
}

impl Client {
    fn connect(hub: &Arc<crate::hub::Hub>) -> Self {
        let (input, incoming) = mpsc::channel(32);
        let (output, outgoing) = mpsc::channel(256);
        tokio::spawn(super::super::serve_connection_with(
            hub.clone(),
            incoming,
            output,
            super::super::Origin::Local,
        ));
        Self { input, outgoing, next: 1 }
    }

    async fn post(&mut self, m: &str, params: Value) -> u64 {
        let id = self.next;
        self.next += 1;
        self.input.send(Message::request(id, m, params).to_line()).await.unwrap();
        id
    }

    /// The answers to `ids`, however the daemon ordered them.
    async fn answers(&mut self, ids: &[u64]) -> HashMap<u64, Value> {
        tokio::time::timeout(Duration::from_secs(20), async {
            let mut got = HashMap::new();
            while got.len() < ids.len() {
                let line = self.outgoing.recv().await.expect("connection remains open");
                let reply: Value = serde_json::from_str(&line).unwrap();
                if let Some(id) = reply["id"].as_u64().filter(|id| ids.contains(id)) {
                    assert!(reply.get("error").is_none(), "{reply}");
                    got.insert(id, reply["result"].clone());
                }
            }
            got
        })
        .await
        .expect("requests answer")
    }

    async fn call(&mut self, m: &str, params: Value) -> Value {
        let id = self.post(m, params).await;
        self.answers(&[id]).await.remove(&id).unwrap()
    }
}

fn hello() -> Value {
    json!({"protocolVersion": 1, "clientInfo": {"name": "cmux-ios", "version": "1"},
           "clientCapabilities": {}})
}

fn attach(kinds: &[&str], also: Option<&[&str]>) -> Value {
    let mut params = json!({"sessionId": ID, "limit": 400, "kinds": kinds, "eventStream": true,
                            "maxBytes": 131072, "toolOutputMaxBytes": 65536});
    if let Some(also) = also {
        params["alsoKinds"] = json!(also);
    }
    params
}

fn page_kinds(reply: &Value) -> Vec<String> {
    reply["events"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|e| e["kind"].as_str().map(str::to_owned))
        .collect()
}

/// New phone, new daemon: the attach written behind `initialize` and the watch reads the sudo
/// card's records through `alsoKinds`, as an older phone's 9-kind attach after `initialize` does.
#[tokio::test]
async fn a_pipelined_attach_with_also_kinds_reads_as_the_old_attach() {
    let hub = hub_with_chat();
    let mut new = Client::connect(&hub);
    let init = new.post(method::INITIALIZE, hello()).await;
    let watch = new.post(method::MUX_WATCH, json!({"enabled": true, "limit": 100})).await;
    let early = new.post(method::MUX_ATTACH, attach(CHAT_KINDS, Some(ELEVATION))).await;
    let mut got = new.answers(&[init, watch, early]).await;
    let caps = got[&init]["_meta"]["acpmux"]["capabilities"].clone();
    assert!(caps.as_array().unwrap().contains(&json!(super::also_kinds::CAPABILITY)), "{caps}");
    let early = got.remove(&early).unwrap();

    let mut old = Client::connect(&hub);
    old.call(method::INITIALIZE, hello()).await;
    let kinds: Vec<&str> = CHAT_KINDS.iter().chain(ELEVATION).copied().collect();
    let before = old.call(method::MUX_ATTACH, attach(&kinds, None)).await;

    assert_eq!(page_kinds(&early), page_kinds(&before));
    assert!(page_kinds(&early).contains(&"elevation_request".to_owned()), "{early}");
    assert!(!page_kinds(&early).contains(&"not_asked".to_owned()), "{early}");
}

/// Old phone, new daemon: an attach with no `alsoKinds` reads exactly its `kinds`, as before.
#[tokio::test]
async fn an_attach_without_also_kinds_is_unchanged() {
    let hub = hub_with_chat();
    let mut old = Client::connect(&hub);
    old.call(method::INITIALIZE, hello()).await;
    let reply = old.call(method::MUX_ATTACH, attach(CHAT_KINDS, None)).await;
    let kinds = page_kinds(&reply);
    assert!(kinds.contains(&"user_message".to_owned()), "{reply}");
    assert!(!kinds.contains(&"elevation_request".to_owned()), "{reply}");
}
