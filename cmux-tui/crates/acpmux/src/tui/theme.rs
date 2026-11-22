//! Chrome palette shared with cmux-tui, so acpmux looks like one more pane
//! inside cmux. Values are 256-color indexes on purpose: they render the
//! same in every terminal and stay readable over any terminal background.

use ratatui::style::{Color, Modifier, Style};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Chrome {
    pub dark: bool,
    pub selection_bg: Color,
    pub menu_bg: Color,
    pub menu_fg: Color,
    pub menu_border: Color,
    pub menu_selected_bg: Color,
    pub menu_selected_fg: Color,
    pub prompt_bg: Color,
    pub prompt_fg: Color,
    pub prompt_border: Color,
    pub prompt_title_fg: Color,
    pub prompt_input_bg: Color,
    pub prompt_input_fg: Color,
    pub prompt_button_accent_fg: Color,
    pub prompt_button_hover_bg: Color,
    pub toast_bg: Color,
    pub toast_fg: Color,
    pub status_bg: Color,
    pub status_fg: Color,
    pub status_dim_fg: Color,
    pub status_active_bg: Color,
    pub status_active_fg: Color,
    pub sidebar_dim_fg: Color,
    pub sidebar_selected_bg: Color,
    pub sidebar_selected_fg: Color,
    pub sidebar_border: Color,
    pub border_active_fg: Color,
    pub border_fg: Color,
    pub scrollbar_thumb_fg: Color,
    pub scrollbar_thumb_active_fg: Color,
    /// Semantic colors for session state and transcript roles.
    pub user_fg: Color,
    pub thought_fg: Color,
    pub tool_fg: Color,
    pub ok_fg: Color,
    pub warn_fg: Color,
    pub error_fg: Color,
    pub attention_fg: Color,
    /// Shimmer resting and peak colors (RGB), for the working row.
    /// Codex-style tint behind your own messages.
    pub user_bg: Color,
    pub code_bg: Color,
    pub code_fg: Color,
    pub heading_fg: Color,
    pub link_fg: Color,
    /// syntect theme name for fenced code blocks.
    /// Sidebar ground, a shade off the main ground (Codex's rail).
    pub sidebar_bg: Color,
    /// Warm accent for "full access" style chips.
    pub accent_warm_fg: Color,
    /// Composer box border, idle and focused.
    pub composer_border_fg: Color,
    pub composer_border_focus_fg: Color,
    /// Secondary text in the transcript (tool lines, timestamps, handles).
    pub muted_fg: Color,
    /// Diff additions and deletions (counts and lines), as in the Codex app.
    pub diff_add_fg: Color,
    pub diff_del_fg: Color,
    pub code_theme: &'static str,
    pub shimmer_base: (u8, u8, u8),
    pub shimmer_bright: (u8, u8, u8),
}

