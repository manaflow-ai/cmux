//! `_acpmux/seen` and `readThrough` on the wire (`hub/seen.rs` `read_through`): only `seen` moves
//! the person's cursor, forward only; an attach, a reconnect, `_acpmux/view` and a restart of the
//! daemon answer it unchanged.

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
    cfg.store.mode = StoreMode::Local;
    let store = crate::store::open(&cfg.store, home).unwrap();
    crate::hub::Hub::new(cfg, store)
}

struct Client {
    input: mpsc::Sender<String>,
    outgoing: mpsc::Receiver<String>,
    next: u64,
}

impl Client {
    async fn connect(hub: &Arc<crate::hub::Hub>) -> Self {
        let (input, incoming) = mpsc::channel(64);
        let (output, outgoing) = mpsc::channel(1024);
        tokio::spawn(serve_connection_with(hub.clone(), incoming, output, Origin::Local));
        let mut client = Client { input, outgoing, next: 1 };
        let hello = json!({"protocolVersion": 1, "clientCapabilities": {},
            "clientInfo": {"name": "test", "version": "0"}});
        let reply = client.call(method::INITIALIZE, hello).await;
        let caps = &reply["result"]["_meta"]["acpmux"]["capabilities"];
        assert!(
            caps.as_array().is_some_and(|c| c.contains(&json!("read-through-v1"))),
            "initialize names read-through-v1: {caps}"
        );
        client
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
}

fn alice() -> Value {
    json!({"acpmux": {"author": {"id": "tailnet:alice@example.com", "name": "Alice"}}})
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn only_seen_moves_the_cursor_and_a_restart_keeps_it() {
    let home = tempfile::tempdir().unwrap();
    let first = hub(home.path());
    let req = crate::hub::NewRequest { cwd: Some(std::env::temp_dir()), ..Default::default() };
    let s = first.new_session(req).await.unwrap();
    for _ in 0..4 {
        first.append(&s, "mux", "note", json!({"row": true}));
    }
    let id = s.id.clone();
    let mut a = Client::connect(&first).await;
    let attached = a.ok(method::MUX_ATTACH, json!({"sessionId": id, "eventStream": true})).await;
    assert_eq!(attached["readThrough"], Value::Null, "nothing seen yet; attaching sees nothing");
    let last = attached["lastSeq"].as_u64().unwrap();

    let seen = a.ok(method::MUX_SEEN, json!({"sessionId": id, "seq": last - 1})).await;
    assert_eq!(seen["readThrough"], json!(last - 1));
    let back = a.ok(method::MUX_SEEN, json!({"sessionId": id, "seq": 1})).await;
    assert_eq!(back["readThrough"], json!(last - 1), "never back");
    let refused = a.call(method::MUX_SEEN, json!({"sessionId": id})).await;
    assert!(refused.get("error").is_some(), "seq is required: {refused}");

    // A view change, idle and back, a notice: nothing moves.
    a.ok(method::MUX_VIEW, json!({"sessionId": id, "visible": true, "attending": false})).await;
    a.ok(method::MUX_VIEW, json!({"sessionId": id, "visible": true, "attending": true})).await;
    first.append(&s, "mux", "notice", json!({"text": "reconnected"}));
    // Alice's cursor is hers.
    let hers = a.ok(method::MUX_SEEN, json!({"sessionId": id, "seq": 2, "_meta": alice()})).await;
    assert_eq!(hers["readThrough"], json!(2));

    // A reconnect: a second connection's attach answers the same cursor.
    let mut b = Client::connect(&first).await;
    let again = b.ok(method::MUX_ATTACH, json!({"sessionId": id, "eventStream": true})).await;
    assert_eq!(again["readThrough"], json!(last - 1));
    let as_alice = b
        .ok(method::MUX_ATTACH, json!({"sessionId": id, "visible": false, "_meta": alice()}))
        .await;
    assert_eq!(as_alice["readThrough"], json!(2));
    drop((a, b, s));
    first.store.flush_session(&id).unwrap();
    first.shutdown_all().await;
    drop(first);

    // The daemon restarts (an update): the cursor is where the person left it.
    let restarted = hub(home.path());
    let mut c = Client::connect(&restarted).await;
    let after = c.ok(method::MUX_ATTACH, json!({"sessionId": id, "eventStream": true})).await;
    assert_eq!(after["readThrough"], json!(last - 1), "kept across a restart");
    restarted.shutdown_all().await;
}
