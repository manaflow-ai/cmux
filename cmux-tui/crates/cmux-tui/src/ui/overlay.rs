//! Overlays drawn on top of the frame: the right-click context menu and
//! the centered rename dialog. Menu items get a one-cell padding column
//! each side inside a border, separator rows divide related groups, and the
//! selected row (arrow keys or mouse hover) highlights across the inner row.

use cmux_tui_core::Rect;
use ratatui::Frame;
use ratatui::buffer::{Buffer, CellWidth};
use ratatui::layout::Position;
use ratatui::style::{Modifier, Style};
use unicode_segmentation::UnicodeSegmentation;

use crate::app::{App, ContextMenu, MenuItem};
use crate::localization::catalog;

use super::{ScrollbarState, ScrollbarStyle};

#[derive(Clone, Copy)]
struct ConnectionPromptStyles {
    base: Style,
    title: Style,
    input: Style,
    button_accent: ratatui::style::Color,
    button_hover: ratatui::style::Color,
}

/// Trusted approval dialog for a browser pairing request.
pub fn draw_pairing_dialog(app: &mut App, frame: &mut Frame) {
    let screen = frame.area();
    let width = 48.min(screen.width.saturating_sub(2)).max(24);
    let height = 10;
    if screen.width < width || screen.height < height {
        return;
    }
    let x = (screen.width - width) / 2;
    let y = (screen.height - height) / 2;
    let Some(dialog) = app.pairing_dialog.as_mut() else { return };
    let copy = &catalog().pairing;
    dialog.rect = Rect { x, y, width, height };

    let chrome = app.chrome;
    let base = Style::default().bg(chrome.prompt_bg).fg(chrome.prompt_fg);
    let border = base.fg(chrome.prompt_border);
    let title = base.fg(chrome.prompt_title_fg).add_modifier(Modifier::BOLD);
    let code = base.fg(chrome.prompt_button_accent_fg).add_modifier(Modifier::BOLD);
    let buf = frame.buffer_mut();
    for dy in 0..height {
        for dx in 0..width {
            set_cell(buf, x + dx, y + dy, " ", base);
        }
    }
    draw_border(buf, dialog.rect, border);
    buf.set_stringn(x + 2, y + 1, copy.title, (width - 4) as usize, title);
    buf.set_stringn(x + 2, y + 3, copy.confirm, (width - 4) as usize, base);
    let code_x = x + width.saturating_sub(label_width(&dialog.challenge.code)) / 2;
    buf.set_stringn(code_x, y + 5, &dialog.challenge.code, (width - 4) as usize, code);
    let peer = format!("{} {}", copy.peer_prefix, dialog.challenge.peer);
    buf.set_stringn(x + 2, y + 6, &peer, (width - 4) as usize, base);

    let deny_label = copy.deny;
    let approve_label = copy.approve;
    let deny_w = label_width(deny_label);
    let approve_w = label_width(approve_label);
    let approve_x = x + width - 2 - approve_w;
    let deny_x = approve_x.saturating_sub(deny_w + 2);
    let button_y = y + 8;
    dialog.approve = Rect { x: approve_x, y: button_y, width: approve_w, height: 1 };
    dialog.deny = Rect { x: deny_x, y: button_y, width: deny_w, height: 1 };
    let button_style = |rect: Rect, accent: bool| {
        let hovered = app.hover.is_some_and(|(hx, hy)| rect.contains(hx, hy));
        let mut style = if accent { base.fg(chrome.prompt_button_accent_fg) } else { base };
        if hovered {
            style = style.add_modifier(Modifier::BOLD).bg(chrome.prompt_button_hover_bg);
        }
        style
    };
    frame.buffer_mut().set_stringn(
        deny_x,
        button_y,
        deny_label,
        deny_w as usize,
        button_style(dialog.deny, false),
    );
    frame.buffer_mut().set_stringn(
        approve_x,
        button_y,
        approve_label,
        approve_w as usize,
        button_style(dialog.approve, true),
    );
}

