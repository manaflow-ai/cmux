//! One god chat: a single chat whose log is hundreds of MB to GBs (months of turns, tool output
//! in the MBs), restarted, opened and streamed into while many connections watch it, one of them
//! stalled.
//!
//! Leo, 2026-11-12: "simulate my god-chats? like a true gb-level history sample and stuff, and
//! also simulate restarts? ... simulate streaming text and acpmux along with lots of
//! connectivity? like truly degenerated cases/states and seeing where we can identify more perf
//! to tackle".
//!
//! `stress::store` holds thousands of small chats; this holds one huge one. Each check runs at
//! a small history ([`SMALL_BYTES`]) and at the god size ([`god_bytes`]) and fails when the cost
//! of the operation grows with the history around it:
//!
//! - restart: a new store and `Hub::new` over the chat (the daemon's start, its log restore
//!   included), in bytes the process reads (`/proc/self/io` `rchar`) and milliseconds;
//! - open: `_acpmux/attach` of the chat as the app opens it, in bytes read and reply bytes;
//! - stream: one agent text delta through `Hub::append`, in bytes read and written, with
//!   [`WATCHERS`] attached connections, one never reading: every other one still receives every
//!   delta, and the stalled one holds no more memory per delta.
//!
//! The god size is 48 MB by default, a run of seconds; the GB run, for numbers:
//! `ACPMUX_STRESS_GOD_MB=1024 cargo test -p acpmux --lib stress::god_chat -- --ignored --nocapture`.
//! Every line it prints starts `STRESS`.

use super::*;
use crate::config::{Config, StoreMode};
use crate::hub::Hub;
use crate::rpc::Message;
use crate::store::{EventRecord, META_SCHEMA, SessionMeta};
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::{Duration, Instant};

const SMALL_BYTES: u64 = 1 << 20;
const GOD: &str = "god";
/// Attached connections while the chat streams; the first never reads its output.
const WATCHERS: usize = 32;
/// Deltas streamed per measured run.
const DELTAS: u64 = 2_000;

/// The god chat's log size: `ACPMUX_STRESS_GOD_MB` (default 48) MB.
fn god_bytes() -> u64 {
    let mb = std::env::var("ACPMUX_STRESS_GOD_MB").ok().and_then(|v| v.trim().parse().ok());
    mb.unwrap_or(48u64) << 20
}

/// Bytes this whole process has read (`rchar`): the restore runs on worker threads.
fn process_read() -> u64 {
    let text = std::fs::read_to_string("/proc/self/io").unwrap();
    io_field(&text, "rchar").unwrap()
}

fn process_written() -> u64 {
    let text = std::fs::read_to_string("/proc/self/io").unwrap();
    io_field(&text, "wchar").unwrap()
}

fn config() -> Config {
    let mut cfg = Config::default();
    cfg.store.mode = StoreMode::Local;
    cfg
}

fn update(kind: &str, update: Value) -> Value {
    let mut update = update;
    update["sessionUpdate"] = json!(kind);
    json!({"jsonrpc": "2.0", "method": "session/update",
           "params": {"sessionId": "agent-god", "update": update}})
}

/// One turn as a long agent chat logs it: the prompt, its start, 40 text deltas, a tool call
/// whose output is 16 KB (a build log, a file read), and its result.
fn turn(turn: u64, seq: &mut u64, at: u64) -> Vec<EventRecord> {
    let mut out = Vec::with_capacity(45);
    let mut push = |dir: &str, kind: &str, msg: Value| {
        *seq += 1;
        out.push(EventRecord {
            seq: *seq,
            at: at + *seq % 1_000,
            dir: dir.into(),
            kind: kind.into(),
            msg,
            host_seq: None,
        });
    };
    let id = format!("t{turn}");
    push(
        "mux",
        "user_message",
        json!({"text": format!("step {turn}: keep going on the refactor"), "turnId": id}),
    );
    push("mux", "turn_started", json!({"turnId": id}));
    for d in 0..40 {
        push(
            "in",
            "agent_message_chunk",
            update(
                "agent_message_chunk",
                json!({"messageId": format!("m{turn}"),
                       "content": {"type": "text", "text": format!("delta {d} of reply {turn}, the usual run of words an agent streams out. ")}}),
            ),
        );
    }
    let call = format!("call-{turn}");
    push(
        "in",
        "tool_call",
        update(
            "tool_call",
            json!({"toolCallId": call, "title": "cargo build", "kind": "execute", "status": "pending"}),
        ),
    );
    push(
        "in",
        "tool_call_update",
        update(
            "tool_call_update",
            json!({"toolCallId": call, "status": "completed",
                   "content": [{"type": "content", "content": {"type": "text", "text": "   Compiling acpmux v0.1.0\n".repeat(600)}}]}),
        ),
    );
    push("mux", "turn_result", json!({"turnId": id, "status": "completed"}));
    out
}

