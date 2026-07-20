//! Overlays drawn on top of the frame: the right-click context menu and
//! the centered rename dialog. Menu items get a one-cell padding column
//! each side inside a border, separator rows divide related groups, and the
//! selected row (arrow keys or mouse hover) highlights across the inner row.

use cmux_tui_core::Rect;
use ratatui::Frame;
use ratatui::buffer::Buffer;
use ratatui::layout::Position;
use ratatui::style::{Modifier, Style};

use crate::app::{App, ContextMenu, MenuItem};
use crate::localization::catalog;

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
    if app.shake_frames > 0 {
        app.shake_frames -= 1;
    }

    let width: u16 = 42.min(screen.width.saturating_sub(2)).max(20);
    let height: u16 = 9;
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
    buf.set_stringn(x + 2, y + 2, prompt.label, (width - 4) as usize, title_style);

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

pub fn draw_menu(app: &mut App, frame: &mut Frame) {
    let screen = frame.area();
    let chrome = app.chrome;
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

        let level = &menu.levels[depth];
        let buf = frame.buffer_mut();
        for dy in 0..height {
            for dx in 0..width {
                set_cell(buf, x + dx, y + dy, " ", base);
            }
        }
        draw_border(buf, level.rect, border);

        let pad = ContextMenu::PAD;
        let inner_x = x + 1;
        let inner_y = y + 1;
        let inner_w = width.saturating_sub(2);
        let inner_h = height.saturating_sub(2);
        for (i, item) in
            level.items.iter().enumerate().skip(level.scroll_offset).take(inner_h as usize)
        {
            let row_y = inner_y + (i - level.scroll_offset) as u16;
            if *item == MenuItem::Separator {
                set_cell(buf, x, row_y, "├", border);
                for dx in 0..inner_w {
                    set_cell(buf, inner_x + dx, row_y, "─", border);
                }
                set_cell(buf, x + width - 1, row_y, "┤", border);
                continue;
            }
            if let Some(label) = item.label() {
                let style = if i == level.selected { selected } else { base };
                for dx in 0..inner_w {
                    set_cell(buf, inner_x + dx, row_y, " ", style);
                }
                let arrow_width = matches!(item, MenuItem::Submenu { .. }) as u16 * 2;
                buf.set_stringn(
                    inner_x + pad + 1,
                    row_y,
                    label,
                    inner_w.saturating_sub(pad * 2 + arrow_width) as usize,
                    style,
                );
                if matches!(item, MenuItem::Submenu { .. }) && inner_w > 2 {
                    buf.set_stringn(x + width - pad - 3, row_y, " ›", 2, style);
                }
            }
        }
    }
}

pub fn draw_toast(app: &App, frame: &mut Frame) {
    let Some(toast) = app.toast.as_ref() else { return };
    let area = app.content_area;
    if area.width == 0 || area.height == 0 {
        return;
    }
    let label = format!(" {} ", toast.text);
    let width = label_width(&label).min(area.width);
    if width == 0 {
        return;
    }
    let x = area.x + area.width.saturating_sub(width + 1);
    let y = area.y + area.height.saturating_sub(2);
    let style = Style::default().bg(app.chrome.toast_bg).fg(app.chrome.toast_fg);
    frame.buffer_mut().set_stringn(x, y, &label, width as usize, style);
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
    label.chars().count() as u16
}

#[cfg(test)]
mod tests {
    use crate::localization::catalog_for_locale;

    #[test]
    fn pairing_dialog_has_english_and_japanese_copy() {
        assert_eq!(catalog_for_locale("en_US.UTF-8").pairing.title, "Approve browser?");
        assert_eq!(catalog_for_locale("ja_JP.UTF-8").pairing.title, "ブラウザを承認しますか？");
    }
}
