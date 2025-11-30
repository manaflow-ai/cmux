//! Shared command palette component for TUI applications.
//!
//! This module provides a reusable, fuzzy-searchable command palette
//! that can be used by both `mux` and `acp_client`.

use ratatui::{
    layout::Rect,
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, Clear, Paragraph},
    Frame,
};
use tui_textarea::TextArea;

/// A command that can be displayed in the palette.
pub trait PaletteCommand: Clone + Copy + PartialEq {
    /// The display label for this command.
    fn label(&self) -> &str;

    /// Optional description shown next to the label.
    fn description(&self) -> Option<&str> {
        None
    }

    /// Optional category for grouping commands.
    fn category(&self) -> Option<&str> {
        None
    }

    /// Optional keybinding hint shown on the right.
    fn keybinding(&self) -> Option<&str> {
        None
    }

    /// Whether this command is currently active/selected (shown with indicator).
    fn is_current(&self) -> bool {
        false
    }
}

/// Result of fuzzy matching a command.
#[derive(Debug, Clone)]
pub struct CommandMatch<C> {
    pub command: C,
    pub score: i64,
    pub label_indices: Vec<usize>,
}

/// Item types for palette rendering.
#[derive(Debug, Clone)]
pub enum PaletteItem<C> {
    /// A header/separator for grouping.
    Header(String),
    /// An empty line for spacing.
    Spacer,
    /// A loading indicator.
    Loading,
    /// A command with its match details.
    Command {
        command: C,
        is_highlighted: bool,
        label_indices: Vec<usize>,
    },
}

/// Generic command palette state.
#[derive(Debug)]
pub struct Palette<'a, C> {
    pub visible: bool,
    pub search_input: TextArea<'a>,
    pub selected_index: usize,
    pub scroll_offset: usize,
    filtered_commands: Vec<CommandMatch<C>>,
    all_commands: Vec<C>,
}

impl<C: PaletteCommand> Default for Palette<'_, C> {
    fn default() -> Self {
        Self::new(Vec::new())
    }
}

impl<'a, C: PaletteCommand> Palette<'a, C> {
    /// Create a new palette with the given commands.
    pub fn new(commands: Vec<C>) -> Self {
        let mut search_input = TextArea::default();
        search_input.set_placeholder_text("Type to search...");
        search_input.set_cursor_line_style(Style::default());

        let filtered_commands = commands
            .iter()
            .filter_map(|cmd| fuzzy_match(cmd, ""))
            .collect();

        Self {
            visible: false,
            search_input,
            selected_index: 0,
            scroll_offset: 0,
            filtered_commands,
            all_commands: commands,
        }
    }

    /// Update the available commands.
    pub fn set_commands(&mut self, commands: Vec<C>) {
        self.all_commands = commands;
        self.update_filtered_commands();
    }

    /// Open the palette.
    pub fn open(&mut self) {
        self.visible = true;
        self.search_input = TextArea::default();
        self.search_input.set_placeholder_text("Type to search...");
        self.search_input.set_cursor_line_style(Style::default());
        self.selected_index = 0;
        self.scroll_offset = 0;
        self.update_filtered_commands();
    }

    /// Close the palette.
    pub fn close(&mut self) {
        self.visible = false;
    }

    /// Get the current search query.
    pub fn search_query(&self) -> String {
        self.search_input.lines().join("")
    }

    /// Update the filtered list of commands based on search query.
    pub fn update_filtered_commands(&mut self) {
        let query = self.search_query();
        let mut matches: Vec<CommandMatch<C>> = self
            .all_commands
            .iter()
            .filter_map(|cmd| fuzzy_match(cmd, &query))
            .collect();

        if !query.trim().is_empty() {
            matches.sort_by(|a, b| {
                b.score
                    .cmp(&a.score)
                    .then_with(|| a.command.label().cmp(b.command.label()))
            });
        }

        self.filtered_commands = matches;

        // Reset selection if it's out of bounds
        if self.selected_index >= self.filtered_commands.len() {
            self.selected_index = 0;
        }
    }

