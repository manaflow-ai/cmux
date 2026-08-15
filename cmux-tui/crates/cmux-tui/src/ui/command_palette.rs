use cmux_tui_core::Rect;
use ratatui::Frame;
use ratatui::buffer::Buffer;
use ratatui::layout::Position;
use ratatui::style::{Modifier, Style};
use unicode_width::UnicodeWidthStr;

use crate::app::App;
use crate::localization::catalog;

pub(crate) fn draw(app: &mut App, frame: &mut Frame) {
    let screen = frame.area();
    let Some(palette) = app.command_palette.as_mut() else { return };
    palette.clear_render_geometry();
    if screen.width == 0 || screen.height == 0 {
        return;
    }

    let horizontal_margin = u16::from(screen.width >= 4);
    let vertical_margin = u16::from(screen.height >= 4);
    let width = 76.min(screen.width.saturating_sub(horizontal_margin * 2));
    let height = 20.min(screen.height.saturating_sub(vertical_margin * 2));
    if width == 0 || height == 0 {
        return;
    }
    let x = screen.x + (screen.width - width) / 2;
    let y = screen.y + (screen.height - height) / 3;
    let rect = Rect { x, y, width, height };
    let chrome = app.chrome;
    let base = Style::default().bg(chrome.menu_bg).fg(chrome.menu_fg);
    let border = base.fg(chrome.menu_border);
    let title_style = base.fg(chrome.prompt_title_fg).add_modifier(Modifier::BOLD);
    let input_style = Style::default().bg(chrome.prompt_input_bg).fg(chrome.prompt_input_fg);
    let dim = base.fg(chrome.status_dim_fg);

    fill(frame.buffer_mut(), rect, base);
    draw_border(frame.buffer_mut(), rect, border);

    if height <= 2 || width <= 2 {
        palette.set_render_geometry(rect, Rect::default(), Vec::new(), 0);
        return;
    }

    let copy = &catalog().palette;
    frame.buffer_mut().set_stringn(
        x + 2,
        y,
        &format!(" {} ", copy.title),
        width.saturating_sub(4) as usize,
        title_style,
    );

    let input_y = y + 2;
    let input_width = width.saturating_sub(4);
    let input_rect = Rect { x: x + 2, y: input_y, width: input_width, height: 1 };
    fill(frame.buffer_mut(), input_rect, input_style);
    let (shown, cursor_col) = palette.input.visible_text_and_cursor(input_width as usize);
    if shown.is_empty() {
        frame.buffer_mut().set_stringn(
            input_rect.x,
            input_rect.y,
            copy.placeholder,
            input_width as usize,
            input_style.fg(chrome.status_dim_fg),
        );
    } else {
        frame.buffer_mut().set_stringn(
            input_rect.x,
            input_rect.y,
            &shown,
            input_width as usize,
            input_style,
        );
    }

    let rows_y = y + 4;
    let footer_rows = 2_u16;
    let visible_rows = height.saturating_sub(4 + footer_rows) as usize;
    palette.set_render_geometry(rect, input_rect, Vec::new(), visible_rows);
    let mut row_rects = Vec::with_capacity(visible_rows);
    let rows = palette
        .visible_candidates()
        .map(|(filtered_index, candidate)| {
            (
                filtered_index,
                candidate.title.clone(),
                candidate.subtitle.clone(),
                candidate.shortcut.clone(),
                candidate.disabled_reason(),
            )
        })
        .collect::<Vec<_>>();

    if rows.is_empty() && visible_rows > 0 {
        frame.buffer_mut().set_stringn(
            x + 2,
            rows_y,
            copy.no_matches,
            width.saturating_sub(4) as usize,
            dim,
        );
    }

    for (line, (filtered_index, title, subtitle, shortcut, disabled)) in
        rows.into_iter().enumerate()
    {
        let row_y = rows_y + line as u16;
        if row_y >= y + height.saturating_sub(2) {
            break;
        }
        let row = Rect { x: x + 1, y: row_y, width: width.saturating_sub(2), height: 1 };
        row_rects.push((row, filtered_index));
        let selected = filtered_index == palette.selected;
        let style = if selected {
            Style::default()
                .bg(chrome.menu_selected_bg)
                .fg(if disabled.is_some() { chrome.status_dim_fg } else { chrome.menu_selected_fg })
        } else if disabled.is_some() {
            dim
        } else {
            base
        };
        fill(frame.buffer_mut(), row, style);

        let right = disabled
            .map(|reason| copy.disabled_reason(reason).to_string())
            .or(shortcut)
            .unwrap_or_default();
        let right_width = UnicodeWidthStr::width(right.as_str()) as u16;
        let right_x = x + width.saturating_sub(right_width + 2);
        let label_width = right_x.saturating_sub(x + 3);
        frame.buffer_mut().set_stringn(
            x + 2,
            row_y,
            &title,
            label_width as usize,
            if selected { style.add_modifier(Modifier::BOLD) } else { style },
        );
        if !right.is_empty() {
            frame.buffer_mut().set_stringn(
                right_x,
                row_y,
                &right,
                width.saturating_sub(right_x.saturating_sub(x) + 1) as usize,
                style,
            );
        } else if label_width > UnicodeWidthStr::width(title.as_str()) as u16 + 2 {
            let subtitle_x = x + 3 + UnicodeWidthStr::width(title.as_str()) as u16;
            frame.buffer_mut().set_stringn(
                subtitle_x,
                row_y,
                &subtitle,
                right_x.saturating_sub(subtitle_x) as usize,
                style.fg(chrome.status_dim_fg),
            );
        }
    }
    palette.row_rects = row_rects;

    if height >= 2 {
        let footer_y = y + height - 2;
        let count = format!("{}/{}", palette.selected.saturating_add(1).min(palette.filtered.len()), palette.filtered.len());
        frame.buffer_mut().set_stringn(
            x + 2,
            footer_y,
            copy.footer,
            width.saturating_sub(4) as usize,
            dim,
        );
        let count_width = UnicodeWidthStr::width(count.as_str()) as u16;
        frame.buffer_mut().set_stringn(
            x + width.saturating_sub(count_width + 2),
            footer_y,
            &count,
            count_width as usize,
            dim,
        );
    }

    if input_width > 0 {
        frame.set_cursor_position(Position::new(
            input_rect.x + (cursor_col as u16).min(input_width.saturating_sub(1)),
            input_rect.y,
        ));
    }
}

