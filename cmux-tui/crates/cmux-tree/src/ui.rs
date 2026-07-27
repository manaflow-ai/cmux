use std::time::{SystemTime, UNIX_EPOCH};

use ratatui::Frame;
use ratatui::layout::{Position, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::widgets::{Block, Borders, Clear};
use unicode_width::{UnicodeWidthChar, UnicodeWidthStr};

use crate::app::{App, Focus, Hit, HitKind, MachineDraft, MachineView};
use crate::codex::ConnectionState;
use crate::model::{ThreadSummary, ThreadTreeRow};
use crate::trajectory::{LineTone, build_trajectory};

const SELECTED_BG: Color = Color::Indexed(236);
const SELECTED_FG: Color = Color::Indexed(255);
const DIM_FG: Color = Color::Indexed(242);
const BORDER_FG: Color = Color::Indexed(238);
const ACTIVE_BORDER_FG: Color = Color::Indexed(110);
const INFO_FG: Color = Color::Indexed(110);
const WARNING_FG: Color = Color::Indexed(179);
const ERROR_FG: Color = Color::Indexed(167);
const SUCCESS_FG: Color = Color::Indexed(114);
const STATUS_BG: Color = Color::Indexed(236);
const STATUS_FG: Color = Color::Indexed(250);
const INPUT_BG: Color = Color::Indexed(233);

pub fn draw(app: &mut App, frame: &mut Frame) {
    let area = frame.area();
    app.hits.clear();
    if area.width == 0 || area.height == 0 {
        return;
    }
    if area.height < 4 || area.width < 30 {
        frame.buffer_mut().set_stringn(
            area.x,
            area.y,
            app.catalog.title(),
            area.width as usize,
            Style::default().fg(INFO_FG).add_modifier(Modifier::BOLD),
        );
        return;
    }

    let content =
        Rect { x: area.x, y: area.y, width: area.width, height: area.height.saturating_sub(1) };
    let (machines, conversations, trajectory) = column_layout(content);
    app.columns = crate::app::ColumnAreas { machines, conversations, trajectory };
    app.hits.extend([
        Hit { area: machines, kind: HitKind::Column(Focus::Machines) },
        Hit { area: conversations, kind: HitKind::Column(Focus::Conversations) },
        Hit { area: trajectory, kind: HitKind::Column(Focus::Trajectory) },
    ]);

    prepare_column(frame, machines, app.focus == Focus::Machines, true);
    prepare_column(frame, conversations, app.focus == Focus::Conversations, true);
    prepare_column(frame, trajectory, app.focus == Focus::Trajectory, false);
    draw_machines(app, frame, machines);
    draw_conversations(app, frame, conversations);
    draw_trajectory(app, frame, trajectory);
    draw_status(app, frame, Rect { y: area.y + area.height - 1, height: 1, ..area });
    if let Some(draft) = app.draft.clone() {
        draw_machine_dialog(app, frame, area, &draft);
    }
}

fn column_layout(area: Rect) -> (Rect, Rect, Rect) {
    let width = area.width;
    let machine_width = if width < 70 { width / 4 } else { (width / 5).clamp(18, 26) };
    let remaining = width.saturating_sub(machine_width);
    let conversation_width = if width < 70 {
        remaining * 2 / 5
    } else {
        (width * 31 / 100).clamp(28, 48).min(remaining.saturating_sub(20))
    };
    let trajectory_width = width.saturating_sub(machine_width + conversation_width);
    let machines = Rect { width: machine_width, ..area };
    let conversations = Rect { x: area.x + machine_width, width: conversation_width, ..area };
    let trajectory =
        Rect { x: conversations.x + conversation_width, width: trajectory_width, ..area };
    (machines, conversations, trajectory)
}

fn prepare_column(frame: &mut Frame, area: Rect, focused: bool, divider: bool) {
    if area.width == 0 {
        return;
    }
    let buffer = frame.buffer_mut();
    let content_width = area.width.saturating_sub(u16::from(divider));
    for y in area.y..area.y + area.height {
        for x in area.x..area.x + content_width {
            buffer[(x, y)].set_symbol(" ").set_style(Style::default());
        }
    }
    if divider {
        let x = area.x + area.width - 1;
        let style = Style::default().fg(if focused { ACTIVE_BORDER_FG } else { BORDER_FG });
        for y in area.y..area.y + area.height {
            buffer[(x, y)].set_symbol("│").set_style(style);
        }
    }
}

fn draw_header(frame: &mut Frame, area: Rect, title: &str, count: Option<usize>, focused: bool) {
    if area.width < 2 {
        return;
    }
    let suffix = count.map(|count| format!("  {count}")).unwrap_or_default();
    let text = format!(" {title}{suffix}");
    frame.buffer_mut().set_stringn(
        area.x,
        area.y,
        text,
        area.width.saturating_sub(1) as usize,
        Style::default().fg(if focused { SELECTED_FG } else { DIM_FG }).add_modifier(if focused {
            Modifier::BOLD
        } else {
            Modifier::empty()
        }),
    );
}

fn draw_machines(app: &mut App, frame: &mut Frame, area: Rect) {
    draw_header(
        frame,
        area,
        app.catalog.machines(),
        Some(app.machines.len()),
        app.focus == Focus::Machines,
    );
    let body =
        Rect { x: area.x, y: area.y + 2, width: area.width, height: area.height.saturating_sub(3) };
    let footer =
        Rect { x: area.x, y: area.y + area.height.saturating_sub(1), width: area.width, height: 1 };
    app.machine_viewport_height = body.height as usize;
    app.clamp_scrolls();
    if app.focus == Focus::Machines {
        app.reveal_machine_selection();
    }

    if app.machines.is_empty() {
        frame.buffer_mut().set_stringn(
            body.x + 1,
            body.y,
            app.catalog.no_machines(),
            body.width.saturating_sub(2) as usize,
            Style::default().fg(DIM_FG),
        );
    }
    for (index, machine) in app.machines.iter().enumerate() {
        let start = index * 3;
        draw_machine_row(
            frame,
            body,
            start,
            app.machine_scroll,
            MachineRow {
                machine,
                selected: index == app.selected_machine,
                focused: app.focus == Focus::Machines,
                catalog: app.catalog,
            },
        );
        if let Some(row) = visible_fixed_row(body, start, app.machine_scroll) {
            app.hits.push(Hit {
                area: Rect {
                    x: body.x,
                    y: row,
                    width: body.width.saturating_sub(1),
                    height: 2.min(body.y + body.height - row),
                },
                kind: HitKind::Machine(index),
            });
        }
    }
    draw_scrollbar(
        frame,
        body,
        app.machines.len() * 3,
        app.machine_scroll,
        app.focus == Focus::Machines,
    );

    let highlighted = app.focus == Focus::Machines && app.machines.is_empty();
    fill_row(
        frame,
        footer,
        if highlighted {
            Style::default().bg(SELECTED_BG).fg(SELECTED_FG)
        } else {
            Style::default().fg(DIM_FG)
        },
    );
    frame.buffer_mut().set_stringn(
        footer.x + 1,
        footer.y,
        format!("+ {}", app.catalog.add_machine()),
        footer.width.saturating_sub(2) as usize,
        if highlighted {
            Style::default().bg(SELECTED_BG).fg(SELECTED_FG).add_modifier(Modifier::BOLD)
        } else {
            Style::default().fg(DIM_FG)
        },
    );
    app.hits.push(Hit {
        area: Rect { width: footer.width.saturating_sub(1), ..footer },
        kind: HitKind::AddMachine,
    });
}

struct MachineRow<'a> {
    machine: &'a MachineView,
    selected: bool,
    focused: bool,
    catalog: crate::localization::Catalog,
}

