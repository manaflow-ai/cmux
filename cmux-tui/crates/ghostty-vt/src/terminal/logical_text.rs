//! Text reads for agents: soft-wrapped rows joined into the logical lines
//! the program printed, the last N lines across scrollback and screen, and
//! the text printed after a remembered line.
//!
//! A row the terminal soft-wrapped (the program printed past the right edge)
//! carries Ghostty's wrap flag; the formatter's `unwrap` option joins it with
//! its continuation, so a 300-column line in an 80-column pane reads back as
//! one line. Rows the program ended with a newline stay separate lines.

use super::*;

impl Terminal {
    /// Plain text of the rendered viewport (as [`Self::viewport_text`]) with
    /// soft wraps joined. A line that started above the viewport reads from
    /// its first row in the viewport.
    pub fn viewport_text_unwrapped(&mut self) -> Result<String> {
        self.whole_rows_text(sys::GHOSTTY_POINT_TAG_VIEWPORT)
    }

    /// Plain text of the live screen below scrollback with soft wraps
    /// joined.
    pub fn active_text_unwrapped(&mut self) -> Result<String> {
        self.whole_rows_text(sys::GHOSTTY_POINT_TAG_ACTIVE)
    }

    fn whole_rows_text(&mut self, tag: sys::GhosttyPointTag) -> Result<String> {
        let cols = self.cols();
        let rows = self.rows();
        if cols == 0 || rows == 0 {
            return Ok(String::new());
        }
        self.selection_text_with_tag_options(
            tag,
            (0, 0),
            (cols.saturating_sub(1), u64::from(rows.saturating_sub(1))),
            true,
            true,
        )
        .ok_or(Error::InvalidValue)
    }

    /// Plain text of scrollback and screen (as [`Self::plain_text`]) with
    /// soft wraps joined.
    pub fn plain_text_unwrapped(&mut self) -> Result<String> {
        let opts = sys::GhosttyFormatterTerminalOptions {
            size: size_of::<sys::GhosttyFormatterTerminalOptions>(),
            emit: sys::GHOSTTY_FORMATTER_FORMAT_PLAIN,
            unwrap: true,
            trim: true,
            extra: sys::GhosttyFormatterTerminalExtra {
                size: size_of::<sys::GhosttyFormatterTerminalExtra>(),
                ..Default::default()
            },
            selection: ptr::null(),
        };
        Ok(String::from_utf8_lossy(&self.format(opts)?).into_owned())
    }

    /// The last `count` lines of scrollback and screen together, oldest
    /// first, without the blank rows below the last printed line. With
    /// `unwrap` a line is a logical line (soft wraps joined), else one row.
    ///
    /// Reads grow from the bottom: first `count` plus one screen of rows,
    /// doubling until the window holds more than `count` lines (so its
    /// first, possibly partial, line is dropped) or reaches the oldest row.
    pub fn last_lines_text(&mut self, count: usize, unwrap: bool) -> Result<String> {
        let cols = self.cols();
        let rows = self.rows();
        if cols == 0 || rows == 0 || count == 0 {
            return Ok(String::new());
        }
        let total = self.scrollbar().map_or(u64::from(rows), |bar| bar.total).max(1);
        let wanted = u64::try_from(count).unwrap_or(u64::MAX);
        let mut span = wanted.saturating_add(u64::from(rows)).min(total);
        loop {
            let start = total.saturating_sub(span);
            let text = self
                .selection_text_with_tag_options(
                    sys::GHOSTTY_POINT_TAG_SCREEN,
                    (0, start),
                    (cols.saturating_sub(1), total.saturating_sub(1)),
                    unwrap,
                    true,
                )
                .ok_or(Error::InvalidValue)?;
            let lines = printed_lines(&text);
            if lines.len() > count || start == 0 {
                let skip = lines.len().saturating_sub(count);
                return Ok(lines.get(skip..).unwrap_or_default().join("\n"));
            }
            span = span.saturating_mul(2).min(total);
        }
    }

    /// An anchor on the logical line the cursor is on now, for
    /// [`Self::text_after_anchor`].
    pub fn anchor_cursor_line(&mut self) -> Result<TrackedScreenPoint> {
        let rows = self.rows();
        let (_, cursor_y) = self.cursor_position().ok_or(Error::NoValue)?;
        let total = self.scrollbar().map_or(u64::from(rows), |bar| bar.total);
        let active_top = total.saturating_sub(u64::from(rows));
        let y = u32::try_from(active_top.saturating_add(u64::from(cursor_y)))
            .map_err(|_| Error::InvalidValue)?;
        self.track_screen_point(0, y)
    }

    /// Text printed below the anchored line (and below the rows its soft
    /// wraps continue on), soft wraps joined: what appeared after the
    /// anchor was taken. A typed command echoes on the anchored line, so it
    /// is not part of this text. When the anchored row is gone (pruned, or a
    /// replaced terminal) every row on the live screen is newer than it, so
    /// the whole live screen is the answer.
    pub fn text_after_anchor(&mut self, anchor: &TrackedScreenPoint) -> Result<String> {
        let Some((_, anchored)) = self.tracked_screen_point(anchor) else {
            return self.active_text_unwrapped();
        };
        let cols = self.cols();
        let rows = self.rows();
        if cols == 0 || rows == 0 {
            return Ok(String::new());
        }
        let total = self.scrollbar().map_or(u64::from(rows), |bar| bar.total);
        let mut start = u64::from(anchored).saturating_add(1);
        while start < total
            && self.row_flag(
                sys::GHOSTTY_POINT_TAG_SCREEN,
                start,
                sys::GHOSTTY_ROW_DATA_WRAP_CONTINUATION,
            ) == Some(true)
        {
            start = start.saturating_add(1);
        }
        if start >= total {
            return Ok(String::new());
        }
        self.selection_text_with_tag_options(
            sys::GHOSTTY_POINT_TAG_SCREEN,
            (0, start),
            (cols.saturating_sub(1), total.saturating_sub(1)),
            true,
            true,
        )
        .ok_or(Error::InvalidValue)
    }

