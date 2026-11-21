//! A log line cut off before its newline (a crash mid-write, a full disk) never swallows the next
//! record. The writer appended the next record straight after the torn bytes, so both made one
//! line no reader parses, and the record was lost: an agent host's entry acked after it was
//! "logged", gone from the transcript for good.

use super::*;

const CHAT: &str = "chat-torn";

fn record(seq: u64) -> EventRecord {
    EventRecord {
        seq,
        at: 1_000 + seq,
        dir: "in".into(),
        kind: "agent_message_chunk".into(),
        msg: serde_json::json!({ "n": seq }),
        host_seq: Some(seq),
    }
}

fn open(home: &Path) -> LocalStore {
    LocalStore::new(home.join("sessions"), StoreConfig::default().segment_bytes)
        .unwrap_or_else(|e| panic!("open the store: {e:#}"))
}

fn seqs(store: &LocalStore) -> Vec<u64> {
    let events = store.events(CHAT, 0, 10_000).unwrap_or_else(|e| panic!("read: {e:#}"));
    events.iter().map(|record| record.seq).collect()
}

fn segment(home: &Path) -> PathBuf {
    home.join("sessions").join(CHAT).join("events").join("000001.ndjson")
}

#[test]
fn a_record_after_a_line_a_crash_cut_off_is_its_own_line() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let store = open(home.path());
    for seq in 1..=3 {
        store.append(CHAT, &record(seq)).unwrap_or_else(|e| panic!("{e:#}"));
    }
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    drop(store);
    // The daemon died in the middle of writing record 4.
    let mut torn = std::fs::OpenOptions::new()
        .append(true)
        .open(segment(home.path()))
        .unwrap_or_else(|e| panic!("{e}"));
    torn.write_all(br#"{"seq":4,"at":10"#).unwrap_or_else(|e| panic!("{e}"));
    drop(torn);
    // The next start logs it again (an agent host replays what was never acked).
    let store = open(home.path());
    store.append(CHAT, &record(4)).unwrap_or_else(|e| panic!("{e:#}"));
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    drop(store);
    assert_eq!(seqs(&open(home.path())), vec![1, 2, 3, 4], "the record after a torn line was lost");
}

#[test]
fn a_record_after_a_write_that_failed_part_way_is_its_own_line() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let store = open(home.path());
    for seq in 1..=3 {
        store.append(CHAT, &record(seq)).unwrap_or_else(|e| panic!("{e:#}"));
    }
    test_write_fault::partial(12);
    assert!(store.append(CHAT, &record(4)).is_err(), "the cut write did not fail");
    // The entry was never acked: it is logged again, and so is the next one.
    store.append(CHAT, &record(4)).unwrap_or_else(|e| panic!("{e:#}"));
    store.append(CHAT, &record(5)).unwrap_or_else(|e| panic!("{e:#}"));
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    drop(store);
    assert_eq!(
        seqs(&open(home.path())),
        vec![1, 2, 3, 4, 5],
        "a record after a write that failed part way was lost"
    );
}
