//! Pane drawing: each pane renders a border box in its rect. The top
//! border row doubles as the tab bar (always visible, with overflow
//! scrolling), the scrollbar is either a dedicated column inside the box
//! or overlays the right border, and the interior is the terminal content
//! from the ghostty render state (with selection highlight). The active
//! pane's border is highlighted — this is also where flashing
//! notifications will hook in later.

use std::collections::{HashMap, HashSet};

use cmux_tui_core::{BrowserStatus, Rect, SurfaceKind};
use ghostty_vt::RenderState;
use ratatui::Frame;
use ratatui::style::{Color, Modifier, Style};
use unicode_width::UnicodeWidthStr;

use super::{ScrollbarState, ScrollbarStyle, copy_buffer_row_cropped, thumb_geometry, truncate};
use crate::app::{App, FocusTarget, Hit, PaneArea, PaneContentGeneration, PaneEdge, Selection};
use crate::config::{Theme, tab_label};
use crate::localization;
use crate::session::{ClientInfo, TabNotificationView};

/// Border style for a pane box: active gets the accent color, idle
/// stays dim. Notification flashing will slot in here as another state
/// later. (No hover state: mousing across terminals should not light up
/// their borders.)
fn border_style(app: &App, focused: bool) -> Style {
    let theme = app.config.theme;
    let color = if focused {
        if app.config.theme_overrides.border_active {
            theme.border_active
        } else {
            app.chrome.border_active_fg
        }
    } else if app.config.theme_overrides.border_inactive {
        theme.border_inactive
    } else {
        app.chrome.border_fg
    };
    Style::default().fg(color)
}

fn notification_color(theme: &Theme, notification: TabNotificationView) -> Color {
    match notification.level {
        "warning" => theme.notification_warning,
        "error" => theme.notification_error,
        _ => theme.notification_info,
    }
}

pub(crate) fn client_border_labels(clients: &[ClientInfo]) -> HashMap<u64, String> {
    let mut visible = HashMap::<u64, Vec<(&ClientInfo, (u16, u16), bool)>>::new();
    let mut participating_attachments = HashSet::<u64>::new();
    for client in clients {
        for size in &client.sizes {
            if size.size_participating {
                participating_attachments.insert(size.surface);
            }
            if let Some(grid) = size.cols.zip(size.rows) {
                visible.entry(size.surface).or_default().push((
                    client,
                    grid,
                    size.size_participating,
                ));
            }
        }
    }
    visible
        .into_iter()
        .filter_map(|(surface, viewers)| {
            if !viewers.iter().any(|(client, _, _)| client.is_self)
                || !viewers.iter().any(|(client, _, _)| !client.is_self)
            {
                return None;
            }
            let use_excluded = !participating_attachments.contains(&surface);
            let minimum = viewers
                .iter()
                .filter(|(_, _, participating)| use_excluded || *participating)
                .map(|(_, size, _)| *size)
                .reduce(|smallest, size| (smallest.0.min(size.0), smallest.1.min(size.1)))?;
            Some((
                surface,
                format!(" {} clients · {}×{} min ", viewers.len(), minimum.0, minimum.1),
            ))
        })
        .collect()
}

#[derive(Default)]
pub struct DrawCursors {
    pub input: Option<(u16, u16)>,
    pub terminal: Option<(u16, u16)>,
}

