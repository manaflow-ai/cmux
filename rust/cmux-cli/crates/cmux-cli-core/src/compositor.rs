//! Multi-pane compositor.
//!
//! Turns a list of (rect, libghostty-vt `Terminal`) into a flat cell grid,
//! then emits ANSI bytes with cursor positioning per row. Terminal cells keep
//! libghostty's raw color intent: default stays default, palette stays
//! palette-indexed, and only explicit RGB stays RGB. This is the rendering
//! path the server uses for composed panes and chrome.
//!
//! The emitter does a full redraw every frame. Dirty-rect diffing is a
//! follow-up optimisation — the project rule is correctness first, and
//! mere full-frame redraws already beat single-pane passthrough once the
//! layout has chrome (sidebar, status bar, pane borders) to track.

use libghostty_vt::Terminal;
use libghostty_vt::render::{
    CellIteration, CellIterator, CursorVisualStyle, RenderState, RowIterator,
};
use libghostty_vt::screen::{CellContentTag, CellWide};
pub use libghostty_vt::style::{RgbColor, StyleColor};
use unicode_width::UnicodeWidthStr;

use crate::layout::Rect;

/// One cell of the composed screen.
///
/// Colors are stored as `StyleColor`. Terminal content keeps libghostty's raw
/// style intent so palette-indexed output still uses the host terminal's
/// active palette. Chrome can still use truecolor cells where cmux owns the
/// color.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Cell {
    /// Zero-or-more grapheme codepoints joined into a display string. Empty
    /// string means "blank, draw a space."
    pub grapheme: String,
    /// Display columns occupied by this cell's grapheme. Wide-character tail
    /// cells use width 0 and are not emitted as standalone spaces.
    pub width: u8,
    pub is_continuation: bool,
    pub fg: StyleColor,
    pub bg: StyleColor,
    pub bold: bool,
    pub italic: bool,
    pub underline: bool,
    pub faint: bool,
    pub strikethrough: bool,
    pub reverse: bool,
    pub blink: bool,
}

impl Default for Cell {
    fn default() -> Self {
        Self {
            grapheme: String::new(),
            width: 1,
            is_continuation: false,
            fg: StyleColor::None,
            bg: StyleColor::None,
            bold: false,
            italic: false,
            underline: false,
            faint: false,
            strikethrough: false,
            reverse: false,
            blink: false,
        }
    }
}

