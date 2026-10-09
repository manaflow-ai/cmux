//! Cmd-K: clear retained history while the active prompt stays usable.

use super::*;

impl Terminal {
    /// Clear retained history and complete rows before the active prompt
    /// without writing bytes to the child process. The prompt then starts on
    /// the top row, as after Ghostty's clear_screen.
    ///
    /// OSC 133 identifies the full prompt when available. Without shell
    /// metadata, only scrollback is cleared because visible rows may contain
    /// hard-newline input whose boundary cannot be inferred. Cursor movement
    /// is skipped when pending-wrap or origin-mode state cannot be restored
    /// exactly. If preserved content begins in scrollback, or the persistent
    /// VT parser is inside a partial sequence or UTF-8 code point, no mutation
    /// is applied.
    pub fn clear_history_preserving_prompt(&mut self) -> ClearHistoryOutcome {
        const CLEAR_SCROLLBACK: &[u8] = b"\x1b[3J";

        if self.active_screen() == Screen::Alternate {
            return ClearHistoryOutcome::Unchanged;
        }
        if !self.vt_boundary.is_safe() {
            return ClearHistoryOutcome::Blocked;
        }

        let mut clear = CLEAR_SCROLLBACK.to_vec();
        let Some((cursor_x, cursor_y)) = self.cursor_position() else {
            return ClearHistoryOutcome::Unchanged;
        };
        let prompt_semantic = self.prompt_semantic.semantic(Screen::Primary);
        let cursor_is_at_prompt = self.cursor_is_at_prompt();
        let prompt_start_y =
            cursor_is_at_prompt.then(|| self.active_prompt_start_row(cursor_y)).flatten();
        let preserve_from_y = if cursor_is_at_prompt {
            prompt_start_y.or_else(|| self.active_logical_line_start_row(cursor_y))
        } else if prompt_semantic == PromptSemantic::Unknown {
            Some(0)
        } else {
            self.active_logical_line_start_row(cursor_y)
        };
        let Some(preserve_from_y) = preserve_from_y else {
            return ClearHistoryOutcome::Unchanged;
        };
        let history_rows = self.history_rows();
        let prompt_may_begin_in_history = cursor_is_at_prompt
            && match prompt_start_y {
                None => true,
                // Some shells mark every hard-newline prompt row. Row zero is
                // only a true boundary when the adjacent history row is not
                // another prompt row.
                Some(0) if history_rows > 0 => self
                    .history_row_prompt_semantic(history_rows - 1)
                    .map(|semantic| semantic != sys::GHOSTTY_ROW_SEMANTIC_NONE)
                    .unwrap_or(true),
                Some(0) => false,
                Some(_) => false,
            };
        if history_rows > 0
            && (prompt_may_begin_in_history
                || (preserve_from_y == 0
                    && !cursor_is_at_prompt
                    && self.active_row_wrap_continuation(0).unwrap_or(true)))
        {
            return ClearHistoryOutcome::Unchanged;
        }
        if self.cursor_pending_wrap() || self.mode(6, false) {
            self.vt_write(&clear);
            return ClearHistoryOutcome::Cleared(clear);
        }
        if preserve_from_y == 0 {
            self.vt_write(&clear);
            return ClearHistoryOutcome::Cleared(clear);
        }

        // Like Ghostty's clear_screen, the preserved content moves to the
        // top row. IND on the bottom row scrolls the whole screen up into
        // history, which keeps soft wraps, prompt marks and image pins (DL
        // would clear the wrap flags); the history then goes. Scrolling acts
        // only inside the scrolling region, so a non-default region blanks
        // the rows in place.
        let target_y = if self.scrolling_region_is_default() {
            clear = format!("\x1b[{};1H", self.rows()).into_bytes();
            clear.extend(std::iter::repeat_n(*b"\x1bD", usize::from(preserve_from_y)).flatten());
            clear.extend_from_slice(CLEAR_SCROLLBACK);
            cursor_y.saturating_sub(preserve_from_y)
        } else {
            for row in 0..preserve_from_y {
                clear
                    .extend_from_slice(format!("\x1b[{};1H\x1b[2K", u32::from(row) + 1).as_bytes());
            }
            cursor_y
        };
        clear.extend_from_slice(
            format!("\x1b[{};{}H", u32::from(target_y) + 1, u32::from(cursor_x) + 1).as_bytes(),
        );
        self.vt_write(&clear);
        ClearHistoryOutcome::Cleared(clear)
    }

    /// True when DECSTBM and DECSLRM cover the whole screen. The terminal
    /// formatter emits those sequences only for a non-default region.
    fn scrolling_region_is_default(&mut self) -> bool {
        let Some(origin) = self.grid_ref(sys::GHOSTTY_POINT_TAG_ACTIVE, 0, 0) else {
            return false;
        };
        let selection = sys::GhosttySelection {
            size: size_of::<sys::GhosttySelection>(),
            start: origin,
            end: origin,
            rectangle: false,
        };
        let mut opts = Self::vt_replay_options(Some(&selection), false, false);
        opts.extra = sys::GhosttyFormatterTerminalExtra {
            size: size_of::<sys::GhosttyFormatterTerminalExtra>(),
            palette: false,
            modes: false,
            scrolling_region: true,
            tabstops: false,
            pwd: false,
            keyboard: false,
            screen: sys::GhosttyFormatterScreenExtra {
                size: size_of::<sys::GhosttyFormatterScreenExtra>(),
                cursor: false,
                style: false,
                hyperlink: false,
                protection: false,
                kitty_keyboard: false,
                charsets: false,
            },
        };
        let Ok(bytes) = self.format(opts) else { return false };
        !contains_margin_sequence(&bytes)
    }
}

/// Finds a `CSI <n>;<n> r` (DECSTBM) or `CSI <n>;<n> s` (DECSLRM) sequence.
fn contains_margin_sequence(bytes: &[u8]) -> bool {
    bytes.windows(2).enumerate().any(|(at, pair)| {
        pair == b"\x1b["
            && bytes[at + 2..]
                .iter()
                .find(|byte| !(byte.is_ascii_digit() || **byte == b';'))
                .is_some_and(|end| *end == b'r' || *end == b's')
    })
}
