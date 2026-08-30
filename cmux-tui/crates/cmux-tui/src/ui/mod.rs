//! Frame drawing: sidebar, panes (border box with tab bar, ghostty
//! render state, and scrollbar), status bar, and overlays (context menu,
//! rename prompt). Every renderer that draws something interactive also
//! pushes a [`Hit`] so clicks always match what is on screen.

pub mod graphics;
pub mod graphics_writer;
pub(crate) mod input;
pub mod omnibar;
mod overlay;
pub(crate) mod pane;
mod rail;
mod scrollbar;
mod sidebar;
pub(crate) mod terminal_grid;

use cmux_tui_core::Rect;
use ratatui::Frame;
use ratatui::buffer::Buffer;
use ratatui::layout::{Position, Rect as RatatuiRect};
use ratatui::style::{Color, Modifier, Style};
use unicode_segmentation::UnicodeSegmentation;
use unicode_width::UnicodeWidthStr;

use crate::app::{App, Hit, RailKind};
use crate::config::Action;
use crate::localization::catalog;
use crate::machine::{DurableNoticeLevel, MachineConnectionPhase};

pub(crate) use overlay::toast_rect;
pub(crate) use scrollbar::{
    ScrollbarState, ScrollbarStyle, horizontal_drag_offset, horizontal_offset_at,
    horizontal_thumb_geometry, thumb_geometry, viewport_drag_offset, viewport_jump_offset,
    viewport_thumb_geometry,
};

#[derive(Default)]
pub(crate) struct ReusableRowBuffer {
    buffer: Option<Buffer>,
}

impl ReusableRowBuffer {
    pub(crate) fn take(&mut self, width: u16) -> Buffer {
        let mut buffer =
            self.buffer.take().unwrap_or_else(|| Buffer::empty(RatatuiRect::default()));
        buffer.resize(RatatuiRect::new(0, 0, width, 1));
        buffer.reset();
        buffer
    }

    pub(crate) fn put(&mut self, buffer: Buffer) {
        debug_assert!(self.buffer.is_none(), "row scratch buffer returned twice");
        self.buffer = Some(buffer);
    }
}

/// Copy one logical buffer row into a visible destination slice.
///
/// Ratatui stores a wide glyph in its lead cell and leaves its following
/// cell blank. Blanking a lead or tail cut by either crop boundary prevents
/// the terminal renderer from overwriting an adjacent pane or wrapping.
pub(crate) fn copy_buffer_row_cropped(
    source: &Buffer,
    source_row: u16,
    source_x: u16,
    target: &mut Buffer,
    target_rect: Rect,
) -> u16 {
    let source_y = source.area.y.saturating_add(source_row);
    let source_left = source.area.x.saturating_add(source_x);
    let source_right = source.area.x.saturating_add(source.area.width);
    let target_right = target.area.x.saturating_add(target.area.width);
    let target_bottom = target.area.y.saturating_add(target.area.height);
    if source_y >= source.area.y.saturating_add(source.area.height)
        || source_left >= source_right
        || target_rect.y < target.area.y
        || target_rect.y >= target_bottom
        || target_rect.x < target.area.x
        || target_rect.x >= target_right
    {
        return 0;
    }
    let width = target_rect
        .width
        .min(source_right.saturating_sub(source_left))
        .min(target_right.saturating_sub(target_rect.x));
    let partial_left =
        source_left > source.area.x && source[(source_left - 1, source_y)].symbol().width() > 1;
    for dx in 0..width {
        let source_cell = &source[(source_left + dx, source_y)];
        let target_cell = &mut target[(target_rect.x + dx, target_rect.y)];
        *target_cell = source_cell.clone();
        let symbol_width = source_cell.symbol().width() as u16;
        if (dx == 0 && partial_left) || symbol_width > width.saturating_sub(dx) {
            target_cell.set_symbol(" ");
        }
    }
    width
}