fn fill(buffer: &mut Buffer, rect: Rect, style: Style) {
    for row in rect.y..rect.y.saturating_add(rect.height) {
        for column in rect.x..rect.x.saturating_add(rect.width) {
            let cell = &mut buffer[(column, row)];
            cell.reset();
            cell.set_symbol(" ").set_style(style);
        }
    }
}

fn draw_border(buffer: &mut Buffer, rect: Rect, style: Style) {
    if rect.width < 2 || rect.height < 2 {
        return;
    }
    let right = rect.x + rect.width - 1;
    let bottom = rect.y + rect.height - 1;
    for x in rect.x + 1..right {
        buffer[(x, rect.y)].set_symbol("─").set_style(style);
        buffer[(x, bottom)].set_symbol("─").set_style(style);
    }
    for y in rect.y + 1..bottom {
        buffer[(rect.x, y)].set_symbol("│").set_style(style);
        buffer[(right, y)].set_symbol("│").set_style(style);
    }
    buffer[(rect.x, rect.y)].set_symbol("┌").set_style(style);
    buffer[(right, rect.y)].set_symbol("┐").set_style(style);
    buffer[(rect.x, bottom)].set_symbol("└").set_style(style);
    buffer[(right, bottom)].set_symbol("┘").set_style(style);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn zero_sized_fill_is_a_noop() {
        let mut buffer = Buffer::empty(ratatui::layout::Rect::new(0, 0, 1, 1));
        fill(&mut buffer, Rect::default(), Style::default());
        assert_eq!(buffer[(0, 0)].symbol(), " ");
    }
}
