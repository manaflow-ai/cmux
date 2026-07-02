//! Frame drawing: panes from ghostty render state, separators, status bar.

use ghostty_vt::{Cell as VtCell, CursorShape, RenderState};
use mux_core::PaneId;
use ratatui::layout::Position;
use ratatui::style::{Color, Modifier, Style};
use ratatui::Frame;

use crate::app::App;

pub fn draw(app: &mut App, frame: &mut Frame) {
    let area = frame.area();
    if area.height == 0 {
        return;
    }

    let (active_pane, status) = gather_status(app);

    // Panes.
    let panes = app.layout.panes.clone();
    let mut cursor: Option<(u16, u16, CursorShape)> = None;
    for (pane_id, rect) in panes {
        let focused = Some(pane_id) == active_pane;
        if let Some(c) = draw_pane(app, frame, pane_id, rect, focused) {
            cursor = Some(c);
        }
    }

    // Separators.
    let sep_style = Style::default().fg(Color::DarkGray);
    for sep in &app.layout.separators {
        let symbol = if sep.vertical { "│" } else { "─" };
        for dy in 0..sep.rect.height {
            for dx in 0..sep.rect.width {
                let x = sep.rect.x + dx;
                let y = sep.rect.y + dy;
                if x < area.width && y < area.height {
                    frame.buffer_mut()[(x, y)]
                        .set_symbol(symbol)
                        .set_style(sep_style);
                }
            }
        }
    }

    // Status bar (bottom row).
    let status_y = area.height - 1;
    let status_style = Style::default().bg(Color::Indexed(236)).fg(Color::Indexed(250));
    for x in 0..area.width {
        frame.buffer_mut()[(x, status_y)].set_symbol(" ").set_style(status_style);
    }
    frame.buffer_mut().set_stringn(
        0,
        status_y,
        &status,
        area.width as usize,
        status_style,
    );
    if app.prefix_armed {
        let indicator = " C-b ";
        let x = area.width.saturating_sub(indicator.len() as u16);
        frame.buffer_mut().set_stringn(
            x,
            status_y,
            indicator,
            indicator.len(),
            Style::default().bg(Color::Yellow).fg(Color::Black),
        );
    }

    if let Some((x, y, _shape)) = cursor {
        frame.set_cursor_position(Position::new(x, y));
    }
}

fn gather_status(app: &App) -> (Option<PaneId>, String) {
    app.mux.with_state(|workspaces, active_ws, panes| {
        let mut status = format!("[{}]", app.session_label);
        let mut active_pane = None;
        for (i, ws) in workspaces.iter().enumerate() {
            if i == active_ws {
                status.push_str(&format!(" {}*", ws.name));
                let tabs = ws
                    .tabs
                    .iter()
                    .enumerate()
                    .map(|(t, tab)| {
                        let title = panes
                            .get(&tab.active_pane)
                            .map(|p| p.title())
                            .filter(|t| !t.is_empty())
                            .unwrap_or_else(|| "shell".into());
                        let marker = if t == ws.active_tab { "*" } else { "" };
                        format!("{}:{}{}", t + 1, truncate(&title, 18), marker)
                    })
                    .collect::<Vec<_>>()
                    .join(" ");
                status.push_str(&format!("  {tabs}"));
                if let Some(tab) = ws.tabs.get(ws.active_tab) {
                    active_pane = Some(tab.active_pane);
                }
            } else {
                status.push_str(&format!(" {}", ws.name));
            }
        }
        (active_pane, status)
    })
}

fn truncate(s: &str, max: usize) -> String {
    if s.chars().count() <= max {
        s.to_string()
    } else {
        let mut out: String = s.chars().take(max.saturating_sub(1)).collect();
        out.push('…');
        out
    }
}

/// Draw one pane; returns the frame cursor position when this pane is
/// focused and its cursor is visible.
fn draw_pane(
    app: &mut App,
    frame: &mut Frame,
    pane_id: PaneId,
    rect: mux_core::Rect,
    focused: bool,
) -> Option<(u16, u16, CursorShape)> {
    let pane = app.mux.pane(pane_id)?;
    pane.take_dirty();

    let rs = app
        .render_states
        .entry(pane_id)
        .or_insert_with(|| RenderState::new().expect("render state alloc"));
    if pane.snapshot(rs).is_err() {
        return None;
    }
    rs.set_clean();

    let area = frame.area();
    let buf = frame.buffer_mut();
    let max_cols = rect.width.min(area.width.saturating_sub(rect.x)) as usize;
    let max_rows = rect.height.min(area.height.saturating_sub(rect.y)) as usize;

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
            let target = &mut buf[(x, y)];
            apply_cell(target, cell);
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
                return Some((rect.x + cursor.x, rect.y + cursor.y, cursor.shape));
            }
        }
    }
    None
}

fn apply_cell(target: &mut ratatui::buffer::Cell, cell: &VtCell) {
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
    style = style.add_modifier(modifier);
    target.set_style(style);
}
