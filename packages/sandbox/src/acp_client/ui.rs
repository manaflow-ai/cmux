use ratatui::{
    layout::{Constraint, Direction, Layout},
    text::{Line, Span},
    widgets::{Block, Borders, Paragraph},
};
use std::sync::LazyLock;
use tui_textarea::TextArea;

use crate::acp_client::markdown::markdown_to_lines;
use crate::acp_client::state::{
    App, ChatEntry, ConnectionState, PaletteCommand, SwitchPaletteItem, UiMode, WorkspaceSyncState,
};

/// Detect if terminal is in dark mode (cached at startup)
static IS_DARK_MODE: LazyLock<bool> = LazyLock::new(|| {
    match terminal_light::luma() {
        Ok(luma) if luma > 0.5 => false, // Light background
        Ok(_) => true,                   // Dark background
        Err(_) => true,                  // Default to dark mode if detection fails
    }
});

/// Get background color for user messages based on terminal mode
fn user_message_bg_color() -> ratatui::style::Color {
    if *IS_DARK_MODE {
        ratatui::style::Color::Rgb(60, 60, 60) // Lighter gray for dark mode
    } else {
        ratatui::style::Color::Rgb(230, 230, 230) // Darker gray for light mode
    }
}

pub(crate) fn ui(f: &mut ratatui::Frame, app: &mut App) {
    let line_count = app.textarea.lines().len() as u16;
    let input_height = (line_count + 2).clamp(3, 12);
    let status_height = 1u16;
    let debug_height = if app.debug_mode { 8u16 } else { 0u16 };

    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints(
            [
                Constraint::Min(1),
                Constraint::Length(debug_height),
                Constraint::Length(input_height),
                Constraint::Length(status_height),
            ]
            .as_ref(),
        )
        .split(f.area());

    let history_area = chunks[0];
    let debug_area = chunks[1];
    let input_area = chunks[2];
    let status_area = chunks[3];

    let area_width = history_area.width as usize;
    let mut lines: Vec<Line<'_>> = Vec::new();

    for (i, entry) in app.history.iter().enumerate() {
        if i > 0 {
            lines.push(Line::from(""));
        }
        match entry {
            ChatEntry::Message {
                role,
                text,
                normalized_markdown,
            } => {
                render_message(
                    &mut lines,
                    role,
                    text,
                    normalized_markdown.as_deref(),
                    area_width,
                );
            }
            ChatEntry::ToolCall {
                title,
                kind,
                status,
                ..
            } => {
                render_tool_call(&mut lines, title, kind, status);
            }
            ChatEntry::Plan(plan) => {
                render_plan(&mut lines, plan);
            }
        }
    }

    let total_lines = lines.len() as u16;
    let view_height = history_area.height;
    let max_scroll = total_lines.saturating_sub(view_height);

    let offset_from_bottom = app.scroll_offset_from_bottom.min(max_scroll);
    app.scroll_offset_from_bottom = offset_from_bottom;

    let scroll_offset = max_scroll.saturating_sub(offset_from_bottom);
    let history_paragraph = Paragraph::new(lines).scroll((scroll_offset, 0));

    f.render_widget(history_paragraph, history_area);

    if app.debug_mode && debug_height > 0 {
        let debug_lines: Vec<Line<'_>> = app
            .debug_messages
            .iter()
            .rev()
            .take(debug_height as usize - 2)
            .rev()
            .map(|s| {
                Line::styled(
                    s.clone(),
                    ratatui::style::Style::default().fg(ratatui::style::Color::DarkGray),
                )
            })
            .collect();

        let debug_block = Block::default()
            .title(" Debug (ACP Messages) ")
            .title_style(
                ratatui::style::Style::default()
                    .fg(ratatui::style::Color::Yellow)
                    .add_modifier(ratatui::style::Modifier::BOLD),
            )
            .borders(Borders::ALL)
            .border_style(ratatui::style::Style::default().fg(ratatui::style::Color::DarkGray));

        let debug_paragraph = Paragraph::new(debug_lines).block(debug_block);
        f.render_widget(debug_paragraph, debug_area);
    }

    f.render_widget(&app.textarea, input_area);

    let provider_style = ratatui::style::Style::default()
        .fg(ratatui::style::Color::Cyan)
        .add_modifier(ratatui::style::Modifier::BOLD);
    let hint_style = ratatui::style::Style::default().fg(ratatui::style::Color::DarkGray);
    let connecting_style = ratatui::style::Style::default()
        .fg(ratatui::style::Color::Yellow)
        .add_modifier(ratatui::style::Modifier::BOLD);
    let error_style = ratatui::style::Style::default()
        .fg(ratatui::style::Color::Red)
        .add_modifier(ratatui::style::Modifier::BOLD);
    let debug_indicator_style = ratatui::style::Style::default().fg(ratatui::style::Color::Yellow);

    let mut status_spans = vec![Span::styled(
        app.current_provider.display_name(),
        provider_style,
    )];

    if let Some(model_name) = app.current_model_name() {
        let model_style = ratatui::style::Style::default().fg(ratatui::style::Color::Magenta);
        status_spans.push(Span::styled(" / ", hint_style));
        status_spans.push(Span::styled(model_name.to_string(), model_style));
    }

    match &app.connection_state {
        ConnectionState::Connecting => {
            status_spans.push(Span::styled(" (connecting...)", connecting_style));
        }
        ConnectionState::Connected => {
            if app.model_switching {
                status_spans.push(Span::styled(" (switching model...)", connecting_style));
            }
        }
        ConnectionState::SwitchingProvider(_) => {
            status_spans.push(Span::styled(" (loading...)", connecting_style));
        }
    }

    match &app.workspace_sync_state {
        WorkspaceSyncState::Syncing => {
            status_spans.push(Span::styled(" │ syncing workspace...", connecting_style));
        }
        WorkspaceSyncState::Failed(_) => {
            status_spans.push(Span::styled(" │ workspace sync failed", error_style));
        }
        WorkspaceSyncState::Idle | WorkspaceSyncState::Completed => {}
    }

    if app.debug_mode {
        status_spans.push(Span::styled(" [DEBUG]", debug_indicator_style));
    }

    status_spans.push(Span::styled(" │ ^O: commands │ ^M: switch", hint_style));

    let status_line = Line::from(status_spans);
    let status_paragraph = Paragraph::new(status_line);
    f.render_widget(status_paragraph, status_area);

    match app.ui_mode {
        UiMode::MainPalette => {
            let search = app.palette_search();
            render_searchable_palette(
                f,
                " Commands ",
                &app.palette_input,
                app.palette_selection,
                PaletteCommand::all()
                    .iter()
                    .filter(|c| c.matches(&search))
                    .map(|c| PaletteItem::Simple {
                        label: c.get_label().to_string(),
                        description: Some(c.get_description().to_string()),
                        is_current: false,
                    })
                    .collect(),
            );
        }
        UiMode::SwitchPalette => {
            let items = app.get_switch_palette_items();
            let palette_items: Vec<_> = items
                .iter()
                .map(|item| match item {
                    SwitchPaletteItem::Header(text) => PaletteItem::Header(text.clone()),
                    SwitchPaletteItem::Provider(p) => PaletteItem::Simple {
                        label: format!("Switch to {}", p.display_name()),
                        description: None,
                        is_current: *p == app.current_provider,
                    },
                    SwitchPaletteItem::Model { provider, id, name } => {
                        let is_current = *provider == app.current_provider
                            && app
                                .model_state
                                .as_ref()
                                .is_some_and(|s| &*s.current_model_id.0 == id);
                        PaletteItem::Simple {
                            label: format!("  {}", name),
                            description: None,
                            is_current,
                        }
                    }
                    SwitchPaletteItem::Loading(_) => PaletteItem::Loading,
                })
                .collect();
            render_searchable_palette(
                f,
                " Switch Provider / Model ",
                &app.palette_input,
                app.palette_selection,
                palette_items,
            );
        }
        UiMode::Chat => {}
    }
}

