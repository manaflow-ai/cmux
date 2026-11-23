use super::*;

fn terminal() -> Terminal {
    Terminal::new(40, 4, 100, ghostty_vt::Callbacks::default()).unwrap()
}

/// Feeds `stream` split at `at` and returns the terminal and the bytes it parsed.
fn feed_split(stream: &[u8], at: usize) -> (Terminal, Vec<u8>) {
    let mut term = terminal();
    let mut marks = ShellMarks::default();
    let mut parsed = Vec::new();
    for chunk in [&stream[..at], &stream[at..]] {
        parsed.extend_from_slice(&write_output(&mut term, chunk, &mut marks));
    }
    (term, parsed)
}

/// A dead program's mouse mode is reset at the next prompt mark wherever
/// the output stream splits, also inside the mark itself: a reader chunk
/// ends anywhere, and a mark split across two chunks used to be missed.
#[test]
fn a_prompt_mark_split_across_chunks_still_resets_modes() {
    let stream = b"\x1b[?1000h\x1b[?25lkilled\r\n\x1b]133;A\x07$ ";
    let (_, whole) = feed_split(stream, stream.len());
    for at in 0..=stream.len() {
        let (term, parsed) = feed_split(stream, at);
        assert!(!term.mouse_tracking(), "mouse mode survived a mark split at {at}");
        assert!(term.mode(CURSOR_VISIBLE, false), "cursor stayed hidden, split at {at}");
        assert_eq!(parsed, whole, "parsed bytes differ for a split at {at}");
    }
}

/// The keyboard modes a command left are reset at its end mark, wherever
/// the stream splits.
#[test]
fn a_command_end_mark_split_across_chunks_still_resets_keyboard_modes() {
    let stream = b"\x1b]133;C\x07\x1b[?2004h\x1b[?1004hran\r\n\x1b]133;D;0\x07";
    let (_, whole) = feed_split(stream, stream.len());
    for at in 0..=stream.len() {
        let (term, parsed) = feed_split(stream, at);
        assert!(!term.mode(2004, false), "bracketed paste survived a split at {at}");
        assert!(!term.mode(1004, false), "focus reports survived a split at {at}");
        assert_eq!(parsed, whole, "parsed bytes differ for a split at {at}");
    }
}
