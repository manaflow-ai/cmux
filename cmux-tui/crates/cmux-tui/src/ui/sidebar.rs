//! Left sidebar renderer for the built-in files/workspaces views and the
//! external plugin PTY. Owns its full column including the status-bar row
//! (the status bar starts after the sidebar) and rebuilds the click hit map
//! as it draws.

use cmux_tui_core::Rect;
use ratatui::Frame;
use ratatui::style::{Color, Modifier, Style};

use super::{middle_truncate, truncate};
use crate::app::{App, Hit};
use crate::config::SidebarView;

/// The color of a workspace's unread indicator, or `None` when nothing is
/// unread. Mirrors the tab-bar severity cue (`error` > `warning` > `info`)
/// so the sidebar dot carries the same meaning as the per-tab marker.
fn workspace_unread_color(
    theme: &crate::config::Theme,
    ws: &crate::session::WorkspaceView,
) -> Option<Color> {
    ws.screens
        .iter()
        .flat_map(|screen| screen.panes.iter())
        .flat_map(|pane| pane.tabs.iter())
        .filter_map(|tab| tab.notification.filter(|notification| notification.unread))
        .map(|notification| match notification.level {
            "error" => (2u8, theme.notification_error),
            "warning" => (1, theme.notification_warning),
            _ => (0, theme.notification_info),
        })
        .max_by_key(|(rank, _)| *rank)
        .map(|(_, color)| color)
}

pub fn draw(app: &mut App, frame: &mut Frame) {
    if app.config.sidebar.plugin.is_some() {
        draw_plugin(app, frame);
        return;
    }
    match app.sidebar_view {
        SidebarView::Files => draw_files(app, frame),
        SidebarView::Workspaces => draw_workspaces(app, frame),
    }
}

fn draw_plugin(app: &mut App, frame: &mut Frame) {
    let area = frame.area();
    let width = app.sidebar_width;
    let height = area.height;
    if width < 3 || height == 0 {
        return;
    }
    let content = app.sidebar_plugin_rect();
    let border_x = width - 1;
    let focused = app.sidebar_focused;
    let border_style = Style::default().fg(if focused {
        app.config.theme.border_active
    } else {
        app.config.theme.border_inactive
    });
    {
        let buf = frame.buffer_mut();
        for y in 0..height {
            buf[(border_x, y)].set_symbol("│").set_style(border_style);
        }
    }
    // The divider column is a drag handle exactly like the built-in sidebar's;
    // without this hit zone, drag-resize is dead whenever a plugin owns the
    // sidebar (the plugin rect stops one column short of the divider).
    app.hits.push((Rect { x: border_x, y: 0, width: 1, height }, Hit::SidebarResize));
    if let Some(surface_id) = app.sidebar_plugin_surface {
        let Some(surface) = app.session.surface(surface_id) else { return };
        surface.take_dirty();
        let theme = app.config.theme;
        let rs = app
            .render_states
            .entry(surface_id)
            .or_insert_with(|| ghostty_vt::RenderState::new().expect("render state alloc"));
        if surface.snapshot(rs).is_ok() {
            rs.set_clean();
            let _ =
                super::terminal_grid::draw_render_state(frame, content, rs, &theme, |_, _| false);
            {
                let buf = frame.buffer_mut();
                for y in 0..height {
                    buf[(border_x, y)].set_symbol("│").set_style(border_style);
                }
            }
            return;
        }
    }
    let message = app.sidebar_plugin_error.as_deref().unwrap_or("sidebar plugin unavailable");
    let base = Style::default();
    let dim = base.fg(Color::Indexed(244));
    let buf = frame.buffer_mut();
    for y in 0..height {
        for x in 0..content.width {
            buf[(x, y)].set_symbol(" ").set_style(base);
        }
    }
    let text = truncate(message, content.width.saturating_sub(2) as usize);
    if content.width > 2 {
        buf.set_stringn(1, height / 2, &text, content.width.saturating_sub(2) as usize, dim);
    }
}

