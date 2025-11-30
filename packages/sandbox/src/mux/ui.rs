use chrono::{DateTime, Utc};
use ratatui::{
    layout::{Alignment, Constraint, Direction, Layout, Rect},
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, Clear, Paragraph, Tabs},
    Frame,
};

use crate::mux::commands::MuxCommand;
use crate::mux::layout::LayoutNode;
use crate::mux::palette::PaletteItem;
use crate::mux::sidebar::Sidebar;
use crate::mux::state::{FocusArea, MuxApp};

/// Main UI rendering function.
pub fn ui(f: &mut Frame, app: &mut MuxApp) {
    let area = f.area();

    // Main layout: sidebar | main area
    let main_chunks = if app.sidebar.visible {
        Layout::default()
            .direction(Direction::Horizontal)
            .constraints([Constraint::Length(app.sidebar.width), Constraint::Min(1)])
            .split(area)
    } else {
        Layout::default()
            .direction(Direction::Horizontal)
            .constraints([Constraint::Min(1)])
            .split(area)
    };

    // Render sidebar if visible
    let main_area = if app.sidebar.visible {
        render_sidebar(f, app, main_chunks[0]);
        main_chunks[1]
    } else {
        main_chunks[0]
    };

    // Main area layout: tabs | workspace | status
    let workspace_chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(1), // Tab bar
            Constraint::Min(1),    // Workspace
            Constraint::Length(1), // Status bar
        ])
        .split(main_area);

    render_tab_bar(f, app, workspace_chunks[0]);
    render_workspace(f, app, workspace_chunks[1]);
    render_status_bar(f, app, workspace_chunks[2]);

    // Render overlays
    if app.command_palette.is_visible() {
        render_command_palette(f, app);
    }

    if app.notifications.is_open {
        render_notifications_overlay(f, app);
    }

    if app.show_help {
        render_help_overlay(f, app);
    }

    if app.renaming_tab {
        render_rename_dialog(f, app);
    }
}

/// Render the sidebar with sandbox list.
fn render_sidebar(f: &mut Frame, app: &MuxApp, area: Rect) {
    let is_focused = app.focus == FocusArea::Sidebar;

    let border_style = if is_focused {
        Style::default().fg(Color::Cyan)
    } else {
        Style::default().fg(Color::DarkGray)
    };

    let block = Block::default()
        .title(" Sandboxes ")
        .title_style(if is_focused {
            Style::default()
                .fg(Color::Cyan)
                .add_modifier(Modifier::BOLD)
        } else {
            Style::default().fg(Color::White)
        })
        .borders(Borders::ALL)
        .border_style(border_style);

    let inner_area = block.inner(area);
    f.render_widget(block, area);

    if app.sidebar.is_loading {
        let loading = Paragraph::new("Loading...").style(Style::default().fg(Color::Yellow));
        f.render_widget(loading, inner_area);
        return;
    }

    if let Some(error) = &app.sidebar.last_error {
        let error_text =
            Paragraph::new(format!("Error: {}", error)).style(Style::default().fg(Color::Red));
        f.render_widget(error_text, inner_area);
        return;
    }

    if app.sidebar.sandboxes.is_empty() {
        let empty_text = Paragraph::new("No sandboxes").style(Style::default().fg(Color::DarkGray));
        f.render_widget(empty_text, inner_area);
        return;
    }

    let mut lines: Vec<Line<'_>> = Vec::new();
    for (idx, sandbox) in app.sidebar.sandboxes.iter().enumerate() {
        let is_selected = idx == app.sidebar.selected_index;

        let status_icon = Sidebar::status_icon(&sandbox.status);
        let status_color = Sidebar::status_color(&sandbox.status);

        let prefix = if is_selected { "▶ " } else { "  " };
        let max_name_width = inner_area.width.saturating_sub(6) as usize;
        let name = Sidebar::format_name(sandbox, max_name_width);

        let style = if is_selected {
            Style::default()
                .fg(Color::Cyan)
                .add_modifier(Modifier::BOLD)
        } else {
            Style::default()
        };

        lines.push(Line::from(vec![
            Span::styled(prefix, style),
            Span::styled(status_icon, Style::default().fg(status_color)),
            Span::raw(" "),
            Span::styled(name, style),
        ]));
    }

    let paragraph = Paragraph::new(lines);
    f.render_widget(paragraph, inner_area);
}