/// Draw every pane of the current frame and return its visible input cursors.
pub fn draw_all(app: &mut App, frame: &mut Frame) -> DrawCursors {
    let active_pane = app.tree.active_screen().map(|screen| screen.active_pane);
    let panes_accept_focus = app.focus == FocusTarget::Pane;
    let areas = app.pane_areas.clone();
    let visible_surfaces: HashSet<_> = areas.iter().map(|area| area.surface).collect();
    app.rendered_terminal_bounds.retain(|surface, _| visible_surfaces.contains(surface));
    app.rendered_kitty_graphics.retain(|surface, _| visible_surfaces.contains(surface));
    app.rendered_terminal_pointer_semantics.retain(|surface, _| visible_surfaces.contains(surface));
    app.rendered_pane_content_generations.retain(|surface, _| visible_surfaces.contains(surface));
    let mut input_cursor = None;
    let mut terminal_cursor = None;
    for area in &areas {
        let focused = panes_accept_focus && Some(area.pane) == active_pane;
        draw_box(app, frame, area, focused);
        if area.bar.is_some() {
            draw_tab_bar(app, frame, area, focused);
        }
        let cursors = draw_content(app, frame, area, focused);
        if cursors.input.is_some() {
            input_cursor = cursors.input;
        }
        if cursors.terminal.is_some() {
            terminal_cursor = cursors.terminal;
        }
        draw_scrollbar(app, frame, area, focused);
        push_resize_hits(app, area);
    }
    DrawCursors { input: input_cursor, terminal: terminal_cursor }
}

/// The pane's border box. The top row is left to the tab bar; here we
/// draw the left/right/bottom edges and the corners.
fn draw_box(app: &mut App, frame: &mut Frame, area: &PaneArea, focused: bool) {
    let rect = area.rect;
    if area.bar.is_none() || rect.width < 2 || rect.height < 2 {
        return;
    }
    let screen = frame.area();
    let theme = app.config.theme;
    let buf = frame.buffer_mut();
    let notification = app
        .tree
        .pane(area.pane)
        .and_then(|pane| pane.tabs.get(pane.active_tab))
        .and_then(|tab| tab.notification)
        .filter(|notification| notification.unread);
    let style = notification
        .map(|notification| Style::default().fg(notification_color(&theme, notification)))
        .unwrap_or_else(|| border_style(app, focused));
    let glyphs = theme.border_style.glyphs();
    let (x0, y0) = (rect.x, rect.y);
    let (x1, y1) = (rect.x + rect.width - 1, rect.y + rect.height - 1);
    if x1 >= screen.width || y1 >= screen.height {
        return;
    }
    for x in x0..=x1 {
        buf[(x, y1)].set_symbol(glyphs.horizontal).set_style(style);
    }
    for y in y0 + 1..y1 {
        if area.has_left_edge() {
            buf[(x0, y)].set_symbol(glyphs.vertical).set_style(style);
        }
        if area.has_right_edge() {
            buf[(x1, y)].set_symbol(glyphs.vertical).set_style(style);
        }
    }
    if area.has_left_edge() {
        buf[(x0, y0)].set_symbol(glyphs.top_left).set_style(style);
        buf[(x0, y1)].set_symbol(glyphs.bottom_left).set_style(style);
    }
    if area.has_right_edge() {
        buf[(x1, y0)].set_symbol(glyphs.top_right).set_style(style);
        buf[(x1, y1)].set_symbol(glyphs.bottom_right).set_style(style);
    }

    if let Some(label) = app.client_border_labels.get(&area.surface) {
        let width = label.width() as u16;
        if area.has_left_edge() && area.has_right_edge() && width + 2 < rect.width {
            let hit = Rect { x: x0 + 1, y: y1, width, height: 1 };
            buf.set_stringn(hit.x, hit.y, label, width as usize, style);
            app.hits.push((hit, Hit::Clients { surface: area.surface }));
        }
    }
}

/// The top border row: `┌` + tabs + `+` + `─...─` + `┐`, with `‹`/`›`
/// overflow arrows when the tabs don't fit. Always visible so a new tab
/// is always one click away.
fn clip_tab_bar_rect(logical: Rect, bar: Rect, source_x: u16) -> Option<Rect> {
    let start = logical.x.max(source_x);
    let end = logical.x.saturating_add(logical.width).min(source_x.saturating_add(bar.width));
    (end > start).then(|| Rect {
        x: bar.x.saturating_add(start.saturating_sub(source_x)),
        y: bar.y,
        width: end - start,
        height: 1,
    })
}

