//! Pane drawing: per-pane tab bar, terminal content from the ghostty
//! render state (with selection highlight), and a thin scrollbar when
//! the surface is scrolled back.

use ghostty_vt::{Cell as VtCell, RenderState, Scrollbar};
use mux_core::Rect;
use ratatui::style::{Color, Modifier, Style};
use ratatui::Frame;

use super::{bar_active_style, bar_base_style, truncate};
use crate::app::{App, Hit, PaneArea, Selection};

/// Draw every pane of the current frame. Returns the terminal cursor
/// position for the focused pane, if visible.
pub fn draw_all(app: &mut App, frame: &mut Frame) -> Option<(u16, u16)> {
    let active_pane = app.tree.active_screen().map(|screen| screen.active_pane);
    let areas = app.pane_areas.clone();
    let mut cursor = None;
    for area in &areas {
        let focused = Some(area.pane) == active_pane;
        if let Some(bar) = area.bar {
            draw_tab_bar(app, frame, area, bar, focused);
        }
        if let Some(c) = draw_content(app, frame, area, focused) {
            cursor = Some(c);
        }
        draw_scrollbar(app, frame, area);
    }
    cursor
}

fn draw_tab_bar(app: &mut App, frame: &mut Frame, area: &PaneArea, bar: Rect, focused: bool) {
    let Some(screen) = app.tree.active_screen() else { return };
    let Some(pane) = screen.pane(area.pane) else { return };
    let screen = frame.area();
    let buf = frame.buffer_mut();
    let base = bar_base_style();

    for x in bar.x..bar.x + bar.width {
        if x < screen.width && bar.y < screen.height {
            buf[(x, bar.y)].set_symbol(" ").set_style(base);
        }
    }

    let max_x = (bar.x + bar.width).min(screen.width);
    let mut x = bar.x;
    let mut hits = Vec::new();
    for (i, tab) in pane.tabs.iter().enumerate() {
        if x >= max_x {
            break;
        }
        let active = i == pane.active_tab;
        let style = if active && focused {
            bar_active_style()
        } else if active {
            bar_active_style().remove_modifier(Modifier::BOLD)
        } else {
            base
        };
        let label = format!(" {} ", truncate(tab.display_title(), 16));
        let width = (label.chars().count() as u16).min(max_x - x);
        buf.set_stringn(x, bar.y, &label, width as usize, style);
        hits.push((Rect { x, y: bar.y, width, height: 1 }, Hit::Tab { pane: area.pane, index: i }));
        x += width;
    }
    // Trailing "+" opens a new tab in this pane.
    if x < max_x {
        let label = " + ";
        let width = (label.len() as u16).min(max_x - x);
        buf.set_stringn(x, bar.y, label, width as usize, base.fg(Color::Indexed(250)));
        hits.push((Rect { x, y: bar.y, width, height: 1 }, Hit::NewTab { pane: area.pane }));
    }
    app.hits.extend(hits);
}

/// Draw one pane's terminal content; returns the frame cursor position
/// when this pane is focused and its cursor is visible.
fn draw_content(
    app: &mut App,
    frame: &mut Frame,
    area: &PaneArea,
    focused: bool,
) -> Option<(u16, u16)> {
    let rect = area.content;
    if rect.width == 0 || rect.height == 0 {
        return None;
    }
    let surface = app.session.surface(area.surface)?;
    surface.take_dirty();

    let rs = app
        .render_states
        .entry(area.surface)
        .or_insert_with(|| RenderState::new().expect("render state alloc"));
    if surface.snapshot(rs).is_err() {
        return None;
    }
    rs.set_clean();

    let selection: Option<Selection> =
        app.selection.filter(|s| s.surface == area.surface && s.anchor != s.head);

    let screen = frame.area();
    let buf = frame.buffer_mut();
    let max_cols = rect.width.min(screen.width.saturating_sub(rect.x)) as usize;
    let max_rows = rect.height.min(screen.height.saturating_sub(rect.y)) as usize;

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
            let selected = selection.is_some_and(|s| s.contains(col as u16, row as u16));
            apply_cell(&mut buf[(x, y)], cell, selected);
        }
        // Pane narrower than the rect (during resize races): blank the rest.
        for col in cells.len()..max_cols {
            let x = rect.x + col as u16;
            buf[(x, y)].set_symbol(" ").set_style(Style::default());
        }
    })
    .ok()?;

    // Rows beyond what the snapshot provided.
    let (_, snap_rows) = rs.size();
    for row in (snap_rows as usize)..max_rows {
        let y = rect.y + row as u16;
        for col in 0..max_cols {
            let x = rect.x + col as u16;
            buf[(x, y)].set_symbol(" ").set_style(Style::default());
        }
    }

    if focused {
        if let Some(cursor) = rs.cursor() {
            if (cursor.x as usize) < max_cols && (cursor.y as usize) < max_rows {
                return Some((rect.x + cursor.x, rect.y + cursor.y));
            }
        }
    }
    None
}