/// Render the tab bar.
fn render_tab_bar(f: &mut Frame, app: &MuxApp, area: Rect) {
    // Get workspace from workspace manager
    let Some(workspace) = app.workspace_manager.active_workspace() else {
        // No active sandbox, show placeholder
        let placeholder =
            Paragraph::new(" No sandbox selected ").style(Style::default().fg(Color::DarkGray));
        f.render_widget(placeholder, area);
        return;
    };

    if workspace.tabs.is_empty() {
        let placeholder = Paragraph::new(" No tabs ")
            .style(Style::default().fg(Color::DarkGray))
            .alignment(Alignment::Left);
        f.render_widget(placeholder, area);
        return;
    }

    let tab_titles: Vec<Line<'_>> = workspace
        .tabs
        .iter()
        .enumerate()
        .map(|(idx, tab)| {
            let style = if idx == workspace.active_tab_index {
                Style::default()
                    .fg(Color::Cyan)
                    .add_modifier(Modifier::BOLD)
            } else {
                Style::default().fg(Color::DarkGray)
            };
            Line::styled(format!(" {} ", tab.name), style)
        })
        .collect();

    let tabs = Tabs::new(tab_titles)
        .select(workspace.active_tab_index)
        .divider(Span::raw("│"))
        .highlight_style(
            Style::default()
                .fg(Color::Cyan)
                .add_modifier(Modifier::BOLD),
        );

    f.render_widget(tabs, area);
}

/// Render the main workspace area with panes.
fn render_workspace(f: &mut Frame, app: &mut MuxApp, area: Rect) {
    // First, calculate areas (needs mutable borrow)
    // Capture zoomed_pane first to avoid borrow issues
    let zoomed_pane = app.zoomed_pane;

    if let Some(tab) = app.active_tab_mut() {
        tab.layout.calculate_areas(area);
        if let Some(zoomed_id) = zoomed_pane {
            if let Some(pane) = tab.layout.find_pane_mut(zoomed_id) {
                pane.area = Some(area);
            }
        }
    }

    // Snapshot layout info without holding a long borrow
    let (layout_snapshot, active_pane_id) = if let Some(tab) = app.active_tab() {
        (Some(tab.layout.clone()), tab.active_pane)
    } else {
        (None, None)
    };

    let Some(layout) = layout_snapshot else {
        // No active tab, show placeholder
        let placeholder = Paragraph::new("Select a sandbox from the sidebar (Tab to switch)")
            .style(Style::default().fg(Color::DarkGray))
            .alignment(Alignment::Center);
        f.render_widget(placeholder, area);
        return;
    };

    let is_main_focused = app.focus == FocusArea::MainArea;

    // If zoomed, only render the zoomed pane
    if let Some(zoomed_id) = zoomed_pane {
        if let Some(pane) = layout.find_pane(zoomed_id) {
            render_pane(f, pane, area, true, is_main_focused, app);
            return;
        }
    }

    // Render all panes
    render_layout_node(f, &layout, active_pane_id, is_main_focused, app);
}

/// Recursively render layout nodes.
fn render_layout_node(
    f: &mut Frame,
    node: &LayoutNode,
    active_pane_id: Option<crate::mux::layout::PaneId>,
    is_main_focused: bool,
    app: &mut MuxApp,
) {
    match node {
        LayoutNode::Pane(pane) => {
            if let Some(area) = pane.area {
                let is_active = active_pane_id == Some(pane.id);
                render_pane(f, pane, area, is_active, is_main_focused, app);
            }
        }
        LayoutNode::Split { first, second, .. } => {
            render_layout_node(f, first, active_pane_id, is_main_focused, app);
            render_layout_node(f, second, active_pane_id, is_main_focused, app);
        }
    }
}

