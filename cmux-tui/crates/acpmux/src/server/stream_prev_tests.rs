//! `Conn::stream_prev` on the wire: each event-stream record names the one this stream sent
//! before it (`prev`), so a client that lost records on the way sees the hole at the next one
//! and reads it from its cursor, instead of drawing it until a reload (cmuxterm-hq#27887).

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
        let (output, outgoing) = mpsc::channel(8192);
        tokio::spawn(serve_connection_with(hub.clone(), incoming, output, Origin::Local));
        let mut client = Client { input, outgoing, next: 1 };
        let hello = json!({"protocolVersion": 1, "clientCapabilities": {},
            "clientInfo": {"name": "test", "version": "0"}});
        client.ok(method::INITIALIZE, hello).await;
        client
    }

    async fn line(&mut self, pick: impl Fn(&Value) -> bool) -> Value {
        tokio::time::timeout(Duration::from_secs(30), async {
            loop {
                let line = self.outgoing.recv().await.expect("the connection ended");
                let line: Value = serde_json::from_str(&line).unwrap();
                if pick(&line) {
                    return line;
                }
            }
        })
        .await
        .expect("the line within 30 s")
    }

    async fn ok(&mut self, m: &str, params: Value) -> Value {
        let id = self.next;
        self.next += 1;
        self.input.send(Message::request(id, m, params).to_line()).await.unwrap();
        let reply = self.line(|line| line["id"] == json!(id)).await;
        assert!(reply.get("error").is_none(), "{m}: {reply}");
        reply["result"].clone()
    }

    /// The next `_acpmux/event` of a `note`.
    async fn note(&mut self) -> Value {
        let line = self
            .line(|line| {
                line["method"] == json!(method::MUX_EVENT)
                    && line["params"]["kind"] == json!("note")
            })
            .await;
        line["params"].clone()
    }
}

/// A long chat streamed to a client whose bridge loses one record in seven: with no `prev`
/// (before), the client cannot tell and every lost record is a hole until a reload; with it, the
/// client sees each hole at the next record and reads it from its cursor, so none is left.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_client_finds_every_lost_record_by_prev_and_reads_it_back() {
    const RECORDS: u64 = 2_000;
    let home = tempfile::tempdir().unwrap();
    let hub = hub(home.path());
    let req = crate::hub::NewRequest { cwd: Some(std::env::temp_dir()), ..Default::default() };
    let s = hub.new_session(req).await.unwrap();
    let id = s.id.clone();
    let mut c = Client::connect(&hub).await;
    c.ok(
        method::MUX_ATTACH,
        json!({"sessionId": id, "eventStream": true, "kinds": ["note"], "limit": 0}),
    )
    .await;

    let mut held: std::collections::BTreeSet<u64> = Default::default();
    let mut sent: Vec<u64> = Vec::new();
    let mut cursor = 0u64;
    let mut holes_seen = 0u64;
    let mut dropped = 0u64;
    let mut last_received: Option<u64> = None;
    for n in 0..RECORDS {
        // A record of a kind the stream does not carry: never a hole of this client's.
        if n % 5 == 0 {
            hub.append(&s, "mux", "other", json!({"n": n}));
        }
        hub.append(&s, "mux", "note", json!({"n": n}));
        let event = c.note().await;
        let seq = event["seq"].as_u64().unwrap();
        sent.push(seq);
        // `prev` is the note this stream sent before, never the record it left out.
        match last_received {
            None => {
                assert!(event.get("prev").is_none(), "the first record after the attach: {event}")
            }
            Some(before) => assert_eq!(event["prev"].as_u64(), Some(before), "{event}"),
        }
        last_received = Some(seq);
        // The bridge loses this one.
        if n % 7 == 3 {
            dropped += 1;
            continue;
        }
        if let Some(prev) = event["prev"].as_u64()
            && prev > cursor
        {
            holes_seen += 1;
            let page = c
                .ok(method::MUX_EVENTS, json!({"sessionId": id, "afterSeq": cursor, "beforeSeq": seq, "kinds": ["note"], "limit": 100}))
                .await;
            for read in page["events"].as_array().expect("a page") {
                held.insert(read["seq"].as_u64().unwrap());
            }
        }
        held.insert(seq);
        cursor = seq;
    }
    // The last record lost has no record after it in this run; the next one finds it.
    let tail_lost = u64::from((RECORDS - 1) % 7 == 3);
    let missing = sent.iter().filter(|seq| !held.contains(seq)).count() as u64;
    eprintln!(
        "stream_prev: records={RECORDS} dropped={dropped} holes_seen={holes_seen} missing_after={missing} missing_before={dropped}"
    );
    assert_eq!(holes_seen, dropped - tail_lost);
    assert_eq!(missing, tail_lost);
    drop((c, s));
    hub.shutdown_all().await;
}

/// A new attach starts the stream over: its first record names no `prev`, so the attach's own
/// page, not a cursor of the old stream, is what the client holds.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_attach_again_starts_the_stream_with_no_prev() {
    let home = tempfile::tempdir().unwrap();
    let hub = hub(home.path());
    let req = crate::hub::NewRequest { cwd: Some(std::env::temp_dir()), ..Default::default() };
    let s = hub.new_session(req).await.unwrap();
    let id = s.id.clone();
    let mut c = Client::connect(&hub).await;
    let attach = json!({"sessionId": id, "eventStream": true, "kinds": ["note"], "limit": 0});
    c.ok(method::MUX_ATTACH, attach.clone()).await;
    hub.append(&s, "mux", "note", json!({"n": 1}));
    hub.append(&s, "mux", "note", json!({"n": 2}));
    let first = c.note().await;
    let second = c.note().await;
    assert!(first.get("prev").is_none(), "{first}");
    assert_eq!(second["prev"], first["seq"]);
    c.ok(method::MUX_ATTACH, attach).await;
    hub.append(&s, "mux", "note", json!({"n": 3}));
    let third = c.note().await;
    assert!(third.get("prev").is_none(), "{third}");
    drop((c, s));
    hub.shutdown_all().await;
}