pub fn draw(app: &mut App, frame: &mut Frame) {
    app.reset_frame_cursor_spec();
    app.reset_rendered_status_message();
    let area = frame.area();
    app.hits.clear();
    if area.width == 0 || area.height == 0 {
        return;
    }
    if app.shortcut_help.is_some() && (area.width < 24 || area.height < 7) {
        app.shortcut_help = None;
    }

    let mut sidebar_input_cursor = None;
    if app.sidebar_layout.ordered.is_empty() {
        // Preserve the pre-layout fallback used during startup, recovery, and
        // isolated renderer tests. Each renderer resolves its area from the
        // legacy live widths when no committed ordered layout exists yet.
        if app.machine_sidebar_width > 0 {
            sidebar::draw_machines(app, frame);
        }
        if app.sidebar_width > 0 {
            sidebar_input_cursor = sidebar::draw(app, frame);
        }
        if app.tabs_sidebar_width > 0 {
            sidebar::draw_tabs(app, frame);
        }
    } else {
        for placement in app.sidebar_layout.ordered.clone() {
            match placement.kind {
                RailKind::Machine => sidebar::draw_machines(app, frame),
                RailKind::Workspace => sidebar_input_cursor = sidebar::draw(app, frame),
                RailKind::Tabs => sidebar::draw_tabs(app, frame),
                RailKind::Projection(index) => sidebar::draw_projection(app, frame, index),
            }
        }
    }

    let pane_cursors = if draw_machine_transition(app, frame) {
        pane::DrawCursors::default()
    } else {
        pane::draw_all(app, frame)
    };
    if app.is_surface_only() || !app.config.status_bar.visible {
        // No reserved status row: transient messages overlay the last row
        // with foreground styling only, single-surface style.
        draw_surface_status(app, frame);
    } else {
        draw_status_bar(app, frame);
    }
    overlay::draw_toast(app, frame);
    overlay::draw_menu(app, frame);
    overlay::draw_shortcut_help(app, frame);

    if app.pairing_dialog.is_some() {
        overlay::draw_pairing_dialog(app, frame);
    // The rename dialog owns the terminal cursor while it is open.
    } else if app.prompt.is_some() {
        overlay::draw_prompt(app, frame);
    } else if app.menu.is_none()
        && app.shortcut_help.is_none()
        && let Some((x, y)) = pane_cursors.input.or(sidebar_input_cursor).or(pane_cursors.terminal)
    {
        frame.set_cursor_position(Position::new(x, y));
    }
    draw_durable_notice_banner(app, frame);
    sanitize_render_buffer(frame.buffer_mut());
}

fn draw_machine_transition(app: &mut App, frame: &mut Frame) -> bool {
    let Some((name, status_text)) = app.machine_transition().map(|view| {
        // Precedence for the interstitial's second line: a hard failure,
        // then a deliberately-asleep hint, then the provider's live progress
        // message, then a status-aware default ("waking" beats a generic
        // "connecting" for a sleeping or stopped machine being resumed).
        let asleep = matches!(
            view.status,
            crate::machine::MachineStatus::Sleeping | crate::machine::MachineStatus::Stopped
        );
        let status_text = if view.phase == MachineConnectionPhase::Failed {
            catalog().sidebar.unavailable.to_string()
        } else if view.phase == MachineConnectionPhase::Disconnected && asleep {
            // Deliberately asleep, nothing in flight: the next keystroke or
            // click wakes it.
            catalog().sidebar.sleeping_wake_hint.to_string()
        } else if let Some(progress) = view.progress {
            progress.to_string()
        } else if asleep {
            catalog().sidebar.waking.to_string()
        } else {
            catalog().sidebar.connecting.to_string()
        };
        (view.name.to_string(), status_text)
    }) else {
        return false;
    };
    let area = app.content_area;
    app.pane_areas.clear();
    if area.width == 0 || area.height == 0 {
        return true;
    }
    app.hits.retain(|(rect, _)| {
        rect.x >= area.x.saturating_add(area.width)
            || area.x >= rect.x.saturating_add(rect.width)
            || rect.y >= area.y.saturating_add(area.height)
            || area.y >= rect.y.saturating_add(rect.height)
    });
    let status = status_text.as_str();
    let style = Style::default().fg(app.chrome.sidebar_dim_fg);
    let title_style =
        Style::default().fg(app.chrome.sidebar_selected_fg).add_modifier(Modifier::BOLD);
    let buffer = frame.buffer_mut();
    for y in area.y..area.y.saturating_add(area.height) {
        for x in area.x..area.x.saturating_add(area.width) {
            buffer[(x, y)].set_symbol(" ").set_style(Style::default());
        }
    }
    let center_y = area.y.saturating_add(area.height / 2);
    let title_width = name.width().min(area.width as usize);
    let title_x = area.x.saturating_add(area.width.saturating_sub(title_width as u16) / 2);
    buffer.set_stringn(title_x, center_y.saturating_sub(1), &name, title_width, title_style);
    let status_width = status.width().min(area.width as usize);
    let status_x = area.x.saturating_add(area.width.saturating_sub(status_width as u16) / 2);
    buffer.set_stringn(status_x, center_y, status, status_width, style);
    true
}