    /// Handle text input.
    pub fn handle_input(&mut self, input: impl Into<tui_textarea::Input>) {
        let old_query = self.search_query();
        self.search_input.input(input);
        let new_query = self.search_query();

        if old_query != new_query {
            self.update_filtered_commands();
            self.selected_index = 0;
            self.scroll_offset = 0;
        }
    }

    /// Move selection up.
    pub fn select_up(&mut self) {
        if !self.filtered_commands.is_empty() {
            self.selected_index = if self.selected_index == 0 {
                self.filtered_commands.len() - 1
            } else {
                self.selected_index - 1
            };
        }
    }

    /// Move selection down.
    pub fn select_down(&mut self) {
        if !self.filtered_commands.is_empty() {
            self.selected_index = (self.selected_index + 1) % self.filtered_commands.len();
        }
    }

    /// Execute the selected command, returning it.
    pub fn execute_selection(&mut self) -> Option<C> {
        let cmd = self.filtered_commands.get(self.selected_index)?.command;
        self.close();
        Some(cmd)
    }

    /// Get the currently selected command without executing.
    pub fn selected_command(&self) -> Option<C> {
        self.filtered_commands
            .get(self.selected_index)
            .map(|m| m.command)
    }

    /// Get palette items grouped by category for rendering.
    /// Returns (items, selected_line_index).
    pub fn get_items(&self) -> (Vec<PaletteItem<C>>, Option<usize>) {
        let mut items = Vec::new();
        let mut current_category: Option<&str> = None;
        let mut selected_line_index = None;

        for (idx, matched) in self.filtered_commands.iter().enumerate() {
            let category = matched.command.category();

            // Add category header if it changed
            if category != current_category {
                if current_category.is_some() {
                    items.push(PaletteItem::Spacer);
                }
                if let Some(cat) = category {
                    items.push(PaletteItem::Header(cat.to_string()));
                }
                current_category = category;
            }

            // Track line index of selected item
            if idx == self.selected_index {
                selected_line_index = Some(items.len());
            }

            items.push(PaletteItem::Command {
                command: matched.command,
                is_highlighted: idx == self.selected_index,
                label_indices: matched.label_indices.clone(),
            });
        }

        (items, selected_line_index)
    }

    /// Update scroll offset to keep selected item visible.
    pub fn adjust_scroll(&mut self, selected_line: usize, visible_height: usize) {
        // If selected item is above the visible area, scroll up
        if selected_line < self.scroll_offset {
            self.scroll_offset = selected_line;
        }
        // If selected item is below the visible area, scroll down
        else if selected_line >= self.scroll_offset + visible_height {
            self.scroll_offset = selected_line - visible_height + 1;
        }
        // Otherwise, keep current scroll position
    }

    /// Get count of filtered commands.
    pub fn filtered_count(&self) -> usize {
        self.filtered_commands.len()
    }

    /// Get reference to filtered commands.
    pub fn filtered_commands(&self) -> &[CommandMatch<C>] {
        &self.filtered_commands
    }
}

