//! Pane drawing: each pane renders a border box in its rect. The top
//! border row doubles as the tab bar (always visible, with overflow
//! scrolling), the scrollbar is either a dedicated column inside the box
//! or overlays the right border, and the interior is the terminal content
//! from the ghostty render state (with selection highlight). The active
//! pane's border is highlighted — this is also where flashing
//! notifications will hook in later.

use ghostty_vt::{Cell as VtCell, ColorSpec, RenderState, Rgb};
use mux_core::{BrowserStatus, Rect, SurfaceKind};
use ratatui::style::{Color, Modifier, Style};
use ratatui::Frame;

use super::{thumb_geometry, truncate};
use crate::app::{App, Hit, PaneArea, PaneEdge, Selection};
use crate::config::{tab_label, Theme};

/// Border style for a pane box: active gets the accent color, idle
/// stays dim. Notification flashing will slot in here as another state
/// later. (No hover state: mousing across terminals should not light up
/// their borders.)
fn border_style(theme: &Theme, focused: bool) -> Style {
    if focused {
        Style::default().fg(theme.border_active)
    } else {
        Style::default().fg(theme.border_inactive)
    }
}

/// Draw every pane of the current frame. Returns the terminal cursor
/// position for the focused pane, if visible.
pub fn draw_all(app: &mut App, frame: &mut Frame) -> Option<(u16, u16)> {
    let active_pane = app.tree.active_screen().map(|screen| screen.active_pane);
    let areas = app.pane_areas.clone();
    let mut cursor = None;
    for area in &areas {
        let focused = Some(area.pane) == active_pane;
        draw_box(app, frame, area, focused);
        if area.bar.is_some() {
            draw_tab_bar(app, frame, area, focused);
        }
        if let Some(c) = draw_content(app, frame, area, focused) {
            cursor = Some(c);
        }
        draw_scrollbar(app, frame, area, focused);
        push_resize_hits(app, area);
    }
    cursor
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
    let style = border_style(&theme, focused);
    let (x0, y0) = (rect.x, rect.y);
    let (x1, y1) = (rect.x + rect.width - 1, rect.y + rect.height - 1);
    if x1 >= screen.width || y1 >= screen.height {
        return;
    }
    for x in x0 + 1..x1 {
        buf[(x, y1)].set_symbol("─").set_style(style);
    }
    for y in y0 + 1..y1 {
        buf[(x0, y)].set_symbol("│").set_style(style);
        buf[(x1, y)].set_symbol("│").set_style(style);
    }
    buf[(x0, y0)].set_symbol("┌").set_style(style);
    buf[(x1, y0)].set_symbol("┐").set_style(style);
    buf[(x0, y1)].set_symbol("└").set_style(style);
    buf[(x1, y1)].set_symbol("┘").set_style(style);
}

