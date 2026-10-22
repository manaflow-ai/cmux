//! Terminal output bytes (what a program writes to its pty) through the
//! ghostty-vt terminal, then the snapshot and replay paths that read the
//! state those bytes built. The first byte picks the size and chunking.
#![no_main]

use ghostty_vt::{Callbacks, Terminal};
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let Some((&shape, bytes)) = data.split_first() else { return };
    let cols = 2 + u16::from(shape & 0x3f);
    let rows = 1 + u16::from(shape >> 6) * 8;
    let Ok(mut terminal) = Terminal::new(cols, rows, 64 * 1024, Callbacks::default()) else {
        return;
    };
    // Feed in uneven chunks so escape sequences split across writes.
    let chunk = 1 + usize::from(shape % 7) * 13;
    for (index, piece) in bytes.chunks(chunk).enumerate() {
        terminal.vt_write(piece);
        if index == 3 {
            let _ = terminal.resize(cols.saturating_add(5), rows.saturating_add(1), 8, 16);
        }
    }
    let _ = terminal.cursor_position();
    let _ = terminal.viewport_text();
    let _ = terminal.latest_input_text(4);
    let _ = terminal.kitty_graphics_snapshot();
    // The replay a reattach sends must itself be accepted by a fresh terminal.
    if let Ok(replay) = terminal.vt_replay_bounded_bytes(256 * 1024) {
        if let Ok(mut fresh) = Terminal::new(cols, rows, 64 * 1024, Callbacks::default()) {
            fresh.vt_write(&replay);
            let _ = fresh.viewport_text();
        }
    }
});
