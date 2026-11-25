//! A reopen's `_acpmux/attach {afterSeq}` (iOS `AcpmuxHub.swift` reopen, the web pane's
//! reconnect) costs what changed since its cursor, not the chat's length. The network-conditions
//! harness (`tests/mobile_link_conditions.rs`, warm phase) measured its reply at ~9.5 KB on a
//! 20-turn chat and ~71.5 KB on a 2,000-turn one with nothing new after the cursor: the reply's
//! `session` detail carries the chat's whole `timeBreakdown` (up to 512 spans, one per turn,
//! `time_breakdown.rs` `MAX_SPANS`), sent again on every reattach.

use crate::config::{Config, StoreMode};
use crate::rpc::{Message, method};
use crate::store::EventRecord;
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::mpsc;

const ID: &str = "reopen-bytes-chat";

/// A chat of `turns` finished turns, each a prompt, its start, one answer chunk and its result,
/// half a second apart so every turn folds to a span. Returns the hub and the newest seq.
fn hub_with_turns(turns: u64) -> (Arc<crate::hub::Hub>, u64) {
    let mut config = Config::default();
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    let mut meta: crate::store::SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": ID, "name": "reopen", "harness": "claude",
        "cwd": "/tmp", "status": "idle", "createdAt": 3, "updatedAt": 3,
    }))
    .unwrap();
    store.save(&meta).unwrap();
    let mut seq = 0;
    let mut push = |at: u64, dir: &str, kind: &str, msg: Value| {
        seq += 1;
        let rec = EventRecord { seq, at, dir: dir.into(), kind: kind.into(), msg, host_seq: None };
        store.append(ID, &rec).unwrap();
    };
    for turn in 0..turns {
        let at = 1_000_000 + turn * 1_000;
        let (prompt, id) = (format!("p{turn}"), format!("t{turn}"));
        push(at, "mux", "user_message", json!({"text": "go on", "promptId": prompt, "turnId": id}));
        push(at, "mux", "turn_started", json!({"promptId": prompt, "turnId": id}));
        let update = json!({"sessionUpdate": "agent_message_chunk",
                            "content": {"type": "text", "text": "ok"}});
        push(
            at + 10,
            "in",
            "agent_message_chunk",
            json!({"jsonrpc": "2.0", "method": "session/update",
                   "params": {"sessionId": ID, "update": update}}),
        );
        push(
            at + 500,
            "mux",
            "turn_result",
            json!({"status": "completed", "turnId": id, "promptId": prompt}),
        );
    }
    meta.last_seq = seq;
    meta.event_count = seq;
    store.save(&meta).unwrap();
    let hub = crate::hub::Hub::new(config, store);
    let session = hub.make_session(meta);
    hub.sessions.lock().unwrap().insert(ID.to_owned(), session);
    (hub, seq)
}

struct Client {
    input: mpsc::Sender<String>,
    outgoing: mpsc::Receiver<String>,
    next: u64,
}

impl Client {
    async fn connect(hub: &Arc<crate::hub::Hub>) -> Self {
        Self::connect_with(hub, json!({})).await
    }

    /// A connection whose `initialize` also carries `extra` (its `_meta`, say).
    async fn connect_with(hub: &Arc<crate::hub::Hub>, extra: Value) -> Self {
        let (input, incoming) = mpsc::channel(32);
        let (output, outgoing) = mpsc::channel(4096);
        tokio::spawn(super::super::serve_connection_with(
            hub.clone(),
            incoming,
            output,
            super::super::Origin::Local,
        ));
        let mut client = Self { input, outgoing, next: 1 };
        let mut hello = json!({"protocolVersion": 1, "clientInfo": {"name": "reopen-bytes-test", "version": "0"}});
        if let (Some(hello), Some(extra)) = (hello.as_object_mut(), extra.as_object()) {
            hello.extend(extra.clone());
        }
        let (_, init) = client.call(method::INITIALIZE, hello).await;
        assert!(init.get("error").is_none(), "{init}");
        client
    }

    /// The reply and its size on the wire.
    async fn call(&mut self, m: &str, params: Value) -> (usize, Value) {
        let id = self.next;
        self.next += 1;
        self.input.send(Message::request(id, m, params).to_line()).await.unwrap();
        tokio::time::timeout(Duration::from_secs(20), async {
            loop {
                let line = self.outgoing.recv().await.expect("connection remains open");
                let reply: Value = serde_json::from_str(&line).unwrap();
                if reply["id"] == json!(id) && reply.get("method").is_none() {
                    return (line.len(), reply);
                }
            }
        })
        .await
        .expect("request answers")
    }
}

