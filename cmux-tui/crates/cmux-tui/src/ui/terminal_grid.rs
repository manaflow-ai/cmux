use cmux_tui_core::{Rect, SurfaceRenderFrame};
use ghostty_vt::{Cell as VtCell, ColorSpec, Rgb};
use ratatui::Frame;
use ratatui::buffer::Buffer;
use ratatui::layout::Rect as RatatuiRect;
use ratatui::style::{Color, Modifier, Style};

use crate::config::{ChromeTheme, Theme};
use crate::localization::{Catalog, ForeignViewportMessages, catalog};

pub fn draw_render_frame(
    frame: &mut Frame,
    rect: Rect,
    render: &SurfaceRenderFrame,
    theme: &Theme,
    chrome: &ChromeTheme,
    selected: impl Fn(u16, u16) -> bool,
) -> Option<(u16, u16)> {
    draw_render_frame_with_catalog(frame, rect, render, theme, chrome, catalog(), selected)
}

pub(crate) fn rendered_viewport_rect(
    rect: Rect,
    screen: RatatuiRect,
    render: &SurfaceRenderFrame,
) -> Rect {
    let max_cols = rect.width.min(screen.width.saturating_sub(rect.x));
    let max_rows = rect.height.min(screen.height.saturating_sub(rect.y));
    let (snap_cols, snap_rows) = render.frame.size;
    Rect { x: rect.x, y: rect.y, width: snap_cols.min(max_cols), height: snap_rows.min(max_rows) }
}

fn draw_render_frame_with_catalog(
    frame: &mut Frame,
    rect: Rect,
    render: &SurfaceRenderFrame,
    theme: &Theme,
    chrome: &ChromeTheme,
    catalog: &Catalog,
    selected: impl Fn(u16, u16) -> bool,
) -> Option<(u16, u16)> {
    if rect.width == 0 || rect.height == 0 {
        return None;
    }
    let screen = frame.area();
    let max_cols = rect.width.min(screen.width.saturating_sub(rect.x)) as usize;
    let max_rows = rect.height.min(screen.height.saturating_sub(rect.y)) as usize;
    let (snap_cols, snap_rows) = render.frame.size;
    let live = rendered_viewport_rect(rect, screen, render);
    let live_cols = usize::from(live.width);
    let live_rows = usize::from(live.height);
    let colors = PaletteResolver::from_frame(render);
    let buf = frame.buffer_mut();

    for (row, cells) in render.frame.styled_rows().iter().enumerate() {
        if row >= live_rows {
            break;
        }
        let y = rect.y + row as u16;
        for (col, cell) in cells.iter().enumerate() {
            if col >= live_cols {
                break;
            }
            let x = rect.x + col as u16;
            let selected = selected(col as u16, row as u16);
            apply_cell(&mut buf[(x, y)], cell, &colors, selected.then_some(theme));
        }
        for col in cells.len()..live_cols {
            let x = rect.x + col as u16;
            buf[(x, y)].set_symbol(" ").set_style(Style::default());
        }
    }

    if live_cols < max_cols || live_rows < max_rows {
        draw_foreign_viewport(
            buf, rect, max_cols, max_rows, live_cols, live_rows, snap_cols, snap_rows, chrome,
            catalog,
        );
    }

    render
        .frame
        .cursor
        .filter(|cursor| (cursor.x as usize) < live_cols && (cursor.y as usize) < live_rows)
        .map(|cursor| (rect.x + cursor.x, rect.y + cursor.y))
}

#[allow(clippy::too_many_arguments)]
fn draw_foreign_viewport(
    buf: &mut Buffer,
    rect: Rect,
    max_cols: usize,
    max_rows: usize,
    live_cols: usize,
    live_rows: usize,
    snap_cols: u16,
    snap_rows: u16,
    chrome: &ChromeTheme,
    catalog: &Catalog,
) {
    let dead_style = Style::default().bg(chrome.foreign_viewport_bg).add_modifier(Modifier::DIM);
    for row in 0..live_rows {
        for col in live_cols..max_cols {
            let cell = &mut buf[(rect.x + col as u16, rect.y + row as u16)];
            cell.reset();
            cell.set_symbol(" ").set_style(dead_style);
        }
    }
    for row in live_rows..max_rows {
        for col in 0..max_cols {
            let cell = &mut buf[(rect.x + col as u16, rect.y + row as u16)];
            cell.reset();
            cell.set_symbol(" ").set_style(dead_style);
        }
    }

    let boundary_style = dead_style.fg(chrome.foreign_viewport_boundary_fg);
    let has_right_band = live_cols < max_cols;
    let has_bottom_band = live_rows < max_rows;
    if has_right_band {
        let x = rect.x + live_cols as u16;
        for row in 0..live_rows {
            buf[(x, rect.y + row as u16)].set_symbol("│").set_style(boundary_style);
        }
    }
    if has_bottom_band {
        let y = rect.y + live_rows as u16;
        for col in 0..live_cols {
            buf[(rect.x + col as u16, y)].set_symbol("─").set_style(boundary_style);
        }
    }
    if has_right_band && has_bottom_band {
        buf[(rect.x + live_cols as u16, rect.y + live_rows as u16)]
            .set_symbol("┘")
            .set_style(boundary_style);
    }

    draw_foreign_size_hint(
        buf,
        rect,
        max_cols,
        max_rows,
        live_cols,
        live_rows,
        has_right_band,
        has_bottom_band,
        &catalog.foreign_viewport,
        snap_cols,
        snap_rows,
        dead_style.fg(chrome.foreign_viewport_hint_fg),
    );
}

