//! The copy-mode state machine: cursor, viewport, visual selection, and the
//! command dispatcher. Every command runs against a [`TerminalGrid`] and a
//! [`CopyView`]; the caller applies the resulting view and outcome.

use crossterm::event::{KeyCode, KeyEvent};

use super::grid::TerminalGrid;
use super::motion;
use super::search::{SearchInput, SearchState};
use crate::config::CopyModeAction;
use crate::localization;
use crate::ui::input::InputEvent;

/// An absolute screen cell: `row` counts from the oldest retained row.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub(crate) struct CopyPoint {
    pub(crate) row: u64,
    pub(crate) col: u16,
}

impl CopyPoint {
    pub(crate) fn key(self) -> (u64, u16) {
        (self.row, self.col)
    }
}

/// The rows a pane shows: `top` is the absolute row of the first visible row.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct CopyView {
    pub(crate) top: u64,
    pub(crate) height: u16,
}

impl CopyView {
    pub(crate) fn bottom(self) -> u64 {
        self.top + u64::from(self.height.max(1)) - 1
    }

    pub(crate) fn contains_row(self, row: u64) -> bool {
        row >= self.top && row <= self.bottom()
    }

    fn max_top(self, total: u64) -> u64 {
        total.saturating_sub(u64::from(self.height.max(1)))
    }

    fn scroll_to(&mut self, top: i128, total: u64) {
        self.top = top.clamp(0, i128::from(self.max_top(total))) as u64;
    }

    /// Scroll as little as possible so `row` is visible.
    fn reveal(&mut self, row: u64, total: u64) {
        if row < self.top {
            self.top = row;
        } else if row > self.bottom() {
            self.top = row + 1 - u64::from(self.height.max(1));
        }
        self.top = self.top.min(self.max_top(total));
    }

    /// Put `row` in the middle of the view, when it is not visible yet.
    fn center(&mut self, row: u64, total: u64) {
        if !self.contains_row(row) {
            let half = i128::from(self.height / 2);
            self.scroll_to(i128::from(row) - half, total);
        }
    }
}

/// The visual selection kinds of copy mode.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum VisualMode {
    Char,
    Line,
    Block,
}

/// What a copy-mode command asks of its caller.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum CopyOutcome {
    /// Copy mode stays active; redraw.
    Stay,
    /// Leave copy mode.
    Exit,
    /// Copy this text to the clipboard, then leave copy mode.
    Yank(String),
}

/// One copy-mode session over one terminal surface.
#[derive(Debug, Clone)]
pub(crate) struct CopyModeState {
    pub(crate) cursor: CopyPoint,
    /// The column vertical motions return to (vim's "curswant").
    desired_col: u16,
    pub(crate) anchor: Option<CopyPoint>,
    pub(crate) visual: Option<VisualMode>,
    /// The resolved selection: inclusive start and end, and for a block
    /// selection its inclusive column span. Recomputed after every command.
    pub(crate) selection: Option<ResolvedSelection>,
    pub(crate) search: Option<SearchState>,
    pub(crate) input: Option<SearchInput>,
    /// A one-command notice for the mode line ("No match").
    pub(crate) notice: Option<&'static str>,
    pub(crate) total_rows: u64,
}

/// A selection resolved against the terminal, ready to draw or copy.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct ResolvedSelection {
    pub(crate) mode: VisualMode,
    pub(crate) start: CopyPoint,
    pub(crate) end: CopyPoint,
}

impl ResolvedSelection {
    /// Whether an absolute cell is selected.
    pub(crate) fn contains(&self, row: u64, col: u16) -> bool {
        if row < self.start.row || row > self.end.row {
            return false;
        }
        match self.mode {
            VisualMode::Line => true,
            VisualMode::Block => col >= self.start.col && col <= self.end.col,
            VisualMode::Char => {
                (row > self.start.row || col >= self.start.col)
                    && (row < self.end.row || col <= self.end.col)
            }
        }
    }
}

