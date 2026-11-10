//! The tail flush: the digest a capture saw stands for stored bytes only
//! when it saw exactly them.

use std::sync::{Arc, Mutex};

use super::super::{LogState, OutputStore, TerminalLog};
use super::{Plan, Seen, SnapshotEnd, flush_tail, snapshot_written};
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
        Seen { digest: screen_with_chunk, settled: false, end: 6, size: None, upload: false },
        false,
    );
    push(&log, b"chunk");
    // The screen did not change since: the same digest, now settled.
    flush_tail(
        &store,
        &directory,
        &log,
        Seen { digest: screen_with_chunk, settled: true, end: 11, size: None, upload: false },
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
        Seen { digest: screen_with_one, settled: true, end: 4, size: None, upload: false },
        false,
    );
    push(&log, b"three");
    flush_tail(
        &store,
        &directory,
        &log,
        Seen { digest: screen_with_one, settled: true, end: 13, size: None, upload: false },
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
        Seen { digest: 5, settled: true, end: 6, size: None, upload: false },
        false,
    );
    let redraw = b"\x1b[20;3H\x1b[?25h";
    push(&log, redraw);
    flush_tail(
        &store,
        &directory,
        &log,
        Seen { digest: 5, settled: true, end: 15, size: None, upload: false },
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
        Seen { digest: 1, settled: true, end: 6, size: None, upload: false },
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
        Seen { digest: 5, settled: true, end: 6, size: None, upload: false },
        false,
    );
    let redraws = vec![b'.'; super::super::TAIL_MAX_UNWRITTEN_BYTES + 1024];
    push(&log, &redraws);
    flush_tail(
        &store,
        &directory,
        &log,
        Seen { digest: 5, settled: true, end: 0, size: None, upload: false },
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
    snapshot_written(
        &directory,
        &log,
        false,
        9,
        (80, 24),
        SnapshotEnd { generation: &Arc::from("g"), stream_end: 3, gaps: 0 },
    );
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
        // Just under the wake threshold (half the cap): the chunk below
        // crosses it without the cap's drop, so the backoff rule itself is
        // checked.
        state.pending = vec![b'.'; super::super::TAIL_MAX_UNWRITTEN_BYTES / 2 - 8];
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
        Seen { digest: 1, settled: true, end: 0, size: None, upload: false },
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
        Seen { digest: 1, settled: true, end: 11, size: None, upload: false },
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
        Seen { digest: 5, settled: true, end: 6, size: None, upload: false },
        false,
    );
    log.state.lock().unwrap().store_failed();
    push(&log, &vec![b'.'; super::super::TAIL_IDLE_BYTES + 1]);
    flush_tail(
        &store,
        &directory,
        &log,
        Seen { digest: 5, settled: true, end: 0, size: None, upload: false },
        false,
    );
    let (pending, dirty) = {
        let state = log.state.lock().unwrap();
        (state.pending.len(), state.dirty)
    };
    let due = store.writer.state.0.lock().unwrap().due;
    let _ = std::fs::remove_dir_all(&directory);
    assert_eq!(pending, 0, "{pending} held redraw bytes stay in memory");
    // The drop asks for the snapshot that covers it at the first pass that
    // may write one (here: when the 1 s write backoff ends), not at the
    // next 30 s or 1 MiB point.
    assert!(dirty, "the dropped bytes wait for a snapshot nobody asked for");
    let limit = std::time::Instant::now()
        + super::super::STORE_RETRY_MIN
        + super::super::TAIL_FLUSH_INTERVAL;
    assert!(
        due.is_some_and(|due| due <= limit),
        "no pass is due when the backoff ends after the drop"
    );
}

/// Failure-mode table, "full disk" / "flood": during a write backoff no pass
/// runs before the backoff ends, so the cap holds in `append` itself (review
/// round 5 of #31643: memory grew by the output rate times the backoff).
#[test]
fn a_flood_during_a_backoff_keeps_at_most_the_cap_in_memory() {
    let store = OutputStore::new(None);
    store.set_tail_enabled(true);
    let id = TerminalPublicId::parse("term_00000000000000000000000000000f3c").unwrap();
    let generation: Arc<str> = Arc::from("g");
    store.append(&id, &generation, b"x", None);
    let log = store.logs.lock().unwrap().get(&id).cloned().unwrap();
    log.state.lock().unwrap().store_failed();
    let chunk = vec![b'y'; 64 * 1024];
    for _ in 0..(super::super::TAIL_MAX_UNWRITTEN_BYTES / chunk.len() + 8) {
        store.append(&id, &generation, &chunk, None);
    }
    let pending = log.state.lock().unwrap().pending.len();
    assert!(
        pending <= super::super::TAIL_MAX_UNWRITTEN_BYTES,
        "{pending} bytes wait in memory during the backoff"
    );
}

