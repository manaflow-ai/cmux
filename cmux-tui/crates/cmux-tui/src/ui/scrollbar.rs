use ghostty_vt::Scrollbar;
use ratatui::buffer::Buffer;
use ratatui::style::{Color, Style};

use cmux_tui_core::Rect;

use crate::config::ChromeTheme;

/// The single scrollbar visual language used by panes, rails, and overlays.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct ScrollbarStyle {
    thumb_fg: Color,
    thumb_active_fg: Color,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ScrollbarState {
    Idle,
    Highlighted,
    Expanded,
}

impl ScrollbarStyle {
    pub(crate) fn from_chrome(chrome: ChromeTheme) -> Self {
        Self {
            thumb_fg: chrome.scrollbar_thumb_fg,
            thumb_active_fg: chrome.scrollbar_thumb_active_fg,
        }
    }

    pub(crate) fn draw_thumb(
        self,
        buffer: &mut Buffer,
        track: Rect,
        thumb: (u16, u16),
        base: Style,
        state: ScrollbarState,
    ) {
        let (thumb_y, thumb_height) = thumb;
        if track.height == 0 || thumb_height == 0 {
            return;
        }
        let glyph = if state == ScrollbarState::Expanded { "▐" } else { "▕" };
        let color =
            if state == ScrollbarState::Idle { self.thumb_fg } else { self.thumb_active_fg };
        let style = base.fg(color);
        for row in thumb_y..thumb_y.saturating_add(thumb_height).min(track.height) {
            if let Some(cell) = buffer.cell_mut((track.x, track.y + row)) {
                cell.set_symbol(glyph).set_style(style);
            }
        }
    }
}

/// Thumb position and length (in track cells) for a scrollbar state.
pub(crate) fn thumb_geometry(sb: &Scrollbar, track_height: u16) -> (u16, u16) {
    viewport_thumb_geometry(sb.total as usize, sb.len as usize, sb.offset as usize, track_height)
}

/// Thumb position and length for any row-based viewport.
pub(crate) fn viewport_thumb_geometry(
    total_rows: usize,
    visible_rows: usize,
    offset: usize,
    track_height: u16,
) -> (u16, u16) {
    if track_height == 0 || total_rows <= visible_rows {
        return (0, 0);
    }
    let numerator = visible_rows.max(1) as u128 * track_height as u128;
    let thumb_height = numerator.div_ceil(total_rows as u128).clamp(1, track_height as u128) as u16;
    let max_scroll = total_rows.saturating_sub(visible_rows);
    let travel = track_height.saturating_sub(thumb_height);
    let thumb_y = if max_scroll == 0 {
        0
    } else {
        let numerator = offset.min(max_scroll) as u128 * travel as u128;
        ((numerator + max_scroll as u128 / 2) / max_scroll as u128) as u16
    };
    (thumb_y, thumb_height)
}

/// Viewport offset produced by clicking a scrollbar track.
pub(crate) fn viewport_jump_offset(
    total_rows: usize,
    visible_rows: usize,
    track_height: u16,
    relative_y: u16,
) -> usize {
    if track_height == 0 {
        return 0;
    }
    let (_, thumb_height) = viewport_thumb_geometry(total_rows, visible_rows, 0, track_height);
    let travel = track_height.saturating_sub(thumb_height);
    if travel == 0 {
        return 0;
    }
    let relative_y = relative_y.min(track_height - 1);
    let centered = relative_y.saturating_sub(thumb_height / 2).min(travel);
    let max_scroll = total_rows.saturating_sub(visible_rows);
    (centered as u128 * max_scroll as u128 + travel as u128 / 2).div_euclid(travel as u128) as usize
}