/// A home whose one chat has a log of at least `bytes`, saved as a clean stop leaves it.
fn fill(bytes: u64) -> (tempfile::TempDir, u64) {
    let home = tempfile::tempdir().unwrap();
    let cfg = config();
    let store = crate::store::open(&cfg.store, home.path()).unwrap();
    let meta = |last_seq: u64| -> SessionMeta {
        serde_json::from_value(json!({
            "schema": META_SCHEMA, "id": GOD, "name": "god chat", "harness": "fake", "cwd": "/w", "status": "idle", "createdAt": 1,
            "updatedAt": 2, "lastSeq": last_seq, "eventCount": last_seq,
        }))
        .unwrap()
    };
    store.save(&meta(0)).unwrap();
    let (mut seq, mut n) = (0, 0);
    // Four months of turns: a turn's records share its minute.
    let start = 1_760_000_000_000;
    loop {
        for r in turn(n, &mut seq, start + n * 60_000) {
            store.append(GOD, &r).unwrap();
        }
        n += 1;
        if n % 64 == 0 && disk_bytes(home.path()) >= bytes {
            break;
        }
    }
    store.save(&meta(seq)).unwrap();
    store.flush().unwrap();
    store.close_log(GOD);
    (home, seq)
}

async fn connect(
    hub: &Arc<Hub>,
) -> (tokio::sync::mpsc::Sender<String>, tokio::sync::mpsc::Receiver<String>) {
    let (tx, input) = tokio::sync::mpsc::channel(8);
    let (output, rx) = tokio::sync::mpsc::channel(8);
    tokio::spawn(crate::server::serve_connection(hub.clone(), input, output));
    tx.send(Message::request(1, "initialize", json!({"protocolVersion": 1})).to_line())
        .await
        .unwrap();
    (tx, rx)
}

/// The reply to request `id` on `rx`, with the bytes of its line; notifications before it are
/// passed over.
async fn reply(rx: &mut tokio::sync::mpsc::Receiver<String>, id: u64) -> (Value, usize) {
    loop {
        let line = tokio::time::timeout(Duration::from_secs(60), rx.recv())
            .await
            .expect("a reply within 60 s")
            .expect("the connection stays open");
        let frame: Value = serde_json::from_str(&line).unwrap();
        if frame["id"] == id {
            assert!(frame.get("error").is_none(), "{frame}");
            return (frame["result"].clone(), line.len());
        }
    }
}

/// The app's open of the chat: its newest page, without waiting for the full restore.
fn attach(id: u64) -> String {
    Message::request(
        id,
        crate::rpc::method::MUX_ATTACH,
        json!({"sessionId": GOD, "waitLogs": false}),
    )
    .to_line()
}

struct Costs {
    log_mb: f64,
    restart_read: f64,
    restart_ms: f64,
    open_read: f64,
    open_reply: f64,
    open_ms: f64,
    delta_read: f64,
    delta_written: f64,
    delta_us: f64,
    stalled_rss_per_delta: f64,
}