/// Centered prompt dialog: bordered box with title, input row, and
/// clickable shortcut buttons. Writes the dialog, input, and button rects
/// back into the prompt so mouse handling matches the drawn geometry.
pub fn draw_prompt(app: &mut App, frame: &mut Frame) {
    let screen = frame.area();
    let hover = app.hover;
    let shake = app.shake_frames;
    let connection = app.connection_transaction.clone();
    if app.shake_frames > 0 {
        app.shake_frames -= 1;
    }

    let width: u16 =
        if connection.is_some() { 64 } else { 42 }.min(screen.width.saturating_sub(2)).max(20);
    let height: u16 = if connection.as_ref().is_some_and(|transaction| {
        matches!(transaction.phase, crate::app::ConnectionDialogPhase::Failed(_))
    }) {
        13
    } else {
        9
    };
    if screen.width < width || screen.height < height {
        return;
    }
    let base_x = (screen.width - width) / 2;
    let x = if shake <= 1 {
        base_x
    } else {
        let offset = if shake.is_multiple_of(2) { 1 } else { -1 };
        (base_x as i32 + offset).clamp(0, screen.width.saturating_sub(width) as i32) as u16
    };
    let y = (screen.height - height) / 2;
    let Some(prompt) = app.prompt.as_mut() else { return };
    prompt.rect = Rect { x, y, width, height };

    let chrome = app.chrome;
    let base = Style::default().bg(chrome.prompt_bg).fg(chrome.prompt_fg);
    let border = base.fg(chrome.prompt_border);
    let title_style = base.fg(chrome.prompt_title_fg).add_modifier(Modifier::BOLD);
    let input_style = Style::default().bg(chrome.prompt_input_bg).fg(chrome.prompt_input_fg);
    let buf = frame.buffer_mut();

    for dy in 0..height {
        for dx in 0..width {
            set_cell(buf, x + dx, y + dy, " ", base);
        }
    }
    draw_border(buf, prompt.rect, border);
    if let Some(transaction) = connection
        && !matches!(transaction.phase, crate::app::ConnectionDialogPhase::Editing)
    {
        draw_connection_prompt(
            frame,
            prompt,
            &transaction,
            hover,
            ConnectionPromptStyles {
                base,
                title: title_style,
                input: input_style,
                button_accent: chrome.prompt_button_accent_fg,
                button_hover: chrome.prompt_button_hover_bg,
            },
        );
        return;
    }
    buf.set_stringn(x + 2, y + 2, prompt.label.as_str(), (width - 4) as usize, title_style);

    // Input row: visible slice around the cursor.
    let input_w = width.saturating_sub(4);
    prompt.input_rect = Rect { x: x + 2, y: y + 4, width: input_w, height: 1 };
    let (shown, cursor_col) = prompt.input.visible_text_and_cursor(input_w as usize);
    for dx in 0..input_w {
        set_cell(buf, x + 2 + dx, y + 4, " ", input_style);
    }
    buf.set_stringn(x + 2, y + 4, &shown, input_w as usize, input_style);
    let cursor_x = x + 2 + (cursor_col as u16).min(input_w);
    frame.set_cursor_position(Position::new(cursor_x, y + 4));

    // Buttons, right-aligned: [ Clear ^C ]  [ Cancel esc ]  [ OK ⏎ ].
    let clear_label = "[ Clear ^C ]";
    let cancel_label = "[ Cancel esc ]";
    let ok_label = "[ OK ⏎ ]";
    let clear_w = label_width(clear_label);
    let cancel_w = label_width(cancel_label);
    let ok_w = label_width(ok_label);
    let ok_x = x + width - 2 - ok_w;
    let cancel_x = ok_x.saturating_sub(cancel_w + 2);
    let clear_fits = clear_w + 2 <= cancel_x.saturating_sub(x + 2);
    let clear_x = cancel_x.saturating_sub(clear_w + 2);
    let button_y = y + 6;
    prompt.ok = Rect { x: ok_x, y: button_y, width: ok_w, height: 1 };
    prompt.cancel = Rect { x: cancel_x, y: button_y, width: cancel_w, height: 1 };
    prompt.clear = if clear_fits {
        Rect { x: clear_x, y: button_y, width: clear_w, height: 1 }
    } else {
        Rect::default()
    };
    let button_style = |rect: Rect, accent: bool| {
        let hovered = hover.is_some_and(|(hx, hy)| rect.contains(hx, hy));
        let mut s = if accent { base.fg(chrome.prompt_button_accent_fg) } else { base };
        if hovered {
            s = s.add_modifier(Modifier::BOLD).bg(chrome.prompt_button_hover_bg);
        }
        s
    };
    let buf = frame.buffer_mut();
    if clear_fits {
        buf.set_stringn(
            clear_x,
            button_y,
            clear_label,
            clear_w as usize,
            button_style(prompt.clear, false),
        );
    }
    buf.set_stringn(
        cancel_x,
        button_y,
        cancel_label,
        cancel_w as usize,
        button_style(prompt.cancel, false),
    );
    buf.set_stringn(ok_x, button_y, ok_label, ok_w as usize, button_style(prompt.ok, true));
}