fn draw_tab_bar(app: &mut App, frame: &mut Frame, area: &PaneArea, focused: bool) {
    let Some(bar) = area.bar else { return };
    let Some(screen_view) = app.tree.active_screen() else { return };
    let Some(pane) = screen_view.pane(area.pane) else { return };
    let tab_cfg = app.config.tabs.clone();
    let tabs: Vec<String> = pane
        .tabs
        .iter()
        .enumerate()
        .map(|(i, t)| {
            let mut label = tab_label(&tab_cfg, i, &t.title, t.name.as_deref());
            if t.notification.is_some_and(|notification| notification.unread) {
                label.push_str(" •");
            }
            label
        })
        .collect();
    let active_tab = pane.active_tab;
    let pane_id = area.pane;
    let hover = app.hover;
    let tab_drag = app.tab_drag();
    let drop_index = tab_drag
        .and_then(|drag| drag.target)
        .and_then(|(target_pane, index)| (target_pane == pane_id).then_some(index));

    let screen = frame.area();
    let full_width = area.viewport.map_or(bar.width, |clip| clip.full_rect_width);
    let source_x = area.viewport.map_or(0, |clip| clip.rect_source_x);
    let screen_right = screen.x.saturating_add(screen.width);
    let screen_bottom = screen.y.saturating_add(screen.height);
    if full_width < 2
        || bar.width == 0
        || source_x >= full_width
        || bar.x < screen.x
        || bar.x >= screen_right
        || bar.y < screen.y
        || bar.y >= screen_bottom
    {
        return;
    }
    let visible_bar = Rect { width: bar.width.min(screen_right.saturating_sub(bar.x)), ..bar };
    let theme = app.config.theme;
    let chrome = app.chrome;
    let style = border_style(app, focused);
    let tab_bg = if app.config.theme_overrides.tab_bg { theme.tab_bg } else { chrome.tab_bar_bg };
    let (base, active_style) = if tab_cfg.solid_background {
        // Solid tab chips on the border line.
        (
            Style::default().bg(tab_bg).fg(chrome.tab_fg),
            if focused {
                Style::default()
                    .bg(theme.tab_active_bg.unwrap_or(chrome.tab_active_bg))
                    .fg(chrome.tab_active_fg)
                    .add_modifier(Modifier::BOLD)
            } else {
                Style::default()
                    .bg(theme.tab_active_bg.unwrap_or(chrome.tab_active_unfocused_bg))
                    .fg(chrome.tab_active_unfocused_fg)
            },
        )
    } else {
        (
            Style::default().fg(chrome.tab_plain_fg),
            if focused {
                Style::default().fg(chrome.tab_plain_active_fg).add_modifier(Modifier::BOLD)
            } else {
                Style::default().fg(chrome.tab_plain_unfocused_fg)
            },
        )
    };
    let visible_rect = |rect| clip_tab_bar_rect(rect, visible_bar, source_x);
    // Hover highlight for the bar's controls (+, ‹, ›).
    let ctrl_style = |rect: Rect| {
        if visible_rect(rect)
            .is_some_and(|rect| hover.is_some_and(|(hx, hy)| rect.contains(hx, hy)))
        {
            Style::default().fg(chrome.tab_control_hover_fg).add_modifier(Modifier::BOLD)
        } else {
            base
        }
    };

    // Unclipped panes render directly into the frame. Cropped panes retain
    // their full logical geometry in a one-row scratch buffer, then use the
    // shared wide-glyph-safe crop path.
    let direct = area.viewport.is_none() && bar.width <= screen_right.saturating_sub(bar.x);
    let mut logical = (!direct).then(|| app.chrome_row_scratch.take(full_width));
    let (origin_x, origin_y) = if direct { (bar.x, bar.y) } else { (0, 0) };
    let buf = match logical.as_mut() {
        Some(logical) => logical,
        None => frame.buffer_mut(),
    };
    let glyphs = theme.border_style.glyphs();
    let (x0, x1) = (0, full_width - 1);
    for x in x0..=x1 {
        buf[(origin_x + x, origin_y)].set_symbol(glyphs.horizontal).set_style(style);
    }
    if area.has_left_edge() {
        buf[(origin_x + x0, origin_y)].set_symbol(glyphs.top_left).set_style(style);
    }
    if area.has_right_edge() {
        buf[(origin_x + x1, origin_y)].set_symbol(glyphs.top_right).set_style(style);
    }

    // Layout the tab labels: " 1 zsh " ... " + ", scrolled so the range
    // starting at tab_scroll fits; the active tab is always kept visible.
    let min_w = tab_cfg.min_width as usize;
    let labels: Vec<String> = tabs
        .iter()
        .map(|t| {
            let label = format!(" {} ", truncate(t, 16));
            // Pad to the configured minimum width, keeping the text centered-ish.
            let short = min_w.saturating_sub(label.width());
            format!("{}{}{}", " ".repeat(short / 2), label, " ".repeat(short - short / 2))
        })
        .collect();
    // Pill and slant chips wrap solid tabs in cap glyphs, one cell on each
    // side; the caps take part in layout, scrolling, and hit rects.
    let chip_caps = tab_cfg.solid_background.then(|| tab_cfg.style.caps()).flatten();
    let cap_cells: u16 = if chip_caps.is_some() { 2 } else { 0 };
    let widths: Vec<u16> = labels.iter().map(|label| label.width() as u16 + cap_cells).collect();
    let inner_w = full_width.saturating_sub(2); // between the corners
    let plus_label = app.config.tabs.plus.label.clone();
    let plus_w: u16 = (plus_label.width() as u16).max(1);
    let arrow_w: u16 = 1;

    // Clamp the requested scroll, then bump it until the active tab fits.
    let max_scroll = tabs.len().saturating_sub(1);
    let mut scroll = app.tab_scroll.get(&pane_id).copied().unwrap_or(0).min(max_scroll);
    let fits = |scroll: usize| {
        let left_arrow = if scroll > 0 { arrow_w } else { 0 };
        let mut budget = inner_w.saturating_sub(left_arrow + plus_w + arrow_w);
        for w in &widths[scroll..=active_tab.max(scroll)] {
            if *w > budget {
                return false;
            }
            budget -= *w;
        }
        true
    };
    while scroll < active_tab && !fits(scroll) {
        scroll += 1;
    }
    app.tab_scroll.insert(pane_id, scroll);

    let mut hits = Vec::new();
    let mut x = x0 + 1;
    let max_x = x1; // exclusive
    if scroll > 0 {
        let rect = Rect { x, y: 0, width: arrow_w, height: 1 };
        buf.set_stringn(origin_x + x, origin_y, "‹", 1, ctrl_style(rect));
        hits.push((rect, Hit::TabScroll { pane: pane_id, delta: -1 }));
        x += arrow_w;
    }
    let mut overflow = false;
    for (i, label) in labels.iter().enumerate().skip(scroll) {
        let w = widths[i];
        // Reserve room for the + button and a possible right arrow.
        if x + w + plus_w + arrow_w > max_x {
            overflow = true;
            break;
        }
        let is_active = i == active_tab;
        let mut style = if is_active { active_style } else { base };
        if let Some(notification) =
            pane.tabs[i].notification.filter(|notification| notification.unread)
        {
            style = style.fg(notification_color(&theme, notification));
        }
        if tab_drag.is_some_and(|drag| pane.tabs[i].surface == drag.surface) {
            style = style.add_modifier(Modifier::DIM);
        }
        if let Some((cap_left, cap_right)) = chip_caps {
            // Caps take the chip's background as their foreground and float
            // over the border row, so every chip reads as a pill or slant.
            let chip_bg = style.bg.unwrap_or(theme.tab_bg);
            let cap_style = Style::default().fg(chip_bg);
            buf.set_stringn(origin_x + x, origin_y, cap_left, 1, cap_style);
            buf.set_stringn(
                origin_x + x + 1,
                origin_y,
                label,
                w.saturating_sub(cap_cells) as usize,
                style,
            );
            buf.set_stringn(origin_x + x + w.saturating_sub(1), origin_y, cap_right, 1, cap_style);
        } else {
            buf.set_stringn(origin_x + x, origin_y, label, w as usize, style);
            if tab_cfg.solid_background && is_active {
                buf[(origin_x + x, origin_y)].set_symbol("▎").set_style(style.fg(theme.tab_rail));
            }
        }
        if drop_index == Some(i) && x < max_x {
            buf[(origin_x + x, origin_y)]
                .set_symbol("▌")
                .set_style(Style::default().fg(theme.tab_rail).add_modifier(Modifier::BOLD));
        }
        hits.push((Rect { x, y: 0, width: w, height: 1 }, Hit::Tab { pane: pane_id, index: i }));
        x += w;
    }
    if drop_index == Some(tabs.len()) && x < max_x {
        buf[(origin_x + x, origin_y)]
            .set_symbol("▌")
            .set_style(Style::default().fg(theme.tab_rail).add_modifier(Modifier::BOLD));
    }
    if overflow && x + arrow_w <= max_x {
        let rect = Rect { x, y: 0, width: arrow_w, height: 1 };
        buf.set_stringn(origin_x + x, origin_y, "›", 1, ctrl_style(rect));
        hits.push((rect, Hit::TabScroll { pane: pane_id, delta: 1 }));
        x += arrow_w;
    }
    if x + plus_w <= max_x {
        let rect = Rect { x, y: 0, width: plus_w, height: 1 };
        buf.set_stringn(origin_x + x, origin_y, &plus_label, plus_w as usize, ctrl_style(rect));
        hits.push((rect, Hit::NewTab { pane: pane_id }));
    }

    if let Some(logical) = logical.take() {
        let visible_width = visible_bar.width.min(full_width.saturating_sub(source_x));
        copy_buffer_row_cropped(
            &logical,
            0,
            source_x,
            frame.buffer_mut(),
            Rect { width: visible_width, height: 1, ..bar },
        );
        app.chrome_row_scratch.put(logical);
    }
    app.hits.extend(hits.into_iter().filter_map(|(rect, hit)| {
        clip_tab_bar_rect(rect, visible_bar, source_x).map(|rect| (rect, hit))
    }));
}

