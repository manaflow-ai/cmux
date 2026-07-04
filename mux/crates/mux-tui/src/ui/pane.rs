//! Pane drawing: each pane renders a border box in its rect. The top
//! border row doubles as the tab bar (always visible, with overflow
//! scrolling), the right border column doubles as the scrollbar (shown
//! whenever the surface has any scrollback), and the interior is the
//! terminal content from the ghostty render state (with selection
//! highlight). The active pane's border is highlighted — this is also
//! where flashing notifications will hook in later.

use ghostty_vt::{Cell as VtCell, RenderState, Scrollbar};
use mux_core::Rect;
use ratatui::style::{Color, Modifier, Style};
use ratatui::Frame;

use super::truncate;
use crate::app::{App, Hit, PaneArea, Selection};

/// Border style for a pane box: active gets the accent color, idle
/// stays dim. Notification flashing will slot in here as another state
/// later. (No hover state: mousing across terminals should not light up
/// their borders.)
fn border_style(focused: bool) -> Style {
    if focused {
        Style::default().fg(Color::Indexed(110))
    } else {
        Style::default().fg(Color::Indexed(238))
    }
}

/// Draw every pane of the current frame. Returns the terminal cursor
/// position for the focused pane, if visible.
pub fn draw_all(app: &mut App, frame: &mut Frame) -> Option<(u16, u16)> {
    let active_pane = app.tree.active_screen().map(|screen| screen.active_pane);
    let areas = app.pane_areas.clone();
    let mut cursor = None;
    for area in &areas {
        let focused = Some(area.pane) == active_pane;
        draw_box(app, frame, area, focused);
        if area.bar.is_some() {
            draw_tab_bar(app, frame, area, focused);
        }
        if let Some(c) = draw_content(app, frame, area, focused) {
            cursor = Some(c);
        }
        draw_scrollbar(app, frame, area, focused);
    }
    cursor
}

/// The pane's border box. The top row is left to the tab bar; here we
/// draw the left/right/bottom edges and the corners.
fn draw_box(_app: &mut App, frame: &mut Frame, area: &PaneArea, focused: bool) {
    let rect = area.rect;
    if area.bar.is_none() || rect.width < 2 || rect.height < 2 {
        return;
    }
    let screen = frame.area();
    let buf = frame.buffer_mut();
    let style = border_style(focused);
    let (x0, y0) = (rect.x, rect.y);
    let (x1, y1) = (rect.x + rect.width - 1, rect.y + rect.height - 1);
    if x1 >= screen.width || y1 >= screen.height {
        return;
    }
    for x in x0 + 1..x1 {
        buf[(x, y1)].set_symbol("─").set_style(style);
    }
    for y in y0 + 1..y1 {
        buf[(x0, y)].set_symbol("│").set_style(style);
        buf[(x1, y)].set_symbol("│").set_style(style);
    }
    buf[(x0, y0)].set_symbol("┌").set_style(style);
    buf[(x1, y0)].set_symbol("┐").set_style(style);
    buf[(x0, y1)].set_symbol("└").set_style(style);
    buf[(x1, y1)].set_symbol("┘").set_style(style);
}

