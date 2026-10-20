//! What the search-everything worker (crate::search_everything) reads from a
//! terminal: the scrollback rows that left the screen since its last read,
//! or the full-screen (alternate screen) frame. One short lock of the
//! terminal per call.

use super::*;

/// Rows read per call, so one lock stays short.
const MAX_ROWS_PER_READ: u64 = 2000;

/// Where the worker stopped reading one terminal's scrollback.
#[derive(Debug, Clone, Copy, Default)]
pub(crate) struct ScrollbackCursor {
    epoch: u64,
    /// The next primary screen row marker to read; `None` before the first read.
    next: Option<u64>,
}

/// One read of a terminal.
pub(crate) enum TerminalCapture {
    /// Scrollback rows from `first_marker` (lines joined with `\n`); `more`
    /// when rows are left to read.
    Scrollback {
        first_marker: u64,
        text: String,
        more: bool,
    },
    /// The text of the alternate screen.
    Screen(String),
    Nothing,
}

impl Surface {
    /// Reads what is new since `cursor` and moves it.
    pub(crate) fn search_capture(&self, cursor: &mut ScrollbackCursor) -> TerminalCapture {
        let Some(pty) = self.as_pty() else { return TerminalCapture::Nothing };
        let Ok(mut term) = pty.term.lock() else { return TerminalCapture::Nothing };
        if term.active_screen() == Screen::Alternate {
            return term.viewport_text().map_or(TerminalCapture::Nothing, TerminalCapture::Screen);
        }
        let epoch = term.history_marker_epoch();
        let top = term.active_top_marker();
        let oldest = term.history_marker(0);
        let from = match cursor.next {
            Some(next) if cursor.epoch == epoch => next.max(oldest),
            // A reflow renumbered every row: what was read stays indexed.
            Some(_) => top,
            None => oldest,
        };
        cursor.epoch = epoch;
        if from >= top {
            cursor.next = Some(from.max(top));
            return TerminalCapture::Nothing;
        }
        let end = top.min(from.saturating_add(MAX_ROWS_PER_READ));
        let last_col = term.cols().saturating_sub(1);
        cursor.next = Some(end);
        match term.read_marker_range(Some(epoch), (from, 0), (end - 1, last_col), false) {
            Ok(text) => TerminalCapture::Scrollback { first_marker: from, text, more: end < top },
            Err(_) => TerminalCapture::Nothing,
        }
    }
}