fn draw_machine_row(
    frame: &mut Frame,
    area: Rect,
    start: usize,
    offset: usize,
    row: MachineRow<'_>,
) {
    let MachineRow { machine, selected, focused, catalog } = row;
    let selected_style =
        Style::default().bg(SELECTED_BG).fg(SELECTED_FG).add_modifier(Modifier::BOLD);
    let normal = Style::default();
    let style = if selected { selected_style } else { normal };
    let dim = if selected {
        selected_style.remove_modifier(Modifier::BOLD).add_modifier(Modifier::DIM)
    } else {
        Style::default().fg(DIM_FG)
    };
    let indicator = match &machine.connection {
        ConnectionState::Connected => INFO_FG,
        ConnectionState::Connecting => WARNING_FG,
        ConnectionState::Disconnected(_) => ERROR_FG,
    };
    let status = match &machine.connection {
        ConnectionState::Connected => machine
            .selected_thread()
            .map(|thread| app_server_status(thread, catalog))
            .unwrap_or_else(|| catalog.connected().to_string()),
        ConnectionState::Connecting => catalog.connecting().to_string(),
        ConnectionState::Disconnected(_) => catalog.disconnected().to_string(),
    };

    for line in 0..2 {
        let absolute = start + line;
        let Some(y) = visible_line(area, absolute, offset) else { continue };
        if selected {
            fill_row(
                frame,
                Rect { x: area.x, y, width: area.width.saturating_sub(1), height: 1 },
                if focused { selected_style } else { style.remove_modifier(Modifier::BOLD) },
            );
        }
        if line == 0 {
            frame.buffer_mut()[(area.x, y)]
                .set_symbol(if selected { "▎" } else { "•" })
                .set_style(style.fg(if selected { ACTIVE_BORDER_FG } else { indicator }));
            frame.buffer_mut().set_stringn(
                area.x + 1,
                y,
                truncate_width(&machine.config.name, area.width.saturating_sub(3) as usize),
                area.width.saturating_sub(3) as usize,
                style,
            );
        } else {
            let subtitle = if status.is_empty() { machine.config.url.as_str() } else { &status };
            frame.buffer_mut().set_stringn(
                area.x + 1,
                y,
                truncate_width(subtitle, area.width.saturating_sub(3) as usize),
                area.width.saturating_sub(3) as usize,
                dim,
            );
        }
    }
}

