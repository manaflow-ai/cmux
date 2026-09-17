//! One scrollable dialog, used by every overlay. Modelled on cmux-tui's
//! shortcut modal: a bordered box on the prompt background, a title with an
//! optional close button, a fixed header area, a scrolling body of rows with
//! the shared scrollbar, and a footer with buttons. The body scrolls with
//! the wheel, PageUp/PageDown, Home/End, track click, and thumb drag, and a
//! `N-M/T` counter appears in the footer when rows overflow.
//!
//! Callers describe the rows; the dialog owns geometry and scrolling, so
//! hit rects for rows and buttons come back consistent with what was drawn.

use super::scroll::{ThumbState, Viewport, draw_thumb};
use super::theme::Chrome;
use super::{ButtonAction, render};
use ratatui::buffer::Buffer;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use unicode_width::UnicodeWidthStr;

/// Scroll state kept by the app for one dialog instance across frames.
#[derive(Debug, Clone, Default)]
pub struct DialogState {
    pub viewport: Viewport,
    /// Screen rects of body rows drawn last frame: (rect, row index).
    pub row_rects: Vec<(Rect, usize)>,
    pub rect: Rect,
}

impl DialogState {
    pub fn wheel(&mut self, delta: isize) {
        self.viewport.scroll_by(delta);
    }
    pub fn press(&mut self, x: u16, y: u16) -> bool {
        if self.viewport.track_contains(x, y) {
            self.viewport.press(y);
            return true;
        }
        false
    }
    pub fn drag_to(&mut self, y: u16) -> bool {
        if self.viewport.drag.is_some() {
            self.viewport.drag_to(y);
            return true;
        }
        false
    }
    pub fn release(&mut self) {
        self.viewport.release();
    }
    /// Body row under a screen point.
    pub fn row_at(&self, x: u16, y: u16) -> Option<usize> {
        self.row_rects.iter().find(|(r, _)| x >= r.x && x < r.x + r.width && y >= r.y && y < r.y + r.height).map(|(_, i)| *i)
    }
    /// Keep `row` inside the visible window, centering when it was far away.
    pub fn reveal(&mut self, row: usize) {
        let v = &mut self.viewport;
        if v.visible == 0 {
            return;
        }
        if row < v.offset {
            v.offset = row;
            v.follow = false;
        } else if row >= v.offset + v.visible {
            v.offset = row + 1 - v.visible;
            v.follow = false;
        }
    }
}

/// One body row: spans with styles, plus whether it is selectable.
pub struct DialogRow {
    pub spans: Vec<(String, Style)>,
    pub selectable: bool,
    /// Right-aligned note drawn dim, e.g. "current".
    pub note: Option<String>,
}

pub struct DialogSpec<'a> {
    pub title: &'a str,
    /// Lines drawn between the title and the body, never scrolled.
    pub header: Vec<Vec<(String, Style)>>,
    pub rows: Vec<DialogRow>,
    /// Highlighted body row.
    pub selected: Option<usize>,
    /// Scroll `selected` into view this frame. Off while the user drags the
    /// scrollbar or hovers, so the viewport stays where they put it.
    pub reveal: bool,
    /// Footer hint, left side.
    pub hint: &'a str,
    /// Footer buttons, right side: (label, accent, action).
    pub buttons: Vec<(&'a str, bool, ButtonAction)>,
    /// Show `[ Esc close ]` in the title row.
    pub close_button: bool,
    pub min_width: u16,
    pub max_width: u16,
}

pub struct DialogOut {
    /// Where the header's first line starts, for callers that place a cursor.
    pub header_origin: (u16, u16),
    pub inner_width: u16,
}

