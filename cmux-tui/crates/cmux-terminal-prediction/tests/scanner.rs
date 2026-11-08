//! Port of classic cmux's `TerminalOutputScannerTests.swift`.

use cmux_terminal_prediction::OutputSignal::{
    AlternateScreen, ClearAtCursor, CursorLeft, CursorLeftBy, Disruptive, Ignorable, Printable,
};
use cmux_terminal_prediction::{OutputSignal, TerminalOutputScanner};

fn scan_chunks(chunks: &[&str]) -> Vec<OutputSignal> {
    let mut scanner = TerminalOutputScanner::new();
    chunks.iter().flat_map(|chunk| scanner.scan(chunk.as_bytes())).collect()
}

fn scan(text: &str) -> Vec<OutputSignal> {
    scan_chunks(&[text])
}

#[test]
fn printable_bytes_report_as_themselves() {
    assert_eq!(scan("ab"), [Printable(0x61), Printable(0x62)]);
}

#[test]
fn control_bytes_move_the_screen() {
    assert_eq!(scan("\r\n\x07\t"), [Disruptive, Disruptive, Disruptive, Disruptive]);
}

#[test]
fn style_changes_carry_no_grid_content() {
    assert_eq!(scan("\x1b[32m"), [Ignorable]);
    assert_eq!(scan("\x1b[0;1;38;5;214m"), [Ignorable]);
}

#[test]
fn operating_system_commands_are_ignorable_with_either_terminator() {
    assert_eq!(scan("\x1b]133;D;0\x07"), [Ignorable]);
    assert_eq!(scan("\x1b]7;file:///home/dev\x1b\\"), [Ignorable]);
}

#[test]
fn an_escape_ends_a_string_sequence_and_starts_the_next_one() {
    // Ghostty leaves any string sequence at the first ESC and parses what
    // follows as a new sequence. A scanner still inside the string would
    // miss the echoes, prompts and screen changes ghostty applies.
    assert_eq!(
        scan("\x1b]0;title\x1bx more\x07"),
        [
            Disruptive,
            Printable(0x20),
            Printable(0x6D),
            Printable(0x6F),
            Printable(0x72),
            Printable(0x65),
            Disruptive,
        ]
    );
    assert_eq!(
        scan("\x1b_x\x1b[31m hi\x1b[?1049h"),
        [Ignorable, Printable(0x20), Printable(0x68), Printable(0x69), AlternateScreen(true)]
    );
}

#[test]
fn eight_bit_controls_end_a_device_control_string() {
    // In DCS, APC, PM and SOS, ghostty leaves the string on any C1 byte;
    // 0x9C is the 8-bit string terminator.
    let mut scanner = TerminalOutputScanner::new();
    assert_eq!(scanner.scan(b"\x1bPabc\x9c\x78"), [Ignorable, Printable(0x78)]);
    assert_eq!(scanner.scan(b"\x1b_abc\x85\x78"), [Disruptive, Printable(0x78)]);
}

#[test]
fn device_control_and_application_strings_are_ignorable() {
    // Their payload is printable ASCII that never reaches the grid; read
    // as printed text it would contradict a correct prediction.
    assert_eq!(scan("\x1bP+q544e\x1b\\"), [Ignorable]);
    assert_eq!(scan("\x1b_private-app\x1b\\"), [Ignorable]);
    assert_eq!(scan("\x1b^private\x1b\\"), [Ignorable]);
    assert_eq!(scan("\x1bXstart of string\x1b\\x"), [Ignorable, Printable(0x78)]);
}

#[test]
fn images_move_the_cursor_and_are_disruptive() {
    // A kitty graphics command and a sixel image both place an image and
    // leave the cursor past it.
    assert_eq!(scan("\x1b_Gf=100,a=T;AAAA\x1b\\"), [Disruptive]);
    assert_eq!(scan("\x1bP0;1q#0;2;0;0;0#0~~\x1b\\"), [Disruptive]);
    assert_eq!(scan_chunks(&["\x1b_G", "i=1;AAAA\x1b", "\\x"]), [Disruptive, Printable(0x78)]);
}

#[test]
fn a_cursor_save_and_restore_detour_is_ignorable() {
    // A status line or clock repainted elsewhere, then the cursor put
    // back where it was.
    assert_eq!(scan("\x1b7\x1b[24;70H12:01\x1b8x"), [Ignorable, Printable(0x78)]);
    assert_eq!(scan("\x1b[s\x1b[1;1Hclock\x1b[ux"), [Ignorable, Printable(0x78)]);
    // An alternate-screen switch inside still counts.
    assert_eq!(scan("\x1b7\x1b[?1049h"), [AlternateScreen(true)]);
}

#[test]
fn bel_is_payload_in_a_device_control_string() {
    // BEL is payload here, unlike in an OSC.
    assert_eq!(scan("\x1bP+q#0;2;0;0;0\x07#0!7~\x1b\\"), [Ignorable]);
    // tmux passthrough doubles each ESC inside its DCS. Ghostty ends the
    // DCS at the first ESC and runs the inner sequence, and so does this.
    assert_eq!(scan("\x1bPtmux;\x1b\x1b]0;title\x07\x1b\\"), [Ignorable, Ignorable]);
}

