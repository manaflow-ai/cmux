//! Fault `flood-bulk` (cmuxterm-hq `docs/design/remote-cloud-durability.md` F18, H13): bulk
//! replays fill a connection's outbound stream, and the cheap reads asked on it (identify, the
//! session list, host health, status) still answer at once. Before, every line went into one
//! queue in order, so an `initialize` answer waited behind every replay line queued before it:
//! the broker's 1.2 s read that took 40-100 s (cmuxterm-hq #11963), here on the daemon's links.

use super::*;
use crate::config::{Config, StoreMode};
use std::time::Duration;

/// What the design allows a cheap read under a flood (F18).
const READ_BUDGET: Duration = Duration::from_millis(200);
/// The bulk replays that hold the connection, and each one's lines.
const REPLAYS: usize = 4;
const LINES_PER_REPLAY: usize = 1_500;
/// The link's bandwidth, as the test's reader takes lines: 8 MiB/s, so the 4 replays
/// (about 12 MiB) take over a second to read.
const BYTES_PER_MS: usize = 8 << 10;

fn hub() -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({})).unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

/// One replayed event of `session`, about 2 KiB as a long agent message is.
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

/// The served connection whose `initialize` named it `name`.
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

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn flood_bulk_cheap_reads_answer_while_four_replays_hold_the_link() {
    let hub = hub();
    let (tx, incoming) = mpsc::channel(64);
    let (output, mut rx) = mpsc::channel::<String>(4096);
    tokio::spawn(serve_connection_with(hub.clone(), incoming, output, Origin::Local));
    let name = format!("flood-bulk-{}", std::process::id());
    tx.send(
        Message::request(
            1,
            method::INITIALIZE,
            json!({"protocolVersion": 1, "clientInfo": {"name": name}}),
        )
        .to_line(),
    )
    .await
    .unwrap();
    let first = tokio::time::timeout(Duration::from_secs(10), rx.recv()).await.unwrap().unwrap();
    assert!(first.contains("\"id\":1"), "{first}");
    let conn = conn_named(&name).await;

    // The flood: four replays, every line queued on the connection the way a hub event's line is
    // (`Conn::send_line`), before any read is asked.
    for n in 0..LINES_PER_REPLAY {
        for session in 0..REPLAYS {
            conn.send_line(&replay_line(session, n));
        }
    }

    // The reader: a link of fixed bandwidth, noting when each answer arrives and checking that
    // every replayed line still comes, in order per chat.
    let started = tokio::time::Instant::now();
    let (answers_tx, mut answers) = mpsc::unbounded_channel::<(Value, Duration)>();
    let reader = tokio::spawn(async move {
        let mut owed = 0usize;
        let mut next_seq = [0u64; REPLAYS];
        let mut replayed = 0usize;
        while replayed < REPLAYS * LINES_PER_REPLAY {
            let line = tokio::time::timeout(Duration::from_secs(60), rx.recv())
                .await
                .expect("the replays keep coming")
                .expect("the connection stays open");
            owed += line.len();
            if owed >= BYTES_PER_MS * 4 {
                tokio::time::sleep(Duration::from_millis((owed / BYTES_PER_MS) as u64)).await;
                owed = 0;
            }
            let value: Value = serde_json::from_str(&line).unwrap();
            if value.get("method").is_none() {
                let _ = answers_tx.send((value, started.elapsed()));
                continue;
            }
            let session = value["params"]["sessionId"].as_str().unwrap_or("");
            let Some(n) = session.strip_prefix("replay-").and_then(|n| n.parse::<usize>().ok())
            else {
                continue;
            };
            assert_eq!(value["params"]["seq"], next_seq[n], "replay {n} in order, none dropped");
            next_seq[n] += 1;
            replayed += 1;
        }
    });

    let reads = [
        (2, method::INITIALIZE, json!({"protocolVersion": 1, "clientInfo": {"name": name}})),
        (3, method::SESSION_LIST, json!({})),
        (4, "_acpmux/host_health", json!({})),
    ];
    for (id, m, params) in &reads {
        tx.send(Message::request(*id, m, params.clone()).to_line()).await.unwrap();
    }
    let mut late = Vec::new();
    for _ in 0..reads.len() {
        let (answer, at) = tokio::time::timeout(Duration::from_secs(60), answers.recv())
            .await
            .expect("every read is answered")
            .expect("the reader is still reading");
        assert!(answer.get("error").is_none(), "{answer}");
        if at > READ_BUDGET {
            late.push(format!("id {} after {} ms", answer["id"], at.as_millis()));
        }
    }
    reader.await.expect("every replayed line came, in order");
    assert!(
        late.is_empty(),
        "cheap reads waited behind {REPLAYS} bulk replays past {} ms: {late:?}",
        READ_BUDGET.as_millis()
    );
    drop((tx, conn));
}
