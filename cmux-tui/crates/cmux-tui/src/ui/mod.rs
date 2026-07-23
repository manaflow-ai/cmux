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
use ratatui::layout::Position;
use ratatui::style::{Color, Modifier, Style};
use unicode_width::UnicodeWidthStr;

use crate::app::{App, Hit};
use crate::config::Action;
use crate::localization::catalog;

pub(crate) use scrollbar::thumb_geometry;

pub fn draw(app: &mut App, frame: &mut Frame) {
    let area = frame.area();
    if area.height == 0 {
        return;
    }

    app.hits.clear();
    if app.machine_sidebar_width > 0 {
        sidebar::draw_machines(app, frame);
    }
    let sidebar_input_cursor = (app.sidebar_width > 0).then(|| sidebar::draw(app, frame)).flatten();

    let pane_cursors = pane::draw_all(app, frame);
    if !app.is_surface_only() {
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
    if app.prefix_armed {
        draw_prefix_help_bar(app, frame, bar_x, status_y);
        return;
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

    let Some(ws) = app.tree.active_workspace().cloned() else { return };
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
    app.hits.extend(hits);

    // Session label / status message, right-aligned (the prefix indicator
    // replaces it).
    let label = app
        .status_message
        .as_ref()
        .map(|msg| format!(" {} ", truncate(msg, area.width.saturating_sub(x) as usize)))
        .unwrap_or_else(|| format!("[{}] ", app.session_label));
    let label_w = label.chars().count() as u16;
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
}

fn draw_prefix_help_bar(app: &App, frame: &mut Frame, bar_x: u16, y: u16) {
    let area = frame.area();
    let chrome = app.chrome;
    let base = Style::default()
        .bg(chrome.status_active_bg)
        .fg(chrome.status_active_fg)
        .add_modifier(Modifier::BOLD);
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
        frame.buffer_mut().set_stringn(
            x,
            y,
            &prefix,
            prefix_width as usize,
            base.fg(app.config.theme.border_active),
        );
        x += prefix_width;
    }

    let actions = [
        Action::ShowShortcuts,
        Action::NewTab,
        Action::SplitRight,
        Action::SplitDown,
        Action::ZoomPane,
        Action::ToggleSidebar,
        Action::ToggleSidebarCompact,
        Action::ClosePane,
        Action::Detach,
    ];
    for action in actions {
        let Some(key) = app.config.keys.prefixed_key_label(action) else { continue };
        let hint = format!(" {key} {} ", catalog().action_label(action));
        let width = hint.width() as u16;
        if x.saturating_add(width) > area.width {
            break;
        }
        frame.buffer_mut().set_stringn(x, y, &hint, width as usize, base);
        x += width;
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
    use super::middle_truncate;

    #[test]
    fn middle_truncates_for_narrow_columns() {
        assert_eq!(middle_truncate("abcdefghi", 7), "ab...hi");
        assert_eq!(middle_truncate("abcdefghi", 3), "...");
        assert_eq!(middle_truncate("abc", 3), "abc");
        assert_eq!(middle_truncate("abc", 0), "");
    }
}