/// Draw the dialog and update `state`. Registers buttons and the close
/// button into `buttons`.
pub fn draw(buf: &mut Buffer, area: Rect, c: &Chrome, hover: Option<(u16, u16)>, spec: DialogSpec, state: &mut DialogState, buttons: &mut Vec<(Rect, ButtonAction)>) -> DialogOut {
    // Width: widest row or header line, within bounds.
    let widest_row = spec
        .rows
        .iter()
        .map(|r| r.spans.iter().map(|(s, _)| s.width()).sum::<usize>() + r.note.as_ref().map(|n| n.width() + 3).unwrap_or(0))
        .max()
        .unwrap_or(0);
    let widest_header = spec.header.iter().map(|l| l.iter().map(|(s, _)| s.width()).sum::<usize>()).max().unwrap_or(0);
    let widest = widest_row.max(widest_header).max(spec.title.width() + 16) as u16 + 8;
    let width = widest.clamp(spec.min_width, spec.max_width).min(area.width.saturating_sub(2));
    // Height: border + title + header + body + footer + border, capped to the screen.
    let chrome_rows = 2 + 1 + spec.header.len() as u16 + 1 + 1; // borders, title, header, gap, footer
    let want = chrome_rows + spec.rows.len() as u16;
    let height = want.min(area.height.saturating_sub(2)).max(chrome_rows + 1);
    let r = render::centered(area, width, height);
    state.rect = r;
    render::fill(buf, r, c.prompt());
    render::border(buf, r, c.prompt_border());
    let inner_x = r.x + 2;
    let inner_w = r.width.saturating_sub(4);
    // Title and close button.
    buf.set_stringn(inner_x, r.y + 1, spec.title, inner_w as usize, c.prompt_title());
    if spec.close_button {
        let close = "[ Esc close ]";
        let cw = close.width() as u16;
        let cr = Rect { x: r.x + r.width - 2 - cw, y: r.y + 1, width: cw, height: 1 };
        let hovered = hover.map(|(hx, hy)| hy == cr.y && hx >= cr.x && hx < cr.x + cr.width).unwrap_or(false);
        buf.set_stringn(cr.x, cr.y, close, cw as usize, c.button(false, hovered));
        buttons.push((cr, ButtonAction::CloseOverlay));
    }
    // Header lines.
    let mut y = r.y + 2;
    let header_origin = (inner_x, y);
    for line in &spec.header {
        let mut x = inner_x;
        for (s, style) in line {
            let room = (inner_x + inner_w).saturating_sub(x);
            if room == 0 {
                break;
            }
            let w = (s.width() as u16).min(room);
            buf.set_stringn(x, y, s, w as usize, *style);
            x += w;
        }
        y += 1;
    }
    // Body.
    let body_y = y;
    let footer_y = r.y + r.height - 2;
    let visible = footer_y.saturating_sub(body_y) as usize;
    let track = Rect { x: r.x + r.width - 2, y: body_y, width: 1, height: visible as u16 };
    state.viewport.follow = false;
    state.viewport.layout(spec.rows.len(), visible, track);
    if let (Some(sel), true) = (spec.selected, spec.reveal && state.viewport.drag.is_none()) {
        state.reveal(sel);
    }
    state.viewport.hover = hover.map(|(hx, hy)| state.viewport.track_contains(hx, hy)).unwrap_or(false);
    let offset = state.viewport.offset;
    state.row_rects.clear();
    let body_w = if state.viewport.has_scrollbar() { inner_w.saturating_sub(1) } else { inner_w };
    for (i, row) in spec.rows.iter().enumerate().skip(offset).take(visible) {
        let ry = body_y + (i - offset) as u16;
        let rect = Rect { x: r.x + 1, y: ry, width: r.width.saturating_sub(3), height: 1 };
        let selected = spec.selected == Some(i) && row.selectable;
        let hovered = row.selectable && hover.map(|(hx, hy)| hy == ry && hx >= rect.x && hx < rect.x + rect.width).unwrap_or(false);
        let base = if selected {
            c.prompt().bg(c.menu_selected_bg).fg(c.menu_selected_fg).add_modifier(Modifier::BOLD)
        } else if hovered {
            c.prompt().bg(c.prompt_button_hover_bg)
        } else {
            c.prompt()
        };
        if selected || hovered {
            for x in rect.x..rect.x + rect.width {
                if let Some(cell) = buf.cell_mut((x, ry)) {
                    cell.set_style(base);
                }
            }
        }
        let mut x = inner_x;
        let marker = if row.selectable { if selected { "▶ " } else { "  " } } else { "" };
        if !marker.is_empty() {
            buf.set_stringn(x, ry, marker, 2, base.fg(c.prompt_button_accent_fg));
            x += 2;
        }
        for (s, style) in &row.spans {
            let room = (inner_x + body_w).saturating_sub(x);
            if room == 0 {
                break;
            }
            let w = (s.width() as u16).min(room);
            let st = if selected || hovered { base.fg(style.fg.unwrap_or(base.fg.unwrap_or(c.prompt_fg))) } else { style.patch(c.prompt()) };
            let st = if selected { st.add_modifier(Modifier::BOLD) } else { st };
            buf.set_stringn(x, ry, s, w as usize, st);
            x += w;
        }
        if let Some(note) = &row.note {
            let nw = note.width() as u16;
            if nw + 2 < body_w {
                buf.set_stringn(inner_x + body_w.saturating_sub(nw), ry, note, nw as usize, base.fg(c.status_dim_fg));
            }
        }
        if row.selectable {
            state.row_rects.push((rect, i));
        }
    }
    if state.viewport.has_scrollbar() {
        draw_thumb(buf, track, state.viewport.thumb(), c.scrollbar_thumb_fg, c.scrollbar_thumb_active_fg, state.viewport.thumb_state());
    }
    // Footer: hint left, counter, buttons right.
    let rects = footer_buttons(buf, r.x + r.width - 2, footer_y, &spec.buttons, c, hover);
    for (rect, (_, _, action)) in rects.iter().zip(spec.buttons.iter()) {
        buttons.push((*rect, action.clone()));
    }
    let buttons_left = rects.first().map(|b| b.x).unwrap_or(r.x + r.width - 2);
    let counter = if state.viewport.has_scrollbar() {
        format!("  {}-{}/{}", offset + 1, (offset + visible).min(spec.rows.len()), spec.rows.len())
    } else {
        String::new()
    };
    let hint = format!("{}{counter}", spec.hint);
    let hw = (hint.width() as u16).min(buttons_left.saturating_sub(inner_x + 1));
    if hw > 0 {
        buf.set_stringn(inner_x, footer_y, &hint, hw as usize, c.prompt().fg(c.status_dim_fg));
    }
    let _ = ThumbState::Idle;
    DialogOut { header_origin, inner_width: inner_w }
}