/// The top border row: `┌` + tabs + `+` + `─...─` + `┐`, with `‹`/`›`
/// overflow arrows when the tabs don't fit. Always visible so a new tab
/// is always one click away.
fn draw_tab_bar(app: &mut App, frame: &mut Frame, area: &PaneArea, focused: bool) {
    let Some(bar) = area.bar else { return };
    let Some(screen_view) = app.tree.active_screen() else { return };
    let Some(pane) = screen_view.pane(area.pane) else { return };
    let tab_cfg = app.config.tabs.clone();
    let tabs: Vec<String> = pane
        .tabs
        .iter()
        .enumerate()
        .map(|(i, t)| tab_label(&tab_cfg, i, &t.title, t.name.as_deref()))
        .collect();
    let active_tab = pane.active_tab;
    let pane_id = area.pane;
    let hover = app.hover;

    let screen = frame.area();
    if bar.width < 2 || bar.y >= screen.height {
        return;
    }
    let theme = app.config.theme;
    let style = border_style(&theme, focused);
    let (base, active_style) = if tab_cfg.solid_background {
        // Solid tab chips on the border line.
        (
            Style::default().bg(theme.tab_bg).fg(Color::Indexed(248)),
            if focused {
                Style::default()
                    .bg(theme.tab_active_bg.unwrap_or(Color::Indexed(240)))
                    .fg(Color::Indexed(255))
                    .add_modifier(Modifier::BOLD)
            } else {
                Style::default()
                    .bg(theme.tab_active_bg.unwrap_or(Color::Indexed(238)))
                    .fg(Color::Indexed(252))
            },
        )
    } else {
        (
            Style::default().fg(Color::Indexed(246)),
            if focused {
                Style::default().fg(Color::Indexed(255)).add_modifier(Modifier::BOLD)
            } else {
                Style::default().fg(Color::Indexed(250))
            },
        )
    };
    // Hover highlight for the bar's controls (+, ‹, ›).
    let hovered_ctrl = |rect: Rect| hover.is_some_and(|(hx, hy)| rect.contains(hx, hy));
    let ctrl_style = |rect: Rect| {
        if hovered_ctrl(rect) {
            Style::default().fg(Color::Indexed(255)).add_modifier(Modifier::BOLD)
        } else {
            base
        }
    };

    // Fill the whole top row with the border line first; tabs overlay it.
    let buf = frame.buffer_mut();
    let (x0, x1) = (bar.x, bar.x + bar.width - 1);
    buf[(x0, bar.y)].set_symbol("┌").set_style(style);
    buf[(x1, bar.y)].set_symbol("┐").set_style(style);
    for x in x0 + 1..x1 {
        buf[(x, bar.y)].set_symbol("─").set_style(style);
    }

    // Layout the tab labels: " 1 zsh " ... " + ", scrolled so the range
    // starting at tab_scroll fits; the active tab is always kept visible.
    let min_w = tab_cfg.min_width as usize;
    let labels: Vec<String> = tabs
        .iter()
        .map(|t| {
            let label = format!(" {} ", truncate(t, 16));
            // Pad to the configured minimum width, keeping the text centered-ish.
            let short = min_w.saturating_sub(label.chars().count());
            format!("{}{}{}", " ".repeat(short / 2), label, " ".repeat(short - short / 2))
        })
        .collect();
    let widths: Vec<u16> = labels.iter().map(|l| l.chars().count() as u16).collect();
    let inner_w = bar.width.saturating_sub(2); // between the corners
    let plus_w: u16 = 3; // " + "
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
        let rect = Rect { x, y: bar.y, width: arrow_w, height: 1 };
        buf.set_stringn(x, bar.y, "‹", 1, ctrl_style(rect));
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
        let style = if is_active { active_style } else { base };
        buf.set_stringn(x, bar.y, label, w as usize, style);
        if tab_cfg.solid_background && is_active {
            buf[(x, bar.y)].set_symbol("▎").set_style(style.fg(theme.tab_rail));
        }
        hits.push((
            Rect { x, y: bar.y, width: w, height: 1 },
            Hit::Tab { pane: pane_id, index: i },
        ));
        x += w;
    }
    if overflow && x + arrow_w <= max_x {
        let rect = Rect { x, y: bar.y, width: arrow_w, height: 1 };
        buf.set_stringn(x, bar.y, "›", 1, ctrl_style(rect));
        hits.push((rect, Hit::TabScroll { pane: pane_id, delta: 1 }));
        x += arrow_w;
    }
    if x + plus_w <= max_x {
        let rect = Rect { x, y: bar.y, width: plus_w, height: 1 };
        buf.set_stringn(x, bar.y, " + ", plus_w as usize, ctrl_style(rect));
        hits.push((rect, Hit::NewTab { pane: pane_id }));
    }
    app.hits.extend(hits);
}