/// Failure-mode table, "flood": a drop in `append` while a snapshot is being
/// written (its capture ended before the dropped bytes) still asks for the
/// snapshot that covers them (review round 6 of #31643: snapshot_written
/// cleared the request, and an idle terminal then kept its last screen
/// neither in the snapshot nor in the tail).
#[test]
fn a_drop_during_a_snapshot_write_still_asks_for_a_snapshot() {
    let directory = directory("drop-during-write");
    let store = OutputStore::new(None);
    store.set_tail_enabled(true);
    let id = TerminalPublicId::parse("term_00000000000000000000000000000f3d").unwrap();
    let generation: Arc<str> = Arc::from("g");
    store.append(&id, &generation, b"before", None);
    let log = store.logs.lock().unwrap().get(&id).cloned().unwrap();
    {
        let mut state = log.state.lock().unwrap();
        state.snapshot_end = Some(0);
        state.snapshot_generation = Some(generation.clone());
        state.snapshot_size = Some((80, 24));
        state.tail_end = Some(0);
    }
    // The snapshot's capture ended at 6; then a flood crossed the cap.
    store.append(&id, &generation, &vec![b'x'; super::super::TAIL_MAX_UNWRITTEN_BYTES + 1], None);
    snapshot_written(
        &directory,
        &log,
        true,
        9,
        (80, 24),
        SnapshotEnd { generation: &generation, stream_end: 6, gaps: 0 },
    );
    let retry = log.state.lock().unwrap().snapshot_retry_in();
    let _ = std::fs::remove_dir_all(&directory);
    assert!(retry.is_some(), "the dropped bytes are in no snapshot, and none is asked for");
}

/// A host reconnect (`stream_gap`) while a snapshot of the old screen is
/// being written must still bring a snapshot of the replaced screen: the
/// stream offset did not move (the gap's bytes never came through append),
/// so the write must not clear the request (review of #31931).
#[test]
fn a_reconnect_during_a_snapshot_write_still_asks_for_a_snapshot() {
    let directory = directory("gap-during-write");
    let store = OutputStore::new(None);
    store.set_tail_enabled(true);
    let id = TerminalPublicId::parse("term_00000000000000000000000000000f3f").unwrap();
    let generation: Arc<str> = Arc::from("g");
    store.append(&id, &generation, b"old screen", None);
    let log = store.logs.lock().unwrap().get(&id).cloned().unwrap();
    // The pass captured the old screen at offset 10; the reconnect replaces
    // the terminal before the pass records its snapshot.
    store.stream_gap(&id);
    snapshot_written(
        &directory,
        &log,
        true,
        9,
        (80, 24),
        SnapshotEnd { generation: &generation, stream_end: 10, gaps: 0 },
    );
    let retry = log.state.lock().unwrap().snapshot_retry_in();
    let _ = std::fs::remove_dir_all(&directory);
    assert!(retry.is_some(), "the snapshot of the old screen cleared the reconnect's request");
}

/// An unfinished Kitty image upload changes nothing the content digest sees
/// (the screen's text, size, history and cursor stay): its bytes are not
/// redraws and must reach the tail, not wait in memory up to the idle cap
/// and then fall back to a snapshot that cannot be taken while the upload is
/// too large to replay (an_unreplayable_screen_does_not_stop_the_tail failed
/// 1 run in about 10 on the fleet this way).
#[test]
fn an_unfinished_upload_is_not_held_as_a_redraw() {
    let directory = directory("upload-hold");
    let store = OutputStore::new(None);
    let log = log(b"screen");
    flush_tail(
        &store,
        &directory,
        &log,
        Seen { digest: 5, settled: true, end: 6, size: None, upload: false },
        false,
    );
    let chunk = b"\x1b_Ga=t,f=100,m=1;AAAA\x1b\\";
    push(&log, chunk);
    // Same digest (the upload is invisible), the capture saw it in flight.
    flush_tail(
        &store,
        &directory,
        &log,
        Seen { digest: 5, settled: true, end: 6 + chunk.len() as u64, size: None, upload: true },
        false,
    );
    let stored = super::super::tail::bytes_after(&directory, &log.terminal_id, "g", 0);
    let _ = std::fs::remove_dir_all(&directory);
    assert!(stored.ends_with(chunk), "the upload's bytes were held as a redraw");
}