/// Render a single pane.
fn render_pane(
    f: &mut Frame,
    pane: &crate::mux::layout::Pane,
    area: Rect,
    is_active: bool,
    is_main_focused: bool,
    app: &mut MuxApp,
) {
    let border_style = if is_active && is_main_focused {
        Style::default().fg(Color::Cyan)
    } else if is_active {
        Style::default().fg(Color::White)
    } else {
        Style::default().fg(Color::DarkGray)
    };

    let title_style = if is_active && is_main_focused {
        Style::default()
            .fg(Color::Cyan)
            .add_modifier(Modifier::BOLD)
    } else {
        Style::default().fg(Color::White)
    };

    let block = Block::default()
        .title(format!(" {} ", pane.title()))
        .title_style(title_style)
        .borders(Borders::ALL)
        .border_style(border_style);

    let inner_area = block.inner(area);
    f.render_widget(block, area);

    // Render pane content
    match &pane.content {
        crate::mux::layout::PaneContent::Empty => {
            let text = Paragraph::new("Empty pane\n\nUse Alt+- or Alt+\\ to split")
                .style(Style::default().fg(Color::DarkGray))
                .alignment(Alignment::Center);
            f.render_widget(text, inner_area);
        }
        crate::mux::layout::PaneContent::Terminal { sandbox_id, .. } => {
            // Check if we have terminal output to display
            let height = inner_area.height as usize;
            let view = app.get_terminal_view(pane.id, height);
            let previous = app.last_terminal_views.get(&pane.id).cloned();
            let render_view = match (view, previous.clone()) {
                (Some(v), _) if v.has_content => Some(v),
                (Some(v), Some(prev)) => {
                    // Prefer previous non-empty view to avoid placeholder flicker
                    if prev.has_content {
                        Some(prev)
                    } else {
                        Some(v)
                    }
                }
                (None, Some(prev)) => Some(prev),
                _ => None,
            };

            if let Some(view) = render_view {
                if view.has_content {
                    // Render terminal output
                    let buf = f.buffer_mut();
                    let previous = app.last_terminal_views.get(&pane.id);
                    let visible_rows = height.min(view.lines.len());

                    let changed = view.changed_lines.as_ref();

                    for row in 0..visible_rows {
                        let row_changed = previous.is_none() || changed.binary_search(&row).is_ok();
                        if !row_changed {
                            continue;
                        }

                        let line = &view.lines[row];
                        let mut x = inner_area.x;
                        let max_width = inner_area.width;
                        let y = inner_area.y + row as u16;

                        for span in &line.spans {
                            let (next_x, _) = buf.set_span(
                                x,
                                y,
                                span,
                                max_width.saturating_sub(x.saturating_sub(inner_area.x)),
                            );
                            x = next_x;
                            if x >= inner_area.x + inner_area.width {
                                break;
                            }
                        }

                        // Clear remaining cells in this row to avoid old characters lingering
                        if x < inner_area.x + inner_area.width {
                            for col in x..inner_area.x + inner_area.width {
                                if let Some(cell) = buf.cell_mut((col, y)) {
                                    cell.set_symbol(" ");
                                    cell.set_style(Style::default());
                                }
                            }
                        }
                    }

                    // Clear leftover rows if the area shrank
                    if let Some(prev) = previous {
                        let prev_rows = prev.lines.len();
                        if prev_rows > visible_rows {
                            for row in visible_rows..prev_rows.min(inner_area.height as usize) {
                                let y = inner_area.y + row as u16;
                                for col in inner_area.x..inner_area.x + inner_area.width {
                                    if let Some(cell) = buf.cell_mut((col, y)) {
                                        cell.set_symbol(" ");
                                        cell.set_style(Style::default());
                                    }
                                }
                            }
                        }
                    }

                    app.last_terminal_views.insert(pane.id, view.clone());

                    // Set cursor position only if:
                    // 1. Pane is active
                    // 2. Main area is focused (not sidebar or command palette)
                    if is_active && is_main_focused {
                        if let Some((cursor_row, cursor_col)) = view.cursor {
                            // Ensure cursor is within visible area
                            let cursor_x = inner_area.x + cursor_col;
                            let cursor_y = inner_area.y + cursor_row;
                            if cursor_x < inner_area.x + inner_area.width
                                && cursor_y < inner_area.y + inner_area.height
                            {
                                f.set_cursor_position((cursor_x, cursor_y));
                            }
                        }
                    }
                    return;
                }
            }

            // Show placeholder when no terminal output yet
            let sandbox_info = sandbox_id
                .as_ref()
                .map(|s| format!("Connected to: {}", s))
                .unwrap_or_else(|| "Not connected".to_string());

            let help_text = if sandbox_id.is_some() {
                "Waiting for output..."
            } else {
                "Select a sandbox from sidebar (Tab) or create one (Alt+N)"
            };

            let text = Paragraph::new(format!("Terminal\n\n{}\n\n{}", sandbox_info, help_text))
                .style(Style::default().fg(Color::DarkGray))
                .alignment(Alignment::Center);
            f.render_widget(text, inner_area);
        }
        crate::mux::layout::PaneContent::Chat {
            sandbox_id,
            provider,
        } => {
            let text = Paragraph::new(format!(
                "Chat with {}\n\nSandbox: {}\n\n(Chat integration coming soon)",
                provider, sandbox_id
            ))
            .style(Style::default().fg(Color::DarkGray))
            .alignment(Alignment::Center);
            f.render_widget(text, inner_area);
        }
    }
}

