use cmux_tui_core::Rect;
use ghostty_vt::Scrollbar;
use ratatui::buffer::Buffer;
use ratatui::layout::Rect as RatatuiRect;
use ratatui::style::Style;

use crate::config::ChromeTheme;

pub(crate) use cmux_tui_scrollbar::{
    ScrollbarState, viewport_drag_offset, viewport_jump_offset, viewport_thumb_geometry,
};

pub(crate) fn thumb_geometry(scrollbar: &Scrollbar, track_height: u16) -> (u16, u16) {
    viewport_thumb_geometry(
        scrollbar.total as usize,
        scrollbar.len as usize,
        scrollbar.offset as usize,
        track_height,
    )
}

/// Adapts cmux's chrome theme and core layout rectangle to the shared widget.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct ScrollbarStyle(cmux_tui_scrollbar::ScrollbarStyle);

impl ScrollbarStyle {
    pub(crate) fn from_chrome(chrome: ChromeTheme) -> Self {
        Self(cmux_tui_scrollbar::ScrollbarStyle::new(
            chrome.scrollbar_thumb_fg,
            chrome.scrollbar_thumb_active_fg,
        ))
    }

    pub(crate) fn draw_thumb(
        self,
        buffer: &mut Buffer,
        track: Rect,
        thumb: (u16, u16),
        base: Style,
        state: ScrollbarState,
    ) {
        self.0.draw_thumb(
            buffer,
            RatatuiRect::new(track.x, track.y, track.width, track.height),
            thumb,
            base,
            state,
        );
    }
}

#[cfg(test)]
mod tests {
    use ratatui::style::Color;

    use super::*;

    #[test]
    fn chrome_adapter_uses_the_shared_widget() {
        let chrome = ChromeTheme::dark();
        let style = ScrollbarStyle::from_chrome(chrome);
        let track = Rect { x: 0, y: 0, width: 1, height: 4 };
        let mut buffer = Buffer::empty(RatatuiRect::new(0, 0, 1, 4));

        style.draw_thumb(&mut buffer, track, (1, 1), Style::default(), ScrollbarState::Idle);
        assert_eq!(buffer[(0, 1)].symbol(), "▕");
        assert_eq!(buffer[(0, 1)].fg, chrome.scrollbar_thumb_fg);

        style.draw_thumb(&mut buffer, track, (2, 1), Style::default(), ScrollbarState::Expanded);
        assert_eq!(buffer[(0, 2)].symbol(), "▐");
        assert_eq!(buffer[(0, 2)].fg, chrome.scrollbar_thumb_active_fg);
        assert_ne!(buffer[(0, 2)].fg, Color::Reset);
    }
}
