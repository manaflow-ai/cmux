//! A clear of rows breaks the soft wrap across the edges of the cleared rows (VT fuzz finding E2 class, review of
//! #29775, 2026-10-31). ED 0, 1 and 2 and DECALN reset the cleared rows, but the row above the range kept its wrap
//! flag (a scrollback row above the screen for ED 2) and the row below kept its continuation (the cursor row after
//! ED 1). A resize then reflowed the scrollback row and the new text after the clear into one line.

use ghostty_vt::{Callbacks, Terminal};

const SCROLLBACK: usize = 1 << 20;

/// A line soft-wraps from the bottom row, two linefeeds move its wrapping row into the scrollback, the screen is
/// cleared with `clear`, and new text goes on row 1.
fn wrap_into_scrollback_then(clear: &[u8]) -> Terminal {
    let mut term = Terminal::new(5, 3, SCROLLBACK, Callbacks::default()).unwrap();
    term.vt_write(b"\x1b[3;1Habcdefg\n\n");
    term.vt_write(clear);
    term.vt_write(b"\x1b[1;1HXY");
    assert!(term.vt_stream_is_ground());
    term
}

fn assert_kept_apart(mut term: Terminal, what: &str) {
    term.resize(12, 3, 8, 16).unwrap();
    let text = term.plain_text().unwrap();
    let lines: Vec<&str> = text.lines().map(str::trim_end).collect();
    // The clear erased "fg"; the scrollback row "abcde" no longer wraps into anything.
    assert!(
        lines.contains(&"abcde") && !lines.iter().any(|l| l.contains("abcde") && l.contains("XY")),
        "after {what} and a wider resize, the scrollback row and the new text must stay on their own rows: {lines:?}"
    );
}

#[test]
fn vt_ed2_breaks_the_wrap_from_scrollback_into_the_cleared_screen() {
    let term = wrap_into_scrollback_then(b"\x1b[2J");
    assert_kept_apart(term, "ED 2");
}

#[test]
fn vt_decaln_breaks_the_wrap_from_scrollback_into_the_filled_screen() {
    let term = wrap_into_scrollback_then(b"\x1b#8");
    assert_kept_apart(term, "DECALN");
}