fn draw_durable_notice_banner(app: &mut App, frame: &mut Frame) {
    let area = frame.area();
    if area.width == 0 || area.height == 0 {
        return;
    }
    let Some(notice) = app.durable_notice().cloned() else {
        return;
    };
    app.hide_status_message();
    app.hits.retain(|(_, hit)| !matches!(hit, Hit::StatusMessage | Hit::CopyStatusMessage));
    let (marker, color) = match notice.level {
        DurableNoticeLevel::Info => ("i ", app.config.theme.notification_info),
        DurableNoticeLevel::Warning => ("! ", app.config.theme.notification_warning),
        DurableNoticeLevel::Error => ("x ", app.config.theme.notification_error),
    };
    let message = notice
        .message
        .chars()
        .map(|character| if character.is_control() { ' ' } else { character })
        .collect::<String>();
    let text = format!("{marker}{message}");
    let style = Style::default().fg(app.chrome.status_bg).bg(color).add_modifier(Modifier::BOLD);
    let y = area.height - 1;
    for x in 0..area.width {
        frame.buffer_mut()[(x, y)].set_symbol(" ").set_style(style);
    }
    frame.buffer_mut().set_stringn(0, y, text, area.width as usize, style);
    app.record_durable_notice_painted(notice.delivery);
}

/// Single-surface clients keep the full terminal grid and overlay transient
/// notices on its last row using foreground styling only.
fn draw_surface_status(app: &mut App, frame: &mut Frame) {
    let Some(message) = app.status_message.as_deref() else {
        app.hide_status_message();
        return;
    };
    let area = frame.area();
    if area.width == 0 {
        app.hide_status_message();
        return;
    }
    let copy_label = status_copy_label();
    let copy_width = copy_label.width().min(area.width as usize) as u16;
    let show_copy = area.width > copy_width.saturating_add(2);
    let message_width = if show_copy {
        area.width.saturating_sub(copy_width.saturating_add(1))
    } else {
        area.width
    };
    let text = status_display_text(message, message_width as usize);
    let text_width = text.width() as u16;
    let style = Style::default().fg(Color::Red).add_modifier(Modifier::BOLD);
    draw_interactive_status_message(
        app,
        frame,
        Rect { x: 0, y: area.height - 1, width: text_width, height: 1 },
        text,
        style,
    );
    if show_copy {
        draw_status_copy_control(
            app,
            frame,
            Rect {
                x: text_width.saturating_add(1),
                y: area.height - 1,
                width: copy_width,
                height: 1,
            },
            &copy_label,
            style,
        );
    }
}

fn status_display_text(message: &str, max_width: usize) -> String {
    let sanitized = message
        .chars()
        .map(|character| if character.is_control() { ' ' } else { character })
        .collect::<String>();
    truncate(&sanitized, max_width)
}

