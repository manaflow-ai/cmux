//! `_acpmux/attach {hold:true}` keeps a chat attached without reading its log.

use crate::config::{Config, StoreMode};
use crate::rpc::{Message, method};
use acpmux_book::gate_rounds::{self, best_p95};
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::mpsc;

const ID: &str = "hold-attach-chat";

fn hub_with_chat() -> (Arc<crate::hub::Hub>, Arc<crate::hub::Session>) {
    let mut config = Config::default();
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    let meta: crate::store::SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": ID, "name": "hold", "harness": "claude",
        "cwd": "/tmp", "status": "running", "createdAt": 3, "updatedAt": 3,
    }))
    .unwrap();
    store.save(&meta).unwrap();
    let hub = crate::hub::Hub::new(config, store);
    let session = hub.make_session(meta);
    hub.sessions.lock().unwrap().insert(ID.to_owned(), session.clone());
    (hub, session)
}

struct Client {
    input: mpsc::Sender<String>,
    outgoing: mpsc::Receiver<String>,
    next: u64,
}

impl Client {
    async fn connect(hub: &Arc<crate::hub::Hub>) -> Self {
        let (input, incoming) = mpsc::channel(32);
        let (output, outgoing) = mpsc::channel(256);
        tokio::spawn(super::super::serve_connection_with(
            hub.clone(),
            incoming,
            output,
            super::super::Origin::Local,
        ));
        let mut client = Self { input, outgoing, next: 1 };
        let hello = json!({
            "protocolVersion": 1,
            "clientInfo": {"name": "hold-attach-test", "version": "0"}
        });
        let init = client.call(method::INITIALIZE, hello).await;
        assert!(init.get("error").is_none(), "{init}");
        client
    }

    async fn call(&mut self, m: &str, params: Value) -> Value {
        let id = self.next;
        self.next += 1;
        self.input.send(Message::request(id, m, params).to_line()).await.unwrap();
        tokio::time::timeout(Duration::from_secs(20), async {
            loop {
                let line = self.outgoing.recv().await.expect("connection remains open");
                let reply: Value = serde_json::from_str(&line).unwrap();
                if reply["id"] == json!(id) {
                    return reply;
                }
            }
        })
        .await
        .expect("request answers")
    }

    async fn notification(&mut self) -> Value {
        tokio::time::timeout(Duration::from_secs(20), async {
            loop {
                let line = self.outgoing.recv().await.expect("connection remains open");
                let value: Value = serde_json::from_str(&line).unwrap();
                if value.get("method").is_some() {
                    return value;
                }
            }
        })
        .await
        .expect("notification arrives")
    }

    async fn notification_method(&mut self, method_name: &str) -> Value {
        loop {
            let value = self.notification().await;
            if value["method"] == method_name {
                return value;
            }
        }
    }
}