/// Item types for palette rendering
enum PaletteItem {
    Header(String),
    Simple {
        label: String,
        description: Option<String>,
        is_current: bool,
    },
    Loading,
}

/// Render a searchable palette overlay with scrolling support
fn render_searchable_palette(
    f: &mut ratatui::Frame,
    title: &str,
    search_input: &TextArea<'_>,
    selection: usize,
    items: Vec<PaletteItem>,
) {
    use ratatui::widgets::Clear;

    let area = f.area();

    let palette_width = 70u16.min(area.width.saturating_sub(4));
    let max_items_height = 15u16;
    let palette_height = (items.len() as u16 + 7)
        .min(max_items_height + 7)
        .min(area.height.saturating_sub(4));

    let x = (area.width.saturating_sub(palette_width)) / 2;
    let y = (area.height.saturating_sub(palette_height)) / 2;

    let palette_area = ratatui::layout::Rect::new(x, y, palette_width, palette_height);
    f.render_widget(Clear, palette_area);

    let inner_area = ratatui::layout::Rect::new(
        palette_area.x + 1,
        palette_area.y + 1,
        palette_area.width.saturating_sub(2),
        palette_area.height.saturating_sub(2),
    );

    let search_area = ratatui::layout::Rect::new(inner_area.x, inner_area.y, inner_area.width, 1);

    let items_start_y = inner_area.y + 2;
    let items_height = inner_area.height.saturating_sub(4);

    let palette_block = Block::default()
        .title(title)
        .title_style(
            ratatui::style::Style::default()
                .fg(ratatui::style::Color::Cyan)
                .add_modifier(ratatui::style::Modifier::BOLD),
        )
        .borders(Borders::ALL)
        .border_style(ratatui::style::Style::default().fg(ratatui::style::Color::Cyan));
    f.render_widget(palette_block, palette_area);

    let search_prefix = Paragraph::new(Line::from(Span::styled(
        ">",
        ratatui::style::Style::default().fg(ratatui::style::Color::Cyan),
    )));
    let prefix_area = ratatui::layout::Rect::new(search_area.x, search_area.y, 2, 1);
    f.render_widget(search_prefix, prefix_area);

    let input_area =
        ratatui::layout::Rect::new(search_area.x + 2, search_area.y, search_area.width - 2, 1);
    f.render_widget(search_input, input_area);

    let mut palette_lines: Vec<Line<'_>> = Vec::new();
    let mut selectable_index = 0usize;
    let mut selected_line_index: Option<usize> = None;

    for item in items.iter() {
        match item {
            PaletteItem::Header(text) => {
                palette_lines.push(Line::styled(
                    format!("─ {} ─", text),
                    ratatui::style::Style::default()
                        .fg(ratatui::style::Color::DarkGray)
                        .add_modifier(ratatui::style::Modifier::BOLD),
                ));
            }
            PaletteItem::Loading => {
                palette_lines.push(Line::styled(
                    "    Loading...",
                    ratatui::style::Style::default()
                        .fg(ratatui::style::Color::Yellow)
                        .add_modifier(ratatui::style::Modifier::ITALIC),
                ));
            }
            PaletteItem::Simple {
                label,
                description,
                is_current,
            } => {
                let is_selected = selectable_index == selection;
                if is_selected {
                    selected_line_index = Some(palette_lines.len());
                }

                let prefix = if is_selected { "▶ " } else { "  " };
                let suffix = if *is_current { " ●" } else { "" };

                let style = if is_selected {
                    ratatui::style::Style::default()
                        .fg(ratatui::style::Color::Cyan)
                        .add_modifier(ratatui::style::Modifier::BOLD)
                } else if *is_current {
                    ratatui::style::Style::default().fg(ratatui::style::Color::Green)
                } else {
                    ratatui::style::Style::default()
                };

                let mut spans = vec![Span::styled(
                    format!("{}{}{}", prefix, label, suffix),
                    style,
                )];

                if let Some(desc) = description {
                    spans.push(Span::styled(
                        format!("  {}", desc),
                        ratatui::style::Style::default().fg(ratatui::style::Color::DarkGray),
                    ));
                }

                palette_lines.push(Line::from(spans));
                selectable_index += 1;
            }
        }
    }

    if items.is_empty() {
        palette_lines.push(Line::styled(
            "  No matches",
            ratatui::style::Style::default().fg(ratatui::style::Color::DarkGray),
        ));
    }

    let total_lines = palette_lines.len() as u16;
    let view_height = items_height;
    let scroll_offset = if let Some(selected_idx) = selected_line_index {
        let selected_idx = selected_idx as u16;
        if selected_idx >= view_height {
            (selected_idx + 1).saturating_sub(view_height)
        } else {
            0
        }
    } else {
        0
    };

    let needs_scroll_down = scroll_offset + view_height < total_lines;

    let items_area =
        ratatui::layout::Rect::new(inner_area.x, items_start_y, inner_area.width, items_height);
    let items_paragraph = Paragraph::new(palette_lines).scroll((scroll_offset, 0));
    f.render_widget(items_paragraph, items_area);

    if scroll_offset > 0 {
        let up_indicator = Paragraph::new("▲")
            .style(ratatui::style::Style::default().fg(ratatui::style::Color::DarkGray));
        let up_area =
            ratatui::layout::Rect::new(items_area.x + items_area.width - 1, items_area.y, 1, 1);
        f.render_widget(up_indicator, up_area);
    }
    if needs_scroll_down {
        let down_indicator = Paragraph::new("▼")
            .style(ratatui::style::Style::default().fg(ratatui::style::Color::DarkGray));
        let down_area = ratatui::layout::Rect::new(
            items_area.x + items_area.width - 1,
            items_area.y + items_area.height - 1,
            1,
            1,
        );
        f.render_widget(down_indicator, down_area);
    }

    let help_y = palette_area.y + palette_area.height - 2;
    let help_area = ratatui::layout::Rect::new(inner_area.x, help_y, inner_area.width, 1);
    let help_text = Paragraph::new(Line::styled(
        "↑↓: navigate │ Enter: select │ Esc: cancel",
        ratatui::style::Style::default().fg(ratatui::style::Color::DarkGray),
    ));
    f.render_widget(help_text, help_area);
}