fn draw_interactive_status_message(
    app: &mut App,
    frame: &mut Frame,
    rect: Rect,
    text: String,
    style: Style,
) {
    if rect.width == 0 || text.is_empty() {
        app.hide_status_message();
        return;
    }
    app.present_status_message(rect, text.clone());
    app.hits.push((rect, Hit::StatusMessage));
    frame.buffer_mut().set_stringn(rect.x, rect.y, &text, rect.width as usize, style);

    let mut selected_style = style.bg(app.config.theme.selection_bg);
    if let Some(foreground) = app.config.theme.selection_fg {
        selected_style = selected_style.fg(foreground);
    }
    for cell in 0..rect.width {
        if app.status_message_cell_selected(&text, cell) {
            frame.buffer_mut()[(rect.x + cell, rect.y)].set_style(selected_style);
        }
    }
}

fn status_copy_label() -> String {
    format!("[{}]", catalog().menu.copy_message)
}

fn draw_status_copy_control(
    app: &mut App,
    frame: &mut Frame,
    rect: Rect,
    label: &str,
    style: Style,
) {
    if rect.width == 0 {
        return;
    }
    let hovered = app.hover.is_some_and(|(x, y)| rect.contains(x, y));
    let style = if hovered { style.add_modifier(Modifier::REVERSED) } else { style };
    frame.buffer_mut().set_stringn(rect.x, rect.y, label, rect.width as usize, style);
    app.hits.push((rect, Hit::CopyStatusMessage));
}

fn sanitize_render_buffer(buffer: &mut Buffer) {
    // Ratatui rejects control bytes while diffing a frame. Keep the
    // component-level text sanitizers for useful output, then enforce this
    // final invariant across titles, plugin UI, browser text, and future
    // renderers so one malformed cell cannot take down the frontend.
    for cell in &mut buffer.content {
        if cell.symbol().chars().any(char::is_control) {
            cell.set_symbol(" ");
        }
    }
}

