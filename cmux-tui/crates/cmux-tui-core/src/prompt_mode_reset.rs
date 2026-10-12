//! A program that dies without cleanup (SIGKILL, a crash) leaves the modes it
//! set: mouse reporting stays on, so every mouse move types an SGR report
//! (`35;1;13M`) into the shell, an alternate screen stays up and the cursor
//! stays hidden. When the shell starts its next prompt (OSC 133;A) with no
//! command running since its last 133;D, nothing it runs can want them any
//! more: they are reset right before the mark, so the prompt draws on a sane
//! screen. A program that prints a prompt mark itself runs after the shell's
//! 133;C, so its modes stay.
//!
//! Bracketed paste (2004), focus reports (1004) and application cursor keys
//! (1) are the line editor's own prompt modes (zsh, bash and fish turn them
//! on to read a line), so they stay.

use std::borrow::Cow;

use ghostty_vt::{Screen, Terminal};

/// An OSC 133 semantic mark; the byte after it names the mark.
const MARK: &[u8] = b"\x1b]133;";

/// Every mouse reporting mode and encoding, as ghostty-vt knows them.
const MOUSE_RESET: &[u8] =
    b"\x1b[?9l\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1005l\x1b[?1006l\x1b[?1015l\x1b[?1016l";

/// The three ways onto the alternate screen, newest last so 1049 restores
/// the cursor the program saved on entry.
const ALT_SCREEN_RESET: &[u8] = b"\x1b[?47l\x1b[?1047l\x1b[?1049l";

/// Show the cursor (DECTCEM).
const CURSOR_SHOW: &[u8] = b"\x1b[?25h";

/// The cursor-visible mode, a DEC private mode.
const CURSOR_VISIBLE: u16 = 25;

/// What a pane's terminal drops when its child exits: nothing runs there
/// any more to want mouse reports, pasted-text brackets, focus reports,
/// application cursor keys, a hidden cursor or an alternate screen.
pub(crate) const EXIT_RESET: &[u8] = b"\x1b[?9l\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1005l\x1b[?1006l\x1b[?1015l\x1b[?1016l\x1b[?2004l\x1b[?1004l\x1b[?1l\x1b[?25h\x1b[?47l\x1b[?1047l\x1b[?1049l";

/// Where the shell is between its marks, carried across output chunks.
#[derive(Debug, Default)]
pub(crate) struct ShellMarks {
    /// A command started (133;C) and has not finished (133;D).
    running: bool,
}

/// Write `data` to `term`, resetting a dead program's modes right before
/// each prompt mark the shell prints at its prompt. Returns the bytes the
/// terminal parsed, resets included, for mirrors and attach taps.
pub(crate) fn write_output<'a>(
    term: &mut Terminal,
    data: &'a [u8],
    marks: &mut ShellMarks,
) -> Cow<'a, [u8]> {
    let mut parsed: Option<Vec<u8>> = None;
    let mut written = 0;
    let mut from = 0;
    while let Some(offset) = find(&data[from..], MARK) {
        let at = from + offset;
        from = at + MARK.len();
        match data.get(from) {
            Some(b'C') => marks.running = true,
            Some(b'D') => marks.running = false,
            Some(b'A') if !marks.running => {
                // The modes as of the mark: what this chunk set before it counts.
                let parsed = parsed.get_or_insert_with(|| Vec::with_capacity(data.len()));
                parsed.extend_from_slice(&term.vt_write_with_normalized(&data[written..at]));
                written = at;
                let reset = leftover_modes(term);
                if !reset.is_empty() {
                    parsed.extend_from_slice(&term.vt_write_with_normalized(&reset));
                }
            }
            _ => {}
        }
    }
    match parsed {
        None => term.vt_write_with_normalized(data),
        Some(mut parsed) => {
            parsed.extend_from_slice(&term.vt_write_with_normalized(&data[written..]));
            Cow::Owned(parsed)
        }
    }
}

/// The resets the terminal needs now: none on a sane screen, so a prompt
/// redraw costs nothing.
fn leftover_modes(term: &Terminal) -> Vec<u8> {
    let mut reset = Vec::new();
    if term.mouse_tracking() {
        reset.extend_from_slice(MOUSE_RESET);
    }
    if matches!(term.active_screen(), Screen::Alternate) {
        reset.extend_from_slice(ALT_SCREEN_RESET);
    }
    if !term.mode(CURSOR_VISIBLE, false) {
        reset.extend_from_slice(CURSOR_SHOW);
    }
    reset
}

fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|window| window == needle)
}
