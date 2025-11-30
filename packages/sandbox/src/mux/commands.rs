use crossterm::event::{KeyCode, KeyModifiers};

use crate::palette::PaletteCommand;

/// A command that can be executed in the multiplexer.
/// Each command has an associated keyboard shortcut.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MuxCommand {
    // Navigation
    FocusLeft,
    FocusRight,
    FocusUp,
    FocusDown,
    FocusSidebar,
    FocusMainArea,
    NextPane,
    PrevPane,
    NextTab,
    PrevTab,
    GoToTab1,
    GoToTab2,
    GoToTab3,
    GoToTab4,
    GoToTab5,
    GoToTab6,
    GoToTab7,
    GoToTab8,
    GoToTab9,

    // Pane management
    SplitHorizontal,
    SplitVertical,
    ClosePane,
    ToggleZoom,
    SwapPaneLeft,
    SwapPaneRight,
    SwapPaneUp,
    SwapPaneDown,
    ResizeLeft,
    ResizeRight,
    ResizeUp,
    ResizeDown,

    // Tab management
    NewTab,
    CloseTab,
    RenameTab,
    MoveTabLeft,
    MoveTabRight,

    // Sidebar
    ToggleSidebar,
    SelectSandbox,
    NextSandbox,
    PrevSandbox,

    // Sandbox management
    NewSandbox,
    DeleteSandbox,
    RefreshSandboxes,

    // Session management
    NewSession,
    AttachSandbox,
    DetachSandbox,

    // UI
    OpenCommandPalette,
    ToggleHelp,
    ShowNotifications,
    Quit,
    ScrollUp,
    ScrollDown,
    ScrollPageUp,
    ScrollPageDown,
    ScrollToTop,
    ScrollToBottom,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommandMatch {
    pub command: MuxCommand,
    pub score: i64,
    pub label_indices: Vec<usize>,
}