fn draw_conversations(app: &mut App, frame: &mut Frame, area: Rect) {
    let rows = app.selected_machine().map(|machine| machine.rows.clone()).unwrap_or_default();
    draw_header(
        frame,
        area,
        app.catalog.conversations(),
        Some(rows.len()),
        app.focus == Focus::Conversations,
    );
    let body =
        Rect { x: area.x, y: area.y + 2, width: area.width, height: area.height.saturating_sub(2) };
    app.conversation_viewport_height = body.height as usize;
    app.clamp_scrolls();
    if app.focus == Focus::Conversations {
        app.reveal_conversation_selection();
    }
    if rows.is_empty() {
        let message = if app.machines.is_empty() {
            app.catalog.no_machines()
        } else if app
            .selected_machine()
            .is_some_and(|machine| matches!(machine.connection, ConnectionState::Connecting))
        {
            app.catalog.loading()
        } else {
            app.catalog.no_conversations()
        };
        frame.buffer_mut().set_stringn(
            body.x + 1,
            body.y,
            message,
            body.width.saturating_sub(2) as usize,
            Style::default().fg(DIM_FG),
        );
    }
    let selected = app.selected_machine().and_then(MachineView::selected_row);
    for (index, row) in rows.iter().enumerate() {
        let start = index * 3;
        draw_conversation_row(
            frame,
            body,
            start,
            app.conversation_scroll,
            ConversationRow {
                row,
                selected: selected == Some(index),
                focused: app.focus == Focus::Conversations,
                catalog: app.catalog,
            },
        );
        if let Some(y) = visible_fixed_row(body, start, app.conversation_scroll) {
            app.hits.push(Hit {
                area: Rect {
                    x: body.x,
                    y,
                    width: body.width.saturating_sub(1),
                    height: 2.min(body.y + body.height - y),
                },
                kind: HitKind::Conversation(index),
            });
        }
    }
    draw_scrollbar(
        frame,
        body,
        rows.len() * 3,
        app.conversation_scroll,
        app.focus == Focus::Conversations,
    );
}

struct ConversationRow<'a> {
    row: &'a ThreadTreeRow,
    selected: bool,
    focused: bool,
    catalog: crate::localization::Catalog,
}