fn render_message<'a>(
    lines: &mut Vec<Line<'a>>,
    role: &str,
    text: &'a str,
    normalized_markdown: Option<&'a str>,
    area_width: usize,
) {
    match role {
        "User" => {
            let bg_style = ratatui::style::Style::default().bg(user_message_bg_color());
            lines.push(Line::styled(" ".repeat(area_width), bg_style));
            for line in text.lines() {
                let padded = format!("{:width$}", line, width = area_width);
                lines.push(Line::styled(padded, bg_style));
            }
            lines.push(Line::styled(" ".repeat(area_width), bg_style));
        }
        "Agent" | "Thought" => {
            if role == "Thought" && text.trim().is_empty() {
                return;
            }
            lines.push(Line::raw(""));
            let prefix_style =
                ratatui::style::Style::default().add_modifier(ratatui::style::Modifier::BOLD);
            let prefix = if role == "Agent" {
                None
            } else {
                Some(("Thought: ".to_string(), prefix_style))
            };
            render_markdown_message(lines, text, normalized_markdown, prefix);
            lines.push(Line::raw(""));
        }
        "Error" => {
            lines.push(Line::raw(""));
            let prefix_style = ratatui::style::Style::default()
                .fg(ratatui::style::Color::Red)
                .add_modifier(ratatui::style::Modifier::BOLD);
            let text_style = ratatui::style::Style::default().fg(ratatui::style::Color::Red);
            let prefix = "Error: ";
            let mut first = true;
            for text_line in text.lines() {
                if first {
                    lines.push(Line::from(vec![
                        Span::styled(prefix.to_string(), prefix_style),
                        Span::styled(text_line.to_owned(), text_style),
                    ]));
                    first = false;
                } else {
                    lines.push(Line::styled(text_line.to_owned(), text_style));
                }
            }
            if first {
                lines.push(Line::from(vec![Span::styled(
                    prefix.to_string(),
                    prefix_style,
                )]));
            }
            lines.push(Line::raw(""));
        }
        "System" => {
            lines.push(Line::raw(""));
            let prefix_style = ratatui::style::Style::default()
                .fg(ratatui::style::Color::Yellow)
                .add_modifier(ratatui::style::Modifier::BOLD);
            let text_style = ratatui::style::Style::default().fg(ratatui::style::Color::Yellow);
            let prefix = "System: ";
            let mut first = true;
            for text_line in text.lines() {
                if first {
                    lines.push(Line::from(vec![
                        Span::styled(prefix.to_string(), prefix_style),
                        Span::styled(text_line.to_owned(), text_style),
                    ]));
                    first = false;
                } else {
                    lines.push(Line::styled(text_line.to_owned(), text_style));
                }
            }
            if first {
                lines.push(Line::from(vec![Span::styled(
                    prefix.to_string(),
                    prefix_style,
                )]));
            }
            lines.push(Line::raw(""));
        }
        _ => {
            lines.push(Line::raw(""));
            let prefix = format!("{}: ", role);
            let prefix_style =
                ratatui::style::Style::default().add_modifier(ratatui::style::Modifier::BOLD);
            let mut first = true;
            for text_line in text.lines() {
                if first {
                    lines.push(Line::from(vec![
                        Span::styled(prefix.clone(), prefix_style),
                        Span::raw(text_line.to_owned()),
                    ]));
                    first = false;
                } else {
                    lines.push(Line::from(text_line.to_owned()));
                }
            }
            if first {
                lines.push(Line::from(vec![Span::styled(prefix, prefix_style)]));
            }
            lines.push(Line::raw(""));
        }
    }
}

