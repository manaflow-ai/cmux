//! A program that dies without cleanup (SIGKILL, a crash) leaves the modes it
//! set: mouse reporting stays on, so every mouse move types an SGR report
//! (`35;1;13M`) into the shell, an alternate screen stays up and the cursor
//! stays hidden. When the shell starts its next prompt (OSC 133;A) with no
//! command running since its last 133;D, nothing it runs can want them any
//! more: they are reset right before the mark, so the prompt draws on a sane
//! screen. A program that prints a prompt mark itself runs after the shell's
//! 133;C, so its modes stay.
//!
//! The keyboard modes are the line editor's own at the prompt: zsh, bash and
//! fish turn on bracketed paste (2004), focus reports (1004), application
//! cursor keys (1) or the kitty keyboard protocol to read a line, and bash's
//! readline does it before printing the prompt that holds 133;A. So they are
//! reset at the shell's command end (133;D) instead, which Ghostty's bash,
//! zsh and fish integrations print from their post-command hook, before the
//! line editor starts: a killed Codex or Claude Code would otherwise leave
//! keys typing kitty sequences (`[97;5u`) and pastes losing their brackets.

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

/// The keyboard modes a finished command leaves: pasted-text brackets, focus
/// reports, application cursor and keypad keys, the whole kitty keyboard
/// flag stack (a pop past its bottom resets the flags) and xterm's
/// modifyOtherKeys.
const KEYBOARD_RESET: &[u8] = b"\x1b[?2004l\x1b[?1004l\x1b[?1l\x1b>\x1b[<99u\x1b[>4;0m";

/// The cursor-visible mode, a DEC private mode.
const CURSOR_VISIBLE: u16 = 25;

/// What a pane's terminal drops when its child exits: nothing runs there
/// any more to want mouse reports, keyboard modes or a hidden cursor.
const EXIT_RESET: &[u8] = b"\x1b[?9l\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1005l\x1b[?1006l\x1b[?1015l\x1b[?1016l\x1b[?2004l\x1b[?1004l\x1b[?1l\x1b>\x1b[<99u\x1b[>4;0m\x1b[?25h";

/// The reset for a pane whose child exited: [`EXIT_RESET`], and the way off
/// an alternate screen only when the child left one up. `?1049l` restores
/// the saved cursor even on the main screen, so sent there it moved the
/// cursor back over the dead child's last lines, and the restore banner and
/// the respawned shell's prompt overwrote them.
pub fn exit_reset(term: &Terminal) -> Vec<u8> {
    let mut reset = EXIT_RESET.to_vec();
    if matches!(term.active_screen(), Screen::Alternate) {
        reset.extend_from_slice(ALT_SCREEN_RESET);
    }
    reset
}

/// Where the shell is between its marks, carried across output chunks.
#[derive(Debug, Default)]
pub struct ShellMarks {
    /// A command started (133;C) and has not finished (133;D).
    running: bool,
    /// The title the stream set, for the title ops libghostty-vt skips
    /// (`CSI 22/23 t`, OSC 1; [`crate::titles`]).
    titles: crate::titles::TitleTracker,
}

impl ShellMarks {
    /// For a parser that joins a stream midway (a hosted mirror after a
    /// daemon restart or a resync): a command may be running, so nothing is
    /// reset until the shell says one finished (133;D).
    pub fn joined_midway() -> Self {
        Self { running: true, ..Self::default() }
    }
}

/// Write `data` to `term`, resetting a dead program's modes right before
/// each prompt mark the shell prints at its prompt. Returns the bytes the
/// terminal parsed, resets included, for mirrors and attach taps.
pub fn write_output<'a>(
    term: &mut Terminal,
    data: &'a [u8],
    marks: &mut ShellMarks,
) -> Cow<'a, [u8]> {
    // A title pop or an OSC 1 icon name becomes the OSC 2 that applies it,
    // here, so this terminal and every mirror fed the parsed bytes agree.
    match marks.titles.rewrite(data) {
        Cow::Borrowed(data) => write_marked(term, data, &mut marks.running),
        Cow::Owned(data) => Cow::Owned(write_marked(term, &data, &mut marks.running).into_owned()),
    }
}

#[allow(
    clippy::indexing_slicing,
    reason = "INVARIANT: written <= at < from <= data.len(); at and from bound a MARK found in data"
)]
fn write_marked<'a>(term: &mut Terminal, data: &'a [u8], running: &mut bool) -> Cow<'a, [u8]> {
    let mut parsed: Option<Vec<u8>> = None;
    let mut written = 0;
    let mut from = 0;
    while let Some(offset) = find(&data[from..], MARK) {
        let at = from + offset;
        from = at + MARK.len();
        match data.get(from) {
            Some(b'C') => *running = true,
            Some(b'D') if *running => {
                *running = false;
                let parsed = parsed.get_or_insert_with(|| Vec::with_capacity(data.len()));
                parsed.extend_from_slice(&term.vt_write_with_normalized(&data[written..at]));
                written = at;
                parsed.extend_from_slice(&term.vt_write_with_normalized(KEYBOARD_RESET));
            }
            Some(b'D') => {}
            Some(b'A') if !*running => {
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

#[cfg(test)]
mod tests {
    use ghostty_vt::{Callbacks, Terminal};

    use super::*;

    fn terminal() -> Terminal {
        Terminal::new(40, 4, 100, Callbacks::default()).unwrap()
    }

    /// A killed program's mouse mode and alt screen end at the shell's next
    /// prompt; its keyboard modes end at the command's 133;D.
    #[test]
    fn a_dead_programs_modes_reset_at_the_shells_marks() {
        let mut term = terminal();
        let mut marks = ShellMarks::default();
        let _ =
            write_output(&mut term, b"\x1b]133;C\x07\x1b[?1000h\x1b[?2004h\x1b[?1049h", &mut marks);
        assert!(term.mouse_tracking());
        let _ = write_output(&mut term, b"\x1b]133;D;137\x07", &mut marks);
        assert!(!term.mode(2004, false), "bracketed paste ends with the command");
        let _ = write_output(&mut term, b"\x1b]133;A\x07$ ", &mut marks);
        assert!(!term.mouse_tracking());
        assert!(matches!(term.active_screen(), Screen::Primary));
    }

    /// A parser that joins midway resets nothing until a command ends.
    #[test]
    fn a_parser_joined_midway_keeps_the_modes_until_a_command_ends() {
        let mut term = terminal();
        let mut marks = ShellMarks::joined_midway();
        let _ = write_output(&mut term, b"\x1b[?1000h\x1b]133;A\x07", &mut marks);
        assert!(term.mouse_tracking());
    }
}
