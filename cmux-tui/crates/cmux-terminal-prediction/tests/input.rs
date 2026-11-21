//! `InputKind::of`, and `TerminalPredictionEngine::sent`, which routes each
//! write Ghostty makes to the entry point Swift's host called for the key.
//! cmux NEXT only: classic read the key before Ghostty encoded it.

use cmux_terminal_prediction::{
    InputKind, PredictionConfiguration, Standing, Status, TerminalPredictionEngine,
};
use std::time::Duration;

fn ms(milliseconds: u64) -> Duration {
    Duration::from_millis(milliseconds)
}

#[test]
fn one_printable_ascii_byte_is_that_key() {
    assert_eq!(InputKind::of(b"a"), InputKind::Printable(b'a'));
    assert_eq!(InputKind::of(b" "), InputKind::Printable(b' '));
    assert_eq!(InputKind::of(b"~"), InputKind::Printable(b'~'));
}

#[test]
fn del_and_bs_are_backspace() {
    assert_eq!(InputKind::of(&[0x7F]), InputKind::Backspace);
    assert_eq!(InputKind::of(&[0x08]), InputKind::Backspace);
}

#[test]
fn ctrl_u_ctrl_w_and_option_backspace_erase_the_line() {
    let line_erases: [&[u8]; 4] = [&[0x15], &[0x17], &[0x1B, 0x7F], &[0x1B, 0x08]];
    for bytes in line_erases {
        assert_eq!(InputKind::of(bytes), InputKind::LineErase, "{bytes:?}");
    }
}

#[test]
fn focus_reports_are_nothing() {
    assert_eq!(InputKind::of(b"\x1b[I"), InputKind::Nothing);
    assert_eq!(InputKind::of(b"\x1b[O"), InputKind::Nothing);
}

#[test]
fn everything_else_is_untracked() {
    let untracked: [&[u8]; 10] = [
        b"",
        b"\r",
        b"\x03",
        b"ab",
        b"\x1b",
        b"\x1b[D",
        b"\x1b[3~",
        b"\x1b[200~pasted\x1b[201~",
        "é".as_bytes(),
        &[0x80],
    ];
    for bytes in untracked {
        assert_eq!(InputKind::of(bytes), InputKind::Untracked, "{bytes:?}");
    }
}

/// Two echoed characters over a 70 ms link, then a presented frame.
fn armed_engine() -> TerminalPredictionEngine {
    let mut engine = TerminalPredictionEngine::new(PredictionConfiguration::default(), true, true);
    engine.typed(Some(b'l'), ms(10));
    engine.observed_output(b"l", ms(80));
    engine.typed(Some(b's'), ms(90));
    engine.observed_output(b"s", ms(160));
    engine.presented_frame(ms(160));
    assert_eq!(engine.status(ms(160)), Status::Predicting);
    engine
}

#[test]
fn sending_a_printable_byte_is_typing_it() {
    let mut by_bytes = armed_engine();
    let mut by_key = armed_engine();

    assert_eq!(by_bytes.sent(b"a", ms(170)), by_key.typed(Some(b'a'), ms(170)));
    assert_eq!(by_bytes.glyphs(), by_key.glyphs());
    let drawn = by_bytes.glyphs();
    assert_eq!(drawn.len(), 1);
    assert_eq!(drawn[0].character, b'a');
    assert_eq!(drawn[0].offset, 0);
    assert_eq!(drawn[0].standing, Standing::Speculative);
}

#[test]
fn sending_each_kind_reaches_its_entry_point() {
    // Backspace retracts the glyph, as `typed_backspace` does: its cell is
    // drawn blank until the remote's erase lands.
    let mut by_bytes = armed_engine();
    let mut by_key = armed_engine();
    by_bytes.sent(b"a", ms(170));
    by_key.typed(Some(b'a'), ms(170));
    assert_eq!(by_bytes.sent(&[0x7F], ms(180)), by_key.typed_backspace(ms(180)));
    assert_eq!(by_bytes.glyphs(), by_key.glyphs());
    assert_eq!(by_bytes.glyphs().len(), 1);
    assert_eq!(by_bytes.glyphs()[0].standing, Standing::Erased);

    // Ctrl-U blanks the glyph in flight, as `typed_line_erase` does.
    let mut by_bytes = armed_engine();
    let mut by_key = armed_engine();
    by_bytes.sent(b"a", ms(170));
    by_key.typed(Some(b'a'), ms(170));
    assert_eq!(by_bytes.sent(&[0x15], ms(180)), by_key.typed_line_erase(ms(180)));
    assert_eq!(by_bytes.glyphs(), by_key.glyphs());

    // A focus report keeps the glyph and the run, as `typed_nothing` does.
    let mut by_bytes = armed_engine();
    by_bytes.sent(b"a", ms(170));
    assert!(!by_bytes.sent(b"\x1b[I", ms(180)));
    by_bytes.sent(b"b", ms(190));
    assert_eq!(by_bytes.glyphs().len(), 2);
    assert_eq!(by_bytes.status(ms(190)), Status::Predicting);

    // Return is untracked, as `typed(None)` is: the glyph already sent
    // stays drawn behind a barrier, and nothing typed after it is drawn.
    let mut by_bytes = armed_engine();
    let mut by_key = armed_engine();
    by_bytes.sent(b"a", ms(170));
    by_key.typed(Some(b'a'), ms(170));
    assert_eq!(by_bytes.sent(b"\r", ms(180)), by_key.typed(None, ms(180)));
    by_bytes.sent(b"b", ms(190));
    by_key.typed(Some(b'b'), ms(190));
    assert_eq!(by_bytes.glyphs(), by_key.glyphs());
    assert_eq!(by_bytes.glyphs().len(), 1);
}
