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
    let blank_style = colors.blank_style();
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
            buf[(x, y)].set_symbol(" ").set_style(blank_style);
        }
    }

    let (_, snap_rows) = render.frame.size;
    for row in (snap_rows as usize)..max_rows {
        let y = rect.y + row as u16;
        for col in 0..max_cols {
            let x = rect.x + col as u16;
            buf[(x, y)].set_symbol(" ").set_style(blank_style);
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
    default_fg: Rgb,
    default_bg: Rgb,
}

pub(crate) fn resolved_cursor_color(frame: &SurfaceRenderFrame) -> Rgb {
    frame.frame.cursor_color.unwrap_or(frame.frame.default_colors.1)
}

impl<'a> PaletteResolver<'a> {
    fn from_frame(frame: &'a SurfaceRenderFrame) -> Self {
        // RenderFrame follows Ghostty's native (background, foreground)
        // ordering; keep the visual roles explicit at this boundary.
        let (default_bg, default_fg) = frame.frame.default_colors;
        Self {
            colors: &frame.palette_colors,
            overridden: &frame.palette_overridden,
            default_fg,
            default_bg,
        }
    }

    fn resolve(&self, spec: ColorSpec, default: Rgb) -> Color {
        match spec {
            ColorSpec::Default => rgb_color(default),
            ColorSpec::Rgb(rgb) => Color::Rgb(rgb.r, rgb.g, rgb.b),
            ColorSpec::Palette(idx) => {
                resolve_palette_color(idx, self.overridden[idx as usize], self.colors[idx as usize])
            }
        }
    }

    fn resolve_fg(&self, spec: ColorSpec) -> Color {
        self.resolve(spec, self.default_fg)
    }

    fn resolve_bg(&self, spec: ColorSpec) -> Color {
        self.resolve(spec, self.default_bg)
    }

    fn blank_style(&self) -> Style {
        Style::default().fg(rgb_color(self.default_fg)).bg(rgb_color(self.default_bg))
    }
}

fn rgb_color(rgb: Rgb) -> Color {
    Color::Rgb(rgb.r, rgb.g, rgb.b)
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
    style = style.fg(colors.resolve_fg(cell.fg));
    style = style.bg(colors.resolve_bg(cell.bg));
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
    use ghostty_vt::{Callbacks, RenderState, Terminal};
    use ratatui::Terminal as RatatuiTerminal;
    use ratatui::backend::TestBackend;

    fn render_frame_with_defaults(
        foreground: Rgb,
        background: Rgb,
        cursor: Option<Rgb>,
    ) -> SurfaceRenderFrame {
        let mut terminal = Terminal::new(2, 1, 0, Callbacks::default()).unwrap();
        terminal.set_default_colors(Some(foreground), Some(background), cursor);
        let mut state = RenderState::new().unwrap();
        state.update(&mut terminal).unwrap();
        SurfaceRenderFrame {
            frame: state.build_frame().unwrap(),
            scrollback_rows: 0,
            palette_colors: [Rgb::default(); 256],
            palette_overridden: [false; 256],
        }
    }

    fn resolver<'a>(colors: &'a [Rgb; 256], overridden: &'a [bool; 256]) -> PaletteResolver<'a> {
        PaletteResolver {
            colors,
            overridden,
            default_fg: Rgb { r: 0x11, g: 0x22, b: 0x33 },
            default_bg: Rgb { r: 0x44, g: 0x55, b: 0x66 },
        }
    }

    #[test]
    fn palette_resolver_preserves_host_palette_for_non_overridden_entries() {
        let colors = [Rgb { r: 1, g: 2, b: 3 }; 256];
        let overridden = [false; 256];
        let resolver = resolver(&colors, &overridden);
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
            assert_eq!(resolver.resolve_fg(ColorSpec::Palette(idx as u8)), color);
        }
        assert_eq!(resolver.resolve_fg(ColorSpec::Palette(16)), Color::Indexed(16));
        assert_eq!(resolver.resolve_fg(ColorSpec::Palette(196)), Color::Indexed(196));
    }

    #[test]
    fn palette_resolver_renders_overridden_entries_as_rgb() {
        let mut colors = [Rgb::default(); 256];
        colors[1] = Rgb { r: 1, g: 2, b: 3 };
        colors[196] = Rgb { r: 4, g: 5, b: 6 };
        let mut overridden = [false; 256];
        overridden[1] = true;
        overridden[196] = true;
        let resolver = resolver(&colors, &overridden);

        assert_eq!(resolver.resolve_fg(ColorSpec::Palette(1)), Color::Rgb(1, 2, 3));
        assert_eq!(resolver.resolve_bg(ColorSpec::Palette(196)), Color::Rgb(4, 5, 6));
    }

    #[test]
    fn default_colors_are_resolved_by_visual_role() {
        let colors = [Rgb::default(); 256];
        let overridden = [false; 256];
        let resolver = resolver(&colors, &overridden);

        assert_eq!(resolver.resolve_fg(ColorSpec::Default), Color::Rgb(0x11, 0x22, 0x33));
        assert_eq!(resolver.resolve_bg(ColorSpec::Default), Color::Rgb(0x44, 0x55, 0x66));
        assert_eq!(
            resolver.blank_style(),
            Style::default().fg(Color::Rgb(0x11, 0x22, 0x33)).bg(Color::Rgb(0x44, 0x55, 0x66))
        );
    }

    #[test]
    fn explicit_rgb_does_not_inherit_a_default_role() {
        let colors = [Rgb::default(); 256];
        let overridden = [false; 256];
        let resolver = resolver(&colors, &overridden);
        let explicit = ColorSpec::Rgb(Rgb { r: 7, g: 8, b: 9 });

        assert_eq!(resolver.resolve_fg(explicit), Color::Rgb(7, 8, 9));
        assert_eq!(resolver.resolve_bg(explicit), Color::Rgb(7, 8, 9));
    }

    #[test]
    fn frame_default_order_and_spare_cells_follow_canonical_roles() {
        let foreground = Rgb { r: 0x11, g: 0x22, b: 0x33 };
        let background = Rgb { r: 0x44, g: 0x55, b: 0x66 };
        let cursor = Rgb { r: 0x77, g: 0x88, b: 0x99 };
        let render = render_frame_with_defaults(foreground, background, Some(cursor));
        let colors = PaletteResolver::from_frame(&render);

        assert_eq!(colors.resolve_fg(ColorSpec::Default), Color::Rgb(0x11, 0x22, 0x33));
        assert_eq!(colors.resolve_bg(ColorSpec::Default), Color::Rgb(0x44, 0x55, 0x66));
        assert_eq!(resolved_cursor_color(&render), cursor);
        let implicit_cursor = render_frame_with_defaults(foreground, background, None);
        assert_eq!(resolved_cursor_color(&implicit_cursor), foreground);

        let mut terminal = RatatuiTerminal::new(TestBackend::new(4, 2)).unwrap();
        terminal
            .draw(|frame| {
                draw_render_frame(
                    frame,
                    Rect { x: 0, y: 0, width: 4, height: 2 },
                    &render,
                    &Theme::default(),
                    |_, _| false,
                );
            })
            .unwrap();

        for position in [(2, 0), (3, 0), (0, 1), (3, 1)] {
            let cell = &terminal.backend().buffer()[position];
            assert_eq!(cell.fg, Color::Rgb(0x11, 0x22, 0x33));
            assert_eq!(cell.bg, Color::Rgb(0x44, 0x55, 0x66));
            assert_eq!(cell.symbol(), " ");
        }
    }
}
