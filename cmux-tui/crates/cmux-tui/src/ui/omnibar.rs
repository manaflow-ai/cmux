use cmux_tui_core::{BrowserStatus, Rect, SurfaceKind};
use ratatui::Frame;
use ratatui::buffer::Buffer;
use ratatui::style::{Modifier, Style};
use unicode_width::UnicodeWidthStr;

use super::{copy_buffer_row_cropped, truncate};
use crate::app::{App, OmnibarHit, PaneArea};

const BACK_X: u16 = 1;
const FORWARD_X: u16 = 3;
const RELOAD_X: u16 = 5;
const EDIT_START_X: u16 = 7;
const TEXT_START_X: u16 = 9;

pub fn hit(rect: Rect, source_x: u16, x: u16, y: u16, editing: bool) -> Option<OmnibarHit> {
    if !rect.contains(x, y) {
        return None;
    }
    if editing {
        return Some(OmnibarHit::Edit);
    }
    let rel = source_x.saturating_add(x.saturating_sub(rect.x));
    match rel {
        BACK_X => Some(OmnibarHit::Back),
        FORWARD_X => Some(OmnibarHit::Forward),
        RELOAD_X => Some(OmnibarHit::Reload),
        EDIT_START_X.. => Some(OmnibarHit::Edit),
        _ => None,
    }
}

pub fn draw(app: &mut App, frame: &mut Frame, area: &PaneArea) -> Option<(u16, u16)> {
    let rect = area.omnibar?;
    let source_x = area.omnibar_source_x();
    let full_width = area.full_omnibar_width();
    let screen = frame.area();
    let screen_right = screen.x.saturating_add(screen.width);
    let screen_bottom = screen.y.saturating_add(screen.height);
    if rect.width == 0
        || rect.height == 0
        || full_width == 0
        || source_x >= full_width
        || rect.x < screen.x
        || rect.x >= screen_right
        || rect.y < screen.y
        || rect.y >= screen_bottom
    {
        return None;
    }
    let surface = app.session.surface(area.surface)?;
    if surface.kind() != SurfaceKind::Browser {
        return None;
    }

    let editing = app
        .omnibar
        .as_ref()
        .is_some_and(|state| state.pane == area.pane && state.surface == area.surface);
    if area.viewport.is_none() && rect.width <= screen_right.saturating_sub(rect.x) {
        if editing {
            return draw_editing(app, frame.buffer_mut(), rect).map(|cursor_x| (cursor_x, rect.y));
        }
        let hover_x = app.hover.and_then(|(x, y)| rect.contains(x, y).then_some(x));
        draw_idle(app, frame.buffer_mut(), area, rect, &surface, hover_x);
        return None;
    }

    let visible_width = rect
        .width
        .min(full_width.saturating_sub(source_x))
        .min(screen_right.saturating_sub(rect.x));
    let logical_rect = Rect { x: 0, y: 0, width: full_width, height: 1 };
    let mut logical = app.chrome_row_scratch.take(full_width);
    let cursor = if editing {
        draw_editing(app, &mut logical, Rect { x: source_x, width: visible_width, ..logical_rect })
    } else {
        let hover_x = app.hover.and_then(|(x, y)| {
            rect.contains(x, y).then(|| source_x.saturating_add(x.saturating_sub(rect.x)))
        });
        draw_idle(app, &mut logical, area, logical_rect, &surface, hover_x);
        None
    };

    copy_buffer_row_cropped(
        &logical,
        0,
        source_x,
        frame.buffer_mut(),
        Rect { width: visible_width, height: 1, ..rect },
    );
    app.chrome_row_scratch.put(logical);
    cursor
        .filter(|cursor_x| {
            *cursor_x >= source_x && *cursor_x < source_x.saturating_add(visible_width)
        })
        .map(|cursor_x| (rect.x + cursor_x - source_x, rect.y))
}