/// The phone's open, then its reopen with afterSeq = the newest record it holds (the harness's
/// cold and warm phases): the reopen's reply size.
async fn reopen_reply_bytes(turns: u64) -> usize {
    let (hub, last) = hub_with_turns(turns);
    let mut client = Client::connect(&hub).await;
    let open = json!({"sessionId": ID, "limit": 400, "eventStream": true,
                      "maxBytes": 128 * 1024, "toolOutputMaxBytes": 64 * 1024});
    let (_, reply) = client.call(method::MUX_ATTACH, open).await;
    assert!(reply.get("error").is_none(), "{reply}");
    // The open starts the chat's time breakdown in the background; the reopen comes after it.
    let s = hub.resolve(ID).unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    while !hub.session_detail(&s)["timeBreakdown"].is_object() {
        assert!(Instant::now() < deadline, "the time breakdown never seeded");
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    // The first reopen gets the breakdown and its version (`time_breakdown_gate.rs`); the next
    // one sends that version back, as the phone does from then on.
    let reopen = json!({"sessionId": ID, "limit": 400, "eventStream": true, "afterSeq": last});
    let (first_bytes, first) = client.call(method::MUX_ATTACH, reopen.clone()).await;
    assert!(first.get("error").is_none(), "{first}");
    let breakdown = &first["result"]["session"]["timeBreakdown"];
    let spans = breakdown["spans"].as_array().map_or(0, Vec::len);
    let breakdown_bytes = serde_json::to_string(breakdown).unwrap().len();
    let version = first["result"]["timeBreakdownVersion"].clone();
    assert!(version.is_string(), "the reply names its breakdown copy: {}", first["result"]);
    let mut again = reopen;
    again["timeBreakdownVersion"] = version;
    let (bytes, reply) = client.call(method::MUX_ATTACH, again).await;
    assert!(reply.get("error").is_none(), "{reply}");
    assert_eq!(reply["result"]["events"], json!([]), "nothing is newer than afterSeq");
    assert!(reply["result"]["session"].get("timeBreakdown").is_none(), "the held copy is left out");
    eprintln!(
        "reopen afterSeq={last} on {turns} turns: {first_bytes} bytes without a held version, \
         {bytes} with it; timeBreakdown {breakdown_bytes} bytes for {spans} spans ({} per span)",
        breakdown_bytes.checked_div(spans).unwrap_or(0)
    );
    bytes
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_reopen_with_nothing_new_costs_the_same_on_a_long_chat() {
    let short = reopen_reply_bytes(20).await;
    let long = reopen_reply_bytes(2_000).await;
    assert!(
        long <= short + 4 * 1024,
        "a reopen with nothing after afterSeq grew with the chat's length: {short} bytes at 20 \
         turns, {long} at 2,000"
    );
}

/// The phone's `initialize` `_meta.acpmux.omitTimeBreakdown` (`AcpmuxHub.swift` `bind`): its
/// attach and the attached chat's `session_changed` rows carry no `timeBreakdown`, while a
/// connection that did not ask (the web pane's Session Info) still gets it in both.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_connection_that_draws_no_breakdown_gets_none_in_its_attach_or_rows() {
    let (hub, _) = hub_with_turns(50);
    let omit = json!({"_meta": {"acpmux": {"omitTimeBreakdown": true}}});
    let mut phone = Client::connect_with(&hub, omit).await;
    let mut pane = Client::connect(&hub).await;
    // Rows go to watchers (`server/mod.rs` fan-out): the phone and the pane both watch.
    for client in [&mut phone, &mut pane] {
        let (_, watch) = client.call(method::MUX_WATCH, json!({"enabled": true})).await;
        assert!(watch.get("error").is_none(), "{watch}");
    }
    let open = json!({"sessionId": ID, "limit": 400, "eventStream": true});
    let (_, first) = pane.call(method::MUX_ATTACH, open.clone()).await;
    assert!(first.get("error").is_none(), "{first}");
    let s = hub.resolve(ID).unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    while !hub.session_detail(&s)["timeBreakdown"].is_object() {
        assert!(Instant::now() < deadline, "the time breakdown never seeded");
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    let (_, pane_attach) = pane.call(method::MUX_ATTACH, open.clone()).await;
    assert!(pane_attach["result"]["session"]["timeBreakdown"].is_object(), "{pane_attach}");
    let (_, phone_attach) = phone.call(method::MUX_ATTACH, open).await;
    assert!(phone_attach.get("error").is_none(), "{phone_attach}");
    assert!(
        phone_attach["result"]["session"].get("timeBreakdown").is_none(),
        "the phone's attach carried a breakdown"
    );
    assert!(phone_attach["result"]["timeBreakdownVersion"].is_string());

    hub.append(&s, "mux", "titled", json!({"title": "renamed-for-rows"}));
    let update = json!({"sessionUpdate": "agent_message_chunk",
                        "content": {"type": "text", "text": "rows-end"}});
    hub.append(
        &s,
        "in",
        "agent_message_chunk",
        json!({"jsonrpc": "2.0", "method": "session/update",
               "params": {"sessionId": ID, "update": update}}),
    );
    for (name, client, wants) in [("phone", &mut phone, false), ("pane", &mut pane, true)] {
        let (rows, with_breakdown) = tokio::time::timeout(Duration::from_secs(10), async {
            let (mut rows, mut with) = (0, 0);
            loop {
                let line = client.outgoing.recv().await.expect("connection remains open");
                let v: Value = serde_json::from_str(&line).unwrap();
                if v["method"] == method::MUX_SESSION_CHANGED
                    && v["params"]["sessionId"] == json!(ID)
                {
                    rows += 1;
                    with += usize::from(v["params"]["session"].get("timeBreakdown").is_some());
                }
                if line.contains("rows-end") {
                    return (rows, with);
                }
            }
        })
        .await
        .unwrap_or_else(|_| panic!("the {name} never got the chat's records"));
        assert!(rows > 0, "the {name} got no session_changed for the attached chat");
        if wants {
            assert!(with_breakdown > 0, "the pane's {rows} rows had no breakdown");
        } else {
            assert_eq!(
                with_breakdown, 0,
                "the phone got a breakdown in {with_breakdown} of {rows} rows"
            );
        }
    }
}
