//! The tail flush: the digest a capture saw stands for stored bytes only
//! when it saw exactly them.

use std::sync::{Arc, Mutex};

use super::super::{LogState, OutputStore, TerminalLog};
use super::{Plan, Seen, flush_tail, snapshot_written};
use crate::resource::TerminalPublicId;

fn directory(name: &str) -> std::path::PathBuf {
    let stamp =
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos();
    let directory = std::env::temp_dir()
        .join(format!("cmux-output-flush-{name}-{}-{stamp}", std::process::id()));
    std::fs::create_dir_all(&directory).unwrap();
    directory
}

/// A log whose snapshot of generation `g` ends at offset 0 and whose tail
/// continues it, with `pending` unwritten from offset 0.
fn log(pending: &[u8]) -> TerminalLog {
    let mut state = LogState::new(Arc::from("g"), 0);
    state.tail.extend(pending.iter().copied());
    state.pending = pending.to_vec();
    state.snapshot_end = Some(0);
    state.snapshot_generation = Some(Arc::from("g"));
    state.snapshot_size = Some((80, 24));
    state.tail_end = Some(0);
    TerminalLog {
        terminal_id: TerminalPublicId::parse("term_00000000000000000000000000000f3a").unwrap(),
        state: Mutex::new(state),
    }
}

fn push(log: &TerminalLog, bytes: &[u8]) {
    let mut state = log.state.lock().unwrap();
    state.tail.extend(bytes.iter().copied());
    state.pending.extend_from_slice(bytes);
}

/// The capture ran while the reader's chunk was parsed but not yet in the
/// store (an odd epoch): its digest already shows the chunk. The chunk that
/// arrives next must reach the tail, not wait as a redraw of stored content
/// (review of #31643: the last lines of a build were held until the next
/// output and lost to a kill).
#[test]
fn a_chunk_in_flight_at_the_capture_still_reaches_the_tail() {
    let directory = directory("in-flight");
    let store = OutputStore::new(None);
    let log = log(b"first ");
    let screen_with_chunk = 7;
    flush_tail(
        &store,
        &directory,
        &log,
        Seen { digest: screen_with_chunk, settled: false, end: 6 },
        false,
    );
    push(&log, b"chunk");
    // The screen did not change since: the same digest, now settled.
    flush_tail(
        &store,
        &directory,
        &log,
        Seen { digest: screen_with_chunk, settled: true, end: 11 },
        false,
    );
    let stored = super::super::tail::bytes_after(&directory, &log.terminal_id, "g", 0);
    let _ = std::fs::remove_dir_all(&directory);
    assert_eq!(stored, b"first chunk", "the chunk in flight was held as a redraw");
}

/// Bytes that came after the capture are not named by its digest either.
#[test]
fn bytes_after_the_capture_still_reach_the_tail() {
    let directory = directory("after");
    let store = OutputStore::new(None);
    let log = log(b"one ");
    let screen_with_one = 3;
    // Captured at offset 4; "two" arrived before the flush took the bytes.
    push(&log, b"two ");
    flush_tail(
        &store,
        &directory,
        &log,
        Seen { digest: screen_with_one, settled: true, end: 4 },
        false,
    );
    push(&log, b"three");
    flush_tail(
        &store,
        &directory,
        &log,
        Seen { digest: screen_with_one, settled: true, end: 13 },
        false,
    );
    let stored = super::super::tail::bytes_after(&directory, &log.terminal_id, "g", 0);
    let _ = std::fs::remove_dir_all(&directory);
    assert_eq!(stored, b"one two three");
}

/// A redraw of stored content (the digest of exactly the stored bytes)
/// waits in memory: an idle TUI writes nothing.
#[test]
fn a_redraw_of_exactly_the_stored_bytes_waits_in_memory() {
    let directory = directory("redraw");
    let store = OutputStore::new(None);
    let log = log(b"screen");
    flush_tail(&store, &directory, &log, Seen { digest: 5, settled: true, end: 6 }, false);
    let redraw = b"\x1b[20;3H\x1b[?25h";
    push(&log, redraw);
    flush_tail(&store, &directory, &log, Seen { digest: 5, settled: true, end: 15 }, false);
    let stored = super::super::tail::bytes_after(&directory, &log.terminal_id, "g", 0);
    let pending = log.state.lock().unwrap().pending.len();
    let _ = std::fs::remove_dir_all(&directory);
    assert_eq!(stored, b"screen");
    assert_eq!(pending, redraw.len(), "the redraw is kept for the next change or snapshot");
}