/// The top border row: `┌` + tabs + `+` + `─...─` + `┐`, with `‹`/`›`
/// overflow arrows when the tabs don't fit. Always visible so a new tab
/// is always one click away.
fn draw_tab_bar(app: &mut App, frame: &mut Frame, area: &PaneArea, focused: bool) {
    let Some(bar) = area.bar else { return };
    let Some(screen_view) = app.tree.active_screen() else { return };
    let Some(pane) = screen_view.pane(area.pane) else { return };
    let tabs: Vec<String> = pane.tabs.iter().enumerate().map(|(i, t)| t.display_title(i)).collect();
    let active_tab = pane.active_tab;
    let pane_id = area.pane;
    let hover = app.hover;

    let screen = frame.area();
    if bar.width < 2 || bar.y >= screen.height {
        return;
    }
    let style = border_style(focused);
    let base = Style::default().fg(Color::Indexed(246));
    let active_style = if focused {
        Style::default().fg(Color::Indexed(255)).add_modifier(Modifier::BOLD)
    } else {
        Style::default().fg(Color::Indexed(250))
    };
    // Hover highlight for the bar's controls (+, ‹, ›).
    let hovered_ctrl = |rect: Rect| hover.is_some_and(|(hx, hy)| rect.contains(hx, hy));
    let ctrl_style = |rect: Rect| {
        if hovered_ctrl(rect) {
            Style::default().fg(Color::Indexed(255)).add_modifier(Modifier::BOLD)
        } else {
            base
        }
    };

    // Fill the whole top row with the border line first; tabs overlay it.
    let buf = frame.buffer_mut();
    let (x0, x1) = (bar.x, bar.x + bar.width - 1);
    buf[(x0, bar.y)].set_symbol("┌").set_style(style);
    buf[(x1, bar.y)].set_symbol("┐").set_style(style);
    for x in x0 + 1..x1 {
        buf[(x, bar.y)].set_symbol("─").set_style(style);
    }

    // Layout the tab labels: " 1 zsh " ... " + ", scrolled so the range
    // starting at tab_scroll fits; the active tab is always kept visible.
    let labels: Vec<String> = tabs.iter().map(|t| format!(" {} ", truncate(t, 16))).collect();
    let widths: Vec<u16> = labels.iter().map(|l| l.chars().count() as u16).collect();
    let inner_w = bar.width.saturating_sub(2); // between the corners
    let plus_w: u16 = 3; // " + "
    let arrow_w: u16 = 1;

    // Clamp the requested scroll, then bump it until the active tab fits.
    let max_scroll = tabs.len().saturating_sub(1);
    let mut scroll = app.tab_scroll.get(&pane_id).copied().unwrap_or(0).min(max_scroll);
    let fits = |scroll: usize| {
        let left_arrow = if scroll > 0 { arrow_w } else { 0 };
        let mut budget = inner_w.saturating_sub(left_arrow + plus_w + arrow_w);
        for w in &widths[scroll..=active_tab.max(scroll)] {
            if *w > budget {
                return false;
            }
            budget -= *w;
        }
        true
    };
    while scroll < active_tab && !fits(scroll) {
        scroll += 1;
    }
    app.tab_scroll.insert(pane_id, scroll);

    let mut hits = Vec::new();
    let mut x = x0 + 1;
    let max_x = x1; // exclusive
    if scroll > 0 {
        let rect = Rect { x, y: bar.y, width: arrow_w, height: 1 };
        buf.set_stringn(x, bar.y, "‹", 1, ctrl_style(rect));
        hits.push((rect, Hit::TabScroll { pane: pane_id, delta: -1 }));
        x += arrow_w;
    }
    let mut overflow = false;
    for (i, label) in labels.iter().enumerate().skip(scroll) {
        let w = widths[i];
        // Reserve room for the + button and a possible right arrow.
        if x + w + plus_w + arrow_w > max_x {
            overflow = true;
            break;
        }
        let style = if i == active_tab { active_style } else { base };
        buf.set_stringn(x, bar.y, label, w as usize, style);
        hits.push((
            Rect { x, y: bar.y, width: w, height: 1 },
            Hit::Tab { pane: pane_id, index: i },
        ));
        x += w;
    }
    if overflow && x + arrow_w <= max_x {
        let rect = Rect { x, y: bar.y, width: arrow_w, height: 1 };
        buf.set_stringn(x, bar.y, "›", 1, ctrl_style(rect));
        hits.push((rect, Hit::TabScroll { pane: pane_id, delta: 1 }));
        x += arrow_w;
    }
    if x + plus_w <= max_x {
        let rect = Rect { x, y: bar.y, width: plus_w, height: 1 };
        buf.set_stringn(x, bar.y, " + ", plus_w as usize, ctrl_style(rect));
        hits.push((rect, Hit::NewTab { pane: pane_id }));
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

/// Scrollbar in the right border column. Visible whenever the surface
/// has any scrollback (total > viewport); hidden only when no scrolling
/// is possible at all. The thumb overlays the border line; the whole
/// track is clickable/draggable.
fn draw_scrollbar(app: &mut App, frame: &mut Frame, area: &PaneArea, focused: bool) {
    let Some(track) = area.track else { return };
    if track.height == 0 {
        return;
    }
    let Some(surface) = app.session.surface(area.surface) else { return };
    let Some(sb) = surface.with_terminal(|t| t.scrollbar()) else { return };
    if sb.total <= sb.len {
        return; // nothing to scroll: no scrollbar
    }

    let (thumb_y, thumb_len) = thumb_geometry(&sb, track.height);

    let screen = frame.area();
    let buf = frame.buffer_mut();
    let thumb_style = if focused {
        Style::default().fg(Color::Indexed(252))
    } else {
        Style::default().fg(Color::Indexed(246))
    };
    for dy in 0..track.height {
        let y = track.y + dy;
        if track.x >= screen.width || y >= screen.height {
            continue;
        }
        // The track stays the border line (drawn by draw_box); only the
        // thumb overlays it with a solid bar.
        if dy >= thumb_y && dy < thumb_y + thumb_len {
            buf[(track.x, y)].set_symbol("┃").set_style(thumb_style);
        }
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