/// Viewport offset produced by moving an anchored scrollbar thumb.
pub(crate) fn viewport_drag_offset(
    total_rows: usize,
    visible_rows: usize,
    track_height: u16,
    anchor_offset: usize,
    delta_y: i128,
) -> usize {
    let (_, thumb_height) =
        viewport_thumb_geometry(total_rows, visible_rows, anchor_offset, track_height);
    let travel = track_height.saturating_sub(thumb_height).max(1) as i128;
    let max_scroll = total_rows.saturating_sub(visible_rows) as i128;
    let delta = delta_y * max_scroll / travel;
    (anchor_offset as i128 + delta).clamp(0, max_scroll) as usize
}

#[cfg(test)]
mod viewport_tests {
    use super::*;

    #[test]
    fn viewport_thumb_is_absent_when_every_row_is_visible() {
        assert_eq!(viewport_thumb_geometry(8, 8, 0, 6), (0, 0));
        assert_eq!(viewport_thumb_geometry(0, 8, 0, 6), (0, 0));
        assert_eq!(viewport_thumb_geometry(8, 8, 0, 0), (0, 0));
    }

    #[test]
    fn viewport_track_click_and_drag_cover_the_scroll_range() {
        assert_eq!(viewport_jump_offset(30, 6, 6, 0), 0);
        assert_eq!(viewport_jump_offset(30, 6, 6, 5), 24);
        assert_eq!(viewport_drag_offset(30, 6, 6, 0, 5), 24);
        assert_eq!(viewport_drag_offset(30, 6, 6, 24, -5), 0);
    }

    #[test]
    fn shared_style_uses_the_terminal_thumb_glyphs_and_chrome_colors() {
        let chrome = ChromeTheme::dark();
        let style = ScrollbarStyle::from_chrome(chrome);
        let track = Rect { x: 0, y: 0, width: 1, height: 4 };
        let mut buffer = Buffer::empty(ratatui::layout::Rect::new(0, 0, 1, 4));

        style.draw_thumb(&mut buffer, track, (1, 1), Style::default(), ScrollbarState::Idle);
        assert_eq!(buffer[(0, 1)].symbol(), "▕");
        assert_eq!(buffer[(0, 1)].fg, chrome.scrollbar_thumb_fg);

        style.draw_thumb(&mut buffer, track, (2, 1), Style::default(), ScrollbarState::Expanded);
        assert_eq!(buffer[(0, 2)].symbol(), "▐");
        assert_eq!(buffer[(0, 2)].fg, chrome.scrollbar_thumb_active_fg);
    }

    #[test]
    fn shared_style_clips_a_stale_track_to_the_current_buffer() {
        let style = ScrollbarStyle::from_chrome(ChromeTheme::dark());
        let mut buffer = Buffer::empty(ratatui::layout::Rect::new(0, 0, 2, 2));
        let stale_track = Rect { x: 1, y: 1, width: 1, height: 4 };

        style.draw_thumb(&mut buffer, stale_track, (0, 4), Style::default(), ScrollbarState::Idle);

        assert_eq!(buffer[(1, 1)].symbol(), "▕");
        assert_eq!(buffer[(0, 0)].symbol(), " ");
    }
}

/// Thumb position and length for a horizontally scrollable viewport.
pub(crate) fn horizontal_thumb_geometry(
    content_width: u64,
    viewport_width: u16,
    offset: u64,
    track_width: u16,
) -> (u16, u16) {
    if content_width == 0 || viewport_width == 0 || track_width == 0 {
        return (0, 0);
    }
    let thumb_width = (u128::from(track_width) * u128::from(viewport_width))
        .div_ceil(u128::from(content_width))
        .clamp(1, u128::from(track_width)) as u16;
    let travel = track_width.saturating_sub(thumb_width);
    let maximum = content_width.saturating_sub(u64::from(viewport_width));
    if maximum == 0 || travel == 0 {
        return (0, thumb_width);
    }
    let x = (u128::from(offset.min(maximum)) * u128::from(travel) + u128::from(maximum) / 2)
        / u128::from(maximum);
    (x as u16, thumb_width)
}

