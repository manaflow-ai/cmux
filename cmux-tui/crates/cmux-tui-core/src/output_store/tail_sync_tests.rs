//! How often the tail files are fsynced while terminals print. Each tail
//! fsync is an F_FULLFSYNC on macOS (Rust's `File::sync_data`): it flushes
//! the drive's cache, and with it the dirty pages and metadata of every other
//! file, early.
//!
//! Measured on a daemon with 3 printing terminals (2026-11-12): the writer
//! thread spent 40 of its 45 sampled file system calls in that fcntl and 5 in
//! write(2); 1,694 tail appends in 5 min carried 0.45 MiB. On scratch files
//! with the same pattern, a sync every second wrote 1.7 MiB/min to the disk
//! for 0.19 MiB/min of data, and 16.5 MiB/min next to a file that takes
//! random page writes (as the registry does), against 6.8 MiB/min with a
//! sync every 30 s.
//!
//! A kill of the daemon and its hosts needs no fsync: write(2) puts the
//! bytes in the page cache, which outlives the process. So every pass still
//! appends every byte, and only an OS crash or a power loss can lose the
//! output written since the last sync. The quit pass syncs at once. Any
//! other pass only writes, and the store syncs the tails written since
//! together, every [`super::super::TAIL_SYNC_INTERVAL`]
//! (`super::sync_due_tails`).

use std::sync::{Arc, Mutex};

use super::super::{LogState, OutputStore, TAIL_FLUSH_INTERVAL, TerminalLog};
use super::{Seen, flush_tail, sync_due_tails};
use crate::resource::TerminalPublicId;

/// Terminals that print in every pass.
const TERMINALS: usize = 3;
/// How long they print, on the store's stopped clock (no real waiting).
const SECONDS: u64 = 60;
/// The most tail fsyncs in that time: one per terminal per 10 s.
const SYNC_BUDGET: u64 = TERMINALS as u64 * SECONDS / 10;
/// The fewest: each printing terminal's tail is synced once a minute.
const SYNC_FLOOR: u64 = TERMINALS as u64;

fn directory(name: &str) -> std::path::PathBuf {
    let stamp =
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos();
    let directory = std::env::temp_dir()
        .join(format!("cmux-output-tail-sync-{name}-{}-{stamp}", std::process::id()));
    std::fs::create_dir_all(&directory).unwrap();
    directory
}

/// `count` terminals of `store`, each with a snapshot of generation `g`
/// (80x24) that ends at offset 0 and an empty tail that continues it.
fn terminals(store: &OutputStore, count: usize) -> Vec<Arc<TerminalLog>> {
    (0..count)
        .map(|index| {
            let mut state = LogState::new(Arc::from("g"), 0);
            state.snapshot_end = Some(0);
            state.snapshot_generation = Some(Arc::from("g"));
            state.snapshot_size = Some((80, 24));
            state.tail_end = Some(0);
            let id = format!("term_0000000000000000000000000000051{index:x}");
            let log = Arc::new(TerminalLog {
                terminal_id: TerminalPublicId::parse(&id).unwrap(),
                state: Mutex::new(state),
            });
            store.logs.lock().unwrap().insert(log.terminal_id.clone(), log.clone());
            log
        })
        .collect()
}

fn print(log: &TerminalLog, bytes: &[u8]) {
    let mut state = log.state.lock().unwrap();
    state.tail.extend(bytes.iter().copied());
    state.pending.extend_from_slice(bytes);
}

/// The tail part of one write pass: each terminal's capture saw a new
/// screen (`digest`) with no chunk in flight, at the end of its stream;
/// then the pass's end, as in `write_pass_at`.
fn pass(
    store: &OutputStore,
    directory: &std::path::Path,
    logs: &[Arc<TerminalLog>],
    printed: &[Vec<u8>],
    digest: u64,
    quitting: bool,
) {
    for (log, printed) in logs.iter().zip(printed) {
        let end = printed.len() as u64;
        let seen = Seen { digest, settled: true, end, size: Some((80, 24)), upload: false };
        flush_tail(store, directory, log, seen, quitting);
    }
    sync_due_tails(store, directory);
}

/// The bytes each terminal's tail file holds now, as a restore reads them.
fn stored(directory: &std::path::Path, logs: &[Arc<TerminalLog>]) -> Vec<Vec<u8>> {
    logs.iter()
        .map(|log| super::super::tail::bytes_after(directory, &log.terminal_id, "g", 0))
        .collect()
}

#[test]
fn printing_terminals_sync_their_tails_within_a_budget_and_lose_nothing_to_a_kill() {
    let directory = directory("budget");
    let store = OutputStore::new(None);
    store.set_tail_enabled(true);
    let logs = terminals(&store, TERMINALS);
    let mut printed = vec![Vec::new(); TERMINALS];
    let passes = SECONDS * 1000 / TAIL_FLUSH_INTERVAL.as_millis() as u64;
    for round in 0..passes {
        store.advance_clock(TAIL_FLUSH_INTERVAL);
        for (index, log) in logs.iter().enumerate() {
            let line = format!("terminal {index} line {round}\r\n");
            print(log, line.as_bytes());
            printed[index].extend_from_slice(line.as_bytes());
        }
        pass(&store, &directory, &logs, &printed, round + 1, false);
        // What a kill of every process right after this pass keeps: every
        // byte is in its tail file (the frame headers; no decompression).
        let ends = super::super::tail::stream_ends(&directory);
        for (log, printed) in logs.iter().zip(&printed) {
            let end = ends.get(&log.terminal_id).map(|(_, end)| *end);
            assert_eq!(end, Some(printed.len() as u64), "pass {round} left bytes out of the tail");
            assert!(log.state.lock().unwrap().pending.is_empty(), "pass {round} kept bytes back");
        }
    }
    let syncs = store.tail_syncs();
    assert_eq!(stored(&directory, &logs), printed, "the tail files do not hold the output");

    // The quit: only the first terminal printed since the last pass. Every
    // tail written since its last sync is synced now, once.
    print(&logs[0], b"last words");
    printed[0].extend_from_slice(b"last words");
    let unsynced = logs
        .iter()
        .filter(|log| {
            let state = log.state.lock().unwrap();
            state.tail_unsynced || !state.pending.is_empty()
        })
        .count() as u64;
    pass(&store, &directory, &logs, &printed, passes + 1, true);
    let quit_syncs = store.tail_syncs() - syncs;
    let left_unsynced = logs
        .iter()
        .filter(|log| {
            let state = log.state.lock().unwrap();
            state.tail_unsynced || !state.pending.is_empty()
        })
        .count();
    let stored = stored(&directory, &logs);
    let _ = std::fs::remove_dir_all(&directory);
    assert_eq!(stored, printed, "the quit lost output");
    assert_eq!(left_unsynced, 0, "the quit left a tail without a sync");
    assert_eq!(quit_syncs, unsynced, "the quit syncs each unsynced tail once");

    assert!(
        syncs >= SYNC_FLOOR,
        "{TERMINALS} terminals printed for {SECONDS} s and only {syncs} tail syncs ran: an OS \
         crash would lose more than a minute of output"
    );
    assert!(
        syncs <= SYNC_BUDGET,
        "{TERMINALS} terminals printed for {SECONDS} s ({passes} passes) and their tails were \
         fsynced {syncs} times; the budget is {SYNC_BUDGET} (one per terminal per 10 s)"
    );
}