/// Status bar: the active workspace's screens, one clickable segment per
/// screen plus a trailing `+` for a new one. It spans only the pane
/// region (it does not extend under the sidebar).
fn draw_status_bar(app: &mut App, frame: &mut Frame) {
    let area = frame.area();
    let status_y = area.height - 1;
    let bar_x = app.total_sidebar_width().min(area.width);
    let chrome = app.chrome;
    let theme = app.config.theme;
    let status_bg = theme.status_bg.unwrap_or(chrome.status_bg);
    let status_fg = theme.status_fg.unwrap_or(chrome.status_fg);
    let base = Style::default().bg(status_bg).fg(status_fg);
    let segments = app.resolved_status_segments();
    let (left_segments, right_segments) = (&segments.0, &segments.1);
    let segment_style = |segment: &crate::app::StatusSegmentView| {
        Style::default().bg(segment.bg.unwrap_or(status_bg)).fg(segment.fg.unwrap_or(status_fg))
    };
    for x in bar_x..area.width {
        frame.buffer_mut()[(x, status_y)].set_symbol(" ").set_style(base);
    }
    let active_style = Style::default()
        .bg(chrome.status_active_bg)
        .fg(chrome.status_active_fg)
        .add_modifier(Modifier::BOLD);
    let mut x: u16 = bar_x;
    let mut hits = Vec::new();
    let put = |frame: &mut Frame, x: &mut u16, text: &str, style: Style| -> (u16, u16) {
        let start = *x;
        let width = text.width().min(area.width.saturating_sub(*x) as usize) as u16;
        if width > 0 {
            frame.buffer_mut().set_stringn(*x, status_y, text, width as usize, style);
            *x += width;
        }
        (start, width)
    };

    let segment_bg = |segment: &crate::app::StatusSegmentView| segment.bg.unwrap_or(status_bg);
    // Segment lists are bounded (eight per side), so lookahead scans stay
    // cheap and the draw path allocates nothing.
    let left_separator = app.config.status_bar.left_separator.as_deref();
    for (index, segment) in left_segments.iter().enumerate() {
        if segment.text.is_empty() {
            continue;
        }
        put(frame, &mut x, &segment.text, segment_style(segment));
        if let Some(separator) = left_separator {
            // Powerline transition: the separator's foreground takes this
            // segment's background and its background the next segment's
            // (or the bar's own, after the last segment).
            let next_bg = left_segments[index + 1..]
                .iter()
                .find(|next| !next.text.is_empty())
                .map(segment_bg)
                .unwrap_or(status_bg);
            put(frame, &mut x, separator, Style::default().fg(segment_bg(segment)).bg(next_bg));
        }
    }
    if app.config.status_bar.show_screens
        && let Some(ws) = app.tree.active_workspace().cloned()
    {
        put(frame, &mut x, " screens ", base.fg(chrome.status_dim_fg));
        let screen_caps = app.config.status_bar.screens_style.caps();
        for (i, screen) in ws.screens.iter().enumerate() {
            let active = i == ws.active_screen;
            let label = format!(" {} ", truncate(&screen.display_name(i), 20));
            let chip_start = x;
            // Caps wrap only the active chip: inactive screens share the
            // bar background, so caps there would be invisible anyway.
            if let (Some((cap_left, _)), true) = (screen_caps, active) {
                put(
                    frame,
                    &mut x,
                    cap_left,
                    Style::default().fg(chrome.status_active_bg).bg(status_bg),
                );
            }
            put(frame, &mut x, &label, if active { active_style } else { base });
            if let (Some((_, cap_right)), true) = (screen_caps, active) {
                put(
                    frame,
                    &mut x,
                    cap_right,
                    Style::default().fg(chrome.status_active_bg).bg(status_bg),
                );
            }
            let chip_width = x.saturating_sub(chip_start);
            if chip_width > 0 {
                hits.push((
                    Rect { x: chip_start, y: status_y, width: chip_width, height: 1 },
                    Hit::ScreenEntry { index: i, id: screen.id },
                ));
            }
        }
        let (start, width) = put(
            frame,
            &mut x,
            &app.config.status_bar.screens_plus.label,
            base.fg(chrome.status_dim_fg),
        );
        if width > 0 {
            hits.push((Rect { x: start, y: status_y, width, height: 1 }, Hit::NewScreen));
        }
    }
    // Session label / status message, right-aligned. Prefix help renders
    // over the pane border above this row.
    let available_label_width = area.width.saturating_sub(x) as usize;
    let copy_label = status_copy_label();
    let copy_width = copy_label.width();
    let show_copy =
        app.status_message.is_some() && available_label_width > copy_width.saturating_add(3);
    let status_text = app.status_message.as_deref().map(|message| {
        let reserved = if show_copy { copy_width.saturating_add(3) } else { 2 };
        status_display_text(message, available_label_width.saturating_sub(reserved))
    });
    if status_text.is_none() {
        app.hide_status_message();
    }
    let label =
        status_text
            .as_ref()
            .map(|message| {
                if show_copy { format!(" {message} {copy_label} ") } else { format!(" {message} ") }
            })
            .unwrap_or_else(|| {
                if app.config.status_bar.show_session {
                    format!(
                        "[{}] ",
                        truncate(&app.session_label, available_label_width.saturating_sub(3))
                    )
                } else {
                    String::new()
                }
            });
    let label_w = label.width().min(area.width as usize) as u16;
    // Right-aligned custom segments sit left of the label; draw them and
    // shrink the viewport track accordingly.
    let mut right_x = area.width.saturating_sub(label_w);
    let right_separator = app.config.status_bar.right_separator.as_deref();
    // Empty texts are normal before a command's first result; later
    // segments still draw.
    for index in (0..right_segments.len()).rev() {
        let segment = &right_segments[index];
        if segment.text.is_empty() {
            continue;
        }
        let width = (segment.text.width() as u16).min(right_x.saturating_sub(x));
        if width == 0 {
            break;
        }
        right_x = right_x.saturating_sub(width);
        frame.buffer_mut().set_stringn(
            right_x,
            status_y,
            &segment.text,
            width as usize,
            segment_style(segment),
        );
        if let Some(separator) = right_separator {
            let separator_width = (separator.width() as u16).min(right_x.saturating_sub(x));
            if separator_width == 0 {
                break;
            }
            // Mirrored powerline transition: the separator sits left of its
            // segment, foreground from the segment, background from the
            // next segment to the left (or the bar itself).
            let left_bg = right_segments[..index]
                .iter()
                .rev()
                .find(|previous| !previous.text.is_empty())
                .map(segment_bg)
                .unwrap_or(status_bg);
            right_x = right_x.saturating_sub(separator_width);
            frame.buffer_mut().set_stringn(
                right_x,
                status_y,
                separator,
                separator_width as usize,
                Style::default().fg(segment_bg(segment)).bg(left_bg),
            );
        }
    }
    let track_end = right_x;
    let track_start = x.saturating_add(1);
    let track_width = track_end.saturating_sub(track_start.saturating_add(1));
    if let Some((content_width, viewport_width, offset)) = app.horizontal_scrollbar_state()
        && track_width > 0
    {
        let track = Rect { x: track_start, y: status_y, width: track_width, height: 1 };
        let track_style = base.fg(chrome.status_dim_fg);
        for cell_x in track.x..track.x + track.width {
            frame.buffer_mut()[(cell_x, status_y)].set_symbol("─").set_style(track_style);
        }
        let (thumb_x, thumb_width) =
            horizontal_thumb_geometry(content_width, viewport_width, offset, track.width);
        let thumb_style = base.fg(chrome.scrollbar_thumb_active_fg);
        for cell_x in track.x + thumb_x..track.x + thumb_x + thumb_width {
            frame.buffer_mut()[(cell_x, status_y)].set_symbol("━").set_style(thumb_style);
        }
        hits.push((track, Hit::HorizontalScrollbar { track }));
    }
    app.hits.extend(hits);

    if x.saturating_add(label_w) <= area.width {
        let label_x = area.width - label_w;
        frame.buffer_mut().set_stringn(
            label_x,
            status_y,
            &label,
            label_w as usize,
            if app.status_message.is_some() {
                base.fg(Color::Red).add_modifier(Modifier::BOLD)
            } else {
                base.fg(chrome.status_dim_fg)
            },
        );
        if let Some(status_text) = status_text {
            let status_width = status_text.width() as u16;
            draw_interactive_status_message(
                app,
                frame,
                Rect { x: label_x.saturating_add(1), y: status_y, width: status_width, height: 1 },
                status_text,
                base.fg(Color::Red).add_modifier(Modifier::BOLD),
            );
            if show_copy {
                draw_status_copy_control(
                    app,
                    frame,
                    Rect {
                        x: label_x.saturating_add(status_width).saturating_add(2),
                        y: status_y,
                        width: copy_width as u16,
                        height: 1,
                    },
                    &copy_label,
                    base.fg(Color::Red).add_modifier(Modifier::BOLD),
                );
            }
        }
    } else {
        app.hide_status_message();
    }
    if app.prefix_armed {
        draw_prefix_help_bar(app, frame, bar_x, status_y.saturating_sub(1));
    }
}

