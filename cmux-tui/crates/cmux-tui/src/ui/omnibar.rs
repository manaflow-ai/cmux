use cmux_tui_core::{BrowserStatus, Rect, SurfaceKind};
use ratatui::Frame;
use ratatui::style::{Modifier, Style};

use super::truncate;
use crate::app::{App, OmnibarHit, PaneArea};

const BACK_X: u16 = 1;
const FORWARD_X: u16 = 3;
const RELOAD_X: u16 = 5;
const EDIT_START_X: u16 = 7;
const TEXT_START_X: u16 = 9;

pub fn hit(rect: Rect, x: u16, y: u16, editing: bool) -> Option<OmnibarHit> {
    if !rect.contains(x, y) {
        return None;
    }
    if editing {
        return Some(OmnibarHit::Edit);
    }
    let rel = x.saturating_sub(rect.x);
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
    if rect.width == 0 || rect.height == 0 {
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
    if editing {
        draw_editing(app, frame, rect)
    } else {
        draw_idle(app, frame, area, rect, &surface);
        None
    }
}

fn draw_idle(
    app: &App,
    frame: &mut Frame,
    area: &PaneArea,
    rect: Rect,
    surface: &crate::session::SurfaceHandle,
) {
    let chrome = app.chrome;
    let base = Style::default().fg(chrome.omnibar_fg);
    fill(frame, rect, base);
    put(frame, rect, 0, " ", base);
    put_nav(frame, app, rect, BACK_X, "‹", base);
    put_nav(frame, app, rect, FORWARD_X, "›", base);
    put_nav(frame, app, rect, RELOAD_X, "⟳", base);
    put(frame, rect, 7, "│", base.fg(chrome.omnibar_sep_fg));

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
            && surface.browser_frame().is_none());
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
        let suffix_width = suffix.chars().count();
        if max > suffix_width {
            let label_max = max - suffix_width;
            let text = truncate(&label, label_max);
            put(frame, rect, TEXT_START_X, &text, base);
            put(
                frame,
                rect,
                TEXT_START_X + text.chars().count() as u16,
                suffix,
                base.fg(chrome.omnibar_dim_fg),
            );
        } else {
            let text = truncate(suffix.trim_start(), max);
            put(frame, rect, TEXT_START_X, &text, base.fg(chrome.omnibar_dim_fg));
        }
    } else {
        let text = truncate(&label, max);
        put(frame, rect, TEXT_START_X, &text, base);
    }
}

fn draw_editing(app: &mut App, frame: &mut Frame, rect: Rect) -> Option<(u16, u16)> {
    let chrome = app.chrome;
    let state = app.omnibar.as_mut()?;
    let base = Style::default().bg(chrome.omnibar_edit_bg).fg(chrome.omnibar_edit_fg);
    fill(frame, rect, base);
    if rect.width == 0 {
        return None;
    }

    let width = rect.width as usize;
    let (shown, cursor_col) = state.input.visible_text_and_cursor(width);
    let style = if state.select_all { base.add_modifier(Modifier::REVERSED) } else { base };
    put(frame, rect, 0, &shown, style);
    Some((rect.x + cursor_col as u16, rect.y))
}

fn put_nav(frame: &mut Frame, app: &App, rect: Rect, rel_x: u16, text: &str, base: Style) {
    if rel_x >= rect.width {
        return;
    }
    let cell = Rect { x: rect.x + rel_x, y: rect.y, width: 1, height: 1 };
    let hovered = app.hover.is_some_and(|(x, y)| cell.contains(x, y));
    let style = if hovered {
        base.fg(app.chrome.omnibar_hover_fg).add_modifier(Modifier::BOLD)
    } else {
        base
    };
    put(frame, rect, rel_x, text, style);
}

fn fill(frame: &mut Frame, rect: Rect, style: Style) {
    let screen = frame.area();
    let max_x = (rect.x + rect.width).min(screen.width);
    if rect.y >= screen.height {
        return;
    }
    for x in rect.x..max_x {
        frame.buffer_mut()[(x, rect.y)].set_symbol(" ").set_style(style);
    }
}

fn put(frame: &mut Frame, rect: Rect, rel_x: u16, text: &str, style: Style) {
    if rel_x >= rect.width {
        return;
    }
    let screen = frame.area();
    if rect.y >= screen.height {
        return;
    }
    let x = rect.x + rel_x;
    let max = rect.width.saturating_sub(rel_x) as usize;
    frame.buffer_mut().set_stringn(x, rect.y, text, max, style);
}

#[cfg(test)]
mod tests {
    use super::hit;
    use crate::app::OmnibarHit;
    use cmux_tui_core::Rect;

    #[test]
    fn editing_omnibar_treats_entire_row_as_edit_text() {
        let rect = Rect { x: 10, y: 2, width: 20, height: 1 };
        assert_eq!(hit(rect, 11, 2, true), Some(OmnibarHit::Edit));
        assert_eq!(hit(rect, 13, 2, true), Some(OmnibarHit::Edit));
        assert_eq!(hit(rect, 15, 2, true), Some(OmnibarHit::Edit));
    }
}
