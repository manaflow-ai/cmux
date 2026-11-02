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
        Seen { digest: screen_with_chunk, settled: false, end: 6, size: None },
        false,
    );
    push(&log, b"chunk");
    // The screen did not change since: the same digest, now settled.
    flush_tail(
        &store,
        &directory,
        &log,
        Seen { digest: screen_with_chunk, settled: true, end: 11, size: None },
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
        Seen { digest: screen_with_one, settled: true, end: 4, size: None },
        false,
    );
    push(&log, b"three");
    flush_tail(
        &store,
        &directory,
        &log,
        Seen { digest: screen_with_one, settled: true, end: 13, size: None },
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
    flush_tail(
        &store,
        &directory,
        &log,
        Seen { digest: 5, settled: true, end: 6, size: None },
        false,
    );
    let redraw = b"\x1b[20;3H\x1b[?25h";
    push(&log, redraw);
    flush_tail(
        &store,
        &directory,
        &log,
        Seen { digest: 5, settled: true, end: 15, size: None },
        false,
    );
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
    flush_tail(
        &store,
        &not_a_folder,
        &log,
        Seen { digest: 1, settled: true, end: 6, size: None },
        false,
    );
    let wants = Plan::of(&log, std::time::Duration::from_secs(30)).wants_snapshot(
        2,
        (80, 24),
        true,
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
    // it, the next snapshot starts the tail again and covers the bytes.
    assert_eq!(tail_end, None);
    assert!(force);
    assert_eq!(pending, 0);
}

/// Bytes held as redraws stay bounded (the idle cap) while no snapshot can
/// replace them; past the cap the tail stops and a snapshot is asked for.
#[test]
fn held_redraw_bytes_stay_bounded() {
    let directory = directory("bounded");
    let store = OutputStore::new(None);
    let log = log(b"screen");
    flush_tail(
        &store,
        &directory,
        &log,
        Seen { digest: 5, settled: true, end: 6, size: None },
        false,
    );
    let redraws = vec![b'.'; super::super::TAIL_MAX_UNWRITTEN_BYTES + 1024];
    push(&log, &redraws);
    flush_tail(
        &store,
        &directory,
        &log,
        Seen { digest: 5, settled: true, end: 0, size: None },
        false,
    );
    let state = log.state.lock().unwrap();
    let (pending, tail_end, force) = (state.pending.len(), state.tail_end, state.force_snapshot);
    drop(state);
    let _ = std::fs::remove_dir_all(&directory);
    assert!(
        pending <= super::super::TAIL_MAX_UNWRITTEN_BYTES,
        "{pending} held bytes are over the cap"
    );
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

/// Failure-mode table, "flood": unwritten bytes past the cap are not written
/// as one huge frame; the terminal falls back to its snapshot (which covers
/// them) and keeps no bytes in memory.
#[test]
fn a_flood_past_the_cap_falls_back_to_the_snapshot() {
    let directory = directory("flood-cap");
    let store = OutputStore::new(None);
    let log = log(&vec![b'x'; super::super::TAIL_MAX_UNWRITTEN_BYTES + 1024]);
    flush_tail(
        &store,
        &directory,
        &log,
        Seen { digest: 1, settled: true, end: 0, size: None },
        false,
    );
    let stored = super::super::tail::bytes_after(&directory, &log.terminal_id, "g", 0);
    let state = log.state.lock().unwrap();
    let (pending, force, tail_end) = (state.pending.len(), state.force_snapshot, state.tail_end);
    drop(state);
    let _ = std::fs::remove_dir_all(&directory);
    assert!(stored.is_empty(), "a {} byte frame went to the tail", stored.len());
    assert_eq!(pending, 0, "the bytes the snapshot covers stay in memory");
    assert!(force && tail_end.is_none());
}

/// Failure-mode table, "full disk" / "slow disk": bytes that the tail cannot
/// continue with are not kept in memory; the next snapshot covers them.
#[test]
fn a_tail_that_does_not_continue_keeps_no_bytes() {
    let directory = directory("no-continue");
    let store = OutputStore::new(None);
    let log = log(b"some output");
    log.state.lock().unwrap().tail_end = None;
    flush_tail(
        &store,
        &directory,
        &log,
        Seen { digest: 1, settled: true, end: 11, size: None },
        false,
    );
    let state = log.state.lock().unwrap();
    let (pending, force) = (state.pending.len(), state.force_snapshot);
    drop(state);
    let _ = std::fs::remove_dir_all(&directory);
    assert_eq!(pending, 0, "bytes wait in memory for a snapshot that covers them anyway");
    assert!(force);
}

/// Failure-mode table, "idle TUI during a backoff": held redraws past the
/// idle cap are dropped (the snapshot covers them), not kept up to 8 MiB.
#[test]
fn held_redraws_past_the_idle_cap_fall_back_to_the_snapshot() {
    let directory = directory("idle-cap");
    let store = OutputStore::new(None);
    let log = log(b"screen");
    flush_tail(
        &store,
        &directory,
        &log,
        Seen { digest: 5, settled: true, end: 6, size: None },
        false,
    );
    log.state.lock().unwrap().store_failed();
    push(&log, &vec![b'.'; super::super::TAIL_IDLE_BYTES + 1]);
    flush_tail(
        &store,
        &directory,
        &log,
        Seen { digest: 5, settled: true, end: 0, size: None },
        false,
    );
    let (pending, dirty) = {
        let state = log.state.lock().unwrap();
        (state.pending.len(), state.dirty)
    };
    let due = store.writer.state.0.lock().unwrap().due;
    let _ = std::fs::remove_dir_all(&directory);
    assert_eq!(pending, 0, "{pending} held redraw bytes stay in memory");
    // The drop asks for the snapshot that covers it at the next pass, not
    // at the next 30 s or 1 MiB point (the loss bound holds after a drop).
    assert!(dirty, "the dropped bytes wait for a snapshot nobody asked for");
    assert!(
        due.is_some_and(|due| due <= std::time::Instant::now() + super::super::TAIL_FLUSH_INTERVAL),
        "no pass is due within the flush interval after the drop"
    );
}