/// Draw one pane's terminal content; returns the frame cursor position
/// when this pane is focused and its cursor is visible.
fn draw_content(app: &mut App, frame: &mut Frame, area: &PaneArea, focused: bool) -> DrawCursors {
    let rect = area.content;
    app.rendered_terminal_bounds.remove(&area.surface);
    app.rendered_kitty_graphics.remove(&area.surface);
    app.rendered_terminal_pointer_semantics.remove(&area.surface);
    if matches!(
        app.rendered_pane_content_generations.get(&area.surface),
        Some(PaneContentGeneration::Terminal(_))
    ) {
        app.rendered_pane_content_generations.remove(&area.surface);
    }
    if rect.width == 0 || rect.height == 0 {
        return DrawCursors::default();
    }
    let Some(surface) = app.session.surface(area.surface) else {
        return DrawCursors::default();
    };
    surface.take_dirty();
    if surface.kind() == SurfaceKind::Browser {
        let cursor = super::omnibar::draw(app, frame, area);
        draw_browser_content(app, frame, area, &surface);
        return DrawCursors { input: cursor.filter(|_| focused), terminal: None };
    }
    let selection_visible = app.selection_is_visible(area.surface);
    let selection: Option<Selection> =
        app.selection.filter(|s| s.surface == area.surface && selection_visible);
    let selection_offset = selection.map(|_| app.surface_scroll_offset(area.surface)).unwrap_or(0);
    let theme = app.config.theme;

    let rs = app
        .render_states
        .entry(area.surface)
        .or_insert_with(|| RenderState::new().expect("render state alloc"));
    let Ok(render) = surface.render_frame(rs) else {
        return DrawCursors::default();
    };
    let source_x = area.content_source_x();
    let live =
        super::terminal_grid::rendered_viewport_rect_cropped(rect, frame.area(), &render, source_x);
    app.rendered_terminal_bounds.insert(area.surface, live);
    app.rendered_kitty_graphics.insert(area.surface, render.frame.kitty_graphics.clone());
    app.rendered_terminal_sizes.insert(area.surface, render.frame.size);
    app.rendered_terminal_pointer_semantics.insert(area.surface, render.pointer_semantics);
    app.rendered_pane_content_generations
        .insert(area.surface, PaneContentGeneration::Terminal(render.content_generation));
    if focused
        && app.menu.is_none()
        && app.prompt.is_none()
        && app.pairing_dialog.is_none()
        // A scoped attach client is a transparent passthrough: it asserts a
        // cursor shape and color on the host terminal only when the inner
        // application authored one (DECSCUSR), never for session or frontend
        // defaults. Otherwise the host terminal's own configured cursor
        // style stays untouched.
        && (!app.is_surface_only() || surface.cursor_style_authored())
    {
        let (shape, blinking) = render.frame.cursor_visual;
        app.use_terminal_cursor_spec(
            super::terminal_grid::resolved_cursor_color(&render),
            shape,
            blinking,
        );
    }

    let cursor = super::terminal_grid::draw_render_frame_cropped(
        frame,
        rect,
        source_x,
        &render,
        &theme,
        &app.chrome,
        |col, row| selection.is_some_and(|s| s.contains_viewport(col, row, selection_offset)),
    );
    if !focused && theme.dim_inactive {
        let screen = frame.area();
        let max_x = rect.x.saturating_add(rect.width).min(screen.width);
        let max_y = rect.y.saturating_add(rect.height).min(screen.height);
        let dim = Style::default().add_modifier(Modifier::DIM);
        let buf = frame.buffer_mut();
        for y in rect.y..max_y {
            for x in rect.x..max_x {
                buf[(x, y)].set_style(dim);
            }
        }
    }
    DrawCursors { input: None, terminal: focused.then_some(cursor).flatten() }
}