/// Render the status bar.
fn render_status_bar(f: &mut Frame, app: &mut MuxApp, area: Rect) {
    app.clear_expired_status();

    let mut spans = Vec::new();

    // Mode indicator
    let mode = match app.focus {
        FocusArea::Sidebar => "SIDEBAR",
        FocusArea::MainArea => "NORMAL",
        FocusArea::CommandPalette => "COMMAND",
        FocusArea::Notifications => "NOTIFS",
    };
    spans.push(Span::styled(
        format!(" {} ", mode),
        Style::default()
            .fg(Color::Black)
            .bg(Color::Cyan)
            .add_modifier(Modifier::BOLD),
    ));
    spans.push(Span::raw(" "));

    // Debug build indicator (only in debug builds)
    #[cfg(debug_assertions)]
    {
        spans.push(Span::styled(
            "[debug build]",
            Style::default()
                .fg(Color::Black)
                .bg(Color::Yellow)
                .add_modifier(Modifier::BOLD),
        ));
        spans.push(Span::raw(" "));
    }

    // Active sandbox info
    if let Some(workspace) = app.workspace_manager.active_workspace() {
        spans.push(Span::styled(
            format!("[{}] ", workspace.name),
            Style::default().fg(Color::Green),
        ));
    }

    // Pane info
    if let Some(tab) = app.active_tab() {
        let pane_count = tab.layout.pane_count();
        spans.push(Span::styled(
            format!(
                "{} pane{}",
                pane_count,
                if pane_count == 1 { "" } else { "s" }
            ),
            Style::default().fg(Color::DarkGray),
        ));
        spans.push(Span::raw(" │ "));
    }

    // Tab info
    if let Some(workspace) = app.workspace_manager.active_workspace() {
        spans.push(Span::styled(
            format!(
                "Tab {}/{}",
                workspace.active_tab_index + 1,
                workspace.tabs.len()
            ),
            Style::default().fg(Color::DarkGray),
        ));
    } else {
        spans.push(Span::styled(
            "No sandbox",
            Style::default().fg(Color::DarkGray),
        ));
    }

    // Status message
    if let Some((msg, _)) = &app.status_message {
        spans.push(Span::raw(" │ "));
        spans.push(Span::styled(
            msg.clone(),
            Style::default().fg(Color::Yellow),
        ));
    }

    // Unread notifications
    let unread = app.notifications.unread_count();
    spans.push(Span::raw(" │ "));
    spans.push(Span::styled(
        format!("Notifs: {}", unread),
        if unread > 0 {
            Style::default()
                .fg(Color::Yellow)
                .add_modifier(Modifier::BOLD)
        } else {
            Style::default().fg(Color::DarkGray)
        },
    ));

    // Right side: keybinding hints
    let hints = " Alt+P: Commands │ Alt+Shift+N: Notifications │ Ctrl+S: Sidebar │ Ctrl+Q: Quit ";
    let hints_width = hints.len() as u16;
    let left_width: u16 = spans.iter().map(|s| s.content.len() as u16).sum();
    let padding = area.width.saturating_sub(left_width + hints_width);

    spans.push(Span::raw(" ".repeat(padding as usize)));
    spans.push(Span::styled(hints, Style::default().fg(Color::DarkGray)));

    let line = Line::from(spans);
    let paragraph = Paragraph::new(line);
    f.render_widget(paragraph, area);
}