fn draw_workspaces(app: &mut App, frame: &mut Frame) {
    let area = frame.area();
    let width = app.sidebar_width;
    let height = area.height;
    if width < 3 || height == 0 {
        return;
    }
    let content_w = (width - 1) as usize; // last column is the border
    let rail = app.config.theme.sidebar_rail;
    let workspace_drag = app.workspace_drag();
    let buf = frame.buffer_mut();

    let chrome = app.chrome;
    let selected_bg = if app.config.theme_overrides.sidebar_active_bg {
        app.config.theme.sidebar_active_bg
    } else {
        chrome.sidebar_selected_bg
    };
    let base = Style::default();
    let dim = base.fg(chrome.sidebar_dim_fg);
    let active_style = Style::default()
        .bg(selected_bg)
        .fg(chrome.sidebar_selected_fg)
        .add_modifier(Modifier::BOLD);
    let border = base.fg(chrome.sidebar_border);

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
        let focused_selection = app.sidebar_focused && i == app.sidebar_workspace_selection;
        let highlighted = active || focused_selection;
        let mut style = if highlighted { active_style } else { base };
        if workspace_drag.is_some_and(|(id, _)| id == ws.id) {
            style = style.add_modifier(Modifier::DIM);
        }
        // The active highlight paints the full rows, and the rail marks
        // BOTH lines of the entry in the configured color.
        if highlighted {
            for x in 0..width - 1 {
                buf[(x, y)].set_style(active_style);
                buf[(x, y + 1)].set_style(active_style);
            }
            if active {
                let rail_style = active_style.fg(rail);
                buf[(0, y)].set_symbol("▎").set_style(rail_style);
                buf[(0, y + 1)].set_symbol("▎").set_style(rail_style);
            }
        }
        if content_w > 1
            && let Some(color) = workspace_unread_color(&app.config.theme, ws)
        {
            let dot_style = style.fg(color).add_modifier(Modifier::BOLD);
            buf[(0, y)].set_symbol("•").set_style(dot_style);
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
        let sub_style = if highlighted { active_style.add_modifier(Modifier::DIM) } else { dim };
        set_line_from(buf, 1, y + 1, subtitle.trim_start(), sub_style);
        hits.push((row_rect(y + 1), Hit::Workspace { index: i, id: ws.id }));
        y += 3; // two content lines + one blank separator line
    }

    if let Some((_, Some(index))) = workspace_drag {
        let marker_y = 2u16.saturating_add(index as u16 * 3).saturating_sub(1);
        if marker_y < height {
            for x in 0..width - 1 {
                buf[(x, marker_y)]
                    .set_symbol("─")
                    .set_style(Style::default().fg(app.config.theme.border_active));
            }
        }
    }

    if y < height {
        set_line(buf, y, " + new workspace", dim);
        hits.push((row_rect(y), Hit::NewWorkspace));
    }
    hits.push((Rect { x: width - 1, y: 0, width: 1, height }, Hit::SidebarResize));
    app.hits.extend(hits);
}