fn draw_connection_prompt(
    frame: &mut Frame,
    prompt: &mut crate::app::Prompt,
    transaction: &crate::app::ConnectionTransaction,
    hover: Option<(u16, u16)>,
    styles: ConnectionPromptStyles,
) {
    use crate::app::ConnectionDialogPhase;

    let Rect { x, y, width, height } = prompt.rect;
    let copy = &catalog().sidebar;
    let (title, error) = match &transaction.phase {
        ConnectionDialogPhase::Editing => return,
        ConnectionDialogPhase::Connecting => {
            (copy.connecting_to_message(&transaction.target), None)
        }
        ConnectionDialogPhase::Starting => (copy.starting_on_message(&transaction.target), None),
        ConnectionDialogPhase::Failed(error) => {
            (copy.failed_to_connect_message(&transaction.target), Some(error.as_str()))
        }
    };
    frame.buffer_mut().set_stringn(x + 2, y + 2, &title, (width - 4) as usize, styles.title);

    let input_w = width.saturating_sub(4);
    prompt.input_rect = Rect::default();
    for dx in 0..input_w {
        set_cell(frame.buffer_mut(), x + 2 + dx, y + 4, " ", styles.input);
    }
    frame.buffer_mut().set_stringn(
        x + 2,
        y + 4,
        &transaction.target,
        input_w as usize,
        styles.input,
    );

    if let Some(error) = error {
        for (index, line) in
            wrapped_message_lines(error, (width - 4) as usize, 3).into_iter().enumerate()
        {
            frame.buffer_mut().set_stringn(
                x + 2,
                y + 6 + index as u16,
                &line,
                (width - 4) as usize,
                styles.base,
            );
        }
    }

    let close_label = format!("[ {} esc ]", copy.close_dialog);
    let retry_label = format!("[ {} ⏎ ]", copy.retry_connection);
    let copy_label = format!("[ {} ^C ]", catalog().menu.copy_message);
    let close_w = label_width(&close_label);
    let retry_w = label_width(&retry_label);
    let copy_w = label_width(&copy_label);
    let button_y = y + height.saturating_sub(3);
    let retry_x = x + width - 2 - retry_w;
    let close_x = retry_x.saturating_sub(close_w + 2);
    let copy_x = close_x.saturating_sub(copy_w + 2);
    let failed = error.is_some();
    prompt.ok = if failed {
        Rect { x: retry_x, y: button_y, width: retry_w, height: 1 }
    } else {
        Rect::default()
    };
    prompt.clear = if failed && copy_x >= x + 2 {
        Rect { x: copy_x, y: button_y, width: copy_w, height: 1 }
    } else {
        Rect::default()
    };
    prompt.cancel = Rect {
        x: if failed { close_x } else { x + width - 2 - close_w },
        y: button_y,
        width: close_w,
        height: 1,
    };
    let button_style = |rect: Rect, accent: bool| {
        let hovered = hover.is_some_and(|(hx, hy)| rect.contains(hx, hy));
        let mut style = if accent { styles.base.fg(styles.button_accent) } else { styles.base };
        if hovered {
            style = style.add_modifier(Modifier::BOLD).bg(styles.button_hover);
        }
        style
    };
    if prompt.clear.width > 0 {
        frame.buffer_mut().set_stringn(
            prompt.clear.x,
            button_y,
            &copy_label,
            copy_w as usize,
            button_style(prompt.clear, false),
        );
    }
    frame.buffer_mut().set_stringn(
        prompt.cancel.x,
        button_y,
        &close_label,
        close_w as usize,
        button_style(prompt.cancel, false),
    );
    if prompt.ok.width > 0 {
        frame.buffer_mut().set_stringn(
            prompt.ok.x,
            button_y,
            &retry_label,
            retry_w as usize,
            button_style(prompt.ok, true),
        );
    }
}

