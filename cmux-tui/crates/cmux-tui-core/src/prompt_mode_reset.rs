//! A program that dies without cleanup (SIGKILL, a crash) leaves the modes it
//! set: mouse reporting stays on, so every mouse move types an SGR report
//! (`35;1;13M`) into the shell, an alternate screen stays up and the cursor
//! stays hidden. When the
//! shell starts its next prompt (OSC 133;A) while it is the terminal's
//! foreground job, nothing it runs can want them any more: they are reset
//! right before the mark, so the prompt draws on a sane screen.
//!
//! Bracketed paste (2004), focus reports (1004) and application cursor keys
//! (1) are the line editor's own prompt modes (zsh, bash and fish turn them
//! on to read a line), so they stay.

use std::borrow::Cow;

use ghostty_vt::{Screen, Terminal};

/// The OSC 133 prompt-start mark, any terminator or options after it.
const PROMPT_START: &[u8] = b"\x1b]133;A";

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

/// Write `data` to `term`, resetting a dead program's modes right before
/// each prompt mark when `shell_foreground` says the terminal's own child
/// is the foreground job. Returns the bytes the terminal parsed, resets
/// included, for mirrors and attach taps.
pub(crate) fn write_output<'a>(
    term: &mut Terminal,
    data: &'a [u8],
    shell_foreground: impl Fn() -> bool,
) -> Cow<'a, [u8]> {
    let Some(first) = find(data, PROMPT_START) else {
        return term.vt_write_with_normalized(data);
    };
    let mut parsed = Vec::with_capacity(data.len());
    let mut rest = data;
    let mut at = first;
    loop {
        parsed.extend_from_slice(&term.vt_write_with_normalized(&rest[..at]));
        let reset = leftover_modes(term);
        if !reset.is_empty() && shell_foreground() {
            parsed.extend_from_slice(&term.vt_write_with_normalized(&reset));
        }
        let mark = &rest[at..];
        let next = find(&mark[PROMPT_START.len()..], PROMPT_START);
        match next {
            Some(offset) => {
                rest = mark;
                at = PROMPT_START.len() + offset;
            }
            None => {
                parsed.extend_from_slice(&term.vt_write_with_normalized(mark));
                return Cow::Owned(parsed);
            }
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