fn draw_files(app: &mut App, frame: &mut Frame) {
    let area = frame.area();
    let width = app.sidebar_width;
    let height = area.height;
    if width < 3 || height == 0 {
        return;
    }
    let content_width = width - 1;
    let content_w = content_width as usize;
    let chrome = app.chrome;
    let base = Style::default();
    let dim = base.fg(chrome.sidebar_dim_fg);
    let selected_bg = if app.config.theme_overrides.sidebar_active_bg {
        app.config.theme.sidebar_active_bg
    } else {
        chrome.sidebar_selected_bg
    };
    let selected_style = Style::default()
        .bg(selected_bg)
        .fg(chrome.sidebar_selected_fg)
        .add_modifier(Modifier::BOLD);
    let border = base.fg(if app.sidebar_focused {
        app.config.theme.border_active
    } else {
        chrome.sidebar_border
    });

    let entries = app
        .sidebar_files
        .visible_entries()
        .map(|entry| (entry.name.clone(), entry.is_dir()))
        .collect::<Vec<_>>();
    let selected = app.sidebar_files.selected();
    let current_dir = app.sidebar_files.current_dir().to_string_lossy().into_owned();
    let pinned = app.sidebar_files.is_pinned();
    let filter_mode = app.sidebar_files.filter_mode();
    let query = app.sidebar_files.query().to_string();
    let show_hidden = app.sidebar_files.show_hidden();
    let total = app.sidebar_files.total_len();
    let listing_error = app.sidebar_files.listing_error().map(str::to_owned);
    let message = app.sidebar_files.message().map(str::to_owned);
    let unread = unread_summary(app);

    let buf = frame.buffer_mut();
    for y in 0..height {
        for x in 0..content_width {
            buf[(x, y)].set_symbol(" ").set_style(base);
        }
        buf[(width - 1, y)].set_symbol("│").set_style(border);
    }

    let marker = if pinned { "● " } else { "  " };
    buf.set_stringn(0, 0, marker, content_w, dim);
    let badge = unread.map(|(count, _)| format!("• {count}"));
    let badge_width = badge.as_ref().map(|text| text.chars().count()).unwrap_or(0);
    let path_width = content_w.saturating_sub(2 + badge_width + usize::from(badge_width > 0));
    let path = middle_truncate(&current_dir, path_width);
    buf.set_stringn(2, 0, &path, path_width, base.add_modifier(Modifier::BOLD));
    if let (Some(text), Some((_, color))) = (badge, unread) {
        let badge_x = content_width.saturating_sub(text.chars().count() as u16);
        buf.set_stringn(
            badge_x,
            0,
            &text,
            text.chars().count(),
            base.fg(color).add_modifier(Modifier::BOLD),
        );
    }

    let body_start = 1;
    let body_height = height.saturating_sub(2) as usize;
    let mut hits = Vec::new();
    if let Some(error) = listing_error {
        if body_height > 0 {
            buf.set_stringn(0, body_start, truncate(&error, content_w), content_w, dim);
        }
    } else if entries.is_empty() {
        if body_height > 0 {
            buf.set_stringn(0, body_start, " No files", content_w, dim);
        }
    } else {
        let offset = file_scroll_offset(selected, body_height, entries.len());
        for (line, (name, is_dir)) in entries.iter().skip(offset).take(body_height).enumerate() {
            let y = body_start + line as u16;
            let row_index = offset + line;
            let style = if row_index == selected { selected_style } else { base };
            if row_index == selected {
                for x in 0..content_width {
                    buf[(x, y)].set_style(style);
                }
            }
            let prefix = if *is_dir { "▸ " } else { "  " };
            buf.set_stringn(0, y, prefix, content_w, style.add_modifier(Modifier::DIM));
            let name_width = content_w.saturating_sub(2);
            buf.set_stringn(2, y, truncate(name, name_width), name_width, style);
            hits.push((
                Rect { x: 0, y, width: content_width, height: 1 },
                Hit::SidebarFile { index: row_index },
            ));
        }
    }

    if height > 1 {
        let footer = if filter_mode {
            format!("/{query}█")
        } else if let Some(message) = message {
            message
        } else {
            format!(
                "{}/{}  .:{}  / filter",
                entries.len(),
                total,
                if show_hidden { "on" } else { "off" }
            )
        };
        buf.set_stringn(0, height - 1, truncate(&footer, content_w), content_w, dim);
    }
    hits.push((Rect { x: width - 1, y: 0, width: 1, height }, Hit::SidebarResize));
    app.hits.extend(hits);
}

fn unread_summary(app: &App) -> Option<(usize, Color)> {
    let mut count = 0;
    let mut highest = None;
    for notification in app
        .tree
        .workspaces
        .iter()
        .flat_map(|workspace| workspace.screens.iter())
        .flat_map(|screen| screen.panes.iter())
        .flat_map(|pane| pane.tabs.iter())
        .filter_map(|tab| tab.notification.filter(|notification| notification.unread))
    {
        count += 1;
        let ranked = match notification.level {
            "error" => (2u8, app.config.theme.notification_error),
            "warning" => (1, app.config.theme.notification_warning),
            _ => (0, app.config.theme.notification_info),
        };
        if highest.is_none_or(|current: (u8, Color)| ranked.0 > current.0) {
            highest = Some(ranked);
        }
    }
    highest.map(|(_, color)| (count, color))
}

fn file_scroll_offset(selected: usize, visible_height: usize, total: usize) -> usize {
    if visible_height == 0 || total <= visible_height || selected < visible_height {
        return 0;
    }
    (selected + 1).saturating_sub(visible_height).min(total - visible_height)
}