impl CopyModeState {
    /// Start copy mode at the terminal cursor when it is visible, otherwise
    /// at the start of the view's last row.
    pub(crate) fn enter(grid: &mut TerminalGrid<'_>, view: CopyView) -> Self {
        let cursor =
            grid.terminal_cursor_in(view).unwrap_or(CopyPoint { row: view.bottom(), col: 0 });
        let cursor = CopyPoint {
            row: cursor.row.min(grid.total_rows() - 1),
            col: grid.lead_col(cursor.row, cursor.col),
        };
        Self {
            cursor,
            desired_col: cursor.col,
            anchor: None,
            visual: None,
            selection: None,
            search: None,
            input: None,
            notice: None,
            total_rows: grid.total_rows(),
        }
    }

    /// Run one bound command.
    pub(crate) fn apply(
        &mut self,
        grid: &mut TerminalGrid<'_>,
        view: &mut CopyView,
        action: CopyModeAction,
    ) -> CopyOutcome {
        self.begin(grid, view);
        let outcome = self.dispatch(grid, view, action);
        self.finish(grid, view);
        outcome
    }

    /// Feed a key to the search prompt. Returns `false` when no prompt is open.
    pub(crate) fn input_key(
        &mut self,
        grid: &mut TerminalGrid<'_>,
        view: &mut CopyView,
        key: &KeyEvent,
        text: Option<&str>,
    ) -> bool {
        if self.input.is_none() {
            return false;
        }
        self.begin(grid, view);
        let event = match (self.input.as_mut(), text) {
            (Some(input), Some(text)) => {
                input.text.insert_str(text);
                InputEvent::Changed
            }
            // Backspace on an empty prompt closes it, as in vim.
            (Some(input), None)
                if key.code == KeyCode::Backspace && input.text.as_str().is_empty() =>
            {
                InputEvent::Cancel
            }
            (Some(input), None) => input.text.handle_key(key),
            (None, _) => InputEvent::None,
        };
        match event {
            InputEvent::Commit => {
                if let Some(input) = self.input.take() {
                    self.submit_search(grid, view, input);
                }
            }
            InputEvent::Cancel => self.input = None,
            InputEvent::Changed | InputEvent::None => {}
        }
        self.finish(grid, view);
        true
    }

    /// Open the search prompt. `forward` searches toward newer output.
    pub(crate) fn open_search(&mut self, forward: bool) {
        self.notice = None;
        self.input = Some(SearchInput::new(forward));
    }

    fn begin(&mut self, grid: &mut TerminalGrid<'_>, view: &CopyView) {
        self.notice = None;
        self.total_rows = grid.total_rows();
        let last = self.total_rows - 1;
        // Scrolling with the wheel can leave the cursor off screen: bring it
        // back into the rows the person sees before moving it.
        let top = view.top.min(last);
        let row = self.cursor.row.clamp(top, view.bottom().clamp(top, last));
        self.cursor = CopyPoint { row, col: grid.lead_col(row, self.cursor.col) };
    }

    fn finish(&mut self, grid: &mut TerminalGrid<'_>, view: &mut CopyView) {
        view.reveal(self.cursor.row, self.total_rows);
        self.selection = self.resolve_selection(grid);
    }

