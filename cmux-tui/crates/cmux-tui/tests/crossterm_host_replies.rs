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

/// One read of input as the live reader parses it: each event as
/// `(code, modifiers)`, in order.
fn keys(bytes: &[u8]) -> Vec<(KeyCode, KeyModifiers)> {
    crossterm::event::parse_events_from_bytes(bytes)
        .into_iter()
        .map(|event| match event {
            Event::Key(key) => (key.code, key.modifiers),
            other => panic!("{bytes:?} gave a non-key event {other:?}"),
        })
        .collect()
}

const ALT_BRACKET: (KeyCode, KeyModifiers) = (KeyCode::Char(']'), KeyModifiers::ALT);

fn plain(c: char) -> (KeyCode, KeyModifiers) {
    (KeyCode::Char(c), KeyModifiers::NONE)
}

/// W5-Q review (PR B finding 3): Alt+] and the keys typed after it in the
/// same read (SSH latency, key repeat, a loaded machine, a host without the
/// kitty keyboard protocol) are all input. The parser once waited for a
/// reply's end, then gave Alt+] and dropped the rest of the read.
#[test]
fn w5q_crossterm_keeps_the_keys_after_alt_right_bracket() {
    assert_eq!(keys(b"\x1b]a"), [ALT_BRACKET, plain('a')], "Alt+] then a");
    assert_eq!(
        keys(b"\x1b]\x1b[A"),
        [ALT_BRACKET, (KeyCode::Up, KeyModifiers::NONE)],
        "Alt+] then Up"
    );
    assert_eq!(keys(b"\x1b]\x1b]\x1b]"), [ALT_BRACKET; 3], "Alt+] key repeat");
    assert_eq!(keys(b"\x1b]\r"), [ALT_BRACKET, (KeyCode::Enter, KeyModifiers::NONE)]);
    assert_eq!(keys(b"\x1b]"), [ALT_BRACKET], "Alt+] alone");
}

/// Only the replies the client asks for (`ESC ] 10 ;` and `ESC ] 11 ;`) are
/// held for their end, and only for a bounded length of printable text:
/// `ESC ] 1 2` is Alt+] and typed `12`, and a long unterminated start is
/// typed text, never held.
#[test]
fn w5q_crossterm_holds_only_a_bounded_color_reply() {
    assert_eq!(
        keys(b"\x1b]12x"),
        [ALT_BRACKET, plain('1'), plain('2'), plain('x')],
        "ESC ] 1 2 is no color reply"
    );
    let long = [&b"\x1b]11;"[..], &[b'x'; 100]].concat();
    let parsed = keys(&long);
    assert_eq!(parsed.first(), Some(&ALT_BRACKET), "{parsed:?}");
    assert_eq!(parsed.len(), long.len() - 1, "every byte after ESC ] is a key: {parsed:?}");
    // A reply with a control byte in it is keys too: nothing is lost.
    assert_eq!(
        keys(b"\x1b]11;a\rb"),
        [
            ALT_BRACKET,
            plain('1'),
            plain('1'),
            plain(';'),
            plain('a'),
            (KeyCode::Enter, KeyModifiers::NONE),
            plain('b'),
        ]
    );
    // A whole color reply is still dropped, and a key after it stays.
    assert_eq!(keys(b"\x1b]11;rgb:2727/2828/2222\x1b\\a"), [plain('a')]);
    assert_eq!(keys(b"\x1b]10;rgb:fdfd/ffff/f1f1\x07b"), [plain('b')]);
}

/// The startup input reader parses one event at a time with more input
/// waiting; the event says how many bytes it used, so a key after Alt+] is
/// not swallowed with it.
#[test]
fn w5q_crossterm_alt_right_bracket_uses_two_bytes() {
    let parsed = crossterm::event::parse_event_len_from_bytes(b"\x1b]a", true).ok().flatten();
    let parsed = parsed.map(|(event, used)| (event.as_key_event().map(|key| key.code), used));
    assert_eq!(parsed, Some((Some(KeyCode::Char(']')), 2)));
}
