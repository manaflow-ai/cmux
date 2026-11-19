//! Hello and attach latency at 50, 500 and 5,000 chats, with a long chat on disk and concurrent
//! heavy opens running: the harness behind the numbers of the attach-scan fix (Leo, 2026-11-18,
//! "Waiting for the agent service": `acpmux daemon status` answered in 4.9 to 11.8 s).
//!
//! Off by default (it writes ~30 MB per size); run it with
//! `ACPMUX_ATTACH_BENCH=1 cargo test -p acpmux --release attach_latency_bench -- --nocapture`.
//! `ACPMUX_ATTACH_BENCH_SIZES=50,500` picks the sizes. Each size prints one line:
//! `attach-bench chats=N hello_p50_ms= hello_p95_ms= attach_p50_ms= attach_p95_ms= ...`.
//!
//! What it does, per size: a store of N small chats (a few turns each) and one long chat (about
//! 25 MB in 64 KiB segments, ~400 of them) whose saved settled view is from its first turn, as an
//! app left open for hours leaves it. Eight loops open the long chat with `settled` (the
//! sampled hot path) and page its log forward from its start for its prompts, while the
//! measured loop connects anew, says hello, and opens a random small chat's newest page, 200
//! times. The runtime has four workers, so a read that holds workers shows in the hello.

use crate::config::{Config, StoreMode};
use crate::rpc::{Message, method};
use crate::store::{LocalStore, SessionMeta, Store};
use serde_json::{Value, json};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};
use tokio::sync::mpsc;

const LONG: &str = "long-chat";

fn meta(id: &str) -> SessionMeta {
    serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": id, "name": id, "harness": "claude",
        "cwd": "/tmp", "status": "idle", "createdAt": 3, "updatedAt": 3,
    }))
    .unwrap()
}

fn rec(seq: u64, dir: &str, kind: &str, msg: Value) -> crate::store::EventRecord {
    crate::store::EventRecord { seq, at: seq, dir: dir.into(), kind: kind.into(), msg, host_seq: None }
}

