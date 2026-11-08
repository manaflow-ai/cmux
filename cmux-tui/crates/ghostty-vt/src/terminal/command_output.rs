//! The newest finished shell command on the primary screen: its command line
//! and the output between it and the prompt the cursor sits at, read from
//! the OSC 133 semantics Ghostty stores per row and cell. A read on request
//! (Fix, Send Last Output to Chat), never per output line.

use super::*;

/// The command line and output of the newest finished command.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommandOutput {
    /// The command line, from the cells OSC 133 marks as input; `None` when
    /// its input is not on the retained screen.
    pub command: Option<String>,
    /// Its output, at most the newest `max_rows` rows, without leading or
    /// trailing blank lines; empty for a command that printed nothing.
    pub output: String,
    /// Whether older output rows were left out.
    pub truncated: bool,
}

impl Terminal {
    /// The newest finished command above the prompt the cursor sits at, or
    /// `None` on the alternate screen, without shell integration, or while
    /// the cursor is not at a prompt (a command is running). Scans at most
    /// `max_rows` output rows up from that prompt and keeps the newest.
    pub fn last_command_output(&mut self, max_rows: u32) -> Option<CommandOutput> {
        if self.active_screen() == Screen::Alternate {
            return None;
        }
        let scrollbar = self.scrollbar()?;
        let (_, cursor_y) = self.cursor_position()?;
        let active_top = scrollbar.total.checked_sub(u64::from(self.rows()))?;
        let cursor_row = active_top + u64::from(cursor_y);
        let cols = self.cols();
        if !self.is_shell_row(cursor_row, cols) {
            return None;
        }
        // The prompt the cursor sits at: up to its first row (a PROMPT row,
        // not a continuation), then over earlier rows of the same prompt that
        // some shells also mark PROMPT. The finished command's own input row
        // holds input cells, which stops the walk.
        let mut prompt = cursor_row;
        while prompt > 0
            && self.row_semantic(prompt) != Some(sys::GHOSTTY_ROW_SEMANTIC_PROMPT)
            && self.is_shell_row(prompt - 1, cols)
        {
            prompt -= 1;
        }
        while prompt > 0
            && self.row_semantic(prompt - 1) == Some(sys::GHOSTTY_ROW_SEMANTIC_PROMPT)
            && !self.has_cells(prompt - 1, cols, &[sys::GHOSTTY_CELL_SEMANTIC_INPUT])
        {
            prompt -= 1;
        }
        let bottom = prompt.checked_sub(1)?;
        // Output rows run up to the finished command's input.
        let lowest = bottom.saturating_sub(u64::from(max_rows.max(1)) - 1);
        let mut top = bottom + 1;
        let mut truncated = false;
        while top > 0 && !self.is_shell_row(top - 1, cols) {
            if top - 1 < lowest {
                truncated = true;
                break;
            }
            top -= 1;
        }
        let command = if truncated {
            None
        } else {
            top.checked_sub(1).and_then(|input| self.input_text_at_or_above(input, 32))
        };
        let output = if top <= bottom {
            self.selection_text_absolute((0, top), (cols.saturating_sub(1), bottom))
                .unwrap_or_default()
        } else {
            String::new()
        };
        let output = output.trim_matches(|c| c == '\n' || c == '\r').to_owned();
        Some(CommandOutput { command, output, truncated })
    }

    /// The input block ending at screen row `row`: the contiguous rows with
    /// input cells at or above it, at most `max_rows` up.
    fn input_text_at_or_above(&mut self, row: u64, max_rows: u32) -> Option<String> {
        let cols = self.cols();
        let (_, last_x) = self.input_span(row, cols)?;
        let lowest = row.saturating_sub(u64::from(max_rows));
        let mut first = (self.input_span(row, cols)?.0, row);
        let mut above = row;
        while above > lowest {
            above -= 1;
            match self.input_span(above, cols) {
                Some((start, _)) => first = (start, above),
                None => break,
            }
        }
        self.selection_text_absolute(first, (last_x, row))
    }

    /// Whether screen row `row` belongs to the shell (a prompt or input row)
    /// rather than to a command's output.
    fn is_shell_row(&self, row: u64, cols: u16) -> bool {
        self.row_semantic(row).is_some_and(|semantic| semantic != sys::GHOSTTY_ROW_SEMANTIC_NONE)
            || self.has_cells(
                row,
                cols,
                &[sys::GHOSTTY_CELL_SEMANTIC_INPUT, sys::GHOSTTY_CELL_SEMANTIC_PROMPT],
            )
    }