fn draw_browser_content(
    app: &mut App,
    frame: &mut Frame,
    area: &PaneArea,
    surface: &crate::session::SurfaceHandle,
) {
    let rect = area.content;
    let screen = frame.area();
    let max_cols = rect.width.min(screen.width.saturating_sub(rect.x));
    let max_rows = rect.height.min(screen.height.saturating_sub(rect.y));
    let buf = frame.buffer_mut();
    for row in 0..max_rows {
        for col in 0..max_cols {
            buf[(rect.x + col, rect.y + row)].set_symbol(" ").set_style(Style::default());
        }
    }

    let browser_status = surface.browser_status();
    let message = if let Some(status @ BrowserStatus::Failed(_)) = browser_status.as_ref() {
        status.failure().map(|failure| localization::catalog().browser.failure_message(failure))
    } else if matches!(browser_status, Some(BrowserStatus::Starting)) {
        Some(localization::catalog().browser.starting.to_string())
    } else if surface.browser_url().is_none() {
        Some(localization::catalog().browser.attach_unsupported.to_string())
    } else if !app.graphics_supported {
        Some(localization::catalog().browser.graphics_unsupported.to_string())
    } else if !surface.has_browser_frame() {
        let url = surface
            .browser_url()
            .or_else(|| {
                app.tree
                    .active_screen()
                    .and_then(|screen| screen.pane(area.pane))
                    .and_then(|pane| pane.tabs.get(pane.active_tab))
                    .map(|tab| tab.title.clone())
            })
            .unwrap_or_else(|| "browser".to_string());
        Some(localization::catalog().browser.loading(&truncate(&url, 48)))
    } else {
        None
    };

    let Some(message) = message else { return };
    if max_cols == 0 || max_rows == 0 {
        return;
    }
    let text = truncate(&message, max_cols as usize);
    let text_w = text.width() as u16;
    let x = rect.x + max_cols.saturating_sub(text_w) / 2;
    let y = rect.y + max_rows / 2;
    frame.buffer_mut().set_stringn(
        x,
        y,
        &text,
        max_cols as usize,
        Style::default().fg(app.chrome.browser_message_fg),
    );
}

