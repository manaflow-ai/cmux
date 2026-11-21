//! What a watcher hears while chats stream and something reads the list over and over
//! (`list_guard.rs` `STREAM_TELL_EVERY`). Leo's Mac, 2026-11-19, nobody using cmux: acpmux sent
//! 312 MB in 90 s, 260 MB to the app and 45 MB to the iPhone host. Each list read (a page, an
//! `acpmux ls`, a peer, a tool) told every streaming chat's whole row to every watching
//! connection, so a watcher's bytes grew with how often anything read the list.
//!
//! Also the `acpmux-watch-bytes` bench (scripts/bench/benches/acpmux_watch_bytes.py): it prints
//! one `ACPMUX-WATCH-BYTES {json}` line before it asserts, so a run on a build without the bound
//! still gives its number.

use super::*;
use std::collections::HashMap;

const CHATS: usize = 20;
/// List reads while every chat streams: one between each chat's chunks.
const READS: usize = 60;

fn hub_with_streaming_chats() -> (Arc<Hub>, Vec<Arc<Session>>) {
    let cfg: crate::config::Config =
        serde_json::from_value(json!({"store": {"mode": "memory"}})).unwrap();
    let hub = Hub::new(
        cfg.clone(),
        crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap(),
    );
    let chats = (0..CHATS)
        .map(|n| {
            let id = format!("live-{n}");
            hub.insert_test_session(
                serde_json::from_value(json!({
                    "schema": crate::store::META_SCHEMA, "id": id, "name": id,
                    "harness": "claude", "family": "claude", "cwd": "/w/repo", "status": "running",
                    "createdAt": 1, "updatedAt": 1, "preview": "earlier reply",
                }))
                .unwrap(),
            )
        })
        .collect();
    (hub, chats)
}

fn stream(hub: &Hub, chat: &Session, n: usize) {
    let update = |update: Value| {
        json!({"jsonrpc": "2.0", "method": "session/update",
               "params": {"sessionId": "agent", "update": update}})
    };
    hub.append(
        chat,
        "in",
        "agent_message_chunk",
        update(json!({"sessionUpdate": "agent_message_chunk",
                      "content": {"type": "text", "text": format!("token {n} of the answer ")}})),
    );
    hub.append(
        chat,
        "in",
        "tool_call_update",
        update(json!({"sessionUpdate": "tool_call_update", "toolCallId": "t1", "status": "in_progress"})),
    );
}

/// The rows told (`session_changed` of kind `row`) on `heard` so far, per chat, and the bytes a
/// watcher without tools was sent for them (the list row `server::deliver` sends).
fn told(
    hub: &Hub,
    heard: &mut tokio::sync::broadcast::Receiver<HubEvent>,
) -> (HashMap<String, usize>, usize) {
    let mut per_chat = HashMap::new();
    let mut bytes = 0;
    while let Ok(event) = heard.try_recv() {
        if event.record.kind != "row" {
            continue;
        }
        *per_chat.entry(event.session_id.clone()).or_default() += 1;
        if let Ok(session) = hub.resolve(&event.session_id) {
            bytes += hub.session_list_summary(&session).to_string().len();
        }
    }
    (per_chat, bytes)
}

/// 20 chats stream (a chunk and a tool update each, between reads) while the list is read 60
/// times. Before, every read told every chat: 1,200 rows, about 2 MB to each watching connection
/// for 60 reads, and a busy Mac reads the list several times a second. Now each chat is told
/// once per `STREAM_TELL_EVERY`, however often the list is read.
#[tokio::test]
async fn a_streaming_chats_row_is_told_once_per_window_however_often_the_list_is_read() {
    let (hub, chats) = hub_with_streaming_chats();
    let mut heard = hub.events.subscribe();
    let started = std::time::Instant::now();
    for read in 0..READS {
        for chat in &chats {
            stream(&hub, chat, read);
        }
        let _ = hub.list_cursor();
    }
    let elapsed = started.elapsed();
    let (per_chat, bytes) = told(&hub, &mut heard);
    let rows: usize = per_chat.values().sum();
    println!(
        "ACPMUX-WATCH-BYTES {}",
        json!({"chats": CHATS, "reads": READS, "rows_told": rows, "watcher_bytes": bytes,
               "bytes_per_read": bytes / READS, "elapsed_ms": elapsed.as_millis() as u64})
    );
    assert!(elapsed < std::time::Duration::from_secs(4), "the reads took {elapsed:?}");
    for chat in &chats {
        let n = per_chat.get(&chat.id).copied().unwrap_or(0);
        assert!(
            n <= 1,
            "{} was told {n} times in {READS} reads within {elapsed:?}: {rows} rows, {bytes} bytes \
             to each watcher",
            chat.id
        );
    }
}

/// A row held back for its window is told at the first read after it, at a later list position:
/// a follow from a cursor taken before it sends the row (#42091 F1), and a change no stream
/// makes (an attach, a respawn's mark) is still told at the next read whatever the window.
#[tokio::test]
async fn a_held_streaming_row_is_told_at_the_first_read_after_its_window() {
    let (hub, chats) = hub_with_streaming_chats();
    hub.events.set_stream_tell_every(std::time::Duration::from_millis(200));
    let chat = &chats[0];
    let mut heard = hub.events.subscribe();
    stream(&hub, chat, 0);
    let _ = hub.list_cursor();
    assert_eq!(
        told(&hub, &mut heard).0.get(&chat.id),
        Some(&1),
        "the first change is told at once"
    );

    stream(&hub, chat, 1);
    let head = hub.list_cursor().0;
    assert_eq!(told(&hub, &mut heard).0.get(&chat.id), None, "held within its window");
    assert!(hub.events.stream_untold(&chat.id));

    // Not a stream change: told at the next read, window or not.
    hub.mark_profile_respawn(chat);
    let _ = hub.list_cursor();
    assert_eq!(
        told(&hub, &mut heard).0.get(&chat.id),
        Some(&1),
        "a respawn's mark waits for no window"
    );
    assert!(!hub.events.stream_untold(&chat.id), "its row carried the stream too");

    stream(&hub, chat, 2);
    let head_held = hub.list_cursor().0;
    assert!(hub.events.stream_untold(&chat.id));
    tokio::time::sleep(std::time::Duration::from_millis(250)).await;
    let _ = hub.list_cursor();
    let follow = hub.list_follow(head_held, false, false, usize::MAX).expect("the log follows it");
    let follow: Value = serde_json::from_str(&follow.text).unwrap();
    let ids: Vec<&str> = follow["sessions"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|r| r["sessionId"].as_str())
        .collect();
    assert_eq!(ids, [chat.id.as_str()], "a follow from before it sends the held row");
    assert!(head_held >= head);
    assert_eq!(told(&hub, &mut heard).0.get(&chat.id), Some(&1), "told once its window passed");
}
