use std::borrow::Cow;
use std::num::NonZeroU16;

use cmux_tui_core::{Rect, SurfaceRenderFrame};
use ghostty_vt::{Cell as VtCell, CellWidth, ColorSpec, CursorInfo, Rgb};
use ratatui::Frame;
use ratatui::buffer::{Buffer, CellDiffOption, CellWidth as RatatuiCellWidth};
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
    draw_render_frame_with_catalog(
        frame,
        HorizontalViewport { rect, source_x: 0 },
        render,
        theme,
        chrome,
        catalog(),
        selected,
    )
}

pub fn draw_render_frame_cropped(
    frame: &mut Frame,
    rect: Rect,
    source_x: u16,
    render: &SurfaceRenderFrame,
    theme: &Theme,
    chrome: &ChromeTheme,
    selected: impl Fn(u16, u16) -> bool,
) -> Option<(u16, u16)> {
    draw_render_frame_with_catalog(
        frame,
        HorizontalViewport { rect, source_x },
        render,
        theme,
        chrome,
        catalog(),
        selected,
    )
}

pub(crate) fn rendered_viewport_rect_cropped(
    rect: Rect,
    screen: RatatuiRect,
    render: &SurfaceRenderFrame,
    source_x: u16,
) -> Rect {
    let max_cols = rect.width.min(screen.width.saturating_sub(rect.x));
    let max_rows = rect.height.min(screen.height.saturating_sub(rect.y));
    let (snap_cols, snap_rows) = render.frame.size;
    Rect {
        x: rect.x,
        y: rect.y,
        width: snap_cols.saturating_sub(source_x).min(max_cols),
        height: snap_rows.min(max_rows),
    }
}

#[derive(Debug, Clone, Copy)]
struct HorizontalViewport {
    rect: Rect,
    source_x: u16,
}

fn draw_render_frame_with_catalog(
    frame: &mut Frame,
    viewport: HorizontalViewport,
    render: &SurfaceRenderFrame,
    theme: &Theme,
    chrome: &ChromeTheme,
    catalog: &Catalog,
    selected: impl Fn(u16, u16) -> bool,
) -> Option<(u16, u16)> {
    let HorizontalViewport { rect, source_x } = viewport;
    if rect.width == 0 || rect.height == 0 {
        return None;
    }
    let screen = frame.area();
    let max_cols = rect.width.min(screen.width.saturating_sub(rect.x)) as usize;
    let max_rows = rect.height.min(screen.height.saturating_sub(rect.y)) as usize;
    let (snap_cols, snap_rows) = render.frame.size;
    let live = rendered_viewport_rect_cropped(rect, screen, render, source_x);
    let live_cols = usize::from(live.width);
    let live_rows = usize::from(live.height);
    let colors = PaletteResolver::from_frame(render);
    let blank_style = colors.blank_style();
    let buf = frame.buffer_mut();

    for (row, cells) in render.frame.styled_rows().iter().enumerate() {
        if row >= live_rows {
            break;
        }
        let y = rect.y + row as u16;
        let source_x = usize::from(source_x);
        let available = cells.len().saturating_sub(source_x).min(live_cols);
        let source_end = source_x.saturating_add(available);
        for col in 0..available {
            let source_col = source_x + col;
            let x = rect.x + col as u16;
            let cell = &cells[source_col];
            let partial = partial_wide_cell(cells, source_x, source_end, source_col);
            let selected = selected_cell(cells, source_col, row, &selected);
            let target = &mut buf[(x, y)];
            apply_cell(target, cell, &colors, selected.then_some(theme));
            if partial {
                // A clipped half of a wide grapheme is rendered as a normal
                // blank cell. Clear the forced width applied above so Ratatui
                // does not skip the adjacent column during diffing.
                target.set_symbol(" ").set_diff_option(CellDiffOption::None);
            }
        }
        for col in available..live_cols {
            let x = rect.x + col as u16;
            let target = &mut buf[(x, y)];
            target.reset();
            target.set_symbol(" ").set_style(blank_style);
        }
    }

    if live_cols < max_cols || live_rows < max_rows {
        draw_foreign_viewport(
            buf, rect, max_cols, max_rows, live_cols, live_rows, snap_cols, snap_rows, chrome,
            catalog,
        );
    }

    render.frame.cursor.and_then(|cursor| {
        cropped_cursor_position(cursor, render.frame.styled_rows(), source_x, live_cols, live_rows)
            .map(|(x, y)| (rect.x + x, rect.y + y))
    })
}

