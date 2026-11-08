//! Port of classic cmux's TerminalOutputScannerTests.swift.

use cmux_terminal_prediction::TerminalOutputScanner;
use cmux_terminal_prediction::TerminalOutputSignal::{
    self, AlternateScreen, ClearAtCursor, CursorLeft, CursorLeftBy, Disruptive, Ignorable, Printable,
};

fn scan_chunks(chunks: &[&str]) -> Vec<TerminalOutputSignal> {
    let mut scanner = TerminalOutputScanner::new();
    chunks.iter().flat_map(|chunk| scanner.scan(chunk.as_bytes())).collect()
}

fn scan(text: &str) -> Vec<TerminalOutputSignal> {
    scan_chunks(&[text])
}

#[test]
fn printable_bytes_report_as_themselves() {
    assert_eq!(scan("ab"), [Printable(0x61), Printable(0x62)]);
}

#[test]
fn control_bytes_move_the_screen() {
    assert_eq!(scan("\r\n\u{7}\t"), [Disruptive, Disruptive, Disruptive, Disruptive]);
}

#[test]
fn style_changes_carry_no_grid_content() {
    assert_eq!(scan("\u{1B}[32m"), [Ignorable]);
    assert_eq!(scan("\u{1B}[0;1;38;5;214m"), [Ignorable]);
}

#[test]
fn operating_system_commands_are_ignorable_with_either_terminator() {
    assert_eq!(scan("\u{1B}]133;D;0\u{7}"), [Ignorable]);
    assert_eq!(scan("\u{1B}]7;file:///home/dev\u{1B}\\"), [Ignorable]);
}

#[test]
fn an_escape_ends_a_string_sequence_and_starts_the_next_one() {
    // Ghostty leaves any string sequence at the first ESC and parses what
    // follows as a new sequence. A scanner still inside the string would
    // miss the echoes, prompts and screen changes ghostty applies.
    assert_eq!(
        scan("\u{1B}]0;title\u{1B}x more\u{7}"),
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
        scan("\u{1B}_x\u{1B}[31m hi\u{1B}[?1049h"),
        [Ignorable, Printable(0x20), Printable(0x68), Printable(0x69), AlternateScreen(true)]
    );
}

#[test]
fn eight_bit_controls_end_a_device_control_string() {
    // In DCS, APC, PM and SOS, ghostty leaves the string on any C1 byte;
    // 0x9C is the 8-bit string terminator.
    let mut scanner = TerminalOutputScanner::new();
    let mut dcs = b"\x1BPabc".to_vec();
    dcs.extend([0x9C, 0x78]);
    assert_eq!(scanner.scan(&dcs), [Ignorable, Printable(0x78)]);
    let mut apc = b"\x1B_abc".to_vec();
    apc.extend([0x85, 0x78]);
    assert_eq!(scanner.scan(&apc), [Disruptive, Printable(0x78)]);
}

#[test]
fn device_control_and_application_strings_are_ignorable() {
    // Their payload is printable ASCII that never reaches the grid; read
    // as printed text it would contradict a correct prediction.
    assert_eq!(scan("\u{1B}P+q544e\u{1B}\\"), [Ignorable]);
    assert_eq!(scan("\u{1B}_private-app\u{1B}\\"), [Ignorable]);
    assert_eq!(scan("\u{1B}^private\u{1B}\\"), [Ignorable]);
    assert_eq!(scan("\u{1B}Xstart of string\u{1B}\\x"), [Ignorable, Printable(0x78)]);
}

#[test]
fn images_move_the_cursor_and_are_disruptive() {
    // A kitty graphics command and a sixel image both place an image and
    // leave the cursor past it.
    assert_eq!(scan("\u{1B}_Gf=100,a=T;AAAA\u{1B}\\"), [Disruptive]);
    assert_eq!(scan("\u{1B}P0;1q#0;2;0;0;0#0~~\u{1B}\\"), [Disruptive]);
    assert_eq!(scan_chunks(&["\u{1B}_G", "i=1;AAAA\u{1B}", "\\x"]), [Disruptive, Printable(0x78)]);
}

#[test]
fn a_cursor_save_and_restore_detour_is_ignorable() {
    // A status line or clock repainted elsewhere, then the cursor put
    // back where it was.
    assert_eq!(scan("\u{1B}7\u{1B}[24;70H12:01\u{1B}8x"), [Ignorable, Printable(0x78)]);
    assert_eq!(scan("\u{1B}[s\u{1B}[1;1Hclock\u{1B}[ux"), [Ignorable, Printable(0x78)]);
    // An alternate-screen switch inside still counts.
    assert_eq!(scan("\u{1B}7\u{1B}[?1049h"), [AlternateScreen(true)]);
}

#[test]
fn bel_is_payload_in_a_device_control_string() {
    // BEL is payload here, unlike in an OSC.
    assert_eq!(scan("\u{1B}P+q#0;2;0;0;0\u{7}#0!7~\u{1B}\\"), [Ignorable]);
    // tmux passthrough doubles each ESC inside its DCS. Ghostty ends the
    // DCS at the first ESC and runs the inner sequence, and so does this.
    assert_eq!(scan("\u{1B}Ptmux;\u{1B}\u{1B}]0;title\u{7}\u{1B}\\"), [Ignorable, Ignorable]);
}

#[test]
fn a_device_control_string_split_across_chunks_is_still_one_signal() {
    assert_eq!(scan_chunks(&["\u{1B}_ai=1;", "AAAA", "\u{1B}", "\\x"]), [Ignorable, Printable(0x78)]);
}