/// Thin scrollbar in the content rect's last column, shown only while
/// the surface is scrolled back (like a transient overlay scrollbar).
/// The whole track is clickable/draggable.
fn draw_scrollbar(app: &mut App, frame: &mut Frame, area: &PaneArea) {
    let rect = area.content;
    if rect.width < 2 || rect.height < 2 {
        return;
    }
    let Some(surface) = app.session.surface(area.surface) else { return };
    let Some(sb) = surface.with_terminal(|t| t.scrollbar()) else { return };
    if !sb.scrolled_back() {
        return;
    }

    let track = Rect { x: rect.x + rect.width - 1, y: rect.y, width: 1, height: rect.height };
    let (thumb_y, thumb_len) = thumb_geometry(&sb, track.height);

    let screen = frame.area();
    let buf = frame.buffer_mut();
    let track_style = Style::default().fg(Color::Indexed(238));
    let thumb_style = Style::default().fg(Color::Indexed(246));
    for dy in 0..track.height {
        let y = track.y + dy;
        if track.x >= screen.width || y >= screen.height {
            continue;
        }
        // ▕ is a thin right-edge bar, so the scrollbar overlays the last
        // column without hiding much content.
        let in_thumb = dy >= thumb_y && dy < thumb_y + thumb_len;
        buf[(track.x, y)].set_symbol("▕").set_style(if in_thumb {
            thumb_style
        } else {
            track_style
        });
    }
    app.hits.push((track, Hit::Scrollbar { surface: area.surface, track }));
}

/// Thumb position and length (in track cells) for a scrollbar state.
fn thumb_geometry(sb: &Scrollbar, track_height: u16) -> (u16, u16) {
    let track = track_height.max(1) as f64;
    let len = ((sb.len as f64 / sb.total as f64) * track).ceil().clamp(1.0, track) as u16;
    let denom = (sb.total - sb.len).max(1) as f64;
    let frac = (sb.offset as f64 / denom).clamp(0.0, 1.0);
    let y = (frac * (track_height.saturating_sub(len)) as f64).round() as u16;
    (y, len)
}

fn apply_cell(target: &mut ratatui::buffer::Cell, cell: &VtCell, selected: bool) {
    if cell.text.is_empty() {
        target.set_symbol(" ");
    } else {
        target.set_symbol(&cell.text);
    }

    let mut style = Style::default();
    style = match cell.fg {
        Some(rgb) => style.fg(Color::Rgb(rgb.r, rgb.g, rgb.b)),
        None => style.fg(Color::Reset),
    };
    style = match cell.bg {
        Some(rgb) => style.bg(Color::Rgb(rgb.r, rgb.g, rgb.b)),
        None => style.bg(Color::Reset),
    };
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
    // Selection renders as reverse video on top of the cell's own style
    // (double-reverse cancels out, which still reads correctly).
    if selected {
        modifier ^= Modifier::REVERSED;
    }
    style = style.add_modifier(modifier);
    target.set_style(style);
}