/// Return whether a grid cell is selected, treating both columns of a wide
/// grapheme as one selectable unit. Selection ranges are normally normalized
/// to the lead cell, but checking the paired coordinate also keeps rendering
/// correct for callers that still provide a raw spacer-tail endpoint. A
/// wrapped grapheme's spacer head is a non-text continuation cell, so it must
/// never receive independent selection styling.
fn selected_cell(
    cells: &[VtCell],
    source_col: usize,
    row: usize,
    selected: &impl Fn(u16, u16) -> bool,
) -> bool {
    let selected_here =
        cells[source_col].width != CellWidth::SpacerHead && selected(source_col as u16, row as u16);
    let paired_col = match cells[source_col].width {
        CellWidth::Wide
            if cells
                .get(source_col.saturating_add(1))
                .is_some_and(|next| next.width == CellWidth::SpacerTail) =>
        {
            Some(source_col + 1)
        }
        CellWidth::SpacerTail
            if source_col > 0
                && cells
                    .get(source_col - 1)
                    .is_some_and(|previous| previous.width == CellWidth::Wide) =>
        {
            Some(source_col - 1)
        }
        CellWidth::Narrow | CellWidth::SpacerHead | CellWidth::Wide | CellWidth::SpacerTail => None,
    };
    selected_here || paired_col.is_some_and(|col| selected(col as u16, row as u16))
}

/// Return a cursor position that is drawable in a horizontally cropped frame.
/// Ghostty can report a cursor on a wide grapheme's trailing spacer. That
/// spacer is not an independent drawable cell, so place the cursor on the
/// grapheme lead before applying crop bounds.
fn cropped_cursor_position(
    cursor: CursorInfo,
    rows: &[Vec<VtCell>],
    source_x: u16,
    live_cols: usize,
    live_rows: usize,
) -> Option<(u16, u16)> {
    let mut x = cursor.x;
    let row = rows.get(cursor.y as usize)?;
    if x > 0
        && row.get(x as usize).is_some_and(|cell| cell.width == CellWidth::SpacerTail)
        && row.get((x - 1) as usize).is_some_and(|cell| cell.width == CellWidth::Wide)
    {
        x -= 1;
    }

    if x < source_x || usize::from(x - source_x) >= live_cols || (cursor.y as usize) >= live_rows {
        return None;
    }

    // A wide lead is drawable only when its trailing spacer is also inside
    // the crop. This matches partial_wide_cell, which blanks split pairs.
    if row.get(x as usize).is_some_and(|cell| cell.width == CellWidth::Wide)
        && (usize::from(x - source_x).saturating_add(1) >= live_cols
            || !row
                .get(x.saturating_add(1) as usize)
                .is_some_and(|cell| cell.width == CellWidth::SpacerTail))
    {
        return None;
    }

    Some((x - source_x, cursor.y))
}

