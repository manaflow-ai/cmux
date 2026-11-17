//! Keyboard copy mode on the App: entering it for the active terminal,
//! routing its keys, applying each command's viewport and yank, and the
//! per-frame overlay and mode line it draws.
//!
//! Copy mode is client presentation state. It reads the terminal it shows
//! (the local view or the remote mirror), moves only this client's view,
//! and copies through the same OSC 52 path as a mouse selection. Outside
//! copy mode the key and draw paths do no extra work.

mod engine;
mod grid;
mod motion;
mod search;
#[cfg(test)]
mod tests;

use cmux_tui_core::{SurfaceId, SurfaceKind};

use self::engine::VisualMode;
pub(crate) use self::engine::{CopyModeState, CopyOutcome, CopyPoint, CopyView, ResolvedSelection};
use self::grid::TerminalGrid;
use crate::app::FocusTarget;
use crate::app::{App, RenderAction};
use crate::config::CopyModeAction;
use crate::keys::KeyboardInput;
use crate::localization;
use crate::session::SurfaceHandle;

/// Copy mode bound to one terminal surface.
#[derive(Debug, Clone)]
pub(crate) struct CopyModeSession {
    pub(crate) surface: SurfaceId,
    pub(crate) state: CopyModeState,
}

/// What one frame draws over a pane in copy mode. Built only while copy
/// mode is active on that pane, holding only the matches in view.
#[derive(Debug, Clone, Default)]
pub(crate) struct CopyOverlay {
    /// The copy cursor, as a viewport cell.
    pub(crate) cursor: Option<(u16, u16)>,
    pub(crate) selection: Option<ResolvedSelection>,
    /// Viewport row offset the absolute rows are relative to.
    pub(crate) offset: u64,
    /// Matches touching the view, and which of them is current.
    pub(crate) matches: Vec<(CopyPoint, CopyPoint, bool)>,
}

impl CopyOverlay {
    /// Whether a viewport cell is inside the copy-mode selection.
    pub(crate) fn selected(&self, col: u16, row: u16) -> bool {
        self.selection
            .is_some_and(|selection| selection.contains(self.offset + u64::from(row), col))
    }
}

/// The mode line shown in the status row while copy mode is active.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct CopyModeLine {
    pub(crate) mode: &'static str,
    /// `row/total`, counting rows from the top of history.
    pub(crate) position: String,
    /// The search prompt being typed: its `/` or `?` and the needle so far.
    pub(crate) prompt: Option<(char, String)>,
    /// The submitted search: its `/` or `?`, needle, and `k/n` count.
    pub(crate) search: Option<(char, String, String)>,
    pub(crate) notice: Option<&'static str>,
    /// `key label` pairs for the most used commands.
    pub(crate) hints: Vec<(String, &'static str)>,
}

impl App {
    pub(crate) fn copy_mode_active(&self) -> bool {
        self.copy_mode.is_some()
    }

    /// `copy-mode` and `search-scrollback`: enter copy mode on the active
    /// terminal, and with `search` open the backward search prompt at once.
    pub(super) fn enter_copy_mode(&mut self, search: bool) {
        if self
            .copy_mode
            .as_ref()
            .is_some_and(|session| Some(session.surface) == self.active_surface())
        {
            if search && let Some(session) = self.copy_mode.as_mut() {
                session.state.open_search(false);
            }
            return;
        }
        self.drop_copy_mode();
        let Some((surface, handle)) = self.active_surface_with_handle() else { return };
        if handle.kind() != SurfaceKind::Pty {
            return;
        }
        let Some(view) = copy_view(&handle) else { return };
        let Some(mut state) =
            handle.with_terminal(|term| CopyModeState::enter(&mut TerminalGrid::new(term), view))
        else {
            return;
        };
        if search {
            state.open_search(false);
        }
        self.replace_selection(None);
        self.copy_mode = Some(CopyModeSession { surface, state });
    }

    /// Leave copy mode and return its terminal's view to the live bottom.
    pub(super) fn exit_copy_mode(&mut self) {
        if let Some(session) = self.copy_mode.take()
            && let Some(handle) = self.session.surface(session.surface)
        {
            let _ = handle.scroll_to_bottom();
        }
    }

    /// Forget copy mode without moving any view (its surface is gone or no
    /// longer focused).
    fn drop_copy_mode(&mut self) {
        self.copy_mode = None;
    }

    /// Route one key to copy mode. `None` when copy mode is not active for
    /// the focused terminal, so the key takes its normal path.
    pub(super) fn copy_mode_key(&mut self, input: &KeyboardInput) -> Option<RenderAction> {
        let session = self.copy_mode.as_ref()?;
        if self.focus != FocusTarget::Pane || Some(session.surface) != self.active_surface() {
            self.drop_copy_mode();
            return None;
        }
        if session.state.input.is_some() {
            let key = input.ui_key();
            let text = input
                .text_for_direct_input()
                .filter(|text| text.chars().any(|c| !c.is_control()))
                .map(str::to_string);
            self.run_copy_command(|state, grid, view| {
                state.input_key(grid, view, &key, text.as_deref());
                CopyOutcome::Stay
            });
            return Some(RenderAction::Draw);
        }
        let (binding_key, fallback) = input.shortcut_keys();
        let action = self
            .config
            .keys
            .copy_mode
            .action_for(&binding_key)
            .or_else(|| fallback.and_then(|key| self.config.keys.copy_mode.action_for(&key)));
        if let Some(action) = action {
            self.run_copy_action(action);
        }
        // Unbound keys are swallowed: copy mode never types into the shell.
        Some(RenderAction::Draw)
    }

