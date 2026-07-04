//! Overlays drawn on top of the frame: the right-click context menu.
//! The menu has a one-cell padding border around its items, and the
//! selected row (arrow keys or mouse hover) is highlighted.

use mux_core::Rect;
use ratatui::style::{Color, Modifier, Style};
use ratatui::Frame;

use crate::app::{App, ContextMenu};

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

    // Background including the padding border.
    for dy in 0..height {
        for dx in 0..width {
            buf[(x + dx, y + dy)].set_symbol(" ").set_style(base);
        }
    }

    let pad = ContextMenu::PAD;
    let label_w = width.saturating_sub(pad * 2) as usize;
    for (i, item) in menu.items.iter().enumerate() {
        let row_y = y + pad + i as u16;
        if row_y >= y + height.saturating_sub(pad) {
            break;
        }
        let style = if i == menu.selected { selected } else { base };
        // Highlight the item row inside the padding border.
        for dx in pad..width.saturating_sub(pad) {
            buf[(x + dx, row_y)].set_style(style);
        }
        buf.set_stringn(x + pad + 1, row_y, item.label(), label_w.saturating_sub(1), style);
    }
}
