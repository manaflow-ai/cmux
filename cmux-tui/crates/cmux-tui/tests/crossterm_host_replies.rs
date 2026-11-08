//! The vendored Crossterm parser drops a host's OSC reply and keeps Alt+]
//! (`cmux-tui/vendor/crossterm/CMUX_PATCH.md`, "Host OSC replies are not
//! input").
//!
//! This test is in the workspace because `vendor/crossterm` is excluded from
//! it, so the vendored crate's own unit tests do not run in the workspace test
//! step. It goes through `parse_event_from_bytes`, the parser the live input
//! reader runs on each buffered byte sequence.

#![cfg(unix)]

use crossterm::event::{Event, KeyCode, KeyModifiers, parse_event_from_bytes};

#[test]
fn w5q_crossterm_drops_a_complete_host_color_reply() {
    for reply in [&b"\x1b]11;rgb:2727/2828/2222\x1b\\"[..], b"\x1b]10;rgb:fdfd/ffff/f1f1\x07"] {
        let parsed = parse_event_from_bytes(reply, false);
        assert!(parsed.is_err(), "{reply:?} was not dropped: {parsed:?}");
    }
    // A reply whose end has not come yet waits for it.
    let waiting = parse_event_from_bytes(b"\x1b]11;rgb:27", false);
    assert!(matches!(waiting, Ok(None)), "{waiting:?}");
}

#[test]
fn w5q_crossterm_keeps_alt_right_bracket() {
    let alt = |bytes: &[u8]| match parse_event_from_bytes(bytes, false) {
        Ok(Some(Event::Key(key))) => Some((key.code, key.modifiers)),
        _ => None,
    };
    assert_eq!(alt(b"\x1b]"), Some((KeyCode::Char(']'), KeyModifiers::ALT)));
}