/// Scrollbar track. Visible whenever the surface has any scrollback
/// (total > viewport); hidden only when no scrolling is possible at all.
/// The whole track is clickable/draggable.
fn draw_scrollbar(app: &mut App, frame: &mut Frame, area: &PaneArea, focused: bool) {
    let Some(track) = area.track else { return };
    if track.height == 0 {
        return;
    }
    let dedicated_column = track.x + 1 < area.rect.x + area.rect.width;
    let screen = frame.area();
    let buf = frame.buffer_mut();
    if dedicated_column {
        for dy in 0..track.height {
            let y = track.y + dy;
            if track.x < screen.width && y < screen.height {
                buf[(track.x, y)].set_symbol(" ").set_style(Style::default());
            }
        }
    }
    let Some(surface) = app.session.surface(area.surface) else { return };
    if surface.kind() == SurfaceKind::Browser {
        return;
    }
    let Some(sb) = surface.scrollbar() else { return };
    if sb.total <= sb.len {
        return; // nothing to scroll: no scrollbar
    }

    let (thumb_y, thumb_len) = thumb_geometry(&sb, track.height);

    // Hovering/dragging the track grows the thumb glyph for a bigger target.
    let hovered = app.hover.is_some_and(|(hx, hy)| track.contains(hx, hy));
    let dragging = app.dragging_scrollbar() == Some(area.surface);
    let active = hovered || dragging;
    // The track stays as the existing pane border or empty reserved column;
    // the shared style paints only the thumb.
    let state = if active {
        ScrollbarState::Expanded
    } else if focused {
        ScrollbarState::Highlighted
    } else {
        ScrollbarState::Idle
    };
    ScrollbarStyle::from_chrome(app.chrome).draw_thumb(
        buf,
        track,
        (thumb_y, thumb_len),
        Style::default(),
        state,
    );
    app.hits.push((track, Hit::Scrollbar { surface: area.surface, track, scrollbar: sb }));
}