impl MuxCommand {
    /// Returns all available commands.
    pub fn all() -> &'static [MuxCommand] {
        &[
            // Navigation
            MuxCommand::FocusLeft,
            MuxCommand::FocusRight,
            MuxCommand::FocusUp,
            MuxCommand::FocusDown,
            MuxCommand::FocusSidebar,
            MuxCommand::FocusMainArea,
            MuxCommand::NextPane,
            MuxCommand::PrevPane,
            MuxCommand::NextTab,
            MuxCommand::PrevTab,
            MuxCommand::GoToTab1,
            MuxCommand::GoToTab2,
            MuxCommand::GoToTab3,
            MuxCommand::GoToTab4,
            MuxCommand::GoToTab5,
            MuxCommand::GoToTab6,
            MuxCommand::GoToTab7,
            MuxCommand::GoToTab8,
            MuxCommand::GoToTab9,
            // Pane management
            MuxCommand::SplitHorizontal,
            MuxCommand::SplitVertical,
            MuxCommand::ClosePane,
            MuxCommand::ToggleZoom,
            MuxCommand::SwapPaneLeft,
            MuxCommand::SwapPaneRight,
            MuxCommand::SwapPaneUp,
            MuxCommand::SwapPaneDown,
            MuxCommand::ResizeLeft,
            MuxCommand::ResizeRight,
            MuxCommand::ResizeUp,
            MuxCommand::ResizeDown,
            // Tab management
            MuxCommand::NewTab,
            MuxCommand::CloseTab,
            MuxCommand::RenameTab,
            MuxCommand::MoveTabLeft,
            MuxCommand::MoveTabRight,
            // Sidebar
            MuxCommand::ToggleSidebar,
            MuxCommand::SelectSandbox,
            MuxCommand::NextSandbox,
            MuxCommand::PrevSandbox,
            // Sandbox management
            MuxCommand::NewSandbox,
            MuxCommand::DeleteSandbox,
            MuxCommand::RefreshSandboxes,
            // Session management
            MuxCommand::NewSession,
            MuxCommand::AttachSandbox,
            MuxCommand::DetachSandbox,
            // UI
            MuxCommand::OpenCommandPalette,
            MuxCommand::ToggleHelp,
            MuxCommand::ShowNotifications,
            MuxCommand::Quit,
            MuxCommand::ScrollUp,
            MuxCommand::ScrollDown,
            MuxCommand::ScrollPageUp,
            MuxCommand::ScrollPageDown,
            MuxCommand::ScrollToTop,
            MuxCommand::ScrollToBottom,
        ]
    }

    /// Returns the display label for the command.
    pub fn label(&self) -> &'static str {
        match self {
            MuxCommand::FocusLeft => "Focus Left",
            MuxCommand::FocusRight => "Focus Right",
            MuxCommand::FocusUp => "Focus Up",
            MuxCommand::FocusDown => "Focus Down",
            MuxCommand::FocusSidebar => "Focus Sidebar",
            MuxCommand::FocusMainArea => "Focus Main Area",
            MuxCommand::NextPane => "Next Pane",
            MuxCommand::PrevPane => "Previous Pane",
            MuxCommand::NextTab => "Next Tab",
            MuxCommand::PrevTab => "Previous Tab",
            MuxCommand::GoToTab1 => "Go to Tab 1",
            MuxCommand::GoToTab2 => "Go to Tab 2",
            MuxCommand::GoToTab3 => "Go to Tab 3",
            MuxCommand::GoToTab4 => "Go to Tab 4",
            MuxCommand::GoToTab5 => "Go to Tab 5",
            MuxCommand::GoToTab6 => "Go to Tab 6",
            MuxCommand::GoToTab7 => "Go to Tab 7",
            MuxCommand::GoToTab8 => "Go to Tab 8",
            MuxCommand::GoToTab9 => "Go to Tab 9",
            MuxCommand::SplitHorizontal => "Split Horizontal",
            MuxCommand::SplitVertical => "Split Vertical",
            MuxCommand::ClosePane => "Close Pane",
            MuxCommand::ToggleZoom => "Toggle Zoom",
            MuxCommand::SwapPaneLeft => "Swap Pane Left",
            MuxCommand::SwapPaneRight => "Swap Pane Right",
            MuxCommand::SwapPaneUp => "Swap Pane Up",
            MuxCommand::SwapPaneDown => "Swap Pane Down",
            MuxCommand::ResizeLeft => "Resize Left",
            MuxCommand::ResizeRight => "Resize Right",
            MuxCommand::ResizeUp => "Resize Up",
            MuxCommand::ResizeDown => "Resize Down",
            MuxCommand::NewTab => "New Tab",
            MuxCommand::CloseTab => "Close Tab",
            MuxCommand::RenameTab => "Rename Tab",
            MuxCommand::MoveTabLeft => "Move Tab Left",
            MuxCommand::MoveTabRight => "Move Tab Right",
            MuxCommand::ToggleSidebar => "Toggle Sidebar",
            MuxCommand::SelectSandbox => "Select Sandbox",
            MuxCommand::NextSandbox => "Next Sandbox",
            MuxCommand::PrevSandbox => "Previous Sandbox",
            MuxCommand::NewSandbox => "New Sandbox",
            MuxCommand::DeleteSandbox => "Delete Sandbox",
            MuxCommand::RefreshSandboxes => "Refresh Sandboxes",
            MuxCommand::NewSession => "New Session",
            MuxCommand::AttachSandbox => "Attach to Sandbox",
            MuxCommand::DetachSandbox => "Detach from Sandbox",
            MuxCommand::OpenCommandPalette => "Command Palette",
            MuxCommand::ToggleHelp => "Toggle Help",
            MuxCommand::ShowNotifications => "Show Notifications",
            MuxCommand::Quit => "Quit",
            MuxCommand::ScrollUp => "Scroll Up",
            MuxCommand::ScrollDown => "Scroll Down",
            MuxCommand::ScrollPageUp => "Scroll Page Up",
            MuxCommand::ScrollPageDown => "Scroll Page Down",
            MuxCommand::ScrollToTop => "Scroll to Top",
            MuxCommand::ScrollToBottom => "Scroll to Bottom",
        }
    }

    /// Returns a description of what the command does.
    pub fn description(&self) -> &'static str {
        match self {
            MuxCommand::FocusLeft => "Move focus to the pane on the left",
            MuxCommand::FocusRight => "Move focus to the pane on the right",
            MuxCommand::FocusUp => "Move focus to the pane above",
            MuxCommand::FocusDown => "Move focus to the pane below",
            MuxCommand::FocusSidebar => "Move focus to the sidebar",
            MuxCommand::FocusMainArea => "Move focus to the main workspace",
            MuxCommand::NextPane => "Cycle focus to the next pane",
            MuxCommand::PrevPane => "Cycle focus to the previous pane",
            MuxCommand::NextTab => "Switch to the next tab",
            MuxCommand::PrevTab => "Switch to the previous tab",
            MuxCommand::GoToTab1 => "Switch to tab 1",
            MuxCommand::GoToTab2 => "Switch to tab 2",
            MuxCommand::GoToTab3 => "Switch to tab 3",
            MuxCommand::GoToTab4 => "Switch to tab 4",
            MuxCommand::GoToTab5 => "Switch to tab 5",
            MuxCommand::GoToTab6 => "Switch to tab 6",
            MuxCommand::GoToTab7 => "Switch to tab 7",
            MuxCommand::GoToTab8 => "Switch to tab 8",
            MuxCommand::GoToTab9 => "Switch to tab 9",
            MuxCommand::SplitHorizontal => "Split the current pane horizontally",
            MuxCommand::SplitVertical => "Split the current pane vertically",
            MuxCommand::ClosePane => "Close the current pane",
            MuxCommand::ToggleZoom => "Toggle zoom on the current pane",
            MuxCommand::SwapPaneLeft => "Swap current pane with the one on the left",
            MuxCommand::SwapPaneRight => "Swap current pane with the one on the right",
            MuxCommand::SwapPaneUp => "Swap current pane with the one above",
            MuxCommand::SwapPaneDown => "Swap current pane with the one below",
            MuxCommand::ResizeLeft => "Resize pane to the left",
            MuxCommand::ResizeRight => "Resize pane to the right",
            MuxCommand::ResizeUp => "Resize pane upward",
            MuxCommand::ResizeDown => "Resize pane downward",
            MuxCommand::NewTab => "Create a new tab",
            MuxCommand::CloseTab => "Close the current tab",
            MuxCommand::RenameTab => "Rename the current tab",
            MuxCommand::MoveTabLeft => "Move current tab to the left",
            MuxCommand::MoveTabRight => "Move current tab to the right",
            MuxCommand::ToggleSidebar => "Toggle focus between sidebar and main workspace",
            MuxCommand::SelectSandbox => "Select a sandbox from the list",
            MuxCommand::NextSandbox => "Switch to the next sandbox workspace",
            MuxCommand::PrevSandbox => "Switch to the previous sandbox workspace",
            MuxCommand::NewSandbox => "Create a new sandbox",
            MuxCommand::DeleteSandbox => "Delete the selected sandbox",
            MuxCommand::RefreshSandboxes => "Refresh the sandbox list",
            MuxCommand::NewSession => "Create a new sandbox session",
            MuxCommand::AttachSandbox => "Attach to an existing sandbox",
            MuxCommand::DetachSandbox => "Detach from the current sandbox",
            MuxCommand::OpenCommandPalette => "Open the command palette",
            MuxCommand::ToggleHelp => "Show or hide help overlay",
            MuxCommand::ShowNotifications => "Show notifications panel",
            MuxCommand::Quit => "Exit the multiplexer",
            MuxCommand::ScrollUp => "Scroll up one line",
            MuxCommand::ScrollDown => "Scroll down one line",
            MuxCommand::ScrollPageUp => "Scroll up one page",
            MuxCommand::ScrollPageDown => "Scroll down one page",
            MuxCommand::ScrollToTop => "Scroll to the top",
            MuxCommand::ScrollToBottom => "Scroll to the bottom",
        }
    }

    /// Returns the category for grouping in the palette.
    pub fn category(&self) -> &'static str {
        match self {
            MuxCommand::FocusLeft
            | MuxCommand::FocusRight
            | MuxCommand::FocusUp
            | MuxCommand::FocusDown
            | MuxCommand::FocusSidebar
            | MuxCommand::FocusMainArea
            | MuxCommand::NextPane
            | MuxCommand::PrevPane
            | MuxCommand::NextTab
            | MuxCommand::PrevTab
            | MuxCommand::GoToTab1
            | MuxCommand::GoToTab2
            | MuxCommand::GoToTab3
            | MuxCommand::GoToTab4
            | MuxCommand::GoToTab5
            | MuxCommand::GoToTab6
            | MuxCommand::GoToTab7
            | MuxCommand::GoToTab8
            | MuxCommand::GoToTab9 => "Navigation",

            MuxCommand::SplitHorizontal
            | MuxCommand::SplitVertical
            | MuxCommand::ClosePane
            | MuxCommand::ToggleZoom
            | MuxCommand::SwapPaneLeft
            | MuxCommand::SwapPaneRight
            | MuxCommand::SwapPaneUp
            | MuxCommand::SwapPaneDown
            | MuxCommand::ResizeLeft
            | MuxCommand::ResizeRight
            | MuxCommand::ResizeUp
            | MuxCommand::ResizeDown => "Panes",

            MuxCommand::NewTab
            | MuxCommand::CloseTab
            | MuxCommand::RenameTab
            | MuxCommand::MoveTabLeft
            | MuxCommand::MoveTabRight => "Tabs",

            MuxCommand::ToggleSidebar
            | MuxCommand::SelectSandbox
            | MuxCommand::NextSandbox
            | MuxCommand::PrevSandbox => "Sidebar",

            MuxCommand::NewSandbox | MuxCommand::DeleteSandbox | MuxCommand::RefreshSandboxes => {
                "Sandbox"
            }

            MuxCommand::NewSession | MuxCommand::AttachSandbox | MuxCommand::DetachSandbox => {
                "Session"
            }

            MuxCommand::OpenCommandPalette
            | MuxCommand::ToggleHelp
            | MuxCommand::ShowNotifications
            | MuxCommand::Quit
            | MuxCommand::ScrollUp
            | MuxCommand::ScrollDown
            | MuxCommand::ScrollPageUp
            | MuxCommand::ScrollPageDown
            | MuxCommand::ScrollToTop
            | MuxCommand::ScrollToBottom => "General",
        }
    }

    /// Returns the default keybinding for this command.
    /// Returns (modifiers, keycode).
    ///
    /// IMPORTANT: Avoid Ctrl+<letter> shortcuts as they conflict with terminal/readline:
    /// - Ctrl+A/E: go to beginning/end of line
    /// - Ctrl+B/F: move backward/forward one char
    /// - Ctrl+D: EOF/delete char
    /// - Ctrl+K/U: kill to end/beginning of line
    /// - Ctrl+N/P: next/previous history
    /// - Ctrl+R: reverse search
    /// - Ctrl+W: delete word backward
    /// - Ctrl+C: interrupt
    /// - Ctrl+Z: suspend
    ///
    /// Use Alt+<key> shortcuts instead, which don't conflict with terminal input.
    pub fn keybinding(&self) -> Option<(KeyModifiers, KeyCode)> {
        match self {
            // Navigation - use Alt+arrows for pane movement (like zellij)
            MuxCommand::FocusLeft => Some((KeyModifiers::ALT, KeyCode::Left)),
            MuxCommand::FocusRight => Some((KeyModifiers::ALT, KeyCode::Right)),
            MuxCommand::FocusUp => Some((KeyModifiers::ALT, KeyCode::Up)),
            MuxCommand::FocusDown => Some((KeyModifiers::ALT, KeyCode::Down)),
            // Focus commands are available via the palette; Ctrl+S handled by ToggleSidebar
            MuxCommand::FocusSidebar => None,
            MuxCommand::FocusMainArea => None,
            MuxCommand::NextPane => Some((KeyModifiers::ALT, KeyCode::Char('o'))), // like tmux
            MuxCommand::PrevPane => {
                Some((KeyModifiers::ALT | KeyModifiers::SHIFT, KeyCode::Char('o')))
            }
            MuxCommand::NextTab => Some((KeyModifiers::ALT, KeyCode::Char(']'))),
            MuxCommand::PrevTab => Some((KeyModifiers::ALT, KeyCode::Char('['))),

            // Tab shortcuts with Alt+number
            MuxCommand::GoToTab1 => Some((KeyModifiers::ALT, KeyCode::Char('1'))),
            MuxCommand::GoToTab2 => Some((KeyModifiers::ALT, KeyCode::Char('2'))),
            MuxCommand::GoToTab3 => Some((KeyModifiers::ALT, KeyCode::Char('3'))),
            MuxCommand::GoToTab4 => Some((KeyModifiers::ALT, KeyCode::Char('4'))),
            MuxCommand::GoToTab5 => Some((KeyModifiers::ALT, KeyCode::Char('5'))),
            MuxCommand::GoToTab6 => Some((KeyModifiers::ALT, KeyCode::Char('6'))),
            MuxCommand::GoToTab7 => Some((KeyModifiers::ALT, KeyCode::Char('7'))),
            MuxCommand::GoToTab8 => Some((KeyModifiers::ALT, KeyCode::Char('8'))),
            MuxCommand::GoToTab9 => Some((KeyModifiers::ALT, KeyCode::Char('9'))),

            // Pane management - use Alt for pane operations
            MuxCommand::SplitHorizontal => Some((KeyModifiers::ALT, KeyCode::Char('-'))),
            MuxCommand::SplitVertical => Some((KeyModifiers::ALT, KeyCode::Char('\\'))),
            MuxCommand::ClosePane => Some((KeyModifiers::ALT, KeyCode::Char('x'))),
            MuxCommand::ToggleZoom => Some((KeyModifiers::ALT, KeyCode::Char('z'))),

            // Swap panes
            MuxCommand::SwapPaneLeft => {
                Some((KeyModifiers::ALT | KeyModifiers::SHIFT, KeyCode::Left))
            }
            MuxCommand::SwapPaneRight => {
                Some((KeyModifiers::ALT | KeyModifiers::SHIFT, KeyCode::Right))
            }
            MuxCommand::SwapPaneUp => Some((KeyModifiers::ALT | KeyModifiers::SHIFT, KeyCode::Up)),
            MuxCommand::SwapPaneDown => {
                Some((KeyModifiers::ALT | KeyModifiers::SHIFT, KeyCode::Down))
            }

            // Resize - Ctrl+Alt+arrows (these don't conflict with readline)
            MuxCommand::ResizeLeft => {
                Some((KeyModifiers::CONTROL | KeyModifiers::ALT, KeyCode::Left))
            }
            MuxCommand::ResizeRight => {
                Some((KeyModifiers::CONTROL | KeyModifiers::ALT, KeyCode::Right))
            }
            MuxCommand::ResizeUp => Some((KeyModifiers::CONTROL | KeyModifiers::ALT, KeyCode::Up)),
            MuxCommand::ResizeDown => {
                Some((KeyModifiers::CONTROL | KeyModifiers::ALT, KeyCode::Down))
            }

            // Tab management - all Alt-based
            MuxCommand::NewTab => Some((KeyModifiers::ALT, KeyCode::Char('t'))),
            MuxCommand::CloseTab => Some((KeyModifiers::ALT, KeyCode::Char('w'))),
            MuxCommand::RenameTab => Some((KeyModifiers::ALT, KeyCode::Char('r'))),
            MuxCommand::MoveTabLeft => {
                Some((KeyModifiers::ALT | KeyModifiers::SHIFT, KeyCode::Char('[')))
            }
            MuxCommand::MoveTabRight => {
                Some((KeyModifiers::ALT | KeyModifiers::SHIFT, KeyCode::Char(']')))
            }

            // Sidebar - Alt+S toggles focus between sidebar and main area
            MuxCommand::ToggleSidebar => Some((KeyModifiers::ALT, KeyCode::Char('s'))),
            // SelectSandbox has no global keybinding - Enter is handled contextually in sidebar focus
            MuxCommand::SelectSandbox => None,
            // Alt+Shift+{ and Alt+Shift+} for sandbox switching (accepts Alt+{ / Alt+} too)
            MuxCommand::NextSandbox => Some((KeyModifiers::ALT, KeyCode::Char('}'))),
            MuxCommand::PrevSandbox => Some((KeyModifiers::ALT, KeyCode::Char('{'))),

            // Sandbox management - use Alt
            MuxCommand::NewSandbox => Some((KeyModifiers::ALT, KeyCode::Char('n'))),
            MuxCommand::DeleteSandbox => None, // No default keybinding, access via command palette
            MuxCommand::RefreshSandboxes => Some((KeyModifiers::ALT, KeyCode::Char('R'))), // Alt+Shift+R

            // Session - use Alt
            MuxCommand::NewSession => None, // Access via command palette
            MuxCommand::AttachSandbox => None, // Access via command palette
            MuxCommand::DetachSandbox => None, // Access via command palette

            // UI - Ctrl+Q for quit is safe, use Alt for others
            MuxCommand::OpenCommandPalette => Some((KeyModifiers::ALT, KeyCode::Char('p'))),
            MuxCommand::ToggleHelp => Some((KeyModifiers::ALT, KeyCode::Char('?'))),
            MuxCommand::ShowNotifications => {
                Some((KeyModifiers::ALT | KeyModifiers::SHIFT, KeyCode::Char('n')))
            }
            MuxCommand::Quit => Some((KeyModifiers::CONTROL, KeyCode::Char('q'))),
            // Scroll - only when NOT focused on terminal (handled separately)
            MuxCommand::ScrollUp => None,
            MuxCommand::ScrollDown => None,
            MuxCommand::ScrollPageUp => Some((KeyModifiers::ALT, KeyCode::PageUp)),
            MuxCommand::ScrollPageDown => Some((KeyModifiers::ALT, KeyCode::PageDown)),
            MuxCommand::ScrollToTop => Some((KeyModifiers::ALT, KeyCode::Home)),
            MuxCommand::ScrollToBottom => Some((KeyModifiers::ALT, KeyCode::End)),
        }
    }

    /// Returns a human-readable string for the keybinding.
    pub fn keybinding_str(&self) -> String {
        match self.keybinding() {
            Some((modifiers, keycode)) => format_keybinding(modifiers, keycode),
            None => String::new(),
        }
    }

    /// Check if this command matches a query string (for filtering in palette).
    pub fn matches(&self, query: &str) -> bool {
        self.fuzzy_match(query).is_some()
    }

    pub(crate) fn fuzzy_match(&self, query: &str) -> Option<CommandMatch> {
        let trimmed = query.trim();

        if trimmed.is_empty() {
            return Some(CommandMatch {
                command: *self,
                score: 0,
                label_indices: Vec::new(),
            });
        }

        let label_match = smart_match(trimmed, self.label());
        let description_match = smart_match(trimmed, self.description());
        let category_match = smart_match(trimmed, self.category());

        let mut best_score: Option<i64> = None;

        if let Some(m) = &label_match {
            best_score = Some(m.score + 200);
        }

        if let Some(m) = description_match {
            let weighted = m.score + 100;
            if best_score.is_none_or(|s| weighted > s) {
                best_score = Some(weighted);
            }
        }

        if let Some(m) = category_match {
            let weighted = m.score + 50;
            if best_score.is_none_or(|s| weighted > s) {
                best_score = Some(weighted);
            }
        }

        let score = best_score?;
        let label_indices = label_match.map(|m| m.indices).unwrap_or_default();

        Some(CommandMatch {
            command: *self,
            score,
            label_indices,
        })
    }

    /// Try to match a key event to a command.
    pub fn from_key(modifiers: KeyModifiers, keycode: KeyCode) -> Option<MuxCommand> {
        // Be lenient for braces: macOS reports Option+Shift+[{ as Alt with '{'/' }'
        // but Shift may or may not be present in modifiers, so accept any Alt+{ or Alt+}.
        if modifiers.contains(KeyModifiers::ALT) {
            if keycode == KeyCode::Char('{') {
                return Some(MuxCommand::PrevSandbox);
            }
            if keycode == KeyCode::Char('}') {
                return Some(MuxCommand::NextSandbox);
            }
        }

        for cmd in Self::all() {
            if let Some((m, k)) = cmd.keybinding() {
                if m == modifiers && k == keycode {
                    return Some(*cmd);
                }
            }
        }
        None
    }
}