fn wrapped_message_lines(message: &str, width: usize, limit: usize) -> Vec<String> {
    if width == 0 || limit == 0 {
        return Vec::new();
    }
    let sanitized = message
        .chars()
        .map(|character| if character.is_control() { ' ' } else { character })
        .collect::<String>();
    let mut lines = Vec::new();
    let mut remaining = sanitized.as_str();
    while !remaining.is_empty() && lines.len() < limit {
        let end = grapheme_prefix_end(remaining, width);
        if end == 0 {
            break;
        }
        let split = if end < remaining.len() {
            remaining[..end]
                .grapheme_indices(true)
                .rev()
                .find(|(_, grapheme)| grapheme_is_whitespace(grapheme))
                .map(|(index, _)| index)
                .filter(|index| *index > 0)
                .unwrap_or(end)
        } else {
            end
        };
        lines.push(trim_grapheme_whitespace(&remaining[..split]).to_string());
        remaining = trim_grapheme_whitespace_start(&remaining[split..]);
    }
    if !remaining.is_empty()
        && let Some(last) = lines.last_mut()
    {
        while usize::from(format!("{last}…").cell_width()) > width && !last.is_empty() {
            let end = last.grapheme_indices(true).next_back().map_or(0, |(index, _)| index);
            last.truncate(end);
        }
        last.push('…');
    }
    lines
}

pub fn draw_menu(app: &mut App, frame: &mut Frame) {
    let screen = frame.area();
    let chrome = app.chrome;
    let hover = app.hover;
    let Some(menu) = app.menu.as_mut() else { return };
    let base = Style::default().bg(chrome.menu_bg).fg(chrome.menu_fg);
    let border = base.fg(chrome.menu_border);
    let selected = Style::default()
        .bg(chrome.menu_selected_bg)
        .fg(chrome.menu_selected_fg)
        .add_modifier(Modifier::BOLD);
    for depth in 0..menu.levels.len() {
        menu.levels[depth].fit_to_rows(screen.height.saturating_sub(2) as usize);
        let width = menu.levels[depth].rect.width.min(screen.width);
        let height = menu.levels[depth].rect.height.min(screen.height);
        let (desired_x, desired_y) = if depth == 0 {
            (menu.levels[depth].rect.x, menu.levels[depth].rect.y)
        } else {
            let parent = &menu.levels[depth - 1];
            let right_x = parent.rect.x.saturating_add(parent.rect.width.saturating_sub(1));
            let x = if right_x.saturating_add(width) <= screen.x.saturating_add(screen.width) {
                right_x
            } else {
                parent.rect.x.saturating_sub(width.saturating_sub(1))
            };
            (
                x,
                parent
                    .rect
                    .y
                    .saturating_add(1)
                    .saturating_add(parent.selected.saturating_sub(parent.scroll_offset) as u16),
            )
        };
        let x = desired_x.min(screen.width.saturating_sub(width));
        let y = desired_y.min(screen.height.saturating_sub(height));
        menu.levels[depth].rect = Rect { x, y, width, height };
        if width < 2 || height < 2 {
            continue;
        }

        let scrollbar_dragging = menu.scrollbar_dragging(depth);
        let level = &menu.levels[depth];
        let scrollbar = level.scrollbar();
        let scrollbar_track = scrollbar.map(|(track, _)| track);
        let buf = frame.buffer_mut();
        for dy in 0..height {
            for dx in 0..width {
                set_cell(buf, x + dx, y + dy, " ", base);
            }
        }
        draw_border(buf, level.rect, border);

        if depth == 0
            && let Some(search) = menu.search.as_mut()
        {
            let title_x = x + 2;
            let title_w = width.saturating_sub(4) as usize;
            let prefix = format!(" {} · ", search.label);
            let prefix_w = usize::from(prefix.cell_width()).min(title_w);
            let search_style = base.add_modifier(Modifier::BOLD);
            buf.set_stringn(title_x, y, &prefix, title_w, search_style);
            let value_x = title_x + prefix_w as u16;
            let value_w = title_w.saturating_sub(prefix_w);
            if search.input.as_str().is_empty() {
                let placeholder = format!("{} ", search.placeholder);
                buf.set_stringn(
                    value_x,
                    y,
                    &placeholder,
                    value_w,
                    base.add_modifier(Modifier::DIM),
                );
            } else if value_w > 0 {
                let (shown, _) = search.input.visible_text_and_cursor(value_w.saturating_sub(1));
                buf.set_stringn(value_x, y, &shown, value_w, search_style);
                let cursor_x = value_x + shown.cell_width().min(value_w.saturating_sub(1) as u16);
                buf.set_stringn(cursor_x, y, "▏", 1, search_style);
            }
        }

        let pad = ContextMenu::PAD;
        let inner_x = x + 1;
        let inner_y = y + 1;
        let inner_w = width.saturating_sub(2);
        let inner_h = height.saturating_sub(2);
        let scrollbar_width = u16::from(scrollbar_track.is_some());
        let row_content_w = inner_w.saturating_sub(scrollbar_width);
        for (i, item) in
            level.items.iter().enumerate().skip(level.scroll_offset).take(inner_h as usize)
        {
            let row_y = inner_y + (i - level.scroll_offset) as u16;
            if *item == MenuItem::Separator {
                set_cell(buf, x, row_y, "├", border);
                for dx in 0..row_content_w {
                    set_cell(buf, inner_x + dx, row_y, "─", border);
                }
                set_cell(buf, x + width - 1, row_y, "┤", border);
                continue;
            }
            if let Some(label) = item.label() {
                let style =
                    if level.selection_active && i == level.selected { selected } else { base };
                for dx in 0..row_content_w {
                    set_cell(buf, inner_x + dx, row_y, " ", style);
                }
                let shortcut_width =
                    item.shortcut().map(|shortcut| shortcut.cell_width() + 2).unwrap_or(0);
                let arrow_width = matches!(item, MenuItem::Submenu { .. }) as u16 * 2;
                buf.set_stringn(
                    inner_x + pad + 1,
                    row_y,
                    label,
                    row_content_w.saturating_sub(pad * 2 + arrow_width + shortcut_width) as usize,
                    style,
                );
                if let Some(shortcut) = item.shortcut() {
                    let shortcut_width =
                        shortcut.cell_width().min(row_content_w.saturating_sub(pad * 2));
                    if shortcut_width > 0 {
                        let shortcut_x = x + level
                            .rect
                            .width
                            .saturating_sub(pad + 1 + shortcut_width + scrollbar_width);
                        buf.set_stringn(
                            shortcut_x,
                            row_y,
                            shortcut,
                            shortcut_width as usize,
                            style,
                        );
                    }
                }
                if matches!(item, MenuItem::Submenu { .. }) && row_content_w > 2 {
                    buf.set_stringn(x + width - pad - 3 - scrollbar_width, row_y, " ›", 2, style);
                }
            }
        }
        if let Some((track, thumb)) = scrollbar {
            let state = if scrollbar_dragging {
                ScrollbarState::Expanded
            } else if hover.is_some_and(|(hx, hy)| track.contains(hx, hy)) {
                ScrollbarState::Highlighted
            } else {
                ScrollbarState::Idle
            };
            ScrollbarStyle::from_chrome(chrome).draw_thumb(buf, track, thumb, base, state);
        }
    }
}

