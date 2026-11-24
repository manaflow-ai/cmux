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
        let mut output = output.trim_matches(|c| c == '\n' || c == '\r').to_owned();
        // Output with no final newline (`printf foo`) ends on the prompt's
        // own row, before the prompt's first cell.
        if let Some(tail) = self.output_before_prompt(prompt, cols) {
            if !output.is_empty() {
                output.push('\n');
            }
            output.push_str(&tail);
        }
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

    /// The text left of the first prompt or input cell of screen row `row`,
    /// when that row starts with output; `None` when the prompt starts it.
    fn output_before_prompt(&mut self, row: u64, cols: u16) -> Option<String> {
        let first = (0..cols).find(|&x| {
            self.cell_semantic(x, row).is_some_and(|semantic| {
                semantic == sys::GHOSTTY_CELL_SEMANTIC_PROMPT
                    || semantic == sys::GHOSTTY_CELL_SEMANTIC_INPUT
            })
        })?;
        let text = self.selection_text_absolute((0, row), (first.checked_sub(1)?, row))?;
        let text = text.trim_end();
        (!text.is_empty()).then(|| text.to_owned())
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
        (0..cols).any(|x| self.cell_semantic(x, row).is_some_and(|s| semantics.contains(&s)))
    }

    /// The semantic content of the cell at column `x` of screen row `row`.
    fn cell_semantic(&self, x: u16, row: u64) -> Option<sys::GhosttyCellSemanticContent> {
        let grid_ref = self.grid_ref(sys::GHOSTTY_POINT_TAG_SCREEN, x, row)?;
        let mut cell = sys::GhosttyCell::default();
        check(unsafe { sys::ghostty_grid_ref_cell(&grid_ref, &mut cell) }).ok()?;
        let mut semantic = sys::GHOSTTY_CELL_SEMANTIC_OUTPUT;
        check(unsafe {
            sys::ghostty_cell_get(
                cell,
                sys::GHOSTTY_CELL_DATA_SEMANTIC_CONTENT,
                (&mut semantic as *mut sys::GhosttyCellSemanticContent).cast(),
            )
        })
        .ok()?;
        Some(semantic)
    }
}

#[cfg(test)]
#[path = "command_output_tests.rs"]
mod tests;