/// One turn's three records from `seq`.
fn turn_records(id: &str, seq: u64, n: u64, text: &str) -> [crate::store::EventRecord; 3] {
    [
        rec(seq, "mux", "user_message", json!({"text": format!("prompt {n}"), "promptId": format!("p{n}")})),
        rec(
            seq + 1,
            "in",
            "session/update",
            json!({"method": "session/update", "params": {"sessionId": id, "update": {
                "sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}}}}),
        ),
        rec(seq + 2, "mux", "turn_result", json!({"status": "completed", "turnId": format!("t{n}"), "turnSeq": n})),
    ]
}

fn open_params(id: &str, settled: bool) -> Value {
    json!({"sessionId": id, "waitLogs": false, "limit": 400, "maxBytes": 131072,
        "kinds": ["transcript"], "eventStream": false, "settled": settled})
}

struct Client {
    input: mpsc::Sender<String>,
    output: mpsc::Receiver<String>,
    next: u64,
}

impl Client {
    fn connect(hub: &Arc<crate::hub::Hub>) -> Self {
        let (input, incoming) = mpsc::channel(8);
        let (output_tx, output) = mpsc::channel(4096);
        tokio::spawn(super::serve_connection_with(
            hub.clone(),
            incoming,
            output_tx,
            super::Origin::Local,
        ));
        Self { input, output, next: 1 }
    }

    async fn call(&mut self, m: &str, params: Value) -> Value {
        let id = self.next;
        self.next += 1;
        self.input.send(Message::request(id, m, params).to_line()).await.unwrap();
        loop {
            let line = self.output.recv().await.expect("the connection answers");
            let reply: Value = serde_json::from_str(&line).unwrap();
            if reply["id"] == id {
                assert!(reply.get("error").is_none(), "{m}: {reply}");
                return reply["result"].clone();
            }
        }
    }

    async fn hello(&mut self) -> Value {
        self.call(
            method::INITIALIZE,
            json!({"protocolVersion": 1, "clientInfo": {"name": "attach-bench", "version": "0"}}),
        )
        .await
    }
}

fn pct(samples: &mut [f64], p: f64) -> f64 {
    samples.sort_by(f64::total_cmp);
    let at = ((samples.len() as f64 - 1.0) * p).round() as usize;
    samples[at.min(samples.len() - 1)]
}

async fn run(chats: usize) -> String {
    let dir = std::env::temp_dir().join(format!("acpmux-attach-bench-{}", uuid::Uuid::now_v7()));
    let sessions = dir.join("sessions");
    let short = "answer ".repeat(20);
    {
        let writer = LocalStore::new(sessions.clone(), 64 * 1024).unwrap();
        for i in 0..chats {
            let id = format!("chat-{i:05}");
            writer.save(&meta(&id)).unwrap();
            let mut seq = 1;
            for n in 1..=4 {
                for r in turn_records(&id, seq, n, &short) {
                    writer.append(&id, &r).unwrap();
                }
                seq += 3;
            }
            Store::flush_session(&writer, &id).unwrap();
        }
        writer.save(&meta(LONG)).unwrap();
        for r in turn_records(LONG, 1, 1, &short) {
            writer.append(LONG, &r).unwrap();
        }
        Store::flush_session(&writer, LONG).unwrap();
    }
    let mut config = Config::default();
    config.store.mode = StoreMode::Memory;
    let hub = crate::hub::Hub::new(
        config,
        Box::new(LocalStore::new(sessions.clone(), 64 * 1024).unwrap()),
    );
    // The long chat's settled view, from its first turn.
    let long = hub.resolve(LONG).unwrap();
    let key = crate::hub::settled_view::SettledKey::of_attach(&open_params(LONG, true)).unwrap();
    assert!(hub.write_settled_view(&long, &key));
    // Then about 25 MB of turns after it, as hours of an agent's work.
    let chunk = "streamed tool output and reply text ".repeat(28);
    for n in 2..=20_000u64 {
        hub.append(&long, "mux", "user_message", json!({"text": format!("prompt {n}"), "promptId": format!("p{n}")}));
        hub.append(
            &long,
            "in",
            "session/update",
            json!({"method": "session/update", "params": {"sessionId": LONG, "update": {
                "sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": chunk}}}}),
        );
        hub.append(&long, "mux", "turn_result", json!({"status": "completed", "turnId": format!("t{n}"), "turnSeq": n}));
    }
    let tail = long.meta().last_seq.saturating_sub(10);

    // The load: eight loops of heavy opens of the long chat.
    let stop = Arc::new(AtomicBool::new(false));
    let mut load = Vec::new();
    for k in 0..8 {
        let hub = hub.clone();
        let stop = stop.clone();
        load.push(tokio::spawn(async move {
            let mut client = Client::connect(&hub);
            client.hello().await;
            while !stop.load(Ordering::Relaxed) {
                if k % 2 == 0 {
                    client.call(method::MUX_ATTACH, open_params(LONG, true)).await;
                } else {
                    client
                        .call(
                            method::MUX_EVENTS,
                            json!({"sessionId": LONG, "afterSeq": tail, "limit": 50, "kinds": ["transcript"]}),
                        )
                        .await;
                }
            }
        }));
    }
    tokio::time::sleep(Duration::from_millis(300)).await;

    let (mut hellos, mut attaches, mut long_opens) = (Vec::new(), Vec::new(), Vec::new());
    let mut rng = 0x9e37_79b9_7f4a_7c15u64;
    for _ in 0..200 {
        rng ^= rng << 13;
        rng ^= rng >> 7;
        rng ^= rng << 17;
        let id = format!("chat-{:05}", (rng as usize) % chats);
        let mut client = Client::connect(&hub);
        let t = Instant::now();
        client.hello().await;
        hellos.push(t.elapsed().as_secs_f64() * 1e3);
        let t = Instant::now();
        let reply = client.call(method::MUX_ATTACH, open_params(&id, false)).await;
        attaches.push(t.elapsed().as_secs_f64() * 1e3);
        assert!(!reply["events"].as_array().unwrap().is_empty());
        // The long chat's open, as the app's pane opens it, under the same load.
        let t = Instant::now();
        client.call(method::MUX_ATTACH, open_params(LONG, true)).await;
        long_opens.push(t.elapsed().as_secs_f64() * 1e3);
    }
    stop.store(true, Ordering::Relaxed);
    for task in load {
        let _ = tokio::time::timeout(Duration::from_secs(120), task).await;
    }
    let segments = std::fs::read_dir(sessions.join(LONG).join("events")).map_or(0, |d| d.count());
    let _ = std::fs::remove_dir_all(&dir);
    format!(
        "attach-bench chats={chats} long_segments={segments} hello_p50_ms={:.2} hello_p95_ms={:.2} attach_p50_ms={:.2} attach_p95_ms={:.2} long_attach_p50_ms={:.2} long_attach_p95_ms={:.2}",
        pct(&mut hellos, 0.5),
        pct(&mut hellos, 0.95),
        pct(&mut attaches, 0.5),
        pct(&mut attaches, 0.95),
        pct(&mut long_opens, 0.5),
        pct(&mut long_opens, 0.95),
    )
}

#[test]
fn attach_latency_bench() {
    if std::env::var_os("ACPMUX_ATTACH_BENCH").is_none() {
        return;
    }
    let sizes: Vec<usize> = std::env::var("ACPMUX_ATTACH_BENCH_SIZES")
        .unwrap_or_else(|_| "50,500,5000".into())
        .split(',')
        .filter_map(|s| s.trim().parse().ok())
        .collect();
    for chats in sizes {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(4)
            .enable_all()
            .build()
            .unwrap();
        let line = runtime.block_on(run(chats));
        println!("{line}");
    }
}