    fn dispatch(
        &mut self,
        grid: &mut TerminalGrid<'_>,
        view: &mut CopyView,
        action: CopyModeAction,
    ) -> CopyOutcome {
        use CopyModeAction as A;
        let page = i128::from(view.height.max(1));
        let half = (page / 2).max(1);
        match action {
            A::CursorLeft => self.set_col(grid.prev_col(self.cursor).unwrap_or(self.cursor.col)),
            A::CursorRight => self.set_col(grid.next_col(self.cursor).unwrap_or(self.cursor.col)),
            A::CursorUp => self.move_rows(grid, -1),
            A::CursorDown => self.move_rows(grid, 1),
            A::WordNext => self.set_point(motion::word_next(grid, self.cursor, false)),
            A::WordPrev => self.set_point(motion::word_prev(grid, self.cursor, false)),
            A::WordEnd => self.set_point(motion::word_end(grid, self.cursor, false)),
            A::BigWordNext => self.set_point(motion::word_next(grid, self.cursor, true)),
            A::BigWordPrev => self.set_point(motion::word_prev(grid, self.cursor, true)),
            A::BigWordEnd => self.set_point(motion::word_end(grid, self.cursor, true)),
            A::LineStart => self.set_col(0),
            A::LineFirstNonBlank => self.set_col(grid.first_non_blank(self.cursor.row)),
            A::LineEnd => self.set_col(grid.last_non_blank(self.cursor.row)),
            A::HistoryTop => self.set_point(CopyPoint { row: 0, col: grid.first_non_blank(0) }),
            A::HistoryBottom => {
                let row = motion::last_text_row(grid, *view);
                self.set_point(CopyPoint { row, col: grid.first_non_blank(row) });
            }
            A::ViewTop => self.set_row(grid, view.top),
            A::ViewMiddle => {
                let rows = view.bottom().min(self.total_rows - 1).saturating_sub(view.top);
                self.set_row(grid, view.top + rows / 2);
            }
            A::ViewBottom => self.set_row(grid, view.bottom().min(self.total_rows - 1)),
            A::HalfPageUp => self.scroll_with_cursor(grid, view, -half),
            A::HalfPageDown => self.scroll_with_cursor(grid, view, half),
            A::PageUp => self.scroll_with_cursor(grid, view, -page),
            A::PageDown => self.scroll_with_cursor(grid, view, page),
            A::ScrollLineUp => self.scroll_view(grid, view, -1),
            A::ScrollLineDown => self.scroll_view(grid, view, 1),
            A::SelectChar => self.toggle_visual(VisualMode::Char),
            A::SelectLine => self.toggle_visual(VisualMode::Line),
            A::SelectBlock => self.toggle_visual(VisualMode::Block),
            A::SwapSelectionEnd => {
                if let Some(anchor) = self.anchor.replace(self.cursor) {
                    self.cursor = anchor;
                    self.desired_col = anchor.col;
                }
            }
            A::Yank => return self.yank(grid),
            A::YankLine => {
                let (top, bottom) = grid.logical_line(self.cursor.row);
                let text = grid.text(
                    CopyPoint { row: top, col: 0 },
                    CopyPoint { row: bottom, col: grid.last_col() },
                    false,
                );
                return self.yank_text(text);
            }
            A::SearchForward => self.open_search(true),
            A::SearchBackward => self.open_search(false),
            A::SearchNext => self.repeat_search(grid, view, false),
            A::SearchPrev => self.repeat_search(grid, view, true),
            A::Cancel => {
                if self.visual.is_some() {
                    self.visual = None;
                    self.anchor = None;
                } else if self.search.is_some() {
                    self.search = None;
                } else {
                    return CopyOutcome::Exit;
                }
            }
            A::Exit => return CopyOutcome::Exit,
        }
        CopyOutcome::Stay
    }

    fn set_col(&mut self, col: u16) {
        self.cursor.col = col;
        self.desired_col = col;
    }

    fn set_point(&mut self, point: CopyPoint) {
        self.cursor = point;
        self.desired_col = point.col;
    }

    fn set_row(&mut self, grid: &mut TerminalGrid<'_>, row: u64) {
        let row = row.min(self.total_rows - 1);
        self.cursor = CopyPoint { row, col: grid.lead_col(row, self.desired_col) };
    }

    fn move_rows(&mut self, grid: &mut TerminalGrid<'_>, delta: i128) {
        let row = (i128::from(self.cursor.row) + delta).clamp(0, i128::from(self.total_rows - 1));
        self.set_row(grid, row as u64);
    }

    /// Ctrl-u/d and page keys: move the view and the cursor together.
    fn scroll_with_cursor(
        &mut self,
        grid: &mut TerminalGrid<'_>,
        view: &mut CopyView,
        delta: i128,
    ) {
        let before = view.top;
        view.scroll_to(i128::from(view.top) + delta, self.total_rows);
        let moved = i128::from(view.top) - i128::from(before);
        // At either end of history the view cannot move: move the cursor the
        // whole distance instead, as tmux does.
        let cursor_delta = if moved == 0 { delta } else { moved };
        self.move_rows(grid, cursor_delta);
    }

