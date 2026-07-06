//! Left sidebar: a "workspaces" header (with a blank line under it),
//! then two lines per workspace (name, then the active pane's title)
//! with a blank line between workspaces, and a new-workspace row at the
//! end. Uses the terminal's default background so it blends with pane
//! content; only the active workspace rows get a highlight. Owns its
//! full column including the status-bar row (the status bar starts
//! after the sidebar). Rebuilds the click hit map as it draws.

use mux_core::Rect;
use ratatui::style::{Color, Modifier, Style};
use ratatui::Frame;

use super::truncate;
use crate::app::{App, Hit};

pub fn draw(app: &mut App, frame: &mut Frame) {
    let area = frame.area();
    let width = app.sidebar_width;
    let height = area.height;
    if width < 3 || height == 0 {
        return;
    }
    let content_w = (width - 1) as usize; // last column is the border
    let rail = app.config.theme.sidebar_rail;
    let buf = frame.buffer_mut();

    let base = Style::default();
    let dim = base.fg(Color::Indexed(242));
    let active_style = Style::default()
        .bg(app.config.theme.sidebar_active_bg)
        .fg(Color::Indexed(255))
        .add_modifier(Modifier::BOLD);
    let border = base.fg(Color::Indexed(237));

    for y in 0..height {
        for x in 0..width - 1 {
            buf[(x, y)].set_symbol(" ").set_style(base);
        }
        buf[(width - 1, y)].set_symbol("│").set_style(border);
    }

    let set_line = |buf: &mut ratatui::buffer::Buffer, y: u16, text: &str, style: Style| {
        buf.set_stringn(0, y, text, content_w, style);
    };
    let set_line_from =
        |buf: &mut ratatui::buffer::Buffer, x: u16, y: u16, text: &str, style: Style| {
            buf.set_stringn(x, y, text, content_w.saturating_sub(x as usize), style);
        };
    let row_rect = |y: u16| Rect { x: 0, y, width: width.saturating_sub(1), height: 1 };

    set_line(buf, 0, " workspaces", dim);

    // Header, a blank line, then per workspace: two reserved lines (name
    // + active pane title) and one blank separator line.
    let mut hits = Vec::new();
    let mut y: u16 = 2;
    for (i, ws) in app.tree.workspaces.iter().enumerate() {
        if y + 1 >= height {
            break;
        }
        let active = i == app.tree.active_workspace;
        let style = if active { active_style } else { base };
        // The active highlight paints the full rows, and the rail marks
        // BOTH lines of the entry in the configured color.
        if active {
            for x in 0..width - 1 {
                buf[(x, y)].set_style(active_style);
                buf[(x, y + 1)].set_style(active_style);
            }
            let rail_style = active_style.fg(rail);
            buf[(0, y)].set_symbol("▎").set_style(rail_style);
            buf[(0, y + 1)].set_symbol("▎").set_style(rail_style);
        }
        set_line_from(buf, 1, y, &truncate(&ws.name, content_w - 1), style);
        hits.push((row_rect(y), Hit::Workspace { index: i, id: ws.id }));

        let screen = ws.active_screen_ref();
        let pane = screen.and_then(|s| s.pane(s.active_pane));
        let title = pane.map(|p| p.display_name()).unwrap_or("shell");
        let screen_count = ws.screens.len();
        let subtitle = if screen_count > 1 {
            format!("  {} ({screen_count} screens)", truncate(title, content_w.saturating_sub(13)))
        } else {
            format!("  {}", truncate(title, content_w.saturating_sub(3)))
        };
        let sub_style = if active { active_style.add_modifier(Modifier::DIM) } else { dim };
        set_line_from(buf, 1, y + 1, subtitle.trim_start(), sub_style);
        hits.push((row_rect(y + 1), Hit::Workspace { index: i, id: ws.id }));
        y += 3; // two content lines + one blank separator line
    }

    if y < height {
        set_line(buf, y, " + new workspace", dim);
        hits.push((row_rect(y), Hit::NewWorkspace));
    }
    hits.push((Rect { x: width - 1, y: 0, width: 1, height }, Hit::SidebarResize));
    app.hits.extend(hits);
}
