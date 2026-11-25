use std::sync::Arc;
use std::sync::atomic::Ordering;

use super::{OUTPUT_TAIL_BYTES, OutputStore, PersistencePolicy, TerminalPublicId};

fn terminal() -> TerminalPublicId {
    TerminalPublicId::parse("term_00000000000000000000000000000e4d").unwrap()
}

fn public_store(root: &std::path::Path) -> OutputStore {
    let store = OutputStore::new(Some(root));
    let mut policy = PersistencePolicy::resolve(Some("snapshot"), None, None);
    policy.min_free_disk_bytes = 0;
    store.cache_policy(policy);
    store.snapshot_file_bytes.store(0, Ordering::Relaxed);
    store.mark_public(&terminal());
    store
}

#[test]
fn parked_reads_survive_compaction_and_late_output() {
    let root = tempfile::tempdir().unwrap();
    let store = public_store(root.path());
    let id = terminal();
    let generation = Arc::from("first");
    store.append(&id, &generation, b"final output", None);
    assert!(!store.release_terminal_output(&id, &generation, 11));
    assert!(store.release_terminal_output(&id, &generation, 12));
    assert!(store.parked_tail_bytes() > 0);
    let log = store.logs.lock().unwrap()[&id].clone();
    assert_eq!(log.state.lock().unwrap().tail.capacity(), 0);
    super::tail::remove(store.directory().unwrap(), &id);
    let part = store.read_after(&id, 6, 3).unwrap();
    assert_eq!(
        (part.bytes.as_slice(), part.start_offset, part.next_offset, part.truncated),
        (b"out".as_slice(), 6, 9, true)
    );
    assert_eq!(store.read_after(&id, 0, 12).unwrap().bytes, b"final output");
    assert_eq!(store.read_after(&id, 99, 3).unwrap().next_offset, 12);
    store.append(&id, &generation, b"\0\xfflate", None);
    assert_eq!(store.read_after(&id, 0, 99).unwrap().bytes, b"final output\0\xfflate");
    assert_eq!(store.parked_tail_bytes(), 0);
    assert!(store.release_terminal_output(&id, &generation, 18));
    store.append(&id, &Arc::from("second"), b"new", None);
    assert_eq!(store.read_after(&id, 0, 5).unwrap().bytes, b"new");
    assert_eq!(store.parked_tail_bytes(), 0);
}

#[test]
fn parking_keeps_the_writer_and_pending_bytes() {
    let root = tempfile::tempdir().unwrap();
    let store = public_store(root.path());
    store.set_tail_enabled(true);
    let id = terminal();
    let generation = Arc::from("first");
    let bytes = vec![0xab; OUTPUT_TAIL_BYTES + 16];
    store.append(&id, &generation, &bytes, None);
    let log = store.logs.lock().unwrap()[&id].clone();
    assert!(store.release_terminal_output(&id, &generation, bytes.len() as u64));
    let mut state = log.state.lock().unwrap();
    assert!(state.dirty);
    assert_eq!(state.pending, bytes);
    // The recovery writer can finish after the terminal exits. Its pending window
    // reaches further back than the raw tail until those bytes have been flushed.
    assert_eq!(state.memory_window(0, 4).start_offset, 0);
    state.pending.clear();
    drop(state);
    let part = store.read_after(&id, 0, 2).unwrap();
    assert_eq!((part.start_offset, part.next_offset, part.bytes), (16, 18, vec![0xab; 2]));
    store.history_cleared(&id);
    assert!(store.read_after(&id, 0, 8).unwrap().bytes.is_empty());
    assert_eq!(store.stream_end(&id).unwrap().1, bytes.len() as u64);
    assert_eq!(store.parked_tail_bytes(), 0);
}

#[test]
fn privacy_and_disk_budget_keep_raw_output_readable() {
    let root = tempfile::tempdir().unwrap();
    let store = public_store(root.path());
    let id = terminal();
    let generation = Arc::from("first");
    store.append(&id, &generation, b"data", None);
    store.snapshot_file_bytes.store(u64::MAX, Ordering::Relaxed);
    assert!(!store.release_terminal_output(&id, &generation, 4));
    store.snapshot_file_bytes.store(0, Ordering::Relaxed);
    assert!(store.release_terminal_output(&id, &generation, 4));
    store.fit_parked_tails(PersistencePolicy::resolve(Some("memory"), None, None));
    assert_eq!(store.parked_tail_bytes(), 0);
    assert!(store.release_terminal_output(&id, &generation, 4));
    store.mark_private(&id);
    assert_eq!(store.parked_tail_bytes(), 0);
    assert!(!store.release_terminal_output(&id, &generation, 4));
    assert_eq!(store.read_after(&id, 0, 4).unwrap().bytes, b"data");
}