fn draw_idle(
    app: &App,
    buffer: &mut Buffer,
    area: &PaneArea,
    rect: Rect,
    surface: &crate::session::SurfaceHandle,
    hover_x: Option<u16>,
) {
    let chrome = app.chrome;
    let base = Style::default().fg(chrome.omnibar_fg);
    fill(buffer, rect, base);
    put(buffer, rect, 0, " ", base);
    let hover = base.fg(chrome.omnibar_hover_fg).add_modifier(Modifier::BOLD);
    put_nav(buffer, rect, BACK_X, "‹", base, hover, hover_x);
    put_nav(buffer, rect, FORWARD_X, "›", base, hover, hover_x);
    put_nav(buffer, rect, RELOAD_X, "⟳", base, hover, hover_x);
    put(buffer, rect, 7, "│", base.fg(chrome.omnibar_sep_fg));

    if rect.width <= TEXT_START_X {
        return;
    }

    let mut label = surface.browser_url().unwrap_or_else(|| {
        app.tree
            .active_screen()
            .and_then(|screen| screen.pane(area.pane))
            .and_then(|pane| pane.tabs.get(pane.active_tab))
            .map(|tab| tab.title.clone())
            .filter(|title| !title.is_empty())
            .unwrap_or_else(|| "browser".to_string())
    });
    let loading = matches!(surface.browser_status(), Some(BrowserStatus::Starting))
        || (matches!(surface.browser_status(), Some(BrowserStatus::Live))
            && !surface.has_browser_frame());
    if loading {
        label.push('…');
    }
    let max = rect.width.saturating_sub(TEXT_START_X) as usize;
    let suffix = " ⏸ chrome tab hidden";
    let tree_stalled = app
        .tree
        .workspaces
        .iter()
        .flat_map(|ws| ws.screens.iter())
        .flat_map(|screen| screen.panes.iter())
        .flat_map(|pane| pane.tabs.iter())
        .find(|tab| tab.surface == area.surface)
        .is_some_and(|tab| tab.browser_frames_stalled);
    if (surface.browser_frames_stalled() || tree_stalled) && max > 0 {
        let suffix_width = suffix.width();
        if max > suffix_width {
            let label_max = max - suffix_width;
            let text = truncate(&label, label_max);
            put(buffer, rect, TEXT_START_X, &text, base);
            put(
                buffer,
                rect,
                TEXT_START_X + text.width() as u16,
                suffix,
                base.fg(chrome.omnibar_dim_fg),
            );
        } else {
            let text = truncate(suffix.trim_start(), max);
            put(buffer, rect, TEXT_START_X, &text, base.fg(chrome.omnibar_dim_fg));
        }
    } else {
        let text = truncate(&label, max);
        put(buffer, rect, TEXT_START_X, &text, base);
    }
}

fn draw_editing(app: &mut App, buffer: &mut Buffer, rect: Rect) -> Option<u16> {
    let chrome = app.chrome;
    let state = app.omnibar.as_mut()?;
    let base = Style::default().bg(chrome.omnibar_edit_bg).fg(chrome.omnibar_edit_fg);
    fill(buffer, rect, base);
    if rect.width == 0 {
        return None;
    }

    let width = rect.width as usize;
    let (shown, cursor_col) = state.input.visible_text_and_cursor(width);
    let style = if state.select_all { base.add_modifier(Modifier::REVERSED) } else { base };
    put(buffer, rect, 0, &shown, style);
    Some(rect.x + cursor_col as u16)
}

fn put_nav(
    buffer: &mut Buffer,
    rect: Rect,
    rel_x: u16,
    text: &str,
    base: Style,
    hover: Style,
    hover_x: Option<u16>,
) {
    if rel_x >= rect.width {
        return;
    }
    let style = if hover_x == Some(rect.x + rel_x) { hover } else { base };
    put(buffer, rect, rel_x, text, style);
}

fn fill(buffer: &mut Buffer, rect: Rect, style: Style) {
    let screen = buffer.area;
    let max_x = (rect.x + rect.width).min(screen.width);
    if rect.y >= screen.height {
        return;
    }
    for x in rect.x..max_x {
        buffer[(x, rect.y)].set_symbol(" ").set_style(style);
    }
}

fn put(buffer: &mut Buffer, rect: Rect, rel_x: u16, text: &str, style: Style) {
    if rel_x >= rect.width {
        return;
    }
    let screen = buffer.area;
    if rect.y >= screen.height {
        return;
    }
    let x = rect.x + rel_x;
    let max = rect.width.saturating_sub(rel_x) as usize;
    buffer.set_stringn(x, rect.y, text, max, style);
}

#[cfg(test)]
mod tests {
    use super::hit;
    use crate::app::OmnibarHit;
    use cmux_tui_core::Rect;

    #[test]
    fn editing_omnibar_treats_entire_row_as_edit_text() {
        let rect = Rect { x: 10, y: 2, width: 20, height: 1 };
        assert_eq!(hit(rect, 0, 11, 2, true), Some(OmnibarHit::Edit));
        assert_eq!(hit(rect, 0, 13, 2, true), Some(OmnibarHit::Edit));
        assert_eq!(hit(rect, 0, 15, 2, true), Some(OmnibarHit::Edit));
    }

    #[test]
    fn clipped_omnibar_hits_keep_their_logical_columns() {
        let rect = Rect { x: 20, y: 2, width: 8, height: 1 };
        assert_eq!(hit(rect, 4, 21, 2, false), Some(OmnibarHit::Reload));
        assert_eq!(hit(rect, 4, 23, 2, false), Some(OmnibarHit::Edit));
        assert_eq!(hit(rect, 4, 20, 2, false), None);
    }
}
