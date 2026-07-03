//! Frame drawing: sidebar, panes (tab bar + ghostty render state),
//! separators, status bar, and overlays (context menu, rename prompt).

mod overlay;
mod pane;
mod sidebar;

use ratatui::layout::Position;
use ratatui::style::{Color, Modifier, Style};
use ratatui::Frame;

use crate::app::App;

pub fn draw(app: &mut App, frame: &mut Frame) {
    let area = frame.area();
    if area.height == 0 {
        return;
    }

    if app.sidebar_width > 0 {
        sidebar::draw(app, frame);
    } else {
        app.sidebar_hits.clear();
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

fn draw_status_bar(app: &mut App, frame: &mut Frame) {
    let area = frame.area();
    let status_y = area.height - 1;
    let status_style = Style::default().bg(Color::Indexed(236)).fg(Color::Indexed(250));
    for x in 0..area.width {
        frame.buffer_mut()[(x, status_y)].set_symbol(" ").set_style(status_style);
    }

    if let Some(prompt) = &app.prompt {
        let text = format!(" {}: {}", prompt.label, prompt.buffer);
        let prompt_style = Style::default().bg(Color::Indexed(236)).fg(Color::Indexed(255));
        frame.buffer_mut().set_stringn(0, status_y, &text, area.width as usize, prompt_style);
        let cursor_x = (text.chars().count() as u16).min(area.width.saturating_sub(1));
        frame.set_cursor_position(Position::new(cursor_x, status_y));
        return;
    }

    let status = status_line(app);
    frame.buffer_mut().set_stringn(0, status_y, &status, area.width as usize, status_style);
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

fn status_line(app: &App) -> String {
    let mut status = format!("[{}]", app.session_label);
    for (i, ws) in app.tree.workspaces.iter().enumerate() {
        if i == app.tree.active_workspace {
            status.push_str(&format!(" {}*", ws.name));
            if let Some(pane) = ws.pane(ws.active_pane) {
                let tabs = pane
                    .tabs
                    .iter()
                    .enumerate()
                    .map(|(t, tab)| {
                        let marker = if t == pane.active_tab { "*" } else { "" };
                        format!("{}:{}{}", t + 1, truncate(tab.display_title(), 18), marker)
                    })
                    .collect::<Vec<_>>()
                    .join(" ");
                status.push_str(&format!("  {tabs}"));
            }
        } else {
            status.push_str(&format!(" {}", ws.name));
        }
    }
    status
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
