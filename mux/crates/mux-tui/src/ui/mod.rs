//! Frame drawing: sidebar, panes (border box with tab bar, ghostty
//! render state, and scrollbar), status bar, and overlays (context menu,
//! rename prompt). Every renderer that draws something interactive also
//! pushes a [`Hit`] so clicks always match what is on screen.

pub mod graphics;
pub mod omnibar;
mod overlay;
mod pane;
mod scrollbar;
mod sidebar;

use mux_core::Rect;
use ratatui::layout::Position;
use ratatui::style::{Color, Modifier, Style};
use ratatui::Frame;

use crate::app::{App, Hit};

pub(crate) use scrollbar::thumb_geometry;

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
    draw_status_bar(app, frame);
    overlay::draw_menu(app, frame);

    // The dialog owns the terminal cursor while it is open (draw_prompt
    // sets it on the input row).
    if app.prompt.is_some() {
        overlay::draw_prompt(app, frame);
    } else if app.menu.is_none() {
        if let Some((x, y)) = cursor {
            frame.set_cursor_position(Position::new(x, y));
        }
    }
}

/// Status bar: the active workspace's screens, one clickable segment per
/// screen plus a trailing `+` for a new one. It spans only the pane
/// region (it does not extend under the sidebar).
fn draw_status_bar(app: &mut App, frame: &mut Frame) {
    let area = frame.area();
    let status_y = area.height - 1;
    let bar_x = app.sidebar_width.min(area.width);
    let base = Style::default().bg(Color::Indexed(236)).fg(Color::Indexed(250));
    for x in bar_x..area.width {
        frame.buffer_mut()[(x, status_y)].set_symbol(" ").set_style(base);
    }

    let active_style = Style::default()
        .bg(Color::Indexed(240))
        .fg(Color::Indexed(255))
        .add_modifier(Modifier::BOLD);
    let mut x: u16 = bar_x;
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

    let Some(ws) = app.tree.active_workspace().cloned() else { return };
    put(frame, &mut x, " screens ", base.fg(Color::Indexed(244)));
    for (i, screen) in ws.screens.iter().enumerate() {
        let active = i == ws.active_screen;
        let label = format!(" {} ", truncate(&screen.display_name(i), 20));
        let (start, width) = put(frame, &mut x, &label, if active { active_style } else { base });
        if width > 0 {
            hits.push((
                Rect { x: start, y: status_y, width, height: 1 },
                Hit::ScreenEntry { index: i, id: screen.id },
            ));
        }
    }
    let (start, width) = put(frame, &mut x, " + ", base.fg(Color::Indexed(244)));
    if width > 0 {
        hits.push((Rect { x: start, y: status_y, width, height: 1 }, Hit::NewScreen));
    }
    app.hits.extend(hits);

    // Session label / status message, right-aligned (the prefix indicator
    // replaces it).
    let label = app
        .status_message
        .as_ref()
        .map(|msg| format!(" {} ", truncate(msg, area.width.saturating_sub(x) as usize)))
        .unwrap_or_else(|| format!("[{}] ", app.session_label));
    let label_w = label.chars().count() as u16;
    if !app.prefix_armed && x + label_w < area.width {
        frame.buffer_mut().set_stringn(
            area.width - label_w,
            status_y,
            &label,
            label_w as usize,
            if app.status_message.is_some() {
                base.fg(Color::Red).add_modifier(Modifier::BOLD)
            } else {
                base.fg(Color::Indexed(244))
            },
        );
    }

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
