//! An attachment that asked for no `timeBreakdown` (`omitTimeBreakdown: true`, the phone) hears
//! its chat's `_acpmux/session_changed` rows without it; one that did not still gets it whole.
//! A full row of a long chat is mostly that field: a phone's resume read 32 KiB of breakdown per
//! row it never draws (the time-away bench, `tests/mobile_link_conditions.rs`).

use crate::config::{Config, StoreMode};
use crate::rpc::{Message, method};
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const WAIT: Duration = Duration::from_secs(30);

struct Client {
    input: mpsc::Sender<String>,
    out: mpsc::Receiver<String>,
    next_id: u64,
}

impl Client {
    async fn connect(hub: &Arc<crate::hub::Hub>) -> Self {
        let (input, incoming) = mpsc::channel(8);
        let (output, out) = mpsc::channel(65_536);
        tokio::spawn(super::serve_connection_with(
            hub.clone(),
            incoming,
            output,
            super::Origin::Local,
        ));
        let mut client = Self { input, out, next_id: 0 };
        let hello = json!({"protocolVersion": 1, "clientInfo": {"name": "rows", "version": "0"}});
        client.call(method::INITIALIZE, hello).await;
        client
    }

    async fn call(&mut self, m: &str, params: Value) -> Value {
        self.next_id += 1;
        let id = self.next_id;
        self.input.send(Message::request(id, m, params).to_line()).await.unwrap();
        let out = &mut self.out;
        tokio::time::timeout(WAIT, async {
            loop {
                let reply: Value = serde_json::from_str(&out.recv().await.unwrap()).unwrap();
                if reply["id"] == id && reply.get("method").is_none() {
                    assert!(reply.get("error").is_none(), "{m}: {reply}");
                    return reply["result"].clone();
                }
            }
        })
        .await
        .unwrap_or_else(|_| panic!("{m} answers"))
    }

    /// The next `_acpmux/session_changed` row for `kind`.
    async fn row(&mut self, kind: &str) -> Value {
        let out = &mut self.out;
        tokio::time::timeout(WAIT, async {
            loop {
                let line: Value = serde_json::from_str(&out.recv().await.unwrap()).unwrap();
                if line["method"] == method::MUX_SESSION_CHANGED
                    && line["params"]["recordKind"] == kind
                {
                    return line["params"]["session"].clone();
                }
            }
        })
        .await
        .unwrap_or_else(|_| panic!("a {kind} row"))
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_phone_attachment_hears_rows_without_the_breakdown() {
    let mut config = Config::default();
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = crate::hub::Hub::new(config, store);
    let meta: crate::store::SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "c", "name": "c", "harness": "claude",
        "family": "claude", "cwd": "/w", "status": "idle", "createdAt": 1, "updatedAt": 1,
    }))
    .unwrap();
    let session = hub.insert_test_session(meta);
    hub.append(&session, "mux", "turn_started", json!({"turnSeq": 1, "turnId": "t1"}));
    hub.append(&session, "mux", "turn_result", json!({"turnSeq": 1, "turnId": "t1"}));
    hub.seed_time_breakdown_for_test(&session);
    assert!(hub.session_summary(&session)["timeBreakdown"].is_object(), "the chat has one");

    let attach = |omit: bool| {
        let mut p = json!({"sessionId": "c", "waitLogs": false, "limit": 0, "eventStream": true});
        if omit {
            p["omitTimeBreakdown"] = json!(true);
        }
        p
    };
    // Rows go out to a connection that watches the list (`deliver`'s `watching`), as the phone
    // and the pane both do: an attachment alone hears the chat's records, not its row.
    let mut phone = Client::connect(&hub).await;
    phone.call(method::MUX_WATCH, json!({"enabled": true})).await;
    phone.call(method::MUX_ATTACH, attach(true)).await;
    let mut pane = Client::connect(&hub).await;
    pane.call(method::MUX_WATCH, json!({"enabled": true})).await;
    pane.call(method::MUX_ATTACH, attach(false)).await;

    hub.append(&session, "mux", "turn_end", json!({"turnSeq": 1, "turnId": "t1"}));
    let lean = phone.row("turn_end").await;
    let whole = pane.row("turn_end").await;
    assert!(whole["timeBreakdown"].is_object(), "the pane keeps it: {whole}");
    assert!(lean.get("timeBreakdown").is_none(), "the phone's row leaves it out: {lean}");
    let mut expected = whole.clone();
    expected.as_object_mut().unwrap().remove("timeBreakdown");
    assert_eq!(lean, expected, "nothing else differs");
}