fn draw_conversation_row(
    frame: &mut Frame,
    area: Rect,
    start: usize,
    offset: usize,
    entry: ConversationRow<'_>,
) {
    let ConversationRow { row, selected, focused, catalog } = entry;
    let selected_style =
        Style::default().bg(SELECTED_BG).fg(SELECTED_FG).add_modifier(Modifier::BOLD);
    let base = if selected {
        if focused { selected_style } else { selected_style.remove_modifier(Modifier::BOLD) }
    } else {
        Style::default()
    };
    let dim = if selected { base.add_modifier(Modifier::DIM) } else { Style::default().fg(DIM_FG) };
    let indicator = status_color(&row.thread);
    let prefix = row.prefix();
    let title = if row.depth() > 0 {
        row.thread.subagent_title().unwrap_or_else(|| catalog.unnamed().to_string())
    } else {
        row.thread.title().unwrap_or(catalog.unnamed()).to_string()
    };
    let first = format!("{prefix}{title}");
    let status = app_server_status(&row.thread, catalog);
    let age = relative_age(row.thread.activity_at(), catalog);
    let cwd = row.thread.cwd.rsplit('/').find(|part| !part.is_empty()).unwrap_or_default();
    let second = [status.as_str(), age.as_str(), cwd]
        .into_iter()
        .filter(|value| !value.is_empty())
        .collect::<Vec<_>>()
        .join(" · ");

    for line in 0..2 {
        let absolute = start + line;
        let Some(y) = visible_line(area, absolute, offset) else { continue };
        if selected {
            fill_row(
                frame,
                Rect { x: area.x, y, width: area.width.saturating_sub(1), height: 1 },
                base,
            );
        }
        if line == 0 {
            frame.buffer_mut()[(area.x, y)]
                .set_symbol(if selected { "▎" } else { "•" })
                .set_style(base.fg(if selected { ACTIVE_BORDER_FG } else { indicator }));
            frame.buffer_mut().set_stringn(
                area.x + 1,
                y,
                truncate_width(&first, area.width.saturating_sub(3) as usize),
                area.width.saturating_sub(3) as usize,
                base,
            );
        } else {
            frame.buffer_mut().set_stringn(
                area.x + 1,
                y,
                truncate_width(&second, area.width.saturating_sub(3) as usize),
                area.width.saturating_sub(3) as usize,
                dim,
            );
        }
    }
}

fn draw_trajectory(app: &mut App, frame: &mut Frame, area: Rect) {
    let title = app
        .selected_machine()
        .and_then(MachineView::selected_thread)
        .and_then(ThreadSummary::title)
        .unwrap_or(app.catalog.trajectory())
        .to_string();
    draw_header(frame, area, &title, None, app.focus == Focus::Trajectory);
    let body =
        Rect { x: area.x, y: area.y + 2, width: area.width, height: area.height.saturating_sub(2) };
    app.trajectory_viewport_height = body.height as usize;
    let conversation = app.selected_machine().and_then(|machine| machine.conversation.clone());
    app.trajectory_view = conversation.as_ref().map_or_else(Default::default, |conversation| {
        build_trajectory(
            conversation,
            body.width.saturating_sub(3) as usize,
            app.catalog,
            &app.expansion,
        )
    });
    app.trajectory_cursor =
        app.trajectory_cursor.min(app.trajectory_view.accordions.len().saturating_sub(1));
    app.clamp_scrolls();

    if conversation.is_none() {
        let message = app
            .selected_machine()
            .and_then(|machine| machine.error.as_deref())
            .unwrap_or(app.catalog.select_conversation());
        frame.buffer_mut().set_stringn(
            body.x + 1,
            body.y,
            message,
            body.width.saturating_sub(2) as usize,
            Style::default().fg(DIM_FG),
        );
    }

    for line_index in app.trajectory_scroll
        ..(app.trajectory_scroll + body.height as usize).min(app.trajectory_view.lines.len())
    {
        let y = body.y + (line_index - app.trajectory_scroll) as u16;
        let line = &app.trajectory_view.lines[line_index];
        let accordion_index = app
            .trajectory_view
            .accordions
            .iter()
            .position(|accordion| accordion.line_index == line_index);
        let selected = accordion_index == Some(app.trajectory_cursor);
        let style = if selected {
            let style = Style::default().bg(SELECTED_BG).fg(SELECTED_FG);
            if app.focus == Focus::Trajectory { style.add_modifier(Modifier::BOLD) } else { style }
        } else {
            tone_style(line.tone)
        };
        if selected {
            fill_row(
                frame,
                Rect { x: body.x, y, width: body.width.saturating_sub(1), height: 1 },
                style,
            );
        }
        let prefix = "  ".repeat(line.indent as usize);
        let text = format!(" {prefix}{}", line.text);
        frame.buffer_mut().set_stringn(
            body.x,
            y,
            truncate_width(&text, body.width.saturating_sub(2) as usize),
            body.width.saturating_sub(2) as usize,
            style,
        );
        if let Some(index) = accordion_index {
            app.hits.push(Hit {
                area: Rect { x: body.x, y, width: body.width.saturating_sub(1), height: 1 },
                kind: HitKind::Accordion(index),
            });
        }
    }
    draw_scrollbar(
        frame,
        body,
        app.trajectory_view.lines.len(),
        app.trajectory_scroll,
        app.focus == Focus::Trajectory,
    );
}

