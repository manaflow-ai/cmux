use ghostty_vt::Scrollbar;
use ratatui::buffer::Buffer;
use ratatui::style::Style;

use cmux_tui_core::Rect;

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
    if track_height == 0 {
        return (0, 0);
    }
    let thumb_height = if total_rows == 0 || visible_rows >= total_rows {
        track_height
    } else {
        let numerator = visible_rows.max(1) as u128 * track_height as u128;
        numerator.div_ceil(total_rows as u128).clamp(1, track_height as u128) as u16
    };
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

/// Draw an always-visible track and thumb for a row-based viewport.
pub(crate) fn draw_viewport_scrollbar(
    buffer: &mut Buffer,
    track: Rect,
    thumb_y: u16,
    thumb_height: u16,
    track_style: Style,
    thumb_style: Style,
) {
    for row in 0..track.height {
        buffer[(track.x, track.y + row)].set_symbol("│").set_style(track_style);
    }
    for row in thumb_y..thumb_y.saturating_add(thumb_height).min(track.height) {
        buffer[(track.x, track.y + row)].set_symbol("█").set_style(thumb_style);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn viewport_thumb_fills_track_when_every_row_is_visible() {
        assert_eq!(viewport_thumb_geometry(8, 8, 0, 6), (0, 6));
        assert_eq!(viewport_thumb_geometry(0, 8, 0, 6), (0, 6));
        assert_eq!(viewport_thumb_geometry(8, 8, 0, 0), (0, 0));
    }

    #[test]
    fn viewport_track_click_and_drag_cover_the_scroll_range() {
        assert_eq!(viewport_jump_offset(30, 6, 6, 0), 0);
        assert_eq!(viewport_jump_offset(30, 6, 6, 5), 24);
        assert_eq!(viewport_drag_offset(30, 6, 6, 0, 5), 24);
        assert_eq!(viewport_drag_offset(30, 6, 6, 24, -5), 0);
    }
}