/// Draw one pane's terminal content; returns the frame cursor position
/// when this pane is focused and its cursor is visible.
fn draw_content(
    app: &mut App,
    frame: &mut Frame,
    area: &PaneArea,
    focused: bool,
) -> Option<(u16, u16)> {
    let rect = area.content;
    if rect.width == 0 || rect.height == 0 {
        return None;
    }
    let surface = app.session.surface(area.surface)?;
    surface.take_dirty();
    if surface.kind() == SurfaceKind::Browser {
        draw_browser_content(app, frame, area, &surface);
        return None;
    }

    let rs = app
        .render_states
        .entry(area.surface)
        .or_insert_with(|| RenderState::new().expect("render state alloc"));
    if surface.snapshot(rs).is_err() {
        return None;
    }
    rs.set_clean();

    let selection: Option<Selection> =
        app.selection.filter(|s| s.surface == area.surface && s.anchor != s.head);
    let theme = app.config.theme;

    let screen = frame.area();
    let buf = frame.buffer_mut();
    let max_cols = rect.width.min(screen.width.saturating_sub(rect.x)) as usize;
    let max_rows = rect.height.min(screen.height.saturating_sub(rect.y)) as usize;
    let colors = PaletteResolver::from_render_state(rs);

    rs.walk_rows(|row, _dirty, cells| {
        if row >= max_rows {
            return;
        }
        let y = rect.y + row as u16;
        for (col, cell) in cells.iter().enumerate() {
            if col >= max_cols {
                break;
            }
            let x = rect.x + col as u16;
            let selected = selection.is_some_and(|s| s.contains(col as u16, row as u16));
            apply_cell(&mut buf[(x, y)], cell, &colors, selected.then_some(&theme));
        }
        // Pane narrower than the rect (during resize races): blank the rest.
        for col in cells.len()..max_cols {
            let x = rect.x + col as u16;
            buf[(x, y)].set_symbol(" ").set_style(Style::default());
        }
    })
    .ok()?;

    // Rows beyond what the snapshot provided.
    let (_, snap_rows) = rs.size();
    for row in (snap_rows as usize)..max_rows {
        let y = rect.y + row as u16;
        for col in 0..max_cols {
            let x = rect.x + col as u16;
            buf[(x, y)].set_symbol(" ").set_style(Style::default());
        }
    }

    if focused {
        if let Some(cursor) = rs.cursor() {
            if (cursor.x as usize) < max_cols && (cursor.y as usize) < max_rows {
                return Some((rect.x + cursor.x, rect.y + cursor.y));
            }
        }
    }
    None
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

    let message = if matches!(surface.browser_status(), Some(BrowserStatus::Failed(_))) {
        let error = match surface.browser_status() {
            Some(BrowserStatus::Failed(error)) => error,
            _ => String::new(),
        };
        Some(format!("browser failed: {error}"))
    } else if matches!(surface.browser_status(), Some(BrowserStatus::Starting)) {
        Some("starting browser...".to_string())
    } else if surface.browser_url().is_none() {
        Some("browser panes are not supported over attach yet".to_string())
    } else if !app.graphics_supported {
        Some("terminal has no kitty graphics support".to_string())
    } else if surface.browser_frame().is_none() {
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
        Some(format!("loading {}...", truncate(&url, 48)))
    } else {
        None
    };

    let Some(message) = message else { return };
    if max_cols == 0 || max_rows == 0 {
        return;
    }
    let text = truncate(&message, max_cols as usize);
    let text_w = text.chars().count() as u16;
    let x = rect.x + max_cols.saturating_sub(text_w) / 2;
    let y = rect.y + max_rows / 2;
    frame.buffer_mut().set_stringn(
        x,
        y,
        &text,
        max_cols as usize,
        Style::default().fg(Color::Indexed(244)),
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
    let Some(sb) = surface.with_terminal(|t| t.scrollbar()).flatten() else { return };
    if sb.total <= sb.len {
        return; // nothing to scroll: no scrollbar
    }

    let (thumb_y, thumb_len) = thumb_geometry(&sb, track.height);

    // Hovering/dragging the track grows the thumb glyph for a bigger target.
    let hovered = app.hover.is_some_and(|(hx, hy)| track.contains(hx, hy));
    let dragging = app.dragging_scrollbar() == Some(area.surface);
    let active = hovered || dragging;
    let glyph = if active { "▐" } else { "▕" };

    let thumb_style = if active || focused {
        Style::default().fg(Color::Indexed(252))
    } else {
        Style::default().fg(Color::Indexed(246))
    };
    for dy in 0..track.height {
        let y = track.y + dy;
        if track.x >= screen.width || y >= screen.height {
            continue;
        }
        // The track stays the border line (drawn by draw_box); only the
        // thumb overlays it with a solid bar.
        if dy >= thumb_y && dy < thumb_y + thumb_len {
            buf[(track.x, y)].set_symbol(glyph).set_style(thumb_style);
        }
    }
    app.hits.push((track, Hit::Scrollbar { surface: area.surface, track }));
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
        cell(x0, y0, Some((pane, PaneEdge::Left)), Some((pane, PaneEdge::Top))),
        cell(x1, y0, Some((pane, PaneEdge::Right)), Some((pane, PaneEdge::Top))),
        cell(x0, y1, Some((pane, PaneEdge::Left)), Some((pane, PaneEdge::Bottom))),
        cell(x1, y1, Some((pane, PaneEdge::Right)), Some((pane, PaneEdge::Bottom))),
    ];
    if rect.height > 2 {
        hits.push((
            Rect { x: x0, y: y0 + 1, width: 1, height: rect.height - 2 },
            Hit::PaneResize { horizontal: Some((pane, PaneEdge::Left)), vertical: None },
        ));
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

#[derive(Clone, Copy)]
struct PaletteResolver {
    colors: [Rgb; 256],
    overridden: [bool; 256],
}

impl PaletteResolver {
    fn from_render_state(rs: &RenderState) -> Self {
        Self {
            colors: std::array::from_fn(|idx| rs.palette_color(idx as u8)),
            overridden: std::array::from_fn(|idx| rs.palette_overridden(idx as u8)),
        }
    }

    fn resolve(&self, spec: ColorSpec) -> Color {
        match spec {
            ColorSpec::Default => Color::Reset,
            ColorSpec::Rgb(rgb) => Color::Rgb(rgb.r, rgb.g, rgb.b),
            ColorSpec::Palette(idx) => {
                resolve_palette_color(idx, self.overridden[idx as usize], self.colors[idx as usize])
            }
        }
    }
}

fn resolve_palette_color(idx: u8, overridden: bool, rgb: Rgb) -> Color {
    if overridden {
        return Color::Rgb(rgb.r, rgb.g, rgb.b);
    }
    if idx < 16 {
        return BASIC_PALETTE_COLORS[idx as usize];
    }
    Color::Indexed(idx)
}

// ANSI palette slots 0-15 as host-terminal colors. Ratatui maps these to crossterm's
// dark/bright variants; crossterm 0.28 serializes them as the indexed equivalent of
// SGR 30-37 and 90-97 (foreground) or 40-47 and 100-107 (background).
const BASIC_PALETTE_COLORS: [Color; 16] = [
    Color::Black,        // 0: 30/40
    Color::Red,          // 1: 31/41
    Color::Green,        // 2: 32/42
    Color::Yellow,       // 3: 33/43
    Color::Blue,         // 4: 34/44
    Color::Magenta,      // 5: 35/45
    Color::Cyan,         // 6: 36/46
    Color::Gray,         // 7: 37/47
    Color::DarkGray,     // 8: 90/100
    Color::LightRed,     // 9: 91/101
    Color::LightGreen,   // 10: 92/102
    Color::LightYellow,  // 11: 93/103
    Color::LightBlue,    // 12: 94/104
    Color::LightMagenta, // 13: 95/105
    Color::LightCyan,    // 14: 96/106
    Color::White,        // 15: 97/107
];

fn apply_cell(
    target: &mut ratatui::buffer::Cell,
    cell: &VtCell,
    colors: &PaletteResolver,
    selected: Option<&Theme>,
) {
    if cell.text.is_empty() {
        target.set_symbol(" ");
    } else {
        target.set_symbol(&cell.text);
    }

    let mut style = Style::default();
    style = style.fg(colors.resolve(cell.fg));
    style = style.bg(colors.resolve(cell.bg));
    let mut modifier = Modifier::empty();
    if cell.bold {
        modifier |= Modifier::BOLD;
    }
    if cell.faint {
        modifier |= Modifier::DIM;
    }
    if cell.italic {
        modifier |= Modifier::ITALIC;
    }
    if cell.underline {
        modifier |= Modifier::UNDERLINED;
    }
    if cell.strikethrough {
        modifier |= Modifier::CROSSED_OUT;
    }
    if cell.inverse {
        modifier |= Modifier::REVERSED;
    }
    if cell.blink {
        modifier |= Modifier::SLOW_BLINK;
    }
    if cell.invisible {
        modifier |= Modifier::HIDDEN;
    }
    style = style.add_modifier(modifier);
    // Selection paints the themed background over the cell (the color
    // comes from mux.json, else the user's Ghostty selection-background,
    // else a dark grey default).
    if let Some(theme) = selected {
        style = style.bg(theme.selection_bg);
        if let Some(fg) = theme.selection_fg {
            style = style.fg(fg);
        }
        style = style.remove_modifier(Modifier::REVERSED);
    }
    target.set_style(style);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn palette_color_mapping_preserves_host_palette_when_not_overridden() {
        let rgb = Rgb { r: 1, g: 2, b: 3 };
        let expected = [
            Color::Black,
            Color::Red,
            Color::Green,
            Color::Yellow,
            Color::Blue,
            Color::Magenta,
            Color::Cyan,
            Color::Gray,
            Color::DarkGray,
            Color::LightRed,
            Color::LightGreen,
            Color::LightYellow,
            Color::LightBlue,
            Color::LightMagenta,
            Color::LightCyan,
            Color::White,
        ];

        for (idx, color) in expected.into_iter().enumerate() {
            assert_eq!(resolve_palette_color(idx as u8, false, rgb), color);
        }
        assert_eq!(resolve_palette_color(16, false, rgb), Color::Indexed(16));
        assert_eq!(resolve_palette_color(196, false, rgb), Color::Indexed(196));
    }

    #[test]
    fn palette_color_mapping_renders_overrides_as_rgb() {
        let rgb = Rgb { r: 1, g: 2, b: 3 };
        assert_eq!(resolve_palette_color(1, true, rgb), Color::Rgb(1, 2, 3));
        assert_eq!(resolve_palette_color(196, true, rgb), Color::Rgb(1, 2, 3));
    }
}
