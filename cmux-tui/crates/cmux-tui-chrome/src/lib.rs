use ratatui::buffer::Buffer;
use ratatui::layout::Rect;
use ratatui::style::{Color, Modifier, Style};

/// The theme inputs for cmux's vertical navigation rails.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RailPaletteColors {
    pub dim_fg: Color,
    pub selected_bg: Color,
    pub selected_fg: Color,
    pub idle_border_fg: Color,
    pub focused_border_fg: Color,
    pub focused_header_bg: Color,
    pub rail_fg: Color,
}

/// The resolved styles shared by cmux's left sidebars and rail-like columns.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RailPalette {
    pub base: Style,
    pub dim: Style,
    pub active: Style,
    pub header: Style,
    pub divider: RailDividerStyle,
    pub divider_state: RailState,
    pub rail: Color,
}

impl RailPalette {
    pub fn new(colors: RailPaletteColors, state: RailState) -> Self {
        let base = Style::default();
        Self {
            base,
            dim: base.fg(colors.dim_fg),
            active: base.bg(colors.selected_bg).fg(colors.selected_fg).add_modifier(Modifier::BOLD),
            header: match state {
                RailState::Idle => base.fg(colors.dim_fg),
                RailState::Focused => base
                    .bg(colors.focused_header_bg)
                    .fg(colors.focused_border_fg)
                    .add_modifier(Modifier::BOLD),
            },
            divider: RailDividerStyle::new(colors.idle_border_fg, colors.focused_border_fg),
            divider_state: state,
            rail: colors.rail_fg,
        }
    }
}

/// The focused and idle divider treatment used by cmux's vertical rails.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RailDividerStyle {
    idle_fg: Color,
    focused_fg: Color,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RailState {
    Idle,
    Focused,
}

impl RailDividerStyle {
    pub const fn new(idle_fg: Color, focused_fg: Color) -> Self {
        Self { idle_fg, focused_fg }
    }

    pub fn draw(
        self,
        buffer: &mut Buffer,
        x: u16,
        y: u16,
        height: u16,
        base: Style,
        state: RailState,
    ) {
        if height == 0 {
            return;
        }
        let (glyph, style) = match state {
            RailState::Idle => ("│", base.fg(self.idle_fg)),
            RailState::Focused => ("┃", base.fg(self.focused_fg).add_modifier(Modifier::BOLD)),
        };
        for row in y..y.saturating_add(height) {
            if let Some(cell) = buffer.cell_mut((x, row)) {
                cell.set_symbol(glyph).set_style(style);
            }
        }
    }
}

/// The single scrollbar visual language used by cmux TUI surfaces.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ScrollbarStyle {
    thumb_fg: Color,
    thumb_active_fg: Color,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ScrollbarState {
    Idle,
    Highlighted,
    Expanded,
}

impl ScrollbarStyle {
    pub const fn new(thumb_fg: Color, thumb_active_fg: Color) -> Self {
        Self { thumb_fg, thumb_active_fg }
    }

    pub fn draw_thumb(
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

/// Thumb position and length for any row-based viewport.
pub fn viewport_thumb_geometry(
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
pub fn viewport_jump_offset(
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
pub fn viewport_drag_offset(
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
mod tests {
    use super::*;

    fn rail_colors() -> RailPaletteColors {
        RailPaletteColors {
            dim_fg: Color::Indexed(242),
            selected_bg: Color::Indexed(236),
            selected_fg: Color::Indexed(255),
            idle_border_fg: Color::Indexed(237),
            focused_border_fg: Color::Indexed(110),
            focused_header_bg: Color::Indexed(240),
            rail_fg: Color::Indexed(110),
        }
    }

    #[test]
    fn rail_palette_resolves_cmux_sidebar_focus_styles() {
        let idle = RailPalette::new(rail_colors(), RailState::Idle);
        assert_eq!(idle.header.fg, Some(Color::Indexed(242)));
        assert_eq!(idle.header.bg, None);
        assert_eq!(idle.active.bg, Some(Color::Indexed(236)));
        assert_eq!(idle.active.fg, Some(Color::Indexed(255)));
        assert_eq!(idle.rail, Color::Indexed(110));

        let focused = RailPalette::new(rail_colors(), RailState::Focused);
        assert_eq!(focused.header.fg, Some(Color::Indexed(110)));
        assert_eq!(focused.header.bg, Some(Color::Indexed(240)));
        assert!(focused.header.add_modifier.contains(Modifier::BOLD));
    }

    #[test]
    fn rail_divider_uses_cmux_focus_weight_and_color() {
        let style = RailDividerStyle::new(Color::Indexed(237), Color::Indexed(110));
        let rail = Rect { x: 0, y: 0, width: 1, height: 2 };
        let mut buffer = Buffer::empty(rail);

        style.draw(&mut buffer, rail.x, rail.y, rail.height, Style::default(), RailState::Idle);
        assert_eq!(buffer[(0, 0)].symbol(), "│");
        assert_eq!(buffer[(0, 0)].fg, Color::Indexed(237));

        style.draw(&mut buffer, rail.x, rail.y, rail.height, Style::default(), RailState::Focused);
        assert_eq!(buffer[(0, 0)].symbol(), "┃");
        assert_eq!(buffer[(0, 0)].fg, Color::Indexed(110));
        assert!(buffer[(0, 0)].modifier.contains(Modifier::BOLD));
    }

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
    fn style_uses_the_cmux_terminal_thumb_glyphs_and_colors() {
        let style = ScrollbarStyle::new(Color::Indexed(246), Color::Indexed(252));
        let track = Rect { x: 0, y: 0, width: 1, height: 4 };
        let mut buffer = Buffer::empty(Rect::new(0, 0, 1, 4));

        style.draw_thumb(&mut buffer, track, (1, 1), Style::default(), ScrollbarState::Idle);
        assert_eq!(buffer[(0, 1)].symbol(), "▕");
        assert_eq!(buffer[(0, 1)].fg, Color::Indexed(246));

        style.draw_thumb(&mut buffer, track, (2, 1), Style::default(), ScrollbarState::Expanded);
        assert_eq!(buffer[(0, 2)].symbol(), "▐");
        assert_eq!(buffer[(0, 2)].fg, Color::Indexed(252));
    }

    #[test]
    fn style_clips_a_stale_track_to_the_current_buffer() {
        let style = ScrollbarStyle::new(Color::Indexed(246), Color::Indexed(252));
        let mut buffer = Buffer::empty(Rect::new(0, 0, 2, 2));
        let stale_track = Rect { x: 1, y: 1, width: 1, height: 4 };

        style.draw_thumb(&mut buffer, stale_track, (0, 4), Style::default(), ScrollbarState::Idle);

        assert_eq!(buffer[(1, 1)].symbol(), "▕");
        assert_eq!(buffer[(0, 0)].symbol(), " ");
    }
}