/// Render the command palette overlay.
fn render_command_palette(f: &mut Frame, app: &mut MuxApp) {
    let area = f.area();

    let palette_width = 70u16.min(area.width.saturating_sub(4));
    let max_height = 20u16.min(area.height.saturating_sub(4));
    let palette_height = (app.command_palette.filtered_count() as u16 + 6).min(max_height);

    let x = (area.width.saturating_sub(palette_width)) / 2;
    let y = area.height / 6; // Place towards the top

    let palette_area = Rect::new(x, y, palette_width, palette_height);
    f.render_widget(Clear, palette_area);

    let block = Block::default()
        .title(" Command Palette ")
        .title_style(
            Style::default()
                .fg(Color::Cyan)
                .add_modifier(Modifier::BOLD),
        )
        .borders(Borders::ALL)
        .border_style(Style::default().fg(Color::Cyan));

    let inner_area = block.inner(palette_area);
    f.render_widget(block, palette_area);

    // Search input
    let search_area = Rect::new(inner_area.x, inner_area.y, inner_area.width, 1);
    let search_prefix = Paragraph::new(Span::styled(">", Style::default().fg(Color::Cyan)));
    f.render_widget(search_prefix, Rect::new(search_area.x, search_area.y, 2, 1));
    f.render_widget(
        app.command_palette.search_input(),
        Rect::new(search_area.x + 2, search_area.y, search_area.width - 2, 1),
    );

    // Commands list
    let items_area = Rect::new(
        inner_area.x,
        inner_area.y + 2,
        inner_area.width,
        inner_area.height.saturating_sub(4),
    );

    let mut lines: Vec<Line<'_>> = Vec::new();

    let (items, selected_line_index) = app.command_palette.get_items();

    for item in items {
        match item {
            PaletteItem::Header(text) => {
                if text.is_empty() {
                    lines.push(Line::raw("")); // Spacing between categories
                } else {
                    lines.push(Line::styled(
                        format!("─ {} ─", text),
                        Style::default()
                            .fg(Color::DarkGray)
                            .add_modifier(Modifier::BOLD),
                    ));
                }
            }
            PaletteItem::Command {
                command,
                is_highlighted,
                label_highlights,
            } => {
                let prefix = if is_highlighted { "▶ " } else { "  " };
                let keybinding = command.keybinding_str();

                let style = if is_highlighted {
                    Style::default()
                        .fg(Color::Cyan)
                        .add_modifier(Modifier::BOLD)
                } else {
                    Style::default()
                };

                let kb_style = Style::default().fg(Color::Yellow);

                // Calculate padding for right-aligned keybinding
                let label = command.label();
                let kb_width = keybinding.len();
                let label_width = items_area
                    .width
                    .saturating_sub(4)
                    .saturating_sub(kb_width as u16) as usize;

                let mut spans = vec![Span::styled(prefix, style)];
                let mut label_spans =
                    highlighted_spans(label, &label_highlights, style, is_highlighted);

                let label_len = label.chars().count();
                let padding = label_width.saturating_sub(label_len);
                if padding > 0 {
                    label_spans.push(Span::styled(" ".repeat(padding), style));
                }

                spans.append(&mut label_spans);

                if !keybinding.is_empty() {
                    spans.push(Span::styled(keybinding, kb_style));
                }

                lines.push(Line::from(spans));
            }
        }
    }

    // Adjust scroll to keep selected item visible
    let visible_lines = items_area.height as usize;
    if let Some(selected_line) = selected_line_index {
        app.command_palette
            .adjust_scroll(selected_line, visible_lines);
    }

    let scroll_offset = app.command_palette.scroll_offset();
    let paragraph = Paragraph::new(lines).scroll((scroll_offset as u16, 0));
    f.render_widget(paragraph, items_area);

    // Help text at bottom
    let help_area = Rect::new(
        inner_area.x,
        inner_area.y + inner_area.height - 1,
        inner_area.width,
        1,
    );
    let help = Paragraph::new(Line::styled(
        "↑↓: navigate │ Enter: execute │ Esc: cancel",
        Style::default().fg(Color::DarkGray),
    ));
    f.render_widget(help, help_area);
}