fn push_resize_hits(app: &mut App, area: &PaneArea) {
    let rect = area.rect;
    if area.bar.is_none() || rect.width < 2 || rect.height < 2 {
        return;
    }
    let (x0, y0) = (rect.x, rect.y);
    let (x1, y1) = (rect.x + rect.width - 1, rect.y + rect.height - 1);
    let pane = area.pane;
    let cell = |x, y, horizontal, vertical| {
        (Rect { x, y, width: 1, height: 1 }, Hit::PaneResize { horizontal, vertical })
    };
    let mut hits = vec![
        cell(
            x0,
            y0,
            area.has_left_edge().then_some((pane, PaneEdge::Left)),
            Some((pane, PaneEdge::Top)),
        ),
        cell(
            x1,
            y0,
            area.has_right_edge().then_some((pane, PaneEdge::Right)),
            Some((pane, PaneEdge::Top)),
        ),
        cell(
            x0,
            y1,
            area.has_left_edge().then_some((pane, PaneEdge::Left)),
            Some((pane, PaneEdge::Bottom)),
        ),
        cell(
            x1,
            y1,
            area.has_right_edge().then_some((pane, PaneEdge::Right)),
            Some((pane, PaneEdge::Bottom)),
        ),
    ];
    if area.has_left_edge() && rect.height > 2 {
        hits.push((
            Rect { x: x0, y: y0 + 1, width: 1, height: rect.height - 2 },
            Hit::PaneResize { horizontal: Some((pane, PaneEdge::Left)), vertical: None },
        ));
    }
    if area.has_right_edge() && rect.height > 2 {
        hits.push((
            Rect { x: x1, y: y0 + 1, width: 1, height: rect.height - 2 },
            Hit::PaneResize { horizontal: Some((pane, PaneEdge::Right)), vertical: None },
        ));
    }
    if rect.width > 2 {
        hits.push((
            Rect { x: x0 + 1, y: y0, width: rect.width - 2, height: 1 },
            Hit::PaneResize { horizontal: None, vertical: Some((pane, PaneEdge::Top)) },
        ));
        hits.push((
            Rect { x: x0 + 1, y: y1, width: rect.width - 2, height: 1 },
            Hit::PaneResize { horizontal: None, vertical: Some((pane, PaneEdge::Bottom)) },
        ));
    }
    app.hits.extend(hits);
}