pub fn draw_shortcut_help(app: &mut App, frame: &mut Frame) {
    let screen = frame.area();
    if app.shortcut_help.is_none() {
        return;
    }
    if screen.width < 24 || screen.height < 7 {
        app.shortcut_help = None;
        return;
    }
    let catalog = catalog();
    let Some(help) = app.shortcut_help.as_ref() else { return };
    let total_rows = help.rows.len();
    let close_text = format!("[{}]", catalog.shortcuts.close_button);
    let desired_width = help
        .rows
        .iter()
        .map(|(action, shortcuts)| {
            usize::from(app.action_display_label(*action).cell_width())
                + usize::from(shortcuts.cell_width())
                + 9
        })
        .max()
        .unwrap_or(44)
        .max(
            usize::from(catalog.shortcuts.title.cell_width())
                + usize::from(close_text.cell_width())
                + 8,
        );
    let width = (desired_width as u16).min(76).min(screen.width.saturating_sub(2)).max(24);
    let height = (total_rows as u16 + 4).min(screen.height.saturating_sub(2)).max(7);
    let x = (screen.width - width) / 2;
    let y = (screen.height - height) / 2;
    let visible_rows = height.saturating_sub(4) as usize;
    let chrome = app.chrome;
    let base = Style::default().bg(chrome.prompt_bg).fg(chrome.prompt_fg);
    let border = base.fg(chrome.prompt_border);
    let title = base.fg(chrome.prompt_title_fg).add_modifier(Modifier::BOLD);
    let shortcut_style = title;
    let rect = Rect { x, y, width, height };
    let Some(help) = app.shortcut_help.as_mut() else { return };
    help.rect = rect;
    help.visible_rows = visible_rows;
    let close_width = close_text.cell_width().min(width.saturating_sub(4));
    help.close_button = Rect {
        x: x + width.saturating_sub(close_width + 3),
        y: y + 1,
        width: close_width,
        height: 1,
    };
    help.scroll_offset = help.scroll_offset.min(total_rows.saturating_sub(visible_rows));
    help.scrollbar_track = if visible_rows > 0 && total_rows > visible_rows {
        Rect { x: x + width - 2, y: y + 2, width: 1, height: visible_rows as u16 }
    } else {
        Rect::default()
    };
    let (thumb_y, thumb_height) = help.scrollbar_geometry(total_rows);
    help.scrollbar_thumb = if help.scrollbar_track.height > 0 {
        Rect {
            x: help.scrollbar_track.x,
            y: help.scrollbar_track.y + thumb_y,
            width: 1,
            height: thumb_height,
        }
    } else {
        Rect::default()
    };
    let scroll_offset = help.scroll_offset;
    let scrollbar_track = help.scrollbar_track;
    let close_button = help.close_button;
    let scrollbar_dragging = help.scrollbar_dragging();

    let buf = frame.buffer_mut();
    for dy in 0..height {
        for dx in 0..width {
            set_cell(buf, x + dx, y + dy, " ", base);
        }
    }
    draw_border(buf, rect, border);
    let title_width = close_button.x.saturating_sub(x + 3);
    buf.set_stringn(x + 2, y + 1, catalog.shortcuts.title, title_width as usize, title);
    buf.set_stringn(
        close_button.x,
        close_button.y,
        &close_text,
        close_button.width as usize,
        shortcut_style,
    );

    let inner_width = width.saturating_sub(5);
    let Some(help) = app.shortcut_help.as_ref() else { return };
    for (line, (action, shortcuts)) in
        help.rows.iter().skip(scroll_offset).take(visible_rows).enumerate()
    {
        let row_y = y + 2 + line as u16;
        let label = app.action_display_label(*action);
        let shortcuts = format!(" {shortcuts} ");
        let shortcut_width = shortcuts.cell_width().min(inner_width / 2);
        let shortcut_x = x + width.saturating_sub(shortcut_width + 2);
        let shortcut_x = if scrollbar_track.height > 0 {
            shortcut_x.min(scrollbar_track.x.saturating_sub(shortcut_width + 1))
        } else {
            shortcut_x
        };
        let label_width = shortcut_x.saturating_sub(x + 3);
        buf.set_stringn(x + 2, row_y, label, label_width as usize, base);
        buf.set_stringn(shortcut_x, row_y, &shortcuts, shortcut_width as usize, shortcut_style);
    }
    ScrollbarStyle::from_chrome(chrome).draw_thumb(
        buf,
        scrollbar_track,
        (thumb_y, thumb_height),
        base,
        if scrollbar_dragging { ScrollbarState::Expanded } else { ScrollbarState::Highlighted },
    );

    let footer = if total_rows > visible_rows {
        let start = scroll_offset.saturating_add(1).min(total_rows);
        let end = (scroll_offset + visible_rows).min(total_rows);
        format!("{}  {start}-{end}/{total_rows}", catalog.shortcuts.footer)
    } else {
        catalog.shortcuts.footer.to_string()
    };
    buf.set_stringn(
        x + 2,
        y + height - 2,
        &footer,
        width.saturating_sub(5) as usize,
        base.fg(chrome.status_dim_fg),
    );
}