fn draw_prefix_help_bar(app: &App, frame: &mut Frame, bar_x: u16, y: u16) {
    let area = frame.area();
    let chrome = app.chrome;
    let base = Style::default()
        .bg(chrome.status_active_bg)
        .fg(chrome.status_active_fg)
        .add_modifier(Modifier::BOLD);
    let keycap = base.fg(app.config.theme.border_active).add_modifier(Modifier::BOLD);
    for x in bar_x..area.width {
        frame.buffer_mut()[(x, y)].set_symbol(" ").set_style(base);
    }

    let mut x = bar_x;
    let prefix = app
        .config
        .keys
        .prefix
        .display_label()
        .map(|label| format!(" {label} "))
        .unwrap_or_default();
    let prefix_width = prefix.width() as u16;
    if prefix_width > 0 && x.saturating_add(prefix_width) <= area.width {
        frame.buffer_mut().set_stringn(x, y, &prefix, prefix_width as usize, keycap);
        x += prefix_width;
    }
    if x < area.width {
        frame.buffer_mut().set_stringn(
            x,
            y,
            " › ",
            area.width.saturating_sub(x).min(3) as usize,
            base.fg(app.config.theme.border_active),
        );
        x = x.saturating_add(3);
    }

    let actions = [
        Action::SendPrefix,
        Action::ShowShortcuts,
        Action::ClosePane,
        Action::CloseTab,
        Action::PrevWorkspace,
        Action::NextWorkspace,
        Action::NewWorkspace,
        Action::CloseWorkspace,
        Action::ZoomPane,
        Action::FocusSidebar,
        Action::Detach,
    ];
    for action in actions {
        if !app.action_available(action) {
            continue;
        }
        let Some(key) = app.config.keys.prefixed_key_label(action) else { continue };
        let key = format!(" {key} ");
        let label = format!(" {} ", catalog().action_label(action));
        let key_width = key.width() as u16;
        let label_width = label.width() as u16;
        if x.saturating_add(key_width).saturating_add(label_width) > area.width {
            break;
        }
        frame.buffer_mut().set_stringn(x, y, &key, key_width as usize, keycap);
        x += key_width;
        frame.buffer_mut().set_stringn(x, y, &label, label_width as usize, base);
        x += label_width;
    }
}

