//! Overlays drawn on top of the frame: the right-click context menu.

use mux_core::Rect;
use ratatui::style::{Color, Modifier, Style};
use ratatui::Frame;

use crate::app::App;

pub fn draw_menu(app: &mut App, frame: &mut Frame) {
    let screen = frame.area();
    let Some(menu) = app.menu.as_mut() else { return };

    // Clamp to the screen (leave the status bar visible) and write the
    // final rect back so click hit-testing matches what is drawn.
    let width = menu.rect.width.min(screen.width);
    let height = menu.rect.height.min(screen.height.saturating_sub(1));
    let x = menu.rect.x.min(screen.width.saturating_sub(width));
    let y = menu.rect.y.min(screen.height.saturating_sub(1).saturating_sub(height));
    menu.rect = Rect { x, y, width, height };

    let base = Style::default().bg(Color::Indexed(237)).fg(Color::Indexed(252));
    let selected = Style::default()
        .bg(Color::Indexed(242))
        .fg(Color::Indexed(255))
        .add_modifier(Modifier::BOLD);
    let buf = frame.buffer_mut();
    for (i, item) in menu.items.iter().enumerate() {
        let row_y = y + i as u16;
        let style = if i == menu.selected { selected } else { base };
        for dx in 0..width {
            buf[(x + dx, row_y)].set_symbol(" ").set_style(style);
        }
        buf.set_stringn(x + 1, row_y, item.label(), width.saturating_sub(1) as usize, style);
    }
}