#[test]
fn a_device_control_string_split_across_chunks_is_still_one_signal() {
    assert_eq!(scan_chunks(&["\x1b_ai=1;", "AAAA", "\x1b", "\\x"]), [Ignorable, Printable(0x78)]);
}

#[test]
fn cancel_aborts_a_string_sequence() {
    assert_eq!(scan("\x1bPabc\x18x"), [Disruptive, Printable(0x78)]);
    assert_eq!(scan("\x1b]0;abc\x1ax"), [Disruptive, Printable(0x78)]);
}

#[test]
fn alternate_screen_modes_are_recognised_in_every_form() {
    assert_eq!(scan("\x1b[?1049h"), [AlternateScreen(true)]);
    assert_eq!(scan("\x1b[?1049l"), [AlternateScreen(false)]);
    assert_eq!(scan("\x1b[?47h"), [AlternateScreen(true)]);
    assert_eq!(scan("\x1b[?1047l"), [AlternateScreen(false)]);
}

#[test]
fn other_private_mode_changes_are_disruptive() {
    // Bracketed paste and mouse reporting change what input means, so the
    // echo stops being predictable.
    assert_eq!(scan("\x1b[?2004h"), [Disruptive]);
    assert_eq!(scan("\x1b[?1002h"), [Disruptive]);
}

#[test]
fn cursor_motion_is_disruptive() {
    assert_eq!(scan("\x1b[3D"), [CursorLeftBy(3)]);
    assert_eq!(scan("\x1b[2K"), [Disruptive]);
    assert_eq!(scan("\x1b[H"), [Disruptive]);
}

#[test]
fn one_cell_erase_halves_are_reported_for_the_engine_to_judge() {
    // A line editor erasing one character moves left, then clears.
    assert_eq!(scan("\x08"), [CursorLeft]);
    assert_eq!(scan("\x1b[D\x1b[1D"), [CursorLeft, CursorLeft]);
    assert_eq!(
        scan("\x1b[K\x1b[0K\x1b[P\x1b[1P"),
        [ClearAtCursor, ClearAtCursor, ClearAtCursor, ClearAtCursor]
    );
    // Other erase modes, wider deletes and selective erase are redraws.
    // A wider move left is reported with its count for the engine's
    // model of the line to judge.
    assert_eq!(
        scan("\x1b[2D\x1b[1K\x1b[2P\x1b[?K"),
        [CursorLeftBy(2), Disruptive, Disruptive, Disruptive]
    );
}

#[test]
fn a_sequence_split_across_chunks_is_still_one_signal() {
    // libghostty delivers whatever the read returned, so a sequence can
    // arrive a byte at a time. Re-synchronising per chunk would read this
    // as several disruptive events and withdraw a correct prediction.
    assert_eq!(scan_chunks(&["\x1b", "[", "?", "1", "0", "4", "9", "h"]), [AlternateScreen(true)]);
    assert_eq!(scan_chunks(&["a\x1b[3", "2mb"]), [Printable(0x61), Ignorable, Printable(0x62)]);
    assert_eq!(scan_chunks(&["\x1b]133;C\x1b", "\\x"]), [Ignorable, Printable(0x78)]);
}

#[test]
fn an_overlong_control_sequence_stays_bounded_and_classifies() {
    // The remote controls sequence length; parameters past the cap are
    // dropped, not stored, and must not truncate into a false match.
    let digits = "9".repeat(100_000);
    assert_eq!(scan(&format!("\x1b[?1049{digits}h")), [Disruptive]);
    assert_eq!(scan(&format!("\x1b[38;2;{digits}mx")), [Ignorable, Printable(0x78)]);
    // The cap resets per sequence.
    assert_eq!(scan(&format!("\x1b[{digits}H\x1b[?1049h")), [Disruptive, AlternateScreen(true)]);
}

#[test]
fn an_unknown_escape_is_disruptive_and_recovers() {
    assert_eq!(scan("\x1bMx"), [Disruptive, Printable(0x78)]);
}

#[test]
fn designating_ascii_is_ignorable() {
    // xterm's sgr0 is `ESC ( B ESC [ m`; shells emit it around the
    // characters they echo, so it must not read as `(` then a printed B.
    assert_eq!(scan("\x1b(B\x1b[m"), [Ignorable, Ignorable]);
    assert_eq!(scan("\x1b)Bx"), [Ignorable, Printable(0x78)]);
    assert_eq!(scan_chunks(&["\x1b(", "B"]), [Ignorable]);
}

#[test]
fn designating_another_character_set_is_disruptive() {
    // DEC line drawing remaps later printables, so the echo no longer
    // matches the key that was typed.
    assert_eq!(scan("\x1b(0x"), [Disruptive, Printable(0x78)]);
    assert_eq!(scan("\x1b#8x"), [Disruptive, Printable(0x78)]);
}
