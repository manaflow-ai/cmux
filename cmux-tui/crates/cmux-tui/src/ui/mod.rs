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
use ratatui::layout::Position;
use ratatui::style::{Color, Modifier, Style};
use unicode_width::UnicodeWidthStr;

use crate::app::{App, Hit};
use crate::config::Action;
use crate::localization::catalog;
use crate::machine::DurableNoticeLevel;

pub(crate) use scrollbar::{
    ScrollbarState, ScrollbarStyle, horizontal_offset_at, horizontal_thumb_geometry,
    thumb_geometry, viewport_drag_offset, viewport_jump_offset, viewport_thumb_geometry,
};

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
    let area = frame.area();
    if area.height == 0 {
        return;
    }
    if app.shortcut_help.is_some() && (area.width < 24 || area.height < 7) {
        app.shortcut_help = None;
    }

    app.hits.clear();
    if app.machine_sidebar_width > 0 {
        sidebar::draw_machines(app, frame);
    }
    let sidebar_input_cursor = (app.sidebar_width > 0).then(|| sidebar::draw(app, frame)).flatten();

    let pane_cursors = pane::draw_all(app, frame);
    if app.is_surface_only() {
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

fn draw_durable_notice_banner(app: &mut App, frame: &mut Frame) {
    let area = frame.area();
    if area.width == 0 || area.height == 0 {
        return;
    }
    let Some(notice) = app.durable_notice().cloned() else {
        return;
    };
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
fn draw_surface_status(app: &App, frame: &mut Frame) {
    let Some(message) = app.status_message.as_deref() else { return };
    let area = frame.area();
    if area.width == 0 {
        return;
    }
    frame.buffer_mut().set_stringn(
        0,
        area.height - 1,
        message,
        area.width as usize,
        Style::default().fg(Color::Red).add_modifier(Modifier::BOLD),
    );
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
    let base = Style::default().bg(chrome.status_bg).fg(chrome.status_fg);
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
        let width = (text.chars().count() as u16).min(area.width.saturating_sub(*x));
        if width > 0 {
            frame.buffer_mut().set_stringn(*x, status_y, text, width as usize, style);
            *x += width;
        }
        (start, width)
    };

    let Some(ws) = app.tree.active_workspace().cloned() else {
        if app.prefix_armed {
            draw_prefix_help_bar(app, frame, bar_x, status_y.saturating_sub(1));
        }
        return;
    };
    put(frame, &mut x, " screens ", base.fg(chrome.status_dim_fg));
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
    let (start, width) = put(frame, &mut x, " + ", base.fg(chrome.status_dim_fg));
    if width > 0 {
        hits.push((Rect { x: start, y: status_y, width, height: 1 }, Hit::NewScreen));
    }
    // Session label / status message, right-aligned. Prefix help renders
    // over the pane border above this row.
    let label = app
        .status_message
        .as_ref()
        .map(|msg| format!(" {} ", truncate(msg, area.width.saturating_sub(x) as usize)))
        .unwrap_or_else(|| format!("[{}] ", app.session_label));
    let label_w = label.chars().count() as u16;
    let track_end = area.width.saturating_sub(label_w);
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

    if x + label_w < area.width {
        frame.buffer_mut().set_stringn(
            area.width - label_w,
            status_y,
            &label,
            label_w as usize,
            if app.status_message.is_some() {
                base.fg(Color::Red).add_modifier(Modifier::BOLD)
            } else {
                base.fg(chrome.status_dim_fg)
            },
        );
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

pub(crate) fn truncate(s: &str, max: usize) -> String {
    if s.chars().count() <= max {
        s.to_string()
    } else {
        let mut out: String = s.chars().take(max.saturating_sub(1)).collect();
        out.push('…');
        out
    }
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

    use super::{copy_buffer_row_cropped, middle_truncate, sanitize_render_buffer};

    #[test]
    fn middle_truncates_for_narrow_columns() {
        assert_eq!(middle_truncate("abcdefghi", 7), "ab...hi");
        assert_eq!(middle_truncate("abcdefghi", 3), "...");
        assert_eq!(middle_truncate("abc", 3), "abc");
        assert_eq!(middle_truncate("abc", 0), "");
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
}