    pub(super) fn run_copy_action(&mut self, action: CopyModeAction) {
        self.run_copy_command(|state, grid, view| state.apply(grid, view, action));
    }

    fn run_copy_command(
        &mut self,
        command: impl FnOnce(&mut CopyModeState, &mut TerminalGrid<'_>, &mut CopyView) -> CopyOutcome,
    ) {
        let Some(mut session) = self.copy_mode.take() else { return };
        let Some(handle) = self.session.surface(session.surface) else { return };
        let Some(before) = copy_view(&handle) else { return };
        let mut view = before;
        let Some(outcome) = handle.with_terminal(|term| {
            command(&mut session.state, &mut TerminalGrid::new(term), &mut view)
        }) else {
            return;
        };
        if view.top != before.top {
            let delta = i128::from(view.top) - i128::from(before.top);
            let _ =
                handle.scroll_delta(delta.clamp(isize::MIN as i128, isize::MAX as i128) as isize);
        }
        self.copy_mode = Some(session);
        match outcome {
            CopyOutcome::Stay => {}
            CopyOutcome::Exit => self.exit_copy_mode(),
            CopyOutcome::Yank(text) => {
                self.copy_terminal_text(&handle, text);
                self.exit_copy_mode();
            }
        }
    }

    /// Copy terminal text to the host clipboard and record it as the
    /// surface's selection text, as a completed mouse selection does.
    pub(super) fn copy_terminal_text(&mut self, handle: &SurfaceHandle, text: String) {
        if let SurfaceHandle::Local(local, _) = handle {
            local.set_selection_text(Some(text.clone()));
        }
        self.copy_text_to_clipboard(&text);
        self.show_toast(localization::catalog().menu.copied.to_string());
    }

    /// `scroll-page-*` and `scroll-half-page-*`: scroll the active terminal
    /// by `numerator / denominator` of its visible rows.
    pub(super) fn scroll_active_pages(&mut self, numerator: isize, denominator: isize) {
        let Some(handle) = self.active_surface_handle() else { return };
        if handle.kind() != SurfaceKind::Pty {
            return;
        }
        let rows = handle.scrollbar().map_or(1, |scrollbar| scrollbar.len.max(1)) as isize;
        let step = (rows * numerator.abs() / denominator.max(1)).max(1);
        let _ = handle.scroll_delta(step * numerator.signum());
    }

    /// The overlay one frame draws over `surface`, when copy mode is on it.
    pub(crate) fn copy_overlay(
        &self,
        surface: SurfaceId,
        offset: u64,
        rows: u16,
    ) -> Option<CopyOverlay> {
        let session = self.copy_mode.as_ref().filter(|session| session.surface == surface)?;
        let state = &session.state;
        let bottom = offset + u64::from(rows.max(1)) - 1;
        let cursor = (state.cursor.row >= offset && state.cursor.row <= bottom)
            .then(|| (state.cursor.col, (state.cursor.row - offset) as u16));
        let matches = state.search.as_ref().map_or_else(Vec::new, |search| {
            let current = search.current.and_then(|index| search.matches.get(index)).map(|m| m.0);
            search
                .matches_in_rows(offset, bottom)
                .iter()
                .map(|&(start, end)| (start, end, Some(start) == current))
                .collect()
        });
        Some(CopyOverlay { cursor, selection: state.selection, offset, matches })
    }

    /// The mode line, while copy mode is active on the focused terminal. A
    /// prefix command that moves focus hides it at once.
    pub(crate) fn copy_mode_line(&self) -> Option<CopyModeLine> {
        let session = self.copy_mode.as_ref()?;
        if self.focus != FocusTarget::Pane || Some(session.surface) != self.active_surface() {
            return None;
        }
        let state = &session.state;
        let messages = &localization::catalog().copy_mode;
        let mode = match state.visual {
            None => messages.mode_copy,
            Some(VisualMode::Char) => messages.mode_visual,
            Some(VisualMode::Line) => messages.mode_visual_line,
            Some(VisualMode::Block) => messages.mode_visual_block,
        };
        let direction = |forward: bool| if forward { '/' } else { '?' };
        let keys = &self.config.keys.copy_mode;
        let hints = [
            (CopyModeAction::SelectChar, messages.hint_select),
            (CopyModeAction::Yank, messages.hint_copy),
            (CopyModeAction::SearchForward, messages.hint_search),
            (CopyModeAction::Exit, messages.hint_exit),
        ]
        .into_iter()
        .filter_map(|(action, label)| Some((keys.label(action)?, label)))
        .collect();
        Some(CopyModeLine {
            mode,
            position: format!("{}/{}", state.cursor.row + 1, state.total_rows),
            prompt: state
                .input
                .as_ref()
                .map(|input| (direction(input.forward), input.text.as_str().to_string())),
            search: state.search.as_ref().map(|search| {
                (direction(search.forward), search.needle.clone(), search.count_label())
            }),
            notice: state.notice,
            hints,
        })
    }
}

/// The rows the person sees of a terminal: its view offset and height.
fn copy_view(handle: &SurfaceHandle) -> Option<CopyView> {
    let scrollbar = handle.scrollbar()?;
    Some(CopyView {
        top: scrollbar.offset,
        height: u16::try_from(scrollbar.len.max(1)).unwrap_or(u16::MAX),
    })
}
