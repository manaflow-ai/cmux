//! `gauges.attach` and `gauges.fanout` on the wire: an attach is a sample, and a chat's record
//! is timed until every attached connection's fan-out queued it (`gauges.rs`).

use crate::config::{Config, StoreMode};
use crate::rpc::{Message, method};
use crate::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use std::path::Path;
use std::sync::Arc;
use std::time::{Duration, Instant};
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
        client.ok(method::INITIALIZE, hello).await;
        client
    }

    /// The next line that `pick` takes, within 20 s.
    async fn line(&mut self, pick: impl Fn(&Value) -> bool) -> Value {
        tokio::time::timeout(Duration::from_secs(20), async {
            loop {
                let line = self.outgoing.recv().await.expect("the connection ended");
                let line: Value = serde_json::from_str(&line).unwrap();
                if pick(&line) {
                    return line;
                }
            }
        })
        .await
        .expect("the line within 20 s")
    }

    async fn ok(&mut self, m: &str, params: Value) -> Value {
        let id = self.next;
        self.next += 1;
        self.input.send(Message::request(id, m, params).to_line()).await.unwrap();
        let reply = self.line(|line| line["id"] == json!(id)).await;
        assert!(reply.get("error").is_none(), "{m}: {reply}");
        reply["result"].clone()
    }
}

/// Waits up to 20 s for `done`.
async fn until(what: &str, done: impl Fn() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(20);
    while !done() {
        assert!(Instant::now() < deadline, "{what} within 20 s");
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
}

fn taken(ring: &crate::gauges::Latencies) -> u64 {
    ring.status()["count"].as_u64().unwrap()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_attach_is_a_sample_and_a_record_is_timed_to_its_last_connection() {
    let home = tempfile::tempdir().unwrap();
    let hub = hub(home.path());
    let req = crate::hub::NewRequest { cwd: Some(std::env::temp_dir()), ..Default::default() };
    let s = hub.new_session(req).await.unwrap();
    let id = s.id.clone();

    // Two connections open the chat. The rings are the process's, which other tests share, so
    // each count is at least this test's.
    let attaches = crate::gauges::attach_latency();
    let before = taken(attaches);
    let mut a = Client::connect(&hub).await;
    let mut b = Client::connect(&hub).await;
    a.ok(method::MUX_ATTACH, json!({"sessionId": id, "eventStream": true})).await;
    b.ok(method::MUX_ATTACH, json!({"sessionId": id, "eventStream": true})).await;
    until("two attach samples", || taken(attaches) >= before + 2).await;

    // A record of the chat: its fan-out clock waits for both connections' fan-out tasks, and
    // reaches none owed once each has queued it.
    let mut events = hub.subscribe();
    hub.append(&s, "mux", "note", json!({"text": "fan me out"}));
    let ev = tokio::time::timeout(Duration::from_secs(20), async {
        loop {
            let ev = events.recv().await.unwrap();
            if ev.session_id == id && ev.record.kind == "note" {
                return ev;
            }
        }
    })
    .await
    .expect("the note's event");
    assert!(ev.row.fanout.sent(), "the send started its clock");
    until("both connections took the note", || ev.row.fanout.owed() == 0).await;

    // `daemon status` carries both, under the names the hq sampler reads.
    let status = a.ok(method::MUX_STATUS, json!({})).await;
    for gauge in ["attach", "fanout"] {
        let g = &status["gauges"][gauge];
        assert!(g["count"].as_u64().is_some_and(|n| n >= 1), "{gauge}: {g}");
        assert!(g["p95Ms"].as_f64().is_some(), "{gauge}: {g}");
        assert!(g["p50Ms"].as_f64() <= g["p95Ms"].as_f64(), "{gauge}: {g}");
        assert!(g["p95Ms"].as_f64() <= g["maxMs"].as_f64(), "{gauge}: {g}");
    }
    let fanout = &status["gauges"]["fanout"];
    assert!(fanout["dropped"].as_u64().is_some(), "{fanout}");
    assert!(fanout["resyncs"].as_u64().is_some(), "{fanout}");
    drop((a, b, s));
    hub.shutdown_all().await;
}