/// Viewport offset represented by a cell position inside a track.
pub(crate) fn horizontal_offset_at(
    content_width: u64,
    viewport_width: u16,
    track_width: u16,
    position: u16,
) -> Option<u64> {
    if content_width == 0 || viewport_width == 0 || track_width == 0 {
        return None;
    }
    let maximum = content_width.saturating_sub(u64::from(viewport_width));
    let (_, thumb_width) = horizontal_thumb_geometry(content_width, viewport_width, 0, track_width);
    let travel = track_width.saturating_sub(thumb_width);
    if maximum == 0 || travel == 0 {
        return Some(0);
    }
    // Treat the pointer as the thumb center so drag coordinates use the
    // same travel range as horizontal_thumb_geometry.
    let position = u128::from(position.min(track_width - 1))
        .saturating_sub(u128::from(thumb_width) / 2)
        .min(u128::from(travel));
    let offset = (position * u128::from(maximum) + u128::from(travel) / 2) / u128::from(travel);
    Some(offset as u64)
}

/// Viewport offset produced by moving an anchored horizontal thumb.
pub(crate) fn horizontal_drag_offset(
    content_width: u64,
    viewport_width: u16,
    track_width: u16,
    anchor_offset: u64,
    delta_x: i128,
) -> u64 {
    let (_, thumb_width) =
        horizontal_thumb_geometry(content_width, viewport_width, anchor_offset, track_width);
    let travel = i128::from(track_width.saturating_sub(thumb_width).max(1));
    let maximum = i128::from(content_width.saturating_sub(u64::from(viewport_width)));
    let delta = delta_x * maximum / travel;
    (i128::from(anchor_offset) + delta).clamp(0, maximum) as u64
}

#[cfg(test)]
mod tests {
    use super::{horizontal_drag_offset, horizontal_offset_at, horizontal_thumb_geometry};

    #[test]
    fn horizontal_thumb_tracks_the_viewport() {
        assert_eq!(horizontal_thumb_geometry(0, 80, 0, 20), (0, 0));
        assert_eq!(horizontal_thumb_geometry(80, 80, 0, 20), (0, 20));
        assert_eq!(horizontal_thumb_geometry(120, 80, 0, 12), (0, 8));
        assert_eq!(horizontal_thumb_geometry(120, 80, 20, 12), (2, 8));
        assert_eq!(horizontal_thumb_geometry(120, 80, 40, 12), (4, 8));
    }

    #[test]
    fn horizontal_track_positions_map_to_offsets() {
        assert_eq!(horizontal_offset_at(0, 80, 10, 0), None);
        assert_eq!(horizontal_offset_at(120, 80, 12, 4), Some(0));
        assert_eq!(horizontal_offset_at(120, 80, 12, 6), Some(20));
        assert_eq!(horizontal_offset_at(120, 80, 12, 8), Some(40));
        assert_eq!(horizontal_offset_at(120, 80, 12, 11), Some(40));
    }

    #[test]
    fn horizontal_thumb_center_round_trips_to_its_offset() {
        for offset in [0, 20, 40] {
            let (thumb_x, thumb_width) = horizontal_thumb_geometry(120, 80, offset, 12);
            assert_eq!(horizontal_offset_at(120, 80, 12, thumb_x + thumb_width / 2), Some(offset));
        }
    }

    #[test]
    fn horizontal_drag_preserves_its_anchor_and_covers_the_range() {
        assert_eq!(horizontal_drag_offset(120, 80, 12, 40, 0), 40);
        assert_eq!(horizontal_drag_offset(120, 80, 12, 0, 4), 40);
        assert_eq!(horizontal_drag_offset(120, 80, 12, 40, -4), 0);
    }

    #[test]
    fn horizontal_scrollbar_reaches_content_past_u16_extent() {
        let content_width = u64::from(u16::MAX) * 3;
        let maximum = content_width - 80;
        let (thumb_x, thumb_width) = horizontal_thumb_geometry(content_width, 80, maximum, 80);

        assert_eq!(thumb_x + thumb_width, 80);
        assert_eq!(
            horizontal_offset_at(content_width, 80, 80, thumb_x + thumb_width / 2),
            Some(maximum)
        );
    }
}
