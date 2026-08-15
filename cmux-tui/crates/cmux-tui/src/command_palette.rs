use std::cmp::Reverse;

use cmux_tui_core::Rect;
use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};

use crate::actions::{
    ActionCandidate, ActionContextSnapshot, ActionInvocation, DisabledReason, search_score,
};
use crate::ui::input::{InputEvent, TextInput};

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum CommandPaletteOutcome {
    None,
    Draw,
    Close,
    Invoke(ActionInvocation),
    Disabled(DisabledReason),
}

pub(crate) struct CommandPalette {
    pub input: TextInput,
    pub candidates: Vec<ActionCandidate>,
    pub filtered: Vec<usize>,
    pub selected: usize,
    pub scroll_offset: usize,
    pub rect: Rect,
    pub input_rect: Rect,
    pub row_rects: Vec<(Rect, usize)>,
    pub visible_rows: usize,
    pub context: ActionContextSnapshot,
}

impl CommandPalette {
    pub(crate) fn new(
        context: ActionContextSnapshot,
        candidates: Vec<ActionCandidate>,
    ) -> Self {
        let mut palette = Self {
            input: TextInput::new(String::new()),
            candidates,
            filtered: Vec::new(),
            selected: 0,
            scroll_offset: 0,
            rect: Rect::default(),
            input_rect: Rect::default(),
            row_rects: Vec::new(),
            visible_rows: 0,
            context,
        };
        palette.refilter(None);
        palette
    }

    pub(crate) fn insert_text(&mut self, text: &str) -> bool {
        let selected = self.selected_id().map(ToOwned::to_owned);
        if !self.input.insert_str(text) {
            return false;
        }
        self.refilter(selected.as_deref());
        true
    }

    pub(crate) fn replace_candidates(
        &mut self,
        context: ActionContextSnapshot,
        candidates: Vec<ActionCandidate>,
    ) {
        let selected = self.selected_id().map(ToOwned::to_owned);
        self.context = context;
        self.candidates = candidates;
        self.refilter(selected.as_deref());
    }

    pub(crate) fn handle_key(&mut self, key: KeyEvent) -> CommandPaletteOutcome {
        match key.code {
            KeyCode::Esc => return CommandPaletteOutcome::Close,
            KeyCode::Up
            | KeyCode::Char('p')
                if key.code == KeyCode::Up || key.modifiers.contains(KeyModifiers::CONTROL) =>
            {
                return self.move_selection(-1);
            }
            KeyCode::Down
            | KeyCode::Char('n')
                if key.code == KeyCode::Down || key.modifiers.contains(KeyModifiers::CONTROL) =>
            {
                return self.move_selection(1);
            }
            KeyCode::PageUp => return self.move_selection(-(self.visible_rows.max(1) as isize)),
            KeyCode::PageDown => return self.move_selection(self.visible_rows.max(1) as isize),
            KeyCode::Home if key.modifiers.is_empty() => return self.select_first(),
            KeyCode::End if key.modifiers.is_empty() => return self.select_last(),
            KeyCode::Enter => return self.invoke_selected(),
            _ => {}
        }

        let selected = self.selected_id().map(ToOwned::to_owned);
        match self.input.handle_key(&key) {
            InputEvent::Changed => {
                self.refilter(selected.as_deref());
                CommandPaletteOutcome::Draw
            }
            InputEvent::Commit => self.invoke_selected(),
            InputEvent::Cancel => CommandPaletteOutcome::Close,
            InputEvent::None => CommandPaletteOutcome::None,
        }
    }

    pub(crate) fn move_selection(&mut self, delta: isize) -> CommandPaletteOutcome {
        if self.filtered.is_empty() {
            return CommandPaletteOutcome::None;
        }
        self.selected = self
            .selected
            .saturating_add_signed(delta)
            .min(self.filtered.len().saturating_sub(1));
        self.ensure_selected_visible();
        CommandPaletteOutcome::Draw
    }

    pub(crate) fn select_filtered_index(&mut self, index: usize) -> CommandPaletteOutcome {
        if index >= self.filtered.len() {
            return CommandPaletteOutcome::None;
        }
        self.selected = index;
        self.ensure_selected_visible();
        CommandPaletteOutcome::Draw
    }

    pub(crate) fn invoke_selected(&self) -> CommandPaletteOutcome {
        let Some(candidate) = self.selected_candidate() else {
            return CommandPaletteOutcome::None;
        };
        match candidate.disabled_reason() {
            Some(reason) => CommandPaletteOutcome::Disabled(reason),
            None => CommandPaletteOutcome::Invoke(ActionInvocation::palette(
                candidate.command.clone(),
                self.context.target.clone(),
            )),
        }
    }

    pub(crate) fn selected_candidate(&self) -> Option<&ActionCandidate> {
        self.filtered.get(self.selected).and_then(|index| self.candidates.get(*index))
    }

