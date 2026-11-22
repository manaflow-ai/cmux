//! A resize's OSC 133 prompt clear waits for the shell (close-then-type
//! empty fresh screen). zsh reads the two SIGWINCHes of a 34 -> 35 -> 34
//! bounce as one, finds its old size and redraws nothing, so a clear at
//! each resize left the prompt blank for good.

use super::*;

/// A prompt as Ghostty's zsh integration marks it: redraw=1, then input.
const PROMPT: &[u8] = b"\x1b]133;A;redraw=1\x07J> \x1b]133;B\x07";

fn at_prompt(cols: u16) -> Terminal {
    let mut term = Terminal::new(cols, 6, 1_000_000, Callbacks::default()).unwrap();
    term.resize(cols, 6, 8, 16).unwrap();
    term.vt_write(PROMPT);
    term
}

#[test]
fn prompt_clear_a_bounce_the_shell_never_answers_keeps_the_prompt() {
    let mut term = at_prompt(34);
    term.resize(35, 6, 8, 16).unwrap();
    term.resize(34, 6, 8, 16).unwrap();
    // zsh redraws nothing for its old size; its next byte is the echo of
    // the key the person types.
    term.vt_write(b"l");
    assert_eq!(term.plain_text().unwrap(), "J> l", "the bounce cleared the prompt");
}

#[test]
fn prompt_clear_a_real_resize_clears_just_before_the_shell_redraw() {
    let mut term = at_prompt(34);
    term.resize(20, 6, 8, 16).unwrap();
    // The prompt stays until the shell answers the new size (the screen
    // read drops trailing blanks).
    assert_eq!(term.plain_text().unwrap(), "J>");
    // zsh's SIGWINCH redraw: its first byte runs the clear, so the redraw
    // leaves one prompt.
    term.vt_write(b"\r");
    assert_eq!(term.plain_text().unwrap(), "");
    term.vt_write(PROMPT);
    assert_eq!(term.plain_text().unwrap(), "J>");
}

fn prompt_redraw_records(snapshot: &[u8]) -> Vec<Vec<u8>> {
    crate::snapshot::snapshot_records(snapshot)
        .filter(|record| record.tag == crate::snapshot::tag::PROMPT_REDRAW)
        .map(|record| record.payload().to_vec())
        .collect()
}

#[test]
fn prompt_clear_a_snapshot_carries_the_waiting_clear_to_a_mirror() {
    let mut term = at_prompt(34);
    // At rest no clear waits: the snapshot has no PROMPT_REDRAW record.
    let rest = term.encode_snapshot(crate::snapshot::SnapshotPhase::Complete).unwrap();
    assert!(prompt_redraw_records(&rest).is_empty());

    // A real resize the shell has not answered: the READY a viewer gets
    // now carries the waiting clear (drawn at 34 x 6), and a terminal
    // restored from it keeps it (its own READY has the same record).
    term.resize(20, 6, 8, 16).unwrap();
    let complete = term.encode_snapshot(crate::snapshot::SnapshotPhase::Complete).unwrap();
    let records = prompt_redraw_records(&complete);
    assert_eq!(records.len(), 1, "the snapshot dropped the waiting clear");
    assert_eq!(&records[0][..4], &[34, 0, 6, 0], "the grid the shell drew at");
    let restored = crate::snapshot::reencode_ready(&complete).unwrap();
    assert_eq!(prompt_redraw_records(&restored), records, "the restore dropped the waiting clear");

    // The shell's first byte runs the clear; no clear waits after it.
    term.vt_write(b"\r");
    let answered = term.encode_snapshot(crate::snapshot::SnapshotPhase::Complete).unwrap();
    assert!(prompt_redraw_records(&answered).is_empty());
}

/// A prompt longer than the narrow grid, so a narrowing wraps it to two
/// rows (26 columns).
const LONG_PROMPT: &[u8] = b"\x1b]133;A;redraw=1\x07lawrence@mini:~/fun/cmux> \x1b]133;B\x07";

/// The byte replay budget of the daemon's mirrors (`VT_REPLAY_MAX_BYTES`).
const REPLAY_BYTES: usize = 15 * 1024 * 1024;

/// A shell at a long prompt under ten lines of output, 34 x 6.
fn host_at_long_prompt() -> Terminal {
    let mut host = Terminal::new(34, 6, 1_000_000, Callbacks::default()).unwrap();
    host.resize(34, 6, 8, 16).unwrap();
    for line in 0..10 {
        host.vt_write(format!("output line {line}\r\n").as_bytes());
    }
    host.vt_write(LONG_PROMPT);
    host
}

/// A byte mirror (remote session, hosted reader, the app's byte mode, iOS):
/// a fresh terminal of the host's size that writes the host's replay.
fn mirror_from_replay(host: &mut Terminal) -> Terminal {
    let replay = host.vt_replay_bounded_theme_portable_with_aliases(REPLAY_BYTES).unwrap();
    let mut mirror =
        Terminal::new(host.cols(), host.rows(), 1_000_000, Callbacks::default()).unwrap();
    mirror.resize(host.cols(), host.rows(), 8, 16).unwrap();
    mirror.vt_write(&replay.self_contained_bytes());
    mirror
}

#[test]
fn prompt_clear_a_mirror_rebuilt_after_a_narrowing_shows_one_prompt() {
    let mut host = host_at_long_prompt();
    host.resize(20, 6, 8, 16).unwrap();
    let mut mirror = mirror_from_replay(&mut host);
    // Building the replay leaves the host's clear waiting for the shell.
    let snapshot = host.encode_snapshot(crate::snapshot::SnapshotPhase::Complete).unwrap();
    assert_eq!(prompt_redraw_records(&snapshot).len(), 1, "the replay ran the host's clear");

    // zsh answers the new size: it returns to the line start and draws its
    // prompt again. The host clears at the first byte; the mirror must show
    // the same screen, not a second copy of the prompt (#21341).
    for bytes in [&b"\r"[..], LONG_PROMPT] {
        host.vt_write(bytes);
        mirror.vt_write(bytes);
    }
    let host_text = host.plain_text().unwrap();
    assert_eq!(host_text.matches("lawrence@mini").count(), 1, "host: {host_text:?}");
    assert!(host_text.contains("output line 0"), "host lost its history: {host_text:?}");
    assert_eq!(mirror.plain_text().unwrap(), host_text, "the mirror shows another screen");
}

#[test]
fn prompt_clear_a_mirror_rebuilt_at_each_step_of_a_bounce_keeps_the_prompt() {
    let mut host = host_at_long_prompt();
    let before = host.plain_text().unwrap();
    host.resize(35, 6, 8, 16).unwrap();
    let _ = mirror_from_replay(&mut host);
    host.resize(34, 6, 8, 16).unwrap();
    let mut mirror = mirror_from_replay(&mut host);
    assert_eq!(host.plain_text().unwrap(), before, "a replay cleared the host's prompt");
    assert_eq!(mirror.plain_text().unwrap(), before, "the mirror lost the prompt");

    // zsh redraws nothing for its old size; its next byte is an echo.
    host.vt_write(b"l");
    mirror.vt_write(b"l");
    assert_eq!(host.plain_text().unwrap(), format!("{before} l"));
    assert_eq!(mirror.plain_text().unwrap(), host.plain_text().unwrap());
}
