//! An agent's tool call while bulk holds the link (Leo, 2026-11-25: "if we own the transport
//! layer, could we also optimize for these cases?"). A chat's `last`, `send_status`, `bg_output`
//! or `who_else` on a peer link's far daemon is answered on the same connection that carries the
//! far chats' replays and streams. With only the cheap reads in the read lane (`flood_bulk.rs`), a
//! tool call's answer waited behind every replay line queued before it.
//!
//! The reader is paced at [`BYTES_PER_MS`] in wall time, as a link of that speed reads, while the
//! calls are asked every few ms from [`CALLERS`] concurrent callers, so each answer's latency is
//! measured from its request to its arrival, on this machine's load as it is:
//! `cargo test -p acpmux --lib flood_interactive -- --nocapture`.

use crate::config::{Config, StoreMode};
use crate::server::*;
use std::time::{Duration, Instant};

/// The bulk replays that hold the link, and each one's lines (about 2 KiB each): 24 MiB in all.
const REPLAYS: usize = 8;
const LINES_PER_REPLAY: usize = 1_500;
/// The link's bandwidth: 16 MiB/s, so the replays take about 1.5 s to read.
const BYTES_PER_MS: usize = 16 << 10;
/// Concurrent callers (agent chats) and the tool calls each asks under the flood.
const CALLERS: usize = 16;
const CALLS_PER_CALLER: usize = 4;
/// What an agent's tool call may wait under a flood: the bulk window at link speed plus room
/// for this machine's load.
const CALL_P99_BUDGET: Duration = Duration::from_millis(250);

fn hub() -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({})).unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

fn replay_line(session: usize, n: usize) -> String {
    Message::notification(
        "session/update",
        json!({
            "sessionId": format!("replay-{session}"),
            "seq": n,
            "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "r".repeat(2_000)}},
        }),
    )
    .to_line()
}

async fn conn_named(name: &str) -> Arc<Conn> {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    loop {
        if let Some(conn) = queue_gauge::live()
            .into_iter()
            .find(|c| *c.name.lock().unwrap_or_else(|e| e.into_inner()) == name)
        {
            return conn;
        }
        assert!(tokio::time::Instant::now() < deadline, "no connection named {name}");
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
}

/// The tool calls an agent makes of a far machine, each answered by the daemon itself (an answer
/// or a refusal; either is the answer the caller waits on).
fn tool_call(n: usize) -> (&'static str, Value) {
    match n % 6 {
        0 => (method::MUX_EVENTS, json!({"sessionId": "far-chat", "limit": 5})),
        1 => (method::MUX_SEND_STATUS, json!({"sessionId": "far-chat"})),
        2 => (method::MUX_BG_LIST, json!({"sessionId": "far-chat"})),
        3 => (method::MUX_WHO_ELSE, json!({})),
        4 => (method::MUX_WATCH_LS, json!({})),
        _ => (method::MUX_HISTORY, json!({"sessionId": "far-chat", "limit": 5})),
    }
}

fn percentile(sorted: &[Duration], p: usize) -> Duration {
    sorted[(sorted.len() * p / 100).min(sorted.len() - 1)]
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn flood_interactive_tool_calls_answer_while_replays_hold_the_link() {
    let hub = hub();
    let (tx, incoming) = mpsc::channel(256);
    let (output, mut rx) = mpsc::channel::<String>(4096);
    let scope = cmux_scope::Scope::new("flood-interactive-test");
    scope.spawn(serve_connection_with(hub.clone(), incoming, output, Origin::Local));
    let name = format!("flood-interactive-{}", std::process::id());
    tx.send(
        Message::request(
            0,
            method::INITIALIZE,
            json!({"protocolVersion": 1, "clientInfo": {"name": name}}),
        )
        .to_line(),
    )
    .await
    .unwrap();
    let first = tokio::time::timeout(Duration::from_secs(10), rx.recv()).await.unwrap().unwrap();
    assert!(first.contains("\"id\":0"), "{first}");
    let conn = conn_named(&name).await;

    for n in 0..LINES_PER_REPLAY {
        for session in 0..REPLAYS {
            conn.send_line(&replay_line(session, n));
        }
    }

    // The callers: each asks its calls a few ms apart while the reader drains the flood.
    let asked: Arc<std::sync::Mutex<HashMap<i64, Instant>>> = Arc::default();
    for caller in 0..CALLERS {
        let (tx, asked) = (tx.clone(), asked.clone());
        tokio::spawn(async move {
            for k in 0..CALLS_PER_CALLER {
                let id = (1 + caller * CALLS_PER_CALLER + k) as i64;
                let (m, params) = tool_call(id as usize);
                asked.lock().unwrap().insert(id, Instant::now());
                tx.send(Message::request(id, m, params).to_line()).await.unwrap();
                tokio::time::sleep(Duration::from_millis(40 + 7 * caller as u64)).await;
            }
        });
    }

    // The paced reader: a link of `BYTES_PER_MS` in wall time.
    let started = Instant::now();
    let (mut read, mut replayed) = (0usize, 0usize);
    let mut next_seq = [0u64; REPLAYS];
    let mut waits = Vec::new();
    while replayed < REPLAYS * LINES_PER_REPLAY || waits.len() < CALLERS * CALLS_PER_CALLER {
        let line = tokio::time::timeout(Duration::from_secs(60), rx.recv())
            .await
            .expect("the replays and answers keep coming")
            .expect("the connection stays open");
        read += line.len();
        let due = started + Duration::from_micros((read * 1000 / BYTES_PER_MS) as u64);
        if let Some(wait) = due.checked_duration_since(Instant::now()) {
            tokio::time::sleep(wait).await;
        }
        let value: Value = serde_json::from_str(&line).unwrap();
        if value.get("method").is_none() {
            let id = value["id"].as_i64().unwrap();
            let at = asked.lock().unwrap().remove(&id).expect("an answer to a call asked");
            waits.push(at.elapsed());
            continue;
        }
        let Some(n) = value["params"]["sessionId"]
            .as_str()
            .and_then(|s| s.strip_prefix("replay-"))
            .and_then(|n| n.parse::<usize>().ok())
        else {
            continue;
        };
        assert_eq!(value["params"]["seq"], next_seq[n], "replay {n} in order, none dropped");
        next_seq[n] += 1;
        replayed += 1;
    }
    waits.sort();
    let (p50, p99) = (percentile(&waits, 50), percentile(&waits, 99));
    eprintln!(
        "flood_interactive: {} tool calls from {CALLERS} callers under {REPLAYS} replays \
         ({} MiB at {} MiB/s): p50 {} ms, p99 {} ms, max {} ms",
        waits.len(),
        read >> 20,
        BYTES_PER_MS >> 10,
        p50.as_millis(),
        p99.as_millis(),
        waits.last().unwrap().as_millis(),
    );
    assert!(
        p99 <= CALL_P99_BUDGET,
        "tool calls waited behind the bulk replays: p50 {} ms, p99 {} ms",
        p50.as_millis(),
        p99.as_millis()
    );
    drop((tx, conn, scope));
}