fn render_notifications_overlay(f: &mut Frame, app: &mut MuxApp) {
    let area = f.area();
    let overlay_width = 80u16.min(area.width.saturating_sub(4));
    let overlay_height = 24u16.min(area.height.saturating_sub(4));
    let x = (area.width.saturating_sub(overlay_width)) / 2;
    let y = (area.height.saturating_sub(overlay_height)) / 5;

    let overlay_area = Rect::new(x, y, overlay_width, overlay_height);
    f.render_widget(Clear, overlay_area);

    let title = format!(
        " Notifications (unread: {}) ",
        app.notifications.unread_count()
    );
    let block = Block::default()
        .title(title)
        .title_style(
            Style::default()
                .fg(Color::Cyan)
                .add_modifier(Modifier::BOLD),
        )
        .borders(Borders::ALL)
        .border_style(Style::default().fg(Color::Cyan));

    let inner_area = block.inner(overlay_area);
    f.render_widget(block, overlay_area);

    if app.notifications.items.is_empty() {
        let empty = Paragraph::new("No notifications yet")
            .alignment(Alignment::Center)
            .style(Style::default().fg(Color::DarkGray));
        f.render_widget(empty, inner_area);
        return;
    }

    let list_height = inner_area.height.saturating_sub(2);
    let list_area = Rect::new(inner_area.x, inner_area.y, inner_area.width, list_height);

    let order = app.notifications.combined_order();
    let mut unread_indices: Vec<usize> = Vec::new();
    let mut read_indices: Vec<usize> = Vec::new();
    for idx in order {
        if app
            .notifications
            .items
            .get(idx)
            .map(|n| n.read_at.is_none())
            .unwrap_or(false)
        {
            unread_indices.push(idx);
        } else {
            read_indices.push(idx);
        }
    }

    let total_items = unread_indices.len() + read_indices.len();
    let desired_selection = if total_items == 0 {
        None
    } else {
        Some(
            app.notifications
                .selected_index
                .min(total_items.saturating_sub(1)),
        )
    };

    let mut lines: Vec<Line<'_>> = Vec::new();
    let mut selected_line: Option<usize> = None;
    let mut selection_counter = 0usize;

    for (header, group) in [("Unread", unread_indices), ("Read", read_indices)] {
        if group.is_empty() {
            continue;
        }
        lines.push(Line::styled(
            format!(" {header} "),
            Style::default()
                .fg(Color::Magenta)
                .add_modifier(Modifier::BOLD),
        ));

        for idx in group {
            let Some(item) = app.notifications.items.get(idx) else {
                continue;
            };
            let is_selected = desired_selection.is_some_and(|target| selection_counter == target);
            if is_selected {
                selected_line = Some(lines.len());
            }
            selection_counter += 1;

            let level_style = match item.level {
                crate::models::NotificationLevel::Info => Style::default().fg(Color::White),
                crate::models::NotificationLevel::Warning => Style::default().fg(Color::Yellow),
                crate::models::NotificationLevel::Error => Style::default().fg(Color::Red),
            };

            let mut spans = Vec::new();
            let state_prefix = if item.read_at.is_none() { "[ ]" } else { "[r]" };
            spans.push(Span::styled(state_prefix, level_style));
            spans.push(Span::raw(" "));
            let time_label = relative_time_string(item.sent_at);
            spans.push(Span::styled(
                time_label,
                Style::default().fg(Color::DarkGray),
            ));
            spans.push(Span::raw(" "));
            spans.push(Span::styled(item.message.clone(), level_style));
            if let Some(sandbox_id) = &item.sandbox_id {
                if let Some(label) = sandbox_short_label(app, sandbox_id) {
                    spans.push(Span::raw("  "));
                    spans.push(Span::styled(
                        format!("sandbox {}", label),
                        Style::default().fg(Color::DarkGray),
                    ));
                }
            }
            if let Some(tab_id) = &item.tab_id {
                spans.push(Span::raw("  "));
                spans.push(Span::styled(
                    format!("tab: {}", tab_id),
                    Style::default().fg(Color::DarkGray),
                ));
            }
            if let Some(read_at) = item.read_at {
                spans.push(Span::raw("  "));
                spans.push(Span::styled(
                    format!("read {}", relative_time_string(read_at)),
                    Style::default().fg(Color::DarkGray),
                ));
            }

            let mut line = Line::from(spans);
            if is_selected {
                line = line.style(
                    Style::default()
                        .bg(Color::DarkGray)
                        .add_modifier(Modifier::BOLD),
                );
            }
            lines.push(line);
        }
    }

    let visible_lines = list_height as usize;
    let target_line = selected_line.unwrap_or(0);
    let scroll_offset = if visible_lines == 0 {
        0
    } else {
        target_line.saturating_sub(visible_lines.saturating_sub(1))
    };

    let paragraph = Paragraph::new(lines).scroll((scroll_offset as u16, 0));
    f.render_widget(paragraph, list_area);

    let help_area = Rect::new(
        inner_area.x,
        inner_area.y + inner_area.height.saturating_sub(1),
        inner_area.width,
        1,
    );
    let help = Paragraph::new(Line::styled(
        "↑↓: navigate │ Enter: open target │ Space/r: mark read │ u: mark unread │ Esc: close",
        Style::default().fg(Color::DarkGray),
    ));
    f.render_widget(help, help_area);
}

