//! PTY output into libghostty-vt through the `ghostty-vt` wrapper: the bytes
//! any program in a pane can write. Chromium fuzzes its renderer-facing
//! parsers the same way (testing/libfuzzer/README.md): untrusted bytes in, no
//! crash, leak or hang out.
//!
//! The input is fed in two writes split at its middle, so an escape sequence
//! that spans `vt_write` calls is exercised; then the terminal resizes (a
//! reflow), reads its text back, and encodes a snapshot that a second
//! terminal replays, which is the restore path a daemon restart takes.
//!
//! Under cargo fuzz, ghostty-vt-sys builds libghostty-vt with
//! crates/ghostty-vt-sys/fuzzing/build.zig: ReleaseSafe and SanitizerCoverage
//! (zig -ffuzz), so libFuzzer is guided by the Zig parser's edges and a Zig
//! bounds, overflow or unreachable check panics as a crash. Those edges are
//! libFuzzer extra counters (Linux only): they count in `ft:` (features), not
//! in `cov:`, which counts only the Rust PCs. The Zig side is not
//! ASan-instrumented: a fault its safety checks do not cover is missed.

#![no_main]

use ghostty_vt::{Callbacks, SnapshotPhase, Terminal, snapshot_ready_len, snapshot_records};
use libfuzzer_sys::fuzz_target;

const COLS: u16 = 80;
const ROWS: u16 = 24;
/// Retained scrollback in bytes. Small, so the fuzzer reaches page eviction
/// quickly and one input cannot retain the 256 MiB malloc limit.
const SCROLLBACK_BYTES: usize = 256 * 1024;
/// Kitty image storage per terminal; well under the malloc limit.
const KITTY_STORAGE_BYTES: u64 = 4 * 1024 * 1024;

fn new_terminal() -> Option<Terminal> {
    let mut terminal = Terminal::new(COLS, ROWS, SCROLLBACK_BYTES, Callbacks::default()).ok()?;
    terminal.set_kitty_image_storage_limit(KITTY_STORAGE_BYTES).ok()?;
    Some(terminal)
}

fuzz_target!(|data: &[u8]| {
    // The pure-Rust snapshot record parsers read raw bytes too.
    let _ = snapshot_ready_len(data);
    for record in snapshot_records(data) {
        let _ = record.payload();
    }

    let Some(mut terminal) = new_terminal() else { return };
    let (head, tail) = data.split_at(data.len() / 2);
    terminal.vt_write(head);
    terminal.vt_write(tail);
    let _ = terminal.plain_text();
    let _ = terminal.resize(COLS / 2, ROWS / 2, 8, 16);
    let _ = terminal.viewport_text();
    let _ = terminal.resize(COLS, ROWS, 8, 16);

    let Ok(snapshot) = terminal.encode_snapshot(SnapshotPhase::Complete) else { return };
    let Some(mut restored) = new_terminal() else { return };
    restored.vt_write(&snapshot);
    let _ = restored.plain_text();
});