/// Composed framebuffer.
#[derive(Debug, Clone)]
pub struct Frame {
    pub cols: u16,
    pub rows: u16,
    /// `cells[row][col]`. Always `rows × cols` after `new`.
    pub cells: Vec<Vec<Cell>>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TerminalGridSnapshot {
    pub cols: u16,
    pub rows: u16,
    pub cells: Vec<TerminalGridCell>,
    pub cursor: Option<TerminalCursor>,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct TerminalGridDefaultColors {
    pub foreground: Option<RgbColor>,
    pub background: Option<RgbColor>,
    pub palette: Option<[RgbColor; 256]>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TerminalGridCell {
    pub text: String,
    pub width: u8,
    pub fg: RgbColor,
    pub bg: RgbColor,
    pub bold: bool,
    pub italic: bool,
    pub underline: bool,
    pub faint: bool,
    pub blink: bool,
    pub strikethrough: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TerminalCursor {
    pub col: u16,
    pub row: u16,
    pub visible: bool,
    pub style: TerminalCursorStyle,
    pub blink: bool,
    pub color: Option<RgbColor>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TerminalCursorStyle {
    Block,
    HollowBlock,
    Underline,
    Bar,
}

impl Frame {
    #[must_use]
    pub fn new(cols: u16, rows: u16) -> Self {
        let mut cells = Vec::with_capacity(rows as usize);
        for _ in 0..rows {
            let row = vec![Cell::default(); cols as usize];
            cells.push(row);
        }
        Self { cols, rows, cells }
    }

    /// Paste one cell into the frame at (row, col). Out-of-bounds writes
    /// are silently dropped so callers can pass pane rects without
    /// bounds-checking first.
    pub fn put(&mut self, row: u16, col: u16, cell: Cell) {
        if row >= self.rows || col >= self.cols {
            return;
        }
        self.cells[row as usize][col as usize] = cell;
    }

    /// Paint one row of styled text into the frame starting at (row, col).
    /// Text beyond `frame.cols` is clipped. Convenience wrapper that takes
    /// RGB colors — for palette / no-color, construct `Cell` manually.
    pub fn paint_text(
        &mut self,
        row: u16,
        col: u16,
        text: &str,
        fg: Option<RgbColor>,
        bg: Option<RgbColor>,
    ) {
        let fg = fg.map_or(StyleColor::None, StyleColor::Rgb);
        let bg = bg.map_or(StyleColor::None, StyleColor::Rgb);
        let mut x = col;
        for ch in text.chars() {
            let grapheme = ch.to_string();
            let width = cell_display_width(&grapheme);
            let width_cols = u16::from(width);
            if x >= self.cols || x.saturating_add(width_cols) > self.cols {
                break;
            }
            self.put(
                row,
                x,
                Cell {
                    grapheme,
                    width,
                    fg,
                    bg,
                    ..Cell::default()
                },
            );
            for tail in 1..width_cols {
                self.put(
                    row,
                    x.saturating_add(tail),
                    Cell {
                        width: 0,
                        is_continuation: true,
                        fg,
                        bg,
                        ..Cell::default()
                    },
                );
            }
            x = x.saturating_add(width_cols);
        }
    }

    /// Fill a rectangle with a single bg color + blank grapheme.
    pub fn fill_rect(&mut self, rect: Rect, bg: Option<RgbColor>) {
        let bg = bg.map_or(StyleColor::None, StyleColor::Rgb);
        for r in rect.row..rect.row.saturating_add(rect.rows) {
            for c in rect.col..rect.col.saturating_add(rect.cols) {
                self.put(
                    r,
                    c,
                    Cell {
                        bg,
                        ..Cell::default()
                    },
                );
            }
        }
    }
}

/// Snapshot one terminal into resolved RGB cells for native graphical clients.
///
/// Server libghostty-vt remains the only terminal parser; clients render this
/// cell model directly instead of reparsing VT output in another terminal
/// emulator.
pub fn terminal_grid_snapshot(terminal: &Terminal<'_, '_>) -> anyhow::Result<TerminalGridSnapshot> {
    let mut render_state = RenderState::new()?;
    let snapshot = render_state.update(terminal)?;
    let cols = snapshot.cols()?;
    let rows = snapshot.rows()?;
    let colors = snapshot.colors()?;
    let default_fg = colors.foreground;
    let default_bg = colors.background;
    let cursor = snapshot
        .cursor_viewport()?
        .map(|cursor| {
            Ok::<TerminalCursor, anyhow::Error>(TerminalCursor {
                col: cursor.x,
                row: cursor.y,
                visible: snapshot.cursor_visible()?,
                style: terminal_cursor_style(snapshot.cursor_visual_style()?),
                blink: snapshot.cursor_blinking()?,
                color: snapshot.cursor_color()?,
            })
        })
        .transpose()?;

    let mut cells = Vec::with_capacity(usize::from(cols) * usize::from(rows));
    let mut row_iter = RowIterator::new()?;
    let mut row_iteration = row_iter.update(&snapshot)?;

    let mut emitted_rows: u16 = 0;
    while row_iteration.next().is_some() {
        if emitted_rows >= rows {
            break;
        }
        let mut cell_iter = CellIterator::new()?;
        let mut cell_iteration = cell_iter.update(&row_iteration)?;
        let mut emitted_cols: u16 = 0;
        while cell_iteration.next().is_some() {
            if emitted_cols >= cols {
                break;
            }
            cells.push(grid_cell_from_iteration(
                &cell_iteration,
                default_fg,
                default_bg,
            )?);
            emitted_cols = emitted_cols.saturating_add(1);
        }
        while emitted_cols < cols {
            cells.push(default_grid_cell(default_fg, default_bg));
            emitted_cols = emitted_cols.saturating_add(1);
        }
        emitted_rows = emitted_rows.saturating_add(1);
    }
    while emitted_rows < rows {
        for _ in 0..cols {
            cells.push(default_grid_cell(default_fg, default_bg));
        }
        emitted_rows = emitted_rows.saturating_add(1);
    }

    Ok(TerminalGridSnapshot {
        cols,
        rows,
        cells,
        cursor,
    })
}

fn grid_cell_from_iteration(
    cell_iteration: &CellIteration<'_, '_>,
    default_fg: RgbColor,
    default_bg: RgbColor,
) -> anyhow::Result<TerminalGridCell> {
    let wide = cell_wide(cell_iteration);
    let is_continuation = is_wide_continuation(wide);
    let grapheme = if is_continuation {
        String::new()
    } else {
        cell_grapheme(cell_iteration)
    };
    let style = cell_iteration.style().ok();
    let mut fg = cell_iteration.fg_color()?.unwrap_or(default_fg);
    let mut bg = cell_iteration.bg_color()?.unwrap_or(default_bg);
    let mut bold = false;
    let mut italic = false;
    let mut underline = false;
    let mut faint = false;
    let mut blink = false;
    let mut strikethrough = false;
    let mut invisible = false;
    if let Some(style) = style {
        bold = style.bold;
        italic = style.italic;
        underline = !matches!(style.underline, libghostty_vt::style::Underline::None);
        faint = style.faint;
        blink = style.blink;
        strikethrough = style.strikethrough;
        invisible = style.invisible;
        if style.inverse {
            std::mem::swap(&mut fg, &mut bg);
        }
    }
    let text = if invisible || is_continuation {
        " ".into()
    } else {
        grapheme
    };
    Ok(TerminalGridCell {
        width: grid_cell_width(wide, &text),
        text,
        fg,
        bg,
        bold,
        italic,
        underline,
        faint,
        blink,
        strikethrough,
    })
}

fn default_grid_cell(fg: RgbColor, bg: RgbColor) -> TerminalGridCell {
    TerminalGridCell {
        text: " ".into(),
        width: 1,
        fg,
        bg,
        bold: false,
        italic: false,
        underline: false,
        faint: false,
        blink: false,
        strikethrough: false,
    }
}

fn cell_grapheme(cell_iteration: &CellIteration<'_, '_>) -> String {
    let graphemes = cell_iteration.graphemes().unwrap_or_default();
    let mut out = String::new();
    for ch in graphemes {
        if ch != '\0' {
            out.push(ch);
        }
    }
    if out.is_empty() { " ".into() } else { out }
}

fn cell_display_width(text: &str) -> u8 {
    u8::try_from(UnicodeWidthStr::width(text).max(1)).unwrap_or(u8::MAX)
}

fn cell_wide(cell_iteration: &CellIteration<'_, '_>) -> CellWide {
    cell_iteration
        .raw_cell()
        .and_then(|cell| cell.wide())
        .unwrap_or(CellWide::Narrow)
}

fn is_wide_continuation(wide: CellWide) -> bool {
    matches!(wide, CellWide::SpacerTail)
}

fn grid_cell_width(wide: CellWide, text: &str) -> u8 {
    match wide {
        CellWide::Wide => 2,
        CellWide::SpacerTail => 0,
        CellWide::Narrow | CellWide::SpacerHead => cell_display_width(text),
    }
}

fn terminal_cursor_style(style: CursorVisualStyle) -> TerminalCursorStyle {
    match style {
        CursorVisualStyle::Bar => TerminalCursorStyle::Bar,
        CursorVisualStyle::Underline => TerminalCursorStyle::Underline,
        CursorVisualStyle::BlockHollow => TerminalCursorStyle::HollowBlock,
        CursorVisualStyle::Block => TerminalCursorStyle::Block,
        _ => TerminalCursorStyle::Block,
    }
}

/// Compose a full frame from N (rect, Terminal) pairs.
///
/// Each pane's `Terminal::render` walks its visible grid and writes into the
/// frame at the pane's rect offsets. Border cells between panes remain
/// blank; the caller is expected to overlay borders on top if desired.
pub fn composite(
    viewport: (u16, u16),
    panes: &[(Rect, &Terminal<'_, '_>)],
) -> anyhow::Result<Frame> {
    let (cols, rows) = viewport;
    let mut frame = Frame::new(cols, rows);
    for (rect, terminal) in panes {
        paste_pane(&mut frame, *rect, terminal)?;
    }
    Ok(frame)
}

/// Paint one pane's libghostty-vt contents into `frame` at `rect`.
///
/// Explicit colors preserve libghostty's style values, including palette
/// indices. `StyleColor::None` is preserved for default foreground/background
/// cells. This viewport-aware path is used for server-side pane composition.
///
/// Cells outside `rect` are untouched; cells inside but outside `frame`'s
/// bounds are silently dropped.
pub fn paste_pane(
    frame: &mut Frame,
    rect: Rect,
    terminal: &Terminal<'_, '_>,
) -> anyhow::Result<()> {
    let mut render_state = RenderState::new()?;
    let snapshot = render_state.update(terminal)?;
    let mut row_iter = RowIterator::new()?;
    let mut row_iteration = row_iter.update(&snapshot)?;

    let mut row_offset: u16 = 0;
    while row_iteration.next().is_some() {
        if row_offset >= rect.rows {
            break;
        }
        let mut cell_iter = CellIterator::new()?;
        let mut cell_iteration = cell_iter.update(&row_iteration)?;

        let mut col_offset: u16 = 0;
        while cell_iteration.next().is_some() {
            if col_offset >= rect.cols {
                break;
            }
            let wide = cell_wide(&cell_iteration);
            let is_continuation = is_wide_continuation(wide);
            let graphemes = cell_iteration.graphemes().unwrap_or_default();
            let style = cell_iteration.style().ok();
            let (fg, bg, bold, italic, underline, faint, strikethrough, reverse, blink) =
                match style {
                    Some(s) => (
                        s.fg_color,
                        render_cell_bg_color(&cell_iteration, s.bg_color),
                        s.bold,
                        s.italic,
                        !matches!(s.underline, libghostty_vt::style::Underline::None),
                        s.faint,
                        s.strikethrough,
                        s.inverse,
                        s.blink,
                    ),
                    None => (
                        StyleColor::None,
                        StyleColor::None,
                        false,
                        false,
                        false,
                        false,
                        false,
                        false,
                        false,
                    ),
                };

            let mut grapheme = String::new();
            if !is_continuation {
                for ch in graphemes {
                    if ch != '\0' {
                        grapheme.push(ch);
                    }
                }
            }
            let width = if is_continuation {
                0
            } else {
                grid_cell_width(wide, &grapheme)
            };
            frame.put(
                rect.row + row_offset,
                rect.col + col_offset,
                Cell {
                    grapheme,
                    width,
                    is_continuation,
                    fg,
                    bg,
                    bold,
                    italic,
                    underline,
                    faint,
                    strikethrough,
                    reverse,
                    blink,
                },
            );
            col_offset += 1;
        }
        row_offset += 1;
    }
    Ok(())
}

fn render_cell_bg_color(
    cell_iteration: &CellIteration<'_, '_>,
    style_bg: StyleColor,
) -> StyleColor {
    if !matches!(style_bg, StyleColor::None) {
        return style_bg;
    }

    let Ok(raw_cell) = cell_iteration.raw_cell() else {
        return style_bg;
    };
    match raw_cell.content_tag() {
        Ok(CellContentTag::BgColorPalette) => raw_cell
            .bg_color_palette()
            .map_or(style_bg, StyleColor::Palette),
        Ok(CellContentTag::BgColorRgb) => raw_cell.bg_color_rgb().map_or(style_bg, StyleColor::Rgb),
        _ => cell_iteration
            .bg_color()
            .ok()
            .flatten()
            .map_or(style_bg, StyleColor::Rgb),
    }
}

/// Emit a full-frame redraw. The bytes should be written verbatim to the
/// client's stdout. Begins with cursor-hide + home and ends with an SGR
/// reset. The caller is responsible for appending the cursor-show +
/// final-position tail (see `render::compose`).
///
/// Pre-alt-screen we used to emit `CSI H CSI 2J` (cursor home + clear
/// screen) as a preamble; in practice that made bursty TUI startup
/// (like `btop`) visibly flash, because every coalesced repaint wipes
/// to the default bg before rewriting every cell. Clients enter the
/// alternate screen before their first rendered frame, so the alt buffer
/// is already blank when we arrive; and `emit_ansi` writes every cell
/// on every frame, so there's no stale content to clear.
///
/// We also prepend `CSI ?25 l` to hide the cursor for the duration of
/// the paint. Without that the host terminal can render intermediate
/// flushes of the per-cell writes and the user sees the cursor
/// streaking through the bottom of the frame as cells are emitted row
/// by row. The paired show (`CSI ?25 h`) + CUP is emitted by the
/// caller once the frame is complete.
#[must_use]
pub fn emit_ansi(frame: &Frame) -> Vec<u8> {
    let mut out: Vec<u8> =
        Vec::with_capacity(usize::from(frame.rows) * usize::from(frame.cols) * 4);
    out.extend_from_slice(b"\x1b[?25l\x1b[H");

    let mut cur = Cell::default();

    for (row_idx, row) in frame.cells.iter().enumerate() {
        out.extend_from_slice(format!("\x1b[{};1H", row_idx + 1).as_bytes());

        for cell in row {
            if cell.is_continuation {
                continue;
            }
            if cell.fg != cur.fg {
                emit_fg(&mut out, cell.fg);
                cur.fg = cell.fg;
            }
            if cell.bg != cur.bg {
                emit_bg(&mut out, cell.bg);
                cur.bg = cell.bg;
            }
            if cell.bold != cur.bold {
                out.extend_from_slice(if cell.bold { b"\x1b[1m" } else { b"\x1b[22m" });
                cur.bold = cell.bold;
            }
            if cell.italic != cur.italic {
                out.extend_from_slice(if cell.italic { b"\x1b[3m" } else { b"\x1b[23m" });
                cur.italic = cell.italic;
            }
            if cell.underline != cur.underline {
                out.extend_from_slice(if cell.underline {
                    b"\x1b[4m"
                } else {
                    b"\x1b[24m"
                });
                cur.underline = cell.underline;
            }
            if cell.faint != cur.faint {
                // `\e[2m` = faint; 22 resets both bold AND faint, so
                // re-emit bold if it's still active.
                out.extend_from_slice(if cell.faint { b"\x1b[2m" } else { b"\x1b[22m" });
                cur.faint = cell.faint;
                if !cell.faint && cell.bold {
                    out.extend_from_slice(b"\x1b[1m");
                }
            }
            if cell.strikethrough != cur.strikethrough {
                out.extend_from_slice(if cell.strikethrough {
                    b"\x1b[9m"
                } else {
                    b"\x1b[29m"
                });
                cur.strikethrough = cell.strikethrough;
            }
            if cell.reverse != cur.reverse {
                out.extend_from_slice(if cell.reverse {
                    b"\x1b[7m"
                } else {
                    b"\x1b[27m"
                });
                cur.reverse = cell.reverse;
            }
            if cell.blink != cur.blink {
                out.extend_from_slice(if cell.blink { b"\x1b[5m" } else { b"\x1b[25m" });
                cur.blink = cell.blink;
            }
            if cell.grapheme.is_empty() {
                out.push(b' ');
            } else {
                out.extend_from_slice(cell.grapheme.as_bytes());
            }
        }
    }

    out.extend_from_slice(b"\x1b[0m");
    out
}

fn emit_fg(out: &mut Vec<u8>, color: StyleColor) {
    match color {
        StyleColor::None => out.extend_from_slice(b"\x1b[39m"),
        StyleColor::Palette(p) => {
            let n = p.0;
            if n < 8 {
                out.extend_from_slice(format!("\x1b[3{n}m").as_bytes());
            } else if n < 16 {
                out.extend_from_slice(format!("\x1b[9{}m", n - 8).as_bytes());
            } else {
                out.extend_from_slice(format!("\x1b[38;5;{n}m").as_bytes());
            }
        }
        StyleColor::Rgb(c) => {
            out.extend_from_slice(format!("\x1b[38;2;{};{};{}m", c.r, c.g, c.b).as_bytes());
        }
    }
}

fn emit_bg(out: &mut Vec<u8>, color: StyleColor) {
    match color {
        StyleColor::None => out.extend_from_slice(b"\x1b[49m"),
        StyleColor::Palette(p) => {
            let n = p.0;
            if n < 8 {
                out.extend_from_slice(format!("\x1b[4{n}m").as_bytes());
            } else if n < 16 {
                out.extend_from_slice(format!("\x1b[10{}m", n - 8).as_bytes());
            } else {
                out.extend_from_slice(format!("\x1b[48;5;{n}m").as_bytes());
            }
        }
        StyleColor::Rgb(c) => {
            out.extend_from_slice(format!("\x1b[48;2;{};{};{}m", c.r, c.g, c.b).as_bytes());
        }
    }
}

/// Convenience: compose panes and emit the ANSI redraw in one call.
pub fn render(
    viewport: (u16, u16),
    panes: &[(Rect, &Terminal<'_, '_>)],
) -> anyhow::Result<Vec<u8>> {
    Ok(emit_ansi(&composite(viewport, panes)?))
}

#[allow(dead_code)]
const _STYLE_COLOR_REFERENCE: fn() -> StyleColor = || StyleColor::None;

#[cfg(test)]
mod tests {
    use super::*;
    use libghostty_vt::{Terminal, TerminalOptions};

    fn mk_terminal(cols: u16, rows: u16, vt: &[u8]) -> Terminal<'static, 'static> {
        let mut t = Terminal::new(TerminalOptions {
            cols,
            rows,
            max_scrollback: 0,
        })
        .expect("Terminal::new");
        t.vt_write(vt);
        t
    }

    #[test]
    fn single_pane_dumps_text() {
        let t = mk_terminal(40, 4, b"hello world\n");
        let rect = Rect {
            col: 0,
            row: 0,
            cols: 40,
            rows: 4,
        };
        let frame = composite((40, 4), &[(rect, &t)]).unwrap();
        let row0: String = frame.cells[0]
            .iter()
            .map(|c| {
                if c.grapheme.is_empty() {
                    ' '.to_string()
                } else {
                    c.grapheme.clone()
                }
            })
            .collect();
        assert!(row0.starts_with("hello world"), "row0: {row0:?}");
    }

    #[test]
    fn horizontal_split_has_both_contents() {
        let left = mk_terminal(20, 4, b"LEFT-pane\n");
        let right = mk_terminal(20, 4, b"RIGHT-pane\n");
        let frame = composite(
            (40, 4),
            &[
                (
                    Rect {
                        col: 0,
                        row: 0,
                        cols: 20,
                        rows: 4,
                    },
                    &left,
                ),
                (
                    Rect {
                        col: 20,
                        row: 0,
                        cols: 20,
                        rows: 4,
                    },
                    &right,
                ),
            ],
        )
        .unwrap();
        let row0: String = frame.cells[0]
            .iter()
            .map(|c| {
                if c.grapheme.is_empty() {
                    ' '.to_string()
                } else {
                    c.grapheme.clone()
                }
            })
            .collect();
        assert!(row0.contains("LEFT-pane"), "row0: {row0:?}");
        assert!(row0.contains("RIGHT-pane"), "row0: {row0:?}");
    }

    #[test]
    fn emit_ansi_contains_cursor_home_and_text() {
        let t = mk_terminal(20, 2, b"ABC\n");
        let frame = composite(
            (20, 2),
            &[(
                Rect {
                    col: 0,
                    row: 0,
                    cols: 20,
                    rows: 2,
                },
                &t,
            )],
        )
        .unwrap();
        let bytes = emit_ansi(&frame);
        // Cursor hide + home first so the cursor doesn't streak through
        // cells as they're emitted; the caller re-shows at the real
        // position. The CSI H CSI 2J preamble was dropped because it
        // produced visible flicker on bursty TUI startup — alt-screen
        // already gives us a blank buffer.
        assert!(bytes.starts_with(b"\x1b[?25l\x1b[H"));
        assert!(
            !bytes.starts_with(b"\x1b[H\x1b[2J"),
            "2J preamble snuck back in"
        );
        let as_str = String::from_utf8_lossy(&bytes);
        assert!(as_str.contains("ABC"), "missing content. output:\n{as_str}");
        // Final SGR reset.
        assert!(bytes.ends_with(b"\x1b[0m"));
    }

    #[test]
    fn emit_ansi_skips_wide_grapheme_tail_cell() {
        let t = mk_terminal(4, 1, "界X".as_bytes());
        let frame = composite(
            (4, 1),
            &[(
                Rect {
                    col: 0,
                    row: 0,
                    cols: 4,
                    rows: 1,
                },
                &t,
            )],
        )
        .unwrap();

        assert_eq!(frame.cells[0][0].grapheme, "界");
        assert_eq!(frame.cells[0][0].width, 2);
        assert!(!frame.cells[0][0].is_continuation);
        assert_eq!(frame.cells[0][1].width, 0);
        assert!(frame.cells[0][1].is_continuation);
        assert_eq!(frame.cells[0][2].grapheme, "X");

        let bytes = emit_ansi(&frame);
        let as_str = String::from_utf8_lossy(&bytes);
        assert!(
            as_str.contains("界X"),
            "wide glyph tail inserted a column. output:\n{as_str}"
        );
        assert!(
            !as_str.contains("界 X"),
            "wide glyph tail was emitted as a space. output:\n{as_str}"
        );
    }

    #[test]
    fn render_emits_sgr_color_on_red_text() {
        // Truecolor fg: red via RGB 255,0,0.
        let vt = b"\x1b[38;2;255;0;0mR\x1b[0m";
        let t = mk_terminal(8, 1, vt);
        let bytes = render(
            (8, 1),
            &[(
                Rect {
                    col: 0,
                    row: 0,
                    cols: 8,
                    rows: 1,
                },
                &t,
            )],
        )
        .unwrap();
        let as_str = String::from_utf8_lossy(&bytes);
        assert!(
            as_str.contains("\x1b[38;2;255;0;0m"),
            "expected fg-red truecolor SGR, got:\n{as_str}"
        );
    }

    #[test]
    fn palette_color_passes_through_so_host_theme_applies() {
        // The shell emits `\e[32m` (palette 2 = green). Server-side pane
        // composition should preserve that palette index so Ghostty's active
        // host palette decides the visible color.
        let vt = b"\x1b[32mG\x1b[0m";
        let t = mk_terminal(8, 1, vt);
        let bytes = render(
            (8, 1),
            &[(
                Rect {
                    col: 0,
                    row: 0,
                    cols: 8,
                    rows: 1,
                },
                &t,
            )],
        )
        .unwrap();
        let s = String::from_utf8_lossy(&bytes);
        assert!(
            s.contains("\x1b[32m") || s.contains("\x1b[38;5;2m"),
            "expected palette-green SGR to stay palette-indexed:\n{s}"
        );
        assert!(
            !s.contains("\x1b[38;2;"),
            "palette-green SGR resolved to truecolor:\n{s}"
        );
    }

    #[test]
    fn uncolored_text_emits_default_sgr_so_host_theme_applies() {
        // A cell with no color set should emit `\e[39m`/`\e[49m` defaults.
        // Emitting truecolor here would override the user's theme fg/bg.
        let t = mk_terminal(8, 1, b"x");
        let bytes = render(
            (8, 1),
            &[(
                Rect {
                    col: 0,
                    row: 0,
                    cols: 8,
                    rows: 1,
                },
                &t,
            )],
        )
        .unwrap();
        let s = String::from_utf8_lossy(&bytes);
        assert!(
            !s.contains("\x1b[38;2;"),
            "default-fg cell leaked truecolor SGR:\n{s}"
        );
        assert!(
            !s.contains("\x1b[48;2;"),
            "default-bg cell leaked truecolor SGR:\n{s}"
        );
    }

    #[test]
    fn erase_line_background_cells_are_preserved() {
        let vt = b"\x1b[48;2;30;31;32mhello\x1b[K";
        let t = mk_terminal(8, 1, vt);
        let frame = composite(
            (8, 1),
            &[(
                Rect {
                    col: 0,
                    row: 0,
                    cols: 8,
                    rows: 1,
                },
                &t,
            )],
        )
        .unwrap();

        for col in 0..8 {
            assert_eq!(
                frame.cells[0][col].bg,
                StyleColor::Rgb(RgbColor {
                    r: 30,
                    g: 31,
                    b: 32,
                }),
                "col {col}"
            );
        }

        let bytes = emit_ansi(&frame);
        let s = String::from_utf8_lossy(&bytes);
        assert!(
            s.contains("\x1b[48;2;30;31;32m"),
            "erase-line background was not emitted:\n{s}"
        );
    }

    #[test]
    fn bright_palette_passes_through_so_host_theme_applies() {
        // Bright green = palette 10. This should remain palette-indexed before
        // the composed frame reaches the host terminal.
        let vt = b"\x1b[92mg\x1b[0m";
        let t = mk_terminal(8, 1, vt);
        let bytes = render(
            (8, 1),
            &[(
                Rect {
                    col: 0,
                    row: 0,
                    cols: 8,
                    rows: 1,
                },
                &t,
            )],
        )
        .unwrap();
        let s = String::from_utf8_lossy(&bytes);
        assert!(
            s.contains("\x1b[92m") || s.contains("\x1b[38;5;10m"),
            "expected bright-green palette SGR to stay palette-indexed:\n{s}"
        );
        assert!(
            !s.contains("\x1b[38;2;"),
            "bright palette SGR resolved to truecolor:\n{s}"
        );
    }

    #[test]
    fn grid_snapshot_resolves_palette_135_through_ghostty_palette() {
        let t = mk_terminal(8, 1, b"\x1b[38;5;135mp\x1b[0m");
        let snapshot = terminal_grid_snapshot(&t).expect("grid snapshot");
        assert_eq!(snapshot.cols, 8);
        assert_eq!(snapshot.rows, 1);
        assert_eq!(snapshot.cells[0].text, "p");
        assert_eq!(
            snapshot.cells[0].fg,
            RgbColor {
                r: 175,
                g: 95,
                b: 255,
            }
        );
    }

    #[test]
    fn grid_snapshot_reports_wide_grapheme_width() {
        let t = mk_terminal(4, 1, "界X".as_bytes());
        let snapshot = terminal_grid_snapshot(&t).expect("grid snapshot");

        assert_eq!(snapshot.cells[0].text, "界");
        assert_eq!(snapshot.cells[0].width, 2);
        assert_eq!(snapshot.cells[1].text, " ");
        assert_eq!(snapshot.cells[1].width, 0);
        assert_eq!(snapshot.cells[2].text, "X");
        assert_eq!(snapshot.cells[2].width, 1);
    }

    #[test]
    fn grid_snapshot_resolves_palette_entries_from_terminal_palette_override() {
        let mut t = mk_terminal(
            4,
            1,
            b"\x1b[35mm\x1b[38;5;13mM\x1b[45m \x1b[48;5;13m \x1b[0m",
        );
        let palette_source = mk_terminal(1, 1, b"");
        let mut palette = palette_source
            .default_color_palette()
            .expect("default palette");
        palette[5] = RgbColor {
            r: 174,
            g: 129,
            b: 255,
        };
        palette[13] = RgbColor {
            r: 190,
            g: 150,
            b: 255,
        };
        t.set_default_color_palette(Some(palette))
            .expect("set default palette");

        let snapshot = terminal_grid_snapshot(&t).expect("grid snapshot");

        assert_eq!(snapshot.cells[0].text, "m");
        assert_eq!(
            snapshot.cells[0].fg,
            RgbColor {
                r: 174,
                g: 129,
                b: 255,
            }
        );
        assert_eq!(snapshot.cells[1].text, "M");
        assert_eq!(
            snapshot.cells[1].fg,
            RgbColor {
                r: 190,
                g: 150,
                b: 255,
            }
        );
        assert_eq!(
            snapshot.cells[2].bg,
            RgbColor {
                r: 174,
                g: 129,
                b: 255,
            }
        );
        assert_eq!(
            snapshot.cells[3].bg,
            RgbColor {
                r: 190,
                g: 150,
                b: 255,
            }
        );
    }

    #[test]
    fn grid_snapshot_resolves_all_background_palette_entries_from_default_override() {
        let mut vt = Vec::new();
        for index in 0u16..=255 {
            vt.extend_from_slice(format!("\x1b[48;5;{index}m \x1b[0m").as_bytes());
        }

        let mut t = mk_terminal(300, 1, &vt);
        let palette_source = mk_terminal(1, 1, b"");
        let mut palette = palette_source
            .default_color_palette()
            .expect("default palette");
        for index in 0u16..=255 {
            palette[usize::from(index)] = RgbColor {
                r: index as u8,
                g: 255u8.wrapping_sub(index as u8),
                b: (index as u8) ^ 0x55,
            };
        }
        t.set_default_color_palette(Some(palette))
            .expect("set default palette");

        let snapshot = terminal_grid_snapshot(&t).expect("grid snapshot");

        for index in 0u16..=255 {
            let expected = palette[usize::from(index)];
            assert_eq!(
                snapshot.cells[usize::from(index)].bg,
                expected,
                "background palette index {index}"
            );
        }
    }

    #[test]
    fn grid_snapshot_resolves_all_foreground_palette_entries_from_default_override() {
        let mut vt = Vec::new();
        for index in 0u16..=255 {
            vt.extend_from_slice(format!("\x1b[38;5;{index}mX\x1b[0m").as_bytes());
        }

        let mut t = mk_terminal(300, 1, &vt);
        let palette_source = mk_terminal(1, 1, b"");
        let mut palette = palette_source
            .default_color_palette()
            .expect("default palette");
        for index in 0u16..=255 {
            palette[usize::from(index)] = RgbColor {
                r: index as u8,
                g: 255u8.wrapping_sub(index as u8),
                b: (index as u8) ^ 0xaa,
            };
        }
        t.set_default_color_palette(Some(palette))
            .expect("set default palette");

        let snapshot = terminal_grid_snapshot(&t).expect("grid snapshot");

        for index in 0u16..=255 {
            let expected = palette[usize::from(index)];
            assert_eq!(
                snapshot.cells[usize::from(index)].fg,
                expected,
                "foreground palette index {index}"
            );
        }
    }

    #[test]
    fn grid_snapshot_resolves_prompt_foreground_palette_indices_from_default_override() {
        let mut t = mk_terminal(
            64,
            1,
            b"\x1b[38;5;135mlawrence\x1b[00m in \x1b[38;5;118m~/fun/cmux-cli\x1b[00m on \x1b[38;5;81mmain\x1b[00m\x1b[38;5;166m \xce\xbb\x1b[00m ",
        );
        let palette_source = mk_terminal(1, 1, b"");
        let palette = palette_source
            .default_color_palette()
            .expect("default palette");
        t.set_default_fg_color(Some(RgbColor {
            r: 253,
            g: 255,
            b: 241,
        }))
        .expect("set default fg");
        t.set_default_bg_color(Some(RgbColor {
            r: 39,
            g: 40,
            b: 34,
        }))
        .expect("set default bg");
        t.set_default_color_palette(Some(palette))
            .expect("set default palette");

        let snapshot = terminal_grid_snapshot(&t).expect("grid snapshot");

        assert_eq!(
            snapshot.cells[0].fg,
            RgbColor {
                r: 175,
                g: 95,
                b: 255,
            }
        );
        assert_eq!(
            snapshot.cells[9].fg,
            RgbColor {
                r: 253,
                g: 255,
                b: 241,
            }
        );
        assert_eq!(
            snapshot.cells[12].fg,
            RgbColor {
                r: 135,
                g: 255,
                b: 0,
            }
        );
        assert_eq!(
            snapshot.cells[30].fg,
            RgbColor {
                r: 95,
                g: 215,
                b: 255,
            }
        );
        assert_eq!(
            snapshot.cells[35].fg,
            RgbColor {
                r: 215,
                g: 95,
                b: 0,
            }
        );
    }

    #[test]
    fn grid_snapshot_fills_blank_cells_with_default_background() {
        let t = mk_terminal(3, 2, b"");
        let snapshot = terminal_grid_snapshot(&t).expect("grid snapshot");
        assert_eq!(snapshot.cells.len(), 6);
        assert!(snapshot.cells.iter().all(|cell| cell.text == " "));
        assert!(
            snapshot
                .cells
                .iter()
                .all(|cell| cell.bg == snapshot.cells[0].bg)
        );
    }

    #[test]
    fn grid_snapshot_uses_terminal_default_colors() {
        let mut t = mk_terminal(2, 1, b"x");
        t.set_default_fg_color(Some(RgbColor {
            r: 253,
            g: 255,
            b: 241,
        }))
        .expect("set default fg");
        t.set_default_bg_color(Some(RgbColor {
            r: 39,
            g: 40,
            b: 34,
        }))
        .expect("set default bg");
        let snapshot = terminal_grid_snapshot(&t).expect("grid snapshot");
        assert_eq!(
            snapshot.cells[0].fg,
            RgbColor {
                r: 253,
                g: 255,
                b: 241
            }
        );
        assert_eq!(
            snapshot.cells[0].bg,
            RgbColor {
                r: 39,
                g: 40,
                b: 34
            }
        );
    }

    #[test]
    fn italic_underline_strikethrough_are_emitted() {
        let vt = b"\x1b[3;4;9ma\x1b[0m";
        let t = mk_terminal(8, 1, vt);
        let bytes = render(
            (8, 1),
            &[(
                Rect {
                    col: 0,
                    row: 0,
                    cols: 8,
                    rows: 1,
                },
                &t,
            )],
        )
        .unwrap();
        let s = String::from_utf8_lossy(&bytes);
        assert!(s.contains("\x1b[3m"), "italic not emitted: {s}");
        assert!(s.contains("\x1b[4m"), "underline not emitted: {s}");
        assert!(s.contains("\x1b[9m"), "strikethrough not emitted: {s}");
    }
}