/// Right-aligned `[ label ]` buttons on one row. Returns their rects in
/// the order given.
pub fn footer_buttons(buf: &mut Buffer, right_x: u16, y: u16, labels: &[(&str, bool, ButtonAction)], c: &Chrome, hover: Option<(u16, u16)>) -> Vec<Rect> {
    let mut rects = Vec::new();
    let mut x = right_x;
    for (label, accent, _) in labels.iter().rev() {
        let w = label.width() as u16;
        x = x.saturating_sub(w);
        let r = Rect { x, y, width: w, height: 1 };
        let hovered = hover.map(|(hx, hy)| hy == y && hx >= r.x && hx < r.x + r.width).unwrap_or(false);
        buf.set_stringn(x, y, label, w as usize, c.button(*accent, hovered));
        rects.push(r);
        x = x.saturating_sub(2);
    }
    rects.reverse();
    rects
}

/// A one-line text field inside a dialog header: filled input background,
/// placeholder when empty. Returns the cursor screen position.
pub fn text_field(buf: &mut Buffer, x: u16, y: u16, width: u16, text: &str, cursor_col: usize, placeholder: &str, c: &Chrome) -> (u16, u16) {
    for cx in x..x + width {
        if let Some(cell) = buf.cell_mut((cx, y)) {
            cell.set_style(c.prompt_input());
        }
    }
    if text.is_empty() {
        buf.set_stringn(x + 1, y, placeholder, width.saturating_sub(1) as usize, c.prompt_input().fg(c.status_dim_fg));
    } else {
        // Keep the cursor visible in a long value.
        let avail = width.saturating_sub(2) as usize;
        let chars: Vec<char> = text.chars().collect();
        let start = cursor_col.saturating_sub(avail);
        let shown: String = chars[start..].iter().collect();
        buf.set_stringn(x + 1, y, &shown, width.saturating_sub(1) as usize, c.prompt_input());
        return (x + 1 + (cursor_col - start) as u16, y);
    }
    (x + 1, y)
}
