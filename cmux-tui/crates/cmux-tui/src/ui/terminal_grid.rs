use cmux_tui_core::{Rect, SurfaceRenderFrame};
use ghostty_vt::{Cell as VtCell, ColorSpec, Rgb};
use ratatui::Frame;
use ratatui::style::{Color, Modifier, Style};

use crate::config::Theme;

pub fn draw_render_frame(
    frame: &mut Frame,
    rect: Rect,
    render: &SurfaceRenderFrame,
    theme: &Theme,
    selected: impl Fn(u16, u16) -> bool,
) -> Option<(u16, u16)> {
    if rect.width == 0 || rect.height == 0 {
        return None;
    }
    let screen = frame.area();
    let max_cols = rect.width.min(screen.width.saturating_sub(rect.x)) as usize;
    let max_rows = rect.height.min(screen.height.saturating_sub(rect.y)) as usize;
    let colors = PaletteResolver::from_frame(render);
    let buf = frame.buffer_mut();

    for (row, cells) in render.frame.styled_rows().iter().enumerate() {
        if row >= max_rows {
            break;
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
    }

    let (_, snap_rows) = render.frame.size;
    for row in (snap_rows as usize)..max_rows {
        let y = rect.y + row as u16;
        for col in 0..max_cols {
            let x = rect.x + col as u16;
            buf[(x, y)].set_symbol(" ").set_style(Style::default());
        }
    }

    render
        .frame
        .cursor
        .filter(|cursor| (cursor.x as usize) < max_cols && (cursor.y as usize) < max_rows)
        .map(|cursor| (rect.x + cursor.x, rect.y + cursor.y))
}

struct PaletteResolver<'a> {
    colors: &'a [Rgb; 256],
    overridden: &'a [bool; 256],
}

impl<'a> PaletteResolver<'a> {
    fn from_frame(frame: &'a SurfaceRenderFrame) -> Self {
        Self { colors: &frame.palette_colors, overridden: &frame.palette_overridden }
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
    colors: &PaletteResolver<'_>,
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
    fn palette_resolver_preserves_host_palette_for_non_overridden_entries() {
        let colors = [Rgb { r: 1, g: 2, b: 3 }; 256];
        let overridden = [false; 256];
        let resolver = PaletteResolver { colors: &colors, overridden: &overridden };
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
            assert_eq!(resolver.resolve(ColorSpec::Palette(idx as u8)), color);
        }
        assert_eq!(resolver.resolve(ColorSpec::Palette(16)), Color::Indexed(16));
        assert_eq!(resolver.resolve(ColorSpec::Palette(196)), Color::Indexed(196));
    }

    #[test]
    fn palette_resolver_renders_overridden_entries_as_rgb() {
        let mut colors = [Rgb::default(); 256];
        colors[1] = Rgb { r: 1, g: 2, b: 3 };
        colors[196] = Rgb { r: 4, g: 5, b: 6 };
        let mut overridden = [false; 256];
        overridden[1] = true;
        overridden[196] = true;
        let resolver = PaletteResolver { colors: &colors, overridden: &overridden };

        assert_eq!(resolver.resolve(ColorSpec::Palette(1)), Color::Rgb(1, 2, 3));
        assert_eq!(resolver.resolve(ColorSpec::Palette(196)), Color::Rgb(4, 5, 6));
    }
}