fn partial_wide_cell(
    cells: &[VtCell],
    source_start: usize,
    source_end: usize,
    source_col: usize,
) -> bool {
    match cells[source_col].width {
        CellWidth::Wide => cells
            .get(source_col.saturating_add(1))
            .filter(|_| source_col.saturating_add(1) < source_end)
            .is_none_or(|next| next.width != CellWidth::SpacerTail),
        CellWidth::SpacerTail => {
            source_col == source_start
                || cells
                    .get(source_col.saturating_sub(1))
                    .is_none_or(|previous| previous.width != CellWidth::Wide)
        }
        CellWidth::Narrow | CellWidth::SpacerHead => false,
    }
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
    target.reset();
    let text = renderable_cell_text(&cell.text);
    target.set_symbol(&text);
    let columns = match cell.width {
        CellWidth::Wide => 2,
        CellWidth::Narrow | CellWidth::SpacerTail | CellWidth::SpacerHead => 1,
    };
    if text.cell_width() != columns {
        target.set_diff_option(CellDiffOption::ForcedWidth(
            NonZeroU16::new(columns).expect("Ghostty cells always occupy at least one column"),
        ));
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

fn renderable_cell_text(text: &str) -> Cow<'_, str> {
    if text.is_empty() {
        return Cow::Borrowed(" ");
    }
    if !text.chars().any(char::is_control) {
        return Cow::Borrowed(text);
    }
    let sanitized = text.chars().filter(|character| !character.is_control()).collect::<String>();
    if sanitized.is_empty() { Cow::Borrowed(" ") } else { Cow::Owned(sanitized) }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ghostty_vt::{Callbacks, CursorShape, RenderState, Terminal};
    use ratatui::Terminal as RatatuiTerminal;
    use ratatui::backend::TestBackend;
    use ratatui::buffer::{CellDiffOption, CellWidth as RatatuiCellWidth};
    use std::num::NonZeroU16;

    #[test]
    fn terminal_cells_drop_control_characters_before_ratatui_diffing() {
        assert_eq!(renderable_cell_text("\r").as_ref(), " ");
        assert_eq!(renderable_cell_text("a\x1bb").as_ref(), "ab");
        assert_eq!(renderable_cell_text("plain").as_ref(), "plain");
    }

    fn render_frame(cols: u16, rows: u16) -> SurfaceRenderFrame {
        let mut terminal = Terminal::new(cols, rows, 0, Callbacks::default()).unwrap();
        terminal.vt_write(b"live");
        let mut state = RenderState::new().unwrap();
        state.update(&mut terminal).unwrap();
        SurfaceRenderFrame {
            frame: state.build_frame().unwrap(),
            content_generation: 1,
            scrollback_rows: 0,
            history_epoch: terminal.history_epoch(),
            pointer_semantics: terminal.pointer_semantic_snapshot(),
            palette_colors: std::array::from_fn(|idx| state.palette_color(idx as u8)),
            palette_overridden: std::array::from_fn(|idx| state.palette_overridden(idx as u8)),
        }
    }

    fn draw_grid(
        render: &SurfaceRenderFrame,
        rect: Rect,
        chrome: ChromeTheme,
        locale: &str,
    ) -> RatatuiTerminal<TestBackend> {
        let width = rect.x + rect.width;
        let height = rect.y + rect.height;
        let mut terminal = RatatuiTerminal::new(TestBackend::new(width, height)).unwrap();
        terminal
            .draw(|frame| {
                draw_render_frame_with_catalog(
                    frame,
                    HorizontalViewport { rect, source_x: 0 },
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

    #[test]
    fn cropped_grid_starts_at_the_requested_source_column() {
        let mut terminal = Terminal::new(8, 1, 0, Callbacks::default()).unwrap();
        terminal.vt_write(b"abcdefgh");
        let mut state = RenderState::new().unwrap();
        state.update(&mut terminal).unwrap();
        let render = SurfaceRenderFrame {
            frame: state.build_frame().unwrap(),
            content_generation: 1,
            scrollback_rows: 0,
            history_epoch: terminal.history_epoch(),
            pointer_semantics: terminal.pointer_semantic_snapshot(),
            palette_colors: std::array::from_fn(|idx| state.palette_color(idx as u8)),
            palette_overridden: std::array::from_fn(|idx| state.palette_overridden(idx as u8)),
        };
        let mut output = RatatuiTerminal::new(TestBackend::new(3, 1)).unwrap();
        output
            .draw(|frame| {
                draw_render_frame_with_catalog(
                    frame,
                    HorizontalViewport {
                        rect: Rect { x: 0, y: 0, width: 3, height: 1 },
                        source_x: 3,
                    },
                    &render,
                    &Theme::default(),
                    &ChromeTheme::dark(),
                    crate::localization::catalog_for_locale("en_US.UTF-8"),
                    |_, _| false,
                );
            })
            .unwrap();

        assert_eq!(row_text(output.backend().buffer(), 0, 0, 3), "def");
    }

    #[test]
    fn cropped_grid_blanks_partial_wide_glyphs_at_both_edges() {
        let mut terminal = Terminal::new(6, 1, 0, Callbacks::default()).unwrap();
        terminal.vt_write("a界bc".as_bytes());
        let mut state = RenderState::new().unwrap();
        state.update(&mut terminal).unwrap();
        let render = SurfaceRenderFrame {
            frame: state.build_frame().unwrap(),
            content_generation: 1,
            scrollback_rows: 0,
            history_epoch: terminal.history_epoch(),
            pointer_semantics: terminal.pointer_semantic_snapshot(),
            palette_colors: std::array::from_fn(|idx| state.palette_color(idx as u8)),
            palette_overridden: std::array::from_fn(|idx| state.palette_overridden(idx as u8)),
        };
        let draw_crop = |source_x| {
            let mut output = RatatuiTerminal::new(TestBackend::new(2, 1)).unwrap();
            output
                .draw(|frame| {
                    draw_render_frame_with_catalog(
                        frame,
                        HorizontalViewport {
                            rect: Rect { x: 0, y: 0, width: 2, height: 1 },
                            source_x,
                        },
                        &render,
                        &Theme::default(),
                        &ChromeTheme::dark(),
                        crate::localization::catalog_for_locale("en_US.UTF-8"),
                        |_, _| false,
                    );
                })
                .unwrap();
            output
        };

        let clipped_lead = draw_crop(0);
        assert_eq!(row_text(clipped_lead.backend().buffer(), 0, 0, 2), "a ");
        assert_eq!(clipped_lead.backend().buffer()[(1, 0)].diff_option, CellDiffOption::None);

        let complete_glyph = draw_crop(1);
        assert_eq!(complete_glyph.backend().buffer()[(0, 0)].symbol(), "界");
        assert_eq!(complete_glyph.backend().buffer()[(1, 0)].symbol(), " ");

        let clipped_tail = draw_crop(2);
        assert_eq!(row_text(clipped_tail.backend().buffer(), 0, 0, 2), " b");
        assert_eq!(clipped_tail.backend().buffer()[(0, 0)].diff_option, CellDiffOption::None);
    }

    #[test]
    fn cropped_grid_places_a_wide_cell_cursor_on_the_lead_cell() {
        let mut terminal = Terminal::new(6, 1, 0, Callbacks::default()).unwrap();
        terminal.vt_write("a界bc".as_bytes());
        let mut state = RenderState::new().unwrap();
        state.update(&mut terminal).unwrap();
        let mut render = SurfaceRenderFrame {
            frame: state.build_frame().unwrap(),
            content_generation: 1,
            scrollback_rows: 0,
            history_epoch: terminal.history_epoch(),
            pointer_semantics: terminal.pointer_semantic_snapshot(),
            palette_colors: std::array::from_fn(|idx| state.palette_color(idx as u8)),
            palette_overridden: std::array::from_fn(|idx| state.palette_overridden(idx as u8)),
        };
        // A terminal cursor may be reported on the trailing spacer of a wide
        // grapheme. The renderer must use the lead column for its placement.
        render.frame.cursor =
            Some(CursorInfo { x: 2, y: 0, shape: CursorShape::Block, blinking: false });

        let mut output = RatatuiTerminal::new(TestBackend::new(3, 1)).unwrap();
        let mut cursor = None;
        output
            .draw(|frame| {
                cursor = draw_render_frame_with_catalog(
                    frame,
                    HorizontalViewport {
                        rect: Rect { x: 0, y: 0, width: 3, height: 1 },
                        source_x: 1,
                    },
                    &render,
                    &Theme::default(),
                    &ChromeTheme::dark(),
                    crate::localization::catalog_for_locale("en_US.UTF-8"),
                    |_, _| false,
                );
            })
            .unwrap();

        assert_eq!(cursor, Some((0, 0)));

        // Cropping from the spacer itself must not leave a cursor on a blank
        // partial-glyph cell.
        let mut output = RatatuiTerminal::new(TestBackend::new(2, 1)).unwrap();
        let mut cursor = None;
        output
            .draw(|frame| {
                cursor = draw_render_frame_with_catalog(
                    frame,
                    HorizontalViewport {
                        rect: Rect { x: 0, y: 0, width: 2, height: 1 },
                        source_x: 2,
                    },
                    &render,
                    &Theme::default(),
                    &ChromeTheme::dark(),
                    crate::localization::catalog_for_locale("en_US.UTF-8"),
                    |_, _| false,
                );
            })
            .unwrap();
        assert_eq!(cursor, None);

        // A lead at the right crop edge is also blanked because its spacer
        // falls outside the live width, so it must not receive a cursor.
        let mut output = RatatuiTerminal::new(TestBackend::new(1, 1)).unwrap();
        let mut cursor = None;
        output
            .draw(|frame| {
                cursor = draw_render_frame_with_catalog(
                    frame,
                    HorizontalViewport {
                        rect: Rect { x: 0, y: 0, width: 1, height: 1 },
                        source_x: 1,
                    },
                    &render,
                    &Theme::default(),
                    &ChromeTheme::dark(),
                    crate::localization::catalog_for_locale("en_US.UTF-8"),
                    |_, _| false,
                );
            })
            .unwrap();
        assert_eq!(cursor, None);
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
            content_generation: 1,
            scrollback_rows: 0,
            history_epoch: terminal.history_epoch(),
            pointer_semantics: terminal.pointer_semantic_snapshot(),
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
    fn terminal_control_cells_render_as_blanks() {
        let colors = [Rgb::default(); 256];
        let overridden = [false; 256];
        let resolver = resolver(&colors, &overridden);

        for text in ["\0", "\t", "\r"] {
            let cell = VtCell { text: text.to_string(), ..VtCell::default() };
            let mut target = ratatui::buffer::Cell::default();
            apply_cell(&mut target, &cell, &resolver, None);
            assert_eq!(target.symbol(), " ");
        }
    }

    #[test]
    fn terminal_cells_keep_ghostty_width_for_ratatui_diffing() {
        let colors = [Rgb::default(); 256];
        let overridden = [false; 256];
        let resolver = resolver(&colors, &overridden);
        let cases = [
            (CellWidth::Narrow, 1, "ｶﾞ", true),
            (CellWidth::Wide, 2, "x", true),
            (CellWidth::Wide, 2, "界", false),
            (CellWidth::SpacerTail, 1, "", false),
            (CellWidth::SpacerHead, 1, "", false),
        ];

        for (width, columns, text, forced) in cases {
            let cell = VtCell { text: text.to_string(), width, ..VtCell::default() };
            let mut target = ratatui::buffer::Cell::default();
            apply_cell(&mut target, &cell, &resolver, None);
            assert_eq!(
                target.cell_width(),
                columns,
                "Ghostty width {width:?} must remain authoritative"
            );
            let expected_diff_option = forced
                .then(|| CellDiffOption::ForcedWidth(NonZeroU16::new(columns).unwrap()))
                .unwrap_or(CellDiffOption::None);
            assert_eq!(target.diff_option, expected_diff_option);
        }
    }

    #[test]
    fn selected_wide_glyph_styles_both_grid_cells() {
        let mut terminal = Terminal::new(6, 1, 0, Callbacks::default()).unwrap();
        terminal.vt_write("a界b".as_bytes());
        let mut state = RenderState::new().unwrap();
        state.update(&mut terminal).unwrap();
        let render = SurfaceRenderFrame {
            frame: state.build_frame().unwrap(),
            content_generation: 1,
            scrollback_rows: 0,
            history_epoch: terminal.history_epoch(),
            pointer_semantics: terminal.pointer_semantic_snapshot(),
            palette_colors: std::array::from_fn(|idx| state.palette_color(idx as u8)),
            palette_overridden: std::array::from_fn(|idx| state.palette_overridden(idx as u8)),
        };
        let mut output = RatatuiTerminal::new(TestBackend::new(4, 1)).unwrap();
        output
            .draw(|frame| {
                draw_render_frame_with_catalog(
                    frame,
                    HorizontalViewport {
                        rect: Rect { x: 0, y: 0, width: 4, height: 1 },
                        source_x: 0,
                    },
                    &render,
                    &Theme::default(),
                    &ChromeTheme::dark(),
                    crate::localization::catalog_for_locale("en_US.UTF-8"),
                    |col, row| col == 1 && row == 0,
                );
            })
            .unwrap();

        let expected_bg = Theme::default().selection_bg;
        assert_eq!(output.backend().buffer()[(1, 0)].bg, expected_bg);
        assert_eq!(output.backend().buffer()[(2, 0)].bg, expected_bg);
    }

    #[test]
    fn wrapped_wide_selection_keeps_the_spacer_head_unselected() {
        let mut terminal = Terminal::new(4, 3, 0, Callbacks::default()).unwrap();
        terminal.vt_write("ABC橋D".as_bytes());
        let mut state = RenderState::new().unwrap();
        state.update(&mut terminal).unwrap();
        let render = SurfaceRenderFrame {
            frame: state.build_frame().unwrap(),
            content_generation: 1,
            scrollback_rows: 0,
            history_epoch: terminal.history_epoch(),
            pointer_semantics: terminal.pointer_semantic_snapshot(),
            palette_colors: std::array::from_fn(|idx| state.palette_color(idx as u8)),
            palette_overridden: std::array::from_fn(|idx| state.palette_overridden(idx as u8)),
        };
        let mut output = RatatuiTerminal::new(TestBackend::new(4, 3)).unwrap();
        output
            .draw(|frame| {
                draw_render_frame_with_catalog(
                    frame,
                    HorizontalViewport {
                        rect: Rect { x: 0, y: 0, width: 4, height: 3 },
                        source_x: 0,
                    },
                    &render,
                    &Theme::default(),
                    &ChromeTheme::dark(),
                    crate::localization::catalog_for_locale("en_US.UTF-8"),
                    // A row-major range can include the physical spacer head,
                    // but only the wrapped glyph's lead row is selectable.
                    |col, row| (col == 3 && row == 0) || (col <= 1 && row == 1),
                );
            })
            .unwrap();

        let buffer = output.backend().buffer();
        let selection_bg = Theme::default().selection_bg;
        assert_ne!(buffer[(3, 0)].bg, selection_bg);
        assert_eq!(buffer[(0, 1)].bg, selection_bg);
        assert_eq!(buffer[(1, 1)].bg, selection_bg);
    }

    #[test]
    fn frame_default_order_and_live_blank_cells_follow_canonical_roles() {
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
                    &ChromeTheme::dark(),
                    |_, _| false,
                );
            })
            .unwrap();

        // This cell belongs to the 2x1 terminal frame and is not occupied by
        // the cursor. Cells outside that frame intentionally use the foreign
        // viewport chrome styling, which is covered below.
        let cell = &terminal.backend().buffer()[(1, 0)];
        assert_eq!(cell.fg, Color::Rgb(0x11, 0x22, 0x33));
        assert_eq!(cell.bg, Color::Rgb(0x44, 0x55, 0x66));
        assert_eq!(cell.symbol(), " ");
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