#[cfg(test)]
mod tests {
    use super::{client_border_labels, clip_tab_bar_rect};
    use crate::session::{ClientInfo, ClientSizeInfo};
    use cmux_tui_core::Rect;

    #[test]
    fn offscreen_tab_hit_clipping_returns_none_without_underflow() {
        let bar = Rect { x: 0, y: 0, width: 8, height: 1 };
        let logical = Rect { x: 1, y: 0, width: 3, height: 1 };
        assert_eq!(clip_tab_bar_rect(logical, bar, 10), None);
    }

    fn client(id: u64, surface: u64, size: Option<(u16, u16)>) -> ClientInfo {
        ClientInfo {
            client: id,
            transport: "unix".to_string(),
            name: None,
            kind: Some("tui".to_string()),
            connected_seconds: 0,
            attached: vec![surface],
            sizes: vec![ClientSizeInfo {
                surface,
                cols: size.map(|size| size.0),
                rows: size.map(|size| size.1),
                size_participating: true,
            }],
            is_self: id == 1,
        }
    }

    #[test]
    fn attached_but_hidden_client_does_not_show_on_pane_border() {
        let clients = vec![client(1, 9, Some((80, 24))), client(2, 9, None)];
        assert_eq!(client_border_labels(&clients).get(&9), None);
    }

    #[test]
    fn client_button_shows_shared_minimum_after_all_sizes_arrive() {
        let clients = vec![client(1, 9, Some((120, 30))), client(2, 9, Some((80, 40)))];
        assert_eq!(
            client_border_labels(&clients).get(&9).map(String::as_str),
            Some(" 2 clients · 80×30 min ")
        );
    }

    #[test]
    fn client_button_shows_fallback_minimum_when_every_viewer_is_excluded() {
        let mut clients = vec![client(1, 9, Some((120, 30))), client(2, 9, Some((80, 40)))];
        for client in &mut clients {
            client.sizes[0].size_participating = false;
        }

        assert_eq!(
            client_border_labels(&clients).get(&9).map(String::as_str),
            Some(" 2 clients · 80×30 min ")
        );
    }

    #[test]
    fn unsized_participant_suppresses_excluded_report_fallback() {
        let mut clients =
            vec![client(1, 9, Some((120, 30))), client(2, 9, Some((80, 40))), client(3, 9, None)];
        clients[0].sizes[0].size_participating = false;
        clients[1].sizes[0].size_participating = false;

        assert_eq!(client_border_labels(&clients).get(&9), None);
    }

    #[test]
    fn client_visible_on_another_tab_does_not_show_on_this_pane_border() {
        let clients = vec![client(1, 9, Some((120, 30))), client(2, 10, Some((80, 40)))];
        assert_eq!(client_border_labels(&clients).get(&9), None);
    }
}
