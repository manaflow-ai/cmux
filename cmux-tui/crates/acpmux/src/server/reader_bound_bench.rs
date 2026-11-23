//! Resident memory after 1 GiB of a chat's events reaches a reader that stopped reading (rework
//! stage 3, `docs/design/acpmux-otp-rework.md` C1 to C4). Leo's Mac, 2026-11-12: the daemon grew to
//! 11 GB within 15 minutes of starting, attached to a chat whose log is 1.09 GB.
//!
//! The reader is a real socket client (`serve_stream`, a unix socket pair): it initializes,
//! attaches to one chat and then reads nothing more, as a stopped or hung app does. The chat then
//! streams [`EVENTS`] events of `bytes` each. The god chat streams 1 MiB events (1 GiB in all),
//! the small one 1 KiB events; `none` streams the god chat's events with no reader at all, which
//! is what the hub's own event ring keeps.
//!
//! Only this crate's API from before the fix is used, so the same file measures both sides:
//! `cargo test -p acpmux --release --lib reader_bound_bench -- --ignored --nocapture --test-threads=1`.

use crate::config::{Config, StoreMode};
use crate::rpc::{Message, method};
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

const EVENTS: usize = 1024;
const GOD_BYTES: usize = 1 << 20;
const SMALL_BYTES: usize = 1 << 10;
/// What the daemon may hold for one stopped reader past what it held before (the outbound bound,
/// 64 MiB, plus the hub's event ring's, 64 MiB, plus slack for the allocator).
const GROWTH_BOUND: usize = 160 << 20;

/// This process's resident memory in bytes (Linux `/proc/self/statm`); a bench that cannot read
/// it fails rather than report no growth.
fn rss() -> usize {
    let statm = std::fs::read_to_string("/proc/self/statm").expect("/proc/self/statm");
    let pages: usize = statm
        .split_whitespace()
        .nth(1)
        .and_then(|p| p.parse().ok())
        .expect("resident pages in /proc/self/statm");
    pages * 4096
}

fn chunk(id: &str, text: &str) -> Value {
    json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": id,
        "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}}}})
}

/// A socket client's two halves: dropping them closes the socket.
type Reader = (
    tokio::io::Lines<BufReader<tokio::net::unix::OwnedReadHalf>>,
    tokio::net::unix::OwnedWriteHalf,
);

/// A stopped reader: a socket client attached to `id` that reads nothing after the attach
/// answers.
async fn stopped_reader(hub: &Arc<crate::hub::Hub>, id: &str) -> Reader {
    let (server, client) = tokio::net::UnixStream::pair().unwrap();
    hub.scope.spawn_named(
        "reader-bound-conn",
        super::stream::serve_stream(
            hub.clone(),
            server,
            None,
            false,
            crate::sender_harness::SocketPeer::Unknown,
            None,
        ),
    );
    let (rd, mut wr) = client.into_split();
    let hello =
        json!({"protocolVersion": 1, "clientInfo": {"name": "reader-bound", "version": "0"}});
    wr.write_all(Message::request(1, method::INITIALIZE, hello).to_line().as_bytes())
        .await
        .unwrap();
    let attach = json!({"sessionId": id, "waitLogs": false, "limit": 0});
    wr.write_all(Message::request(2, method::MUX_ATTACH, attach).to_line().as_bytes())
        .await
        .unwrap();
    let mut lines = BufReader::new(rd).lines();
    tokio::time::timeout(Duration::from_secs(30), async {
        while let Some(line) = lines.next_line().await.unwrap() {
            let reply: Value = serde_json::from_str(&line).unwrap_or_default();
            if reply["id"] == 2 {
                assert!(reply.get("error").is_none(), "{reply}");
                return;
            }
        }
        panic!("the connection ended before the attach answered");
    })
    .await
    .expect("the attach answers");
    (lines, wr)
}

/// RSS before and after `id`'s [`EVENTS`] events of `bytes` each, with a stopped reader or none.
async fn measure(name: &str, bytes: usize, reader: bool) -> (usize, usize) {
    let dir = tempfile::tempdir().unwrap();
    let mut config = Config::default();
    config.store.mode = StoreMode::Local;
    let store = crate::store::open(&config.store, dir.path()).unwrap();
    let id = "reader-bound-chat";
    let meta: crate::store::SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": id, "name": "lane", "harness": "claude",
        "cwd": "/tmp", "status": "running", "createdAt": 1, "updatedAt": 1
    }))
    .unwrap();
    store.save(&meta).unwrap();
    let hub = crate::hub::Hub::new(config, store);
    let session = hub.make_session(meta);
    hub.sessions.lock().unwrap().insert(id.to_owned(), session.clone());
    let _reader = if reader { Some(stopped_reader(&hub, id).await) } else { None };
    tokio::time::sleep(Duration::from_millis(500)).await;
    let before = rss();
    let text = "x".repeat(bytes);
    for _ in 0..EVENTS {
        hub.append(&session, "in", "agent_message_chunk", chunk(id, &text));
        tokio::task::yield_now().await;
    }
    drop(text);
    // The fan-out and the writer take what they will.
    tokio::time::sleep(Duration::from_secs(5)).await;
    let after = rss();
    eprintln!(
        "READER-BOUND {name}: events {EVENTS} x {bytes} B ({} MiB sent), rss before {} MiB, after {} MiB, growth {} MiB",
        (EVENTS * bytes) >> 20,
        before >> 20,
        after >> 20,
        after.saturating_sub(before) >> 20
    );
    (before, after)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "bench: 1 GiB of events; run with --ignored --nocapture --test-threads=1"]
async fn reader_bound_bench_god_stopped_reader() {
    let (before, after) = measure("god stopped", GOD_BYTES, true).await;
    assert!(
        after.saturating_sub(before) < GROWTH_BOUND,
        "a stopped reader of a god chat grew the daemon by {} MiB",
        after.saturating_sub(before) >> 20
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "bench: run with --ignored --nocapture --test-threads=1"]
async fn reader_bound_bench_small_stopped_reader() {
    measure("small stopped", SMALL_BYTES, true).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "bench: 1 GiB of events; run with --ignored --nocapture --test-threads=1"]
async fn reader_bound_bench_god_no_reader() {
    let (before, after) = measure("god no reader", GOD_BYTES, false).await;
    assert!(
        after.saturating_sub(before) < GROWTH_BOUND,
        "the hub's event ring alone grew the daemon by {} MiB",
        after.saturating_sub(before) >> 20
    );
}