/// A disk that refuses writes (a full disk; here the store folder is a
/// plain file) must not make the next pass build a whole snapshot replay
/// under the parser lock, fail, and ask again 100 ms later, for good (review
/// of #31643 at 8aed6172b46).
#[test]
fn a_failing_disk_does_not_retry_the_snapshot_on_the_next_pass() {
    let root = directory("failing");
    let not_a_folder = root.join("store");
    std::fs::write(&not_a_folder, b"a file where the store folder goes").unwrap();
    let store = OutputStore::new(None);
    let log = log(b"output");
    flush_tail(&store, &not_a_folder, &log, Seen { digest: 1, settled: true, end: 6 }, false);
    let wants = Plan::of(&log, std::time::Duration::from_secs(30)).wants_snapshot(
        2,
        (80, 24),
        false,
        true,
        false,
    );
    let state = log.state.lock().unwrap();
    let (tail_end, force, pending) = (state.tail_end, state.force_snapshot, state.pending.len());
    drop(state);
    let _ = std::fs::remove_dir_all(&root);
    assert!(!wants, "the pass right after a failed write asks for a snapshot again");
    // The failed append may have left a cut frame: nothing more goes behind
    // it, the next snapshot starts the tail again, the bytes wait for it.
    assert_eq!(tail_end, None);
    assert!(force);
    assert_eq!(pending, 6);
}

/// Bytes held as redraws stay bounded (8 MiB) while no snapshot can replace
/// them; past the cap the tail stops and a snapshot is asked for.
#[test]
fn held_redraw_bytes_stay_bounded() {
    let directory = directory("bounded");
    let store = OutputStore::new(None);
    let log = log(b"screen");
    flush_tail(&store, &directory, &log, Seen { digest: 5, settled: true, end: 6 }, false);
    let redraws = vec![b'.'; super::super::TAIL_MAX_UNWRITTEN_BYTES + 1024];
    push(&log, &redraws);
    flush_tail(&store, &directory, &log, Seen { digest: 5, settled: true, end: 0 }, false);
    let state = log.state.lock().unwrap();
    let (pending, tail_end, force) = (state.pending.len(), state.tail_end, state.force_snapshot);
    drop(state);
    let _ = std::fs::remove_dir_all(&directory);
    assert_eq!(pending, super::super::TAIL_MAX_UNWRITTEN_BYTES);
    assert_eq!(tail_end, None, "the tail continued past dropped bytes");
    assert!(force);
}

/// A snapshot in any mode removes the terminal's tail: a tail left from
/// snapshot mode never replays over a newer snapshot after a mode change.
#[test]
fn a_snapshot_in_full_mode_removes_a_tail_left_from_snapshot_mode() {
    let directory = directory("full-mode");
    let log = log(b"");
    super::super::tail::append(&directory, &log.terminal_id, "g", 0, 0, b"old", false).unwrap();
    snapshot_written(&directory, &log, false, 9, (80, 24), &std::sync::Arc::from("g"), 3);
    let left = super::super::tail::path(&directory, &log.terminal_id).exists();
    let _ = std::fs::remove_dir_all(&directory);
    assert!(!left, "the tail of snapshot mode outlived a full-mode snapshot");
}

/// A flood during a write backoff must not wake the writer on every chunk
/// (review of #31643 at de88631da57: each wake moved the capped 8 MiB
/// buffer under the lock the reader needs, back to back).
#[test]
fn a_flood_during_a_write_backoff_does_not_wake_the_writer_per_chunk() {
    let store = OutputStore::new(None);
    store.set_tail_enabled(true);
    let id = TerminalPublicId::parse("term_00000000000000000000000000000f3b").unwrap();
    let generation: Arc<str> = Arc::from("g");
    store.append(&id, &generation, b"x", None);
    let log = store.logs.lock().unwrap().get(&id).cloned().unwrap();
    {
        let mut state = log.state.lock().unwrap();
        state.store_failed();
        state.pending = vec![b'.'; super::super::TAIL_MAX_UNWRITTEN_BYTES];
    }
    store.writer.state.0.lock().unwrap().due = None;
    store.append(&id, &generation, b"one more chunk", None);
    let due = store.writer.state.0.lock().unwrap().due;
    assert!(
        due.is_none_or(
            |due| due > std::time::Instant::now() + std::time::Duration::from_millis(500)
        ),
        "a chunk during the backoff woke the writer at once"
    );
}