#[test]
fn cancel_aborts_a_string_sequence() {
    assert_eq!(scan("\u{1B}Pabc\u{18}x"), [Disruptive, Printable(0x78)]);
    assert_eq!(scan("\u{1B}]0;abc\u{1A}x"), [Disruptive, Printable(0x78)]);
}

#[test]
fn alternate_screen_modes_are_recognised_in_every_form() {
    assert_eq!(scan("\u{1B}[?1049h"), [AlternateScreen(true)]);
    assert_eq!(scan("\u{1B}[?1049l"), [AlternateScreen(false)]);
    assert_eq!(scan("\u{1B}[?47h"), [AlternateScreen(true)]);
    assert_eq!(scan("\u{1B}[?1047l"), [AlternateScreen(false)]);
}

#[test]
fn other_private_mode_changes_are_disruptive() {
    // Bracketed paste and mouse reporting change what input means, so the
    // echo stops being predictable.
    assert_eq!(scan("\u{1B}[?2004h"), [Disruptive]);
    assert_eq!(scan("\u{1B}[?1002h"), [Disruptive]);
}

#[test]
fn cursor_motion_is_disruptive() {
    assert_eq!(scan("\u{1B}[3D"), [CursorLeftBy(3)]);
    assert_eq!(scan("\u{1B}[2K"), [Disruptive]);
    assert_eq!(scan("\u{1B}[H"), [Disruptive]);
}

#[test]
fn one_cell_erase_halves_are_reported_for_the_engine_to_judge() {
    // A line editor erasing one character moves left, then clears.
    assert_eq!(scan("\u{8}"), [CursorLeft]);
    assert_eq!(scan("\u{1B}[D\u{1B}[1D"), [CursorLeft, CursorLeft]);
    assert_eq!(
        scan("\u{1B}[K\u{1B}[0K\u{1B}[P\u{1B}[1P"),
        [ClearAtCursor, ClearAtCursor, ClearAtCursor, ClearAtCursor]
    );
    // Other erase modes, wider deletes and selective erase are redraws.
    // A wider move left is reported with its count for the engine's
    // model of the line to judge.
    assert_eq!(
        scan("\u{1B}[2D\u{1B}[1K\u{1B}[2P\u{1B}[?K"),
        [CursorLeftBy(2), Disruptive, Disruptive, Disruptive]
    );
}

#[test]
fn a_sequence_split_across_chunks_is_still_one_signal() {
    // libghostty delivers whatever the read returned, so a sequence can
    // arrive a byte at a time. Re-synchronising per chunk would read this
    // as several disruptive events and withdraw a correct prediction.
    assert_eq!(scan_chunks(&["\u{1B}", "[", "?", "1", "0", "4", "9", "h"]), [AlternateScreen(true)]);
    assert_eq!(scan_chunks(&["a\u{1B}[3", "2mb"]), [Printable(0x61), Ignorable, Printable(0x62)]);
    assert_eq!(scan_chunks(&["\u{1B}]133;C\u{1B}", "\\x"]), [Ignorable, Printable(0x78)]);
}

#[test]
fn an_overlong_control_sequence_stays_bounded_and_classifies() {
    // The remote controls sequence length; parameters past the cap are
    // dropped, not stored, and must not truncate into a false match.
    let digits = "9".repeat(100_000);
    assert_eq!(scan(&format!("\u{1B}[?1049{digits}h")), [Disruptive]);
    assert_eq!(scan(&format!("\u{1B}[38;2;{digits}mx")), [Ignorable, Printable(0x78)]);
    // The cap resets per sequence.
    assert_eq!(scan(&format!("\u{1B}[{digits}H\u{1B}[?1049h")), [Disruptive, AlternateScreen(true)]);
}

#[test]
fn an_unknown_escape_is_disruptive_and_recovers() {
    assert_eq!(scan("\u{1B}Mx"), [Disruptive, Printable(0x78)]);
}

#[test]
fn designating_ascii_is_ignorable() {
    // xterm's sgr0 is `ESC ( B ESC [ m`; shells emit it around the
    // characters they echo, so it must not read as `(` then a printed B.
    assert_eq!(scan("\u{1B}(B\u{1B}[m"), [Ignorable, Ignorable]);
    assert_eq!(scan("\u{1B})Bx"), [Ignorable, Printable(0x78)]);
    assert_eq!(scan_chunks(&["\u{1B}(", "B"]), [Ignorable]);
}

#[test]
fn designating_another_character_set_is_disruptive() {
    // DEC line drawing remaps later printables, so the echo no longer
    // matches the key that was typed.
    assert_eq!(scan("\u{1B}(0x"), [Disruptive, Printable(0x78)]);
    assert_eq!(scan("\u{1B}#8x"), [Disruptive, Printable(0x78)]);
}

#[test]
fn skim_keeps_the_parse_state_scan_would() {
    // Not in the Swift suite: skim jumps over text but must leave the
    // scanner where scan would, so a sequence split across a skimmed chunk
    // and a scanned one still classifies once.
    let mut scanner = TerminalOutputScanner::new();
    let skim = scanner.skim(b"total 48\r\nfile\x1B[?10");
    assert!(skim.touched_the_screen);
    assert_eq!(skim.alternate_screen, None);
    assert_eq!(scanner.scan(b"49hx"), [AlternateScreen(true), Printable(0x78)]);
}