    fn row_semantic(&self, row: u64) -> Option<sys::GhosttyRowSemanticPrompt> {
        self.row_prompt_semantic(sys::GHOSTTY_POINT_TAG_SCREEN, row)
    }

    /// Whether any cell of screen row `row` carries one of `semantics`.
    fn has_cells(
        &self,
        row: u64,
        cols: u16,
        semantics: &[sys::GhosttyCellSemanticContent],
    ) -> bool {
        (0..cols).any(|x| {
            let Some(grid_ref) = self.grid_ref(sys::GHOSTTY_POINT_TAG_SCREEN, x, row) else {
                return false;
            };
            let mut cell = sys::GhosttyCell::default();
            if check(unsafe { sys::ghostty_grid_ref_cell(&grid_ref, &mut cell) }).is_err() {
                return false;
            }
            let mut semantic = sys::GHOSTTY_CELL_SEMANTIC_OUTPUT;
            check(unsafe {
                sys::ghostty_cell_get(
                    cell,
                    sys::GHOSTTY_CELL_DATA_SEMANTIC_CONTENT,
                    (&mut semantic as *mut sys::GhosttyCellSemanticContent).cast(),
                )
            })
            .is_ok()
                && semantics.contains(&semantic)
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn shell() -> Terminal {
        Terminal::new(40, 10, 10_000, Callbacks::default()).unwrap()
    }

    /// One prompt, a submitted command, its output and `D;code`, then the next prompt.
    fn run(term: &mut Terminal, command: &str, output: &str, code: i32) {
        term.vt_write(
            format!("\x1b]133;A\x07$ \x1b]133;B\x07{command}\r\n\x1b]133;C\x07").as_bytes(),
        );
        term.vt_write(output.as_bytes());
        term.vt_write(format!("\x1b]133;D;{code}\x07").as_bytes());
    }

    fn prompt(term: &mut Terminal) {
        term.vt_write(b"\x1b]133;A\x07$ \x1b]133;B\x07");
    }

    #[test]
    fn reads_the_command_and_its_output_above_the_prompt() {
        let mut term = shell();
        run(&mut term, "ls", "a\r\nb\r\n", 0);
        run(&mut term, "cargo test", "error[E0425]: x\r\nerror: could not compile\r\n", 101);
        prompt(&mut term);
        let last = term.last_command_output(100).unwrap();
        assert_eq!(last.command.as_deref(), Some("cargo test"));
        assert_eq!(last.output, "error[E0425]: x\nerror: could not compile");
        assert!(!last.truncated);
    }

    #[test]
    fn a_command_without_output_reads_empty_and_keeps_its_command() {
        let mut term = shell();
        run(&mut term, "echo hi", "hi\r\n", 0);
        run(&mut term, "false", "", 1);
        prompt(&mut term);
        let last = term.last_command_output(100).unwrap();
        assert_eq!(last.command.as_deref(), Some("false"));
        assert_eq!(last.output, "");
    }

    #[test]
    fn typing_at_the_new_prompt_does_not_change_the_read() {
        let mut term = shell();
        run(&mut term, "make", "boom\r\n", 2);
        prompt(&mut term);
        term.vt_write(b"git st");
        let last = term.last_command_output(100).unwrap();
        assert_eq!(last.command.as_deref(), Some("make"));
        assert_eq!(last.output, "boom");
    }

    #[test]
    fn long_output_keeps_the_newest_rows() {
        let mut term = shell();
        let output: String = (1..=50).map(|line| format!("line {line}\r\n")).collect();
        run(&mut term, "seq", &output, 1);
        prompt(&mut term);
        let last = term.last_command_output(5).unwrap();
        assert!(last.truncated);
        assert_eq!(last.command, None, "the input is past the scanned rows");
        assert_eq!(last.output, "line 46\nline 47\nline 48\nline 49\nline 50");
    }

    #[test]
    fn no_read_without_shell_integration_or_while_a_command_runs() {
        let mut term = shell();
        term.vt_write(b"$ ls\r\na\r\n$ ");
        assert_eq!(term.last_command_output(100), None, "no marks");

        let mut term = shell();
        term.vt_write(b"\x1b]133;A\x07$ \x1b]133;B\x07sleep 9\r\n\x1b]133;C\x07working\r\n");
        assert_eq!(term.last_command_output(100), None, "the cursor is in output");
    }
}