    /// Ctrl-y/e: move the view one line; the cursor stays on its row unless
    /// that row leaves the view.
    fn scroll_view(&mut self, grid: &mut TerminalGrid<'_>, view: &mut CopyView, delta: i128) {
        view.scroll_to(i128::from(view.top) + delta, self.total_rows);
        let last = self.total_rows - 1;
        let top = view.top.min(last);
        let row = self.cursor.row.clamp(top, view.bottom().clamp(top, last));
        if row != self.cursor.row {
            self.set_row(grid, row);
        }
    }

    fn toggle_visual(&mut self, mode: VisualMode) {
        if self.visual == Some(mode) {
            self.visual = None;
            self.anchor = None;
        } else {
            self.visual = Some(mode);
            self.anchor.get_or_insert(self.cursor);
        }
    }

    fn resolve_selection(&self, grid: &mut TerminalGrid<'_>) -> Option<ResolvedSelection> {
        let mode = self.visual?;
        let anchor = self.anchor?;
        let (first, last) = if anchor.key() <= self.cursor.key() {
            (anchor, self.cursor)
        } else {
            (self.cursor, anchor)
        };
        Some(match mode {
            VisualMode::Char => ResolvedSelection { mode, start: first, end: wide_end(grid, last) },
            VisualMode::Line => {
                let top = grid.logical_line(first.row).0;
                let bottom = grid.logical_line(last.row).1;
                ResolvedSelection {
                    mode,
                    start: CopyPoint { row: top, col: 0 },
                    end: CopyPoint { row: bottom, col: grid.last_col() },
                }
            }
            VisualMode::Block => {
                let left = anchor.col.min(self.cursor.col);
                let right_point = if anchor.col >= self.cursor.col { anchor } else { self.cursor };
                let right = wide_end(grid, right_point).col;
                ResolvedSelection {
                    mode,
                    start: CopyPoint { row: first.row, col: left },
                    end: CopyPoint { row: last.row, col: right },
                }
            }
        })
    }

    fn yank(&mut self, grid: &mut TerminalGrid<'_>) -> CopyOutcome {
        let Some(selection) = self.resolve_selection(grid) else {
            self.notice = Some(localization::catalog().copy_mode.nothing_selected);
            return CopyOutcome::Stay;
        };
        let text = grid.text(selection.start, selection.end, selection.mode == VisualMode::Block);
        self.yank_text(text)
    }

    fn yank_text(&mut self, text: Option<String>) -> CopyOutcome {
        match text {
            Some(text) if !text.is_empty() => CopyOutcome::Yank(text),
            _ => {
                self.notice = Some(localization::catalog().copy_mode.nothing_selected);
                CopyOutcome::Stay
            }
        }
    }

    fn submit_search(
        &mut self,
        grid: &mut TerminalGrid<'_>,
        view: &mut CopyView,
        input: SearchInput,
    ) {
        let needle = input.text.as_str().to_string();
        if needle.is_empty() {
            // An empty prompt repeats the last search in the new direction.
            if let Some(search) = self.search.as_mut() {
                search.forward = input.forward;
                self.repeat_search(grid, view, false);
            }
            return;
        }
        self.search = Some(SearchState::new(needle, input.forward));
        self.repeat_search(grid, view, false);
    }

    /// Jump to the next match in the search direction, or the opposite one
    /// when `reverse`; wraps around past either end.
    fn repeat_search(&mut self, grid: &mut TerminalGrid<'_>, view: &mut CopyView, reverse: bool) {
        let Some(search) = self.search.as_mut() else {
            self.notice = Some(localization::catalog().copy_mode.no_previous_search);
            return;
        };
        search.refresh(grid);
        let forward = search.forward != reverse;
        match search.step(self.cursor, forward) {
            Some(point) => {
                self.cursor = point;
                self.desired_col = point.col;
                view.center(point.row, self.total_rows);
            }
            None => self.notice = Some(localization::catalog().copy_mode.no_match),
        }
    }
}

/// A wide grapheme's lead extends a selection end over its trailing spacer.
fn wide_end(grid: &mut TerminalGrid<'_>, point: CopyPoint) -> CopyPoint {
    if grid.width(point) == ghostty_vt::CellWidth::Wide && point.col < grid.last_col() {
        CopyPoint { col: point.col + 1, ..point }
    } else {
        point
    }
}
