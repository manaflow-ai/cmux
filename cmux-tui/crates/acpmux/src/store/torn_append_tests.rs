//! A log append that fails partway (a full disk writes part of a line, then `ENOSPC`) leaves no
//! torn line behind: the next record starts on a line of its own, so nothing the store said it
//! kept is lost and a strict read still opens the log. A torn tail a crash left is cut when the
//! log is next opened for writing. Run on Windows too (`cmux-tui.yml` test-windows): there the
//! writer's handle may only append, so the cut takes its own handle.
//!
//! Before the fix, the next append was glued onto the torn bytes: the merged line read as no
//! record, so that record was gone from the log, and every strict read of the log failed.

use super::*;
use serde_json::json;

const CHAT: &str = "chat-a";

fn record(seq: u64) -> EventRecord {
    EventRecord {
        seq,
        at: 1_000 + seq,
        dir: "in".into(),
        kind: "agent_message_chunk".into(),
        msg: json!({"content": {"type": "text", "text": format!("chunk {seq} of an agent's reply")}}),
        host_seq: None,
    }
}

fn chat(store: &dyn Store) {
    let meta: SessionMeta = serde_json::from_value(json!({
        "schema": META_SCHEMA, "id": CHAT, "name": CHAT, "harness": "claude", "family": "claude",
        "cwd": "/w", "status": "idle", "createdAt": 1, "updatedAt": 1,
    }))
    .unwrap();
    store.save(&meta).unwrap();
}

/// The seqs a strict read finds, or its error.
fn strict_seqs(store: &dyn Store) -> Result<Vec<u64>> {
    let mut seqs = Vec::new();
    store.scan_strict(CHAT, 0, &mut |r| {
        seqs.push(r.seq);
        true
    })?;
    Ok(seqs)
}

fn loose_seqs(store: &dyn Store) -> Vec<u64> {
    let mut seqs = Vec::new();
    store
        .scan(CHAT, 0, &mut |r| {
            seqs.push(r.seq);
            true
        })
        .unwrap();
    seqs
}

fn stores(home: &Path) -> Vec<(&'static str, Box<dyn Store>)> {
    let plain = LocalStore::new(home.join("plain"), 1 << 20).unwrap();
    let journaled = open(&StoreConfig::default(), &home.join("journaled")).unwrap();
    vec![("local", Box::new(plain)), ("journal", journaled)]
}

/// Every length a partial write can keep, from nothing to all but the newline, on the plain
/// store and on the journal store the daemon runs.
#[test]
fn a_partial_write_loses_no_record_the_store_kept() {
    let line_len = serde_json::to_string(&record(2)).unwrap().len() + 1;
    for kept in [0, 1, 7, line_len / 2, line_len - 1] {
        let home = tempfile::tempdir().unwrap();
        for (name, store) in stores(home.path()) {
            let store = store.as_ref();
            chat(store);
            store.append(CHAT, &record(1)).unwrap();
            test_write_fault::partial(kept);
            assert!(store.append(CHAT, &record(2)).is_err(), "{name}: the full disk is an error");
            store.append(CHAT, &record(3)).unwrap();
            store.append(CHAT, &record(4)).unwrap();
            let strict = strict_seqs(store)
                .unwrap_or_else(|e| panic!("{name}, {kept} bytes kept: strict read failed: {e:#}"));
            assert_eq!(strict, vec![1, 3, 4], "{name}, {kept} bytes kept");
            assert_eq!(loose_seqs(store), vec![1, 3, 4], "{name}, {kept} bytes kept");
        }
    }
}

/// A process killed mid-append leaves half a line at the end of the segment. The next run's
/// first append cuts it, so its records read and the log stays strictly readable.
#[test]
fn a_torn_tail_from_a_crash_is_cut_when_the_log_is_next_written() {
    let home = tempfile::tempdir().unwrap();
    let root = home.path().join("plain");
    {
        let store = LocalStore::new(root.clone(), 1 << 20).unwrap();
        chat(&store);
        store.append(CHAT, &record(1)).unwrap();
        store.flush().unwrap();
    }
    let segment = root.join(CHAT).join("events").join("000001.ndjson");
    let line = serde_json::to_string(&record(2)).unwrap();
    let mut file = OpenOptions::new().append(true).open(&segment).unwrap();
    file.write_all(&line.as_bytes()[..line.len() / 2]).unwrap();
    drop(file);

    let store = LocalStore::new(root, 1 << 20).unwrap();
    store.append(CHAT, &record(3)).unwrap();
    assert_eq!(strict_seqs(&store).unwrap(), vec![1, 3]);
    let text = std::fs::read_to_string(&segment).unwrap();
    assert!(text.ends_with('\n') && text.lines().count() == 2, "{text:?}");
}

/// A segment whose last line is whole is left as it is.
#[test]
fn a_whole_tail_is_kept_when_the_log_is_next_written() {
    let home = tempfile::tempdir().unwrap();
    let root = home.path().join("plain");
    {
        let store = LocalStore::new(root.clone(), 1 << 20).unwrap();
        chat(&store);
        for seq in 1..=3 {
            store.append(CHAT, &record(seq)).unwrap();
        }
        store.flush().unwrap();
    }
    let store = LocalStore::new(root, 1 << 20).unwrap();
    store.append(CHAT, &record(4)).unwrap();
    assert_eq!(strict_seqs(&store).unwrap(), vec![1, 2, 3, 4]);
}

/// A failed write whose cut back fails too closes the log rather than dropping it: the records
/// appended before it are synced as at any close, so a checkpoint that takes the log as synced
/// (`sync_log` with no open writer) and then an OS crash lose none of them. Review of #40884, F1.
#[cfg(unix)]
#[test]
fn a_failed_cut_closes_the_log_so_earlier_records_survive_an_os_crash() {
    let home = tempfile::tempdir().unwrap();
    let sessions = home.path().join("sessions");
    {
        let store = LocalStore::new(sessions.clone(), 1 << 20).unwrap();
        chat(&store);
        store.append(CHAT, &record(1)).unwrap();
        store.append(CHAT, &record(2)).unwrap();
        test_write_fault::partial_and_failed_cut(9);
        assert!(store.append(CHAT, &record(3)).is_err());
        // The checkpoint's sync: the writer is gone, so only the folders are synced here.
        store.sync_log(CHAT).unwrap();
        assert!(!store.close_sync_failed());
    }
    sync_model::os_crash(&sessions);
    let store = LocalStore::new(sessions, 1 << 20).unwrap();
    store.append(CHAT, &record(4)).unwrap();
    assert_eq!(strict_seqs(&store).unwrap(), vec![1, 2, 4]);
}