pub fn draw_toast(app: &App, frame: &mut Frame) {
    let Some(toast) = app.toast.as_ref() else { return };
    let label = format!(" {} ", toast.text);
    let Some(rect) = toast_rect_for_label(app.content_area, &label) else { return };
    let style = Style::default().bg(app.chrome.toast_bg).fg(app.chrome.toast_fg);
    frame.buffer_mut().set_stringn(rect.x, rect.y, &label, rect.width as usize, style);
}

pub(crate) fn toast_rect(app: &App) -> Option<Rect> {
    let toast = app.toast.as_ref()?;
    toast_rect_for_label(app.content_area, &format!(" {} ", toast.text))
}

fn toast_rect_for_label(area: Rect, label: &str) -> Option<Rect> {
    if area.width == 0 || area.height == 0 {
        return None;
    }
    let width = label_width(label).min(area.width);
    (width > 0).then_some(Rect {
        x: area.x + area.width.saturating_sub(width + 1),
        y: area.y + area.height.saturating_sub(2),
        width,
        height: 1,
    })
}

fn set_cell(buf: &mut Buffer, x: u16, y: u16, symbol: &str, style: Style) {
    let cell = &mut buf[(x, y)];
    cell.reset();
    cell.set_symbol(symbol).set_style(style);
}

