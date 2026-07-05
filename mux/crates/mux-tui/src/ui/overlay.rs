//! Overlays drawn on top of the frame: the right-click context menu and
//! the centered rename dialog. Menu items get a one-cell padding column
//! each side inside a border (no extra rows), and the selected row (arrow
//! keys or mouse hover) highlights across the inner row, padding included.

use mux_core::Rect;
use ratatui::buffer::Buffer;
use ratatui::layout::Position;
use ratatui::style::{Color, Modifier, Style};
use ratatui::Frame;

use crate::app::{App, ContextMenu};

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

    let base = Style::default().bg(Color::Indexed(236)).fg(Color::Indexed(252));
    let border = base.fg(Color::Indexed(244));
    let title_style = base.fg(Color::Indexed(255)).add_modifier(Modifier::BOLD);
    let input_style = Style::default().bg(Color::Indexed(233)).fg(Color::Indexed(255));
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
        let mut s = if accent { base.fg(Color::Indexed(114)) } else { base };
        if hovered {
            s = s.add_modifier(Modifier::BOLD).bg(Color::Indexed(240));
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
    let Some(menu) = app.menu.as_mut() else { return };

    // Clamp to the screen and write the final rect back so click and
    // hover hit-testing match what is drawn.
    let width = menu.rect.width.min(screen.width);
    let height = menu.rect.height.min(screen.height);
    let x = menu.rect.x.min(screen.width.saturating_sub(width));
    let y = menu.rect.y.min(screen.height.saturating_sub(height));
    menu.rect = Rect { x, y, width, height };
    if width < 2 || height < 2 {
        return;
    }

    let base = Style::default().bg(Color::Indexed(237)).fg(Color::Indexed(252));
    let border = base.fg(Color::Indexed(244));
    let selected = Style::default()
        .bg(Color::Indexed(242))
        .fg(Color::Indexed(255))
        .add_modifier(Modifier::BOLD);
    let buf = frame.buffer_mut();

    for dy in 0..height {
        for dx in 0..width {
            set_cell(buf, x + dx, y + dy, " ", base);
        }
    }
    draw_border(buf, menu.rect, border);

    let pad = ContextMenu::PAD;
    let inner_x = x + 1;
    let inner_y = y + 1;
    let inner_w = width.saturating_sub(2);
    let inner_h = height.saturating_sub(2);
    for (i, item) in menu.items.iter().enumerate() {
        let row_y = inner_y + i as u16;
        if i as u16 >= inner_h {
            break;
        }
        let style = if i == menu.selected { selected } else { base };
        // The highlight spans the full inner row, side padding included.
        for dx in 0..inner_w {
            set_cell(buf, inner_x + dx, row_y, " ", style);
        }
        buf.set_stringn(
            inner_x + pad + 1,
            row_y,
            item.label(),
            inner_w.saturating_sub(pad * 2) as usize,
            style,
        );
    }
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
