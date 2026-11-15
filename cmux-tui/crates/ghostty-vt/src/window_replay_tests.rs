//! A window replay (`terminal/window_replay.rs`) gives a mirror the history
//! rows it asked for and the screen, and none of the rows between them.

use super::*;

const SCROLLBACK_BYTES: usize = 64 * 1024 * 1024;
const BUDGET: usize = 15 * 1024 * 1024;

fn history_line(line: usize) -> String {
    format!(
        "\x1b[3{}mline {line:06}\x1b[0m compiling crate-{} v0.{}",
        line % 8,
        line % 977,
        line % 13
    )
}

fn shell_with(lines: usize) -> Terminal {
    let mut term = Terminal::new(80, 24, SCROLLBACK_BYTES, Callbacks::default()).unwrap();
    for line in 0..lines {
        term.vt_write(format!("{}\r\n", history_line(line)).as_bytes());
    }
    term.vt_write(b"$ make\r\nbuilding\r\n$ ");
    term
}

fn mirror_of(source: &Terminal, replay: &VtReplay) -> Terminal {
    let mut mirror =
        Terminal::new(source.cols(), source.rows(), SCROLLBACK_BYTES, Callbacks::default())
            .unwrap();
    mirror.vt_write(&replay.bytes);
    mirror.vt_write(&replay.pending_sequence);
    mirror
}

fn plain_lines(term: &mut Terminal) -> Vec<String> {
    term.plain_text().unwrap().lines().map(str::to_owned).collect()
}

#[test]
fn a_window_far_above_the_screen_holds_its_rows_then_the_screen() {
    let mut source = shell_with(5_000);
    let history = u64::from(source.history_rows());
    let window = source.vt_replay_window_theme_portable_with_aliases(BUDGET, 1_000, 200).unwrap();
    let window = window.expect("a window far above the screen");
    assert_eq!(window.history_rows_omitted, 1_000);
    assert_eq!(window.history_rows_skipped, history - 1_200);
    let mut mirror = mirror_of(&source, &window.replay);
    assert_eq!(u64::from(mirror.history_rows()), 200, "the mirror's history is the window");
    let lines = plain_lines(&mut mirror);
    assert_eq!(lines.first().map(String::as_str), Some("line 001000 compiling crate-23 v0.12"));
    assert_eq!(lines.get(199).map(String::as_str), Some("line 001199 compiling crate-222 v0.3"));
    assert_eq!(mirror.viewport_text().unwrap(), source.viewport_text().unwrap(), "the screen");
    // The cursor is where the source's is: the next byte lands on the same cell.
    for term in [&mut source, &mut mirror] {
        term.vt_write(b"X");
    }
    assert_eq!(mirror.viewport_text().unwrap(), source.viewport_text().unwrap());
}

#[test]
fn the_window_at_the_top_reaches_line_one() {
    let mut source = shell_with(5_000);
    let window =
        source.vt_replay_window_theme_portable_with_aliases(BUDGET, 0, 300).unwrap().unwrap();
    assert_eq!(window.history_rows_omitted, 0);
    let mut mirror = mirror_of(&source, &window.replay);
    assert_eq!(
        plain_lines(&mut mirror).first().map(String::as_str),
        Some("line 000000 compiling crate-0 v0.0")
    );
}

#[test]
fn a_window_that_reaches_the_screen_or_an_alternate_screen_is_left_to_a_tail() {
    let mut source = shell_with(500);
    let history = u64::from(source.history_rows());
    assert!(
        source
            .vt_replay_window_theme_portable_with_aliases(BUDGET, 100, history)
            .unwrap()
            .is_none()
    );
    assert!(source.vt_replay_window_theme_portable_with_aliases(BUDGET, 0, 0).unwrap().is_none());
    source.vt_write(b"\x1b[?1049h\x1b[2J\x1b[Heditor");
    assert!(source.vt_replay_window_theme_portable_with_aliases(BUDGET, 0, 100).unwrap().is_none());
}

/// Wrapped lines keep their rows on both sides of the gap.
#[test]
fn wrapped_rows_keep_their_places_around_the_gap() {
    let mut source = Terminal::new(40, 10, SCROLLBACK_BYTES, Callbacks::default()).unwrap();
    for line in 0..2_000 {
        source.vt_write(format!("{line:05} {}\r\n", "w".repeat(line % 90)).as_bytes());
    }
    let window =
        source.vt_replay_window_theme_portable_with_aliases(BUDGET, 500, 400).unwrap().unwrap();
    let mut mirror = mirror_of(&source, &window.replay);
    assert_eq!(u64::from(mirror.history_rows()), 400);
    assert_eq!(mirror.viewport_text().unwrap(), source.viewport_text().unwrap());
    let mirror_lines = plain_lines(&mut mirror);
    let source_lines = plain_lines(&mut source);
    assert_eq!(mirror_lines[..400], source_lines[500..900]);
}
