//! Command palette for the mux TUI.
//!
//! This is a thin wrapper around the shared palette component
//! that adds MuxCommand-specific functionality.

use crate::mux::commands::MuxCommand;
use crate::palette::{Palette, PaletteItem as SharedPaletteItem};

/// Re-export PaletteItem for compatibility with existing code.
#[derive(Debug, Clone)]
pub enum PaletteItem {
    /// A header/separator for grouping.
    Header(String),
    /// A command with its details.
    Command {
        command: MuxCommand,
        is_highlighted: bool,
        label_highlights: Vec<usize>,
    },
}

/// State for the command palette.
/// Wraps the shared Palette component.
#[derive(Debug)]
pub struct CommandPalette<'a> {
    inner: Palette<'a, MuxCommand>,
}

impl Default for CommandPalette<'_> {
    fn default() -> Self {
        Self::new()
    }
}

impl<'a> CommandPalette<'a> {
    pub fn new() -> Self {
        Self {
            inner: Palette::new(MuxCommand::all().to_vec()),
        }
    }

    /// Check if palette is visible.
    pub fn is_visible(&self) -> bool {
        self.inner.visible
    }

    /// Open the palette.
    pub fn open(&mut self) {
        self.inner.open();
    }

    /// Close the palette.
    pub fn close(&mut self) {
        self.inner.close();
    }

    /// Get the current search query.
    pub fn search_query(&self) -> String {
        self.inner.search_query()
    }

    /// Handle text input.
    pub fn handle_input(&mut self, input: impl Into<tui_textarea::Input>) {
        self.inner.handle_input(input);
    }

    /// Move selection up.
    pub fn select_up(&mut self) {
        self.inner.select_up();
    }

    /// Move selection down.
    pub fn select_down(&mut self) {
        self.inner.select_down();
    }

    /// Get the currently selected command.
    pub fn selected_command(&self) -> Option<MuxCommand> {
        self.inner.selected_command()
    }

    /// Execute the selected command and close the palette.
    pub fn execute_selection(&mut self) -> Option<MuxCommand> {
        self.inner.execute_selection()
    }

    /// Get palette items grouped by category for rendering.
    /// Returns (items, selected_line_index).
    pub fn get_items(&self) -> (Vec<PaletteItem>, Option<usize>) {
        let (shared_items, selected_line) = self.inner.get_items();

        let items = shared_items
            .into_iter()
            .map(|item| match item {
                SharedPaletteItem::Header(text) => PaletteItem::Header(text),
                SharedPaletteItem::Spacer => PaletteItem::Header(String::new()),
                SharedPaletteItem::Loading => PaletteItem::Header("Loading...".to_string()),
                SharedPaletteItem::Command {
                    command,
                    is_highlighted,
                    label_indices,
                } => PaletteItem::Command {
                    command,
                    is_highlighted,
                    label_highlights: label_indices,
                },
            })
            .collect();

        (items, selected_line)
    }

    /// Update scroll offset to keep selected item visible.
    pub fn adjust_scroll(&mut self, selected_line: usize, visible_height: usize) {
        self.inner.adjust_scroll(selected_line, visible_height);
    }

    /// Get the current scroll offset.
    pub fn scroll_offset(&self) -> usize {
        self.inner.scroll_offset
    }

    /// Get count of filtered commands.
    pub fn filtered_count(&self) -> usize {
        self.inner.filtered_count()
    }

    /// Get reference to the search input TextArea for rendering.
    pub fn search_input(&self) -> &tui_textarea::TextArea<'a> {
        &self.inner.search_input
    }

    /// Get selected index.
    pub fn selected_index(&self) -> usize {
        self.inner.selected_index
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn palette_filtering_works() {
        let mut palette = CommandPalette::new();
        palette.open();

        // Initial state should show all commands
        assert!(palette.filtered_count() > 0);
    }

    #[test]
    fn palette_matches_focus_main_area_abbreviation() {
        use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};

        let mut palette = CommandPalette::new();
        palette.open();

        let query = "fmain ar";
        for ch in query.chars() {
            let key_event = KeyEvent::new(KeyCode::Char(ch), KeyModifiers::NONE);
            palette.handle_input(key_event);
        }

        let (items, _) = palette.get_items();
        assert!(items.iter().any(|item| matches!(
            item,
            PaletteItem::Command {
                command: MuxCommand::FocusMainArea,
                ..
            }
        )));
    }

    #[test]
    fn palette_matches_focus_main_area_via_key_events() {
        use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};

        let mut palette = CommandPalette::new();
        palette.open();

        let query = "fmain ar";
        for ch in query.chars() {
            let key_event = KeyEvent::new(KeyCode::Char(ch), KeyModifiers::NONE);
            palette.handle_input(key_event);
        }

        let (items, _) = palette.get_items();
        assert!(items.iter().any(|item| matches!(
            item,
            PaletteItem::Command {
                command: MuxCommand::FocusMainArea,
                ..
            }
        )));
    }

    #[test]
    fn palette_matches_exact_phrase_via_key_events() {
        use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};

        let mut palette = CommandPalette::new();
        palette.open();

        let query = "Focus Main Area";
        for ch in query.chars() {
            let key_event = KeyEvent::new(KeyCode::Char(ch), KeyModifiers::NONE);
            palette.handle_input(key_event);
        }

        let (items, _) = palette.get_items();
        assert!(
            items.iter().any(|item| matches!(
                item,
                PaletteItem::Command {
                    command: MuxCommand::FocusMainArea,
                    ..
                }
            )),
            "Expected FocusMainArea in filtered commands"
        );
    }

    #[test]
    fn palette_navigation_works() {
        let mut palette = CommandPalette::new();
        palette.open();

        assert_eq!(palette.selected_index(), 0);

        palette.select_down();
        assert_eq!(palette.selected_index(), 1);

        palette.select_up();
        assert_eq!(palette.selected_index(), 0);

        palette.select_up();
        assert_eq!(palette.selected_index(), palette.filtered_count() - 1);
    }

    #[test]
    fn palette_selection_works() {
        let mut palette = CommandPalette::new();
        palette.open();

        let selected = palette.selected_command();
        assert!(selected.is_some());
    }
}