fn draw_border(buf: &mut Buffer, rect: Rect, style: Style) {
    if rect.width < 2 || rect.height < 2 {
        return;
    }
    let x0 = rect.x;
    let y0 = rect.y;
    let x1 = rect.x + rect.width - 1;
    let y1 = rect.y + rect.height - 1;
    for x in x0 + 1..x1 {
        set_cell(buf, x, y0, "─", style);
        set_cell(buf, x, y1, "─", style);
    }
    for y in y0 + 1..y1 {
        set_cell(buf, x0, y, "│", style);
        set_cell(buf, x1, y, "│", style);
    }
    set_cell(buf, x0, y0, "┌", style);
    set_cell(buf, x1, y0, "┐", style);
    set_cell(buf, x0, y1, "└", style);
    set_cell(buf, x1, y1, "┘", style);
}

fn label_width(label: &str) -> u16 {
    label.cell_width()
}

fn grapheme_prefix_end(input: &str, max_width: usize) -> usize {
    let mut width: usize = 0;
    let mut end = 0;
    for (index, grapheme) in input.grapheme_indices(true) {
        let grapheme_width = usize::from(grapheme.cell_width());
        if width.saturating_add(grapheme_width) > max_width {
            break;
        }
        width += grapheme_width;
        end = index + grapheme.len();
    }
    end
}

fn grapheme_is_whitespace(grapheme: &str) -> bool {
    grapheme.chars().next().is_some_and(char::is_whitespace)
}

fn trim_grapheme_whitespace_start(input: &str) -> &str {
    let start = input
        .grapheme_indices(true)
        .find(|(_, grapheme)| !grapheme_is_whitespace(grapheme))
        .map_or(input.len(), |(index, _)| index);
    &input[start..]
}

fn trim_grapheme_whitespace_end(input: &str) -> &str {
    let end = input
        .grapheme_indices(true)
        .rev()
        .find(|(_, grapheme)| !grapheme_is_whitespace(grapheme))
        .map_or(0, |(index, grapheme)| index + grapheme.len());
    &input[..end]
}

fn trim_grapheme_whitespace(input: &str) -> &str {
    trim_grapheme_whitespace_end(trim_grapheme_whitespace_start(input))
}

#[cfg(test)]
mod tests {
    use cmux_tui_core::Rect;
    use ratatui::buffer::CellWidth;

    use super::{label_width, toast_rect_for_label, wrapped_message_lines};
    use crate::localization::catalog_for_locale;

    #[test]
    fn pairing_dialog_has_english_and_japanese_copy() {
        assert_eq!(catalog_for_locale("en_US.UTF-8").pairing.title, "Approve browser?");
        assert_eq!(catalog_for_locale("ja_JP.UTF-8").pairing.title, "ブラウザを承認しますか？");
    }

    #[test]
    fn toast_occlusion_uses_the_rendered_character_clamp() {
        assert_eq!(
            toast_rect_for_label(Rect { x: 10, y: 2, width: 10, height: 5 }, " 界 "),
            Some(Rect { x: 15, y: 5, width: 4, height: 1 })
        );
    }

    #[test]
    fn overlay_labels_and_wrapping_use_terminal_cell_width() {
        assert_eq!(label_width(" 界 "), 4);
        let lines = wrapped_message_lines("界界界", 4, 2);
        assert_eq!(lines, vec!["界界", "界"]);
        assert!(lines.iter().all(|line| line.cell_width() <= 4));
    }

    #[test]
    #[allow(clippy::unicode_not_nfc)]
    fn wrapping_trims_whitespace_graphemes_without_orphaning_marks() {
        let lines = wrapped_message_lines("a \u{301}b", 2, 2);
        assert_eq!(lines, vec!["a", "b"]);
    }

    #[test]
    #[allow(clippy::unicode_not_nfc)]
    fn wrapping_uses_terminal_cell_width_for_halfwidth_dakuten() {
        let lines = wrapped_message_lines("界ﾞ界ﾞ", 5, 2);
        assert_eq!(lines, vec!["界ﾞ", "界ﾞ"]);
    }
}