fn draw_scrollbar(frame: &mut Frame, area: Rect, total: usize, offset: usize, focused: bool) {
    if area.width == 0 || area.height == 0 || total <= area.height as usize {
        return;
    }
    let track_height = area.height as usize;
    let thumb_height = ((track_height * track_height).div_ceil(total)).clamp(1, track_height);
    let scrollable = total.saturating_sub(track_height).max(1);
    let thumb_y =
        (offset.min(scrollable) * (track_height - thumb_height) + scrollable / 2) / scrollable;
    let x = area.x + area.width - 1;
    for line in 0..track_height {
        let in_thumb = line >= thumb_y && line < thumb_y + thumb_height;
        frame.buffer_mut()[(x, area.y + line as u16)]
            .set_symbol(if in_thumb { "┃" } else { "│" })
            .set_style(Style::default().fg(if in_thumb {
                if focused { SELECTED_FG } else { Color::Indexed(246) }
            } else {
                BORDER_FG
            }));
    }
}

fn draw_status(app: &App, frame: &mut Frame, area: Rect) {
    fill_row(frame, area, Style::default().bg(STATUS_BG).fg(STATUS_FG));
    let title = format!(" {} ", app.catalog.title());
    frame.buffer_mut().set_stringn(
        area.x,
        area.y,
        &title,
        area.width as usize,
        Style::default().bg(STATUS_BG).fg(SELECTED_FG).add_modifier(Modifier::BOLD),
    );
    let message = app
        .status_message
        .as_ref()
        .map(|(message, _)| message.as_str())
        .unwrap_or_else(|| app.catalog.key_help());
    let available = area.width.saturating_sub(title.width() as u16 + 1);
    frame.buffer_mut().set_stringn(
        area.x + title.width() as u16,
        area.y,
        format!(" {message}"),
        available as usize,
        Style::default().bg(STATUS_BG).fg(DIM_FG),
    );
}

fn draw_machine_dialog(app: &mut App, frame: &mut Frame, screen: Rect, draft: &MachineDraft) {
    let width = screen.width.saturating_sub(4).clamp(28, 72);
    let height = 13.min(screen.height.saturating_sub(2)).max(8);
    let area = Rect {
        x: screen.x + screen.width.saturating_sub(width) / 2,
        y: screen.y + screen.height.saturating_sub(height) / 2,
        width,
        height,
    };
    frame.render_widget(Clear, area);
    let block = Block::default()
        .borders(Borders::ALL)
        .title(format!(" {} ", app.catalog.add_title()))
        .border_style(Style::default().fg(ACTIVE_BORDER_FG))
        .style(Style::default().bg(STATUS_BG).fg(STATUS_FG));
    frame.render_widget(block, area);

    let labels =
        [app.catalog.machine_name(), app.catalog.websocket_url(), app.catalog.token_file()];
    let mut active_cursor = None;
    for (index, label) in labels.iter().enumerate() {
        let label_y = area.y + 2 + index as u16 * 3;
        if label_y + 1 >= area.y + area.height {
            break;
        }
        frame.buffer_mut().set_stringn(
            area.x + 2,
            label_y,
            label,
            area.width.saturating_sub(4) as usize,
            Style::default().bg(STATUS_BG).fg(if draft.field == index {
                SELECTED_FG
            } else {
                DIM_FG
            }),
        );
        let input_area =
            Rect { x: area.x + 2, y: label_y + 1, width: area.width.saturating_sub(4), height: 1 };
        let style = Style::default()
            .bg(if draft.field == index { INPUT_BG } else { SELECTED_BG })
            .fg(SELECTED_FG);
        fill_row(frame, input_area, style);
        let (visible, cursor_x) =
            input_window(&draft.values[index], draft.cursors[index], input_area.width as usize);
        frame.buffer_mut().set_stringn(
            input_area.x,
            input_area.y,
            visible,
            input_area.width as usize,
            style,
        );
        app.hits.push(Hit { area: input_area, kind: HitKind::DialogField(index) });
        if draft.field == index {
            active_cursor = Some(Position::new(
                input_area.x + cursor_x.min(input_area.width.saturating_sub(1) as usize) as u16,
                input_area.y,
            ));
        }
    }

    let controls_y = area.y + area.height.saturating_sub(2);
    let save = format!("[{}]", app.catalog.save());
    frame.buffer_mut().set_stringn(
        area.x + 2,
        controls_y,
        &save,
        save.width(),
        Style::default().bg(STATUS_BG).fg(SUCCESS_FG).add_modifier(Modifier::BOLD),
    );
    app.hits.push(Hit {
        area: Rect { x: area.x + 2, y: controls_y, width: save.width() as u16, height: 1 },
        kind: HitKind::DialogSave,
    });
    frame.buffer_mut().set_stringn(
        area.x + 4 + save.width() as u16,
        controls_y,
        app.catalog.cancel(),
        area.width.saturating_sub(6 + save.width() as u16) as usize,
        Style::default().bg(STATUS_BG).fg(DIM_FG),
    );
    app.hits.push(Hit {
        area: Rect {
            x: area.x + 4 + save.width() as u16,
            y: controls_y,
            width: app.catalog.cancel().width() as u16,
            height: 1,
        },
        kind: HitKind::DialogCancel,
    });
    if let Some(error) = draft.error.as_deref() {
        frame.buffer_mut().set_stringn(
            area.x + 2,
            controls_y.saturating_sub(1),
            error,
            area.width.saturating_sub(4) as usize,
            Style::default().bg(STATUS_BG).fg(ERROR_FG),
        );
    }
    if let Some(cursor) = active_cursor {
        frame.set_cursor_position(cursor);
    }
}

