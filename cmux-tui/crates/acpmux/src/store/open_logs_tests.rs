use super::*;
use crate::store::{EventRecord, LocalStore, Store as _};

#[test]
fn the_bound_follows_the_open_file_limit() {
    // Unknown, or launchd's default for a user agent: the bound before it followed the limit.
    assert_eq!(for_limit(None), 64);
    assert_eq!(for_limit(Some(256)), 64);
    assert_eq!(for_limit(Some(1024)), 64);
    assert_eq!(for_limit(Some(4096)), 256);
    // What the daemon raises itself to on macOS, and the Linux default it raises to.
    assert_eq!(for_limit(Some(10_240)), 512);
    assert_eq!(for_limit(Some(65_536)), 512);
    assert_eq!(for_limit(Some(u64::MAX)), 512);
}

/// Writes three records to each of 100 chats in turn, the way 100 streaming chats write, and
/// returns how many log syncs the second and third rounds made (the first opens every log).
fn syncs_while_100_chats_stream(logs: usize) -> u64 {
    let dir = std::env::temp_dir().join(format!("acpmux-open-logs-{}", uuid::Uuid::now_v7()));
    let store = LocalStore::new(dir.clone(), 1 << 20).unwrap().with_open_logs(logs);
    let record = |seq| EventRecord {
        seq,
        at: seq,
        dir: "in".into(),
        kind: "agent_message_chunk".into(),
        msg: serde_json::json!({"text": "a streamed chunk"}),
        host_seq: None,
    };
    let syncs = || super::super::log_sync::ALL_SYNCS.with(std::cell::Cell::get);
    let chats: Vec<String> = (0..100).map(|n| format!("chat-{n:03}")).collect();
    for chat in &chats {
        store.append(chat, &record(1)).unwrap();
    }
    let before = syncs();
    for seq in 2..=3 {
        for chat in &chats {
            store.append(chat, &record(seq)).unwrap();
        }
    }
    let made = syncs() - before;
    for chat in &chats {
        let seqs: Vec<u64> =
            store.events(chat, 0, usize::MAX).unwrap().iter().map(|e| e.seq).collect();
        assert_eq!(seqs, [1, 2, 3], "{chat}");
    }
    let _ = std::fs::remove_dir_all(&dir);
    made
}

#[test]
fn more_chats_than_the_old_bound_stream_with_no_sync_under_the_raised_limit() {
    // Under the limit the daemon raises itself to, 100 chats keep their logs open.
    assert_eq!(syncs_while_100_chats_stream(for_limit(Some(10_240))), 0);
    // At the old bound each of those 200 appends closed, and synced, another chat's log.
    assert_eq!(syncs_while_100_chats_stream(for_limit(None)), 200);
}