fn hold(kinds: Value) -> Value {
    json!({"sessionId": ID, "hold": true, "eventStream": true, "kinds": kinds})
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn hold_attach_returns_metadata_without_reading_and_exposes_capability() {
    let (hub, session) = hub_with_chat();
    for n in 0..200 {
        hub.append(&session, "mux", "long_record", json!({"n": n}));
    }
    hub.mark_log_unread_for_test(&session);
    let mut client = Client::connect(&hub).await;
    let reply = client.call(method::MUX_ATTACH, hold(json!(["long_record"]))).await;
    assert!(reply.get("error").is_none(), "{reply}");
    let result = &reply["result"];
    assert_eq!(result["hold"], true);
    assert_eq!(result["lastSeq"], session.meta().last_seq);
    assert!(result.get("events").is_none());
    assert!(result.get("hasMore").is_none());
    assert!(result.get("pageThrough").is_none());
    assert!(result.get("turnOpener").is_none());
    assert!(result.get("settled").is_none());
    assert!(!hub.session_log_loaded(&session), "hold attach read the log");
    assert!(crate::capabilities::ids().contains(&crate::capabilities::HOLD_ATTACH));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn hold_attach_rejects_every_log_read_parameter() {
    let (hub, _) = hub_with_chat();
    let mut client = Client::connect(&hub).await;
    let mut refusals = vec![
        (json!({"sessionId": ID, "hold": true, "kinds": []}), "eventStream"),
        (json!({"sessionId": ID, "hold": true, "eventStream": true}), "kinds"),
        (hold(json!(["transcript"])), "kinds"),
        (hold(json!(vec!["x"; 17])), "kinds"),
    ];
    for name in ["limit", "afterSeq", "beforeSeq", "maxBytes", "toolOutputMaxBytes", "settled"] {
        let mut params = hold(json!(["x"]));
        params[name] = json!(1);
        refusals.push((params, name));
    }
    for (params, name) in refusals {
        let reply = client.call(method::MUX_ATTACH, params).await;
        let error = reply.get("error").expect("a refusal");
        assert!(error["message"].as_str().unwrap().contains(name), "{name}: {error}");
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn hold_attach_supports_view_typing_presence_and_exact_live_kinds() {
    let (hub, session) = hub_with_chat();
    let mut first = Client::connect(&hub).await;
    let reply = first.call(method::MUX_ATTACH, hold(json!(["named_kind"]))).await;
    assert!(reply.get("error").is_none(), "{reply}");
    let view = first.call(method::MUX_VIEW, json!({"sessionId": ID, "visible": true})).await;
    assert!(view.get("error").is_none(), "{view}");
    let typing = first.call(method::MUX_TYPING, json!({"sessionId": ID, "on": true})).await;
    assert!(typing.get("error").is_none(), "{typing}");

    let mut second = Client::connect(&hub).await;
    let second_attach = second.call(method::MUX_ATTACH, hold(json!(["named_kind"]))).await;
    assert!(second_attach.get("error").is_none(), "{second_attach}");
    assert_eq!(hub.presence.snapshot(ID)["participants"][0]["devices"], 2);

    hub.append(&session, "mux", "named_kind", json!({"ok": true}));
    hub.append(&session, "mux", "not_named", json!({"ok": false}));
    hub.append(
        &session,
        "in",
        "agent_message_chunk",
        json!({"method": "session/update", "params": {"sessionId": ID,
            "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "agent"}}}}),
    );
    hub.append(&session, "mux", "tool_call", json!({"tool": "Bash"}));
    let event = first.notification_method(method::MUX_EVENT).await;
    assert_eq!(event["params"]["kind"], "named_kind");
    let extra = tokio::time::timeout(Duration::from_millis(50), first.outgoing.recv()).await;
    assert!(extra.is_err(), "the first attach got more than named_kind: {extra:?}");

    let detached = second.call(method::MUX_DETACH, json!({"sessionId": ID})).await;
    assert!(detached.get("error").is_none(), "{detached}");
    assert_eq!(hub.presence.snapshot(ID)["participants"][0]["devices"], 1);
}

fn emit_gate(name: &str, small: u128, god: u128) {
    let line = json!({"name": name, "small_p95": small, "god_p95": god, "unit": "ns"}).to_string();
    eprintln!("{line}");
    if let Some(path) = std::env::var_os("V2_GATE_OUT")
        && let Ok(mut file) = std::fs::OpenOptions::new().create(true).append(true).open(path)
    {
        use std::io::Write;
        let _ = writeln!(file, "{line}");
    }
}

async fn attach_elapsed(client: &mut Client) -> u128 {
    let started = Instant::now();
    let reply = client.call(method::MUX_ATTACH, hold(json!(["long_record"]))).await;
    assert!(reply.get("error").is_none());
    let elapsed = started.elapsed().as_nanos();
    let detached = client.call(method::MUX_DETACH, json!({"sessionId": ID})).await;
    assert!(detached.get("error").is_none());
    elapsed
}

async fn plain_attach_elapsed(client: &mut Client) -> u128 {
    let started = Instant::now();
    let reply = client
        .call(
            method::MUX_ATTACH,
            json!({"sessionId": ID, "eventStream": true, "kinds": ["long_record"], "waitLogs": false}),
        )
        .await;
    assert!(reply.get("error").is_none());
    let elapsed = started.elapsed().as_nanos();
    let detached = client.call(method::MUX_DETACH, json!({"sessionId": ID})).await;
    assert!(detached.get("error").is_none());
    elapsed
}

fn bench_hub(records: usize) -> Arc<crate::hub::Hub> {
    let (hub, session) = hub_with_chat();
    for n in 0..records {
        hub.append(&session, "mux", "long_record", json!({"n": n}));
    }
    hub.mark_log_unread_for_test(&session);
    hub
}

#[ignore = "Linux gate profile: a hold attach on the long chat against the short one"]
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn hold_attach_gate() {
    const ROUNDS: usize = 5;
    const SAMPLES: usize = 40;
    let small_hub = bench_hub(200);
    let god_hub = bench_hub(20_000);
    let mut small_rounds = Vec::new();
    let mut god_rounds = Vec::new();
    let mut small_client = Client::connect(&small_hub).await;
    let mut god_client = Client::connect(&god_hub).await;
    for _ in 0..ROUNDS {
        let mut small = Vec::with_capacity(SAMPLES);
        let mut god = Vec::with_capacity(SAMPLES);
        for _ in 0..SAMPLES {
            small.push(attach_elapsed(&mut small_client).await);
            god.push(attach_elapsed(&mut god_client).await);
        }
        small_rounds.push(small);
        god_rounds.push(god);
    }
    gate_rounds::report("v2.pr06.hold_attach", &[("small", &small_rounds), ("god", &god_rounds)]);
    let small_p95 = best_p95(&small_rounds);
    let god_p95 = best_p95(&god_rounds);
    let plain_god = plain_attach_elapsed(&mut god_client).await;
    let hold_god = attach_elapsed(&mut god_client).await;
    eprintln!("hold attach comparison (god): without_hold_ns={plain_god}, with_hold_ns={hold_god}");
    emit_gate("v2.pr06.hold_attach", small_p95, god_p95);
    assert!(
        god_p95.saturating_mul(100) <= small_p95.saturating_mul(120),
        "hold attach ratio exceeds 1.2: small={small_p95}, god={god_p95}"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn live_turns_the_owner_on_and_live_list_answers_the_shared_records() {
    let (hub, _session) = hub_with_chat();
    let mut client = Client::connect(&hub).await;
    let attach = client.call(method::MUX_ATTACH, hold(json!(["named_kind"]))).await;
    assert!(attach.get("error").is_none(), "{attach}");
    client.call(method::MUX_VIEW, json!({"sessionId": ID, "visible": true})).await;

    let off = client.call(method::MUX_LIVE_LIST, json!({})).await;
    assert_eq!(off["result"], json!({"live": false, "people": []}), "{off}");
    let read = client.call(method::MUX_LIVE, json!({})).await;
    assert_eq!(read["result"], json!({"live": false}), "a call without live only reads");

    let on = client.call(method::MUX_LIVE, json!({"live": true})).await;
    assert_eq!(on["result"], json!({"live": true}), "{on}");
    client.call(method::MUX_TYPING, json!({"sessionId": ID, "on": true})).await;
    let list = client.call(method::MUX_LIVE_LIST, json!({})).await;
    let people = list["result"]["people"].as_array().expect("people");
    assert_eq!(list["result"]["live"], true);
    assert_eq!(people.len(), 1, "{list}");
    assert_eq!(people[0]["id"], "owner");
    assert_eq!(people[0]["kind"], "person");
    assert_eq!(people[0]["doing"], "typing");
    assert_eq!(people[0]["where"]["chat"], ID);

    let bad = client.call(method::MUX_LIVE, json!({"live": "yes"})).await;
    assert!(bad.get("error").is_some(), "a non-boolean live is refused: {bad}");
}