fn input_window(value: &str, cursor: usize, width: usize) -> (String, usize) {
    if width == 0 {
        return (String::new(), 0);
    }
    let characters = value.chars().collect::<Vec<_>>();
    let start = cursor.saturating_sub(width.saturating_sub(1));
    let visible = characters.iter().skip(start).take(width).collect::<String>();
    (visible, cursor.saturating_sub(start))
}

fn fill_row(frame: &mut Frame, area: Rect, style: Style) {
    for y in area.y..area.y + area.height {
        for x in area.x..area.x + area.width {
            frame.buffer_mut()[(x, y)].set_symbol(" ").set_style(style);
        }
    }
}

fn visible_fixed_row(area: Rect, start: usize, offset: usize) -> Option<u16> {
    visible_line(area, start, offset)
}

fn visible_line(area: Rect, line: usize, offset: usize) -> Option<u16> {
    if line < offset || line >= offset + area.height as usize {
        return None;
    }
    Some(area.y + (line - offset) as u16)
}

fn truncate_width(value: &str, width: usize) -> String {
    if value.width() <= width {
        return value.to_string();
    }
    if width == 0 {
        return String::new();
    }
    let target = width.saturating_sub(1);
    let mut used = 0;
    let mut output = String::new();
    for character in value.chars() {
        let character_width = character.width().unwrap_or(0);
        if used + character_width > target {
            break;
        }
        output.push(character);
        used += character_width;
    }
    output.push('…');
    output
}

fn status_color(thread: &ThreadSummary) -> Color {
    match thread.status_type() {
        "active" => {
            let flags = thread.active_flags();
            if flags
                .iter()
                .any(|flag| matches!(flag.as_str(), "waitingOnApproval" | "waitingOnUserInput"))
            {
                WARNING_FG
            } else {
                INFO_FG
            }
        }
        "systemError" => ERROR_FG,
        "idle" => SUCCESS_FG,
        _ => DIM_FG,
    }
}

fn app_server_status(thread: &ThreadSummary, catalog: crate::localization::Catalog) -> String {
    catalog.status(thread.status_type(), &thread.active_flags()).to_string()
}

fn relative_age(timestamp: i64, catalog: crate::localization::Catalog) -> String {
    let now: i64 = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
        .try_into()
        .unwrap_or(i64::MAX);
    catalog.elapsed(now.saturating_sub(timestamp))
}

fn tone_style(tone: LineTone) -> Style {
    match tone {
        LineTone::Normal => Style::default(),
        LineTone::Dim => Style::default().fg(DIM_FG),
        LineTone::User => Style::default().fg(INFO_FG).add_modifier(Modifier::BOLD),
        LineTone::Agent => Style::default().fg(SELECTED_FG).add_modifier(Modifier::BOLD),
        LineTone::Accent => Style::default().fg(INFO_FG),
        LineTone::Success => Style::default().fg(SUCCESS_FG),
        LineTone::Error => Style::default().fg(ERROR_FG),
    }
}

