//! The tail flush: the digest a capture saw stands for stored bytes only
//! when it saw exactly them. (Red form: the flush takes only the digest.)

use std::sync::{Arc, Mutex};

use super::super::{LogState, OutputStore, TerminalLog};
use super::flush_tail;
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
    flush_tail(&store, &directory, &log, screen_with_chunk, false);
    push(&log, b"chunk");
    // The screen did not change since: the same digest, now settled.
    flush_tail(&store, &directory, &log, screen_with_chunk, false);
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
    flush_tail(&store, &directory, &log, screen_with_one, false);
    push(&log, b"three");
    flush_tail(&store, &directory, &log, screen_with_one, false);
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
    flush_tail(&store, &directory, &log, 5, false);
    push(&log, b"\x1b[20;3H\x1b[?25h");
    flush_tail(&store, &directory, &log, 5, false);
    let stored = super::super::tail::bytes_after(&directory, &log.terminal_id, "g", 0);
    let pending = log.state.lock().unwrap().pending.len();
    let _ = std::fs::remove_dir_all(&directory);
    assert_eq!(stored, b"screen");
    assert_eq!(pending, 9, "the redraw is kept for the next change or snapshot");
}