    pub(crate) fn visible_candidates(
        &self,
    ) -> impl Iterator<Item = (usize, &ActionCandidate)> + '_ {
        self.filtered
            .iter()
            .enumerate()
            .skip(self.scroll_offset)
            .take(self.visible_rows)
            .filter_map(|(filtered_index, candidate_index)| {
                self.candidates.get(*candidate_index).map(|candidate| (filtered_index, candidate))
            })
    }

    pub(crate) fn set_render_geometry(
        &mut self,
        rect: Rect,
        input_rect: Rect,
        row_rects: Vec<(Rect, usize)>,
        visible_rows: usize,
    ) {
        self.rect = rect;
        self.input_rect = input_rect;
        self.row_rects = row_rects;
        self.visible_rows = visible_rows;
        self.ensure_selected_visible();
    }

    pub(crate) fn clear_render_geometry(&mut self) {
        self.rect = Rect::default();
        self.input_rect = Rect::default();
        self.row_rects.clear();
        self.visible_rows = 0;
    }

    fn select_first(&mut self) -> CommandPaletteOutcome {
        if self.filtered.is_empty() {
            return CommandPaletteOutcome::None;
        }
        self.selected = 0;
        self.ensure_selected_visible();
        CommandPaletteOutcome::Draw
    }

    fn select_last(&mut self) -> CommandPaletteOutcome {
        if self.filtered.is_empty() {
            return CommandPaletteOutcome::None;
        }
        self.selected = self.filtered.len() - 1;
        self.ensure_selected_visible();
        CommandPaletteOutcome::Draw
    }

    fn selected_id(&self) -> Option<&str> {
        self.selected_candidate().map(|candidate| candidate.id.as_str())
    }

    fn refilter(&mut self, preserve_id: Option<&str>) {
        let query = self.input.as_str();
        let mut matches = self
            .candidates
            .iter()
            .enumerate()
            .filter_map(|(index, candidate)| {
                search_score(query, &candidate.title, candidate.id.as_str(), candidate.focus_rank)
                    .map(|score| (index, score, candidate.availability.is_enabled()))
            })
            .collect::<Vec<_>>();
        matches.sort_by_key(|(index, score, enabled)| (Reverse(*score), Reverse(*enabled), *index));
        self.filtered = matches.into_iter().map(|(index, _, _)| index).collect();
        self.selected = preserve_id
            .and_then(|id| {
                self.filtered.iter().position(|candidate| {
                    self.candidates[*candidate].id.as_str() == id
                })
            })
            .unwrap_or(0)
            .min(self.filtered.len().saturating_sub(1));
        self.scroll_offset = 0;
        self.ensure_selected_visible();
    }

    fn ensure_selected_visible(&mut self) {
        if self.filtered.is_empty() {
            self.selected = 0;
            self.scroll_offset = 0;
            return;
        }
        self.selected = self.selected.min(self.filtered.len() - 1);
        if self.visible_rows == 0 {
            return;
        }
        if self.selected < self.scroll_offset {
            self.scroll_offset = self.selected;
        } else if self.selected >= self.scroll_offset + self.visible_rows {
            self.scroll_offset = self.selected + 1 - self.visible_rows;
        }
        self.scroll_offset = self
            .scroll_offset
            .min(self.filtered.len().saturating_sub(self.visible_rows));
    }
}

#[cfg(test)]
mod tests {
    use cmux_tui_core::SurfaceKind;

    use super::*;
    use crate::actions::{ActionFocus, ActionRegistry};
    use crate::config::Keys;
    use crate::localization::catalog_for_locale;

    fn palette() -> CommandPalette {
        let context = ActionContextSnapshot::for_test(ActionFocus::Pane, SurfaceKind::Pty);
        let candidates = ActionRegistry::candidates(
            &context,
            &Keys::default(),
            catalog_for_locale("en"),
            &[],
        );
        CommandPalette::new(context, candidates)
    }

    #[test]
    fn filtering_keeps_disabled_actions_and_enter_reports_the_reason() {
        let mut palette = palette();
        assert!(palette.insert_text("browser back"));
        assert_eq!(palette.filtered.len(), 1);
        assert_eq!(
            palette.invoke_selected(),
            CommandPaletteOutcome::Disabled(DisabledReason::NoBrowser)
        );
    }

    #[test]
    fn query_changes_preserve_selection_when_the_action_still_matches() {
        let mut palette = palette();
        assert!(palette.insert_text("pane"));
        palette.move_selection(2);
        let selected = palette.selected_id().unwrap().to_string();
        assert!(palette.insert_text(" "));
        assert_eq!(palette.selected_id(), Some(selected.as_str()));
    }

    #[test]
    fn tiny_viewports_do_not_underflow_navigation() {
        let mut palette = palette();
        palette.set_render_geometry(Rect::default(), Rect::default(), Vec::new(), 0);
        assert_eq!(palette.move_selection(1), CommandPaletteOutcome::Draw);
        assert_eq!(palette.move_selection(-100), CommandPaletteOutcome::Draw);
    }
}