/// Implement the shared palette command trait for MuxCommand.
impl PaletteCommand for MuxCommand {
    fn label(&self) -> &str {
        MuxCommand::label(self)
    }

    fn description(&self) -> Option<&str> {
        Some(MuxCommand::description(self))
    }

    fn category(&self) -> Option<&str> {
        Some(MuxCommand::category(self))
    }

    fn keybinding(&self) -> Option<&str> {
        // We store keybinding as a computed string, but trait expects &str
        // Since the method returns String, we can't return a reference.
        // Return None for now - keybinding is handled via keybinding_str()
        None
    }

    fn is_current(&self) -> bool {
        false
    }
}

/// Format a keybinding as a human-readable string.
fn format_keybinding(modifiers: KeyModifiers, keycode: KeyCode) -> String {
    let mut parts = Vec::new();

    if modifiers.contains(KeyModifiers::CONTROL) {
        parts.push("Ctrl");
    }
    if modifiers.contains(KeyModifiers::ALT) {
        parts.push("Alt");
    }
    if modifiers.contains(KeyModifiers::SHIFT) {
        parts.push("Shift");
    }
    if modifiers.contains(KeyModifiers::SUPER) {
        parts.push("Super");
    }

    let key_str = match keycode {
        KeyCode::Char(c) => {
            if c == ' ' {
                "Space".to_string()
            } else {
                c.to_uppercase().to_string()
            }
        }
        KeyCode::Enter => "Enter".to_string(),
        KeyCode::Esc => "Esc".to_string(),
        KeyCode::Backspace => "Backspace".to_string(),
        KeyCode::Tab => "Tab".to_string(),
        KeyCode::Delete => "Del".to_string(),
        KeyCode::Insert => "Ins".to_string(),
        KeyCode::Home => "Home".to_string(),
        KeyCode::End => "End".to_string(),
        KeyCode::PageUp => "PgUp".to_string(),
        KeyCode::PageDown => "PgDn".to_string(),
        KeyCode::Up => "↑".to_string(),
        KeyCode::Down => "↓".to_string(),
        KeyCode::Left => "←".to_string(),
        KeyCode::Right => "→".to_string(),
        KeyCode::F(n) => format!("F{}", n),
        _ => "?".to_string(),
    };
    parts.push(&key_str);

    parts.join("+")
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct FuzzyMatch {
    score: i64,
    indices: Vec<usize>,
}

/// Normalize whitespace in a string: replace all whitespace variants with regular space
/// and collapse multiple spaces into one.
fn normalize_whitespace(s: &str) -> String {
    s.chars()
        .map(|c| if c.is_whitespace() { ' ' } else { c })
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

fn smart_match(query: &str, candidate: &str) -> Option<FuzzyMatch> {
    // Normalize whitespace (handles non-breaking spaces, tabs, etc.)
    let query_normalized = normalize_whitespace(query);
    let candidate_normalized = normalize_whitespace(candidate);

    // Case-insensitive comparison
    let query_lower = query_normalized.to_lowercase();
    let candidate_lower = candidate_normalized.to_lowercase();

    // 1. Substring Match (on normalized strings)
    if candidate_lower.contains(&query_lower) {
        // For substring match, highlight all characters in the candidate
        // since we're matching the full normalized query
        let indices: Vec<usize> = candidate.char_indices().map(|(idx, _)| idx).collect();

        return Some(FuzzyMatch {
            score: 1000 + query.len() as i64, // Prefer longer matches
            indices,
        });
    }

    // 2. Fuzzy Match (Subsequence) on normalized strings
    // Match query chars against candidate chars, treating all whitespace as equivalent
    let mut score = 0;
    let mut indices = Vec::new();
    let mut query_chars = query_lower.chars().peekable();
    let mut last_match_pos: Option<usize> = None;
    let mut consecutive_matches = 0;

    for (idx, ch) in candidate.char_indices() {
        // Normalize the character for comparison
        let ch_lower = ch.to_lowercase().next().unwrap_or(ch);
        let ch_normalized = if ch_lower.is_whitespace() {
            ' '
        } else {
            ch_lower
        };

        if let Some(&q_char) = query_chars.peek() {
            // Also normalize the query char for comparison
            let q_normalized = if q_char.is_whitespace() { ' ' } else { q_char };

            if ch_normalized == q_normalized {
                // Match found
                indices.push(idx);
                query_chars.next(); // Advance query

                // Scoring
                let mut char_score = 10;

                // Bonus for start of word (boundary)
                if is_boundary(candidate, idx) {
                    char_score += 10;
                }

                // Bonus for consecutive matches
                if let Some(last) = last_match_pos {
                    if idx == last + ch.len_utf8() {
                        consecutive_matches += 1;
                        char_score += 5 * consecutive_matches; // Growing bonus
                    } else {
                        consecutive_matches = 0;
                        // Penalty for gaps
                        let gap = idx.saturating_sub(last + 1);
                        char_score -= (gap as i64).min(5);
                    }
                } else {
                    // First match
                    if idx == 0 {
                        char_score += 10; // Bonus for matching start of string
                    }
                }

                score += char_score;
                last_match_pos = Some(idx);
            }
        }
    }

    if query_chars.peek().is_none() {
        // All query chars matched
        Some(FuzzyMatch { score, indices })
    } else {
        None
    }
}

fn is_boundary(text: &str, byte_idx: usize) -> bool {
    if byte_idx == 0 {
        return true;
    }

    let mut chars_before = text[..byte_idx].chars();
    let mut chars_after = text[byte_idx..].chars();

    let prev = chars_before.next_back();
    let current = chars_after.next();

    if let Some(prev_char) = prev {
        if prev_char.is_whitespace() || prev_char == '-' || prev_char == '_' || prev_char == '/' {
            return true;
        }

        if let Some(curr_char) = current {
            if prev_char.is_lowercase() && curr_char.is_uppercase() {
                return true;
            }
        }
    }

    false
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn all_commands_have_labels() {
        for cmd in MuxCommand::all() {
            assert!(!cmd.label().is_empty());
        }
    }

    #[test]
    fn all_commands_have_descriptions() {
        for cmd in MuxCommand::all() {
            assert!(!cmd.description().is_empty());
        }
    }

    #[test]
    fn all_commands_have_categories() {
        for cmd in MuxCommand::all() {
            assert!(!cmd.category().is_empty());
        }
    }

    #[test]
    fn command_matching_works() {
        assert!(MuxCommand::SplitHorizontal.matches("split"));
        assert!(MuxCommand::SplitHorizontal.matches("splt"));
        assert!(MuxCommand::SplitHorizontal.matches("horizontal"));
        assert!(MuxCommand::SplitHorizontal.matches("pane"));
        assert!(!MuxCommand::SplitHorizontal.matches("xyz"));
    }

    #[test]
    fn fuzzy_matching_provides_indices() {
        let result = MuxCommand::SplitHorizontal
            .fuzzy_match("splith")
            .expect("should match fuzzily");
        assert_eq!(result.label_indices.len(), 6);
    }

    #[test]
    fn fuzzy_matching_handles_spaces_and_stuttered_terms() {
        let result = MuxCommand::FocusMainArea.fuzzy_match("fmain ar");
        assert!(result.is_some());
    }

    #[test]
    fn fuzzy_matching_handles_full_phrase() {
        let result = MuxCommand::FocusMainArea.fuzzy_match("Focus Main Area");
        assert!(result.is_some());
    }

    #[test]
    fn fuzzy_matching_various_patterns() {
        // These should all match "Focus Main Area"
        let patterns_that_should_match = [
            "fma",                           // First letters of each word
            "FMA",                           // Uppercase first letters
            "Focus Main Area",               // Exact match
            "focus main area",               // Lowercase exact
            "fmainarea",                     // First letter + rest concatenated
            "focusmainarea",                 // All words concatenated (no spaces)
            "focus",                         // Just first word
            "main area",                     // Substring
            "foc main",                      // Partial first word + second word
            "Focus\u{00A0}Main\u{00A0}Area", // Non-breaking spaces (pasted from web)
        ];

        for pattern in patterns_that_should_match {
            let result = MuxCommand::FocusMainArea.fuzzy_match(pattern);
            assert!(
                result.is_some(),
                "Pattern '{}' should match 'Focus Main Area'",
                pattern
            );
        }
    }

    #[test]
    fn keybinding_lookup_works() {
        // Alt+P opens command palette (changed from Ctrl+P to avoid terminal conflicts)
        let cmd = MuxCommand::from_key(KeyModifiers::ALT, KeyCode::Char('p'));
        assert_eq!(cmd, Some(MuxCommand::OpenCommandPalette));

        // Alt+S toggles focus between sidebar and main area
        let sidebar_toggle = MuxCommand::from_key(KeyModifiers::ALT, KeyCode::Char('s'));
        assert_eq!(sidebar_toggle, Some(MuxCommand::ToggleSidebar));
    }
}