fn highlighted_spans<'a>(
    text: &'a str,
    highlights: &[usize],
    base_style: Style,
    is_selected: bool,
) -> Vec<Span<'a>> {
    if highlights.is_empty() {
        return vec![Span::styled(text.to_string(), base_style)];
    }

    let mut sorted_indices = highlights.to_vec();
    sorted_indices.sort_unstable();
    sorted_indices.dedup();

    let mut spans: Vec<Span<'a>> = Vec::new();
    let mut last_idx = 0usize;

    for idx in sorted_indices {
        if idx > text.len() {
            continue;
        }

        if idx > last_idx {
            spans.push(Span::styled(text[last_idx..idx].to_string(), base_style));
        }

        if let Some(ch) = text[idx..].chars().next() {
            let mut highlight_style = base_style.add_modifier(Modifier::BOLD);
            if is_selected {
                highlight_style = highlight_style.add_modifier(Modifier::UNDERLINED);
            }
            spans.push(Span::styled(ch.to_string(), highlight_style));
            last_idx = idx + ch.len_utf8();
        } else {
            last_idx = idx;
        }
    }

    if last_idx < text.len() {
        spans.push(Span::styled(text[last_idx..].to_string(), base_style));
    }

    spans
}

fn relative_time_string(timestamp: DateTime<Utc>) -> String {
    let now = Utc::now();
    let delta = now.signed_duration_since(timestamp);
    if delta.num_seconds() < 0 {
        return "just now".to_string();
    }
    let seconds = delta.num_seconds();
    if seconds < 90 {
        return format!("{}s ago", seconds);
    }
    let minutes = delta.num_minutes();
    if minutes < 90 {
        return format!("{}m ago", minutes);
    }
    let hours = delta.num_hours();
    if hours < 48 {
        return format!("{}h ago", hours);
    }
    timestamp.format("%Y-%m-%d").to_string()
}

