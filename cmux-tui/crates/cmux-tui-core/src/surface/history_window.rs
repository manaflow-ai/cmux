//! Which history rows a byte viewer's replay holds.
//!
//! The Mac keeps a terminal's whole scrollback. A viewer that asks for it
//! (`replay_history_rows`, `attach-replay-history-rows-v1`; with
//! `replay_history_start`, `attach-replay-history-window-v1`) holds the
//! screen and a window of history: the newest rows (a tail), or a window
//! anywhere above them for a reader far up. Its memory and every replay it
//! gets stay bounded by the window, however long the Mac's history is, and a
//! reader still reaches the oldest row by moving the window.
//!
//! The window also holds across a resize or resync: those replay each viewer
//! its own window, not the whole history (before, every `resized` sent a
//! windowed phone the whole scrollback, up to `VT_REPLAY_MAX_BYTES`).

/// The most history rows a window away from the screen holds. A tail keeps
/// whatever count it asked for (`replay_history_rows`, as before).
pub(crate) const MAX_WINDOW_ROWS: u64 = 10_000;

/// The history a byte viewer asked for.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct HistoryWindow {
    /// The window's first history row (0: the oldest row kept). `None`: the
    /// newest rows, right above the screen.
    pub(crate) start: Option<u64>,
    pub(crate) rows: u64,
}

/// What a replay of [`HistoryWindow`] holds, given the history now.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum WindowPlan {
    /// The newest `rows` history rows (all of them when fewer), then the screen.
    Tail { rows: u64 },
    /// History rows `[start, start + rows)`, then the screen; the `skipped`
    /// rows between them are left out.
    Gap { start: u64, rows: u64, skipped: u64 },
}

impl HistoryWindow {
    pub(crate) fn tail(rows: u64) -> Self {
        Self { start: None, rows }
    }

    /// The replay of this window over `history_rows` rows of history. A
    /// window is at most [`MAX_WINDOW_ROWS`] and at least one row. A gap
    /// shorter than the window is not worth leaving out: the rows from
    /// `start` down to the screen go as one tail, at most twice the window.
    pub(crate) fn plan(self, history_rows: u64) -> WindowPlan {
        let Some(start) = self.start else {
            return WindowPlan::Tail { rows: self.rows };
        };
        let rows = self.rows.clamp(1, MAX_WINDOW_ROWS);
        let start = start.min(history_rows);
        let skipped = history_rows.saturating_sub(start.saturating_add(rows));
        if skipped < rows {
            WindowPlan::Tail { rows: history_rows - start }
        } else {
            WindowPlan::Gap { start, rows, skipped }
        }
    }

    /// The window a resize or resync replays: rows are numbered again after
    /// a reflow, so a window away from the screen becomes a tail of its size
    /// (the viewer finds its reader again by text, as after any replay).
    pub(crate) fn after_reflow(self) -> Self {
        Self::tail(self.start.map_or(self.rows, |_| self.rows.clamp(1, MAX_WINDOW_ROWS)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plans() {
        let gap = |start, rows, skipped| WindowPlan::Gap { start, rows, skipped };
        let tail = |rows| WindowPlan::Tail { rows };
        let window = |start, rows| HistoryWindow { start: Some(start), rows };
        // (asked, history rows, plan)
        let cases = [
            // A tail is what it was: the newest rows asked for.
            (HistoryWindow::tail(0), 100_000, tail(0)),
            (HistoryWindow::tail(2_000), 100_000, tail(2_000)),
            (HistoryWindow::tail(50_000), 100_000, tail(50_000)),
            // The top of a 100k-row history: line 1 first, then the screen.
            (window(0, 4_000), 100_000, gap(0, 4_000, 96_000)),
            // Anywhere in the middle.
            (window(48_000, 4_000), 100_000, gap(48_000, 4_000, 48_000)),
            // A window is bounded.
            (window(0, 1_000_000), 100_000, gap(0, MAX_WINDOW_ROWS, 90_000)),
            (window(0, 0), 100_000, gap(0, 1, 99_999)),
            // Near the screen: one tail from the window's start, at most twice the window.
            (window(93_000, 4_000), 100_000, tail(7_000)),
            (window(96_000, 4_000), 100_000, tail(4_000)),
            (window(99_000, 4_000), 100_000, tail(1_000)),
            // Past the end (the history shrank): the screen alone.
            (window(120_000, 4_000), 100_000, tail(0)),
            // A short history.
            (window(0, 4_000), 3_000, tail(3_000)),
            (window(0, 4_000), 0, tail(0)),
        ];
        for (asked, history, plan) in cases {
            assert_eq!(asked.plan(history), plan, "{asked:?} over {history} rows");
        }
    }

    #[test]
    fn a_reflow_keeps_the_window_size_as_a_tail() {
        assert_eq!(HistoryWindow::tail(2_000).after_reflow(), HistoryWindow::tail(2_000));
        assert_eq!(
            HistoryWindow { start: Some(40_000), rows: 4_000 }.after_reflow(),
            HistoryWindow::tail(4_000)
        );
        assert_eq!(
            HistoryWindow { start: Some(0), rows: 1_000_000 }.after_reflow(),
            HistoryWindow::tail(MAX_WINDOW_ROWS)
        );
    }
}
