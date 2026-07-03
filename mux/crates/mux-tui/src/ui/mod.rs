//! Frame drawing: sidebar, panes (tab bar + ghostty render state +
//! scrollbar), separators, status bar, and overlays (context menu,
//! rename prompt). Every renderer that draws something interactive also
//! pushes a [`Hit`] so clicks always match what is on screen.

mod overlay;
mod pane;
mod sidebar;

use mux_core::Rect;
use ratatui::layout::Position;
use ratatui::style::{Color, Modifier, Style};
use ratatui::Frame;

use crate::app::{App, Hit};

pub fn draw(app: &mut App, frame: &mut Frame) {
    let area = frame.area();
    if area.height == 0 {
        return;
    }

    app.hits.clear();
    if app.sidebar_width > 0 {
        sidebar::draw(app, frame);
    }

    let cursor = pane::draw_all(app, frame);
    draw_separators(app, frame);
    draw_status_bar(app, frame);
    overlay::draw_menu(app, frame);

    // The prompt owns the terminal cursor while it is open.
    if app.prompt.is_none() {
        if let Some((x, y)) = cursor {
            frame.set_cursor_position(Position::new(x, y));
        }
    }
}

fn draw_separators(app: &App, frame: &mut Frame) {
    let area = frame.area();
    let sep_style = Style::default().fg(Color::DarkGray);
    for sep in &app.separators {
        let symbol = if sep.vertical { "│" } else { "─" };
        for dy in 0..sep.rect.height {
            for dx in 0..sep.rect.width {
                let x = sep.rect.x + dx;
                let y = sep.rect.y + dy;
                if x < area.width && y < area.height {
                    frame.buffer_mut()[(x, y)].set_symbol(symbol).set_style(sep_style);
                }
            }
        }
    }
}

/// Status bar: session label, then one clickable segment per workspace,
/// and the active pane's tabs (also clickable).
fn draw_status_bar(app: &mut App, frame: &mut Frame) {
    let area = frame.area();
    let status_y = area.height - 1;
    let base = Style::default().bg(Color::Indexed(236)).fg(Color::Indexed(250));
    for x in 0..area.width {
        frame.buffer_mut()[(x, status_y)].set_symbol(" ").set_style(base);
    }

    if let Some(prompt) = &app.prompt {
        let text = format!(" {}: {}", prompt.label, prompt.buffer);
        let prompt_style = Style::default().bg(Color::Indexed(236)).fg(Color::Indexed(255));
        frame.buffer_mut().set_stringn(0, status_y, &text, area.width as usize, prompt_style);
        let cursor_x = (text.chars().count() as u16).min(area.width.saturating_sub(1));
        frame.set_cursor_position(Position::new(cursor_x, status_y));
        return;
    }

    let active_style = base.fg(Color::Indexed(255)).add_modifier(Modifier::BOLD);
    let mut x: u16 = 0;
    let mut hits = Vec::new();
    let put = |frame: &mut Frame, x: &mut u16, text: &str, style: Style| -> (u16, u16) {
        let start = *x;
        let width = (text.chars().count() as u16).min(area.width.saturating_sub(*x));
        if width > 0 {
            frame.buffer_mut().set_stringn(*x, status_y, text, width as usize, style);
            *x += width;
        }
        (start, width)
    };

    put(frame, &mut x, &format!("[{}]", app.session_label), base);
    let workspaces = app.tree.workspaces.clone();
    let active_ws = app.tree.active_workspace;
    for (i, ws) in workspaces.iter().enumerate() {
        let active = i == active_ws;
        let label = if active { format!(" {}*", ws.name) } else { format!(" {}", ws.name) };
        let (start, width) = put(frame, &mut x, &label, if active { active_style } else { base });
        if width > 0 {
            hits.push((
                Rect { x: start, y: status_y, width, height: 1 },
                Hit::Workspace { index: i, id: ws.id },
            ));
        }
        if !active {
            continue;
        }
        // The active workspace also lists its active pane's tabs.
        let Some(pane) = ws.pane(ws.active_pane) else { continue };
        put(frame, &mut x, " ", base);
        for (t, tab) in pane.tabs.iter().enumerate() {
            let marker = if t == pane.active_tab { "*" } else { "" };
            let label = format!(" {}:{}{}", t + 1, truncate(tab.display_title(), 18), marker);
            let style = if t == pane.active_tab { active_style } else { base };
            let (start, width) = put(frame, &mut x, &label, style);
            if width > 0 {
                hits.push((
                    Rect { x: start, y: status_y, width, height: 1 },
                    Hit::Tab { pane: pane.id, index: t },
                ));
            }
        }
    }
    app.hits.extend(hits);

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
}

pub(crate) fn truncate(s: &str, max: usize) -> String {
    if s.chars().count() <= max {
        s.to_string()
    } else {
        let mut out: String = s.chars().take(max.saturating_sub(1)).collect();
        out.push('…');
        out
    }
}

pub(crate) fn bar_base_style() -> Style {
    Style::default().bg(Color::Indexed(234)).fg(Color::Indexed(246))
}

pub(crate) fn bar_active_style() -> Style {
    Style::default().bg(Color::Indexed(238)).fg(Color::Indexed(255)).add_modifier(Modifier::BOLD)
}