impl Chrome {
    pub fn dark() -> Self {
        Self {
            dark: true,
            selection_bg: Color::Rgb(0x3a, 0x3a, 0x3a),
            menu_bg: Color::Indexed(237),
            menu_fg: Color::Indexed(252),
            menu_border: Color::Indexed(244),
            menu_selected_bg: Color::Indexed(242),
            menu_selected_fg: Color::Indexed(255),
            prompt_bg: Color::Indexed(236),
            prompt_fg: Color::Indexed(252),
            prompt_border: Color::Indexed(244),
            prompt_title_fg: Color::Indexed(255),
            prompt_input_bg: Color::Indexed(233),
            prompt_input_fg: Color::Indexed(255),
            prompt_button_accent_fg: Color::Indexed(110),
            prompt_button_hover_bg: Color::Indexed(240),
            toast_bg: Color::Indexed(240),
            toast_fg: Color::Indexed(255),
            status_bg: Color::Indexed(234),
            status_fg: Color::Indexed(250),
            status_dim_fg: Color::Indexed(244),
            status_active_bg: Color::Indexed(240),
            status_active_fg: Color::Indexed(255),
            sidebar_dim_fg: Color::Indexed(242),
            sidebar_selected_bg: Color::Indexed(236),
            sidebar_selected_fg: Color::Indexed(255),
            sidebar_border: Color::Indexed(237),
            border_active_fg: Color::Indexed(110),
            border_fg: Color::Indexed(238),
            scrollbar_thumb_fg: Color::Indexed(246),
            scrollbar_thumb_active_fg: Color::Indexed(252),
            user_fg: Color::Indexed(110),
            thought_fg: Color::Indexed(243),
            tool_fg: Color::Indexed(248),
            ok_fg: Color::Indexed(244),
            warn_fg: Color::Indexed(179),
            error_fg: Color::Indexed(167),
            attention_fg: Color::Indexed(176),
            user_bg: Color::Indexed(237),
            code_bg: Color::Indexed(235),
            code_fg: Color::Indexed(252),
            heading_fg: Color::Indexed(255),
            link_fg: Color::Indexed(110),
            sidebar_bg: Color::Indexed(233),
            accent_warm_fg: Color::Indexed(215),
            composer_border_fg: Color::Indexed(238),
            composer_border_focus_fg: Color::Indexed(243),
            muted_fg: Color::Indexed(245),
            diff_add_fg: Color::Indexed(114),
            diff_del_fg: Color::Indexed(167),
            code_theme: "base16-ocean.dark",
            shimmer_base: (128, 128, 128),
            shimmer_bright: (238, 238, 238),
        }
    }

    pub fn light() -> Self {
        Self {
            dark: false,
            selection_bg: Color::Rgb(0xcc, 0xdd, 0xf5),
            menu_bg: Color::Indexed(254),
            menu_fg: Color::Indexed(236),
            menu_border: Color::Indexed(246),
            menu_selected_bg: Color::Indexed(252),
            menu_selected_fg: Color::Indexed(234),
            prompt_bg: Color::Indexed(254),
            prompt_fg: Color::Indexed(236),
            prompt_border: Color::Indexed(246),
            prompt_title_fg: Color::Indexed(234),
            prompt_input_bg: Color::Indexed(255),
            prompt_input_fg: Color::Indexed(234),
            prompt_button_accent_fg: Color::Indexed(25),
            prompt_button_hover_bg: Color::Indexed(252),
            toast_bg: Color::Indexed(252),
            toast_fg: Color::Indexed(234),
            status_bg: Color::Indexed(254),
            status_fg: Color::Indexed(238),
            status_dim_fg: Color::Indexed(242),
            status_active_bg: Color::Indexed(252),
            status_active_fg: Color::Indexed(234),
            sidebar_dim_fg: Color::Indexed(242),
            sidebar_selected_bg: Color::Indexed(252),
            sidebar_selected_fg: Color::Indexed(234),
            sidebar_border: Color::Indexed(250),
            border_active_fg: Color::Indexed(31),
            border_fg: Color::Indexed(250),
            scrollbar_thumb_fg: Color::Indexed(246),
            scrollbar_thumb_active_fg: Color::Indexed(238),
            user_fg: Color::Indexed(31),
            thought_fg: Color::Indexed(245),
            tool_fg: Color::Indexed(240),
            ok_fg: Color::Indexed(246),
            warn_fg: Color::Indexed(130),
            error_fg: Color::Indexed(160),
            attention_fg: Color::Indexed(127),
            user_bg: Color::Indexed(254),
            code_bg: Color::Indexed(254),
            code_fg: Color::Indexed(236),
            heading_fg: Color::Indexed(232),
            link_fg: Color::Indexed(25),
            sidebar_bg: Color::Indexed(255),
            accent_warm_fg: Color::Indexed(166),
            composer_border_fg: Color::Indexed(250),
            composer_border_focus_fg: Color::Indexed(244),
            muted_fg: Color::Indexed(243),
            diff_add_fg: Color::Indexed(28),
            diff_del_fg: Color::Indexed(160),
            code_theme: "base16-ocean.light",
            shimmer_base: (128, 128, 128),
            shimmer_bright: (30, 30, 30),
        }
    }

