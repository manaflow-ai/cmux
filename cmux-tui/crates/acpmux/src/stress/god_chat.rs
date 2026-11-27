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
//!   included), in bytes the process reads (`/proc/self/io` `rchar`) and milliseconds, then what
//!   its background work reads until the process goes quiet;
//! - open: `_acpmux/attach` of the chat as the app opens it, in bytes read and reply bytes;
//! - stream: 20,000 agent text deltas through `Hub::append`, in bytes read and written per
//!   delta, with [`WATCHERS`] attached connections whose queues are a daemon's: every reader
//!   receives every delta, and the one that never reads holds at most its queue and the hub's
//!   event ring and is told it lagged (`_acpmux/lagged`), so it reads again instead of the hub
//!   holding every delta for it.
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
/// Deltas streamed per run: more than a connection's queue ([`OUTPUT`]) and the hub's event ring
/// ([`EVENT_RING`]) behind it hold together, so a reader that stops must miss some.
const DELTAS: u64 = 20_000;

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

/// The god chat's own folder (its log segments and their indexes), or the whole home.
fn chat_bytes(store: &dyn crate::store::Store, home: &std::path::Path) -> u64 {
    disk_bytes(&store.session_dir(GOD).unwrap_or_else(|| home.to_path_buf()))
}

/// A home whose one chat has a log of at least `bytes`, saved as a clean stop leaves it, with
/// the log's size on disk.
fn fill(bytes: u64) -> (tempfile::TempDir, u64, u64) {
    let home = tempfile::tempdir().unwrap();
    let cfg = config();
    let store = crate::store::open(&cfg.store, home.path()).unwrap();
    let meta = |last_seq: u64| -> SessionMeta {
        serde_json::from_value(json!({
            "schema": META_SCHEMA, "id": GOD, "name": "god chat", "harness": "fake",
            "cwd": "/w", "status": "idle", "createdAt": 1, "updatedAt": 2,
            "lastSeq": last_seq, "eventCount": last_seq,
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
        if n % 64 == 0 {
            store.flush().unwrap();
            if chat_bytes(store.as_ref(), home.path()) >= bytes {
                break;
            }
        }
    }
    store.save(&meta(seq)).unwrap();
    store.flush().unwrap();
    store.close_log(GOD);
    let size = chat_bytes(store.as_ref(), home.path());
    store.seal();
    (home, seq, size)
}

/// A connection's queues as a daemon's WebSocket has them (`server/mod.rs`): 256 in, 4096 out.
const OUTPUT: usize = 4096;
/// The hub's event ring every connection reads from (`list_guard::Events::new` in `Hub::build`).
const EVENT_RING: usize = 8192;

async fn connect(
    hub: &Arc<Hub>,
) -> (tokio::sync::mpsc::Sender<String>, tokio::sync::mpsc::Receiver<String>) {
    let (tx, input) = tokio::sync::mpsc::channel(256);
    let (output, rx) = tokio::sync::mpsc::channel(OUTPUT);
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

/// The app's open of the chat (webviews `direct.ts` `sendAttach`): its newest 400 records in at
/// most 128 KB, without waiting for the full restore, with the event stream.
fn attach(id: u64) -> String {
    Message::request(
        id,
        crate::rpc::method::MUX_ATTACH,
        json!({"sessionId": GOD, "waitLogs": false, "limit": 400, "maxBytes": 128 * 1024,
               "kinds": ["transcript"], "eventStream": true, "visible": true}),
    )
    .to_line()
}

/// Waits until this process has read nothing more for 300 ms (at most 20 s): the restart's
/// background work (a hub's watchers, the journal's checkpoint). Returns the bytes it read.
async fn settle() -> u64 {
    let (first, deadline) = (process_read(), Instant::now() + Duration::from_secs(20));
    let mut last = first;
    while Instant::now() < deadline {
        tokio::time::sleep(Duration::from_millis(300)).await;
        let now = process_read();
        if now == last {
            break;
        }
        last = now;
    }
    last - first
}

struct Costs {
    log_mb: f64,
    restart_read: f64,
    restart_ms: f64,
    restart_after_read: f64,
    open_read: f64,
    open_reply: f64,
    open_ms: f64,
    delta_read: f64,
    delta_written: f64,
    delta_us: f64,
    rss_per_delta: f64,
    /// Readers (all but the stalled watcher) that missed a delta, and the fewest one got.
    short_readers: usize,
    least_seen: u64,
    stalled_held: usize,
    stalled_told: bool,
}

/// Restart, open and stream at one history size, in this process (the meters are process-wide).
fn costs(bytes: u64) -> Costs {
    let (home, last_seq, log_bytes) = fill(bytes);
    let log_mb = log_bytes as f64 / (1 << 20) as f64;
    let runtime =
        tokio::runtime::Builder::new_multi_thread().worker_threads(2).enable_all().build().unwrap();
    let costs = runtime.block_on(async {
        // Restart: the store opened again and the daemon's hub over it, its restore included.
        let (read, wall) = (process_read(), Instant::now());
        let cfg = config();
        let hub = Hub::new(cfg.clone(), crate::store::open(&cfg.store, home.path()).unwrap());
        let restart_read = (process_read() - read) as f64;
        let restart_ms = wall.elapsed().as_secs_f64() * 1e3;
        let restart_after_read = settle().await as f64;
        let session =
            hub.sessions().into_iter().find(|s| s.id == GOD).expect("the god chat is listed");
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
        let (stalled_tx, mut stalled_rx) = watchers.remove(0);
        let mut readers = Vec::new();
        for (tx, mut rx) in watchers {
            readers.push(tokio::spawn(async move {
                let _keep = tx;
                // A notification may carry several deltas: count each delta's index once.
                let (mut seen, mut lagged) = (std::collections::HashSet::new(), false);
                while (seen.len() as u64) < DELTAS {
                    let Ok(Some(line)) =
                        // timeout: a reader idle 5 s stops; the count it saw is the result.
                        tokio::time::timeout(Duration::from_secs(5), rx.recv()).await
                    else {
                        break;
                    };
                    lagged |= line.contains("_acpmux/lagged");
                    for part in line.split("god-stream-delta ").skip(1) {
                        let digits: String =
                            part.chars().take_while(char::is_ascii_digit).collect();
                        if let Ok(i) = digits.parse::<u64>() {
                            seen.insert(i);
                        }
                    }
                }
                (seen.len() as u64, lagged)
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
        let (read, written) = (process_read(), process_written());
        let mut appending = Duration::ZERO;
        for i in warm..DELTAS {
            let one = Instant::now();
            hub.append(&session, "in", "agent_message_chunk", delta(i));
            appending += one.elapsed();
            // Paced at 16 deltas a millisecond at most (an agent streams far fewer), so the
            // readers run between them; unpaced, a loop of appends outruns the hub's ring and
            // readers lag by design (`_acpmux/lagged`, then a read of `_acpmux/events`).
            if i % 16 == 0 {
                tokio::time::sleep(Duration::from_millis(1)).await;
            }
        }
        let ops = (DELTAS - warm) as f64;
        let delta_us = appending.as_secs_f64() * 1e6 / ops;
        let delta_read = (process_read() - read) as f64 / ops;
        let delta_written = (process_written() - written) as f64 / ops;
        let rss_per_delta = (rss_bytes().unwrap_or(0) as f64 - rss_before).max(0.0) / ops;
        let (mut short_readers, mut least_seen) = (0, DELTAS);
        for reader in readers {
            let (seen, _lagged) = reader.await.unwrap();
            short_readers += usize::from(seen < DELTAS);
            least_seen = least_seen.min(seen);
        }
        // The stalled watcher holds at most its queue and the ring behind it (draining the queue
        // lets its forwarder refill it from the ring), and is told it lagged so it reads again.
        let (mut stalled_held, mut stalled_told) = (0, false);
        while let Ok(line) = stalled_rx.try_recv() {
            stalled_held += 1;
            stalled_told |= line.contains("_acpmux/lagged");
        }
        drop((stalled_tx, stalled_rx));
        drop(session);
        drop(hub);
        Costs {
            log_mb,
            restart_read,
            restart_ms,
            restart_after_read,
            open_read,
            open_reply: open_reply as f64,
            open_ms,
            delta_read,
            delta_written,
            delta_us,
            rss_per_delta,
            short_readers,
            least_seen,
            stalled_held,
            stalled_told,
        }
    });
    // The hub's tasks end with its runtime, before the next size is measured.
    runtime.shutdown_timeout(Duration::from_secs(5));
    costs
}

fn print(size: &str, c: &Costs) {
    eprintln!(
        "STRESS god chat {size}: log={:.1} MB; restart read={:.0} B in {:.1} ms, then {:.0} B \
         in the background; open read={:.0} B reply={:.0} B in {:.1} ms; per delta to \
         {WATCHERS} watchers (1 stalled) read={:.0} B written={:.0} B in {:.1} us, rss {:.0} B; \
         {} readers short (fewest {} of {DELTAS}); the stalled one held {} lines, told it lagged: {}",
        c.log_mb,
        c.restart_read,
        c.restart_ms,
        c.restart_after_read,
        c.open_read,
        c.open_reply,
        c.open_ms,
        c.delta_read,
        c.delta_written,
        c.delta_us,
        c.rss_per_delta,
        c.short_readers,
        c.least_seen,
        c.stalled_held,
        c.stalled_told,
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
    // with the log is over it. Times and memory are printed, not judged: a loaded runner moves them.
    let flat = |what: &str, small: f64, god: f64, floor: f64| {
        assert_flat_with_size(&format!("god chat {what}"), small, god, floor)
    };
    flat("restart bytes read", small.restart_read, god.restart_read, 1024.0 * 1024.0);
    flat(
        "restart background bytes read",
        small.restart_after_read,
        god.restart_after_read,
        1024.0 * 1024.0,
    );
    flat("open bytes read", small.open_read, god.open_read, 256.0 * 1024.0);
    flat("open reply bytes", small.open_reply, god.open_reply, 64.0 * 1024.0);
    flat("bytes read per delta", small.delta_read, god.delta_read, 512.0);
    flat("bytes written per delta", small.delta_written, god.delta_written, 512.0);
    for (size, c) in [("small", &small), ("god", &god)] {
        assert_eq!(
            c.short_readers,
            0,
            "{size}: {} of {} readers beside a stalled one missed deltas (fewest {} of {DELTAS})",
            c.short_readers,
            WATCHERS - 1,
            c.least_seen
        );
        assert!(
            c.stalled_held <= OUTPUT + EVENT_RING,
            "{size}: a stalled watcher held {} lines, past its queue of {OUTPUT} and the ring of \
             {EVENT_RING}",
            c.stalled_held
        );
        assert!(
            c.stalled_told,
            "{size}: a stalled watcher that missed deltas was not told it lagged"
        );
    }
}
