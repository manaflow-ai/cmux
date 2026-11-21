//! A replay of one window of the history and the screen, without the rows
//! between them.
//!
//! The Mac keeps the scrollback; a phone mirror holds the screen and the
//! rows around what its reader looks at. A reader far up in a long history
//! gets the rows `[start, start + rows)`, then the screen, from one replay:
//! the mirror's history is that window, and its memory stays bounded however
//! long the Mac's history is (`replay_history_start`,
//! `attach-replay-history-window-v1` in cmux-tui-core).

use super::*;

/// A replay of a window of the history above the screen
/// ([`Terminal::vt_replay_window_theme_portable_with_aliases`]).
#[derive(Debug, Clone)]
pub struct VtReplayWindow {
    pub replay: VtReplay,
    /// History rows older than the window's first row, left out.
    pub history_rows_omitted: u64,
    /// History rows between the window's last row and the screen, left out.
    pub history_rows_skipped: u64,
}

impl Terminal {
    /// The history rows `[start, start + rows)` (0: the oldest row kept),
    /// then the screen, in at most `max_bytes`. `None` when such a replay
    /// is not this terminal's whole state or a tail serves as well: the
    /// window reaches the screen, a program holds the alternate screen,
    /// Kitty images are kept or one is being sent, or a prompt clear waits
    /// for the shell. The caller then sends a tail replay.
    pub fn vt_replay_window_theme_portable_with_aliases(
        &mut self,
        max_bytes: usize,
        start: u64,
        rows: u64,
    ) -> Result<Option<VtReplayWindow>> {
        if rows == 0 || self.active_screen() != Screen::Primary {
            return Ok(None);
        }
        let Some(scrollbar) = self.scrollbar() else {
            return Ok(None);
        };
        let screen_rows = scrollbar.len.min(scrollbar.total).max(1);
        let screen_start = scrollbar.total.saturating_sub(screen_rows);
        let Some(window_end) = start.checked_add(rows) else {
            return Ok(None);
        };
        if window_end >= screen_start {
            return Ok(None);
        }
        let (inflight, pending) = self.replay_inflight_and_pending(max_bytes)?;
        if !inflight.is_empty() || self.settled_prompt_copy().is_some() {
            return Ok(None);
        }
        let mut pixel_cache = std::mem::take(&mut self.kitty_replay_pixel_cache.0);
        let snapshot = kitty::snapshot_for_replay(self, &mut pixel_cache, true);
        self.kitty_replay_pixel_cache.0 = pixel_cache;
        let snapshot = snapshot?;
        if !snapshot.graphics.images.is_empty() || !snapshot.graphics.placements.is_empty() {
            return Ok(None);
        }
        let state_suffix = self.replay_state_suffix();
        let Some(remaining) = max_bytes
            .checked_sub(state_suffix.len())
            .and_then(|remaining| remaining.checked_sub(pending.len()))
        else {
            return Ok(None);
        };
        let range = ReplayRowRange { start, end: scrollbar.total - 1 };
        let skip = ReplayRowRange { start: window_end, end: screen_start - 1 };
        let Some(text) = self.vt_replay_text_range_skipping(
            range,
            Some(skip),
            &KittyReplayRowIndex::default(),
            remaining,
            false,
        )?
        else {
            return Ok(None);
        };
        let mut bytes = text.bytes;
        bytes.extend_from_slice(&state_suffix);
        let replay_cursor_offset = u32::try_from(bytes.len()).map_err(|_| Error::OutOfSpace)?;
        let replay = VtReplay {
            bytes,
            kitty_image_aliases: Vec::new(),
            kitty_state: self.kitty_replay_state(replay_cursor_offset)?,
            pending_sequence: pending,
        };
        Ok(Some(VtReplayWindow {
            replay,
            history_rows_omitted: start,
            history_rows_skipped: skip.end - skip.start + 1,
        }))
    }
}