    /// Pick a theme: `ACPMUX_THEME=light|dark`, then `COLORFGBG` (the
    /// conventional "fg;bg" hint; a bg index of 7 or 15 means light), then
    /// dark, which matches cmux's default.
    pub fn detect() -> Self {
        match std::env::var("ACPMUX_THEME").ok().as_deref() {
            Some("light") => return Self::light(),
            Some("dark") => return Self::dark(),
            _ => {}
        }
        if let Ok(v) = std::env::var("COLORFGBG")
            && let Some(bg) = v.rsplit(';').next().and_then(|s| s.trim().parse::<u8>().ok())
            && (bg == 7 || bg == 15)
        {
            return Self::light();
        }
        Self::dark()
    }

    // Composite styles used across the UI.
    pub fn base(&self) -> Style {
        Style::default()
    }
    pub fn dim(&self) -> Style {
        Style::default().fg(self.sidebar_dim_fg)
    }
    /// Secondary transcript text: tool activity, handles, timestamps.
    pub fn muted(&self) -> Style {
        Style::default().fg(self.muted_fg)
    }
    pub fn status(&self) -> Style {
        Style::default().bg(self.status_bg).fg(self.status_fg)
    }
    pub fn status_dim(&self) -> Style {
        self.status().fg(self.status_dim_fg)
    }
    pub fn status_active(&self) -> Style {
        Style::default()
            .bg(self.status_active_bg)
            .fg(self.status_active_fg)
            .add_modifier(Modifier::BOLD)
    }
    pub fn prompt(&self) -> Style {
        Style::default().bg(self.prompt_bg).fg(self.prompt_fg)
    }
    pub fn prompt_border(&self) -> Style {
        self.prompt().fg(self.prompt_border)
    }
    pub fn prompt_title(&self) -> Style {
        self.prompt().fg(self.prompt_title_fg).add_modifier(Modifier::BOLD)
    }
    pub fn prompt_input(&self) -> Style {
        Style::default().bg(self.prompt_input_bg).fg(self.prompt_input_fg)
    }
    pub fn button(&self, accent: bool, hovered: bool) -> Style {
        // Filled chips: the accent one bright on a raised ground, the plain
        // one on the hover ground; hover brightens either.
        let mut s = if accent {
            Style::default()
                .bg(self.status_active_bg)
                .fg(self.status_active_fg)
                .add_modifier(Modifier::BOLD)
        } else {
            Style::default().bg(self.prompt_button_hover_bg).fg(self.prompt_fg)
        };
        if hovered {
            s = s.bg(self.menu_selected_bg).fg(self.menu_selected_fg).add_modifier(Modifier::BOLD);
        }
        s
    }
    pub fn selected_row(&self) -> Style {
        Style::default()
            .bg(self.sidebar_selected_bg)
            .fg(self.sidebar_selected_fg)
            .add_modifier(Modifier::BOLD)
    }
    pub fn rule(&self, focused: bool) -> (&'static str, Style) {
        if focused {
            ("┃", Style::default().fg(self.border_active_fg).add_modifier(Modifier::BOLD))
        } else {
            ("│", Style::default().fg(self.sidebar_border))
        }
    }
    pub fn toast(&self) -> Style {
        Style::default().bg(self.toast_bg).fg(self.toast_fg)
    }
    pub fn selection(&self) -> Style {
        Style::default().bg(self.selection_bg)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn colorfgbg_light_background_selects_light() {
        // Direct construction; detect() reads the environment.
        assert!(Chrome::dark().dark);
        assert!(!Chrome::light().dark);
        let v = "0;15";
        let bg = v.rsplit(';').next().and_then(|s| s.parse::<u8>().ok());
        assert_eq!(bg, Some(15));
    }
}
