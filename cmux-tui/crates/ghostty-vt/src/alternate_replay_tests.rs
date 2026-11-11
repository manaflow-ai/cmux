//! A replay taken while a program holds the alternate screen keeps the
//! primary screen under it (`terminal/alternate_replay.rs`). Before, a
//! daemon that adopted a terminal host after an update while an editor was
//! open showed an empty screen with no scrollback when the editor quit.

use super::*;

const SCROLLBACK_BYTES: usize = 10_000_000;
const FULL_BUDGET: usize = 15 * 1024 * 1024;

fn terminal_with(cols: u16, rows: u16, bytes: &[u8]) -> Terminal {
    let mut term = Terminal::new(cols, rows, SCROLLBACK_BYTES, Callbacks::default()).unwrap();
    term.resize(cols, rows, 8, 16).unwrap();
    term.vt_write(bytes);
    term
}

fn total_rows(term: &Terminal) -> u64 {
    term.scrollbar().map_or(0, |scrollbar| scrollbar.total)
}

/// A shell session with `lines` of history, then a full-screen program that
/// entered the alternate screen with `enter` and drew on it.
fn shell_then_program(lines: usize, enter: &str) -> Vec<u8> {
    let mut bytes = Vec::new();
    for line in 0..lines {
        bytes.extend_from_slice(
            format!("\x1b[3{}mhistory {line:05} before the editor\x1b[0m\r\n", line % 8).as_bytes(),
        );
    }
    bytes.extend_from_slice(b"$ \x1b[1mvim notes.txt\x1b[0m");
    bytes.extend_from_slice(enter.as_bytes());
    bytes.extend_from_slice(b"\x1b[2J\x1b[H~ editor line one\r\n~ editor line two\x1b[5;12H");
    bytes
}

const ALTERNATE_MODES: [(&str, &str); 3] =
    [("\x1b[?1049h", "\x1b[?1049l"), ("\x1b[?1047h", "\x1b[?1047l"), ("\x1b[?47h", "\x1b[?47l")];

/// The mirror shows what the source shows now, and again after the program
/// leaves the alternate screen: the same screen, the same history, the cursor
/// in the same place (a byte written after the leave lands on the same cell).
fn assert_mirror_follows(source: &mut Terminal, mirror: &mut Terminal, leave: &str, what: &str) {
    assert_eq!(mirror.active_screen(), Screen::Alternate, "{what}: not on the alternate screen");
    assert_eq!(
        mirror.viewport_text().unwrap(),
        source.viewport_text().unwrap(),
        "{what}: the alternate screen differs"
    );
    for term in [&mut *source, &mut *mirror] {
        term.vt_write(leave.as_bytes());
        term.vt_write(b"X");
    }
    assert_eq!(mirror.active_screen(), Screen::Primary, "{what}");
    assert_eq!(
        mirror.viewport_text().unwrap(),
        source.viewport_text().unwrap(),
        "{what}: the primary screen under the program was lost"
    );
    assert_eq!(total_rows(mirror), total_rows(source), "{what}: history rows");
    assert_eq!(
        mirror.plain_text().unwrap(),
        source.plain_text().unwrap(),
        "{what}: the history under the program was lost"
    );
}

#[test]
fn a_replay_of_the_alternate_screen_keeps_the_primary_screen_and_its_history() {
    for (enter, leave) in ALTERNATE_MODES {
        for palette in [true, false] {
            let what = format!("enter {enter:?}, palette {palette}");
            let mut source = terminal_with(100, 30, &shell_then_program(300, enter));
            let replay = source.vt_replay_bounded_with_palette(FULL_BUDGET, palette).unwrap();
            let mut mirror = terminal_with(100, 30, &replay.self_contained_bytes());
            assert_mirror_follows(&mut source, &mut mirror, leave, &what);
        }
    }
}

/// A tail replay (a viewer that fetches older rows later) keeps the primary
/// screen too, with at most its history allowance of rows above it.
#[test]
fn a_tail_replay_of_the_alternate_screen_keeps_the_primary_screen() {
    let mut source = terminal_with(100, 30, &shell_then_program(3_000, "\x1b[?1049h"));
    let tail = source.vt_replay_tail_theme_portable_with_aliases(FULL_BUDGET, 100).unwrap();
    let mut mirror = terminal_with(100, 30, &tail.replay.self_contained_bytes());
    for term in [&mut source, &mut mirror] {
        term.vt_write(b"\x1b[?1049l");
    }
    assert_eq!(mirror.viewport_text().unwrap(), source.viewport_text().unwrap());
    assert_eq!(total_rows(&mirror), 130, "the screen and 100 rows of history");
}

/// A budget the primary history does not fit keeps the alternate screen
/// whole and the newest primary rows, never less than before.
#[test]
fn a_small_budget_keeps_the_alternate_screen_whole() {
    let mut source = terminal_with(100, 30, &shell_then_program(3_000, "\x1b[?1049h"));
    let alone = {
        let mut screen_only = terminal_with(100, 30, b"");
        screen_only.vt_write(b"\x1b[?1049h\x1b[2J\x1b[H~ editor line one\r\n~ editor line two");
        screen_only.vt_replay_bounded(FULL_BUDGET).unwrap().bytes.len()
    };
    for budget in [alone, alone + 512, 16 * 1024, 64 * 1024] {
        let Ok(replay) = source.vt_replay_bounded(budget) else { continue };
        assert!(replay.bytes.len() <= budget, "{budget}: {} bytes", replay.bytes.len());
        let mut mirror = terminal_with(100, 30, &replay.self_contained_bytes());
        assert_eq!(mirror.active_screen(), Screen::Alternate, "{budget}");
        assert_eq!(mirror.viewport_text().unwrap(), source.viewport_text().unwrap(), "{budget}");
    }
}

/// The primary screen's replay is unchanged: no copy, no extra bytes.
#[test]
fn a_replay_of_the_primary_screen_is_unchanged_after_a_program_left() {
    let mut bytes = shell_then_program(300, "\x1b[?1049h");
    bytes.extend_from_slice(b"\x1b[?1049l$ ");
    let mut source = terminal_with(100, 30, &bytes);
    let replay = source.vt_replay_bounded(FULL_BUDGET).unwrap();
    let mut mirror = terminal_with(100, 30, &replay.self_contained_bytes());
    assert_eq!(mirror.active_screen(), Screen::Primary);
    assert_eq!(mirror.plain_text().unwrap(), source.plain_text().unwrap());
}
