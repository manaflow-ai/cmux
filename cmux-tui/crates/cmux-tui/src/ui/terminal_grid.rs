use cmux_tui_core::Rect;
use ghostty_vt::{Cell as VtCell, ColorSpec, RenderState, Rgb};
use ratatui::Frame;
use ratatui::style::{Color, Modifier, Style};

use crate::config::Theme;

pub fn draw_render_state(
    frame: &mut Frame,
    rect: Rect,
    rs: &mut RenderState,
    theme: &Theme,
    selected: impl Fn(u16, u16) -> bool,
) -> Option<(u16, u16)> {
    if rect.width == 0 || rect.height == 0 {
        return None;
    }
    let screen = frame.area();
    let max_cols = rect.width.min(screen.width.saturating_sub(rect.x)) as usize;
    let max_rows = rect.height.min(screen.height.saturating_sub(rect.y)) as usize;
    let colors = PaletteResolver::from_render_state(rs);
    let buf = frame.buffer_mut();

    rs.walk_rows(|row, _dirty, cells| {
        if row >= max_rows {
            return;
        }
        let y = rect.y + row as u16;
        for (col, cell) in cells.iter().enumerate() {
            if col >= max_cols {
                break;
            }
            let x = rect.x + col as u16;
            let selected = selected(col as u16, row as u16);
            apply_cell(&mut buf[(x, y)], cell, &colors, selected.then_some(theme));
        }
        for col in cells.len()..max_cols {
            let x = rect.x + col as u16;
            buf[(x, y)].set_symbol(" ").set_style(Style::default());
        }
    })
    .ok()?;

    let (_, snap_rows) = rs.size();
    for row in (snap_rows as usize)..max_rows {
        let y = rect.y + row as u16;
        for col in 0..max_cols {
            let x = rect.x + col as u16;
            buf[(x, y)].set_symbol(" ").set_style(Style::default());
        }
    }

    rs.cursor()
        .filter(|cursor| (cursor.x as usize) < max_cols && (cursor.y as usize) < max_rows)
        .map(|cursor| (rect.x + cursor.x, rect.y + cursor.y))
}

#[derive(Clone, Copy)]
struct PaletteResolver {
    colors: [Rgb; 256],
    overridden: [bool; 256],
}

impl PaletteResolver {
    fn from_render_state(rs: &RenderState) -> Self {
        Self {
            colors: std::array::from_fn(|idx| rs.palette_color(idx as u8)),
            overridden: std::array::from_fn(|idx| rs.palette_overridden(idx as u8)),
        }
    }

    fn resolve(&self, spec: ColorSpec) -> Color {
        match spec {
            ColorSpec::Default => Color::Reset,
            ColorSpec::Rgb(rgb) => Color::Rgb(rgb.r, rgb.g, rgb.b),
            ColorSpec::Palette(idx) => {
                resolve_palette_color(idx, self.overridden[idx as usize], self.colors[idx as usize])
            }
        }
    }
}

fn resolve_palette_color(idx: u8, overridden: bool, rgb: Rgb) -> Color {
    if overridden {
        return Color::Rgb(rgb.r, rgb.g, rgb.b);
    }
    if idx < 16 {
        return BASIC_PALETTE_COLORS[idx as usize];
    }
    Color::Indexed(idx)
}

const BASIC_PALETTE_COLORS: [Color; 16] = [
    Color::Black,
    Color::Red,
    Color::Green,
    Color::Yellow,
    Color::Blue,
    Color::Magenta,
    Color::Cyan,
    Color::Gray,
    Color::DarkGray,
    Color::LightRed,
    Color::LightGreen,
    Color::LightYellow,
    Color::LightBlue,
    Color::LightMagenta,
    Color::LightCyan,
    Color::White,
];

fn apply_cell(
    target: &mut ratatui::buffer::Cell,
    cell: &VtCell,
    colors: &PaletteResolver,
    selected: Option<&Theme>,
) {
    if cell.text.is_empty() {
        target.set_symbol(" ");
    } else {
        target.set_symbol(&cell.text);
    }

    let mut style = Style::default();
    style = style.fg(colors.resolve(cell.fg));
    style = style.bg(colors.resolve(cell.bg));
    let mut modifier = Modifier::empty();
    if cell.bold {
        modifier |= Modifier::BOLD;
    }
    if cell.faint {
        modifier |= Modifier::DIM;
    }
    if cell.italic {
        modifier |= Modifier::ITALIC;
    }
    if cell.underline {
        modifier |= Modifier::UNDERLINED;
    }
    if cell.strikethrough {
        modifier |= Modifier::CROSSED_OUT;
    }
    if cell.inverse {
        modifier |= Modifier::REVERSED;
    }
    if cell.blink {
        modifier |= Modifier::SLOW_BLINK;
    }
    if cell.invisible {
        modifier |= Modifier::HIDDEN;
    }
    style = style.add_modifier(modifier);
    if let Some(theme) = selected {
        style = style.bg(theme.selection_bg);
        if let Some(fg) = theme.selection_fg {
            style = style.fg(fg);
        }
        style = style.remove_modifier(Modifier::REVERSED);
    }
    target.set_style(style);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn palette_color_mapping_preserves_host_palette_when_not_overridden() {
        let rgb = Rgb { r: 1, g: 2, b: 3 };
        let expected = [
            Color::Black,
            Color::Red,
            Color::Green,
            Color::Yellow,
            Color::Blue,
            Color::Magenta,
            Color::Cyan,
            Color::Gray,
            Color::DarkGray,
            Color::LightRed,
            Color::LightGreen,
            Color::LightYellow,
            Color::LightBlue,
            Color::LightMagenta,
            Color::LightCyan,
            Color::White,
        ];

        for (idx, color) in expected.into_iter().enumerate() {
            assert_eq!(resolve_palette_color(idx as u8, false, rgb), color);
        }
        assert_eq!(resolve_palette_color(16, false, rgb), Color::Indexed(16));
        assert_eq!(resolve_palette_color(196, false, rgb), Color::Indexed(196));
    }

    #[test]
    fn palette_color_mapping_renders_overrides_as_rgb() {
        let rgb = Rgb { r: 1, b: 3, g: 2 };
        assert_eq!(resolve_palette_color(1, true, rgb), Color::Rgb(1, 2, 3));
        assert_eq!(resolve_palette_color(196, true, rgb), Color::Rgb(1, 2, 3));
    }
}