/// Snapshot mode wakes the writer at once when a terminal's unwritten bytes
/// cross half the cap (4 MiB), so a flood a healthy disk can take is written
/// before `append` would drop it at the cap (review note on #31643).
#[test]
fn a_flood_crossing_half_the_cap_wakes_the_writer_at_once() {
    let store = OutputStore::new(None);
    store.set_tail_enabled(true);
    let id = TerminalPublicId::parse("term_00000000000000000000000000000f3e").unwrap();
    let generation: Arc<str> = Arc::from("g");
    store.append(&id, &generation, b"x", None);
    let log = store.logs.lock().unwrap().get(&id).cloned().unwrap();
    log.state.lock().unwrap().pending = vec![b'.'; super::super::TAIL_MAX_UNWRITTEN_BYTES / 2 - 8];
    store.writer.state.0.lock().unwrap().due = None;
    store.append(&id, &generation, b"one more chunk", None);
    let due = store.writer.state.0.lock().unwrap().due;
    let pending = log.state.lock().unwrap().pending.len();
    assert!(pending > super::super::TAIL_MAX_UNWRITTEN_BYTES / 2, "the bytes were dropped");
    assert!(
        due.is_some_and(|due| due <= std::time::Instant::now()),
        "the writer is not due at once after the flood crossed half the cap: {due:?}"
    );
}

/// The parked snapshots' trim runs once a day however busy the writer is: the first pass after start (whose prune
/// already trimmed) only starts the day.
#[test]
fn the_parked_trim_runs_once_a_day_with_any_pass() {
    use super::{WriterState, take_trim};
    let mut state = WriterState::default();
    assert!(!take_trim(&mut state), "the start's prune ran it");
    assert!(!take_trim(&mut state), "a busy writer's next pass does not");
    let a_day_ago = std::time::Instant::now().checked_sub(super::super::parked_trim::PASS_EVERY);
    let Some(a_day_ago) = a_day_ago else { return }; // a clock that started under a day ago (Windows)
    state.last_trim = Some(a_day_ago);
    assert!(take_trim(&mut state), "a day later any pass runs it");
    assert!(!take_trim(&mut state));
}

/// A terminal's history grew by a step while a write pass is due: the turn that takes the write pass also
/// measures. The write pass runs the budget at most once per snapshot interval (`OutputStore::enforce_due`), and
/// the terminal does not ask again while its request is open (`LogState::measure_due`), so a request that the
/// write pass takes and does not run leaves the total budget to the interval (30 s; one hour in
/// `the_total_memory_budget_holds_while_terminals_print_not_one_interval_later`, which a loaded host made red:
/// "four full terminals kept 9074 and 9074 rows over the 16 MiB budget"). No clock: the writer's choice is a
/// function of its state and one instant.
#[test]
fn the_total_memory_budget_request_is_not_lost_to_a_write_pass_that_is_due_first() {
    use super::{Turn, WriterState, take_turn};
    let now = std::time::Instant::now();
    let mut state = WriterState { last_trim: Some(now), ..WriterState::default() };

    // Only a request: the turn measures and writes nothing.
    state.memory_due = true;
    assert_eq!(take_turn(&mut state, now), Some(Turn { memory: true, write: false, trim: false }));
    assert_eq!(take_turn(&mut state, now), None, "one request is one measurement");

    // Only a write pass that is due: the turn writes and measures nothing more.
    state.due = Some(now);
    assert_eq!(take_turn(&mut state, now), Some(Turn { memory: false, write: true, trim: false }));
    assert_eq!(take_turn(&mut state, now), None);

    // A write pass that is not due yet does not hold the request back.
    state.due = Some(now + std::time::Duration::from_secs(3600));
    state.memory_due = true;
    assert_eq!(take_turn(&mut state, now), Some(Turn { memory: true, write: false, trim: false }));

    // Both at the same instant: the write pass runs, and the request is not lost.
    state.due = Some(now);
    state.memory_due = true;
    let turn = take_turn(&mut state, now).expect("a write pass is due");
    assert!(turn.write, "a due write pass runs in the turn that takes it: {turn:?}");
    assert!(
        turn.memory || state.memory_due,
        "the request for a measurement is gone and no turn measures: the terminal's `measure_due` stays set, \
         so it never asks again, and the total memory budget waits for the snapshot interval: {turn:?}"
    );
}