#[allow(clippy::too_many_arguments)]
fn draw_foreign_size_hint(
    buf: &mut Buffer,
    rect: Rect,
    max_cols: usize,
    max_rows: usize,
    live_cols: usize,
    live_rows: usize,
    has_right_band: bool,
    has_bottom_band: bool,
    messages: &ForeignViewportMessages,
    snap_cols: u16,
    snap_rows: u16,
    style: Style,
) {
    let hint_width = messages.hint_width(snap_cols, snap_rows);
    let right_width = max_cols.saturating_sub(live_cols);
    let bottom_height = max_rows.saturating_sub(live_rows);

    let placement =
        if has_right_band && (right_width >= hint_width.saturating_add(2) || !has_bottom_band) {
            // Match the native frontend: one-cell padding from the right hairline
            // and, when possible, from the live viewport's top edge.
            let x = live_cols.saturating_add(1);
            let y = usize::from(live_rows > 2);
            let trailing_padding = usize::from(right_width > 2);
            let available = max_cols.saturating_sub(x.saturating_add(trailing_padding));
            if available > 0 && y < live_rows { Some((x, y, available)) } else { None }
        } else if has_bottom_band && bottom_height >= 2 && max_cols >= 3 {
            // If the right band cannot hold the explanation, put it one row below
            // the bottom hairline and end it at the live viewport's bottom-right
            // corner when space allows.
            let available = max_cols - 2;
            let width = hint_width.min(available);
            let x = live_cols.saturating_sub(width.saturating_add(1)).max(1);
            Some((x, live_rows + 1, width))
        } else {
            None
        };

    let Some((x, y, width)) = placement else { return };
    let Some(hint) = messages.hint(snap_cols, snap_rows) else { return };
    buf.set_stringn(rect.x + x as u16, rect.y + y as u16, hint.as_str(), width, style);
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
    target.reset();
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
    use cmux_tui_core::SurfaceRenderFrame;
    use ghostty_vt::{Callbacks, RenderState, Terminal as VtTerminal};
    use ratatui::Terminal;
    use ratatui::backend::TestBackend;

    fn render_frame(cols: u16, rows: u16) -> SurfaceRenderFrame {
        let mut terminal = VtTerminal::new(cols, rows, 0, Callbacks::default()).unwrap();
        terminal.vt_write(b"live");
        let mut state = RenderState::new().unwrap();
        state.update(&mut terminal).unwrap();
        SurfaceRenderFrame {
            frame: state.build_frame().unwrap(),
            scrollback_rows: 0,
            palette_colors: std::array::from_fn(|idx| state.palette_color(idx as u8)),
            palette_overridden: std::array::from_fn(|idx| state.palette_overridden(idx as u8)),
        }
    }

    fn draw_grid(
        render: &SurfaceRenderFrame,
        rect: Rect,
        chrome: ChromeTheme,
        locale: &str,
    ) -> Terminal<TestBackend> {
        let width = rect.x + rect.width;
        let height = rect.y + rect.height;
        let mut terminal = Terminal::new(TestBackend::new(width, height)).unwrap();
        terminal
            .draw(|frame| {
                draw_render_frame_with_catalog(
                    frame,
                    rect,
                    render,
                    &Theme::default(),
                    &chrome,
                    crate::localization::catalog_for_locale(locale),
                    |_, _| false,
                );
            })
            .unwrap();
        terminal
    }

    fn row_text(buffer: &Buffer, y: u16, x: u16, width: u16) -> String {
        (x..x + width).map(|cell_x| buffer[(cell_x, y)].symbol()).collect()
    }

    fn english_foreign_viewport_hint(
        cols: u16,
        rows: u16,
    ) -> crate::localization::ForeignViewportHint {
        crate::localization::catalog_for_locale("en_US.UTF-8")
            .foreign_viewport
            .hint(cols, rows)
            .expect("English hint fits inline")
    }

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

    #[test]
    fn foreign_viewport_dims_bands_draws_boundaries_and_places_hint_at_corner() {
        let render = render_frame(12, 5);
        let rect = Rect { x: 2, y: 1, width: 70, height: 10 };
        let chrome = ChromeTheme::dark();
        let terminal = draw_grid(&render, rect, chrome, "en_US.UTF-8");
        let buffer = terminal.backend().buffer();
        let boundary_x = rect.x + 12;
        let boundary_y = rect.y + 5;

        let right_dead = &buffer[(boundary_x + 2, rect.y + 3)];
        assert_eq!(right_dead.bg, chrome.foreign_viewport_bg);
        assert!(right_dead.modifier.contains(Modifier::DIM));
        let bottom_dead = &buffer[(rect.x + 3, boundary_y + 2)];
        assert_eq!(bottom_dead.bg, chrome.foreign_viewport_bg);
        assert!(bottom_dead.modifier.contains(Modifier::DIM));

        assert_eq!(buffer[(boundary_x, rect.y + 2)].symbol(), "│");
        assert_eq!(buffer[(rect.x + 3, boundary_y)].symbol(), "─");
        assert_eq!(buffer[(boundary_x, boundary_y)].symbol(), "┘");
        let expected_hint = english_foreign_viewport_hint(12, 5);
        assert!(
            row_text(buffer, rect.y + 1, boundary_x + 1, rect.width - 13)
                .starts_with(expected_hint.as_str())
        );
    }

    #[test]
    fn foreign_viewport_draws_injected_catalog_locale() {
        let render = render_frame(12, 5);
        let rect = Rect { x: 0, y: 0, width: 80, height: 10 };
        let terminal = draw_grid(&render, rect, ChromeTheme::dark(), "ja_JP.UTF-8");
        let buffer = terminal.backend().buffer();
        let expected = crate::localization::catalog_for_locale("ja_JP.UTF-8")
            .foreign_viewport
            .hint(12, 5)
            .expect("Japanese hint fits inline");

        let rendered = row_text(buffer, 1, 13, rect.width - 13).replace(' ', "");
        assert!(rendered.starts_with(&expected.as_str().replace(' ', "")));
    }

    #[test]
    fn foreign_viewport_replaces_stale_dead_cells_without_touching_live_cells() {
        let rect = Rect { x: 0, y: 0, width: 5, height: 4 };
        let mut buffer = Buffer::empty(ratatui::layout::Rect::new(0, 0, 5, 4));
        for y in 0..4 {
            for x in 0..5 {
                buffer[(x, y)]
                    .set_symbol("x")
                    .set_style(Style::default().fg(Color::Red).add_modifier(Modifier::BOLD));
            }
        }
        let chrome = ChromeTheme::dark();

        draw_foreign_viewport(
            &mut buffer,
            rect,
            5,
            4,
            3,
            2,
            3,
            2,
            &chrome,
            crate::localization::catalog_for_locale("en_US.UTF-8"),
        );

        assert_eq!(buffer[(1, 1)].symbol(), "x");
        assert_eq!(buffer[(1, 1)].fg, Color::Red);
        assert!(buffer[(1, 1)].modifier.contains(Modifier::BOLD));
        for (x, y) in [(4, 0), (4, 2)] {
            let dead = &buffer[(x, y)];
            assert_eq!(dead.symbol(), " ");
            assert_eq!(dead.bg, chrome.foreign_viewport_bg);
            assert_eq!(dead.fg, Color::Reset);
            assert!(!dead.modifier.contains(Modifier::BOLD));
        }
    }

    #[test]
    fn foreign_viewport_dead_space_adapts_to_light_and_dark_chrome() {
        let render = render_frame(4, 2);
        let rect = Rect { x: 0, y: 0, width: 8, height: 4 };
        let dark = ChromeTheme::dark();
        let light = ChromeTheme::light();
        let dark_terminal = draw_grid(&render, rect, dark, "en_US.UTF-8");
        let light_terminal = draw_grid(&render, rect, light, "en_US.UTF-8");

        assert_eq!(dark_terminal.backend().buffer()[(6, 1)].bg, dark.foreign_viewport_bg);
        assert_eq!(light_terminal.backend().buffer()[(6, 1)].bg, light.foreign_viewport_bg);
        assert_ne!(dark.foreign_viewport_bg, light.foreign_viewport_bg);
    }

    #[test]
    fn matching_viewport_draws_no_dead_space_boundary_or_hint() {
        let render = render_frame(12, 5);
        let rect = Rect { x: 0, y: 0, width: 12, height: 5 };
        let chrome = ChromeTheme::dark();
        let terminal = draw_grid(&render, rect, chrome, "en_US.UTF-8");
        let buffer = terminal.backend().buffer();

        for y in 0..rect.height {
            for x in 0..rect.width {
                let cell = &buffer[(x, y)];
                assert_ne!(cell.bg, chrome.foreign_viewport_bg);
                assert!(!cell.modifier.contains(Modifier::DIM));
                assert!(!matches!(cell.symbol(), "│" | "─" | "┘"));
            }
        }
        assert!(!row_text(buffer, 0, 0, rect.width).contains(
            crate::localization::catalog_for_locale("en_US.UTF-8").foreign_viewport.terminal_grid
        ));
    }
}