/// Normalize whitespace: replace all whitespace variants with regular space
/// and collapse multiple spaces into one.
fn normalize_whitespace(s: &str) -> String {
    s.chars()
        .map(|c| if c.is_whitespace() { ' ' } else { c })
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

/// Check if a character is a word separator (space, hyphen, underscore, dot).
fn is_separator(c: char) -> bool {
    c.is_whitespace() || c == '-' || c == '_' || c == '.'
}

/// Simple fuzzy match of a query against a string label.
/// Returns true if the query fuzzy-matches the label.
/// This is useful for filtering items that don't implement PaletteCommand.
pub fn fuzzy_match_str(query: &str, label: &str) -> bool {
    // Reuse the core matching logic
    fuzzy_match_label(query, label).is_some()
}

/// Core fuzzy matching logic that works on raw strings.
/// Returns Some((score, indices)) if matched, None otherwise.
fn fuzzy_match_label(query: &str, label: &str) -> Option<(i64, Vec<usize>)> {
    // Normalize whitespace
    let query_normalized = normalize_whitespace(query);
    let label_normalized = normalize_whitespace(label);

    let query_lower = query_normalized.to_lowercase();
    let label_lower = label_normalized.to_lowercase();

    // 1. Substring match
    if label_lower.contains(&query_lower) {
        let indices: Vec<usize> = label.char_indices().map(|(idx, _)| idx).collect();
        return Some((1000 + query.len() as i64, indices));
    }

    // 2. Fuzzy subsequence match
    let mut score = 0i64;
    let mut indices = Vec::new();
    let mut query_chars = query_lower.chars().peekable();
    let mut last_match_pos: Option<usize> = None;
    let mut consecutive_matches = 0i64;

    for (idx, ch) in label.char_indices() {
        let ch_lower = ch.to_lowercase().next().unwrap_or(ch);

        if let Some(&q_char) = query_chars.peek() {
            let ch_is_sep = is_separator(ch_lower);
            let q_is_sep = is_separator(q_char);

            let matches = if ch_is_sep && q_is_sep {
                true
            } else if ch_is_sep {
                continue;
            } else if q_is_sep {
                if is_boundary(label, idx) {
                    query_chars.next();
                    continue;
                }
                false
            } else {
                ch_lower == q_char
            };

            if matches {
                indices.push(idx);
                query_chars.next();

                let mut char_score = 10i64;
                if is_boundary(label, idx) {
                    char_score += 10;
                }
                if let Some(last) = last_match_pos {
                    if idx == last + ch.len_utf8() {
                        consecutive_matches += 1;
                        char_score += 5 * consecutive_matches;
                    } else {
                        consecutive_matches = 0;
                        let gap = idx.saturating_sub(last + 1);
                        char_score -= (gap as i64).min(5);
                    }
                } else if idx == 0 {
                    char_score += 10;
                }
                score += char_score;
                last_match_pos = Some(idx);
            }
        }
    }

    if query_chars.peek().is_none() {
        Some((score, indices))
    } else {
        None
    }
}

/// Perform fuzzy matching of a command against a query.
pub fn fuzzy_match<C: PaletteCommand>(command: &C, query: &str) -> Option<CommandMatch<C>> {
    let label = command.label();

    // Normalize whitespace
    let query_normalized = normalize_whitespace(query);
    let label_normalized = normalize_whitespace(label);

    let query_lower = query_normalized.to_lowercase();
    let label_lower = label_normalized.to_lowercase();

    // Also search in description if available
    let desc_lower = command
        .description()
        .map(|d| normalize_whitespace(d).to_lowercase());

    // 1. Substring match
    if label_lower.contains(&query_lower)
        || desc_lower
            .as_ref()
            .is_some_and(|d| d.contains(&query_lower))
    {
        let indices: Vec<usize> = label.char_indices().map(|(idx, _)| idx).collect();
        return Some(CommandMatch {
            command: *command,
            score: 1000 + query.len() as i64,
            label_indices: indices,
        });
    }

    // 2. Fuzzy subsequence match
    // Treat all separators (space, hyphen, underscore, dot) as equivalent
    let mut score = 0i64;
    let mut indices = Vec::new();
    let mut query_chars = query_lower.chars().peekable();
    let mut last_match_pos: Option<usize> = None;
    let mut consecutive_matches = 0i64;

    for (idx, ch) in label.char_indices() {
        let ch_lower = ch.to_lowercase().next().unwrap_or(ch);

        if let Some(&q_char) = query_chars.peek() {
            // Normalize separators: treat space, hyphen, underscore, dot as equivalent
            let ch_is_sep = is_separator(ch_lower);
            let q_is_sep = is_separator(q_char);

            let matches = if ch_is_sep && q_is_sep {
                // Both are separators - they match
                true
            } else if ch_is_sep {
                // Label has separator but query doesn't - skip separator in label
                // (allows "codexmax" to match "codex-max")
                continue;
            } else if q_is_sep {
                // Query has separator but label char isn't - check if we're at a word boundary
                // If so, consume the query separator and continue looking for next query char
                if is_boundary(label, idx) {
                    query_chars.next();
                    // Don't add to indices - separator consumed, re-check this char
                    continue;
                }
                false
            } else {
                // Neither is a separator - direct char comparison
                ch_lower == q_char
            };

            if matches {
                indices.push(idx);
                query_chars.next();

                let mut char_score = 10i64;

                // Bonus for word boundary
                if is_boundary(label, idx) {
                    char_score += 10;
                }

                // Bonus for consecutive matches
                if let Some(last) = last_match_pos {
                    if idx == last + ch.len_utf8() {
                        consecutive_matches += 1;
                        char_score += 5 * consecutive_matches;
                    } else {
                        consecutive_matches = 0;
                        let gap = idx.saturating_sub(last + 1);
                        char_score -= (gap as i64).min(5);
                    }
                } else if idx == 0 {
                    char_score += 10;
                }

                score += char_score;
                last_match_pos = Some(idx);
            }
        }
    }

    if query_chars.peek().is_none() {
        Some(CommandMatch {
            command: *command,
            score,
            label_indices: indices,
        })
    } else {
        None
    }
}

fn is_boundary(text: &str, byte_idx: usize) -> bool {
    if byte_idx == 0 {
        return true;
    }
    let bytes = text.as_bytes();
    if byte_idx >= bytes.len() {
        return false;
    }
    let prev = bytes[byte_idx - 1];
    let curr = bytes[byte_idx];
    // Boundary if previous is space/punctuation or case change
    prev == b' '
        || prev == b'_'
        || prev == b'-'
        || (prev.is_ascii_lowercase() && curr.is_ascii_uppercase())
}

/// Configuration for rendering the palette.
#[derive(Debug, Clone)]
pub struct PaletteStyle {
    pub title: String,
    pub width: u16,
    pub max_height: u16,
    pub show_keybindings: bool,
    pub show_descriptions: bool,
    pub highlight_matches: bool,
}

impl Default for PaletteStyle {
    fn default() -> Self {
        Self {
            title: " Command Palette ".to_string(),
            width: 70,
            max_height: 20,
            show_keybindings: true,
            show_descriptions: true,
            highlight_matches: true,
        }
    }
}

/// Render the command palette overlay.
pub fn render_palette<C: PaletteCommand>(
    f: &mut Frame,
    palette: &mut Palette<'_, C>,
    style: &PaletteStyle,
) {
    let area = f.area();

    let palette_width = style.width.min(area.width.saturating_sub(4));
    let max_height = style.max_height.min(area.height.saturating_sub(4));
    let palette_height = (palette.filtered_count() as u16 + 6).min(max_height);

    let x = (area.width.saturating_sub(palette_width)) / 2;
    let y = area.height / 6;

    let palette_area = Rect::new(x, y, palette_width, palette_height);
    f.render_widget(Clear, palette_area);

    let block = Block::default()
        .title(style.title.as_str())
        .title_style(
            Style::default()
                .fg(Color::Cyan)
                .add_modifier(Modifier::BOLD),
        )
        .borders(Borders::ALL)
        .border_style(Style::default().fg(Color::Cyan));

    let inner_area = block.inner(palette_area);
    f.render_widget(block, palette_area);

    // Search input
    let search_area = Rect::new(inner_area.x, inner_area.y, inner_area.width, 1);
    let search_prefix = Paragraph::new(Span::styled(">", Style::default().fg(Color::Cyan)));
    f.render_widget(search_prefix, Rect::new(search_area.x, search_area.y, 2, 1));
    f.render_widget(
        &palette.search_input,
        Rect::new(search_area.x + 2, search_area.y, search_area.width - 2, 1),
    );

    // Items area
    let items_area = Rect::new(
        inner_area.x,
        inner_area.y + 2,
        inner_area.width,
        inner_area.height.saturating_sub(4),
    );

    let mut lines: Vec<Line<'_>> = Vec::new();
    let (items, selected_line_index) = palette.get_items();

    for item in items {
        match item {
            PaletteItem::Header(text) => {
                lines.push(Line::styled(
                    format!("─ {} ─", text),
                    Style::default()
                        .fg(Color::DarkGray)
                        .add_modifier(Modifier::BOLD),
                ));
            }
            PaletteItem::Spacer => {
                lines.push(Line::raw(""));
            }
            PaletteItem::Loading => {
                lines.push(Line::styled(
                    "    Loading...",
                    Style::default()
                        .fg(Color::Yellow)
                        .add_modifier(Modifier::ITALIC),
                ));
            }
            PaletteItem::Command {
                command,
                is_highlighted,
                label_indices,
            } => {
                // Extract all values from command first to avoid lifetime issues
                let label = command.label().to_string();
                let keybinding = if style.show_keybindings {
                    command.keybinding().unwrap_or("").to_string()
                } else {
                    String::new()
                };
                let is_current = command.is_current();

                let prefix = if is_highlighted { "▶ " } else { "  " };

                let base_style = if is_highlighted {
                    Style::default()
                        .fg(Color::Cyan)
                        .add_modifier(Modifier::BOLD)
                } else if is_current {
                    Style::default().fg(Color::Green)
                } else {
                    Style::default()
                };

                let kb_style = Style::default().fg(Color::Yellow);

                // Calculate padding for right-aligned keybinding
                let kb_width = keybinding.len();
                let current_indicator = if is_current { " ●" } else { "" };
                let label_width = items_area
                    .width
                    .saturating_sub(4)
                    .saturating_sub(kb_width as u16)
                    .saturating_sub(current_indicator.len() as u16)
                    as usize;

                let mut spans = vec![Span::styled(prefix, base_style)];

                if style.highlight_matches && !label_indices.is_empty() {
                    let mut label_spans =
                        highlighted_spans(&label, &label_indices, base_style, is_highlighted);
                    spans.append(&mut label_spans);
                } else {
                    spans.push(Span::styled(label.clone(), base_style));
                }

                if is_current {
                    spans.push(Span::styled(
                        current_indicator,
                        Style::default().fg(Color::Green),
                    ));
                }

                let label_len = label.chars().count() + current_indicator.len();
                let padding = label_width.saturating_sub(label_len);
                if padding > 0 {
                    spans.push(Span::styled(" ".repeat(padding), base_style));
                }

                if !keybinding.is_empty() {
                    spans.push(Span::styled(keybinding, kb_style));
                }

                lines.push(Line::from(spans));
            }
        }
    }

    if lines.is_empty() {
        lines.push(Line::styled(
            "  No matches",
            Style::default().fg(Color::DarkGray),
        ));
    }

    // Adjust scroll
    let visible_lines = items_area.height as usize;
    if let Some(selected_line) = selected_line_index {
        palette.adjust_scroll(selected_line, visible_lines);
    }

    let scroll_offset = palette.scroll_offset;
    let paragraph = Paragraph::new(lines).scroll((scroll_offset as u16, 0));
    f.render_widget(paragraph, items_area);

    // Help text
    let help_area = Rect::new(
        inner_area.x,
        inner_area.y + inner_area.height - 1,
        inner_area.width,
        1,
    );
    let help = Paragraph::new(Line::styled(
        "↑↓: navigate │ Enter: execute │ Esc: cancel",
        Style::default().fg(Color::DarkGray),
    ));
    f.render_widget(help, help_area);
}

/// Create highlighted spans for a label with matched indices.
fn highlighted_spans(
    text: &str,
    indices: &[usize],
    base_style: Style,
    is_selected: bool,
) -> Vec<Span<'static>> {
    let highlight_style = if is_selected {
        base_style.add_modifier(Modifier::UNDERLINED)
    } else {
        Style::default()
            .fg(Color::Yellow)
            .add_modifier(Modifier::BOLD)
    };

    let mut spans = Vec::new();
    let mut last_end = 0;

    let chars: Vec<(usize, char)> = text.char_indices().collect();
    let index_set: std::collections::HashSet<usize> = indices.iter().copied().collect();

    for (char_idx, (byte_idx, _ch)) in chars.iter().enumerate() {
        if index_set.contains(byte_idx) {
            // Add any preceding non-highlighted text
            if *byte_idx > last_end {
                spans.push(Span::styled(
                    text[last_end..*byte_idx].to_string(),
                    base_style,
                ));
            }
            // Add highlighted character
            let end = if char_idx + 1 < chars.len() {
                chars[char_idx + 1].0
            } else {
                text.len()
            };
            spans.push(Span::styled(
                text[*byte_idx..end].to_string(),
                highlight_style,
            ));
            last_end = end;
        }
    }

    // Add any remaining text
    if last_end < text.len() {
        spans.push(Span::styled(text[last_end..].to_string(), base_style));
    }

    if spans.is_empty() {
        spans.push(Span::styled(text.to_string(), base_style));
    }

    spans
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Debug, Clone, Copy, PartialEq)]
    enum TestCommand {
        Foo,
        Bar,
        FocusMainArea,
        GptCodexMax,
    }

    impl PaletteCommand for TestCommand {
        fn label(&self) -> &str {
            match self {
                TestCommand::Foo => "Foo Command",
                TestCommand::Bar => "Bar Command",
                TestCommand::FocusMainArea => "Focus Main Area",
                TestCommand::GptCodexMax => "gpt-5.1-codex-max",
            }
        }

        fn category(&self) -> Option<&str> {
            Some("Test")
        }
    }

    #[test]
    fn fuzzy_match_works() {
        let cmd = TestCommand::FocusMainArea;
        assert!(fuzzy_match(&cmd, "").is_some());
        assert!(fuzzy_match(&cmd, "focus").is_some());
        assert!(fuzzy_match(&cmd, "fma").is_some());
        assert!(fuzzy_match(&cmd, "Focus Main Area").is_some());
        assert!(fuzzy_match(&cmd, "focusmainarea").is_some());
        assert!(fuzzy_match(&cmd, "xyz").is_none());
    }

    #[test]
    fn fuzzy_match_handles_hyphens() {
        let cmd = TestCommand::GptCodexMax;
        // "gpt-5.1-codex-max" should match various patterns
        assert!(fuzzy_match(&cmd, "").is_some());
        assert!(fuzzy_match(&cmd, "codex").is_some());
        assert!(
            fuzzy_match(&cmd, "codex max").is_some(),
            "space should match hyphen"
        );
        assert!(
            fuzzy_match(&cmd, "codex-max").is_some(),
            "hyphen should match hyphen"
        );
        assert!(
            fuzzy_match(&cmd, "codexmax").is_some(),
            "no separator should skip hyphens"
        );
        assert!(
            fuzzy_match(&cmd, "gpt codex").is_some(),
            "space should match across hyphens"
        );
        assert!(fuzzy_match(&cmd, "gpt-codex").is_some());
        assert!(fuzzy_match(&cmd, "5.1").is_some());
        assert!(fuzzy_match(&cmd, "gcm").is_some(), "first letters of words");
    }

    #[test]
    fn palette_filtering_works() {
        let mut palette = Palette::new(vec![
            TestCommand::Foo,
            TestCommand::Bar,
            TestCommand::FocusMainArea,
        ]);
        palette.open();

        assert_eq!(palette.filtered_count(), 3);

        use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
        palette.handle_input(KeyEvent::new(KeyCode::Char('f'), KeyModifiers::NONE));
        assert!(palette.filtered_count() >= 1);
    }

    #[test]
    fn palette_navigation_works() {
        let mut palette = Palette::new(vec![TestCommand::Foo, TestCommand::Bar]);
        palette.open();

        assert_eq!(palette.selected_index, 0);
        palette.select_down();
        assert_eq!(palette.selected_index, 1);
        palette.select_down();
        assert_eq!(palette.selected_index, 0); // Wraps
        palette.select_up();
        assert_eq!(palette.selected_index, 1); // Wraps back
    }
}