fn render_tool_call<'a>(
    lines: &mut Vec<Line<'a>>,
    title: &str,
    kind: &agent_client_protocol::ToolKind,
    status: &agent_client_protocol::ToolCallStatus,
) {
    let icon = match kind {
        agent_client_protocol::ToolKind::Read => "📖",
        agent_client_protocol::ToolKind::Edit => "✏️",
        agent_client_protocol::ToolKind::Delete => "🗑️",
        agent_client_protocol::ToolKind::Move => "📦",
        agent_client_protocol::ToolKind::Search => "🔍",
        agent_client_protocol::ToolKind::Execute => "▶️",
        agent_client_protocol::ToolKind::Think => "💭",
        agent_client_protocol::ToolKind::Fetch => "🌐",
        agent_client_protocol::ToolKind::SwitchMode => "🔄",
        agent_client_protocol::ToolKind::Other => "🔧",
    };

    let status_indicator = match status {
        agent_client_protocol::ToolCallStatus::Pending => ("⏳", ratatui::style::Color::Yellow),
        agent_client_protocol::ToolCallStatus::InProgress => ("⚙️", ratatui::style::Color::Cyan),
        agent_client_protocol::ToolCallStatus::Completed => ("✓", ratatui::style::Color::Green),
        agent_client_protocol::ToolCallStatus::Failed => ("✗", ratatui::style::Color::Red),
    };

    let tool_style = ratatui::style::Style::default().fg(ratatui::style::Color::Cyan);
    let status_style = ratatui::style::Style::default().fg(status_indicator.1);

    lines.push(Line::from(vec![
        Span::raw(format!("{} ", icon)),
        Span::styled(title.to_owned(), tool_style),
        Span::raw(" "),
        Span::styled(status_indicator.0.to_owned(), status_style),
    ]));
}