/// Restart, open and stream at one history size, in this process (the meters are process-wide).
fn costs(bytes: u64) -> Costs {
    let (home, last_seq) = fill(bytes);
    let log_mb = disk_bytes(home.path()) as f64 / (1 << 20) as f64;
    let runtime =
        tokio::runtime::Builder::new_multi_thread().worker_threads(2).enable_all().build().unwrap();
    runtime.block_on(async {
        // Restart: the store opened again and the daemon's hub over it, its restore included.
        let (read, wall) = (process_read(), Instant::now());
        let cfg = config();
        let hub = Hub::new(cfg.clone(), crate::store::open(&cfg.store, home.path()).unwrap());
        let restart_read = (process_read() - read) as f64;
        let restart_ms = wall.elapsed().as_secs_f64() * 1e3;
        let session = hub.sessions().into_iter().find(|s| s.id == GOD).expect("the god chat is listed");
        assert_eq!(session.meta().last_seq, last_seq, "the restart sees the whole log");

        // Open: the first connection attaches as the app does.
        let mut watchers = Vec::new();
        let (tx, mut rx) = connect(&hub).await;
        reply(&mut rx, 1).await;
        let (read, wall) = (process_read(), Instant::now());
        tx.send(attach(2)).await.unwrap();
        let (page, open_reply) = reply(&mut rx, 2).await;
        let open_read = (process_read() - read) as f64;
        let open_ms = wall.elapsed().as_secs_f64() * 1e3;
        assert!(page["events"].as_array().is_some_and(|e| !e.is_empty()), "the open shows a page");
        watchers.push((tx, rx));
        for _ in 1..WATCHERS {
            let (tx, mut rx) = connect(&hub).await;
            reply(&mut rx, 1).await;
            tx.send(attach(2)).await.unwrap();
            reply(&mut rx, 2).await;
            watchers.push((tx, rx));
        }
        // The first watcher stops reading: its output fills and stays full.
        let (stalled_tx, stalled_rx) = watchers.remove(0);
        let mut readers = Vec::new();
        for (tx, mut rx) in watchers {
            readers.push(tokio::spawn(async move {
                let _keep = tx;
                // A notification may carry several deltas: count each delta's index once.
                let mut seen = std::collections::HashSet::new();
                while (seen.len() as u64) < DELTAS {
                    let Ok(Some(line)) =
                        tokio::time::timeout(Duration::from_secs(60), rx.recv()).await
                    else {
                        break;
                    };
                    for part in line.split("god-stream-delta ").skip(1) {
                        let digits: String = part.chars().take_while(char::is_ascii_digit).collect();
                        if let Ok(i) = digits.parse::<u64>() {
                            seen.insert(i);
                        }
                    }
                }
                seen.len() as u64
            }));
        }

        // Stream: agent text deltas into the god chat, as a reply streams.
        let warm = DELTAS / 10;
        let delta = |i: u64| {
            update(
                "agent_message_chunk",
                json!({"messageId": "m-live", "content": {"type": "text", "text": format!("god-stream-delta {i} ")}}),
            )
        };
        for i in 0..warm {
            hub.append(&session, "in", "agent_message_chunk", delta(i));
        }
        let rss_before = rss_bytes().unwrap_or(0) as f64;
        let (read, written, wall) = (process_read(), process_written(), Instant::now());
        for i in warm..DELTAS {
            hub.append(&session, "in", "agent_message_chunk", delta(i));
            if i % 64 == 0 {
                tokio::task::yield_now().await;
            }
        }
        let ops = (DELTAS - warm) as f64;
        let delta_us = wall.elapsed().as_secs_f64() * 1e6 / ops;
        let delta_read = (process_read() - read) as f64 / ops;
        let delta_written = (process_written() - written) as f64 / ops;
        let stalled_rss_per_delta = (rss_bytes().unwrap_or(0) as f64 - rss_before).max(0.0) / ops;
        for (i, reader) in readers.into_iter().enumerate() {
            let seen = reader.await.unwrap();
            assert_eq!(seen, DELTAS, "watcher {} of {WATCHERS} beside a stalled one got {seen} of {DELTAS} deltas", i + 2);
        }
        drop((stalled_tx, stalled_rx));
        Costs {
            log_mb,
            restart_read,
            restart_ms,
            open_read,
            open_reply: open_reply as f64,
            open_ms,
            delta_read,
            delta_written,
            delta_us,
            stalled_rss_per_delta,
        }
    })
}

fn print(size: &str, c: &Costs) {
    eprintln!(
        "STRESS god chat {size}: log={:.1} MB restart read={:.0} B in {:.1} ms; open read={:.0} B \
         reply={:.0} B in {:.1} ms; per delta read={:.0} B written={:.0} B {:.1} us, \
         rss {:.0} B/delta with a stalled watcher of {WATCHERS}",
        c.log_mb,
        c.restart_read,
        c.restart_ms,
        c.open_read,
        c.open_reply,
        c.open_ms,
        c.delta_read,
        c.delta_written,
        c.delta_us,
        c.stalled_rss_per_delta,
    );
}

/// In a process of its own: bytes read and memory are counted for the whole process. Manual,
/// as `update_cost_bench` is: CI runs no new perf test (root CLAUDE.md).
#[test]
#[ignore = "manual god-chat stress: cargo test -p acpmux --lib stress::god_chat -- --ignored --nocapture"]
fn a_god_chat_restarts_opens_and_streams_as_a_small_one_does() {
    isolated("stress::god_chat::god_chat_alone");
}

#[test]
fn god_chat_alone() {
    if !in_child() {
        return;
    }
    let small = costs(SMALL_BYTES);
    print("small", &small);
    let god = costs(god_bytes());
    print("god", &god);
    // Fixed costs (the store's files, the hub's state files) sit under each floor; what grows
    // with the log is over it.
    assert_flat_with_size(
        "god chat restart bytes read",
        small.restart_read,
        god.restart_read,
        1 << 20,
    );
    assert_flat_with_size(
        "god chat open bytes read",
        small.open_read,
        god.open_read,
        256.0 * 1024.0,
    );
    assert_flat_with_size(
        "god chat open reply bytes",
        small.open_reply,
        god.open_reply,
        64.0 * 1024.0,
    );
    assert_flat_with_size("god chat bytes read per delta", small.delta_read, god.delta_read, 512.0);
    assert_flat_with_size(
        "god chat bytes written per delta",
        small.delta_written,
        god.delta_written,
        512.0,
    );
    // A stalled watcher's queue is bounded: memory per delta is noise, not the delta's bytes
    // times the deltas it missed.
    assert!(
        god.stalled_rss_per_delta < 4096.0,
        "a stalled watcher holds {:.0} B per delta",
        god.stalled_rss_per_delta
    );
}