const TRUNCATE_BYTES_PER_CELL: usize = 128;
const TRUNCATE_MAX_OUTPUT_BYTES: usize = 4_096;

pub(crate) fn truncate(s: &str, max: usize) -> String {
    if max == 0 {
        return String::new();
    }

    // Display width alone does not bound combining marks or other zero-width
    // scalars. Limit the UTF-8 prefix inspected and copied on every paint.
    let output_byte_budget = max
        .saturating_mul(TRUNCATE_BYTES_PER_CELL)
        .clamp(TRUNCATE_BYTES_PER_CELL, TRUNCATE_MAX_OUTPUT_BYTES);
    let mut prefix_end = s.len().min(output_byte_budget);
    while !s.is_char_boundary(prefix_end) {
        prefix_end -= 1;
    }
    let byte_truncated = prefix_end < s.len();
    let bounded_prefix = &s[..prefix_end];

    if !byte_truncated && bounded_prefix.width() <= max {
        return bounded_prefix.to_string();
    }

    // A byte cutoff can land inside one extended grapheme. Conservatively
    // discard that final grapheme so a pathological first grapheme becomes
    // just an ellipsis instead of leaking a partial combining sequence.
    let complete_prefix = if byte_truncated {
        let last_grapheme_start =
            bounded_prefix.grapheme_indices(true).next_back().map(|(index, _)| index).unwrap_or(0);
        &bounded_prefix[..last_grapheme_start]
    } else {
        bounded_prefix
    };
    let content_width = max - 1;
    let content_byte_budget = output_byte_budget.saturating_sub('…'.len_utf8());
    let mut width: usize = 0;
    let mut out = String::with_capacity(
        complete_prefix.len().min(content_byte_budget).saturating_add('…'.len_utf8()),
    );
    for grapheme in complete_prefix.graphemes(true) {
        let grapheme_width = grapheme.width();
        if width.saturating_add(grapheme_width) > content_width
            || out.len().saturating_add(grapheme.len()) > content_byte_budget
        {
            break;
        }
        out.push_str(grapheme);
        width += grapheme_width;
    }
    out.push('…');
    out
}

pub(crate) fn middle_truncate(input: &str, max_chars: usize) -> String {
    let chars = input.chars().collect::<Vec<_>>();
    if chars.len() <= max_chars {
        return input.to_string();
    }
    if max_chars == 0 {
        return String::new();
    }
    if max_chars <= 3 {
        return ".".repeat(max_chars);
    }
    let keep = max_chars - 3;
    let front = keep.div_ceil(2);
    let back = keep / 2;
    let mut output = chars[..front].iter().collect::<String>();
    output.push_str("...");
    output.extend(&chars[chars.len() - back..]);
    output
}

