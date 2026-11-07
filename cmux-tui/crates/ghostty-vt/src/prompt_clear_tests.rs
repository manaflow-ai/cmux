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
