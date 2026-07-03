//! Left sidebar: a "workspaces" header, then two lines per workspace
//! (name, then the active pane's title) with a blank line between
//! workspaces, and a new-workspace row at the end. Rebuilds the click
//! hit map as it draws.

use ratatui::style::{Color, Modifier, Style};
use ratatui::Frame;

use super::truncate;
use crate::app::{App, SidebarRow};

pub fn draw(app: &mut App, frame: &mut Frame) {
    let area = frame.area();
    let width = app.sidebar_width;
    let height = area.height.saturating_sub(1); // status bar
    app.sidebar_hits.clear();
    if width < 3 || height == 0 {
        return;
    }
    let content_w = (width - 1) as usize; // last column is the border
    let buf = frame.buffer_mut();

    let base = Style::default().bg(Color::Indexed(233)).fg(Color::Indexed(248));
    let dim = base.fg(Color::Indexed(242));
    let active_style = Style::default()
        .bg(Color::Indexed(236))
        .fg(Color::Indexed(255))
        .add_modifier(Modifier::BOLD);
    let border = Style::default().bg(Color::Indexed(233)).fg(Color::Indexed(237));

    for y in 0..height {
        for x in 0..width - 1 {
            buf[(x, y)].set_symbol(" ").set_style(base);
        }
        buf[(width - 1, y)].set_symbol("│").set_style(border);
    }

    let set_line = |buf: &mut ratatui::buffer::Buffer, y: u16, text: &str, style: Style| {
        buf.set_stringn(0, y, text, content_w, style);
    };

    set_line(buf, 0, " workspaces", dim.add_modifier(Modifier::BOLD));

    // Header, then per workspace: two reserved lines (name + active pane
    // title), then one blank separator line.
    let mut y: u16 = 1;
    for (i, ws) in app.tree.workspaces.iter().enumerate() {
        if y + 1 >= height {
            break;
        }
        let active = i == app.tree.active_workspace;
        let style = if active { active_style } else { base };
        let marker = if active { "▎" } else { " " };
        set_line(buf, y, &format!("{marker}{}", truncate(&ws.name, content_w - 1)), style);
        app.sidebar_hits.push((y, SidebarRow::Workspace { index: i, id: ws.id }));

        let pane = ws.pane(ws.active_pane);
        let title = pane.map(|p| p.display_name()).unwrap_or("shell");
        let tab_count = pane.map(|p| p.tabs.len()).unwrap_or(1);
        let subtitle = if tab_count > 1 {
            format!("  {} ({tab_count} tabs)", truncate(title, content_w.saturating_sub(10)))
        } else {
            format!("  {}", truncate(title, content_w.saturating_sub(3)))
        };
        let sub_style = if active { active_style.add_modifier(Modifier::DIM) } else { dim };
        set_line(buf, y + 1, &subtitle, sub_style);
        app.sidebar_hits.push((y + 1, SidebarRow::Workspace { index: i, id: ws.id }));
        y += 3; // two content lines + one blank separator line
    }

    if y < height {
        set_line(buf, y, " + new workspace", dim);
        app.sidebar_hits.push((y, SidebarRow::NewWorkspace));
    }
}
