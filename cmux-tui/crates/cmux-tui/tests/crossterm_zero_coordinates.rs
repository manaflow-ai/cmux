//! A 0 position from the host terminal is malformed input, never an arithmetic
//! underflow.
//!
//! Mouse reports (normal, rxvt, SGR) and cursor position reports carry 1-based
//! positions. The vendored Crossterm parser subtracted 1 from what the host
//! terminal sent, so a 0 panicked builds with overflow checks (cmux debug builds,
//! the input thread of the TUI client) and became 65535 in release. The parser
//! now refuses it, as it already refuses a bad button byte
//! (`cmux-tui/vendor/crossterm/CMUX_PATCH.md`, "Zero terminal coordinates").
//!
//! This test is in the workspace because `vendor/crossterm` is excluded from it,
//! so the vendored crate's own unit tests do not run in the workspace test step.
//! It goes through `parse_event_from_bytes`, the parser entry the client's
//! startup input reader uses (`ui/graphics.rs`).

#![cfg(unix)]

use crossterm::event::parse_event_from_bytes;

#[test]
fn crossterm_zero_coordinates_are_refused_not_underflowed() {
    for buffer in [
        // SGR mouse: column 10, row 0; column 0, row 10.
        &b"\x1B[<0;10;0m"[..],
        b"\x1B[<0;0;10M",
        // rxvt mouse: column 0; row 0.
        b"\x1B[32;0;5M",
        b"\x1B[32;10;0M",
        // Cursor position report: row 0; column 0.
        b"\x1B[0;5R",
        b"\x1B[5;0R",
        // Normal (X10) mouse: a column byte and a row byte of 32 are position 0.
        b"\x1B[M  !",
        b"\x1B[M !\x20",
    ] {
        let parsed = std::panic::catch_unwind(|| parse_event_from_bytes(buffer, false));
        let Ok(parsed) = parsed else {
            panic!("{buffer:?} panicked in the parser (a 0 position underflowed)");
        };
        assert!(parsed.is_err(), "{buffer:?} was not refused: {parsed:?}");
    }
}

#[test]
fn crossterm_one_based_coordinates_still_parse() {
    // The control: position 1,1 is the top left cell, 0-based 0,0.
    let event = parse_event_from_bytes(b"\x1B[<0;1;1M", false).expect("parsed").expect("an event");
    let crossterm::event::Event::Mouse(mouse) = event else {
        panic!("not a mouse event: {event:?}")
    };
    assert_eq!((mouse.column, mouse.row), (0, 0));
}
