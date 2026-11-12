//! The quit pass: what a daemon writes while it stops. Every terminal has no
//! daemon from the stop until the next daemon adopts its host, so the stop
//! does only what keeps the output safe: the unwritten bytes go to each
//! terminal's tail, durably. A snapshot (a compaction of snapshot plus tail)
//! is written at quit only for a terminal whose tail cannot carry its bytes.
//! The next daemon reads a snapshot and its tail the same way.
//!
//! A quit used to write a new snapshot (a VT replay, gzip, a file fsync, a
//! rename and a folder fsync) for every terminal with any output since its
//! last snapshot, one after another: 2.3-3.0 s of a 2.8-3.3 s stop for 300
//! terminals on a build Mac at load 50-60 (update drill, 2026-11-11), with
//! no input and no output in any terminal for that time.

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use super::super::{LogState, OutputStore, TerminalLog};
use super::{Plan, Seen, flush_tail};
use crate::resource::TerminalPublicId;

fn directory(name: &str) -> std::path::PathBuf {
    let stamp =
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos();
    let directory = std::env::temp_dir()
        .join(format!("cmux-output-quit-{name}-{}-{stamp}", std::process::id()));
    std::fs::create_dir_all(&directory).unwrap();
    directory
}

/// A terminal this daemon wrote a snapshot of (generation `g`, 80x24, digest
/// 1, ending at offset 0), whose tail continues it with `stored` bytes and
/// holds `pending` unwritten ones after them.
fn log(stored: &[u8], pending: &[u8]) -> TerminalLog {
    let mut state = LogState::new(Arc::from("g"), 0);
    state.tail.extend(stored.iter().chain(pending).copied());
    state.snapshot_end = Some(0);
    state.snapshot_generation = Some(Arc::from("g"));
    state.snapshot_size = Some((80, 24));
    state.snapshot_digest = Some(1);
    state.tail_bytes = stored.len() as u64;
    state.tail_end = Some(stored.len() as u64);
    state.pending_start = stored.len() as u64;
    state.pending = pending.to_vec();
    TerminalLog {
        terminal_id: TerminalPublicId::parse("term_00000000000000000000000000000a17").unwrap(),
        state: Mutex::new(state),
    }
}

/// Whether the quit pass writes `log`'s snapshot when its screen now has
/// digest 2 at 80x24.
fn quit_wants_snapshot(log: &TerminalLog, size: (u16, u16)) -> bool {
    let screen = super::ScreenNow { digest: 2, size, alternate: false };
    Plan::of(log, Duration::from_secs(30)).wants_snapshot(screen, true, false, true, true)
}

#[test]
fn a_quit_writes_no_snapshot_for_a_terminal_its_tail_carries() {
    // Output since the snapshot: some in the tail file, some not written yet.
    let log = log(b"stored ", b"unwritten");
    assert!(
        !quit_wants_snapshot(&log, (80, 24)),
        "the quit rewrote the snapshot of a terminal whose tail carries its output"
    );
}

#[test]
fn a_quit_still_writes_a_snapshot_when_the_tail_cannot_carry_the_bytes() {
    // No snapshot of this generation from this daemon: no tail can continue it.
    let fresh = log(b"", b"output");
    fresh.state.lock().unwrap().snapshot_generation = None;
    assert!(quit_wants_snapshot(&fresh, (80, 24)), "a new generation lost its output at quit");
    // A resize: the tail's bytes would replay at the old size.
    let resized = log(b"stored ", b"unwritten");
    assert!(quit_wants_snapshot(&resized, (100, 30)), "a resized terminal kept its old snapshot");
    // Unwritten bytes past what one tail frame takes.
    let flood = log(b"", &vec![b'x'; super::super::TAIL_MAX_UNWRITTEN_BYTES + 1]);
    assert!(quit_wants_snapshot(&flood, (80, 24)), "a flood past the cap did not get a snapshot");
}

#[test]
fn a_quit_appends_the_unwritten_bytes_to_the_tail_and_syncs_it() {
    let directory = directory("sync");
    let store = OutputStore::new(None);
    let log = log(b"", b"last words");
    // The tail was synced just now: a pass that is not the quit waits a second for the next sync.
    log.state.lock().unwrap().tail_synced_at = Some(Instant::now());
    flush_tail(
        &store,
        &directory,
        &log,
        Seen { digest: 2, settled: true, end: 10, size: Some((80, 24)), upload: false },
        true,
    );
    let stored = super::super::tail::bytes_after(&directory, &log.terminal_id, "g", 0);
    let state = log.state.lock().unwrap();
    let (pending, unsynced) = (state.pending.len(), state.tail_unsynced);
    drop(state);
    let _ = std::fs::remove_dir_all(&directory);
    assert_eq!(stored, b"last words");
    assert_eq!(pending, 0);
    assert!(!unsynced, "the quit left the last bytes in the tail without a sync");
}

#[test]
fn a_quit_writes_a_snapshot_for_a_terminal_on_the_alternate_screen() {
    // An update rolled back to a build before ed6ab5728d8c rebuilds a tail
    // that ends on the alternate screen without the primary screen.
    let log = log(b"stored ", b"unwritten");
    let plan = Plan::of(&log, Duration::from_secs(30));
    let alternate = super::ScreenNow { digest: 2, size: (80, 24), alternate: true };
    assert!(
        plan.wants_snapshot(alternate, true, false, true, true),
        "a terminal on the alternate screen was left to its tail at quit"
    );
    // Nothing since its snapshot: nothing to write.
    let idle = log_with_nothing_new();
    let plan = Plan::of(&idle, Duration::from_secs(30));
    let unchanged = super::ScreenNow { digest: 1, size: (80, 24), alternate: true };
    assert!(
        !plan.wants_snapshot(unchanged, true, false, true, true),
        "an unchanged screen was rewritten"
    );
}

/// A terminal whose snapshot (digest 1) holds all of its output.
fn log_with_nothing_new() -> TerminalLog {
    log(b"", b"")
}