#[cfg(test)]
mod tests {
    use ratatui::buffer::Buffer;
    use ratatui::layout::Rect;
    use ratatui::style::Style;

    use super::{
        ReusableRowBuffer, copy_buffer_row_cropped, middle_truncate, sanitize_render_buffer,
        truncate,
    };

    #[test]
    fn middle_truncates_for_narrow_columns() {
        assert_eq!(middle_truncate("abcdefghi", 7), "ab...hi");
        assert_eq!(middle_truncate("abcdefghi", 3), "...");
        assert_eq!(middle_truncate("abc", 3), "abc");
        assert_eq!(middle_truncate("abc", 0), "");
    }

    #[test]
    fn truncation_uses_terminal_cell_width_and_preserves_graphemes() {
        assert_eq!(truncate("復元失敗", 5), "復元…");
        assert_eq!(truncate("e\u{301}clair", 2), "e\u{301}…");
        assert_eq!(truncate("復元", 1), "…");
        assert_eq!(truncate("復元", 0), "");
    }

    #[test]
    fn truncation_bounds_pathological_zero_width_input() {
        let oversized_grapheme = format!("x{}", "\u{301}".repeat(10_000));
        assert_eq!(truncate(&oversized_grapheme, 20), "…");

        let invisible = "\u{200b}".repeat(10_000);
        assert_eq!(truncate(&invisible, 0), "");
        assert!(truncate(&invisible, 4).len() <= 4_096);
    }

    #[test]
    fn render_buffer_rejects_control_bytes_from_every_ui_source() {
        let mut buffer = Buffer::empty(Rect::new(0, 0, 3, 1));
        buffer[(0, 0)].set_symbol("\u{1b}");
        buffer[(1, 0)].set_symbol("bad\ncell");
        buffer[(2, 0)].set_symbol("ok");

        sanitize_render_buffer(&mut buffer);

        assert_eq!(buffer[(0, 0)].symbol(), " ");
        assert_eq!(buffer[(1, 0)].symbol(), " ");
        assert_eq!(buffer[(2, 0)].symbol(), "ok");
    }

    #[test]
    fn cropped_buffer_rows_blank_partial_wide_glyphs_at_both_edges() {
        let mut source = Buffer::empty(Rect::new(0, 0, 5, 1));
        source.set_string(0, 0, "a界b", Style::default());
        assert_eq!(source[(1, 0)].symbol(), "界");

        let draw_crop = |source_x| {
            let mut target = Buffer::empty(Rect::new(0, 0, 2, 1));
            copy_buffer_row_cropped(
                &source,
                0,
                source_x,
                &mut target,
                cmux_tui_core::Rect { x: 0, y: 0, width: 2, height: 1 },
            );
            target
        };

        let clipped_lead = draw_crop(0);
        assert_eq!(clipped_lead[(0, 0)].symbol(), "a");
        assert_eq!(clipped_lead[(1, 0)].symbol(), " ");

        let complete = draw_crop(1);
        assert_eq!(complete[(0, 0)].symbol(), "界");
        assert_eq!(complete[(1, 0)].symbol(), " ");

        let clipped_tail = draw_crop(2);
        assert_eq!(clipped_tail[(0, 0)].symbol(), " ");
        assert_eq!(clipped_tail[(1, 0)].symbol(), "b");
    }

    #[test]
    fn reusable_row_buffer_keeps_its_allocation_for_smaller_rows() {
        let mut scratch = ReusableRowBuffer::default();
        let first = scratch.take(512);
        let pointer = first.content.as_ptr();
        let capacity = first.content.capacity();
        scratch.put(first);

        let second = scratch.take(256);
        assert_eq!(second.area.width, 256);
        assert_eq!(second.content.as_ptr(), pointer);
        assert_eq!(second.content.capacity(), capacity);
    }
}