#[cfg(test)]
mod tests {
    use ratatui::Terminal;
    use ratatui::backend::TestBackend;
    use serde_json::json;

    use super::*;
    use crate::app::App;
    use crate::config::{Config, MachineConfig};
    use crate::model::{Conversation, ThreadSummary, Turn, flatten_thread_tree};

    #[test]
    fn three_column_screen_renders_machine_subagent_and_collapsed_work() {
        let config = Config {
            machines: vec![MachineConfig {
                id: "machine".into(),
                name: "studio".into(),
                url: "ws://127.0.0.1:4500".into(),
                token_file: None,
            }],
        };
        let mut app = App::fixture(config);
        let root = ThreadSummary {
            id: "root".into(),
            preview: "Build cmux tree".into(),
            updated_at: 100,
            status: json!({"type": "idle"}),
            ..ThreadSummary::default()
        };
        let child = ThreadSummary {
            id: "child".into(),
            parent_thread_id: Some("root".into()),
            agent_nickname: Some("Scout".into()),
            agent_role: Some("explorer".into()),
            updated_at: 90,
            status: json!({"type": "idle"}),
            ..ThreadSummary::default()
        };
        app.machines[0].connection = ConnectionState::Connected;
        app.machines[0].threads = vec![root.clone(), child];
        app.machines[0].rows = flatten_thread_tree(app.machines[0].threads.clone());
        app.machines[0].selected_thread_id = Some(root.id);
        app.machines[0].conversation = Some(Conversation {
            id: "root".into(),
            status: json!({"type": "idle"}),
            turns: vec![Turn {
                id: "turn".into(),
                status: "completed".into(),
                items: vec![
                    json!({"type": "userMessage", "id": "u", "content": [{"type": "text", "text": "Build it"}]}),
                    json!({"type": "commandExecution", "id": "c", "command": "cargo test", "status": "completed"}),
                    json!({"type": "agentMessage", "id": "a", "text": "Done"}),
                ],
                ..Turn::default()
            }],
        });

        let mut terminal = Terminal::new(TestBackend::new(110, 24)).unwrap();
        terminal.draw(|frame| draw(&mut app, frame)).unwrap();
        let screen = terminal.backend().buffer().content().iter().enumerate().fold(
            String::new(),
            |mut output, (index, cell)| {
                if index > 0 && index % 110 == 0 {
                    output.push('\n');
                }
                output.push_str(cell.symbol());
                output
            },
        );

        assert!(screen.contains("machines"));
        assert!(screen.contains("conversations"));
        assert!(screen.contains("Scout · explorer"));
        assert!(screen.contains("work · 1 steps"));
        assert!(!screen.contains("cargo test"));
    }

    #[test]
    fn width_truncation_respects_wide_characters() {
        assert_eq!(truncate_width("東京terminal", 6), "東京t…");
    }

    #[test]
    fn long_conversation_list_draws_a_proportional_scrollbar() {
        let config = Config {
            machines: vec![MachineConfig {
                id: "machine".into(),
                name: "studio".into(),
                url: "ws://127.0.0.1:4500".into(),
                token_file: None,
            }],
        };
        let mut app = App::fixture(config);
        app.machines[0].connection = ConnectionState::Connected;
        app.machines[0].threads = (0..20)
            .map(|index| ThreadSummary {
                id: format!("thread-{index}"),
                preview: format!("Conversation {index}"),
                updated_at: 100 - index,
                status: json!({"type": "idle"}),
                ..ThreadSummary::default()
            })
            .collect();
        app.machines[0].rows = flatten_thread_tree(app.machines[0].threads.clone());
        app.machines[0].selected_thread_id = Some("thread-0".into());

        let mut terminal = Terminal::new(TestBackend::new(90, 14)).unwrap();
        terminal.draw(|frame| draw(&mut app, frame)).unwrap();

        let x = app.columns.conversations.x + app.columns.conversations.width - 1;
        let track = (app.columns.conversations.y + 2
            ..app.columns.conversations.y + app.columns.conversations.height)
            .map(|y| terminal.backend().buffer()[(x, y)].symbol())
            .collect::<Vec<_>>();
        assert!(track.contains(&"┃"));
        assert!(track.contains(&"│"));
    }
}
