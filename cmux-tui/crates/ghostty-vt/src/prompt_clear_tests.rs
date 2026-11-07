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
