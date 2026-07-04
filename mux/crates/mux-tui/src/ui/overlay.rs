//! Overlays drawn on top of the frame: the right-click context menu and
//! the centered rename dialog. Menu items get a one-cell padding column
//! each side (no extra rows), and the selected row (arrow keys or mouse
//! hover) highlights across the menu's full width, padding included.

use mux_core::Rect;
use ratatui::layout::Position;
use ratatui::style::{Color, Modifier, Style};
use ratatui::Frame;

use crate::app::{App, ContextMenu};

/// Centered rename dialog: title row, input row, and clickable
/// [ OK ] / [ Cancel ] buttons. Writes the dialog and button rects back
/// into the prompt so mouse handling matches the drawn geometry.
pub fn draw_prompt(app: &mut App, frame: &mut Frame) {
    let screen = frame.area();
    let Some(prompt) = app.prompt.as_mut() else { return };
    let hover = app.hover;

    let width: u16 = 40.min(screen.width.saturating_sub(2)).max(20);
    let height: u16 = 5;
    if screen.width < width || screen.height < height {
        return;
    }
    let x = (screen.width - width) / 2;
    let y = (screen.height - height) / 2;
    prompt.rect = Rect { x, y, width, height };

    let base = Style::default().bg(Color::Indexed(236)).fg(Color::Indexed(252));
    let title_style = base.fg(Color::Indexed(255)).add_modifier(Modifier::BOLD);
    let input_style = Style::default().bg(Color::Indexed(233)).fg(Color::Indexed(255));
    let buf = frame.buffer_mut();

    for dy in 0..height {
        for dx in 0..width {
            buf[(x + dx, y + dy)].set_symbol(" ").set_style(base);
        }
    }
    buf.set_stringn(x + 2, y, prompt.label, (width - 4) as usize, title_style);

    // Input row: the buffer tail, with a visible text cursor.
    let input_w = (width - 4) as usize;
    let shown: String = {
        let chars: Vec<char> = prompt.buffer.chars().collect();
        let skip = chars.len().saturating_sub(input_w.saturating_sub(1));
        chars[skip..].iter().collect()
    };
    for dx in 0..input_w as u16 {
        buf[(x + 2 + dx, y + 2)].set_symbol(" ").set_style(input_style);
    }
    buf.set_stringn(x + 2, y + 2, &shown, input_w, input_style);
    let cursor_x = x + 2 + (shown.chars().count() as u16).min(input_w as u16 - 1);
    frame.set_cursor_position(Position::new(cursor_x, y + 2));

    // Buttons, right-aligned: [ Cancel ]  [ OK ]
    let ok_label = "[ OK ]";
    let cancel_label = "[ Cancel ]";
    let ok_w = ok_label.len() as u16;
    let cancel_w = cancel_label.len() as u16;
    let ok_x = x + width - 2 - ok_w;
    let cancel_x = ok_x.saturating_sub(cancel_w + 2);
    let button_y = y + height - 1;
    prompt.ok = Rect { x: ok_x, y: button_y, width: ok_w, height: 1 };
    prompt.cancel = Rect { x: cancel_x, y: button_y, width: cancel_w, height: 1 };
    let button_style = |rect: Rect, accent: bool| {
        let hovered = hover.is_some_and(|(hx, hy)| rect.contains(hx, hy));
        let mut s = if accent { base.fg(Color::Indexed(114)) } else { base };
        if hovered {
            s = s.add_modifier(Modifier::BOLD).bg(Color::Indexed(240));
        }
        s
    };
    let buf = frame.buffer_mut();
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

    let base = Style::default().bg(Color::Indexed(237)).fg(Color::Indexed(252));
    let selected = Style::default()
        .bg(Color::Indexed(242))
        .fg(Color::Indexed(255))
        .add_modifier(Modifier::BOLD);
    let buf = frame.buffer_mut();

    let pad = ContextMenu::PAD;
    for (i, item) in menu.items.iter().enumerate() {
        let row_y = y + i as u16;
        if row_y >= y + height {
            break;
        }
        let style = if i == menu.selected { selected } else { base };
        // The highlight spans the full row, side padding included.
        for dx in 0..width {
            buf[(x + dx, row_y)].set_symbol(" ").set_style(style);
        }
        buf.set_stringn(
            x + pad + 1,
            row_y,
            item.label(),
            width.saturating_sub(pad * 2) as usize,
            style,
        );
    }
}
