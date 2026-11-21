//! The primary screen under an alternate screen, in a replay.
//!
//! The VT formatter writes the active screen only. While a program holds
//! the alternate screen (an editor, a pager, a full-screen agent), a replay
//! therefore carried no primary screen and no history: a mirror rebuilt
//! from it (a daemon adopting a terminal host after an update, a renderer
//! attach, a journal checkpoint) showed an empty screen with no scrollback
//! when the program left. So the replay of an alternate screen starts with
//! the primary screen's text: it comes from a copy of this terminal that has
//! left the alternate screen (a GHOSTSNP round trip, then the same mode
//! reset the program will send), laid out like any replay, with what the
//! budget leaves after the alternate screen's own replay. The alternate
//! replay that follows starts with its modes, so its `?1049h` (or `?1047h`,
//! `?47h`) saves the primary cursor and switches screens on the mirror the
//! way the program did on this terminal.

use super::*;
use crate::snapshot::{DecodedTerminal, SnapshotPhase};

impl Terminal {
    /// Bounded text used when a daemon must replace a reader's held output
    /// after a reconnect. While the alternate screen is active, plain_text
    /// intentionally exposes only that screen; recoveries also retain the
    /// primary screen and its scrollback so replacing the held text does not
    /// erase the shell history underneath a full-screen program.
    pub fn recovery_text_bounded(&mut self, max_bytes: usize) -> Result<Option<String>> {
        if self.active_screen() != Screen::Alternate {
            let Some(mut text) = self.plain_text_bounded(max_bytes)? else {
                return Ok(None);
            };
            if !append_omitted_line_feeds(&mut text, self, max_bytes) {
                return Ok(None);
            }
            if text.len() > max_bytes {
                return Ok(None);
            }
            return Ok(Some(text));
        }
        if !self.vt_stream_is_ground() {
            return Err(Error::InvalidValue);
        }
        let mut active = self.plain_text_bounded(max_bytes)?.ok_or(Error::OutOfSpace)?;
        if !append_omitted_line_feeds(&mut active, self, max_bytes) {
            return Ok(None);
        }
        let leave: &[u8] = if self.mode(1049, false) {
            b"\x1b[?1049l"
        } else if self.mode(1047, false) {
            b"\x1b[?1047l"
        } else if self.mode(47, false) {
            b"\x1b[?47l"
        } else {
            return Err(Error::InvalidValue);
        };
        let complete = self.encode_snapshot(SnapshotPhase::Complete)?;
        let copy = DecodedTerminal::decode(&complete)?;
        unsafe { sys::ghostty_terminal_vt_write(copy.raw(), leave.as_ptr(), leave.len()) };
        let primary = self.with_replay_grid(Some(&copy), |term| {
            let mut primary = term.plain_text_bounded(max_bytes)?.ok_or(Error::OutOfSpace)?;
            if !append_omitted_line_feeds(&mut primary, term, max_bytes) {
                return Err(Error::OutOfSpace);
            }
            Ok::<_, Error>(primary)
        })?;
        let separator =
            usize::from(!primary.is_empty() && !active.is_empty() && !primary.ends_with('\n'));
        if primary.len().saturating_add(separator).saturating_add(active.len()) > max_bytes {
            return Ok(None);
        }
        let mut text = String::with_capacity(primary.len() + separator + active.len());
        text.push_str(&primary);
        if separator != 0 {
            text.push('\n');
        }
        text.push_str(&active);
        Ok(Some(text))
    }

    /// Replay text of the primary screen under the active alternate
    /// screen, at most `max_bytes`, or `None` when the primary screen is
    /// active, it does not fit, or no copy can be made (an unfinished
    /// escape sequence, say): the replay then holds the alternate screen
    /// alone, as before. Kitty images of the primary screen are not
    /// included (their placements come back when the program redraws).
    pub(super) fn primary_under_alternate_replay(
        &mut self,
        max_bytes: usize,
        include_palette: bool,
        max_history_rows: Option<u64>,
    ) -> Option<Vec<u8>> {
        if self.active_screen() != Screen::Alternate || !self.vt_stream_is_ground() {
            return None;
        }
        // Leave the way the program entered: 1049 restores the cursor it
        // saved, which is the primary cursor the program will come back to.
        let leave: &[u8] = if self.mode(1049, false) {
            b"\x1b[?1049l"
        } else if self.mode(1047, false) {
            b"\x1b[?1047l"
        } else if self.mode(47, false) {
            b"\x1b[?47l"
        } else {
            return None;
        };
        let complete = self.encode_snapshot(SnapshotPhase::Complete).ok()?;
        let copy = DecodedTerminal::decode(&complete).ok()?;
        // The copy is private to this call, has no callbacks and is in the
        // ground state (checked above), so this write only switches screens.
        unsafe { sys::ghostty_terminal_vt_write(copy.raw(), leave.as_ptr(), leave.len()) };
        if self.prompt_clear_may_wait {
            // As `settled_prompt_copy`: run the prompt clear a resize put
            // off, so the mirror matches this terminal after the shell's redraw.
            let waits = false;
            check(unsafe {
                sys::ghostty_terminal_set(
                    copy.raw(),
                    sys::GHOSTTY_TERMINAL_OPT_PROMPT_REDRAW_WAITS_FOR_SHELL,
                    (&waits as *const bool).cast(),
                )
            })
            .ok()?;
        }
        let text = self.with_replay_grid(Some(&copy), |term| {
            if term.active_screen() != Screen::Primary {
                return None;
            }
            term.vt_replay_text_layout_bounded(
                max_bytes,
                &KittyReplayRowIndex::default(),
                None,
                include_palette,
                max_history_rows,
            )
            .ok()
        })?;
        // No range: the layout fell back to a terminal reset, which would
        // only clear what the alternate replay sets up.
        text.range?;
        (text.bytes.len() <= max_bytes).then_some(text.bytes)
    }
}

fn append_omitted_line_feeds(text: &mut String, terminal: &Terminal, max_bytes: usize) -> bool {
    let Some((_, cursor_row)) = terminal.cursor_position() else {
        return true;
    };
    let cursor_row = terminal.scrollback_rows().saturating_add(usize::from(cursor_row));
    let lines = text.split('\n').count();
    let missing = cursor_row.saturating_add(1).saturating_sub(lines);
    if missing > max_bytes.saturating_sub(text.len()) {
        return false;
    }
    text.extend(std::iter::repeat_n('\n', missing));
    true
}