    fn row_flag(
        &self,
        tag: sys::GhosttyPointTag,
        y: u64,
        data: sys::GhosttyRowData,
    ) -> Option<bool> {
        let grid_ref = self.grid_ref(tag, 0, y)?;
        let mut row = sys::GhosttyRow::default();
        check(unsafe { sys::ghostty_grid_ref_row(&grid_ref, &mut row) }).ok()?;
        let mut value = false;
        check(unsafe { sys::ghostty_row_get(row, data, (&mut value as *mut bool).cast()) }).ok()?;
        Some(value)
    }
}

/// The lines of formatter text without the blank lines after the last
/// printed one.
fn printed_lines(text: &str) -> Vec<&str> {
    let mut lines: Vec<&str> = text.split('\n').map(|line| line.trim_end_matches('\r')).collect();
    while lines.last().is_some_and(|line| line.trim().is_empty()) {
        lines.pop();
    }
    lines
}

#[cfg(test)]
mod tests {
    use super::*;

    fn terminal(cols: u16, rows: u16) -> Terminal {
        Terminal::new(cols, rows, 10_000_000, Callbacks::default()).unwrap()
    }

    #[test]
    fn read_run_logical_text_joins_a_soft_wrapped_line_and_keeps_hard_breaks() {
        let mut term = terminal(20, 10);
        let long = "x".repeat(70);
        term.vt_write(format!("first\r\n{long}\r\nlast\r\n").as_bytes());
        let wrapped = term.viewport_text().unwrap();
        assert!(wrapped.lines().filter(|line| line.starts_with('x')).count() > 1);
        for unwrapped in
            [term.viewport_text_unwrapped().unwrap(), term.active_text_unwrapped().unwrap()]
        {
            let lines: Vec<&str> = unwrapped.lines().filter(|line| !line.is_empty()).collect();
            assert_eq!(lines, ["first", long.as_str(), "last"]);
        }
        let all = term.plain_text_unwrapped().unwrap();
        assert!(all.lines().any(|line| line == long), "{all:?}");
    }

    #[test]
    fn read_run_logical_text_last_lines_reads_across_scrollback_and_drops_trailing_blank_rows() {
        let mut term = terminal(20, 5);
        let output: String = (1..=40).map(|line| format!("line {line}\r\n")).collect();
        term.vt_write(output.as_bytes());
        let long = "y".repeat(300);
        term.vt_write(format!("{long}\r\ndone\r\n").as_bytes());
        assert_eq!(term.last_lines_text(3, true).unwrap(), format!("line 40\n{long}\ndone"));
        assert_eq!(term.last_lines_text(1, true).unwrap(), "done");
        // Rows, not logical lines, without unwrap: the long line's last row.
        let rows = term.last_lines_text(2, false).unwrap();
        assert_eq!(rows, format!("{}\ndone", "y".repeat(20)));
        // More lines than exist: everything, oldest first.
        let all = term.last_lines_text(10_000, true).unwrap();
        assert!(all.starts_with("line 1\n"));
        assert!(all.ends_with("done"));
    }

    #[test]
    fn read_run_logical_text_after_anchor_skips_the_anchored_line_and_its_wrapped_echo() {
        let mut term = terminal(20, 6);
        term.vt_write(b"old BENCH_OK\r\n$ ");
        let anchor = term.anchor_cursor_line().unwrap();
        // The typed command echoes on the anchored line and wraps past it.
        let typed = format!("echo {} BENCH_OK", "z".repeat(30));
        term.vt_write(typed.as_bytes());
        term.vt_write(b"\r\n");
        assert_eq!(term.text_after_anchor(&anchor).unwrap().trim(), "");
        term.vt_write(b"step 1\r\nBENCH_OK\r\n$ ");
        let after = term.text_after_anchor(&anchor).unwrap();
        let lines: Vec<&str> = after.lines().collect();
        assert_eq!(lines.first().copied(), Some("step 1"));
        assert!(lines.contains(&"BENCH_OK"));
        assert!(!after.contains("echo"), "the typed command is not new output: {after:?}");
        assert!(!after.contains("old"), "older output is not new output: {after:?}");
    }

    #[test]
    fn read_run_logical_text_after_anchor_follows_the_line_into_scrollback() {
        let mut term = terminal(20, 4);
        term.vt_write(b"$ cmd");
        let anchor = term.anchor_cursor_line().unwrap();
        let output: String = (1..=10).map(|line| format!("\r\nout {line}")).collect();
        term.vt_write(output.as_bytes());
        let after = term.text_after_anchor(&anchor).unwrap();
        let lines: Vec<&str> = after.lines().collect();
        assert_eq!(lines.first().copied(), Some("out 1"));
        assert_eq!(lines.last().copied(), Some("out 10"));
    }
}