fn sandbox_short_label(app: &MuxApp, sandbox_id: &str) -> Option<String> {
    app.sidebar
        .sandboxes
        .iter()
        .find(|s| s.id.to_string() == sandbox_id)
        .map(|s| format!("#{}", s.index))
}

/// Render help overlay showing all keybindings.
fn render_help_overlay(f: &mut Frame, _app: &MuxApp) {
    let area = f.area();

    let help_width = 60u16.min(area.width.saturating_sub(4));
    let help_height = 30u16.min(area.height.saturating_sub(4));

    let x = (area.width.saturating_sub(help_width)) / 2;
    let y = (area.height.saturating_sub(help_height)) / 2;

    let help_area = Rect::new(x, y, help_width, help_height);
    f.render_widget(Clear, help_area);

    let block = Block::default()
        .title(" Keyboard Shortcuts ")
        .title_style(
            Style::default()
                .fg(Color::Cyan)
                .add_modifier(Modifier::BOLD),
        )
        .borders(Borders::ALL)
        .border_style(Style::default().fg(Color::Cyan));

    let inner_area = block.inner(help_area);
    f.render_widget(block, help_area);

    let mut lines: Vec<Line<'_>> = Vec::new();
    let mut current_category: Option<&str> = None;

    for cmd in MuxCommand::all() {
        let category = cmd.category();
        if current_category != Some(category) {
            if current_category.is_some() {
                lines.push(Line::raw(""));
            }
            lines.push(Line::styled(
                category,
                Style::default()
                    .fg(Color::Yellow)
                    .add_modifier(Modifier::BOLD),
            ));
            current_category = Some(category);
        }

        let keybinding = cmd.keybinding_str();
        if !keybinding.is_empty() {
            let kb_width = 16;
            lines.push(Line::from(vec![
                Span::raw("  "),
                Span::styled(
                    format!("{:<width$}", keybinding, width = kb_width),
                    Style::default().fg(Color::Cyan),
                ),
                Span::raw(cmd.label()),
            ]));
        }
    }

    let paragraph = Paragraph::new(lines);
    f.render_widget(paragraph, inner_area);
}

/// Render tab rename dialog.
fn render_rename_dialog(f: &mut Frame, app: &MuxApp) {
    let area = f.area();

    let dialog_width = 40u16.min(area.width.saturating_sub(4));
    let dialog_height = 5u16;

    let x = (area.width.saturating_sub(dialog_width)) / 2;
    let y = (area.height.saturating_sub(dialog_height)) / 2;

    let dialog_area = Rect::new(x, y, dialog_width, dialog_height);
    f.render_widget(Clear, dialog_area);

    let block = Block::default()
        .title(" Rename Tab ")
        .title_style(
            Style::default()
                .fg(Color::Cyan)
                .add_modifier(Modifier::BOLD),
        )
        .borders(Borders::ALL)
        .border_style(Style::default().fg(Color::Cyan));

    let inner_area = block.inner(dialog_area);
    f.render_widget(block, dialog_area);

    if let Some(input) = &app.rename_input {
        let input_area = Rect::new(inner_area.x, inner_area.y + 1, inner_area.width, 1);
        f.render_widget(input, input_area);
    }

    let help_area = Rect::new(
        inner_area.x,
        inner_area.y + inner_area.height - 1,
        inner_area.width,
        1,
    );
    let help = Paragraph::new(Line::styled(
        "Enter: confirm │ Esc: cancel",
        Style::default().fg(Color::DarkGray),
    ));
    f.render_widget(help, help_area);
}