fn render_plan<'a>(lines: &mut Vec<Line<'a>>, plan: &agent_client_protocol::Plan) {
    let header_style = ratatui::style::Style::default()
        .fg(ratatui::style::Color::Magenta)
        .add_modifier(ratatui::style::Modifier::BOLD);
    lines.push(Line::styled("📋 Plan", header_style));

    for entry in &plan.entries {
        let (status_icon, status_color) = match entry.status {
            agent_client_protocol::PlanEntryStatus::Pending => {
                ("○", ratatui::style::Color::DarkGray)
            }
            agent_client_protocol::PlanEntryStatus::InProgress => {
                ("◐", ratatui::style::Color::Yellow)
            }
            agent_client_protocol::PlanEntryStatus::Completed => {
                ("●", ratatui::style::Color::Green)
            }
        };

        let status_style = ratatui::style::Style::default().fg(status_color);
        let content_style = ratatui::style::Style::default();

        lines.push(Line::from(vec![
            Span::raw("  "),
            Span::styled(status_icon.to_owned(), status_style),
            Span::raw(" "),
            Span::styled(entry.content.clone(), content_style),
        ]));
    }
}

fn render_markdown_message(
    lines: &mut Vec<Line<'_>>,
    text: &str,
    normalized_markdown: Option<&str>,
    prefix: Option<(String, ratatui::style::Style)>,
) {
    let source = normalized_markdown.unwrap_or(text);
    let mut result_lines = markdown_to_lines(source);

    if let Some((label, style)) = prefix {
        if let Some(first_line) = result_lines.first_mut() {
            let mut spans = vec![Span::styled(label, style)];
            spans.append(&mut first_line.spans);
            *first_line = Line::from(spans);
        } else {
            result_lines.push(Line::from(vec![Span::styled(label, style)]));
        }
    }

    lines.extend(result_lines);
}
