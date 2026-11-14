//! Copy-mode drawing: the cursor and search highlights painted over a pane's
//! terminal cells, and the mode line drawn in the status row. Both run only
//! while copy mode is active.

use cmux_tui_core::Rect;
use ghostty_vt::{CellWidth, RenderRow};
use ratatui::Frame;
use ratatui::buffer::Buffer;
use ratatui::style::{Color, Modifier, Style};

use crate::app::App;
use crate::app::copy_mode::{CopyModeLine, CopyOverlay};
use crate::config::Theme;

/// Paint the copy cursor and the visible search matches over the cells the
/// terminal grid just drew. `live` is the drawn viewport and `source_x` the
/// first source column it shows.
pub(super) fn paint_overlay(
    frame: &mut Frame,
    live: Rect,
    source_x: u16,
    rows: &[RenderRow],
    theme: &Theme,
    overlay: &CopyOverlay,
) {
    let buf = frame.buffer_mut();
    let cols = rows.first().map_or(0, |row| row.len() as u16);
    let other = Style::default().fg(theme.notification_warning).add_modifier(Modifier::UNDERLINED);
    let current = Style::default().bg(theme.notification_warning).fg(Color::Black);
    for &(start, end, is_current) in &overlay.matches {
        let style = if is_current { current } else { other };
        let first = start.row.max(overlay.offset);
        let last = end.row.min(overlay.offset + u64::from(live.height.max(1)) - 1);
        for row in first..=last {
            let from = if row == start.row { start.col } else { 0 };
            let to = if row == end.row { end.col } else { cols.saturating_sub(1) };
            let viewport_row = (row - overlay.offset) as u16;
            for col in from..=to {
                paint_cell(buf, live, source_x, col, viewport_row, style);
            }
        }
    }
    if let Some((col, row)) = overlay.cursor {
        let style = Style::default().bg(theme.border_active).fg(Color::Black);
        paint_cell(buf, live, source_x, col, row, style);
        let wide = rows
            .get(usize::from(row))
            .and_then(|cells| cells.get(usize::from(col)))
            .is_some_and(|cell| cell.width == CellWidth::Wide);
        if wide {
            paint_cell(buf, live, source_x, col + 1, row, style);
        }
    }
}

fn paint_cell(buf: &mut Buffer, live: Rect, source_x: u16, col: u16, row: u16, style: Style) {
    if col < source_x || row >= live.height {
        return;
    }
    let x = col - source_x;
    if x >= live.width {
        return;
    }
    buf[(live.x + x, live.y + row)].set_style(style);
}

/// Draw the copy-mode line across the status row from `x0`: the mode chip,
/// the search prompt or result, then the key hints and cursor position at
/// the right edge.
pub(super) fn draw_mode_line(app: &App, frame: &mut Frame, x0: u16, y: u16, line: &CopyModeLine) {
    let width = frame.area().width;
    let chrome = app.chrome;
    let theme = app.config.theme;
    let base = Style::default()
        .bg(theme.status_bg.unwrap_or(chrome.status_bg))
        .fg(theme.status_fg.unwrap_or(chrome.status_fg));
    let chip = Style::default()
        .bg(chrome.status_active_bg)
        .fg(chrome.status_active_fg)
        .add_modifier(Modifier::BOLD);
    let accent = base.fg(theme.notification_warning).add_modifier(Modifier::BOLD);
    let dim = base.fg(chrome.status_dim_fg);
    let buf = frame.buffer_mut();
    for x in x0..width {
        buf[(x, y)].set_symbol(" ").set_style(base);
    }
    let mut x = x0;
    let put = |buf: &mut Buffer, x: &mut u16, text: &str, style: Style| {
        if *x < width {
            *x = buf.set_stringn(*x, y, text, usize::from(width - *x), style).0;
        }
    };
    put(buf, &mut x, &format!(" {} ", line.mode), chip);
    put(buf, &mut x, " ", base);
    if let Some((direction, text)) = &line.prompt {
        put(buf, &mut x, &format!("{direction}{text}"), base);
        put(buf, &mut x, " ", base.add_modifier(Modifier::REVERSED));
    } else if let Some(notice) = line.notice {
        put(buf, &mut x, notice, accent);
    } else if let Some((direction, needle, count)) = &line.search {
        put(buf, &mut x, &format!("{direction}{needle} "), base);
        put(buf, &mut x, count, accent);
    }
    let position = format!(" {} ", line.position);
    let hints = line
        .hints
        .iter()
        .map(|(key, label)| format!("{key} {label}"))
        .collect::<Vec<_>>()
        .join(" · ");
    let position_width = position.chars().count() as u16;
    let hints_width = unicode_width::UnicodeWidthStr::width(hints.as_str()) as u16;
    let mut right = width.saturating_sub(position_width);
    if right > x.saturating_add(1) {
        buf.set_stringn(right, y, &position, usize::from(position_width), dim);
    } else {
        return;
    }
    if !hints.is_empty() && right > x.saturating_add(hints_width).saturating_add(2) {
        right -= hints_width + 1;
        buf.set_stringn(right, y, &hints, usize::from(hints_width), dim);
    }
}
